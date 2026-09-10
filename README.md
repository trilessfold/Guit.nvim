# guit.nvim

A lightweight Git log and commit browser for Neovim, built as a thin layer on top of Fugitive.

## Features

- `:Guit log [rev]` opens a paged git log in a bottom pane
- `:Guit show <commit>` opens changed files for a commit in a bottom pane
- `:Guit history <path>` opens file, directory, or selected-line history in a bottom pane
- `:Guit compare <left> <right>` compares two revisions in a bottom pane
- `:Guit status` opens a working tree browser in a bottom pane, with staging
- `:Guit inline [rev]` draws the diff against a revision over the current buffer
- File diffs open side by side in Fugitive or inline in a single buffer, your choice
- `:Guit blame` opens block-based blame in a left pane and follows the focused file window
- `:Guit toggle` closes and restores the last Guit pane
- Read-only UI buffers for log, show, history, compare, and blame panes
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
    width = 60,
  },
  diff = {
    mode = 'split', -- split (Fugitive vimdiff) or inline (single buffer)
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
- `:'<,'>Guit history`
- `:Guit compare <left_rev> <right_rev>`
- `:Guit compare <left_rev>..<right_rev>`
- `:Guit status`
- `:Guit blame`
- `:Guit inline [rev]`

`:Guit toggle` closes an open Guit pane. If no Guit pane is open, it restores the last Guit view; before any prior view, it opens `:Guit log`.

From a Fugitive object buffer, `:Guit show %` opens `Guit show` for that object's commit. `:Guit history %` uses that object's file path and starts history at that object's commit. From a normal file buffer, `:Guit history %` uses the current buffer's file path.

## Keymaps

The same key means the same thing in every pane. Mappings carry a `desc`, and
`g?` lists the ones actually in effect rather than the defaults.

Shared by all panes:

| Key | Action |
|---|---|
| `<CR>` | open the entry under the cursor, keep focus in the pane |
| `o` | open it and move focus to the target window |
| `dd` | open the diff for the entry — `dd` means diff everywhere, in the shape `diff.mode` selects |
| `<Tab>` | jump to the target window |
| `-` | go back to the view this one was opened from |
| `r` | reload the view |
| `q` | close this pane |
| `g?` | show the mappings in effect |
| `y<C-G>` | yank the object under the cursor into a register |
| `.` | put that object on the command line |

Commit panes (`log`, `history`, `blame`):

| Key | Action |
|---|---|
| `c` / `C` | open the commit in Fugitive, keeping / moving focus |
| `s` | open `Guit show` for the commit |
| `dd` | compare the commit against `HEAD` |

File panes (`show`, `compare`, `status`):

| Key | Action |
|---|---|
| `di` | open the diff inline, in a single buffer |
| `ds` | open the diff side by side in Fugitive |
| `t` | switch between tree and list view |
| `h` / `l` | collapse / expand the directory under the cursor |
| `H` / `L` (also `zC` / `zO`) | collapse / expand the whole subtree |
| `zM` / `zR` | collapse / expand the whole tree |
| `[z` | jump to the parent directory |
| `zP` | jump to the top-level directory |
| `zj` / `zk` | jump to the next / previous sibling |

`blame` uses `t` to cycle its mode (`color`, `plain`, `heat`) and `-` to restore
the buffer the target window showed before blame opened one.

Guit does not map `?`, `gg`, `G` or `<C-o>`, and never maps anything into your
own file buffers, so search, motions with counts and the jumplist keep working.
The one exception is `]c` / `[c` while an inline diff is drawn on a buffer, see
below.

### Configuring keys

```lua
require('guit').setup({
  keymaps = {
    open_show = '<leader>S',
    open_diff = false,        -- leave dd to Vim
  },
})
```

Because `filetype` is set after the mappings are installed, an
`after/ftplugin/guitlog.lua` overrides them:

```lua
vim.keymap.set('n', '<CR>', '<Cmd>echo "mine"<CR>', { buffer = 0 })
```

Renamed in this release, old names still accepted for one more: `split` →
`open_focus`, `collapse_all` → `collapse_subtree`, `expand_all` →
`expand_subtree`.

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
:Guit compare main feature      " the two revisions directly
:Guit compare main..feature     " same
:Guit compare main...feature    " feature against the merge base
:Guit compare main              " main against the working tree
```

### Choosing commits

Selecting commits uses Vim's own selection mechanisms rather than a marking
mode of its own. In a `Guit log` or `Guit history` pane:

```vim
V j j :Guit compare             " visual selection
ma  …  mb  :'a,'bGuit compare   " marks, visible in :marks
:.,'aGuit compare
:5,12Guit compare
```

The range is inclusive — every selected commit appears in the diff, unlike
git's own `a..b`, which excludes `a`. Selecting the root commit compares
against the empty tree.

For anything else, `y<C-G>` yanks the full hash and `.` puts the object on the
command line, so `:Git revert`, `:Git cherry-pick`, `:Git rebase -i` and
`:Gdiffsplit` are one keystroke away without Guit implementing any of them.

## Working tree status

```vim
:Guit status
```

`Guit status` opens a working tree browser. It groups files under `Staged`, `Unstaged`, `Untracked`, and `Conflicts` sections and reuses the same tree/list navigation as `Guit show` and `Guit compare`.

`<CR>` opens the working tree file, `dd` opens the Fugitive diff.

### Staging

| Key | Action |
|---|---|
| `s` | stage |
| `u` | unstage |
| `-` | toggle: stage if unstaged, unstage if staged |
| `X` | throw the changes away — asks first, listing what will be lost |

These follow fugitive rather than the plugin's own scheme, so fingers carry
over from `:Git`. It is the one place where `s` and `-` mean something
different from the other panes, and it is where their usual meanings —
"open Guit show", "go back" — have nothing to act on.

Each key acts on the file under the cursor, on every file under a directory or
a section heading, or on every file a visual selection covers:

```vim
s          " stage this file
Vjjs       " stage these three
```

`X` is the only destructive one. On a staged file it resets to `HEAD` in both
the index and the worktree; on an untracked file it deletes the file from disk,
because git has no copy to restore. It always confirms first, naming the files.

Guit does not commit, push, rebase, or stage hunks — use fugitive for those.
`.` puts the path on the command line and `y<C-G>` yanks it.

## Inline diff

```vim
:Guit inline          " current buffer against the index (or a fugitive object against its parent)
:Guit inline main     " against main
:Guit inline          " again: remove the overlay
```

A file diff has two shapes. *Split* is Fugitive's side-by-side vimdiff of two
buffers. *Inline* is one buffer with the changes drawn on top of it, like VS
Code's inline diff view: everything the new side has is green, added and
changed lines alike; removed lines appear red, as virtual lines where they used
to be, in the syntax colours they had; within a changed line the characters
that differ get a stronger green or red. The sign column marks each hunk: `+`
added, `~` changed, `_` a line after which something was removed, `~_` both.
The colours are the backgrounds of your colorscheme's `DiffAdd` and
`DiffDelete` and nothing else, so the code keeps its own colours.

The buffer is the real one — a Fugitive object or the working tree file — so
its filetype, treesitter, gitsigns, LSP and `:Guit blame` all keep working, and
a working tree file stays editable with the overlay following the edits. The
old side is never loaded into a buffer.

Hunks are grouped the same way `:diffthis` and Fugitive's split do: whichever
of 'diffopt's `algorithm:`, `indent-heuristic`, `linematch:`, `iwhite`,
`iwhiteall`, `iwhiteeol` and `iblank` you have set applies here too, instead of
a strategy of Guit's own.

`dd` in the file panes opens the shape `diff.mode` selects; `di` and `ds` pick
one explicitly. Inside the diffed buffer `]c` and `[c` jump between hunks, with
a count, without wrapping. These two keys are the only thing Guit ever maps
into a file buffer: they exist only while the overlay is shown, and a mapping
that was already there (gitsigns' `]c`, say) is put back afterwards. Set
`hunk_next` / `hunk_prev` to `false` to leave the keys alone.

The two shapes are one or the other, never both on the same buffer. `di` after
`ds` (or after fugitive's own `dd` / `ds`) closes the side-by-side windows and
turns `'diff'` off; `ds` after `di`, fugitive's `dd` or a plain `:diffthis`
takes the overlay down.

```lua
require('guit').setup({
  diff = {
    mode = 'inline',    -- split | inline: what dd opens
    signs = true,       -- +, ~, _ and ‾ in the sign column
    word_diff = true,   -- highlight what differs within a changed line
    syntax = true,      -- removed lines in the old side's syntax colours
  },
})
```

`b:guit_inline_diff` holds the object the buffer is compared against while an
overlay is shown, for a statusline.

`di` also works inside fugitive's own buffers, next to fugitive's `dd`, `ds`
and `dv`: in the `:Git` status buffer it opens the file under the cursor as an
inline diff (staged against `HEAD`, unstaged against the index) and moves focus
there like fugitive's `dd`; in a `fugitive://` blob buffer it is `:Guit inline`
against the parent commit. Set `keymaps.fugitive_inline = false` to leave
fugitive's buffers alone.

