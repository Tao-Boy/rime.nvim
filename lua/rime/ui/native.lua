-- Candidate menu in the built-in popup menu (|complete()|).
--
-- Items have an empty "word", so moving through the menu never changes
-- the buffer; Rime's highlighted candidate is selected with
-- nvim_select_popupmenu_item() without inserting it.
local M = {}

local api = vim.api
local config = require('rime.config')

local shown = false
local saved = nil ---@type { buf: integer, completeopt: string }?

local function label(ctx, i)
  if ctx.labels and ctx.labels[i] then return ctx.labels[i] end
  local keys = ctx.select_keys
  if keys and #keys >= i then return keys:sub(i, i) end
  return tostring(i % 10)
end

local function set_completeopt(buf)
  if saved and saved.buf == buf then return end
  saved = { buf = buf, completeopt = api.nvim_get_option_value('completeopt', { scope = 'local' }) }
  api.nvim_set_option_value('completeopt', 'menuone,noinsert,noselect', { scope = 'local' })
end

local function restore_completeopt()
  if not saved then return end
  local s = saved
  saved = nil
  if api.nvim_buf_is_valid(s.buf) then
    api.nvim_buf_call(s.buf, function()
      api.nvim_set_option_value('completeopt', s.completeopt, { scope = 'local' })
    end)
  end
end

---@param ctx table Rime context
function M.show(ctx)
  local format = config.options.native.format
  local items = {}
  for i, cand in ipairs(ctx.candidates) do
    items[i] = {
      word = '',
      abbr = format(label(ctx, i), cand),
      menu = cand.comment or '',
      empty = 1,
      dup = 1,
      user_data = i - 1,
    }
  end
  -- Page number, with "+" when more pages follow.
  items[1].kind = (ctx.page_no + 1) .. (ctx.last_page and '' or '+')
  set_completeopt(api.nvim_get_current_buf())
  vim.fn.complete(vim.fn.col('.'), items)
  if ctx.highlighted >= 0 and ctx.highlighted < #items then
    api.nvim_select_popupmenu_item(ctx.highlighted, false, false, {})
  end
  shown = true
end

function M.hide()
  if not shown then return end
  shown = false
  local mode = api.nvim_get_mode().mode:sub(1, 1)
  if (mode == 'i' or mode == 'R') and vim.fn.complete_info({ 'mode' }).mode ~= '' then
    -- End completion mode (complete() with no items would keep it).  Fed
    -- before any pending key, so it reaches completion mode, which only
    -- ends when it is processed.  Never remapped: <C-e> may be ours.
    api.nvim_feedkeys(vim.keycode('<C-e>'), 'ni', false)
  end
  restore_completeopt()
end

return M
