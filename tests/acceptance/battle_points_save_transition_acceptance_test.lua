-- Battle Point persistence through the production save path. A journey's own
-- published save is rewritten as the previous envelope with the Battle Point
-- bucket absent and the previous statistics format; the production store then
-- loads it and the runtime continues. The envelope gains exactly the empty
-- Battle Point owner, keeps every owner the earlier release already wrote, and
-- records its own statistics format. A current save that names an
-- out-of-range balance is refused instead of being clamped.
--
-- Only audio, fade and clock host boundaries are recorded; the save store, the
-- runtime and every owning domain stay production-owned, and the render trap
-- stays active.

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
    tags = { "field", "save", "battle-points" },
  },
  tests = {},
}

local MAP = "MAP_BURNED_TOWER_1F"
local PREVIOUS_GAME_SCHEMA = "g4-game-save-v17"
local PREVIOUS_STATS_SCHEMA = "hgss-stats-v4"
local PREVIOUS_STATS_STATE_VERSION = 4
local BATTLE_POINTS_SCHEMA = "hgss-battle-points-v1"
local HOF_BUCKET_SCHEMA = "hgss-hall-of-fame-v1"

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

---@return AcceptanceHarness
local function harness()
  local acceptance = AcceptanceHarness.new()
  local createGame = acceptance.gameFactory
  acceptance.gameFactory = function(versionId, map)
    local game = createGame(versionId, map)
    game.location = { mapSymbol = MAP, fieldX = 10, fieldZ = 10, facing = "south" }
    game.hallOfFame = hallOfFameBucket()
    game.playerData.profile.money = 3000
    return game
  end
  return acceptance
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
---@param label string
---@return table the settled captured game save
local function settledCapture(game, label)
  local lastError = nil
  for _ = 1, 480 do
    local ok, record, reason = pcall(game.runtime.captureGameSave, game.runtime)
    if ok and record ~= nil then
      return record
    end
    lastError = ok and tostring(reason or "capture returned no record") or tostring(record)
    game:step()
  end
  error("the settled field never accepted its save: " .. label .. "; last failure: " .. tostring(lastError), 0)
end

-- Rewrites one captured save as the previous envelope: the release before the
-- Battle Point owner never wrote that bucket, and its statistics format
-- carried no point counters.
---@param captured table the journey's own capture
---@return table
local function previousEnvelope(captured)
  local legacy = deepCopy(captured)
  legacy.schema = PREVIOUS_GAME_SCHEMA
  legacy.battlePoints = nil
  legacy.gameStats.schema = PREVIOUS_STATS_SCHEMA
  legacy.gameStats.stateVersion = PREVIOUS_STATS_STATE_VERSION
  legacy.gameStats.battlePointsReceived = nil
  legacy.gameStats.battlePointsSpent = nil
  return legacy
end

---@param game table acceptance game owning the production store
---@param record table the earlier envelope
local function writePayload(game, record)
  assert(love.filesystem.createDirectory(payloadDirectory(game)), "the acceptance save root holds its payload")
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

