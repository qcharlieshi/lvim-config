#!/usr/bin/env bash
# Happy-path smoke test for cockpit step 1 (herdr runtime + projects).
# Runs against a throwaway herdr session `ckspike` with an isolated inbox and projects dir.
# Starts real Claude agents in ~/.config/nvim (an already-trusted folder): costs a few tokens.
# Usage: bash scripts/cockpit-smoke-herdr.sh [last-section]   (default: all)
set -euo pipefail

export NVIM_CFG=$(cd "$(dirname "$0")/.." && pwd)
CLI="$NVIM_CFG/scripts/cockpit_inbox.py"
LAST=${1:-99}
T=$(mktemp -d /tmp/ck.XXXX) # short path: macOS unix sockets max 104 chars
export COCKPIT_INBOX_DIR=$T/inbox COCKPIT_PROJECTS_DIR=$T/projects COCKPIT_HERDR_SESSION=ckspike
# run from inside a herdr pane (an agent), the CLI would talk to that server, not ckspike
unset HERDR_SOCKET_PATH HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID
H=(herdr --session ckspike)

cleanup() {
  "${H[@]}" server stop >/dev/null 2>&1 || true
  herdr --session ckdead server stop >/dev/null 2>&1 || true
  sleep 1
  herdr session delete ckspike >/dev/null 2>&1 || true
  herdr session delete ckdead >/dev/null 2>&1 || true
  # section 12 forks smoke-* agents into worktrees of the real repos: leave no worktree or branch behind
  for repo in "$NVIM_CFG" ~/dev/profile_website; do
    for wt in "$repo"/.worktrees/fork-smoke-*; do
      if [ -e "$wt" ]; then git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1 || true; fi
    done
    git -C "$repo" worktree prune >/dev/null 2>&1 || true
    git -C "$repo" for-each-ref --format='%(refname:short)' 'refs/heads/fork/smoke-*' | while read -r b; do
      git -C "$repo" branch -D "$b" >/dev/null 2>&1 || true
    done
    rmdir "$repo/.worktrees" 2>/dev/null || true
  done
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
# a stale server from an aborted run must not be reused
for s in ckspike ckdead; do herdr --session "$s" server stop >/dev/null 2>&1 || true; done
sleep 1
for s in ckspike ckdead; do herdr session delete "$s" >/dev/null 2>&1 || true; done
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
PID2=$(pgrep -f -- "--session ckdead server" | head -1)
[ -n "$PID2" ] || fail "no ckdead server process"
! ps -wwE -p "$PID2" | grep -qE "(VIMRUNTIME|MYVIMRC)=" || fail "ensure() leaked VIMRUNTIME/MYVIMRC into the herdr server env"
"${H[@]}" pane close "$P2" >/dev/null # frees the name smoke-1 for section 4
ok "cache sees smoke-1 idle with terminal_id; CockpitAgents fired; ensure() starts a dead server (no VIMRUNTIME/MYVIMRC)"
[ "$LAST" -le 2 ] && exit 0

# --- 3: project definitions ----------------------------------------------------------------
echo "3: projects"
cat >"$T/t3.lua" <<'LUA'
local projects = require("cockpit.projects")
local picks = { vim.env.NVIM_CFG, vim.fn.expand("~/dev/profile_website"), "✓ done" }
vim.ui.input = function(_, cb) cb("smoke") end
vim.ui.select = function(_, _, cb) cb(table.remove(picks, 1)) end
projects.new()
local p = assert(projects.get("smoke"), "project smoke missing")
assert(vim.deep_equal(p.repos, { vim.env.NVIM_CFG, vim.fn.expand("~/dev/profile_website") }), vim.inspect(p.repos))
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
# A pre-approved permission guarantees Claude's folder-trust dialog (matches an untrusted extra repo)
mkdir -p "$T/untrusted/.claude" && echo '{"permissions":{"allow":["Bash(true)"]}}' >"$T/untrusted/.claude/settings.local.json"
cat >"$T/t4.lua" <<'LUA'
local h, projects = require("cockpit.herdr"), require("cockpit.projects")
local function await(fn, ms) -- run fn(cb) and wait for cb's args
  local got
  fn(function(...) got = { ... } end)
  assert(vim.wait(ms or 180000, function() return got ~= nil end, 50), "timed out")
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
  h.request("agent.prompt", { target = name, text = "Run this bash command and reply with only its output: echo PROJ=$COCKPIT_PROJECT", wait = { timeout_ms = 180000 } }, cb)
end, 190000)
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
  assert(vim.wait(ms or 180000, function() return got ~= nil end, 50), "timed out")
  return unpack(got)
