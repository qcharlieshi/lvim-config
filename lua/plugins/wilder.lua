return {
  "gelguy/wilder.nvim",
  config = function()
    local wilder = require("wilder")
    wilder.setup({ modes = { ":", "/", "?" } })

    -- wilder.set_option("pipeline", {
    --   wilder.branch(
    --     wilder.python_file_finder_pipeline({
    --       file_command = function(ctx, arg)
    --         if string.find(arg, ".") ~= nil then
    --           return { "fdfind", "-tf", "-H" }
    --         else
    --           return { "fdfind", "-tf" }
    --         end
    --       end,
    --       dir_command = { "fd", "-td" },
    --       filters = { "cpsm_filter" },
    --     }),
    --     wilder.substitute_pipeline({
    --       pipeline = wilder.python_search_pipeline({
    --         skip_cmdtype_check = 1,
    --         pattern = wilder.python_fuzzy_pattern({
    --           start_at_boundary = 0,
    --         }),
    --       }),
    --     }),
    --     wilder.cmdline_pipeline({
    --       fuzzy = 2,
    --       fuzzy_filter = wilder.lua_fzy_filter(),
    --     }),
    --     {
    --       wilder.check(function(ctx, x)
    --         return x == ""
    --       end),
    --       wilder.history(),
    --     },
    --     wilder.python_search_pipeline({
    --       pattern = wilder.python_fuzzy_pattern({
    --         start_at_boundary = 0,
    --       }),
    --     })
    --   ),
    -- })
    --
    -- local highlighters = {
    --   wilder.pcre2_highlighter(),
    --   wilder.lua_fzy_highlighter(),
    -- }
    --
    -- local popupmenu_renderer = wilder.popupmenu_renderer(wilder.popupmenu_border_theme({
    --   border = "rounded",
    --   empty_message = wilder.popupmenu_empty_message_with_spinner(),
    --   highlighter = highlighters,
    --   left = {
    --     " ",
    --     wilder.popupmenu_devicons(),
    --     wilder.popupmenu_buffer_flags({
    --       flags = " a + ",
    --       icons = { ["+"] = "", a = "", h = "" },
    --     }),
    --   },
    --   right = {
    --     " ",
    --     wilder.popupmenu_scrollbar(),
    --   },
    -- }))
    --
    -- local wildmenu_renderer = wilder.wildmenu_renderer({
    --   highlighter = highlighters,
    --   separator = " · ",
    --   left = { " ", wilder.wildmenu_spinner(), " " },
    --   right = { " ", wilder.wildmenu_index() },
    -- })
    --
    -- wilder.set_option(
    --   "renderer",
    --   wilder.renderer_mux({
    --     [":"] = popupmenu_renderer,
    --     ["/"] = wildmenu_renderer,
    --     substitute = wildmenu_renderer,
    --   })
    -- )
    wilder.set_option(
      "renderer",
      wilder.popupmenu_renderer(wilder.popupmenu_border_theme({
        highlights = {
          border = "Normal", -- highlight to use for the border
        },
        -- 'single', 'double', 'rounded' or 'solid'
        border = "rounded",

        left = {
          " ",
          wilder.popupmenu_devicons(),
          wilder.popupmenu_buffer_flags({
            flags = " a + ",
            icons = { ["+"] = "", a = "", h = "" },
          }),
        },
        right = {
          " ",
          wilder.popupmenu_scrollbar(),
        },
      }))
    )

    wilder.set_option("pipeline", {
      wilder.branch(
        wilder.python_file_finder_pipeline({
          file_command = { "rg", "--files" },
          dir_command = { "fd", "-td" },
          -- -- use {'cpsm_filter'} for performance, requires cpsm vim plugin
          -- found at https://github.com/nixprime/cpsm
          filters = { "fuzzy_filter", "difflib_sorter" },
        }),
        wilder.cmdline_pipeline({
          -- sets the language to use, 'vim' and 'python' are supported
          language = "python",
          -- -- 0 turns off fuzzy matching
          -- 1 turns on fuzzy matching
          -- 2 partial fuzzy matching (match does not have to begin with the same first letter)
          fuzzy = 1,
        }),
        wilder.python_search_pipeline({
          -- can be set to wilder#python_fuzzy_delimiter_pattern() for stricter fuzzy matching
          pattern = wilder.python_fuzzy_pattern(),
          -- omit to get results in the order they appear in the buffer
          sorter = wilder.python_difflib_sorter(),
          -- can be set to 're2' for performance, requires pyre2 to be installed
          -- see :h wilder#python_search() for more details
          engine = "re",
        })
      ),
    })
  end,
}
