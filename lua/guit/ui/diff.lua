local config = require('guit.config')
local inline_diff = require('guit.ui.inline_diff')
local preview = require('guit.ui.preview')

--- Opening a file diff from a pane, in either of the two shapes Guit offers.
---
--- Every pane describes what it wants compared as a *spec*: an old side and a
--- new side, each a revision plus a path, or a bare path for the working
--- tree, or nil when that side has no content (added, deleted, root commit).
--- This module turns the spec into windows, so the panes no longer each carry
--- their own copy of "Gedit this, Gdiffsplit that, unless...".
---
---   { cwd = '/repo',
---     left  = { rev = 'abc^', path = 'old/name.lua' } | nil,
---     right = { rev = 'abc', path = 'name.lua' } | { path = 'name.lua' } | nil }
local M = {}

--- Opens an empty scratch buffer beside the current window and diffs against it.
---
--- Used when one side of a comparison genuinely has no content: a file added by
--- the commit, a file deleted by it, or any file in a root commit, which has no
--- parent to diff against. Without this the caller would build a `<commit>^`
--- object spec that git cannot resolve.
---@param side string 'left' or 'right' -- which side the empty buffer goes on
---@param label string|nil name shown for the empty buffer
function M.open_empty_side(side, label)
  vim.cmd('diffthis')
  local file_winid = vim.api.nvim_get_current_win()
  vim.cmd((side == 'left' and 'leftabove' or 'rightbelow') .. ' vnew')

  local bufnr = vim.api.nvim_get_current_buf()
  pcall(vim.api.nvim_buf_set_name, bufnr, ('guit://empty/%s'):format(label or 'empty'))
  vim.bo[bufnr].buftype = 'nofile'
  vim.bo[bufnr].bufhidden = 'wipe'
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly = true
  vim.cmd('diffthis')

  if vim.api.nvim_win_is_valid(file_winid) then
    vim.api.nvim_set_current_win(file_winid)
  end
end

--- Whether a commit has no parent, so `<commit>^` would not resolve.
---@param parents string[]|nil
---@return boolean
function M.is_root_commit(parents)
  return parents ~= nil and #parents == 0
end

--- A side is a revision when it names one; an empty string means the working
--- tree, which `:Guit compare <rev>` produces.
local function has_rev(side)
  return side and side.rev and side.rev ~= ''
end

--- The fugitive object, or the plain file, for one side.
local function object_of(side)
  if has_rev(side) then
    return ('%s:%s'):format(side.rev, vim.fn.fnameescape(side.path))
  end
  return vim.fn.fnameescape(side.path)
end

--- What the diff is against, for the buffer variable and messages.
local function label_of(side)
  if not side then
    return 'an empty file'
  end
  if has_rev(side) then
    return ('%s:%s'):format(side.rev, side.path)
  end
  return 'working tree'
end

local function edit_side(cwd, side)
  if has_rev(side) then
    vim.cmd('Gedit ' .. object_of(side))
  else
    vim.cmd('edit ' .. vim.fn.fnameescape(cwd .. '/' .. side.path))
  end
end

--- Split mode hands both sides to fugitive. Inline mode reads the old side
--- with git itself and only needs fugitive when the buffer it shows is an
--- object rather than a working tree file.
local function needs_fugitive(spec, mode)
  if mode == 'inline' then
    return has_rev(spec.right or spec.left)
  end
  return has_rev(spec.left) or has_rev(spec.right)
end

local function fugitive_missing(commands)
  for _, command in ipairs(commands) do
    if vim.fn.exists(':' .. command) ~= 2 then
      return true
    end
  end
  return false
end

local function return_focus(state, keep_focus)
  if keep_focus and state.winid and vim.api.nvim_win_is_valid(state.winid) then
    vim.api.nvim_set_current_win(state.winid)
  end
end

local function open_split(state, spec)
  return preview.with_managed_preview(state, function()
    if not spec.right then
      edit_side(spec.cwd, spec.left)
      M.open_empty_side('right', spec.left.path)
      return
    end
    edit_side(spec.cwd, spec.right)
    if spec.left then
      vim.cmd('Gdiffsplit! ' .. object_of(spec.left))
    else
      M.open_empty_side('left', spec.right.path)
    end
  end)
end

