-- cockpit projects: a named set of repos (first = primary, spawn cwd; rest = --add-dir).
-- Layout: <dir>/<name>/{project.json, repos/<basename> -> repo, threads/<tid>.jsonl -> inbox thread}.
local M = {}

M.dir = vim.fn.expand(vim.env.COCKPIT_PROJECTS_DIR or "~/.cockpit/projects")
local NAME = "^[a-z][a-z0-9_-]*$"
local DONE = "✓ done"

function M.root(name)
  return M.dir .. "/" .. name
end

local function file(name)
  return M.root(name) .. "/project.json"
end

local function read(path)
  local ok, p = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
  end)
  if not ok or type(p) ~= "table" then
    return nil
  end
  p.repos = vim.tbl_map(function(r)
    return vim.fn.expand(r)
  end, p.repos or {})
  return p
end

local function link(target, path)
  if not vim.uv.fs_lstat(path) then
    vim.uv.fs_symlink(target, path)
  end
end

function M.save(p)
  local root = M.root(p.name)
  -- pcall: two `claude` launches may create the same project at once (mkdir -p is racy in nvim)
  pcall(vim.fn.mkdir, root .. "/repos", "p")
  pcall(vim.fn.mkdir, root .. "/threads", "p")
  local home = vim.fn.expand("~")
  local repos = vim.tbl_map(function(r)
    return r:sub(1, #home) == home and ("~" .. r:sub(#home + 1)) or r
  end, p.repos)
  local data =
    { name = p.name, repos = repos, ticket = p.ticket, created = p.created or os.date("%Y-%m-%dT%H:%M:%S%z") }
  vim.fn.writefile({ vim.json.encode(data) }, file(p.name))
  -- rebuild repos/ symlinks (basename collision -> <basename>-2)
  for _, l in ipairs(vim.fn.glob(root .. "/repos/*", false, true)) do
    vim.uv.fs_unlink(l)
  end
  local seen = {}
  for _, r in ipairs(p.repos) do
    local base = vim.fs.basename(r)
    local n = base
    if seen[base] then
      n = base .. "-2"
    end
    seen[base] = true
    vim.uv.fs_symlink(vim.fn.expand(r), root .. "/repos/" .. n)
  end
end

-- flat <name>.json (step 1) -> <name>/project.json
function M.migrate()
  for _, path in ipairs(vim.fn.glob(M.dir .. "/*.json", false, true)) do
    local p = read(path)
    if p then
      p.name = p.name or vim.fn.fnamemodify(path, ":t:r")
      local raw = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
      p.created = raw.created
      M.save(p)
      vim.uv.fs_unlink(path)
    end
  end
end

function M.get(name)
  M.migrate()
  local path = file(name)
  return vim.fn.filereadable(path) == 1 and read(path) or nil
end

function M.list()
  M.migrate()
  local out = {}
  for _, path in ipairs(vim.fn.glob(M.dir .. "/*/project.json", false, true)) do
    local p = read(path)
    if p then
      out[#out + 1] = p
    end
  end
  table.sort(out, function(a, b)
    return a.name < b.name
  end)
  return out
end

function M.link_thread(name, tid)
  local store = require("cockpit.inbox.store")
  vim.fn.mkdir(M.root(name) .. "/threads", "p")
  link(store.thread_file(tid), M.root(name) .. "/threads/" .. tid .. ".jsonl")
end

local function git_roots()
  local cmd =
    { "fd", "-H", "-t", "d", "--max-depth", "4", "^\\.git$", vim.fn.expand("~/dev"), vim.fn.expand("~/.config") }
  local out = vim.system(cmd, { text = true }):wait().stdout or ""
  local roots = {}
  for line in out:gmatch("[^\n]+") do
    roots[#roots + 1] = vim.fs.dirname(line:gsub("/$", ""))
  end
  table.sort(roots)
  return roots
end

local function valid_name(name)
  if not name:match(NAME) or #name > 28 then
    vim.notify("cockpit: project names are [a-z][a-z0-9_-], max 28 chars", vim.log.levels.WARN)
    return false
  end
  return true
end

-- name → dirs (first pick is primary) → save → cb(p)
local function new_from_dirs(cb)
  vim.ui.input({ prompt = "Project name: " }, function(name)
    if not name or name == "" then
      return
    end
    if not name:match(NAME) or #name > 28 then
      return vim.notify("cockpit: project names are [a-z][a-z0-9_-], max 28 chars", vim.log.levels.WARN)
    end
    local roots, repos = git_roots(), {}
    local function pick()
      local items = { DONE }
      for _, r in ipairs(roots) do
        if not vim.tbl_contains(repos, r) then
          items[#items + 1] = r
        end
      end
      local prompt = #repos == 0 and "Primary repo" or ("Add repo (" .. #repos .. " so far)")
      vim.ui.select(items, { prompt = prompt }, function(choice)
        if choice and choice ~= DONE then
          repos[#repos + 1] = choice
          return pick()
        end
        if #repos == 0 then
          return vim.notify("cockpit: a project needs at least one repo", vim.log.levels.WARN)
        end
        local p = { name = name, repos = repos }
        M.save(p)
        vim.notify("cockpit: project " .. name .. " saved (" .. #repos .. " repos)")
        if cb then
          cb(M.get(name))
        end
      end)
    end
    pick()
  end)
end

local function git(dir, ...)
  local r = vim.system({ "git", "-C", dir, "rev-parse", ... }, { text = true }):wait()
  return r.code == 0 and vim.trim(r.stdout) or nil
end

local function real(p)
  return vim.uv.fs_realpath(p) or p
end

-- The project with the most specific dir equal to or containing `dir` (longest dir wins), or nil.
-- Never creates one.
function M.containing(dir)
  dir = real(vim.fs.normalize(dir))
  local best, len = nil, -1
  for _, p in ipairs(M.list()) do
    for _, r in ipairs(p.repos) do
      r = real(r)
      if (dir == r or dir:sub(1, #r + 1) == r .. "/") and #r > len then
        best, len = p.name, #r
      end
    end
  end
  return best
end

-- The project containing `dir`; else creates a one-dir project named after the repo (a worktree's own
-- toplevel, so it can become its own ticket project). Outside git, `dir` itself is the dir (e.g.
-- ~/dev/lilt, the org root holding many repos). Returns the name; nil only for $HOME and /, which
-- would make a project of everything.
function M.for_dir(dir)
  local found = M.containing(dir)
  if found then
    return found
  end
  local repo = git(dir, "--show-toplevel") or real(vim.fs.normalize(dir))
  if repo == "/" or repo == real(vim.fn.expand("~")) then
    return nil
  end
  local base = vim.fs.basename(repo):lower():gsub("[^a-z0-9_-]", "-"):gsub("^[^a-z]+", "")
  base = (base == "" and "repo" or base):sub(1, 28)
  local name, n = base, 1
  while M.get(name) do -- never clobber an unrelated project with the same basename
    n = n + 1
    name = base:sub(1, 28 - #tostring(n) - 1) .. "-" .. n
  end
  M.save({ name = name, repos = { repo } })
  return name
end

function M.edit(name)
  local function open(n)
    vim.cmd.edit(vim.fn.fnameescape(file(n)))
  end
  if name and name ~= "" then
    return open(name)
  end
  vim.ui.select(
    vim.tbl_map(function(p)
      return p.name
    end, M.list()),
    { prompt = "Edit project" },
    function(n)
      if n then
        open(n)
      end
    end
  )
end

-- Where a new worktree for `key` (ENG-35131, optional) + `slug` goes: <repo>-<number> (the sibling convention,
-- e.g. lilt-mcp-35131), <repo>-<number>-<slug> if that exists, <repo>-<slug> without a ticket. Branch
-- <prefix>/<KEY>-<slug> (eng/ENG-35131-slack-poc), or <prefix>/<slug>.
function M.worktree_plan(repo, key, slug)
  local prefix = require("cockpit.ticket").prefixes()[1]:lower()
  local num = key and key:match("%-(%d+)$")
  local path = num and (repo .. "-" .. num) or (repo .. "-" .. slug)
  if num and vim.uv.fs_stat(path) then
    path = path .. "-" .. slug
  end
  return { path = path, branch = key and (prefix .. "/" .. key .. "-" .. slug) or (prefix .. "/" .. slug) }
end

function M.make_worktree(repo, key, slug)
  local plan = M.worktree_plan(repo, key, slug)
  local r = vim
    .system({ "git", "-C", repo, "worktree", "add", "-b", plan.branch, plan.path, "HEAD" }, { text = true })
    :wait()
  if r.code ~= 0 then
    return nil, vim.trim(r.stderr or "")
  end
  return plan.path
end

-- linked worktrees of `repo` (not the main checkout): { {path, branch?} }
function M.list_worktrees(repo)
  local out = vim.system({ "git", "-C", repo, "worktree", "list", "--porcelain" }, { text = true }):wait().stdout or ""
  local list, cur = {}, nil
  for line in (out .. "\n"):gmatch("([^\n]*)\n") do
    if line:match("^worktree ") then
      cur = { path = line:sub(10) }
      list[#list + 1] = cur
    elseif cur and line:match("^branch ") then
      cur.branch = line:sub(8):gsub("^refs/heads/", "")
    end
  end
  table.remove(list, 1) -- the main checkout comes first
  return list
end

-- dirs from worktrees: "New worktree" (ticket, slug -> git worktree add) or "Existing worktrees" (multi-pick).
-- cb(dirs, key) with the ticket key for naming, or nothing on cancel.
local function pick_worktrees(kind, cb)
  vim.ui.select(git_roots(), { prompt = "Repo" }, function(repo)
    if not repo then
      return
    end
    if kind == "New worktree" then
      vim.ui.input({ prompt = "Ticket (e.g. ENG-35131, optional): " }, function(raw)
        if raw == nil then
          return
        end
        local key = require("cockpit.ticket").find(raw)
        vim.ui.input({ prompt = "Short slug: " }, function(slug)
          if not slug or slug == "" then
            return
          end
          local path, err = M.make_worktree(repo, key, slug)
          if not path then
            return vim.notify("cockpit: git worktree add failed — " .. err, vim.log.levels.ERROR)
          end
          cb({ path }, key, slug)
        end)
      end)
      return
    end
    local wts, picked = M.list_worktrees(repo), {}
    local function more()
      local items = { DONE }
      for _, w in ipairs(wts) do
        if not vim.tbl_contains(picked, w.path) then
          items[#items + 1] = w.path
        end
      end
      local fmt = function(item)
        for _, w in ipairs(wts) do
          if w.path == item then
            return ("%s  [%s]"):format(item, w.branch or "detached")
          end
        end
        return item
      end
      vim.ui.select(items, { prompt = "Worktrees (" .. #picked .. " so far)", format_item = fmt }, function(choice)
        if choice and choice ~= DONE then
          picked[#picked + 1] = choice
          return more()
        end
        if #picked > 0 then
          cb(picked, require("cockpit.ticket").for_dir(picked[1]))
        end
      end)
    end
    more()
  end)
end

local KINDS = { "Dirs", "New worktree", "Existing worktrees" }

-- :CockpitProject new — from dirs, a new worktree, or existing worktrees; cb(p) once saved
function M.new(cb)
  vim.ui.select(KINDS, { prompt = "New project from" }, function(kind)
    if kind == "Dirs" then
      return new_from_dirs(cb)
    elseif not kind then
      return
    end
    pick_worktrees(kind, function(dirs, key, slug)
      vim.ui.input({ prompt = "Project name: ", default = slug or "" }, function(name)
        if name == "" then
          name = slug
        end
        if not name or not valid_name(name) then
          return
        end
        M.save({ name = name, repos = dirs, ticket = key })
        vim.notify("cockpit: project " .. name .. " saved (" .. #dirs .. " dirs)")
        if cb then
          cb(M.get(name))
        end
      end)
    end)
  end)
end

-- :CockpitProject add-worktree [name] — append a new or existing worktree to a project
function M.add_worktree(name)
  local function go(n)
    local p = M.get(n)
    if not p then
      return vim.notify("cockpit: no project " .. tostring(n), vim.log.levels.WARN)
    end
    vim.ui.select({ "New worktree", "Existing worktrees" }, { prompt = "Add to " .. n }, function(kind)
      if not kind then
        return
      end
      pick_worktrees(kind, function(dirs)
        for _, d in ipairs(dirs) do
          if not vim.tbl_contains(p.repos, d) then
            p.repos[#p.repos + 1] = d
          end
        end
        M.save(p)
        vim.notify(("cockpit: %s now has %d dirs"):format(n, #p.repos))
      end)
    end)
  end
  if name and name ~= "" then
    return go(name)
  end
  vim.ui.select(
    vim.tbl_map(function(p)
      return p.name
    end, M.list()),
    { prompt = "Add a worktree to project" },
    function(n)
      if n then
        go(n)
      end
    end
  )
end

return M
