# Custom Keybindings

**Buffer & Directory Management:**

- `<leader>ba`: Set buffer directory as CWD
- `<leader>b.`: Open previous buffer in other window/split (creates vsplit if no other window exists) — has a TODO to fix consistency
- `<leader>f.`: Copy relative file path to clipboard

**Scoped Grep (Search group — all support `<C-e>` file/grep toggle):**

- `<leader>sB`: Scoped grep open buffers (overrides LazyVim's grep_buffers with toggle-enabled version)
- `<leader>sa`: Scoped grep git changed files vs origin/main (overrides LazyVim's Autocmds picker)
- `<leader>sd`: Scoped grep diff vs any branch/commit (overrides LazyVim's Diagnostics picker)

**Cockpit (`lua/cockpit/inbox/`, agents post via `scripts/cockpit_inbox.py`, pipelines via `--stage`):**

- `<leader>ka` / `:Cockpit [id]`: one tab, three fixed windows — runs rail (left) · workspace (deliverable) · thread (bottom). `<leader>kz` hide/show rail · `<leader>kr` focus rail
- Rail: `<CR>` load run · `a` archive · `u` unread · `g.` show archived · `R` refresh · `q` close cockpit. Pipeline runs show a stage strip `●─◉─○` and `stage rN`
- Workspace (markdown is editable; edits are diffed against what was sent and go out with the reply): `ga` note (normal/visual) · `gD` delete note · `]a`/`[a` notes · `]d`/`[d` next/prev deliverable · `gp` vs previous round (CodeDiff) · `gR` revert edits · `gS` sent vs current file · `gA` approve · `gN` +notes · `gC` changes · `gX` reject · `gr` reply
- Codediff deliverable: `<CR>` review in CodeDiff (own tab; edit the right side, never the agent's worktree) · `gR` reset edits · `q` rail
- Thread: `A` approve (with notes/edits if any) · `N` +notes · `C` changes · `X` reject · `r` reply · `1`–`9` pick option · `<CR>` open file / pick · `]f`/`[f` files · `q` rail · composer `:w` sends
- Agents (herdr, `lua/cockpit/herdr.lua`): rail `s` spawn into a project · `A` agent picker (attach/interrupt/kill/prompt) · on a run: `X` kill its agent (confirm) · `i` interrupt · `gt` attach (tmux window). Rail glyph = the run's agent: `◐` working · `⚠` blocked · `○` idle · `✕` offline
- `:CockpitSpawn [project]` · `:CockpitAgent` · `:CockpitProject new|edit [name]` (projects: `~/.cockpit/projects/<name>.json`, first repo = primary, rest = `--add-dir`)
- `<leader>kb` / `:InboxBoard`: manual card board (legacy)

**Diagnostics:**

- `<leader>dd`: Show pretty TypeScript errors for current line (pretty-ts-errors plugin)

**Window Navigation & Resizing:**

- `w + <Arrow Keys>`: Navigate between windows
- `<C-h/j/k/l>`: Commented out — conflicts with vim-tmux-navigator (tmux handles these instead)
- `<leader>w+/-`: Resize window height by 20 lines
- `<leader>w</>`: Resize window width by 20 columns

**Code Navigation:**

- `]1` / `[1`: Jump to next/previous top-level code block (searches for `^[a-zA-Z_]` pattern)
