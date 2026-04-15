# Plugin Ecosystem

All 106 plugins tracked in `lazy-lock.json` (~101 resolve to actual clones on disk after dedup). Plugin specs live under `lua/plugins/`; anything not listed there is pulled in via a LazyVim extra (see `lazyvim.json`).

Legend: **[custom]** = non-trivial local config in `lua/plugins/<name>.lua`. **[extra]** = comes from a LazyVim extra, no local override. **[dep]** = library/peer dependency.

---

## Core / Loader

- `lazy.nvim` — Plugin manager. Bootstrap + config in `lua/config/lazy.lua`.
- `LazyVim` — Base distro. Disables several defaults; custom colorscheme chain in `lua/config/lazy.lua`.
- `lazydev.nvim` — Neovim Lua runtime types for LSP. [extra]
- `plenary.nvim` — Shared Lua stdlib. [dep]
- `nui.nvim` — UI component library. [dep]
- `nvim-nio` — Async IO primitives. [dep]
- `promise-async` — Async/promise lib used by ufo. [dep]

## Colorschemes

- `tokyonight.nvim` — Active theme. LazyVim default; also second entry in the `install.colorscheme` fallback chain in `lua/config/lazy.lua` (and the first, `gruvdark`, is not installed, so this is what actually loads).
- `catppuccin` — Fallback theme only. Installed but unused unless tokyonight fails to load.
- Note: `lua/config/colors.lua` is a palette helper for lualine, **not** a colorscheme. `lua/plugins/tokyonight.lua.deprecated` is stale — the plugin is still active via the fallback chain.

## UI / Chrome

- `snacks.nvim` **[custom]** — Dashboard (Triforce animation, weather, git pane), picker, terminal, profiler. Heavy customization in `lua/plugins/snacks.lua`. [extra for explorer/picker]
- `lualine.nvim` **[custom]** — Dual-bar statusline: branch cache with 2s TTL, perf metrics bottom, date/buffers top.
- `incline.nvim` **[custom]** — Floating winbar with devicon color + navic breadcrumbs; overlaps native winbar.
- `edgy.nvim` **[custom]** — Sidebar window manager; configured to pin Claude Code terminal at 40% width right. [extra]
- `noice.nvim` — Cmdline / messages UI replacement.
- `which-key.nvim` — Keymap discovery popup.
- `nvim-web-devicons` — File type icons.
- `mini.icons` — Alt icon provider used by snacks/etc.
- `indent-blankline.nvim` — Indent guides. [extra]
- `mini.indentscope` — Animated current-scope indent line. [extra]
- `mini.animate` — Window/cursor/scroll animations. [extra]
- `smear-cursor.nvim` — Smooth cursor smear trail. [extra]
- `render-markdown.nvim` — Inline rendering of markdown in buffer.
- `bufferline.nvim` — **Disabled** in `lua/plugins/bufferline.lua` (kept for reference).

## Colors / Highlights

- `mini.hipatterns` — Highlights hex colors / patterns. [extra]
- `vim-illuminate` — Highlights other occurrences of word under cursor. [extra]
- `todo-comments.nvim` — Highlights + searches TODO/FIX/NOTE tags.

## File / Buffer Management

- `yazi.nvim` **[custom]** — Terminal file manager integration; `<leader>yc/yw`, `<c-up>` toggle.
- `mini.files` — Miller-column file browser. [extra]
- `hbac.nvim` **[custom]** — Auto-close untouched buffers, threshold 8.
- `scope.nvim` — Per-tab buffer scoping.
- `persistence.nvim` — Session save/restore.

## Navigation / Motion

- `flash.nvim` — Label-based jump (s/S, treesitter jumps).
- `harpoon` — Pinned file quick-switch. [extra]
- `recall.nvim` **[custom]** — Persistent global marks with snacks picker integration (`<leader>mm/mn/mp/mc/ml`).
- `trailblazer.nvim` **[custom]** — Trail-marks with `<leader>t*` bindings.
- `vim-tmux-navigator` **[custom]** — `<c-h/j/k/l>` seamless tmux+nvim pane moves.
- `microscope.nvim` **[custom]** — `<leader>r` peek-definition popup.

