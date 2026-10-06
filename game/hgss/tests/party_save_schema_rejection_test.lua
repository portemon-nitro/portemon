-- Save compatibility: the former schema is rejected through the structured
-- save-error path without migrating or synthesizing a fallback. Nested
-- buckets travel untouched to their owning runtime domains, so a missing
-- bucket still normalizes and its owner reports the failure at restore.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local GameSave = require("libs.hgss.src.save.GameSave")
local BagSave = require("libs.hgss.src.save.BagSave")

local T = {}

local function record(schema, overrides)
  local value = {
    schema = schema,
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
    playerData = { profile = {}, options = {} },
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

local function rejectionCode(candidate)
  local normalized, err = GameSave.normalize(candidate)
  Assert.isNil(normalized, "the record must not normalize")
  Assert.isTrue(Errors.is(err), "rejection uses the structured save-error path")
  return assert(err).code
end

function T.former_schema_is_rejected_without_migration()
  Assert.equal(
    rejectionCode(record("g4-game-save-v2")),
    "GAME_SAVE_SCHEMA_UNSUPPORTED",
    "the former schema is rejected rather than migrated"
  )
end

function T.missing_nested_buckets_travel_to_their_owning_domains()
  local withoutBag = record(GameSave.SCHEMA)
  withoutBag.bag = nil
  Assert.notNil(
    GameSave.normalize(withoutBag),
    "a record without a bag bucket normalizes; the bag owner reports the missing state at restore"
  )
  local withoutMons = record(GameSave.SCHEMA)
  withoutMons.mons = nil
  Assert.notNil(
    GameSave.normalize(withoutMons),
    "a record without a mons bucket normalizes; the mon service reports the missing state at restore"
  )
end

return { tests = T }
