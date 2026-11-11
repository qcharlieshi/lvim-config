-- Headless entry for scripts/cockpit-claude: start a Claude agent in herdr for <cwd>'s project.
--   nvim --headless -u NONE --cmd "set rtp^=<nvim cfg>" -l scripts/cockpit-spawn.lua -- <cwd> <claude args…>
-- stdout: "<agent name> <pane id> <terminal id>" on success (also when blocked at startup: attach answers it).
-- exit 1 with a one-line reason on stderr otherwise.
local argv = vim.deepcopy(_G.arg)
if argv[1] == "--" then
  table.remove(argv, 1)
end
local cwd = table.remove(argv, 1)

local function die(msg)
  io.stderr:write("cockpit: " .. msg .. "\n")
  os.exit(1)
end

vim.notify = function() end -- herdr.lua notifies; the launcher prints its own one line
local herdr = require("cockpit.herdr")
if not cwd or not herdr.ensure() then
  die("herdr server not running")
end
local project = require("cockpit.projects").for_dir(cwd)
if not project then
  die("not in a git repo") -- the launcher checks this first and bypasses silently
end

-- Claude sees the launcher's environment (API keys, venv, `FOO=bar claude`), minus the tmux/herdr/
-- nvim bits that must not leak into a herdr pane; nvim adds VIMRUNTIME/MYVIMRC itself
local env = {}
for k, v in pairs(vim.fn.environ()) do
  if not (k == "TMUX" or k == "TMUX_PANE" or k == "COCKPIT_NO_HERDR" or k == "VIMRUNTIME" or k == "MYVIMRC"
    or k:match("^HERDR_") or k:match("^NVIM")) then
    env[k] = v
  end
end

local got, pane
herdr.spawn(project, nil, function(err, name, pane_id)
  got = { err = err, name = name, pane_id = pane_id }
end, { args = argv, interactive = false, cwd = cwd, env = env, on_pane = function(id)
  pane = id
end })
-- the fresh pane spawn made: closed on every failure, so no stray shell (or late headless Claude) is left
local function give_up(msg)
  if pane then
    herdr.request("pane.close", { pane_id = pane })
  end
  die(msg)
end
-- non-interactive start returns at launch: ≤ 1.5 s defer + agent.start's 70 s client timeout + agent.get
if not vim.wait(120000, function()
  return got ~= nil
end, 50) then
  give_up("spawn timed out")
end
-- An agent that exists is attachable whatever start said (blocked at a dialog, slow reply) — but only the
-- one in our pane: a name clash would find another launch's agent under that name
local a
if got.name then
  local _, res = herdr.request("agent.get", { target = got.name })
  a = res and res.agent
end
if not a or a.pane_id ~= pane or not a.terminal_id then
  give_up("spawn failed — " .. (got.err and (got.err.message or got.err.code)
    or (a and "name " .. got.name .. " belongs to another agent" or "agent not found after start")))
end
io.stdout:write(got.name .. " " .. a.pane_id .. " " .. a.terminal_id .. "\n")
os.exit(0)
