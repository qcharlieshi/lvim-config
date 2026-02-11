local dbAnim = require("dashboardAnimation")
local weather = require("weather")

-- Start with fallback weather (instant, no blocking)
local weather_text = table.concat(weather.get_weather_section(), "\n")
local weather_fetch_started = false

-- Helper to disable folding in dashboard
local function disable_dashboard_folding(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  -- Only apply to dashboard buffers
  local ft_ok, filetype = pcall(vim.api.nvim_buf_get_option, bufnr, "filetype")
  if not ft_ok or filetype ~= "snacks_dashboard" then
    return
  end

  -- Get all windows showing this buffer
  local ok, wins = pcall(vim.fn.win_findbuf, bufnr)
  if not ok or not wins then
    return
  end

  for _, win in ipairs(wins) do
    if vim.api.nvim_win_is_valid(win) then
      -- Set window-local options
      pcall(vim.api.nvim_set_option_value, "foldenable", false, { win = win })
      pcall(vim.api.nvim_set_option_value, "foldcolumn", "0", { win = win })
      pcall(vim.api.nvim_set_option_value, "foldlevel", 99, { win = win })
    end
  end

  -- Set buffer-local options
  pcall(vim.api.nvim_set_option_value, "foldmethod", "manual", { buf = bufnr })

  -- Clear any existing folds (only if we're in that buffer)
  if bufnr == vim.api.nvim_get_current_buf() then
    pcall(vim.cmd, "normal! zE")
  end
end

-- Helper function to fetch and update weather
local function fetch_and_update_weather()
  if weather_fetch_started then
    return -- Already fetching, don't start another request
  end
  weather_fetch_started = true

  weather.fetch_weather_async(function(weather_data)
    local lines = vim.split(weather_data, "\n")
    -- Remove empty lines at the end
    while #lines > 0 and lines[#lines]:match("^%s*$") do
      table.remove(lines)
    end
    weather_text = table.concat(lines, "\n")
    weather_fetch_started = false

    -- Update dashboard if it's currently open
    local current_buf = vim.api.nvim_get_current_buf()
    local ft_ok, filetype = pcall(vim.api.nvim_buf_get_option, current_buf, "filetype")

    if ft_ok and filetype == "snacks_dashboard" then
      local snacks_ok, snacks = pcall(require, "snacks")
      if snacks_ok and snacks.dashboard then
        pcall(snacks.dashboard.update)
        -- Ensure folding stays disabled after update
        vim.schedule(function()
          if current_buf and vim.api.nvim_buf_is_valid(current_buf) then
            disable_dashboard_folding(current_buf)
          end
        end)
      end
    end
  end)
end

-- Start async fetch immediately (won't block)
fetch_and_update_weather()

vim.api.nvim_create_autocmd("FileType", {
  pattern = "snacks_dashboard",
  callback = function(ev)
    -- Reset animation state when dashboard opens
    dbAnim.shouldPlayAnimation = true
    dbAnim.asciiImg = dbAnim.frames[1]

    -- Disable folding
    disable_dashboard_folding(ev.buf)
  end,
})

-- Also catch BufWinEnter and WinEnter to ensure folding stays disabled
vim.api.nvim_create_autocmd({ "BufWinEnter", "WinEnter" }, {
  pattern = "*",
  callback = function(ev)
    if vim.bo[ev.buf].filetype == "snacks_dashboard" then
      vim.schedule(function()
        disable_dashboard_folding(ev.buf)
      end)
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
        row = nil,
        col = nil,
        pane_gap = 4,
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
