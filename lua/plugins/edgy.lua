return {
  "folke/edgy.nvim",
  event = "VeryLazy",
  opts = {
    right = {
      {
        title = "Claude Code",
        ft = "snacks_terminal",
        size = { width = 0.7 }, -- 40% of screen width
        filter = function(buf, win)
          return vim.api.nvim_buf_get_name(buf):find("ClaudeCode") ~= nil
        end,
      },
    },
  },
}
