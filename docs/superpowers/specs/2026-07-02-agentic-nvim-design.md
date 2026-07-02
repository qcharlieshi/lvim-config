# Agentic Neovim — Parallel Lens Design

**Date:** 2026-07-02
**Status:** Approved design, pre-implementation
**Tier:** Prototype (happy path, manual smoke tests, no test suite)

Neovim as the human's high-bandwidth review/markup surface for agent-driven work. The
Claude Code harness is the primary driver; nvim is a parallel view and edit layer the
agent stages and reads back from. Because vim is text-only and every action maps to a
command, an agentic harness can manipulate it completely — that is the bet this design
doubles down on.

## Decisions

- **Topology:** nvim as parallel lens. Harness drives; nvim renders, reviews, annotates.
  Not nvim-as-cockpit, not symmetric peers.
- **Transport:** exchange-ledger hybrid ("Approach C"). Plain files as shared substrate +
  the existing `nvim_bridge.py` as the imperative agent→nvim channel. **MCP server
  rejected** as overwrought — revisit only if a non-Claude harness needs to drive nvim.
- **Markup model:** PR-review-style anchored comments (primary), applied uniformly to
  code, diffs, and markdown plans/specs; freeform editor state (marks, trails, quickfix)
  stays readable by the agent as secondary signal. **Hunk-level accept/reject verdicts
  rejected** — expressive commentary over binary triage.
- **Orchestration:** session roster + routing, model-tiered markup, and fleet
  observability are all in scope, phased after the review loop is proven.

## Visions & Plausibility

| # | Vision | Plausibility | Summary |
|---|--------|-------------|---------|
| V1 | The staged editor | Certain (exists) | Agent finishes work; buffers, harpoon, marks, quickfix already set. Needs hardening, not building. |
| V2 | The review loop | High | Every agent edit snapshotted → `:ClaudeReview` diff walk → anchored comments → `:AgentSend` returns structured review to the agent. |
| V3 | The switchboard | Medium-high | nvim knows all live sessions; annotations route to a chosen session and can carry model/effort hints. Direct work from the editor. |
| V4 | The fleet lens | Medium | Lualine/sidebar observability: live sessions, unreviewed-edit counts. Value scales with concurrent-agent habit. |
| V5 | Vim grammar as agent action language | Speculative | Experiments only: (a) agents emit vim-native ops (macros, `:g`, normal-mode sequences) as a legible, replayable edit dialect; (b) attention telemetry — agent reads jumplist/changelist/recent buffers to infer user focus. |

V1–V2 are the core deliverable. V3–V4 build on the same substrate. V5 is named so the
experiments have a home, but nothing in phases 0–5 depends on it.

## Architecture

```
Claude Code session (driver)                     Neovim (parallel lens)
  │                                                 │
  ├─ PreToolUse hook ──► ledger.tsv + snapshots ──► :ClaudeReview (codediff walk)
  ├─ SessionStart/End ─► registry.json ───────────► roster picker / lualine fleet
  ├─ nvim-bridge skill ─► nvim_bridge.py ─────────► staging (open/marks/harpoon/qf)
  │                                                 │
  ◄─ skill v2: read annotations ◄── annotations.jsonl ◄── annotate plugin (<leader>ac)
  ◄─ tmux poke ("review ready") ◄────────────────────── :AgentSend [session]
```

### Substrate

```
~/.local/state/claude-nvim/
├── registry.json                    # live sessions (cross-session, root level)
└── <session_id>/
    ├── ledger.tsv                   # ts \t tool \t file_path \t snapshot_path
    ├── snapshots/<hash>.<ext>       # pre-edit copies (first touch per session)
    └── annotations.jsonl            # flushed review comments (append-only)
```

All plain files. Debuggable with `cat`. No daemon.

### Components

Each ships standalone value, in build order.

