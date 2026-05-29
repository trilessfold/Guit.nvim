local changed_files = require('guit.changed_files')
local config = require('guit.config')
local highlights = require('guit.ui.highlight')
local keymaps = require('guit.ui.changed_file_keymaps')
local panel = require('guit.ui.changed_file_panel')
local preview = require('guit.ui.preview')
local render = require('guit.ui.status_render')
local session = require('guit.session')
local status = require('guit.status')
local ui_util = require('guit.ui.util')
local window = require('guit.ui.window')

local M = {}

local function snapshot(state)
  local entry, idx = panel.current_entry(state)
  return {
    kind = 'status',
    cwd = state.cwd,
    view_mode = state.view_mode,
    restore = {
      line = idx,
      path = entry and entry.full_path or nil,
    },
  }
end

local function file_path(entry)
  return entry and (entry.worktree_path or entry.full_path)
end

local function open_file_diff(state, entry, keep_focus)
  if not entry or entry.kind ~= 'file' then
    return
  end
  local path = file_path(entry)
  if not path then
    return
  end
  if vim.fn.exists(':Gedit') ~= 2 or vim.fn.exists(':Gdiffsplit') ~= 2 then
    vim.notify('guit.nvim: fugitive not found (:Gedit / :Gdiffsplit unavailable)', vim.log.levels.ERROR)
    return
  end

  local ok, err = preview.with_managed_preview(state, function()
    if entry.section == 'staged' then
      vim.cmd(('Gedit :0:%s'):format(vim.fn.fnameescape(path)))
      vim.cmd(('Gdiffsplit! HEAD:%s'):format(vim.fn.fnameescape(entry.worktree_old_path or path)))
    elseif entry.section == 'unstaged' then
      vim.cmd('edit ' .. vim.fn.fnameescape(state.cwd .. '/' .. path))
      vim.cmd(('Gdiffsplit! :0:%s'):format(vim.fn.fnameescape(path)))
    else
      vim.cmd('edit ' .. vim.fn.fnameescape(state.cwd .. '/' .. path))
    end
  end)
  if not ok then
    vim.notify('guit.nvim: failed to open status diff in fugitive: ' .. tostring(err), vim.log.levels.ERROR)
  end
  if keep_focus and state.winid and vim.api.nvim_win_is_valid(state.winid) then
    vim.api.nvim_set_current_win(state.winid)
  end
end

local function open_worktree_file(state, entry, keep_focus)
  if not entry or entry.kind ~= 'file' then
    return
  end
  local path = file_path(entry)
  if not path then
    return
  end
  if vim.fn.exists(':Gedit') ~= 2 then
    vim.notify('guit.nvim: fugitive not found (:Gedit unavailable)', vim.log.levels.ERROR)
    return
  end

  local ok, err = preview.with_managed_preview(state, function()
    vim.cmd(('Gedit %s'):format(vim.fn.fnameescape(path)))
  end)
  if not ok then
    vim.notify('guit.nvim: failed to open status file: ' .. tostring(err), vim.log.levels.ERROR)
  end
  if keep_focus and state.winid and vim.api.nvim_win_is_valid(state.winid) then
    vim.api.nvim_set_current_win(state.winid)
  end
end

local function apply_items(state, items, staged_stats, unstaged_stats)
  state.items = items or {}
  state.summary = status.enrich_with_numstat(state.items, staged_stats or {}, unstaged_stats or {})
  state.tree_state = changed_files.build_state(state.items)
  panel.rerender(state, render)
end

local function refresh(state)
  status.fetch({ cwd = state.cwd }, function(items, err)
    if not vim.api.nvim_buf_is_valid(state.bufnr) then
      return
    end
    if err then
      vim.notify('guit.nvim: ' .. err, vim.log.levels.ERROR)
      return
    end
    status.fetch_numstat({ cwd = state.cwd }, true, function(staged_stats)
      if not vim.api.nvim_buf_is_valid(state.bufnr) then
        return
      end
      status.fetch_numstat({ cwd = state.cwd }, false, function(unstaged_stats)
        if not vim.api.nvim_buf_is_valid(state.bufnr) then
          return
        end
        apply_items(state, items, staged_stats, unstaged_stats)
      end)
    end)
  end)
end

local function help()
  vim.notify(table.concat({
    'Guit status help', '',
    '  <CR>  open working tree file and keep focus here',
    '  o     open working tree file and move to target window',
    '  dd    open working tree diff and keep focus here',
    '  <Tab> jump to target window',
    '  [z    jump to parent directory',
    '  zP    jump to top-level directory for the current branch',
    '  zj/zJ jump to next sibling entry',
    '  zk/zK jump to previous sibling entry',
    '  t     toggle tree/list',
    '  h/l   collapse/expand current directory',
    '  H/L   collapse/expand current subtree',
    '  zM/zR collapse/expand whole tree',
    '  r     refresh',
    '  q     close pane',
    '',
    'Read-only viewer: no stage, unstage, or restore actions.',
  }, '\n'), vim.log.levels.INFO, { title = 'guit.nvim' })
end

local function attach_autocmds(state)
  local group = vim.api.nvim_create_augroup(('GuitStatus_%d'):format(state.bufnr), { clear = true })
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
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })
end

local function set_keymaps(state)
  keymaps.attach(state, render, {
    refresh = refresh,
    help = help,
    open_file = open_worktree_file,
    open_diff = open_file_diff,
  })
end

function M.open(opts)
  highlights.setup()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = 'nofile'
  vim.bo[bufnr].bufhidden = 'wipe'
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = 'guitstatus'
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly = true

  local winid = opts.reuse_winid
  local target_winid = opts.target_winid
  if winid and vim.api.nvim_win_is_valid(winid) then
    ui_util.with_winfixbuf_disabled(winid, function() vim.api.nvim_win_set_buf(winid, bufnr) end)
    vim.api.nvim_set_current_win(winid)
  else
    winid, target_winid = window.open_bottom_pane(bufnr)
  end

  local state = {
    bufnr = bufnr,
    winid = winid,
    target_winid = target_winid,
    cwd = opts.cwd,
    ns = vim.api.nvim_create_namespace(('guit-status-%d'):format(bufnr)),
    selection_ns = vim.api.nvim_create_namespace(('guit-status-select-%d'):format(bufnr)),
    view_mode = opts.view_mode or config.options.show.default_view,
    items = {},
    entries = {},
    tree_state = nil,
    sectioned_list = true,
    entry_offset = 0,
    summary = nil,
    restore = opts.restore,
    restore_done = false,
    preview = opts.preview or { anchor_winid = target_winid, extra_wins = {}, buffers = {} },
  }
  session.register(state, snapshot)
  attach_autocmds(state)
  set_keymaps(state)
  render.update_winbar(state)
  ui_util.set_readonly(bufnr, true)
  refresh(state)
end

return M
