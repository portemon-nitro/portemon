-- The one real-thread/real-Data proof for the presentation preparation
-- worker: a real love.thread worker reads real save-directory cache bytes,
-- decodes/packs a mesh and decodes an image, and replies with LÖVE
-- Data/ImageData -- never a Mesh or Image. Every other queue behavior
-- (priority, cancellation, disposal) is covered deterministically with a
-- fake thread/channel in the component-layer queue tests; this suite proves
-- only that the real worker/Data path works and never touches love.graphics.
-- The real filesystem is required here (unlike the in-memory FakeCache used
-- elsewhere) because a worker Lua state cannot see this state's closures --
-- only the shared save directory and Channel-safe Variants cross the
-- boundary.

local Assert = require("tests.support.Assert")
local ArtifactPublisher = require("libs.storage.src.ArtifactPublisher")
local CacheFs = require("libs.storage.src.CacheFs")
local MeshWriter = require("libs.assets.src.model.MeshWriter")
local PngWriter = require("tests.support.PngEncoder")
local SceneMesh = require("libs.hgss.src.presentation.SceneMesh")

local T = {}

local VERSION_ID = "asset-preparation-worker-test"
local MESH_PATH = "geometry/prepared.g4mesh"
local TEXTURE_PATH = "textures/prepared.png"
local COMPRESSED_MESH_PATH = "geometry/compressed.g4mesh"

local function requireQueue()
  local ok, AssetPreparationQueue = pcall(require, "libs.hgss.src.presentation.AssetPreparationQueue")
  Assert.isTrue(ok, "the production asset preparation queue boundary is missing: " .. tostring(AssetPreparationQueue))
  return AssetPreparationQueue --[[@as table]]
end

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

local function preparedCache()
  local cache = CacheFs.forVersion(VERSION_ID)
  cache:write(MESH_PATH, MeshWriter.encode(triangleBatch()))
  cache:write(TEXTURE_PATH, PngWriter.encode(2, 2, string.char(255, 0, 0, 255):rep(4)))
  return cache
end

function T.worker_prepares_mesh_and_image_payloads_without_touching_graphics()
  local AssetPreparationQueue = requireQueue()
  local cache = preparedCache()
  local statsBefore = love.graphics.getStats()

  local ok, err = pcall(function()
    local queue = AssetPreparationQueue.new(cache)
    local meshToken = queue:request("mesh", MESH_PATH, "demand")
    local imageToken = queue:request("image", TEXTURE_PATH, "demand")

    local mesh = queue:wait(meshToken)
    Assert.equal(mesh.vertexCount, 3)
    Assert.equal(mesh.indexCount, 3)
    Assert.equal(mesh.indexType, "uint16")
    Assert.isNil(mesh.mesh, "the worker never realizes a love Mesh")
    Assert.notNil(mesh.vertexData, "the worker replies with packed vertex Data")
    Assert.notNil(mesh.indexData, "the worker replies with packed index Data")

    local image = queue:wait(imageToken)
    Assert.isNil(image.image, "the worker never realizes a love Image")
    Assert.notNil(image.imageData, "the worker replies with decoded ImageData")
    Assert.equal(image.imageData:getWidth(), 2)
    Assert.equal(image.imageData:getHeight(), 2)

    queue:release()
  end)

  local statsAfter = love.graphics.getStats()
  cache:removeTree("")

  if not ok then
    error(err, 0)
  end
  Assert.equal(statsAfter.images, statsBefore.images, "preparation alone creates no GPU Image")
  Assert.equal(statsAfter.canvases, statsBefore.canvases, "preparation alone creates no GPU Canvas")
end

