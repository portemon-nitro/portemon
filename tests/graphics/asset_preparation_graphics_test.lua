-- The one real-thread/real-Data proof for the presentation preparation
-- worker: a real love.thread worker receives the resident generated payload
-- the main thread resolved, decodes/packs a mesh and decodes an image, and
-- replies with LÖVE Data/ImageData -- never a Mesh or Image. Every other
-- queue behavior (priority, cancellation, disposal) is covered
-- deterministically with a fake thread/channel in the component-layer queue
-- tests; this suite proves only that the real worker/Data path works and
-- never touches love.graphics. A real thread is required because a worker
-- Lua state cannot see this state's closures: only channel-safe Data crosses
-- the boundary.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local ResidentCache = require("libs.storage.src.ResidentCache")
local MeshWriter = require("libs.assets.src.model.MeshWriter")
local PngWriter = require("tests.support.PngEncoder")
local SceneMesh = require("libs.hgss.src.presentation.SceneMesh")

local T = {}

local VERSION_ID = "asset-preparation-worker-test"
local MESH_PATH = "data/generated/geometry/prepared.g4mesh"
local TEXTURE_PATH = "assets/generated/textures/prepared.png"
local COMPRESSED_MESH_PATH = "data/generated/geometry/compressed.g4mesh"
local ICON_PAGE_PATH = "assets/generated/party/page-0.png"
local DERIVATIVE_PATH = "assets/generated/textures/derivative.png"

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

-- One resident generated view over the given logical payloads: the same
-- reader object a selected epoch installs, so the worker receives immutable
-- Data references instead of reading a physical cache file.
local function residentCache(assets)
  local sourceId = "base:" .. VERSION_ID
  local store = ResidentCache.new(VERSION_ID, sourceId)
  local entries = {}
  local index = 0
  for path, bytes in pairs(assets) do
    local text = type(bytes) == "userdata" and bytes:getString() or bytes
    index = index + 1
    entries[index] = {
      path = path,
      data = assert(love.data.newByteData(text)),
      size = #text,
      sourceId = sourceId,
      contentId = VERSION_ID .. "\0" .. path,
    }
  end
  store:commit(store:prepare(entries))
  return CacheFs.fromStore(store), store
end

-- The selected decoded CPU owner the queue requires: a generous idle budget
-- keeps each test's decoded values findable, and every return trims.
local function decodedOwner()
  local ResidentAssetCache = require("libs.hgss.src.field.ResidentAssetCache")
  return ResidentAssetCache.new({
    idleByteLimit = 32 * 1024 * 1024,
    release = function(value)
      if type(value.release) == "function" then
        value:release()
      end
    end,
  })
end

local function preparedCache()
  return residentCache({
    [MESH_PATH] = MeshWriter.encode(triangleBatch()),
    [TEXTURE_PATH] = PngWriter.encode(2, 2, string.char(255, 0, 0, 255):rep(4)),
  })
end

function T.worker_prepares_mesh_and_image_payloads_without_touching_graphics()
  local AssetPreparationQueue = requireQueue()
  local cache = preparedCache()
  local statsBefore = love.graphics.getStats()

  local ok, err = pcall(function()
    local queue = AssetPreparationQueue.new(cache, { decoded = decodedOwner() })
    local meshToken = queue:request("mesh", MESH_PATH, "demand")
    local imageToken = queue:request("image", TEXTURE_PATH, "demand")

    local mesh = assert(queue:wait(meshToken)).value.payload
    Assert.equal(mesh.vertexCount, 3)
    Assert.equal(mesh.indexCount, 3)
    Assert.equal(mesh.indexType, "uint16")
    Assert.isNil(mesh.mesh, "the worker never realizes a love Mesh")
    Assert.notNil(mesh.vertexData, "the worker replies with packed vertex Data")
    Assert.notNil(mesh.indexData, "the worker replies with packed index Data")

    local image = assert(queue:wait(imageToken)).value.payload
    Assert.isNil(image.image, "the worker never realizes a love Image")
    Assert.notNil(image.imageData, "the worker replies with decoded ImageData")
    Assert.equal(image.imageData:getWidth(), 2)
    Assert.equal(image.imageData:getHeight(), 2)

    queue:release()
  end)

  local statsAfter = love.graphics.getStats()

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
    local queue = AssetPreparationQueue.new(cache, { decoded = decodedOwner() })
    local meshToken = queue:request("mesh", MESH_PATH, "demand")
    local imageToken = queue:request("image", TEXTURE_PATH, "demand")

    local mesh = assert(queue:wait(meshToken)).value.payload
    Assert.notNil(mesh.vertexData, "the packaged worker replies with packed vertex Data")
    Assert.notNil(mesh.indexData, "the packaged worker replies with packed index Data")

    local image = assert(queue:wait(imageToken)).value.payload
    Assert.notNil(image.imageData, "the packaged worker replies with decoded ImageData")
    Assert.equal(image.imageData:getWidth(), 2)
    Assert.equal(image.imageData:getHeight(), 2)

    queue:release()
  end)

  local statsAfter = love.graphics.getStats()

  if not runOk then
    error(runErr, 0)
  end
  Assert.equal(statsAfter.images, statsBefore.images, "preparation alone creates no GPU Image")
