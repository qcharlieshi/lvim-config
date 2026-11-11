# tmux as an agent runtime: research for the cockpit design review

Date: 2026-08-28
Scope: a meta-harness that runs Claude Code agents in a dedicated tmux server (`tmux -L cockpit`) and shows each agent in a Neovim `:terminal` running `tmux -L cockpit attach -t <target>`.

---

## 1. tmux attach semantics: session vs window vs pane, grouped sessions, window-size

### Clients attach to sessions, never to windows or panes

In tmux the client object holds a pointer to a *session*; the "current window" is a property of the session (`s->curw`), and the "active pane" is a property of the window. There is no per-client current window. `attach-session -t sess:win.pane` does **not** narrow what the client sees; it *mutates the session* so every client on it changes view. From `cmd-attach-session.c`:

```c
if (tflag != NULL && tflag[strcspn(tflag, ":.")] != '\0') {
    type = CMD_FIND_PANE;          /* target has ':' or '.' -> resolve a pane */
    ...
}
...
if (wl != NULL) {
    if (wp != NULL)
        window_set_active_pane(wp->window, wp, 1);   /* window-level state */
    session_set_current(s, wl);                      /* session-level state */
    ...
}
```
Source: https://github.com/tmux/tmux/blob/d7f59ecc/cmd-attach-session.c

So two nvim terminals attached to the same session with different `-t sess:0` / `-t sess:1` targets will both end up showing whichever window was selected *last*, and any `select-window` in one affects the other. This is the fundamental reason "window-per-agent in one session, one attach per window" cannot work.

### Grouped sessions (`new-session -t <group>`)

Man page (`new-session`, `-t`): "Sessions in the same group share the same set of windows - new windows are linked to all sessions in the group and any windows closed removed from all sessions. **The current and previous window and any session options remain independent** and any session in a group may be killed without affecting the others."
Source: https://man.openbsd.org/man1/tmux.1 (also https://man7.org/linux/man-pages/man1/tmux.1.html)

`-n` and a shell command are invalid with `-t` (the group already has windows). This gives each *viewer* an independent current window over a shared window set: N grouped sessions, each attached by one nvim terminal, each parked on a different window. It works, but it is a viewer-side trick layered on a single "real" session, and it has costs described below.

### `window-size` when clients of different sizes attach

Window option `window-size largest | smallest | manual | latest` (default `latest` since 3.2, `smallest` earlier): "'latest' uses the size of the most recently used client, 'largest' the largest client, 'smallest' the smallest client and 'manual' a size set by the 'resize-window' command." `aggressive-resize` (default off): "When 'window-size' is 'smallest', whether the maximum size of a window is the smallest attached session where it is the current window ('on') or the smallest session it is linked to ('off')."
Source: https://github.com/tmux/tmux/blob/d7f59ecc/options-table.c ; https://unix.stackexchange.com/questions/209981/tmux-doesnt-resize-with-terminal-window

Consequences for grouped sessions: a window linked into N grouped sessions is sized against *all* clients attached to any of those sessions (or, with `smallest`+`aggressive-resize on`, only those where it is current). Because Claude Code's Ink TUI re-lays-out on every SIGWINCH, a window shared across viewers of different sizes will flap, or (with `latest`) resize whenever the user focuses a different nvim split. Only when each window has exactly one attached client at a time is sizing stable. tmux also injects control sequences on attach that Claude Squad had to filter ("nuke the first stdin bytes ... 0;95;0c or ]10;rgb...") — one more reason to avoid repeated attach/detach churn (https://github.com/smtg-ai/claude-squad/blob/a4ab6988/session/tmux/tmux.go).

### Conclusion: topology

**Session-per-agent on the dedicated `-L cockpit` server.** Each agent gets `tmux -L cockpit new-session -d -s <agent> -c <dir> claude ...`; each nvim `:terminal` runs `tmux -L cockpit attach -t =<agent>` (use `=` for exact-match, since `-t name` is a prefix match — claude-squad hit this). One client per session means:
- the "current window" problem disappears (each session has one window),
- `window-size` is trivially the one attached client, no flapping,
- kill/restart/log per agent are plain `kill-session`/`pipe-pane -t <agent>`,
- `has-session -t =<agent>` is a clean liveness probe.

