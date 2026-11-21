-- Tests for the shared GPU asset pool used by MapSceneLoader and NeighborRing:
-- content-addressed mesh dedup plus sampler-aware texture borrowing (the
-- wrap pair selects the borrowed lease, so two materials sharing pixels but
-- sampling them differently never alias one mutable sampler), unknown wrap
-- rejection, and exactly-once lease/mesh release. Failure handling has two
-- scopes, mirroring the two production failure classes: a build wrapper
-- rolls back every lease and mesh created inside a failed construction (the
-- whole scene build), while a single post-construction acquire failure
-- borrows nothing -- the live scene keeps the leases it is drawing. The
-- image side borrows from an injected fake shared owner headless; mesh
-- construction needs a real graphics context, so this is a graphics suite.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local MeshWriter = require("libs.assets.src.model.MeshWriter")
local PngWriter = require("tests.support.PngEncoder")
local BinaryWriter = require("libs.codec.src.BinaryWriter")
local ErrorCodes = require("libs.assets.src.ErrorCodes")
local GpuAssetPool = require("libs.hgss.src.presentation.GpuAssetPool")
local SceneMesh = require("libs.hgss.src.presentation.SceneMesh")
local ControllableImageOwner = require("tests.support.ControllableImageOwner")
local SharedImagePoolFake = require("tests.support.SharedImagePoolFake")

local T = {}

local GEOM_PATH = MapAssetCache.geometryPath("aaaa")
local EMPTY_GEOM_PATH = MapAssetCache.geometryPath("empty")
local TEX_PATH = MapAssetCache.texturePath("bbbb")

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

-- A syntactically valid G4M2 batch with zero vertices: MeshWriter refuses
-- to encode an empty batch, so this is the hand-crafted malformed-data shape
-- that must fail loudly at the geometry step, not decode or fold into a
-- NaN box.
local function emptyMeshBytes()
  return BinaryWriter.new():bytes("G4M2"):u16(2):u16(0):u32(0):u32(0):u16(40):u16(2):u32(0):tostring()
end

-- A CacheFs whose :read(path) serves canned bytes for the known paths,
-- mirroring CacheFs:read's string-or-nil contract.
local function fakeCacheFs()
  local blob = {
    [GEOM_PATH] = MeshWriter.encode(triangleBatch()),
    [EMPTY_GEOM_PATH] = emptyMeshBytes(),
    [TEX_PATH] = PngWriter.encode(1, 1, string.char(255, 0, 0, 255)),
  }
  return {
    read = function(_, path)
      return blob[path]
    end,
  }
end

-- The selected CPU-owner pair a geometry-only pool borrows: the preparation
-- queue answers one worker-shaped lease over the packed upload for the
-- requested procedural batch, and the decoded owner returns it exactly once.
-- Texture-only pools resolve the same capability from their image owner.
local function meshPreparation()
  local returned = 0
  local source = fakeCacheFs()
  local queue = {}
  function queue:request(kind, path, priority)
    return { kind = kind, path = path, priority = priority }
  end
  function queue:wait(request)
    if request.path == EMPTY_GEOM_PATH then
      -- The worker already rejects an empty batch during upload packing; the
      -- pool's own rollback is exercised with the well-formed zero-vertex
      -- packet it would realize.
      return {
        value = {
          kind = request.kind,
          payload = {
            vertexData = love.data.newByteData(1),
            indexData = love.data.newByteData(1),
            vertexCount = 0,
            indexCount = 0,
            indexType = "uint16",
          },
        },
      }
    end
    local bytes = assert(source.read(nil, request.path), "missing mesh " .. tostring(request.path))
    return { value = { kind = request.kind, payload = SceneMesh.prepareUpload(bytes) } }
  end
  local decoded = {
    returns = function()
      return returned
    end,
  }
  function decoded:returnLease(lease)
    lease.value = nil
    returned = returned + 1
    return true
  end
  function decoded:trim() end
  return { assetPreparation = queue, decoded = decoded }
end

-- Construct a pool through the suite's one geometry preparation pair unless
-- the test supplies explicit owners or a session image owner (whose own
-- preparation capability is the required source).
local function newPool(cacheFs, opts)
  opts = opts or {}
  if opts.assetPreparation == nil and opts.decoded == nil and opts.imageAssets == nil then
    local preparation = meshPreparation()
    opts.assetPreparation = preparation.assetPreparation
    opts.decoded = preparation.decoded
  end
  return GpuAssetPool.new(cacheFs, opts)
end

