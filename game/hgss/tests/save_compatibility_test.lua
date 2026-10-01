-- Whole-save compatibility: unrelated content edits keep compatible
-- references loading through the real validation boundary, while removed
-- references, out-of-range state, and malformed records keep rejecting with
-- failures that name their bucket and referenced key.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local ItemFixture = require("libs.items.tests.item_fixture")
local ItemCatalog = require("libs.items.src.ItemCatalog")
local MonCatalog = require("libs.mons.src.MonCatalog")
local GameSaveValidation = require("game.hgss.src.save.GameSaveValidation")
local EncounterSave = require("libs.hgss.src.save.EncounterSave")
local PokedexSave = require("libs.hgss.src.save.PokedexSave")
local BagSave = require("libs.hgss.src.save.BagSave")
local MonsSave = require("libs.mons.src.MonsSave")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local CompatibilityFixture = require("tests.support.script.CompatibilityFixture")

local T = {}

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[key] = copy(item)
  end
  return out
end

local function stockedBag()
  local bag = BagSave.empty()
  bag.pockets.balls = { { item = "POKE_BALL", quantity = 3 } }
  bag.pockets.medicine = { { item = "POTION", quantity = 1 } }
  bag.registered = { "BICYCLE" }
  return bag
end

local function partyBucket(monCatalog)
  local factory = CatalogFixture.makeFactory(0x12345678, monCatalog)
  local mon = factory:createNormal(CatalogFixture.normalRequest())
  return MonsSave.capture({ max = 6, mons = { mon } }, Lcrng.new(0x99999999):capture(), monCatalog:fingerprint())
end

local function quietScripts(setup)
  return {
    schema = "g4-script-save-v1",
    registryFingerprint = setup.registry:fingerprint(),
    taskFingerprint = setup.tasks:fingerprint(),
    capturedAtSimulationTick = 0,
    nextEnvironmentId = 0,
    nextInstanceId = 0,
    nextTaskId = 0,
    environments = {},
    instances = {},
    tasks = {},
  }
end

local function baseRecord(saveId, scripts)
  local monCatalog = CatalogFixture.makeCatalog()
  return {
    schema = "g4-game-save-v5",
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
      profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000, badges = 0 },
      options = { textFrame = 0, textSpeed = "mid" },
    },
    fieldTravel = { lastHealSpawn = "SPAWN_NEW_BARK" },
    world = { flags = { [10] = true }, variables = {}, objects = {}, rng = { state = 1, calls = 0 } },
    scripts = scripts,
    auxiliaryUi = { requested = "shown", state = "shown" },
    audio = { fieldMusicOverride = 7 },
    mons = partyBucket(monCatalog),
    bag = stockedBag(),
    encounters = EncounterSave.initial(),
    pokedex = PokedexSave.initial(),
  }
end

local function contextWith(setup, monCatalog, itemCatalog, audioIds)
  return {
    charmap = CatalogFixture.CHARMAP,
    frameIndexes = { [0] = true },
    audioSequenceIds = audioIds or { [7] = true },
    monCatalog = monCatalog or CatalogFixture.makeCatalog(),
    itemCatalog = itemCatalog or ItemFixture.makeCatalog(),
    scriptCompatibility = {
      validationOptions = function()
        return CompatibilityFixture.optionsFor(setup)
      end,
    },
  }
end

local function serviceFor(cell)
  return GameSaveValidation.new({
    contextLoader = function()
      return cell.current
    end,
  })
end

-- Whether a whole-save failure names its bucket and referenced key, however
-- the cause chain phrases it: the top-level message or context carries it.
local function mentions(haystack, needle, seen)
  if type(haystack) == "string" then
    return haystack:find(needle, 1, true) ~= nil
  end
  if type(haystack) == "number" then
    return tostring(haystack):find(needle, 1, true) ~= nil
  end
  if type(haystack) ~= "table" then
    return false
  end
  seen = seen or {}
  if seen[haystack] then
    return false
  end
  seen[haystack] = true
  for key, value in pairs(haystack) do
    if mentions(key, needle, seen) or mentions(value, needle, seen) then
      return true
    end
  end
  return false
end

local function failureNamesKey(err, bucket, needle)
  if not Errors.is(err) then
    return false
  end
  if err.code ~= "GAME_SAVE_BUCKET_INVALID" then
    return false
  end
  if type(err.context) ~= "table" or err.context.bucket ~= bucket then
    return false
  end
  return mentions(err.message, needle) or mentions(err.context, needle)
end

