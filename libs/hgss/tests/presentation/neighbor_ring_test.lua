-- NeighborRing loader tests: the sampler-wrap loader boundary for the eight
-- surrounding-cell ring mirrors MapSceneLoader's -- a cell material's raw
-- descriptor wrap/flip pair must resolve through SceneDescriptor.wrap()
-- before the image reaches the GPU pool, never the raw record.wrap.x/y the
-- old materialsById passed straight through. Headless: the pool's
-- meshBuilder seam and a stub graphics namespace stand in for real love GPU
-- resources, while textures borrow from the injected fake shared owner, so
-- this suite needs no graphics capability.

local Assert = require("tests.support.Assert")
local ControllableImageOwner = require("tests.support.ControllableImageOwner")
local NeighborRing = require("libs.hgss.src.presentation.NeighborRing")
local MeshWriter = require("libs.assets.src.model.MeshWriter")
local SceneMesh = require("libs.hgss.src.presentation.SceneMesh")
local FakeCache = require("tests.support.FakeCache")
local FakePreparationQueue = require("tests.support.FakePreparationQueue")
local SharedImagePoolFake = require("tests.support.SharedImagePoolFake")
local SynchronousWaitProbe = require("tests.support.SynchronousWaitProbe")

local T = {}

local STUB_GRAPHICS = {
  newImage = function()
    error("neighbor_ring does not build images in this test")
  end,
  -- Worker-prepared geometry is realized as a LÖVE Mesh, so the prepared path
  -- needs the mesh constructor even though the synchronous path uses the
  -- pool's injectable mesh builder.
  newMesh = function()
    return {
      setVertices = function() end,
      setVertexMap = function() end,
      release = function() end,
    }
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

---@param images ControllableImageOwner
---@param queue table? preparation queue the staged build routes geometry through
---@return table neighbor options
local function stagedNeighborOptions(images, queue)
  return {
    meshBuilder = fakeMeshBuilder,
    imageAssets = images,
    graphics = STUB_GRAPHICS,
    assetPreparation = queue,
  }
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
  local descriptors = {
    cell(32, 1, 0, groundMaterial("neighbor-ground.png"), geometryPath),
    cell(-32, 1, 0, groundMaterial("neighbor-ground.png"), geometryPath),
  }
  local images = ControllableImageOwner.new()
  local task = begin(backend, descriptors, stagedNeighborOptions(images))
  Assert.equal(task:advance(0), 0, "a zero budget does no work")
  Assert.isFalse(task:isReady(), "cold images keep the staged ring pending")
  Assert.equal(task:advance(1), 0, "a pending worker wait consumes no work unit")
  Assert.isFalse(task:isReady(), "the ring stays pending while the worker is withheld")
  Assert.equal(images.uploads, 0, "no GPU image is staged while the worker is withheld")
  images:publish()
  local consumed = task:advance(8)
  Assert.isTrue(consumed >= 0 and consumed <= 8 and consumed % 1 == 0, "the completing advance stays within its budget")
  Assert.isTrue(task:isReady(), "the ring completes once the worker replies")
  local ring = task:takeResult()
  Assert.equal(#ring.draws, 2, "both neighbor cells draw after staged completion")
  Assert.isTrue(
    ring.draws[1].material.image == ring.draws[2].material.image,
    "cells sharing a texture share one borrowed image"
  )
  Assert.equal(images.uploads, 1, "one shared texture uploads once")
  local readyImages = ControllableImageOwner.new()
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
  local images = ControllableImageOwner.new()
  images:publish()
  local ring = begin(backend, descriptors, stagedNeighborOptions(images)):finish()
  Assert.equal(#ring.draws, 1, "finish builds the one neighbor cell")
  Assert.equal(ring.draws[1].transform[13], 32, "the finished ring carries the cell offset")
  ring:release()
  Assert.equal(images:outstandingLeases(), 0, "finish hands ownership to the returned ring")
end

-- The explicit synchronous entry blocks on a cold texture by sleeping for the
-- worker instead of polling it: the ring completes once the owner replies,
-- within a bounded number of polls, and returns every borrowed lease.
function T.sync_load_blocks_on_a_cold_texture_without_hot_polling()
  local geometryPath = "assets/generated/maps/geometry/neighbor-quad.g4mesh"
  local backend = FakeCache.new()
  backend:write(geometryPath, MeshWriter.encode(quad()))
  local descriptors = { cell(32, 1, 0, groundMaterial("neighbor-ground.png"), geometryPath) }
  local images = ControllableImageOwner.new()
  local probe = SynchronousWaitProbe.new(images, { publishAfterSleeps = 2 })
  probe:install()
  local ok, ringOrFailure = pcall(NeighborRing.load, backend, descriptors, stagedNeighborOptions(images))
  probe:restore()
  Assert.isTrue(ok, "the blocking neighbour load completes: " .. tostring(ringOrFailure))
  Assert.isTrue(probe.sleeps >= 1, "the blocking wait handed the CPU to the worker instead of polling it")
  Assert.equal(#ringOrFailure.draws, 1, "the completed ring draws its cell")
  ringOrFailure:release()
  Assert.equal(images:outstandingLeases(), 0, "releasing the completed ring returns every borrowed lease")
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
  local images = ControllableImageOwner.new()
  images:publish()
  images:failAfterUploads(1, "injected neighbor texture failure")
  local task = begin(backend, descriptors, stagedNeighborOptions(images))
  local ok, err = pcall(task.advance, task, 8)
  Assert.isFalse(ok, "a failed texture fails the staged advance")
  Assert.isTrue(tostring(err):find("injected neighbor texture failure", 1, true) ~= nil, "the texture cause propagates")
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
  local healthy = ControllableImageOwner.new()
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
  local images = ControllableImageOwner.new()
  images:publish()
  images:withhold("neighbor-second.png")
  local sceneToken = images:request("neighbor-first.png", { wrapX = "repeat", wrapY = "repeat" }, "demand")
  Assert.equal(images:poll(sceneToken), "ready", "the sibling scene borrow is warm")
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
  local images = ControllableImageOwner.new()
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
  local images = ControllableImageOwner.new()
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

-- One procedural neighbor geometry path plus the prepared upload payload the
-- worker would answer it with, so a blocking finish realizes the same mesh a
-- cooperative advance realizes.
local GEOMETRY_PATH = "assets/generated/maps/geometry/neighbor-quad.g4mesh"

local function geometryBackend()
  local backend = FakeCache.new()
  backend:write(GEOMETRY_PATH, MeshWriter.encode(quad()))
  return backend
end

local function preparedMeshPayload(backend)
  local bytes = assert(backend:read(GEOMETRY_PATH))
  return SceneMesh.prepareUpload(bytes, GEOMETRY_PATH)
end

-- Advance a staged build until it suspends on its geometry ticket: the
-- material stages charge work units of their own before the first geometry
-- request reaches the worker.
local function advanceToGeometryTicket(task, queue)
  for _ = 1, 8 do
    if #queue.requests > 0 then
      return
    end
    task:advance(1)
  end
  Assert.isTrue(#queue.requests > 0, "the staged build requests its geometry")
end

-- Suspend one staged build on its published geometry ticket, then leave it
-- through `exitPath`. Both exits own the same obligation: the abandoned build
-- drops the ticket it was suspended on exactly once, so the ready worker packet
-- stops being charged to the session queue's budget, a late reply publishes
-- nothing, and the borrowed images return.
---@param exitPath string "release", "failure", or "terminal"
local function assertGeometryTicketDroppedOnExit(exitPath)
  local backend = geometryBackend()
  local images = ControllableImageOwner.new()
  images:publish()
  local queue = FakePreparationQueue.new({ deferred = true, payloadBytes = 2048 })
  local descriptors = { cell(32, 1, 0, groundMaterial("neighbor-ground.png"), GEOMETRY_PATH) }
  local task = NeighborRing.begin(backend, descriptors, stagedNeighborOptions(images, queue))
  advanceToGeometryTicket(task, queue)
  Assert.equal(task:advance(1), 0, "a pending geometry ticket consumes no work unit")
  Assert.isFalse(task:isReady(), "the ring waits for the geometry worker")
  Assert.equal(#queue.requests, 1, "the ring requests its geometry from the worker")
  Assert.equal(queue.requests[1].kind, "mesh", "procedural neighbor geometry is prepared as a mesh")
  Assert.equal(queue.requests[1].priority, "prefetch", "a staged build keeps requesting at prefetch priority")
  local token = queue.requests[1].token
  Assert.isTrue(queue:publish(token), "the worker publishes the pending geometry")
  Assert.equal(queue.readyBytes, 2048, "the published packet is charged to the ready budget")

  if exitPath == "release" then
    task:release()
    task:release()
  elseif exitPath == "failure" then
    queue:failPoll("preparation queue reply is malformed")
    local ok, err = pcall(task.advance, task, 1)
    Assert.isFalse(ok, "a queue fault fails the staged build")
    Assert.isTrue(
      tostring(err):find("preparation queue reply is malformed", 1, true) ~= nil,
      "the queue cause propagates instead of a cancellation error"
    )
    task:release()
    Assert.equal(#queue.cancelCalls, 1, "release after failure never cancels the same ticket twice")
  else
    -- A terminal failure result (poll answers "failed" without raising) leaves
    -- the ticket owned by the build, so the same unwind must cancel it.
    queue.failure = "injected GX failure"
    local ok, err = pcall(task.advance, task, 1)
    Assert.isFalse(ok, "a terminal preparation failure fails the staged build")
    Assert.isTrue(
      tostring(err):find("injected GX failure", 1, true) ~= nil,
      "the preparation cause propagates instead of a cancellation error"
    )
    task:release()
    Assert.equal(#queue.cancelCalls, 1, "release after failure never cancels the same ticket twice")
  end

  Assert.equal(#queue.cancelCalls, 1, exitPath .. " cancels the outstanding geometry ticket exactly once")
  Assert.equal(queue:outstandingTickets(), 0, exitPath .. " leaves no ticket charged to the session queue")
  Assert.equal(queue.cancelCalls[1], token, exitPath .. " cancels the ticket the build was suspended on")
  Assert.equal(queue.readyBytes, 0, "the ready-payload budget returns to baseline")
  Assert.isFalse(task:isReady(), "a closed build never becomes ready")
  Assert.throws(function()
    task:takeResult()
  end, "a closed build publishes no ring")
  Assert.isFalse(queue:publish(token), "a late worker reply cannot publish a dropped ticket")
  Assert.equal(images:outstandingLeases(), 0, "the closed build returns its borrowed images")
end

-- A staged build that is abandoned while the geometry worker still owes it a
-- packet drops that interest through either exit, before the packet is claimed.
function T.staged_release_and_failure_cancel_the_outstanding_geometry_ticket_once()
  assertGeometryTicketDroppedOnExit("release")
  assertGeometryTicketDroppedOnExit("failure")
  assertGeometryTicketDroppedOnExit("terminal")
end

-- The synchronous entry blocks on the worker instead of re-polling the
-- suspended build: it promotes the outstanding ticket to demand, waits for the
-- payload once, and resumes the build with that payload stashed.
function T.staged_finish_waits_on_the_worker_instead_of_repolling_the_build()
  local backend = geometryBackend()
  local images = ControllableImageOwner.new()
  images:publish()
  local queue = FakePreparationQueue.new({
    deferred = true,
    payloadBytes = 2048,
    pollLimit = 8,
    payload = function(kind, path)
      Assert.equal(kind, "mesh", "neighbor geometry arrives as a prepared mesh")
      Assert.equal(path, GEOMETRY_PATH, "the worker prepares the requested geometry path")
      return preparedMeshPayload(backend)
    end,
  })
  local descriptors = { cell(32, 1, 0, groundMaterial("neighbor-ground.png"), GEOMETRY_PATH) }
  local ring = NeighborRing.begin(backend, descriptors, stagedNeighborOptions(images, queue)):finish()
  Assert.equal(#queue.requests, 1, "the finishing build issues its geometry request once")
  Assert.equal(queue.requests[1].priority, "demand", "finishing promotes new requests to demand")
  Assert.equal(queue.waited, 1, "finish blocks on the outstanding ticket once")
  Assert.equal(#queue.promotions, 1, "finish promotes the outstanding ticket")
  Assert.equal(queue.promotions[1].token, queue.requests[1].token, "the promoted ticket is the awaited one")
  Assert.equal(queue.promotions[1].priority, "demand", "the outstanding ticket becomes demand before the wait")
  Assert.equal(queue.polls, 1, "finish consumes its waited payload instead of re-polling the build")
  Assert.equal(queue.readyBytes, 0, "the waited payload transfers instead of staying charged")
  Assert.equal(#ring.draws, 1, "finish builds the one neighbor cell")
  Assert.equal(ring.draws[1].transform[13], 32, "the finished ring carries the cell offset")
  ring:release()
  Assert.equal(images:outstandingLeases(), 0, "ring release returns every borrow")
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

-- Neighbor geometry gets the same treatment as the central scene's: a native
-- model bank is requested from the existing preparation worker once, and the
-- ring realizes each cell's selected draw from that one prepared payload
-- instead of replaying the bank on the main thread.
function T.native_neighbor_geometry_arrives_through_the_preparation_queue()
  local NativeGxFormat = require("libs.assets.src.model.NativeGxFormat")
  local SceneMesh = require("libs.hgss.src.presentation.SceneMesh")
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
  local function triangle(vertices)
    local ops, params = { 0x40 }, { u32(0) }
    for _, vertex in ipairs(vertices) do
      ops[#ops + 1], params[#params + 1] = 0x21, u32(0x00000FFF)
      ops[#ops + 1], params[#params + 1] = 0x22, u32(0)
      ops[#ops + 1], params[#params + 1] = 0x23, vtx16(vertex)
    end
    ops[#ops + 1], params[#params + 1] = 0x41, ""
    while #ops % 4 ~= 0 do
      ops[#ops + 1], params[#params + 1] = 0x00, ""
    end
    local out = {}
    for group = 0, #ops / 4 - 1 do
      local opcodeBytes = {}
      for slot = 1, 4 do
        opcodeBytes[slot] = string.char(ops[group * 4 + slot])
      end
      out[#out + 1] = table.concat(opcodeBytes)
      for slot = 1, 4 do
        out[#out + 1] = params[group * 4 + slot]
      end
    end
    return table.concat(out)
  end
  local bankPath = "assets/generated/maps/geometry/neighbor-bank.g4gx"
  local bankBytes = NativeGxFormat.encode({
    draws = {
      {
        commands = triangle({ { 0, 0, 0 }, { 2, 0, 0 }, { 2, 0, 2 } }),
        nodeIndex = 0,
        materialIndex = 0,
        shapeIndex = 0,
        transformMode = "static",
      },
      {
        commands = triangle({ { 4, 0, 0 }, { 6, 0, 0 }, { 6, 0, 2 } }),
        nodeIndex = 0,
        materialIndex = 0,
        shapeIndex = 0,
        transformMode = "static",
      },
    },
  })
  local backend = FakeCache.new()
  backend:write(bankPath, bankBytes)
  local material = groundMaterial("neighbor-ground.png")
  local descriptors = {
    cell(32, 1, 0, material, { file = bankPath, drawIndex = 0 }),
    cell(-32, 1, 0, material, { file = bankPath, drawIndex = 1 }),
  }
  local requests = {}
  local queue = { requests = requests, _tokens = {}, _nextToken = 0 }
  function queue:request(kind, path, priority)
    self._nextToken = self._nextToken + 1
    local token = self._nextToken
    requests[#requests + 1] = { kind = kind, path = path, priority = priority }
    self._tokens[token] = { kind = kind, payload = SceneMesh.prepareNativeBank(backend:read(path), path) }
    return token
  end
  function queue:poll(token)
    if self._tokens[token] == nil then
      return "failed", "unknown preparation token"
    end
    return "ready"
  end
  function queue:take(token)
    local record = assert(self._tokens[token], "take before ready")
    self._tokens[token] = nil
    return record.payload
  end
  function queue:cancel(token)
    self._tokens[token] = nil
  end
  function queue:release() end

  local images = SharedImagePoolFake.new()
  local ring = NeighborRing.load(backend, descriptors, {
    meshBuilder = fakeMeshBuilder,
    imageAssets = images,
    graphics = STUB_GRAPHICS,
    assetPreparation = queue,
  })
  Assert.equal(#requests, 1, "one bank request serves every neighbor draw that selects it")
  Assert.equal(requests[1].kind, "g4gx", "native neighbor geometry is prepared as a model bank")
  Assert.equal(#ring.draws, 2, "both neighbor cells draw their selected bank draw")
  Assert.equal(ring.draws[1].center[1], 1, "the realized center comes from the selected draw")
  Assert.equal(ring.draws[1].transform[13], 32, "the cell offset still bakes into the draw transform")
  Assert.equal(ring.draws[2].transform[13], -32, "the second cell keeps its own offset")
  ring:release()
end

return { tests = T }
