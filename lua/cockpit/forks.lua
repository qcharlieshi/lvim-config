-- cockpit forks (spec §3.4, §4b.1/3/4/7): a fork resumes its parent's Claude session as a new
-- session (`--resume <id> --fork-session`) in a pane split into the parent's ck/ workspace.
--   continue — same checkout as the parent.
--   worktree — fresh git worktrees, one per project repo, on branch fork/<parent>-<n>. Never
--              touches the parent's checkouts; kill-cleanup never drops commits without asking.
local M = {}

local function git(dir, ...)
  local r = vim.system({ "git", "-C", dir, ... }, { text = true }):wait()
  return r.code == 0, vim.trim(r.stdout or ""), vim.trim(r.stderr or "")
end

local function preamble(parent)
  return ("You are a fork of %s. Open new inbox threads for your work; don't post to your parent's threads."):format(
    parent.name
  )
end

-- A hand-started agent has no name (its cache key is the pane id): display it by target, and
-- slug that for branch/path use (pane ids contain ':', which git refs reject).
local function named(parent)
  return vim.tbl_extend("force", parent, { name = parent.name or parent.target })
end

local function slug(name)
  return (name:gsub("[^%w._-]", "-"))
end

-- herdr's view first, the registry record as fallback
local function session_of(parent)
  local _, got = require("cockpit.herdr").request("agent.get", { target = parent.target or parent.name })
  local s = got and got.agent and got.agent.agent_session and got.agent.agent_session.value
  if not s and parent.project then
    local rec = require("cockpit.registry").by_terminal(parent.project, parent.terminal_id)
    s = rec and rec.session
  end
  return s
end

-- Validate the parent; returns project, session or nil after notifying.
local function check(parent)
  local p = parent.project and require("cockpit.projects").get(parent.project)
  if not p then
    vim.notify("cockpit: " .. parent.name .. " is not in a project", vim.log.levels.WARN)
    return
  end
  local session = session_of(parent)
  if not session then
    vim.notify("cockpit: " .. parent.name .. " has no session id yet", vim.log.levels.WARN)
    return
  end
  -- Claude writes the transcript on the first message; --resume of a session without one exits
  local claude_dir = vim.env.CLAUDE_CONFIG_DIR or vim.fn.expand("~/.claude")
  if #vim.fn.glob(claude_dir .. "/projects/*/" .. session .. ".jsonl", false, true) == 0 then
    vim.notify("cockpit: " .. parent.name .. " has no conversation to fork yet", vim.log.levels.WARN)
    return
  end
  return p, session
end

-- Split a pane next to the parent and start the resumed fork there; record it, then send the
-- user's prompt. The fork preamble is given at launch, so a fork blocked at startup (folder trust)
-- still gets it once you answer the dialog: as SessionStart hook context via --settings, because
-- --append-system-prompt / --system-prompt are ignored on --resume (claude 2.1.322). `undo` runs when the fork never
-- came to exist (split failed, or start failed other than blocked).
local function start(parent, session, cwd, add_dirs, system, prompt, rec, cb, undo)
  undo = undo or function() end
  local herdr = require("cockpit.herdr")
  local project = parent.project
  local env = { COCKPIT_PROJECT = project, COCKPIT_INBOX_DIR = vim.env.COCKPIT_INBOX_DIR, COCKPIT_PARENT = parent.name }
  local err, res = herdr.request("pane.split", {
    target_pane_id = parent.pane_id,
    direction = "right",
    cwd = cwd,
    focus = false,
    env = env,
  })
  if err then
    undo()
    vim.notify("cockpit: fork failed — " .. err.message, vim.log.levels.ERROR)
    return cb(err)
  end
  local pane_id = res.pane.pane_id
  local hook = { type = "command", command = "printf '%s\\n' " .. vim.fn.shellescape(system) }
  local settings = vim.json.encode({ hooks = { SessionStart = { { hooks = { hook } } } } })
  local args = { "--resume", session, "--fork-session", "--settings", settings }
  for _, d in ipairs(add_dirs) do
    vim.list_extend(args, { "--add-dir", d })
  end
  rec =
    vim.tbl_extend("force", rec, { project = project, parent_terminal = parent.terminal_id, parent_name = parent.name })
  herdr.start_in(pane_id, herdr.free_name(project), args, rec, function(serr, name)
    if serr and serr.code ~= "agent_not_ready" then
      herdr.request("pane.close", { pane_id = pane_id })
      undo()
    elseif not serr and prompt and prompt ~= "" then
      herdr.request("agent.prompt", { target = name, text = prompt }, function() end)
    end
    cb(serr, name)
  end)
end

