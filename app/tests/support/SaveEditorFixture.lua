-- Builds complete canonical saves for save editor transaction tests. Domain
-- validation and publication stay real; only the filesystem backend is local.

local FakeCache = require("tests.support.FakeCache")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local GameSave = require("libs.hgss.src.save.GameSave")
local GameSaveStore = require("libs.hgss.src.save.GameSaveStore")
local BagSave = require("libs.hgss.src.save.BagSave")
local MonsSave = require("libs.mons.src.MonsSave")
local SaveFs = require("libs.storage.src.SaveFs")
local ScriptSave = require("libs.script.src.ScriptSave")

local M = {}

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, item in pairs(value) do
    result[key] = copy(item)
  end
  return result
end

local function validationContext()
  local itemCatalog = CatalogFixture.makeItemCatalog()
  return {
    charmap = CatalogFixture.CHARMAP,
    language = "english",
    frameIndexes = { [0] = true, [1] = true, [2] = true },
    monCatalog = CatalogFixture.makeCatalog(),
    itemCatalog = itemCatalog,
  }
end

local function record(saveId)
  return {
    schema = GameSave.SCHEMA,
    saveId = saveId,
    versionId = "heartgold",
    playTimeSeconds = 91,
    mapId = 60,
    fieldX = 684,
    fieldZ = 393,
    worldY = 0,
    surfaceId = 0,
    terrainDependencyHash = "terrain-heartgold",
    facing = "south",
    fieldTravel = { lastHealSpawn = "SPAWN_NEW_BARK" },
    playerData = {
      profile = {
        name = "GOLD",
        gender = 0,
        trainerId = 1234,
        money = 3000,
        badges = 5,
        nationalDex = false,
        runningShoes = false,
        runningShoesLock = false,
      },
      options = { textFrame = 1, textSpeed = "fast" },
    },
    world = {
      flags = { [817] = true, [50000] = true },
      variables = { [4] = 0, [7] = 19 },
      objects = {
        schema = "g4-field-objects-v1",
        rng = { state = 17, calls = 3 },
        actors = {
          ["map:60:object:7"] = {
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
            controller = { kind = "pattern", timer = 2, sequenceIndex = 1 },
          },
        },
      },
      rng = { state = 912, calls = 47 },
    },
    scripts = {
      schema = ScriptSave.SCHEMA_NAME,
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
    mons = MonsSave.empty(7),
    bag = BagSave.empty(),
    fashionCase = require("libs.hgss.src.save.FashionCaseState").empty(),
    mart = require("libs.hgss.src.save.MartSave").empty(),
    mailbox = require("libs.hgss.src.save.Mailbox").new():capture(),
    photoAlbum = require("libs.hgss.src.save.PhotoAlbum").new():capture(),
    avatar = { state = "cycling" },
    weatherId = 2,
  }
end

function M.new(options)
  options = options or {}
  local backend = options.backend or FakeCache.new()
  local context = validationContext()
  local store = GameSaveStore.new(SaveFs.global(backend))
  local saveId = store:reserve()
  local initial = record(saveId)
  store:publishFirst(initial)
  local canonical = assert(store:load(saveId))
  return {
    backend = backend,
    context = context,
    initial = canonical,
    saveFs = SaveFs.global(backend),
    saveId = saveId,
    store = store,
    symbols = options.symbols or FieldScriptSymbols,
    validateRecord = function(candidate)
      return GameSave.normalize(candidate)
    end,
    copy = copy,
  }
end

return M
