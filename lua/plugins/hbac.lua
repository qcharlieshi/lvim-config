-- allows for closing the unedited buffers automaticlly
-- TODO: doesn't seem to work?
return {
  "axkirillov/hbac.nvim",
  config = true,
  autoclose = true, -- set autoclose to false if you want to close manually
  threshold = 8,
}
