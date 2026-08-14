return {
  "esmuellert/codediff.nvim",
  dependencies = { "MunifTanjim/nui.nvim" },
  cmd = "CodeDiff",
  -- Suppress the legacy :VscodeDiff alias; its own guard makes the shim no-op
  init = function()
    vim.g.loaded_vscode_diff = 1
  end,
  opts = {
    explorer = {
      view_mode = "tree",
      focus_on_select = true,
    },
  },
}
