-- Tests the one version-aware semantic boundary used by persisted records and
-- in-memory field construction.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local Errors = require("libs.errors.src.Errors")
local GameSaveValidation = require("libs.hgss.src.save.GameSaveValidation")
local ItemFixture = require("libs.items.tests.item_fixture")
local BagSave = require("libs.hgss.src.save.BagSave")
local FashionCaseState = require("libs.hgss.src.save.FashionCaseState")
local MonsSave = require("libs.mons.src.MonsSave")
local MartSave = require("libs.hgss.src.save.MartSave")

local T = {}

local function monsBucket()
  return MonsSave.empty(CatalogFixture.makeCatalog():fingerprint(), 7)
end

local function context()
  return {
    charmap = { G = 1, O = 2, L = 3, D = 4 },
    frameIndexes = { [0] = true },
    audioSequenceIds = { [7] = true },
    monCatalog = CatalogFixture.makeCatalog(),
    itemCatalog = ItemFixture.makeCatalog(),
    martCatalog = { cards = {}, apricorns = {}, seals = {} },
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

local function record(saveId, versionId, playerData)
  return {
    schema = "g4-game-save-v5",
    saveId = saveId,
    versionId = versionId,
    playTimeSeconds = 0,
    mapId = 60,
    fieldX = 684,
    fieldZ = 393,
    worldY = 0,
    surfaceId = 0,
    terrainDependencyHash = "terrain-" .. versionId,
    facing = "south",
    playerData = playerData,
    fieldTravel = { lastHealSpawn = "SPAWN_NEW_BARK" },
    world = { flags = {}, variables = {}, objects = {}, rng = { state = 1, calls = 0 } },
    scripts = {
      schema = "g4-script-save-v1",
      registryFingerprint = "registry",
      taskFingerprint = "tasks",
      capturedAtSimulationTick = 41,
      nextEnvironmentId = 3,
      nextInstanceId = 5,
      nextTaskId = 7,
      environments = {},
      instances = {},
      tasks = {},
    },
    auxiliaryUi = { requested = "shown", state = "shown" },
    audio = {},
    mons = monsBucket(),
    bag = BagSave.empty(),
    mart = MartSave.empty(),
    fashionCase = FashionCaseState.empty(),
  }
end

local function v4record(saveId, versionId, playerData)
  local value = record(saveId, versionId, playerData)
  value.schema = "g4-game-save-v4"
  value.mart = nil
  value.fashionCase = nil
  return value
end

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, child in pairs(value) do
    result[key] = copy(child)
  end
  return result
end

local function markPreUpdateFingerprints(candidate)
  candidate.scripts.registryFingerprint = "pre-update-registry"
  candidate.scripts.taskFingerprint = "pre-update-tasks"
end

local function fieldObjectActor(overrides)
  local result = {
    actorId = "map:60:object:7",
    mapId = 60,
    objectEventId = 7,
    sourceMovementType = "walk_north_east_west_south",
    movementType = "walk_north_east_west_south",
    fieldX = 12,
    fieldZ = 14,
    cellKey = "0:0",
    sourceSurfaceId = 3,
    facing = "east",
    managerOrder = 0,
    controller = { kind = "pattern", timer = 0, sequenceIndex = 1 },
  }
  for key, value in pairs(overrides or {}) do
    rawset(result, key, value)
  end
  return result
end

local function fieldObjectBucket(actor)
  return {
    schema = "g4-field-objects-v1",
    rng = { state = 7, calls = 3 },
    actors = { [actor.actorId] = actor },
  }
end

local validPlayerData = {
  profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000, badges = 0, nationalDex = false },
  options = { textFrame = 0, textSpeed = "mid" },
}

function T.full_record_validation_is_shared_and_version_context_is_cached()
  local loads = 0
  local service = GameSaveValidation.new({
    contextLoader = function(versionId)
      loads = loads + 1
      Assert.equal(versionId, "heartgold")
      return context()
    end,
  })
  local first = assert(service:validate(record("save-00000001", "heartgold", validPlayerData)))
  local second = assert(service:validate(record("save-00000002", "heartgold", validPlayerData)))
  Assert.equal(first.saveId, "save-00000001")
  Assert.equal(second.saveId, "save-00000002")
  Assert.equal(first.schema, "g4-game-save-v5")
  Assert.equal(first.fashionCase.schema, "hgss-fashion-case-v1")
  Assert.equal(loads, 1)
  local invalid, err = service:validate(record("save-00000003", "heartgold", { options = {} }))
  Assert.isNil(invalid)
  Assert.isTrue(Errors.is(err))
end

