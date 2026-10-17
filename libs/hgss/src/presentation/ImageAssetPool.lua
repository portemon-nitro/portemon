-- The one session-scoped owner of physical GPU images for generated PNGs:
-- every field, menu, mon, battle, and editor consumer borrows immutable
-- image and palette objects here instead of building textures privately.
-- Logical requests (generated PNG paths under immutable sampler state) first
-- resolve against still-resident pairs without worker or GPU work; a miss
-- fans into worker-classified derivatives whose pixel identity is resolved
-- before any GPU staging. Readiness never creates GPU objects: the consuming
-- acquire borrows the live pair or realizes and publishes exactly one source
-- and palette pair, then retires its ticket. Tickets are single-use interest,
-- never lifetime: a successful acquire consumes its token and a later lease
-- needs a fresh request, which is an immediate hit while the pair stays
-- resident. A shared idle kernel retains released pairs in oldest-first
-- order: a pair with a single logical owner rests resident until the prune
-- pass, while a pair shared by several owners is swept with its last
-- returned lease. Borrowed pairs stay alive either way.
-- The pool borrows the session preparation worker instead of starting its
-- own, so one presented session runs exactly one background worker. Only
-- use without a session queue (headless or test fixtures) builds a
-- pool-owned fallback worker through the thread option. Disposal cancels
-- pending interest, drops unclaimed payloads, frees retained pairs exactly
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
---@field logicalKey string private resident lookup identity for the path plus sampler
---@field logicalPath string
---@field sampler ImageAssetPoolSampler
---@field priority "demand"|"prefetch"
---@field job integer? preparation queue token while the request is still queued
---@field state "queued"|"prepared"|"cached"|"failed"
---@field payload ImageAssetPoolPayload? unuploaded worker result held only by a prepared ticket
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
---@field staged integer unconsumed prepared CPU payloads
---@field ready integer live cached tickets ready to borrow
---@field failed integer live failed tickets awaiting cancellation
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
---@field _residentByLogical table<string, string> private logical identity to live physical identity
---@field _logicalByPhysical table<string, table<string, boolean>> private live physical identity to logical identities
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
-- the physical key. Hashes are small fixed digests, never image buffers.
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

