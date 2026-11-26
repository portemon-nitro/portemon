-- Legacy encounter persistence through the real save path. A journey's
-- published save is rewritten as the previous shipped envelope carrying only
-- the earlier encounter bucket with one player-authored roamer record, and the
-- production store then loads it: the loaded world keeps that roamer exactly as
-- it was stored - no native slot, route, or location is invented - draws no
-- random value, and the next capture publishes the current encounter format.
-- Only the audio, fade and clock host boundaries are recorded; the save store,
-- the runtime and every owning domain stay production-owned, and the render
-- trap stays active throughout.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldMapDataCache = require("libs.assets.src.field.FieldMapDataCache")
local LuaWriter = require("libs.codec.src.LuaWriter")
local MapCatalog = require("romdump.src.digest.map.MapCatalog")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = {
      "field-runtime",
      "map:88",
      "map-data:88",
      "message-bank:626",
      "map:45",
      "map-data:45",
      "field-cell:0-14",
      "field-cell:0-15",
      "field-cell:0-16",
      "field-cell:0-17",
      "field-cell:0-18",
      "field-cell:0-61",
      "field-cell:0-62",
      "field-cell:0-63",
      "field-cell:0-64",
      "field-cell:0-65",
      "field-cell:0-108",
      "field-cell:0-109",
      "field-cell:0-110",
      "field-cell:0-111",
      "field-cell:0-112",
      "field-cell:0-155",
      "field-cell:0-156",
      "field-cell:0-157",
      "field-cell:0-158",
      "field-cell:0-159",
      "field-cell:0-202",
      "field-cell:0-203",
      "field-cell:0-204",
      "field-cell:0-205",
      "field-cell:0-206",
    },
    tags = { "field", "save", "encounter" },
  },
  tests = {},
}

-- The shipped envelope and encounter bucket this migration starts from.
local LEGACY_GAME_SCHEMA = "g4-game-save-v14"
local LEGACY_ENCOUNTER_SCHEMA = "hgss-encounter-v1"
local LEGACY_GAME_STATS_SCHEMA = "hgss-stats-v3"
local LEGACY_GAME_STATS_STATE_VERSION = 3

local LAKE_OF_RAGE = "MAP_LAKE_OF_RAGE"
local LAKE_OF_RAGE_ORIGIN = { x = 512, z = 32 }
local SHORE_TILE = { fieldX = 525, fieldZ = 72, facing = "north" }

-- The player-authored roamer the legacy bucket carries: an ordinary record with
-- the player's own key and no native encounter metadata at all.
local LEGACY_ROAMER_KEY = "wanderer"
local LEGACY_ROAMER_SPECIES = "RATTATA"
local LEGACY_ROAMER_HP = 17
local LEGACY_ROAMER_REVISION = 3

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

