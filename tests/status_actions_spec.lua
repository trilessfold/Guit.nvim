-- The working tree keys of :Guit status, driven through the pane itself
-- against a real repository: the git commands are the easy part, choosing
-- which paths to hand them is where the bugs were.
local status_buffer = require('guit.ui.status_buffer')

describe('Guit status working tree actions', function()
  local repo, real_confirm

  local function git(...)
    return vim.system({ 'git', ... }, { cwd = repo, text = true }):wait()
  end

  local function porcelain()
    local out = (git('status', '--porcelain', '-z').stdout or '')
    return (out:gsub('%z$', ''):gsub('%z', ' | '))
  end

  -- Puts the cursor on the first pane line mentioning `needle`, under the
  -- given section heading.
  local function goto_line(section, needle)
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local in_section = false
    for i, line in ipairs(lines) do
      if line:find(section .. '/', 1, true) then
        in_section = true
      elseif in_section and line:find(needle, 1, true) then
        vim.api.nvim_win_set_cursor(0, { i, 0 })
        return true
      end
    end
    return false
  end

  -- A previous pane leaves its window with 'winfixbuf'; free every window
  -- before opening another one.
  local function reset_windows()
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      vim.wo[winid].winfixbuf = false
    end
    vim.cmd('silent! only!')
  end

  local function open()
    reset_windows()
    vim.cmd('enew')
    status_buffer.open({ cwd = repo })
    vim.wait(5000, function()
      return vim.bo.filetype == 'guitstatus' and #vim.api.nvim_buf_get_lines(0, 0, -1, false) > 1
    end)
  end

  -- Presses a key and waits for the pane to redraw, which it does once the
  -- git command behind the key has finished. Polling `git status` instead
  -- would race the plugin's own command for .git/index.lock.
  local function press(key)
    local before = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
    vim.api.nvim_feedkeys(key, 'x', false)
    vim.wait(5000, function()
      return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n') ~= before
    end, 50)
  end

  before_each(function()
    repo = vim.fn.tempname()
    vim.fn.mkdir(repo, 'p')
    git('init', '-q', '-b', 'main')
    git('config', 'user.email', 't@t')
    git('config', 'user.name', 'T')
    vim.fn.writefile({ 'one' }, repo .. '/old.txt')
    git('add', 'old.txt')
    git('commit', '-qm', 'initial')
    real_confirm = vim.fn.confirm
  end)

  after_each(function()
    vim.fn.confirm = real_confirm
    reset_windows()
    vim.cmd('silent! %bwipeout!')
    vim.fn.delete(repo, 'rf')
  end)

  it('unstages both halves of a rename', function()
    git('mv', 'old.txt', 'new.txt')
    -- -z lists the new path first, then the old one.
    assert.equals('R  new.txt | old.txt', porcelain())
    open()
    assert.is_true(goto_line('Staged', 'new.txt'), 'rename line not found in pane')

    press('u')

    -- old.txt is back in the index (HEAD has it) but not on disk, so an
    -- unstaged deletion remains; resetting new.txt alone would have left the
    -- deletion staged instead.
    assert.equals(' D old.txt | ?? new.txt', porcelain())
  end)

  it('discards both halves of a rename', function()
    git('mv', 'old.txt', 'new.txt')
    open()
    assert.is_true(goto_line('Staged', 'new.txt'))
    vim.fn.confirm = function() return 1 end

    press('X')

    assert.equals('', porcelain())
    assert.same({ 'one' }, vim.fn.readfile(repo .. '/old.txt'))
  end)

  it('resets a conflicted file', function()
    git('checkout', '-qb', 'other')
    vim.fn.writefile({ 'theirs' }, repo .. '/old.txt')
    git('commit', '-qam', 'theirs')
    git('checkout', '-q', 'main')
    vim.fn.writefile({ 'ours' }, repo .. '/old.txt')
    git('commit', '-qam', 'ours')
    git('merge', 'other')
    assert.equals('UU old.txt', porcelain())
    open()
    assert.is_true(goto_line('Conflicts', 'old.txt'), 'conflict line not found in pane')
    vim.fn.confirm = function() return 1 end

    press('X')

    assert.equals('', porcelain())
    assert.same({ 'ours' }, vim.fn.readfile(repo .. '/old.txt'))
  end)
end)
