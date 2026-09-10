local config = require('guit.config')
local highlights = require('guit.ui.highlight')
local keymaps = require('guit.keymaps')

--- Inline diff: one buffer, the changes drawn on top of it.
---
--- The buffer shows the *new* side of a comparison -- a fugitive object or the
--- working tree file itself, with its own filetype, treesitter and whatever
--- else the user has attached to it. The old side is never loaded into a
--- buffer. Instead the removed lines are drawn as virtual lines where they
--- used to be, the way VS Code's inline diff draws them: everything the new
--- side has is green, everything the old side had is red, and within a
--- changed line the characters that differ get a stronger shade of the same
--- colour. Removed lines keep the syntax colours of the old side.
---
--- The inline and the side-by-side shape never share a buffer: the overlay
--- takes the buffer out of a split diff, and the buffer entering one takes
--- the overlay down.
---
--- Because the buffer is a real one, everything that works on normal buffers
--- keeps working: gitsigns, LSP, `:Guit blame` following it, the jumplist.
--- That is the point of the whole exercise; a side-by-side vimdiff of two
--- fugitive objects gives none of it.
local M = {}

local NS = vim.api.nvim_create_namespace('guit-inline-diff')

-- bufnr -> record. A record is the old side plus everything needed to take the
-- overlay down again without leaving a trace in the buffer.
local attached = {}

-- bufnr -> true while this module has an nvim_buf_attach listener on the
-- buffer. One listener per buffer for its whole life: attaching a second one
-- after every detach/attach cycle would pile up callbacks.
local listening = {}

-- bufnr -> the number of the latest request to attach to it. The old side
-- usually arrives from an asynchronous git show; anything that takes the
-- overlay down, or asks for a different one, in the meantime moves this
-- number on, and the late result is dropped when it sees it no longer holds
-- the current one.
local requests = {}

local RENDER_DELAY_MS = 80

-- Removed lines wider than the window scroll with it under 'nowrap' instead
-- of being cut at the edge, where Neovim supports it.
local SCROLL_VIRT_LINES = vim.fn.has('nvim-0.11') == 1

---------------------------------------------------------------------------
-- Pure diffing
---------------------------------------------------------------------------

local function join(lines)
  if #lines == 0 then
    return ''
  end
  return table.concat(lines, '\n') .. '\n'
end

-- 'diffopt' flags that map straight onto a vim.diff() boolean option.
local DIFFOPT_FLAGS = {
  ['indent-heuristic'] = 'indent_heuristic',
  iwhite = 'ignore_whitespace_change',
  iwhiteall = 'ignore_whitespace',
  iwhiteeol = 'ignore_whitespace_change_at_eol',
  iblank = 'ignore_blank_lines',
}

--- Reads 'diffopt' into the options `vim.diff()` takes, so the inline diff
--- groups hunks the same way `:diffthis` and `:Gdiffsplit` do for this user
--- -- their algorithm, their whitespace handling, their linematch setting --
--- instead of a strategy of our own that would disagree with them on where a
--- change starts and ends.
---@return table
local function diffopt_to_vim_diff()
  local opts = {}
  for _, item in ipairs(vim.opt.diffopt:get()) do
    local flag = DIFFOPT_FLAGS[item]
    if flag then
      opts[flag] = true
    else
      local algorithm = item:match('^algorithm:(.+)$')
      local linematch = item:match('^linematch:(%d+)$')
      if algorithm then
        opts.algorithm = algorithm
      elseif linematch then
        opts.linematch = tonumber(linematch)
      end
    end
  end
  return opts
end

