-- cockpit rail: project → agent → fork → thread tree (tree.lua), one line per row, real vim folds.
-- Fold state is kept by node key across re-renders (the 3 s refresh must never move folds or cursor).
local util = require("cockpit.inbox.util")
local store = require("cockpit.inbox.store")
local M = {}

local W = 49 -- usable columns; recomputed from the rail window's width on every render
local WIDE = 90 -- at or above this width (rail docked as a top strip) cards squeeze to 2 lines
local EXPR = "v:lua.require'cockpit.inbox.rail'.foldexpr(v:lnum)"
local TEXT = "v:lua.require'cockpit.inbox.rail'.foldtext()"
-- buf -> { map = row->node, rows = key->row, levels = row->fold level, parts = row->segments,
--          closed = set of closed fold keys, seen = set of keys ever rendered }
local views = {}
local detail = {} -- terminal_id -> blocked prompt line ("" none, false = fetch pending)
local show_archived = false

local function ui()
  return require("cockpit.inbox.ui")
end

local function dw(s)
  return vim.fn.strdisplaywidth(s)
end

local function width(parts)
  local n = 0
  for _, p in ipairs(parts) do
    n = n + dw(p[1])
  end
  return n
end

-- truncate to `room` display columns with …
local function fit(s, room)
  s = (s or ""):gsub("\n", " ")
  if dw(s) <= room then
    return s
  end
  local out = ""
  for _, ch in ipairs(vim.fn.split(s, "\\zs")) do
    if dw(out .. ch) > room - 1 then
      break
    end
    out = out .. ch
  end
  return room >= 1 and out .. "…" or ""
end

