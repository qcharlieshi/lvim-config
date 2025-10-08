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

function M.fetch_weather()
  local now = os.time()

  -- Return cached data if still valid
  if M.cache.data and (now - M.cache.timestamp) < M.cache.ttl then
    return M.cache.data
  end

  -- Use vim.system for Neovim 0.10+ or vim.fn.system for older versions
  local result
  if vim.system then
    local cmd = vim.system({ "curl", "-s", "--connect-timeout", "3", "wttr.in/?0QnT" }, { text = true })
    result = cmd:wait()
    if result.code == 0 and result.stdout then
      M.cache.data = result.stdout
      M.cache.timestamp = now
      return M.cache.data
    end
  else
    result = vim.fn.system('curl -s --connect-timeout 3 "wttr.in/?0QnT"')
    if vim.v.shell_error == 0 and result and result ~= "" then
      M.cache.data = result
      M.cache.timestamp = now
      return M.cache.data
    end
  end

  -- Return fallback if fetch failed
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
