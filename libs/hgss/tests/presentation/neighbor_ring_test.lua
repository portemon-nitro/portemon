-- NeighborRing loader tests: the sampler-wrap loader boundary for the eight
-- surrounding-cell ring mirrors MapSceneLoader's -- a cell material's raw
-- descriptor wrap/flip pair must resolve through SceneDescriptor.wrap()
-- before the image reaches the GPU pool, never the raw record.wrap.x/y the
-- old materialsById passed straight through. Headless: the pool's
-- meshBuilder seam and a stub graphics namespace stand in for real love GPU
-- resources, while textures borrow from the injected fake shared owner, so
-- this suite needs no graphics capability.

local Assert = require("tests.support.Assert")
local NeighborRing = require("libs.hgss.src.presentation.NeighborRing")
local MeshWriter = require("libs.assets.src.model.MeshWriter")
local FakeCache = require("tests.support.FakeCache")
local SharedImagePoolFake = require("tests.support.SharedImagePoolFake")

local T = {}

local STUB_GRAPHICS = {
  newImage = function()
    error("neighbor_ring does not build images in this test")
  end,
}
---@cast STUB_GRAPHICS GpuAssetPool.Graphics

-- A fake mesh builder for the pool's GPU seam: SceneMesh.decode output
-- becomes a plain object, so the ring's assembly runs headless.
local function fakeMeshBuilder(decoded)
  return {
    id = decoded and decoded.name or "mesh",
    release = function() end,
  }
end

-- A 2x2-tile quad in tile space (MeshWriter vertex shape).
local function quad()
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
  return {
    vertices = { v(0, 0), v(2, 0), v(2, 2), v(0, 2) },
    indices = { 0, 1, 2, 0, 2, 3 },
  }
end

-- One neighbor cell descriptor with one material and one batch sampling it,
-- the scene-form shape MapAssetCompiler emits per drawn surrounding cell.
local function cell(offsetX, offsetY, offsetZ, material, geometryPath)
  return {
    offsetTilesX = offsetX,
    offsetTilesY = offsetY,
    offsetTilesZ = offsetZ,
    materials = { material },
    batches = {
      {
        geometry = geometryPath,
        material = material.id,
        cullMode = "back",
        polygonMode = "modulation",
        polygonId = 0,
        translucentDepthWrite = false,
        depthEqual = false,
        polygonAlpha = 31,
        lightMask = 0,
        alphaClass = "opaque",
        fogEnabled = false,
      },
    },
  }
end

-- A cell material's raw descriptor state (`wrap.x = "repeat"`,
-- `flip.x = true`) must reach the GPU image as the resolved DS
-- mirrored-repeat sampler -- the same loader-boundary requirement
-- MapSceneLoader must satisfy, proven independently through NeighborRing.
function T.neighbor_material_with_flip_resolves_to_mirrored_repeat()
  local geometryPath = "assets/generated/maps/geometry/neighbor-quad.g4mesh"
  local backend = FakeCache.new()
  backend:write(geometryPath, MeshWriter.encode(quad()))
  local material = {
    id = 0,
    name = "ground",
    texture = "neighbor-ground.png",
    wrap = { x = "repeat", y = "repeat" },
    flip = { x = true, y = false },
    texWidth = 16,
    texHeight = 16,
    texMtxMode = 0,
  }
  local descriptors = { cell(32, 1, 0, material, geometryPath) }
  local images = SharedImagePoolFake.new()
  local ring = NeighborRing.load(backend, descriptors, {
    meshBuilder = fakeMeshBuilder,
    imageAssets = images,
    graphics = STUB_GRAPHICS,
  })
  Assert.equal(images.uploads, 1, "one shared image for the one cell material")
  Assert.notNil(
    images:findPhysical("neighbor-ground.png", { wrapX = "mirroredrepeat", wrapY = "repeat" }),
    "the neighbor image is borrowed with the resolved mirrored-repeat wrap, not the raw repeat pair"
  )
  ring:release()
end

