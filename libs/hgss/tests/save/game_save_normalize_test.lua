-- Tests the pure persistence-routing boundary for game saves: supported
-- records normalize and migrate without generated caches, while only
-- record/schema/save/version identity stays strict. Entry coordinates,
-- avatar, play time, and nested buckets are owned by their runtime domains
-- or display metadata, so routing normalization never traverses them.

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
      profile = {
        name = "GOLD",
        gender = 0,
        trainerId = 0,
        money = 3000,
        badges = 0,
        nationalDex = false,
        runningShoes = false,
        runningShoesLock = false,
      },
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
  value.scripts = {
    schema = "g4-script-save-v1",
    registryFingerprint = "legacy-registry",
    taskFingerprint = "legacy-tasks",
    capturedAtSimulationTick = 0,
    nextEnvironmentId = 0,
    nextInstanceId = 0,
    nextTaskId = 0,
    environments = {},
    instances = {},
    tasks = {},
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

-- Persistence routing owns only record/schema/save/version identity: every
-- other current value belongs to a runtime domain or to display metadata,
-- so it passes through untouched for its owner to validate on use.
function T.routing_identity_stays_strict_while_domain_state_passes_through()
  Assert.notNil(GameSave.normalize(record()))
  returnsCode("GAME_SAVE_SCHEMA_UNSUPPORTED", function()
    return GameSave.normalize(record({ schema = "g4-game-save-v10" }))
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
  returnsCode("GAME_SAVE_INVALID", function()
    ---@diagnostic disable-next-line: param-type-mismatch -- the test deliberately exercises invalid input
    return GameSave.normalize(nil)
  end)
  -- Field-domain, display-domain, and avatar state the routing does not
  -- own passes through byte-identically: the field owner, the menu card,
  -- and legacy migration validate what they actually use.
  local passthrough = {
    { playTimeSeconds = -1 },
    { playTimeSeconds = GameSave.MAX_PLAY_TIME_SECONDS + 1 },
    { facing = "up" },
    { mapId = -1 },
    { fieldX = 0x10000 },
    { terrainDependencyHash = "" },
    { avatar = { state = "flying" } },
    { weatherId = 99 },
  }
  for _, overrides in ipairs(passthrough) do
    local input = record(overrides)
    local trusted, trustErr = GameSave.normalize(input)
    Assert.isNil(trustErr, "routing must not preflight domain state")
    trusted = assert(trusted)
    for key, expected in pairs(overrides) do
      Assert.deepEqual(trusted[key], expected, "unowned state passes through untouched")
    end
  end
  local missingCoordinate = record()
  missingCoordinate.fieldX = nil
  Assert.notNil(GameSave.normalize(missingCoordinate))
end

function T.missing_avatar_passes_through_without_canonicalization()
  local value = record()
  value.avatar = nil
  local normalized, err = GameSave.normalize(value)
  Assert.isNil(err, "avatar state belongs to the field domain, not persistence routing")
  Assert.isNil(assert(normalized).avatar, "routing adds no avatar the owner never stored")
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
  Assert.equal(migrated.mons.schema, "g4-mons-save-v3")
  Assert.equal(migrated.scripts.schema, "g4-script-save-v2")
end

function T.unknown_top_level_extension_metadata_survives_current_normalization()
  local input = record({ modState = { marker = "kept" } })
  local normalized = assert(GameSave.normalize(input))
  Assert.equal(normalized.schema, GameSave.SCHEMA)
  Assert.deepEqual(normalized.modState, { marker = "kept" })
  Assert.equal(normalized.mapId, 60)
  -- Routing identity stays strict alongside unrelated extensions, while
  -- field-domain values pass through even next to extension state.
  local _, routingErr = GameSave.normalize(record({ modState = { marker = "kept" }, versionId = "" }))
  Assert.equal(assert(routingErr).code, "GAME_SAVE_VERSION_INVALID")
  local trusted = assert(GameSave.normalize(record({ modState = { marker = "kept" }, mapId = -1 })))
  Assert.equal(trusted.mapId, -1)
  Assert.deepEqual(trusted.modState, { marker = "kept" })
end

function T.historical_migration_never_repairs_nested_content()
  local input = v3record()
  input.mons.rng = { state = 99, calls = 3 }
  local migrated = assert(GameSave.normalize(input))
  Assert.equal(migrated.schema, GameSave.SCHEMA)
  Assert.deepEqual(migrated.mons.rng, { state = 99, calls = 3 }, "nested state passes through unrepaired")
  Assert.isNil(migrated.mons.catalogFingerprint, "migration drops the obsolete fingerprint without repairing state")
end

return { tests = T }
