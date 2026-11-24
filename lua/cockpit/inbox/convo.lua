-- Agent conversation view: the agent's Claude transcript(s) with its inbox posts and your replies
-- interleaved, plus a chat composer. Opens for any rail agent — live or dead, with or without threads.
-- Shown in the cockpit's bottom (thread) window; ui.select_agent owns the window placement.
local store = require("cockpit.inbox.store")
local util = require("cockpit.inbox.util")
local transcript = require("cockpit.transcript")
local float = require("cockpit.inbox.float")
local M = {}

local views = {} -- buf -> { tid, node, key, map }
local drafts = {} -- agent key (rail "a:<akey>": Claude session id) -> chat draft text
local VERDICTS = {
  approve = "approved",
  approve_with_notes = "approved with notes",
  changes_requested = "changes requested",
  reject = "rejected",
}

local function ui()
  return require("cockpit.inbox.ui")
end

-- freshest rail node for this agent (the rail rebuilds its tree every render); else the one we opened with
local function node_of(v)
  local rail, rb = require("cockpit.inbox.rail"), ui().rail_buf()
  local row = rail.row(rb, "a:" .. v.tid)
  local n = row and rail.node(rb, row)
  if n and n.kind == "agent" then
    v.node = n
  end
  return v.node
end

-- Claude session ids, oldest first: registry history, the live one, and session-<sid8> thread ids
local function session_ids(node, threads)
  local ids, seen = {}, {}
  local function add(sid)
    if sid and sid ~= "" and not seen[sid] then
      for s in pairs(seen) do -- an 8-char prefix and its full id are the same session
        if s:sub(1, 8) == sid:sub(1, 8) then
          return
        end
      end
      seen[sid] = true
      ids[#ids + 1] = sid
    end
  end
  local rec, a = node.rec or {}, node.agent or {}
  for _, s in ipairs(rec.sessions or {}) do
    add(s)
  end
  add(rec.session)
  add(a.session_id)
  add(a.source == "session" and a.session and a.session.session_id or nil)
  for _, t in ipairs(threads) do
    add(t.id:match("^session%-(%x+)$"))
  end
  return ids
end

-- threads of the agent whose rail key is "a:<akey>": by Claude session; a pre-session agent (akey = its terminal) or
-- a seat's "earlier session" row (old:<terminal>) owns its seat's unattributed threads
local function owned_threads(akey)
  local tree = require("cockpit.inbox.tree")
  local seat = akey:match("^old:(.+)$") or akey
  return vim.tbl_filter(function(t)
    local k = tree.owner_key(t)
    if k then
      return k == akey
    end
    local o = t.owner and t.owner.herdr
    return o ~= nil and o.terminal_id == seat
  end, store.threads())
end

-- inbox events as conversation items
local function inbox_items(threads)
  local out = {}
  for _, t in ipairs(threads) do
    for _, m in ipairs(t.messages) do
      out[#out + 1] = { ts = m.ts or 0, inbox = true, thread = t, msg = m }
    end
  end
  return out
end

function M.render(buf, opened)
  local v = views[buf]
  v.first = v.first or opened
  local node = node_of(v)
  local threads = owned_threads(v.tid)
  local sids = session_ids(node, threads)
  local tpaths, tsids = {}, {}
  for _, sid in ipairs(sids) do
    local path = transcript.find(sid)
    if path then
      tpaths[#tpaths + 1], tsids[#tsids + 1] = path, sid
    end
  end
  local key = table.concat({ transcript.key(tpaths), node.status or "", #threads }, "|")
  for _, t in ipairs(threads) do
    key = key .. "|" .. (t.last_ts or 0) .. t.status
  end
  if key == v.key then
    if opened then
      vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(buf), 0 })
      v.first = false
    end
    return
  end
  v.key = key

  local items, seq = {}, 0
  for i, p in ipairs(tpaths) do
    local entries = transcript.entries(p)
    if #tpaths > 1 and entries[1] then
      seq = seq + 1
      items[#items + 1] =
        { ts = entries[1].ts, seq = seq, divider = ("session %d · %s"):format(i, tsids[i]:sub(1, 8)) }
    end
    for _, e in ipairs(entries) do
      seq = seq + 1
      items[#items + 1] = vim.tbl_extend("keep", { seq = seq }, e)
    end
  end
  for _, it in ipairs(inbox_items(threads)) do
    seq = seq + 1
    it.seq = seq
    items[#items + 1] = it
  end
  table.sort(items, function(a, b)
    if a.ts ~= b.ts then
      return a.ts < b.ts
    end
    return a.seq < b.seq
  end)

  local a = node.agent or {}
  local lines, marks, map = {}, {}, {}
  local function line(text, group)
    lines[#lines + 1] = text
    if group then
      marks[#marks + 1] = { #lines - 1, 0, #text, group }
    end
  end
  local g = util.AGENT[node.status] or util.AGENT.unknown
  line("# " .. (node.name or v.tid), "Title")
  lines[#lines + 1] = util.segs(#lines, {
    { ((node.rec and node.rec.project) or a.project or "?") .. " · ", "Comment" },
    { g[1] .. " " .. (node.status or "?"), g[2] },
    { a.title and (" · " .. a.title) or "", "Comment" },
  }, marks)
  line(
    node.live and "r chat · <CR> open post · gt focus in herdr · gT attach · i interrupt · q rail"
      or "dead agent: read-only · <CR> open post · q rail",
    "Comment"
  )
  if #sids == 0 then
    line("")
    line("(no Claude session id known for this agent — its transcript can't be located)", "DiagnosticWarn")
  elseif #tpaths == 0 then
    line("")
    line("(no transcript yet — Claude writes it on the first message)", "Comment")
  end

  local last_role
  for _, it in ipairs(items) do
    if it.divider then
      line("")
      line("──── " .. it.divider .. " ────", "Comment")
      last_role = nil
    elseif it.inbox then
      local t, m = it.thread, it.msg
      if m.kind == "message" then
        local extra = {}
        if #(m.attachments or {}) > 0 then
          extra[#extra + 1] = "📎" .. #m.attachments
        end
        if #(m.questions or {}) > 0 then
          extra[#extra + 1] = "?" .. #m.questions
        end
        if m.gate then
          extra[#extra + 1] = "⚑ gate"
        end
        line("")
        local verb = m == t.messages[1] and "posted" or "update"
        line(
          ("📮 %s · %s%s%s"):format(
            verb,
            t.title or t.id,
            #extra > 0 and (" · " .. table.concat(extra, " ")) or "",
            t.archived and " · archived" or ""
          ),
          "Directory"
        )
        map[#lines] = t.id
        local first = vim.split(vim.trim(m.text or ""), "\n")[1]
        if first and first ~= "" then
          line("   " .. util.trunc(first, 160), "Comment")
          map[#lines] = t.id
        end
      elseif m.kind == "reply" then
        line("")
        line(
          ("↩ you replied%s · %s"):format(m.verdict and (" (" .. VERDICTS[m.verdict] .. ")") or "", t.title or t.id),
          "String"
        )
        map[#lines] = t.id
      end
      last_role = nil
    else
      if it.role ~= last_role or (it.role == "user" and not it.tool) then
        line("")
        if it.role == "user" then
          line("## you · " .. util.ago(it.ts) .. " ago", "String")
        else
          line(("## %s · %s ago"):format(node.name or "agent", util.ago(it.ts)), "Function")
        end
        last_role = it.role
      end
      if it.command then
        line("› " .. it.command, "Special")
      elseif it.tool then
        line("  ▸ " .. it.tool, "Comment")
      else
        vim.list_extend(lines, vim.split(it.text, "\n"))
      end
    end
  end

  -- follow the tail: windows whose cursor sits on the last line stay there
  local follow = {}
  for _, w in ipairs(vim.fn.win_findbuf(buf)) do
    local n = vim.api.nvim_buf_line_count(buf)
    if v.first or vim.api.nvim_win_get_cursor(w)[1] >= n then
      follow[#follow + 1] = w
    end
  end
  v.first = false
  util.set_lines(buf, lines)
  for _, mk in ipairs(marks) do
    util.hl(buf, mk[1], mk[2], mk[3], mk[4])
  end
  v.map = map
  for _, w in ipairs(follow) do
    vim.api.nvim_win_set_cursor(w, { #lines, 0 })
  end
end

function M.compose(tid)
  local v
  for _, view in pairs(views) do
    if view.tid == tid then
      v = view
    end
  end
  local node = v and node_of(v)
  if not (node and node.live) then
    return vim.notify(
      "cockpit: " .. ((node and node.name) or tid) .. " isn't running — nothing to chat with",
      vim.log.levels.WARN
    )
  end
  if node.agent.source == "session" then
    return vim.notify(
      "cockpit: " .. node.name .. " runs in a tmux pane, not herdr — gt to go there",
      vim.log.levels.WARN
    )
  end
  local name = "cockpit://agent/" .. tid .. "/chat"
  local buf = util.scratch(name, "markdown", "acwrite")
  if not vim.b[buf].cockpit_chat then
    vim.b[buf].cockpit_chat = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(drafts[tid] or "", "\n"))
    vim.bo[buf].modified = false
    local group = vim.api.nvim_create_augroup("cockpit_chat_" .. buf, { clear = true })
    local function save()
      drafts[tid] = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    end
    vim.api.nvim_create_autocmd(
      { "BufLeave", "TextChanged", "InsertLeave" },
      { group = group, buffer = buf, callback = save }
    )
    vim.api.nvim_create_autocmd("BufWriteCmd", {
      group = group,
      buffer = buf,
      callback = function()
        save()
        local text = vim.trim(drafts[tid] or "")
        if text == "" then
          return vim.notify("cockpit: nothing to send", vim.log.levels.WARN)
        end
        local target = node_of(v).agent.target
        vim.notify("cockpit: " .. require("cockpit.herdr").prompt(target, text))
        drafts[tid] = nil
        vim.bo[buf].modified = false
        vim.api.nvim_del_augroup_by_id(group)
        vim.schedule(function()
          pcall(vim.api.nvim_buf_delete, buf, { force = true })
          vim.defer_fn(M.refresh, 1500)
        end)
      end,
    })
    util.map(buf, "q", function()
      vim.api.nvim_win_close(0, true)
    end, "Close (keeps draft)")
  end
  float.open(buf, { title = "Chat · " .. node.name, footer = ":w send · q keep draft" })
  vim.cmd("startinsert")
end

-- the conversation buffer for an agent (terminal id), created on first use
function M.buf(tid, node)
  local buf = util.scratch("cockpit://agent/" .. tid, "markdown")
  if views[buf] then
    views[buf].node = node or views[buf].node
    return buf
  end
  views[buf] = { tid = tid, node = node, first = true, map = {} }
  local map = util.map
  map(buf, "r", function()
    M.compose(tid)
  end, "Chat with agent")
  map(buf, "<CR>", function()
    local t = views[buf].map[vim.api.nvim_win_get_cursor(0)[1]]
    if t then
      ui().select(t, nil, { open_diff = true })
    end
  end, "Open inbox post")
  local function live_herdr(fn)
    return function()
      local n = node_of(views[buf])
      if not (n and n.live) then
        return vim.notify("cockpit: agent isn't running", vim.log.levels.WARN)
      end
      local herdr, sessions = require("cockpit.herdr"), require("cockpit.sessions")
      fn(n, herdr, sessions, n.agent.source == "session")
    end
  end
  map(
    buf,
    "gt",
    live_herdr(function(n, herdr, sessions, tmux)
      return tmux and sessions.attach(n.agent.pane_id) or herdr.focus(n.agent.target)
    end),
    "Focus agent in herdr"
  )
  map(
    buf,
    "gT",
    live_herdr(function(n, herdr, sessions, tmux)
      return tmux and sessions.attach(n.agent.pane_id) or herdr.attach(n.agent.target)
    end),
    "Attach to agent (tmux)"
  )
  map(
    buf,
    "i",
    live_herdr(function(n, herdr, sessions, tmux)
      return tmux and sessions.interrupt(n.agent.pane_id) or herdr.interrupt(n.agent.target)
    end),
    "Interrupt agent"
  )
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    callback = function()
      views[buf] = nil
    end,
  })
  return buf
end

-- re-render visible conversations (cheap when nothing changed: keyed on transcript size/mtime)
function M.refresh()
  for buf, _ in pairs(views) do
    if vim.api.nvim_buf_is_valid(buf) and #vim.fn.win_findbuf(buf) > 0 then
      M.render(buf)
    end
  end
end

return M
