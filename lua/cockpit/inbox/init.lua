-- cockpit: agents post deliverables (documents, diffs, questions), optionally as gated pipeline
-- stages, with scripts/cockpit_inbox.py; you review, edit, annotate and send a verdict here.
local store = require("cockpit.inbox.store")
local M = {}

local seen = {} -- tid -> last message id already notified

local function notify_new()
  for _, t in ipairs(store.threads()) do
    local last = t.messages[#t.messages]
    if last and last.kind == "message" and seen[t.id] ~= last.id then
      local what = t.status == "needs_you" and "waiting on you" or "new message"
      vim.notify(("Inbox · %s: %s (%s)"):format(t.project or "?", t.title or t.id, what), vim.log.levels.INFO)
      seen[t.id] = last.id
    end
  end
end

local function watch()
  local timer = assert(vim.uv.new_timer())
  local function on_change()
    timer:stop()
    timer:start(
      300,
      0,
      vim.schedule_wrap(function()
        require("cockpit.inbox.ui").refresh()
        notify_new()
      end)
    )
  end
  for _, dir in ipairs({ store.root, store.path("threads") }) do
    vim.fn.mkdir(dir, "p")
    local h = assert(vim.uv.new_fs_event())
    h:start(dir, {}, on_change)
  end
  -- Prime without notifying for threads that existed before this nvim started
  for _, t in ipairs(store.threads()) do
    local last = t.messages[#t.messages]
    seen[t.id] = last and last.id or false
  end
end

function M.setup()
  local ui = function()
    return require("cockpit.inbox.ui")
  end
  local function open(o)
    if o.args ~= "" then
      ui().open_thread(o.args)
    else
      ui().open()
    end
  end
  vim.api.nvim_create_user_command("Cockpit", open, { nargs = "?", desc = "Cockpit (optional run/thread id)" })
  vim.api.nvim_create_user_command("Inbox", open, { nargs = "?", desc = "Cockpit (alias)" })
  vim.api.nvim_create_user_command("CockpitProject", function(o)
    local projects = require("cockpit.projects")
    if o.fargs[1] == "edit" then
      projects.edit(o.fargs[2])
    else
      projects.new()
    end
  end, {
    nargs = "*",
    desc = "Cockpit project: new | edit [name]",
    complete = function(_, line)
      if line:match("edit%s+%S*$") then
        return vim.tbl_map(function(p)
          return p.name
        end, require("cockpit.projects").list())
      end
      return { "new", "edit" }
    end,
  })
  vim.api.nvim_create_user_command("InboxBoard", function()
    ui().board()
  end, { desc = "Cockpit board" })
  vim.keymap.set("n", "<leader>ka", function()
    ui().open()
  end, { desc = "Cockpit" })
  vim.keymap.set("n", "<leader>kb", function()
    ui().board()
  end, { desc = "Cockpit board" })
  watch()
end

-- For a statusline segment: number of threads waiting on you
function M.waiting_count()
  local n = 0
  for _, t in ipairs(store.threads()) do
    if t.status == "needs_you" and not t.archived then
      n = n + 1
    end
  end
  return n
end

return M
