-- Candidate menu in blink.cmp.
local M = {}

local config = require('rime.config')
local engine = require('rime.engine')

local shown = false
local warned = false

local function provider()
  return config.options.blink.provider
end

--- Register the source with blink.cmp unless the user already did.
local function register()
  local ok, bconfig = pcall(require, 'blink.cmp.config')
  if not ok then return false end
  local providers = bconfig.sources and bconfig.sources.providers
  if providers and not providers[provider()] then
    local ok2, err = pcall(require('blink.cmp').add_source_provider, provider(), {
      name = 'Rime',
      module = 'rime.blink',
    })
    if not ok2 then
      vim.notify('rime: cannot register the blink.cmp source: ' .. tostring(err), vim.log.levels.ERROR)
      return false
    end
  end
  return true
end

---@param ctx table Rime context
function M.show(ctx)
  local ok, cmp = pcall(require, 'blink.cmp')
  if not ok or not register() then
    if not warned then
      warned = true
      vim.notify("rime: blink.cmp is not available, using ui = 'native'", vim.log.levels.WARN)
    end
    config.options.ui = 'native'
    return require('rime.ui.native').show(ctx)
  end
  local opts = {
    force = true,
    providers = { provider() },
    trigger_kind = 'manual',
    initial_selected_item_idx = ctx.highlighted + 1,
  }
  -- trigger.show() also refreshes an open menu, which cmp.show() skips
  -- for an unchanged provider list.
  local shown_now = pcall(function()
    require('blink.cmp.completion.windows.menu').force_auto_show()
    require('blink.cmp.completion.trigger').show(opts)
  end)
  if not shown_now then
    cmp.show({ providers = opts.providers, initial_selected_item_idx = opts.initial_selected_item_idx })
  end
  shown = true
end

function M.hide()
  if not shown then return end
  shown = false
  pcall(function()
    require('blink.cmp.completion.trigger').hide()
  end)
end

--- Before Rime handles a key: if the selection was moved in blink's menu
--- (by its own mappings), move Rime's highlight to the same candidate, so
--- that e.g. <Space> commits what the menu shows as selected.
function M.sync()
  if not shown then return end
  local list = package.loaded['blink.cmp.completion.list']
  local ctx = engine.ctx
  if not list or not ctx or not list.selected_item_idx then return end
  local item = list.items and list.items[list.selected_item_idx]
  local index = item and item.source_id == provider() and item.data and item.data.rime_index
  if index and index ~= ctx.highlighted then engine.highlight(index) end
end

return M
