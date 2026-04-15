return {
  "linux-cultist/venv-selector.nvim",
  dependencies = { "neovim/nvim-lspconfig", "nvim-telescope/telescope.nvim", "mfussenegger/nvim-dap-python" },
  opts = {
    -- Your options go here
    -- name = "venv",
    -- auto_refresh = false
  },
  -- Only load for Python buffers; the `<leader>cv`/`<leader>cV` keys below still
  -- trigger loading from any filetype if needed. Prevents nvim-dap-python (a
  -- dep, above) from being dragged onto the startup path via `VeryLazy`.
  ft = "python",
  keys = {
    -- Keymap to open VenvSelector to pick a venv.
    { "<leader>cV", "<cmd>VenvSelect<cr>" },
    -- Keymap to retrieve the venv from a cache (the one previously used for the same project directory).
    { "<leader>cv", "<cmd>VenvSelectCached<cr>" },
  },
}
