-- Worker-side effective-image classifier: exact RGBA scan over a contiguous
-- row-major RGBA8 buffer (a decoded ImageData or the love Data a decoder
-- already filled), first-seen palette order, bulk FFI copies. Consumed only
-- by the preparation worker; never touches GPU objects. At most 256 exact
-- RGBA words pack to one index byte per pixel plus an exact RGBA palette;
-- anything more crowded falls back to straight RGBA bytes. Transparent RGB
-- and fractional alpha stay distinct: all four channels feed both the palette
-- key and the pixel hash. Fails loudly off little-endian rather than
-- byte-swapping pixels silently.

local ffi = require("ffi")

local ImageDerivative = {}

---@class ImageDerivativeClassification
---@field width integer
---@field height integer
---@field kind "r8"|"rgba8"
---@field colors integer palette slot count, zero for straight RGBA
---@field pixelHash string SHA256 over the raw row-major RGBA bytes
---@field indexData love.ByteData packed first-seen slots, or straight RGBA bytes on fallback
---@field paletteData love.ByteData? concatenated RGBA tuples in first-seen order; nil on fallback

---@class ImageDerivative
---@field classify fun(imageData: love.ImageData): ImageDerivativeClassification
---@field classifyPixels fun(width: integer, height: integer, pixels: love.Data): ImageDerivativeClassification

local MAX_INDEXED_COLORS = 256

---@param pixels love.Data
---@param byteCount integer
---@return ffi.cdata* pointer
local function pixelBufferPointer(pixels, byteCount)
  assert(pixels ~= nil, "image classification requires a love Data pixel buffer")
  local size = pixels:getSize()
  assert(size == byteCount, string.format("image classification requires %d RGBA bytes, got %d", byteCount, size))
  local pointer = pixels:getFFIPointer()
  assert(pointer ~= nil, "image classification requires a contiguous pixel buffer")
  return pointer
end

-- Exact classification of one row-major RGBA8 pixel buffer. Returns
-- dimensions, the representation, the palette slot count (zero for straight
-- RGBA), the SHA256 pixel hash over the raw row-major RGBA bytes, and love
-- Data payloads (nil palette for straight RGBA). Two passes over contiguous
-- uint32 words with at most 256 Lua dictionary entries; the only per-byte
-- work is bulk ffi.copy, never per-pixel allocation.
---@param width integer
---@param height integer
---@param pixels love.Data exact row-major RGBA8 pixel bytes
---@return ImageDerivativeClassification classification record with love Data payloads
function ImageDerivative.classifyPixels(width, height, pixels)
  assert(
    type(width) == "number" and width % 1 == 0 and width >= 1,
    "image classification requires a positive integer width"
  )
  assert(
    type(height) == "number" and height % 1 == 0 and height >= 1,
    "image classification requires a positive integer height"
  )
  if ffi.abi("le") ~= true then
    error("image classification requires a little-endian host", 0)
  end
  local count = width * height
  local pointer = pixelBufferPointer(pixels, count * 4)
  local words = ffi.cast("const uint32_t *", pointer)
  local seen = {}
  local order = {}
  local distinct = 0
  local crowded = false
  for index = 0, count - 1 do
    local word = words[index]
    if seen[word] == nil then
      if distinct >= MAX_INDEXED_COLORS then
        crowded = true
        break
      end
      seen[word] = distinct
      distinct = distinct + 1
      order[distinct] = word
    end
  end
  local pixelHash = love.data.hash("sha256", pixels)
  if crowded then
    local rgba = love.data.newByteData(count * 4)
    ffi.copy(rgba:getFFIPointer(), pointer, count * 4)
    return {
      width = width,
      height = height,
      kind = "rgba8",
      colors = 0,
      pixelHash = pixelHash,
      indexData = rgba,
      paletteData = nil,
    }
  end
  local indexes = love.data.newByteData(count)
  local palette = love.data.newByteData(distinct * 4)
  local indexBytes = ffi.cast("uint8_t *", indexes:getFFIPointer())
  local paletteWords = ffi.cast("uint32_t *", palette:getFFIPointer())
  for slot = 0, distinct - 1 do
    paletteWords[slot] = order[slot + 1]
  end
  for index = 0, count - 1 do
    indexBytes[index] = seen[words[index]]
  end
  return {
    width = width,
    height = height,
    kind = "r8",
    colors = distinct,
    pixelHash = pixelHash,
    indexData = indexes,
    paletteData = palette,
  }
end

-- Classify one decoded RGBA8 image by reading its dimensions and handing its
-- own pixel bytes to the buffer core.
---@param imageData love.ImageData decoded RGBA8 image data
---@return ImageDerivativeClassification classification record with love Data payloads
function ImageDerivative.classify(imageData)
  assert(imageData ~= nil, "image classification requires decoded image data")
  local data = imageData --[[@as table<string, fun(self: love.ImageData): unknown>]]
  local width = data.getWidth(imageData)
  local height = data.getHeight(imageData)
  assert(type(width) == "number" and width % 1 == 0 and width >= 1, "image classification requires a decoded width")
  assert(type(height) == "number" and height % 1 == 0 and height >= 1, "image classification requires a decoded height")
  ---@cast width integer
  ---@cast height integer
  return ImageDerivative.classifyPixels(width, height, imageData)
end

return ImageDerivative
