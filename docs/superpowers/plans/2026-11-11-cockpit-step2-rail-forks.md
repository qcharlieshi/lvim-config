# Cockpit Step 2 — Project Rail, Forks, Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The cockpit rail becomes a foldable project → agent → fork → thread tree, one line per row. Agents can be forked as a continuation (`f`) or into a worktree (`F`). Killing an agent archives its threads. The cockpit gains a project directory as the tab cwd, floating composers, CodeDiff auto-open, and a lualine buffer list showing the thread's deliverables.

**Architecture:**
- **Shrink `ui.lua`** (1400 lines) by moving the rail out. A pure `tree.lua` builds the model from threads + the herdr agent cache + a per-project agent registry, and `rail.lua` renders it with real vim folds.
- **New modules:**
  - `forks.lua` — fork creation and worktree cleanup.
  - `registry.lua` — `agents.jsonl` for each project.
  - `float.lua` — floating composers.
- **Existing modules:**
  - `projects.lua` moves to a directory per project.
  - `store.lua` gains thread ownership.

**Tech Stack:** Neovim 0.11 Lua, herdr 0.9.5 socket API (via `lua/cockpit/herdr.lua`), git worktrees, lualine, snacks.nvim picker, codediff.nvim (`:CodeDiff`).

**Spec:** `docs/superpowers/specs/2026-11-11-cockpit-step2-rail-forks-design.md` (§4b holds the builder-check answers, and they bind). Step 1 spec and plan sit beside it.

## Global Constraints

- **Quality tier: Prototype.** Happy-path smoke sections in `scripts/cockpit-smoke-herdr.sh` only. Every new section works against the isolated `ckspike` session with `COCKPIT_INBOX_DIR` and `COCKPIT_PROJECTS_DIR` under `$T`.
- **Step 1 rules still hold:**
  - Explicit herdr targets; never `--current`.
  - Never close panes cockpit didn't create, and never answer a `blocked` dialog.
  - Commit only the files the task lists. The nvim repo has unrelated dirty files (`lazy-lock.json`, `options.lua`, `lsp.lua`, `lualine.lua`, `keymaps.lua`, …), so never `git add -A`.
  - Task 8 edits `lua/plugins/lualine.lua`, which is already dirty. Use `git add -p` there and stage only the cockpit hunk.
- **Rail:**
  - Width stays `RAIL_W = 36`, one line per row, nesting by 2-space indent.
  - Glyphs: agents `◐` working · `⚠` blocked · `○` idle/done · `?` unknown · `✕` dead. Forks `⑂`. Thread run-status glyphs keep the existing `STATUS` table.
  - Header line: `COCKPIT  ✋N ◐N ⚠N`.
- **Fold node keys:** `p:<project>`, `a:<terminal_id>`, `past:<project>`, `unassigned`.
- **Agent identity is `terminal_id`** (§4b.4). Names are display-only and never reused within a project.
- **Fork branch:** `fork/<parent-name>-<n>`. Worktree path `<repo>/.worktrees/fork-<parent-name>-<n>`, one per repo in the project (§4b.1).
- **Fork preamble (exact):**
  - Continue fork: `You are a fork of <parent>. Open new inbox threads for your work; don't post to your parent's threads.`
  - Worktree fork, prefixed with: `You are a fork of <parent> working in separate git worktrees (<paths>) on branch <branch>. Only edit files there.`
- **Project dir:** `~/.cockpit/projects/<name>/{project.json, repos/<basename>, agents.jsonl, threads/}`.

## Review Focus

1. **A project with no live agents and no threads** (just created): it renders as an empty project row, folds without error, and `s` on it spawns there. Pinned in Task 4.
2. **A fork whose parent was killed:** it renders at the project's top level as `⑂ <name> (from <parent>)`, not under `past`. Pinned in Task 3 (tree fixture).
3. **Rail re-render while the cursor is on a folded agent:** fold state and the cursor's node survive the 3 s refresh. Pinned in Task 4.
4. **Killing a worktree fork that committed work:** the branch is never deleted without the prompt. "Keep" keeps the branch and only removes a clean worktree dir. Pinned in Task 5.
5. **Composer float closed with `q` mid-draft:** the draft is kept and reopening `r` restores it, same as today's split. Pinned in Task 7.

