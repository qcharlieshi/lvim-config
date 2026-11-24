# Cockpit architecture review — 2026-11-24

**Scope:** `lua/cockpit/**` (~4.4k lines), `scripts/cockpit_inbox.py`, `cockpit-claude`, `cockpit-spawn.lua`, `cockpit-smoke-herdr.sh` at `af17308`.
**Goal:** what has to change to move cockpit from Prototype to Production tier.
**Not covered:** visual and interactive UX QA, and herdr itself.

---

## 1. Shape of the system today

```
 agent side (Python, per Claude process)          nvim side (Lua, per nvim instance)
 ───────────────────────────────────────          ──────────────────────────────────
 cockpit_inbox.py post/wait/read/card  ──┐    ┌── inbox/store.lua   (parse + derive + deliver + ledger)
 cockpit_inbox.py hook stop|prompt     ──┤    ├── inbox/ui.lua      (layout, thread, workspace, composer, board, agent picker)
                                         ▼    ▼   inbox/rail.lua    (render + folds + actions + cleanup)
                          ~/.cockpit/inbox/*.jsonl   inbox/tree.lua    (pure model ✓)
                          ~/.cockpit/projects/…   ├── herdr.lua         (socket client, cache, spawn/kill/attach)
                                                  ├── projects / registry / sessions / forks
 cockpit-claude ─► nvim -l cockpit-spawn.lua ─────┘
                                                       herdr socket ◄──► herdr.lua, cockpit_inbox.py
                                                       tmux         ◄──► store.deliver, sessions, hook
```

### What's already production-grade, and should stay

- **Append-only event logs with derived state.** You can replay, grep and debug them, and they don't depend on any vendor. Keep this as the source of truth.
- **`tree.lua` is pure and takes fixtures.** Use it as the model for the rest of the code.
- **Explicit herdr targets** (never `--current`). herdr threads never fall back to tmux delivery.
- **O_EXCL name claims.** Worktree-fork rollback. Review trees are rebuilt from the sent patch, so the agent's worktree is never touched.
- **Hook crashes are swallowed** (`cmd_hook`), so a hook bug can't wedge an agent.

---

## 2. Findings

Severity: **P0** = wrong behaviour today · **P1** = will bite under load, concurrency or failure · **P2** = maintainability and testability · **P3** = polish.

### P0 — correctness

| # | Finding | Evidence | Fix direction |
|---|---|---|---|
| 0.1 | **Threads from hand-started tmux sessions never attach to their agent.** `session()` records `pid = os.getppid()`, which is the Bash tool's `zsh` (or the hook's `sh`), not Claude. `tree.owner_tid` → `cc:<shell pid>`, but `sessions.list()` keys agents `cc:<claude pid>`. So these threads always land in *unassigned*. Kill (`X`) and the agent's `<CR>` see no threads. | Verified live: python ppid `30889` (`/bin/zsh`), its parent `14641` (`claude`). Real threads carry pids like `58882` / `87082`. | Walk up the process tree to the `claude` ancestor, or join on `CLAUDE_CODE_SESSION_ID` ↔ `sessionId` in `~/.claude/sessions/*.json`. The session id is the stable key and survives pid reuse. Prefer it. |
| 0.2 | **CLI exit codes collide with verdict codes.** `wait` uses `1 = changes_requested` and `2 = reject`. But `sys.exit("msg")` exits 1, an unhandled traceback exits 1, and argparse errors exit 2. An agent running `post --wait` that hits *any* error is told "changes requested" or "rejected". | `VERDICT_EXIT`, `thread_path()`, `cmd_post` | Reserve a distinct range: errors `64+` (sysexits), verdicts `10–13`. Or print the verdict as JSON on stdout and keep the exit code for success/failure only. |
| 0.3 | **Python readers crash on a torn last line.** `read_jsonl` does `json.loads` on every line with no guard. Lua writes replies (which embed whole edit patches) through stdio. A large write can land in several `write()` syscalls, so `wait`, polling every 2 s, can read half a line, crash, and exit 1. Per 0.2, that looks like *changes requested*. Lua's reader already tolerates bad lines; the two sides disagree. | `read_jsonl` (py) vs `read_jsonl` (lua) | (a) Tolerate a trailing partial line in both readers (skip a last line that has no `\n`). (b) Write each event with a single `os.write` / `uv.fs_write` on an `O_APPEND` fd. (c) Keep events small: put patches in `blobs/` and reference them by sha. |
| 0.4 | **Undelivered replies are never redelivered.** Delivery is fire-and-forget: if the agent is offline, `herdr.prompt` fails, the herdr cache is stale, or a tmux pane is gone, the reply sits unacked forever. The `ack` event exists, but nothing on the nvim side acts on missing acks. | `store.deliver`, `pending_replies` | Add an outbox. When an agent turns live/idle (herdr event) or a session appears, redeliver unacked replies for threads it owns. Show "undelivered" in the rail. |
| 0.5 | **Annotations drift after edits.** Notes are pinned to sent-blob line numbers but rendered on the edited buffer. Already noted in the handoff (T5). | `render_notes` | Re-anchor through the `vim.diff` indices you already compute in `render_edits`, or store notes as extmarks while drafting and resolve them to sent-line ranges at send time. |
| 0.6 | **Second-resolution timestamps decide read/unread.** `last.ts > t.read_ts` uses `os.time()` / `int(time.time())`. A message that lands in the same second you open the thread is marked read. | `store.thread` | Compare event order (index in the log) instead of wall time. "Read up to event id X" is exact. |

