-- Adds folding preview
return {
  "kevinhwang91/nvim-ufo",
  dependencies = {
    "kevinhwang91/promise-async",
  },
  event = "VeryLazy",
  opts = {
    provider_selector = function(bufnr, filetype, buftype)
      -- Disable folding for dashboard and special buffers
      if filetype == "snacks_dashboard" or filetype == "" or buftype ~= "" then
        return ""
      end
      return { "treesitter", "indent" }
    end,
    preview = {
      win_config = {
        border = { "", "─", "", "", "", "─", "", "" },
        winhighlight = "Normal:Folded",
        winblend = 0,
      },
      mappings = {
        scrollU = "<C-u>",
        scrollD = "<C-d>",
        jumpTop = "[",
        jumpBot = "]",
      },
    },
    fold_virt_text_handler = function(virtText, lnum, endLnum, width, truncate)
      local newVirtText = {}
      local suffix = (" 󰁂 %d "):format(endLnum - lnum)
      local sufWidth = vim.fn.strdisplaywidth(suffix)
      local targetWidth = width - sufWidth
      local curWidth = 0
      for _, chunk in ipairs(virtText) do
        local chunkText = chunk[1]
        local chunkWidth = vim.fn.strdisplaywidth(chunkText)
        if targetWidth > curWidth + chunkWidth then
          table.insert(newVirtText, chunk)
        else
          chunkText = truncate(chunkText, targetWidth - curWidth)
          local hlGroup = chunk[2]
          table.insert(newVirtText, { chunkText, hlGroup })
          chunkWidth = vim.fn.strdisplaywidth(chunkText)
          if curWidth + chunkWidth < targetWidth then
            suffix = suffix .. (" "):rep(targetWidth - curWidth - chunkWidth)
          end
          break
        end
        curWidth = curWidth + chunkWidth
      end
      table.insert(newVirtText, { suffix, "MoreMsg" })
      return newVirtText
    end,
  },
  init = function()
    vim.o.foldcolumn = "1"
    vim.o.foldlevel = 99
    vim.o.foldlevelstart = 99
    vim.o.foldenable = true

    -- Auto preview fold after 2 seconds
    local timer = vim.loop.new_timer()
    local last_fold_time = 0

    vim.api.nvim_create_autocmd("CursorMoved", {
      callback = function()
        if timer then
          timer:stop()
        end
        last_fold_time = vim.loop.now()
        timer:start(
          2000,
          0,
          vim.schedule_wrap(function()
            if vim.loop.now() - last_fold_time >= 2000 then
              local line = vim.fn.line(".")
              local fold_start = vim.fn.foldclosed(line)
              if fold_start ~= -1 then
                require("ufo").peekFoldedLinesUnderCursor()
              end
            end
          end)
        )
      end,
    })
  end,
  config = function(_, opts)
    require("ufo").setup(opts)

    -- Keymaps
    vim.keymap.set("n", "zR", require("ufo").openAllFolds)
    vim.keymap.set("n", "zM", require("ufo").closeAllFolds)
    vim.keymap.set("n", "zr", require("ufo").openFoldsExceptKinds)
    vim.keymap.set("n", "zm", require("ufo").closeFoldsWith)
  end,
}
