-- CPU-only entry point for the presentation preparation worker. Reads
-- confined cache bytes, decodes/packs mesh upload buffers, decodes image
-- data, or classifies private image derivatives, and replies with flat
-- records carrying love Data/ImageData. Never touches love.graphics: GPU
-- realization stays on the main thread.
--
-- The module is resolved through the packaged require path by a small
-- literal bootstrap: the queue starts its thread from that bootstrap, which
-- installs the explicitly supplied development search path when required
-- and then calls run with the queue's channel pair. Requiring this module
-- in any other state only exposes run without starting any work.

local Worker = {}

---@param requestChannel table<string, unknown> borrowed queue request channel
---@param replyChannel table<string, unknown> borrowed queue reply channel
function Worker.run(requestChannel, replyChannel)
  assert(requestChannel and replyChannel, "preparation worker requires its request/reply channels")

  pcall(require, "love.image")

  local Errors = require("libs.errors.src.Errors")
  local SceneMesh = require("libs.hgss.src.presentation.SceneMesh")

  local function fail(token, kind, path, cause)
    local text = Errors.is(cause) and Errors.format(cause) or tostring(cause)
    replyChannel:push({ token = token, ok = false, kind = kind, path = path, error = text })
  end

  -- Mesh bytes enter through the versioned cache so wrapped physical files
  -- decode off the main thread. The confined path travels with the request
  -- for channel compatibility, but the logical path is authoritative: it
  -- must resolve to exactly the confined path before any byte is read.
  local function readMeshBytes(versionId, logicalPath, path)
    assert(type(versionId) == "string" and versionId ~= "", "mesh preparation requires a version identity")
    assert(type(logicalPath) == "string" and logicalPath ~= "", "mesh preparation requires a logical path")
    local CacheFs = require("libs.storage.src.CacheFs")
    local cache = CacheFs.forVersion(versionId)
    if cache:resolve(logicalPath) ~= path then
      error("mesh preparation path escapes its confined cache entry", 0)
    end
    local bytes = cache:read(logicalPath)
    if bytes == nil then
      error("unreadable cache file: " .. tostring(path), 0)
    end
    return bytes
  end

  local function prepareMesh(token, versionId, logicalPath, path)
    local readOk, bytes = pcall(readMeshBytes, versionId, logicalPath, path)
    if not readOk then
      fail(token, "mesh", path, bytes)
      return
    end
    local ok, prepared = pcall(SceneMesh.prepareUpload, bytes, path)
    if not ok then
      fail(token, "mesh", path, prepared)
      return
    end
    replyChannel:push({
      token = token,
      ok = true,
      kind = "mesh",
      path = path,
      vertexData = prepared.vertexData,
      indexData = prepared.indexData,
      vertexCount = prepared.vertexCount,
      indexCount = prepared.indexCount,
      indexType = prepared.indexType,
      centerX = prepared.centerX,
      centerY = prepared.centerY,
      centerZ = prepared.centerZ,
      minX = prepared.minX,
      maxX = prepared.maxX,
      minY = prepared.minY,
      maxY = prepared.maxY,
      minZ = prepared.minZ,
      maxZ = prepared.maxZ,
    })
  end

  -- Effective PNG bytes are authoritative: the source hash binds the exact
  -- PNG compression while the persisted derivative carries the decoded
  -- pixel hash. A matching validated derivative is reused without decoding;
  -- anything else rebuilds from the trusted PNG. Replies carry only Data
  -- plus small metadata; a missing or damaged generated PNG fails loudly
  -- instead of substituting bytes. Never touches graphics.
  local function prepareImageDerivative(token, versionId, logicalPath, path)
    local function work()
      assert(
        type(versionId) == "string" and versionId ~= "",
        "image-derivative preparation requires a version identity"
      )
      assert(
        type(logicalPath) == "string" and logicalPath ~= "",
        "image-derivative preparation requires a logical path"
      )
      local CacheFs = require("libs.storage.src.CacheFs")
      local RuntimeImageCache = require("libs.assets.src.image.RuntimeImageCache")
      local ImageDerivative = require("libs.hgss.src.presentation.ImageDerivative")
      local cache = CacheFs.forVersion(versionId)
      if cache:resolve(logicalPath) ~= path then
        error("image-derivative preparation path escapes its confined cache entry", 0)
      end
      local pngBytes = cache:read(logicalPath)
      if pngBytes == nil then
        error("unreadable cache file: " .. tostring(path), 0)
      end
      local sourceHash = love.data.hash("sha256", pngBytes)
      local derivativePath = RuntimeImageCache.pathFor(sourceHash, RuntimeImageCache.FORMAT_VERSION)
      local reuseOk, reuseEntry = pcall(RuntimeImageCache.load, cache, derivativePath)
      if reuseOk and reuseEntry ~= nil and reuseEntry.sourceHash == sourceHash then
        -- Validated strings become transfer-ready Data here, at the
        -- LOVE-owned worker boundary; the shared cache format stays love-free.
        local indexData = love.data.newByteData(reuseEntry.index)
        local paletteData = nil
        if reuseEntry.kind == "r8" then
          paletteData = love.data.newByteData(reuseEntry.palette)
        end
        replyChannel:push({
          token = token,
          ok = true,
          kind = "image-derivative",
          path = path,
          sourceHash = sourceHash,
          pixelHash = reuseEntry.pixelHash,
          width = reuseEntry.width,
          height = reuseEntry.height,
          representation = reuseEntry.kind,
          colors = reuseEntry.colors,
          indexData = indexData,
          paletteData = paletteData,
        })
        return
      end
      -- Decoded image/file handles live only in this block; classification
      -- copies out the packed payloads before the handles are released.
      local classified
      do
        local fileData, fileError = love.filesystem.newFileData(pngBytes, "prepared.png")
        if fileData == nil then
          error("unreadable image source: " .. tostring(path) .. ": " .. tostring(fileError), 0)
        end
        local imageData, imageError = love.image.newImageData(fileData)
        if imageData == nil then
          error("unreadable image source: " .. tostring(path) .. ": " .. tostring(imageError), 0)
        end
        classified = ImageDerivative.classify(imageData)
      end
      local paletteBytes = ""
      if classified.paletteData ~= nil then
        paletteBytes = classified.paletteData:getString()
      end
      RuntimeImageCache.store(
        cache,
        derivativePath,
        RuntimeImageCache.encode({
          sourceHash = sourceHash,
          pixelHash = classified.pixelHash,
          width = classified.width,
          height = classified.height,
          kind = classified.kind,
          colors = classified.colors,
          index = classified.indexData:getString(),
          palette = paletteBytes,
        })
      )
      replyChannel:push({
        token = token,
        ok = true,
        kind = "image-derivative",
        path = path,
        sourceHash = sourceHash,
        pixelHash = classified.pixelHash,
        width = classified.width,
        height = classified.height,
        representation = classified.kind,
        colors = classified.colors,
        indexData = classified.indexData,
        paletteData = classified.paletteData,
      })
    end
    local ok, err = pcall(work)
    if not ok then
      fail(token, "image-derivative", path, err)
    end
  end

  local function prepareImage(token, path)
    local bytes, readError = love.filesystem.read(path)
    if bytes == nil then
      fail(token, "image", path, "unreadable cache file: " .. tostring(readError))
      return
    end
    local fileData, fileError = love.filesystem.newFileData(bytes, "prepared.png")
    if fileData == nil then
      fail(token, "image", path, fileError)
      return
    end
    local imageData, imageError = love.image.newImageData(fileData)
    if imageData == nil then
      fail(token, "image", path, imageError)
      return
    end
    replyChannel:push({ token = token, ok = true, kind = "image", path = path, imageData = imageData })
  end

  while true do
    local job = requestChannel:demand()
    if type(job) ~= "table" or job.op == "shutdown" then
      break
    end
    if job.op == "prepare" and job.kind == "mesh" then
      local ok, err = pcall(prepareMesh, job.token, job.versionId, job.logicalPath, job.path)
      if not ok then
        fail(job.token, job.kind, job.path, err)
      end
    elseif job.op == "prepare" and job.kind == "image" then
      local ok, err = pcall(prepareImage, job.token, job.path)
      if not ok then
        fail(job.token, job.kind, job.path, err)
      end
    elseif job.op == "prepare" and job.kind == "image-derivative" then
      local ok, err = pcall(prepareImageDerivative, job.token, job.versionId, job.logicalPath, job.path)
      if not ok then
        fail(job.token, job.kind, job.path, err)
      end
    else
      fail(job.token, job.kind, job.path, "unknown preparation request")
    end
  end
end

-- A directly started thread entry carries its channels as chunk arguments;
-- a plain require carries the module name instead and only exposes run.
local directRequest, directReply = ...
if type(directRequest) == "table" and type(directReply) == "table" then
  Worker.run(directRequest, directReply)
end

return Worker
