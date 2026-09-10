-- Minimal init for headless test runs: exposes this plugin and plenary only.
-- Runs with --noplugin, so plenary's command is registered explicitly rather
-- than by letting Neovim source every plugin on the user's runtimepath.
local root = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, 'S').source:sub(2)), ':p:h:h')
local plenary = vim.fn.expand('~/.local/share/nvim/lazy/plenary.nvim')

vim.opt.runtimepath:prepend(root)
vim.opt.swapfile = false

if vim.fn.isdirectory(plenary) == 0 then
  io.stderr:write('plenary.nvim not found at ' .. plenary .. '\n')
  vim.cmd('cquit 1')
end

vim.opt.runtimepath:append(plenary)
vim.cmd('source ' .. plenary .. '/plugin/plenary.vim')

-- Register :Guit; --noplugin would otherwise skip it.
vim.cmd('runtime! plugin/guit.lua')