function T.compatible_references_survive_unrelated_edits_in_every_bucket()
  local setup = CompatibilityFixture.rig()
  -- Move text changes without touching any referenced key.
  local editedRoot = CatalogFixture.buildAssetRoot()
  editedRoot.moves.TACKLE.description = "Charges fiercely at the foe."
  local editedMonCatalog = MonCatalog.new(editedRoot, ItemFixture.makeCatalog())
  Assert.isTrue(
    editedMonCatalog:fingerprint() ~= CatalogFixture.makeCatalog():fingerprint(),
    "the text edit must move the catalog fingerprint"
  )
  -- An unused custom item joins the catalog the bag validates against.
  local extendedItemRoot = ItemFixture.buildAssetRoot()
  extendedItemRoot.items["ember:EMBER_CHARM"] = {
    name = "Ember Charm",
    nameIndefinite = "an Ember Charm",
    namePlural = "Ember Charms",
    description = "A charm holding leftover warmth.",
    pocket = "items",
    preventToss = false,
    selectable = false,
    isBall = false,
    friendshipBoost = false,
    icon = "ember:EMBER_CHARM",
    isHm = false,
    canHold = true,
    heldFormEffect = "none",
    partyUse = { kind = "none" },
  }
  local extendedItemCatalog = ItemCatalog.fromResolved(extendedItemRoot)
  local candidate = baseRecord("save-00000021", quietScripts(setup))
  candidate.world.flags[11] = true
  local service = serviceFor({
    current = contextWith(setup, editedMonCatalog, extendedItemCatalog, { [7] = true, [8] = true, [9] = true }),
  })
  local valid = assert(service:validate(candidate))
  Assert.equal(valid.saveId, "save-00000021")
  Assert.equal(valid.mons.party.mons[1].species, "CHIKORITA")
  Assert.equal(valid.bag.pockets.balls[1].item, "POKE_BALL")
  Assert.equal(valid.audio.fieldMusicOverride, 7)
  Assert.isTrue(valid.world.flags[11], "the unrelated world flag survives the load")
end

function T.grown_script_registries_do_not_invalidate_paused_saves()
  local setup = CompatibilityFixture.rig()
  local bucket = CompatibilityFixture.pausedBucket(setup)
  CompatibilityFixture.growWithUnused(setup)
  Assert.isTrue(
    setup.registry:fingerprint() ~= bucket.registryFingerprint,
    "the unused script must move the registry fingerprint"
  )
  Assert.isTrue(
    setup.tasks:fingerprint() ~= bucket.taskFingerprint,
    "the unused task must move the task fingerprint"
  )
  local candidate = baseRecord("save-00000022", bucket)
  local service = serviceFor({ current = contextWith(setup) })
  local valid = service:validate(candidate)
  Assert.notNil(valid, "a paused save must survive unrelated registry growth")
  Assert.equal(valid.saveId, "save-00000022")
  Assert.equal(#valid.scripts.instances, 1, "the paused script instance survives the load")
  Assert.equal(#valid.scripts.tasks, 1, "the waiting task survives the load")
end

function T.corrupt_saves_still_reject()
  local setup = CompatibilityFixture.rig()
  local broken = CompatibilityFixture.pausedBucket(setup)
  broken.tasks[1].ownerInstanceId = "ghost-owner"
  local candidate = baseRecord("save-00000023", broken)
  local service = serviceFor({ current = contextWith(setup) })
  local invalid, err = service:validate(candidate)
  Assert.isNil(invalid, "a script bucket with a dangling task owner must not load")
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, "GAME_SAVE_BUCKET_INVALID")
  Assert.equal(err.context.bucket, "scripts")
  Assert.equal(
    candidate.scripts.tasks[1].ownerInstanceId,
    "ghost-owner",
    "the rejected record is left untouched"
  )

  local setupBag = CompatibilityFixture.rig()
  local badBag = baseRecord("save-00000024", quietScripts(setupBag))
  badBag.bag.pockets.balls = { { item = "NOPE_BALL", quantity = 1 } }
  local bagService = serviceFor({ current = contextWith(setupBag) })
  invalid, err = bagService:validate(badBag)
  Assert.isNil(invalid, "a bag naming an unknown item must not load")
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, "GAME_SAVE_BUCKET_INVALID")
  Assert.equal(err.context.bucket, "bag")
  Assert.equal(badBag.bag.pockets.balls[1].item, "NOPE_BALL", "the rejected record is left untouched")
end

