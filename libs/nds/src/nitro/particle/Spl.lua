-- Decoder for JN SPL APS particle-definition members.

local Spl = {}

local Errors = require("libs.errors.src.Errors")
local BinaryReader = require("libs.codec.src.BinaryReader")

local HEADER_SIZE = 0x20
local EMITTER_SIZE = 0x58
local RESOURCE_HEADER_SIZE = 0x20
local SECTION_BITS = {
  { bit = 8, role = "scale", size = 0x0c },
  { bit = 9, role = "color", size = 0x0c },
  { bit = 10, role = "alpha", size = 0x08 },
  { bit = 11, role = "texture", size = 0x0c },
  { bit = 16, role = "child", size = 0x14 },
}
local CALCULATION_BITS = {
  { bit = 24, role = "gravity", size = 0x08 },
  { bit = 25, role = "random", size = 0x08 },
  { bit = 26, role = "magnet", size = 0x10 },
  { bit = 27, role = "spin", size = 0x04 },
  { bit = 28, role = "scfield", size = 0x08 },
  { bit = 29, role = "convergence", size = 0x10 },
}

local function hasBit(value, bit)
  return math.floor(value / 2 ^ bit) % 2 == 1
end

local function invalid(message, fields)
  error(Errors.new("NITRO_SPL_INVALID", message, fields))
end

local function checkedBytes(reader, offset, length, label)
  if offset < 0 or length < 0 or offset + length > reader:length() then
    invalid("APS section exceeds the source member", { offset = offset, length = length, label = label })
  end
  return reader:bytes(offset, length)
end

---@class NitroSplSection
---@field role string
---@field data string source-independent section bytes

---@class NitroSplEmitter
---@field flags integer
---@field baseRecord string
---@field sections NitroSplSection[]
---@field calculations NitroSplSection[]

---@class NitroSplResource
---@field flags integer
---@field texture string|nil embedded texture bytes, when not shared
---@field textureReference integer|nil zero-based resource index when shared
---@field palette string|nil embedded palette bytes

---@class NitroSplData
---@field format "APS12_1"
---@field emitters NitroSplEmitter[]
---@field resources NitroSplResource[]
---@field source Errors.Context|nil

---@param bytes string
---@param context Errors.Context|nil
---@return NitroSplData|nil, Errors.Error|nil
local function _decode(bytes, context)
  assert(type(bytes) == "string", "Spl.decode requires a string")
  local reader = BinaryReader.new(bytes, "nitro-spl")
  if reader:length() < HEADER_SIZE or reader:ascii(0, 8) ~= " APS12_1" then
    invalid("APS header is missing or truncated", { size = reader:length(), source = context })
  end

  local emitterCount = reader:u16le(8)
  local resourceCount = reader:u16le(10)
  local offset = HEADER_SIZE
  local emitters = {}
  for emitterIndex = 1, emitterCount do
    local baseRecord = checkedBytes(reader, offset, EMITTER_SIZE, "emitter base record")
    local flags = reader:u32le(offset)
    offset = offset + EMITTER_SIZE
    local sections = {}
    for _, definition in ipairs(SECTION_BITS) do
      if hasBit(flags, definition.bit) then
        sections[#sections + 1] = {
          role = definition.role,
          data = checkedBytes(reader, offset, definition.size, definition.role .. " emitter section"),
        }
        offset = offset + definition.size
      end
    end
    local calculations = {}
    for _, definition in ipairs(CALCULATION_BITS) do
      if hasBit(flags, definition.bit) then
        calculations[#calculations + 1] = {
          role = definition.role,
          data = checkedBytes(reader, offset, definition.size, definition.role .. " calculation data"),
        }
        offset = offset + definition.size
      end
    end
    emitters[emitterIndex] = {
      flags = flags,
      baseRecord = baseRecord,
      sections = sections,
      calculations = calculations,
    }
  end

  local resources = {}
  for resourceIndex = 1, resourceCount do
    checkedBytes(reader, offset, RESOURCE_HEADER_SIZE, "resource descriptor")
    local flags = reader:u32le(offset + 4)
    local textureSize = reader:u32le(offset + 8)
    local paletteOffset = reader:u32le(offset + 12)
    local paletteSize = reader:u32le(offset + 16)
    local resourceSize = reader:u32le(offset + 28)
    if resourceSize < RESOURCE_HEADER_SIZE then
      invalid("APS resource span is shorter than its descriptor", {
        resourceIndex = resourceIndex - 1,
        resourceSize = resourceSize,
        source = context,
      })
    end
    checkedBytes(reader, offset, resourceSize, "resource entry")

    local resource = { flags = flags }
    if hasBit(flags, 17) then
      local textureReference = math.floor(flags / 2 ^ 18) % 256
      if textureReference >= resourceIndex - 1 then
        invalid("APS texture reference does not point to an earlier resource", {
          resourceIndex = resourceIndex - 1,
          textureReference = textureReference,
          source = context,
        })
      end
      resource.textureReference = textureReference
    elseif textureSize > 0 then
      if textureSize > resourceSize - RESOURCE_HEADER_SIZE then
        invalid("APS texture payload exceeds its resource record", {
          resourceIndex = resourceIndex - 1,
          offset = offset,
          textureSize = textureSize,
          resourceSize = resourceSize,
          source = context,
        })
      end
      resource.texture = checkedBytes(
        reader,
        offset + RESOURCE_HEADER_SIZE,
        textureSize,
        "embedded texture record "
          .. resourceIndex
          .. " flags "
          .. flags
          .. " textureSize "
          .. textureSize
          .. " paletteOffset "
          .. paletteOffset
          .. " paletteSize "
          .. paletteSize
          .. " resourceSize "
          .. resourceSize
      )
    end
    if paletteSize > 0 then
      if paletteOffset < RESOURCE_HEADER_SIZE or paletteOffset + paletteSize > resourceSize then
        invalid("APS palette offset overlaps its descriptor", {
          resourceIndex = resourceIndex - 1,
          offset = offset,
          paletteOffset = paletteOffset,
          paletteSize = paletteSize,
          resourceSize = resourceSize,
          source = context,
        })
      end
      resource.palette = checkedBytes(reader, offset + paletteOffset, paletteSize, "embedded palette")
    end
    resources[resourceIndex] = resource
    offset = offset + resourceSize
  end

  return { format = "APS12_1", emitters = emitters, resources = resources, source = context }
end

function Spl.decode(bytes, context)
  ---@type boolean, NitroSplData|Errors.Error|nil
  local ok, result = pcall(_decode, bytes, context)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result)
end

return Spl
