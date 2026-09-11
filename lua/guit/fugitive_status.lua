local config = require('guit.config')
local diff = require('guit.ui.diff')
local git = require('guit.git')
local inline_diff = require('guit.ui.inline_diff')
local keymaps = require('guit.keymaps')

--- `di` inside fugitive's own buffers.
---
--- Fugitive's `:Git` status maps dd, ds and dv to its vimdiff variants and
--- leaves di free, so the inline diff slots in beside them. Fugitive keeps
--- the file-under-cursor logic script-local, but its status lines have a
--- fixed shape -- `M path`, `R old -> new` under a `Staged (3)` style
--- heading -- which is parsed here the same way fugitive itself does it.
---
--- In a fugitive blob buffer (`fugitive://.../<commit>/<path>`), where
--- fugitive maps dd to `Gdiffsplit!` against the parent, di toggles the inline
--- diff: the comparison a Guit pane drew there, such as a :Guit compare
--- between two revisions, or |:Guit-inline| against the parent otherwise.
--- With `diff.mode = 'inline'` dd does the same, see attach_blob.
local M = {}

-- Fugitive has no conflicts section: an unmerged file appears under both
-- Staged and Unstaged with the status letter U.
local SECTIONS = {
  Staged = 'staged',
  Unstaged = 'unstaged',
  Untracked = 'untracked',
}

