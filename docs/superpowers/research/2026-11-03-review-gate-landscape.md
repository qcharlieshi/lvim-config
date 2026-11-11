# Review-gate landscape (2026-11-03)

Question: is there a product whose whole workflow is "I only look at documents (incl. CodeDiffs) and either continue or send back for redo"? Does it change cockpit spec v8? Sources via Exa. Supersedes §3 of `2026-08-28-cockpit-landscape.md`.

## Verdict

Yes. The pattern now has a name ("UI Review Gate", vividkit.dev/guides/ui-review-gate) and several maintained implementations. Since 2026-08-28 the biggest change is **Plannotator Inbox + Board** (v0.28.x, Oct 2026). It covers most of cockpit's steer loop and review surface, minus nvim, why-tags and git lineage. The spec's build-vs-rent test (§1) needs re-running against it.

## 1. Document-gate tools (approve / send back)

| Tool | Artifacts | Verdicts | Notable |
| --- | --- | --- | --- |
| **Plannotator** (backnotprop, 8k★, v0.28.48 on 2026-11-03) · plannotator.ai | plans (ExitPlanMode hook), markdown/HTML/folders/URLs, local diffs, GitHub/GitLab PRs, jj/GitButler/p4, `--patch-file` | Approve · Approve with Notes · Send Feedback · Close | Plan version history + rendered plan diffs; **Inbox** (`~/.plannotator/inbox/`, threads per project, replies wake the asking session as a new turn when idle, MCP `read_thread`/`wait_for_reply` for others); **Board** (Backlog/Todo/In progress/In review/Done cards, agent-maintained); **guided review** (change split into sections in reading order, each with diff + summary, checked against the real diff); runs as a Claude Code **mod** (non-blocking: decision arrives later as a message; decision on stale revision refused) |
| **radekska/plannotator.nvim** | plans, git diffs | approve / deny | nvim buffers replacing the browser UI; `gc`/`gs`/`gd` comment/suggest/delete. Inbox support unknown |
| **Crit** (tomasz-tomczyk/crit, MIT) · crit.md | markdown, git diffs (git/jj/sapling, stacked PRs), live app via proxy, HTML | comment rounds → approve | Comments persist and re-anchor across rounds; round-to-round diff; `crit comment file:line` for agents |
| **stet** · stet.fyi | spec/plan/mockup pages | Approve · Changes requested | `stet push --wait`; **exit code = verdict** (0/1); verdict persists, so a new session still finds it |
| **Visual Plan** (`vplan`) · visualplan.dev | MDX plans | Approve (0) · Deny (1) · Iterate (2) · Timeout (3) | Iterate requires feedback; answerable open-question blocks; `-i N` round with delta gutter |
| **Convergent** (lostinpatterns, Pi ext) | any markdown | Revision Request · Approve | Revisions generated in an **isolated side session**; only the approved revision enters the main context, superseded ones stay out |
| **Commentary** · commentary.dev | specs/plans/docs | unresolved-comment queue | API/MCP for agents to fetch unresolved comments |

## 2. Board/orchestrator UIs with a review column

- **Vibe Kanban** (Apache-2.0, community-maintained since bloop shut down 2026-04): done task → In Review; line comments batched → Send → task back to In Progress.
- **Cordane**: ticket → worktree → agent → review → PR; "request changes" pins notes to diff lines, same branch gets another pass; failing checks auto-returned within a retry budget.
- **walleyboard PRD** (NikolaiUgelvik): requires a **review package** before Review (diff, commits, summary, tests run/skipped, risks). Requested changes return the *same* session/worktree.
- Conductor, Sculptor, Nimbalyst, Orca, Superset, Emdash: diff review + send-back exists, but they're workspace managers, not document gates. Comparison: orchestrator.inc/compare/best-ai-coding-agent-orchestrators/

## 3. nvim review surfaces (CodeDiff prior art)

- **paul-enz/reviewr.nvim**: herdr-reviewr-style; scopes incl. **turn** (changed since last turn baseline, private `refs/reviewr/*`); comments anchored by identity, not row; mux-agnostic send (`:terminal` → tmux → … → filesystem inbox).
- **cam-matsui/redline.nvim**: comments use **GitHub's review-comment schema** (`path,line,side,start_line,body` + `suggestion` fences), so local export and PR submission are the same data.
- **CodeCompanion code review**: per-round baseline `refs/worktree/codecompanion/baseline`; accept/revert per hunk; works with external Claude Code via `review.md`.
- **rytkmt/herdr-diff-review.nvim**: PreToolUse hook opens the diff in nvim inside herdr; accept / deny / with message / accept-edited.
- **hamersaw/ullr.nvim**: fan-out `claude -p` review agents; declined findings remembered so they aren't re-suggested.
- agent-review.nvim (colewhitley: tmux trigger-line delivery; igor-gorohovsky: approve/decline/approve-with-note).

## 4. Generic HITL inboxes (not coding-specific)

LangGraph `interrupt()` + **agent-inbox** (accept/edit/respond/ignore); LangChain HITL middleware (approve/edit/reject-with-message/respond); **HumanLayer** (Slack approvals, rejection feedback routed back); **gotoHuman** (review types, retry/regenerate, **artifact versioning**); VekInbox (durable queue, signed webhooks). Takeaway: gate = block; **gate + reason = correction loop**.

## 5. Platform change: Claude Code mods (v2.1.287+, Oct 2026)

code.claude.com/docs/en/plugins/mods/{overview,api,reference}: `$.session.send({to:{sessionId}})` (SendMessage-equivalent delivery with `isDelivered`), `session.receive`/`session.send` hooks, `$.tool.register`, `$.prompt.submit`, `$.ui.status/toast`. Plannotator uses these for non-blocking review. For cockpit this gives a **vendor-native, in-process delivery path** for steers. It can replace operator-relayed `SendMessage`, and possibly the polling PreToolUse gate.

## Implications for spec v8

1. **Build-vs-rent fails for the review surface + delivery.** Plannotator meets criterion (1) (active, generic, near-daily releases). What still passes is the why-taxonomy, git-tracked artifacts/lineage and `feedback.jsonl`. Nothing found captures *why-tagged* steers. Closest: ullr's declined-finding memory, nvim-arbiter "review memory".
2. **Verdicts should be explicit and closed.** Use `approve` · `approve-with-notes` · `changes-requested` · `reject/stop`, mapped to exit codes (vplan/stet precedent). Today the spec folds verdicts into the steer taxonomy (`approve` is a why-tag).
3. **CodeDiff format:** replace `.patch + sidecar` with a **guided-review** shape: ordered sections, each with hunks + one-line why, validated against the real diff. Keep per-round baselines in private refs so round N shows only the delta.
4. **Steer record schema:** adopt GitHub review-comment fields (redline) so a steer can post as a PR review unchanged.
5. **Context hygiene (Convergent):** a successor or revision should see only the approved/latest revision + steer, not superseded drafts. That fits the `review send` successor path.
6. **Delivery:** prototype steer delivery as a cockpit **mod** before building the operator relay or herdr `agent.prompt` path.
7. **Open:** does plannotator.nvim speak the Inbox protocol? If not, can a cockpit nvim client read `~/.plannotator/inbox/` + reply via its MCP? That would let nvim stay the hood while renting the plumbing.
