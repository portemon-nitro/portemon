-- Resolves normalized field warp records into destination map coordinates and
-- terrain surfaces. Warp indexes are zero-based; event coordinates remain in
-- the authoritative global field domain. Scripted warps arrive as `direct`
-- records carrying pre-resolved global destination coordinates and resolve
-- through their own branch before any indexed-record dispatch. Dynamic-warp
-- anchors (destinationWarpId 0x100) resolve through the saved destination the
-- script recorded on the travel owner, exactly as the source
-- FieldSystem_MapConnection copies LocalFieldData.dynamicWarp wholesale; an
-- anchor with no established destination is attributed, never guessed. Warp
-- *trigger* semantics live in TransitionTrigger; this module only locates
-- records and resolves destinations.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local FieldCoordinates = require("libs.hgss.src.field.FieldCoordinates")
local SurfaceResolver = require("libs.hgss.src.world.SurfaceResolver")

local WarpSystem = {}

-- Dynamic-warp anchors: destinationWarpId 0x100 means the warp points at the
-- runtime-chosen destination stored on the travel owner. The source asserts
-- that such an anchor's map header is the 0xFFF sentinel, which names no map:
-- the saved record carries the destination map, its warp id, its map-local
-- tile, and the arrival facing.
WarpSystem.DYNAMIC_WARP_SENTINEL = 0x100

local WARP_Y_SCALE = 16

local function warps(runtimeMap)
  return assert(
    runtimeMap and runtimeMap.fieldData and runtimeMap.fieldData.events and runtimeMap.fieldData.events.warps,
    "runtime map warp data required"
  )
end

---@param sourceMap table<string, unknown>
---@param sourceWarp table<string, unknown>
---@param destinationMap table<string, unknown>
---@param destinationWarp table<string, unknown>?
---@param fieldX integer
---@param fieldZ integer
---@param sample table<string, unknown>
---@return table<string, unknown>
local function resolutionRecord(sourceMap, sourceWarp, destinationMap, destinationWarp, fieldX, fieldZ, sample)
  return {
    sourceMap = sourceMap,
    sourceWarp = sourceWarp,
    destinationMap = destinationMap,
    destinationWarp = destinationWarp,
    fieldX = fieldX,
    fieldZ = fieldZ,
    surfaceId = sample.surfaceId,
    worldY = sample.worldY,
    suppression = {
      mapId = destinationMap.mapId,
      fieldX = fieldX,
      fieldZ = fieldZ,
    },
  }
end

function WarpSystem.findAt(runtimeMap, fieldX, fieldZ)
  for _, warp in ipairs(warps(runtimeMap)) do
    if warp.x == fieldX and warp.z == fieldZ then
      return warp
    end
  end
  return nil
end

-- The trigger identity attributed to a destination-side failure of this warp.
---@param sourceMap table<string, unknown>
---@param warp table<string, unknown>
---@return table<string, unknown>
local function triggerContext(sourceMap, warp)
  return {
    sourceMapId = sourceMap.mapId,
    sourceWarpId = warp.index,
    destinationMapId = warp.destinationMapId,
    destinationWarpId = warp.destinationWarpId,
  }
end

-- Loads the destination map through the same unknown-destination-map wrap
-- whichever record named it: the triggered warp's own map header, or the
-- symbol the saved dynamic destination carries.
---@param loader { load: fun(loader: unknown, destinationMap: integer|string): table<string, unknown> }
---@param sourceMap table<string, unknown>
---@param warp table<string, unknown>
---@param destinationMap integer|string
---@return table<string, unknown>
local function loadDestination(loader, sourceMap, warp, destinationMap)
  local ok, result = pcall(loader.load, loader, destinationMap)
  if ok then
    return result
  end
  if Errors.is(result) and result.code == FieldErrors.FIELD_MAP_UNKNOWN then
    local context = triggerContext(sourceMap, warp)
    context.destinationMap = destinationMap
    context.cause = result.code
    Errors.raise(FieldErrors.FIELD_DESTINATION_MAP_UNKNOWN, "warp destination map is unavailable", context)
  end
  error(result, 0)
end

