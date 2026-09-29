-- Production-composed Dig/Teleport returns and the checked Fly boundary:
-- real cave-entrance recording through genuine map transitions, Dig exit
-- through the composed field runtime/task/world/maps owners, Teleport
-- through saved spawn history, failed-warp fault containment, and the Fly
-- checked no-op inside the real menu flow. Stops before GPU rendering like
-- every acceptance path. Return-point facts ride the durable travel record;
-- no destination is ever derived from the live player position. Teleport
-- resolves through the compiled spawn landing index behind a port the
-- test wires to the version cache, and set_spawn legs update travel
-- through the script travel service; the red names a missing datum,
-- never infrastructure.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local RomFs = require("romdump.src.source.RomFs")
local NavigationFacts = require("tests.rom.support.NavigationFacts")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local OpeningLifecycle = require("tests.acceptance.support.OpeningLifecycle")
local FieldMovePolicy = require("libs.hgss.src.field.FieldMovePolicy")
local FieldMoveRuntime = require("libs.hgss.src.field.FieldMoveRuntime")
local FieldMoveWorld = require("game.hgss.src.field.FieldMoveWorld")
local FieldMoveTask = require("libs.hgss.src.script.tasks.FieldMoveTask")
local PartyActions = require("libs.hgss.src.field.PartyActions")
local PlayerProgression = require("libs.hgss.src.save.PlayerProgression")
local PokemonMenuFlow = require("game.hgss.src.field.PokemonMenuFlow")
local PartyCache = require("libs.assets.src.PartyCache")
local FieldUiFixture = require("tests.support.FieldUiFixture")

