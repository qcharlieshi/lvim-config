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
  purple = "#1e2030",
}

return {
  "nvim-lualine/lualine.nvim",
  dependencies = { "nvim-tree/nvim-web-devicons", "SmiteshP/nvim-navic" },
  config = function()
    -- PERF: we don't need this lualine require madness 🤷
    local lualine_require = require("lualine_require")
    lualine_require.require = require

    local icons = LazyVim.config.icons

    vim.o.laststatus = vim.g.lualine_laststatus

    require("lualine").setup({
      options = {
        icons_enabled = true,
        theme = "auto",
        component_separators = { left = "|", right = "|" },
        section_separators = { left = "", right = "" },
        -- always_show_tabline = true,
        ignore_focus = {
          "dashboard",
          "alpha",
          "ministarter",
          "snacks_dashboard",
          "snacks_picker_list",
          "snacks_picker_input",
          "snacks_terminal",
          "snacks_picker",
          "claude",
          "terminal",
        },
      },

      -- BOTTOM BAR
      sections = {
        lualine_a = { { "branch", separator = { left = "" }, right_padding = 2 } },
        lualine_b = {
          {
            separator = { left = "" },
            color = { fg = colors.cyan },
            "filename",
            file_status = true,
            path = 1,
            right_padding = 2,
            shorting_target = 40,
            symbols = {
              modified = "[+]", -- Text to show when the file is modified.
              readonly = "[-]", -- Text to show when the file is non-modifiable or readonly.
              unnamed = "[No Name]", -- Text to show for unnamed buffers.
              newfile = "[New]", -- Text to show for newly created file before first write
            },
          },
        },
        lualine_c = {
          -- {
          -- draw_empty = true,
          -- separator = { left = "" },
          -- color = { fg = colors.black },
          -- left_padding = 2,
          --   function()
          --     local navic = require("nvim-navic")
          --     if navic.is_available() then
          --       local width = vim.o.columns
          --       local depth_limit = math.floor(width / 20)
          --       return navic.get_location({ depth_limit = math.max(depth_limit, 1) })
          --     end
          --     return ""
          --   end,
          --   cond = function()
          --     local navic = require("nvim-navic")
          --     return navic.is_available()
          --   end,
          -- },

          {
            draw_empty = true,
            separator = { left = "" },
            color = { fg = colors.black },
            left_padding = 2,
            "diagnostics",
          },
        },
        lualine_x = {
          Snacks.profiler.status(),
        -- stylua: ignore
        {
          function() return require("noice").api.status.command.get() end,
          cond = function() return package.loaded["noice"] and require("noice").api.status.command.has() end,
          color = function() return { fg = Snacks.util.color("Statement") } end,
        },
        -- stylua: ignore
        {
          function() return require("noice").api.status.mode.get() end,
          cond = function() return package.loaded["noice"] and require("noice").api.status.mode.has() end,
          color = function() return { fg = Snacks.util.color("Constant") } end,
        },
        -- stylua: ignore
        {
          function() return "  " .. require("dap").status() end,
          cond = function() return package.loaded["dap"] and require("dap").status() ~= "" end,
          color = function() return { fg = Snacks.util.color("Debug") } end,
        },
        -- stylua: ignore
        {
          require("lazy.status").updates,
          cond = require("lazy.status").has_updates,
          color = function() return { fg = Snacks.util.color("Special") } end,
        },
          {
            "diff",
            symbols = {
              added = icons.git.added,
              modified = icons.git.modified,
              removed = icons.git.removed,
            },
            -- source = function()
            --   local gitsigns = vim.b.gitsigns_status_dict
            --   if gitsigns then
            --     return {
            --       added = gitsigns.added,
            --       modified = gitsigns.changed,
            --       removed = gitsigns.removed,
            --     }
            --   end
            --   return { added = 0, modified = 0, removed = 0 }
            -- end,
          },
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
            colored = false,
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

      -- TOP BAR
      tabline = {
        lualine_a = {
          {
            -- use_mode_colors = true,
            "buffers",
            show_modified_status = true,
            mode = 2,
            max_length = function()
              return vim.o.columns * 4 / 5 -- Original length for single window
            end,
            -- component_separators = { left = "", right = "" },
            buffers_color = {
              active = { fg = colors.grey, bg = colors.orange }, -- Color for active buffer.
              inactive = { fg = colors.cyan_dark, bg = colors.black }, -- Color for inactive buffer.
            },
            separator = { left = "", right = "", color = { fg = colors.red, bg = colors.orange } },
            -- symbols = {
            --   alternate_file = "",
            --   directory = "",
            -- },
            right_padding = 4,
          },
        },
        lualine_b = {
          -- {
          --   left_padding = 4,
          --   separator = { left = "" },
          --   color = { bg = colors.purple, fg = colors.black },
          --   function()
          --     local navic = require("nvim-navic")
          --     if navic.is_available() then
          --       local width = vim.api.nvim_win_get_width(0)
          --       local depth_limit = math.floor(width / 20)
          --       return navic.get_location({ depth_limit = math.max(depth_limit, 1) })
          --     end
          --     return ""
          --   end,
          --   cond = function()
          --     local navic = require("nvim-navic")
          --     return navic.is_available()
          --   end,
          -- },
        },
        lualine_c = {},
        lualine_x = {},
        lualine_y = {},
        lualine_z = {
          {
            "tabs",
            cond = function()
              return #vim.fn.gettabinfo() > 1
            end,
          },
        },
      },

      -- winbar = " ",
      extensions = { "lazy", "fzf" },
    })
  end,
}
