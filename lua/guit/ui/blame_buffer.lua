local blame = require('guit.blame')
local config = require('guit.config')
local fugitive = require('guit.fugitive')
local git = require('guit.git')
local history = require('guit.history')
local highlights = require('guit.ui.highlight')
local ui_util = require('guit.ui.util')
local window = require('guit.ui.window')

local M = {}

local state_by_buf = {}

local palette = {
  0x3b82f6,
  0x22c55e,
  0xeab308,
  0xef4444,
  0xa855f7,
  0x14b8a6,
  0xf97316,
  0x06b6d4,
}

local function valid_win(winid)
  return winid and vim.api.nvim_win_is_valid(winid)
end

local function valid_buf(bufnr)
  return bufnr and vim.api.nvim_buf_is_valid(bufnr)
end

local function line_count(bufnr)
  return valid_buf(bufnr) and vim.api.nvim_buf_line_count(bufnr) or 0
end

local function format_time(timestamp)
  if not timestamp then
    return '----------'
  end
  return os.date('%Y-%m-%d', timestamp)
end

local function truncate_display(text, width)
  text = tostring(text or ''):gsub('%s+', ' ')
  if width <= 0 then
    return ''
  end
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  if width == 1 then
    return '…'
  end

  local out = ''
  local used = 0
  for i = 0, vim.fn.strchars(text) - 1 do
    local char = vim.fn.strcharpart(text, i, 1)
    local char_width = vim.fn.strdisplaywidth(char)
    if used + char_width > width - 1 then
      break
    end
    out = out .. char
    used = used + char_width
  end
  return out .. '…'
end

local function pad_display(text, width)
  local out = truncate_display(text, width)
  return out .. string.rep(' ', math.max(0, width - vim.fn.strdisplaywidth(out)))
end

local function render_layout(state)
  local width = config.options.blame.width
  if valid_win(state.winid) then
    width = vim.api.nvim_win_get_width(state.winid)
  end

  local available = width - 23
  if available <= 0 then
    return { author = 0, summary = 0 }
  end

  local author = math.min(18, math.max(10, math.floor(width * 0.3)), available)
  local summary = available - author - 1
  if summary < 4 then
    author = available
    summary = 0
  end
  return { author = author, summary = summary }
end

local function is_current_item(state, item)
  return item and item.hash and state.current_hash and item.hash == state.current_hash
end

local function line_text(state, item)
  if not item then
    return '  '
  end
  local block_marker = is_current_item(state, item) and '█' or '▌'
  if item.block_start then
    local layout = state.render_layout or render_layout(state)
    local author = pad_display(item.author, layout.author)
    local summary = layout.summary > 0 and pad_display(item.summary, layout.summary) or ''
    local body = layout.summary > 0 and (author .. ' ' .. summary) or author
    return string.format('%s %s %s %s', block_marker, item.short_hash, body, format_time(item.author_time))
  end
  return block_marker
end

local function hl_name(prefix, id)
  return string.format('GuitBlame%s%d', prefix, id)
end

local function hash_color_index(hash)
  local value = 0
  for i = 1, #(hash or '') do
    value = (value * 33 + hash:byte(i)) % 2147483647
  end
  return value % #palette + 1
end

local function setup_color_groups(lines)
  for _, item in ipairs(lines) do
    local color_id = hash_color_index(item.hash)
    local color = palette[color_id]
    local block_name = hl_name('Block', color_id)
    local hash_name = hl_name('Hash', color_id)
    vim.api.nvim_set_hl(0, block_name, { fg = color, bold = true, default = false })
    vim.api.nvim_set_hl(0, hash_name, { fg = color, bold = true, default = false })
  end
end

