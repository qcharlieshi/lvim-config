return {
  {
    "LeonHeidelbach/trailblazer.nvim",
    config = function()
      require("trailblazer").setup({
        mappings = { -- rename this to "force_mappings" to completely override default mappings and not merge with them
          nv = { -- Mode union: normal & visual mode. Can be extended by adding i, x, ...
            motions = {
              new_trail_mark = "<leader>ta",
              track_back = "<leader>tb",
              peek_move_next_down = "<leader>tj",
              peek_move_previous_up = "<leader>tk",
              move_to_nearest = "<leader>tn",
              toggle_trail_mark_list = "<leaderal>tm",
            },
            -- actions = {
            --   delete_all_trail_marks = "<A-L>",
            --   paste_at_last_trail_mark = "<A-p>",
            --   paste_at_all_trail_marks = "<A-P>",
            --   set_trail_mark_select_mode = "<A-t>",
            --   switch_to_next_trail_mark_stack = "<A-.>",
            --   switch_to_previous_trail_mark_stack = "<A-,>",
            --   set_trail_mark_stack_sort_mode = "<A-s>",
            -- },
          },
          -- You can also add/move any motion or action to mode specific mappings i.e.:
          -- i = {
          --     motions = {
          --         new_trail_mark = '<C-l>',
          --         ...
          --     },
          --     ...
          -- },
        },
      })
    end,
  },
}
