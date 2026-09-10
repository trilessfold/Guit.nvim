local config = require('guit.config')
local git = require('guit.git')
local history = require('guit.history')
local highlights = require('guit.ui.highlight')
local render = require('guit.ui.history_render')
local show_buffer = require('guit.ui.show_buffer')
local window = require('guit.ui.window')
local ui_util = require('guit.ui.util')
local preview = require('guit.ui.preview')
local diff = require('guit.ui.diff')
local keymaps = require('guit.keymaps')
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
    line_range = state.line_range,
    hide_stats = state.hide_stats,
    replaced = state.replaced,
    follow = state.follow,
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
  if state.fetch_failed then return false end
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
  else
    vim.notify('guit.nvim: fugitive not found (:Gedit unavailable)', vim.log.levels.WARN)
  end

  if opts.keep_focus and state.winid and vim.api.nvim_win_is_valid(state.winid) then
    vim.api.nvim_set_current_win(state.winid)
  end
end

--- The two sides of the file's change in the selected commit. The first
--- commit of the repository has no parent side; a commit that added the file
--- has none either, and one that deleted it has no commit side.
local function history_diff_spec(state, item)
  local path = item.path or state.path
  local status = (item.status or ''):sub(1, 1)
  local left = { rev = item.hash .. '^', path = item.old_path or path }
  local right = { rev = item.hash, path = path }
  if status == 'D' then
    right = nil
  elseif status == 'A' or diff.is_root_commit(item.parents) then
    left = nil
  end
  return { cwd = state.cwd, left = left, right = right }
end

local function open_file_diff_for_history(state, item, keep_focus, mode)
  if not state.is_file then
    open_commit(state, item.hash, { keep_focus = keep_focus })
    return
  end
  diff.open(state, history_diff_spec(state, item), { mode = mode, keep_focus = keep_focus })
end

local function open_file_revision_for_history(state, item, keep_focus)
  if vim.fn.exists(':Gedit') ~= 2 then
    vim.notify('guit.nvim: fugitive not found (:Gedit unavailable)', vim.log.levels.ERROR)
    return
  end

  local path = item.path or state.path
  local ok, err = preview.with_managed_preview(state, function()
    vim.cmd(('Gedit %s:%s'):format(item.hash, vim.fn.fnameescape(path)))
    local target_line = item.target_line or (state.line_range and state.line_range.start)
    if target_line then
      local max_line = vim.api.nvim_buf_line_count(0)
      local line = math.max(1, math.min(target_line, max_line))
      pcall(vim.api.nvim_win_set_cursor, 0, { line, 0 })
    end
  end)
  if not ok then
    vim.notify('guit.nvim: failed to open file revision in fugitive: ' .. tostring(err), vim.log.levels.ERROR)
    if keep_focus and state.winid and vim.api.nvim_win_is_valid(state.winid) then
      vim.api.nvim_set_current_win(state.winid)
    end
    return
  end

  if keep_focus and state.winid and vim.api.nvim_win_is_valid(state.winid) then
    vim.api.nvim_set_current_win(state.winid)
  end
end

local function open_primary(state, item, keep_focus)
  if state.line_range then
    open_file_revision_for_history(state, item, keep_focus)
  elseif state.replaced and state.is_file then
    open_file_revision_for_history(state, item, keep_focus)
  elseif state.is_file then
    open_file_diff_for_history(state, item, keep_focus)
  else
    open_commit(state, item.hash, { keep_focus = keep_focus })
  end
end

local function fetch_total_count(state)
  if state.line_range then
    return
  end
  history.fetch_total_count({ cwd = state.cwd, path = state.path, rev = state.rev, follow = state.follow }, function(count, err)
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
  local generation = state.generation or 0
  render.set_loading_line(state, state.line_range and '… loading line history …' or '… loading file history …')
  render.update_winbar(state)

  history.fetch_page({
    cwd = state.cwd,
    path = state.path,
    rev = state.rev,
    line_range = state.line_range,
    follow = state.follow,
    skip = #state.items,
    limit = page_size_for(state.winid),
  }, function(payload, err)
    if not vim.api.nvim_buf_is_valid(state.bufnr) then return end
    -- A refresh happened while this page was in flight; its results belong to
    -- a list that no longer exists.
    if generation ~= (state.generation or 0) then return end
    state.loading = false
    render.clear_loading_line(state)
    if err then
      state.fetch_failed = true
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
  state.generation = (state.generation or 0) + 1
  state.items = {}
  state.eof = false
  state.loading = false
  state.fetch_failed = false
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
  local function with_item(fn)
    return function(s)
      local item = get_current_item(s)
      if item then
        fn(s, item)
      end
    end
  end

  local handlers = {
    close = function(s)
      session.close(s)
    end,
    refresh = refresh,
    focus_target = focus_target_window,
    open_show = open_show_from_history,
    open = with_item(function(s, item)
      open_primary(s, item, true)
    end),
    open_focus = with_item(function(s, item)
      open_primary(s, item, false)
    end),
    commit = with_item(function(s, item)
      open_commit(s, item.hash, { keep_focus = true })
    end),
    commit_focus = with_item(function(s, item)
      open_commit(s, item.hash, { keep_focus = false })
    end),
    open_diff = with_item(function(s, item)
      require('guit').compare(item.hash, 'HEAD', { cwd = s.cwd })
    end),
    -- File history has a file diff to show, and can name the shape of it.
    open_diff_inline = state.is_file and with_item(function(s, item)
      open_file_diff_for_history(s, item, true, 'inline')
    end) or nil,
    open_diff_split = state.is_file and with_item(function(s, item)
      open_file_diff_for_history(s, item, true, 'split')
    end) or nil,
    yank_hash = with_item(function(_, item)
      ui_util.yank(item.hash)
    end),
    cmdline = with_item(function(_, item)
      ui_util.put_on_cmdline(item.hash)
    end),
  }

  handlers.help = keymaps.help_handler(
    state.line_range and 'Guit line history' or 'Guit history',
    handlers
  )
  keymaps.apply(state, handlers)
end

function M.open(opts)
  highlights.setup()

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = 'nofile'
  vim.bo[bufnr].bufhidden = 'wipe'
  vim.bo[bufnr].swapfile = false
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
    line_range = opts.line_range,
    hide_stats = opts.hide_stats or opts.line_range ~= nil,
    replaced = opts.replaced or false,
    follow = opts.follow or false,
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
  -- Set last: FileType fires here, so after/ftplugin/guithistory.lua runs after the
  -- plugin's own mappings and can override them.
  vim.bo[bufnr].filetype = 'guithistory'
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

--- The commits shown on a range of lines, oldest last.
---
--- Line N of a log or history pane is item N, which is what makes
--- `:'<,'>Guit compare` and `:'a,'bGuit compare` work: the visual selection or
--- the marks are the selection mechanism, so Guit needs no marking mode of its
--- own.
---@param bufnr integer
---@param line1 integer
---@param line2 integer
---@return table[] items
---@return string|nil cwd the repository the commits belong to
function M.items_in_range(bufnr, line1, line2)
  local state = state_by_buf[bufnr]
  if not state then
    return {}, nil
  end

  local first = math.min(line1, line2)
  local last = math.max(line1, line2)
  local items = {}
  for line = first, last do
    local item = state.items[line]
    if item then
      items[#items + 1] = item
    end
  end
  return items, state.cwd
end

return M
