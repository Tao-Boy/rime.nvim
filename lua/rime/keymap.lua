-- Insert-mode mappings that route keys to Rime.
--
-- Every printable ASCII key, and the keys of `config.keys`, gets a
-- buffer-local <expr> mapping.  The mapping asks Rime synchronously (a
-- key takes microseconds) and returns the committed text, so text is
-- inserted exactly like typed text: in order, with undo, dot-repeat and
-- abbreviations working.  Drawing the candidate menu is deferred to the
-- event loop (see rime.ui).
--
-- A key Rime does not want falls back to the mapping it shadows, if
-- any (autopairs, blink.cmp, <Plug> mappings, ...), or to the plain key.
local M = {}

local api = vim.api
local config = require('rime.config')
local engine = require('rime.engine')
local probe = require('rime.probe')

local DESC = 'rime.nvim'

-- Rime key names (X11 keysyms) and modifier masks.
local keysyms = {
  space = 0x20,
  grave = 0x60,
  BackSpace = 0xff08,
  Tab = 0xff09,
  Return = 0xff0d,
  Escape = 0xff1b,
  Delete = 0xffff,
  Home = 0xff50,
  Left = 0xff51,
  Up = 0xff52,
  Right = 0xff53,
  Down = 0xff54,
  Page_Up = 0xff55,
  Prior = 0xff55,
  Page_Down = 0xff56,
  Next = 0xff56,
  End = 0xff57,
  ISO_Left_Tab = 0xfe20,
  F4 = 0xffc1,
}
local masks = {
  Shift = 1,
  Lock = 2,
  Control = 4,
  Alt = 8,
  Super = 0x4000000,
  Hyper = 0x8000000,
  Meta = 0x10000000,
  Release = 0x40000000,
}

