-- Where an area-name announcement originates. The real post-swap coordinator
-- owns the durable destination publication, so a completed warp is the one
-- ordinary place that may announce the destination; a discarded prepared swap
-- announces nothing. The real zone controller is the seamless origin: it
-- reports a section change only when the map section actually changes, which
-- is the single fact a changed-section announcement is allowed to key on.

local Assert = require("tests.support.Assert")
local FieldWorldSwapCoordinator = require("game.hgss.src.field.FieldWorldSwapCoordinator")
local FieldZoneController = require("libs.hgss.src.world.FieldZoneController")

local T = {}

-- Records every area-name announcement the coordinator emits through the
-- runtime's banner owner.
local function bannerRecorder()
  return {
    requests = {},
    request = function(self, mapId, mapSectionNativeId)
      self.requests[#self.requests + 1] = { mapId = mapId, mapSectionNativeId = mapSectionNativeId }
      return true
    end,
  }
end

local function mapDouble(mapId, mapSymbol, sectionNativeId)
  return {
    mapId = mapId,
    mapSymbol = mapSymbol,
    mapSectionNativeId = sectionNativeId,
    fieldData = { transitionEnvironment = "outdoors" },
  }
end

-- The live runtime surface the commit owner touches, with the banner owner
-- attached and every unrelated collaborator reduced to the small recording
-- stand-in the commit path reads.
local function commitRuntime()
  local runtime = {
    runtimeMap = mapDouble(60, "MAP_NEW_BARK", 5),
    player = { fieldX = 10, fieldZ = 10, facing = "north" },
    transition = {},
    followingMon = nil,
    followingMonTransition = nil,
    audio = nil,
    playerVisual = nil,
    camera = nil,
    mapNameBanner = bannerRecorder(),
    fieldTerrainEffectController = { clear = function() end },
    zoneController = {},
    scripts = { onMapSwap = function() end },
    session = {
      beginMapEntry = function() end,
    },
    residency = {
      commitTransition = function()
        return true
      end,
      discardTransition = function()
        return true
      end,
    },
  }
  return runtime
end

local function preparedSwap()
  return { residency = {}, player = {}, playerVisual = {}, camera = {} }
end

function T.a_completed_warp_announces_the_destination_exactly_once()
  local runtime = commitRuntime()
  local coordinator = FieldWorldSwapCoordinator.new(runtime)
  coordinator:commit({ destinationMap = mapDouble(61, "MAP_ROUTE_29", 6) }, "north", preparedSwap())
  Assert.equal(#runtime.mapNameBanner.requests, 1, "a completed warp announces the destination once")
  Assert.deepEqual(
    runtime.mapNameBanner.requests[1],
    { mapId = 61, mapSectionNativeId = 6 },
    "the announcement carries the destination map and its native section"
  )
end

function T.a_same_section_warp_still_announces_the_destination()
  local runtime = commitRuntime()
  local coordinator = FieldWorldSwapCoordinator.new(runtime)
  -- Source and destination share one native section id; the ordinary warp
  -- route must not gate on section equality.
  coordinator:commit({ destinationMap = mapDouble(61, "MAP_ROUTE_29", 5) }, "north", preparedSwap())
  Assert.equal(#runtime.mapNameBanner.requests, 1, "the same-section destination is still announced once")
end

function T.a_discarded_prepared_swap_announces_nothing()
  local runtime = commitRuntime()
  local coordinator = FieldWorldSwapCoordinator.new(runtime)
  -- A completed warp is the baseline: exactly one announcement. A discard
  -- that follows it must not add a second.
  coordinator:commit({ destinationMap = mapDouble(61, "MAP_ROUTE_29", 6) }, "north", preparedSwap())
  Assert.equal(#runtime.mapNameBanner.requests, 1, "a completed warp announces the destination once")
  coordinator:abort({ destinationMap = mapDouble(60, "MAP_NEW_BARK", 5) }, {})
  Assert.equal(#runtime.mapNameBanner.requests, 1, "an aborted swap must not announce a destination")
end

-- The seamless origin reports a section change exactly when the section
-- differs; the runtime keys the changed-section announcement on this fact.
local function zoneController(currentMap, maps, changes)
  return FieldZoneController.new({
    currentMap = currentMap,
    mapForId = function(mapId)
      return maps[mapId]
    end,
    onChange = function(change)
      changes[#changes + 1] = change
    end,
  })
end

local function coverageReporting(mapId)
  return {
    mapHeaderAt = function()
      return mapId
    end,
  }
end

function T.a_crossed_section_reports_the_change_with_the_new_map()
  local town = { mapId = 60, mapSymbol = "MAP_NEW_BARK", mapSection = "NEW_BARK_TOWN" }
  local route = { mapId = 61, mapSymbol = "MAP_ROUTE_29", mapSection = "ROUTE_29" }
  local maps = { [60] = town, [61] = route }
  local changes = {}
  local controller = zoneController(town, maps, changes)
  local change = controller:afterCoverageCommit(coverageReporting(61), { fieldX = 1, fieldZ = 1 })
  Assert.notNil(change, "a committed cross-section move reports a change")
  Assert.isTrue(change.mapSectionChanged, "crossing a section boundary is a section change")
  Assert.equal(change.newMapId, 61, "the change names the destination map")
  Assert.equal(changes[1], change, "the change is published to the owner callback exactly once")
end

function T.a_header_change_within_one_section_is_not_a_section_change()
  local town = { mapId = 60, mapSymbol = "MAP_NEW_BARK", mapSection = "NEW_BARK_TOWN" }
  local house = { mapId = 63, mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_1F", mapSection = "NEW_BARK_TOWN" }
  local maps = { [60] = town, [63] = house }
  local changes = {}
  local controller = zoneController(town, maps, changes)
  local change = controller:afterCoverageCommit(coverageReporting(63), { fieldX = 1, fieldZ = 1 })
  Assert.notNil(change, "a committed in-section header change reports a change record")
  Assert.isFalse(change.mapSectionChanged, "a same-section header change is not a section change")
end

return { tests = T }
