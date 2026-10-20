local M = {}

local api = vim.api
local config = require('rime.config')
local engine = require('rime.engine')

local enabled = false
local augroup = nil ---@type integer?

local function keymap()
  return require('rime.keymap')
end

local function ui()
  return require('rime.ui')
end

local function in_insert()
  local m = api.nvim_get_mode().mode:sub(1, 1)
  return m == 'i' or m == 'R'
end

--- Finish the composition when leaving insert mode or the buffer.
local function finish()
  if engine.composing then
    if config.options.on_leave == 'commit' then
      local anchor = engine.anchor
      local text = engine.commit_raw()
      if text and anchor and api.nvim_buf_is_valid(anchor[1]) then
        pcall(api.nvim_buf_set_text, anchor[1], anchor[2], anchor[3], anchor[2], anchor[3], { text })
      end
    else
      engine.clear()
    end
  end
  ui().hide()
end

local function attach()
  keymap().attach()
  -- Plugins that map keys on InsertEnter may run after us: check again.
  vim.schedule(function()
    if enabled and in_insert() then keymap().attach() end
  end)
end

local function set_highlights()
  api.nvim_set_hl(0, 'RimePreedit', { default = true, link = 'Underlined' })
  api.nvim_set_hl(0, 'RimeLabel', { default = true, link = 'Number' })
end

local function create_autocmds()
  augroup = api.nvim_create_augroup('rime', { clear = true })
  local au = function(event, opts)
    opts.group = augroup
    api.nvim_create_autocmd(event, opts)
  end
  au('InsertEnter', {
    callback = function()
      if not enabled then return end
      engine.start()
      attach()
    end,
  })
  -- ModeChanged also covers CTRL-C, which skips InsertLeave.
  au('ModeChanged', {
    pattern = { 'i:*', 'R:*' },
    callback = function()
      if not in_insert() then finish() end
    end,
  })
  au({ 'BufLeave', 'WinLeave' }, {
    callback = function()
      if engine.composing then finish() end
    end,
  })
  au('CursorMovedI', {
    callback = function()
      -- The cursor left the composition (mouse click, ...): drop it.
      local anchor = engine.anchor
      if not engine.composing or not anchor then return end
      local cursor = api.nvim_win_get_cursor(0)
      if api.nvim_get_current_buf() ~= anchor[1] or cursor[1] - 1 ~= anchor[2] or cursor[2] ~= anchor[3] then
        finish()
      end
    end,
  })
  -- Without an InsertCharPre autocommand, Insert mode inserts a run of
  -- typed characters at once, after evaluating the mappings of the keys
  -- that follow: probes and the composition anchor would see the text
  -- before the run.  Having one makes Vim insert each character first.
  au('InsertCharPre', { callback = function() end })
  au('BufWipeout', {
    callback = function(ev)
      keymap().attached[ev.buf] = nil
    end,
  })
  au('ColorScheme', { callback = set_highlights })
  au('VimLeavePre', {
    callback = function()
      if engine.state == 'starting' or engine.state == 'busy' then
        api.nvim_echo({ { 'rime: waiting for Rime to finish…' } }, false, {})
        vim.cmd.redraw()
      end
      engine.shutdown()
    end,
  })
  if config.options.mode_events then
    au({ 'InsertEnter', 'InsertLeave', 'CursorMovedI', 'BufEnter' }, {
      callback = function()
        require('rime.mode').changed()
      end,
    })
  end
end

---@param opts? rime.Config
function M.setup(opts)
  local was_enabled = enabled
  if was_enabled then M.disable() end
  config.set(opts)
  if package.loaded['rime.probe'] then require('rime.probe').reset() end
  if package.loaded['rime.keymap'] then keymap().reset() end
  set_highlights()
  create_autocmds()
  if config.options.preload then
    -- With a UI only: scripts and headless instances never need Rime.
    if #api.nvim_list_uis() > 0 then
      vim.schedule(engine.start)
    else
      api.nvim_create_autocmd('UIEnter', { group = augroup, once = true, callback = vim.schedule_wrap(engine.start) })
    end
  end
  if config.options.enabled or was_enabled then M.enable() end
