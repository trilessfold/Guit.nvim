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

-- A directory's repository root does not change while Neovim runs, but
-- repo_root sits on hot paths (every command, every :Guit completion keystroke,
-- and every window switch while blame is open) and each miss forks a git
-- process. Memoise it.
local repo_root_cache = {}

function M.repo_root(cwd)
  cwd = cwd or vim.uv.cwd()
  local cached = repo_root_cache[cwd]
  if cached then
    return cached
  end

  local root, err = inside_repo(cwd)
  if not root then
    -- Only successes are memoised: a directory that is not a repository now
    -- may be one after `git init`, and a cached error would hide that until
    -- Neovim restarts.
    return nil, err
  end
  repo_root_cache[cwd] = root
  return root
end

--- Drops the memoised roots. Only needed if the repository layout changes
--- underneath a running session.
function M.clear_repo_root_cache()
  repo_root_cache = {}
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
    -- %P (parent hashes) is prepended rather than folded into config.git.pretty
    -- so that it sits at a known index whatever the user's display format
    -- contains; appended, a format with an extra field would shift it.
    ('--pretty=format:%%P%%x1f%s'):format(config.options.git.pretty),
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
        if #parts >= 7 then
          items[#items + 1] = {
            parents = vim.split(parts[1] or '', '%s+', { trimempty = true }),
            hash = parts[2],
            short_hash = parts[3],
            author = parts[4],
            date = parts[5],
            refs = parts[6],
            subject = parts[7],
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
      -- %P lists the parent hashes: empty for a root commit, several for a
      -- merge. Callers need it to know whether <commit>^ resolves at all.
      '%P',
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
      if #parts < 8 then
        on_done(nil, 'failed to parse commit metadata')
        return
      end

      local parents = vim.split(parts[7] or '', '%s+', { trimempty = true })
      local body = table.concat(vim.list_slice(parts, 8), SEP)
      on_done({
        hash = parts[1],
        short_hash = parts[2],
        author = parts[3],
        date = parts[4],
        refs = parts[5],
        subject = parts[6],
        parents = parents,
        body = (body or ''):gsub('%s+$', ''),
      })
    end)
  end)
end

return M