-- Expanded hunks (fugitive's `=`) sit under their file line and start with a
-- diff sigil.
local function is_hunk_line(line)
  return line:match('^[ @+%-]') ~= nil
end

--- The file entry a status line belongs to.
---
--- Pure: takes the buffer lines so it can be tested without fugitive.
---@param lines string[]
---@param lnum integer 1-based
---@return table|nil { section, status, path, old_path }
function M.entry_at(lines, lnum)
  local line = lines[lnum]
  if not line then
    return nil
  end

  -- On an expanded hunk, the file is the nearest non-hunk line above.
  while lnum > 1 and is_hunk_line(lines[lnum]) do
    lnum = lnum - 1
  end
  line = lines[lnum]

  local status, text = line:match('^([A-Z?][A-Z?]?) (.+)$')
  if not status then
    return nil
  end

  -- Walk up to the section heading; a blank line ends the section.
  local heading
  for i = lnum - 1, 1, -1 do
    local candidate = lines[i]
    if candidate == '' then
      break
    end
    local word = candidate:match('^(%u%l+) %(%d+%+?%)$')
    if word then
      heading = word
      break
    end
  end
  local section = heading and SECTIONS[heading]
  if not section then
    return nil
  end

  local old_path, path = text:match('^(.-) %-> (.+)$')
  if not old_path then
    path = text
  end
  return {
    section = section,
    status = status,
    path = path,
    old_path = old_path,
  }
end

--- The two sides for an entry, mirroring `Guit status`. nil means "just open
--- the file": untracked files and conflicts have no useful second side.
function M.spec_for(cwd, entry)
  local status = entry.status:sub(1, 1)
  -- The index holds no stage 0 for an unmerged path, so neither side of a
  -- conflict can be read; the file itself, with its markers, is all there is.
  if status == 'U' then
    return nil
  end
  local left, right
  if entry.section == 'staged' then
    left = { rev = 'HEAD', path = entry.old_path or entry.path }
    right = { rev = ':0', path = entry.path }
  elseif entry.section == 'unstaged' then
    left = { rev = ':0', path = entry.path }
    right = { path = entry.path }
  else
    return nil
  end
  if status == 'A' then
    left = nil
  elseif status == 'D' then
    right = nil
  end
  return { cwd = cwd, left = left, right = right }
end

-- One preview state per status buffer, so consecutive di presses reuse the
-- same window and take down the previous overlay, exactly like a Guit pane.
local state_by_buf = {}

local function is_plain_window(winid, status_bufnr)
  if not vim.api.nvim_win_is_valid(winid) then
    return false
  end
  local bufnr = vim.api.nvim_win_get_buf(winid)
  if bufnr == status_bufnr then
    return false
  end
  local ft = vim.bo[bufnr].filetype
  return ft ~= 'fugitive' and not vim.startswith(ft, 'guit')
    and vim.api.nvim_win_get_config(winid).relative == ''
end

--- The window to open the diff in: the one the user came from, another
--- ordinary window in the tab, or a new split above the status.
local function pick_target(status_winid, status_bufnr)
  local previous = vim.fn.win_getid(vim.fn.winnr('#'))
  if previous ~= 0 and previous ~= status_winid and is_plain_window(previous, status_bufnr) then
    return previous
  end
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if winid ~= status_winid and is_plain_window(winid, status_bufnr) then
      return winid
    end
  end
  vim.cmd('aboveleft split')
  local winid = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(status_winid)
  return winid
end

local function state_for(bufnr)
  local state = state_by_buf[bufnr]
  if not state then
    state = { bufnr = bufnr, preview = { extra_wins = {}, buffers = {} } }
    state_by_buf[bufnr] = state
    vim.api.nvim_create_autocmd('BufWipeout', {
      buffer = bufnr,
      once = true,
      callback = function()
        inline_diff.detach_owned(state)
        state_by_buf[bufnr] = nil
      end,
    })
  end
  state.winid = vim.api.nvim_get_current_win()
  state.target_winid = pick_target(state.winid, bufnr)
  state.preview.anchor_winid = state.target_winid
  return state
end

local function worktree(bufnr)
  if vim.fn.exists('*FugitiveWorkTree') == 1 then
    local tree = vim.fn.FugitiveWorkTree(bufnr)
    if tree and tree ~= '' then
      return tree
    end
  end
  return git.repo_root(vim.uv.cwd())
end

--- Opens the file under the cursor of a `:Git` status buffer as an inline
--- diff, moving focus to it the way fugitive's own dd does.
function M.open_inline()
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local entry = M.entry_at(lines, vim.api.nvim_win_get_cursor(0)[1])
  if not entry then
    return
  end
  local cwd = worktree(bufnr)
  if not cwd then
    vim.notify('guit.nvim: not inside a git work tree', vim.log.levels.WARN)
    return
  end

  local state = state_for(bufnr)
  local spec = M.spec_for(cwd, entry)
  if spec then
    diff.open(state, spec, { mode = 'inline', keep_focus = false })
  else
    diff.open_object(state, cwd, { path = entry.path }, { keep_focus = false })
  end
end

local function map(bufnr, lhs, rhs, desc)
  if not lhs then
    return
  end
  vim.keymap.set('n', lhs, rhs, {
    buffer = bufnr,
    nowait = true,
    silent = true,
    desc = 'Guit: ' .. desc,
  })
end

--- Installs di into a `:Git` status buffer.
function M.attach_status(bufnr)
  map(bufnr, keymaps.key_for('fugitive_inline'), M.open_inline,
    'open the file under the cursor as an inline diff')
end

--- Installs di into a fugitive blob buffer, and dd as well when `diff.mode`
--- is inline.
---
--- Fugitive maps dd in a read-only blob to Gdiffsplit! against the parent,
--- which always opens a side-by-side split. Everywhere else in Guit dd opens
--- the shape `diff.mode` selects, so with 'inline' a dd pressed in the inline
--- viewer used to open a split next to it anyway. With 'inline', dd in a blob
--- is therefore the same toggle as di. Fugitive fires User FugitiveBlob after
--- installing its own mappings, so this one wins. With 'split' fugitive's dd
--- already is the split and is left alone. Buffers that can be edited, such
--- as index objects, never get it: there dd deletes a line.
function M.attach_blob(bufnr)
  local function toggle()
    require('guit').inline()
  end
  map(bufnr, keymaps.key_for('fugitive_inline'), toggle,
    'toggle the inline diff: the Guit pane comparison, or against the parent commit')
  if config.options.diff.mode == 'inline' and not vim.bo[bufnr].modifiable then
    map(bufnr, keymaps.key_for('open_diff'), toggle,
      'toggle the inline diff, as diff.mode says: the Guit pane comparison, or against the parent')
  end
end

return M