function T.packaged_worker_module_resolves_and_prepares_through_a_real_thread()
  -- The worker entry must resolve through the normal packaged require path
  -- and expose its channel entry instead of executing its channel loop on
  -- require: a small literal bootstrap requires this module inside the real
  -- worker thread, so checkout-file reads cannot be the load mechanism.
  local ok, worker = pcall(require, "libs.hgss.src.presentation.asset_preparation_worker")
  Assert.isTrue(ok, "the packaged worker module must be requirable in the main state: " .. tostring(worker))
  Assert.equal(
    type(worker.run),
    "function",
    "the worker module exposes its request/reply entry for the packaged bootstrap"
  )

  -- The real-thread half: default construction still starts a worker that
  -- prepares real cache bytes into CPU payloads without touching graphics.
  local AssetPreparationQueue = requireQueue()
  local cache = preparedCache()
  local statsBefore = love.graphics.getStats()

  local runOk, runErr = pcall(function()
    local queue = AssetPreparationQueue.new(cache)
    local meshToken = queue:request("mesh", MESH_PATH, "demand")
    local imageToken = queue:request("image", TEXTURE_PATH, "demand")

    local mesh = queue:wait(meshToken)
    Assert.notNil(mesh.vertexData, "the packaged worker replies with packed vertex Data")
    Assert.notNil(mesh.indexData, "the packaged worker replies with packed index Data")

    local image = queue:wait(imageToken)
    Assert.notNil(image.imageData, "the packaged worker replies with decoded ImageData")
    Assert.equal(image.imageData:getWidth(), 2)
    Assert.equal(image.imageData:getHeight(), 2)

    queue:release()
  end)

  local statsAfter = love.graphics.getStats()
  cache:removeTree("")

  if not runOk then
    error(runErr, 0)
  end
  Assert.equal(statsAfter.images, statsBefore.images, "preparation alone creates no GPU Image")
end

function T.invalid_image_bytes_fail_preparation_without_hanging_the_worker()
  local AssetPreparationQueue = requireQueue()
  local cache = preparedCache()
  cache:write(TEXTURE_PATH, "not a png")
  local statsBefore = love.graphics.getStats()

  local meshAfterFailure = false
  local runOk, runErr = pcall(function()
    local queue = AssetPreparationQueue.new(cache)
    local badToken = queue:request("image", TEXTURE_PATH, "demand")
    local waitOk, waitErr = pcall(queue.wait, queue, badToken)
    Assert.isFalse(waitOk, "undecodable image bytes fail instead of hanging the waiter")
    Assert.isTrue(
      tostring(waitErr):find(TEXTURE_PATH, 1, true) ~= nil,
      "the image failure names its logical path: " .. tostring(waitErr)
    )

    local meshToken = queue:request("mesh", MESH_PATH, "demand")
    local mesh = queue:wait(meshToken)
    Assert.notNil(mesh.vertexData, "the worker loop survives a failed image decode")
    meshAfterFailure = true

    queue:release()
  end)

  local statsAfter = love.graphics.getStats()
  cache:removeTree("")

  if not runOk then
    error(runErr, 0)
  end
  Assert.isTrue(meshAfterFailure, "a later mesh request still prepares after the image failure")
  Assert.equal(statsAfter.images, statsBefore.images, "preparation alone creates no GPU Image")
end

