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

-- vim.keymap.set("n", "<leader>gm", function()
--   -- Get the Git repo root (trim only leading/trailing whitespace)
--   local git_root = vim.fn.system("git rev-parse --show-toplevel"):gsub("^%s*(.-)%s*$", "%1")
--   if git_root == "" then
--     git_root = vim.loop.cwd()
--   end
--
--   -- Get the list of modified files relative to the repo root
--   local modified_files = vim.fn.systemlist("git diff --name-only")
--   if #modified_files == 0 then
--     print("No modified files found")
--     return
--   en
--
--   -- Escape each file name individually
--   local escaped_files = {}
--   for _, file in ipairs(modified_files) do
--     table.insert(escaped_files, vim.fn.shellescape(file))
--   end
--   local files_arg = table.concat(escaped_files, " ")
--
--   -- Use Snacks picker to search within the modified files
--   require("snacks").picker({
--     prompt = "Grep Modified Files",
--     cwd = git_root,
--     files = modified_files,
--     action = function(query)
--       if not query or query == "" then
--         print("No query provided")
--         return
--       end
--       local escaped_query = vim.fn.shellescape(query)
--       local grep_cmd = "rg " .. escaped_query .. " " .. files_arg
--       -- Open the results in a terminal split:
--       vim.cmd("split | terminal " .. grep_cmd)
--     end,
--   })
-- end, { desc = "Grep modified git files (snacks)" })
