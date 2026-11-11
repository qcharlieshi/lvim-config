# Neovim as the single hood — "vim + tmux under one roof"

**Date:** 2026-08-28 · **Question:** can nvim be the whole cockpit UI (windows = panes, tabpages = tracks, floats = dashboards, `:terminal` = agents, vim grammar = input), with tmux/shpool reduced to a durability engine underneath? · **Method:** Exa search of 2026 sources, issues, and plugin READMEs; no code run. Builds on `2026-08-28-cockpit-architecture-alternatives.md`.

## 1. Durability pattern

| Option | Survives nvim crash | What breaks / gotchas |
|---|---|---|
| **`:terminal tmux -L cockpit attach -t <agent>`** (inner tmux server, prefix `None`, `status off`) | Yes — agents live in the inner server | Nested tmux needs `escape-time 0` on the inner server ([tmux-users](https://groups.google.com/g/tmux-users/c/kjnAcoh6NRs)); nvim's `:terminal` **does not forward CSI-u / modifyOtherKeys** to the child PTY — Shift+Enter, Alt+Enter, most Ctrl+Shift chords die at libtermkey; only legacy sequences pass. Workaround: buffer-local `tnoremap` → `nvim_chan_send(job, "\x1b[13;2u")` per key (sidekick.nvim [#289](https://github.com/folke/sidekick.nvim/issues/289), tmux 3.6a `extended-keys-format csi-u`). Claude Code uses Shift+Enter for newline, so this is mandatory, not optional. OSC responses (bg colour, OSC 11) are answered by tmux, not the outer terminal ([tmux#3964](https://github.com/tmux/tmux/issues/3964)). `pipe-pane`, `send-keys`, `$TMUX_PANE` in hooks all keep working. |
| **shpool** | Yes | No multiplexing; single client per session; state restore via vt100 render; "doesn't restore terminal state properly" per a 2025 migrator ([BigGo](https://biggo.com/news/202508021314_Developer_Ditches_tmux_for_Simpler_Setup)); only one of dtach/abduco/shpool could detach from inside nvim (command-based detach). |
| **abduco / dtach** | Yes | No screen restore on reattach; per-session process: 100 sessions ≈ 92–98 MB vs tmux 26 MB ([dev.to/tumf 2026-01](https://dev.to/tumf/session-management-in-parallel-in-search-of-a-tmux-alternative-only-to-find-tmux-is-the-best-2hfk)) — "for 100 parallel AI sessions, tmux is the lightest". |
| **Herdr** (Rust server that *owns* agent PTYs; socket API; 21 agents detected; session restore; signalbox.nvim view) | Yes | Another daemon with its own detection (screen manifests + hooks); duplicates what we get for free by spawning ([herdr](https://github.com/herdrdev/herdr), [signalbox.nvim](https://github.com/nwiizo/signalbox.nvim)). Worth watching; not needed. |
| **nvim 0.12 `:detach` / `:connect` / `--remote-ui`** | **UI only.** `:terminal` jobs die with the *server*; `:detach` keeps the server alive across UI loss, not across a server crash | `:detach!` marks detachable; `[count]<C-z>` detaches; `:connect` hot-swaps servers ([ui-lifecycle](https://neovim.io/doc/user/gui/), [#5035](https://github.com/neovim/neovim/issues/5035)). Still maturing: `restart`/`connect` events formalised as a 0.12 blocker ([#35149](https://github.com/neovim/neovim/issues/35149)); dangling servers if clients fail to reattach; `--embed --listen` exits when stdio closes ([#38456](https://github.com/neovim/neovim/issues/38456)); `:terminal` lag after days of remote reconnects ([#35107](https://github.com/neovim/neovim/issues/35107)). |

**Rendering cost of N terminals inside nvim:** libvterm → buffer sync every 10 ms (`REFRESH_DELAY`, [terminal.c](https://github.com/neovim/neovim/blob/master/src/nvim/terminal.c)); rapid output slows *all* windows ([#11090](https://github.com/neovim/neovim/issues/11090)); ≥10–12k scrollback lines make a tab sluggish; big screens are worse than vim ([#20408](https://github.com/neovim/neovim/issues/20408)). Mitigation that fits us: agent terminals get `scrollback=1000` because the full log is in `pipe-pane` files for lnav. The libghostty-vt replacement ([#39773](https://github.com/neovim/neovim/pull/39773), targeting 0.13) fixes reflow but currently regresses large-scrollback perf.

## 2. nvim as multiplexer in practice

- **Direct precedent:** barrettruth's `mux`, ported by harivansh ([PR #286](https://git.harivan.sh/harivansh-afk/nix/pulls/286)): one detached `nvim --headless --listen` **per project**, thin `--remote-ui` clients, tagged view tabpages (edit/vcs/ai/zsh), untagged tabs as tmux-style windows, mksession snapshots (5-min autosave + restore), `:connect` project switching, tmux muscle-memory prefix dispatcher, `linger` for logout survival, OSC 7 → tab auto-rename. Hard-won rules in its commits: **never map `<Esc>` in terminal mode** (it must reach the agent); park the cursor on the last line on `WinLeave` so background terminals keep tailing; `G` = jump to tail and resume insert.
- 2026 write-ups ([Oliver Davies](https://www.oliverdavies.uk/blog/using-neovim-terminal-multiplexer), [Salcedo](https://dev.to/javiersalcedopuyo/neovim-is-my-terminal-multiplexer-30il), [Kraust](https://kraust.github.io/posts/neovim-is-a-multiplexer/), [jonfk](https://www.jonfk.ca/blog/neovim-as-terminal-multiplexer/)) agree on the wins — one keymap, text objects over terminal output, consistent theme — and on the misses: no session persistence without extra work, multi-project is awkward (Ghostty tabs or `:connect`), background terminals don't auto-follow, `<C-\><C-n>` ergonomics.
- **Agent-terminal managers already exist:** agentpanel.nvim (floating rail of `claude`/`codex` terminals grouped by project + worktree, activity spinner→bell, persisted metadata), agent-workbench.nvim (pi RPC sessions as buffers; tab = workspace), aiterm/agent-term/nvim-agent (previous report). All of them host agents *inside* nvim and inherit the durability gap.

## 3. Dashboards inside nvim

- Live buffers driven by `uv.fs_event` are a solved pattern: cc-watcher.nvim (sidebar of Claude edits, `fs_event` "zero CPU idle", debounced notifications), agentsync.nvim (recursive `fs_event` on macOS, poll fallback on Linux, 100 ms debounce), live-autoread.nvim (per-buffer watchers, `checktime` only for visible buffers — exactly what `STATE.md` needs), agent-tail.nvim (Claude `PostToolUse` hook → event file → `nvim --server … --remote-expr`; **no daemon**, sidebar + synthetic `vim.diff()` per event).
- Extmark renderers for streaming content: coact.nvim (extmark headers, virtual lines, spinner, auto-follow that suspends when you scroll away), agent-workbench (History buffer with folds, statusline with state/tokens/cost).
- **Fleet tables exist:** hangar.nvim dashboard (status/cost/turns/files), signalbox.nvim attention board (90% float, `blocked`/`done` first, read-only preview pane, one control chord `<C-g>` to toggle board↔terminal), agentpanel rail. None reads *our* JSON, but the field lists are directly reusable for `status.lua`.

## 4. Meta-agent controllability

nvim RPC covers everything the cockpit needs: `nvim_open_win(buf, enter, {split="right", win=0|<id>|-1, width=…})` creates real splits, in other tabpages too, and `nvim_win_set_config` moves floats↔splits ([news-0.10](https://neovim.io/doc/user/news-0.10/), [win_config.c](https://github.com/neovim/neovim/blob/master/src/nvim/api/win_config.c)); `nvim_open_term` + `nvim_chan_send` drive terminals; `nvim_set_current_tabpage`, `winrestcmd`, `mksession` handle layouts. The bridge already speaks this; it just needs `--socket` pointed at the headless server. One nvim server holding the *UI* is a real SPOF for layout — mitigated by mksession autosave + `mux restore`-style relaunch — but with agents in the inner tmux it is **not** a SPOF for work.

## 5. Vim grammar over non-text things

oil.nvim's model is the template: entities are lines in a buffer, edits are staged and applied on `:w`, `BufReadCmd`/`BufWriteCmd` own the lifecycle, actions are named and rebindable ([oil](https://github.com/stevearc/oil.nvim), [mutation system](https://deepwiki.com/stevearc/oil.nvim/3.2-mutation-system)). A `cockpit://agents` buffer where `dd` kills (with confirm), `y` approves, `<CR>` attaches, and `:w` applies queued sends is idiomatic and cheap. For documents, `mini.ai` `gen_spec.treesitter` + `after/queries/markdown/textobjects.scm` gives `ah`/`ih` section textobjects (caveat: `markdown_inline` captures aren't searched from `markdown` — [mini#2397](https://github.com/nvim-mini/mini.nvim/issues/2397)); nvim-treesitter-textobjects `move` gives `]s`/`[s`.

## 6. LazyVim and `NVIM_APPNAME`

`NVIM_APPNAME=cockpit` gives a fully isolated config/data/state tree ([:h NVIM_APPNAME](https://neovim.io/doc/user/starting/), [#21691](https://github.com/neovim/neovim/issues/21691)) — child nvims inherit it, so agents' `$EDITOR` would too. But isolation is the *wrong* property here: you want your LazyVim keymaps, pickers, Atlas, sidekick, bridge in the cockpit. `mux` uses an env guard (`MUX=1`) inside one config; do the same (`COCKPIT=1` → load `lua/cockpit/`). Nothing found argues for leaving LazyVim; `NVIM_APPNAME` is the right tool only for a throwaway experiment.

## Proposed architecture (if adopted)

```
Ghostty
└─ [optional] outer tmux session <goal>            ← sessionizer keeps working; or skip it
   └─ nvim --remote-ui --server /tmp/nvim-cockpit-<goal>.pipe   (thin UI; :detach / reattach)
      └─ nvim --headless --listen …  COCKPIT=1     (one per goal; layout, pickers, dashboards)
         ├─ tabpage 0  = main: STATE.md · fleet buffer · cockpit-claude terminal
         ├─ tabpage N  = track: windows = :terminal `tmux -L cockpit attach -t <track>/<agent>` · diff · document
         └─ floats     = attention board, lineage graph, `:`/`Space Space` prompts
tmux -L cockpit (inner server, prefix None, status off, escape-time 0, extended-keys csi-u)
   └─ one session per agent pane: claude / lnav / hwatch …    ← survives nvim; pipe-pane → logs/
cockpit.py: same CLI; tmux verbs target `-L cockpit`; layout verbs go through the bridge socket
```

Steer path unchanged (`send-keys` into the inner session); status unchanged (hooks write `agents/*.json`, `fs_event` redraws the fleet buffer); views become mksession snapshots per tabpage.

**Effort:** launcher (~200 lines, `mux.sh` as model) + `lua/cockpit/` (views/tabpages, terminal attach wrappers with CSI-u shims, prefix-less dispatcher, statusline, `fs_event` fleet buffer, oil-style agents buffer) ≈ 1.5–3 weeks, vs ≈ 1 week for v4's tmux chrome. `cockpit.py` changes are small (`-L cockpit`, `--socket`).

**Risks:** CSI-u shims per agent (Claude Code Shift+Enter); libvterm CPU with many visible terminals (keep ≤4 visible, low scrollback); 0.12 detach edge cases (dangling servers, reconnect lag); `<Esc>` discipline in terminal mode; every dashboard is Lua you maintain; two "hoods" if the outer tmux stays (pick one leader — Space in nvim makes Space-hold/Karabiner unnecessary).

## Verdict

**Viable now — with the inner-tmux (or Herdr) durability engine; not viable as the process host.** Nvim 0.12 makes "nvim as the hood" real for the UI half (detach/reattach, splits via RPC, floats, one leader), `mux` proves the shape in daily use, and the plugin ecosystem has already solved fs_event dashboards and agent-terminal rails. The half nvim cannot do — keeping agents alive across its own crash, forwarding modern key encodings, cheap rendering of many busy terminals — is exactly what the inner tmux server does, and the cockpit CLI keeps working against it unchanged. Recommendation: **keep v4's CLI and inner tmux; make "nvim hood" a second front-end** (`cockpit up --hood nvim`) behind a `COCKPIT=1` guard in the existing LazyVim config, and let the two front-ends compete for a month before deleting one.
