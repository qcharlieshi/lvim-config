-- cockpit-ctl, nvim side: a fixed, terse API the coordinator drives over this nvim's socket
-- (scripts/cockpit_ctl.py → exec_lua). One line per item: its output lands in the coordinator's context.
-- run(argv) -> { code = 0|1|64, out = string }
local M = {}

local HELP = [[cockpit-ctl — the coordinator's CLI (one line per item)
  agents                                        live agents: name · status · project · context · ✋ waiting · purpose · last words
  threads [--needs-you]                         open inbox threads, newest first
  projects                                      cockpit projects and their dirs
  spawn <project> [--profile P] [--name N] [--dir D] <prompt>
  fork <agent> continue|worktree <prompt>
  prompt <agent> [--now] <text>                 refused while the agent is working, unless --now
  reply <thread> [--verdict V] <text>           reply for the engineer; V: approve approve_with_notes changes_requested reject
  kill <agent>                                  end an agent, archive its threads
  purpose <agent> <text>                        record what an agent is for (shown by agents)
  ask [--fork <agent>] <question>               one-off Claude session; prints only its answer
  open <file> [line]                            open a file in the engineer's nvim
  bridge <command> [args]                       nvim bridge: open_many harpoon_add mark trail scoped_grep buffers cursor state]]

local function ok(out)
  return { code = 0, out = out }
end

local function fail(out, code)
  return { code = code or 1, out = out }
end

local function trunc(s, n)
  s = (s or ""):gsub("%s+", " ")
  return vim.fn.strchars(s) > n and vim.fn.strcharpart(s, 0, n - 1) .. "…" or s
end

