# guit.nvim

A lightweight Git log and commit browser for Neovim, built as a thin layer on top of Fugitive.

## Features

- `:Guit log [rev]` opens a paged git log in a bottom pane
- `:Guit show <commit>` opens changed files for a commit in a bottom pane
- `:Guit history <path>` opens file or directory history in a bottom pane
- `:Guit compare <left> <right>` compares two revisions in a bottom pane
- `:Guit blame` opens block-based blame in a left pane and follows the focused file window
- `:Guit toggle` closes and restores the last Guit pane
- Read-only UI buffers for log, show, history, and compare panes
- Tree or list mode for changed files, with live toggling
- Tree folding with `h` / `l`, `H` / `L`, and extra `z*` motions inspired by Vim folds
- Commit metadata header in `Guit show` with hash, author, refs, title, and body
- `<CR>` opens the selected commit or file in Fugitive while keeping focus in the lower pane
- `s` from `Guit log` or `Guit history` opens `Guit show` in the same lower pane and `-` returns to the originating pane
- `<C-o>` in the opened Fugitive buffer jumps back to the originating Guit pane
- `%` in `Guit show %` and `Guit history %` understands Fugitive object buffers
- English Vim help in `:help guit`

## Requirements

- Neovim with `vim.system()` support
- `tpope/vim-fugitive`

## Setup

```lua
require('guit').setup({
  show = {
    default_view = 'tree', -- or 'list'
  },
  blame = {
    mode = 'color', -- color, plain, or heat
    width = 48,
  },
})
```

## Commands

- `:Guit toggle`
- `:Guit log [rev]`
- `:Guit show <rev>`
- `:Guit show %`
- `:Guit history <file-or-directory>`
- `:Guit history %`
- `:Guit compare <left_rev> <right_rev>`
- `:Guit compare <left_rev>..<right_rev>`
- `:Guit blame`

`:Guit toggle` closes an open Guit pane. If no Guit pane is open, it restores the last Guit view; before any prior view, it opens `:Guit log`.

From a Fugitive object buffer, `:Guit show %` opens `Guit show` for that object's commit. `:Guit history %` uses that object's file path and starts history at that object's commit. From a normal file buffer, `:Guit history %` uses the current buffer's file path.

## Keymaps

Shared pane keymaps:

- `<CR>` open in target window and keep focus in the pane
- `o` open and move focus to target window
- `<Tab>` jump to the target window
- `r` refresh
- `q` close pane
- `?` show a short help message

Log pane:

- `s` open `Guit show` for the current commit in the same lower pane

Show and compare panes:

- `t` toggle tree/list
- `h` / `l` collapse or expand around the current location
- `H` / `L` collapse or expand the current subtree
- `[z` jump to the parent directory
- `zP` jump to the top-level ancestor in the current branch
- `zj` / `zk` jump to the next / previous sibling entry
- `zM` / `zR` collapse / expand the whole tree

Show pane:

- `-` or `<BS>` return to the originating log or history pane when available

History pane:

- `c` open the selected commit in Fugitive and keep focus in history
- `C` open the selected commit in Fugitive and move focus to the target window
- `s` open `Guit show` for the selected commit in the same lower pane

Blame pane:

- `<CR>` open the file at the blamed revision in the target window
- `<C-o>` restore the previous target buffer opened before blame `<CR>`
- `c` open the blamed Fugitive commit and keep focus in blame
- `C` open the blamed Fugitive commit and move focus to the target window
- `s` open `Guit show` for the blamed commit
- `t` cycle blame mode: `color`, `plain`, `heat`

## Help

The plugin generates help tags on load. Run `:help guit` after adding it to your runtimepath.

## Architecture

Changed-files data loading and tree/list transformation live in `lua/guit/changed_files.lua`.
That module is intentionally separate from the UI layer so it can be reused by future views.


## Guit show change counts

`Guit show <commit>` displays per-file and per-directory `+added/-deleted`
counts by default. Disable it with:

```lua
require('guit').setup({
  show = {
    show_counts = false,
  },
})
```


## Compare revisions

```vim
:Guit compare main feature
:Guit compare main..feature
```

This opens a bottom compare pane similar to `Guit show`, with tree/list views,
change counts, and Fugitive diff opening for the selected file between the two
revisions.

## Blame

```vim
:Guit blame
```

`Guit blame` opens a narrow blame buffer to the left of the current file. The blame and target windows use `scrollbind` and `cursorbind`, so scrolling either window keeps the other aligned. While the blame pane is open, focusing another normal file or Fugitive file object retargets blame to that buffer.

Blame is rendered as blocks: the first line of each consecutive commit block shows hash, author, summary, and date; following lines in the same block show a continuation marker. Modes keep the normal window background and color the hash plus block marker:

- `color` gives each commit hash a stable color
- `plain` uses the regular Guit hash styling
- `heat` colors older-to-newer lines from cool to warm


## Command-line completion

`Guit show`, `Guit log`, and `Guit compare` complete local branches, remote branches, tags, and `HEAD`. `Guit show` and `Guit history` also complete `%` where supported.

## File status colors

Changed-file statuses are color-coded in tree and list views:

- `M` modified
- `A` added
- `D` deleted
- `R` renamed
- `C` copied


## Guit history

```vim
:Guit history <file-or-directory>
:Guit history %
```

Shows commits that touched the given file or directory in a lower pane. The compact stats column uses `<files>f <additions> <deletions>`.

For file history, `<CR>` opens the file diff for the selected commit. Rename commits use the old path on the parent side and the new path on the commit side. History rows include a file-action prefix such as `[M]`, `[A]`, or `[R old/path -> new/path]`.
