-- Locates, builds and loads the rime_core C module.
local M = {}

local is_win = vim.fn.has('win32') == 1

--- Root directory of the plugin.
M.root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h:h')

local libname = is_win and 'rime_core.dll' or 'rime_core.so'
--- Whether the plugin directory can be written: not when it is installed
--- read-only, e.g. by a package.
M.writable = vim.uv.fs_access(M.root, 'W') == true
--- Directory for the module: lib/ in the plugin, or a directory in
--- stdpath('data') when the plugin is read-only.
M.lib_dir = M.writable and M.root .. '/lib' or vim.fn.stdpath('data') .. '/rime.nvim'
--- The module: the plugin's own when it has one (built by a package).
M.library = M.root .. '/lib/' .. libname
if not M.writable and not vim.uv.fs_stat(M.library) then M.library = M.lib_dir .. '/' .. libname end

local sources = { 'src/rime_core.c', 'src/rime/rime_api.h', 'Makefile' }

---@type table?
M.core = nil

local function mtime(path)
  local stat = vim.uv.fs_stat(path)
  return stat and stat.mtime.sec or nil
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

--- Command that builds the module.
---@return string[]
function M.build_command()
  local make = vim.env.MAKE or ((is_win and vim.fn.executable('mingw32-make') == 1) and 'mingw32-make' or 'make')
  local cmd = { make }
  if not M.writable then
    vim.fn.mkdir(M.lib_dir, 'p')
    table.insert(cmd, 'TARGET=' .. M.lib_dir .. '/' .. libname)
  end
  return cmd
end

local building = nil ---@type fun(ok: boolean, msg: string)[]?

--- Build the C module asynchronously with make.
---@param on_done? fun(ok: boolean, msg: string)
function M.build(on_done)
  if building then
    if on_done then table.insert(building, on_done) end
    return
  end
  building = { on_done }
  local cmd = M.build_command()
  local name = table.concat(cmd, ' ')

  local function finish(success, msg)
    local callbacks = building or {}
    building = nil
    vim.schedule(function()
      for _, cb in ipairs(callbacks) do
        cb(success, msg)
      end
    end)
  end

  local ok, err = pcall(vim.system, cmd, { cwd = M.root, text = true }, function(res)
    if res.code == 0 then return finish(true, 'built ' .. M.library) end
    finish(false, ('build failed (%s exited with %d):\n%s%s'):format(name, res.code, res.stdout or '', res.stderr or ''))
  end)
  if not ok then finish(false, ('cannot run %s: %s\nInstall make and a C compiler (gcc or clang)'):format(name, err)) end
end

return M
