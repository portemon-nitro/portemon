-- Private effective-image derivative format: versioned binary paths, header
-- integrity, and exact pixel round-trips through an isolated cache root.
-- Source-independent and love-free: hashing happens worker-side
-- (love.data.hash); this module only stores and validates opaque 32-byte
-- identities, dimensions, and payload bytes. The file layout is G4RI v1:
-- magic, version, representation, dimensions, palette count, payload
-- lengths, the source and pixel hashes, the packed payloads, and a trailing
-- integrity word over everything before it. The derivative is disposable:
-- a missing or damaged file rebuilds from the still-trusted generated PNG,
-- and publication is atomic (confined stage file plus replace), so a failed
-- write keeps the previously published derivative intact.

local ffi = require("ffi")

local Errors = require("libs.errors.src.Errors")

local RuntimeImageCache = {}

---@class RuntimeImageCache.Entry
---@field sourceHash string|userdata 32 raw SHA256 bytes over the effective PNG bytes
---@field pixelHash string|userdata 32 raw SHA256 bytes over the raw row-major RGBA bytes
---@field width integer
---@field height integer
---@field kind "r8"|"rgba8"
---@field colors integer palette slot count, zero for straight RGBA
---@field index string packed first-seen slots, or straight RGBA bytes on fallback
---@field palette string concatenated RGBA tuples in first-seen order; empty on fallback

---@class RuntimeImageCache
---@field FORMAT_VERSION integer
---@field pathFor fun(sourceHash: string, version: integer): string
---@field encode fun(entry: RuntimeImageCache.Entry): string
---@field decode fun(bytes: string): RuntimeImageCache.Entry
---@field store fun(cache: table<string, unknown>, path: string, bytes: string): boolean
---@field load fun(cache: table<string, unknown>, path: string): RuntimeImageCache.Entry?

RuntimeImageCache.FORMAT_VERSION = 1

local MAGIC = "G4RI"
local KIND_R8_BYTE = 1
local KIND_RGBA8_BYTE = 2
local HASH_LENGTH = 32
local HEADER_LENGTH = 4 + 1 + 1 + 4 + 4 + 4 + 4 + 4 + HASH_LENGTH + HASH_LENGTH
local CHECKSUM_LENGTH = 4
local MAX_DIMENSION = 16777215
local MAX_DIMENSION_PRODUCT = 4294967295
local MAX_INDEXED_COLORS = 256
local STAGE_SUFFIX = ".__g4next"

---@param value integer
---@return string
local function writeU32LE(value)
  local first = value % 256
  local second = math.floor(value / 256) % 256
  local third = math.floor(value / 65536) % 256
  local fourth = math.floor(value / 16777216) % 256
  return string.char(first, second, third, fourth)
end

---@param bytes string
---@param position integer 1-based offset of the word
---@return integer
local function readU32LE(bytes, position)
  local first, second, third, fourth = bytes:byte(position, position + 3)
  assert(first ~= nil and second ~= nil and third ~= nil and fourth ~= nil, "u32 read past the header end")
  return first + second * 256 + third * 65536 + fourth * 16777216
end

-- Integrity word only: corruption detection for a disposable, rebuildable
-- file. Source and pixel identity stay cryptographic (SHA256 fields below);
-- hashing here would need love and does not belong in this package.
-- The checksum reads the live string through a typed byte view, so the
-- caller must keep owning `bytes` for the whole call and pass a prefix
-- length already validated against `#bytes`.
---@param bytes string live bytes owning the checked prefix
---@param length integer validated prefix length, `0 <= length <= #bytes`
---@return integer
local function integrityWord(bytes, length)
  assert(type(bytes) == "string", "integrity input must be a byte string")
  assert(
    type(length) == "number" and length % 1 == 0 and length >= 0 and length <= #bytes,
    "integrity length must be a validated prefix of the input"
  )
  local view = ffi.cast("const uint8_t *", bytes)
  local first, second = 1, 0
  for index = 0, length - 1 do
    first = (first + view[index]) % 65521
    second = (second + first) % 65521
  end
  return second * 65536 + first
end

---@param bytes string
---@return string
local function toHex(bytes)
  local parts = {}
  for index = 1, #bytes do
    parts[index] = string.format("%02x", bytes:byte(index))
  end
  return table.concat(parts)
end

---@param value unknown
---@return string 32 raw hash bytes
local function normalizeHash(value)
  if type(value) == "string" and #value == HASH_LENGTH then
    return value
  end
  if type(value) == "userdata" then
    local shaped = value --[[@as table<string, unknown>]]
    if type(shaped.getString) == "function" then
      local text = (shaped.getString --[[@as fun(self: unknown): unknown]])(value)
      if type(text) == "string" and #text == HASH_LENGTH then
        return text
      end
    end
  end
  Errors.raise("IMAGE_DERIVATIVE_BAD_HASH", "image derivative identities are 32 raw hash bytes", {})
  error("unreachable hash identity", 0)
