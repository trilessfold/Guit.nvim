local config = require('guit.config')
local changed_files = require('guit.changed_files')
local compare = require('guit.compare')
local highlights = require('guit.ui.highlight')
local keymaps = require('guit.ui.changed_file_keymaps')
local render = require('guit.ui.compare_render')
local panel = require('guit.ui.changed_file_panel')
local window = require('guit.ui.window')
local ui_util = require('guit.ui.util')
local preview = require('guit.ui.preview')
local session = require('guit.session')

local M = {}

local function snapshot(state)
  local entry, idx = panel.current_entry(state)
  return {
    kind = 'compare',
    cwd = state.cwd,
    left = state.left,
    right = state.right,
    view_mode = state.view_mode,
    restore = {
      line = idx,
      path = entry and entry.full_path or nil,
    },
  }
end
local function open_file_diff(state, entry, keep_focus)
  if not entry or entry.kind ~= 'file' then return end
  if vim.fn.exists(':Gedit') ~= 2 or vim.fn.exists(':Gdiffsplit') ~= 2 then
    vim.notify('guit.nvim: fugitive not found (:Gedit / :Gdiffsplit unavailable)', vim.log.levels.ERROR)
    return
  end
  local ok, err = preview.with_managed_preview(state, function()
    vim.cmd(('Gedit %s:%s'):format(state.right, vim.fn.fnameescape(entry.full_path)))
    vim.cmd(('Gdiffsplit! %s:%s'):format(state.left, vim.fn.fnameescape(entry.old_path or entry.full_path)))
  end)
  if not ok then
    vim.notify('guit.nvim: failed to open compare diff in fugitive: ' .. tostring(err), vim.log.levels.ERROR)
    if keep_focus and state.winid and vim.api.nvim_win_is_valid(state.winid) then
      vim.api.nvim_set_current_win(state.winid)
    end
    return
  end
  if keep_focus and state.winid and vim.api.nvim_win_is_valid(state.winid) then
    vim.api.nvim_set_current_win(state.winid)
  end
end

local function refresh(state)
  compare.fetch_changed_files({ cwd = state.cwd, left = state.left, right = state.right }, function(items, err)
    if not vim.api.nvim_buf_is_valid(state.bufnr) then return end
    if err then vim.notify('guit.nvim: ' .. err, vim.log.levels.ERROR); return end
    state.items = items or {}
    local function apply_items()
      state.tree_state = changed_files.build_state(state.items)
      panel.rerender(state, render)
    end
    if config.options.show.show_counts then
      compare.fetch_numstat({ cwd = state.cwd, left = state.left, right = state.right }, function(stats, total, stats_err)
        if not vim.api.nvim_buf_is_valid(state.bufnr) then return end
        if stats_err then
          vim.notify('guit.nvim: ' .. stats_err, vim.log.levels.WARN)
          state.summary = { additions = 0, deletions = 0 }
          apply_items()
          return
        end
        compare.enrich_with_numstat(state.items, stats or {})
        state.summary = total or { additions = 0, deletions = 0 }
        apply_items()
      end)
    else
      state.summary = nil
      apply_items()
    end
  end)
  compare.fetch_meta({ cwd = state.cwd, left = state.left, right = state.right }, function(meta, err)
    if not vim.api.nvim_buf_is_valid(state.bufnr) then return end
    if err then vim.notify('guit.nvim: ' .. err, vim.log.levels.WARN); return end
    state.meta = meta
    panel.rerender(state, render, (panel.current_entry(state) or {}).full_path)
  end)
end

local function attach_autocmds(state)
  local group = vim.api.nvim_create_augroup(('GuitCompare_%d'):format(state.bufnr), { clear = true })
  vim.api.nvim_create_autocmd({ 'CursorMoved', 'BufEnter' }, {
    group = group, buffer = state.bufnr,
    callback = function()
      render.update_selected_line(state)
      render.update_winbar(state)
      session.update(state)
    end,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group, buffer = state.bufnr,
    callback = function()
      session.clear(state)
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })
end

local function help()
  vim.notify(table.concat({
    'Guit compare help', '',
    '  <CR>  open file diff between compared revisions and keep focus here',
    '  o     open file diff and move focus to target window',
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
  }, '\n'), vim.log.levels.INFO, { title = 'guit.nvim' })
end

local function set_keymaps(state)
  keymaps.attach(state, render, {
    refresh = refresh,
    help = help,
    open_file = open_file_diff,
  })
end

function M.open(opts)
  highlights.setup()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = 'nofile'; vim.bo[bufnr].bufhidden = 'wipe'; vim.bo[bufnr].swapfile = false; vim.bo[bufnr].filetype = 'guitcompare'; vim.bo[bufnr].modifiable = false; vim.bo[bufnr].readonly = true
  local winid = opts.reuse_winid
  local target_winid = opts.target_winid
  if winid and vim.api.nvim_win_is_valid(winid) then
    ui_util.with_winfixbuf_disabled(winid, function() vim.api.nvim_win_set_buf(winid, bufnr) end)
    vim.api.nvim_set_current_win(winid)
  else
    winid, target_winid = window.open_bottom_pane(bufnr)
  end
  local state = {
    bufnr = bufnr, winid = winid, target_winid = target_winid, cwd = opts.cwd,
    left = opts.left, right = opts.right,
    ns = vim.api.nvim_create_namespace(('guit-compare-%d'):format(bufnr)),
    selection_ns = vim.api.nvim_create_namespace(('guit-compare-select-%d'):format(bufnr)),
    view_mode = opts.view_mode or config.options.show.default_view,
    items = {}, entries = {}, tree_state = nil, entry_offset = 0, meta = nil, summary = nil,
    restore = opts.restore, restore_done = false,
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
