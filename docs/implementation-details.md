# Implementation Details

Deep implementation notes for specific modules. Read this when working on the relevant subsystem.

## Dashboard Animation State Management

- `shouldPlayAnimation` flag prevents re-animation on buffer switches
- Folding is explicitly disabled for dashboard buffers via multiple autocmds (`FileType`, `BufWinEnter`, `WinEnter`)
- Animation plays once on startup (100ms delay), then stops when dashboard closes or any action is taken
- `lastRenderedFrame` optimization prevents unnecessary dashboard updates

## Terminal Background Sync

- Uses OSC 11 (set background) on `UIEnter`/`ColorScheme` events
- Uses OSC 111 (reset background) on `UILeave` event
- Reads `Normal` highlight background color and syncs entire terminal frame to match Neovim theme

## Scoped Grep (`lua/lib/scoped-grep.lua`)

- Seeker-style `<C-e>` toggle between file picker and grep within scoped file lists (progressive refinement)
- All scopes start in **file picker** mode showing the scoped files, then `<C-e>` toggles to grep (and back)
- `grep_buffers()`: Scope = open listed buffers with on-disk files
- `grep_git_changed()`: Scope = files changed since merge-base with `origin/main`
- `grep_diff()`: Scope = files changed vs user-selected branch/commit (interactive branch picker)
- `grep_files(files, title)`: Generic entry point for any custom file list
- State resets on each invocation — no cross-session leakage
- Multi-select (Tab) in file picker narrows the scope; otherwise all filtered items carry over

## Performance Monitoring System (`lua/config/performance.lua`)

- FPS counter: 30-sample rolling average, 1s cache
- Event loop latency: measures `vim.schedule` round-trip, 20 samples, 1s interval
- Input lag: tracks `InsertCharPre` → `TextChanged` delta, 15 samples, 100ms throttle
- Buffer load time: `BufReadPre` → `BufReadPost` delta, 10 samples, cached per buffer

All metrics displayed in lualine with color-coded thresholds (green/yellow/red). Metrics progressively hide at narrow widths: buffer load drops at <160 cols, input lag at <140, latency at <120, FPS at <100.

## LSP — tsgo (experimental)

- Uses `tsgo --lsp --stdio` as TypeScript/JavaScript LSP (replaces vtsls, which is explicitly disabled)
- **This is a preview build** — commit note says "will need to be updated to final version"
- vtsls, ruff, and pyright are all disabled

## Neovim Bridge (`scripts/nvim_bridge.py`)

- Python CLI that connects to a running Neovim via socket (pynvim)
- Socket discovery: `$NVIM_LISTEN_ADDRESS` → `/tmp/nvim-server.pipe` → `$NVIM` → sibling tmux pane auto-detection
- Commands: `open`, `open_many`, `harpoon_add/list`, `mark`, `trail`, `kulala/kulala_gen`, `scoped_grep`, `buffers`, `cursor`, `state`, `exec`, `cmd`
- Used by the Claude Code `/nvim-bridge` skill to stage files, drop marks, and query editor state from agent context

## Sidekick (`lua/plugins/sidekick.lua`)

- `sidekick.nvim` integration for Claude Code as an in-editor AI assistant
- Uses tmux mux backend with vertical split (50% width)
- Auto-creates/attaches to a Claude session without picker prompt
- Supports sending context: current buffer (`{this}`), file (`{file}`), all buffers (`{buffers}`), visual selection (`{selection}`)

## Cockpit (`lua/cockpit/`, `scripts/cockpit*`)

Agent review inbox + agent runtime front end. Agents (Claude Code) post documents, diffs and questions; you review, edit, annotate and send a verdict from one nvim tab. Agents run headless in **herdr** (or as plain Claude sessions you started yourself in tmux). Keys: [keybindings.md](keybindings.md) → "Cockpit". Design history lives in git (removed `docs/superpowers/`); current state and Production gaps: [todo/cockpit-architecture-review.md](todo/cockpit-architecture-review.md).

### Modules

