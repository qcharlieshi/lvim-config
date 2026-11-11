# Cockpit handoff — next steps after v1 view (2026-11-11)

**Tier:** Prototype. **Repo:** `~/.config/nvim` (pushed at `48cd8ef`) + `~/.config/nix-darwin` (herdr install **uncommitted** in `home.nix`).
**Read first:** this doc → `specs/2026-11-10-cockpit-herdr-runtime-design.md` (step 1, built) → `specs/2026-08-28-cockpit-design.md` (v8, parent; partly superseded, see §2).

Two sessions worked in parallel on 2026-11-10. This one designed and built the **v1 review view** (rail/workspace/thread, gated pipelines, editable deliverables). The other one committed that as its baseline (`481c5f1`) and built **step 1: herdr runtime + projects** on top (`5310d48`…`d964c48`). Both are on `origin/main`.

## 1. What exists now

| Piece | Where | State |
|---|---|---|
| Cockpit tab: runs rail · workspace · thread, fixed windows | `lua/cockpit/inbox/ui.lua` | Built; headless-tested only, needs interactive QA |
| Pipeline stages on threads: `post --stage S [--pipeline P --stages a,b,c]`; a stage post always gates; each post to a stage = a new round | `scripts/cockpit_inbox.py`, `store.lua` (`strip`, `deliverables`, `previous`) | Built |
| Editable markdown deliverables; edits diffed vs the sent blob, sent as patches, logged as `kind:"edit"` in `feedback.jsonl` | `ui.lua` (`render_edits`, `save_edit`), `store.lua` (`edits`, `clear_edits`) | Built |
| Codediff review in `:CodeDiff dir base/ review/`, rebuilt from the sent patch at a resolved `base_sha`; edits on the right side become patches; agent worktree never touched | `lua/cockpit/inbox/review.lua` | Built; review side confirmed editable |
| Reply tells the agent the next stage step (repost same stage / move to next / halted) | `cockpit_inbox.py` `stage_step` | Built |
| herdr runtime: socket client, live agent cache, spawn/kill/interrupt/attach/prompt, projects, delivery via `agent.prompt` with tmux fallback, status glyph in rail | `lua/cockpit/herdr.lua`, `projects.lua`, `store.deliver` | Built by the other session; smoke: `scripts/cockpit-smoke-herdr.sh` |

Keys: `docs/keybindings.md` → "Cockpit".

## 2. Decisions made in the design conversation (and why)

1. **Own nvim inbox, not Plannotator.** The 2026-11-03 research recommended renting Plannotator's Inbox; the user built cockpit's own instead. The why-tagged ledger + vim grammar stay ours.
2. **herdr is the runtime, not the front end.** tmux stays the outer shell, nvim stays outside herdr. Reasons: herdr's input re-encoding/latency bugs (#2890, CSI-u family) would hit every editor keystroke; sessionizer / vim-tmux-navigator / resurrect would break. Revisit only if a dedicated `herdr attach` window becomes where the user lives.
3. **herdr-reviewr rejected for codediffs; codediff.nvim instead.** reviewr's comments live only in its pane (no JSON export yet) and Send pastes plain text, bypassing threads/verdicts/`feedback.jsonl`; it's also a second key grammar. codediff.nvim is already installed and used by atlas.
4. **Claude Code mods: agent side only.** Good for in-session delivery (`$.session.append`), a status band, `tool.call` gating, and a phone surface. Bad as the review surface (no operators/visual selection/yank; per-session, not cross-agent). Not built.
5. **Pipelines never run straight through.** Every stage ends at a human gate.
6. **Custom pipelines** with per-stage deliverable templates (markdown mostly, codediffs too).
7. **Everything under review is editable.** Edit → diff vs what was sent → sent back for another round of that stage. Approve-with-edits passes the stage and the edits travel as required input. Codediff edits stay out of the agent's worktree.
8. **Layout A** (runs rail + stage workspace + thread) over a board-first or queue-first view. Mockups: `.superpowers/brainstorm/12882-1794355530/content/main-layout.html` (untracked).

