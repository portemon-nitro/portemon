-- Catalog compatibility: the mons owner rejects a bucket written against
-- different generated content with a structured error before any live
-- service is published, leaving the last valid record untouched. Store
-- loading itself stays at the envelope: only the restoring domain proof
-- reads the bucket.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local Errors = require("libs.errors.src.Errors")
local BagSave = require("libs.hgss.src.save.BagSave")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")

local T = {}

local function record(mons)
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
    mons = mons,
    bag = BagSave.empty(),
  }
  return value
end

function T.stale_catalog_fingerprint_blocks_continue_without_publication()
  local catalog = CatalogFixture.makeCatalog()
  local stale = MonsSave.capture(Party.new():capture(), Lcrng.new(0x99999999):capture(), "stale-catalog-fingerprint")
  local candidate = record(stale)
  local snapshot = {
    schema = candidate.schema,
    catalogFingerprint = stale.catalogFingerprint,
    rngState = stale.rng.state,
  }
  local ok, blockError = pcall(MonsSave.validate, candidate.mons, CatalogFixture.domainContext(catalog))
  Assert.isFalse(ok, "the mismatched bucket never becomes a live service")
  blockError = assert(blockError, "the block uses the structured save-error path")
  Assert.isTrue(Errors.is(blockError), "the block uses the structured save-error path")
  Assert.equal(blockError.code, "MONS_SAVE_FINGERPRINT_MISMATCH", "the mons bucket owns the incompatibility")
  Assert.equal(candidate.schema, snapshot.schema, "the rejected record is left untouched")
  Assert.equal(
    candidate.mons.catalogFingerprint,
    snapshot.catalogFingerprint,
    "the rejected bucket keeps its fingerprint"
  )
  Assert.equal(candidate.mons.rng.state, snapshot.rngState, "the rejected generator state is unchanged")
  Assert.isTrue(
    MonsSave.validate(
      MonsSave.capture(Party.new():capture(), Lcrng.new(7):capture(), catalog:fingerprint()),
      CatalogFixture.domainContext(catalog)
    ),
    "the current catalog still validates fresh buckets"
  )
end

return { tests = T }
