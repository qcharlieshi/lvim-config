-- Multi-provider PR/issue dashboard (GitHub, GitLab, Bitbucket, Jira).
-- PR diffs render in CodeDiff so branch compare and PR review share one UI;
-- the review layer (panel, inline comments, notes, approve) still attaches.
-- Revert to open_cmd = "AtlasDiff" if the CodeDiff adapter breaks.
return {
  "emrearmagan/atlas.nvim",
  dependencies = {
    "nvim-tree/nvim-web-devicons",
    "MeanderingProgrammer/render-markdown.nvim",
    "esmuellert/codediff.nvim",
  },
  cmd = "Atlas",
  opts = {
    ui = { picker = "snacks" },
    pulls = {
      diff = {
        open_cmd = "CodeDiff",
        show_review_panel = true,
      },
      -- No provider defaults upstream — a provider is only usable once listed here.
      providers = { github = {} },
    },
    issues = {
      providers = {
        github = {},
        -- Jira needs credentials; export ATLAS_JIRA_URL / _EMAIL / _TOKEN.
        jira = vim.env.ATLAS_JIRA_URL and {
          base_url = vim.env.ATLAS_JIRA_URL,
          email = vim.env.ATLAS_JIRA_EMAIL,
          token = vim.env.ATLAS_JIRA_TOKEN,
        } or nil,
      },
    },
  },
}
