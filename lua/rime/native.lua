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

--- Build the C module asynchronously with make.
---@param on_done? fun(ok: boolean, msg: string)
function M.build(on_done)
  if building then
    if on_done then table.insert(building, on_done) end
    return
  end
  building = { on_done }
  local make = vim.env.MAKE or ((is_win and vim.fn.executable('mingw32-make') == 1) and 'mingw32-make' or 'make')
  local ok, err = pcall(vim.system, { make }, { cwd = M.root, text = true }, function(res)
    local callbacks = building or {}
    building = nil
    local success = res.code == 0
    local msg = success and 'built ' .. M.library
      or ('build failed (%s exited with %d):\n%s%s'):format(make, res.code, res.stdout or '', res.stderr or '')
    vim.schedule(function()
      for _, cb in ipairs(callbacks) do
        cb(success, msg)
      end
    end)
  end)
  if not ok then
    local callbacks = building
    building = nil
    for _, cb in ipairs(callbacks) do
      cb(false, ('cannot run %s: %s'):format(make, err))
    end
  end
end

return M
