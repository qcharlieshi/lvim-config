# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a highly customized LazyVim-based Neovim configuration with extensive UI customizations, custom keybindings, and specialized plugins for development workflows.

## Key Architecture Components

### Configuration Structure

- `init.lua`: Main entry point with Python path setup, custom grep function (`GrepChangedFilesWithPicker`), and terminal background sync (OSC 11/111 escape codes)
- `lua/config/`: Core LazyVim configuration overrides
  - `lazy.lua`: Lazy.nvim plugin manager setup
  - `keymaps.lua`: Custom keybindings (window navigation, buffer management)
  - `options.lua`: Forces root directory to stay as CWD (`vim.g.root_spec = { "cwd" }`)
  - `autocmds.lua`: Auto-save on `BufLeave`/`FocusLost` for normal modifiable buffers
- `lua/plugins/`: Individual plugin configurations (38 total, 8 deprecated)
- `lua/dashboardAnimation.lua`: Custom Triforce animation using Braille characters with state management
- `lua/weather.lua`: Weather integration via wttr.in API with 5-minute cache and fallback handling

### Core Plugin Ecosystem

- **UI Framework**: Snacks.nvim powers dashboard (with animation), picker (fullscreen), and profiler
- **Status Line**: Dual-bar lualine layout (top: date/buffers/tabs, bottom: git/diagnostics with mini-diff symbols)
- **File Management**: Yazi integration for terminal file manager, HBAC for intelligent buffer auto-close
- **Search & Navigation**: Snacks picker using ripgrep/fd with fullscreen layout
- **Git Integration**: Mini-diff for inline change indicators, diffview for comprehensive diffs
- **Development Tools**: LSP configs, obsidian notes integration, recall for AI assistance

### Critical Implementation Details

1. **Dashboard Animation State**: `shouldPlayAnimation` flag in `dashboardAnimation.lua` prevents re-animation on buffer switches. Folding is explicitly disabled for dashboard buffers via window/buffer options.

2. **Terminal Background Sync**: Uses OSC 11 (set background) and OSC 111 (reset) escape codes on `UIEnter`/`ColorScheme` and `UILeave` events to match terminal background to Neovim theme.

3. **Custom Grep Function**: `GrepChangedFilesWithPicker()` in `init.lua` finds merge-base with origin/main, greps only changed files, presents results via `vim.ui.select` (overridden by Snacks).

4. **Buffer Reuse**: `switchbuf = {"useopen", "usetab"}` makes Neovim intelligently reuse existing buffers/tabs when opening files.

5. **Weather Integration**: Non-blocking async fetch with 5-minute cache, immediate fallback display, updates dashboard after fetch completes.

6. **Deprecated Plugins**: 8 plugins have `.deprecated` suffix - these should not be activated or modified.

## Development Commands

### Formatting & Linting

```bash
# Format Lua files (2-space indent, 120 char width)
stylua . --config-path=stylua.toml

# Check Lua syntax (if luacheck installed)
luacheck lua/
```

### Plugin Management

```bash
# Update plugins
nvim -c "Lazy update" -c "qa"

# Profile startup time
nvim --startuptime startup.log

# Check plugin status
nvim -c "Lazy check"
```

## Custom Keybindings

### Buffer & Directory Management

- `<leader>ba`: Set buffer directory as CWD
- `<leader>b.`: Open previous buffer in other window/split
- `<leader>f.`: Copy relative file path to clipboard

### Git Workflow

- `<leader>ga`: Grep through git changed files (merge-base with origin/main) using Snacks picker

### Window Navigation

- `w + <Arrow Keys>`: Navigate between windows
- `<leader>w+/-/</>`: Resize windows by 20 lines/columns

### Code Navigation

- `]1` / `[1]`: Jump to next/previous top-level code block

## Code Style

- **Lua**: 2-space indentation, 120 character line width (stylua.toml)
- **Plugin configs**: Each plugin in separate file under `lua/plugins/`
- **Naming**: Snake case for files, camelCase for Lua functions
- **Comments**: Minimal, focus on "why" not "what"

## Important Notes

- **Root Directory**: Forced to stay as CWD via `vim.g.root_spec = { "cwd" }` in `options.lua` - prevents LazyVim auto-detection
- **Python Path**: Hardcoded to `/Library/Frameworks/Python.framework/Versions/3.12/bin/python3` in `init.lua:3`
- **Dashboard State**: Animation plays once on startup; state managed via `shouldPlayAnimation` flag
- **Auto-save**: Only triggers for normal modifiable file buffers (not special buffers or readonly)
- **Weather Caching**: 5-minute cache in `weather.lua` reduces wttr.in API calls
- **Deprecated Files**: Do not activate or modify any `*.deprecated` plugin files
