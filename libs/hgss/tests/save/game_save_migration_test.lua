-- GameSave v4 migration tests: the pure v3 -> v4 step copies without
-- mutating, zeroes badges, falls back to the mother spawn, and keeps every
-- other bucket intact. Current-schema validation requires fieldTravel and
-- still rejects unknown schemas. Listing recognizes supported historical
-- envelopes without approving them semantically: legacy reads migrate only
-- in memory until an explicit save, active historical saves stay rejected,
-- and a listed envelope never implies a loadable record.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local GameSave = require("libs.hgss.src.save.GameSave")
local BagSave = require("libs.hgss.src.save.BagSave")
local EncounterSave = require("libs.hgss.src.save.EncounterSave")
local PokedexSave = require("libs.hgss.src.save.PokedexSave")
local GameSaveStore = require("libs.hgss.src.save.GameSaveStore")
local GameSaveValidation = require("game.hgss.src.save.GameSaveValidation")
local SaveFs = require("libs.storage.src.SaveFs")
local FakeCache = require("tests.support.FakeCache")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local ItemFixture = require("libs.items.tests.item_fixture")
local MonsSave = require("libs.mons.src.MonsSave")
local Lcrng = require("libs.mons.src.gen4.Lcrng")

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
  value.schema = GameSave.SCHEMA
  value.playerData.profile.badges = 0
  value.fieldTravel = { lastHealSpawn = "SPAWN_NEW_BARK" }
  value.encounters = EncounterSave.initial()
  value.pokedex = PokedexSave.initial()
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
  Assert.notNil(GameSave.validate(v4record()))
  returnsCode("GAME_SAVE_BUCKET_INVALID", function()
    local value = v4record()
    value.fieldTravel = nil
    return GameSave.validate(value)
  end)
  returnsCode("GAME_SAVE_SCHEMA_UNSUPPORTED", function()
    return GameSave.validate(v3record())
  end)
end

function T.migrated_records_validate_with_a_travel_validator()
  local migrated = GameSave.migrateV5(GameSave.migrateV4(GameSave.migrateV3(v3record())))
  local opts = {
    fieldTravelValidate = function(value)
      Assert.deepEqual(value, { lastHealSpawn = "SPAWN_NEW_BARK" })
      return value
    end,
  }
  local valid = assert(GameSave.validate(migrated, opts))
  Assert.deepEqual(valid.fieldTravel, { lastHealSpawn = "SPAWN_NEW_BARK" })
end

function T.v5_migration_fabricates_neither_frontier_nor_special_spawn()
  local input = GameSave.migrateV4(GameSave.migrateV3(v3record()))
  local originalSchema = input.schema
  local migrated = GameSave.migrateV5(input)
  Assert.equal(originalSchema, GameSave.HISTORICAL_SCHEMA_V5)
  Assert.equal(input.schema, originalSchema)
  Assert.isNil(input.battleFrontier)
  Assert.isNil(migrated.battleFrontier, "migration creates no Frontier bucket")
  Assert.isNil(migrated.fieldTravel.specialSpawn, "an absent special spawn migrates as nil")
  Assert.deepEqual(migrated.fieldTravel, { lastHealSpawn = "SPAWN_NEW_BARK" })
  Assert.equal(migrated.schema, GameSave.SCHEMA)
end

function T.v5_migration_preserves_field_travel_exactly()
  local input = GameSave.migrateV4(GameSave.migrateV3(v3record()))
  input.fieldTravel = {
    lastHealSpawn = "SPAWN_GOLDENROD",
    specialSpawn = { map = "MAP_NEW_BARK", fieldX = 688, fieldZ = 393, warpId = -1, direction = "south" },
  }
  local migrated = GameSave.migrateV5(input)
  Assert.deepEqual(migrated.fieldTravel, input.fieldTravel, "migration carries travel through untouched")
  Assert.isNil(migrated.battleFrontier, "migration creates no Frontier bucket")
end

local function quiescentScripts()
  return {
    schema = "g4-script-save-v1",
    registryFingerprint = "old-registry",
    taskFingerprint = "old-tasks",
    capturedAtSimulationTick = 41,
    nextEnvironmentId = 3,
    nextInstanceId = 5,
    nextTaskId = 7,
    environments = {},
    instances = {},
    tasks = {},
  }
end

-- A payload as an older game version wrote it: v3 envelope, badge-less
-- profile, quiescent scripts, current mons and bag buckets.
local function historicalRecord(saveId)
  local monCatalog = CatalogFixture.makeCatalog()
  local factory = CatalogFixture.makeFactory(0x12345678, monCatalog)
  local mon = factory:createNormal(CatalogFixture.normalRequest())
  return {
    schema = "g4-game-save-v3",
    saveId = saveId,
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
      profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000 },
      options = { textFrame = 0, textSpeed = "mid" },
    },
    world = { flags = {}, variables = {}, objects = {}, rng = { state = 1, calls = 0 } },
    scripts = quiescentScripts(),
    auxiliaryUi = { requested = "shown", state = "shown" },
    audio = {},
    mons = MonsSave.capture(
      { max = 6, mons = { mon } },
      Lcrng.new(0x99999999):capture(),
      monCatalog:fingerprint()
    ),
    bag = BagSave.empty(),
  }
end

