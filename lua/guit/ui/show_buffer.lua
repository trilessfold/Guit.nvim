local config = require('guit.config')
local changed_files = require('guit.changed_files')
local git = require('guit.git')
local highlights = require('guit.ui.highlight')
local keymaps = require('guit.ui.changed_file_keymaps')
local render = require('guit.ui.show_render')
local panel = require('guit.ui.changed_file_panel')
local window = require('guit.ui.window')
local ui_util = require('guit.ui.util')
local preview = require('guit.ui.preview')
local diff = require('guit.ui.diff')
local session = require('guit.session')

local M = {}

local state_by_buf = {}

local function return_to_panel(state)
  if state.winid and vim.api.nvim_win_is_valid(state.winid) then
    vim.api.nvim_set_current_win(state.winid)
  elseif state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
    vim.cmd('buffer ' .. state.bufnr)
  end
end

local function return_to_log(state)
  local origin = state.source_log
  if not origin then
    vim.notify('guit.nvim: original Guit log buffer is no longer available', vim.log.levels.WARN)
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

    vim.notify('guit.nvim: original Guit log buffer is no longer available', vim.log.levels.WARN)
    return
  end

  vim.bo[origin.bufnr].bufhidden = 'hide'
  ui_util.with_winfixbuf_disabled(winid, function()
    vim.api.nvim_win_set_buf(winid, origin.bufnr)
  end)
  local line = math.max(1, math.min(origin.line or 1, vim.api.nvim_buf_line_count(origin.bufnr)))
  vim.api.nvim_win_set_cursor(winid, { line, 0 })
  vim.api.nvim_set_current_win(winid)
  local activators = {
    guitlog = 'guit.ui.buffer',
    guithistory = 'guit.ui.history_buffer',
    guitcompare = 'guit.ui.compare_buffer',
    guitstatus = 'guit.ui.status_buffer',
  }
  local module = activators[vim.bo[origin.bufnr].filetype]
  if module then
    require(module).activate(origin.bufnr, winid)
  end
end


local function snapshot(state)
  local entry, idx = panel.current_entry(state)
  local source_log = state.source_log and {
    bufnr = state.source_log.bufnr,
    line = state.source_log.line,
    snapshot = state.source_log.snapshot,
  } or nil
  return {
    kind = 'show',
    cwd = state.cwd,
    commit = state.commit,
    view_mode = state.view_mode,
    source_log = source_log,
    restore = {
      line = idx,
      path = entry and entry.full_path or nil,
    },
  }
end

--- The two sides of a file's change in this commit.
---
--- A root commit has no parent, so nothing is on the left; an added file has
--- nothing there either, and a deleted one has nothing on the right. Building
--- a `<commit>^:path` object for those would fail inside fugitive.
local function diff_spec(state, entry)
  local status = (entry.status or ''):sub(1, 1)
  -- The file list usually lands before the commit metadata; until it does,
  -- ask git directly rather than assume a parent exists.
  local root
  if state.meta and state.meta.parents then
    root = diff.is_root_commit(state.meta.parents)
  else
    root = not changed_files.has_parent(state.cwd, state.commit)
  end
  local left = { rev = changed_files.parent_of(state.commit), path = entry.old_path or entry.full_path }
  local right = { rev = state.commit, path = entry.full_path }
  if status == 'D' then
    right = nil
  elseif status == 'A' or root then
    left = nil
  end
  return { cwd = state.cwd, left = left, right = right }
end

local function open_file_diff(state, entry, keep_focus, mode)
  if not entry or entry.kind ~= 'file' then
    return
  end
  diff.open(state, diff_spec(state, entry), { mode = mode, keep_focus = keep_focus })
end

local function fetch_meta(state)
  local generation = state.generation or 0
  git.fetch_commit_meta({ cwd = state.cwd, commit = state.commit }, function(meta, err)
    if not vim.api.nvim_buf_is_valid(state.bufnr) then
      return
    end
    if generation ~= (state.generation or 0) then
      return
    end
    if err then
      vim.notify('guit.nvim: ' .. err, vim.log.levels.WARN)
      return
    end
    state.meta = meta
    panel.rerender(state, render, (panel.current_entry(state) or {}).full_path)
  end)
end

