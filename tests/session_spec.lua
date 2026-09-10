local git = require('guit.git')
local session = require('guit.session')
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

describe('session pane registry', function()
  local real_page, real_total

  before_each(function()
    real_page, real_total = git.fetch_page, git.fetch_total_count
    git.fetch_page = function(_, cb)
      cb({ items = { commit(1), commit(2) }, eof = true })
    end
    git.fetch_total_count = function(_, cb)
      cb(2)
    end
    vim.cmd('silent! %bwipeout!')
  end)

  after_each(function()
    git.fetch_page, git.fetch_total_count = real_page, real_total
    vim.cmd('silent! %bwipeout!')
  end)

  -- A pane window has winfixbuf set, so each new pane needs a plain window to
  -- be opened from.
  local function open_pane()
    vim.cmd('topleft new')
    buffer.open({ cwd = vim.uv.cwd() })
    return vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  end

  it('closes the pane q was pressed in, not the newest one', function()
    -- A single global slot meant the second pane replaced the first, so `q` in
    -- the first pane closed the second and left the first stranded.
    local first_buf, first_win = open_pane()
    local second_buf, second_win = open_pane()
    assert.are_not.equal(first_buf, second_buf)

    vim.api.nvim_set_current_win(first_win)
    vim.api.nvim_feedkeys('q', 'x', false)

    assert.is_false(vim.api.nvim_win_is_valid(first_win), 'the focused pane should close')
    assert.is_true(vim.api.nvim_win_is_valid(second_win), 'the other pane must stay open')
  end)

  it('lets toggle act on a pane that was re-entered', function()
    local first_buf, first_win = open_pane()
    local _, second_win = open_pane()

    -- Returning to the older pane fires BufEnter, which must re-activate it.
    vim.api.nvim_set_current_win(first_win)
    vim.cmd('doautocmd BufEnter')

    session.close_active()

    assert.is_false(vim.api.nvim_win_is_valid(first_win))
    assert.is_true(vim.api.nvim_win_is_valid(second_win))
  end)

  it('reclaims the origin buffer a view was opened from', function()
    -- log -> show -> q used to leave the log buffer hidden forever, together
    -- with its state entry and its augroup.
    local origin_buf, pane_win = open_pane()

    -- This is what `s` does: hide the log buffer and hand its window to show.
    vim.bo[origin_buf].bufhidden = 'hide'
    local show_buf = vim.api.nvim_create_buf(false, true)
    vim.wo[pane_win].winfixbuf = false
    vim.api.nvim_win_set_buf(pane_win, show_buf)

    local state = { bufnr = show_buf, winid = pane_win, source_log = { bufnr = origin_buf } }
    assert.is_true(vim.api.nvim_buf_is_valid(origin_buf))
    assert.equals(-1, vim.fn.bufwinid(origin_buf), 'log buffer should now be hidden')

    session.register(state, function()
      return { kind = 'show' }
    end)
    session.close(state)
    vim.wait(50)

    assert.is_false(vim.api.nvim_buf_is_valid(origin_buf), 'origin buffer should be reclaimed')
  end)
end)
