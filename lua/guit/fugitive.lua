local M = {}

--- Reads the worktree path a linked worktree's git dir points back to.
--- `<main>/.git/worktrees/<name>/gitdir` contains "<worktree>/.git".
local function linked_worktree(git_dir)
  local gitdir_file = git_dir .. '/gitdir'
  if vim.fn.filereadable(gitdir_file) ~= 1 then
    return nil
  end

  local line = (vim.fn.readfile(gitdir_file, '', 1) or {})[1]
  if not line then
    return nil
  end

  local worktree = vim.trim(line):gsub('/%.git$', '')
  return worktree ~= '' and worktree or nil
end

local function git_toplevel(git_dir)
  if not git_dir or git_dir == '' then
    return nil
  end

  -- Derive the worktree from the git dir itself rather than asking git.
  -- `git --git-dir <dir> rev-parse --show-toplevel` inherits the *caller's* cwd
  -- for the worktree, so from an unrelated directory it succeeds and returns
  -- that unrelated directory -- a wrong answer with a zero exit code, which no
  -- fallback below would ever get to correct.
  if git_dir:match('/%.git/worktrees/[^/]+$') then
    local worktree = linked_worktree(git_dir)
    if worktree then
      return worktree
    end
  end

  if git_dir:match('/%.git$') then
    return (git_dir:gsub('/%.git$', ''))
  end

  -- Bare repository or a custom GIT_DIR: git is the only authority, and it
  -- needs a cwd that actually sits inside the repository.
  local parent = vim.fn.fnamemodify(git_dir, ':h')
  local result = vim.system(
    { 'git', '--git-dir', git_dir, 'rev-parse', '--show-toplevel' },
    { cwd = vim.fn.isdirectory(parent) == 1 and parent or nil, text = true }
  ):wait()
  if result.code == 0 then
    local top = (result.stdout or ''):gsub('%s+$', '')
    if top ~= '' then
      return top
    end
  end

  return nil
end

local function split_object(object)
  if not object or object == '' then
    return nil
  end

  local commit, path = object:match('^([^:]+):(.+)$')
  if commit and path then
    return commit, path
  end
  return object, nil
end

local function parse_with_fugitive(bufname)
  if vim.fn.exists('*FugitiveParse') ~= 1 then
    return nil
  end

  local ok, parsed = pcall(vim.fn.FugitiveParse, bufname)
  if not ok or type(parsed) ~= 'table' then
    return nil
  end

  local commit, path = split_object(parsed[1])
  local cwd = git_toplevel(parsed[2])
  if not commit or not cwd then
    return nil
  end

  return {
    commit = commit,
    path = path,
    cwd = cwd,
    git_dir = parsed[2],
  }
end

local function parse_url(bufname)
  local git_dir, commit, file = (bufname or ''):match('^fugitive://(.+)//([0-9a-fA-F]+)(/.*)$')
  if not git_dir or not commit then
    return nil
  end

  if vim.startswith(git_dir, '/') then
    git_dir = '/' .. git_dir:gsub('^/+', '')
  end

  return {
    commit = commit,
    path = file and file:gsub('^/', '') or nil,
    cwd = git_toplevel(git_dir),
    git_dir = git_dir,
  }
end

function M.from_buffer(bufnr)
  bufnr = bufnr or 0
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  if not vim.startswith(bufname, 'fugitive://') then
    return nil
  end

  return parse_with_fugitive(bufname) or parse_url(bufname)
end

return M
