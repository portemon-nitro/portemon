-- One production-composed, ROM-backed field proves the live area-name banner:
-- a real seamless section crossing announces the destination's native label
-- and compiled style from the running field, the reverse crossing announces
-- the return, and a real interior door warp whose destination header carries
-- no compiled style shows no banner. The banner is read straight from the
-- composed runtime, and the journey stops before any GPU draw.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local RomSourcePath = require("tests.rom.support.RomSourcePath")
local NavigationFacts = require("tests.rom.support.NavigationFacts")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local OpeningLifecycle = require("tests.acceptance.support.OpeningLifecycle")

-- The compiled area-window style each sampled source header projects from its
-- nonzero area icon (area icon minus one).
local NEW_BARK_STYLE = 1
local ROUTE_29_STYLE = 2

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = {
      "field-runtime",
      -- The banner reads its native section labels from bank 279 and its
      -- skins from the generated field-entry class.
      "field-entry:global",
      "message-bank:279",
      -- The traversed maps, their streamed coverage, and field music.
      "audio-bank:700",
      "audio-bank:702",
      "audio-bank:709",
      "map-data:31",
      "map-data:33",
      "map-data:34",
      "map-data:47",
      "map-data:48",
      "map-data:60",
      "map-data:61",
      "map-data:67",
      "map:33",
      "map:34",
      "map:60",
      "map:61",
      "map:67",
    },
    tags = { "field", "map-name" },
  },
  tests = {},
}

-- The area-name banner is owned by the composed field runtime. Reading it by
-- name keeps the pre-implementation failure attributable to the missing
-- behavior under test rather than a suite load error.
local function bannerStatus(game)
  local banner = game.runtime.mapNameBanner
  Assert.notNil(banner, "the running field must own an area-name banner")
  return banner:status()
end

local function freezeAutonomousActors(game)
  local runtime = game.runtime
  for mapId in pairs(runtime.actors.maps) do
    for _, actor in ipairs(runtime.actors:actorsOf(mapId)) do
      runtime.actors:setMovementType(actor.actorId, "stationary")
    end
  end
end

local function withVersion(fn)
  local harness = AcceptanceHarness.new()
  local versionId = AcceptanceHarness.defaultVersion()
  local romFs, romSource = RomSourcePath.openReader(versionId)
  assert(romFs, tostring(romSource))
  local facts = NavigationFacts.discover(CacheFs.forVersion(versionId), romFs)
  romFs:close()
  romSource:release()
  local game = harness:boot({ versionId = versionId, map = "MAP_NEW_BARK", save = "fresh" })
  OpeningLifecycle.seedNewBarkWestExitScene(game)
  OpeningLifecycle.settleNewBarkFriendScene(game)
  freezeAutonomousActors(game)
  local ok, failure = xpcall(function()
    fn(game, facts)
    Assert.equal(game:renderAttempts(), 0, "the map-name journey must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(failure, 0)
  end
end

local function moveTo(game, point, stopMapId)
  return game:moveTo({ fieldX = point.fieldX, fieldZ = point.fieldZ }, stopMapId)
end

function T.tests.area_name_banners_follow_eligible_arrivals_on_the_live_field()
  withVersion(function(game, facts)
    Assert.isNil(bannerStatus(game), "a freshly loaded field shows no area-name banner before any arrival")

    local crossing = moveTo(game, facts.zoneBoundary, facts.route29.mapId)
    Assert.equal(crossing.mapId, facts.route29.mapId, "the crossing lands on Route 29")
    Assert.notNil(crossing.zoneChange, "the seamless crossing publishes a zone change")
    Assert.isTrue(crossing.zoneChange.mapSectionChanged, "crossing from town to route changes the map section")
    local routeBanner = assert(bannerStatus(game), "a changed map section announces the destination area name")
    Assert.equal(routeBanner.styleKey, ROUTE_29_STYLE, "Route 29 carries its compiled area-window style")
    Assert.isTrue(
      type(routeBanner.title) == "string" and #routeBanner.title > 0,
      "the banner resolves a native section label"
    )

    game:waitForFieldReady()
    freezeAutonomousActors(game)
    -- Stop at the reverse crossing. The still-visible Route 29 banner departs
    -- first, so advance through the latest-pending replacement to the New Bark
    -- art the arrival announced before reading it.
    local returned = moveTo(game, facts.newBark, facts.newBark.mapId)
    Assert.equal(returned.mapId, facts.newBark.mapId, "the reverse crossing lands back in New Bark")
    Assert.isTrue(
      returned.zoneChange ~= nil and returned.zoneChange.mapSectionChanged,
      "crossing from route to town changes the map section back"
    )
    game:advanceUntil("reverse banner replacement", function()
      local status = bannerStatus(game)
      return status ~= nil and status.styleKey == NEW_BARK_STYLE
    end, 20)
    local townBanner = assert(bannerStatus(game), "the return crossing announces New Bark's area name")
    Assert.equal(townBanner.styleKey, NEW_BARK_STYLE, "New Bark carries its compiled area-window style")
    Assert.isTrue(
      type(townBanner.title) == "string" and #townBanner.title > 0,
      "the return resolves a native section label"
    )
    Assert.isTrue(
      townBanner.title ~= routeBanner.title,
      "distinct map sections resolve distinct native labels"
    )

    -- A real interior door warp from the same journey: the destination header
    -- carries no compiled style, so the arrival announces no area name.
    local building = facts.buildingWarp
    moveTo(game, building)
    game:face(building.direction)
    game:move(building.direction)
    game:advanceUntil("building transition starts", function(snapshot)
      return snapshot.transition.phase ~= "idle"
    end, 32)
    local interior = game:advanceUntil("building transition completes", function(snapshot)
      return snapshot.transition.phase == "idle" and snapshot.mapId ~= facts.newBark.mapId
    end, 120)
    Assert.isTrue(interior.mapId ~= facts.newBark.mapId, "the door warp lands inside the building")
    Assert.isNil(
      bannerStatus(game),
      "a building whose header has no compiled style shows no area-name banner"
    )
  end)
end

return T
