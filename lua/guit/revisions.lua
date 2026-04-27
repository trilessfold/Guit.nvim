local git = require('guit.git')

local M = {}

local function unique_sorted(items)
  local seen, out = {}, {}
  for _, item in ipairs(items) do
    if item ~= '' and not seen[item] then
      seen[item] = true
      out[#out + 1] = item
    end
  end
  table.sort(out)
  return out
end

function M.list_refs(cwd)
  local repo = git.repo_root(cwd or vim.uv.cwd())
  if not repo then
    return {}
  end

  local result = vim.system({
    'git', 'for-each-ref',
    '--format=%(refname:short)',
    'refs/heads', 'refs/remotes', 'refs/tags',
  }, { cwd = repo, text = true }):wait()

  if result.code ~= 0 then
    return { 'HEAD' }
  end

  local refs = {}
  for _, line in ipairs(vim.split(result.stdout or '', '\n', { trimempty = true })) do
    refs[#refs + 1] = line
  end
  refs[#refs + 1] = 'HEAD'
  return unique_sorted(refs)
end

function M.complete_refs(arglead, cwd)
  local refs = M.list_refs(cwd)
  if not arglead or arglead == '' then
    return refs
  end
  local out = {}
  for _, ref in ipairs(refs) do
    if vim.startswith(ref, arglead) then
      out[#out + 1] = ref
    end
  end
  return out
end

function M.complete_compare(arglead, cmdline, cwd)
  local refs = M.list_refs(cwd)

  if arglead:find('%.%.') then
    local left, partial = arglead:match('^(.-)%.%.(.*)$')
    left = left or ''
    partial = partial or ''
    local out = {}
    for _, ref in ipairs(refs) do
      if partial == '' or vim.startswith(ref, partial) then
        out[#out + 1] = left .. '..' .. ref
      end
    end
    return out
  end

  return M.complete_refs(arglead, cwd)
end

local function subcommand_matches(arglead)
  return vim.tbl_filter(function(item)
    return arglead == '' or vim.startswith(item, arglead)
  end, { 'log', 'show', 'history', 'compare' })
end

function M.complete(arglead, cmdline, cwd)
  local parts = vim.split(cmdline, '%s+', { trimempty = true })
  local trailing_space = cmdline:match('%s$') ~= nil

  if #parts <= 1 then
    return subcommand_matches(arglead)
  end

  if #parts == 2 and not trailing_space then
    return subcommand_matches(arglead)
  end

  local sub = parts[2]
  if sub == 'show' then
    local items = M.complete_refs(arglead, cwd)
    if arglead == '' or vim.startswith('%', arglead) then
      table.insert(items, 1, '%')
    end
    return items
  elseif sub == 'log' then
    return M.complete_refs(arglead, cwd)
  elseif sub == 'history' then
    local items = vim.fn.getcompletion(arglead, 'file')
    if arglead == '' or vim.startswith('%', arglead) then
      table.insert(items, 1, '%')
    end
    return items
  elseif sub == 'compare' then
    return M.complete_compare(arglead, cmdline, cwd)
  end
  return {}
end

return M
