-- sidekick-picker: disambiguate sidekick's CLI picker rows.
--
-- Sidekick renders each session as `<tool> [tmux:<session>] <cwd>`, which
-- collapses into identical rows when several claude instances share a tmux
-- session and cwd. Claude Code writes the conversation topic to the tmux pane
-- title, so that title is the only thing that actually tells them apart.
--
-- Wired into snacks via `picker.sources.select.kinds.sidekick_cli`, the
-- documented hook for customizing a `vim.ui.select` kind.

local M = {}

-- Width of the spliced `<pane id> <title>` column.
local TITLE_COL = 36
local TTL = 1000

local titles, titles_at = {}, 0

---@return table<string, string> pane_id -> pane_title
local function pane_titles()
  local now = vim.uv.now()
  if now - titles_at < TTL then
    return titles
  end
  titles_at = now
  titles = {}

  -- vim.system raises on a missing binary, which would take the picker with it
  if vim.fn.executable("tmux") == 0 then
    return titles
  end

  local out = vim.system({ "tmux", "list-panes", "-a", "-F", "#{pane_id}\t#{pane_title}" }, { text = true }):wait()
  if out.code ~= 0 then
    return titles
  end
  for line in (out.stdout or ""):gmatch("[^\n]+") do
    local id, title = line:match("^(%%%d+)\t(.*)$")
    if id and title ~= "" then
      titles[id] = title
    end
  end
  return titles
end

--- Drop tools that aren't installed, and make pane titles searchable.
---@param item snacks.picker.finder.Item wrapping a sidekick.cli.State
function M.transform(item)
  if not item.installed then
    return false
  end

  local pane = item.session and item.session.tmux_pane_id
  local title = pane and pane_titles()[pane]
  if title then
    item.sk_pane, item.sk_title = pane, title
    item.text = item.text .. " " .. title
  end
end

--- Sidekick's own row, with a fixed-width `<pane id> <title>` column spliced in.
---@param item snacks.picker.finder.Item
---@param picker snacks.Picker
function M.format(item, picker)
  local ret = require("sidekick.cli.ui.select").format(item, picker)
  if not item.sk_title then
    return ret
  end

  -- Snacks renders the cwd as a deferred part that resolves against whatever
  -- width is left, so the title must go *before* it: appended after, it never
  -- aligns and the path resolver overruns the row.
  local at = #ret + 1
  for i, part in ipairs(ret) do
    if part.resolve or part.virtual or part.field == "file" then
      at = i
      break
    end
  end

  local pane = item.sk_pane
  local avail = TITLE_COL - vim.api.nvim_strwidth(pane) - 1
  local title = item.sk_title
  if vim.api.nvim_strwidth(title) > avail then
    title = vim.fn.strcharpart(title, 0, avail - 1) .. "…"
  end

  local pad = math.max(1, avail - vim.api.nvim_strwidth(title) + 1)
  table.insert(ret, at, { string.rep(" ", pad) })
  table.insert(ret, at, { title, "SnacksPickerDesc" })
  table.insert(ret, at, { " " })
  table.insert(ret, at, { pane, "SnacksPickerDimmed" })
  return ret
end

return M
