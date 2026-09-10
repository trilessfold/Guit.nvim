-- Pressing `r` while a page is still in flight used to append
-- the stale page into the freshly cleared list, duplicating commits.
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
  }
end

describe('log pane refresh', function()
  local real_fetch_page, real_total, pending

  before_each(function()
    pending = {}
    real_fetch_page = git.fetch_page
    real_total = git.fetch_total_count
    -- Capture callbacks instead of running git, so the test controls ordering.
    git.fetch_page = function(_, cb)
      pending[#pending + 1] = cb
    end
    git.fetch_total_count = function(_, cb)
      cb(2)
    end
  end)

  after_each(function()
    git.fetch_page = real_fetch_page
    git.fetch_total_count = real_total
    vim.cmd('silent! %bwipeout!')
  end)

  it('drops a page belonging to a superseded refresh', function()
    vim.cmd('enew')
    buffer.open({ cwd = vim.uv.cwd() })

    assert.equals(1, #pending, 'initial load should have issued one fetch')

    -- User presses `r` while that first page is still in flight.
    vim.api.nvim_feedkeys('r', 'x', false)
    assert.equals(2, #pending, 'refresh should have issued a second fetch')

    -- The stale page lands first, then the fresh one.
    pending[1]({ items = { commit(1), commit(2) }, eof = true })
    pending[2]({ items = { commit(1), commit(2) }, eof = true })

    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local rendered = 0
    for _, line in ipairs(lines) do
      if line:match('commit %d') then
        rendered = rendered + 1
      end
    end

    assert.equals(2, rendered, 'each commit must appear exactly once')
  end)
end)