-- The private logical identity: the generated path plus the full immutable
-- sampler state. The length prefix keeps a path containing a separator from
-- colliding with a longer path plus sampler suffix; sampler channels are
-- fixed enum strings that never embed a NUL byte.
---@param logicalPath string
---@param sampler ImageAssetPoolSampler
---@return string
local function logicalKeyFor(logicalPath, sampler)
  return table.concat({
    tostring(#logicalPath),
    ":",
    logicalPath,
    "\0",
    sampler.wrapX,
    "\0",
    sampler.wrapY,
    "\0",
    sampler.minFilter,
    "\0",
    sampler.magFilter,
  })
end

-- Release one evicted physical pair exactly once, forget its census share,
-- and invalidate every logical alias that pointed at it. Borrowed pairs
-- never reach here: the kernel only evicts idle entries, so a throwing
-- release still leaves coherent bookkeeping behind.
---@param pool ImageAssetPool
---@param entry ImageAssetPoolPhysical
local function releasePhysical(pool, entry)
  local key = entry.physicalKey
  local aliases = pool._logicalByPhysical[key]
  if aliases ~= nil then
    for logicalKey in pairs(aliases) do
      if pool._residentByLogical[logicalKey] == key then
        pool._residentByLogical[logicalKey] = nil
      end
    end
    pool._logicalByPhysical[key] = nil
  end
  entry.image:release()
  if entry.palette ~= nil then
    entry.palette:release()
  end
  pool._physicalCount = pool._physicalCount - 1
end

-- Remember one successful logical resolution: the alias may be reused while
-- its physical entry stays resident and is forgotten on eviction above.
---@param pool ImageAssetPool
---@param logicalKey string
---@param physicalKey string
local function registerAlias(pool, logicalKey, physicalKey)
  pool._residentByLogical[logicalKey] = physicalKey
  local reverse = pool._logicalByPhysical[physicalKey]
  if reverse == nil then
    reverse = {}
    pool._logicalByPhysical[physicalKey] = reverse
  end
  reverse[logicalKey] = true
end

-- Forget one logical mapping whose physical entry proved absent, keeping the
-- reverse membership coherent for the remaining aliases.
---@param pool ImageAssetPool
---@param logicalKey string
---@param physicalKey string
local function dropStaleAlias(pool, logicalKey, physicalKey)
  if pool._residentByLogical[logicalKey] == physicalKey then
    pool._residentByLogical[logicalKey] = nil
  end
  local reverse = pool._logicalByPhysical[physicalKey]
  if reverse ~= nil then
    reverse[logicalKey] = nil
    if next(reverse) == nil then
      pool._logicalByPhysical[physicalKey] = nil
    end
  end
end

-- Release a staged-but-unpublished GPU object while unwinding a failed
-- realization. Staged objects are never published, so this never touches
-- live or previously retained pairs.
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

-- Byte size of one transferred worker buffer without copying its bytes:
-- Data reports its size directly while plain strings measure by length.
---@param data love.ByteData|string
---@return integer
local function dataByteSize(data)
  if type(data) == "string" then
    return #data
  end
  local sized = data --[[@as love.ByteData]]
  local ok, size = pcall(function()
    return sized:getSize()
  end)
  if ok and type(size) == "number" and size >= 0 then
    return math.floor(size)
  end
  error("image preparation payload has unreadable data", 0)
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

-- Expand Data-held indexed buffers to a straight RGBA Data without a
-- whole-image Lua string: both inputs stay owned by their locals until the
-- bulk FFI copy completes, then the fresh output Data travels to ImageData.
---@param indexData love.ByteData packed first-seen slots
---@param paletteData love.ByteData concatenated RGBA tuples in first-seen order
---@param count integer pixel count
---@return love.ByteData concatenated row-major RGBA bytes
local function expandIndexedData(indexData, paletteData, count)
  if ffi.abi("le") ~= true then
    error("indexed image fallback requires a little-endian host", 0)
  end
  local indexes = ffi.cast("const uint8_t *", indexData:getFFIPointer())
  local palette = ffi.cast("const uint32_t *", paletteData:getFFIPointer())
  local out = love.data.newByteData(count * 4)
  local pixels = ffi.cast("uint32_t *", out:getFFIPointer())
  for slot = 0, count - 1 do
    pixels[slot] = palette[indexes[slot]]
  end
  return out
end

---@class ImageAssetPoolRealizedPixels
---@field pixelHash string exact pixel identity bytes for the physical key
---@field width integer decoded source width in pixels
---@field height integer decoded source height in pixels
---@field sourceData love.ImageData
---@field paletteData love.ImageData?
---@field kind "r8"|"rgba8" effective representation after the device fallback
---@field weight integer resident byte weight of the pair

-- The effective representation for one classified payload on this device:
-- indexed payloads collapse to straight RGBA where the format probe says
-- the device cannot sample them, otherwise the classified kind stands.
---@param pool ImageAssetPool
---@param kind "r8"|"rgba8"
---@return "r8"|"rgba8"
local function effectiveKindFor(pool, kind)
  if kind == "r8" and not pool._indexed then
    return "rgba8"
  end
  return kind
end

-- Compute the physical identity for one worker payload under one sampler
-- without decoding pixels or creating GPU objects: validates the small
-- classification metadata and normalizes the representation first so the
-- fallback and native paths key identically for the device.
---@param pool ImageAssetPool
---@param payload ImageAssetPoolPayload
---@param sampler ImageAssetPoolSampler
---@return string physicalKey
---@return "r8"|"rgba8" effectiveKind
local function keyForPayload(pool, payload, sampler)
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
  assert(record.pixelHash ~= nil, "image preparation answered without a pixel identity")
  local kind = effectiveKindFor(pool, record.kind)
  if kind == "r8" then
    assert(type(record.colors) == "number" and record.colors >= 1, "indexed image preparation needs a palette")
    assert(record.paletteData ~= nil, "indexed image preparation needs palette bytes")
    assert(record.indexData ~= nil, "indexed image preparation needs index bytes")
  elseif record.kind == "r8" then
    assert(record.paletteData ~= nil, "indexed image fallback needs palette bytes")
    assert(record.indexData ~= nil, "indexed image fallback needs index bytes")
  else
    assert(record.indexData ~= nil, "straight image preparation needs pixel bytes")
  end
  return physicalKeyFor(hashToString(record.pixelHash), record.width, record.height, sampler, kind), kind
end

-- Realize one transferred worker payload into staged pixel data on the
-- consuming acquire, passing the transferred Data straight to ImageData so
-- the common path copies no whole-image Lua string. The caller keeps the
-- payload Data alive across the FFI fallback copy; size checks run before
-- every native construction.
---@param pool ImageAssetPool
---@param payload ImageAssetPoolPayload
---@return ImageAssetPoolRealizedPixels
local function realizePayload(pool, payload)
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
  local kind = effectiveKindFor(pool, record.kind)
  local count = record.width * record.height
  if kind == "r8" then
    assert(type(record.colors) == "number" and record.colors >= 1, "indexed image preparation needs a palette")
    local paletteData = assert(record.paletteData, "indexed image preparation needs palette bytes")
    local indexData = assert(record.indexData, "indexed image preparation needs index bytes")
    assert(dataByteSize(indexData) == count, "indexed image payload length must match its dimensions")
    assert(dataByteSize(paletteData) == record.colors * 4, "palette payload length must match its slot count")
    local sourceData = love.image.newImageData(record.width, record.height, kind, indexData --[[@as string]])
    local paletteImageData = love.image.newImageData(record.colors, 1, "rgba8", paletteData --[[@as string]])
    return {
      pixelHash = hashToString(record.pixelHash),
      width = record.width,
      height = record.height,
      sourceData = sourceData,
      paletteData = paletteImageData,
      kind = kind,
      weight = count + record.colors * 4,
    }
  end
  if record.kind == "r8" then
    local paletteData = assert(record.paletteData, "indexed image fallback needs palette bytes")
    local indexData = assert(record.indexData, "indexed image fallback needs index bytes")
    assert(dataByteSize(indexData) == count, "indexed image payload length must match its dimensions")
    assert(dataByteSize(paletteData) == record.colors * 4, "palette payload length must match its slot count")
    local sourceData
    if type(indexData) == "string" or type(paletteData) == "string" then
      local indexString = type(indexData) == "string" and indexData or (indexData --[[@as love.ByteData]]):getString()
      local paletteString = type(paletteData) == "string" and paletteData
        or (paletteData --[[@as love.ByteData]]):getString()
      local rgbaBytes = expandIndexedPayload(indexString, paletteString, count)
      sourceData = love.image.newImageData(record.width, record.height, kind, rgbaBytes)
    else
      local rgbaData = expandIndexedData(indexData --[[@as love.ByteData]], paletteData --[[@as love.ByteData]], count)
      sourceData = love.image.newImageData(record.width, record.height, kind, rgbaData --[[@as string]])
    end
    return {
      pixelHash = hashToString(record.pixelHash),
      width = record.width,
      height = record.height,
      sourceData = sourceData,
      paletteData = nil,
      kind = kind,
      weight = count * 4,
    }
  end
  local indexData = assert(record.indexData, "straight image preparation needs pixel bytes")
  assert(dataByteSize(indexData) == count * 4, "straight image payload length must match its dimensions")
  local sourceData = love.image.newImageData(record.width, record.height, kind, indexData --[[@as string]])
  return {
    pixelHash = hashToString(record.pixelHash),
    width = record.width,
    height = record.height,
    sourceData = sourceData,
    paletteData = nil,
    kind = kind,
    weight = count * 4,
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
    -- alive. Resident logical aliases resolve while their physical entry
    -- stays present and are forgotten on eviction, so the maps stay bounded
    -- by the live resident set instead of the session history.
    _images = ResidentAssetCache.new({
      idleByteLimit = opts.idleByteLimit or DEFAULT_IDLE_IMAGE_BYTES,
      release = onPhysicalRelease,
    }),
    _requests = {},
    _residentByLogical = {},
    _logicalByPhysical = {},
    _nextToken = 0,
    _physicalCount = 0,
    _disposed = false,
  }, ImageAssetPool) --[[@as ImageAssetPool]]
  return pool