function T.removed_item_rejects_naming_its_key()
  local setup = CompatibilityFixture.rig()
  local candidate = baseRecord("save-00000031", quietScripts(setup))
  candidate.bag.pockets.balls = { { item = "NOPE_BALL", quantity = 1 } }
  local service = serviceFor({ current = contextWith(setup) })
  local invalid, err = service:validate(candidate)
  Assert.isNil(invalid, "a bag naming a removed item must not load")
  Assert.isTrue(failureNamesKey(err, "bag", "NOPE_BALL"), "the failure must name the removed item")
  Assert.equal(candidate.bag.pockets.balls[1].item, "NOPE_BALL", "the rejected record is left untouched")
end

function T.removed_audio_override_rejects_naming_its_key()
  local setup = CompatibilityFixture.rig()
  local candidate = baseRecord("save-00000032", quietScripts(setup))
  candidate.audio = { fieldMusicOverride = 99 }
  local service = serviceFor({ current = contextWith(setup) })
  local invalid, err = service:validate(candidate)
  Assert.isNil(invalid, "an audio bucket naming a removed override must not load")
  Assert.isTrue(failureNamesKey(err, "audio", "99"), "the failure must name the removed override")
  Assert.equal(candidate.audio.fieldMusicOverride, 99, "the rejected record is left untouched")
end

function T.removed_text_frame_rejects_naming_its_key()
  local setup = CompatibilityFixture.rig()
  local candidate = baseRecord("save-00000033", quietScripts(setup))
  candidate.playerData.options.textFrame = 99
  local service = serviceFor({ current = contextWith(setup) })
  local invalid, err = service:validate(candidate)
  Assert.isNil(invalid, "player data naming a removed text frame must not load")
  Assert.isTrue(failureNamesKey(err, "playerData", "99"), "the failure must name the removed frame")
  Assert.equal(candidate.playerData.options.textFrame, 99, "the rejected record is left untouched")
end

function T.removed_mon_form_rejects_naming_its_key()
  local setup = CompatibilityFixture.rig()
  local candidate = baseRecord("save-00000034", quietScripts(setup))
  candidate.mons.party.mons[1].form = 7
  local service = serviceFor({ current = contextWith(setup) })
  local invalid, err = service:validate(candidate)
  Assert.isNil(invalid, "a mon naming a removed form must not load")
  Assert.isTrue(failureNamesKey(err, "mons", "7"), "the failure must name the removed form")
  Assert.equal(candidate.mons.party.mons[1].form, 7, "the rejected record is left untouched")
end

function T.over_max_health_rejects_naming_its_value()
  local setup = CompatibilityFixture.rig()
  local candidate = baseRecord("save-00000035", quietScripts(setup))
  candidate.mons.party.mons[1].condition.currentHp = 99991
  local service = serviceFor({ current = contextWith(setup) })
  local invalid, err = service:validate(candidate)
  Assert.isNil(invalid, "a mon above its valid health maximum must not load")
  Assert.isTrue(failureNamesKey(err, "mons", "99991"), "the failure must name the offending value")
  Assert.equal(
    candidate.mons.party.mons[1].condition.currentHp,
    99991,
    "the rejected record is left untouched"
  )
end

function T.over_max_power_points_rejects_naming_its_value()
  local setup = CompatibilityFixture.rig()
  local candidate = baseRecord("save-00000036", quietScripts(setup))
  candidate.mons.party.mons[1].moves[1].pp = 999
  local service = serviceFor({ current = contextWith(setup) })
  local invalid, err = service:validate(candidate)
  Assert.isNil(invalid, "a move above its valid power-point maximum must not load")
  Assert.isTrue(failureNamesKey(err, "mons", "999"), "the failure must name the offending value")
  Assert.equal(candidate.mons.party.mons[1].moves[1].pp, 999, "the rejected record is left untouched")
end

function T.malformed_bag_quantity_rejects_naming_its_value()
  local setup = CompatibilityFixture.rig()
  local candidate = baseRecord("save-00000037", quietScripts(setup))
  candidate.bag.pockets.balls = { { item = "POKE_BALL", quantity = 1500 } }
  local service = serviceFor({ current = contextWith(setup) })
  local invalid, err = service:validate(candidate)
  Assert.isNil(invalid, "a bag stack outside its valid quantity range must not load")
  Assert.isTrue(failureNamesKey(err, "bag", "1500"), "the failure must name the offending value")
  Assert.equal(candidate.bag.pockets.balls[1].quantity, 1500, "the rejected record is left untouched")
end

function T.changed_terrain_hash_keeps_geometry_intact()
  local setup = CompatibilityFixture.rig()
  local candidate = baseRecord("save-00000041", quietScripts(setup))
  candidate.terrainDependencyHash = "rebuilt-terrain-hash"
  local service = serviceFor({ current = contextWith(setup) })
  local valid = assert(service:validate(candidate))
  Assert.equal(valid.mapId, 60)
  Assert.equal(valid.fieldX, 684)
  Assert.equal(valid.fieldZ, 393)
  Assert.equal(valid.worldY, 0)
  Assert.equal(valid.surfaceId, 0)
  Assert.equal(valid.terrainDependencyHash, "rebuilt-terrain-hash")
