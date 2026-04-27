local M = {}

local function git_toplevel(git_dir)
  if not git_dir or git_dir == '' then
    return nil
  end

  local result = vim.system({ 'git', '--git-dir', git_dir, 'rev-parse', '--show-toplevel' }, { text = true }):wait()
  if result.code == 0 then
    local top = (result.stdout or ''):gsub('%s+$', '')
    if top ~= '' then
      return top
    end
  end

  if git_dir:match('/%.git$') then
    return git_dir:gsub('/%.git$', '')
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
