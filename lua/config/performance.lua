-- Performance monitoring for Neovim
local M = {}

-- FPS Counter (Update Frequency Tracking)
local fps_data = {
  last_time = vim.loop.hrtime(),
  frame_times = {},
  max_samples = 30,
}

function M.get_fps()
  local now = vim.loop.hrtime()
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
      return math.floor(1 / avg_frame_time)
    end
  end
  return 0
end

-- Event Loop Latency Monitor
local latency_data = {
  current_latency = 0,
  samples = {},
  max_samples = 20,
  last_check = 0,
  check_interval = 0.5, -- Check every 500ms
}

-- Input Lag Monitor (tracks time from keypress to buffer change)
local input_lag_data = {
  current_lag = 0,
  samples = {},
  max_samples = 15,
  last_input_time = 0,
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

-- Combined status string for lualine
function M.fps_status()
  local fps = M.get_fps()
  if fps > 0 then
    return string.format("%d fps", fps)
  end
  return ""
end

function M.latency_status()
  local latency = M.get_latency()
  if latency > 0 then
    return string.format("%.1fms", latency)
  end
  return ""
end

-- Track input lag by measuring time from keypress to cursor/text update
local function track_input()
  input_lag_data.last_input_time = vim.loop.hrtime()
end

local function measure_input_lag()
  if input_lag_data.last_input_time > 0 then
    local now = vim.loop.hrtime()
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

-- Set up autocmds to track input lag
vim.api.nvim_create_autocmd({ "InsertCharPre" }, {
  callback = track_input,
})

vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
  callback = measure_input_lag,
})

vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
  callback = measure_input_lag,
})

function M.get_input_lag()
  return input_lag_data.current_lag
end

function M.input_lag_status()
  local lag = M.get_input_lag()
  if lag > 0 then
    return string.format("%.1fms", lag)
  end
  return "0.0ms"
end

return M
