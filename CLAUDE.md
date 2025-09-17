# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a highly customized LazyVim-based Neovim configuration with extensive UI customizations, custom keybindings, and specialized plugins for development workflows.

## Key Architecture Components

### Configuration Structure

- `init.lua`: Main entry point with Python path setup, custom grep function, and terminal background sync
- `lua/config/`: Core LazyVim configuration overrides
  - `lazy.lua`: Lazy.nvim plugin manager setup
  - `keymaps.lua`: Custom keybindings (window navigation, buffer management)
  - `options.lua`: Forces root directory to stay as CWD
  - `autocmds.lua`: Auto-commands for various behaviors
- `lua/plugins/`: Individual plugin configurations (50+ plugins)
- `lua/dashboardAnimation.lua`: Custom animated dashboard with Triforce animation
- `lua/weather.lua`: Weather integration for dashboard

### Core Plugin Ecosystem

- **UI Framework**: Snacks.nvim with custom dashboard, picker, and profiler
- **Status Line**: Heavily customized lualine with git diff symbols, repository info, and dual-bar layout
- **File Management**: Yazi file manager integration, custom buffer management (HBAC)
- **Search & Navigation**: Enhanced picker with fullscreen layout, ripgrep integration
- **Git Integration**: Mini-diff for inline changes, diffview for comprehensive diffs
- **Development Tools**: LSP configurations, obsidian notes, recall for AI assistance

### Custom Features

- **Animated Dashboard**: Custom Triforce animation that plays on startup
- **Enhanced Git Workflow**: Custom grep function for changed files (`<leader>ga`)
- **Advanced Window Management**: Custom keybinds for splits and navigation
- **Terminal Background Sync**: Matches terminal background to Neovim theme
- **Dual-Status Layout**: Top bar shows date/buffers/tabs, bottom shows git/diagnostics

## Development Commands

### Formatting & Linting

```bash
# Format Lua files
stylua . --config-path=stylua.toml

# Check Lua syntax (if luacheck is installed)
luacheck lua/
```

### Testing Configuration

```bash
# Test configuration in isolated environment
nvim --clean -c "set rtp+=." -c "runtime plugin/plenary.vim" -c "PlenaryBustedDirectory test/"
```

### Plugin Management

```bash
# Update plugins
nvim -c "Lazy update" -c "qa"

# Profile startup time
nvim --startuptime startup.log
```

## Custom Keybindings

- `<leader>ba`: Set buffer directory as CWD
- `<leader>ga`: Grep in git changed files with picker
- `<leader>b.`: Open previous buffer in other window/split
- `<leader>f.`: Copy relative file path to clipboard
- `w + arrow keys`: Navigate between windows
- `]1` / `[1`: Jump to next/previous top-level code block

## Code Style

- **Lua**: 2-space indentation, 120 character line width (stylua.toml)
- **Plugin configs**: Each plugin in separate file under `lua/plugins/`
- **Naming**: Snake case for files, camelCase for Lua functions
- **Comments**: Minimal, focus on "why" not "what"

## Important Notes

- Root directory management is forced to stay as CWD (`vim.g.root_spec = { "cwd" }`)
- Python path is hardcoded to specific system installation
- Dashboard animation state must be managed when switching between dashboard and other buffers
- Many deprecated plugins exist with `.deprecated` suffix - these should not be activated
- Custom MRU buffer tracking implemented in `lua/mru_buffers.lua`
