-- scoped-grep: seeker-style file<->grep toggle within specific scopes
-- Scopes: open buffers, git changed files, diff against any branch/commit
-- <C-e> toggles between file list and grep within those files (progressive refinement)

local M = {}

local TOGGLE_KEY = "<C-e>"

-- ---------------------------------------------------------------------------
-- State: tracks file scope between toggles (reset per invocation)
-- ---------------------------------------------------------------------------
local state = {
  mode = "file", -- "file" | "grep"
  file_list = {}, -- files to grep within (file->grep)
  grep_files = {}, -- files from grep results (grep->file)
  title = "", -- display title for the scope
}

local function reset_state(title)
  state.mode = "file"
  state.file_list = {}
  state.grep_files = {}
  state.title = title or ""
end

-- ---------------------------------------------------------------------------
-- Picker item extraction (mirrors seeker's approach)
-- ---------------------------------------------------------------------------

--- Get selected items or all filtered items from a snacks picker
---@param picker table snacks picker object
---@return table[]
local function get_picker_items(picker)
  local selected = picker:selected()
  if selected and #selected > 0 then return selected end
  return picker:items() or {}
end

--- Extract unique file paths from picker items
---@param items table[]
---@return string[]
local function extract_file_paths(items)
  local paths, seen = {}, {}
  for _, item in ipairs(items) do
    local file
    if type(item) == "string" then
      file = item
    elseif type(item) == "table" then
      file = item.file or item.path or item.filename
    end
    if file then
      local cwd = (type(item) == "table" and item.cwd) or vim.fn.getcwd()
      local abs = vim.fn.fnamemodify(vim.fs.joinpath(cwd, file), ":p")
      if not seen[abs] then
        paths[#paths + 1] = abs
        seen[abs] = true
      end
    end
  end
  return paths
end

-- ---------------------------------------------------------------------------
-- Toggle actions
-- ---------------------------------------------------------------------------

local function create_file_picker()
  local files = state.grep_files
  local cwd = vim.fn.getcwd()

  local picker_opts = {
    title = state.title .. " [files]",
    finder = function()
      local items = {}
      for _, file in ipairs(files) do
        local rel = vim.fn.fnamemodify(file, ":~:.")
        items[#items + 1] = { text = rel, file = rel, cwd = cwd }
      end
      return items
    end,
    actions = {
      scoped_toggle = function(picker)
        local items = get_picker_items(picker)
        if #items == 0 then return end
        state.file_list = extract_file_paths(items)
        state.mode = "grep"
        picker:close()
        vim.schedule(function() create_grep_picker() end)
      end,
    },
    win = {
      input = {
        keys = {
          [TOGGLE_KEY] = { "scoped_toggle", mode = { "n", "i" }, desc = "Toggle to grep" },
        },
      },
    },
  }

  Snacks.picker.pick("files", picker_opts)
end

-- forward declaration used above
function create_grep_picker()
  local picker_opts = {
    title = state.title .. " [grep]",
    actions = {
      scoped_toggle = function(picker)
        local items = get_picker_items(picker)
        if #items == 0 then return end
        state.grep_files = extract_file_paths(items)
        state.mode = "file"
        picker:close()
        vim.schedule(create_file_picker)
      end,
    },
    win = {
      input = {
        keys = {
          [TOGGLE_KEY] = { "scoped_toggle", mode = { "n", "i" }, desc = "Toggle to files" },
        },
      },
    },
  }

  if #state.file_list > 0 then
    picker_opts.dirs = state.file_list
  end

  Snacks.picker.grep(picker_opts)
end

-- ---------------------------------------------------------------------------
-- Scope: start with file picker showing scoped files, toggle into grep
-- ---------------------------------------------------------------------------

--- Launch scoped file picker with toggle support
---@param files string[] file paths (relative or absolute)
---@param title string scope title
local function start_scoped(files, title)
  if not files or #files == 0 then
    vim.notify("No files in scope", vim.log.levels.INFO)
    return
  end

  reset_state(title)

  -- normalize to absolute for consistent state
  local cwd = vim.fn.getcwd()
  local abs_files = {}
  for _, f in ipairs(files) do
    abs_files[#abs_files + 1] = vim.fn.fnamemodify(vim.fs.joinpath(cwd, f), ":p")
  end

  state.grep_files = abs_files -- seed the file list for the initial file picker
  create_file_picker()
end

-- ---------------------------------------------------------------------------
-- Git helpers
-- ---------------------------------------------------------------------------

local function git_changed_files(base, head)
  head = head or "HEAD"
  local output = vim.fn.systemlist(string.format("git diff --name-only %s %s", base, head))
  if vim.v.shell_error ~= 0 then
    vim.notify("git diff failed: " .. (output[1] or "unknown error"), vim.log.levels.ERROR)
    return {}
  end
  return vim.tbl_filter(function(f) return f ~= "" end, output)
end

local function get_merge_base(target)
  local base = vim.fn.system("git merge-base HEAD " .. target):gsub("%s+", "")
  if vim.v.shell_error ~= 0 or base == "" then
    vim.notify("Could not determine merge-base with " .. target, vim.log.levels.ERROR)
    return nil
  end
  return base
end

local function get_git_branches()
  local output = vim.fn.systemlist("git branch --format='%(refname:short)' 2>/dev/null")
  if vim.v.shell_error ~= 0 then return {} end
  local remotes = vim.fn.systemlist("git branch -r --format='%(refname:short)' 2>/dev/null")
  if vim.v.shell_error == 0 then
    vim.list_extend(output, remotes)
  end
  return vim.tbl_filter(function(b) return b ~= "" end, output)
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Grep across open buffers with file<->grep toggle
function M.grep_buffers()
  local files = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if name ~= "" and vim.bo[buf].buflisted and vim.uv.fs_stat(name) then
      files[#files + 1] = name
    end
  end
  start_scoped(files, "Open Buffers")
end

--- Grep git changed files vs origin/main with file<->grep toggle
function M.grep_git_changed()
  local base = get_merge_base("origin/main")
  if not base then return end
  local files = git_changed_files(base)
  start_scoped(files, string.format("Changed vs origin/main (%d)", #files))
end

--- Grep diff vs any branch/commit with file<->grep toggle
function M.grep_diff()
  local branches = get_git_branches()

  vim.ui.select(branches, {
    prompt = "Compare against (or type a commit):",
    format_item = function(item) return item end,
  }, function(choice)
    if not choice or choice == "" then return end
    local base = get_merge_base(choice)
    if not base then return end
    local files = git_changed_files(base)
    start_scoped(files, string.format("Diff vs %s (%d)", choice, #files))
  end)
end

--- Generic: scoped grep within an arbitrary file list
---@param files string[] file paths
---@param title? string picker title
function M.grep_files(files, title)
  start_scoped(files, title or string.format("Custom Scope (%d)", #files))
end

return M
