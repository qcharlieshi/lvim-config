-- cockpit UI helpers shared by ui.lua and rail.lua: glyph tables, buffer/line/highlight utilities.
local M = {}

M.ns = vim.api.nvim_create_namespace("cockpit_inbox")

-- thread run status: glyph, highlight, label
M.STATUS = {
  needs_you = { "✋", "DiagnosticWarn", "waiting on you" },
  unread = { "●", "DiagnosticInfo", "unread" },
  working = { "⟳", "DiagnosticInfo", "agent working" },
  replied = { "↩", "Comment", "replied" },
  read = { "○", "Comment", "" },
  done = { "✓", "DiagnosticOk", "done" },
}

-- herdr agent status
M.AGENT = {
  working = { "◐", "DiagnosticInfo" },
  blocked = { "⚠", "DiagnosticWarn" },
  idle = { "○", "Comment" },
  done = { "○", "Comment" },
  unknown = { "?", "Comment" },
  offline = { "✕", "DiagnosticError" },
  dead = { "✕", "DiagnosticError" },
}

function M.ago(ts)
  local d = os.time() - (ts or os.time())
  if d < 60 then
    return d .. "s"
  elseif d < 3600 then
    return math.floor(d / 60) .. "m"
  elseif d < 86400 then
    return math.floor(d / 3600) .. "h"
  end
  return math.floor(d / 86400) .. "d"
end

function M.trunc(s, n)
  s = (s or ""):gsub("\n", " ")
  return vim.fn.strchars(s) > n and vim.fn.strcharpart(s, 0, n - 1) .. "…" or s
end

function M.find_buf(name)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b) == name then
      return b
    end
  end
end

function M.scratch(name, ft, buftype)
  local buf = M.find_buf(name)
  if not buf then
    buf = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_buf_set_name(buf, name)
    vim.bo[buf].buftype = buftype or "nofile"
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = ft
  end
  return buf
end

function M.set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
end

function M.hl(buf, row, col, end_col, group)
  vim.api.nvim_buf_set_extmark(buf, M.ns, row, col, { end_col = end_col, hl_group = group })
end

function M.map(buf, lhs, fn, desc, mode)
  vim.keymap.set(mode or "n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
end

-- A line built from { text, hl } segments; returns the text and its highlight marks
function M.segs(row, parts, marks)
  local text, col = "", 0
  for _, p in ipairs(parts) do
    if p[2] then
      marks[#marks + 1] = { row, col, col + #p[1], p[2] }
    end
    text = text .. p[1]
    col = col + #p[1]
  end
  return text
end

function M.run_status(t)
  if t.done then
    return "done"
  elseif t.stage and t.status == "replied" then
    return "working"
  end
  return t.status
end

return M
