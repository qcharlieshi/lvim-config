-- Reply delivery + outbox (review 0.4). herdr and tmux are faked: nothing leaves this process.
local h = require("tests.helpers")
local eq = MiniTest.expect.equality
local live, calls, claude_sessions

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      h.fresh()
      live, calls, claude_sessions = {}, {}, {}
      -- live hand-started Claude sessions, shaped like sessions.list()
      package.loaded["cockpit.sessions"] = {
        list = function()
          return claude_sessions
        end,
      }
      package.loaded["cockpit.herdr"] = {
        start = function() end,
        agents = function()
          return live
        end,
        by_terminal = function(tid)
          return live[tid]
        end,
        prompt = function(target, text)
          calls[#calls + 1] = { target = target, text = text }
          if live.fail then
            return target .. ": agent_blocked", false
          end
          return "delivered to " .. target, true
        end,
      }
    end,
  },
})

local function post(tid, session)
  local store = require("cockpit.inbox.store")
  store.append(store.thread_file(tid), {
    kind = "message",
    from = "agent",
    title = tid,
    text = "x",
    session = session or { agent = "claude", herdr = { terminal_id = "term-a" } },
  })
end

local function reply(tid, extra)
  local store = require("cockpit.inbox.store")
  return store.append(
    store.thread_file(tid),
    vim.tbl_extend("force", { kind = "reply", from = "human", text = "ok" }, extra or {})
  )
end

local function thread(tid)
  return require("cockpit.inbox.store").thread(tid)
end

local function ids(list)
  return vim.tbl_map(function(r)
    return r.id
  end, list)
end

