local M = {}

local ZERO_HASH = '^0+$'

local function parse_header(line)
  local hash, original, final, group = line:match('^(%S+)%s+(%d+)%s+(%d+)%s*(%d*)$')
  if not hash then
    return nil
  end
  return {
    hash = hash,
    original_line = tonumber(original),
    final_line = tonumber(final),
    group_size = tonumber(group) or 1,
  }
end

local function short_hash(hash)
  if not hash or hash:match(ZERO_HASH) then
    return '0000000'
  end
  return hash:sub(1, 7)
end

function M.parse_porcelain(output)
  local lines = {}
  local current = nil

  for _, raw in ipairs(vim.split(output or '', '\n', { plain = true, trimempty = false })) do
    if raw:sub(1, 1) == '\t' then
      if current then
        current.text = raw:sub(2)
        current.short_hash = short_hash(current.hash)
        lines[current.final_line or (#lines + 1)] = current
        current = nil
      end
    else
      local header = parse_header(raw)
      if header then
        current = header
      elseif current then
        local key, value = raw:match('^(%S+)%s*(.*)$')
        if key == 'author' then
          current.author = value
        elseif key == 'author-time' then
          current.author_time = tonumber(value)
        elseif key == 'summary' then
          current.summary = value
        elseif key == 'filename' then
          current.filename = value
        elseif key == 'previous' then
          local previous_hash, previous_path = value:match('^(%S+)%s+(.+)$')
          current.previous_hash = previous_hash
          current.previous_path = previous_path
        end
      end
    end
  end

  return lines
end

function M.annotate_blocks(lines)
  local block_id = 0
  local previous_hash = nil
  for i, item in ipairs(lines) do
    if item.hash ~= previous_hash then
      block_id = block_id + 1
      item.block_start = true
      previous_hash = item.hash
    else
      item.block_start = false
    end
    item.block_id = block_id
    item.line = i
  end
  return lines
end

function M.fetch(opts, on_done)
  local args = {
    'git',
    '--no-pager',
    'blame',
    '--line-porcelain',
  }
  if opts.rev and opts.rev ~= '' then
    args[#args + 1] = opts.rev
  end
  args[#args + 1] = '--'
  args[#args + 1] = opts.path

  vim.system(args, { cwd = opts.cwd, text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        on_done(nil, (result.stderr or result.stdout or 'git blame failed'):gsub('%s+$', ''))
        return
      end
      on_done(M.annotate_blocks(M.parse_porcelain(result.stdout)))
    end)
  end)
end

return M
