-- The one session-scoped owner of physical GPU images for generated PNGs:
-- every field, menu, mon, battle, and editor consumer borrows immutable
-- image and palette objects here instead of building textures privately.
-- Logical requests (generated PNG paths under immutable sampler state) fan
-- into worker-classified derivatives; the main thread realizes at most one
-- source and palette pair per poll, stages both GPU objects transactionally,
-- and drops its temporary payload references afterwards. Each poll stages
-- its own pair: a failed stage releases only its own new objects, reports
-- failure, and publishes nothing. Acquire publishes the staged pair under
-- the physical identity -- exact pixel content plus representation plus
-- sampler -- or adopts the live pair another request already published and
-- releases its staged duplicate, so identical pixels under matching sampler
-- state resolve to one image and palette while a different wrap or filter
-- pair never aliases. A shared idle kernel retains released pairs in
-- oldest-first order: a pair with a single logical owner rests resident
-- until the prune pass, while a pair shared by several owners is swept
-- with its last returned lease. Borrowed pairs stay alive either way.
-- The pool borrows the session preparation worker instead of starting its
-- own, so one presented session runs exactly one background worker. Only
-- use without a session queue (headless or test fixtures) builds a
-- pool-owned fallback worker through the thread option. Disposal cancels
-- pending interest, releases unstaged pairs, frees retained pairs exactly
-- once, and joins the worker only when the pool owns its fallback worker,
-- so late payloads never publish after their owner left.

local ffi = require("ffi")

local ResidentAssetCache = require("libs.hgss.src.field.ResidentAssetCache")
local AssetPreparationQueue = require("libs.hgss.src.presentation.AssetPreparationQueue")
local ImageSampling = require("libs.nds.src.love.ImageSampling")

-- First-pass idle budget for unborrowed physical pairs: 64 MiB of idle
-- images stay resident across prunes. Borrowed pairs are never evicted for
-- budget; overflow stays visible in stats until a later pass admits or
-- trims it. Target-device calibration is pending: this first-pass value is
-- not a measured device limit, and the release gate re-measures it on
-- hardware.
local DEFAULT_IDLE_IMAGE_BYTES = 64 * 1024 * 1024

---@class ImageAssetPoolSampler
---@field wrapX string horizontal wrap mode
---@field wrapY string vertical wrap mode
---@field minFilter string minification filter
---@field magFilter string magnification filter

---@class ImageAssetPoolGraphics
---@field newImage fun(data: unknown): ImageAssetPoolImage
---@field getImageFormats fun(): table<string, boolean>

---@class ImageAssetPoolImage: love.Image
---@field data love.ImageData?

---@class ImageAssetPoolOptions
---@field graphics ImageAssetPoolGraphics|love.graphics|nil injectable graphics namespace (nil keeps love.graphics)
---@field queue AssetPreparationQueue? borrowed session preparation worker (nil builds a pool-owned fallback worker; production always passes the live session queue)
---@field thread table<string, unknown>? injectable love.thread-shaped namespace for the pool-owned fallback worker only (nil keeps love.thread)
---@field idleByteLimit number? maximum unborrowed resident bytes retained across prunes (nil keeps the compiled first-pass budget)

---@class ImageAssetPoolRequest
---@field logicalPath string
---@field sampler ImageAssetPoolSampler
---@field priority "demand"|"prefetch"
---@field job integer preparation queue token
---@field state "queued"|"staged"|"ready"|"failed"|"cancelled"
---@field stagedImage ImageAssetPoolImage? unpublished pair staged by this request
---@field stagedPalette ImageAssetPoolImage? unpublished palette staged by this request
---@field stagedKind "r8"|"rgba8"? representation of the staged pair
---@field stagedWidth integer? decoded width of the staged pair
---@field stagedHeight integer? decoded height of the staged pair
---@field stagedWeight integer? resident byte weight of the staged pair
---@field physicalKey string?
---@field failure string?

