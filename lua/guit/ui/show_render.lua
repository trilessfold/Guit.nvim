local config = require('guit.config')
local ui_util = require('guit.ui.util')

local M = {}

local function status_label(entry)
  local status = entry.status or ''
  if status:match('^R%d+$') then
    return 'R'
  elseif status:match('^C%d+$') then
    return 'C'
  end
  return status
end

local function header_lines(state)
  local meta = state.meta or {}
  local lines = {
    'Commit: ' .. (meta.hash or state.commit),
    'Author: ' .. (meta.author or '…'),
    'Date:   ' .. ((meta.date and meta.date ~= '') and meta.date or '…'),
  }

  local message_lines = {}
  if meta.subject and meta.subject ~= '' then
    message_lines[#message_lines + 1] = meta.subject
  end
  if meta.body and meta.body ~= '' then
    for _, line in ipairs(vim.split(meta.body, '\n', { plain = true })) do
      message_lines[#message_lines + 1] = line
    end
  end

  if #message_lines > 0 then
    lines[#lines + 1] = ''
    lines[#lines + 1] = 'Message:'
    for _, line in ipairs(message_lines) do
      lines[#lines + 1] = '  ' .. line
    end
  end

  lines[#lines + 1] = ''
  return lines
end

function M.format_entry(entry)
  local indent = string.rep('  ', entry.depth or 0)
  if entry.kind == 'dir' then
    local icon = entry.expanded and '▾' or '▸'
    return string.format('%s%s %s/', indent, icon, entry.name)
  end

  local label = status_label(entry)
  local renamed = entry.old_path and ('  ← ' .. entry.old_path) or ''
  return string.format('%s%-2s %s%s', indent, label, entry.name, renamed)
end

function M.render_all(state)
  vim.api.nvim_buf_clear_namespace(state.bufnr, state.ns, 0, -1)

  local header = header_lines(state)
  state.entry_offset = #header

  local lines = vim.deepcopy(header)
  local hls = {}

  for i = 1, #header do
    local row = i - 1
    if i == 1 then
      hls[#hls + 1] = { row, 0, 7, config.options.highlights.hash }
      hls[#hls + 1] = { row, 8, -1, config.options.highlights.subject }
    elseif i == 2 then
      hls[#hls + 1] = { row, 0, 7, config.options.highlights.author }
      hls[#hls + 1] = { row, 8, -1, config.options.highlights.subject }
    elseif i == 3 then
      hls[#hls + 1] = { row, 0, 5, config.options.highlights.date }
      hls[#hls + 1] = { row, 8, -1, config.options.highlights.subject }
    else
      hls[#hls + 1] = { row, 0, -1, config.options.highlights.date }
    end
  end

  if #state.entries == 0 then
    lines[#lines + 1] = 'No changed files'
    hls[#hls + 1] = { #lines - 1, 0, -1, config.options.highlights.loading }
  else
    for idx, entry in ipairs(state.entries) do
      local row = state.entry_offset + idx - 1
      local line = M.format_entry(entry)
      lines[#lines + 1] = line

      if entry.kind == 'dir' then
        local start_col = #string.rep('  ', entry.depth or 0)
        hls[#hls + 1] = { row, start_col, start_col + 1, config.options.highlights.refs }
        hls[#hls + 1] = { row, start_col + 2, -1, config.options.highlights.dir }
      else
        local indent = #string.rep('  ', entry.depth or 0)
        hls[#hls + 1] = { row, indent, indent + 2, config.options.highlights.status }
        local name_start = indent + 3
        local name_end = name_start + #entry.name
        hls[#hls + 1] = { row, name_start, name_end, config.options.highlights.file }
        if entry.old_path then
          local old_start = line:find('← ', 1, true)
          if old_start then
            hls[#hls + 1] = { row, old_start - 1, -1, config.options.highlights.date }
          end
        end
      end
    end
  end

  ui_util.with_modifiable(state.bufnr, function()
    vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
  end)
  for _, hl in ipairs(hls) do
    vim.api.nvim_buf_add_highlight(state.bufnr, state.ns, hl[4], hl[1], hl[2], hl[3])
  end
  M.update_selected_line(state)
end

function M.update_selected_line(state)
  if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
    return
  end
  local line = vim.api.nvim_win_get_cursor(state.winid)[1]
  ui_util.update_line_selection(state.bufnr, state.selection_ns, line, config.options.highlights.selected)
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

  local mode = state.view_mode
  local commit = (state.meta and state.meta.short_hash) or state.commit:sub(1, 10)

  vim.wo[state.winid].winbar = table.concat({
    '%#' .. config.options.highlights.title .. '#',
    ' Guit show ',
    '%*',
    '%#' .. config.options.highlights.hash .. '#',
    ' ' .. commit .. ' ',
    '%*',
    '%=',
    '%#' .. config.options.highlights.counter .. '#',
    string.format(' %d/%d ', selected, #state.entries),
    '%*',
    '%#' .. config.options.highlights.date .. '#',
    ' ' .. mode .. ' ',
    '%*',
  })
end

return M