---@param record table
---@return string[] the record's top-level owners, sorted
local function ownerNames(record)
  local names = {}
  for key in pairs(record) do
    names[#names + 1] = key
  end
  table.sort(names)
  return names
end

---@param record table
---@return table<string, boolean>
local function ownerSet(record)
  local set = {}
  for _, name in ipairs(ownerNames(record)) do
    set[name] = true
  end
  return set
end

-- A save written before the Battle Point wallet existed gains exactly the
-- empty wallet, keeps everything the earlier release already owned and
-- continues.
function T.tests.the_previous_envelope_gains_an_empty_wallet_and_keeps_its_owners()
  local versionId = AcceptanceHarness.defaultVersion()
  local first = harness():boot({
    versionId = versionId,
    map = MAP,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true, audioHost = "recording" },
  })
  local captured, migrated = nil, nil
  local ok, err = xpcall(function()
    first:waitForFieldEntry()
    Assert.isTrue(
      first.runtime.monService:giveMon({ species = "RATTATA", level = 5 }),
      "the save scenario needs one party mon"
    )
    captured = settledCapture(first, "the fresh journey")
    local wallet = assert(captured.battlePoints, "the current save carries the Battle Point owner")
    Assert.equal(wallet.schema, BATTLE_POINTS_SCHEMA, "the wallet carries its own schema identity")
    Assert.equal(wallet.balance, 0, "a new journey starts with an empty wallet")
    Assert.equal(captured.gameStats.battlePointsReceived, 0, "a new journey received no point")
    Assert.equal(captured.gameStats.battlePointsSpent, 0, "a new journey spent no point")
    Assert.isNil(captured.frontier, "the save carries no Battle Frontier challenge record")

    local store = assert(first.runtime.saveStore, "the field runtime owns its save store")
    Assert.isTrue(store:publishFirst(captured), "the journey publishes its own save")

    local legacy = previousEnvelope(captured)
    Assert.isNil(legacy.battlePoints, "the previous envelope never wrote a Battle Point bucket")
    writePayload(first, legacy)
    migrated = load(first, captured.saveId)

    Assert.equal(migrated.schema, captured.schema, "the migrated envelope carries the current schema")
    local migratedWallet = assert(migrated.battlePoints, "the previous envelope migrates to the empty wallet")
    Assert.equal(migratedWallet.schema, BATTLE_POINTS_SCHEMA, "the migrated wallet carries the current schema")
    Assert.equal(migratedWallet.balance, 0, "the migration invents no balance")
    Assert.equal(migrated.gameStats.battlePointsReceived, 0, "the migration invents no received count")
    Assert.equal(migrated.gameStats.battlePointsSpent, 0, "the migration invents no spent count")

    local added = {}
    local current = ownerSet(migrated)
    local previous = ownerSet(legacy)
    for _, name in ipairs(ownerNames(migrated)) do
      if not previous[name] then
        added[#added + 1] = name
      end
    end
    Assert.deepEqual(added, { "battlePoints" }, "the migration adds exactly the Battle Point owner")
    Assert.isTrue(current.hallOfFame and current.daycare, "the migrated envelope keeps its existing owners")

    Assert.deepEqual(migrated.hallOfFame, captured.hallOfFame, "the migration keeps the recorded Hall of Fame")
    Assert.deepEqual(
      migrated.mons.party.mons,
      captured.mons.party.mons,
      "the migration keeps the canonical party"
    )
    Assert.equal(migrated.playerData.profile.money, 3000, "the migration keeps the saved money")
    Assert.deepEqual(migrated.encounters, captured.encounters, "the migration keeps the encounter and roamer state")
    Assert.equal(migrated.gameStats.score, captured.gameStats.score, "the migration keeps the trainer-card score")
    Assert.deepEqual(
      migrated.gameStats.uniqueCaught,
      captured.gameStats.uniqueCaught,
      "the migration keeps the registered species"
    )
    Assert.equal(migrated.gameStats.daycareDeposits, 0, "the migration keeps the Day Care statistics")
  end, debug.traceback)
  first:close()
  if not ok then
    error(err, 0)
  end

  -- Continue through the production store: the migrated save boots, restores
  -- the same empty wallet and republishes it unchanged.
  local resumed = bootFrom(migrated)
  local resumedOk, resumedErr = xpcall(function()
    resumed:waitForFieldEntry()
    local republished = settledCapture(resumed, "the continued journey")
    Assert.deepEqual(
      republished.battlePoints,
      migrated.battlePoints,
      "Continue keeps the empty wallet unchanged"
    )
    Assert.deepEqual(republished.hallOfFame, captured.hallOfFame, "Continue keeps the recorded Hall of Fame")
    Assert.deepEqual(
      republished.mons.party.mons,
      captured.mons.party.mons,
      "Continue keeps the canonical party"
    )
    Assert.equal(republished.gameStats.battlePointsSpent, 0, "Continue keeps the spent count")
    Assert.equal(resumed:renderAttempts(), 0, "the save transition stops before GPU rendering")
  end, debug.traceback)
  resumed:close()
  if not resumedOk then
    error(resumedErr, 0)
  end

  -- A current save whose wallet names a balance outside the source range is
  -- refused rather than clamped into a plausible balance.
  local corrupt = deepCopy(migrated)
  corrupt.battlePoints = { schema = BATTLE_POINTS_SCHEMA, balance = 10000 }
  local rejected = AcceptanceHarness.new({
    gameFactory = function()
      return corrupt
    end,
  })
  local bootOk, bootErr = pcall(function()
    rejected:boot({
      versionId = versionId,
      map = MAP,
      save = "continue",
      seedSave = corrupt,
      fieldOptions = { recordingScriptHosts = true, audioHost = "recording" },
    })
  end)
  Assert.isFalse(bootOk, "a wallet balance outside the source range is refused: " .. tostring(bootErr))
end

return T