function T.v5_fashion_case_is_required_and_strict_while_v4_migrates()
  local service = GameSaveValidation.new({
    contextLoader = function()
      return context()
    end,
  })
  local current = assert(service:validate(record("save-00000031", "heartgold", validPlayerData)))
  local missing = {}
  for key, value in pairs(current) do
    missing[key] = value
  end
  missing.fashionCase = nil
  local invalid, err = service:validate(missing)
  Assert.isNil(invalid)
  Assert.isTrue(Errors.is(err))

  local malformed = {}
  for key, value in pairs(current) do
    malformed[key] = value
  end
  malformed.fashionCase = { schema = "hgss-fashion-case-v1", counts = {} }
  invalid, err = service:validate(malformed)
  Assert.isNil(invalid)
  Assert.isTrue(Errors.is(err))

  local invalidV4 = record("save-00000032", "heartgold", validPlayerData)
  invalidV4.fashionCase = { schema = "hgss-fashion-case-v1", counts = {} }
  invalid, err = service:validate(invalidV4)
  Assert.isNil(invalid)
  Assert.isTrue(Errors.is(err))
end

function T.version_context_failure_does_not_borrow_another_version()
  local service = GameSaveValidation.new({
    contextLoader = function(versionId)
      if versionId == "heartgold" then
        return context()
      end
      Errors.raise("SAVE_VERSION_CONTEXT_UNAVAILABLE", "version context is unavailable", { versionId = versionId })
    end,
  })
  Assert.notNil(service:validate(record("save-00000001", "heartgold", validPlayerData)))
  local invalid, err = service:validate(record("save-00000002", "soulsilver", validPlayerData))
  Assert.isNil(invalid)
  local unavailableError = assert(err)
  Assert.equal(unavailableError.code, "SAVE_VERSION_CONTEXT_UNAVAILABLE")
end

function T.complete_validation_rejects_stale_task_identity()
  local selected = context()
  selected.scriptCompatibility.validationOptions = function()
    return {
      expectedRegistryFingerprint = "registry",
      expectedTaskFingerprint = "current-tasks",
      resolveTask = function()
        return nil
      end,
      resolveComposition = function()
        return nil
      end,
    }
  end
  local service = GameSaveValidation.new({
    contextLoader = function()
      return selected
    end,
  })
  local current = assert(
    GameSaveValidation.new({
      contextLoader = function()
        return context()
      end,
    }):validate(record("save-00000004", "heartgold", validPlayerData))
  )
  current.scripts.taskFingerprint = "pre-update-tasks"
  local invalid, err = service:validate(current)
  Assert.isNil(invalid)
  Assert.isTrue(Errors.is(err))
  local validationError = assert(err)
  Assert.equal(validationError.code, "GAME_SAVE_BUCKET_INVALID")
end

function T.quiescent_v4_saves_rebind_stale_fingerprints_and_preserve_state()
  local service = GameSaveValidation.new({
    contextLoader = function()
      return context()
    end,
  })
  local candidate = v4record("save-00000018", "heartgold", validPlayerData)
  markPreUpdateFingerprints(candidate)
  candidate.world.flags = { [12] = true }
  candidate.world.rng = { state = 91, calls = 37 }
  candidate.mons = monsBucket()
  local sourceWorld = copy(candidate.world)
  local sourcePlayerData = copy(candidate.playerData)
  local sourceFieldTravel = copy(candidate.fieldTravel)
  local sourceMons = copy(candidate.mons)
  local sourceBag = copy(candidate.bag)
  local sourceScripts = copy(candidate.scripts)

  local valid = assert(service:validate(candidate))
  Assert.equal(valid.schema, "g4-game-save-v5")
  Assert.equal(valid.fashionCase.schema, "hgss-fashion-case-v1")
  Assert.equal(valid.scripts.registryFingerprint, "registry")
  Assert.equal(valid.scripts.taskFingerprint, "tasks")
  Assert.equal(valid.scripts.capturedAtSimulationTick, sourceScripts.capturedAtSimulationTick)
  Assert.equal(valid.scripts.nextEnvironmentId, sourceScripts.nextEnvironmentId)
  Assert.equal(valid.scripts.nextInstanceId, sourceScripts.nextInstanceId)
  Assert.equal(valid.scripts.nextTaskId, sourceScripts.nextTaskId)
  Assert.deepEqual(valid.world, sourceWorld)
  Assert.deepEqual(valid.playerData, sourcePlayerData)
  Assert.deepEqual(valid.fieldTravel, sourceFieldTravel)
  Assert.deepEqual(valid.mons, sourceMons)
  Assert.deepEqual(valid.bag, sourceBag)
  Assert.equal(candidate.schema, "g4-game-save-v4")
  Assert.equal(candidate.scripts.registryFingerprint, "pre-update-registry")
  Assert.equal(candidate.scripts.taskFingerprint, "pre-update-tasks")
  Assert.deepEqual(candidate.scripts, sourceScripts)
  Assert.isNil(candidate.fashionCase)
