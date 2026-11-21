-- The one shared GPU-asset owner for scene loading: MapSceneLoader and
-- NeighborRing both need "read content-addressed cache bytes, decode/build a
-- persistent love Mesh, and borrow a GPU Image per unique sampler state",
-- so this pool is that shared responsibility. It dedups meshes by
-- content-addressed path and owns every Mesh it creates, while every
-- texture resolves to a lease borrowed from the session-scoped shared image
-- owner (two materials sharing pixels but sampling them differently never
-- alias one mutable sampler -- the shared owner keys physical images by
-- pixel content plus sampler, and the scene dedups its leases by path plus
-- wrap X/Y). The mesh entry caches the model-space bounding-box center and
-- AABB of each unique geometry path, computed once (pure SceneDescriptor
-- math) so no loader rescan of the decoded vertices happens per draw or
-- placement. Failure has two scopes: a construction wrapped in build()
-- releases everything the construction created (the loaders wrap their whole
-- scene build in one, on a pool created immediately before), while a single
-- acquire outside a build releases only the object that failed acquisition
-- itself created, never the resources a live scene is drawing. The pool knows
-- nothing about maps, neighbors, materials, or transforms; those stay in
-- the loaders. CPU-side, the pool borrows the selected session's preparation
-- queue and decoded owner: a geometry acquisition that needs worker decode
-- takes its own kernel lease, realizes the GPU object, and hands the lease back
-- at once, so no scene retains a decoded bank.

local ModelAsset = require("libs.assets.src.model.ModelAsset")
local SceneDescriptor = require("libs.hgss.src.presentation.SceneDescriptor")
local SynchronousWait = require("libs.hgss.src.presentation.SynchronousWait")
local VertexFormat = require("libs.assets.src.model.VertexFormat")
local ErrorCodes = require("libs.assets.src.ErrorCodes")
local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")

---@class GpuAssetPool.Mesh: love.Mesh
---@class GpuAssetPool.Image: love.Image
---@class GpuAssetPool.Graphics
---@field newImage fun(data: unknown): GpuAssetPool.Image
-- The sampling handle one texture borrow resolves to: exactly the material
-- shape ImageSampling.sendMaterialSampling consumes (bound image, exact
-- palette for indexed sources, and the indexed flag that selects the
-- palette path). One stable table per scene-local path/wrap identity, so
-- repeated acquisitions share it like the lease it describes.
---@class GpuAssetPool.SamplingHandle
---@field image GpuAssetPool.Image bound source image (index bytes or straight RGBA)
---@field palette GpuAssetPool.Image? exact RGBA palette, present only for indexed sources
---@field kind "r8"|"rgba8" source image representation used by exact 2D sampling
---@field indexed boolean true when the material must sample through the palette
---@class GpuAssetPool
---@field cacheFs table<string, unknown>
---@field graphics GpuAssetPool.Graphics|love.graphics
---@field meshes GpuAssetPool.Mesh[]
---@field triangles integer
---@field _imageAssets table<string, unknown>? session-scoped shared image owner every texture is borrowed from
---@field _imageLeases table<string, unknown>[] leases this scene borrowed from the shared owner, in acquisition order
---@field _pooledByKey table<string, GpuAssetPool.SamplingHandle> borrowed sampling handle by scene-local path/wrap identity
---@field _imageTokens table<string, integer> outstanding shared image request by scene-local path/wrap identity, from the request until its lease replaces it
---@field _queue table<string, unknown>? borrowed selected preparation queue
---@field _decoded table<string, unknown>? borrowed selected decoded CPU owner
local GpuAssetPool = {}
GpuAssetPool.__index = GpuAssetPool

-- LÖVE's real WrapMode vocabulary for sampled scene materials;
-- SceneDescriptor.MIRRORED_REPEAT is SceneDescriptor.wrap's resolved DS
-- mirrored-repeat mode (a repeated axis whose NSBTX material sets the flip
-- bit).
local WRAP_MODES = { clamp = true, ["repeat"] = true, [SceneDescriptor.MIRRORED_REPEAT] = true }

-- The pool keys its retained resources by the shared generated-asset identity
-- (one draw of a native model bank, one named texture/palette pair, or a plain
-- path), so repeated demand of the same selected asset reuses exactly one
-- resident object.
local assetKey = ModelAsset.assetIdentity

