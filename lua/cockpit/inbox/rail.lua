-- cockpit rail: project → agent → fork → thread tree (tree.lua), one line per row, real vim folds.
-- Fold state is kept by node key across re-renders (the 3 s refresh must never move folds or cursor).
local util = require("cockpit.inbox.util")
local store = require("cockpit.inbox.store")
local M = {}

local W = 35 -- RAIL_W (36) minus one spare column
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

local function agent_parts(node)
  local g = util.AGENT[node.status] or util.AGENT.unknown
  local left = { indent(node), node.fork and { "⑂ ", "Special" } or { g[1] .. " ", g[2] } }
  local suffix = (node.fork == "worktree" and " wt" or "") .. (node.orphan_of and (" (from " .. node.orphan_of .. ")") or "")
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
  elseif node.children and #node.children > 0 then
    return ">" .. (node.depth + 1)
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
      cursors[w] = { key = v.map[c] and v.map[c].key, row = c, topline = vim.fn.line("w0") }
    end)
  end

  local nodes = require("cockpit.inbox.tree").build({ show_archived = show_archived })
  local lines, marks, map, rows, levels, parts_by = {}, {}, {}, {}, {}, {}
  for _, node in ipairs(nodes) do
    if node.kind == "agent" and node.live then
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
    local parts = parts_for(node)
    local r = #lines + 1
    lines[r] = util.segs(r - 1, parts, marks)
    map[r], rows[node.key], levels[r], parts_by[r] = node, r, level(node), parts
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
    local o = node.thread.owner and node.thread.owner.herdr
    return o and M.node(buf, M.row(buf, "a:" .. o.terminal_id))
  end
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

local function open_thread(t)
  ui().select(t.id)
  local projects = require("cockpit.projects")
  local dir = (t.project and projects.get(t.project)) and projects.root(t.project) or (t.session and t.session.cwd)
  if dir and vim.fn.isdirectory(dir) == 1 then
    vim.cmd.tcd(vim.fn.fnameescape(dir))
  end
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
    local o = t.owner and t.owner.herdr
    return t.archived and o and o.terminal_id == node.terminal_id
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
  local rec = recs[tid]
  local owned = vim.tbl_filter(function(t)
    local o = t.owner and t.owner.herdr
    return not t.archived and o and o.terminal_id == tid
  end, store.threads())
  local forks = 0
  for _, r in pairs(recs) do
    if r.parent_terminal == tid and herdr.by_terminal(r.terminal_id) then
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
  if a then
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
  "  za zo zc zM zR zj zk  folds",
}

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
  local function with_agent(fn, live)
    return function()
      local a = agent_of(buf, cursor_node(buf))
      if not a or (live and not a.live) then
        return vim.notify("cockpit: no " .. (live and "live " or "") .. "agent on this row", vim.log.levels.WARN)
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
  map(buf, "X", with_agent(M.kill_agent), "Kill agent")
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
  map(buf, "f", with_agent(fork("continue"), true), "Fork agent (continue)")
  map(buf, "F", with_agent(fork("worktree"), true), "Fork agent (worktree)")
  map(buf, "i", with_agent(function(a)
    herdr.interrupt(a.agent.target)
  end, true), "Interrupt agent")
  map(buf, "gt", with_agent(function(a)
    herdr.attach(a.agent.target)
  end, true), "Attach to agent")
  map(buf, "a", with_thread(function(t)
    store.append(store.thread_file(t.id), { kind = "state", archived = not t.archived })
  end), "Archive / unarchive")
  map(buf, "u", with_thread(function(t)
    store.append(store.thread_file(t.id), { kind = "state", read = t.status == "unread" })
  end), "Toggle unread")
  map(buf, "g.", function()
    show_archived = not show_archived
    M.render(buf)
  end, "Toggle archived")
  map(buf, "R", function()
    herdr.reconcile()
    ui().refresh()
  end, "Cockpit: refresh")
  map(buf, "s", function()
    ui().spawn()
  end, "Spawn agent")
  map(buf, "A", function()
    ui().pick_agent()
  end, "Agent picker")
  map(buf, "q", function()
    ui().close()
  end, "Close cockpit")
  map(buf, "?", function()
    vim.lsp.util.open_floating_preview(HELP, "", { border = "rounded", focus_id = "cockpit_rail_help", title = " rail keys " })
  end, "Rail keys")
  M.render(buf)
end

return M