--- Reads one side's content. The working tree side is never read here: it is
--- the buffer itself.
local function fetch_lines(cwd, side, on_done)
  vim.system({ 'git', '--no-pager', 'show', ('%s:%s'):format(side.rev, side.path) }, {
    cwd = cwd,
    text = true,
  }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        on_done(nil, (result.stderr or result.stdout or 'git show failed'):gsub('%s+$', ''))
        return
      end
      local lines = vim.split(result.stdout or '', '\n', { plain = true })
      -- A file ending in a newline yields one trailing empty field that the
      -- buffer, which has no such line, would otherwise appear to have lost.
      if #lines > 0 and lines[#lines] == '' then
        lines[#lines] = nil
      end
      on_done(lines)
    end)
  end)
end

local function open_inline(state, spec)
  local shown = spec.right or spec.left
  local bufnr
  local ok, err = preview.with_managed_preview(state, function(anchor_winid)
    edit_side(spec.cwd, shown)
    bufnr = vim.api.nvim_win_get_buf(anchor_winid)
    -- attach does this too, but the old side may take a git show to arrive;
    -- until then a split diff left over from ds would still be on screen.
    inline_diff.leave_split(bufnr, anchor_winid)
  end)
  if not ok then
    return false, err
  end

  -- Anything the pane opens after this, and anything that takes the overlay
  -- down, must win over a git show still in flight; the stale result would
  -- otherwise dress up whatever the window shows by then, or undo a split
  -- diff the user asked for in the meantime. Two guards: the pane's own
  -- generation, moved on by M.open and M.open_object, and the buffer's
  -- request token, moved on by any detach.
  local generation = state.inline_generation
  local token = inline_diff.begin_request(bufnr)
  local winid = state.target_winid
  local label = label_of(spec.left)

  local function attach(opts)
    if generation ~= state.inline_generation
        or not inline_diff.request_is_current(bufnr, token)
        or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    local count = inline_diff.attach(bufnr, vim.tbl_extend('force', {
      owner = state,
      label = label,
      jump_first = true,
      winid = winid,
    }, opts))
    if count == 0 and not opts.all_deleted then
      vim.notify('guit.nvim: no differences against ' .. label, vim.log.levels.INFO)
    end
  end

  if not spec.right then
    attach({ all_deleted = true })
  elseif not spec.left then
    attach({ old_lines = {} })
  else
    fetch_lines(spec.cwd, spec.left, function(lines, fetch_err)
      if fetch_err then
        vim.notify('guit.nvim: ' .. fetch_err, vim.log.levels.ERROR)
        return
      end
      attach({ old_lines = lines })
    end)
  end
  return true
end

--- Opens the diff a spec describes in the pane's target window.
---@param state table pane state
---@param spec table see the module comment
---@param opts table|nil { mode = 'split'|'inline', keep_focus = boolean }
---@return boolean ok
function M.open(state, spec, opts)
  opts = opts or {}
  if not spec.left and not spec.right then
    return false
  end

  -- Whatever inline overlay the pane was still waiting for is superseded.
  state.inline_generation = (state.inline_generation or 0) + 1

  local mode = opts.mode or config.options.diff.mode
  local required = mode == 'inline' and { 'Gedit' } or { 'Gedit', 'Gdiffsplit' }
  if needs_fugitive(spec, mode) and fugitive_missing(required) then
    vim.notify(('guit.nvim: fugitive not found (:%s unavailable)'):format(table.concat(required, ' / :')),
      vim.log.levels.ERROR)
    return false
  end

  local ok, err
  if mode == 'inline' then
    ok, err = open_inline(state, spec)
  else
    ok, err = open_split(state, spec)
  end

  if not ok then
    vim.notify('guit.nvim: failed to open diff in fugitive: ' .. tostring(err), vim.log.levels.ERROR)
  end
  return_focus(state, opts.keep_focus)
  return ok
end

--- Opens a single object, no diff. Panes use it for files whose second side
--- there is no point in showing, such as untracked files.
function M.open_object(state, cwd, side, opts)
  opts = opts or {}
  state.inline_generation = (state.inline_generation or 0) + 1
  if has_rev(side) and fugitive_missing({ 'Gedit' }) then
    vim.notify('guit.nvim: fugitive not found (:Gedit unavailable)', vim.log.levels.ERROR)
    return false
  end
  local ok, err = preview.with_managed_preview(state, function()
    edit_side(cwd, side)
  end)
  if not ok then
    vim.notify('guit.nvim: failed to open file: ' .. tostring(err), vim.log.levels.ERROR)
  end
  return_focus(state, opts.keep_focus)
  return ok
end

return M
