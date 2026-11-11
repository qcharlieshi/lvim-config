# Herdr on macOS — Research

**Date:** 2026-08-31 · **For:** cockpit v7 §13 open question ("does Herdr replace the outer-tmux supervisor?")
**Verdict:** **Yes on macOS, yes as supervisor candidate.** Verified running headless on this machine (aarch64-darwin, nixpkgs binary cache). The socket API covers cockpit's entire supervisor + status + tty-steer surface, including two things the v6 spec hand-built: agent-state detection and a reliable prompt-delivery primitive. Adopt for build-order step 4, with the caveats in §5.

## 1. What it is

- `herdrdev/herdr` — Rust agent-aware terminal multiplexer ("the runtime your coding agents live on"). 34k stars, **Apache-2.0** (relicensed from AGPL), pushed daily, 54+ releases since 2026-03. Bundled in Omarchy 4.0. Latest stable **v0.8.2** (2026-08-19).
- Model: background **server** owns real PTYs; clients attach/detach; hierarchy = workspace (project) → tabs → panes. Named sessions are separate namespaces (`herdr session attach <name>`). Runs *inside* an existing terminal, and works inside tmux.
- **Agent awareness**: foreground-process + screen-heuristic detection, zero config — Claude Code has full `idle`/`working`/`blocked` support (blocked = permission prompt / waiting on input). Official Claude Code integration additionally reports **session identity**, so server restart natively re-runs `claude --resume <id>`.

## 2. macOS support — verified

| Claim | Status |
|---|---|
| Ships macOS binaries (Intel + Apple silicon); detection via `proc_pidinfo` | docs + release assets |
| **Runs headless on this Mac**: `herdr server` + `status`/`api snapshot`/`agent list`/full `pane` CLI, isolated `$HOME` | **verified 2026-08-31** (0.8.0 via nixpkgs binary cache, 6.3 MB download) |
| nixpkgs `herdr` 0.8.2, aarch64-darwin **CACHED** | verified via cache.nixos.org |
| Homebrew `brew install herdr` · mise `mise use -g herdr` · `nix run github:herdrdev/herdr/v0.x.y` | docs |
| Unix-socket path must fit `sun_path` (104 chars on macOS) — deep `$HOME`/session dirs fail with `local socket name length exceeds capacity` | **verified** (hit it with a long scratch HOME) |
| Nix *source* builds on macOS currently broken (xcbuild refactor loses `SDKROOT`) — binary cache unaffected | open issue |

**Install for us:** add `herdr` to `home.nix` (`home.packages`) — in nixpkgs at 0.8.2 with a darwin cache; no brew needed.

## 3. Control surface → cockpit mapping

NDJSON over `~/.config/herdr/herdr.sock` (or per-session socket); CLI wraps the same methods; `herdr api schema --json` is self-describing. Herdr injects `HERDR_SOCKET_PATH` / `HERDR_WORKSPACE_ID` / `HERDR_PANE_ID` / `HERDR_ENV=1` into managed panes — same pattern as cockpit's `$COCKPIT_*`.

| cockpit v6 hand-built | herdr primitive |
|---|---|
| outer tmux session per goal | named session per goal (`herdr session attach <goal>`), or default session with workspace-per-track |
| tmux window per worker | workspace/tab/pane per agent (`pane.split`, `pane.run`, `agent.start`) |
| §5 status rules (markers + hooks + stream tail) | `agent.list`, `agent_status` = `idle|working|blocked|done|unknown`; `events.subscribe` → `pane.agent_status_changed` (push, not poll) |
| `needs_you` for tty agents | `blocked` state (screen-heuristic; full support for Claude Code) + `agent.wait --until blocked` |
| tty steer paste protocol (C-u, load-buffer, paste -p -d, 150 ms sleep, Enter retry) | **`agent.prompt`** (with optional `wait: {until, timeout_ms}`) — deletes the whole dance |
| `cockpit grab` (capture-pane) | `pane.read` — sources `visible`/`recent`/`recent-unwrapped`/`detection` |
| worktree tracking hooks | `worktree.list/create/open/remove` + `worktree.*` events (worktree ↔ workspace) |
| `--resume` relaunch plumbing | native agent session restore on server restart (Claude Code ≥ v6 integration) |
| approve/deny on a tty gate | `agent.send_keys` at a `blocked` pane (still keystroke-level — see §5) |
| inbox `uv.fs_event` on markers | one long-lived `events.subscribe` NDJSON connection (the herdr-agent-state plugin does exactly this: `session.snapshot` seed + subscribe + 2 s `agent.list` reconcile poll, since working→idle flips lack an event) |
| operator drives supervisor | official agent skill (`npx skills add herdrdev/herdr --skill herdr -g`), guarded by `HERDR_ENV=1` |
| nvim ↔ pane navigation | `herdr-splits.nvim` (in nixpkgs as `vimPlugins.herdr-splits-nvim`): smart-splits-style two-way nav/resize, `HERDR_ENV`-gated |

