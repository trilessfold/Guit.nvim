local changed_files = require('guit.changed_files')
local config = require('guit.config')
local diff = require('guit.ui.diff')
local highlights = require('guit.ui.highlight')
local keymaps = require('guit.ui.changed_file_keymaps')
local panel = require('guit.ui.changed_file_panel')
local render = require('guit.ui.status_render')
local session = require('guit.session')
local stage = require('guit.stage')
local status = require('guit.status')
local ui_util = require('guit.ui.util')
local window = require('guit.ui.window')

local M = {}

local state_by_buf = {}

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

--- The two sides of a file's change in its section.
---
--- Staged changes compare the index (`:0:`) against HEAD, unstaged ones the
--- working tree against the index. Untracked and conflicted files have no
--- useful second side: the index holds no stage 0 for a conflict, and an
--- untracked file is all "new" by definition. Those return nil and are
--- simply opened.
local function diff_spec(state, entry)
  local path = file_path(entry)
  local status = (entry.status or ''):sub(1, 1)
  local left, right
  if entry.section == 'staged' then
    left = { rev = 'HEAD', path = entry.worktree_old_path or path }
    right = { rev = ':0', path = path }
  elseif entry.section == 'unstaged' then
    left = { rev = ':0', path = path }
    right = { path = path }
  else
    return nil
  end
  if status == 'A' then
    left = nil
  elseif status == 'D' then
    right = nil
  end
  return { cwd = state.cwd, left = left, right = right }
end

local function open_file_diff(state, entry, keep_focus, mode)
  if not entry or entry.kind ~= 'file' then
    return
  end
  local path = file_path(entry)
  if not path then
    return
  end
  local spec = diff_spec(state, entry)
  if spec then
    diff.open(state, spec, { mode = mode, keep_focus = keep_focus })
  else
    diff.open_object(state, state.cwd, { path = path }, { keep_focus = keep_focus })
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
  diff.open_object(state, state.cwd, { path = path }, { keep_focus = keep_focus })
end

local function apply_items(state, items, staged_stats, unstaged_stats)
  state.items = items or {}
  state.summary = status.enrich_with_numstat(state.items, staged_stats or {}, unstaged_stats or {})
  state.tree_state = changed_files.build_state(state.items)
  panel.rerender(state, render)
end

local function refresh(state)
  state.generation = (state.generation or 0) + 1
  local generation = state.generation
  status.fetch({ cwd = state.cwd }, function(items, err)
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
    -- fetch_numstat reports (stats, total, err); dropping the error made
    -- a failed diff look like a repository with zero changes everywhere.
    status.fetch_numstat({ cwd = state.cwd }, true, function(staged_stats, _, staged_err)
      if not vim.api.nvim_buf_is_valid(state.bufnr) then
        return
      end
      if generation ~= state.generation then
        return
      end
      if staged_err then
        vim.notify('guit.nvim: ' .. staged_err, vim.log.levels.WARN)
      end
      status.fetch_numstat({ cwd = state.cwd }, false, function(unstaged_stats, _, unstaged_err)
        if not vim.api.nvim_buf_is_valid(state.bufnr) then
          return
        end
        if generation ~= state.generation then
          return
        end
        if unstaged_err then
          vim.notify('guit.nvim: ' .. unstaged_err, vim.log.levels.WARN)
        end
        apply_items(state, items, staged_stats, unstaged_stats)
      end)
    end)
  end)
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
      state_by_buf[state.bufnr] = nil
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })
end

-- ---------------------------------------------------------------------------
-- Working tree actions
-- ---------------------------------------------------------------------------

