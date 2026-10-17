-- Script camera focus presence: pinning samples the topmost walkable
-- surface, the focus resolves through the camera-target paths while
-- active, scripted walks interpolate and commit through the standard
-- movement seam, and map changes or explicit clears release it. The
-- presence lives outside the actor store (never drawn, saved, or in
-- occupancy).

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldActorManager = require("libs.hgss.src.actors.FieldActorManager")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local TerrainSurface = require("libs.hgss.src.world.TerrainSurface")

local T = {}

local POLICY = {
  variableSprites = { first = 101, last = 117, variableBase = 0x4020 },
}

local function terrain()
  return TerrainSurface.new({
    plates = {
      {
        id = 0,
        minX = 0,
        minZ = 0,
        maxX = 32,
        maxZ = 32,
        normal = { x = 0, y = 1, z = 0 },
        distance = 0,
        slopeClass = "flat",
      },
      {
        id = 1,
        minX = 8,
        minZ = 0,
        maxX = 32,
        maxZ = 32,
        normal = { x = 0, y = 1, z = 0 },
        distance = 4,
        slopeClass = "flat",
      },
    },
  })
end

local function testMap(mapId)
  return {
    mapId = mapId or 61,
    mapSection = "test-section",
    mapSectionNativeId = 7,
    followMode = "ALLOW",
    coordinateOrigin = { x = 0, z = 0 },
    collision = {
      containsLocal = function(_, x, z)
        return x >= 0 and x < 32 and z >= 0 and z < 32
      end,
    },
    terrain = terrain(),
    mapSymbol = "test-map",
    sceneRuntime = nil,
    scene = {},
    terrainDependencyHash = "test-terrain",
    fieldRegion = {},
    cameraType = 4,
    fieldData = { events = { objects = {}, background = {}, warps = {}, coordinates = {} } },
    release = function() end,
    updateAnimated = function() end,
  }
end

local function manager()
  local assets = {
    references = {},
    knows = function()
      return false
    end,
    acquire = function()
      error("focus presence acquires no visual", 0)
    end,
    release = function() end,
    total = function()
      return 0
    end,
  }
  local mgr = FieldActorManager.new({ assets = assets, policy = POLICY })
  mgr:enterMap(testMap(61), FieldEventState.new())
  return mgr
end

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected a structured error")
  Assert.equal(err.code, code, "expected " .. code)
  return err
end

function T.create_pins_the_topmost_walkable_surface_and_resolves()
  local mgr = manager()
  local id = mgr:createCameraTarget(10, 5)
  Assert.isTrue(type(id) == "string", "creation reports the stable focus identity")
  Assert.equal(mgr:cameraTargetId(), id, "the focus answers the camera-target path")
  Assert.equal(mgr:actorIdForMapIndex(241), id, "the focus answers the pinned object index")
  local position = mgr:getPosition(id)
  Assert.equal(position.fieldX, 10)
  Assert.equal(position.fieldZ, 5)
  local map = mgr.maps[61].runtimeMap
  local expectedY = math.max(map.terrain:sample(0, 10.5, 5.5).worldY, map.terrain:sample(1, 10.5, 5.5).worldY)
  Assert.equal(position.worldY, expectedY, "creation samples the topmost walkable surface")
  Assert.equal(mgr:getFacing(id), "south")
  Assert.isFalse(mgr:isScriptedMoving(id), "a fresh focus owns no motion")
  Assert.isFalse(mgr:isVisible(id), "the invisible focus never draws")
end

function T.unwalkable_tiles_and_missing_maps_fault()
  local mgr = manager()
  local map = mgr.maps[61].runtimeMap
  local oldCandidates = map.terrain.candidatesAt
  map.terrain.candidatesAt = function()
    return {}
  end
  throwsCode("FIELD_COORDINATES_OUT_OF_COVERAGE", function()
    mgr:createCameraTarget(10, 5)
  end)
  map.terrain.candidatesAt = oldCandidates
  Assert.isNil(mgr:cameraTargetId(), "a faulted creation pins nothing")
