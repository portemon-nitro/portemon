-- Owns one destination verification lifetime for a relocated save.
-- The owner captures the requested six-field placement, session revision
-- and leave intent at start, advances its private verifier on step, and
-- emits at most one terminal result per operation. Verification is never
-- save authorization: the caller rechecks revision, placement and open
-- drafts before running its own transaction. This module never saves,
-- closes, or reports the application result.

local LocationService = require("app.src.saveeditor.SaveEditorLocationService")

---@class SaveEditorLocationSavePlacement
---@field mapId integer
---@field fieldX integer
---@field fieldZ integer
---@field surfaceId integer
---@field worldY number
---@field terrainDependencyHash string|integer

---@class SaveEditorLocationSaveDerivedAssets

---@class SaveEditorLocationSaveSavedObjects

---@class SaveEditorLocationSaveResources
---@field cacheFs CacheFs
---@field world SaveEditorStructuralWorld
---@field derivedAssets SaveEditorLocationSaveDerivedAssets
---@field savedObjects SaveEditorLocationSaveSavedObjects

---@class SaveEditorLocationSaveTicket
---@field kind string
---@field operationId integer
---@field sessionRevision integer
---@field location SaveEditorLocationSavePlacement
---@field leave boolean

---@alias SaveEditorLocationSaveSnapshot SaveEditorSnapshot

---@class SaveEditorLocationSaveTileStatus
---@field reason string?

---@class SaveEditorLocationSaveResult
---@field kind string
---@field reason string?
---@field operationId integer?
---@field sessionRevision integer?
---@field location SaveEditorLocationSavePlacement?
---@field leave boolean?
---@field tileStatus SaveEditorLocationSaveTileStatus?

---@class SaveEditorLocationSave
---@field resources SaveEditorLocationSaveResources
---@field operationId integer
---@field pending { operationId: integer, sessionRevision: integer, location: SaveEditorLocationSavePlacement, leave: boolean, verifier: SaveEditorLocationService }?
local LocationSave = {}
LocationSave.__index = LocationSave

local function copyLocation(location)
  return {
    mapId = location.mapId,
    fieldX = location.fieldX,
    fieldZ = location.fieldZ,
    surfaceId = location.surfaceId,
    worldY = location.worldY,
    terrainDependencyHash = location.terrainDependencyHash,
  }
end

local function sameLocation(left, right)
  return left.mapId == right.mapId
    and left.fieldX == right.fieldX
    and left.fieldZ == right.fieldZ
    and left.surfaceId == right.surfaceId
    and left.worldY == right.worldY
    and left.terrainDependencyHash == right.terrainDependencyHash
end

---@param resources SaveEditorLocationSaveResources
---@return SaveEditorLocationSave
function LocationSave.new(resources)
  assert(type(resources) == "table", "destination verification needs its resources")
  assert(resources.cacheFs ~= nil, "destination verification needs its cache filesystem")
  assert(type(resources.world) == "table", "destination verification needs its structural world")
  assert(type(resources.derivedAssets) == "table", "destination verification needs its derived-asset host")
  assert(type(resources.savedObjects) == "table", "destination verification needs its saved objects")
  return setmetatable({
    resources = resources,
    operationId = 0,
    pending = nil,
  }, LocationSave)
end

-- Starts one verification for the staged session snapshot. Returns false
-- without replacing the pending operation when a check is already running.
---@param sessionSnapshot SaveEditorLocationSaveSnapshot
---@param leave boolean
---@return boolean started
function LocationSave:start(sessionSnapshot, leave)
  if self.pending ~= nil then
    return false
  end
  assert(type(sessionSnapshot) == "table", "destination verification needs its session snapshot")
  assert(type(sessionSnapshot.revision) == "number", "destination verification needs its session revision")
  local location = assert(sessionSnapshot.location, "destination verification needs its staged placement")
  local resources = self.resources
  local verifier = LocationService.new({
    cacheFs = resources.cacheFs,
    world = resources.world,
    derivedAssets = resources.derivedAssets,
    savedObjects = resources.savedObjects,
  })
  local started, startError = pcall(function()
    verifier:openMap(location.mapId)
    verifier:setViewport(location.fieldX, location.fieldZ, 1, 1)
  end)
  if not started then
    verifier:dispose()
    error(startError, 0)
  end
  self.operationId = self.operationId + 1
  self.pending = {
    operationId = self.operationId,
    sessionRevision = sessionSnapshot.revision,
    location = copyLocation(location),
    leave = leave,
    verifier = verifier,
  }
  return true
end

-- Advances the pending verification against the current session snapshot.
-- Returns exactly one terminal result per operation: pending while staged
-- work runs, cancelled after revision or placement drift, failed with its
-- diagnostic, unresolvable with its tile status, drifted after the
-- placement moved during resolution, or one verified ticket. Settlement
-- releases the verifier exactly once.
---@param sessionSnapshot SaveEditorLocationSaveSnapshot
---@return SaveEditorLocationSaveResult result
function LocationSave:step(sessionSnapshot)
  local pending = self.pending
  if pending == nil then
    return { kind = "cancelled", reason = "destination check is not pending" }
  end
  if
    sessionSnapshot.revision ~= pending.sessionRevision
    or not sameLocation(sessionSnapshot.location, pending.location)
  then
    return self:_settle({ kind = "cancelled", reason = "the save changed during verification" })
  end
  pending.verifier:update()
  local readiness = pending.verifier:snapshot().status
  if readiness.state == "pending" then
    return { kind = "pending", operationId = pending.operationId }
  end
  if readiness.state ~= "ready" then
    return self:_settle({ kind = "failed", reason = readiness.reason or "The destination could not be verified." })
  end
  local placement, resolution = pending.verifier:resolve(
    pending.location.mapId,
    pending.location.fieldX,
    pending.location.fieldZ,
    pending.verifier:snapshot().generation
  )
  if placement == nil then
    return self:_settle({
      kind = "unresolvable",
      reason = resolution.reason or "The destination is unavailable.",
      tileStatus = resolution,
    })
  end
  if not sameLocation(placement, pending.location) then
    return self:_settle({ kind = "drifted", reason = "destination_changed_during_resolution" })
  end
  local ticket = {
    kind = "verified",
    operationId = pending.operationId,
    sessionRevision = pending.sessionRevision,
    location = copyLocation(pending.location),
    leave = pending.leave,
  }
  return self:_settle(ticket)
end

-- Reports the pending operation without advancing staged work.
---@return { state: string, operationId: integer }?
function LocationSave:status()
  local pending = self.pending
  if pending == nil then
    return nil
  end
  return { state = "pending", operationId = pending.operationId }
end

-- Retires the pending operation and releases its verifier. Late or stale
-- results can never yield a ticket afterwards.
function LocationSave:cancel()
  self:_settle(nil)
end

-- Releases any pending verification. The borrowed resources stay with
-- their owners.
function LocationSave:dispose()
  self:_settle(nil)
end

function LocationSave:_settle(result)
  local pending = self.pending
  self.pending = nil
  if pending ~= nil then
    pending.verifier:dispose()
  end
  return result
end

return LocationSave
