# Cockpit performance plan (review P1 1.1–1.4)

**Source:** [cockpit-architecture-review.md](cockpit-architecture-review.md) §2 P1. **Status:** design only, no code yet.
**Already done with the P0 work:** nothing from 1.1–1.4. The outbox's 60 s sweep and its `CockpitAgents` / fs-change flushes (`delivery.flush`) add `store.threads()` calls. PERF-2's cache covers them, and they reuse the thread list that the fs-change path has already parsed.

Every ticket is measured against PERF-0 before and after. A ticket is done only when its own numbers improve and `scripts/test` stays green.

---

## PERF-0 · Synthetic 200-thread benchmark (do first)

**Approach**
- `tests/bench/gen_inbox.py N` writes a synthetic inbox into a temp dir:
  - 200 threads with about 30 events each: messages, replies, annotations, acks, deliveries.
  - 10 % have pipelines.
  - 5 threads are 5 MB: older replies with inline `patch`, to test legacy compatibility.
  - Blobs, plus a `projects/` dir with 3 projects and 40 registry records.
- `tests/bench/bench.lua` runs headless with `-u tests/minimal_init.lua` against that dir. Using `vim.uv.hrtime`, it reports median and p95 over 20 runs for:
  - `store.threads()`, cold and warm.
  - `tree.build({...fixtures})`.
  - `ui.render_rail` on an open rail with the real tree.
  - The fs-change path in `inbox/init.lua`: refresh, `notify_new`, `delivery.flush`.
  - `store.thread(id)` on the 5 MB thread.
- Event-loop stall: with a fake herdr socket (a Python NDJSON server that sleeps 3 s per request), record the worst `vim.schedule` round-trip while one rail tick and one `delivery.flush` run. This is the same probe `lua/config/performance.lua` uses.
- `tests/bench/hook.py`: `hook stop` wall time on a synthetic 50 MB transcript, from a cwd with 12 git repos under it (the org-root case). Report p50 and p95 over 20 runs.
- **Output:** one JSON line per run appended to `tests/bench/results.jsonl` (gitignored), so before and after runs can be diffed.

**Risks:** synthetic shapes drift from real ones. Seed the generator from the event mix in a real `~/.cockpit/inbox` (counts per kind only, no content).

---

## PERF-1 · No sync I/O on the UI thread (review 1.1)

**Approach**
- Make every herdr call from nvim async. `herdr.request` already has the callback path; the sync form (`vim.wait(5000)`) stays only for `scripts/cockpit-spawn.lua`, which is headless. Callers to convert:
  - `herdr.free_name` (`agent.list`, plus a `git branch --list` per candidate). Run one `git for-each-ref refs/heads/fork/<project>-*` up front instead of one call per candidate.
  - `project_pane` (`workspace.list`, `pane.list`, `workspace.create`/`pane.split`) and the `agent.get` in `start_in`. All are already inside `spawn`'s callback chain.
  - `herdr.kill`, `herdr.interrupt` and `herdr.prompt`. The `ui.lua` agent-picker prompt is the only UI caller; give it a callback.
  - `herdr.ensure`: `status server` plus `vim.wait(3000)` becomes `vim.system(..., on_exit)` with a retry timer.
  - `forks.start` (git worktree add, `free_name`).
- **Delivery goes async.** `delivery.attempt` takes a callback, and the transports return through it. `ui.send` reports "sent · delivering…" and `delivery` notifies the result. The outbox makes this safe: the reply is on disk before any transport runs, and a crash mid-delivery leaves a queued reply that `flush` picks up.
  - Watch `delivery.deliver`'s return value: smoke section 5 asserts on it, so it would change to a callback.
- **tmux discovery moves off the render path.** One async `tmux list-panes -a -F '#{pane_id}\t#{pane_title}'` per 3 s tick fills a pane cache. `sessions.pane_titles`, `rail.cleanup`'s `pane_alive` and `delivery.tmux_pane_alive` read the cache, and render never spawns a process.
  - `sessions.attach`/`interrupt` and the tmux transport use `vim.system` with `on_exit`.

**Files:** `lua/cockpit/herdr.lua`, `forks.lua`, `sessions.lua`, `inbox/delivery.lua`, `inbox/rail.lua` (cleanup), `inbox/ui.lua` (send / agent picker callers only), `scripts/cockpit-smoke-herdr.sh` (section 5 expectations).

