return {
  "esmuellert/vscode-diff.nvim",
  dependencies = { "MunifTanjim/nui.nvim" },
  cmd = "CodeDiff",
  config = function()
    require("vscode-diff").setup({
      diff_binaries = true, -- Auto-download pre-built binaries
      disable_inlay_hints = true, -- Cleaner diff view
    })
  end,
}