### P1 — robustness, concurrency, performance

| # | Finding | Fix direction |
|---|---|---|
| 1.1 | **Sync I/O on the UI thread.** `herdr.request` without cb does `vim.wait(5000)`. It's used in `project_pane`, `free_name`, `kill`, `prompt`, `deliver` and `forks.start`. `herdr.ensure` waits up to 3 s. `free_name` runs `git branch --list` per candidate. `deliver` runs `tmux list-panes`. The rail's 3 s timer runs `sessions.list()`, which calls `tmux list-panes` via `systemlist`. A slow herdr or tmux freezes the editor. | Make every herdr call async (it already has the cb path) and use `vim.system(..., on_exit)` for tmux and git. Keep sync only in `cockpit-spawn.lua`, which is headless. |
| 1.2 | **Full re-parse of every thread on every render.** `store.threads()` reads and derives every file. It runs on each 3 s rail tick, each fs event (300 ms debounce), each `waiting_count()` call and each `kill_agent`. `render_thread` and `workspace_winbar` call `store.thread()` again and `sha256` the agent's file (`changed_since_sent`) on every render. It's fine at 20 threads; it scales linearly with history and nothing is ever deleted (1.6). | Add a derived-thread cache keyed by `(path, size, mtime_ns)`. Append-only logs also allow incremental parsing from the last offset. Cache `changed_since_sent` by the file's `(size, mtime)`. |
| 1.3 | **Every nvim instance runs the whole cockpit background.** `keymaps.lua` calls `setup()` eagerly. Each nvim gets fs watchers, a primed parse of all threads, a herdr subscription and a reconcile. When herdr is down, `subscribe()` retries every 2 s forever in every instance. Every instance also fires the same "Inbox · …" notification. | Lazy-start: commands and keys register at startup, but `herdr.start()` and `watch()` run on first `:Cockpit`, or when the statusline segment is visible. Back off exponentially on reconnect. Elect one notifier (lock file in `~/.cockpit/`) or notify only from the instance with the cockpit tab open. |
| 1.4 | **The Stop hook runs on every unwatched stop of every tmux/herdr Claude.** It makes up to 2 herdr socket calls (2 s timeout each) and a `tmux display`. It reads the **whole transcript** (can be tens of MB late in a session) and runs `git diff` / `ls-files` per repo. From an org root like `~/dev/lilt`, that's every repo under it. | Read the transcript backwards from the end until the last human prompt (you already do a tail read in `sessions.lua`). Do cheap checks first (`stop_hook_active`, watched pane) and herdr identity last. Put a wall-clock budget on the hook and fail open. |
| 1.5 | **`send` is a non-atomic multi-step sequence.** It does append reply → ledger → `clear_edits` → `deliver` (sync) → schedule buffer teardown. A crash or error midway leaves edits on disk that the next render shows as unsent, and they'd go out again. Reply text and answers live only in memory (`drafts`), so quitting nvim loses them. | Persist drafts as `draft` events, or in a `drafts/<tid>.json`. Make `send` idempotent: the reply event carries the edit shas it consumed, and edits whose sha is already in a reply are ignored. Deliver asynchronously after the append. |
| 1.6 | **Nothing is ever garbage-collected** except `turns/` and `status/`. `blobs/`, `review/<tid>/` (already 800 K for 20 threads, and it holds full file copies), `edits/`, `waiting/`, `attached/`, `names/`, and archived threads all grow without bound. | Add a `:CockpitGC` / `cockpit_inbox.py gc`. Delete `review/` and `edits/` for archived or replied threads. Remove unreferenced blobs (mark and sweep over the threads). Remove stale `attached/`, `waiting/` and `names/` entries. |
| 1.7 | **Path inputs aren't validated.** `--thread`, `:Cockpit <id>`, and `wait/read <tid>` become file paths as-is (`../` works). Today only local, trusted callers reach them, but agent output feeds `--thread`. | Validate thread ids in one place on both sides: `^[A-Za-z0-9_-]+$` (the hook already does this for the reply trigger). |
| 1.8 | **Nothing logs failures except `vim.notify` and hook stderr.** If delivery fails while nvim is closed, or a hook is slow, you can't find out afterwards. | Append to `~/.cockpit/log.jsonl` (one line per delivery, hook decision and herdr error, with a duration). It doubles as the data for 1.4 budgets. |

