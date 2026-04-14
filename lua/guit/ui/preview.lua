local ui_util = require('guit.ui.util')

local M = {}

local function unique_list(items)
  local seen, out = {}, {}
  for _, item in ipairs(items or {}) do
    if item and not seen[item] then
      seen[item] = true
      out[#out + 1] = item
    end
  end
  return out
end

local function snapshot_windows(tabpage)
  local wins = {}
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
    wins[winid] = true
  end
  return wins
end

local function pick_anchor(state)
  local preview = state.preview or {}
  local candidates = {
    state.target_winid,
    preview.anchor_winid,
  }

  for _, winid in ipairs(candidates) do
    if winid and vim.api.nvim_win_is_valid(winid) then
      return winid
    end
  end

  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if winid ~= state.winid and vim.api.nvim_win_is_valid(winid) then
      return winid
    end
  end

  return vim.api.nvim_get_current_win()
end

local function visible_buffers(exclude_winids)
  local visible = {}
  local exclude = {}
  for _, winid in ipairs(exclude_winids or {}) do
    exclude[winid] = true
  end
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(winid) and not exclude[winid] then
      visible[vim.api.nvim_win_get_buf(winid)] = true
    end
  end
  return visible
end

function M.ensure_state(state)
  state.preview = state.preview or {
    anchor_winid = state.target_winid,
    extra_wins = {},
    buffers = {},
  }
  return state.preview
end

function M.begin(state)
  local preview = M.ensure_state(state)
  local anchor_winid = pick_anchor(state)

  for _, winid in ipairs(preview.extra_wins or {}) do
    if winid ~= anchor_winid and vim.api.nvim_win_is_valid(winid) then
      pcall(vim.api.nvim_win_close, winid, true)
    end
  end

  local visible = visible_buffers({ state.winid })
  for _, bufnr in ipairs(preview.buffers or {}) do
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) and not visible[bufnr] then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end

  preview.extra_wins = {}
  preview.buffers = {}
  preview.anchor_winid = anchor_winid
  state.target_winid = anchor_winid

  return {
    anchor_winid = anchor_winid,
    tabpage = vim.api.nvim_get_current_tabpage(),
    before_windows = snapshot_windows(vim.api.nvim_get_current_tabpage()),
  }
end

function M.finish(state, ctx)
  local preview = M.ensure_state(state)
  local anchor_winid = ctx.anchor_winid
  if not anchor_winid or not vim.api.nvim_win_is_valid(anchor_winid) then
    anchor_winid = state.target_winid
  end
  if not anchor_winid or not vim.api.nvim_win_is_valid(anchor_winid) then
    anchor_winid = vim.api.nvim_get_current_win()
  end

  local extra_wins = {}
  local buffers = {}

  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(ctx.tabpage)) do
    if not ctx.before_windows[winid] and winid ~= state.winid then
      extra_wins[#extra_wins + 1] = winid
    end
  end

  if anchor_winid and vim.api.nvim_win_is_valid(anchor_winid) then
    buffers[#buffers + 1] = vim.api.nvim_win_get_buf(anchor_winid)
  end
  for _, winid in ipairs(extra_wins) do
    if vim.api.nvim_win_is_valid(winid) then
      buffers[#buffers + 1] = vim.api.nvim_win_get_buf(winid)
    end
  end

  preview.anchor_winid = anchor_winid
  preview.extra_wins = unique_list(extra_wins)
  preview.buffers = unique_list(buffers)
  state.target_winid = anchor_winid
end

function M.with_managed_preview(state, fn)
  local ctx = M.begin(state)
  local ok, err = pcall(function()
    ui_util.with_winfixbuf_disabled(ctx.anchor_winid, function()
      vim.api.nvim_set_current_win(ctx.anchor_winid)
      fn(ctx.anchor_winid)
    end)
  end)
  if ok then
    M.finish(state, ctx)
    return true
  end
  return false, err
end

return M
