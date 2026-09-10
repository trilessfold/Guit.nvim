local config = require('guit.config')
local git = require('guit.git')
local buffer = require('guit.ui.buffer')
local show_buffer = require('guit.ui.show_buffer')
local compare_buffer = require('guit.ui.compare_buffer')
local status_buffer = require('guit.ui.status_buffer')
local history_buffer = require('guit.ui.history_buffer')
local blame_buffer = require('guit.ui.blame_buffer')
local fugitive = require('guit.fugitive')
local history = require('guit.history')
local session = require('guit.session')

local M = {}

local function current_buffer_source()
  local fugitive_source = fugitive.from_buffer(0)
  if fugitive_source then
    return fugitive_source
  end

  local current = vim.fn.expand('%:p')
  if current == '' then
    return nil, 'current buffer has no file name'
  end
  return { path = current }
end

local function expand_current_buffer_path(path)
  if path ~= '%' then
    return { path = path }
  end

  return current_buffer_source()
end

function M.setup(opts)
  config.setup(opts)
end

function M.log(rev, opts)
  if type(rev) == 'table' and opts == nil then
    opts = rev
    rev = nil
  end

  local cwd = (opts and opts.cwd) or vim.uv.cwd()
  local repo, err = git.repo_root(cwd)
  if not repo then
    vim.notify('guit.nvim: ' .. err, vim.log.levels.ERROR)
    return
  end

  buffer.open(vim.tbl_extend('force', opts or {}, { cwd = repo, rev = rev }))
end

function M.show(commit, opts)
  if not commit or commit == '' then
    vim.notify('guit.nvim: usage :Guit show <commit_hash>', vim.log.levels.INFO)
    return
  end

  local source = nil
  if commit == '%' then
    source = fugitive.from_buffer(0)
    if not source or not source.commit then
      vim.notify('guit.nvim: current buffer is not a fugitive commit object', vim.log.levels.WARN)
      return
    end
    commit = source.commit
  end

  local cwd = (opts and opts.cwd) or (source and source.cwd) or vim.uv.cwd()
  local repo, err = git.repo_root(cwd)
  if not repo then
    vim.notify('guit.nvim: ' .. err, vim.log.levels.ERROR)
    return
  end

  show_buffer.open(vim.tbl_extend('force', opts or {}, { cwd = repo, commit = commit }))
end

function M.history(path, opts)
  opts = opts or {}
  if (not path or path == '') and opts.line_range then
    path = '%'
  end
  if not path or path == '' then
    vim.notify('guit.nvim: usage :Guit history <file_or_directory>', vim.log.levels.INFO)
    return
  end

  local source, expand_err = expand_current_buffer_path(path)
  if not source then
    vim.notify('guit.nvim: ' .. expand_err, vim.log.levels.WARN)
    return
  end
  path = source.path
  if not path or path == '' then
    vim.notify('guit.nvim: current fugitive buffer does not point to a file', vim.log.levels.WARN)
    return
  end

  local cwd = (opts and opts.cwd) or source.cwd or vim.uv.cwd()
  local repo, err = git.repo_root(cwd)
  if not repo then
    vim.notify('guit.nvim: ' .. err, vim.log.levels.ERROR)
    return
  end

  local rel = history.normalize_path(repo, path)
  local abs = vim.fn.fnamemodify(path, ':p')
  local stat_path = abs
  if vim.fn.filereadable(abs) == 0 and vim.fn.isdirectory(abs) == 0 then
    stat_path = repo .. '/' .. rel
  end
  local stat = vim.uv.fs_stat(stat_path)
  local is_file = source.commit and source.path ~= nil or (stat and stat.type == 'file' or false)
  history_buffer.open(vim.tbl_extend('force', opts or {}, {
    cwd = repo,
    path = rel,
    path_display = path,
    rev = source.commit,
    is_file = is_file,
    line_range = opts.line_range,
    hide_stats = opts.line_range ~= nil,
    replaced = not source.commit and history.is_replaced_path(repo, rel),
    follow = is_file and not opts.line_range,
  }))
end

-- git's empty tree. Diffing against it is how you show a root commit, which
-- has no parent for the usual <hash>^ to resolve to.
local EMPTY_TREE = '4b825dc642cb6eb9a060e54bf8d69288fbee4904'

local RANGE_PANES = {
  guitlog = 'guit.ui.buffer',
  guithistory = 'guit.ui.history_buffer',
}

