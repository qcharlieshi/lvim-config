-- Headless entry for scripts/cockpit-claude: start a Claude agent in herdr for <cwd>'s project.
--   nvim --headless -u NONE --cmd "set rtp^=<nvim cfg>" -l scripts/cockpit-spawn.lua -- <cwd> <claude args…>
-- stdout: "<agent name> <pane id>" on success (also when blocked at startup: attach answers it).
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

local got
herdr.spawn(project, nil, function(err, name, pane_id)
  got = { err = err, name = name, pane_id = pane_id }
end, { args = argv, interactive = false, cwd = cwd, env = env })
if not vim.wait(120000, function()
  return got ~= nil
end, 50) then
  die("spawn timed out")
end
-- An agent that exists is attachable whatever start said (blocked at a dialog, slow reply)
local a
if got.name then
  local _, res = herdr.request("agent.get", { target = got.name })
  a = res and res.agent
end
if not a then
  if got.pane_id then
    herdr.request("pane.close", { pane_id = got.pane_id }) -- the fresh pane spawn made: no stray shell
  end
  die("spawn failed — " .. (got.err and (got.err.message or got.err.code) or "agent not found after start"))
end
local name = got.name
io.stdout:write(name .. " " .. a.pane_id .. "\n")
os.exit(0)
