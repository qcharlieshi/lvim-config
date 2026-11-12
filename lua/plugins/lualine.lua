local colors = require("config.colors").colors
local perf = require("config.performance")

-- Cached git branch with TTL to avoid shelling out on every statusline redraw
local git_branch_cache = { branch = "", cwd = "", last_fetch = 0 }
local GIT_BRANCH_TTL_MS = 2000 -- only re-fetch every 2 seconds

local function get_git_branch()
  local cwd = vim.fn.getcwd()
  local now = vim.loop.now()
  if git_branch_cache.cwd == cwd and (now - git_branch_cache.last_fetch) < GIT_BRANCH_TTL_MS then
    return git_branch_cache.branch
  end
  local branch = vim.fn.system("git branch --show-current 2>/dev/null"):gsub("\n", "")
  git_branch_cache.branch = branch
  git_branch_cache.cwd = cwd
  git_branch_cache.last_fetch = now
  return branch
end

local function tabline_clock()
  return "  " .. os.date("%a %b %d • %R")
end

local function tabline_spacer_width()
  return math.floor(vim.o.columns / 12)
end

-- Budget for the buffers component = whatever the rest of the tabline leaves over.
-- Overshooting makes nvim truncate at lualine's `%<`, clipping the left cap and first buffer.
local function tabline_buffers_max_length()
  local clock_w = vim.fn.strdisplaywidth(tabline_clock()) + 3 -- padding + cap
  local tabs_w = vim.fn.tabpagenr("$") * 4 + 3 -- " n " + separators + cap
  -- lualine appends "..." markers + caps after its max_length check, and counts %Z{} placeholders oddly
  local slack = 8
  return math.max(20, vim.o.columns - clock_w - tabs_w - 2 * tabline_spacer_width() - slack)
end

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
              local branch = get_git_branch()
              if branch == "" then
                return ""
              end

              local repo_name = vim.fn.fnamemodify(vim.fn.getcwd(), ":t")

              return "" .. " " .. repo_name .. "/" .. branch .. " "
            end,
            -- separator = { left = "" },
          },
          {
            function()
              local gs = vim.b.gitsigns_status_dict
              if not gs or not gs.added or gs.added == 0 then
                return ""
              end
              return " " .. icons.git.added .. gs.added
            end,
            color = { fg = "#2a6b4d" },
          },
          {
            function()
              local gs = vim.b.gitsigns_status_dict
              if not gs or not gs.changed or gs.changed == 0 then
                return ""
              end
              return " " .. icons.git.modified .. gs.changed
            end,
            color = { fg = "#8b6914" },
          },
          {
            function()
              local gs = vim.b.gitsigns_status_dict
              if not gs or not gs.removed or gs.removed == 0 then
                return ""
              end
              return " " .. icons.git.removed .. gs.removed
            end,
            color = { fg = "#8b2635" },
          },
        },
        lualine_b = {
          {
            separator = { left = "" },
            color = { fg = colors.cyan },
            "filename",
            file_status = true,
            path = 1,
            right_padding = 2,
            shorting_target = 40,
            -- symbols = {
            --   modified = "[+]", -- Text to show when the file is modified.
            --   readonly = "[-]", -- Text to show when the file is non-modifiable or readonly.
            --   unnamed = "[No Name]", -- Text to show for unnamed buffers.
            --   newfile = "[New]", -- Text to show for newly created file before first write
            -- },
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
          -- Performance monitoring (progressively hidden at narrow widths)
          {
            function()
              return " " .. perf.fps_status()
            end,
            color = { fg = colors.cyan },
            cond = function()
              return perf.enabled and vim.o.columns >= 100 and perf.fps_status() ~= ""
            end,
          },
          {
            function()
              return "⏱ " .. perf.latency_status()
            end,
            color = perf.get_latency_color,
            cond = function()
              return perf.enabled and vim.o.columns >= 120
            end,
          },
          {
            function()
              return "⌨ " .. perf.input_lag_status()
            end,
            color = perf.get_input_lag_color,
            cond = function()
              return perf.enabled and vim.o.columns >= 140
            end,
          },
          {
            function()
              return "📂 " .. perf.buffer_load_status()
            end,
            color = perf.get_buffer_load_color,
            cond = function()
              return perf.enabled and vim.o.columns >= 160
            end,
          },
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
        },
        lualine_y = {
          { "progress", color = { bg = colors.orange, fg = colors.grey }, separator = { left = "" } },
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
            separator = { left = "" },
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
            tabline_clock,
            separator = { right = "" },
          },
          {
            function()
              return string.rep(" ", tabline_spacer_width())
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
            -- cockpit deliverable buffers show as their bare file name
            -- ctx.bufnr exists, but lualine pre-shortens `name`, so match on the real buffer name
            fmt = function(name, ctx)
              local full = ctx and ctx.bufnr and vim.api.nvim_buf_get_name(ctx.bufnr) or name
              return full:match("^cockpit://inbox/[^/]+/%x+/(.+)$") or name
            end,
            max_length = tabline_buffers_max_length,
            -- Adds seperator between each buffer but right doesn't seem to show up?
            -- component_separators = { left = "", right = "" },
            buffers_color = {
              active = { fg = colors.grey, bg = colors.orange }, -- Color for active buffer.
              inactive = { fg = colors.grey, bg = colors.cyan_dark }, -- Color for inactive buffer.
            },
            separator = { left = "", right = "" },
            -- symbols = {
            --   alternate_file = "",
            --   directory = "",
            -- },
            left_padding = 2,
            right_padding = 4,
          },
          -- {
          --   function()
          --     local gitsigns = vim.b.gitsigns_status_dict
          --     if not gitsigns then
          --       return ""
          --     end
          --
          --     local diff_str = ""
          --     if gitsigns.added and gitsigns.added > 0 then
          --       diff_str = diff_str .. " " .. icons.git.added .. gitsigns.added
          --     end
          --     if gitsigns.changed and gitsigns.changed > 0 then
          --       diff_str = diff_str .. " " .. icons.git.modified .. gitsigns.changed
          --     end
          --     if gitsigns.removed and gitsigns.removed > 0 then
          --       diff_str = diff_str .. " " .. icons.git.removed .. gitsigns.removed
          --     end
          --     return diff_str
          --   end,
          --   color = { fg = colors.cyan_dark, bg = colors.orange },
          -- },
        },
        lualine_x = {},
        lualine_y = {},
        lualine_z = {
          {
            function()
              return string.rep(" ", tabline_spacer_width())
            end,
            color = { bg = "NONE", fg = "NONE" },
          },
          {
            "tabs",
            separator = { left = "" },
            -- cond = function()
            --   return #vim.fn.gettabinfo() > 1
            -- end,
          },
        },
      },

      -- winbar = " ",
      extensions = { "lazy", "fzf" },
    })
  end,
}
