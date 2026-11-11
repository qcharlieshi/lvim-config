# Herdr headless under tmux — Research

**Date:** 2026-09-15 · **For:** cockpit v8 "headless cut" (tmux = outer shell, headless `herdr server` = worker runtime, attach-in-a-tmux-pane = escape hatch)
**Prior:** `2026-08-31-herdr-macos.md` (0.8.2 verified headless on aarch64-darwin; #2900 explicit-ids rule; #3217 CPU)

**Verdicts:** (a) headless server: **viable on ≥ 0.8.0** — the one blocking bug is fixed; (b) attach inside tmux: **viable as an escape hatch**, tolerated-not-supported upstream, with one real key-encoding risk; (c) lifecycle: **launchd user agent** (`RunAtLoad=true`, `KeepAlive=false`), `cockpit up` keeps an idempotent ensure.

## 1. Headless server — long-lived, clientless

- Headless is a first-class mode: `HeadlessServer` runs the full event loop with **virtual rendering** into memory, no raw mode/stdin; two sockets (`herdr.sock` JSON-RPC API, `herdr-client.sock` binary frames) ([DeepWiki: Headless Server](https://deepwiki.com/herdrdev/herdr/2.2-headless-server-and-client-protocol), [src/server/headless.rs](https://github.com/herdrdev/herdr/blob/ca1af383/src/server/headless.rs)). Docs bless it: "`herdr server` runs the headless server explicitly. Use it for supervised or service-style setups" ([CLI reference](https://herdr.dev/docs/cli-reference/)).
- **Agent detection is server-side and client-independent.** Terminal emulation, scrollback, OSC tracking, and screen-manifest detection stay current even when rendering is skipped ("Skipping the render does not drop output… agent detection all stay current" — [0.8 perf blog](https://herdr.dev/blog/ten-agents-three-clients-95-percent-less-cpu/)). Detection reads the bottom pane buffer, not a rendered viewport. For Claude Code, hooks report **session identity only**; `idle|working|blocked` comes from screen manifests ([0.8.2 agents doc](https://github.com/herdrdev/herdr/blob/master/docs/versions/0.8.2/website/src/content/docs/agents.mdx)).
- **The blocker was #2064, fixed in 0.8.0**: on ≤ 0.7.5 a crash-restarted clientless server never respawned `claude --resume` panes until a client attached (companion symptom: `agent list` shows idle agents that `agent prompt` calls `agent_not_found`, [#2065](https://github.com/herdrdev/herdr/issues/2065)). Changelog 0.8.0: "Headless servers now resume restored agent sessions without waiting for a TUI client to attach. (#2064)". nixpkgs ships 0.8.2 → covered. Pin ≥ 0.8.0 as a hard floor.
- **Sizing**: with no client, the shared runtime is 80×24 (`MIN_COLS×MIN_ROWS`); after a client detaches, PTYs keep their last attached size, and *new* headless layout uses a **configured fallback** ([config docs](https://herdr.dev/docs/configuration/)). Set the fallback (e.g. 200×50) so headless-spawned Claude panes render wide enough for stable screen detection.
- **CPU**: 0.8.0 removed the idle-render tax (sidebar spinner gone, hidden-pane output ≈ 0.2–0.6 CPU-points, idle "at the measurement floor" — perf blog; history in [#726](https://github.com/ogulcancelik/herdr/issues/726)). Detection still ticks 300/500 ms per pane server-side. #3217 (0.8.2 multi-agent CPU) was stabilized by disabling toasts + sound alerts — notification-path-bound, so a clientless server with notifications off should be largely immune; keep them off regardless. Watch [#2890](https://github.com/herdrdev/herdr/issues/2890) (typing latency scales with hidden panes' output) for the *attached* case.
- **Memory**: the big number is the agents themselves (5 idle Claude panes ≈ 3.1 GB RSS under the server, [#630](https://github.com/herdrdev/herdr/issues/630)); `pane release-agent` + deferred resume exists for parking; auto-hibernation is a requested feature.

## 2. Attach inside tmux — the escape hatch

- **Upstream stance**: "you can run herdr inside tmux if you want, but we can't support tmux-specific edge cases" ([#2135](https://github.com/herdrdev/herdr/issues/2135), closed not-planned). Works; unsupported edges.
- **Nested-launch guard poisoning**: starting a *tmux server from inside a herdr pane* leaks `HERDR_ENV` into tmux's server-global env; then `herdr` refuses to launch in any pane of that tmux server ([#2134](https://github.com/herdrdev/herdr/issues/2134)/#2135; PR #2137 improves this, release status unconfirmed). Our topology never does this — **rule: never start a tmux server from a herdr pane**. A clean outer tmux has no `HERDR_ENV`, so the guard doesn't fire for the attach client.
- **Clipboard**: herdr's OSC 52 writes need tmux passthrough ([#2054](https://github.com/herdrdev/herdr/issues/2054)); our `.tmux.conf` already sets `allow-passthrough on` (`set-clipboard on` is the belt-and-suspenders fix).
- **Keys — the real risk**: the Shift+Enter/CSI-u family ([#8](https://github.com/herdrdev/herdr/issues/8), #78, #81, #106, #1229, #1546, #1581, #1666). herdr re-encodes input against the inner pane's kitty-protocol state and historically dropped modified-Enter. Two local specifics: (1) our Ghostty config contains `keybind = shift+enter=text:\n` — exactly the Claude-Code-setup artifact behind #8 (herdr shipped a workaround; removing the keybind so Ghostty sends `\x1b[13;2u` is the clean fix); (2) one #8 datapoint found Shift+Enter *worked* under herdr-in-tmux because tmux normalizes the key. Net: degradation = "newline key flaky during hands-on attach" — annoying, not blocking (`\`+Enter works; steering goes through `agent.prompt` anyway).
- **Attach mechanics**: reattach streams the current frame via a diff encoder (no scrollback replay cost); multiple clients supported — one **foreground** client drives runtime size; `terminal session observe` gives read-only NDJSON frame streams for any number of watchers; one writable direct-attach owner per terminal (`--takeover`) ([persistence docs](https://herdr.dev/docs/persistence-remote/)). Detach is `ctrl+b q`; **`session stop` kills the panes** — document the difference ([gist](https://gist.github.com/lasergoat/7f92d7c4ba72ee9889bb4b1fd6cd287a)).
- Bonus: `terminal session observe/control` (NDJSON frames + `terminal.input`) is a scriptable alternative to a full client for `grab`-style peeking and even steering — no TUI in the loop.

## 3. Lifecycle: launchd vs `cockpit up`

- Herdr installs no LaunchAgent; brew users get `brew services start herdr`. For nix: a **home-manager `launchd.agents` entry** running `herdr server`, `RunAtLoad=true`, **`KeepAlive=false`** (with `true`, launchd resurrects the server after a deliberate stop, making clean shutdown impossible — gist). Double launch is safe: the second server prints "already running" and exits 1.
- **`PATH` in the plist must include claude's bin dir** — restore relaunches agents by bare name against the *launchd* environment; a missing dir ⇒ panes silently restore as empty shells (gist). `shell_mode="auto"` gives login shells inside panes, so pane PATH is fine; it's the *server's* env that matters for resume.
- `cockpit up` keeps an idempotent `herdr server` ensure (covers "launchd agent not installed" and post-`server stop`).
- Caveat: herdr SIGHUPs panes on stop, so zsh history since last clean exit is lost on server stop — cosmetic for worker panes.

## 4. Resurrection interplay

Clean separation, no double-restore: tmux-resurrect/continuum restores the outer tmux session (nvim window, shells); it does **not** restore `herdr session attach` clients unless added to `@resurrect-processes` — don't add it (an attach client racing the herdr server at login is noise; reattach on demand via `cockpit attach`). Herdr restores its own layout + `claude --resume` panes independently at `RunAtLoad`, before any cockpit command runs. Agents live only under herdr, so nothing restores twice; ordering between launchd and continuum is free.

## 5. Spec deltas (v8)

1. Pin herdr **≥ 0.8.0** (nixpkgs 0.8.2); note #2064 as the reason.
2. Server lifecycle = **launchd user agent** via home-manager (`RunAtLoad`, `KeepAlive=false`, PATH incl. claude's dir); `cockpit up` ensure stays as fallback.
3. herdr config: headless fallback size (~200×50), notifications/sounds off, `resume_agents_on_restore=true` (default), **`pane_history` off** (plaintext scrollback at rest; our logs live elsewhere).
4. New rule beside explicit-ids: **never start a tmux server from inside a herdr pane** (env-leak guard poisoning, #2134).
5. Escape-hatch doc: attach in a tmux pane is fine (`allow-passthrough` already on); known flaky key = modified Enter — remove Ghostty's `shift+enter=text:\n` keybind; `terminal session observe/control` as the scriptable alternative to attach.
6. Skill/operator note: detach (`ctrl+b q`) vs `session stop` (kills agents).
7. Resurrect: do not add herdr to `@resurrect-processes`.
