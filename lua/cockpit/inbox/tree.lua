-- cockpit rail model: pure tree of projects > agents (forks nested) > threads. No buffers, no side effects.
--
-- tree.build(opts?) -> Node[]  (flat, depth-first, display order; every node also keeps its own `children`)
--   opts: show_archived?, threads?, agents?, sessions?, herdr_status?, registry?, projects?   (fixtures; absent => live sources)
--   opts.registry fixture shape: table<project, table<terminal_id, Rec>>  (live: registry.all(project) per project)
--
-- Node fields (all nodes): kind = "header"|"project"|"agent"|"thread"|"past"|"unassigned", key, depth (0-based)
--   header:     counts = {needs_you, working, blocked} totals over all projects + unassigned
--   project:    key "p:<name>", name, counts, children (agent nodes, top level), past? (past Node; also emitted
--               right after the children in the flat list; absent when the project has no dead agents)
--   agent:      key "a:<terminal_id>", name, terminal_id, agent (herdr cache entry, or registry rec if dead),
--               rec (registry rec or nil), live (bool), status ("blocked"|"working"|"idle"|... or "dead"),
--               fork ("continue"|"worktree"|nil), orphan_of (parent name when live fork's parent is dead/missing),
--               children (fork agent nodes first, then thread nodes)
--   thread:     key "t:<id>", thread (store thread t)
--   past:       key "past:<project>", project, children (dead agent nodes, flat, each with its threads)
--   unassigned: key "unassigned", children (agents with no project, then threads with no owner agent)
-- Fold keys are the node keys; hiding a folded node's subtree is the renderer's job (skip rows with depth > node.depth).
local M = {}

local RANK = { needs_you = 1, unread = 2, working = 3, replied = 4, read = 5, done = 6 }

local function owner_tid(t)
  local h = t.owner and t.owner.herdr and t.owner.herdr.terminal_id
  if h then return h end
  -- a hand-started Claude session (sessions.lua) owns the threads its pid posted
  local pid = t.session and t.session.pid
  return pid and ("cc:" .. pid) or nil
end

local SESSION_STATUS = { busy = "working", waiting = "blocked", idle = "idle" }

-- defined project whose repo contains cwd (longest repo path wins), else the cwd basename as a group
local function project_for_cwd(cwd, plist)
  local best, len = nil, -1
  for _, p in ipairs(plist) do
    for _, r in ipairs(p.repos or {}) do
      if (cwd == r or cwd:sub(1, #r + 1) == r .. "/") and #r > len then best, len = p.name, #r end
    end
  end
  return best or (cwd and vim.fs.basename(cwd)) or nil
end

-- urgency tier: lower sorts first
local function tier(c)
  if c.blocked > 0 then return 1 end
  if c.needs_you > 0 then return 2 end
  if c.working > 0 then return 3 end
  return 4
end

local function sort_threads(list)
  table.sort(list, function(a, b)
    local ra, rb = RANK[a.status] or 9, RANK[b.status] or 9
    if ra ~= rb then return ra < rb end
    return (a.last_ts or 0) > (b.last_ts or 0)
  end)
end

local function sum(into, c)
  for k, v in pairs(c) do into[k] = (into[k] or 0) + v end
end

local function build_agent(info, ctx, forks_of)
  local node = {
    kind = "agent", key = "a:" .. info.tid, name = info.name, terminal_id = info.tid,
    agent = info.agent or info.rec, rec = info.rec, live = info.live,
    fork = info.rec and info.rec.fork, children = {},
    status = info.live and info.agent.status or "dead",
  }
  -- own = this agent only (live only); sub = including forks; recent = newest activity
  local own = { needs_you = 0, working = 0, blocked = 0 }
  local threads = ctx.by_owner[info.tid] or {}
  local recent = info.rec and info.rec.ts or 0
  if info.live then
    if node.status == "working" then own.working = 1 end
    if node.status == "blocked" then own.blocked = 1 end
    for _, t in ipairs(threads) do
      if t.status == "needs_you" then own.needs_you = own.needs_you + 1 end
    end
  end
  for _, t in ipairs(threads) do recent = math.max(recent, t.last_ts or 0) end
  local sub = vim.deepcopy(own)
  local kids = {}
  for _, f in ipairs(forks_of[info.tid] or {}) do
    local fn = build_agent(f, ctx, forks_of)
    sum(sub, fn.sub)
    recent = math.max(recent, fn.recent)
    kids[#kids + 1] = fn
  end
  node.own, node.sub, node.recent = own, sub, recent
  table.sort(kids, function(a, b)
    local ta, tb = tier(a.sub), tier(b.sub)
    if ta ~= tb then return ta < tb end
    if a.recent ~= b.recent then return a.recent > b.recent end
    return a.name < b.name
  end)
  vim.list_extend(node.children, kids)
  sort_threads(threads)
  for _, t in ipairs(threads) do
    node.children[#node.children + 1] = { kind = "thread", key = "t:" .. t.id, thread = t }
  end
  return node
end

local function sort_agents(list)
  table.sort(list, function(a, b)
    local ta, tb = tier(a.sub), tier(b.sub)
    if ta ~= tb then return ta < tb end
    if a.recent ~= b.recent then return a.recent > b.recent end
    return a.name < b.name
  end)
end

-- infos: all agents (live or dead) of one scope; returns top-level agent nodes.
-- Live forks nest under a live parent in the same scope; orphaned live forks stay top-level.
local function nest(infos, ctx, flat_dead)
  local present = {}
  for _, i in ipairs(infos) do present[i.tid] = i end
  local forks_of, top = {}, {}
  for _, i in ipairs(infos) do
    local pt = i.rec and i.rec.parent_terminal
    local parent = pt and present[pt]
    if not flat_dead and i.live and parent and parent.live then
      forks_of[pt] = forks_of[pt] or {}
      table.insert(forks_of[pt], i)
    else
      top[#top + 1] = i
    end
  end
  local nodes = {}
  for _, i in ipairs(top) do
    local n = build_agent(i, ctx, forks_of)
    if i.live and i.rec and i.rec.parent_terminal then n.orphan_of = i.rec.parent_name end
    nodes[#nodes + 1] = n
  end
  sort_agents(nodes)
  return nodes
end

local function flatten(node, depth, out)
  node.depth = depth
  out[#out + 1] = node
  for _, c in ipairs(node.children or {}) do flatten(c, depth + 1, out) end
  if node.past then flatten(node.past, depth + 1, out) end
end

function M.build(opts)
  opts = opts or {}
  local threads = opts.threads or require("cockpit.inbox.store").threads()
  local cache = opts.agents or require("cockpit.herdr").agents()
  local plist = opts.projects or require("cockpit.projects").list()

  local live = {} -- tid -> cache entry
  for _, a in pairs(cache) do
    if a.terminal_id then live[a.terminal_id] = a end
  end
  -- herdr agents: model / context / last words from the statusline file tagged with their pane
  local fixture = opts.agents ~= nil -- fixture runs never read live session files
  local by_pane = opts.herdr_status or (fixture and {} or require("cockpit.sessions").by_herdr_pane())
  for tid, a in pairs(live) do
    if by_pane[a.pane_id] then live[tid] = vim.tbl_extend("force", a, { session = by_pane[a.pane_id] }) end
  end
  -- hand-started Claude sessions in tmux panes: agents keyed "cc:<pid>", shaped like a herdr entry
  for _, s in ipairs(opts.sessions or (fixture and {} or require("cockpit.sessions").list())) do
    live["cc:" .. s.pid] = {
      name = s.name, target = s.pane, kind = "claude", source = "session", session = s,
      project = project_for_cwd(s.cwd, plist), status = SESSION_STATUS[s.status] or s.status or "unknown",
      pane_id = s.pane, terminal_id = "cc:" .. s.pid, cwd = s.cwd,
    }
  end

  -- project names: defined projects plus any referenced by live agents
  local names, seen = {}, {}
  local function add(n)
    if n and not seen[n] then seen[n] = true; names[#names + 1] = n end
  end
  for _, p in ipairs(plist) do add(p.name) end
  for _, a in pairs(live) do add(a.project) end

  local regs = {} -- tid -> Rec (with .project)
  for _, n in ipairs(names) do
    local all = opts.registry and (opts.registry[n] or {}) or require("cockpit.registry").all(n)
    for tid, rec in pairs(all) do
      rec.project = rec.project or n
      regs[tid] = rec
    end
  end

  -- agent infos by scope
  local by_proj, unassigned, known = {}, {}, {}
  local function info(tid, a, rec)
    return { tid = tid, agent = a, rec = rec, live = a ~= nil, name = (rec and rec.name) or a.name or tid }
  end
  for tid, a in pairs(live) do
    local rec = regs[tid]
    local p = a.project or (rec and rec.project)
    known[tid] = true
    local i = info(tid, a, rec)
    if p then
      by_proj[p] = by_proj[p] or {}
      table.insert(by_proj[p], i)
    else
      unassigned[#unassigned + 1] = i
    end
  end
  local dead = {} -- project -> infos
  for tid, rec in pairs(regs) do
    if not live[tid] then
      known[tid] = true
      dead[rec.project] = dead[rec.project] or {}
      table.insert(dead[rec.project], info(tid, nil, rec))
    end
  end

  -- thread ownership
  local by_owner, orphans = {}, {}
  for _, t in ipairs(threads) do
    if not t.archived or opts.show_archived then
      local tid = owner_tid(t)
      if tid and known[tid] then
        by_owner[tid] = by_owner[tid] or {}
        table.insert(by_owner[tid], t)
      else
        orphans[#orphans + 1] = t
      end
    end
  end
  local ctx = { by_owner = by_owner }

  local totals = { needs_you = 0, working = 0, blocked = 0 }
  local projects = {}
  for _, n in ipairs(names) do
    local children = nest(by_proj[n] or {}, ctx)
    local counts = { needs_you = 0, working = 0, blocked = 0 }
    for _, c in ipairs(children) do sum(counts, c.sub) end
    sum(totals, counts)
    local p = { kind = "project", key = "p:" .. n, name = n, counts = counts, children = children, urgency = tier(counts) }
    if dead[n] then
      local pn = { kind = "past", key = "past:" .. n, project = n, children = nest(dead[n], ctx, true) }
      table.sort(pn.children, function(a, b) return a.recent > b.recent end)
      p.past = pn
    end
    projects[#projects + 1] = p
  end
  table.sort(projects, function(a, b)
    if a.urgency ~= b.urgency then return a.urgency < b.urgency end
    return a.name < b.name
  end)

  local out = { { kind = "header", key = "header", counts = totals, depth = 0 } }
  for _, p in ipairs(projects) do flatten(p, 0, out) end

  local un_children = nest(unassigned, ctx)
  for _, c in ipairs(un_children) do sum(totals, c.sub) end
  for _, t in ipairs(orphans) do
    if t.status == "needs_you" then totals.needs_you = totals.needs_you + 1 end
  end
  sort_threads(orphans)
  for _, t in ipairs(orphans) do
    un_children[#un_children + 1] = { kind = "thread", key = "t:" .. t.id, thread = t }
  end
  if #un_children > 0 then
    flatten({ kind = "unassigned", key = "unassigned", children = un_children }, 0, out)
  end
  return out
end

return M