local T = {
  metadata = { capabilities = { "rom_dump" },
    derivedAssets = { "field-runtime", "audio-bank:702", "audio-bank:709", "audio-bank:728", "map-data:31", "map-data:33", "map-data:34", "map-data:35", "map-data:47", "map-data:48", "map-data:60", "map-data:67", "map-data:134", "map-data:176", "map:33", "map:48", "map:60", "map:134", "map:176" }, tags = { "field", "return" } },
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

local function withGame(fn, map)
  local harness = AcceptanceHarness.new()
  local versionId = AcceptanceHarness.defaultVersion()
  local romFs, err = RomFs.open(versionId)
  assert(romFs, tostring(err))
  local facts = NavigationFacts.discover(CacheFs.forVersion(versionId), romFs)
  romFs:close()
  -- Route 46 boots fresh at its own default spawn a short walk from the
  -- Dark Cave mouth. A New Bark start would trek through north Route 29,
  -- whose wandering NPC faults on missing seam surface data (an autonomy
  -- robustness defect outside this deliverable); the cave-entry behavior
  -- under test is identical from either start.
  local game = harness:boot({ versionId = versionId, map = map or "MAP_NEW_BARK", save = "fresh" })
  OpeningLifecycle.seedNewBarkWestExitScene(game)
  OpeningLifecycle.settleNewBarkFriendScene(game)
  freezeAutonomousActors(game)
  local ok, failure = xpcall(function()
    fn(game, facts)
    Assert.equal(game:renderAttempts(), 0, "return-move acceptance must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(failure, 0)
  end
end

local function awardBadge(game, key)
  local profile = assert(game.runtime.playerData and game.runtime.playerData.profile, "live profile required")
  PlayerProgression.new(profile):awardBadge(key)
  Assert.isTrue(PlayerProgression.new(profile):hasBadge(key), "badge award must persist on the live profile")
end

-- Party membership is seeded through the real script-gift operation: wild
-- encounters do not exist yet, and gifts are the source mechanic for new
-- party members.
local function giftMon(game, species)
  local mons = assert(game.runtime.monService, "live mon service required")
  Assert.isTrue(
    mons:giveMon({ species = species, level = 5, heldItem = "NONE", form = 0, location = 7 }),
    "setup gift must enter the party: " .. species
  )
  return mons:partyCount() - 1
end

local function teachMove(game, slot, itemKey)
  local runtime = game.runtime
  local mons = assert(runtime.monService, "live mon service required")
  local bag = assert(runtime.bagService, "live bag service required")
  Assert.isTrue(bag:add(itemKey, 1), "setup must stock " .. itemKey)
  local actions = PartyActions.new({ mons = mons, bag = bag })
  local outcome = actions:commit({
    kind = "teach_move",
    slot = slot,
    partyRevision = mons:partyRevision(),
    bagRevision = bag:revision(),
    item = itemKey,
  })
  Assert.equal(outcome.kind, "changed", itemKey .. " must teach, got " .. tostring(outcome.kind))
end

local function livePlayerPort(game)
  local runtime = game.runtime
  local player = assert(runtime.player, "live player required")
  local avatar = assert(runtime.playerAvatar, "live avatar transition owner required")
  local port = {}
  function port:position()
    return { fieldX = player.fieldX, fieldZ = player.fieldZ, worldY = player.worldY }
  end
  function port:facing()
    return player.facing
  end
  function port:beginScriptedAction(action)
    return player:beginScriptedAction(action)
  end
  function port:advanceScriptedAction(progress, duration)
    return player:advanceScriptedAction(progress, duration)
  end
  function port:commitScriptedAction()
    return player:commitScriptedAction()
  end
  function port:cancelScriptedMovement()
    return player:cancelScriptedMovement()
  end
  function port:isScriptedMoving()
    return player:isScriptedMoving()
  end
  function port:queueAvatarTransition(name)
    return avatar:queueTransition(name)
  end
  function port:applyAvatarTransitions()
    return runtime:applyAvatarTransitions()
  end
  return port
end

-- Menu-lane maps service: menu-origin returns run the ordinary
-- transition fade lifecycle, never the script-authored screen cover, so
-- the adapter is constructed without a screen (the service's supported
-- fallback path). It borrows the live transition/loader and the current
-- source map; callers rebuild it after any map change. Production
-- composition owns the equivalent long-lived wiring.
local function menuLaneWarps(game)
  local runtime = game.runtime
  local MapsService = require("libs.hgss.src.script.ScriptMapsService")
  return MapsService.new({
    transition = assert(runtime.transition, "live transition required"),
    loader = assert(runtime.mapLoader, "live map loader required"),
    sourceMap = assert(runtime.runtimeMap, "live source map required"),
  })
end

local function liveWorld(game, warpsOverride)
  local runtime = game.runtime
  local versionId = AcceptanceHarness.defaultVersion()
  local spawnCache = CacheFs.forVersion(versionId)
  local FieldMapDataCache = require("libs.assets.src.field.FieldMapDataCache")
  local spawns = {
    destinationFor = function(_, spawnKey)
      return FieldMapDataCache.spawnDestination(spawnCache, spawnKey)
    end,
  }
  return FieldMoveWorld.new({
    actors = assert(runtime.actors, "live actor manager required"),
    events = assert(runtime.eventState, "live event state required"),
    maps = {
      current = function()
        local map = runtime.runtimeMap
        return { symbol = map.mapSymbol, id = map.mapId, fieldUse = map.fieldData.fieldUse }
      end,
      runtimeMap = function()
        return runtime.runtimeMap
      end,
    },
    player = livePlayerPort(game),
    profile = assert(runtime.playerData and runtime.playerData.profile, "live profile required"),
    weather = {
      change = function(_, _)
        error("return-move acceptance covers no weather change", 2)
      end,
    },
    reactions = {
      dispatch = function(_, _)
        error("return-move acceptance covers no reaction dispatch", 2)
      end,
    },
    warps = warpsOverride or menuLaneWarps(game),
    spawns = spawns,
  })
end

-- Structural port for the return runtime under test: names exactly the
-- exercised boundary so helper-built subjects resolve their methods.
---@class ReturnRuntimePort
---@field queue fun(self: ReturnRuntimePort, request: table<string, unknown>): table<string, unknown>

local function liveRuntime(world)
  local runtime = FieldMoveRuntime.new({ policy = FieldMovePolicy, world = world })
  return runtime --[[@as ReturnRuntimePort]]
end

local function returnContext(game)
  local runtime = game.runtime
  local profile = assert(runtime.playerData and runtime.playerData.profile, "live profile required")
  return {
    badges = assert(profile.badges, "live badge mask required"),
    mapSymbol = runtime.runtimeMap.mapSymbol,
    mapId = runtime.runtimeMap.mapId,
    fieldUse = runtime.runtimeMap.fieldData.fieldUse,
    avatarMode = "walking",
    humanFollower = false,
    followingMon = false,
    rocketCostume = false,
    safari = false,
    palPark = false,
    surfEdge = false,
    facingWaterfall = false,
    facingWhirlpool = false,
    climbTile = false,
    headbuttTree = false,
    foggy = false,
    chatterOpen = false,
  }
end

local function liveTravel(game)
  return assert(game.runtime.fieldTravel, "live travel state required")
end

local function driveTask(game, runtime, state)
  local ctx = { services = { fieldMoves = runtime } }
  local result = nil
  game:advanceUntil("field task settles", function()
    local outcome = FieldMoveTask.poll(state, ctx)
    if outcome.complete then
      result = outcome.result
      return true
    end
    game:step()
    return false
  end, 1200)
  return assert(result, "field task must report a result")
end

local function runReturnPlan(game, runtime, move, slot, travel)
  local context = returnContext(game)
  local queued = runtime:queue({ move = move, slot = slot, context = context, travel = travel:capture() })
  Assert.equal(queued.kind, "accepted", move .. " admission must accept, got " .. tostring(queued.kind))
  local state = FieldMoveTask.create({ source = "pending" }, { services = { fieldMoves = runtime } })
  Assert.isNil(state.refused, move .. " planning must produce an executable plan")
  return driveTask(game, runtime, state)
end

-- Warp-tile discovery from generated warp data: the tile on the given
-- map whose warp leads to the given destination symbol. Discovery only
-- reads compiled records; every step after it is production movement.
local function findWarpTile(game, fromSymbol, toSymbol)
  local runtime = game.runtime
  local loader = assert(runtime.mapLoader, "live map loader required")
  local source = assert(loader:load(fromSymbol), fromSymbol .. " must load")
  local warps = assert(source.fieldData.events.warps, fromSymbol .. " needs warp events")
  for _, warp in ipairs(warps) do
    if warp.destinationMapId ~= nil then
      local target = loader:load(warp.destinationMapId)
      if target ~= nil and target.mapSymbol == toSymbol then
        return { tile = { fieldX = warp.x, fieldZ = warp.z }, destinationSymbol = toSymbol }
      end
    end
  end
  error("no warp from " .. fromSymbol .. " to " .. toSymbol, 0)
end

local function findDarkCaveMouth(game)
  return findWarpTile(game, "MAP_ROUTE_46", "MAP_DARK_CAVE_ROUTE_31_SIDE")
end

local function stepOnto(game, tile)
  game:moveTo(tile)
  freezeAutonomousActors(game)
  game:step()
end

local function waitForMap(game, symbol)
  game:advanceUntil("map swap to " .. symbol, function()
    freezeAutonomousActors(game)
    return game.runtime.runtimeMap.mapSymbol == symbol
  end, 600)
  freezeAutonomousActors(game)
end

local function settlePlayer(game)
  game:advanceUntil("field settles save-stable", function()
    local runtime = game.runtime
    local session = runtime.session
    local transitionIdle = session.transition == nil or session.transition.phase == "idle"
    local dialogueClear = session.dialogue == nil or not session.dialogue:isModal()
    local signpostClear = session.signpost == nil or not session.signpost:isModal()
    local hostClear = session.applicationHost == nil or not session.applicationHost:isActive()
    local avatar = runtime.playerAvatar
    local avatarClear = avatar == nil or avatar:isStableForSave()
    local entryClear = session.mapEntryController == nil or not session.mapEntryController:isActive()
    if
      runtime.player.motion == "idle"
      and transitionIdle
      and dialogueClear
      and signpostClear
      and hostClear
      and avatarClear
      and entryClear
    then
      return true
    end
    return false
  end, 1200)
end

function T.tests.dig_exits_to_the_recorded_outside_entrance()
  withGame(function(game)
    local geodude = giftMon(game, "GEODUDE")
    teachMove(game, geodude, "TM28")
    local mouth = findDarkCaveMouth(game)
    stepOnto(game, mouth.tile)
    waitForMap(game, mouth.destinationSymbol)
    local entrance = liveTravel(game):capture().escapeEntrance
    Assert.notNil(entrance, "entering the cave must record the outside entrance")
    settlePlayer(game)
    game:restart()
    freezeAutonomousActors(game)
    local reloaded = liveTravel(game):capture().escapeEntrance
    Assert.deepEqual(reloaded, entrance, "save/reload must preserve the recorded entrance")
    local mover = liveRuntime(liveWorld(game))
    local result = runReturnPlan(game, mover, "dig", geodude, liveTravel(game))
    Assert.equal(result.kind, "field_move_done", "dig must run to done")
    local settled = game:snapshot()
    Assert.equal(settled.mapSymbol, entrance.map, "dig must exit to the recorded entrance map")
    Assert.equal(settled.player.fieldX, entrance.fieldX, "dig must exit to the recorded entrance tile")
    Assert.equal(settled.player.fieldZ, entrance.fieldZ, "dig must exit to the recorded entrance tile")
  end, "MAP_ROUTE_46")
end

function T.tests.teleport_uses_explicit_heal_spawn_history()
  withGame(function(game)
    local geodude = giftMon(game, "GEODUDE")
    teachMove(game, geodude, "TM28")
    local travel = liveTravel(game)
    local before = travel:capture()
    Assert.equal(before.lastHealSpawn, "SPAWN_NEW_BARK", "fresh boot starts at the mother spawn")
    -- Medicine never writes respawn history, even when invoked: the
    -- use_item path executes fully and leaves the travel record alone.
    local runtime = game.runtime
    local mons = assert(runtime.monService, "live mon service required")
    local bag = assert(runtime.bagService, "live bag service required")
    Assert.isTrue(bag:add("POTION", 1), "setup must stock a potion")
    local actions = PartyActions.new({ mons = mons, bag = bag })
    local healing = actions:commit({
      kind = "use_item",
      slot = geodude,
      partyRevision = mons:partyRevision(),
      bagRevision = bag:revision(),
      item = "POTION",
    })
    Assert.equal(healing.kind, "no_effect", "a healthy mon needs no healing")
    Assert.deepEqual(travel:capture(), before, "medicine use must not rewrite respawn history")
    local mover = liveRuntime(liveWorld(game))
    local result = runReturnPlan(game, mover, "teleport", geodude, travel)
    Assert.equal(result.kind, "field_move_done", "teleport to the mother spawn must run to done")
    local settled = game:snapshot()
    Assert.equal(settled.mapSymbol, "MAP_NEW_BARK", "mother-spawn teleport must land in New Bark")
  end)
end

function T.tests.failed_return_warp_fabricates_nothing()
  withGame(function(game)
    local geodude = giftMon(game, "GEODUDE")
    teachMove(game, geodude, "TM28")
    local mouth = findDarkCaveMouth(game)
    stepOnto(game, mouth.tile)
    waitForMap(game, mouth.destinationSymbol)
    local runtime = game.runtime
    local realLoader = assert(runtime.mapLoader, "live map loader required")
    local loadCalls = 0
    local faultingLoader = setmetatable({
      load = function()
        loadCalls = loadCalls + 1
        return nil, "injected destination failure"
      end,
    }, { __index = realLoader })
    local MapsService = require("libs.hgss.src.script.ScriptMapsService")
    local faultingService = MapsService.new({
      transition = runtime.transition,
      loader = faultingLoader,
      sourceMap = runtime.runtimeMap,
    })
    local mover = liveRuntime(liveWorld(game, faultingService))
    local travel = liveTravel(game)
    local entrance = assert(travel:capture().escapeEntrance, "cave entry must record the entrance")
    local before = game:snapshot()
    local context = returnContext(game)
    local queued = mover:queue({ move = "dig", slot = geodude, context = context, travel = travel:capture() })
    Assert.equal(queued.kind, "accepted", "dig admission must accept before the injected failure")
    local state = FieldMoveTask.create({ source = "pending" }, { services = { fieldMoves = mover } })
    Assert.isNil(state.refused, "dig planning must produce an executable plan")
    local result = driveTask(game, mover, state)
    Assert.equal(result.kind, "field_move_failed", "the failed warp must fault the task, not succeed")
    Assert.equal(loadCalls, 1, "the failed warp must start exactly once")
    local settled = game:snapshot()
    Assert.equal(settled.mapSymbol, before.mapSymbol, "failure must not move the player")
    Assert.equal(settled.player.fieldX, before.player.fieldX, "failure must not jump position")
    Assert.equal(settled.player.fieldZ, before.player.fieldZ, "failure must not jump position")
    Assert.deepEqual(travel:capture().escapeEntrance, entrance, "failure must leave travel intact")
  end, "MAP_ROUTE_46")
end

local function stubMeasurement()
  local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")
  return {
    width = 256,
    height = 192,
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 256, height = 192 },
      touch = true,
      role = "world",
    }),
    pixelRatio = 1,
    signature = "return-flow-test:256x192",
  }
