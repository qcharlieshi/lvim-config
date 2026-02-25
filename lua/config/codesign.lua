-- Auto re-sign native libraries after treesitter/plugin builds
-- Required on macOS 26+ where com.apple.provenance causes SIGKILL on dlopen

local M = {}

local sign_script = vim.fn.stdpath("config") .. "/scripts/sign-native-libs.sh"

function M.sign()
  vim.fn.jobstart({ sign_script }, {
    on_exit = function(_, code)
      if code == 0 then
        vim.notify("Native libs re-signed", vim.log.levels.INFO, { title = "codesign" })
      else
        vim.notify("Failed to sign native libs (exit " .. code .. ")", vim.log.levels.ERROR, { title = "codesign" })
      end
    end,
  })
end

-- Manual command
vim.api.nvim_create_user_command("SignNativeLibs", M.sign, { desc = "Re-sign treesitter parsers and native plugin libs" })

-- Auto-sign after Lazy operations (sync, update, install)
vim.api.nvim_create_autocmd("User", {
  pattern = { "LazySync", "LazyUpdate", "LazyInstall" },
  callback = function()
    -- Small delay to let builds finish writing files
    vim.defer_fn(M.sign, 3000)
  end,
  desc = "Re-sign native libs after plugin updates",
})

-- Auto-sign after TSUpdate/TSInstall
vim.api.nvim_create_autocmd("User", {
  pattern = "TSUpdate",
  callback = function()
    vim.defer_fn(M.sign, 2000)
  end,
  desc = "Re-sign parsers after treesitter update",
})

return M