end
h.start(); h.watch(true)
local err, name = await(function(cb) h.spawn("smoke", nil, cb) end)
assert(not err, vim.inspect(err))
local cmd = ("python3 %s post --title s5 --text hi"):format(vim.env.CLI)
local perr = await(function(cb)
  h.request("agent.prompt", { target = name, text = "Run exactly this bash command, then reply done: " .. cmd, wait = { timeout_ms = 180000 } }, cb)
end, 190000)
assert(not perr, vim.inspect(perr))
local f = vim.fn.glob(store.path("threads", "*-s5.jsonl"), false, true)[1]
assert(f, "agent did not post s5")
local t = store.thread(vim.fn.fnamemodify(f, ":t:r"))
assert(t.session.herdr and t.session.herdr.terminal_id, "s5 has no herdr identity")
local how = store.deliver(t)
assert(how:find("^delivered"), "deliver returned: " .. how)
assert(vim.wait(180000, function()
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
  assert(vim.wait(ms or 180000, function() return got ~= nil end, 50), "timed out")
  return unpack(got)
end
local err, name = await(function(cb) h.spawn("smoke", nil, cb) end)
assert(not err, vim.inspect(err))
local cmd = ("python3 %s post --title s6 --text hi"):format(vim.env.CLI)
await(function(cb)
  h.request("agent.prompt", { target = name, text = "Run exactly this bash command, then reply done: " .. cmd, wait = { timeout_ms = 180000 } }, cb)
end, 190000)
assert(vim.fn.glob(store.path("threads", "*-s6.jsonl")) ~= "", "agent did not post s6")
ui.open()
local rail = vim.fn.bufnr("cockpit://rail")
-- the first line of the agent's card carries its status glyph (○ idle, ✕ dead)
local tid = h.agents()[name].terminal_id
local function agent_line()
  local r = require("cockpit.inbox.rail").row(rail, "a:" .. tid)
  return r and vim.api.nvim_buf_get_lines(rail, r - 1, r, false)[1] or ""
end
local function has_s6()
  return vim.iter(vim.api.nvim_buf_get_lines(rail, 0, -1, false)):any(function(l) return l:find("s6", 1, true) ~= nil end)
end
assert(vim.wait(10000, function() ui.refresh(); return has_s6() and agent_line():find("○", 1, true) ~= nil end, 500),
  "no idle glyph: " .. agent_line())
h.kill(name)
assert(vim.wait(10000, function() return agent_line():find("✕", 1, true) ~= nil end, 200),
  "no offline glyph after kill: " .. agent_line())
for lhs, desc in pairs({ s = "Spawn agent", X = "Kill agent", i = "Interrupt agent", gt = "Attach to agent", A = "Agent picker" }) do
  local m = vim.api.nvim_buf_call(rail, function() return vim.fn.maparg(lhs, "n", false, true) end)
  assert(m.desc == desc, lhs .. " desc " .. tostring(m.desc))
end
assert(vim.fn.exists(":CockpitSpawn") == 2 and vim.fn.exists(":CockpitAgent") == 2, "commands missing")
print("T6 OK")
LUA
CLI=$CLI nlua "$T/t6.lua" 2>&1 | tee "$T/t6.out" | grep -q "T6 OK" || { cat "$T/t6.out"; fail "section 6"; }
ok "rail agent card shows ○ while idle, ✕ after kill; s X i gt A mapped; :CockpitSpawn/:CockpitAgent exist"
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
  assert(vim.wait(ms or 180000, function() return got ~= nil end, 50), "timed out")
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
echo '{"name":"old","repos":["~/.config/nvim","~/dev/profile_website"],"created":"2026-01-01T00:00:00+0000"}' >"$T/projects/old.json"
cat >"$T/t8.lua" <<'LUA'
local projects = require("cockpit.projects")
local dir = vim.env.COCKPIT_PROJECTS_DIR
local p = assert(projects.get("old"), "old missing")
assert(vim.deep_equal(p.repos, { vim.fn.expand("~/.config/nvim"), vim.fn.expand("~/dev/profile_website") }), vim.inspect(p.repos))
assert(vim.fn.filereadable(dir .. "/old/project.json") == 1, "project.json not written")
assert(vim.fn.filereadable(dir .. "/old.json") == 0, "old.json not removed")
assert(projects.root("old") == dir .. "/old", projects.root("old"))
for base, repo in pairs({ nvim = "~/.config/nvim", profile_website = "~/dev/profile_website" }) do
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
  assert(vim.wait(ms or 180000, function() return got ~= nil end, 50), "timed out")
  return unpack(got)
end
h.start(); h.watch(true)
vim.fn.delete(require("cockpit.projects").root("smoke") .. "/agents.jsonl") -- earlier sections also spawn into smoke
local err, name1 = await(function(cb) h.spawn("smoke", nil, cb) end)
assert(not err, vim.inspect(err))
local tid1 = h.agents()[name1].terminal_id
local all = registry.all("smoke")
assert(vim.tbl_count(all) == 1, "registry: " .. vim.inspect(all))
local rec1 = registry.by_terminal("smoke", tid1)
assert(rec1 and rec1.name == name1, "no record for " .. tid1)
assert(type(rec1.session) == "string" and rec1.session ~= "", "no session: " .. vim.inspect(rec1))
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

# --- 11: rail — project tree, folds survive refresh, kill archives ------------------------------------
echo "11: rail tree + folds + kill-archive"
cat >"$T/t11.lua" <<'LUA'
local h, store, registry = require("cockpit.herdr"), require("cockpit.inbox.store"), require("cockpit.registry")
require("cockpit.inbox").setup()
local ui, rail = require("cockpit.inbox.ui"), require("cockpit.inbox.rail")
local function await(fn, ms)
  local got
  fn(function(...) got = { ... } end)
  assert(vim.wait(ms or 180000, function() return got ~= nil end, 50), "timed out")
  return unpack(got)
end
local function lines(buf) return vim.api.nvim_buf_get_lines(buf, 0, -1, false) end
-- 1. an empty project still gets a row (Review Focus 1)
require("cockpit.projects").save({ name = "r", repos = { vim.env.NVIM_CFG } })
ui.open()
local buf = vim.fn.bufnr("cockpit://rail")
local win = vim.fn.win_findbuf(buf)[1]
assert(vim.iter(lines(buf)):any(function(l) return l:match("^▾ r%s*$") ~= nil end), "no ▾ r row:\n" .. table.concat(lines(buf), "\n"))
-- 2. smoke → agent card (its rows all map to the agent) → s11
local err, name = await(function(cb) h.spawn("smoke", nil, cb) end)
assert(not err, vim.inspect(err))
local tid = h.agents()[name].terminal_id
local cmd = ("python3 %s post --title s11 --text hi"):format(vim.env.CLI)
await(function(cb)
  h.request("agent.prompt", { target = name, text = "Run exactly this bash command, then reply done: " .. cmd, wait = { timeout_ms = 180000 } }, cb)
end, 190000)
local f = vim.fn.glob(store.path("threads", "*-s11.jsonl"), false, true)[1]
assert(f, "agent did not post s11")
local sid = vim.fn.fnamemodify(f, ":t:r")
local function row(key) ui.refresh_rail(); return rail.row(buf, key) end
assert(vim.wait(10000, function() return row("t:" .. sid) ~= nil end, 200), "s11 never in rail")
local pr = row("p:smoke")
local tr = rail.row(buf, "t:" .. sid)
assert(rail.row(buf, "a:" .. tid) == pr + 1 and tr > pr + 1, "not in order:\n" .. table.concat(lines(buf), "\n"))
for r = pr + 2, tr - 1 do
  assert(rail.node(buf, r).key == "a:" .. tid, "row " .. r .. " between agent and thread is not its card")
end
local L = lines(buf)
assert(L[pr]:match("^▾ smoke") and L[tr]:find("s11", 1, true), "rows:\n" .. table.concat(lines(buf), "\n"))
assert(table.concat(L, "\n", pr + 1, tr - 1):find("herdr " .. name, 1, true), "card lacks herdr name:\n" .. table.concat(L, "\n"))
local past = rail.row(buf, "past:smoke")
assert(past and vim.api.nvim_win_call(win, function() return vim.fn.foldclosed(past) end) == past, "past:smoke not folded by default")
-- 3. zc on the agent survives a reconcile + re-render; cursor stays on the agent node (Review Focus 3)
vim.api.nvim_set_current_win(win)
vim.api.nvim_win_set_cursor(win, { pr + 1, 0 })
vim.cmd("normal zc")
assert(vim.fn.foldclosed(pr + 1) == pr + 1, "zc did not close the agent fold")
vim.wait(3500)
ui.refresh_rail()
local ar = rail.row(buf, "a:" .. tid)
assert(vim.fn.foldclosed(ar) == ar, "agent fold reopened after refresh")
assert(rail.row(buf, "a:" .. tid) == vim.api.nvim_win_get_cursor(win)[1], "cursor left the agent node")
-- 4. kill → archive its threads, registry dead = true
vim.fn.confirm = function() return 1 end
rail.kill_agent(rail.node(buf, ar))
assert(store.thread(sid).archived, "s11 not archived")
assert(registry.by_terminal("smoke", tid).dead == true, "registry not dead: " .. vim.inspect(registry.by_terminal("smoke", tid)))
assert(vim.wait(10000, function() return h.by_terminal(tid) == nil end, 100), "agent still live")
-- 5. X on a past (dead) agent archives its threads and never calls herdr.kill
local ev = vim.json.encode({ kind = "message", id = "m1", ts = os.time(), title = "s11b", project = "smoke", text = "x",
  session = { herdr = { terminal_id = tid } } })
vim.fn.writefile({ ev }, store.path("threads", "2026-01-01T00-00-00-s11b.jsonl"))
local kills = {}
h.kill = function(target) kills[#kills + 1] = tostring(target) end
ui.refresh_rail()
local dr = rail.row(buf, "a:" .. tid)
assert(dr and not rail.node(buf, dr).live, "dead agent row missing")
vim.api.nvim_set_current_win(win)
vim.api.nvim_win_set_cursor(win, { dr, 0 })
vim.cmd("normal! zv")
vim.cmd("normal X")
assert(store.thread("2026-01-01T00-00-00-s11b").archived, "past agent's thread not archived")
assert(#kills == 0, "herdr.kill called for a dead agent: " .. table.concat(kills, ","))
print("T11 OK")
LUA
CLI=$CLI NVIM_CFG=$NVIM_CFG nlua "$T/t11.lua" 2>&1 | tee "$T/t11.out" | grep -q "T11 OK" || { cat "$T/t11.out"; fail "section 11"; }
ok "rail: empty project row; smoke > agent card > s11; folds + cursor survive refresh; kill archives + registry dead; X on a past agent archives without herdr.kill"
[ "$LAST" -le 11 ] && exit 0

# --- 12: forks — continue + worktree, kill cleanup -----------------------------------------------------
echo "12: forks"
cat >"$T/t12.lua" <<'LUA'
local h, registry = require("cockpit.herdr"), require("cockpit.registry")
require("cockpit.inbox").setup()
local rail, forks = require("cockpit.inbox.rail"), require("cockpit.forks")
local function await(fn, ms)
  local got
  fn(function(...) got = { ... } end)
  assert(vim.wait(ms or 180000, function() return got ~= nil end, 50), "timed out")
  return unpack(got)
end
local nv = vim.env.NVIM_CFG
local function has_branch(b)
  return vim.trim(vim.system({ "git", "-C", nv, "branch", "--list", b }, { text = true }):wait().stdout) ~= ""
end
local function live(name)
  assert(vim.wait(10000, function() return h.agents()[name] ~= nil end, 100), name .. " not live")
  return h.agents()[name]
end
vim.fn.confirm = function() return 1 end
local err, pname = await(function(cb) h.spawn("smoke", nil, cb) end)
assert(not err, vim.inspect(err))
local parent = live(pname)
-- Claude writes no transcript before the first message: an unprompted session cannot be resumed
local nerr = await(function(cb) forks.continue(parent, nil, cb) end, 5000)
assert(nerr and nerr.code == "no_session", "forked an unprompted parent: " .. vim.inspect(nerr))
local perr = await(function(cb)
  h.request("agent.prompt", { target = pname, text = "Reply with only: hi", wait = { timeout_ms = 180000 } }, cb)
end, 190000)
assert(not perr, vim.inspect(perr))
local psession = registry.by_terminal("smoke", parent.terminal_id).session
-- 1. continue fork: live child in the parent's workspace, own session, linked to the parent
local cerr, cname = await(function(cb) forks.continue(parent, nil, cb) end)
assert(not cerr, vim.inspect(cerr))
local child = live(cname)
local crec = registry.by_terminal("smoke", child.terminal_id)
assert(crec, "no registry rec for " .. cname .. ": " .. vim.inspect(registry.all("smoke")) .. vim.inspect(child))
assert(crec.fork == "continue" and crec.parent_terminal == parent.terminal_id and crec.parent_name == pname, vim.inspect(crec))
assert(type(crec.session) == "string" and crec.session ~= psession, "fork session " .. tostring(crec.session) .. " vs parent " .. tostring(psession))
assert(child.workspace_id == parent.workspace_id, "fork not in the parent's workspace")
assert(h.agents()[pname], "parent died")
-- the preamble arrives at launch as SessionStart context (survives a blocked start)
local qerr = await(function(cb)
  h.request("agent.prompt", { target = cname, text = "Per the context you were given at session start, which agent are you a fork of? Reply with only FORKOF=<that name>", wait = { timeout_ms = 180000 } }, cb)
end, 190000)
assert(not qerr, vim.inspect(qerr))
local _, cread = h.request("agent.read", { target = cname, source = "recent_unwrapped", lines = 40 })
assert(cread and vim.inspect(cread):find("FORKOF=" .. pname, 1, true), "fork does not know its parent: " .. vim.inspect(cread))
rail.kill_agent(child)
-- 2. worktree fork: branch fork/<parent>-1 + worktree dir
local branch, wt = "fork/" .. pname .. "-1", nv .. "/.worktrees/fork-" .. pname .. "-1"
local werr, wname = await(function(cb) forks.worktree(parent, nil, cb) end)
assert(not werr, vim.inspect(werr))
assert(has_branch(branch), branch .. " missing")
assert(vim.fn.isdirectory(wt) == 1, wt .. " missing")
local wa = live(wname)
local wrec = registry.by_terminal("smoke", wa.terminal_id)
assert(wrec.fork == "worktree" and #wrec.worktrees == 2 and wrec.worktrees[1].path == wt, vim.inspect(wrec))
assert(type(wrec.session) == "string" and wrec.session ~= psession, "worktree fork session " .. tostring(wrec.session))
assert(vim.fn.resolve(wa.cwd) == vim.fn.resolve(wt), "fork cwd " .. tostring(wa.cwd))
-- 3. killed unchanged: worktree + branch removed silently
vim.ui.select = function(_, opts) error("asked: " .. opts.prompt) end
rail.kill_agent(wa)
assert(not has_branch(branch), branch .. " still exists")
assert(vim.fn.isdirectory(wt) == 0, wt .. " still exists")
-- 3b. unnamed parent (hand-started agent: cache key = pane id) + a start that fails → no orphans
local anon = vim.deepcopy(parent); anon.name = nil
anon.target = parent.pane_id
local ok_nil, nerr2 = pcall(forks.continue, { project = "smoke", target = "w99:p99", terminal_id = "term_x" }, nil, function() end)
assert(ok_nil, "unnamed parent without session threw: " .. tostring(nerr2))
local real_start, seen = h.start_in, nil
h.start_in = function(_, name, _, rec, cb)
  seen = rec.worktrees
  cb({ code = "timeout", message = "stubbed start failure" }, name)
end
local ferr = await(function(cb) forks.worktree(anon, nil, cb) end, 30000)
h.start_in = real_start
assert(ferr and ferr.code == "timeout", vim.inspect(ferr))
assert(seen and seen[1].branch:match("^fork/w%w+%-p%w+%-1$"), "unnamed branch: " .. vim.inspect(seen))
assert(vim.fn.isdirectory(seen[1].path) == 0 and not has_branch(seen[1].branch), "failed fork left worktree/branch behind")
-- 4. Review Focus 4: a fork with a commit → asked; Keep branch keeps it, removes the clean worktree
local w2err, w2name = await(function(cb) forks.worktree(parent, nil, cb) end)
assert(not w2err, vim.inspect(w2err))
local w2 = live(w2name)
local c = vim.system({ "git", "-C", wt, "commit", "--allow-empty", "-m", "x" }, { text = true }):wait()
assert(c.code == 0, c.stderr)
local asked
vim.ui.select = function(items, opts, cb) asked = opts.prompt; cb("Keep branch") end
rail.kill_agent(w2)
assert(asked and asked:find(branch, 1, true) and asked:find("1 commit", 1, true), "prompt: " .. tostring(asked))
assert(has_branch(branch), "kept branch deleted")
assert(vim.fn.isdirectory(wt) == 0, "clean worktree not removed")
h.kill(pname)
print("T12 OK")
LUA
NVIM_CFG=$NVIM_CFG nlua "$T/t12.lua" 2>&1 | tee "$T/t12.out" | grep -q "T12 OK" || { cat "$T/t12.out"; fail "section 12"; }
ok "continue fork: own session, parent link, parent stays live, preamble at launch; unnamed parent + failed start leave no worktree; worktree fork: branch + worktree, clean kill removes both, kept branch survives a commit"
[ "$LAST" -le 12 ] && exit 0

# --- 13: :CockpitCleanup — archive threads of dead agents ---------------------------------------------
echo "13: cleanup"
cat >"$T/t13.lua" <<'LUA'
local store = require("cockpit.inbox.store")
require("cockpit.inbox").setup()
local rail = require("cockpit.inbox.rail")
local function seed(id, session)
  store.append(store.thread_file(id), { kind = "message", title = id, project = "smoke", session = session, text = "x", ts = os.time() - 7200 })
end
seed("c-gone", { agent = "a", herdr = { terminal_id = "term_gone" } })
seed("c-tmux", { agent = "a", tmux_pane = "%999999" })
seed("c-none", { agent = "a" })
seed("c-old", { agent = "a", herdr = { terminal_id = "term_gone2" } })
store.append(store.thread_file("c-old"), { kind = "state", archived = true })
assert(vim.fn.exists(":CockpitCleanup") == 2, "no :CockpitCleanup command")
local h = require("cockpit.herdr")
local notes = {}
local notify = vim.notify
vim.notify = function(m) notes[#notes + 1] = m end
-- never reconciled: herdr liveness unknown, so nothing may be called dead
local wins = #vim.api.nvim_list_wins()
rail.cleanup()
assert(#vim.api.nvim_list_wins() == wins, "cleanup opened a float before any reconcile")
-- a failed reconcile (no server) refuses too
local sess = vim.env.COCKPIT_HERDR_SESSION
vim.env.COCKPIT_HERDR_SESSION = "ck13none"
local done
h.reconcile(function() done = true end)
assert(vim.wait(10000, function() return done end), "reconcile never returned")
rail.cleanup()
assert(#vim.api.nvim_list_wins() == wins, "cleanup opened a float after a failed reconcile")
assert(vim.iter(notes):any(function(m) return m:find("herdr", 1, true) ~= nil end), "no refusal notice: " .. vim.inspect(notes))
vim.notify = notify
vim.env.COCKPIT_HERDR_SESSION = sess
done = nil
h.reconcile(function() done = true end)
assert(vim.wait(10000, function() return done end), "reconcile never returned")
rail.cleanup()
local buf = vim.api.nvim_get_current_buf()
local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
assert(text:find("c-gone", 1, true) and text:find("c-tmux", 1, true), "candidates not listed:\n" .. text)
assert(not text:find("c-none", 1, true) and not text:find("c-old", 1, true), "non-candidates listed:\n" .. text)
vim.api.nvim_feedkeys("y", "x", false)
assert(store.thread("c-gone").archived, "c-gone not archived")
assert(store.thread("c-tmux").archived, "c-tmux not archived")
assert(not store.thread("c-none").archived, "c-none archived")
assert(vim.fn.filereadable(store.thread_file("c-gone")) == 1, "thread file deleted")
-- q cancels
seed("c-q", { agent = "a", herdr = { terminal_id = "term_gone3" } })
rail.cleanup()
vim.api.nvim_feedkeys("q", "x", false)
assert(not store.thread("c-q").archived, "q archived")
print("T13 OK")
LUA
nlua "$T/t13.lua" 2>&1 | tee "$T/t13.out" | grep -q "T13 OK" || { cat "$T/t13.out"; fail "section 13"; }
ok ":CockpitCleanup refuses until herdr reconciled; lists dead-agent threads, y archives (files kept), q cancels"
[ "$LAST" -le 13 ] && exit 0

# --- 14: floating composers — reply + line note (headless, no herdr) -----------------------------------
echo "14: floating composers"
cat >"$T/t14.lua" <<'LUA'
local store = require("cockpit.inbox.store")
require("cockpit.inbox").setup()
local ui = require("cockpit.inbox.ui")
local sha = vim.fn.sha256("# doc\nline two\n")
vim.fn.mkdir(store.path("blobs"), "p")
vim.fn.writefile({ "# doc", "line two" }, store.path("blobs", sha))
local tid = "f14"
store.append(store.thread_file(tid), { kind = "message", title = "f14", project = "smoke", text = "x", ts = os.time(),
  attachments = { { name = "doc.md", type = "markdown", sha256 = sha } } })
ui.select(tid)
local function keys(k) vim.api.nvim_feedkeys(vim.keycode(k), "x", false) end
-- reply composer is a float; q keeps the draft; reopening restores it
ui.compose(tid, nil)
local cfg = vim.api.nvim_win_get_config(0)
assert(cfg.relative ~= "", "composer is not a float")
assert(cfg.border and cfg.title, "float has no border/title")
local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "half a thought" })
keys("<Esc>")
keys("q")
assert(vim.api.nvim_win_get_config(0).relative == "", "q did not close the float")
ui.compose(tid, nil)
assert(vim.api.nvim_win_get_config(0).relative ~= "", "reopened composer is not a float")
local got = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
assert(got == "half a thought", "draft not restored: " .. got)
keys("<Esc>")
keys("q")
-- line note: label select then a floating 3-line input
local wins = vim.api.nvim_tabpage_list_wins(0)
local att_win
for _, w in ipairs(wins) do
  if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)):find("doc.md", 1, true) then att_win = w end
end
assert(att_win, "attachment window not found")
vim.api.nvim_set_current_win(att_win)
vim.api.nvim_win_set_cursor(att_win, { 1, 0 })
vim.ui.select = function(items, _, cb) cb("bug") end
keys("ga")
cfg = vim.api.nvim_win_get_config(0)
assert(cfg.relative ~= "" and cfg.height == 3, "note input is not a 3-line float: " .. vim.inspect(cfg))
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "a", "b" })
vim.cmd("write")
assert(vim.api.nvim_win_get_config(0).relative == "", "note float still open after :w")
local t = store.thread(tid)
assert(#t.drafts == 1 and t.drafts[1].text == "a\nb", vim.inspect(t.drafts))
assert(t.drafts[1].label == "bug", "label")
print("T14 OK")
LUA
nlua "$T/t14.lua" 2>&1 | tee "$T/t14.out" | grep -q "T14 OK" || { cat "$T/t14.out"; fail "section 14"; }
ok "reply composer + note input are floats; q keeps the draft and reopen restores it; note :w saves joined lines"
[ "$LAST" -le 14 ] && exit 0

# --- 15: CodeDiff auto-open, deliverable-only buffer list (headless, no herdr) ----------------------------
echo "15: select — diff auto-opens CodeDiff, only deliverables are listed buffers"
cat >"$T/t15.lua" <<'LUA'
local store = require("cockpit.inbox.store")
require("cockpit.inbox").setup()
local ui = require("cockpit.inbox.ui")
local review = require("cockpit.inbox.review")
local function blob(lines)
  local sha = vim.fn.sha256(table.concat(lines, "\n") .. "\n")
  vim.fn.mkdir(store.path("blobs"), "p")
  vim.fn.writefile(lines, store.path("blobs", sha))
  return sha
end
local md = blob({ "# doc" })
local df = blob({ "--- a/x", "+++ b/x", "@@ -1 +1 @@", "-a", "+b" })
local tid = "f15"
store.append(store.thread_file(tid), { kind = "message", title = "f15", project = "smoke", text = "x", ts = os.time(),
  attachments = { { name = "doc.md", type = "markdown", sha256 = md }, { name = "x.diff", type = "diff", sha256 = df } } })
local calls = {}
review.open = function(t, att) calls[#calls + 1] = { t, att.name }; vim.cmd("tabnew") end -- real tab switch, like CodeDiff
ui.select(tid)
local listed = {}
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  if vim.bo[b].buflisted and vim.api.nvim_buf_get_name(b) ~= "" then listed[#listed + 1] = vim.api.nvim_buf_get_name(b) end
end
table.sort(listed)
local want = { "cockpit://inbox/f15/" .. md:sub(1, 8) .. "/doc.md", "cockpit://inbox/f15/" .. df:sub(1, 8) .. "/x.diff" }
table.sort(want)
assert(vim.deep_equal(listed, want), "listed buffers: " .. vim.inspect(listed))
-- the first deliverable is the markdown; selecting a diff-first thread must auto-open
local tid2 = "g15"
store.append(store.thread_file(tid2), { kind = "message", title = "g15", project = "smoke", text = "x", ts = os.time(),
  attachments = { { name = "y.diff", type = "diff", sha256 = df } } })
ui.select(tid2) -- internal re-select (no opts): must not open CodeDiff
assert(#calls == 0, "internal select opened a diff: " .. vim.inspect(calls))
local ck_tab = vim.api.nvim_get_current_tabpage()
local proj = vim.fn.tempname()
vim.fn.mkdir(proj, "p")
ui.select(tid2, nil, { dir = proj, open_diff = true })
assert(vim.api.nvim_get_current_tabpage() ~= ck_tab, "no tab switch")
assert(vim.fn.getcwd(-1, vim.api.nvim_tabpage_get_number(ck_tab)) == vim.uv.fs_realpath(proj), "cockpit tab cwd: " .. vim.fn.getcwd(-1, vim.api.nvim_tabpage_get_number(ck_tab)))
vim.api.nvim_set_current_tabpage(ck_tab)
ui.select(tid2, nil, { dir = proj, open_diff = true }) -- second user select refocuses the existing tab
assert(vim.api.nvim_get_current_tabpage() ~= ck_tab, "existing diff tab not focused")
vim.api.nvim_set_current_tabpage(ck_tab)
assert(#calls == 1 and calls[1][1] == tid2 and calls[1][2] == "y.diff", "review.open calls: " .. vim.inspect(calls))
local bar
for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  if vim.wo[w].winbar:find("diff opened in CodeDiff", 1, true) then bar = true end
end
assert(bar, "placeholder winbar missing")
-- other thread's deliverables got unlisted; this one's are listed
local l2 = {}
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  if vim.bo[b].buflisted and vim.api.nvim_buf_get_name(b) ~= "" then l2[#l2 + 1] = vim.api.nvim_buf_get_name(b) end
end
assert(#l2 == 1 and l2[1]:find("g15", 1, true), "listed after switch: " .. vim.inspect(l2))
print("T15 OK")
LUA
nlua "$T/t15.lua" 2>&1 | tee "$T/t15.out" | grep -q "T15 OK" || { cat "$T/t15.out"; fail "section 15"; }
ok "select unlists other threads' deliverables; a diff deliverable auto-opens CodeDiff with a placeholder winbar"
[ "$LAST" -le 15 ] && exit 0

# 16. quiet Stop hook (no herdr): unwatched stops post only for inbox replies or trailing '?'
I16=$T/inbox16
mkdir -p "$I16"
hook16() { # <prompt> <last message> <session id>
  printf '{"type":"user","message":{"content":"%s"}}\n' "$1" >"$T/tr16.jsonl"
  python3 -c 'import json,sys; print(json.dumps({"transcript_path": sys.argv[1], "last_assistant_message": sys.argv[2], "session_id": sys.argv[3], "cwd": "/tmp"}))' \
    "$T/tr16.jsonl" "$2" "$3" |
    env -u TMUX -u TMUX_PANE -u COCKPIT_INBOX_HOOK HERDR_PANE_ID=w0:p0 COCKPIT_INBOX_DIR="$I16" python3 "$CLI" hook stop
}
hook16 "hello" "Done." aaaaaaaa11
[ -z "$(ls "$I16/threads" 2>/dev/null)" ] || fail "status chatter created a thread: $(ls "$I16/threads")"
hook16 "hello" "Checked it.
Which one?" bbbbbbbb22
[ "$(wc -l <"$I16/threads/session-bbbbbbbb.jsonl")" -eq 1 ] || fail "question thread missing"
grep -q '"questions": \[{' "$I16/threads/session-bbbbbbbb.jsonl" || grep -q '"questions":\[{' "$I16/threads/session-bbbbbbbb.jsonl" || fail "no question recorded"
mkdir -p "$I16/threads"
echo '{"kind":"message","from":"agent","text":"seed","title":"T1"}' >"$I16/threads/T1.jsonl"
hook16 "Inbox reply on thread T1. Run: python3 x read T1 --new" "ok" cccccccc33
[ "$(wc -l <"$I16/threads/T1.jsonl")" -eq 2 ] || fail "reply did not append to T1"
[ ! -e "$I16/threads/session-cccccccc.jsonl" ] || fail "reply made a stray thread"
ok "Stop hook: chatter silent, trailing ? posts a question, inbox reply appends to its thread"
# markdown-wrapped trailing question still counts
hook16 "hello" "Two options.
**Which one?**" dddddddd44
[ -f "$I16/threads/session-dddddddd.jsonl" ] || fail "**Which one?** posted no question"
# the reply trigger is untrusted text: a regex, an absolute path or an unknown id never becomes a file
before16=$(ls "$I16/threads" | sort)
P16=$(mktemp -d /tmp/ckp16XXXXXX) # no '.' in the path: the old lazy regex stopped at the first one
hook16 'Inbox reply on thread (\\S+?). Run: x' "ok" eeeeeeee55
hook16 "Inbox reply on thread $P16/evil. Run: x" "ok" eeeeeeee56
hook16 "see: Inbox reply on thread $P16/evil2. Run: x" "ok" eeeeeeee57
hook16 "Inbox reply on thread NOSUCH. Run: python3 x read NOSUCH --new" "ok" eeeeeeee58
[ "$(ls "$I16/threads" | sort)" = "$before16" ] || fail "untrusted reply ids created threads: $(ls "$I16/threads")"
[ -z "$(ls -A "$P16")" ] || fail "absolute-path thread id wrote outside the inbox: $(ls -A "$P16")"
rm -rf "$P16"
ok "Stop hook: **Which one?** is a question; regex / absolute path / unknown thread ids create no file"
# C1: a herdr agent attached by the `claude` launcher is watched exactly when its tmux pane is
P16W=$("${H[@]}" workspace create --cwd "$NVIM_CFG" --label hook16 | jget 'd["result"]["root_pane"]["pane_id"]')
TERM16=$("${H[@]}" pane get "$P16W" | jget 'd["result"]["pane"]["terminal_id"]')
mkdir -p "$T/bin16" "$T/att16"
# fake tmux: pane %42 is the focused pane of an attached session iff $T/watched16 exists
cat >"$T/bin16/tmux" <<SH
#!/bin/sh
[ -e "$T/watched16" ] && echo "%42 1 1 1" || echo "%42 0 1 1"
SH
chmod +x "$T/bin16/tmux"
hook16a() { # <session id>: a trailing question from the herdr pane P16W
  printf '{"type":"user","message":{"content":"hi"}}\n' >"$T/tr16.jsonl"
  python3 -c 'import json,sys; print(json.dumps({"transcript_path": sys.argv[1], "last_assistant_message": "Which?", "session_id": sys.argv[2], "cwd": "/tmp"}))' \
    "$T/tr16.jsonl" "$1" |
    env -u TMUX -u TMUX_PANE -u COCKPIT_INBOX_HOOK PATH="$T/bin16:$PATH" HERDR_ENV=1 HERDR_PANE_ID="$P16W" \
      COCKPIT_ATTACH_DIR="$T/att16" COCKPIT_INBOX_DIR="$I16" python3 "$CLI" hook stop
}
echo "%42" >"$T/att16/$TERM16"
touch "$T/watched16"
hook16a ffffffff61
[ ! -e "$I16/threads/session-ffffffff.jsonl" ] || fail "attached + watched herdr agent posted"
rm "$T/watched16"
hook16a ffffffff62
[ -e "$I16/threads/session-ffffffff.jsonl" ] || fail "attached but unwatched herdr agent did not post"
rm "$I16/threads/session-ffffffff.jsonl" "$T/att16/$TERM16"
touch "$T/watched16"
hook16a ffffffff63
[ -e "$I16/threads/session-ffffffff.jsonl" ] || fail "unattached herdr agent did not post"
rm "$T/watched16"
"${H[@]}" pane close "$P16W" >/dev/null
ok "Stop hook: herdr agent with an attach marker follows its tmux pane (watched -> silent, not -> posts); no marker -> unwatched"
[ "$LAST" -le 16 ] && exit 0

# --- 17: `claude` via herdr — cockpit-spawn.lua + launcher bypass ---------------------------------
echo "17: claude via herdr"
P17=$T/projects17 # fresh projects dir: no project holds ~/.config/nvim yet
PN17=$(basename "$NVIM_CFG") # the auto-created project: nvim, or the worktree dir name when run from one
spawn17() {
  TMUX=dummy COCKPIT_PROJECTS_DIR=$P17 nvim --headless -u NONE -i NONE --cmd "set rtp^=$NVIM_CFG" \
    -l "$NVIM_CFG/scripts/cockpit-spawn.lua" -- "$NVIM_CFG" </dev/null 2>"$T/s17.err"
}
read -r N17 PANE17 _ <<<"$(spawn17)" || true
[ -n "$N17" ] && [ -n "$PANE17" ] || { cat "$T/s17.err"; fail "cockpit-spawn.lua printed no agent"; }
J17=$("${H[@]}" agent get "$N17") || fail "$N17 not live"
WS17=$(jget 'd["result"]["agent"]["workspace_id"]' <<<"$J17")
"${H[@]}" workspace list | python3 -c '
import sys, json
ws = {w["workspace_id"]: w["label"] for w in json.load(sys.stdin)["result"]["workspaces"]}
assert ws.get(sys.argv[1]) == "ck/" + sys.argv[2], ws
' "$WS17" "$PN17" || fail "$N17 not in a ck/nvim workspace"
[ -f "$P17/$PN17/project.json" ] || fail "project nvim not created"
grep -q "\"$N17\"" "$P17/$PN17/agents.jsonl" || fail "$N17 not in the nvim registry"
read -r N17B PANE17B _ <<<"$(spawn17)" || true
[ -n "$N17B" ] && [ "$N17B" != "$N17" ] || { cat "$T/s17.err"; fail "second spawn: '$N17B'"; }
[ "$(ls "$P17")" = "$PN17" ] || fail "second run made another project: $(ls "$P17")"
[ "$(wc -l <"$P17/$PN17/agents.jsonl")" -ge 2 ] || fail "second agent not in the nvim registry"
"${H[@]}" pane close "$PANE17" >/dev/null
"${H[@]}" pane close "$PANE17B" >/dev/null
ok "cockpit-spawn.lua starts $N17 then $N17B in ck/nvim; project nvim created once"
# two launches at once (two `claude` in the same repo): different names, each attached to its own pane
spawn17p() {
  TMUX=dummy COCKPIT_PROJECTS_DIR=$P17 nvim --headless -u NONE -i NONE --cmd "set rtp^=$NVIM_CFG" \
    -l "$NVIM_CFG/scripts/cockpit-spawn.lua" -- "$NVIM_CFG" </dev/null >"$T/s17$1.out" 2>"$T/s17$1.err"
}
spawn17p x &
PX=$!
spawn17p y &
PY=$!
wait "$PX" "$PY" || true # not a bare wait: the ckspike server is a background job too
read -r N17X PANE17X TERM17X <"$T/s17x.out" || true
read -r N17Y PANE17Y TERM17Y <"$T/s17y.out" || true
[ -n "$N17X" ] && [ -n "$N17Y" ] || { cat "$T/s17x.err" "$T/s17y.err"; fail "concurrent spawn printed '$N17X' / '$N17Y'"; }
[ "$N17X" != "$N17Y" ] && [ "$PANE17X" != "$PANE17Y" ] || fail "concurrent spawns share an agent: $N17X@$PANE17X / $N17Y@$PANE17Y"
for k in x y; do
  read -r n_ p_ t_ <"$T/s17$k.out"
  J=$("${H[@]}" agent get "$n_") || fail "$n_ not live"
  [ "$(jget 'd["result"]["agent"]["pane_id"]' <<<"$J")" = "$p_" ] || fail "$n_ is not in the pane its spawn printed ($p_)"
  [ "$(jget 'd["result"]["agent"]["terminal_id"]' <<<"$J")" = "$t_" ] || fail "$n_ terminal_id mismatch"
done
"${H[@]}" pane close "$PANE17X" >/dev/null
"${H[@]}" pane close "$PANE17Y" >/dev/null
ok "two concurrent spawns -> $N17X and $N17Y, each in its own pane"
# the launcher marks the attach for the Stop hook: ATTACH_DIR/<terminal_id> = its $TMUX_PANE, removed after
REAL_HERDR=$(command -v herdr)
mkdir -p "$T/bin17h"
cat >"$T/bin17h/herdr" <<SH
#!/bin/sh
case " \$* " in
*" agent attach "*) ls "\$COCKPIT_ATTACH_DIR" >"$T/att17.ls"; cat "\$COCKPIT_ATTACH_DIR"/* >"$T/att17.cat"; exit 0 ;;
esac
exec "$REAL_HERDR" "\$@"
SH
chmod +x "$T/bin17h/herdr"
(cd "$NVIM_CFG" && TMUX=dummy TMUX_PANE=%77 PATH="$T/bin17h:$PATH" COCKPIT_PROJECTS_DIR=$P17 COCKPIT_ATTACH_DIR="$T/att17" \
  "$NVIM_CFG/scripts/cockpit-claude" </dev/null >"$T/l17.out" 2>"$T/l17.err") || { cat "$T/l17.err"; fail "launcher exited non-zero"; }
[ "$(cat "$T/att17.cat" 2>/dev/null)" = "%77" ] || { cat "$T/l17.err"; fail "no attach marker with %77 during attach: '$(cat "$T/att17.cat" 2>/dev/null)'"; }
TERM17L=$(cat "$T/att17.ls")
[[ $TERM17L == term_* ]] || fail "attach marker not named by terminal_id: $TERM17L"
[ -z "$(ls -A "$T/att17")" ] || fail "attach marker left behind: $(ls -A "$T/att17")"
PANE17L=$("${H[@]}" agent list | python3 -c '
import sys, json
print(next(a["pane_id"] for a in json.load(sys.stdin)["result"]["agents"] if a.get("terminal_id") == sys.argv[1]))
' "$TERM17L") || fail "launcher agent $TERM17L not live"
"${H[@]}" pane close "$PANE17L" >/dev/null
ok "launcher: attach marker $TERM17L = %77 while attached, removed after"
# worktrees resolve to their main repo (temp repo, no herdr)
R17=$T/r17
git init -q "$R17" && git -C "$R17" commit -q --allow-empty -m init && git -C "$R17" worktree add -q "$R17/.wt" -b wt17 2>/dev/null
mkdir -p "$T/plain17"
cat >"$T/t17.lua" <<LUA
local projects = require("cockpit.projects")
local a = projects.for_dir("$R17")
local b = projects.for_dir("$R17/.wt")
assert(a == "r17" and b == "r17", tostring(a) .. " / " .. tostring(b))
assert(projects.for_dir("$T/plain17") == "plain17", "non-git dir: " .. tostring(projects.for_dir("$T/plain17")))
assert(projects.for_dir(vim.fn.expand("~")) == nil, "\$HOME got a project")
print("T17 OK")
LUA
COCKPIT_PROJECTS_DIR=$P17 nlua "$T/t17.lua" 2>&1 | tee "$T/t17.out" | grep -q "T17 OK" || { cat "$T/t17.out"; fail "for_dir worktree"; }
ok "for_dir: a worktree maps to its main repo's project; non-git dir -> own project; \$HOME -> nil"
# bypass: plain claude, no herdr session touched
V17=$(TMUX=dummy COCKPIT_NO_HERDR=1 COCKPIT_HERDR_SESSION=ck17none "$NVIM_CFG/scripts/cockpit-claude" --version 2>&1) || fail "bypass --version failed: $V17"
[[ $V17 == *"Claude Code"* ]] || fail "bypass printed: $V17"
[ ! -e ~/.config/herdr/sessions/ck17none ] || fail "bypass touched herdr"
ok "COCKPIT_NO_HERDR=1 cockpit-claude --version -> $V17 (no herdr)"
# launched from a subdirectory with a spaced arg and an exported var: pane cwd, argv and env follow
(cd "$NVIM_CFG/lua" && TMUX=dummy FOO17=bar17 COCKPIT_PROJECTS_DIR=$P17 nvim --headless -u NONE -i NONE \
  --cmd "set rtp^=$NVIM_CFG" -l "$NVIM_CFG/scripts/cockpit-spawn.lua" -- "$PWD" --append-system-prompt "a b" \
  </dev/null >"$T/s17c.out" 2>"$T/s17.err") || { cat "$T/s17.err"; fail "spawn from subdir"; }
read -r N17C PANE17C _ <"$T/s17c.out"
CWD17=$("${H[@]}" agent get "$N17C" | jget 'd["result"]["agent"]["cwd"]')
[ "$CWD17" = "$NVIM_CFG/lua" ] || fail "$N17C cwd $CWD17, want $NVIM_CFG/lua"
# the launcher returns at launch (no readiness wait): give claude a moment to become the foreground process
for _ in $(seq 30); do
  PID17=$("${H[@]}" pane process-info --pane "$PANE17C" | python3 -c '
import sys, json
procs = json.load(sys.stdin)["result"]["process_info"]["foreground_processes"]
hit = [p for p in procs if "a b" in (p.get("argv") or []) and "--append-system-prompt" in p["argv"]]
assert hit, [p.get("argv") for p in procs]
print(hit[0]["pid"])
' 2>"$T/p17.err") && break
  sleep 0.5
done
[ -n "${PID17:-}" ] || { cat "$T/p17.err"; fail "$N17C argv lost the spaced arg"; }
ps -wwE -p "$PID17" | grep -q "FOO17=bar17" || fail "$N17C env lacks FOO17"
! ps -wwE -p "$PID17" | grep -q "TMUX=dummy" || fail "$N17C env leaked TMUX"
"${H[@]}" pane close "$PANE17C" >/dev/null
ok "spawn from nvim/lua: pane cwd = nvim/lua, --append-system-prompt \"a b\" one argv item, FOO17 forwarded, TMUX not"
# $HOME: silent plain claude (stub), no herdr session started
mkdir -p "$T/bin17"
printf '#!/bin/sh\necho "PLAIN $*"\n' >"$T/bin17/claude" && chmod +x "$T/bin17/claude"
O17=$(cd ~ && TMUX=dummy PATH="$T/bin17:$PATH" COCKPIT_HERDR_SESSION=ck17none "$NVIM_CFG/scripts/cockpit-claude" --model x 2>"$T/s17n.err")
[ "$O17" = "PLAIN --model x" ] || fail "\$HOME launcher printed: $O17"
[ ! -s "$T/s17n.err" ] || fail "\$HOME bypass warned: $(cat "$T/s17n.err")"
[ ! -e ~/.config/herdr/sessions/ck17none ] || fail "\$HOME bypass touched herdr"
ok "\$HOME: silent plain claude, no herdr"
[ "$LAST" -le 17 ] && exit 0

# --- 18: rail `s` spawns into the row's project; launcher spawn skips the readiness wait (headless) -----
echo "18: rail s + non-interactive start"
cat >"$T/t18.lua" <<'LUA'
vim.env.COCKPIT_HERDR_SESSION = "ck18none" -- no herdr: agents are stubbed
local h, store, registry, projects = require("cockpit.herdr"), require("cockpit.inbox.store"), require("cockpit.registry"), require("cockpit.projects")
require("cockpit.inbox").setup()
local ui, rail = require("cockpit.inbox.ui"), require("cockpit.inbox.rail")
projects.save({ name = "s18", repos = { vim.env.NVIM_CFG } })
projects.save({ name = "s18b", repos = { vim.env.NVIM_CFG } })
registry.append("s18", { name = "s18-old", terminal_id = "term_d18", project = "s18" })
h.agents = function()
  return { ["s18b-1"] = { name = "s18b-1", target = "s18b-1", project = "s18b", status = "idle", terminal_id = "term_l18", pane_id = "p18" } }
end
local function seed(id, project, tid)
  store.append(store.thread_file(id), { kind = "message", title = id, project = project, text = "x", ts = os.time(),
    session = tid and { herdr = { terminal_id = tid } } or { agent = "a" } })
end
seed("t18l", "s18b", "term_l18")
seed("t18d", "s18", "term_d18")
seed("t18o", nil, nil)
local spawned
ui.spawn = function(p) spawned = p == nil and "PICK" or p end
ui.open()
local buf = vim.fn.bufnr("cockpit://rail")
local win = vim.fn.win_findbuf(buf)[1]
vim.api.nvim_set_current_win(win)
vim.cmd("normal! zR")
local want = { header = "PICK", ["p:s18"] = "s18", ["past:s18"] = "s18", ["a:term_d18"] = "s18", ["t:t18d"] = "s18",
  ["p:s18b"] = "s18b", ["a:term_l18"] = "s18b", ["t:t18l"] = "s18b", unassigned = "PICK", ["t:t18o"] = "PICK" }
for key, exp in pairs(want) do
  local row = rail.row(buf, key)
  assert(row, "no row " .. key .. ":\n" .. table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
  vim.api.nvim_win_set_cursor(win, { row, 0 })
  spawned = nil
  vim.cmd("normal s")
  assert(spawned == exp, ("s on %s spawned %s, want %s"):format(key, tostring(spawned), exp))
end
print("T18a OK")

-- start_in with interactive = false (the launcher): registers at launch and returns, no agent.wait
local calls = {}
h.request = function(method, params, cb)
  calls[#calls + 1] = method
  local res = method == "agent.get" and { agent = { name = params.target, terminal_id = "term_s18", pane_id = "p18", agent_status = "working" } } or {}
  if cb then
    vim.schedule(function() cb(nil, res) end)
    return
  end
  return nil, res
end
local got
h.start_in("p18", "s18-9", {}, { project = "s18" }, function(err, name) got = { err = err, name = name } end, { interactive = false })
assert(vim.wait(5000, function() return got ~= nil end), "start_in never called back")
assert(got.err == nil and got.name == "s18-9", vim.inspect(got))
assert(not vim.tbl_contains(calls, "agent.wait"), "non-interactive start waited for readiness: " .. table.concat(calls, ","))
assert(registry.by_terminal("s18", "term_s18"), "not registered at launch")
print("T18 OK")
LUA
NVIM_CFG=$NVIM_CFG nlua "$T/t18.lua" 2>&1 | tee "$T/t18.out" | grep -q "T18 OK" || { cat "$T/t18.out"; fail "section 18"; }
ok "rail s: project/past/agent/thread rows spawn into their project, header/unassigned pick; launcher start registers without waiting"
[ "$LAST" -le 18 ] && exit 0

echo "all sections passed"
