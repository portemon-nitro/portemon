-- Native roamer state through the real save and field composition. A journey's
-- published save is rewritten as the current envelope carrying the source's
-- four native roamer slots (source species, level, battle health and route),
-- and the production store loads it: the loaded owner keeps every slot, its
-- route and its battle health without guessing or drawing. The same journey
-- then crosses a real map connection, enters a real gatehouse door and crosses
-- back, so each source transition form is exercised on the live field: a
-- connection updates the player's location history and then moves every active
-- roamer along the source's 41-route graph with the source's own draw order,
-- while an ordinary warp only records the history and moves nothing. A real
-- Fly field move -- a party member that knows Fly, the Storm badge and a
-- confirmed flypoint in the Pokegear Fly map -- then reaches the source's fly
-- warp reset, which randomizes every active roamer inside its own region and
-- still records the player's arrival and departure. Only the audio, fade and
-- clock host boundaries are recorded; the save store, maps, scripts, actors
-- and roamer owner stay production-owned, and the render trap stays active
-- throughout.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local CacheFs = require("libs.storage.src.CacheFs")
local GeneratedCacheFixture = require("tests.support.GeneratedCacheFixture")
local FakeAudioOutput = require("tests.acceptance.support.FakeAudioOutput")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local FinalizedGameFixture = require("tests.support.FinalizedGameFixture")
local LuaWriter = require("libs.codec.src.LuaWriter")
local MapCatalog = require("romdump.src.digest.map.MapCatalog")
local NavigationFacts = require("tests.rom.support.NavigationFacts")
local OpeningLifecycle = require("tests.acceptance.support.OpeningLifecycle")
local PlayerProgression = require("libs.hgss.src.save.PlayerProgression")
local RoamerSourceFacts = require("tests.acceptance.support.RoamerSourceFacts")
local RomSourcePath = require("tests.rom.support.RomSourcePath")
local ScriptRng = require("libs.hgss.src.script.ScriptRng")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = {
      "field-runtime",
      "field-entry:global",
      "message-bank:279",
      -- The Fly selector's own information pane and Fly/Quit labels.
      "message-bank:273",
      -- The traversed maps, their streamed coverage and field music, plus the
      -- source fly warp's departure cry: the Fly user's own cry bank and the
      -- standard cry sequence's bank.
      "audio-bank:1",
      "audio-bank:16",
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
      "map-data:14",
      "map-data:134",
      "map:33",
      "map:34",
      "map:60",
      "map:61",
      "map:67",
      "map:134",
      "message-bank:373",
      "message-bank:374",
      "message-bank:542",
    },
    tags = { "field", "save", "encounter", "roamer" },
  },
  tests = {},
}

-- The shipped envelope and encounter bucket this scenario starts a journey
-- from. A native roamer slot only exists in the encounter bucket the source
-- roamer feature introduces.
local CURRENT_GAME_SCHEMA = "g4-game-save-v15"
local CURRENT_ENCOUNTER_SCHEMA = "hgss-encounter-v2"
local CURRENT_ENCOUNTER_STATE_VERSION = 2
-- The statistics bucket that envelope release shipped: the steps-biked total
-- existed, but no League-win, care, or Battle Point counters yet.
local CURRENT_GAME_STATS_SCHEMA = "hgss-stats-v3"
local CURRENT_GAME_STATS_STATE_VERSION = 3

local NEW_BARK = "MAP_NEW_BARK"
local ROUTE_29 = "MAP_ROUTE_29"
local ROUTE_29_GATEHOUSE = "MAP_ROUTE_29_ROUTE_46_GATEHOUSE"

-- The four source slots this journey carries: slot 0 Raikou/40, slot 1
-- Entei/40, slot 2 Latias/35, slot 3 Latios/35, each with its own route.
local SOURCE_SLOTS = {
  { key = "native.raikou", slot = 0, species = "RAIKOU", level = 40, routeIndex = 0, currentHp = 12 },
  { key = "native.entei", slot = 1, species = "ENTEI", level = 40, routeIndex = 1, currentHp = 77 },
  { key = "native.latias", slot = 2, species = "LATIAS", level = 35, routeIndex = 2, currentHp = 40 },
  { key = "native.latios", slot = 3, species = "LATIOS", level = 35, routeIndex = 3, currentHp = 55 },
}