end

-- Record logical interest in one generated PNG under one immutable sampler
-- state. A still-resident logical mapping resolves without dispatching
-- worker work; otherwise the request enrolls classification work at once.
-- Returns an opaque single-use token; readiness is observed through poll
-- and the token is consumed by exactly one successful acquire.
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
  local samplerCopy = {
    wrapX = sampler.wrapX,
    wrapY = sampler.wrapY,
    minFilter = sampler.minFilter,
    magFilter = sampler.magFilter,
  }
  local logicalKey = logicalKeyFor(logicalPath, samplerCopy)
  local mapped = self._residentByLogical[logicalKey]
  if mapped ~= nil then
    local resident = self._images:find(mapped)
    if resident ~= nil then
      self._nextToken = self._nextToken + 1
      local token = self._nextToken
      self._requests[token] = {
        logicalKey = logicalKey,
        logicalPath = logicalPath,
        sampler = samplerCopy,
        priority = level,
        state = "cached",
        physicalKey = mapped,
      }
      return token
    end
    dropStaleAlias(self, logicalKey, mapped)
  end
  local job = self._queue:request("image-derivative", logicalPath, level)
  self._nextToken = self._nextToken + 1
  local token = self._nextToken
  self._requests[token] = {
    logicalKey = logicalKey,
    logicalPath = logicalPath,
    sampler = samplerCopy,
    priority = level,
    job = job,
    state = "queued",
  }
  return token
