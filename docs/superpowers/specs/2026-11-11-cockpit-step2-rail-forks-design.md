# Cockpit step 2: project rail, forks, and polish

**Date:** 2026-11-11 · **Tier:** Prototype (happy-path smoke only) · **Repo:** `~/.config/nvim`
**Builds on:** `2026-11-10-cockpit-herdr-runtime-design.md` (step 1, shipped: `lua/cockpit/herdr.lua`, `projects.lua`, rail glyphs and keys) and the rail/workspace/thread cockpit in `lua/cockpit/inbox/ui.lua`.

## 1. Intent

**The problem today:**
- The rail is a flat list of **threads** grouped by git repo. Nearly all of them come from tmux-era agents that are long dead, so 14 rows read "waiting on you" for 1–6 days. You can't see which agents are running, and there's no way to branch an agent's work.
- Each row takes two lines.
- The top buffer list shows internal names (`#7 session-eee7f296`).
- Replies open in a split.
- Diffs need an extra keypress to reach CodeDiff.

Step 2 makes the rail a picture of the **work**: projects → agents → forks → threads. It adds forks for one-off questions and parallel approaches, makes killing an agent clean up after itself, and tightens the look.

**The model (agreed in brainstorming):**

| Term | What it is |
|---|---|
| **Agent** | A live Claude session in a herdr pane. Spawned, forked, or started by hand. |
| **Thread** | A review packet the agent posted: its deliverables (docs, diffs) and questions, plus your notes, edits, answers and verdict. One agent → many threads. |
| **Killing a thread** | Archiving it. A thread is only a record; nothing is lost, because `feedback.jsonl` already holds what you sent. |
| **Killing an agent** | Also archives its threads, since replies to a dead agent have nowhere to go. |
| **Continue fork (`f`)** | A new agent that branches the parent's conversation (`claude --resume <session> --fork-session`) in the same checkout. It's an ordinary agent; no special rules. |
| **Worktree fork (`F`)** | The same branch of the conversation, but running in its own git worktree on branch `fork/<parent>-<n>`. Used to explore a different approach without touching the parent's files. |

## 2. Goals / non-goals / anti-goals

