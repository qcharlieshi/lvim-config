return {
  "esmuellert/codediff.nvim",
  dependencies = { "MunifTanjim/nui.nvim" },
  cmd = "CodeDiff",
  config = function()
    require("codediff").setup({
      diff = {
        disable_inlay_hints = true, -- Cleaner diff view
      },
    })
  end,
}