-- The one sampler validation for shared-owner texture acquisition: unknown
-- wrap modes on a sampled material are malformed data and raise instead of
-- degrading to clamp.
local function checkWrap(path, wrapX, wrapY)
  if not WRAP_MODES[wrapX] or not WRAP_MODES[wrapY] then
    Errors.raise(
      FieldErrors.GPU_ASSET_UNKNOWN_WRAP,
      "unknown texture wrap mode " .. tostring(wrapX) .. "/" .. tostring(wrapY),
      { path = path, wrapX = wrapX, wrapY = wrapY }
    )
  end
end

-- Release the last object of an owned list -- the failed acquisition's own.
-- The pop happens only when a guarded body recorded an object before
-- failing.
local function releaseLast(owned)
  local object = owned[#owned]
  owned[#owned] = nil
  object:release()
end

-- Run a mesh acquire under protection: any failure releases only the Mesh
-- the failed acquisition itself created -- never Meshes from earlier
-- acquisitions or a live scene. The guarded body records at most one Mesh
-- before any step that can fail, and the owned-list pop plus the release
-- happen here. A body that fails before recording anything owns nothing.
local function guarded(pool, fn)
  local meshesBefore = #pool.meshes
  local ok, err = pcall(fn)
  if not ok then
    if #pool.meshes > meshesBefore then
      releaseLast(pool.meshes)
    end
    error(err)
  end
end

---@class GpuAssetPoolOptions
---@field graphics? unknown -- injectable graphics namespace (nil keeps love.graphics)
---@field imageAssets? table<string, unknown> -- session-scoped shared GPU image owner; required for every texture acquisition, which borrows a lease instead of owning an Image
---@field assetPreparation? table<string, unknown> -- selected preparation queue, paired with decoded
---@field decoded? table<string, unknown> -- selected decoded CPU owner, paired with assetPreparation

-- The CPU owners a scene's geometry preparation borrows. An explicit pair wins
-- and must agree with the image owner's own capability; otherwise the session
-- image owner's required preparation accessor supplies it, so a cutscene or
-- actor constructor that already holds the image owner needs no new argument. A
-- pool that supplies only one of the pair is a programming error, and a pool
-- with neither source is a programming error too: there is no private owner
-- fallback.
---@param opts GpuAssetPoolOptions
---@return table<string, unknown> queue
---@return table<string, unknown> decoded
local function resolvePreparation(opts)
  local queue = opts.assetPreparation
  local decoded = opts.decoded
  assert((queue == nil) == (decoded == nil), "GpuAssetPool needs the preparation queue and the decoded owner together")
  local images = opts.imageAssets
  local fromImageOwner = nil
  if images ~= nil then
    assert(
      type(images.preparation) == "function",
      "GpuAssetPool requires the session image owner's CPU preparation accessor"
    )
    fromImageOwner = images:preparation()
    assert(
      type(fromImageOwner) == "table" and fromImageOwner.queue ~= nil and fromImageOwner.decoded ~= nil,
      "the session image owner exposes no CPU preparation"
    )
  end
  if queue ~= nil then
    if fromImageOwner ~= nil then
      assert(
        fromImageOwner.queue == queue and fromImageOwner.decoded == decoded,
        "explicit CPU owners must be the session image owner's own preparation"
      )
    end
    ---@cast decoded -nil
    return queue, decoded
  end
  assert(
    fromImageOwner ~= nil,
    "GpuAssetPool requires the selected CPU preparation or a session image owner that exposes one"
  )
  return fromImageOwner.queue, fromImageOwner.decoded
end

-- cacheFs: a CacheFs-shaped reader (read(path) returns raw bytes or nil); see
-- GpuAssetPoolOptions for the injectable mesh seam. Textures are never owned
-- here: every image acquisition borrows a lease from the session-scoped
-- shared image owner.
---@param cacheFs table<string, unknown>
---@param opts GpuAssetPoolOptions?
---@return GpuAssetPool
function GpuAssetPool.new(cacheFs, opts)
  assert(cacheFs and cacheFs.read, "GpuAssetPool requires a CacheFs-shaped object")
  opts = opts or {}
  ---@type GpuAssetPool.Graphics|love.graphics|nil
  local graphics = opts.graphics
  if graphics == nil then
    graphics = love and love.graphics
  end
  assert(graphics and graphics.newImage, "GpuAssetPool requires love.graphics")
  ---@cast graphics GpuAssetPool.Graphics|love.graphics
  local queue, decoded = resolvePreparation(opts)
  return setmetatable({
    cacheFs = cacheFs,
    graphics = graphics,
    meshes = {},
    triangles = 0,
    _meshCache = {},
    -- The session-scoped shared image owner every texture is borrowed from.
    -- Texture acquisition without it is a programming error and fails
    -- loudly; meshes are unaffected and stay scene-owned.
    _imageAssets = opts.imageAssets,
    _imageLeases = {},
    _pooledByKey = {},
    _imageTokens = {},
    _queue = queue,
    _decoded = decoded,
  }, GpuAssetPool)
end

-- One selected draw out of a decoded native bank payload. The payload is
-- shared by every consumer of the same identity, so a draw is picked, never
-- consumed: the rest of the bank stays intact for its own readers.
---@param payload table<string, unknown>
---@param reference ModelAsset.GeometryReference
---@return SceneMesh.PreparedMesh
local function nativeDraw(payload, reference)
  local draws = payload.draws
  local drawIndex = assert(reference.drawIndex)
  local prepared = type(draws) == "table" and draws[drawIndex + 1] or nil
  if prepared == nil then
    Errors.raise("SCENE_MESH_NATIVE_DRAW_MISSING", "native model bank has no draw " .. tostring(drawIndex), {
      file = ModelAsset.geometryFile(reference),
      drawIndex = drawIndex,
    })
  end
  ---@cast prepared SceneMesh.PreparedMesh
  return prepared
end

-- The decoded payload one awaited preparation value carries, optionally
-- narrowed to a native bank draw.
---@param lease table<string, unknown>
---@param reference string|ModelAsset.GeometryReference
---@return SceneMesh.PreparedMesh
local function preparedPayload(lease, reference)
  local value = lease.value
  local payload = value and value.payload
  assert(type(payload) == "table", "the awaited preparation lease carries no decoded payload")
  if type(reference) == "table" then
    return nativeDraw(payload, reference)
  end
  ---@cast payload SceneMesh.PreparedMesh
  return payload
end

-- Acquire (or fetch) the shared Mesh for a content-addressed geometry path.
-- Returns { mesh, triangles, center, bounds }: the model-space bounding-box
-- center and AABB are computed once per path (pure SceneDescriptor math over
-- the decoded vertices, which are otherwise discarded) and shared by every
-- consumer -- draw sort centers, descriptor bounds folds -- so no loader
-- rescan happens per draw/placement. The triangle count feeds loader stats
-- exactly once per mesh. All four fields are stable references across
-- repeated acquires of the same path.
---@param reference string|ModelAsset.GeometryReference procedural mesh path or a native model-bank selector
---@return { mesh: GpuAssetPool.Mesh, triangles: integer, center: number[], bounds: { minX: number, maxX: number, minY: number, maxY: number, minZ: number, maxZ: number } }
function GpuAssetPool:meshFor(reference)
  local key = assetKey(reference)
  local entry = self._meshCache[key]
  if entry ~= nil then
    return entry
  end
  -- Every geometry source is a worker transaction on the selected queue: a
  -- procedural batch requests its packed upload, a native bank requests the
  -- whole bank, and the pool realizes the one payload it needs, then returns
  -- the decoded lease at once so no scene retains decoded bytes after upload.
  local queue = assert(self._queue, "geometry acquisition requires the selected preparation queue")
  local kind = "mesh"
  local source = reference
  if type(reference) == "table" then
    kind = "g4gx"
    source = ModelAsset.geometryFile(reference)
  end
  local lease = queue:wait(queue:request(kind, source, "demand"))
  local ok, realized = pcall(function()
    return self:meshFromPrepared(reference, preparedPayload(lease, reference))
  end)
  self:_returnPrepared(lease)
  if not ok then
    error(realized, 0)
  end
  return realized --[[@as table]]
end

-- Return one borrowed decoded lease after its GPU objects exist. A pool that
-- owns no decoded owner never borrowed one.
---@param lease table<string, unknown>?
function GpuAssetPool:_returnPrepared(lease)
  if lease == nil then
    return
  end
  local decoded = assert(self._decoded, "a prepared lease needs the selected decoded owner")
  decoded:returnLease(lease)
  decoded:trim()
end

-- Acquire one geometry reference through the preparation queue: CPU decoding
-- and upload packing already happened on the worker, so only the LÖVE Mesh is
-- realized here. `await(kind, path)` ("mesh" for a procedural batch, "g4gx"
-- for a whole native bank) is the staged caller's cooperative wait and yields
-- the kernel lease it took; the pool reads that lease's shared value and leaves
-- the lease with the caller, who returns it once the build realizes the draw. A
-- shared bank payload is never consumed: realizing one draw keeps every other
-- draw intact for its own consumer.
---@param reference string|ModelAsset.GeometryReference
---@param await fun(kind: string, path: string): table<string, unknown>
---@return { mesh: GpuAssetPool.Mesh, triangles: integer, center: number[], bounds: { minX: number, maxX: number, minY: number, maxY: number, minZ: number, maxZ: number } }
function GpuAssetPool:preparedMesh(reference, await)
  assert(type(await) == "function", "prepared mesh acquisition requires a preparation await")
  local key = assetKey(reference)
  local entry = self._meshCache[key]
  if entry ~= nil then
    return entry
  end
  if type(reference) == "table" then
    local lease = await("g4gx", ModelAsset.geometryFile(reference))
    return self:meshFromPrepared(reference, preparedPayload(lease, reference))
  end
  ---@cast reference string
  local lease = await("mesh", reference)
  return self:meshFromPrepared(reference, preparedPayload(lease, reference))
end

-- The immutable sampler state a shared-owner texture request carries. The
-- filter stays nearest/nearest, matching the sampler contract every scene
-- material renders through.
---@param wrapX string
---@param wrapY string
---@return table<string, string>
local function sharedSampler(wrapX, wrapY)
  return { wrapX = wrapX, wrapY = wrapY, minFilter = "nearest", magFilter = "nearest" }
end

-- The scene-local identity of one borrowed texture: the shared owner keys
-- physical images by pixel content plus sampler, while the scene only
-- needs per path/wrap dedup so repeated acquisitions within one scene
-- share a single lease.
---@param path string|ModelAsset.GeometryReference|ModelAsset.TextureReference
---@param wrapX string
---@param wrapY string
---@return string
local function pooledKey(path, wrapX, wrapY)
  return wrapX .. "|" .. wrapY .. "|" .. assetKey(path)
end

-- Enroll one texture in the shared owner ahead of its first acquisition so
-- classification starts before the staged build reaches the material. A nil
-- path (untextured material) enrolls nothing. Enrollment without a session
-- image owner is a programming error and fails loudly, matching the
-- acquisition contract. Unknown wrap modes raise here instead of degrading
-- to clamp, matching the acquisition contract.
---@param path string|ModelAsset.TextureReference?
---@param wrapX string
---@param wrapY string
function GpuAssetPool:prefetchShared(path, wrapX, wrapY)
  if path == nil then
    return
  end
  local images = assert(self._imageAssets, "GpuAssetPool requires a session image owner for textures")
  checkWrap(assetKey(path), wrapX, wrapY)
  local key = pooledKey(path, wrapX, wrapY)
  if self._pooledByKey[key] == nil and self._imageTokens[key] == nil then
    self._imageTokens[key] = images:request(path, sharedSampler(wrapX, wrapY), "prefetch")
  end
end

-- Borrow one texture from the shared owner, blocking cooperatively while
-- its classification is still in flight. `wait` is invoked once per
-- pending poll so staged scene builds yield their checkpoint (nil waits by
-- sleeping, for synchronous callers with no checkpoint to yield). Returns
-- the stable sampling handle for the scene-local path/wrap identity: the
-- bound image plus the exact palette and indexed flag the renderer's
-- shared sampler consumes.
--
-- Every outstanding ticket -- prefetched or demand-created -- is tracked
-- until the lease replaces it, so releasing the scene always drops the
-- requests it started, including one still pending at the worker.
-- Borrowing without a session image owner is a programming error and fails
-- loudly. Unknown wrap modes raise; a missing texture fails without
-- publishing. A failure here borrows nothing -- the shared owner keeps
-- every live pair it already published.
---@param path string|ModelAsset.TextureReference?
---@param wrapX string
---@param wrapY string
---@param wait (fun())? invoked while the shared request is still pending
---@return GpuAssetPool.SamplingHandle?
function GpuAssetPool:sharedImage(path, wrapX, wrapY, wait)
  if path == nil then
    return nil
  end
  local images = assert(self._imageAssets, "GpuAssetPool requires a session image owner for textures")
  checkWrap(assetKey(path), wrapX, wrapY)
  local key = pooledKey(path, wrapX, wrapY)
  local held = self._pooledByKey[key]
  if held ~= nil then
    return held
  end
  local token = self._imageTokens[key]
  if token == nil then
    token = images:request(path, sharedSampler(wrapX, wrapY), "demand")
    self._imageTokens[key] = token
  end
  -- The ticket stays owned here until a lease exists: a failed poll or a
  -- failed acquisition drops it through the shared owner, so a rolled-back
  -- scene never leaves an unreachable request charged to the session.
  local function acquireLease()
    local status, failure = images:poll(token)
    while status == "pending" do
      if wait ~= nil then
        wait()
      else
        SynchronousWait.block()
      end
      status, failure = images:poll(token)
    end
    if status ~= "ready" then
      error("shared image " .. assetKey(path) .. " is not ready: " .. tostring(failure), 0)
    end
    return images:acquire(token)
  end
  local acquired, leaseOrFailure = pcall(acquireLease)
  self._imageTokens[key] = nil
  if not acquired then
    pcall(images.cancel, images, token)
    error(leaseOrFailure, 0)
  end
  local lease = leaseOrFailure
  -- The sampling handle mirrors the borrowed lease: the scene holds leases
  -- (returned on release) while materials carry the handle's sampling
  -- fields. The handle is stable per path/wrap identity, so repeated
  -- acquisitions of one texture share it.
  ---@type GpuAssetPool.SamplingHandle
  local handle = { image = lease.image, palette = lease.palette, kind = lease.kind, indexed = lease.kind == "r8" }
  self._pooledByKey[key] = handle
  self._imageLeases[#self._imageLeases + 1] = lease
  return handle
end

-- The already-borrowed sampling handle for one texture identity, or a loud
-- failure when the scene never borrowed it. Live render callbacks resolve
-- their materials through this instead of sharedImage: a scene tick binds only
-- textures its construction already holds, so no field frame can wait on
-- worker classification or publish a freshly decoded image.
---@param path string|ModelAsset.TextureReference?
---@param wrapX string
---@param wrapY string
---@return GpuAssetPool.SamplingHandle?
function GpuAssetPool:heldImage(path, wrapX, wrapY)
  if path == nil then
    return nil
  end
  checkWrap(assetKey(path), wrapX, wrapY)
  local handle = self._pooledByKey[pooledKey(path, wrapX, wrapY)]
  if handle == nil then
    Errors.raise(
      FieldErrors.GPU_ASSET_TEXTURE_NOT_HELD,
      "texture "
        .. assetKey(path)
        .. " was never borrowed by this scene ("
        .. tostring(wrapX)
        .. "/"
        .. tostring(wrapY)
        .. "); live lookups never start worker work",
      { path = assetKey(path), wrapX = wrapX, wrapY = wrapY }
    )
  end
  return handle
end

-- Acquire the bound Image for a texture path under one immutable sampler
-- state (wrap X/Y). Every texture is borrowed from the session-scoped
-- shared image owner: the scene holds the lease while the shared owner owns
-- the GPU object, so identical textures across scenes resolve to one
-- physical image. This returns only the bound image; callers that render
-- indexed sources need the full sampling handle (image + palette + indexed)
-- from sharedImage. Unknown wrap modes on a sampled material are malformed
-- data and raise instead of degrading to clamp; a nil path (untextured
-- material, no sampler state) yields no image. Acquisition without a
-- session image owner is a programming error and fails loudly.
---@param path string|ModelAsset.TextureReference?
---@param wrapX string
---@param wrapY string
---@return GpuAssetPool.Image?
function GpuAssetPool:imageFor(path, wrapX, wrapY)
  if not path then
    return nil
  end
  local handle = self:sharedImage(path, wrapX, wrapY)
  return handle and handle.image or nil
end

-- Realize a worker-prepared mesh payload on the main thread. Shares the
-- content-addressed dedup key, the cached center/AABB shape, the triangle
-- stat, and the transactional rollback with meshFor: an already-realized
-- path returns its entry without uploading a duplicate, and a failure
-- between Mesh creation and publication releases the partial object and
-- leaves the cache tables/counters unchanged.
---@param path string|ModelAsset.GeometryReference procedural mesh path or a native model-bank selector
---@param prepared SceneMesh.PreparedMesh
---@return { mesh: GpuAssetPool.Mesh, triangles: integer, center: number[], bounds: { minX: number, maxX: number, minY: number, maxY: number, minZ: number, maxZ: number } }
function GpuAssetPool:meshFromPrepared(path, prepared)
  local key = assetKey(path)
  local entry = self._meshCache[key]
  if not entry then
    guarded(self, function()
      assert(
        type(prepared) == "table" and prepared.vertexData and prepared.indexData,
        "prepared mesh payload is required"
      )
      assert(
        prepared.indexType == "uint16" or prepared.indexType == "uint32",
        "prepared mesh index type must be uint16 or uint32"
      )
      local mesh = self.graphics.newMesh(VertexFormat.LAYOUT, prepared.vertexCount, "triangles", "static")
      ---@cast mesh GpuAssetPool.Mesh
      -- Record ownership before the failure-capable upload steps, exactly
      -- like the synchronous path, so a later failure pops and releases
      -- exactly this mesh instead of orphaning it.
      self.meshes[#self.meshes + 1] = mesh
      if prepared.vertexCount == 0 then
        Errors.raise(ErrorCodes.SCENE_DESC_EMPTY_MESH, "a mesh must have at least one vertex", { path = key })
      end
      mesh:setVertices(prepared.vertexData)
      mesh:setVertexMap(prepared.indexData, prepared.indexType)
      local triangleCount = prepared.indexCount / 3
      ---@cast triangleCount integer
      entry = {
        mesh = mesh,
        triangles = triangleCount,
        center = { prepared.centerX, prepared.centerY, prepared.centerZ },
        bounds = {
          minX = prepared.minX,
          maxX = prepared.maxX,
          minY = prepared.minY,
          maxY = prepared.maxY,
          minZ = prepared.minZ,
          maxZ = prepared.maxZ,
        },
      }
      self._meshCache[key] = entry
      self.triangles = self.triangles + entry.triangles
    end)
  end
  return entry
end

-- Borrow a worker-prepared texture payload's sampling handle from the shared
-- owner on the main thread. The staged payload is superseded: the shared
-- owner classifies the same effective texture through its own worker, so this
-- delegates to the same borrow as imageFor and never builds a second Image.
-- A nil path (untextured material) yields no handle.
---@param path string|ModelAsset.TextureReference?
---@param wrapX string
---@param wrapY string
---@param prepared table<string, unknown> superseded staged payload; the shared owner classifies through its own worker
---@return GpuAssetPool.Image?
function GpuAssetPool:imageFromPrepared(path, wrapX, wrapY, prepared)
  if not path then
    return nil
  end
  -- A scene borrowing the shared owner never builds a second prepared
  -- ImageData path: the shared owner classifies the same effective
  -- texture through its own worker, so the staged payload is superseded.
  assert(type(prepared) == "table", "prepared image payload is required")
  local handle = self:sharedImage(path, wrapX, wrapY)
  return handle and handle.image or nil
end

-- The number of textures this scene holds: its borrowed shared leases.
---@return integer
function GpuAssetPool:textureCount()
  return #self._imageLeases
end

-- Release every owned GPU object exactly once and return every borrowed
-- lease to the shared owner. Outstanding image tickets cancel through the
-- shared owner so their worker payloads are discarded instead of retained
-- unclaimed. Idempotent: the owned mesh list, the lease list,
-- and the triangle count are cleared, so a repeat release (or a cleanup
-- after a failed acquire) never touches the same object twice. Pools
-- behind other scenes keep their own leases and meshes; a release here
-- never evicts a committed scene's resources.
function GpuAssetPool:release()
  for _, mesh in ipairs(self.meshes) do
    mesh:release()
  end
  -- Texture work borrows the session image owner; mesh-only pools without
  -- one skip both loops exactly as before, keeping headless construction
  -- release-safe.
  local images = self._imageAssets
  if images ~= nil then
    for _, lease in ipairs(self._imageLeases) do
      images:release(lease)
    end
    for _, token in pairs(self._imageTokens) do
      images:cancel(token)
    end
  else
    assert(#self._imageLeases == 0, "GpuAssetPool requires a session image owner for textures")
  end
  self._imageLeases, self._pooledByKey, self._imageTokens = {}, {}, {}
  self.meshes = {}
  self._meshCache = {}
  self.triangles = 0
end

-- Run the scene construction against this (freshly created) pool: the
-- loaders create the pool and immediately wrap their whole build in build().
-- On failure everything the construction acquired is released (dedup caches
-- included) and the failure re-raises; on success everything stays owned and
-- fn's value is returned. The wrapper is exactly "construct a fresh scene
-- pool, release on failed construction" -- nothing more: it is not a generic
-- transaction API, and callers must not reuse a pool that already owns
-- objects (a failed inner construction would release them).
---@param fn fun(): unknown?
---@return unknown
function GpuAssetPool:build(fn)
  assert(type(fn) == "function", "GpuAssetPool:build requires a function")
  local ok, result = pcall(fn)
  if not ok then
    self:release()
    error(result)
  end
  return result
end

return GpuAssetPool
