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

# --- 3: project definitions ----------------------------------------------------------------
echo "3: projects"
cat >"$T/t3.lua" <<'LUA'
local projects = require("cockpit.projects")
local picks = { vim.fn.expand("~/.config/nvim"), vim.fn.expand("~/dev/genzed"), "✓ done" }
vim.ui.input = function(_, cb) cb("smoke") end
vim.ui.select = function(_, _, cb) cb(table.remove(picks, 1)) end
projects.new()
local p = assert(projects.get("smoke"), "project smoke missing")
assert(vim.deep_equal(p.repos, { vim.fn.expand("~/.config/nvim"), vim.fn.expand("~/dev/genzed") }), vim.inspect(p.repos))
assert(vim.fn.filereadable(vim.env.COCKPIT_PROJECTS_DIR .. "/smoke/project.json") == 1, "smoke/project.json not written")
assert(#projects.list() == 1 and projects.list()[1].name == "smoke", "list")
print("T3 OK")
LUA
nlua "$T/t3.lua" 2>&1 | tee "$T/t3.out" | grep -q "T3 OK" || { cat "$T/t3.out"; fail "section 3"; }
ok "projects.new() writes smoke/project.json with primary + extra repo"
[ "$LAST" -le 3 ] && exit 0

# --- 4: agent actions — spawn / prompt / interrupt / kill ---------------------------------------
echo "4: spawn/prompt/interrupt/kill"
mkdir -p "$T/untrusted" && git -C "$T/untrusted" init -q
# A pre-approved permission guarantees Claude's folder-trust dialog (matches the genzed case)
mkdir -p "$T/untrusted/.claude" && echo '{"permissions":{"allow":["Bash(true)"]}}' >"$T/untrusted/.claude/settings.local.json"
cat >"$T/t4.lua" <<'LUA'
local h, projects = require("cockpit.herdr"), require("cockpit.projects")
local function await(fn, ms) -- run fn(cb) and wait for cb's args
  local got
  fn(function(...) got = { ... } end)
  assert(vim.wait(ms or 90000, function() return got ~= nil end, 50), "timed out")
  return unpack(got)
end
local function gone(name) return vim.wait(10000, function() return h.agents()[name] == nil end, 100) end
h.start()
h.watch(true) -- the cockpit UI turns this on while open; startup idle flips emit no event

-- spawn into project smoke: own workspace labelled smoke, COCKPIT_PROJECT in the pane env
local err, name = await(function(cb) h.spawn("smoke", nil, cb) end)
assert(not err, vim.inspect(err))
assert(name == "smoke-1", "name " .. tostring(name))
assert(vim.wait(10000, function() local a = h.agents()[name]; return a and a.status == "idle" end), "smoke-1 not idle: " .. vim.inspect(h.agents()))
assert(h.agents()[name].project == "smoke", "project " .. tostring(h.agents()[name].project))
local perr = await(function(cb)
  h.request("agent.prompt", { target = name, text = "Run this bash command and reply with only its output: echo PROJ=$COCKPIT_PROJECT", wait = { timeout_ms = 90000 } }, cb)
end, 100000)
assert(not perr, vim.inspect(perr))
local _, read = h.request("agent.read", { target = name, source = "recent_unwrapped", lines = 60 })
assert(read and vim.inspect(read):find("PROJ=smoke", 1, true), "COCKPIT_PROJECT not in pane env")

assert(h.interrupt(name) == nil, "interrupt errored")
assert(h.kill(name) == nil, "kill errored")
assert(gone(name), "smoke-1 still in cache after kill")

-- Review Focus 2: untrusted folder -> blocked at startup, agent kept, attach offered
projects.save({ name = "untrusted", repos = { vim.env.T .. "/untrusted" } })
local offered
vim.ui.select = function(items, opts, cb) offered = opts.prompt; cb("Later") end
local uerr, uname = await(function(cb) h.spawn("untrusted", nil, cb) end)
assert(uerr and uerr.code == "agent_not_ready", vim.inspect(uerr))
assert(offered and offered:find("blocked", 1, true), "attach-now not offered")
assert(vim.wait(10000, function() local a = h.agents()[uname]; return a and a.status == "blocked" end), "not blocked")
h.kill(uname)

-- Review Focus 4: ad-hoc agent outside any project — visible, no project, never reused by spawn
local _, ws = h.request("workspace.create", { cwd = vim.env.NVIM_CFG, label = "adhoc-ws", focus = false })
vim.wait(1500)
local aerr = await(function(cb)
  h.request("agent.start", { name = "adhoc", kind = "claude", pane_id = ws.root_pane.pane_id, timeout_ms = 60000 }, cb)
end)
assert(not aerr, vim.inspect(aerr))
assert(vim.wait(10000, function() return h.agents().adhoc ~= nil end), "adhoc not cached")
assert(h.agents().adhoc.project == nil, "adhoc got a project")
local function panes(wid) return #(select(2, h.request("pane.list", { workspace_id = wid })).panes) end
local before = panes(ws.workspace.workspace_id)
local serr, sname = await(function(cb) h.spawn("smoke", nil, cb) end)
assert(not serr, vim.inspect(serr))
assert(panes(ws.workspace.workspace_id) == before, "spawn touched the ad-hoc workspace")
h.kill(sname); h.kill("adhoc")
print("T4 OK")
LUA
T=$T NVIM_CFG=$NVIM_CFG nlua "$T/t4.lua" 2>&1 | tee "$T/t4.out" | grep -q "T4 OK" || { cat "$T/t4.out"; fail "section 4"; }
ok "spawn into project (env + label), prompt, interrupt, kill; untrusted -> blocked + attach offer; ad-hoc agent left alone"
[ "$LAST" -le 4 ] && exit 0

# --- 5: reply delivery via agent.prompt ------------------------------------------------------
echo "5: delivery"
cat >"$T/t5.lua" <<'LUA'
local h, store = require("cockpit.herdr"), require("cockpit.inbox.store")
local function await(fn, ms)
  local got
  fn(function(...) got = { ... } end)
  assert(vim.wait(ms or 90000, function() return got ~= nil end, 50), "timed out")
  return unpack(got)
end
h.start(); h.watch(true)
local err, name = await(function(cb) h.spawn("smoke", nil, cb) end)
assert(not err, vim.inspect(err))
local cmd = ("python3 %s post --title s5 --text hi"):format(vim.env.CLI)
local perr = await(function(cb)
  h.request("agent.prompt", { target = name, text = "Run exactly this bash command, then reply done: " .. cmd, wait = { timeout_ms = 90000 } }, cb)
end, 100000)
assert(not perr, vim.inspect(perr))
local f = vim.fn.glob(store.path("threads", "*-s5.jsonl"), false, true)[1]
assert(f, "agent did not post s5")
local t = store.thread(vim.fn.fnamemodify(f, ":t:r"))
assert(t.session.herdr and t.session.herdr.terminal_id, "s5 has no herdr identity")
local how = store.deliver(t)
assert(how:find("^delivered"), "deliver returned: " .. how)
assert(vim.wait(60000, function()
  local _, r = h.request("agent.read", { target = name, source = "recent_unwrapped", lines = 80 })
  return r and vim.inspect(r):find("Inbox reply on thread", 1, true) ~= nil
end, 1000), "reply never reached the agent")
-- Review Focus 3: killed agent -> offline, never another pane
h.kill(name)
assert(vim.wait(10000, function() return h.by_terminal(t.session.herdr.terminal_id) == nil end), "still cached")
local how2 = store.deliver(t)
assert(how2:find("offline", 1, true), "deliver after kill returned: " .. how2)
print("T5 OK")
LUA
CLI=$CLI nlua "$T/t5.lua" 2>&1 | tee "$T/t5.out" | grep -q "T5 OK" || { cat "$T/t5.out"; fail "section 5"; }
ok "reply delivered to the herdr agent via agent.prompt; offline after kill"
[ "$LAST" -le 5 ] && exit 0

# --- 6: rail — agent status glyph + keys ------------------------------------------------------
echo "6: rail glyphs + keys"
cat >"$T/t6.lua" <<'LUA'
local h, store = require("cockpit.herdr"), require("cockpit.inbox.store")
require("cockpit.inbox").setup() -- starts herdr cache, commands, CockpitAgents -> rail refresh
local ui = require("cockpit.inbox.ui")
local function await(fn, ms)
  local got
  fn(function(...) got = { ... } end)
  assert(vim.wait(ms or 90000, function() return got ~= nil end, 50), "timed out")
  return unpack(got)
end
local err, name = await(function(cb) h.spawn("smoke", nil, cb) end)
assert(not err, vim.inspect(err))
local cmd = ("python3 %s post --title s6 --text hi"):format(vim.env.CLI)
await(function(cb)
  h.request("agent.prompt", { target = name, text = "Run exactly this bash command, then reply done: " .. cmd, wait = { timeout_ms = 90000 } }, cb)
end, 100000)
assert(vim.fn.glob(store.path("threads", "*-s6.jsonl")) ~= "", "agent did not post s6")
ui.open()
local rail = vim.fn.bufnr("cockpit://rail")
local function line_after_title()
  local lines = vim.api.nvim_buf_get_lines(rail, 0, -1, false)
  for i, l in ipairs(lines) do
    if l:find("s6", 1, true) then return lines[i + 1] or "" end
  end
  return ""
end
assert(vim.wait(10000, function() ui.refresh(); return line_after_title():find("○", 1, true) ~= nil end, 500),
  "no idle glyph: " .. line_after_title())
h.kill(name)
assert(vim.wait(10000, function() return line_after_title():find("✕", 1, true) ~= nil end, 200),
  "no offline glyph after kill: " .. line_after_title())
for lhs, desc in pairs({ s = "Spawn agent", X = "Kill agent", i = "Interrupt agent", gt = "Attach to agent", A = "Agent picker" }) do
  local m = vim.api.nvim_buf_call(rail, function() return vim.fn.maparg(lhs, "n", false, true) end)
  assert(m.desc == desc, lhs .. " desc " .. tostring(m.desc))
end
assert(vim.fn.exists(":CockpitSpawn") == 2 and vim.fn.exists(":CockpitAgent") == 2, "commands missing")
print("T6 OK")
LUA
CLI=$CLI nlua "$T/t6.lua" 2>&1 | tee "$T/t6.out" | grep -q "T6 OK" || { cat "$T/t6.out"; fail "section 6"; }
ok "rail shows ○ for a live idle agent, ✕ after kill; s X i gt A mapped; :CockpitSpawn/:CockpitAgent exist"
[ "$LAST" -le 6 ] && exit 0

# --- 7: review fixes — refresh timer lifecycle, own workspaces only, no tmux leak ------------------
echo "7: review fixes"
HP=$("${H[@]}" workspace create --cwd "$NVIM_CFG" | jget 'd["result"]["root_pane"]["pane_id"]')
HW=${HP%%:*}
"${H[@]}" workspace rename "$HW" smoke >/dev/null # a hand-opened workspace that happens to share the project's name
cat >"$T/t7.lua" <<'LUA'
local h, store = require("cockpit.herdr"), require("cockpit.inbox.store")
require("cockpit.inbox").setup()
local ui = require("cockpit.inbox.ui")
local function await(fn, ms)
  local got
  fn(function(...) got = { ... } end)
  assert(vim.wait(ms or 90000, function() return got ~= nil end, 50), "timed out")
  return unpack(got)
end
-- fix 1: the 3 s reconcile stays on while the cockpit is open (re-open / select), off after close
ui.open(); ui.open()
assert(h.watching(), "refresh timer off while cockpit open")
ui.close()
assert(not h.watching(), "refresh timer still on after close")
-- fix 2: spawn never adopts a hand-opened workspace labelled like the project
local hw = vim.env.HW
local function panes(wid) return #(select(2, h.request("pane.list", { workspace_id = wid })).panes) end
local before = panes(hw)
local err, name = await(function(cb) h.spawn("smoke", nil, cb) end)
assert(not err, vim.inspect(err))
assert(panes(hw) == before, "spawn split the hand-opened workspace")
local _, a = h.request("agent.get", { target = name })
local _, ws = h.request("workspace.get", { workspace_id = a.agent.workspace_id })
assert(ws.workspace.label == "ck/smoke", "label " .. tostring(ws.workspace.label))
assert(vim.wait(5000, function() return (h.agents()[name] or {}).project == "smoke" end), "project not resolved from ck/ label")
h.kill(name)
-- fix 3: a herdr-posted thread whose agent is gone never falls through to a tmux pane
local how = store.deliver({ id = "x", session = { herdr = { terminal_id = "term_gone" }, tmux_pane = "%999999" } })
assert(how:find("offline", 1, true), "deliver fell through: " .. how)
print("T7 OK")
LUA
HW=$HW nlua "$T/t7.lua" 2>&1 | tee "$T/t7.out" | grep -q "T7 OK" || { cat "$T/t7.out"; fail "section 7"; }
ok "timer on while open/off after close; spawn uses its own ck/ workspace; no tmux fallthrough for herdr threads"
[ "$LAST" -le 7 ] && exit 0

# --- 8: project directories — migration from flat json, repo symlinks, thread links ---------------
echo "8: project dirs"
mkdir -p "$T/projects"
echo '{"name":"old","repos":["~/.config/nvim","~/dev/genzed"],"created":"2026-01-01T00:00:00+0000"}' >"$T/projects/old.json"
cat >"$T/t8.lua" <<'LUA'
local projects = require("cockpit.projects")
local dir = vim.env.COCKPIT_PROJECTS_DIR
local p = assert(projects.get("old"), "old missing")
assert(vim.deep_equal(p.repos, { vim.fn.expand("~/.config/nvim"), vim.fn.expand("~/dev/genzed") }), vim.inspect(p.repos))
assert(vim.fn.filereadable(dir .. "/old/project.json") == 1, "project.json not written")
assert(vim.fn.filereadable(dir .. "/old.json") == 0, "old.json not removed")
assert(projects.root("old") == dir .. "/old", projects.root("old"))
for base, repo in pairs({ nvim = "~/.config/nvim", genzed = "~/dev/genzed" }) do
  local l = dir .. "/old/repos/" .. base
  assert(vim.uv.fs_lstat(l).type == "link", base .. " not a symlink")
  assert(vim.uv.fs_realpath(l) == vim.uv.fs_realpath(vim.fn.expand(repo)), base .. " wrong target")
end
projects.link_thread("old", "x")
assert(vim.uv.fs_lstat(dir .. "/old/threads/x.jsonl").type == "link", "thread link missing")
projects.link_thread("old", "x") -- idempotent
projects.migrate()
assert(vim.tbl_contains(vim.tbl_map(function(x) return x.name end, projects.list()), "old"), "old missing from list after re-migrate")
print("T8 OK")
LUA
nlua "$T/t8.lua" 2>&1 | tee "$T/t8.out" | grep -q "T8 OK" || { cat "$T/t8.out"; fail "section 8"; }
ok "flat project json migrates to <name>/project.json with repo symlinks and thread links"
[ "$LAST" -le 8 ] && exit 0

# --- 9: agent registry, unique names, thread ownership ---------------------------------------------
echo "9: registry + names + owner"
cat >"$T/t9.lua" <<'LUA'
local h, registry, store = require("cockpit.herdr"), require("cockpit.registry"), require("cockpit.inbox.store")
local function await(fn, ms)
  local got
  fn(function(...) got = { ... } end)
  assert(vim.wait(ms or 90000, function() return got ~= nil end, 50), "timed out")
  return unpack(got)
end
h.start(); h.watch(true)
vim.fn.delete(require("cockpit.projects").root("smoke") .. "/agents.jsonl") -- earlier sections also spawn into smoke
local err, name1 = await(function(cb) h.spawn("smoke", nil, cb) end)
assert(not err, vim.inspect(err))
local tid1 = h.agents()[name1].terminal_id
local all = registry.all("smoke")
assert(vim.tbl_count(all) == 1, "registry: " .. vim.inspect(all))
assert(all[tid1] and all[tid1].name == name1, "no record for " .. tid1)
assert(type(all[tid1].session) == "string" and all[tid1].session ~= "", "no session: " .. vim.inspect(all[tid1]))
assert(registry.names("smoke")[name1], "names() missing " .. name1)
assert(h.kill(name1) == nil, "kill errored")
assert(vim.wait(10000, function() return h.agents()[name1] == nil end, 100), "still cached")
local err2, name2 = await(function(cb) h.spawn("smoke", nil, cb) end)
assert(not err2, vim.inspect(err2))
assert(name2 ~= name1, "name reused: " .. name2)
h.kill(name2)
-- ownership: first message's session wins; t.session stays the latest
local function ev(term, n)
  return vim.json.encode({ kind = "message", id = "m" .. n, ts = n, title = "own", project = "smoke", text = "x", session = { herdr = { terminal_id = term } } })
end
vim.fn.mkdir(store.path("threads"), "p")
vim.fn.writefile({ ev("term_first", 1), ev("term_second", 2) }, store.path("threads", "2026-01-01T00-00-00-own9.jsonl"))
local t = store.thread("2026-01-01T00-00-00-own9")
assert(t.owner.herdr.terminal_id == "term_first", vim.inspect(t.owner))
assert(t.session.herdr.terminal_id == "term_second", vim.inspect(t.session))
print("T9 OK")
LUA
nlua "$T/t9.lua" 2>&1 | tee "$T/t9.out" | grep -q "T9 OK" || { cat "$T/t9.out"; fail "section 9"; }
ok "spawn records {terminal_id, session} in agents.jsonl; respawn gets a fresh name; thread.owner = first message session"
[ "$LAST" -le 9 ] && exit 0

# --- 10: rail tree model (fixtures only, no herdr) ----------------------------------------------------
echo "10: tree model"
cat >"$T/t10.lua" <<'LUA'
local tree = require("cockpit.inbox.tree")
local function ag(name, tid, status, project)
  return { name = name, terminal_id = tid, status = status, project = project }
end
local agents = { A = ag("A", "tA", "idle", "p"), F = ag("F", "tF", "idle", "p"), G = ag("G", "tG", "idle", "p") }
local registry = { p = {
  tA = { name = "A", project = "p", terminal_id = "tA", ts = 1 },
  tF = { name = "F", project = "p", terminal_id = "tF", parent_terminal = "tA", parent_name = "A", fork = "continue", ts = 2 },
  tD = { name = "D", project = "p", terminal_id = "tD", dead = true, ts = 0 },
  tG = { name = "G", project = "p", terminal_id = "tG", parent_terminal = "tD", parent_name = "D", fork = "continue", ts = 3 },
}, q = {} }
local function th(id, owner, status, archived)
  return { id = id, title = id, status = status, archived = archived, last_ts = 1,
    owner = owner and { herdr = { terminal_id = owner } } or nil }
end
local threads = { th("t1", "tA", "needs_you"), th("t2", "tF", "read"), th("t3", "tD", "read", true), th("t4", nil, "read") }
local function keys(nodes)
  return vim.tbl_map(function(n) return n.kind == "thread" and n.thread.id or n.key end, nodes)
end
local function run(show)
  return tree.build({ show_archived = show, threads = threads, agents = agents, registry = registry,
    projects = { { name = "p" }, { name = "q" } } })
end
local nodes = run(false)
assert(vim.deep_equal(keys(nodes), { "header", "p:p", "a:tA", "a:tF", "t2", "t1", "a:tG", "past:p", "a:tD", "p:q", "unassigned", "t4" }),
  vim.inspect(keys(nodes)))
local by = {}
for _, n in ipairs(nodes) do by[n.key] = n end
assert(by["p:p"].counts.needs_you == 1, vim.inspect(by["p:p"].counts))
assert(by["a:tG"].orphan_of == "D" and by["a:tG"].depth == 1)
assert(by["a:tF"].fork == "continue" and by["a:tF"].depth == 2 and by["a:tF"].live)
assert(by["a:tD"].live == false and by["a:tD"].depth == 2)
assert(by["p:q"] and #by["p:q"].children == 0)
assert(not vim.tbl_contains(keys(nodes), "t3"), "t3 shown without show_archived")
assert(vim.tbl_contains(keys(run(true)), "t3"), "t3 missing with show_archived")
print("T10 OK")
LUA
nlua "$T/t10.lua" 2>&1 | tee "$T/t10.out" | grep -q "T10 OK" || { cat "$T/t10.out"; fail "section 10"; }
ok "tree.build orders project > agent > forks > threads, orphans, past, unassigned; archived gated"
[ "$LAST" -le 10 ] && exit 0

echo "all sections passed"
