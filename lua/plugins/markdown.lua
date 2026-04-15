-- Markdown stack: render-markdown only.
-- markdown-preview (iamcco) disabled: we never used the browser preview,
-- and it carries a node/yarn build hook. Re-enable here if needed.
-- markdown-plus (yousefhadder) removed: its <localleader>m* keymaps
-- went unused. See docs/plugin-audit.md.
return {
  { "iamcco/markdown-preview.nvim", enabled = false },
}
