# Cockpit direction review — 2026-11-24

**Scope:** direction, stack and architecture, and usability, for Cockpit as a daily driver. Tier: Prototype (personal repo), so this skips enterprise hardening on purpose. It complements [cockpit-architecture-review.md](cockpit-architecture-review.md), which covers correctness and production gaps, and doesn't repeat it. Project overview: [../cockpit-summary.md](../cockpit-summary.md).

**Evidence used:** source under `lua/cockpit/` and `scripts/cockpit*`, including the uncommitted coordinator/ctl/ask work; the `docs/todo/cockpit-*` plans; git history (first commit 2026-11-10); and a read-only look at `~/.cockpit/`.

---

## 1. Verdict

**The core direction is right; the build order isn't.**

What's right:
- **herdr as the runtime, nvim as the review surface.** Nvim is where the review happens.
- **Append-only logs** as the source of truth.
- **"Agent = conversation"** keyed by Claude session id.
- **Forks and handoffs** as context management.

These are good bets. The herdr-only simplification (dropping hand-started tmux sessions) cut complexity that wasn't paying for itself.

What's off: the build is running well ahead of the usage. In about 2 weeks there are ~10k lines. The real inbox shows:

| Feature | Built | Used |
| --- | --- | --- |
| Threads | 42 | 42 |
| Agent messages | 75 | 75 |
| Replies | full outbox | **5** (2 verdicts) |
| Inline annotations | yes | **0** |
| Pipeline stages | yes | **0** |
| Gates | yes | 3 |
| Board / cards | yes (`<leader>kb`, "legacy") | **0** (no `cards.jsonl`) |
| Coordinator / asks | yes (uncommitted) | not run yet |

Caveat: 20 of the 42 threads are from today, so real use may only just be starting. Still, the uncommitted coordinator adds a **second LLM control layer**: a long-lived agent with rotation, a scratchpad, a CLI and an RPC bridge back into nvim. The first layer (rail → review → reply) hasn't proven its loop yet.

**Recommendation:**
- Finish the herdr-only cleanup and the spawn dialog (T1).
- Ship `<leader>kk` **one-off / fork asks** (cheap, stateless, clearly useful).
- **Hold the coordinator behind them.** Daily-drive for a week with a tiny usage log, then decide what to cut or build next. Section 4 has the argument for and against the coordinator.

---

## 2. What Cockpit is becoming

Inferred from code and plans:

1. **Supervision:** a rail of agents across projects with live status (`◐ ⚠ ○ ✕`) and ✋ counts.
2. **Review loop:** agents post at decision points, you reply with a verdict, and delivery is guaranteed.
3. **Conversation-centric agents:** transcript view, Past sessions, forks. Next on that path: threads-as-sessions, then resume.
4. **Context economics:**
   - continue/worktree forks now
   - handoff forks at stage boundaries (T3)
   - report-to-parent (T4)
   - a barebones coordinator (~11k starting tokens) that rotates instead of compacting
5. **Natural-language front door:** ask from anywhere with the context of where you are; the coordinator drives the herd through `cockpit-ctl`.

Goals 1–3 are the product. Goal 4 is the differentiator: nothing off the shelf does handoff forks well. Goal 5 is a convenience layer, and its value depends on how many agents you actually run at once. With 3–6 agents, the rail is faster than a sentence.

---

## 3. Stack and architecture

### Solid — keep

- **The JSONL event-log model and its I/O rules:** single-write appends, tolerant readers, validated ids, golden contract fixtures. You can grep it, replay it, and debug it with `jq`.
- **`herdr.lua` as the only herdr adapter,** always using explicit targets. If herdr changes or gets replaced, that's one file.
- **Session-id identity.** This was the right call, and it made forks, Past and rotation simple.
- **`tree.lua` as a pure model, and the `store`/`delivery` split.** The fast test suite (~6 s, no herdr, no Claude) is cheap enough that it will keep getting run.
- **Coordinator safety rails:** a narrow tool set, `--strict-mcp-config`, Edit/Write only inside its own dir, a confirm-before-acting rule, and `prompt` refusing a working agent.

### Concerns, in priority order

