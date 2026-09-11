-- Toggling an inline diff off and on from inside the buffer. When a pane drew
-- it, a :Guit compare between two revisions say, toggling it back on must
-- restore that comparison, not switch to the object against its parent.
local diff = require('guit.ui.diff')
local inline_diff = require('guit.ui.inline_diff')

describe('an inline diff toggled from inside its buffer', function()
  local dir, pane, target, state

  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    vim.fn.writefile({ 'one', 'two' }, dir .. '/file.txt')
    vim.o.hidden = true
    vim.cmd('silent! only!')
    vim.cmd('enew')
    pane = vim.api.nvim_get_current_win()
    vim.cmd('rightbelow split')
    target = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(pane)
    state = { bufnr = vim.api.nvim_get_current_buf(), winid = pane, target_winid = target }
  end)

  after_each(function()
    vim.cmd('silent! %bwipeout!')
    vim.fn.delete(dir, 'rf')
  end)

  -- An added file: no old side to fetch, so no git and no fugitive needed.
  local function spec()
    return { cwd = dir, right = { path = 'file.txt' } }
  end

  it("comes back as the pane's comparison", function()
    assert.is_true(diff.open(state, spec(), { mode = 'inline' }))
    local bufnr = vim.api.nvim_win_get_buf(target)
    assert.is_true(inline_diff.is_attached(bufnr))
    local label = vim.b[bufnr].guit_inline_diff

    vim.api.nvim_set_current_win(target)
    require('guit').inline()
    assert.is_false(inline_diff.is_attached(bufnr))

    require('guit').inline()
    assert.is_true(inline_diff.is_attached(bufnr))
    assert.equals(label, vim.b[bufnr].guit_inline_diff)
  end)

  it('does not move the cursor when it comes back', function()
    diff.open(state, spec(), { mode = 'inline' })
    local bufnr = vim.api.nvim_win_get_buf(target)
    vim.api.nvim_set_current_win(target)
    require('guit').inline()
    vim.api.nvim_win_set_cursor(target, { 2, 0 })

    require('guit').inline()

    assert.equals(2, vim.api.nvim_win_get_cursor(target)[1])
  end)

  it('has nothing to restore once the pane is gone', function()
    diff.open(state, spec(), { mode = 'inline' })
    local bufnr = vim.api.nvim_win_get_buf(target)
    inline_diff.detach(bufnr)
    vim.api.nvim_buf_delete(state.bufnr, { force = true })

    assert.is_false(diff.reattach(bufnr, target))
  end)
end)