end

local function recordingIcons()
  local function prepare(_)
    return true, nil
  end
  local function cancel() end
  return { prepare = prepare, cancel = cancel }
end

local function openPartyFlow(game, checkDouble)
  local runtime = game.runtime
  local icons = recordingIcons()
  local mons = assert(runtime.monService, "live mon service required")
  local bag = assert(runtime.bagService, "live bag service required")
  local profile = assert(runtime.playerData and runtime.playerData.profile, "live profile required")
  local actions = PartyActions.new({ mons = mons, bag = bag })
  return PokemonMenuFlow.new({
    root = "party",
    mons = mons,
    bag = bag,
    bagCursor = assert(runtime.bagCursor, "live bag cursor required"),
    partyActions = actions,
    fieldMoves = checkDouble,
    assets = {
      bagManifest = {},
      partyManifest = PartyCache.loadManifest(CacheFs.forVersion(AcceptanceHarness.defaultVersion())),
      uiManifest = FieldUiFixture.manifest(),
      monCatalog = {
        moveByNativeId = function()
          error("fly acceptance needs no move catalog lookup", 0)
        end,
      },
      itemCatalog = bag:catalog(),
      heroGender = (profile.gender == 0) and "male" or "female",
    },
    measureDisplay = stubMeasurement,
    prepareIcons = icons.prepare,
    cancelIconPreparation = icons.cancel,
  })
