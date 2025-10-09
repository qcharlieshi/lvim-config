local dbAnim = require("dashboardAnimation")
local weather = require("weather")

-- Start with loading message, fetch async
local weather_text = "   Loading weather..."
local weather_loaded = false

-- Fetch weather asynchronously on plugin load
vim.defer_fn(function()
  weather_text = table.concat(weather.get_weather_section(), "\n")
  weather_loaded = true
  -- Update dashboard if it's currently open
  if vim.bo.filetype == "snacks_dashboard" then
    vim.schedule(function()
      require("snacks").dashboard.update()
    end)
  end
end, 0)

vim.api.nvim_create_autocmd("FileType", {
  pattern = "snacks_dashboard",
  callback = function()
    -- Reset animation state when dashboard opens
    dbAnim.shouldPlayAnimation = true
    dbAnim.asciiImg = dbAnim.frames[1]

    -- Only re-fetch if weather hasn't been loaded yet or if it's been a while
    if not weather_loaded then
      vim.defer_fn(function()
        weather_text = table.concat(weather.get_weather_section(), "\n")
        weather_loaded = true
        vim.schedule(function()
          require("snacks").dashboard.update()
        end)
      end, 0)
    end
  end,
})

return {
  {
    "folke/snacks.nvim",
    init = function()
      vim.defer_fn(function()
        dbAnim.theAnimation(dbAnim.theAnimation)
      end, 100)
    end,
    opts = {
      dashboard = {
        width = 80,
        row = nil, -- center vertically
        col = nil, -- center horizontally
        pane_gap = 4, -- gap between panes
        autokeys = "1234567890abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ",
        on_close = function()
          dbAnim.shouldPlayAnimation = false
        end,
        preset = {
          pick = function(cmd, opts)
            return LazyVim.pick(cmd, opts)()
          end,
          header = [[]],
        },
        sections = {
          {
            section = "header",
            padding = 1,
            function()
              return { header = dbAnim.asciiImg }
            end,
          },
          {
            padding = 2,
            function()
              return { header = weather_text }
            end,
          },
          { section = "keys", gap = 1, padding = 1 },
          { section = "startup", padding = 1 },
        },
        keys = {
          {
            icon = " ",
            key = "f",
            desc = "Find File",
            action = function()
              Snacks.dashboard.pick("files")
              dbAnim.shouldPlayAnimation = false
            end,
          },
          {
            icon = " ",
            key = "n",
            desc = "New File",
            action = function()
              vim.cmd("ene | startinsert")
              dbAnim.shouldPlayAnimation = false
            end,
          },
          {
            icon = " ",
            key = "g",
            desc = "Find Text",
            action = function()
              Snacks.dashboard.pick("live_grep")
              dbAnim.shouldPlayAnimation = false
            end,
          },
          { icon = " ", key = "r", desc = "Recent Files", action = ":lua Snacks.dashboard.pick('oldfiles')" },
          {
            icon = " ",
            key = "c",
            desc = "Config",
            action = ":lua Snacks.dashboard.pick('files', {cwd = vim.fn.stdpath('config')})",
          },
          { icon = " ", key = "s", desc = "Restore Session", section = "session" },
          { icon = "󰒲 ", key = "l", desc = "Lazy", action = ":Lazy", enabled = package.loaded.lazy ~= nil },
          { icon = " ", key = "q", desc = "Quit", action = ":qa" },
        },
      },
      picker = {
        layout = { -- the layout config
          fullscreen = true,
        },
        sources = {
          explorer = {
            focus = "list",
            auto_close = true,
            jump = { close = false },
            layout = { fullscreen = false },
            preview = { true },
          },
        },
        debug = {
          grep = true,
          files = true,
        },
        grep = {
          debug = true,
          finder = "rg",
          supports_args = true,
          live = true,
          -- TODO: figure out globs, they can't be done (?)
          args = {
            "--hidden",
            "--follow",
            "--glob=!.git",
            "--glob=!node_modules",
            "--glob=!*.lock",
            "--multiline",
          },
          rg_glob = true,
        },
        matcher = {
          fuzzy = true,
          smartcase = true,
          ignorecase = true,
          sort_empty = false,
          filename_bonus = true, -- give bonus for matching file names (last part of the path)
          file_pos = true, -- support patterns like `file:line:col` and `file:line`
          -- the bonusses below, possibly require string concatenation and path normalization,
          -- so this can have a performance impact for large lists and increase memory usage
          cwd_bonus = true, -- give bonus for matching files in the cwd
          frecency = true, -- frecency bonus, both frequency and recency
          live = true,
          buffer = true,
        },
        files = {
          finder = "fd",
        },
        -- Add custom actions.
        -- actions = {
        --   open_left = open_leftmost,
        --   open_right = open_leftmost,
        -- },

        -- Bind your custom action to a hotkey in the input window key mappings.
        -- win = {
        --   input = {
        --     keys = {
        --       ["<C-w>h"] = "open_left", -- or choose your preferred key combo
        --     },
        --   },
        -- },
      },
    },
  },
}