**A1 — nvim is the daemon, and every nvim is one.** Delivery, reconcile, coordinator rotation and `cockpit-ctl` all run inside whichever nvim(s) are open.
- Each instance starts fs watchers, the outbox flush, the herdr subscription, the coordinator 20 s timer, and its own "Inbox ·" notifications (`keymaps.lua:290` calls `setup()` eagerly).
- The rotation state (`rot`) is per-process. Two nvims can both decide to rotate, and send two checkpoints.
- `cockpit-ctl` targets "whichever nvim asked last" (`coordinator/nvim`). If that nvim is closed, every coordinator command fails. If it's open, `ctl.fresh_agents` blocks *your editor* in `vim.wait` for up to 3 s per command.

Perspectives:
- *(a) Keep nvim as host, elect one owner.* A lock file in `~/.cockpit/` decides which nvim owns it: the first `:Cockpit`/`<leader>ka` takes the lock, and other instances only register keys. Small change, fits Prototype.
- *(b) Headless cockpit daemon.* An `nvim --headless` or Python process owns delivery, reconcile, rotation and the ctl socket, and editor nvims become views. Cleaner, and it means the coordinator works when the editor is closed. But it adds a process to supervise.
- *(c) Push the daemon role into herdr* (hooks, notifications). Not possible as far as I can tell. I haven't verified herdr's plugin or hook surface, so this one is unknown.

**My call:** (a) now. Move to (b) only if the coordinator becomes the main interface, because then "nvim closed → herd deaf" becomes a real problem.

**A2 — There are four entry points and two styles of CLI.**

| Entry point | Language | How it touches state |
| --- | --- | --- |
| `cockpit_inbox.py` | Python | writes the logs directly |
| `cockpit_ctl.py` | Python + pynvim | RPCs into Lua (`ctl.run`), except `ask`/`open`/`bridge`, which run locally |
| `cockpit-claude` + `cockpit-spawn.lua` | shell wrapper + headless nvim | spawns |
| `ctl.lua` / `ask.lua` | Lua | the `claude -p` one-off runner itself |

Each piece is reasonable on its own, but together they're a lot of surface for one person to keep in their head.
- The planned removal of the `claude` wrapper helps.
- Longer term, make `cockpit-ctl` **the** shell entry point for everything: spawn from a terminal, `threads`, `reply`. Then the wrapper isn't missed.
- If A1(b) ever happens, fold the inbox verbs into the same CLI.
- Don't rewrite this now.

**A3 — Sync I/O still sits on the UI thread.** `herdr.request` without a callback (`vim.wait(5000)`), `herdr.ensure` (`vim.wait(3000)`), `ctl.fresh_agents`, and the `tmux list-panes` `systemlist` in herdr.lua. A slow herdr freezes the editor, and the coordinator now *adds* callers. PERF-1 in `cockpit-perf-plan.md` is the right fix and isn't started. Do it before the coordinator lands, or at least make `ctl` use the async reconcile with a short timeout.