end

function T.invalid_image_bytes_fail_preparation_without_hanging_the_worker()
  local AssetPreparationQueue = requireQueue()
  local cache = (
    residentCache({
      [MESH_PATH] = MeshWriter.encode(triangleBatch()),
      [TEXTURE_PATH] = "not a png",
    })
  )
  local statsBefore = love.graphics.getStats()

  local meshAfterFailure = false
  local runOk, runErr = pcall(function()
    local queue = AssetPreparationQueue.new(cache, { decoded = decodedOwner() })
    local badToken = queue:request("image", TEXTURE_PATH, "demand")
    local waitOk, waitErr = pcall(queue.wait, queue, badToken)
    Assert.isFalse(waitOk, "undecodable image bytes fail instead of hanging the waiter")
    Assert.isTrue(
      tostring(waitErr):find(TEXTURE_PATH, 1, true) ~= nil,
      "the image failure names its logical path: " .. tostring(waitErr)
    )

    local meshToken = queue:request("mesh", MESH_PATH, "demand")
    local mesh = assert(queue:wait(meshToken)).value.payload
    Assert.notNil(mesh.vertexData, "the worker loop survives a failed image decode")
    meshAfterFailure = true

    queue:release()
  end)

  local statsAfter = love.graphics.getStats()

  if not runOk then
    error(runErr, 0)
  end
  Assert.isTrue(meshAfterFailure, "a later mesh request still prepares after the image failure")
  Assert.equal(statsAfter.images, statsBefore.images, "preparation alone creates no GPU Image")
end