---@class ImageAssetPoolPayload
---@field sourceHash string|love.ByteData
---@field pixelHash string|love.ByteData
---@field width integer
---@field height integer
---@field kind "r8"|"rgba8"
---@field colors integer palette slot count, zero for straight RGBA
---@field indexData love.ByteData packed first-seen slots, or straight RGBA bytes on fallback
---@field paletteData love.ByteData? concatenated RGBA tuples in first-seen order; nil on fallback

---@class ImageAssetPoolPhysical
---@field image ImageAssetPoolImage
---@field palette ImageAssetPoolImage?
---@field kind "r8"|"rgba8"
---@field width integer
---@field height integer
---@field physicalKey string
---@field bytes integer resident byte weight of the pair
---@field liveLeases integer outstanding borrows of the pair
---@field shared boolean true once several requests borrowed the pair

---@class ImageAssetPoolLease
---@field image ImageAssetPoolImage resolved source image
---@field palette ImageAssetPoolImage? resolved palette image, nil for straight RGBA
---@field kind "r8"|"rgba8" payload representation of the source image
---@field width integer decoded source width in pixels
---@field height integer decoded source height in pixels
---@field physicalKey string shared identity of the borrowed physical pair
---@field draw fun(self: ImageAssetPoolLease, graphics: love.graphics, x: number, y: number, ...: unknown) palette-exact sampler draw of the borrowed pair
---@field drawQuad fun(self: ImageAssetPoolLease, graphics: love.graphics, quad: love.Quad, x: number, y: number, ...: unknown) palette-exact sampler draw through a caller-owned viewport
---@field _cacheLease ResidentAssetCacheLease private borrow token for the physical entry
---@field _pool ImageAssetPool private owning pool for release routing
---@field _released boolean true once this lease returned its borrow

---@class ImageAssetPoolStats
---@field requests integer total logical requests recorded
---@field staged integer requests holding an unpublished staged pair
---@field ready integer requests resolved to a physical pair
---@field failed integer requests that failed or were cancelled
---@field physicalImages integer live physical pairs retained
---@field idleBytes integer unborrowed resident bytes
---@field pinnedBytes integer bytes held by outstanding leases

---@class ImageAssetPool
---@field _cacheFs CacheFs
---@field _graphics ImageAssetPoolGraphics
---@field _indexed boolean true while the device reports indexed texture support
---@field _queue AssetPreparationQueue borrowed session worker, or the pool-owned fallback worker when no session queue was passed
---@field _ownsQueue boolean true only when the pool built its fallback worker itself
---@field _images ResidentAssetCache
---@field _requests table<integer, ImageAssetPoolRequest>
---@field _nextToken integer
---@field _physicalCount integer
---@field _disposed boolean
local ImageAssetPool = {}
ImageAssetPool.__index = ImageAssetPool

-- The shared pool-lease draw surface: every pool lease draws itself through the
-- exact palette-or-RGBA rule, so retail layers that cannot import the
-- platform sampler (game, app) still render through it with zero new
-- imports. RGBA borrows draw pixel-identical to raw; indexed borrows bind
-- their exact palette. Sibling handle owners (mon icon pages) attach this
-- same metatable to their handle records instead of reimplementing draws.
local Lease = {}
Lease.__index = Lease

-- Draw the borrowed pair through the shared exact rule onto the current
-- canvas. Tint, canvas, blend, and caller shader state are preserved by
-- the sampler; extra placement arguments pass through to the draw call.
---@param graphics love.graphics host namespace the pair was realized in
---@param x number draw position x
---@param y number draw position y
---@param ... unknown optional extra placement arguments forwarded to the draw call
function Lease:draw(graphics, x, y, ...)
  assert(not self._released, "released image leases draw nothing")
  ImageSampling.draw(graphics, self, nil, x, y, ...)
end

