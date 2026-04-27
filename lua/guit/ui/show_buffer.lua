local config = require('guit.config')
local changed_files = require('guit.changed_files')
local git = require('guit.git')
local highlights = require('guit.ui.highlight')
local render = require('guit.ui.show_render')
local window = require('guit.ui.window')
local ui_util = require('guit.ui.util')
local preview = require('guit.ui.preview')
local session = require('guit.session')

local M = {}

local state_by_buf = {}

local function return_to_panel(state)
  if state.winid and vim.api.nvim_win_is_valid(state.winid) then
    vim.api.nvim_set_current_win(state.winid)
  elseif state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
    vim.cmd('buffer ' .. state.bufnr)
  end
end

local function return_to_log(state)
  local origin = state.source_log
  if not origin then
    vim.notify('guit.nvim: original Guit log buffer is no longer available', vim.log.levels.WARN)
    return
  end

  local winid = state.winid
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return
  end

  if not origin.bufnr or not vim.api.nvim_buf_is_valid(origin.bufnr) then
    if origin.snapshot then
      session.open_snapshot(origin.snapshot, {
        reuse_winid = winid,
        target_winid = state.target_winid,
        preview = state.preview,
      })
      return
    end

    vim.notify('guit.nvim: original Guit log buffer is no longer available', vim.log.levels.WARN)
    return
  end

  vim.bo[origin.bufnr].bufhidden = 'hide'
  ui_util.with_winfixbuf_disabled(winid, function()
    vim.api.nvim_win_set_buf(winid, origin.bufnr)
  end)
  local line = math.max(1, math.min(origin.line or 1, vim.api.nvim_buf_line_count(origin.bufnr)))
  vim.api.nvim_win_set_cursor(winid, { line, 0 })
  vim.api.nvim_set_current_win(winid)
  local ft = vim.bo[origin.bufnr].filetype
  if ft == 'guitlog' then
    require('guit.ui.buffer').activate(origin.bufnr, winid)
  elseif ft == 'guithistory' then
    require('guit.ui.history_buffer').activate(origin.bufnr, winid)
  end
end