local function setup_heat_groups(state)
  local lines = state.items
  local newest, oldest = nil, nil
  for _, item in ipairs(lines) do
    if item.author_time then
      newest = newest and math.max(newest, item.author_time) or item.author_time
      oldest = oldest and math.min(oldest, item.author_time) or item.author_time
    end
  end
  newest = newest or os.time()
  oldest = oldest or newest
  local span = math.max(newest - oldest, 1)

  for _, item in ipairs(lines) do
    local ratio = item.author_time and ((item.author_time - oldest) / span) or 0
    local bucket = math.max(1, math.min(8, math.floor(ratio * 7) + 1))
    if is_current_item(state, item) then
      bucket = 8
    end
    item.heat_bucket = bucket
  end

  for i = 1, 8 do
    local hot = 0xef4444
    local cold = 0x3b82f6
    local ratio = (i - 1) / 7
    local function channel(shift)
      local a = bit.band(bit.rshift(hot, shift), 0xff)
      local b = bit.band(bit.rshift(cold, shift), 0xff)
      return math.floor(a * ratio + b * (1 - ratio) + 0.5)
    end
    local color = bit.bor(bit.lshift(channel(16), 16), bit.lshift(channel(8), 8), channel(0))
    vim.api.nvim_set_hl(0, hl_name('Heat', i), { fg = color, default = false })
  end
end

local function item_hl(state, item)
  if state.mode == 'plain' then
    return config.options.highlights.hash
  elseif state.mode == 'heat' then
    return hl_name('Heat', item.heat_bucket or 1)
  end
  return hl_name('Hash', hash_color_index(item.hash))
end

local function marker_hl(state, item)
  if state.mode == 'plain' then
    return config.options.highlights.status
  elseif state.mode == 'heat' then
    return hl_name('Heat', item.heat_bucket or 1)
  end
  return hl_name('Block', hash_color_index(item.hash))
end

