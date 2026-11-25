-- Ask from anywhere: a float composer prefilled with context (cockpit.context), sent to one of
--   coordinator — the long-lived cockpit coordinator (default)
--   one-off     — headless `claude -p` (profile `ask`), answer streamed into ~/.cockpit/asks/<id>.md
--   fork        — a one-off that resumes the context agent's session with --fork-session: its whole conversation,
--                 without adding to it
-- One-offs are read-only (Read/Grep/Glob + Exa) and can open files in this nvim through cockpit-ctl.
local util = require("cockpit.inbox.util")
local float = require("cockpit.inbox.float")
local M = {}

M.DIR = vim.fn.expand(vim.env.COCKPIT_ASKS_DIR or "~/.cockpit/asks")
local CONTEXT_NOTE = "<!-- context below: edit or delete it, it is sent as-is -->"

local running = {} -- path -> vim.SystemObj

local function ctl()
  return require("cockpit.coordinator").CTL
end

function M.tools()
  return {
    "Read",
    "Grep",
    "Glob",
    "Bash(" .. ctl() .. " open:*)",
    "Bash(" .. ctl() .. " bridge:*)",
    "mcp__exa__web_search_exa",
    "mcp__exa__web_fetch_exa",
  }
end

local function preamble()
  return (
    "You are a one-off assistant: answer, then you're done — nobody replies in this session. Be concise. "
    .. "You can't edit files. The engineer is in Neovim: to show them code, open it there with `%s open <file> [line]` "
    .. "(also `%s bridge open_many|mark|harpoon_add|scoped_grep …`) rather than quoting long passages.\n\n"
  ):format(ctl(), ctl())
end

