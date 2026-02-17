-- bootstrap lazy.nvim, LazyVim and your plugins
require("config.lazy")
vim.g.python3_host_prog = "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3"

-- use the existing buffers/tabs if avaliable
vim.opt.switchbuf = { "useopen", "usetab" }

-- Scoped grep keybindings moved to lua/config/keymaps.lua
-- Uses lua/lib/scoped-grep.lua with snacks.picker

-- -- --
--
-- Allows syncing of neovim frame to the entire terminal screen
vim.api.nvim_create_autocmd({ "UIEnter", "ColorScheme" }, {
  callback = function()
    local normal = vim.api.nvim_get_hl(0, { name = "Normal" })
    if not normal.bg then
      return
    end
    io.write(string.format("\027]11;#%06x\027\\", normal.bg))
  end,
})

-- Allows syncing of neovim frame to the entire terminal screen
vim.api.nvim_create_autocmd("UILeave", {
  callback = function()
    io.write("\027]111\027\\")
  end,
})
--
-- -- --
