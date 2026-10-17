-- Photo requests use the production FieldMapLoader coordinate and demand
-- seam, while cancellation prevents delayed work from becoming a ready view.

local Assert = require("tests.support.Assert")
local PhotoAlbum = require("libs.hgss.src.save.PhotoAlbum")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local SharedImagePoolFake = require("tests.support.SharedImagePoolFake")
local FieldActorCache = require("libs.assets.src.field.FieldActorCache")
local FieldActorFixture = require("tests.support.FieldActorFixture")
local PngWriter = require("libs.assets.src.PngWriter")
local FieldCellCache = require("libs.assets.src.field.FieldCellCache")
local FieldMapDataCache = require("libs.assets.src.field.FieldMapDataCache")
local CollisionFixture = require("tests.support.CollisionFixture")
local FieldMapLoader = require("libs.hgss.src.world.FieldMapLoader")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local HgssFieldEdgeColors = require("romdump.src.digest.field.HgssFieldEdgeColors")
local HgssFieldFog = require("romdump.src.digest.field.HgssFieldFog")

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
  local loader =
    FieldMapLoader.new(cacheFs, world(), { derivedAssets = derivedAssets, imageAssets = SharedImagePoolFake.new() })
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

local AVATAR_SPRITE = 11

local function strictMonCatalog()
  return {
    followerSelection = function()
      error("a lone saved photo must not resolve a party follower", 0)
    end,
  }
end

local function readyDerivedAssets()
  return {
    requestField = function()
      return true
    end,
    requestLogicalField = function()
      return true
    end,
    requestCell = function()
      return true
    end,
    ensureField = function() end,
    ensureLogicalField = function() end,
    ensureCell = function() end,
  }
end

local function indoorFieldData()
  return {
    schema = FieldMapDataCache.FIELD_SCHEMA,
    initScripts = {},
    mapId = 41,
    mapSymbol = "MAP_PHOTO_TEST",
    cameraType = 0,
    transitionEnvironment = "outdoors",
    fieldUse = {
      flyAllowed = true,
      teleportAllowed = true,
      escapeAllowed = false,
      flashUsable = false,
      alphChamber = false,
      icePathB2F = false,
      cave = false,
      unionOrColosseum = false,
    },
    events = { background = {}, objects = {}, warps = {}, coordinates = {} },
    music = { day = "SEQ_X", night = "SEQ_X", flagOverrides = {}, traversalOverrides = {} },
    soundplates = {},
    renderEnvironment = {
      lighting = {
        records = {
          {
            endHalfSeconds = 0,
            lights = {},
            diffuseRgb555 = 0,
            ambientRgb555 = 0,
            specularRgb555 = 0,
            emissionRgb555 = 0,
          },
        },
      },
      edgeColors = HgssFieldEdgeColors.tableForAreaLightPattern(0),
      weatherId = 0,
      fog = HgssFieldFog.runtimePreset(HgssFieldFog.resolve(0)),
    },
  }
end

local function lonePhoto()
  local photo = savedPhoto()
  photo.subjectSprite = nil
  photo.party = { false, false, false, false, false, false }
  return photo
end

local function indoorCache()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:writeLua(MapAssetCache.worldPath(), world())
  cache:writeLua(FieldCellCache.indexPath(), {
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
            x = 0,
            z = 0,
            mapHeaderId = 41,
            altitude = 0,
            landDataMemberId = 1,
            areaDataMemberId = 1,
            file = FieldCellCache.cellPath(12, 0),
          },
        },
      },
    },
  })
  cache:writeLua(FieldMapDataCache.fieldPath(41), indoorFieldData())
  cache:writeLua(MapAssetCache.mapDir(41) .. "/scene.lua", {
    schema = MapAssetCache.SCENE_SCHEMA,
    mapId = 41,
    mapSymbol = "MAP_PHOTO_TEST",
    type = "indoor",
    cameraType = 0,
    neighbors = {},
    buildingInstances = {},
    terrainAnimations = { textureSrt = false },
    matrix = { worldOriginX = 100, worldOriginZ = 200 },
    collision = { file = "test/indoor.collision" },
  })
  cache:writeLua(MapAssetCache.terrainPath(41), {
    schema = MapAssetCache.TERRAIN_SCHEMA,
    source = { bdhcSha1 = "photo-indoor-terrain" },
    plates = {},
  })
  cache:write("test/indoor.collision", CollisionFixture.asset(32, 32))
  cache:writeLua(FieldActorCache.indexPath(), {
    schema = FieldActorCache.INDEX_SCHEMA,
    spriteIds = { AVATAR_SPRITE },
    runtime = {
      avatars = {
        [1] = { states = { normal = AVATAR_SPRITE, walking = AVATAR_SPRITE } },
      },
    },
  })
  cache:writeLua(FieldActorCache.visualPath(AVATAR_SPRITE), FieldActorFixture.visual(AVATAR_SPRITE, { frameCount = 5 }))
  cache:write(
    FieldActorCache.atlasPath(AVATAR_SPRITE),
    PngWriter.encode(160, 32, string.rep(string.char(180, 60, 80, 255), 160 * 32))
  )
  return cache
end

local function indoorLoader(cache, pool)
  return FieldMapLoader.new(cache, world(), {
    derivedAssets = readyDerivedAssets(),
    sceneLoader = {
      load = function(_, scene)
        return {
          scene = scene,
          release = function() end,
        }
      end,
    },
    imageAssets = pool,
  })
end

