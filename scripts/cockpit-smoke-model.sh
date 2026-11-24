#!/usr/bin/env bash
# Fixture-only cockpit tests: no herdr server, no Claude. Runs in seconds.
# Usage: bash scripts/cockpit-smoke-model.sh [section ...]   (default: all)
set -euo pipefail

NVIM_CFG=$(cd "$(dirname "$0")/.." && pwd)
CLI="$NVIM_CFG/scripts/cockpit_inbox.py"
T=$(mktemp -d /tmp/ckm.XXXX)
export COCKPIT_INBOX_DIR=$T/inbox COCKPIT_PROJECTS_DIR=$T/projects COCKPIT_CLAUDE_DIR=$T/claude COCKPIT_INBOX_HOOK=0
unset COCKPIT_PROJECT TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_SOCKET_PATH HERDR_TAB_ID HERDR_WORKSPACE_ID
trap 'rm -rf "$T"' EXIT

ok() { printf '  ✓ %s\n' "$*"; }
fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}
thread_file() { ls "$COCKPIT_INBOX_DIR"/threads/*-"$1".jsonl 2>/dev/null | head -1; }
nlua() { T=$T nvim --headless -u NONE -i NONE --cmd "set rtp^=$NVIM_CFG" -l "$1"; }
want() { [ $# -eq 0 ] || [ -z "${SECTIONS:-}" ] || [[ " $SECTIONS " == *" $1 "* ]]; }
SECTIONS="$*"

# --- 19: tickets + project-for-dir by longest containing dir -------------------------------------------
if want 19; then
  echo "19: tickets + project containment"
  mkdir -p "$T/org/lilt-mcp-35131/src" "$T/org/core" "$T/elsewhere"
  cat >"$T/t19.lua" <<'LUA'
local T = vim.env.T
local projects, ticket = require("cockpit.projects"), require("cockpit.ticket")
projects.save({ name = "lilt", repos = { T .. "/org" } })
projects.save({ name = "slack-poc", repos = { T .. "/org/lilt-mcp-35131" } })
assert(projects.containing(T .. "/org/lilt-mcp-35131/src") == "slack-poc", projects.containing(T .. "/org/lilt-mcp-35131/src"))
assert(projects.containing(T .. "/org/core") == "lilt")
assert(projects.containing(T .. "/elsewhere") == nil)
assert(projects.for_dir(T .. "/org/lilt-mcp-35131") == "slack-poc")
assert(ticket.find("ENG-35131 Slack assist POC") == "ENG-35131")
assert(ticket.find("eng/ENG-34500-context-filter") == "ENG-34500")
assert(ticket.find("GPT-5 vs UTF-8 and SHA-256") == nil)
assert(ticket.slug("ENG-35131") == "eng-35131")
assert(ticket.for_dir(T .. "/org/lilt-mcp-35131") == "ENG-35131", ticket.for_dir(T .. "/org/lilt-mcp-35131"))
projects.save({ name = "t", repos = { T .. "/org" }, ticket = "ENG-1" })
assert(projects.get("t").ticket == "ENG-1")
print("T19 OK")
LUA
  nlua "$T/t19.lua" 2>&1 | tee "$T/t19.out" | grep -q "T19 OK" || { cat "$T/t19.out"; fail "section 19 (lua)"; }
  (cd "$T/org/lilt-mcp-35131/src" && python3 "$CLI" post --title s19 --text x >/dev/null)
  head -1 "$(thread_file s19)" | python3 -c '
import sys, json
e = json.loads(sys.stdin.readline())
assert e["project"] == "slack-poc", e["project"]
' || fail "section 19 (post project)"
  ok "ticket keys (ENG only), longest-containing project, project.ticket persisted, post uses containment"
fi

# --- 20: session identity — registry keyed by session, owner events, CLI records the Claude session ------
if want 20; then
  echo "20: session identity"
  cat >"$T/t20.lua" <<'LUA'
local registry, store = require("cockpit.registry"), require("cockpit.inbox.store")
registry.append("p", { name = "lilt-9", project = "p", terminal_id = "tX" }) -- legacy: no session
registry.append("p", { name = "lilt-9", project = "p", terminal_id = "tX", session = "S2" })
registry.append("p", { name = "other", project = "p", terminal_id = "tY" }) -- legacy, never learned
local all = registry.all("p")
assert(all.S2 and not all.tX, vim.inspect(all))
assert(all.tY and all.tY.name == "other", vim.inspect(all))
assert(registry.by_terminal("p", "tX").session == "S2")
assert(registry.key({ terminal_id = "t", session = "s" }) == "s" and registry.key({ terminal_id = "t" }) == "t")
-- an owner event overrides the first message's session
vim.fn.mkdir(store.path("threads"), "p")
store.append(store.thread_file("o1"), { kind = "message", text = "x", session = { pid = 1 } })
assert(store.owner_session(store.thread("o1")) == nil)
store.append(store.thread_file("o1"), { kind = "owner", session = { session_id = "S1" } })
assert(store.owner_session(store.thread("o1")) == "S1", vim.inspect(store.thread("o1").owner))
store.append(store.thread_file("o2"), { kind = "message", text = "x", session = { herdr = { session_id = "H1" } } })
assert(store.owner_session(store.thread("o2")) == "H1")
print("T20 OK")
LUA
  nlua "$T/t20.lua" 2>&1 | tee "$T/t20.out" | grep -q "T20 OK" || { cat "$T/t20.out"; fail "section 20 (lua)"; }
  # Review Focus 2: posted from the Bash tool, python's parent is a shell, not Claude: walk up to the Claude pid
  mkdir -p "$COCKPIT_CLAUDE_DIR/sessions"
  bash -c 'echo "{\"pid\": $$, \"sessionId\": \"sess-fake\"}" >"$COCKPIT_CLAUDE_DIR/sessions/$$.json"
    bash -c "cd \"$1\" && python3 \"$2\" post --title s20 --text x >/dev/null"' _ "$T" "$CLI"
  head -1 "$(thread_file s20)" | python3 -c '
import sys, json
e = json.loads(sys.stdin.readline())
assert e["session"]["session_id"] == "sess-fake", e["session"]
' || fail "section 20 (CLI session_id)"
  ok "registry keyed by session (legacy superseded), owner events win, CLI finds the Claude session via ancestors"
fi

echo "model smoke: all requested sections passed"
