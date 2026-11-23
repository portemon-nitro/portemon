-- ROM-conformance facts resolve the compiled Elm/New Bark warp pair all
-- the way through destination terrain selection without hardcoded endpoints,
-- and pin the generated elevator anchor's own transition classification so the
-- dynamic-warp profile-selection path stays a vanilla fact.

local Assert = require("tests.support.Assert")
local FieldTransitionProfile = require("libs.hgss.src.transition.FieldTransitionProfile")
local RomRuntimeMap = require("tests.support.RomRuntimeMap")
local TransitionTrigger = require("libs.hgss.src.transition.TransitionTrigger")
local WarpSystem = require("libs.hgss.src.transition.WarpSystem")

local T = {}

-- The source classification of a compiled map tile: the transition policy
-- reads the metatile behavior at the player's tile, so a ROM fact about a
-- vanilla warp classifies through the same owner the field session uses.
local function classificationAt(runtimeMap, fieldX, fieldZ)
  local localX = fieldX - runtimeMap.coordinateOrigin.x
  local localZ = fieldZ - runtimeMap.coordinateOrigin.z
  return TransitionTrigger.classify(runtimeMap.collision:getLocal(localX, localZ).behavior)
end

function T.elms_lab_and_new_bark_warps_resolve_both_directions(romFs)
  local maps = {
    [60] = RomRuntimeMap.compile(romFs, "MAP_NEW_BARK"),
    [61] = RomRuntimeMap.compile(romFs, "MAP_NEW_BARK_ELMS_LAB_1F"),
  }
  local loader = {
    load = function(_, mapId)
      return assert(maps[mapId])
    end,
  }

  local labWarp = assert(WarpSystem.findAt(maps[61], 4, 14))
  local outside = WarpSystem.resolveDestination(loader, maps[61], labWarp)
  Assert.equal(outside.destinationMap.mapId, 60)
  Assert.equal(outside.destinationWarp.index, 0)
  Assert.equal(outside.fieldX, 684)
  Assert.equal(outside.fieldZ, 393)
  Assert.notNil(maps[60].terrain:plate(outside.surfaceId))

  local townWarp = assert(WarpSystem.findAt(maps[60], 684, 393))
  local inside = WarpSystem.resolveDestination(loader, maps[60], townWarp)
  Assert.equal(inside.destinationMap.mapId, 61)
  Assert.equal(inside.destinationWarp.index, 0)
  Assert.equal(inside.fieldX, 4)
  Assert.equal(inside.fieldZ, 14)
  Assert.notNil(maps[61].terrain:plate(inside.surfaceId))
end

-- The source elevator anchor (FieldSystem_MapConnection's 0x100 branch): the
-- generated elevator map's own warp tile names no destination map, so the
-- script-recorded dynamic destination names the selected floor, and the
-- floor's matching warp returns to the elevator. Arriving on the elevator's
-- anchor is what makes the coordinator refresh the saved destination to the
-- entrance, so the journey closes without a hardcoded endpoint.
function T.elevator_anchor_resolves_the_scripted_floor_destination(romFs)
  local elevator = RomRuntimeMap.compile(romFs, "MAP_CELADON_CONDOMINIUMS_LEFT_ELEVATOR")
  local firstFloor = RomRuntimeMap.compile(romFs, "MAP_CELADON_CONDOMINIUMS_1F")
  local bySymbol = { MAP_CELADON_CONDOMINIUMS_1F = firstFloor }
  local byId = { [elevator.mapId] = elevator, [firstFloor.mapId] = firstFloor }
  local loader = {
    load = function(_, destination)
      return assert(byId[destination] or bySymbol[destination], "unknown destination " .. tostring(destination))
    end,
  }

  local anchor = assert(WarpSystem.findAt(elevator, 3, 6), "the generated elevator carries its anchor tile")
  Assert.equal(anchor.destinationWarpId, WarpSystem.DYNAMIC_WARP_SENTINEL, "the elevator tile is the dynamic anchor")

  -- Leaving through the anchor is an environment-mode warp: the anchor tile
  -- classifies as the directional south entrance. Profile selection therefore
  -- asks for the destination environment, which only the saved record can
  -- name -- the anchor's own 0xFFF header names no map.
  local anchorTrigger = assert(classificationAt(elevator, 3, 6), "the anchor tile carries a transition classification")
  Assert.equal(anchorTrigger.kind, "directional")
  Assert.equal(
    assert(anchorTrigger.transition, "the anchor tile carries a transition descriptor").mode,
    FieldTransitionProfile.MODE_ENVIRONMENT,
    "the elevator anchor selects its profile from the destination environment"
  )
  Assert.equal(
    elevator.fieldData.transitionEnvironment,
    "building",
    "the elevator's own environment is the selection source side"
  )

  -- The branch script's SetDynamicWarp MAP_CELADON_CONDOMINIUMS_1F, 2, 5, 3, 1:
  -- the saved warp id re-anchors the arrival tile, and the saved direction is
  -- the arrival facing (FieldSystem_EnterLocation creates the player with it).
  local saved = { map = "MAP_CELADON_CONDOMINIUMS_1F", warpId = 2, fieldX = 5, fieldZ = 3, direction = "south" }
  local arrival = WarpSystem.resolveDestination(loader, elevator, anchor, saved)
  Assert.equal(arrival.destinationMap.mapId, firstFloor.mapId)
  Assert.equal(arrival.destinationWarp.index, 2, "the saved warp id names the destination record")
  Assert.equal(arrival.fieldX, 3, "the destination record re-anchors the arrival tile")
  Assert.equal(arrival.fieldZ, 2)
  Assert.equal(arrival.facing, "south", "the saved direction is the arrival facing")
  Assert.notNil(firstFloor.terrain:plate(arrival.surfaceId))

  -- The floor's own warp returns to the elevator anchor, which is the arrival
  -- that refreshes the saved destination back to the floor the player left.
  local back = assert(WarpSystem.findAt(firstFloor, 3, 2), "the floor warp arrives where it leaves")
  local backArrival = WarpSystem.resolveDestination(loader, firstFloor, back)
  Assert.equal(backArrival.destinationMap.mapId, elevator.mapId)
  Assert.equal(backArrival.destinationWarp.destinationWarpId, WarpSystem.DYNAMIC_WARP_SENTINEL)
  -- The floor's return warp is the door into the elevator: its destination
  -- record on the elevator map is the 0x100 anchor, so the arrival is the one
  -- that records the entrance the anchor later leaves through.
  local backTrigger =
    assert(classificationAt(firstFloor, 3, 2), "the floor warp tile carries a transition classification")
  Assert.equal(backTrigger.kind, "door", "the floor returns through the elevator door")

  local unset = Assert.throws(function()
    WarpSystem.resolveDestination(loader, elevator, anchor)
  end)
  Assert.equal(unset.code, "FIELD_DYNAMIC_WARP_UNSET", "an anchor with no saved destination is attributed")
end

return require("tests.rom.support.RomSuite").fromFacts(T)
