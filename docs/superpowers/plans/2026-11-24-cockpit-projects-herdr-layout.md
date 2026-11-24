# Cockpit projects, session identity, and herdr tab layout — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the agent a Claude session, not a herdr pane. Make projects user-defined sets of dirs, possibly spanning several worktrees. Give each project one herdr workspace and each agent one tab, named after its ticket.

**Architecture:**
- **Session identity:** herdr's per-pane `agent_session.value` becomes the agent key everywhere: cache, registry, thread owner and rail tree. The registry learns it during reconcile, because it isn't known at `agent.start`.
- **Spawning:** `spawn()` creates a tab (not a split pane) in the `ck/<project>` workspace, with `cwd` set to the agent's worktree, and names the agent from that worktree's ticket.
- **Old threads** get their session id from a one-time backfill.

**Tech Stack:** Lua (Neovim 0.11+ headless for tests), Python 3 (`scripts/cockpit_inbox.py`), herdr socket API / CLI, git worktrees.

**Spec:** `docs/superpowers/specs/2026-11-24-cockpit-projects-herdr-layout-design.md`

## Global Constraints

- **Quality tier is Prototype.** Write happy-path tests only. No unit-test framework. Add error handling only where a step names it.
- **Where tests go:**
  - **Fixture-only sections** (19, 20, 23, 25; no herdr, no Claude) go in a new `scripts/cockpit-smoke-model.sh`. It copies the main script's setup lines (`T`, `COCKPIT_*` env, `ok`/`fail`/`nlua`/`jget`/`thread_file`) and takes an optional section list (`bash scripts/cockpit-smoke-model.sh 19 20`, default all), so it runs in seconds.
  - **Live sections** (21, 22, 24) and the existing sections stay in `scripts/cockpit-smoke-herdr.sh`, which runs sections 1..N.
- **Test isolation:**
  - Every test runs under the smoke script's isolated setup: `COCKPIT_INBOX_DIR` and `COCKPIT_PROJECTS_DIR` under `$T`, and herdr session `ckspike`.
  - Any `claude`, `herdr` or `nvim` started outside that setup sets `COCKPIT_INBOX_DIR` to a scratch dir and `COCKPIT_INBOX_HOOK=0`, and unsets `TMUX`/`TMUX_PANE`.
  - Never write to `~/.cockpit` from a test.
- **Herdr agent names** must match `[a-z][a-z0-9_-]{0,31}` and be unique among live agents.
- **Ticket keys** match `^(<prefix>)-\d+$` with prefixes from `vim.g.cockpit_ticket_prefixes`, default `{ "ENG" }` (Python: env `COCKPIT_TICKET_PREFIXES`, comma-separated, default `ENG`).
  - This replaces the spec's `require("cockpit").config`: there is no `cockpit` init module.
- **Workspaces:** a workspace is cockpit's only if labelled `ck/<project>`. Never persist workspace ids. Never close a workspace, tab or pane cockpit didn't create.
- **`project.json` keeps the key `repos`** (meaning dirs). New optional field: `ticket`.
- **Rail keys:**
  - **Fresh is `N`.** `R` is already refresh in `rail.lua`, which deviates from the spec: update spec §4.2/§4.5 in Task 7.
  - **Move to project is `m`.**
- **Lua style:** 2-space indent, 120 columns; run `stylua . --config-path=stylua.toml` before each commit.
- **Before starting:** the working tree has another session's uncommitted cockpit work: `scripts/cockpit_inbox.py` (turn snapshots), `lua/cockpit/inbox/rail.lua`, `tree.lua` and `scripts/cockpit-smoke-herdr.sh`. Don't start until that work is committed. Then branch `cockpit-projects-layout` from it.

## Review Focus