Also relevant: `pane.report_agent` / `workspace.report_metadata` let cockpit **push** its own semantic state (e.g. stream-mode workers, `needs_you` from the PreToolUse gate) into herdr's sidebar — herdr can be the single status plane for all four spawn modes, not just tty.

## 4. What herdr does NOT cover

- **No permission gate.** `blocked` tells you a prompt is on screen; approve/deny is still `send_keys`. The stream-mode `PreToolUse` gate (if ever built) remains cockpit's.
- **No artifacts, no steer taxonomy, no lineage** — the judgment layer is untouched, as expected.
- **Headless-stream workers aren't panes.** `-p` FIFO workers have no PTY; if stream mode is ever built they surface via `pane.report_agent`/external reporting, not detection.
- **Not a human event log** — `~/.cockpit` git state is still the record.

## 5. Risks / caveats

1. **#2900 (open, macOS): driving herdr from *outside* a managed pane has silent footguns.** `--current` with `HERDR_PANE_ID` unset falls back to the **UI-focused pane** and succeeds — write verbs (`pane run`, `pane close`, `agent prompt`) can hit the pane the human is typing in. Cockpit CLI runs outside panes (nvim, hooks) ⇒ **rule: always explicit pane/agent ids, never `--current`, never omit targets.** Same issue: `pane.read --source visible` returns an incomplete viewport — use `recent`.
2. **#3217 (open, macOS 0.8.2): multi-agent CPU lag / fan noise**; reporter says disabling toasts + sound alerts stabilized it. Watch before betting the fleet on 0.8.2; disable notifications in config.
3. **Churn**: protocol bumped 19→20 within 0.8.x; "protocol changes may require stopping old servers." Pin via nixpkgs; treat like any rented runtime — isolate calls behind one cockpit module (`supervisor.py`), the same quarantine rule as `runtime.py`.
4. ~279 open issues incl. macOS input-source/CSI-u edge cases (Warp modifiers, dictation, `<C-w>` on non-US layouts). None hit the headless/socket path we'd lean on.
5. Live handoff unsupported for Nix installs (direct installs only) — irrelevant for our use.
6. Environment interactions: one report of corporate EDR (Cortex XDR) SIGKILLing the pane tree; devshell issue open. Not applicable here, noted for completeness.

## 6. Architecture options for cockpit

- **A (recommended): herdr named session replaces the outer tmux session for cockpit goals.** Sessionizer grows a cockpit branch: `herdr session attach cockpit-<goal>`; nvim lives in a pane; workers in workspaces (workspace = track). Detach/reattach and restart-restore come free; `kill` = `herdr session stop`. tmux remains for non-cockpit projects.
- **B (lowest friction): herdr inside the existing tmux session** (supported) — keeps the sessionizer untouched; costs a nested mux and two prefixes.
- Either way, `lua/cockpit/` consumes one `events.subscribe` stream instead of `uv.fs_event` on marker files, and `status` becomes `herdr agent list` + cockpit-pushed metadata.

## 7. Spec impact (v7 → v8 candidates)

- §3/§5: supervisor = herdr session; **delete the tty paste protocol** in favor of `agent.prompt --wait`; status rules collapse to herdr states + `pane.report_agent` pushes; `marker.json` shrinks (session identity restore is native).
- §12 step 4 precondition: **met** — spike done, adopt.
- New rule for `cockpit` CLI: explicit ids only (risk #1).
- Open: does `agent.prompt` deliver mid-turn or queue? (Claude Code coalescing under `send-text` unverified — test before deleting the paste protocol entirely.)
