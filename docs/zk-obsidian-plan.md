# zk + Obsidian Integration — Plan

**Status:** SHELVED — designed 2026-08-20, not implemented.
**Scope:** `~/.config/nvim` (plugin spec), `~/.config/nix-darwin/home.nix` (install), Obsidian vault root (`.zk/`).

Design for running [zk](https://github.com/zk-org/zk) as the note *engine* over the existing
Obsidian vault, with [zk-nvim](https://github.com/zk-org/zk-nvim) as the Neovim front end.
Obsidian.app keeps working unchanged — no migration, no format conversion.

---

## Why (and why not)

zk's notebook is just a directory holding `.zk/config.toml` + a SQLite index. Notes stay plain
markdown, so both tools can own the same files.

**What this actually buys:**

1. **`zk lsp`** — `[[` link completion, go-to-definition, backlinks, dead-link diagnostics.
   Strictly better than obsidian.nvim's equivalents.
2. **`zk list --format json`** — a structured query API over the vault. This is the real prize:
   the `journal` skill and the nightly Inbox-triage cron currently do `rg` + hand-rolled file
   edits. A queryable index is a far better substrate for both, and for Claude.

**What it does not buy:** search speed. The vault is ~107 notes; `rg` over that is already
instantaneous. The SQLite index is not solving a scaling problem. If items 1 and 2 above don't
feel valuable, **this plan is churn — don't do it.**

### Non-goals

- Migrating off Obsidian. Obsidian.app stays the GUI/graph/mobile reader.
- Renaming existing notes or rewriting existing links.
- Replacing Templater for Obsidian-side note creation.

---

## Architecture

| Layer | Owner |
|---|---|
| Create / template / index / query | `zk` CLI |
| Link completion, backlinks, dead-link diagnostics | `zk lsp` |
| Picker + commands in Neovim | `zk-nvim` (snacks picker) |
| Rendering in Neovim | `render-markdown.nvim` (already installed) |
| Graph view, mobile, plugins, reading | Obsidian.app (unchanged) |
| Obsidian-only niceties (app URI, image paste) | obsidian.nvim, stripped — see open decision |

---

## Vault facts (as of 2026-08-20)

Path: `~/Library/Mobile Documents/iCloud~md~obsidian/Documents/Default/`

```
_Templates/  Archive/  Areas/(14)  Inbox/(2)  Journal/(38)
Knowledge/(21)  Projects/(19)  Resources/(13)  Self/  Tags/
```

No `.zk/` yet. 25 Obsidian plugins installed, including `templater-obsidian`,
`dataview`, `obsidian-git`, `omnisearch`, `obsidian-local-rest-api`.

---

## The four settings that make or break compatibility

Everything else is taste; these four are correctness.

| Setting | Value | Why |
|---|---|---|
| `link-format` | `"wiki"` | zk defaults to `[markdown](links)`. Obsidian wants `[[wikilinks]]`. |
| `filename` | `"{{slug title}}"` | zk defaults to a random 4-char ID. Obsidian resolves `[[wikilinks]]` by filename/title, so ID filenames make every zk-created note unresolvable from Obsidian's side. **This is the one that silently ruins things.** |
| `link-drop-extension` | `true` (default) | Emit `[[note]]`, not `[[note.md]]`. |
| `hashtags` | `true` (default) | Matches Obsidian's `#tag`. |

---

## `.zk/config.toml`

Groups let each top-level vault directory keep its own filename pattern and template, mapping 1:1
onto the structure that already exists.

```toml
# Notebook root: <vault>/Default/

[note]
language = "en"
default-title = "Untitled"
filename = "{{slug title}}"
extension = "md"
template = "default.md"
# Keep zk out of directories it has no business indexing.
exclude = ["_Templates", "Archive", ".obsidian", ".trash"]

[format.markdown]
link-format = "wiki"
link-drop-extension = true
hashtags = true
colon-tags = false
multiword-tags = false

[lsp.diagnostics]
dead-link = "warning"     # not "error" — a vault this old has legitimate stubs
wiki-title = "hint"
self-link = "none"
missing-backlink = "none" # noisy on a journal-heavy vault

[lsp.completion]
note-label = "{{title-or-path}}"
note-detail = "{{path}}"

# --- Groups -----------------------------------------------------------------

[group.journal]
paths = ["Journal"]
[group.journal.note]
filename = "{{format-date now '%Y-%m-%d'}}"
template = "journal.md"

[group.knowledge]
paths = ["Knowledge/**"]
[group.knowledge.note]
filename = "{{slug title}}"
template = "evergreen.md"

[group.inbox]
paths = ["Inbox"]
[group.inbox.note]
filename = "{{slug title}}"
template = "inbox.md"

[group.projects]
paths = ["Projects"]
[group.projects.note]
filename = "{{slug title}}"
template = "project.md"

# --- Aliases ----------------------------------------------------------------

[alias]
# Notes touched recently, newest first.
recent = "zk list --sort modified- --limit ${1:-20} $@"
# Notes nothing links to.
orphans = "zk list --orphan $@"
# JSON out, for the journal skill / cron to consume.
q = "zk list --quiet --format json $@"
```

Templates live in `.zk/templates/` (Handlebars). Keep them **thin** — Templater still owns
Obsidian-side creation, and two template engines drifting apart is the main ongoing tax here.

---

## `lua/plugins/zk.lua`

```lua
-- zk-nvim: note engine over the Obsidian vault.
-- See docs/zk-obsidian-plan.md. Requires `zk` on PATH (home.nix).
local vault = vim.fn.expand("~")
  .. "/Library/Mobile Documents/iCloud~md~obsidian/Documents/Default"

return {
  "zk-org/zk-nvim",
  name = "zk",
  ft = "markdown",
  cmd = { "ZkNew", "ZkNotes", "ZkTags", "ZkMatch", "ZkBacklinks", "ZkLinks", "ZkCd" },
  opts = {
    picker = "snacks_picker",
    picker_options = {
      snacks_picker = { layout = { preset = "ivy" } },
    },
    lsp = {
      config = {
        name = "zk",
        cmd = { "zk", "lsp" },
        filetypes = { "markdown" },
      },
      -- Only attaches inside a zk notebook, so this stays scoped to the vault
      -- and will not fire on repo READMEs.
      auto_attach = { enabled = true },
    },
    tags = { multi_select_strategy = "AND" },
  },
  keys = {
    -- `<leader>n` is unclaimed in this config (verified 2026-08-20 — zero hits across
    -- lua/ and docs/keybindings.md). Confirm no LazyVim extra grabs it before committing.
    { "<leader>nn", "<Cmd>ZkNotes<CR>", desc = "zk: notes" },
    { "<leader>nt", "<Cmd>ZkTags<CR>", desc = "zk: tags" },
    { "<leader>nf", "<Cmd>ZkMatch<CR>", desc = "zk: full-text search" },
    { "<leader>nb", "<Cmd>ZkBacklinks<CR>", desc = "zk: backlinks" },
    { "<leader>nl", "<Cmd>ZkLinks<CR>", desc = "zk: outbound links" },
    { "<leader>nc", "<Cmd>ZkNew { title = vim.fn.input('Title: ') }<CR>", desc = "zk: new note" },
    -- Visual: turn a selection into a new linked note.
    { "<leader>nc", ":'<,'>ZkNewFromTitleSelection<CR>", mode = "v", desc = "zk: new from selection" },
  },
}
```

Full command list is in the zk-nvim README; the set above is the useful core.

---

## Risks and mitigations

### 1. SQLite index inside an iCloud-synced folder — the sharpest risk

`.zk/notebook.db` sits under continuous iCloud sync. Expect a
`notebook (conflicted copy).db` eventually.

**Mitigation:** it's derived state. `zk index --force` rebuilds it from the markdown. Add a note
to the vault `CLAUDE.md` telling Claude to (a) surface any `.zk/*conflicted*` file rather than
merge it, and (b) run `zk index` after bulk file edits. iCloud Drive has no ignore mechanism, so
this cannot be prevented, only recovered from cheaply.

### 2. obsidian.nvim and zk's LSP will fight

Both provide `[[` completion and both hook link-following (`gf`/`gd`). Running them unmodified
means double completion sources and competing keymaps. See open decision below.

### 3. Pre-existing bug in `lua/plugins/obsidian.lua`

The workspace path points at `.../Documents` (the iCloud container) but the vault is
`.../Documents/Default`. obsidian.nvim is rooted one level too high today. Worth fixing whether
or not the rest of this plan happens.

### 4. `epwalsh/obsidian.nvim` is no longer the maintained line

The community fork `obsidian-nvim/obsidian.nvim` is where development moved (last push 2026-08-14
vs 2026-06-04 upstream; 2.1k vs 6.2k stars). If obsidian.nvim survives step 4, switch to the fork.

### 5. zk does not parse links in YAML frontmatter

[zk#709](https://github.com/zk-org/zk/issues/709), PR #710 open. Frontmatter `up:`/MOC-style links
will not produce backlinks. Body links only. Not a blocker unless the vault leans on frontmatter
links — verify before starting.

### 6. Two template engines

Templater fires in Obsidian, Handlebars fires on `zk new`. Divergence is the long-term cost. Keep
zk templates minimal, or make zk the sole creator and let the Templater templates go stale
deliberately.

---

## Implementation checklist

Ordered; each step is independently verifiable.

- [x] **0. Pre-flight — DONE 2026-08-20.** Frontmatter wikilinks appear in only 2 of ~107 notes
      (both under `Projects/`), so risk 5 is negligible. Re-check if that changes:
      `rg -l '^\s*[a-zA-Z_-]+:\s*.*\[\[' <vault> --glob '*.md'`
- [ ] **1. Commit a vault snapshot.** `obsidian-git` is installed; make sure the working tree is
      clean before zk touches anything. This is the rollback point.
- [ ] **2. Install zk.** Add `zk` to `home.packages` in `~/.config/nix-darwin/home.nix`
      (nixpkgs unstable has 0.15.6). **Then ask Charlie to run**
      `darwin-rebuild switch --flake ~/.config/nix-darwin#default` — never invoke sudo.
- [ ] **3. Init the notebook.** `cd <vault> && zk init`, then replace the generated
      `.zk/config.toml` with the config above. Write the four templates into `.zk/templates/`.
      Run `zk index` and confirm the note count matches `find <vault> -name '*.md' | wc -l`
      minus excluded dirs.
- [ ] **4. Resolve the obsidian.nvim decision** (see below), and fix the workspace path bug
      either way.
- [ ] **5. Add `lua/plugins/zk.lua`.** Verify: `:ZkNotes` opens in snacks; `:checkhealth lsp`
      shows the zk client attached inside the vault and *not* attached in a code repo;
      typing `[[` in a vault note completes note titles.
- [ ] **6. Round-trip test.** Create a note with `:ZkNew`, add a `[[link]]` to it from another
      note, then open both in Obsidian.app and confirm the link resolves and the graph updates.
      This is the acceptance test for the whole plan.
- [ ] **7. Document.** Add a `zk` section to the vault `CLAUDE.md` (index-after-bulk-edit,
      conflict handling) and to `docs/keybindings.md`.
- [ ] **8. (Production tier only)** Rewrite the `journal` skill's search paths to use
      `zk list --format json` instead of `rg`. Same for the nightly Inbox-triage cron.
      This is the step that justifies the project — treat it as the goal, not a stretch.

---

## Open decisions

### obsidian.nvim: strip or remove?

**Recommendation: strip.** (Charlie has not decided; this is my lean, not a settled call.)
 Disable its completion and link-following so zk's LSP owns navigation,
but keep it for the things zk genuinely has no answer for — `obsidian://` URI to open a note in
the app, image paste into the attachment folder, Obsidian-flavored checkbox toggling, block refs
(`^block-id`) and embeds (`![[...]]`). Removing it outright loses real functionality for no gain,
since the conflict is resolvable by config.

### Quality tier

Unset. **Prototype** = steps 0–7, no tests, no skill rewrite. **Production** = adds step 8 plus
conflict-handling docs. Step 8 is where the actual value is, so Prototype risks leaving this as a
slightly nicer picker and nothing more.

---

## Backing out

1. Remove `lua/plugins/zk.lua`, `rm -rf <vault>/.zk`, drop `zk` from `home.nix`.
2. Notes created by zk are plain markdown with wiki links — they survive removal intact.
3. Nothing in this plan rewrites existing notes, so there is no lossy step to undo.

---

## References

- zk note format / link format: <https://zk-org.github.io/zk/notes/note-format.html>
- zk note config + filename templates: <https://zk-org.github.io/zk/config/config-note.html>
- zk groups: <https://zk-org.github.io/zk/config/config-group.html>
- zk LSP config: <https://zk-org.github.io/zk/config/config-lsp.html>
- zk filtering (`zk list`): <https://zk-org.github.io/zk/notes/note-filtering.html>
- zk-nvim README (commands, pickers): <https://github.com/zk-org/zk-nvim>
- Obsidian → zk migration notes: <https://github.com/zk-org/zk/discussions/369>
- Frontmatter links issue: <https://github.com/zk-org/zk/issues/709>
