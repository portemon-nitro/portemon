-- Strict byte decoder for the retail SPL particle resource file behind the
-- HGSS opening movie's starter effects (NARC_a_0_5_9 member 4). The layout
-- follows the retail SPL library (SplFileHeader, SPLResBase and its optional
-- scale/color/alpha/texture/child and field blocks, then the texture
-- blocks): a 0x20-byte header naming the emitter and texture counts, one
-- emitter record after another, then the texture payloads. Only structural
-- decoding happens here; emitter-to-starter assignment and runtime
-- vocabulary stay with the opening-particle compiler. This module never
-- allocates graphics objects and never simulates particles.

local Errors = require("libs.errors.src.Errors")
local BinaryReader = require("libs.codec.src.BinaryReader")

local SplResource = {}

SplResource.ERROR = { SOURCE_INVALID = "SPL_SOURCE_INVALID" }

local HEADER_SIZE = 0x20
-- Optional animation block sizes in resource order (scale, color, alpha).
local BASE_SIZE = 88
local SCL_ANM_SIZE = 12
local CLR_ANM_SIZE = 12
local ALP_ANM_SIZE = 8
local TEX_ANM_SIZE = 12
local CHILD_SIZE = 20

-- Field parameter blocks in the resource after the base/animation/child
-- blocks, in this order, when the base flag enables them. Sizes follow the
-- retail SPL field structs (see spl_internal.h in the retail library).
local FIELD_SIZES = {
  gravity = 8,
  random = 8,
  magnet = 16,
  spin = 4,
  collision = 8,
  convergence = 16,
}

-- Collision response codes: the first two responses act, higher values
-- are defined no-ops normalizing to none.

local MAGIC = " APS12_1"

---@param message string
---@param context table<string, unknown>|nil
---@noreturn
local function sourceError(message, context)
  Errors.raise(SplResource.ERROR.SOURCE_INVALID, message, context or {})
end

---@param reader BinaryReader
---@param offset integer zero-based offset of the flag word
---@return integer
local function flagAt(reader, offset)
  return reader:u32le(offset)
end

---@param flag integer
---@param bit integer
---@return boolean
local function hasBit(flag, bit)
  return math.floor(flag / (2 ^ bit)) % 2 == 1
end

-- Bits the structural walk decodes into normalized records. Formerly
-- unsupported entries (random loop phase, random/collision fields, fixed
-- polygon identities) are valid source behavior and decode below instead
-- of failing the resource.
local UNSUPPORTED_BITS = {}

local SUPPORTED_FIELD_BITS = {
  [24] = "gravity",
  [25] = "random",
  [26] = "magnet",
  [27] = "spin",
  [28] = "collision",
  [29] = "convergence",
}

---@param reader BinaryReader
---@param offset integer zero-based offset of the child block
---@param emitterId integer
---@return table<string, unknown> normalized child record
local function decodeChild(reader, offset, emitterId)
  local length = reader:length()
  if offset + CHILD_SIZE > length then
    sourceError("SPL emitter child block exceeds its resource", { emitter = emitterId, offset = offset })
  end
  local flag = reader:u16le(offset)
  -- Only the undefined child flag vocabulary fails: reserved bits 12-15
  -- would change spawn, animation, or draw behavior the structural walk
  -- cannot see. Every other documented bit normalizes below.
  if math.floor(flag / 4096) % 16 ~= 0 then
    sourceError("SPL emitter uses an unsupported child feature", {
      emitter = emitterId,
      flag = flag,
      offset = offset,
    })
  end
  local function childBit(bit)
    return math.floor(flag / (2 ^ bit)) % 2 == 1
  end
  local color = reader:u16le(offset + 10)
  local gen = reader:u32le(offset + 12)
  local tex = reader:u32le(offset + 16)
  local function toS16(value)
    if value >= 32768 then
      return value - 65536
    end
    return value
  end
  return {
    offset = offset,
    flag = flag,
    initVelMagRndm = toS16(reader:u16le(offset + 2)) / 4096,
    scaleEnd = toS16(reader:u16le(offset + 4)) / 4096,
    life = reader:u16le(offset + 6),
    velRatio = reader:u8(offset + 8),
    sclRatio = reader:u8(offset + 9),
    colorRgb = {
      r = color % 32,
      g = math.floor(color / 32) % 32,
      b = math.floor(color / 1024) % 32,
    },
    genNum = gen % 256,
    genStart = math.floor(gen / 256) % 256,
    genInterval = math.floor(gen / 65536) % 256,
    texNo = math.floor(gen / 16777216) % 256,
    texRepeatS = tex % 4,
    texRepeatT = math.floor(tex / 4) % 4,
    reverseS = math.floor(tex / 16) % 2 == 1,
    reverseT = math.floor(tex / 32) % 2 == 1,
    dpolCenter = math.floor(tex / 64) % 2 == 1,
    affectFields = childBit(0),
    polygonRotationAxis = math.floor(flag / 512) % 4,
    polygonPlane = math.floor(flag / 2048) % 2,
  }
