-- cockpit agent registry: append-only <project dir>/agents.jsonl, one record per agent start/change.
-- Identity is the Claude session (`session`); a record without one (legacy, or a start whose session
-- isn't known yet) is keyed by terminal_id until reconcile learns the session in that seat.
local M = {}

local function file(project)
  return require("cockpit.projects").root(project) .. "/agents.jsonl"
end

function M.key(rec)
  return rec.session or rec.terminal_id
end

function M.append(project, rec)
  rec = vim.tbl_extend("force", rec, { ts = os.time() })
  pcall(vim.fn.mkdir, vim.fs.dirname(file(project)), "p") -- racy with a concurrent launch
  local f = assert(io.open(file(project), "a"))
  f:write(vim.json.encode(rec), "\n")
  f:close()
end

local function lines(project)
  if vim.fn.filereadable(file(project)) == 0 then
    return {}
  end
  local out = {}
  for _, line in ipairs(vim.fn.readfile(file(project))) do
    local ok, rec = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
    if ok and type(rec) == "table" and rec.terminal_id then
      out[#out + 1] = rec
    end
  end
  return out
end

-- latest line per key wins; a record with a session supersedes earlier session-less ones of its terminal
function M.all(project)
  local out = {}
  for _, rec in ipairs(lines(project)) do
    if rec.session and out[rec.terminal_id] and not out[rec.terminal_id].session then
      out[rec.terminal_id] = nil
    end
    out[M.key(rec)] = rec
  end
  return out
end

-- the latest record for a terminal (seat), whatever session it holds
function M.by_terminal(project, terminal_id)
  local got
  for _, rec in ipairs(lines(project)) do
    if rec.terminal_id == terminal_id then
      got = rec
    end
  end
  return got
end

function M.names(project)
  local set = {}
  for _, rec in pairs(M.all(project)) do
    set[rec.name] = true
  end
  return set
end

return M
