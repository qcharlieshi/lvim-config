-- cockpit coordinator: one long-lived, barebones Claude session (herdr agent in its own `cockpit` project) that
-- you ask from anywhere in nvim. It answers, keeps SCRATCHPAD.md, and spawns / forks / prompts agents through
-- scripts/cockpit-ctl. Its context is kept small: own system prompt, few tools, no MCP or skills, asks carry
-- references, and instead of autocompact it is rotated (checkpoint the scratchpad, end, restart fresh on the next ask)
-- once it passes vim.g.cockpit_coordinator_rotate_tokens.
local M = {}

M.PROJECT = "cockpit"
M.NAME = "cockpit-coordinator"
M.DIR = vim.fn.expand(vim.env.COCKPIT_COORDINATOR_DIR or "~/.cockpit/coordinator")
local ROOT = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
M.CTL = ROOT .. "/scripts/cockpit-ctl"
M.TOOLS = "Bash,Read,Grep,Glob,Edit,Write"
M.CHECKPOINT = "[cockpit] checkpoint: this conversation is about to be rotated. Update SCRATCHPAD.md and TODO.md "
  .. "with everything worth keeping (record agent purposes with cockpit-ctl purpose), then reply `done`."

local SEED = {
  "# Coordinator scratchpad",
  "",
  "## Now",
  "",
  "## Decisions",
  "",
  "## Open questions",
  "",
  "## Notes",
}

local rot -- in-flight rotation: { target, at, saw_working }
local needs_seed = false -- a fresh session hasn't had the scratchpad yet (e.g. its start stopped at the trust dialog)
local starting -- callbacks waiting for a coordinator that is being started
local timer

function M.threshold()
  return vim.g.cockpit_coordinator_rotate_tokens or 120000
end

function M.scratchpad()
  return M.DIR .. "/SCRATCHPAD.md"
end

function M.todo()
  return M.DIR .. "/TODO.md"
end

-- the cockpit project (dir = M.DIR) and the scratchpad, created on first use
function M.ensure_project()
  local projects = require("cockpit.projects")
  vim.fn.mkdir(M.DIR, "p")
  if vim.fn.filereadable(M.scratchpad()) == 0 then
    vim.fn.writefile(SEED, M.scratchpad())
  end
  if vim.fn.filereadable(M.todo()) == 0 then
    vim.fn.writefile({ "# TODO", "" }, M.todo())
  end
  local p = projects.get(M.PROJECT)
  if not p then
    p = { name = M.PROJECT, repos = { M.DIR } }
    projects.save(p)
  end
  return p
end

