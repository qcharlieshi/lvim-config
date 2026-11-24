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

# --- 10: rail tree model — agents are Claude sessions ---------------------------------------------------
if want 10; then
  echo "10: tree model"
  cat >"$T/t10.lua" <<'LUA'
local tree = require("cockpit.inbox.tree")
local function ag(name, tid, sid, project)
  return { name = name, terminal_id = tid, session_id = sid, status = "idle", project = project }
end
-- live: A (SA), F fork of A (SF), L in seat tL running SL2 whose only record is legacy (no session)
local agents = { A = ag("A", "tA", "SA", "p"), F = ag("F", "tF", "SF", "p"), L = ag("lilt-9", "tL", "SL2", "p") }
local registry = { p = {
  SA = { name = "A", project = "p", terminal_id = "tA", session = "SA", ts = 1 },
  SF = { name = "F", project = "p", terminal_id = "tF", session = "SF", parent_session = "SA", parent_name = "A", fork = "continue", ts = 2 },
  SD = { name = "D", project = "p", terminal_id = "tD", session = "SD", dead = true, ts = 0 },
  tL = { name = "lilt-9", project = "p", terminal_id = "tL", ts = 3 },
}, q = {} }
local function th(id, sid, term, status, archived)
  local owner = (sid or term) and { session_id = sid, herdr = term and { terminal_id = term } or nil } or nil
  return { id = id, title = id, status = status, archived = archived, last_ts = 1, owner = owner }
end
local threads = {
  th("t1", "SA", "tA", "needs_you"), th("t2", "SF", "tF", "read"), th("t3", "SD", "tD", "read", true),
  th("t5", nil, "tL", "read"), -- legacy thread from an earlier session in seat tL
  th("t4", nil, nil, "read"),
}
local function keys(nodes)
  return vim.tbl_map(function(n) return n.kind == "thread" and n.thread.id or n.key end, nodes)
end
local function run(show, reg)
  return tree.build({ show_archived = show, threads = threads, agents = agents, registry = reg or registry,
    projects = { { name = "p" }, { name = "q" } } })
end
local nodes = run(false)
assert(vim.deep_equal(keys(nodes), { "header", "p:p", "a:SA", "a:SF", "t2", "t1", "a:SL2",
  "past:p", "a:SD", "a:old:tL", "t5", "p:q", "unassigned", "t4" }), vim.inspect(keys(nodes)))
local by = {}
for _, n in ipairs(nodes) do by[n.key] = n end
assert(by["p:p"].counts.needs_you == 1, vim.inspect(by["p:p"].counts))
assert(by["a:SF"].fork == "continue" and by["a:SF"].depth == 2 and by["a:SF"].live)
assert(by["a:SL2"].name == "lilt-9" and by["a:SL2"].live, vim.inspect(by["a:SL2"]))  -- RF5: one row
assert(#by["a:SL2"].children == 0, "earlier session's thread on the live agent")
assert(by["a:old:tL"].name == "lilt-9 · earlier session" and not by["a:old:tL"].live)
assert(by["a:SD"].live == false and by["a:SD"].depth == 2)
assert(tree.owner_key(threads[1]) == "SA")
assert(not vim.tbl_contains(keys(nodes), "t3"), "t3 shown without show_archived")
assert(vim.tbl_contains(keys(run(true)), "t3"), "t3 missing with show_archived")
-- m: a moved record wins over the workspace label
local moved = vim.deepcopy(registry)
moved.p.SA = vim.tbl_extend("force", moved.p.SA, { project = "q", moved = true })
local mk = keys(run(false, moved))
assert(vim.fn.index(mk, "a:SA") > vim.fn.index(mk, "p:q"), vim.inspect(mk))
print("T10 OK")
LUA
  nlua "$T/t10.lua" 2>&1 | tee "$T/t10.out" | grep -q "T10 OK" || { cat "$T/t10.out"; fail "section 10"; }
  ok "tree: agents keyed by session; legacy seat record = one live row; earlier session -> Past; forks by parent_session; move wins"
fi

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

# --- 21: reconcile learns session changes; late rename to the ticket (herdr stubbed) ----------------------
if want 21; then
  echo "21: learn sessions + late rename"
  cat >"$T/t21.lua" <<'LUA'
local h, registry = require("cockpit.herdr"), require("cockpit.registry")
require("cockpit.projects").save({ name = "lilt", repos = { vim.env.T .. "/org21" } })
registry.append("lilt", { name = "lilt-9", project = "lilt", terminal_id = "tL", session = "S1" })
registry.append("lilt", { name = "mine", project = "lilt", terminal_id = "tM", session = "M1" })
local cache = {
  ["lilt-9"] = { name = "lilt-9", target = "lilt-9", project = "lilt", terminal_id = "tL", session_id = "S2",
    tab_id = "w1:t2", title = "GPT-5 notes", status = "idle" },
  mine = { name = "mine", target = "mine", project = "lilt", terminal_id = "tM", session_id = "M1",
    tab_id = "w1:t3", title = "ENG-1 hand named", status = "idle" },
}
h.agents = function() return cache end
local calls = {}
h.request = function(method, params, cb)
  calls[#calls + 1] = method .. " " .. (params.name or params.label or "")
  local res = method == "tab.get" and { tab = { label = "lilt-9" } } or {}
  if cb then return cb(nil, res) end
  return nil, res
end
h.learn()
local rec = registry.by_terminal("lilt", "tL")
assert(rec.session == "S2" and rec.name == "lilt-9", vim.inspect(rec)) -- /clear: the seat's new session is learned
assert(registry.all("lilt").S1, "earlier session record lost") -- stays for Past
assert(#calls == 0, "renamed on noise: " .. vim.inspect(calls)) -- RF3: GPT-5 is not a ticket
cache["lilt-9"].title = "ENG-35131 Slack assist POC"
h.learn()
assert(vim.tbl_contains(calls, "agent.rename eng-35131") and vim.tbl_contains(calls, "tab.rename eng-35131"), vim.inspect(calls))
rec = registry.by_terminal("lilt", "tL")
assert(rec.name == "eng-35131" and rec.renamed and rec.session == "S2", vim.inspect(rec))
calls = {}
cache["lilt-9"].name = "eng-35131"
h.learn()
assert(#calls == 0, "renamed twice: " .. vim.inspect(calls))
assert(registry.by_terminal("lilt", "tM").name == "mine") -- hand-set names are never touched
print("T21 OK")
LUA
  nlua "$T/t21.lua" 2>&1 | tee "$T/t21.out" | grep -q "T21 OK" || { cat "$T/t21.out"; fail "section 21"; }
  ok "learn(): /clear appends the seat's new session; ENG title renames agent + tab once; noise and hand-set names untouched"
fi

echo "model smoke: all requested sections passed"