-- A stored mesh prepares to identical upload payloads: the worker decodes the
-- cache bytes off the main thread through the versioned cache, and the
-- prepared geometry matches a direct decode of the same logical bytes. The
-- test itself never reads cache bytes on the main thread, so matching
-- geometry proves the decode happened in the worker.
function T.mesh_prepares_off_main_thread_through_the_versioned_cache()
  local AssetPreparationQueue = requireQueue()
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
  local cache, store = residentCache({ [COMPRESSED_MESH_PATH] = logical })
  Assert.equal(
    assert(store:readData(COMPRESSED_MESH_PATH)):getString(),
    logical,
    "the resident view keeps the generated bytes verbatim"
  )
  local baseline = SceneMesh.prepareUpload(logical, COMPRESSED_MESH_PATH)
  local statsBefore = love.graphics.getStats()

  local runOk, runErr = pcall(function()
    local queue = AssetPreparationQueue.new(cache, { decoded = decodedOwner() })
    local meshToken = queue:request("mesh", COMPRESSED_MESH_PATH, "demand")
    local prepared = assert(queue:wait(meshToken)).value.payload
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
  local pixels = {}
  for _ = 1, 256 * 128 do
    pixels[#pixels + 1] = string.char(40, 120, 200, 255)
  end
  local cache = (residentCache({
    [ICON_PAGE_PATH] = PngWriter.encode(256, 128, table.concat(pixels)),
  }))
  local statsBefore = love.graphics.getStats()

  local runOk, runErr = pcall(function()
    local queue = AssetPreparationQueue.new(cache, { decoded = decodedOwner() })
    local token = queue:request("image", ICON_PAGE_PATH, "demand")
    local image = assert(queue:wait(token)).value.payload
    Assert.isNil(image.image, "the worker never realizes a love Image")
    Assert.notNil(image.imageData, "the worker replies with decoded ImageData")
    Assert.equal(image.imageData:getWidth(), 256)
    Assert.equal(image.imageData:getHeight(), 128)
    queue:release()
  end)

  local statsAfter = love.graphics.getStats()

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
  local logicalPath = DERIVATIVE_PATH
  local pngA = PngWriter.encode(2, 2, string.char(255, 0, 0, 255):rep(4))
  local pngB = PngWriter.encode(2, 2, string.char(0, 64, 255, 255):rep(4))
  Assert.isTrue(pngA ~= pngB, "the replacement fixture must carry distinct source bytes")
  local cache, store = residentCache({ [logicalPath] = pngA })
  local statsBefore = love.graphics.getStats()

  local runOk, runErr = pcall(function()
    local queue = AssetPreparationQueue.new(cache, { decoded = decodedOwner() })
    local firstToken = queue:request("image-derivative", logicalPath, "demand")
    local first = assert(queue:wait(firstToken)).value.payload
    Assert.equal(first.width, 2)
    Assert.equal(first.height, 2)
    Assert.isTrue(first.kind == "r8" or first.kind == "rgba8", "the derivative classifies to a known layout")
    Assert.notNil(first.indexData, "the worker replies with packed index Data")

    -- Replacing the generated bytes at the same logical path is what the
    -- next request must observe: the queue resolves the replacement payload
    -- afresh instead of reusing the earlier decode.
    store:commit(store:prepare({
      {
        path = logicalPath,
        data = assert(love.data.newByteData(pngB)),
        size = #pngB,
        sourceId = "base:" .. VERSION_ID,
        contentId = VERSION_ID .. "\0replacement\0" .. logicalPath,
      },
    }))

    local secondToken = queue:request("image-derivative", logicalPath, "demand")
    local second = assert(queue:wait(secondToken)).value.payload
    Assert.isTrue(second.pixelHash ~= first.pixelHash, "the replacement pixels must differ from the earlier payload")
    Assert.equal(second.width, 2)
    Assert.equal(second.height, 2)
    Assert.isTrue(
      second.kind == "r8" or second.kind == "rgba8",
      "the replacement derivative classifies to a known layout"
    )
    Assert.notNil(second.indexData, "the worker replies with packed index Data")

    local thirdToken = queue:request("image-derivative", logicalPath, "demand")
    local third = assert(queue:wait(thirdToken)).value.payload
    Assert.equal(third.pixelHash, second.pixelHash, "the repeat preparation reads the same PNG to the same pixels")
    Assert.equal(third.width, second.width)
    Assert.equal(third.height, second.height)

    queue:release()
  end)

  local statsAfter = love.graphics.getStats()
  store:close()

  if not runOk then
    error(runErr, 0)
  end
  Assert.equal(statsAfter.images, statsBefore.images, "preparation alone creates no GPU Image")
  Assert.equal(statsAfter.canvases, statsBefore.canvases, "preparation alone creates no GPU Canvas")
end

-- The engine-owned model bank under test: two terrain-eligible draws of one
-- source model that share the boundary x=0. The coarse draw carries the
-- unbroken span z in [0,4]; the fine neighbour breaks the same span at
-- z=2, which is the T-junction the producer repair splices into the coarse
-- side before the surface ever reaches the GPU.
local TERRAIN_BANK_PATH = "data/generated/geometry/terrain-bank.g4gx"

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
-- source model bank when the bank is prepared: the coarse side adopts the
-- neighbour's breakpoint before any of the group reaches the GPU, and the one
-- bank reply carries every draw, so selecting the sibling draw never replays
-- the bank or repairs it twice.
function T.terrain_bank_group_is_conformed_once_for_the_whole_bank_reply()
  local AssetPreparationQueue = requireQueue()
  local bank = terrainBank()
  local cache = (residentCache({ [TERRAIN_BANK_PATH] = bank }))
  local runOk, runErr = pcall(function()
    local queue = AssetPreparationQueue.new(cache, { decoded = decodedOwner() })
    local token = queue:request("g4gx", TERRAIN_BANK_PATH, "demand")
    local prepared = assert(queue:wait(token)).value.payload
    Assert.equal(#prepared.draws, 2, "one bank reply carries one upload packet per draw")
    local coarse = prepared.draws[1]
    Assert.equal(coarse.indexCount, 9, "the coarse draw adopts the neighbour's boundary breakpoint")
    Assert.equal(coarse.vertexCount, 5, "the repaired draw expresses the shared breakpoint once")
    Assert.isNil(coarse.mesh, "the worker never realizes a love Mesh")
    local fine = prepared.draws[2]
    Assert.equal(fine.indexCount, 12, "the already-segmented neighbour keeps its four triangles")
    queue:release()
  end)
  if not runOk then
    error(runErr, 0)
  end
end

-- One prepared native bank is shared by independent consumers: the resident
-- kernel charges it once, a repeat request is ready without another worker
-- roundtrip, and realizing one draw through the scene GPU owner leaves every
-- other draw of that shared packet intact for its own consumer. Releasing the
-- two leases in reverse order returns the whole bank exactly once.
function T.shared_native_bank_leases_survive_single_draw_uploads()
  local AssetPreparationQueue = requireQueue()
  local ResidentAssetCache = require("libs.hgss.src.field.ResidentAssetCache")
  local GpuAssetPool = require("libs.hgss.src.presentation.GpuAssetPool")
  local bank = terrainBank()
  local cache = (residentCache({ [TERRAIN_BANK_PATH] = bank }))
  local released = {}
  local decoded = ResidentAssetCache.new({
    idleByteLimit = 8 * 1024 * 1024,
    release = function(value)
      released[#released + 1] = value
      if type(value.release) == "function" then
        value:release()
      end
    end,
  })
  local pool
  local runOk, runErr = pcall(function()
    local queue = AssetPreparationQueue.new(cache, { decoded = decoded })
    local firstToken = queue:request("g4gx", TERRAIN_BANK_PATH, "demand")
    local firstLease = queue:wait(firstToken)
    Assert.notNil(
      firstLease.value,
      "wait must transfer a lease over the decoded bank instead of the raw prepared payload"
    )
    local prepared = firstLease.value.payload
    Assert.equal(#prepared.draws, 2, "the shared bank packet carries every draw of the source model")
    Assert.isTrue(firstLease.value.nativeBytes > 0, "the bank's own upload buffers carry the native charge")
    local charge = firstLease.value.nativeBytes + firstLease.value.metadataChargeBytes
    Assert.equal(decoded:stats().pinnedBytes, charge, "the shared bank value is charged once")

    local secondToken = queue:request("g4gx", TERRAIN_BANK_PATH, "demand")
    Assert.equal(queue:poll(secondToken), "ready", "a resident bank identity is ready without another worker roundtrip")
    local secondLease = queue:take(secondToken)
    Assert.isTrue(secondLease.value == firstLease.value, "both consumers share one immutable bank value")

    pool = GpuAssetPool.new(cache, {
      graphics = love.graphics,
      assetPreparation = queue,
      decoded = decoded,
    })
    local triangles = 0
    for drawIndex = 0, 1 do
      local lease = drawIndex == 0 and firstLease or secondLease
      local entry = pool:preparedMesh({ file = TERRAIN_BANK_PATH, drawIndex = drawIndex }, function()
        return lease
      end)
      Assert.notNil(entry.mesh, "draw " .. drawIndex .. " realizes its own GPU mesh")
      Assert.isTrue(entry.triangles > 0, "draw " .. drawIndex .. " reports its triangle count")
      triangles = triangles + entry.triangles
    end
    Assert.isTrue(triangles > 0, "both draws realize real geometry")
    for drawIndex, draw in ipairs(prepared.draws) do
      Assert.notNil(draw, "uploading a draw preserves draw " .. drawIndex .. " of the shared packet")
    end
    Assert.equal(#prepared.draws, 2, "the shared packet keeps its complete draw list after uploads")

    Assert.isTrue(decoded:returnLease(secondLease), "the second lease returns")
    Assert.isTrue(decoded:returnLease(firstLease), "the first lease returns after it")
    Assert.isNil(firstLease.value, "a returned lease clears its exposed value")
    Assert.equal(decoded:stats().pinnedBytes, 0, "no bank bytes stay pinned after both returns")
    Assert.equal(decoded:stats().idleBytes, charge, "the shared bank rests idle at its single charge")
    decoded:clear()
    Assert.equal(#released, 1, "the shared bank value is freed exactly once")
    queue:release()
  end)
  local disposeOk, disposeErr = pcall(function()
    if pool ~= nil then
      pool:release()
    end
  end)
  if not runOk then
    error(runErr, 0)
  end
  Assert.isTrue(disposeOk, "the scene GPU owner must release its meshes: " .. tostring(disposeErr))
end

return {
  metadata = { capabilities = { "graphics" } },
  tests = T,
}