end

-- Probe one request without blocking and without creating GPU objects.
-- Returns "pending" while classification or the worker is in flight, "ready"
-- once the pixel identity resolved to a borrowable pair or an unuploaded
-- prepared payload, or "failed" with the cause when the source is missing
-- or its classification is unusable. A ready ticket borrows or realizes
-- exactly once through its consuming acquire.
---@param token integer
---@return string, string?
function ImageAssetPool:poll(token)
  local request = assert(self._requests[token], "unknown image request token")
  if request.state == "cached" or request.state == "prepared" then
    return "ready"
  end
  if request.state == "failed" then
    return "failed", request.failure
  end
  if self._disposed then
    error("image request was cancelled", 0)
  end
  assert(request.state == "queued", "image request is not ready: " .. tostring(request.state))
  local status, cause = self._queue:poll(assert(request.job, "queued image request has no worker job"))
  if status == "pending" then
    return "pending"
  end
  if status == "failed" then
    request.state = "failed"
    request.failure = cause
    return "failed", cause
  end
  local payload = self._queue:take(assert(request.job, "queued image request has no worker job"))
  request.job = nil
  local keyOk, physicalKey = pcall(keyForPayload, self, payload --[[@as ImageAssetPoolPayload]], request.sampler)
  if not keyOk then
    request.state = "failed"
    request.failure = tostring(physicalKey)
    return "failed", tostring(physicalKey)
  end
  ---@cast physicalKey string
  local resident = self._images:find(physicalKey)
  if resident ~= nil then
    request.payload = nil
    request.physicalKey = physicalKey
    request.state = "cached"
    return "ready"
  end
  request.payload = payload --[[@as ImageAssetPoolPayload]]
  request.physicalKey = physicalKey
  request.state = "prepared"
  return "ready"
end