-- claude argv for a one-off. spec: fork (herdr agent with session_id) | resume (session id)
function M.argv(spec)
  local argv = { "claude", "-p", "--output-format", "stream-json", "--verbose" }
  vim.list_extend(argv, require("cockpit.profiles").args("ask"))
  if spec.resume then
    vim.list_extend(argv, { "--resume", spec.resume })
  elseif spec.fork then
    vim.list_extend(argv, { "--resume", spec.fork.session_id, "--fork-session" })
  end
  argv[#argv + 1] = "--allowedTools"
  vim.list_extend(argv, M.tools()) -- variadic: must stay last (the prompt goes on stdin)
  return argv
end

-- a one-off is nobody's herdr agent: no herdr / inbox hooks, no tmux; the bridge talks to this nvim
local function env()
  local e = {}
  for k, v in pairs(vim.fn.environ()) do
    if not k:match("^HERDR_") and k ~= "TMUX" and k ~= "TMUX_PANE" then
      e[k] = v
    end
  end
  e.NVIM_LISTEN_ADDRESS = vim.v.servername
  e.COCKPIT_INBOX_HOOK = "0"
  e.COCKPIT_ASK = "1"
  return e
end

local function append(path, text)
  local f = io.open(path, "a")
  if f then
    f:write(text)
    f:close()
  end
  local buf = util.find_buf("cockpit://ask/" .. vim.fn.fnamemodify(path, ":t:r"))
  if buf and vim.api.nvim_buf_is_valid(buf) then
    M.load(buf, path)
  end
end

local function title_of(path)
  local f = io.open(path, "r")
  local first = f and f:read("*l") or ""
  if f then
    f:close()
  end
  return (first:gsub("^#%s*", ""))
end

local function tool_line(b)
  local i = b.input or {}
  local what = i.file_path or i.path or i.pattern or i.command or i.query or i.url or ""
  return ("> 🔧 %s %s\n\n"):format(b.name, util.trunc(tostring(what), 100))
end

-- Run claude for `path` (already holding the question); stream its answer into the file
local function start(path, argv, prompt, cwd)
  local pending, got_result = "", false
  local function handle(line)
    local ok, ev = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
    if not ok or type(ev) ~= "table" then
      return
    end
    if ev.type == "assistant" and ev.message then
      for _, b in ipairs(ev.message.content or {}) do
        if b.type == "text" and vim.trim(b.text or "") ~= "" then
          append(path, vim.trim(b.text) .. "\n\n")
        elseif b.type == "tool_use" then
          append(path, tool_line(b))
        end
      end
    elseif ev.type == "result" then
      got_result = true
      append(
        path,
        ("<!-- session: %s · cost: $%.2f · %ds -->\n"):format(
          ev.session_id or "",
          ev.total_cost_usd or 0,
          math.floor((ev.duration_ms or 0) / 1000)
        )
      )
      local what = ev.is_error and "✗" or "✓"
      vim.notify(("Ask %s %s — <leader>kK"):format(what, title_of(path)))
    end
  end
  running[path] = vim.system(argv, {
    cwd = cwd and vim.fn.isdirectory(cwd) == 1 and cwd or nil,
    env = env(),
    clear_env = true,
    stdin = prompt,
    text = true,
    stdout = function(_, data)
      if not data then
        return
      end
      pending = pending .. data
      local lines = {}
      for l in pending:gmatch("([^\n]*)\n") do
        lines[#lines + 1] = l
      end
      pending = pending:match("[^\n]*$")
      vim.schedule(function()
        for _, l in ipairs(lines) do
          handle(l)
        end
      end)
    end,
  }, function(res)
    vim.schedule(function()
      running[path] = nil
      if not got_result then
        local why = res.signal ~= 0 and "cancelled" or ("failed: " .. vim.trim(res.stderr or ""):sub(1, 400))
        append(path, "**" .. why .. "**\n")
        vim.notify("Ask ✗ " .. title_of(path) .. " — " .. why, vim.log.levels.WARN)
      end
    end)
  end)
end

-- New one-off. spec: question, context (string), fork? (herdr agent), cwd?
function M.run(spec)
  vim.fn.mkdir(M.DIR, "p")
  local first = vim.split(vim.trim(spec.question), "\n")[1]
  local title = util.trunc(first, 80)
  local naming = require("cockpit.naming")
  local path = ("%s/%s-%s.md"):format(M.DIR, os.date("%Y%m%d-%H%M%S"), naming.slug(title, 40))
  local target = spec.fork and ("fork " .. (spec.fork.name or spec.fork.target)) or "one-off"
  local head = {
    "# " .. title,
    "",
    ("- asked: %s · via: composer · target: %s · cwd: %s"):format(
      os.date("%Y-%m-%d %H:%M"),
      target,
      vim.fn.fnamemodify(spec.cwd or vim.fn.getcwd(), ":~")
    ),
    "",
    "## Question",
    "",
    vim.trim(spec.question),
    "",
  }
  if spec.context and vim.trim(spec.context) ~= "" then
    vim.list_extend(head, { vim.trim(spec.context), "" })
  end
  vim.list_extend(head, { "## Answer", "", "" })
  vim.fn.writefile(vim.split(table.concat(head, "\n"), "\n"), path) -- writefile turns embedded \n into NUL
  start(path, M.argv(spec), preamble() .. vim.trim(spec.question) .. "\n\n" .. (spec.context or ""), spec.cwd)
  vim.notify("Ask → " .. target .. ": " .. title)
  return path
end

local function session_of(path)
  local sid
  for _, l in ipairs(vim.fn.readfile(path)) do
    sid = l:match("^<!%-%- session: ([%w-]+)") or sid
  end
  return sid
end

-- Continue a finished one-off in its own session; the answer appends to the same file
function M.follow_up(path, question)
  local sid = session_of(path)
  if not sid then
    return vim.notify("cockpit: that ask has no session yet (still running?)", vim.log.levels.WARN)
  end
  append(path, "\n## Follow-up\n\n" .. vim.trim(question) .. "\n\n### Answer\n\n")
  start(path, M.argv({ resume = sid }), question, nil)
end

---------------------------------------------------------------------------
-- Answer buffer + history
---------------------------------------------------------------------------

function M.load(buf, path)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.fn.readfile(path))
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  for _, w in ipairs(vim.fn.win_findbuf(buf)) do
    if running[path] then -- follow the tail while it streams
      vim.api.nvim_win_set_cursor(w, { vim.api.nvim_buf_line_count(buf), 0 })
    end
  end
end

function M.open_result(path)
  local buf = util.scratch("cockpit://ask/" .. vim.fn.fnamemodify(path, ":t:r"), "markdown")
  M.load(buf, path)
  if not vim.b[buf].cockpit_ask then
    vim.b[buf].cockpit_ask = true
    util.map(buf, "q", function()
      vim.api.nvim_win_close(0, true)
    end, "Close")
    util.map(buf, "r", function()
      vim.ui.input({ prompt = "Follow-up: " }, function(q)
        if q and vim.trim(q) ~= "" then
          M.follow_up(path, q)
        end
      end)
    end, "Follow-up question")
    util.map(buf, ">", function()
      require("cockpit.coordinator").send(
        ("[cockpit] A one-off answered a question; read %s and note anything worth keeping in your scratchpad."):format(
          vim.fn.fnamemodify(path, ":~")
        )
      )
    end, "Hand to the coordinator")
    util.map(buf, "x", function()
      if running[path] then
        running[path]:kill("sigterm")
      end
    end, "Cancel while running")
  end
  float.open(buf, {
    title = "Ask · " .. util.trunc(title_of(path), 60),
    footer = "r follow-up · > coordinator · x cancel · q close",
    width = math.min(120, vim.o.columns - 6),
    height = vim.o.lines - 8,
  })
end

function M.pick()
  local files = vim.fn.glob(M.DIR .. "/*.md", false, true)
  table.sort(files, function(a, b)
    return a > b
  end)
  files = vim.list_slice(files, 1, 50)
  if #files == 0 then
    return vim.notify("cockpit: no asks yet — <leader>kk")
  end
  vim.ui.select(files, {
    prompt = "Asks",
    format_item = function(p)
      local stamp = vim.fn.fnamemodify(p, ":t"):match("^(%d+%-%d%d%d%d)")
      return ("%s %s  %s"):format(running[p] and "⟳" or " ", stamp or "", title_of(p))
    end,
  }, function(p)
    if p then
      M.open_result(p)
    end
  end)
end

---------------------------------------------------------------------------
-- Composer
---------------------------------------------------------------------------

local function targets(ctx)
  local t = { "coordinator", "one-off" }
  if ctx.agent and ctx.agent.session_id then
    t[#t + 1] = "fork"
  end
  return t
end

local function label(st)
  if st.target == "fork" then
    return "fork " .. (st.ctx.agent.name or st.ctx.agent.target)
  end
  return st.target
end

-- question = everything above "## Context"; context = that heading and below (the note line dropped)
function M.split(lines)
  local q, c, in_ctx = {}, {}, false
  for _, l in ipairs(lines) do
    if l == CONTEXT_NOTE then -- luacheck: ignore 542
    elseif l == "## Context" then
      in_ctx = true
      c[#c + 1] = l
    elseif in_ctx then
      c[#c + 1] = l
    else
      q[#q + 1] = l
    end
  end
  return vim.trim(table.concat(q, "\n")), vim.trim(table.concat(c, "\n"))
end

-- opts: l1/l2 visual range (from the keymap)
function M.compose(opts)
  local ctx = require("cockpit.context").gather(opts)
  local st = { target = "coordinator", ctx = ctx }
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "cockpit://ask/new-" .. buf)
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].filetype = "acwrite", "wipe", "markdown"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.list_extend({ "", "", CONTEXT_NOTE }, ctx.lines))
  vim.bo[buf].modified = false
  local footer = ":w send · <C-t> target · q cancel"
  local win = float.open(buf, { title = "Ask → " .. label(st), footer = footer })
  local function cycle()
    local list = targets(ctx)
    local i = 1
    for k, v in ipairs(list) do
      if v == st.target then
        i = k
      end
    end
    st.target = list[i % #list + 1]
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_config(win, { title = " Ask → " .. label(st) .. " ", title_pos = "center" })
    end
  end
  vim.keymap.set({ "n", "i" }, "<C-t>", cycle, { buffer = buf, desc = "Cycle ask target" })
  util.map(buf, "q", function()
    vim.api.nvim_win_close(0, true)
  end, "Cancel")
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      local question, context = M.split(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      if question == "" then
        return vim.notify("cockpit: write the question above the context", vim.log.levels.WARN)
      end
      vim.bo[buf].modified = false
      vim.schedule(function()
        pcall(vim.api.nvim_win_close, win, true)
      end)
      if st.target == "coordinator" then
        require("cockpit.coordinator").send(question .. (context ~= "" and ("\n\n" .. context) or ""))
      else
        M.run({
          question = question,
          context = context,
          fork = st.target == "fork" and ctx.agent or nil,
          cwd = (st.target == "fork" and ctx.agent.cwd) or ctx.cwd,
        })
      end
    end,
  })
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  vim.cmd("startinsert")
end

return M
