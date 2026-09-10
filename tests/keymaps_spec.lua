local config = require('guit.config')
local keymaps = require('guit.keymaps')

describe('keymap resolution', function()
  after_each(function()
    config.setup({})
  end)

  it('falls back to the declared default', function()
    assert.equals('<CR>', keymaps.key_for('open'))
    assert.equals('g?', keymaps.key_for('help'))
  end)

  it('honours a user override', function()
    config.setup({ keymaps = { open_show = '<leader>S' } })
    assert.equals('<leader>S', keymaps.key_for('open_show'))
  end)

  it('leaves the key to Vim when an action is disabled', function()
    config.setup({ keymaps = { commit = false } })
    assert.is_nil(keymaps.key_for('commit'))
  end)

  it('still accepts the pre-rename configuration keys', function()
    config.setup({ keymaps = { split = 'O', collapse_all = 'zz' } })
    assert.equals('O', keymaps.key_for('open_focus'))
    assert.equals('zz', keymaps.key_for('collapse_subtree'))
  end)

  it('does not steal keys Vim needs', function()
    -- ?, gg, G, <C-o> and the H/L pair's z-aliases must never be a default.
    local defaults = {}
    for action, spec in pairs(keymaps.actions) do
      defaults[spec.key] = action
      for _, alias in ipairs(spec.aliases or {}) do
        defaults[alias] = action
      end
    end
    for _, key in ipairs({ '?', 'gg', 'G', '<C-o>', 'n', 'N', '/' }) do
      assert.is_nil(defaults[key], ('%s must be left to Vim'):format(key))
    end
  end)
end)

describe('bound mappings', function()
  local bufnr

  before_each(function()
    bufnr = vim.api.nvim_create_buf(false, true)
  end)

  after_each(function()
    config.setup({})
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  local function mapped(lhs)
    return vim.api.nvim_buf_call(bufnr, function()
      local map = vim.fn.maparg(lhs, 'n', false, true)
      return type(map) == 'table' and map.buffer == 1
    end)
  end

  it('binds the primary key and its aliases', function()
    keymaps.apply({ bufnr = bufnr }, { collapse_subtree = function() end })
    assert.is_true(mapped('H'))
    assert.is_true(mapped('zC'))
  end)

  it('leaves the aliases to Vim along with a disabled key', function()
    config.setup({ keymaps = { collapse_subtree = false } })
    keymaps.apply({ bufnr = bufnr }, { collapse_subtree = function() end })
    assert.is_false(mapped('H'))
    assert.is_false(mapped('zC'))
  end)

  it('hands a visual selection to the handler as a line range', function()
    local got
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'a', 'b', 'c', 'd' })
    vim.api.nvim_win_set_buf(0, bufnr)
    keymaps.apply({ bufnr = bufnr }, { stage = function(_, range) got = range end })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.api.nvim_feedkeys('Vjs', 'x', false)
    assert.same({ line1 = 2, line2 = 3 }, got)
  end)
end)

describe('generated help', function()
  after_each(function()
    config.setup({})
  end)

  it('describes the keys actually in effect', function()
    config.setup({ keymaps = { refresh = '<F5>' } })
    local text = keymaps.help_text('Guit test', { refresh = function() end })

    assert.is_truthy(text:find('<F5>', 1, true))
    assert.is_truthy(text:find('reload this view', 1, true))
  end)

  it('omits actions the pane does not provide', function()
    local text = keymaps.help_text('Guit test', { refresh = function() end })

    assert.is_nil(text:find('open the diff', 1, true))
  end)

  it('omits actions the user disabled', function()
    config.setup({ keymaps = { refresh = false } })
    local text = keymaps.help_text('Guit test', { refresh = function() end })

    assert.is_nil(text:find('reload this view', 1, true))
  end)

  it('lists the alias next to the primary key', function()
    local text = keymaps.help_text('Guit test', { collapse_subtree = function() end })

    assert.is_truthy(text:find('H zC', 1, true))
  end)
end)