## Search / Picker

- `telescope.nvim` — Classic fuzzy picker (kept for venv-selector and terraform compat). [extra via snacks_picker still primary]
- `telescope-terraform.nvim` — Terraform resource picker.
- `telescope-terraform-doc.nvim` — Terraform provider docs.
- `seeker.nvim` **[custom]** — Find→grep workflow (`<leader>fa/ff/fg/fw`).
- `grug-far.nvim` — Project-wide find & replace UI.
- `nvim-bqf` — Better quickfix: preview + fuzzy filter.
- `quicker.nvim` **[custom]** — Enhanced quickfix rendering (loaded on `ft=qf`).

## LSP / Completion

- `nvim-lspconfig` **[custom]** — Custom `tsgo` LSP server registration for TS/JS (replaces vtsls).
- `mason.nvim` — LSP/tool installer.
- `mason-lspconfig.nvim` — Mason↔lspconfig bridge.
- `mason-nvim-dap.nvim` — Mason↔dap bridge.
- `blink.cmp` — Primary completion engine. [extra]
- `blink-copilot` — Copilot source for blink. [extra]
- `copilot.lua` — GitHub Copilot inline suggestions. [extra]
- `sidekick.nvim` **[custom]** — Claude Code CLI sidebar; auto-attach + custom `<leader>a*` bindings.
- `none-ls.nvim` — LSP-shaped wrapper for external formatters/linters. [extra]
- `nvim-lint` — Async linting (eslint, ruff, etc.). [extra]
- `conform.nvim` — Async formatting (prettier, black, stylua).
- `nvim-navic` **[custom]** — LSP breadcrumbs; depth 15, click-through, lazy context. [extra]
- `inc-rename.nvim` — Live preview LSP rename. [extra]
- `SchemaStore.nvim` — JSON/YAML schema catalog.

## Snippets

- `friendly-snippets` — Snippet corpus.
- `mini.snippets` — Snippet engine. [extra]

## Treesitter

- `nvim-treesitter` — Parser/highlight core.
- `nvim-treesitter-context` — Sticky context header. [extra]
- `nvim-treesitter-textobjects` — af/if/aa/ia etc.
- `nvim-ts-autotag` — Auto-close JSX/HTML tags.
- `nvim-ts-context-commentstring` — Context-aware comment strings.
- `ts-comments.nvim` — Modern commentstring injector.
- `mini.comment` — Commenter engine. [extra]
- `mini.ai` — Enhanced text-objects.
- `mini.pairs` — Auto-pair brackets.
- `mini.surround` — Surround verbs. [extra]

## Editing

- `yanky.nvim` — Yank ring + paste history. [extra]
- `dial.nvim` — Smart `<c-a>/<c-x>` incrementing. [extra]
- `sort.nvim` **[custom]** — Visual-range sort helpers.
- `mini.nvim` **[custom]** — Loaded only for `mini.misc` + `setup_termbg_sync()` in `lua/plugins/mini-misc.lua`.

## Folding

- `nvim-ufo` **[custom]** — Treesitter/indent folds with preview; disables folding in dashboard + special buffers; custom fold virt-text handler.

## Git

- `gitsigns.nvim` **[custom]** — Sign column + hunk nav (`]h/[h`, `<leader>gh*`); `show_deleted=true`.
- `mini.diff` — Inline diff source (feeds lualine). [extra]
- `diffview.nvim` — **Deprecated** (`.deprecated` file kept); replaced by mini.diff.
- `codediff.nvim` **[custom]** — Tree-mode diff explorer for branch compare.
- `octo.nvim` **[custom]** — GitHub PR/issue review with `use_local_fs=true`.

## Testing / Debugging

