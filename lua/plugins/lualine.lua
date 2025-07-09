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
    -- Create thick top border for statusline
    -- vim.api.nvim_set_hl(0, "StatusLineTopBorder", { fg = colors.cyan, bg = colors.black })
    -- vim.opt.laststatus = 2
    --
    -- -- Add the border character above statusline
    -- vim.api.nvim_create_autocmd("VimEnter", {
    --   callback = function()
    --     vim.o.fillchars = vim.o.fillchars .. ",stl:━"
    --   end,
    -- })
    -- PERF: we don't need this lualine require madness 🤷
    local lualine_require = require("lualine_require")
    lualine_require.require = require

    local icons = LazyVim.config.icons

    vim.o.laststatus = vim.g.lualine_laststatus

    require("lualine").setup({
      options = {
        icons_enabled = true,
        theme = "auto",
        component_separators = { left = "║", right = "║" },
        section_separators = { left = "", right = "" },
        -- globalstatus = vim.o.laststatus == 3,
        always_show_tabline = true,
        padding = { left = 1, right = 1 },
        ignore_focus = {
          "dashboard",
          "alpha",
          "ministarter",
          "snacks_dashboard",
          "snacks_picker_list",
          "snacks_picker_input",
          "snacks_terminal",
          "terminal",
        },
      },
      sections = {
        lualine_a = { { "branch", separator = { left = "" }, right_padding = 2 } },
        lualine_b = {
          { separator = { left = "" }, color = { fg = colors.cyan }, "filename", path = 1, right_padding = 2 },
        },
        lualine_c = {
          {
            draw_empty = true,
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
            source = function()
              local gitsigns = vim.b.gitsigns_status_dict
              if gitsigns then
                return {
                  added = gitsigns.added,
                  modified = gitsigns.changed,
                  removed = gitsigns.removed,
                }
              end
              return { added = 0, modified = 0, removed = 0 }
            end,
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
            separator = { left = "", right = "║" },
            color = { bg = colors.purple, fg = colors.black },
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
      extensions = { "lazy", "fzf" },
    })
  end,
}