-- left .. padding .. right (right-aligned at W)
local function line(left, right)
  local parts = vim.list_extend({}, left)
  if right and #right > 0 then
    parts[#parts + 1] = { string.rep(" ", math.max(1, W - width(left) - width(right))) }
    vim.list_extend(parts, right)
  end
  return parts
end

local COUNTS = {
  { "needs_you", "✋", "DiagnosticWarn" },
  { "working", "◐", "DiagnosticInfo" },
  { "blocked", "⚠", "DiagnosticWarn" },
}
local function counts(c, always)
  local out = {}
  for _, k in ipairs(COUNTS) do
    local n = c[k[1]] or 0
    if always or n > 0 then
      if #out > 0 then
        out[#out + 1] = { " " }
      end
      out[#out + 1] = { k[2] .. n, n > 0 and k[3] or "Comment" }
    end
  end
  return out
end

-- tree.lua gives `unassigned` no counts; derive them from its children
local function unassigned_counts(node)
  local c = { needs_you = 0, working = 0, blocked = 0 }
  for _, ch in ipairs(node.children) do
    if ch.kind == "agent" then
      for k, n in pairs(ch.sub) do
        c[k] = c[k] + n
      end
    elseif ch.thread.status == "needs_you" then
      c.needs_you = c.needs_you + 1
    end
  end
  return c
end

local function indent(node)
  return { string.rep("  ", node.depth) }
end

-- word-wrap s to at most n lines of `room` columns; the last line gets … when cut
local function wrap(s, room, n)
  local words = vim.split(vim.trim((s or ""):gsub("%s+", " ")), " ", { plain = true })
  local out, cur = {}, ""
  for i, w in ipairs(words) do
    local cand = cur == "" and w or (cur .. " " .. w)
    if dw(cand) <= room then
      cur = cand
    elseif dw(w) > room / 2 then
      -- a long token (URL, path): hard-split it across lines instead of leaving a stub line
      local acc = ""
      for _, ch in ipairs(vim.fn.split(cand, "\\zs")) do
        if dw(acc .. ch) > room then
          out[#out + 1] = acc
          if #out == n then
            out[n] = fit(acc .. " " .. table.concat(words, " ", i), room) -- … marks the cut
            return out
          end
          acc = ""
        end
        acc = acc .. ch
      end
      cur = vim.trim(acc)
    else
      if cur ~= "" then
        out[#out + 1] = cur
      end
      if #out == n then
        out[n] = fit(out[n] .. " " .. table.concat(words, " ", i), room)
        return out
      end
      cur = fit(w, room)
    end
  end
  if cur ~= "" then
    out[#out + 1] = cur
  end
  return out
end

local STATUS_WORD = { working = "working", blocked = "blocked", idle = "idle", done = "done" }

-- "▰▰▰▱▱ 61%" (or "130k tok" when only the transcript's token count is known)
local function ctx_parts(s)
  if s.ctx_pct then
    local n = math.floor(s.ctx_pct / 20 + 0.5)
    local hl = s.ctx_pct >= 80 and "DiagnosticError" or s.ctx_pct >= 60 and "DiagnosticWarn" or "DiagnosticOk"
    return { { string.rep("▰", n) .. string.rep("▱", 5 - n), hl }, { (" %d%%"):format(s.ctx_pct), hl } }
  elseif s.tokens then
    return { { ("%dk tok"):format(math.floor(s.tokens / 1000)), "Comment" } }
  end
  return {}
end

-- the message under an agent's name: what it waits on when blocked, else its last words
local function agent_message(node)
  local a, s = node.agent or {}, node.agent and node.agent.session
  if node.status == "blocked" then
    local d = (s and s.waiting) or detail[node.terminal_id]
    if d and d ~= "" then
      return d, "DiagnosticWarn"
    end
  end
  return (s and s.text) or a.title, "Comment"
end

-- live agent: a card of up to 4 lines (2 when the rail is wide). Returns a list of parts lists.
local function agent_card(node)
  local g = util.AGENT[node.status] or util.AGENT.unknown
  local a, s = node.agent or {}, (node.agent and node.agent.session) or {}
  local pad = { string.rep("  ", node.depth + 1) }
  local glyph = node.fork and { "⑂ ", "Special" } or { g[1] .. " ", g[2] }
  local suffix = (node.fork == "worktree" and " wt" or "")
    .. (node.orphan_of and (" (from " .. node.orphan_of .. ")") or "")
  local right = { { STATUS_WORD[node.status] or node.status or "?", g[2] } }
  if node.recent and node.recent > 0 or s.ts then
    right[#right + 1] = { " · " .. util.ago(math.max(node.recent or 0, s.ts or 0)), "Comment" }
  end
  local meta = {}
  local model = s.model or (a.source ~= "session" and a.kind) or nil
  if model then
    meta[#meta + 1] = { model, "Special" }
  end
  local ctx = ctx_parts(s)
  if #ctx > 0 then
    meta[#meta + 1] = { " · " }
    vim.list_extend(meta, ctx)
  end
  if a.source ~= "session" then
    meta[#meta + 1] = { " · herdr " .. (a.name or ""), "Comment" }
  end
  local title = s.session_name and a.source ~= "session" and s.session_name or node.name
  local msg, msg_hl = agent_message(node)
  local cards = {}
  if W >= WIDE then
    -- glyph name · model ctx …… status · ago / message on one line
    local left = { indent(node), glyph }
    local tail = vim.list_extend({ { "  " } }, meta)
    local name_room = W - width(left) - dw(suffix) - width(tail) - width(right) - 2
    vim.list_extend(left, { { fit(title, math.max(8, name_room)), "Title" }, { suffix, "Comment" } })
    cards[1] = line(vim.list_extend(left, tail), right)
    if msg and msg ~= "" then
      cards[2] = { pad, { fit(msg, W - width({ pad })), msg_hl } }
    end
    return cards
  end
  local left = { indent(node), glyph }
  local name_room = W - width(left) - dw(suffix) - width(right) - 1
  vim.list_extend(left, { { fit(title, name_room), "Title" }, { suffix, "Comment" } })
  cards[1] = line(left, right)
  if #meta > 0 then
    cards[#cards + 1] = vim.list_extend({ pad }, meta)
  end
  if msg and msg ~= "" then
    for _, l in ipairs(wrap(msg, W - width({ pad }), 2)) do
      cards[#cards + 1] = { pad, { l, msg_hl } }
    end
  end
  return cards
end

local function agent_parts(node)
  local g = util.AGENT[node.status] or util.AGENT.unknown
  local left = { indent(node), node.fork and { "⑂ ", "Special" } or { g[1] .. " ", g[2] } }
  local suffix = (node.fork == "worktree" and " wt" or "")
    .. (node.orphan_of and (" (from " .. node.orphan_of .. ")") or "")
  local right = {}
  if node.fork then
    right[1] = { g[1], g[2] }
  end
  local d = node.status == "blocked" and detail[node.terminal_id]
  if not d or d == "" then
    if node.recent and node.recent > 0 then
      right[#right + 1] = { (node.fork and " " or "") .. util.ago(node.recent), "Comment" }
    end
  end
  local name_room = W - width(left) - dw(suffix) - width(right) - 1
  if d and d ~= "" then
    name_room = math.min(name_room, math.max(8, W - width(left) - dw(suffix) - 12))
  end
  vim.list_extend(left, {
    { fit(node.name, name_room), not node.live and "Comment" or nil },
    { suffix, "Comment" },
  })
  if d and d ~= "" then
    local room = W - width(left) - width(right) - 2
    if room >= 4 then
      right[#right + 1] = { (node.fork and " " or "") .. fit(d, room), "DiagnosticWarn" }
    end
  end
  return line(left, right)
end

local function thread_parts(node)
  local t = node.thread
  local st = util.run_status(t)
  local s = util.STATUS[st] or util.STATUS.read
  local right = {}
  if #(t.deliverables or {}) > 0 then
    right[#right + 1] = { "📎" .. #t.deliverables .. " ", "Comment" }
  end
  if #(t.open_questions or {}) > 0 then
    right[#right + 1] = { "?" .. #t.open_questions .. " ", "DiagnosticWarn" }
  end
  right[#right + 1] = { " " .. util.ago(t.last_ts), "Comment" }
  local left = { indent(node), { s[1] .. " ", s[2] } }
  local dim = (st == "done" or t.archived) and "Comment" or nil
  left[#left + 1] = { fit(t.title or t.id, W - width(left) - width(right) - 1), dim }
  return line(left, right)
end

local function parts_for(node)
  local k = node.kind
  if k == "header" then
    local p = { { "COCKPIT", "Title" }, { "  " } }
    vim.list_extend(p, counts(node.counts, true))
    if show_archived then
      p[#p + 1] = { "  +archived", "Comment" }
    end
    return p
  elseif k == "project" or k == "unassigned" then
    local right = counts(k == "project" and node.counts or unassigned_counts(node))
    local name = k == "project" and node.name or "unassigned"
    return line({ { "▾ ", "Directory" }, { fit(name, W - 2 - width(right) - 1), "Directory" } }, right)
  elseif k == "past" then
    return { indent(node), { ("▾ past (%d)"):format(#node.children), "Comment" } }
  elseif k == "agent" then
    return agent_parts(node)
  end
  return thread_parts(node)
end

-- foldexpr level: project/unassigned open level 1; any other node with children opens depth+1;
-- leaves sit inside their parent's fold
local function level(node)
  if node.kind == "header" then
    return "0"
  elseif node.kind == "project" or node.kind == "unassigned" then
    return ">1"
  elseif (node.children and #node.children > 0) or (node.kind == "agent" and node.live) then
    return ">" .. (node.depth + 1) -- a live agent's card folds down to its first line
  end
  return tostring(node.depth)
end

function M.foldexpr(lnum)
  local v = views[vim.api.nvim_get_current_buf()]
  return v and v.levels[lnum] or "0"
end

-- the row itself (highlighted), with ▾ turned to ▸
function M.foldtext()
  local v = views[vim.api.nvim_get_current_buf()]
  local parts = v and v.parts[vim.v.foldstart]
  if not parts then
    return vim.fn.getline(vim.v.foldstart)
  end
  local out, swapped = {}, false
  for _, p in ipairs(parts) do
    local text = p[1]
    if not swapped and text:find("▾", 1, true) then
      text, swapped = text:gsub("▾", "▸", 1), true
    end
    out[#out + 1] = { text, p[2] or "Normal" }
  end
  return out
end

-- window-local fold options; true when they had to be (re)set, i.e. the window's folds are fresh
local function ensure_win(w)
  if vim.wo[w].foldmethod == "expr" and vim.wo[w].foldexpr == EXPR then
    return false
  end
  local function o(k, val)
    vim.api.nvim_set_option_value(k, val, { win = w, scope = "local" })
  end
  o("foldexpr", EXPR)
  o("foldtext", TEXT)
  o("fillchars", "fold: ,eob: ")
  o("foldminlines", 0)
  o("foldlevel", 99)
  o("foldcolumn", "0")
  o("foldenable", true)
  o("foldmethod", "expr")
  return true
end

-- Reapply the remembered fold state (and optionally the cursor node) in window w
local function apply_folds(buf, w, cur)
  local v = views[buf]
  vim.api.nvim_win_call(w, function()
    vim.cmd("silent! normal! zx")
    vim.cmd("silent! %foldopen!")
    local closing = {}
    for key in pairs(v.closed) do
      local r = v.rows[key]
      if r and v.levels[r]:sub(1, 1) == ">" then
        closing[#closing + 1] = r
      end
    end
    table.sort(closing, function(a, b) -- children before parents
      return a > b
    end)
    for _, r in ipairs(closing) do
      vim.cmd(("silent! %dfoldclose"):format(r))
    end
    if cur then
      local n = vim.api.nvim_buf_line_count(buf)
      local r = (cur.key and v.rows[cur.key]) or math.min(cur.row, n)
      if cur.key and v.rows[cur.key] and cur.off then
        r = math.min(r + cur.off, n)
      end
      vim.fn.winrestview({ topline = math.min(cur.topline, n) })
      vim.api.nvim_win_set_cursor(w, { r, 0 })
    end
  end)
end

local function render_all()
  for b in pairs(views) do
    if vim.api.nvim_buf_is_valid(b) then
      M.render(b)
    else
      views[b] = nil
    end
  end
end

-- the approval prompt a blocked agent is waiting on: last non-empty line that isn't box drawing
local function fetch_detail(tid, target)
  detail[tid] = false
  require("cockpit.herdr").request("agent.read", { target = target, source = "recent", lines = 15 }, function(_, res)
    if detail[tid] ~= false then
      return -- left blocked meanwhile
    end
    local text = res and ((res.read and res.read.text) or res.text) or ""
    local pick = ""
    for _, l in ipairs(vim.split(text, "\n")) do
      local s = vim.trim((l:gsub("\226[\148\149][\128-\191]", " "))) -- U+2500–U+257F box drawing
      if s ~= "" then
        pick = s
      end
    end
    detail[tid] = pick
    render_all()
  end)
end

local function new_view()
  return { map = {}, rows = {}, levels = {}, parts = {}, closed = {}, seen = {} }
end

function M.render(buf)
  views[buf] = views[buf] or new_view()
  local v = views[buf]
  -- 1. remember fold state + cursor node per window (rows hidden inside a closed fold keep their old state)
  local cursors, fresh = {}, {}
  for _, w in ipairs(vim.fn.win_findbuf(buf)) do
    fresh[w] = ensure_win(w)
    vim.api.nvim_win_call(w, function()
      if not fresh[w] then
        for row, node in pairs(v.map) do
          if v.levels[row] and v.levels[row]:sub(1, 1) == ">" then
            local fc = vim.fn.foldclosed(row)
            if fc == row then
              v.closed[node.key] = true
            elseif fc == -1 then
              v.closed[node.key] = nil
            end
          end
        end
      end
      local c = vim.api.nvim_win_get_cursor(w)[1]
      local key = v.map[c] and v.map[c].key
      local off = key and v.rows[key] and (c - v.rows[key]) or 0
      cursors[w] = { key = key, row = c, off = off, topline = vim.fn.line("w0") }
    end)
  end
  local wins = vim.fn.win_findbuf(buf)
  if #wins > 0 then
    W = math.max(24, vim.api.nvim_win_get_width(wins[1]) - 1)
  end

  local nodes = require("cockpit.inbox.tree").build({ show_archived = show_archived })
  local lines, marks, map, rows, levels, parts_by = {}, {}, {}, {}, {}, {}
  for _, node in ipairs(nodes) do
    if node.kind == "agent" and node.live and node.agent.source ~= "session" then
      if node.status == "blocked" then
        if detail[node.terminal_id] == nil then
          fetch_detail(node.terminal_id, node.agent.target)
        end
      else
        detail[node.terminal_id] = nil
      end
    end
    if not v.seen[node.key] then
      v.seen[node.key] = true
      if node.kind == "past" or node.kind == "unassigned" then
        v.closed[node.key] = true
      end
    end
    local card = (node.kind == "agent" and node.live) and agent_card(node) or { parts_for(node) }
    local first = #lines + 1
    rows[node.key] = first
    for i, parts in ipairs(card) do
      local r = #lines + 1
      lines[r] = util.segs(r - 1, parts, marks)
      -- card lines after the first sit inside the agent's own fold
      map[r], levels[r], parts_by[r] = node, i == 1 and level(node) or tostring(node.depth + 1), parts
    end
  end
  if #nodes == 1 then
    for _, l in ipairs({ "", "  (no projects — s spawns an agent)" }) do
      lines[#lines + 1] = l
      levels[#lines] = "0"
    end
  end
  -- 2. set lines (levels first: foldexpr reads them)
  v.map, v.rows, v.levels, v.parts = map, rows, levels, parts_by
  util.set_lines(buf, lines)
  for _, m in ipairs(marks) do
    util.hl(buf, m[1], m[2], m[3], m[4])
  end
  -- 3–5. zx, re-close remembered keys, cursor back on its node
  for w, cur in pairs(cursors) do
    apply_folds(buf, w, cur)
  end
end

function M.row(buf, key)
  return views[buf] and views[buf].rows[key]
end

function M.node(buf, row)
  return views[buf] and views[buf].map[row]
end

local function cursor_node(buf)
  return M.node(buf, vim.api.nvim_win_get_cursor(0)[1])
end

-- the agent node a row acts on: itself, or a thread's owner agent
local function agent_of(buf, node)
  if node and node.kind == "agent" then
    return node
  elseif node and node.kind == "thread" then
    local key = require("cockpit.inbox.tree").owner_key(node.thread)
    return key and M.node(buf, M.row(buf, "a:" .. key))
  end
end

-- the project a row belongs to, or nil (header, unassigned rows, project-less agents/threads)
local function project_of(node)
  if not node then
    return nil
  elseif node.kind == "project" then
    return node.name
  elseif node.kind == "past" then
    return node.project
  elseif node.kind == "agent" then
    return (node.rec and node.rec.project) or (node.agent and node.agent.project)
  elseif node.kind == "thread" then
    return node.thread.project
  end
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

local function open_thread(t)
  local projects = require("cockpit.projects")
  local dir = (t.project and projects.get(t.project)) and projects.root(t.project) or (t.session and t.session.cwd)
  ui().select(t.id, nil, { dir = dir, open_diff = true })
end

-- does agent node own thread t: by Claude session; an "earlier session" node owns its seat's unattributed threads
local function owns(node, t)
  local key = require("cockpit.inbox.tree").owner_key(t)
  if key then
    return key == node.akey
  end
  local o = t.owner and t.owner.herdr
  return node.akey == "old:" .. tostring(node.terminal_id) and o ~= nil and o.terminal_id == node.terminal_id
end

local function open(buf, node)
  if not node or node.kind == "header" then
    return
  elseif node.kind == "thread" then
    return open_thread(node.thread)
  elseif node.kind ~= "agent" then
    return vim.cmd("silent! normal! za")
  end
  if node.live then
    local newest
    for _, c in ipairs(node.children) do
      if c.kind == "thread" and (not newest or (c.thread.last_ts or 0) > (newest.last_ts or 0)) then
        newest = c.thread
      end
    end
    return newest and open_thread(newest) or vim.notify("cockpit: " .. node.name .. " has no threads yet")
  end
  -- past agent: pick one of its archived threads
  local list = vim.tbl_filter(function(t)
    return t.archived and owns(node, t)
  end, store.threads())
  if #list == 0 then
    return vim.notify("cockpit: " .. node.name .. " has no archived threads")
  end
  vim.ui.select(list, {
    prompt = node.name .. " · archived threads",
    format_item = function(t)
      return ("%s · %s"):format(t.title or t.id, util.ago(t.last_ts))
    end,
  }, function(t)
    if t then
      open_thread(t)
    end
  end)
end

-- X: kill the agent's pane, archive the threads it owns, mark it dead in the registry.
-- Accepts a rail agent node or a herdr cache entry (from the agent picker).
function M.kill_agent(node)
  local herdr, registry = require("cockpit.herdr"), require("cockpit.registry")
  local tid = node.terminal_id
  local a -- live herdr cache entry to kill; nil for a dead (past) agent
  if node.kind ~= "agent" then
    a = node
  elseif node.live then
    a = node.agent
  end
  local name = node.name or (a and a.target) or tid
  local project = (node.rec and node.rec.project) or (a and a.project)
  local recs = project and registry.all(project) or {}
  local rec = node.rec or (project and registry.by_terminal(project, tid))
  local sid = node.session_id or (a and a.session_id)
  local target = node.kind == "agent" and node or { akey = sid or ("term:" .. tostring(tid)), terminal_id = tid }
  local owned = vim.tbl_filter(function(t)
    return not t.archived and owns(target, t)
  end, store.threads())
  local forks = 0
  for _, r in pairs(recs) do
    local child = (sid and r.parent_session == sid) or (not r.parent_session and r.parent_terminal == tid)
    if child and herdr.by_terminal(r.terminal_id) then
      forks = forks + 1
    end
  end
  local msg = ("Kill %s and archive its %d threads?"):format(name, #owned)
  if forks > 0 then
    msg = msg .. (" (%d forks keep running)"):format(forks)
  end
  if vim.fn.confirm(msg, "&Yes\n&No", 2) ~= 1 then
    return
  end
  if a and a.source == "session" then
    -- hand-started tmux session: end Claude, leave the pane and its shell
    local ok, err = vim.uv.kill(a.session.pid, "sigterm")
    if not ok and err then
      return vim.notify("cockpit: kill failed — " .. err, vim.log.levels.ERROR)
    end
  elseif a then
    local err = herdr.kill(a.target)
    if err then
      return vim.notify("cockpit: kill failed — " .. err.message, vim.log.levels.ERROR)
    end
  end
  for _, t in ipairs(owned) do
    store.append(store.thread_file(t.id), { kind = "state", archived = true })
  end
  if rec then
    registry.append(project, vim.tbl_extend("force", rec, { dead = true }))
    local ok, f = pcall(require, "cockpit.forks")
    if ok and rec.fork == "worktree" then
      local cok, cerr = pcall(f.cleanup, rec)
      if not cok then
        vim.notify("cockpit: fork cleanup failed — " .. tostring(cerr), vim.log.levels.ERROR)
      end
    end
  end
  vim.notify(("cockpit: killed %s, archived %d threads"):format(name, #owned))
  ui().refresh()
end

local HELP = {
  "Agent / fork row (thread row: its agent)",
  "  X     kill + archive its threads",
  "  f F   fork (continue / worktree)",
  "  i     interrupt      gt  attach",
  "        (tmux sessions: no forks; X ends claude, pane stays)",
  "  <CR>  open newest thread",
  "        (past agent: archived threads)",
  "Thread row",
  "  <CR>  open          a  archive",
  "  u     toggle unread",
  "Project / past / unassigned",
  "  <CR>  toggle fold",
  "Any row",
  "  s spawn   A agent picker   R refresh",
  "  g. show archived   q close",
  "  gv rail left/top   <C-w>< > + - resize",
  "  za zo zc zM zR zj zk  folds",
}

-- :CockpitCleanup — float of unarchived threads whose agent is gone; y archives them all, q cancels.
function M.cleanup()
  local herdr = require("cockpit.herdr")
  -- an empty cache only means "dead" once herdr has answered; otherwise every herdr thread would look dead
  if not herdr.reconciled() then
    herdr.reconcile()
    return vim.notify(
      "cockpit: herdr not reachable (or not checked yet) — can't tell which agents are dead; try again",
      vim.log.levels.WARN
    )
  end
  local panes
  local function pane_alive(p)
    if not panes then
      panes = {}
      for _, id in ipairs(vim.fn.systemlist({ "tmux", "list-panes", "-a", "-F", "#{pane_id}" })) do
        panes[id] = true
      end
    end
    return panes[p]
  end
  local live_sessions = {}
  for _, a in pairs(herdr.agents()) do
    if a.session_id then
      live_sessions[a.session_id] = true
    end
  end
  for _, s in ipairs(require("cockpit.sessions").list()) do
    live_sessions[s.session_id or ""] = true
  end
  local cands = vim.tbl_filter(function(t)
    if t.archived then
      return false
    end
    local sid = store.owner_session(t)
    if sid then -- its conversation ended, even if another one now runs in the same pane
      return not live_sessions[sid]
    end
    local h = t.owner and t.owner.herdr
    if h then
      return h.terminal_id ~= nil and herdr.by_terminal(h.terminal_id) == nil
    end
    local p = t.session and t.session.tmux_pane
    return p ~= nil and not pane_alive(p)
  end, store.threads())
  if #cands == 0 then
    return vim.notify("cockpit: nothing to clean up")
  end
  local lines = {}
  for _, t in ipairs(cands) do
    lines[#lines + 1] = ("%s · %s · %s"):format(t.title or t.id, t.project or "-", util.ago(t.last_ts))
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "y archive all · q cancel"
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local w = 20
  for _, l in ipairs(lines) do
    w = math.max(w, vim.fn.strdisplaywidth(l))
  end
  w = math.min(w, vim.o.columns - 4)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = w,
    height = #lines,
    row = math.max(0, math.floor((vim.o.lines - #lines) / 2)),
    col = math.max(0, math.floor((vim.o.columns - w) / 2)),
    style = "minimal",
    border = "rounded",
    title = (" cleanup: %d dead-agent threads "):format(#cands),
  })
  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  util.map(buf, "y", function()
    close()
    for _, t in ipairs(cands) do
      store.append(store.thread_file(t.id), { kind = "state", archived = true })
    end
    vim.notify(("cockpit: archived %d threads"):format(#cands))
    ui().refresh()
  end, "Archive all")
  util.map(buf, "q", close, "Cancel")
  util.map(buf, "<Esc>", close, "Cancel")
end

function M.attach(buf)
  views[buf] = views[buf] or new_view()
  local map, herdr = util.map, require("cockpit.herdr")
  vim.api.nvim_create_autocmd("BufWinEnter", {
    buffer = buf,
    callback = function()
      for _, w in ipairs(vim.fn.win_findbuf(buf)) do
        if ensure_win(w) then
          apply_folds(buf, w)
        end
      end
    end,
  })
  local sessions = require("cockpit.sessions")
  local function is_session(a)
    return a.agent and a.agent.source == "session"
  end
  -- herdr_only: fork/kill need herdr; a hand-started tmux session can't take them
  local function with_agent(fn, live, herdr_only)
    return function()
      local a = agent_of(buf, cursor_node(buf))
      if not a or (live and not a.live) then
        return vim.notify("cockpit: no " .. (live and "live " or "") .. "agent on this row", vim.log.levels.WARN)
      end
      if herdr_only and is_session(a) then
        return vim.notify(
          "cockpit: " .. a.name .. " runs in tmux pane " .. a.agent.pane_id .. ", not herdr — gt to go there",
          vim.log.levels.WARN
        )
      end
      fn(a)
    end
  end
  local function with_thread(fn)
    return function()
      local n = cursor_node(buf)
      if n and n.kind == "thread" then
        fn(n.thread)
        ui().refresh()
      end
    end
  end
  map(buf, "<CR>", function()
    open(buf, cursor_node(buf))
  end, "Open")
  map(buf, "X", with_agent(M.kill_agent, false, false), "Kill agent")
  local function fork(kind)
    return function(a)
      vim.ui.input({ prompt = "Fork prompt (optional): " }, function(text)
        if text == nil then
          return -- cancelled
        end
        require("cockpit.forks")[kind](a.agent, text, function()
          ui().refresh()
        end)
      end)
    end
  end
  map(buf, "f", with_agent(fork("continue"), true, true), "Fork agent (continue)")
  map(buf, "F", with_agent(fork("worktree"), true, true), "Fork agent (worktree)")
  map(
    buf,
    "i",
    with_agent(function(a)
      if is_session(a) then
        return sessions.interrupt(a.agent.pane_id)
      end
      herdr.interrupt(a.agent.target)
    end, true),
    "Interrupt agent"
  )
  map(
    buf,
    "gt",
    with_agent(function(a)
      if is_session(a) then
        return sessions.attach(a.agent.pane_id)
      end
      herdr.attach(a.agent.target)
    end, true),
    "Attach to agent"
  )
  map(buf, "gv", function()
    ui().flip_rail()
  end, "Rail: left column / top strip")
  vim.api.nvim_create_autocmd("WinResized", {
    callback = function()
      for _, w in ipairs(vim.v.event.windows or {}) do
        if vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_buf(w) == buf then
          ui().rail_resized(w)
          return M.render(buf)
        end
      end
    end,
  })
  map(
    buf,
    "a",
    with_thread(function(t)
      store.append(store.thread_file(t.id), { kind = "state", archived = not t.archived })
    end),
    "Archive / unarchive"
  )
  map(
    buf,
    "u",
    with_thread(function(t)
      store.append(store.thread_file(t.id), { kind = "state", read = t.status == "unread" })
    end),
    "Toggle unread"
  )
  map(buf, "g.", function()
    show_archived = not show_archived
    M.render(buf)
  end, "Toggle archived")
  map(buf, "R", function()
    herdr.reconcile()
    ui().refresh()
  end, "Cockpit: refresh")
  map(buf, "s", function()
    local p = project_of(cursor_node(buf))
    -- no defined project on this row (header, unassigned, a thread from an undefined project): pick one
    ui().spawn((p and require("cockpit.projects").get(p)) and p or nil)
  end, "Spawn agent")
  map(buf, "A", function()
    ui().pick_agent()
  end, "Agent picker")
  map(buf, "q", function()
    ui().close()
  end, "Close cockpit")
  map(buf, "?", function()
    vim.lsp.util.open_floating_preview(
      HELP,
      "",
      { border = "rounded", focus_id = "cockpit_rail_help", title = " rail keys " }
    )
  end, "Rail keys")
  M.render(buf)
end

return M
