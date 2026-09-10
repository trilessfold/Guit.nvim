local config = require('guit.config')
local git_parse = require('guit.git_parse')

local M = {}

local SEP = '\31'
local REC = '\30'

local function parse_log_items(output)
  local items = {}
  for _, block in ipairs(vim.split(output or '', REC, { plain = true, trimempty = true })) do
    local line = (block:gsub('^\n+', '')):match('([^\n]+)')
    if line and line ~= '' then
      local meta = vim.split(line, SEP, { plain = true })
      if #meta >= 6 then
        items[#items + 1] = {
          hash = meta[1],
          short_hash = meta[2],
          author = meta[3],
          date = meta[4],
          refs = meta[5],
          subject = meta[6],
          parents = vim.split(meta[7] or '', '%s+', { trimempty = true }),
          files_changed = 0,
          additions = 0,
          deletions = 0,
        }
      end
    end
  end
  return items
end

local function parse_line_log_items(output)
  local items = {}
  for _, block in ipairs(vim.split(output or '', REC, { plain = true, trimempty = true })) do
    local line = (block:gsub('^\n+', '')):match('([^\n]+)')
    if line and line ~= '' then
      local meta = vim.split(line, SEP, { plain = true })
      if #meta >= 6 then
        local _, plus_start = block:match('\n@@ %-(%d+),?%d* %+(%d+),?%d* @@')
        items[#items + 1] = {
          hash = meta[1],
          short_hash = meta[2],
          author = meta[3],
          date = meta[4],
          refs = meta[5],
          subject = meta[6],
          files_changed = 0,
          additions = 0,
          deletions = 0,
          target_line = tonumber(plus_start),
        }
      end
    end
  end
  return items
end

local function expand_brace_path(path)
  local prefix, old_name, new_name, suffix = path:match('^(.-){(.-)%s+=>%s+(.-)}(.*)$')
  if old_name and new_name then
    return prefix .. old_name .. suffix, prefix .. new_name .. suffix
  end
  return nil, nil
end

local function path_matches(candidate, path)
  return candidate == path or vim.startswith(candidate, path .. '/')
end

local function numstat_matches_path(numstat_path, path)
  if path_matches(numstat_path, path) then
    return true
  end

  local old_path, new_path = expand_brace_path(numstat_path)
  return (old_path and path_matches(old_path, path)) or (new_path and path_matches(new_path, path)) or false
end

