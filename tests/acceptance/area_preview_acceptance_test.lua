-- One production-composed, ROM-backed field proves the time-aware area
-- preview end to end. Booting outdoors on Route 46 and stepping through the
-- Dark Cave mouth commits the cave destination into a held preview selected
-- from the generated manifest for the host clock's daytime slot, with the
-- field input lock kept and the old warp fade retired; the reveal then
-- completes and releases the field. Stepping back out of the cave (a cave
-- source) never selects a preview. The journey stops before any GPU draw, and
-- every asserted key or stage is read from the live manifest or the live
-- transition, never copied ROM text.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local OpeningLifecycle = require("tests.acceptance.support.OpeningLifecycle")

local ROUTE_46 = "MAP_ROUTE_46"
local DARK_CAVE = "MAP_DARK_CAVE_ROUTE_31_SIDE"

-- The harness boots its local clock at hour 12, so the selection lands on the
-- second (day) slot; slots are zero-based morning/day/evening/night.
local DAY_SLOT = 1
local PREVIEW_STAGES = { fade_in = true, hold = true, blend_out = true }

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = {
      "field-runtime",
      "field-entry:global",
      "message-bank:279",
      "audio-bank:702",
      "audio-bank:709",
      "audio-bank:728",
      "map-data:31",
      "map-data:33",
      "map-data:34",
      "map-data:35",
      "map-data:47",
      "map-data:48",
      "map-data:60",
      "map-data:134",
      "map-data:176",
      "map:33",
      "map:48",
      "map:60",
      "map:134",
      "map:176",
    },
    tags = { "field", "area-preview" },
  },
  tests = {},
}

local function freezeAutonomousActors(game)
  local runtime = game.runtime
  for mapId in pairs(runtime.actors.maps) do
    for _, actor in ipairs(runtime.actors:actorsOf(mapId)) do
      runtime.actors:setMovementType(actor.actorId, "stationary")
    end
  end
end

local function withGame(fn)
  local harness = AcceptanceHarness.new()
  local versionId = AcceptanceHarness.defaultVersion()
  -- Route 46 boots fresh at its own default spawn a short walk from the Dark
  -- Cave mouth. The cave-entry behavior under test is identical from any
  -- start, and this avoids the unrelated north-Route-29 autonomy defect.
  local game = harness:boot({ versionId = versionId, map = ROUTE_46, save = "fresh" })
  OpeningLifecycle.seedNewBarkWestExitScene(game)
  OpeningLifecycle.settleNewBarkFriendScene(game)
  freezeAutonomousActors(game)
  local ok, failure = xpcall(function()
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "the area-preview journey must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(failure, 0)
  end
end

-- Warp-tile discovery from compiled warp data: the tile on the given map
-- whose warp leads to the given destination symbol. Discovery only reads
-- compiled records; every step after it is production movement.
local function findWarpTile(game, fromSymbol, toSymbol)
  local loader = assert(game.runtime.mapLoader, "live map loader required")
  local source = assert(loader:load(fromSymbol), fromSymbol .. " must load")
  local warps = assert(source.fieldData.events.warps, fromSymbol .. " needs warp events")
  for _, warp in ipairs(warps) do
    if warp.destinationMapId ~= nil then
      local target = loader:load(warp.destinationMapId)
      if target ~= nil and target.mapSymbol == toSymbol then
        return { fieldX = warp.x, fieldZ = warp.z }
      end
    end
  end
  error("no warp from " .. fromSymbol .. " to " .. toSymbol, 0)
end

local function stepOnto(game, tile)
  game:moveTo(tile)
  freezeAutonomousActors(game)
  game:step()
end

-- The arrival lands on the destination warp tile under recovery suppression,
-- so walking straight onto it is inert. Step to a walkable neighbour first;
-- leaving the tile clears the suppression, and the return walk re-arms it.
local function rearmWarp(game, tile)
  local player = game:snapshot().player
  if player.fieldX ~= tile.fieldX or player.fieldZ ~= tile.fieldZ then
    return
  end
  for _, offset in ipairs({ { 0, 1 }, { 0, -1 }, { 1, 0 }, { -1, 0 } }) do
    local neighbour = { fieldX = tile.fieldX + offset[1], fieldZ = tile.fieldZ + offset[2] }
    pcall(function()
      game:moveTo(neighbour)
    end)
    local after = game:snapshot().player
    if after.fieldX ~= tile.fieldX or after.fieldZ ~= tile.fieldZ then
      return
    end
  end
  error("could not step off the destination warp tile", 0)
end

function T.tests.an_outdoor_warp_holds_the_time_aware_preview_and_a_cave_warp_does_not()
  withGame(function(game)
    local runtime = game.runtime
    local transition = assert(runtime.transition, "live transition required")
    local manifest = assert(runtime.fieldEntryManifest, "the field-entry manifest is required")
    local destinationId = assert(runtime.mapLoader:load(DARK_CAVE), DARK_CAVE .. " must load").mapId
    local destinationSlots = assert(
      manifest.previewByMapId[destinationId],
      DARK_CAVE .. " must be a pinned preview destination"
    )

    Assert.isNil(
      transition:presentationStatus().preview,
      "a freshly booted field owns no preview before any warp"
    )

    local mouth = findWarpTile(game, ROUTE_46, DARK_CAVE)
    stepOnto(game, mouth)
    game:advanceUntil("the cave destination commits", function()
      freezeAutonomousActors(game)
      return game:snapshot().mapId == destinationId
    end, 480)

    local committed = transition:presentationStatus()
    local preview = committed.preview
    Assert.notNil(preview, "an eligible outdoor warp commits into a time-aware area preview")
    Assert.equal(preview.timeSlot, DAY_SLOT, "the harness day clock selects the daytime slot")
    Assert.equal(
      preview.imageKey,
      destinationSlots[DAY_SLOT],
      "the preview shows the committed destination's generated daytime image"
    )
    Assert.isTrue(
      PREVIEW_STAGES[preview.stage] == true,
      "the preview reports a known stage: " .. tostring(preview.stage)
    )
    Assert.isTrue(transition.locked, "the preview holds the field input lock")
    Assert.isNil(committed.overlay, "the completed warp fade must not cover the preview")
    Assert.equal(game:snapshot().mapSymbol, DARK_CAVE, "the destination is already the live map under the preview")

    local revealed = game:waitForTransition()
    Assert.equal(revealed.destination.mapSymbol, DARK_CAVE, "the preview completes onto the committed cave")
    Assert.isNil(transition:presentationStatus().preview, "the preview is released once the reveal completes")
    Assert.isFalse(transition.locked, "the completed reveal releases the field input lock")

    freezeAutonomousActors(game)
    local exit = findWarpTile(game, DARK_CAVE, ROUTE_46)
    rearmWarp(game, exit)
    stepOnto(game, exit)
    -- The Route 46 mouth is a directional WARP_SOUTH standing tile inside the
    -- cave: the exit begins on a fresh south press while the player stands on
    -- it, which the completed entrance step above does not provide.
    game:move("south")
    local sawPreview = false
    game:advanceUntil("the cave-source warp completes", function()
      freezeAutonomousActors(game)
      if transition:presentationStatus().preview ~= nil then
        sawPreview = true
      end
      local snapshot = game:snapshot()
      return snapshot.mapSymbol == ROUTE_46 and snapshot.transition.phase == "idle"
    end, 480)
    Assert.isFalse(sawPreview, "leaving a cave never selects a preview")
    Assert.isNil(transition:presentationStatus().preview, "no preview remains after an ineligible warp")
  end)
end

return T
