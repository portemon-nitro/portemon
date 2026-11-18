-- Production-composed field-step terrain responses for non-player map
-- objects. Retail spawns every stepping object's terrain response at that
-- object's own committed tile (MapObject_SpawnStepStartEffects), so an
-- ordinary autonomous map object must rustle its own grass exactly like the
-- player and the walking partner do.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = {
      "audio-bank:707",
      "audio-bank:708",
      "audio-bank:711",
      "audio-bank:712",
      "audio-bank:714",
      "field-runtime",
      "map-data:14",
      "map-data:16",
      "map-data:19",
      "map-data:20",
      "map-data:21",
      "map-data:53",
      "map-data:54",
      "map-data:59",
      "map:14",
      "map:16",
      "map:19",
      "map:20",
      "map:21",
      "map:53",
      "map:54",
      "map:59",
    },
    tags = { "field", "terrain", "autonomous" },
  },
  tests = {},
}

local TALL_GRASS = 2

-- Route 11's west-facing shuttle object paces its ±9-tile range along a line
-- that crosses a stand of tall grass west of its spawn tile.
local SHUTTLE_ACTOR_ID = "map:19:object:3"

local function behaviorAt(map, fieldX, fieldZ)
  local localX = fieldX - map.coordinateOrigin.x
  local localZ = fieldZ - map.coordinateOrigin.z
  if not map.collision:containsLocal(localX, localZ) then
    return nil
  end
  return map.collision:getLocal(localX, localZ).behavior
end

local function ownedEffect(snapshot, actorId)
  local terrainEffects = snapshot.terrainEffects
  local actor = snapshot.actors[actorId]
  if terrainEffects == nil or actor == nil then
    return nil
  end
  for _, instance in ipairs(terrainEffects.instances) do
    if
      instance.ownerKey == actorId
      and instance.fieldX == actor.fieldX
      and instance.fieldZ == actor.fieldZ
    then
      return instance
    end
  end
  return nil
end

function T.tests.autonomous_object_steps_spawn_their_own_grass_response()
  local versionId = AcceptanceHarness.defaultVersion()
  local game = AcceptanceHarness.new():boot({ versionId = versionId, map = "MAP_ROUTE_11", save = "fresh" })
  local ok, failure = xpcall(function()
    game:waitForFieldReady()
    local runtime = game.runtime
    local map = assert(runtime.runtimeMap, "field runtime map is required")
    local shuttle = assert(runtime.actors:getById(SHUTTLE_ACTOR_ID), "Route 11 keeps its shuttling object live")
    local start = shuttle:getFieldPosition()

    local stepped = game:advanceUntil("the shuttling object commits its first step", function(snapshot)
      local actor = snapshot.actors[SHUTTLE_ACTOR_ID]
      return actor ~= nil and (actor.fieldX ~= start.fieldX or actor.fieldZ ~= start.fieldZ)
    end, 120)
    Assert.isTrue(stepped.tick > 0, "the shuttling object's autonomy runs inside the player's residency")

    local rustled = game:advanceUntil("the shuttling object rustles the grass it crosses", function(snapshot)
      return ownedEffect(snapshot, SHUTTLE_ACTOR_ID) ~= nil
    end, 600)
    local instance = assert(ownedEffect(rustled, SHUTTLE_ACTOR_ID), "the rustle stays observable")
    local committed = assert(rustled.actors[SHUTTLE_ACTOR_ID], "the shuttling object stays on the map")
    Assert.equal(instance.fieldX, committed.fieldX, "the autonomous object owns the effect at its own tile")
    Assert.equal(instance.fieldZ, committed.fieldZ, "the autonomous object owns the effect at its own tile")
    Assert.equal(instance.kind, "tall_grass", "the autonomous step response names the tile's grass")
    Assert.equal(
      behaviorAt(map, committed.fieldX, committed.fieldZ),
      TALL_GRASS,
      "the response anchors a tall grass tile"
    )
    Assert.isTrue(instance.ownerKey ~= "player", "the autonomous object owns its own response")

    Assert.equal(game:renderAttempts(), 0, "autonomous step acceptance must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(failure, 0)
  end
end

return T
