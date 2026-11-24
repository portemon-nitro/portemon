-- Day Care persistence through the production save path. A journey's own
-- published save is rewritten as the previous envelope (and as the envelope
-- before it) with the Day Care bucket absent; the production store then loads
-- it and the runtime continues: the Hall of Fame history, the encounter/roamer
-- state and the statistics survive unchanged, the Day Care starts genuinely
-- empty with no invented egg or gift identity, and the next capture publishes
-- the current Day Care format. A current save that names an invalid stored
-- parent is refused instead of being normalized. Only the audio, fade and
-- clock host boundaries are recorded; the save store, the runtime and every
-- owning domain stay production-owned, and the render trap stays active.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local LuaWriter = require("libs.codec.src.LuaWriter")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = {
      "field-runtime",
      "map:7",
      "map-data:7",
    },
    tags = { "field", "save", "daycare" },
  },
  tests = {},
}

local MAP = "MAP_BURNED_TOWER_1F"
local PREVIOUS_GAME_SCHEMA = "g4-game-save-v16"
local EARLIER_GAME_SCHEMA = "g4-game-save-v15"
local PREVIOUS_STATS_SCHEMA = "hgss-stats-v3"
local PREVIOUS_STATS_STATE_VERSION = 3
local HOF_BUCKET_SCHEMA = "hgss-hall-of-fame-v1"
local DAYCARE_BUCKET_SCHEMA = "hgss-daycare-v1"

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

-- The one recorded clear the previous envelope already carried.
---@return table
local function hallOfFameBucket()
  return {
    schema = HOF_BUCKET_SCHEMA,
    stateVersion = 1,
    total = 1,
    records = {
      {
        date = { year = 2000, month = 1, day = 1 },
        party = {
          {
            species = "TYPHLOSION",
            level = 60,
            form = 0,
            personality = 1,
            otId = 1,
            otName = "GOLD",
            nickname = "TYPHLOSION",
            moves = { "FLAMETHROWER", "EMBER", "TACKLE", "GROWL" },
          },
        },
      },
    },
  }
end

---@param records table? the record a boot candidate already carries
---@return AcceptanceHarness
local function harness(records)
  local harness = AcceptanceHarness.new()
  local createGame = harness.gameFactory
  harness.gameFactory = function(versionId, map)
    if records ~= nil then
      return records
    end
    local game = createGame(versionId, map)
    game.location = { mapSymbol = MAP, fieldX = 10, fieldZ = 10, facing = "south" }
    game.hallOfFame = hallOfFameBucket()
    return game
  end
  return harness
end

---@param game table acceptance game owning the production store
---@return string the save payload directory inside the acceptance save root
local function payloadDirectory(game)
  return game.saveNamespace .. "/global/games"
end

---@param game table acceptance game owning the production store
---@param saveId string
---@return string the save payload path inside the acceptance save root
local function payloadPath(game, saveId)
  return payloadDirectory(game) .. "/" .. saveId .. ".lua"
end

---@param game table
---@return table the settled captured game save
local function settledCapture(game)
  local lastError = nil
  for _ = 1, 480 do
    local ok, record = pcall(game.runtime.captureGameSave, game.runtime)
    if ok and record ~= nil then
      return record
    end
    lastError = ok and "capture returned no record" or tostring(record)
    game:step()
  end
  error("the settled field never accepted its save; last failure: " .. tostring(lastError), 0)
end

---@param capture table the captured game save
---@return table the Day Care bucket
local function daycareBucket(capture)
  local bucket = assert(capture.daycare, "the current save carries the Day Care bucket")
  Assert.equal(bucket.schema, DAYCARE_BUCKET_SCHEMA, "the saved Day Care carries its own schema identity")
  return bucket
end

-- Rewrites one captured save as an earlier envelope: the Day Care bucket is
-- absent because that release never wrote it, and the nested statistics
-- bucket belongs to the same release.
---@param captured table the journey's own capture
---@param schema string the earlier envelope schema
---@return table
local function earlierEnvelope(captured, schema)
  local legacy = deepCopy(captured)
  legacy.schema = schema
  legacy.daycare = nil
  if schema == PREVIOUS_GAME_SCHEMA then
    legacy.gameStats.schema = PREVIOUS_STATS_SCHEMA
    legacy.gameStats.stateVersion = PREVIOUS_STATS_STATE_VERSION
    legacy.gameStats.daycareDeposits = nil
    legacy.gameStats.eggsHatched = nil
  else
    legacy.hallOfFame = nil
  end
  return legacy
end

-- Rewrites the published payload on disk so the loader reads the earlier
-- envelope, exactly as a save written by the previous release would be.
---@param game table acceptance game owning the production store
---@param record table the earlier envelope
local function writePayload(game, record)
  assert(love.filesystem.createDirectory(payloadDirectory(game)), "the acceptance save root holds its payload directory")
  assert(
    love.filesystem.write(payloadPath(game, record.saveId), LuaWriter.encode(record)),
    "the earlier payload is written"
  )
end

---@param game table acceptance game owning the production store
---@param saveId string the catalog-visible save identity
---@return table the record the production store loads back
local function load(game, saveId)
  local store = assert(game.runtime.saveStore, "the field runtime owns its save store")
  return assert(store:load(saveId), "the published save loads through the production store")
