local config = require('guit.config')
local ui_util = require('guit.ui.util')

local M = {}

local function display_width(text)
  return vim.fn.strdisplaywidth(text)
end

local function fit_display(text, width)
  if display_width(text) <= width then
    return text .. string.rep(' ', width - display_width(text))
  end

  local acc = {}
  local used = 0
  local i = 0
  local limit = math.max(width - 1, 0)
  while i < vim.fn.strchars(text) do
    local ch = vim.fn.strcharpart(text, i, 1)
    local w = display_width(ch)
    if used + w > limit then
      break
    end
    acc[#acc + 1] = ch
    used = used + w
    i = i + 1
  end
  local clipped = table.concat(acc) .. '…'
  local clipped_w = display_width(clipped)
  if clipped_w < width then
    clipped = clipped .. string.rep(' ', width - clipped_w)
  end
  return clipped
end

local function clamp_subject(subject)
  local max = config.options.max_subject_width
  if display_width(subject) <= max then
    return subject
  end

  local acc = {}
  local used = 0
  local i = 0
  local limit = math.max(max - 1, 0)
  while i < vim.fn.strchars(subject) do
    local ch = vim.fn.strcharpart(subject, i, 1)
    local w = display_width(ch)
    if used + w > limit then
      break
    end
    acc[#acc + 1] = ch
    used = used + w
    i = i + 1
  end
  return table.concat(acc) .. '…'
end

function M.format_item(item)
  local hash = fit_display(item.short_hash, 10)
  local date = fit_display(item.date, 16)
  local author = fit_display(item.author, 20)
  local refs = item.refs ~= '' and (' ' .. item.refs) or ''
  local subject = clamp_subject(item.subject)

  local line = table.concat({ hash, '  ', date, '  ', author, refs, '  ', subject })
  return line, {
    hash_start = 0,
    hash_end = #hash,
    date_start = #hash + 2,
    date_end = #hash + 2 + #date,
    author_start = #hash + 2 + #date + 2,
    author_end = #hash + 2 + #date + 2 + #author,
    refs_start = #hash + 2 + #date + 2 + #author,
    refs_end = #hash + 2 + #date + 2 + #author + #refs,
  }
end

function M.render_lines(state, start_idx)
  local lines = {}
  local highlights = {}
  local ns = state.ns
  local offset = start_idx - 1

  for i = start_idx, #state.items do
    local item = state.items[i]
    local line, spans = M.format_item(item)
    lines[#lines + 1] = line

    local row = offset + (#lines - 1)

    highlights[#highlights + 1] = { row, spans.hash_start, spans.hash_end, config.options.highlights.hash }
    highlights[#highlights + 1] = { row, spans.date_start, spans.date_end, config.options.highlights.date }
    highlights[#highlights + 1] = { row, spans.author_start, spans.author_end, config.options.highlights.author }

    if item.refs ~= '' then
      highlights[#highlights + 1] = { row, spans.refs_start, spans.refs_end, config.options.highlights.refs }
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