local function refresh(state)
  state.generation = (state.generation or 0) + 1
  local generation = state.generation
  changed_files.fetch_changed_files({ cwd = state.cwd, commit = state.commit }, function(items, err)
    if not vim.api.nvim_buf_is_valid(state.bufnr) then
      return
    end
    -- Results of a superseded refresh must not be applied on top of the
    -- list a newer one already installed.
    if generation ~= state.generation then
      return
    end

    if err then
      vim.notify('guit.nvim: ' .. err, vim.log.levels.ERROR)
      return
    end

    state.items = items or {}

    local function apply_items()
      state.tree_state = changed_files.build_state(state.items)
      panel.rerender(state, render)
    end

    if config.options.show.show_counts then
      changed_files.fetch_numstat({ cwd = state.cwd, commit = state.commit }, function(stats, total, stats_err)
        if not vim.api.nvim_buf_is_valid(state.bufnr) then
          return
        end
        if generation ~= state.generation then
          return
        end
        if stats_err then
          vim.notify('guit.nvim: ' .. stats_err, vim.log.levels.WARN)
          state.summary = { additions = 0, deletions = 0 }
          apply_items()
          return
        end

        changed_files.enrich_with_numstat(state.items, stats or {})
        state.summary = total or { additions = 0, deletions = 0 }
        apply_items()
      end)
    else
      state.summary = nil
      apply_items()
    end
  end)
  fetch_meta(state)
end


local function attach_autocmds(state)
  local group = vim.api.nvim_create_augroup(('GuitShow_%d'):format(state.bufnr), { clear = true })

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
      state_by_buf[state.bufnr] = nil
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })
end

local function open_commit_object(state, keep_focus)
  if vim.fn.exists(':Gedit') ~= 2 then
    vim.notify('guit.nvim: fugitive not found (:Gedit unavailable)', vim.log.levels.ERROR)
    return
  end
  local ok, err = preview.with_managed_preview(state, function()
    vim.cmd(('Gedit %s'):format(state.commit))
  end)
  if not ok then
    vim.notify('guit.nvim: failed to open commit in fugitive: ' .. tostring(err), vim.log.levels.ERROR)
  end
  if keep_focus and state.winid and vim.api.nvim_win_is_valid(state.winid) then
    vim.api.nvim_set_current_win(state.winid)
  end
end

local function set_keymaps(state)
  keymaps.attach(state, render, {
    title = 'Guit show',
    back = return_to_log,
    refresh = refresh,
    open_file = open_file_diff,
    -- dd always means "diff", in every pane.
    open_diff = open_file_diff,
    commit = open_commit_object,
    -- The object of a row here is the file at this commit, which is both a
    -- valid fugitive object and a valid git revision.
    yank_hash = function(s)
      local entry = panel.current_entry(s)
      ui_util.yank(entry and entry.kind == 'file'
        and ('%s:%s'):format(s.commit, entry.full_path)
        or s.commit)
    end,
    cmdline = function(s)
      local entry = panel.current_entry(s)
      ui_util.put_on_cmdline(entry and entry.kind == 'file'
        and ('%s:%s'):format(s.commit, entry.full_path)
        or s.commit)
    end,
  })
end

function M.open(opts)
  highlights.setup()

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = 'nofile'
  vim.bo[bufnr].bufhidden = 'wipe'
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly = true

  local winid = opts.reuse_winid
  local target_winid = opts.target_winid
  if winid and vim.api.nvim_win_is_valid(winid) then
    ui_util.with_winfixbuf_disabled(winid, function()
      vim.api.nvim_win_set_buf(winid, bufnr)
    end)
    vim.api.nvim_set_current_win(winid)
  else
    winid, target_winid = window.open_bottom_pane(bufnr)
  end

  local state = {
    bufnr = bufnr,
    winid = winid,
    target_winid = target_winid,
    cwd = opts.cwd,
    commit = opts.commit,
    ns = vim.api.nvim_create_namespace(('guit-show-%d'):format(bufnr)),
    selection_ns = vim.api.nvim_create_namespace(('guit-show-select-%d'):format(bufnr)),
    view_mode = opts.view_mode or config.options.show.default_view,
    items = {},
    entries = {},
    tree_state = nil,
    entry_offset = 0,
    meta = nil,
    source_log = opts.source_log,
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
  attach_autocmds(state)
  set_keymaps(state)
  -- Set last: FileType fires here, so after/ftplugin/guitshow.lua runs after the
  -- plugin's own mappings and can override them.
  vim.bo[bufnr].filetype = 'guitshow'
  render.update_winbar(state)
  ui_util.set_readonly(bufnr, true)
  refresh(state)
end

return M