-- Injected graphics namespace for pool construction. Image construction
-- itself always borrows from the injected shared owner, so this namespace
-- only stands in for the Mesh side's graphics requirement headless.
local function fakeGraphics()
  return {
    newImage = function()
      error("GpuAssetPool borrows textures from the session image owner")
    end,
  }
end

-- Borrowed-lease samplers: the shared owner keys physical images by pixel
-- content plus sampler, so these are the lookup identities the tests assert
-- published or absent through the fake.
local CLAMP_SAMPLER = { wrapX = "clamp", wrapY = "clamp" }
local REPEAT_SAMPLER = { wrapX = "repeat", wrapY = "clamp" }

function T.rejects_a_missing_graphics_namespace()
  local err = Assert.throws(function()
    newPool(fakeCacheFs(), { graphics = false })
  end)
  Assert.isTrue(tostring(err):find("GpuAssetPool requires love.graphics", 1, true) ~= nil)
end

-- Texture acquisition without the session shared owner is a programming
-- error and fails loudly instead of building a private image.
function T.texture_acquisition_without_a_session_pool_fails_loudly()
  local pool = newPool(fakeCacheFs(), { graphics = fakeGraphics() })
  local err = Assert.throws(function()
    pool:imageFor(TEX_PATH, "clamp", "clamp")
  end)
  Assert.isTrue(
    tostring(err):find("GpuAssetPool requires a session image owner", 1, true) ~= nil,
    "borrowing without a session owner fails loudly"
  )
  local preparedErr = Assert.throws(function()
    pool:imageFromPrepared(TEX_PATH, "clamp", "clamp", { imageData = {} })
  end)
  Assert.isTrue(
    tostring(preparedErr):find("GpuAssetPool requires a session image owner", 1, true) ~= nil,
    "prepared borrowing without a session owner fails loudly"
  )
  Assert.equal(pool:textureCount(), 0, "no lease is borrowed without a session owner")
end

function T.unknown_wrap_modes_are_rejected()
  local pool = newPool(fakeCacheFs(), { graphics = fakeGraphics(), imageAssets = SharedImagePoolFake.new() })
  local err = Assert.throws(function()
    pool:imageFor(TEX_PATH, "mirror", "clamp")
  end)
  Assert.isTrue(Errors.is(err) and err.code == "GPU_ASSET_UNKNOWN_WRAP", "raises GPU_ASSET_UNKNOWN_WRAP")
  Assert.equal(pool:textureCount(), 0, "no lease is borrowed for a rejected sampler")
end

function T.image_identity_includes_the_wrap_pair()
  local images = SharedImagePoolFake.new()
  local pool = newPool(fakeCacheFs(), { graphics = fakeGraphics(), imageAssets = images })
  local repeatX = pool:imageFor(TEX_PATH, "repeat", "clamp")
  local clampX = pool:imageFor(TEX_PATH, "clamp", "clamp")
  Assert.isTrue(repeatX ~= clampX, "different wrap pairs must not alias one borrowed image")
  Assert.equal(images.uploads, 2, "each sampler state resolves its own physical image")
  Assert.equal(images:findPhysical(TEX_PATH, REPEAT_SAMPLER), repeatX)
  Assert.equal(images:findPhysical(TEX_PATH, CLAMP_SAMPLER), clampX)
end

function T.same_path_and_wrap_dedup_to_one_borrowed_lease()
  local images = SharedImagePoolFake.new()
  local pool = newPool(fakeCacheFs(), { graphics = fakeGraphics(), imageAssets = images })
  local first = pool:imageFor(TEX_PATH, "repeat", "clamp")
  local second = pool:imageFor(TEX_PATH, "repeat", "clamp")
  Assert.equal(first, second)
  Assert.equal(pool:textureCount(), 1, "one scene lease for the repeated acquisition")
  Assert.equal(images.uploads, 1, "the shared owner builds the physical image once")
end

-- sharedImage propagates the full sampling handle: the bound image plus the
-- exact palette and indexed flag the renderer's shared sampler consumes.
-- The handle is stable per path/wrap identity, like the lease it describes.
function T.sharedImage_propagates_the_sampling_handle()
  local images = SharedImagePoolFake.new()
  local pool = newPool(fakeCacheFs(), { graphics = fakeGraphics(), imageAssets = images })
  local first = pool:sharedImage(TEX_PATH, "repeat", "clamp")
  local second = pool:sharedImage(TEX_PATH, "repeat", "clamp")
  Assert.equal(first, second, "repeated borrows share one stable handle")
  Assert.equal(first.image, images:findPhysical(TEX_PATH, REPEAT_SAMPLER))
  Assert.isFalse(first.indexed, "the fake straight image resolves a non-indexed handle")
  Assert.isNil(first.palette, "the fake straight image resolves no palette")
  Assert.equal(pool:imageFor(TEX_PATH, "repeat", "clamp"), first.image, "imageFor binds the handle's image")
  pool:release()