-- Draw the borrowed pair through a caller-owned viewport (atlas cell,
-- sprite quad) under the shared exact rule. Same state contract as draw.
---@param graphics love.graphics host namespace the pair was realized in
---@param quad love.Quad source viewport, already transformed UVs owned by the caller
---@param x number draw position x
---@param y number draw position y
---@param ... unknown optional extra placement arguments forwarded to the draw call
function Lease:drawQuad(graphics, quad, x, y, ...)
  assert(not self._released, "released image leases draw nothing")
  ImageSampling.draw(graphics, self, quad, x, y, ...)
end

-- Expose the shared lease surface for sibling handle owners and test
-- doubles that stand in for pool borrows.
ImageAssetPool.Lease = Lease

-- Substitute the shared exact-sampling snippet into one custom shader
-- source for layers that cannot import the platform sampler themselves.
-- Sources without the marker pass through untouched.
---@param source string custom shader source carrying the sampler marker
---@return string shader source with the shared rule spliced in
function ImageAssetPool.withSharedSampling(source)
  return ImageSampling.withSharedSampling(source)
end

-- Validate one immutable sampler record: every channel is an explicit
-- string so two records compare by value in the physical key.
---@param sampler ImageAssetPoolSampler
local function checkSampler(sampler)
  assert(type(sampler) == "table", "image request sampler is required")
  assert(type(sampler.wrapX) == "string", "image request sampler wrapX is required")
  assert(type(sampler.wrapY) == "string", "image request sampler wrapY is required")
  assert(type(sampler.minFilter) == "string", "image request sampler minFilter is required")
  assert(type(sampler.magFilter) == "string", "image request sampler magFilter is required")
end

-- Normalize a worker hash (raw string or Data) to comparable bytes for
-- the physical key.
---@param hash string|love.ByteData
---@return string
local function hashToString(hash)
  if type(hash) == "string" then
    return hash
  end
  local data = hash --[[@as love.ByteData]]
  return data:getString()
end

-- Render raw identity bytes printable and safely comparable inside the
-- physical key.
---@param bytes string
---@return string
local function toHex(bytes)
  return (bytes:gsub(".", function(byte)
    return string.format("%02x", byte:byte())
  end))
end

-- The one physical identity: exact pixel content, dimensions,
-- representation, and the full immutable sampler state. Different pixels,
-- different representations, or different sampler states never alias.
---@param pixelHash string exact pixel identity bytes
---@param width integer decoded source width in pixels
---@param height integer decoded source height in pixels
---@param sampler ImageAssetPoolSampler
---@param kind "r8"|"rgba8"
---@return string
local function physicalKeyFor(pixelHash, width, height, sampler, kind)
  return table.concat({
    toHex(pixelHash),
    "|",
    tostring(width),
    "x",
    tostring(height),
    "|",
    kind,
    "|",
    sampler.wrapX,
    "|",
    sampler.wrapY,
    "|",
    sampler.minFilter,
    "|",
    sampler.magFilter,
  })
end

-- Release one evicted physical pair exactly once and forget its census
-- share. Borrowed pairs never reach here: the kernel only evicts idle
-- entries, so a throwing release still leaves coherent bookkeeping behind.
---@param pool ImageAssetPool
---@param entry ImageAssetPoolPhysical
local function releasePhysical(pool, entry)
  entry.image:release()
  if entry.palette ~= nil then
    entry.palette:release()
  end
  pool._physicalCount = pool._physicalCount - 1
end

-- Release a staged-but-unpublished GPU object while unwinding a failed
-- realization or an adopted duplicate. Staged objects are never published,
-- so this never touches live or previously retained pairs.
---@param object ImageAssetPoolImage
local function releaseStagedObject(object)
  object:release()
end

-- Keep a realized payload reference on host-held test doubles for exactness
-- assertions. Real GPU images are userdata and skip this; nothing reads the
-- reference on the draw path.
---@param image ImageAssetPoolImage
---@param payload love.ImageData
local function attachSourcePayload(image, payload)
  if type(image) == "table" then
    local shaped = image --[[@as table<string, love.ImageData>]]
    shaped.data = payload
  end
end

