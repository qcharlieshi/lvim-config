-- Performance monitoring for Neovim
local M = {}

-- FPS Counter (Update Frequency Tracking)
local fps_data = {
  last_time = vim.loop.hrtime(),
  frame_times = {},
  max_samples = 30,
  cached_fps = 0,
  last_calculation = 0,
  cache_duration = 1.0, -- Cache for 1 second
}

function M.get_fps()
  local now = vim.loop.hrtime()
  local now_seconds = now / 1e9

  -- Return cached value if still fresh
  if now_seconds - fps_data.last_calculation < fps_data.cache_duration then
    return fps_data.cached_fps
  end

  local delta = (now - fps_data.last_time) / 1e9 -- Convert to seconds

  table.insert(fps_data.frame_times, delta)
  if #fps_data.frame_times > fps_data.max_samples then
    table.remove(fps_data.frame_times, 1)
  end

  fps_data.last_time = now

  -- Calculate average FPS from recent samples
  if #fps_data.frame_times > 0 then
    local sum = 0
    for _, dt in ipairs(fps_data.frame_times) do
      sum = sum + dt
    end
    local avg_frame_time = sum / #fps_data.frame_times
    if avg_frame_time > 0 then
      fps_data.cached_fps = math.floor(1 / avg_frame_time)
    else
      fps_data.cached_fps = 0
    end
  else
    fps_data.cached_fps = 0
  end

  fps_data.last_calculation = now_seconds
  return fps_data.cached_fps
end

-- Event Loop Latency Monitor
local latency_data = {
  current_latency = 0,
  samples = {},
  max_samples = 20,
  last_check = 0,
  check_interval = 1.0, -- Check every 1 second (reduced from 500ms)
}

-- Input Lag Monitor (tracks time from keypress to buffer change)
local input_lag_data = {
  current_lag = 0,
  samples = {},
  max_samples = 15,
  last_input_time = 0,
  last_measure_time = 0,
  measure_interval = 0.1, -- Only measure every 100ms to reduce overhead
}

-- Buffer Load Time Monitor
local buffer_load_data = {
  current_load_time = 0,
  samples = {},
  max_samples = 10,
  load_start_time = {},
}

local function measure_latency()
  local start_time = vim.loop.hrtime()

  vim.schedule(function()
    local end_time = vim.loop.hrtime()
    local latency_ms = (end_time - start_time) / 1e6 -- Convert to milliseconds

    table.insert(latency_data.samples, latency_ms)
    if #latency_data.samples > latency_data.max_samples then
      table.remove(latency_data.samples, 1)
    end

    -- Calculate average latency
    local sum = 0
    for _, l in ipairs(latency_data.samples) do
      sum = sum + l
    end
    latency_data.current_latency = sum / #latency_data.samples
  end)
end

function M.get_latency()
  local now = vim.loop.hrtime() / 1e9
  if now - latency_data.last_check > latency_data.check_interval then
    measure_latency()
    latency_data.last_check = now
  end

  return latency_data.current_latency
end

-- Cached status strings to reduce string formatting overhead
local status_cache = {
  fps = "",
  latency = "",
  input_lag = "",
  buffer_load = "",
  last_update = 0,
  update_interval = 1.0, -- Update status strings every 1 second
}

local function update_status_cache()
  local now = vim.loop.hrtime() / 1e9
  if now - status_cache.last_update < status_cache.update_interval then
    return
  end

  status_cache.last_update = now

  local fps = M.get_fps()
  status_cache.fps = fps > 0 and string.format("%d fps", fps) or ""

  local latency = M.get_latency()
  status_cache.latency = latency > 0 and string.format("%.1fms", latency) or ""

  local lag = M.get_input_lag()
  status_cache.input_lag = lag > 0 and string.format("%.1fms", lag) or "0.0ms"

  local load_time = M.get_buffer_load_time()
  status_cache.buffer_load = load_time > 0 and string.format("%.1fms", load_time) or "0.0ms"
end

-- Combined status string for lualine
function M.fps_status()
  update_status_cache()
  return status_cache.fps
end

function M.latency_status()
  update_status_cache()
  return status_cache.latency
end

-- Cached color functions to avoid recalculation on every statusline redraw
local color_cache = {
  latency_color = { fg = "#2a6b4d" },
  input_lag_color = { fg = "#2a6b4d" },
  buffer_load_color = { fg = "#2a6b4d" },
  last_update = 0,
  update_interval = 1.0,
}

