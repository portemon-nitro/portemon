-- Production-composed Bicycle and fishing rod use through the real field
-- scheduler, script services, Bag admission, and registered-slot input on
-- New Bark Town: the Bicycle mounts with its music and puts the follower
-- away, counts its steps toward the Bike Shop call, refuses to dismount
-- under the Cycling Road lock, a registered rod
-- refused on dry land prints Oak's words, and a rod cast at the shore
-- animates the rod and lands a hooked Pokemon whose bite the friendly
-- follower notices before the wild battle. Scripted world draws make the encounter
-- roll hook and, once the line is out, make the bite draws exact; nothing
-- renders.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FakeAudioOutput = require("tests.acceptance.support.FakeAudioOutput")
local FieldCoordinates = require("libs.hgss.src.field.FieldCoordinates")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local FinalizedGameFixture = require("tests.support.FinalizedGameFixture")
local MetatileBehavior = require("libs.hgss.src.world.MetatileBehavior")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = {
      "field-runtime",
      "map-data:60",
      "map:60",
      "map-data:33",
      "map:33",
      "map-data:31",
      "map:31",
      "map-data:47",
      "map:47",
      "map-data:48",
      "map:48",
      "audio-bank:702",
      "audio-bank:709",
      "audio-bank:728",
      "message-bank:10",
      "message-bank:40",
    },
    tags = { "field", "acceptance" },
  },
  tests = {},
}

local NEW_BARK = "MAP_NEW_BARK"
local BIKE_SHOP_TRIGGER = "gear.trigger.2"
local SIDES = {
  { facing = "north", dx = 0, dz = -1 },
  { facing = "south", dx = 0, dz = 1 },
  { facing = "west", dx = -1, dz = 0 },
  { facing = "east", dx = 1, dz = 0 },
}

local function withGame(fn)
  local game = AcceptanceHarness.new({
    gameFactory = function(versionId)
      return FinalizedGameFixture.build(versionId, {
        location = { mapSymbol = NEW_BARK, fieldX = 10, fieldZ = 10, facing = "south" },
      })
    end,
  }):boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = NEW_BARK,
    save = "fresh",
    fieldOptions = {
      audioHost = "production",
      audioOutput = FakeAudioOutput.new(),
      recordingScriptHosts = true,
    },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "the acceptance stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- An open land tile and the facing toward a neighbor `wanted` accepts.
local function shoreTile(game, wanted)
  local map = game.runtime.runtimeMap
  local collision = map.collision
  local function cellAt(fieldX, fieldZ)
    local localX, localZ = FieldCoordinates.fieldToLocal(map, fieldX, fieldZ)
    if not collision:containsLocal(localX, localZ) then
      return nil
    end
    return collision:getLocal(localX, localZ)
  end
  for localZ = 0, 255 do
    for localX = 0, 255 do
      if collision:containsLocal(localX, localZ) then
        local cell = collision:getLocal(localX, localZ)
        if not cell.blocked and not MetatileBehavior.isSurfableWater(cell.behavior) then
          local fieldX, fieldZ = FieldCoordinates.localToField(map, localX, localZ)
          for _, side in ipairs(SIDES) do
            local neighbor = cellAt(fieldX + side.dx, fieldZ + side.dz)
            if neighbor ~= nil and wanted(neighbor.behavior) then
              return fieldX, fieldZ, side.facing
            end
          end
        end
      end
    end
  end
  error("New Bark Town has no matching shore tile", 0)
end

local function stand(game, fieldX, fieldZ, facing)
  game.runtime.player:setScriptPosition({ fieldX = fieldX, fieldZ = fieldZ })
  game:step()
  game:face(facing)
end

-- Steps until the named script ends, confirming dialogue as it waits and
-- failing on a script fault; a battle taking over ends the run.
local function runScriptToEnd(game, scriptId, firstEvent, onTick)
  for _ = 1, 900 do
    for index = firstEvent + 1, #game:hostEvents().records do
      local event = game:hostEvents().records[index]
      Assert.isTrue(event.name ~= "script.error", scriptId .. " must not fault: " .. tostring(event.payload.message))
      if event.name == "script.ended" and event.payload.scriptId == scriptId then
        return event.payload
      end
    end
    if game.runtime.battleCoordinator:hasBattleWork() then
      return { battle = true }
    end
    if onTick ~= nil and onTick() then
      game.runtime:pressAction()
      game:step()
      game.runtime:releaseAction()
    elseif game:snapshot().dialogue.waiting or game:snapshot().dialogue.modal then
      game.runtime:pressAction()
      game:step()
      game.runtime:releaseAction()
    else
      game:step()
    end
  end
  error(scriptId .. " did not end", 0)
