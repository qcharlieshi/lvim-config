return {
  "fnune/recall.nvim",
  version = "*",
  config = function()
    local recall = require("recall")

    recall.setup({
      sign = "",
      sign_highlight = "@comment.note",
      telescope = {
        autoload = true,
        mappings = {
          unmark_selected_entry = {
            normal = "dd",
            insert = "<M-d>",
          },
        },
      },
      wshada = vim.fn.has("nvim-0.10") == 0,
    })

    -- Keymappings
    vim.keymap.set("n", "<leader>mm", recall.toggle, { desc = "Toggle mark" })
    vim.keymap.set("n", "<leader>mn", recall.goto_next, { desc = "Next mark" })
    vim.keymap.set("n", "<leader>mp", recall.goto_prev, { desc = "Previous mark" })
    vim.keymap.set("n", "<leader>mc", recall.clear, { desc = "Clear marks" })

    -- Snacks Picker integration
    vim.keymap.set("n", "<leader>ml", function()
      require("snacks").picker.pick("recall")
    end, { desc = "List marks" })
  end,
}
