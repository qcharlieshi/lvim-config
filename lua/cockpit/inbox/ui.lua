-- cockpit UI: one tab, three fixed windows — runs rail (left) · workspace (deliverable under
-- review, editable) · thread (bottom right). Selecting anything swaps buffers in those windows;
-- nothing opens tabs or splits except the transient reply composer and CodeDiff (own tab).
-- Every view is re-rendered from store; the only UI-held truth is unsent answers/reply text.
local store = require("cockpit.inbox.store")
local M = {}

local ns = vim.api.nvim_create_namespace("cockpit_inbox")
local ns_edit = vim.api.nvim_create_namespace("cockpit_inbox_edits")
local views = {} -- buf -> { kind, map, tid, att, ... }
local drafts = {} -- tid -> { answers = { [qkey] = { opt = true } }, verdict, text }
local ck = { last_att = {} } -- cockpit tab: tab, rail, work, thread (wins), tid, show_archived

local RAIL_W, THREAD_H = 36, 14

local STATUS = {
  needs_you = { "✋", "DiagnosticWarn", "waiting on you" },
  unread = { "●", "DiagnosticInfo", "unread" },
  working = { "⟳", "DiagnosticInfo", "agent working" },
  replied = { "↩", "Comment", "replied" },
  read = { "○", "Comment", "" },
  done = { "✓", "DiagnosticOk", "done" },
}
local RANK = { needs_you = 1, unread = 2, working = 3, replied = 4, read = 5, done = 6 }
local STRIP = {
  done = { "●", "DiagnosticOk" },
  needs_you = { "◉", "DiagnosticWarn" },
  working = { "◉", "DiagnosticInfo" },
  todo = { "○", "Comment" },
}
local VERDICTS = {
  approve = "approved",
  approve_with_notes = "approved with notes",
  changes_requested = "changes requested",
  reject = "rejected",
}
-- herdr agent status for a run's producer (only for runs posted from a herdr pane)
local AGENT = {
  working = { "◐", "DiagnosticInfo" },
  blocked = { "⚠", "DiagnosticWarn" },
  idle = { "○", "Comment" },
  done = { "○", "Comment" },
  unknown = { "?", "Comment" },
  offline = { "✕", "DiagnosticError" },
}

local function run_agent(t)
  local hid = t.session and t.session.herdr
  return hid and require("cockpit.herdr").by_terminal(hid.terminal_id)
end

local LANE_NAMES =
  { backlog = "Backlog", todo = "Todo", in_progress = "In progress", in_review = "In review", done = "Done" }

local function ago(ts)
  local d = os.time() - (ts or os.time())
  if d < 60 then
    return d .. "s"
  elseif d < 3600 then
    return math.floor(d / 60) .. "m"
  elseif d < 86400 then
    return math.floor(d / 3600) .. "h"
  end
  return math.floor(d / 86400) .. "d"
end

local function trunc(s, n)
  s = (s or ""):gsub("\n", " ")
  return vim.fn.strchars(s) > n and vim.fn.strcharpart(s, 0, n - 1) .. "…" or s
end

local function draft(tid)
  drafts[tid] = drafts[tid] or { answers = {} }
  return drafts[tid]
end

local function find_buf(name)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b) == name then
      return b
    end
  end
end

local function scratch(name, ft, buftype)
  local buf = find_buf(name)
  if not buf then
    buf = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_buf_set_name(buf, name)
    vim.bo[buf].buftype = buftype or "nofile"
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = ft
  end
  return buf
end

local function set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
end

local function hl(buf, row, col, end_col, group)
  vim.api.nvim_buf_set_extmark(buf, ns, row, col, { end_col = end_col, hl_group = group })
end

