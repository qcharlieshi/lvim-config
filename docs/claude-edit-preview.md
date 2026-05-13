# Claude Edit Preview — DIY design

A code-preview.nvim-style review surface for Claude Code edits, built from existing pieces (sidekick, codediff, nvim_bridge, tmux). Three modes layered on a single snapshot ledger:

1. **Passive review** (default) — every Edit/Write/MultiEdit is logged with a pre-edit snapshot. `:ClaudeReview` walks them after the fact.
2. **Blocking review** (opt-in) — same hook, additionally pauses Claude and pops the diff in nvim for accept/reject.
3. **Prompt control** — `<leader>a{y,n,Y}` answers Claude's permission prompts from any nvim pane.

## Why DIY over the plugin

- Reuses `nvim_bridge.py` socket discovery, `codediff.nvim`, sidekick's tmux mux, gitsigns — no new abstractions.
- ~80 lines bash + ~60 lines Lua vs. an evolving third-party plugin coupled to neo-tree.
- The plugin's value is specifically that diffs land *in nvim* (searchable, jump-to-def, marks). Claude Code's native CLI prompt already shows a diff for blocking review; we want a richer post-hoc surface and we want it to integrate with the existing `<leader>a*` family.

Won't get: cross-backend adapters (OpenCode, Copilot CLI). Skip until needed.

## Architecture

```
PreToolUse (Edit|Write|MultiEdit)
        │
        ▼
~/.claude/scripts/snapshot-edit.sh
        │  - snapshot orig file (first touch per session) → /tmp/claude-snapshots/$SESSION/<hash>.<ext>
        │  - append ledger row → /tmp/claude-snapshots/$SESSION/ledger.tsv
        │  - if $CLAUDE_PREVIEW=block: open diff via nvim_bridge + emit permissionDecision=ask
        ▼
Claude proceeds (or waits, in block mode)

:ClaudeReview      ─── reads ledger.tsv, snacks picker → CodeDiff snapshot orig
<leader>a{y,n,Y}   ─── tmux capture-pane guard → state.session:send("1|2|3\n")

SessionEnd hook    ─── GC sessions older than N days
```

## Pieces

### 1. Snapshot hook — `~/.claude/scripts/snapshot-edit.sh`

Bash. Reads tool payload from stdin (Claude Code hook contract):

```json
{ "session_id": "...", "tool_name": "Edit|Write|MultiEdit",
  "tool_input": { "file_path": "...", ... } }
```