1. **`/clear` in a live tab:** after the session changes, the old session's threads leave the live agent's row and appear under Past. Pinned in Task 4.
2. **Thread posted from the Bash tool,** where the parent process is a shell, not Claude: it still records the Claude session id. Pinned in Task 2.
3. **Ticket-looking noise** in a session title ("GPT-5", "UTF-8", "SHA-256") never renames an agent. Pinned in Tasks 1 and 4.
4. **Two agents spawned on the same ticket** get `eng-35131` and `eng-35131-2`, never a herdr name clash. Pinned in Task 5.
5. **A registry record with no `session`** (all 18 existing ones) whose terminal is live shows as exactly one agent row, not one live and one past. Pinned in Task 3.

---

### Task 0: Spike — verify spec §5 against a throwaway herdr session

Throwaway. No code is kept; findings go into spec §5.

**Files:**
- Modify: `docs/superpowers/specs/2026-11-24-cockpit-projects-herdr-layout-design.md` (§5: record each answer)

- [ ] **Step 1:** Start an isolated server: `herdr --session ckprobe server &`, with `COCKPIT_INBOX_DIR=$(mktemp -d)`, `COCKPIT_INBOX_HOOK=0` and `TMUX`/`TMUX_PANE` unset.
- [ ] **Step 2: §5.1.** Run `workspace create --cwd ~/.config/nvim --label ck/probe`, then `tab create --workspace <ws> --cwd ~/.config/nvim --label probe-1 --env COCKPIT_PROJECT=probe`, then `agent start probe-1 --kind claude --pane <tab root pane>`. Prompt it to run `printenv COCKPIT_PROJECT`. Expected: `probe`.
- [ ] **Step 3: §5.4.** Send `/clear` with `agent prompt probe-1 /clear`. Check that `agent get probe-1` reports a different `agent_session.value` and that `name` is still `probe-1`.
- [ ] **Step 4: §5.3.** `agent rename probe-1 probe-x` and `tab rename <tab> probe-x` succeed while the agent is idle, and `agent get probe-x` works.
- [ ] **Step 5: §5.2.** `pane close` the agent's pane. In a new tab, start `claude --resume <first session id>`. Record whether `agent_session.value` equals that id.
- [ ] **Step 6: §5.4b.** `tab close <tab>` ends the Claude process: `pgrep -f` for its pid is empty within 5 s.
- [ ] **Step 7:** `herdr --session ckprobe server stop; herdr session delete ckprobe`. Write the results into spec §5. If step 2 or 6 fails, stop and report to the controller before Task 5.
- [ ] **Step 8: Commit.** `git add docs/superpowers/specs/2026-11-24-cockpit-projects-herdr-layout-design.md && git commit -m "docs(cockpit): record herdr tab/session spike results"`

---

### Task 1: Tickets and project-for-dir by longest containing dir

**Files:**
- Create: `lua/cockpit/ticket.lua`
- Modify: `lua/cockpit/projects.lua` (`save` keeps `ticket`; `for_dir`; new `containing`)
- Modify: `lua/cockpit/inbox/tree.lua:35-43` (`project_for_cwd` → `projects.containing`)
- Modify: `scripts/cockpit_inbox.py` (`project_of`)
- Test: `scripts/cockpit-smoke-herdr.sh`, new section 19 (fixtures, no herdr)

**Interfaces:**
- Produces:
  - `ticket.prefixes() -> string[]`
  - `ticket.find(text: string) -> string|nil`: the first key whose prefix is in `prefixes()`, matched as a whole word, uppercased, e.g. `"ENG-35131"`.
  - `ticket.slug(key: string) -> string`: lowercase, herdr charset, at most 32 characters (`"eng-35131"`).
  - `ticket.for_dir(dir: string) -> string|nil`:
    - First, `find()` on the branch from `git -C dir branch --show-current`.
    - Otherwise, the dir basename's first `-(\d+)` group, combined with `prefixes()[1]`. Example: `lilt-mcp-34500` → `ENG-34500`.
    - Otherwise `nil`.
  - `projects.containing(dir: string) -> string|nil`: the project with the longest `repos[i]` equal to `dir` or containing it (realpath on both sides). It never creates a project.
  - `projects.for_dir(dir) -> string|nil`: `containing(dir)`, else today's auto-create fallback (repo-named project; nil for `$HOME` and `/`).
    - Drop the old "worktree collapses to its main repo" rule: when no project contains a worktree, the fallback creates one named after the worktree's own toplevel basename.
  - `projects.save(p)` writes `ticket` when present.
  - `cockpit_inbox.py project_of(cwd)`: `COCKPIT_PROJECT`, else longest containing dir across `$COCKPIT_PROJECTS_DIR/*/project.json` (default `~/.cockpit/projects`), else today's git-common-dir / basename fallback.

