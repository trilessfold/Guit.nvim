-- dd in a history pane. In a file history it used to compare the commit
-- against HEAD in a new pane, which left an inline overlay from di on screen
-- next to it: both diff shapes at once. It now opens the file diff, like di
-- and ds, so the shapes stay one or the other.
local diff = require('guit.ui.diff')
local guit = require('guit')
local history = require('guit.history')
local history_buffer = require('guit.ui.history_buffer')

local function commit(n)
  return {
    hash = ('%040d'):format(n),
    short_hash = ('%07d'):format(n),
    author = 'A',
    date = '2026-01-01 00:00',
    refs = '',
    subject = 'commit ' .. n,
    parents = { ('%040d'):format(n - 1) },
    status = 'M',
    path = 'f.txt',
    files_changed = 1,
    additions = 1,
    deletions = 1,
  }
end

describe('dd in a history pane', function()
  local real_page, real_total, real_open, real_compare
  local opened_diff, compared

  before_each(function()
    opened_diff, compared = nil, nil
    real_page, real_total = history.fetch_page, history.fetch_total_count
    history.fetch_page = function(_, cb)
      cb({ items = { commit(2), commit(1) }, eof = true })
    end
    history.fetch_total_count = function(_, cb)
      cb(2)
    end
    real_open = diff.open
    diff.open = function(state, spec, opts)
      opened_diff = { spec = spec, opts = opts }
      return true
    end
    real_compare = guit.compare
    guit.compare = function(left, right, opts)
      compared = { left = left, right = right, opts = opts }
    end
    vim.cmd('silent! %bwipeout!')
    vim.cmd('topleft new')
  end)

  after_each(function()
    history.fetch_page, history.fetch_total_count = real_page, real_total
    diff.open = real_open
    guit.compare = real_compare
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      vim.wo[winid].winfixbuf = false
    end
    vim.cmd('silent! only!')
    vim.cmd('silent! %bwipeout!')
  end)

  local function press_dd_on_first_commit()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.api.nvim_feedkeys('dd', 'x', false)
  end

  it('opens the file diff in the configured shape for a file history', function()
    history_buffer.open({ cwd = vim.uv.cwd(), path = 'f.txt', is_file = true })

    press_dd_on_first_commit()

    assert.is_nil(compared, 'dd must not open a compare pane in a file history')
    assert.is_truthy(opened_diff)
    -- No explicit mode: diff.open falls back to diff.mode, so dd is di or ds.
    assert.is_nil(opened_diff.opts.mode)
    assert.equals(('%040d'):format(2), opened_diff.spec.right.rev)
    assert.equals(('%040d'):format(2) .. '^', opened_diff.spec.left.rev)
  end)

  it('still compares the commit against HEAD for a directory history', function()
    history_buffer.open({ cwd = vim.uv.cwd(), path = 'lua', is_file = false })

    press_dd_on_first_commit()

    assert.is_nil(opened_diff)
    assert.is_truthy(compared)
    assert.equals(('%040d'):format(2), compared.left)
    assert.equals('HEAD', compared.right)
    assert.equals(vim.uv.cwd(), compared.opts.cwd)
  end)
end)
