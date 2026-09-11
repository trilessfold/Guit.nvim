local config = require('guit.config')
local changed_files = require('guit.changed_files')
local compare = require('guit.compare')
local highlights = require('guit.ui.highlight')
local keymaps = require('guit.ui.changed_file_keymaps')
local render = require('guit.ui.compare_render')
local panel = require('guit.ui.changed_file_panel')
local window = require('guit.ui.window')
local ui_util = require('guit.ui.util')
local diff = require('guit.ui.diff')
local handoff = require('guit.ui.handoff')
local session = require('guit.session')

local M = {}

local state_by_buf = {}

--- The two sides of a file's change between the compared revisions.
---
--- An empty `state.right` is the working tree (`:Guit compare <rev>`), which
--- the diff module recognises by the missing revision. Added files have no
--- left side and deleted files no right side.
local function diff_spec(state, entry)
  local status = (entry.status or ''):sub(1, 1)
  -- Three-dot lists what `right` changed since the merge base, so that, not
  -- `left` itself, is the old side of every file; refresh resolves it in the
  -- background, and a dd that comes first resolves it on the spot.
  local left_rev = state.left
  if state.symmetric then
    if not state.merge_base then
      local base, err = compare.merge_base({ cwd = state.cwd, left = state.left, right = state.right })
      if not base then
        vim.notify('guit.nvim: ' .. err, vim.log.levels.ERROR)
        return nil
      end
      state.merge_base = base
    end
    left_rev = state.merge_base
  end
  local left = { rev = left_rev, path = entry.old_path or entry.full_path }
  local right = { rev = state.right, path = entry.full_path }
  if status == 'A' then
    left = nil
  elseif status == 'D' then
    right = nil
  end
  return { cwd = state.cwd, left = left, right = right }
end

local function snapshot(state)
  local entry, idx = panel.current_entry(state)
  return {
    kind = 'compare',
    cwd = state.cwd,
    left = state.left,
    right = state.right,
    symmetric = state.symmetric,
    source_log = state.source_log,
    view_mode = state.view_mode,
    restore = {
      line = idx,
      path = entry and entry.full_path or nil,
    },
  }
end
local function open_file_diff(state, entry, keep_focus, mode)
  if not entry or entry.kind ~= 'file' then return end
  local spec = diff_spec(state, entry)
  if not spec then return end
  diff.open(state, spec, { mode = mode, keep_focus = keep_focus })
end

--- The object a row stands for: the file on the right side, or the right
--- revision itself on a directory row. Against the working tree the right
--- side has no revision, so the object is the plain path.
local function object_of(state, entry)
  local worktree = not state.right or state.right == ''
  if entry and entry.kind == 'file' then
    if worktree then
      return entry.full_path
    end
    return ('%s:%s'):format(state.right, entry.full_path)
  end
  return worktree and state.left or state.right
end

--- The revision arguments every compare fetch shares.
local function range_of(state)
  return { cwd = state.cwd, left = state.left, right = state.right, symmetric = state.symmetric }
end

local function refresh(state)
  state.generation = (state.generation or 0) + 1
  local generation = state.generation
  state.merge_base = nil
  if state.symmetric then
    compare.fetch_merge_base(range_of(state), function(base, err)
      if not vim.api.nvim_buf_is_valid(state.bufnr) then return end
      if generation ~= state.generation then return end
      if err then vim.notify('guit.nvim: ' .. err, vim.log.levels.WARN); return end
      state.merge_base = base
    end)
  end
  compare.fetch_changed_files(range_of(state), function(items, err)
    if not vim.api.nvim_buf_is_valid(state.bufnr) then return end
    -- Results of a superseded refresh must not be applied on top of the list a
    -- newer one already installed.
    if generation ~= state.generation then return end
    if err then vim.notify('guit.nvim: ' .. err, vim.log.levels.ERROR); return end
    state.items = items or {}
    local function apply_items()
      state.tree_state = changed_files.build_state(state.items)
      panel.rerender(state, render)
    end
    if config.options.show.show_counts then
      compare.fetch_numstat(range_of(state), function(stats, total, stats_err)
        if not vim.api.nvim_buf_is_valid(state.bufnr) then return end
        if generation ~= state.generation then return end
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
  compare.fetch_meta(range_of(state), function(meta, err)
    if not vim.api.nvim_buf_is_valid(state.bufnr) then return end
    if generation ~= state.generation then return end
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
      state_by_buf[state.bufnr] = nil
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })
end


local function set_keymaps(state)
  keymaps.attach(state, render, {
    title = 'Guit compare',
    -- Only a compare that took over a log or history pane's window has
    -- somewhere to go back to.
    back = state.source_log and handoff.back or nil,
    refresh = refresh,
    open_file = open_file_diff,
    open_diff = open_file_diff,
    yank_hash = function(s)
      ui_util.yank(object_of(s, panel.current_entry(s)))
    end,
    cmdline = function(s)
      ui_util.put_on_cmdline(object_of(s, panel.current_entry(s)))
    end,
  })
end

function M.open(opts)
  highlights.setup()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = 'nofile'; vim.bo[bufnr].bufhidden = 'wipe'; vim.bo[bufnr].swapfile = false; vim.bo[bufnr].modifiable = false; vim.bo[bufnr].readonly = true
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
    left = opts.left, right = opts.right, symmetric = opts.symmetric,
    ns = vim.api.nvim_create_namespace(('guit-compare-%d'):format(bufnr)),
    selection_ns = vim.api.nvim_create_namespace(('guit-compare-select-%d'):format(bufnr)),
    view_mode = opts.view_mode or config.options.show.default_view,
    items = {}, entries = {}, tree_state = nil, entry_offset = 0, meta = nil, summary = nil,
    restore = opts.restore, restore_done = false,
    source_log = opts.source_log,
    preview = opts.preview or { anchor_winid = target_winid, extra_wins = {}, buffers = {} },
  }
  state_by_buf[bufnr] = state
  session.register(state, snapshot)
  attach_autocmds(state)
  set_keymaps(state)
  -- Set last: FileType fires here, so after/ftplugin/guitcompare.lua runs
  -- after the plugin's own mappings and can override them.
  vim.bo[bufnr].filetype = 'guitcompare'
  render.update_winbar(state)
  ui_util.set_readonly(bufnr, true)
  refresh(state)
end

--- Re-attaches a pane that was hidden while another view borrowed its window.
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
