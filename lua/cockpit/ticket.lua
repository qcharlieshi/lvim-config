-- Ticket keys (ENG-35131) for agent names. Only configured prefixes count, so "GPT-5" or "UTF-8" in a
-- session title never becomes a name. vim.g.cockpit_ticket_prefixes, default { "ENG" }.
local M = {}

function M.prefixes()
  return vim.g.cockpit_ticket_prefixes or { "ENG" }
end

-- first whole-word key with a configured prefix, uppercased; nil if none
function M.find(text)
  if not text then
    return nil
  end
  local up = text:upper()
  local best, at = nil, math.huge
  for _, p in ipairs(M.prefixes()) do
    local s, _, num = up:find("%f[%w]" .. p:upper() .. "%-(%d+)%f[%W]")
    if s and s < at then
      best, at = p:upper() .. "-" .. num, s
    end
  end
  return best
end

function M.slug(key)
  return (key:lower():gsub("[^a-z0-9_-]", "-"):gsub("^[^a-z]+", ""):sub(1, 32))
end

-- the ticket of a worktree dir: its branch name, else the first -<digits> in the dir name (lilt-mcp-34500)
function M.for_dir(dir)
  local r = vim.system({ "git", "-C", dir, "branch", "--show-current" }, { text = true }):wait()
  local key = r.code == 0 and M.find(r.stdout) or nil
  if key then
    return key
  end
  local num = vim.fs.basename(dir):match("%-(%d%d%d+)")
  return num and (M.prefixes()[1]:upper() .. "-" .. num) or nil
end

return M
