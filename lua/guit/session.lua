local M = {}

-- Every open Guit pane, keyed by its buffer. A single global slot meant the
-- second pane to open silently replaced the first: `q` in the older pane then
-- closed the newer one, and the older pane became unreachable to :Guit toggle.
local panes = {}

-- The pane :Guit toggle acts on: whichever was focused most recently.
local active_bufnr = nil

-- Snapshot of the last pane state, so toggle can recreate a closed view.
local last = nil

local function valid_win(winid)
  return winid and vim.api.nvim_win_is_valid(winid)
end

local function valid_buf(bufnr)
  return bufnr and vim.api.nvim_buf_is_valid(bufnr)
end

local function clone(value)
  return vim.deepcopy(value or {})
end

local function remember(snapshot)
  if snapshot and snapshot.kind then
    last = clone(snapshot)
  end
end

local function entry_for(state)
  local entry = state and panes[state.bufnr]
  if entry and entry.state == state then
    return entry
  end
  return nil
end

--- Wipes the pane a view was opened from, if it is still hidden.
---
--- Opening `Guit show` from a log pane sets the log buffer to bufhidden=hide so
--- `-` can return to it. On the path where the user never goes back, nothing
--- used to wipe it, so its buffer, its state entry and its augroup survived for
--- the rest of the session -- one leak per log -> show -> q cycle.
local function release_origin(state)
  local origin = state and state.source_log
  local bufnr = origin and origin.bufnr
  if not valid_buf(bufnr) then
    return
  end
  -- Still on screen somewhere: it is not ours to reclaim.
  if vim.fn.bufwinid(bufnr) ~= -1 then
    return
  end
  if vim.bo[bufnr].modified then
    return
  end
  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
end

function M.register(state, snapshot_fn)
  panes[state.bufnr] = {
    bufnr = state.bufnr,
    winid = state.winid,
    state = state,
    snapshot_fn = snapshot_fn,
  }
  active_bufnr = state.bufnr
  remember(snapshot_fn(state))
end

function M.update(state)
  local entry = entry_for(state)
  if not entry or not entry.snapshot_fn then
    return
  end
  -- Entering a pane makes it the one toggle and `q` act on, so returning to an
  -- older pane hands control back to it.
  entry.winid = state.winid
  active_bufnr = state.bufnr
  remember(entry.snapshot_fn(state))
end

function M.clear(state)
  local entry = entry_for(state)
  if not entry then
    return
  end
  panes[state.bufnr] = nil
  if active_bufnr == state.bufnr then
    active_bufnr = nil
  end
  -- The pane is being wiped; its origin cannot be reached any more.
  vim.schedule(function()
    release_origin(state)
    require('guit.ui.inline_diff').detach_owned(state)
  end)
end

local function close_entry(entry)
  if not entry or not valid_win(entry.winid) then
    return false
  end

  if entry.snapshot_fn then
    remember(entry.snapshot_fn(entry.state))
  end
  release_origin(entry.state)
  require('guit.ui.inline_diff').detach_owned(entry.state)
  if valid_buf(entry.bufnr) then
    vim.bo[entry.bufnr].bufhidden = 'wipe'
  end
  vim.api.nvim_win_close(entry.winid, true)

  panes[entry.bufnr] = nil
  if active_bufnr == entry.bufnr then
    active_bufnr = nil
  end
  return true
end

--- Closes one specific pane. This is what `q` inside a pane must call, so it
--- always closes the pane the key was pressed in.
function M.close(state)
  return close_entry(entry_for(state))
end

--- Closes the most recently focused pane. Used by :Guit toggle.
function M.close_active()
  local entry = active_bufnr and panes[active_bufnr]
  if not entry then
    active_bufnr = nil
    return false
  end
  return close_entry(entry)
end

local function restore_log(snapshot, opts)
  opts = opts or {}
  require('guit.ui.buffer').open({
    cwd = snapshot.cwd,
    rev = snapshot.rev,
    restore = snapshot.restore,
    reuse_winid = opts.reuse_winid,
    target_winid = opts.target_winid,
    preview = opts.preview,
  })
end

local function restore_show(snapshot, opts)
  opts = opts or {}
  require('guit.ui.show_buffer').open({
    cwd = snapshot.cwd,
    commit = snapshot.commit,
    view_mode = snapshot.view_mode,
    source_log = snapshot.source_log,
    restore = snapshot.restore,
    reuse_winid = opts.reuse_winid,
    target_winid = opts.target_winid,
    preview = opts.preview,
  })
end

local function restore_history(snapshot, opts)
  opts = opts or {}
  require('guit.ui.history_buffer').open({
    cwd = snapshot.cwd,
    path = snapshot.path,
    path_display = snapshot.path_display,
    rev = snapshot.rev,
    is_file = snapshot.is_file,
    line_range = snapshot.line_range,
    hide_stats = snapshot.hide_stats,
    replaced = snapshot.replaced,
    follow = snapshot.follow,
    restore = snapshot.restore,
    reuse_winid = opts.reuse_winid,
    target_winid = opts.target_winid,
    preview = opts.preview,
  })
end

local function restore_compare(snapshot, opts)
  opts = opts or {}
  require('guit.ui.compare_buffer').open({
    cwd = snapshot.cwd,
    left = snapshot.left,
    right = snapshot.right,
    symmetric = snapshot.symmetric,
    source_log = snapshot.source_log,
    view_mode = snapshot.view_mode,
    restore = snapshot.restore,
    reuse_winid = opts.reuse_winid,
    target_winid = opts.target_winid,
    preview = opts.preview,
  })
end

local function restore_status(snapshot, opts)
  opts = opts or {}
  require('guit.ui.status_buffer').open({
    cwd = snapshot.cwd,
    view_mode = snapshot.view_mode,
    restore = snapshot.restore,
    reuse_winid = opts.reuse_winid,
    target_winid = opts.target_winid,
    preview = opts.preview,
  })
end

function M.open_snapshot(snapshot, opts)
  if snapshot.kind == 'log' then
    restore_log(snapshot, opts)
  elseif snapshot.kind == 'show' then
    restore_show(snapshot, opts)
  elseif snapshot.kind == 'history' then
    restore_history(snapshot, opts)
  elseif snapshot.kind == 'compare' then
    restore_compare(snapshot, opts)
  elseif snapshot.kind == 'status' then
    restore_status(snapshot, opts)
  end
end

function M.restore(default_open)
  local entry = active_bufnr and panes[active_bufnr]
  if entry and valid_win(entry.winid) then
    vim.api.nvim_set_current_win(entry.winid)
    return true
  end

  local snapshot = last
  if not snapshot then
    if default_open then
      default_open()
    end
    return false
  end

  if snapshot.kind == 'log' or snapshot.kind == 'show' or snapshot.kind == 'history' or snapshot.kind == 'compare' or snapshot.kind == 'status' then
    M.open_snapshot(snapshot)
  elseif default_open then
    default_open()
  end
  return true
end

function M.toggle(default_open)
  if M.close_active() then
    return
  end
  M.restore(default_open)
end

function M.has_active()
  local entry = active_bufnr and panes[active_bufnr]
  return entry ~= nil and valid_win(entry.winid) and valid_buf(entry.bufnr)
end

return M
