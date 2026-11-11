# Rust TUI as the single hood — wrapping tmux with custom panels and a vim layer

**Date:** 2026-08-28 · **Question:** can a ratatui app that *wraps tmux* (tmux keeps hosting agents + nvim; the TUI renders/arranges via control mode), adds custom panels (fleet, lineage, steer queue, metrics), and carries a vim modal layer be the cockpit's one hood — "vim + tmux under one hood"? · **Method:** Exa search/crawl, `gh api` repo stats; no code run. Complements [architecture-alternatives](2026-08-28-cockpit-architecture-alternatives.md); not repeated here.

## 1. bosun — the existing "ratatui over tmux" reference

[yetidevworks/bosun](https://github.com/yetidevworks/bosun) (43★, Rust, pushed 2026-08-24, ~30 commits, Homebrew tap; a from-scratch rewrite of agent-deck). Architecture, from its README:

- **tmux is the source of truth.** Push notifications via control mode (`tmux -C`); no database; multiple bosun instances coexist because they all read one tmux server. Runs its sessions on a dedicated socket `tmux -L bosun`, partly so Claude's macOS Keychain auth lineage flows through bosun's process tree.
- **Actor model**: one task owns tmux I/O, one owns `AppState`; no shared mutexes on the render path.
- **Rendering the selected pane**: 2.0 replaced 1 fps `capture-pane` snapshot polling with a *real embedded PTY* (`portable-pty` + `vt100` + `tui-term`), "parser-primed on switch" to avoid scrollback replay. Non-focused sessions still get status glyphs at ~5 Hz from pane captures (prompt-box detection rather than substring scans).
- **Input routing** into the embed needed explicit work: DECCKM application cursor keys, bracketed-paste forwarding, SGR 1006 mouse, modifyOtherKeys (Shift+Enter, Ctrl+Backspace). That list is the "multiplexer tax" in miniature.
- **Persistence trick**: `@bosun_container_id` tmux user option so a sidebar "container" (tabbed sessions) survives a tmux server restart.
- Extras: focus-in-place (`s`), sections, per-session status bar set with `set-option -t` (never global), 15 themes, self-update.

Take-away: the viable Rust shape is exactly bosun's — *a ratatui client of tmux*, not a replacement. It does one embedded pane; N live embeds would multiply the PTY/vt100 cost and the input-fidelity surface.

**Other "tmux as backend" clients**: [tmuxy](https://github.com/flplima/tmuxy) (81★, pushed 2026-08-26) — Rust control-mode backend streaming state to a web/Tauri front end ("the missing tmux GUI… AI agents already love tmux, why create a new tool"); [tmux-integrated](https://deepwiki.com/pcassidy75/tmux-integrated/2.3-tmuxgateway-control-mode-protocol-parser) (VS Code, TS gateway modelled on iTerm2's); [tmux-control-mode-js](https://github.com/promptctl/tmux-control-mode-js). All confirm the pattern is well-trodden and that the hard part is the protocol layer, not the UI.

## 2. Embedding terminals in ratatui

- [tui-term](https://docs.rs/tui-term) (229★, pushed 2026-08-01): `vt100` is the *only* parser backend; widget renders a `vt100::Screen` into the ratatui buffer; threaded/channel/tokio I/O models. It is a display of a grid, not a terminal emulator — features live or die in `vt100`.
- Fidelity gaps you inherit (from [terminfo.dev](https://terminfo.dev/multiplexers) and [FrankenTUI's matrix](https://docs.frankentui.com/reference/terminal-compatibility)): kitty keyboard protocol is not relayed; DEC 2026 synchronized output must be batched by *you* or embedded TUIs tear/blank (orcatui's lesson); OSC 52/8/133 need passthrough; the outer tmux already downgrades these, so an embed inside a TUI inside tmux is two layers of degradation.
- nvim inside an embed: workable for viewing (true color yes via vt100 SGR; undercurl/colored underlines and kitty-keys unlikely), but you would be running nvim inside a PTY inside a TUI inside tmux — three redraw paths — to get a widget tmux already gives you natively. Not worth it; keep nvim as a real tmux pane.
- Performance: one live embed (bosun) is fine; several 60 fps embeds is what orcatui/Shin-sibainu-ccmux built daemons and per-pane threads for ([psmux commit](https://github.com/psmux/psmux/commit/78cebea2891f0e77d470bb874d8d4cee972965bf) shows the kind of write-queue backpressure bug you meet).

## 3. Vim modal layer crates

- [modalkit](https://github.com/ulyssa/modalkit) (92★, pushed 2026-08-26; powers iamb): a `ModalMachine` with Vim/Emacs binding sets over `TerminalKey`, producing `Action<I: ApplicationInfo>`. Crucially `Action::Application(I::Action)` lets you define your own action enum — [editor-types' own docs](https://docs.rs/editor-types/latest/src/editor_types/application.rs.html) use a *code-review* example (`Comment(ReviewId, PathBuf, usize, String)`, `ExpandHunk(Count)`, merge). `EditContext` carries count, register, mark specifiers; `RepeatType` gives `.`; `CommandBar`/`Prompt` give `:`; `Register` includes named/macro registers; `show_mode()`/`show_dialog()` exist for a which-key-ish surface.
- Caveat: counts/registers/marks/motions are typed for *text* (buffers, cursors, `Mark` is an editor mark). Binding them to pane/agent/document targets means implementing `ApplicationAction` for your enum and ignoring the editor half — feasible (iamb does it for rooms), but you own the target-resolution semantics; modalkit gives grammar, not tmux motions.
- tui-textarea's vim mode and edtui are text-widget bindings only — irrelevant to whole-app modality.
- Effort to a credible vim layer (Normal/Review/Insert, counts, `m`/`'` marks, `.` repeat, `:` with completion, `?` help): ~1–2 k LOC on modalkit; the grammar itself is the easy half, the *targets* (which pane is "next agent") are the same code the Python CLI needs anyway.

## 4. tmux control mode from Rust

- [libtmux-rs](https://github.com/libtmux/libtmux-rs): created **2026-08-15**, 1★, `0.1.0-alpha.6`, "API changes between releases… nothing is stable yet"; async, typed, control-mode transport, query layer, a `tmux-mcp` crate. Promising, not a foundation to depend on this quarter. `tmux_interface` (older, sync, command-builder) is stable but no control mode.
- Raw `tmux -C` is small: `%begin/%end/%error` blocks, `%output` (octal-escaped, may split UTF-8 across notifications → per-pane decoder), `%layout-change`, `%window-*`, `%session-changed` readiness gate, and 3.2+ flow control `%pause/%continue/%extended-output` + `refresh-client -A` and **format subscriptions** (`refresh-client -B` → `%subscription-changed`, push instead of polling formats). tmuxy-core and tmux-integrated both document a ~300-line parser + state aggregator; iTerm2's `TmuxGateway`/`TmuxLayoutParser` is the reference ([DeepWiki](https://deepwiki.com/gnachman/iTerm2/5.2-tmux-integration)).
- Known pain (iTerm2 wiki, tmux-integrated latency notes): in-band signaling means a dead tmux/ssh sends commands to the shell; race on reconnect (adopt existing windows vs create); title-echo loops; fragmented ESC sequences over high latency; resize storms need debouncing; `%pause` backpressure when a client can't drain output. All solved before, all yours to re-solve.
- Latency: control mode is one persistent connection — libtmux-rs measures 8 ms vs 168 ms per 6 commands over subprocess; `%output` streaming for N panes is fine *if* you either consume it or use flow control to pause panes you aren't rendering (tmux-control-mode-js's "idle pane suppression").

## 5. Meta-agent controllability and zellij

- Precedents for TUI + CLI twins: [yazi/ya](https://deepwiki.com/sxyazi/yazi/7-inter-process-communication) (first instance hosts a Unix-socket DDS server; `ya emit/pub/sub/exec`, JSON results); WezTerm `wezterm cli`; zellij `zellij action`; Helix's socket PR ([#13896](https://github.com/helix-editor/helix/pull/13896), unmerged). Pattern: the TUI listens on a socket, a thin CLI sends actions and prints JSON — i.e. the Rust hood must still ship a `cockpit` CLI, and every panel action must be an IPC verb or the agent can't do it.
- **Zellij as the ready-made hood** ([v0.45.1, 2026-08-28](https://github.com/zellij-org/zellij), 35k★): WASM plugins render custom panes and receive `PaneUpdate/TabUpdate/Key/Timer/FileSystem*` events, can open panes/tabs, write to panes, `reconfigure` keybinds, and take **pipes** from `zellij pipe` (CLI → plugin messaging); KDL layouts with `override-layout` at runtime; `list-panes --json`, `zellij subscribe` (streams rendered pane output as JSON), `--create-background` headless sessions, IDs returned on create; **session resurrection** built in (layout serialized every 1 s, resurrect via `attach`); a modal system (Normal/Pane/Tab/Resize/Scroll/Session/Locked) with an on-screen which-key-style bar that users describe as "feels a lot like which-key.nvim" ([Poppe](https://www.mauriciopoppe.com/notes/tmux-to-zellij/)).
  - Costs: nvim collisions require the "Unlock-First" preset or the zellij-autolock/zellij.vim timer hack ([tutorial](https://zellij.dev/tutorials/colliding-keybindings/), Poppe: "feels like a hack… trips up"); Alt-binds vanish in default locked mode ([#5217](https://github.com/zellij-org/zellij/issues/5217)); no `switch-client -l`, no `respawn-pane -k`, layout quirks; `new-pane` does not inherit the parent env; and **Claude Code Agent Teams assume tmux** — a [tmux shim](https://github.com/stanislc/zellij-claude-teams) exists to fake it, "fragile to Claude Code updates". Everything in the current spec that leans on tmux hooks/`pipe-pane`/`display-menu`/key tables would be re-expressed as WASM plugins.

## 6. Effort and risk

| Option | What you build | Estimate | Main risks |
|---|---|---|---|
| (a) bosun-style panel TUI *inside* a tmux pane | ratatui app reading `agents/*.json` + `git log`; fleet table, lineage graph, steer queue, metrics; drives tmux via subprocess/control mode; no embeds; optional modalkit for its own keys | 2–4 weeks, ~3–5 k LOC | second toolchain; duplicates `hwatch status --pretty` + `status.lua` until it clearly beats them |
| (b) full hood: ratatui client of tmux with vim layer | control-mode gateway + layout parser + state aggregator; N live embeds via tui-term; modalkit grammar with pane/agent/doc targets; socket IPC + `cockpit` CLI twin; format subscriptions | 3–6 months to parity with tmux chrome, ~15–25 k LOC (iTerm2's integration is many thousand lines alone) | you re-own iTerm2's race/latency/flow-control list; embed fidelity (kitty keys, 2026, OSC) degrades nvim and Claude Code TUIs; libtmux-rs alpha; single maintainer = you |
| (c) zellij + custom WASM plugins | fleet/lineage/steer plugins in Rust→WASM; KDL layouts; `zellij pipe` as the agent's control surface | 3–6 weeks for panels; migration of tmux config/sessionizer/hooks | nvim key collisions; Agent Teams tmux dependency (shim); loses tmux hooks/`pipe-pane`/popups; zellij's own modal system competes with a vim layer |

nvim's role: unchanged in (a); demoted to "a pane we render" in (b) (worst of the three for the editor); a normal pane in (c).

## Architecture sketch — the viable Rust option (a), extensible toward (b)

```
tmux server ──(tmux -C, one connection)──▶ cockpit-tui (ratatui, in pane %N of window 0)
   │  %layout-change / %window-* / %subscription-changed (@cockpit_* formats)      │
   │  no %output consumed (refresh-client -A pause all panes)                       │
   ├── agents (claude …) panes, nvim panes, lnav/hwatch panes  ◀── select-pane/send-keys/respawn-pane
   └── hooks → ~/.cockpit/<s>/agents/*.json ──(fs watch)──▶ cockpit-tui panels
cockpit CLI (Python today) ──unix socket JSON──▶ cockpit-tui (focus panel, filter, open doc, run action)
```

Rendering: ratatui draws *only* its panels; tmux draws everything else. Input: keys in the TUI pane go to modalkit → `CockpitAction` → tmux commands or CLI calls; Space-hold/`M-Space` key tables stay in tmux for everything outside the panel. IPC: the TUI hosts a socket; `cockpit ui <verb>` is the agent's and the keymap's shared path.

## Comparison

| Criterion | v4 tmux toolkit | (a) Rust panel in tmux | (b) Rust hood over tmux | (c) zellij + plugins | nvim as hood |
|---|---|---|---|---|---|
| Vim grammar fidelity | good (key tables; nvim for docs) | good inside panel; tmux elsewhere | best single grammar (modalkit) | zellij modes ≠ vim; collisions | best (it *is* vim) |
| Glanceability / custom panels | adequate (badges, `status --pretty`) | best-in-class panels, cheap | same | good (WASM panes) | very good (floats/buffers) |
| Durability / remote | tmux native | tmux native | tmux native (hood is a client) | zellij resurrection | UI yes, processes no |
| Composability (lnav/delta/gh) | native panes | native panes | embedded → degraded | native panes | `:terminal`, second-class |
| Meta-agent controllability | one surface (CLI) | CLI + one extra socket | CLI + socket for every panel action | `zellij action`/`pipe` | RPC bridge |
| Maintenance | lowest | +1 Rust crate | highest (protocol + embeds + IPC) | plugin toolchain + migration | Lua grows |
| Time to first useful | days | 2–4 wk | months | 3–6 wk | 1–2 wk |

## Verdict

**Not as the hood; yes as a panel.** A Rust TUI *wrapping* tmux is precisely bosun, and bosun's own evolution shows where it leads: one embedded PTY, a growing input-fidelity checklist, and tmux still doing the real work. Making it the single hood (b) means rebuilding iTerm2's control-mode integration plus terminal embedding, and it *worsens* the two things you care most about — nvim (now inside an embed) and agent controllability (every panel action needs an IPC twin). "Vim + tmux under one hood" is better achieved the other way round: keep tmux as the hood, make its key tables vim-shaped (v4 §5), and put the *rich panels* — fleet table, lineage graph, steer queue, metrics — in a single ratatui pane (option a) **only after** `status --pretty` + `status.lua` prove insufficient; modalkit is the right crate if that panel wants its own vim grammar. zellij is the one credible "Rust multiplexer with custom panes and a CLI" — but its nvim collisions, missing tmux primitives, and Claude Code's tmux dependency make it a migration with negative payoff today. Re-evaluate (b) only if libtmux-rs stabilizes *and* the cockpit outgrows tmux's format language for more than one panel.