end

--- Enable Chinese input.
function M.enable()
  if enabled then return end
  if not augroup then create_autocmds() end
  enabled = true
  engine.start()
  if in_insert() then attach() end
  require('rime.mode').changed()
end

--- Disable Chinese input: unmap the keys everywhere.
function M.disable()
  if not enabled then return end
  enabled = false
  finish()
  keymap().detach_all()
  require('rime.mode').changed()
end

function M.toggle()
  if enabled then
    M.disable()
  else
    M.enable()
  end
end

---@return boolean
function M.is_enabled()
  return enabled
end

--- Toggle Rime's own ASCII mode (like pressing Shift in a desktop IME).
function M.toggle_ascii()
  if not engine.ready() then return end
  if engine.composing then
    local text = engine.commit_raw()
    if text and in_insert() then api.nvim_feedkeys(text, 'n', true) end
  end
  engine.set_option('ascii_mode', not engine.get_option('ascii_mode'))
end

--- Mode at the cursor: 'off', 'loading', 'ascii', 'en' or 'zh'.
---@return rime.Mode
function M.mode()
  return require('rime.mode').get()
end

--- Label of the current mode for a statusline (see config.status).
---@return string
function M.status()
  return config.options.status[M.mode()] or ''
end

M.deploy = engine.redeploy
M.sync = engine.sync
M.schemas = engine.schemas

---@param id? string schema id; nil asks with vim.ui.select()
function M.select_schema(id)
  if id then return engine.select_schema(id) end
  local list = engine.schemas()
  if #list == 0 then return vim.notify('rime: no schema available', vim.log.levels.WARN) end
  vim.ui.select(list, {
    prompt = 'Rime schema',
    format_item = function(item)
      return ('%s (%s)'):format(item.name, item.id)
    end,
  }, function(item)
    if item then engine.select_schema(item.id) end
  end)
end

--- Rebuild the native module.
function M.build()
  require('rime.native').build(function(ok, msg)
    if ok and require('rime.native').core then msg = msg .. ' (restart Neovim to load it)' end
    vim.notify('rime: ' .. msg, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
  end)
end

local commands = {
  toggle = M.toggle,
  enable = M.enable,
  disable = M.disable,
  ascii = M.toggle_ascii,
  deploy = M.deploy,
  sync = M.sync,
  build = M.build,
  schema = function(args)
    M.select_schema(args[1])
  end,
  status = function()
    local st = engine.status()
    local lines = {
      'state: ' .. engine.state .. (engine.error and (' (' .. engine.error .. ')') or ''),
      'mode: ' .. M.mode(),
    }
    if st then
      table.insert(lines, ('schema: %s (%s)'):format(st.schema_name or '?', st.schema_id or '?'))
      table.insert(lines, 'ascii_mode: ' .. tostring(st.ascii_mode))
    end
    vim.notify(table.concat(lines, '\n'))
  end,
}

--- Implementation of :Rime.
---@param args string[]
function M.command(args)
  local name = args[1] or 'toggle'
  local fn = commands[name]
  if not fn then return vim.notify('rime: unknown subcommand ' .. name, vim.log.levels.ERROR) end
  fn(vim.list_slice(args, 2))
end

---@param arglead string
---@param line string
function M.complete(arglead, line)
  local words = vim.split(line, '%s+', { trimempty = true })
  local n = #words + (line:match('%s$') and 1 or 0)
  local items = {}
  if n <= 2 then
    items = vim.tbl_keys(commands)
  elseif words[2] == 'schema' and n == 3 then
    items = vim.tbl_map(function(s)
      return s.id
    end, engine.schemas())
  end
  table.sort(items)
  return vim.tbl_filter(function(s)
    return vim.startswith(s, arglead)
  end, items)
end

return M
