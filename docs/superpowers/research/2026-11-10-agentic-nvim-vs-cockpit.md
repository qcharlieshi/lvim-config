# agentic.nvim vs Cockpit (2026-11-10)

**Question:** [carlos-algms/agentic.nvim](https://github.com/carlos-algms/agentic.nvim) (read at `4750d6c`, 2026-11-08) is a mature nvim front-end for coding agents. What overlaps cockpit spec v8 and the built inbox, and what should cockpit adopt, borrow or ignore?

**Inputs:** agentic.nvim README, `lua/agentic/**` (~18.5k Lua lines excluding tests), `docs/adr/0001–0008`; cockpit spec v8 (`specs/2026-08-28-cockpit-design.md`), `lua/cockpit/inbox/`, `scripts/cockpit_inbox.py`. Nothing was installed or run, so every behaviour claim comes from source and docs.

## Verdict

They sit at different layers. agentic.nvim is a **live chat with one agent at a time**: an ACP (Agent Client Protocol) client that renders the conversation, tool calls and permission prompts in a sidebar. Cockpit is an **async review queue plus a judgment ledger** across many agents. agentic.nvim has no annotations, verdicts, artifacts or feedback capture. Cockpit has no live conversation UI.

The one real overlap is cockpit's planned **stream mode** (§5 `stream`, §8 agent buffers, build step 6). agentic.nvim already does most of it over a **standard protocol**, which the cockpit research never considered (`rg -i acp docs/superpowers/` returned nothing before this doc). **Adopt ACP as the stream-mode transport if step 6 ever runs. Don't adopt agentic.nvim as the runtime**, because its agents die with nvim. Separately, it's a candidate to replace sidekick.nvim for the live lane.

## 1. Feature matrix

| Dimension | agentic.nvim | Cockpit |
| --- | --- | --- |
| Shape | Chat sidebar. Spawns an ACP adapter over stdio JSON-RPC | CLI spine + review inbox. Agents post docs, diffs and questions; you annotate and give a verdict |
| Built | ~18.5k Lua lines, 8 ADRs, unit + integration tests, 12+ providers | Inbox only (~1.2k Lua + 456 Py). Spec core not started |
| Timing | Live: you watch, permissions wait for a keypress | Async: the Stop hook forces a post, and you review later |
| Permission gate | Protocol-native `session/request_permission`: one-key numbered answers using provider labels (ADR 0003), diff preview before the edit applies | Spec: `PreToolUse` hook → `needs_you.json`, because `PermissionRequest` never fires under `-p stream-json` |
| Agent output as buffers | Done: streaming tool-call blocks, folds, statuscolumn borders, hunk navigation | Spec §8 `stream.lua`, on top of undocumented `stream-json` frames isolated in `runtime.py` |
| Vendors | Any ACP provider: Claude, Codex, Gemini, OpenCode, Cursor, Copilot, Goose, … | "Other agent CLIs later" |
| Process lifetime | ACP child of nvim (`uv.spawn`, own process group, ADR 0006), stopped on exit. The conversation comes back via provider `session/list` + `session/load`; an in-flight turn is lost | Must outlive nvim (headless herdr / `claude --bg`). `jobstart` rejected for this reason (§3) |
| Multiple sessions | Many per provider, multiplexed over one subprocess (ADR 0004), keyed by session, not tab (ADR 0008) | Tracks = tabpages (§8) |
| Context injection | File, selection, diagnostics, images, `@` file picker, slash-command completion | None (agents read files themselves) |
| Annotations, verdicts, ledger | None. Allow or reject only, nothing recorded | Core: line-anchored notes, why-tags, 4 verdicts, `feedback.jsonl`, board |
| Extension points | `hooks.{before_first_prompt, on_prompt_submit, on_session_update, on_file_edit, on_request_permission, on_response_complete}` | Hooks are Claude Code hooks (`cockpit_inbox.py hook stop`) |

## 2. Adopt / borrow / ignore

| Item | Verdict | Why |
| --- | --- | --- |
| **ACP as the stream-mode transport** | **Adopt (if step 6 runs)** | Passes all three build-vs-rent criteria (§1): Zed and others build it generically, it holds none of our data, and swapping costs only a client. It replaces the hand-rolled FIFO/NDJSON protocol and the `PreToolUse` gate with documented `session/prompt`, `session/update`, `session/request_permission`, `session/cancel` |
| agentic.nvim as cockpit's worker runtime | **Ignore** | Agents are nvim children. Breaks the "workers survive nvim and tmux restarts" requirement (§2 Worker runtime) |
| agentic.nvim instead of sidekick.nvim for live chat | **Spike** | Gains: protocol-native permissions + diff preview, model/mode switching, context injection. Loses: the real Claude Code TUI (hooks, plugins, mods, plan-mode UI, statusline). An ACP adapter will lag Claude Code. The flow metric (§1) penalises a second Claude grammar |
| ADR 0008: key ownership by session/track id, never by tabpage handle | **Borrow** | Tab-keyed state caused `:tabclose` killing live sessions, `bufwinid` misses in other tabs, and `vim.t` copy-on-read bugs. Cockpit's "tabpages are tracks" must store state by track id and treat the tab only as where it is shown now |
| ADR 0001/0002: streaming into `wrap` + fold buffers flickers; draw borders with `statuscolumn` | **Borrow** for `stream.lua` | Exactly the "agents are buffers" render path. `set_lines` topline shift vs lazy `foldexpr` causes a viewport jump. Use manual folds, and snapshot fold state on hide |
| ADR 0003: numbered one-key answers using provider labels | **Borrow** → inbox | Done 2026-11-10: `1`–`9` pick options in thread views |
| `on_file_edit` / `on_response_complete` hooks | **Borrow (if the spike adopts it)** | Feed `cockpit_inbox.py post` from live sessions so the ledger also covers in-the-loop work. Inbox replies could go in as `session/prompt` instead of `tmux send-keys` |
| Inline virtual-line diff preview | **Ignore for now** | Inbox `gS` (sent vs current `diffthis`) already covers the review need |

## 3. Integration gaps if agentic.nvim is adopted for the live lane

- `cockpit_inbox.py hook stop` returns early without `TMUX_PANE`, and reply delivery uses `tmux send-keys`. An ACP session has neither, so it would skip the inbox entirely. Delivery would have to go through agentic.nvim's session API, and only while nvim runs.
- Herdr status detection is pane-based. ACP sessions would need to push state (`pane.report_agent`) from `on_session_update`.

## 4. Spike questions

1. **Billing (blocks everything ACP).** Spec §2 says "never the Agent SDK; Agent SDK is API-key only". `claude-agent-acp` is built on the Claude Agent SDK, yet agentic.nvim's README says `claude /login` (subscription) works with no API key. Test: run `claude-agent-acp` with no `ANTHROPIC_API_KEY` and check whether turns bill to the subscription. One of the two claims is wrong.
2. Can an ACP adapter run detached (under herdr or launchd) with nvim connecting as a client, e.g. a stdio↔socket bridge? If yes, ACP satisfies "workers outlive nvim", and stream mode becomes "ACP client + bridge" instead of `runtime.py`.
3. Mid-turn `session/prompt`: rejected, queued, or injected by `claude-agent-acp`? This is the same question as §13 "is mid-turn injection worth owning", answered on a standard surface.
4. Which Claude Code features are missing over ACP (plugins/mods, `AskUserQuestion`, background tasks, `/` commands from plugins)? Decides the sidekick-replacement spike.