-- The saved dynamic destination of a dynamic-warp anchor. An anchor reached
-- with no established destination is attributed rather than resolved against
-- the sentinel header or the current map.
---@param sourceMap table<string, unknown>
---@param warp table<string, unknown>
---@param dynamicWarp table<string, unknown>?
---@return table<string, unknown> { map, fieldX, fieldZ, warpId, direction }
function WarpSystem.dynamicWarpRecord(sourceMap, warp, dynamicWarp)
  if dynamicWarp == nil then
    Errors.raise(FieldErrors.FIELD_DYNAMIC_WARP_UNSET, "dynamic warp anchor reached with no destination", {
      sourceMapId = sourceMap.mapId,
      sourceWarpId = warp.index,
      destinationMapId = warp.destinationMapId,
      destinationWarpId = warp.destinationWarpId,
    })
  end
  return assert(dynamicWarp, "a dynamic warp anchor carries a saved destination")
end

-- The arrival surface at a destination tile: an available height hint wins
-- (the destination warp record's height is authoritative), otherwise the
-- topmost walkable terrain surface at the point. Never an unconditional
-- zero-height hint: that selects the wrong floor on vertically stacked maps.
---@param destinationMap table<string, unknown>
---@param localX number
---@param localZ number
---@param hintY number?
---@return table<string, unknown> sample
local function warpSurface(destinationMap, localX, localZ, hintY)
  local x = localX + FieldCoordinates.TILE_CENTER_OFFSET
  local z = localZ + FieldCoordinates.TILE_CENTER_OFFSET
  if hintY ~= nil then
    return SurfaceResolver.new(destinationMap.terrain):resolve({ localX = x, localZ = z, currentY = hintY })
  end
  local best
  for _, plate in ipairs(destinationMap.terrain:candidatesAt(x, z)) do
    if plate.walkable ~= false then
      local sample = destinationMap.terrain:sample(plate.id, x, z)
      if best == nil or sample.worldY > best.worldY then
        best = sample
      end
    end
  end
  assert(best, "warp destination has no walkable terrain surface at its coordinates")
  return best
end

-- The arrival surface of a scripted direct warp. An explicit record `y` wins
-- (the caller's intent), then the destination map's indexed warp named by the
-- record, then the topmost walkable terrain surface.
---@param destinationMap table<string, unknown>
---@param warp table<string, unknown>
---@param localX number
---@param localZ number
---@return table<string, unknown> sample
local function directSurface(destinationMap, warp, localX, localZ)
  local hintY
  if type(warp.y) == "number" then
    hintY = warp.y
  else
    local destinationWarp = warps(destinationMap)[(warp.destinationWarpId or 0) + 1]
    if destinationWarp ~= nil and destinationWarp.index == (warp.destinationWarpId or 0) then
      hintY = destinationWarp.y / WARP_Y_SCALE
    end
  end
  return warpSurface(destinationMap, localX, localZ, hintY)
end

-- The arrival tile of a dynamic-warp destination in the global field domain.
-- A saved warp id names an event on the destination map whose tile the arrival
-- re-anchors on (FieldSystem_EnterLocation), so that record stays the arrival
-- anchor; the source's -1 names no record, and its saved map-local tile
-- converts through the destination origin instead.
---@param destinationFieldData table<string, unknown>
---@param destinationOrigin { x: integer, z: integer }? the destination map origin; required only when the saved warp id names no record
---@param dynamicWarp table<string, unknown> the saved destination record
---@param context table<string, unknown> trigger identity, { sourceMapId, sourceWarpId, destinationMapId }
---@return { fieldX: integer, fieldZ: integer, warp: table<string, unknown>? }
local function dynamicArrival(destinationFieldData, destinationOrigin, dynamicWarp, context)
  if dynamicWarp.warpId < 0 then
    assert(destinationOrigin, "a dynamic warp with no destination warp event needs the destination map origin")
    return {
      fieldX = dynamicWarp.fieldX + destinationOrigin.x,
      fieldZ = dynamicWarp.fieldZ + destinationOrigin.z,
    }
  end
  local destinationWarps = destinationFieldData.events.warps
  local destinationWarp = destinationWarps[dynamicWarp.warpId + 1]
  if not destinationWarp or destinationWarp.index ~= dynamicWarp.warpId then
    Errors.raise(FieldErrors.FIELD_DESTINATION_WARP_UNKNOWN, "destination warp index is unavailable", {
      sourceMapId = context.sourceMapId,
      sourceWarpId = context.sourceWarpId,
      destinationMapId = context.destinationMapId,
      destinationWarpId = dynamicWarp.warpId,
    })
  end
  return { fieldX = destinationWarp.x, fieldZ = destinationWarp.z, warp = destinationWarp }
end

-- The arrival tile a dynamic-warp destination resolves to, shared by warp
-- planning (lightweight field data plus the structural origin) and resolution
-- (a loaded destination map). The loaded map's own origin is the coordinate
-- authority there; a caller that only has field data passes the origin it
-- resolved from the structural world table.
---@param destinationMap table<string, unknown>
---@param dynamicWarp table<string, unknown> the saved destination record
---@param context table<string, unknown>? trigger identity for attribution
---@return { fieldX: integer, fieldZ: integer, warp: table<string, unknown>|nil }
function WarpSystem.dynamicDestination(destinationMap, dynamicWarp, context)
  assert(
    type(destinationMap) == "table" and destinationMap.fieldData and destinationMap.coordinateOrigin,
    "dynamic warp destination map and origin required"
  )
  if context == nil then
    context = { destinationMapId = destinationMap.mapId }
  end
  return dynamicArrival(destinationMap.fieldData, destinationMap.coordinateOrigin, dynamicWarp, context)
end

-- Shared destination coordinate selection for planning and resolution:
-- the global arrival coordinates and the selected destination warp record
-- for a source warp, preserving direct-before-dynamic-sentinel behavior
-- and indexed validation. Pure over already-loaded field data; height and
-- surface selection stay in resolveDestination.
---@param sourceMap table<string, unknown>
---@param warp table<string, unknown>
---@param destinationFieldData table<string, unknown>
---@param dynamicWarp table<string, unknown>? the saved dynamic destination for a dynamic anchor
---@param destinationOrigin { x: integer, z: integer }? the destination map origin; required only for lightweight field data with no saved warp record
---@return { fieldX: integer, fieldZ: integer, warp: table<string, unknown>? }
function WarpSystem.destinationCoordinates(sourceMap, warp, destinationFieldData, dynamicWarp, destinationOrigin)
  assert(sourceMap and sourceMap.mapId and warp, "source map and warp required")
  assert(
    destinationFieldData and destinationFieldData.events and destinationFieldData.events.warps,
    "destination field warp data required"
  )
  -- A scripted `direct` record carries pre-resolved global coordinates and
  -- selects itself before every indexed-path dispatch, including the
  -- dynamic-warp anchor.
  if warp.direct then
    assert(type(warp.x) == "number" and type(warp.z) == "number", "direct warp carries global coordinates")
    return { fieldX = warp.x, fieldZ = warp.z, warp = warp }
  end
  if warp.destinationWarpId == WarpSystem.DYNAMIC_WARP_SENTINEL then
    local record = WarpSystem.dynamicWarpRecord(sourceMap, warp, dynamicWarp)
    return dynamicArrival(destinationFieldData, destinationOrigin, record, triggerContext(sourceMap, warp))
  end
  local destinationWarps = destinationFieldData.events.warps
  local destinationWarp = destinationWarps[warp.destinationWarpId + 1]
  if not destinationWarp or destinationWarp.index ~= warp.destinationWarpId then
    Errors.raise(FieldErrors.FIELD_DESTINATION_WARP_UNKNOWN, "destination warp index is unavailable", {
      sourceMapId = sourceMap.mapId,
      sourceWarpId = warp.index,
      destinationMapId = warp.destinationMapId,
      destinationWarpId = warp.destinationWarpId,
    })
  end
  return { fieldX = destinationWarp.x, fieldZ = destinationWarp.z, warp = destinationWarp }
end

-- Everything a warp destination is before any surface is sampled: which logical
-- map, the arrival coordinates it names, and the facing a saved dynamic record
-- imposes. Splitting this out lets the covered-transition owner start staging the
-- destination's physical window while the cover is up, with the resolution
-- reading exactly the same decision.
---@class WarpSystem.DestinationPlan
---@field kind "direct"|"dynamic"|"indexed"
---@field destinationMap table<string, unknown>
---@field coordinates { fieldX: integer, fieldZ: integer, warp: table<string, unknown>? }
---@field facing string|nil

---@param loader { load: fun(loader: unknown, destinationMap: integer|string): table<string, unknown> }
---@param sourceMap table<string, unknown>
---@param warp table<string, unknown>
---@param dynamicWarp table<string, unknown>? the saved dynamic destination for a dynamic anchor
---@return WarpSystem.DestinationPlan
function WarpSystem.destinationPlan(loader, sourceMap, warp, dynamicWarp)
  assert(loader and loader.load, "warp destination loader required")
  assert(sourceMap and sourceMap.mapId and warp, "source map and warp required")
  if warp.direct then
    local destinationMap = loadDestination(loader, sourceMap, warp, warp.destinationMapId)
    return {
      kind = "direct",
      destinationMap = destinationMap,
      coordinates = WarpSystem.destinationCoordinates(sourceMap, warp, assert(destinationMap.fieldData)),
      facing = nil,
    }
  end
  if warp.destinationWarpId == WarpSystem.DYNAMIC_WARP_SENTINEL then
    local record = WarpSystem.dynamicWarpRecord(sourceMap, warp, dynamicWarp)
    local destinationMap = loadDestination(loader, sourceMap, warp, record.map)
    return {
      kind = "dynamic",
      destinationMap = destinationMap,
      coordinates = WarpSystem.dynamicDestination(destinationMap, record, triggerContext(sourceMap, warp)),
      facing = record.direction,
    }
  end
  local destinationMap = loadDestination(loader, sourceMap, warp, warp.destinationMapId)
  return {
    kind = "indexed",
    destinationMap = destinationMap,
    coordinates = WarpSystem.destinationCoordinates(sourceMap, warp, assert(destinationMap.fieldData)),
    facing = nil,
  }
end

---@param loader { load: fun(loader: unknown, destinationMap: integer|string): table<string, unknown> }
---@param sourceMap table<string, unknown>
---@param warp table<string, unknown>
---@param dynamicWarp table<string, unknown>? the saved dynamic destination for a dynamic anchor
---@return table<string, unknown>
function WarpSystem.resolveDestination(loader, sourceMap, warp, dynamicWarp)
  local plan = WarpSystem.destinationPlan(loader, sourceMap, warp, dynamicWarp)
  local destinationMap = plan.destinationMap
  local coordinates = plan.coordinates
  local localX, localZ = FieldCoordinates.fieldToLocal(destinationMap, coordinates.fieldX, coordinates.fieldZ)
  -- A scripted `direct` record carries pre-resolved global coordinates and
  -- resolves its own warp instead of an indexed destination record. It
  -- loads through the same unknown-destination-map wrap as the indexed path
  -- (one standardized code) and must precede every indexed-path dispatch,
  -- including the dynamic-warp anchor.
  if plan.kind == "direct" then
    local sample = directSurface(destinationMap, warp, localX, localZ)
    -- The direct record is the source trigger and the destination record in
    -- one table: it carries the pre-resolved destination coordinates.
    return resolutionRecord(
      sourceMap,
      warp,
      destinationMap,
      assert(coordinates.warp),
      coordinates.fieldX,
      coordinates.fieldZ,
      sample
    )
  end
  -- A dynamic anchor names its destination only through the saved record; the
  -- sentinel map header names no map, so the record's symbol loads it and its
  -- direction is the arrival facing the source creates the player with.
  if plan.kind == "dynamic" then
    local hintY
    if coordinates.warp ~= nil then
      hintY = coordinates.warp.y / WARP_Y_SCALE
    end
    local sample = warpSurface(destinationMap, localX, localZ, hintY)
    local resolution = resolutionRecord(
      sourceMap,
      warp,
      destinationMap,
      coordinates.warp,
      coordinates.fieldX,
      coordinates.fieldZ,
      sample
    )
    resolution.facing = plan.facing
    return resolution
  end
  local destinationWarp = assert(coordinates.warp, "the indexed path names its destination record")
  local hintY = destinationWarp.y / WARP_Y_SCALE
  local sample = SurfaceResolver.new(destinationMap.terrain):resolve({
    localX = localX + FieldCoordinates.TILE_CENTER_OFFSET,
    localZ = localZ + FieldCoordinates.TILE_CENTER_OFFSET,
    currentY = hintY,
  })
  return resolutionRecord(
    sourceMap,
    warp,
    destinationMap,
    destinationWarp,
    coordinates.fieldX,
    coordinates.fieldZ,
    sample
  )
end

function WarpSystem.isSuppressed(token, mapId, fieldX, fieldZ)
  return token ~= nil and token.mapId == mapId and token.fieldX == fieldX and token.fieldZ == fieldZ
end

function WarpSystem.updateSuppression(token, mapId, fieldX, fieldZ)
  if WarpSystem.isSuppressed(token, mapId, fieldX, fieldZ) then
    return token
  end
  return nil
end

return WarpSystem