Grouped sessions are the fallback only if you genuinely need a *shared* window set (e.g. one "team" session with windows the user can also browse in a raw tmux client). Do not use a single session with window-per-agent and per-window attach targets: the source above shows it cannot give each nvim terminal a different window.

This matches what every tmux-native orchestrator surveyed below does (claude-squad, agent-deck, OpenRig, agent-manager, ccmux-skzv all use session-per-agent; Tmux-Orchestrator and Batty use window/pane-per-agent but only because a *human* views one tmux client at a time).

---

## 2. Nested-attach check only compares ttys on the same server

The refusal `sessions should be nested with care, unset $TMUX to force` is produced in `cmd-attach-session.c` and `cmd-new-session.c` when `server_client_check_nested(c)` returns 1. That function (server-client.c) is:

```c
/* Check if this client is inside this server. */
int
server_client_check_nested(struct client *c)
{
    struct environ_entry *envent;
    struct window_pane   *wp;

    envent = environ_find(c->environ, "TMUX");
    if (envent == NULL || *envent->value == '\0')
        return (0);

    RB_FOREACH(wp, window_pane_tree, &all_window_panes) {
        if (strcmp(wp->tty, c->ttyname) == 0)
            return (1);
    }
    return (0);
}
```
Source: https://github.com/tmux/tmux/blob/d7f59ecc/server-client.c

