local M = {}

function M.check()
  local health = vim.health
  local config = require('rime.config').options
  local native = require('rime.native')
  local engine = require('rime.engine')

  health.start('rime.nvim')
  if vim.fn.has('nvim-0.11') == 1 then
    health.ok('Neovim ' .. tostring(vim.version()))
  else
    health.error('Neovim 0.11 or newer is required')
  end

  if vim.uv.fs_stat(native.library) then
    if native.needs_build() then
      health.warn('native module is older than its sources', { 'Run :Rime build and restart Neovim' })
    else
      health.ok('native module: ' .. native.library)
    end
  else
    local cmd = native.build_commands()[1]
    if vim.fn.executable(cmd[1]) == 1 then
      health.warn('native module not built yet; it is built on first use with `' .. table.concat(cmd, ' ') .. '`', {
        'Or run :Rime build',
      })
    else
      health.error('native module missing and `make`/a C compiler not found', {
        'Install make and a C compiler, then run :Rime build',
        'On NixOS it is built through nix-shell (or nix shell) when they are missing',
      })
    end
  end

  local core, err = native.load()
  if core then
    local version, rime_version = core.version()
    health.ok('rime_core ' .. version .. (rime_version and (', librime ' .. rime_version) or ''))
  else
    health.error('cannot load the native module: ' .. tostring(err))
  end

  health.start('Rime')
  local running = engine.ready() and core
  local library = running and core.library and core.library()
  if library then
    health.ok('librime: ' .. library)
  elseif engine.librime_path() then
    health.info('librime: ' .. engine.librime_path())
  elseif vim.uv.fs_stat(native.root .. '/lib/nix-librime') then
    health.info('librime: the system one, else ' .. vim.uv.fs_realpath(native.root .. '/lib/nix-librime') .. ' (fetched by make)')
  elseif engine.is_nix() then
    health.info('librime: looked up in /nix/store when Rime starts (run :Rime build to fetch it from nixpkgs)')
  end
  local dirs = running and core.dirs() or nil
  local shared = dirs and dirs.shared or engine.shared_data_dir()
  if shared and shared ~= '' then
    health.ok('shared data: ' .. shared)
  elseif not running and vim.uv.fs_stat(native.root .. '/lib/nix-rime-data') then
    health.info('shared data: ' .. vim.uv.fs_realpath(native.root .. '/lib/nix-rime-data') .. ' (fetched by make)')
  elseif engine.is_nix() and not running then
    health.info('shared data: looked up in /nix/store when Rime starts (run :Rime build to fetch it from nixpkgs)')
  else
    health.error('no shared Rime data found', {
      'Install rime-data (e.g. rime-data-luna-pinyin, rime-prelude, rime-essay) or a configuration such as rime-ice',
      'On Nix: run :Rime build, which fetches rime-data from nixpkgs',
      'or set shared_data_dir',
    })
  end
  health.info('user data: ' .. config.user_data_dir)
  health.info('logs: ' .. config.log_dir)

  local state = engine.state
  if state == 'ready' then
    local st = engine.status() or {}
    health.ok(('running, schema %s (%s)'):format(st.schema_name or '?', st.schema_id or '?'))
  elseif state == 'error' then
    health.error('Rime failed to start: ' .. tostring(engine.error), { 'See the logs in ' .. config.log_dir })
  else
    health.info('state: ' .. state)
  end

  health.start('Candidate menu')
  if config.ui == 'blink' then
    if pcall(require, 'blink.cmp') then
      health.ok('blink.cmp found')
    else
      health.error("ui = 'blink' but blink.cmp is not installed")
    end
  else
    health.ok('built-in popup menu')
  end
end

return M
