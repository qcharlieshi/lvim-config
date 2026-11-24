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
  eq(
    vim.tbl_map(
      function(m)
        return m.round
      end,
      vim.tbl_filter(function(m)
        return m.kind == "message"
      end, t.messages)
    ),
    { 1, 2, 1 }
  )
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

T["thread ids that would leave threads/ are refused"] = function()
  local store = require("cockpit.inbox.store")
  h.write(vim.env.COCKPIT_INBOX_DIR .. "/evil.jsonl", '{"v":1,"kind":"message","id":"m1","ts":1}\n')
  for _, id in ipairs({ "../evil", "a/b", "x y", "", "a.b" }) do
    eq(store.valid_id(id), false)
    eq(store.thread(id), nil)
    MiniTest.expect.error(function()
      store.thread_file(id)
    end)
  end
  eq(store.valid_id("20260101-120000-fix-it_2"), true)
end

T["append() writes each event whole, even large ones"] = function()
  local store = require("cockpit.inbox.store")
  local file = store.thread_file("big")
  local big = string.rep("x", 300001)
  for i = 1, 3 do
    store.append(file, { kind = "message", text = big, n = i })
  end
  local f = assert(io.open(file, "rb"))
  local data = f:read("a")
  f:close()
  eq(data:sub(-1), "\n")
  local n = 0
  for line in data:gmatch("([^\n]*)\n") do
    n = n + 1
    eq(#vim.json.decode(line).text, #big)
  end
  eq(n, 3)
end

T["reply edit patches go to blobs, read back inline or by sha"] = function()
  local store = require("cockpit.inbox.store")
  local file = store.thread_file("t1")
  local patch = "--- a/plan.md\n+++ b/plan.md\n@@ -1 +1 @@\n-a\n+b\n"
  local reply = store.append(file, {
    kind = "reply",
    from = "human",
    edits = { { attachment = "plan.md", sha256 = string.rep("a", 64), patch = patch } },
  })
  local f = assert(io.open(file, "r"))
  local line = vim.json.decode(f:read("l"))
  f:close()
  eq(line.edits[1].patch, nil)
  eq(line.edits[1].patch_sha256, vim.fn.sha256(patch))
  eq(store.edit_patch(reply.edits[1]), patch)
  eq(store.edit_patch({ patch = "inline" }), "inline")
end

return T
