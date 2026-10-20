-- Probes look at the text around the cursor and decide whether a key is
-- typed as ASCII instead of going to Rime.
local M = {}

local api = vim.api
local config = require('rime.config')

---@class rime.ProbeContext
---@field buf integer
---@field win integer
---@field row integer 0-based line of the cursor
---@field col integer 0-based byte column of the cursor
---@field line string text of the cursor line
---@field before string text of the line before the cursor
---@field key? string the key being typed (a single character), nil when only the mode is asked
---@field filetype string
---@field captures fun(self: rime.ProbeContext): string[]? tree-sitter captures at the cursor, nil without tree-sitter highlighting
---@field syntax fun(self: rime.ProbeContext): string[] syntax group names at the cursor

-- Tree-sitter / syntax lookups ---------------------------------------------

--- Position probes look at: the character before the cursor, so that the
--- end of a comment or string still counts as inside it.
local function lookup_col(ctx)
  return ctx.col > 0 and ctx.col - 1 or 0
end

--- The highlighter reparses on redraw; after keys typed since then the
--- tree is stale.  An incremental parse of the cursor line is cheap.
local function refresh_tree(ctx)
  local ok, parser = pcall(vim.treesitter.get_parser, ctx.buf)
  if ok and parser and not parser:is_valid() then
    pcall(parser.parse, parser, { ctx.row, ctx.row + 1 })
  end
end

local function captures(ctx)
  if ctx._captures == nil then
    ctx._captures = false
    -- Only use trees kept up to date by the highlighter: parsing here
    -- could take long on a big buffer.
    if vim.treesitter.highlighter.active[ctx.buf] then
      refresh_tree(ctx)
      local ok, caps = pcall(vim.treesitter.get_captures_at_pos, ctx.buf, ctx.row, lookup_col(ctx))
      if ok then
        local names = {}
        for i, cap in ipairs(caps) do
          names[i] = cap.capture
        end
        ctx._captures = names
      end
    end
  end
  return ctx._captures or nil
end

local function syntax(ctx)
  if ctx._syntax == nil then
    local names = {}
    if vim.b[ctx.buf].current_syntax or vim.bo[ctx.buf].syntax ~= '' then
      for _, id in ipairs(vim.fn.synstack(ctx.row + 1, lookup_col(ctx) + 1)) do
        table.insert(names, vim.fn.synIDattr(vim.fn.synIDtrans(id), 'name'))
        table.insert(names, vim.fn.synIDattr(id, 'name'))
      end
    end
    ctx._syntax = names
  end
  return ctx._syntax
end

local function any_match(names, patterns)
  for _, name in ipairs(names) do
    for _, pat in ipairs(patterns) do
      if name:find(pat) then return true end
    end
  end
  return false
end

--- Language of the innermost tree-sitter tree at the cursor.
local function language_at(ctx)
  if not vim.treesitter.highlighter.active[ctx.buf] then return nil end
  local ok, parser = pcall(vim.treesitter.get_parser, ctx.buf)
  if not ok or not parser then return nil end
  local col = lookup_col(ctx)
  local ok2, tree = pcall(parser.language_for_range, parser, { ctx.row, col, ctx.row, col })
  if not ok2 or not tree then return nil end
  return tree:lang(), parser:lang()
end

-- Built-in probes ------------------------------------------------------------

---@type table<string, fun(ctx: rime.ProbeContext): boolean?>
M.builtin = {}

--- After an ASCII letter, optionally followed by digits and punctuation:
--- keep typing the English word.
function M.builtin.after_ascii(ctx)
  return ctx.before:find('%a[%d%p]*$') ~= nil
end

--- After ASCII text and a space: keep typing English.
function M.builtin.space_after_ascii(ctx)
  return ctx.before:find('[%w%p] +$') ~= nil
end

--- Typing an uppercase letter.
function M.builtin.uppercase(ctx)
  return ctx.key ~= nil and ctx.key:find('^%u$') ~= nil
end

--- Typing punctuation right after an ASCII character: "a," and "1." stay ASCII.
function M.builtin.punct_after_ascii(ctx)
  return ctx.key ~= nil and ctx.key:find('^%p$') ~= nil and ctx.before:find('[%w%p]$') ~= nil
end

--- At the start of a line (only whitespace before the cursor).
function M.builtin.line_start(ctx)
  return ctx.before:find('^%s*$') ~= nil
end

local comment_or_string = { '^comment', '^string', '^character' }
local comment_captures = { '^comment' }
local string_captures = { '^string', '^character' }
local comment_or_string_syn = { 'Comment', 'String', 'Character', 'Todo' }

