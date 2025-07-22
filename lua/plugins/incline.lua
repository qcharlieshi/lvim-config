return {
  "b0o/incline.nvim",
  dependencies = { "SmiteshP/nvim-navic", "nvim-tree/nvim-web-devicons" },
  event = "BufReadPre",
  config = function()
    local helpers = require("incline.helpers")
    local navic = require("nvim-navic")
    local devicons = require("nvim-web-devicons")

    require("incline").setup({
      window = {
        padding = 0,
        margin = { horizontal = 0, vertical = 0 },
      },
      render = function(props)
        local filename = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(props.buf), ":t")
        if filename == "" then
          filename = "[No Name]"
        end

        local ft_icon, ft_color = devicons.get_icon_color(filename)
        local modified = vim.bo[props.buf].modified

        local res = {}

        if props.focused == false then
          res = {
            {
              { "", guifg = ft_color },
              ft_icon and { " ", ft_icon, "  ", guibg = ft_color, guifg = helpers.contrast_color(ft_color) } or "",
              { "  ", filename, " ", gui = modified and "bold,italic" or "bold" },
            },
            guibg = helpers.contrast_color(ft_color),
          }
        end

        if props.focused and navic.is_available() then
          local data = navic.get_data() or {}
          table.insert(res, { "", guifg = "#1E202F", guibg = "#222435" })
          table.insert(res, { "  ", guibg = "#1E202F" })
          for _, item in ipairs(data) do
            table.insert(res, {
              { item.icon, group = "NavicIcons" .. item.type },
              { item.name, group = "NavicText" },
              { " > ", group = "NavicSeparator" },
            })
          end
          table.insert(res, { " " })
          -- table.insert(res, { { "", guifg = "#00000" } })
        end

        return res
      end,
    })
  end,
}
