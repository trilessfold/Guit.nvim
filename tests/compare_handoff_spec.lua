-- Compare opened from a log takes the log's window, as show does, and `-`
-- brings the log back. It used to open as a second pane below the log; that
-- pane then targeted the log's window, so the first file diff opened from
-- compare replaced the log, and a split from there added windows on top.
local compare = require('guit.compare')
local git = require('guit.git')
local buffer = require('guit.ui.buffer')

local function commit(n)
  return {
    hash = ('%040d'):format(n),
    short_hash = ('%07d'):format(n),
    author = 'A',
    date = '2026-01-01 00:00',
    refs = '',
    subject = 'commit ' .. n,
    parents = { ('%040d'):format(n - 1) },
  }
end

describe('compare opened from a log pane', function()
  local saved = {}
  local log_win

  local function mock(module, name, fn)
    saved[#saved + 1] = { module, name, module[name] }
    module[name] = fn
  end

  local function window_count()
    return #vim.api.nvim_tabpage_list_wins(0)
  end

  before_each(function()
    mock(git, 'fetch_page', function(_, cb)
      cb({ items = { commit(3), commit(2), commit(1) }, eof = true })
    end)
    mock(git, 'fetch_total_count', function(_, cb) cb(3) end)
    mock(compare, 'fetch_changed_files', function(_, cb) cb({}) end)
    mock(compare, 'fetch_numstat', function(_, cb) cb({}, { additions = 0, deletions = 0 }) end)
    mock(compare, 'fetch_meta', function(_, cb)
      cb({ left = { input = 'l', short_hash = 'l' }, right = { input = 'r', short_hash = 'r' } })
    end)
    mock(compare, 'fetch_merge_base', function(_, cb) cb('base') end)

    vim.cmd('silent! %bwipeout!')
    vim.cmd('topleft new')
    buffer.open({ cwd = vim.uv.cwd() })
    log_win = vim.api.nvim_get_current_win()
  end)

  after_each(function()
    for i = #saved, 1, -1 do
      local entry = saved[i]
      entry[1][entry[2]] = entry[3]
    end
    saved = {}
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      vim.wo[winid].winfixbuf = false
    end
    vim.cmd('silent! only!')
    vim.cmd('silent! %bwipeout!')
  end)

  it('replaces the log in its window for a range, without adding a pane', function()
    local before = window_count()

    vim.cmd([[1,2Guit compare]])

    assert.equals(before, window_count())
    assert.equals(log_win, vim.api.nvim_get_current_win())
    assert.equals('guitcompare', vim.bo.filetype)
  end)

  it('does the same for dd on a commit', function()
    local before = window_count()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })

    vim.api.nvim_feedkeys('dd', 'x', false)

    assert.equals(before, window_count())
    assert.equals(log_win, vim.api.nvim_get_current_win())
    assert.equals('guitcompare', vim.bo.filetype)
  end)

  it('returns to the log on -, with the cursor back on the selection', function()
    vim.cmd([[2,3Guit compare]])
    assert.equals('guitcompare', vim.bo.filetype)

    vim.api.nvim_feedkeys('-', 'x', false)

    assert.equals(log_win, vim.api.nvim_get_current_win())
    assert.equals('guitlog', vim.bo.filetype)
    assert.equals(2, vim.api.nvim_win_get_cursor(0)[1])
  end)
end)
