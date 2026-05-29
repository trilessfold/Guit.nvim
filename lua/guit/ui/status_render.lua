local config = require('guit.config')
local show_render = require('guit.ui.show_render')
local ui_util = require('guit.ui.util')

local M = {}

local section_highlights = {
  Staged = 'status_staged',
  Unstaged = 'status_unstaged',
  Untracked = 'status_untracked',
  Conflicts = 'status_conflicts',
}

local function status_label(entry)
  local status = entry.status or ''
  if status:match('^R%d+$') then
    return 'R'
  elseif status:match('^C%d+$') then
    return 'C'
  end
  return status
end

local function status_highlight(entry)
  local status = status_label(entry)
  if status == 'M' then
    return config.options.highlights.status_modified
  elseif status == 'A' then
    return config.options.highlights.status_added
  elseif status == 'D' then
    return config.options.highlights.status_deleted
  elseif status == 'R' then
    return config.options.highlights.status_renamed
  elseif status == 'C' then
    return config.options.highlights.status_copied
  elseif status == '??' then
    return config.options.highlights.status_untracked
  elseif status:find('U', 1, true) then
    return config.options.highlights.status_conflicts
  end
  return config.options.highlights.status
end

local function section_highlight(entry)
  if entry.depth ~= 0 or entry.kind ~= 'dir' then
    return nil
  end
  local key = section_highlights[entry.name]
  return key and config.options.highlights[key] or nil
end

local function format_counts(additions, deletions)
  return string.format('%d %d', additions or 0, deletions or 0)
end

local function add_count_highlights(state, row, line, counts_start)
  if not counts_start then
    return
  end
  local counts_text = line:sub(counts_start + 2)
  local add_text, del_text = counts_text:match('^(%d+)%s+(%d+)$')
  if not add_text then
    return
  end
  local add_col = counts_start + 1
  vim.api.nvim_buf_add_highlight(state.bufnr, state.ns, config.options.highlights.additions, row, add_col, add_col + #add_text)
  local del_col = add_col + #add_text + 1
  vim.api.nvim_buf_add_highlight(state.bufnr, state.ns, config.options.highlights.deletions, row, del_col, del_col + #del_text)
end

local function header_lines(state)
  local lines = {
    'Status: ' .. state.cwd,
  }
  if config.options.show.show_counts and state.summary then
    lines[#lines + 1] = 'Changes: ' .. format_counts(state.summary.additions, state.summary.deletions)
  end
  lines[#lines + 1] = ''
  return lines
end

function M.render_all(state)
  vim.api.nvim_buf_clear_namespace(state.bufnr, state.ns, 0, -1)
  local header = header_lines(state)
  state.entry_offset = #header
  local lines = vim.deepcopy(header)
  local hls = {}

  for i, line in ipairs(header) do
    local row = i - 1
    if vim.startswith(line, 'Status:') then
      hls[#hls + 1] = { row, 0, 7, config.options.highlights.title }
      hls[#hls + 1] = { row, 8, -1, config.options.highlights.subject }
    elseif vim.startswith(line, 'Changes:') then
      hls[#hls + 1] = { row, 0, 8, config.options.highlights.status }
      local counts = line:sub(10)
      local add, del = counts:match('^(%d+)%s+(%d+)$')
      if add then
        local add_col = 9
        hls[#hls + 1] = { row, add_col, add_col + #add, config.options.highlights.additions }
        local del_col = add_col + #add + 1
        hls[#hls + 1] = { row, del_col, del_col + #del, config.options.highlights.deletions }
      end
    end
  end

  if #state.entries == 0 then
    lines[#lines + 1] = 'No working tree changes'
    hls[#hls + 1] = { #lines - 1, 0, -1, config.options.highlights.loading }
  else
    for _, entry in ipairs(state.entries) do
      lines[#lines + 1] = show_render.format_entry(entry)
    end
  end

  ui_util.with_modifiable(state.bufnr, function()
    vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
  end)

  for _, hl in ipairs(hls) do
    vim.api.nvim_buf_add_highlight(state.bufnr, state.ns, hl[4], hl[1], hl[2], hl[3])
  end

  local old_meta, old_commit = state.meta, state.commit
  state.meta = nil
  state.commit = 'WORKTREE'
  for idx, entry in ipairs(state.entries) do
    local row = state.entry_offset + idx - 1
    local line = show_render.format_entry(entry)
    if entry.kind == 'dir' then
      local start_col = #string.rep('  ', entry.depth or 0)
      local dir_hl = section_highlight(entry) or config.options.highlights.dir
      local icon_hl = section_highlight(entry) or config.options.highlights.refs
      vim.api.nvim_buf_add_highlight(state.bufnr, state.ns, icon_hl, row, start_col, start_col + 1)
      local counts_start = config.options.show.show_counts and line:match('.*()  %d+ %d+$') or nil
      vim.api.nvim_buf_add_highlight(state.bufnr, state.ns, dir_hl, row, start_col + 2, counts_start and counts_start - 1 or -1)
      add_count_highlights(state, row, line, counts_start)
    else
      local indent = #string.rep('  ', entry.depth or 0)
      vim.api.nvim_buf_add_highlight(state.bufnr, state.ns, status_highlight(entry), row, indent, indent + 2)
      local counts_start = config.options.show.show_counts and line:match('.*()  %d+ %d+$') or nil
      vim.api.nvim_buf_add_highlight(state.bufnr, state.ns, config.options.highlights.file, row, indent + 3, counts_start and counts_start - 1 or -1)
      add_count_highlights(state, row, line, counts_start)
    end
  end
  state.meta, state.commit = old_meta, old_commit
  M.update_selected_line(state)
end

function M.update_selected_line(state)
  return show_render.update_selected_line(state)
end

function M.update_winbar(state)
  if not vim.api.nvim_win_is_valid(state.winid) then
    return
  end
  local selected = 0
  if #state.entries > 0 then
    local cursor = vim.api.nvim_win_get_cursor(state.winid)[1]
    if cursor > (state.entry_offset or 0) then
      selected = math.min(cursor - state.entry_offset, #state.entries)
    end
  end
  vim.wo[state.winid].winbar = table.concat({
    '%#' .. config.options.highlights.title .. '#', ' Guit status ', '%*',
    '%=',
    '%#' .. config.options.highlights.counter .. '#', string.format(' %d/%d ', selected, #state.entries), '%*',
    '%#' .. config.options.highlights.date .. '#', ' ' .. state.view_mode .. ' ', '%*',
  })
end

return M
