# Cockpit — projects, agent identity, and herdr layout

**Date:** 2026-11-24 · **Tier:** Prototype (personal repo) · **Builds on:** `2026-11-10-cockpit-herdr-runtime-design.md` (step 1), `2026-11-11-cockpit-step2-rail-forks-design.md` (step 2). Where this doc differs, it wins.

## 1. Why

The rail showed a 4-day-old thread ("nothing left to do: tgallant merged the stack…") under the agent titled "ENG-35131 Slack assist POC". Both came from herdr agent `lilt-9` (`term_6608d68c229c0e`, pane `w5:p9`), a single Claude process (pid 69358, running since Nov 18).

- **Nov 20:** the old thread was posted by session `1077c886…`.
- **After a `/clear`:** the process now runs session `8737f883…`, the Slack POC.
- **The bug:** cockpit treats the **herdr terminal** as the agent (`tree.lua` `owner_tid`, `registry.lua` "identity is terminal_id"). So every conversation that ever ran in a pane shares one row. The row's title, model and context come from whichever session is there *now*.

The other symptoms share the same root:

- **One project for the whole org.** Project `lilt` = `["~/dev/lilt"]`, the org root. The `claude` launcher (`scripts/cockpit-claude` → `cockpit-spawn.lua` → `projects.for_dir(cwd)`) auto-creates a project per launch dir, and the user launches from `~/dev/lilt`. Ticket work is invisible as such: the Slack POC in worktree `~/dev/lilt/lilt-mcp-35131`, and the contextdb UI stack in `lilt-mcp-34498` … `34502`, `34499-front`, `34499-interp`.
- **Herdr is a wall of panes.** Every spawn runs `pane.split --direction right` into the project's single `ck/<project>` workspace. `ck/lilt` now has 1 tab and 10 panes.
- **Names carry no meaning.** `lilt-1` … `lilt-13` are slot numbers. The only meaningful label is Claude's session title.

**Success:** in both the rail and herdr, each group is a project the user chose and each row is one Claude conversation. Herdr names read as tickets (`eng-35131`), not slot numbers.

## 2. Goals / non-goals / anti-goals

**Goals**
1. **Agent identity is the Claude session** (session id), not the pane or terminal. Threads belong to the session that posted them.
2. **Projects are user-defined**, each a set of dirs. Ticket-sized projects (`slack-poc`, `contextdb-ui`) are first-class, and one project may span several worktrees and tickets.
3. **Herdr layout:** one workspace per project, one tab per agent. Each tab starts in the dir (worktree) that agent works in.
4. **Herdr names:** agent names and tab labels use ticket keys (`eng-35131`) when a ticket is known.
5. **A new conversation means a new tab.** A one-key "fresh" action replaces `/clear` as the normal way to start over.

**Non-goals**
- **Old layout:** cleaning up the existing `ck/lilt` 10-pane workspace or the stray `~` workspaces w1–w4. They're left alone; new spawns use the new layout.
- **Worktree removal:** removing worktrees when a project ends stays manual.
- **Jira:** no integration (fetching ticket titles). Ticket keys come from branch names, project config or session titles.
- **Rail design:** no visual changes beyond what the new identity and actions require.

**Anti-goals**
- **Inherited threads:** a tab silently inheriting a previous session's threads (the original bug).
- **No correction path:** inferring a hand-launched agent's project from cwd *alone*, with no way to fix it.
- **One worktree per agent:** most agents review or research, and each worktree needs its own installs and builds.
- **Workspace clutter:** one herdr workspace per worktree. A 5-ticket project would become 5+ workspaces.

## 3. Approaches considered

**Layout** (user picked A):

| | Layout | Trade-off |
|---|---|---|
| **A (chosen)** | Project = herdr workspace, agent = tab | Herdr mirrors the rail and there are no narrow panes. You see one agent at a time, which is already true at 10 panes. |
| B | Keep split panes; fix identity and naming only | Smallest change, but herdr stays a wall of panes. |
| C | One worktree workspace per agent | Maximum isolation, but heavy, and wrong for review or research agents. |

**Worktrees** (user picked a):

| | Worktrees | Trade-off |
|---|---|---|
| **a (chosen)** | Cockpit runs `git worktree add` itself (as `forks.lua` already does). A worktree is a project dir, and an agent's tab `cwd` is its worktree. `herdr worktree list` is used only for discovery. | Herdr stays one workspace per project, but herdr's own worktree-workspace grouping goes unused. |
| b | `herdr worktree create/open`, one workspace per worktree, project = a group of workspaces | Herdr-native, but recreates the clutter. |

**Naming after `/clear`** (user: stop clearing and start fresh agents instead):

- **Chosen:** the name and tab label stick to the tab, and the new "fresh" action is the clean path.
- **Still handled:** a `/clear` is handled correctly for identity (§4.3). Only the herdr name can go stale, which is the accepted trade-off.

## 4. Design

### 4.1 Projects

`~/.cockpit/projects/<name>/project.json`:

