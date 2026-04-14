if vim.g.loaded_guit then
  return
end
vim.g.loaded_guit = 1

local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
local docdir = root .. '/doc'
pcall(vim.cmd, 'silent! helptags ' .. vim.fn.fnameescape(docdir))

vim.api.nvim_create_user_command('Guit', function(opts)
  require('guit').command(opts.fargs)
end, {
  nargs = '*',
  complete = function(_, cmdline)
    local parts = vim.split(cmdline, '%s+', { trimempty = true })
    if #parts <= 2 then
      return { 'log', 'show' }
    end
    return {}
  end,
})
