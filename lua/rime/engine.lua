-- Owns the Rime session: starting it in the background, polling for
-- finished jobs, and keeping track of the composition.
local M = {}

local api = vim.api
local config = require('rime.config')
local native = require('rime.native')

---@alias rime.State 'stopped'|'building'|'starting'|'ready'|'busy'|'error'
---@type rime.State
M.state = 'stopped'
---@type string?
M.error = nil
--- Whether Rime has an unfinished composition.
M.composing = false
--- Context of the composition, refreshed after every key.
---@type table?
M.ctx = nil
--- { buf, row, col } where the composition started.
---@type { [1]: integer, [2]: integer, [3]: integer }?
M.anchor = nil

---@type table?
local core = nil
local timer = nil ---@type uv.uv_timer_t?
local waiters = {} ---@type fun()[]
local deploying = false ---@type false|table|'announced'

local levels = { info = 0, warning = 1, error = 2, fatal = 3 }

local function notify(msg, level)
  vim.notify('rime: ' .. msg, level or vim.log.levels.INFO)
end

local function emit(pattern, data)
  api.nvim_exec_autocmds('User', { pattern = pattern, data = data, modeline = false })
end

local function ui()
  return require('rime.ui')
end

--- Shared data directory: the configured one, or the first that exists.
local function shared_data_dir()
  local dir = config.options.shared_data_dir
  if dir then return vim.fs.normalize(dir) end
  local candidates = {}
  for _, d in ipairs(vim.split(vim.env.XDG_DATA_DIRS or '/usr/local/share:/usr/share', ':', { trimempty = true })) do
    table.insert(candidates, d .. '/rime-data')
  end
  vim.list_extend(candidates, {
    '/opt/homebrew/share/rime-data',
    '/usr/local/share/rime-data',
    '/usr/share/rime-data',
    '/run/current-system/sw/share/rime-data',
    '/Library/Input Methods/Squirrel.app/Contents/SharedSupport',
  })
  for _, d in ipairs(candidates) do
    if vim.uv.fs_stat(d .. '/default.yaml') then return d end
  end
  return nil
end
M.shared_data_dir = shared_data_dir

local function flush_waiters()
  local list = waiters
  waiters = {}
  for _, fn in ipairs(list) do
    fn()
  end
end

local function handle_event(kind, value)
  if kind == 'deploy' then
    -- librime checks the workspace at every start; only announce a
    -- deployment that takes a while (compiling dictionaries).
    if value == 'start' then
      local id = {}
      deploying = id
      vim.defer_fn(function()
        if deploying == id then
          deploying = 'announced'
          notify('deploying…')
        end
      end, 1000)
    elseif value == 'success' then
      if deploying == 'announced' then notify('deployed') end
      deploying = false
    elseif value == 'failure' then
      deploying = false
      notify('deployment failed, see ' .. config.options.log_dir, vim.log.levels.ERROR)
    end
  elseif kind == 'schema' or kind == 'option' then
    emit('RimeOption', { kind = kind, value = value })
    require('rime.mode').changed()
  elseif kind == 'error' then
    notify(value, vim.log.levels.ERROR)
  elseif kind == 'warning' then
    notify(value, vim.log.levels.WARN)
  end
end

local function poll()
  if not core then return end
  local state, events = core.poll()
  if events then
    for _, ev in ipairs(events) do
      handle_event(ev[1], ev[2])
    end
  end
  if state == 'busy' then return end
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
  if state == 'ready' then
    M.state = 'ready'
    M.error = nil
    emit('RimeReady')
    require('rime.mode').changed()
    flush_waiters()
  else
    M.state = state == 'error' and 'error' or 'stopped'
    waiters = {}
  end
end

local function start_polling()
  if timer then return end
  timer = assert(vim.uv.new_timer())
  -- Only runs while a job is in progress; stops itself afterwards.
  timer:start(10, 25, vim.schedule_wrap(poll))
end

