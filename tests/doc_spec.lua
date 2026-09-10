local keymaps = require('guit.keymaps')

-- The help file and the mapping table drifted apart repeatedly: doc/guit.txt
-- listed keys the code no longer bound, and bound keys it never mentioned.
-- These checks make that drift a test failure instead of a bug report.
local function read(path)
  local root = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, 'S').source:sub(2)), ':p:h:h')
  return table.concat(vim.fn.readfile(root .. '/' .. path), '\n')
end

describe('documentation', function()
  local doc = read('doc/guit.txt')
  local readme = read('README.md')

  it('mentions every configurable action', function()
    for action in pairs(keymaps.actions) do
      assert.is_truthy(doc:find(action, 1, true), ('doc/guit.txt never mentions %s'):format(action))
    end
  end)

  it('lists every action, with its default key, in the configuration defaults', function()
    -- config.defaults.keymaps is what users copy from; a key missing there is
    -- one they cannot see, and one whose default differs is a lie.
    local defaults = require('guit.config').defaults.keymaps
    for action, spec in pairs(keymaps.actions) do
      assert.equals(spec.key, defaults[action], ('config default for %s'):format(action))
    end
    for action in pairs(defaults) do
      assert.is_truthy(keymaps.actions[action], ('config default %s is not an action'):format(action))
    end
  end)

  it('does not document keys the plugin stopped binding', function()
    -- These were removed so Vim keeps them.
    for _, gone in ipairs({ '<BS>', 'zJ', 'zK' }) do
      assert.is_nil(doc:find(gone, 1, true), ('doc/guit.txt still documents %s'):format(gone))
      assert.is_nil(readme:find(gone, 1, true), ('README.md still documents %s'):format(gone))
    end
  end)

  it('does not advertise the old config names as current', function()
    for _, old in ipairs({ "split =", "collapse_all =", "expand_all =" }) do
      assert.is_nil(readme:find(old, 1, true), ('README.md still shows %s'):format(old))
    end
  end)

  it('has a tag for every section it cross-references', function()
    for tag in doc:gmatch('|(guit%-[%w_]+)|') do
      assert.is_truthy(doc:find('*' .. tag .. '*', 1, true), ('broken help tag |%s|'):format(tag))
    end
  end)
end)
