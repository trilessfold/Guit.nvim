local config = require('guit.config')

local M = {}

function M.open_bottom_pane(bufnr)
  local target_winid = vim.api.nvim_get_current_win()
  local total_lines = vim.o.lines - vim.o.cmdheight
  local height = math.max(config.options.layout.min_height, math.floor(total_lines * config.options.layout.height))

  vim.cmd(('%s %dsplit'):format(config.options.layout.position, height))
  local pane_winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(pane_winid, bufnr)

  vim.wo[pane_winid].number = false
  vim.wo[pane_winid].relativenumber = false
  vim.wo[pane_winid].cursorline = false
  vim.wo[pane_winid].cursorlineopt = 'line'
  vim.wo[pane_winid].winhighlight = ''
  vim.wo[pane_winid].signcolumn = 'no'
  vim.wo[pane_winid].foldcolumn = '0'
  vim.wo[pane_winid].wrap = false
  vim.wo[pane_winid].winfixheight = true
  vim.wo[pane_winid].winfixbuf = true

  return pane_winid, target_winid
end

return M
