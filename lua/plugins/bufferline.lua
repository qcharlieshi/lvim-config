return {
  "akinsho/bufferline.nvim",
  version = "*",
  dependencies = "nvim-tree/nvim-web-devicons",
  config = function()
    require("bufferline").setup({
      options = {
        termguicolors = true,
        mode = "buffers",
        separator_style = "slope",
        always_show_bufferline = false,
        show_buffer_close_icons = true,
        show_close_icon = true,
        show_tab_indicators = true,
        indicator = {
          icon = "",
          style = "underline",
        },
        persist_buffer_sort = true,
        diagnostics_update_in_insert = false,
        tab_size = 28,
        max_name_length = 28,
        truncate_names = true,
        enforce_regular_tabs = false,
        color_icons = true,
        sort_by = "insert_after_current",
        highlights = {
          indicator_selected = {
            fg = "#7aa2f7",
            underline = true,
            bold = true,
          },
        },
      },
    })
  end,
}
