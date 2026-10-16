-- Production-composed follower rejoin through the area-preview arrival: with a
-- follower in the party, booting outdoors on Route 46 and stepping through
-- the Dark Cave mouth commits the cave destination into its held time-aware
-- preview, and the follower must arrive hidden on the committed player tile
-- -- like retail HideUntilStep -- with exactly one stable partner identity;
-- the first trail step then re-shows it, ordinary following resumes, and the
-- reveal releases no extra actor and leaves the field unlocked. Real
-- ROM-derived maps, the real field runtime, and the real mon service stay in
-- the path; only host boundaries (audio, saves, clock) are faked by the
-- harness. The party setup goes through the production script-gift operation,
-- the same insertion the starter and field-script paths use. The journey
-- stops before any GPU draw, and every asserted key or stage is read from
-- live production state, never copied ROM text.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local OpeningLifecycle = require("tests.acceptance.support.OpeningLifecycle")

local ROUTE_46 = "MAP_ROUTE_46"
local DARK_CAVE = "MAP_DARK_CAVE_ROUTE_31_SIDE"

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
      "map-data:123",
      "map-data:48",
      "map-data:60",
      "map-data:134",
      "map-data:176",
      "map:33",
      "map:48",
      "map:60",
      "map:123",
      "map:134",
      "map:176",
    },
    tags = { "field", "following-mon", "rejoin" },
  },
  tests = {},
}

local DIRECTIONS = { "north", "south", "east", "west" }

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
    Assert.equal(game:renderAttempts(), 0, "the follower-rejoin journey must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(failure, 0)
  end
end

local function gift(game, species)
  local added = game.runtime.monService:giveMon({ species = species, level = 5, form = 0 })
  Assert.isTrue(added, "setup gift must enter the party: " .. tostring(species))
end

local function partnerId(game)
  return game.runtime.actors:partnerId()
end

local function waitForPartner(game)
  return game:advanceUntil("follower installation after party gift", function()
    return partnerId(game) ~= nil
  end, 120)
end

local function assertNoFault(game, where)
  Assert.isNil(game.runtime.errorText, "field runtime faulted " .. where .. ": " .. tostring(game.runtime.errorText))
end

local function playerTile(snapshot)
  return { fieldX = snapshot.player.fieldX, fieldZ = snapshot.player.fieldZ }
end

local function sameTile(a, b)
  return a.fieldX == b.fieldX and a.fieldZ == b.fieldZ
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

local function partnerCount(snapshot)
  local seen = 0
  for actorId in pairs(snapshot.actors) do
    if actorId == "field:partner" then
      seen = seen + 1
    end
  end
  return seen
end

-- One committed ordinary step in the first walkable direction; answers the
-- vacated player tile. Turns in place and blocked input never count.
local function committedStep(game)
  for _ = 1, 4 do
    for _, direction in ipairs(DIRECTIONS) do
      game:face(direction)
      local before = playerTile(game:snapshot())
      game:move(direction)
      game:advanceUntil("reveal movement resolves", function(snapshot)
        return snapshot.player.motion == "idle"
      end, 120)
      local after = playerTile(game:snapshot())
      if not sameTile(after, before) then
        return before
      end
    end
  end
  error("the arrival room offers no committable step for the reveal probe", 0)
end

function T.tests.preview_arrival_hides_the_follower_until_its_first_step()
  withGame(function(game)
    gift(game, "CHIKORITA")
    waitForPartner(game)
    assertNoFault(game, "while installing the follower")
    local before = assert(partnerId(game), "the lead gift must install one partner actor")
    Assert.equal(before, "field:partner", "the partner keeps its stable actor identity")

    local mouth = findWarpTile(game, ROUTE_46, DARK_CAVE)
    stepOnto(game, mouth)
    local completed = game:waitForTransition()
    assertNoFault(game, "across the preview transition")
    Assert.equal(completed.destination.mapSymbol, DARK_CAVE, "the preview completes onto the committed cave")
    -- Actor entry runs on the map-entry stages after the transition
    -- completes, so the reinstall lands a few ticks after the transition
    -- boundary; wait for it the same way every other scenario does.
    game:advanceUntil("partner reinstalls on the arrival map", function()
      return partnerId(game) ~= nil
    end, 120)
    freezeAutonomousActors(game)

    local runtime = game.runtime
    Assert.isFalse(runtime.transition.locked, "the completed reveal releases the field input lock")
    local id = assert(partnerId(game), "the preview arrival keeps exactly one partner installed")
    Assert.equal(id, before, "the arrival rejoins the same follower, never a second actor")
    local arrived = game:snapshot()
    Assert.equal(partnerCount(arrived), 1, "the arrival publishes exactly one follower actor")
    Assert.notNil(arrived.actors[id], "the rejoined follower is a real actor on the new map")
    Assert.isTrue(
      sameTile(arrived.actors[id], playerTile(arrived)),
      "the rejoined follower stands on the committed player tile"
    )
    Assert.isFalse(
      runtime.actors:isVisible(id),
      "the rejoined follower stays hidden until its first trail step, like retail HideUntilStep"
    )

    local followingMon = assert(runtime.followingMon, "the live following-mon controller is required")
    local vacated = committedStep(game)
    local revealed = game:advanceUntil("the follower re-shows on its first trail step", function(snapshot)
      local actor = snapshot.actors[id]
      return actor ~= nil
        and actor.fieldX == vacated.fieldX
        and actor.fieldZ == vacated.fieldZ
        and followingMon:isMovementSettled()
    end, 180)
    assertNoFault(game, "while revealing the follower")
    Assert.notNil(revealed.actors[id], "the revealed follower remains published after its step")
    Assert.isTrue(
      runtime.actors:isVisible(id),
      "the first trail step re-shows the follower, like the retail step observation clearing HideUntilStep"
    )
    Assert.equal(partnerId(game), id, "the reveal keeps the one stable follower identity")
    Assert.equal(partnerCount(game:snapshot()), 1, "the reveal installs no second follower")

    local second = committedStep(game)
    local trailing = game:advanceUntil("ordinary following resumes after the reveal", function(snapshot)
      local actor = snapshot.actors[id]
      return actor ~= nil
        and actor.fieldX == second.fieldX
        and actor.fieldZ == second.fieldZ
        and followingMon:isMovementSettled()
    end, 180)
    assertNoFault(game, "while trailing after the reveal")
    Assert.notNil(trailing.actors[id], "the follower keeps trailing after its reveal")
    Assert.isTrue(runtime.actors:isVisible(id), "the follower stays visible while trailing")
    Assert.equal(partnerId(game), id, "trailing keeps the one stable follower identity")
  end)
end

return T
