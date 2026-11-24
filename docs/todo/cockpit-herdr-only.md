# Cockpit: herdr-only agents, one conversation per agent

Direction (2026-11-24): agents are always started from cockpit/nvim and run in herdr; the herdr TUI is just a view
(`gt` → `agent.focus`). An agent is one conversation (its Claude session log), not a set of threads. Delete this
file when the list is done.

- [ ] **Remove the `claude` wrapper** (`scripts/cockpit-claude`, the zsh `claude()` function in nix-darwin dotfiles,
  `scripts/cockpit-spawn.lua`): `claude` goes back to plain Claude; spawn with rail `s` / `:CockpitSpawn`.
  Also drops `~/.cockpit/attached/`, `herdr.attach`'s attached-pane jump (`gT`) and the Stop hook's
  attached-marker "watched" check (replace with: watched = focused in the herdr TUI, `agent.get().focused`).
- [x] **Remove hand-started tmux session support**: `sessions.list()` discovery, `cc:<pid>` agent keys in
  `tree.lua`, tmux `send-keys` delivery in `store.deliver`, tmux interrupt/attach branches in rail/convo, and the
  3 s rail timer (convo kept a 3 s stat-keyed tick rather than an fs watch). Old `cc:` threads fall to *unassigned*; the Stop hook no longer posts from them.
- [ ] **Threads become sessions on disk**: `cockpit_inbox.py post` without `--thread` appends to
  `session-<sid8>` (the Stop hook's id) instead of creating a titled thread; `--title` labels the message.
  Then the rail drops thread rows under agents (status/📎/? counts move onto the agent card) and the
  convo view is the only per-agent view. Legacy titled threads stay readable, merged by owner.
- [ ] **Record `session_id` on posts** (`CLAUDE_CODE_SESSION_ID` in the message `session` block) and join
  ownership on it (architecture review CK-2 / 0.1).
- [ ] **Resume a dead agent** from its conversation (`claude --resume <sid>` in herdr, new registry rec).
- [ ] **Subagent transcripts**: show sidechain (`isSidechain`) runs as collapsible blocks under their Task call.
- [ ] Verify herdr `agent.prompt` with multi-line text submits once (convo composer sends it as is).
