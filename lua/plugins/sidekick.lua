return {
  {
    "folke/sidekick.nvim",
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
