-- Auto-closes untouched buffers once the count exceeds `threshold`.
-- Options MUST live inside `opts` — hbac passes `opts` to its `setup()`.
-- Previously these were top-level spec fields, which lazy.nvim silently ignored.
return {
  "axkirillov/hbac.nvim",
  opts = {
    autoclose = true,
    threshold = 8,
  },
}
