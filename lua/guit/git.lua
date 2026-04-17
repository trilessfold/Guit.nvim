local config = require('guit.config')

local M = {}

local SEP = '\31'

local function inside_repo(cwd)
  local out = vim.system({ 'git', 'rev-parse', '--show-toplevel' }, { cwd = cwd, text = true }):wait()
  if out.code ~= 0 then
    return nil, (out.stderr or out.stdout or 'Not a git repository'):gsub('%s+$', '')
  end
  return (out.stdout or ''):gsub('%s+$', '')
end

function M.repo_root(cwd)
  return inside_repo(cwd or vim.uv.cwd())
end

function M.fetch_total_count(opts, on_done)
  local args = { 'git', 'rev-list', '--count', opts.rev or 'HEAD' }
  vim.system(args, {
    cwd = opts.cwd,
    text = true,
  }, function(result)
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
  local args = {
    'git',
    '--no-pager',
    'log',
    '--date=format-local:' .. config.options.date_format,
    '--decorate=short',
    '--color=never',
    '--no-show-signature',
    ('--skip=%d'):format(opts.skip or 0),
    ('-n%d'):format(opts.limit),
    ('--pretty=format:%s'):format(config.options.git.pretty),
  }

  if opts.rev and opts.rev ~= '' then
    args[#args + 1] = opts.rev
  end

  vim.system(args, {
    cwd = opts.cwd,
    text = true,
  }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        on_done(nil, (result.stderr or result.stdout or 'git log failed'):gsub('%s+$', ''))
        return
      end

      local items = {}
      for _, line in ipairs(vim.split(result.stdout or '', '\n', { trimempty = true })) do
        local parts = vim.split(line, SEP, { plain = true })
        if #parts >= 6 then
          items[#items + 1] = {
            hash = parts[1],
            short_hash = parts[2],
            author = parts[3],
            date = parts[4],
            refs = parts[5],
            subject = parts[6],
          }
        end
      end

      on_done({
        items = items,
        eof = #items < opts.limit,
      })
    end)
  end)
end

function M.fetch_commit_meta(opts, on_done)
  local args = {
    'git',
    '--no-pager',
    'show',
    '-s',
    '--date=format-local:' .. config.options.date_format,
    '--decorate=short',
    '--color=never',
    '--no-show-signature',
    ('--format=%s'):format(table.concat({
      '%H',
      '%h',
      '%an',
      '%ad',
      '%D',
      '%s',
      '%b',
    }, '%x1f')),
    opts.commit,
  }

  vim.system(args, {
    cwd = opts.cwd,
    text = true,
  }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        on_done(nil, (result.stderr or result.stdout or 'git show failed'):gsub('%s+$', ''))
        return
      end

      local raw = result.stdout or ''
      local parts = vim.split(raw, SEP, { plain = true })
      if #parts < 7 then
        on_done(nil, 'failed to parse commit metadata')
        return
      end

      local body = table.concat(vim.list_slice(parts, 7), SEP)
      on_done({
        hash = parts[1],
        short_hash = parts[2],
        author = parts[3],
        date = parts[4],
        refs = parts[5],
        subject = parts[6],
        body = (body or ''):gsub('%s+$', ''),
      })
    end)
  end)
end

return M
