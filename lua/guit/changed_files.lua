local M = {}

local function parent_spec(commit)
  return commit .. '^'
end

function M.parent_of(commit)
  return parent_spec(commit)
end

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
      stats[path] = {
        additions = additions,
        deletions = deletions,
      }
      total.additions = total.additions + additions
      total.deletions = total.deletions + deletions
    end
  end

  return stats, total
end

function M.enrich_with_numstat(items, stats)
  for _, item in ipairs(items or {}) do
    local entry = stats and stats[item.path]
    item.additions = entry and entry.additions or 0
    item.deletions = entry and entry.deletions or 0
  end
  return items
end

function M.fetch_changed_files(opts, on_done)
  local args = {
    'git',
    '--no-pager',
    'diff-tree',
    '--root',
    '--find-renames',
    '--no-commit-id',
    '--name-status',
    '-r',
    ('--format='),
    opts.commit,
  }

  vim.system(args, {
    cwd = opts.cwd,
    text = true,
  }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        on_done(nil, (result.stderr or result.stdout or 'git diff-tree failed'):gsub('%s+$', ''))
        return
      end

      on_done(parse_name_status(result.stdout))
    end)
  end)
end

function M.fetch_numstat(opts, on_done)
  local args = {
    'git',
    '--no-pager',
    'diff-tree',
    '--root',
    '--find-renames',
    '--no-commit-id',
    '--numstat',
    '-r',
    ('--format='),
    opts.commit,
  }

  vim.system(args, {
    cwd = opts.cwd,
    text = true,
  }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        on_done(nil, nil, (result.stderr or result.stdout or 'git diff-tree --numstat failed'):gsub('%s+$', ''))
        return
      end

      local stats, total = parse_numstat(result.stdout)
      on_done(stats, total)
    end)
  end)
end

local function tree_node(name, full_path)
  return {
    name = name,
    full_path = full_path,
    kind = 'dir',
    children = {},
    _child_map = {},
    additions = 0,
    deletions = 0,
  }
end

