-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

-- Fast key-repeat guard: layered defense against scroll freeze/jank.
-- 1. EOF/BOF guard for j/k: swallow at file boundaries (zero-cost no-op).
-- 2. Rapid-scroll mode (covers j/k/<Down>/<Up>/<PageDown>/<PageUp>/<C-d>/<C-u>/<C-f>/<C-b>):
--    after 2+ presses within 50ms, suppress CursorMoved AND WinScrolled
--    autocmds + trip mini.animate's kill-switch so scroll animations don't
--    queue. Without WinScrolled in the ignore set, mini.animate.scroll
--    (LazyVim's mini-animate extra runs a 150ms linear animation per scroll
--    event) accumulates a queue under fast key-repeat and stalls input —
--    most visible asymmetrically on PageDown because PageUp at BOF is a
--    no-op that never queues an animation.
--    A single CursorMoved fires 100ms after the last press so plugins catch up.
local _rapid = {
  timer = vim.uv.new_timer(),
  saved_ei = nil,
  saved_animate = nil,
  last_press = 0,
  THRESHOLD_MS = 50,
  COOLDOWN_MS = 100,
}

local function _rapid_scroll_tick()
  local now = vim.uv.now()
  local rapid = (now - _rapid.last_press) < _rapid.THRESHOLD_MS
  _rapid.last_press = now

  if rapid and not _rapid.saved_ei then
    _rapid.saved_ei = vim.o.eventignore
    local ei = _rapid.saved_ei
    vim.o.eventignore = (ei ~= "" and ei .. "," or "") .. "CursorMoved,CursorMovedI,WinScrolled"
    _rapid.saved_animate = vim.g.minianimate_disable
    vim.g.minianimate_disable = true
  end

  _rapid.timer:stop()
  _rapid.timer:start(
    _rapid.COOLDOWN_MS,
    0,
    vim.schedule_wrap(function()
      if _rapid.saved_ei ~= nil then
        vim.o.eventignore = _rapid.saved_ei
        _rapid.saved_ei = nil
        vim.g.minianimate_disable = _rapid.saved_animate
        _rapid.saved_animate = nil
        pcall(vim.api.nvim_exec_autocmds, "CursorMoved", { modeline = false })
      end
    end)
  )
end

local function eof_safe_down()
  if vim.api.nvim_win_get_cursor(0)[1] >= vim.api.nvim_buf_line_count(0) then
    return ""
  end
  if vim.fn.mode(1) == "n" then
    _rapid_scroll_tick()
  end
  return vim.v.count1 .. "j"
end

local function bof_safe_up()
  if vim.api.nvim_win_get_cursor(0)[1] <= 1 then
    return ""
  end
  if vim.fn.mode(1) == "n" then
    _rapid_scroll_tick()
  end
  return vim.v.count1 .. "k"
end

vim.keymap.set("n", "j", eof_safe_down, { expr = true, silent = true, desc = "Down (EOF-safe)" })
vim.keymap.set("n", "<Down>", eof_safe_down, { expr = true, silent = true, desc = "Down (EOF-safe)" })
vim.keymap.set("n", "k", bof_safe_up, { expr = true, silent = true, desc = "Up (BOF-safe)" })
vim.keymap.set("n", "<Up>", bof_safe_up, { expr = true, silent = true, desc = "Up (BOF-safe)" })

-- Page / half-page motions go through the same throttle. <C-d>/<C-u> append
-- `zz` to preserve LazyVim's centered-scroll default. vim.v.count (not count1)
-- so an unprefixed <C-d> keeps its half-page semantics rather than being
-- coerced to a 1-line scroll.
local function rapid_scroll_keyseq(keyseq)
  return function()
    if vim.fn.mode(1) == "n" then
      _rapid_scroll_tick()
    end
    if vim.v.count > 0 then
      return vim.v.count .. keyseq
    end
    return keyseq
  end
end

local _PageDown = vim.api.nvim_replace_termcodes("<PageDown>", true, true, true)
local _PageUp = vim.api.nvim_replace_termcodes("<PageUp>", true, true, true)
local _CtrlD = vim.api.nvim_replace_termcodes("<C-d>", true, true, true)
local _CtrlU = vim.api.nvim_replace_termcodes("<C-u>", true, true, true)
local _CtrlF = vim.api.nvim_replace_termcodes("<C-f>", true, true, true)
local _CtrlB = vim.api.nvim_replace_termcodes("<C-b>", true, true, true)

vim.keymap.set(
  "n",
  "<PageDown>",
  rapid_scroll_keyseq(_PageDown),
  { expr = true, silent = true, desc = "PageDown (throttled)" }
)
vim.keymap.set(
  "n",
  "<PageUp>",
  rapid_scroll_keyseq(_PageUp),
  { expr = true, silent = true, desc = "PageUp (throttled)" }
)
vim.keymap.set(
  "n",
  "<C-d>",
  rapid_scroll_keyseq(_CtrlD .. "zz"),
  { expr = true, silent = true, desc = "Half-page down (throttled, centered)" }
)
vim.keymap.set(
  "n",
  "<C-u>",
  rapid_scroll_keyseq(_CtrlU .. "zz"),
  { expr = true, silent = true, desc = "Half-page up (throttled, centered)" }
)
vim.keymap.set(
  "n",
  "<C-f>",
  rapid_scroll_keyseq(_CtrlF),
  { expr = true, silent = true, desc = "Page forward (throttled)" }
)
vim.keymap.set(
  "n",
  "<C-b>",
  rapid_scroll_keyseq(_CtrlB),
  { expr = true, silent = true, desc = "Page back (throttled)" }
)

