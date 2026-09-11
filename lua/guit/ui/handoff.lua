local session = require('guit.session')
local ui_util = require('guit.ui.util')

--- One pane handing its window to another view, and getting it back.
---
--- `s` in a log opens show in the log's own window rather than as a second
--- pane: the log is hidden, not closed, and `-` in show puts it back with the
--- cursor where it was. Compare opened from a log or history pane works the
--- same way. It used to open as a new pane below the log, which then became
--- compare's target window: the first file diff opened from compare replaced
--- the log, and a split from there left more windows on screen than any other
--- path to the same diff.
local M = {}

local ACTIVATORS = {
  guitlog = 'guit.ui.buffer',
  guithistory = 'guit.ui.history_buffer',
  guitcompare = 'guit.ui.compare_buffer',
  guitstatus = 'guit.ui.status_buffer',
}

--- Opens another view in a pane's own window.
---@param state table the pane giving up its window
---@param origin table { line = integer|nil, snapshot = table|nil }
---@param open fun(opts: table): boolean|nil receives reuse_winid, target_winid, source_log and preview; false means nothing was opened
---@param what string the view being opened, for the error message
---@return boolean opened
function M.replace(state, origin, open, what)
  if not (state.target_winid and vim.api.nvim_win_is_valid(state.target_winid)) then
    state.target_winid = nil
  end
  -- Hidden rather than wiped once the new view takes the window, so `-` can
  -- bring it back.
  vim.bo[state.bufnr].bufhidden = 'hide'

  local ok, result = pcall(open, {
    reuse_winid = state.winid,
    target_winid = state.target_winid,
    source_log = { bufnr = state.bufnr, line = origin.line, snapshot = origin.snapshot },
    preview = state.preview,
  })

  if ok and result ~= false then
    return true
  end
  -- Nothing took the window: the pane keeps its normal lifetime.
  if vim.api.nvim_buf_is_valid(state.bufnr) then
    vim.bo[state.bufnr].bufhidden = 'wipe'
  end
  if not ok then
    vim.notify(('guit.nvim: failed to open %s: %s'):format(what, tostring(result)), vim.log.levels.ERROR)
  end
  return false
end

--- Puts the pane a view was opened from back into the view's window, with
--- the cursor on the line it was on. A pane that has been wiped since is
--- rebuilt from its snapshot.
---@param state table the view's state, carrying `source_log`
function M.back(state)
  local origin = state.source_log
  if not origin then
    vim.notify('guit.nvim: the pane this was opened from is no longer available', vim.log.levels.WARN)
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

    vim.notify('guit.nvim: the pane this was opened from is no longer available', vim.log.levels.WARN)
    return
  end

  vim.bo[origin.bufnr].bufhidden = 'hide'
  ui_util.with_winfixbuf_disabled(winid, function()
    vim.api.nvim_win_set_buf(winid, origin.bufnr)
  end)
  local line = math.max(1, math.min(origin.line or 1, vim.api.nvim_buf_line_count(origin.bufnr)))
  vim.api.nvim_win_set_cursor(winid, { line, 0 })
  vim.api.nvim_set_current_win(winid)
  local module = ACTIVATORS[vim.bo[origin.bufnr].filetype]
  if module then
    require(module).activate(origin.bufnr, winid)
  end
end

return M