- [ ] **Step 1: Write section 19.** It creates two projects in `$COCKPIT_PROJECTS_DIR`: `lilt` = `[$T/org]` and `slack-poc` = `[$T/org/lilt-mcp-35131]` (plain dirs). Then it asserts:

```lua
local projects, ticket = require("cockpit.projects"), require("cockpit.ticket")
assert(projects.containing(T .. "/org/lilt-mcp-35131/src") == "slack-poc")
assert(projects.containing(T .. "/org/core") == "lilt")
assert(projects.containing(T .. "/elsewhere") == nil)
assert(ticket.find("ENG-35131 Slack assist POC") == "ENG-35131")
assert(ticket.find("eng/ENG-34500-context-filter") == "ENG-34500")
assert(ticket.find("GPT-5 vs UTF-8 and SHA-256") == nil)
assert(ticket.slug("ENG-35131") == "eng-35131")
assert(ticket.for_dir(T .. "/org/lilt-mcp-35131") == "ENG-35131") -- not a git dir: basename rule
projects.save({ name = "t", repos = { T .. "/org" }, ticket = "ENG-1" })
assert(projects.get("t").ticket == "ENG-1")
```

  Also: `python3 $CLI post --title s19 --text x`, run with `cwd=$T/org/lilt-mcp-35131/src` and no `COCKPIT_PROJECT`, records `project == "slack-poc"`.
- [ ] **Step 2:** Create `scripts/cockpit-smoke-model.sh` (see Global Constraints) with section 19, then run `bash scripts/cockpit-smoke-model.sh 19`. Expected: FAIL, `module 'cockpit.ticket' not found`.
- [ ] **Step 3:** Implement `ticket.lua`, `projects.containing`, the new `for_dir`, `save(ticket)`, `tree.project_for_cwd` → `projects.containing(cwd) or basename`, and `project_of`.
- [ ] **Step 4:** Re-run section 19 (PASS). Re-run section 3, "project definitions" (still PASS), and sections 17–18, the launcher (still PASS, now resolving by containment).
- [ ] **Step 5: Commit.** `git commit -m "feat(cockpit): ticket keys, project-for-dir by longest containing dir"`

---

### Task 2: Record the Claude session id: cache, registry, threads

**Files:**
- Modify: `lua/cockpit/herdr.lua:159-180` (`apply`: add `session_id`, `tab_id`)
- Modify: `lua/cockpit/registry.lua` (key by session; `by_terminal`)
- Modify: `scripts/cockpit_inbox.py` (`herdr_identity`, `session`, new `claude_session_id`)
- Modify: `lua/cockpit/inbox/store.lua:64-80` (an `owner` event overrides)
- Test: smoke section 1 (extend) + new section 20 (fixtures)

