local git = require('guit.git')
local guit = require('guit')
local buffer = require('guit.ui.buffer')

local ROOT = ('a'):rep(40)

local function commit(n, parents)
  return {
    hash = ('%040d'):format(n),
    short_hash = ('%07d'):format(n),
    author = 'A',
    date = '2026-01-01 00:00',
    refs = '',
    subject = 'commit ' .. n,
    parents = parents,
  }
end

describe(':[range]Guit compare', function()
  local real_page, real_total, real_compare, opened

  before_each(function()
    opened = nil
    real_page, real_total = git.fetch_page, git.fetch_total_count
    -- Newest first, and the last one is a root commit.
    git.fetch_page = function(_, cb)
      cb({
        items = {
          commit(3, { ('%040d'):format(2) }),
          commit(2, { ('%040d'):format(1) }),
          commit(1, {}),
        },
        eof = true,
      })
    end
    git.fetch_total_count = function(_, cb)
      cb(3)
    end
    real_compare = guit.compare
    guit.compare = function(left, right, opts)
      opened = { left = left, right = right, opts = opts }
    end
    vim.cmd('silent! %bwipeout!')
    vim.cmd('topleft new')
    buffer.open({ cwd = vim.uv.cwd() })
  end)

  after_each(function()
    git.fetch_page, git.fetch_total_count = real_page, real_total
    guit.compare = real_compare
    vim.cmd('silent! %bwipeout!')
  end)

  it('includes every selected commit', function()
    -- Lines 1..2 are the two newest commits. git's own a..b would drop the
    -- older one, so the older end is widened to its parent.
    vim.cmd([[1,2Guit compare]])

    assert.is_truthy(opened)
    assert.equals(('%040d'):format(3), opened.right)
    assert.equals(('%040d'):format(2) .. '^', opened.left)
  end)

  it('compares in the repository the pane was opened for', function()
    -- The pane's repository need not be Neovim's cwd; the hashes only
    -- resolve in the former.
    vim.cmd([[1,2Guit compare]])

    assert.equals(vim.uv.cwd(), opened.opts.cwd)
  end)

  it('compares a single line against its parent', function()
    vim.cmd([[2Guit compare]])

    assert.equals(('%040d'):format(2), opened.right)
    assert.equals(('%040d'):format(2) .. '^', opened.left)
  end)

  it('uses the empty tree when the root commit is selected', function()
    -- <root>^ does not resolve, so the left side must be git's empty tree.
    vim.cmd([[1,3Guit compare]])

    assert.equals('4b825dc642cb6eb9a060e54bf8d69288fbee4904', opened.left)
    assert.equals(('%040d'):format(3), opened.right)
  end)

  it('still honours explicit arguments over the range', function()
    vim.cmd([[1,2Guit compare main feature]])

    assert.equals('main', opened.left)
    assert.equals('feature', opened.right)
  end)
end)
