local M = {}

function M.with_winfixbuf_disabled(winid, fn)
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return fn()
  end
  local old = vim.wo[winid].winfixbuf
  vim.wo[winid].winfixbuf = false
  local ok, res = pcall(fn)
  if vim.api.nvim_win_is_valid(winid) then
    vim.wo[winid].winfixbuf = old
  end
  if not ok then
    error(res)
  end
  return res
end

function M.set_readonly(bufnr, value)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.bo[bufnr].modifiable = not value
  vim.bo[bufnr].readonly = value
end

function M.with_modifiable(bufnr, fn)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local old_modifiable = vim.bo[bufnr].modifiable
  local old_readonly = vim.bo[bufnr].readonly
  vim.bo[bufnr].modifiable = true
  vim.bo[bufnr].readonly = false
  local ok, err = pcall(fn)
  vim.bo[bufnr].modifiable = old_modifiable
  vim.bo[bufnr].readonly = old_readonly
  if not ok then
    error(err)
  end
end


function M.update_line_selection(bufnr, ns, line, group)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  if not line or line < 1 then
    return
  end
  local row = line - 1
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if row >= line_count then
    return
  end
  vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, {
    line_hl_group = group,
    priority = 1,
  })
end

return M