--- Parse a Rime key description such as "Control+grave" or "Shift+Tab".
---@param desc string
---@return integer? code, integer mask
function M.parse_key(desc)
  local parts = vim.split(desc, '+', { plain = true })
  local name = parts[#parts]
  if name == '' and #parts > 1 then name = '+' end
  local mask = 0
  for i = 1, #parts - 1 do
    if parts[i] ~= '' then
      local m = masks[parts[i]]
      if not m then return nil, 0 end
      mask = bit.bor(mask, m)
    end
  end
  local code = keysyms[name] or (#name == 1 and name:byte()) or tonumber(name)
  return code, mask
end

---@class rime.KeySpec
---@field lhs string
---@field keys string what to return to type the key itself
---@field raw string termcodes of lhs
---@field char? string the character, for printable keys
---@field special boolean only sent to Rime while composing
---@field code integer
---@field mask integer
---@field fn fun(): string

---@type rime.KeySpec[]
local specs = {}

--- buf -> { priors = lhs -> mapping shadowed, restore = lhs -> buffer mapping to restore }
---@type table<integer, { priors: table<string, table>, restore: table<string, table> }>
M.attached = {}

-- Fallback to shadowed mappings ----------------------------------------------

local callbacks = {} ---@type function[]

function M._run(id)
  local fn = callbacks[id]
  if fn then fn() end
end

--- Return (or feed) `keys`, the result of the shadowed mapping `m`.
local function emit(m, spec, keys)
  if m.noremap == 1 or keys == '' then return keys end
  -- The mapping wants its keys remapped, which an <expr> result cannot
  -- be: feed them.  A result starting with the key itself must not run
  -- this mapping again, so that part is fed without remapping.
  local raw = vim.keycode(keys)
  if raw:sub(1, #spec.raw) == spec.raw then
    api.nvim_feedkeys(raw:sub(#spec.raw + 1), 'mi', false)
    api.nvim_feedkeys(spec.raw, 'ni', false)
  else
    api.nvim_feedkeys(raw, 'mi', false)
  end
  return ''
end

---@param m table maparg() dictionary
---@param spec rime.KeySpec
local function fallback(m, spec)
  if m.callback then
    if m.expr == 1 then
      local ok, res = pcall(m.callback)
      if not ok or type(res) ~= 'string' then return '' end
      if m.replace_keycodes ~= 1 then res = vim.fn.keytrans(res) end
      return emit(m, spec, res)
    end
    -- Runs outside the textlock of this <expr> mapping.
    if not m._rime_id then
      table.insert(callbacks, m.callback)
      m._rime_id = #callbacks
    end
    return ('<Cmd>lua require("rime.keymap")._run(%d)<CR>'):format(m._rime_id)
  end
  if m.expr == 1 then
    local ok, res = pcall(vim.fn.eval, m.rhs)
    if not ok or type(res) ~= 'string' then return '' end
    return emit(m, spec, vim.fn.keytrans(res))
  end
  return emit(m, spec, m.rhs or '')
end

---@param spec rime.KeySpec
local function pass(spec)
  local st = M.attached[api.nvim_get_current_buf()]
  local prior = st and st.priors[spec.lhs]
  if not prior then return spec.keys end
  return fallback(prior, spec)
end

-- The hot path ----------------------------------------------------------------

---@param spec rime.KeySpec
---@return string
local function on_key(spec)
  if not engine.composing then
    if spec.special or not engine.ready() or probe.ascii(spec.char) then return pass(spec) end
  elseif config.options.ui == 'blink' then
    -- The selection may have moved in blink.cmp's menu.
    require('rime.ui.blink').sync()
  end
  local handled, commit = engine.process(spec.code, spec.mask)
  if handled == nil then return pass(spec) end
  local out = commit and (commit:gsub('<', '<lt>')) or ''
  if not handled then out = out .. pass(spec) end
  return out
end

-- Specs -----------------------------------------------------------------------

local function build_specs()
  specs = {}
  local names = { ['<'] = '<lt>', ['|'] = '<Bar>', ['\\'] = '<Bslash>' }
  for b = 0x21, 0x7e do
    local ch = string.char(b)
    local lhs = names[ch] or ch
    table.insert(specs, { lhs = lhs, keys = lhs, char = ch, special = false, code = b, mask = 0 })
  end
  for lhs, desc in pairs(config.options.keys) do
    if desc then
      local code, mask = M.parse_key(desc)
      if code then
        table.insert(specs, { lhs = lhs, keys = lhs, special = true, code = code, mask = mask })
      else
        vim.notify(('rime: unknown Rime key %q for %s'):format(desc, lhs), vim.log.levels.WARN)
      end
    end
  end
  for _, spec in ipairs(specs) do
    spec.raw = vim.keycode(spec.lhs)
    spec.fn = function()
      return on_key(spec)
    end
  end
end

-- Attaching ---------------------------------------------------------------------

--- Map the keys in the current buffer, keeping the mappings they shadow.
--- Cheap when already attached: also used to re-assert the mappings when
--- another plugin replaced some of them.
function M.attach()
  local buf = api.nvim_get_current_buf()
  if #specs == 0 then build_specs() end
  local st = M.attached[buf]
  if st then
    local n = 0
    for _, m in ipairs(api.nvim_buf_get_keymap(buf, 'i')) do
      if m.desc == DESC then n = n + 1 end
    end
    if n >= #specs then return end
  else
    if not config.options.filter(buf) then return end
    st = { priors = {}, restore = {} }
    M.attached[buf] = st
  end
  local opts = config.options
  for _, spec in ipairs(specs) do
    local m = vim.fn.maparg(spec.lhs, 'i', false, true)
    if m.desc ~= DESC then
      st.priors[spec.lhs] = next(m) and m or nil
      st.restore[spec.lhs] = m.buffer == 1 and m or nil
      api.nvim_buf_set_keymap(buf, 'i', spec.lhs, '', {
        expr = true,
        noremap = true,
        replace_keycodes = true,
        nowait = opts.nowait,
        silent = true,
        desc = DESC,
        callback = spec.fn,
      })
    end
  end
end

--- Remove the mappings from `buf` and restore the ones they replaced.
---@param buf integer
function M.detach(buf)
  local st = M.attached[buf]
  M.attached[buf] = nil
  if not st or not api.nvim_buf_is_valid(buf) then return end
  api.nvim_buf_call(buf, function()
    for _, spec in ipairs(specs) do
      if vim.fn.maparg(spec.lhs, 'i', false, true).desc == DESC then
        pcall(api.nvim_buf_del_keymap, buf, 'i', spec.lhs)
        local prior = st.restore[spec.lhs]
        if prior then pcall(vim.fn.mapset, prior) end
      end
    end
  end)
end

function M.detach_all()
  for buf in pairs(M.attached) do
    M.detach(buf)
  end
end

--- Rebuild the key list after the configuration changed.
function M.reset()
  M.detach_all()
  specs = {}
end

return M
