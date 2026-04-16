if vim.g.loaded_guit then
  return
end
vim.g.loaded_guit = 1

local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
local docdir = root .. '/doc'
pcall(vim.cmd, 'silent! helptags ' .. vim.fn.fnameescape(docdir))

local augroup = vim.api.nvim_create_augroup('GuitHighlights', { clear = true })
vim.api.nvim_create_autocmd('ColorScheme', {
  group = augroup,
  callback = function()
    pcall(function()
      require('guit.ui.highlight').setup()
    end)
  end,
})

vim.api.nvim_create_user_command('Guit', function(opts)
  require('guit').command(opts.fargs)
end, {
  nargs = '*',
  complete = function(arglead, cmdline, _)
    return require('guit.revisions').complete(arglead, cmdline, vim.uv.cwd())
  end,
})
