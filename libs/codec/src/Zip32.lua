-- Pure IEEE CRC-32 and Zip32 record encoding for first-party archive writers.
-- Filesystem, compression, trust, and publication policy stay with callers.

local bit = require("bit")

local Zip32 = {}

local MAX_NAME_BYTES = 0xFFFF
local MAX_RECORD_BYTES = 0xFFFFFFFF
local METHOD_STORE = 0
local METHOD_DEFLATE = 8
local FLAG_UTF8 = 0x0800
local VERSION_NEEDED = 20
local DOS_TIME = 0
local DOS_DATE = 0x0021

local LOCAL_SIGNATURE = 0x04034B50
local CENTRAL_SIGNATURE = 0x02014B50
local EOCD_SIGNATURE = 0x06054B50

---@class Zip32.Row
---@field path string
---@field uncompressedSize integer
---@field unsignedCrc32 integer
---@field method integer
---@field compressedSize integer
---@field offset integer

---@param value integer
---@return string
local function u16(value)
  assert(type(value) == "number" and value >= 0 and value <= 0xFFFF and value % 1 == 0, "zip u16 field out of range")
  return string.char(value % 256, math.floor(value / 256) % 256)
end

---@param value integer
---@return string
local function u32(value)
  assert(
    type(value) == "number" and value >= 0 and value <= MAX_RECORD_BYTES and value % 1 == 0,
    "zip u32 field out of range"
  )
  local fourth = math.floor(value / 16777216)
  assert(fourth <= 255, "zip u32 field out of range")
  return string.char(value % 256, math.floor(value / 256) % 256, math.floor(value / 65536) % 256, fourth)
end

-- LuaJIT's bit library answers signed 32-bit values; ZIP/CRC fields carry the
-- unsigned number.
---@param value integer
---@return integer
local function unsigned32(value)
  return bit.band(value, 0xFFFFFFFF) % 0x100000000
end

local CRC_TABLE

---@return integer[]
local function crcTable()
  if CRC_TABLE == nil then
    local table_ = {}
    for index = 0, 255 do
      local value = index
      for _ = 1, 8 do
        local mask = -bit.band(value, 1)
        value = bit.bxor(bit.rshift(value, 1), bit.band(0xEDB88320, mask))
      end
      table_[index] = value
    end
    CRC_TABLE = table_
  end
  return CRC_TABLE
end

---@param view BinaryView
---@return integer unsignedCrc32
function Zip32.crc32(view)
  assert(type(view) == "table" and type(view.u8) == "function", "zip CRC requires a BinaryView")
  local table_ = crcTable()
  local value = 0xFFFFFFFF
  for offset = 0, view:length() - 1 do
    local slot = bit.band(bit.bxor(value, view:u8(offset)), 0xFF)
    value = bit.bxor(bit.rshift(value, 8), table_[slot])
  end
  return unsigned32(bit.bnot(value))
end

---@param row Zip32.Row
local function validateRow(row)
  assert(type(row) == "table", "zip row must be a record")
  assert(type(row.path) == "string" and row.path ~= "", "zip row path is required")
  assert(not row.path:find("\0", 1, true) and not row.path:find("\\", 1, true), "zip row path is not canonical")
  assert(#row.path <= MAX_NAME_BYTES, "zip row path exceeds the name field")
  assert(row.method == METHOD_STORE or row.method == METHOD_DEFLATE, "zip row method is unsupported")
  for _, field in ipairs({ "uncompressedSize", "unsignedCrc32", "compressedSize", "offset" }) do
    local value = row[field]
    assert(
      type(value) == "number" and value >= 0 and value <= MAX_RECORD_BYTES and value % 1 == 0,
      "zip row " .. field .. " is out of range"
    )
  end
end

---@param row Zip32.Row
---@return string
function Zip32.localHeader(row)
  validateRow(row)
  return table.concat({
    u32(LOCAL_SIGNATURE),
    u16(VERSION_NEEDED),
    u16(FLAG_UTF8),
    u16(row.method),
    u16(DOS_TIME),
    u16(DOS_DATE),
    u32(row.unsignedCrc32),
    u32(row.compressedSize),
    u32(row.uncompressedSize),
    u16(#row.path),
    u16(0),
    row.path,
  })
end

---@param row Zip32.Row
---@return string
function Zip32.centralRecord(row)
  validateRow(row)
  return table.concat({
    u32(CENTRAL_SIGNATURE),
    u16(VERSION_NEEDED),
    u16(VERSION_NEEDED),
    u16(FLAG_UTF8),
    u16(row.method),
    u16(DOS_TIME),
    u16(DOS_DATE),
    u32(row.unsignedCrc32),
    u32(row.compressedSize),
    u32(row.uncompressedSize),
    u16(#row.path),
    u16(0),
    u16(0),
    u16(0),
    u16(0),
    u32(0),
    u32(row.offset),
    row.path,
  })
end

---@param entryCount integer
---@param directorySize integer
---@param directoryOffset integer
---@return string
function Zip32.endRecord(entryCount, directorySize, directoryOffset)
  return table.concat({
    u32(EOCD_SIGNATURE),
    u16(0),
    u16(0),
    u16(entryCount),
    u16(entryCount),
    u32(directorySize),
    u32(directoryOffset),
    u16(0),
  })
end

return Zip32