end

---@param sourceHash string|userdata 32 raw SHA256 bytes over the effective PNG bytes
---@param version integer derivative format version
---@return string cache-relative confined derivative path
function RuntimeImageCache.pathFor(sourceHash, version)
  local hash = normalizeHash(sourceHash)
  if type(version) ~= "number" or version % 1 ~= 0 or version < 1 then
    Errors.raise("IMAGE_DERIVATIVE_BAD_VERSION", "image derivative version must be a positive integer", {})
  end
  return string.format("_private/image-derivatives/v%d/%s.g4ri", version, toHex(hash))
end

---@param kind unknown
---@return integer
local function kindByte(kind)
  if kind == "r8" then
    return KIND_R8_BYTE
  end
  if kind == "rgba8" then
    return KIND_RGBA8_BYTE
  end
  Errors.raise("IMAGE_DERIVATIVE_BAD_KIND", "image derivative representations are r8 or rgba8", { kind = kind })
  error("unreachable representation", 0)
end

---@param byte integer
---@return "r8"|"rgba8"
local function kindName(byte)
  if byte == KIND_R8_BYTE then
    return "r8"
  end
  if byte == KIND_RGBA8_BYTE then
    return "rgba8"
  end
  Errors.raise("IMAGE_DERIVATIVE_CORRUPT", "image derivative carries an unknown representation", {})
  error("unreachable representation name", 0)
end

