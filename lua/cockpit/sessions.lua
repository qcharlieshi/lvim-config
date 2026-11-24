-- cockpit ↔ hand-started Claude Code sessions (not owned by herdr). Read-only discovery from files
-- Claude Code already writes:
--   ~/.claude/sessions/<pid>.json   name, cwd, tmux pane, status (idle|busy|waiting), waitingFor
--   ~/.cockpit/status/<sid>.json    statusline input (claude-statusline.sh): model, context_window
--   transcript jsonl                last assistant text (+ model/usage fallback when no status file yet)
-- Only sessions with a tmux pane are listed: herdr strips TMUX from its panes, so its agents never
-- show up twice.
local M = {}

local SESSIONS = vim.fn.expand("~/.claude/sessions")
local STATUS = vim.fn.expand(vim.env.COCKPIT_STATUS_DIR or "~/.cockpit/status")
local TAIL = 256 * 1024

local tcache = {} -- transcript path -> { key = mtime:size, info }

local function read_json(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  local ok, v = pcall(vim.json.decode, s, { luanil = { object = true, array = true } })
  return ok and type(v) == "table" and v or nil
end

local function alive(pid)
  return pid and vim.uv.kill(pid, 0) == 0
end

local function transcript_path(cwd, sid)
  return vim.fn.expand("~/.claude/projects/") .. cwd:gsub("[^%w]", "-") .. "/" .. sid .. ".jsonl"
end

-- last assistant text + model/usage from the transcript tail; cached by mtime:size
local function transcript(path)
  local st = path and vim.uv.fs_stat(path)
  if not st then
    return {}
  end
  local key = st.mtime.sec .. ":" .. st.size
  local c = tcache[path]
  if c and c.key == key then
    return c.info
  end
  local info = {}
  local f = io.open(path, "r")
  if f then
    f:seek("set", math.max(0, st.size - TAIL))
    local lines = vim.split(f:read("*a") or "", "\n", { plain = true })
    f:close()
    for i = #lines, 2, -1 do -- line 1 may be cut mid-record
      local l = lines[i]
      if l:find('"type":"assistant"', 1, true) then
        local ok, e = pcall(vim.json.decode, l, { luanil = { object = true, array = true } })
        local m = ok and type(e) == "table" and e.message
        if m then
          info.model = info.model or m.model
          if not info.tokens and m.usage then
            local u = m.usage
            info.tokens = (u.input_tokens or 0)
              + (u.cache_read_input_tokens or 0)
              + (u.cache_creation_input_tokens or 0)
          end
          if not info.text then
            for j = #(m.content or {}), 1, -1 do
              local b = m.content[j]
              if b.type == "text" and vim.trim(b.text or "") ~= "" then
                info.text = vim.trim(b.text)
                break
              end
            end
          end
          if info.text and info.tokens then
            break
          end
        end
      end
    end
  end
  tcache[path] = { key = key, info = info }
  return info
end

-- "claude-opus-5-5" -> "Opus 5.5" (same shape as the statusline's display_name)
local function short_model(id)
  if not id then
    return nil
  end
  local s = id:gsub("^claude%-", ""):gsub("%-(%d+)%-(%d+)", " %1.%2"):gsub("%-", " ")
  return (s:gsub("^%l", string.upper))
end

-- markdown → plain one-liner for the rail: [text](url) → text, drop ** and `
local function plain(t)
  if not t then
    return nil
  end
  t = t:gsub("%[([^%]]+)%]%([^)]*%)", "%1"):gsub("%*%*", ""):gsub("`", ""):gsub("^#+%s*", "")
  return t
end

-- pane id -> title Claude sets (its session topic), minus the leading status glyph
local function pane_titles()
  local out = {}
  for _, l in ipairs(vim.fn.systemlist({ "tmux", "list-panes", "-a", "-F", "#{pane_id}\t#{pane_title}" })) do
    local id, title = l:match("^(%%%d+)\t(.*)$")
    if id then
      title = vim.trim(title:gsub("^[^%w]+", ""))
      if title ~= "" and title ~= "Claude Code" then
        out[id] = title
      end
    end
  end
  return out
end

-- Live sessions: list of { pid, session_id, name, cwd, pane, status, waiting, ts, model, ctx_pct, tokens, ctx_size, text }
function M.list()
  local out, titles = {}, nil
  for _, path in ipairs(vim.fn.glob(SESSIONS .. "/*.json", false, true)) do
    local s = read_json(path)
    local pane = s and s.tmux and s.tmux:match("(%%%d+)$")
    if s and pane and alive(s.pid) then
      local st = read_json(STATUS .. "/" .. s.sessionId .. ".json") or {}
      local tpath = st.transcript_path or transcript_path(s.cwd or "", s.sessionId)
      local tr = transcript(tpath)
      local cw = st.context_window or {}
      titles = titles or pane_titles()
      out[#out + 1] = {
        pid = s.pid,
        session_id = s.sessionId,
        name = st.session_name or titles[pane] or s.name or tostring(s.pid),
        cwd = s.cwd,
        pane = pane,
        status = s.status,
        waiting = s.waitingFor,
        ts = math.floor((s.statusUpdatedAt or s.updatedAt or 0) / 1000),
        model = (st.model and st.model.display_name) or short_model(tr.model),
        ctx_pct = cw.used_percentage,
        ctx_size = cw.context_window_size,
        tokens = tr.tokens,
        text = plain(tr.text),
      }
    end
  end
  return out
end

local STALE = 7 * 86400 -- status files untouched this long are deleted
local scache = {} -- status path -> { mtime, json }

-- herdr pane id -> { model, ctx_pct, ctx_size, tokens, text, session_name } from status files the
-- statusline tagged with herdr_pane. Pane ids restart with the herdr server: the newest file wins.
function M.by_herdr_pane()
  local out, newest, now = {}, {}, os.time()
  for _, path in ipairs(vim.fn.glob(STATUS .. "/*.json", false, true)) do
    local st = vim.uv.fs_stat(path)
    if st and now - st.mtime.sec > STALE then
      os.remove(path)
      scache[path] = nil
    elseif st then
      local c = scache[path]
      if not c or c.mtime ~= st.mtime.sec then
        c = { mtime = st.mtime.sec, json = read_json(path) or {} }
        scache[path] = c
      end
      local j, pane = c.json, c.json.herdr_pane
      if pane and (not newest[pane] or c.mtime > newest[pane]) then
        newest[pane] = c.mtime
        local tr = transcript(j.transcript_path)
        local cw = j.context_window or {}
        out[pane] = {
          session_id = j.session_id,
          session_name = j.session_name,
          model = (j.model and j.model.display_name) or short_model(tr.model),
          ctx_pct = cw.used_percentage,
          ctx_size = cw.context_window_size,
          tokens = tr.tokens,
          text = plain(tr.text),
        }
      end
    end
  end
  return out
end

-- tmux helpers (these panes live in the outer tmux, not in herdr)
function M.attach(pane)
  vim.system({ "tmux", "switch-client", "-t", pane }):wait()
  vim.system({ "tmux", "select-pane", "-t", pane }):wait()
end

function M.interrupt(pane)
  vim.system({ "tmux", "send-keys", "-t", pane, "Escape" }):wait()
end

return M
