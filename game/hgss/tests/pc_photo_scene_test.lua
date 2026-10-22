-- Photo requests use the production FieldMapLoader coordinate and demand
-- seam, while cancellation prevents delayed work from becoming a ready view.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
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

-- Image-shaped stand-in for seeded physicals: the scene under test borrows
-- and releases leases but never draws, so component coverage needs no real
-- GPU texture (pixel rendering belongs to the graphics layer).
local function stubImage()
  local image = { released = false, releaseCount = 0 }
  function image:setFilter() end
  function image:setWrap() end
  function image:getWidth()
    return 64
  end
  function image:getHeight()
    return 32
  end
  function image:getDimensions()
    return 64, 32
  end
  function image:release()
    self.released = true
    self.releaseCount = self.releaseCount + 1
  end
  return image
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
    local image = stubImage()
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

local function partyPhoto()
  local photo = savedPhoto()
  photo.party = {
    { species = "CHIKORITA", form = 0, gender = 1, shiny = false },
    { species = "CYNDAQUIL", form = 0, gender = 0, shiny = false },
    { species = "TOTODILE", form = 0, gender = 1, shiny = false },
    false,
    false,
    false,
  }
  photo.sourcePartyCount = 3
  return photo
end

local function partyCatalog()
  local visuals = { CHIKORITA = 21, CYNDAQUIL = 22, TOTODILE = 23 }
  return {
    followerSelection = function(_, mon)
      local visualId = visuals[mon.species]
      assert(visualId, "saved party species needs its follower visual")
      return { visualId = visualId }
    end,
  }
end

local function multiSubjectCache()
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
  local spriteIds = { AVATAR_SPRITE, 21, 22, 23 }
  cache:writeLua(FieldActorCache.indexPath(), {
    schema = FieldActorCache.INDEX_SCHEMA,
    spriteIds = spriteIds,
    runtime = {
      avatars = {
        [1] = { states = { normal = AVATAR_SPRITE, walking = AVATAR_SPRITE } },
      },
    },
  })
  for _, spriteId in ipairs(spriteIds) do
    cache:writeLua(FieldActorCache.visualPath(spriteId), FieldActorFixture.visual(spriteId, { frameCount = 5 }))
    cache:write(
      FieldActorCache.atlasPath(spriteId),
      PngWriter.encode(160, 32, string.rep(string.char(180, 60, 80, 255), 160 * 32))
    )
  end
  return cache
end

-- A session image owner that withholds chosen atlas paths as worker-pending
-- until the viewer path is exercised, then lends them normally. Request and
-- cancellation counts stay visible so the viewer can prove bounded,
-- exactly-once preparation without sleeping.
local function delayedActorPool()
  local inner = SharedImagePoolFake.new()
  local pool = { _inner = inner, requests = 0, cancels = 0, _paths = {}, _pending = {} }
  function pool:blockAtlas(spriteId)
    self._pending[FieldActorCache.atlasPath(spriteId)] = true
  end
  function pool:blockAtlases(spriteIds)
    for _, spriteId in ipairs(spriteIds) do
      self:blockAtlas(spriteId)
    end
  end
  function pool:releaseAtlases()
    for path in pairs(self._pending) do
      self._pending[path] = nil
    end
  end
  function pool:request(path, sampler, priority)
    self.requests = self.requests + 1
    local token = self._inner:request(path, sampler, priority)
    self._paths[token] = path
    return token
  end
  function pool:poll(token)
    local path = self._paths[token]
    if path ~= nil and self._pending[path] then
      return "pending"
    end
    return self._inner:poll(token)
  end
  function pool:acquire(token)
    self._paths[token] = nil
    return self._inner:acquire(token)
  end
  function pool:cancel(token)
    self.cancels = self.cancels + 1
    self._paths[token] = nil
    return self._inner:cancel(token)
  end
  function pool:release(lease)
    return self._inner:release(lease)
  end
  function pool:seedPhysical(path, sampler, handle)
    return self._inner:seedPhysical(path, sampler, handle)
  end
  function pool:failAfterUploads(count, message)
    return self._inner:failAfterUploads(count, message)
  end
  function pool:clearFailure()
    return self._inner:clearFailure()
  end
  function pool:stats()
    return self._inner:stats()
  end
  function pool:findPhysical(path, sampler)
    return self._inner:findPhysical(path, sampler)
  end
  function pool:prune()
    return self._inner:prune()
  end
  function pool:dispose()
    return self._inner:dispose()
  end
  function pool:uploadCount()
    return self._inner.uploads
  end
  return pool
