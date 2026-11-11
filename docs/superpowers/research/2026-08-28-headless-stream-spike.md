# Spike: persistent headless `claude -p` stream-json worker for an nvim cockpit

Date: 2026-08-28 · CC 2.1.251 · macOS 25.5 · Tier: throwaway spike
Scripts/evidence: `<scratchpad>/spike/` (`start.sh`, `send.sh`, `hook.sh`, `spike-settings.json`, `out.ndjson`, `events.jsonl`, `run1..run8/`)

**Overall: WORKS WITH ONE MAJOR CAVEAT.** A persistent multi-turn NDJSON worker on subscription auth is real and pleasant to drive. The caveat: the `PermissionRequest` hook **never fires** in this mode — use a `PreToolUse` hook as the human-in-the-loop gate.

## Command shape that worked

```bash
env -u ANTHROPIC_API_KEY claude -p \
  --input-format stream-json --output-format stream-json --verbose \
  --permission-mode default \
  --settings /abs/path/spike-settings.json \
  --add-dir /abs/work/dir \
  --replay-user-messages \
  < in.fifo > out.ndjson 2> err.log
```
Do **not** pass `--bare`: bare mode never reads OAuth credentials and needs `ANTHROPIC_API_KEY`.

stdin turn format (one NDJSON line, `uuid` optional but useful for correlation):
```json
{"type":"user","uuid":"<uuid4>","message":{"role":"user","content":"text"},"parent_tool_use_id":null}
```

## 1. Auth — WORKS

- `claude auth status` → `{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"team"}` (exit 0).
- `system/init` in the stream reports `"apiKeySource":"none"`, `"model":"claude-fable-5"` → subscription OAuth, no API key.
- `ANTHROPIC_API_KEY` was unset; every run used `env -u ANTHROPIC_API_KEY` anyway.
- Bonus: an `initialize` control request on stdin returns the account block directly —
  `{"account":{"email":...,"organization":"Lilt","subscriptionType":"Claude Team","apiProvider":"firstParty"}}` plus `pid`, `current_permission_mode`, `models`, `commands`, `agents`. Best single status probe for the cockpit.

## 2. Persistent multi-turn over stdin — WORKS

