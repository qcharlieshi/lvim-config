-- cockpit ↔ herdr: the only place nvim talks to the agent runtime (rented and disposable, see
-- docs/superpowers/specs/2026-11-10-cockpit-herdr-runtime-design.md). Speaks herdr's NDJSON
-- socket API directly. Every call names its target explicitly — never --current (herdr #2900).
local M = {}

local uv = vim.uv
local seq = 0
local cache = {} -- key (agent name, else pane id) -> Agent
local labels = {} -- workspace_id -> label
local sub -- live events.subscribe pipe
local started = false
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
function M.request(method, params, cb)
  seq = seq + 1
  local id = "ck" .. seq
  local done, out_err, out_res = false, nil, nil
  local function finish(err, res)
    if done then
      return
    end
    done, out_err, out_res = true, err, res
    if cb then
      vim.schedule(function()
        cb(err, res)
      end)
    end
  end
  local pipe = assert(uv.new_pipe(false))
  pipe:connect(M.socket(), function(cerr)
    if cerr then
      pipe:close()
      return finish({ code = "connect", message = cerr })
    end
    local buf = ""
    pipe:read_start(function(rerr, chunk)
      if rerr or not chunk then
        pipe:close()
        return finish({ code = "closed", message = rerr or "connection closed" })
      end
      buf = buf .. chunk
      for line in buf:gmatch("([^\n]*)\n") do
        local msg = decode(line)
        if msg and msg.id == id then
          pipe:read_stop()
          pipe:close()
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

local function project_for(workspace_id)
  local label = labels[workspace_id]
  local ok, projects = pcall(require, "cockpit.projects")
  return (ok and label and projects.get(label)) and label or nil
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
  M.request("workspace.list", {}, function(_, ws)
    labels = {}
    for _, w in ipairs((ws or {}).workspaces or {}) do
      labels[w.workspace_id] = w.label
    end
    M.request("agent.list", {}, function(err, res)
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

function M.by_terminal(terminal_id)
  for _, a in pairs(cache) do
    if terminal_id and a.terminal_id == terminal_id then
      return a
    end
  end
end

return M