local function update_color_cache()
  local now = vim.loop.hrtime() / 1e9
  if now - color_cache.last_update < color_cache.update_interval then
    return
  end

  color_cache.last_update = now

  -- Update latency color
  local latency = M.get_latency()
  if latency > 50 then
    color_cache.latency_color = { fg = "#8b2635" }
  elseif latency > 20 then
    color_cache.latency_color = { fg = "#8b6914" }
  else
    color_cache.latency_color = { fg = "#2a6b4d" }
  end

  -- Update input lag color
  local lag = M.get_input_lag()
  if lag > 100 then
    color_cache.input_lag_color = { fg = "#8b2635" }
  elseif lag > 50 then
    color_cache.input_lag_color = { fg = "#8b6914" }
  else
    color_cache.input_lag_color = { fg = "#2a6b4d" }
  end

  -- Update buffer load color
  local load_time = M.get_buffer_load_time()
  if load_time > 200 then
    color_cache.buffer_load_color = { fg = "#8b2635" }
  elseif load_time > 100 then
    color_cache.buffer_load_color = { fg = "#8b6914" }
  else
    color_cache.buffer_load_color = { fg = "#2a6b4d" }
  end
end

function M.get_latency_color()
  update_color_cache()
  return color_cache.latency_color
end

function M.get_input_lag_color()
  update_color_cache()
  return color_cache.input_lag_color
end

function M.get_buffer_load_color()
  update_color_cache()
  return color_cache.buffer_load_color
end

-- Track input lag by measuring time from keypress to text change only
local function track_input()
  input_lag_data.last_input_time = vim.loop.hrtime()
end

local function measure_input_lag()
  -- Throttle measurements to reduce overhead
  local now = vim.loop.hrtime()
  local now_seconds = now / 1e9

  if now_seconds - input_lag_data.last_measure_time < input_lag_data.measure_interval then
    return
  end

  input_lag_data.last_measure_time = now_seconds

  if input_lag_data.last_input_time > 0 then
    local lag_ms = (now - input_lag_data.last_input_time) / 1e6

    -- Only record if lag is reasonable (< 1 second, to filter out idle time)
    if lag_ms < 1000 then
      table.insert(input_lag_data.samples, lag_ms)
      if #input_lag_data.samples > input_lag_data.max_samples then
        table.remove(input_lag_data.samples, 1)
      end

      -- Calculate average
      local sum = 0
      for _, l in ipairs(input_lag_data.samples) do
        sum = sum + l
      end
      input_lag_data.current_lag = sum / #input_lag_data.samples
    end

    input_lag_data.last_input_time = 0
  end
end

-- Set up autocmds to track input lag (only on text changes, NOT cursor movement)
vim.api.nvim_create_autocmd({ "InsertCharPre" }, {
  callback = track_input,
})

vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
  callback = measure_input_lag,
})

function M.get_input_lag()
  return input_lag_data.current_lag
end

function M.input_lag_status()
  update_status_cache()
  return status_cache.input_lag
end

-- Track buffer load times
local function start_buffer_load()
  local bufnr = vim.api.nvim_get_current_buf()
  buffer_load_data.load_start_time[bufnr] = vim.loop.hrtime()
end

local function end_buffer_load()
  local bufnr = vim.api.nvim_get_current_buf()
  local start_time = buffer_load_data.load_start_time[bufnr]

  if start_time then
    local end_time = vim.loop.hrtime()
    local load_time_ms = (end_time - start_time) / 1e6

    -- Only track reasonable load times (< 5 seconds)
    if load_time_ms < 5000 then
      table.insert(buffer_load_data.samples, load_time_ms)
      if #buffer_load_data.samples > buffer_load_data.max_samples then
        table.remove(buffer_load_data.samples, 1)
      end

      -- Calculate average
      local sum = 0
      for _, t in ipairs(buffer_load_data.samples) do
        sum = sum + t
      end
      buffer_load_data.current_load_time = sum / #buffer_load_data.samples
    end

    buffer_load_data.load_start_time[bufnr] = nil
  end
end

-- Set up autocmds to track buffer load time
vim.api.nvim_create_autocmd("BufReadPre", {
  callback = start_buffer_load,
})

vim.api.nvim_create_autocmd("BufReadPost", {
  callback = end_buffer_load,
})

function M.get_buffer_load_time()
  return buffer_load_data.current_load_time
end

function M.buffer_load_status()
  update_status_cache()
  return status_cache.buffer_load
end

return M
