-- Parses a Nintendo DS cartridge container over a borrowed byte source. Header,
-- FAT, FNT, and overlay layout follows GBATEK's DS cartridge references.
-- Generic header, FAT, FNT, and overlay structure lives here; ROM identity and
-- project-specific dump mapping remain in the producer package.

local Errors = require("libs.errors.src.Errors")
local BinaryReader = require("libs.codec.src.BinaryReader")
local NitroFs = require("libs.nds.src.rom.NitroFs")
local OverlayTable = require("libs.nds.src.rom.OverlayTable")
local bit = require("bit")

---@class Cartridge
---@field private _source table<string, unknown>
---@field private _header table<string, unknown>
---@field private _fat table<integer, table<string, unknown>>
---@field private _fatCount integer
---@field private _nitro table<string, unknown>
---@field private _arm9Overlays table[]
---@field private _arm7Overlays table[]
local Cartridge = {}
Cartridge.__index = Cartridge

local MIN_HEADER = 0x200
local BANNER_BLOCK_SIZE = 0x240
local BANNER_BITMAP_OFFSET = 0x20
local BANNER_PALETTE_OFFSET = 0x220
local BANNER_PALETTE_SIZE = 32

local function parseHeader(reader)
  local function region(off)
    return { offset = reader:u32le(off), size = reader:u32le(off + 4) }
  end
  return {
    title = reader:ascii(0x00, 12, true),
    gameCode = reader:ascii(0x0C, 4),
    makerCode = reader:ascii(0x10, 2),
    unitCode = reader:u8(0x12),
    deviceCapacity = reader:u8(0x14),
    romVersion = reader:u8(0x1E),
    flags = reader:u8(0x1F),
    arm9 = {
      offset = reader:u32le(0x20),
      entryAddress = reader:u32le(0x24),
      ramAddress = reader:u32le(0x28),
      size = reader:u32le(0x2C),
    },
    arm7 = {
      offset = reader:u32le(0x30),
      entryAddress = reader:u32le(0x34),
      ramAddress = reader:u32le(0x38),
      size = reader:u32le(0x3C),
    },
    fnt = region(0x40),
    fat = region(0x48),
    arm9Overlays = region(0x50),
    arm7Overlays = region(0x58),
    bannerOffset = reader:u32le(0x68),
    usedRomSize = reader:u32le(0x80),
    headerSize = reader:u32le(0x84),
  }
end

local function assertInRomSize(name, offset, size, romSize)
  if offset < 0 or size < 0 or offset + size > romSize then
    Errors.raise(
      "NDS_SECTION_OUT_OF_RANGE",
      name .. " region (offset " .. offset .. ", size " .. size .. ") exceeds ROM of " .. romSize,
      { section = name, offset = offset, size = size, romSize = romSize }
    )
  end
end

local function readOrRaise(source, offset, length, name)
  local bytes, err = source:read(offset, length)
  if not bytes then
    Errors.raise("NDS_READ_FAILED", name .. ": " .. Errors.format(err), { section = name })
  end
  return bytes
end

local function parseFat(source, fatOffset, fatSize, romSize)
  local bytes = readOrRaise(source, fatOffset, fatSize, "fat")
  local reader = BinaryReader.new(bytes, "fat")
  local count = fatSize / 8
  local fat = {}
  for fileId = 0, count - 1 do
    local base = fileId * 8
    local startOffset = reader:u32le(base)
    local endOffset = reader:u32le(base + 4)
    if startOffset > endOffset then
      Errors.raise(
        "FAT_ENTRY_INVALID",
        "FAT entry " .. fileId .. " has start past end",
        { fileId = fileId, startOffset = startOffset, endOffset = endOffset }
      )
    end
    if endOffset > romSize then
      Errors.raise(
        "FAT_RANGE_OUT_OF_BOUNDS",
        "FAT entry " .. fileId .. " ends past the ROM",
        { fileId = fileId, startOffset = startOffset, endOffset = endOffset, romSize = romSize }
      )
    end
    fat[fileId] = { startOffset = startOffset, endOffset = endOffset, size = endOffset - startOffset }
  end
  return fat, count
end

