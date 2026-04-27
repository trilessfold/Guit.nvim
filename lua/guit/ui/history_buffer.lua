local config = require('guit.config')
local git = require('guit.git')
local history = require('guit.history')
local highlights = require('guit.ui.highlight')
local render = require('guit.ui.history_render')
local show_buffer = require('guit.ui.show_buffer')
local window = require('guit.ui.window')
local ui_util = require('guit.ui.util')
local preview = require('guit.ui.preview')
local session = require('guit.session')

local M = {}

local state_by_buf = {}

local function page_size_for(winid)
  local height = vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_height(winid) or vim.o.lines
  return math.max(20, math.floor(height * config.options.page_size_factor))
end

local function prefetch_threshold_for(winid)
  local height = vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_height(winid) or vim.o.lines
  return math.max(5, math.floor(height * config.options.prefetch_threshold_factor))
end

local function current_line(state)
  if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
    return nil
  end
  return vim.api.nvim_win_get_cursor(state.winid)[1]
end

local function get_current_item(state)
  local line = current_line(state)
  if not line then
    return nil, nil
  end
  return state.items[line], line
end

local function snapshot(state)
  local item, line = get_current_item(state)
  local restore = state.restore or {}
  return {
    kind = 'history',
    cwd = state.cwd,
    path = state.path,
    path_display = state.path_display,
    rev = state.rev,
    is_file = state.is_file,
    restore = {
      line = line or restore.line,
      hash = item and item.hash or restore.hash,
    },
  }
end