-- split argv into flags (--k v, or --k alone when listed in `bools`) and the remaining words
local function parse(argv, bools)
  local flags, rest, i = {}, {}, 1
  while i <= #argv do
    local k = argv[i]:match("^%-%-([%w-]+)$")
    if k and bools and bools[k] then
      flags[k] = true
    elseif k and argv[i + 1] then
      flags[k] = argv[i + 1]
      i = i + 1
    else
      rest[#rest + 1] = argv[i]
    end
    i = i + 1
  end
  return flags, rest
end

-- the herdr cache only follows events; the coordinator acts on what it reads, so refresh first (≤ 3 s)
local function fresh_agents()
  local herdr = require("cockpit.herdr")
  if herdr.reconcile then
    local done = false
    herdr.reconcile(function()
      done = true
    end)
    vim.wait(3000, function()
      return done
    end, 20)
  end
  return herdr.agents()
end

local function agent_named(name)
  local agents = fresh_agents()
  if agents[name] then
    return agents[name]
  end
  for _, a in pairs(agents) do
    if a.name == name or a.target == name then
      return a
    end
  end
end

local function ctx(s)
  if s.tokens then
    return math.floor(s.tokens / 1000) .. "k"
  end
  return s.ctx_pct and (s.ctx_pct .. "%") or "?"
end

local cmds = {}

function cmds.help()
  return ok(HELP)
end

function cmds.agents()
  local by_pane = require("cockpit.sessions").by_herdr_pane()
  local list = vim.tbl_values(fresh_agents())
  if #list == 0 then
    return ok("no live agents")
  end
  table.sort(list, function(a, b)
    if (a.project or "") ~= (b.project or "") then
      return (a.project or "") < (b.project or "")
    end
    return a.target < b.target
  end)
  local coord = require("cockpit.coordinator").PROJECT
  local registry, tree = require("cockpit.registry"), require("cockpit.inbox.tree")
  local waiting = {} -- session id -> threads waiting on the engineer
  for _, t in ipairs(require("cockpit.inbox.store").threads()) do
    local key = not t.archived and t.status == "needs_you" and tree.owner_key(t)
    if key then
      waiting[key] = (waiting[key] or 0) + 1
    end
  end
  local lines = {}
  for _, a in ipairs(list) do
    local s = by_pane[a.pane_id] or {}
    local rec = a.project and registry.by_terminal(a.project, a.terminal_id)
    local what = rec and (rec.purpose or (rec.prompt and ("prompt: " .. rec.prompt)))
    local parts = {
      (a.name or a.target) .. (a.project == coord and " (you)" or ""),
      a.status or "?",
      a.project or "—",
      "ctx " .. ctx(s),
    }
    if waiting[a.session_id] then
      parts[#parts + 1] = "✋" .. waiting[a.session_id]
    end
    if what then
      parts[#parts + 1] = "for: " .. trunc(what, 80)
    end
    parts[#parts + 1] = trunc(s.text or a.title or "", 80)
    lines[#lines + 1] = table.concat(parts, " · ")
  end
  return ok(table.concat(lines, "\n"))
end

function cmds.threads(argv)
  local flags = parse(argv, { ["needs-you"] = true })
  local list = vim.tbl_filter(function(t)
    return not t.archived and (not flags["needs-you"] or t.status == "needs_you")
  end, require("cockpit.inbox.store").threads())
  if #list == 0 then
    return ok("no open threads")
  end
  table.sort(list, function(a, b)
    return (a.last_ts or 0) > (b.last_ts or 0)
  end)
  local lines = {}
  for i = 1, math.min(#list, 30) do
    local t = list[i]
    lines[#lines + 1] = ("%s · %s · %s · %s"):format(t.id, t.status, t.project or "—", trunc(t.title or "", 80))
  end
  if #list > 30 then
    lines[#lines + 1] = ("… %d more"):format(#list - 30)
  end
  return ok(table.concat(lines, "\n"))
end

function cmds.projects()
  local home = vim.fn.expand("~")
  local lines = {}
  for _, p in ipairs(require("cockpit.projects").list()) do
    local dirs = vim.tbl_map(function(r)
      return r:sub(1, #home) == home and ("~" .. r:sub(#home + 1)) or r
    end, p.repos)
    lines[#lines + 1] = p.name .. " · " .. table.concat(dirs, ", ") .. (p.ticket and (" · " .. p.ticket) or "")
  end
  return ok(#lines > 0 and table.concat(lines, "\n") or "no projects")
end

function cmds.spawn(argv)
  local flags, rest = parse(argv)
  local project = table.remove(rest, 1)
  local prompt = table.concat(rest, " ")
  if not project or prompt == "" then
    return fail("usage: spawn <project> [--profile P] [--name N] [--dir D] <prompt>", 64)
  end
  if not require("cockpit.projects").get(project) then
    return fail("no project " .. project .. " (see: projects)")
  end
  local name, err
  require("cockpit.herdr").spawn(project, prompt, function(serr, started)
    err = serr
    if serr then
      vim.notify("cockpit: coordinator's spawn failed — " .. (serr.message or serr.code), vim.log.levels.WARN)
    else
      vim.notify("cockpit: coordinator spawned " .. started)
    end
  end, {
    profile = flags.profile,
    name = flags.name,
    dir = flags.dir and vim.fn.expand(flags.dir),
    interactive = false,
    on_pane = function(_, n)
      name = n
    end,
  })
  if err then
    return fail("spawn failed: " .. (err.message or err.code))
  end
  return ok(
    ("spawning %s in %s — it gets the prompt once ready (~10 s); check with: agents"):format(name or "?", project)
  )
end

function cmds.fork(argv)
  local name, kind = argv[1], argv[2]
  local prompt = table.concat(vim.list_slice(argv, 3), " ")
  if not name or not (kind == "continue" or kind == "worktree") then
    return fail("usage: fork <agent> continue|worktree <prompt>", 64)
  end
  local a = agent_named(name)
  if not a then
    return fail("no live agent " .. name .. " (see: agents)")
  end
  local rec = a.project and require("cockpit.registry").by_terminal(a.project, a.terminal_id)
  local err
  require("cockpit.forks")[kind](a, prompt, function(ferr, started)
    err = ferr
    if not ferr then
      vim.notify("cockpit: coordinator forked " .. name .. " → " .. tostring(started))
    end
  end, rec and rec.profile)
  if err and err.code ~= "agent_not_ready" then
    return fail("fork failed: " .. (err.message or err.code))
  end
  return ok(("forking %s (%s) — check with: agents"):format(name, kind))
end

function cmds.prompt(argv)
  local flags, rest = parse(argv, { now = true })
  local name = table.remove(rest, 1)
  local text = table.concat(rest, " ")
  if not name or text == "" then
    return fail("usage: prompt <agent> [--now] <text>", 64)
  end
  local a = agent_named(name)
  if not a then
    return fail("no live agent " .. name .. " (see: agents)")
  end
  if a.status == "working" and not flags.now then
    return fail(name .. " is working — retry when idle, or pass --now (the message lands mid-turn)")
  end
  local msg, sent = require("cockpit.herdr").prompt(a.target, text)
  return sent and ok(msg) or fail(msg)
end

local VERDICTS = { approve = true, approve_with_notes = true, changes_requested = true, reject = true }

-- The engineer's reply, relayed verbatim on their instruction: a normal reply event (delivered like one sent from the
-- cockpit), tagged relayed_by = "coordinator" so feedback.jsonl can tell them apart. Pending notes stay drafts.
function cmds.reply(argv)
  local flags, rest = parse(argv)
  local tid = table.remove(rest, 1)
  local text = table.concat(rest, " ")
  local verdict = flags.verdict
  if not tid or (text == "" and not verdict) then
    return fail("usage: reply <thread> [--verdict V] <text>", 64)
  end
  if verdict and not VERDICTS[verdict] then
    return fail("verdict must be one of: approve approve_with_notes changes_requested reject", 64)
  end
  if (verdict == "changes_requested" or verdict == "reject") and text == "" then
    return fail("say what to change", 64)
  end
  local store = require("cockpit.inbox.store")
  local t = store.valid_id(tid) and store.thread(tid)
  if not t then
    return fail("no thread " .. tid .. " (see: threads)")
  end
  local reply = store.append(store.thread_file(tid), {
    kind = "reply",
    from = "human",
    relayed_by = "coordinator",
    verdict = verdict,
    stage = t.stage,
    round = t.round,
    text = text,
    answers = {},
    annotations = {},
  })
  store.ledger(t, reply)
  local how = store.deliver(t)
  pcall(function()
    require("cockpit.inbox.ui").refresh()
  end)
  return ok(("replied to %s%s · %s"):format(tid, verdict and (" (" .. verdict .. ")") or "", how))
end

function cmds.kill(argv)
  local a = argv[1] and agent_named(argv[1])
  if not a then
    return fail("no live agent " .. tostring(argv[1]) .. " (see: agents)")
  end
  if a.project == require("cockpit.coordinator").PROJECT then
    return fail("that's you — the engineer rotates the coordinator with <leader>kR")
  end
  require("cockpit.inbox.rail").kill_agent(a, { confirmed = true })
  return ok("killed " .. (a.name or a.target))
end

function cmds.purpose(argv)
  local a = argv[1] and agent_named(argv[1])
  local text = table.concat(vim.list_slice(argv, 2), " ")
  if not a or text == "" then
    return fail(a and "usage: purpose <agent> <text>" or ("no live agent " .. tostring(argv[1])), a and 64 or 1)
  end
  if not a.project then
    return fail((a.name or a.target) .. " isn't in a cockpit project")
  end
  local registry = require("cockpit.registry")
  local rec = registry.by_terminal(a.project, a.terminal_id)
    or { name = a.name, terminal_id = a.terminal_id, project = a.project }
  registry.append(
    a.project,
    vim.tbl_extend("force", rec, { session = a.session_id or rec.session, purpose = text:sub(1, 300) })
  )
  return ok("noted: " .. (a.name or a.target) .. " — " .. trunc(text, 80))
end

-- internal, for `ask --fork`: the agent's Claude session, dir and launch profile as JSON
function cmds.session(argv)
  local a = argv[1] and agent_named(argv[1])
  if not (a and a.session_id) then
    return fail("no live agent with a session: " .. tostring(argv[1]))
  end
  local rec = a.project and require("cockpit.registry").by_terminal(a.project, a.terminal_id)
  return ok(vim.json.encode({
    name = a.name or a.target,
    session = a.session_id,
    cwd = a.cwd,
    profile = rec and rec.profile or "default",
  }))
end

-- internal, for `ask`: claude flags of a profile as JSON
function cmds.profile_args(argv)
  return ok(vim.json.encode(require("cockpit.profiles").args(argv[1] or "ask")))
end

function M.run(argv)
  argv = argv or {}
  local cmd = cmds[argv[1] or "help"]
  if not cmd then
    return fail("unknown command " .. argv[1] .. "\n" .. HELP, 64)
  end
  local okc, res = pcall(cmd, vim.list_slice(argv, 2))
  if not okc then
    return fail("internal error: " .. tostring(res), 70)
  end
  return res
end

return M
