local config = require('guit.config')

local M = {}

local SEP = '\31'
local REC = '\30'

local function parse_shortstat_line(line)
  line = line or ''
  local files = tonumber((line:match('(%d+)%s+files?%s+changed'))) or 0
  local additions = tonumber((line:match('(%d+)%s+insertions?%(%+%)'))) or 0
  local deletions = tonumber((line:match('(%d+)%s+deletions?%(%-%)'))) or 0
  return files, additions, deletions
end

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
          files_changed = 0,
          additions = 0,
          deletions = 0,
        }
      end
    end
  end
  return items
end

local function parse_show_stats(output)
  local stats = {}
  local current_hash = nil

  for _, raw in ipairs(vim.split(output or '', '\n', { plain = true, trimempty = false })) do
    local line = raw or ''
    if vim.startswith(line, REC) then
      current_hash = line:sub(#REC + 1):match('^([0-9a-fA-F]+)')
      if current_hash and not stats[current_hash] then
        stats[current_hash] = { files_changed = 0, additions = 0, deletions = 0 }
      end
    elseif current_hash and line:find('changed', 1, true) then
      local f, a, d = parse_shortstat_line(line)
      if f > 0 or a > 0 or d > 0 then
        stats[current_hash] = {
          files_changed = f,
          additions = a,
          deletions = d,
        }
      end
    end
  end

  return stats
end

local function fetch_commit_stats(cwd, path, hashes, on_done)
  if not hashes or #hashes == 0 then
    on_done({})
    return
  end

  local args = { 'git', '--no-pager', 'show', '--shortstat', '--format=' .. REC .. '%H', '--color=never' }
  vim.list_extend(args, hashes)
  if path and path ~= '' then
    args[#args + 1] = '--'
    args[#args + 1] = path
  end

  vim.system(args, { cwd = cwd, text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        on_done(nil, (result.stderr or result.stdout or 'git show --shortstat failed'):gsub('%s+$', ''))
        return
      end
      on_done(parse_show_stats(result.stdout))
    end)
  end)
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
    if rel ~= '' then
      return rel
    end
  end
  return vim.fn.fnamemodify(path, ':.')
end

function M.fetch_total_count(opts, on_done)
  local args = { 'git', 'rev-list', '--count', 'HEAD', '--', opts.path }
  vim.system(args, { cwd = opts.cwd, text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        on_done(nil, (result.stderr or result.stdout or 'git rev-list failed'):gsub('%s+$', ''))
        return
      end
      local count = tonumber((result.stdout or ''):match('%d+')) or 0
      on_done(count)
    end)
  end)
end

function M.fetch_page(opts, on_done)
  local pretty = REC .. table.concat({ '%H', '%h', '%an', '%ad', '%D', '%s' }, '%x1f')
  local args = {
    'git', '--no-pager', 'log',
    '--date=format-local:' .. config.options.date_format,
    '--decorate=short',
    '--color=never',
    '--no-show-signature',
    ('--skip=%d'):format(opts.skip or 0),
    ('-n%d'):format(opts.limit),
    ('--pretty=format:%s'):format(pretty),
    '--', opts.path,
  }

  vim.system(args, { cwd = opts.cwd, text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        on_done(nil, (result.stderr or result.stdout or 'git log failed'):gsub('%s+$', ''))
        return
      end

      local items = parse_log_items(result.stdout)
      local hashes = {}
      for _, item in ipairs(items) do
        hashes[#hashes + 1] = item.hash
      end

      fetch_commit_stats(opts.cwd, opts.path, hashes, function(stats, stats_err)
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
  end)
end

return M
