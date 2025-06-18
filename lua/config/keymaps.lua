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

vim.keymap.set("n", "<C-H>", "<C-w>h", { noremap = true, silent = true })
vim.keymap.set("n", "<C-J>", "<C-w>j", { noremap = true, silent = true })
vim.keymap.set("n", "<C-K>", "<C-w>k", { noremap = true, silent = true })
vim.keymap.set("n", "<C-L>", "<C-w>l", { noremap = true, silent = true })

vim.keymap.set("n", "<leader>c.", "<cmd>ClaudeCode<CR>", { desc = "Toggle Claude Code" })

-- Jump to next/previous meaningful first-level block
vim.keymap.set("n", "]1", "/^[a-zA-Z_]<CR>", { noremap = true, silent = true, desc = "Next first-level block" })
vim.keymap.set("n", "[1", "?^[a-zA-Z_]<CR>", { noremap = true, silent = true, desc = "Previous first-level block" })

vim.keymap.set("n", "<leader>f.", ':let @+ = expand("%:.")<CR>', { desc = "Copy relative path" })

vim.keymap.set("n", "<leader>b.", function()
  if #vim.api.nvim_list_wins() > 1 then
    vim.cmd("wincmd w | buffer #")
  else
    vim.cmd("vsplit #")
  end
end, { noremap = true, silent = true, desc = "Open previous buffer in window" })
