local config = require('guit.config')
local fugitive_status = require('guit.fugitive_status')

describe('Guit keys in a fugitive blob buffer', function()
  local bufnr

  before_each(function()
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr].modifiable = false
  end)

  after_each(function()
    config.setup({})
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  local function guit_map(lhs)
    return vim.api.nvim_buf_call(bufnr, function()
      local map = vim.fn.maparg(lhs, 'n', false, true)
      return type(map) == 'table' and map.buffer == 1 and (map.desc or ''):find('^Guit') ~= nil
    end)
  end

  it('binds di whatever the diff mode', function()
    config.setup({ diff = { mode = 'split' } })
    fugitive_status.attach_blob(bufnr)
    assert.is_true(guit_map('di'))
  end)

  it('takes over dd when diff.mode is inline, so dd never opens a split', function()
    config.setup({ diff = { mode = 'inline' } })
    fugitive_status.attach_blob(bufnr)
    assert.is_true(guit_map('dd'))
  end)

  it("leaves fugitive's dd alone when diff.mode is split", function()
    config.setup({ diff = { mode = 'split' } })
    fugitive_status.attach_blob(bufnr)
    assert.is_false(guit_map('dd'))
  end)

  it('never maps dd in a buffer that can be edited', function()
    config.setup({ diff = { mode = 'inline' } })
    vim.bo[bufnr].modifiable = true
    fugitive_status.attach_blob(bufnr)
    assert.is_false(guit_map('dd'))
  end)

  it('keeps dd for fugitive when open_diff is disabled', function()
    config.setup({ diff = { mode = 'inline' }, keymaps = { open_diff = false } })
    fugitive_status.attach_blob(bufnr)
    assert.is_false(guit_map('dd'))
    assert.is_true(guit_map('di'))
  end)
end)

-- A :Git status buffer as fugitive renders it, with one hunk expanded.
local STATUS = {
  'Head: main',
  'Help: g?',
  '',
  'Untracked (1)',
  '? notes.txt',
  '',
  'Unstaged (2)',
  'M lua/guit/init.lua',
  '@@ -1,3 +1,4 @@',
  ' local a',
  '+local b',
  ' local c',
  'D gone.lua',
  '',
  'Staged (4)',
  'A new file.lua',
  'R old/name.lua -> new/name.lua',
  'M README.md',
  -- fugitive has no conflicts section: an unmerged file is listed under
  -- both Staged and Unstaged with the single status letter U.
  'U conflict.lua',
  '',
  'Unpushed to origin/main (1)',
  'abc1234 a commit',
}

describe('fugitive status parsing', function()
  it('reads section, status and path from a file line', function()
    assert.same(
      { section = 'unstaged', status = 'M', path = 'lua/guit/init.lua' },
      fugitive_status.entry_at(STATUS, 8))
    assert.same(
      { section = 'staged', status = 'M', path = 'README.md' },
      fugitive_status.entry_at(STATUS, 18))
  end)

  it('keeps a space in a file name', function()
    assert.equals('new file.lua', fugitive_status.entry_at(STATUS, 16).path)
  end)

  it('splits a rename into old and new path', function()
    local entry = fugitive_status.entry_at(STATUS, 17)
    assert.equals('old/name.lua', entry.old_path)
    assert.equals('new/name.lua', entry.path)
  end)

  it('attributes an expanded hunk to the file above it', function()
    for lnum = 9, 12 do
      assert.equals('lua/guit/init.lua', fugitive_status.entry_at(STATUS, lnum).path)
    end
  end)

  it('recognises conflicted and untracked files', function()
    local conflict = fugitive_status.entry_at(STATUS, 19)
    assert.equals('staged', conflict.section)
    assert.equals('U', conflict.status)
    assert.equals('untracked', fugitive_status.entry_at(STATUS, 5).section)
  end)

  it('returns nothing for headings, blanks and commit lines', function()
    for _, lnum in ipairs({ 1, 3, 4, 7, 20, 21, 22 }) do
      assert.is_nil(fugitive_status.entry_at(STATUS, lnum), ('line %d'):format(lnum))
    end
  end)
end)

describe('fugitive status diff spec', function()
  local cwd = '/repo'

  it('compares staged files against HEAD, unstaged against the index', function()
    local staged = fugitive_status.spec_for(cwd, { section = 'staged', status = 'M', path = 'a' })
    assert.same({ rev = 'HEAD', path = 'a' }, staged.left)
    assert.same({ rev = ':0', path = 'a' }, staged.right)

    local unstaged = fugitive_status.spec_for(cwd, { section = 'unstaged', status = 'M', path = 'a' })
    assert.same({ rev = ':0', path = 'a' }, unstaged.left)
    assert.same({ path = 'a' }, unstaged.right)
  end)

  it('uses the old path on the HEAD side of a staged rename', function()
    local spec = fugitive_status.spec_for(cwd, { section = 'staged', status = 'R', path = 'new', old_path = 'old' })
    assert.equals('old', spec.left.path)
    assert.equals('new', spec.right.path)
  end)

  it('drops the side that does not exist for added and deleted files', function()
    assert.is_nil(fugitive_status.spec_for(cwd, { section = 'staged', status = 'A', path = 'a' }).left)
    assert.is_nil(fugitive_status.spec_for(cwd, { section = 'unstaged', status = 'D', path = 'a' }).right)
  end)

  it('has no diff for untracked and conflicted files', function()
    assert.is_nil(fugitive_status.spec_for(cwd, { section = 'untracked', status = '?', path = 'a' }))
    -- A conflict has no stage 0 to read, whichever section fugitive lists it in.
    assert.is_nil(fugitive_status.spec_for(cwd, { section = 'staged', status = 'U', path = 'a' }))
    assert.is_nil(fugitive_status.spec_for(cwd, { section = 'unstaged', status = 'U', path = 'a' }))
  end)
end)
