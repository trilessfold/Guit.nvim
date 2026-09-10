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

--- Escapes text destined for 'winbar' or 'statusline'.
---
--- Those options treat % as the start of an item, so a branch or file name
--- containing one is otherwise evaluated: "file%{6*7}.txt" renders as
--- "file42.txt".
---@param text string|nil
---@return string
function M.escape_statusline(text)
  return (tostring(text or ''):gsub('%%', '%%%%'))
end

--- Puts an object on the command line, cursor before it, ready for a command.
---
--- This is fugitive's `.`: the pane stays read-only, but anything reachable by
--- an Ex command becomes one keystroke away -- :Guit compare, :Git revert,
--- :Git cherry-pick, :Gdiffsplit.
---@param object string commit hash, ref, or path
function M.put_on_cmdline(object)
  if not object or object == '' then
    return
  end
  local keys = vim.api.nvim_replace_termcodes(': ' .. object .. '<Home>', true, false, true)
  vim.api.nvim_feedkeys(keys, 'n', false)
end

--- Yanks text into the register the user asked for, defaulting to the unnamed
--- one, and mirrors it to the clipboard the way a normal yank would.
---@param text string
function M.yank(text)
  if not text or text == '' then
    return
  end

  local register = vim.v.register
  if register == nil or register == '' then
    register = '"'
  end
  vim.fn.setreg(register, text, 'v')

  -- Match what a plain `y` would do when 'clipboard' says so: `unnamed` is
  -- the * register, `unnamedplus` the + one, and both may be set at once.
  if register == '"' then
    for _, item in ipairs(vim.opt.clipboard:get()) do
      if item == 'unnamed' then
        vim.fn.setreg('*', text, 'v')
      elseif item == 'unnamedplus' then
        vim.fn.setreg('+', text, 'v')
      end
    end
  end
  vim.notify('guit.nvim: yanked ' .. text, vim.log.levels.INFO)
end

return M
