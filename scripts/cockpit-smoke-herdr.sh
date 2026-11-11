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
assert(vim.fn.filereadable(vim.env.COCKPIT_PROJECTS_DIR .. "/smoke.json") == 1, "smoke.json not written")
assert(#projects.list() == 1 and projects.list()[1].name == "smoke", "list")
print("T3 OK")
LUA
nlua "$T/t3.lua" 2>&1 | tee "$T/t3.out" | grep -q "T3 OK" || { cat "$T/t3.out"; fail "section 3"; }
ok "projects.new() writes smoke.json with primary + extra repo"
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

echo "all sections passed"
