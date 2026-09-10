local preview = require('guit.ui.preview')

-- Builds the two-window layout every Guit pane uses: the pane itself plus the
-- target window that previews are opened into.
local function make_state()
  vim.cmd('silent! %bwipeout!')
  vim.o.hidden = true
  vim.cmd('enew')
  local pane = vim.api.nvim_get_current_win()
  vim.cmd('rightbelow split')
  local target = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(pane)
  return { winid = pane, target_winid = target }
end

local function tmp(name)
  return vim.fn.tempname() .. '-' .. name
end

describe('preview buffer reclamation', function()
  it('never discards a buffer with unsaved changes', function()
    -- Guit opens a file plus a diff split, the user edits the split, then
    -- selects another entry. The old code force-deleted the split buffer.
    local state = make_state()
    local edited = tmp('edited.txt')

    preview.with_managed_preview(state, function()
      vim.cmd('edit ' .. tmp('anchor.txt'))
      vim.cmd('leftabove vsplit ' .. edited)
      vim.cmd('wincmd p')
    end)

    local split_buf = vim.fn.bufnr(edited)
    vim.api.nvim_buf_set_lines(split_buf, 0, -1, false, { 'UNSAVED EDIT' })
    vim.bo[split_buf].modified = true

    vim.api.nvim_set_current_win(state.winid)
    preview.with_managed_preview(state, function()
      vim.cmd('edit ' .. tmp('next.txt'))
    end)

    assert.is_true(vim.api.nvim_buf_is_valid(split_buf))
    assert.equals('UNSAVED EDIT', vim.api.nvim_buf_get_lines(split_buf, 0, -1, false)[1])
  end)

  it('still reclaims the unmodified buffers it opened', function()
    -- The guard must not defeat the cleanup the mechanism exists for.
    local state = make_state()
    local throwaway = tmp('throwaway.txt')

    preview.with_managed_preview(state, function()
      vim.cmd('edit ' .. tmp('anchor.txt'))
      vim.cmd('leftabove vsplit ' .. throwaway)
      vim.cmd('wincmd p')
    end)
    local split_buf = vim.fn.bufnr(throwaway)

    vim.api.nvim_set_current_win(state.winid)
    preview.with_managed_preview(state, function()
      vim.cmd('edit ' .. tmp('next.txt'))
    end)

    assert.is_false(vim.api.nvim_buf_is_valid(split_buf))
  end)

  it('leaves buffers the user opened alone', function()
    local state = make_state()
    local mine = tmp('mine.txt')
    vim.api.nvim_set_current_win(state.target_winid)
    vim.cmd('edit ' .. mine)
    local user_buf = vim.api.nvim_get_current_buf()

    vim.api.nvim_set_current_win(state.winid)
    preview.with_managed_preview(state, function()
      vim.cmd('edit ' .. tmp('other.txt'))
    end)
    vim.api.nvim_set_current_win(state.winid)
    preview.with_managed_preview(state, function()
      vim.cmd('edit ' .. tmp('another.txt'))
    end)

    assert.is_true(vim.api.nvim_buf_is_valid(user_buf))
  end)

  it('tracks windows opened by an action that then failed', function()
    -- Without this the extra window is orphaned and never cleaned up.
    local state = make_state()

    local ok = preview.with_managed_preview(state, function()
      vim.cmd('edit ' .. tmp('anchor.txt'))
      vim.cmd('leftabove vsplit ' .. tmp('half-open.txt'))
      error('action failed midway')
    end)

    assert.is_false(ok)
    assert.is_true(#state.preview.extra_wins > 0)
  end)
end)
