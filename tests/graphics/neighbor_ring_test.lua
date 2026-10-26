-- Tests for NeighborRing.load: it turns compiled scene.neighbors descriptors
-- into GPU draws, reading geometry from a cacheFs, baking each cell's
-- world offset into the draw transform while retaining model-space sort centers,
-- and deduplicating a shared geometry path across cells into a single owned mesh.
-- Textures borrow from the injected session shared owner (fake headless);
-- geometry is canned in-process, so the suite is ROM-free. load() needs a
-- graphics context. The failure-path tests prove a failed cell acquire or a
-- malformed cell descriptor returns every lease the earlier cells already
-- borrowed.
--
-- Terrain animation wiring: load() accepts the central scene's
-- compiled texture-SRT clip as `opts.textureSrt` (false = no area animation)
-- and builds ONE terrain animator across every neighbor cell's runtime
-- material tables, exposed as ring:updateAnimated() -- the shared clocks keep
-- same-name materials in phase across cells, swap-frame images are acquired
-- inside the load transaction, and updateFixed mutates the draw materials in
-- place. Empty neighbors and clips stay safe no-ops.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local MeshWriter = require("libs.assets.src.model.MeshWriter")
local PngWriter = require("tests.support.PngEncoder")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local NeighborRing = require("libs.hgss.src.presentation.NeighborRing")
local RenderQueue = require("libs.hgss.src.presentation.RenderQueue")
local Matrix4 = require("libs.math.src.Matrix4")
local SharedImagePoolFake = require("tests.support.SharedImagePoolFake")

local T = {}

local function queueScratch()
  return RenderQueue.newScratch()
end

-- One-triangle batch in the MeshWriter vertex layout.
local function triangleBatch(zOffset)
  zOffset = zOffset or 0
  local function v(x, z)
    return {
      x = x,
      y = 0,
      z = z + zOffset,
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

-- A cacheFs whose :read(path) returns canned bytes for the known geometry and
-- texture paths, mirroring CacheFs:read's string-or-nil contract.
local function fakeCacheFs()
  local meshBytes = MeshWriter.encode(triangleBatch())
  local elevatedMeshBytes = MeshWriter.encode(triangleBatch(48))
  local pngBytes = PngWriter.encode(1, 1, string.char(255, 0, 0, 255))
  local geomPath = MapAssetCache.geometryPath("aaaa")
  local elevatedGeomPath = MapAssetCache.geometryPath("cccc")
  local texPath = MapAssetCache.texturePath("bbbb")
  local blob = {
    [geomPath] = meshBytes,
    [elevatedGeomPath] = elevatedMeshBytes,
    [texPath] = pngBytes,
  }
  return {
    read = function(_, path)
      return blob[path]
    end,
  }, geomPath, texPath, elevatedGeomPath
end

-- Injected graphics namespace tracking created images and their release calls,
-- so the image side of a failed cell load can be observed without a GL context.
---@class RingFakeGraphics: love.graphics
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
  }
  ---@cast graphics RingFakeGraphics
  return graphics
end

-- Two cells sharing one geometry path (dedup) and one material each. `wraps`
-- optionally supplies a per-cell wrap table (indexed 1, 2) for sampler tests.
local function descriptors(geomPath, texPath, wraps)
  local function cell(ox, oz, index)
    return {
      offsetTilesX = ox,
      offsetTilesZ = oz,
      batches = {
        {
          geometry = geomPath,
          material = 0,
          alphaClass = "opaque",
          cullMode = "back",
          polygonAlpha = 31,
          polygonMode = "modulation",
          lightMask = 0,
          polygonId = 0,
          translucentDepthWrite = false,
          depthEqual = false,
        },
      },
      materials = {
        {
          id = 0,
          name = "terrain",
          texture = texPath,
          wrap = wraps and wraps[index] or { x = "repeat", y = "clamp" },
          diffuse = { r = 255, g = 255, b = 255, a = 255 },
          texWidth = 16,
          texHeight = 16,
          texMtxMode = 0,
        },
      },
    }
  end
  return { cell(32, 0, 1), cell(-32, -32, 2) }
