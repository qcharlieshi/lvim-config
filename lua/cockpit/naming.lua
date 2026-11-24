-- cockpit agent names: <project>-<label>, the same name for herdr, the tab and `claude -n`.
-- Label, first that exists: a name you typed › ticket key (branch, then prompt) › a meaningful branch ›
-- 2-3 words of the first prompt. Without any, herdr.free_name falls back to <project>-<n>.
local M = {}

local MAX = 28
M.MAX = MAX
local SKIP_BRANCH = { main = true, master = true, develop = true, dev = true, trunk = true, HEAD = true }
local STOP = {}
for w in
  ([[a an the and or but to of in on at for from with without into onto by as is are be was were
  this that these those it its we our you your i me my please can could would should will just also then
  so do does did make add fix use get set new let lets need want try some any all more about over via]]):gmatch("%S+")
do
  STOP[w] = true
end

function M.slug(s, max)
  s = (s or ""):lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  if max and #s > max then
    s = s:sub(1, max):gsub("%-[^%-]*$", "") -- cut at a word boundary
  end
  return s
end

-- a ticket key with a configured prefix (cockpit.ticket: ENG-35131 -> eng-35131), so sha-256 never counts
function M.ticket(s)
  local key = require("cockpit.ticket").find(s)
  return key and key:lower()
end

function M.branch(dir)
  if not dir then
    return
  end
  local r = vim.system({ "git", "-C", dir, "branch", "--show-current" }, { text = true }):wait()
  local b = r.code == 0 and vim.trim(r.stdout or "") or ""
  if b == "" or SKIP_BRANCH[b] or b:match("^fork/") then
    return -- detached, a default branch, or a cockpit fork branch (named after its parent already)
  end
  return b
end

function M.words(prompt, n)
  local out = {}
  for w in (prompt or ""):lower():gmatch("[%w]+") do
    if #w >= 3 and not STOP[w] and not w:match("^%d+$") then
      out[#out + 1] = w
      if #out == (n or 3) then
        break
      end
    end
  end
  return #out > 0 and table.concat(out, "-") or nil
end

-- Name base for an agent, or nil for the numbered fallback. opts: name (typed), dir, prompt.
function M.base(project, opts)
  opts = opts or {}
  if opts.name and vim.trim(opts.name) ~= "" then
    return M.slug(opts.name, MAX)
  end
  local branch = M.branch(opts.dir)
  local label = M.ticket(branch) or M.ticket(opts.prompt)
  if not label and branch then
    label = M.slug(branch:match("[^/]+$"))
  end
  label = label or M.words(opts.prompt)
  if not label or label == "" then
    return
  end
  local name = M.slug(project) .. "-" .. label
  return M.slug(name, MAX)
end

return M
