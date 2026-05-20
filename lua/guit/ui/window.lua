local config = require('guit.config')

local M = {}

local opening_pane = false

function M.is_opening_pane()
  return opening_pane
end

function M.open_bottom_pane(bufnr)
  local target_winid = vim.api.nvim_get_current_win()
  local total_lines = vim.o.lines - vim.o.cmdheight
  local height = math.max(config.options.layout.min_height, math.floor(total_lines * config.options.layout.height))

  opening_pane = true
  local ok, err = pcall(function()
    vim.cmd(('%s %dsplit'):format(config.options.layout.position, height))
  end)
  opening_pane = false
  if not ok then
    error(err)
  end

  local pane_winid = vim.api.nvim_get_current_win()
  opening_pane = true
  ok, err = pcall(function()
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
    vim.wo[pane_winid].scrollbind = false
    vim.wo[pane_winid].cursorbind = false
  end)
  opening_pane = false
  if not ok then
    error(err)
  end

  return pane_winid, target_winid
end

return M
