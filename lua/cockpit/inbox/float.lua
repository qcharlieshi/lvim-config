-- Floating window helper for the reply composer and line-note input.
local M = {}

-- opts: { title, footer, width?, height?, relative? = "editor"|"cursor" }
function M.open(buf, opts)
  opts = opts or {}
  local relative = opts.relative or "editor"
  local width = opts.width or math.min(100, vim.o.columns - 10)
  local height = opts.height or math.min(20, vim.o.lines - 8)
  local cfg = {
    relative = relative,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = opts.title and (" " .. opts.title .. " ") or nil,
    title_pos = opts.title and "center" or nil,
    footer = opts.footer and (" " .. opts.footer .. " ") or nil,
    footer_pos = opts.footer and "center" or nil,
  }
  if relative == "cursor" then
    cfg.row, cfg.col = 1, 0
  else
    cfg.row = math.floor((vim.o.lines - height) / 2) - 1
    cfg.col = math.floor((vim.o.columns - width) / 2)
  end
  local win = vim.api.nvim_open_win(buf, true, cfg)
  vim.wo[win].wrap = true
  return win
end

return M
