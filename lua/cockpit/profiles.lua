-- cockpit profiles: named claude launch settings, picked when spawning or forking an agent.
-- Built-in `default` adds nothing: the agent gets your user config (every plugin, MCP server, model).
-- More profiles go in ~/.cockpit/profiles.json, e.g.
--   { "planner": { "model": "opus", "effort": "high",
--                  "settings": { "enabledPlugins": { "superpowers@claude-plugins-official": true } } } }
-- Fields: model, effort, permission_mode, settings (table), plugin_dirs, mcp_config, strict_mcp,
-- append_system_prompt_file (ignored by claude on --resume, so not for forks), args (raw flags).
local M = {}

M.DEFAULT = "default"
local FILE = vim.fn.expand("~/.cockpit/profiles.json")

-- Internal profiles, never offered in the spawn picker; ~/.cockpit/profiles.json can override them by name.
-- `coordinator` only sets the model: cockpit.coordinator adds its barebones flags on top.
local HIDDEN = {
  coordinator = { model = "opus", effort = "medium" },
  ask = { model = "opus", effort = "medium" },
  digest = { model = "sonnet", effort = "low" }, -- the coordinator's delegated reads and summaries (cockpit-ctl ask)
}

function M.all()
  local defs = vim.tbl_extend("force", { [M.DEFAULT] = {} }, vim.deepcopy(HIDDEN))
  if vim.fn.filereadable(FILE) == 1 then
    local ok, user = pcall(vim.json.decode, table.concat(vim.fn.readfile(FILE), "\n"))
    if ok and type(user) == "table" then
      defs = vim.tbl_extend("force", defs, user)
    else
      vim.notify("cockpit: ignoring unreadable " .. FILE, vim.log.levels.WARN)
    end
  end
  return defs
end

-- default first, then the rest by name
function M.names()
  local names = vim.tbl_filter(function(n)
    return n ~= M.DEFAULT and not HIDDEN[n]
  end, vim.tbl_keys(M.all()))
  table.sort(names)
  table.insert(names, 1, M.DEFAULT)
  return names
end

-- claude flags for profile `name`. `settings` (the caller's own --settings table, e.g. a fork's
-- SessionStart hook) is merged into the profile's so claude gets a single --settings flag.
function M.args(name, settings)
  local p = M.all()[name or M.DEFAULT] or {}
  local args = {}
  local function flag(f, v)
    if v ~= nil and v ~= "" then
      vim.list_extend(args, { f, tostring(v) })
    end
  end
  flag("--model", p.model)
  flag("--effort", p.effort)
  flag("--permission-mode", p.permission_mode)
  flag("--append-system-prompt-file", p.append_system_prompt_file and vim.fn.expand(p.append_system_prompt_file))
  for _, d in ipairs(p.plugin_dirs or {}) do
    flag("--plugin-dir", vim.fn.expand(d))
  end
  if p.mcp_config then
    flag("--mcp-config", vim.fn.expand(p.mcp_config))
    if p.strict_mcp then
      args[#args + 1] = "--strict-mcp-config"
    end
  end
  local merged = vim.tbl_deep_extend("force", p.settings or {}, settings or {})
  if next(merged) then
    flag("--settings", vim.json.encode(merged))
  end
  vim.list_extend(args, p.args or {})
  return args
end

-- cb(name) or nothing on cancel. With only `default` there is nothing to pick: no prompt.
-- `current` (e.g. a fork's parent profile) is listed first.
function M.pick(cb, current)
  local names = M.names()
  if #names == 1 then
    return cb(names[1])
  end
  if current and vim.tbl_contains(names, current) then
    names = vim.tbl_filter(function(n)
      return n ~= current
    end, names)
    table.insert(names, 1, current)
  end
  vim.ui.select(names, { prompt = "Profile" }, function(choice)
    if choice then
      cb(choice)
    end
  end)
end

return M
