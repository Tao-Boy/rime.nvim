-- Headless tests: nvim --headless -u NONE -c "luafile tests/run.lua"
-- Needs librime and the luna_pinyin schema (rime-data-luna-pinyin).
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(root)
vim.o.swapfile = false

local tmp = vim.fn.tempname()
local rime = require('rime')
local engine = require('rime.engine')

rime.setup({
  user_data_dir = tmp .. '/user',
  log_dir = tmp .. '/log',
  schema = 'luna_pinyin_simp',
  enabled = true,
})

assert(vim.wait(60000, engine.ready, 10), 'Rime did not start: ' .. tostring(engine.error))

local function print(...)
  io.stdout:write(table.concat(vim.tbl_map(tostring, { ... }), ' ') .. '\n')
  io.stdout:flush()
end

local failures, count = 0, 0
local function test(name, fn)
  count = count + 1
  if vim.env.RIME_TEST_DEBUG then print("...  " .. name) end
  vim.cmd('enew!')
  vim.bo.buftype = 'nofile'
  local ok, err = pcall(fn)
  if ok then
    print('ok   ' .. name)
  else
    failures = failures + 1
    print('FAIL ' .. name .. ': ' .. tostring(err))
  end
  engine.clear()
end

--- Type `keys` (in <> notation) as if typed, processing mappings.
local function type(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), 'tx', false)
end

--- Type `keys`, then run `fn` while still in Insert mode, then leave it.
local function while_inserting(keys, fn)
  local err
  vim.defer_fn(function()
    local ok, e = pcall(fn)
    if not ok then err = e end
    -- :stopinsert does nothing in completion mode: end it first.
    engine.clear()
    require('rime.ui').hide()
    vim.schedule(vim.cmd.stopinsert)
  end, 30)
  vim.api.nvim_feedkeys(vim.keycode(keys), 'tx!', false)
  if err then error(err, 0) end
end

local function line()
  return vim.api.nvim_get_current_line()
end

local function eq(want, got, msg)
  if want ~= got then error(('%s: expected %s, got %s'):format(msg or 'mismatch', vim.inspect(want), vim.inspect(got)), 2) end
end

local function set_probes(list)
  require('rime.config').options.probes = list
  require('rime.probe').reset()
end

test('commit with space', function()
  type('inihao <Esc>')
  eq('你好', line())
end)

test('select with digit, punctuation', function()
  type('ishijie2,<Esc>')
  eq('师姐，', line())
end)

test('highlight with <Down>, commit with <Space>', function()
  type('izhe<Down> <Esc>')
  eq('着', line())
end)

test('<CR> commits the raw input', function()
  type('inihao<CR><Esc>')
  eq('nihao', line())
end)

test('<Esc> clears the composition, then leaves insert mode', function()
  while_inserting('inihao<Esc>', function()
    eq('', line())
    eq('i', vim.api.nvim_get_mode().mode, 'still in insert mode')
  end)
end)

test('<BS> edits the composition, then the buffer', function()
  type('iab<BS><BS><BS><Esc>')
  eq('', line())
  type('ix<Esc>')
  type('a<BS><Esc>')
  eq('', line())
end)

test('digits and keys outside a composition pass through', function()
  type('i123 <Esc>')
  eq('123 ', line())
end)

test('composition is dropped when leaving insert mode', function()
  while_inserting('inihao', function()
    eq(true, engine.composing)
  end)
  eq(false, engine.composing)
  eq('', line())
end)

test("on_leave = 'commit' inserts the raw input", function()
  require('rime.config').options.on_leave = 'commit'
  -- <C-c> leaves Insert mode without going through Rime (or InsertLeave).
  vim.api.nvim_set_current_line('x')
  type('A nihao<C-c>')
  require('rime.config').options.on_leave = 'clear'
  eq('x nihao', line())
  eq(false, engine.composing)
end)

test('commit text with "<" is inserted literally', function()
  -- ascii_mode makes Rime commit punctuation as is.
  engine.set_option('ascii_punct', true)
  type('i<lt>a<Esc>')
  engine.set_option('ascii_punct', false)
  eq('<', line():sub(1, 1))
end)

test('probe after_ascii', function()
  set_probes({ 'after_ascii' })
  vim.api.nvim_set_current_line('abc')
  type('Axy nihao <Esc>')
  eq('abcxy 你好', line())
  set_probes({})
end)

test('probe uppercase', function()
  set_probes({ 'uppercase', 'after_ascii' })
  type('iHello nihao <Esc>')
  eq('Hello 你好', line())
  set_probes({})
end)

test('custom probe function and "rime" result', function()
  set_probes({
    function(ctx)
      return ctx.before:find('#$') and 'rime' or nil
    end,
    function()
      return true
    end,
  })
  type('ini#nihao <Esc>')
  eq('ni#你好', line())
  set_probes({})
end)

