# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a highly customized LazyVim-based Neovim configuration with extensive UI customizations, custom keybindings, and specialized plugins for development workflows.

## Architecture & Design Decisions

### Configuration Structure

- `init.lua`: Main entry point containing:
  - Python path setup (hardcoded to `/Library/Frameworks/Python.framework/Versions/3.12/bin/python3`)
  - `GrepChangedFilesWithPicker()` function for git-aware searching
  - Terminal background sync using OSC escape codes (OSC 11/111)
- `lua/config/`: Core LazyVim overrides
  - `options.lua`: **Forces root directory to stay as CWD** (`vim.g.root_spec = { "cwd" }`) - this is critical to prevent LazyVim from auto-changing directories
  - `autocmds.lua`: Auto-save on `BufLeave`/`FocusLost` (only for normal modifiable file buffers)
  - `keymaps.lua`: Custom keybindings (see below)
- `lua/plugins/`: Individual plugin configs (multiple active plugins, 8 files with `.deprecated` suffix - **do not modify deprecated files**)
- `lua/dashboardAnimation.lua`: Triforce animation frames using Braille characters with state management
- `lua/weather.lua`: wttr.in integration with 5-minute cache and async fetch

### Critical Implementation Details

**Dashboard Animation State Management:**

- `shouldPlayAnimation` flag in `dashboardAnimation.lua` prevents re-animation on buffer switches
- Folding is explicitly disabled for dashboard buffers via multiple autocmds (`FileType`, `BufWinEnter`, `WinEnter`)
- Animation plays once on startup (100ms delay), then stops when dashboard closes or any action is taken
- `lastRenderedFrame` optimization prevents unnecessary dashboard updates

**Terminal Background Sync:**

- Uses OSC 11 (set background) on `UIEnter`/`ColorScheme` events
- Uses OSC 111 (reset background) on `UILeave` event
- Reads `Normal` highlight background color and syncs entire terminal frame to match Neovim theme

**Custom Git-Aware Grep (`<leader>ga`):**

- Finds merge-base with `origin/main` using `git merge-base HEAD origin/main`
- Runs grep only on changed files since merge-base
- Uses `vim.ui.select` (overridden by Snacks picker) to present results
- Result format: `filename:line:match` - clicking navigates to that line

**Weather Integration:**

- Async fetch using `vim.system` (Neovim 0.10+) with 3-second timeout
- Displays fallback immediately, updates after fetch completes
- 5-minute cache (`M.cache.ttl = 300`) reduces API calls
- `weather_fetch_started` flag prevents duplicate concurrent requests

**Buffer Reuse Strategy:**

- `switchbuf = {"useopen", "usetab"}` in `init.lua:6` - reuses existing buffers/tabs when opening files
- Prevents buffer proliferation and maintains workspace organization

## Development Commands

### Formatting

```bash
stylua . --config-path=stylua.toml  # 2-space indent, 120 char width
```

### Testing & Diagnostics

```bash
nvim --startuptime startup.log  # Profile startup time in detail
nvim --clean -u init.lua        # Test config without existing state
:checkhealth                    # Check Neovim health and plugin status
:LspInfo                        # Check LSP server status
```

### Plugin Management

```bash
:Lazy update          # Update all plugins
:Lazy check           # Check for plugin issues
:Lazy profile         # Profile startup time
:Lazy restore         # Restore plugins from lazy-lock.json
```

## Custom Keybindings

**Dashboard Actions (Snacks Dashboard):**

- `f`: Find file
- `n`: New file
- `g`: Find text (live grep)
- `r`: Recent files
- `c`: Config files
- `s`: Restore session
- `l`: Lazy plugin manager
- `q`: Quit

**Buffer & Directory Management:**

- `<leader>ba`: Set buffer directory as CWD (useful when `root_spec = cwd` but you want to switch context)
- `<leader>b.`: Open previous buffer in other window/split (creates vsplit if no other window exists)
- `<leader>f.`: Copy relative file path to clipboard

**Git Workflow:**

- `<leader>ga`: Grep through git changed files (merge-base with origin/main)

**Window Navigation & Resizing:**

- `w + <Arrow Keys>`: Navigate between windows
- `<C-h/j/k/l>`: Disabled (commented out to avoid conflicts with vim-tmux-navigator)
- `<leader>w+/-`: Resize window height by 20 lines
- `<leader>w</>`: Resize window width by 20 columns

**Code Navigation:**

- `]1` / `[1]`: Jump to next/previous top-level code block (searches for `^[a-zA-Z_]` pattern)

## Code Style & Conventions

- **Lua**: 2-space indentation, 120 character line width (enforced by `stylua.toml`)
- **Plugin configs**: Each plugin in separate file under `lua/plugins/`
- **Naming**: Snake case for files, camelCase for Lua functions
- **Comments**: Minimal, focus on "why" not "what"

## Plugin Ecosystem

**Core UI:**

- `snacks.nvim`: Dashboard (with animation), fullscreen picker, profiler
- `lualine.nvim`: Dual-bar statusline (top: date/buffers/tabs, bottom: git/diagnostics)
- `gruvdark`: Custom theme

**File Management:**

- `yazi.nvim`: Terminal file manager integration
- `hbac.nvim`: Automatic buffer cleanup (intelligent closing of unused buffers)

**Git:**

- `mini.diff`: Inline git change indicators (used in statusline)
- `diffview.nvim`: Comprehensive diff views

**Search & Navigation:**

- `snacks.picker`: Fullscreen fuzzy finder (uses ripgrep/fd)
  - Custom grep args: `--hidden`, `--follow`, `--multiline`
  - Excludes: `.git`, `node_modules`, `*.lock`

## Important Behavioral Notes

- **Root directory never auto-changes** due to `vim.g.root_spec = { "cwd" }` - use `<leader>ba` to manually change if needed
- **Dashboard animation only plays once** on startup to avoid performance issues and visual distractions
- **Auto-save only affects normal files** - special buffers, readonly files, and unnamed buffers are excluded
- **Weather displays fallback immediately** - real weather updates asynchronously without blocking startup
- **Deprecated plugins (8 files)** are kept for reference but should not be activated or modified
