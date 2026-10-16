-- Immutable packed PCM16 sample with one typed FFI backing. fromBytes copies
-- a Lua payload string into a single int16 array once; fromData adopts a
-- caller-supplied Data beside its read pointer without copying. Voices
-- borrow the object and read through the pre-cast pointer; read(index) is
-- the checked test path over the same backing. Only little-endian hosts
-- are supported.

local ffi = require("ffi")

---@class Pcm16Data
---@field getFFIPointer fun(self: Pcm16Data): ffi.cdata*
---@field getSize fun(self: Pcm16Data): integer

---@class Pcm16
---@field data ffi.cdata*|Pcm16Data the strong backing owner (FFI array or adopted Data)
---@field ptr ffi.cdata* the cached const int16_t read pointer
---@field frames integer the sample frame count
---@field fromBytes fun(bytes: string): Pcm16
---@field fromData fun(data: Pcm16Data|userdata): Pcm16
---@field read fun(self: Pcm16, index: integer): integer

local Pcm16 = {}
Pcm16.__index = Pcm16

assert(ffi.abi("le"), "packed PCM16 samples require a little-endian host")

---@param size integer
local function checkSize(size)
  assert(
    type(size) == "number" and size % 1 == 0 and size > 0 and size % 2 == 0,
    "packed PCM16 needs a non-empty even byte count"
  )
end

---@param bytes string
---@return Pcm16
function Pcm16.fromBytes(bytes)
  assert(type(bytes) == "string", "packed PCM16 packs a payload string")
  checkSize(#bytes)
  local frames = math.floor(#bytes / 2)
  local backing = ffi.new("int16_t[?]", frames)
  ffi.copy(backing, bytes, #bytes)
  return setmetatable({
    data = backing,
    ptr = ffi.cast("const int16_t *", backing),
    frames = frames,
  }, Pcm16) --[[@as Pcm16]]
end

-- Adopts a worker-prepared Data without copying: the Data stays beside the
-- pointer as the strong owner, so the pointer is valid while the object
-- lives. The Data is duck-typed (getFFIPointer/getSize) and never imported
-- from love, keeping this module headless.
---@param data Pcm16Data|userdata
---@return Pcm16
function Pcm16.fromData(data)
  assert(type(data) == "table" or type(data) == "userdata", "packed PCM16 adopts a Data object")
  assert(type(data.getFFIPointer) == "function", "adopted PCM16 Data requires getFFIPointer")
  assert(type(data.getSize) == "function", "adopted PCM16 Data requires getSize")
  ---@cast data Pcm16Data
  local size = data:getSize()
  checkSize(size)
  local pointer = data:getFFIPointer()
  assert(pointer ~= nil, "adopted PCM16 Data returned a nil pointer")
  return setmetatable({
    data = data,
    ptr = ffi.cast("const int16_t *", pointer),
    frames = math.floor(size / 2),
  }, Pcm16) --[[@as Pcm16]]
end

-- Test-only checked read: zero-based indexed int16 over the backing.
---@param index integer
---@return integer
function Pcm16:read(index)
  assert(
    type(index) == "number" and index % 1 == 0 and index >= 0 and index < self.frames,
    "packed PCM16 index out of range"
  )
  return tonumber(self.ptr[index]) --[[@as integer]]
end

return Pcm16