-- A controllable stand-in for the session-scoped shared image owner: worker
-- results stay withheld until the test publishes them, so a staged neighbor
-- build can prove it yields instead of blocking. It models the same
-- request/poll/acquire/cancel/release shape the GPU pool consumes: one
-- physical image per texture path plus wrap state, explicit leases, and
-- failing polls once the injected threshold trips.
local function controllableImageOwner()
  local owner = {
    uploads = 0,
    held = true,
    failAfter = nil,
    failMessage = nil,
    cancels = 0,
    withheld = {},
    _nextToken = 0,
    _requests = {},
    _physicals = {},
  }
  function owner:request(path, sampler, _priority)
    assert(type(path) == "string", "shared image request path is required")
    assert(
      type(sampler) == "table" and sampler.wrapX ~= nil and sampler.wrapY ~= nil,
      "shared image request needs sampler state"
    )
    self._nextToken = self._nextToken + 1
    self._requests[self._nextToken] =
      { state = "staged", path = path, key = path .. "|" .. sampler.wrapX .. "|" .. sampler.wrapY }
    return self._nextToken
  end
  function owner:poll(token)
    local request = assert(self._requests[token], "unknown image request token")
    if request.state == "cancelled" then
      error("image request was cancelled", 0)
    end
    if request.state == "acquired" then
      return "ready"
    end
    if self.failAfter ~= nil and self.uploads >= self.failAfter then
      return "failed", self.failMessage or "injected shared image failure"
    end
    if self.held or self.withheld[request.path] then
      return "pending"
    end
    return "ready"
  end
  function owner:acquire(token)
    local request = assert(self._requests[token], "unknown image request token")
    assert(request.state == "staged", "image request is not ready")
    local physical = self._physicals[request.key]
    if physical == nil then
      local image = { released = false, releaseCount = 0 }
      function image:release()
        self.released = true
        self.releaseCount = self.releaseCount + 1
      end
      physical = { image = image, leases = 0 }
      self._physicals[request.key] = physical
      self.uploads = self.uploads + 1
    end
    physical.leases = physical.leases + 1
    request.state = "acquired"
    return { image = physical.image, palette = nil, kind = nil, _key = request.key, _owner = self, _released = false }
  end
  function owner:cancel(token)
    local request = self._requests[token]
    if request == nil or request.state == "acquired" then
      return false
    end
    self._requests[token] = nil
    self.cancels = self.cancels + 1
    return true
  end
  function owner:release(lease)
    assert(lease ~= nil and lease._owner == self, "image lease belongs to another pool")
    if lease._released then
      return false
    end
    lease._released = true
    local physical = assert(self._physicals[lease._key], "physical image left the pool under its lease")
    physical.leases = physical.leases - 1
    return true
  end
  function owner:outstandingLeases()
    local total = 0
    for _, physical in pairs(self._physicals) do
      total = total + physical.leases
    end
    return total
  end
  function owner:publish()
    self.held = false
  end
  function owner:withhold(path)
    self.withheld[path] = true
  end
  function owner:failAfterUploads(count, message)
    self.failAfter = count
    self.failMessage = message
  end
  return owner
end

local function stagedNeighborOptions(images)
  return { meshBuilder = fakeMeshBuilder, imageAssets = images, graphics = STUB_GRAPHICS }
end

local function groundMaterial(texture)
  return {
    id = 0,
    name = "ground",
    texture = texture,
    wrap = { x = "repeat", y = "repeat" },
    flip = { x = false, y = false },
    texWidth = 16,
    texHeight = 16,
    texMtxMode = 0,
  }
end

