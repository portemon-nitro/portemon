-- Production-composed transition contracts: one ordinary door ingress and one
-- House stairs profile-3 path.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local OpeningLifecycle = require("tests.acceptance.support.OpeningLifecycle")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = {
      "field-runtime",
      "map:60",
      "map:61",
      "map:63",
      "map:64",
      "map-data:67",
      "map-data:68",
      "map:67",
      "map:68",
    },
    tags = { "field", "transition", "door", "profile" },
  },
  tests = {},
}

local TOWN = "MAP_NEW_BARK"
local HOUSE_1F = "MAP_NEW_BARK_PLAYER_HOUSE_1F"
local HOUSE_2F = "MAP_NEW_BARK_PLAYER_HOUSE_2F"
local LAB_1F = "MAP_NEW_BARK_ELMS_LAB_1F"
local TOWN_DOOR_APPROACH = { fieldX = 684, fieldZ = 394 }
local HOUSE_WARP = { fieldX = 3, fieldZ = 3 }

local function freezeAutonomousActors(game)
  local runtime = game.runtime
  for mapId in pairs(runtime.actors.maps) do
    for _, actor in ipairs(runtime.actors:actorsOf(mapId)) do
      runtime.actors:setMovementType(actor.actorId, "stationary")
    end
  end
end

-- Drives one real step in `direction`: single presses can fall between
-- fixed ticks, so press until the committed tile changes (a turn-in-place
-- never counts), then prove the displacement.
local function driveStep(game, direction, label)
  game:face(direction)
  local start = game:snapshot().player
  for _ = 1, 20 do
    game:move(direction)
    local after = game:advanceUntil(label, function(snapshot)
      return snapshot.player.motion == "idle"
    end, 120)
    if after.player.fieldX ~= start.fieldX or after.player.fieldZ ~= start.fieldZ then
      return after
    end
  end
  error("no committable step " .. direction .. " for " .. label, 0)
end

-- Presses `direction` until a transition starts (bounded): single presses
-- can fall between fixed ticks, and the first press may only turn.
local function driveTransitionStart(game, direction, label)
  game:face(direction)
  for _ = 1, 20 do
    game:move(direction)
    if game.runtime.transition.phase ~= "idle" then
      return
    end
  end
  error("no transition started for " .. label, 0)
end

-- Source facts for the two transitions; identical across ready versions.
local FACTS = {
  house2fArrival = { fieldX = 3, fieldZ = 4 },
  -- The lab entry lands on the destination warp tile itself (retail warp
  -- placement), not on the map spawn one tile north of it.
  labFloor = { fieldX = 4, fieldZ = 14 },
  labDoorAnchor = { fieldX = 4, fieldZ = 14 },
  -- The shop entrance stands one tile north of its approach: the approach
  -- is the logical-local tile (43, 8), the door warp the global tile
  -- (555, 391), and the destination the indoor shop map.
  shopApproachLocal = { fieldX = 43, fieldZ = 8 },
  shopApproachGlobal = { fieldX = 555, fieldZ = 392 },
  shopMapId = 68,
}