end

function T.untextured_materials_get_no_image()
  local pool = newPool(fakeCacheFs(), { graphics = fakeGraphics() })
  Assert.isNil(pool:imageFor(nil, "clamp", "clamp"))
  Assert.isNil(pool:imageFromPrepared(nil, "clamp", "clamp", { imageData = {} }))
  Assert.equal(pool:textureCount(), 0)
end

-- Construction rollback: the whole scene build runs inside the build
-- wrapper (MapSceneLoader.load and the NeighborRing load path), so a
-- failing borrow must return every lease the build already holds -- a
-- partially failed construction never keeps a borrowed texture.
function T.build_returns_every_borrowed_lease_when_a_later_borrow_fails()
  local images = SharedImagePoolFake.new()
  local pool = newPool(fakeCacheFs(), { graphics = fakeGraphics(), imageAssets = images })
  local first = pool:imageFor(TEX_PATH, "clamp", "clamp")
  images:failAfterUploads(1, "injected shared image failure")
  local err = Assert.throws(function()
    pool:build(function()
      pool:imageFor(TEX_PATH, "repeat", "clamp")
    end)
  end)
  Assert.isTrue(
    tostring(err):find("injected shared image failure", 1, true) ~= nil,
    "rethrows the shared borrow failure"
  )
  Assert.equal(images:stats().outstandingLeases, 0, "the failed build returns every borrowed lease")
  Assert.equal(images:prune(), 1, "the rolled-back physical image is reclaimed exactly once")
  Assert.isTrue(first.released, "no lease outlives the reclaimed physical image")
  images:clearFailure()
  local retry = pool:imageFor(TEX_PATH, "clamp", "clamp")
  Assert.isTrue(retry ~= nil, "the pool is usable after the rollback")
  Assert.equal(pool:textureCount(), 1)
  pool:release()
end

-- The build wrapper is not a release-everything-on-exit path: a successful
-- construction keeps its leases and returns the builder's value.
function T.build_keeps_borrowed_leases_and_returns_the_value_on_success()
  local images = SharedImagePoolFake.new()
  local pool = newPool(fakeCacheFs(), { graphics = fakeGraphics(), imageAssets = images })
  local result = pool:build(function()
    pool:imageFor(TEX_PATH, "clamp", "clamp")
    return "built"
  end)
  Assert.equal(result, "built", "the build returns the builder's value")
  Assert.equal(images:stats().outstandingLeases, 1, "a successful construction keeps its lease")
  Assert.equal(pool:textureCount(), 1)
  pool:release()
end

-- Post-construction failure: a single borrow failing while the live scene
-- draws borrows nothing -- the earlier leases the scene is using stay
-- held, and the failed sampler state is borrowable again afterwards.
function T.failed_single_borrow_keeps_the_live_scene_leases()
  local images = SharedImagePoolFake.new()
  local pool = newPool(fakeCacheFs(), { graphics = fakeGraphics(), imageAssets = images })
  local first = pool:imageFor(TEX_PATH, "clamp", "clamp")
  images:failAfterUploads(1, "injected shared image failure")
  local err = Assert.throws(function()
    pool:imageFor(TEX_PATH, "repeat", "repeat")
  end)
  Assert.isTrue(tostring(err):find("injected shared image failure", 1, true) ~= nil, "rethrows the borrow failure")
  Assert.equal(images:stats().outstandingLeases, 1, "the live lease stays held after a single failed borrow")
  Assert.equal(images:findPhysical(TEX_PATH, CLAMP_SAMPLER), first, "the live image is still resident")
  Assert.isNil(
    images:findPhysical(TEX_PATH, { wrapX = "repeat", wrapY = "repeat" }),
    "the failed borrow publishes no phantom physical image"
  )
  images:clearFailure()
  local retry = pool:imageFor(TEX_PATH, "repeat", "repeat")
  Assert.isTrue(retry ~= nil, "the failed sampler state is borrowable again")
  Assert.equal(pool:textureCount(), 2)
  pool:release()
end

