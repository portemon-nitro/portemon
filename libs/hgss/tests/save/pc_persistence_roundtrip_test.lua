-- Existing save migration preserves Pokemon and random-generator state.

local Assert = require("tests.support.Assert")
local GameSave = require("libs.hgss.src.save.GameSave")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")

local T = {}

function T.v4_migration_adds_pc_state_without_changing_existing_values()
  local catalog = CatalogFixture.makeCatalog()
  local args = CatalogFixture.factoryArgs(0x12345678, catalog)
  local MonFactory = require("libs.mons.src.gen4.MonFactory")
  local mon = MonFactory.new(args):createNormal(CatalogFixture.normalRequest({ species = "CHIKORITA", level = 5 }))
  mon.nickname = "LEAF"
  mon.markings = 5
  mon.condition.currentHp = mon.condition.currentHp - 1
  mon.capsule = { id = 0, seals = {} }
  local party = Party.new()
  party:add(mon)
  local originalMons = MonsSave.capture(party:capture(), args.rng:capture())
  originalMons.schema = MonsSave.LEGACY_SCHEMA
  originalMons.catalogFingerprint = "legacy-catalog"
  originalMons.boxes = nil
  originalMons.party.mons[1].schema = require("libs.mons.src.Mon").LEGACY_SCHEMA
  -- A genuine v1 record carries the opaque native status word, not the
  -- semantic effect list: project the healthy condition back to zero.
  originalMons.party.mons[1].condition =
    { status = 0, currentHp = originalMons.party.mons[1].condition.currentHp }
  local v4 = {
    schema = "g4-game-save-v4",
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
      profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000, badges = 3 },
      options = { textFrame = 0, textSpeed = "mid" },
    },
    fieldTravel = { lastHealSpawn = "SPAWN_NEW_BARK" },
    world = { flags = { FLAG = true }, variables = { VARIABLE = 7 }, objects = {}, rng = { state = 19, calls = 8 } },
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
    mons = originalMons,
    bag = { schema = "g4-bag-v1", pockets = {} },
  }
  local v5 = GameSave.migrateV4(v4)
  Assert.isTrue(type(GameSave.migrateV5) == "function", "save migration must add the new persisted PC owners")
  local v6 = GameSave.migrateV6(GameSave.migrateV5(v5))
  Assert.equal(v6.schema, GameSave.LEGACY_V7_SCHEMA)
  local migrated = GameSave.migrateV7(v6)

  Assert.equal(v4.schema, "g4-game-save-v4", "migration does not mutate the input")
  Assert.equal(v4.mons.schema, originalMons.schema)
  Assert.equal(migrated.schema, GameSave.SCHEMA)
  Assert.deepEqual(migrated.world, v4.world)
  Assert.equal(migrated.scripts.schema, "g4-script-save-v2")
  Assert.deepEqual(migrated.scripts.tasks, v4.scripts.tasks)
  Assert.isNil(migrated.scripts.registryFingerprint)
  Assert.deepEqual(migrated.mons.rng, originalMons.rng)
  Assert.deepEqual(migrated.mons.party.mons[1], mon, "party health, nickname, markings and capsule survive")
  Assert.isNil(migrated.mons.catalogFingerprint, "migration drops the obsolete fingerprint")
  Assert.notNil(migrated.mailbox)
  Assert.notNil(migrated.photoAlbum)
end

return { tests = T }