Two conditions must both hold: `$TMUX` is set in the connecting client's environment **and** the client's tty is the pty of some pane *on this server* (`all_window_panes` is the server-local pane tree). Historically the check compared socket paths; commit 6b21296 ("Move the nested check from client to server and compare the client tty ... to the pane pty names instead of comparing socket paths. This means that `new -d` will work without unsetting $TMUX") introduced the current behavior (https://git.yumc.pw/circlecloud/tmux/commit/6b2129696fbefe44d0adce1f2a11b4ae477cd07e).

Implication: from a shell inside the user's *default* tmux, `tmux -L cockpit attach -t agent1` connects to a different server; that server has no pane whose pty equals the caller's tty, so the check returns 0 and the attach succeeds with `$TMUX` still set. When the attach runs inside an nvim `:terminal` the client's tty is nvim's job pty, which is not a pane pty on *either* server, so it is fine even if nvim itself lives in the default tmux. (`new-session` applies the same check only when creating an attached client; `new-session -d` from the harness is unaffected.)

One caveat: `$TMUX` inherited by the *agent* process (the `claude` inside the cockpit pane) will point at the cockpit socket, which is what you want — Claude Code uses `$TMUX` to decide to DCS-wrap OSC 52 (section 5). Do not `unset TMUX` in the agent's environment.

---

## 3. How existing tmux-based orchestrators do it

| Project | Topology | Status detection | Prompt injection | Notes |
|---|---|---|---|---|
| **claude-squad** (smtg-ai) | Session per instance (`tmux new-session -d -s claudesquad_<title> -c <worktree> claude`); the TUI attaches by spawning `tmux attach-session` inside its own PTY. | Polls `capture-pane -p -e -J`, SHA-256 hashes content; changed hash = Running, unchanged = Ready; `hasPrompt` = substring `"No, and tell Claude what to do differently"`. AutoYes just writes `\r`. | Writes raw bytes to the attach PTY, `sleep 100ms`, then `\r`. | Issue #266: prompt sent before CLI is in raw mode is *lost*; proposed fix is readiness polling on pane content. https://github.com/smtg-ai/claude-squad/blob/a4ab6988/session/tmux/tmux.go , https://github.com/smtg-ai/claude-squad/issues/266 |
| **Tmux-Orchestrator** (Jedward23) | One session per project, window per agent (`project:0` PM, `project:1` dev...). Human-viewed. | `tmux capture-pane -t session:0 -p \| tail -50` read by an LLM. | `send-claude-message.sh`: `send-keys -t $WINDOW "$MESSAGE"; sleep 0.5; send-keys Enter`. CLAUDE.md: "the critical 0.5s delay between message and Enter". | https://github.com/Jedward23/Tmux-Orchestrator/blob/main/send-claude-message.sh |
| **agent-deck** (asheshgoplani) | Session per agent on its **own tmux server** (`tmux -L agent-deck`, socket `$TMUX_TMPDIR/tmux-<uid>/agent-deck`) "so it never touches your interactive tmux's config, bindings, or sessions". | Hook fast path first (Claude `UserPromptSubmit`->running, `Stop`->waiting via a status-file watcher), then `capture-pane` content sniffing fallback (`internal/tmux/detector.go`, `patterns.go`: "esc interrupt", spinner glyphs, Braille spinner in OSC pane title). Own maintainers note the pane heuristic "false-positives to idle during tool calls and thinking pauses". | `session send` with delivery verification; v1.11 made only `delivery: submitted` exit 0. Issue #1978: mid-turn sends are *queued* by Claude Code ("Press up to edit queued messages") and were misreported as failed. | https://github.com/asheshgoplani/agent-deck , https://github.com/asheshgoplani/agent-deck/issues/1978 , https://github.com/asheshgoplani/agent-deck/issues/1614 |
| **ccmux** (epilande) | Discovers agents already running in your panes; `ccmux spawn` opens a new window or split. Daemon + SSE. | Claude Code hooks installed in `~/.claude/settings.json`: `ccmux-session-start.sh`, `ccmux-session-end.sh`, `ccmux-state-notify.sh` (on `idle_prompt` / `permission_prompt` Notification). | `ccmux invoke` for one-shot turns; `ccmux handoff` moves text between sessions. | https://github.com/epilande/ccmux |
| **ccmux** (skzv) | tmux session manager for agents; session per project/agent, cross-device over tailnet. | Daemon state detection "active / idle / needs_input" per agent. | Resumes with `claude --resume <id>`. | https://github.com/skzv/ccmux |
| **OpenRig** (mvschwarz) | "Every agent runs in a tmux session you can attach to" (session per seat); daemon + SQLite + MCP. | Hook-primary (`PermissionRequest`), capture-pane fallback ("12-line trailing-content scan + 15-second send-readiness freshness"). | `rig send`, with a guard: refuses when target pane is at an interactive picker (`needs_input`), advise-and-send otherwise (0.4.3 reversed an over-strict deny-by-default). Has "wait-for-idle send mode". | https://github.com/mvschwarz/openrig , https://github.com/mvschwarz/openrig/releases/tag/v0.4.1 , v0.4.3 |
| **Batty** (battysh) | One team session, **pane per role**; engineers in worktrees. Rust, tmux >= 3.2. | "watches for idle/completed states"; file-based Maildir inbox routing. | Inbox delivery into the pane. | https://github.com/battysh/batty |
| **agent-dashboard** (bjornjee) | Agents in tmux panes; dashboard is a control plane over `capture-pane`. | Claude Code plugin hooks (`agent-state-fast.js`, `agent-state-reporter.js`) write per-agent JSON; **parses transcript JSONL** for state (permission/plan/question/running/idle_prompt/done/pr/merged), subagent tree, plans, mermaid. | Quick replies, numbered options, free-text `r`. | https://github.com/bjornjee/agent-dashboard |
| **agent-manager** (jwbannister) | Session per agent. | Claude Code launched with a generated `--settings` file whose hooks write `working/waiting/finished/idle` to a per-session status file; pane regex still "upgrades" it because hooks cannot see a plain-text question, Esc interrupt, or error line. | `space` sends a prompt into the pane. | https://github.com/jwbannister/agent-manager , https://agent-manager.dev/docs/status/ |
| **agent-of-empires** | Session per agent, Rust. | Hooks primary; `detect_claude_status` pane fallback strips ANSI then matches "esc to interrupt", live token counter, spinner+verb, "Waiting for N background agent". Explicit reconciler because Esc-interrupt fires neither `Stop` nor `idle_prompt`, leaving the hook file stuck on `running`. | `load-buffer`/`paste-buffer` then Enter after `send_keys_enter_delay_ms`; PR #3355 raised Claude's delay 0->150 ms. | https://github.com/agent-of-empires/agent-of-empires/blob/main/src/tmux/status_detection.rs , https://github.com/agent-of-empires/agent-of-empires/pull/3355 |
| **Crystal** (stravu) | Not tmux: Electron + node-pty + Claude Code SDK per worktree. Deprecated Feb 2026 in favour of Nimbalyst. | SDK message stream. | SDK. | https://github.com/stravu/crystal/blob/main/CLAUDE.md |
| Small tmux status plugins: **tmux-claude-status** (farnots), **tmux-agent** (yaodong), **tmux-claude-hooks-status**, **claude-session-manager** (pablobfonseca) | Discover `claude` panes on the user's server. | All hook-driven, writing tmux user options (`@claude_pane_status`) or a registry keyed by `$TMUX_PANE`; regex scraping only as fallback. tmux-claude-status notes: only `UserPromptSubmit` should move waiting->working; `PreToolUse/PostToolUse` arrive out of order after `Stop` because hooks run in parallel; use `Notification permission_prompt`, not `PermissionRequest`, for need-input. | n/a | https://github.com/farnots/tmux-claude-status , https://github.com/yaodong/tmux-agent |

### Consensus on status detection

1. Hooks are authoritative for turn boundaries: `UserPromptSubmit` -> working, `Stop` -> idle, `Notification(permission_prompt|idle_prompt)` -> needs input, `StopFailure` -> error. Claude Code hook input includes `transcript_path`, `session_id`, and `cwd`; hooks receive JSON on stdin and run without a controlling tty. Docs: https://code.claude.com/docs/en/hooks , https://code.claude.com/docs/en/hooks-guide
2. Known hook blind spots (every project rediscovers them): Esc-interrupt fires no `Stop`; Esc-cancelling a permission fires no clearing event; plain-text questions ending a turn look like `Stop`; a `Stop` is not guaranteed after every tool batch (coding-agents-tmux PR #15). So everyone keeps a `capture-pane` heuristic as a tie-breaker, and the better ones (agent-of-empires, agent-manager) only let the pane *downgrade* a hook state.
3. A regex-free "pane hash unchanged for N seconds -> idle" safety net (Composio agent-orchestrator RFC #1941) is cheaper and less brittle than string patterns; it needs the spinner to be off (note the Claude status footer animates while working, so unchanged hash reliably means not-working). https://github.com/ComposioHQ/agent-orchestrator/issues/1941
4. Transcript JSONL (`~/.claude/projects/<slug>/<session>.jsonl`) is what agent-dashboard and tmux-agent parse for rich state (`AskUserQuestion` tool_use = waiting on human; `system/api_error` = blocked). Anthropic's docs say the format "is internal to Claude Code and changes between versions" and recommend hooks' `transcript_path` / `last_assistant_message` instead. https://code.claude.com/docs/en/sessions , https://github.com/anthropics/claude-code/issues/53516

### Consensus on prompt injection and the Ink pitfalls

- **Never chain text and Enter in one `send-keys`.** Claude Code treats a fast text+Enter as a single paste/multi-line input and does not submit (openclaw docs PR #7737; macf issue #55 where Enter inside the same read batch "inserts a newline instead of submitting"). https://github.com/openclaw/openclaw/pull/7737 , https://github.com/groundnuty/macf/issues/55
- **Root cause is Claude Code's paste coalescer**: `PASTE_COMPLETION_TIMEOUT_MS = 100` in `usePasteHandler.ts` — a bracketed paste starts a 100 ms quiet timer and *any Enter that arrives inside the window is appended to the paste* instead of submitting. Hence the "[Pasted text #1 +N lines]" placeholder sitting unsubmitted. Agent-of-empires fixed it with a 150 ms delay; mulmoterminal uses 150 ms; Tmux-Orchestrator uses 500 ms; claude-squad 100 ms (marginal). https://github.com/agent-of-empires/agent-of-empires/pull/3355 , https://github.com/receptron/mulmoterminal/blob/main/server/session/draft-injection.ts
- **Fixed sleeps still race on slow/remote hosts.** claude-session-driver #20: 0.1 s was insufficient over SSH; fix was to re-send Enter until the `UserPromptSubmit` hook event proves acceptance, and fail loudly otherwise. Composio agent-orchestrator #564 hit the same with 300 ms after `load-buffer`+`paste-buffer`, moved to bracketed paste + adaptive retry. https://github.com/obra/claude-session-driver/issues/20 , https://github.com/ComposioHQ/agent-orchestrator/issues/564
- **Use bracketed paste for multi-line text**: either `tmux load-buffer -b x - <<<"$msg"; tmux paste-buffer -b x -p -d -t <target>` (`-p` wraps in `\e[200~ ... \e[201~` when the app has requested bracketed paste) or `send-keys -l` with the wrapper bytes yourself. Claude Code renders it as one `[Pasted text]` block. Strip C0/C1 control bytes and especially an embedded `\e[201~` from untrusted text before pasting (mulmoterminal does this).
- **Send-readiness**: text written before the TUI enters raw mode is discarded (claude-squad #266) or echoed to scrollback (mulmoterminal). Wait for an input-ready marker ("shift+tab to cycle" / `❯` footer) or for `SessionStart` hook before the first injection; or pass the first prompt as the `claude "<prompt>"` positional arg (agent-relay does this, but note tmux `new-session` command-length limits for large prompts — write a launcher script instead).
- **Mid-turn sends are queued**, not dropped (Claude Code shows "Press up to edit queued messages"); do not treat "no turn started" as failure (agent-deck #1978).
- Prefer `C-u` before typing to clear stale composer text (macf helper) and target panes by `%id` or `=exact-name`.

---

## 4. `pipe-pane` logs of a full-screen Ink TUI

- `pipe-pane` copies the raw pty output stream, escape sequences and all; it has no strip flag. For a fullscreen/alt-screen Ink app that redraws the whole frame on every tick, the log is a stream of cursor-movement and erase sequences and is unreadable as text. tmux issue #3005 and the tmux-logging plugin both fall back to `ansifilter` (C, handles CSI/OSC) or a `sed` regex; `ansi2txt | col -b` (colorized-logs) also works. https://github.com/tmux/tmux/issues/3005 , https://github.com/tmux-plugins/tmux-logging/blob/master/README.md , https://github.com/tmux-plugins/tmux-logging/issues/67
- Even after stripping colour, cursor-addressed redraws produce repeated partial frames with no line structure ("`sed` doesn't process a line until newline is seen, so we miss the last line"). Nobody in the agent-orchestrator space uses `pipe-pane` as the *semantic* log; hao-ai-lab/research-agent surveyed the options and concluded: `pipe-pane` raw for a debug stream, `ansifilter` tiered fallback, and `capture-pane -p` (tmux's own VT parser renders clean plaintext) for snapshots. https://github.com/hao-ai-lab/research-agent/issues/245
- `asciinema rec` (or `script`) is the right tool if you want a *replayable* recording of the TUI; a tmux-logging user switched to an asciinema wrapper for exactly this reason. It still is not a greppable log.
- Consensus for agents: the human-readable log is the **transcript JSONL** (`~/.claude/projects/<slug>/<session_id>.jsonl`; path also delivered as `transcript_path` in every hook payload) plus hook-emitted events; `capture-pane -p -S -N` for "what does the screen say right now". Use `pipe-pane -o 'cat >> raw.log'` only as a crash-forensics stream, and view it with `ansifilter` or replay it through a terminal.

---

## 5. Passthrough through nvim `:terminal` + inner tmux

### Keyboard: Shift+Enter / CSI-u / kitty protocol

- Claude Code (2.1.0+) speaks the kitty keyboard protocol on supported terminals, but **inside tmux `$TERM` is `tmux-256color`/`xterm-256color` and Claude Code does not emit the kitty activation sequence**, so with tmux's default `extended-keys on` (request-based) Shift+Enter is never forwarded. Anthropic's tmux guidance: `set -g allow-passthrough on`, `set -s extended-keys on`, `set -as terminal-features 'xterm*:extkeys'`. https://code.claude.com/docs/en/terminal-config ; https://github.com/anthropics/claude-code/issues/26629
- Field reports say `on` is insufficient and you need `extended-keys always` plus `extended-keys-format csi-u` (tmux >= 3.5; 3.6a recommended, 3.5 had CSI-u bugs), with `terminal-features` matching the *outer* `$TERM` glob so tmux requests extended keys from its own host. https://roman.pt/posts/terminal-setup/ , https://blog.fsck.com/agent-blog/2026/02/26/terminal-keyboard-protocol/ , https://github.com/anthropics/claude-code/issues/1758
- **Neovim `:terminal` is the real blocker**: nvim's own TUI *decodes* CSI-u/modifyOtherKeys from the outer terminal (into `<S-CR>`, `<A-CR>`) but libvterm's keyboard encoder does **not** re-emit CSI-u to the child pty, so the inner tmux never sees `\e[13;2u` regardless of its config. Keys with legacy encodings (Shift+Tab `\e[Z`, Ctrl+arrows) still work. Workaround used by sidekick.nvim (issue #289): buffer-local terminal-mode maps that write the raw bytes with `nvim_chan_send(job, "\x1b[13;2u")`; sidekick also switched its context-send path from `nvim_put()` to `nvim_chan_send()` because `nvim_put` mangled bytes that looked like CSI fragments. https://github.com/folke/sidekick.nvim/issues/289
- Cheap universal fallback: Ctrl+J (`0x0a`) inserts a newline in Claude Code everywhere; Ghostty/iTerm `shift+enter=text:\x0a` binding also works through nvim+tmux. Avoid the old `/terminal-setup` iTerm binding (`\n` remap) since it breaks Shift+Enter for nvim itself (claude-code #614).

### Paste (text and images)

- Neovim <= 0.11.x fragments a large streamed paste into a `\e[200~..\e[201~` pair *per ~4 KB chunk*; Claude Code then shows many `[Pasted text #N]` blocks or garbles. Fixed in Neovim 0.12+ (PR #39152); claudecode.nvim ships a `vim.paste` coalescing shim for older versions. https://github.com/neovim/neovim/issues/39110 , https://github.com/coder/claudecode.nvim/blob/8ec32127/fixtures/paste-repro/init.lua
- Image paste does not work inside tmux at all: tmux only forwards text from the clipboard, and Claude Code reads images via `pbpaste`/`xclip`-style helpers racing on `/dev/tty`. Inside nvim `:terminal` there is no image path either. Save to file and reference it, or paste into a non-nvim terminal. https://github.com/anthropics/claude-code/issues/25672 , https://github.com/anthropics/claude-code/issues/42712
- A tmux-specific newline-dropping paste bug (#52126/#51667) was fixed in Claude Code 2.1.119.

### Clipboard out (OSC 52)

- When `$TMUX` is set, Claude Code wraps OSC 52 in DCS passthrough (`\ePtmux;\e\e]52;c;...\a\e\\`). tmux >= 3.3 drops that unless `allow-passthrough on` (visible panes) or `all` (also hidden panes). `set-clipboard`/`terminal-features clipboard` are irrelevant to this path. https://max.nardit.com/articles/osc52-clipboard-xterm-tmux , https://github.com/anthropics/claude-code/issues/38944
- After the inner tmux unwraps it, the raw OSC 52 hits nvim's `:terminal`, and **Neovim 0.11+ handles OSC 52 *write* natively** via the configured clipboard provider (query/paste deliberately unsupported; no `TermRequest` is emitted for it). So `/copy` should work end-to-end with `allow-passthrough` on. https://neovim.io/doc/user/terminal/#terminal-osc52 , https://neovim.io/doc/user/news-0.11/
- Other passthrough (OSC 9/777 notifications, OSC 0/2 title, progress bar OSC 9;4) also requires `allow-passthrough`; nvim surfaces OSC/DCS as `TermRequest` autocommands (0.10+) so the cockpit can turn a Claude Code desktop-notification sequence into an nvim notification. https://neovim.io/doc/user/news-0.10/

### Colour and redraw

- nvim's `:terminal` is libvterm-based and renders 24-bit colour when `termguicolors` is set (auto-enabled on truecolor hosts since 0.10). Set the inner tmux to `set -g default-terminal tmux-256color` and `set -as terminal-features ',xterm-256color:RGB'` so Claude Code's truecolor SGRs pass through. Nvim sets `TERM=xterm-256color` for terminal jobs, which the `xterm*` globs above match. https://neovim.io/doc/user/tui/ , https://github.com/neovim/neovim/pull/26407
- nvim `:terminal` now implements synchronized output (mode 2026) — see `synchronized_output` in `src/nvim/terminal.c` — which reduces Ink flicker if the inner tmux forwards it; tmux forwards DECSET 2026 only to terminals declaring the `sync` feature (`terminal-features 'xterm*:sync'`). https://github.com/neovim/neovim/blob/master/src/nvim/terminal.c
- Claude Code docs note "Display flickers or scrollback jumps" as a known tmux symptom; keeping one client per window (section 1) avoids resize-driven redraw storms.

### Recommended inner-tmux (`-L cockpit`) config

```tmux
# ~/.config/cockpit/tmux.conf  (loaded with: tmux -L cockpit -f <this> ...)
set -g default-terminal "tmux-256color"
set -as terminal-features ',xterm*:RGB:extkeys:sync:clipboard'
set -s  extended-keys always
set -s  extended-keys-format csi-u
set -g  allow-passthrough all      # agents live in windows nvim may not be showing
set -g  set-clipboard on
set -g  history-limit 50000
set -g  status off                 # nvim owns the chrome
set -g  window-size latest
set -g  escape-time 10
set -g  focus-events on
set -g  mouse on
```

---

## Implications for the cockpit spec

1. **Topology**: one tmux *session* per agent on the `-L cockpit` server, one window, one pane; each nvim `:terminal` runs `tmux -L cockpit attach -t =<agent>`. Never rely on `attach -t sess:win.pane` to isolate a view — it changes the session's current window for all clients. Use grouped sessions only if a shared window set is a hard requirement.
2. **Nesting**: no `unset TMUX` gymnastics are needed; the nested check compares ttys against panes on the *same* server. Keep `$TMUX` intact for the agent so Claude Code DCS-wraps OSC 52.
3. **Status model**: hooks first (`UserPromptSubmit`, `Stop`, `StopFailure`, `Notification[permission_prompt|idle_prompt]`, `SessionStart/End`) written to a per-agent state file or tmux user option (`set -p @cockpit_status`); pane-hash "no motion for N s -> idle" as the only regex-free downgrade; optional `capture-pane` string checks strictly to *downgrade* hook `running` (Esc-interrupt banner, permission menu). Install hooks via a generated `--settings` file per agent rather than editing `~/.claude/settings.json`.
4. **Prompt injection**: wait for readiness (SessionStart hook or input-box marker), `C-u`, then `load-buffer`+`paste-buffer -p -d`, wait >= 150 ms (Claude's 100 ms paste-coalesce window), then `send-keys Enter` as a separate command; confirm via `UserPromptSubmit` hook and retry Enter with backoff; treat "queued during a turn" as success. Sanitize control bytes and `\e[201~` in the payload.
5. **Logging**: per-agent transcript JSONL is the log of record (path from hook payload `transcript_path`); `capture-pane -p` for screen snapshots; `pipe-pane` raw stream only for forensics, viewed through `ansifilter`/asciinema. Do not attempt to parse `pipe-pane` output for state.
6. **Terminal fidelity inside nvim**: ship the inner-tmux config above; add terminal-mode maps in the cockpit buffers sending `\x1b[13;2u` for `<S-CR>` (and `\x1b[13;3u` for `<A-CR>`) via `nvim_chan_send`; require Neovim 0.12+ or install the paste-coalescing `vim.paste` shim; document that image paste is unavailable in this path; wire `TermRequest` to surface OSC 9/777 notifications.
7. **Size stability**: because each session has exactly one client, `window-size latest` is safe. If you later add a "raw tmux" viewer for the same agent, expect Ink to re-layout on every focus change unless both clients are the same size.
