-- Owns field actor visual residency and conversion into draw records/items.

local FieldActorAssetProvider = require("libs.hgss.src.presentation.FieldActorAssetProvider")
local FieldActorDraw = require("libs.hgss.src.presentation.FieldActorDraw")

---@class FieldActorPresentationAssets: FieldActorAssets
---@field resident fun(self: FieldActorPresentationAssets, spriteId: integer): FieldActorDraw.Entry?
---@field prepare fun(self: FieldActorPresentationAssets, spriteId: integer): boolean
---@field cancelPreparation fun(self: FieldActorPresentationAssets, spriteId: integer): boolean

---@class FieldActorPresentationOptions
---@field assets FieldActorPresentationAssets? injected provider-shaped owner for focused tests

---@class FieldActorPresentationRuntime
---@field cacheFs CacheFs?
---@field imageAssets table<string, unknown>? the runtime-owned shared image owner borrowed by presented actors
---@field actors FieldActorManager
---@field playerVisual FieldPlayerVisual
---@field apricornTreePresentation table<string, function>?

---@class FieldActorPendingStage
---@field manager FieldActorManager
---@field revision integer
---@field playerSpriteId integer
---@field apricornRevision integer?
---@field needed integer[] sorted desired sprite IDs still being admitted
---@field staged table<integer, boolean> desired IDs already acquired by this stage

---@class FieldActorPresentation
---@field runtime FieldActorPresentationRuntime
---@field assets FieldActorPresentationAssets
---@field _presentationSpriteRefs table<integer, boolean>
---@field _lastActorManager FieldActorManager?
---@field _lastActorVisualRevision integer?
---@field _lastPlayerSpriteId integer?
---@field _lastApricornAssetRevision integer?
---@field _pending FieldActorPendingStage?
---@field _actorRecords table[]?
---@field _actorDrawStorage FieldActorDrawStorage?
local FieldActorPresentation = {}
FieldActorPresentation.__index = FieldActorPresentation

---@param runtime FieldActorPresentationRuntime
---@param options FieldActorPresentationOptions?
---@return FieldActorPresentation
function FieldActorPresentation.new(runtime, options)
  options = options or {}
  local self = setmetatable({
    runtime = runtime,
    assets = options.assets or FieldActorAssetProvider.new(
      assert(runtime.cacheFs, "field actor presentation cache filesystem is unavailable"),
      { imageAssets = assert(runtime.imageAssets, "presented field actors borrow the field image pool") }
    ),
    _presentationSpriteRefs = {},
    _pending = nil,
    _lastActorManager = nil,
    _lastActorVisualRevision = nil,
    _lastPlayerSpriteId = nil,
    _lastApricornAssetRevision = nil,
    _actorRecords = {},
    _actorDrawStorage = { items = {}, actorSlots = {}, generation = 0 },
  }, FieldActorPresentation)
  return self
end

---@param runtime FieldActorPresentationRuntime
---@return FieldActorManager actors
---@return integer actorRevision
---@return integer playerSpriteId
---@return integer? apricornAssetRevision
local function sampleDesired(runtime)
  local actors = assert(runtime.actors, "field actor manager is unavailable")
  local playerVisual = assert(runtime.playerVisual, "field player visual is unavailable")
  local actorRevision = actors:visualRevision()
  local playerSpriteId = assert(playerVisual.spriteId, "field player visual has no spriteId")
  local apricornTrees = runtime.apricornTreePresentation
  local apricornAssetRevision = apricornTrees ~= nil and apricornTrees:assetRevision() or nil
  return actors, actorRevision, playerSpriteId, apricornAssetRevision
end

---@param actors FieldActorManager
---@param actorRevision integer
---@param playerSpriteId integer
---@param apricornAssetRevision integer?
---@return boolean
function FieldActorPresentation:_isCommitted(actors, actorRevision, playerSpriteId, apricornAssetRevision)
  return self._lastActorManager == actors
    and self._lastActorVisualRevision == actorRevision
    and self._lastPlayerSpriteId == playerSpriteId
    and self._lastApricornAssetRevision == apricornAssetRevision
end

-- Returns only the staged references and drops staged preparation interest.
-- Committed references and drawable records are never touched.
function FieldActorPresentation:_rollbackStage()
  local stage = self._pending
  if stage == nil then
    return
  end
  self._pending = nil
  for spriteId in pairs(stage.staged) do
    self.assets:release(spriteId)
  end
  for _, spriteId in ipairs(stage.needed) do
    if not stage.staged[spriteId] and not self._presentationSpriteRefs[spriteId] then
      self.assets:cancelPreparation(spriteId)
    end
  end
end

