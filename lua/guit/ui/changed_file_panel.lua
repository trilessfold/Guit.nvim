local changed_files = require('guit.changed_files')

local M = {}

function M.current_index(state)
  if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
    return nil
  end
  local line = vim.api.nvim_win_get_cursor(state.winid)[1] - (state.entry_offset or 0)
  if line < 1 then
    return nil
  end
  return line
end

function M.current_entry(state)
  local idx = M.current_index(state)
  if not idx then
    return nil, nil
  end
  return state.entries[idx], idx
end

function M.in_entries_area(state)
  if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
    return false
  end
  return vim.api.nvim_win_get_cursor(state.winid)[1] > (state.entry_offset or 0)
end

function M.set_cursor(state, index)
  if not state.winid or not vim.api.nvim_win_is_valid(state.winid) or #state.entries == 0 then
    return
  end
  local line = math.max(1, math.min(index, #state.entries)) + (state.entry_offset or 0)
  vim.api.nvim_win_set_cursor(state.winid, { line, 0 })
end

function M.current_dir_target(state)
  local entry = M.current_entry(state)
  if not entry then
    return nil
  end
  if entry.kind == 'dir' then
    return entry.full_path
  end
  return changed_files.parent_dir(entry.full_path)
end

function M.find_entry_index(state, predicate)
  for i, entry in ipairs(state.entries) do
    if predicate(entry, i) then
      return i, entry
    end
  end
  return nil, nil
end

function M.find_first_child_index(state, dir_path)
  if not dir_path or dir_path == '' then
    return nil, nil
  end
  local prefix = dir_path .. '/'
  local dir_depth = select(2, dir_path:gsub('/', ''))
  return M.find_entry_index(state, function(entry)
    return entry.full_path:sub(1, #prefix) == prefix and entry.depth == dir_depth + 1
  end)
end

function M.find_parent_index(state, entry)
  if not entry then
    return nil, nil
  end
  local parent = changed_files.parent_dir(entry.full_path)
  if not parent then
    return nil, nil
  end
  return M.find_entry_index(state, function(candidate)
    return candidate.kind == 'dir' and candidate.full_path == parent
  end)
end

function M.find_top_ancestor_index(state, entry)
  if not entry then
    return nil, nil
  end
  local top = changed_files.top_dir(entry.full_path)
  if not top then
    return nil, nil
  end
  return M.find_entry_index(state, function(candidate)
    return candidate.kind == 'dir' and candidate.full_path == top
  end)
end

function M.find_sibling_index(state, idx, delta)
  local entry = state.entries[idx]
  if not entry then
    return nil, nil
  end
  local target_depth = entry.depth
  local parent = changed_files.parent_dir(entry.full_path) or ''
  local step = delta > 0 and 1 or -1
  local i = idx + step

  while i >= 1 and i <= #state.entries do
    local candidate = state.entries[i]
    local candidate_parent = changed_files.parent_dir(candidate.full_path) or ''
    if candidate.depth < target_depth then
      return nil, nil
    end
    if candidate.depth == target_depth and candidate_parent == parent then
      return i, candidate
    end
    i = i + step
  end
  return nil, nil
end

function M.restore_cursor(state, render, preferred_path)
  if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
    return
  end
  if #state.entries == 0 then
    vim.api.nvim_win_set_cursor(state.winid, { math.max(1, state.entry_offset or 1), 0 })
    return
  end

  local target = preferred_path
  if not target and state.restore and not state.restore_done then
    target = state.restore.path
  end
  if target then
    for i, entry in ipairs(state.entries) do
      if entry.full_path == target then
        vim.api.nvim_win_set_cursor(state.winid, { i + (state.entry_offset or 0), 0 })
        render.update_selected_line(state)
        state.restore_done = true
        return
      end
    end
  end

  local cursor = vim.api.nvim_win_get_cursor(state.winid)[1]
  local current = cursor - (state.entry_offset or 0)
  if state.restore and not state.restore_done and state.restore.line then
    current = state.restore.line
  end
  local line = math.max(1, math.min(current > 0 and current or 1, #state.entries))
  vim.api.nvim_win_set_cursor(state.winid, { line + (state.entry_offset or 0), 0 })
  state.restore_done = true
  render.update_selected_line(state)
end

function M.rerender(state, render, preferred_path)
  state.entries = changed_files.to_entries(state.items, state.view_mode, state.tree_state, {
    sectioned = state.sectioned_list == true,
  })
  render.render_all(state)
  M.restore_cursor(state, render, preferred_path)
  render.update_winbar(state)
end

function M.cycle_view(state, render)
  local preferred = M.current_entry(state)
  state.view_mode = state.view_mode == 'tree' and 'list' or 'tree'
  M.rerender(state, render, preferred and preferred.full_path or nil)
end

function M.collapse_current(state, render)
  if state.view_mode ~= 'tree' then
    return
  end
  local entry = M.current_entry(state)
  if not entry then
    return
  end

  if entry.kind == 'dir' and entry.expanded then
    changed_files.toggle_dir(state.tree_state, entry.full_path, false)
    M.rerender(state, render, entry.full_path)
    return
  end

  local parent = M.current_dir_target(state)
  if parent then
    changed_files.toggle_dir(state.tree_state, parent, false)
    M.rerender(state, render, parent)
  end
end

function M.expand_current(state, render)
  if state.view_mode ~= 'tree' then
    return
  end
  local entry = M.current_entry(state)
  if not entry then
    return
  end

  if entry.kind == 'dir' then
    if not entry.expanded then
      changed_files.toggle_dir(state.tree_state, entry.full_path, true)
      M.rerender(state, render, entry.full_path)
      return
    end

    local child_idx = M.find_first_child_index(state, entry.full_path)
    if child_idx then
      M.set_cursor(state, child_idx)
      render.update_selected_line(state)
      render.update_winbar(state)
    end
    return
  end

  local parent = M.current_dir_target(state)
  if parent then
    changed_files.expand_chain(state.tree_state, parent)
    M.rerender(state, render, entry.full_path)
  end
end

function M.set_subtree(state, render, expand)
  if state.view_mode ~= 'tree' then
    return
  end
  local entry = M.current_entry(state)
  local target = M.current_dir_target(state)
  if not target then
    return
  end
  if expand then
    changed_files.expand_chain(state.tree_state, target)
  end
  changed_files.set_subtree(state.tree_state, target, expand)
  M.rerender(state, render, expand and entry and entry.full_path or target)
end

function M.set_all(state, render, expand)
  if state.view_mode ~= 'tree' then
    return
  end
  changed_files.set_all(state.tree_state, expand)
  M.rerender(state, render)
end

function M.jump_parent(state, render)
  if state.view_mode ~= 'tree' then
    return
  end
  local entry = M.current_entry(state)
  local idx = select(1, M.find_parent_index(state, entry))
  if idx then
    M.set_cursor(state, idx)
    render.update_selected_line(state)
    render.update_winbar(state)
  end
end

function M.jump_top(state, render)
  if state.view_mode ~= 'tree' then
    return
  end
  local entry = M.current_entry(state)
  local idx = select(1, M.find_top_ancestor_index(state, entry))
  if idx then
    M.set_cursor(state, idx)
    render.update_selected_line(state)
    render.update_winbar(state)
  end
end

function M.jump_sibling(state, render, delta)
  if state.view_mode ~= 'tree' then
    return
  end
  local idx = M.current_index(state)
  if not idx then
    return
  end
  local sibling_idx = select(1, M.find_sibling_index(state, idx, delta))
  if sibling_idx then
    M.set_cursor(state, sibling_idx)
    render.update_selected_line(state)
    render.update_winbar(state)
  end
end

return M
