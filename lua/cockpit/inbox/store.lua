-- cockpit inbox store: reads/writes the JSONL shared with scripts/cockpit_inbox.py.
-- Threads are append-only event logs; all state (status, drafts, read) is derived.
local M = {}

M.root = vim.fn.expand(vim.env.COCKPIT_INBOX_DIR or "~/.cockpit/inbox")
M.cli = vim.fn.stdpath("config") .. "/scripts/cockpit_inbox.py"
M.lanes = { "backlog", "todo", "in_progress", "in_review", "done" }
-- Steer taxonomy from the cockpit spec (§8); labels not listed here are blocking
M.labels = {
  "looks-good",
  "bug",
  "question",
  "wrong-assumption",
  "missed-context",
  "missing-convention",
  "style",
  "scope-creep",
}
local NON_BLOCKING = { ["looks-good"] = true, question = true, style = true }

function M.path(...)
  return table.concat({ M.root, ... }, "/")
end

local function read_jsonl(file)
  local f = io.open(file, "r")
  if not f then
    return {}
  end
  local out = {}
  for line in f:lines() do
    if line ~= "" then
      local ok, ev = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
      if ok then
        out[#out + 1] = ev
      end
    end
  end
  f:close()
  return out
end

function M.append(file, ev)
  ev = vim.tbl_extend("keep", ev, {
    v = 1,
    at = os.date("%Y-%m-%dT%H:%M:%S%z"),
    ts = os.time(),
    id = vim.fn.sha256(tostring(vim.uv.hrtime()) .. math.random()):sub(1, 12),
  })
  vim.fn.mkdir(vim.fs.dirname(file), "p")
  local f = assert(io.open(file, "a"))
  f:write(vim.json.encode(ev) .. "\n")
  f:close()
  return ev
end

function M.thread_file(id)
  return M.path("threads", id .. ".jsonl")
end

function M.is_blocking(label)
  return not NON_BLOCKING[label]
end

function M.thread(id)
  local events = read_jsonl(M.thread_file(id))
  if #events == 0 then
    return nil
  end
  local t = { id = id, messages = {}, sent = {}, read_ts = 0, archived = false, last_ts = 0 }
  local notes, deleted, sent_ids, rounds = {}, {}, {}, {}
  for _, e in ipairs(events) do
    if e.kind == "message" then
      t.title = t.title or e.title
      t.project = t.project or e.project
      t.session = e.session or t.session
      t.pipeline = t.pipeline or e.pipeline
      t.stages = t.stages or e.stages
      if e.stage then
        rounds[e.stage] = (rounds[e.stage] or 0) + 1
        e.round = rounds[e.stage]
        t.stage, t.round = e.stage, e.round
      end
      t.messages[#t.messages + 1] = e
      t.last_ts = e.ts
    elseif e.kind == "reply" then
      t.messages[#t.messages + 1] = e
      t.last_ts = e.ts
      for _, n in ipairs(e.annotations or {}) do
        sent_ids[n.id] = true
        t.sent[#t.sent + 1] = n
      end
    elseif e.kind == "annotation" then
      notes[#notes + 1] = e
    elseif e.kind == "annotation_deleted" then
      deleted[e.target] = true
    elseif e.kind == "state" then
      if e.read ~= nil then
        t.read_ts = e.read and e.ts or 0
      end
      if e.archived ~= nil then
        t.archived = e.archived
      end
    end
  end
  t.drafts = vim.tbl_filter(function(n)
    return not deleted[n.id] and not sent_ids[n.id]
  end, notes)
  if t.stage then
    -- Stages seen but not declared (a pipeline that grew a stage) still show, in order of appearance
    t.stages = vim.deepcopy(t.stages or {})
    for _, m in ipairs(t.messages) do
      if m.stage and not vim.tbl_contains(t.stages, m.stage) then
        t.stages[#t.stages + 1] = m.stage
      end
    end
  end

  local last = t.messages[#t.messages]
  t.agent = t.session and t.session.agent or "agent"
  t.open_questions = {}
  if last and last.kind == "message" then
    -- Questions stay open until the next human reply, across consecutive agent messages
    for i = #t.messages, 1, -1 do
      local m = t.messages[i]
      if m.kind == "reply" then
        break
      end
      for _, q in ipairs(m.questions or {}) do
        table.insert(t.open_questions, 1, vim.tbl_extend("force", q, { key = m.id .. "/" .. q.id }))
      end
    end
  end
  if not last then
    t.status = "read"
  elseif last.kind == "reply" then
    t.status = "replied"
  elseif #t.open_questions > 0 or last.gate then
    t.status = "needs_you"
  elseif last.ts > t.read_ts then
    t.status = "unread"
  else
    t.status = "read"
  end
  local verdict = last and last.kind == "reply" and last.verdict
  t.done = t.stage ~= nil
    and t.stage == t.stages[#t.stages]
    and (verdict == "approve" or verdict == "approve_with_notes")
  t.deliverables = M.deliverables(t)
  return t
end

-- The latest round's attachments: what is under review right now
function M.deliverables(t)
  for i = #t.messages, 1, -1 do
    local m = t.messages[i]
    if m.kind == "message" and #(m.attachments or {}) > 0 then
      return m.attachments, m
    end
  end
  return {}, nil
end

-- The same deliverable (by name) from the previous round of the same stage, for "what changed"
function M.previous(t, att)
  local seen = false
  for i = #t.messages, 1, -1 do
    local m = t.messages[i]
    for _, a in ipairs(m.attachments or {}) do
      if a.sha256 == att.sha256 then
        seen = true
      elseif seen and a.name == att.name then
        return a
      end
    end
  end
end

-- One { stage, state } per pipeline stage: done · needs_you · working · todo
function M.strip(t)
  if not t.stage then
    return {}
  end
  local cur = vim.fn.index(t.stages, t.stage) + 1
  return vim.tbl_map(function(s)
    local i = vim.fn.index(t.stages, s) + 1
    local state = i < cur and "done"
      or i > cur and "todo"
      or t.done and "done"
      or t.status == "needs_you" and "needs_you"
      or "working"
    return { stage = s, state = state }
  end, t.stages)
end

---------------------------------------------------------------------------
-- Human edits: a deliverable is edited in place; the draft is the edited copy, the edit is
-- its diff against exactly what was sent (the blob), computed at send time.
---------------------------------------------------------------------------

function M.edit_file(tid, att)
  return M.path("edits", tid, att.sha256)
end

-- Codediff deliverables are reviewed as two directories: base/ (before) vs review/ (the
-- agent's version, editable); sent/ keeps the agent's version pristine to diff edits against.
function M.review_root(tid, att)
  return M.path("review", tid, att.sha256:sub(1, 12))
end

function M.patch_paths(lines)
  local out, seen = {}, {}
  for _, l in ipairs(lines) do
    local p = l:match("^%+%+%+ b/(.+)$") or l:match("^%-%-%- a/(.+)$")
    if p and not seen[p] then
      seen[p] = true
      out[#out + 1] = p
    end
  end
  return out
end

local function read(file)
  local f = io.open(file, "rb")
  if not f then
    return nil
  end
  local data = f:read("a")
  f:close()
  return data
end

local function unified(path, a, b)
  if a == b then
    return nil
  end
  local body = vim.diff(a or "", b or "", { result_type = "unified", ctxlen = 3 })
  return ("--- a/%s\n+++ b/%s\n%s"):format(path, path, body)
end

-- { attachment, sha256, path, patch } for every current deliverable the human changed
function M.edits(t)
  local out = {}
  for _, att in ipairs(t.deliverables) do
    local patch
    if att.type == "diff" then
      local root = M.review_root(t.id, att)
      local parts = {}
      for _, p in ipairs(M.patch_paths(M.blob(att.sha256))) do
        parts[#parts + 1] = unified(p, read(root .. "/sent/" .. p), read(root .. "/review/" .. p))
      end
      patch = #parts > 0 and table.concat(parts, "") or nil
    else
      local edited = read(M.edit_file(t.id, att))
      patch = edited and unified(att.name, table.concat(M.blob(att.sha256), "\n") .. "\n", edited)
    end
    if patch then
      out[#out + 1] = { attachment = att.name, sha256 = att.sha256, path = att.path, patch = patch }
    end
  end
  return out
end

-- After send the edits are in the reply; drop the drafts so the next round starts clean
function M.clear_edits(t)
  for _, att in ipairs(t.deliverables) do
    os.remove(M.edit_file(t.id, att))
    if att.type == "diff" then
      vim.fn.delete(M.review_root(t.id, att), "rf")
    end
  end
end

function M.threads()
  local out = {}
  for _, file in ipairs(vim.fn.glob(M.path("threads", "*.jsonl"), false, true)) do
    local t = M.thread(vim.fn.fnamemodify(file, ":t:r"))
    if t then
      out[#out + 1] = t
    end
  end
  return out
end

function M.blob(sha)
  local file = M.path("blobs", sha)
  return vim.fn.filereadable(file) == 1 and vim.fn.readfile(file) or { "(blob missing: " .. sha .. ")" }
end

function M.changed_since_sent(att)
  if not att.path then
    return false
  end
  local f = io.open(att.path, "rb")
  if not f then
    return true
  end
  local data = f:read("a")
  f:close()
  return vim.fn.sha256(data) ~= att.sha256
end

function M.cards()
  local latest, order = {}, {}
  for _, e in ipairs(read_jsonl(M.path("cards.jsonl"))) do
    if not latest[e.card] then
      order[#order + 1] = e.card
    end
    latest[e.card] = e
  end
  return vim.tbl_map(function(id)
    return latest[id]
  end, order)
end

function M.save_card(card)
  local snap = { kind = "card", by = "you" }
  for _, k in ipairs({ "card", "title", "lane", "thread", "note", "owe" }) do
    snap[k] = card[k]
  end
  return M.append(M.path("cards.jsonl"), snap)
end

-- The CLI touches waiting/<id> every 2s while an agent blocks in `wait`
function M.agent_waiting(id)
  local stat = vim.uv.fs_stat(M.path("waiting", id))
  return stat ~= nil and os.time() - stat.mtime.sec < 10
end

-- Blocked agents read the reply themselves; otherwise nudge the agent's tmux pane with a
-- one-line trigger (multi-line pastes would submit early) — Claude queues it if mid-turn.
function M.deliver(t)
  if M.agent_waiting(t.id) then
    return "agent was waiting and has it"
  end
  local msg = ("Inbox reply on thread %s. Run: python3 %s read %s --new"):format(t.id, M.cli, t.id)
  -- herdr agents: join on terminal_id (pane ids restart after a server restart), deliver with agent.prompt
  local hid = t.session and t.session.herdr
  if hid then
    local herdr = require("cockpit.herdr")
    local agent = herdr.by_terminal(hid.terminal_id)
    if agent then
      return herdr.prompt(agent.target, msg)
    end
  end
  local pane = t.session and t.session.tmux_pane
  if not pane and hid then
    return "agent offline; reply kept for the next reader"
  end
  if not pane then
    return "no agent pane; it can run `read " .. t.id .. " --new`"
  end
  -- list-panes, not display-message: display -t falls back to the current pane when the target is gone
  local panes = vim.system({ "tmux", "list-panes", "-a", "-F", "#{pane_id}" }, { text = true }):wait().stdout or ""
  if not vim.tbl_contains(vim.split(panes, "\n", { trimempty = true }), pane) then
    return "agent pane " .. pane .. " is gone; reply kept for the next reader"
  end
  vim.system({ "tmux", "send-keys", "-t", pane, "-l", msg }):wait()
  vim.system({ "tmux", "send-keys", "-t", pane, "Enter" }):wait()
  return "delivered to pane " .. pane
end

-- One line per steer: the why-tagged dataset the harness-improvement loop mines later
function M.ledger(t, reply)
  local base = { thread = t.id, title = t.title, project = t.project, agent = t.agent, reply = reply.id }
  local file = M.path("feedback.jsonl")
  base.stage, base.round = t.stage, t.round
  if reply.verdict then
    M.append(file, vim.tbl_extend("force", base, { kind = "verdict", verdict = reply.verdict }))
  end
  -- A direct edit is the strongest steer: it shows exactly what was wrong
  for _, ed in ipairs(reply.edits or {}) do
    M.append(
      file,
      vim.tbl_extend("force", base, { kind = "edit", verdict = reply.verdict, sha256 = ed.sha256, patch = ed.patch })
    )
  end
  for _, n in ipairs(reply.annotations or {}) do
    M.append(
      file,
      vim.tbl_extend("force", base, {
        kind = "steer",
        verdict = reply.verdict,
        label = n.label,
        blocking = n.blocking,
        loc = n.loc,
        sha256 = n.sha256,
        text = n.text,
      })
    )
  end
end

return M
