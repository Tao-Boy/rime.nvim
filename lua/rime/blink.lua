-- blink.cmp source showing Rime's candidates.
--
-- rime.nvim registers it as provider `rime` (config.blink.provider) and
-- opens the menu with only this provider while composing, so it does not
-- need to be listed in blink's `sources.default`.  Accepting an item
-- selects the candidate in Rime, which commits it (and learns from it).
local source = {}

local engine = require('rime.engine')

local Text = 1 -- CompletionItemKind.Text

function source.new(opts)
  return setmetatable({ opts = opts or {} }, { __index = source })
end

function source:enabled()
  return engine.composing
end

local empty = { items = {}, is_incomplete_forward = false, is_incomplete_backward = false }

local function label(ctx, i)
  if ctx.labels and ctx.labels[i] then return ctx.labels[i] end
  local keys = ctx.select_keys
  if keys and #keys >= i then return keys:sub(i, i) end
  return tostring(i % 10)
end

function source:get_completions(context, callback)
  local ctx = engine.composing and engine.ctx
  if not ctx then return callback(empty) end
  -- The composition is not in the buffer: blink would filter the items
  -- against the word before the cursor, so make every item match it.
  local keyword = context.get_keyword and context.get_keyword() or ''
  local cursor = vim.api.nvim_win_get_cursor(0)
  local pos = { line = cursor[1] - 1, character = cursor[2] }
  local n = #ctx.candidates
  local items = {}
  for i, cand in ipairs(ctx.candidates) do
    items[i] = {
      label = cand.text,
      filterText = keyword,
      sortText = ('%04d'):format(i),
      -- Keep Rime's order whatever the fuzzy score, frecency or proximity.
      score_offset = (n - i + 1) * 1000,
      kind = Text,
      kind_name = 'Rime',
      kind_icon = label(ctx, i),
      kind_hl = 'RimeLabel',
      labelDetails = cand.comment and { description = cand.comment } or nil,
      -- Inserting nothing: previews (auto_insert) leave the buffer alone.
      textEdit = { newText = '', range = { start = pos, ['end'] = pos } },
      insertTextFormat = 1,
      data = { rime_index = i - 1 },
    }
  end
  callback({ items = items, is_incomplete_forward = true, is_incomplete_backward = true })
end

function source:execute(_, item, callback)
  local index = item.data and item.data.rime_index
  if index and engine.composing then
    local commit = engine.select(index)
    if commit then vim.api.nvim_feedkeys(commit, 'n', true) end
  end
  callback()
end

return source