Behavior:
- `mkdir -p /tmp/claude-snapshots/$session_id`
- Hash `file_path` (`shasum | cut -c1-12`); snapshot path `$SNAP_DIR/$hash.<ext>`
- If snapshot doesn't exist yet: copy `file_path` → snapshot. (For `Write` of new files: `: > snapshot` so diff shows as added.)
- Append `\t`-separated row: `ts\ttool\tfile_path\tsnapshot_path` to `$SNAP_DIR/ledger.tsv`
- If `CLAUDE_PREVIEW=block`:
  - Compute proposed content into `$SNAP_DIR/$hash.proposed.<ext>` (apply Edit's `old_string→new_string`; for MultiEdit, walk `edits[]` in order; for Write, just `tool_input.content`)
  - Call `nvim_bridge.py cmd "tabnew | edit $proposed | diffthis | vsplit $orig | diffthis"`
  - Emit `{"hookSpecificOutput":{"permissionDecision":"ask"}}` to stdout, exit 0

Exit 0 always for passive mode.

### 2. settings.json hook entry — `~/.claude/settings.json`

```json
"hooks": {
  "PreToolUse": [
    {
      "matcher": "Edit|Write|MultiEdit",
      "hooks": [{ "type": "command", "command": "bash ~/.claude/scripts/snapshot-edit.sh" }]
    }
  ],
  "SessionEnd": [
    {
      "hooks": [{ "type": "command",
        "command": "find /tmp/claude-snapshots -mindepth 1 -maxdepth 1 -mtime +7 -exec rm -rf {} +" }]
    }
  ]
}
```

Toggle blocking mode per-shell: `export CLAUDE_PREVIEW=block` before launching Claude.

### 3. Reviewer — `lua/plugins/claude-review.lua`

New file. User command + keymap:

```lua
local function read_ledger(session_id)
  -- if session_id nil, list session dirs, pick most recent or all
  -- return list of { ts, tool, file_path, snapshot_path }
end

local function open_diff(entry)
  -- :CodeDiff <snapshot> <file_path>
  -- or fallback: :tabnew | edit <snapshot> | diffthis | vsplit <file_path> | diffthis
end

vim.api.nvim_create_user_command("ClaudeReview", function(opts)
  local entries = read_ledger(opts.args ~= "" and opts.args or nil)
  require("snacks.picker").pick({
    items = entries,
    format = function(e) return ("%s  %s  %s"):format(e.ts, e.tool, e.file_path) end,
    confirm = function(_, item) open_diff(item) end,
  })
end, { nargs = "?", desc = "Review Claude edits (optional session_id)" })
```

Bind under `<leader>aR` (review) in sidekick.lua's keys table to keep the `<leader>a*` family coherent.

`diffopt` tuning in `lua/config/options.lua` (LazyVim default is close):

```lua
vim.opt.diffopt:append({ "algorithm:histogram", "linematch:60", "indent-heuristic" })
```

### 4. Prompt-answer keymaps — additions to `lua/plugins/sidekick.lua`

Reuse `with_claude`. Add a guard helper:

```lua
local function claude_is_prompting(state)
  -- state.terminal has the tmux pane id; capture last ~20 lines
  local pane = state.terminal and state.terminal.pane_id  -- inspect actual field
  if not pane then return true end  -- no guard available, fall through
  local out = vim.fn.system({ "tmux", "capture-pane", "-p", "-t", pane, "-S", "-30" })
  return out:match("Do you want") and out:match("1%.%s*Yes")
end

local function answer(choice)
  return function()
    with_claude(function(state)
      if not claude_is_prompting(state) then
        vim.notify("Claude isn't prompting", vim.log.levels.WARN)
        return
      end
      state.session:send(choice .. "\n")
    end)
  end
end
```

Add to `keys`:

```lua
{ "<leader>ay", answer("1"), desc = "Claude: Yes" },
{ "<leader>an", answer("2"), desc = "Claude: No" },
{ "<leader>aY", answer("3"), desc = "Claude: Yes don't ask again" },
```

Inspect the actual sidekick state shape — `state.terminal` may not expose `pane_id` directly; may need `state.terminal:pane_id()` or to walk `state.session`. Verify before relying on the guard; fall back to no-guard for `y`/`n`, keep guard mandatory for `Y`.

## Edge cases

- **MultiEdit**: snapshot once on first edit; ledger rows count = number of MultiEdit invocations, not edits within. Fine — review surface is per-tool-call.
- **Rename / delete**: Edit/Write don't rename. If Claude uses Bash to `mv` a file, this hook misses it. Acceptable — gitsigns covers external moves.
- **Write of new file**: snapshot is empty file; diff shows as added. Reviewer should label these.
- **Same file edited many times**: snapshot is set on first touch, so diff always shows total drift from session start, not per-edit. That's the right default for post-hoc review. If you want per-edit granularity, snapshot every time and key by `ts`.
- **Snapshot dir growth**: SessionEnd GC handles 7+ day old. Tune as needed.
- **Files outside cwd / outside any project**: still works, snapshot is keyed on absolute path hash.

## Optional next steps

- Add a `:ClaudeReviewLast` shortcut → diffs the most recent ledger entry without picker.
- Sign column indicator: when a buffer's path matches a ledger entry, show a custom sign (separate from gitsigns) so you know Claude touched it this session.
- `CLAUDE_PREVIEW=block` per-tool: e.g. block on Write only, passive on Edit. Implement by reading `tool_name` in the hook and matching against a comma-separated env var.
- Status-line indicator: count of un-reviewed ledger entries for the current session.

## Files to touch

- New: `~/.claude/scripts/snapshot-edit.sh`
- New: `~/.config/nvim/lua/plugins/claude-review.lua`
- Edit: `~/.claude/settings.json` (add PreToolUse + SessionEnd entries)
- Edit: `~/.config/nvim/lua/plugins/sidekick.lua` (add 3 keymaps + guard helper)
- Edit: `~/.config/nvim/lua/config/options.lua` (diffopt tweak — verify it isn't already set)