local function render(state)
  local out = {}
  local max_lines = math.max(#state.items, line_count(state.target_bufnr))
  state.render_layout = render_layout(state)
  for i = 1, max_lines do
    out[i] = line_text(state, state.items[i])
  end

  ui_util.with_modifiable(state.bufnr, function()
    vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, out)
  end)
  vim.api.nvim_buf_clear_namespace(state.bufnr, state.ns, 0, -1)

  if state.mode == 'color' then
    setup_color_groups(state.items)
  elseif state.mode == 'heat' then
    setup_heat_groups(state)
  end

  for row, item in ipairs(state.items) do
    local line = out[row] or ''
    local group = item_hl(state, item)
    vim.api.nvim_buf_add_highlight(state.bufnr, state.ns, marker_hl(state, item), row - 1, 0, math.min(#line, 3))
    if item.block_start then
      vim.api.nvim_buf_add_highlight(state.bufnr, state.ns, group, row - 1, 4, math.min(#line, 12))
    end
  end
end

local function current_item(state)
  if not valid_win(state.winid) then
    return nil
  end
  local line = vim.api.nvim_win_get_cursor(state.winid)[1]
  return state.items[line]
end

local resolve_target
local set_target

local function open_in_target(state, fn)
  if not valid_win(state.target_winid) then
    vim.notify('guit.nvim: blame target window is gone', vim.log.levels.WARN)
    return
  end
  local current = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(state.target_winid)
  local ok, err = pcall(fn)
  if valid_win(current) then
    vim.api.nvim_set_current_win(current)
  end
  if not ok then
    vim.notify('guit.nvim: ' .. tostring(err), vim.log.levels.ERROR)
  end
  return ok
end

local function ensure_committed(item)
  if not item or not item.hash or item.hash:match('^0+$') then
    vim.notify('guit.nvim: line is not committed yet', vim.log.levels.WARN)
    return false
  end
  return true
end

local function resolve_commit(cwd, rev)
  if not cwd or not rev or rev == '' then
    return nil
  end
  local result = vim.system({ 'git', 'rev-parse', rev }, { cwd = cwd, text = true }):wait()
  if result.code ~= 0 then
    return nil
  end
  local hash = (result.stdout or ''):match('%x+')
  return hash
end

local function current_target_commit(state)
  return resolve_commit(state.cwd, state.rev or 'HEAD')
end

local function already_open_in_target(state, item)
  local current = current_target_commit(state)
  if current and item.hash and current == item.hash then
    vim.notify('guit.nvim: selected revision is already open in the target window', vim.log.levels.WARN)
    return true
  end
  return false
end

local function target_snapshot(state)
  if not valid_win(state.target_winid) then
    return nil
  end

  local current = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(state.target_winid)
  local bufnr = vim.api.nvim_get_current_buf()
  local snapshot = {
    bufnr = bufnr,
    name = vim.api.nvim_buf_get_name(bufnr),
    view = vim.fn.winsaveview(),
  }
  if valid_win(current) then
    vim.api.nvim_set_current_win(current)
  end
  return snapshot
end

local function push_target_snapshot(state, snapshot)
  if not snapshot then
    return
  end
  state.target_history = state.target_history or {}
  state.target_history[#state.target_history + 1] = snapshot
  while #state.target_history > 10 do
    table.remove(state.target_history, 1)
  end
end

local function jump_target_back(state)
  if not valid_win(state.target_winid) then
    vim.notify('guit.nvim: blame target window is gone', vim.log.levels.WARN)
    return
  end
  if not state.target_history or #state.target_history == 0 then
    vim.notify('guit.nvim: blame target history is empty', vim.log.levels.WARN)
    return
  end

  local snapshot = table.remove(state.target_history)
  local return_winid = valid_win(state.winid) and state.winid or vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(state.target_winid)
  state.restoring_target = true
  local ok, err = pcall(function()
    if valid_buf(snapshot.bufnr) then
      vim.api.nvim_win_set_buf(state.target_winid, snapshot.bufnr)
    elseif snapshot.name and snapshot.name ~= '' then
      vim.cmd('edit ' .. vim.fn.fnameescape(snapshot.name))
    else
      vim.cmd('enew')
    end
    if snapshot.view then
      pcall(vim.fn.winrestview, snapshot.view)
    end
  end)
  state.restoring_target = false
  if valid_win(return_winid) then
    vim.api.nvim_set_current_win(return_winid)
  end
  if not ok then
    vim.notify('guit.nvim: ' .. tostring(err), vim.log.levels.ERROR)
    return
  end

  local target = resolve_target(state.target_winid)
  if target then
    set_target(state, target, { silent = true })
  end
end

local function open_file_revision(state)
  local item = current_item(state)
  if not ensure_committed(item) then
    return
  end
  if vim.fn.exists(':Gedit') ~= 2 then
    vim.notify('guit.nvim: fugitive not found (:Gedit unavailable)', vim.log.levels.ERROR)
    return
  end
  if already_open_in_target(state, item) then
    return
  end
  local snapshot = target_snapshot(state)
  local target_line = item.original_line or item.line
  open_in_target(state, function()
    vim.cmd(('Gedit %s:%s'):format(item.hash, vim.fn.fnameescape(item.filename or state.path)))
    if target_line then
      local max_line = vim.api.nvim_buf_line_count(0)
      pcall(vim.api.nvim_win_set_cursor, 0, { math.max(1, math.min(target_line, max_line)), 0 })
    end
    push_target_snapshot(state, snapshot)
    local bufnr = vim.api.nvim_get_current_buf()
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.keymap.set('n', '<C-o>', function()
        jump_target_back(state)
      end, {
        buffer = bufnr,
        silent = true,
        nowait = true,
        desc = 'Return to Guit blame',
      })
    end
  end)
end

local function open_commit(state, keep_focus)
  local item = current_item(state)
  if not ensure_committed(item) then
    return
  end
  if vim.fn.exists(':Gedit') ~= 2 then
    vim.notify('guit.nvim: fugitive not found (:Gedit unavailable)', vim.log.levels.ERROR)
    return
  end
  open_in_target(state, function()
    vim.cmd(('Gedit %s'):format(item.hash))
  end)
  if not keep_focus and valid_win(state.target_winid) then
    vim.api.nvim_set_current_win(state.target_winid)
  end
end

local function open_show(state)
  local item = current_item(state)
  if not ensure_committed(item) then
    return
  end
  if not valid_win(state.target_winid) then
    vim.notify('guit.nvim: blame target window is gone', vim.log.levels.WARN)
    return
  end
  local current = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(state.target_winid)
  local ok, err = pcall(function()
    require('guit').show(item.hash, { cwd = state.cwd })
  end)
  if not ok then
    if valid_win(current) then
      vim.api.nvim_set_current_win(current)
    end
    vim.notify('guit.nvim: ' .. tostring(err), vim.log.levels.ERROR)
  end
end

local function cycle_mode(state)
  local modes = { 'color', 'plain', 'heat' }
  local index = 1
  for i, mode in ipairs(modes) do
    if mode == state.mode then
      index = i
      break
    end
  end
  state.mode = modes[index % #modes + 1]
  render(state)
end

local function save_win_options(state, winid)
  state.bound_win_options = state.bound_win_options or {}
  if not valid_win(winid) or state.bound_win_options[winid] then
    return
  end
  state.bound_win_options[winid] = {
    scrollbind = vim.wo[winid].scrollbind,
    cursorbind = vim.wo[winid].cursorbind,
    foldenable = vim.wo[winid].foldenable,
  }
end

local function set_bind(state, winid, enabled, opts)
  if not valid_win(winid) then
    return
  end
  opts = opts or {}
  if enabled then
    save_win_options(state, winid)
    vim.wo[winid].scrollbind = true
    vim.wo[winid].cursorbind = true
    return
  end

  local saved = state.bound_win_options and state.bound_win_options[winid] or nil
  if saved then
    vim.wo[winid].scrollbind = saved.scrollbind
    vim.wo[winid].cursorbind = saved.cursorbind
    vim.wo[winid].foldenable = saved.foldenable
    state.bound_win_options[winid] = nil
  else
    vim.wo[winid].scrollbind = false
    vim.wo[winid].cursorbind = false
  end
end

function resolve_target(winid)
  if not valid_win(winid) then
    return nil
  end

  local bufnr = vim.api.nvim_win_get_buf(winid)
  local source = fugitive.from_buffer(bufnr)
  if not source then
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name == '' or vim.bo[bufnr].buftype ~= '' then
      return nil
    end
    source = { path = name }
  end
  if not source.path or source.path == '' then
    return nil
  end

  local cwd = source.cwd or vim.fn.fnamemodify(source.path, ':p:h')
  local repo = git.repo_root(cwd)
  if not repo then
    return nil
  end

  return {
    target_winid = winid,
    target_bufnr = bufnr,
    cwd = repo,
    path = history.normalize_path(repo, source.path),
    rev = source.commit,
  }
end

local function same_target(state, target)
  return state.target_winid == target.target_winid
    and state.target_bufnr == target.target_bufnr
    and state.cwd == target.cwd
    and state.path == target.path
    and state.rev == target.rev
end

local function sync_to_target(state)
  if state.syncing then
    return
  end
  state.syncing = true
  set_bind(state, state.winid, true)
  set_bind(state, state.target_winid, true)
  if valid_win(state.winid) and valid_win(state.target_winid) then
    local current = vim.api.nvim_get_current_win()
    local target_cursor = vim.api.nvim_win_get_cursor(state.target_winid)
    pcall(vim.api.nvim_win_set_cursor, state.winid, { math.max(1, math.min(target_cursor[1], line_count(state.target_bufnr))), 0 })
    vim.api.nvim_set_current_win(state.target_winid)
    pcall(vim.cmd, 'syncbind')
    if valid_win(current) then
      vim.api.nvim_set_current_win(current)
    end
  end
  state.syncing = false
end

local function fetch_target(state, opts)
  state.request_id = (state.request_id or 0) + 1
  local request_id = state.request_id
  blame.fetch({ cwd = state.cwd, path = state.path, rev = state.rev }, function(items, err)
    if not valid_buf(state.bufnr) then
      return
    end
    if request_id ~= state.request_id then
      return
    end
    if err then
      state.items = {}
      state.current_hash = nil
      render(state)
      if not opts or not opts.silent then
        vim.notify('guit.nvim: ' .. err, vim.log.levels.ERROR)
      end
      return
    end
    state.current_hash = current_target_commit(state)
    state.items = items or {}
    render(state)
    sync_to_target(state)
  end)
end

function set_target(state, target, opts)
  if not target or not target.path then
    return
  end
  if same_target(state, target) and state.items and #state.items > 0 then
    sync_to_target(state)
    return
  end

  set_bind(state, state.target_winid, false)
  state.target_winid = target.target_winid
  state.target_bufnr = target.target_bufnr
  state.cwd = target.cwd
  state.path = target.path
  state.rev = target.rev
  fetch_target(state, opts)
end

local function set_keymaps(state)
  local opts = { buffer = state.bufnr, nowait = true, silent = true }
  vim.keymap.set('n', config.options.keymaps.open, function() open_file_revision(state) end, opts)
  vim.keymap.set('n', config.options.keymaps.commit, function() open_commit(state, true) end, opts)
  vim.keymap.set('n', config.options.keymaps.commit_focus, function() open_commit(state, false) end, opts)
  vim.keymap.set('n', config.options.keymaps.open_show, function() open_show(state) end, opts)
  vim.keymap.set('n', config.options.keymaps.toggle_view, function() cycle_mode(state) end, opts)
  vim.keymap.set('n', '<C-o>', function() jump_target_back(state) end, opts)
  vim.keymap.set('n', config.options.keymaps.close, function()
    if valid_win(state.winid) then
      vim.api.nvim_win_close(state.winid, true)
    end
  end, opts)
  vim.keymap.set('n', config.options.keymaps.help, function()
    vim.notify(table.concat({
      'Guit blame help',
      '',
      '  <CR>  open file at blamed revision in the target window',
      '  <C-o> jump back in the target window and keep focus here',
      '  c     open blamed commit in Fugitive and keep focus here',
      '  C     open blamed commit in Fugitive and move focus to target',
      '  s     open Guit show for blamed commit',
      '  t     cycle blame color mode',
      '  q     close blame pane',
      '  ?     show this help',
    }, '\n'), vim.log.levels.INFO, { title = 'guit.nvim' })
  end, opts)
end

local function attach_autocmds(state)
  local group = vim.api.nvim_create_augroup(('GuitBlame_%d'):format(state.bufnr), { clear = true })
  vim.api.nvim_create_autocmd({ 'WinEnter', 'BufEnter' }, {
    group = group,
    callback = function()
      if not valid_win(state.winid) then
        pcall(vim.api.nvim_del_augroup_by_id, group)
        return
      end
      if state.syncing then
        return
      end
      if state.restoring_target then
        return
      end
      if window.is_opening_pane() then
        return
      end
      local winid = vim.api.nvim_get_current_win()
      if winid == state.winid then
        return
      end
      set_target(state, resolve_target(winid), { silent = true })
    end,
  })
  vim.api.nvim_create_autocmd('WinResized', {
    group = group,
    callback = function()
      if valid_win(state.winid) then
        render(state)
      end
    end,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    buffer = state.bufnr,
    callback = function()
      state_by_buf[state.bufnr] = nil
      set_bind(state, state.target_winid, false)
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })
end

local function open_window(state)
  local target_winid = vim.api.nvim_get_current_win()
  vim.cmd(('topleft vertical %dsplit'):format(config.options.blame.width))
  local winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(winid, state.bufnr)

  vim.wo[winid].number = false
  vim.wo[winid].relativenumber = false
  vim.wo[winid].signcolumn = 'no'
  vim.wo[winid].foldcolumn = '0'
  vim.wo[winid].foldmethod = 'manual'
  vim.wo[winid].foldenable = false
  vim.wo[winid].wrap = false
  vim.wo[winid].winfixwidth = true
  vim.wo[winid].scrollbind = true
  vim.wo[winid].cursorbind = true
  vim.wo[winid].cursorline = true
  vim.wo[winid].winbar = ''

  return winid, target_winid
end

function M.open(opts)
  highlights.setup()

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = 'nofile'
  vim.bo[bufnr].bufhidden = 'wipe'
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = 'guitblame'
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly = true

  local state = {
    bufnr = bufnr,
    target_bufnr = opts.target_bufnr,
    cwd = opts.cwd,
    path = opts.path,
    mode = opts.mode or config.options.blame.mode,
    items = {},
    ns = vim.api.nvim_create_namespace(('guit-blame-%d'):format(bufnr)),
  }

  state.winid, state.target_winid = open_window(state)
  state.rev = opts.rev
  state_by_buf[bufnr] = state
  set_keymaps(state)
  attach_autocmds(state)
  sync_to_target(state)
  fetch_target(state)
end

return M