local function restore_cursor(state)
  local restore = state.restore
  if not restore or state.restore_done or not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
    return
  end
  if #state.items == 0 then
    return
  end

  local line = restore.line or 1
  if restore.hash then
    for i, item in ipairs(state.items) do
      if item.hash == restore.hash then
        line = i
        break
      end
    end
  end

  line = math.max(1, math.min(line, #state.items))
  vim.api.nvim_win_set_cursor(state.winid, { line, 0 })
  state.restore_done = true
end

local function should_prefetch(state)
  local line = current_line(state)
  if not line then return false end
  if #state.items == 0 then return true end
  local remaining = #state.items - line
  return remaining <= prefetch_threshold_for(state.winid)
end

local function focus_target_window(state)
  if state.target_winid and vim.api.nvim_win_is_valid(state.target_winid) then
    vim.api.nvim_set_current_win(state.target_winid)
  end
end

local function bind_back_navigation(state, bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  if vim.b[bufnr].guit_history_bufnr == state.bufnr then return end
  vim.b[bufnr].guit_history_bufnr = state.bufnr
  vim.keymap.set('n', '<C-o>', function()
    if state.winid and vim.api.nvim_win_is_valid(state.winid) then
      vim.api.nvim_set_current_win(state.winid)
    elseif state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
      vim.cmd('buffer ' .. state.bufnr)
    end
  end, { buffer = bufnr, silent = true, nowait = true, desc = 'Return to Guit history' })
end

local function open_commit(state, commit, opts)
  opts = opts or {}
  if vim.fn.exists(':Gedit') == 2 then
    local ok, err = preview.with_managed_preview(state, function()
      vim.cmd(('Gedit %s'):format(commit))
    end)
    if not ok then
      vim.notify('guit.nvim: failed to open commit in fugitive: ' .. tostring(err), vim.log.levels.ERROR)
      if opts.keep_focus and state.winid and vim.api.nvim_win_is_valid(state.winid) then
        vim.api.nvim_set_current_win(state.winid)
      end
      return
    end
    bind_back_navigation(state, vim.api.nvim_get_current_buf())
  else
    vim.notify('guit.nvim: fugitive not found (:Gedit unavailable)', vim.log.levels.WARN)
  end

  if opts.keep_focus and state.winid and vim.api.nvim_win_is_valid(state.winid) then
    vim.api.nvim_set_current_win(state.winid)
  end
end

local function open_file_diff_for_history(state, item, keep_focus)
  if not state.is_file then
    open_commit(state, item.hash, { keep_focus = keep_focus })
    return
  end

  if vim.fn.exists(':Gedit') ~= 2 or vim.fn.exists(':Gdiffsplit') ~= 2 then
    vim.notify('guit.nvim: fugitive not found (:Gedit / :Gdiffsplit unavailable)', vim.log.levels.ERROR)
    return
  end

  local commit = item.hash
  local path = item.path or state.path
  local parent_path = item.old_path or path

  local ok, err = preview.with_managed_preview(state, function()
    vim.cmd(('Gedit %s:%s'):format(commit, vim.fn.fnameescape(path)))
    vim.cmd(('Gdiffsplit! %s^:%s'):format(commit, vim.fn.fnameescape(parent_path)))
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

local function open_primary(state, item, keep_focus)
  if state.is_file then
    open_file_diff_for_history(state, item, keep_focus)
  else
    open_commit(state, item.hash, { keep_focus = keep_focus })
  end
end

local function fetch_total_count(state)
  history.fetch_total_count({ cwd = state.cwd, path = state.path, rev = state.rev }, function(count, err)
    if not vim.api.nvim_buf_is_valid(state.bufnr) then return end
    if err then
      vim.notify('guit.nvim: ' .. err, vim.log.levels.WARN)
      return
    end
    state.total_count = count
    render.update_winbar(state)
  end)
end

local function fetch_more(state, force)
  if state.loading or state.eof or not vim.api.nvim_buf_is_valid(state.bufnr) then return end
  if not force and not should_prefetch(state) then return end

  state.loading = true
  render.set_loading_line(state, '… loading file history …')
  render.update_winbar(state)

  history.fetch_page({
    cwd = state.cwd,
    path = state.path,
    rev = state.rev,
    skip = #state.items,
    limit = page_size_for(state.winid),
  }, function(payload, err)
    if not vim.api.nvim_buf_is_valid(state.bufnr) then return end
    state.loading = false
    render.clear_loading_line(state)
    if err then
      render.update_winbar(state)
      vim.notify('guit.nvim: ' .. err, vim.log.levels.ERROR)
      return
    end
    if not payload or #payload.items == 0 then
      state.eof = true
      render.update_winbar(state)
      return
    end
    local start_idx = #state.items + 1
    vim.list_extend(state.items, payload.items)
    state.eof = payload.eof
    render.render_lines(state, start_idx)
    restore_cursor(state)
    render.update_selected_line(state)
    render.update_winbar(state)
  end)
end

local function refresh(state)
  state.items = {}
  state.eof = false
  state.loading = false
  state.loading_row = nil
  ui_util.with_modifiable(state.bufnr, function()
    vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, {})
  end)
  render.update_winbar(state)
  fetch_total_count(state)
  fetch_more(state, true)
end

local function attach_autocmds(state)
  local group = vim.api.nvim_create_augroup(('GuitHistory_%d'):format(state.bufnr), { clear = true })
  vim.api.nvim_create_autocmd({ 'CursorMoved', 'WinScrolled', 'VimResized', 'BufEnter' }, {
    group = group,
    buffer = state.bufnr,
    callback = function()
      if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
        return
      end
      fetch_more(state, false)
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

local function open_show_from_history(state)
  local item, line = get_current_item(state)
  if not item or not item.hash then
    vim.notify('guit.nvim: no commit selected', vim.log.levels.WARN)
    return
  end

  state.target_winid = (state.target_winid and vim.api.nvim_win_is_valid(state.target_winid)) and state.target_winid or nil
  vim.bo[state.bufnr].bufhidden = 'hide'

  local ok, err = pcall(show_buffer.open, {
    cwd = state.cwd,
    commit = item.hash,
    reuse_winid = state.winid,
    target_winid = state.target_winid,
    source_log = { bufnr = state.bufnr, line = line, snapshot = snapshot(state) },
    preview = state.preview,
  })

  if not ok then
    vim.bo[state.bufnr].bufhidden = 'wipe'
    vim.notify('guit.nvim: failed to open Guit show: ' .. tostring(err), vim.log.levels.ERROR)
  end
end

local function set_keymaps(state)
  local opts = { buffer = state.bufnr, nowait = true, silent = true }
  vim.keymap.set('n', config.options.keymaps.close, function()
    session.close_active()
  end, opts)
  vim.keymap.set('n', config.options.keymaps.refresh, function() refresh(state) end, opts)
  vim.keymap.set('n', config.options.keymaps.open, function()
    local item = get_current_item(state)
    if item then open_primary(state, item, true) end
  end, opts)
  vim.keymap.set('n', config.options.keymaps.split, function()
    local item = get_current_item(state)
    if item then open_primary(state, item, false) end
  end, opts)
  vim.keymap.set('n', config.options.keymaps.commit, function()
    local item = get_current_item(state)
    if item then open_commit(state, item.hash, { keep_focus = true }) end
  end, opts)
  vim.keymap.set('n', config.options.keymaps.commit_focus, function()
    local item = get_current_item(state)
    if item then open_commit(state, item.hash, { keep_focus = false }) end
  end, opts)
  vim.keymap.set('n', config.options.keymaps.open_show, function() open_show_from_history(state) end, opts)
  vim.keymap.set('n', config.options.keymaps.focus_target, function() focus_target_window(state) end, opts)
  vim.keymap.set('n', config.options.keymaps.help, function()
    vim.notify(table.concat({
      'Guit history help', '',
      (state.is_file and '  <CR>  open diff for this file in the selected commit and keep focus here' or '  <CR>  open commit in target window and keep focus here'),
      (state.is_file and '  o     open file diff and move focus to target window' or '  o     open commit and move focus to target window'),
      '  c     open commit in fugitive and keep focus here',
      '  C     open commit in fugitive and move focus to target window',
      '  s     open Guit show for the current commit in the lower pane',
      '  <Tab> jump to target window',
      '  r     refresh history',
      '  q     close pane',
      '  gg    jump to top',
      '  G     jump to bottom and request another page',
      '  ?     show this help', '',
      'The compact stats column uses: <files>f <additions> <deletions>.',
      'See :help guit for full documentation.',
    }, '\n'), vim.log.levels.INFO, { title = 'guit.nvim' })
  end, opts)
  vim.keymap.set('n', 'gg', function() vim.cmd('normal! gg') end, opts)
  vim.keymap.set('n', 'G', function() vim.cmd('normal! G'); fetch_more(state, true) end, opts)
end

function M.open(opts)
  highlights.setup()

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = 'nofile'
  vim.bo[bufnr].bufhidden = 'wipe'
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = 'guithistory'
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly = true

  local winid, target_winid
  if opts.reuse_winid and vim.api.nvim_win_is_valid(opts.reuse_winid) then
    winid = opts.reuse_winid
    target_winid = opts.target_winid or vim.api.nvim_get_current_win()
    ui_util.with_winfixbuf_disabled(winid, function()
      vim.api.nvim_win_set_buf(winid, bufnr)
    end)
  else
    winid, target_winid = window.open_bottom_pane(bufnr)
  end

  local state = {
    bufnr = bufnr,
    winid = winid,
    target_winid = target_winid,
    cwd = opts.cwd,
    path = opts.path,
    path_display = opts.path_display or opts.path,
    rev = opts.rev,
    is_file = opts.is_file or false,
    ns = vim.api.nvim_create_namespace(('guit-history-%d'):format(bufnr)),
    selection_ns = vim.api.nvim_create_namespace(('guit-history-select-%d'):format(bufnr)),
    items = {},
    eof = false,
    loading = false,
    loading_row = nil,
    total_count = nil,
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
  set_keymaps(state)
  attach_autocmds(state)
  render.update_winbar(state)
  refresh(state)
end

function M.activate(bufnr, winid)
  local state = state_by_buf[bufnr]
  if not state then
    return
  end
  state.winid = winid or state.winid
  session.register(state, snapshot)
  render.update_selected_line(state)
  render.update_winbar(state)
end

return M
