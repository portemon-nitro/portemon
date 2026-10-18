-- Reconstructs one saved photo using the live field-map presentation owner.
-- Camera and subject behavior follows the retail ROM's photo capture.

local FieldActorAssetProvider = require("libs.hgss.src.presentation.FieldActorAssetProvider")
local FieldActorDraw = require("libs.hgss.src.presentation.FieldActorDraw")
local FieldCamera = require("libs.hgss.src.field.FieldCamera")
local FieldActorCache = require("libs.assets.src.field.FieldActorCache")

local PhotoScene = {}
PhotoScene.__index = PhotoScene
---@class PhotoScene

local WORK_UNITS = 16
local PHOTO_CAMERA = {
  projectionType = "perspective",
  distanceTiles = 666.922119140625 / 16,
  angleXRaw = 0xEE00,
  angleYRaw = 0,
  halfFovRadians = 2 * math.pi * 0x230 / 65536,
  fullVerticalFovRadians = 4 * math.pi * 0x230 / 65536,
  targetOffsetTiles = { x = 16.3125 / 16, y = 0, z = -47 / 16 },
  nearTiles = 0.1,
  farTiles = 2048,
}

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, child in pairs(value) do
    result[key] = copy(child)
  end
  return result
end

---@param options table<string, unknown>
---@return PhotoScene
function PhotoScene.new(options)
  assert(type(options) == "table", "photo scene options are required")
  assert(type(options.versionId) == "string" and options.versionId ~= "", "photo scene requires a version")
  assert(type(options.derivedAssets) == "table", "photo scene requires derived asset access")
  assert(type(options.monCatalog) == "table", "photo scene requires the shared MonCatalog")
  local loader = assert(options.fieldMapLoader, "photo scene borrows a field map loader")
  local imageAssets = assert(loader.imageAssets, "presented photo scene requires the field image pool")
  local cacheFs = assert(options.cacheFs or loader.cacheFs, "photo scene requires a version cache")
  return setmetatable({
    versionId = options.versionId,
    _derivedAssets = options.derivedAssets,
    monCatalog = options.monCatalog,
    profile = copy(assert(options.profile, "photo scene requires the current player profile")),
    cacheFs = cacheFs,
    loader = loader,
    imageAssets = imageAssets,
    phase = "idle",
    photo = nil,
    failure = nil,
    task = nil,
    runtimeMap = nil,
    coverage = nil,
    actorAssets = nil,
    spriteIds = {},
    _actorPlan = nil,
    _actorIds = nil,
    view = nil,
    generation = 0,
    disposed = false,
    borrowedLoader = options.borrowFieldMapLoader == true,
  }, PhotoScene)
end

local function releasePresentation(self)
  local coverage = self.coverage
  self.coverage = nil
  if coverage then
    coverage:release()
  end
  local assets = self.actorAssets
  self.actorAssets = nil
  if assets then
    for _, spriteId in ipairs(self.spriteIds) do
      assets:release(spriteId)
    end
    assets:dispose()
  end
  self.spriteIds = {}
  self._actorPlan = nil
  self._actorIds = nil
  local task = self.task
  self.task = nil
  if task then
    task:release()
  end
  self.runtimeMap = nil
  self.view = nil
end

function PhotoScene:_releaseOwned()
  releasePresentation(self)
  if not self.borrowedLoader and self.loader then
    self.loader:release()
    self.loader = nil
  end
end

function PhotoScene:request(photo)
  assert(not self.disposed, "disposed photo scene cannot accept a request")
  assert(type(photo) == "table" and photo.schema == "g4-photo-v1", "saved photo record is required")
  if self.phase ~= "idle" then
    self:_releaseOwned()
  end
  self.generation = self.generation + 1
  self.photo = copy(photo)
  self.failure = nil
  self.phase = "pending"
  self._globalPosition = nil
  self._generationAtRequest = self.generation
  local ok, result = pcall(function()
    local loader = assert(self.loader)
    self._globalPosition = loader:globalPosition(photo.mapSymbol, photo.fieldX, photo.fieldZ)
    return loader:requestLocation(photo.mapSymbol, self._globalPosition.x, self._globalPosition.z, "required")
  end)
  if not ok then
    self.failure = result
    self.phase = "failed"
    self:_releaseOwned()
  elseif result then
    self._locationReady = true
  else
    self._locationReady = false
  end
