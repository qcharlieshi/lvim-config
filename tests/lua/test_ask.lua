-- Ask / coordinator / cockpit-ctl: argv building, context gathering, rotation trigger, ctl output. herdr is faked.
local h = require("tests.helpers")
local eq = MiniTest.expect.equality
local live, prompts

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      h.fresh()
      live, prompts = {}, {}
      package.loaded["cockpit.herdr"] = {
        agents = function()
          return live
        end,
        by_terminal = function(tid)
          for _, a in pairs(live) do
            if a.terminal_id == tid then
              return a
            end
          end
        end,
        prompt = function(target, text)
          prompts[#prompts + 1] = { target = target, text = text }
          return "delivered to " .. target, true
        end,
      }
    end,
  },
})

local function index(list, v)
  for i, x in ipairs(list) do
    if x == v then
      return i
    end
  end
end

T["hidden profiles: never offered, opus at medium effort"] = function()
  local profiles = require("cockpit.profiles")
  eq(profiles.names(), { "default" })
  eq(profiles.args("ask"), { "--model", "opus", "--effort", "medium" })
  eq(profiles.args("coordinator"), { "--model", "opus", "--effort", "medium" })
  eq(profiles.args("digest"), { "--model", "sonnet", "--effort", "low" })
end

T["coordinator args: barebones flags, own system prompt, resume first"] = function()
  local c = require("cockpit.coordinator")
  c.ensure_project()
  local args = c.args("sid-1")
  eq({ args[1], args[2] }, { "--resume", "sid-1" })
  eq(args[index(args, "--tools") + 1], "Bash,Read,Grep,Glob,Edit,Write")
  MiniTest.expect.no_equality(index(args, "--strict-mcp-config"), nil)
  MiniTest.expect.no_equality(index(args, "--disable-slash-commands"), nil)
  local prompt = table.concat(vim.fn.readfile(args[index(args, "--system-prompt-file") + 1]), "\n")
  eq(prompt:find("{{", 1, true), nil)
  MiniTest.expect.no_equality(prompt:find(c.CTL .. " agents", 1, true), nil)
  local settings = vim.json.decode(args[index(args, "--settings") + 1])
  MiniTest.expect.no_equality(index(settings.permissions.allow, "Bash(" .. c.CTL .. ":*)"), nil)
  eq(vim.fn.filereadable(c.scratchpad()), 1)
  eq(vim.fn.filereadable(c.todo()), 1)
  eq(require("cockpit.projects").get("cockpit").repos, { c.DIR })
end

T["rotation: only when idle and over the threshold"] = function()
  local c = require("cockpit.coordinator")
  eq(c.should_rotate(130000, "idle", 120000), true)
  eq(c.should_rotate(130000, "working", 120000), false)
  eq(c.should_rotate(130000, "done", 120000), true)
  eq(c.should_rotate(90000, "idle", 120000), false)
  eq(c.should_rotate(nil, "idle", 120000), false)
end

T["context: a file selection is a reference plus a capped excerpt"] = function()
  local path = vim.fn.tempname() .. ".txt"
  local lines = {}
  for i = 1, 60 do
    lines[i] = "local x" .. i .. " = " .. i
  end
  vim.fn.writefile(lines, path)
  vim.cmd.edit(path)
  local ctx = require("cockpit.context").gather({ l1 = 3, l2 = 50 })
  local text = table.concat(ctx.lines, "\n")
  eq(ctx.lines[1], "## Context")
  MiniTest.expect.no_equality(text:find(":3-50 (text)", 1, true), nil)
  MiniTest.expect.no_equality(text:find("local x3 = 3", 1, true), nil)
  eq(text:find("local x43 = 43", 1, true), nil) -- past the 40-line cap
  MiniTest.expect.no_equality(text:find("8 more selected lines", 1, true), nil)
end

T["composer split: question above the context heading, note line dropped"] = function()
  local q, c = require("cockpit.ask").split({
    "why is this slow?",
    "",
    "<!-- context below: edit or delete it, it is sent as-is -->",
    "## Context",
    "- file: ~/x.lua:3",
  })
  eq(q, "why is this slow?")
  eq(c, "## Context\n- file: ~/x.lua:3")
end