local RAIKOU_STATUS_VAR = assert(FieldScriptSymbols.variablesByName.VAR_ROAMER_RAIKOU_STATUS)
local ENTEI_STATUS_VAR = assert(FieldScriptSymbols.variablesByName.VAR_ROAMER_ENTEI_STATUS)

---@param value unknown
---@return unknown
local function deepCopy(value)
  if type(value) ~= "table" then
    return value
  end
  local copy = {}
  for key, item in pairs(value) do
    copy[key] = deepCopy(item)
  end
  return copy
end

local routeMapId = RoamerSourceFacts.routeMapId

-- One persisted native roamer record in the shape the encounter owner already
-- stores, carrying its source slot and route beside the borrowed identity.
---@param source table source slot facts
---@param lifecycle string source lifecycle word
---@return table<string, unknown>
local function roamerRecord(source, lifecycle)
  return {
    key = source.key,
    stateVersion = CURRENT_ENCOUNTER_STATE_VERSION,
    mon = {
      species = source.species,
      personality = 31415900 + source.slot,
      met = { level = source.level },
      condition = { currentHp = source.currentHp, effects = {} },
    },
    location = routeMapId(source.routeIndex),
    lifecycle = lifecycle,
    revision = source.slot + 1,
    native = { slot = source.slot, routeIndex = source.routeIndex },
  }
end

---@param captured table the journey's own captured encounter bucket
---@param lifecycles table<string, string> lifecycle overrides by roamer key
---@return table<string, unknown> the current encounter bucket
local function nativeEncounterBucket(captured, lifecycles)
  local roamers = {}
  for _, source in ipairs(SOURCE_SLOTS) do
    roamers[source.key] = roamerRecord(source, (lifecycles or {})[source.key] or "roaming")
  end
  return {
    schema = CURRENT_ENCOUNTER_SCHEMA,
    stateVersion = CURRENT_ENCOUNTER_STATE_VERSION,
    steps = captured.steps,
    repelSteps = captured.repelSteps,
    swarm = captured.swarm,
    playerRoutes = { current = false, previous = false },
    roamers = roamers,
  }
end

---@return AcceptanceHarness
local function harness()
  return AcceptanceHarness.new({
    gameFactory = function(versionId, map)
      return FinalizedGameFixture.build(versionId, {
        location = { mapSymbol = map or NEW_BARK, fieldX = 10, fieldZ = 10, facing = "south" },
      })
    end,
  })
end

---@param game table acceptance game owning the production store
---@return string the save payload directory inside the acceptance save root.
-- The production store reads product saves from the global root, which the
-- acceptance save backend remaps below its own namespace.
local function payloadDirectory(game)
  return game.saveNamespace .. "/global/games"
end

---@param game table acceptance game owning the production store
---@param saveId string
---@return string the save payload path inside the acceptance save root
local function payloadPath(game, saveId)
  return payloadDirectory(game) .. "/" .. saveId .. ".lua"
end

