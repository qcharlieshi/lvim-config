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
      },
      servers = {
        vtsls = {
          settings = {
            typescript = {
              tsserver = {
                maxTsServerMemory = 16192,
              },
            },
            javascript = {
              tsserver = {
                maxTsServerMemory = 16192,
              },
            },
          },
        },
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