local function validationContext()
  return {
    charmap = CatalogFixture.CHARMAP,
    frameIndexes = { [0] = true },
    audioSequenceIds = { [7] = true },
    monCatalog = CatalogFixture.makeCatalog(),
    itemCatalog = ItemFixture.makeCatalog(),
    scriptCompatibility = {
      validationOptions = function()
        return {
          expectedRegistryFingerprint = "registry",
          expectedTaskFingerprint = "tasks",
          resolveTask = function()
            return nil
          end,
          resolveComposition = function()
            return nil
          end,
        }
      end,
    },
  }
end

local function wiredStore(backend)
  local validation = GameSaveValidation.new({
    contextLoader = function()
      return validationContext()
    end,
  })
  local store = GameSaveStore.new(SaveFs.global(backend), {
    recordValidate = function(record)
      return validation:validate(record)
    end,
  })
  return store
end

-- Plant a payload exactly as the older version left it: the current
-- publisher would refuse the v3 envelope, so the bytes and the catalog
-- entry are written directly.
local function plantPayload(backend, saveId, record)
  local saveFs = SaveFs.global(backend)
  saveFs:writeLua("catalog.lua", {
    schema = GameSaveStore.CATALOG_SCHEMA,
    nextId = 2,
    allocatedIds = { saveId },
    deletedIds = {},
    saveIds = { saveId },
  })
  saveFs:writeLua("games/" .. saveId .. ".lua", record)
end

function T.historical_envelopes_list_without_semantic_approval()
  local candidate = historicalRecord("save-00000001")
  local envelope = GameSave.metadata(candidate)
  Assert.notNil(envelope, "listing must recognize the supported historical envelope")
  Assert.equal(envelope.saveId, "save-00000001")
  Assert.equal(envelope.versionId, "heartgold")
  Assert.equal(envelope.playerData.profile.name, "GOLD")
end

function T.planted_historical_payload_lists_its_envelope()
  local backend = FakeCache.new()
  local store = wiredStore(backend)
  plantPayload(backend, "save-00000001", historicalRecord("save-00000001"))
  local entries = store:listMetadata()
  Assert.equal(#entries, 1)
  Assert.isNil(entries[1].error, "the historical payload must list its envelope")
  Assert.equal(entries[1].saveId, "save-00000001")
  Assert.equal(entries[1].playerData.profile.name, "GOLD")
end

function T.migrated_loads_write_nothing_until_explicit_save()
  local backend = FakeCache.new()
  local writes = {}
  local originalWrite = backend.write
  rawset(backend, "write", function(self, path, data)
    writes[#writes + 1] = path
    return originalWrite(self, path, data)
  end)
  local store = wiredStore(backend)
  plantPayload(backend, "save-00000001", historicalRecord("save-00000001"))
  writes = {}
  local loaded = assert(store:load("save-00000001"))
  Assert.equal(loaded.schema, "g4-game-save-v6")
  Assert.equal(loaded.playerData.profile.badges, 0)
  Assert.deepEqual(writes, {}, "loading and migrating must not write")
  local raw = assert(SaveFs.global(backend):loadLua("games/save-00000001.lua"))
  Assert.equal(raw.schema, "g4-game-save-v3", "the stored bytes keep their historical schema")
  Assert.isNil(raw.fieldTravel, "the stored bytes gain no travel record before an explicit save")
  local entries = store:list()
  Assert.equal(#entries, 1)
  Assert.isNil(entries[1].error, "the migrated view lists without error")
  store:save(loaded)
  Assert.isTrue(#writes > 0, "the explicit save must record its writes")
  local published = assert(SaveFs.global(backend):loadLua("games/save-00000001.lua"))
  Assert.equal(published.schema, "g4-game-save-v6", "only the explicit save publishes migrated bytes")
end

function T.active_historical_saves_stay_rejected()
  local candidate = historicalRecord("save-00000002")
  candidate.scripts.tasks = {
    { taskId = 1, taskType = "field_move", taskVersion = 1, ownerInstanceId = 1, environmentId = 1, state = {} },
  }
  local validation = GameSaveValidation.new({
    contextLoader = function()
      return validationContext()
    end,
  })
  local invalid, err = validation:validate(candidate)
  Assert.isNil(invalid, "a historical save with an active graph must not migrate")
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, "GAME_SAVE_SCHEMA_UNSUPPORTED")
  Assert.equal(candidate.schema, "g4-game-save-v3", "the rejected record is left untouched")
  Assert.equal(#candidate.scripts.tasks, 1, "the rejected tasks are left untouched")
end

function T.listing_never_approves_semantics()
  local backend = FakeCache.new()
  local store = wiredStore(backend)
  local candidate = historicalRecord("save-00000001")
  candidate.schema = GameSave.SCHEMA
  candidate.fieldTravel = { lastHealSpawn = "SPAWN_NEW_BARK" }
  candidate.playerData.profile.badges = 0
  candidate.bag.pockets.balls = { { item = "NOPE_BALL", quantity = 1 } }
  plantPayload(backend, "save-00000001", candidate)
  local entries = store:listMetadata()
  Assert.equal(#entries, 1)
  Assert.isNil(entries[1].error, "the display envelope is shallow by design")
  Assert.equal(entries[1].playerData.profile.name, "GOLD")
  local ok, failure = pcall(function()
    return store:load("save-00000001")
  end)
  Assert.isFalse(ok, "the listed but semantically invalid record must not load")
  Assert.isTrue(Errors.is(failure))
  Assert.equal(failure.code, "GAME_SAVE_BUCKET_INVALID")
end

return { tests = T }
