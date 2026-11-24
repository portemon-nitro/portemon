-- Read-only launcher asset data from packaged files or a source checkout.

local RepoFs = require("libs.storage.src.RepoFs")

local LauncherAssets = {}

---@param path string
---@return love.FileData?
function LauncherAssets.read(path)
  assert(type(path) == "string" and path ~= "", "launcher asset path is required")
  ---@type string|nil
  local bytes = love.filesystem.read(path)
  if bytes == nil then
    bytes = RepoFs.new(love.filesystem.getSourceBaseDirectory()):read(path)
  end
  if bytes == nil then
    return nil
  end
  return love.filesystem.newFileData(bytes, path)
end

return LauncherAssets
