return {
  "nvim-lualine/lualine.nvim",
  dependencies = { "nvim-tree/nvim-web-devicons" },
  opts = {
    options = {
      theme = "auto",
    },
    sections = {
      lualine_a = { "mode" },
      lualine_b = { "branch" },
      lualine_c = { { "filename", path = 1, file_status = true } },
      lualine_y = { "filetype", "progress" },
      -- lualine_z can be defined if needed
    },
    inactive_sections = {
      lualine_a = { { "filename", path = 1 } }, -- wrap in a table for consistency
      lualine_b = {},
      lualine_c = {},
      lualine_x = {},
      lualine_y = {},
      lualine_z = { "location" },
    },
    tabline = {},
    extensions = {},
  },
}
