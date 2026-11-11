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

# --- 2: nvim herdr client — live agent cache + ensure() --------------------------------------
echo "2: herdr.lua agent cache"
P2=$("${H[@]}" pane split "$P" --direction right --cwd "$NVIM_CFG" --no-focus | jget 'd["result"]["pane"]["pane_id"]')
sleep 1
"${H[@]}" agent start smoke-1 --kind claude --pane "$P2" --timeout 60000 >/dev/null || fail "agent start smoke-1"
cat >"$T/t2.lua" <<'LUA'
local h = require("cockpit.herdr")
local fired = 0
vim.api.nvim_create_autocmd("User", { pattern = "CockpitAgents", callback = function() fired = fired + 1 end })
h.start()
assert(vim.wait(5000, function() return h.agents()["smoke-1"] ~= nil end), "smoke-1 never reached the cache")
local a = h.agents()["smoke-1"]
assert(a.status == "idle", "status " .. tostring(a.status))
assert(a.terminal_id:match("^term_"), "terminal_id " .. tostring(a.terminal_id))
assert(h.by_terminal(a.terminal_id).name == "smoke-1", "by_terminal")
assert(fired >= 1, "CockpitAgents never fired")
h.stop()
-- Review Focus 1: ensure() starts a server that is not running
vim.env.COCKPIT_HERDR_SESSION = "ckdead"
assert(h.ensure() == true, "ensure() did not start ckdead")
print("T2 OK")
LUA
nlua "$T/t2.lua" 2>&1 | tee "$T/t2.out" | grep -q "T2 OK" || { cat "$T/t2.out"; fail "section 2"; }
"${H[@]}" pane close "$P2" >/dev/null # frees the name smoke-1 for section 4
ok "cache sees smoke-1 idle with terminal_id; CockpitAgents fired; ensure() starts a dead server"
[ "$LAST" -le 2 ] && exit 0

echo "all sections passed"
