-- Markdown stack: render-markdown only.
-- markdown-preview (iamcco) disabled: we never used the browser preview,
-- and it carries a node/yarn build hook. Re-enable here if needed.
-- markdown-plus (yousefhadder) removed: its <localleader>m* keymaps
-- went unused. See docs/plugin-audit.md.
return {
  { "iamcco/markdown-preview.nvim", enabled = false },
  {
    "MeanderingProgrammer/render-markdown.nvim",
    opts = {
      pipe_table = {
        -- 'padded' (default) sizes columns by raw cell width, so concealed
        -- markup (**bold**, `code`, links) inflates every column it appears in
        -- and pushes wide tables further off screen. 'trimmed' measures the
        -- visible width instead. Requires `nowrap` — see config/autocmds.lua.
        cell = "trimmed",
      },
    },
  },
}
