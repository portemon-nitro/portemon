-- Optional metadata-only preparation for a published save's global location.

local MapAssetCache = require("libs.assets.src.MapAssetCache")
local FieldMapLoader = require("libs.hgss.src.world.FieldMapLoader")

local SaveLocationPreparation = {}
SaveLocationPreparation.__index = SaveLocationPreparation

---@class SaveLocationPreparation
---@field versionId string
---@field derivedAssets table<string, function>?
---@field entryLocation { mapId: integer, fieldX: integer, fieldZ: integer }
---@field loader FieldMapLoader?
---@field ready boolean
---@field failure unknown?
---@field disposed boolean

---@class SaveLocationPreparation.Options
---@field versionId string
---@field entryLocation { mapId: integer, fieldX: integer, fieldZ: integer }
---@field derivedAssets table<string, function>

local function integer(value)
  return type(value) == "number" and value == value and math.abs(value) < math.huge and value % 1 == 0
end

---@param options SaveLocationPreparation.Options
---@return SaveLocationPreparation
function SaveLocationPreparation.new(options)
  assert(type(options) == "table", "saved-location preparation requires its composition")
  assert(
    options.versionId == "heartgold" or options.versionId == "soulsilver",
    "a supported selected version is required"
  )
  local host = options.derivedAssets
  assert(type(host) == "table" and type(host.requestMilestone) == "function", "a borrowed selected host is required")
  local location = options.entryLocation
  assert(type(location) == "table", "a saved location is required")
  assert(integer(location.mapId) and location.mapId >= 0, "map identity must be a non-negative integer")
  assert(integer(location.fieldX) and integer(location.fieldZ), "saved coordinates must be finite integers")
  return setmetatable({
    versionId = options.versionId,
    derivedAssets = host,
    entryLocation = { mapId = location.mapId, fieldX = location.fieldX, fieldZ = location.fieldZ },
    loader = nil,
    ready = false,
    failure = nil,
    disposed = false,
  }, SaveLocationPreparation)
end

function SaveLocationPreparation:_request(name)
  local host = assert(self.derivedAssets)
  local ok, ready, failure = pcall(host.requestMilestone, name, "near")
  if not ok then
    return false, ready
  end
  if failure ~= nil then
    return false, failure
  end
  return ready == true, nil
end

function SaveLocationPreparation:_buildLoader()
  local host = assert(self.derivedAssets)
  local okView, cacheFs = pcall(host.getCacheFs)
  if not okView then
    return false, cacheFs
  end
  if type(cacheFs) ~= "table" then
    return false, "saved-location preparation has no installed generated view"
  end
  local okWorld, world = pcall(cacheFs.loadLua, cacheFs, MapAssetCache.worldPath())
  if not okWorld then
    return false, world
  end
  if type(world) ~= "table" then
    return false, "saved-location world metadata is unavailable"
  end
  local okLoader, loader = pcall(FieldMapLoader.new, cacheFs, world, { derivedAssets = host })
  if not okLoader then
    return false, loader
  end
  self.loader = loader
  return true, nil
end

---@return boolean ready
---@return unknown? failure
function SaveLocationPreparation:poll()
  if self.disposed then
    return false, "saved-location preparation is disposed"
  end
  if self.ready or self.failure ~= nil then
    return self.ready, self.failure
  end
  local planningReady, planningFailure = self:_request("field-planning")
  if planningFailure ~= nil then
    self.failure = planningFailure
    return false, self.failure
  end
  local runtimeReady, runtimeFailure = self:_request("field-runtime")
  if runtimeFailure ~= nil then
    self.failure = runtimeFailure
    return false, self.failure
  end
  if self.loader == nil and planningReady then
    local built, failure = self:_buildLoader()
    if not built then
      self.failure = failure
      return false, self.failure
    end
  end
  if self.loader == nil then
    return false, nil
  end
  local location = self.entryLocation
  local loader = assert(self.loader)
  local ok, ready, failure =
    pcall(loader.requestLocation, loader, location.mapId, location.fieldX, location.fieldZ, "near", {
      neighborUrgency = "near",
    })
  if not ok then
    self.failure = ready
  elseif failure ~= nil then
    self.failure = failure
  elseif ready == true and runtimeReady then
    self.ready = true
  end
  return self.ready, self.failure
end

function SaveLocationPreparation:dispose()
  if self.disposed then
    return
  end
  self.disposed = true
  local loader = self.loader
  self.loader = nil
  self.derivedAssets = nil
  if loader ~= nil then
    loader:release()
  end
end

return SaveLocationPreparation
