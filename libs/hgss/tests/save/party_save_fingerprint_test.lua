-- Catalog trust: the mons owner neither persists nor compares an aggregate
-- catalog fingerprint. Current captures omit the field entirely; a v2
-- predecessor bucket whose fingerprint disagrees with the current catalog
-- migrates through the outer save boundary into the fingerprint-free v3
-- shape and restores without a compatibility gate. Store loading itself
-- stays at the envelope: only the restoring domain proof reads the bucket.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local BagSave = require("libs.hgss.src.save.BagSave")
local Boxes = require("libs.mons.src.Boxes")
local GameSave = require("libs.hgss.src.save.GameSave")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")

local T = {}

local function staleV2Mons()
  return {
    schema = "g4-mons-save-v2",
    catalogFingerprint = "stale-catalog-fingerprint",
    rng = Lcrng.new(0x99999999):capture(),
    party = Party.new():capture(),
    boxes = Boxes.new():capture(),
  }
end

local function quiescentV1Scripts()
  return {
    schema = "g4-script-save-v1",
    registryFingerprint = "stale-registry-fingerprint",
    taskFingerprint = "stale-task-fingerprint",
    capturedAtSimulationTick = 0,
    nextEnvironmentId = 0,
    nextInstanceId = 0,
    nextTaskId = 0,
    environments = {},
    instances = {},
    tasks = {},
  }
end

local function v7record(mons, scripts)
  return {
    schema = "g4-game-save-v7",
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
    scripts = scripts,
    auxiliaryUi = { requested = "shown", state = "shown" },
    audio = {},
    mons = mons,
    bag = BagSave.empty(),
  }
end

function T.mismatched_v2_fingerprint_migrates_and_restores_without_a_gate()
  local catalog = CatalogFixture.makeCatalog()
  local candidate = v7record(staleV2Mons(), quiescentV1Scripts())
  local normalized = assert(GameSave.normalize(candidate))
  Assert.equal(normalized.schema, "g4-game-save-v9", "the predecessor advances to the current outer schema")
  Assert.equal(normalized.mons.schema, "g4-mons-save-v3", "the nested mons bucket advances to its current schema")
  Assert.isNil(normalized.mons.catalogFingerprint, "migration drops the obsolete fingerprint field")
  Assert.equal(normalized.scripts.schema, "g4-script-save-v2", "the nested scripts bucket advances as well")
  Assert.equal(
    candidate.mons.catalogFingerprint,
    "stale-catalog-fingerprint",
    "migration leaves the predecessor input untouched"
  )
  local restored = MonsSave.restore(normalized.mons, CatalogFixture.domainContext(catalog))
  Assert.equal(restored.party:count(), 0, "the migrated empty party restores under the current catalog")
  Assert.deepEqual(restored.rng:capture(), Lcrng.new(0x99999999):capture(), "the generator state survives migration")
  Assert.isTrue(
    MonsSave.validate(
      MonsSave.capture(Party.new():capture(), Lcrng.new(7):capture()),
      CatalogFixture.domainContext(catalog)
    ),
    "current captures omit the fingerprint field and still validate"
  )
end

return { tests = T }
