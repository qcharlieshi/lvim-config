#!/usr/bin/env bash
# Live smoke tests for projects / session identity / herdr tab layout (spec 2026-11-24). Self-contained:
# own throwaway herdr session `cklayout`, isolated inbox + projects. Starts real Claude agents in this
# checkout (an already-trusted folder): costs a few tokens.
# Usage: bash scripts/cockpit-smoke-layout.sh [section ...]   (default: all)
set -euo pipefail

export NVIM_CFG=$(cd "$(dirname "$0")/.." && pwd)
CLI="$NVIM_CFG/scripts/cockpit_inbox.py"
T=$(mktemp -d /tmp/ckl.XXXX) # short path: macOS unix sockets max 104 chars
export T CLI COCKPIT_INBOX_DIR=$T/inbox COCKPIT_PROJECTS_DIR=$T/projects COCKPIT_HERDR_SESSION=cklayout COCKPIT_INBOX_HOOK=0
# run from inside a herdr pane (an agent), the CLI would talk to that server, not cklayout
unset HERDR_SOCKET_PATH HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID TMUX TMUX_PANE COCKPIT_PROJECT
H=(herdr --session cklayout)
SECTIONS="$*"

cleanup() {
  "${H[@]}" server stop >/dev/null 2>&1 || true
  sleep 1
  herdr session delete cklayout >/dev/null 2>&1 || true
  rm -rf "$T"
}
trap cleanup EXIT

ok() { printf '  ✓ %s\n' "$*"; }
fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}
want() { [ -z "$SECTIONS" ] || [[ " $SECTIONS " == *" $1 "* ]]; }
nlua() { nvim --headless -u NONE -i NONE --cmd "set rtp^=$NVIM_CFG" -l "$1"; }
# shared lua prelude: await(fn, ms) runs fn(cb) and waits for cb's args
cat >"$T/prelude.lua" <<'LUA'
function await(fn, ms)
  local got
  fn(function(...) got = { ... } end)
  assert(vim.wait(ms or 180000, function() return got ~= nil end, 50), "timed out")
  return unpack(got)
end
LUA

"${H[@]}" server stop >/dev/null 2>&1 || true
sleep 1
herdr session delete cklayout >/dev/null 2>&1 || true
"${H[@]}" server >"$T/server.log" 2>&1 &
up() { [[ $("${H[@]}" status server 2>/dev/null) == *"status: running"* ]]; }
for _ in $(seq 20); do up && break; sleep 0.5; done
up || fail "cklayout server did not start"

# --- 21: /clear in a live agent -> reconcile records the seat's new session (earlier one -> Past) ---------
if want 21; then
  echo "21: live session change"
  cat >"$T/t21.lua" <<'LUA'
dofile(vim.env.T .. "/prelude.lua")
local h, registry, projects, tree = require("cockpit.herdr"), require("cockpit.registry"), require("cockpit.projects"), require("cockpit.inbox.tree")
projects.save({ name = "l21", repos = { vim.env.NVIM_CFG } })
h.start(); h.watch(true)
local err, name = await(function(cb) h.spawn("l21", nil, cb) end)
assert(not err, vim.inspect(err))
local a = h.agents()[name]
local s1 = a.session_id
assert(s1, "no session_id in cache: " .. vim.inspect(a))
assert(vim.wait(10000, function() local r = registry.by_terminal("l21", a.terminal_id); return r and r.session == s1 end, 200),
  "registry never learned " .. s1 .. ": " .. vim.inspect(registry.by_terminal("l21", a.terminal_id)))
-- /clear: same pane, same process, new session
h.request("agent.prompt", { target = name, text = "/clear" })
assert(vim.wait(30000, function() local x = h.agents()[name]; return x and x.session_id and x.session_id ~= s1 end, 300),
  "session never changed after /clear")
local s2 = h.agents()[name].session_id
assert(vim.wait(10000, function() return registry.by_terminal("l21", a.terminal_id).session == s2 end, 200), "new session not learned")
assert(registry.all("l21")[s1], "earlier session record gone")
local keys = vim.tbl_map(function(n) return n.key end, tree.build({}))
assert(vim.tbl_contains(keys, "a:" .. s2) and vim.tbl_contains(keys, "a:" .. s1), vim.inspect(keys))
assert(vim.fn.index(keys, "a:" .. s1) > vim.fn.index(keys, "past:l21"), "earlier session not under Past: " .. vim.inspect(keys))
h.kill(name)
print("T21 OK")
LUA
  nlua "$T/t21.lua" 2>&1 | tee "$T/t21.out" | grep -q "T21 OK" || { cat "$T/t21.out"; fail "section 21"; }
  ok "/clear in a live agent: reconcile learns the new session; the earlier one is under Past"
fi

echo "layout smoke: all requested sections passed"
