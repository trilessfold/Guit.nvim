local changed_files = require('guit.changed_files')
local keymaps = require('guit.keymaps')
local panel = require('guit.ui.changed_file_panel')
local session = require('guit.session')

local M = {}

local function focus_target(state)
  if state.target_winid and vim.api.nvim_win_is_valid(state.target_winid) then
    vim.api.nvim_set_current_win(state.target_winid)
  end
end

--- <CR> on a directory folds it; on a file it opens whatever this pane
--- considers the file's primary object.
local function toggle_or_open(state, render, handlers)
  local entry = panel.current_entry(state)
  if not entry then
    return
  end
  if entry.kind == 'dir' and state.view_mode == 'tree' then
    changed_files.toggle_dir(state.tree_state, entry.full_path)
    panel.rerender(state, render, entry.full_path)
    return
  end
  if handlers.open_file then
    handlers.open_file(state, entry, true)
  end
end

--- Falls back to the plain motion when the tree meaning does not apply, so h
--- and l still move the cursor in list mode.
local function tree_or_motion(state, render, motion, action)
  if state.view_mode ~= 'tree' or not panel.in_entries_area(state) then
    vim.cmd('normal! ' .. motion)
    return
  end
  action(state, render)
end

function M.attach(state, render, handlers)
  handlers = handlers or {}

  local bound = {
    close = function(s)
      session.close(s)
    end,
    focus_target = focus_target,
    toggle_view = function(s)
      panel.cycle_view(s, render)
    end,
    open = function(s)
      toggle_or_open(s, render, handlers)
    end,
    open_focus = function(s)
      local entry = panel.current_entry(s)
      if entry and entry.kind == 'file' and handlers.open_file then
        handlers.open_file(s, entry, false)
      end
    end,
    collapse = function(s)
      tree_or_motion(s, render, 'h', panel.collapse_current)
    end,
    expand = function(s)
      tree_or_motion(s, render, 'l', panel.expand_current)
    end,
    collapse_subtree = function(s)
      panel.set_subtree(s, render, false)
    end,
    expand_subtree = function(s)
      panel.set_subtree(s, render, true)
    end,
    collapse_tree = function(s)
      panel.set_all(s, render, false)
    end,
    expand_tree = function(s)
      panel.set_all(s, render, true)
    end,
    jump_parent = function(s)
      panel.jump_parent(s, render)
    end,
    jump_top = function(s)
      panel.jump_top(s, render)
    end,
    jump_next = function(s)
      panel.jump_sibling(s, render, 1)
    end,
    jump_prev = function(s)
      panel.jump_sibling(s, render, -1)
    end,
  }

  -- Optional, pane-specific behaviour.
  if handlers.back then
    bound.back = handlers.back
  end
  if handlers.refresh then
    bound.refresh = handlers.refresh
  end
  if handlers.open_diff then
    -- dd follows the configured diff mode; di and ds name one explicitly.
    local function open_diff(mode)
      return function(s)
        local entry = panel.current_entry(s)
        if entry and entry.kind == 'file' then
          handlers.open_diff(s, entry, true, mode)
        end
      end
    end
    bound.open_diff = open_diff(nil)
    bound.open_diff_inline = open_diff('inline')
    bound.open_diff_split = open_diff('split')
  end
  if handlers.open_show then
    bound.open_show = handlers.open_show
  end
  if handlers.commit then
    bound.commit = function(s)
      handlers.commit(s, true)
    end
    bound.commit_focus = function(s)
      handlers.commit(s, false)
    end
  end
  if handlers.yank_hash then
    bound.yank_hash = handlers.yank_hash
  end
  if handlers.cmdline then
    bound.cmdline = handlers.cmdline
  end

  -- Working tree mutations, wired only by the pane that has a worktree.
  for _, action in ipairs({ 'stage', 'unstage', 'stage_toggle', 'discard' }) do
    if handlers[action] then
      bound[action] = handlers[action]
    end
  end

  bound.help = keymaps.help_handler(handlers.title or 'Guit', bound)
  keymaps.apply(state, bound)
end

return M
