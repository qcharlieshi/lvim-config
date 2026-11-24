local M = {}

M.root = vim.env.COCKPIT_ROOT
M.fixtures = M.root .. "/tests/fixtures/threads"

-- A fresh, empty inbox per test, and cockpit modules reloaded so they read it (they read env at load time)
function M.fresh()
  local dir = vim.fn.tempname()
  vim.env.COCKPIT_INBOX_DIR = dir .. "/inbox"
  vim.env.COCKPIT_PROJECTS_DIR = dir .. "/projects"
  vim.fn.mkdir(dir .. "/inbox/threads", "p")
  for name in pairs(package.loaded) do
    if name:match("^cockpit") then
      package.loaded[name] = nil
    end
  end
  return dir
end

function M.read_json(path)
  local f = assert(io.open(path, "r"))
  local s = f:read("a")
  f:close()
  return vim.json.decode(s, { luanil = { object = true, array = true } })
end

-- Copy the golden thread fixtures into the current inbox; returns expected.json
function M.load_fixtures()
  local dst = vim.env.COCKPIT_INBOX_DIR .. "/threads/"
  for _, f in ipairs(vim.fn.glob(M.fixtures .. "/*.jsonl", false, true)) do
    vim.uv.fs_copyfile(f, dst .. vim.fs.basename(f))
  end
  return M.read_json(M.fixtures .. "/expected.json")
end

function M.write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
end

function M.run()
  require("mini.test").run({
    collect = {
      find_files = function()
        return vim.fn.glob(M.root .. "/tests/lua/test_*.lua", false, true)
      end,
    },
    execute = { reporter = require("mini.test").gen_reporter.stdout({ group_depth = 2 }) },
  })
end

return M
