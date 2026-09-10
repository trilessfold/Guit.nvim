local git_parse = require('guit.git_parse')

local M = {}

local sections = {
  staged = 'Staged',
  unstaged = 'Unstaged',
  untracked = 'Untracked',
  conflicts = 'Conflicts',
}

local section_order = {
  staged = 1,
  unstaged = 2,
  untracked = 3,
  conflicts = 4,
}

local function section_path(section, path)
  return sections[section] .. '/' .. path
end

local function is_conflict(x, y)
  if x == '?' or y == '?' then
    return false
  end
  return x == 'U' or y == 'U' or (x == 'A' and y == 'A') or (x == 'D' and y == 'D')
end

local function add_item(items, section, status, path, old_path)
  items[#items + 1] = {
    section = section,
    section_label = sections[section],
    section_order = section_order[section] or 99,
    status = status,
    path = section_path(section, path),
    worktree_path = path,
    old_path = old_path,
    worktree_old_path = old_path,
    kind = 'file',
    additions = 0,
    deletions = 0,
  }
end

local function parse_porcelain_z(output)
  local items = {}
  local records = vim.split(output or '', '\0', { plain = true, trimempty = true })
  local i = 1
  while i <= #records do
    local record = records[i]
    local xy, path = record:match('^(..)%s(.+)$')
    if xy and path then
      local x, y = xy:sub(1, 1), xy:sub(2, 2)
      local old_path = nil
      if x == 'R' or x == 'C' then
        old_path = records[i + 1]
        i = i + 1
      end

      if x == '?' and y == '?' then
        add_item(items, 'untracked', '??', path)
      elseif is_conflict(x, y) then
        add_item(items, 'conflicts', xy, path, old_path)
      else
        if x ~= ' ' then
          add_item(items, 'staged', x, path, old_path)
        end
        if y ~= ' ' then
          add_item(items, 'unstaged', y, path)
        end
      end
    end
    i = i + 1
  end
  return items
end

function M.enrich_with_numstat(items, staged_stats, unstaged_stats)
  local total = { additions = 0, deletions = 0 }
  for _, item in ipairs(items or {}) do
    local stats
    if item.section == 'staged' then
      stats = staged_stats and staged_stats[item.worktree_path]
    elseif item.section == 'unstaged' then
      stats = unstaged_stats and unstaged_stats[item.worktree_path]
    end
    item.additions = stats and stats.additions or 0
    item.deletions = stats and stats.deletions or 0
    total.additions = total.additions + item.additions
    total.deletions = total.deletions + item.deletions
  end
  return total
end

function M.fetch(opts, on_done)
  vim.system({ 'git', '--no-pager', 'status', '--porcelain=v1', '-z' }, {
    cwd = opts.cwd,
    text = true,
  }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        on_done(nil, (result.stderr or result.stdout or 'git status failed'):gsub('%s+$', ''))
        return
      end
      on_done(parse_porcelain_z(result.stdout))
    end)
  end)
end

function M.fetch_numstat(opts, staged, on_done)
  -- --find-renames plus -z means a renamed file is reported under both its
  -- old and its new path, so the worktree_path lookup below always resolves.
  local args = { 'git', '--no-pager', 'diff', '--numstat', '--find-renames', '-z' }
  if staged then
    args[#args + 1] = '--cached'
  end
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

return M