end

-- Replaces the world generator with a scripted one: the listed values are
-- served in order, then a fixed series keeps wild generation deterministic.
local function scriptDraws(game, values)
  local drawn = 0
  local rng = {}
  function rng:nextRaw()
    drawn = drawn + 1
    return values[drawn] or (drawn * 977) % 65536
  end
  function rng:capture()
    return { state = 1, calls = drawn }
  end
  game.runtime.scripts.worldState.rng = rng
end

function T.tests.the_bicycle_and_rods_work_from_the_bag_and_registered_slots()
  withGame(function(game)
    local runtime = game.runtime
    local mons = assert(runtime.monService, "live mon service required")
    Assert.isTrue(
      mons:giveMon({ species = "CHIKORITA", level = 5, heldItem = "NONE", form = 0, location = 7 }),
      "setup gift must enter the party"
    )
    local bag = runtime.bagService
    Assert.isTrue(bag:add("BICYCLE", 1) and bag:add("OLD_ROD", 1), "the key items enter the Bag")
    game:step()
    game:step()
    Assert.isTrue(runtime.followingMon:isVisible(), "the lead follows the player")

    -- The Bag's Bicycle mounts with the bike music and puts the follower
    -- away; using it again dismounts and brings the follower back.
    local events = #game:hostEvents().records
    runtime:_admitFieldAction("pokemon.key_item", { item = "BICYCLE" })
    Assert.isTrue(runScriptToEnd(game, "runtime.bicycle", events).completed)
    game:step()
    Assert.equal(runtime.playerAvatar:durableState(), "cycling")
    Assert.notNil(runtime.audio:musicOverride(), "riding sets the bike music")
    Assert.isFalse(runtime.followingMon:isVisible(), "the follower is put away for the ride")
    Assert.isTrue(runtime.followingMon:isActive(), "a stowed follower stays active")
    -- The 1024th biked step raises the Bike Shop call trigger.
    local stats = runtime.gameStats
    for _ = 1, 1023 do
      stats:countBikedStep()
    end
    local function bikeShopTriggered()
      return runtime.pokegearState:readPhone().triggers[BIKE_SHOP_TRIGGER] == true
    end
    Assert.isFalse(bikeShopTriggered(), "1023 biked steps ring nobody")
    -- Steps south, away from the signpost north of the start tile that a
    -- coasting bike would bump and read.
    local function rideOneStep()
      local start = game:snapshot().player
      game:face("south")
      game:move("south")
      for _ = 1, 30 do
        local now = game:snapshot().player
        if now.motion == "idle" and now.fieldZ == start.fieldZ + 1 then
          return
        end
        game:step()
      end
      error("the rider cannot step south", 0)
    end
    rideOneStep()
    Assert.equal(stats:stepsBikedCount(), 1024, "the ridden step counts as biked")
    Assert.isTrue(bikeShopTriggered(), "the 1024th biked step raises the Bike Shop call")
    -- The answered call consumes its trigger, quiets the ring, and sets
    -- the got-call flag; after that, riding never raises it again.
    runtime.pokegearState:setTrigger(BIKE_SHOP_TRIGGER, false)
    runtime.incomingCalls:resetTransient("answered")
    runtime.eventState:setFlag(FieldScriptSymbols.flagsByName.FLAG_SYS_GOT_BIKE_SHOP_CALL)
    rideOneStep()
    Assert.equal(stats:stepsBikedCount(), 1025)
    Assert.isFalse(bikeShopTriggered(), "the Bike Shop calls only once")
    -- Under the Cycling Road lock the registered Bicycle refuses to
    -- dismount; once unlocked the Bag's Bicycle dismounts and brings the
    -- follower back with the map music.
    Assert.isTrue(bag:tryRegister("BICYCLE"), "the Bicycle registers to a slot")
    local bikeSlot = bag:registeredItems()[1] == "BICYCLE" and 1 or 2
    runtime.player:setBikeLocked(true)
    events = #game:hostEvents().records
    runtime.input:pressRegisteredSlot(bikeSlot, "test")
    game:step()
    runtime.input:releaseRegisteredSlot(bikeSlot, "test")
    Assert.isTrue(runScriptToEnd(game, "runtime.item_use_refusal.no_dismount", events).completed)
    Assert.equal(runtime.playerAvatar:durableState(), "cycling", "the locked bike stays mounted")
    runtime.player:setBikeLocked(false)
    Assert.isTrue(bag:unregister("BICYCLE"), "the Bicycle frees its slot")
    events = #game:hostEvents().records
    runtime:_admitFieldAction("pokemon.key_item", { item = "BICYCLE" })
    Assert.isTrue(runScriptToEnd(game, "runtime.bicycle", events).completed)
    Assert.equal(runtime.playerAvatar:durableState(), "walking")
    Assert.isNil(runtime.audio:musicOverride(), "dismounting returns to the map music")
    rideOneStep()
    Assert.equal(stats:stepsBikedCount(), 1025, "a walked step is not biked")

    -- A registered rod away from the water prints Oak's words.
    Assert.isTrue(bag:tryRegister("OLD_ROD"), "the rod registers to a slot")
    local slot = bag:registeredItems()[1] == "OLD_ROD" and 1 or 2
    local landX, landZ, landFacing = shoreTile(game, function(behavior)
      return not MetatileBehavior.isSurfableWater(behavior)
    end)
    stand(game, landX, landZ, landFacing)
    events = #game:hostEvents().records
    runtime.input:pressRegisteredSlot(slot, "test")
    game:step()
    runtime.input:releaseRegisteredSlot(slot, "test")
    Assert.isTrue(runScriptToEnd(game, "runtime.item_use_refusal.not_here", events).completed)

    -- At the shore the registered rod casts. Once the line is out the
    -- world draws are exact: a 30-tick bite, then the friendly follower's
    -- notice roll inside its 50% band. A on the bite lands the Pokemon.
    local mon = mons:partyMon(0)
    mons:applyFollowerInteractionDeltas(0, 255 - mon.friendship, 0)
    local shoreX, shoreZ, shoreFacing = shoreTile(game, MetatileBehavior.isSurfableWater)
    stand(game, shoreX, shoreZ, shoreFacing)
    scriptDraws(game, { 0 })
    events = #game:hostEvents().records
    runtime.input:pressRegisteredSlot(slot, "test")
    game:step()
    runtime.input:releaseRegisteredSlot(slot, "test")
    local fishing = runtime.fishingHost
    game:advanceUntil("the line goes out", function()
      return fishing:pose() == "cast"
    end, 30)
    scriptDraws(game, { 0, 0 })
    Assert.equal(runtime.playerAvatar:status().visualState, "fishing", "the cast shows the fishing visual")
    Assert.isTrue(runtime.pendingEncounter.environment.fished, "the hooked encounter carries the Lure Ball fact")
    game:step()
    local castFrame = runtime.playerVisual:status()
    Assert.equal(castFrame.pose, "walk", "the rod plays the fishing sprite's facing sequence")
    Assert.isTrue(castFrame.poseTick > 0, "the cast steps the line out")
    local noticed = nil
    local ended = runScriptToEnd(game, "runtime.fishing.old_rod", events, function()
      if fishing:pose() == "bite" and noticed == nil then
        noticed = assert(fishing:notice(), "the bite raises the mark")
        Assert.isTrue(runtime.playerVisual:status().poseTick < 15, "the bite dips the rod")
        return true
      end
      return false
    end)
    Assert.notNil(noticed, "the line bites")
    Assert.isTrue(noticed.onFollower, "the friendly follower notices the bite")
    Assert.equal(runtime.playerAvatar:status().visualState, "walking", "the rod is stowed before the battle")
    Assert.isTrue(ended.battle == true, "the landed Pokemon starts the wild battle")
  end)
end

return T
