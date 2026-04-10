# Implementation Details

Deep implementation notes for specific modules. Read this when working on the relevant subsystem.

## Dashboard Animation State Management

- `shouldPlayAnimation` flag prevents re-animation on buffer switches
- Folding is explicitly disabled for dashboard buffers via multiple autocmds (`FileType`, `BufWinEnter`, `WinEnter`)
- Animation plays once on startup (100ms delay), then stops when dashboard closes or any action is taken
- `lastRenderedFrame` optimization prevents unnecessary dashboard updates

## Terminal Background Sync

- Uses OSC 11 (set background) on `UIEnter`/`ColorScheme` events
- Uses OSC 111 (reset background) on `UILeave` event
- Reads `Normal` highlight background color and syncs entire terminal frame to match Neovim theme

## Scoped Grep (`lua/lib/scoped-grep.lua`)

- Seeker-style `<C-e>` toggle between file picker and grep within scoped file lists (progressive refinement)
- All scopes start in **file picker** mode showing the scoped files, then `<C-e>` toggles to grep (and back)
- `grep_buffers()`: Scope = open listed buffers with on-disk files
- `grep_git_changed()`: Scope = files changed since merge-base with `origin/main`
- `grep_diff()`: Scope = files changed vs user-selected branch/commit (interactive branch picker)
- `grep_files(files, title)`: Generic entry point for any custom file list
- State resets on each invocation — no cross-session leakage
- Multi-select (Tab) in file picker narrows the scope; otherwise all filtered items carry over

## Performance Monitoring System (`lua/config/performance.lua`)

- FPS counter: 30-sample rolling average, 1s cache
- Event loop latency: measures `vim.schedule` round-trip, 20 samples, 1s interval
- Input lag: tracks `InsertCharPre` → `TextChanged` delta, 15 samples, 100ms throttle
- Buffer load time: `BufReadPre` → `BufReadPost` delta, 10 samples, cached per buffer

All metrics displayed in lualine with color-coded thresholds (green/yellow/red). Metrics progressively hide at narrow widths: buffer load drops at <160 cols, input lag at <140, latency at <120, FPS at <100.

## LSP — tsgo (experimental)

- Uses `tsgo --lsp --stdio` as TypeScript/JavaScript LSP (replaces vtsls, which is explicitly disabled)
- **This is a preview build** — commit note says "will need to be updated to final version"
- vtsls, ruff, and pyright are all disabled

## Neovim Bridge (`scripts/nvim_bridge.py`)

- Python CLI that connects to a running Neovim via socket (pynvim)
- Socket discovery: `$NVIM_LISTEN_ADDRESS` → `/tmp/nvim-server.pipe` → `$NVIM` → sibling tmux pane auto-detection
- Commands: `open`, `open_many`, `harpoon_add/list`, `mark`, `trail`, `kulala/kulala_gen`, `scoped_grep`, `buffers`, `cursor`, `state`, `exec`, `cmd`
- Used by the Claude Code `/nvim-bridge` skill to stage files, drop marks, and query editor state from agent context

## Sidekick (`lua/plugins/sidekick.lua`)

- `sidekick.nvim` integration for Claude Code as an in-editor AI assistant
- Uses tmux mux backend with vertical split (50% width)
- Auto-creates/attaches to a Claude session without picker prompt
- Supports sending context: current buffer (`{this}`), file (`{file}`), all buffers (`{buffers}`), visual selection (`{selection}`)

## Buffer Reuse Strategy

- `switchbuf = {"useopen", "usetab"}` in `init.lua:6` — reuses existing buffers/tabs when opening files
