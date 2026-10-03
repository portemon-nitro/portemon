-- GameSave v4 migration tests: the pure v3 -> v4 step copies without
-- mutating, zeroes badges, falls back to the mother spawn, and keeps every
-- other bucket intact. Current-schema validation requires fieldTravel and
-- still rejects unknown schemas.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local GameSave = require("libs.hgss.src.save.GameSave")
local BagSave = require("libs.hgss.src.save.BagSave")
local MartSave = require("libs.hgss.src.save.MartSave")

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

local function v5record(overrides)
  local value = v4record(overrides)
  value.schema = GameSave.SCHEMA
  value.playerData.profile.nationalDex = false
  value.mart = MartSave.empty()
  return value
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
  Assert.notNil(GameSave.validate(v5record()))
  returnsCode("GAME_SAVE_BUCKET_INVALID", function()
    local value = v5record()
    value.fieldTravel = nil
    return GameSave.validate(value)
  end)
  returnsCode("GAME_SAVE_SCHEMA_UNSUPPORTED", function()
    return GameSave.validate(v3record())
  end)
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

function T.v4_migration_adds_only_the_declared_state_and_does_not_mutate_input()
  local input = v4record({
    world = { flags = { [10] = true }, variables = {}, objects = {}, rng = { seed = 17 } },
    mons = { fingerprint = "mon-fp", members = { "preserved" } },
  })
  input.bag.pockets.medicine[1] = { item = "POTION", quantity = 4 }
  input.bag.registered = { "BICYCLE" }
  local beforeWorld, beforeMons, beforeBag = input.world, input.mons, input.bag

  local migrated = GameSave.migrateV4(input)
  Assert.equal(migrated.schema, "g4-game-save-v5")
  Assert.equal(migrated.playerData.profile.nationalDex, false)
  Assert.deepEqual(migrated.mart, MartSave.empty())
  Assert.deepEqual(migrated.world, beforeWorld)
  Assert.deepEqual(migrated.mons, beforeMons)
  Assert.deepEqual(migrated.bag, beforeBag)
  Assert.equal(input.schema, "g4-game-save-v4")
  Assert.isNil(input.playerData.profile.nationalDex)
  Assert.isNil(input.mart)
end

function T.v3_migrates_through_literal_v4_before_v5_defaults_are_added()
  local first = GameSave.migrateV3(v3record())
  Assert.equal(first.schema, "g4-game-save-v4", "v3 migration remains an explicit intermediate step")
  local current = GameSave.migrateV4(first)
  Assert.equal(current.schema, GameSave.SCHEMA)
  Assert.equal(current.playerData.profile.nationalDex, false)
  Assert.deepEqual(current.mart, MartSave.empty())
end

function T.malformed_current_economy_and_v4_input_are_not_repaired_in_place()
  local malformed = v5record()
  malformed.mart.dailyPurchasedMask = 4096
  returnsCode("GAME_SAVE_BUCKET_INVALID", function()
    return GameSave.validate(malformed, { martValidate = function(value)
      local canonical, err = MartSave.validate(value, {
        cards = {}, apricorns = {}, seals = {},
      })
      return canonical, err
    end })
  end)
  Assert.equal(malformed.schema, GameSave.SCHEMA)
  Assert.equal(malformed.mart.dailyPurchasedMask, 4096)
end

return { tests = T }
