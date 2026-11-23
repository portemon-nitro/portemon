-- Decodes the ARM9 hidden-item table using the indexed record layout in the
-- retail decomp's script_manager.c::GetHiddenItemParams and hidden_items.h.
-- Record bytes are discovered from the verified retail ARM9 image.

local BinaryReader = require("libs.codec.src.BinaryReader")
local Errors = require("libs.errors.src.Errors")
local OverlayCompression = require("libs.nds.src.rom.OverlayCompression")

local HiddenItemParams = {}

local RECORD_COUNT = 231
local RECORD_SIZE = 8
local TABLE_SIZE = RECORD_COUNT * RECORD_SIZE
local ANCHOR = string.char(17, 0, 1, 0, 0, 0, 0, 0, 92, 0, 1, 0, 0, 0, 1, 0, 92, 0, 1, 0, 0, 0, 225, 0)

---@param code string
---@param message string
---@param version string
---@param sourceOffset integer?
---@param details table<string, string|integer|nil>?
---@return nil, Errors.Error
local function sourceError(code, message, version, sourceOffset, details)
  ---@type table<string, string|integer|nil>
  local context = { version = version, sourceOffset = sourceOffset }
  for key, value in pairs(details or {}) do
    context[key] = value
  end
  return nil, Errors.new(code, message, context)
end

---@param bytes string
---@return integer[]
local function findCandidateOffsets(bytes)
  local offsets = {}
  local searchFrom = 1
  while true do
    local matchStart = string.find(bytes, ANCHOR, searchFrom, true)
    if not matchStart then
      return offsets
    end
    offsets[#offsets + 1] = matchStart - 1
    searchFrom = matchStart + 1
  end
end

---@param reader BinaryReader
---@param sourceOffset integer
---@param version string
---@return table<integer, { itemId: integer, quantity: integer }>?, Errors.Error?
local function decodeCandidate(reader, sourceOffset, version)
  local availableBytes = reader:length() - sourceOffset
  if availableBytes < TABLE_SIZE then
    return sourceError(
      "HIDDEN_ITEM_TABLE_INVALID",
      "hidden-item table is truncated",
      version,
      sourceOffset,
      { requiredBytes = TABLE_SIZE, availableBytes = availableBytes }
    )
  end

  local byIndex = {}
  for rowIndex = 0, RECORD_COUNT - 1 do
    local rowOffset = sourceOffset + rowIndex * RECORD_SIZE
    local itemId = reader:u16le(rowOffset)
    local quantity = reader:u8(rowOffset + 2)
    local unknownByte = reader:u8(rowOffset + 3)
    local unknownWord = reader:u16le(rowOffset + 4)
    local index = reader:u16le(rowOffset + 6)
    if
      itemId == 0
      or quantity == 0
      or unknownByte ~= 0
      or unknownWord ~= 0
      or index >= RECORD_COUNT
      or byIndex[index] ~= nil
    then
      return sourceError(
        "HIDDEN_ITEM_TABLE_INVALID",
        "hidden-item table row is invalid",
        version,
        rowOffset,
        { rowIndex = rowIndex, index = index, itemId = itemId, quantity = quantity }
      )
    end
    byIndex[index] = { itemId = itemId, quantity = quantity }
  end

  if byIndex[0].itemId ~= 17 or byIndex[1].itemId ~= 92 or byIndex[225].itemId ~= 92 or byIndex[230].itemId ~= 53 then
    return sourceError(
      "HIDDEN_ITEM_TABLE_INVALID",
      "hidden-item table does not match the known HGSS source records",
      version,
      sourceOffset
    )
  end
  return byIndex
end

---@class HiddenItemParams
---@field load fun(romFs: RomFs): table<integer, { itemId: integer, quantity: integer }>?, Errors.Error?

---@param romFs RomFs
---@return table<integer, { itemId: integer, quantity: integer }>?, Errors.Error?
function HiddenItemParams.load(romFs)
  assert(type(romFs) == "table" and type(romFs.readArm9) == "function", "load requires a RomFs source")
  assert(type(romFs.version) == "function", "load requires a versioned RomFs source")
  local version = romFs:version()
  assert(type(version) == "string", "RomFs version must be a string")

  local bytes, readErr = romFs:readArm9()
  if not bytes then
    if Errors.is(readErr) then
      return nil, readErr
    end
    if readErr ~= nil then
      error(readErr, 0)
    end
    return sourceError("HIDDEN_ITEM_TABLE_INVALID", "main ARM9 image is unavailable", version)
  end
  if type(bytes) ~= "string" then
    return sourceError("HIDDEN_ITEM_TABLE_INVALID", "main ARM9 read did not return bytes", version)
  end

  local expanded = OverlayCompression.decode(bytes)
  if expanded and #expanded > #bytes then
    bytes = expanded
  end

  local offsets = findCandidateOffsets(bytes)
  if #offsets == 0 then
    return sourceError("HIDDEN_ITEM_TABLE_NOT_FOUND", "hidden-item table anchor was not found", version)
  end
  if #offsets > 1 then
    return sourceError(
      "HIDDEN_ITEM_TABLE_AMBIGUOUS",
      "multiple hidden-item table anchors were found",
      version,
      offsets[1],
      { secondOffset = offsets[2], matchCount = #offsets }
    )
  end

  return decodeCandidate(BinaryReader.new(bytes, "HGSS main ARM9"), offsets[1], version)
end

return HiddenItemParams
