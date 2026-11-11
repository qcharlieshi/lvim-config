# Plannotator Inbox vs Cockpit (2026-11-03)

**Question:** Plannotator Inbox + Board, guided review, plan/code review and the Claude Code mod now cover much of what cockpit spec v8 plans to build. What should cockpit stop building, what is really different, and how should the two fit together?

**Inputs:** spec v8 (`specs/2026-08-28-cockpit-design.md`), `2026-11-03-review-gate-landscape.md`, Plannotator docs/blog/source/releases (URLs inline, list at end). `plannotator` is **not installed on this Mac**, so every behaviour claim below comes from docs or source, not from running it.

## Verdict

Plannotator already ships the **review surface and the delivery plumbing** of cockpit's steer loop: annotate, verdict, revise, deliver to the asking session, guided CodeDiffs, plus async away-from-desk review. Cockpit still has one durable asset of its own: **why-tagged steers kept in a git ledger with attribution**. Plannotator added durable "decision records", then deleted them 11 days later on an owner ruling ([PR #1985](https://github.com/backnotprop/plannotator/pull/1985)). That shows the judgment-capture layer is not something this vendor wants to own. **Recommendation: option (d).** Plannotator becomes the transport and review UI. Cockpit becomes a git ledger plus a thin ingest layer. The nvim hood (§8) stays frozen until a usage spike shows the browser actually costs flow.

## 1. Feature matrix