**Interfaces:**
- Produces:
  - Herdr cache entry adds `session_id: string|nil` (from `a.agent_session.value`) and `tab_id`.
  - `registry.key(rec) -> rec.session or rec.terminal_id`.
  - `registry.all(project) -> table<key, Rec>`, where the latest line per `key(rec)` wins.
    - A record that has a `session` *supersedes* any earlier session-less record for the same `terminal_id`: drop that legacy entry.
    - `Rec` adds `session`, `pane_id`, `tab_id`, `dir`, `parent_session?` and `moved?: true` (set by `m`).
  - `registry.by_terminal(project, terminal_id) -> Rec|nil`: the latest record for that terminal.
  - Python `claude_session_id() -> str|None`:
    - Walk the process ancestors from `os.getppid()` (via `ps -o ppid= -p <pid>`) up to 8 levels.
    - Return `sessionId` from the first `$COCKPIT_CLAUDE_DIR/sessions/<pid>.json` that exists (default `~/.claude`).
  - `herdr_identity()` adds `session_id`, the pane's `agent_session.value` from the `agent.list` entry it already reads.
  - `session()` adds `"session_id": (herdr_identity() or {}).get("session_id") or claude_session_id()`.
  - `store.thread(id).owner`: the `session` of the first `message` event, overridden by the `session` field of the latest `{kind="owner", session=...}` event.
  - `store.owner_session(t) -> string|nil`: `t.owner.session_id or (t.owner.herdr and t.owner.herdr.session_id)`.

- [ ] **Step 1: Write the tests.**
  - **Section 1:** after `s1`, assert `e["session"]["session_id"]` is a non-empty string. The pane runs no Claude, so herdr gives none; fake one: write `$T/claude/sessions/$$.json` = `{"sessionId":"sess-fake"}` for the shell's pid, and export `COCKPIT_CLAUDE_DIR=$T/claude`.
  - **Section 1, Review Focus 2:** post via `bash -c 'python3 $CLI post …'` (an extra shell layer between the pid with the session file and python). Assert `session_id == "sess-fake"`.
  - **Section 20 (Lua):**

```lua
local registry, store = require("cockpit.registry"), require("cockpit.inbox.store")
registry.append("p", { name = "lilt-9", project = "p", terminal_id = "tX" })              -- legacy
registry.append("p", { name = "lilt-9", project = "p", terminal_id = "tX", session = "S2" })
local all = registry.all("p")
assert(all.S2 and not all.tX, vim.inspect(all))
assert(registry.by_terminal("p", "tX").session == "S2")
-- owner override
store.append(store.thread_file("o1"), { kind = "message", text = "x", session = { pid = 1 } })
store.append(store.thread_file("o1"), { kind = "owner", session = { session_id = "S1" } })
assert(store.owner_session(store.thread("o1")) == "S1")
```

- [ ] **Step 2:** Run sections 1 and 20. Expected: FAIL (no `session_id`; `all.tX` still present).
- [ ] **Step 3:** Implement as specified in Interfaces.
- [ ] **Step 4:** Run sections 1, 9 and 20 (PASS). Section 9 ("registry, unique names, thread ownership") may need its fixture records to gain `session`; adjust assertions only where the key changed.
- [ ] **Step 5: Commit.** `git commit -m "feat(cockpit): record Claude session id on threads, cache and registry"`

---

### Task 3: Rail tree keyed by session

**Files:**
- Modify: `lua/cockpit/inbox/tree.lua` (ownership, agent keys, Past "earlier session", forks by `parent_session`, move precedence)
- Modify: `lua/cockpit/inbox/rail.lua` (callers of `owner_tid`; `kill_agent` matches by session)
- Test: smoke section 10 (rewrite fixture), section 11 (adjust)