end

local function seedSubjectAtlas(pool, cache, spriteId)
  local sampler = { wrapX = "clamp", wrapY = "clamp", minFilter = "nearest", magFilter = "nearest" }
  local visual = assert(cache:loadLua(FieldActorCache.visualPath(spriteId)))
  local path = assert(visual.render.image)
  local image = stubImage()
  pool:seedPhysical(path, sampler, { image = image, width = image:getWidth(), height = image:getHeight() })
  return path
end

local function contains(list, value)
  for _, entry in ipairs(list) do
    if entry == value then
      return true
    end
  end
  return false
end

-- Withheld subject atlases keep every viewer advance responsive: the viewer
-- stays pending with no partial image, then publishes the exact saved
-- player and party subjects at their source offsets once staged.
function T.pending_subject_atlases_keep_advance_responsive_until_ready()
  local PhotoScene = sceneImplementation()
  local cache = multiSubjectCache()
  local pool = delayedActorPool()
  local spriteIds = { AVATAR_SPRITE, 21, 22, 23 }
  for _, spriteId in ipairs(spriteIds) do
    seedSubjectAtlas(pool, cache, spriteId)
  end
  pool:blockAtlases(spriteIds)
  local loader = indoorLoader(cache, pool)
  local album = PhotoAlbum.new()
  local stored = assert(album:prepareChanges(0, { { slot = 0, value = partyPhoto() } }))
  stored.publish()
  local before = album:get(0)
  local scene = PhotoScene.new({
    versionId = "heartgold",
    cacheFs = cache,
    derivedAssets = readyDerivedAssets(),
    profile = { name = "GOLD", gender = 0 },
    monCatalog = partyCatalog(),
    fieldMapLoader = loader,
    borrowFieldMapLoader = true,
  })

  scene:request(album:get(0))
  Assert.equal(scene:status().phase, "pending", "the viewer waits while its saved map resolves")
  for _ = 1, 6 do
    scene:advance(16)
    local status = scene:status()
    Assert.equal(status.phase, "pending", "withheld subject atlases keep the viewer pending without failing")
    Assert.isNil(status.failure, "pending preparation carries no failure")
  end
  Assert.equal(pool.requests, #spriteIds, "every distinct subject holds one outstanding atlas ticket while pending")
  Assert.equal(#scene.spriteIds, 0, "no subject is published before its atlas is staged")
  Assert.equal(pool:stats().outstandingLeases, 0, "no atlas lease is borrowed before readiness")
  Assert.equal(pool:uploadCount(), 0, "withheld atlases stage no duplicate upload")
  Assert.isFalse(loader.released, "pending work never releases the borrowed live loader")

  pool:releaseAtlases()
  scene:advance(16)
  local mid = scene:status()
  Assert.equal(mid.phase, "pending", "staged subjects publish over bounded advances after readiness")
  Assert.isTrue(
    #scene.spriteIds >= 1 and #scene.spriteIds <= 2,
    "one advance materializes at most two new subjects"
  )
  for _ = 1, 8 do
    if scene:status().phase ~= "pending" then
      break
    end
    scene:advance(16)
  end
  local status = scene:status()
  Assert.equal(status.phase, "ready", "staged subjects reach a ready view")
  Assert.isNil(status.failure, "successful preparation carries no failure")
  Assert.equal(#scene.spriteIds, 4, "every distinct subject is acquired exactly once")
  for _, spriteId in ipairs(spriteIds) do
    Assert.isTrue(contains(scene.spriteIds, spriteId), "the ready viewer owns every saved subject atlas")
  end
  Assert.isTrue(pool:stats().outstandingLeases >= 4, "the ready viewer holds its subject atlases as pool leases")
  Assert.equal(pool:uploadCount(), 0, "borrowed atlas identities resolve without a new upload")

  local view = scene:takeReady()
  Assert.equal(#view.subjects, 4, "the ready view carries the saved player and party subjects")
  local byActor = {}
  for _, subject in ipairs(view.subjects) do
    byActor[subject.actorId] = subject
    Assert.equal(subject.facing, "south", "saved subjects face the source direction")
  end
  Assert.equal(byActor["photo-player"].spriteId, AVATAR_SPRITE, "the saved player resolves its avatar visual")
  Assert.deepEqual({ byActor["photo-player"].world.x, byActor["photo-player"].world.z }, { 5.5, 7.5 })
  Assert.equal(byActor["photo-party-1"].spriteId, 21, "party order determines the first follower visual")
  Assert.deepEqual({ byActor["photo-party-1"].world.x, byActor["photo-party-1"].world.z }, { 7.5, 7.5 })
  Assert.equal(byActor["photo-party-2"].spriteId, 22, "party order determines the second follower visual")
  Assert.deepEqual({ byActor["photo-party-2"].world.x, byActor["photo-party-2"].world.z }, { 6.5, 6.5 })
  Assert.equal(byActor["photo-party-3"].spriteId, 23, "party order determines the third follower visual")
  Assert.deepEqual({ byActor["photo-party-3"].world.x, byActor["photo-party-3"].world.z }, { 4.5, 6.5 })
  Assert.equal(view.mapSectionNativeId, 1, "the snapshot keeps its source map-section identity")
  Assert.equal(view.renderEnvironment.fieldTimeSeconds, 67020, "saved hour and minute set only the private clock")
  Assert.equal(view.camera.profile.projectionType, "perspective", "the source camera uses perspective projection")
  Assert.near(view.camera.profile.distanceTiles, 666.922119140625 / 16, 1e-12)
  Assert.equal(view.camera.profile.angleXRaw, 0xEE00, "camera X angle remains the source raw angle")
  Assert.equal(view.camera.profile.angleYRaw, 0, "camera Y angle remains the source raw angle")
  Assert.deepEqual(view.viewport, { x = 4, y = 3, width = 248, height = 185 })
  Assert.isTrue(#view.spriteItems >= 4, "the snapshot carries a draw item per saved subject")
  Assert.isTrue(#view.worldParts == 4, "the snapshot keeps the central scene lane layout")

  scene:dispose()
  scene:dispose()
  Assert.isFalse(loader.released, "closing the viewer leaves the borrowed live loader alive")
  Assert.equal(pool:stats().outstandingLeases, 0, "closing the viewer returns its image leases exactly once")
  Assert.deepEqual(album:get(0), before, "viewing leaves the persisted photo unchanged")
end

-- Cancelling, replacing, or failing a photo whose subjects are still
-- withheld returns every staged ticket and lease exactly once, never
-- touches the borrowed loader, and never publishes a stale or partial view.
function T.cancel_replacement_and_atlas_failure_return_staged_resources_once()
  local PhotoScene = sceneImplementation()
  local spriteIds = { AVATAR_SPRITE, 21, 22, 23 }

  do
    local cache = multiSubjectCache()
    local pool = delayedActorPool()
    for _, spriteId in ipairs(spriteIds) do
      seedSubjectAtlas(pool, cache, spriteId)
    end
    pool:blockAtlases(spriteIds)
    local loader = indoorLoader(cache, pool)
    local album = PhotoAlbum.new()
    local stored = assert(album:prepareChanges(0, { { slot = 0, value = partyPhoto() } }))
    stored.publish()
    local before = album:get(0)
    local scene = PhotoScene.new({
      versionId = "heartgold",
      cacheFs = cache,
      derivedAssets = readyDerivedAssets(),
      profile = { name = "GOLD", gender = 0 },
      monCatalog = partyCatalog(),
      fieldMapLoader = loader,
      borrowFieldMapLoader = true,
    })
    scene:request(album:get(0))
    for _ = 1, 3 do
      scene:advance(16)
      Assert.equal(scene:status().phase, "pending", "withheld subjects keep the viewer pending before cancel")
    end
    Assert.equal(pool.requests, 4, "every distinct subject holds one outstanding ticket before cancel")
    scene:cancel()
    Assert.equal(scene:status().phase, "cancelled", "cancel between map and subject work stops the viewer")
    scene:advance(16)
    Assert.equal(scene:status().phase, "cancelled", "a cancelled viewer publishes nothing late")
    Assert.equal(pool:stats().outstandingLeases, 0, "cancel borrows no atlas lease")
    Assert.equal(pool.cancels, 4, "cancel returns every outstanding atlas ticket exactly once")
    Assert.throws(function()
      scene:takeReady()
    end, "a cancelled viewer has no view to transfer")
    scene:dispose()
    scene:dispose()
    Assert.isFalse(loader.released, "cancel leaves the borrowed live loader alive")
    Assert.equal(pool:stats().outstandingLeases, 0, "cancelled cleanup holds no lease")
    Assert.deepEqual(album:get(0), before, "cancel leaves the persisted photo unchanged")
  end

  do
    local cache = multiSubjectCache()
    local pool = delayedActorPool()
    for _, spriteId in ipairs(spriteIds) do
      seedSubjectAtlas(pool, cache, spriteId)
    end
    pool:blockAtlases(spriteIds)
    local loader = indoorLoader(cache, pool)
    local album = PhotoAlbum.new()
    local first = partyPhoto()
    local second = partyPhoto()
    second.hour = 9
    local stored = assert(album:prepareChanges(0, { { slot = 0, value = first } }))
    stored.publish()
    local scene = PhotoScene.new({
      versionId = "heartgold",
      cacheFs = cache,
      derivedAssets = readyDerivedAssets(),
      profile = { name = "GOLD", gender = 0 },
      monCatalog = partyCatalog(),
      fieldMapLoader = loader,
      borrowFieldMapLoader = true,
    })
    scene:request(album:get(0))
    for _ = 1, 3 do
      scene:advance(16)
      Assert.equal(scene:status().phase, "pending", "the first photo stays pending while its subjects are withheld")
    end
    Assert.equal(pool.requests, 4, "the first photo holds one ticket per subject before replacement")
    scene:request(second)
    Assert.equal(scene:status().phase, "pending", "replacement starts its own pending viewer")
    Assert.equal(pool.cancels, 4, "replacement returns the superseded photo tickets exactly once")
    Assert.equal(pool:stats().outstandingLeases, 0, "replacement borrows no lease for the superseded photo")
    for _ = 1, 3 do
      scene:advance(16)
      Assert.equal(scene:status().phase, "pending", "the replacement stays pending while its subjects are withheld")
    end
    pool:releaseAtlases()
    for _ = 1, 8 do
      if scene:status().phase ~= "pending" then
        break
      end
      scene:advance(16)
    end
    Assert.equal(scene:status().phase, "ready", "the replacement reaches a ready view")
    local view = scene:takeReady()
    Assert.equal(
      view.renderEnvironment.fieldTimeSeconds,
      9 * 3600 + 37 * 60,
      "late completion of the superseded photo cannot publish into the new viewer"
    )
    Assert.equal(#view.subjects, 4, "the replacement view carries its own saved subjects")
    scene:dispose()
    Assert.isFalse(loader.released, "replacement leaves the borrowed live loader alive")
    Assert.equal(pool:stats().outstandingLeases, 0, "closing the replacement viewer returns its leases exactly once")
    Assert.deepEqual(album:get(0), first, "replacement leaves the persisted photo unchanged")
  end

  do
    local cache = multiSubjectCache()
    local pool = delayedActorPool()
    for _, spriteId in ipairs(spriteIds) do
      seedSubjectAtlas(pool, cache, spriteId)
    end
    pool:failAfterUploads(0, "injected atlas failure")
    local loader = indoorLoader(cache, pool)
    local album = PhotoAlbum.new()
    local stored = assert(album:prepareChanges(0, { { slot = 0, value = partyPhoto() } }))
    stored.publish()
    local before = album:get(0)
    local scene = PhotoScene.new({
      versionId = "heartgold",
      cacheFs = cache,
      derivedAssets = readyDerivedAssets(),
      profile = { name = "GOLD", gender = 0 },
      monCatalog = partyCatalog(),
      fieldMapLoader = loader,
      borrowFieldMapLoader = true,
    })
    scene:request(album:get(0))
    for _ = 1, 8 do
      if scene:status().phase ~= "pending" then
        break
      end
      scene:advance(16)
    end
    local status = scene:status()
    Assert.equal(status.phase, "failed", "a missing subject atlas fails the viewer instead of publishing partially")
    Assert.isTrue(Errors.is(status.failure), "a failed atlas surfaces its typed cause")
    Assert.equal(status.failure.code, "FIELD_ACTOR_ATLAS_MISSING", "a failed atlas names its missing image cause")
    Assert.throws(function()
      scene:takeReady()
    end, "a failed viewer has no view to transfer")
    Assert.equal(pool:stats().outstandingLeases, 0, "failure borrows no atlas lease")
    scene:dispose()
    scene:dispose()
    Assert.isFalse(loader.released, "failure leaves the borrowed live loader alive")
    Assert.equal(pool:stats().outstandingLeases, 0, "failed cleanup holds no lease")
    Assert.deepEqual(album:get(0), before, "failure leaves the persisted photo unchanged")
  end
end

return { tests = T }