end

function T.walks_interpolate_and_commit_through_the_movement_seam()
  local mgr = manager()
  local id = mgr:createCameraTarget(10, 5)
  local before = mgr:getPosition(id)
  mgr:beginScriptedAction(id, { action = "walk", direction = "east", distance = "near", speed = "normal" })
  Assert.isTrue(mgr:isScriptedMoving(id), "the begun walk owns motion")
  mgr:advanceScriptedAction(id, 4, 8)
  local mid = mgr:getPosition(id)
  Assert.equal(mid.fieldX, before.fieldX, "committed tiles move only on commit")
  mgr:commitScriptedAction(id)
  local after = mgr:getPosition(id)
  Assert.equal(after.fieldX, 11, "the walk commits one tile east")
  Assert.equal(after.fieldZ, 5)
  Assert.isFalse(mgr:isScriptedMoving(id), "commit releases motion")
  mgr:beginScriptedAction(id, { action = "walk_in_place", direction = "west", speed = "normal" })
  mgr:setFacing(id, "west")
  mgr:advanceScriptedAction(id, 3, 8)
  mgr:commitScriptedAction(id)
  local held = mgr:getPosition(id)
  Assert.equal(held.fieldX, 11, "turns-in-place hold their tile")
  Assert.equal(mgr:getFacing(id), "west")
end

function T.cancel_abandons_motion_on_the_committed_tile()
  local mgr = manager()
  local id = mgr:createCameraTarget(10, 5)
  mgr:beginScriptedAction(id, { action = "walk", direction = "east", distance = "near", speed = "normal" })
  mgr:advanceScriptedAction(id, 7, 8)
  mgr:cancelScriptedMovement(id)
  Assert.isFalse(mgr:isScriptedMoving(id), "cancel releases motion")
  local position = mgr:getPosition(id)
  Assert.equal(position.fieldX, 10, "cancel keeps the committed tile")
  mgr:cancelScriptedMovement(id)
  Assert.isFalse(mgr:isScriptedMoving(id), "cancel without motion is a no-op")
end

function T.unsupported_focus_kinds_fault_like_unsupported_actor_actions()
  local mgr = manager()
  local id = mgr:createCameraTarget(10, 5)
  throwsCode("SCRIPT_UNSUPPORTED_REACHABLE", function()
    mgr:beginScriptedAction(id, { action = "jump", direction = "south", distance = "near", speed = "fast" })
  end)
end

function T.clear_and_map_changes_release_the_focus()
  local mgr = manager()
  mgr:createCameraTarget(10, 5)
  mgr:clearCameraTarget()
  Assert.isNil(mgr:cameraTargetId(), "explicit clear releases the focus")
  Assert.isNil(mgr:getPosition("script:camera_target"), "a released focus has no position")
  mgr:clearCameraTarget()
  mgr:createCameraTarget(10, 5)
  mgr:enterMap(testMap(62), FieldEventState.new())
  Assert.isNil(mgr:cameraTargetId(), "entering another map releases the dead focus")
  mgr:createCameraTarget(10, 5)
  local same = mgr.maps[62].runtimeMap
  mgr:enterMap(same, FieldEventState.new())
  Assert.notNil(mgr:cameraTargetId(), "rebinding the live map keeps its focus")
end

function T.focus_lives_outside_store_occupancy_and_save()
  local mgr = manager()
  mgr:createCameraTarget(10, 5)
  Assert.isNil(mgr:getById("script:camera_target"), "the focus is not a store actor")
  local captured = mgr:captureObjects()
  local found = false
  local function scan(value)
    if type(value) == "table" then
      for key, item in pairs(value) do
        if key == "actorId" and item == "script:camera_target" then
          found = true
        end
        scan(item)
      end
    end
  end
  scan(captured)
  Assert.isFalse(found, "capture never persists the transient focus")
end

return { tests = T }
