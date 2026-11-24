-- cockpit reply delivery: gets each sent reply to its agent (herdr agent.prompt, else its tmux pane) and keeps
-- trying until it lands. store.lua only records events; this is the one module that talks to transports.
--
-- Outbox: a reply is pending until the agent acks it (`cockpit_inbox.py read --new` / `wait`). Each attempt is
-- logged in the thread as { kind = "delivery", replies, ok, via?, target?, detail }:
--   ok = true            the agent has it (prompt accepted, or it was blocked in `wait`): never sent again
--   ok = false, no via   no reachable agent at send time: queued until one turns up, for FRESH at most
--   ok = false, via      the transport failed (agent at a dialog, ...): retried with backoff, MAX_TRIES at most
-- flush() runs on agent changes (CockpitAgents), inbox changes and a slow timer (tmux panes emit nothing).
-- One prompt covers every pending reply of a thread, since `read --new` prints them all. Several nvims may
-- flush at once: an attempt is claimed with an O_EXCL file in outbox/ before it's made.
local store = require("cockpit.inbox.store")
local M = {}

M.BACKOFF, M.BACKOFF_MAX, M.MAX_TRIES = 30, 3600, 8
-- A reply never attempted (nvim died between append and deliver) or only queued (agent unreachable) is sent for
-- this long after it was written; after that it's left alone rather than replayed to an agent that has moved on
M.FRESH = 3600
M.now = os.time

-- One line: multi-line pastes would submit early. Claude queues it if mid-turn. cockpit_inbox.py's Stop hook
-- matches this exact shape to know the turn answers a thread.
function M.trigger(tid)
  return ("Inbox reply on thread %s. Run: python3 %s read %s --new"):format(tid, store.cli, tid)
end

-- The CLI touches waiting/<tid> every 2 s while an agent blocks in `wait`
function M.agent_waiting(tid)
  local stat = vim.uv.fs_stat(store.path("waiting", tid))
  return stat ~= nil and M.now() - stat.mtime.sec < 10
end

-- The live Claude session in a tmux pane. A pane id alone isn't enough: ids restart at %0 with the tmux server,
-- so a queued reply's pane may now be a shell or an editor. When the thread names its session, that must match.
local function claude_in(pane, sid)
  for _, s in ipairs(require("cockpit.sessions").list()) do
    if s.pane == pane and (not sid or s.session_id == sid) then
      return s
    end
  end
end

-- resolve(t) -> { via = <transport>, target } | nil, why: the thread's live agent. Swap it to join threads to
-- agents differently (e.g. on the Claude session id).
function M.default_resolve(t)
  local hid = t.session and t.session.herdr
  if hid then
    -- terminal_id, not pane_id: pane ids restart with the herdr server
    local agent = require("cockpit.herdr").by_terminal(hid.terminal_id)
    -- the pane may run a newer conversation now (/clear): never type a reply into the wrong one
    local sid = store.owner_session(t) or hid.session_id
    if agent and sid and agent.session_id and agent.session_id ~= sid then
      return nil, "that conversation ended (another one runs in its pane); reply queued until it's back"
    end
    if agent then
      return { via = "herdr", target = agent.target }
    end
    -- never fall through to tmux: a tmux_pane on a herdr thread is leaked env, i.e. someone else's pane
    return nil, "agent offline; reply queued until it's back"
  end
  local pane = t.session and t.session.tmux_pane
  if not pane then
    return nil, "no agent pane; it can run `read " .. t.id .. " --new`"
  end
  if not claude_in(pane, t.session.session_id) then
    return nil, "no Claude session in pane " .. pane .. " any more; reply queued until it's back"
  end
  return { via = "tmux", target = pane }
end
M.resolve = M.default_resolve

-- transport(target, msg) -> status line, ok
M.transports = {
  herdr = function(target, msg)
    return require("cockpit.herdr").prompt(target, msg)
  end,
  tmux = function(pane, msg)
    local r = vim.system({ "tmux", "send-keys", "-t", pane, "-l", msg }):wait()
    if r.code == 0 then
      r = vim.system({ "tmux", "send-keys", "-t", pane, "Enter" }):wait()
    end
    if r.code ~= 0 then
      return "tmux send-keys to " .. pane .. " failed", false
    end
    return "delivered to pane " .. pane, true
  end,
}

-- Should flush() try this undelivered reply now?
function M.due(r, now)
  if r.delivered then
    return false
  elseif #r.attempts == 0 then
    return now - (r.ts or 0) < M.FRESH
  end
  local tried = vim.tbl_filter(function(d)
    return d.via ~= nil
  end, r.attempts)
  if #tried == 0 then
    return now - (r.ts or 0) < M.FRESH -- only queued so far: the agent wasn't reachable
  elseif #tried >= M.MAX_TRIES then
    return false
  end
  return now >= tried[#tried].ts + math.min(M.BACKOFF * 2 ^ (#tried - 1), M.BACKOFF_MAX)
end

local function claim(r)
  vim.fn.mkdir(store.path("outbox"), "p")
  local fd = vim.uv.fs_open(store.path("outbox", r.id .. "." .. (#r.attempts + 1)), "wx", 420)
  if fd then
    vim.uv.fs_close(fd)
  end
  return fd ~= nil
end

local function record(t, replies, ok, route, detail)
  store.append(store.thread_file(t.id), {
    kind = "delivery",
    replies = vim.tbl_map(function(r)
      return r.id
    end, replies),
    ok = ok,
    via = route and route.via,
    target = route and route.target,
    detail = detail,
  })
end

-- One delivery attempt for thread t. send: the human just replied (skip backoff, queue if unreachable).
-- Returns a status line, or nil when nothing was due.
local function attempt(t, send)
  local now = M.now()
  local due = vim.tbl_filter(function(r)
    return store.valid_id(r.id) and (send or M.due(r, now))
  end, t.undelivered)
  if #due == 0 then
    return nil
  end
  local waiting = M.agent_waiting(t.id)
  local route, why
  if waiting then
    route = { via = "wait" }
  else
    route, why = M.resolve(t)
  end
  if not route then
    if send then
      record(t, due, false, nil, why)
    end
    return why
  end
  if not claim(due[1]) then
    return "another nvim is delivering it"
  end
  if waiting then
    record(t, due, true, route, "agent was waiting")
    return "agent was waiting and has it"
  end
  local transport = M.transports[route.via]
  local called, detail, ok = pcall(transport, route.target, M.trigger(t.id))
  if not called then
    detail, ok = tostring(detail), false
  end
  record(t, due, ok == true, route, detail)
  return detail, ok == true
end

-- At send time; t may predate the reply, so the thread is read again
function M.deliver(t)
  local cur = store.thread(t.id)
  if not cur then
    return "no thread " .. tostring(t.id)
  end
  return attempt(cur, true) or "nothing to deliver"
end

-- Retry every due reply; threads: an already-derived store.threads() list to reuse
function M.flush(threads)
  for _, t in ipairs(threads or store.threads()) do
    if #(t.undelivered or {}) > 0 and not t.archived then
      local ok, detail, delivered = pcall(attempt, t, false)
      if not ok then
        vim.notify("cockpit: delivery failed on " .. t.id .. " — " .. tostring(detail), vim.log.levels.WARN)
      elseif delivered then
        vim.notify(("Cockpit: queued reply on %s · %s"):format(t.title or t.id, detail))
      end
    end
  end
end

return M
