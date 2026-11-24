-- cockpit rail model: pure tree of projects > agents (forks nested) > threads. No buffers, no side effects.
-- An agent is a Claude session (its session id), not the herdr pane/terminal it runs in: a pane that ran several
-- conversations shows the live one, and the earlier ones under Past.
--
-- tree.build(opts?) -> Node[]  (flat, depth-first, display order; every node also keeps its own `children`)
--   opts: show_archived?, threads?, agents?, herdr_status?, registry?, projects?   (fixtures; absent => live sources)
--   opts.registry fixture shape: table<project, table<key, Rec>>  (live: registry.all(project) per project)
--
-- Node fields (all nodes): kind = "header"|"project"|"agent"|"thread"|"past"|"unassigned", key, depth (0-based)
--   header:     counts = {needs_you, working, blocked} totals over all projects + unassigned
--   project:    key "p:<name>", name, counts, children (agent nodes, top level), past? (past Node; also emitted
--               right after the children in the flat list; absent when the project has no dead agents)
--   agent:      key "a:<akey>" where akey = session id ("term:<terminal_id>" while herdr hasn't reported one;
--               "old:<terminal_id>" for the earlier, unattributed sessions of a seat), name, akey, session_id,
--               terminal_id, agent (herdr cache entry, or registry rec if dead), rec (registry rec or nil), live (bool),
--               status ("blocked"|"working"|"idle"|... or "dead"), fork ("continue"|"worktree"|nil), orphan_of
--               (parent name when a live fork's parent is dead/missing), children (forks first, then threads)
--   thread:     key "t:<id>", thread (store thread t)
--   past:       key "past:<project>", project, children (dead agent nodes, flat, each with its threads)
--   unassigned: key "unassigned", children (agents with no project, then threads with no owner agent)
-- Fold keys are the node keys; hiding a folded node's subtree is the renderer's job (skip rows with depth > node.depth).
local M = {}

local RANK = { needs_you = 1, unread = 2, working = 3, replied = 4, read = 5, done = 6 }

-- the Claude session that owns a thread, or nil (legacy thread nobody attributed)
function M.owner_key(t)
  return require("cockpit.inbox.store").owner_session(t)
end

-- urgency tier: lower sorts first
local function tier(c)
  if c.blocked > 0 then
    return 1
  end
  if c.needs_you > 0 then
    return 2
  end
  if c.working > 0 then
    return 3
  end
  return 4
end

local function sort_threads(list)
  table.sort(list, function(a, b)
    local ra, rb = RANK[a.status] or 9, RANK[b.status] or 9
    if ra ~= rb then
      return ra < rb
    end
    return (a.last_ts or 0) > (b.last_ts or 0)
  end)
end

local function sum(into, c)
  for k, v in pairs(c) do
    into[k] = (into[k] or 0) + v
  end
end

local function by_urgency(a, b)
  local ta, tb = tier(a.sub), tier(b.sub)
  if ta ~= tb then
    return ta < tb
  end
  if a.recent ~= b.recent then
    return a.recent > b.recent
  end
  return a.name < b.name
end

local function build_agent(info, ctx, forks_of)
  local node = {
    kind = "agent",
    key = "a:" .. info.key,
    akey = info.key,
    name = info.name,
    session_id = info.session_id,
    terminal_id = info.tid,
    agent = info.agent or info.rec,
    rec = info.rec,
    live = info.live,
    fork = info.rec and info.rec.fork,
    children = {},
    status = info.live and info.agent.status or "dead",
  }
  -- own = this agent only (live only); sub = including forks; recent = newest activity
  local own = { needs_you = 0, working = 0, blocked = 0 }
  local threads = ctx.by_owner[info.key] or {}
  local recent = info.rec and info.rec.ts or 0
  if info.live then
    if node.status == "working" then
      own.working = 1
    end
    if node.status == "blocked" then
      own.blocked = 1
    end
    for _, t in ipairs(threads) do
      if t.status == "needs_you" then
        own.needs_you = own.needs_you + 1
      end
    end
  end
  for _, t in ipairs(threads) do
    recent = math.max(recent, t.last_ts or 0)
  end
  local sub = vim.deepcopy(own)
  local kids = {}
  for _, f in ipairs(forks_of[info.key] or {}) do
    local fn = build_agent(f, ctx, forks_of)
    sum(sub, fn.sub)
    recent = math.max(recent, fn.recent)
    kids[#kids + 1] = fn
  end
  node.own, node.sub, node.recent = own, sub, recent
  table.sort(kids, by_urgency)
  vim.list_extend(node.children, kids)
  sort_threads(threads)
  for _, t in ipairs(threads) do
    node.children[#node.children + 1] = { kind = "thread", key = "t:" .. t.id, thread = t }
  end
  return node
end

-- infos: all agents (live or dead) of one scope; returns top-level agent nodes.
-- Live forks nest under a live parent in the same scope; orphaned live forks stay top-level.
local function nest(infos, ctx, flat_dead)
  local present = {}
  for _, i in ipairs(infos) do
    present[i.key] = i
  end
  local forks_of, top = {}, {}
  for _, i in ipairs(infos) do
    local pk = i.rec and (i.rec.parent_session or (i.rec.parent_terminal and ctx.key_of_seat[i.rec.parent_terminal]))
    local parent = pk and present[pk]
    if not flat_dead and i.live and parent and parent.live then
      forks_of[pk] = forks_of[pk] or {}
      table.insert(forks_of[pk], i)
    else
      top[#top + 1] = i
    end
  end
  local nodes = {}
  for _, i in ipairs(top) do
    local n = build_agent(i, ctx, forks_of)
    if i.live and i.rec and (i.rec.parent_session or i.rec.parent_terminal) then
      n.orphan_of = i.rec.parent_name
    end
    nodes[#nodes + 1] = n
  end
  table.sort(nodes, by_urgency)
  return nodes
end

local function flatten(node, depth, out)
  node.depth = depth
  out[#out + 1] = node
  for _, c in ipairs(node.children or {}) do
    flatten(c, depth + 1, out)
  end
  if node.past then
    flatten(node.past, depth + 1, out)
  end
end

function M.build(opts)
  opts = opts or {}
  local threads = opts.threads or require("cockpit.inbox.store").threads()
  local cache = opts.agents or require("cockpit.herdr").agents()
  local plist = opts.projects or require("cockpit.projects").list()
  local regkey = require("cockpit.registry").key

  local live = {} -- akey -> cache entry
  local fixture = opts.agents ~= nil -- fixture runs never read live session files
  -- herdr agents: model / context / last words from the statusline file tagged with their pane
  local by_pane = opts.herdr_status or (fixture and {} or require("cockpit.sessions").by_herdr_pane())
  for _, a in pairs(cache) do
    if a.terminal_id then
      if by_pane[a.pane_id] then
        a = vim.tbl_extend("force", a, { session = by_pane[a.pane_id] })
      end
      live[a.session_id or ("term:" .. a.terminal_id)] = a
    end
  end

  -- project names: defined projects plus any referenced by live agents
  local names, seen = {}, {}
  local function add(n)
    if n and not seen[n] then
      seen[n] = true
      names[#names + 1] = n
    end
  end
  for _, p in ipairs(plist) do
    add(p.name)
  end
  for _, a in pairs(live) do
    add(a.project)
  end

  local regs, seat = {}, {} -- key -> Rec (with .project); terminal_id -> latest Rec of that seat
  for _, n in ipairs(names) do
    local all = opts.registry and (opts.registry[n] or {}) or require("cockpit.registry").all(n)
    for _, rec in pairs(all) do
      rec.project = rec.project or n
      local k = regkey(rec)
      -- the same session can have records in two projects (m writes to the target's file): newest wins
      if not regs[k] or (rec.ts or 0) >= (regs[k].ts or 0) then
        regs[k] = rec
      end
      local cur = seat[rec.terminal_id]
      if not cur or (rec.ts or 0) >= (cur.ts or 0) then
        seat[rec.terminal_id] = rec
      end
    end
  end

  -- agent infos by scope
  local by_proj, unassigned, dead, known, consumed, key_of_seat = {}, {}, {}, {}, {}, {}
  for key, a in pairs(live) do
    local rec = regs[key]
    local s = seat[a.terminal_id]
    if not rec and s and not s.session then
      rec = s -- legacy seat record: the live session is that agent until reconcile learns its session
      consumed[regkey(s)] = true
    end
    local p = (rec and rec.moved and rec.project) or a.project or (rec and rec.project) or (s and s.project)
    known[key] = true
    key_of_seat[a.terminal_id] = key
    local i = {
      key = key,
      tid = a.terminal_id,
      session_id = a.session_id,
      agent = a,
      rec = rec,
      live = true,
      name = (rec and rec.name) or (s and s.name) or a.name or a.terminal_id,
    }
    if p then
      by_proj[p] = by_proj[p] or {}
      table.insert(by_proj[p], i)
    else
      unassigned[#unassigned + 1] = i
    end
  end
  for key, rec in pairs(regs) do
    if not live[key] and not consumed[key] then
      known[key] = true
      key_of_seat[rec.terminal_id] = key_of_seat[rec.terminal_id] or key
      dead[rec.project] = dead[rec.project] or {}
      table.insert(
        dead[rec.project],
        { key = key, tid = rec.terminal_id, session_id = rec.session, rec = rec, live = false, name = rec.name }
      )
    end
  end

  -- thread ownership: by session; an unattributed thread from a known seat is that seat's "earlier session"
  local by_owner, orphans, earlier = {}, {}, {}
  for _, t in ipairs(threads) do
    if not t.archived or opts.show_archived then
      local key = M.owner_key(t)
      local tid = t.owner and t.owner.herdr and t.owner.herdr.terminal_id
      local s = tid and (seat[tid] or (key_of_seat[tid] and live[key_of_seat[tid]]))
      local legacy = tid and seat[tid]
      if key and known[key] then
        by_owner[key] = by_owner[key] or {}
        table.insert(by_owner[key], t)
      elseif legacy and not legacy.session and not consumed[regkey(legacy)] and not live[regkey(legacy)] then
        -- a dead pre-session agent: its unattributed threads are its own (one Past row, not two)
        local k = regkey(legacy)
        by_owner[k] = by_owner[k] or {}
        table.insert(by_owner[k], t)
      elseif s and s.project then
        local okey = "old:" .. tid
        if not by_owner[okey] then
          by_owner[okey] = {}
          local p = s.project or "?"
          earlier[p] = earlier[p] or {}
          table.insert(earlier[p], {
            key = okey,
            tid = tid,
            live = false,
            name = (s.name or tid) .. " · earlier session",
            rec = { name = (s.name or tid) .. " · earlier session", terminal_id = tid, project = p },
          })
        end
        table.insert(by_owner[okey], t)
      else
        orphans[#orphans + 1] = t
      end
    end
  end
  local ctx = { by_owner = by_owner, key_of_seat = key_of_seat }

  local totals = { needs_you = 0, working = 0, blocked = 0 }
  local projects = {}
  for _, n in ipairs(names) do
    local children = nest(by_proj[n] or {}, ctx)
    local counts = { needs_you = 0, working = 0, blocked = 0 }
    for _, c in ipairs(children) do
      sum(counts, c.sub)
    end
    sum(totals, counts)
    local p =
      { kind = "project", key = "p:" .. n, name = n, counts = counts, children = children, urgency = tier(counts) }
    -- X marks rec.dead: dismissed from past once it owns no visible threads (g. brings it back)
    local shown = vim.tbl_filter(function(i)
      return opts.show_archived or not i.rec.dead or by_owner[i.key] ~= nil
    end, dead[n] or {})
    if #shown > 0 or earlier[n] then
      local past = nest(shown, ctx, true)
      table.sort(past, function(a, b)
        return a.recent > b.recent
      end)
      local old = nest(earlier[n] or {}, ctx, true)
      table.sort(old, function(a, b)
        return a.recent > b.recent
      end)
      p.past = { kind = "past", key = "past:" .. n, project = n, children = vim.list_extend(past, old) }
    end
    projects[#projects + 1] = p
  end
  table.sort(projects, function(a, b)
    if a.urgency ~= b.urgency then
      return a.urgency < b.urgency
    end
    return a.name < b.name
  end)

  local out = { { kind = "header", key = "header", counts = totals, depth = 0 } }
  for _, p in ipairs(projects) do
    flatten(p, 0, out)
  end

  local un_children = nest(unassigned, ctx)
  for _, c in ipairs(un_children) do
    sum(totals, c.sub)
  end
  for _, t in ipairs(orphans) do
    if t.status == "needs_you" then
      totals.needs_you = totals.needs_you + 1
    end
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