-- Publish a journey's own save rewritten as the current envelope carrying the
-- native roamer slots, then load it through the production store so the
-- production Continue path owns every restored owner.
---@param lifecycles table<string, string>? lifecycle overrides by roamer key
---@return table loaded game record the production store answered
local function publishedNativeJourney(lifecycles)
  local versionId = AcceptanceHarness.defaultVersion()
  local game = harness():boot({ versionId = versionId, map = NEW_BARK, save = "fresh" })
  local loaded
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    local store = assert(game.runtime.saveStore, "the field runtime owns its save store")
    local captured = assert(game.runtime:captureGameSave(), "the journey captures its own save")
    local saveId = assert(captured.saveId, "a captured save names its identity")
    Assert.isTrue(store:publishFirst(captured), "the journey publishes its first save")

    local native = deepCopy(captured)
    native.schema = CURRENT_GAME_SCHEMA
    native.encounters = nativeEncounterBucket(captured.encounters, lifecycles)
    -- The envelope predates the Hall of Fame history, the Day Care, the
    -- Battle Point wallet, and the Game Corner coin balance, so its own copy
    -- carries none of those fields and its statistics keep the release's
    -- shape.
    native.hallOfFame = nil
    native.daycare = nil
    native.battlePoints = nil
    native.playerData.profile.coins = nil
    native.gameStats.schema = CURRENT_GAME_STATS_SCHEMA
    native.gameStats.stateVersion = CURRENT_GAME_STATS_STATE_VERSION
    native.gameStats.leagueWins = nil
    native.gameStats.daycareDeposits = nil
    native.gameStats.eggsHatched = nil
    native.gameStats.battlePointsReceived = nil
    native.gameStats.battlePointsSpent = nil
    assert(
      love.filesystem.createDirectory(payloadDirectory(game)),
      "the acceptance save root holds its payload directory"
    )
    assert(love.filesystem.write(payloadPath(game, saveId), LuaWriter.encode(native)), "the native payload is written")
    local loadOk, recordOrError = pcall(function()
      return store:load(saveId)
    end)
    Assert.isTrue(
      loadOk and type(recordOrError) == "table",
      "the production store loads the journey's current native roamer save: " .. tostring(recordOrError)
    )
    loaded = recordOrError
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
  return loaded
end

---@param loaded table game record the production store answered
---@return table game live acceptance game continuing that journey
local function continueJourney(loaded)
  local game = AcceptanceHarness.new({
    gameFactory = function()
      return loaded
    end,
  }):boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = NEW_BARK,
    save = "continue",
    fieldOptions = { recordingScriptHosts = true, audioHost = "recording" },
  })
  local ok, err = pcall(function()
    game:waitForFieldEntry()
  end)
  if not ok then
    game:close()
    error(err, 0)
  end
  return game
end

---@param game table
---@return table<string, unknown> captured encounter state
local function capturedEncounters(game)
  local roamers = assert(game.runtime.roamerState, "the field runtime owns its roamer state")
  return assert(roamers:capture(), "the roamer owner captures its own state")
end

---@param game table
---@return table<string, table> roamer records by key
local function capturedRoamers(game)
  return assert(capturedEncounters(game).roamers, "the roamer capture carries its records")
end

---@param game table
---@return table<string, unknown> the persisted player route history
local function playerRoutes(game)
  local history = assert(
    capturedEncounters(game).playerRoutes,
    "the roamer owner captures the player's route history"
  )
  return history
end

local routeIndexOf = RoamerSourceFacts.routeIndexOf

-- The four keys the journey carries, in source slot order.
local SLOT_KEYS = {}
for index, source in ipairs(SOURCE_SLOTS) do
  SLOT_KEYS[index] = source.key
end

-- field_roamer.c::Save_UpdateRoamersLocation over the source's own route graph,
-- drawing from the one world stream in source order. Returns the route indexes
-- it predicts.
---@param roamers table<string, table> the journey's captured roamer records
---@param lastLocation integer|false the source's player-location history back
---@param rng table a detached copy of the world stream
---@return table<integer, integer> predicted route index by slot
local function simulateSourceUpdate(roamers, lastLocation, rng)
  return RoamerSourceFacts.simulateUpdate(roamers, SLOT_KEYS, lastLocation, rng)
end

-- A detached source-clock world stream copy: the roamer transition must draw
-- from this one shared stream, never a private generator.
---@param game table
---@return table
local function clonedWorldRng(game)
  local worldState = assert(game.runtime.scripts, "the field owns its script platform").worldState
  return ScriptRng.restore(assert(worldState.rng, "the world owns its generator"):serialize())
end

---@param game table
---@return string the world stream state
local function worldRngState(game)
  return assert(game.runtime.scripts.worldState.rng:serialize()).state
end

