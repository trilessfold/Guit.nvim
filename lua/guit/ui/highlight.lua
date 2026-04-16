local config = require('guit.config')

local M = {}

local function get_hl(name)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  if ok and hl and not vim.tbl_isempty(hl) then
    return hl
  end
  return {}
end

local function hex_to_rgb(color)
  if not color then return nil end
  return {
    bit.rshift(bit.band(color, 0xff0000), 16),
    bit.rshift(bit.band(color, 0x00ff00), 8),
    bit.band(color, 0x0000ff),
  }
end

local function rgb_to_hex(rgb)
  return bit.bor(bit.lshift(rgb[1], 16), bit.lshift(rgb[2], 8), rgb[3])
end

local function blend(color_a, color_b, ratio)
  if not color_a then return color_b end
  if not color_b then return color_a end
  local a = hex_to_rgb(color_a)
  local b = hex_to_rgb(color_b)
  return rgb_to_hex({
    math.floor((a[1] * ratio) + (b[1] * (1 - ratio)) + 0.5),
    math.floor((a[2] * ratio) + (b[2] * (1 - ratio)) + 0.5),
    math.floor((a[3] * ratio) + (b[3] * (1 - ratio)) + 0.5),
  })
end

local function lighten(color, amount)
  if not color then return nil end
  return blend(color, 0xffffff, 1 - amount)
end

local function luminance(color)
  if not color then return 0 end
  local rgb = hex_to_rgb(color)
  local function channel(v)
    v = v / 255
    if v <= 0.03928 then
      return v / 12.92
    end
    return ((v + 0.055) / 1.055) ^ 2.4
  end
  local r, g, b = channel(rgb[1]), channel(rgb[2]), channel(rgb[3])
  return 0.2126 * r + 0.7152 * g + 0.0722 * b
end

local function theme_mode(normal_bg)
  return luminance(normal_bg) < 0.35 and 'dark' or 'light'
end

local function adapt_status(base, normal_bg, mode)
  if mode == 'dark' then
    return blend(base, normal_bg, 0.90)
  end
  return blend(base, normal_bg, 0.76)
end

local function adapt_text(base, normal_fg, normal_bg, mode, opts)
  opts = opts or {}
  local bg_ratio = opts.bg_ratio or (mode == 'dark' and 0.86 or 0.70)
  local fg_ratio = opts.fg_ratio or (mode == 'dark' and 0.84 or 0.72)
  local mixed = blend(base, normal_bg, bg_ratio)
  return blend(mixed, normal_fg, fg_ratio)
end

local function safe_set(name, spec)
  vim.api.nvim_set_hl(0, name, vim.tbl_extend('force', spec, { default = false }))
end

function M.setup()
  local normal = get_hl('Normal')
  local cursorline = get_hl('CursorLine')
  local title_hl = get_hl('Title')
  local identifier_hl = get_hl('Identifier')
  local type_hl = get_hl('Type')
  local comment_hl = get_hl('Comment')
  local special_hl = get_hl('Special')
  local directory_hl = get_hl('Directory')

  local normal_fg = normal.fg or 0xd0d0d0
  local normal_bg = normal.bg or 0x101010
  local mode = theme_mode(normal_bg)
  local base_cursor_bg = cursorline.bg or blend(normal_fg, normal_bg, mode == 'dark' and 0.12 or 0.16)

  local palette = {
    added = adapt_status(0x58c26d, normal_bg, mode),
    deleted = adapt_status(0xe06c75, normal_bg, mode),
    modified = adapt_status(0xe5c25c, normal_bg, mode),
    renamed = adapt_status(0x61afef, normal_bg, mode),
    copied = adapt_status(0xc678dd, normal_bg, mode),
    hash = identifier_hl.fg or adapt_text(0x7fa8d8, normal_fg, normal_bg, mode, { bg_ratio = mode == 'dark' and 0.84 or 0.74, fg_ratio = mode == 'dark' and 0.82 or 0.70 }),
    date = comment_hl.fg or adapt_text(0xa7acb8, normal_fg, normal_bg, mode, { bg_ratio = mode == 'dark' and 0.82 or 0.72, fg_ratio = mode == 'dark' and 0.80 or 0.70 }),
    author = type_hl.fg or adapt_text(0xc2cad6, normal_fg, normal_bg, mode, { bg_ratio = mode == 'dark' and 0.86 or 0.76, fg_ratio = mode == 'dark' and 0.86 or 0.76 }),
    refs = directory_hl.fg or adapt_text(0x87b37d, normal_fg, normal_bg, mode, { bg_ratio = mode == 'dark' and 0.90 or 0.78, fg_ratio = mode == 'dark' and 0.88 or 0.78 }),
    title = title_hl.fg or adapt_text(0x89b4fa, normal_fg, normal_bg, mode, { bg_ratio = mode == 'dark' and 0.82 or 0.70, fg_ratio = mode == 'dark' and 0.88 or 0.78 }),
    loading = comment_hl.fg or adapt_text(0xa7acb8, normal_fg, normal_bg, mode),
    counter = comment_hl.fg or adapt_text(0xb0b6c2, normal_fg, normal_bg, mode),
    status = special_hl.fg or adapt_text(0xa9a6b2, normal_fg, normal_bg, mode),
    selected_bg = blend(base_cursor_bg, normal_bg, mode == 'dark' and 0.88 or 0.82),
  }

  safe_set(config.options.highlights.hash, { fg = palette.hash })
  safe_set(config.options.highlights.date, { fg = palette.date })
  safe_set(config.options.highlights.author, { fg = palette.author })
  safe_set(config.options.highlights.refs, { fg = palette.refs })
  safe_set(config.options.highlights.subject, { fg = normal_fg })
  safe_set(config.options.highlights.file, { link = 'Normal' })
  safe_set(config.options.highlights.dir, { link = 'Directory' })
  safe_set(config.options.highlights.status, { fg = palette.status })
  safe_set(config.options.highlights.title, { fg = palette.title, bold = title_hl.bold or false, italic = title_hl.italic or false })
  safe_set(config.options.highlights.loading, { fg = palette.loading })
  safe_set(config.options.highlights.counter, { fg = palette.counter })

  safe_set(config.options.highlights.status_added, { fg = palette.added })
  safe_set(config.options.highlights.status_deleted, { fg = palette.deleted })
  safe_set(config.options.highlights.status_modified, { fg = palette.modified })
  safe_set(config.options.highlights.status_renamed, { fg = palette.renamed })
  safe_set(config.options.highlights.status_copied, { fg = palette.copied })

  safe_set(config.options.highlights.additions, { fg = lighten(palette.added, 0.04) })
  safe_set(config.options.highlights.deletions, { fg = lighten(palette.deleted, 0.04) })

  local selected = { bg = palette.selected_bg }
  safe_set(config.options.highlights.selected, selected)
  safe_set(config.options.highlights.cursorline, selected)
end

return M
