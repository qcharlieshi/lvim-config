local dbAnim = require("dashboardAnimation")
local weather = require("weather")

-- Persistent picker toggle state (survives picker close/reopen within session)
local picker_state = { hidden = false, ignored = false }

-- Start with fallback weather (instant, no blocking)
local weather_text = table.concat(weather.get_weather_section(), "\n")
local weather_fetch_started = false

-- ── Git terminal section helper ──
-- Synchronous but with tight timeout — rev-parse is local-only (~5ms), no network.
-- The original vim.fn.system() had no timeout; this caps at 50ms to avoid hangs.
local git_result = vim.system({ "git", "rev-parse", "--is-inside-work-tree" }, { text = true }):wait(50)
local in_git = git_result and git_result.code == 0 and (git_result.stdout or ""):find("true") ~= nil
local wide_enough = vim.o.columns >= 142 -- 68*2 + 6 = two-pane minimum

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

      -- Wrap Snacks.picker.pick to inject persisted hidden/ignored state
      vim.api.nvim_create_autocmd("User", {
        pattern = "VeryLazy",
        once = true,
        callback = function()
          vim.schedule(function()
            -- Patch explorer diagnostics to guard against wiped buffers (hbac compat)
            local diag_ok, explorer_diag = pcall(require, "snacks.explorer.diagnostics")
            if diag_ok and explorer_diag then
              local orig_update = explorer_diag.update
              explorer_diag.update = function(cwd)
                -- Purge diagnostics referencing invalid buffers before the original runs
                local ns_list = vim.diagnostic.get()
                for i = #ns_list, 1, -1 do
                  local d = ns_list[i]
                  if d.bufnr and not vim.api.nvim_buf_is_valid(d.bufnr) then
                    pcall(vim.diagnostic.reset, nil, d.bufnr)
                  end
                end
                return orig_update(cwd)
              end
            end

            if not (Snacks and Snacks.picker) then
              return
            end
            local orig_pick = Snacks.picker.pick
            Snacks.picker.pick = function(source, opts)
              -- When called with a single table arg (e.g. vim.ui.select),
              -- source IS the opts table — don't split into two args
              if type(source) == "table" then
                if source.hidden == nil then
                  source.hidden = picker_state.hidden
                end
                if source.ignored == nil then
                  source.ignored = picker_state.ignored
                end
                return orig_pick(source)
              end
              opts = opts or {}
              if opts.hidden == nil then
                opts.hidden = picker_state.hidden
              end
              if opts.ignored == nil then
                opts.ignored = picker_state.ignored
              end
              return orig_pick(source, opts)
            end
          end)
        end,
      })
    end,
    opts = {
      dashboard = {
        width = 68,
        row = nil,
        col = nil,
        pane_gap = 6,
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
          -- ── Left Pane (1) ──
          {
            section = "header",
            padding = 1,
            function()
              return { header = dbAnim.asciiImg }
            end,
          },
          { section = "keys", gap = 1, padding = 1 },
          { section = "startup", padding = 1 },

          -- ── Right Pane (2) ──
          {
            pane = 2,
            padding = 1,
            enabled = wide_enough,
            function()
              return { header = weather_text }
            end,
          },
          {
            pane = 2,
            icon = " ",
            title = "Branch / Tag",
            section = "terminal",
            cmd = "printf ' %s\\n %s' \"$(git branch --show-current)\" \"$(git describe --tags --abbrev=0 2>/dev/null || echo 'no tag')\"",
            height = 3,
            padding = 1,
            ttl = 5 * 60,
            indent = 3,
            enabled = in_git and wide_enough,
          },
          {
            pane = 2,
            icon = " ",
            title = "Git Status",
            section = "terminal",
            cmd = "git status --short --branch --renames || echo ' clean'",
            height = 8,
            padding = 1,
            ttl = 5 * 60,
            indent = 3,
            enabled = in_git and wide_enough,
          },
          {
            pane = 2,
            icon = " ",
            title = "Open PRs",
            section = "terminal",
            cmd = "gh pr list --limit 5 --author @me 2>/dev/null || echo ' none'",
            height = 7,
            padding = 1,
            ttl = 5 * 60,
            indent = 3,
            enabled = in_git and wide_enough,
          },
          {
            pane = 2,
            icon = " ",
            title = "Git Log",
            section = "terminal",
            cmd = "git log --oneline --graph --decorate --color=always -8",
            height = 10,
            padding = 1,
            ttl = 5 * 60,
            indent = 3,
            enabled = in_git and wide_enough,
          },
          {
            pane = 2,
            icon = " ",
            title = "Recent Branches",
            section = "terminal",
            cmd = "git branch --sort=-committerdate --format='  %(refname:short)  %(committerdate:relative)' --color=always | head -5",
            height = 6,
            padding = 1,
            ttl = 5 * 60,
            indent = 3,
            enabled = in_git and wide_enough,
          },
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
        actions = {
          toggle_hidden_persist = function(picker)
            picker_state.hidden = not picker_state.hidden
            return picker:action("toggle_hidden")
          end,
          toggle_ignored_persist = function(picker)
            picker_state.ignored = not picker_state.ignored
            return picker:action("toggle_ignored")
          end,
        },
        win = {
          input = {
            keys = {
              ["<a-h>"] = { "toggle_hidden_persist", desc = "Toggle Hidden" },
              ["<a-i>"] = { "toggle_ignored_persist", desc = "Toggle Ignored" },
            },
          },
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
          grep = false,
          files = false,
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
