-- Gate Python test/debug adapters to `ft = "python"` so they stay off the
-- startup path outside Python repos. See docs/plugin-audit.md line 130.
--
-- Note: the real startup-load culprit for `nvim-dap-python` was the `VeryLazy`
-- event + dependency in `venv-selector.lua`; that's been swapped to `ft =
-- "python"`. `neotest-python` is already indirectly lazy (loaded when the
-- `<leader>t*` keys fire via `neotest`), but the override here enforces intent.
return {
  { "nvim-neotest/neotest-python", ft = "python" },
  { "mfussenegger/nvim-dap-python", ft = "python" },
}