---

### Task 1: Project directory + migration + tab cwd helper

**Files:** Modify `lua/cockpit/projects.lua`, `scripts/cockpit-smoke-herdr.sh` (section 8)

**Interfaces:**
- Produces:
  - `projects.root(name) -> string` — the directory path.
  - `projects.get/list/save/new/edit` — same signatures as step 1. Storage is `<dir>/<name>/project.json`. `save` rebuilds `repos/` symlinks (basename collision → `<basename>-2`).
  - `projects.migrate()` — moves any `<dir>/<name>.json` into `<name>/project.json`, then `save`s it. Called lazily by `list()` / `get()`.
  - `projects.link_thread(name, tid)` — creates the `threads/<tid>.jsonl` symlink if it's missing.

- [ ] **Step 1: Write smoke section 8** (headless, no herdr needed).
  - Write a step-1-style `$T/projects/old.json` with repos `{~/.config/nvim, ~/dev/genzed}`.
  - `projects.get("old")` → repos are expanded.
  - Assert `$T/projects/old/project.json` exists, `$T/projects/old.json` is gone, and `old/repos/nvim` and `old/repos/genzed` are symlinks resolving to those repos.
  - `link_thread("old", "x")` creates `old/threads/x.jsonl`, a symlink.
- [ ] **Step 2:** Run `bash scripts/cockpit-smoke-herdr.sh 8`. Expected: FAIL at the `project.json` assertion.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run it. Expected: sections 1–8 PASS. Sections 3 and 4 must still pass against the new layout.
- [ ] **Step 5:** Commit `lua/cockpit/projects.lua scripts/cockpit-smoke-herdr.sh`: `feat(cockpit): project directories with repo symlinks`.

---

### Task 2: Agent registry, unique names, thread ownership

**Files:**
- Create `lua/cockpit/registry.lua`
- Modify `lua/cockpit/herdr.lua` (`free_name`, `spawn`), `lua/cockpit/inbox/store.lua` (`M.thread`), `scripts/cockpit-smoke-herdr.sh` (section 9)

**Interfaces:**
- Produces:
  - `registry.append(project, rec)` — appends to `projects.root(project)/agents.jsonl`; adds `ts`.
  - `registry.all(project) -> table<terminal_id, Rec>` — latest line per `terminal_id` wins. `Rec = {name, project, terminal_id, session, parent_terminal?, parent_name?, fork? = "continue"|"worktree", worktrees? = {{repo, path, branch, base}}, dead? = true, ts}`.
  - `registry.names(project) -> set<string>`
  - `herdr.spawn` appends `{name, project, terminal_id, session}` after readiness. `session` comes from `agent.get` → `agent.agent_session.value`; if that's absent, use `nil` and record a Ruling.
  - `free_name(project)` skips live names, `registry.names(project)`, and `git branch --list 'fork/<name>-*'` hits in the primary repo.
  - `store.thread(id).owner` — the `session` of the **first** `message` event. `t.session` keeps its meaning (the latest one).

- [ ] **Step 1: Write smoke section 9.**
  - Spawn into `smoke`. Assert `registry.all("smoke")` has one record with this agent's `terminal_id` and a non-empty `session`.
  - Kill it, spawn again. Assert the new name ≠ the old name.
  - Assert ownership with a hand-built thread file: two `message` events with different `session.herdr.terminal_id` → `owner.herdr.terminal_id` equals the first one's.
- [ ] **Step 2:** Run it. Expected: FAIL (`module 'cockpit.registry' not found`).
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run sections 1–9. Expected: PASS.
- [ ] **Step 5:** Commit `lua/cockpit/registry.lua lua/cockpit/herdr.lua lua/cockpit/inbox/store.lua scripts/cockpit-smoke-herdr.sh`: `feat(cockpit): agent registry, unique names, thread ownership`.

