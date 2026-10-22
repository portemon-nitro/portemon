-- Decoder for the NNS G2D ANBK animation bank used by multi-cell resources.

local Errors = require("libs.errors.src.Errors")
local BinaryReader = require("libs.codec.src.BinaryReader")
local NitroG2dFile = require("libs.nds.src.nitro.g2d.NitroG2dFile")

local MultiCellAnimation = {}

---@class NitroG2d.MultiCellAnimationFrame
---@field dataOffset integer offset relative to the ABNK payload
---@field duration integer

---@class NitroG2d.MultiCellAnimationSequence
---@field frameCount integer
---@field loopStart integer
---@field animationType integer
---@field playMode integer
---@field frames NitroG2d.MultiCellAnimationFrame[]

---@class NitroG2d.MultiCellAnimationData
---@field format "NANR"
---@field animationCount integer
---@field frameCount integer
---@field animations NitroG2d.MultiCellAnimationSequence[]
---@field source Errors.Context|nil

---@param bytes string
---@param context Errors.Context|nil
---@return NitroG2d.MultiCellAnimationData
local function _decode(bytes, context)
  local file, fileError = NitroG2dFile.decode(bytes, context)
  if file == nil then
    error(fileError)
  end
  if file.magic ~= "NANR" then
    error(
      Errors.new(
        "NITRO_G2D_MAGIC_INVALID",
        "multi-cell animation data requires a NANR file",
        { magic = file.magic, source = context }
      )
    )
  end
  local block = file.blocks.ABNK
  if block == nil then
    error(Errors.new("NITRO_G2D_BANK_MISSING", "NANR file has no ABNK block", { source = context }))
  end
  local r = BinaryReader.new(block.bytes, "nitro-g2d-multianimation")
  if #block.bytes < 0x18 then
    error(
      Errors.new(
        "NITRO_G2D_BANK_INVALID",
        "ABNK block is shorter than its header",
        { size = #block.bytes, source = context }
      )
    )
  end
  local animationCount = r:u16le(0)
  local frameCount = r:u16le(2)
  local animationsOffset = r:u32le(4)
  local framesOffset = r:u32le(8)
  local frameDataOffset = r:u32le(12)
  if animationsOffset + animationCount * 16 > #block.bytes or framesOffset + frameCount * 8 > #block.bytes then
    error(Errors.new("NITRO_G2D_BANK_INVALID", "ABNK animation or frame table exceeds the block", {
      animationCount = animationCount,
      frameCount = frameCount,
      animationsOffset = animationsOffset,
      framesOffset = framesOffset,
      size = #block.bytes,
      source = context,
    }))
  end
  local animations = {}
  for index = 0, animationCount - 1 do
    local offset = animationsOffset + index * 16
    local count = r:u16le(offset)
    local loopStart = r:u16le(offset + 2)
    local animationType = r:u32le(offset + 4)
    local playMode = r:u32le(offset + 8)
    local relativeFramesOffset = r:u32le(offset + 12)
    local firstFrame = framesOffset + relativeFramesOffset
    if count == 0 or loopStart >= count or firstFrame + count * 8 > #block.bytes then
      error(Errors.new("NITRO_G2D_BANK_INVALID", "ABNK animation frame range is invalid", {
        animationIndex = index,
        count = count,
        loopStart = loopStart,
        firstFrame = firstFrame,
        size = #block.bytes,
        source = context,
      }))
    end
    local frames = {}
    for frameIndex = 0, count - 1 do
      local frameOffset = firstFrame + frameIndex * 8
      local relativeDataOffset = r:u32le(frameOffset)
      local data = frameDataOffset + relativeDataOffset
      if data >= #block.bytes then
        error(Errors.new("NITRO_G2D_BANK_INVALID", "ABNK frame data offset exceeds the block", {
          animationIndex = index,
          frameIndex = frameIndex,
          dataOffset = data,
          size = #block.bytes,
          source = context,
        }))
      end
      frames[#frames + 1] = { dataOffset = data, duration = r:u16le(frameOffset + 4) }
    end
    animations[#animations + 1] = {
      frameCount = count,
      loopStart = loopStart,
      animationType = animationType,
      playMode = playMode,
      frames = frames,
    }
  end
  return {
    format = "NANR",
    animationCount = animationCount,
    frameCount = frameCount,
    animations = animations,
    source = context,
  }
end

---@param bytes string
---@param context Errors.Context|nil
---@return NitroG2d.MultiCellAnimationData|nil, Errors.Error|nil
function MultiCellAnimation.decode(bytes, context)
  ---@type boolean, NitroG2d.MultiCellAnimationData|Errors.Error
  local ok, result = pcall(_decode, bytes, context)
  if ok then
    ---@cast result NitroG2d.MultiCellAnimationData
    return result
  end
  if Errors.is(result) then
    ---@cast result Errors.Error
    return nil, result
  end
  error(result)
end

return MultiCellAnimation
