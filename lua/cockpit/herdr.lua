-- cockpit ↔ herdr: the only place nvim talks to the agent runtime (rented and disposable).
-- Speaks herdr's NDJSON socket API directly. Every call names its target explicitly — never --current (herdr #2900).
local M = {}

local uv = vim.uv
local seq = 0
local cache = {} -- key (agent name, else pane id) -> Agent
local labels = {} -- workspace_id -> label
local sub -- live events.subscribe pipe
local started = false
local reconciled = false -- the last reconcile reached herdr (else the cache says nothing about liveness)
local reconcile_timer, debounce_timer

local function session_args()
  local s = vim.env.COCKPIT_HERDR_SESSION
  return (s and s ~= "") and { "--session", s } or {}
end

function M.socket()
  local s = vim.env.COCKPIT_HERDR_SESSION
  local base = vim.fn.expand("~/.config/herdr")
  return (s and s ~= "") and (base .. "/sessions/" .. s .. "/herdr.sock") or (base .. "/herdr.sock")
end

-- herdr CLI argv with the session selected
function M.cli(...)
  return vim.list_extend(vim.list_extend({ "herdr" }, session_args()), { ... })
end

local function decode(line)
  local ok, v = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
  return ok and v or nil
end

-- One request per connection. Async with cb(err, result); sync (≤ 5 s) without, returning err, result.
-- Async calls time out client-side (default 30 s; a server-side wait in params + 10 s) with err.code "timeout".
function M.request(method, params, cb, opts)
  seq = seq + 1
  local id = "ck" .. seq
  local done, out_err, out_res = false, nil, nil
  local timer
  local function finish(err, res)
    if done then
      return
    end
    done, out_err, out_res = true, err, res
    if timer and not timer:is_closing() then
      timer:close()
    end
    if cb then
      vim.schedule(function()
        cb(err, res)
      end)
    end
  end
  local pipe = assert(uv.new_pipe(false))
  local function close_pipe()
    if not pipe:is_closing() then
      pipe:close()
    end
  end
  if cb then
    local ms = opts and opts.timeout_ms
    if not ms then
      local w = params and (params.timeout_ms or (params.wait and params.wait.timeout_ms))
      ms = w and (w + 10000) or 30000
    end
    timer = assert(uv.new_timer())
    timer:start(ms, 0, function()
      if not done then
        close_pipe()
        finish({ code = "timeout", message = method .. " timed out" })
      end
    end)
  end
  pipe:connect(M.socket(), function(cerr)
    if cerr then
      close_pipe()
      return finish({ code = "connect", message = cerr })
    end
    local buf = ""
    pipe:read_start(function(rerr, chunk)
      if rerr or not chunk then
        close_pipe()
        return finish({ code = "closed", message = rerr or "connection closed" })
      end
      buf = buf .. chunk
      for line in buf:gmatch("([^\n]*)\n") do
        local msg = decode(line)
        if msg and msg.id == id then
          pipe:read_stop()
          close_pipe()
          return finish(msg.error, msg.result)
        end
      end
      buf = buf:match("[^\n]*$")
    end)
    -- {} would encode as [] — herdr wants an object
    local p = (params and next(params)) and params or vim.empty_dict()
    pipe:write(vim.json.encode({ id = id, method = method, params = p }) .. "\n")
  end)
  if not cb then
    vim.wait(5000, function()
      return done
    end, 10)
    if not done then
      return { code = "timeout", message = method .. " timed out" }, nil
    end
    return out_err, out_res
  end
end

local function server_up()
  local r = vim.system(M.cli("status", "server"), { text = true }):wait()
  return (r.stdout or ""):find("status: running", 1, true) ~= nil
end

