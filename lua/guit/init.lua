local config = require('guit.config')
local git = require('guit.git')
local buffer = require('guit.ui.buffer')
local show_buffer = require('guit.ui.show_buffer')
local compare_buffer = require('guit.ui.compare_buffer')

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

function M.compare(left, right, opts)
  if (not left or left == '') or (not right or right == '') then
    vim.notify('guit.nvim: usage :Guit compare <left_rev> <right_rev>', vim.log.levels.INFO)
    return
  end

  local cwd = (opts and opts.cwd) or vim.uv.cwd()
  local repo, err = git.repo_root(cwd)
  if not repo then
    vim.notify('guit.nvim: ' .. err, vim.log.levels.ERROR)
    return
  end

  compare_buffer.open(vim.tbl_extend('force', opts or {}, { cwd = repo, left = left, right = right }))
end

function M.command(args)
  local sub = args[1]
  if sub == 'log' then
    return M.log()
  elseif sub == 'show' then
    return M.show(args[2])
  elseif sub == 'compare' then
    local left = args[2]
    local right = args[3]
    if left and not right then
      local a,b = left:match('^(.-)%.%.(.-)$')
      if a and b and a ~= '' and b ~= '' then
        left, right = a, b
      end
    end
    return M.compare(left, right)
  end

  vim.notify('guit.nvim: usage :Guit log | :Guit show <commit_hash> | :Guit compare <left_rev> <right_rev>', vim.log.levels.INFO)
end

return M