-- f: fork in the parent's own checkout. cb(err, name).
function M.continue(parent, prompt, cb)
  cb = cb or function() end
  parent = named(parent)
  local p, session = check(parent)
  if not p then
    return cb({ code = "no_session", message = "cannot fork " .. parent.name })
  end
  start(parent, session, parent.cwd, vim.list_slice(p.repos, 2), preamble(parent), prompt, { fork = "continue" }, cb)
end

local function exclude_worktrees(repo)
  local _, common = git(repo, "rev-parse", "--path-format=absolute", "--git-common-dir")
  local file = common .. "/info/exclude"
  local lines = vim.fn.filereadable(file) == 1 and vim.fn.readfile(file) or {}
  if not vim.tbl_contains(lines, ".worktrees/") then
    vim.fn.mkdir(common .. "/info", "p")
    vim.fn.writefile({ ".worktrees/" }, file, "a")
  end
end

local function remove(w, force)
  local cmd = force and { "worktree", "remove", "--force", w.path } or { "worktree", "remove", w.path }
  return git(w.repo, unpack(cmd))
end

-- worktrees made for a fork that never started have no commits: drop them and their branch
local function rollback(wts)
  for _, w in ipairs(wts) do
    remove(w, true)
    git(w.repo, "branch", "-D", w.branch)
  end
end

-- F: fork into fresh worktrees of every project repo. cb(err, name).
function M.worktree(parent, prompt, cb)
  cb = cb or function() end
  parent = named(parent)
  local p, session = check(parent)
  if not p then
    return cb({ code = "no_session", message = "cannot fork " .. parent.name })
  end
  local id = slug(parent.name)
  -- lowest n whose branch exists in none of the repos
  local n, branch = 0, nil
  repeat
    n = n + 1
    branch = ("fork/%s-%d"):format(id, n)
    local taken = vim.iter(p.repos):any(function(r)
      return (select(1, git(r, "rev-parse", "--verify", "--quiet", "refs/heads/" .. branch)))
    end)
  until not taken
  local wts = {}
  for _, repo in ipairs(p.repos) do
    exclude_worktrees(repo)
    local path = ("%s/.worktrees/fork-%s-%d"):format(repo, id, n)
    local _, base = git(repo, "rev-parse", "HEAD")
    local ok, _, gerr = git(repo, "worktree", "add", path, "-b", branch, "HEAD")
    if not ok then
      rollback(wts)
      vim.notify("cockpit: worktree fork failed in " .. repo .. " — " .. gerr, vim.log.levels.ERROR)
      return cb({ code = "worktree", message = gerr })
    end
    wts[#wts + 1] = { repo = repo, path = path, branch = branch, base = base }
  end
  local paths = vim.tbl_map(function(w)
    return w.path
  end, wts)
  local system = ("You are a fork of %s working in separate git worktrees (%s) on branch %s. Only edit files there. "):format(
    parent.name,
    table.concat(paths, ", "),
    branch
  ) .. preamble(parent)
  start(
    parent,
    session,
    paths[1],
    vim.list_slice(paths, 2),
    system,
    prompt,
    { fork = "worktree", worktrees = wts },
    cb,
    function()
      rollback(wts)
    end
  )
end

-- After a worktree fork is killed: drop clean, commit-less worktrees + branch silently; otherwise
-- ask once for the whole fork. Keep → remove only clean worktree dirs, keep the branch.
function M.cleanup(rec)
  local wts = rec.worktrees or {}
  if #wts == 0 then
    return
  end
  local ahead, dirty = 0, {}
  for _, w in ipairs(wts) do
    local _, st = git(w.path, "status", "--porcelain")
    w.dirty = vim.fn.isdirectory(w.path) == 1 and st ~= ""
    if w.dirty then
      dirty[#dirty + 1] = vim.fs.basename(w.repo)
    end
    local _, count = git(w.repo, "rev-list", "--count", w.base .. ".." .. w.branch)
    ahead = ahead + (tonumber(count) or 0)
  end
  local function drop(force)
    for _, w in ipairs(wts) do
      remove(w, force)
      git(w.repo, "branch", "-D", w.branch)
    end
  end
  if ahead == 0 and #dirty == 0 then
    return drop(false)
  end
  local prompt = ("%s : %d commit%s"):format(wts[1].branch, ahead, ahead == 1 and "" or "s")
  if #dirty > 0 then
    prompt = prompt .. ", dirty in " .. table.concat(dirty, ", ")
  end
  vim.ui.select({ "Keep branch", "Discard" }, { prompt = prompt }, function(choice)
    if choice == "Discard" then
      drop(true)
    elseif choice == "Keep branch" then
      for _, w in ipairs(wts) do
        if not w.dirty then
          remove(w, false)
        end
      end
    end
  end)
end

return M
