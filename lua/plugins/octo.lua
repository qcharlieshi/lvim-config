return {
  "pwntester/octo.nvim",
  requires = {
    "nvim-lua/plenary.nvim",
    -- "nvim-telescope/telescope.nvim",
    -- OR 'ibhagwan/fzf-lua',
    "folke/snacks.nvim",
    "nvim-tree/nvim-web-devicons",
  },
  config = function()
    require("octo").setup({
      use_local_fs = true,
    })
  end,
}
