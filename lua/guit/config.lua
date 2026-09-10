local M = {}

M.defaults = {
  page_size_factor = 3,
  prefetch_threshold_factor = 1,
  date_format = '%Y-%m-%d %H:%M',
  layout = {
    mode = 'split',
    position = 'botright',
    height = 0.28,
    min_height = 10,
    title = ' Guit log ',
  },
  -- Keys are resolved through lua/guit/keymaps.lua, which also carries each
  -- action's description and generates the g? help. Set any action to false to
  -- leave the key to Vim.
  keymaps = {
    open = '<CR>',
    open_focus = 'o',
    open_diff = 'dd',
    open_diff_inline = 'di',
    open_diff_split = 'ds',
    open_show = 's',
    commit = 'c',
    commit_focus = 'C',
    focus_target = '<Tab>',
    back = '-',
    refresh = 'r',
    close = 'q',
    help = 'g?',
    toggle_view = 't',
    collapse = 'h',
    expand = 'l',
    collapse_subtree = 'H',
    expand_subtree = 'L',
    collapse_tree = 'zM',
    expand_tree = 'zR',
    jump_parent = '[z',
    jump_top = 'zP',
    jump_next = 'zj',
    jump_prev = 'zk',
    yank_hash = 'y<C-G>',
    cmdline = '.',
    -- Guit status only
    stage = 's',
    unstage = 'u',
    stage_toggle = '-',
    discard = 'X',
    -- Inside a buffer showing an inline diff
    hunk_next = ']c',
    hunk_prev = '[c',
    -- Inside fugitive's own buffers
    fugitive_inline = 'di',
  },
  -- How dd opens a file diff: 'split' is fugitive's side-by-side vimdiff,
  -- 'inline' draws the old side over the new one in a single buffer.
  diff = {
    mode = 'split', -- split | inline
    signs = true, -- +, ~ and - in the sign column of an inline diff
    word_diff = true, -- highlight the characters that differ within a changed line
    syntax = true, -- colour removed lines with the old side's treesitter highlights
  },
  show = {
    default_view = 'tree',
    show_counts = true,
  },
  blame = {
    mode = 'color', -- color | plain | heat
    width = 60,
  },
  git = {
    pretty = table.concat({
      '%H',
      '%h',
      '%an',
      '%ad',
      '%D',
      '%s',
    }, '%x1f'),
  },
  highlights = {
    hash = 'GuitHash',
    date = 'GuitDate',
    author = 'GuitAuthor',
    refs = 'GuitRefs',
    subject = 'GuitSubject',
    file = 'GuitFile',
    dir = 'GuitDir',
    status = 'GuitStatus',
    cursorline = 'GuitCursorLine',
    title = 'GuitTitle',
    loading = 'GuitLoading',
    counter = 'GuitCounter',
    selected = 'GuitSelected',
    additions = 'GuitAdditions',
    deletions = 'GuitDeletions',
    status_modified = 'GuitStatusModified',
    status_added = 'GuitStatusAdded',
    status_deleted = 'GuitStatusDeleted',
    status_renamed = 'GuitStatusRenamed',
    status_copied = 'GuitStatusCopied',
    status_staged = 'GuitStatusStaged',
    status_unstaged = 'GuitStatusUnstaged',
    status_untracked = 'GuitStatusUntracked',
    status_conflicts = 'GuitStatusConflicts',
    diff_add = 'GuitDiffAdd',
    diff_add_text = 'GuitDiffAddText',
    diff_delete = 'GuitDiffDelete',
    diff_delete_text = 'GuitDiffDeleteText',
    diff_sign_add = 'GuitDiffSignAdd',
    diff_sign_change = 'GuitDiffSignChange',
    diff_sign_delete = 'GuitDiffSignDelete',
  },
  revisions = {
    include_head = true,
  },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), opts or {})
end

return M
