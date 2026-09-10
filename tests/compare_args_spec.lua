local guit = require('guit')

describe(':Guit compare argument parsing', function()
  it('splits three-dot before two-dot', function()
    -- The old code matched '..' first and produced ("main", ".feature").
    local left, right, symmetric = guit.parse_compare_args('main...feature')

    assert.equals('main', left)
    assert.equals('feature', right)
    assert.is_true(symmetric)
  end)

  it('splits the two-dot form', function()
    local left, right, symmetric = guit.parse_compare_args('main..feature')

    assert.equals('main', left)
    assert.equals('feature', right)
    assert.is_false(symmetric)
  end)

  it('keeps two separate arguments as-is', function()
    local left, right, symmetric = guit.parse_compare_args('main', 'feature')

    assert.equals('main', left)
    assert.equals('feature', right)
    assert.is_false(symmetric)
  end)

  it('treats a lone revision as a working-tree comparison', function()
    local left, right, symmetric = guit.parse_compare_args('main')

    assert.equals('main', left)
    assert.is_nil(right)
    assert.is_false(symmetric)
  end)

  it('handles refs that themselves contain dots', function()
    local left, right, symmetric = guit.parse_compare_args('v1.2.3...v2.0.0')

    assert.equals('v1.2.3', left)
    assert.equals('v2.0.0', right)
    assert.is_true(symmetric)
  end)

  it('returns nothing for empty input', function()
    local left = guit.parse_compare_args('')
    assert.is_nil(left)
  end)
end)