---

### Task 3: `tree.lua` — pure rail model

**Files:** Create `lua/cockpit/inbox/tree.lua`; modify `scripts/cockpit-smoke-herdr.sh` (section 10, headless, fixtures only).

**Interfaces:**
- Consumes: `store.threads()`, `herdr.agents()`, `registry.all`, `projects.list`.
- Produces: `tree.build(opts?: {show_archived?: boolean, threads?, agents?, registry?, projects?}) -> Node[]`. The optional fields inject fixtures; when absent, it reads the live sources.
  - `Node = {kind = "header"|"project"|"agent"|"thread"|"past"|"unassigned", key, depth, ...}`. Projects hold `children` (agents), `past` (a Node) and `counts = {needs_you, working, blocked}`. Agents hold `agent` (cache entry or registry rec), `live`, `fork`, `orphan_of`, `children` (forks then threads).
  - **Ownership:** a thread's agent is the one whose `terminal_id == t.owner.herdr.terminal_id`.
  - **Agent placement:** an agent's project comes from the cache's `project` (`ck/` label), else its registry record. Agents in neither go under `unassigned`, as do threads without an owner terminal.
  - **Forks:** a fork whose parent is live nests under the parent. If the parent is dead, it goes to the project's top level with `orphan_of = parent_name`.
  - **Past:** dead registry agents (not live in the cache) go under `past`, with their threads (archived ones included only when `show_archived`).
  - **Sort:** projects by urgency (blocked > needs_you > working > idle), then name. Agents the same way, then most recent. Threads by the existing `RANK`, then `last_ts`.

- [ ] **Step 1: Write smoke section 10** — one fixture world in a lua file. It has:
  - project `p` with live agent A (idle), A's live continue fork F, and dead agent D;
  - live agent G whose parent (dead) is D;
  - threads t1 (owner A, needs_you), t2 (owner F), t3 (owner D, archived), t4 (no herdr);
  - an empty project `q` (Review Focus 1).

  Assert:
  - order `[header, p, A, F, t2, t1, G(orphan_of=D), past(p), q, unassigned]`, with t1 under A after F's subtree, per "forks then threads";
  - `p.counts.needs_you == 1`;
  - t3 is absent unless `show_archived`.
- [ ] **Step 2:** Run it. Expected: FAIL (module missing).
- [ ] **Step 3:** Implement `tree.build`.
- [ ] **Step 4:** Run it. Expected: PASS.
- [ ] **Step 5:** Commit `lua/cockpit/inbox/tree.lua scripts/cockpit-smoke-herdr.sh`: `feat(cockpit): rail tree model`.

---

### Task 4: `rail.lua` — render, folds, keys, kill-archive, help

**Files:**
- Create `lua/cockpit/inbox/rail.lua`
- Modify `lua/cockpit/inbox/ui.lua`: delete `render_rail` / `rail_buf` bodies and delegate; keep `M.rail_buf` / `M.render_rail` names as thin wrappers so `select()` / `refresh()` callers are unchanged. Move `kill_agent` into rail.
- Modify `scripts/cockpit-smoke-herdr.sh` (section 11)

