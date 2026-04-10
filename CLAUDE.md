# CLAUDE.md

Highly customized LazyVim-based Neovim configuration with extensive UI customizations, performance monitoring, custom keybindings, and specialized plugins.

## Reference Docs (read on demand)

- [docs/implementation-details.md](docs/implementation-details.md) — Dashboard animation, terminal sync, scoped grep, perf monitoring, LSP/tsgo, nvim bridge, sidekick internals
- [docs/keybindings.md](docs/keybindings.md) — All custom keybinding mappings
- [docs/plugin-ecosystem.md](docs/plugin-ecosystem.md) — Active plugin catalog with descriptions

## Configuration Structure

- `init.lua`: Entry point — Python path, terminal background sync (OSC 11/111), macOS codesign loader
- `lua/config/`: options, autocmds, keymaps, performance, colors, lazy, codesign
- `lua/lib/scoped-grep.lua`: Scoped grep module (grep within buffers, git changed files, or cross-branch diffs)
- `lua/plugins/`: Individual plugin configs (~30 active, 9 deprecated with `.deprecated` suffix)
- `lua/dashboardAnimation.lua`: Triforce animation frames (Braille characters)
- `lua/weather.lua`: wttr.in integration with async fetch
- `scripts/nvim_bridge.py`: Python bridge for Claude Code agents to control Neovim via socket
- `scripts/sign-native-libs.sh`: macOS codesign script for treesitter parsers + blink.cmp

## Code Style

- **Lua**: 2-space indent, 120 char width (`stylua . --config-path=stylua.toml`)
- **Plugin configs**: Each plugin in separate file under `lua/plugins/`
- **Naming**: Snake case for files, camelCase for Lua functions
- **Comments**: Minimal, focus on "why" not "what"

## Dev Commands

```bash
stylua . --config-path=stylua.toml    # Format
:Lazy update / :Lazy check / :Lazy profile  # Plugin management
nvim --startuptime startup.log        # Startup profiling
```

## Rules

- **Do not modify deprecated plugin files** (`.deprecated` suffix) — kept for reference only
- **Root directory never auto-changes** — `vim.g.root_spec = { "cwd" }` in options.lua. Use `<leader>ba` to change manually
- **Auto-save only affects normal files** — special buffers, readonly, and unnamed buffers excluded
- **macOS 26+ codesign** — `lua/config/codesign.lua` auto-re-signs native libs after `:Lazy update`/`:TSUpdate`. Run `:SignNativeLibs` manually if needed. After upgrading nvim: `codesign -fs - --entitlements /tmp/nvim-entitlements.plist /Applications/nvim-macos-arm64/bin/nvim`
