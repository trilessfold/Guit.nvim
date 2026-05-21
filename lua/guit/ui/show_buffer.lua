local config = require('guit.config')
local changed_files = require('guit.changed_files')
local git = require('guit.git')
local highlights = require('guit.ui.highlight')
local render = require('guit.ui.show_render')
local panel = require('guit.ui.changed_file_panel')
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

local function snapshot(state)
  local entry, idx = panel.current_entry(state)
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
    panel.rerender(state, render, (panel.current_entry(state) or {}).full_path)
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
      panel.rerender(state, render)
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
    panel.cycle_view(state, render)
  end, opts)

  vim.keymap.set('n', config.options.keymaps.collapse, function()
    if state.view_mode ~= 'tree' or not panel.in_entries_area(state) then
      vim.cmd('normal! h')
      return
    end
    panel.collapse_current(state, render)
  end, opts)

  vim.keymap.set('n', config.options.keymaps.expand, function()
    if state.view_mode ~= 'tree' or not panel.in_entries_area(state) then
      vim.cmd('normal! l')
      return
    end
    panel.expand_current(state, render)
  end, opts)

  vim.keymap.set('n', config.options.keymaps.collapse_all, function()
    panel.set_subtree(state, render, false)
  end, opts)

  vim.keymap.set('n', config.options.keymaps.expand_all, function()
    panel.set_subtree(state, render, true)
  end, opts)

  vim.keymap.set('n', config.options.keymaps.help, function()
    show_help(state)
  end, opts)

  vim.keymap.set('n', '<CR>', function()
    local entry = panel.current_entry(state)
    if not entry then
      return
    end
    if entry.kind == 'dir' and state.view_mode == 'tree' then
      changed_files.toggle_dir(state.tree_state, entry.full_path)
      panel.rerender(state, render, entry.full_path)
      return
    end
    open_file_diff(state, entry, true)
  end, opts)

  vim.keymap.set('n', config.options.keymaps.split, function()
    local entry = panel.current_entry(state)
    if entry and entry.kind == 'file' then
      open_file_diff(state, entry, false)
    end
  end, opts)

  vim.keymap.set('n', '[z', function()
    panel.jump_parent(state, render)
  end, opts)
  vim.keymap.set('n', 'zP', function()
    panel.jump_top(state, render)
  end, opts)
  vim.keymap.set('n', 'zj', function()
    panel.jump_sibling(state, render, 1)
  end, opts)
  vim.keymap.set('n', 'zJ', function()
    panel.jump_sibling(state, render, 1)
  end, opts)
  vim.keymap.set('n', 'zk', function()
    panel.jump_sibling(state, render, -1)
  end, opts)
  vim.keymap.set('n', 'zK', function()
    panel.jump_sibling(state, render, -1)
  end, opts)

  vim.keymap.set('n', 'zM', function()
    panel.set_all(state, render, false)
  end, opts)
  vim.keymap.set('n', 'zR', function()
    panel.set_all(state, render, true)
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
