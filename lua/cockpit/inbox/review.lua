-- Codediff deliverables in CodeDiff: rebuild before/after trees from the sent patch so the
-- review (and any edits) never touch the agent's worktree. Edits are diffed against sent/.
local store = require("cockpit.inbox.store")
local M = {}

local function sh(cmd, opts)
  local r = vim.system(cmd, vim.tbl_extend("force", { text = true }, opts or {})):wait()
  return r.code == 0, r.stdout or "", r.stderr or ""
end

local function write(file, data)
  vim.fn.mkdir(vim.fs.dirname(file), "p")
  local f = assert(io.open(file, "wb"))
  f:write(data)
  f:close()
end

-- Idempotent: an existing review/ holds the human's edits and is never rebuilt
function M.prepare(tid, att)
  local root = store.review_root(tid, att)
  if vim.fn.isdirectory(root .. "/review") == 1 then
    return root
  end
  local base = att.base_sha or att.base or "HEAD"
  local paths = store.patch_paths(store.blob(att.sha256))
  for _, p in ipairs(paths) do
    local ok, out = sh({ "git", "-C", att.cwd or ".", "show", base .. ":" .. p })
    if ok then
      write(root .. "/base/" .. p, out)
      write(root .. "/sent/" .. p, out)
    end
  end
  vim.fn.mkdir(root .. "/base", "p")
  vim.fn.mkdir(root .. "/sent", "p")
  -- Ceiling stops git from discovering an enclosing repo, so `apply` acts like patch(1)
  local ok, _, err = sh(
    { "git", "apply", "--whitespace=nowarn", store.path("blobs", att.sha256) },
    { cwd = root .. "/sent", env = { GIT_CEILING_DIRECTORIES = root } }
  )
  if not ok then
    vim.fn.delete(root, "rf")
    return nil, "patch does not apply to " .. base .. ": " .. vim.trim(err)
  end
  sh({ "cp", "-R", root .. "/sent", root .. "/review" })
  return root
end

function M.open(tid, att)
  if att.cwd and vim.fn.isdirectory(att.cwd) == 0 then
    return vim.notify("cockpit: repo for this diff is gone: " .. att.cwd, vim.log.levels.WARN)
  end
  local root, err = M.prepare(tid, att)
  if not root then
    return vim.notify("cockpit: " .. err, vim.log.levels.ERROR)
  end
  vim.cmd("CodeDiff dir " .. vim.fn.fnameescape(root .. "/base") .. " " .. vim.fn.fnameescape(root .. "/review"))
end

function M.reset(tid, att)
  vim.fn.delete(store.review_root(tid, att), "rf")
end

return M
