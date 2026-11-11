-- cockpit agent registry: append-only <project dir>/agents.jsonl, one record per agent start/change.
-- Identity is terminal_id; names are display-only and never reused within a project.
local M = {}

local function file(project)
  return require("cockpit.projects").root(project) .. "/agents.jsonl"
end

function M.append(project, rec)
  rec = vim.tbl_extend("force", rec, { ts = os.time() })
  pcall(vim.fn.mkdir, vim.fs.dirname(file(project)), "p") -- racy with a concurrent launch
  local f = assert(io.open(file(project), "a"))
  f:write(vim.json.encode(rec), "\n")
  f:close()
end

-- latest line per terminal_id wins
function M.all(project)
  local out = {}
  if vim.fn.filereadable(file(project)) == 0 then
    return out
  end
  for _, line in ipairs(vim.fn.readfile(file(project))) do
    local ok, rec = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
    if ok and type(rec) == "table" and rec.terminal_id then
      out[rec.terminal_id] = rec
    end
  end
  return out
end

function M.names(project)
  local set = {}
  for _, rec in pairs(M.all(project)) do
    set[rec.name] = true
  end
  return set
end

return M
