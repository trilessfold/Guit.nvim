local changed_files = require('guit.changed_files')
local config = require('guit.config')
local panel = require('guit.ui.changed_file_panel')
local session = require('guit.session')

local M = {}

local function focus_target(state)
  if state.target_winid and vim.api.nvim_win_is_valid(state.target_winid) then
    vim.api.nvim_set_current_win(state.target_winid)
  end
end

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

function M.attach(state, render, handlers)
  handlers = handlers or {}
  local opts = { buffer = state.bufnr, nowait = true, silent = true }

  vim.keymap.set('n', config.options.keymaps.close, function()
    session.close_active()
  end, opts)

  if handlers.back then
    vim.keymap.set('n', config.options.keymaps.back, function()
      handlers.back(state)
    end, opts)
    vim.keymap.set('n', '<BS>', function()
      handlers.back(state)
    end, opts)
  end

  if handlers.refresh then
    vim.keymap.set('n', config.options.keymaps.refresh, function()
      handlers.refresh(state)
    end, opts)
  end

  vim.keymap.set('n', config.options.keymaps.focus_target, function()
    focus_target(state)
  end, opts)

  vim.keymap.set('n', config.options.keymaps.toggle_view, function()
    panel.cycle_view(state, render)
  end, opts)

  vim.keymap.set('n', config.options.keymaps.collapse, function()
    if state.view_mode ~= 'tree' or not panel.in_entries_area(state) then
      vim.cmd('normal! h')
      return
    end
    panel.collapse_current(state, render)
  end, opts)

  vim.keymap.set('n', config.options.keymaps.expand, function()
    if state.view_mode ~= 'tree' or not panel.in_entries_area(state) then
      vim.cmd('normal! l')
      return
    end
    panel.expand_current(state, render)
  end, opts)

  vim.keymap.set('n', config.options.keymaps.collapse_all, function()
    panel.set_subtree(state, render, false)
  end, opts)

  vim.keymap.set('n', config.options.keymaps.expand_all, function()
    panel.set_subtree(state, render, true)
  end, opts)

  if handlers.help then
    vim.keymap.set('n', config.options.keymaps.help, function()
      handlers.help(state)
    end, opts)
  end

  vim.keymap.set('n', config.options.keymaps.open, function()
    toggle_or_open(state, render, handlers)
  end, opts)

  vim.keymap.set('n', config.options.keymaps.split, function()
    local entry = panel.current_entry(state)
    if entry and entry.kind == 'file' and handlers.open_file then
      handlers.open_file(state, entry, false)
    end
  end, opts)

  if handlers.open_diff then
    vim.keymap.set('n', config.options.keymaps.open_diff, function()
      local entry = panel.current_entry(state)
      if entry and entry.kind == 'file' then
        handlers.open_diff(state, entry, true)
      end
    end, opts)
  end

  vim.keymap.set('n', '[z', function()
    panel.jump_parent(state, render)
  end, opts)
  vim.keymap.set('n', 'zP', function()
    panel.jump_top(state, render)
  end, opts)
  vim.keymap.set('n', 'zj', function()
    panel.jump_sibling(state, render, 1)
  end, opts)
  vim.keymap.set('n', 'zJ', function()
    panel.jump_sibling(state, render, 1)
  end, opts)
  vim.keymap.set('n', 'zk', function()
    panel.jump_sibling(state, render, -1)
  end, opts)
  vim.keymap.set('n', 'zK', function()
    panel.jump_sibling(state, render, -1)
  end, opts)

  vim.keymap.set('n', 'zM', function()
    panel.set_all(state, render, false)
  end, opts)
  vim.keymap.set('n', 'zR', function()
    panel.set_all(state, render, true)
  end, opts)
end

return M