```json
{
  "name": "contextdb-ui",
  "repos": ["~/dev/lilt/lilt-mcp-34500", "~/dev/lilt/lilt-mcp-34501", "~/dev/lilt/lilt-mcp-34499-front"],
  "ticket": "ENG-34498",
  "created": "…"
}
```

**Fields**
- **`repos`** keeps its name (no migration) but means **dirs**: any dirs, git or not.
  - `repos[1]` is primary: the workspace cwd, and the default tab cwd.
  - When spawning an agent, every *other* dir is passed as `--add-dir`, as today.
- **`ticket`** (optional): the project's default ticket key, used for naming when a dir has none (§4.4).

**Which project a dir belongs to** (shared by `projects.for_dir`, the launcher, `tree.project_for_cwd` and `cockpit_inbox.py project_of`):
- The `COCKPIT_PROJECT` env wins.
- Otherwise, the project whose dir contains `dir` most specifically (longest match). For example, `~/dev/lilt/lilt-mcp-34500/src` → `contextdb-ui`, and `~/dev/lilt/core` → `lilt`.
- This replaces `for_dir`'s "primary-repo match, worktree collapses to its main repo" logic. A worktree must resolve to its own ticket project.

**Auto-create stays as a fallback.** A launch from a dir that no project contains creates a one-dir project named after the repo, as today. The user fixes projects by editing JSON (`:CockpitProject edit`).

**Creating and growing projects.** `:CockpitProject new`, and `s` → "+ new project" in the rail, start with a choice:
1. **Dirs:** today's flow (name → pick dirs).
2. **New worktree:**
   - Pick a base repo, then enter a ticket key (optional) and a short slug.
   - Branch: `eng/<TICKET>-<slug>`.
   - Path: `<repo>-<ticket number>`, or `<repo>-<ticket number>-<slug>` if that path exists (the user's existing sibling convention).
   - Runs `git worktree add -b <branch> <path> <base ref>` and creates a one-dir project.
3. **Existing worktrees:** pick a repo, then multi-select from `herdr worktree list --cwd <repo>`, which includes branch and detached state. This creates a project with those dirs.

`:CockpitProject add-worktree [project]` runs flow 2 or 3 to append dirs to an existing project.

### 4.2 Herdr layout

- **Workspace per project.**
  - Labelled `ck/<project>` and created with `workspace create --cwd <repos[1]> --label ck/<name>`.
  - Found by label at runtime. Unchanged rules: never persist workspace ids, never adopt unlabelled workspaces.
- **Tab per agent.** `spawn(project, prompt, {dir})` replaces `pane.split`:
  - It runs `tab create --workspace <ws> --cwd <dir> --label <agent name> --env COCKPIT_PROJECT=<project> --env COCKPIT_INBOX_DIR=… --no-focus`.
  - Then it runs `agent start` in that tab's root pane.
  - The tab's dir comes from: `opts.dir`, else a pick from the project's dirs when there is more than one, else `repos[1]`. The launcher passes its cwd.
  - The user may split a tab for a shell. Cockpit never touches extra panes.
- **The workspace's root tab is the project shell.** On first spawn, cockpit creates the workspace, renames its first tab to `shell`, and then creates the agent tab. Agents never start in `shell`.
- **Forks** (`forks.lua`) open in a new tab of the parent's workspace instead of splitting the parent's pane. Worktree forks use their own `cwd`.
- **Kill** closes the agent's **tab** when that tab holds only the agent's pane; otherwise it closes just the pane.
- **Fresh (`R` on an agent row, and `:CockpitFresh`):** with confirmation, kill the agent's tab, then `spawn()` a new agent in the same project and dir. The new agent gets the next name in the sequence (§4.4). This is the supported way to start a new conversation.

### 4.3 Agent identity = Claude session

**Where the session id comes from**
- Herdr reports it per pane as `agent_session.value` in `agent.list`, `agent.get` and `pane.list`. It follows in-process session changes: lilt-9 reports `8737f883` now, from the same process that ran `1077c886`.
- The statusline files (`sessions.by_herdr_pane()`) and `~/.claude/sessions/<pid>.json` (`sessionId`) also carry it.

**Cache.** `herdr.lua apply` adds `session_id = a.agent_session and a.agent_session.value`.

**Registry** (`registry.lua`)
- Records are keyed by `session`. A record is `{name, session, terminal_id, pane_id, tab_id, project, dir, parent_session?, fork?, ts}`, and the latest line per session wins.
- The session id isn't known at `agent.start`, and none of the 18 existing records has one. So **reconcile learns it.** When a cached agent's terminal has a registry record with no session, or a different one, reconcile appends a record for the current session: same seat, same name and project.
- The previous session's record is then no longer live, so it shows under **Past**. This covers `/clear`, updates, and a new `claude` in the same pane.
- Legacy records without `session` are keyed by `terminal_id` until that terminal's first reconcile.

**Threads**
- New threads record the posting session. `cockpit_inbox.py herdr_identity()` adds `session_id` from the pane's `agent.list` entry, which it already reads for `name`.
- For threads posted outside herdr, `session()` adds the session id from `~/.claude/sessions/<pid>.json` for the nearest Claude ancestor process. `os.getppid()` is often a Bash-tool shell, not Claude: today's spec thread recorded pid 28604, which wasn't a Claude process.
- **One-time backfill of old threads** (a `cockpit_inbox.py backfill-sessions` command, run once and idempotent). For each thread with no session id:
  1. A thread id of the form `session-<8hex>` matches the transcript `~/.claude/projects/*/<8hex>*.jsonl`.
     - Example: `session-1077c886` → session `1077c886-1766-…`.
  2. Otherwise, search transcripts for the thread id. The session whose transcript contains it posted it.
     - Example: `20261124-070847-eng-35131-…` → session `8737f883…`.
  3. Unmatched threads stay without a session.
  - It writes an `owner` event carrying `session_id`. Store reads already use `t.owner = t.owner or e.session`; the builder adjusts so a later owner event wins.

**Ownership** (`tree.owner_tid(t)`): the thread's session id; else `orphan`. Orphans go under the project's **Past** as "earlier session" when their terminal is known, otherwise under Unassigned. A thread is **never** attached to a live agent by terminal alone.

**Other changes**
- Hand-started non-herdr sessions (`cc:<pid>` in `tree.lua`) switch to their session id; `sessions.list()` already returns it.
- Forks nest by `parent_session` instead of `parent_terminal`.
- `claude --resume <id>` should keep `<id>` (spike §5). If it does, a resumed conversation reattaches its row and threads.

### 4.4 Naming

**Rail row label:** the Claude session title (unchanged). The secondary line shows `herdr <name>`.

**Herdr agent name (= tab label):** chosen at spawn, first match wins:
1. **The ticket key of the tab's dir:** the branch name of that worktree (`eng/ENG-34500-…` → `eng-34500`). For a detached worktree, the dir name (`lilt-mcp-34500` → `eng-34500` when the project's ticket prefix is `ENG`).
2. **The project's `ticket`.**
3. **A ticket key in the spawn prompt.**
4. **Fallback:** `<project>-<n>`, as today.

