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
      separator = " > ",
      depth_limit = 15,
      depth_limit_indicator = "..",
      safe_output = true,
      click = true,
      highlight = true,
      lazy_update_context = true,
    })

    -- Setup navic on winbar
    -- vim.wo.winbar = "    %{%v:lua.require'nvim-navic'.get_location()%}    "
    -- vim.o.winbar = "                  "
  end,
}