## 3. Next steps (ordered; ticket-style)

### T1 — Reconcile the two "step 2"s (decision, before any code)
The herdr spec's step 2 is "inbox redesign: project → agent → thread tree, table layout". v1 already ships a run-centric rail. Decide the rail hierarchy, likely **project → run (thread) with the producing agent's status inline**, and whether agents without a run need their own rows. **Done when:** one paragraph in a spec v9 note, approved by the user.

### T2 — Pipeline definitions + deliverable templates
- `~/.cockpit/pipelines/<name>.yaml`: ordered stages; per stage the required deliverables (`kind`, template, `markdown|codediff`).
- `~/.cockpit/templates/<kind>.md`: frontmatter + headings + one-line guidance (v8 §6 shape).
- `post --pipeline P` reads stages from the file (drop `--stages` or keep it as an override); a stage post missing a required deliverable is refused with a message naming it.
- Rail/winbar show missing deliverables.
**Done when:** a `feature` (plan → spec → impl → review) and a `bugfix` (diagnose → fix) pipeline exist and a stage post is validated against them.

### T3 — Run a pipeline from cockpit
`spawn` (herdr) with a pipeline: the agent is seeded with the pipeline file, its stage instructions and the CLI usage. At each gate it posts and **ends its turn**; the verdict arrives via `agent.prompt` (built). Env `COCKPIT_RUN` / `COCKPIT_STAGE` / `COCKPIT_PIPELINE` so subagents post to the same run (`--stage` already reads `COCKPIT_STAGE`/`COCKPIT_PIPELINE`; add `--thread` from `COCKPIT_RUN`).
**Done when:** a run started from the rail goes through two stages with a changes-requested round, entirely from nvim.

### T4 — Subagent attribution
Posts from subagents are indistinguishable today (`session.agent` = `claude`). Add a `producer` field (role/subagent type) and handle `SubagentStop` in the hook (today only `Stop` is hooked, and `turn_activity` reads only the parent transcript, so subagent edits are probably missed; verify).

### T5 — v1 polish (from the build)
- Interactive QA of layout A: window sizes, rail collapse, composer split, highlights.
- Notes are anchored to sent-version line numbers; they drift after you edit lines above them. Re-anchor via the edit diff.
- CodeDiff opens its own tab; on `CodeDiffClose`, return to the cockpit tab and refresh (README documents the `User CodeDiffClose` event).
- In `CodeDiff dir`, the base side is editable too (edits there are ignored); make it read-only.
- `stylua` isn't on PATH. Add it to `home.nix` and format `lua/cockpit`.

### T6 — Housekeeping
- Commit the herdr install in `~/.config/nix-darwin` (`home.nix`), then `darwin-rebuild switch` (user runs it; needs sudo).
- **Test hygiene:** any test that runs `cockpit_inbox.py` from inside a Claude session must `unset TMUX_PANE TMUX` and set `COCKPIT_INBOX_DIR` to a temp dir. Otherwise the reply is delivered into the tester's own pane (happened once in this session).
- Write spec v9 folding in §2 and T1, and mark v8's superseded parts.

### Later / only if needed
- Mod for delivery + status band in sessions herdr doesn't own.
- Phone review surface (mod on mobile) — the user hasn't said they want away-from-desk review.

## 4. How to test

- herdr runtime: `bash scripts/cockpit-smoke-herdr.sh`.
- View/pipeline loop (pattern used for v1): temp `COCKPIT_INBOX_DIR`, a scratch git repo, `post --stage spec … --attach spec.md --diff`, then headless `nvim -c "luafile test.lua"` driving `require("cockpit.inbox.ui").select(tid)`, edit the workspace buffer, `compose`+`:write`, and assert on the thread file and `cockpit_inbox.py read <tid> --new` (exit 1 = changes requested).

## 5. Open questions for the user

1. T1: is an agent's identity part of the rail (agent rows), or only a status glyph on its run?
2. Should approving the last stage auto-archive the run?
3. Where should pipeline/template files live: `~/.cockpit/` (per machine) or in this repo (versioned)?
