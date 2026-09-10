local stage = require('guit.stage')

describe('staging argv', function()
  local real_system, calls

  before_each(function()
    calls = {}
    real_system = vim.system
    vim.system = function(argv, _, cb)
      calls[#calls + 1] = argv
      cb({ code = 0, stdout = '', stderr = '' })
      return { wait = function() end }
    end
  end)

  after_each(function()
    vim.system = real_system
  end)

  -- The last git call made: the mutating one, after any probe such as
  -- discard_staged's check that HEAD exists.
  local function argv_of(fn, paths)
    fn('/repo', paths or { 'a.txt' }, function() end)
    vim.wait(200, function() return #calls > 0 and calls[#calls][2] ~= 'rev-parse' end)
    return calls[#calls]
  end

  it('keeps every path literal, so a file named *.txt is only itself', function()
    local argv = argv_of(stage.discard_worktree, { '*.txt' })
    assert.equals('--literal-pathspecs', argv[2])
  end)

  it('separates paths from options with exactly one --', function()
    local argv = argv_of(stage.stage)
    local separators = 0
    for _, a in ipairs(argv) do
      if a == '--' then
        separators = separators + 1
      end
    end
    assert.equals(1, separators)
    assert.equals('--', argv[#argv - 1])
    assert.equals('a.txt', argv[#argv])
  end)

  it('unstages with reset, which also works before the first commit', function()
    -- git restore --staged fails with "could not resolve HEAD" on an unborn
    -- branch, which is exactly when someone is first staging files.
    local argv = argv_of(stage.unstage)
    assert.same({ 'git', '--literal-pathspecs', 'reset', '-q', 'HEAD', '--', 'a.txt' }, argv)
  end)

  it('passes every path as its own argument', function()
    local argv = argv_of(stage.stage, { 'a b.txt', 'тест.txt', '--evil' })
    assert.equals('a b.txt', argv[#argv - 2])
    assert.equals('тест.txt', argv[#argv - 1])
    -- after -- git reads this as a path, not as an option
    assert.equals('--evil', argv[#argv])
  end)

  it('refuses to run with no paths', function()
    local err
    stage.stage('/repo', {}, function(e) err = e end)
    assert.is_truthy(err)
    assert.equals(0, #calls)
  end)

  it('discards a staged change in both the index and the worktree', function()
    local argv = argv_of(stage.discard_staged)
    assert.same({ 'git', '--literal-pathspecs', 'restore', '--staged', '--worktree', '--', 'a.txt' }, argv)
  end)

  it('resets a conflict in the index as well, which a plain restore refuses', function()
    local argv = argv_of(stage.discard_conflicts)
    assert.same({ 'git', '--literal-pathspecs', 'restore', '--staged', '--worktree', '--', 'a.txt' }, argv)
  end)
end)

describe('staging against a real repository', function()
  local repo

  local function git(...)
    return vim.system({ 'git', ... }, { cwd = repo, text = true }):wait()
  end

  -- -z, like the plugin itself uses: without it git quotes any path holding a
  -- space and the assertion would be about git's display, not about staging.
  local function porcelain()
    local out = (git('status', '--porcelain', '-z').stdout or '')
    return (out:gsub('%z$', ''):gsub('%z', ' | '))
  end

  local function sync(fn, paths)
    local done, error_message = false, nil
    fn(repo, paths, function(err)
      error_message = err
      done = true
    end)
    vim.wait(5000, function() return done end)
    return error_message
  end

  before_each(function()
    repo = vim.fn.tempname()
    vim.fn.mkdir(repo, 'p')
    git('init', '-q', '-b', 'main')
    git('config', 'user.email', 't@t')
    git('config', 'user.name', 'T')
    vim.fn.writefile({ 'one' }, repo .. '/tracked.txt')
    git('add', 'tracked.txt')
    git('commit', '-qm', 'initial')
  end)

  after_each(function()
    vim.fn.delete(repo, 'rf')
  end)

  it('stages and unstages a path containing a space', function()
    vim.fn.writefile({ 'x' }, repo .. '/two words.txt')
    assert.is_nil(sync(stage.stage, { 'two words.txt' }))
    assert.equals('A  two words.txt', porcelain())

    assert.is_nil(sync(stage.unstage, { 'two words.txt' }))
    assert.equals('?? two words.txt', porcelain())
  end)

  it('unstages before the first commit exists', function()
    local empty = vim.fn.tempname()
    vim.fn.mkdir(empty, 'p')
    vim.system({ 'git', 'init', '-q', '-b', 'main' }, { cwd = empty }):wait()
    vim.fn.writefile({ 'x' }, empty .. '/f.txt')
    vim.system({ 'git', 'add', 'f.txt' }, { cwd = empty }):wait()

    local done, err = false, nil
    stage.unstage(empty, { 'f.txt' }, function(e) err = e; done = true end)
    vim.wait(5000, function() return done end)

    assert.is_nil(err)
    local out = vim.system({ 'git', 'status', '--porcelain', '-z' }, { cwd = empty, text = true }):wait()
    assert.equals('?? f.txt', (out.stdout or ''):gsub('%z$', ''))
    vim.fn.delete(empty, 'rf')
  end)

  it('throws away an unstaged change', function()
    vim.fn.writefile({ 'two' }, repo .. '/tracked.txt')
    assert.equals(' M tracked.txt', porcelain())

    assert.is_nil(sync(stage.discard_worktree, { 'tracked.txt' }))
    assert.equals('', porcelain())
    assert.same({ 'one' }, vim.fn.readfile(repo .. '/tracked.txt'))
  end)

  it('does not let a file named like a glob discard its neighbours', function()
    -- git reads pathspecs as globs by default: `*.txt` would match every
    -- .txt file, and the confirmation only ever named one.
    vim.fn.writefile({ 'star' }, repo .. '/*.txt')
    git('add', '*.txt')
    git('commit', '-qm', 'star')
    vim.fn.writefile({ 'two' }, repo .. '/tracked.txt')
    vim.fn.writefile({ 'changed' }, repo .. '/*.txt')

    assert.is_nil(sync(stage.discard_worktree, { '*.txt' }))
    assert.equals(' M tracked.txt', porcelain())
  end)

  it('resets a conflicted file to HEAD', function()
    git('checkout', '-qb', 'other')
    vim.fn.writefile({ 'theirs' }, repo .. '/tracked.txt')
    git('commit', '-qam', 'theirs')
    git('checkout', '-q', 'main')
    vim.fn.writefile({ 'ours' }, repo .. '/tracked.txt')
    git('commit', '-qam', 'ours')
    git('merge', 'other')
    assert.equals('UU tracked.txt', porcelain())

    assert.is_nil(sync(stage.discard_conflicts, { 'tracked.txt' }))
    assert.equals('', porcelain())
    assert.same({ 'ours' }, vim.fn.readfile(repo .. '/tracked.txt'))
  end)

  it('discards a staged file before the first commit exists', function()
    -- No HEAD to restore from: the staged file is all new, so it goes.
    local empty = vim.fn.tempname()
    vim.fn.mkdir(empty, 'p')
    vim.system({ 'git', 'init', '-q', '-b', 'main' }, { cwd = empty }):wait()
    vim.fn.writefile({ 'x' }, empty .. '/f.txt')
    vim.system({ 'git', 'add', 'f.txt' }, { cwd = empty }):wait()

    local done, err = false, nil
    stage.discard_staged(empty, { 'f.txt' }, function(e) err = e; done = true end)
    vim.wait(5000, function() return done end)

    assert.is_nil(err)
    local out = vim.system({ 'git', 'status', '--porcelain', '-z' }, { cwd = empty, text = true }):wait()
    assert.equals('', (out.stdout or ''):gsub('%z$', ''))
    assert.equals(0, vim.fn.filereadable(empty .. '/f.txt'))
    vim.fn.delete(empty, 'rf')
  end)

  it('deletes untracked files and directories', function()
    vim.fn.mkdir(repo .. '/dir', 'p')
    vim.fn.writefile({ 'x' }, repo .. '/dir/f.txt')

    assert.is_nil(sync(stage.delete_untracked, { 'dir/' }))
    assert.equals(0, vim.fn.isdirectory(repo .. '/dir'))
    assert.equals('', porcelain())
  end)
end)
