# Cockpit: spawn/fork dialog, fork provenance, handoff forks

**Tier:** Prototype. **Depends on:** `cockpit-projects-layout` (nvim-3a's branch: tabs per agent, `agent_name()`, dir picker) being merged.

**Already done (branch `cockpit-naming`):**
- Agent names come from `lua/cockpit/naming.lua`: typed name › ticket (branch, then prompt) › meaningful branch › 2–3 prompt words › `<project>-<n>`.
- The same name goes to herdr, the tab and `claude -n`.
- Spawn and fork ask for an optional name with `vim.ui.input`.
- On merge with `cockpit-projects-layout`: fold `naming.base` into its `agent_name()`, and use its `ticket.lua` in place of `naming.ticket`.

## T1 — Spawn/fork dialog (one float instead of chained pickers)

- One editable float buffer, shared by spawn and fork. Built on `inbox/float.lua`, no new plugin.
  ```
   Spawn · <project>
   Dir      <repo>          (multi-repo projects only)
   Profile  default         <Tab>/<S-Tab> cycle
   Name                     (empty → derived)
   ──────────────
   first prompt, multi-line
  ```
- The fork version adds `Mode  continue | worktree | handoff` and, for handoff, `Source  conversation | deliverable | review`. It defaults Profile to the parent's and puts the fork prompt (handoff: summarization prompt) below the line.
- `<C-s>` or `:w` submits, `q` cancels. The field lines are parsed back. Unknown values show an error in the float and don't close it.
- Replaces the chained `vim.ui.select`/`vim.ui.input` in `ui.spawn` and the rail `fork()`.

**Done when:** spawn and both fork kinds go through the float. A multi-line first prompt is delivered intact, and an empty Name gives the derived name.

## T2 — Record why a fork exists

- Fork records in `agents.jsonl` gain `fork_prompt` (the text typed) and `parent_session`.
- The rail details/winbar shows `↳ <parent> · "<fork prompt, truncated>"`.

**Done when:** a fork's record and rail row show its parent and prompt after an nvim restart.

## Fork model (how the pieces are meant to be used)

A project usually has one lead agent (exploration, or straight onto a ticket) and a few forks. Transitions are manual for now; workflows/pipelines that automate them come later and reuse these primitives.

- **Direct fork** (`continue` / `worktree`, exists): the child inherits the whole conversation. Right when the context *is* the value: a short session that already read the files the next step touches, side quests, trying two approaches in parallel.
- **Handoff fork** (T3): fresh session seeded with an edited handoff. Right at a **stage boundary**, i.e. when a deliverable is approved: the exploration behind it is noise for the next stage.
  - plan → implement: seed = approved deliverable + delta (what the conversation knows that the doc doesn't).
  - implement → review: seed = the plan + the diff. Nothing written by the implementer, so the reviewer isn't anchored on its reasoning.
  - review → fix: no fork. Findings go back to the implementer as a reply.
- **Review rounds stay in the author's session.** A deliverable's revise/approve loop runs on its inbox thread with the agent that wrote it: the revision needs that context, rounds are small, and the "why we changed it" is what the next handoff's delta should capture. Forking a round only duplicates the context and leaves the parent with a lossy summary of what it would have had natively.
- **Fold back = a report, not a merge** (T4). A child that finishes sends its parent a short report pointing at its thread. Only worth it when the parent keeps working as lead; otherwise the inbox thread is the record.
- **Escape hatch**: a lean child can query the parent's full conversation with `cockpit-ctl ask --fork <parent>` (T3d makes that work after the parent has exited).

## T3 — `handoff` fork mode (fresh session from an edited handoff)

Common to all sources:
- A separate `claude -p` on the `digest` profile (Sonnet; you edit the result anyway) writes the handoff markdown. The parent is never interrupted.
- The handoff opens in the cockpit workspace as an editable deliverable, stored as an inbox blob (not committed to the repo).
- `:w`/approve starts a **fresh** session (no `--resume`) in the parent's checkout, on a profile picked in the dialog. The edited handoff is its first prompt; `fork = "handoff"`, `handoff_source`, `fork_prompt` and the handoff blob sha go in its record.

### T3a — from the conversation
- The dialog's text is a **summarization prompt** (what to keep or focus on), not a first prompt.
- The summarizer reads the parent's transcript JSONL and writes: goal, state, decisions + why, next steps, open questions.

### T3b — from a deliverable
- Pick an inbox attachment (doc or diff) of the parent's threads, or a file.
- The handoff = the deliverable (by reference: path / blob) + a summarizer-written **delta**: rejected approaches, gotchas and constraints from the conversation that the deliverable doesn't state. Not a re-summary.

### T3c — review handoff
- Seed = the plan deliverable (picked as in T3b) + `git diff <base>..<head>` of the implementer's checkout or fork branch, by reference.
- No summarizer pass over the implementer's transcript.
- The reviewer posts findings to its own thread; you forward them to the implementer (reply), which keeps the fix loop in the implementer's session.

### T3d — `ask --fork` on an exited parent
- `ctl.lua` `session` falls back to the registry record's session id (as `forks.lua` `session_of` does) when no live agent has the name.

**Done when:** from a long-running agent, a T3a/b handoff fork starts with a context of a few thousand tokens, its first prompt matches the edited handoff, and the handoff is viewable from the fork's rail row. A T3c reviewer's first prompt contains the plan and the diff ref and nothing from the implementer's transcript.

## T4 — report to parent (fold back)

- Manual rail key on a fork: the summarizer drafts a short report from the fork's transcript (what was done, deviations from the seed/plan, open items, link to its thread). You edit it; it's delivered to the parent through `inbox/delivery.lua` as a reply-style prompt.
- Not automatic on approve/kill: most children don't need to report back.

**Done when:** a report lands in the parent as one prompt pointing at the child's thread, and appears in the parent's thread history.

## Open questions

- Should a worktree `handoff` fork exist in v1, or only same-checkout? (T3c reviewing a `worktree` fork only needs its branch for the diff, not a worktree of its own.)
- T4: deliver into the parent's conversation, or only post to a thread the parent can `read`? The first keeps the lead current but grows its context.