T["one-off argv: fork resumes with --fork-session, tools last"] = function()
  local ask = require("cockpit.ask")
  local argv = ask.argv({ fork = { session_id = "s-9" } })
  local r = index(argv, "--resume")
  eq({ argv[r + 1], argv[r + 2] }, { "s-9", "--fork-session" })
  local t = index(argv, "--allowedTools")
  eq(#argv - t, #ask.tools())
end

T["ctl: agents one line each; prompt refuses a working agent"] = function()
  live["eng-1"] = {
    name = "eng-1",
    target = "eng-1",
    status = "working",
    project = "lilt",
    pane_id = "p1",
    terminal_id = "t1",
  }
  local ctl = require("cockpit.ctl")
  local res = ctl.run({ "agents" })
  eq(res.code, 0)
  eq(res.out, "eng-1 · working · lilt · ctx ? · ")
  res = ctl.run({ "prompt", "eng-1", "do", "the", "thing" })
  eq(res.code, 1)
  eq(#prompts, 0)
  res = ctl.run({ "prompt", "eng-1", "--now", "do", "it" })
  eq({ res.code, prompts[1].text }, { 0, "do it" })
  eq(ctl.run({ "nope" }).code, 64)
end

T["ctl: purpose is recorded in the registry and shown by agents"] = function()
  local registry = require("cockpit.registry")
  require("cockpit.projects").save({ name = "lilt", repos = { vim.fn.tempname() } })
  registry.append("lilt", { name = "eng-1", terminal_id = "t1", session = "s1", prompt = "fix the flaky test" })
  live["eng-1"] = {
    name = "eng-1",
    target = "eng-1",
    status = "idle",
    project = "lilt",
    pane_id = "p1",
    terminal_id = "t1",
    session_id = "s1",
  }
  local ctl = require("cockpit.ctl")
  MiniTest.expect.no_equality(ctl.run({ "agents" }).out:find("for: prompt: fix the flaky test", 1, true), nil)
  eq(ctl.run({ "purpose", "eng-1", "owns", "ENG-1", "rollout" }).code, 0)
  eq(registry.by_terminal("lilt", "t1").purpose, "owns ENG-1 rollout")
  MiniTest.expect.no_equality(ctl.run({ "agents" }).out:find("for: owns ENG-1 rollout", 1, true), nil)
end

T["ctl: reply is a normal reply tagged relayed_by, verdicts go to the ledger"] = function()
  local store = require("cockpit.inbox.store")
  store.append(
    store.thread_file("t-1"),
    { kind = "message", from = "agent", title = "plan", text = "ok?", gate = true }
  )
  local ctl = require("cockpit.ctl")
  eq(ctl.run({ "reply", "t-1", "--verdict", "maybe", "x" }).code, 64)
  eq(ctl.run({ "reply", "t-1", "--verdict", "reject" }).code, 64) -- a reject needs a reason
  local res = ctl.run({ "reply", "t-1", "--verdict", "approve", "ship", "it" })
  eq(res.code, 0)
  local t = store.thread("t-1")
  local last = t.messages[#t.messages]
  eq({ last.kind, last.verdict, last.text, last.relayed_by }, { "reply", "approve", "ship it", "coordinator" })
  local ledger = vim.fn.readfile(store.path("feedback.jsonl"))
  eq(vim.json.decode(ledger[#ledger]).relayed_by, "coordinator")
  eq(ctl.run({ "reply", "nope", "hi" }).code, 1)
end

T["ctl: the coordinator won't kill itself"] = function()
  live["cockpit-coordinator"] =
    { name = "cockpit-coordinator", target = "cockpit-coordinator", project = "cockpit", terminal_id = "tc" }
  eq(require("cockpit.ctl").run({ "kill", "cockpit-coordinator" }).code, 1)
end

T["rail: the coordinator's project is pinned first"] = function()
  local nodes = require("cockpit.inbox.tree").build({
    threads = {},
    agents = {},
    registry = {},
    projects = { { name = "alpha", repos = {} }, { name = "cockpit", repos = {} } },
  })
  local order = {}
  for _, n in ipairs(nodes) do
    if n.kind == "project" then
      order[#order + 1] = n.name
    end
  end
  eq(order, { "cockpit", "alpha" })
end

return T
