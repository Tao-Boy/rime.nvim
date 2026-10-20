local M = {}

---@alias rime.Probe string|fun(ctx: rime.ProbeContext): (boolean|string|nil)

---@class rime.Config
M.defaults = {
  -- librime -------------------------------------------------------------

  --- Directory of the shared Rime data (default.yaml, schemas, dictionaries).
  --- nil: detect /usr/share/rime-data, Homebrew, Squirrel, ...
  ---@type string?
  shared_data_dir = nil,
  --- Directory of the user data: custom yaml files, user dictionaries and
  --- the deployed build/.  Kept apart from the system IME (fcitx, ibus),
  --- whose user dictionary may be locked while it runs.
  ---@type string
  user_data_dir = vim.fn.stdpath('data') .. '/rime',
  ---@type string
  log_dir = vim.fn.stdpath('log') .. '/rime',
  --- Minimal level written to the log: 'info', 'warning', 'error' or 'fatal'.
  log_level = 'error',
  --- Path of the librime shared library; nil searches the usual names.
  ---@type string?
  librime = nil,
  --- Schema to select once Rime is up; nil keeps Rime's own choice.
  ---@type string?
  schema = nil,
  --- Check every file for changes when deploying at startup.
  full_check = false,
  --- Start Rime in the background once the UI is up, so that it is ready
  --- when first enabled.  false: start on first enable.
  preload = true,
  --- Build lib/rime_core with `make` when it is missing or out of date.
  auto_build = true,

  -- Input ----------------------------------------------------------------

  --- Enable input when Neovim starts.
  enabled = false,
  --- Only attach to buffers for which this returns true.
  ---@type fun(buf: integer): boolean
  filter = function(buf)
    return vim.bo[buf].buftype ~= 'terminal'
  end,
  --- Probes decide, from the context of the cursor, whether a key is typed
  --- as plain ASCII instead of going to Rime.  They run when no
  --- composition is in progress, in order.  A probe returns true (or
  --- 'ascii') to type ASCII, 'rime' to send the key to Rime without
  --- asking the remaining probes, and nil/false to let the next one
  --- decide.  Strings name built-in probes, see `:help rime-probes`.
  ---@type rime.Probe[]
  probes = {},
  --- Filetypes where the 'code' probe never applies.
  prose_filetypes = {
    '', 'text', 'markdown', 'org', 'norg', 'neorg', 'tex', 'plaintex', 'latex',
    'typst', 'rst', 'asciidoc', 'gitcommit', 'mail', 'help', 'quarto', 'rmd',
  },
  --- Keys sent to Rime while a composition is in progress, as
  --- { [vim key] = 'Rime key' }.  Printable ASCII always goes to Rime.
  --- Set a key to false to leave it alone.
  ---@type table<string, string|false>
  keys = {
    ['<Space>'] = 'space',
    ['<BS>'] = 'BackSpace',
    ['<C-h>'] = 'BackSpace',
    ['<Del>'] = 'Delete',
    ['<CR>'] = 'Return',
    ['<S-CR>'] = 'Shift+Return',
    ['<Esc>'] = 'Escape',
    ['<C-e>'] = 'Escape',
    ['<C-y>'] = 'space',
    ['<Tab>'] = 'Tab',
    ['<S-Tab>'] = 'Shift+ISO_Left_Tab',
    ['<Left>'] = 'Left',
    ['<Right>'] = 'Right',
    ['<Up>'] = 'Up',
    ['<Down>'] = 'Down',
    ['<C-p>'] = 'Up',
    ['<C-n>'] = 'Down',
    ['<PageUp>'] = 'Page_Up',
    ['<PageDown>'] = 'Page_Down',
    ['<Home>'] = 'Home',
    ['<End>'] = 'End',
  },
  --- Map keys with <nowait>, so that a key starting a longer insert-mode
  --- mapping (like "jk") reaches Rime immediately.
  nowait = true,
  --- What to do with an unfinished composition when leaving insert mode:
  --- 'clear' drops it, 'commit' inserts the raw input.
  on_leave = 'clear',

  -- Display ----------------------------------------------------------------

  --- Candidate menu: 'native' (the popup menu, |ins-completion-menu|) or
  --- 'blink' (blink.cmp).
  ---@type 'native'|'blink'
  ui = 'native',
  --- Inline text shown at the cursor while composing:
  --- 'preedit' (Rime's preedit, e.g. "ni hao"), 'input' (raw input),
  --- 'preview' (text that would be committed) or false.
  ---@type 'preedit'|'input'|'preview'|false
  preedit = 'preedit',
  native = {
    --- Format of a menu entry's label; receives the select label and the
    --- candidate.
    ---@type fun(label: string, cand: { text: string, comment?: string }): string
    format = function(label, cand)
      return label .. '. ' .. cand.text
    end,
  },
  blink = {
    --- Provider id registered with blink.cmp.
    provider = 'rime',
  },
  --- Labels returned by require('rime').status().
  status = {
    off = '',
    loading = '…',
    zh = '中',
    en = 'EN',
    ascii = 'A',
  },
  --- Recompute the mode (zh/en) as the cursor moves and fire
  --- `User RimeModeChanged`, e.g. to recolor the cursor.
  mode_events = false,
}

---@type rime.Config
M.options = vim.deepcopy(M.defaults)

---@param opts? table
function M.set(opts)
  opts = opts or {}
  local merged = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), opts)
  -- Lists replace, they are not merged index by index.
  for _, key in ipairs({ 'probes', 'prose_filetypes' }) do
    if opts[key] ~= nil then merged[key] = opts[key] end
  end
  M.options = merged
  return merged
end

return M
