return {
  "SmiteshP/nvim-navic",
  dependencies = "neovim/nvim-lspconfig",
  config = function()
    local navic = require("nvim-navic")
    local icons = require("lazyvim.config").icons.kinds

    navic.setup({
      icons = icons,
      lsp = {
        auto_attach = true,
        preference = nil,
      },
      highlight = true,
      separator = " > ",
      depth_limit = 5,
      depth_limit_indicator = "..",
      safe_output = true,
      lazy_update_context = false,
      click = true,
    })
  end,
}