end

local function fieldActorConfig(cacheFs)
  local index = assert(cacheFs:loadLua(FieldActorCache.indexPath()), "field actor index is unavailable")
  assert(
    type(index.runtime) == "table" and type(index.runtime.avatars) == "table",
    "field actor avatar config is invalid"
  )
  return index.runtime.avatars
end

local function avatarSprite(avatars, gender, state)
  local avatar = assert(avatars[gender + 1], "current-profile avatar is unavailable")
  return assert(avatar.states[state] or avatar.states.walking, "saved avatar state has no current-profile visual")
end

-- Saved-subject placement without image work: builds the same records and
-- unique sprite ids the viewer publishes, so later advances can prepare
-- each atlas before borrowing it.
local function planSubjects(self, localX, localZ)
  local photo = assert(self.photo)
  local cacheFs = assert(self.cacheFs)
  local avatars = fieldActorConfig(cacheFs)
  local records = {}
  local orderedIds = {}
  local seen = {}
  local function add(spriteId, actorId, x, z, pose)
    if not seen[spriteId] then
      seen[spriteId] = true
      orderedIds[#orderedIds + 1] = spriteId
    end
    return {
      actorId = actorId,
      spriteId = spriteId,
      world = { x = x + 0.5, y = 0, z = z + 0.5 },
      facing = "south",
      pose = pose or "idle",
      poseTick = 0,
    }
  end
  local playerSprite = avatarSprite(avatars, self.profile.gender, photo.avatarState)
  records[#records + 1] = add(playerSprite, "photo-player", localX, localZ, photo.avatarState)

  local monCatalog = assert(self.monCatalog, "photo scene requires the shared MonCatalog")
  local function follower(mon, x, z, actorId)
    if mon == false then
      return
    end
    local selection = monCatalog:followerSelection({ species = mon.species, form = mon.form, gender = mon.gender })
    records[#records + 1] = add(selection.visualId, actorId, x, z)
  end
  if photo.subjectSprite then
    local spriteId = tonumber(photo.subjectSprite)
    assert(spriteId and spriteId > 0 and spriteId % 1 == 0, "saved subject sprite is a decimal actor id")
    records[#records + 1] = add(spriteId, "photo-subject", localX + 2, localZ, "idle")
    follower(photo.party[1], localX + 1, localZ - 1, "photo-subject-pokemon")
  else
    local offsets = { { 2, 0 }, { 1, -1 }, { -1, -1 }, { 3, -1 }, { 0, -2 }, { 2, -2 } }
    for index, mon in ipairs(photo.party) do
      local offset = offsets[index]
      follower(mon, localX + offset[1], localZ + offset[2], "photo-party-" .. index)
    end
  end
  return records, orderedIds
end

local function centralParts(runtimeMap)
  local scene = assert(runtimeMap.sceneRuntime, "photo map has no scene presentation")
  local parts = {}
  for _, name in ipairs({ "mapDraws", "staticBuildingDraws", "runtimePropDraws", "animatedBuildingDraws" }) do
    parts[#parts + 1] = scene[name] or {}
  end
  return parts
end

local function withoutHidden(parts, hidden)
  local result = {}
  local omitted = {}
  for _, modelKey in ipairs(hidden) do
    if modelKey ~= false then
      omitted[modelKey] = true
    end
  end
  for _, part in ipairs(parts) do
    if not omitted[part.modelKey] then
      result[#result + 1] = part
    end
  end
  return result
end

function PhotoScene:_publish()
  local photo = assert(self.photo)
  local runtimeMap = assert(self.runtimeMap)
  local loader = assert(self.loader)
  local subjects = assert(self._actorPlan, "saved subjects are planned before the view publishes")
  local assets = assert(self.actorAssets, "saved subject visuals are staged before the view publishes")
  local localX, localZ = photo.fieldX, photo.fieldZ
  local sceneParts = centralParts(runtimeMap)
  if runtimeMap.scene.type == "outdoor" then
    self.coverage =
      loader:createPhysicalCoverage(runtimeMap, { fieldX = self._globalPosition.x, fieldZ = self._globalPosition.z })
    sceneParts[#sceneParts + 1] = self.coverage:worldParts()
  end
  local environment = copy(runtimeMap.renderEnvironment)
  environment.fieldTimeSeconds = photo.hour * 3600 + photo.minute * 60
  local spriteItems = FieldActorDraw.items(subjects, function(spriteId)
    return assert(assets:resident(spriteId), "photo actor visual is not resident")
  end)
  local visibleParts = {}
  for index, lane in ipairs(sceneParts) do
    visibleParts[index] = withoutHidden(lane, photo.hiddenPropModels)
  end
  self.view = {
    mapSectionNativeId = assert(runtimeMap.mapSectionNativeId, "saved map has its source map-section identity"),
    renderEnvironment = environment,
    camera = FieldCamera.new(PHOTO_CAMERA, {
      initialTarget = {
        x = localX + 0.5,
        y = 0,
        z = localZ + 0.5,
      },
    }),
    worldParts = visibleParts,
    spriteItems = spriteItems,
    subjects = subjects,
    viewport = { x = 4, y = 3, width = 248, height = 185 },
    alpha = 1,
  }
  self.phase = "ready"
end

function PhotoScene:advance(_)
  if self.disposed or self.phase ~= "pending" then
    return
  end
  local ok, err = pcall(function()
    local loader = assert(self.loader)
    local photo = assert(self.photo)
    if self.runtimeMap == nil then
      if self.task == nil then
        if not self._locationReady then
          local ready, failure =
            loader:requestLocation(photo.mapSymbol, self._globalPosition.x, self._globalPosition.z, "required")
          if failure then
            error(failure, 0)
          end
          if not ready then
            return
          end
          self._locationReady = true
        end
        self.task = loader:beginLoad(photo.mapSymbol)
      end
      local task = assert(self.task)
      task:advance(WORK_UNITS)
      if not task:isReady() then
        return
      end
      self.runtimeMap = task:takeResult()
      self.task = nil
    end
    if self._actorIds == nil then
      local records, orderedIds = planSubjects(self, photo.fieldX, photo.fieldZ)
      self._actorPlan = records
      self._actorIds = orderedIds
      local imageAssets = assert(self.imageAssets, "presented photo scene requires the field image pool")
      self.actorAssets = FieldActorAssetProvider.new(assert(self.cacheFs), { imageAssets = imageAssets })
    end
    local assets = assert(self.actorAssets)
    local wanted = assert(self._actorIds)
    local owned = {}
    for _, spriteId in ipairs(self.spriteIds) do
      owned[spriteId] = true
    end
    local budget = 2
    for _, spriteId in ipairs(wanted) do
      if not owned[spriteId] then
        local ready = assets:prepare(spriteId)
        if ready and budget > 0 then
          assets:acquire(spriteId)
          self.spriteIds[#self.spriteIds + 1] = spriteId
          owned[spriteId] = true
          budget = budget - 1
        end
      end
    end
    if #self.spriteIds < #wanted then
      return
    end
    self:_publish()
  end)
  if not ok then
    self.failure = err
    self.phase = "failed"
    self:_releaseOwned()
  end
end

function PhotoScene:status()
  assert(not self.disposed, "disposed photo scene has no status")
  return { phase = self.phase, failure = self.failure }
end

function PhotoScene:takeReady()
  assert(self.phase == "ready", "photo scene is not ready")
  local view = self.view
  self.view = nil
  return view
end

function PhotoScene:cancel()
  if self.disposed or self.phase ~= "pending" then
    return
  end
  self.generation = self.generation + 1
  self.phase = "cancelled"
  self:_releaseOwned()
end

function PhotoScene:dispose()
  if self.disposed then
    return
  end
  self.disposed = true
  self:_releaseOwned()
end

return PhotoScene
