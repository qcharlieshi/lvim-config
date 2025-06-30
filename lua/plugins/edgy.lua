return {
  "folke/edgy.nvim",
  event = "VeryLazy",
  opts = {
    right = {
      {
        title = "Claude Code",
        ft = "snacks_terminal",
        -- only reason we have this config is so the claue code sidebar it opens in default
        -- to a more reasonable size
        size = { width = 0.7 }, -- 70% of screen width
        filter = function(buf, win)
          return vim.api.nvim_buf_get_name(buf):find("ClaudeCode") ~= nil
        end,
      },
    },
  },
}