**Goals**
1. A rail organized **project → agent → fork → thread** ("layout A"), with every level foldable using vim's `z` keys.
2. Higher density: **one line per row**.
3. **Forks:** `f` continue and `F` worktree, from an agent row or a thread row (where they act on that thread's agent).
4. Kill agent → archive its threads. `:CockpitCleanup` archives threads of agents that died without `X` (crash, closed by hand). *(The tmux-era threads and processes were deleted by hand on 2026-11-11, so no migration of them is needed.)*
5. A **project directory** convention, with the cockpit tab's cwd (`:tcd`) set to it.
6. Reply and line-note composers open as **floating windows**.
7. Diff deliverables open **directly in CodeDiff** (codediff.nvim).
8. In the cockpit tab, the lualine **buffer list shows only the current thread's deliverables**, named by file.

**Non-goals**
- PRD, context and memory content (step 3). Step 2 only creates the empty project directory those will live in.
- Reviving a dead agent by replying to its archived thread (later).
- The board. It stays as-is.
- Changing how the workspace window shows markdown deliverables.

**Anti-goals**
- Folds or the cursor jumping on the 3 s refresh.
- A fork ever touching the parent's worktree (`F`), or deleting a fork branch that has commits without asking.
- Losing data on kill or cleanup: archive only, never delete thread files.

## 3. Design

### 3.1 Project directory (replaces step 1's flat `<name>.json`)

```
~/.cockpit/projects/<name>/
  project.json            { name, repos[], created }   (same schema as step 1)
  repos/<basename> -> <repo path>     one symlink per repo (basename collision → <basename>-2)
  agents.jsonl            cockpit's agent registry (3.3)
  threads/                symlinks to this project's ~/.cockpit/inbox/threads/<id>.jsonl, for browsing
  PRD.md, context/        (step 3; not created yet)
```

- `projects.lua` reads both layouts. On first load it migrates any `<name>.json` into `<name>/project.json` and creates the `repos/` symlinks.
- `projects.save` (re)builds `repos/` from `repos[]`.
- `threads/` links are added when a thread first shows up with that project. They're for browsing only; nothing reads through them.
- **Tab cwd:**
  - When you select a run whose project is known, the cockpit tab does `:tcd ~/.cockpit/projects/<project>`.
  - For unassigned runs it does `:tcd` to the thread's `session.cwd`.
  - The tabline (or winbar) shows the project name.

### 3.2 Rail

**Layout A, one line per row.** Indentation shows nesting; widths assume `RAIL_W = 36`, and long titles are truncated with `…`.

```
COCKPIT  ✋3 ◐2 ⚠1                       ← header: counts across projects
▾ lilt-mcp                   ✋1 ◐1 ⚠1   ← project (counts shown always; essential when folded)
  ◐ lilt-mcp-1                    2m     ← agent: status glyph, name, age of last activity
    ✋ Bulk undo plan        📎3 ?1  13h  ← thread: run status, title, badges, age
    ↩ Retry backoff fix            1h
    ⑂ lilt-mcp-2 wt   ⚠ git push…        ← fork: nested under parent; "wt" = worktree fork;
                                           blocked rows show the pending tool from agent.read
  ○ lilt-mcp-3                   18m
▸ past (4)                                ← dead agents of this project, folded
▸ unassigned                            ← agents/threads outside any ck/ workspace, folded by default
```

**Sorting:**
- **Projects:** by most urgent first (blocked → waiting on you → working → idle), then by name.
- **Agents within a project:** by the same urgency, then most recent.
- **Threads within an agent:** use the existing `RANK`.

**Which agent a thread belongs to:**
- Thread → live agent by `session.herdr.terminal_id`.
- Thread → dead agent: if it has a `session.herdr` block, it groups under `past` with the agent's recorded `name`.
- No `herdr` block (agent ran outside herdr, e.g. a hand-started tmux Claude) → `unassigned`, sub-grouped by its `project` field.

**Folding:**
- Use real vim folds: `foldmethod=expr`, `foldexpr` from a per-line level table built during render (project rows start level 1, agent rows level 2, fork rows level 3), and `foldtext` that returns the row itself, so counts stay visible when folded.
- `za/zo/zc/zM/zR/zj/zk` then work natively.
- **Fold state survives re-render:** before re-rendering, record which node keys (`p:<project>`, `a:<agent>`) are closed. After setting lines, reapply them with `:foldclose` on those rows. Keep the cursor on the same node key, not the same row number.
- Defaults: `past` and `unassigned` start closed.

**Keys:**
- **Agent or fork row:**
  - `X` kills it. The confirm reads `Kill <name> and archive its N threads?`; for a worktree fork it adds the 3.4 cleanup prompt.
  - `f` / `F` fork it.
  - `i` interrupts, `gt` attaches, `<CR>` opens its newest thread.
- **Thread row:**
  - `<CR>` opens it, `a` archives it, `u` toggles unread.
  - `f` / `F` / `X` / `i` / `gt` act on its agent.
- **Any row:** `s` spawns, `A` opens the picker, `g.` shows archived (archived threads render dimmed in place), `R` refreshes.
- The help text moves into a `?` float listing these keys.

**Blocked detail:** for agents with `status == "blocked"`, show the last non-empty line of `agent.read {source = "recent", lines = 15}` that looks like the approval prompt, truncated. Fetch it only on the transition into blocked, and cache it per agent.

### 3.3 Agent registry: `agents.jsonl` (per project)

herdr knows nothing about forks, so cockpit records what it spawns. It's append-only and the latest line per agent wins:

```json
{"name":"lilt-mcp-2","project":"lilt-mcp","parent":"lilt-mcp-1","fork":"worktree",
 "session":"<claude session id>","terminal_id":"term_…","worktree":"/…/.worktrees/fork-lilt-mcp-1-1",
 "branch":"fork/lilt-mcp-1-1","base":"<sha>","ts":…}
```

- Written by `herdr.spawn` (with `fork = nil`) and by the fork functions.
- The rail reads it for parent and child nesting, and for `past` names.
- Agents started by hand aren't in it. They show as top-level agents in their project (if they're in a `ck/` workspace) or under `unassigned`.

### 3.4 Forks (`herdr.lua`)

