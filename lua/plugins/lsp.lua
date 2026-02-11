return {
  {
    "neovim/nvim-lspconfig",
    opts = {
      setup = {
        -- sith_lsp = function()
        --   local configs = require("lspconfig.configs")
        --   if not configs.sith_lsp then
        --     configs.sith_lsp = {
        --       default_config = {
        --         cmd = { "/Users/qcharlieshi/.cargo/bin/sith-lsp" },
        --         filetypes = { "python" },
        --         root_dir = function(fname)
        --           return require("lspconfig.util").root_pattern(
        --             "pyproject.toml",
        --             "setup.py",
        --             "setup.cfg",
        --             "requirements.txt",
        --             "Pipfile",
        --             "pyrightconfig.json",
        --             ".git"
        --           )(fname)
        --         end,
        --         single_file_support = true,
        --       },
        --     }
        --   end
        -- end,
        tsgo = function()
          local configs = require("lspconfig.configs")
          if not configs.tsgo then
            configs.tsgo = {
              default_config = {
                cmd = { "tsgo", "--lsp", "--stdio" },
                filetypes = {
                  "javascript",
                  "javascriptreact",
                  "javascript.jsx",
                  "typescript",
                  "typescriptreact",
                  "typescript.tsx",
                },
                root_dir = require("lspconfig.util").root_pattern(
                  "tsconfig.json",
                  "tsconfig.base.json",
                  "jsconfig.json",
                  "package.json",
                  ".git"
                ),
                single_file_support = true,
              },
            }
          end
        end,
      },
      servers = {
        -- vtsls (commented out in favor of tsgo)
        -- vtsls = {
        --   settings = {
        --     typescript = {
        --       tsserver = {
        --         maxTsServerMemory = 16192,
        --       },
        --     },
        --     javascript = {
        --       tsserver = {
        --         maxTsServerMemory = 16192,
        --       },
        --     },
        --   },
        -- },
        vtsls = { enabled = false },
        tsgo = {},
        -- sith_lsp = {
        --   settings = {
        --     ruff = {
        --       enabled = true,
        --       format = { enable = true },
        --       lint = { enable = true },
        --     },
        --   },
        -- },
        ruff = {
          enabled = false,
        },
        -- Disable pyright
        pyright = {
          enabled = false,
        },
      },
    },
  },
}
