-- Tests the pure persistence-envelope boundary for game saves: supported
-- records normalize and migrate without generated caches, while routing
-- identity and entry coordinates stay strict. Nested buckets are owned by
-- their runtime domains, so envelope normalization never traverses them.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local GameSave = require("libs.hgss.src.save.GameSave")
local BagSave = require("libs.hgss.src.save.BagSave")
local FashionCaseState = require("libs.hgss.src.save.FashionCaseState")
local MartSave = require("libs.hgss.src.save.MartSave")
local Mailbox = require("libs.hgss.src.save.Mailbox")
local PhotoAlbum = require("libs.hgss.src.save.PhotoAlbum")

local T = {}

local function record(overrides)
  local value = {
    schema = GameSave.SCHEMA,
    saveId = "save-00000001",
    versionId = "heartgold",
    playTimeSeconds = 61,
    mapId = 60,
    fieldX = 684,
    fieldZ = 393,
    worldY = 0,
    surfaceId = 0,
    terrainDependencyHash = "terrain-heartgold",
    facing = "south",
    playerData = {
      profile = { name = "GOLD", gender = 0, trainerId = 0, money = 3000, badges = 0, nationalDex = false },
      options = { textFrame = 0, textSpeed = "mid" },
    },
    fieldTravel = { lastHealSpawn = "SPAWN_NEW_BARK" },
    fashionCase = FashionCaseState.empty(),
    world = { flags = {}, variables = {}, objects = {}, rng = { state = 1, calls = 0 } },
    scripts = {},
    auxiliaryUi = { requested = "shown", state = "shown" },
    audio = {},
    mons = {},
    bag = BagSave.empty(),
    mart = MartSave.empty(),
    mailbox = Mailbox.new():capture(),
    photoAlbum = PhotoAlbum.new():capture(),
  }
  for key, replacement in pairs(overrides or {}) do
    rawset(value, key, replacement)
  end
  return value
end

local function v3record(overrides)
  local value = record(overrides)
  value.schema = "g4-game-save-v3"
  value.playerData = {
    profile = { name = "GOLD", gender = 0, trainerId = 0, money = 3000 },
    options = { textFrame = 0, textSpeed = "mid" },
  }
  value.mons = {
    schema = "g4-mons-save-v1",
    catalogFingerprint = "legacy-catalog",
    rng = { state = 7, calls = 0 },
    party = { max = 6, mons = {} },
  }
  value.fieldTravel = nil
  value.fashionCase = nil
  value.mart = nil
  value.mailbox = nil
  value.photoAlbum = nil
  return value
end

local function returnsCode(code, fn)
  local normalized, err = fn()
  Assert.isNil(normalized)
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, code)
end

function T.current_envelope_normalizes_without_reading_nested_buckets()
  local input = record({ mons = { fingerprint = "drifted" }, world = {}, bag = { nonsense = true } })
  local normalized = assert(GameSave.normalize(input))
  Assert.equal(normalized.saveId, "save-00000001")
  Assert.equal(normalized.versionId, "heartgold")
  Assert.equal(normalized.schema, GameSave.SCHEMA)
  Assert.equal(normalized.mapId, 60)
  -- Nested state passes through untouched: the owning domains read it later.
  Assert.equal(normalized.mons.fingerprint, "drifted")
  Assert.deepEqual(normalized.world, {})
end

function T.routing_identity_and_entry_coordinates_stay_strict()
  Assert.notNil(GameSave.normalize(record()))
  returnsCode("GAME_SAVE_SCHEMA_UNSUPPORTED", function()
    return GameSave.normalize(record({ schema = "g4-game-save-v8" }))
  end)
  returnsCode("GAME_SAVE_SCHEMA_UNSUPPORTED", function()
    return GameSave.normalize(record({ schema = "g4-field-save-v3" }))
  end)
  returnsCode("GAME_SAVE_SAVE_ID_INVALID", function()
    return GameSave.normalize(record({ saveId = "../escape" }))
  end)
  returnsCode("GAME_SAVE_VERSION_INVALID", function()
    return GameSave.normalize(record({ versionId = "" }))
  end)
  returnsCode("GAME_SAVE_PLAY_TIME_INVALID", function()
    return GameSave.normalize(record({ playTimeSeconds = -1 }))
  end)
  returnsCode("GAME_SAVE_PLAY_TIME_INVALID", function()
    return GameSave.normalize(record({ playTimeSeconds = GameSave.MAX_PLAY_TIME_SECONDS + 1 }))
  end)
  returnsCode("GAME_SAVE_FIELD_INVALID", function()
    return GameSave.normalize(record({ facing = "up" }))
  end)
  returnsCode("GAME_SAVE_FIELD_INVALID", function()
    return GameSave.normalize(record({ mapId = -1 }))
  end)
  returnsCode("GAME_SAVE_FIELD_INVALID", function()
    local value = record()
    value.fieldX = nil
    return GameSave.normalize(value)
  end)
  returnsCode("GAME_SAVE_FIELD_INVALID", function()
    return GameSave.normalize(record({ terrainDependencyHash = "" }))
  end)
  returnsCode("GAME_SAVE_INVALID", function()
    ---@diagnostic disable-next-line: param-type-mismatch -- the test deliberately exercises invalid input
    return GameSave.normalize(nil)
  end)
end

function T.missing_avatar_canonicalizes_to_walking_without_generated_reads()
  local value = record()
  value.avatar = nil
  local normalized = assert(GameSave.normalize(value))
  Assert.deepEqual(normalized.avatar, { state = "walking" })
  Assert.isNil(value.avatar, "normalization must not mutate its input")
end

function T.supported_history_migrates_to_current_without_generated_caches()
  local migrated = assert(GameSave.normalize(v3record()))
  Assert.equal(migrated.schema, GameSave.SCHEMA)
  Assert.equal(migrated.saveId, "save-00000001")
  Assert.equal(migrated.playerData.profile.badges, 0)
  Assert.equal(migrated.playerData.profile.nationalDex, false)
  Assert.deepEqual(migrated.fieldTravel, { lastHealSpawn = "SPAWN_NEW_BARK" })
  Assert.deepEqual(migrated.mart, MartSave.empty())
  Assert.deepEqual(migrated.fashionCase, FashionCaseState.empty())
  Assert.equal(migrated.mons.schema, "g4-mons-save-v2")
end

function T.historical_migration_never_repairs_nested_content()
  local input = v3record()
  input.mons.catalogFingerprint = "drifted"
  local migrated = assert(GameSave.normalize(input))
  Assert.equal(migrated.schema, GameSave.SCHEMA)
  Assert.equal(migrated.mons.catalogFingerprint, "drifted")
end

return { tests = T }