--- Line-level hunks between two line lists, in the shape `vim.diff` reports
--- them but with the removed text attached so the renderer does not need the
--- old side any more.
---
--- `new_start` for a pure deletion (`new_count == 0`) is the new-side line the
--- removed lines used to follow, 0 when they were at the top of the file.
---@param old_lines string[]
---@param new_lines string[]
---@return table[] hunks { old_start, old_count, new_start, new_count, removed }
function M.hunks(old_lines, new_lines)
  local opts = diffopt_to_vim_diff()
  local linematch = opts.linematch
  opts.linematch = nil
  opts.result_type = 'indices'

  local raw
  if linematch then
    local ok
    ok, raw = pcall(vim.diff, join(old_lines), join(new_lines),
      vim.tbl_extend('force', opts, { linematch = linematch }))
    if not ok then
      -- Older Neovim without linematch: alignment inside a hunk is cruder,
      -- the hunks themselves are the same.
      raw = nil
    end
  end
  if not raw then
    raw = vim.diff(join(old_lines), join(new_lines), opts)
  end

  local hunks = {}
  for _, h in ipairs(raw or {}) do
    local old_start, old_count, new_start, new_count = h[1], h[2], h[3], h[4]
    local removed = {}
    for i = 0, old_count - 1 do
      removed[#removed + 1] = old_lines[old_start + i] or ''
    end
    hunks[#hunks + 1] = {
      old_start = old_start,
      old_count = old_count,
      new_start = new_start,
      new_count = new_count,
      removed = removed,
    }
  end
  return hunks
end

--- Splits a line into words, runs of blanks and single punctuation characters.
--- Non-ASCII bytes count as word characters so UTF-8 sequences stay whole.
local function tokenize(line)
  local tokens = {}
  local pos = 1
  while pos <= #line do
    local tok = line:match('^[%w_\128-\255]+', pos)
      or line:match('^%s+', pos)
      or line:sub(pos, pos)
    tokens[#tokens + 1] = tok
    pos = pos + #tok
  end
  return tokens
end

--- Byte offsets where each token starts, plus the total length as a sentinel.
local function offsets(tokens)
  local out = { 0 }
  for i, tok in ipairs(tokens) do
    out[i + 1] = out[i] + #tok
  end
  return out
end

-- Above this share of a line being different, word highlights stop carrying
-- information and the whole line reads better as simply "changed".
local WORD_DIFF_MAX_RATIO = 0.8

local function is_continuation(byte)
  return byte and byte >= 0x80 and byte <= 0xBF
end

--- Narrows a replacement to the characters that actually differ, the way
--- 'diffopt' inline:char does in vimdiff: OutAuthentication -> OutRegistration
--- highlights "Authentic" and "Registr", not the whole words. Tokens are the
--- unit of the diff, characters the unit of the highlight. Never splits a
--- UTF-8 sequence.
local function trim_common(old_line, new_line, edit)
  local os, of = edit.old[1], edit.old[2]
  local ns, nf = edit.new[1], edit.new[2]
  if of <= os or nf <= ns then
    return
  end
  while os < of and ns < nf and old_line:byte(os + 1) == new_line:byte(ns + 1) do
    os, ns = os + 1, ns + 1
  end
  while is_continuation(old_line:byte(os + 1)) and os > edit.old[1] do
    os, ns = os - 1, ns - 1
  end
  while of > os and nf > ns and old_line:byte(of) == new_line:byte(nf) do
    of, nf = of - 1, nf - 1
  end
  while is_continuation(old_line:byte(of + 1)) and of < edit.old[2] do
    of, nf = of + 1, nf + 1
  end
  edit.old = { os, of }
  edit.new = { ns, nf }
end

--- The edits that turn one line into another, as byte ranges: a 0-based
--- inclusive start and exclusive finish on each side. An insertion has an
--- empty old range, a deletion an empty new range; the new range of a
--- deletion still says where in the new line the removed text used to sit.
---
--- Returns nil when the lines have too little in common for word-level
--- highlights to mean anything.
---@param old_line string
---@param new_line string
---@return table[]|nil edits { old = { s, f }, new = { s, f } }
function M.word_edits(old_line, new_line)
  if old_line == new_line then
    return {}
  end
  -- A side that is empty or only blanks has nothing to pair words with, and
  -- the usual "too different" rule would turn trailing whitespace being
  -- stripped into a full removed line. It is one edit: whatever the other
  -- side has.
  if old_line:match('^%s*$') or new_line:match('^%s*$') then
    return { { old = { 0, #old_line }, new = { 0, #new_line } } }
  end
  local old_tokens, new_tokens = tokenize(old_line), tokenize(new_line)
  if #old_tokens == 0 or #new_tokens == 0 then
    return nil
  end

  local raw = vim.diff(join(old_tokens), join(new_tokens), { result_type = 'indices' })
  local old_off, new_off = offsets(old_tokens), offsets(new_tokens)
  local edits = {}
  local old_total, new_total = 0, 0

  for _, h in ipairs(raw or {}) do
    local os, oc, ns, nc = h[1], h[2], h[3], h[4]
    -- vim.diff reports the line *after which* an empty side sits, so an
    -- insertion's old index and a deletion's new index are one behind.
    local old_range = oc > 0 and { old_off[os], old_off[os + oc] } or { old_off[os + 1], old_off[os + 1] }
    local new_range = nc > 0 and { new_off[ns], new_off[ns + nc] } or { new_off[ns + 1], new_off[ns + 1] }
    old_total = old_total + (old_range[2] - old_range[1])
    new_total = new_total + (new_range[2] - new_range[1])
    edits[#edits + 1] = { old = old_range, new = new_range }
  end

  if (#old_line > 0 and old_total / #old_line > WORD_DIFF_MAX_RATIO)
      or (#new_line > 0 and new_total / #new_line > WORD_DIFF_MAX_RATIO) then
    return nil
  end
  for _, edit in ipairs(edits) do
    trim_common(old_line, new_line, edit)
  end
  return edits
end

--- The non-empty ranges of word_edits, per side.
---@return table[]|nil old_ranges
---@return table[]|nil new_ranges
function M.word_ranges(old_line, new_line)
  local edits = M.word_edits(old_line, new_line)
  if not edits then
    return nil, nil
  end
  local old_ranges, new_ranges = {}, {}
  for _, edit in ipairs(edits) do
    if edit.old[2] > edit.old[1] then
      old_ranges[#old_ranges + 1] = edit.old
    end
    if edit.new[2] > edit.new[1] then
      new_ranges[#new_ranges + 1] = edit.new
    end
  end
  return old_ranges, new_ranges
end

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------

local function hl(name)
  return config.options.highlights[name]
end

--- Expands tabs the way the buffer would display them, so a virtual line
--- lines up with the real ones around it. Virtual text renders a literal tab
--- as `^I`.
local function expand_tabs(text, col, tabstop)
  local out = {}
  for part, tab in text:gmatch('([^\t]*)(\t?)') do
    if part ~= '' then
      out[#out + 1] = part
      col = col + vim.fn.strdisplaywidth(part, col)
    end
    if tab ~= '' then
      local width = tabstop - (col % tabstop)
      out[#out + 1] = (' '):rep(width)
      col = col + width
    end
  end
  return table.concat(out), col
end

--- Treesitter highlights of the old side, as `{ start, finish, group }` byte
--- spans per 0-based row, so removed lines are coloured like the code around
--- them instead of as plain text. The whole old side is parsed at once: a
--- line on its own is often not valid code (the inside of a string, half a
--- function call) and would be coloured wrong.
---
--- nil when there is nothing to parse with: no filetype, no parser for it,
--- or syntax colouring turned off.
local function parse_old_side(old_lines, filetype)
  if #old_lines == 0 or filetype == '' or not config.options.diff.syntax then
    return nil
  end
  local lang = vim.treesitter.language.get_lang(filetype) or filetype
  local source = table.concat(old_lines, '\n')
  local ok, parser = pcall(vim.treesitter.get_string_parser, source, lang)
  if not ok or not parser then
    return nil
  end

  local rows = {}
  ok = pcall(function()
    parser:parse(true)
    parser:for_each_tree(function(tree, ltree)
      local query = vim.treesitter.query.get(ltree:lang(), 'highlights')
      if not query then
        return
      end
      -- Captures come in pattern order and injected trees after their
      -- parent, so a later span painting over an earlier one is what the
      -- buffer's own highlighter would show too.
      for id, node in query:iter_captures(tree:root(), source, 0, -1) do
        local name = query.captures[id]
        if name:sub(1, 1) ~= '_' and name ~= 'spell' and name ~= 'nospell' and name ~= 'conceal' then
          local group = '@' .. name .. '.' .. ltree:lang()
          local start_row, start_col, end_row, end_col = node:range()
          for row = start_row, end_row do
            local line = old_lines[row + 1]
            if line then
              local from = row == start_row and start_col or 0
              local to = row == end_row and math.min(end_col, #line) or #line
              if to > from then
                local spans = rows[row] or {}
                spans[#spans + 1] = { from, to, group }
                rows[row] = spans
              end
            end
          end
        end
      end
    end)
  end)
  return ok and rows or nil
end

--- The old side's syntax spans, parsed on first use and again only when the
--- buffer's filetype changes. The old side itself never does.
local function old_side_syntax(bufnr, rec)
  local filetype = vim.bo[bufnr].filetype
  if rec.syntax_filetype ~= filetype then
    rec.syntax_filetype = filetype
    rec.syntax = parse_old_side(rec.old_lines, filetype)
  end
  return rec.syntax
end

--- Builds the `[text, hl]` chunks for one removed line. The characters that
--- differ get `word_hl`, the rest `base_hl`; both only paint a background,
--- stacked over the syntax group of each character so the text keeps its
--- colour. The line is padded so the background runs to the window edge like
--- a real highlighted line does.
local function virt_line_chunks(text, ranges, syntax, base_hl, word_hl, tabstop)
  local groups = {}
  for _, span in ipairs(syntax or {}) do
    for byte = span[1] + 1, math.min(span[2], #text) do
      groups[byte] = span[3]
    end
  end
  local differs = {}
  for _, range in ipairs(ranges or {}) do
    for byte = range[1] + 1, math.min(range[2], #text) do
      differs[byte] = true
    end
  end

  -- A chunk ends wherever the syntax group or the "differs" flag changes.
  -- Both only ever change on a character boundary: treesitter ranges are
  -- token boundaries and word ranges never split a UTF-8 sequence.
  local chunks = {}
  local col = 0
  local start = 1
  for byte = 2, #text + 1 do
    if byte > #text or groups[byte] ~= groups[start] or differs[byte] ~= differs[start] then
      local piece
      piece, col = expand_tabs(text:sub(start, byte - 1), col, tabstop)
      local bg = differs[start] and word_hl or base_hl
      chunks[#chunks + 1] = { piece, groups[start] and { groups[start], bg } or bg }
      start = byte
    end
  end

  -- A window can never be wider than the screen, and virtual text past the
  -- edge is simply clipped. A line that scrolls with the window needs a full
  -- screen past its end, whatever its length, to never show a gap.
  local pad = SCROLL_VIRT_LINES and vim.o.columns or (vim.o.columns - col)
  if pad > 0 then
    chunks[#chunks + 1] = { (' '):rep(pad), base_hl }
  end
  if #chunks == 0 then
    chunks[1] = { ' ', base_hl }
  end
  return chunks
end

--- The buffer line a hunk is reached at by `]c`: its first new-side line, or
--- for a pure deletion the line the removed text hangs off.
local function anchor_line(hunk)
  if hunk.new_count > 0 then
    return hunk.new_start
  end
  return math.max(1, hunk.new_start)
end

-- Line highlights and signs are collected per row while the hunks render
-- and emitted afterwards, one row at a time. A row can mean two things at
-- once -- a changed line that a deletion follows -- and two sign extmarks
-- would show only one of them, while a single `~_` shows both.
--
-- The line background is deliberately *not* a line_hl_group. That kind of
-- highlight paints over the background of every range highlight on the
-- line, whatever their priority, so a green inserted word on a DiffChange
-- line came out as DiffChange with the word merely bold. A range highlight
-- spanning the line with hl_eol looks the same and combines by priority.
-- It also does not count as a sign, which matters to statuscolumns that
-- pick one sign per line from nvim_buf_get_extmarks(type = 'sign').
local function note_row(rec, row, field, value)
  local entry = rec.rows[row] or {}
  entry[field] = value == nil and true or value
  rec.rows[row] = entry
end

--- The sign for a row. The glyphs follow gitsigns, which most eyes already
--- read: `_` says "something was removed below this line", `‾` "above it",
--- and `~_` a changed line with a deletion after it.
local function sign_for(entry)
  local text, group
  if entry.change then
    text, group = '~', 'diff_sign_change'
  elseif entry.add then
    text, group = '+', 'diff_sign_add'
  elseif entry.deleted then
    text, group = '-', 'diff_sign_delete'
  end
  if entry.delete_above then
    return '‾', 'diff_sign_delete'
  end
  if entry.delete_below then
    if text then
      return text .. '_', group
    end
    return '_', 'diff_sign_delete'
  end
  return text, group
end

local function render_rows(bufnr, rec)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  for row, entry in pairs(rec.rows) do
    if row < line_count then
      if entry.line_hl then
        vim.api.nvim_buf_set_extmark(bufnr, NS, row, 0, {
          end_row = row + 1,
          end_col = 0,
          hl_group = entry.line_hl,
          hl_eol = true,
          priority = 20,
        })
      end
      if config.options.diff.signs then
        local text, group = sign_for(entry)
        if text then
          vim.api.nvim_buf_set_extmark(bufnr, NS, row, 0, {
            sign_text = text,
            sign_hl_group = hl(group),
            priority = 20,
          })
        end
      end
    end
  end
end

local function render_all_deleted(bufnr, rec)
  for row = 0, vim.api.nvim_buf_line_count(bufnr) - 1 do
    note_row(rec, row, 'line_hl', hl('diff_delete'))
    note_row(rec, row, 'deleted')
  end
end

--- Places removed lines as virtual lines at `row`, above or below it.
local function place_virt_lines(bufnr, row, above, virt_lines)
  if #virt_lines == 0 then
    return
  end
  vim.api.nvim_buf_set_extmark(bufnr, NS, row, 0, {
    virt_lines = virt_lines,
    virt_lines_above = above,
    virt_lines_overflow = SCROLL_VIRT_LINES and 'scroll' or nil,
    priority = 20,
  })
end

local function render_hunk(bufnr, rec, hunk, tabstop, word_diff)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local removed_ranges = {}

  -- New-side lines, all green: in a unified view a changed line is simply
  -- the new version of a removed one. The pairing with a removed line only
  -- decides the sign and which line the characters are diffed against.
  for i = 1, hunk.new_count do
    local row = hunk.new_start + i - 2
    if row >= line_count then
      break
    end
    local paired = i <= hunk.old_count
    note_row(rec, row, 'line_hl', hl('diff_add'))
    note_row(rec, row, paired and 'change' or 'add')

    if paired and word_diff then
      local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ''
      local old_ranges, new_ranges = M.word_ranges(hunk.removed[i], line)
      removed_ranges[i] = old_ranges
      for _, range in ipairs(new_ranges or {}) do
        vim.api.nvim_buf_set_extmark(bufnr, NS, row, range[1], {
          end_col = range[2],
          hl_group = hl('diff_add_text'),
          priority = 30,
        })
      end
    end
  end

  -- Old-side lines, drawn where they used to be: the whole removed block
  -- above the new one, as in a unified diff.
  local virt_lines = {}
  local syntax = hunk.old_count > 0 and old_side_syntax(bufnr, rec) or nil
  for i, text in ipairs(hunk.removed) do
    local old_row = hunk.old_start + i - 2
    virt_lines[#virt_lines + 1] = virt_line_chunks(text, removed_ranges[i], syntax and syntax[old_row],
      hl('diff_delete'), hl('diff_delete_text'), tabstop)
  end
  if #virt_lines == 0 then
    return
  end

  if hunk.new_count > 0 then
    place_virt_lines(bufnr, math.min(hunk.new_start - 1, line_count - 1), true, virt_lines)
    return
  end

  -- A pure deletion hangs off the line it followed; at the top of the file
  -- there is no such line, so it hangs above the first one.
  if hunk.new_start == 0 then
    place_virt_lines(bufnr, 0, true, virt_lines)
    note_row(rec, 0, 'delete_above')
  else
    local row = math.min(hunk.new_start - 1, line_count - 1)
    place_virt_lines(bufnr, row, false, virt_lines)
    note_row(rec, row, 'delete_below')
  end
end

local function render(bufnr, rec)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
  rec.rows = {}

  if rec.all_deleted then
    rec.hunks = {}
    render_all_deleted(bufnr, rec)
    render_rows(bufnr, rec)
    return
  end

  local new_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  rec.hunks = M.hunks(rec.old_lines, new_lines)
  local tabstop = vim.bo[bufnr].tabstop
  local word_diff = config.options.diff.word_diff and true or false
  for _, hunk in ipairs(rec.hunks) do
    render_hunk(bufnr, rec, hunk, tabstop, word_diff)
  end
  render_rows(bufnr, rec)
end

-- Edits arrive one keystroke at a time; redrawing after each would make a big
-- file sluggish. Collapse them into one redraw shortly after typing pauses.
local function schedule_render(bufnr, rec)
  rec.pending = (rec.pending or 0) + 1
  local generation = rec.pending
  vim.defer_fn(function()
    if attached[bufnr] ~= rec or rec.pending ~= generation then
      return
    end
    render(bufnr, rec)
  end, RENDER_DELAY_MS)
end

---------------------------------------------------------------------------
-- Buffer-local mappings
---------------------------------------------------------------------------

local NAV_ACTIONS = { hunk_next = 1, hunk_prev = -1 }

--- Maps hunk navigation into the buffer for as long as the overlay is shown.
---
--- This is the one place Guit maps into a buffer it does not own. A mapping
--- that was already there -- gitsigns' ]c, say -- is saved and put back when
--- the overlay goes.
local function install_maps(bufnr, rec)
  rec.saved_maps = {}
  for action, dir in pairs(NAV_ACTIONS) do
    local lhs = keymaps.key_for(action)
    if lhs then
      local existing = vim.api.nvim_buf_call(bufnr, function()
        return vim.fn.maparg(lhs, 'n', false, true)
      end)
      if type(existing) == 'table' and existing.buffer == 1 then
        rec.saved_maps[lhs] = existing
      end
      vim.keymap.set('n', lhs, function()
        M.goto_hunk(bufnr, dir * vim.v.count1)
      end, {
        buffer = bufnr,
        nowait = true,
        silent = true,
        desc = 'Guit: ' .. keymaps.actions[action].desc,
      })
    end
  end
end

local function remove_maps(bufnr, rec)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  for action in pairs(NAV_ACTIONS) do
    local lhs = keymaps.key_for(action)
    if lhs then
      pcall(vim.keymap.del, 'n', lhs, { buffer = bufnr })
      local saved = rec.saved_maps and rec.saved_maps[lhs]
      if saved then
        vim.api.nvim_buf_call(bufnr, function()
          pcall(vim.fn.mapset, 'n', false, saved)
        end)
      end
    end
  end
end

---------------------------------------------------------------------------
-- Inline and split are one or the other
---------------------------------------------------------------------------

local function diffoff(winid)
  vim.api.nvim_win_call(winid, function()
    vim.cmd('diffoff')
  end)
end

--- Takes a buffer out of a side-by-side diff, for the inline one to replace
--- it. Vim diffs every 'diff' window of a tab page with every other, so the
--- other 'diff' windows in the tab of `winid` are the sides it was compared
--- against: they are closed, and `winid` itself leaves 'diff'. A side that
--- cannot be closed -- the last window, a modified buffer under 'nohidden'
--- -- merely stops diffing. Windows in other tab pages showing the buffer
--- stop diffing too, without anything being closed.
---@param bufnr integer
---@param winid integer|nil the window the overlay is shown in
function M.leave_split(bufnr, winid)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if not (winid and vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr) then
    winid = vim.fn.bufwinid(bufnr)
  end

  if winid ~= -1 and vim.wo[winid].diff then
    local tabpage = vim.api.nvim_win_get_tabpage(winid)
    for _, other in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
      if other ~= winid and vim.api.nvim_win_is_valid(other) and vim.wo[other].diff then
        if not pcall(vim.api.nvim_win_close, other, false) and vim.api.nvim_win_is_valid(other) then
          diffoff(other)
        end
      end
    end
    diffoff(winid)
  end

  for _, other in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.wo[other].diff then
      diffoff(other)
    end
  end
end

-- The other direction: a buffer entering a split diff -- ds in a pane,
-- fugitive's own dd and ds, a plain :diffthis -- loses its overlay. The
-- option is set with the window current, so the buffer is the current one.
vim.api.nvim_create_autocmd('OptionSet', {
  group = vim.api.nvim_create_augroup('GuitInlineDiff', { clear = true }),
  pattern = 'diff',
  callback = function()
    local new = vim.v.option_new
    if new == true or new == 1 or new == '1' then
      M.detach(vim.api.nvim_get_current_buf())
    end
  end,
})

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

--- Draws the old side over a buffer and keeps the drawing current as the
--- buffer changes.
---
--- Re-attaching to a buffer that already has an overlay replaces it. A
--- buffer in a side-by-side diff leaves it first, see leave_split.
---@param bufnr integer
---@param opts table {
---   old_lines: string[]       the old side; empty means everything was added
---   all_deleted: boolean      the file no longer exists: mark every line removed
---   owner: table|nil          the pane that opened it, for detach_owned
---   label: string|nil         what the buffer is compared against
---   jump_first: boolean       move the cursor to the first hunk
---   winid: integer|nil        window the overlay is shown in and the cursor move applies to
--- }
---@return integer hunk_count
function M.attach(bufnr, opts)
  opts = opts or {}
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return 0
  end
  M.leave_split(bufnr, opts.winid)
  -- Panes define the groups when they open, but :Guit inline and di in a
  -- fugitive buffer reach here without any pane ever having opened.
  highlights.setup()

  local previous = attached[bufnr]
  if previous then
    -- Keep the maps; only the content changes.
    previous.pending = (previous.pending or 0) + 1
  end

  local rec = {
    old_lines = opts.old_lines or {},
    all_deleted = opts.all_deleted or false,
    owner = opts.owner,
    label = opts.label,
    hunks = {},
    rows = {},
    saved_maps = previous and previous.saved_maps or nil,
  }
  attached[bufnr] = rec
  vim.b[bufnr].guit_inline_diff = opts.label or true

  if not previous then
    install_maps(bufnr, rec)
  end
  if not listening[bufnr] then
    listening[bufnr] = true
    -- The listener outlives the overlay: with nothing attached it simply
    -- does nothing, and the next attach reuses it rather than adding one.
    local function changed()
      local current = attached[bufnr]
      if current then
        schedule_render(bufnr, current)
      end
    end
    vim.api.nvim_buf_attach(bufnr, false, {
      on_lines = changed,
      on_reload = changed,
      on_detach = function()
        listening[bufnr] = nil
        attached[bufnr] = nil
        requests[bufnr] = nil
      end,
    })
  end

  render(bufnr, rec)

  if opts.jump_first and #rec.hunks > 0 then
    local winid = opts.winid
    if not (winid and vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr) then
      winid = vim.fn.bufwinid(bufnr)
    end
    if winid ~= -1 then
      local line = math.min(anchor_line(rec.hunks[1]), vim.api.nvim_buf_line_count(bufnr))
      pcall(vim.api.nvim_win_set_cursor, winid, { line, 0 })
    end
  end

  return #rec.hunks
end

--- Removes the overlay and everything it installed.
function M.detach(bufnr)
  -- Taking the overlay down also cancels one still on its way: a git show
  -- that returns after this must not put it back.
  M.begin_request(bufnr)
  local rec = attached[bufnr]
  if not rec then
    return false
  end
  attached[bufnr] = nil
  rec.pending = (rec.pending or 0) + 1
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
    remove_maps(bufnr, rec)
    vim.b[bufnr].guit_inline_diff = nil
  end
  return true
end

--- Removes every overlay a pane opened. Called when the pane previews
--- something else or closes, so a working tree buffer the user keeps open is
--- not left looking like a diff.
function M.detach_owned(owner)
  if not owner then
    return
  end
  -- Overlays the pane asked for but has not received yet are cancelled too,
  -- see guit.ui.diff; they are not in `attached` and cannot be found here.
  owner.inline_generation = (owner.inline_generation or 0) + 1
  for bufnr, rec in pairs(attached) do
    if rec.owner == owner then
      M.detach(bufnr)
    end
  end
end

--- Registers a new request to attach to a buffer and returns its token.
--- Every later request, and every detach, invalidates it.
---@param bufnr integer
---@return integer token
function M.begin_request(bufnr)
  requests[bufnr] = (requests[bufnr] or 0) + 1
  return requests[bufnr]
end

--- Whether a request is still the latest for its buffer.
---@param bufnr integer
---@param token integer
---@return boolean
function M.request_is_current(bufnr, token)
  return requests[bufnr] == token
end

function M.is_attached(bufnr)
  return attached[bufnr] ~= nil
end

--- The current hunks, for tests and statuslines.
function M.hunks_of(bufnr)
  local rec = attached[bufnr]
  return rec and rec.hunks or nil
end

--- Moves the cursor `count` hunks forward (positive) or back (negative) in
--- the window showing the buffer. Does not wrap, like Vim's own ]c.
---@param bufnr integer
---@param count integer
---@return boolean moved
function M.goto_hunk(bufnr, count)
  local rec = attached[bufnr]
  if not rec or #rec.hunks == 0 or count == 0 then
    return false
  end
  local winid = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(winid) ~= bufnr then
    winid = vim.fn.bufwinid(bufnr)
    if winid == -1 then
      return false
    end
  end

  local lines = {}
  for _, hunk in ipairs(rec.hunks) do
    lines[#lines + 1] = anchor_line(hunk)
  end
  table.sort(lines)

  local cursor = vim.api.nvim_win_get_cursor(winid)[1]
  local index
  if count > 0 then
    for i, line in ipairs(lines) do
      if line > cursor then
        index = i + count - 1
        break
      end
    end
  else
    for i = #lines, 1, -1 do
      if lines[i] < cursor then
        index = i + count + 1
        break
      end
    end
  end

  if not index or index < 1 or index > #lines then
    vim.notify('guit.nvim: no more hunks', vim.log.levels.INFO)
    return false
  end

  local target = math.min(lines[index], vim.api.nvim_buf_line_count(bufnr))
  vim.api.nvim_win_set_cursor(winid, { target, 0 })
  return true
end

return M
