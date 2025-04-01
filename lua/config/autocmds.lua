-- Autocmds are automatically loaded on the VeryLazy event
-- Default autocmds that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/autocmds.lua
-- Add any additional autocmds heredoc

-- Allows for editing the quickfix buffer
vim.api.nvim_create_autocmd({ "BufWinEnter", "FileType" }, {
  callback = function()
    if vim.bo.buftype == "quickfix" then
      vim.opt_local.modifiable = true
    end
  end,
})