--- Turns a line range in a log or history pane into a revision range.
---
--- The selection is inclusive: selecting three commits shows all three, so the
--- older end is widened to its parent. git's own `a..b` excludes `a`, which is
--- a common source of "where did my commit go".
---@param line1 integer
---@param line2 integer
---@return string|nil left
---@return string|nil right
---@return string|nil cwd the pane's repository, which need not be Neovim's cwd
local function range_to_revisions(line1, line2)
  local bufnr = vim.api.nvim_get_current_buf()
  local module = RANGE_PANES[vim.bo[bufnr].filetype]
  if not module then
    return nil, nil, nil
  end

  local items, cwd = require(module).items_in_range(bufnr, line1, line2)
  if #items == 0 then
    return nil, nil, nil
  end

  -- The log reads newest first, so the first selected line is the newer end.
  local newest = items[1]
  local oldest = items[#items]
  local left = (oldest.parents and #oldest.parents == 0)
      and EMPTY_TREE
      or (oldest.hash .. '^')

  return left, newest.hash, cwd
end

--- Splits the revision arguments of `:Guit compare`.
---
--- Three-dot must be tried before two-dot: matching `..` first against
--- "main...feature" yields "main" and ".feature", because the non-greedy left
--- side stops at the earliest pair of dots.
---@param first string|nil
---@param second string|nil
---@return string|nil left
---@return string|nil right
---@return boolean symmetric true when the user asked for merge-base comparison
function M.parse_compare_args(first, second)
  if not first or first == '' then
    return nil, nil, false
  end

  if second and second ~= '' then
    return first, second, false
  end

  local a, b = first:match('^(.-)%.%.%.(.+)$')
  if a and a ~= '' then
    return a, b, true
  end

  a, b = first:match('^(.-)%.%.(.+)$')
  if a and a ~= '' then
    return a, b, false
  end

  return first, nil, false
end

function M.compare(left, right, opts)
  opts = opts or {}
  if not left or left == '' then
    vim.notify('guit.nvim: usage :Guit compare <left_rev> <right_rev>', vim.log.levels.INFO)
    return
  end
  -- A single revision compares it against the working tree, which is what git
  -- itself does for `git diff <rev>`.
  if not right or right == '' then
    right = ''
    opts = vim.tbl_extend('force', opts, { symmetric = false })
  end

  local cwd = opts.cwd or vim.uv.cwd()
  local repo, err = git.repo_root(cwd)
  if not repo then
    vim.notify('guit.nvim: ' .. err, vim.log.levels.ERROR)
    return
  end

  compare_buffer.open(vim.tbl_extend('force', opts, { cwd = repo, left = left, right = right, symmetric = opts.symmetric }))
end

function M.status(opts)
  opts = opts or {}
  local cwd = opts.cwd or vim.uv.cwd()
  local repo, err = git.repo_root(cwd)
  if not repo then
    vim.notify('guit.nvim: ' .. err, vim.log.levels.ERROR)
    return
  end
  status_buffer.open(vim.tbl_extend('force', opts, { cwd = repo }))
end

function M.blame(path, opts)
  opts = opts or {}
  if not path or path == '' then
    path = '%'
  end

  local source, expand_err = expand_current_buffer_path(path)
  if not source then
    vim.notify('guit.nvim: ' .. expand_err, vim.log.levels.WARN)
    return
  end
  path = source.path
  if not path or path == '' then
    vim.notify('guit.nvim: current buffer does not point to a file', vim.log.levels.WARN)
    return
  end

  local cwd = opts.cwd or source.cwd or vim.uv.cwd()
  local repo, err = git.repo_root(cwd)
  if not repo then
    vim.notify('guit.nvim: ' .. err, vim.log.levels.ERROR)
    return
  end

  local rel = history.normalize_path(repo, path)
  blame_buffer.open(vim.tbl_extend('force', opts, {
    cwd = repo,
    path = rel,
    rev = source.commit,
    target_bufnr = vim.api.nvim_get_current_buf(),
  }))
end

function M.toggle()
  session.toggle(function()
    M.log()
  end)
end

--- Draws the diff of the current buffer against a revision over the buffer
--- itself; the same command again takes it down.
---
--- Without a revision a working tree file is compared against the index,
--- which is `git diff`, and a fugitive object against its parent, which is
--- what the commit did to the file.
---@param rev string|nil
function M.inline(rev)
  local inline_diff = require('guit.ui.inline_diff')
  local bufnr = vim.api.nvim_get_current_buf()
  local winid = vim.api.nvim_get_current_win()

  if (not rev or rev == '') and inline_diff.is_attached(bufnr) then
    inline_diff.detach(bufnr)
    return
  end

  local source, expand_err = current_buffer_source()
  if not source then
    vim.notify('guit.nvim: ' .. expand_err, vim.log.levels.WARN)
    return
  end
  if not source.path or source.path == '' then
    vim.notify('guit.nvim: current buffer does not point to a file', vim.log.levels.WARN)
    return
  end

  local repo, err = git.repo_root(source.cwd or vim.fn.fnamemodify(source.path, ':p:h'))
  if not repo then
    vim.notify('guit.nvim: ' .. err, vim.log.levels.ERROR)
    return
  end

  local rel = history.normalize_path(repo, source.path)
  -- A base Guit picked itself may simply not exist: a root commit has no
  -- parent, an untracked file has no index entry. That is an all-new file,
  -- not an error. A base the user typed is theirs to get right.
  local derived = not rev or rev == ''
  if derived then
    rev = source.commit and (source.commit .. '^') or ':0'
  end

  -- `:Guit inline HEAD~1` then `:Guit inline HEAD`: whichever git show returns
  -- last must not win. The token also dies with any detach in between.
  local token = inline_diff.begin_request(bufnr)

  vim.system({ 'git', '--no-pager', 'show', ('%s:%s'):format(rev, rel) }, {
    cwd = repo, text = true,
  }, function(result)
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(bufnr) or not inline_diff.request_is_current(bufnr, token) then
        return
      end
      local lines
      if result.code ~= 0 then
        local stderr = (result.stderr or ''):gsub('%s+$', '')
        -- The path not existing at that revision is not an error: the whole
        -- file is new relative to it. Anything else is.
        local missing = derived
          or stderr:find('does not exist', 1, true)
          or stderr:find('exists on disk, but not in', 1, true)
        if not missing then
          vim.notify('guit.nvim: ' .. (stderr ~= '' and stderr or 'git show failed'), vim.log.levels.ERROR)
          return
        end
        lines = {}
      else
        lines = vim.split(result.stdout or '', '\n', { plain = true })
        if #lines > 0 and lines[#lines] == '' then
          lines[#lines] = nil
        end
      end
      local label = ('%s:%s'):format(rev, rel)
      local count = inline_diff.attach(bufnr, { old_lines = lines, label = label, winid = winid })
      if count == 0 then
        vim.notify('guit.nvim: no differences against ' .. label, vim.log.levels.INFO)
      end
    end)
  end)
end

function M.command(args, opts)
  opts = opts or {}
  local sub = args[1]
  local range_opts = nil
  if opts.range and opts.range > 0 then
    local start_line = math.min(opts.line1, opts.line2)
    local finish_line = math.max(opts.line1, opts.line2)
    range_opts = { line_range = { start = start_line, finish = finish_line } }
  end

  if sub == 'toggle' then
    return M.toggle()
  elseif sub == 'log' then
    return M.log(args[2])
  elseif sub == 'show' then
    return M.show(args[2])
  elseif sub == 'history' then
    return M.history(table.concat(vim.list_slice(args, 2), ' '), range_opts)
  elseif sub == 'compare' then
    -- A range wins over arguments: `V j :Guit compare` should not need any.
    if opts.range and opts.range > 0 and not args[2] then
      local left, right, cwd = range_to_revisions(opts.line1, opts.line2)
      if not left then
        vim.notify('guit.nvim: no commits selected', vim.log.levels.WARN)
        return
      end
      return M.compare(left, right, { cwd = cwd })
    end
    local left, right, symmetric = M.parse_compare_args(args[2], args[3])
    return M.compare(left, right, { symmetric = symmetric })
  elseif sub == 'status' then
    return M.status()
  elseif sub == 'blame' then
    return M.blame(table.concat(vim.list_slice(args, 2), ' '))
  elseif sub == 'inline' then
    return M.inline(args[2])
  end

  vim.notify('guit.nvim: usage :Guit toggle | :Guit log [rev] | :Guit show <rev> | :Guit history <path> | :Guit compare <left_rev> <right_rev> | :Guit status | :Guit blame | :Guit inline [rev]', vim.log.levels.INFO)
end

return M