**Risks**
- Callbacks can land after the cockpit tab or buffer is gone, so guard every UI touch with `nvim_buf_is_valid`.
- Two spawns could race between `free_name` and `claim`. The O_EXCL claim already protects this; keep it as the arbiter.
- Error paths that returned `err` synchronously now have to notify instead. Silent failures are the main regression to test for.

**Measure:** PERF-0's event-loop stall against the 3 s fake herdr. Today it's about 5 s (a sync `vim.wait`); target under 50 ms. Also add a check to `scripts/test`: `rg 'vim\.wait\(' lua/cockpit` must match only `herdr.request`'s sync branch.

---

## PERF-2 · Parse once, re-derive incrementally (review 1.2)

**Approach**
- **Per-file cache in `store.lua`.** Map path to `{ ino, size, mtime_ns, offset, events, derived }`. `store.thread(id)` does:
  1. `fs_stat`.
  2. If ino, size and mtime are unchanged, return `derived`.
  3. If the inode is the same and the file only grew, read from `offset`, decode only the new complete lines, append them to `events`, and re-derive. Derivation is O(events) table work with no JSON, so it's cheap. `offset` advances only past the last `\n`: a torn tail stays unread, which matches the 0.3 reader rule.
  4. If the file shrank or the inode changed, do a full parse.
- **`store.threads()`**: one `fs_scandir` plus a stat per file, and parse only what changed. The fs_event callback passes the filename, so `init.lua` can mark just that entry dirty and skip the stats.
- **Derivation must be idempotent on cached events.** Today `store.thread` annotates events in place (`e.seq`, `e.round`, `m.attempts`, `m.delivered`). Keep that, but treat the returned `derived` as read-only: audit `ui.lua` and `rail.lua` for mutation and `vim.deepcopy` where they write. In tests, `vim.tbl_freeze`-style assertions catch writes.
- **Cache `changed_since_sent(att)`** by `(att.path, size, mtime_ns)` → sha256. It's called on every thread render and winbar update, and hashes the agent's whole file each time.
- **Cache `registry.all(project)`** the same way. `tree.build` reads every project's `agents.jsonl` per render.
- Python's `wait` polls every 2 s and re-reads the whole thread. Give it the same offset trick: remember the byte offset and only parse new lines.

**Files:** `lua/cockpit/inbox/store.lua`, `inbox/init.lua` (dirty-by-filename), `registry.lua` (after the session-id branch lands, since it rewrites this file), `scripts/cockpit_inbox.py` (`wait`).

**Risks**
- A stale cache if mtime granularity hides two writes in one tick. Use `mtime_ns` and `size` together; appends always grow size.
- A file rewritten in place (GC, 1.6) has to change the inode or shrink. Make GC write-and-rename.
- Memory: 200 threads × 30 events is trivial. A 5 MB thread holds its decoded events, so cap the cached `events` (drop the `events` field above about 2 MB and keep only `derived`; the next change does a full parse).