test('probe code (tree-sitter)', function()
  vim.bo.filetype = 'lua'
  vim.treesitter.start(0, 'lua')
  set_probes({ 'code' })
  type('ilocal x = 1 -- nihao <Esc>')
  vim.treesitter.get_parser(0):parse()
  type('olocal s = "nihao <Esc>')
  eq('local x = 1 -- 你好', vim.fn.getline(1))
  eq('local s = "你好', vim.fn.getline(2))
  set_probes({})
end)

test('probe code: after a closing quote is code', function()
  vim.bo.filetype = 'lua'
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'f("a"' })
  vim.treesitter.start(0, 'lua')
  vim.treesitter.get_parser(0):parse()
  set_probes({ 'code' })
  type('A,<Esc>')
  eq('f("a",', line())
  set_probes({})
end)

test('probe code_block (markdown fence)', function()
  vim.bo.filetype = 'markdown'
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { '```lua', 'x', '```' })
  vim.treesitter.start(0, 'markdown')
  vim.treesitter.get_parser(0):parse(true)
  set_probes({ 'code_block' })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  type('A nihao<Esc>')
  eq('x nihao', vim.fn.getline(2))
  vim.api.nvim_buf_set_lines(0, 3, 3, false, { '' })
  vim.treesitter.get_parser(0):parse(true)
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  type('Anihao <Esc>')
  eq('你好', vim.fn.getline(4))
  set_probes({})
end)

test('shadowed <expr> mapping is used when the key passes through', function()
  vim.keymap.set('i', '(', function()
    return '()<Left>'
  end, { buffer = true, expr = true })
  require('rime.keymap').attach()
  set_probes({ 'after_ascii' })
  vim.api.nvim_set_current_line('f')
  type('A(x<Esc>')
  eq('f(x)', line())
  set_probes({})
  type('o(<Esc>')
  eq('（', line())
  set_probes({})
end)

test('shadowed callback mapping is used when the key passes through', function()
  local called = false
  vim.keymap.set('i', '<Tab>', function()
    called = true
  end, { buffer = true })
  require('rime.keymap').attach()
  type('i<Tab><Esc>')
  eq(true, called)
end)

test('shadowed remapping mapping', function()
  vim.keymap.set('i', '<Plug>(test-x)', 'XX', { buffer = true })
  vim.keymap.set('i', '<C-n>', '<Plug>(test-x)', { buffer = true, remap = true })
  require('rime.keymap').attach()
  type('i<C-n><Esc>')
  eq('XX', line())
end)

test('disable restores buffer mappings, enable maps again', function()
  vim.keymap.set('i', ')', 'RP', { buffer = true, desc = 'mine' })
  require('rime.keymap').attach()
  rime.disable()
  eq('mine', vim.fn.maparg(')', 'i', false, true).desc)
  eq('', vim.fn.maparg('a', 'i'))
  type('ia)<Esc>')
  eq('aRP', line())
  rime.enable()
  type('o<Esc>')
  type('inihao <Esc>')
  eq('你好', line())
end)

test('toggle in insert mode', function()
  while_inserting('ini', function()
    rime.toggle()
    eq(false, engine.composing)
  end)
  type('ahao<Esc>')
  eq('hao', line())
  rime.toggle()
end)

test('ascii mode', function()
  rime.toggle_ascii()
  type('inihao<Esc>')
  eq('nihao', line())
  eq('ascii', rime.mode())
  rime.toggle_ascii()
end)

test('blink source items', function()
  local got
  while_inserting('inihao', function()
    require('rime.blink').new({}):get_completions({
      get_keyword = function()
        return ''
      end,
    }, function(res)
      got = res
    end)
  end)
  eq('你好', got.items[1].label)
  eq(0, got.items[1].data.rime_index)
  eq(true, got.items[1].score_offset > got.items[2].score_offset)
end)

test('key latency', function()
  local keymap = require('rime.keymap')
  keymap.attach()
  local spec_fn
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(0, 'i')) do
    if m.lhs == 'n' then spec_fn = m.callback end
  end
  assert(spec_fn, 'mapping for n')
  local t0 = vim.uv.hrtime()
  local n = 200
  for _ = 1, n do
    spec_fn()
    engine.clear()
  end
  local per = (vim.uv.hrtime() - t0) / n / 1e3
  print(('     %.1f µs per key (process + context + preedit)'):format(per))

end)

test('quitting while Rime deploys does not crash', function()
  local script = ([[
    vim.opt.rtp:prepend(%q)
    require('rime').setup({ user_data_dir = vim.fn.tempname(), full_check = true })
    require('rime.engine').start()
    vim.wait(20, function() return false end)
    vim.cmd('qa!')
  ]]):format(root)
  local file = tmp .. '/quit.lua'
  vim.fn.mkdir(tmp, 'p')
  vim.fn.writefile(vim.split(script, '\n'), file)
  local res = vim.system({ vim.v.progpath, '--headless', '-n', '-u', 'NONE', '-c', 'luafile ' .. file }):wait(60000)
  eq(0, res.code, 'exit code')
end)

print(('%d/%d passed'):format(count - failures, count))
engine.shutdown()
vim.fn.delete(tmp, 'rf')
os.exit(failures == 0 and 0 or 1)
