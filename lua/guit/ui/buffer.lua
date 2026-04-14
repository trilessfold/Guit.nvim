local config = require('guit.config')
local git = require('guit.git')
local highlights = require('guit.ui.highlight')
local render = require('guit.ui.render')
local show_buffer = require('guit.ui.show_buffer')
local window = require('guit.ui.window')
local ui_util = require('guit.ui.util')
local preview = require('guit.ui.preview')

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
  return vim.api.nvim_win_get_cursor(state.winid)[1]
end

local function get_current_item(state)
  local line = current_line(state)
  return state.items[line], line
end

local function should_prefetch(state)
  if #state.items == 0 then
    return true
  end
  local remaining = #state.items - current_line(state)
  return remaining <= prefetch_threshold_for(state.winid)
end

local function focus_target_window(state)
  if state.target_winid and vim.api.nvim_win_is_valid(state.target_winid) then
    vim.api.nvim_set_current_win(state.target_winid)
  end
end

local function bind_back_navigation(state, bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  if vim.b[bufnr].guit_log_bufnr == state.bufnr then
    return
  end

  vim.b[bufnr].guit_log_bufnr = state.bufnr
  vim.keymap.set('n', '<C-o>', function()
    if state.winid and vim.api.nvim_win_is_valid(state.winid) then
      vim.api.nvim_set_current_win(state.winid)
    elseif state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
      vim.cmd('buffer ' .. state.bufnr)
    end
  end, {
    buffer = bufnr,
    silent = true,
    nowait = true,
    desc = 'Return to Guit log',
  })
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
    local ok, err = preview.with_managed_preview(state, function()
      vim.cmd(('edit %s'):format(vim.fn.fnameescape(commit .. '.gitshow')))
    end)
    if not ok then
      vim.notify('guit.nvim: failed to open commit preview: ' .. tostring(err), vim.log.levels.ERROR)
      if opts.keep_focus and state.winid and vim.api.nvim_win_is_valid(state.winid) then
        vim.api.nvim_set_current_win(state.winid)
      end
      return
    end
  end

  if opts.keep_focus and state.winid and vim.api.nvim_win_is_valid(state.winid) then
    vim.api.nvim_set_current_win(state.winid)
  end
end

local function fetch_total_count(state)
  git.fetch_total_count({ cwd = state.cwd }, function(count, err)
    if not vim.api.nvim_buf_is_valid(state.bufnr) then
      return
    end
    if err then
      vim.notify('guit.nvim: ' .. err, vim.log.levels.WARN)
      return
    end

    state.total_count = count
    render.update_winbar(state)
  end)
end

local function fetch_more(state, force)
  if state.loading or state.eof or not vim.api.nvim_buf_is_valid(state.bufnr) then
    return
  end
  if not force and not should_prefetch(state) then
    return
  end

  state.loading = true
  render.set_loading_line(state, '… loading git log …')
  render.update_winbar(state)

  git.fetch_page({
    cwd = state.cwd,
    skip = #state.items,
    limit = page_size_for(state.winid),
  }, function(payload, err)
    if not vim.api.nvim_buf_is_valid(state.bufnr) then
      return
    end

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
  local group = vim.api.nvim_create_augroup(('GuitBuffer_%d'):format(state.bufnr), { clear = true })

  vim.api.nvim_create_autocmd({ 'CursorMoved', 'WinScrolled', 'VimResized', 'BufEnter' }, {
    group = group,
    buffer = state.bufnr,
    callback = function()
      fetch_more(state, false)
      render.update_selected_line(state)
      render.update_winbar(state)
    end,
  })

  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    buffer = state.bufnr,
    callback = function()
      state_by_buf[state.bufnr] = nil
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })
end

local function open_show_from_log(state)
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
    source_log = {
      bufnr = state.bufnr,
      line = line,
    },
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
    if vim.api.nvim_win_is_valid(state.winid) then
      vim.api.nvim_win_close(state.winid, true)
    end
  end, opts)

  vim.keymap.set('n', config.options.keymaps.refresh, function()
    refresh(state)
  end, opts)

  vim.keymap.set('n', config.options.keymaps.open, function()
    local item = get_current_item(state)
    if item then
      open_commit(state, item.hash, { keep_focus = true })
    end
  end, opts)

  vim.keymap.set('n', config.options.keymaps.split, function()
    local item = get_current_item(state)
    if item then
      open_commit(state, item.hash, { keep_focus = false })
    end
  end, opts)

  vim.keymap.set('n', config.options.keymaps.open_show, function()
    open_show_from_log(state)
  end, opts)

  vim.keymap.set('n', config.options.keymaps.focus_target, function()
    focus_target_window(state)
  end, opts)

  vim.keymap.set('n', config.options.keymaps.help, function()
    vim.notify(table.concat({
      'Guit log help',
      '',
      '  <CR>  open commit in target window and keep focus here',
      '  o     open commit and move focus to target window',
      '  s     open Guit show for the current commit in the lower pane',
      '  <Tab> jump to target window',
      '  r     refresh log',
      '  q     close pane',
      '  gg    jump to top',
      '  G     jump to bottom and request another page',
      '  ?     show this help',
      '',
      'See :help guit for full documentation.',
    }, '\n'), vim.log.levels.INFO, { title = 'guit.nvim' })
  end, opts)

  vim.keymap.set('n', 'gg', function()
    vim.cmd('normal! gg')
  end, opts)

  vim.keymap.set('n', 'G', function()
    vim.cmd('normal! G')
    fetch_more(state, true)
  end, opts)
end

function M.open(opts)
  highlights.setup()

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = 'nofile'
  vim.bo[bufnr].bufhidden = 'wipe'
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = 'guitlog'
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly = true

  local winid, target_winid = window.open_bottom_pane(bufnr)

  local state = {
    bufnr = bufnr,
    winid = winid,
    target_winid = target_winid,
    cwd = opts.cwd,
    ns = vim.api.nvim_create_namespace(('guit-%d'):format(bufnr)),
    selection_ns = vim.api.nvim_create_namespace(('guit-select-%d'):format(bufnr)),
    items = {},
    eof = false,
    loading = false,
    loading_row = nil,
    total_count = nil,
    preview = {
      anchor_winid = target_winid,
      extra_wins = {},
      buffers = {},
    },
  }

  state_by_buf[bufnr] = state
  attach_autocmds(state)
  set_keymaps(state)
  render.update_winbar(state)
  refresh(state)
end

return M
