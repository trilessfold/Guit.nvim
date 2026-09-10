local parse = require('guit.git_parse')

-- Fixtures below are byte-for-byte captures of real git output, produced by a
-- repository containing a renamed file with a space, a non-ASCII filename, a
-- merge commit and a root commit. See tests/README.md for how to regenerate.

describe('git_parse.name_status_z', function()
  it('keeps both sides of a rename whose paths contain spaces', function()
    local items = parse.name_status_z('R050\0old name.txt\0new name.txt\0')

    assert.equals(1, #items)
    assert.equals('R050', items[1].status)
    assert.equals('old name.txt', items[1].old_path)
    assert.equals('new name.txt', items[1].path)
  end)

  it('keeps non-ASCII paths raw, without quoting or octal escapes', function()
    local items = parse.name_status_z('A\0тест ф.txt\0')

    assert.equals('тест ф.txt', items[1].path)
    assert.is_nil(items[1].path:find('\\'))
    assert.is_nil(items[1].path:find('"'))
  end)

  it('parses a commit mixing rename, modify, add and delete', function()
    local items = parse.name_status_z(
      'R100\0new name.txt\0renamed again.txt\0'
        .. 'M\0root.txt\0'
        .. 'A\0новый.txt\0'
        .. 'D\0тест ф.txt\0'
    )

    assert.equals(4, #items)
    assert.same({ 'R100', 'M', 'A', 'D' }, vim.tbl_map(function(i) return i.status end, items))
    assert.same(
      { 'renamed again.txt', 'root.txt', 'новый.txt', 'тест ф.txt' },
      vim.tbl_map(function(i) return i.path end, items)
    )
    assert.equals('new name.txt', items[1].old_path)
    assert.is_nil(items[2].old_path)
  end)

  it('treats a copy like a rename', function()
    local items = parse.name_status_z('C075\0src.txt\0dst.txt\0')

    assert.equals('src.txt', items[1].old_path)
    assert.equals('dst.txt', items[1].path)
  end)

  it('returns an empty list for empty output', function()
    assert.same({}, parse.name_status_z(''))
    assert.same({}, parse.name_status_z(nil))
  end)
end)

describe('git_parse.numstat_z', function()
  it('registers a rename under both the old and the new path', function()
    local stats = parse.numstat_z('0\t0\t\0old name.txt\0new name.txt\0')

    -- status.lua looks files up by their worktree path, changed_files.lua by
    -- the new path; both must resolve.
    assert.same({ additions = 0, deletions = 0 }, stats['old name.txt'])
    assert.same({ additions = 0, deletions = 0 }, stats['new name.txt'])
  end)

  it('parses a commit mixing rename, modify, add and delete', function()
    local stats, total = parse.numstat_z(
      '0\t0\t\0new name.txt\0renamed again.txt\0'
        .. '1\t0\troot.txt\0'
        .. '1\t0\tновый.txt\0'
        .. '0\t1\tтест ф.txt\0'
    )

    assert.same({ additions = 1, deletions = 0 }, stats['root.txt'])
    assert.same({ additions = 1, deletions = 0 }, stats['новый.txt'])
    assert.same({ additions = 0, deletions = 1 }, stats['тест ф.txt'])
    assert.same({ additions = 0, deletions = 0 }, stats['renamed again.txt'])
    assert.same({ additions = 2, deletions = 1 }, total)
  end)

  it('counts a rename once in the total despite two path keys', function()
    local _, total = parse.numstat_z('3\t4\t\0a.txt\0b.txt\0')

    assert.same({ additions = 3, deletions = 4 }, total)
  end)

  it('treats binary files as zero rather than failing', function()
    local stats, total = parse.numstat_z('-\t-\timage.png\0')

    assert.same({ additions = 0, deletions = 0 }, stats['image.png'])
    assert.same({ additions = 0, deletions = 0 }, total)
  end)

  it('returns empty stats for empty output', function()
    local stats, total = parse.numstat_z('')

    assert.same({}, stats)
    assert.same({ additions = 0, deletions = 0 }, total)
  end)
end)

describe('git_parse.rename_paths', function()
  it('splits on the tab, not on the space inside a filename', function()
    local old_path, new_path = parse.rename_paths('old name.txt\tnew name.txt')

    assert.equals('old name.txt', old_path)
    assert.equals('new name.txt', new_path)
  end)

  it('handles paths without spaces', function()
    local old_path, new_path = parse.rename_paths('a/b.txt\tc/d.txt')

    assert.equals('a/b.txt', old_path)
    assert.equals('c/d.txt', new_path)
  end)

  it('returns nil when there is no second path', function()
    assert.is_nil(parse.rename_paths('only-one.txt'))
    assert.is_nil(parse.rename_paths(''))
    assert.is_nil(parse.rename_paths(nil))
  end)
end)