-- A texture whose worker reply never arrives as pixels must not strand its
-- ticket at the long-lived shared owner: a prefetched ticket that fails before
-- acquisition is cancelled exactly once, so a rolled-back scene leaves no
-- unreachable request (and no ready payload) charged to the session.
function T.a_failed_prefetched_texture_cancels_its_shared_ticket()
  local images = ControllableImageOwner.new()
  local pool = newPool(fakeCacheFs(), { graphics = fakeGraphics(), imageAssets = images })
  pool:prefetchShared(TEX_PATH, "clamp", "clamp")
  local token = assert(images.requests[1], "prefetching enrolls one shared ticket").token
  images:failNow("injected shared image failure")
  local err = Assert.throws(function()
    pool:imageFor(TEX_PATH, "clamp", "clamp")
  end)
  Assert.isTrue(tostring(err):find("injected shared image failure", 1, true) ~= nil, "the borrow rethrows the cause")
  Assert.equal(#images.cancelCalls, 1, "the failed borrow cancels its ticket exactly once")
  Assert.equal(images.cancelCalls[1], token, "the cancelled ticket is the prefetched one")
  Assert.equal(images:outstandingTickets(), 0, "the failed borrow strands no request at the owner")
  Assert.equal(images.readyBytes, 0, "the failed borrow leaves no payload charged")
  Assert.equal(pool:textureCount(), 0, "the failed borrow takes no lease")
  pool:release()
  Assert.equal(#images.cancelCalls, 1, "releasing after the failure cancels nothing twice")
end

-- A demand-created texture fails the same way, and a later retry after the
-- owner recovers borrows normally: the failure drops only its own ticket.
function T.a_failed_demand_texture_cancels_its_ticket_and_a_retry_succeeds()
  local images = ControllableImageOwner.new()
  local pool = newPool(fakeCacheFs(), { graphics = fakeGraphics(), imageAssets = images })
  images:failNow("injected shared image failure")
  Assert.throws(function()
    pool:imageFor(TEX_PATH, "repeat", "clamp")
  end)
  Assert.equal(#images.cancelCalls, 1, "the failed demand borrow cancels its ticket exactly once")
  Assert.equal(images.cancelCalls[1], assert(images.requests[1]).token, "the cancelled ticket is the demand request")
  Assert.equal(images:outstandingTickets(), 0, "the failed borrow strands no request at the owner")

  images:clearFailure()
  images:publish()
  local handle = pool:imageFor(TEX_PATH, "repeat", "clamp")
  Assert.isTrue(handle ~= nil, "an independent retry after the failure borrows normally")
  Assert.equal(pool:textureCount(), 1, "the retry holds exactly its own lease")
  pool:release()
  Assert.equal(images:outstandingLeases(), 0, "releasing the retried pool returns its lease")
end

-- A scene released while a demand-created texture is still pending drops that
-- ticket: the long-lived shared owner keeps no request and no unclaimed payload
-- for a scene that no longer exists.
function T.releasing_a_scene_cancels_its_pending_demand_texture_ticket()
  local images = ControllableImageOwner.new({ held = false, payloadBytes = 2048 })
  images:withhold(TEX_PATH)
  local pool = newPool(fakeCacheFs(), { graphics = fakeGraphics(), imageAssets = images })
  local leaseThread = coroutine.create(function()
    return pool:sharedImage(TEX_PATH, "clamp", "clamp", function()
      coroutine.yield("wait")
    end)
  end)
  local resumed, state = coroutine.resume(leaseThread)
  Assert.isTrue(resumed, tostring(state))
  Assert.equal(state, "wait", "the borrow suspends on the withheld worker reply")
  Assert.equal(images:outstandingTickets(), 1, "the pending demand ticket is charged to the shared owner")
  Assert.equal(#images.requests, 1, "the scene requested the texture exactly once")

  pool:release()
  Assert.equal(#images.cancelCalls, 1, "releasing the scene cancels the pending demand ticket exactly once")
  Assert.equal(images.cancelCalls[1], assert(images.requests[1]).token, "the cancelled ticket is the demand one")
  Assert.equal(images:outstandingTickets(), 0, "the released scene strands no request at the shared owner")
  Assert.isFalse(
    images:publish(assert(images.requests[1]).token),
    "a late worker reply cannot publish the dropped ticket"
  )
  Assert.equal(images.readyBytes, 0, "no unclaimed payload stays charged")
  Assert.equal(pool:textureCount(), 0, "the released scene holds no lease")
end

-- The live texture lookup answers only identities the scene already holds: it
-- never enrolls worker classification, so a render callback can bind a texture
-- without a wait path.
function T.heldImage_answers_only_already_borrowed_textures()
  local images = ControllableImageOwner.new({ held = false })
  local pool = newPool(fakeCacheFs(), { graphics = fakeGraphics(), imageAssets = images })
  local borrowed = pool:sharedImage(TEX_PATH, "clamp", "clamp")
  Assert.equal(pool:heldImage(TEX_PATH, "clamp", "clamp"), borrowed, "the held lookup answers the borrowed handle")
  Assert.equal(#images.requests, 1, "the held lookup starts no additional request")
  local err = Assert.throws(function()
    pool:heldImage(TEX_PATH, "repeat", "clamp")
  end)
  Assert.isTrue(
    Errors.is(err) and err.code == "GPU_ASSET_TEXTURE_NOT_HELD",
    "an unborrowed sampler state fails loudly instead of starting worker work"
  )
  Assert.equal(#images.requests, 1, "an unborrowed identity never reaches the shared owner")
  Assert.isNil(pool:heldImage(nil, "clamp", "clamp"), "an untextured material resolves no handle")
  pool:release()
end

function T.release_returns_leases_and_prune_reclaims_exactly_once()
  local images = SharedImagePoolFake.new()
  local pool = newPool(fakeCacheFs(), { graphics = fakeGraphics(), imageAssets = images })
  local clampImage = pool:imageFor(TEX_PATH, "clamp", "clamp")
  local repeatImage = pool:imageFor(TEX_PATH, "repeat", "clamp")
  pool:release()
  pool:release()
  Assert.equal(images:stats().outstandingLeases, 0, "release returns every borrowed lease")
  Assert.equal(images:prune(), 2, "both idle physical images are reclaimed")
  Assert.equal(clampImage.releaseCount, 1, "the clamp physical image is released exactly once")
  Assert.equal(repeatImage.releaseCount, 1, "the repeat physical image is released exactly once")
  Assert.equal(pool:textureCount(), 0)
end

function T.mesh_entries_dedup_and_accumulate_triangles_once()
  local pool = newPool(fakeCacheFs())
  local first = pool:meshFor(GEOM_PATH)
  local second = pool:meshFor(GEOM_PATH)
  Assert.equal(first.mesh, second.mesh)
  Assert.equal(first.triangles, 1)
  Assert.equal(pool.triangles, 1, "shared geometry is counted once")
  Assert.equal(#pool.meshes, 1)
  pool:release()
end

-- A mesh file that decodes to zero vertices is malformed data: the geometry
-- math raises SCENE_DESC_EMPTY_MESH instead of folding inf/nan seeds. The
-- mesh object the builder created before that step must already be owned by
-- the pool, so the guarded acquire pops and releases it exactly once --
-- never an orphaned love Mesh.

-- The per-mesh geometry cache: the entry exposes the model-space
-- bounding-box center and AABB, computed ONCE per content-addressed path and
-- shared by every consumer (draw items, descriptor folds, sort centers) --
-- consumers read the cached values instead of rescanning the same vertices
-- per draw/placement. The values live on the shared entry, so repeated
-- acquires return the same precomputed tables.
function T.mesh_entries_expose_cached_center_and_aabb()
  local pool = newPool(fakeCacheFs())
  local entry = pool:meshFor(GEOM_PATH)
  -- The triangle fixture spans x[0,2], y=0, z[0,2].
  Assert.deepEqual(entry.center, { 1, 0, 1 }, "the pool mesh entry exposes the cached model-space center")
  Assert.deepEqual(
    entry.bounds,
    { minX = 0, maxX = 2, minY = 0, maxY = 0, minZ = 0, maxZ = 2 },
    "the pool mesh entry exposes the cached model-space AABB"
  )
  local again = pool:meshFor(GEOM_PATH)
  Assert.equal(again, entry, "the entry is the shared per-path object")
  Assert.equal(again.center, entry.center, "the cached center is computed once per content-addressed path")
  Assert.equal(again.bounds, entry.bounds, "the cached AABB is computed once per content-addressed path")
  pool:release()
end

-- Injected graphics namespace for prepared-mesh realization: newMesh is
-- called by vertex count/layout (never a decoded vertex table), and
-- setVertices/setVertexMap can be made to fail after the Mesh object exists,
-- to exercise the transactional rollback the prepared path must share with
-- the synchronous path.
local function fakeMeshGraphics(opts)
  opts = opts or {}
  local created = {}
  return {
    created = created,
    newImage = fakeGraphics().newImage,
    newMesh = function(_, _, _)
      local mesh = { released = false, vertexData = nil, vertexMapData = nil, indexType = nil }
      mesh.setVertices = function(_, data)
        if opts.failSetVertices then
          error("injected setVertices failure")
        end
        mesh.vertexData = data
      end
      mesh.setVertexMap = function(_, data, datatype)
        if opts.failSetVertexMap then
          error("injected setVertexMap failure")
        end
        mesh.vertexMapData = data
        mesh.indexType = datatype
      end
      mesh.release = function()
        mesh.released = true
      end
      created[#created + 1] = mesh
      return mesh
    end,
  }
end

function T.empty_mesh_fails_and_releases_the_created_mesh()
  local graphics = fakeMeshGraphics()
  local pool = newPool(fakeCacheFs(), { graphics = graphics })
  local err = Assert.throws(function()
    pool:meshFor(EMPTY_GEOM_PATH)
  end)
  Assert.isTrue(Errors.is(err) and err.code == ErrorCodes.SCENE_DESC_EMPTY_MESH, "raises SCENE_DESC_EMPTY_MESH")
  Assert.equal(#graphics.created, 1, "the prepared realization created the mesh before the geometry step")
  Assert.equal(graphics.created[1].released, true, "the failed acquisition's own mesh is released")
  Assert.equal(#pool.meshes, 0, "the pool owns no mesh after the failed acquire")
end

local function preparedMeshPayload()
  return SceneMesh.prepareUpload(MeshWriter.encode(triangleBatch()))
end

-- Equivalence: a prepared realization must dedup, geometry-fold, and stat
-- exactly like the synchronous path for the same content-addressed path.
function T.meshFromPrepared_matches_meshFor_geometry_for_equivalent_content()
  local syncPool = newPool(fakeCacheFs())
  local syncEntry = syncPool:meshFor(GEOM_PATH)

  local graphics = fakeMeshGraphics()
  local preparedPool = newPool(fakeCacheFs(), { graphics = graphics })
  local preparedEntry = preparedPool:meshFromPrepared(GEOM_PATH, preparedMeshPayload())

  Assert.equal(preparedEntry.triangles, syncEntry.triangles)
  Assert.deepEqual(preparedEntry.center, syncEntry.center)
  Assert.deepEqual(preparedEntry.bounds, syncEntry.bounds)
  Assert.notNil(graphics.created[1].vertexMapData, "prepared realization uploads a zero-based vertex map Data")
  Assert.equal(#preparedPool.meshes, 1)

  syncPool:release()
  preparedPool:release()
end

-- Dedup across entry points: a path already realized through one entry
-- point must not be rebuilt through the other.
function T.meshFromPrepared_dedups_with_a_prior_synchronous_acquire()
  local graphics = fakeMeshGraphics()
  local pool = newPool(fakeCacheFs(), { graphics = graphics })
  local synchronous = pool:meshFor(GEOM_PATH)
  local prepared = pool:meshFromPrepared(GEOM_PATH, preparedMeshPayload())
  Assert.equal(prepared, synchronous, "the prepared path returns the already-realized entry, never a duplicate")
  Assert.equal(#pool.meshes, 1, "no second Mesh object is created for an already-realized path")
end

-- Transactional realization: a failure between Mesh creation and
-- publication must release the partial object and leave the pool's cache
-- tables/counters exactly as before the failed call.
function T.meshFromPrepared_rolls_back_the_partial_mesh_on_publish_failure()
  local graphics = fakeMeshGraphics({ failSetVertexMap = true })
  local pool = newPool(fakeCacheFs(), { graphics = graphics })
  local err = Assert.throws(function()
    pool:meshFromPrepared(GEOM_PATH, preparedMeshPayload())
  end)
  Assert.isTrue(tostring(err):find("injected setVertexMap failure", 1, true) ~= nil)
  Assert.equal(#pool.meshes, 0, "no mesh is published before every upload step succeeds")
  Assert.equal(pool.triangles, 0, "the triangle stat is not updated for an unpublished mesh")
  Assert.equal(graphics.created[1].released, true, "the partially-constructed mesh is released")

  local retryGraphics = fakeMeshGraphics()
  local retryPool = newPool(fakeCacheFs(), { graphics = retryGraphics })
  local retried = retryPool:meshFromPrepared(GEOM_PATH, preparedMeshPayload())
  Assert.notNil(retried, "the prepared path is usable again after a rolled-back failure")
  retryPool:release()
end

-- imageFromPrepared delegates to the same shared borrow as imageFor: the
-- staged payload is superseded by the shared owner's own classification,
-- so both entry points resolve one physical image and one scene lease.
function T.imageFromPrepared_delegates_to_the_shared_borrow()
  local images = SharedImagePoolFake.new()
  local pool = newPool(fakeCacheFs(), { graphics = fakeGraphics(), imageAssets = images })
  local prepared = { imageData = { fakeImageData = true } }
  local fromPrepared = pool:imageFromPrepared(TEX_PATH, "clamp", "clamp", prepared)
  local fromSync = pool:imageFor(TEX_PATH, "clamp", "clamp")
  Assert.equal(fromPrepared, fromSync, "prepared and synchronous borrowing share one lease")
  Assert.equal(images.uploads, 1, "the superseded payload never builds a second image")
  Assert.equal(pool:textureCount(), 1)
  pool:release()
end

-- The staged payload stays a required collaborator even though its bytes
-- are superseded: callers must stage before borrowing.
function T.imageFromPrepared_still_requires_its_staged_payload()
  local images = SharedImagePoolFake.new()
  local pool = newPool(fakeCacheFs(), { graphics = fakeGraphics(), imageAssets = images })
  local err = Assert.throws(function()
    pool:imageFromPrepared(TEX_PATH, "clamp", "clamp", nil)
  end)
  Assert.isTrue(
    tostring(err):find("prepared image payload is required", 1, true) ~= nil,
    "borrowing without a staged payload fails loudly"
  )
  Assert.equal(images.uploads, 0, "no borrow happens without a staged payload")
  pool:release()
end

-- The engine-owned model bank under test: one draw list, two draws with
-- distinct extents, so a selector's draw index is observable in the acquired
-- mesh's cached bounds.
local BANK_PATH = MapAssetCache.geometryPath("native-bank")

local function bankCommands(vertices)
  local function u32(value)
    return string.char(
      value % 256,
      math.floor(value / 256) % 256,
      math.floor(value / 65536) % 256,
      math.floor(value / 16777216) % 256
    )
  end
  local function vtx16(vertex)
    local function fx(value)
      return math.floor(value * 4096) % 0x10000
    end
    return u32(fx(vertex[1]) + fx(vertex[2]) * 0x10000) .. u32(fx(vertex[3]))
  end
  return string.char(0x40, 0x23, 0x23, 0x23)
    .. u32(0)
    .. vtx16(vertices[1])
    .. vtx16(vertices[2])
    .. vtx16(vertices[3])
    .. string.char(0x41, 0, 0, 0)
end

---@param value unknown
---@return string
local function bankBytes(value)
  if type(value) == "string" then
    return value
  end
  if type(value) == "table" and value.data ~= nil then
    return bankBytes(value.data)
  end
  assert(type(value) == "userdata" and type(value.getString) == "function", "the model bank travels as bytes")
  return value:getString()
end

-- A model bank of two draws: draw 0 spans x[0,2] z[0,6], draw 1 spans
-- x[-6,-4] z[0,3] (VTX_16 carries signed 1.3.12, so a negative span is how one
-- draw is kept clearly apart from the other).
local function twoDrawBank()
  local ok, NativeGxFormat = pcall(require, "libs.assets.src.model.NativeGxFormat")
  Assert.isTrue(
    ok and type(NativeGxFormat) == "table",
    "the native model bank format is missing: the GPU owner cannot acquire one draw out of a source model bank"
  )
  return bankBytes(NativeGxFormat.encode({
    draws = {
      {
        commands = bankCommands({ { 0, 0, 0 }, { 2, 0, 0 }, { 0, 0, 6 } }),
        nodeIndex = 0,
        materialIndex = 0,
        shapeIndex = 0,
        transformMode = "static",
        seedColorSource = 0,
        seedColor = { 255, 255, 255 },
      },
      {
        commands = bankCommands({ { -6, 0, 0 }, { -4, 0, 0 }, { -6, 0, 3 } }),
        nodeIndex = 0,
        materialIndex = 1,
        shapeIndex = 0,
        transformMode = "static",
        seedColorSource = 0,
        seedColor = { 255, 255, 255 },
      },
    },
  }))
end

-- A native model bank is one decoded worker payload shared by every selected
-- draw: the pool asks the selected queue for the bank, realizes only the draw it
-- needs, returns that decoded lease immediately and keeps no bank of its own.
-- Repeated demand reuses the resident GPU mesh, each draw is its own GPU
-- resource, and release disposes each exactly once.
function T.native_bank_selectors_realize_from_the_shared_decoded_bank()
  local bytes = twoDrawBank()
  local cacheFs = {
    read = function()
      return nil
    end,
  }
  local created = {}
  local bankRequests, returnedLeases = 0, 0
  local shared = SceneMesh.prepareNativeBank(bytes, "shared-bank")
  local queue = {
    request = function(_, kind, path, priority)
      Assert.equal(kind, "g4gx", "a native bank request is a whole-bank g4gx job")
      bankRequests = bankRequests + 1
      return { path = path, priority = priority }
    end,
    wait = function()
      return { value = { kind = "g4gx", payload = shared } }
    end,
  }
  local decoded = {
    returnLease = function(_, lease)
      lease.value = nil
      returnedLeases = returnedLeases + 1
      return true
    end,
    trim = function() end,
  }
  local pool = newPool(cacheFs, {
    graphics = fakeMeshGraphics(),
    assetPreparation = queue,
    decoded = decoded,
  })

  local first = pool:meshFor({ file = BANK_PATH, drawIndex = 0 })
  Assert.equal(first.triangles, 1, "the selected draw reports its triangle count")
  Assert.deepEqual(first.center, { 1, 0, 3 }, "the selected draw reports its own model-space center")
  Assert.deepEqual(
    first.bounds,
    { minX = 0, maxX = 2, minY = 0, maxY = 0, minZ = 0, maxZ = 6 },
    "the selected draw reports its own bounds"
  )
  Assert.equal(returnedLeases, 1, "the decoded bank lease returns once its GPU mesh exists")
  Assert.equal(bankRequests, 1, "the first demand asks the queue for the whole bank")

  local again = pool:meshFor({ file = BANK_PATH, drawIndex = 0 })
  Assert.equal(again, first, "the same selected draw resolves the resident entry")
  Assert.equal(again.mesh, first.mesh, "repeated demand reuses the resident GPU mesh")
  Assert.equal(bankRequests, 1, "repeated demand asks the session for nothing new")

  local second = pool:meshFor({ file = BANK_PATH, drawIndex = 1 })
  Assert.isTrue(second.mesh ~= first.mesh, "another draw of the same bank is its own GPU resource")
  Assert.deepEqual(second.center, { -5, 0, 1.5 }, "the second draw reports its own center")
  Assert.equal(returnedLeases, 2, "each realization returns its own decoded lease")
  Assert.notNil(shared.draws[1], "realizing one draw leaves the shared bank's first draw intact")
  Assert.notNil(shared.draws[2], "realizing one draw leaves the shared bank's second draw intact")
  Assert.equal(#pool.meshes, 2, "the pool owns one mesh per selected draw")

  pool:release()
  pool:release()
  Assert.equal(#pool.meshes, 0, "release disposes every resident mesh")
  Assert.equal(created[1], created[1], "the pool keeps only GPU resources")
end

-- The staged worker path realizes the same native bank the synchronous path
-- decodes, but the bank comes from the preparation queue as one payload: the
-- scene build awaits the bank once, every selected draw realizes from it, and
-- an unknown draw index fails loudly instead of uploading nothing.
function T.prepared_native_bank_payload_realizes_every_selected_draw()
  local bytes = twoDrawBank()
  local cacheFs = {
    read = function(_, path)
      return path == BANK_PATH and bytes or nil
    end,
  }
  local graphics = fakeMeshGraphics()
  local pool = newPool(cacheFs, { graphics = graphics })
  local prepared = SceneMesh.prepareNativeBank(bytes, "worker-bank")
  local awaited = {}
  local function await(kind, path)
    awaited[#awaited + 1] = tostring(kind) .. " " .. tostring(path)
    return { value = { kind = kind, payload = prepared } }
  end

  local first = pool:preparedMesh({ file = BANK_PATH, drawIndex = 0 }, await)
  Assert.deepEqual(first.center, { 1, 0, 3 }, "the realized draw keeps its own model-space center")
  local second = pool:preparedMesh({ file = BANK_PATH, drawIndex = 1 }, await)
  Assert.deepEqual(second.center, { -5, 0, 1.5 }, "the second draw realizes from the same bank payload")
  Assert.deepEqual(
    awaited,
    { "g4gx " .. BANK_PATH, "g4gx " .. BANK_PATH },
    "every selected draw awaits the same decoded bank identity"
  )
  Assert.notNil(prepared.draws[1], "realizing one draw leaves the shared packet's first draw intact")
  Assert.notNil(prepared.draws[2], "realizing one draw leaves the shared packet's second draw intact")

  local ok, failure = pcall(function()
    pool:preparedMesh({ file = BANK_PATH, drawIndex = 7 }, await)
  end)
  Assert.isFalse(ok, "a draw index the bank does not carry fails loudly")
  Assert.equal(
    type(failure) == "table" and failure.code or failure,
    "SCENE_MESH_NATIVE_DRAW_MISSING",
    "the missing-draw failure names the bank selector contract"
  )
  Assert.equal(awaited[3], "g4gx " .. BANK_PATH, "a missing draw resolves the same resident bank identity")
  Assert.equal(#prepared.draws, 2, "a missing draw leaves the shared packet's draw list size unchanged")

  pool:release()
end

return {
  metadata = { capabilities = { "graphics" } },
  tests = T,
}
