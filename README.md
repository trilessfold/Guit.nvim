# guit.nvim

A lightweight Git log and commit browser for Neovim, built as a thin layer on top of Fugitive.

## Features

- `:Guit log [rev]` opens a paged git log in a bottom pane
- `:Guit show <commit>` opens changed files for a commit in a bottom pane
- Read-only UI buffers for both log and show panes
- Tree or list mode for changed files, with live toggling
- Tree folding with `h` / `l`, `H` / `L`, and extra `z*` motions inspired by Vim folds
- Commit metadata header in `Guit show` with hash, author, refs, title, and body
- `<CR>` opens the selected commit or file in Fugitive while keeping focus in the lower pane
- `s` from `Guit log` opens `Guit show` in the same lower pane and `-` returns to the same log position
- `<C-o>` in the opened Fugitive buffer jumps back to the originating Guit pane
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
})
```

## Commands

- `:Guit log [rev]`
- `:Guit show <rev>`

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

Changed files pane:

- `-` or `<BS>` return to the originating log pane when available
- `t` toggle tree/list
- `h` / `l` collapse or expand around the current location
- `H` / `L` collapse or expand the current subtree
- `[z` jump to the parent directory
- `zP` jump to the top-level ancestor in the current branch
- `zj` / `zk` jump to the next / previous sibling entry
- `zM` / `zR` collapse / expand the whole tree

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


## Command-line completion

`Guit compare` completes local branches, remote branches, tags, and `HEAD`.

## File status colors

Changed-file statuses are color-coded in tree and list views:

- `M` modified
- `A` added
- `D` deleted
- `R` renamed
- `C` copied