## Blame

```vim
:Guit blame
```

`Guit blame` opens a narrow blame buffer to the left of the current file. The blame and target windows use `scrollbind` and `cursorbind`, so scrolling either window keeps the other aligned. While the blame pane is open, focusing another normal file or Fugitive file object retargets blame to that buffer.

Blame is rendered as blocks: the first line of each consecutive commit block shows hash, author, and date. Multi-line blocks show the commit summary on the second block line; single-line blocks show the summary as a temporary virtual line when the blame cursor is on that block. Modes keep the normal window background and color the hash plus block marker:

- `color` gives each commit hash a stable color
- `plain` uses the regular Guit hash styling
- `heat` colors older-to-newer lines from cool to warm

When the target window has collapsed folds, the blame pane does not mirror the folds. Instead it keeps the blame cursor visible by nudging only the blame viewport when the cursor approaches the top or bottom edge.


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
:'<,'>Guit history
:'<,'>Guit history %
```

Shows commits that touched the given file or directory in a lower pane. The compact stats column uses `<files>f <additions> <deletions>`.

For file history, `<CR>` opens the file diff for the selected commit. Rename commits use the old path on the parent side and the new path on the commit side. History rows include a file-action prefix such as `[M]`, `[A]`, or `[R old/path -> new/path]`.

With a command range, `Guit history` opens line history for the selected lines in the current file. Line history reuses the same history pane and keymaps, omits the compact stats column, and `<CR>` opens the file revision for the selected commit.