**1. Edit ledger** — implement `docs/claude-edit-preview.md` as designed, with one
delta: relocate from `/tmp/claude-snapshots/` to the state dir above. PreToolUse hook
on `Edit|Write|MultiEdit` snapshots the original on first touch and appends a ledger
row. Passive by default; `CLAUDE_PREVIEW=block` opt-in blocking review survives
unchanged. SessionEnd GC for dirs older than 7 days.

**2. Review surface** — `lua/plugins/claude-review.lua`. `:ClaudeReview [session]`:
snacks picker over ledger rows → codediff (fallback `diffthis`) of snapshot vs current.
`:ClaudeReviewLast` diffs the most recent entry directly. A dedicated sign (distinct
from gitsigns) marks any open buffer whose path appears in the current session's
ledger. Keybind under the `<leader>a*` family (`<leader>aR`).

**3. Annotation plugin** — new `lua/annotate/init.lua` (+ thin plugin spec). The core
primitive of the return channel.

- `<leader>am` (normal: current line; visual: range) opens a small input; comment is
  stored as an extmark-anchored annotation and rendered as virtual text + sign.
  (`<leader>ac` is taken by sidekick's Toggle Claude.)
- Works identically in code buffers, diff buffers, and markdown plans — an annotation
  does not care what it anchors to.
- `<leader>al` lists session annotations (snacks picker, jump on select);
  `<leader>ax` deletes the annotation under cursor.
- Optional model hint: a leading `@haiku` / `@sonnet` / `@opus` / `@fable` token in the
  comment body is parsed out at flush time into the `model_hint` field.
- Serialization schema (one JSON object per line in `annotations.jsonl`):

```json
{
  "id": "a-<uuid8>",
  "file": "/abs/path.ts",
  "range": {"start_line": 120, "end_line": 128},
  "anchor_text": "the first anchored line's text",
  "context_before": ["...", "..."],
  "context_after": ["...", "..."],
  "body": "this boundary belongs in the service layer",
  "model_hint": null,
  "target_session": "<session_id or null>",
  "created": "ISO8601",
  "consumed": false
}
```

`anchor_text` + context lines exist so the consuming agent can fuzzy re-anchor if the
file has drifted since flush — re-anchoring is the agent's job, not the editor's.

**4. Return channel** — two halves:

- nvim side: `:AgentSend [session]` marks pending annotations flushed, writes them to
  the target session's `annotations.jsonl`, and pokes the session: via sidekick's
  `session:send()` when it is the attached session, else raw
  `tmux send-keys -t <pane>` using the registry's pane id. The poke is a single line:
  `Annotations flushed: <path>. Read them via the nvim-bridge skill and address each.`
  With no argument and multiple live sessions, a picker chooses the target.
- Claude side: nvim-bridge skill v2 adds an `annotations` command to `nvim_bridge.py` —
  reads unconsumed annotations for the current session (or a given path), returns JSON,
  rewrites them with `consumed: true`. Skill doc gains a "consume review" workflow: read annotations →
  address each → reply with per-annotation dispositions.

**5. Session registry** — SessionStart hook appends
`{session_id, cwd, tmux_pane ($TMUX_PANE), pid, started}` to `registry.json`;
SessionEnd removes the entry. Staleness guard: any nvim-side read validates panes with
`tmux has-session`/pane liveness and prunes dead entries. Roster picker
(`<leader>as`): shows live sessions with cwd + unreviewed-edit count; select to set the
default annotation/`:AgentSend` target.

**6. Fleet segment** — lualine component reading registry + ledgers: live session
count and unreviewed-edit count for the current session's ledger. Pure read; cached
with a short TTL like the existing branch cache.

## Phase 0 — Agentic-Readiness Fixes

Audit findings through the parallel-lens frame; these precede feature work because V1
reliability depends on them.

| Finding | Problem | Fix |
|---------|---------|-----|
| hbac autoclose (threshold 8) | Garbage-collects agent-staged buffers mid-review | Bridge pins buffers it opens (`hbac` pin API) — `open`/`open_many` gain a pin step |
| scope.nvim per-tab buffers | Staged buffers invisible from other tabs | Convention: bridge stages into the current tab; document `:ScopeMoveBuf` as the escape hatch |
| kulala "doesn't seem to work?" TODO | Bridge's `kulala_gen` workflow is dead if the plugin is broken | Verify once; wire `global_keymaps` if fixable in <30min, else drop plugin + bridge command + skill section |
| 9 `.deprecated` plugin files | Noise for any agent reading the config | Delete (git history suffices) |
| sidekick state shape unverified | Prompt-answer keymaps + `:AgentSend` poke depend on `state.terminal` pane id | Inspect actual shape once, encode the accessor in one helper shared by both features |
| Marks alphabet (A–Z) | Global marks are a scarce staging resource | No fix — annotations supersede marks for review anchoring; marks stay for navigation |
| Old-audit leftovers (telescope trio, catppuccin, commented LSP blocks) | Config noise, no agentic impact | Fold in opportunistically; not blocking |

## Phases

Each phase ends with a manual smoke test; a phase is done when its smoke passes.

- **Phase 0 — readiness:** fixes above. Smoke: bridge stages 10 files, all survive
  5 minutes of unrelated editing; buffers visible in the working tab.
- **Phase 1 — edit ledger + review:** hooks + `claude-review.lua`. Smoke: run a Claude
  session that edits 3 files, `:ClaudeReview` walks all 3 diffs, signs appear.
- **Phase 2 — annotations:** annotate plugin, local-only. Smoke: annotate code + a
  markdown plan, list, delete, restart nvim (annotations are session-scoped, loss on
  restart is acceptable at this tier).
- **Phase 3 — return channel:** `:AgentSend` + skill v2 `annotations`. Smoke: full
  round trip — agent edits, human annotates 2 files + the plan, `:AgentSend`, agent
  reads and addresses each annotation.
- **Phase 4 — switchboard:** registry hooks, roster picker, routing, model hints.
  Smoke: two live sessions in different repos; route one annotation to each; hints
  parsed correctly.
- **Phase 5 — fleet lens:** lualine segment. Smoke: counts update as sessions
  start/stop and edits accumulate.
- **V5 experiments (unscheduled):** vim-native edit dialect; attention telemetry via
  `getjumplist()`/`g;` history read through the bridge.

## Error Handling (prototype scope)

- **Poke target dead:** registry staleness check before send; on failure, annotations
  remain queued in the exchange dir — any future session can consume them.
- **Extmark drift / file changed after flush:** consuming agent fuzzy re-anchors from
  `anchor_text` + context lines; annotations that can't re-anchor are reported, not
  dropped.
- **Multiple nvim instances:** already handled by bridge socket discovery
  (commit `c78b74c`); registry is keyed by Claude session, not editor instance.
- **Hook failures:** hooks exit 0 always in passive mode; a broken hook degrades to
  "no ledger," never blocks the agent.

## Out of Scope

- MCP server for nvim (rejected; revisit only for non-Claude harnesses).
- Hunk-level accept/reject verdicts (rejected in favor of comments).
- Cross-backend adapters (OpenCode, Copilot CLI) — per claude-edit-preview.md.
- Annotation persistence across nvim restarts (session-scoped is fine at this tier).
- Cost tracking in the fleet segment (needs harness-side data we don't have a clean
  read on yet).

## Files to Touch

- New: `~/.claude/scripts/snapshot-edit.sh`, `~/.claude/scripts/session-registry.sh`
- New: `lua/plugins/claude-review.lua`, `lua/annotate/init.lua` (+ plugin spec)
- Edit: `~/.claude/settings.json` (PreToolUse, SessionStart, SessionEnd hooks)
- Edit: `scripts/nvim_bridge.py` (pin-on-open, `annotations` command)
- Edit: `~/.claude/skills/nvim-bridge/SKILL.md` (v2: consume-review workflow)
- Edit: `lua/plugins/sidekick.lua` (shared pane-id helper, `<leader>as` roster)
- Edit: `lua/plugins/lualine.lua` (fleet segment)
- Edit: `lua/plugins/hbac.lua` (expose pin path if needed)
