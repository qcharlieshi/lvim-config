-- we needed this to allow for neovim to take up all the space in the terminal, may not be needed anymore
return {
  "echasnovski/mini.nvim",
  version = "*",
  config = function()
    require("mini.misc").setup()
    require("mini.misc").setup_termbg_sync()
  end,
}
