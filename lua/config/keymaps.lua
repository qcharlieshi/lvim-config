-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

-- Sets the current root to the buffer's directory
vim.keymap.set("n", "<leader>ba", function()
  vim.cmd([[cd %:h]])
  vim.notify(vim.fn.getcwd(), vim.log.levels.INFO, {
    title = "Buffer CWD",
  })
end, { desc = "Buffer CWD", silent = true })

-- Move to different windows using `w` + arrow keys
vim.keymap.set("n", "w<Right>", "<C-w>w", { desc = "Move to the window on the right", silent = true })
vim.keymap.set("n", "w<Left>", "<C-w>h", { desc = "Move to the window on the left", silent = true })
vim.keymap.set("n", "w<Up>", "<C-w>k", { desc = "Move to the window above", silent = true })
vim.keymap.set("n", "w<Down>", "<C-w>j", { desc = "Move to the window below", silent = true })

-- Define a function to jump to the previous line with indent level 1.
local function goToIndentLevelOne()
  local target_line = vim.fn.line(".") -- start at the current line

  -- Walk upward until a line with an indent of exactly 1 is found.
  while target_line > 1 do
    target_line = target_line - 1
    if vim.fn.indent(target_line) == 1 then
      break
    end
  end

  -- If no matching line is found, target_line will eventually become 1.
  vim.api.nvim_win_set_cursor(0, { target_line, 0 })
end

-- Map the key sequence (e.g., [+t) in normal mode to call the function.
vim.api.nvim_set_keymap("n", "[+t", ":lua goToIndentLevelOne()<CR>", { noremap = true, silent = true })
