# Venv-selector + Telescope Cleanup Plan

Proposal to remove `venv-selector.nvim` and the telescope triad it drags in. Companion to [`plugin-audit.md`](plugin-audit.md) §"Telescope just for venv-selector" (line 57).

Status: **proposed, not executed.**

---

## TL;DR

Drop 4 plugins with zero adds:

- `venv-selector.nvim`
- `telescope.nvim`
- `telescope-terraform.nvim`
- `telescope-terraform-doc.nvim`

Trade a `<leader>cv`/`cV` picker for whatever your shell already does (direnv, `uv run`, manual activation).

---

## Why this is worth doing

| | Before | After |
| --- | --- | --- |
| Plugins | 4 (venv-selector + 3 telescope) | 0 |
| Hard deps | `venv-selector` → `telescope.nvim` (pre-v2 API) | — |
| Picker stack | snacks primary **+** telescope secondary | snacks only |
| Startup | ~10 ms on telescope load | saved |
| On-disk | ~6 MB | saved |

The audit's original suggestion — "upgrade venv-selector past v1, drop telescope" — needs +1 plugin (`fzf-lua`, v2's picker backend). Dropping venv-selector entirely is a cleaner result.

## What lives on each plugin

### `venv-selector.nvim`

- Currently pinned to `bcb2f58` on `main` — pre-rewrite v1 API.
- Bindings: `<leader>cV` = `:VenvSelect`, `<leader>cv` = `:VenvSelectCached`.
- Hard-depends on `nvim-telescope/telescope.nvim` as its picker.
- Upstream has since moved: `v2`/`regexp` branches use `fzf-lua`.

### Telescope triad

- `telescope.nvim` — kept **only** as a venv-selector transitive dep (snacks.picker is primary).
- `telescope-terraform.nvim` + `telescope-terraform-doc.nvim` — pulled by `lazyvim.plugins.extras.lang.terraform` (enabled in `lazyvim.json:36`), not by any user-level spec.
- Nothing else in the config imports `telescope.builtin`:
  - `octo.lua:5` — commented out
  - `recall.lua:10` — defensive config key, not a require
  - `example.lua` — guarded `if true then return {} end`

## Replacement strategy (venv activation without the plugin)

LSP (pyright / basedpyright / ruff / ty) reads `$VIRTUAL_ENV` and `$PATH` at launch. Options ordered by ergonomic cost:

1. **direnv** — `.envrc` with `layout python` or `source .venv/bin/activate`. nvim inherits env. Zero in-editor action.
2. **`uv run nvim`** — uv auto-activates the project venv for the subprocess.
3. **Shell autoenv** — zsh-autoenv / mise / pyenv-virtualenv activation hook.
4. **Manual** — activate venv in shell before `nvim`.

If you hit a repo with mid-session venv switching needs, fallbacks:

- Restart nvim after `source .venv/bin/activate`.
- `:let $VIRTUAL_ENV = '/path/...' | LspRestart` — one-liner, no plugin.
- Reinstall `venv-selector` later if it becomes a real friction point.

## Execution steps

```
# 1. Delete the spec
rm lua/plugins/venv-selector.lua

# 2. Disable the terraform extra
#    Edit lazyvim.json — remove line 36: "lazyvim.plugins.extras.lang.terraform"

# 3. Prune lazy-lock.json (4 entries)
#    - venv-selector.nvim
#    - telescope.nvim
#    - telescope-terraform.nvim
#    - telescope-terraform-doc.nvim

# 4. Update docs
#    - plugin-audit.md: mark "Telescope just for venv-selector" as REMOVED, check ☑ line 125
#    - plugin-ecosystem.md: delete the 3 telescope lines from "Search / Picker"

# 5. Verify
nvim --startuptime /tmp/after.log +qa
:Lazy clean  # removes orphaned clones
:checkhealth lazy
```

## Rollback

If Python LSP breaks or `:VenvSelect` muscle memory wins:

```bash
git revert <this commit>
nvim +Lazy
```

Or selective revert: restore `lua/plugins/venv-selector.lua` only, leave the telescope+terraform removals in place.

## Risks / what could go wrong

- **LSP picks the wrong interpreter** on the first open after removal. Mitigation: activate venv in shell *or* set `$VIRTUAL_ENV` before launching nvim.
- **Terraform files lose resource/docs picker.** Mitigation: only matters if you edit `.tf` files. Syntax highlighting + LSP (`terraformls`) stays — it's pulled by the base `lang.terraform` treesitter parser via nvim-treesitter, not the extra. Worth confirming before landing.
- **Some snacks picker extension silently relied on telescope.** Unlikely — snacks is self-contained — but worth a `:checkhealth snacks` after.
- **A LazyVim extra we forget about pulls telescope back in.** `lang.terraform` is the only one flagged; audit other enabled extras if Lazy re-clones telescope on next sync.

## Open questions (resolve before executing)

- [ ] Do you edit `.tf` files in nvim? If yes, keep the terraform extra — the partial win is still 1 plugin (venv-selector) dropped plus telescope, telescope re-requires a picker so maybe a wash.
- [ ] Is direnv / shell auto-activation already in place? If not, the UX hit is real on day one.
- [ ] Any LILT repo where you've leaned on `:VenvSelectCached` recently? Grep your shell history for `VenvSelect` if unsure.

## Related follow-ups (separate passes)

- `docs/plugin-audit.md` line 130: `neotest-python` + `nvim-dap-python` lazy-loaded on `ft=python` — independent but same Python-stack cleanup theme.
- Sibling Python extras in `lazyvim.json` worth reviewing once venv-selector's gone.
