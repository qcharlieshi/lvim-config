local M = {}

M.cache = {
  data = nil,
  timestamp = 0,
  ttl = 300, -- 5 minutes cache
}

M.fallback_weather = [[
     \  /       Weather
   _ /"".-.     Unavailable
     \_(   ).   Check connection
     /(___(__)  
]]

-- Async weather fetch with callback
function M.fetch_weather_async(callback)
  local now = os.time()

  -- Return cached data if still valid
  if M.cache.data and (now - M.cache.timestamp) < M.cache.ttl then
    callback(M.cache.data)
    return
  end

  -- Use vim.system async for Neovim 0.10+
  if vim.system then
    vim.system({ "curl", "-s", "--connect-timeout", "3", "wttr.in/?0QnT" }, { text = true }, function(result)
      vim.schedule(function()
        if result.code == 0 and result.stdout then
          M.cache.data = result.stdout
          M.cache.timestamp = now
          callback(M.cache.data)
        else
          -- Return fallback if fetch failed
          callback(M.fallback_weather)
        end
      end)
    end)
  else
    -- Fallback for older versions - use defer_fn to at least not block immediately
    vim.defer_fn(function()
      local result = vim.fn.system('curl -s --connect-timeout 3 "wttr.in/?0QnT"')
      if vim.v.shell_error == 0 and result and result ~= "" then
        M.cache.data = result
        M.cache.timestamp = now
        callback(M.cache.data)
      else
        callback(M.fallback_weather)
      end
    end, 0)
  end
end

-- Synchronous version for backward compatibility (uses cache or fallback immediately)
function M.fetch_weather()
  local now = os.time()

  -- Return cached data if still valid
  if M.cache.data and (now - M.cache.timestamp) < M.cache.ttl then
    return M.cache.data
  end

  -- If no cache, return fallback immediately rather than blocking
  return M.fallback_weather
end

function M.get_weather_section()
  local weather_data = M.fetch_weather()

  -- Split into lines and ensure proper formatting
  local lines = vim.split(weather_data, "\n")

  -- Remove empty lines at the end
  while #lines > 0 and lines[#lines]:match("^%s*$") do
    table.remove(lines)
  end

  -- Return in the format expected by snacks.nvim text sections
  return lines
end

return M
