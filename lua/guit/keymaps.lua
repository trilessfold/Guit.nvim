local config = require('guit.config')

local M = {}

--- Every action a Guit pane can bind.
---
--- This table is the single source of truth: the mappings themselves, their
--- `desc` (so `:map` and which-key are useful), and the `g?` help text are all
--- generated from it. Previously each pane hardcoded its own keys and its own
--- help string, so the two drifted apart from each other and from doc/guit.txt.
---
--- `aliases` are extra, non-configurable keys bound alongside the primary one.
--- A pane binds an action only when it passes a handler for it.
M.actions = {
  -- Opening things
  open         = { key = '<CR>', desc = 'open the entry under the cursor, keep focus here' },
  open_focus   = { key = 'o',    desc = 'open the entry under the cursor and move focus to it' },
  open_diff    = { key = 'dd',   desc = 'open the diff for the entry under the cursor' },
  open_diff_inline = { key = 'di', desc = 'open the diff inline, in a single buffer' },
  open_diff_split  = { key = 'ds', desc = 'open the diff side by side in fugitive' },
  open_show    = { key = 's',    desc = 'open Guit show for the selected commit' },
  commit       = { key = 'c',    desc = 'open the commit in fugitive, keep focus here' },
  commit_focus = { key = 'C',    desc = 'open the commit in fugitive and move focus to it' },

  -- Moving around
  focus_target = { key = '<Tab>', desc = 'jump to the target window' },
  back         = { key = '-',     desc = 'go back to the view this one was opened from' },

  -- Pane control
  refresh = { key = 'r',  desc = 'reload this view' },
  close   = { key = 'q',  desc = 'close this pane' },
  help    = { key = 'g?', desc = 'show these mappings' },

  -- Presentation
  toggle_view = { key = 't', desc = 'change display mode' },

  -- Tree navigation
  collapse         = { key = 'h', desc = 'collapse the directory under the cursor' },
  expand           = { key = 'l', desc = 'expand the directory under the cursor' },
  collapse_subtree = { key = 'H', aliases = { 'zC' }, desc = 'collapse the whole subtree' },
  expand_subtree   = { key = 'L', aliases = { 'zO' }, desc = 'expand the whole subtree' },
  collapse_tree    = { key = 'zM', desc = 'collapse the whole tree' },
  expand_tree      = { key = 'zR', desc = 'expand the whole tree' },
  jump_parent      = { key = '[z', desc = 'jump to the parent directory' },
  jump_top         = { key = 'zP', desc = 'jump to the top-level directory' },
  jump_next        = { key = 'zj', desc = 'jump to the next sibling' },
  jump_prev        = { key = 'zk', desc = 'jump to the previous sibling' },

  -- Working tree (|:Guit-status| only)
  --
  -- These reuse fugitive's keys so the fingers of anyone coming from :Git
  -- carry over. It is the one deliberate exception to "a key means the same
  -- thing in every pane": s and - read differently here, and only here, where
  -- their usual meanings have nothing to act on.
  stage        = { key = 's', modes = { 'n', 'x' }, desc = 'stage the file, directory or selection' },
  unstage      = { key = 'u', modes = { 'n', 'x' }, desc = 'unstage the file, directory or selection' },
  stage_toggle = { key = '-', modes = { 'n', 'x' }, desc = 'stage if unstaged, unstage if staged' },
  discard      = { key = 'X', modes = { 'n', 'x' }, desc = 'throw away changes (asks first)' },

  -- Inline diff (mapped into the diffed buffer itself, see |guit-inline-diff|)
  --
  -- These mirror Vim's own ]c and [c in diff mode, which do nothing in a
  -- buffer that is not in 'diff'. They are installed only while an overlay is
  -- shown and any mapping they displace is restored afterwards.
  hunk_next = { key = ']c', desc = 'jump to the next hunk of the inline diff' },
  hunk_prev = { key = '[c', desc = 'jump to the previous hunk of the inline diff' },

  -- Fugitive's own buffers (see |guit-fugitive|)
  --
  -- :Git status maps dd, ds and dv to its vimdiff variants and leaves di
  -- free; a blob buffer maps dd to Gdiffsplit! against the parent. di sits
  -- beside them in both, opening the inline form instead.
  fugitive_inline = { key = 'di', desc = 'in fugitive buffers: open the inline diff' },

  -- Taking the object somewhere else
  yank_hash = { key = 'y<C-G>', desc = 'yank the full hash (or path) into a register' },
  cmdline   = { key = '.',      desc = 'put the object under the cursor on the command line' },
}

