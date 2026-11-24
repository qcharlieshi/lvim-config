-- tree.build on fixtures (was smoke section 10): no herdr, no sessions, no registry files
local h = require("tests.helpers")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set({ hooks = { pre_case = h.fresh } })

local function ag(name, tid, status, project)
  return { name = name, terminal_id = tid, status = status, project = project }
end

local function th(id, owner, status, archived)
  return {
    id = id,
    title = id,
    status = status,
    archived = archived,
    last_ts = 1,
    owner = owner and { herdr = { terminal_id = owner } } or nil,
  }
end

local function build(show)
  return require("cockpit.inbox.tree").build({
    show_archived = show,
    threads = { th("t1", "tA", "needs_you"), th("t2", "tF", "read"), th("t3", "tD", "read", true), th("t4", nil, "read") },
    agents = { A = ag("A", "tA", "idle", "p"), F = ag("F", "tF", "idle", "p"), G = ag("G", "tG", "idle", "p") },
    registry = {
      p = {
        tA = { name = "A", project = "p", terminal_id = "tA", ts = 1 },
        tF = { name = "F", project = "p", terminal_id = "tF", parent_terminal = "tA", parent_name = "A", fork = "continue", ts = 2 },
        tD = { name = "D", project = "p", terminal_id = "tD", ts = 0 },
        tG = { name = "G", project = "p", terminal_id = "tG", parent_terminal = "tD", parent_name = "D", fork = "continue", ts = 3 },
      },
      q = {},
    },
    projects = { { name = "p" }, { name = "q" } },
  })
end

local function keys(nodes)
  return vim.tbl_map(function(n)
    return n.kind == "thread" and n.thread.id or n.key
  end, nodes)
end

T["orders project > agent > forks > threads, orphans, past, unassigned"] = function()
  local nodes = build(false)
  eq(keys(nodes), { "header", "p:p", "a:tA", "a:tF", "t2", "t1", "a:tG", "past:p", "a:tD", "p:q", "unassigned", "t4" })
  local by = {}
  for _, n in ipairs(nodes) do
    by[n.key] = n
  end
  eq(by["p:p"].counts.needs_you, 1)
  eq({ by["a:tG"].orphan_of, by["a:tG"].depth }, { "D", 1 })
  eq({ by["a:tF"].fork, by["a:tF"].depth, by["a:tF"].live }, { "continue", 2, true })
  eq({ by["a:tD"].live, by["a:tD"].depth }, { false, 2 })
  eq(#by["p:q"].children, 0)
end

T["archived threads only with show_archived"] = function()
  eq(vim.tbl_contains(keys(build(false)), "t3"), false)
  eq(vim.tbl_contains(keys(build(true)), "t3"), true)
end

T["owner_tid: herdr terminal, else the posting pid"] = function()
  local tree = require("cockpit.inbox.tree")
  eq(tree.owner_tid({ owner = { herdr = { terminal_id = "x" } } }), "x")
  eq(tree.owner_tid({ session = { pid = 42 } }), "cc:42")
  eq(tree.owner_tid({}), nil)
end

return T