-- A staged neighbor build yields while its textures are still cold: every
-- pending advance returns promptly without consuming a work unit or
-- staging GPU objects, and the completed ring matches the synchronous
-- build exactly, deduplicating one shared texture across cells.
function T.staged_begin_yields_on_cold_images_without_consuming_work()
  local begin = assert(NeighborRing.begin, "neighbor ring exposes a staged begin task")
  local geometryPath = "assets/generated/maps/geometry/neighbor-quad.g4mesh"
  local backend = FakeCache.new()
  backend:write(geometryPath, MeshWriter.encode(quad()))
  local descriptors =
    { cell(32, 1, 0, groundMaterial("neighbor-ground.png"), geometryPath), cell(-32, 1, 0, groundMaterial(
      "neighbor-ground.png"
    ), geometryPath) }
  local images = controllableImageOwner()
  local task = begin(backend, descriptors, stagedNeighborOptions(images))
  Assert.equal(task:advance(0), 0, "a zero budget does no work")
  Assert.isFalse(task:isReady(), "cold images keep the staged ring pending")
  Assert.equal(task:advance(1), 0, "a pending worker wait consumes no work unit")
  Assert.isFalse(task:isReady(), "the ring stays pending while the worker is withheld")
  Assert.equal(images.uploads, 0, "no GPU image is staged while the worker is withheld")
  images:publish()
  local consumed = task:advance(8)
  Assert.isTrue(
    consumed >= 0 and consumed <= 8 and consumed % 1 == 0,
    "the completing advance stays within its budget"
  )
  Assert.isTrue(task:isReady(), "the ring completes once the worker replies")
  local ring = task:takeResult()
  Assert.equal(#ring.draws, 2, "both neighbor cells draw after staged completion")
  Assert.isTrue(
    ring.draws[1].material.image == ring.draws[2].material.image,
    "cells sharing a texture share one borrowed image"
  )
  Assert.equal(images.uploads, 1, "one shared texture uploads once")
  local readyImages = controllableImageOwner()
  readyImages:publish()
  local sync = NeighborRing.load(backend, descriptors, stagedNeighborOptions(readyImages))
  Assert.equal(#sync.draws, #ring.draws, "the staged ring draws every cell the synchronous build draws")
  Assert.equal(ring.draws[1].transform[13], sync.draws[1].transform[13], "staged cell offsets match the sync build")
  Assert.equal(ring.draws[1].transform[14], sync.draws[1].transform[14], "staged cell heights match the sync build")
  task:release()
  Assert.equal(images:outstandingLeases(), 1, "releasing a transferred task never revokes the taken ring")
  ring:release()
  sync:release()
  Assert.equal(images:outstandingLeases(), 0, "ring release returns its borrowed lease")
end

-- The synchronous entry stays explicitly blocking for standalone callers:
-- begin followed by finish completes against a ready owner.
function T.staged_begin_finish_completes_for_an_explicit_synchronous_owner()
  local begin = assert(NeighborRing.begin, "neighbor ring exposes a staged begin task")
  local geometryPath = "assets/generated/maps/geometry/neighbor-quad.g4mesh"
  local backend = FakeCache.new()
  backend:write(geometryPath, MeshWriter.encode(quad()))
  local descriptors = { cell(32, 1, 0, groundMaterial("neighbor-ground.png"), geometryPath) }
  local images = controllableImageOwner()
  images:publish()
  local ring = begin(backend, descriptors, stagedNeighborOptions(images)):finish()
  Assert.equal(#ring.draws, 1, "finish builds the one neighbor cell")
  Assert.equal(ring.draws[1].transform[13], 32, "the finished ring carries the cell offset")
  ring:release()
  Assert.equal(images:outstandingLeases(), 0, "finish hands ownership to the returned ring")
end

-- A texture failure mid-build fails the staged advance with its cause,
-- returns already-borrowed leases exactly once, publishes no partial ring,
-- and leaves an independent retry free to succeed.
function T.staged_begin_failure_releases_partial_borrows_and_publishes_nothing()
  local begin = assert(NeighborRing.begin, "neighbor ring exposes a staged begin task")
  local geometryPath = "assets/generated/maps/geometry/neighbor-quad.g4mesh"
  local backend = FakeCache.new()
  backend:write(geometryPath, MeshWriter.encode(quad()))
  local descriptors = {
    cell(32, 1, 0, groundMaterial("neighbor-first.png"), geometryPath),
    cell(-32, 1, 0, groundMaterial("neighbor-second.png"), geometryPath),
  }
  local images = controllableImageOwner()
  images:publish()
  images:failAfterUploads(1, "injected neighbor texture failure")
  local task = begin(backend, descriptors, stagedNeighborOptions(images))
  local ok, err = pcall(task.advance, task, 8)
  Assert.isFalse(ok, "a failed texture fails the staged advance")
  Assert.isTrue(
    tostring(err):find("injected neighbor texture failure", 1, true) ~= nil,
    "the texture cause propagates"
  )
  Assert.isFalse(task:isReady(), "a failed stage is never ready")
  Assert.equal(images:outstandingLeases(), 0, "partial borrows return exactly once")
  local okAgain, errAgain = pcall(task.advance, task, 1)
  Assert.isFalse(okAgain, "the failure stays sticky")
  Assert.equal(tostring(errAgain), tostring(err), "later advances repeat the original cause")
  local okTake = pcall(task.takeResult, task)
  Assert.isFalse(okTake, "no partial ring is published")
  task:release()
  task:release()
  Assert.equal(images:outstandingLeases(), 0, "repeated release is safe")
  local healthy = controllableImageOwner()
  healthy:publish()
  local retry = begin(backend, descriptors, stagedNeighborOptions(healthy)):finish()
  Assert.equal(#retry.draws, 2, "an independent retry draws both cells")
  retry:release()
end

-- Cancelling a staged build before the second texture replies returns the
-- first borrow and drops pending interest, without touching a sibling
-- scene lease borrowed from the same owner.
function T.staged_begin_cancel_returns_borrows_without_touching_scene_leases()
  local begin = assert(NeighborRing.begin, "neighbor ring exposes a staged begin task")
  local geometryPath = "assets/generated/maps/geometry/neighbor-quad.g4mesh"
  local backend = FakeCache.new()
  backend:write(geometryPath, MeshWriter.encode(quad()))
  local descriptors = {
    cell(32, 1, 0, groundMaterial("neighbor-first.png"), geometryPath),
    cell(-32, 1, 0, groundMaterial("neighbor-second.png"), geometryPath),
  }
  local images = controllableImageOwner()
  images:publish()
  images:withhold("neighbor-second.png")
  local sceneToken = images:request("neighbor-first.png", { wrapX = "repeat", wrapY = "repeat" }, "demand")
  local sceneLease = images:acquire(sceneToken)
  local task = begin(backend, descriptors, stagedNeighborOptions(images))
  task:advance(8)
  Assert.isFalse(task:isReady(), "the withheld second texture keeps the staged ring pending")
  task:release()
  task:release()
  Assert.equal(images:outstandingLeases(), 1, "cancelling keeps only the sibling scene borrow")
  Assert.isFalse(sceneLease.image.released, "the sibling scene image stays drawable")
  -- The worker replies: the withheld texture becomes acquirable for the
  -- independent load below.
  images.withheld["neighbor-second.png"] = nil
  local sync = NeighborRing.load(backend, descriptors, stagedNeighborOptions(images))
  Assert.equal(#sync.draws, 2, "an independent load still draws both cells")
  images:release(sceneLease)
  sync:release()
  Assert.equal(images:outstandingLeases(), 0, "every borrow returns")
end

-- A staged neighbor build yields while a texture-swap replacement frame is
-- still cold, then completes once the worker replies and animates through
-- the preloaded frames on the shared fixed-tick clock.
function T.staged_begin_cold_swap_frame_yields_then_animates()
  local begin = assert(NeighborRing.begin, "neighbor ring exposes a staged begin task")
  local geometryPath = "assets/generated/maps/geometry/neighbor-quad.g4mesh"
  local backend = FakeCache.new()
  backend:write(geometryPath, MeshWriter.encode(quad()))
  local material = groundMaterial("neighbor-ground.png")
  material.textureSwap = {
    name = "ground",
    steps = {
      { texture = "neighbor-swap-a.png", durationTicks = 1 },
      { texture = "neighbor-swap-b.png", durationTicks = 1 },
    },
  }
  local descriptors = { cell(32, 1, 0, material, geometryPath) }
  local images = controllableImageOwner()
  images:publish()
  images:withhold("neighbor-swap-a.png")
  images:withhold("neighbor-swap-b.png")
  local task = begin(backend, descriptors, stagedNeighborOptions(images))
  local consumed = task:advance(8)
  Assert.isFalse(task:isReady(), "a cold swap frame keeps the staged ring pending")
  Assert.isTrue(consumed >= 0 and consumed <= 8, "the pending advance stays within its budget")
  Assert.equal(images.uploads, 1, "only the warm base image is staged while swap frames are cold")
  -- The worker replies: the withheld frames become acquirable.
  images.withheld["neighbor-swap-a.png"] = nil
  images.withheld["neighbor-swap-b.png"] = nil
  task:advance(8)
  Assert.isTrue(task:isReady(), "the ring completes once the worker replies")
  local ring = task:takeResult()
  Assert.equal(#ring.draws, 1, "the staged ring draws its cell")
  Assert.equal(images.uploads, 3, "base plus both swap frames upload exactly once")
  local baseImage = ring.draws[1].material.image
  ring:updateAnimated()
  Assert.isTrue(
    ring.draws[1].material.image == baseImage,
    "the base image shows for the first schedule entry's duration"
  )
  ring:updateAnimated()
  Assert.equal(
    ring.draws[1].material.image,
    images._physicals["neighbor-swap-b.png|repeat|repeat"].image,
    "the clock swaps to the second preloaded frame"
  )
  ring:release()
  Assert.equal(images:outstandingLeases(), 0, "ring release returns every borrow")
end

-- A malformed sampler wrap fails the staged advance before anything is
-- borrowed: the failure is sticky, nothing is published, and release after
-- failure is safe.
function T.staged_begin_malformed_wrap_fails_without_borrowing()
  local begin = assert(NeighborRing.begin, "neighbor ring exposes a staged begin task")
  local geometryPath = "assets/generated/maps/geometry/neighbor-quad.g4mesh"
  local backend = FakeCache.new()
  backend:write(geometryPath, MeshWriter.encode(quad()))
  local material = groundMaterial("neighbor-ground.png")
  material.wrap = { x = "sideways", y = "repeat" }
  local descriptors = { cell(32, 1, 0, material, geometryPath) }
  local images = controllableImageOwner()
  images:publish()
  local task = begin(backend, descriptors, stagedNeighborOptions(images))
  local ok = pcall(task.advance, task, 8)
  Assert.isFalse(ok, "a malformed wrap fails the staged advance")
  Assert.isFalse(task:isReady(), "a failed stage is never ready")
  Assert.equal(images.uploads, 0, "no image is borrowed after a wrap failure")
  Assert.equal(images:outstandingLeases(), 0, "no lease is outstanding after a wrap failure")
  local okAgain = pcall(task.advance, task, 1)
  Assert.isFalse(okAgain, "the failure stays sticky")
  local okTake = pcall(task.takeResult, task)
  Assert.isFalse(okTake, "no partial ring is published")
  task:release()
  task:release()
  Assert.equal(images:outstandingLeases(), 0, "release after failure is safe")
end

function T.neighbor_vertical_offset_reaches_the_draw_transform()
  local geometryPath = "assets/generated/maps/geometry/neighbor-quad.g4mesh"
  local backend = FakeCache.new()
  backend:write(geometryPath, MeshWriter.encode(quad()))
  local material = {
    id = 0,
    name = "ground",
    texture = "neighbor-ground.png",
    wrap = { x = "repeat", y = "repeat" },
    flip = { x = false, y = false },
    texWidth = 16,
    texHeight = 16,
    texMtxMode = 0,
  }
  local ring = NeighborRing.load(backend, { cell(32, 1, -32, material, geometryPath) }, {
    meshBuilder = fakeMeshBuilder,
    imageAssets = SharedImagePoolFake.new(),
    graphics = STUB_GRAPHICS,
  })
  Assert.equal(ring.draws[1].transform[13], 32)
  Assert.equal(ring.draws[1].transform[14], 1)
  Assert.equal(ring.draws[1].transform[15], -32)
  ring:release()
end

return { tests = T }
