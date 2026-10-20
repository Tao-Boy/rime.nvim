-- The input mode at the cursor, for statuslines and `User RimeModeChanged`.
local M = {}

local api = vim.api

---@alias rime.Mode 'off'|'loading'|'ascii'|'en'|'zh'

local cache = { key = nil, value = nil }
local last = nil ---@type rime.Mode?
local pending = false

---@return rime.Mode
local function compute()
  if not require('rime').is_enabled() then return 'off' end
  local engine = require('rime.engine')
  if not engine.ready() then return 'loading' end
  if engine.get_option('ascii_mode') then return 'ascii' end
  local m = api.nvim_get_mode().mode:sub(1, 1)
  if (m == 'i' or m == 'R') and not engine.composing and require('rime.probe').ascii(nil) then return 'en' end
  return 'zh'
end

--- Current mode.  Cached per buffer state and cursor, so it is cheap to
--- call from a statusline.
---@return rime.Mode
function M.get()
  local buf = api.nvim_get_current_buf()
  local cursor = api.nvim_win_get_cursor(0)
  local key = table.concat({
    buf,
    api.nvim_buf_get_changedtick(buf),
    cursor[1],
    cursor[2],
    api.nvim_get_mode().mode,
    tostring(require('rime').is_enabled()),
    require('rime.engine').state,
    tostring(require('rime.engine').composing),
  }, ':')
  if cache.key ~= key then
    cache.key = key
    cache.value = compute()
  end
  return cache.value
end

--- Something that may change the mode happened: recompute it on the next
--- tick and fire `User RimeModeChanged` when it differs.
function M.changed()
  cache.key = nil
  if pending then return end
  pending = true
  vim.schedule(function()
    pending = false
    local mode = M.get()
    if mode == last then return end
    local prev = last
    last = mode
    api.nvim_exec_autocmds('User', {
      pattern = 'RimeModeChanged',
      data = { mode = mode, previous = prev },
      modeline = false,
    })
    vim.cmd.redrawstatus()
  end)
end

return M