local function map(buf, lhs, fn, desc, mode)
  vim.keymap.set(mode or "n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
end

local function cursor_item(buf)
  local v = views[buf]
  return v and v.map and v.map[vim.api.nvim_win_get_cursor(0)[1]]
end

local function win_for(buf)
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(w) == buf then
      return w
    end
  end
end

-- A line built from { text, hl } segments; returns the text and its highlight marks
local function segs(row, parts, marks)
  local text, col = "", 0
  for _, p in ipairs(parts) do
    if p[2] then
      marks[#marks + 1] = { row, col, col + #p[1], p[2] }
    end
    text = text .. p[1]
    col = col + #p[1]
  end
  return text
end

local function run_status(t)
  if t.done then
    return "done"
  elseif t.stage and t.status == "replied" then
    return "working"
  end
  return t.status
end

---------------------------------------------------------------------------
-- Cockpit layout
---------------------------------------------------------------------------

local function valid(w)
  return w and vim.api.nvim_win_is_valid(w)
end

local function in_cockpit()
  return ck.tab and vim.api.nvim_tabpage_is_valid(ck.tab) and vim.api.nvim_get_current_tabpage() == ck.tab
end

local function placeholder()
  local buf = scratch("cockpit://empty", "cockpit-empty")
  set_lines(buf, { "", "  Select a run in the rail with <CR>." })
  return buf
end

local function style_wins()
  local o = { number = false, relativenumber = false, foldcolumn = "0" }
  for k, val in pairs(o) do
    vim.wo[ck.rail][k] = val
    vim.wo[ck.thread][k] = val
  end
  vim.wo[ck.rail].signcolumn, vim.wo[ck.rail].wrap, vim.wo[ck.rail].cursorline = "no", false, true
  vim.wo[ck.rail].winfixwidth = true
  vim.wo[ck.thread].wrap, vim.wo[ck.thread].linebreak, vim.wo[ck.thread].winfixheight = true, true, true
  vim.wo[ck.work].wrap, vim.wo[ck.work].linebreak, vim.wo[ck.work].signcolumn = true, true, "yes"
end

-- Ensure the cockpit tab and its three windows exist (rebuilding any the user closed)
local function layout()
  if ck.tab and vim.api.nvim_tabpage_is_valid(ck.tab) then
    require("cockpit.herdr").watch(false)
  vim.api.nvim_set_current_tabpage(ck.tab)
    if valid(ck.rail) and valid(ck.work) and valid(ck.thread) then
      return
    end
    vim.cmd("silent! only")
  else
    vim.cmd("tabnew")
    ck.tab = vim.api.nvim_get_current_tabpage()
  end
  ck.rail = vim.api.nvim_get_current_win()
  vim.cmd("botright vsplit")
  ck.work = vim.api.nvim_get_current_win()
  vim.cmd("belowright " .. THREAD_H .. "split")
  ck.thread = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_width(ck.rail, RAIL_W)
  vim.api.nvim_win_set_buf(ck.rail, M.rail_buf())
  vim.api.nvim_win_set_buf(ck.work, placeholder())
  vim.api.nvim_win_set_buf(ck.thread, placeholder())
  style_wins()
  vim.api.nvim_set_current_win(ck.rail)
end

local function focus_rail()
  if valid(ck.rail) then
    vim.api.nvim_set_current_win(ck.rail)
  end
end

function M.toggle_rail()
  if valid(ck.rail) then
    local w = vim.api.nvim_win_get_width(ck.rail)
    vim.api.nvim_win_set_width(ck.rail, w > 2 and 1 or RAIL_W)
  end
end

function M.close()
  if not (ck.tab and vim.api.nvim_tabpage_is_valid(ck.tab)) then
    return
  end
  vim.api.nvim_set_current_tabpage(ck.tab)
  if #vim.api.nvim_list_tabpages() > 1 then
    vim.cmd("tabclose")
  else
    vim.cmd("silent! only | enew")
  end
  ck.tab = nil
end

-- Keys every cockpit buffer shares; editable buffers keep R for Replace mode
local function common_maps(buf, editable)
  map(buf, "<leader>kz", M.toggle_rail, "Cockpit: toggle rail")
  map(buf, "<leader>kr", focus_rail, "Cockpit: focus rail")
  if not editable then
    map(buf, "R", M.refresh, "Cockpit: refresh")
  end
end

---------------------------------------------------------------------------
-- Runs rail
---------------------------------------------------------------------------

function M.render_rail(buf)
  local v = views[buf]
  local threads = vim.tbl_filter(function(t)
    return ck.show_archived or not t.archived
  end, store.threads())
  for _, t in ipairs(threads) do
    t.run_status = run_status(t)
  end
  table.sort(threads, function(a, b)
    if a.project ~= b.project then
      return (a.project or "") < (b.project or "")
    end
    if RANK[a.run_status] ~= RANK[b.run_status] then
      return RANK[a.run_status] < RANK[b.run_status]
    end
    return a.last_ts > b.last_ts
  end)

  local counts = { needs_you = 0, working = 0 }
  for _, t in ipairs(threads) do
    counts[t.run_status] = (counts[t.run_status] or 0) + 1
  end
  local lines, marks, item_map, rows = {}, {}, {}, {}
  lines[1] = segs(0, {
    { " RUNS ", "Title" },
    { ("✋%d"):format(counts.needs_you), counts.needs_you > 0 and "DiagnosticWarn" or "Comment" },
    { "  " },
    { ("⟳%d"):format(counts.working), counts.working > 0 and "DiagnosticInfo" or "Comment" },
    { ck.show_archived and "  +archived" or "", "Comment" },
  }, marks)
  local project
  for _, t in ipairs(threads) do
    if t.project ~= project then
      project = t.project
      lines[#lines + 1] = ""
      lines[#lines + 1] = segs(#lines, { { "── " .. (project or "?") .. " ──", "Directory" } }, marks)
    end
    local s = STATUS[t.run_status]
    local sel = t.id == ck.tid
    lines[#lines + 1] = segs(#lines, {
      { sel and "▸" or " ", "Special" },
      { s[1] .. " ", s[2] },
      { trunc(t.title or t.id, RAIL_W - 6), (t.run_status == "done" or t.archived) and "Comment" or nil },
    }, marks)
    item_map[#lines] = t
    rows[t.id] = #lines
    local second = { { "    " } }
    if t.stage then
      for i, st in ipairs(store.strip(t)) do
        if i > 1 then
          second[#second + 1] = { "─", "Comment" }
        end
        second[#second + 1] = STRIP[st.state]
      end
      second[#second + 1] = { ("  %s r%d"):format(t.stage, t.round), s[2] }
    else
      second[#second + 1] = { s[3] ~= "" and s[3] or "message", "Comment" }
    end
    if t.session and t.session.herdr then
      local a = run_agent(t)
      local g = AGENT[a and a.status or "offline"] or AGENT.unknown
      second[#second + 1] = { "  " .. g[1], g[2] }
    end
    second[#second + 1] = { "  " .. ago(t.last_ts), "Comment" }
    lines[#lines + 1] = segs(#lines, second, marks)
    item_map[#lines] = t
  end
  if #threads == 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  (empty — agents post with"
    lines[#lines + 1] = "   scripts/cockpit_inbox.py post)"
  end
  set_lines(buf, lines)
  for _, m in ipairs(marks) do
    hl(buf, m[1], m[2], m[3], m[4])
  end
  v.map, v.rows = item_map, rows
end

function M.rail_buf()
  local buf = scratch("cockpit://rail", "cockpit-rail")
  if views[buf] then
    return buf
  end
  views[buf] = { kind = "rail" }
  common_maps(buf)
  map(buf, "<CR>", function()
    local t = cursor_item(buf)
    if t then
      M.select(t.id)
    end
  end, "Open run")
  map(buf, "a", function()
    local t = cursor_item(buf)
    if t then
      store.append(store.thread_file(t.id), { kind = "state", archived = not t.archived })
      M.refresh()
    end
  end, "Archive / unarchive")
  map(buf, "u", function()
    local t = cursor_item(buf)
    if t then
      store.append(store.thread_file(t.id), { kind = "state", read = t.status == "unread" })
      M.refresh()
    end
  end, "Toggle unread")
  map(buf, "g.", function()
    ck.show_archived = not ck.show_archived
    M.render_rail(buf)
  end, "Toggle archived")
  local function with_agent(fn)
    return function()
      local t = cursor_item(buf)
      local a = t and run_agent(t)
      if not a then
        return vim.notify("cockpit: no live herdr agent for this run", vim.log.levels.WARN)
      end
      fn(a)
    end
  end
  map(buf, "s", M.spawn, "Spawn agent")
  map(buf, "A", M.pick_agent, "Agent picker")
  map(buf, "X", with_agent(M.kill_agent), "Kill agent")
  map(buf, "i", with_agent(function(a)
    require("cockpit.herdr").interrupt(a.target)
  end), "Interrupt agent")
  map(buf, "gt", with_agent(function(a)
    require("cockpit.herdr").attach(a.target)
  end), "Attach to agent")
  map(buf, "q", M.close, "Close cockpit")
  M.render_rail(buf)
  return buf
end

-- Open (or jump to) the cockpit tab
function M.open()
  require("cockpit.herdr").watch(true)
  layout()
  M.render_rail(M.rail_buf())
  focus_rail()
end
M.inbox = M.open

---------------------------------------------------------------------------
-- Thread view (bottom right)
---------------------------------------------------------------------------

local function notes_for(t, sha)
  local n = 0
  for _, d in ipairs(t.drafts) do
    if d.sha256 == sha then
      n = n + 1
    end
  end
  return n
end

function M.render_thread(buf)
  local v = views[buf]
  local t = store.thread(v.tid)
  if not t then
    return
  end
  local d = draft(t.id)
  local s = STATUS[run_status(t)]
  local lines, marks = {}, {}
  lines[1] = "# " .. (t.title or t.id)
  marks[#marks + 1] = { 0, 0, #lines[1], "Title" }
  local info = {
    { ("%s · %s · "):format(t.project or "?", t.agent), "Comment" },
    { s[1] .. " " .. (s[3] ~= "" and s[3] or t.status), s[2] },
  }
  if t.stage then
    info[#info + 1] = { "  ·  " .. (t.pipeline or "pipeline") .. "  ", "Comment" }
    for i, st in ipairs(store.strip(t)) do
      if i > 1 then
        info[#info + 1] = { " ─ ", "Comment" }
      end
      info[#info + 1] = { st.stage .. " ", st.state == "todo" and "Comment" or nil }
      info[#info + 1] = STRIP[st.state]
    end
  end
  lines[2] = segs(1, info, marks)
  lines[3] = "A approve  N +notes  C changes  X reject  r reply  1-9 pick  <CR> open  ]f [f files  q rail"
  marks[#marks + 1] = { 2, 0, #lines[3], "Comment" }

  local item_map = {}
  local open_keys = {}
  for _, q in ipairs(t.open_questions) do
    open_keys[q.key] = q
  end
  local att_n = 0
  v.attachments = {}
  v.questions = {} -- open question blocks, for 1-9 picks: { key, first, last, opts }
  local function line(text, group)
    lines[#lines + 1] = text
    if group then
      marks[#marks + 1] = { #lines - 1, 0, #text, group }
    end
  end

  for _, m in ipairs(t.messages) do
    line("")
    if m.kind == "message" then
      line(
        ("## %s%s · %s ago"):format(t.agent, m.stage and (" · " .. m.stage .. " r" .. m.round) or "", ago(m.ts)),
        "Function"
      )
      vim.list_extend(lines, (m.text or "") ~= "" and vim.split(m.text, "\n") or {})
      for _, att in ipairs(m.attachments or {}) do
        att_n = att_n + 1
        v.attachments[#v.attachments + 1] = att
        local notes = notes_for(t, att.sha256)
        line(
          ("📎 [%d] %s%s%s%s"):format(
            att_n,
            att.name,
            att.type == "diff" and (" · diff " .. (att.base or "HEAD") .. ".." .. (att.head or "")) or "",
            notes > 0 and (" · ✎" .. notes) or "",
            store.changed_since_sent(att) and " · changed since sent" or ""
          ),
          "Directory"
        )
        item_map[#lines] = { type = "att", att = att }
      end
      for _, q in ipairs(m.questions or {}) do
        local key = m.id .. "/" .. q.id
        local open = open_keys[key] ~= nil
        line("? " .. q.text .. (#q.options == 0 and "  (answer in your reply)" or ""), open and "DiagnosticWarn" or "Comment")
        local block = { key = key, first = #lines, opts = q.options }
        for i, opt in ipairs(q.options) do
          local picked = open and d.answers[key] and d.answers[key][opt]
          line(
            ("   [%s] %s%s"):format(picked and "x" or " ", (open and i <= 9) and (i .. ". ") or "", opt),
            not open and "Comment" or nil
          )
          if open then
            item_map[#lines] = { type = "opt", key = key, opt = opt }
          end
        end
        block.last = #lines
        if open and #q.options > 0 then
          v.questions[#v.questions + 1] = block
        end
      end
      if m.gate then
        line(m.stage and ("⚑ gate: approve to finish " .. m.stage) or "⚑ verdict requested", "DiagnosticWarn")
      end
    else
      line(
        ("## you · %s ago%s"):format(ago(m.ts), m.verdict and (" · " .. VERDICTS[m.verdict]) or ""),
        m.verdict == "reject" and "DiagnosticError" or "String"
      )
      vim.list_extend(lines, m.text and m.text ~= "" and vim.split(m.text, "\n") or {})
      for _, a in ipairs(m.answers or {}) do
        lines[#lines + 1] = ("  → %s: %s"):format(a.question, a.answer)
      end
      for _, ed in ipairs(m.edits or {}) do
        line(("  ✐ edited %s"):format(ed.path or ed.attachment), "Comment")
      end
      for _, n in ipairs(m.annotations or {}) do
        line(("  ✎ [%s] %s%s"):format(n.label, n.loc or "", (n.text or "") ~= "" and (" — " .. n.text) or ""), "Comment")
      end
    end
  end

  local edits = #store.edits(t)
  if #t.drafts > 0 or edits > 0 or next(d.answers) or (d.text and d.text ~= "") then
    line("")
    line(
      ("── unsent: %d notes%s%s%s"):format(
        #t.drafts,
        edits > 0 and (", " .. edits .. " edited") or "",
        next(d.answers) and ", answers" or "",
        (d.text and d.text ~= "") and ", reply draft" or ""
      ),
      "DiagnosticHint"
    )
  end

  set_lines(buf, lines)
  for _, mk in ipairs(marks) do
    hl(buf, mk[1], mk[2], mk[3], mk[4])
  end
  v.map = item_map
end

local function thread_win(tid)
  if in_cockpit() and valid(ck.thread) then
    local v = views[vim.api.nvim_win_get_buf(ck.thread)]
    if v and v.tid == tid then
      return ck.thread
    end
  end
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local v = views[vim.api.nvim_win_get_buf(w)]
    if v and v.kind == "thread" and v.tid == tid then
      return w
    end
  end
end

local function jump_attachment(buf, dir)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local rows = {}
  for r, item in pairs(views[buf].map) do
    if item.type == "att" then
      rows[#rows + 1] = r
    end
  end
  table.sort(rows)
  if dir < 0 then
    rows = vim.fn.reverse(rows)
  end
  for _, r in ipairs(rows) do
    if (dir > 0 and r > row) or (dir < 0 and r < row) then
      vim.api.nvim_win_set_cursor(0, { r, 0 })
      M.open_attachment(views[buf].tid, views[buf].map[r].att)
      return
    end
  end
end

local function pick(buf, key, opt)
  local d = draft(views[buf].tid)
  local q = d.answers[key] or {}
  q = q[opt] and {} or { [opt] = true } -- single choice: picking replaces
  d.answers[key] = next(q) and q or nil
  M.render_thread(buf)
end

-- prefix "g" in the workspace, where bare A/C/N/X/r are editing keys
local function verdict_maps(buf, tid, prefix)
  prefix = prefix or ""
  map(buf, prefix .. "r", function()
    M.compose(tid, nil)
  end, "Reply")
  map(buf, prefix .. "A", function()
    M.quick_approve(tid)
  end, "Approve")
  map(buf, prefix .. "N", function()
    M.compose(tid, "approve_with_notes")
  end, "Approve with notes")
  map(buf, prefix .. "C", function()
    M.compose(tid, "changes_requested")
  end, "Request changes")
  map(buf, prefix .. "X", function()
    M.compose(tid, "reject")
  end, "Reject")
end

local function thread_buf(tid)
  local buf = scratch("cockpit://inbox/" .. tid, "markdown")
  if views[buf] then
    return buf
  end
  views[buf] = { kind = "thread", tid = tid }
  common_maps(buf)
  verdict_maps(buf, tid)
  map(buf, "<CR>", function()
    local item = cursor_item(buf)
    if not item then
      return
    end
    if item.type == "att" then
      M.open_attachment(tid, item.att, true)
    else
      pick(buf, item.key, item.opt)
    end
  end, "Open file / pick option")
  -- One-key answers (agentic.nvim ADR 0003): the question under the cursor, else the first open one.
  -- Costs counts (`3j`) in this buffer, which is a short read-only view.
  for i = 1, 9 do
    map(buf, tostring(i), function()
      local qs = views[buf].questions or {}
      local row = vim.api.nvim_win_get_cursor(0)[1]
      local q = qs[1]
      for _, b in ipairs(qs) do
        if row >= b.first and row <= b.last then
          q = b
        end
      end
      if q and q.opts[i] then
        pick(buf, q.key, q.opts[i])
      end
    end, "Pick option " .. i)
  end
  map(buf, "]f", function()
    jump_attachment(buf, 1)
  end, "Next file")
  map(buf, "[f", function()
    jump_attachment(buf, -1)
  end, "Prev file")
  map(buf, "q", focus_rail, "Back to rail")
  return buf
end

-- Load a run into the cockpit: thread below, its current deliverable (or the last one viewed) above
function M.select(tid, focus)
  local t = store.thread(tid)
  if not t then
    return vim.notify("cockpit: no thread " .. tid, vim.log.levels.WARN)
  end
  layout()
  ck.tid = tid
  local buf = thread_buf(tid)
  vim.api.nvim_win_set_buf(ck.thread, buf)
  if t.status == "unread" or (t.status == "needs_you" and t.read_ts < t.last_ts) then
    store.append(store.thread_file(tid), { kind = "state", read = true })
  end
  M.render_thread(buf)
  local att = ck.last_att[tid]
  if not (att and vim.tbl_contains(vim.tbl_map(function(a)
    return a.sha256
  end, t.deliverables), att.sha256)) then
    att = t.deliverables[1]
  end
  if att then
    M.open_attachment(tid, att, false)
  else
    vim.api.nvim_win_set_buf(ck.work, placeholder())
    vim.wo[ck.work].winbar = ""
  end
  local rail = M.rail_buf()
  M.render_rail(rail)
  local row = views[rail].rows[tid]
  if row then
    vim.api.nvim_win_set_cursor(ck.rail, { row, 0 })
  end
  vim.api.nvim_set_current_win(focus or ck.rail)
end

-- `:Inbox <id>` and other entry points
function M.open_thread(tid)
  M.select(tid, nil)
  if valid(ck.work) then
    vim.api.nvim_set_current_win(ck.work)
  end
end

---------------------------------------------------------------------------
-- Workspace: deliverables (editable) + annotations
---------------------------------------------------------------------------

-- Map a patch line to "file:line" on the new side so steers point at real code
local function diff_loc(lines, l1, l2)
  local function at(lnum)
    local file, new = nil, nil
    for i = 1, lnum do
      local l = lines[i] or ""
      local f = l:match("^%+%+%+ b/(.+)$") or l:match("^%+%+%+ (.+)$")
      local hunk = l:match("^@@ %-%d+,?%d* %+(%d+)")
      if f then
        file, new = f, nil
      elseif hunk then
        new = tonumber(hunk) - 1
      elseif new and l:sub(1, 1) ~= "-" and l:sub(1, 1) ~= "\\" then
        new = new + 1
      end
    end
    return file, new
  end
  local file, a = at(l1)
  local _, b = at(l2)
  if not file or not a then
    return nil
  end
  return file .. ":" .. a .. ((b and b ~= a) and ("-" .. b) or "")
end

local function render_notes(buf)
  local v = views[buf]
  local t = store.thread(v.tid)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local count = vim.api.nvim_buf_line_count(buf)
  local function put(n, sent)
    local first = math.min(n.line_start, count) - 1
    local row = math.min(n.line_end, count) - 1
    local text = ("%s [%s%s] %s"):format(sent and "✓" or "✎", n.label, n.blocking and ", blocking" or "", n.text or "")
    vim.api.nvim_buf_set_extmark(buf, ns, first, 0, {
      sign_text = sent and "✓" or "✎",
      sign_hl_group = sent and "Comment" or "DiagnosticHint",
      end_row = row,
    })
    vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
      virt_lines = { { { "    " .. text, sent and "Comment" or "DiagnosticHint" } } },
    })
  end
  for _, n in ipairs(t.sent) do
    if n.sha256 == v.att.sha256 then
      put(n, true)
    end
  end
  v.notes = {}
  for _, n in ipairs(t.drafts) do
    if n.sha256 == v.att.sha256 then
      put(n, false)
      v.notes[#v.notes + 1] = n
    end
  end
  table.sort(v.notes, function(a, b)
    return a.line_start < b.line_start
  end)
end

-- Show the human's edits against what was sent: changed/added lines tinted, removed lines as
-- virtual lines where they used to be
local function render_edits(buf)
  local v = views[buf]
  vim.api.nvim_buf_clear_namespace(buf, ns_edit, 0, -1)
  local sent = store.blob(v.att.sha256)
  local cur = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local a, b = table.concat(sent, "\n") .. "\n", table.concat(cur, "\n") .. "\n"
  v.edited = a ~= b
  if not v.edited then
    return
  end
  for _, h in ipairs(vim.diff(a, b, { result_type = "indices" })) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    if cb > 0 then
      vim.api.nvim_buf_set_extmark(buf, ns_edit, sb - 1, 0, {
        end_row = sb - 1 + cb - 1,
        line_hl_group = ca > 0 and "DiffChange" or "DiffAdd",
        hl_eol = true,
        sign_text = ca > 0 and "~" or "+",
        sign_hl_group = ca > 0 and "DiffChange" or "DiffAdd",
        priority = 10,
      })
    end
    if ca > 0 then
      local virt = {}
      for i = sa, sa + ca - 1 do
        virt[#virt + 1] = { { "- " .. (sent[i] or ""), "DiffDelete" } }
      end
      local above = cb > 0 or sb == 0
      vim.api.nvim_buf_set_extmark(buf, ns_edit, above and math.max(sb - 1, 0) or sb - 1, 0, {
        virt_lines = virt,
        virt_lines_above = above,
      })
    end
  end
end

local function save_edit(buf)
  local v = views[buf]
  local file = store.edit_file(v.tid, v.att)
  local data = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") .. "\n"
  if data == table.concat(store.blob(v.att.sha256), "\n") .. "\n" then
    os.remove(file)
  else
    vim.fn.mkdir(vim.fs.dirname(file), "p")
    local f = assert(io.open(file, "wb"))
    f:write(data)
    f:close()
  end
  vim.bo[buf].modified = false
end

local function refresh_thread_views(tid)
  for buf, v in pairs(views) do
    if vim.api.nvim_buf_is_valid(buf) and v.tid == tid then
      if v.kind == "thread" then
        M.render_thread(buf)
      elseif v.kind == "attachment" then
        render_notes(buf)
      end
    end
  end
end

local function annotate(buf, l1, l2)
  local v = views[buf]
  vim.ui.select(store.labels, { prompt = "Why" }, function(label)
    if not label then
      return
    end
    local function save(text)
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local loc = v.att.type == "diff" and diff_loc(lines, l1, l2)
        or ((v.att.path or v.att.name) .. ":" .. l1 .. (l2 ~= l1 and ("-" .. l2) or ""))
      store.append(store.thread_file(v.tid), {
        kind = "annotation",
        from = "human",
        sha256 = v.att.sha256,
        attachment = v.att.name,
        line_start = l1,
        line_end = l2,
        quote = table.concat(vim.list_slice(lines, l1, math.min(l2, l1 + 2)), "\n"),
        loc = loc or (v.att.name .. ":" .. l1),
        label = label,
        blocking = store.is_blocking(label),
        text = text,
      })
      refresh_thread_views(v.tid)
    end
    if label == "looks-good" then
      save("")
    else
      vim.ui.input({ prompt = label .. ": " }, function(text)
        if text and text ~= "" then
          save(text)
        end
      end)
    end
  end)
end

local function note_at_cursor(buf)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  for _, n in ipairs(views[buf].notes or {}) do
    if row >= n.line_start and row <= n.line_end then
      return n
    end
  end
end

-- Winbar: the round's deliverables as tabs, the current one highlighted
local function workspace_winbar(buf)
  local v = views[buf]
  local t = store.thread(v.tid)
  local parts = {}
  local list = t.deliverables
  if not vim.tbl_contains(vim.tbl_map(function(a)
    return a.sha256
  end, list), v.att.sha256) then
    list = { v.att } -- an older round's file opened from the thread
  end
  for _, a in ipairs(list) do
    local cur = a.sha256 == v.att.sha256
    parts[#parts + 1] = (cur and "%#TabLineSel#" or "%#TabLine#") .. " " .. a.name:gsub("%%", "%%%%") .. " "
  end
  local state = {}
  if t.stage then
    state[#state + 1] = t.stage .. " r" .. t.round
  end
  if v.edited or (v.att.type == "diff" and #vim.tbl_filter(function(e)
    return e.sha256 == v.att.sha256
  end, store.edits(t)) > 0) then
    state[#state + 1] = "%#DiagnosticHint#✐ edited%*"
  end
  if store.changed_since_sent(v.att) then
    state[#state + 1] = "%#DiagnosticWarn#⚠ changed since sent%*"
  end
  local keys = v.att.type == "diff" and "<CR> CodeDiff  gR reset  ga note  ]d [d  gA gN gC gX  q rail"
    or "ga note  gp prev round  gR revert  ]d [d  gA gN gC gX  gr reply"
  return table.concat(parts, "") .. "%#WinBar#  " .. table.concat(state, " · ") .. "%=%#Comment#" .. keys .. " "
end

local function cycle_deliverable(buf, dir)
  local v = views[buf]
  local list = store.thread(v.tid).deliverables
  for i, a in ipairs(list) do
    if a.sha256 == v.att.sha256 then
      local nxt = list[((i - 1 + dir) % #list) + 1]
      return M.open_attachment(v.tid, nxt, true)
    end
  end
end

-- Previous round of the same deliverable vs this one, side by side in CodeDiff
local function compare_previous(buf)
  local v = views[buf]
  local prev = store.previous(store.thread(v.tid), v.att)
  if not prev then
    return vim.notify("cockpit: no previous round of " .. v.att.name, vim.log.levels.INFO)
  end
  local dir = store.path("review", v.tid, "rounds")
  vim.fn.mkdir(dir, "p")
  local a = ("%s/%s-%s"):format(dir, prev.sha256:sub(1, 8), prev.name)
  local b = ("%s/%s-%s"):format(dir, v.att.sha256:sub(1, 8), v.att.name)
  vim.fn.writefile(store.blob(prev.sha256), a)
  vim.fn.writefile(store.blob(v.att.sha256), b)
  vim.cmd("CodeDiff file " .. vim.fn.fnameescape(a) .. " " .. vim.fn.fnameescape(b))
end

local function attachment_buf(tid, att)
  local name = ("cockpit://inbox/%s/%s/%s"):format(tid, att.sha256:sub(1, 8), att.name)
  local is_diff = att.type == "diff"
  local ft = is_diff and "diff" or (vim.filetype.match({ filename = att.name }) or "text")
  local buf = find_buf(name)
  if buf and views[buf] then
    return buf
  end
  buf = scratch(name, ft, is_diff and "nofile" or "acwrite")
  views[buf] = { kind = "attachment", tid = tid, att = att }
  local edited = not is_diff and vim.fn.filereadable(store.edit_file(tid, att)) == 1
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, edited and vim.fn.readfile(store.edit_file(tid, att)) or store.blob(att.sha256))
  vim.bo[buf].modified = false
  vim.bo[buf].modifiable = not is_diff
  common_maps(buf, not is_diff)
  verdict_maps(buf, tid, "g")

  if is_diff then
    local review = require("cockpit.inbox.review")
    map(buf, "<CR>", function()
      review.open(tid, att)
    end, "Review in CodeDiff")
    map(buf, "gR", function()
      if vim.fn.confirm("Drop your edits to " .. att.name .. "?", "&Yes\n&No", 2) == 1 then
        review.reset(tid, att)
        M.refresh()
      end
    end, "Reset edits")
  else
    local group = vim.api.nvim_create_augroup("cockpit_edit_" .. buf, { clear = true })
    vim.api.nvim_create_autocmd("BufWriteCmd", {
      group = group,
      buffer = buf,
      callback = function()
        save_edit(buf)
        render_edits(buf)
        refresh_thread_views(tid)
      end,
    })
    vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
      group = group,
      buffer = buf,
      callback = function()
        save_edit(buf)
        render_edits(buf)
        if valid(ck.work) and vim.api.nvim_win_get_buf(ck.work) == buf then
          vim.wo[ck.work].winbar = workspace_winbar(buf)
        end
      end,
    })
    vim.api.nvim_create_autocmd("BufLeave", {
      group = group,
      buffer = buf,
      callback = function()
        refresh_thread_views(tid)
      end,
    })
    map(buf, "gp", function()
      compare_previous(buf)
    end, "Compare with previous round")
    map(buf, "gR", function()
      if vim.fn.confirm("Revert your edits to " .. att.name .. "?", "&Yes\n&No", 2) == 1 then
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, store.blob(att.sha256))
        save_edit(buf)
        render_edits(buf)
        M.refresh()
      end
    end, "Revert edits")
    map(buf, "gS", function()
      if not att.path or vim.fn.filereadable(att.path) == 0 then
        return vim.notify("cockpit: no current file to compare", vim.log.levels.WARN)
      end
      vim.cmd("CodeDiff file " .. vim.fn.fnameescape(att.path))
    end, "Sent vs current file")
  end

  map(buf, "ga", function()
    local r = vim.api.nvim_win_get_cursor(0)[1]
    annotate(buf, r, r)
  end, "Annotate line")
  map(buf, "ga", function()
    local l1, l2 = vim.fn.line("v"), vim.fn.line(".")
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
    annotate(buf, math.min(l1, l2), math.max(l1, l2))
  end, "Annotate selection", "x")
  map(buf, "gD", function()
    local n = note_at_cursor(buf)
    if n then
      store.append(store.thread_file(tid), { kind = "annotation_deleted", target = n.id })
      refresh_thread_views(tid)
    end
  end, "Delete note")
  for lhs, dir in pairs({ ["]a"] = 1, ["[a"] = -1 }) do
    map(buf, lhs, function()
      local row = vim.api.nvim_win_get_cursor(0)[1]
      local notes = views[buf].notes or {}
      for i = dir > 0 and 1 or #notes, dir > 0 and #notes or 1, dir do
        local l = notes[i].line_start
        if (dir > 0 and l > row) or (dir < 0 and l < row) then
          return vim.api.nvim_win_set_cursor(0, { l, 0 })
        end
      end
    end, dir > 0 and "Next note" or "Prev note")
  end
  map(buf, "]d", function()
    cycle_deliverable(buf, 1)
  end, "Next deliverable")
  map(buf, "[d", function()
    cycle_deliverable(buf, -1)
  end, "Prev deliverable")
  if is_diff then
    map(buf, "q", focus_rail, "Back to rail") -- editable buffers keep q for macros
  end
  return buf
end

-- Always lands in the cockpit's workspace window
function M.open_attachment(tid, att, focus)
  if not in_cockpit() then
    M.select(tid)
  end
  local buf = attachment_buf(tid, att)
  ck.last_att[tid] = att
  vim.api.nvim_win_set_buf(ck.work, buf)
  render_notes(buf)
  if att.type ~= "diff" then
    render_edits(buf)
  end
  vim.wo[ck.work].winbar = workspace_winbar(buf)
  if focus ~= false then
    vim.api.nvim_set_current_win(ck.work)
  end
end

---------------------------------------------------------------------------
-- Reply composer and send
---------------------------------------------------------------------------

local function collect_answers(t, d)
  local out = {}
  for _, q in ipairs(t.open_questions) do
    local picks = vim.tbl_keys(d.answers[q.key] or {})
    if #picks > 0 then
      out[#out + 1] = { question = q.text, answer = table.concat(picks, ", ") }
    end
  end
  return out
end

-- Sent rounds' buffers would otherwise keep showing (and re-saving) edits that already went out
local function drop_attachment_bufs(tid)
  for buf, v in pairs(views) do
    if v.kind == "attachment" and v.tid == tid and vim.api.nvim_buf_is_valid(buf) then
      local w = valid(ck.work) and vim.api.nvim_win_get_buf(ck.work) == buf
      pcall(vim.api.nvim_del_augroup_by_name, "cockpit_edit_" .. buf)
      if w then
        vim.api.nvim_win_set_buf(ck.work, placeholder())
      end
      views[buf] = nil
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
end

function M.send(tid)
  local t = store.thread(tid)
  local d = draft(tid)
  local text = vim.trim(d.text or "")
  local answers = collect_answers(t, d)
  local edits = store.edits(t)
  if text == "" and #t.drafts == 0 and #answers == 0 and #edits == 0 and not d.verdict then
    return vim.notify("cockpit: nothing to send", vim.log.levels.WARN)
  end
  if
    (d.verdict == "changes_requested" or d.verdict == "reject")
    and text == ""
    and #t.drafts == 0
    and #edits == 0
  then
    return vim.notify("cockpit: say what to change (reply text, notes or edits)", vim.log.levels.WARN)
  end
  local reply = store.append(store.thread_file(tid), {
    kind = "reply",
    from = "human",
    verdict = d.verdict,
    stage = t.stage,
    round = t.round,
    text = text,
    answers = answers,
    annotations = t.drafts,
    edits = #edits > 0 and edits or nil,
  })
  store.ledger(t, reply)
  store.clear_edits(t)
  drafts[tid] = nil
  local how = store.deliver(t)
  vim.notify(("Cockpit: sent%s · %s"):format(d.verdict and (" (" .. VERDICTS[d.verdict] .. ")") or "", how))
  local cbuf = find_buf("cockpit://inbox/" .. tid .. "/reply")
  vim.schedule(function()
    if cbuf then
      -- Drop the draft-saving autocmds first, or closing the composer resurrects the draft
      pcall(vim.api.nvim_del_augroup_by_name, "cockpit_inbox_reply_" .. cbuf)
      if vim.api.nvim_buf_is_valid(cbuf) then
        vim.api.nvim_buf_delete(cbuf, { force = true })
      end
      views[cbuf] = nil
    end
    drop_attachment_bufs(tid)
    if in_cockpit() and ck.tid == tid then
      M.select(tid)
    end
    M.refresh()
  end)
end

function M.quick_approve(tid)
  local t = store.thread(tid)
  local d = draft(tid)
  local extra = #t.drafts > 0 or #collect_answers(t, d) > 0 or #store.edits(t) > 0
  d.verdict = extra and "approve_with_notes" or "approve"
  M.send(tid)
end

function M.compose(tid, verdict)
  local d = draft(tid)
  d.verdict = verdict
  local name = "cockpit://inbox/" .. tid .. "/reply"
  local buf = scratch(name, "markdown", "acwrite")
  local w = win_for(buf)
  if not w then
    local tw = thread_win(tid)
    if tw then
      vim.api.nvim_set_current_win(tw)
    end
    vim.cmd("belowright 10split")
    w = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(w, buf)
  end
  vim.api.nvim_set_current_win(w)
  if not views[buf] then
    views[buf] = { kind = "composer", tid = tid }
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(d.text or "", "\n"))
    vim.bo[buf].modified = false
    local group = vim.api.nvim_create_augroup("cockpit_inbox_reply_" .. buf, { clear = true })
    local function save_draft()
      draft(tid).text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    end
    vim.api.nvim_create_autocmd("BufWriteCmd", {
      group = group,
      buffer = buf,
      callback = function()
        save_draft()
        vim.bo[buf].modified = false
        M.send(tid)
      end,
    })
    vim.api.nvim_create_autocmd({ "BufLeave", "BufHidden", "TextChanged", "InsertLeave" }, {
      group = group,
      buffer = buf,
      callback = save_draft,
    })
    vim.api.nvim_create_autocmd("BufWipeout", {
      group = group,
      buffer = buf,
      callback = function()
        views[buf] = nil
      end,
    })
  end
  local t = store.thread(tid)
  local edits = #store.edits(t)
  vim.wo[w].winbar = ("Reply · %s%s  ·  :w send  ·  :q keeps draft"):format(
    verdict and VERDICTS[verdict] or "no verdict",
    edits > 0 and (" · with " .. edits .. " edited deliverable" .. (edits > 1 and "s" or "")) or ""
  )
  vim.cmd("startinsert")
end

---------------------------------------------------------------------------
-- Board (manual cards; runs live in the rail)
---------------------------------------------------------------------------

function M.render_board(buf)
  local by_lane = {}
  local week = os.time() - 7 * 86400
  for _, c in ipairs(store.cards()) do
    if c.lane ~= "cancelled" and not (c.lane == "done" and c.ts < week) then
      by_lane[c.lane] = by_lane[c.lane] or {}
      table.insert(by_lane[c.lane], c)
    end
  end
  local lines = { "Board", "<CR> open thread  > < move  a add  x cancel  e note  i cockpit  R refresh  q close" }
  local marks, item_map = {}, {}
  for _, lane in ipairs(store.lanes) do
    local cards = by_lane[lane] or {}
    table.sort(cards, function(a, b)
      return a.ts > b.ts
    end)
    lines[#lines + 1] = ""
    lines[#lines + 1] = ("── %s (%d)%s"):format(LANE_NAMES[lane], #cards, lane == "done" and " · last 7 days" or "")
    marks[#marks + 1] = { #lines - 1, "Title" }
    for _, c in ipairs(cards) do
      local waiting = c.thread and (store.thread(c.thread) or {}).status == "needs_you"
      lines[#lines + 1] = ("  %s %-40s %-10s %4s  %s"):format(
        waiting and "✋" or "◆",
        trunc(c.title, 40),
        trunc(c.by, 10),
        ago(c.ts),
        c.owe and ("You: " .. c.owe) or (waiting and "Waiting on you") or trunc(c.note or "", 50)
      )
      item_map[#lines] = c
      if waiting or c.owe then
        marks[#marks + 1] = { #lines - 1, "DiagnosticWarn" }
      end
    end
  end
  set_lines(buf, lines)
  hl(buf, 0, 0, #lines[1], "Title")
  hl(buf, 1, 0, #lines[2], "Comment")
  for _, mk in ipairs(marks) do
    hl(buf, mk[1], 0, #lines[mk[1] + 1], mk[2])
  end
  views[buf].map = item_map
end

function M.board()
  local buf = scratch("cockpit://board", "cockpit-board")
  if not views[buf] then
    views[buf] = { kind = "board" }
    local function move(dir)
      local c = cursor_item(buf)
      if not c then
        return
      end
      local i = vim.fn.index(store.lanes, c.lane) + 1 + dir
      if store.lanes[i] then
        c.lane = store.lanes[i]
        c.owe = nil
        store.save_card(c)
        M.render_board(buf)
      end
    end
    map(buf, ">", function()
      move(1)
    end, "Move right")
    map(buf, "<", function()
      move(-1)
    end, "Move left")
    map(buf, "<CR>", function()
      local c = cursor_item(buf)
      if c and c.thread then
        M.open_thread(c.thread)
      end
    end, "Open thread")
    map(buf, "a", function()
      vim.ui.input({ prompt = "New card: " }, function(title)
        if title and title ~= "" then
          store.save_card({
            card = "c-" .. vim.fn.sha256(title .. os.time()):sub(1, 8),
            title = title,
            lane = "backlog",
          })
          M.render_board(buf)
        end
      end)
    end, "Add card")
    map(buf, "e", function()
      local c = cursor_item(buf)
      if c then
        vim.ui.input({ prompt = "Note: ", default = c.note }, function(note)
          if note then
            c.note = note
            store.save_card(c)
            M.render_board(buf)
          end
        end)
      end
    end, "Edit note")
    map(buf, "x", function()
      local c = cursor_item(buf)
      if c and vim.fn.confirm("Cancel card '" .. c.title .. "'?", "&Yes\n&No", 2) == 1 then
        c.lane = "cancelled"
        store.save_card(c)
        M.render_board(buf)
      end
    end, "Cancel card")
    map(buf, "i", M.open, "Cockpit")
    map(buf, "R", function()
      M.render_board(buf)
    end, "Refresh")
    map(buf, "q", "<cmd>bdelete<cr>", "Close")
  end
  vim.api.nvim_win_set_buf(0, buf)
  M.render_board(buf)
end

---------------------------------------------------------------------------
-- Agents (herdr)
---------------------------------------------------------------------------

function M.kill_agent(a)
  local label = ("Kill %s (%s)?"):format(a.target, a.status or "?")
  if vim.fn.confirm(label, "&Yes\n&No", 2) == 1 then
    local err = require("cockpit.herdr").kill(a.target)
    vim.notify(err and ("cockpit: kill failed — " .. err.message) or ("cockpit: killed " .. a.target))
  end
end

function M.spawn(project)
  local projects, herdr = require("cockpit.projects"), require("cockpit.herdr")
  local function go(name)
    vim.ui.input({ prompt = "First prompt (optional): " }, function(text)
      if text ~= nil then
        herdr.spawn(name, text)
      end
    end)
  end
  if type(project) == "string" and project ~= "" then
    return go(project)
  end
  local NEW = "+ new project"
  local names = vim.tbl_map(function(p)
    return p.name
  end, projects.list())
  names[#names + 1] = NEW
  vim.ui.select(names, { prompt = "Spawn into project" }, function(choice)
    if choice == NEW then
      projects.new(function(p)
        go(p.name)
      end)
    elseif choice then
      go(choice)
    end
  end)
end

function M.pick_agent()
  local herdr = require("cockpit.herdr")
  local list = vim.tbl_values(herdr.agents())
  if #list == 0 then
    return vim.notify("cockpit: no live herdr agents")
  end
  table.sort(list, function(a, b)
    return a.target < b.target
  end)
  vim.ui.select(list, {
    prompt = "Agent",
    format_item = function(a)
      return ("%s · %s · %s · %s"):format(a.target, a.project or "—", a.status or "?", a.title or "")
    end,
  }, function(a)
    if not a then
      return
    end
    vim.ui.select({ "attach", "interrupt", "kill", "prompt" }, { prompt = a.target }, function(action)
      if action == "attach" then
        herdr.attach(a.target)
      elseif action == "interrupt" then
        herdr.interrupt(a.target)
      elseif action == "kill" then
        M.kill_agent(a)
      elseif action == "prompt" then
        vim.ui.input({ prompt = a.target .. " ← " }, function(text)
          if text and text ~= "" then
            vim.notify("cockpit: " .. herdr.prompt(a.target, text))
          end
        end)
      end
    end)
  end)
end

function M.refresh_rail()
  for buf, v in pairs(views) do
    if v.kind == "rail" and vim.api.nvim_buf_is_valid(buf) then
      M.render_rail(buf)
    end
  end
end

function M.refresh()
  for buf, v in pairs(views) do
    if not vim.api.nvim_buf_is_valid(buf) then
      views[buf] = nil
    elseif v.kind == "rail" then
      M.render_rail(buf)
    elseif v.kind == "board" then
      M.render_board(buf)
    elseif v.kind == "thread" then
      M.render_thread(buf)
    elseif v.kind == "attachment" then
      render_notes(buf)
      if valid(ck.work) and vim.api.nvim_win_get_buf(ck.work) == buf then
        vim.wo[ck.work].winbar = workspace_winbar(buf)
      end
    end
  end
end

return M