function M.build_tree(items)
  local root = tree_node('', '')

  for _, item in ipairs(items) do
    local parts = vim.split(item.path, '/', { plain = true, trimempty = true })
    local node = root
    local prefix = ''

    for i, part in ipairs(parts) do
      local is_last = i == #parts
      prefix = prefix == '' and part or (prefix .. '/' .. part)

      if is_last then
        node.children[#node.children + 1] = {
          kind = 'file',
          name = part,
          full_path = item.path,
          status = item.status,
          old_path = item.old_path,
          additions = item.additions or 0,
          deletions = item.deletions or 0,
        }
      else
        local next_node = node._child_map[part]
        if not next_node then
          next_node = tree_node(part, prefix)
          node._child_map[part] = next_node
          node.children[#node.children + 1] = next_node
        end
        node = next_node
      end
    end
  end

  local function sort_children(node)
    table.sort(node.children, function(a, b)
      if a.kind ~= b.kind then
        return a.kind == 'dir'
      end
      return a.name < b.name
    end)
    for _, child in ipairs(node.children) do
      if child.kind == 'dir' then
        sort_children(child)
      end
    end
  end

  local function aggregate(node)
    local additions = 0
    local deletions = 0
    for _, child in ipairs(node.children) do
      if child.kind == 'dir' then
        aggregate(child)
      end
      additions = additions + (child.additions or 0)
      deletions = deletions + (child.deletions or 0)
    end
    node.additions = additions
    node.deletions = deletions
  end

  sort_children(root)
  aggregate(root)
  return root
end

function M.create_expanded_map(root, expanded)
  local map = vim.deepcopy(expanded or {})
  local function visit(node)
    for _, child in ipairs(node.children or {}) do
      if child.kind == 'dir' then
        if map[child.full_path] == nil then
          map[child.full_path] = true
        end
        visit(child)
      end
    end
  end
  visit(root)
  return map
end

function M.flatten_tree(root, expanded)
  local entries = {}

  local function visit(node, depth)
    for _, child in ipairs(node.children) do
      if child.kind == 'dir' then
        local is_expanded = expanded[child.full_path] ~= false
        entries[#entries + 1] = {
          kind = 'dir',
          depth = depth,
          name = child.name,
          full_path = child.full_path,
          expanded = is_expanded,
          additions = child.additions or 0,
          deletions = child.deletions or 0,
        }
        if is_expanded then
          visit(child, depth + 1)
        end
      else
        entries[#entries + 1] = {
          kind = 'file',
          depth = depth,
          name = child.name,
          full_path = child.full_path,
          status = child.status,
          old_path = child.old_path,
          additions = child.additions or 0,
          deletions = child.deletions or 0,
        }
      end
    end
  end

  visit(root, 0)
  return entries
end

function M.as_list(items)
  local entries = {}
  table.sort(items, function(a, b)
    return a.path < b.path
  end)

  for _, item in ipairs(items) do
    entries[#entries + 1] = {
      kind = 'file',
      depth = 0,
      name = item.path,
      full_path = item.path,
      status = item.status,
      old_path = item.old_path,
      additions = item.additions or 0,
      deletions = item.deletions or 0,
    }
  end

  return entries
end

function M.build_state(items)
  local tree = M.build_tree(items)
  local expanded = M.create_expanded_map(tree)
  return {
    tree = tree,
    expanded = expanded,
  }
end

function M.to_entries(items, mode, tree_state)
  if mode == 'list' then
    return M.as_list(items)
  end
  if not tree_state or not tree_state.tree then
    tree_state = M.build_state(items)
  end
  return M.flatten_tree(tree_state.tree, tree_state.expanded)
end

function M.toggle_dir(tree_state, full_path, expand)
  if not tree_state or not tree_state.expanded or not full_path or full_path == '' then
    return
  end
  if expand == nil then
    tree_state.expanded[full_path] = not (tree_state.expanded[full_path] ~= false)
  else
    tree_state.expanded[full_path] = expand
  end
end

function M.set_all(tree_state, expand)
  if not tree_state or not tree_state.expanded then
    return
  end
  for path, _ in pairs(tree_state.expanded) do
    tree_state.expanded[path] = expand
  end
end

function M.set_subtree(tree_state, full_path, expand)
  if not tree_state or not tree_state.tree or not tree_state.expanded or not full_path or full_path == '' then
    return
  end

  local function visit(node)
    if node.kind == 'dir' and node.full_path == full_path then
      tree_state.expanded[node.full_path] = expand
      local function walk(child)
        for _, grandchild in ipairs(child.children or {}) do
          if grandchild.kind == 'dir' then
            tree_state.expanded[grandchild.full_path] = expand
            walk(grandchild)
          end
        end
      end
      walk(node)
      return true
    end

    for _, child in ipairs(node.children or {}) do
      if child.kind == 'dir' and visit(child) then
        return true
      end
    end

    return false
  end

  visit(tree_state.tree)
end

function M.parent_dir(path)
  if not path or path == '' then
    return nil
  end
  local parent = path:match('^(.+)/[^/]+$')
  return parent
end

function M.ancestor_dirs(path)
  local dirs = {}
  local current = path
  while current and current ~= '' do
    current = M.parent_dir(current)
    if current and current ~= '' then
      table.insert(dirs, current)
    end
  end
  return dirs
end

function M.top_dir(path)
  if not path or path == '' then
    return nil
  end
  return path:match('^([^/]+)')
end

function M.expand_chain(tree_state, path)
  if not tree_state or not tree_state.expanded or not path or path == '' then
    return
  end
  local current = path
  while current and current ~= '' do
    if tree_state.expanded[current] ~= nil then
      tree_state.expanded[current] = true
    end
    current = M.parent_dir(current)
  end
end

function M.collapse_chain(tree_state, path)
  if not tree_state or not tree_state.expanded or not path or path == '' then
    return
  end
  local current = path
  while current and current ~= '' do
    if tree_state.expanded[current] ~= nil then
      tree_state.expanded[current] = false
    end
    current = M.parent_dir(current)
  end
end

return M
