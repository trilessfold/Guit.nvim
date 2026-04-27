local M = {}

local active = nil
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

function M.register(state, snapshot_fn)
  active = {
    bufnr = state.bufnr,
    winid = state.winid,
    state = state,
    snapshot_fn = snapshot_fn,
  }
  remember(snapshot_fn(state))
end

function M.update(state)
  if not active or active.state ~= state or not active.snapshot_fn then
    return
  end
  remember(active.snapshot_fn(state))
end

function M.clear(state)
  if active and active.state == state then
    active = nil
  end
end

function M.close_active()
  if not active or not valid_win(active.winid) then
    active = nil
    return false
  end

  if active.snapshot_fn then
    remember(active.snapshot_fn(active.state))
  end
  if valid_buf(active.bufnr) then
    vim.bo[active.bufnr].bufhidden = 'wipe'
  end
  vim.api.nvim_win_close(active.winid, true)
  active = nil
  return true
end

local function restore_log(snapshot)
  require('guit.ui.buffer').open({
    cwd = snapshot.cwd,
    rev = snapshot.rev,
    restore = snapshot.restore,
  })
end

local function restore_show(snapshot)
  require('guit.ui.show_buffer').open({
    cwd = snapshot.cwd,
    commit = snapshot.commit,
    view_mode = snapshot.view_mode,
    restore = snapshot.restore,
  })
end

local function restore_history(snapshot)
  require('guit.ui.history_buffer').open({
    cwd = snapshot.cwd,
    path = snapshot.path,
    path_display = snapshot.path_display,
    rev = snapshot.rev,
    is_file = snapshot.is_file,
    restore = snapshot.restore,
  })
end

local function restore_compare(snapshot)
  require('guit.ui.compare_buffer').open({
    cwd = snapshot.cwd,
    left = snapshot.left,
    right = snapshot.right,
    view_mode = snapshot.view_mode,
    restore = snapshot.restore,
  })
end

function M.restore(default_open)
  if active and valid_win(active.winid) then
    vim.api.nvim_set_current_win(active.winid)
    return true
  end

  local snapshot = last
  if not snapshot then
    if default_open then
      default_open()
    end
    return false
  end

  if snapshot.kind == 'log' then
    restore_log(snapshot)
  elseif snapshot.kind == 'show' then
    restore_show(snapshot)
  elseif snapshot.kind == 'history' then
    restore_history(snapshot)
  elseif snapshot.kind == 'compare' then
    restore_compare(snapshot)
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
  return active ~= nil and valid_win(active.winid) and valid_buf(active.bufnr)
end

return M
