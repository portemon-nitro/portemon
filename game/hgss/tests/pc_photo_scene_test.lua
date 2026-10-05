-- Photo requests use the production FieldMapLoader coordinate and demand
-- seam, while cancellation prevents delayed work from becoming a ready view.

local Assert = require("tests.support.Assert")
local PhotoAlbum = require("libs.hgss.src.save.PhotoAlbum")
local FieldCellCache = require("libs.assets.src.field.FieldCellCache")
local FieldMapLoader = require("libs.hgss.src.world.FieldMapLoader")
local MapAssetCache = require("libs.assets.src.MapAssetCache")

local T = {}

local function savedPhoto()
  return {
    schema = "g4-photo-v1",
    icon = 1,
    playerName = "GOLD",
    playerGender = 0,
    leadNickname = "LEAF",
    avatarState = "normal",
    mapSymbol = "MAP_PHOTO_TEST",
    fieldX = 5,
    fieldZ = 7,
    date = { year = 2010, month = 1, day = 2, weekday = 6 },
    hour = 18,
    minute = 37,
    party = {
      { species = "CHIKORITA", form = 0, gender = 1, shiny = true },
      false,
      false,
      false,
      false,
      false,
    },
    sourcePartyCount = 1,
    hiddenPropModels = { "HIDDEN_PROP_A", "HIDDEN_PROP_B" },
  }
end

local function world()
  local map = {
    id = 41,
    symbol = "MAP_PHOTO_TEST",
    mapSection = "TEST",
    mapSectionNativeId = 1,
    followMode = "ALLOW",
    worldOriginX = 100,
    worldOriginZ = 200,
    matrix = { memberId = 12 },
  }
  return {
    schema = MapAssetCache.WORLD_SCHEMA,
    maps = { map },
    byId = { [41] = 1 },
    bySymbol = { MAP_PHOTO_TEST = 41 },
    analysis = { mapHeaderCount = 1, excluded = {} },
  }
end

local function sceneImplementation()
  local ok, scene = pcall(require, "game.hgss.src.pc.PhotoScene")
  Assert.isTrue(ok, "saved photo scene preparation and cancellation are implemented")
  return assert(scene)
end

function T.cancelled_location_demand_cannot_adopt_a_late_ready_photo()
  local PhotoScene = sceneImplementation()
  local pending = true
  local requests = {}
  local derivedAssets = {
    requestField = function(mapId, urgency)
      requests[#requests + 1] = { kind = "field", mapId = mapId, urgency = urgency }
      return true
    end,
    requestLogicalField = function(mapId, urgency)
      requests[#requests + 1] = { kind = "logical", mapId = mapId, urgency = urgency }
      return not pending
    end,
    requestCell = function(descriptor, urgency)
      requests[#requests + 1] = { kind = "cell", descriptor = descriptor.index, urgency = urgency }
      return true
    end,
  }
  local cacheFs = {
    loadLua = function(_, path)
      if path == FieldCellCache.indexPath() then
        return {
          schema = FieldCellCache.INDEX_SCHEMA,
          matrices = {
            {
              matrixMemberId = 12,
              width = 8,
              height = 8,
              cells = {
                {
                  matrixMemberId = 12,
                  index = 0,
                  x = 3,
                  z = 6,
                  mapHeaderId = 41,
                  altitude = 0,
                  landDataMemberId = 1,
                  areaDataMemberId = 1,
                  file = FieldCellCache.cellPath(12, 0),
                },
              },
            },
          },
        }
      end
      return nil, "not staged"
    end,
  }
  local loader = FieldMapLoader.new(cacheFs, world(), { derivedAssets = derivedAssets })
  local album = PhotoAlbum.new()
  local record = savedPhoto()
  local stored = assert(album:prepareChanges(0, { { slot = 0, value = record } }))
  stored.publish()
  local before = album:get(0)
  local scene = PhotoScene.new({
    versionId = "heartgold",
    cacheFs = cacheFs,
    derivedAssets = derivedAssets,
    profile = { name = "GOLD", gender = 0 },
    monCatalog = { followerSelection = function() end },
    fieldMapLoader = loader,
  })

  scene:request(album:get(0))
  Assert.equal(scene:status().phase, "pending", "the scene waits for its saved map's required closure")
  Assert.deepEqual(requests, {
    { kind = "field", mapId = 41, urgency = "required" },
    { kind = "logical", mapId = 41, urgency = "required" },
    { kind = "cell", descriptor = 0, urgency = "required" },
  }, "the real loader resolves the saved map symbol and global coordinates")
  Assert.equal(loader:residentCount(), 0, "location demand does not acquire a map scene")

  scene:cancel()
  pending = false
  scene:advance(64)
  Assert.isTrue(scene:status().phase ~= "ready", "a cancelled generation cannot publish delayed readiness")
  Assert.equal(loader:residentCount(), 0, "late readiness never loads into the private loader")
  Assert.deepEqual(album:get(0), before, "failed or cancelled viewing retains the saved record")

  scene:dispose()
  Assert.isTrue(loader.released, "disposing the photo releases its privately owned loader")
  Assert.deepEqual(album:get(0), before, "scene cleanup leaves persisted photo data unchanged")
  scene:dispose()
  Assert.isTrue(loader.released, "repeated disposal remains safe")
end

return { tests = T }
