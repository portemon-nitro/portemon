-- GameSave version migration tests: each pure version step copies without
-- mutating its source, adds only its own newly owned state, and keeps every
-- other bucket intact. Direct current validation accepts only the current
-- schema and still rejects unknown schemas.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local GameSave = require("libs.hgss.src.save.GameSave")
local BagSave = require("libs.hgss.src.save.BagSave")

local FashionCaseState = require("libs.hgss.src.save.FashionCaseState")
local Mailbox = require("libs.hgss.src.save.Mailbox")
local MartSave = require("libs.hgss.src.save.MartSave")
local PhotoAlbum = require("libs.hgss.src.save.PhotoAlbum")
local EncounterSave = require("libs.hgss.src.save.EncounterSave")
local PokedexSave = require("libs.hgss.src.save.PokedexSave")


local T = {}

local function legacyScriptsBucket()
  return {
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
end

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
    scripts = legacyScriptsBucket(),
    auxiliaryUi = {},
    audio = {},
    mons = {
      schema = "g4-mons-save-v1",
      catalogFingerprint = "legacy-catalog",
      rng = { state = 7, calls = 0 },
      party = { max = 6, mons = {} },
    },
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
  value.encounters = EncounterSave.initial()
  value.pokedex = PokedexSave.initial()
  return value
end

local function currentRecord(overrides)
  local value = v4record(overrides)
  return GameSave.migrateV6(GameSave.migrateV5(GameSave.migrateV4(value)))
end

-- Master-era v5: v4 state plus the national Dex flag and mart state, with
-- no fashion-case state. Historical fixtures use this exact shape.
local function v5record(overrides)
  local value = v4record(overrides)
  value.schema = GameSave.LEGACY_V5_SCHEMA
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

function T.current_envelope_normalizes_while_old_schemas_migrate_first()
  local current = GameSave.migrateV6(GameSave.migrateV5(v5record()))
  Assert.notNil(GameSave.normalize(current))
  -- Nested buckets travel to their owning domains untouched: a missing
  -- travel record still normalizes, and field restore reports the failure
  -- when it actually needs the state.
  local withoutTravel = currentRecord()
  withoutTravel.fieldTravel = nil
  Assert.notNil(GameSave.normalize(withoutTravel))
  -- Historical records never normalize directly as current: they advance
  -- only through the migration boundary.
  returnsCode("GAME_SAVE_SCHEMA_UNSUPPORTED", function()
    local value = v3record()
    value.schema = "g4-game-save-v2"
    return GameSave.normalize(value)
  end)
  local migratedV3 = assert(GameSave.normalize(v3record()))
  Assert.equal(migratedV3.schema, GameSave.SCHEMA)
  local migratedV5 = assert(GameSave.normalize(v5record()))
  Assert.equal(migratedV5.schema, GameSave.SCHEMA)
end


function T.v4_migration_adds_only_national_dex_and_mart_state()
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
  Assert.equal(migrated.playerData.profile.nationalDex, false)
  Assert.deepEqual(migrated.mart, MartSave.empty())
  Assert.isNil(migrated.fashionCase, "the master advancement carries no fashion-case state")
  Assert.isNil(source.fashionCase)
  Assert.isNil(source.mart)
  Assert.isNil(source.playerData.profile.nationalDex)
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

function T.migrated_records_carry_their_travel_state_to_the_owning_domain()
  local migrated = GameSave.migrateV6(GameSave.migrateV5(GameSave.migrateV4(GameSave.migrateV3(v3record()))))
  local normalized = assert(GameSave.normalize(migrated))
  Assert.deepEqual(normalized.fieldTravel, { lastHealSpawn = "SPAWN_NEW_BARK" })
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

function T.v3_migrates_through_v4_v5_and_both_v6_layout_steps()
  local first = GameSave.migrateV3(v3record())
  Assert.equal(first.schema, "g4-game-save-v4", "v3 migration remains an explicit intermediate step")
  local v5 = GameSave.migrateV4(first)
  Assert.equal(v5.schema, GameSave.LEGACY_V5_SCHEMA)
  local v6 = GameSave.migrateV5(v5)
  Assert.equal(v6.schema, GameSave.LEGACY_V6_SCHEMA)
  local v7 = GameSave.migrateV6(v6)
  Assert.equal(v7.schema, GameSave.LEGACY_V7_SCHEMA, "v6 reconciliation remains an explicit intermediate step")
  local current = GameSave.migrateV7(v7)
  Assert.equal(current.schema, GameSave.SCHEMA)
  Assert.equal(current.playerData.profile.nationalDex, false)
  Assert.deepEqual(current.mart, MartSave.empty())
end

function T.malformed_nested_economy_is_not_repaired_by_normalization()
  local malformed = GameSave.migrateV6(GameSave.migrateV5(v5record()))
  malformed.mart.dailyPurchasedMask = 4096
  -- The envelope boundary trusts nested state: the tampered record
  -- normalizes untouched, and the mart owner still rejects it locally.
  local normalized = assert(GameSave.normalize(malformed))
  Assert.equal(normalized.schema, GameSave.SCHEMA)
  Assert.equal(normalized.mart.dailyPurchasedMask, 4096)
  local canonical, err = MartSave.validate(malformed.mart, { cards = {}, apricorns = {}, seals = {} })
  Assert.isNil(canonical)
  Assert.isTrue(Errors.is(err))
  Assert.equal(malformed.mart.dailyPurchasedMask, 4096)
end

function T.future_schemas_reject_while_known_envelopes_stay_listable()
  returnsCode("GAME_SAVE_SCHEMA_UNSUPPORTED", function()
    local value = currentRecord()
    value.schema = "g4-game-save-v9"
    return GameSave.normalize(value)
  end)
  local envelope, envelopeErr = GameSave.metadata({
    schema = "g4-game-save-v9",
    saveId = "save-00000001",
    versionId = "heartgold",
    playTimeSeconds = 0,
    playerData = { profile = { name = "GOLD" } },
  })
  Assert.isNil(envelope)
  Assert.isTrue(Errors.is(envelopeErr))
  Assert.equal(envelopeErr.code, "GAME_SAVE_SCHEMA_UNSUPPORTED")
  local historicalV6 = assert(GameSave.metadata({
    schema = GameSave.LEGACY_V6_SCHEMA,
    saveId = "save-00000002",
    versionId = "heartgold",
    playTimeSeconds = 0,
    playerData = { profile = { name = "GOLD" } },
  }))
  Assert.equal(historicalV6.versionId, "heartgold")
  local historical = assert(GameSave.metadata({
    schema = "g4-game-save-v5",
    saveId = "save-00000001",
    versionId = "heartgold",
    playTimeSeconds = 0,
    playerData = { profile = { name = "GOLD" } },
  }))
  Assert.equal(historical.versionId, "heartgold")
end

function T.master_records_advance_with_fashion_case_and_current_mons_state()
  Assert.isTrue(
    type(GameSave.migrateV5) == "function",
    "master records advance through a dedicated migration step"
  )
  local source = v5record({ world = { flags = { [10] = true }, variables = {}, objects = {}, rng = { seed = 7 } } })
  local migrated = GameSave.migrateV5(source)
  Assert.notNil(migrated)
  Assert.equal(migrated.schema, "g4-game-save-v6")
  Assert.deepEqual(migrated.fashionCase, FashionCaseState.empty())
  Assert.equal(migrated.playerData.profile.nationalDex, false)
  Assert.deepEqual(migrated.mart, MartSave.empty())
  Assert.deepEqual(migrated.world, source.world)
  Assert.equal(migrated.mons.schema, "g4-mons-save-v3")
  Assert.deepEqual(migrated.bag, source.bag)
  -- The source stays a master record: same schema, no fashion-case state.
  Assert.equal(source.schema, "g4-game-save-v5")
  Assert.isNil(source.fashionCase)
  -- A record already carrying fashion-case state is not a legitimate
  -- master input: migration rejects it instead of blessing it as current.
  local inconsistent = v5record()
  inconsistent.fashionCase = FashionCaseState.empty()
  local err = Assert.throws(function()
    GameSave.migrateV5(inconsistent)
  end)


  Assert.isTrue(Errors.is(err))
  Assert.notNil(inconsistent.fashionCase, "rejection leaves the inconsistent source untouched")
end

function T.migrate_v6_reconciles_the_two_published_bucket_groups()
  Assert.isTrue(type(GameSave.migrateV6) == "function", "v6 has an explicit reconciliation step")
  local master = GameSave.migrateV5(v5record())
  master.schema = "g4-game-save-v6"
  master.mailbox = nil
  master.photoAlbum = nil
  master.fashionCase.counts[1] = 1
  local masterFashionCase = GameSave.migrateV6(master)
  Assert.equal(masterFashionCase.schema, GameSave.LEGACY_V7_SCHEMA)
  Assert.deepEqual(masterFashionCase.fashionCase, master.fashionCase)
  Assert.deepEqual(masterFashionCase.mailbox, Mailbox.new():capture())
  Assert.deepEqual(masterFashionCase.photoAlbum, PhotoAlbum.new():capture())
  Assert.equal(master.schema, "g4-game-save-v6")
  Assert.isNil(master.mailbox)
  Assert.equal(master.fashionCase.counts[1], 1)

  local pc = GameSave.migrateV6(GameSave.migrateV5(v5record()))
  pc.schema = "g4-game-save-v6"
  pc.fashionCase = nil
  local pcMailbox, pcPhotoAlbum = pc.mailbox, pc.photoAlbum
  local pcFeatures = GameSave.migrateV6(pc)
  Assert.equal(pcFeatures.schema, GameSave.LEGACY_V7_SCHEMA)
  Assert.deepEqual(pcFeatures.mailbox, pcMailbox)
  Assert.deepEqual(pcFeatures.photoAlbum, pcPhotoAlbum)
  Assert.deepEqual(pcFeatures.fashionCase, FashionCaseState.empty())
  Assert.equal(pc.schema, "g4-game-save-v6")
  Assert.isNil(pc.fashionCase)
  Assert.deepEqual(pc.mailbox, pcMailbox)
  Assert.deepEqual(pc.photoAlbum, pcPhotoAlbum)
end

function T.unrelated_extension_metadata_survives_legacy_migration_steps()
  local legacy = GameSave.migrateV5(v5record())
  legacy.modState = { marker = "kept" }
  local reconciled = GameSave.migrateV6(legacy)
  Assert.equal(reconciled.schema, GameSave.LEGACY_V7_SCHEMA)
  Assert.deepEqual(reconciled.modState, { marker = "kept" })
  Assert.deepEqual(reconciled.fashionCase, FashionCaseState.empty())

  local predecessor = GameSave.migrateV6(GameSave.migrateV5(v5record()))
  predecessor.modState = { marker = "kept" }
  local migrated = GameSave.migrateV7(predecessor)
  Assert.equal(migrated.schema, GameSave.SCHEMA)
  Assert.deepEqual(migrated.modState, { marker = "kept" })
  -- The same legacy payload normalizes end-to-end with its extension intact.
  local normalized = assert(GameSave.normalize(predecessor))
  Assert.equal(normalized.schema, GameSave.SCHEMA)
  Assert.deepEqual(normalized.modState, { marker = "kept" })
end

function T.migrate_v6_rejects_incomplete_and_mixed_bucket_groups()
  local malformed = GameSave.migrateV6(GameSave.migrateV5(v5record()))
  malformed.schema = "g4-game-save-v6"
  local cases = {
    function(_) end,
    function(value)
      value.photoAlbum = nil
    end,
    function(value)
      value.mailbox = nil
    end,
    function(value)
      value.fashionCase = nil
      value.mailbox = nil
      value.photoAlbum = nil
    end,
  }
  for _, damage in ipairs(cases) do
    local candidate = {}
    for key, value in pairs(malformed) do
      candidate[key] = value
    end
    damage(candidate)
    local err = Assert.throws(function()
      GameSave.migrateV6(candidate)
    end)
    Assert.isTrue(Errors.is(err))
    Assert.equal(candidate.schema, "g4-game-save-v6")
  end
  local extended = GameSave.migrateV5(v5record())
  extended.unrecognized = true
  local reconciled = GameSave.migrateV6(extended)
  Assert.equal(reconciled.schema, GameSave.LEGACY_V7_SCHEMA)
  Assert.isTrue(reconciled.unrecognized, "unrelated top-level state survives migration")
end

function T.migrate_v7_advances_nested_buckets_and_drops_fingerprints_without_a_quiescence_gate()
  local S = require("gen4.script")
  local Registry = require("libs.script.src.Registry")
  local Composition = require("libs.script.src.Composition")
  local TaskRegistry = require("libs.script.src.TaskRegistry")
  local Scheduler = require("libs.script.src.Scheduler")
  local ScriptSave = require("libs.script.src.ScriptSave")
  local WaitTicksTask = require("libs.script.src.tasks.WaitTicksTask")
  local FakeServices = require("tests.support.script.FakeServices")
  local services = FakeServices.new()
  local registry = Registry.new()
  local composition = Composition.new(registry)
  local taskRegistry = TaskRegistry.new()
  taskRegistry:register("wait_ticks", 1, WaitTicksTask)
  local scheduler = Scheduler.new({
    semantics = require("libs.hgss.src.script.RuntimeValues"),
    services = services,
    taskRegistry = taskRegistry,
    resolveComposition = function(id)
      return composition:effective(id)
    end,
  })
  local resource = S.script({
    api = 1,
    id = "test.migrate_live",
    steps = {
      S.waitTicks({ ticks = 5 }),
      S.setVar({ variable = "VAR_MIGRATED", value = 1 }),
      S.stop(),
    },
  })
  registry:installBase(resource.id, resource, "generated")
  scheduler:createForeground(assert(composition:effective(resource.id)), nil, 100)
  scheduler:step(100, nil)
  local live = ScriptSave.capture(scheduler, 100)
  Assert.isTrue(#live.tasks >= 1, "the v7 fixture carries a live continuation")
  local predecessor = {}
  for key, value in pairs(live) do
    predecessor[key] = value
  end
  predecessor.schema = "g4-script-save-v1"
  predecessor.registryFingerprint = "stale-registry"
  predecessor.taskFingerprint = "stale-tasks"

  local Lcrng = require("libs.mons.src.gen4.Lcrng")
  local Party = require("libs.mons.src.Party")
  local Boxes = require("libs.mons.src.Boxes")
  local v7 = v5record({
    world = { flags = { [10] = true }, variables = {}, objects = {}, rng = { seed = 7 } },
  })
  v7.schema = GameSave.LEGACY_V7_SCHEMA
  v7.fashionCase = FashionCaseState.empty()
  v7.mailbox = Mailbox.new():capture()
  v7.photoAlbum = PhotoAlbum.new():capture()
  v7.mons = {
    schema = "g4-mons-save-v2",
    catalogFingerprint = "stale-catalog",
    rng = Lcrng.new(0x22222222):capture(),
    party = Party.new():capture(),
    boxes = Boxes.new():capture(),
  }
  v7.scripts = predecessor

  local migrated = GameSave.migrateV7(v7)
  Assert.equal(migrated.schema, GameSave.SCHEMA)
  Assert.equal(migrated.mons.schema, "g4-mons-save-v3")
  Assert.isNil(migrated.mons.catalogFingerprint)
  Assert.equal(migrated.scripts.schema, "g4-script-save-v2")
  Assert.isNil(migrated.scripts.registryFingerprint)
  Assert.isNil(migrated.scripts.taskFingerprint)
  Assert.deepEqual(migrated.scripts.tasks, live.tasks, "the live continuation tasks survive migration exactly")
  Assert.deepEqual(migrated.scripts.instances, live.instances)
  Assert.deepEqual(migrated.world, v7.world, "unrelated top-level state is preserved")
  Assert.deepEqual(migrated.bag, v7.bag)
  Assert.equal(v7.schema, GameSave.LEGACY_V7_SCHEMA, "migration leaves its input untouched")

  -- The normalization boundary performs the same migration automatically,
  -- and the migrated continuation restores concretely without any
  -- quiescent rebinding step.
  local normalized = assert(GameSave.normalize(v7))
  Assert.equal(normalized.schema, GameSave.SCHEMA)
  local resumed = Scheduler.new({
    semantics = require("libs.hgss.src.script.RuntimeValues"),
    services = services,
    taskRegistry = taskRegistry,
    resolveComposition = function(id)
      return composition:effective(id)
    end,
  })
  ScriptSave.restore(normalized.scripts, resumed, 0)
  for tick = 1, 8 do
    resumed:step(tick, nil)
  end
  Assert.equal(services.world:getVar("VAR_MIGRATED"), 1, "the migrated continuation runs to completion")
end

function T.version_advancement_keeps_each_historical_meaning()
  local v4 = GameSave.migrateV3(v3record())
  Assert.equal(v4.schema, "g4-game-save-v4")
  local v5 = GameSave.migrateV4(v4)
  Assert.equal(v5.schema, "g4-game-save-v5")
  Assert.equal(v5.playerData.profile.nationalDex, false)
  Assert.deepEqual(v5.mart, MartSave.empty())
  Assert.isNil(v5.fashionCase, "the master advancement carries no fashion-case state")
  Assert.equal(v4.schema, "g4-game-save-v4")
  Assert.isNil(v4.playerData.profile.nationalDex)
  Assert.isNil(v4.mart)
end

return { tests = T }
