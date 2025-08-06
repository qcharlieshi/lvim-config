local colors = require("config.colors").colors

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
        disabled_filetypes = {},
        globalstatus = true,
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
          "edgy",
        },
      },

      -- BOTTOM BAR
      sections = {
        lualine_a = {
          {
            function()
              local branch = vim.b.gitsigns_head
                or vim.fn.system("git branch --show-current 2>/dev/null"):gsub("\n", "")
              if branch == "" then
                return ""
              end

              local repo_name = vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
              return "" .. " " .. repo_name .. "/" .. branch
            end,
            separator = { left = "" },
            right_padding = 2,
          },
        },
        lualine_b = {
          {
            separator = { left = "" },
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
          -- separator = { left = "" },
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
            separator = { left = "" },
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
          function() return "  " .. require("dap").status() end,
          cond = function() return package.loaded["dap"] and require("dap").status() ~= "" end,
          color = function() return { fg = Snacks.util.color("Debug") } end,
        },
        -- stylua: ignore
        {
          require("lazy.status").updates,
          cond = require("lazy.status").has_updates,
          color = function() return { fg = Snacks.util.color("Special") } end,
        },
        },
        lualine_y = {
          { "progress", color = { bg = colors.orange, fg = colors.grey }, separator = { left = "" } },
          { "location", color = { bg = colors.orange, fg = colors.grey } },
          {
            function()
              return vim.fn.line("$") .. "L"
            end,
            color = { bg = colors.orange, fg = colors.grey },
          },
        },
        lualine_z = {
          {
            separator = { left = "", right = "" },
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
            function()
              return string.rep(" ", math.floor(vim.o.columns / 6))
            end,
            color = { bg = "NONE", fg = "NONE" },
          },
        },
        lualine_b = {},
        lualine_c = {
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
          {
            function()
              local gitsigns = vim.b.gitsigns_status_dict
              if not gitsigns then
                return ""
              end

              local diff_str = ""
              if gitsigns.added and gitsigns.added > 0 then
                diff_str = diff_str .. " " .. icons.git.added .. gitsigns.added
              end
              if gitsigns.changed and gitsigns.changed > 0 then
                diff_str = diff_str .. " " .. icons.git.modified .. gitsigns.changed
              end
              if gitsigns.removed and gitsigns.removed > 0 then
                diff_str = diff_str .. " " .. icons.git.removed .. gitsigns.removed
              end
              return diff_str
            end,
            color = { fg = colors.cyan_dark, bg = colors.orange },
          },
        },
        lualine_x = {},
        lualine_y = {},
        lualine_z = {
          {
            "tabs",
            cond = function()
              return #vim.fn.gettabinfo() > 1
            end,
          },
          {
            function()
              return string.rep(" ", math.floor(vim.o.columns / 6))
            end,
            color = { bg = "NONE", fg = "NONE" },
          },
        },
      },

      -- winbar = " ",
      extensions = { "lazy", "fzf" },
    })
  end,
}
