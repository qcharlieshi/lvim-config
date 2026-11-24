-- cockpit ↔ Claude Code session details for herdr agents, read from files Claude Code already writes:
--   ~/.cockpit/status/<sid>.json    statusline input (claude-statusline.sh): model, context_window, herdr_pane
--   transcript jsonl                last assistant text (+ model/usage fallback when no status file yet)
local M = {}

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

return M
