local M = {}

M.defaults = {
  page_size_factor = 3,
  prefetch_threshold_factor = 1,
  max_subject_width = 72,
  date_format = '%Y-%m-%d %H:%M',
  layout = {
    mode = 'split',
    position = 'botright',
    height = 0.28,
    min_height = 10,
    title = ' Guit log ',
  },
  keymaps = {
    open = '<CR>',
    split = 'o',
    focus_target = '<Tab>',
    refresh = 'r',
    close = 'q',
    toggle_view = 't',
    collapse = 'h',
    expand = 'l',
    collapse_all = 'H',
    expand_all = 'L',
    help = '?',
    open_show = 's',
    back = '-',
  },
  show = {
    default_view = 'tree',
    show_counts = true,
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
  },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), opts or {})
end

return M
