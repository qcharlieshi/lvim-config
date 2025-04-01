-- Define your custom action to open in the leftmost window.
local function open_leftmost(picker)
  vim.cmd("wincmd h") -- Move to the leftmost window (you might need more logic here)
  picker:jump() -- Use the picker's jump action to open the selected item
end

return {
  {
    "folke/snacks.nvim",
    opts = {
      picker = {
        -- debug = {
        --   grep = true,
        --   files = true,
        -- },
        grep = {
          -- todo --
          finder = "rg",
          supports_args = true,
          glob = "%s%-%-",
        },
        matcher = {
          fuzzy = true, -- use fuzzy matching
          smartcase = true, -- use smartcase
          ignorecase = true, -- use ignorecase
          sort_empty = false, -- sort results when the search string is empty
          filename_bonus = true, -- give bonus for matching file names (last part of the path)
          file_pos = true, -- support patterns like `file:line:col` and `file:line`
          -- the bonusses below, possibly require string concatenation and path normalization,
          -- so this can have a performance impact for large lists and increase memory usage
          cwd_bonus = true, -- give bonus for matching files in the cwd
          frecency = true, -- frecency bonus
          live = true,
          buffer = true,
        },
        files = {
          finder = "fd",
        },
        -- Add custom actions.
        -- actions = {
        --   open_left = open_leftmost,
        --   open_right = open_leftmost,
        -- },

        -- Bind your custom action to a hotkey in the input window key mappings.
        -- win = {
        --   input = {
        --     keys = {
        --       ["<C-w>h"] = "open_left", -- or choose your preferred key combo
        --     },
        --   },
        -- },
      },
    },
  },
}