- **The parent's session id** comes from herdr's `agent_session.value`, seen in `agent.start` results; the builder confirms `agent.get` carries it too. If there's no session id: `notify("cockpit: <name> has no session id yet")` and do nothing.
- **`fork_continue(parent)`:**
  1. Split a new pane in the parent's workspace, with the cwd set to the parent's `cwd`.
  2. `agent.start {kind = "claude", args = {"--resume", session, "--fork-session", <--add-dir…>}}` with the same env as spawn, plus `COCKPIT_PARENT=<parent>`.
  3. Name it `<project>-<n>`.
  4. Use the same readiness wait as spawn (idle | blocked).
  5. Optionally send a first prompt (`vim.ui.input "Fork prompt (optional)"`). For a one-off question you type it here.
- **`fork_worktree(parent)`:**
  1. `branch = fork/<parent>-<n>`, `base` = the parent repo's `HEAD`.
  2. Create the worktree with herdr `worktree.create {cwd = parent repo, branch, base, workspace_id = parent ws}`, or with plain `git worktree add <repo>/.worktrees/<branch-slug> -b <branch> <base>` if herdr's call doesn't give a usable pane. That's the builder's choice; record which.
  3. Start the same `--resume --fork-session` agent with its cwd in the worktree.
  4. Its first prompt is prefixed: `You are a fork of <parent> working in a separate git worktree at <path> on branch <branch>. Only edit files there.`, then your text.
  5. **Risk:** Claude's project memory and `.claude/settings.local.json` key on the cwd, so a worktree path may hit the folder-trust dialog. That falls through to step 1's "blocked → attach now?" flow, which is acceptable.
- **Killing a worktree fork** (`X`):
  1. After `pane.close`, if `git -C <worktree> status --porcelain` is empty and `git rev-list <base>..<branch>` is empty, remove the worktree and delete the branch silently.
  2. Otherwise ask `Keep branch fork/… (N commits, dirty)? [Keep / Discard]`. Keep removes only the worktree directory if it's clean, and leaves it if it's dirty.
- **Accepting a fork's approach:** out of scope. You merge the branch yourself; the rail just shows the branch name.

### 3.5 Kill → archive, plus the one-time cleanup

- `ui.kill_agent(a)` first collects the threads whose `session.herdr.terminal_id == a.terminal_id` and are not archived. It confirms with the count, kills the agent, then appends `{kind = "state", archived = true}` to each thread.
- `:CockpitCleanup` archives every unarchived thread whose agent is not live: a herdr thread whose terminal is gone, or a non-herdr thread whose `tmux_pane` is gone. It previews the list in a float before acting, and you run it by hand. "Kept for next reader" semantics still apply if someone `read`s them.

### 3.6 Floating composers

- **`r`, `A`, `N`, `C`, `X` in the thread window:** today's composer buffer (`acwrite`, `:w` sends, drafts kept) opens in a centered float instead of a split:
  - size `min(100, cols - 10)` × `min(20, lines - 8)`, rounded border
  - title `Reply · <verdict>`, footer `:w send · q keep draft`
- **`ga` line notes:** after the label `vim.ui.select`, the note text is typed into a small float anchored under the selected lines (3 lines, `relative = "cursor"`). `<CR>` in normal mode or `:w` saves; `q` cancels. Multi-line notes are now allowed.

### 3.7 CodeDiff for diffs

- When the selected deliverable is a diff (`att.type == "diff"`), `select()` calls `review.open(tid, att)` directly. CodeDiff gets its own tab, as today.
- The workspace window shows a one-line placeholder: `diff opened in CodeDiff (tab N) · <CR> reopen`.
- `q` in CodeDiff returns to the cockpit tab. That's codediff's own close plus `ui.open()`.

### 3.8 lualine buffer list in the cockpit tab

The goal: inside the cockpit tab, lualine's `buffers` component lists only the current thread's deliverables, named by file (`design.md`, `lilt-mcp-a1b2.diff`).

- Rail, thread and composer buffers are **unlisted** (`buflisted = false`).
- Deliverable buffers are listed. Their buffer **name** stays `cockpit://…`, but lualine shows a friendly name: use a `fmt` in the lualine `buffers` component that maps `cockpit://inbox/<tid>/<sha8>/<name>` → `<name>`. Lualine config lives in `lua/plugins/lualine.lua`.
- On `select(tid)`, set `buflisted = false` on the previous thread's deliverable buffers and `true` on this thread's. scope.nvim keeps that tab-local.
- `:bnext` and `:bprev` then cycle deliverables. Keep `]d` / `[d`.
- The workspace winbar drops its deliverable tabs, which the buffer list now shows, and keeps the action hints.

