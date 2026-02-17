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

-- Might be getting in the way ov vim-tmux, add back if not
-- vim.keymap.set("n", "<C-H>", "<C-w>h", { noremap = true, silent = true })
-- vim.keymap.set("n", "<C-J>", "<C-w>j", { noremap = true, silent = true })
-- vim.keymap.set("n", "<C-K>", "<C-w>k", { noremap = true, silent = true })
-- vim.keymap.set("n", "<C-L>", "<C-w>l", { noremap = true, silent = true })

-- Jump to next/previous meaningful first-level block
vim.keymap.set("n", "]1", "/^[a-zA-Z_]<CR>", { noremap = true, silent = true, desc = "Next first-level block" })
vim.keymap.set("n", "[1", "?^[a-zA-Z_]<CR>", { noremap = true, silent = true, desc = "Previous first-level block" })

vim.keymap.set("n", "<leader>f.", ':let @+ = expand("%:.")<CR>', { desc = "Copy relative path" })

-- local function goto_prev_buffer_other_window()
--   local current_win = vim.api.nvim_get_current_win()
--   local all_wins = vim.api.nvim_list_wins()
--
--   -- Filter out current window and floating windows
--   local other_wins = {}
--   for _, win in ipairs(all_wins) do
--     if win ~= current_win and vim.api.nvim_win_get_config(win).relative == "" then
--       table.insert(other_wins, win)
--     end
--   end
--
--   if #other_wins > 0 then
--     -- Go to first other window and switch to previous buffer
--     vim.api.nvim_set_current_win(other_wins[1])
--     if vim.fn.bufexists("#") == 1 then
--       vim.cmd("buffer #")
--     end
--   else
--     -- No other window exists, create vertical split
--     if vim.fn.bufexists("#") == 1 then
--       vim.cmd("vsplit #")
--     else
--       -- No previous buffer, just create empty split
--       vim.cmd("vsplit")
--     end
--   end
-- end
--
-- vim.keymap.set("n", "<leader>b.", goto_prev_buffer_other_window, {
--   noremap = true,
--   silent = true,
--   desc = "Previous buffer in other window or vsplit",
-- })
--
-- TODO: need to fix this to be more consistent
vim.keymap.set("n", "<leader>b.", function()
  if #vim.api.nvim_list_wins() > 1 then
    vim.cmd("wincmd w | buffer #")
  else
    vim.cmd("vsplit #")
  end
end, { noremap = true, silent = true, desc = "Open previous buffer in window" })

-- Window resize keymaps with larger increments
-- Remaps current resize keys to use bigger intervals
vim.keymap.set("n", "<leader>w+", "<cmd>resize +20<CR>", { desc = "Increase window height", silent = true })
vim.keymap.set("n", "<leader>w-", "<cmd>resize -20<CR>", { desc = "Decrease window height", silent = true })
vim.keymap.set("n", "<leader>w<", "<cmd>vertical resize -20<CR>", { desc = "Decrease window width", silent = true })
vim.keymap.set("n", "<leader>w>", "<cmd>vertical resize +20<CR>", { desc = "Increase window width", silent = true })

-- Show Pretty Typescript Errors
vim.keymap.set("n", "<leader>dd", require("nvim-pretty-ts-errors").show_line_diagnostics)

-- Scoped Grep — seeker-style file<->grep toggle within git/buffer scopes
-- All three open a file picker first, then <C-e> toggles to grep (and back)
local sg = require("lib.scoped-grep")
vim.keymap.set("n", "<leader>sB", sg.grep_buffers, { desc = "Scoped grep: open buffers" })
vim.keymap.set("n", "<leader>sa", sg.grep_git_changed, { desc = "Scoped grep: git changed (vs origin/main)" })
vim.keymap.set("n", "<leader>sd", sg.grep_diff, { desc = "Scoped grep: diff vs branch/commit" })