---@param source table<string, unknown> with size() and read(offset, length) methods
---@param header table<string, unknown>? pre-read generic cartridge header
---@return string? rgbaBytes
---@return Errors.Error?
function Cartridge.readBannerIcon(source, header)
  assert(source and type(source.size) == "function" and type(source.read) == "function", "Cartridge source is invalid")
  local resolvedHeader = header
  if resolvedHeader == nil then
    local headerOk, result = pcall(Cartridge.readHeader, source)
    if not headerOk then
      if Errors.is(result) then
        return nil, result
      end
      error(result, 0)
    end
    resolvedHeader = result
  end
  local bannerOffset = resolvedHeader.bannerOffset
  if bannerOffset == 0 then
    return nil,
      Errors.new("NDS_BANNER_MISSING", "cartridge has no static banner", {
        bannerOffset = bannerOffset,
      })
  end
  local romSize = source:size()
  if bannerOffset < 0 or bannerOffset + BANNER_BLOCK_SIZE > romSize then
    return nil,
      Errors.new("NDS_BANNER_OUT_OF_RANGE", "static banner exceeds the ROM", {
        bannerOffset = bannerOffset,
        size = BANNER_BLOCK_SIZE,
        romSize = romSize,
      })
  end
  local block, readError = source:read(bannerOffset, BANNER_BLOCK_SIZE)
  if block == nil then
    return nil,
      Errors.new("NDS_BANNER_READ_FAILED", "static banner could not be read", {
        bannerOffset = bannerOffset,
        cause = Errors.format(readError),
      })
  end
  if #block ~= BANNER_BLOCK_SIZE then
    return nil,
      Errors.new("NDS_BANNER_TRUNCATED", "static banner read was incomplete", {
        bannerOffset = bannerOffset,
        expectedSize = BANNER_BLOCK_SIZE,
        actualSize = #block,
      })
  end

  local reader = BinaryReader.new(block, "banner")
  local palette = {}
  for index = 0, BANNER_PALETTE_SIZE / 2 - 1 do
    local color = reader:u16le(BANNER_PALETTE_OFFSET + index * 2)
    local red = bit.band(color, 0x1F)
    local green = bit.band(bit.rshift(color, 5), 0x1F)
    local blue = bit.band(bit.rshift(color, 10), 0x1F)
    palette[index] = {
      red = bit.lshift(red, 3) + bit.rshift(red, 2),
      green = bit.lshift(green, 3) + bit.rshift(green, 2),
      blue = bit.lshift(blue, 3) + bit.rshift(blue, 2),
    }
  end

  local rgba = {}
  for y = 0, 31 do
    for x = 0, 31 do
      local tile = math.floor(y / 8) * 4 + math.floor(x / 8)
      local byteOffset = BANNER_BITMAP_OFFSET + tile * 32 + (y % 8) * 4 + math.floor((x % 8) / 2)
      local packed = reader:u8(byteOffset)
      local index = x % 2 == 0 and bit.band(packed, 0x0F) or bit.rshift(packed, 4)
      if index == 0 then
        rgba[#rgba + 1] = "\0\0\0\0"
      else
        local color = palette[index]
        rgba[#rgba + 1] = string.char(color.red, color.green, color.blue, 255)
      end
    end
  end
  return table.concat(rgba)
end

---@param source table<string, unknown> with size() and read(offset, length) methods
---@return table<string, unknown> header
function Cartridge.readHeader(source)
  assert(source and type(source.size) == "function" and type(source.read) == "function", "Cartridge source is invalid")
  local romSize = source:size()
  if romSize < MIN_HEADER then
    Errors.raise("NDS_TOO_SMALL", "ROM is " .. romSize .. " bytes, need at least " .. MIN_HEADER, { size = romSize })
  end
  return parseHeader(BinaryReader.new(readOrRaise(source, 0, MIN_HEADER, "header"), "header"))
end

---@param source table<string, unknown> with size() and read(offset, length) methods
---@param header table<string, unknown>? pre-read generic cartridge header
---@return Cartridge
function Cartridge.parse(source, header)
  assert(source and type(source.size) == "function" and type(source.read) == "function", "Cartridge source is invalid")
  local romSize = source:size()
  header = header or Cartridge.readHeader(source)
  assertInRomSize("arm9", header.arm9.offset, header.arm9.size, romSize)
  assertInRomSize("arm7", header.arm7.offset, header.arm7.size, romSize)
  assertInRomSize("fnt", header.fnt.offset, header.fnt.size, romSize)
  assertInRomSize("fat", header.fat.offset, header.fat.size, romSize)
  assertInRomSize("arm9Overlays", header.arm9Overlays.offset, header.arm9Overlays.size, romSize)
  assertInRomSize("arm7Overlays", header.arm7Overlays.offset, header.arm7Overlays.size, romSize)

  if header.fat.size == 0 or header.fat.size % 8 ~= 0 then
    Errors.raise(
      "NDS_FAT_SIZE_INVALID",
      "FAT size " .. header.fat.size .. " must be nonzero and divisible by 8",
      { fatSize = header.fat.size }
    )
  end

  local fat, fatCount = parseFat(source, header.fat.offset, header.fat.size, romSize)
  local nitro = NitroFs.parse(readOrRaise(source, header.fnt.offset, header.fnt.size, "fnt"), fatCount)
  local arm9Overlays = OverlayTable.parse(
    readOrRaise(source, header.arm9Overlays.offset, header.arm9Overlays.size, "arm9Overlays"),
    fatCount,
    "arm9"
  )
  local arm7Overlays = OverlayTable.parse(
    readOrRaise(source, header.arm7Overlays.offset, header.arm7Overlays.size, "arm7Overlays"),
    fatCount,
    "arm7"
  )

  return setmetatable({
    _source = source,
    _header = header,
    _fat = fat,
    _fatCount = fatCount,
    _nitro = nitro,
    _arm9Overlays = arm9Overlays,
    _arm7Overlays = arm7Overlays,
  }, Cartridge)
end

function Cartridge:size()
  return self._source:size()
end

function Cartridge:header()
  return self._header
end

function Cartridge:nitroFs()
  return self._nitro
end

function Cartridge:arm9Overlays()
  return self._arm9Overlays
end

function Cartridge:arm7Overlays()
  return self._arm7Overlays
end

function Cartridge:fatCount()
  return self._fatCount
end

function Cartridge:read(offset, length)
  return self._source:read(offset, length)
end

function Cartridge:fatFileInfo(fileId)
  local entry = self._fat[fileId]
  if not entry then
    Errors.raise(
      "NDS_FILE_ID_OUT_OF_RANGE",
      "no FAT entry for fileId " .. tostring(fileId),
      { fileId = fileId, fatCount = self._fatCount }
    )
  end
  return { startOffset = entry.startOffset, endOffset = entry.endOffset, size = entry.size }
end

function Cartridge:readFatFile(fileId)
  local entry = self:fatFileInfo(fileId)
  return readOrRaise(self._source, entry.startOffset, entry.size, "fat file " .. fileId)
end

return Cartridge
