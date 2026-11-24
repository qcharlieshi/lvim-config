local h = require("tests.helpers")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set({ hooks = { pre_case = h.fresh } })

local function ids(list, key)
  return vim.tbl_map(function(x)
    return x[key or "id"]
  end, list)
end

T["thread() matches the golden fixtures"] = function()
  local expected = h.load_fixtures()
  local store = require("cockpit.inbox.store")
  for name, want in pairs(expected) do
    local t = store.thread(name)
    local got = {
      status = t.status,
      stage = t.stage,
      round = t.round,
      archived = t.archived,
      drafts = ids(t.drafts),
      open_questions = ids(t.open_questions, "key"),
    }
    local exp = {
      status = want.status,
      stage = want.stage,
      round = want.round,
      archived = want.archived,
      drafts = want.drafts,
      open_questions = want.open_questions,
    }
    eq({ name, got }, { name, exp })
  end
end

T["thread() of a missing id is nil"] = function()
  eq(require("cockpit.inbox.store").thread("nope"), nil)
end

T["pipeline derives stages, rounds and done"] = function()
  h.load_fixtures()
  local store = require("cockpit.inbox.store")
  local t = store.thread("pipeline")
  eq(t.stages, { "plan", "build" })
  eq(vim.tbl_map(function(m)
    return m.round
  end, vim.tbl_filter(function(m)
    return m.kind == "message"
  end, t.messages)), { 1, 2, 1 })
  eq(t.done, false)
  eq(store.strip(t), { { stage = "plan", state = "done" }, { stage = "build", state = "needs_you" } })
  eq(#t.deliverables, 1)
end

T["append() round-trips through thread()"] = function()
  local store = require("cockpit.inbox.store")
  local file = store.thread_file("t1")
  store.append(file, { kind = "message", from = "agent", title = "T", text = "hi" })
  local ev = store.append(file, { kind = "reply", from = "human", verdict = "approve", text = "ok" })
  local t = store.thread("t1")
  eq(t.title, "T")
  eq(t.status, "replied")
  eq(t.messages[2].id, ev.id)
end

return T
