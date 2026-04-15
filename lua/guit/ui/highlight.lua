local config = require('guit.config')

local M = {}

local function mix_colors(fg, bg, ratio)
  if not fg or not bg then
    return fg
  end
  local function channel(color, shift)
    return bit.rshift(bit.band(color, bit.lshift(0xff, shift)), shift)
  end
  local fr, fg_c, fb = channel(fg, 16), channel(fg, 8), channel(fg, 0)
  local br, bg_c, bb = channel(bg, 16), channel(bg, 8), channel(bg, 0)
  local function blend(a, b)
    return math.floor((a * ratio) + (b * (1 - ratio)) + 0.5)
  end
  local r, g, b = blend(fr, br), blend(fg_c, bg_c), blend(fb, bb)
  return bit.bor(bit.lshift(r, 16), bit.lshift(g, 8), b)
end

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
  local normal = vim.api.nvim_get_hl(0, { name = 'Normal', link = false })
  local added = vim.api.nvim_get_hl(0, { name = 'Added', link = false })
  local removed = vim.api.nvim_get_hl(0, { name = 'Removed', link = false })
  local bg = normal.bg or 0
  vim.api.nvim_set_hl(0, config.options.highlights.additions, { fg = mix_colors(added.fg or normal.fg, bg, 0.55), default = false })
  vim.api.nvim_set_hl(0, config.options.highlights.deletions, { fg = mix_colors(removed.fg or normal.fg, bg, 0.55), default = false })
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
