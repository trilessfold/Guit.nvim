local M = {}

--- Runs one mutating git command.
---
--- Paths go in as argv entries, never interpolated into a string, so spaces,
--- quotes and non-ASCII names are safe. The trailing `--` keeps a path that
--- looks like a revision or an option from being read as one, and
--- `--literal-pathspecs` keeps one that looks like a glob from matching more
--- than itself: without it a file literally named `*.txt` would also discard
--- every other .txt file the user never selected.
---@param cwd string repository root
---@param args string[] git arguments before the paths
---@param paths string[] worktree-relative paths
---@param on_done fun(err: string|nil)
local function run(cwd, args, paths, on_done)
  if not paths or #paths == 0 then
    on_done('nothing selected')
    return
  end

  local argv = { 'git', '--literal-pathspecs' }
  vim.list_extend(argv, args)
  argv[#argv + 1] = '--'
  vim.list_extend(argv, paths)

  vim.system(argv, { cwd = cwd, text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        on_done((result.stderr or result.stdout or 'git failed'):gsub('%s+$', ''))
        return
      end
      on_done(nil)
    end)
  end)
end

--- Whether HEAD names a commit. On an unborn branch it does not, and every
--- command that restores from HEAD fails with "could not resolve HEAD".
local function has_head(cwd, on_done)
  vim.system({ 'git', 'rev-parse', '--verify', '--quiet', 'HEAD' }, { cwd = cwd, text = true }, function(result)
    vim.schedule(function()
      on_done(result.code == 0)
    end)
  end)
end

--- Removes files and directories from disk.
local function remove_from_disk(cwd, paths, on_done)
  for _, path in ipairs(paths or {}) do
    local absolute = cwd .. '/' .. path
    if vim.fn.delete(absolute, 'rf') ~= 0 then
      on_done(('failed to delete %s'):format(path))
      return
    end
  end
  on_done(nil)
end

--- Stages paths. `git add` also records deletions, so it covers every section.
function M.stage(cwd, paths, on_done)
  run(cwd, { 'add' }, paths, on_done)
end

--- Unstages paths.
---
--- `git reset HEAD` rather than `git restore --staged`: the latter fails with
--- "could not resolve HEAD" in a repository that has no commits yet, which is
--- exactly when a user is most likely to be staging things.
function M.unstage(cwd, paths, on_done)
  run(cwd, { 'reset', '-q', 'HEAD' }, paths, on_done)
end

--- Throws away unstaged changes to tracked files.
function M.discard_worktree(cwd, paths, on_done)
  run(cwd, { 'restore' }, paths, on_done)
end

--- Throws away a staged change, in both the index and the worktree.
--- For a newly added file this also removes it from disk, because HEAD has no
--- such file to restore.
---
--- Before the first commit there is no HEAD to restore from, so everything
--- staged is by definition new: it is taken out of the index and deleted.
function M.discard_staged(cwd, paths, on_done)
  if not paths or #paths == 0 then
    on_done('nothing selected')
    return
  end
  has_head(cwd, function(head)
    if head then
      run(cwd, { 'restore', '--staged', '--worktree' }, paths, on_done)
      return
    end
    run(cwd, { 'rm', '-q', '-r', '--cached', '--force' }, paths, function(err)
      if err then
        on_done(err)
        return
      end
      remove_from_disk(cwd, paths, on_done)
    end)
  end)
end

--- Resets a conflicted file to HEAD, in both the index and the worktree.
---
--- A plain `git restore` refuses an unmerged path ("path 'x' is unmerged");
--- restoring the index as well replaces the conflict entries with HEAD's.
function M.discard_conflicts(cwd, paths, on_done)
  run(cwd, { 'restore', '--staged', '--worktree' }, paths, on_done)
end

--- Deletes untracked files and directories. git has nothing to restore these
--- from, so this is a plain filesystem removal.
function M.delete_untracked(cwd, paths, on_done)
  remove_from_disk(cwd, paths, on_done)
end

return M
