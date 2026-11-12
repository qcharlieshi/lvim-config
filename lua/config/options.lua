-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here

-- fixes lazyvim changing root dir unexpectedly
vim.g.root_spec = { "cwd" }

-- disable diagnostics by default (toggle with <leader>ud)
vim.diagnostic.enable(false)

-- lsp.log is never rotated; at WARN, copilot-language-server's window/logMessage
-- spam (OrgCustomAgentClient 404s every few minutes per repo) grew it past 13MB.
vim.lsp.log.set_level(vim.log.levels.ERROR)

-- Reduce scroll-down stutter under fast key repeat: avoid EOF "wall" where
-- buffered keypresses can't move the cursor and back up the input queue.
vim.opt.scrolloff = 1

-- Pan one column at a time instead of jumping half a screen. Matters for the
-- nowrap markdown buffers in config/autocmds.lua, where wide pipe tables are
-- read by scrolling sideways. Global option, so it lives here, not in the
-- FileType autocmd.
vim.opt.sidescroll = 1

-- Python LSP: pyrefly (Meta, Rust) instead of LazyVim's default pyright (Node).
-- Picked over Astral's `ty`, the other Rust contender, purely on stability:
-- pyrefly hit a stable 1.0 on 2026-05-12 and is the default type checker for
-- Instagram/PyTorch/JAX, while ty is still on 0.0.x with an explicit "breaking
-- changes between any two versions" policy.
--
-- Read by lazyvim.plugins.extras.lang.python at spec-source time, which flips
-- pyright/basedpyright/ruff_lsp off and enables pyrefly + ruff. Only works
-- because LazyVim loads config.options before sourcing plugin modules.
vim.g.lazyvim_python_lsp = "pyrefly"