-- Sets the current root to the buffer's directory
vim.keymap.set("n", "<leader>ba", function()
  vim.cmd([[cd %:h]])
  vim.notify(vim.fn.getcwd(), vim.log.levels.INFO, {
    title = "Buffer CWD",
  })
end, { desc = "Buffer CWD", silent = true })

-- Move to different windows using `w` + arrow keys
vim.keymap.set("n", "w<Right>", "<C-w>w", { desc = "Move to the window on the right", silent = true })
vim.keymap.set("n", "w<Left>", "<C-w>h", { desc = "Move to the window on the left", silent = true })
vim.keymap.set("n", "w<Up>", "<C-w>k", { desc = "Move to the window above", silent = true })
vim.keymap.set("n", "w<Down>", "<C-w>j", { desc = "Move to the window below", silent = true })

-- Might be getting in the way ov vim-tmux, add back if not
-- vim.keymap.set("n", "<C-H>", "<C-w>h", { noremap = true, silent = true })
-- vim.keymap.set("n", "<C-J>", "<C-w>j", { noremap = true, silent = true })
-- vim.keymap.set("n", "<C-K>", "<C-w>k", { noremap = true, silent = true })
-- vim.keymap.set("n", "<C-L>", "<C-w>l", { noremap = true, silent = true })

-- Jump to next/previous meaningful first-level block
vim.keymap.set("n", "]1", "/^[a-zA-Z_]<CR>", { noremap = true, silent = true, desc = "Next first-level block" })
vim.keymap.set("n", "[1", "?^[a-zA-Z_]<CR>", { noremap = true, silent = true, desc = "Previous first-level block" })

vim.keymap.set("n", "<leader>f.", ':let @+ = expand("%:.")<CR>', { desc = "Copy relative path" })

-- local function goto_prev_buffer_other_window()
--   local current_win = vim.api.nvim_get_current_win()
--   local all_wins = vim.api.nvim_list_wins()
--
--   -- Filter out current window and floating windows
--   local other_wins = {}
--   for _, win in ipairs(all_wins) do
--     if win ~= current_win and vim.api.nvim_win_get_config(win).relative == "" then
--       table.insert(other_wins, win)
--     end
--   end
--
--   if #other_wins > 0 then
--     -- Go to first other window and switch to previous buffer
--     vim.api.nvim_set_current_win(other_wins[1])
--     if vim.fn.bufexists("#") == 1 then
--       vim.cmd("buffer #")
--     end
--   else
--     -- No other window exists, create vertical split
--     if vim.fn.bufexists("#") == 1 then
--       vim.cmd("vsplit #")
--     else
--       -- No previous buffer, just create empty split
--       vim.cmd("vsplit")
--     end
--   end
-- end
--
-- vim.keymap.set("n", "<leader>b.", goto_prev_buffer_other_window, {
--   noremap = true,
--   silent = true,
--   desc = "Previous buffer in other window or vsplit",
-- })
--
-- TODO: need to fix this to be more consistent
vim.keymap.set("n", "<leader>b.", function()
  if #vim.api.nvim_list_wins() > 1 then
    vim.cmd("wincmd w | buffer #")
  else
    vim.cmd("vsplit #")
  end
end, { noremap = true, silent = true, desc = "Open previous buffer in window" })

-- Window resize keymaps with larger increments
-- Remaps current resize keys to use bigger intervals
vim.keymap.set("n", "<leader>w+", "<cmd>resize +20<CR>", { desc = "Increase window height", silent = true })
vim.keymap.set("n", "<leader>w-", "<cmd>resize -20<CR>", { desc = "Decrease window height", silent = true })
vim.keymap.set("n", "<leader>w<", "<cmd>vertical resize -20<CR>", { desc = "Decrease window width", silent = true })
vim.keymap.set("n", "<leader>w>", "<cmd>vertical resize +20<CR>", { desc = "Increase window width", silent = true })

-- Show Pretty Typescript Errors
vim.keymap.set("n", "<leader>dd", require("nvim-pretty-ts-errors").show_line_diagnostics)

-- Smart save: prompt for filename if buffer is unnamed, otherwise just save
vim.keymap.set({ "n", "i" }, "<C-s>", function()
  local bt = vim.bo.buftype
  if bt ~= "" then
    return
  end -- skip terminal, nofile, prompt, dashboard, etc.
  if vim.bo.readonly then
    return
  end

  if vim.api.nvim_buf_get_name(0) == "" then
    vim.ui.input({ prompt = "Save as: ", completion = "file" }, function(path)
      if path and path ~= "" then
        vim.cmd("file " .. vim.fn.fnameescape(path))
        vim.cmd("write")
      end
    end)
  else
    vim.cmd("write")
  end
end, { desc = "Save (prompt if unnamed)", silent = true })

-- Scoped Grep — seeker-style file<->grep toggle within git/buffer scopes
-- All three open a file picker first, then <C-e> toggles to grep (and back)
local sg = require("lib.scoped-grep")
vim.keymap.set("n", "<leader>sB", sg.grep_buffers, { desc = "Scoped grep: open buffers" })
vim.keymap.set("n", "<leader>sa", sg.grep_git_changed, { desc = "Scoped grep: git changed (vs origin/main)" })
vim.keymap.set("n", "<leader>sd", sg.grep_diff, { desc = "Scoped grep: diff vs branch/commit" })
