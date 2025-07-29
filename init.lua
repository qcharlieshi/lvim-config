-- bootstrap lazy.nvim, LazyVim and your plugins
require("config.lazy")
vim.g.python3_host_prog = "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3"

-- use the existing buffers/tabs if avaliable
-- vim.opt.switchbuf = { "useopen", "usetab" }

-- Ensure this runs after the Snacks plugin is loaded
vim.ui.input = require("snacks").input
vim.ui.select = require("snacks").picker.select -- if you want to override vim.ui.select as well

-- Map <leader>gc to run the grep-on-changed-files function
-- TODO: move to keybinds?
vim.api.nvim_set_keymap("n", "<leader>ga", ":lua GrepChangedFilesWithPicker()<CR>", { noremap = true, silent = true })
function GrepChangedFilesWithPicker()
  -- Determine the merge base with the upstream branch (adjust branch as needed)
  local base = vim.fn.system("git merge-base HEAD origin/main"):gsub("%s+", "")
  if base == "" then
    print("Could not determine merge base.")
    return
  end

  -- Get the list of files changed since the merge base
  local diff_cmd = "git diff --name-only " .. base
  local files_str = vim.fn.system(diff_cmd)
  local files = vim.fn.split(files_str, "\n")
  files = vim.tbl_filter(function(f)
    return f ~= ""
  end, files)

  if #files == 0 then
    print("No changed files found!")
    return
  end

  -- Prompt for the grep search pattern
  local pattern = vim.fn.input("Grep for: ")
  if pattern == "" then
    return
  end

  -- Run grep over the changed files (-n for line numbers)
  local grep_cmd = "grep -n " .. pattern .. " " .. table.concat(files, " ")
  local grep_results_str = vim.fn.system(grep_cmd)
  if grep_results_str == "" then
    print("No matches found!")
    return
  end

  local grep_results = vim.fn.split(grep_results_str, "\n")
  grep_results = vim.tbl_filter(function(line)
    return line ~= ""
  end, grep_results)

  -- Use vim.ui.select (which snacks will replace if installed) to display the results
  vim.ui.select(grep_results, {
    prompt = "Grep Results:",
    format_item = function(item)
      return item
    end,
  }, function(choice)
    if choice then
      -- Expected format: "filename:line:match"
      local parts = vim.split(choice, ":", { plain = true })
      local filename = parts[1]
      local lineno = tonumber(parts[2])
      if filename and lineno then
        vim.cmd("edit " .. filename)
        vim.fn.cursor(lineno, 1)
      end
    end
  end)
end

-- -- --
--
-- Allows syncing of neovim frame to the entire terminal screen
vim.api.nvim_create_autocmd({ "UIEnter", "ColorScheme" }, {
  callback = function()
    local normal = vim.api.nvim_get_hl(0, { name = "Normal" })
    if not normal.bg then
      return
    end
    io.write(string.format("\027]11;#%06x\027\\", normal.bg))
  end,
})

-- Allows syncing of neovim frame to the entire terminal screen
vim.api.nvim_create_autocmd("UILeave", {
  callback = function()
    io.write("\027]111\027\\")
  end,
})
--
-- -- --
