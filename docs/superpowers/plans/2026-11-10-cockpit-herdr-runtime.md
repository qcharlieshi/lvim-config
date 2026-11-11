# Cockpit Step 1 — herdr Runtime + Projects Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cockpit spawns, kills, interrupts, attaches to and prompts Claude agents running headless in herdr, grouped by multi-repo projects, with live agent status in the cockpit rail.

**Architecture:**
- **herdr calls:** every one goes through `lua/cockpit/herdr.lua` (nvim) or a small socket helper in `scripts/cockpit_inbox.py` (agent side). Both speak herdr's NDJSON socket API directly: one connection per request, plus one long-lived `events.subscribe` connection.
- **Projects:** JSON files under `~/.cockpit/projects/`, one herdr workspace per project, matched by label.
- **Threads ↔ agents:** joined by herdr `terminal_id`.

**Tech Stack:** Neovim 0.11 Lua (`vim.uv` pipes, `vim.json`), Python 3 stdlib (`socket`, `json`), herdr 0.9.5 (installed; default session socket `~/.config/herdr/herdr.sock`).

**Spec:** `docs/superpowers/specs/2026-11-10-cockpit-herdr-runtime-design.md` (parent: `2026-08-28-cockpit-design.md`)

## Global Constraints

- **Quality tier: Prototype.** Happy-path tests only, i.e. the smoke script below. No unit-test framework, and no error handling beyond what's listed.
- **Targets:** every herdr call names its target explicitly (pane id or agent name). **Never `--current`, never an omitted target** (herdr #2900).
- **Pane reads:** use `source = "recent"` or `"recent-unwrapped"`, never `"visible"`.
- **Session:** `COCKPIT_HERDR_SESSION` env selects the herdr session; unset means default.
  - Socket path: default `~/.config/herdr/herdr.sock`; named `~/.config/herdr/sessions/<name>/herdr.sock`.
  - Inside a herdr pane, prefer `HERDR_SOCKET_PATH` if set.
- **Request frame:** `{"id": "<str>", "method": "<m>", "params": {...}}\n`. The response is the line with the same `id`; `error` holds `{code, message}`.
- **Agent names:** `^[a-z][a-z0-9_-]{0,31}$`, format `<project>-<n>`, where n is the lowest free integer ≥ 1. Project names use the same charset, max 28 chars.
- **Spawned agents:** `kind = "claude"`, args `--add-dir <repo>` for each non-primary repo, start timeout 60000 ms. Panes get env `COCKPIT_PROJECT=<project>` (plus `COCKPIT_INBOX_DIR` when set in nvim).
- **Kill:** `pane.close`. **Interrupt:** `agent.send_keys` with `keys = ["esc"]`.
- **Never** close panes or workspaces that aren't a named live agent's own pane. Never answer a `blocked` dialog.
- **Hand-started tmux agents:** keep today's behavior. The tmux delivery path stays.
- **Commits:** only the files each task lists. The nvim repo has unrelated uncommitted edits (`lazy-lock.json`, `options.lua`, `lsp.lua`, …), so never `git add -A`.

## Review Focus

1. **herdr server not running** when `s` / `A` / `:CockpitSpawn` is used → `ensure()` starts it, or notifies with the log path. Never a Lua traceback. Pinned in Task 2.
2. **Spawn into an untrusted folder** (Claude's trust dialog) → the agent stays, shows ⚠ blocked, and you're asked "attach now?". Pinned in Task 4's smoke step (`genzed`-style untrusted temp dir).
3. **Thread whose agent was killed** → rail shows ✕ offline. A reply falls through to "kept for next reader", never to some other live pane. Pinned in Task 6.
4. **Ad-hoc herdr agent not spawned by cockpit** (you ran `claude` in a herdr pane yourself) → it shows in the picker with project `—` and is killable. The project workspace lookup never touches it. Pinned in Task 4.
5. **Agent posts from a herdr pane with no `COCKPIT_PROJECT`** → project falls back to `project_of(cwd)`; the thread still gets its `herdr` block. Pinned in Task 1.

---

### Task 0: Baseline commit of the current cockpit code

`lua/cockpit/` and `scripts/cockpit_inbox.py` are **untracked**; the rail/workspace rewrite from 2026-11-10 21:52 was never committed. Commit it as-is first so every later diff is reviewable.

**Files:** `lua/cockpit/inbox/{init,store,ui,review}.lua`, `scripts/cockpit_inbox.py`, `docs/superpowers/specs/2026-11-10-cockpit-herdr-runtime-design.md`, this plan. Add `scripts/__pycache__/` to `.gitignore`.

- [ ] **Step 1:** **Ask the user before this commit.** It records another session's work under their name.
- [ ] **Step 2:** `git add` exactly those paths + `.gitignore`; commit `chore(cockpit): baseline rail/workspace inbox + herdr step-1 spec`.

---

### Task 1: Agent side — herdr identity + project on posted threads

**Files:**
- Modify: `scripts/cockpit_inbox.py` (`session()` ~L109, `project_of` call sites, `watching()` ~L369, `hook_stop()` ~L391)
- Create: `scripts/cockpit-smoke-herdr.sh` (sections are added by later tasks)

**Interfaces:**
- Produces:
  - `herdr_call(method: str, params: dict) -> dict | None` returns the `result` or `None` on any error.
  - `herdr_identity() -> dict | None` returns `{"pane_id", "workspace_id", "terminal_id", "name"}`.
  - `session()["herdr"]` is that dict, or absent.
  - Thread `project` = `COCKPIT_PROJECT` env, else `project_of(cwd)`.

- [ ] **Step 1: Write smoke section 1** in `scripts/cockpit-smoke-herdr.sh`:
  - **Setup:** `set -euo pipefail`; `T=$(mktemp -d /tmp/ck.XXXX)` (short path: macOS socket limit is 104 chars); `export COCKPIT_INBOX_DIR=$T/inbox COCKPIT_PROJECTS_DIR=$T/projects COCKPIT_HERDR_SESSION=ckspike`.
  - Start `herdr --session ckspike server` in the background with those env vars, and wait for `herdr --session ckspike status server` to report `status: running`. `trap` → `herdr --session ckspike server stop; herdr session delete ckspike; rm -rf $T`.
  - `workspace create` (via `herdr --session ckspike workspace create --cwd ~/.config/nvim`) → take `root_pane.pane_id` as `$P`.
  - `herdr --session ckspike pane run $P "COCKPIT_PROJECT=smoke python3 $CLI post --title s1 --text hi"`, then `pane wait-output $P --match '-s1' --timeout 10000`.
  - **Assert** with python on `$T/inbox/threads/*-s1.jsonl` line 1:
    - `session.herdr.pane_id == $P`
    - `session.herdr.terminal_id` starts with `term_`
    - `project == "smoke"`
  - Run a second post without `COCKPIT_PROJECT` and **assert** `project == "nvim"` (Review Focus 5).
- [ ] **Step 2:** Run `bash scripts/cockpit-smoke-herdr.sh`. Expected: FAIL at the `session.herdr` assertion (KeyError).
- [ ] **Step 3: Implement** `herdr_call`, `herdr_identity`, the `session()` field and the project rule.
  - `herdr_identity` returns `None` unless `HERDR_ENV == "1"` and `HERDR_PANE_ID` is set.
  - It calls `pane.get {"pane_id": HERDR_PANE_ID}`, then picks `name` from `agent.list` where `pane_id` matches (absent → omit `name`).
  - Socket path follows Global Constraints. Timeout is 2 s.
- [ ] **Step 4: Stop hook.**
  - `pane = TMUX_PANE or HERDR_PANE_ID`.
  - `watching()` for a herdr pane: `pane.get` → `focused`, and `herdr status client` (subprocess, 2 s) output contains `status: running`. Otherwise unwatched.
  - Record in the smoke notes whether `status client` actually reports attachment.
- [ ] **Step 5:** Run the smoke script. Expected: section 1 PASS.
- [ ] **Step 6:** Commit `scripts/cockpit_inbox.py scripts/cockpit-smoke-herdr.sh`: `feat(cockpit): record herdr identity + project on posted threads`.

---

### Task 2: `lua/cockpit/herdr.lua` — socket client, ensure, agent cache

**Files:**
- Create: `lua/cockpit/herdr.lua`
- Modify: `scripts/cockpit-smoke-herdr.sh` (section 2)

**Interfaces:**
- Produces:
  - `M.request(method: string, params: table, cb?: fun(err: {code,message}|nil, result: table|nil))`. Async when `cb` is given; sync (≤ 5 s, via `vim.wait`) when not, returning `err, result`.
  - `M.ensure() -> boolean`. Runs `herdr [--session S] status server`. If not running, spawns `herdr [--session S] server` detached (`vim.system(..., {detach = true})`) and polls for ≤ 3 s. On failure: `vim.notify("cockpit: herdr server not running — see ~/.config/herdr/herdr-server.log", ERROR)` and returns `false`.
  - `M.agents() -> table<string, Agent>`, keyed by agent name. `Agent = {name, project, status, pane_id, workspace_id, terminal_id, cwd, title}`.
    - `status` ∈ `idle|working|blocked|done|unknown`.
    - `project` = the label of `workspace_id` when `require("cockpit.projects").get(label)` exists, else `nil`.
  - `M.by_terminal(terminal_id) -> Agent|nil`
  - `M.start()` / `M.stop()`. Seed from `agent.list` + `workspace.list`, then open the subscription. Types: `pane.updated`, `pane.created`, `pane.closed`, `pane.exited`, `pane.agent_detected`. Reconnect after 2 s on drop.
  - `M.watch(on: boolean)` — the 3000 ms `agent.list` reconcile timer, on only while cockpit is open.
  - Every cache change fires `vim.api.nvim_exec_autocmds("User", {pattern = "CockpitAgents"})`.
- Consumes: `require("cockpit.projects").get` from Task 3. Stub it as `pcall(require, …)` returning `nil` so this task stands alone.

- [ ] **Step 1: Write smoke section 2.**
  - Start a claude agent in the section-1 workspace: `herdr --session ckspike pane split $P --direction right --cwd ~/.config/nvim --no-focus` → `$P2`, then `agent start smoke-1 --kind claude --pane $P2 --timeout 60000`.
  - Run headless nvim (`nvim --headless -u NONE -i NONE --cmd 'set rtp^=~/.config/nvim' -l $T/t2.lua`) with `t2.lua`:
    - `require("cockpit.herdr").start()`, then `vim.wait(5000, function() return agents()["smoke-1"] end)`.
    - **Assert** `status == "idle"`, `terminal_id` matches `^term_`, and the `CockpitAgents` autocmd fired at least once.
- [ ] **Step 2:** Run it. Expected: FAIL (`module 'cockpit.herdr' not found`).
- [ ] **Step 3: Implement** `request`, `ensure`, the cache, the subscription and `watch`.
  - Use `vim.uv.new_pipe(false):connect(sock, cb)`. Buffer reads and split on `\n`. Ids are `"ck" .. counter`.
  - `pane.updated` → update `status`/`pane_id`/`title` for the agent on that pane. `pane.closed` / `pane.exited` → drop it. `pane.agent_detected` → trigger one reconcile.
- [ ] **Step 4: Review Focus 1** — append to `t2.lua`:
  - `vim.env.COCKPIT_HERDR_SESSION = "ckdead"`, then `assert(require("cockpit.herdr").ensure() == true)`, which starts that server.
  - Then `herdr --session ckdead server stop` and delete it in the trap.
- [ ] **Step 5:** Run it. Expected: section 2 PASS.
- [ ] **Step 6:** Commit `lua/cockpit/herdr.lua scripts/cockpit-smoke-herdr.sh`: `feat(cockpit): herdr socket client + live agent cache`.

---

### Task 3: Projects

**Files:**
- Create: `lua/cockpit/projects.lua`
- Modify: `lua/cockpit/inbox/init.lua` (`setup()`: register `:CockpitProject`)

**Interfaces:**
- Produces:
  - `M.dir` = `vim.fn.expand(vim.env.COCKPIT_PROJECTS_DIR or "~/.cockpit/projects")`
  - `M.list() -> Project[]`, sorted by name. `Project = {name: string, repos: string[] (expanded, absolute), created: string}`.
  - `M.get(name) -> Project|nil`
  - `M.save(p: Project)` writes `<dir>/<name>.json`. Repos are stored `~`-relative.
  - `M.new(cb?: fun(p: Project))` runs:
    1. `vim.ui.input` for the name; validate `^[a-z][a-z0-9_-]{0,27}$`.
    2. Repo multi-pick: `vim.ui.select` in a loop over git roots from `fd -H -t d '^\.git$' ~/dev ~/.config --max-depth 4` (parent dirs), with entry `"✓ done"` ending the loop. The first pick is primary.
    3. Save, then `cb(p)`.
  - `:CockpitProject new|edit [name]`. `edit` opens the JSON (picks via `vim.ui.select` when no name is given).

- [ ] **Step 1: Write smoke section 3** (headless nvim, `$T/t3.lua`):
  - Stub `vim.ui.input` → `"smoke"`.
  - Stub `vim.ui.select` to return `~/.config/nvim`, then `~/dev/genzed`, then `"✓ done"`.
  - Call `projects.new()` and **assert** `projects.get("smoke").repos` == `{expand("~/.config/nvim"), expand("~/dev/genzed")}`, and that `$T/projects/smoke.json` exists.
- [ ] **Step 2:** Run it. Expected: FAIL (module missing).
- [ ] **Step 3: Implement** `projects.lua` and the command.
- [ ] **Step 4:** Run it. Expected: PASS.
- [ ] **Step 5:** Commit `lua/cockpit/projects.lua lua/cockpit/inbox/init.lua scripts/cockpit-smoke-herdr.sh`: `feat(cockpit): multi-repo project definitions`.

---

### Task 4: Agent actions — spawn / kill / interrupt / attach / prompt

**Files:**
- Modify: `lua/cockpit/herdr.lua`, `scripts/cockpit-smoke-herdr.sh` (section 4)

**Interfaces:**
- Consumes: `projects.get/list` (Task 3), `M.request`/`M.ensure`/`M.agents` (Task 2).
- Produces:
  - `M.spawn(project: string, prompt?: string, cb?: fun(err, agent_name: string))`
  - `M.kill(name: string)`. No confirm here; callers confirm.
  - `M.interrupt(name: string)`
  - `M.attach(name: string)`. Inside tmux (`$TMUX` set): `tmux new-window -n <name> 'herdr [--session S] agent attach <name>'`. Otherwise `tabnew | terminal herdr … agent attach <name>`.
  - `M.prompt(name: string, text: string) -> string` returns a status line. `agent_blocked` → `"<name> is at a dialog — attach to answer"`.

- [ ] **Step 1: Write smoke section 4** (headless nvim `$T/t4.lua`, project `smoke` from section 3):
  1. `spawn("smoke")`, then wait ≤ 60 s for agent `smoke-1` to be `idle` (section 2 must `pane close $P2` at its end, so the name is free). **Assert** its `workspace_id`'s label is `smoke`, and that pane env has `COCKPIT_PROJECT` (via `agent.read` after `prompt(name, "run: echo $COCKPIT_PROJECT")` with wait; **assert** the output contains `smoke`).
  2. `interrupt(name)` returns no error.
  3. `kill(name)`, then within 5 s the agent is gone from `agents()`.
  4. **Review Focus 2:** project `untrusted` with repo `$T/untrusted` (a fresh `git init`). Stub `vim.ui.select` (the attach-now prompt) → "No". `spawn("untrusted")` → the cb gets err `agent_not_ready`, and the agent is in `agents()` with `status == "blocked"`. Then kill it.
  5. **Review Focus 4:** `pane split` + `agent start adhoc --kind claude` by hand in a non-project workspace. **Assert** `agents().adhoc.project == nil`. Spawning `smoke` again reuses the `smoke` workspace and never splits the ad-hoc workspace (assert the ad-hoc workspace pane count is unchanged).
- [ ] **Step 2:** Run it. Expected: FAIL (`spawn` nil).
- [ ] **Step 3: Implement.** The spawn algorithm (not determined by the signature):
  1. `ensure()`; `p = projects.get(project)`.
  2. `ws` = the entry of `workspace.list` whose `label == project`.
     - None → `workspace.create {cwd = p.repos[1], label = project, focus = false, env = ENV}`; the pane is `root_pane`.
     - Else → `pane.list {workspace_id}`. Use the first pane with no `agent` field whose `foreground_cwd` is set (an idle shell), otherwise `pane.split {target_pane_id = <first pane>, direction = "right", cwd = p.repos[1], focus = false, env = ENV}`.
  3. `ENV = {COCKPIT_PROJECT = project, COCKPIT_INBOX_DIR = vim.env.COCKPIT_INBOX_DIR}` (nil dropped).
  4. `agent.start {name = <project>-<n>, kind = "claude", pane_id, args = <--add-dir pairs>, timeout_ms = 60000}`.
  5. On success, if a prompt was given → `agent.prompt {target = name, text = prompt}` (no wait).
  6. On `agent_not_ready` → `vim.ui.select({"Attach now", "Later"}, {prompt = name .. " is blocked at startup (likely folder trust)"})` → `attach(name)` on "Attach now".
- [ ] **Step 4:** Run it. Expected: section 4 PASS. Note in a comment at the top of the smoke script whether `agent.prompt` sent mid-turn queued or injected, if observed.
- [ ] **Step 5:** Commit `lua/cockpit/herdr.lua scripts/cockpit-smoke-herdr.sh`: `feat(cockpit): spawn/kill/interrupt/attach/prompt via herdr`.

---

### Task 5: Reply delivery via herdr

**Files:**
- Modify: `lua/cockpit/inbox/store.lua` (`M.deliver`, ~L332)

**Interfaces:**
- Consumes: `herdr.by_terminal`, `herdr.prompt`.
- Produces: `store.deliver(t)` with this order:
  1. `agent_waiting` → unchanged.
  2. `t.session.herdr` and `herdr.by_terminal(t.session.herdr.terminal_id)` → `herdr.prompt(agent.name, oneliner)`; return its status line.
  3. `tmux_pane` → today's code, unchanged.
  4. `t.session.herdr` with no live agent → `"agent offline; reply kept for the next reader"`.

  `oneliner` is the same text as today: `("Inbox reply on thread %s. Run: python3 %s read %s --new")`.

- [ ] **Step 1: Write smoke section 5:**
  1. Spawn `smoke-N`.
  2. Prompt it (with wait): "run exactly: `python3 $CLI post --title s5 --text hi`".
  3. Headless nvim: `store.deliver(store.thread(<s5 id>))`. **Assert** the return starts with `"delivered"`.
  4. Within 60 s, `agent.read {target, source = "recent-unwrapped", lines = 80}` contains `Inbox reply on thread`.
  5. **Review Focus 3:** kill the agent, then `deliver` again. **Assert** it returns the "agent offline" string and that no `tmux send-keys` runs (the thread has no `tmux_pane` inside herdr).
- [ ] **Step 2:** Run it. Expected: FAIL (returns the "no agent pane" string).
- [ ] **Step 3: Implement** the new order.
- [ ] **Step 4:** Run it. Expected: PASS.
- [ ] **Step 5:** Commit `lua/cockpit/inbox/store.lua scripts/cockpit-smoke-herdr.sh`: `feat(cockpit): deliver replies to herdr agents via agent.prompt`.

---

### Task 6: Rail status glyph, keys, agent picker, commands

**Files:**
- Modify: `lua/cockpit/inbox/ui.lua` (`render_rail` ~L228, `rail_buf` ~L302, `M.open` ~L339, `M.close` ~L202)
- Modify: `lua/cockpit/inbox/init.lua` (`setup()`: `herdr.start()`, commands, `User CockpitAgents` → `ui.refresh()`)
- Modify: `docs/keybindings.md` (Cockpit section)

**Interfaces:**
- Consumes: everything in `herdr.lua` and `projects.lua`.
- Produces:
  - `ui.pick_agent()`: `vim.ui.select` over `herdr.agents()` with format `name · project|— · status · title`, then an action select `{"attach", "interrupt", "kill", "prompt"}`. Kill confirms `Kill <name> (<status>)?`; prompt uses `vim.ui.input`.
  - `ui.spawn()`: `vim.ui.select` over `projects.list()` names + `"+ new project"`, then `vim.ui.input` "First prompt (optional)", then `herdr.spawn`.
  - `:CockpitSpawn [project]`, `:CockpitAgent`.

**Glyphs** (exact). They go on the rail's **second line**, before the age, and are only shown when the thread has `session.herdr`:

| Status | Glyph | Highlight |
|---|---|---|
| working | `◐` | DiagnosticInfo |
| blocked | `⚠` | DiagnosticWarn |
| idle / done | `○` | Comment |
| unknown | `?` | Comment |
| offline (no live agent for `terminal_id`) | `✕` | DiagnosticError |

**Rail keys** (thread rows act on that thread's agent; on rows with no live herdr agent, show `notify("no live herdr agent for this run")`):

| Key | Action |
|---|---|
| `s` | spawn (any row) |
| `X` | kill (confirm) |
| `i` | interrupt |
| `gt` | attach |
| `A` | agent picker (any row) |

The help line / `docs/keybindings.md` lists them.

**Lifecycle:** `M.open` → `herdr.watch(true)`; `M.close` → `herdr.watch(false)`.

- [ ] **Step 1: Write smoke section 6** (headless nvim):
  1. With a spawned `smoke-N` that has posted thread `s6`, call `ui.open()`.
  2. **Assert** the rail buffer line after the `s6` title contains `○`.
  3. `herdr.kill(name)`, then wait for the `CockpitAgents` event and **assert** that line now contains `✕`.
  4. **Assert** `vim.fn.maparg("X", "n", false, true)` on the rail buffer has desc `Kill agent`, and likewise `s`, `i`, `gt`, `A`.
- [ ] **Step 2:** Run it. Expected: FAIL.
- [ ] **Step 3: Implement.** Keep the glyph inside `RAIL_W` (36), trimming the status word before the age if needed.
- [ ] **Step 4:** Run the **whole** smoke script. Expected: all sections PASS.
- [ ] **Step 5: Manual check** in the real default session:
  1. `<leader>ka` → `s` → pick or create a project → the agent appears in the `herdr` TUI.
  2. `A` → attach opens a tmux window on it.
  3. `X` kills it.
- [ ] **Step 6:** Commit `lua/cockpit/inbox/ui.lua lua/cockpit/inbox/init.lua docs/keybindings.md scripts/cockpit-smoke-herdr.sh`: `feat(cockpit): agent status, spawn/kill/attach keys and picker in the rail`.