-- Borrow one ready ticket as an immutable lease record and consume the
-- ticket. A live pair is borrowed directly; otherwise the prepared payload
-- is realized and published exactly once under its physical identity, so
-- compatible tickets that resolved the same identity share one image and
-- palette while a different wrap, filter, or representation never aliases.
-- The lease holds the pair alive; release it when the logical owner lets
-- go. Acquiring before readiness, after failure, cancellation, or a second
-- acquire of the same token fails loudly instead of fabricating pixels.
---@param token integer
---@return ImageAssetPoolLease
function ImageAssetPool:acquire(token)
  local request = assert(self._requests[token], "unknown image request token")
  if request.state ~= "cached" and request.state ~= "prepared" then
    if request.state == "failed" then
      error("image request is not ready: failed", 0)
    end
    error("image request is not ready: " .. tostring(request.state), 0)
  end
  local key = assert(request.physicalKey, "ready image request has no physical identity")
  local found = self._images:find(key)
  if found ~= nil then
    local physical = found --[[@as ImageAssetPoolPhysical]]
    request.payload = nil
    local borrowed = self._images:borrow(key)
    physical.liveLeases = physical.liveLeases + 1
    if physical.liveLeases > 1 then
      physical.shared = true
    end
    registerAlias(self, request.logicalKey, key)
    self._requests[token] = nil
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
  if request.state == "cached" then
    dropStaleAlias(self, request.logicalKey, key)
    self._requests[token] = nil
    error("physical image left the pool under its request", 0)
  end
  local payload = assert(request.payload, "prepared image request has no payload")
  local decodeOk, realized = pcall(realizePayload, self, payload)
  if not decodeOk then
    request.payload = nil
    self._requests[token] = nil
    error(realized, 0)
  end
  ---@cast realized ImageAssetPoolRealizedPixels
  assert(realized.pixelHash ~= nil, "realized image has no pixel identity")
  local staged = {} ---@type ImageAssetPoolImage[]
  local stageOk, image, palette =
    pcall(stagePhysicalObjects, staged, self._graphics, realized.sourceData, realized.paletteData, request.sampler)
  if not stageOk then
    for _, object in ipairs(staged) do
      pcall(releaseStagedObject, object)
    end
    request.payload = nil
    self._requests[token] = nil
    error(image, 0)
  end
  attachSourcePayload(image, realized.sourceData)
  local physical = {
    image = image,
    palette = palette,
    kind = realized.kind,
    width = realized.width,
    height = realized.height,
    physicalKey = key,
    bytes = realized.weight,
    liveLeases = 1,
    shared = false,
  }
  local publishOk, publishErr = pcall(function()
    self._images:publish(key, physical, realized.weight)
  end)
  if not publishOk then
    pcall(releaseStagedObject, image)
    if palette ~= nil then
      pcall(releaseStagedObject, palette)
    end
    request.payload = nil
    self._requests[token] = nil
    error(publishErr, 0)
  end
  self._physicalCount = self._physicalCount + 1
  local borrowed = self._images:borrow(key)
  registerAlias(self, request.logicalKey, key)
  request.payload = nil
  self._requests[token] = nil
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

-- Drop logical interest in one request that never reached a lease.
-- Queued work cancels through the borrowed queue so its late payload is
-- discarded; prepared payloads and cached identities are forgotten without
-- creating GPU objects. Consumed or unknown tokens report false: an
-- acquired ticket owns its borrow through its lease, never through a
-- resurrected token. Total: never fails.
---@param token integer
---@return boolean true when interest was dropped
function ImageAssetPool:cancel(token)
  local request = self._requests[token]
  if request == nil then
    return false
  end
  if request.job ~= nil then
    pcall(function()
      self._queue:cancel(request.job)
    end)
    request.job = nil
  end
  request.payload = nil
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
-- idle age; eviction invalidates every logical alias to the evicted pair
-- through the release callback, so no later request resolves a stale hit.
---@return integer
function ImageAssetPool:prune()
  local evicted, _ = self._images:trim()
  return evicted
end

-- Cancel every pending ticket, drop unclaimed payloads, and release
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
    if request.job ~= nil then
      -- A borrowed session queue outlives this pool: drop the worker
      -- interest so its late payload is discarded instead of retained
      -- unclaimed until the session owner joins the worker.
      pcall(function()
        self._queue:cancel(request.job)
      end)
      request.job = nil
    end
    request.payload = nil
  end
  self._requests = {}
  self._residentByLogical = {}
  self._logicalByPhysical = {}
  -- Only the pool-owned fallback worker is joined here; a borrowed
  -- session worker stays live for its owner.
  if self._ownsQueue then
    self._queue:release()
  end
  self._images:clear()
end

-- Current census: live ticket states, live physical pairs, and resident
-- bytes split into idle and lease-held shares. Ticket counts are current
-- live interest, never history: successful acquires and cancellations
-- leave no record behind.
---@return ImageAssetPoolStats
function ImageAssetPool:stats()
  local resident = self._images:stats()
  local staged = 0
  local ready = 0
  local failed = 0
  for _, request in pairs(self._requests) do
    if request.state == "prepared" then
      staged = staged + 1
    elseif request.state == "cached" then
      ready = ready + 1
    elseif request.state == "failed" then
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
