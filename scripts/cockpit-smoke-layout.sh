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

# --- 22: spawn = one tab per agent in ck/<project>, named after the ticket; kill closes the tab ------------
if want 22; then
  echo "22: tab per agent + ticket names"
  cat >"$T/t22.lua" <<'LUA'
dofile(vim.env.T .. "/prelude.lua")
local h, projects = require("cockpit.herdr"), require("cockpit.projects")
projects.save({ name = "l22", repos = { vim.env.NVIM_CFG }, ticket = "ENG-99998" })
h.start(); h.watch(true)
local e1, n1, p1, t1 = await(function(cb) h.spawn("l22", nil, cb) end)
assert(not e1, vim.inspect(e1))
local e2, n2, p2, t2 = await(function(cb) h.spawn("l22", nil, cb) end)
assert(not e2, vim.inspect(e2))
assert(n1 == "eng-99998" and n2 == "eng-99998-2", n1 .. " / " .. n2) -- RF4: no clash
assert(t1 and t2 and t1 ~= t2, "not separate tabs: " .. tostring(t1) .. " " .. tostring(t2))
local _, wl = h.request("workspace.list", {})
local ws = vim.iter(wl.workspaces):find(function(w) return w.label == "ck/l22" end)
assert(ws, "no ck/l22 workspace")
local _, tl = h.request("tab.list", { workspace_id = ws.workspace_id })
local labels = vim.tbl_map(function(t) return t.label end, tl.tabs)
assert(vim.deep_equal(labels, { "shell", "eng-99998", "eng-99998-2" }), vim.inspect(labels))
for _, t in ipairs(tl.tabs) do assert(t.pane_count == 1, "tab " .. t.label .. " has " .. t.pane_count .. " panes") end
assert(h.agents()[n1].tab_id == t1 and h.agents()[n1].pane_id == p1, vim.inspect(h.agents()[n1]))
assert(h.kill(n2) == nil, "kill errored")
_, tl = h.request("tab.list", { workspace_id = ws.workspace_id })
labels = vim.tbl_map(function(t) return t.label end, tl.tabs)
assert(vim.deep_equal(labels, { "shell", "eng-99998" }), "after kill: " .. vim.inspect(labels))
h.kill(n1)
print("T22 OK")
LUA
  nlua "$T/t22.lua" 2>&1 | tee "$T/t22.out" | grep -q "T22 OK" || { cat "$T/t22.out"; fail "section 22"; }
  ok "spawn: ck/l22 has tabs shell, eng-99998, eng-99998-2 (one pane each); kill closes the agent's tab"
fi

# --- 24: rail N = fresh conversation (new tab, same dir); m = move the agent to another project -----------
if want 24; then
  echo "24: rail N fresh + m move"
  cat >"$T/t24.lua" <<'LUA'
dofile(vim.env.T .. "/prelude.lua")
local h, projects, tree = require("cockpit.herdr"), require("cockpit.projects"), require("cockpit.inbox.tree")
require("cockpit.inbox").setup()
local rail = require("cockpit.inbox.rail")
projects.save({ name = "l24", repos = { vim.env.NVIM_CFG } })
projects.save({ name = "q24", repos = { vim.env.T .. "/q24" } })
h.start(); h.watch(true)
local err, name, _, tab = await(function(cb) h.spawn("l24", nil, cb) end)
assert(not err, vim.inspect(err))
local old = h.agents()[name]
local function node_of(sid)
  return vim.iter(tree.build({})):find(function(n) return n.key == "a:" .. sid end)
end
assert(vim.wait(10000, function() return node_of(old.session_id) ~= nil end, 200), "no rail node for " .. name)
vim.fn.confirm = function() return 1 end
rail.fresh_agent(node_of(old.session_id))
local fresh
assert(vim.wait(120000, function()
  for _, a in pairs(h.agents()) do
    if a.project == "l24" and a.session_id and a.session_id ~= old.session_id and a.status == "idle" then fresh = a end
  end
  return fresh ~= nil and h.agents()[name] == nil
end, 300), "no fresh agent / old one still live: " .. vim.inspect(h.agents()))
assert(fresh.tab_id ~= tab, "fresh agent reused the old tab")
assert(vim.fn.resolve(fresh.cwd) == vim.fn.resolve(old.cwd), "fresh agent in " .. tostring(fresh.cwd))
local _, tl = h.request("tab.list", { workspace_id = fresh.workspace_id })
assert(not vim.iter(tl.tabs):any(function(t) return t.tab_id == tab end), "old tab still open")
-- m: move the fresh agent to q24
vim.ui.select = function(items, _, cb) cb("q24") end
assert(vim.wait(10000, function() return node_of(fresh.session_id) ~= nil end, 200), "fresh agent not in rail")
rail.move_agent(node_of(fresh.session_id))
local keys = vim.tbl_map(function(n) return n.key end, tree.build({}))
local pq, ak = vim.fn.index(keys, "p:q24"), vim.fn.index(keys, "a:" .. fresh.session_id)
assert(pq >= 0 and ak > pq, "not moved under q24: " .. vim.inspect(keys))
h.kill(fresh.name)
print("T24 OK")
LUA
  nlua "$T/t24.lua" 2>&1 | tee "$T/t24.out" | grep -q "T24 OK" || { cat "$T/t24.out"; fail "section 24"; }
  ok "N: old tab closed, fresh agent in the same dir with a new session; m: agent moves to q24 in the rail"
fi

echo "layout smoke: all requested sections passed"
