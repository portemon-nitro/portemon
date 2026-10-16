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
local PngWriter = require("libs.assets.src.PngWriter")
local BinaryWriter = require("libs.codec.src.BinaryWriter")
local ErrorCodes = require("libs.assets.src.ErrorCodes")
local GpuAssetPool = require("libs.hgss.src.presentation.GpuAssetPool")
local SceneMesh = require("libs.hgss.src.presentation.SceneMesh")
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
    GpuAssetPool.new(fakeCacheFs(), { graphics = false })
  end)
  Assert.isTrue(tostring(err):find("GpuAssetPool requires love.graphics", 1, true) ~= nil)
end

-- Texture acquisition without the session shared owner is a programming
-- error and fails loudly instead of building a private image.
function T.texture_acquisition_without_a_session_pool_fails_loudly()
  local pool = GpuAssetPool.new(fakeCacheFs(), { graphics = fakeGraphics() })
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
  local pool = GpuAssetPool.new(fakeCacheFs(), { graphics = fakeGraphics(), imageAssets = SharedImagePoolFake.new() })
  local err = Assert.throws(function()
    pool:imageFor(TEX_PATH, "mirror", "clamp")
  end)
  Assert.isTrue(Errors.is(err) and err.code == "GPU_ASSET_UNKNOWN_WRAP", "raises GPU_ASSET_UNKNOWN_WRAP")
  Assert.equal(pool:textureCount(), 0, "no lease is borrowed for a rejected sampler")
end

function T.image_identity_includes_the_wrap_pair()
  local images = SharedImagePoolFake.new()
  local pool = GpuAssetPool.new(fakeCacheFs(), { graphics = fakeGraphics(), imageAssets = images })
  local repeatX = pool:imageFor(TEX_PATH, "repeat", "clamp")
  local clampX = pool:imageFor(TEX_PATH, "clamp", "clamp")
  Assert.isTrue(repeatX ~= clampX, "different wrap pairs must not alias one borrowed image")
  Assert.equal(images.uploads, 2, "each sampler state resolves its own physical image")
  Assert.equal(images:findPhysical(TEX_PATH, REPEAT_SAMPLER), repeatX)
  Assert.equal(images:findPhysical(TEX_PATH, CLAMP_SAMPLER), clampX)
end

function T.same_path_and_wrap_dedup_to_one_borrowed_lease()
  local images = SharedImagePoolFake.new()
  local pool = GpuAssetPool.new(fakeCacheFs(), { graphics = fakeGraphics(), imageAssets = images })
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
  local pool = GpuAssetPool.new(fakeCacheFs(), { graphics = fakeGraphics(), imageAssets = images })
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
  local pool = GpuAssetPool.new(fakeCacheFs(), { graphics = fakeGraphics() })
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
  local pool = GpuAssetPool.new(fakeCacheFs(), { graphics = fakeGraphics(), imageAssets = images })
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
  local pool = GpuAssetPool.new(fakeCacheFs(), { graphics = fakeGraphics(), imageAssets = images })
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
  local pool = GpuAssetPool.new(fakeCacheFs(), { graphics = fakeGraphics(), imageAssets = images })
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

function T.release_returns_leases_and_prune_reclaims_exactly_once()
  local images = SharedImagePoolFake.new()
  local pool = GpuAssetPool.new(fakeCacheFs(), { graphics = fakeGraphics(), imageAssets = images })
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
  local pool = GpuAssetPool.new(fakeCacheFs())
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
function T.empty_mesh_fails_and_releases_the_created_mesh()
  local created = {}
  local pool = GpuAssetPool.new(fakeCacheFs(), {
    graphics = fakeGraphics(),
    meshBuilder = function()
      local mesh = { released = false }
      mesh.release = function()
        mesh.released = true
      end
      created[#created + 1] = mesh
      return mesh --[[@as GpuAssetPool.Mesh]]
    end,
  })
  local err = Assert.throws(function()
    pool:meshFor(EMPTY_GEOM_PATH)
  end)
  Assert.isTrue(Errors.is(err) and err.code == ErrorCodes.SCENE_DESC_EMPTY_MESH, "raises SCENE_DESC_EMPTY_MESH")
  Assert.equal(#created, 1, "the builder created the mesh before the geometry step")
  Assert.equal(created[1].released, true, "the failed acquisition's own mesh is released")
  Assert.equal(#pool.meshes, 0, "the pool owns no mesh after the failed acquire")
end

-- The per-mesh geometry cache: the entry exposes the model-space
-- bounding-box center and AABB, computed ONCE per content-addressed path and
-- shared by every consumer (draw items, descriptor folds, sort centers) --
-- consumers read the cached values instead of rescanning the same vertices
-- per draw/placement. The values live on the shared entry, so repeated
-- acquires return the same precomputed tables.
function T.mesh_entries_expose_cached_center_and_aabb()
  local pool = GpuAssetPool.new(fakeCacheFs())
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

local function preparedMeshPayload()
  return SceneMesh.prepareUpload(MeshWriter.encode(triangleBatch()))
end

-- Equivalence: a prepared realization must dedup, geometry-fold, and stat
-- exactly like the synchronous path for the same content-addressed path.
function T.meshFromPrepared_matches_meshFor_geometry_for_equivalent_content()
  local syncPool = GpuAssetPool.new(fakeCacheFs())
  local syncEntry = syncPool:meshFor(GEOM_PATH)

  local graphics = fakeMeshGraphics()
  local preparedPool = GpuAssetPool.new(fakeCacheFs(), { graphics = graphics })
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
  local pool = GpuAssetPool.new(fakeCacheFs(), {
    graphics = graphics,
    meshBuilder = function()
      return { release = function() end }
    end,
  })
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
  local pool = GpuAssetPool.new(fakeCacheFs(), { graphics = graphics })
  local err = Assert.throws(function()
    pool:meshFromPrepared(GEOM_PATH, preparedMeshPayload())
  end)
  Assert.isTrue(tostring(err):find("injected setVertexMap failure", 1, true) ~= nil)
  Assert.equal(#pool.meshes, 0, "no mesh is published before every upload step succeeds")
  Assert.equal(pool.triangles, 0, "the triangle stat is not updated for an unpublished mesh")
  Assert.equal(graphics.created[1].released, true, "the partially-constructed mesh is released")

  local retryGraphics = fakeMeshGraphics()
  local retryPool = GpuAssetPool.new(fakeCacheFs(), { graphics = retryGraphics })
  local retried = retryPool:meshFromPrepared(GEOM_PATH, preparedMeshPayload())
  Assert.notNil(retried, "the prepared path is usable again after a rolled-back failure")
  retryPool:release()
end

-- imageFromPrepared delegates to the same shared borrow as imageFor: the
-- staged payload is superseded by the shared owner's own classification,
-- so both entry points resolve one physical image and one scene lease.
function T.imageFromPrepared_delegates_to_the_shared_borrow()
  local images = SharedImagePoolFake.new()
  local pool = GpuAssetPool.new(fakeCacheFs(), { graphics = fakeGraphics(), imageAssets = images })
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
  local pool = GpuAssetPool.new(fakeCacheFs(), { graphics = fakeGraphics(), imageAssets = images })
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

return {
  metadata = { capabilities = { "graphics" } },
  tests = T,
}
