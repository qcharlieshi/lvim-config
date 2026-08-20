-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here

-- fixes lazyvim changing root dir unexpectedly
vim.g.root_spec = { "cwd" }

-- disable diagnostics by default (toggle with <leader>ud)
vim.diagnostic.enable(false)

-- Reduce scroll-down stutter under fast key repeat: avoid EOF "wall" where
-- buffered keypresses can't move the cursor and back up the input queue.
vim.opt.scrolloff = 1

-- Pan one column at a time instead of jumping half a screen. Matters for the
-- nowrap markdown buffers in config/autocmds.lua, where wide pipe tables are
-- read by scrolling sideways. Global option, so it lives here, not in the
-- FileType autocmd.
vim.opt.sidescroll = 1
