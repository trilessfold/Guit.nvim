local config = require('guit.config')
local changed_files = require('guit.changed_files')
local show_render = require('guit.ui.show_render')
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
  end
  return config.options.highlights.status
end

local function format_counts(additions, deletions)
  additions = additions or 0
  deletions = deletions or 0
  return string.format('%d %d', additions, deletions)
end

local function header_lines(state)
  local meta = state.meta or {}
  local left = meta.left or { input = state.left, short_hash = state.left }
  local right = meta.right or { input = state.right, short_hash = state.right }

  local function revision_line(label, rev)
    local hash = rev.short_hash or rev.input or ''
    local subject = rev.subject and rev.subject ~= '' and ('  ' .. rev.subject) or ''
    return string.format('%-8s%s%s', label .. ':', hash, subject)
  end

  local lines = {
    revision_line('Left', left),
    revision_line('Right', right),
  }

  if meta.behind ~= nil and meta.ahead ~= nil then
    lines[#lines + 1] = string.format('Ahead/Behind: %d %d', meta.ahead, meta.behind)
  end
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

  for i = 1, #header do
    local row = i - 1
    local line = header[i]
    if vim.startswith(line, 'Left:') or vim.startswith(line, 'Right:') then
      local label_len = line:find(':', 1, true) or 0
      local value_start = 8
      hls[#hls + 1] = { row, 0, label_len, config.options.highlights.status }
      local content = line:sub(value_start + 1)
      local hash_text, subject_text = content:match('^(%S+)%s%s+(.+)$')
      if hash_text then
        hls[#hls + 1] = { row, value_start, value_start + #hash_text, config.options.highlights.hash }
        local subject_col = value_start + #hash_text + 2
        hls[#hls + 1] = { row, subject_col, -1, config.options.highlights.subject }
      elseif content ~= '' then
        hls[#hls + 1] = { row, value_start, -1, config.options.highlights.hash }
      end
    elseif vim.startswith(line, 'Ahead/Behind:') then
      hls[#hls + 1] = { row, 0, 12, config.options.highlights.status }
      local counts = line:sub(15)
      local a, b = counts:match('^(%d+)%s+(%d+)$')
      if a then
        local a_col = 14
        hls[#hls + 1] = { row, a_col, a_col + #a, config.options.highlights.additions }
        local b_col = a_col + #a + 1
        hls[#hls + 1] = { row, b_col, b_col + #b, config.options.highlights.deletions }
      end
    elseif vim.startswith(line, 'Changes:') then
      hls[#hls + 1] = { row, 0, 8, config.options.highlights.status }
      local counts = line:sub(10)
      local a, b = counts:match('^(%d+)%s+(%d+)$')
      if a then
        local a_col = 9
        hls[#hls + 1] = { row, a_col, a_col + #a, config.options.highlights.additions }
        local b_col = a_col + #a + 1
        hls[#hls + 1] = { row, b_col, b_col + #b, config.options.highlights.deletions }
      end
    else
      hls[#hls + 1] = { row, 0, -1, config.options.highlights.subject }
    end
  end

  local saved_meta, saved_commit = state.meta, state.commit
  state.meta = nil
  state.commit = state.right
  local old_header = state.entry_offset
  if #state.entries == 0 then
    lines[#lines + 1] = 'No changed files'
    hls[#hls + 1] = { #lines - 1, 0, -1, config.options.highlights.loading }
  else
    for _, entry in ipairs(state.entries) do
      lines[#lines + 1] = show_render.format_entry(entry)
    end
    ui_util.with_modifiable(state.bufnr, function()
      vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
    end)
    -- reuse highlight generation by temporarily mapping rows through show_render logic
    vim.api.nvim_buf_clear_namespace(state.bufnr, state.ns, 0, -1)
    for _, hl in ipairs(hls) do
      vim.api.nvim_buf_add_highlight(state.bufnr, state.ns, hl[4], hl[1], hl[2], hl[3])
    end
    for idx, entry in ipairs(state.entries) do
      local row = state.entry_offset + idx - 1
      local line = show_render.format_entry(entry)
      if entry.kind == 'dir' then
        local start_col = #string.rep('  ', entry.depth or 0)
        vim.api.nvim_buf_add_highlight(state.bufnr, state.ns, config.options.highlights.refs, row, start_col, start_col + 1)
        local counts_start = config.options.show.show_counts and line:match('.*()  %d+ %d+$') or nil
        if counts_start then
          vim.api.nvim_buf_add_highlight(state.bufnr, state.ns, config.options.highlights.dir, row, start_col + 2, counts_start - 1)
          local counts_text = line:sub(counts_start + 2)
          local add_text, del_text = counts_text:match('^(%d+)%s+(%d+)$')
          if add_text then
            local add_col = counts_start + 1
            vim.api.nvim_buf_add_highlight(state.bufnr, state.ns, config.options.highlights.additions, row, add_col, add_col + #add_text)
            local del_col = add_col + #add_text + 1
            vim.api.nvim_buf_add_highlight(state.bufnr, state.ns, config.options.highlights.deletions, row, del_col, del_col + #del_text)
          end
        else
          vim.api.nvim_buf_add_highlight(state.bufnr, state.ns, config.options.highlights.dir, row, start_col + 2, -1)
        end
      else
        local indent = #string.rep('  ', entry.depth or 0)
        vim.api.nvim_buf_add_highlight(state.bufnr, state.ns, status_highlight(entry), row, indent, indent + 2)
        local counts_start = config.options.show.show_counts and line:match('.*()  %d+ %d+$') or nil
        local name_start = indent + 3
        local name_end = counts_start and (counts_start - 1) or -1
        vim.api.nvim_buf_add_highlight(state.bufnr, state.ns, config.options.highlights.file, row, name_start, name_end)
        if entry.old_path then
          local old_start = line:find('← ', 1, true)
          if old_start then
            local old_end = counts_start and (counts_start - 1) or -1
            vim.api.nvim_buf_add_highlight(state.bufnr, state.ns, config.options.highlights.date, row, old_start - 1, old_end)
          end
        end
        if counts_start then
          local counts_text = line:sub(counts_start + 2)
          local add_text, del_text = counts_text:match('^(%d+)%s+(%d+)$')
          if add_text then
            local add_col = counts_start + 1
            vim.api.nvim_buf_add_highlight(state.bufnr, state.ns, config.options.highlights.additions, row, add_col, add_col + #add_text)
            local del_col = add_col + #add_text + 1
            vim.api.nvim_buf_add_highlight(state.bufnr, state.ns, config.options.highlights.deletions, row, del_col, del_col + #del_text)
          end
        end
      end
    end
    show_render.update_selected_line(state)
    state.meta, state.commit = saved_meta, saved_commit
    return
  end

  ui_util.with_modifiable(state.bufnr, function()
    vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
  end)
  for _, hl in ipairs(hls) do
    vim.api.nvim_buf_add_highlight(state.bufnr, state.ns, hl[4], hl[1], hl[2], hl[3])
  end
  show_render.update_selected_line(state)
  state.meta, state.commit = saved_meta, saved_commit
  state.entry_offset = #header
end

function M.update_selected_line(state)
  return show_render.update_selected_line(state)
end

function M.update_winbar(state)
  if not vim.api.nvim_win_is_valid(state.winid) then return end
  local selected = 0
  if #state.entries > 0 then
    local cursor = vim.api.nvim_win_get_cursor(state.winid)[1]
    if cursor > (state.entry_offset or 0) then
      selected = math.min(cursor - state.entry_offset, #state.entries)
    end
  end
  vim.wo[state.winid].winbar = table.concat({
    '%#' .. config.options.highlights.title .. '#', ' Guit compare ', '%*',
    '%#' .. config.options.highlights.hash .. '#', ' ' .. state.left .. '..' .. state.right .. ' ', '%*',
    '%=',
    '%#' .. config.options.highlights.counter .. '#', string.format(' %d/%d ', selected, #state.entries), '%*',
    '%#' .. config.options.highlights.date .. '#', ' ' .. state.view_mode .. ' ', '%*',
  })
end

return M