end

---@param record table the record to continue from
---@return table game
local function bootFrom(record)
  return AcceptanceHarness.new({
    gameFactory = function()
      return record
    end,
  }):boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = MAP,
    save = "continue",
    seedSave = record,
    fieldOptions = { recordingScriptHosts = true, audioHost = "recording" },
  })
end

-- A save written before the Day Care existed gains exactly the empty Day Care
-- state, keeps everything the earlier release already owned, and continues.
function T.tests.previous_envelopes_gain_an_empty_day_care_without_inventing_a_gift()
  local versionId = AcceptanceHarness.defaultVersion()
  local first = harness(nil):boot({
    versionId = versionId,
    map = MAP,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true, audioHost = "recording" },
  })
  local captured, migratedFromPrevious, migratedFromEarlier = nil, nil, nil
  local ok, err = xpcall(function()
    first:waitForFieldEntry()
    captured = settledCapture(first)
    Assert.equal(captured.hallOfFame.total, 1, "the journey starts with its recorded clear")
    local store = assert(first.runtime.saveStore, "the field runtime owns its save store")
    Assert.isTrue(store:publishFirst(captured), "the journey publishes its own save")

    for _, entry in ipairs({
      { schema = PREVIOUS_GAME_SCHEMA, label = "the previous envelope" },
      { schema = EARLIER_GAME_SCHEMA, label = "the envelope before it" },
    }) do
      local legacy = earlierEnvelope(captured, entry.schema)
      Assert.isNil(legacy.daycare, entry.label .. " never wrote a Day Care bucket")
      writePayload(first, legacy)
      local loaded = load(first, captured.saveId)
      if entry.schema == PREVIOUS_GAME_SCHEMA then
        migratedFromPrevious = loaded
      else
        migratedFromEarlier = loaded
      end

      local bucket = daycareBucket(loaded)
      Assert.equal(#bucket.slots, 0, entry.label .. " migrates to an empty Day Care")
      Assert.equal(bucket.pendingEggPid, 0, entry.label .. " invents no pending egg")
      Assert.equal(bucket.eggCycleCounter, 0, entry.label .. " invents no egg cycle progress")
      Assert.deepEqual(loaded.encounters, captured.encounters, entry.label .. " keeps the encounter and roamer state")
      Assert.equal(loaded.gameStats.daycareDeposits, 0, entry.label .. " invents no deposit count")
      Assert.equal(loaded.gameStats.eggsHatched, 0, entry.label .. " invents no hatch count")
      Assert.equal(loaded.gameStats.score, captured.gameStats.score, entry.label .. " keeps the trainer-card score")
      Assert.deepEqual(
        loaded.gameStats.uniqueCaught,
        captured.gameStats.uniqueCaught,
        entry.label .. " keeps the registered species"
      )
    end

    Assert.deepEqual(
      migratedFromPrevious.hallOfFame,
      captured.hallOfFame,
      "the previous envelope keeps its recorded Hall of Fame history"
    )
    Assert.equal(
      migratedFromEarlier.hallOfFame.total,
      0,
      "the envelope before the Hall of Fame migrates without inventing a clear"
    )
  end, debug.traceback)
  first:close()
  if not ok then
    error(err, 0)
  end

  -- Continue through the production store: the migrated save boots, restores
  -- the same empty Day Care, and republishes it unchanged.
  local resumed = bootFrom(migratedFromPrevious)
  local resumedOk, resumedErr = xpcall(function()
    resumed:waitForFieldEntry()
    local republished = settledCapture(resumed)
    Assert.deepEqual(
      daycareBucket(republished),
      daycareBucket(migratedFromPrevious),
      "Continue keeps the empty Day Care state unchanged"
    )
    Assert.deepEqual(
      republished.hallOfFame,
      captured.hallOfFame,
      "Continue keeps the recorded Hall of Fame history unchanged"
    )
    Assert.deepEqual(
      republished.encounters,
      captured.encounters,
      "Continue keeps the encounter and roamer state unchanged"
    )
    Assert.equal(resumed:renderAttempts(), 0, "the save transition stops before GPU rendering")
  end, debug.traceback)
  resumed:close()
  if not resumedOk then
    error(resumedErr, 0)
  end

  -- A current save that names an invalid stored parent is refused rather than
  -- normalized into a plausible parent.
  local corrupt = deepCopy(migratedFromPrevious)
  corrupt.daycare = {
    schema = DAYCARE_BUCKET_SCHEMA,
    slots = {
      { mon = { schema = "g4-mon-v2", species = "TYPHLOSION" }, steps = -1 },
    },
    pendingEggPid = 0,
    eggCycleCounter = 0,
  }
  local rejected = harness(corrupt)
  local bootOk, bootErr = pcall(function()
    rejected:boot({
      versionId = versionId,
      map = MAP,
      save = "continue",
      seedSave = corrupt,
      fieldOptions = { recordingScriptHosts = true, audioHost = "recording" },
    })
  end)
  Assert.isFalse(bootOk, "a current Day Care bucket with an invalid stored parent is refused: " .. tostring(bootErr))
end

return T
