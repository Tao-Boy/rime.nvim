if vim.g.loaded_rime then return end
vim.g.loaded_rime = true

vim.api.nvim_create_user_command('Rime', function(opts)
  require('rime').command(opts.fargs)
end, {
  nargs = '*',
  desc = 'Rime input method',
  complete = function(arglead, line)
    return require('rime').complete(arglead, line)
  end,
})

-- Mappings for users: map these, or call require('rime').toggle().
vim.keymap.set({ 'n', 'i' }, '<Plug>(rime-toggle)', function()
  require('rime').toggle()
end, { desc = 'Toggle Rime input' })
vim.keymap.set({ 'n', 'i' }, '<Plug>(rime-ascii)', function()
  require('rime').toggle_ascii()
end, { desc = "Toggle Rime's ASCII mode" })
