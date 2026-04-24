local config = require('guit.config')
local ui_util = require('guit.ui.util')

local M = {}

local function display_width(text)
  return vim.fn.strdisplaywidth(text)
end

local function fit_display(text, width)
  text = text or ''
  local current = display_width(text)
  if current == width then
    return text
  end
  if current < width then
    return text .. string.rep(' ', width - current)
  end
  local acc, used = {}, 0
  local i = 0
  local limit = math.max(width - 1, 0)
  while i < vim.fn.strchars(text) do
    local ch = vim.fn.strcharpart(text, i, 1)
    local w = display_width(ch)
    if used + w > limit then break end
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

local function counts_raw(item)
  return string.format('%df %d %d', item.files_changed or 0, item.additions or 0, item.deletions or 0)
end

local function counts_text(item)
  return fit_display(counts_raw(item), 14)
end

function M.format_item(item)
  local hash = fit_display(item.short_hash, 10)
  local date = fit_display(item.date, 16)
  local author = fit_display(item.author, 20)
  local counts = counts_text(item)
  local subject = item.subject or ''

  local sep = '  '
  local segments = { hash, sep, date, sep, author, sep, counts, sep, subject }
  local line = table.concat(segments)

  local hash_start = 0
  local hash_end = #hash
  local date_start = hash_end + #sep
  local date_end = date_start + #date
  local author_start = date_end + #sep
  local author_end = author_start + #author
  local counts_start = author_end + #sep
  local counts_end = counts_start + #counts

  return line, {
    hash_start = hash_start,
    hash_end = hash_end,
    date_start = date_start,
    date_end = date_end,
    author_start = author_start,
    author_end = author_end,
    counts_start = counts_start,
    counts_end = counts_end,
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
    local counts = line:sub(spans.counts_start + 1, spans.counts_end)
    local files_s, add_s, del_s = counts:match('^(%d+f)%s+(%d+)%s+(%d+)')
    if files_s then
      local files_col = spans.counts_start
      highlights[#highlights + 1] = { row, files_col, files_col + #files_s, config.options.highlights.counter }
      local add_col = files_col + #files_s + 1
      highlights[#highlights + 1] = { row, add_col, add_col + #add_s, config.options.highlights.additions }
      local del_col = add_col + #add_s + 1
      highlights[#highlights + 1] = { row, del_col, del_col + #del_s, config.options.highlights.deletions }
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
  if not state.loading_row then return end
  ui_util.with_modifiable(state.bufnr, function()
    vim.api.nvim_buf_set_lines(state.bufnr, state.loading_row, state.loading_row + 1, false, {})
  end)
  state.loading_row = nil
end

function M.update_selected_line(state)
  if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then return end
  local line = vim.api.nvim_win_get_cursor(state.winid)[1]
  ui_util.update_line_selection(state.bufnr, state.selection_ns, line, config.options.highlights.selected)
end

function M.update_winbar(state)
  if not vim.api.nvim_win_is_valid(state.winid) then return end
  local loaded = #state.items
  local total = state.total_count and tostring(state.total_count) or '?'
  local selected = loaded > 0 and math.min(vim.api.nvim_win_get_cursor(state.winid)[1], loaded) or 0
  local selected_label = loaded > 0 and string.format(' %d/%s ', selected, total) or (' 0/' .. total .. ' ')
  local loaded_label = string.format(' loaded %d/%s ', loaded, total)
  local spinner = state.loading and '  loading…' or ''
  local done = state.eof and loaded > 0 and '  eof' or ''
  local path = state.path_display or state.path or ''

  vim.wo[state.winid].winbar = table.concat({
    '%#' .. config.options.highlights.title .. '#',
    ' Guit history ',
    '%*',
    '%#' .. config.options.highlights.file .. '#',
    ' ' .. path .. ' ',
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
