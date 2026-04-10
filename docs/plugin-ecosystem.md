# Plugin Ecosystem

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
- `tsgo` LSP (see implementation details)
