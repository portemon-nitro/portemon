-- Decoder for NNS G2D NMCR/MCBK multi-cell banks, following the HGSS NMC unpacker.

local Errors = require("libs.errors.src.Errors")
local BinaryReader = require("libs.codec.src.BinaryReader")
local NitroG2dFile = require("libs.nds.src.nitro.g2d.NitroG2dFile")

local MultiCell = {}

---@class NitroG2d.MultiCellCell
---@field count integer
---@field attributes integer
---@field dataOffset integer offset relative to the MCBK payload
---@field data string

---@class NitroG2d.MultiCellData
---@field format "NMCR"
---@field cellCount integer
---@field cells NitroG2d.MultiCellCell[]
---@field extendedDataOffset integer
---@field source Errors.Context|nil

---@param bytes string
---@param context Errors.Context|nil
---@return NitroG2d.MultiCellData
local function _decode(bytes, context)
  local file, fileError = NitroG2dFile.decode(bytes, context)
  if file == nil then
    error(fileError)
  end
  if file.magic ~= "NMCR" then
    error(
      Errors.new(
        "NITRO_G2D_MAGIC_INVALID",
        "multi-cell data requires an NMCR file",
        { magic = file.magic, source = context }
      )
    )
  end
  local block = file.blocks.MCBK
  if block == nil then
    error(Errors.new("NITRO_G2D_BANK_MISSING", "NMCR file has no MCBK block", { source = context }))
  end

  local r = BinaryReader.new(block.bytes, "nitro-g2d-multicell")
  if #block.bytes < 20 then
    error(
      Errors.new(
        "NITRO_G2D_BANK_INVALID",
        "MCBK block is shorter than its header",
        { size = #block.bytes, source = context }
      )
    )
  end
  local cellCount = r:u16le(0)
  local cellsOffset = r:u32le(4)
  local dataOffset = r:u32le(8)
  local extendedOffset = r:u32le(16)
  if cellsOffset + cellCount * 8 > #block.bytes or dataOffset > #block.bytes then
    error(Errors.new("NITRO_G2D_BANK_INVALID", "MCBK cell table or data bank exceeds the block", {
      cellCount = cellCount,
      cellsOffset = cellsOffset,
      dataOffset = dataOffset,
      size = #block.bytes,
      source = context,
    }))
  end
  if extendedOffset ~= 0 and extendedOffset >= #block.bytes then
    error(
      Errors.new(
        "NITRO_G2D_BANK_INVALID",
        "MCBK extended data offset exceeds the block",
        { extendedOffset = extendedOffset, size = #block.bytes, source = context }
      )
    )
  end

  local cells = {}
  for index = 0, cellCount - 1 do
    local entryOffset = cellsOffset + index * 8
    local count = r:u16le(entryOffset)
    local attributes = r:u16le(entryOffset + 2)
    local relativeDataOffset = r:u32le(entryOffset + 4)
    local cellDataOffset = dataOffset + relativeDataOffset
    if cellDataOffset >= #block.bytes then
      error(
        Errors.new(
          "NITRO_G2D_BANK_INVALID",
          "MCBK cell data offset exceeds the block",
          { cellIndex = index, cellDataOffset = cellDataOffset, size = #block.bytes, source = context }
        )
      )
    end
    cells[#cells + 1] = {
      count = count,
      attributes = attributes,
      dataOffset = cellDataOffset,
      data = r:bytes(cellDataOffset, #block.bytes - cellDataOffset),
    }
  end
  return { format = "NMCR", cellCount = cellCount, cells = cells, extendedDataOffset = extendedOffset, source = context }
end

---@param bytes string
---@param context Errors.Context|nil
---@return NitroG2d.MultiCellData|nil, Errors.Error|nil
function MultiCell.decode(bytes, context)
  ---@type boolean, NitroG2d.MultiCellData|Errors.Error
  local ok, result = pcall(_decode, bytes, context)
  if ok then
    ---@cast result NitroG2d.MultiCellData
    return result
  end
  if Errors.is(result) then
    ---@cast result Errors.Error
    return nil, result
  end
  error(result)
end

return MultiCell
