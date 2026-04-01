-- Autocmds are automatically loaded on the VeryLazy event
-- Default autocmds that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/autocmds.lua
-- Add any additional autocmds heredoc

-- Autosave when switching buffers
vim.api.nvim_create_autocmd({ "BufLeave", "FocusLost" }, {
  callback = function()
    if vim.bo.modified and not vim.bo.readonly and vim.fn.expand("%") ~= "" and vim.bo.buftype == "" then
      vim.api.nvim_command("silent update")
    end
  end,
})

-- Open PDFs in fancy-cat via tmux split
vim.api.nvim_create_autocmd("BufReadCmd", {
  pattern = "*.pdf",
  callback = function(ev)
    local path = vim.fn.expand("<afile>:p")
    vim.fn.system(string.format("tmux split-window -h 'fancy-cat %s'", vim.fn.shellescape(path)))
    vim.api.nvim_buf_delete(ev.buf, { force = true })
  end,
})