---@param versionId string
---@param mapSymbol string
---@param spawn table
---@return AcceptanceHarness
local function journey(versionId, mapSymbol, spawn)
  local baseFactory = AcceptanceHarness.new().gameFactory
  return AcceptanceHarness.new({
    gameFactory = function(requestedVersion, map)
      local game = baseFactory(requestedVersion, map)
      game.location = {
        mapSymbol = mapSymbol,
        fieldX = spawn.fieldX - LAKE_OF_RAGE_ORIGIN.x,
        fieldZ = spawn.fieldZ - LAKE_OF_RAGE_ORIGIN.z,
        facing = spawn.facing,
      }
      return game
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

-- The bucket the earlier shipped runtime published for one player-authored
-- roamer, in the shape that earlier schema declared.
---@param steps integer
---@return table<string, unknown>
local function legacyEncounterBucket(steps)
  return {
    schema = LEGACY_ENCOUNTER_SCHEMA,
    stateVersion = 1,
    steps = steps,
    repelSteps = 0,
    swarm = false,
    roamers = {
      [LEGACY_ROAMER_KEY] = {
        key = LEGACY_ROAMER_KEY,
        stateVersion = 1,
        mon = {
          species = LEGACY_ROAMER_SPECIES,
          personality = 123456789,
          condition = { currentHp = LEGACY_ROAMER_HP, effects = {} },
        },
        location = MapCatalog.idForSymbol(LAKE_OF_RAGE),
        lifecycle = "roaming",
        revision = LEGACY_ROAMER_REVISION,
      },
    },
  }
end

function T.tests.legacy_custom_roamer_survives_migration_without_invented_native_data()
  local versionId = AcceptanceHarness.defaultVersion()
  local first = journey(versionId, LAKE_OF_RAGE, SHORE_TILE):boot({
    versionId = versionId,
    map = LAKE_OF_RAGE,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true },
  })
  local published, loaded
  local ok, err = xpcall(function()
    first:waitForFieldEntry()
    local store = assert(first.runtime.saveStore, "the field runtime owns its save store")
    local captured = assert(first.runtime:captureGameSave(), "the journey captures its own save")
    local saveId = assert(captured.saveId, "a captured save names its identity")
    Assert.isTrue(store:publishFirst(captured), "the journey publishes its first save")

    -- Rewrite the published payload as the earlier shipping envelope: every
    -- bucket is the one the journey really captured, only the envelope schema
    -- and the encounter bucket belong to the earlier release.
    local legacy = deepCopy(captured)
    legacy.schema = LEGACY_GAME_SCHEMA
    legacy.encounters = legacyEncounterBucket(captured.encounters.steps)
    -- The envelope predates the Hall of Fame history, the Day Care, and the
    -- Battle Point wallet, and its statistics keep the release's own shape.
    legacy.hallOfFame = nil
    legacy.daycare = nil
    legacy.battlePoints = nil
    legacy.playerData.profile.coins = nil
    legacy.gameStats.schema = LEGACY_GAME_STATS_SCHEMA
    legacy.gameStats.stateVersion = LEGACY_GAME_STATS_STATE_VERSION
    legacy.gameStats.leagueWins = nil
    legacy.gameStats.daycareDeposits = nil
    legacy.gameStats.eggsHatched = nil
    legacy.gameStats.battlePointsReceived = nil
    legacy.gameStats.battlePointsSpent = nil
    assert(
      love.filesystem.createDirectory(payloadDirectory(first)),
      "the acceptance save root holds its payload directory"
    )
    assert(love.filesystem.write(payloadPath(first, saveId), LuaWriter.encode(legacy)), "the legacy payload is written")

    -- Continue through the production store: the load path owns the migration.
    loaded = assert(store:load(saveId), "the production store loads the legacy save")
  end, debug.traceback)
  first:close()
  if not ok then
    error(err, 0)
  end

  local resumed = AcceptanceHarness.new({
    gameFactory = function()
      return loaded
    end,
  }):boot({
    versionId = versionId,
    map = LAKE_OF_RAGE,
    save = "continue",
    fieldOptions = { recordingScriptHosts = true },
  })
  local resumedOk, resumedErr = xpcall(function()
    resumed:waitForFieldEntry()
    local roamers = assert(resumed.runtime.roamerState, "the field runtime owns its roamer state")
    local captured = assert(roamers:capture(), "the roamer owner captures its own state")
    local keys = {}
    for key in pairs(captured.roamers) do
      keys[#keys + 1] = tostring(key)
    end
    local record = assert(captured.roamers[LEGACY_ROAMER_KEY], "the legacy custom roamer is preserved")
    Assert.equal(record.mon.species, LEGACY_ROAMER_SPECIES, "the legacy roamer keeps its stored species")
    Assert.equal(record.mon.condition.currentHp, LEGACY_ROAMER_HP, "the legacy roamer keeps its stored health")
    Assert.equal(record.location, MapCatalog.idForSymbol(LAKE_OF_RAGE), "the legacy roamer keeps its stored location")
    Assert.equal(record.lifecycle, "roaming", "the legacy roamer keeps its stored lifecycle")
    Assert.equal(record.revision, LEGACY_ROAMER_REVISION, "the legacy roamer keeps its stored revision")
    Assert.isNil(record.native, "migration never invents a native slot or route for a custom roamer")
    for _, reserved in ipairs({ "native.raikou", "native.entei", "native.latias", "native.latios" }) do
      Assert.isNil(captured.roamers[reserved], "migration never invents the native roamer " .. reserved)
    end
    -- Loading a legacy save is observation, never gameplay: the world stream is
    -- exactly where the stored bucket left it.
    Assert.deepEqual(
      resumed.runtime.scripts.worldState.rng:serialize(),
      loaded.world.rng,
      "the migrated world draws no random value"
    )

    -- The next capture publishes the current encounter format with the same
    -- custom record and no guessed native metadata.
    local republished = assert(resumed.runtime:captureGameSave(), "the migrated journey captures its save")
    Assert.isTrue(
      republished.encounters.stateVersion > 1,
      "the republished encounter bucket carries the current state version (published "
        .. tostring(republished.encounters.stateVersion)
        .. ")"
    )
    Assert.equal(
      republished.encounters.roamers[LEGACY_ROAMER_KEY].mon.species,
      LEGACY_ROAMER_SPECIES,
      "the republished bucket still carries the legacy custom roamer"
    )
    Assert.isNil(
      republished.encounters.roamers[LEGACY_ROAMER_KEY].native,
      "the republished bucket still carries no invented native metadata"
    )
    Assert.equal(resumed:renderAttempts(), 0, "the migration acceptance stops before GPU rendering")
  end, debug.traceback)
  resumed:close()
  if not resumedOk then
    error(resumedErr, 0)
  end
end

return T