-- permission rule path: ~/x for paths under $HOME, //abs otherwise
local function rule_path(path)
  local home = vim.fn.expand("~")
  if path:sub(1, #home + 1) == home .. "/" then
    return "~" .. path:sub(#home + 1)
  end
  return "/" .. path
end

function M.settings()
  local allow = {
    "Bash(" .. M.CTL .. ":*)",
    "Read(~/dev/**)",
    "Read(~/.config/**)",
    "Read(~/.cockpit/**)",
    "Edit(" .. rule_path(M.DIR) .. "/**)",
    "Write(" .. rule_path(M.DIR) .. "/**)",
  }
  for _, p in ipairs(require("cockpit.projects").list()) do
    for _, r in ipairs(p.repos) do
      allow[#allow + 1] = "Read(" .. rule_path(r) .. "/**)"
    end
  end
  return { permissions = { allow = allow } }
end

-- the system prompt with this machine's paths filled in; returns its path
function M.system_prompt()
  local src = table.concat(vim.fn.readfile(ROOT .. "/scripts/cockpit-coordinator.md"), "\n")
  local text = src:gsub("{{CTL}}", (M.CTL:gsub("%%", "%%%%"))):gsub("{{DIR}}", (M.DIR:gsub("%%", "%%%%")))
  local path = M.DIR .. "/system-prompt.md"
  vim.fn.writefile(vim.split(text, "\n"), path)
  return path
end

-- claude flags on top of the `coordinator` profile (model/effort): the barebones part
function M.args(resume)
  local args = {}
  if resume then
    vim.list_extend(args, { "--resume", resume })
  end
  vim.list_extend(args, {
    "--system-prompt-file",
    M.system_prompt(),
    "--tools",
    M.TOOLS,
    "--strict-mcp-config",
    "--disable-slash-commands",
    "--settings",
    vim.json.encode(M.settings()),
  })
  return args
end

-- the live coordinator (herdr cache entry) or nil
function M.agent()
  for _, a in pairs(require("cockpit.herdr").agents()) do
    if a.project == M.PROJECT then
      return a
    end
  end
end

-- the session to resume: newest record that wasn't ended (rotated / killed) and still has a transcript
local function resumable()
  local best
  for _, rec in pairs(require("cockpit.registry").all(M.PROJECT)) do
    if rec.session and not rec.dead and (not best or (rec.ts or 0) > (best.ts or 0)) then
      best = rec
    end
  end
  local claude_dir = vim.env.CLAUDE_CONFIG_DIR or vim.fn.expand("~/.claude")
  if best and #vim.fn.glob(claude_dir .. "/projects/*/" .. best.session .. ".jsonl", false, true) > 0 then
    return best.session
  end
end

-- a stale O_EXCL name claim would make the next start "cockpit-coordinator-2"
local function release_name()
  vim.uv.fs_unlink(require("cockpit.projects").root(M.PROJECT) .. "/names/" .. M.NAME)
end

-- cb(err, agent, fresh): the live coordinator, started (resumed when possible) if needed
function M.ensure(cb)
  local a = M.agent()
  if a then
    return cb(nil, a, false)
  end
  if starting then
    starting[#starting + 1] = cb
    return
  end
  starting = { cb }
  M.ensure_project()
  release_name()
  local sid = resumable()
  vim.notify("cockpit: " .. (sid and "resuming" or "starting") .. " the coordinator…")
  local herdr = require("cockpit.herdr")
  herdr.spawn(M.PROJECT, nil, function(err, name)
    herdr.reconcile(function()
      local waiting = starting or {}
      starting = nil
      local got = M.agent() or (name and { target = name, name = name })
      for _, f in ipairs(waiting) do
        f(err, got, sid == nil)
      end
    end)
  end, { profile = "coordinator", name = M.NAME, args = M.args(sid) })
end

-- the nvim the coordinator's cockpit-ctl talks to: whichever one asked last
function M.remember_nvim()
  if vim.v.servername ~= "" then
    vim.fn.mkdir(M.DIR, "p")
    vim.fn.writefile({ vim.v.servername }, M.DIR .. "/nvim")
  end
end

local function seed_prefix()
  local out = { "[cockpit] Fresh session. Your notes files:" }
  for _, path in ipairs({ M.scratchpad(), M.todo() }) do
    if vim.fn.filereadable(path) == 1 then
      vim.list_extend(out, { "", "### " .. path, "", table.concat(vim.fn.readfile(path), "\n") })
    end
  end
  return table.concat(out, "\n") .. "\n\n---\n\n"
end

-- Fire `text` at the coordinator (starting it if needed); a fresh session gets the scratchpad first
function M.send(text)
  M.remember_nvim()
  M.ensure(function(err, a, fresh)
    needs_seed = needs_seed or fresh
    if err and err.code == "agent_not_ready" then
      return vim.notify(
        "cockpit: the coordinator is waiting at a startup dialog (folder trust on first run) — "
          .. "attach (rail gT) and accept it, then ask again",
        vim.log.levels.WARN
      )
    elseif err or not a then
      return vim.notify(
        "cockpit: coordinator unavailable — " .. (err and (err.message or err.code) or "didn't start"),
        vim.log.levels.ERROR
      )
    end
    local msg, sent = require("cockpit.herdr").prompt(a.target, (needs_seed and seed_prefix() or "") .. text)
    if sent then
      needs_seed = false
    end
    vim.notify("cockpit → coordinator: " .. msg, sent and vim.log.levels.INFO or vim.log.levels.WARN)
  end)
end

-- context size of the coordinator's conversation (tokens), from its statusline file / transcript
function M.tokens(a)
  local s = require("cockpit.sessions").by_herdr_pane()[a.pane_id]
  if not s then
    return nil
  end
  if s.tokens then
    return s.tokens
  end
  return s.ctx_pct and s.ctx_size and math.floor(s.ctx_pct * s.ctx_size / 100) or nil
end

-- herdr reports a finished turn nobody looked at yet as "done": as quiet as idle
local function quiet(status)
  return status == "idle" or status == "done"
end

function M.should_rotate(tokens, status, threshold)
  return quiet(status) and tokens ~= nil and tokens >= threshold
end

-- end the checkpointed conversation; the next ask starts fresh from the scratchpad
local function finish(a)
  rot = nil
  local registry = require("cockpit.registry")
  local rec = registry.by_terminal(M.PROJECT, a.terminal_id)
  require("cockpit.herdr").kill(a.target)
  if rec then
    registry.append(
      M.PROJECT,
      vim.tbl_extend("force", rec, { session = a.session_id or rec.session, dead = true, rotated = true })
    )
  end
  release_name()
  vim.notify("cockpit: coordinator rotated — the next ask starts fresh from SCRATCHPAD.md")
end

-- Ask the coordinator to checkpoint its scratchpad; check() ends it once that turn is over
function M.rotate()
  local a = M.agent()
  if not a then
    return vim.notify("cockpit: no coordinator running")
  end
  if rot then
    return vim.notify("cockpit: coordinator rotation already in progress")
  end
  local msg, ok = require("cockpit.herdr").prompt(a.target, M.CHECKPOINT)
  if not ok then
    return vim.notify("cockpit: rotation checkpoint failed — " .. msg, vim.log.levels.WARN)
  end
  rot = { target = a.target, at = os.time(), saw_working = false }
  vim.notify("cockpit: rotating the coordinator (checkpointing its scratchpad)")
end

-- Runs on every agent-cache change and on a slow timer
function M.check()
  local a = M.agent()
  if not a then
    rot = nil
    return
  end
  if rot then
    if a.status == "working" then
      rot.saw_working = true
    end
    -- 10 min cap: a checkpoint that never shows up as working (missed transition) still ends
    if (rot.saw_working and quiet(a.status)) or os.time() - rot.at > 600 then
      finish(a)
    end
    return
  end
  if M.should_rotate(M.tokens(a), a.status, M.threshold()) then
    M.rotate()
  end
end

-- Show the coordinator's conversation in the cockpit (thread window)
function M.open()
  local a = M.agent()
  if not a then
    return vim.notify("cockpit: no coordinator running — <leader>kk to ask it something")
  end
  local ui, rail = require("cockpit.inbox.ui"), require("cockpit.inbox.rail")
  ui.open()
  local rb = ui.rail_buf()
  ui.render_rail(rb)
  local row = rail.row(rb, "a:" .. (a.session_id or ("term:" .. a.terminal_id)))
  local node = row and rail.node(rb, row)
  if node then
    ui.select_agent(node)
  end
end

function M.setup()
  local group = vim.api.nvim_create_augroup("cockpit_coordinator", { clear = true })
  vim.api.nvim_create_autocmd("User", { group = group, pattern = "CockpitAgents", callback = M.check })
  -- the herdr cache only follows events while the cockpit is closed; poll the coordinator's state slowly
  timer = timer or assert(vim.uv.new_timer())
  timer:start(
    20000,
    20000,
    vim.schedule_wrap(function()
      if M.agent() or rot then
        require("cockpit.herdr").reconcile(M.check)
      end
    end)
  )
end

return M
