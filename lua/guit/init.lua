local config = require('guit.config')
local git = require('guit.git')
local buffer = require('guit.ui.buffer')
local show_buffer = require('guit.ui.show_buffer')
local compare_buffer = require('guit.ui.compare_buffer')
local history_buffer = require('guit.ui.history_buffer')
local fugitive = require('guit.fugitive')

local M = {}

local function expand_current_buffer_path(path)
  if path ~= '%' then
    return path
  end

  local current = vim.fn.expand('%:p')
  if current == '' then
    return nil, 'current buffer has no file name'
  end
  return current
end

function M.setup(opts)
  config.setup(opts)
end

function M.log(rev, opts)
  if type(rev) == 'table' and opts == nil then
    opts = rev
    rev = nil
  end

  local cwd = (opts and opts.cwd) or vim.uv.cwd()
  local repo, err = git.repo_root(cwd)
  if not repo then
    vim.notify('guit.nvim: ' .. err, vim.log.levels.ERROR)
    return
  end

  buffer.open(vim.tbl_extend('force', opts or {}, { cwd = repo, rev = rev }))
end

function M.show(commit, opts)
  if not commit or commit == '' then
    vim.notify('guit.nvim: usage :Guit show <commit_hash>', vim.log.levels.INFO)
    return
  end

  local source = nil
  if commit == '%' then
    source = fugitive.from_buffer(0)
    if not source or not source.commit then
      vim.notify('guit.nvim: current buffer is not a fugitive commit object', vim.log.levels.WARN)
      return
    end
    commit = source.commit
  end

  local cwd = (opts and opts.cwd) or (source and source.cwd) or vim.uv.cwd()
  local repo, err = git.repo_root(cwd)
  if not repo then
    vim.notify('guit.nvim: ' .. err, vim.log.levels.ERROR)
    return
  end

  show_buffer.open(vim.tbl_extend('force', opts or {}, { cwd = repo, commit = commit }))
end

function M.history(path, opts)
  if not path or path == '' then
    vim.notify('guit.nvim: usage :Guit history <file_or_directory>', vim.log.levels.INFO)
    return
  end

  local expanded_path, expand_err = expand_current_buffer_path(path)
  if not expanded_path then
    vim.notify('guit.nvim: ' .. expand_err, vim.log.levels.WARN)
    return
  end
  path = expanded_path

  local cwd = (opts and opts.cwd) or vim.uv.cwd()
  local repo, err = git.repo_root(cwd)
  if not repo then
    vim.notify('guit.nvim: ' .. err, vim.log.levels.ERROR)
    return
  end

  local rel = require('guit.history').normalize_path(repo, path)
  local abs = vim.fn.fnamemodify(path, ':p')
  local stat_path = abs
  if vim.fn.filereadable(abs) == 0 and vim.fn.isdirectory(abs) == 0 then
    stat_path = repo .. '/' .. rel
  end
  local stat = vim.uv.fs_stat(stat_path)
  local is_file = stat and stat.type == 'file' or false
  history_buffer.open(vim.tbl_extend('force', opts or {}, { cwd = repo, path = rel, path_display = path, is_file = is_file }))
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
    return M.log(args[2])
  elseif sub == 'show' then
    return M.show(args[2])
  elseif sub == 'history' then
    return M.history(table.concat(vim.list_slice(args, 2), ' '))
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

  vim.notify('guit.nvim: usage :Guit log [rev] | :Guit show <rev> | :Guit history <path> | :Guit compare <left_rev> <right_rev>', vim.log.levels.INFO)
end

return M