-- A wrapped mesh still prepares to identical upload payloads: the stored
-- bytes carry the envelope, the worker decodes them off the main thread
-- through the versioned cache, and the prepared geometry matches a direct
-- decode of the logical bytes. The test itself never reads cache bytes on
-- the main thread, so matching geometry proves the decode happened in the
-- worker.
function T.compressed_mesh_prepares_off_main_thread_through_the_versioned_cache()
  local AssetPreparationQueue = requireQueue()
  local cache = CacheFs.forVersion(VERSION_ID)
  local vertices, indices = {}, {}
  for i = 0, 159 do
    local base = i * 3
    local corners = { { 0, 0 }, { 2, 0 }, { 0, 2 } }
    for _, corner in ipairs(corners) do
      vertices[#vertices + 1] = {
        x = corner[1],
        y = 0,
        z = corner[2],
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
    indices[#indices + 1] = base
    indices[#indices + 1] = base + 1
    indices[#indices + 1] = base + 2
  end
  local logical = MeshWriter.encode({ vertices = vertices, indices = indices })
  Assert.isTrue(#logical >= 1024, "the mesh fixture must clear the wrap threshold")
  cache:write(COMPRESSED_MESH_PATH, logical)
  local physical = love.filesystem.read(cache:resolve(COMPRESSED_MESH_PATH))
  Assert.notNil(physical, "the stored mesh must be readable")
  assert(type(physical) == "string", "stored mesh bytes must be a string")
  Assert.equal(physical:sub(1, 4), "PDC1", "the stored mesh is wrapped")
  Assert.isTrue(#physical < #logical, "the wrapped mesh saves space")
  local baseline = SceneMesh.prepareUpload(logical, COMPRESSED_MESH_PATH)
  local statsBefore = love.graphics.getStats()

  local runOk, runErr = pcall(function()
    local queue = AssetPreparationQueue.new(cache)
    local meshToken = queue:request("mesh", COMPRESSED_MESH_PATH, "demand")
    local prepared = queue:wait(meshToken)
    Assert.isNil(prepared.mesh, "the worker never realizes a love Mesh")
    Assert.equal(prepared.vertexCount, baseline.vertexCount)
    Assert.equal(prepared.indexCount, baseline.indexCount)
    Assert.equal(prepared.indexType, baseline.indexType)
    Assert.notNil(prepared.vertexData, "the worker replies with packed vertex Data")
    Assert.notNil(prepared.indexData, "the worker replies with packed index Data")
    Assert.equal(prepared.vertexData:getSize(), baseline.vertexData:getSize())
    Assert.equal(prepared.indexData:getSize(), baseline.indexData:getSize())
    Assert.equal(
      love.data.hash("sha256", prepared.vertexData:getString()),
      love.data.hash("sha256", baseline.vertexData:getString()),
      "the worker decoded the same vertex bytes"
    )
    Assert.equal(
      love.data.hash("sha256", prepared.indexData:getString()),
      love.data.hash("sha256", baseline.indexData:getString()),
      "the worker decoded the same index bytes"
    )
    queue:release()
  end)

  local statsAfter = love.graphics.getStats()
  cache:removeTree("")

  if not runOk then
    error(runErr, 0)
  end
  Assert.equal(statsAfter.images, statsBefore.images, "preparation alone creates no GPU Image")
end

-- Icon-page preparation reuses this exact worker path: an icon-page-sized
-- PNG decodes on the worker thread into ImageData the main thread later
-- realizes exactly once, with no GPU object created by preparation itself.
function T.icon_sized_image_decodes_through_the_real_worker_without_graphics()
  local AssetPreparationQueue = requireQueue()
  local cache = CacheFs.forVersion(VERSION_ID)
  local pixels = {}
  for _ = 1, 256 * 128 do
    pixels[#pixels + 1] = string.char(40, 120, 200, 255)
  end
  cache:write("party/page-0.png", PngWriter.encode(256, 128, table.concat(pixels)))
  local statsBefore = love.graphics.getStats()

  local runOk, runErr = pcall(function()
    local queue = AssetPreparationQueue.new(cache)
    local token = queue:request("image", "party/page-0.png", "demand")
    local image = queue:wait(token)
    Assert.isNil(image.image, "the worker never realizes a love Image")
    Assert.notNil(image.imageData, "the worker replies with decoded ImageData")
    Assert.equal(image.imageData:getWidth(), 256)
    Assert.equal(image.imageData:getHeight(), 128)
    queue:release()
  end)

  local statsAfter = love.graphics.getStats()
  cache:removeTree("")

  if not runOk then
    error(runErr, 0)
  end
  Assert.equal(statsAfter.images, statsBefore.images, "preparation alone creates no GPU Image")
end

-- A generated PNG prepares through the real worker into a classified
-- derivative payload, and a second request for the same source reuses the
-- privately stored derivative through the same worker cache: both payloads
-- carry identical source and pixel hashes with no GPU object created by
-- preparation itself. Replacing the generated file at the same path through
-- the staged publication lifecycle is visible to the next request on the
-- same live worker: the follow-up payloads bind the replacement bytes, and
-- repeating the replacement reuses its stored derivative.
function T.image_prepares_through_the_real_worker_from_the_png_alone()
  local AssetPreparationQueue = requireQueue()
  local cache = CacheFs.forVersion(VERSION_ID)
  local logicalPath = "assets/generated/textures/derivative.png"
  local pngA = PngWriter.encode(2, 2, string.char(255, 0, 0, 255):rep(4))
  local pngB = PngWriter.encode(2, 2, string.char(0, 64, 255, 255):rep(4))
  Assert.isTrue(pngA ~= pngB, "the replacement fixture must carry distinct source bytes")
  cache:write(logicalPath, pngA)
  local statsBefore = love.graphics.getStats()

  local runOk, runErr = pcall(function()
    local queue = AssetPreparationQueue.new(cache)
    local firstToken = queue:request("image-derivative", logicalPath, "demand")
    local first = queue:wait(firstToken)
    Assert.equal(first.width, 2)
    Assert.equal(first.height, 2)
    Assert.isTrue(first.kind == "r8" or first.kind == "rgba8", "the derivative classifies to a known layout")
    Assert.notNil(first.indexData, "the worker replies with packed index Data")

    local publisher = ArtifactPublisher.begin(cache, "derivative-refresh", { logicalPath })
    publisher.stage:write(logicalPath, pngB)
    Assert.isTrue(publisher:publish(), "the replacement publication must succeed")

    local secondToken = queue:request("image-derivative", logicalPath, "demand")
    local second = queue:wait(secondToken)
    Assert.isTrue(
      second.pixelHash ~= first.pixelHash,
      "the replacement pixels must differ from the earlier payload"
    )
    Assert.equal(second.width, 2)
    Assert.equal(second.height, 2)
    Assert.isTrue(
      second.kind == "r8" or second.kind == "rgba8",
      "the replacement derivative classifies to a known layout"
    )
    Assert.notNil(second.indexData, "the worker replies with packed index Data")

    local thirdToken = queue:request("image-derivative", logicalPath, "demand")
    local third = queue:wait(thirdToken)
    Assert.equal(third.pixelHash, second.pixelHash, "the repeat preparation reads the same PNG to the same pixels")
    Assert.equal(third.width, second.width)
    Assert.equal(third.height, second.height)

    queue:release()
  end)

  local statsAfter = love.graphics.getStats()
  cache:removeTree("")
  pcall(function()
    CacheFs.forArtifactStage(VERSION_ID, "derivative-refresh"):removeTree("")
  end)

  if not runOk then
    error(runErr, 0)
  end
  Assert.equal(statsAfter.images, statsBefore.images, "preparation alone creates no GPU Image")
  Assert.equal(statsAfter.canvases, statsBefore.canvases, "preparation alone creates no GPU Canvas")
end

-- A generated PCM sample prepares through the real worker as one
-- transferable ByteData holding the exact logical bytes, proving the
-- audio-sample branch rides the same worker cache as meshes and images.
function T.audio_sample_prepares_through_the_real_worker_as_transferable_bytes()
  local AssetPreparationQueue = requireQueue()
  local cache = CacheFs.forVersion(VERSION_ID)
  local logical = string.rep("\1\2\3\4", 512)
  cache:write("data/generated/audio/sample.pcm16le", logical)
  local statsBefore = love.graphics.getStats()

  local runOk, runErr = pcall(function()
    local queue = AssetPreparationQueue.new(cache)
    local token = queue:request("audio-sample", "data/generated/audio/sample.pcm16le", "demand")
    local prepared = queue:wait(token)
    Assert.equal(prepared.size, #logical, "the sample payload sizes the exact logical bytes")
    Assert.notNil(prepared.byteData, "the worker replies with transferable sample Data")
    Assert.equal(prepared.byteData:getString(), logical, "the sample bytes survive the worker round trip")

    local repeatToken = queue:request("audio-sample", "data/generated/audio/sample.pcm16le", "demand")
    local repeated = queue:wait(repeatToken)
    Assert.equal(repeated.byteData:getString(), logical, "a repeat preparation decodes identical sample bytes")

    queue:release()
  end)

  local statsAfter = love.graphics.getStats()
  cache:removeTree("")

  if not runOk then
    error(runErr, 0)
  end
  Assert.equal(statsAfter.images, statsBefore.images, "preparation alone creates no GPU Image")
end


-- The engine-owned model bank under test: two terrain-eligible draws of one
-- source model that share the boundary x=0. The coarse draw carries the
-- unbroken span z in [0,4]; the fine neighbour breaks the same span at
-- z=2, which is the T-junction the producer repair splices into the coarse
-- side before the surface ever reaches the GPU.
local TERRAIN_BANK_PATH = "geometry/terrain-bank.g4gx"

local function gxU32(value)
  return string.char(
    value % 256,
    math.floor(value / 256) % 256,
    math.floor(value / 65536) % 256,
    math.floor(value / 16777216) % 256
  )
end

local function gxVtx16(x, y, z)
  local function fx(value)
    return math.floor(value * 4096) % 0x10000
  end
  return gxU32(fx(x) + fx(y) * 0x10000) .. gxU32(fx(z))
end

-- BEGIN_VTXS(quads) with a normal and a positioned vertex per corner, then
-- END_VTXS, packed in the DS geometry FIFO's four-opcode groups.
local function gxQuad(vertices)
  local ops = { 0x40 }
  local params = { gxU32(1) } -- primitive type 1: quads
  for _, vertex in ipairs(vertices) do
    ops[#ops + 1], params[#params + 1] = 0x21, gxU32(0x00000FFF)
    ops[#ops + 1], params[#params + 1] = 0x22, gxU32(0)
    ops[#ops + 1], params[#params + 1] = 0x23, gxVtx16(vertex[1], vertex[2], vertex[3])
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

---@param value unknown
---@return string
local function gxBankBytes(value)
  if type(value) == "string" then
    return value
  end
  if type(value) == "table" and value.data ~= nil then
    return gxBankBytes(value.data)
  end
  assert(type(value) == "userdata" and type(value.getString) == "function", "the model bank travels as bytes")
  return value:getString()
end

local function terrainBank()
  local ok, NativeGxFormat = pcall(require, "libs.assets.src.model.NativeGxFormat")
  Assert.isTrue(
    ok and type(NativeGxFormat) == "table",
    "the native model bank format is missing: terrain draws cannot be decoded and repaired as one grouped bank"
  )
  return gxBankBytes(NativeGxFormat.encode({
    draws = {
      {
        commands = gxQuad({ { -4, 1, 0 }, { 0, 1, 0 }, { 0, 1, 4 }, { -4, 1, 4 } }),
        nodeIndex = 0,
        materialIndex = 0,
        shapeIndex = 0,
        transformMode = "static",
        terrainBoundaryEligible = true,
      },
      {
        commands = gxQuad({ { 0, 1, 0 }, { 4, 1, 0 }, { 4, 1, 2 }, { 0, 1, 2 } })
          .. gxQuad({ { 0, 1, 2 }, { 4, 1, 2 }, { 4, 1, 4 }, { 0, 1, 4 } }),
        nodeIndex = 0,
        materialIndex = 1,
        shapeIndex = 0,
        transformMode = "static",
        terrainBoundaryEligible = true,
      },
    },
  }))
end

-- Terrain boundary repair runs over the whole eligible draw group of one
-- source model bank when the first draw is decoded: the coarse side adopts the
-- neighbour's breakpoint before any of the group reaches the GPU, and a later
-- request for the sibling draw decodes the already-conformed group instead of
-- repairing it again per draw.
function T.terrain_bank_group_is_conformed_before_the_first_draw_is_used()
  local AssetPreparationQueue = requireQueue()
  local cache = CacheFs.forVersion(VERSION_ID)
  local bank = terrainBank()
  local runOk, runErr = pcall(function()
    cache:write(TERRAIN_BANK_PATH, bank)
    local queue = AssetPreparationQueue.new(cache)
    local coarseToken = queue:request("g4gx", { file = TERRAIN_BANK_PATH, drawIndex = 0 }, "demand")
    local coarse = queue:wait(coarseToken)
    Assert.equal(coarse.indexCount, 9, "the coarse draw adopts the neighbour's boundary breakpoint")
    Assert.equal(coarse.vertexCount, 5, "the repaired draw expresses the shared breakpoint once")
    Assert.isNil(coarse.mesh, "the worker never realizes a love Mesh")

    local fineToken = queue:request("g4gx", { file = TERRAIN_BANK_PATH, drawIndex = 1 }, "demand")
    local fine = queue:wait(fineToken)
    Assert.equal(fine.indexCount, 12, "the already-segmented neighbour keeps its four triangles")

    local repeatToken = queue:request("g4gx", { file = TERRAIN_BANK_PATH, drawIndex = 0 }, "demand")
    local repeated = queue:wait(repeatToken)
    Assert.equal(repeated.indexCount, 9, "repeated demand never repairs the same group twice")
    Assert.equal(repeated.vertexCount, 5, "repeated demand keeps the repaired topology stable")
    queue:release()
  end)
  cache:removeTree("")
  if not runOk then
    error(runErr, 0)
  end
end

return {
  metadata = { capabilities = { "graphics" } },
  tests = T,
}