- FIFO gotcha confirmed necessary at startup: hold a writer (`exec 3> in.fifo`) in a second tmux window.
- Turn 1 "Reply with exactly the word PONG." → `assistant`/`result` text `PONG`.
- Turn 2 "What word did you just say?" → `PONG`. Same `session_id` (`25c6ff3a-…`), same pid, `etime 01:38` between turns. Context carried.
- Output flows normally with only the FIFO holder as the other writer; no manual flush needed.
- Timings (subscription, trivial turns): first `assistant` event **2.9–3.3 s** after the stdin write, `result` **+0.1–0.2 s** later. Cold start (process launch → first `result`, with the user's 4 MCP servers connecting) **≈10–13 s**.
- Surprise: `system/init` is **not** emitted at process start. It is emitted *per turn*, after the first stdin message. So "worker ready" cannot be detected from `system/init`; use the `initialize` control response or the `SessionStart` hook instead.
- `--replay-user-messages` echoes each stdin turn back as `{"type":"user","isReplay":true,...}` — cheap write-ack and it also reveals mid-turn injected messages. Recommended.
- Bonus: the process **survives stdin EOF** (all FIFO writers closed) and resumes reading when a new writer opens the FIFO. It never self-exits.

## 3. Hooks in headless mode — WORKS (partially)

Fired, with correct payloads, from a `--settings` file:

| Event | Fired | Notes |
|---|---|---|
| `SessionStart` | yes | `source:"startup"`; also streams `hook_started`/`hook_response` frames on stdout |
| `UserPromptSubmit` | yes | carries `prompt`; **does not fire** for a message injected mid-turn |
| `PreToolUse` | yes | `tool_name`, `tool_input`; no stdout frames |
| `Stop` | yes | `last_assistant_message` populated — use it, don't parse the transcript |
| `Notification` | **never** | no `permission_prompt` notification was ever produced |
| `PermissionRequest` | **never** | 0 firings across 9 sessions |
| `PermissionDenied` | **never** | auto-mode-only event; we ran `default` |

`transcript_path` existed on disk every time (`~/.claude/projects/<slug>/<sid>.jsonl`, ~60 KB).

## 4. Permission via hook — FAILS as specified, WORKS via `PreToolUse`

`PermissionRequest` **never fires** under `-p --input-format stream-json`, contradicting the docs
("in sessions that can't show a prompt … Claude Code still runs these hooks"). Instead a gated tool
call is hard-denied immediately: stream shows `{"type":"system","subtype":"permission_denied", …}`
and the model gets a `tool_result` such as *"Claude requested permissions to write to … but you haven't
granted it yet"*. No `control_request`/`can_use_tool` frame is emitted on stdout either, even after a
successful `initialize` control request — `can_use_tool` stays SDK-only for a raw CLI client.
(The documented third path is `--permission-prompt-tool <mcp tool>`; untested here.)

**What worked** — a gating `PreToolUse` hook (`matcher: "Bash|Write"`) that writes `needs_you.json`, polls for a `decision` file, then emits:

```json
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow",
                       "permissionDecisionReason":"approved in nvim cockpit"}}
```
```json
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny",
                       "permissionDecisionReason":"Human operator denied this from the nvim cockpit."}}
```

- **allow** (human answered after 5 s): `touch gated-marker` ran, `gated-marker` created, whole turn 10.6 s. Hook block was 0.68 s from `waiting` to `decision=allow`.
- **deny**: file not created; the model received the reason verbatim as the `tool_result` and reported it. Turn completed `success`.
- `allow` also overrides Claude Code's own Bash write-guard, which otherwise hard-denies writes with *"may only create or modify files in the allowed working directories"* — that guard fired even for paths **inside** `--add-dir`, so treat it as another thing only the hook can unblock.
- **While waiting, the NDJSON stream is silent.** No "waiting on permission" event of any kind. The only signal is: last frame is an `assistant` `tool_use` block with no matching `tool_result`. The hook's own side-channel file is the real signal.
- **Hook `timeout: 10`** → output discarded, no decision, flow proceeds unchanged and falls through to the built-in deny. Fail-closed and safe; the whole turn took 23 s. The hook's own process is not killed, so it must self-bound its polling.
- Gotcha found the hard way: `skipAutoPermissionPrompt: true` in the user's `~/.claude/settings.json` suppressed the prompt path entirely. The cockpit must pin the permission-relevant keys in its own `--settings`.

## 5. Resume across modes — WORKS

```bash
env -u ANTHROPIC_API_KEY claude -p --resume 9db00203-e28b-4dd0-a472-e71505110c68 "…"
```
Exit 0 in 9.2 s; it correctly recounted the 5 earlier turns including the mid-turn injected message and the interrupt. Resume works from a different cwd.
Visibility: **not** listed by `claude agents --json --all` (0 matches). It exists only as `~/.claude/projects/-Users-…-work/<sid>.jsonl`. Session discovery must read that directory.

## 6. Interrupt / steer semantics

- **Mid-turn stdin message is injected into the running turn, not queued as a new turn.** Sent 8 s into a 3-step Bash turn, it appeared as `isReplay:true`, the model answered it inline (`QUEUED-OK`) and continued the original work. One `result`, one `Stop`, one `UserPromptSubmit` for the whole thing. This is exactly the steering primitive a cockpit wants.
- **`control_request` interrupt over stdin — WORKS, process survives.**
  ```json
  {"type":"control_request","request_id":"cockpit-int-1","request":{"subtype":"interrupt"}}
  ```
  → `{"type":"control_response","response":{"subtype":"success","request_id":"cockpit-int-1","response":{"still_queued":[]}}}`, then a `user` frame `[Request interrupted by user]`, then `result` with `subtype:"error_during_execution"`. Worker stayed alive and accepted later turns. `system/init` advertised `capabilities: ["interrupt_receipt_v1","interrupt_cancel_queued_v1","msg_lifecycle_v1"]`.
- **SIGINT** ends the turn *and* exits the process, **exit 0**. Not a "stop button" — it is a clean shutdown.
- **SIGTERM** → **exit 143**, turn left unfinished (matches docs).
- **stdin EOF** → no exit at all (see §2).

## Implications for cockpit spawn / steer / status

- **Spawn**: one long-lived `claude -p --input-format stream-json --output-format stream-json --verbose --replay-user-messages` per worker, launched from nvim with `jobstart` — a real pipe removes the FIFO-holder problem entirely. Never `--bare`. Always ship a cockpit-owned `--settings` file that pins `permissions.defaultMode`, `skipAutoPermissionPrompt: false`, and the hook block, so a user's global settings can't change the gating contract.
- **Readiness**: don't wait for `system/init` (it only arrives per-turn). Send an `initialize` control request right after spawn — it returns `pid`, `account`, `current_permission_mode`, `models`, `commands`, `agents` in one shot and doubles as the auth badge.
- **Render**: `out.ndjson` maps cleanly to a buffer. Useful frames: `assistant` (text / thinking / tool_use), `user` (tool_result, injected turns, `[Request interrupted by user]`), `result` (`success` vs `error_during_execution`), `system/init`, `system/permission_denied`, `system/task_started`|`task_notification` (background Bash), `rate_limit_event`, `command_lifecycle`. `--replay-user-messages` + `uuid` gives per-turn correlation.
- **Steer**: write a `{"type":"user",…}` line at any time. Mid-turn it is injected into the live turn — this is the feature, not a bug. There is no "queued turn" semantics to model.
- **Stop button** = `control_request` `interrupt` (worker survives). **Close** = SIGINT (exit 0). **Kill** = SIGTERM (143). Never use SIGINT for "stop".
- **Permissions** must go through a `PreToolUse` hook, not `PermissionRequest`. Broad matcher (`*` or at least `Bash|Write|Edit|NotebookEdit|WebFetch`), and the hook is the *only* channel that can unblock the built-in Bash write-guard.
- **The stream gives no permission-pending signal.** The cockpit's pending-approval UI must be driven by the hook's own side channel (a JSON file, or better a socket back into nvim). Add a per-hook `timeout` so an unattended worker fails closed instead of hanging a turn forever; consider `permissionDecision: "defer"` for approvals that outlive the nvim session.
- **Status/recovery**: session state lives in `~/.claude/projects/<cwd-slug>/<session_id>.jsonl`; `claude agents --json --all` does not see these. Cache `session_id` from the first `system/init` (or `SessionStart` hook) and offer `--resume` for crash recovery — continuity is full.
- **Budget ~3 s per trivial turn and ~10–13 s cold start** with MCP servers attached. If spawn latency matters, trim MCP config for cockpit workers.