| File | Role |
| --- | --- |
| `scripts/cockpit_inbox.py` | Agent-side CLI (`post`, `wait`, `read`, `list`, `card`) + Claude Code hooks (`hook stop`, `hook prompt`). Owns `inbox/` writes from the agent side |
| `scripts/cockpit-claude` | `claude` wrapper (the zsh `claude()` function calls it): spawns the agent headless in herdr via `cockpit-spawn.lua` and attaches in the current tmux pane. Falls back to plain `claude` outside tmux, inside herdr, for `-p`/`--version`/positional prompts, in `$HOME` or `/`, or with `COCKPIT_NO_HERDR=1` |
| `scripts/cockpit-spawn.lua` | Headless nvim entry used by `cockpit-claude` to resolve the project and spawn |
| `scripts/cockpit-smoke-herdr.sh` | End-to-end smoke test against a scratch herdr session and temp dirs |
| `lua/cockpit/herdr.lua` | The only nvim ↔ herdr code: NDJSON socket client, live agent cache, spawn/kill/interrupt/attach/prompt. Always uses explicit target ids, never `--current` (herdr #2900) |
| `lua/cockpit/projects.lua` | Named repo sets; `for_dir()` maps a directory to a project, creating one if needed |
| `lua/cockpit/registry.lua` | Per-project `agents.jsonl` |
| `lua/cockpit/sessions.lua` | Read-only discovery of Claude sessions you started yourself in tmux (not run by herdr) |
| `lua/cockpit/forks.lua` | `continue` / `worktree` forks of an agent's session (`--resume <id> --fork-session`) |
| `lua/cockpit/profiles.lua` | Launch profiles picked on spawn/fork (model, effort, plugins, `--settings`…). Built-in `default` adds no flags; more in `~/.cockpit/profiles.json`. The picker is skipped while `default` is the only one; the choice is recorded as `profile` in `agents.jsonl` |
| `lua/cockpit/inbox/store.lua` | Reads and writes the JSONL shared with the Python CLI; derives thread state; delivers replies |
| `lua/cockpit/inbox/ui.lua` | The tab: rail (left) · workspace (deliverable) · thread (bottom); composer + notes float |
| `lua/cockpit/inbox/rail.lua`, `tree.lua` | Rail rendering; `tree.lua` is the pure project → agent → fork → thread model |
| `lua/cockpit/inbox/review.lua` | Diff deliverables in CodeDiff, rebuilt from the sent patch (never touches the agent's worktree) |

### File system (`~/.cockpit/`)

Logs are append-only JSONL and are never rewritten. All state (status, drafts, read/archived, current card lane, live agents) is derived by replaying them. Every line has a `{v: 1, at, ts, id}` envelope. The Python and Lua sides read and write the same files.

```
~/.cockpit/
├── inbox/                      $COCKPIT_INBOX_DIR
│   ├── threads/<tid>.jsonl     one event log per thread (tid: YYYYMMDD-HHMMSS-<slug>, or session-<sid8> from the Stop hook)
│   ├── blobs/<sha256>          attachment bytes as sent, so notes stay pinned to what was reviewed
│   ├── turns/<session>.json    per-repo state at turn start (written by `hook prompt`)
│   ├── waiting/<tid>           touched every 2 s while an agent blocks in `wait`
│   ├── edits/<tid>/<sha256>    your edited copy of a file deliverable
│   ├── review/<tid>/<sha12>/   diff deliverable trees: base/ (before) · review/ (editable) · sent/ (agent's, pristine)
│   ├── cards.jsonl             board card snapshots (latest line per card wins)
│   └── feedback.jsonl          steering log: one line per verdict / edit / note sent
├── projects/                   $COCKPIT_PROJECTS_DIR
│   └── <name>/
│       ├── project.json        {name, repos[], created}; repos[0] is primary (spawn cwd), rest are --add-dir
│       ├── repos/<basename>    symlink → repo (collision → <basename>-2)
│       ├── threads/<tid>.jsonl symlink → inbox thread (browsing only; nothing reads through it)
│       ├── agents.jsonl        {terminal_id, name, project, session, ts, dead?}; forks add fork ("continue"|"worktree"), parent_terminal, parent_name, worktrees[{repo, path, branch, base}]; latest line per terminal_id wins
│       └── names/<name>        O_EXCL name claims so two spawns can't take the same name
├── attached/<terminal_id>      $COCKPIT_ATTACH_DIR: tmux pane id where cockpit-claude has this herdr agent attached
└── status/<session_id>.json    $COCKPIT_STATUS_DIR: status line input JSON saved by claude-statusline.sh (nix-darwin dotfiles)
```

**Thread events** (`kind`):

| kind | Writer | Fields |
| --- | --- | --- |
| `message` | agent | `text`, `attachments[]`, `questions[{id,text,options}]`, `gate`, `stage`, `pipeline`, `stages`, `session{agent,tmux_pane,herdr{pane_id,workspace_id,terminal_id,name},cwd,pid}`; first message also has `title`, `project` |
| `annotation` | you | `sha256`, `attachment`, `line_start`, `line_end`, `quote`, `loc`, `label`, `blocking`, `text` |
| `annotation_deleted` | you | `target` |
| `reply` | you | `verdict` (approve · approve_with_notes · changes_requested · reject · none), `text`, `answers[]`, `annotations[]` (the drafts it sends), `edits[]`, `stage`, `round` |
| `ack` | agent | `reply` (id the agent has read) |
| `state` | you | `read`, `archived` |

**Attachments**: `{name, sha256, type: "file"|"diff"}`. Files also carry `path`. Diffs also carry `base`, `base_sha` (resolved when posted), `head` and `cwd`.

**What `store.thread()` derives**:
- `drafts`: annotations that are neither deleted nor already sent.
- `status`, first match wins:
  - `replied`: the last event is your reply.
  - `needs_you`: there are open questions, or the last message has `gate`.
  - `unread`: the last message's `ts` is newer than the read marker.
  - otherwise `read`.
- `round`: count of messages per `stage`.
- `deliverables`: the latest message that has attachments.
- `owner`: the first message's `session`. Project is matched by the `COCKPIT_PROJECT` env var, else the git common dir's basename (so worktrees share their main repo's project).

### Flows

- **Posting**: `cockpit_inbox.py post` copies the attachments into `blobs/` and appends a `message`. `--gate` (or any `--stage`) puts the thread in `needs_you`. `--wait` blocks on `wait`.
- **CLI exit codes** (`post --wait`, `wait`, `read --new`). Verdicts and errors never share a code, so a failing CLI can't pass for a verdict:

  | Code | Meaning |
  | --- | --- |
  | 0 | approved, approved with notes, or a plain reply |
  | 10 / 11 | changes requested / rejected |
  | 12 | `wait --timeout` ran out |
  | 64 | usage error (argparse, `post` without `--title`, invalid thread id) |
  | 65 | nothing to post (empty diff) |
  | 66 | no such thread or card |
  | 70 | internal error (traceback on stderr) |
- **Stop hook** (registered in `~/.claude/settings.json`): runs only in tmux or herdr sessions, and only when nobody is watching the agent's pane. A herdr agent counts as watched only while it's attached (marker in `attached/`) and that tmux pane is visible. Then:
  - If the turn changed files, the hook **blocks the stop** and tells the agent to `post` them.
  - Otherwise, if the last line of the agent's message ends in `?` (or the session is already replying to a thread), it posts that message itself.
- **Reply delivery** (`store.deliver`), first match wins:
  - The agent is blocked in `wait` (fresh `waiting/<tid>`): it reads the reply itself.
  - The thread has a herdr session: `agent.prompt`, joined on `terminal_id`. Never falls back to tmux for these.
  - Otherwise, a one-line `tmux send-keys` to `session.tmux_pane`. The agent then runs `read <tid> --new`, which also appends the `ack`.
- **Turn diffs** (`post --diff` with no REV, inside a Claude session): one diff per repo the turn touched, compared against the `turns/` snapshot. The snapshot comes from `git stash create`, so your own uncommitted work is left out. Repos without a snapshot fall back to the edited files vs HEAD.
  - **Not wired yet:** `hook prompt` (UserPromptSubmit) isn't registered in `~/.claude/settings.json`, so `turns/` is never written and only the fallback runs.

## Buffer Reuse Strategy

- `switchbuf = {"useopen", "usetab"}` in `init.lua:6` — reuses existing buffers/tabs when opening files
