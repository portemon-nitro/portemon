-- LÖVE tests for MapSceneLoader's sampler-aware image ownership and
-- transactional construction: materials sharing one texture path but sampling
-- it with different wrap modes must receive independent, correctly configured
-- images (regression for the shared-sampler alias), same-sampler materials
-- share one image, and unknown wrap modes fail loudly instead of degrading to
-- clamp. Image construction needs a graphics context, so those tests skip
-- graphics; the unknown-wrap rejection and every post-acquisition failure that
-- releases already-acquired images use an injected fake graphics namespace.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local MapSceneLoader = require("libs.hgss.src.presentation.MapSceneLoader")
local MeshWriter = require("libs.assets.src.model.MeshWriter")
local CollisionGridAsset = require("libs.assets.src.field.CollisionGridAsset")
local PngWriter = require("tests.support.PngEncoder")
local SceneMesh = require("libs.hgss.src.presentation.SceneMesh")
local ControllableImageOwner = require("tests.support.ControllableImageOwner")
local SharedImagePoolFake = require("tests.support.SharedImagePoolFake")
local SynchronousWaitProbe = require("tests.support.SynchronousWaitProbe")

local T = {}

-- One-triangle batch in the MeshWriter vertex layout.
local function triangleBatch()
  local function v(x, z)
    return {
      x = x,
      y = 0,
      z = z,
      u = 0,
      v = 0,
      nx = 0,
      ny = 1,
      nz = 0,
      r = 255,
      g = 255,
      b = 255,
      a = 255,
      colorSource = 0,
    }
  end
  return { vertices = { v(0, 0), v(2, 0), v(0, 2) }, indices = { 0, 1, 2 } }
end

local function material(id, texPath, wrap)
  local result = {
    id = id,
    name = "mat" .. id,
    texture = texPath,
    wrap = wrap,
    diffuse = { r = 255, g = 255, b = 255, a = 255 },
    texWidth = 16,
    texHeight = 16,
    texMtxMode = 0,
  }
  return result
end

local function batch(geomPath, materialId)
  local result = {
    geometry = geomPath,
    material = materialId,
    alphaClass = "opaque",
    cullMode = "back",
    polygonAlpha = 31,
    polygonMode = "modulation",
    lightMask = 0,
    polygonId = 0,
    translucentDepthWrite = false,
    depthEqual = false,
  }
  return result
end

-- A minimal current scene: no building instances, no neighbors, one terrain
-- batch per supplied material, and the scene's collision asset (the door
-- pass resolves against the grid it decodes into).
-- A disabled fog preset shape (HgssFieldFog.runtimePreset's shape for a
-- disabled weather); this suite does not exercise fog wiring itself.
local function defaultFogFixture()
  local table32 = {}
  for i = 1, 32 do
    table32[i] = 0
  end
  return { enabled = false, color = 0, offset = 0, table = table32 }
end

local function scene(materials)
  return {
    schema = MapAssetCache.SCENE_SCHEMA,
    mapId = 1,
    cameraType = 0,
    matrix = { width = 1, height = 1, x = 0, z = 0, worldOriginX = 0, worldOriginZ = 0 },
    collision = { width = 32, height = 32, file = MapAssetCache.collisionPath(1) },
    materials = materials,
    mapBatches = {},
    buildingInstances = {},
    neighbors = {},
    terrainAnimations = { textureSrt = false },
    fog = defaultFogFixture(),
  }
end

-- A cacheFs serving canned bytes for the shared geometry/texture paths.
-- luaFiles backs loadLua for model descriptors. The blob table is returned so
-- tests can corrupt or omit individual files.
local function cacheFs()
  local geomPath = MapAssetCache.geometryPath("aaaa")
  local texPath = MapAssetCache.texturePath("bbbb")
  local luaFiles = {}
  local cells = {}
  for index = 1, 32 * 32 do
    cells[index] = { behavior = 0, terrainResponseId = 0, blocked = false }
  end
  local blob = {
    [geomPath] = MeshWriter.encode(triangleBatch()),
    [texPath] = PngWriter.encode(1, 1, string.char(255, 0, 0, 255)),
    [MapAssetCache.collisionPath(1)] = CollisionGridAsset.encode({ width = 32, height = 32, cells = cells }),
  }
  local references = {}
  local function acquireSource(reference)
    local lease = { value = assert(reference).data }
    function lease:release()
      self.value = nil
    end
    return lease
  end
  local result = {
    read = function(_, path)
      return blob[path]
    end,
    loadLua = function(_, path)
      return luaFiles[path]
    end,
    -- Presented collision borrows the resident compact bytes: one immutable
    -- reference per generated payload, taken through the acquirer below.
    resolveAsset = function(_, path)
      local payload = blob[path]
      if type(payload) ~= "string" then
        return nil
      end
      local reference = references[path]
      if reference == nil then
        reference = {
          path = path,
          sourceId = "base:map-scene-loader-test",
          contentId = "map-scene-loader-test\0" .. path,
          size = #payload,
          data = assert(love.data.newByteData(payload)),
        }
        references[path] = reference
      end
      return reference
    end,
    acquireSource = acquireSource,
  }
  ---@cast result CacheFs
  return result, geomPath, texPath, luaFiles, blob
