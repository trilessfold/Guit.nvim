local config = require('guit.config')
local inline_diff = require('guit.ui.inline_diff')

local NS = vim.api.nvim_create_namespace('guit-inline-diff')

local function scratch(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  return bufnr
end

local function marks(bufnr)
  return vim.api.nvim_buf_get_extmarks(bufnr, NS, 0, -1, { details = true })
end

-- Line backgrounds are range highlights spanning the line with hl_eol, not
-- line_hl_group marks: those would paint over the word highlights.
local function line_groups(bufnr)
  local out = {}
  for _, mark in ipairs(marks(bufnr)) do
    if mark[4].hl_eol then
      out[mark[2] + 1] = mark[4].hl_group
    end
  end
  return out
end

local function virt_lines(bufnr)
  local out = {}
  for _, mark in ipairs(marks(bufnr)) do
    if mark[4].virt_lines then
      for _, vl in ipairs(mark[4].virt_lines) do
        local text = ''
        for _, chunk in ipairs(vl) do
          text = text .. chunk[1]
        end
        out[#out + 1] = { row = mark[2], above = mark[4].virt_lines_above or false, text = vim.trim(text) }
      end
    end
  end
  return out
end

describe('inline diff hunks', function()
  it('reports an added, a removed and a changed block', function()
    local hunks = inline_diff.hunks(
      { 'a', 'b', 'c', 'd' },
      { 'a', 'B', 'c', 'd', 'e' })
    assert.equals(2, #hunks)
    assert.same({ 'b' }, hunks[1].removed)
    assert.equals(2, hunks[1].new_start)
    assert.equals(1, hunks[1].new_count)
    assert.equals(0, hunks[2].old_count)
    assert.equals(5, hunks[2].new_start)
  end)

  it('anchors a deletion at the top to line zero', function()
    local hunks = inline_diff.hunks({ 'gone', 'a' }, { 'a' })
    assert.equals(1, #hunks)
    assert.equals(0, hunks[1].new_start)
    assert.equals(0, hunks[1].new_count)
  end)

  it('is empty for identical content', function()
    assert.same({}, inline_diff.hunks({ 'a', 'b' }, { 'a', 'b' }))
  end)
end)

describe('inline diff hunks follow the user\'s diffopt', function()
  -- Guit used to hardcode algorithm:histogram, indent-heuristic and
  -- linematch:60 regardless of the user's own 'diffopt', so the inline diff
  -- grouped hunks differently from :diffthis and Gdiffsplit. vim.diff() is
  -- swapped for a spy that records the options it was called with -- an
  -- actual algorithm-dependent example would work too, but would be fragile
  -- across Neovim versions, and this pins the real point: what reaches
  -- vim.diff().
  local original_diffopt, real_diff, captured

  before_each(function()
    original_diffopt = vim.o.diffopt
    real_diff = vim.diff
    vim.diff = function(a, b, opts)
      captured = opts
      return real_diff(a, b, opts)
    end
  end)

  after_each(function()
    vim.o.diffopt = original_diffopt
    vim.diff = real_diff
  end)

  it('passes the configured algorithm, indent-heuristic and linematch through', function()
    vim.o.diffopt = 'internal,filler,closeoff,algorithm:patience,indent-heuristic,linematch:80'
    inline_diff.hunks({ 'a', 'b' }, { 'a', 'B' })
    assert.equals('patience', captured.algorithm)
    assert.is_true(captured.indent_heuristic)
    assert.equals(80, captured.linematch)
  end)

  it('does not force any of them when diffopt sets none', function()
    vim.o.diffopt = 'internal,filler,closeoff,inline:simple'
    inline_diff.hunks({ 'a', 'b' }, { 'a', 'B' })
    assert.is_nil(captured.algorithm)
    assert.is_nil(captured.indent_heuristic)
    assert.is_nil(captured.linematch)
  end)

  it('maps the whitespace-handling flags', function()
    vim.o.diffopt = 'internal,filler,iwhiteall,iwhiteeol,iwhite,iblank'
    inline_diff.hunks({ 'a' }, { 'a ' })
    assert.is_true(captured.ignore_whitespace)
    assert.is_true(captured.ignore_whitespace_change_at_eol)
    assert.is_true(captured.ignore_whitespace_change)
    assert.is_true(captured.ignore_blank_lines)
  end)

  it('still returns hunks when vim.diff rejects the configured linematch', function()
    vim.o.diffopt = 'internal,filler,linematch:60'
    vim.diff = function(a, b, opts)
      captured = opts
      if opts.linematch then
        error('linematch not supported')
      end
      return real_diff(a, b, opts)
    end
    local hunks = inline_diff.hunks({ 'a', 'b' }, { 'a', 'B' })
    assert.equals(1, #hunks)
    assert.equals(nil, captured.linematch)
  end)
end)

describe('inline diff word ranges', function()
  it('finds the word that changed', function()
    local old_ranges, new_ranges = inline_diff.word_ranges(
      'local count = 1',
      'local total = 1')
    assert.same({ { 6, 11 } }, old_ranges)
    assert.same({ { 6, 11 } }, new_ranges)
  end)

  it('gives up when almost everything differs', function()
    local old_ranges = inline_diff.word_ranges('one two three', 'alpha beta gamma delta')
    assert.is_nil(old_ranges)
  end)

  it('keeps multibyte words whole', function()
    local _, new_ranges = inline_diff.word_ranges('x = "привет"', 'x = "пока"')
    assert.equals(1, #new_ranges)
    -- The shared leading "п" is trimmed, on a character boundary.
    assert.equals('ока', ('x = "пока"'):sub(new_ranges[1][1] + 1, new_ranges[1][2]))
  end)
end)

describe('inline diff overlay', function()
  after_each(function()
    config.setup({})
  end)

  it('paints added and changed lines green and draws removed ones as virtual text', function()
    local bufnr = scratch({ 'a', 'B', 'c', 'd', 'e' })
    local count = inline_diff.attach(bufnr, { old_lines = { 'a', 'b', 'c', 'd' } })
    assert.equals(2, count)

    local groups = line_groups(bufnr)
    assert.equals('GuitDiffAdd', groups[2])
    assert.equals('GuitDiffAdd', groups[5])

    local vls = virt_lines(bufnr)
    assert.equals(1, #vls)
    assert.equals('b', vls[1].text)
    assert.equals(1, vls[1].row)
    assert.is_true(vls[1].above)
  end)

  it('hangs a pure deletion below the line it followed', function()
    local bufnr = scratch({ 'a', 'c' })
    inline_diff.attach(bufnr, { old_lines = { 'a', 'b', 'c' } })
    local vls = virt_lines(bufnr)
    assert.equals(1, #vls)
    assert.equals(0, vls[1].row)
    assert.is_false(vls[1].above)
  end)

  it('expands tabs in removed lines to the buffer tabstop', function()
    local bufnr = scratch({ 'x' })
    vim.bo[bufnr].tabstop = 4
    inline_diff.attach(bufnr, { old_lines = { '\tindented', 'x' } })
    local vls = virt_lines(bufnr)
    local raw = ''
    for _, chunk in ipairs(marks(bufnr)[1][4].virt_lines[1]) do
      raw = raw .. chunk[1]
    end
    assert.is_nil(raw:find('\t', 1, true))
    assert.equals('    indented', raw:sub(1, 12))
    assert.equals(1, #vls)
  end)

  it('marks every line removed for a deleted file', function()
    local bufnr = scratch({ 'one', 'two' })
    inline_diff.attach(bufnr, { all_deleted = true })
    local groups = line_groups(bufnr)
    assert.equals('GuitDiffDelete', groups[1])
    assert.equals('GuitDiffDelete', groups[2])
  end)

  it('marks the characters that differ green on the new line and red on the old one', function()
    local bufnr = scratch({ 'local total = 1' })
    inline_diff.attach(bufnr, { old_lines = { 'local count = 1' } })
    local found = false
    for _, mark in ipairs(marks(bufnr)) do
      if mark[4].hl_group == 'GuitDiffAddText' then
        found = true
        assert.equals(6, mark[3])
        assert.equals(11, mark[4].end_col)
      end
    end
    assert.is_true(found)

    local removed = {}
    for _, mark in ipairs(marks(bufnr)) do
      for _, chunk in ipairs((mark[4].virt_lines or {})[1] or {}) do
        removed[#removed + 1] = chunk
      end
    end
    assert.same({ 'local ', 'GuitDiffDelete' }, removed[1])
    assert.same({ 'count', 'GuitDiffDeleteText' }, removed[2])
  end)

  it('leaves signs out when configured off', function()
    config.setup({ diff = { signs = false } })
    local bufnr = scratch({ 'a', 'b' })
    inline_diff.attach(bufnr, { old_lines = { 'a' } })
    for _, mark in ipairs(marks(bufnr)) do
      assert.is_nil(mark[4].sign_text)
    end
  end)

  it('detach clears everything it drew', function()
    local bufnr = scratch({ 'a', 'b' })
    inline_diff.attach(bufnr, { old_lines = { 'a' } })
    assert.is_true(inline_diff.is_attached(bufnr))
    inline_diff.detach(bufnr)
    assert.is_false(inline_diff.is_attached(bufnr))
    assert.same({}, marks(bufnr))
    assert.is_nil(vim.b[bufnr].guit_inline_diff)
  end)

  it('detach_owned only takes down the owner\'s overlays', function()
    local mine, theirs = scratch({ 'a' }), scratch({ 'a' })
    local owner = {}
    inline_diff.attach(mine, { old_lines = {}, owner = owner })
    inline_diff.attach(theirs, { old_lines = {} })
    inline_diff.detach_owned(owner)
    assert.is_false(inline_diff.is_attached(mine))
    assert.is_true(inline_diff.is_attached(theirs))
  end)

  it('redraws after the buffer is edited', function()
    local bufnr = scratch({ 'a', 'b' })
    inline_diff.attach(bufnr, { old_lines = { 'a', 'b' } })
    assert.equals(0, #inline_diff.hunks_of(bufnr))

    vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { 'B' })
    vim.wait(500, function()
      return #inline_diff.hunks_of(bufnr) == 1
    end)
    assert.equals(1, #inline_diff.hunks_of(bufnr))
    assert.equals('GuitDiffAdd', line_groups(bufnr)[2])
  end)
end)

describe('inline diff colours', function()
  local GROUPS = { 'GuitDiffAdd', 'GuitDiffAddText', 'GuitDiffDelete', 'GuitDiffDeleteText' }

  after_each(function()
    config.setup({})
    vim.cmd('highlight clear')
  end)

  local function removed_chunks(bufnr)
    for _, mark in ipairs(marks(bufnr)) do
      if mark[4].virt_lines then
        return mark[4].virt_lines[1]
      end
    end
  end

  it('only paints backgrounds, so the code keeps its own colours', function()
    -- Neovim's own DiffAdd sets a foreground and its DiffDelete no background.
    vim.api.nvim_set_hl(0, 'DiffAdd', { bg = 0x003300, fg = 0xffffff })
    vim.api.nvim_set_hl(0, 'DiffDelete', { fg = 0xff0000, bold = true })
    inline_diff.attach(scratch({ 'a' }), { old_lines = { 'b' } })

    for _, name in ipairs(GROUPS) do
      local group = vim.api.nvim_get_hl(0, { name = name })
      assert.is_not_nil(group.bg, name .. ' has no background')
      assert.is_nil(group.fg, name .. ' overrides the text colour')
      assert.is_nil(group.bold, name .. ' overrides the text style')
    end
    assert.equals(0x003300, vim.api.nvim_get_hl(0, { name = 'GuitDiffAdd' }).bg)
  end)

  it('is green and red whatever the scheme does with its diff groups', function()
    local function channels(color)
      return bit.rshift(color, 16), bit.band(bit.rshift(color, 8), 0xff), bit.band(color, 0xff)
    end
    -- gruvbox-style: the colour in fg, shown through 'reverse'.
    vim.api.nvim_set_hl(0, 'Normal', { bg = 0x1d2021, fg = 0xebdbb2 })
    vim.api.nvim_set_hl(0, 'DiffAdd', { fg = 0xb8bb26, reverse = true })
    vim.api.nvim_set_hl(0, 'DiffDelete', {})
    inline_diff.attach(scratch({ 'a' }), { old_lines = { 'b' } })

    for _, name in ipairs({ 'GuitDiffAdd', 'GuitDiffAddText' }) do
      local r, g, b = channels(vim.api.nvim_get_hl(0, { name = name }).bg)
      assert.is_true(g > r and g > b, name .. ' is not green')
    end
    for _, name in ipairs({ 'GuitDiffDelete', 'GuitDiffDeleteText' }) do
      local r, g, b = channels(vim.api.nvim_get_hl(0, { name = name }).bg)
      assert.is_true(r > g and r > b, name .. ' is not red')
    end
  end)

  it('draws removed lines in the syntax colours of the old side', function()
    local bufnr = scratch({ 'return x' })
    vim.bo[bufnr].filetype = 'lua'
    inline_diff.attach(bufnr, { old_lines = { 'local x = "a\\n"', 'return x' } })

    local by_text = {}
    for _, chunk in ipairs(removed_chunks(bufnr)) do
      by_text[chunk[1]] = chunk[2]
    end
    -- The syntax group first, the red background stacked over it.
    assert.same({ '@keyword.lua', 'GuitDiffDelete' }, by_text['local'])
    assert.same({ '@variable.lua', 'GuitDiffDelete' }, by_text['x'])
    assert.equals('GuitDiffDelete', by_text[' '])
  end)

  it('parses the old side as a whole, not line by line', function()
    -- The second line alone is not a string; inside the old file it is.
    local bufnr = scratch({ 'x' })
    vim.bo[bufnr].filetype = 'lua'
    inline_diff.attach(bufnr, { old_lines = { 'local s = [[', 'plain words', ']]', 'x' } })

    local vls
    for _, mark in ipairs(marks(bufnr)) do
      vls = mark[4].virt_lines or vls
    end
    local groups = vls[2][1][2]
    assert.equals('plain words', vls[2][1][1])
    assert.equals('@string.lua', groups[1])
  end)

  it('uses the stronger red under syntax colours too', function()
    local bufnr = scratch({ 'local total = 1' })
    vim.bo[bufnr].filetype = 'lua'
    inline_diff.attach(bufnr, { old_lines = { 'local count = 1' } })
    local by_text = {}
    for _, chunk in ipairs(removed_chunks(bufnr)) do
      by_text[chunk[1]] = chunk[2]
    end
    assert.same({ '@variable.lua', 'GuitDiffDeleteText' }, by_text['count'])
  end)

  it('draws removed lines plain without a parser or with syntax off', function()
    local unknown = scratch({ 'x' })
    vim.bo[unknown].filetype = 'no-such-language'
    inline_diff.attach(unknown, { old_lines = { 'local y', 'x' } })
    assert.equals('GuitDiffDelete', removed_chunks(unknown)[1][2])

    config.setup({ diff = { syntax = false } })
    local off = scratch({ 'x' })
    vim.bo[off].filetype = 'lua'
    inline_diff.attach(off, { old_lines = { 'local y', 'x' } })
    assert.same({ 'local y', 'GuitDiffDelete' }, removed_chunks(off)[1])
  end)
end)

describe('inline and side-by-side diffs are one or the other', function()
  local function diff_windows()
    local out = {}
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.wo[winid].diff then
        out[#out + 1] = winid
      end
    end
    return out
  end

  before_each(function()
    vim.cmd('silent! diffoff!')
    vim.cmd('only!')
  end)

  it('closes the sides a buffer was diffed against when the overlay goes on', function()
    local new, old = scratch({ 'a', 'B' }), scratch({ 'a', 'b' })
    vim.api.nvim_win_set_buf(0, new)
    local winid = vim.api.nvim_get_current_win()
    vim.cmd('diffthis')
    vim.cmd('vsplit')
    vim.api.nvim_win_set_buf(0, old)
    vim.cmd('diffthis')
    vim.api.nvim_set_current_win(winid)

    inline_diff.attach(new, { old_lines = { 'a', 'b' }, winid = winid })

    assert.same({ winid }, vim.api.nvim_tabpage_list_wins(0))
    assert.is_false(vim.wo[winid].diff)
    assert.is_true(inline_diff.is_attached(new))
  end)

  it('keeps the overlay window even when another window shows the same buffer', function()
    -- fugitive's ds from :Git leaves the file in one window and the object in
    -- another; di may reuse either.
    local new, old = scratch({ 'a', 'B' }), scratch({ 'a', 'b' })
    vim.api.nvim_win_set_buf(0, new)
    vim.cmd('diffthis')
    vim.cmd('vsplit')
    local winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(0, old)
    vim.cmd('diffthis')
    vim.api.nvim_win_set_buf(winid, new)

    inline_diff.attach(new, { old_lines = { 'a', 'b' }, winid = winid })

    assert.same({ winid }, vim.api.nvim_tabpage_list_wins(0))
    assert.same({}, diff_windows())
  end)

  it('leaves windows in other tab pages open, only no longer diffing', function()
    local new, old = scratch({ 'a', 'B' }), scratch({ 'a', 'b' })
    vim.api.nvim_win_set_buf(0, new)
    local winid = vim.api.nvim_get_current_win()
    vim.cmd('diffthis')
    vim.cmd('tab split')
    local other_tab_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(0, old)
    vim.cmd('diffthis | vsplit')
    vim.api.nvim_win_set_buf(0, new)
    vim.cmd('diffthis')
    vim.cmd('tabprevious')

    inline_diff.attach(new, { old_lines = { 'a', 'b' }, winid = winid })

    -- The window in the other tab page is left open, just no longer diffing.
    assert.is_true(vim.api.nvim_win_is_valid(other_tab_win))
    for _, w in ipairs(vim.fn.win_findbuf(new)) do
      assert.is_false(vim.wo[w].diff)
    end
    vim.cmd('silent! tabonly!')
  end)

  it('takes the overlay down when the buffer enters a side-by-side diff', function()
    -- That is an OptionSet autocmd, which Vim only fires once it has started.
    -- The test runner runs every spec from -c, before that, so the scenario
    -- runs in a child Neovim executing a script, which has.
    local root = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, 'S').source:sub(2)), ':p:h:h')
    local script = vim.fn.tempname() .. '.lua'
    vim.fn.writefile(vim.split(([[
      vim.opt.runtimepath:prepend(%q)
      local inline_diff = require('guit.ui.inline_diff')
      local ns = vim.api.nvim_create_namespace('guit-inline-diff')
      local bufnr = vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'a', 'B' })
      inline_diff.attach(bufnr, { old_lines = { 'a', 'b' } })
      local before = inline_diff.is_attached(bufnr)
      vim.cmd('diffthis')
      io.stdout:write(vim.json.encode({
        before = before,
        after = inline_diff.is_attached(bufnr),
        marks = #vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {}),
        mapped = next(vim.fn.maparg(']c', 'n', false, true)) ~= nil,
      }))
    ]]):format(root), '\n'), script)

    local result = vim.system({ vim.v.progpath, '--headless', '--clean', '-l', script }, { text = true }):wait()
    vim.fn.delete(script)
    assert.equals(0, result.code, result.stderr)
    assert.same({ before = true, after = false, marks = 0, mapped = false }, vim.json.decode(result.stdout))
  end)

  it('leaves the overlay alone when a buffer leaves a diff', function()
    local bufnr = scratch({ 'a', 'B' })
    vim.api.nvim_win_set_buf(0, bufnr)
    inline_diff.attach(bufnr, { old_lines = { 'a', 'b' } })
    vim.cmd('diffoff')
    assert.is_true(inline_diff.is_attached(bufnr))
  end)

  it('swaps di and ds in a pane without leaving the other shape behind', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    vim.fn.writefile({ 'one', 'two' }, dir .. '/file.txt')
    vim.o.hidden = true
    vim.cmd('enew')
    local pane = vim.api.nvim_get_current_win()
    vim.cmd('rightbelow split')
    local target = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(pane)
    local state = { winid = pane, target_winid = target }
    -- An added file: neither shape needs fugitive for it.
    local spec = { cwd = dir, right = { path = 'file.txt' } }
    local diff = require('guit.ui.diff')
    local function shown()
      return vim.api.nvim_win_get_buf(state.target_winid)
    end

    assert.is_true(diff.open(state, spec, { mode = 'inline' }))
    assert.is_true(inline_diff.is_attached(shown()))
    assert.equals(2, #vim.api.nvim_tabpage_list_wins(0))

    assert.is_true(diff.open(state, spec, { mode = 'split' }))
    assert.is_false(inline_diff.is_attached(shown()))
    assert.equals(3, #vim.api.nvim_tabpage_list_wins(0))
    assert.equals(2, #diff_windows())

    assert.is_true(diff.open(state, spec, { mode = 'inline' }))
    assert.is_true(inline_diff.is_attached(shown()))
    assert.equals(2, #vim.api.nvim_tabpage_list_wins(0))
    assert.same({}, diff_windows())

    vim.fn.delete(dir, 'rf')
  end)
end)

describe('inline diffs still on their way', function()
  local dir, pane, target, state

  -- A repository with a file in the index, so an unstaged-style spec (index
  -- against working tree) needs no fugitive and does fetch the old side from
  -- git asynchronously.
  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local function git(...)
      return vim.system({ 'git', ... }, { cwd = dir, text = true }):wait()
    end
    git('init', '-q', '-b', 'main')
    vim.fn.writefile({ 'one', 'two' }, dir .. '/file.txt')
    vim.fn.writefile({ 'other' }, dir .. '/other.txt')
    git('add', 'file.txt', 'other.txt')
    vim.fn.writefile({ 'one', 'TWO' }, dir .. '/file.txt')

    vim.o.hidden = true
    vim.cmd('silent! only!')
    vim.cmd('enew')
    pane = vim.api.nvim_get_current_win()
    vim.cmd('rightbelow split')
    target = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(pane)
    state = { winid = pane, target_winid = target }
  end)

  after_each(function()
    vim.cmd('silent! %bwipeout!')
    vim.fn.delete(dir, 'rf')
  end)

  local spec = function()
    return { cwd = dir, left = { rev = ':0', path = 'file.txt' }, right = { path = 'file.txt' } }
  end

  local function settle()
    vim.wait(1000, function() return false end, 50)
  end

  it('attaches once git show returns', function()
    local diff = require('guit.ui.diff')
    assert.is_true(diff.open(state, spec(), { mode = 'inline' }))
    local bufnr = vim.api.nvim_win_get_buf(target)
    assert.is_false(inline_diff.is_attached(bufnr))
    vim.wait(5000, function() return inline_diff.is_attached(bufnr) end)
    assert.is_true(inline_diff.is_attached(bufnr))
  end)

  it('is dropped when the pane opens something else first', function()
    local diff = require('guit.ui.diff')
    diff.open(state, spec(), { mode = 'inline' })
    local bufnr = vim.api.nvim_win_get_buf(target)
    diff.open_object(state, dir, { path = 'other.txt' })
    settle()
    assert.is_false(inline_diff.is_attached(bufnr))
  end)

  it('is dropped when the pane switches to a split diff first', function()
    local diff = require('guit.ui.diff')
    diff.open(state, spec(), { mode = 'inline' })
    local bufnr = vim.api.nvim_win_get_buf(target)
    -- Without fugitive the split cannot open, but asking for it must still
    -- cancel the inline one: a late attach would close the split's sides.
    diff.open(state, spec(), { mode = 'split' })
    settle()
    assert.is_false(inline_diff.is_attached(bufnr))
  end)

  it('is dropped when the pane closes first', function()
    local diff = require('guit.ui.diff')
    diff.open(state, spec(), { mode = 'inline' })
    local bufnr = vim.api.nvim_win_get_buf(target)
    inline_diff.detach_owned(state)
    settle()
    assert.is_false(inline_diff.is_attached(bufnr))
  end)

  it('is dropped by a detach of the buffer in the meantime', function()
    local bufnr = scratch({ 'a' })
    local token = inline_diff.begin_request(bufnr)
    inline_diff.detach(bufnr)
    assert.is_false(inline_diff.request_is_current(bufnr, token))
  end)

  it('yields to a newer request for the same buffer', function()
    local bufnr = scratch({ 'a' })
    local older = inline_diff.begin_request(bufnr)
    local newer = inline_diff.begin_request(bufnr)
    assert.is_false(inline_diff.request_is_current(bufnr, older))
    assert.is_true(inline_diff.request_is_current(bufnr, newer))
  end)
end)

describe('inline diff signs', function()
  after_each(function()
    config.setup({})
  end)

  local function signs(bufnr)
    local out = {}
    for _, mark in ipairs(marks(bufnr)) do
      if mark[4].sign_text then
        out[mark[2] + 1] = vim.trim(mark[4].sign_text)
      end
    end
    return out
  end

  it('marks a deletion on the line it followed, and one at the top on the first line', function()
    local top = scratch({ 'a', 'b' })
    inline_diff.attach(top, { old_lines = { 'gone', 'a', 'b' } })
    assert.equals('‾', signs(top)[1])

    local middle = scratch({ 'a', 'c' })
    inline_diff.attach(middle, { old_lines = { 'a', 'b', 'c' } })
    assert.equals('_', signs(middle)[1])
    assert.is_nil(signs(middle)[2])
  end)

  it('leaves the sign as the only sign-type mark on its line', function()
    -- A line_hl_group extmark counts as a sign to nvim_buf_get_extmarks with
    -- type = 'sign'. A statuscolumn that shows one sign per line (snacks,
    -- LazyVim) then picks the text-less one and draws a blank.
    local bufnr = scratch({ 'a', 'b' })
    inline_diff.attach(bufnr, { old_lines = { 'a' } })
    local sign_marks = vim.api.nvim_buf_get_extmarks(bufnr, NS, 0, -1, { details = true, type = 'sign' })
    assert.equals(1, #sign_marks)
    assert.equals('+', vim.trim(sign_marks[1][4].sign_text))
    for _, mark in ipairs(marks(bufnr)) do
      assert.is_nil(mark[4].line_hl_group)
    end
  end)

  it('lets a word highlight keep its own background on a highlighted line', function()
    -- The stronger green must show on a green line. line_hl_group would
    -- paint over it.
    vim.o.termguicolors = true
    vim.api.nvim_set_hl(0, 'DiffAdd', { bg = 0x224422 })
    local bufnr = scratch({ 'f(a, b, c)', 'f(a, b, c)' })
    vim.cmd('only!')
    vim.api.nvim_win_set_buf(0, bufnr)
    inline_diff.attach(bufnr, { old_lines = { 'f(a, b)', 'f(a, b, c)' } })
    vim.cmd('redraw')
    -- Same word highlight on a plain line, for the attribute to compare with.
    local probe = vim.api.nvim_create_namespace('probe')
    vim.api.nvim_buf_set_extmark(bufnr, probe, 1, 6, { end_col = 9, hl_group = 'GuitDiffAddText', priority = 30 })
    vim.cmd('redraw')
    -- Byte 7 (1-based) is the inserted ', c' on line 1 and the probe on line 2.
    -- Screen rows, not buffer lines: the removed line above line 1 is
    -- scrolled into view and pushes both down.
    local changed, plain = vim.fn.screenpos(0, 1, 7), vim.fn.screenpos(0, 2, 7)
    local first = vim.fn.screenpos(0, 1, 1).col
    assert.equals(vim.fn.screenattr(plain.row, plain.col), vim.fn.screenattr(changed.row, changed.col))
    assert.are_not.equals(vim.fn.screenattr(changed.row, first), vim.fn.screenattr(changed.row, changed.col))
  end)

  it('shows a changed line with a deletion after it as one sign', function()
    local bufnr = scratch({ 'a', 'foo(x, y)', 'next' })
    inline_diff.attach(bufnr, { old_lines = { 'a', 'foo(x)', '', 'next' } })
    assert.equals('~_', signs(bufnr)[2])
    -- The removed foo(x) sits above the changed line, the removed blank
    -- line below it.
    local vls = virt_lines(bufnr)
    assert.equals(2, #vls)
    assert.same({ row = 1, above = true, text = 'foo(x)' }, vls[1])
    assert.same({ row = 1, above = false, text = '' }, vls[2])
  end)
end)

describe('inline diff word edits', function()
  it('treats a line reduced to nothing as one edit, not a removed line', function()
    local edits = inline_diff.word_edits('        ', '')
    assert.same({ { old = { 0, 8 }, new = { 0, 0 } } }, edits)
    assert.same({ { old = { 0, 0 }, new = { 0, 4 } } }, inline_diff.word_edits('', 'text'))
  end)

  it('narrows a replaced word to the characters that differ, like inline:char', function()
    local edits = inline_diff.word_edits('x = OutAuthentication,', 'x = OutRegistration,')
    assert.equals(1, #edits)
    assert.equals('Authentic', ('x = OutAuthentication,'):sub(edits[1].old[1] + 1, edits[1].old[2]))
    assert.equals('Registr', ('x = OutRegistration,'):sub(edits[1].new[1] + 1, edits[1].new[2]))
  end)

  it('does not split a multibyte character while narrowing', function()
    local edits = inline_diff.word_edits('x = привет;', 'x = привоз;')
    -- п р и в are shared; е -> о, т -> з differ: "ет" vs "оз", 4 bytes each.
    assert.equals('ет', ('x = привет;'):sub(edits[1].old[1] + 1, edits[1].old[2]))
    assert.equals('оз', ('x = привоз;'):sub(edits[1].new[1] + 1, edits[1].new[2]))
  end)

  it('places an insertion at an empty old range', function()
    local edits = inline_diff.word_edits('a b', 'a, b')
    assert.equals(1, #edits)
    assert.same({ 1, 1 }, edits[1].old)
    assert.same({ 1, 2 }, edits[1].new)
  end)
end)

describe('inline diff navigation', function()
  local function show(bufnr)
    vim.cmd('only!')
    vim.api.nvim_win_set_buf(0, bufnr)
    return vim.api.nvim_get_current_win()
  end

  it('jumps to the first hunk on attach when asked', function()
    local bufnr = scratch({ 'a', 'b', 'c', 'D', 'e' })
    local winid = show(bufnr)
    inline_diff.attach(bufnr, { old_lines = { 'a', 'b', 'c', 'd', 'e' }, jump_first = true, winid = winid })
    assert.equals(4, vim.api.nvim_win_get_cursor(winid)[1])
  end)

  it(']c and [c walk the hunks without wrapping', function()
    local bufnr = scratch({ 'A', 'b', 'c', 'D', 'e', 'F' })
    local winid = show(bufnr)
    inline_diff.attach(bufnr, { old_lines = { 'a', 'b', 'c', 'd', 'e', 'f' } })
    vim.api.nvim_win_set_cursor(winid, { 1, 0 })

    assert.is_true(inline_diff.goto_hunk(bufnr, 1))
    assert.equals(4, vim.api.nvim_win_get_cursor(winid)[1])
    assert.is_true(inline_diff.goto_hunk(bufnr, 1))
    assert.equals(6, vim.api.nvim_win_get_cursor(winid)[1])
    assert.is_false(inline_diff.goto_hunk(bufnr, 1))
    assert.equals(6, vim.api.nvim_win_get_cursor(winid)[1])

    assert.is_true(inline_diff.goto_hunk(bufnr, -2))
    assert.equals(1, vim.api.nvim_win_get_cursor(winid)[1])
  end)

  it('maps the keys into the buffer and restores what was there before', function()
    local bufnr = scratch({ 'A', 'b' })
    show(bufnr)
    vim.keymap.set('n', ']c', '<Cmd>echo "theirs"<CR>', { buffer = bufnr })

    inline_diff.attach(bufnr, { old_lines = { 'a', 'b' } })
    local during = vim.fn.maparg(']c', 'n', false, true)
    assert.is_truthy(during.desc and during.desc:find('Guit', 1, true))

    inline_diff.detach(bufnr)
    local after = vim.fn.maparg(']c', 'n', false, true)
    assert.equals('<Cmd>echo "theirs"<CR>', after.rhs)
    assert.equals(1, after.buffer)
  end)

  it('leaves no mapping behind in a buffer that had none', function()
    local bufnr = scratch({ 'A' })
    show(bufnr)
    inline_diff.attach(bufnr, { old_lines = { 'a' } })
    inline_diff.detach(bufnr)
    assert.same({}, vim.fn.maparg('[c', 'n', false, true))
  end)
end)