--- Start Rime in the background.  `on_ready` runs once it is usable.
---@param on_ready? fun()
function M.start(on_ready)
  if on_ready then table.insert(waiters, on_ready) end
  if M.state == 'ready' then return flush_waiters() end
  if M.state ~= 'stopped' and M.state ~= 'error' then return end

  local opts = config.options
  if not native.core and opts.auto_build and native.needs_build() then
    M.state = 'building'
    notify('building the native module…')
    native.build(function(ok, msg)
      M.state = 'stopped'
      if not ok then
        M.state = 'error'
        M.error = msg
        waiters = {}
        return notify(msg, vim.log.levels.ERROR)
      end
      M.start()
    end)
    return
  end

  local c, err = native.load()
  if not c then
    M.state = 'error'
    M.error = 'cannot load ' .. native.library .. ': ' .. tostring(err)
    waiters = {}
    return notify(M.error .. '\nRun :Rime build', vim.log.levels.ERROR)
  end
  core = c

  local shared = shared_data_dir()
  if not shared then
    notify('no shared Rime data found; set shared_data_dir', vim.log.levels.WARN)
  end
  vim.fn.mkdir(opts.user_data_dir, 'p')
  vim.fn.mkdir(opts.log_dir, 'p')
  local ok, start_err = core.start({
    librime = opts.librime,
    shared_data_dir = shared,
    user_data_dir = vim.fs.normalize(opts.user_data_dir),
    log_dir = vim.fs.normalize(opts.log_dir),
    log_level = levels[opts.log_level] or 2,
    schema = opts.schema,
    full_check = opts.full_check,
  })
  if not ok then
    M.state = 'error'
    M.error = start_err
    return notify('cannot start: ' .. tostring(start_err), vim.log.levels.ERROR)
  end
  M.state = 'starting'
  start_polling()
end

---@return boolean
function M.ready()
  return M.state == 'ready'
end

---@return table?
function M.core()
  return core
end

--- Run a background job of the C module (redeploy, sync, select_schema).
local function job(name, ...)
  if not core or (M.state ~= 'ready' and M.state ~= 'error') then
    return notify(name .. ': Rime is not running', vim.log.levels.WARN)
  end
  M.clear()
  local ok, err = core[name](...)
  if not ok then return notify(name .. ': ' .. tostring(err), vim.log.levels.WARN) end
  M.state = 'busy'
  start_polling()
end

function M.redeploy()
  if M.state == 'stopped' or M.state == 'error' then
    -- Not running yet: starting deploys anyway.
    config.options.full_check = true
    return M.start()
  end
  job('redeploy')
end

function M.sync()
  job('sync')
end

---@param id string
function M.select_schema(id)
  config.options.schema = id
  job('select_schema', id)
end

-- Composition -------------------------------------------------------------

--- Record the new composition state after Rime handled something.
---@param composing boolean
function M.update(composing)
  if composing then
    if not M.composing then
      local cursor = api.nvim_win_get_cursor(0)
      M.anchor = { api.nvim_get_current_buf(), cursor[1] - 1, cursor[2] }
    end
    M.ctx = core.context()
  else
    M.ctx = nil
    M.anchor = nil
  end
  M.composing = composing
  ui().update()
end

--- Send a key to Rime.  Returns nothing when Rime is not usable.
---@param code integer
---@param mask integer
---@return boolean? handled, string? commit
function M.process(code, mask)
  if not core then return nil end
  local handled, commit, composing = core.process(code, mask)
  if handled == nil then return nil end
  M.update(composing)
  return handled, commit
end

--- Select candidate `index` (0-based, on the current page).
---@return string? commit
function M.select(index)
  if not core then return nil end
  local ok, commit, composing = core.select(index)
  if ok == nil then return nil end
  M.update(composing)
  return commit
end

--- Highlight candidate `index` (0-based, on the current page).
function M.highlight(index)
  if core and M.composing and core.highlight(index) then
    M.ctx = core.context()
    return true
  end
  return false
end

--- Drop the composition.
function M.clear()
  if core and M.composing then core.clear() end
  if M.composing then M.update(false) end
end

--- Commit the raw input of the composition and return it.
---@return string?
function M.commit_raw()
  if not core or not M.composing then return nil end
  local text = core.commit()
  M.update(false)
  return text
end

---@return table?
function M.status()
  return core and core.status() or nil
end

---@param name string
---@return boolean?
function M.get_option(name)
  return core and core.get_option(name)
end

---@param name string
---@param value boolean
function M.set_option(name, value)
  if core and core.set_option(name, value) then require('rime.mode').changed() end
end

---@return { id: string, name: string }[]
function M.schemas()
  return core and core.schemas() or {}
end

function M.shutdown()
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
  if core then core.shutdown() end
  M.state = 'stopped'
end

return M
