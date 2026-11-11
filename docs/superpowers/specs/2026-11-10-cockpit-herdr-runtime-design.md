# Cockpit step 1 — herdr runtime + projects

**Date:** 2026-11-10 · **Tier:** Prototype (happy-path smoke test only) · **Repo:** `~/.config/nvim` + `~/.config/nix-darwin`
**Parent spec:** `2026-08-28-cockpit-design.md` (v8). This doc supersedes it where they differ; "track" there = **project** here.

## 1. Intent

Today the inbox can read and reply to agents but can't manage them. Agents are hand-started `claude` sessions in tmux, delivery is a `tmux send-keys` nudge, and "project" is just the git repo an agent happened to post from.

Step 1 makes agents something cockpit **owns**: they run headless in a herdr server, belong to a named (possibly multi-repo) **project**, and can be spawned, killed, interrupted, attached to, and prompted from nvim, with live `idle | working | blocked | done | unknown | offline` status. It is the foundation for:

- **Step 2 — inbox redesign:** project → agent → thread tree, table layout. Not in this doc.
- **Step 3 — project context:** PRD, memory, and context fed to spawned agents; board cards sourced from it. Not in this doc.

## 2. Goals / non-goals / anti-goals

**Goals**
- herdr installed declaratively; headless server always available after login.
- Project definition on disk: name + 1..N repos, one primary.
- Spawn a Claude agent into a project from nvim; kill / interrupt / attach to it.
- Live agent status available to nvim as an in-memory cache (step 2 renders it).
- Replies reach herdr agents via `agent prompt`, not tmux paste.
- Threads posted by herdr agents record which agent and project they came from.

**Non-goals (this step)**
- Inbox table / tree redesign (step 2). Step 1 adds keys and a status glyph to the existing list only.
- PRD / memory / context injection (step 3) — but the project dir leaves room for it.
- Worktrees, `claude --bg` background mode, stream mode, the `cockpit` operator agent.
- Changing the board (kept as-is).

**Anti-goals**
- Breaking the current flow: hand-started tmux agents must keep posting and receiving replies exactly as today (tmux fallback stays).
- Cockpit auto-answering a `blocked` dialog (trust prompts, permission prompts). It surfaces them; you answer.
- Closing herdr panes/workspaces cockpit didn't create.

## 3. Verified facts (herdr 0.9.5, nixpkgs, aarch64-darwin, spiked 2026-11-10)

