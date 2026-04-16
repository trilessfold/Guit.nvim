local config = require('guit.config')
local changed_files = require('guit.changed_files')
local compare = require('guit.compare')
local highlights = require('guit.ui.highlight')
local render = require('guit.ui.compare_render')
local window = require('guit.ui.window')
local ui_util = require('guit.ui.util')
local preview = require('guit.ui.preview')

local M = {}

local function current_index(state)
  local line = vim.api.nvim_win_get_cursor(state.winid)[1] - (state.entry_offset or 0)
  if line < 1 then return nil end
  return line
end
local function current_entry(state)
  local idx = current_index(state)
  return idx and state.entries[idx] or nil, idx
end
local function current_dir_target(state)
  local entry = current_entry(state)
  if not entry then return nil end
  if entry.kind == 'dir' then return entry.full_path end
  return changed_files.parent_dir(entry.full_path)
end
local function restore_cursor(state, preferred_path)
  if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then return end
  if #state.entries == 0 then return end
  if preferred_path then
    for i, entry in ipairs(state.entries) do
      if entry.full_path == preferred_path then
        vim.api.nvim_win_set_cursor(state.winid, { i + (state.entry_offset or 0), 0 })
        render.update_selected_line(state)
        return
      end
    end
  end
  local cursor = vim.api.nvim_win_get_cursor(state.winid)[1]
  local current = cursor - (state.entry_offset or 0)
  local line = math.max(1, math.min(current > 0 and current or 1, #state.entries))
  vim.api.nvim_win_set_cursor(state.winid, { line + (state.entry_offset or 0), 0 })
  render.update_selected_line(state)
end
local function rerender(state, preferred_path)
  state.entries = changed_files.to_entries(state.items, state.view_mode, state.tree_state)
  render.render_all(state)
  restore_cursor(state, preferred_path)
  render.update_winbar(state)
end

local function open_file_diff(state, entry, keep_focus)
  if not entry or entry.kind ~= 'file' then return end
  if vim.fn.exists(':Gedit') ~= 2 or vim.fn.exists(':Gdiffsplit') ~= 2 then
    vim.notify('guit.nvim: fugitive not found (:Gedit / :Gdiffsplit unavailable)', vim.log.levels.ERROR)
    return
  end
  local ok, err = preview.with_managed_preview(state, function()
    vim.cmd(('Gedit %s:%s'):format(state.right, vim.fn.fnameescape(entry.full_path)))
    vim.cmd(('Gdiffsplit! %s:%s'):format(state.left, vim.fn.fnameescape(entry.old_path or entry.full_path)))
  end)
  if not ok then
    vim.notify('guit.nvim: failed to open compare diff in fugitive: ' .. tostring(err), vim.log.levels.ERROR)
    if keep_focus and state.winid and vim.api.nvim_win_is_valid(state.winid) then
      vim.api.nvim_set_current_win(state.winid)
    end
    return
  end
  if keep_focus and state.winid and vim.api.nvim_win_is_valid(state.winid) then
    vim.api.nvim_set_current_win(state.winid)
  end
end

local function refresh(state)
  compare.fetch_changed_files({ cwd = state.cwd, left = state.left, right = state.right }, function(items, err)
    if not vim.api.nvim_buf_is_valid(state.bufnr) then return end
    if err then vim.notify('guit.nvim: ' .. err, vim.log.levels.ERROR); return end
    state.items = items or {}
    local function apply_items()
      state.tree_state = changed_files.build_state(state.items)
      rerender(state)
    end
    if config.options.show.show_counts then
      compare.fetch_numstat({ cwd = state.cwd, left = state.left, right = state.right }, function(stats, total, stats_err)
        if not vim.api.nvim_buf_is_valid(state.bufnr) then return end
        if stats_err then
          vim.notify('guit.nvim: ' .. stats_err, vim.log.levels.WARN)
          state.summary = { additions = 0, deletions = 0 }
          apply_items()
          return
        end
        compare.enrich_with_numstat(state.items, stats or {})
        state.summary = total or { additions = 0, deletions = 0 }
        apply_items()
      end)
    else
      state.summary = nil
      apply_items()
    end
  end)
  compare.fetch_meta({ cwd = state.cwd, left = state.left, right = state.right }, function(meta, err)
    if not vim.api.nvim_buf_is_valid(state.bufnr) then return end
    if err then vim.notify('guit.nvim: ' .. err, vim.log.levels.WARN); return end
    state.meta = meta
    rerender(state, (current_entry(state) or {}).full_path)
  end)
end

local function attach_autocmds(state)
  local group = vim.api.nvim_create_augroup(('GuitCompare_%d'):format(state.bufnr), { clear = true })
  vim.api.nvim_create_autocmd({ 'CursorMoved', 'BufEnter' }, {
    group = group, buffer = state.bufnr,
    callback = function() render.update_selected_line(state); render.update_winbar(state) end,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group, buffer = state.bufnr,
    callback = function() pcall(vim.api.nvim_del_augroup_by_id, group) end,
  })
end

local function set_cursor(state, index)
  if not state.winid or not vim.api.nvim_win_is_valid(state.winid) or #state.entries == 0 then return end
  local line = math.max(1, math.min(index, #state.entries)) + (state.entry_offset or 0)
  vim.api.nvim_win_set_cursor(state.winid, { line, 0 })
end
local function find_first_child_index(state, dir_path)
  if not dir_path or dir_path == '' then return nil end
  local prefix = dir_path .. '/'
  local dir_depth = select(2, dir_path:gsub('/', ''))
  for i, entry in ipairs(state.entries) do
    if entry.full_path:sub(1, #prefix) == prefix and entry.depth == dir_depth + 1 then return i, entry end
  end
  return nil, nil
end
local function collapse_current(state)
  if state.view_mode ~= 'tree' then return end
  local entry = current_entry(state)
  if not entry then return end
  if entry.kind == 'dir' and entry.expanded then
    changed_files.toggle_dir(state.tree_state, entry.full_path, false)
    rerender(state, entry.full_path)
    return
  end
  local parent = current_dir_target(state)
  if parent then changed_files.toggle_dir(state.tree_state, parent, false); rerender(state, parent) end
end
local function expand_current(state)
  if state.view_mode ~= 'tree' then return end
  local entry = current_entry(state)
  if not entry then return end
  if entry.kind == 'dir' then
    if not entry.expanded then changed_files.toggle_dir(state.tree_state, entry.full_path, true); rerender(state, entry.full_path); return end
    local child_idx = find_first_child_index(state, entry.full_path)
    if child_idx then set_cursor(state, child_idx); render.update_selected_line(state); render.update_winbar(state) end
    return
  end
  local parent = current_dir_target(state)
  if parent then changed_files.expand_chain(state.tree_state, parent); rerender(state, entry.full_path) end
end
local function subtree(state, expand)
  if state.view_mode ~= 'tree' then return end
  local target = current_dir_target(state)
  if not target then return end
  if expand then changed_files.expand_chain(state.tree_state, target) end
  changed_files.set_subtree(state.tree_state, target, expand)
  rerender(state, target)
end
local function cycle_view(state)
  local preferred = current_entry(state)
  state.view_mode = state.view_mode == 'tree' and 'list' or 'tree'
  rerender(state, preferred and preferred.full_path or nil)
end
local function find_parent_index(state, entry)
  if not entry then return nil, nil end
  local parent = changed_files.parent_dir(entry.full_path)
  if not parent then return nil, nil end
  for i, candidate in ipairs(state.entries) do
    if candidate.kind == 'dir' and candidate.full_path == parent then
      return i, candidate
    end
  end
  return nil, nil
end
local function find_top_ancestor_index(state, entry)
  if not entry then return nil, nil end
  local target = entry.kind == 'dir' and entry.full_path or changed_files.parent_dir(entry.full_path)
  if not target then return nil, nil end
  local top = target
  while true do
    local parent = changed_files.parent_dir(top)
    if not parent then break end
    top = parent
  end
  for i, candidate in ipairs(state.entries) do
    if candidate.kind == 'dir' and candidate.full_path == top then
      return i, candidate
    end
  end
  return nil, nil
end
local function find_sibling_index(state, idx, delta)
  local entry = state.entries[idx]
  if not entry then return nil, nil end
  local target_depth = entry.depth
  local parent = changed_files.parent_dir(entry.full_path) or ''
  local i = idx + delta
  while i >= 1 and i <= #state.entries do
    local candidate = state.entries[i]
    local candidate_parent = changed_files.parent_dir(candidate.full_path) or ''
    if candidate.depth < target_depth then return nil, nil end
    if candidate.depth == target_depth and candidate_parent == parent then
      return i, candidate
    end
    i = i + delta
  end
  return nil, nil
end
local function jump_parent(state)
  if state.view_mode ~= 'tree' then return end
  local entry = current_entry(state)
  local idx = select(1, find_parent_index(state, entry))
  if idx then
    set_cursor(state, idx)
    render.update_selected_line(state)
    render.update_winbar(state)
  end
end
local function jump_top(state)
  if state.view_mode ~= 'tree' then return end
  local entry = current_entry(state)
  local idx = select(1, find_top_ancestor_index(state, entry))
  if idx then
    set_cursor(state, idx)
    render.update_selected_line(state)
    render.update_winbar(state)
  end
end
local function jump_sibling(state, delta)
  if state.view_mode ~= 'tree' then return end
  local idx = current_index(state)
  if not idx then return end
  local sibling_idx = select(1, find_sibling_index(state, idx, delta))
  if sibling_idx then
    set_cursor(state, sibling_idx)
    render.update_selected_line(state)
    render.update_winbar(state)
  end
end

local function help()
  vim.notify(table.concat({
    'Guit compare help', '',
    '  <CR>  open file diff between compared revisions and keep focus here',
    '  o     open file diff and move focus to target window',
    '  <Tab> jump to target window',
    '  [z    jump to parent directory',
    '  zP    jump to top-level directory for the current branch',
    '  zj/zJ jump to next sibling entry',
    '  zk/zK jump to previous sibling entry',
    '  t     toggle tree/list',
    '  h/l   collapse/expand current directory',
    '  H/L   collapse/expand current subtree',
    '  zM/zR collapse/expand whole tree',
    '  r     refresh',
    '  q     close pane',
  }, '\n'), vim.log.levels.INFO, { title = 'guit.nvim' })
end

local function set_keymaps(state)
  local opts = { buffer = state.bufnr, nowait = true, silent = true }
  vim.keymap.set('n', config.options.keymaps.close, function() if vim.api.nvim_win_is_valid(state.winid) then vim.api.nvim_win_close(state.winid, true) end end, opts)
  vim.keymap.set('n', config.options.keymaps.refresh, function() refresh(state) end, opts)
  vim.keymap.set('n', config.options.keymaps.focus_target, function() if state.target_winid and vim.api.nvim_win_is_valid(state.target_winid) then vim.api.nvim_set_current_win(state.target_winid) end end, opts)
  vim.keymap.set('n', config.options.keymaps.toggle_view, function() cycle_view(state) end, opts)
  vim.keymap.set('n', config.options.keymaps.collapse, function() if state.view_mode ~= 'tree' or vim.api.nvim_win_get_cursor(state.winid)[1] <= (state.entry_offset or 0) then vim.cmd('normal! h'); return end collapse_current(state) end, opts)
  vim.keymap.set('n', config.options.keymaps.expand, function() if state.view_mode ~= 'tree' or vim.api.nvim_win_get_cursor(state.winid)[1] <= (state.entry_offset or 0) then vim.cmd('normal! l'); return end expand_current(state) end, opts)
  vim.keymap.set('n', config.options.keymaps.collapse_all, function() subtree(state, false) end, opts)
  vim.keymap.set('n', config.options.keymaps.expand_all, function() subtree(state, true) end, opts)
  vim.keymap.set('n', config.options.keymaps.help, help, opts)
  vim.keymap.set('n', '<CR>', function() local entry = current_entry(state); if not entry then return end; if entry.kind == 'dir' and state.view_mode == 'tree' then changed_files.toggle_dir(state.tree_state, entry.full_path); rerender(state, entry.full_path); return end; open_file_diff(state, entry, true) end, opts)
  vim.keymap.set('n', config.options.keymaps.split, function() local entry = current_entry(state); if entry and entry.kind == 'file' then open_file_diff(state, entry, false) end end, opts)
  vim.keymap.set('n', '[z', function() jump_parent(state) end, opts)
  vim.keymap.set('n', 'zP', function() jump_top(state) end, opts)
  vim.keymap.set('n', 'zj', function() jump_sibling(state, 1) end, opts)
  vim.keymap.set('n', 'zJ', function() jump_sibling(state, 1) end, opts)
  vim.keymap.set('n', 'zk', function() jump_sibling(state, -1) end, opts)
  vim.keymap.set('n', 'zK', function() jump_sibling(state, -1) end, opts)
  vim.keymap.set('n', 'zM', function() changed_files.set_all(state.tree_state, false); rerender(state) end, opts)
  vim.keymap.set('n', 'zR', function() changed_files.set_all(state.tree_state, true); rerender(state) end, opts)
end

function M.open(opts)
  highlights.setup()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = 'nofile'; vim.bo[bufnr].bufhidden = 'wipe'; vim.bo[bufnr].swapfile = false; vim.bo[bufnr].filetype = 'guitcompare'; vim.bo[bufnr].modifiable = false; vim.bo[bufnr].readonly = true
  local winid = opts.reuse_winid
  local target_winid = opts.target_winid
  if winid and vim.api.nvim_win_is_valid(winid) then
    ui_util.with_winfixbuf_disabled(winid, function() vim.api.nvim_win_set_buf(winid, bufnr) end)
    vim.api.nvim_set_current_win(winid)
  else
    winid, target_winid = window.open_bottom_pane(bufnr)
  end
  local state = {
    bufnr = bufnr, winid = winid, target_winid = target_winid, cwd = opts.cwd,
    left = opts.left, right = opts.right,
    ns = vim.api.nvim_create_namespace(('guit-compare-%d'):format(bufnr)),
    selection_ns = vim.api.nvim_create_namespace(('guit-compare-select-%d'):format(bufnr)),
    view_mode = opts.view_mode or config.options.show.default_view,
    items = {}, entries = {}, tree_state = nil, entry_offset = 0, meta = nil, summary = nil,
    preview = opts.preview or { anchor_winid = target_winid, extra_wins = {}, buffers = {} },
  }
  attach_autocmds(state)
  set_keymaps(state)
  render.update_winbar(state)
  ui_util.set_readonly(bufnr, true)
  refresh(state)
end

return M
