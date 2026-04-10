# Custom Keybindings

**Buffer & Directory Management:**

- `<leader>ba`: Set buffer directory as CWD
- `<leader>b.`: Open previous buffer in other window/split (creates vsplit if no other window exists) — has a TODO to fix consistency
- `<leader>f.`: Copy relative file path to clipboard

**Scoped Grep (Search group — all support `<C-e>` file/grep toggle):**

- `<leader>sB`: Scoped grep open buffers (overrides LazyVim's grep_buffers with toggle-enabled version)
- `<leader>sa`: Scoped grep git changed files vs origin/main (overrides LazyVim's Autocmds picker)
- `<leader>sd`: Scoped grep diff vs any branch/commit (overrides LazyVim's Diagnostics picker)

**Diagnostics:**

- `<leader>dd`: Show pretty TypeScript errors for current line (pretty-ts-errors plugin)

**Window Navigation & Resizing:**

- `w + <Arrow Keys>`: Navigate between windows
- `<C-h/j/k/l>`: Commented out — conflicts with vim-tmux-navigator (tmux handles these instead)
- `<leader>w+/-`: Resize window height by 20 lines
- `<leader>w</>`: Resize window width by 20 columns

**Code Navigation:**

- `]1` / `[1`: Jump to next/previous top-level code block (searches for `^[a-zA-Z_]` pattern)
