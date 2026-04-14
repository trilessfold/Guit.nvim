local config = require('guit.config')
local git = require('guit.git')
local buffer = require('guit.ui.buffer')
local show_buffer = require('guit.ui.show_buffer')

local M = {}

function M.setup(opts)
  config.setup(opts)
end

function M.log(opts)
  local cwd = (opts and opts.cwd) or vim.uv.cwd()
  local repo, err = git.repo_root(cwd)
  if not repo then
    vim.notify('guit.nvim: ' .. err, vim.log.levels.ERROR)
    return
  end

  buffer.open({ cwd = repo })
end

function M.show(commit, opts)
  if not commit or commit == '' then
    vim.notify('guit.nvim: usage :Guit show <commit_hash>', vim.log.levels.INFO)
    return
  end

  local cwd = (opts and opts.cwd) or vim.uv.cwd()
  local repo, err = git.repo_root(cwd)
  if not repo then
    vim.notify('guit.nvim: ' .. err, vim.log.levels.ERROR)
    return
  end

  show_buffer.open(vim.tbl_extend('force', opts or {}, { cwd = repo, commit = commit }))
end

function M.command(args)
  local sub = args[1]
  if sub == 'log' then
    return M.log()
  elseif sub == 'show' then
    return M.show(args[2])
  end

  vim.notify('guit.nvim: usage :Guit log | :Guit show <commit_hash>', vim.log.levels.INFO)
end

return M