end

function T.validation_adds_no_surface_gate()
  -- Surface existence is the runtime rebind's gate, not validation's: the
  -- field loader rebinds to the closest surface at the saved coordinates
  -- and fails only when no surface exists there. Validation must not
  -- invent a stricter hash or surface check of its own.
  local setup = CompatibilityFixture.rig()
  local candidate = baseRecord("save-00000042", quietScripts(setup))
  candidate.terrainDependencyHash = "rebuilt-terrain-hash"
  candidate.surfaceId = 9999
  candidate.worldY = -100.5
  local service = serviceFor({ current = contextWith(setup) })
  local valid = assert(service:validate(candidate))
  Assert.equal(valid.surfaceId, 9999)
  Assert.equal(valid.worldY, -100.5)
  Assert.equal(valid.terrainDependencyHash, "rebuilt-terrain-hash")
end

function T.failed_saves_never_touch_the_last_published_save()
  local GameSaveStore = require("libs.hgss.src.save.GameSaveStore")
  local SaveFs = require("libs.storage.src.SaveFs")
  local FakeCache = require("tests.support.FakeCache")
  local backend = FakeCache.new()
  local setup = CompatibilityFixture.rig()
  local service = serviceFor({ current = contextWith(setup) })
  local store = GameSaveStore.new(SaveFs.global(backend), {
    recordValidate = function(record)
      return service:validate(record)
    end,
  })
  local saveId = store:reserve()
  local candidate = baseRecord(saveId, quietScripts(setup))
  store:publishFirst(candidate)
  local payloadPath = "saves/games/" .. saveId .. ".lua"
  local publishedPayload = backend.files[payloadPath]
  local publishedCatalog = backend.files["saves/catalog.lua"]
  Assert.notNil(publishedPayload, "the published payload must reach the save root")
  local before = assert(store:load(saveId))
  local broken = baseRecord(saveId, quietScripts(setup))
  broken.bag.pockets.balls = { { item = "NOPE_BALL", quantity = 1 } }
  local ok, failure = pcall(function()
    return store:save(broken)
  end)
  Assert.isFalse(ok, "the invalid record must not save")
  Assert.isTrue(Errors.is(failure))
  Assert.equal(failure.code, "GAME_SAVE_BUCKET_INVALID")
  Assert.equal(
    backend.files[payloadPath],
    publishedPayload,
    "a failed save must not rewrite the last payload"
  )
  Assert.equal(
    backend.files["saves/catalog.lua"],
    publishedCatalog,
    "a failed save must not touch the catalog"
  )
  Assert.deepEqual(store:load(saveId), before, "the last save still loads unchanged")
end

function T.failed_context_rebuild_leaves_later_loads_untouched()
  local setup = CompatibilityFixture.rig()
  local attempts = 0
  local cell = { current = contextWith(setup) }
  local service = GameSaveValidation.new({
    contextLoader = function()
      attempts = attempts + 1
      if attempts == 1 then
        Errors.raise("SAVE_VERSION_CONTEXT_UNAVAILABLE", "version context is unavailable", {
          versionId = "heartgold",
        })
      end
      return cell.current
    end,
  })
  local candidate = baseRecord("save-00000043", quietScripts(setup))
  local invalid, err = service:validate(candidate)
  Assert.isNil(invalid, "the failed rebuild must not validate")
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, "SAVE_VERSION_CONTEXT_UNAVAILABLE")
  local valid = assert(service:validate(candidate))
  Assert.equal(valid.saveId, "save-00000043", "the failed rebuild must poison no cache entry")
end

function T.unknown_task_graph_rejects_naming_its_key()
  local setup = CompatibilityFixture.rig()
  local bucket = CompatibilityFixture.pausedBucket(setup)
  bucket.instances[1].frames[1].graphRevision = "stale-graph-9"
  local candidate = baseRecord("save-00000038", bucket)
  local service = serviceFor({ current = contextWith(setup) })
  local invalid, err = service:validate(candidate)
  Assert.isNil(invalid, "a script naming an unknown task graph must not load")
  Assert.isTrue(failureNamesKey(err, "scripts", "stale-graph-9"), "the failure must name the unknown graph")
  Assert.equal(
    candidate.scripts.instances[1].frames[1].graphRevision,
    "stale-graph-9",
    "the rejected record is left untouched"
  )
end

return { tests = T }
