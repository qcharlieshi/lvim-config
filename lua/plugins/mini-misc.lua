return {
  "echasnovski/mini.nvim",
  version = "*",
  config = function()
    require("mini.misc").setup()
    require("mini.misc").setup_termbg_sync()
  end,
}
