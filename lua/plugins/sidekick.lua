-- Helper: get or create an attached claude session, bypassing the picker
local function with_claude(cb)
  local Session = require("sidekick.cli.session")
  local State = require("sidekick.cli.state")

  -- Check for already attached claude session
  local attached = State.get({ name = "claude", attached = true })
  if #attached > 0 then
    return cb(attached[1])
  end

  -- Not attached yet — ensure backends are registered, then create
  Session.setup()
  local session = Session.new({ tool = "claude" })
  session = Session.attach(session)
  local state = State.get_state(session)
  cb(state)
end

return {
  {
    "folke/sidekick.nvim",
    keys = {
      {
        "<leader>aa",
        function()
          with_claude(function(state)
            if state.terminal then
              state.terminal:toggle()
              if state.terminal:is_open() then
                state.terminal:focus()
              end
            end
          end)
        end,
        desc = "Sidekick Toggle Claude",
      },
      {
        "<leader>at",
        function() require("sidekick.cli").send({ msg = "{this}", name = "claude" }) end,
        mode = { "x", "n" },
        desc = "Send This",
      },
      {
        "<leader>af",
        function() require("sidekick.cli").send({ msg = "{file}", name = "claude" }) end,
        desc = "Send File",
      },
      {
        "<leader>ab",
        function() require("sidekick.cli").send({ msg = "{buffers}", name = "claude" }) end,
        desc = "Send Buffers",
      },
      {
        "<leader>av",
        function() require("sidekick.cli").send({ msg = "{selection}", name = "claude" }) end,
        mode = { "x" },
        desc = "Send Visual Selection",
      },
      {
        "<leader>ap",
        function() require("sidekick.cli").prompt({ name = "claude" }) end,
        mode = { "n", "x" },
        desc = "Sidekick Select Prompt",
      },
      {
        "<leader>ar",
        function()
          with_claude(function(state)
            if state.session then
              state.session:send("--resume\n")
            end
          end)
        end,
        desc = "Resume Claude",
      },
      {
        "<leader>aC",
        function()
          with_claude(function(state)
            if state.session then
              state.session:send("--continue\n")
            end
          end)
        end,
        desc = "Continue Claude",
      },
      {
        "<leader>ac",
        function()
          with_claude(function(state)
            if state.terminal then
              state.terminal:toggle()
              if state.terminal:is_open() then
                state.terminal:focus()
              end
            end
          end)
        end,
        desc = "Toggle Claude",
      },
      {
        "<leader>ad",
        function() require("sidekick.cli").close({ name = "claude" }) end,
        desc = "Detach Claude",
      },
      {
        "<c-.>",
        function()
          with_claude(function(state)
            if state.terminal then
              state.terminal:toggle()
              if state.terminal:is_open() then
                state.terminal:focus()
              end
            end
          end)
        end,
        desc = "Sidekick Toggle",
        mode = { "n", "t", "i", "x" },
      },
    },
    opts = {
      cli = {
        mux = {
          enabled = true,
          backend = "tmux",
          create = "split",
          split = {
            vertical = true,
            size = 0.5,
          },
        },
      },
    },
  },
}
