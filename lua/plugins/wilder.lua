return {
  "gelguy/wilder.nvim",
  dependencies = {
    "nvim-tree/nvim-web-devicons",
    "romgrk/fzy-lua-native",
  },
  config = function()
    local wilder = require("wilder")
    require("nvim-web-devicons").setup()
    wilder.setup({ modes = { ":", "/", "?" } })
    wilder.set_option("use_python_remote_plugin", 1)

    local gradient = {
      "#f4468f",
      "#fd4a85",
      "#ff507a",
      "#ff566f",
      "#ff5e63",
      "#ff6658",
      "#ff704e",
      "#ff7a45",
      "#ff843d",
      "#ff9036",
      "#f89b31",
      "#efa72f",
      "#e6b32e",
      "#dcbe30",
      "#d2c934",
      "#c8d43a",
      "#bfde43",
      "#b6e84e",
      "#aff05b",
    }

    for i, fg in ipairs(gradient) do
      gradient[i] = wilder.make_hl("WilderGradient" .. i, "Pmenu", { { a = 1 }, { a = 10 }, { foreground = fg } })
    end

    local highlighters = wilder.highlighter_with_gradient({
      -- requires luarocks install pcre2
      wilder.pcre2_highlighter(),
      wilder.lua_fzy_highlighter(),
    })

    wilder.set_option(
      "renderer",
      wilder.popupmenu_renderer(wilder.popupmenu_palette_theme({
        -- 'single', 'double', 'rounded' or 'solid'
        -- can also be a list of 8 characters, see :h wilder#popupmenu_palette_theme() for more details
        border = "rounded",
        margin = "50",
        max_height = "50%", -- max height of the palette
        min_height = "25%", -- set to the same as 'max_height' for a fixed height window
        prompt_position = "top", -- 'top' or 'bottom' to set the location of the prompt
        reverse = 0, -- set to 1 to reverse the order of the list, use in combination with 'prompt_position'
        right = { " ", wilder.popupmenu_scrollbar() },
        left = {
          " ",
          wilder.popupmenu_devicons(),
          wilder.popupmenu_buffer_flags({
            flags = " a + ",
            icons = { ["+"] = "", a = "", h = "" },
          }),
        },
        highlights = {
          gradient = gradient, -- must be set
          -- selected doesn't fill the entire selection for whatever reason
          -- selected_gradient = "#87CEEB", -- light blue highlight for selected candidate
          -- selected_gradient key can be set to apply gradient highlighting for the selected candidate.
        },
        highlighter = highlighters,
      }))
    )

    wilder.set_option("pipeline", {
      wilder.branch(
        wilder.cmdline_pipeline({
          fuzzy = 2,
          fuzzy_filter = wilder.lua_fzy_filter(),
        }),
        wilder.vim_search_pipeline()
        -- wilder.search_pipeline()
      ),
    })
  end,
}