end

-- Graph-exploring menu drivers: menus are FocusGraph-navigated, so these
-- seekers read live status and backtrack instead of assuming a layout.
local function childView(flow)
  local status = flow:status()
  Assert.isTrue(status.open, "the party flow stays open")
  return assert(status.child, "the party flow holds a live child")
end

local function focusSlot(flow, slot)
  for _ = 1, 12 do
    local child = childView(flow)
    if child.cursorNode == slot then
      return
    end
    flow:updateFixed({ { type = "navigate", direction = "down" } })
  end
  error("slot focus never settled on " .. tostring(slot), 0)
end

local function activateMenuMove(flow, move)
  flow:updateFixed({ { type = "confirm" } })
  for _ = 1, 30 do
    local child = childView(flow)
    local menu = assert(child.menu, "slot confirm must open the action menu")
    local current = menu[child.menuIndex]
    if current ~= nil and current.move == move then
      flow:updateFixed({ { type = "confirm" } })
      return
    end
    flow:updateFixed({ { type = "navigate", direction = "down" } })
  end
  error("the action menu never offered " .. move, 0)
end

function T.tests.fly_is_the_only_checked_silent_noop()
  withGame(function(game)
    local pidgey = giftMon(game, "PIDGEY")
    teachMove(game, pidgey, "HM02")
    local runtime = game.runtime
    local context = returnContext(game)
    local probe = liveRuntime(liveWorld(game))
    local refused = probe:queue({ move = "fly", slot = pidgey, context = context })
    Assert.equal(refused.kind, "need_badge", "fly without the storm badge must fail the real check")
    awardBadge(game, "storm")
    local mons = assert(runtime.monService, "live mon service required")
    local bag = assert(runtime.bagService, "live bag service required")
    local monRevision = mons:partyRevision()
    local bagRevision = bag:revision()
    local flyPpBefore = nil
    for _, entry in ipairs(assert(mons:partyMon(pidgey).moves, "fly mon carries moves")) do
      if entry.move == "FLY" then
        flyPpBefore = entry.pp
      end
    end
    Assert.notNil(flyPpBefore, "the setup must teach fly before the no-op leg")
    local playerBefore = game:snapshot().player
    local flow = openPartyFlow(game, {
      check = function(_)
        return { kind = "ok" }
      end,
    })
    local status = flow:status()
    Assert.isTrue(status.open, "the party flow opens")
    Assert.equal(status.page, "party_browse", "a party root opens the party page")
    flow:updateFixed({})
    focusSlot(flow, pidgey)
    activateMenuMove(flow, "FLY")
    status = flow:status()
    Assert.isTrue(status.open, "checked fly keeps the party flow open")
    Assert.equal(status.page, "party_browse", "checked fly returns to party browse")
    Assert.isNil(flow:takeResult(), "checked fly reports no terminal result")
    local after = game:snapshot()
    Assert.equal(after.player.fieldX, playerBefore.fieldX, "checked fly must not move the player")
    Assert.equal(after.player.fieldZ, playerBefore.fieldZ, "checked fly must not move the player")
    Assert.equal(mons:partyRevision(), monRevision, "checked fly must not publish mon changes")
    Assert.equal(bag:revision(), bagRevision, "checked fly must not consume items")
    if flyPpBefore ~= nil then
      local flyPpAfter = nil
      for _, entry in ipairs(assert(mons:partyMon(pidgey).moves, "fly mon carries moves")) do
        if entry.move == "FLY" then
          flyPpAfter = entry.pp
        end
      end
      Assert.equal(flyPpAfter, flyPpBefore, "checked fly must not spend move PP")
    end
    -- Fresh subsequent input works on the restored party: stale pointer
    -- releases are ignored, navigation moves, and a new menu opens.
    flow:updateFixed({ { type = "pointer_up", pointerId = "mouse:1", x = 0, y = 0 } })
    Assert.isNil(flow:takeResult(), "a stale release must not complete anything")
    focusSlot(flow, 0)
    flow:updateFixed({ { type = "confirm" } })
    local reopened = childView(flow)
    Assert.notNil(reopened.menu, "fresh input opens a new action menu after the no-op")
    flow:updateFixed({ { type = "cancel" } })
    flow:dispose()
  end)
end

return { tests = T.tests, metadata = T.metadata }