**Measure:** PERF-0 `store.threads()` warm. Target: 200 threads in under 5 ms warm with nothing changed, under 1 ms per changed thread. Rail render p95 before and after. Unit test: the golden fixtures derive identically through the cache, both cold and after incremental appends (append the fixture's events one by one).

---

## PERF-3 · Lazy start, reconnect backoff, one notifier (review 1.3)

**Approach**
- **`setup()` only registers** commands, keys and the `CockpitAgents` autocmd. A new `start()` runs on the first `:Cockpit`, `<leader>ka`/`kb` or `:CockpitSpawn`, or on the first `waiting_count()` call from a visible statusline segment. It does `herdr.start()`, the inbox fs watchers, the outbox sweep timer and the priming parse.
- **Reconnect backoff in `herdr.subscribe`:** 2 s, doubling to 60 s, reset on a successful connect. Herdr being down then costs one connect per minute per instance, not 30.
- **One notifier.** An O_EXCL lock `~/.cockpit/notifier.lock` holds the instance's pid. A lock whose pid fails `uv.kill(pid, 0)` is stale and gets taken over. Only the holder runs `notify_new` and the outbox sweep timer. Other instances still flush on their own `CockpitAgents` events, and the per-attempt claims keep that safe.
  - Release the lock on `VimLeavePre`.
  - Hand-over: other instances retry taking the lock on their 60 s tick.

**Files:** `lua/cockpit/inbox/init.lua`, `lua/cockpit/herdr.lua`, `lua/config/keymaps.lua` (still calls `setup()`).

**Risks**
- Without the cockpit opened, nothing notifies. The notifier election only works for started instances, so start the watchers (not herdr) eagerly in at most one instance: the one that wins the lock at `setup()`.
- A crashed holder leaves a lock: the stale-pid check handles it. Pid reuse is possible but rare; also compare the lock's mtime to the process start time.

**Measure:** `nvim --startuptime` with `require("cockpit.inbox").setup()` before and after (target: cockpit < 1 ms at startup). Count herdr connects per minute with herdr stopped and 3 instances open (log it via 1.8's `log.jsonl`). Count notifications per new message with 3 instances (target 1).

---

## PERF-4 · Cheaper Stop hook (review 1.4)

**Approach**, cheapest checks first, failing open (allow the stop) on any budget overrun:
1. Env and payload checks: no pane, `COCKPIT_INBOX_HOOK=0`, `stop_hook_active`. These cost nothing; they already come first.
2. **Session id from the environment first.** The session-id branch (`cockpit-projects-layout`) adds `claude_session_id()`, which walks the process tree with up to 8 `ps -o ppid=` subprocesses per `post` and per hook call. Check `CLAUDE_CODE_SESSION_ID` first: Claude Code sets it in the agent's Bash env, and it equals `sessionId` in `~/.claude/sessions/<pid>.json`. In the hook, use the payload's `session_id`. Keep the `ps` walk only as a last resort.
3. **herdr identity, lazily and once.** A herdr hook run can call `herdr_identity()` twice (`attached_tmux_pane`, then `session()` when it posts), and each call makes 2 socket round trips (`pane.get`, `agent.list`, 2 s timeout each). Memoize per process. `attached_tmux_pane` only needs `pane.get` for `terminal_id`, so skip `agent.list` unless something is actually posted. Check whether herdr exports the terminal id in the pane env, which would avoid the socket entirely.
4. **`watching()`**: one `tmux display` (about 5 ms) stays, before any transcript work.
5. **Tail-read the transcript.** Read it backwards in 256 KB blocks until the last real human prompt (`human_text`), as `sessions.lua` already does for its tail. That makes the cost proportional to the last turn, not the whole session. Share one helper between `turn_activity` and the `ps`-free session lookup.
6. **`turn_diffs` only when the turn could have changed files**: edited paths in the turn, or a `Bash` tool use, or a turn snapshot that exists.
   - Run the per-repo `git diff` and `ls-files` calls concurrently (`Popen` all, then wait).
   - From an org root, only diff repos that have a snapshot entry or an edited file. Today that's already the case for edited files, but every snapshotted repo is diffed.
7. **Wall-clock budget**, e.g. 1.5 s, checked between steps. On overrun, allow the stop and append `{kind: "hook", decision: "budget", ms, step}` to `~/.cockpit/log.jsonl` (1.8). That log is also the data for tuning the budget.

**Files:** `scripts/cockpit_inbox.py` (`hook_stop`, `turn_activity`, `herdr_identity`, `session`, `turn_diffs`). Land after the session-id branch, since it rewrites `session()` and `herdr_identity()`.

**Risks**
- A tail-read that stops at the wrong "human" entry: tool results arrive as `type=user`. Keep `human_text` as the single predicate and test on fixtures that include long tool-result runs.
- Concurrent git calls in a dozen repos briefly spike CPU. Cap at 4 workers.
- Failing open means a missed "post your changes" block. The log makes those visible.

**Measure:** PERF-0 `hook.py` p50/p95. Targets: under 150 ms p50 for a chatty session with no edits, and under 1.5 s worst case. Cases: (a) 50 MB transcript with no edits, (b) an org root with 12 repos and 3 edited, (c) herdr socket down (today 2 × 2 s of timeouts). Count subprocesses per hook run with `ps`-sampling or a `subprocess.run` wrapper in the test (target: 0 for (a) without tmux).

---

## Order

PERF-0 → PERF-2 (biggest win, smallest risk, makes the rest measurable) → PERF-4 (after the session-id branch merges) → PERF-1 → PERF-3.