| Fact | Evidence |
|---|---|
| `workspace create --cwd D` → `.result.workspace.workspace_id`, `.result.root_pane.pane_id`; label defaults to dir basename | spike |
| `agent start NAME --kind claude --pane P [--timeout MS] -- <claude args>` passes args through (`--add-dir` confirmed); returns once idle | spike |
| Untrusted folder → `agent_not_ready` error, agent listed as `blocked` (Claude's trust dialog) | spike (genzed) |
| `agent list` / `agent get` fields: `name, agent, agent_status, pane_id, workspace_id, tab_id, terminal_id, cwd, terminal_title, interactive_ready` | spike |
| `agent prompt NAME TEXT [--wait --timeout MS]`; rejects with `agent_blocked` if at a dialog | spike + `herdr --skill` |
| `pane close P` kills the agent; it drops out of `agent list` | spike |
| Panes get `HERDR_ENV=1`, `HERDR_PANE_ID`, `HERDR_WORKSPACE_ID`, `HERDR_TAB_ID` | `herdr --skill` (prompted check inconclusive — **re-verify in build**) |
| `events.subscribe` takes `{"subscriptions":[{"type":…}]}`. Global types: `pane.updated` (carries `agent_status`), `pane.created/closed/exited/agent_detected`. `pane.agent_status_changed` needs a `pane_id`. | spike: `unknown→working` seen on `pane.updated`; `working→idle` not observed before close |
| Pane IDs aren't reused within a server lifetime; `terminal_id` looks random (`term_65fe…`) | `herdr --skill`; spike |
| Agent names: `[a-z][a-z0-9_-]{0,31}`, unique among live agents | `herdr --skill` |
| `herdr integration install claude` writes `~/.claude/hooks/herdr-agent-state.sh` (session identity → resume after server restart) | `integration status` |
| `claude` lives at `~/.local/bin/claude` | `command -v` |

## 4. Design

### 4.1 Install (nix-darwin)

- `home.nix`: add `herdr` to `home.packages`.
- `home.nix`: `launchd.agents.herdr-server` running `herdr server`, `RunAtLoad = true`, `KeepAlive = false`, `ProcessType = "Interactive"`, logs to `~/Library/Logs/herdr-server.log`. `EnvironmentVariables.PATH` must include `~/.local/bin` and the nix profile bins, or Claude panes restored after a restart come up as empty shells (parent spec §2).
- **Session:** the **default** herdr session. Bare `herdr` then attaches to the same server cockpit drives, so you can always eyeball everything. *(My call.)*
- `herdr integration install claude` gives session identity and resume across server restarts. It edits `~/.claude`, so it's run once by hand (documented), not by nix.
- You run `darwin-rebuild switch --flake ~/.config/nix-darwin#default`.

### 4.2 Projects

`~/.cockpit/projects/<name>.json`:

```json
{ "name": "lilt-mcp", "repos": ["~/dev/lilt/lilt-mcp", "~/dev/lilt/mcp-agent-ui"], "created": "2026-11-10T…" }
```

- `repos[0]` is primary (spawn cwd); the rest become `--add-dir`. Name matches the herdr agent-name charset so it can prefix agent names.
- Step 3 will add `~/.cockpit/projects/<name>/` (PRD, context, memory) next to the JSON. Nothing reads it yet.
- **Create:** `:CockpitProject new` prompts for a name, then multi-select repos (picker over git repos under `~/dev`, `~/.config`). Or hand-write the JSON.
- **Edit:** open the JSON.
- **One herdr workspace per project**, labelled `ck/<name>` so a hand-opened workspace that shares the repo's basename is never adopted (final-review fix). Resolve it at runtime by label (`workspace list`); don't persist workspace IDs. Create on first spawn with `cwd = <primary>`. Spawn only uses the fresh root pane of a workspace it just created; otherwise it splits.

### 4.3 nvim runtime module — `lua/cockpit/herdr.lua`

Thin wrapper; every vendor assumption lives here so step 2/3 and a future swap only touch this file.

- **`ensure()`** — `herdr status server`. If not running, start it detached (launchd may be off/killed) and wait ≤ 3 s. Errors become a `vim.notify` with the log path.
- **Agent cache** — `agents[name] = {name, project, status, pane_id, workspace_id, terminal_id, cwd, title}`.
  - Seeded from `agent list`.
  - Updated from one long-lived `events.subscribe` socket connection (`vim.uv.new_pipe`; types `pane.updated`, `pane.created`, `pane.closed`, `pane.exited`, `pane.agent_detected`).
  - Plus a 3 s `agent list` reconcile **while any cockpit view is visible**, because not every transition emits an event.
  - `project` = the workspace label when it names a known project, else `nil` (ad-hoc herdr agent).
  - Fires `User CockpitAgents` on change, so the UI refreshes. Socket path from `herdr status server`. Reconnect on drop.
- **`spawn(project, prompt?)`**
  1. `ensure()`.
  2. Find or create the project workspace. Pick a pane: the workspace's root pane if it's an agent-less shell, else `pane split <any pane in ws> --direction right --cwd <primary> --no-focus`.
  3. `agent start <project>-<n> --kind claude --pane P --timeout 60000 -- --add-dir …`, where n = lowest free integer.
  4. On success with a prompt: `agent prompt NAME PROMPT` (no `--wait`).
  5. On `agent_not_ready`: notify `"<name> is blocked at startup (likely folder trust): attach to answer"`. The agent stays; the cached status shows `blocked`.
- **`kill(name)`** — `pane close <pane_id>`. Only ever called on a named agent, after confirmation.
- **`interrupt(name)`** — `agent send-keys NAME esc`.
- **`attach(name)`** — `tmux new-window -n <name> 'herdr agent attach <name>'`. Outside tmux: a `:terminal` tab.
- **`prompt(name, text)`** — `agent prompt`. Maps `agent_blocked` → "agent is at a dialog; attach to answer".

### 4.4 Agent ↔ thread linkage (`scripts/cockpit_inbox.py`)

- `session()`: when `HERDR_ENV=1` and `HERDR_PANE_ID` is set, record `herdr = {pane_id, workspace_id, terminal_id, name}` resolved **explicitly**: `herdr pane get $HERDR_PANE_ID` (+ the matching `agent list` entry for `name`). Never `--current`; the parent spec bans it because of #2900, where it falls back to the UI-focused pane. If resolution fails, record **no** `herdr` block; the thread then uses tmux / "next reader" delivery. Keep `tmux_pane` as today.
- `project`: `COCKPIT_PROJECT` env (set by `spawn()` through `workspace.create`/`pane.split` `env`, verified in schema) → else today's `project_of(cwd)`.
- Hook `stop`: treat `HERDR_PANE_ID` like `TMUX_PANE` (today it returns early without `TMUX_PANE`).
  - `watching()` for herdr panes: the pane is `focused` **and** a herdr client is attached (`herdr status client`).
  - **Builder:** verify that `status client` reports attachment; if it can't, treat herdr panes as unwatched.
- **Join key** thread → live agent: `terminal_id`, never `pane_id` alone. Pane IDs restart from `w1:p1` after a server restart, so a dead thread could bind to a new agent.

### 4.5 Delivery (`store.deliver`)

Order:
1. Agent blocked in `wait` → unchanged.
2. Thread has `session.herdr` and that terminal is live in the cache → `herdr.prompt(name, oneliner)`.
3. `tmux_pane` alive → today's `send-keys`.
4. Else → "kept for next reader".

### 4.6 Inbox additions (existing list, no redesign)

- Each thread row gets a status glyph for its agent (from cache via terminal_id): working ◐, blocked ⚠, idle ○, offline ✕, none (tmux/unknown) blank.
- **Keys** (on a thread row, they act on its agent):
  - `s` — spawn: pick a project (`vim.ui.select`, plus a "+ new project" entry), then an optional first prompt.
  - `X` — kill, with confirm: `Kill <name> (<status>)?`.
  - `i` — interrupt.
  - `gt` — attach.
  - These are not available on a thread with no live herdr agent; a notify says why.
- **Agent picker:** `:CockpitAgent`, also `A` in the inbox. It covers agents that have no thread yet, e.g. one just spawned or blocked at the trust prompt.
  - `vim.ui.select` over the live agent cache, one line per agent: `name · project · status · title`.
  - Then an action menu: attach / interrupt / kill (confirm) / prompt (input).
  - When `spawn()` hits `agent_not_ready`, the notify is replaced by a prompt: "`<name>` is blocked at startup — attach now?"
  - Step 2's table absorbs this picker.
- **Commands:** `:CockpitSpawn [project]`, `:CockpitAgent`, `:CockpitProject new|edit`.
- Header help line updated.

## 5. Decisions made in this doc (check these)

1. Default herdr session, not a named `cockpit` session.
2. Workspace ↔ project by label match; no stored IDs.
3. Agent names `<project>-<n>`.
4. Kill = `pane close` (hard). No separate soft stop in step 1; `i` interrupt covers "stop what you're doing".
5. Attach opens a new tmux window.
6. `herdr integration install claude` is a documented manual step.
7. tmux fallback kept for hand-started agents.
8. Status glyph in the old list is a stopgap; step 2 replaces it.
9. After a herdr server restart, old threads show **offline** (join is `terminal_id` only). Keeping them linked via the Claude session id is deferred to step 2 if it bites.

## 6. Risks / verify during build

- `HERDR_*` env presence inside Claude's Bash tool (the spike's prompted check was inconclusive).
- `working → idle` event coverage: the reconcile poll covers it, but measure whether 3 s feels laggy.
- Nested `herdr agent attach` inside tmux + Ghostty: modified-Enter flakiness (parent spec step 1 says remove Ghostty's `shift+enter=text:\n`). Note it; fix only if it bites.
- `agent prompt` mid-turn: queued vs injected is still unverified. The inbox sends regardless (same as today's tmux nudge, which Claude queues). Record the observed behavior in the smoke notes.
- launchd PATH: verify a server-restart-restored pane can find `claude`.

## 6b. Session selection (builder call, settled)

- `herdr.lua` and `cockpit_inbox.py` target the session named by `COCKPIT_HERDR_SESSION`; unset means the default session. Every herdr call passes explicit pane/agent ids (parent spec rule).
- Inside a pane, the herdr env already points at the right socket.

## 7. Done when

**Smoke test isolation (builder call, settled):**
- The script starts its own `--session ckspike` server with `COCKPIT_INBOX_DIR` and a projects dir under a temp dir exported into the server's env, so panes inherit them.
- It uses a real `claude` in `~/.config/nvim`, an already-trusted folder.
- Step 3 is driven deterministically: `agent prompt` with "run exactly: `python3 …/cockpit_inbox.py post …`", and the script asserts on the thread file rather than on model prose.
- It stops and deletes the session at the end.


`scripts/cockpit-smoke-herdr.sh` (happy path, isolated `--session ckspike`) passes:
1. create a project
2. spawn → agent idle
3. the agent posts a thread → the thread carries `herdr.terminal_id` + project
4. reply from nvim (headless) → arrives via `agent prompt`
5. interrupt
6. kill → agent gone, thread shows offline

Plus a manual check in the real default session: `<leader>ka` → `s` → agent appears in `herdr` TUI.