- `neotest` — Test runner framework. [extra]
- `neotest-python` — Python adapter. [extra]
- `neotest-golang` — Go adapter. [extra]
- `nvim-dap` — Debug adapter core. [extra]
- `nvim-dap-ui` — DAP UI panes. [extra]
- `nvim-dap-virtual-text` — Inline variable values. [extra]
- `nvim-dap-python` — Python DAP glue. [extra]
- `nvim-dap-go` — Go DAP glue. [extra]
- `one-small-step-for-vimkind` — Lua (nvim) DAP adapter. [extra]

## Language-Specific

- `rustaceanvim` — Rust-analyzer orchestration + codelens. [extra]
- `crates.nvim` — `Cargo.toml` version hints. [extra]
- `nvim-jdtls` — Java LSP (Eclipse JDT). [extra]
- `helm-ls.nvim` — Helm LSP. [extra]
- `venv-selector.nvim` **[custom]** — Python venv picker (`<leader>cv/cV`).
- `nvim-pretty-ts-errors` **[custom]** — TypeScript error prettifier; runs `npm install` on build.
- `markdown-plus.nvim` — Markdown editing helpers.
- `markdown-preview.nvim` — Browser-rendered markdown preview. [extra]
- `nvim-jqx` **[custom]** — JSON/YAML prettify; loaded on `json`/`yaml` ft.

## Data / Databases

- `vim-dadbod` — DB client core. [extra via `lang.sql`]
- `vim-dadbod-ui` — DB navigator UI. [extra]
- `vim-dadbod-completion` — SQL completion. [extra]
- `dadbod-grip.nvim` **[custom]** — Rich DB CLI (`Grip*` commands); build script strips malformed upstream `lazy.lua`.

## HTTP / API

- `kulala.nvim` **[custom]** — REST client (`<leader>R*`), runs on `http`/`rest` ft. [extra via `util.rest`]
- `apidocs.nvim` **[custom]** — Offline devdocs viewer (`<leader>k*`); uses snacks picker.

## Diagrams / Images

- `diagram.nvim` **[custom]** — Mermaid/PlantUML/D2/gnuplot rendering with custom `mermaid-config.json`.
- `image.nvim` — Inline image rendering backend.

## Notes / Knowledge

- `obsidian.nvim` **[custom]** — Points at iCloud Obsidian vault; loads on markdown ft.

## Utility

- `trouble.nvim` — Diagnostics/locationlist panel.
- `outline.nvim` — Symbol tree sidebar. [extra]

## Dot / Scripting

- Dot extra — `.dot` filetype support (graphviz). [extra via `util.dot`]

---

## Deprecated (kept for reference)

Files suffixed `.lua.deprecated` in `lua/plugins/`:

- `aider.lua` — replaced by sidekick/claude-code workflow
- `claude-code.lua` — replaced by sidekick
- `comrade.lua` — superseded
- `deoplete.lua` — pre-blink completion
- `diffview.lua` — replaced by mini.diff
- `friendly-snippets.lua` — now pulled in via LazyVim extra
- `quickscope.lua` — replaced by flash
- `tokyonight.lua` — replaced by gruvdark
- `wilder.lua` — replaced by noice

---

## LazyVim Extras Enabled

From `lazyvim.json` (each pulls a bundle of plugins above):

**AI**: copilot, sidekick
**Coding**: blink, luasnip, mini-comment, mini-snippets, mini-surround, yanky
**DAP**: core, nlua
**Editor**: dial, harpoon2, illuminate, inc-rename, mini-files, navic, outline, snacks_explorer, snacks_picker
**Formatting/Linting**: prettier, eslint
**LSP**: none-ls
**Test**: core
**UI**: edgy, indent-blankline, mini-animate, mini-indentscope, smear-cursor, treesitter-context
**Util**: dot, mini-hipatterns, octo, rest
**Langs**: docker, git, go, helm, java, json, kotlin, markdown, nix, python, rust, sql, tailwind, terraform, toml, typescript, yaml
**Other**: vscode
