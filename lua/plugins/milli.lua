-- milli.nvim is used here as a splash *registry* only — its bundled splashes
-- live alongside our custom ones under `lua/milli/splashes/`, and our own
-- dashboardAnimation.lua reads them via `require("milli.splashes.<name>")`.
--
-- We deliberately do NOT call `require("milli").snacks(...)`. Milli's snacks
-- preset paints frames via nvim_buf_set_lines, which would wipe out the
-- pane-2 weather/git content that shares buffer rows with the header in
-- our two-pane snacks dashboard. See dashboardAnimation.lua for the
-- extmark-overlay renderer that preserves pane 2.
return {
  "Amansingh-afk/milli.nvim",
  lazy = true,
  cmd = { "MilliPreview" },
}