### P2 — maintainability and testability

| # | Finding | Fix direction |
|---|---|---|
| 2.1 | **One schema, two implementations, no contract.** Python and Lua both write and read the event schema. They already disagree: lanes (`cancelled` exists only in Python), tolerant vs strict parsing, and `cmd_list`'s "open/replied" vs `store.thread` status. `v: 1` is written but never checked. | Write a schema doc or JSON Schema for each `kind`, plus a **golden fixture dir** (a few thread files, each paired with its expected derived state) that both a pytest and a Lua test assert against. Readers skip events with an unknown `v`. |
| 2.2 | **Layering is inverted.** `store` (data) calls `herdr` and `tmux` in `deliver` (transport). `ui` and `rail` require each other. `ui.lua` (1355 lines) holds layout, thread view, workspace editing, composer, board and agent picker. | Extract `delivery.lua`: store → events only, delivery → transports. Split `ui.lua` into `layout`, `thread_view`, `workspace` (edits + notes), `composer` and `board`. Rail actions call a small `actions.lua` instead of `ui()`. The goal is that only `ui/*` touches windows. |
| 2.3 | **The only test is a 1048-line bash E2E.** It needs a real herdr server and **real Claude agents (tokens)**, and section 12 creates worktrees and branches in your **real repos** (`~/.config/nvim`, `~/dev/genzed`). There are no fast tests for the pure logic: `store.thread` derivation, `tree.build` (fixtures exist but run only inside the bash script), `turn_activity`, `hook_stop` routing, `format_reply`, `stage_step`, or `diff_loc`. | Three levels. (1) **Unit**: pytest for `cockpit_inbox.py` and a headless-nvim busted/mini.test runner for `store`, `tree` and `diff_loc`, both under 5 s. (2) **Contract**: the golden fixtures from 2.1. (3) **E2E**: the existing smoke test, using scratch git repos made in `$T` instead of real ones, with Claude-spending sections behind a flag. |
| 2.4 | **Hard-coded environment.** `git_roots` scans `~/dev` and `~/.config`. The herdr socket path is built by hand in two languages. `CLI = python3 <path>` is baked into agent instructions. `stylua` isn't on PATH (handoff T5), so the Lua isn't formatted. | Put these in one `config.lua` and env table. Add `stylua` to `home.nix`. Format with `ruff format` / `ruff check` for Python. |
| 2.5 | **Autocmds have no group.** `rail.attach` creates a global `WinResized` and a buffer `BufWinEnter` with no augroup. A wiped and recreated rail buffer adds another set each time. | Use one `cockpit` augroup with `clear = true` per buffer-scoped group. |
| 2.6 | **`turn_activity` decides "posted" by substring.** `"cockpit_inbox.py" in cmd and " post" in cmd` also matches `post --help`, or an echo of the command. | Match the tool_result too (a thread id was printed), or have `post` drop a `turns/<sid>.posted` marker that the hook reads. |

### P3 — polish (from the handoff, still open)

Wire `hook prompt` (UserPromptSubmit) so turn snapshots exist (today only the fallback runs). Return to the cockpit tab on `CodeDiffClose`. Make the CodeDiff base side read-only. Lua `store.lanes` lacks `cancelled`.

---

## 3. Design decisions worth arguing about

