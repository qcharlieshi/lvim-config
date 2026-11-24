-- Headless test init: this repo + mini.nvim on the rtp, no user config, no plugins.
--   nvim --headless --noplugin -u tests/minimal_init.lua -c "lua require('tests.helpers').run()"
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp = { root, vim.env.VIMRUNTIME }
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local mini = vim.fn.expand("~/.local/share/nvim/lazy/mini.nvim")
if vim.fn.isdirectory(mini) == 0 then
  mini = root .. "/.tests/deps/mini.nvim"
  if vim.fn.isdirectory(mini) == 0 then
    vim.fn.system({ "git", "clone", "--filter=blob:none", "https://github.com/echasnovski/mini.nvim", mini })
  end
end
vim.opt.rtp:append(mini)
vim.o.swapfile = false
vim.o.shadafile = "NONE"

-- Never let a test reach a real tmux pane, herdr server or inbox
for _, k in ipairs({ "TMUX", "TMUX_PANE", "CLAUDE_CODE_SESSION_ID", "COCKPIT_HERDR_SESSION", "COCKPIT_PROJECT" }) do
  vim.env[k] = nil
end
for k in pairs(vim.fn.environ()) do
  if k:match("^HERDR_") then
    vim.env[k] = nil
  end
end
local tmp = vim.fn.tempname()
vim.env.HOME = tmp .. "/home"
vim.env.COCKPIT_INBOX_DIR = tmp .. "/inbox"
vim.env.COCKPIT_PROJECTS_DIR = tmp .. "/projects"
vim.env.COCKPIT_STATUS_DIR = tmp .. "/status"
vim.env.COCKPIT_ROOT = root

require("mini.test").setup()