end

function T.active_v4_graphs_reject_without_mutating_the_source()
  local service = GameSaveValidation.new({
    contextLoader = function()
      return context()
    end,
  })
  local candidate = v4record("save-00000019", "heartgold", validPlayerData)
  markPreUpdateFingerprints(candidate)
  candidate.scripts.environments = { { environmentId = 1 } }
  candidate.scripts.instances = { { instanceId = 1 } }
  candidate.scripts.tasks = { { taskId = 1, taskType = "old_task", taskVersion = 1 } }
  local before = copy(candidate)

  local invalid, err = service:validate(candidate)
  Assert.isNil(invalid)
  local rejection = assert(err)
  Assert.equal(rejection.code, "GAME_SAVE_SCHEMA_UNSUPPORTED")
  Assert.equal(rejection.context.schema, "g4-game-save-v4")
  Assert.isTrue(rejection.message:find("active", 1, true) ~= nil)
  Assert.deepEqual(candidate, before)
end

function T.complete_validation_composes_field_object_validation()
  local service = GameSaveValidation.new({
    contextLoader = function()
      return context()
    end,
  })
  local candidate = record("save-00000005", "heartgold", validPlayerData)
  candidate.world.objects = {
    schema = "g4-field-objects-v1",
    rng = { state = 7, calls = 3 },
    actors = {},
  }
  local valid = assert(service:validate(candidate))
  Assert.equal(valid.world.objects.schema, "g4-field-objects-v1")
end

function T.complete_validation_rejects_malformed_field_object_actor_state()
  local service = GameSaveValidation.new({
    contextLoader = function()
      return context()
    end,
  })

  local validRecord = record("save-00000006", "heartgold", validPlayerData)
  validRecord.world.objects = fieldObjectBucket(fieldObjectActor())
  Assert.notNil(service:validate(validRecord), "the valid field-object actor must pass")

  local oversizedPatternIndex = record("save-00000007", "heartgold", validPlayerData)
  local invalidPatternActor = fieldObjectActor()
  invalidPatternActor.controller.sequenceIndex = 999
  oversizedPatternIndex.world.objects = fieldObjectBucket(invalidPatternActor)
  local invalid, err = service:validate(oversizedPatternIndex)
  Assert.isNil(invalid)
  Assert.isTrue(Errors.is(err))

  local removedBlockedState = record("save-00000008", "heartgold", validPlayerData)
  removedBlockedState.world.objects = fieldObjectBucket(fieldObjectActor({
    controller = { kind = "pattern", timer = 0, sequenceIndex = 1, blocked = false },
  }))
  invalid, err = service:validate(removedBlockedState)
  Assert.isNil(invalid)
  Assert.isTrue(Errors.is(err))
end

function T.complete_validation_canonicalizes_a_missing_avatar_to_walking()
  local service = GameSaveValidation.new({
    contextLoader = function()
      return context()
    end,
  })
  local candidate = record("save-00000009", "heartgold", validPlayerData)
  Assert.isNil(candidate.avatar)
  local valid = assert(service:validate(candidate))
  Assert.deepEqual(valid.avatar, { state = "walking" }, "a legacy record without avatar state loads as walking")
  Assert.equal(valid.schema, "g4-game-save-v5", "legacy records migrate to the current schema")
end

function T.complete_validation_round_trips_every_durable_avatar_state()
  local service = GameSaveValidation.new({
    contextLoader = function()
      return context()
    end,
  })
  for _, durable in ipairs({ "walking", "cycling", "surfing", "rocket" }) do
    local candidate = record("save-00000010", "heartgold", validPlayerData)
    candidate.avatar = { state = durable }
    local valid = assert(service:validate(candidate))
    Assert.deepEqual(valid.avatar, { state = durable })
  end
end

function T.complete_validation_rejects_non_durable_and_malformed_avatar_records()
  local service = GameSaveValidation.new({
    contextLoader = function()
      return context()
    end,
  })
  local cases = {
    { avatar = { state = "heal" }, label = "temporary visual state" },
    { avatar = { state = "saving" }, label = "temporary saving state" },
    { avatar = { state = "nope" }, label = "unknown state" },
    { avatar = {}, label = "missing state" },
    { avatar = { state = 7 }, label = "non-string state" },
    { avatar = { state = "walking", phase = 3 }, label = "unknown extra field" },
    { avatar = "walking", label = "non-table record" },
  }
  for _, case in ipairs(cases) do
    local candidate = record("save-00000011", "heartgold", validPlayerData)
    candidate.avatar = case.avatar
    local invalid, err = service:validate(candidate)
    Assert.isNil(invalid, case.label .. " must not validate")
    Assert.isTrue(Errors.is(err), case.label .. " must raise a structured error")
  end
