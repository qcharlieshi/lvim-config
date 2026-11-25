# Cockpit — project summary

_Living summary. Internals (modules, file schema, event kinds, flows): [implementation-details.md → Cockpit](implementation-details.md#cockpit-luacockpit-scriptscockpit). Keys: [keybindings.md → Cockpit](keybindings.md). Open work: `docs/todo/cockpit-*.md`._

## What it is

Cockpit is a control room for running several Claude Code agents at once from Neovim. It has two halves:

- **Agent runtime.** Agents run headless in [herdr](#tech-stack), a terminal workspace manager for AI coding agents. Cockpit groups them into **projects** (sets of repos or worktrees) and spawns, forks, prompts, interrupts and kills them.
- **Review inbox.** Agents post deliverables (docs, diffs, questions) to an inbox. You review them in one nvim tab: edit, annotate, send a verdict. Replies are delivered back into the agent's conversation.

## End goals (inferred from code, plans and history)

1. **One place to supervise many agents.** At a glance: who is working, blocked, idle or waiting on you, across projects.
2. **Review, not babysit.** Agents work unattended and come to you only at decision points (a gate, a question, changed files). Your feedback goes back to them reliably.
3. **Agent = conversation.** An agent is one Claude session, with its transcript, forks and history. It isn't a pane or a thread. (Direction set 2026-11-24, `todo/cockpit-herdr-only.md`.)
4. **Cheap context management.** Fork a conversation (`continue` / `worktree`), and later hand off at stage boundaries (plan → implement → review), so that each agent's context stays small (`todo/cockpit-spawn-dialog-and-handoff-forks.md`).
5. **Natural-language control (newest, uncommitted).** A long-lived, minimal **coordinator** agent plus `<leader>kk` asks from anywhere. You talk to the herd instead of driving keys.

## Daily workflow

```
<leader>ka   open cockpit tab ── rail: project → agent → fork → thread
   s         spawn agent in a project (profile + name pickers, first prompt)
   <CR>      agent → its conversation view (transcript + inbox posts); r = chat to it
   <CR>      thread → deliverable in workspace (CodeDiff for diffs), thread below
   A/N/C/X   approve / +notes / changes / reject   (ga = inline note, edits diff against the sent copy)
   gt / gT   focus in herdr TUI / attach in tmux
<leader>kk   ask from anywhere (coordinator · one-off · fork one-off), with context of where you are
<leader>kc   coordinator conversation
```

Agents post with `scripts/cockpit_inbox.py post` (`--wait` blocks for your verdict; the exit code carries it). Their Stop hook makes them post when a turn changed files or ended in a question, unless you're watching their pane.

## Architecture

```
            you (nvim: rail · workspace · thread · convo · ask/composer floats)
                    │ Lua (lua/cockpit/**)                     ▲
                    │                                          │ pynvim RPC: ctl.run(argv)
   herdr.lua ◄──NDJSON socket──► herdr server ──► claude panes │
      │ spawn/kill/prompt/focus        (one ck/<project>       │
      │ events → agent cache            workspace, tab/agent)  │
      ▼                                     │                  │
   ~/.cockpit/  ◄── append-only JSONL ──────┼── cockpit_inbox.py (agent CLI + Stop hook)
   inbox/ projects/ status/ asks/           │
   coordinator/                             └── coordinator agent ── cockpit-ctl (cockpit_ctl.py)
```

- **Source of truth:** append-only JSONL plus blobs in `~/.cockpit/`. All state (thread status, drafts, read/archived, delivery) is derived by replaying logs. Both Python and Lua read and write them, held together by golden-fixture contract tests.
- **Identity:** Claude **session id** is the owner key (registry `agents.jsonl`, latest record per session wins). herdr `terminal_id` is only the transport address.
- **Delivery:** an outbox with O_EXCL claims, retries and backoff. It runs inside nvim on agent-cache changes, inbox fs events and a 60 s tick.
- **Boundaries:** `herdr.lua` is the only herdr code. `tree.lua` is a pure model. `store.lua` handles events only, and `delivery.lua` handles transport.

## Tech stack

| Layer | Tech |
| --- | --- |
| UI and domain logic | Lua in Neovim (~7.2k lines, of which ~1.2k is the uncommitted coordinator/ask layer: `ui.lua` 1.4k, `rail.lua` 0.9k, `herdr.lua` 0.7k) |
| Agent-side CLI and hooks | Python, stdlib only (`cockpit_inbox.py`, ~0.9k lines) |
| Coordinator CLI | Python + pynvim (`cockpit_ctl.py`), which calls back into the cockpit nvim |
| Runtime | herdr 0.9.5 (external, pre-1.0, socket API), Claude Code CLI, tmux (attach only) |
| Diff review | CodeDiff plugin |
| Tests | pytest (via `uv`) + mini.test headless. Contract fixtures. A 1k-line bash E2E smoke test that spends real tokens |

## Status and maturity (2026-11-24)

- **Tier:** Prototype, with a production-minded core (log I/O rules, exit-code contract, outbox, tests). Built in about 2 weeks (~10k lines including scripts and tests). Over 60 commits touch Cockpit.
- **Real usage so far:** 42 threads (20 of them today), 75 agent messages, 5 replies (2 verdicts), **0 annotations**, **0 pipeline stages**, 3 gates. Three projects (`lilt`, `lilt-mcp`, `nvim`) and about 70 registry records. The coordinator and asks have never run live: there is no `~/.cockpit/coordinator/` and no `asks/`.
- **Done:** herdr-only runtime (hand-started tmux sessions dropped), session-keyed agents and Past, conversation view, forks, profiles, derived names and tickets, outbox, P0 fixes from the architecture review.
- **In flight (uncommitted):** coordinator + `cockpit-ctl`, `<leader>kk` ask (one-off / fork), `context.lua`, hidden profiles.

## Known gaps

- **Sync I/O on the UI thread.** `herdr.request` / `ensure` and `ctl.fresh_agents` use `vim.wait` for up to 3–5 s (`todo/cockpit-perf-plan.md` PERF-1, not started).
- **Every nvim instance runs the whole background:** watchers, outbox, coordinator rotation check and notifications (review CK-7).
- **No GC.** `status/` has 357 files, `review/` 1.2 MB, `blobs/` 0.5 MB (CK-10).
- **`hook prompt` isn't registered,** so turn-diff snapshots never exist and only the fallback runs.
- **Still to do from herdr-only:** remove the `claude` wrapper, threads-as-sessions, resume a dead agent, subagent transcripts.
- **Planned:** spawn/fork dialog (T1), fork provenance (T2), handoff forks (T3), report-to-parent (T4).
- **Monoliths:** `ui.lua` and `rail.lua` (CK-11). Annotations drift after edits (CK-12).

Direction and usability review: [todo/cockpit-direction-review.md](todo/cockpit-direction-review.md).