function T.viewers_release_only_the_loader_they_own()
  local PhotoScene = sceneImplementation()
  local cache = indoorCache()
  local borrowedPool = SharedImagePoolFake.new()
  local ownedPool = SharedImagePoolFake.new()
  local liveLoader = indoorLoader(cache, borrowedPool)
  local ownedLoader = indoorLoader(cache, ownedPool)
  local album = PhotoAlbum.new()
  local stored = assert(album:prepareChanges(0, { { slot = 0, value = lonePhoto() } }))
  stored.publish()
  local before = album:get(0)

  local borrowed = PhotoScene.new({
    versionId = "heartgold",
    cacheFs = cache,
    derivedAssets = readyDerivedAssets(),
    profile = { name = "GOLD", gender = 0 },
    monCatalog = strictMonCatalog(),
    fieldMapLoader = liveLoader,
    borrowFieldMapLoader = true,
  })
  borrowed:request(album:get(0))
  Assert.equal(borrowed:status().phase, "pending", "the borrowed viewer waits on the live loader's closure")
  borrowed:cancel()
  borrowed:advance(64)
  Assert.isTrue(borrowed:status().phase ~= "ready", "a cancelled borrowed viewer publishes nothing late")
  borrowed:dispose()
  borrowed:dispose()
  Assert.isFalse(liveLoader.released, "closing the borrowed viewer leaves the live loader alive")
  Assert.deepEqual(album:get(0), before, "borrowed viewing retains the saved record")

  local owned = PhotoScene.new({
    versionId = "heartgold",
    cacheFs = cache,
    derivedAssets = readyDerivedAssets(),
    profile = { name = "GOLD", gender = 0 },
    monCatalog = strictMonCatalog(),
    fieldMapLoader = ownedLoader,
  })
  owned:request(album:get(0))
  owned:cancel()
  owned:advance(64)
  Assert.isTrue(owned:status().phase ~= "ready", "a cancelled owned viewer publishes nothing late")
  owned:dispose()
  Assert.isTrue(ownedLoader.released, "disposing the owned viewer releases its injected loader once")
  owned:dispose()
  Assert.isTrue(ownedLoader.released, "repeated owned disposal remains safe")
  Assert.isFalse(liveLoader.released, "owned disposal never touches the live loader")
  Assert.deepEqual(album:get(0), before, "owned cleanup leaves persisted photo data unchanged")
end

function T.viewer_without_an_injected_loader_fails_before_building_a_private_one()
  local PhotoScene = sceneImplementation()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:writeLua(MapAssetCache.worldPath(), world())
  local ok, sceneOrErr = pcall(PhotoScene.new, {
    versionId = "heartgold",
    cacheFs = cache,
    derivedAssets = readyDerivedAssets(),
    profile = { name = "GOLD", gender = 0 },
    monCatalog = strictMonCatalog(),
  })
  if ok then
    sceneOrErr:dispose()
  end
  Assert.isFalse(ok, "a presented photo borrows the live field loader instead of starting a private worker")
end

function T.saved_subject_atlas_borrows_the_shared_image_owner()
  local PhotoScene = sceneImplementation()
  local cache = indoorCache()
  local pool = SharedImagePoolFake.new()
  local loader = indoorLoader(cache, pool)
  do
    local sampler = { wrapX = "clamp", wrapY = "clamp", minFilter = "nearest", magFilter = "nearest" }
    local visual = assert(cache:loadLua(FieldActorCache.visualPath(AVATAR_SPRITE)))
    local path = assert(visual.render.image)
    local bytes = assert(cache:read(path))
    local image = love.graphics.newImage(love.filesystem.newFileData(bytes, path))
    pool:seedPhysical(path, sampler, { image = image, width = image:getWidth(), height = image:getHeight() })
  end
  local album = PhotoAlbum.new()
  local stored = assert(album:prepareChanges(0, { { slot = 0, value = lonePhoto() } }))
  stored.publish()
  local before = album:get(0)
  local scene = PhotoScene.new({
    versionId = "heartgold",
    cacheFs = cache,
    derivedAssets = readyDerivedAssets(),
    profile = { name = "GOLD", gender = 0 },
    monCatalog = strictMonCatalog(),
    fieldMapLoader = loader,
    borrowFieldMapLoader = true,
  })

  scene:request(album:get(0))
  for _ = 1, 16 do
    if scene:status().phase ~= "pending" then
      break
    end
    scene:advance(16)
  end
  local status = scene:status()
  Assert.equal(status.phase, "ready", "a complete saved photo reaches a ready view")
  Assert.isNil(status.failure, "successful preparation carries no failure")
  local sampler = { wrapX = "clamp", wrapY = "clamp", minFilter = "nearest", magFilter = "nearest" }
  Assert.isTrue(
    pool:findPhysical(FieldActorCache.atlasPath(AVATAR_SPRITE), sampler) ~= nil,
    "the saved subject atlas resolves through the borrowed image owner instead of a private upload"
  )
  Assert.isTrue(
    pool:stats().outstandingLeases >= 1,
    "the ready viewer holds its subject atlas as a pool lease"
  )
  local view = scene:takeReady()
  Assert.isTrue(#view.subjects >= 1, "the ready view carries the saved player subject")

  scene:dispose()
  scene:dispose()
  Assert.isFalse(loader.released, "closing the viewer leaves the borrowed live loader alive")
  Assert.equal(pool:stats().outstandingLeases, 0, "closing the viewer returns its image leases exactly once")
  Assert.deepEqual(album:get(0), before, "viewing leaves the persisted photo unchanged")
end

return { tests = T }