--- The file entries a key press applies to.
---
--- One key covers three targets, because the pane is a tree: a file acts on
--- itself, a directory or a section heading acts on everything beneath it, and
--- a visual selection acts on every file the selected lines cover.
---@param state table
---@param range table|nil { line1, line2 } when invoked from visual mode
---@return table[] entries
local function selected_entries(state, range)
  local seen, out = {}, {}

  local function take(entry)
    if not entry or entry.kind ~= 'file' then
      return
    end
    -- A directory and the files inside it can both be in the selection, and
    -- the same file arrives as two different tables depending on whether it
    -- came from state.items or state.entries. Key on what it identifies.
    local key = (entry.section or '') .. '\0' .. (file_path(entry) or '')
    if seen[key] then
      return
    end
    seen[key] = true
    out[#out + 1] = entry
  end

  local function take_under(dir)
    local prefix = dir .. '/'
    for _, item in ipairs(state.items or {}) do
      if item.path == dir or vim.startswith(item.path or '', prefix) then
        take(item)
      end
    end
  end

  if range then
    local offset = state.entry_offset or 0
    for line = math.min(range.line1, range.line2), math.max(range.line1, range.line2) do
      local entry = state.entries[line - offset]
      if entry then
        if entry.kind == 'file' then
          take(entry)
        else
          take_under(entry.full_path)
        end
      end
    end
    return out
  end

  local entry = panel.current_entry(state)
  if not entry then
    return out
  end
  if entry.kind == 'file' then
    take(entry)
  else
    take_under(entry.full_path)
  end
  return out
end

--- Groups the selection by the section each file sits in, because staged and
--- unstaged files need different git commands.
---
--- A staged rename is two index entries, the deletion of the old path and
--- the addition of the new one. git only acts on the paths it is given, so
--- resetting or restoring the new path alone leaves the deletion staged; both
--- paths go in.
---@param entries table[]
---@return table<string, string[]> paths by section
---@return table<string, string[]> labels by section, one per entry, for messages
local function by_section(entries)
  local groups, labels = {}, {}
  for _, entry in ipairs(entries) do
    local section = entry.section or 'unstaged'
    groups[section] = groups[section] or {}
    labels[section] = labels[section] or {}
    local path = file_path(entry)
    local old_path = section == 'staged' and entry.worktree_old_path or nil
    if old_path and old_path ~= path then
      table.insert(groups[section], old_path)
      table.insert(labels[section], old_path .. ' -> ' .. path)
    else
      table.insert(labels[section], path)
    end
    table.insert(groups[section], path)
  end
  return groups, labels
end

--- Runs a set of git operations and refreshes once they have all finished.
local function apply(state, operations)
  if #operations == 0 then
    vim.notify('guit.nvim: nothing to do', vim.log.levels.INFO)
    return
  end

  -- Sequentially, not in parallel: two git commands writing the index at once
  -- collide on .git/index.lock and one of them quietly does nothing. That
  -- holds across key presses too, so a second action waits for the first.
  if state.busy then
    vim.notify('guit.nvim: previous action still running', vim.log.levels.WARN)
    return
  end
  state.busy = true

  local function finish()
    state.busy = false
    if vim.api.nvim_buf_is_valid(state.bufnr) then
      refresh(state)
    end
  end

  local index = 0
  local function step()
    index = index + 1
    local operation = operations[index]
    if not operation then
      finish()
      return
    end

    operation(function(err)
      if err then
        vim.notify('guit.nvim: ' .. err, vim.log.levels.ERROR)
        finish()
        return
      end
      step()
    end)
  end

  step()
end

local function do_stage(state, range)
  local entries = selected_entries(state, range)
  local paths = {}
  for _, entry in ipairs(entries) do
    -- A file already in the index has nothing to add.
    if entry.section ~= 'staged' then
      paths[#paths + 1] = file_path(entry)
    end
  end

  apply(state, #paths > 0 and {
    function(cb)
      stage.stage(state.cwd, paths, cb)
    end,
  } or {})
end

local function do_unstage(state, range)
  local groups = by_section(selected_entries(state, range))
  local paths = groups.staged or {}

  apply(state, #paths > 0 and {
    function(cb)
      stage.unstage(state.cwd, paths, cb)
    end,
  } or {})
end

local function do_stage_toggle(state, range)
  local groups = by_section(selected_entries(state, range))
  local operations = {}

  if groups.staged and #groups.staged > 0 then
    operations[#operations + 1] = function(cb)
      stage.unstage(state.cwd, groups.staged, cb)
    end
  end

  local to_stage = {}
  for _, section in ipairs({ 'unstaged', 'untracked', 'conflicts' }) do
    vim.list_extend(to_stage, groups[section] or {})
  end
  if #to_stage > 0 then
    operations[#operations + 1] = function(cb)
      stage.stage(state.cwd, to_stage, cb)
    end
  end

  apply(state, operations)
end

--- Spells out exactly what is about to be lost, then asks.
local function confirm_discard(labels)
  local lines = { 'Throw away changes? This cannot be undone.', '' }

  local function describe(section, label)
    local paths = labels[section]
    if not paths or #paths == 0 then
      return
    end
    lines[#lines + 1] = label
    for _, path in ipairs(paths) do
      lines[#lines + 1] = '  ' .. path
    end
  end

  describe('staged', 'Staged changes will be reset to HEAD:')
  describe('unstaged', 'Unstaged changes will be lost:')
  describe('conflicts', 'Conflicted files will be reset:')
  describe('untracked', 'These files will be DELETED from disk:')

  return vim.fn.confirm(table.concat(lines, '\n'), '&Yes\n&No', 2) == 1
end

local function do_discard(state, range)
  local groups, labels = by_section(selected_entries(state, range))
  if vim.tbl_isempty(groups) then
    vim.notify('guit.nvim: nothing selected', vim.log.levels.INFO)
    return
  end

  if not confirm_discard(labels) then
    return
  end

  local operations = {}
  if groups.staged then
    operations[#operations + 1] = function(cb)
      stage.discard_staged(state.cwd, groups.staged, cb)
    end
  end
  if groups.unstaged then
    operations[#operations + 1] = function(cb)
      stage.discard_worktree(state.cwd, groups.unstaged, cb)
    end
  end
  -- A plain restore refuses unmerged paths; conflicts need the index reset
  -- along with the worktree.
  if groups.conflicts then
    operations[#operations + 1] = function(cb)
      stage.discard_conflicts(state.cwd, groups.conflicts, cb)
    end
  end
  if groups.untracked then
    operations[#operations + 1] = function(cb)
      stage.delete_untracked(state.cwd, groups.untracked, cb)
    end
  end

  apply(state, operations)
end

local function set_keymaps(state)
  keymaps.attach(state, render, {
    title = 'Guit status',
    refresh = refresh,
    stage = do_stage,
    unstage = do_unstage,
    stage_toggle = do_stage_toggle,
    discard = do_discard,
    open_file = open_worktree_file,
    open_diff = open_file_diff,
    -- Nothing is committed here, so the object is the worktree path.
    yank_hash = function(s)
      local entry = panel.current_entry(s)
      if entry and entry.kind == 'file' then
        ui_util.yank(file_path(entry))
      end
    end,
    cmdline = function(s)
      local entry = panel.current_entry(s)
      if entry and entry.kind == 'file' then
        ui_util.put_on_cmdline(file_path(entry))
      end
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
  state_by_buf[bufnr] = state
  session.register(state, snapshot)
  attach_autocmds(state)
  set_keymaps(state)
  -- Set last: FileType fires here, so after/ftplugin/guitstatus.lua runs after the
  -- plugin's own mappings and can override them.
  vim.bo[bufnr].filetype = 'guitstatus'
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
