-- Application validation for the battle-era buckets: encounter and dex
-- state validate against the runtime composition's selected references
-- (custom content resolves, removed references fail naming theirs), while
-- a context without reference sets fails closed (only empty buckets
-- validate) and malformed present buckets fail at their owning boundary.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local Errors = require("libs.errors.src.Errors")
local GameSaveValidation = require("game.hgss.src.save.GameSaveValidation")
local ItemFixture = require("libs.items.tests.item_fixture")
local BagSave = require("libs.hgss.src.save.BagSave")
local EncounterSave = require("libs.hgss.src.save.EncounterSave")
local MonsSave = require("libs.mons.src.MonsSave")
local PokedexSave = require("libs.hgss.src.save.PokedexSave")

local T = {}

local function contextWith(refs)
  return {
    charmap = { G = 1, O = 2, L = 3, D = 4 },
    frameIndexes = { [0] = true },
    audioSequenceIds = { [7] = true },
    monCatalog = CatalogFixture.makeCatalog(),
    itemCatalog = ItemFixture.makeCatalog(),
    speciesRefs = refs and refs.species or nil,
    mapRefs = refs and refs.maps or nil,
    scriptCompatibility = {
      validationOptions = function()
        return {
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

local function serviceFor(context)
  return GameSaveValidation.new({
    contextLoader = function()
      return context
    end,
  })
end

local function record(overrides)
  local value = {
    schema = "g4-game-save-v5",
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
      profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000, badges = 0 },
      options = { textFrame = 0, textSpeed = "mid" },
    },
    fieldTravel = { lastHealSpawn = "SPAWN_NEW_BARK" },
    world = { flags = {}, variables = {}, objects = {}, rng = { state = 1, calls = 0 } },
    scripts = {
      schema = "g4-script-save-v1",
      registryFingerprint = "registry",
      taskFingerprint = "tasks",
      capturedAtSimulationTick = 0,
      nextEnvironmentId = 0,
      nextInstanceId = 0,
      nextTaskId = 0,
      environments = {},
      instances = {},
      tasks = {},
    },
    auxiliaryUi = { requested = "shown", state = "shown" },
    audio = {},
    mons = MonsSave.empty(CatalogFixture.makeCatalog():fingerprint(), 7),
    bag = BagSave.empty(),
    encounters = EncounterSave.initial(),
    pokedex = PokedexSave.initial(),
  }
  for key, replacement in pairs(overrides or {}) do
    rawset(value, key, replacement)
  end
  return value
end

local function roamerBucket()
  return {
    schema = EncounterSave.SCHEMA,
    stateVersion = EncounterSave.STATE_VERSION,
    steps = 41,
    repelSteps = 0,
    swarm = false,
    radio = "none",
    roamers = {
      raikou = {
        key = "raikou",
        stateVersion = EncounterSave.STATE_VERSION,
        mon = { species = "CUSTOM_MON" },
        location = 60,
        lifecycle = "roaming",
        revision = 3,
      },
    },
  }
end

local function dexBucket()
  return {
    schema = PokedexSave.SCHEMA,
    stateVersion = PokedexSave.STATE_VERSION,
    seen = { "CUSTOM_MON" },
    caught = {},
  }
end

local CUSTOM_REFS = { species = { CHIKORITA = true, CUSTOM_MON = true }, maps = { [60] = true } }

function T.selected_custom_content_resolves_through_composition_refs()
  local service = serviceFor(contextWith(CUSTOM_REFS))
  local candidate = record({ encounters = roamerBucket(), pokedex = dexBucket() })
  local valid = assert(service:validate(candidate))
  Assert.equal(valid.encounters.roamers.raikou.location, 60)
  Assert.deepEqual(valid.pokedex.seen, { "CUSTOM_MON" })
end

function T.removed_references_fail_naming_their_bucket()
  local service = serviceFor(contextWith({ species = { CHIKORITA = true }, maps = { [60] = true } }))
  local candidate = record({ encounters = roamerBucket(), pokedex = dexBucket() })
  local invalid, err = service:validate(candidate)
  Assert.isNil(invalid)
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, "GAME_SAVE_BUCKET_INVALID")
  Assert.isTrue(err.context.bucket == "encounters" or err.context.bucket == "pokedex")
end

function T.unknown_roamer_locations_fail_closed()
  local refs = { species = { CHIKORITA = true, CUSTOM_MON = true }, maps = { [61] = true } }
  local service = serviceFor(contextWith(refs))
  local invalid, err = service:validate(record({ encounters = roamerBucket() }))
  Assert.isNil(invalid)
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, "GAME_SAVE_BUCKET_INVALID")
  Assert.equal(err.context.bucket, "encounters")
end

function T.reference_free_contexts_fail_closed_on_nonempty_buckets()
  local service = serviceFor(contextWith(nil))
  Assert.notNil(service:validate(record()), "empty buckets validate without reference sets")
  local invalid, err = service:validate(record({ pokedex = dexBucket() }))
  Assert.isNil(invalid, "a context without sets approves no selected references")
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, "GAME_SAVE_BUCKET_INVALID")
end

function T.malformed_new_buckets_fail_at_their_owning_boundary()
  local service = serviceFor(contextWith(CUSTOM_REFS))
  local broken = record()
  broken.encounters = { schema = "bogus", stateVersion = 1 }
  local invalid, err = service:validate(broken)
  Assert.isNil(invalid)
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, "GAME_SAVE_BUCKET_INVALID")
  Assert.equal(err.context.bucket, "encounters")
end

return { tests = T }
