return {
  "emmanueltouzery/apidocs.nvim",
  dependencies = {
    "folke/snacks.nvim",
  },
  cmd = { "ApidocsSearch", "ApidocsInstall", "ApidocsOpen", "ApidocsUninstall" },
  config = function()
    require("apidocs").setup({
      picker = "snacks", -- Use snacks picker since you have it
    })
  end,
  keys = {
    { "<leader>kd", "<cmd>ApidocsOpen<cr>", desc = "Search Api Doc" },
    { "<leader>ki", "<cmd>ApidocsInstall<cr>", desc = "Install Api Docs" },
    { "<leader>ks", "<cmd>ApidocsSearch<cr>", desc = "Search Api Docs" },
    { "<leader>ku", "<cmd>ApidocsUninstall<cr>", desc = "Uninstall Api Docs" },
  },
}