-- Freeze map actors that would otherwise wander across a planned route.
---@param game table
local function freezeAutonomousActors(game)
  local runtime = game.runtime
  for mapId in pairs(runtime.actors.maps) do
    for _, actor in ipairs(runtime.actors:actorsOf(mapId)) do
      runtime.actors:setMovementType(actor.actorId, "stationary")
    end
  end
end

-- ---------------------------------------------------------------------------
-- Persistence: the production store loads four native slots with their source
-- species, levels, routes and battle health, draws nothing to do so, and the
-- next capture round-trips them unchanged through Continue.
-- ---------------------------------------------------------------------------

function T.tests.native_roamer_slots_and_battle_health_roundtrip_through_continue()
  local loaded = publishedNativeJourney(nil)
  local game = continueJourney(loaded)
  local ok, err = xpcall(function()
    local roamers = capturedRoamers(game)
    for _, source in ipairs(SOURCE_SLOTS) do
      local record = assert(
        roamers[source.key],
        "Continue restores the native roamer slot as " .. source.key
      )
      Assert.equal(record.native.slot, source.slot, "the restored " .. source.species .. " keeps its source slot")
      Assert.equal(
        record.native.routeIndex,
        source.routeIndex,
        "the restored " .. source.species .. " keeps its source route index"
      )
      Assert.equal(record.mon.species, source.species, "the restored roamer carries its source species")
      Assert.equal(record.mon.met.level, source.level, "the restored roamer carries its source level")
      Assert.equal(
        record.mon.condition.currentHp,
        source.currentHp,
        "the restored " .. source.species .. " keeps the battle health it was saved with"
      )
      Assert.equal(record.lifecycle, "roaming", "the restored " .. source.species .. " keeps its roaming lifecycle")
      Assert.equal(record.revision, source.slot + 1, "the restored roamer keeps its stored revision")
      Assert.equal(
        record.location,
        routeMapId(source.routeIndex),
        "the restored roamer location agrees with its source route"
      )
    end
    Assert.deepEqual(
      playerRoutes(game),
      { current = false, previous = false },
      "Continue restores the player's route history"
    )
    local worldState = assert(game.runtime.scripts, "the field owns its script platform").worldState
    Assert.deepEqual(
      worldState.rng:serialize(),
      loaded.world.rng,
      "loading a native roamer save is observation, never gameplay"
    )
    -- The source's own status words still read the journey's published values.
    Assert.equal(worldState:getVar(RAIKOU_STATUS_VAR), 0, "the restored journey keeps its Raikou status word")
    Assert.equal(worldState:getVar(ENTEI_STATUS_VAR), 0, "the restored journey keeps its Entei status word")

    -- Continue's own capture republishes the identical native state.
    local republished = assert(game.runtime:captureGameSave(), "the restored journey captures its save")
    Assert.equal(republished.encounters.schema, CURRENT_ENCOUNTER_SCHEMA, "the capture publishes the current bucket")
    for _, source in ipairs(SOURCE_SLOTS) do
      local record = assert(republished.encounters.roamers[source.key], "the capture keeps " .. source.key)
      Assert.deepEqual(record.native, { slot = source.slot, routeIndex = source.routeIndex })
      Assert.equal(record.mon.condition.currentHp, source.currentHp)
    end

    -- Save and Continue again: the persisted owner state is the source of
    -- truth, not a live launch artifact.
    game:save()
    game:restart()
    game:waitForFieldEntry()
    local resumed = capturedRoamers(game)
    for _, source in ipairs(SOURCE_SLOTS) do
      local record = assert(resumed[source.key], "Save and Continue keep " .. source.key)
      Assert.deepEqual(
        record.native,
        { slot = source.slot, routeIndex = source.routeIndex },
        "Save and Continue keep the source slot and route of " .. source.species
      )
      Assert.equal(
        record.mon.condition.currentHp,
        source.currentHp,
        "Save and Continue keep the battle health of " .. source.species
      )
      Assert.equal(record.lifecycle, "roaming", "Save and Continue keep " .. source.species .. " roaming")
    end
    Assert.deepEqual(playerRoutes(game), { current = false, previous = false }, "Save and Continue keep the history")
    Assert.equal(game:renderAttempts(), 0, "the roamer acceptance stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- ---------------------------------------------------------------------------
-- Movement: a real connection entry records the player's route history and
-- then moves each active roamer along the source graph with the source's draw
-- order, an ordinary gatehouse warp records history and moves nothing, and the
-- return connection never leaves an active roamer on the route just left.
-- Terminal slots never move.
-- ---------------------------------------------------------------------------

function T.tests.connection_entry_moves_active_roamers_while_ordinary_warps_do_not()
  local versionId = AcceptanceHarness.defaultVersion()
  local romFs, romSource = RomSourcePath.openReader(versionId)
  assert(romFs, tostring(romSource))
  local facts = NavigationFacts.discover(GeneratedCacheFixture.reader(versionId), romFs)
  romFs:close()
  romSource:release()

  -- Latias is terminal while Latios, the last source slot, still roams: the
  -- last slot must both move and stay terminal-aware in source order.
  local loaded = publishedNativeJourney({ ["native.latias"] = "caught" })
  local game = continueJourney(loaded)
  local ok, err = xpcall(function()
    OpeningLifecycle.seedNewBarkWestExitScene(game)
    OpeningLifecycle.settleNewBarkFriendScene(game)
    freezeAutonomousActors(game)

    -- A real connection enters Route 29. The source pushes the arrival into
    -- the player's history first, then moves every active roamer.
    local before = capturedRoamers(game)
    local predicted = simulateSourceUpdate(before, false, clonedWorldRng(game))
    local rngBefore = worldRngState(game)
    game:moveTo({ fieldX = facts.zoneBoundary.fieldX, fieldZ = facts.zoneBoundary.fieldZ }, facts.route29.mapId)
    Assert.equal(game:snapshot().mapId, facts.route29.mapId, "the connection lands on Route 29")
    game:waitForFieldReady()
    freezeAutonomousActors(game)
    Assert.deepEqual(
      playerRoutes(game),
      { current = facts.route29.mapId, previous = false },
      "a connection entry records the arrival and the route the player left"
    )
    local entered = capturedRoamers(game)
    for slot = 0, 3 do
      local key = SOURCE_SLOTS[slot + 1].key
      local record = assert(entered[key], "the roamer survives the connection: " .. key)
      if before[key].lifecycle == "roaming" then
        Assert.equal(
          routeIndexOf(record),
          predicted[slot],
          "the " .. SOURCE_SLOTS[slot + 1].species .. " follows the source route draw from the world stream"
        )
        Assert.equal(
          record.location,
          routeMapId(predicted[slot]),
          "the moved roamer's location agrees with its source route"
        )
      else
        Assert.equal(
          routeIndexOf(record),
          routeIndexOf(before[key]),
          "a terminal " .. SOURCE_SLOTS[slot + 1].species .. " never moves"
        )
      end
    end
    Assert.isTrue(worldRngState(game) ~= rngBefore, "the roamer transition advances the one world stream")

    -- An ordinary gatehouse warp is not a connection: it records the history
    -- and moves nothing. Route 29's north door evaluates while the player
    -- stands south of it and presses into the gatehouse.
    local gate = game:warpDestination(0)
    local settledRoutes = capturedRoamers(game)
    game:moveTo({ fieldX = gate.fieldX, fieldZ = gate.fieldZ + 1 })
    game:face("north")
    game:move("north")
    game:step()
    game:advanceUntil("the Route 29 gatehouse transition starts", function(snapshot)
      return snapshot.mapId == gate.mapId
    end, 480)
    game:waitForTransition()
    game:waitForFieldReady()
    Assert.equal(game:snapshot().mapSymbol, ROUTE_29_GATEHOUSE, "the door lands in the Route 29 gatehouse")
    local warped = capturedRoamers(game)
    for _, source in ipairs(SOURCE_SLOTS) do
      Assert.equal(
        routeIndexOf(warped[source.key]),
        routeIndexOf(settledRoutes[source.key]),
        "an ordinary warp never moves the " .. source.species
      )
      Assert.equal(warped[source.key].location, settledRoutes[source.key].location)
    end
    Assert.deepEqual(
      playerRoutes(game),
      { current = false, previous = facts.route29.mapId },
      "an ordinary warp records the player's arrival without moving roamers"
    )

    -- Leaving the gatehouse is another ordinary warp back onto Route 29.
    game:face("south")
    game:move("south")
    game:advanceUntil("the gatehouse exit starts", function(snapshot)
      return snapshot.mapId == facts.route29.mapId
    end, 480)
    game:waitForTransition()
    game:waitForFieldReady()
    freezeAutonomousActors(game)
    for _, source in ipairs(SOURCE_SLOTS) do
      Assert.equal(
        routeIndexOf(capturedRoamers(game)[source.key]),
        routeIndexOf(warped[source.key]),
        "the gatehouse exit never moves the " .. source.species
      )
    end
    Assert.deepEqual(
      playerRoutes(game),
      { current = facts.route29.mapId, previous = false },
      "the gatehouse exit records the arrival on the route"
    )
    -- The exit lands on the door tile itself; step off it before travelling.
    game:move("south")
    game:advanceUntil("the player steps off the door tile", function(snapshot)
      return snapshot.player.motion == "idle" and snapshot.mapId == facts.route29.mapId
    end, 240)

    -- The return connection excludes the route the player just left: the
    -- source's own history back is Route 29, so no active roamer may pick it.
    local leaving = capturedRoamers(game)
    local returnPredicted = simulateSourceUpdate(leaving, facts.route29.mapId, clonedWorldRng(game))
    game:moveTo({ fieldX = facts.newBark.fieldX, fieldZ = facts.newBark.fieldZ }, facts.newBark.mapId)
    Assert.equal(game:snapshot().mapId, facts.newBark.mapId, "the return connection lands in New Bark")
    local returned = capturedRoamers(game)
    for slot = 0, 3 do
      local key = SOURCE_SLOTS[slot + 1].key
      if leaving[key].lifecycle == "roaming" then
        Assert.equal(
          routeIndexOf(returned[key]),
          returnPredicted[slot],
          "the returning " .. SOURCE_SLOTS[slot + 1].species .. " follows the source route draw"
        )
        Assert.isTrue(
          returned[key].location ~= routeMapId(0),
          "the returning " .. SOURCE_SLOTS[slot + 1].species .. " never picks the route the player left"
        )
      end
    end
    Assert.deepEqual(
      playerRoutes(game),
      { current = false, previous = facts.route29.mapId },
      "the return connection records the arrival and the route the player left"
    )
    Assert.equal(game:renderAttempts(), 0, "the roamer acceptance stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end


-- ---------------------------------------------------------------------------
-- Fly: the party member knows Fly, the Storm badge is owned and one flypoint
-- is confirmed in the Pokegear Fly map. The field move is admitted through the
-- same field-action seam the party menu's handoff uses, the real selector
-- confirms the flypoint, and the fly warp randomizes every active roamer
-- inside its own region while recording the player's arrival and departure.
-- Terminal slots and battle health do not change.
-- ---------------------------------------------------------------------------

local FLY_KEY = "FLY"
local CHERRYGROVE = "MAP_CHERRYGROVE"
local CHERRYGROVE_FLYPOINT_FLAG = assert(FieldScriptSymbols.flagsByName.FLAG_SYS_FLYPOINT_CHERRYGROVE)
local STORM_BADGE = "storm"

---@param game table acceptance game owning the production field runtime
---@return table? the live companion application status
local function companionStatus(game)
  local host = assert(game.runtime.pokegearApplications, "the field composes the companion host")
  if not host:isActive() then
    return nil
  end
  return host:status()
end

---@param status table live companion status
---@return boolean whether a permitted flypoint is selected under the cursor
local function flypointSelected(status)
  for _, indicator in ipairs(status.view.indicators or {}) do
    if indicator.state == "selected" then
      return true
    end
  end
  return false
end

-- Presses the action button into the modal input lane without asking the
-- field interaction resolver for a target. The Fly selector gates keys while
-- its own cursor tween runs (fly_map.c gates on cursorMoving), so the driver
-- lets a pending cursor move settle before it sends the press.
---@param game table
local function pressModalAction(game)
  for _ = 1, 4 do
    game:step()
  end
  game.runtime:pressAction()
  game:step()
  game.runtime:releaseAction()
end

-- Steps until the companion application reports the caller's boundary.
---@param game table
---@param label string boundary description
---@param predicate fun(status: table?): boolean
---@param maxTicks integer
---@return table status
local function advanceCompanion(game, label, predicate, maxTicks)
  for _ = 0, maxTicks do
    local status = companionStatus(game)
    if predicate(status) then
      return status
    end
    if _ < maxTicks then
      game:step()
    end
  end
  error("the companion application did not reach " .. label, 0)
end

-- The Fly field move's own journey: a party member that knows Fly, the Storm
-- badge and one confirmed flypoint. The field-action admission the party menu
-- uses must hand the player's confirmed flypoint set to the field-move owner,
-- the selector must offer it, and the confirmation must fly the field there
-- through the source's fly warp.
function T.tests.fly_field_move_reaches_the_source_fly_warp()
  local versionId = AcceptanceHarness.defaultVersion()
  -- The production audio service without a device never reports the
  -- departure cry finished, so this journey renders it into the recording
  -- output boundary instead.
  local game = harness():boot({
    versionId = versionId,
    map = NEW_BARK,
    save = "fresh",
    fieldOptions = { audioOutput = FakeAudioOutput.new() },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    local mons = assert(game.runtime.monService, "the field owns its mon service")
    Assert.isTrue(
      mons:giveMon({ species = "PIDGEY", level = 20, form = 0, heldItem = "NONE" }),
      "the prepared Fly user enters through the production gift operation"
    )
    mons:setMove(0, 0, FLY_KEY)
    local profile = assert(game.runtime.playerData and game.runtime.playerData.profile, "the journey owns its profile")
    PlayerProgression.new(profile):awardBadge(STORM_BADGE)
    game:setWorldState({ flag = CHERRYGROVE_FLYPOINT_FLAG })
    game:waitForFieldReady()
    local startMapId = game:snapshot().mapId

    game.runtime:_admitFieldAction("pokemon.field_move", { move = "fly", slot = 0 })
    local open = advanceCompanion(game, "the Fly destination selection", function(status)
      return status ~= nil and status.view.indicators ~= nil and #status.view.indicators > 0
    end, 480)
    Assert.equal(open.mode, "fly", "the admitted field move opens the Fly selector")
    for _ = 1, 12 do
      local status = companionStatus(game)
      if status ~= nil and flypointSelected(status) then
        break
      end
      game:move("west")
    end
    local selected = assert(companionStatus(game), "the selector stays open while it is driven")
    Assert.isTrue(flypointSelected(selected), "the selector offers the player's confirmed flypoint")

    pressModalAction(game)
    advanceCompanion(game, "the Fly/Quit menu", function(status)
      return status ~= nil and status.view.menu ~= nil
    end, 240)
    pressModalAction(game)
    game:advanceUntil("the fly warp leaves the town", function(snapshot)
      return snapshot.mapId ~= startMapId
    end, 2400)
    game:waitForTransition()
    game:waitForFieldReady()
    Assert.equal(game:snapshot().mapSymbol, CHERRYGROVE, "the confirmed flypoint lands on its own map")
    Assert.equal(game:renderAttempts(), 0, "the roamer acceptance stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

function T.tests.fly_warp_randomizes_every_active_roamer()
  -- Latias is already caught, so the terminal slot proves that a fly warp
  -- leaves inactive slots alone while the last source slot, Latios, still
  -- randomizes.
  local loaded = publishedNativeJourney({ ["native.latias"] = "caught" })
  local game = continueJourney(loaded)
  local ok, err = xpcall(function()
    local mons = assert(game.runtime.monService, "the field owns its mon service")
    Assert.isTrue(
      mons:giveMon({ species = "PIDGEY", level = 20, form = 0, heldItem = "NONE" }),
      "the prepared Fly user enters through the production gift operation"
    )
    mons:setMove(0, 0, FLY_KEY)
    local profile = assert(game.runtime.playerData and game.runtime.playerData.profile, "the journey owns its profile")
    PlayerProgression.new(profile):awardBadge(STORM_BADGE)
    Assert.isTrue(PlayerProgression.new(profile):hasBadge(STORM_BADGE), "the Storm badge is owned")
    game:setWorldState({ flag = CHERRYGROVE_FLYPOINT_FLAG })
    game:waitForFieldReady()
    local startMapId = game:snapshot().mapId
    Assert.equal(game:snapshot().mapSymbol, NEW_BARK, "the Fly journey starts in New Bark")

    local before = capturedRoamers(game)
    -- The party menu hands its field action to the same admission command.
    game.runtime:_admitFieldAction("pokemon.field_move", { move = "fly", slot = 0 })
    local open = advanceCompanion(game, "the Fly destination selection", function(status)
      return status ~= nil and (status.view.indicators ~= nil) and #status.view.indicators > 0
    end, 480)
    Assert.equal(open.mode, "fly", "the admitted field move opens the Fly selector")

    -- The selector starts on the player's own cell; the confirmed flypoint lies
    -- west of it, so the driver reads the live indicator state instead of
    -- assuming a layout.
    for _ = 1, 12 do
      local status = companionStatus(game)
      if status ~= nil and flypointSelected(status) then
        break
      end
      game:move("west")
    end
    local selected = assert(companionStatus(game), "the selector stays open while it is driven")
    Assert.isTrue(flypointSelected(selected), "the cursor reaches the one confirmed flypoint")

    pressModalAction(game)
    local menu = advanceCompanion(game, "the Fly/Quit menu", function(status)
      return status ~= nil and status.view.menu ~= nil
    end, 240)
    Assert.notNil(menu.view.menu, "confirming a flypoint opens the source's Fly/Quit menu")

    local departure = capturedRoamers(game)
    local predicted = RoamerSourceFacts.simulateRandomize(departure, SLOT_KEYS, game:snapshot().mapId, clonedWorldRng(game))
    local rngBefore = worldRngState(game)
    pressModalAction(game)
    game:advanceUntil("the fly warp leaves the town", function(snapshot)
      return snapshot.mapId ~= startMapId
    end, 2400)
    game:waitForTransition()
    game:waitForFieldReady()
    Assert.equal(game:snapshot().mapSymbol, CHERRYGROVE, "the confirmed flypoint lands on its own map")

    local arrived = capturedRoamers(game)
    for slot = 0, 3 do
      local source = SOURCE_SLOTS[slot + 1]
      local record = assert(arrived[source.key], "the fly warp keeps " .. source.key)
      Assert.equal(record.mon.condition.currentHp, source.currentHp, "the fly warp keeps " .. source.species .. " battle health")
      if departure[source.key].lifecycle == "roaming" then
        Assert.equal(
          routeIndexOf(record),
          predicted[slot],
          "the fly warp randomizes the " .. source.species .. " from the one world stream"
        )
        Assert.equal(
          record.location,
          routeMapId(predicted[slot]),
          "the randomized " .. source.species .. " location agrees with its source route"
        )
        Assert.isTrue(
          routeIndexOf(record) ~= routeIndexOf(departure[source.key]),
          "the fly warp randomizes the " .. source.species .. " onto a new route"
        )
      else
        Assert.equal(
          routeIndexOf(record),
          routeIndexOf(departure[source.key]),
          "a terminal " .. source.species .. " never moves on a fly warp"
        )
      end
    end
    Assert.isTrue(worldRngState(game) ~= rngBefore, "the fly warp draws from the one world stream")
    Assert.deepEqual(
      playerRoutes(game),
      { current = MapCatalog.idForSymbol(CHERRYGROVE), previous = startMapId },
      "the fly warp records the arrival and the town the player left"
    )
    Assert.equal(game:renderAttempts(), 0, "the roamer acceptance stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