| Dimension | Plannotator (OSS v0.28.48) | Cockpit v8 (spec) |
| --- | --- | --- |
| Artifact types | Plans (ExitPlanMode), any md/txt/HTML/folder/URL, local diffs (git/jj/GitButler/p4), GitHub/GitLab PRs, agent's last message; Inbox attachments of any file incl. images, video, PDF ([inbox ref](https://plannotator.ai/docs/reference/inbox/), [CLI](https://docs.plannotator.ai/open-source/reference/cli.md)) | Closed `kind` enum: research/prd/spec/design/adr/plan/codediff/review/digest + Records (§6) |
| CodeDiff | **Guided review**: ordered sections, each with an overview and per-file summaries, every file checked against the real diff. Versioned strict snapshot `guide{title,intent,sections[{title,overview,diffs[{file,summary}]}]}`, `review{rawPatch,base}`, `source{headSha,…}`, `generator{engine,model}` ([ADR 007](https://github.com/backnotprop/plannotator/blob/main/adr/decisions/007-portable-guided-reviews-20260815.md), [agent reviews](https://docs.plannotator.ai/open-source/workflows/agent-reviews.md)). Saved guide flags "Diff changed" on commit drift | `.patch` + sidecar (Intent · Files · Risk · How to test) (§6) |
| Verdicts | Plan/doc: Send Feedback · Approve with Notes · Approve · Close. Strict mode `--gate --json --require-approval` gives exit 0/1/2 ([hooks](https://docs.plannotator.ai/open-source/reference/hooks.md)). Inbox: reply · 👍 Looks good · Mark read · Archive · question-card picks. **No explicit per-document verdict in the Inbox** | None explicit; `approve` is a why-tag (§8 taxonomy) |
| Annotation model | Comment / Delete / Quick label / Looks good / Global; direct edits as unified diff ([annotations](https://docs.plannotator.ai/open-source/workflows/annotations-and-feedback.md)). Code: comment/suggestion/concern + `conventionalLabel` (custom strings allowed) + `blocking` decoration ([ui/types.ts](https://github.com/backnotprop/plannotator/blob/main/packages/ui/types.ts), [config](https://docs.plannotator.ai/open-source/reference/configuration.md)) | `{ref, why, text}`, closed why-taxonomy (§4, §8) |
| Anchoring | Text quote (`originalText`) + source line. Inbox: attachment `sent_sha256` blob, so a comment pins to the bytes that were sent ([inbox-attachments.ts](https://github.com/backnotprop/plannotator/blob/main/packages/core/inbox-attachments.ts)) | `id@sha:line` (git sha) (§6) |
| Revisions | Plan history keyed by project + first heading + **date**; files keyed by path; rendered/raw plan diff; a revised plan updates the open tab ([version history](https://docs.plannotator.ai/open-source/workflows/version-history.md)). Not git | Revisions are commits; `git log -p` (§4, §6) |
| Delivery / addressing | Reply goes to the **session that asked**. Claude Code/Pi/OpenCode 2 are woken as a new turn at idle; **Send now** injects into the running turn; Codex ≥0.149 via `codex queue`; other MCP clients poll `read_thread`/`wait_for_reply` ([inbox ref](https://plannotator.ai/docs/reference/inbox/)) | `review send <id>` addresses the **artifact**, lazy resolver (§2, §5) |
| Producer gone | After 1 min of silence the thread shows "session ended". At Send you choose another *running* session in the project or "Leave it for the next agent". Never routed automatically; **no successor spawn** | Spawn a successor seeded with steer + `context`/`handoff` (§5) |
| Async | Native: nobody blocks; the mod ends Claude's turn on ExitPlanMode and delivers the decision later; decisions survive terminal close + `claude --continue` ([claude-code](https://docs.plannotator.ai/open-source/agents/claude-code.md)). Mod is **off in `claude -p`/SDK** | Gate hook polls; mid-turn semantics an open question (§5, §13) |
| Permission gate | ExitPlanMode only. Inbox "action items" are human to-dos, not tool gates | `PreToolUse` gate → `needs_you.json` (§5) |
| Fleet status | **Board**: work-item cards (Backlog/Todo/In progress/In review/Done), agent-maintained, auto-Done on PR merge; off by default. Not process state | Process state via herdr + fleet float (§5, §8) |
| Storage | `~/.plannotator/inbox/projects/<name>-<hash>/{messages,questions,annotations,cards}.jsonl`. Append-only, one full-snapshot line per record version (`{v:1,seq,at,kind,id,record}`), blobs by sha256 ([inbox-types.ts](https://github.com/backnotprop/plannotator/blob/main/packages/core/inbox-types.ts)). Greppable and exportable; not git-tracked; no size limits | `~/.cockpit/` git repo, flock'd commits (§4) |
| Lineage | None across documents. Threads link files; cards link threads/PRs | `derives_from`/`steered_by`/`supersedes`/`code` (§6) |
| Harness-improvement data | Feedback is flattened to markdown for the agent. Structured only in Inbox `annotations.jsonl`. "Compound value" means saving feedback to a folder by hand and asking an agent to write a skill ([compound value](https://docs.plannotator.ai/open-source/start/compound-value.md)). Decisions feature **removed** (#1985) | `feedback.jsonl` with why-tags + `producer` attribution (§10) |
| Surface | Browser, phone over Tailscale, VS Code/Zed tabs. nvim only via [plannotator.nvim](https://github.com/radekska/plannotator.nvim): 1★, last push 2026-06-19 (before the Inbox), plan/diff only, drives **unversioned** session routes ([local API](https://docs.plannotator.ai/open-source/reference/local-api.md)) | nvim (§8) |
| Vendors | ~15 agents auto-connected (Claude Code, Codex, Pi, OpenCode, Gemini, Qwen, Cursor, …) | Claude Code ("others later") (§1) |
| API | Inbox MCP (`send_message`, `read_thread`, `search`, `resolve_message`, `submit_guide`, `card`); `plannotator inbox call <action> <json>` for scripts; external-annotations HTTP (the only documented-stable route). "No tool answers, approves or sends anything for you": the **human side has no public API** | `cockpit` CLI verbs (§7) |

## 2. Already done: cockpit should not build these

1. **Annotate-and-send UI** for documents and diffs: the §8 document overlay, the annotate operator UI, the `review send` delivery path for interactive Claude sessions. Plannotator's version is better: quote anchoring, direct-edit diffs, image markup, guided-review comments.
2. **Delivery to the asking session, including mid-turn.** "Send now" answers the §13 question about whether a mid-turn steer injects or queues, for mod-equipped interactive sessions. Delivery acks ("Queued", "Delivered") are built in.
3. **CodeDiff format.** The guided-review snapshot is versioned, strict, records base/head and generator, and detects drift. It beats `.patch + sidecar`.
4. **Async away-from-desk review** (tailnet phone, notifications, triage sections "Stopped on you / Holding up work"). Cockpit can't offer this at all, and the thesis (§1) assumes long-running agents.
5. **Structured questions** (`:::question` with `Stopped:`/`Holds up:` lines, supersede/re-ask) and **action items**. Cockpit has no equivalent; `needs_you` covers tool permissions only.
6. **Multi-vendor connectors.** "Other agent CLIs later" (§1) is already done.

By the spec's own test (§1): (1) a funded team is building this generically, at 48 releases from v0.28.0 (2026-10-05) to v0.28.48 (2026-11-03); (2) the UI accrues no data of ours if we capture it elsewhere; (3) switching later costs only adapters. **The review surface fails the test, so rent it.**

## 3. Where cockpit is different, and whether it matters

| Claim | Devil's advocate | Holds? |
| --- | --- | --- |
| Why-tagged steer ledger (§10) | Plannotator's `conventionalLabels` and quick labels are a ready UI for why-tags. Configure them to the cockpit taxonomy and the UI cost disappears. What's left is **persistence + attribution**, roughly 150 lines of ingest. It's also the one thing Plannotator explicitly backed out of (#1985), and Workspaces (hosted, commercial) was handled "in a separate change". That suggests capture may move behind the paid tier | **Yes**, but it's a data layer, not a UI |
| Git-tracked artifacts + lineage (§4, §6) | Lineage pays off only in `retro`, which is deferred to step 8 "until volume". The `doc lineage` Mermaid graph is gold-plating for a prototype. Frontmatter is free; graph tooling is not | Keep frontmatter, drop the tooling |
| Artifact addressing + successor spawn (§5) | Plannotator's "Leave it for the next agent" plus resume-time thread injection covers most of it. A successor spawn is a small watcher on "session ended" threads that runs `claude` with a seed prompt to `read_thread` | Marginal; build it as a layer on top |
| nvim as the hood (§8) | It's a real preference. But flow (§1) counts **grammars per hour**, and v8 already has nvim + tmux + herdr + an operator terminal. A browser Inbox replaces about five planned nvim buffers. An nvim Inbox client would have to target unversioned human-side routes on a near-daily release train, which is the exact quarantine problem `runtime.py` exists for | **Unproven**, so spike before building |
| `PreToolUse` gate (§5) | Needed only for stream mode, which is optional (step 6). Background mode uses native needs-you | Not a differentiator |
| Budgets, templates, closed kinds (§6) | Templates are prompts; budgets are lint warnings. Plannotator publishes templates too ([templates](https://docs.plannotator.ai/templates/index.md)) | Cheap and worth keeping, but not a moat |

## 4. Integration options

| Option | Mechanics | Cost | Lock-in | §1 test / flow |
| --- | --- | --- | --- | --- |
| **(a) Adopt wholesale**; cockpit shrinks to a data layer | Plannotator plugin + Inbox for everything. Cockpit = cron/`FileChanged` ingest of `~/.plannotator/inbox/**.jsonl` into `~/.cockpit` git | Lowest (days). Lose verdict structure, lineage, successor spawn | Med: JSONL is exportable, but the session-addressing semantics are theirs | Passes. Flow: +1 grammar (browser), −nvim review |
| **(b) nvim hood on Inbox storage/MCP** | nvim reads the JSONL directly; writes replies through the Inbox's internal `/api/inbox/*` with the token from `inbox.json` | High and recurring: reverse-engineering + chasing daily releases; plannotator.nvim shows the decay rate | **High**: human-side routes are unversioned UI contracts | Fails criterion 3 (our adapter is the switching cost). Flow: best on paper |
| **(c) Stay the course, borrow formats** | Build §6–§8 as specced; adopt the guided-review snapshot, Conventional Comments labels, `:::question` syntax | Highest (weeks of §8 + delivery) | None | Fails criterion 1 for the review UI. Flow: nvim-only, no phone |
| **(d) Inbox as transport, cockpit as ledger** (new) | `cockpit doc publish <id>` = `plannotator inbox call send_message` with the Document attached + a `:::question` verdict block (approve · approve-with-notes · changes-requested · reject). Human reviews in the Inbox. Reply wakes the producer. `cockpit ingest` tails `questions.jsonl` (verdict picks) + `annotations.jsonl` (why = label) into `feedback.jsonl`, joined to `producer`/`id`, and commits. "Session ended" threads trigger a successor spawn. CodeDiffs go through `submit_guide` | Low–med: publish + ingest + successor ≈ step 2–3 scope | Low–med: we only read **append-only JSONL** and call the **documented** MCP/`inbox call`. If Plannotator dies, artifacts + feedback survive in git | Passes all three. Flow: browser for review, nvim/tmux for code; measurable |

Option (d) borrows the "stable surface only" discipline of `supervisor.py`. It uses only MCP / `inbox call` / external-annotations / JSONL reads, and never the human-side HTTP routes.

## 5. Recommendation and spec v9 changes

Adopt **(d)**. Run Plannotator as the rented review plane, and own only the ledger. Treat the nvim hood as an experiment the data has to justify.

- **§1** Re-run build-vs-rent: the review surface and delivery fail the test and become *rented* (Plannotator), with all assumptions quarantined in a new `review_plane.py`. Thesis unchanged. Add the evidence that the vendor removed decision capture (#1985).
- **§2** Decisions table: Hood → "nvim for code and agent buffers; Plannotator Inbox for review (rented)". Add "Review plane: Plannotator ≥0.28.48, stable surfaces only". Steer addressing stays artifact-first, but the resolver checks Inbox thread state first.
- **§5** Steer delivery: first choice is the Inbox reply (mod wake / Send now); `SendMessage` and `agent.prompt` are fallbacks for sessions without the mod. Successor spawn is triggered by "session ended" threads. The open question about mid-turn behaviour is answered for mod sessions.
- **§6** Replace `codediff` `.patch + sidecar` with the guided-review snapshot v1 (store `{id}.guide.json` + `.patch` in git). Add an explicit `verdict` enum to the steer Record. Map `review` kind findings to Conventional Comments labels.
- **§7** Add `doc publish`, `ingest`. Turn `annotate` into a CLI-only fallback. `review send` becomes "publish with prior-round context".
- **§8** Freeze: inbox buffer, document overlay, annotate operator, fleet float. Keep only the documents/tracks buffers (read-only views over `~/.cockpit`) and the operator terminal. Configure `conventionalLabels` = the why-taxonomy, each with a `blocking` flag.
- **§10** v1 data source = ingest from Inbox JSONL. Add `verdict`, `label`, `blocking`, `sent_sha256` to `feedback.jsonl`.
- **§12** New order: 1 CLI core → 2 artifacts + `doc publish` → 3 `ingest` + `feedback.jsonl` + successor spawn → 4 operator/supervisor → (5 nvim hood only if spike Q6 says so) → 6 stream → 7 telemetry.
- **§13** Add the spike questions below; drop the question about whether `hunk` earns a place as an annotation backend.

## 6. Spike questions (each testable in under a day)

1. With a Document attached via `send_message`, do a quick label's text and a code comment's `conventionalLabel` show up in `annotations.jsonl` (`record.annotation`) in a form `jq` can extract? Do the Inbox's file viewers offer quick labels at all, or only full plan review?
2. Does the mod load and wake a **`claude --bg`** background session (cockpit's default spawn mode, §5)? Docs only exclude `-p`/SDK/Windows. If the answer is no, which fallback works: MCP polling or `SendMessage`?
3. Does a `:::question` verdict pick land in `questions.jsonl` with the answering reply id, so verdict and annotations join on one Send?
4. Does `plannotator inbox call send_message` with `--session <host>:<id>` let the cockpit CLI post *as* the producer, so the reply wakes the producer and not the CLI's shell?
5. Does Send now inject into a running Claude turn (one `Stop`) or start a second turn? This is the same test as §13's `agent.prompt` question.
6. **Flow:** review all Documents in the browser Inbox for one week and log context switches per hour with a tmux/browser focus logger. If switches exceed the v8 baseline estimate, unfreeze §8 option (b), scoped to read-only views.
7. Is the JSONL format stable across 5 consecutive releases? Diff the `{v:1}` line shapes from fixtures in `packages/shared/inbox/fixtures/thread-state/v1`.
8. With `annotateHistory` on, does reopening a revised Document from the Inbox show the plan diff, or do Inbox attachments only get "Changed since sent"?

## Risks (lock-in)

- **Single maintainer:** backnotprop has 4,168 commits; the next contributor has 24. Releases are near-daily and features get reversed (Decisions lasted Oct 7–18).
- **Commercial pull:** hosted Workspaces and mobile apps are coming ([blog](https://plannotator.ai/blog/the-age-of-the-inbox/)).
- **Mitigation:** the license is dual MIT/Apache-2.0, so a fork is possible. Data is append-only JSONL plus sha256 blobs. Cockpit never makes it the source of truth for artifacts.

## Sources

docs.plannotator.ai/llms.txt · /open-source/inbox.md · plannotator.ai/docs/reference/inbox/ · plannotator.ai/blog/the-age-of-the-inbox/ · /open-source/agents/claude-code.md · /open-source/workflows/{plan-review,annotations-and-feedback,version-history,agent-reviews,local-changes}.md · /open-source/reference/{custom-feedback,hooks,cli,local-api,external-annotations,configuration}.md · /open-source/start/compound-value.md · /open-source/artifact-server.md · github.com/backnotprop/plannotator (releases v0.28.0–v0.28.48; PR #1985; `packages/core/inbox-types.ts`, `inbox-attachments.ts`, `packages/ui/types.ts`, `apps/hook/server/inbox-call-command.ts`, ADR 007) · github.com/radekska/plannotator.nvim · code.claude.com/docs/en/plugins/mods/{overview,api}
