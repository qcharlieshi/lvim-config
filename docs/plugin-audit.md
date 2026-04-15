# Plugin Audit — 2026-04-15

Audit of the ~101 installed plugins (106 tracked in `lazy-lock.json`). Companion to [`plugin-ecosystem.md`](plugin-ecosystem.md). Findings grouped by severity: bugs first, redundancy/bloat second, install quirks third, open questions last.

---

## Bugs / dead code

### `hbac.nvim` options were being silently dropped — **FIXED**

`lua/plugins/hbac.lua` originally set `autoclose = true` and `threshold = 8` at the **top level** of the lazy spec, not inside `opts`. `config = true` therefore ran with defaults — confirmed by the file's own TODO comment ("doesn't seem to work?"). Fixed by moving both keys into `opts`.

### `lsp.lua` carries ~50 lines of commented-out code

`sith_lsp` (commented), `vtsls` settings (commented), `ruff` / `pyright` disabled blocks. Only `tsgo` is live. Cleanup candidate — `git log` already has the history.

### `kulala.nvim` has a stale "doesn't seem to work?" TODO

Either wire `global_keymaps` properly or drop the plugin. Currently it's installed, bound to `<leader>R*` keys, and the author has doubts it functions.

### `lua/plugins/example.lua`

Guarded by `if true then return {} end` so it's a no-op, but still clones behavior notes that mention `gruvbox` etc. and confuses audits. Consider deleting — LazyVim docs exist online.

---

## Redundancy / bloat

### Three themes, one active

- `tokyonight.nvim` — **actually renders** (fallback chain `gruvdark` → `tokyonight` → …; `gruvdark` isn't installed, so Lazy drops to #2).
- `catppuccin` — pure dead weight unless tokyonight fails to load.
- `gruvdark` — named in `lua/config/lazy.lua:29` but no plugin ever defines it. Aspirational / regression.

**Action:** either install an actual gruvdark/gruvbox plugin (if that was the intent) or remove `gruvdark` from the fallback list and drop `catppuccin` from `lazy-lock.json`.

### `mini.nvim` meta + 10 individual mini.* submodules

`mini-misc.lua` pulls the meta repo just to call `mini.misc.setup_termbg_sync()`. LazyVim extras pull submodules (`mini.ai`, `mini.files`, …) from the same upstream. Net effect: the `mini.nvim` repo is cloned twice with different names. Not technically broken, but wasteful and confusing.

**Action:** drop `mini-misc.lua`'s `"nvim-mini/mini.nvim"` dep; `require("mini.misc")` works from any already-loaded mini submodule.

### Three markdown plugins

- `markdown-plus.nvim` — editing helpers
- `render-markdown.nvim` — inline (in-buffer) rendering
- `markdown-preview.nvim` — browser HTML preview (node-based)

Distinct use cases, but `render-markdown` usually suffices. Confirm `markdown-plus` is earning its keep; `markdown-preview` is only useful if you open a browser preview.

### `microscope.nvim`

Tiny plugin bound to `<leader>r` for "peek definition". LSP `gd`/`gD`/`K` + `flash.nvim` already cover this. Candidate for removal.

### Telescope just for venv-selector

`telescope.nvim`, `telescope-terraform.nvim`, `telescope-terraform-doc.nvim` all installed despite `snacks.picker` being primary. The hard dependency is `venv-selector.nvim` (and probably rarely-used terraform docs). Upgrading `venv-selector` past v1 drops the telescope requirement.

**Potential win:** removes 3 plugins, ~6 MB on disk, ~10 ms startup.

### 9 `.deprecated` plugin files

`lua/plugins/*.lua.deprecated` — navigation noise. Particularly misleading: `friendly-snippets.lua.deprecated` exists while the plugin is still installed via the `coding.luasnip` extra.

**Action:** move to `docs/deprecated-plugins/` or just delete; `git log` keeps history.

---

## Install quirks worth flagging

### `dadbod-grip.nvim` build-hook deletes upstream file

`build = function(plugin) os.remove(plugin.dir .. "/lazy.lua") end` — if the maintainer ever fixes their malformed `lazy.lua`, the hook silently errors on next update. Either pin the commit or send an upstream PR.

### `nvim-pretty-ts-errors` runs `npm install` on build

Fragile: breaks without Node/npm in PATH. Confirm it's actually rewriting TS diagnostics vs. just sitting idle.

### `bufferline.nvim` spec is fully disabled

File holds `enabled = false` with ~45 lines of commented config. Not in the lock (correctly). Delete the file instead of leaving a disabled spec.

### `helm-ls.nvim` pulled by `lang.helm` extra

No local override, and helm rarely shows up in daily work per CLAUDE.md stack. Consider dropping the extra.

---

## Open questions

1. **Colorscheme intent.** Did you expect `gruvdark` to load? If yes, that's an install regression (plugin was never committed). If no, drop it from the fallback list.
2. **Snippet engines.** `lazyvim.json` pulls `coding.luasnip` *and* `coding.mini-snippets`. Which is blink actually consuming? One may be inert — pick one.
3. **Python testing/debugging always-on.** `neotest-python` + `nvim-dap-python` load at startup. Per CLAUDE.md, Python work is mostly inside LILT repos — worth switching to `ft = { "python" }` to trim startup cost outside those repos.
4. **`persistence.nvim` vs. snacks sessions.** Snacks has its own session support. Double-loaded?

---

## Numbers at a glance

| Metric                                  | Count |
| --------------------------------------- | ----- |
| Lock entries                            | 106   |
| Actually cloned to `~/.local/share/nvim/lazy/` | 101   |
| Local specs in `lua/plugins/`           | 35    |
| `.deprecated` files                     | 9     |
| LazyVim extras enabled                  | 50    |

---

## Fixes applied this pass

- `lua/plugins/hbac.lua` — moved `autoclose`/`threshold` into `opts` so hbac actually receives them.
- `docs/plugin-ecosystem.md` — corrected plugin count (107→106/~101) and the `gruvdark` primary-theme claim.

## Suggested follow-ups (not done)

Pick whatever's worth your time:

- [ ] Remove `catppuccin` (or install a real gruvdark) — `lazy-lock.json` + `lua/config/lazy.lua`
- [ ] Kill `mini-misc.lua`'s duplicate `mini.nvim` dep
- [ ] Drop `microscope.nvim` if `gd`/flash cover it
- [ ] Upgrade `venv-selector` → drop 3 telescope plugins
- [ ] Delete 9 `.deprecated` files (or relocate)
- [ ] Fix or drop `kulala.nvim`
- [ ] Clean commented-out LSP blocks in `lsp.lua`
- [ ] Delete the disabled `bufferline.lua`
- [ ] Lazy-load `neotest-python` / `nvim-dap-python` on `ft=python`