end

function T.complete_validation_rejects_records_without_a_valid_bag()
  local service = GameSaveValidation.new({
    contextLoader = function()
      return context()
    end,
  })
  local missing = record("save-00000012", "heartgold", validPlayerData)
  missing.bag = nil
  local invalid, err = service:validate(missing)
  Assert.isNil(invalid, "a v3 record without a bag must not validate")
  Assert.isTrue(Errors.is(err))

  local malformed = record("save-00000013", "heartgold", validPlayerData)
  malformed.bag = { schema = "hgss-bag-v1", pockets = {}, registered = {} }
  invalid, err = service:validate(malformed)
  Assert.isNil(invalid, "a v3 record with a malformed bag must not validate")
  Assert.isTrue(Errors.is(err))

  local valid = assert(service:validate(record("save-00000014", "heartgold", validPlayerData)))
  Assert.equal(valid.bag.schema, "hgss-bag-v1", "a valid bag bucket survives version validation")
end

local function v3record(saveId, playerData, scripts)
  local value = record(saveId, "heartgold", playerData)
  value.schema = "g4-game-save-v3"
  value.fieldTravel = nil
  value.mart = nil
  value.fashionCase = nil
  value.playerData = {
    profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000 },
    options = { textFrame = 0, textSpeed = "mid" },
  }
  value.scripts = scripts
  return value
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

function T.quiescent_v3_saves_migrate_without_losing_history()
  local service = GameSaveValidation.new({
    contextLoader = function()
      return context()
    end,
  })
  local candidate = v3record("save-00000015", validPlayerData, quiescentScripts())
  local valid = assert(service:validate(candidate))
  Assert.equal(valid.schema, "g4-game-save-v5")
  Assert.equal(valid.fashionCase.schema, "hgss-fashion-case-v1")
  Assert.equal(valid.playerData.profile.badges, 0)
  Assert.equal(valid.playerData.profile.nationalDex, false)
  Assert.deepEqual(valid.mart, MartSave.empty())
  Assert.deepEqual(valid.fieldTravel, { lastHealSpawn = "SPAWN_NEW_BARK" })
  Assert.equal(valid.scripts.registryFingerprint, "registry")
  Assert.equal(valid.scripts.taskFingerprint, "tasks")
  Assert.equal(valid.scripts.nextEnvironmentId, 3)
  Assert.equal(valid.scripts.nextInstanceId, 5)
  Assert.equal(valid.scripts.nextTaskId, 7)
  Assert.equal(valid.playerData.profile.name, "GOLD")
  -- The submitted bytes are untouched: still v3, badge-less, old prints.
  Assert.equal(candidate.schema, "g4-game-save-v3")
  Assert.isNil(candidate.playerData.profile.badges)
  Assert.isNil(candidate.fieldTravel)
  Assert.equal(candidate.scripts.registryFingerprint, "old-registry")
end

function T.active_v3_graphs_reject_without_data_loss()
  local service = GameSaveValidation.new({
    contextLoader = function()
      return context()
    end,
  })
  local scripts = quiescentScripts()
  scripts.tasks = {
    {
      taskId = 1,
      taskType = "field_move",
      taskVersion = 1,
      ownerInstanceId = 1,
      environmentId = 1,
      state = {},
    },
  }
  local candidate = v3record("save-00000016", validPlayerData, scripts)
  local invalid, err = service:validate(candidate)
  Assert.isNil(invalid)
  local rejection = assert(err)
  Assert.equal(rejection.code, "GAME_SAVE_SCHEMA_UNSUPPORTED")
  Assert.equal(candidate.schema, "g4-game-save-v3")
  Assert.equal(#candidate.scripts.tasks, 1)
end

function T.malformed_v4_travel_is_rejected_never_repaired()
  local service = GameSaveValidation.new({
    contextLoader = function()
      return context()
    end,
  })
  local candidate = record("save-00000017", "heartgold", validPlayerData)
  candidate.fieldTravel = { lastHealSpawn = "" }
  local invalid, err = service:validate(candidate)
  Assert.isNil(invalid)
  Assert.isTrue(Errors.is(err))
end

return { tests = T }
