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
- The fork version adds `Mode  continue | worktree | handoff`, defaults Profile to the parent's, and puts the fork prompt below the line.
- `<C-s>` or `:w` submits, `q` cancels. The field lines are parsed back. Unknown values show an error in the float and don't close it.
- Replaces the chained `vim.ui.select`/`vim.ui.input` in `ui.spawn` and the rail `fork()`.

**Done when:** spawn and both fork kinds go through the float. A multi-line first prompt is delivered intact, and an empty Name gives the derived name.

## T2 — Record why a fork exists

- Fork records in `agents.jsonl` gain `fork_prompt` (the text typed) and `parent_session`.
- The rail details/winbar shows `↳ <parent> · "<fork prompt, truncated>"`.

**Done when:** a fork's record and rail row show its parent and prompt after an nvim restart.

## T3 — `handoff` fork mode (fresh session from an edited summary)

- In fork mode `handoff`, the dialog's text is a **summarization prompt** (what to keep or focus on), not a first prompt.
- A separate `claude -p` (profile model, default Sonnet) reads the parent's transcript JSONL plus the summarization prompt and writes a handoff markdown: goal, state, decisions + why, next steps, open questions. The parent is never interrupted.
- The handoff opens in the cockpit workspace as an editable deliverable, stored as an inbox blob (not committed to the repo).
- `:w`/approve starts a **fresh** session (no `--resume`) in the parent's checkout. A worktree option is possible later. The edited handoff is its first prompt; `fork_prompt` and the handoff blob sha go in its record.

**Done when:** from a long-running agent, a handoff fork starts with a context of a few thousand tokens. Its first prompt matches the edited handoff, and the handoff is viewable from the fork's rail row.

## Open questions

- Should T3's summarizer default to the parent's profile model or always Sonnet (cheaper)?
- Should a worktree `handoff` fork exist in v1, or only same-checkout?