T["a reply sent while its agent is offline is redelivered when the agent comes back"] = function()
  require("cockpit.inbox").setup()
  local store = require("cockpit.inbox.store")
  post("t1")
  local r = reply("t1")
  MiniTest.expect.no_equality(store.deliver(thread("t1")):find("offline", 1, true), nil)
  eq(#calls, 0)
  live["term-a"] = { target = "agent-1", terminal_id = "term-a", status = "idle" }
  vim.api.nvim_exec_autocmds("User", { pattern = "CockpitAgents" })
  eq(#calls, 1)
  eq(calls[1].target, "agent-1")
  eq(calls[1].text:match("^Inbox reply on thread (t1)%. Run: .* read t1 %-%-new$"), "t1")
  eq(ids(thread("t1").unacked), { r.id })
  eq(thread("t1").undelivered, {})
  -- idempotent: the agent has the prompt, a later agent event doesn't repeat it
  vim.api.nvim_exec_autocmds("User", { pattern = "CockpitAgents" })
  eq(#calls, 1)
end

T["send delivers once and records it"] = function()
  local delivery = require("cockpit.inbox.delivery")
  live["term-a"] = { target = "agent-1", terminal_id = "term-a" }
  post("t1")
  local r = reply("t1")
  eq(delivery.deliver(thread("t1")), "delivered to agent-1")
  delivery.flush()
  eq(#calls, 1)
  local d = vim.tbl_filter(function(e)
    return e.kind == "delivery"
  end, require("cockpit.inbox.store").read_jsonl(require("cockpit.inbox.store").thread_file("t1")))
  eq(#d, 1)
  eq({ d[1].replies, d[1].ok, d[1].via }, { { r.id }, true, "herdr" })
end

T["one prompt covers every pending reply of a thread"] = function()
  local delivery = require("cockpit.inbox.delivery")
  post("t1")
  reply("t1")
  reply("t1")
  delivery.deliver(thread("t1")) -- offline: queued
  live["term-a"] = { target = "agent-1", terminal_id = "term-a" }
  delivery.flush()
  eq(#calls, 1)
  eq(#thread("t1").undelivered, 0)
end

T["acked replies are neither unacked nor undelivered"] = function()
  local store = require("cockpit.inbox.store")
  post("t1")
  local r = reply("t1")
  store.append(store.thread_file("t1"), { kind = "ack", reply = r.id })
  eq(thread("t1").unacked, {})
  eq(thread("t1").undelivered, {})
  require("cockpit.inbox.delivery").flush()
  eq(#calls, 0)
end

T["a failed prompt backs off exponentially, then gives up"] = function()
  local delivery = require("cockpit.inbox.delivery")
  local now = os.time()
  delivery.now = function()
    return now
  end
  live["term-a"] = { target = "agent-1", terminal_id = "term-a" }
  live.fail = true
  post("t1")
  reply("t1")
  delivery.deliver(thread("t1"))
  eq(#calls, 1)
  delivery.flush()
  eq(#calls, 1) -- inside the backoff window
  local tries = 1
  for _ = 1, 20 do
    now = now + delivery.BACKOFF_MAX
    delivery.flush()
    tries = #calls
  end
  eq(tries, delivery.MAX_TRIES)
  eq(#thread("t1").undelivered, 1)
end

T["replies from before the outbox are left alone"] = function()
  local delivery = require("cockpit.inbox.delivery")
  live["term-a"] = { target = "agent-1", terminal_id = "term-a" }
  post("t1")
  reply("t1", { ts = os.time() - delivery.FRESH - 60 })
  delivery.flush()
  eq(#calls, 0)
  eq(#thread("t1").undelivered, 1)
end

T["a reply never attempted (nvim died before delivering) is picked up"] = function()
  live["term-a"] = { target = "agent-1", terminal_id = "term-a" }
  post("t1")
  reply("t1")
  require("cockpit.inbox.delivery").flush()
  eq(#calls, 1)
end

T["two nvims never deliver the same attempt"] = function()
  local delivery = require("cockpit.inbox.delivery")
  post("t1")
  local r = reply("t1")
  delivery.deliver(thread("t1")) -- offline: queued
  live["term-a"] = { target = "agent-1", terminal_id = "term-a" }
  -- the other nvim claimed attempt 2 (attempt 1 was the queued record above)
  h.write(require("cockpit.inbox.store").path("outbox", r.id .. ".2"), "")
  delivery.flush()
  eq(#calls, 0)
end

T["an agent blocked in wait reads it itself"] = function()
  local store = require("cockpit.inbox.store")
  local delivery = require("cockpit.inbox.delivery")
  live["term-a"] = { target = "agent-1", terminal_id = "term-a" }
  post("t1")
  reply("t1")
  h.write(store.path("waiting", "t1"), "")
  eq(delivery.deliver(thread("t1")), "agent was waiting and has it")
  eq(#calls, 0)
  eq(thread("t1").undelivered, {})
end

local function tmux_spy(delivery)
  local sent = {}
  delivery.transports.tmux = function(pane, msg)
    sent[#sent + 1] = { pane, msg }
    return "delivered to pane " .. pane, true
  end
  return sent
end

T["tmux threads: no Claude in the pane queues, the session coming back gets send-keys"] = function()
  local delivery = require("cockpit.inbox.delivery")
  local sent = tmux_spy(delivery)
  post("t1", { agent = "claude", tmux_pane = "%7" })
  reply("t1")
  MiniTest.expect.no_equality(delivery.deliver(thread("t1")):find("queued", 1, true), nil)
  eq(#sent, 0)
  claude_sessions[1] = { pid = 1, session_id = "sid-1", pane = "%7" }
  delivery.flush()
  eq(#sent, 1)
  eq(sent[1][1], "%7")
end

T["a queued reply is never typed into a reused pane id without a Claude session"] = function()
  -- tmux pane ids restart at %0 with the server: after a restart %7 can be a plain shell or an nvim
  local delivery = require("cockpit.inbox.delivery")
  local sent = tmux_spy(delivery)
  post("t1", { agent = "claude", tmux_pane = "%7" })
  reply("t1")
  delivery.deliver(thread("t1"))
  delivery.flush()
  eq(#sent, 0)
end

T["a queued reply is never typed into a pane now running another Claude session"] = function()
  local delivery = require("cockpit.inbox.delivery")
  local sent = tmux_spy(delivery)
  post("t1", { agent = "claude", tmux_pane = "%7", session_id = "sid-A" })
  reply("t1")
  claude_sessions[1] = { pid = 2, session_id = "sid-B", pane = "%7" }
  delivery.deliver(thread("t1"))
  delivery.flush()
  eq(#sent, 0)
  claude_sessions[1] = { pid = 3, session_id = "sid-A", pane = "%7" }
  delivery.flush()
  eq(#sent, 1)
end

T["a queued reply expires after FRESH"] = function()
  local delivery = require("cockpit.inbox.delivery")
  local now = os.time()
  delivery.now = function()
    return now
  end
  post("t1")
  reply("t1")
  delivery.deliver(thread("t1")) -- offline: queued
  now = now + delivery.FRESH + 1
  live["term-a"] = { target = "agent-1", terminal_id = "term-a" }
  delivery.flush()
  eq(#calls, 0)
end

T["herdr threads never fall back to tmux"] = function()
  local delivery = require("cockpit.inbox.delivery")
  local sent = 0
  claude_sessions[1] = { pid = 1, session_id = "sid-1", pane = "%1" }
  delivery.transports.tmux = function()
    sent = sent + 1
    return "x", true
  end
  post("t1", { agent = "claude", herdr = { terminal_id = "gone" }, tmux_pane = "%1" })
  reply("t1")
  MiniTest.expect.no_equality(delivery.deliver(thread("t1")):find("offline", 1, true), nil)
  eq(sent, 0)
end

T["deliver on a thread that doesn't exist says so (smoke 7 passes a bare thread table)"] = function()
  eq(require("cockpit.inbox.delivery").deliver({ id = "x", session = { tmux_pane = "%1" } }), "no thread x")
end

T["the owner join is injectable (e.g. by Claude session id)"] = function()
  local delivery = require("cockpit.inbox.delivery")
  delivery.resolve = function(t)
    if t.owner and t.owner.session_id == "sid-1" then
      return { via = "herdr", target = "renamed-agent" }
    end
    return nil, "no agent"
  end
  post("t1", { agent = "claude", session_id = "sid-1" })
  reply("t1")
  eq(delivery.deliver(thread("t1")), "delivered to renamed-agent")
  eq(calls[1].target, "renamed-agent")
end

T["unacked replies match the golden fixtures"] = function()
  local expected = h.load_fixtures()
  for name, want in pairs(expected) do
    eq({ name, ids(thread(name).unacked) }, { name, want.pending_replies })
    if want.undelivered then
      eq({ name, ids(thread(name).undelivered) }, { name, want.undelivered })
    end
  end
end

return T