## 4. Decisions made here (check these)

1. Project directory `~/.cockpit/projects/<name>/`, with automatic migration from step 1's flat JSON.
2. Tab cwd is the project directory, so pickers see every repo through the `repos/` symlinks.
3. Threads from agents outside herdr go under `unassigned`, folded by default.
4. Fold state is kept by node key across refreshes; `past` and `unassigned` start folded.
5. Cockpit's own `agents.jsonl` registry holds fork parentage. herdr has no field for it.
6. Fork names follow `<project>-<n>`, the same as spawned agents. The `⑂` glyph and nesting show they're forks.
7. Worktree fork branch is `fork/<parent>-<n>`, at `<repo>/.worktrees/<slug>` if created by git directly.
8. Unchanged worktree forks are cleaned up silently on kill. Changed ones ask.
9. `:CockpitCleanup` is manual and shows a preview first.
10. Line notes can be multi-line in the float.
11. Help moves to a `?` float.

## 4b. Builder-check answers (settled 2026-11-11)

1. **Worktree forks in multi-repo projects:** every repo in the project gets its own worktree on the same `fork/…` branch name. `--add-dir` points at those worktrees, not the parent's checkouts (this keeps the anti-goal). The `agents.jsonl` fork record holds `worktrees = [{repo, path, branch, base}]`, and kill-cleanup runs per repo, with one combined keep/discard prompt.
2. **Thread ownership:** a thread belongs to the agent that **first** posted it. `store.thread()` sets `t.owner = <first message's session>`, and `t.session` keeps today's meaning (latest poster, used for delivery). The fork preamble (both kinds) says: `Open new inbox threads for your work; don't post to your parent's threads.` The kill-archive rule uses `owner`.
3. **Parent killed:** no cascade. If the parent has live forks, the confirm says so: `Kill lilt-mcp-1 and archive 3 threads? (2 forks keep running)`. Orphaned forks render at the project's top level as `⑂ lilt-mcp-2  (from lilt-mcp-1)`.
4. **Agent identity:** keyed by `terminal_id` everywhere: registry, `past`, and parent links (`parent_terminal`). Names are display-only, but `free_name` also skips names already in the project's registry and existing `fork/<name>-*` branches, so names are unique across history.
5. **`past`:** driven by `agents.jsonl`. It lists dead agents even when all their threads are archived, and `past (N)` counts agents. `<CR>` on a past agent lists its archived threads (same as `g.`).
6. **Symlinks:** fd and rg don't follow symlinks by default. In the cockpit tab only, project pickers pass follow-symlinks (snacks picker `follow = true` for files and grep when the cwd is under `~/.cockpit/projects`). Global picker config is unchanged.
7. **herdr `worktree.create`:** not used. It opens an unlabelled workspace with no `env`. Forks use plain `git worktree add <repo>/.worktrees/<slug> -b <branch> <base>`, and the fork pane is split in the parent's `ck/` workspace with the usual env.

## 5. Risks / verify during build

- `agent.get` / `agent.list` carry `agent_session.value` (seen in `agent.start` output). If not, use the session id from the thread's Stop-hook payload, which `cockpit_inbox.py` already receives, and record it in `session`.
- `--resume <id> --fork-session` while the parent is still live in another pane: confirm both keep working independently.
- Worktree cwd and folder trust (3.4).
- Foldexpr in a `nofile` buffer that's re-rendered every 3 s: measure for flicker. If folds misbehave, fall back to a manual collapse set with the same keys mapped (`za` etc.), keeping the same behavior.
- lualine `fmt` for the buffers component: confirm it receives the buffer number or name.

## 6. Done when

`scripts/cockpit-smoke-herdr.sh` gains sections that check:
1. The project dir migrates, and its `repos/` symlinks exist.
2. The rail renders project → agent → thread with a fork nested under its parent, one line per row.
3. `zc` on a project survives a re-render.
4. `fork_continue` produces a live agent whose `--resume` session differs from the parent's.
5. `fork_worktree` creates the branch and worktree, and killing it unchanged removes both.
6. Killing an agent archives its threads.
7. `:CockpitCleanup` archives a seeded thread whose agent is gone.

Plus a manual pass in your real setup covering the float composer, the CodeDiff auto-open, and the lualine buffer list.
