-- tree.build on fixtures (was smoke section 10): no herdr, no sessions, no registry files
local h = require("tests.helpers")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set({ hooks = { pre_case = h.fresh } })

-- agents are Claude sessions: live entries carry session_id, records carry session (see tree.lua header)
local function ag(name, tid, sid, status, project)
  return { name = name, terminal_id = tid, session_id = sid, status = status, project = project }
end

local function th(id, owner, status, archived)
  return {
    id = id,
    title = id,
    status = status,
    archived = archived,
    last_ts = 1,
    owner = owner and { session_id = owner, herdr = { terminal_id = "t" .. owner:sub(2) } } or nil,
  }
end

local function build(show)
  return require("cockpit.inbox.tree").build({
    show_archived = show,
    threads = {
      th("t1", "SA", "needs_you"),
      th("t2", "SF", "read"),
      th("t3", "SD", "read", true),
      th("t4", nil, "read"),
    },
    agents = {
      A = ag("A", "tA", "SA", "idle", "p"),
      F = ag("F", "tF", "SF", "idle", "p"),
      G = ag("G", "tG", "SG", "idle", "p"),
    },
    registry = {
      p = {
        SA = { name = "A", project = "p", terminal_id = "tA", session = "SA", ts = 1 },
        SF = {
          name = "F",
          project = "p",
          terminal_id = "tF",
          session = "SF",
          parent_session = "SA",
          parent_name = "A",
          fork = "continue",
          ts = 2,
        },
        SD = { name = "D", project = "p", terminal_id = "tD", session = "SD", ts = 0 },
        SG = {
          name = "G",
          project = "p",
          terminal_id = "tG",
          session = "SG",
          parent_session = "SD",
          parent_name = "D",
          fork = "continue",
          ts = 3,
        },
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
  eq(keys(nodes), { "header", "p:p", "a:SA", "a:SF", "t2", "t1", "a:SG", "past:p", "a:SD", "p:q", "unassigned", "t4" })
  local by = {}
  for _, n in ipairs(nodes) do
    by[n.key] = n
  end
  eq(by["p:p"].counts.needs_you, 1)
  eq({ by["a:SG"].orphan_of, by["a:SG"].depth }, { "D", 1 })
  eq({ by["a:SF"].fork, by["a:SF"].depth, by["a:SF"].live }, { "continue", 2, true })
  eq({ by["a:SD"].live, by["a:SD"].depth }, { false, 2 })
  eq(#by["p:q"].children, 0)
end

T["archived threads only with show_archived"] = function()
  eq(vim.tbl_contains(keys(build(false)), "t3"), false)
  eq(vim.tbl_contains(keys(build(true)), "t3"), true)
end

T["owner_key: the Claude session that posted it (CLI or herdr), never the terminal alone"] = function()
  local tree = require("cockpit.inbox.tree")
  eq(tree.owner_key({ owner = { session_id = "s1" } }), "s1")
  eq(tree.owner_key({ owner = { herdr = { terminal_id = "x", session_id = "s2" } } }), "s2")
  eq(tree.owner_key({ owner = { herdr = { terminal_id = "x" } } }), nil)
  eq(tree.owner_key({}), nil)
end

T["a dead legacy agent (record without session) keeps its own unattributed threads: one Past row"] = function()
  local nodes = require("cockpit.inbox.tree").build({
    threads = { { id = "t9", title = "t9", status = "read", last_ts = 1, owner = { herdr = { terminal_id = "tD" } } } },
    agents = {},
    registry = { p = { tD = { name = "lilt-3", project = "p", terminal_id = "tD", ts = 0 } } },
    projects = { { name = "p" } },
  })
  eq(keys(nodes), { "header", "p:p", "past:p", "a:tD", "t9" })
end

T["an unattributed thread from a project-less live agent's pane is unassigned, not lost"] = function()
  local th9 = { id = "t9", title = "t9", status = "needs_you", last_ts = 1, owner = { herdr = { terminal_id = "tX" } } }
  local nodes = require("cockpit.inbox.tree").build({
    threads = { th9 },
    agents = { x = { name = "x", terminal_id = "tX", session_id = "SX", status = "idle" } },
    registry = {},
    projects = {},
  })
  eq(vim.tbl_contains(keys(nodes), "t9"), true)
  eq(nodes[1].counts.needs_you, 1)
end

return T
