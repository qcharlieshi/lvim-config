-- The ASCII caracters used in the animation
-- ⠀⠁⠂⠃⠄⠅⠆⠇⠈⠉⠊⠋⠌⠍⠎⠏
-- ⠐⠑⠒⠓⠔⠕⠖⠗⠘⠙⠚⠛⠜⠝⠞⠟
-- ⠠⠡⠢⠣⠤⠥⠦⠧⠨⠩⠪⠫⠬⠭⠮⠯
-- ⠰⠱⠲⠳⠴⠵⠶⠷⠸⠹⠺⠻⠼⠽⠾⠿
-- ⡀⡁⡂⡃⡄⡅⡆⡇⡈⡉⡊⡋⡌⡍⡎⡏
-- ⡐⡑⡒⡓⡔⡕⡖⡗⡘⡙⡚⡛⡜⡝⡞⡟
-- ⡠⡡⡢⡣⡤⡥⡦⡧⡨⡩⡪⡫⡬⡭⡮⡯
-- ⡰⡱⡲⡳⡴⡵⡶⡷⡸⡹⡺⡻⡼⡽⡾⡿
-- ⢀⢁⢂⢃⢄⢅⢆⢇⢈⢉⢊⢋⢌⢍⢎⢏
-- ⢐⢑⢒⢓⢔⢕⢖⢗⢘⢙⢚⢛⢜⢝⢞⢟
-- ⢠⢡⢢⢣⢤⢥⢦⢧⢨⢩⢪⢫⢬⢭⢮⢯
-- ⢰⢱⢲⢳⢴⢵⢶⢷⢸⢹⢺⢻⢼⢽⢾⢿
-- ⣀⣁⣂⣃⣄⣅⣆⣇⣈⣉⣊⣋⣌⣍⣎⣏
-- ⣐⣑⣒⣓⣔⣕⣖⣗⣘⣙⣚⣛⣜⣝⣞⣟
-- ⣤⣡⣢⣣⣤⣥⣦⣧⣨⣩⣪⣫⣬⣭⣮⣯
-- ⣰⣱⣲⣳⣴⣵⣶⣷⣸⣹⣺⣻⣼⣽⣾⣿

-- The majority of the function are in the end

local M = {}

M.shouldPlayAnimation = true
M.lastRenderedFrame = nil

M.splash = "triforce"

-- Load animation frames from a milli.nvim splash module. Splashes expose
-- per-row tables (one string per row); we join them back to multi-line
-- strings so the renderer below can use its existing vim.split(...) path.
local function load_splash(name)
  local ok, mod = pcall(require, "milli.splashes." .. name)
  if not ok then
    error("dashboardAnimation: splash not found: " .. tostring(name))
  end
  local frames = {}
  for i, frame in ipairs(mod.frames) do
    frames[i] = table.concat(frame, "\n")
  end
  return frames
end

M.frames = load_splash(M.splash)

M.set_splash = function(name)
  M.splash = name
  M.frames = load_splash(name)
  M.asciiImg = M.frames[1]
  M.lastRenderedFrame = nil
end

M.asciiImg = M.frames[1]
M.anim_ns = vim.api.nvim_create_namespace("dashboard_anim")

M.ascii = function(counting, callback)
  if not M.shouldPlayAnimation then
    return
  end

  M.asciiImg = #M.frames < math.floor(counting) and M.frames[#M.frames] or M.frames[math.floor(counting)]

  -- Only update dashboard if the frame actually changed
  -- Use extmark overlays instead of buffer writes to avoid:
  --   1. Re-rendering terminal sections (flicker)
  --   2. Destroying pane 2 content (same buffer lines)
  --   3. Losing centering (snacks pads pane 1 lines)
  if M.asciiImg ~= M.lastRenderedFrame then
    M.lastRenderedFrame = M.asciiImg
    local buf = vim.api.nvim_get_current_buf()
    local ok, ft = pcall(vim.api.nvim_get_option_value, "filetype", { buf = buf })
    if ok and ft == "snacks_dashboard" then
      local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local new_lines = vim.split(M.asciiImg, "\n")

      -- Trim leading and trailing empty lines from frame
      while #new_lines > 0 and new_lines[1]:match("^%s*$") do
        table.remove(new_lines, 1)
      end
      while #new_lines > 0 and new_lines[#new_lines]:match("^%s*$") do
        table.remove(new_lines)
      end

      -- Find the header region: first braille line
      local start_line = nil
      for i, line in ipairs(buf_lines) do
        if line:find("[⠀-⣿]") then
          start_line = i - 1 -- 0-indexed
          break
        end
      end

      if start_line then
        -- Calculate window margin using same formula as snacks (dashboard.lua:612)
        local win = vim.api.nvim_get_current_win()
        local win_width = vim.api.nvim_win_get_width(win)
        local pane_width = 68
        local pane_gap = 6
        local num_panes = win_width >= 142 and 2 or 1
        local col = math.max(0, math.floor((win_width - (pane_width * num_panes + pane_gap * (num_panes - 1))) / 2))

        vim.api.nvim_buf_clear_namespace(buf, M.anim_ns, start_line, start_line + #new_lines)

        for i, frame_line in ipairs(new_lines) do
          local row = start_line + i - 1
          if row < vim.api.nvim_buf_line_count(buf) then
            local display_w = vim.fn.strdisplaywidth(frame_line)
            local center_pad = math.floor((pane_width - display_w) / 2)
            local right_pad = pane_width - display_w - center_pad
            local padded = string.rep(" ", center_pad) .. frame_line .. string.rep(" ", right_pad)

            vim.api.nvim_buf_set_extmark(buf, M.anim_ns, row, col, {
              virt_text = { { padded, "SnacksDashboardHeader" } },
              virt_text_pos = "overlay",
            })
          end
        end
      end
    end
  end

  if counting >= #M.frames + 1 then
    callback(callback)
  end
end

M.theAnimation = function(callback)
  require("snacks").animate(1, #M.frames + 1, function(value, ctx)
    M.ascii(value, callback)
  end, {
    duration = 150,
    fps = 24, -- Reduced from 60 to 24 FPS - still smooth but 2.5x less CPU
  })
end

M.list_splashes = function()
  local files = vim.api.nvim_get_runtime_file("lua/milli/splashes/*.lua", true)
  local seen, out = {}, {}
  for _, p in ipairs(files) do
    local name = p:match("([^/]+)%.lua$")
    if name and not seen[name] then
      seen[name] = true
      table.insert(out, name)
    end
  end
  table.sort(out)
  return out
end

vim.api.nvim_create_user_command("Splash", function(opts)
  if opts.args == "" then
    print("current: " .. tostring(M.splash))
    print("available: " .. table.concat(M.list_splashes(), ", "))
    return
  end
  local ok, err = pcall(M.set_splash, opts.args)
  if not ok then
    vim.notify(tostring(err), vim.log.levels.ERROR)
    return
  end
  M.shouldPlayAnimation = true
  local snacks_ok, snacks = pcall(require, "snacks")
  if snacks_ok and snacks.dashboard then
    pcall(snacks.dashboard.update)
    vim.defer_fn(function() M.theAnimation(M.theAnimation) end, 50)
  end
end, {
  nargs = "?",
  complete = function() return M.list_splashes() end,
  desc = "Swap dashboard splash animation",
})

return M
