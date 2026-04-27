local M = {}

local function parse_name_status(output)
  local items = {}
  for _, line in ipairs(vim.split(output or '', '\n', { trimempty = true })) do
    local status, rest = line:match('^(%S+)%s+(.+)$')
    if status and rest then
      local path = rest
      local old_path = nil
      if status:match('^R%d+$') or status:match('^C%d+$') then
        local left, right = rest:match('^(.-)%s+(.+)$')
        old_path = left
        path = right or rest
      end
      items[#items + 1] = {
        status = status,
        path = path,
        old_path = old_path,
        kind = 'file',
        additions = 0,
        deletions = 0,
      }
    end
  end
  return items
end

local function parse_numstat(output)
  local stats = {}
  local total = { additions = 0, deletions = 0 }
  for _, line in ipairs(vim.split(output or '', '\n', { trimempty = true })) do
    local add_s, del_s, path = line:match('^(%S+)\t(%S+)\t(.+)$')
    if add_s and del_s and path then
      local additions = tonumber(add_s) or 0
      local deletions = tonumber(del_s) or 0
      stats[path] = { additions = additions, deletions = deletions }
      local prefix, old_name, new_name, suffix = path:match('^(.-){(.-)%s+=>%s+(.-)}(.*)$')
      if old_name and new_name then
        stats[prefix .. old_name .. suffix] = stats[path]
        stats[prefix .. new_name .. suffix] = stats[path]
      end
      total.additions = total.additions + additions
      total.deletions = total.deletions + deletions
    end
  end
  return stats, total
end

function M.fetch_changed_files(opts, on_done)
  local args = {
    'git', '--no-pager', 'diff', '--find-renames', '--name-status', opts.left, opts.right,
  }
  vim.system(args, { cwd = opts.cwd, text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        on_done(nil, (result.stderr or result.stdout or 'git diff --name-status failed'):gsub('%s+$', ''))
        return
      end
      on_done(parse_name_status(result.stdout))
    end)
  end)
end

function M.fetch_numstat(opts, on_done)
  local args = {
    'git', '--no-pager', 'diff', '--find-renames', '--numstat', opts.left, opts.right,
  }
  vim.system(args, { cwd = opts.cwd, text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        on_done(nil, nil, (result.stderr or result.stdout or 'git diff --numstat failed'):gsub('%s+$', ''))
        return
      end
      local stats, total = parse_numstat(result.stdout)
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

  local pending = 2
  local out = {}
  local failed = false
  local function done()
    pending = pending - 1
    if pending == 0 and not failed then
      vim.system({ 'git', 'rev-list', '--left-right', '--count', opts.left .. '...' .. opts.right }, {
        cwd = opts.cwd, text = true,
      }, function(result)
        vim.schedule(function()
          local ahead, behind = 0, 0
          if result.code == 0 then
            behind, ahead = (result.stdout or ''):match('^(%d+)%s+(%d+)')
            behind = tonumber(behind) or 0
            ahead = tonumber(ahead) or 0
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
  read_rev(opts.right, function(meta, err)
    if err and not failed then failed = true; on_done(nil, err); return end
    out.right = meta
    done()
  end)
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