local function bind_back_navigation(state, bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  if vim.b[bufnr].guit_show_bufnr == state.bufnr then
    return
  end

  vim.b[bufnr].guit_show_bufnr = state.bufnr
  vim.keymap.set('n', '<C-o>', function()
    return_to_panel(state)
  end, {
    buffer = bufnr,
    silent = true,
    nowait = true,
    desc = 'Return to Guit show',
  })
end

local function current_index(state)
  local line = vim.api.nvim_win_get_cursor(state.winid)[1] - (state.entry_offset or 0)
  if line < 1 then
    return nil
  end
  return line
end

local function in_entries_area(state)
  if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
    return false
  end
  local line = vim.api.nvim_win_get_cursor(state.winid)[1]
  return line > (state.entry_offset or 0)
end

local function set_cursor(state, index)
  if not state.winid or not vim.api.nvim_win_is_valid(state.winid) or #state.entries == 0 then
    return
  end
  local line = math.max(1, math.min(index, #state.entries)) + (state.entry_offset or 0)
  vim.api.nvim_win_set_cursor(state.winid, { line, 0 })
end

local function current_entry(state)
  local idx = current_index(state)
  if not idx then
    return nil, nil
  end
  return state.entries[idx], idx
end

local function snapshot(state)
  local entry, idx = current_entry(state)
  local source_log = state.source_log and {
    bufnr = state.source_log.bufnr,
    line = state.source_log.line,
    snapshot = state.source_log.snapshot,
  } or nil
  return {
    kind = 'show',
    cwd = state.cwd,
    commit = state.commit,
    view_mode = state.view_mode,
    source_log = source_log,
    restore = {
      line = idx,
      path = entry and entry.full_path or nil,
    },
  }
end

local function current_dir_target(state)
  local entry = current_entry(state)
  if not entry then
    return nil
  end
  if entry.kind == 'dir' then
    return entry.full_path
  end
  return changed_files.parent_dir(entry.full_path)
end

local function find_entry_index(state, predicate)
  for i, entry in ipairs(state.entries) do
    if predicate(entry, i) then
      return i, entry
    end
  end
  return nil, nil
end

local function find_first_child_index(state, dir_path)
  if not dir_path or dir_path == '' then
    return nil
  end
  local prefix = dir_path .. '/'
  local dir_depth = select(2, dir_path:gsub('/', ''))
  for i, entry in ipairs(state.entries) do
    if entry.full_path:sub(1, #prefix) == prefix and entry.depth == dir_depth + 1 then
      return i, entry
    end
  end
  return nil, nil
end

local function find_parent_index(state, entry)
  if not entry then
    return nil, nil
  end
  local parent = changed_files.parent_dir(entry.full_path)
  if not parent then
    return nil, nil
  end
  return find_entry_index(state, function(candidate)
    return candidate.kind == 'dir' and candidate.full_path == parent
  end)
end

local function find_top_ancestor_index(state, entry)
  if not entry then
    return nil, nil
  end
  local top = changed_files.top_dir(entry.full_path)
  if not top then
    return nil, nil
  end
  return find_entry_index(state, function(candidate)
    return candidate.kind == 'dir' and candidate.full_path == top
  end)
end

local function find_sibling_index(state, idx, delta)
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

local function restore_cursor(state, preferred_path)
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

local function rerender(state, preferred_path)
  state.entries = changed_files.to_entries(state.items, state.view_mode, state.tree_state)
  render.render_all(state)
  restore_cursor(state, preferred_path)
  render.update_winbar(state)
end

local function open_file_diff(state, entry, keep_focus)
  if not entry or entry.kind ~= 'file' then
    return
  end

  if vim.fn.exists(':Gedit') ~= 2 or vim.fn.exists(':Gdiffsplit') ~= 2 then
    vim.notify('guit.nvim: fugitive not found (:Gedit / :Gdiffsplit unavailable)', vim.log.levels.ERROR)
    return
  end

  local ok, err = preview.with_managed_preview(state, function()
    vim.cmd(('Gedit %s:%s'):format(state.commit, vim.fn.fnameescape(entry.full_path)))
    vim.cmd(('Gdiffsplit! %s:%s'):format(
      changed_files.parent_of(state.commit),
      vim.fn.fnameescape(entry.old_path or entry.full_path)
    ))
  end)
  if not ok then
    vim.notify('guit.nvim: failed to open file diff in fugitive: ' .. tostring(err), vim.log.levels.ERROR)
    if keep_focus and state.winid and vim.api.nvim_win_is_valid(state.winid) then
      vim.api.nvim_set_current_win(state.winid)
    end
    return
  end
  bind_back_navigation(state, vim.api.nvim_get_current_buf())

  if keep_focus and state.winid and vim.api.nvim_win_is_valid(state.winid) then
    vim.api.nvim_set_current_win(state.winid)
  end
end

local function fetch_meta(state)
  git.fetch_commit_meta({ cwd = state.cwd, commit = state.commit }, function(meta, err)
    if not vim.api.nvim_buf_is_valid(state.bufnr) then
      return
    end
    if err then
      vim.notify('guit.nvim: ' .. err, vim.log.levels.WARN)
      return
    end
    state.meta = meta
    rerender(state, (current_entry(state) or {}).full_path)
  end)
end

local function refresh(state)
  changed_files.fetch_changed_files({ cwd = state.cwd, commit = state.commit }, function(items, err)
    if not vim.api.nvim_buf_is_valid(state.bufnr) then
      return
    end

    if err then
      vim.notify('guit.nvim: ' .. err, vim.log.levels.ERROR)
      return
    end

    state.items = items or {}

    local function apply_items()
      state.tree_state = changed_files.build_state(state.items)
      rerender(state)
    end

    if config.options.show.show_counts then
      changed_files.fetch_numstat({ cwd = state.cwd, commit = state.commit }, function(stats, total, stats_err)
        if not vim.api.nvim_buf_is_valid(state.bufnr) then
          return
        end
        if stats_err then
          vim.notify('guit.nvim: ' .. stats_err, vim.log.levels.WARN)
          state.summary = { additions = 0, deletions = 0 }
          apply_items()
          return
        end

        changed_files.enrich_with_numstat(state.items, stats or {})
        state.summary = total or { additions = 0, deletions = 0 }
        apply_items()
      end)
    else
      state.summary = nil
      apply_items()
    end
  end)
  fetch_meta(state)
end

local function cycle_view(state)
  local preferred = current_entry(state)
  state.view_mode = state.view_mode == 'tree' and 'list' or 'tree'
  rerender(state, preferred and preferred.full_path or nil)
end

local function collapse_current(state)
  if state.view_mode ~= 'tree' then
    return
  end
  local entry = current_entry(state)
  if not entry then
    return
  end

  if entry.kind == 'dir' and entry.expanded then
    changed_files.toggle_dir(state.tree_state, entry.full_path, false)
    rerender(state, entry.full_path)
    return
  end

  local parent = entry.kind == 'dir' and changed_files.parent_dir(entry.full_path) or changed_files.parent_dir(entry.full_path)
  if parent then
    changed_files.toggle_dir(state.tree_state, parent, false)
    rerender(state, parent)
  end
end

local function expand_current(state)
  if state.view_mode ~= 'tree' then
    return
  end
  local entry, idx = current_entry(state)
  if not entry then
    return
  end
  if entry.kind == 'dir' then
    if not entry.expanded then
      changed_files.toggle_dir(state.tree_state, entry.full_path, true)
      rerender(state, entry.full_path)
      return
    end

    local child_idx = find_first_child_index(state, entry.full_path)
    if child_idx then
      set_cursor(state, child_idx)
      render.update_selected_line(state)
      render.update_winbar(state)
    end
    return
  end

  local parent = current_dir_target(state)
  if parent then
    changed_files.expand_chain(state.tree_state, parent)
    rerender(state, entry.full_path)
  end
end

local function collapse_all(state)
  if state.view_mode ~= 'tree' then
    return
  end
  local target = current_dir_target(state)
  if not target then
    return
  end
  changed_files.set_subtree(state.tree_state, target, false)
  rerender(state, target)
end

local function expand_all(state)
  if state.view_mode ~= 'tree' then
    return
  end
  local entry = current_entry(state)
  local target = current_dir_target(state)
  if not target then
    return
  end
  changed_files.expand_chain(state.tree_state, target)
  changed_files.set_subtree(state.tree_state, target, true)
  rerender(state, entry and entry.full_path or target)
end

local function collapse_global(state)
  if state.view_mode ~= 'tree' then
    return
  end
  changed_files.set_all(state.tree_state, false)
  rerender(state)
end

local function expand_global(state)
  if state.view_mode ~= 'tree' then
    return
  end
  changed_files.set_all(state.tree_state, true)
  rerender(state)
end

local function collapse_branch(state)
  if state.view_mode ~= 'tree' then
    return
  end
  local entry = current_entry(state)
  if not entry then
    return
  end

  if entry.kind == 'dir' then
    changed_files.collapse_chain(state.tree_state, entry.full_path)
    rerender(state, entry.full_path)
    return
  end

  local parent = changed_files.parent_dir(entry.full_path)
  if parent then
    changed_files.collapse_chain(state.tree_state, parent)
    rerender(state, parent)
  end
end

local function expand_branch(state)
  if state.view_mode ~= 'tree' then
    return
  end
  local entry = current_entry(state)
  if not entry then
    return
  end

  local target = entry.kind == 'dir' and entry.full_path or changed_files.parent_dir(entry.full_path)
  if target then
    changed_files.expand_chain(state.tree_state, target)
    rerender(state, entry.full_path)
  end
end

local function jump_parent(state)
  if state.view_mode ~= 'tree' then
    return
  end
  local entry = current_entry(state)
  local idx = select(1, find_parent_index(state, entry))
  if idx then
    set_cursor(state, idx)
    render.update_selected_line(state)
    render.update_winbar(state)
  end
end

local function jump_top(state)
  if state.view_mode ~= 'tree' then
    return
  end
  local entry = current_entry(state)
  local idx = select(1, find_top_ancestor_index(state, entry))
  if idx then
    set_cursor(state, idx)
    render.update_selected_line(state)
    render.update_winbar(state)
  end
end

local function jump_sibling(state, delta)
  if state.view_mode ~= 'tree' then
    return
  end
  local idx = current_index(state)
  if not idx then
    return
  end
  local sibling_idx = select(1, find_sibling_index(state, idx, delta))
  if sibling_idx then
    set_cursor(state, sibling_idx)
    render.update_selected_line(state)
    render.update_winbar(state)
  end
end

local function show_help(state)
  local lines = {
    'Guit show help',
    '',
    'Navigation',
    '  <CR>  open file diff in target window and keep focus here',
    '  o     open file diff in target window and move there',
    '  <Tab> jump to target window',
    '  -     return to the originating Guit log buffer when available',
    '  [z    jump to parent directory',
    '  zP    jump to top-level directory for the current branch',
    '  zj/zJ jump to next sibling entry',
    '  zk/zK jump to previous sibling entry',
    '',
    'Views',
    '  t     toggle tree/list',
    '  h     collapse current directory; if already closed, collapse parent',
    '  l     expand current directory; if already open, jump into first child',
    '  H     collapse the current subtree',
    '  L     expand the current subtree',
    '',
    'Fold-like',
    '  zM    collapse whole tree',
    '  zR    expand whole tree',
    '',
    'Other',
    '  r     refresh',
    '  q     close pane',
    '  ?     show this help',
    '',
    'See :help guit for full documentation.',
  }
  vim.notify(table.concat(lines, '\n'), vim.log.levels.INFO, { title = 'guit.nvim' })
end

local function attach_autocmds(state)
  local group = vim.api.nvim_create_augroup(('GuitShow_%d'):format(state.bufnr), { clear = true })

  vim.api.nvim_create_autocmd({ 'CursorMoved', 'BufEnter' }, {
    group = group,
    buffer = state.bufnr,
    callback = function()
      render.update_selected_line(state)
      render.update_winbar(state)
      session.update(state)
    end,
  })

  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    buffer = state.bufnr,
    callback = function()
      session.clear(state)
      state_by_buf[state.bufnr] = nil
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })
end

local function set_keymaps(state)
  local opts = { buffer = state.bufnr, nowait = true, silent = true }

  vim.keymap.set('n', config.options.keymaps.close, function()
    session.close_active()
  end, opts)

  vim.keymap.set('n', config.options.keymaps.back, function()
    return_to_log(state)
  end, opts)
  vim.keymap.set('n', '<BS>', function()
    return_to_log(state)
  end, opts)

  vim.keymap.set('n', config.options.keymaps.refresh, function()
    refresh(state)
  end, opts)

  vim.keymap.set('n', config.options.keymaps.focus_target, function()
    if state.target_winid and vim.api.nvim_win_is_valid(state.target_winid) then
      vim.api.nvim_set_current_win(state.target_winid)
    end
  end, opts)

  vim.keymap.set('n', config.options.keymaps.toggle_view, function()
    cycle_view(state)
  end, opts)

  vim.keymap.set('n', config.options.keymaps.collapse, function()
    if state.view_mode ~= 'tree' or not in_entries_area(state) then
      vim.cmd('normal! h')
      return
    end
    collapse_current(state)
  end, opts)

  vim.keymap.set('n', config.options.keymaps.expand, function()
    if state.view_mode ~= 'tree' or not in_entries_area(state) then
      vim.cmd('normal! l')
      return
    end
    expand_current(state)
  end, opts)

  vim.keymap.set('n', config.options.keymaps.collapse_all, function()
    collapse_all(state)
  end, opts)

  vim.keymap.set('n', config.options.keymaps.expand_all, function()
    expand_all(state)
  end, opts)

  vim.keymap.set('n', config.options.keymaps.help, function()
    show_help(state)
  end, opts)

  vim.keymap.set('n', '<CR>', function()
    local entry = current_entry(state)
    if not entry then
      return
    end
    if entry.kind == 'dir' and state.view_mode == 'tree' then
      changed_files.toggle_dir(state.tree_state, entry.full_path)
      rerender(state, entry.full_path)
      return
    end
    open_file_diff(state, entry, true)
  end, opts)

  vim.keymap.set('n', config.options.keymaps.split, function()
    local entry = current_entry(state)
    if entry and entry.kind == 'file' then
      open_file_diff(state, entry, false)
    end
  end, opts)

  vim.keymap.set('n', '[z', function()
    jump_parent(state)
  end, opts)
  vim.keymap.set('n', 'zP', function()
    jump_top(state)
  end, opts)
  vim.keymap.set('n', 'zj', function()
    jump_sibling(state, 1)
  end, opts)
  vim.keymap.set('n', 'zJ', function()
    jump_sibling(state, 1)
  end, opts)
  vim.keymap.set('n', 'zk', function()
    jump_sibling(state, -1)
  end, opts)
  vim.keymap.set('n', 'zK', function()
    jump_sibling(state, -1)
  end, opts)

  vim.keymap.set('n', 'zM', function()
    collapse_global(state)
  end, opts)
  vim.keymap.set('n', 'zR', function()
    expand_global(state)
  end, opts)
end

function M.open(opts)
  highlights.setup()

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = 'nofile'
  vim.bo[bufnr].bufhidden = 'wipe'
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = 'guitshow'
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly = true

  local winid = opts.reuse_winid
  local target_winid = opts.target_winid
  if winid and vim.api.nvim_win_is_valid(winid) then
    ui_util.with_winfixbuf_disabled(winid, function()
      vim.api.nvim_win_set_buf(winid, bufnr)
    end)
    vim.api.nvim_set_current_win(winid)
  else
    winid, target_winid = window.open_bottom_pane(bufnr)
  end

  local state = {
    bufnr = bufnr,
    winid = winid,
    target_winid = target_winid,
    cwd = opts.cwd,
    commit = opts.commit,
    ns = vim.api.nvim_create_namespace(('guit-show-%d'):format(bufnr)),
    selection_ns = vim.api.nvim_create_namespace(('guit-show-select-%d'):format(bufnr)),
    view_mode = opts.view_mode or config.options.show.default_view,
    items = {},
    entries = {},
    tree_state = nil,
    entry_offset = 0,
    meta = nil,
    source_log = opts.source_log,
    restore = opts.restore,
    restore_done = false,
    preview = opts.preview or {
      anchor_winid = target_winid,
      extra_wins = {},
      buffers = {},
    },
  }

  state_by_buf[bufnr] = state
  session.register(state, snapshot)
  attach_autocmds(state)
  set_keymaps(state)
  render.update_winbar(state)
  ui_util.set_readonly(bufnr, true)
  refresh(state)
end

return M
