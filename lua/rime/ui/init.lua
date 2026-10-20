-- Display of the composition: the inline preedit is drawn right away,
-- the candidate menu once per event-loop tick, so a burst of keys only
-- redraws the menu once.
local M = {}

local api = vim.api
local config = require('rime.config')
local engine = require('rime.engine')

M.ns = api.nvim_create_namespace('rime')

local mark = nil ---@type { buf: integer, id: integer }?
local scheduled = false

---@return { show: fun(ctx: table), hide: fun() }
function M.menu()
  if config.options.ui == 'blink' then return require('rime.ui.blink') end
  return require('rime.ui.native')
end

local function clear_preedit()
  if mark then
    pcall(api.nvim_buf_del_extmark, mark.buf, M.ns, mark.id)
    mark = nil
  end
end

local function preedit_text(ctx)
  local kind = config.options.preedit
  if not kind then return nil end
  local text
  if kind == 'input' then
    text = ctx.input
  elseif kind == 'preview' then
    text = ctx.preview
  end
  if not text or text == '' then text = ctx.preedit end
  return text ~= '' and text or nil
end

local function draw_preedit(ctx)
  local anchor = engine.anchor
  local text = ctx and anchor and preedit_text(ctx)
  if not text then return clear_preedit() end
  local buf, row, col = anchor[1], anchor[2], anchor[3]
  if mark and mark.buf ~= buf then clear_preedit() end
  local ok, id = pcall(api.nvim_buf_set_extmark, buf, M.ns, row, col, {
    id = mark and mark.id or nil,
    virt_text = { { text, 'RimePreedit' } },
    virt_text_pos = 'inline',
    -- Keep the mark left of the cursor, so the cursor shows after it.
    right_gravity = false,
    undo_restore = false,
  })
  if ok then
    mark = { buf = buf, id = id }
  else
    clear_preedit()
  end
end

function M.render()
  scheduled = false
  local ctx = engine.ctx
  local mode = api.nvim_get_mode().mode
  local menu = M.menu()
  if ctx and engine.composing and #ctx.candidates > 0 and (mode:sub(1, 1) == 'i' or mode:sub(1, 1) == 'R') then
    menu.show(ctx)
  else
    menu.hide()
  end
end

--- Called after every change of the composition.
function M.update()
  draw_preedit(engine.composing and engine.ctx or nil)
  if not scheduled then
    scheduled = true
    vim.schedule(M.render)
  end
end

--- Remove everything at once (leaving insert mode, disabling).
function M.hide()
  clear_preedit()
  M.menu().hide()
end

return M
