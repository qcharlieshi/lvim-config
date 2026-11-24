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

echo "model smoke: all requested sections passed"