local function withDefaultGame(map, fn, fieldOptions)
  local versionId = AcceptanceHarness.defaultVersion()
  local harness = AcceptanceHarness.new()
  local game = harness:boot({
    versionId = versionId,
    map = map,
    save = "fresh",
    fieldOptions = fieldOptions,
  })
  game:advanceDialogue()
  local ok, err = xpcall(function()
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "transition acceptance must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

local function hasEffect(game, sequence)
  for _, effect in ipairs(game:hostEffects()) do
    if effect == "audio:" .. sequence then
      return true
    end
  end
  return false
end

local function stepOntoHouseStairs(game)
  game:moveTo(HOUSE_WARP)
  game:advanceUntil("player reaches the stair landing", function(snapshot)
    return snapshot.player.motion == "idle"
      and snapshot.player.fieldX == HOUSE_WARP.fieldX
      and snapshot.player.fieldZ == HOUSE_WARP.fieldZ
  end, 60)
  game:step({ direction = "west" })
end

-- The one production door journey: the source door opens and the swap waits
-- for the completed ingress at full black, the entry lands on the
-- destination warp tile itself (retail warp placement), and a trailing
-- follower reinstalls hidden on the committed player tile until its first
-- trail step reveals it and ordinary visible trailing resumes. The egress
-- teleport, the mid-step reinstall, and the no-trail egress step live one
-- layer down in the cheap coordinator/transition/controller suites; this
-- boot pins only what needs the real maps, doors, and generated data.
function T.tests.door_entry_lands_on_the_warp_tile_with_the_follower_hidden_until_its_first_step()
  withDefaultGame(TOWN, function(game)
    OpeningLifecycle.seedNewBarkWestExitScene(game)
    OpeningLifecycle.settleNewBarkFriendScene(game)
    freezeAutonomousActors(game)
    local added = game.runtime.monService:giveMon({ species = "CHIKORITA", level = 5, form = 0 })
    Assert.isTrue(added, "setup gift must enter the party")
    game:advanceUntil("follower installation after party gift", function()
      return game.runtime.actors:partnerId() ~= nil
    end, 120)
    freezeAutonomousActors(game)
    game:moveTo(TOWN_DOOR_APPROACH)
    game:move("north")
    local transition = game.runtime.transition
    local neededRetry = transition.phase == "idle"
    if neededRetry then
      -- A single press can fall between fixed ticks; retry until the edge registers.
      driveTransitionStart(game, "north", "the lab door entry")
    end
    Assert.equal(transition.phase, "fade_out", "the production door input must start a transition")
    Assert.isTrue(hasEffect(game, "SEQ_SE_DP_DOOR_OPEN"), "door audio follows the selected source animation")
    Assert.notNil(transition.sourceDoor, "the production transition must resolve the source door")
    if not neededRetry then
      Assert.isNil(transition.resolution, "destination preparation waits for source door ingress")
    end
    game:advanceUntil("source door ingress completes", function()
      return transition.resolution ~= nil
    end, 120)
    Assert.equal(transition.resolution.fieldX, FACTS.labDoorAnchor.fieldX)
    Assert.equal(transition.resolution.fieldZ, FACTS.labDoorAnchor.fieldZ)
    Assert.equal(transition:presentationStatus().entryAction, "step_down")
    local completed = game:waitForTransition()
    Assert.equal(completed.destination.mapSymbol, LAB_1F, "the door completes into the lab")
    Assert.deepEqual(
      { completed.destination.player.fieldX, completed.destination.player.fieldZ },
      { FACTS.labFloor.fieldX, FACTS.labFloor.fieldZ },
      "a door entry lands on the destination warp tile"
    )
    game:advanceUntil("partner reinstalls on the arrival map", function()
      return game.runtime.actors:partnerId() ~= nil
    end, 180)
    freezeAutonomousActors(game)
    local followingMon = assert(game.runtime.followingMon, "the live following-mon controller is required")
    local id = assert(game.runtime.actors:partnerId(), "the arrival keeps one partner installed")
    local arrived = game:snapshot()
    Assert.equal(
      arrived.actors[id].fieldX,
      arrived.player.fieldX,
      "the rejoined follower stands on the committed player tile"
    )
    Assert.equal(
      arrived.actors[id].fieldZ,
      arrived.player.fieldZ,
      "the rejoined follower stands on the committed player tile"
    )
    Assert.isFalse(
      game.runtime.actors:isVisible(id),
      "the arrival keeps the follower hidden until its first trail step"
    )
    -- North off the arrival tile: the warp tile itself is no ordinary
    -- destination (normal movement cannot step back onto a door tile),
    -- so the single reveal step plus the settled visible follower is the
    -- whole production contract here; continued trailing lives in the
    -- cheap coordinator suite.
    local vacated = { fieldX = arrived.player.fieldX, fieldZ = arrived.player.fieldZ }
    local stepped = driveStep(game, "north", "the reveal step resolves")
    Assert.deepEqual(
      { stepped.player.fieldX, stepped.player.fieldZ },
      { vacated.fieldX, vacated.fieldZ - 1 },
      "the reveal step walks north off the arrival tile"
    )
    game:advanceUntil("the follower re-shows after the arrival", function(snapshot)
      local actor = snapshot.actors[id]
      return snapshot.player.motion == "idle"
        and actor ~= nil
        and actor.fieldX == vacated.fieldX
        and actor.fieldZ == vacated.fieldZ
        and followingMon:isMovementSettled()
    end, 180)
    Assert.isTrue(
      game.runtime.actors:isVisible(id),
      "the first trail step re-shows the follower on the vacated tile"
    )
  end, { recordingScriptHosts = true })
end

-- An outdoor shop door resolves in the physical cell that owns its
-- building: walking north onto the entrance completes the shop ingress in
-- the indoor shop map instead of rejecting the door as uncovered. The
-- boot spawns directly south of the door warp so the journey is one step.
function T.tests.outdoor_shop_door_enters_through_its_owning_cell()
  local harness = AcceptanceHarness.new()
  local defaultFactory = harness.gameFactory
  harness.gameFactory = function(vId, map)
    local game = defaultFactory(vId, map)
    if map == "MAP_CHERRYGROVE" then
      game.location.mapSymbol = "MAP_CHERRYGROVE"
      game.location.fieldX = FACTS.shopApproachLocal.fieldX
      game.location.fieldZ = FACTS.shopApproachLocal.fieldZ
      game.location.facing = "north"
    end
    return game
  end
  local versionId = AcceptanceHarness.defaultVersion()
  local game = harness:boot({ versionId = versionId, map = "MAP_CHERRYGROVE", save = "fresh" })
  local ok, err = xpcall(function()
    game:waitForFieldReady()
    local snapshot = game:snapshot()
    Assert.equal(snapshot.mapSymbol, "MAP_CHERRYGROVE")
    Assert.equal(snapshot.player.fieldX, FACTS.shopApproachGlobal.fieldX)
    Assert.equal(snapshot.player.fieldZ, FACTS.shopApproachGlobal.fieldZ)
    game:move("north")
    Assert.notNil(
      game.runtime.transition.sourceDoor,
      "the production transition must resolve the outdoor shop source door"
    )
    local completed = game:waitForTransition()
    Assert.equal(completed.destination.mapSymbol, "MAP_CHERRYGROVE_POKEMART")
    Assert.equal(completed.destination.mapId, FACTS.shopMapId)
    Assert.equal(game.runtime.transition.phase, "idle")
    Assert.equal(game:renderAttempts(), 0, "transition acceptance must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

function T.tests.player_house_stairs_remain_fixed_profile_three_indoors()
  local versionId = AcceptanceHarness.defaultVersion()
  local harness = AcceptanceHarness.new()
  local defaultFactory = harness.gameFactory
  harness.gameFactory = function(vId, map)
    local game = defaultFactory(vId, map)
    if map == HOUSE_1F then
      game.location.fieldX = 4
      game.location.fieldZ = 5
      game.location.facing = "south"
    end
    return game
  end
  local game = harness:boot({
    versionId = versionId,
    map = HOUSE_1F,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true },
  })
  OpeningLifecycle.seedPostOpeningHouseState(game)
  game:waitForFieldReady()
  local ok, err = xpcall(function()
    stepOntoHouseStairs(game)
    Assert.isFalse(game.runtime.player.motion == "climbing", "horizontal stairs must not use an in-place climb")
    local staged = game:advanceUntil("destination stair staging", function(snapshot)
      return snapshot.mapSymbol == HOUSE_2F
    end, 120)
    Assert.deepEqual(
      { staged.player.fieldX, staged.player.fieldZ },
      { FACTS.house2fArrival.fieldX, FACTS.house2fArrival.fieldZ },
      "profile three must expose its adjacent arrival tile after the swap"
    )
    game:advanceUntil("destination stair transition completes", function(snapshot)
      return snapshot.mapSymbol == HOUSE_2F
        and snapshot.transition.phase == "idle"
        and snapshot.player.motion == "idle"
        and snapshot.player.fieldX == FACTS.house2fArrival.fieldX
        and snapshot.player.fieldZ == FACTS.house2fArrival.fieldZ
    end, 120)
    Assert.equal(game.runtime.transition.profileId, 3, "indoor stairs retain fixed profile 3")
    Assert.equal(game.runtime.transition.sourceKind, "stairs", "the trigger remains a stair transition")
    Assert.isTrue(hasEffect(game, "SEQ_SE_DP_KAIDAN2"), "the stair exit emits the source sequence")
    Assert.deepEqual(
      { game.runtime.player.fieldX, game.runtime.player.fieldZ },
      { FACTS.house2fArrival.fieldX, FACTS.house2fArrival.fieldZ },
      "profile three must finish on the real destination arrival tile"
    )
    Assert.equal(game:renderAttempts(), 0, "transition acceptance must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