local function parse_show_stats(output, path)
  local stats = {}
  local current_hash = nil

  for _, raw in ipairs(vim.split(output or '', '\n', { plain = true, trimempty = false })) do
    local line = raw or ''
    if vim.startswith(line, REC) then
      current_hash = line:sub(#REC + 1):match('^([0-9a-fA-F]+)')
      if current_hash and not stats[current_hash] then
        stats[current_hash] = { files_changed = 0, additions = 0, deletions = 0 }
      end
    elseif current_hash then
      local add_s, del_s, numstat_path = line:match('^(%S+)\t(%S+)\t(.+)$')
      local match_path = type(path) == 'table' and path[current_hash] or path
      if add_s and del_s and numstat_path and match_path and numstat_matches_path(numstat_path, match_path) then
        local stat = stats[current_hash]
        stat.files_changed = stat.files_changed + 1
        stat.additions = stat.additions + (tonumber(add_s) or 0)
        stat.deletions = stat.deletions + (tonumber(del_s) or 0)
      end
    end
  end

  return stats
end

local function parse_path_changes(output, path)
  local changes = {}
  local current_hash = nil

  for _, raw in ipairs(vim.split(output or '', '\n', { plain = true, trimempty = false })) do
    local line = raw or ''
    if vim.startswith(line, REC) then
      current_hash = line:sub(#REC + 1):match('^([0-9a-fA-F]+)')
    elseif current_hash and line ~= '' then
      local status, rest = line:match('^(%S+)%s+(.+)$')
      if status and rest then
        if status:match('^R%d+$') or status:match('^C%d+$') then
          local old_path, new_path = git_parse.rename_paths(rest)
          if old_path and new_path and (new_path == path or old_path == path) then
            changes[current_hash] = { status = status, path = new_path, old_path = old_path }
          end
        elseif rest == path then
          changes[current_hash] = { status = status, path = rest }
        end
      end
    end
  end

  return changes
end

local function parse_all_path_changes(output)
  local changes = {}
  local current_hash = nil

  for _, raw in ipairs(vim.split(output or '', '\n', { plain = true, trimempty = false })) do
    local line = raw or ''
    if vim.startswith(line, REC) then
      current_hash = line:sub(#REC + 1):match('^([0-9a-fA-F]+)')
      if current_hash and not changes[current_hash] then
        changes[current_hash] = {}
      end
    elseif current_hash and line ~= '' then
      local status, rest = line:match('^(%S+)%s+(.+)$')
      if status and rest then
        if status:match('^R%d+$') or status:match('^C%d+$') then
          local old_path, new_path = git_parse.rename_paths(rest)
          if old_path and new_path then
            changes[current_hash][#changes[current_hash] + 1] = { status = status, path = new_path, old_path = old_path }
          end
        else
          changes[current_hash][#changes[current_hash] + 1] = { status = status, path = rest }
        end
      end
    end
  end

  return changes
end

local function fetch_commit_stats(cwd, path, hashes, on_done)
  if not hashes or #hashes == 0 then
    on_done({})
    return
  end

  local args = {
    'git',
    '-c', 'core.quotePath=false',
    '--no-pager',
    'show',
    '--numstat',
    '--find-renames',
    '--format=' .. REC .. '%H',
    '--color=never',
  }
  vim.list_extend(args, hashes)

  vim.system(args, { cwd = cwd, text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        on_done(nil, (result.stderr or result.stdout or 'git show --numstat failed'):gsub('%s+$', ''))
        return
      end
      on_done(parse_show_stats(result.stdout, path))
    end)
  end)
end

local function fetch_commit_path_changes(cwd, path, hashes, on_done)
  if not hashes or #hashes == 0 then
    on_done({})
    return
  end

  local args = {
    'git',
    '-c', 'core.quotePath=false',
    '--no-pager',
    'show',
    '--name-status',
    '--find-renames',
    '--format=' .. REC .. '%H',
    '--color=never',
  }
  vim.list_extend(args, hashes)

  vim.system(args, { cwd = cwd, text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        on_done(nil, (result.stderr or result.stdout or 'git show --name-status failed'):gsub('%s+$', ''))
        return
      end
      on_done(parse_path_changes(result.stdout, path))
    end)
  end)
end

local function fetch_all_commit_path_changes(cwd, hashes, on_done)
  if not hashes or #hashes == 0 then
    on_done({})
    return
  end

  local args = {
    'git',
    '-c', 'core.quotePath=false',
    '--no-pager',
    'show',
    '--name-status',
    '--find-renames',
    '--format=' .. REC .. '%H',
    '--color=never',
  }
  vim.list_extend(args, hashes)

  vim.system(args, { cwd = cwd, text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        on_done(nil, (result.stderr or result.stdout or 'git show --name-status failed'):gsub('%s+$', ''))
        return
      end
      on_done(parse_all_path_changes(result.stdout))
    end)
  end)
end

local function apply_follow_paths(items, changes, path)
  local current_path = path
  for _, item in ipairs(items) do
    item.path = current_path
    for _, change in ipairs(changes[item.hash] or {}) do
      if (change.status:match('^R%d+$') or change.status:match('^C%d+$')) and change.path == current_path then
        item.status = change.status
        item.path = change.path
        item.old_path = change.old_path
        current_path = change.old_path
        break
      elseif change.path == current_path then
        item.status = change.status
        item.path = change.path
      end
    end
  end
end

function M.normalize_path(repo, path)
  if not path or path == '' then
    return nil
  end
  local absolute = vim.fn.fnamemodify(path, ':p')
  local repo_abs = vim.fn.fnamemodify(repo, ':p')
  if vim.startswith(absolute, repo_abs) then
    local rel = absolute:sub(#repo_abs + 1)
    rel = rel:gsub('^/', '')
    rel = rel:gsub('/+$', '')
    if rel ~= '' then
      return rel
    end
  end
  return (vim.fn.fnamemodify(path, ':.'):gsub('/+$', ''))
end

local function status_records(output)
  local records = {}
  for _, record in ipairs(vim.split(output or '', '\0', { plain = true, trimempty = true })) do
    local xy, status_path = record:match('^(..) (.+)$')
    if xy and status_path then
      records[#records + 1] = { xy = xy, path = status_path }
    end
  end
  return records
end

--- Asynchronous form of |is_replaced_path|.
---
--- `git status` refreshes the index and stats the worktree, so on a large
--- repository it costs hundreds of milliseconds. It must never run on a
--- window-switch path.
function M.is_replaced_path_async(cwd, path, on_done)
  if not cwd or not path or path == '' then
    on_done(false)
    return
  end

  vim.system({ 'git', 'status', '--porcelain=v1', '-z', '--', path }, { cwd = cwd, text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        on_done(false)
        return
      end

      local deleted, untracked = false, false
      for _, record in ipairs(status_records(result.stdout)) do
        if record.path == path then
          deleted = deleted or record.xy:sub(1, 1) == 'D' or record.xy:sub(2, 2) == 'D'
          untracked = untracked or record.xy == '??'
        end
      end
      on_done(deleted and untracked)
    end)
  end)
end

function M.is_replaced_path(cwd, path)
  if not cwd or not path or path == '' then
    return false
  end

  local result = vim.system({ 'git', 'status', '--porcelain=v1', '-z', '--', path }, { cwd = cwd, text = true }):wait()
  if result.code ~= 0 then
    return false
  end

  local deleted = false
  local untracked = false
  for _, record in ipairs(status_records(result.stdout)) do
    if record.path == path then
      deleted = deleted or record.xy:sub(1, 1) == 'D' or record.xy:sub(2, 2) == 'D'
      untracked = untracked or record.xy == '??'
    end
  end
  return deleted and untracked
end

function M.fetch_total_count(opts, on_done)
  local args
  if opts.follow then
    args = { 'git', '--no-pager', 'log', '--follow', '--format=%H', opts.rev or 'HEAD', '--', opts.path }
  else
    args = { 'git', 'rev-list', '--count', opts.rev or 'HEAD', '--', opts.path }
  end
  vim.system(args, { cwd = opts.cwd, text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        on_done(nil, (result.stderr or result.stdout or 'git history count failed'):gsub('%s+$', ''))
        return
      end
      local count = nil
      if opts.follow then
        count = #vim.split(result.stdout or '', '\n', { trimempty = true })
      else
        count = tonumber((result.stdout or ''):match('%d+')) or 0
      end
      on_done(count)
    end)
  end)
end

function M.fetch_page(opts, on_done)
  -- %P (parent hashes) tells the UI whether <hash>^ resolves; it is empty
  -- for a root commit.
  local pretty = REC .. table.concat({ '%H', '%h', '%an', '%ad', '%D', '%s', '%P' }, '%x1f')
  local args = {
    'git', '-c', 'core.quotePath=false', '--no-pager', 'log',
    '--date=format-local:' .. config.options.date_format,
    '--decorate=short',
    '--color=never',
    '--no-show-signature',
    ('--skip=%d'):format(opts.skip or 0),
    ('-n%d'):format(opts.limit),
    ('--pretty=format:%s'):format(pretty),
  }

  if opts.line_range then
    vim.list_extend(args, {
      ('-L%d,%d:%s'):format(opts.line_range.start, opts.line_range.finish, opts.path),
      opts.rev or 'HEAD',
    })
  else
    if opts.follow then
      args[#args + 1] = '--follow'
    end
    vim.list_extend(args, {
      opts.rev or 'HEAD',
      '--', opts.path,
    })
  end

  vim.system(args, { cwd = opts.cwd, text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        on_done(nil, (result.stderr or result.stdout or 'git log failed'):gsub('%s+$', ''))
        return
      end

      if opts.line_range then
        local items = parse_line_log_items(result.stdout)
        for _, item in ipairs(items) do
          item.path = opts.path
          item.hide_stats = true
        end
        on_done({ items = items, eof = #items < opts.limit })
        return
      end

      local items = parse_log_items(result.stdout)
      local hashes = {}
      for _, item in ipairs(items) do
        hashes[#hashes + 1] = item.hash
      end

      if opts.follow then
        fetch_all_commit_path_changes(opts.cwd, hashes, function(changes, changes_err)
          if changes_err then
            on_done(nil, changes_err)
            return
          end

          apply_follow_paths(items, changes, opts.path)
          local path_by_hash = {}
          for _, item in ipairs(items) do
            path_by_hash[item.hash] = item.path or opts.path
          end

          fetch_commit_stats(opts.cwd, path_by_hash, hashes, function(stats, stats_err)
            if stats_err then
              on_done(nil, stats_err)
              return
            end
            for _, item in ipairs(items) do
              local st = stats[item.hash]
              if st then
                item.files_changed = st.files_changed or 0
                item.additions = st.additions or 0
                item.deletions = st.deletions or 0
              end
            end
            on_done({ items = items, eof = #items < opts.limit })
          end)
        end)
        return
      end

      fetch_commit_stats(opts.cwd, opts.path, hashes, function(stats, stats_err)
        if stats_err then
          on_done(nil, stats_err)
          return
        end

        fetch_commit_path_changes(opts.cwd, opts.path, hashes, function(changes, changes_err)
          if changes_err then
            on_done(nil, changes_err)
            return
          end

          for _, item in ipairs(items) do
            local st = stats[item.hash]
            if st then
              item.files_changed = st.files_changed or 0
              item.additions = st.additions or 0
              item.deletions = st.deletions or 0
            end

            local change = changes[item.hash]
            if change then
              item.status = change.status
              item.path = change.path
              item.old_path = change.old_path
            end
          end

          on_done({ items = items, eof = #items < opts.limit })
        end)
      end)
    end)
  end)
end

return M