-- Stage one physical pair (source plus optional palette) in order,
-- recording each object as it is created so a later failure releases
-- exactly the objects this stage created. Palette sampling stays nearest
-- and clamped regardless of the source sampler state.
local function stagePhysicalObjects(staged, graphics, sourceData, paletteData, sampler)
  local image = graphics.newImage(sourceData)
  staged[#staged + 1] = image
  image:setFilter(sampler.minFilter, sampler.magFilter)
  image:setWrap(sampler.wrapX, sampler.wrapY)
  local palette = nil
  if paletteData ~= nil then
    palette = graphics.newImage(paletteData)
    staged[#staged + 1] = palette
    palette:setFilter("nearest", "nearest")
    palette:setWrap("clamp", "clamp")
  end
  return image, palette
end

-- Expand one indexed payload to straight RGBA bytes on a device without
-- indexed texture support. One bulk FFI pass over contiguous words; the
-- classification below already guarantees every slot lands in the palette.
---@param indexBytes string packed first-seen slots
---@param paletteBytes string concatenated RGBA tuples in first-seen order
---@param count integer pixel count
---@return string concatenated row-major RGBA bytes
local function expandIndexedPayload(indexBytes, paletteBytes, count)
  if ffi.abi("le") ~= true then
    error("indexed image fallback requires a little-endian host", 0)
  end
  local indexes = ffi.cast("const uint8_t *", indexBytes)
  local palette = ffi.cast("const uint32_t *", paletteBytes)
  local out = love.data.newByteData(count * 4)
  local pixels = ffi.cast("uint32_t *", out:getFFIPointer())
  for slot = 0, count - 1 do
    pixels[slot] = palette[indexes[slot]]
  end
  return out:getString()
end

---@class ImageAssetPoolStagedPixels
---@field pixelHash string exact pixel identity bytes for the physical key
---@field width integer decoded source width in pixels
---@field height integer decoded source height in pixels
---@field sourceData love.ImageData
---@field paletteData love.ImageData?
---@field kind "r8"|"rgba8"
---@field weight integer

-- Decode one transferred worker payload into staged pixel data without
-- consulting retained pairs: every poll builds its own source bytes, so a
-- failed upload belongs to exactly one request and a missing source fails
-- without touching live pairs.
---@param pool ImageAssetPool
---@param payload ImageAssetPoolPayload
---@return ImageAssetPoolStagedPixels
local function decodeTransferred(pool, payload)
  assert(type(payload) == "table", "image preparation answered without a payload")
  local record = payload --[[@as ImageAssetPoolPayload]]
  assert(
    type(record.width) == "number"
      and record.width % 1 == 0
      and record.width >= 1
      and type(record.height) == "number"
      and record.height % 1 == 0
      and record.height >= 1,
    "image preparation answered with invalid dimensions"
  )
  assert(record.kind == "r8" or record.kind == "rgba8", "image preparation answered with an unknown representation")
  local kind = record.kind
  if kind == "r8" and not pool._indexed then
    kind = "rgba8"
  end
  local count = record.width * record.height
  local sourceBytes
  local paletteBytes = nil
  local weight
  if kind == "r8" then
    assert(type(record.colors) == "number" and record.colors >= 1, "indexed image preparation needs a palette")
    local paletteData = assert(record.paletteData, "indexed image preparation needs palette bytes")
    local indexData = assert(record.indexData, "indexed image preparation needs index bytes")
    sourceBytes = indexData:getString()
    paletteBytes = paletteData:getString()
    assert(#sourceBytes == count, "indexed image payload length must match its dimensions")
    assert(#paletteBytes == record.colors * 4, "palette payload length must match its slot count")
    weight = count + record.colors * 4
  elseif record.kind == "r8" then
    local paletteData = assert(record.paletteData, "indexed image fallback needs palette bytes")
    local indexData = assert(record.indexData, "indexed image fallback needs index bytes")
    local indexString = indexData:getString()
    local paletteString = paletteData:getString()
    assert(#indexString == count, "indexed image payload length must match its dimensions")
    sourceBytes = expandIndexedPayload(indexString, paletteString, count)
    weight = count * 4
  else
    local indexData = assert(record.indexData, "straight image preparation needs pixel bytes")
    sourceBytes = indexData:getString()
    assert(#sourceBytes == count * 4, "straight image payload length must match its dimensions")
    weight = count * 4
  end
  local sourceData = love.image.newImageData(record.width, record.height, kind, sourceBytes)
  local paletteImageData = nil
  if paletteBytes ~= nil then
    paletteImageData = love.image.newImageData(record.colors, 1, "rgba8", paletteBytes)
  end
  return {
    pixelHash = hashToString(record.pixelHash),
    width = record.width,
    height = record.height,
    sourceData = sourceData,
    paletteData = paletteImageData,
    kind = kind,
    weight = weight,
  }
end

---@param cacheFs CacheFs
---@param opts ImageAssetPoolOptions?
---@return ImageAssetPool
function ImageAssetPool.new(cacheFs, opts)
  assert(
    cacheFs and cacheFs.read and cacheFs.resolve and type(cacheFs.versionId) == "string",
    "ImageAssetPool requires a versioned CacheFs"
  )
  opts = opts or {}
  local graphics = opts.graphics
  if graphics == nil then
    graphics = love and love.graphics
  end
  assert(graphics and graphics.newImage and graphics.getImageFormats, "ImageAssetPool requires love.graphics")
  ---@cast graphics ImageAssetPoolGraphics
  local formats = graphics.getImageFormats()
  local indexed = type(formats) == "table" and formats.r8 == true
  -- Production borrows the already-live session worker so the pool never
  -- starts a second thread beside it. The fallback below exists only for
  -- headless or test use where no session queue exists.
  local queue = opts.queue
  local ownsQueue = false
  if queue == nil then
    queue = AssetPreparationQueue.new(cacheFs, { thread = opts.thread })
    ownsQueue = true
  else
    assert(
      type(queue.request) == "function" and type(queue.poll) == "function" and type(queue.take) == "function",
      "ImageAssetPool requires its borrowed session queue to provide request, poll, and take"
    )
  end
  local pool
  local function onPhysicalRelease(entry)
    releasePhysical(pool, entry --[[@as ImageAssetPoolPhysical]])
  end
  pool = setmetatable({
    _cacheFs = cacheFs,
    _graphics = graphics,
    _indexed = indexed,
    _queue = queue,
    _ownsQueue = ownsQueue,
    -- Idle entries accumulate until the owner prunes: unborrowed pairs
    -- beyond the idle budget leave oldest-first while borrowed pairs stay
    -- alive. New requests refresh already-resident pairs below, so the
    -- prune pass prefers predicted reuse over the historical idle tail.
    _images = ResidentAssetCache.new({
      idleByteLimit = opts.idleByteLimit or DEFAULT_IDLE_IMAGE_BYTES,
      release = onPhysicalRelease,
    }),
    _requests = {},
    _nextToken = 0,
    _physicalCount = 0,
    _disposed = false,
  }, ImageAssetPool) --[[@as ImageAssetPool]]
  return pool
end

-- Refresh already-resident pairs matching a new request as semantic
-- reuse: predicted demand that reuses a resident pair moves it to
-- most-recently-used, so a later prune evicts the historical idle tail
-- first. Unknown or evicted identities are ignored; borrowed pairs need
-- no move. The scan is linear in recorded requests with no allocation;
-- requests are scene-lifetime interest, never per-frame or per-draw.
---@param pool ImageAssetPool
---@param logicalPath string
---@param sampler ImageAssetPoolSampler
local function touchResidentPair(pool, logicalPath, sampler)
  for _, prior in pairs(pool._requests) do
    if
      prior.physicalKey ~= nil
      and prior.logicalPath == logicalPath
      and prior.sampler.wrapX == sampler.wrapX
      and prior.sampler.wrapY == sampler.wrapY
      and prior.sampler.minFilter == sampler.minFilter
      and prior.sampler.magFilter == sampler.magFilter
    then
      pcall(function()
        pool._images:find(prior.physicalKey --[[@as string]])
      end)
    end
  end
end

-- Record logical interest in one generated PNG under one immutable sampler
-- state and enroll its classification work immediately. Returns an opaque
-- token; readiness is observed through poll, never assumed.
---@param logicalPath string generated PNG path in the selected cache
---@param sampler ImageAssetPoolSampler immutable sampler state for the physical key
---@param priority "demand"|"prefetch"? demand jumps ahead of prefetch work
---@return integer token for poll and acquire
function ImageAssetPool:request(logicalPath, sampler, priority)
  assert(not self._disposed, "image pool is disposed")
  assert(type(logicalPath) == "string", "image request path is required")
  checkSampler(sampler)
  local level = priority or "demand"
  assert(level == "demand" or level == "prefetch", "unknown preparation priority " .. tostring(priority))
  local job = self._queue:request("image-derivative", logicalPath, level)
  self._nextToken = self._nextToken + 1
  local token = self._nextToken
  self._requests[token] = {
    logicalPath = logicalPath,
    sampler = sampler,
    priority = level,
    job = job,
    state = "queued",
  }
  touchResidentPair(self, logicalPath, sampler)
  return token
end

-- Probe one request without blocking, staging at most one physical pair
-- per call. Returns "pending" while classification or the worker is in
-- flight, "ready" once this request staged its pair, or "failed" with the
-- cause when the source is missing or the upload stage failed. Staging
-- never consults retained pairs: the staged pair belongs to this request
-- until acquire publishes or adopts it.
---@param token integer
---@return string, string?
function ImageAssetPool:poll(token)
  local request = assert(self._requests[token], "unknown image request token")
  if request.state == "staged" or request.state == "ready" then
    return "ready"
  end
  if request.state == "failed" then
    return "failed", request.failure
  end
  if request.state == "cancelled" or self._disposed then
    error("image request was cancelled", 0)
  end
  local status, cause = self._queue:poll(request.job)
  if status == "pending" then
    return "pending"
  end
  if status == "failed" then
    request.state = "failed"
    request.failure = cause
    return "failed", cause
  end
  local payload = self._queue:take(request.job)
  local decodeOk, decoded = pcall(decodeTransferred, self, payload)
  if not decodeOk then
    request.state = "failed"
    request.failure = tostring(decoded)
    return "failed", tostring(decoded)
  end
  local staged = {} ---@type ImageAssetPoolImage[]
  local stageOk, image, palette =
    pcall(stagePhysicalObjects, staged, self._graphics, decoded.sourceData, decoded.paletteData, request.sampler)
  if not stageOk then
    for _, object in ipairs(staged) do
      pcall(releaseStagedObject, object)
    end
    request.state = "failed"
    request.failure = tostring(image)
    return "failed", tostring(image)
  end
  attachSourcePayload(image, decoded.sourceData)
  request.stagedImage = image
  request.stagedPalette = palette
  request.stagedKind = decoded.kind
  request.stagedWidth = decoded.width
  request.stagedHeight = decoded.height
  request.stagedWeight = decoded.weight
  request.physicalKey = physicalKeyFor(decoded.pixelHash, decoded.width, decoded.height, request.sampler, decoded.kind)
  request.state = "staged"
  return "ready"
end

-- Adopt the live pair for a staged request: borrow the retained entry and
-- release this request's staged duplicate exactly once.
---@param pool ImageAssetPool
---@param request ImageAssetPoolRequest
---@param physical ImageAssetPoolPhysical
---@return ImageAssetPoolLease
local function adoptLivePair(pool, request, physical)
  local stagedImage = assert(request.stagedImage, "staged image request has no staged pair")
  local borrowed = pool._images:borrow(physical.physicalKey)
  physical.liveLeases = physical.liveLeases + 1
  physical.shared = true
  pcall(releaseStagedObject, stagedImage)
  if request.stagedPalette ~= nil then
    pcall(releaseStagedObject, request.stagedPalette)
  end
  request.stagedImage = nil
  request.stagedPalette = nil
  request.physicalKey = physical.physicalKey
  request.state = "ready"
  return setmetatable({
    image = physical.image,
    palette = physical.palette,
    kind = physical.kind,
    width = physical.width,
    height = physical.height,
    physicalKey = physical.physicalKey,
    _cacheLease = borrowed,
    _pool = pool,
    _released = false,
  }, Lease)
end

-- Publish a staged request as the new live pair and borrow it for the
-- returned lease.
---@param pool ImageAssetPool
---@param request ImageAssetPoolRequest
---@param key string
---@return ImageAssetPoolLease
local function publishStagedPair(pool, request, key)
  local stagedImage = assert(request.stagedImage, "staged image request has no staged pair")
  local weight = assert(request.stagedWeight, "staged image request has no staged weight")
  local physical = {
    image = stagedImage,
    palette = request.stagedPalette,
    kind = assert(request.stagedKind, "staged image request has no staged representation"),
    width = assert(request.stagedWidth, "staged image request has no staged width"),
    height = assert(request.stagedHeight, "staged image request has no staged height"),
    physicalKey = key,
    bytes = weight,
    liveLeases = 1,
    shared = false,
  }
  pool._images:publish(key, physical, weight)
  pool._physicalCount = pool._physicalCount + 1
  local borrowed = pool._images:borrow(key)
  request.stagedImage = nil
  request.stagedPalette = nil
  request.physicalKey = key
  request.state = "ready"
  return setmetatable({
    image = physical.image,
    palette = physical.palette,
    kind = physical.kind,
    width = physical.width,
    height = physical.height,
    physicalKey = physical.physicalKey,
    _cacheLease = borrowed,
    _pool = pool,
    _released = false,
  }, Lease)
end

-- Borrow one staged request as an immutable lease record. The first
-- request for an identity publishes its staged pair; a later request for
-- the same identity adopts the live pair and releases its staged
-- duplicate, so compatible requests resolve one image and palette. The
-- lease holds the pair alive; release it when the logical owner lets go.
-- Acquiring before staging, after failure, or after cancellation fails
-- loudly instead of fabricating pixels.
---@param token integer
---@return ImageAssetPoolLease
function ImageAssetPool:acquire(token)
  local request = assert(self._requests[token], "unknown image request token")
  if request.state == "ready" then
    local key = assert(request.physicalKey, "ready image request has no physical identity")
    local found = assert(self._images:find(key), "physical image left the pool under its request")
    local physical = found --[[@as ImageAssetPoolPhysical]]
    local borrowed = self._images:borrow(key)
    physical.liveLeases = physical.liveLeases + 1
    if physical.liveLeases > 1 then
      physical.shared = true
    end
    return setmetatable({
      image = physical.image,
      palette = physical.palette,
      kind = physical.kind,
      width = physical.width,
      height = physical.height,
      physicalKey = physical.physicalKey,
      _cacheLease = borrowed,
      _pool = self,
      _released = false,
    }, Lease)
  end
  if request.state ~= "staged" then
    error("image request is not ready: " .. tostring(request.state), 0)
  end
  assert(request.stagedImage ~= nil, "staged image request has no staged pair")
  local key = assert(request.physicalKey, "staged image request has no physical identity")
  local found = self._images:find(key)
  if found ~= nil then
    return adoptLivePair(self, request, found --[[@as ImageAssetPoolPhysical]])
  end
  return publishStagedPair(self, request, key)
end

-- Drop logical interest in one request that never reached a lease.
-- Queued work cancels through the borrowed queue so its late payload is
-- discarded; staged-but-unacquired pairs release their staged objects.
-- Already-acquired requests keep their record: outstanding leases still
-- borrow through it for re-acquire, so cancellation reports false and
-- changes nothing. Unknown tokens report false. Total: never fails.
---@param token integer
---@return boolean true when interest was dropped
function ImageAssetPool:cancel(token)
  local request = self._requests[token]
  if request == nil then
    return false
  end
  if request.state == "ready" then
    return false
  end
  if request.stagedImage ~= nil then
    pcall(releaseStagedObject, request.stagedImage)
    request.stagedImage = nil
  end
  if request.stagedPalette ~= nil then
    pcall(releaseStagedObject, request.stagedPalette)
    request.stagedPalette = nil
  end
  pcall(function()
    self._queue:cancel(request.job)
  end)
  self._requests[token] = nil
  return true
end

-- Return one lease borrow. The first return releases the borrow and
-- reports true; repeating it reports false without side effects. A lease
-- from another pool fails loudly. Retiring the last borrow of a shared
-- pair sweeps it at once; a singly owned pair rests for the prune pass.
---@param lease ImageAssetPoolLease
---@return boolean
function ImageAssetPool:release(lease)
  assert(lease ~= nil and lease._pool == self, "image lease belongs to another pool")
  if lease._released then
    return false
  end
  lease._released = true
  local found = assert(self._images:find(lease.physicalKey), "physical image left the pool under its lease")
  local physical = found --[[@as ImageAssetPoolPhysical]]
  local firstReturn = self._images:returnLease(lease._cacheLease)
  physical.liveLeases = physical.liveLeases - 1
  if physical.liveLeases == 0 and physical.shared then
    self._images:trim()
  end
  return firstReturn
end

-- Trim unborrowed pairs oldest-first until the idle budget is met and
-- report the evicted count. Borrowed pairs stay resident regardless of
-- idle age; request-time reuse plus this oldest-first order prefers
-- predicted entries over the historical idle tail.
---@return integer
function ImageAssetPool:prune()
  local evicted, _ = self._images:trim()
  return evicted
end

-- Cancel every pending request, release unstaged pairs, and release
-- retained pairs exactly once, joining the worker only when the pool owns
-- its fallback worker. A borrowed session worker outlives its pool: the
-- session owner joins it after every borrower above is gone. Late worker
-- payloads publish nothing afterwards. Requires all leases returned first;
-- idempotent once disposed.
function ImageAssetPool:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  for _, request in pairs(self._requests) do
    if request.state == "queued" or request.state == "staged" then
      request.state = "cancelled"
      if request.stagedImage ~= nil then
        pcall(releaseStagedObject, request.stagedImage)
        request.stagedImage = nil
      end
      if request.stagedPalette ~= nil then
        pcall(releaseStagedObject, request.stagedPalette)
        request.stagedPalette = nil
      end
      -- A borrowed session queue outlives this pool: drop the worker
      -- interest so its late payload is discarded instead of retained
      -- unclaimed until the session owner joins the worker.
      pcall(function()
        self._queue:cancel(request.job)
      end)
    end
  end
  -- Only the pool-owned fallback worker is joined here; a borrowed
  -- session worker stays live for its owner.
  if self._ownsQueue then
    self._queue:release()
  end
  self._images:clear()
end

-- Current census: request states, live physical pairs, and resident bytes
-- split into idle and lease-held shares.
---@return ImageAssetPoolStats
function ImageAssetPool:stats()
  local resident = self._images:stats()
  local staged = 0
  local ready = 0
  local failed = 0
  for _, request in pairs(self._requests) do
    if request.state == "staged" then
      staged = staged + 1
    elseif request.state == "ready" then
      ready = ready + 1
    elseif request.state == "failed" or request.state == "cancelled" then
      failed = failed + 1
    end
  end
  return {
    requests = self._nextToken,
    staged = staged,
    ready = ready,
    failed = failed,
    physicalImages = self._physicalCount,
    idleBytes = resident.idleBytes,
    pinnedBytes = resident.pinnedBytes,
  }
end

return ImageAssetPool