**Storage: JSONL vs SQLite.**
- *For SQLite (WAL):* atomic multi-row writes (fixes 0.3 and 1.5), indexed queries (fixes 1.2), safe concurrent readers, and Python ships `sqlite3`.
- *Against:* Lua needs `sqlite.lua` or the `sqlite3` CLI (a new dependency), you lose grep/tail debuggability, and migrations become real work.
- *My call:* **keep JSONL** at this volume (20 threads, 116 K). Fix the specific weaknesses: single-write appends, tolerant readers, mtime-keyed cache, GC. Revisit past ~1k threads, or if you add cross-thread queries such as feedback mining.

**Two languages for the domain.**
- *Python-only core* (Lua shells out to `cockpit_inbox.py derive`) gives one implementation, but adds a process spawn per render.
- *Lua-only* (the CLI becomes `nvim -l`) adds ~40 ms of startup per hook call, and hooks run often.
- *Keep both, with a contract* (2.1) is the cheapest way to stop drift. **Recommended.** Keep the Python side "dumb": write events, read replies. Derivation stays in Lua.

**Polling vs events.** Three refresh sources overlap today: the herdr `events.subscribe`, inbox fs_events, and a 3 s timer that re-renders the whole rail. Production shape:
- fs_event → invalidate that thread's cache entry → render.
- herdr events → agent cache.
- The timer survives only for tmux sessions, which emit nothing. It reads `~/.claude/sessions` asynchronously and re-renders only on a diff.

**Identity.** The system mixes four agent keys: herdr `terminal_id`, `cc:<pid>`, agent name, and `pane_id`. Claude's **session id** is the one thing every source shares: herdr's `agent_session`, `~/.claude/sessions/*.json`, status files, the hook payload, and `CLAUDE_CODE_SESSION_ID` in posts. Making it the primary owner key fixes 0.1, and makes forks and resumes cleaner. Keep `terminal_id` only as the herdr *transport* address. Devil's advocate: a resumed/forked session gets a new session id, so ownership follows the conversation, not the pane. For a review inbox that's arguably what you want.

---

## 4. Proposed tickets (no code until approved)

Ordered by value ÷ effort. **Production tier** means each bug fix starts with a regression test that fails for the reported reason.

1. **CK-1 · Test harness first.** pytest plus a headless-nvim Lua test runner, golden thread fixtures, and `make test`/`just test` under 5 s. Rewrite smoke section 12 to use scratch repos. *Done when* `test` runs with no herdr, no Claude and no real repos touched.
2. **CK-2 · Session-id ownership (0.1).** Posts and hook record `session_id` (`CLAUDE_CODE_SESSION_ID` / payload). `owner_tid` prefers it, and sessions.lua keys agents by it. Migration: old threads fall back to `herdr.terminal_id`, else unassigned.
3. **CK-3 · Safe log I/O (0.3, 1.7).** Single-syscall appends on both sides. Tolerant readers on both sides. Shared thread-id validator. Patches move into blobs.
4. **CK-4 · CLI exit-code contract (0.2).** New codes, documented in the docstring, `NEXT_STEP` and the fork preamble. Tests for each path.
5. **CK-5 · Delivery outbox (0.4, 2.2a).** Extract `delivery.lua`. Redeliver unacked replies on agent live/idle. Rail shows "undelivered". Log to `log.jsonl` (1.8).
6. **CK-6 · Async + cached rendering (1.1, 1.2).** Async herdr, tmux and git everywhere in nvim. Thread cache keyed by size and mtime. Measure before and after with `:Lazy profile` and a 200-thread synthetic inbox.
7. **CK-7 · Lazy start + single notifier (1.3).**
8. **CK-8 · Durable drafts + idempotent send (1.5, 0.6).**
9. **CK-9 · Hook budget (1.4, 2.6).** Tail-read the transcript, cheap checks first, time budget, `posted` marker. Wire `hook prompt`.
10. **CK-10 · GC (1.6).**
11. **CK-11 · Split `ui.lua` (2.2b), one augroup (2.5), config module and formatters (2.4).** Do this last so the earlier tickets have tests guarding the refactor.
12. **CK-12 · Re-anchor notes (0.5).**

## 5. Open questions

1. Is the **Production** target for all of cockpit, or the **core** only (store, delivery, CLI, hooks), with the UI staying Prototype? I'd recommend core-only: that's where the silent failures are.
2. Should session id be the owner key (CK-2)? It changes which threads group under a forked or resumed agent.
3. Can the test suite add a dev dependency (`busted` or `mini.test` for Lua, `pytest` through `uv`)?
