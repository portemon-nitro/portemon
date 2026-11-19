-- Engine-owned G4TX texture bank: one source TEX0 pack's named textures and
-- named palettes in one compact little-endian file. A material resolves a
-- texture name and a palette name independently against the same bank, so the
-- same indexed texels serve several palettes without an expanded image per
-- pairing. Each texture record keeps the source DS format, extent, colour-0
-- transparency, its byte-exact texel payload and, for 4x4-compressed formats,
-- its index region; each palette record keeps its byte-exact palette payload.
-- No RGBA copy and no source archive identity is stored. Pure domain module:
-- no love dependency.

local bit = require("bit")
local BinaryReader = require("libs.codec.src.BinaryReader")
local Errors = require("libs.errors.src.Errors")

local NativeTextureBank = {}

local MAGIC = "G4TX"
local VERSION = 1
-- magic[4], u16 version, u16 reserved, u32 totalBytes, u32 textureCount,
-- u32 paletteCount, u32 textureTableOffset, u32 paletteTableOffset,
-- u32 payloadOffset.
local HEADER_SIZE = 32
-- u32 nameOffset, u16 nameLength, u16 flags, u32 formatRaw, u16 width,
-- u16 height, u32 texelsOffset, u32 texelsLength, u32 indexOffset,
-- u32 indexLength.
local TEXTURE_RECORD_SIZE = 32
-- u32 nameOffset, u16 nameLength, u16 reserved, u32 dataOffset, u32 dataLength.
local PALETTE_RECORD_SIZE = 16
local FLAG_COLOR0_TRANSPARENT = 0x01
local UINT32_MAX = 0xFFFFFFFF

NativeTextureBank.MAGIC = MAGIC
NativeTextureBank.VERSION = VERSION
NativeTextureBank.HEADER_SIZE = HEADER_SIZE
NativeTextureBank.TEXTURE_RECORD_SIZE = TEXTURE_RECORD_SIZE
NativeTextureBank.PALETTE_RECORD_SIZE = PALETTE_RECORD_SIZE

local function fail(code, message, context)
  Errors.raise(code, message, context)
end

local function unsigned(value, limit, name)
  if type(value) ~= "number" or value ~= math.floor(value) or value < 0 or value > limit then
    fail(
      "NATIVE_TEX_BAD_FIELD",
      string.format("%s must be an integer in 0..%d, got %s", name, limit, tostring(value)),
      { field = name }
    )
  end
  return value
end

local function bytesOf(value, name)
  if type(value) == "string" then
    return value
  end
  if type(value) == "table" then
    local getString = value.getString
    if type(getString) == "function" then
      return getString(value)
    end
  end
  fail("NATIVE_TEX_BAD_FIELD", name .. " must be bytes", { field = name })
end

local function nameOf(value, label)
  if type(value) ~= "string" or value == "" then
    fail("NATIVE_TEX_BAD_FIELD", label .. " name must be a non-empty string", { field = label })
  end
  if value:find("\0", 1, true) ~= nil then
    fail("NATIVE_TEX_BAD_FIELD", label .. " name must not embed a terminator", { field = label })
  end
  return value
end

local function align4(value)
  return math.floor((value + 3) / 4) * 4
end

local function u16(value)
  return string.char(value % 256, math.floor(value / 256) % 256)
end

local function u32(value)
  return string.char(
    value % 256,
    math.floor(value / 256) % 256,
    math.floor(value / 65536) % 256,
    math.floor(value / 16777216) % 256
  )
end

---@class NativeTextureBank.Texture
---@field name string
---@field formatRaw integer DS texture format number
---@field width integer
---@field height integer
---@field color0Transparent boolean
---@field texels string byte-exact encoded texels
---@field indexData string|nil the 4x4-compressed index region

---@class NativeTextureBank.Palette
---@field name string
---@field data string byte-exact palette payload

