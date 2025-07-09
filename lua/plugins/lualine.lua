local colors = {
  blue = "#80a0ff",
  cyan = "#79dac8",
  cyan_dark = "#4a9b8e",
  black = "#080808",
  white = "#c6c6c6",
  red = "#ff5189",
  violet = "#d183e8",
  grey = "#303030",
  orange = "#ff9500",
}

return {
  "nvim-lualine/lualine.nvim",
  dependencies = { "nvim-tree/nvim-web-devicons", "SmiteshP/nvim-navic" },
  opts = {
    options = {
      theme = "auto",
      globalstatus = vim.o.laststatus == 3,
      disabled_filetypes = {
        statusline = { "dashboard", "alpha", "ministarter", "snacks_dashboard", "snacks_picker_list" },
      },
    },
    sections = {
      lualine_a = { { "branch", separator = { left = "" }, right_padding = 2 } },
      lualine_b = {
        { separator = { left = "" }, color = { fg = colors.cyan }, "filename", path = 1, right_padding = 2 },
        -- { , separator = { left = "", right = "" }, color = { bg = colors.cyan, fg = colors.grey } },
      },
      lualine_c = {
        {
          separator = { left = "" },
          color = { fg = colors.black },
          left_padding = 2,
          function()
            local navic = require("nvim-navic")
            if navic.is_available() then
              return navic.get_location({ depth_limit = 6 })
            end
            return ""
          end,
          cond = function()
            local navic = require("nvim-navic")
            return navic.is_available()
          end,
        },
        "diagnostics",
      },
      lualine_y = {
        { "progress", color = { bg = colors.orange, fg = colors.grey }, separator = { left = "" } },
        { "location", color = { bg = colors.orange, fg = colors.grey } },
      },
      lualine_z = {
        {
          separator = { left = "", right = "" },
          left_padding = 2,
          "filetype",
          color = { bg = colors.cyan_dark, fg = colors.grey },
        },
      },
    },
    inactive_sections = {
      lualine_a = { "filename" },
      lualine_b = {},
      lualine_c = {},
      lualine_x = {},
      lualine_y = {},
      lualine_z = { "location" },
    },
  },
}
