local git_parse = require('guit.git_parse')

local M = {}

--- Builds the revision arguments for a git diff.
---
--- Two-dot (the default) diffs the two revisions directly. Three-dot compares
--- `right` against the merge base, which is what reviewing a branch normally
--- means; git accepts that as a single `left...right` argument.
---@param opts table { left, right, symmetric }
---@return string[]
local function range_args(opts)
  if opts.symmetric then
    return { opts.left .. '...' .. opts.right }
  end
  -- An absent right side means "against the working tree": git wants the
  -- revision alone, not an empty second argument.
  if not opts.right or opts.right == '' then
    return { opts.left }
  end
  return { opts.left, opts.right }
end

--- The merge base of a three-dot comparison, which is the revision every
--- file on the left side is actually read from: `left...right` lists what
--- `right` changed since the branches diverged, so a file diff against
--- `left` itself would show `left`'s own changes as well.
---@param opts table { cwd, left, right }
---@return string|nil base
---@return string|nil err
function M.merge_base(opts)
  local result = vim.system({ 'git', 'merge-base', opts.left, opts.right }, { cwd = opts.cwd, text = true }):wait()
  if result.code ~= 0 then
    return nil, (result.stderr or result.stdout or 'git merge-base failed'):gsub('%s+$', '')
  end
  local base = (result.stdout or ''):gsub('%s+$', '')
  if base == '' then
    return nil, 'no merge base between ' .. opts.left .. ' and ' .. opts.right
  end
  return base
end

--- Asynchronous form of |merge_base|.
function M.fetch_merge_base(opts, on_done)
  vim.system({ 'git', 'merge-base', opts.left, opts.right }, { cwd = opts.cwd, text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        on_done(nil, (result.stderr or result.stdout or 'git merge-base failed'):gsub('%s+$', ''))
        return
      end
      local base = (result.stdout or ''):gsub('%s+$', '')
      if base == '' then
        on_done(nil, 'no merge base between ' .. opts.left .. ' and ' .. opts.right)
        return
      end
      on_done(base)
    end)
  end)
end

function M.fetch_changed_files(opts, on_done)
  local args = {
    -- -z keeps paths raw; the trailing -- stops a ref that looks like a path
    -- (or like an option) from being reinterpreted by git.
    'git', '--no-pager', 'diff', '--find-renames', '--name-status', '-z',
  }
  vim.list_extend(args, range_args(opts))
  args[#args + 1] = '--'
  vim.system(args, { cwd = opts.cwd, text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        on_done(nil, (result.stderr or result.stdout or 'git diff --name-status failed'):gsub('%s+$', ''))
        return
      end
      on_done(git_parse.name_status_z(result.stdout))
    end)
  end)
end

function M.fetch_numstat(opts, on_done)
  local args = {
    'git', '--no-pager', 'diff', '--find-renames', '--numstat', '-z',
  }
  vim.list_extend(args, range_args(opts))
  args[#args + 1] = '--'
  vim.system(args, { cwd = opts.cwd, text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        on_done(nil, nil, (result.stderr or result.stdout or 'git diff --numstat failed'):gsub('%s+$', ''))
        return
      end
      local stats, total = git_parse.numstat_z(result.stdout)
      on_done(stats, total)
    end)
  end)
end

function M.fetch_meta(opts, on_done)
  local pretty = table.concat({ '%H', '%h', '%s' }, '%x1f')
  local function read_rev(rev, cb)
    vim.system({
      'git', '--no-pager', 'show', '-s', '--no-show-signature', '--color=never', ('--format=%s'):format(pretty), rev,
    }, { cwd = opts.cwd, text = true }, function(result)
      vim.schedule(function()
        if result.code ~= 0 then
          cb(nil, (result.stderr or result.stdout or ('git show failed for ' .. rev)):gsub('%s+$', ''))
          return
        end
        local parts = vim.split(result.stdout or '', '\31', { plain = true })
        cb({
          input = rev,
          hash = parts[1] or rev,
          short_hash = parts[2] or rev,
          subject = (parts[3] or ''):gsub('%s+$', ''),
        })
      end)
    end)
  end

  -- An empty right side is the working tree, which has no commit to read.
  local worktree_right = not opts.right or opts.right == ''
  local pending = worktree_right and 1 or 2
  local out = {}
  local failed = false
  local function done()
    pending = pending - 1
    if pending == 0 and not failed then
      if worktree_right then
        on_done({ left = out.left, right = { input = 'working tree' }, ahead = nil, behind = nil })
        return
      end
      vim.system({ 'git', 'rev-list', '--left-right', '--count', opts.left .. '...' .. opts.right }, {
        cwd = opts.cwd, text = true,
      }, function(result)
        vim.schedule(function()
          local ahead, behind = nil, nil
          if result.code == 0 then
            local b, a = (result.stdout or ''):match('^(%d+)%s+(%d+)')
            behind = tonumber(b)
            ahead = tonumber(a)
          end
          on_done({ left = out.left, right = out.right, ahead = ahead, behind = behind })
        end)
      end)
    end
  end

  read_rev(opts.left, function(meta, err)
    if err and not failed then failed = true; on_done(nil, err); return end
    out.left = meta
    done()
  end)
  if not worktree_right then
    read_rev(opts.right, function(meta, err)
      if err and not failed then failed = true; on_done(nil, err); return end
      out.right = meta
      done()
    end)
  end
end

function M.enrich_with_numstat(items, stats)
  for _, item in ipairs(items or {}) do
    local entry = stats and stats[item.path]
    item.additions = entry and entry.additions or 0
    item.deletions = entry and entry.deletions or 0
  end
  return items
end

return M
