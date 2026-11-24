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
  "past:p", "a:old:tL", "t5", "p:q", "unassigned", "t4" }), vim.inspect(keys(nodes)))
-- SD was killed (rec.dead) and owns only an archived thread: dismissed from Past unless show_archived
assert(vim.tbl_contains(vim.tbl_map(function(n) return n.key end, run(true)), "a:SD"))
local by = {}
for _, n in ipairs(nodes) do by[n.key] = n end
assert(by["p:p"].counts.needs_you == 1, vim.inspect(by["p:p"].counts))
assert(by["a:SF"].fork == "continue" and by["a:SF"].depth == 2 and by["a:SF"].live)
assert(by["a:SL2"].name == "lilt-9" and by["a:SL2"].live, vim.inspect(by["a:SL2"]))  -- RF5: one row
assert(#by["a:SL2"].children == 0, "earlier session's thread on the live agent")
assert(by["a:old:tL"].name == "lilt-9 · earlier session" and not by["a:old:tL"].live)
assert(tree.owner_key(threads[1]) == "SA")
assert(not vim.tbl_contains(keys(nodes), "t3"), "t3 shown without show_archived")
assert(vim.tbl_contains(keys(run(true)), "t3"), "t3 missing with show_archived")
-- m: a moved record wins over the workspace label
local moved = vim.deepcopy(registry)
moved.p.SA = vim.tbl_extend("force", moved.p.SA, { project = "q", moved = true })
local mk = keys(run(false, moved))
assert(vim.fn.index(mk, "a:SA") > vim.fn.index(mk, "p:q"), vim.inspect(mk))
-- the move record lives in the target's file; a target sorting before the source must still win (newest ts)
local moved2 = vim.deepcopy(registry)
moved2.a = { SA = vim.tbl_extend("force", registry.p.SA, { project = "a", moved = true, ts = 9 }) }
local mk2 = vim.tbl_map(function(n) return n.key end, tree.build({ threads = threads, agents = agents, registry = moved2,
  projects = { { name = "a" }, { name = "p" }, { name = "q" } } }))
assert(vim.fn.index(mk2, "a:SA") > vim.fn.index(mk2, "p:a") and vim.fn.index(mk2, "a:SA") < vim.fn.index(mk2, "p:p"), vim.inspect(mk2))
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
-- I3: a rename after m (move) keeps the move: written to the session's newest record's project, moved kept
require("cockpit.projects").save({ name = "q21", repos = { vim.env.T .. "/q21" } })
registry.append("lilt", { name = "lilt-5", project = "lilt", terminal_id = "tV", session = "V1" })
registry.append("q21", { name = "lilt-5", project = "q21", terminal_id = "tV", session = "V1", moved = true })
cache.v = { name = "lilt-5", target = "lilt-5", project = "lilt", terminal_id = "tV", session_id = "V1", tab_id = "w1:t5",
  title = "ENG-777 views", status = "idle" }
h.learn()
local newest = registry.find_session("V1")
assert(newest and newest.name == "eng-777" and newest.project == "q21" and newest.moved, vim.inspect(newest))
-- I2: X / m on an "earlier session" row never write a registry record (the synthetic rec is display-only)
local rail, store = require("cockpit.inbox.rail"), require("cockpit.inbox.store")
vim.fn.mkdir(store.path("threads"), "p")
store.append(store.thread_file("old21"), { kind = "message", text = "x", ts = 1, session = { herdr = { terminal_id = "tL" } } })
local before = vim.deepcopy(registry.by_terminal("lilt", "tL"))
local old = { kind = "agent", akey = "old:tL", terminal_id = "tL", live = false, name = "eng-35131 · earlier session",
  rec = { name = "eng-35131 · earlier session", terminal_id = "tL", project = "lilt" } }
vim.fn.confirm = function() return 1 end
rail.kill_agent(old)
assert(store.thread("old21").archived, "earlier session's thread not archived")
assert(vim.deep_equal(registry.by_terminal("lilt", "tL"), before), "X wrote a record: " .. vim.inspect(registry.by_terminal("lilt", "tL")))
vim.ui.select = function(_, _, cb) cb("q21") end
rail.move_agent(old)
assert(vim.deep_equal(registry.by_terminal("lilt", "tL"), before) and not registry.by_terminal("q21", "tL"), "m wrote a record")
print("T21 OK")
LUA
  nlua "$T/t21.lua" 2>&1 | tee "$T/t21.out" | grep -q "T21 OK" || { cat "$T/t21.out"; fail "section 21"; }
  ok "learn(): /clear appends the seat's new session; ENG title renames agent + tab once; noise and hand-set names untouched"
fi

# --- 23: project creation from new / existing worktrees -------------------------------------------------
if want 23; then
  echo "23: worktree projects"
  R=$T/repo23
  git init -q "$R" && git -C "$R" commit -q --allow-empty -m init
  git -C "$R" worktree add -q "$T/repo23-34500" -b eng/ENG-34500-filters 2>/dev/null
  cat >"$T/t23.lua" <<'LUA'
local T = vim.env.T
local projects = require("cockpit.projects")
local R = T .. "/repo23"
local plan = projects.worktree_plan(R, "ENG-35131", "slack-poc")
assert(plan.path == R .. "-35131" and plan.branch == "eng/ENG-35131-slack-poc", vim.inspect(plan))
vim.fn.mkdir(R .. "-35131", "p")
assert(projects.worktree_plan(R, "ENG-35131", "slack-poc").path == R .. "-35131-slack-poc")
assert(projects.worktree_plan(R, nil, "spike").path == R .. "-spike" and projects.worktree_plan(R, nil, "spike").branch == "eng/spike")
vim.fn.delete(R .. "-35131", "d")
local wts = projects.list_worktrees(R)
assert(#wts == 1 and wts[1].path == vim.uv.fs_realpath(T .. "/repo23-34500") and wts[1].branch == "eng/ENG-34500-filters", vim.inspect(wts))
-- New worktree, end to end through the prompts
local selects = { "New worktree", R }
local inputs = { "ENG-35131", "slack-poc", "" } -- key, slug, name (empty = slug)
vim.ui.select = function(_, _, cb) cb(table.remove(selects, 1)) end
vim.ui.input = function(_, cb) cb(table.remove(inputs, 1)) end
local made
projects.new(function(p) made = p end)
assert(made and made.name == "slack-poc", vim.inspect(made))
assert(made.repos[1] == R .. "-35131" and made.ticket == "ENG-35131", vim.inspect(made))
local br = vim.trim(vim.system({ "git", "-C", R .. "-35131", "branch", "--show-current" }, { text = true }):wait().stdout)
assert(br == "eng/ENG-35131-slack-poc", br)
-- Existing worktrees: multi-select, ticket from the first one's branch
selects = { "Existing worktrees", R, vim.uv.fs_realpath(T .. "/repo23-34500"), "✓ done" }
inputs = { "contextdb-ui" }
made = nil
projects.new(function(p) made = p end)
assert(made and made.name == "contextdb-ui" and made.ticket == "ENG-34500", vim.inspect(made))
-- add-worktree appends to an existing project
selects = { "New worktree", R }
inputs = { "ENG-34501", "saved-views" }
projects.add_worktree("contextdb-ui")
local p = projects.get("contextdb-ui")
assert(#p.repos == 2 and p.repos[2] == R .. "-34501", vim.inspect(p.repos))
print("T23 OK")
LUA
  nlua "$T/t23.lua" 2>&1 | tee "$T/t23.out" | grep -q "T23 OK" || { cat "$T/t23.out"; fail "section 23"; }
  ok "worktree_plan paths/branches; new-worktree and existing-worktrees projects; add-worktree appends"
fi

# --- 25: backfill-sessions tags legacy threads with the Claude session that posted them -------------------
if want 25; then
  echo "25: backfill-sessions"
  export COCKPIT_INBOX_DIR=$T/inbox25 # own inbox: earlier sections leave threads behind
  mkdir -p "$COCKPIT_CLAUDE_DIR/projects/x" "$COCKPIT_INBOX_DIR/threads"
  echo '{}' >"$COCKPIT_CLAUDE_DIR/projects/x/1077c886-aaaa.jsonl"
  echo '{"text":"posted 20261124-070847-eng-35131-spec ok"}' >"$COCKPIT_CLAUDE_DIR/projects/x/8737f883-bbbb.jsonl"
  for id in session-1077c886 20261124-070847-eng-35131-spec lonely; do
    echo '{"v":1,"ts":1,"kind":"message","from":"agent","text":"x","session":{"herdr":{"terminal_id":"tL"},"pid":1}}' \
      >"$COCKPIT_INBOX_DIR/threads/$id.jsonl"
  done
  python3 "$CLI" backfill-sessions --dry-run >"$T/bf.out"
  grep -q "session-1077c886 -> 1077c886-aaaa" "$T/bf.out" || { cat "$T/bf.out"; fail "dry-run output"; }
  [ "$(cat "$COCKPIT_INBOX_DIR"/threads/*.jsonl | wc -l)" -eq 3 ] || fail "dry-run wrote"
  python3 "$CLI" backfill-sessions >/dev/null
  cat >"$T/t25.lua" <<'LUA'
local store = require("cockpit.inbox.store")
assert(store.owner_session(store.thread("session-1077c886")) == "1077c886-aaaa")
assert(store.owner_session(store.thread("20261124-070847-eng-35131-spec")) == "8737f883-bbbb")
assert(store.owner_session(store.thread("lonely")) == nil)
assert(store.thread("session-1077c886").owner.herdr.terminal_id == "tL", "seat lost")
print("T25 OK")
LUA
  nlua "$T/t25.lua" 2>&1 | tee "$T/t25.out" | grep -q "T25 OK" || { cat "$T/t25.out"; fail "section 25"; }
  before=$(cat "$COCKPIT_INBOX_DIR"/threads/*.jsonl | wc -l)
  python3 "$CLI" backfill-sessions >/dev/null
  [ "$(cat "$COCKPIT_INBOX_DIR"/threads/*.jsonl | wc -l)" -eq "$before" ] || fail "second run appended"
  ok "backfill: session-<8hex> and transcript search tag legacy threads; unmatched untouched; idempotent; dry-run writes nothing"
fi

echo "model smoke: all requested sections passed"