**Interfaces:**
- Consumes: `tree.build`, `herdr.*`, `forks.*` (Task 5; until then `f`/`F` notify "forks: not yet"), `store.append`.
- Produces:
  - `rail.render(buf)` — one line per Node.
    - Line formats: per the spec §3.2 sketch, right-aligned age, `trunc` titles.
    - Stores `views[buf].map[row] = node` and `views[buf].rows[node.key] = row`.
    - Window-local folds: `foldmethod=expr`, `foldexpr=v:lua.require'cockpit.inbox.rail'.foldexpr(v:lnum)` from a per-row level table (`>1` project, `>2` agent with children, `>3` fork with children, others their depth), `foldtext` returning the line text, `fillchars` `fold: `.
    - **Fold persistence algorithm:**
      1. Before rendering, walk the rows and collect node keys where `foldclosed(row) == row`.
      2. Set the lines.
      3. `zx`.
      4. For each collected key still present, `exe row .. "foldclose"`.
      5. Restore the cursor to the previous cursor node's key row.
      6. First render: close `past:*` and `unassigned`.
  - `rail.kill_agent(node)`:
    1. Confirm `Kill <name> and archive its N threads?`, plus ` (K forks keep running)` when live forks exist.
    2. `herdr.kill`.
    3. Append `archived = true` to each owned, unarchived thread.
    4. `registry.append(project, {…rec, dead = true})`.
    5. For worktree forks, call `forks.cleanup(rec)` (Task 5).
  - **Keys** per spec §3.2: `X f F i gt <CR> a u g. R s A ?`.
    - `<CR>` on an agent opens its newest thread; on a project it toggles the fold.
    - `?` opens a float listing keys (`vim.lsp.util.open_floating_preview` is fine).
  - `<CR>` on a thread with a known project also runs `:tcd projects.root(project)`. Otherwise it runs `:tcd` to `t.session.cwd`.
  - `<CR>` on a `past` agent opens a picker of its archived threads (`vim.ui.select`, then `ui.select(tid)`).
  - **Blocked detail:** when an agent enters `blocked` (a cache transition), fetch `agent.read {target, source = "recent", lines = 15}` once. Take the last non-empty line that isn't box-drawing, cache it per `terminal_id`, and render it after `⚠` truncated to fit. Clear it when the status leaves `blocked`.

- [ ] **Step 1: Write smoke section 11** (live herdr).
  1. Create project `r` (no agents). `ui.open()`; the rail has a `▾ r` row (Review Focus 1).
  2. Spawn into `smoke` and have it post `s11`. The rail shows `smoke` → agent → `s11` on three consecutive rows, each one line.
  3. `zc` on the agent row, wait for one reconcile (3 s), then assert `foldclosed(agent_row) == agent_row` and the cursor is still on the agent's node (Review Focus 3).
  4. `rail.kill_agent(node)` with `vim.fn.confirm` stubbed to 1. Assert `s11` is archived and the registry has `dead = true`.
- [ ] **Step 2:** Run it. Expected: FAIL.
- [ ] **Step 3:** Implement `rail.lua`, then slim `ui.lua`.
- [ ] **Step 4:** Run the whole script. Expected: PASS. Section 6's glyph assertions must be updated to the new one-line format: a Ruling if they change shape.
- [ ] **Step 5:** Commit `lua/cockpit/inbox/rail.lua lua/cockpit/inbox/ui.lua scripts/cockpit-smoke-herdr.sh`: `feat(cockpit): project tree rail with folds and kill-archive`.

---

### Task 5: Forks

**Files:**
- Create `lua/cockpit/forks.lua`
- Modify `lua/cockpit/herdr.lua`: extract the start-and-wait part of `spawn` into `M.start_in(pane_id, name, args, env, cb)` so forks reuse it.
- Modify `lua/cockpit/inbox/rail.lua` (wire `f`/`F`) and `scripts/cockpit-smoke-herdr.sh` (section 12).

**Interfaces:**
- Consumes: `registry`, `projects`, `herdr.request/start_in/agents`.
- Produces:
  - `forks.continue(parent: Agent, prompt?: string, cb?)` — splits a pane in the parent's workspace with `cwd = parent.cwd`. Args are `--resume <session> --fork-session` plus `--add-dir` for the project's other repos. Env adds `COCKPIT_PARENT=<parent name>`. The first prompt is the continue preamble + `prompt`. Appends a registry record with `fork = "continue"`, `parent_terminal`, `parent_name`.
  - `forks.worktree(parent, prompt?, cb?)`:
    1. Branch `fork/<parent>-<n>` (lowest free n across all repos).
    2. For each project repo: `git -C <repo> worktree add <repo>/.worktrees/fork-<parent>-<n> -b <branch> HEAD`, recording `base = git rev-parse HEAD`.
    3. Start with cwd = the primary's worktree and `--add-dir` = the other worktrees.
    4. The worktree preamble.
    5. Registry `fork = "worktree"`, `worktrees`.
    6. Add `.worktrees/` to each repo's `.git/info/exclude` if it's missing.
  - `forks.cleanup(rec)`: for each worktree, check dirty (`status --porcelain`) and ahead (`rev-list --count base..branch`).
    - All clean and not ahead → `git worktree remove` + `git branch -D`, silently.
    - Otherwise one `vim.ui.select({"Keep branch", "Discard"}, {prompt = "fork/… : N commits, dirty in <repos>"})`.
      - **Discard** → `worktree remove --force` + `branch -D`.
      - **Keep** → remove the worktree dir only where it's clean; keep the branch.
  - No session id on the parent → notify `cockpit: <name> has no session id yet` and return.