-- Older configuration names, kept working for one release.
local deprecated = {
  split = 'open_focus',
  collapse_all = 'collapse_subtree',
  expand_all = 'expand_subtree',
}

local warned = {}

--- Resolves the key for an action, honouring user configuration.
---
--- Returns nil when the user disabled the action with `false`, in which case
--- nothing is bound and the action is omitted from the help.
---@param action string
---@return string|nil key
function M.key_for(action)
  local configured = config.options.keymaps or {}
  local spec = M.actions[action]
  local default = spec and spec.key or nil
  local key = configured[action]

  -- setup() merges over the defaults, so "the user chose this" means the value
  -- differs from the default -- it is never simply absent.
  local explicit = key ~= nil and key ~= default

  for old, new in pairs(deprecated) do
    if new == action and configured[old] ~= nil and not explicit then
      if not warned[old] then
        warned[old] = true
        vim.notify(
          ('guit.nvim: keymaps.%s is deprecated, use keymaps.%s'):format(old, new),
          vim.log.levels.WARN
        )
      end
      return configured[old] or nil
    end
  end

  if key == false then
    return nil
  end
  if key ~= nil then
    return key
  end
  return default
end

--- Binds every action the pane supplied a handler for.
---@param state table pane state, must carry `bufnr`
---@param handlers table<string, fun(state: table)>
function M.apply(state, handlers)
  local opts = { buffer = state.bufnr, nowait = true, silent = true }

  for action, handler in pairs(handlers) do
    local spec = M.actions[action]
    if spec then
      -- Disabling an action with `false` disables its aliases with it;
      -- otherwise zC would stay bound while g? no longer lists it.
      local key = M.key_for(action)
      local keys = {}
      if key then
        keys[#keys + 1] = key
        for _, alias in ipairs(spec.aliases or {}) do
          keys[#keys + 1] = alias
        end
      end

      local modes = spec.modes or { 'n' }
      for _, lhs in ipairs(keys) do
        for _, mode in ipairs(modes) do
          vim.keymap.set(mode, lhs, function()
            -- In visual mode the marks are only set once the selection ends,
            -- so leave it first and hand the handler the range it covered.
            if mode == 'x' then
              vim.cmd('normal! \27')
              handler(state, {
                line1 = vim.fn.line("'<"),
                line2 = vim.fn.line("'>"),
              })
              return
            end
            handler(state)
          end, vim.tbl_extend('force', opts, { desc = 'Guit: ' .. spec.desc }))
        end
      end
    end
  end
end

-- Grouped so the help reads in a sensible order rather than a hash order.
local help_order = {
  { 'Open', { 'open', 'open_focus', 'open_diff', 'open_diff_inline', 'open_diff_split', 'open_show', 'commit', 'commit_focus' } },
  { 'Inline diff', { 'hunk_next', 'hunk_prev', 'fugitive_inline' } },
  { 'Move', { 'focus_target', 'back', 'jump_parent', 'jump_top', 'jump_next', 'jump_prev' } },
  { 'Tree', { 'collapse', 'expand', 'collapse_subtree', 'expand_subtree', 'collapse_tree', 'expand_tree' } },
  { 'Working tree', { 'stage', 'unstage', 'stage_toggle', 'discard' } },
  { 'Take', { 'yank_hash', 'cmdline' } },
  { 'Pane', { 'toggle_view', 'refresh', 'close', 'help' } },
}

--- Builds the help text from the mappings actually in effect, so a user who
--- rebound something is told about their key, not the default.
---@param title string
---@param handlers table<string, fun(state: table)>
---@return string
function M.help_text(title, handlers)
  local lines = { title, '' }

  for _, group in ipairs(help_order) do
    local heading, actions = group[1], group[2]
    local rows = {}
    for _, action in ipairs(actions) do
      if handlers[action] then
        local key = M.key_for(action)
        if key then
          local spec = M.actions[action]
          local keys = key
          for _, alias in ipairs(spec.aliases or {}) do
            keys = keys .. ' ' .. alias
          end
          rows[#rows + 1] = ('  %-8s %s'):format(keys, spec.desc)
        end
      end
    end
    if #rows > 0 then
      lines[#lines + 1] = heading
      vim.list_extend(lines, rows)
      lines[#lines + 1] = ''
    end
  end

  lines[#lines + 1] = 'See :help guit for full documentation.'
  return table.concat(lines, '\n')
end

--- The standard help handler for a pane.
---@param title string
---@param handlers table
---@return fun()
function M.help_handler(title, handlers)
  return function()
    vim.notify(M.help_text(title, handlers), vim.log.levels.INFO, { title = 'guit.nvim' })
  end
end

return M
