# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Highly customized LazyVim-based Neovim configuration with extensive UI customizations, a performance monitoring system, custom keybindings, and specialized plugins for development workflows.

## Architecture & Design Decisions

### Configuration Structure

- `init.lua`: Main entry point — Python path, terminal background sync (OSC 11/111)
- `lua/lib/scoped-grep.lua`: Scoped grep module — grep within open buffers, git changed files, or diff vs any branch/commit (uses snacks.picker)
- `lua/config/options.lua`: **Forces root directory to stay as CWD** (`vim.g.root_spec = { "cwd" }`) — critical, prevents LazyVim from auto-changing directories
- `lua/config/autocmds.lua`: Auto-save on `BufLeave`/`FocusLost` (only normal modifiable file buffers)
- `lua/config/keymaps.lua`: Custom keybindings (see below)
- `lua/config/performance.lua`: Real-time performance monitoring (FPS, event loop latency, input lag, buffer load times) — integrated into lualine statusline with color-coded thresholds (green <20ms / yellow <50ms / red >50ms)
- `lua/config/colors.lua`: Shared color palette used by lualine theming
- `lua/config/lazy.lua`: Plugin manager setup — colorscheme fallback chain: gruvdark → tokyonight → habamax → catppuccin
- `lua/plugins/`: Individual plugin configs (~30 active, 8 deprecated with `.deprecated` suffix — **do not modify deprecated files**)
- `lua/dashboardAnimation.lua`: Triforce animation frames using Braille characters with state management
- `lua/weather.lua`: wttr.in integration with 5-minute cache and async fetch

### Critical Implementation Details

**Dashboard Animation State Management:**

- `shouldPlayAnimation` flag prevents re-animation on buffer switches
- Folding is explicitly disabled for dashboard buffers via multiple autocmds (`FileType`, `BufWinEnter`, `WinEnter`)
- Animation plays once on startup (100ms delay), then stops when dashboard closes or any action is taken
- `lastRenderedFrame` optimization prevents unnecessary dashboard updates

**Terminal Background Sync:**

- Uses OSC 11 (set background) on `UIEnter`/`ColorScheme` events
- Uses OSC 111 (reset background) on `UILeave` event
- Reads `Normal` highlight background color and syncs entire terminal frame to match Neovim theme

**Scoped Grep (`lua/lib/scoped-grep.lua`):**

- Seeker-style `<C-e>` toggle between file picker and grep within scoped file lists (progressive refinement)
- All scopes start in **file picker** mode showing the scoped files, then `<C-e>` toggles to grep (and back)
- `grep_buffers()`: Scope = open listed buffers with on-disk files
- `grep_git_changed()`: Scope = files changed since merge-base with `origin/main`
- `grep_diff()`: Scope = files changed vs user-selected branch/commit (interactive branch picker)
- `grep_files(files, title)`: Generic entry point for any custom file list
- State resets on each invocation — no cross-session leakage
- Multi-select (Tab) in file picker narrows the scope; otherwise all filtered items carry over

**Performance Monitoring System (`lua/config/performance.lua`):**

- FPS counter: 30-sample rolling average, 1s cache
- Event loop latency: measures `vim.schedule` round-trip, 20 samples, 1s interval
- Input lag: tracks `InsertCharPre` → `TextChanged` delta, 15 samples, 100ms throttle
- Buffer load time: `BufReadPre` → `BufReadPost` delta, 10 samples
- All metrics displayed in lualine with color-coded thresholds (green/yellow/red)

**LSP — tsgo (experimental):**

- Uses `tsgo --lsp --stdio` as TypeScript/JavaScript LSP (replaces vtsls, which is explicitly disabled)
- **This is a preview build** — commit note says "will need to be updated to final version"
- vtsls, ruff, and pyright are all disabled

**Buffer Reuse Strategy:**

- `switchbuf = {"useopen", "usetab"}` in `init.lua:6` — reuses existing buffers/tabs when opening files

## Development Commands

### Formatting

```bash
stylua . --config-path=stylua.toml  # 2-space indent, 120 char width
```

### Plugin Management

```bash
:Lazy update          # Update all plugins
:Lazy check           # Check for plugin issues
:Lazy profile         # Profile startup time
nvim --startuptime startup.log  # Detailed startup profiling
```

## Custom Keybindings

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

## Code Style & Conventions

- **Lua**: 2-space indentation, 120 character line width (enforced by `stylua.toml`)
- **Plugin configs**: Each plugin in separate file under `lua/plugins/`
- **Naming**: Snake case for files, camelCase for Lua functions
- **Comments**: Minimal, focus on "why" not "what"

## Plugin Ecosystem

**Core UI:**

- `snacks.nvim`: Dashboard (with Triforce animation), fullscreen picker, profiler
- `lualine.nvim`: Dual-bar statusline — top: date/buffers/tabs, bottom: git/diagnostics/performance metrics
- `gruvdark`: Primary theme (colorscheme fallback chain defined in `lua/config/lazy.lua`)

**File Management:**

- `yazi.nvim`: Terminal file manager integration
- `hbac.nvim`: Automatic buffer cleanup (threshold: 8 buffers)

**Git:**

- `mini.diff`: Inline git change indicators (integrated into lualine statusline)
- Note: `diffview.nvim` is deprecated — mini.diff is the active replacement

**Search & Navigation:**

- `snacks.picker`: Fullscreen fuzzy finder (uses ripgrep/fd)
  - Custom grep args: `--hidden`, `--follow`, `--multiline`
  - Excludes: `.git`, `node_modules`, `*.lock`
- `seeker.nvim`: Find-then-grep workflow with `<C-e>` toggle for progressive refinement (`<leader>fa/ff/fg/fw`)
- `lua/lib/scoped-grep.lua`: Git-aware scoped grep — grep within buffers, changed files, or cross-branch diffs

**TypeScript:**

- `pretty-ts-errors`: Prettifies TypeScript diagnostic messages (requires `npm install` build step)
- `tsgo` LSP (see LSP section above)

## Important Behavioral Notes

- **Root directory never auto-changes** due to `vim.g.root_spec = { "cwd" }` — use `<leader>ba` to manually change if needed
- **Dashboard animation only plays once** on startup to avoid performance issues
- **Auto-save only affects normal files** — special buffers, readonly, and unnamed buffers excluded
- **Weather displays fallback immediately** — real data updates asynchronously without blocking startup
- **Deprecated plugins (8 files)** are kept for reference but should not be activated or modified
- **Performance metrics in statusline** may show 0 until enough samples are collected after startup
