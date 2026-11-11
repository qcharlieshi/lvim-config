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
  vim.fn.mkdir(root .. "/repos", "p")
  vim.fn.mkdir(root .. "/threads", "p")
  local home = vim.fn.expand("~")
  local repos = vim.tbl_map(function(r)
    return r:sub(1, #home) == home and ("~" .. r:sub(#home + 1)) or r
  end, p.repos)
  local data = { name = p.name, repos = repos, created = p.created or os.date("%Y-%m-%dT%H:%M:%S%z") }
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
  local cmd = { "fd", "-H", "-t", "d", "--max-depth", "4", "^\\.git$", vim.fn.expand("~/dev"), vim.fn.expand("~/.config") }
  local out = vim.system(cmd, { text = true }):wait().stdout or ""
  local roots = {}
  for line in out:gmatch("[^\n]+") do
    roots[#roots + 1] = vim.fs.dirname(line:gsub("/$", ""))
  end
  table.sort(roots)
  return roots
end

-- name → repos (first pick is primary) → save → cb(p)
function M.new(cb)
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

return M