---@param entry RuntimeImageCache.Entry
---@return string deterministic derivative bytes
function RuntimeImageCache.encode(entry)
  assert(type(entry) == "table", "image derivative encoding requires an entry table")
  local sourceHash = normalizeHash(entry.sourceHash)
  local pixelHash = normalizeHash(entry.pixelHash)
  local width, height = entry.width, entry.height
  if
    type(width) ~= "number"
    or width % 1 ~= 0
    or width < 1
    or width > MAX_DIMENSION
    or type(height) ~= "number"
    or height % 1 ~= 0
    or height < 1
    or height > MAX_DIMENSION
    or height > math.floor(MAX_DIMENSION_PRODUCT / width)
  then
    Errors.raise(
      "IMAGE_DERIVATIVE_BAD_DIMENSIONS",
      "image derivative dimensions must be positive with a u32-representable product",
      {}
    )
  end
  ---@cast width integer
  ---@cast height integer
  local kind = kindByte(entry.kind)
  local colors = entry.colors
  if type(colors) ~= "number" or colors % 1 ~= 0 then
    Errors.raise("IMAGE_DERIVATIVE_BAD_LAYOUT", "image derivative palette count must be an integer", {})
  end
  ---@cast colors integer
  local index = entry.index
  local palette = entry.palette
  if palette == nil then
    palette = ""
  end
  if type(index) ~= "string" or type(palette) ~= "string" then
    Errors.raise("IMAGE_DERIVATIVE_BAD_LAYOUT", "image derivative payloads are byte strings", {})
  end
  ---@cast index string
  ---@cast palette string
  local pixels = width * height
  if kind == KIND_R8_BYTE then
    if colors < 1 or colors > MAX_INDEXED_COLORS then
      Errors.raise("IMAGE_DERIVATIVE_BAD_LAYOUT", "indexed derivatives keep 1..256 palette slots", {})
    end
    if #index ~= pixels or #palette ~= colors * 4 then
      Errors.raise("IMAGE_DERIVATIVE_BAD_LAYOUT", "indexed payload lengths disagree with dimensions", {})
    end
  else
    if colors ~= 0 then
      Errors.raise("IMAGE_DERIVATIVE_BAD_LAYOUT", "straight RGBA derivatives carry no palette count", {})
    end
    if #index ~= pixels * 4 or #palette ~= 0 then
      Errors.raise("IMAGE_DERIVATIVE_BAD_LAYOUT", "straight RGBA payload lengths disagree with dimensions", {})
    end
  end
  local header = MAGIC
    .. string.char(RuntimeImageCache.FORMAT_VERSION)
    .. string.char(kind)
    .. writeU32LE(width)
    .. writeU32LE(height)
    .. writeU32LE(colors)
    .. writeU32LE(#index)
    .. writeU32LE(#palette)
    .. sourceHash
    .. pixelHash
  local body = header .. index .. palette
  return body .. writeU32LE(integrityWord(body, #body))
end

---@param bytes string
---@return RuntimeImageCache.Entry decoded derivative entry
function RuntimeImageCache.decode(bytes)
  assert(type(bytes) == "string", "image derivative decoding requires byte input")
  if #bytes < HEADER_LENGTH + CHECKSUM_LENGTH then
    Errors.raise("IMAGE_DERIVATIVE_CORRUPT", "image derivative bytes are truncated", { length = #bytes })
  end
  if bytes:sub(1, 4) ~= MAGIC then
    Errors.raise("IMAGE_DERIVATIVE_CORRUPT", "image derivative magic mismatch", {})
  end
  if bytes:byte(5) ~= RuntimeImageCache.FORMAT_VERSION then
    Errors.raise("IMAGE_DERIVATIVE_CORRUPT", "image derivative version mismatch", {})
  end
  local kind = kindName(bytes:byte(6))
  local width = readU32LE(bytes, 7)
  local height = readU32LE(bytes, 11)
  local colors = readU32LE(bytes, 15)
  local indexLength = readU32LE(bytes, 19)
  local paletteLength = readU32LE(bytes, 23)
  if width < 1 or width > MAX_DIMENSION or height < 1 or height > MAX_DIMENSION then
    Errors.raise("IMAGE_DERIVATIVE_CORRUPT", "image derivative dimensions are out of range", {})
  end
  if height > math.floor(MAX_DIMENSION_PRODUCT / width) then
    Errors.raise("IMAGE_DERIVATIVE_CORRUPT", "image derivative dimension product overflows", {})
  end
  local pixels = width * height
  if kind == "r8" then
    if colors < 1 or colors > MAX_INDEXED_COLORS then
      Errors.raise("IMAGE_DERIVATIVE_CORRUPT", "indexed derivative palette count is out of range", {})
    end
    if indexLength ~= pixels or paletteLength ~= colors * 4 then
      Errors.raise("IMAGE_DERIVATIVE_CORRUPT", "indexed derivative payload lengths disagree", {})
    end
  else
    if colors ~= 0 then
      Errors.raise("IMAGE_DERIVATIVE_CORRUPT", "straight RGBA derivative carries a palette count", {})
    end
    if indexLength ~= pixels * 4 or paletteLength ~= 0 then
      Errors.raise("IMAGE_DERIVATIVE_CORRUPT", "straight RGBA derivative payload lengths disagree", {})
    end
  end
  if #bytes ~= HEADER_LENGTH + indexLength + paletteLength + CHECKSUM_LENGTH then
    Errors.raise("IMAGE_DERIVATIVE_CORRUPT", "image derivative size disagrees with its header", { length = #bytes })
  end
  local prefixLength = HEADER_LENGTH + indexLength + paletteLength
  local stored = readU32LE(bytes, prefixLength + 1)
  if integrityWord(bytes, prefixLength) ~= stored then
    Errors.raise("IMAGE_DERIVATIVE_CORRUPT", "image derivative integrity word mismatch", {})
  end
  local indexStart = HEADER_LENGTH + 1
  local indexEnd = HEADER_LENGTH + indexLength
  return {
    sourceHash = bytes:sub(27, 58),
    pixelHash = bytes:sub(59, 90),
    width = width,
    height = height,
    kind = kind,
    colors = colors,
    index = bytes:sub(indexStart, indexEnd),
    palette = bytes:sub(indexEnd + 1, indexEnd + paletteLength),
  }
end

-- Atomic publication: the bytes land in a confined sibling stage file first
-- and move into place with one replace. A failed write or replace raises
-- the backend's structured error and leaves any previously published
-- derivative untouched; a failed replace also removes its stage residue.
---@param cache table<string, unknown> versioned CacheFs-shaped store
---@param path string cache-relative derivative destination from pathFor
---@param bytes string encoded derivative from encode
---@return boolean
function RuntimeImageCache.store(cache, path, bytes)
  assert(cache ~= nil, "image derivative storage requires a cache")
  assert(type(path) == "string", "image derivative storage requires a path")
  assert(type(bytes) == "string", "image derivative storage requires encoded bytes")
  local staging = path .. STAGE_SUFFIX
  local store = cache --[[@as table<string, fun(self: table, ...: unknown): unknown>]]
  store.write(cache, staging, bytes)
  local ok, replaceError = pcall(store.replace, cache, staging, path)
  if not ok then
    pcall(store.remove, cache, staging)
    error(replaceError, 0)
  end
  return true
end

-- Nil when no derivative was published yet (rebuildable); a structured
-- IMAGE_DERIVATIVE_CORRUPT failure when bytes are present but damaged.
-- The entry carries only the canonical string payloads and stays pure and
-- love-free; the worker wraps validated strings into transfer-ready Data
-- views before replying to the queue.
---@param cache table<string, unknown> versioned CacheFs-shaped store
---@param path string cache-relative derivative path from pathFor
---@return RuntimeImageCache.Entry? decoded entry, or nil when absent
function RuntimeImageCache.load(cache, path)
  assert(cache ~= nil, "image derivative loading requires a cache")
  assert(type(path) == "string", "image derivative loading requires a path")
  local store = cache --[[@as table<string, fun(self: table, ...: unknown): unknown>]]
  local bytes = store.read(cache, path)
  if bytes == nil then
    return nil
  end
  assert(type(bytes) == "string", "image derivative cache reads must be byte strings")
  return RuntimeImageCache.decode(bytes)
end

return RuntimeImageCache