-- Deterministic, bounded encoding: fixed header, both record tables, then the
-- names and payloads. Record order is the caller's input order, so an
-- unchanged source pack always produces identical bytes.
---@param record { textures: NativeTextureBank.Texture[], palettes: NativeTextureBank.Palette[] }
---@return string
function NativeTextureBank.encode(record)
  if type(record) ~= "table" or type(record.textures) ~= "table" or type(record.palettes) ~= "table" then
    fail("NATIVE_TEX_BAD_RECORD", "the native texture bank record needs texture and palette lists", {})
  end
  local textures, palettes = record.textures, record.palettes
  local textureCount, paletteCount = #textures, #palettes
  unsigned(textureCount, UINT32_MAX, "texture count")
  unsigned(paletteCount, UINT32_MAX, "palette count")

  local textureTableOffset = HEADER_SIZE
  local paletteTableOffset = textureTableOffset + textureCount * TEXTURE_RECORD_SIZE
  local payloadOffset = align4(paletteTableOffset + paletteCount * PALETTE_RECORD_SIZE)

  local names = {}
  local seenTextureNames = {}
  local seenPaletteNames = {}
  local cursor = payloadOffset
  local preparedTextures = {}
  for index, texture in ipairs(textures) do
    if type(texture) ~= "table" then
      fail("NATIVE_TEX_BAD_RECORD", "texture " .. index .. " is not a record", { textureIndex = index - 1 })
    end
    local name = nameOf(texture.name, "texture")
    if seenTextureNames[name] then
      fail("NATIVE_TEX_DUPLICATE_NAME", "two textures share one name: " .. name, { name = name })
    end
    seenTextureNames[name] = true
    local texels = bytesOf(texture.texels, "texture texels")
    local indexData = texture.indexData ~= nil and bytesOf(texture.indexData, "texture index data") or nil
    preparedTextures[index] = {
      name = name,
      formatRaw = unsigned(texture.formatRaw or 0, 7, "texture format"),
      width = unsigned(texture.width or 0, 0xFFFF, "texture width"),
      height = unsigned(texture.height or 0, 0xFFFF, "texture height"),
      color0Transparent = texture.color0Transparent == true,
      texels = texels,
      indexData = indexData,
    }
    names[#names + 1] = name
    cursor = cursor + #name
    cursor = align4(cursor) + #texels
    cursor = align4(cursor) + (indexData ~= nil and #indexData or 0)
    cursor = align4(cursor)
  end
  local preparedPalettes = {}
  for index, palette in ipairs(palettes) do
    if type(palette) ~= "table" then
      fail("NATIVE_TEX_BAD_RECORD", "palette " .. index .. " is not a record", { paletteIndex = index - 1 })
    end
    local name = nameOf(palette.name, "palette")
    if seenPaletteNames[name] then
      fail("NATIVE_TEX_DUPLICATE_NAME", "two palettes share one name: " .. name, { name = name })
    end
    seenPaletteNames[name] = true
    local data = bytesOf(palette.data, "palette data")
    preparedPalettes[index] = { name = name, data = data }
    cursor = cursor + #name
    cursor = align4(cursor) + #data
    cursor = align4(cursor)
  end
  local totalBytes = cursor

  -- Lay the payload out once, so record offsets and emitted bytes come from
  -- the same deterministic walk.
  local payload = {}
  local payloadLength = payloadOffset
  local function append(text)
    payload[#payload + 1] = text
    payloadLength = payloadLength + #text
  end
  local function padTo4()
    local remainder = payloadLength % 4
    if remainder ~= 0 then
      append(string.rep("\0", 4 - remainder))
    end
  end
  for _, item in ipairs(preparedTextures) do
    item.nameOffset = payloadLength
    append(item.name)
    padTo4()
    item.texelsOffset = payloadLength
    append(item.texels)
    padTo4()
    if item.indexData ~= nil then
      item.indexOffset = payloadLength
      append(item.indexData)
      padTo4()
    else
      item.indexOffset = 0
    end
  end
  for _, item in ipairs(preparedPalettes) do
    item.nameOffset = payloadLength
    append(item.name)
    padTo4()
    item.dataOffset = payloadLength
    append(item.data)
    padTo4()
  end
  assert(payloadLength == totalBytes, "native texture bank payload size disagrees with its layout")

  local chunks = {
    MAGIC,
    u16(VERSION),
    u16(0),
    u32(totalBytes),
    u32(textureCount),
    u32(paletteCount),
    u32(textureTableOffset),
    u32(paletteTableOffset),
    u32(payloadOffset),
  }
  for _, item in ipairs(preparedTextures) do
    chunks[#chunks + 1] = u32(item.nameOffset)
      .. u16(#item.name)
      .. u16(item.color0Transparent and FLAG_COLOR0_TRANSPARENT or 0)
      .. u32(item.formatRaw)
      .. u16(item.width)
      .. u16(item.height)
      .. u32(item.texelsOffset)
      .. u32(#item.texels)
      .. u32(item.indexOffset)
      .. u32(item.indexData ~= nil and #item.indexData or 0)
  end
  for _, item in ipairs(preparedPalettes) do
    chunks[#chunks + 1] = u32(item.nameOffset) .. u16(#item.name) .. u16(0) .. u32(item.dataOffset) .. u32(#item.data)
  end
  if #names > 0 then
    chunks[#chunks + 1] = table.concat(payload)
  end
  local encoded = table.concat(chunks)
  assert(#encoded == totalBytes, "native texture bank encoded an unexpected size")
  return encoded
end

-- The reader hands back read-only descriptions pinned to the source bytes;
-- an unknown name resolves nothing.
---@class NativeTextureBank.Bank
---@field textureCount integer
---@field paletteCount integer
---@field private _textures table<string, NativeTextureBank.Texture>
---@field private _palettes table<string, NativeTextureBank.Palette>
---@field texture fun(self: NativeTextureBank.Bank, name: string): NativeTextureBank.Texture|nil
---@field palette fun(self: NativeTextureBank.Bank, name: string): NativeTextureBank.Palette|nil

local Bank = {}
Bank.__index = Bank

---@param name string
---@return NativeTextureBank.Texture|nil
function Bank:texture(name)
  return self._textures[name]
end

---@param name string
---@return NativeTextureBank.Palette|nil
function Bank:palette(name)
  return self._palettes[name]
end

local function readName(reader, offset, length, label)
  if length == 0 then
    fail("NATIVE_TEX_BAD_FIELD", label .. " name is empty", { offset = offset })
  end
  local name = reader:bytes(offset, length)
  if name:find("\0", 1, true) ~= nil then
    fail("NATIVE_TEX_BAD_FIELD", label .. " name embeds a terminator", { offset = offset })
  end
  return name
end

-- Read one G4TX bank. Version, counts, table offsets and every name/payload
-- span are validated before any record is returned, so a malformed bank is
-- rejected whole instead of partially decoded.
---@param bytes string|love.Data
---@return NativeTextureBank.Bank|nil bank
---@return Errors.Error|nil error
function NativeTextureBank.read(bytes)
  local reader = BinaryReader.new(bytes, "g4tx")
  local length = reader:length()
  if length < HEADER_SIZE then
    fail("NATIVE_TEX_BAD_LENGTH", "native texture bank is shorter than its header", { size = length })
  end
  local magic = reader:ascii(0, 4)
  if magic ~= MAGIC then
    fail("NATIVE_TEX_BAD_MAGIC", "expected " .. MAGIC .. " magic, got " .. magic, { magic = magic })
  end
  local version = reader:u16le(4)
  if version ~= VERSION then
    fail("NATIVE_TEX_BAD_VERSION", "unsupported native texture bank version " .. version, { version = version })
  end
  local totalBytes = reader:u32le(8)
  local textureCount = reader:u32le(12)
  local paletteCount = reader:u32le(16)
  local textureTableOffset = reader:u32le(20)
  local paletteTableOffset = reader:u32le(24)
  local payloadOffset = reader:u32le(28)
  if totalBytes ~= length then
    fail("NATIVE_TEX_BAD_LENGTH", "native texture bank length disagrees with its header", {
      declared = totalBytes,
      size = length,
    })
  end
  if textureTableOffset ~= HEADER_SIZE then
    fail("NATIVE_TEX_BAD_OFFSET", "native texture bank texture table is misplaced", {
      offset = textureTableOffset,
    })
  end
  local paletteTableEnd = paletteTableOffset + paletteCount * PALETTE_RECORD_SIZE
  if
    paletteTableOffset ~= textureTableOffset + textureCount * TEXTURE_RECORD_SIZE
    or paletteTableEnd > payloadOffset
    or payloadOffset > totalBytes
  then
    fail("NATIVE_TEX_BAD_OFFSET", "native texture bank record tables overrun their payload", {
      textureCount = textureCount,
      paletteCount = paletteCount,
      payloadOffset = payloadOffset,
    })
  end

  local byTextureName = {}
  for index = 1, textureCount do
    local recordOffset = textureTableOffset + (index - 1) * TEXTURE_RECORD_SIZE
    local nameOffset = reader:u32le(recordOffset)
    local nameLength = reader:u16le(recordOffset + 4)
    local flags = reader:u16le(recordOffset + 6)
    local formatRaw = reader:u32le(recordOffset + 8)
    local width = reader:u16le(recordOffset + 12)
    local height = reader:u16le(recordOffset + 14)
    local texelsOffset = reader:u32le(recordOffset + 16)
    local texelsLength = reader:u32le(recordOffset + 20)
    local indexOffset = reader:u32le(recordOffset + 24)
    local indexLength = reader:u32le(recordOffset + 28)
    if nameOffset < payloadOffset or texelsOffset < payloadOffset then
      fail("NATIVE_TEX_BAD_OFFSET", "texture record points outside the payload", { textureIndex = index - 1 })
    end
    if indexLength > 0 and indexOffset < payloadOffset then
      fail("NATIVE_TEX_BAD_OFFSET", "texture index region points outside the payload", { textureIndex = index - 1 })
    end
    local name = readName(reader, nameOffset, nameLength, "texture")
    if byTextureName[name] ~= nil then
      fail("NATIVE_TEX_DUPLICATE_NAME", "two textures share one name: " .. name, { name = name })
    end
    local texture = {
      name = name,
      formatRaw = formatRaw,
      width = width,
      height = height,
      color0Transparent = bit.band(flags, FLAG_COLOR0_TRANSPARENT) ~= 0,
      texels = reader:bytes(texelsOffset, texelsLength),
      indexData = indexLength > 0 and reader:bytes(indexOffset, indexLength) or nil,
    }
    byTextureName[name] = texture
  end

  local byPaletteName = {}
  for index = 1, paletteCount do
    local recordOffset = paletteTableOffset + (index - 1) * PALETTE_RECORD_SIZE
    local nameOffset = reader:u32le(recordOffset)
    local nameLength = reader:u16le(recordOffset + 4)
    local dataOffset = reader:u32le(recordOffset + 8)
    local dataLength = reader:u32le(recordOffset + 12)
    if nameOffset < payloadOffset or dataOffset < payloadOffset then
      fail("NATIVE_TEX_BAD_OFFSET", "palette record points outside the payload", { paletteIndex = index - 1 })
    end
    local name = readName(reader, nameOffset, nameLength, "palette")
    if byPaletteName[name] ~= nil then
      fail("NATIVE_TEX_DUPLICATE_NAME", "two palettes share one name: " .. name, { name = name })
    end
    local palette = { name = name, data = reader:bytes(dataOffset, dataLength) }
    byPaletteName[name] = palette
  end

  return setmetatable({
    textureCount = textureCount,
    paletteCount = paletteCount,
    _textures = byTextureName,
    _palettes = byPaletteName,
  }, Bank),
    nil
end

return NativeTextureBank