-- Make sure the herdr server for the selected session is running; start it detached if not.
function M.ensure()
  if server_up() then
    return true
  end
  local env = vim.fn.environ()
  env.TMUX, env.TMUX_PANE = nil, nil -- never leak tmux into herdr panes (#2134)
  -- nor this nvim: its runtime/config and server socket mean nothing to a shell in a herdr pane
  env.VIMRUNTIME, env.MYVIMRC = nil, nil
  for k in pairs(env) do
    if k:match("^NVIM") then
      env[k] = nil
    end
  end
  vim.system(M.cli("server"), { detach = true, env = env, clear_env = true, stdout = false, stderr = false })
  local ok = vim.wait(3000, server_up, 200)
  if not ok then
    vim.notify("cockpit: herdr server not running — see ~/.config/herdr/herdr-server.log", vim.log.levels.ERROR)
  end
  return ok
end

---------------------------------------------------------------------------
-- Agent cache
---------------------------------------------------------------------------

-- Cockpit owns only workspaces it labelled ck/<project>; a hand-opened workspace that merely
-- shares the project's name (labels default to the dir basename) is never adopted.
local PREFIX = "ck/"
local function project_for(workspace_id)
  local label = labels[workspace_id]
  local name = label and label:sub(1, #PREFIX) == PREFIX and label:sub(#PREFIX + 1)
  local ok, projects = pcall(require, "cockpit.projects")
  return (ok and name and projects.get(name)) and name or nil
end

local function fire()
  vim.api.nvim_exec_autocmds("User", { pattern = "CockpitAgents", modeline = false })
end

local function apply(agents)
  local next_cache = {}
  for _, a in ipairs(agents or {}) do
    local key = a.name or a.pane_id
    next_cache[key] = {
      name = a.name,
      target = key, -- agent commands accept a live name or the pane id
      kind = a.agent,
      project = project_for(a.workspace_id),
      status = a.agent_status,
      pane_id = a.pane_id,
      workspace_id = a.workspace_id,
      terminal_id = a.terminal_id,
      cwd = a.cwd,
      title = a.terminal_title_stripped or a.terminal_title,
    }
  end
  if not vim.deep_equal(next_cache, cache) then
    cache = next_cache
    fire()
  end
end

-- Pull agent.list + workspace labels; events only tell us *that* something changed
function M.reconcile(cb)
  M.request("workspace.list", {}, function(werr, ws)
    labels = {}
    for _, w in ipairs((ws or {}).workspaces or {}) do
      labels[w.workspace_id] = w.label
    end
    M.request("agent.list", {}, function(err, res)
      reconciled = not werr and not err
      if not err then
        apply(res.agents)
      end
      if cb then
        cb()
      end
    end)
  end)
end

local function schedule_reconcile()
  debounce_timer = debounce_timer or assert(uv.new_timer())
  debounce_timer:stop()
  debounce_timer:start(100, 0, vim.schedule_wrap(M.reconcile))
end

local EVENTS = { "pane.updated", "pane.created", "pane.closed", "pane.exited", "pane.agent_detected" }

local function subscribe()
  if sub or not started then
    return
  end
  local pipe = assert(uv.new_pipe(false))
  sub = pipe
  local function dropped()
    if sub == pipe then
      sub = nil
    end
    if not pipe:is_closing() then
      pipe:close()
    end
    if started then
      vim.defer_fn(subscribe, 2000)
    end
  end
  pipe:connect(M.socket(), function(cerr)
    if cerr then
      return dropped()
    end
    local subs = vim.tbl_map(function(t)
      return { type = t }
    end, EVENTS)
    pipe:write(vim.json.encode({ id = "cksub", method = "events.subscribe", params = { subscriptions = subs } }) .. "\n")
    local buf = ""
    pipe:read_start(function(rerr, chunk)
      if rerr or not chunk then
        return dropped()
      end
      buf = buf .. chunk
      if buf:find("\n") then
        buf = buf:match("[^\n]*$")
        schedule_reconcile()
      end
    end)
  end)
end

function M.start()
  started = true
  M.reconcile()
  subscribe()
end

function M.stop()
  started = false
  M.watch(false)
  if sub and not sub:is_closing() then
    sub:close()
  end
  sub = nil
end

-- 3 s safety-net reconcile while a cockpit view is visible (not every transition emits an event)
function M.watch(on)
  if on then
    reconcile_timer = reconcile_timer or assert(uv.new_timer())
    reconcile_timer:start(0, 3000, vim.schedule_wrap(M.reconcile))
  elseif reconcile_timer then
    reconcile_timer:stop()
  end
end

function M.agents()
  return cache
end

-- true when the last reconcile reached herdr, i.e. an agent missing from agents() is really gone
function M.reconciled()
  return reconciled
end

function M.watching()
  return reconcile_timer ~= nil and reconcile_timer:is_active()
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

-- Claim <project dir>/names/<name> with O_EXCL: two spawns racing for the same free name (two `claude`
-- launches at once) can't both get it. A claim older than 5 min is stale (its spawn finished or died;
-- a started agent is in the registry by then) and is taken over.
local CLAIM_TTL = 300
local function claim(project, name)
  local dir = require("cockpit.projects").root(project) .. "/names"
  pcall(vim.fn.mkdir, dir, "p") -- racy with a concurrent launch
  local path = dir .. "/" .. name
  for _ = 1, 2 do
    local fd = uv.fs_open(path, "wx", 420)
    if fd then
      uv.fs_close(fd)
      return true
    end
    local st = uv.fs_stat(path)
    if not st or os.time() - st.mtime.sec <= CLAIM_TTL then
      return false
    end
    uv.fs_unlink(path) -- stale: retry the exclusive create once
  end
  return false
end

-- A name is free if no live agent, no registry record (names are never reused within a project),
-- no fork/<name>-* branch in the primary repo and no other spawn's claim has it.
local function free_name(project)
  local _, res = M.request("agent.list", {})
  local taken = vim.deepcopy(require("cockpit.registry").names(project))
  for _, a in ipairs((res or {}).agents or {}) do
    if a.name then
      taken[a.name] = true
    end
  end
  local p = require("cockpit.projects").get(project)
  local repo = p and p.repos[1]
  local n = 1
  while true do
    local cand = project .. "-" .. n
    if not taken[cand] then
      local out = repo and vim.system({ "git", "-C", repo, "branch", "--list", "fork/" .. cand .. "-*" }, { text = true }):wait().stdout or ""
      if vim.trim(out) == "" and claim(project, cand) then
        return cand
      end
    end
    n = n + 1
  end
end

M.free_name = free_name

-- The pane to start an agent in: create the project's ck/ workspace and use its fresh root pane,
-- or split a new pane into the existing one. Never reuses a pane cockpit didn't just create.
-- Returns err, pane_id.
local function project_pane(p, env, cwd)
  cwd = cwd or p.repos[1]
  local _, wl = M.request("workspace.list", {})
  local ws
  for _, w in ipairs((wl or {}).workspaces or {}) do
    if w.label == PREFIX .. p.name then
      ws = w
      break
    end
  end
  if not ws then
    local err, res = M.request("workspace.create", { cwd = cwd, label = PREFIX .. p.name, focus = false, env = env })
    return err, res and res.root_pane.pane_id
  end
  local _, pl = M.request("pane.list", { workspace_id = ws.workspace_id })
  local panes = (pl or {}).panes or {}
  local err, res = M.request("pane.split", {
    target_pane_id = panes[1] and panes[1].pane_id,
    workspace_id = ws.workspace_id,
    direction = "right",
    cwd = cwd,
    focus = false,
    env = env,
  })
  return err, res and res.pane.pane_id
end

-- Start a Claude agent in a fresh pane cockpit just created; cb(err, name). `rec` carries the
-- registry fields beyond {name, terminal_id, session} and must include `project` (agent.start takes
-- no env: env is set when the pane is created). A blocked start (folder trust) keeps the agent,
-- records it, and offers to attach so you can answer the dialog yourself (unless
-- opts.interactive == false, e.g. the `claude` launcher, which attaches anyway).
function M.start_in(pane_id, name, args, rec, cb, opts)
  cb = cb or function() end
  local interactive = not (opts and opts.interactive == false)
  -- a fresh pane needs a moment to reach its shell prompt before agent.start accepts it
  vim.defer_fn(function()
    local function started(serr)
      -- Record the agent once it exists: on ready, and also when blocked at startup (the agent is kept)
      if not serr or serr.code == "agent_not_ready" or serr.code == "timeout" then
        local _, got = M.request("agent.get", { target = name })
        local a = got and got.agent
        if a and a.terminal_id then
          if serr and serr.code == "timeout" then
            -- a lost reply, not a failed start: the agent exists, so judge it by its status
            serr = a.agent_status == "blocked" and { code = "agent_not_ready", message = name .. " is blocked during startup" } or nil
          end
          require("cockpit.registry").append(rec.project, vim.tbl_extend("force", rec, {
            name = name,
            terminal_id = a.terminal_id,
            session = a.agent_session and a.agent_session.value or nil,
          }))
        end
      end
      M.reconcile()
      if serr and serr.code == "agent_not_ready" and interactive then
        vim.ui.select({ "Attach now", "Later" }, { prompt = name .. " is blocked at startup (likely folder trust)" }, function(choice)
          if choice == "Attach now" then
            M.attach(name)
          end
        end)
      elseif serr and serr.code == "agent_not_ready" then
        vim.notify("cockpit: " .. name .. " is blocked at startup", vim.log.levels.WARN)
      elseif serr then
        vim.notify("cockpit: " .. name .. " failed to start — " .. serr.message, vim.log.levels.ERROR)
      elseif interactive then
        vim.notify("cockpit: " .. name .. " ready")
      end
      cb(serr, name)
    end
    -- Over the socket, agent.start returns at launch; readiness (the CLI's wait) is ours to do.
    -- Not for the launcher (interactive == false): you attach right away and see whatever Claude shows
    -- (trust dialog, resume picker, login), so waiting would only delay the attach.
    M.request("agent.start", { name = name, kind = "claude", pane_id = pane_id, args = args, timeout_ms = 60000 }, function(serr)
      if serr or not interactive then
        return started(serr)
      end
      local wait = { target = name, ["until"] = { "idle", "blocked" }, timeout_ms = 60000 }
      M.request("agent.wait", wait, function(werr, res)
        local status = res and res.agent and res.agent.agent_status
        if not werr and status == "blocked" then
          werr = { code = "agent_not_ready", message = name .. " is blocked during startup" }
        end
        started(werr)
      end, { timeout_ms = 75000 })
    end)
  end, 1500)
end

-- Start a Claude agent in `project`; cb(err, name, pane_id). opts.args: extra claude args (appended);
-- opts.interactive = false: no attach prompt when blocked at startup (cb still gets the name).
-- opts.cwd: the pane's cwd (default: the primary repo). opts.env: base pane env (COCKPIT_* win).
-- opts.on_pane(pane_id): called as soon as the pane exists (the launcher closes it if it gives up).
function M.spawn(project, prompt, cb, opts)
  opts = opts or {}
  cb = cb or function() end
  if not M.ensure() then
    return cb({ code = "no_server", message = "herdr server not running" })
  end
  local p = require("cockpit.projects").get(project)
  if not p then
    return cb({ code = "no_project", message = "no project " .. project })
  end
  local env = vim.tbl_extend("force", opts.env or {}, { COCKPIT_PROJECT = project, COCKPIT_INBOX_DIR = vim.env.COCKPIT_INBOX_DIR })
  local err, pane_id = project_pane(p, env, opts.cwd)
  if err then
    vim.notify("cockpit: spawn failed — " .. err.message, vim.log.levels.ERROR)
    return cb(err)
  end
  if opts.on_pane then
    opts.on_pane(pane_id)
  end
  local args = {}
  for i = 2, #p.repos do
    vim.list_extend(args, { "--add-dir", p.repos[i] })
  end
  vim.list_extend(args, opts.args or {})
  M.start_in(pane_id, free_name(project), args, { project = project }, function(serr, name)
    if not serr and prompt and prompt ~= "" then
      M.request("agent.prompt", { target = name, text = prompt }, function() end)
    end
    cb(serr, name, pane_id)
  end, { interactive = opts.interactive })
end

-- Hard kill: close the agent's own pane. Callers confirm first. Returns err or nil.
function M.kill(target)
  local a = cache[target]
  local pane_id = a and a.pane_id or target
  local err = M.request("pane.close", { pane_id = pane_id })
  M.reconcile()
  return err
end

function M.interrupt(target)
  return (M.request("agent.send_keys", { target = target, keys = { "esc" } }))
end

function M.attach(target)
  local argv = M.cli("agent", "attach", target)
  if vim.env.TMUX then
    vim.system({ "tmux", "new-window", "-n", target, table.concat(vim.tbl_map(vim.fn.shellescape, argv), " ") })
  else
    vim.cmd("tabnew")
    vim.fn.jobstart(argv, { term = true })
    vim.cmd("startinsert")
  end
end

-- Submit text as a prompt; returns a one-line status for the user.
function M.prompt(target, text)
  local err = M.request("agent.prompt", { target = target, text = text })
  if not err then
    return "delivered to " .. target
  elseif err.code == "agent_blocked" then
    return target .. " is at a dialog — attach to answer"
  end
  return target .. ": " .. (err.message or err.code)
end

function M.by_terminal(terminal_id)
  for _, a in pairs(cache) do
    if terminal_id and a.terminal_id == terminal_id then
      return a
    end
  end
end

return M
