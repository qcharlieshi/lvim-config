#!/usr/bin/env bash
# Happy-path smoke test for cockpit step 1 (herdr runtime + projects).
# Runs against a throwaway herdr session `ckspike` with an isolated inbox and projects dir.
# Starts real Claude agents in ~/.config/nvim (an already-trusted folder): costs a few tokens.
# Usage: bash scripts/cockpit-smoke-herdr.sh [last-section]   (default: all)
set -euo pipefail

NVIM_CFG=$(cd "$(dirname "$0")/.." && pwd)
CLI="$NVIM_CFG/scripts/cockpit_inbox.py"
LAST=${1:-99}
T=$(mktemp -d /tmp/ck.XXXX) # short path: macOS unix sockets max 104 chars
export COCKPIT_INBOX_DIR=$T/inbox COCKPIT_PROJECTS_DIR=$T/projects COCKPIT_HERDR_SESSION=ckspike
H=(herdr --session ckspike)

cleanup() {
  "${H[@]}" server stop >/dev/null 2>&1 || true
  herdr --session ckdead server stop >/dev/null 2>&1 || true
  sleep 1
  herdr session delete ckspike >/dev/null 2>&1 || true
  herdr session delete ckdead >/dev/null 2>&1 || true
  rm -rf "$T"
}
trap cleanup EXIT

ok() { printf '  ✓ %s\n' "$*"; }
fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}
jget() { python3 -c 'import sys,json; d=json.load(sys.stdin); exec("print(" + sys.argv[1] + ")")' "$1"; }
thread_file() { ls "$COCKPIT_INBOX_DIR"/threads/*-"$1".jsonl 2>/dev/null | head -1; }
# Run a lua file in headless nvim with this config on the rtp (no user config, no plugins)
nlua() { nvim --headless -u NONE -i NONE --cmd "set rtp^=$NVIM_CFG" -l "$1"; }

# --- server -------------------------------------------------------------------------------
env -u TMUX -u TMUX_PANE "${H[@]}" server >"$T/server.log" 2>&1 &
up() { [[ $("${H[@]}" status server 2>/dev/null) == *"status: running"* ]]; }
for _ in $(seq 20); do up && break; sleep 0.5; done
up || fail "ckspike server did not start"

# --- 1: posted threads carry herdr identity + project -------------------------------------
echo "1: agent-side herdr identity"
P=$("${H[@]}" workspace create --cwd "$NVIM_CFG" | jget 'd["result"]["root_pane"]["pane_id"]')
sleep 1
"${H[@]}" pane run "$P" "COCKPIT_PROJECT=smoke python3 $CLI post --title s1 --text hi" >/dev/null
"${H[@]}" pane wait-output "$P" --match '-s1' --timeout 10000 >/dev/null
F=$(thread_file s1)
[ -n "$F" ] || fail "thread s1 not written"
head -1 "$F" | python3 -c '
import sys, json
e = json.loads(sys.stdin.readline())
h = e["session"]["herdr"]
assert h["pane_id"] == sys.argv[1], h
assert h["terminal_id"].startswith("term_"), h
assert e["project"] == "smoke", e["project"]
' "$P" || fail "s1 identity/project"
ok "s1 has herdr.pane_id, terminal_id, project=smoke"

"${H[@]}" pane run "$P" "python3 $CLI post --title s1b --text hi" >/dev/null
"${H[@]}" pane wait-output "$P" --match '-s1b' --timeout 10000 >/dev/null
head -1 "$(thread_file s1b)" | python3 -c '
import sys, json
e = json.loads(sys.stdin.readline())
assert "herdr" in e["session"], e["session"]
assert e["project"] == "nvim", e["project"]
' || fail "s1b fallback project"
ok "no COCKPIT_PROJECT -> project_of(cwd)=nvim, herdr block still recorded"
[ "$LAST" -le 1 ] && exit 0

echo "all sections passed"
