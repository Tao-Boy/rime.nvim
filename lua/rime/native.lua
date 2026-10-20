-- Locates, builds and loads the rime_core C module.
local M = {}

local is_win = vim.fn.has('win32') == 1

--- Root directory of the plugin.
M.root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h:h')
M.library = M.root .. (is_win and '/lib/rime_core.dll' or '/lib/rime_core.so')

local sources = { 'src/rime_core.c', 'src/rime/rime_api.h', 'Makefile' }

---@type table?
M.core = nil

local function mtime(path)
  local stat = vim.uv.fs_stat(path)
  return stat and stat.mtime.sec or nil
end

--- On Nix, the links to librime and rime-data the Makefile makes in lib/
--- that are missing (none elsewhere, or with NIX=0 in the environment).
---@return string[]
function M.missing_nix_links()
  local missing = {}
  if is_win or vim.env.NIX == '0' or not vim.uv.fs_stat('/nix/store') then return missing end
  for _, name in ipairs({ 'nix-librime', 'nix-rime-data' }) do
    -- fs_stat follows the link: a link into a collected path is missing too.
    if not vim.uv.fs_stat(M.root .. '/lib/' .. name) then table.insert(missing, name) end
  end
  return missing
end

--- Whether lib/rime_core is missing or older than its sources.
function M.needs_build()
  local lib = mtime(M.library)
  if not lib then return true end
  for _, src in ipairs(sources) do
    local t = mtime(M.root .. '/' .. src)
    if t and t > lib then return true end
  end
  return false
end

---@return table? core, string? err
function M.load()
  if M.core then return M.core end
  local loader, err = package.loadlib(M.library, 'luaopen_rime_core')
  if not loader then return nil, err end
  M.core = loader()
  return M.core
end

local building = nil ---@type fun(ok: boolean, msg: string)[]?

local function executable(name)
  return vim.fn.executable(name) == 1
end

--- Commands that can build the module, to try in order.  Without make and
--- a compiler (NixOS has none by default), borrow them from Nix.
---@return string[][]
---@param args? string[] extra arguments for make
function M.build_commands(args)
  args = args or {}
  local make = vim.env.MAKE or ((is_win and executable('mingw32-make')) and 'mingw32-make' or 'make')
  local cc = vim.env.CC or 'cc'
  local list = {}
  if executable(make) and (executable(cc) or executable('gcc') or executable('clang')) then
    table.insert(list, vim.list_extend({ make }, args))
  end
  if executable('nix-shell') then
    table.insert(list, { 'nix-shell', '-p', 'gcc', 'gnumake', '--run', table.concat(vim.list_extend({ 'make' }, args), ' ') })
  end
  if executable('nix') then
    table.insert(list, vim.list_extend({
      'nix', '--extra-experimental-features', 'nix-command flakes',
      'shell', 'nixpkgs#gcc', 'nixpkgs#gnumake', 'nixpkgs#coreutils', '--command', 'make',
    }, args))
  end
  if #list == 0 then table.insert(list, vim.list_extend({ make }, args)) end
  return list
end

--- Build the C module asynchronously.
--- `on_done` receives the error output of make as third argument, also
--- on success (fetching from nixpkgs may have failed without failing make).
---@param on_done? fun(ok: boolean, msg: string, output: string)
---@param args? string[] extra arguments for make, e.g. { 'NIX=1' }
function M.build(on_done, args)
  if building then
    if on_done then table.insert(building, on_done) end
    return
  end
  building = { on_done }
  local commands = M.build_commands(args)
  local errors = {}

  local function finish(success, msg, output)
    local callbacks = building or {}
    building = nil
    vim.schedule(function()
      for _, cb in ipairs(callbacks) do
        cb(success, msg, output or '')
      end
    end)
  end

  local function try(i)
    local cmd = commands[i]
    if not cmd then return finish(false, 'build failed:\n' .. table.concat(errors, '\n')) end
    local name = table.concat(cmd, ' ')
    local ok, err = pcall(vim.system, cmd, { cwd = M.root, text = true }, function(res)
      if res.code == 0 then return finish(true, 'built ' .. M.library, res.stderr or '') end
      table.insert(errors, ('%s exited with %d:\n%s%s'):format(name, res.code, res.stdout or '', res.stderr or ''))
      vim.schedule(function()
        try(i + 1)
      end)
    end)
    if not ok then
      table.insert(errors, ('cannot run %s: %s'):format(name, err))
      try(i + 1)
    end
  end
  try(1)
end

return M
