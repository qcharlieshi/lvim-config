-- Claude Code transcripts (~/.claude/projects/<cwd>/<session>.jsonl) as conversation entries.
-- Parsed incrementally: each file keeps its byte offset, so a refresh only decodes appended lines.
--
-- Entry: { ts, role = "user"|"assistant", text? , tool? = "Name: summary", command? = "/name args" }
-- Skipped: subagent (sidechain) and meta lines, tool results, non-message records.
local M = {}

local PROJECTS = vim.fn.expand("~/.claude/projects")
local paths = {} -- session id (or 8-char prefix) -> transcript path
local parsed = {} -- path -> { offset, entries }

-- path of a session's transcript; accepts a full id or the 8-char prefix thread ids carry
function M.find(sid)
  if paths[sid] and vim.uv.fs_stat(paths[sid]) then
    return paths[sid]
  end
  local hit = vim.fn.glob(PROJECTS .. "/*/" .. sid .. (#sid < 36 and "*" or "") .. ".jsonl", false, true)[1]
  paths[sid] = hit
  return hit
end

local UTC_OFFSET = os.time() - os.time(os.date("!*t"))
-- "2026-11-24T14:41:11.123Z" -> epoch seconds
local function epoch(iso)
  local y, mo, d, h, mi, s = (iso or ""):match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then
    return 0
  end
  return os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = s }) + UTC_OFFSET
end

local SUMMARY_KEYS = { "skill", "command", "file_path", "pattern", "description", "url", "query", "prompt", "path" }
local function tool_line(b)
  local input, arg = b.input or {}, nil
  for _, k in ipairs(SUMMARY_KEYS) do
    if type(input[k]) == "string" and input[k] ~= "" then
      arg = input[k]
      break
    end
  end
  arg = arg and vim.trim(arg:gsub("%s*\n%s*", " ⏎ ")) or ""
  if #arg > 120 then
    arg = arg:sub(1, 119) .. "…"
  end
  return (b.name or "tool") .. (arg ~= "" and (": " .. arg) or "")
end

local function decode(line, out)
  if not (line:find('"type":"user"', 1, true) or line:find('"type":"assistant"', 1, true)) then
    return
  end
  local ok, e = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
  if not ok or type(e) ~= "table" or e.isSidechain or e.isMeta or e.isCompactSummary then
    return
  end
  local m, ts = e.message, epoch(e.timestamp)
  if type(m) ~= "table" or (e.type ~= "user" and e.type ~= "assistant") then
    return
  end
  local content = type(m.content) == "string" and { { type = "text", text = m.content } } or m.content or {}
  for _, b in ipairs(content) do
    if b.type == "text" and vim.trim(b.text or "") ~= "" then
      local text = vim.trim(b.text)
      local cmd = text:match("<command%-name>(.-)</command%-name>")
      if cmd then
        local args = text:match("<command%-args>(.-)</command%-args>") or ""
        out[#out + 1] = { ts = ts, role = e.type, command = vim.trim(cmd .. " " .. args) }
      elseif not text:match("^<") then -- hook output, caveats, local command stdout
        out[#out + 1] = { ts = ts, role = e.type, text = text }
      end
    elseif b.type == "tool_use" then
      out[#out + 1] = { ts = ts, role = e.type, tool = tool_line(b) }
    end
  end
end

-- entries of one transcript file (cached; re-reads only what was appended)
function M.entries(path)
  local st = path and vim.uv.fs_stat(path)
  if not st then
    return {}
  end
  local c = parsed[path]
  if not c or st.size < c.offset then
    c = { offset = 0, entries = {} }
    parsed[path] = c
  end
  if st.size > c.offset then
    local f = io.open(path, "r")
    if f then
      f:seek("set", c.offset)
      local chunk = f:read(st.size - c.offset) or ""
      f:close()
      local last_nl = chunk:match(".*()\n") -- keep a half-written last line for next time
      if last_nl then
        for line in chunk:sub(1, last_nl):gmatch("([^\n]*)\n") do
          decode(line, c.entries)
        end
        c.offset = c.offset + last_nl
      end
    end
  end
  return c.entries
end

-- cheap change key for a set of transcript paths
function M.key(list)
  local parts = {}
  for _, p in ipairs(list) do
    local st = vim.uv.fs_stat(p)
    parts[#parts + 1] = st and (st.size .. ":" .. st.mtime.sec) or "-"
  end
  return table.concat(parts, ",")
end

return M