**A4 — herdr is a pre-1.0 external dependency** (0.9.5). The code already works around its bugs (#2900 `--current`, startup-pending rename refusal, the trust dialog). The risk is contained by A-solid #2.
- herdr also has its own `agent`, `notification` and `worktree` commands, and possibly an agent list in its TUI. Some of the rail's job may overlap with what herdr already shows. Worth one look before building more agent-status UI.
- I didn't check herdr's docs, so I can't say how much it overlaps.

**A5 — UI monoliths.** `ui.lua` (1.4k lines) and `rail.lua` (0.9k lines) hold most of the UX.
- Not urgent at Prototype tier, but every usability item below lands in them.
- Do one split, `composer` + `thread_view` out of ui.lua, at the start of T1 (the dialog), not as a standalone refactor.

**A6 — No GC.** `status/` holds 357 files, `review/` 1.2 MB, and `blobs/` 0.5 MB after about 2 weeks. That's harmless for months. A one-shot `:CockpitGC` (S) is enough, and it doesn't need to be automatic.

**Not a concern (devil's advocate on the obvious objections):**
- *"Use SQLite."* No. At this volume, being able to grep the logs is worth more. The existing review reached the same conclusion.
- *"Two languages."* The contract fixtures already handle the drift risk.
- *"Rewrite as a standalone TUI or web app."* See §4.

---

## 4. Should this live in nvim, and should the coordinator exist?

### nvim as the host

- **For:** review happens in your editor, with your LSP, CodeDiff, keymaps and buffers. Edits to deliverables are real buffers. Context-aware asks (`context.lua`) only work because you're already there. You live in nvim and tmux.
- **Against:** an editor makes a poor daemon (A1). Lua UI code is verbose: rail plus ui come to about 2.3k lines for what a TUI framework would do in far less. Cockpit also becomes hard to use from anywhere else, like a phone or another machine.
- **Alternatives** (from memory, not re-verified today; check before adopting):
  - Claude Squad: a tmux/TUI multi-agent manager.
  - Conductor and Crystal: desktop apps for parallel Claude Code in worktrees.
  - vibe-kanban: a board for agent tasks.
  - Claude Code's own background/remote sessions and subagents.
  - sidekick.nvim, which this config already has, for an in-editor agent terminal.

  These cover spawn, worktrees and status well. None of them has your **review loop**: verdicts back into the conversation, edits diffed against what was sent, an outbox. And none has **handoff forks**.
- **Recommendation:** stay in nvim for the review and ask surfaces, because that's the differentiated part. Don't grow nvim into the orchestrator. If something needs to run when the editor is closed, it belongs in herdr or a daemon (A1b).

### The coordinator

- **For:**
  - It gives you one front door from anywhere.
  - It can delegate big reads to cheap forks (`ask --fork`), which saves your attention.
  - The scratchpad and TODO give you continuity across days.
  - It's well constrained.
- **Against:**
  - With 3–6 agents, "spawn X in lilt with prompt Y" is slower through the coordinator than rail `s`: you write a sentence, wait for an Opus turn, read its one-line plan, say yes, wait for the ctl RPC.
  - It's another stateful thing to babysit: the trust dialog on first run, rotation, a stale nvim socket, scratchpad drift.
  - It duplicates the rail, but through a slower and less certain channel.
  - The "relay feedback verbatim" rule exists because paraphrase is a real risk.
- **Middle path (recommended):**
  1. Make `<leader>kk` default to **one-off** (or fork when the context has an agent).
  2. Make the coordinator an explicit target.
  3. Use it for a week and count how often you pick it.
  4. If it's rarely chosen, keep `cockpit-ctl` (useful from a plain terminal anyway) and drop the long-lived agent, its rotation and its scratchpad.

---

## 5. Usability suggestions (prioritized)

Effort: S < ½ day · M ≈ 1–2 days · L > 2 days.

| # | Problem | Suggestion | Effort | Why it matters for the end goal |
| --- | --- | --- | --- | --- |
| U1 | "What needs me?" is only visible inside the cockpit tab or in transient `vim.notify` toasts, and every open nvim duplicates the toasts. | A lualine segment `✋N ⚠M` (needs_you threads + blocked agents), visible in every tab. Add `<leader>kn` to **jump to the next waiting item**: a thread → open it, a blocked agent → `gt`. One notifier only (A1a). | S | Goal 1 is attention routing. If you have to open a tab to find out whether you're needed, you'll check less and agents will sit blocked. |
| U2 | Keys collide across windows: `X` is reject in the thread but kill-agent in the rail; `A` is approve vs the agent picker; `N` is +notes vs fresh conversation. There's no which-key group for `<leader>k` and no in-window help. | Give the rail's destructive actions a different letter (e.g. `dd` kill, `<C-n>` fresh conversation) and keep `A/N/C/X` for verdicts only. Add a which-key `<leader>k` group and `?` → a help float per cockpit window, generated from the keymap tables. | S | You'll run this many times a day. One muscle-memory slip should never kill an agent. Discoverability keeps the large key surface usable. |
| U3 | Spawn and fork chain `vim.ui.select`/`input` calls (project → dir → profile → name → prompt). There are 29 prompt call sites across cockpit. A multi-line first prompt is awkward. | Do **T1 (spawn/fork dialog)** next, before T3. Prefill it from context: spawning from a file or ticket puts that ticket in Name and that file in the prompt. Remember the last profile per project. | M | Spawning is the most frequent herd action. Friction here pushes you back to plain `claude` in a pane, outside Cockpit. |
| U4 | The rail is four levels deep (project → agent → fork → thread) while threads are mostly Stop-hook posts. There are two per-agent views (thread vs conversation). | Finish **threads-as-sessions** (herdr-only todo): an agent card shows status, 📎 count and ? count. Make `<CR>` always go to the conversation, with posts inline and `<CR>` on a post opening the deliverable. Thread rows only for gated or explicitly titled posts. | M | Goal 3. One view per agent halves the navigation and matches how you actually use it (75 messages, 5 replies). |
| U5 | `<leader>kk` defaults to the coordinator. The first run stops at a trust dialog (you have to attach and accept, then ask again), and every ask pays for an Opus turn on a shared, rotating session. | Default to **one-off**, or **fork** when the context has a live agent. Keep the coordinator as an explicit `<C-t>` target (§4). Pre-trust `~/.cockpit/coordinator` by adding it to Claude's trusted folders on `ensure_project` so the first run doesn't stall, if Claude Code allows that. **Unverified:** check how Claude Code stores folder trust. | S | Asks are the cheapest high-value feature you have. They should be instant and have no failure modes. |
| U6 | Failure modes are silent or hard to see: herdr down (retries every 2 s forever, per nvim), `hook prompt` never registered (turn diffs fall back to the edited files vs HEAD), Stop hook missing from `settings.json`, stale `coordinator/nvim` socket, missing pynvim venv. | `:checkhealth cockpit` (a `lua/cockpit/health.lua`). It checks: herdr server and version, hooks registered in `~/.claude/settings.json`, `cockpit-ctl` reachable, profiles parse, trust state, and the sizes of the state dirs. | S | When something breaks today, it looks like "agents just didn't post". One command tells you whether it's Cockpit or the agent. |
| U7 | The editor freezes for up to 3–5 s when herdr is slow, and coordinator ctl calls block the editor (A3). | PERF-1 as already planned. At minimum make `ctl.fresh_agents` use the cached agents when the reconcile takes longer than 300 ms. | M | Latency in the editor is the fastest way to stop using an in-editor tool. |
| U8 | A dead agent can be viewed but not continued (Past is read-only). | **Resume** from the conversation view: `claude --resume <sid>` in a new herdr tab, with a new registry record linked as `resumed_from`. | S–M | Goal 3. Conversations outlive panes (reboots, herdr restarts). Without resume, Past is a graveyard. |
| U9 | Review features that nobody has used yet (annotations, stages and pipelines, the board, the `cards.jsonl` lanes) add keys, rail glyphs and code. | Hide them rather than delete: drop `<leader>kb` and the stage strip unless a thread has stages. Revisit after a week of use (U10). Don't build more review features until annotations get used. | S | Fewer concepts on screen. The code stays in git if a workflow needs it later. |
| U10 | Nothing records how you actually use Cockpit, so direction calls rest on gut feel. | Append one line per user action to `~/.cockpit/usage.jsonl` (`{at, action, target}` for spawn, fork, reply, verdict, ask target, focus, attach). A `:CockpitUsage` summary. Delete it once the direction settles. | S | Makes §4's coordinator decision, and U9's hide-or-delete call, rest on data. |
| U11 | Handoff forks (T3) and report-to-parent (T4) are the differentiators, but they're specced on top of a digest pipeline that doesn't exist yet. | After U3, build **T3b (handoff from a deliverable)** first. It needs the least summarizer machinery: the approved doc plus a short delta. T3a and T4 can wait. | M | Goal 4 is where Cockpit beats the off-the-shelf tools. Ship the cheapest version that proves it. |
| U12 | `gT` attach and the `attached/` marker exist only for the `claude` wrapper. With herdr-only, `gt` (focus in the herdr TUI) covers the use case. | Finish the wrapper removal from the herdr-only todo. Base "watched" on herdr `focused`. Expose `cockpit-ctl spawn` as the shell way to start an agent (alias `ck`). | S | Removes a tmux code path and a whole state dir, and leaves one way to see an agent. |

### Suggested order

1. **U2, U1, U6, U5** (all S) — immediate ergonomics plus failure visibility.
2. **U10**, then a week of daily use.
3. **U3 + U4** (one rail/ui pass, with the A5 split folded in).
4. **U7, U8, U12.**
5. **U11.**
6. Decide on the coordinator with U10's data.

---

## 6. Unsure / not verified

- **What herdr already offers** (agent list or notifications in its TUI, hooks). I only saw `herdr --help`. Some rail or status work might duplicate it.
- **The current state of the alternative tools** in §4. They're named from memory and weren't re-checked for this review.
- **Whether Claude Code can pre-trust a folder** non-interactively (U5).
- **Usage numbers** come from a ~2-week-old inbox with most activity today. Treat them as directional, not conclusive.
- **The coordinator and asks have never run live** (no `~/.cockpit/coordinator/` or `asks/`). Its UX costs above are reasoned, not observed.
