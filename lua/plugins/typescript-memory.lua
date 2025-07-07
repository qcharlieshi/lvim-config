return {
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        vtsls = {
          settings = {
            typescript = {
              tsserver = {
                maxTsServerMemory = 16192
              }
            },
            javascript = {
              tsserver = {
                maxTsServerMemory = 16192
              }
            }
          }
        }
      }
    }
  }
}