end

function T.builds_one_draw_per_cell_batch_with_offset_in_transform()
  local cacheFs, geomPath, texPath = fakeCacheFs()
  local ring = NeighborRing.load(cacheFs, descriptors(geomPath, texPath), { imageAssets = SharedImagePoolFake.new() })

  Assert.equal(#ring.draws, 2) -- one batch per cell
  Assert.equal(ring.stats.cellCount, 2)

  -- The loader sorts from the triangle bounding-box center (1, 0, 1); each draw
  -- keeps that model-space center while the transform carries the cell offset.
  local d1 = ring.draws[1]
  Assert.equal(d1.transform[13], 32) -- translate X column of Matrix4
  Assert.equal(d1.transform[15], 0) -- translate Z
  Assert.deepEqual(d1.center, { 1, 0, 1 }, "center remains in model space")
  Assert.deepEqual(d1.modelNormal, { 1, 0, 0, 0, 1, 0, 0, 0, 1 })

  local d2 = ring.draws[2]
  Assert.equal(d2.transform[13], -32)
  Assert.equal(d2.transform[15], -32)
  Assert.equal(d1.modelNormal, d2.modelNormal, "translation-only neighbors share one model normal")

  ring:release()
end

local function translucentDescriptors(firstGeomPath, secondGeomPath, texPath)
  local function cell(geometry, offsetTilesZ)
    return {
      offsetTilesX = 0,
      offsetTilesY = 0,
      offsetTilesZ = offsetTilesZ,
      batches = {
        {
          geometry = geometry,
          material = 0,
          alphaClass = "translucent",
          cullMode = "back",
          polygonAlpha = 31,
          polygonMode = "modulation",
          lightMask = 0,
          polygonId = 0,
          translucentDepthWrite = false,
          depthEqual = false,
        },
      },
      materials = {
        {
          id = 0,
          name = "terrain",
          texture = texPath,
          wrap = { x = "repeat", y = "clamp" },
          diffuse = { r = 255, g = 255, b = 255, a = 255 },
          texMtxMode = 0,
        },
      },
    }
  end
  return { cell(firstGeomPath, 32), cell(secondGeomPath, 0) }
end

function T.sorts_translucent_neighbors_using_one_cell_transform()
  local cacheFs, geomPath, texPath, elevatedGeomPath = fakeCacheFs()
  local ring = NeighborRing.load(
    cacheFs,
    translucentDescriptors(geomPath, elevatedGeomPath, texPath),
    { imageAssets = SharedImagePoolFake.new() }
  )

  -- The first mesh center is z=1 and lives in the +32 cell, so its world-space
  -- sort center is z=33. The second mesh center is z=49 in the origin cell.
  -- With one transform application, the first draw is submitted first. A
  -- pre-offset center would be transformed again to z=65 and reverse them.
  local queue = RenderQueue.buildInto({ ring.draws }, Matrix4.identity(), queueScratch())
  Assert.isTrue(queue.blended[1].item == ring.draws[1], "the +32 neighbor sorts at z=33")
  Assert.isTrue(queue.blended[2].item == ring.draws[2], "the origin neighbor sorts at z=49")

  ring:release()
end

function T.dedups_shared_geometry_into_one_owned_mesh()
  local cacheFs, geomPath, texPath = fakeCacheFs()
  local ring = NeighborRing.load(cacheFs, descriptors(geomPath, texPath), { imageAssets = SharedImagePoolFake.new() })
  -- Both cells reference the same geometry/texture path, so only one mesh and
  -- one image are built and owned.
  Assert.equal(ring.stats.meshCount, 1)
  Assert.equal(ring.stats.textureCount, 1)
  ring:release()
end

-- Regression for the sampler alias: two cells sharing one texture path but
-- sampling it with different wrap modes must each keep their own configured
-- image, never one mutated sampler whose state depends on load order.
function T.same_texture_with_different_wraps_gets_independent_images()
  local cacheFs, geomPath, texPath = fakeCacheFs()
  local images = SharedImagePoolFake.new()
  local ring = NeighborRing.load(
    cacheFs,
    descriptors(geomPath, texPath, { { x = "clamp", y = "clamp" }, { x = "repeat", y = "repeat" } }),
    { imageAssets = images }
  )
  Assert.equal(ring.stats.textureCount, 2, "one borrowed image per sampler state")
  local drawA = ring.draws[1]
  local drawB = ring.draws[2]
  Assert.isTrue(drawA.material.image ~= drawB.material.image, "wrap variants must not alias")
  Assert.equal(drawA.material.image, images:findPhysical(texPath, { wrapX = "clamp", wrapY = "clamp" }))
  Assert.equal(drawB.material.image, images:findPhysical(texPath, { wrapX = "repeat", wrapY = "repeat" }))
  ring:release()
end

-- A batch-free cell enrolls its material before the build; the second
-- cell's unknown wrap then fails enrollment, before anything is borrowed:
-- a failed neighbor load holds no leases and publishes nothing.
function T.failed_cell_acquire_releases_earlier_cells_images()
  local cacheFs, _, texPath = fakeCacheFs()
  local function cell(ox, wrap)
    return {
      offsetTilesX = ox,
      offsetTilesZ = 0,
      batches = {},
      materials = {
        {
          id = 0,
          name = "terrain",
          texture = texPath,
          wrap = wrap,
          diffuse = { r = 255, g = 255, b = 255, a = 255 },
        },
      },
    }
  end
  local images = SharedImagePoolFake.new()
  local err = Assert.throws(function()
    NeighborRing.load(cacheFs, {
      cell(32, { x = "clamp", y = "clamp" }),
      cell(-32, { x = "mirror", y = "clamp" }),
    }, { graphics = fakeGraphics(), imageAssets = images })
  end)
  Assert.isTrue(Errors.is(err) and err.code == "SCENE_DESC_BAD_WRAP", "raises SCENE_DESC_BAD_WRAP")
  Assert.equal(images.uploads, 0, "the wrap failure precedes any borrow")
  Assert.equal(images:stats().outstandingLeases, 0, "a failed cell load holds no leases")
  Assert.equal(images:prune(), 0, "a failed cell load publishes nothing to reclaim")
end

-- A malformed descriptor (missing batches array) fails outside the pool after
-- earlier cells acquired images; the load must still release them.
function T.malformed_cell_descriptor_releases_earlier_cells_images()
  local cacheFs, _, texPath = fakeCacheFs()
  local first = {
    offsetTilesX = 32,
    offsetTilesZ = 0,
    batches = {},
    materials = {
      {
        id = 0,
        name = "terrain",
        texture = texPath,
        wrap = { x = "clamp", y = "clamp" },
        diffuse = { r = 255, g = 255, b = 255, a = 255 },
      },
    },
  }
  local second = {
    offsetTilesX = -32,
    offsetTilesZ = 0,
    materials = {},
  }
  local graphics = fakeGraphics()
  local images = SharedImagePoolFake.new()
  local ok, err = pcall(NeighborRing.load, cacheFs, { first, second }, { graphics = graphics, imageAssets = images })
  Assert.isFalse(ok, "a descriptor without a batches array fails the load: " .. tostring(err))
  Assert.equal(images.uploads, 1, "the first cell's image was borrowed")
  Assert.equal(images:stats().outstandingLeases, 0, "a malformed descriptor returns the earlier cells' leases")
  Assert.equal(images:prune(), 1, "the rolled-back image is reclaimed exactly once")
end

-- ---- terrain animation wiring ----

-- The new-bark-like replacement schedule: R0 for 18 ticks, R1 for 18, R0
-- for 18, R2 for 18, loop.
local function flowerSteps(prefix)
  return {
    { texture = prefix .. "0.png", durationTicks = 18 },
    { texture = prefix .. "1.png", durationTicks = 18 },
    { texture = prefix .. "0.png", durationTicks = 18 },
    { texture = prefix .. "2.png", durationTicks = 18 },
  }
end

-- A compiled texsrt clip in the NsbtaClipCompiler payload shape (the central
-- scene's terrainAnimations.textureSrt): one target with a translation-S
-- curve and identity scale/rotation constants.
local function terrainSrtClip(frames, transKeys)
  return {
    id = "fixture:area00_ani",
    name = "area00_ani",
    category = "material",
    kind = "texsrt",
    frameCount = frames,
    tracks = { { target = "water", targetIndex = 0 } },
    semanticNames = {},
    compiled = {
      targets = {
        {
          index = 0,
          name = "water",
          channels = {
            scaleS = { source = "constant", value = 0x1000 },
            scaleT = { source = "constant", value = 0x1000 },
            rot = { source = "constant", value = 0x10000000 },
            transS = { source = "curve", rate = 1, limit = frames, storage = "fx32", keys = transKeys },
            transT = { source = "constant", value = 0 },
          },
        },
      },
    },
  }
end

-- A neighbor cell with a texture-swap terrain material (flower01) plus a
-- water material targeted by the area SRT clip: the compiled neighbor
-- scene-material shape. The base image and the replacement step paths are
-- distinct per cell, so two cells of one animation name can prove phase
-- alignment while each resolves its own paths.
local function animatedCell(ox, oz, geomPath, prefix)
  return {
    offsetTilesX = ox,
    offsetTilesZ = oz,
    batches = {
      {
        geometry = geomPath,
        material = 0,
        alphaClass = "opaque",
        cullMode = "back",
        polygonAlpha = 31,
        polygonMode = "modulation",
        lightMask = 0,
        polygonId = 0,
        translucentDepthWrite = false,
        depthEqual = false,
      },
      {
        geometry = geomPath,
        material = 1,
        alphaClass = "opaque",
        cullMode = "back",
        polygonAlpha = 31,
        polygonMode = "modulation",
        lightMask = 0,
        polygonId = 0,
        translucentDepthWrite = false,
        depthEqual = false,
      },
    },
    materials = {
      {
        id = 0,
        name = "flower01",
        texture = prefix .. "-base.png",
        wrap = { x = "repeat", y = "repeat" },
        texWidth = 16,
        texHeight = 16,
        texMtxMode = 0,
        textureSwap = {
          name = "flower01",
          steps = flowerSteps(prefix),
        },
      },
      {
        id = 1,
        name = "water",
        texture = "water.png",
        wrap = { x = "repeat", y = "repeat" },
        texWidth = 16,
        texHeight = 16,
        texMtxMode = 0,
      },
    },
  }
end

-- One animator spans every neighbor cell: all swap step images are borrowed
-- inside the ring's load transaction (same-name paths dedup through the
-- shared owner), ring:updateAnimated() switches step images and advances the
-- targeted texture matrices in place on the draw materials -- no draw-list
-- rebuild -- and release after success returns every base and step lease
-- while the shared owner reclaims each idle image exactly once.
function T.neighbor_swap_frames_are_acquired_and_update_in_place()
  local cacheFs, geomPath, _ = fakeCacheFs()
  local clip = terrainSrtClip(4, { 0x0, 0x1000, 0x2000, 0x3000 })
  local images = SharedImagePoolFake.new()
  local ring = NeighborRing.load(
    cacheFs,
    { animatedCell(32, 0, geomPath, "f"), animatedCell(-32, -32, geomPath, "f") },
    {
      imageAssets = images,
      textureSrt = clip,
    }
  )
  Assert.equal(
    ring.stats.textureCount,
    5,
    "base, the three unique steps, and water are borrowed once across both cells"
  )
  Assert.equal(images.uploads, 5)
  local sampler = { wrapX = "repeat", wrapY = "repeat" }

  local draws = ring.draws
  local flowerA = draws[1].material
  local flowerB = draws[3].material
  local waterA = draws[2].material
  local image0 = flowerA.image
  local waterMatrix0 = waterA.texMatrix
  Assert.equal(
    image0,
    images:findPhysical("f-base.png", sampler),
    "load binds the base image and leaves it in place -- never the first replacement step"
  )

  for _ = 1, 19 do
    ring:updateAnimated()
  end

  Assert.equal(ring.draws, draws, "the neighbor draw array is not rebuilt on an animation tick")
  Assert.equal(flowerA.image, images:findPhysical("f1.png", sampler), "the step image switched to step 2 at tick 19")
  Assert.isFalse(flowerA.image == image0, "the switched image is a different shared image")
  Assert.equal(flowerB.image, images:findPhysical("f1.png", sampler), "both cells share the group clock")
  Assert.near(waterA.texMatrix[7], -3, 1e-9, "the SRT sample advanced to frame 3 (0x3000 scroll)")
  Assert.isFalse(waterA.texMatrix == waterMatrix0, "a targeted matrix is replaced per tick")

  local physicals = {}
  for _, path in ipairs({ "f-base.png", "f0.png", "f1.png", "f2.png", "water.png" }) do
    physicals[#physicals + 1] = images:findPhysical(path, sampler)
  end
  ring:release()
  Assert.equal(images:stats().outstandingLeases, 0, "release returns every borrowed lease")
  Assert.equal(images:prune(), 5, "all five idle images are reclaimed")
  for _, physical in ipairs(physicals) do
    Assert.equal(physical.releaseCount, 1, "every neighbor base and step image is reclaimed exactly once")
  end
end

-- Same-name neighbor cells compiled against their own texture packs carry
-- different replacement paths but the same durations; the one group clock
-- keeps them in phase, each switching to its own image at the same tick.
function T.same_name_neighbor_cells_stay_in_phase_with_distinct_paths()
  local cacheFs, geomPath, _ = fakeCacheFs()
  local images = SharedImagePoolFake.new()
  local ring = NeighborRing.load(
    cacheFs,
    { animatedCell(32, 0, geomPath, "a"), animatedCell(-32, -32, geomPath, "b") },
    {
      imageAssets = images,
      textureSrt = false,
    }
  )
  local sampler = { wrapX = "repeat", wrapY = "repeat" }
  local flowerA = ring.draws[1].material
  local flowerB = ring.draws[3].material
  Assert.equal(flowerA.image, images:findPhysical("a-base.png", sampler))
  Assert.equal(flowerB.image, images:findPhysical("b-base.png", sampler))

  for _ = 1, 19 do
    ring:updateAnimated()
  end
  Assert.equal(flowerA.image, images:findPhysical("a1.png", sampler), "cell A enters its own step 2 at tick 19")
  Assert.equal(flowerB.image, images:findPhysical("b1.png", sampler), "cell B enters its own step 2 at the same tick")

  for _ = 1, 54 do
    ring:updateAnimated()
  end
  Assert.equal(flowerA.image, images:findPhysical("a0.png", sampler), "cell A wraps to its own step 1 at tick 73")
  Assert.equal(flowerB.image, images:findPhysical("b0.png", sampler), "cell B wraps to its own step 1 at tick 73")

  ring:release()
end

-- Empty neighbors and the absence of an area clip still expose the safe
-- no-op update method: nothing animates, nothing is acquired, nothing is
-- rebuilt.
function T.empty_neighbor_ring_updates_safely()
  local cacheFs, _, _ = fakeCacheFs()
  local images = SharedImagePoolFake.new()
  local ring = NeighborRing.load(cacheFs, {}, { imageAssets = images, textureSrt = false })
  Assert.equal(#ring.draws, 0)
  ring:updateAnimated()
  Assert.equal(images.uploads, 0)
  ring:release()
  local clipRing = NeighborRing.load(cacheFs, {}, {
    imageAssets = images,
    textureSrt = terrainSrtClip(4, { 0x0, 0x1000, 0x2000, 0x3000 }),
  })
  clipRing:updateAnimated()
  Assert.equal(#clipRing.draws, 0)
  clipRing:release()
end

return {
  metadata = { capabilities = { "graphics" } },
  tests = T,
}