end

---@param reader BinaryReader
---@param baseOffset integer zero-based offset of the emitter base record
---@param emitterId integer
---@return table<string, unknown> normalized emitter record
---@return integer nextOffset zero-based offset past the emitter record
local function decodeEmitter(reader, baseOffset, emitterId)
  local length = reader:length()
  if baseOffset + BASE_SIZE > length then
    sourceError("SPL emitter record exceeds its resource", { emitter = emitterId, offset = baseOffset })
  end
  local flag = flagAt(reader, baseOffset)
  for bit, name in pairs(UNSUPPORTED_BITS) do
    if hasBit(flag, bit) then
      sourceError("SPL emitter uses an unsupported particle feature", {
        emitter = emitterId,
        flag = name,
        offset = baseOffset,
      })
    end
  end
  local cursor = baseOffset + BASE_SIZE
  local function take(size, role)
    if cursor + size > length then
      sourceError("SPL emitter " .. role .. " block exceeds its resource", {
        emitter = emitterId,
        offset = cursor,
      })
    end
    local offset = cursor
    cursor = cursor + size
    return offset
  end
  local blocks = {}
  if hasBit(flag, 8) then
    blocks.scaleOffset = take(SCL_ANM_SIZE, "scale")
  end
  if hasBit(flag, 9) then
    blocks.colorOffset = take(CLR_ANM_SIZE, "color")
  end
  if hasBit(flag, 10) then
    blocks.alphaOffset = take(ALP_ANM_SIZE, "alpha")
  end
  if hasBit(flag, 11) then
    blocks.textureAnimOffset = take(TEX_ANM_SIZE, "texture animation")
  end
  if hasBit(flag, 16) then
    blocks.childOffset = take(CHILD_SIZE, "child")
  end
  local fields = {}
  for bit = 24, 29 do
    if hasBit(flag, bit) then
      local name = SUPPORTED_FIELD_BITS[bit]
      if name == nil then
        local fieldName = bit == 25 and "use_fld_rndm" or "use_fld_scfld"
        sourceError("SPL emitter uses an unsupported particle field", {
          emitter = emitterId,
          flag = fieldName,
          offset = cursor,
        })
      end
      fields[#fields + 1] = { kind = name, offset = take(FIELD_SIZES[name], name) }
    end
  end
  local function s16(offset)
    local value = reader:u16le(offset)
    if value >= 32768 then
      return value - 65536
    end
    return value
  end
  local function s32(offset)
    local value = reader:u32le(offset)
    if value >= 2147483648 then
      return value - 4294967296
    end
    return value
  end
  local function fx32(offset)
    return s32(offset) / 4096
  end
  local function vecFx32(offset)
    return { x = fx32(offset), y = fx32(offset + 4), z = fx32(offset + 8) }
  end
  local function rgb555Channels(offset)
    local value = reader:u16le(offset)
    return { r = value % 32, g = math.floor(value / 32) % 32, b = math.floor(value / 1024) % 32 }
  end
  -- Second animation/texture word: loop frame, directional scale, texture
  -- repeat counts, the animated scale direction, the polygon center, and
  -- the direction-from-center selector in bit 31.
  local word1 = reader:u32le(baseOffset + 72)
  -- Mirror/offset word: texture mirroring, the UV offset mode, and the
  -- reserved remainder, which carries no behavior for the observed records.
  local word2 = reader:u32le(baseOffset + 76)
  local function wordBit(word, bit)
    return math.floor(word / (2 ^ bit)) % 2 == 1
  end
  local child = nil
  if blocks.childOffset ~= nil then
    child = decodeChild(reader, blocks.childOffset, emitterId)
  end
  return {
    id = emitterId,
    flag = flag,
    position = vecFx32(baseOffset + 4),
    generationCountFx = s32(baseOffset + 16),
    radius = fx32(baseOffset + 20),
    length = fx32(baseOffset + 24),
    axis = {
      x = s16(baseOffset + 28) / 4096,
      y = s16(baseOffset + 30) / 4096,
      z = s16(baseOffset + 32) / 4096,
    },
    baseColorRgb = rgb555Channels(baseOffset + 34),
    initialVelocityFx = s32(baseOffset + 36),
    initialAxisVelocityFx = s32(baseOffset + 40),
    baseScaleFx = s32(baseOffset + 44),
    aspect = s16(baseOffset + 48) / 4096,
    startOffset = reader:u16le(baseOffset + 50),
    rotationMin = s16(baseOffset + 52),
    rotationMax = s16(baseOffset + 54),
    initRotation = reader:u16le(baseOffset + 56),
    emitterLife = reader:u16le(baseOffset + 60),
    particleLife = reader:u16le(baseOffset + 62),
    randomRanges = {
      baseScale = reader:u8(baseOffset + 64),
      particleLife = reader:u8(baseOffset + 65),
      initVelocity = reader:u8(baseOffset + 66),
    },
    generationInterval = reader:u8(baseOffset + 68),
    baseAlpha = reader:u8(baseOffset + 69),
    airResist = reader:u8(baseOffset + 70),
    textureIndex = reader:u8(baseOffset + 71),
    loopFrame = word1 % 256,
    dbbScale = math.floor(word1 / 256) % 65536,
    texRepeat = { s = math.floor(word1 / 16777216) % 4, t = math.floor(word1 / 67108864) % 4 },
    sclAnmDirect = math.floor(word1 / 268435456) % 8,
    reverseTex = { s = word2 % 2 == 1, t = math.floor(word2 / 2) % 2 == 1 },
    randomLoopPhase = wordBit(flag, 20),
    cameraOffset = wordBit(flag, 23),
    fixedPolygonId = wordBit(flag, 30),
    childFixedPolygonId = wordBit(flag, 31),
    polygonRotationAxis = math.floor(flag / 131072) % 4,
    polygonPlane = wordBit(flag, 19) and "xz" or "xy",
    directionFromCenter = wordBit(word1, 31),
    offsetPos = math.floor(word2 / 4) % 8,
    offset = { x = s16(baseOffset + 80) / 4096, y = s16(baseOffset + 82) / 4096 },
    blocks = blocks,
    child = child,
    fields = fields,
  },
    cursor
end

---@param reader BinaryReader
---@param offset integer zero-based offset of the texture header
---@param textureId integer
---@param earlier table<string, unknown>[] already decoded texture records for shared-texel resolution
---@return table<string, unknown> normalized texture record
---@return integer nextOffset zero-based offset past the texture block
local function decodeTexture(reader, offset, textureId, earlier)
  local length = reader:length()
  if offset + 32 > length then
    sourceError("SPL texture block exceeds its resource", { texture = textureId, offset = offset })
  end
  local magic = reader:u32le(offset)
  if magic ~= 0x53505420 then
    sourceError("SPL texture block has an unexpected magic", { texture = textureId, offset = offset })
  end
  local param = reader:u32le(offset + 4)
  local function bits(value, shift, width)
    return math.floor(value / (2 ^ shift)) % (2 ^ width)
  end
  local format = bits(param, 0, 4)
  if format < 1 or format > 7 then
    sourceError("SPL texture has an unsupported texel format", {
      texture = textureId,
      format = format,
      offset = offset,
    })
  end
  local width = 2 ^ (bits(param, 4, 4) + 3)
  local height = 2 ^ (bits(param, 8, 4) + 3)
  local repeatS = bits(param, 12, 1) == 1
  local repeatT = bits(param, 13, 1) == 1
  local flipS = bits(param, 14, 1) == 1
  local flipT = bits(param, 15, 1) == 1
  local color0Transparent = bits(param, 16, 1) == 1
  local sharedTexels = bits(param, 17, 1) == 1
  local reference = bits(param, 18, 8)
  local texSize = reader:u32le(offset + 8)
  local paletteOffset = reader:u32le(offset + 12)
  local paletteSize = reader:u32le(offset + 16)
  local blockSize = reader:u32le(offset + 28)
  if blockSize < 32 or offset + blockSize > length then
    sourceError("SPL texture block size exceeds its resource", { texture = textureId, offset = offset })
  end
  if paletteOffset + paletteSize > blockSize then
    sourceError("SPL texture palette exceeds its texture block", { texture = textureId, offset = offset })
  end
  local texelOffset = offset + 32
  local texelSize = texSize
  if sharedTexels then
    -- Hardware texture sharing copies only the earlier entry's texel
    -- bytes: the referencing header keeps its own dimensions, format,
    -- palette, transparency, and sampler.
    local shared = earlier[reference + 1]
    if shared == nil then
      sourceError("SPL texture references a missing earlier texture", {
        texture = textureId,
        reference = reference,
        offset = offset,
      })
    end
    assert(shared ~= nil, "SPL texture references a staged earlier texture")
    texelOffset = shared.texelOffset
    texelSize = shared.texelSize
  end
  if texelOffset + texelSize > length then
    sourceError("SPL texture texels exceed their resource", { texture = textureId, offset = offset })
  end
  local function wrap(repeatEnabled, flipEnabled)
    if flipEnabled then
      return "mirroredrepeat"
    end
    if repeatEnabled then
      return "repeat"
    end
    return "clamp"
  end
  return {
    id = textureId,
    format = format,
    width = width,
    height = height,
    texelOffset = texelOffset,
    texelSize = texelSize,
    paletteOffset = offset + paletteOffset,
    paletteSize = paletteSize,
    color0Transparent = color0Transparent,
    sampler = {
      minFilter = "nearest",
      magFilter = "nearest",
      wrapX = wrap(repeatS, flipS),
      wrapY = wrap(repeatT, flipT),
    },
  },
    offset + blockSize
end

-- Decode one SPL resource file into normalized emitter and texture
-- records. Offsets stay zero-based into the member bytes; the caller owns
-- texture pixel decoding and emitter assignment.
---@param data string raw SPL resource member bytes
---@return table<string, unknown>|nil
---@return Errors.Error|string|nil
function SplResource.decode(data)
  if type(data) ~= "string" or #data < HEADER_SIZE then
    return nil,
      Errors.new(
        SplResource.ERROR.SOURCE_INVALID,
        "SPL resource is shorter than its header",
        { size = type(data) == "string" and #data or -1 }
      )
  end
  local reader = BinaryReader.new(data, "spl-resource")
  if reader:ascii(0, 8, false) ~= MAGIC then
    return nil,
      Errors.new(
        SplResource.ERROR.SOURCE_INVALID,
        "SPL resource has an unexpected magic",
        { magic = reader:ascii(0, 8, false) }
      )
  end
  local emitterCount = reader:u16le(8)
  local textureCount = reader:u16le(10)
  if emitterCount <= 0 or emitterCount > 64 or textureCount < 0 or textureCount > 64 then
    return nil,
      Errors.new(
        SplResource.ERROR.SOURCE_INVALID,
        "SPL resource carries an implausible emitter or texture count",
        { emitters = emitterCount, textures = textureCount }
      )
  end
  local ok, result = pcall(function()
    local emitters = {}
    local cursor = HEADER_SIZE
    for emitterId = 0, emitterCount - 1 do
      local emitter
      emitter, cursor = decodeEmitter(reader, cursor, emitterId)
      emitters[#emitters + 1] = emitter
    end
    local textures = {}
    for textureId = 0, textureCount - 1 do
      local texture
      texture, cursor = decodeTexture(reader, cursor, textureId, textures)
      textures[#textures + 1] = texture
    end
    if cursor ~= #data then
      sourceError("SPL resource carries trailing bytes past its texture blocks", {
        offset = cursor,
        size = #data,
      })
    end
    return { emitters = emitters, textures = textures }
  end)
  if not ok then
    if Errors.is(result) then
      return nil, result
    end
    error(result, 0)
  end
  return result
end

return SplResource