- [ ] **Step 1: Write smoke section 12.**
  1. Spawn `smoke`, then `forks.continue(parent)`. The child is live, its registry rec has `parent_terminal` == the parent's, and its `session` ≠ the parent's `session`.
  2. `forks.worktree(parent)`: the `fork/<parent>-1` branch exists in `~/.config/nvim`, and the worktree dir exists.
  3. Kill it unchanged via `rail.kill_agent`: worktree and branch are gone.
  4. **Review Focus 4:** `forks.worktree` again, then have the test itself commit a file in the worktree (`git -C <wt> commit --allow-empty -m x`). Kill with `vim.ui.select` stubbed → "Keep branch". The branch still exists; the worktree dir is removed. Then delete the branch in the trap.
- [ ] **Step 2:** Run it. Expected: FAIL.
- [ ] **Step 3:** Implement and wire the `f`/`F` keys. Both prompt `vim.ui.input "Fork prompt (optional)"`.
- [ ] **Step 4:** Run the whole script. Expected: PASS.
- [ ] **Step 5:** Commit `lua/cockpit/forks.lua lua/cockpit/herdr.lua lua/cockpit/inbox/rail.lua scripts/cockpit-smoke-herdr.sh`: `feat(cockpit): continue and worktree forks`.

---

### Task 6: `:CockpitCleanup`

**Files:** Modify `lua/cockpit/inbox/init.lua`, `lua/cockpit/inbox/rail.lua` (`rail.cleanup()`), `scripts/cockpit-smoke-herdr.sh` (section 13)

**Interfaces:**
- Produces `rail.cleanup()`:
  - Candidates are unarchived threads where either `t.owner.herdr` is set and `herdr.by_terminal` is nil, or there's no herdr block and `t.session.tmux_pane` isn't in `tmux list-panes -a`.
  - Show the candidates in a float (`title · project · age`). `y` archives all, `q` cancels.

- [ ] **Step 1: Write smoke section 13.** Seed a thread whose owner has `herdr.terminal_id = "term_gone"`, call `rail.cleanup()`, press `y` via `feedkeys`, and assert it's archived.
- [ ] **Step 2:** Run it. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run it. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(cockpit): :CockpitCleanup for threads of dead agents`.

---

### Task 7: Floating composers

**Files:**
- Create `lua/cockpit/inbox/float.lua`
- Modify `lua/cockpit/inbox/ui.lua` (`M.compose` ~L1142, `annotate` ~L814)
- Modify `scripts/cockpit-smoke-herdr.sh` (section 14, headless, no herdr)

**Interfaces:**
- Produces:
  - `float.open(buf, {title, footer, width?, height?, relative? = "editor"|"cursor"}) -> win`. Rounded border, `title_pos = "center"`, `footer_pos = "center"`. Defaults: width `math.min(100, vim.o.columns - 10)`, height `math.min(20, vim.o.lines - 8)`, centered.
  - `M.compose`: same buffer, autocmds and drafts as today, but `float.open(buf, {title = "Reply · <verdict>", footer = ":w send · q keep draft"})` replaces the `belowright 10split`. `q` in normal mode closes the float (the `BufLeave` draft save already fires).
  - `annotate`: after the label select (looks-good still saves immediately), open a 3-line `acwrite` scratch in `float.open(..., {relative = "cursor", title = label})`. `:w` or normal-mode `<CR>` saves the joined lines as `text`; `q` cancels.

- [ ] **Step 1: Write smoke section 14.**
  1. Seed a thread with a markdown deliverable in `$T/inbox`, then `ui.select(tid)` and `ui.compose(tid, nil)`.
  2. Assert `nvim_win_get_config(0).relative ~= ""`, i.e. it's a float.
  3. Type text, `q`, then `ui.compose` again: the text is restored (Review Focus 5).
  4. Annotate line 1 with select stubbed to `bug`. A float opens; set the lines `{"a","b"}`, `:w`, and assert the draft note text == `"a\nb"`.
- [ ] **Step 2:** Run it. Expected: FAIL (not a float).
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run it. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(cockpit): floating reply and note composers`.

