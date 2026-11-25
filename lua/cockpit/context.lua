-- Ask context: what the window you asked from is showing, as a short markdown block of references (paths, line
-- ranges, agent / thread ids) rather than contents — the receiver reads more only if it needs to.
-- gather({ buf, win, l1?, l2? }) -> { lines = string[], agent = herdr cache entry?, cwd = dir }
local M = {}

M.MAX_SELECTION = 40

local function trunc(s, n)
  s = (s or ""):gsub("%s+", " ")
  return vim.fn.strchars(s) > n and vim.fn.strcharpart(s, 0, n - 1) .. "…" or s
end

local function tilde(p)
  return p and vim.fn.fnamemodify(p, ":~") or "?"
end

local function git(dir, ...)
  local r = vim.system({ "git", "-C", dir, ... }, { text = true }):wait()
  return r.code == 0 and vim.trim(r.stdout or "") or nil
end

-- the live herdr agent running Claude session `sid`
local function agent_by_session(sid)
  for _, a in pairs(require("cockpit.herdr").agents()) do
    if sid and a.session_id == sid then
      return a
    end
  end
end

-- selection excerpt (or just the cursor line) as a fenced block, capped
local function excerpt(buf, l1, l2, ft, where)
  local n = l2 - l1 + 1
  local take = math.min(n, M.MAX_SELECTION)
  local out = { "", "```" .. (ft or ""), unpack(vim.api.nvim_buf_get_lines(buf, l1 - 1, l1 - 1 + take, false)) }
  out[#out + 1] = "```"
  if n > take then
    out[#out + 1] = ("(%d more selected lines: read %s)"):format(n - take, where)
  end
  return out
end

local function agent_lines(a, extra)
  local s = a.session or {}
  local out = {
    ("- agent: %s · %s · project %s · dir %s · session %s"):format(
      a.name or a.target or "?",
      a.status or "dead",
      a.project or "—",
      tilde(a.cwd or a.dir),
      a.session_id or (type(a.session) == "string" and a.session) or "?"
    ),
  }
  if type(s) == "table" and s.text then
    out[#out + 1] = "- its last words: " .. trunc(s.text, 200)
  end
  if extra then
    out[#out + 1] = extra
  end
  return out
end

local function thread_lines(t)
  local out = {
    ("- inbox thread: %s «%s» · %s · project %s"):format(
      t.id,
      trunc(t.title or "", 80),
      t.status,
      t.project or "—"
    ),
  }
  local last
  for i = #t.messages, 1, -1 do
    if t.messages[i].kind == "message" then
      last = t.messages[i]
      break
    end
  end
  if last and last.text then
    out[#out + 1] = "- last agent message: " .. trunc(last.text, 240)
  end
  for _, d in ipairs(t.deliverables or {}) do
    out[#out + 1] = ("- deliverable: %s (%s%s)"):format(d.name, d.type, d.path and (", " .. tilde(d.path)) or "")
  end
  return out
end

local function from_rail(buf, row)
  local node = require("cockpit.inbox.rail").node(buf, row)
  if not node then
    return { lines = { "- in the cockpit rail (header row)" } }
  end
  if node.kind == "agent" then
    local a = node.live and node.agent or vim.tbl_extend("force", node.rec or {}, { name = node.name })
    return { lines = agent_lines(a), agent = node.live and node.agent or nil, cwd = a.cwd or a.dir }
  elseif node.kind == "thread" then
    local t = node.thread
    local owner = agent_by_session(require("cockpit.inbox.tree").owner_key(t))
    local lines = thread_lines(t)
    if owner then
      vim.list_extend(lines, agent_lines(owner))
    end
    return { lines = lines, agent = owner, cwd = owner and owner.cwd }
  elseif node.kind == "project" or node.kind == "past" then
    local p = require("cockpit.projects").get(node.name or node.project)
    if p then
      return {
        lines = { "- cockpit project: " .. p.name .. " · dirs " .. table.concat(vim.tbl_map(tilde, p.repos), ", ") },
        cwd = p.repos[1],
      }
    end
  end
  return { lines = { "- in the cockpit rail" } }
end

local function from_file(buf, l1, l2, line)
  local path = vim.api.nvim_buf_get_name(buf)
  if path == "" then
    return { lines = { "- (unnamed buffer)" } }
  end
  local ft = vim.bo[buf].filetype
  local dir = vim.fs.dirname(path)
  local root = git(dir, "rev-parse", "--show-toplevel")
  local lines = {}
  local where = l1 and ("%s:%d-%d"):format(tilde(path), l1, l2) or ("%s:%d"):format(tilde(path), line)
  lines[#lines + 1] = ("- file: %s%s"):format(where, ft ~= "" and (" (" .. ft .. ")") or "")
  if root then
    local branch = git(root, "branch", "--show-current")
    lines[#lines + 1] = ("- repo: %s%s"):format(
      tilde(root),
      (branch and branch ~= "") and (" · branch " .. branch) or ""
    )
  end
  local project = require("cockpit.projects").containing(path)
  if project then
    lines[#lines + 1] = "- cockpit project: " .. project
  end
  if l1 then
    vim.list_extend(lines, excerpt(buf, l1, l2, ft, where))
  end
  return { lines = lines, cwd = root or dir }
end

-- opts: buf, win (default current), l1/l2 = visual line range
function M.gather(opts)
  opts = opts or {}
  local buf = opts.buf or vim.api.nvim_get_current_buf()
  local win = opts.win or vim.api.nvim_get_current_win()
  local line = vim.api.nvim_win_get_cursor(win)[1]
  local l1, l2 = opts.l1, opts.l2
  local name = vim.api.nvim_buf_get_name(buf)
  local res
  local ok_ui, ui = pcall(require, "cockpit.inbox.ui")
  local view = ok_ui and ui.view(buf)
  local cv = name:match("^cockpit://agent/[^/]+$") and require("cockpit.inbox.convo").view(buf)
  if view and view.kind == "rail" then
    res = from_rail(buf, line)
  elseif cv and cv.node then
    local n = cv.node
    local a = n.live and n.agent or vim.tbl_extend("force", n.rec or {}, { name = n.name })
    res = { lines = agent_lines(a, "- looking at its conversation"), agent = n.live and n.agent or nil, cwd = a.cwd }
  elseif view and view.tid then
    local t = require("cockpit.inbox.store").thread(view.tid)
    local lines = t and thread_lines(t) or { "- inbox thread " .. view.tid }
    local owner = t and agent_by_session(require("cockpit.inbox.tree").owner_key(t))
    if view.kind == "attachment" and view.att then
      local where = ("deliverable %s"):format(view.att.name)
      local at = l1 and ("lines %d-%d"):format(l1, l2) or ("line %d"):format(line)
      lines[#lines + 1] = ("- reviewing %s at %s%s"):format(
        where,
        at,
        view.att.path and (" (" .. tilde(view.att.path) .. ")") or ""
      )
      if l1 then
        vim.list_extend(lines, excerpt(buf, l1, l2, vim.bo[buf].filetype, where))
      end
    end
    if owner then
      vim.list_extend(lines, agent_lines(owner))
    end
    res = { lines = lines, agent = owner, cwd = owner and owner.cwd }
  elseif name:match("^%a+://") or vim.bo[buf].buftype ~= "" then
    res = { lines = { ("- buffer: %s (%s)"):format(name ~= "" and name or "[scratch]", vim.bo[buf].filetype) } }
  else
    res = from_file(buf, l1, l2, line)
  end
  res.cwd = res.cwd or vim.fn.getcwd()
  table.insert(res.lines, 1, "## Context")
  return res
end

return M
