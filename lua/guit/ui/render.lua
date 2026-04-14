local config = require('guit.config')
local ui_util = require('guit.ui.util')

local M = {}

local function clamp_subject(subject)
  local max = config.options.max_subject_width
  if vim.fn.strdisplaywidth(subject) <= max then
    return subject
  end
  return vim.fn.strcharpart(subject, 0, max - 1) .. '…'
end

function M.format_item(item)
  local refs = item.refs ~= '' and (' ' .. item.refs) or ''
  return string.format('%-10s  %-16s  %-20s%s  %s', item.short_hash, item.date, item.author, refs, clamp_subject(item.subject))
end

function M.render_lines(state, start_idx)
  local lines = {}
  local highlights = {}
  local ns = state.ns
  local offset = start_idx - 1

  for i = start_idx, #state.items do
    local item = state.items[i]
    local line = M.format_item(item)
    lines[#lines + 1] = line

    local row = offset + (#lines - 1)
    local hash_width = 10
    local date_width = 16
    local author_width = 20
    local hash_end = hash_width
    local date_start = hash_width + 2
    local date_end = date_start + date_width
    local author_start = date_end + 2
    local author_end = author_start + #item.author
    local refs_start = author_start + author_width

    highlights[#highlights + 1] = { row, 0, hash_end, config.options.highlights.hash }
    highlights[#highlights + 1] = { row, date_start, date_end, config.options.highlights.date }
    highlights[#highlights + 1] = { row, author_start, author_end, config.options.highlights.author }

    if item.refs ~= '' then
      local refs_end = refs_start + 1 + #item.refs
      highlights[#highlights + 1] = { row, refs_start, refs_end, config.options.highlights.refs }
    end
  end

  ui_util.with_modifiable(state.bufnr, function()
    vim.api.nvim_buf_set_lines(state.bufnr, start_idx - 1, -1, false, lines)
  end)
  for _, hl in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(state.bufnr, ns, hl[4], hl[1], hl[2], hl[3])
  end
end

function M.set_loading_line(state, text)
  ui_util.with_modifiable(state.bufnr, function()
    if state.loading_row then
      vim.api.nvim_buf_set_lines(state.bufnr, state.loading_row, state.loading_row + 1, false, { text })
    else
      state.loading_row = vim.api.nvim_buf_line_count(state.bufnr)
      vim.api.nvim_buf_set_lines(state.bufnr, -1, -1, false, { text })
    end
  end)
  vim.api.nvim_buf_add_highlight(state.bufnr, state.ns, config.options.highlights.loading, state.loading_row, 0, -1)
end

function M.clear_loading_line(state)
  if not state.loading_row then
    return
  end
  ui_util.with_modifiable(state.bufnr, function()
    vim.api.nvim_buf_set_lines(state.bufnr, state.loading_row, state.loading_row + 1, false, {})
  end)
  state.loading_row = nil
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

  local loaded = #state.items
  local total = state.total_count and tostring(state.total_count) or '?'
  local selected = loaded > 0 and math.min(vim.api.nvim_win_get_cursor(state.winid)[1], loaded) or 0
  local selected_label = loaded > 0 and string.format(' %d/%s ', selected, total) or ' 0/' .. total .. ' '
  local loaded_label = string.format(' loaded %d/%s ', loaded, total)
  local spinner = state.loading and '  loading…' or ''
  local done = state.eof and loaded > 0 and '  eof' or ''

  vim.wo[state.winid].winbar = table.concat({
    '%#' .. config.options.highlights.title .. '#',
    ' Guit log ',
    '%*',
    '%=',
    '%#' .. config.options.highlights.counter .. '#',
    selected_label,
    '%*',
    '%#' .. config.options.highlights.date .. '#',
    loaded_label,
    '%*',
    spinner,
    done,
  })
end

return M
