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
local CacheFs = require("libs.storage.src.CacheFs")
local MeshWriter = require("libs.assets.src.model.MeshWriter")
local PngWriter = require("libs.assets.src.PngWriter")
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

return {
  metadata = { capabilities = { "graphics" } },
  tests = T,
}