**Rules**
- **Duplicates:** a second live agent with the same key gets `-2`, `-3`, ….
- **Uniqueness:** names are unique **among live agents** (herdr's rule). Drop step 1's "never reused within a project", since the registry no longer relies on names. Keep the `fork/<name>-*` branch check.
- **Late rename:** an agent that still has a fallback name gets renamed once, when its session title first contains a ticket key. It uses `agent rename` plus `tab rename`, if the name is free. This turns today's `lilt-9` into `eng-35131`. It never overrides a name the user set by hand (any name not matching the fallback pattern).
- **Ticket keys:** must match a configured prefix list, default `{ "ENG" }` (`require("cockpit").config.ticket_prefixes`), followed by `-\d+`. "GPT-5" and "UTF-8" never count.
- **After a `/clear`:** the name sticks to the tab (§3). "Fresh" is the clean path.
- **Charset:** herdr requires `[a-z][a-z0-9_-]{0,31}`. Lowercase and truncate.

### 4.5 Rail

The tree shape stays `projects > agents (forks nested) > threads`. Changes:
- **Keys:** agents are keyed `a:<session_id>`.
- **Past:** contains dead sessions and "earlier session" orphans.
- **`R` fresh** (§4.2).
- **`m` move to project:**
  - It appends a registry record that sets `project` for **that session**. The tab stays in its herdr workspace.
  - Precedence for an agent's project: the registry move, then the workspace label, then the registry `project`.
  - Thread placement follows the owning agent, so moved threads go along. The `COCKPIT_PROJECT` env still stamps the old project on *new* thread metadata, but the tree no longer reads that for placement.
  - A new session in the same tab gets the workspace's project.

## 5. To verify early (spike before building on them)

1. `tab create --env` reaches a Claude started by `agent start` in that tab's root pane, so `COCKPIT_PROJECT` is visible to `cockpit_inbox.py`.
2. `claude --resume <id>` keeps `<id>` as the session id that herdr's `agent_session` reports.
3. `agent rename` works on a live, idle agent without disturbing it. `tab rename` works on a tab hosting an agent.
4. Closing a tab via the API ends the Claude process in it (for kill and fresh).

## 6. Calls I made (check these)

- Kept the `repos` key (it means dirs) instead of renaming it to `dirs`.
- Auto-create still runs for dirs no project contains.
- The workspace root tab is renamed `shell` and never hosts an agent.
- New-worktree path is `<repo>-<ticket number>[-<slug>]` and the branch is `eng/<TICKET>-<slug>`.
- Late rename to a ticket slug happens automatically, once, and only from a fallback name.
- Ticket prefixes default to `ENG` only.
- Old threads are tagged once, by thread-id prefix or by searching transcripts. Unmatched ones go to Past or Unassigned and are never guessed onto a live agent.
- "Move to project" applies per session.
- Fresh (`R`) asks for confirmation before killing.

## 7. Left to the builder

- Exact UI for the project creation and add-worktree flows (`vim.ui.select` / `vim.ui.input` chains, like today).
- How reconcile detects a session change cheaply (compare cached `session_id` per terminal).
- Fixture updates for `tree.build` tests and `scripts/cockpit-smoke-herdr.sh`.