**Interfaces:**
- Consumes: Task 2's `registry.all` keys, `store.owner_session`, and cache `session_id`.
- Produces:
  - `tree.owner_key(t) -> string|nil`: `store.owner_session(t)`, else `"cc:" .. pid` only for non-herdr threads whose pid is a live `sessions.list()` entry (then mapped to that entry's `session_id`), else `nil`. Remove `owner_tid`, and update `rail.lua:501,551,583`.
  - **Agent node:**
    - `key = "a:" .. (session_id or ("term:" .. terminal_id))`; new field `session_id`.
    - A live cache entry and the registry record with the same `session` are **one** agent.
    - A live entry whose session isn't in the registry yet uses `registry.by_terminal()` for its name, project and fork fields (Review Focus 5).
  - **Orphan threads** (no owner key) with `t.owner.herdr.terminal_id` known go into that terminal's project Past under a synthetic dead agent: `key = "a:old:" .. terminal_id`, `name = <herdr name> .. " · earlier session"`. All other orphans go to Unassigned, as today.
  - **Fork nesting** uses `rec.parent_session` and falls back to `parent_terminal` for legacy records.
  - **Agent project:** a registry record with `moved = true` wins; else the workspace label (`a.project`); else `rec.project`.

- [ ] **Step 1: Rewrite section 10's fixture** with session ids:
  - live agents: `A` (session `SA`, terminal `tA`), `F` (fork of `SA`, session `SF`) and `L` (terminal `tL`, live session `SL2`, with only a **legacy** registry record `{terminal_id="tL", name="lilt-9"}`);
  - dead `D` (session `SD`);
  - threads `t1` (owner `SA`), `t2` (owner `SF`), `t5` (owner `SL1`, the earlier session, `herdr.terminal_id = "tL"`) and `t4` (no owner).

  Assert:

```lua
assert(vim.deep_equal(keys(nodes), { "header", "p:p", "a:SA", "a:SF", "t2", "t1", "a:SL2",
  "past:p", "a:SD", "a:old:tL", "t5", "p:q", "unassigned", "t4" }), vim.inspect(keys(nodes)))
assert(by["a:SL2"].name == "lilt-9")               -- one row for the legacy-record live agent
assert(#by["a:SL2"].children == 0)                  -- earlier session's thread is not on it
assert(by["a:old:tL"].name == "lilt-9 · earlier session")
```

  Plus one move case: a record for `SA` with `project = "q", moved = true` puts `a:SA` under `p:q`.
- [ ] **Step 2:** Run section 10. Expected: FAIL on keys.
- [ ] **Step 3:** Implement the tree and rail changes.
- [ ] **Step 4:** Run sections 10, 11 and 13 (cleanup uses ownership). Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat(cockpit): rail agents are Claude sessions; earlier sessions go to Past"`

---

### Task 4: Reconcile learns sessions; late rename to ticket

**Files:**
- Modify: `lua/cockpit/herdr.lua` (`reconcile` → `learn()` after `apply`)
- Test: new section 21 (live `ckspike`, starts a real Claude)

**Interfaces:**
- Consumes: `registry.by_terminal`, `ticket.find`, `ticket.slug`, and the cache's `session_id`, `title`, `tab_id`.
- Produces: `herdr.learn()`, called at the end of each successful reconcile. For every live cache entry with `project`, `terminal_id` and `session_id`:
  - **Session learning:**
    - Look up `rec = registry.by_terminal(project, terminal_id)`.
    - If `rec` exists and `rec.session ~= session_id`, append `{…rec, session = session_id, pane_id, tab_id, moved = nil, renamed = nil}`.
    - If no `rec` exists, do nothing: hand-launched agents outside cockpit's projects aren't registered.
  - **Late rename** (spec §4.4):
    - It applies when the agent's name matches `^<project>%-%d+$` (fallback form), its record has no `renamed`, and `ticket.find(title)` returns a key whose slug is not a live agent name.
    - Then run `agent.rename` and `tab.rename` (when the tab label equals the old name), and append `{…rec, name = slug, renamed = true}`.
  - It must not run twice for the same session within one reconcile; guard with a module-local `pending[session_id]`.

- [ ] **Step 1: Write section 21:**
  - Spawn agent `smoke21-1` in project `smoke21` (dir `~/.config/nvim`) with `herdr.spawn` (the current pane split is fine; this task doesn't depend on Task 5).
  - Wait until ready, then `herdr.reconcile` and assert `registry.by_terminal("smoke21", tid).session == cache.session_id`.
  - **Review Focus 1:** post a thread from the agent's pane, send `agent.prompt` `/clear`, wait for idle, reconcile. Assert a new record with a different `session` exists and that `tree.build()` shows the thread under `past:smoke21`, not under the live agent.
  - **Rename:** `agent.prompt` with text `Reply only: ok` won't change the title deterministically. Instead, stub the title: set `cache[name].title = "ENG-99999 smoke"` and call `herdr.learn()` directly. Assert `agent.get eng-99999` succeeds.
  - **Review Focus 3:** with the title stubbed to `"GPT-5 notes"`, `learn()` leaves the name unchanged.
- [ ] **Step 2:** Run section 21. Expected: FAIL (`learn` is nil).
- [ ] **Step 3:** Implement `learn()`.
- [ ] **Step 4:** Run sections 4, 11 and 21. Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat(cockpit): reconcile learns session changes and renames agents to their ticket"`

---

### Task 5: Spawn into tabs; ticket names; forks and kill follow tabs

**Files:**
- Modify: `lua/cockpit/herdr.lua:290-466` (`free_name` → `agent_name`; `project_pane` → `project_tab`; `spawn` opts; `kill`)
- Modify: `lua/cockpit/forks.lua:64-96` (`start` uses a tab)
- Modify: `scripts/cockpit-spawn.lua` (pass `dir = cwd`)
- Test: sections 4, 12, 17 and 18 (adjust expectations: tabs, not splits) + new section 22

**Interfaces:**
- Consumes: Task 0's results, `ticket.for_dir`, `ticket.find`, `ticket.slug`, `projects.get(p).ticket`.
- Produces:
  - `herdr.agent_name(project: string, dir: string, prompt?: string) -> string`.
    - Base name: `ticket.slug` of `ticket.for_dir(dir)`, else of the project's `ticket`, else of `ticket.find(prompt)`.
    - With a base: the first of `base`, `base-2`, `base-3`, … that is not a live agent name and has no `fork/<cand>-*` branch, claimed with `claim()`.
    - Without one: today's `<project>-<n>` loop.
    - Drop the registry "never reused" check.
  - `project_tab(p, env, dir, label) -> err, pane_id, tab_id`.
    - Find `ck/<name>` by label. If it's missing, run `workspace.create {cwd = p.repos[1], label = "ck/"..name, focus = false}` and `tab.rename` its first tab to `shell`.
    - Then run `tab.create {workspace_id, cwd = dir, label = label, env = env, focus = false}` and return its root pane.
  - `herdr.spawn(project, prompt, cb, opts)`:
    - `opts.dir` is the tab's cwd (`opts.cwd` is accepted as an alias). Default: `p.repos[1]`; when `#p.repos > 1` and `opts.interactive ~= false`, `vim.ui.select` over `p.repos` first.
    - `--add-dir` gets every `p.repos` entry except `dir`.
    - The registry record adds `dir`, `tab_id`, `pane_id`.
    - `cb(err, name, pane_id, tab_id)`.
  - `herdr.kill(target)`: if the agent's tab has exactly 1 pane (`tab.get`), run `tab.close`; else `pane.close`.
  - `forks.start`: `tab.create` in the parent's `workspace_id`, with `cwd` and `label = name`. The name comes from `agent_name(project, cwd)`. Then `start_in` in the tab's root pane. On failure, `tab.close` (was `pane.close`). The record adds `parent_session = parent.session_id`.

- [ ] **Step 1: Write section 22:**
  - Create project `smoke22` with `repos = { <nvim cfg> }, ticket = "ENG-99998"`.
  - Spawn twice with `interactive = false`.
  - Assert the names are `eng-99998` and `eng-99998-2` (Review Focus 4).
  - Assert `tab.list` for workspace `ck/smoke22` shows labels `{ "shell", "eng-99998", "eng-99998-2" }`.
  - Assert each agent's `pane_id` is the root pane of its own tab.
  - Run `herdr.kill("eng-99998-2")`. Assert that tab is gone and `shell` remains.
- [ ] **Step 2:** Run section 22. Expected: FAIL (names `smoke22-1`, `smoke22-2`; one tab).
- [ ] **Step 3:** Implement. Update sections 4, 12, 17 and 18 where they assert split panes or `<project>-<n>` names. Keep their intent; change only layout and name expectations.
- [ ] **Step 4:** Run the whole smoke script: `bash scripts/cockpit-smoke-herdr.sh`. Expected: all ✓.
- [ ] **Step 5: Commit.** `git commit -m "feat(cockpit): one herdr tab per agent, named after its worktree's ticket"`

---

### Task 6: Project creation — dirs, new worktree, existing worktrees, add-worktree

**Files:**
- Modify: `lua/cockpit/projects.lua` (`new` gains a first choice; new `worktree_plan`, `add_worktree`)
- Modify: wherever `:CockpitProject` subcommands are registered (`rg -n "CockpitProject" lua/`): add `add-worktree`
- Test: new section 23 (temp git repo, no herdr)

**Interfaces:**
- Produces:
  - `projects.worktree_plan(repo: string, key?: string, slug: string) -> { path: string, branch: string }`.
    - Branch: `eng/<KEY>-<slug>`, or `eng/<slug>` without a key.
    - Path: `<repo>-<number>`; if that exists, `<repo>-<number>-<slug>`; without a key, `<repo>-<slug>`.
    - The `eng/` prefix is lowercased from `ticket.prefixes()[1]`.
  - `projects.make_worktree(repo, key?, slug) -> path|nil, err?`: runs `git -C repo worktree add -b <branch> <path> HEAD`.
  - `projects.list_worktrees(repo) -> { {path, branch?} }`: from `herdr worktree list --cwd repo` JSON (`.result.worktrees`), excluding the main checkout (`is_linked_worktree == false`). Falls back to `git worktree list --porcelain` if herdr errors.
  - `projects.new(cb)`: first `vim.ui.select { "Dirs", "New worktree", "Existing worktrees" }`.
    - **Dirs:** today's flow.
    - **New worktree:** repo → key (input, may be empty) → slug → name (default slug) → `make_worktree` → save `{name, repos = {path}, ticket = key}`.
    - **Existing worktrees:** repo → repeated select over `list_worktrees` until "✓ done" → name → save `{repos = picked, ticket = ticket.for_dir(picked[1])}`.
  - `projects.add_worktree(name)`: the same two worktree flows, appending to an existing project's `repos`.

- [ ] **Step 1: Write section 23:**
  - `git init $T/repo23` with one commit.
  - Assert `worktree_plan("$T/repo23", "ENG-35131", "slack-poc")` == `{ path = "$T/repo23-35131", branch = "eng/ENG-35131-slack-poc" }`.
  - `mkdir $T/repo23-35131`, then assert the plan path becomes `$T/repo23-35131-slack-poc`.
  - `make_worktree` creates it and `git -C` shows the branch.
  - `list_worktrees` returns it.
  - Stub `vim.ui.select`/`vim.ui.input` to drive "New worktree" end to end. Assert `projects.get(name).repos[1]` is the new path and `.ticket == "ENG-35131"`.
- [ ] **Step 2:** Run section 23. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run sections 3 and 23. Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat(cockpit): create projects from new or existing worktrees"`

---

### Task 7: Rail actions — `N` fresh, `m` move to project

**Files:**
- Modify: `lua/cockpit/inbox/rail.lua` (keymaps near `:765-830`, `HELP` at `:629`, new `fresh_agent`, `move_agent`)
- Modify: the spec, §4.2/§4.5: `R` → `N`
- Test: section 11 (extend) or new section 24 (live ckspike)

**Interfaces:**
- Consumes: `herdr.kill`, `herdr.spawn(project, nil, cb, { dir = rec.dir })` and `registry.append`.
- Produces:
  - `rail.fresh_agent(node)`:
    - Confirm with `Start a fresh <name> in <dir>? (kills this conversation)`.
    - Run `herdr.kill(target)`, archive the threads it owns (reuse the archive loop from `kill_agent`), and append the old record as `dead`.
    - Then `spawn(project, nil, …, { dir = rec.dir or agent.cwd })`.
    - Herdr agents only; it no-ops with a notice for hand-started tmux sessions.
  - `rail.move_agent(node)`: `vim.ui.select` over `projects.list()` names, then append `{…rec, project = choice, moved = true}`.
    - If the agent has no registry record, synthesize one from the cache entry (`name`, `terminal_id`, `session = session_id`).
    - Refresh.
  - **Keymaps:** `N` → `with_agent(M.fresh_agent, true, true)` and `m` → `with_agent(M.move_agent, false, false)`.
  - **HELP:** add `  N     fresh conversation (new tab, same dir)` and `  m     move to project`.

- [ ] **Step 1: Write the test.**
  - Spawn `smoke24` agent A. Call `rail.fresh_agent(node)` with `vim.fn.confirm` stubbed to 1.
  - Assert A's tab is gone and a new live agent exists in project `smoke24`, with the same `dir` and a different session.
  - Call `move_agent` with `vim.ui.select` stubbed to `"q24"`. Assert `tree.build()` places the new agent under `p:q24`.
- [ ] **Step 2:** Run it. Expected: FAIL.
- [ ] **Step 3:** Implement, and update the spec key.
- [ ] **Step 4:** Run sections 11 and 24. Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat(cockpit): rail N starts a fresh conversation, m moves an agent to a project"`

---

### Task 8: One-time backfill of legacy threads

**Files:**
- Modify: `scripts/cockpit_inbox.py` (new subcommand `backfill-sessions [--dry-run]`; add it to the module docstring's usage list)
- Test: new section 25 (fixture transcripts, no herdr)

**Interfaces:**
- Consumes: Task 2's `owner` event shape `{kind: "owner", session: {session_id}}`.
- Produces: `cockpit_inbox.py backfill-sessions [--dry-run]`. For each thread file whose owner has no `session_id`:
  1. A thread id matching `^session-([0-9a-f]{8})$`: the first `$COCKPIT_CLAUDE_DIR/projects/*/<8hex>*.jsonl` gives the full session id (the filename stem).
  2. Otherwise, the first `$COCKPIT_CLAUDE_DIR/projects/*/*.jsonl` containing the thread id string (use `rg -l --fixed-strings` when available, else a Python scan) gives its stem.
  3. Otherwise, skip.

  It appends `{"v":1,"kind":"owner","ts":…,"at":…,"session":{"session_id":…}}`. `--dry-run` prints `<thread> -> <session|unmatched>` and writes nothing. Running it twice appends nothing the second time.

- [ ] **Step 1: Write section 25:**
  - Fixture `$T/claude/projects/x/1077c886-aaaa.jsonl` (any content) and `$T/claude/projects/x/8737f883-bbbb.jsonl` containing the text `20261124-070847-eng-35131-spec`.
  - Threads `session-1077c886`, `20261124-070847-eng-35131-spec` and `lonely`, each with one legacy message (no `session_id`).
  - Run `backfill-sessions`. Assert `owner_session` is `1077c886-aaaa`, `8737f883-bbbb` and nil respectively.
  - Run it again. Assert the thread files' line counts are unchanged.
- [ ] **Step 2:** Run it. Expected: FAIL (unknown subcommand).
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run section 25. Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat(cockpit): backfill-sessions tags legacy threads with their Claude session"`
- [ ] **Step 6: Real data, controller only, with the user's OK.** Run `python3 scripts/cockpit_inbox.py backfill-sessions --dry-run` against the real inbox and show the user the summary. Expected: `session-1077c886 -> 1077c886-…` and `20261124-070847-eng-35131-slack-assist-poc-spec -> 8737f883-…`. Run without `--dry-run` only after the user approves.