---

### Task 8: CodeDiff auto-open, lualine deliverable buffers, picker follow

**Files:**
- Modify `lua/cockpit/inbox/ui.lua` (`select` ~L642, `scratch` ~L85, `attachment_buf` ~L919, `workspace_winbar` ~L861)
- Modify `lua/plugins/lualine.lua` (buffers component, ~L278) — **stage the hunk only**
- Modify `lua/plugins/snacks.lua` (the `Snacks.picker.pick` wrapper ~L196)
- Modify `docs/keybindings.md`, `scripts/cockpit-smoke-herdr.sh` (section 15)

**Interfaces:**
- **Buffer listing:**
  - `scratch(name, ft, buftype, listed?)`: rail, thread, composer, placeholder and board buffers are created **unlisted**; deliverable buffers are listed.
  - `select(tid)` sets `buflisted = false` on every deliverable buffer of other threads and `true` on this thread's.
- **CodeDiff auto-open:** `select(tid)`, when the chosen deliverable has `att.type == "diff"`:
  - calls `require("cockpit.inbox.review").open(tid, att)`;
  - puts the placeholder in the workspace window with winbar `diff opened in CodeDiff · <CR> reopen`.
- **Winbar:** the workspace winbar drops its deliverable tab strip and keeps the action hints.
- **lualine:** the `buffers` component gets `fmt = function(name, ctx) … end`. It maps buffer names matching `^cockpit://inbox/[^/]+/%x+/(.+)$` to the capture, and leaves others unchanged. Verify `ctx.bufnr` is available; otherwise use `vim.api.nvim_buf_get_name` on the name lookup and record a Ruling.
- **Picker follow:** in the snacks `pick` wrapper, when `vim.fn.getcwd()` starts with `vim.fn.expand("~/.cockpit/projects")`, set `source.follow = true` (opts table form likewise).

- [ ] **Step 1: Write smoke section 15** (headless, with plugins **not** loaded).
  - Seed a thread with two deliverables (md + diff) and call `ui.select(tid)`.
  - **Assert** `vim.tbl_filter(buflisted)` names are exactly the two deliverable buffers.
  - **Assert** `review.open` was called: stub it to record its args before `select`.
  - The lualine `fmt` and picker follow are checked manually (Step 5), since they need the full config.
- [ ] **Step 2:** Run it. Expected: FAIL.
- [ ] **Step 3:** Implement. For lualine, `git add -p lua/plugins/lualine.lua` and stage only the `fmt` hunk.
- [ ] **Step 4:** Run the whole script. Expected: all sections PASS.
- [ ] **Step 5: Manual check** in the real session:
  1. `<leader>ka`: the rail tree folds with `za` / `zM` / `zR`.
  2. Open a run: the lualine tabline shows `design.md`-style names only.
  3. `r` opens the floating composer.
  4. A diff run opens CodeDiff.
  5. `<leader>ff` in the cockpit tab lists files under `repos/…`.
- [ ] **Step 6:** Commit `lua/cockpit/inbox/ui.lua lua/plugins/snacks.lua docs/keybindings.md scripts/cockpit-smoke-herdr.sh` plus the staged lualine hunk: `feat(cockpit): CodeDiff auto-open, deliverable buffer list, picker follow`.