end

-- Injected graphics namespace tracking created images and their release calls,
-- so the image side of a failed load can be observed without a GL context.
---@class SceneFakeGraphics: love.graphics
---@field images table[]
local function fakeGraphics()
  local images = {}
  local graphics = {
    images = images,
    newImage = function()
      local image = { released = false }
      image.setFilter = function() end
      image.setWrap = function() end
      image.release = function()
        image.released = true
      end
      images[#images + 1] = image
      return image
    end,
    newMesh = function()
      local mesh = { released = false }
      mesh.setVertices = function() end
      mesh.setVertexMap = function() end
      mesh.release = function()
        mesh.released = true
      end
      return mesh
    end,
  }
  ---@cast graphics SceneFakeGraphics
  return graphics
end

local function fakeImage()
  return {
    setFilter = function() end,
    setWrap = function() end,
    release = function() end,
    getWidth = function()
      return 1
    end,
    getHeight = function()
      return 1
    end,
  }
end

local function fakeMesh()
  return { release = function() end }
end

local IDENTITY = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }

-- A deterministic fake AssetPreparationQueue: `pendingPolls` controls how
-- many poll() calls on a token return "pending" before it becomes "ready".
-- Once ready, the payload is computed lazily from the same cache bytes a
-- real worker would have prepared, so realized resources are equivalent to
-- the synchronous path. Exercises MapSceneLoader's WAIT/checkpoint contract
-- without starting any real thread.
local function fakeAssetPreparationQueue(cache, opts)
  opts = opts or {}
  local pendingPolls = opts.pendingPolls or 0
  -- A single path whose preparation never completes: poll() stays pending
  -- and wait() raises the injected failure, so a synchronous finish() can
  -- prove failure propagation and cleanup of already-realized resources.
  local waitFailurePath = opts.waitFailurePath
  local waitFailureMessage = opts.waitFailureMessage or "injected preparation wait failure"
  -- A single path whose preparation reports a terminal failure result, the
  -- ordinary non-throwing "failed" status the real queue keeps the ticket for.
  local pollFailurePath = opts.pollFailurePath
  local pollFailureMessage = opts.pollFailureMessage or "injected preparation failure"
  local records = {}
  local nextToken = 0
  -- Requests actually routed through this queue, in order: the tests assert
  -- against this log so a production path that silently keeps using the
  -- synchronous acquisition (ignoring the injected queue) cannot pass by
  -- accident.
  local requestLog = {}
  -- Cancellations in order, so a failed build can prove which ticket its
  -- unwind dropped, and the live-ticket census a failed build must empty.
  local cancelCalls = {}
  local queue = { requestLog = requestLog, cancelCalls = cancelCalls }
  local function payloadFor(record)
    if record.kind == "mesh" then
      return SceneMesh.prepareUpload(assert(cache:read(record.path), "missing mesh " .. record.path))
    end
    local bytes = assert(cache:read(record.path), "missing texture " .. record.path)
    return { imageData = love.image.newImageData(love.filesystem.newFileData(bytes, "tex.png")) }
  end
  function queue:request(kind, path, priority)
    nextToken = nextToken + 1
    records[nextToken] = { kind = kind, path = path, priority = priority, polls = 0 }
    requestLog[#requestLog + 1] = { token = nextToken, kind = kind, path = path, priority = priority }
    return nextToken
  end
  function queue:poll(token)
    local record = assert(records[token], "unknown token")
    if pollFailurePath ~= nil and record.path == pollFailurePath then
      return "failed", pollFailureMessage
    end
    if waitFailurePath ~= nil and record.path == waitFailurePath then
      return "pending"
    end
    record.polls = record.polls + 1
    if record.polls <= pendingPolls then
      return "pending"
    end
    if not record.payload then
      record.payload = payloadFor(record)
    end
    return "ready"
  end
  -- A take transfers one kernel lease over the shared decoded value, exactly
  -- like the selected queue: the caller owns it and returns it through the
  -- decoded owner below.
  function queue:take(token)
    local record = assert(records[token], "unknown token")
    local payload = assert(record.payload, "take before ready")
    records[token] = nil
    return { value = { kind = record.kind, payload = payload } }
  end
  function queue:promote(token, priority)
    local record = assert(records[token], "unknown token")
    assert(priority == "demand", "unknown preparation priority " .. tostring(priority))
    record.priority = priority
  end
  function queue:wait(token)
    local record = assert(records[token], "unknown token")
    if waitFailurePath ~= nil and record.path == waitFailurePath then
      error(waitFailureMessage, 0)
    end
    while self:poll(token) ~= "ready" do
    end
    return self:take(token)
  end
  function queue:cancel(token)
    cancelCalls[#cancelCalls + 1] = token
    records[token] = nil
  end
  -- Live tickets still owned by a caller: queued/ready records no take, wait,
  -- or cancel consumed.
  ---@return integer
  function queue:outstandingTickets()
    local total = 0
    for _ in pairs(records) do
      total = total + 1
    end
    return total
  end
  function queue:release() end
  -- The borrowed decoded CPU owner these leases return through.
  queue.decoded = {
    leased = 0,
    returned = 0,
    trims = 0,
    returnLease = function(self, lease)
      if lease == nil then
        return false
      end
      lease.value = nil
      self.returned = self.returned + 1
      return true
    end,
    trim = function(self)
      self.trims = self.trims + 1
      return 0
    end,
  }
  queue.decoded.leased = 0
  return queue
end

-- Every staged build in this suite borrows compact collision through the
-- fixture's selected acquirer, so its options carry the same capability the
-- production composition injects.
local function beginScene(cache, scene, opts)
  opts = opts or {}
  opts.acquireSource = opts.acquireSource or cache.acquireSource
  if opts.imageAssets ~= nil and opts.assetPreparation == nil then
    local queue = fakeAssetPreparationQueue(cache)
    opts.assetPreparation = queue
    opts.decoded = queue.decoded
  end
  if opts.imageAssets ~= nil and opts.assetPreparation ~= nil and opts.decoded ~= nil then
    local images = opts.imageAssets
    images._preparation = { queue = opts.assetPreparation, decoded = opts.decoded }
    function images:preparation()
      return self._preparation
    end
  end
  return MapSceneLoader.begin(cache, scene, opts)
end

local function loadScene(cache, scene, opts)
  return beginScene(cache, scene, opts):finish()
end

function T.same_texture_with_different_wraps_gets_independent_images()
  local cache, geomPath, texPath = cacheFs()
  local s =
    scene({ material(0, texPath, { x = "clamp", y = "clamp" }), material(1, texPath, { x = "repeat", y = "repeat" }) })
  s.mapBatches = { batch(geomPath, 0), batch(geomPath, 1) }
  local images = SharedImagePoolFake.new()
  local runtime = loadScene(cache, s, { imageAssets = images })
  local clampImage = runtime.mapDraws[1].material.image
  local repeatImage = runtime.mapDraws[2].material.image
  Assert.isTrue(clampImage ~= repeatImage, "shared pixels with different wraps must not alias")
  Assert.equal(images:findPhysical(texPath, { wrapX = "clamp", wrapY = "clamp" }), clampImage)
  Assert.equal(images:findPhysical(texPath, { wrapX = "repeat", wrapY = "repeat" }), repeatImage)
  Assert.equal(runtime.stats.textureCount, 2)
  Assert.equal(runtime.stats.meshCount, 1, "the shared geometry still dedups")
  runtime:release()
end

function T.same_texture_and_wrap_share_one_image()
  local cache, geomPath, texPath = cacheFs()
  local s = scene({
    material(0, texPath, { x = "repeat", y = "clamp" }),
    material(1, texPath, { x = "repeat", y = "clamp" }),
  })
  s.mapBatches = { batch(geomPath, 0), batch(geomPath, 1) }
  local runtime = loadScene(cache, s, { imageAssets = SharedImagePoolFake.new() })
  Assert.equal(runtime.mapDraws[1].material.image, runtime.mapDraws[2].material.image)
  Assert.equal(runtime.stats.textureCount, 1)
  runtime:release()
end

function T.scene_and_building_descriptor_samplers_stay_independent()
  local cache, geomPath, texPath, luaFiles = cacheFs()
  local s = scene({ material(0, texPath, { x = "clamp", y = "clamp" }) })
  s.mapBatches = { batch(geomPath, 0) }
  -- The building descriptor shares the scene texture but samples it with
  -- repeat wrap; the scene image and the descriptor image must stay separate.
  s.buildingInstances = {
    {
      placementIndex = 0,
      modelKey = "building",
      transform = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 },
    },
  }
  luaFiles[MapAssetCache.modelPath("building")] = {
    schema = "g4-model-descriptor-v1",
    kind = "static",
    batches = { batch(geomPath, 0) },
    materials = { material(0, texPath, { x = "repeat", y = "repeat" }) },
  }
  local runtime = loadScene(cache, s, { imageAssets = SharedImagePoolFake.new() })
  Assert.equal(runtime.stats.textureCount, 2)
  local sceneImage = runtime.mapDraws[1].material.image
  local buildingImage = runtime.staticBuildingDraws[1].material.image
  Assert.isTrue(sceneImage ~= buildingImage, "scene and descriptor samplers stay independent")
  runtime:release()
end

function T.unknown_wrap_modes_fail_loudly()
  local cache, geomPath, texPath = cacheFs()
  local s = scene({ material(0, texPath, { x = "mirror", y = "clamp" }) })
  s.mapBatches = { batch(geomPath, 0) }
  local ok, err = pcall(MapSceneLoader.load, cache, s, { imageAssets = SharedImagePoolFake.new() })
  Assert.isTrue(
    not ok and Errors.is(err) and err.code == "SCENE_DESC_BAD_WRAP",
    "raises SCENE_DESC_BAD_WRAP: " .. tostring(err.code)
  )
end

-- A scene material image is borrowed before the map batches; a missing
-- geometry path fails that later mesh load, and the lease must be returned.
function T.failed_mesh_load_releases_acquired_images()
  local cache, _, texPath = cacheFs()
  local s = scene({ material(0, texPath, { x = "clamp", y = "clamp" }) })
  s.mapBatches = { { geometry = "missing-geometry.g4mesh", material = 0 } }
  local images = SharedImagePoolFake.new()
  local err = Assert.throws(function()
    loadScene(cache, s, { graphics = fakeGraphics(), imageAssets = images })
  end)
  Assert.isTrue(tostring(err):find("missing mesh missing-geometry.g4mesh", 1, true) ~= nil, "mesh failure propagates")
  Assert.equal(images.uploads, 1, "the scene material image was borrowed")
  local borrowed = images:findPhysical(texPath, { wrapX = "clamp", wrapY = "clamp" })
  Assert.notNil(borrowed, "the borrowed image was published before the mesh failed")
  Assert.equal(images:stats().outstandingLeases, 0, "a failed mesh load returns the borrowed lease")
  Assert.equal(images:prune(), 1, "the rolled-back image is reclaimed exactly once")
  Assert.isTrue(borrowed.released, "a failed mesh load releases the borrowed image")
end

-- The dedup consumption contract: one content-addressed mesh is
-- shared by the terrain batch, both placements of one static building model,
-- and the model's descriptor AABB. Every draw item must carry the SAME
-- per-mesh center (the value cached on the pool entry, not a per-draw
-- recomputation), and both placement records must share one descriptor AABB
-- table. A consumer that recomputes a center or folds bounds per placement
-- instead of reading the shared cached values turns this red.
function T.one_mesh_center_serves_every_consumer_and_placement()
  local cache, geomPath, texPath, luaFiles = cacheFs()
  local s = scene({ material(0, texPath, { x = "clamp", y = "clamp" }) })
  s.mapBatches = { batch(geomPath, 0) }
  s.buildingInstances = {
    { placementIndex = 0, modelKey = "building", transform = IDENTITY },
    {
      placementIndex = 1,
      modelKey = "building",
      transform = { 2, 0, 0, 0, 0, 3, 0, 0, 0, 0, 4, 0, 5, 0, 0, 1 },
    },
  }
  luaFiles[MapAssetCache.modelPath("building")] = {
    schema = "g4-model-descriptor-v1",
    kind = "static",
    batches = { batch(geomPath, 0) },
    materials = { material(0, texPath, { x = "clamp", y = "clamp" }) },
  }
  local runtime = loadScene(cache, s, { imageAssets = SharedImagePoolFake.new() })
  local expectedCenter = { 1, 0, 1 }
  Assert.deepEqual(runtime.mapDraws[1].center, expectedCenter, "the terrain draw carries the mesh center")
  Assert.deepEqual(runtime.staticBuildingDraws[1].center, expectedCenter, "placement 0 carries the same mesh center")
  Assert.deepEqual(runtime.staticBuildingDraws[2].center, expectedCenter, "placement 1 carries the same mesh center")
  Assert.deepEqual(runtime.mapDraws[1].modelNormal, { 1, 0, 0, 0, 1, 0, 0, 0, 1 })
  Assert.deepEqual(runtime.staticBuildingDraws[1].modelNormal, { 1, 0, 0, 0, 1, 0, 0, 0, 1 })
  Assert.deepEqual(
    runtime.staticBuildingDraws[2].modelNormal,
    { 0.5, 0, 0, 0, 1 / 3, 0, 0, 0, 0.25 },
    "a static building carries the inverse-transpose of its final transform"
  )
  local a = runtime.mapProps.placements[1].bounds
  local b = runtime.mapProps.placements[2].bounds
  Assert.equal(a, b, "both placements share one cached descriptor AABB")
  Assert.equal(a.minX, 0)
  Assert.equal(a.maxX, 2)
  Assert.equal(a.minY, 0)
  Assert.equal(a.maxY, 0)
  Assert.equal(a.minZ, 0)
  Assert.equal(a.maxZ, 2)
  runtime:release()
end

-- A missing model descriptor fails building creation after scene images
-- exist; every borrowed lease must be returned.
function T.failed_descriptor_load_releases_acquired_images()
  local cache, _, texPath = cacheFs()
  local s = scene({ material(0, texPath, { x = "clamp", y = "clamp" }) })
  s.buildingInstances = { { modelKey = "missing", transform = IDENTITY } }
  local images = SharedImagePoolFake.new()
  local err = Assert.throws(function()
    loadScene(cache, s, { graphics = fakeGraphics(), imageAssets = images })
  end)
  Assert.isTrue(tostring(err):find("missing model missing", 1, true) ~= nil, "descriptor failure propagates")
  Assert.equal(images.uploads, 1, "the scene material image was borrowed")
  Assert.equal(images:stats().outstandingLeases, 0, "a failed descriptor load returns the borrowed lease")
  Assert.equal(images:prune(), 1, "the rolled-back image is reclaimed exactly once")
end

-- An unknown wrap inside a building descriptor fails material creation after
-- the scene material image was acquired; the whole pool is released.
function T.unknown_wrap_in_a_building_descriptor_releases_acquired_images()
  local cache, _, texPath, luaFiles = cacheFs()
  local s = scene({ material(0, texPath, { x = "clamp", y = "clamp" }) })
  s.buildingInstances = { { modelKey = "building", transform = IDENTITY } }
  luaFiles[MapAssetCache.modelPath("building")] = {
    schema = "g4-model-descriptor-v1",
    batches = {},
    materials = { material(0, texPath, { x = "mirror", y = "clamp" }) },
  }
  local images = SharedImagePoolFake.new()
  local err = Assert.throws(function()
    loadScene(cache, s, { graphics = fakeGraphics(), imageAssets = images })
  end)
  Assert.isTrue(Errors.is(err) and err.code == "SCENE_DESC_BAD_WRAP", "raises SCENE_DESC_BAD_WRAP")
  Assert.equal(images.uploads, 1, "the scene image was borrowed before the descriptor failed")
  Assert.equal(images:stats().outstandingLeases, 0, "the scene lease is returned with the failed descriptor")
  Assert.equal(images:prune(), 1, "the rolled-back scene image is reclaimed exactly once")
end

-- An unsupported transform mode raises after its mesh was acquired; the load
-- must release the mesh and every image. love-backed (a real mesh is built).
function T.failed_transform_mode_releases_acquired_gpu_objects()
  local cache, geomPath, texPath = cacheFs()
  local s = scene({ material(0, texPath, { x = "clamp", y = "clamp" }) })
  s.mapBatches = { { geometry = geomPath, material = 0, transformMode = "spooky" } }
  local images = SharedImagePoolFake.new()
  local queue = fakeAssetPreparationQueue(cache)
  images._preparation = { queue = queue, decoded = queue.decoded }
  function images:preparation()
    return self._preparation
  end
  local ok, err = pcall(MapSceneLoader.load, cache, s, {
    graphics = fakeGraphics(),
    imageAssets = images,
    assetPreparation = queue,
    decoded = queue.decoded,
  })
  Assert.isTrue(
    not ok and Errors.is(err) and err.code == "MAP_SCENE_UNSUPPORTED_TRANSFORM_MODE",
    "raises the transform-mode error"
  )
  Assert.equal(images.uploads, 1, "the scene image was borrowed before the transform mode failed")
  Assert.equal(images:stats().outstandingLeases, 0, "the failed load returns the borrowed lease")
  Assert.equal(images:prune(), 1, "the rolled-back image is reclaimed exactly once")
end

function T.staged_scene_build_advances_one_atomic_operation_per_work_unit()
  Assert.equal(type(MapSceneLoader.begin), "function", "the production scene loader must expose staged construction")
  local cache, geomPath, texPath = cacheFs()
  local s = scene({
    material(0, texPath, { x = "clamp", y = "clamp" }),
    material(1, texPath, { x = "repeat", y = "repeat" }),
  })
  s.mapBatches = { batch(geomPath, 0), batch(geomPath, 1) }
  local meshAcquisitions = 0
  local task = beginScene(cache, s, {
    graphics = fakeGraphics(),
    imageAssets = SharedImagePoolFake.new(),
    meshBuilder = function()
      meshAcquisitions = meshAcquisitions + 1
      return fakeMesh()
    end,
  })

  Assert.equal(task:advance(1), 1, "one resume consumes one work unit")
  Assert.isFalse(task:isReady(), "a multi-resource scene is not ready after one work unit")
  Assert.isTrue(meshAcquisitions <= 1, "one work unit performs at most one atomic mesh acquisition")

  Assert.equal(task:advance(1), 1, "the next resume consumes one work unit")
  Assert.isFalse(task:isReady(), "the staged scene remains incomplete across resumes")
  Assert.isTrue(meshAcquisitions <= 2, "two work units perform at most two atomic mesh acquisitions")

  local staged = task:finish()
  local synchronous = loadScene(cache, s, {
    graphics = fakeGraphics(),
    imageAssets = SharedImagePoolFake.new(),
    meshBuilder = fakeMesh,
  })
  Assert.equal(staged.stats.meshCount, synchronous.stats.meshCount, "staged and synchronous mesh ownership agree")
  Assert.equal(
    staged.stats.textureCount,
    synchronous.stats.textureCount,
    "staged and synchronous image ownership agree"
  )
  Assert.equal(#staged.mapDraws, #synchronous.mapDraws, "staged and synchronous draw assembly agree")
  staged:release()
  synchronous:release()
end

-- A field scene task backed by an unprepared resource must yield "waiting"
-- and return zero consumed work while pending, matching FieldCoverage's
-- zero-consumption backoff contract, then produce a scene equivalent to the
-- synchronous path once preparation completes.
function T.build_task_waits_without_consuming_budget_until_prepared_assets_are_ready()
  local cache, geomPath, texPath = cacheFs()
  local s = scene({ material(0, texPath, { x = "clamp", y = "clamp" }) })
  s.mapBatches = { batch(geomPath, 0) }
  local queue = fakeAssetPreparationQueue(cache, { pendingPolls = 2 })
  local task =
    beginScene(cache, s, { assetPreparation = queue, decoded = queue.decoded, imageAssets = SharedImagePoolFake.new() })

  local guard = 0
  while not task:isReady() and guard < 100 do
    local consumed = task:advance(1)
    Assert.isTrue(consumed == 0 or consumed == 1, "advance never charges more than the supplied work budget")
    guard = guard + 1
  end
  Assert.isTrue(guard < 100, "the staged build must complete in a bounded number of advances")
  Assert.isTrue(
    #queue.requestLog > 0,
    "the build task must route resource acquisition through the injected preparation queue, not the synchronous path"
  )
  Assert.isTrue(
    queue.requestLog[1].priority == "prefetch" or queue.requestLog[1].priority == "demand",
    "field scene acquisition requests carry a valid queue priority"
  )

  local runtime = task:takeResult()
  local synchronous = loadScene(cache, s, { imageAssets = SharedImagePoolFake.new() })
  Assert.equal(#runtime.mapDraws, 1, "the frame-0 scene still assembles once preparation completes")
  Assert.deepEqual(
    runtime.mapDraws[1].center,
    synchronous.mapDraws[1].center,
    "prepared-path geometry matches the synchronous path"
  )
  runtime:release()
  synchronous:release()
end

-- Once resources are ready, realization is still bounded: a caller-supplied
-- budget of N charges at most N resource realizations per call, exactly like
-- the existing synchronous staged-build contract.
function T.ready_prepared_resources_still_respect_the_per_call_work_budget()
  local cache, geomPath, texPath = cacheFs()
  local s = scene({
    material(0, texPath, { x = "clamp", y = "clamp" }),
    material(1, texPath, { x = "repeat", y = "repeat" }),
  })
  s.mapBatches = { batch(geomPath, 0), batch(geomPath, 1) }
  local queue = fakeAssetPreparationQueue(cache, { pendingPolls = 0 })
  local images = SharedImagePoolFake.new()
  local task = beginScene(cache, s, { assetPreparation = queue, decoded = queue.decoded, imageAssets = images })

  Assert.equal(task:advance(1), 1, "one ready resource realization is charged as one work unit")
  Assert.isFalse(task:isReady(), "a multi-resource scene is not ready after one work unit")
  Assert.equal(task:advance(1), 1, "a second resume realizes at most one more resource")

  local runtime = task:finish()
  Assert.equal(runtime.stats.textureCount, 2, "both distinct-wrap textures are realized by completion")
  Assert.equal(images.uploads, 2, "both textures borrow through the shared owner")
  Assert.isTrue(#queue.requestLog >= 1, "mesh preparation for the scene is still routed through the injected queue")
  runtime:release()
end

-- The explicit synchronous entry blocks on a cold scene texture by sleeping for
-- the worker instead of polling it: the scene assembles once the owner replies,
-- within a bounded number of polls, and keeps no borrowed lease behind.
function T.synchronous_finish_blocks_on_a_cold_texture_without_hot_polling()
  local cache, geomPath, texPath = cacheFs()
  local s = scene({ material(0, texPath, { x = "clamp", y = "clamp" }) })
  s.mapBatches = { batch(geomPath, 0) }
  local images = ControllableImageOwner.new()
  local probe = SynchronousWaitProbe.new(images, { publishAfterSleeps = 2 })
  probe:install()
  local ok, runtimeOrFailure = pcall(loadScene, cache, s, { imageAssets = images })
  probe:restore()
  Assert.isTrue(ok, "the blocking scene load completes: " .. tostring(runtimeOrFailure))
  Assert.isTrue(probe.sleeps >= 1, "the blocking wait handed the CPU to the worker instead of polling it")
  Assert.equal(#runtimeOrFailure.mapDraws, 1, "the completed scene draws its terrain batch")
  runtimeOrFailure:release()
  Assert.equal(images:outstandingLeases(), 0, "releasing the completed scene returns every borrowed lease")
end

-- A synchronous finish() whose outstanding mesh preparation fails inside
-- wait() propagates that failure and releases the already-realized scene
-- image exactly once; releasing the failed task afterwards releases nothing
-- further.
function T.synchronous_finish_propagates_preparation_wait_failure_and_releases_realized_images()
  local cache, geomPath, texPath = cacheFs()
  local s = scene({ material(0, texPath, { x = "clamp", y = "clamp" }) })
  s.mapBatches = { batch(geomPath, 0) }
  local graphics = fakeGraphics()
  local queue = fakeAssetPreparationQueue(cache, {
    waitFailurePath = geomPath,
    waitFailureMessage = "injected preparation wait failure",
  })
  local images = SharedImagePoolFake.new()
  local task = beginScene(
    cache,
    s,
    { graphics = graphics, assetPreparation = queue, decoded = queue.decoded, imageAssets = images }
  )

  Assert.equal(task:advance(1), 1, "the first work unit borrows the texture")
  Assert.isFalse(task:isReady(), "the scene is not ready while the mesh preparation is pending")
  Assert.equal(task:advance(1), 0, "a pending preparation consumes no work budget")
  Assert.equal(images.uploads, 1, "the texture was borrowed before the mesh failed")
  local borrowed = images:findPhysical(texPath, { wrapX = "clamp", wrapY = "clamp" })
  Assert.notNil(borrowed, "the borrowed texture was published before the mesh failed")

  local err = Assert.throws(function()
    task:finish()
  end, "a failed preparation wait must fail the synchronous finish")
  Assert.isTrue(
    tostring(err):find("injected preparation wait failure", 1, true) ~= nil,
    "the preparation wait failure propagates: " .. tostring(err)
  )
  Assert.equal(images:stats().outstandingLeases, 0, "the failed finish returns the borrowed lease")
  Assert.equal(images:prune(), 1, "the failed finish leaves exactly one idle image")
  Assert.isTrue(borrowed.released, "the borrowed image is reclaimed exactly once")
  Assert.equal(borrowed.releaseCount, 1, "the failed finish reclaims the borrowed image exactly once")
  Assert.equal(#queue.cancelCalls, 1, "the failed wait cancels the ticket it was suspended on exactly once")
  Assert.equal(
    queue.cancelCalls[1],
    assert(queue.requestLog[#queue.requestLog].token, "the recorded mesh request carries no token"),
    "the cancelled ticket is the awaited mesh preparation"
  )
  Assert.equal(queue:outstandingTickets(), 0, "the failed finish leaves no ticket charged to the session queue")

  task:release()
  Assert.equal(images:stats().outstandingLeases, 0, "releasing the failed task returns nothing further")
  Assert.equal(#queue.cancelCalls, 1, "releasing the failed task cancels nothing twice")
end

-- A preparation that reports a terminal failure result (poll answers "failed"
-- without raising) fails the staged build with its ticket still owned, so the
-- unwind cancels it instead of leaving failed work charged to the session.
function T.terminal_preparation_failure_cancels_the_outstanding_ticket()
  local cache, geomPath, texPath = cacheFs()
  local s = scene({ material(0, texPath, { x = "clamp", y = "clamp" }) })
  s.mapBatches = { batch(geomPath, 0) }
  local queue = fakeAssetPreparationQueue(cache, {
    pollFailurePath = geomPath,
    pollFailureMessage = "injected GX failure",
  })
  local images = SharedImagePoolFake.new()
  local task = beginScene(cache, s, { assetPreparation = queue, decoded = queue.decoded, imageAssets = images })

  Assert.equal(task:advance(1), 1, "the first work unit borrows the texture")
  local err = Assert.throws(function()
    task:advance(1)
  end, "a terminal preparation failure fails the staged build")
  Assert.isTrue(
    tostring(err):find("injected GX failure", 1, true) ~= nil,
    "the preparation cause propagates: " .. tostring(err)
  )
  Assert.equal(#queue.cancelCalls, 1, "the failed build cancels its outstanding ticket exactly once")
  Assert.equal(queue.cancelCalls[1], assert(queue.requestLog[#queue.requestLog].token), "it cancels its own ticket")
  Assert.equal(queue:outstandingTickets(), 0, "the failed build leaves no ticket charged to the session queue")
  Assert.equal(images:stats().outstandingLeases, 0, "the failed build returns the borrowed lease")
  Assert.equal(images:prune(), 1, "the failed build leaves exactly one idle image")

  task:release()
  Assert.equal(#queue.cancelCalls, 1, "releasing the failed task cancels nothing twice")
end

-- Resolve the physical image a draw material renders from, whether the
-- material carries the image directly or wraps a borrowed lease record.
local function materialImage(material)
  local handle = material.image or material.lease or material.imageLease
  Assert.notNil(handle, "scene material exposes no image handle")
  if type(handle) == "table" and handle.lease ~= nil then
    handle = handle.lease
  end
  if type(handle) == "table" and handle.image ~= nil and handle.physicalKey ~= nil then
    return handle.image
  end
  return handle
end

-- A mesh builder recording every scene-owned mesh with a release flag, so
-- the test can prove each scene release frees exactly its own meshes.
local function trackedMeshes(store)
  return function()
    local mesh = { released = false }
    mesh.release = function()
      mesh.released = true
    end
    store[#store + 1] = mesh
    return mesh
  end
end

-- Two adjacent scenes compiled against the identical texture path and
-- sampler state must resolve to one physical image borrowed from the
-- session owner: staging both uploads once, releasing the first scene
-- keeps the survivor rendering, and releasing the second returns the last
-- lease while each scene frees only its own meshes.
function T.overlapping_neighbor_scenes_share_one_physical_image()
  local cache, geomPath, texPath = cacheFs()
  local sceneA = scene({ material(0, texPath, { x = "clamp", y = "clamp" }) })
  sceneA.mapBatches = { batch(geomPath, 0) }
  local sceneB = scene({ material(0, texPath, { x = "clamp", y = "clamp" }) })
  sceneB.mapBatches = { batch(geomPath, 0) }
  local pool = SharedImagePoolFake.new()
  local meshesA, meshesB = {}, {}
  local runtimeA = loadScene(cache, sceneA, {
    graphics = fakeGraphics(),
    meshBuilder = trackedMeshes(meshesA),
    imageAssets = pool,
  })
  local runtimeB = loadScene(cache, sceneB, {
    graphics = fakeGraphics(),
    meshBuilder = trackedMeshes(meshesB),
    imageAssets = pool,
  })

  Assert.equal(pool.uploads, 1, "two scenes sharing one texture path and sampler resolve a single physical image")
  local imageA = materialImage(runtimeA.mapDraws[1].material)
  local imageB = materialImage(runtimeB.mapDraws[1].material)
  Assert.equal(imageA, imageB, "both scenes render from the same physical image")
  Assert.equal(pool:stats().outstandingLeases, 2, "each staged scene holds its own lease")

  runtimeA:release()
  Assert.isFalse(imageB.released, "releasing the first scene must not release the image under the survivor")
  Assert.equal(materialImage(runtimeB.mapDraws[1].material), imageB, "the surviving scene still renders its image")
  Assert.equal(pool:stats().outstandingLeases, 1, "only the released scene returned its lease")
  for _, mesh in ipairs(meshesA) do
    Assert.isTrue(mesh.released, "the released scene frees its owned meshes")
  end
  for _, mesh in ipairs(meshesB) do
    Assert.isFalse(mesh.released, "the surviving scene keeps its owned meshes")
  end

  runtimeB:release()
  Assert.equal(pool:stats().outstandingLeases, 0, "the second release returns the last lease")
  for _, mesh in ipairs(meshesB) do
    Assert.isTrue(mesh.released, "the second release frees its owned meshes")
  end
  Assert.equal(pool:prune(), 1, "the idle shared image is reclaimed exactly once")
  Assert.isTrue(imageB.released, "no lease outlives the shared image")
  pool:dispose()
end

return {
  metadata = { capabilities = { "graphics" } },
  tests = T,
}
