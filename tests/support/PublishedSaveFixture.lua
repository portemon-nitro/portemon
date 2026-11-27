-- Current-schema published save fixture for isolated real SaveFs/GameSaveStore
-- composition. It carries no generated assets or user data.

local GameSave = require("libs.hgss.src.save.GameSave")

local Fixture = {}

---@param saveId string
---@param versionId string
---@return table<string, unknown>
function Fixture.new(saveId, versionId)
  return {
    schema = GameSave.SCHEMA,
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
    playerData = {
      profile = {
        name = versionId == "heartgold" and "GOLD" or "SILVER",
        gender = 0,
        trainerId = 0,
        money = 3000,
        badges = {},
        nationalDex = false,
        runningShoes = false,
        runningShoesLock = false,
        rivalName = "Silver",
      },
      options = { textFrame = 0, textSpeed = "mid" },
    },
    fieldTravel = { lastHealSpawn = "SPAWN_NEW_BARK" },
    world = { flags = {}, variables = {}, objects = {}, rng = { state = 1, calls = 0 } },
    scripts = {},
    bag = require("libs.hgss.src.save.BagSave").empty(),
    fashionCase = require("libs.hgss.src.save.FashionCaseState").empty(),
    mart = require("libs.hgss.src.save.MartSave").empty(),
    mailbox = require("libs.hgss.src.save.Mailbox").new():capture(),
    photoAlbum = require("libs.hgss.src.save.PhotoAlbum").new():capture(),
    encounters = require("libs.hgss.src.save.EncounterSave").initial(),
    pokedex = require("libs.hgss.src.save.PokedexSave").initial(),
    mons = require("libs.mons.src.MonsSave").empty(7),
    auxiliaryUi = { requested = "shown", state = "shown" },
    audio = {},
  }
end

return Fixture
