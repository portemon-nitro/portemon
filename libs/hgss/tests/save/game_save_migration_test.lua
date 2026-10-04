-- GameSave v4 migration tests: the pure v3 -> v4 step copies without
-- mutating, zeroes badges, falls back to the mother spawn, and keeps every
-- other bucket intact. Current-schema validation requires fieldTravel and
-- still rejects unknown schemas.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local GameSave = require("libs.hgss.src.save.GameSave")
local BagSave = require("libs.hgss.src.save.BagSave")

local T = {}

local function v3record(overrides)
  local value = {
    schema = "g4-game-save-v3",
    saveId = "save-00000001",
    versionId = "heartgold",
    playTimeSeconds = 0,
    mapId = 60,
    fieldX = 684,
    fieldZ = 393,
    worldY = 0,
    surfaceId = 0,
    terrainDependencyHash = "terrain-heartgold",
    facing = "south",
    playerData = {
      profile = { name = "GOLD", gender = 0, trainerId = 0, money = 3000 },
      options = { textFrame = 0, textSpeed = "mid" },
    },
    world = { flags = {}, variables = {}, objects = {}, rng = {} },
    scripts = {},
    auxiliaryUi = {},
    audio = {},
    mons = {},
    bag = BagSave.empty(),
  }
  for key, replacement in pairs(overrides or {}) do
    rawset(value, key, replacement)
  end
  return value
end

local function v4record(overrides)
  local value = v3record(overrides)
  value.schema = "g4-game-save-v4"
  value.playerData.profile.badges = 0
  value.fieldTravel = { lastHealSpawn = "SPAWN_NEW_BARK" }
  return value
end

local function currentRecord(overrides)
  local value = v4record(overrides)
  local migrated = GameSave.migrateV4(value)
  return migrated
end

local function returnsCode(code, fn)
  local valid, err = fn()
  Assert.isNil(valid)
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, code)
end

function T.migration_copies_without_mutating_and_initializes_new_state()
  local input = v3record()
  local migrated = GameSave.migrateV3(input)
  Assert.equal(migrated.schema, "g4-game-save-v4")
  Assert.equal(migrated.playerData.profile.badges, 0)
  Assert.deepEqual(migrated.fieldTravel, { lastHealSpawn = "SPAWN_NEW_BARK" })
  Assert.equal(migrated.mapId, 60)
  Assert.equal(migrated.saveId, "save-00000001")
  -- The input is untouched: same schema, no badges, no travel record.
  Assert.equal(input.schema, "g4-game-save-v3")
  Assert.isNil(input.playerData.profile.badges)
  Assert.isNil(input.fieldTravel)
end

function T.migration_preserves_party_bag_leaves_world_and_rng()
  local input = v3record({
    world = { flags = { [10] = true }, variables = {}, objects = {}, rng = { seed = 7 } },
    mons = { fingerprint = "mon-fp" },
  })
  local migrated = GameSave.migrateV3(input)
  Assert.deepEqual(migrated.world, input.world)
  Assert.deepEqual(migrated.mons, input.mons)
  Assert.deepEqual(migrated.bag, input.bag)
end

function T.current_validation_requires_travel_and_rejects_old_schemas()
  Assert.notNil(GameSave.validate(currentRecord()))
  returnsCode("GAME_SAVE_BUCKET_INVALID", function()
    local value = currentRecord()
    value.fieldTravel = nil
    return GameSave.validate(value)
  end)
  returnsCode("GAME_SAVE_SCHEMA_UNSUPPORTED", function()
    return GameSave.validate(v3record())
  end)
end

function T.v4_migration_adds_only_an_empty_fashion_case_copy()
  local source = v4record()
  source.schema = "g4-game-save-v4"
  source.scripts = {
    registryFingerprint = "pre-update-registry",
    taskFingerprint = "pre-update-tasks",
    nextTaskId = 7,
    environments = {},
    instances = {},
    tasks = {},
  }
  local sourceScripts = {}
  for key, value in pairs(source.scripts) do
    sourceScripts[key] = value
  end
  local migrated = GameSave.migrateV4(source)
  Assert.equal(migrated.schema, "g4-game-save-v5")
  Assert.deepEqual(migrated.fashionCase.counts, (function()
    local counts = {}
    for id = 1, 100 do
      counts[id] = 0
    end
    return counts
  end)())
  Assert.isNil(source.fashionCase)
  Assert.equal(source.schema, "g4-game-save-v4")
  Assert.deepEqual(migrated.world, source.world)
  Assert.deepEqual(migrated.bag, source.bag)
  Assert.deepEqual(migrated.scripts, sourceScripts)
  Assert.equal(source.scripts.registryFingerprint, "pre-update-registry")
  Assert.equal(source.scripts.taskFingerprint, "pre-update-tasks")
  Assert.equal(source.schema, "g4-game-save-v4")
end

function T.v4_migration_rejects_a_bucket_that_did_not_exist_in_v4()
  local source = v4record()
  source.schema = "g4-game-save-v4"
  source.fashionCase = { unexpected = true }
  local err = Assert.throws(function()
    GameSave.migrateV4(source)
  end)
  Assert.isTrue(Errors.is(err))
  Assert.equal(source.schema, "g4-game-save-v4")
end

function T.migrated_records_validate_with_a_travel_validator()
  local migrated = GameSave.migrateV4(GameSave.migrateV3(v3record()))
  local opts = {
    fieldTravelValidate = function(value)
      Assert.deepEqual(value, { lastHealSpawn = "SPAWN_NEW_BARK" })
      return value
    end,
  }
  local valid = assert(GameSave.validate(migrated, opts))
  Assert.deepEqual(valid.fieldTravel, { lastHealSpawn = "SPAWN_NEW_BARK" })
end

return { tests = T }
