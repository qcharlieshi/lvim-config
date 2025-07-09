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
      icons_enabled = true,
      theme = "auto",
      -- color = { bg = colors.grey },
      component_separators = { left = "|", right = "|" },
      section_separators = { left = "", right = "" },
      globalstatus = vim.o.laststatus == 3,
      always_show_tabline = true,
      ignore_focus = {
        "dashboard",
        "alpha",
        "ministarter",
        "snacks_dashboard",
        "snacks_picker_list",
        "snacks_picker_input",
      },
    },
    sections = {
      lualine_a = { { "branch", separator = { left = "" }, right_padding = 2 } },
      lualine_b = {
        { separator = { left = "" }, color = { fg = colors.cyan }, "filename", path = 1, right_padding = 2 },
      },
      lualine_c = {
        {
          separator = { left = "" },
          color = { fg = colors.black },
          left_padding = 2,
          function()
            local navic = require("nvim-navic")
            if navic.is_available() then
              local width = vim.api.nvim_win_get_width(0)
              local depth_limit = math.floor(width / 5)
              return navic.get_location({ depth_limit = math.max(depth_limit, 1) })
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
    winbar = {
      lualine_a = {
        {
          show_modified_status = true,
          -- use_mode_colors = true,
          "buffers",
          mode = 2,
          max_length = vim.o.columns * 2 / 5,
          -- component_separators = { left = "", right = "" },
          buffers_color = {
            active = { fg = colors.grey, bg = colors.orange }, -- Color for active buffer.
            inactive = { fg = colors.cyan_dark, bg = colors.black }, -- Color for inactive buffer.
          },
          separator = { left = "", right = "", color = { fg = colors.red, bg = colors.orange } },
          symbols = {
            alternate_file = "",
            directory = "",
          },
          right_padding = 4,
        },
      },
      lualine_b = {
        {
          left_padding = 4,
          separator = { left = "" },
          color = { bg = colors.black, fg = colors.black },
          function()
            local navic = require("nvim-navic")
            if navic.is_available() then
              local width = vim.api.nvim_win_get_width(0)
              local depth_limit = math.floor(width / 20)
              return navic.get_location({ depth_limit = math.max(depth_limit, 1) })
            end
            return ""
          end,
          cond = function()
            local navic = require("nvim-navic")
            return navic.is_available()
          end,
        },
      },
      lualine_c = {},
      lualine_x = {},
      lualine_y = {},
      lualine_z = { { "tabs" } },
    },
  },
}
