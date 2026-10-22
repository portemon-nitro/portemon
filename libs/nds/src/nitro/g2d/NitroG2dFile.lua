-- Decoder for the common NNS G2D file envelope and byte-swapped block IDs.

local Errors = require("libs.errors.src.Errors")
local BinaryReader = require("libs.codec.src.BinaryReader")

local NitroG2dFile = {}
local HEADER_SIZE = 0x10

---@class NitroG2dFile.Block
---@field magic string
---@field offset integer
---@field size integer
---@field bytes string

---@class NitroG2dFile.Decoded
---@field magic string
---@field version integer
---@field blocks table<string, NitroG2dFile.Block>
---@field source Errors.Context|nil

---@param bytes string
---@param context Errors.Context|nil
---@return NitroG2dFile.Decoded
local function _decode(bytes, context)
  assert(type(bytes) == "string", "NitroG2dFile.decode requires a string")
  local r = BinaryReader.new(bytes, "nitro-g2d")
  if #bytes < HEADER_SIZE then
    error(
      Errors.new("NITRO_G2D_FILE_TOO_SMALL", "G2D file is shorter than its header", { size = #bytes, source = context })
    )
  end

  local fileMagic = string.reverse(r:ascii(0, 4))
  local bom = r:u16le(4)
  local fileSize = r:u32le(8)
  local headerSize = r:u16le(12)
  local blockCount = r:u16le(14)
  if bom ~= 0xFEFF or fileSize ~= #bytes or headerSize < HEADER_SIZE or headerSize > fileSize then
    error(Errors.new("NITRO_G2D_FILE_INVALID_HEADER", "G2D file header fields are inconsistent", {
      bom = bom,
      fileSize = fileSize,
      actualSize = #bytes,
      headerSize = headerSize,
      source = context,
    }))
  end

  local blocks = {}
  local offset = headerSize
  for index = 1, blockCount do
    if offset + 8 > fileSize then
      error(Errors.new("NITRO_G2D_BLOCK_INVALID", "G2D block header exceeds the file", {
        blockIndex = index - 1,
        offset = offset,
        source = context,
      }))
    end
    local magic = string.reverse(r:ascii(offset, 4))
    local size = r:u32le(offset + 4)
    if size < 8 or offset + size > fileSize or blocks[magic] ~= nil then
      error(Errors.new("NITRO_G2D_BLOCK_INVALID", "G2D block is duplicated or exceeds the file", {
        blockIndex = index - 1,
        magic = magic,
        offset = offset,
        size = size,
        source = context,
      }))
    end
    blocks[magic] = {
      magic = magic,
      offset = offset,
      size = size - 8,
      bytes = r:bytes(offset + 8, size - 8),
    }
    offset = offset + size
  end
  if offset ~= fileSize then
    error(
      Errors.new(
        "NITRO_G2D_FILE_INVALID_SIZE",
        "G2D blocks do not fill the declared file",
        { offset = offset, fileSize = fileSize, source = context }
      )
    )
  end
  return { magic = fileMagic, version = r:u16le(6), blocks = blocks, source = context }
end

---@param bytes string
---@param context Errors.Context|nil
---@return NitroG2dFile.Decoded|nil, Errors.Error|nil
function NitroG2dFile.decode(bytes, context)
  ---@type boolean, NitroG2dFile.Decoded|Errors.Error
  local ok, result = pcall(_decode, bytes, context)
  if ok then
    ---@cast result NitroG2dFile.Decoded
    return result
  end
  if Errors.is(result) then
    ---@cast result Errors.Error
    return nil, result
  end
  error(result)
end

return NitroG2dFile