---@return boolean installed true once the desired set is fully admitted
function FieldActorPresentation:sync()
  local runtime = self.runtime
  local actors, actorRevision, playerSpriteId, apricornAssetRevision = sampleDesired(runtime)
  if self:_isCommitted(actors, actorRevision, playerSpriteId, apricornAssetRevision) then
    self:_rollbackStage()
    return true
  end

  local stage = self._pending
  local sameStage = stage ~= nil
    and stage.manager == actors
    and stage.revision == actorRevision
    and stage.playerSpriteId == playerSpriteId
    and stage.apricornRevision == apricornAssetRevision
  if not sameStage then
    self:_rollbackStage()
    local neededSet = {}
    neededSet[playerSpriteId] = true
    actors:collectSpriteIds(neededSet)
    local apricornTrees = runtime.apricornTreePresentation
    if apricornTrees then
      apricornTrees:collectSpriteIds(neededSet)
    end
    local needed = {}
    for spriteId in pairs(neededSet) do
      needed[#needed + 1] = spriteId
    end
    table.sort(needed)
    stage = {
      manager = actors,
      revision = actorRevision,
      playerSpriteId = playerSpriteId,
      apricornRevision = apricornAssetRevision,
      needed = needed,
      staged = {},
    }
    self._pending = stage
  end
  assert(stage, "field actor admission stage is unavailable")

  local staged = stage.staged
  local ok, err = pcall(function()
    local budget = 2
    for _, spriteId in ipairs(stage.needed) do
      if not self._presentationSpriteRefs[spriteId] and not staged[spriteId] then
        if self.assets:prepare(spriteId) and budget > 0 then
          budget = budget - 1
          self.assets:acquire(spriteId)
          staged[spriteId] = true
        end
      end
    end
  end)
  if not ok then
    self:_rollbackStage()
    error(err, 0)
  end

  for _, spriteId in ipairs(stage.needed) do
    if not self._presentationSpriteRefs[spriteId] and not staged[spriteId] then
      return false
    end
  end

  local wanted = {}
  for _, spriteId in ipairs(stage.needed) do
    wanted[spriteId] = true
  end
  local retired = {}
  for spriteId in pairs(self._presentationSpriteRefs) do
    if not wanted[spriteId] then
      retired[#retired + 1] = spriteId
    end
  end
  table.sort(retired)
  for _, spriteId in ipairs(retired) do
    self.assets:release(spriteId)
    self._presentationSpriteRefs[spriteId] = nil
  end
  for spriteId in pairs(staged) do
    self._presentationSpriteRefs[spriteId] = true
  end
  self._lastActorVisualRevision = actorRevision
  self._lastActorManager = actors
  self._lastPlayerSpriteId = playerSpriteId
  self._lastApricornAssetRevision = apricornAssetRevision
  self._pending = nil
  return true
end

function FieldActorPresentation:_assetLookup(spriteId)
  return assert(self.assets:resident(spriteId), "field actor presentation visual is not resident")
  --[[@as FieldActorDraw.Entry]]
end

-- While a newer actor set is still being admitted, or the desired set has
-- diverged from the last admitted set (for example after a failed admission
-- left the committed set intact), draws keep serving the retained complete
-- set so no frame references an unadmitted sprite.
---@return boolean
function FieldActorPresentation:_holdingCommitted()
  if self._pending ~= nil then
    return true
  end
  if self._lastActorManager == nil then
    return false
  end
  local actors, actorRevision, playerSpriteId, apricornAssetRevision = sampleDesired(self.runtime)
  return not self:_isCommitted(actors, actorRevision, playerSpriteId, apricornAssetRevision)
end

---@param alpha number
---@return table[]
function FieldActorPresentation:drawItems(alpha)
  if self:_holdingCommitted() then
    local storage = assert(self._actorDrawStorage, "field actor draw storage is unavailable")
    return storage.items
  end
  local records = assert(self._actorRecords, "field actor presentation is disposed")
  records[1] = self.runtime.playerVisual:drawRecord(alpha)
  local actorRecords = self.runtime.actors:drawRecords(alpha)
  local apricornTrees = self.runtime.apricornTreePresentation
  if apricornTrees then
    apricornTrees:updateTreeSprites(actorRecords)
  end
  for index, record in ipairs(actorRecords) do
    records[index + 1] = record
  end
  local recordCount = #actorRecords + 1
  if apricornTrees then
    local fruit = apricornTrees:drawRecord()
    if fruit then
      recordCount = recordCount + 1
      records[recordCount] = fruit
    end
  end
  for index = #records, recordCount + 1, -1 do
    records[index] = nil
  end
  local storage = assert(self._actorDrawStorage, "field actor draw storage is unavailable")
  return FieldActorDraw.itemsInto(records, function(spriteId)
    return self:_assetLookup(spriteId)
  end, storage)
end

---@return table[]
function FieldActorPresentation:records()
  return assert(self._actorRecords, "field actor presentation is disposed")
end

function FieldActorPresentation:dispose()
  self:_rollbackStage()
  self._actorRecords = nil
  self._actorDrawStorage = nil
  for spriteId in pairs(self._presentationSpriteRefs) do
    self.assets:release(spriteId)
  end
  self._presentationSpriteRefs = {}
  if self.assets then
    self.assets:dispose()
    self.assets = nil
  end
end

return FieldActorPresentation
