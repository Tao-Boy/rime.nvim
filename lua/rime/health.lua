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
    local cc = vim.env.CC or 'cc'
    if vim.fn.executable('make') == 1 and vim.fn.executable(cc) == 1 then
      health.warn('native module not built yet; it is built on first use', { 'Or run :Rime build' })
    else
      health.error('native module missing and `make`/a C compiler not found', {
        'Install make and a C compiler, then run :Rime build',
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
  local shared = engine.shared_data_dir()
  if shared then
    health.ok('shared data: ' .. shared)
  else
    health.error('no shared Rime data found', {
      'Install rime-data (e.g. rime-data-luna-pinyin, rime-prelude, rime-essay) or a configuration such as rime-ice',
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
