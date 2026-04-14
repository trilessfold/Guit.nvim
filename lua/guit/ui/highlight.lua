local config = require('guit.config')

local M = {}

function M.setup()
  vim.api.nvim_set_hl(0, config.options.highlights.hash, { link = 'Identifier', default = false })
  vim.api.nvim_set_hl(0, config.options.highlights.date, { link = 'Comment', default = false })
  vim.api.nvim_set_hl(0, config.options.highlights.author, { link = 'Type', default = false })
  vim.api.nvim_set_hl(0, config.options.highlights.refs, { link = 'Special', default = false })
  vim.api.nvim_set_hl(0, config.options.highlights.subject, { link = 'Normal', default = false })
  vim.api.nvim_set_hl(0, config.options.highlights.file, { link = 'Normal', default = false })
  vim.api.nvim_set_hl(0, config.options.highlights.dir, { link = 'Directory', default = false })
  vim.api.nvim_set_hl(0, config.options.highlights.status, { link = 'String', default = false })
  vim.api.nvim_set_hl(0, config.options.highlights.cursorline, { link = 'CursorLine', default = false })
  vim.api.nvim_set_hl(0, config.options.highlights.title, { link = 'Title', default = false })
  vim.api.nvim_set_hl(0, config.options.highlights.loading, { link = 'Comment', default = false })
  vim.api.nvim_set_hl(0, config.options.highlights.counter, { link = 'Number', default = false })
  local cursorline = vim.api.nvim_get_hl(0, { name = 'CursorLine', link = false })
  local selected = {}
  if cursorline.bg then
    selected.bg = cursorline.bg
  end
  if cursorline.ctermbg then
    selected.ctermbg = cursorline.ctermbg
  end
  if vim.tbl_isempty(selected) then
    selected = { link = 'CursorLine' }
  end
  vim.api.nvim_set_hl(0, config.options.highlights.selected, selected)
end

return M
