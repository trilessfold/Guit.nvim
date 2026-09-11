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

-- di inside fugitive's buffers: the :Git status list and blob objects, and dd
-- in blob objects too when diff.mode is inline. Fugitive announces a loaded
-- object with User FugitiveBlob, after its own mappings; the status buffer
-- only has its filetype.
local fugitive_group = vim.api.nvim_create_augroup('GuitFugitive', { clear = true })
vim.api.nvim_create_autocmd('FileType', {
  group = fugitive_group,
  pattern = 'fugitive',
  callback = function(args)
    require('guit.fugitive_status').attach_status(args.buf)
  end,
})
vim.api.nvim_create_autocmd('User', {
  group = fugitive_group,
  pattern = 'FugitiveBlob',
  callback = function(args)
    require('guit.fugitive_status').attach_blob(args.buf)
  end,
})

vim.api.nvim_create_user_command('Guit', function(opts)
  require('guit').command(opts.fargs, opts)
end, {
  nargs = '*',
  range = true,
  complete = function(arglead, cmdline, _)
    return require('guit.revisions').complete(arglead, cmdline, vim.uv.cwd())
  end,
})
