-- A plain CMD+click on a PDF opens it in macOS Preview, which zooms and
-- scrolls it properly (a remote one is first copied over the ssh pane's
-- ControlMaster, or reused from the cache). Clicks go through features/paths.lua.
local files = require 'lib.files'

local function is_pdf(path)
  return path:lower():match '%.pdf$' ~= nil
end

local M = { needs = { 'paths' } }

function M.apply(_, ctx)
  ctx.is_pdf = is_pdf
  files.enable_polling()
end

return M