--- Whether the character before the cursor is the closing quote of a
--- string, i.e. the cursor is just outside it: `f("abc"|`.
local function closes_string(ctx)
  local quote = ctx.before:sub(-1)
  if quote ~= '"' and quote ~= "'" and quote ~= '`' then return false end
  local ok, node = pcall(vim.treesitter.get_node, {
    bufnr = ctx.buf,
    pos = { ctx.row, ctx.col - 1 },
    ignore_injections = false,
  })
  while ok and node do
    local t = node:type()
    if t:find('string') or t:find('char') or t:find('template') then
      local sr, sc = node:start()
      return sr < ctx.row or sc < ctx.col - 1
    end
    node = node:parent()
  end
  return false
end

--- In source code, outside comments and strings.
function M.builtin.code(ctx)
  if vim.tbl_contains(config.options.prose_filetypes, ctx.filetype) then return nil end
  local caps = captures(ctx)
  if caps then
    if any_match(caps, comment_captures) then return nil end
    if any_match(caps, string_captures) and not closes_string(ctx) then
      -- In a string, its delimiters still close it.
      return ctx.key ~= nil and ctx.key:find('^["\'`]$') ~= nil or nil
    end
    return true
  end
  if vim.bo[ctx.buf].syntax == '' then return true end
  return not any_match(syntax(ctx), comment_or_string_syn) or nil
end

local raw_captures = { '^markup%.raw' }
local raw_syntax = { 'Code', 'Raw', 'SrcBlock', 'Verbatim', 'Listing' }

--- In a code block or inline code of a prose buffer (markdown fences,
--- `code`, org source blocks, ...).
function M.builtin.code_block(ctx)
  local caps = captures(ctx)
  if caps then
    if any_match(caps, raw_captures) then return true end
    local lang, root = language_at(ctx)
    if lang and lang ~= root and not lang:find('^markdown') and not lang:find('latex') then
      -- Code injected into the buffer's language, e.g. ```lua fences.
      return not any_match(caps, comment_or_string)
    end
    return nil
  end
  return any_match(syntax(ctx), raw_syntax) or nil
end

local math_captures = { '^markup%.math' }
local math_syntax = { 'Math', 'mkdMath', 'texMathZone' }

--- In TeX math: $...$, \[...\], equation environments.
function M.builtin.math(ctx)
  if vim.fn.exists('*vimtex#syntax#in_mathzone') == 1 then
    local ok, res = pcall(vim.fn['vimtex#syntax#in_mathzone'])
    if ok and res == 1 then return true end
  end
  local caps = captures(ctx)
  if caps and any_match(caps, math_captures) then return true end
  return any_match(syntax(ctx), math_syntax) or nil
end

--- After a TeX command or inside its argument name: \alpha, \begin{...}.
function M.builtin.tex_command(ctx)
  return ctx.before:find('\\%a*$') ~= nil or ctx.before:find('\\%a+{[%w*]*$') ~= nil
end

-- Evaluation ------------------------------------------------------------------

local Context = {}
Context.__index = Context
Context.captures = captures
Context.syntax = syntax

---@param key? string
---@return rime.ProbeContext
function M.context(key)
  local win = api.nvim_get_current_win()
  local buf = api.nvim_win_get_buf(win)
  local cursor = api.nvim_win_get_cursor(win)
  local line = api.nvim_get_current_line()
  local col = cursor[2]
  return setmetatable({
    buf = buf,
    win = win,
    row = cursor[1] - 1,
    col = col,
    line = line,
    before = line:sub(1, col),
    key = key,
    filetype = vim.bo[buf].filetype,
  }, Context)
end

local resolved ---@type { name: string, fn: function }[]?
local failed = {} ---@type table<string, boolean>

local function resolve()
  if resolved then return resolved end
  resolved = {}
  for i, p in ipairs(config.options.probes) do
    if type(p) == 'string' then
      local fn = M.builtin[p]
      if fn then
        table.insert(resolved, { name = p, fn = fn })
      else
        vim.notify(('rime: unknown probe %q'):format(p), vim.log.levels.WARN)
      end
    elseif type(p) == 'function' then
      table.insert(resolved, { name = 'probes[' .. i .. ']', fn = p })
    end
  end
  return resolved
end

--- Forget the resolved probe list (after the configuration changed).
function M.reset()
  resolved = nil
  failed = {}
end

--- Whether `key` should be typed as ASCII at the cursor.  With no key,
--- whether the cursor is in an "ASCII context" (for the mode indicator).
---@param key? string
---@return boolean
function M.ascii(key)
  local list = resolve()
  if #list == 0 then return false end
  local ctx = M.context(key)
  for _, p in ipairs(list) do
    if not failed[p.name] then
      local ok, res = pcall(p.fn, ctx)
      if not ok then
        -- A broken probe must not break typing: report it once and skip it.
        failed[p.name] = true
        vim.schedule(function()
          vim.notify(('rime: probe %s failed: %s'):format(p.name, res), vim.log.levels.ERROR)
        end)
      elseif res == true or res == 'ascii' then
        return true
      elseif res == 'rime' then
        return false
      end
    end
  end
  return false
end

return M
