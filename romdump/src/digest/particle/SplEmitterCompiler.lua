-- Normalizes decoded retail SPL particle resources (SplResource) into the
-- source-independent emitter vocabulary generated assets carry: one record
-- per emitter plus staged texture art. Callers supply the texture output
-- paths, an optional per-emitter group, and an optional required emitter
-- count; the SPL binary layout stays with SplResource and the replay
-- semantics with the runtime simulation. Any emitter feature the runtime
-- cannot reproduce fails the build with emitter context instead of silently
-- dropping an effect. Texture pixels decode through the shared
-- TextureDecoder. Authority: the retail SPL library (spl_resource.h,
-- spl_generate.c, spl_anim.c, spl_manager.c).

local BinaryReader = require("libs.codec.src.BinaryReader")
local Errors = require("libs.errors.src.Errors")
local Hashing = require("romdump.src.digest.Hashing")
local PngWriter = require("romdump.src.digest.PngEncoder")
local SplResource = require("libs.nds.src.nitro.spl.SplResource")
local TextureDecoder = require("libs.nds.src.gx.TextureDecoder")

local SplEmitterCompiler = {}

SplEmitterCompiler.ERROR = { SOURCE_INVALID = "SPL_EMITTER_SOURCE_INVALID" }

-- Retail deterministic seed: the particle heap starts zeroed, so the
-- library random stream opens at zero. The record pins zero rather than the
-- host random state.
local PARTICLE_SEED = 0

---@param message string
---@param context table<string, unknown>|nil
local function sourceError(message, context)
  Errors.raise(SplEmitterCompiler.ERROR.SOURCE_INVALID, message, context or {})
end

---@param value integer unsigned 16-bit value
---@return integer
local function toS16(value)
  if value >= 32768 then
    return value - 65536
  end
  return value
end

---@param block string raw SPL member bytes
---@param record table<string, unknown> decoded SplResource texture record
---@return table<string, unknown> decoded width, height, and RGBA pixels
local function decodeTexture(block, record)
  local texels = block:sub(record.texelOffset + 1, record.texelOffset + record.texelSize)
  local palette = block:sub(record.paletteOffset + 1, record.paletteOffset + record.paletteSize)
  local ok, decoded = pcall(TextureDecoder.decode, {
    format = record.format,
    width = record.width,
    height = record.height,
    texel = texels,
    palette = palette,
    color0Transparent = true,
  }, { name = "particle-texture-" .. tostring(record.id) })
  if not ok then
    sourceError("particle texture could not be decoded", {
      texture = record.id,
      error = tostring(decoded),
    })
  end
  assert(type(decoded) == "table" and type(decoded.pixels) == "string", "particle texture decode is malformed")
  return decoded
end

---@param record table<string, unknown> decoded SplResource texture record
---@param decoded table<string, unknown> decoded texture pixels
---@return string pngBytes
local function encodeTexturePng(record, decoded)
  local png = PngWriter.encode(decoded.width, decoded.height, decoded.pixels)
  if png == nil then
    sourceError("particle texture could not be encoded", { texture = record.id })
  end
  return assert(png, "particle texture encoding is malformed")
end

---@param field table<string, unknown> decoded SplResource field record
---@param block string raw SPL member bytes
---@return table<string, unknown> normalized field record
local function normalizeField(field, block)
  local reader = BinaryReader.new(block, "spl-field")
  if field.kind == "gravity" then
    local function fx(offset)
      return toS16(reader:u16le(offset)) / 4096
    end
    return {
      kind = "gravity",
      magnitude = { x = fx(field.offset), y = fx(field.offset + 2), z = fx(field.offset + 4) },
    }
  elseif field.kind == "magnet" then
    local function fx(offset)
      local value = reader:u32le(offset)
      if value >= 2147483648 then
        value = value - 4294967296
      end
      return value / 4096
    end
    return {
      kind = "magnet",
      position = { x = fx(field.offset), y = fx(field.offset + 4), z = fx(field.offset + 8) },
      magnitude = toS16(reader:u16le(field.offset + 12)) / 4096,
    }
  elseif field.kind == "spin" then
    return {
      kind = "spin",
      rotation = reader:u16le(field.offset),
      axis = reader:u16le(field.offset + 2),
    }
  end
  -- SplResource decodes only the observed gravity, magnet, and spin
  -- fields, so any other kind is a producer inconsistency.
  sourceError("particle field is outside the observed set", { kind = field.kind })
  error("unreachable")
end

-- Reads one staged scale block: three signed fx16 stages with entry/exit
-- life-rate thresholds and the loop selector (recorded only when set).
---@param block string raw SPL member bytes
---@param offset integer zero-based offset of the scale block
---@return table<string, unknown> normalized scale record
local function decodeScaleBlock(block, offset)
  local reader = BinaryReader.new(block, "spl-scale")
  local thresholds = reader:u16le(offset + 6)
  local etc = reader:u16le(offset + 8)
  return {
    startFx = toS16(reader:u16le(offset)),
    normalFx = toS16(reader:u16le(offset + 2)),
    finishFx = toS16(reader:u16le(offset + 4)),
    inTick = thresholds % 256,
    outTick = math.floor(thresholds / 256) % 256,
    loop = etc % 2 == 1 or nil,
  }
end

-- Reads one staged color block: RGB555 endpoints with entry/peak/exit
-- life-rate thresholds, interpolation, and the random-pick and loop
-- selectors (recorded only when set).
---@param block string raw SPL member bytes
---@param offset integer zero-based offset of the color block
---@return table<string, unknown> normalized color record
local function decodeColorBlock(block, offset)
  local reader = BinaryReader.new(block, "spl-color")
  local function channels(value)
    return { r = value % 32, g = math.floor(value / 32) % 32, b = math.floor(value / 1024) % 32 }
  end
  local rates = reader:u32le(offset + 4)
  local etc = reader:u16le(offset + 8)
  return {
    startRgb = channels(reader:u16le(offset)),
    endRgb = channels(reader:u16le(offset + 2)),
    inTick = rates % 256,
    peakTick = math.floor(rates / 256) % 256,
    outTick = math.floor(rates / 65536) % 256,
    interpolate = math.floor(etc / 4) % 2 == 1,
    random = etc % 2 == 1 or nil,
    loop = math.floor(etc / 2) % 2 == 1 or nil,
  }
end

-- Reads one staged alpha block: three 5-bit levels with entry/exit
-- life-rate thresholds, the flicker magnitude, and the loop selector
-- (recorded only when set).
---@param block string raw SPL member bytes
---@param offset integer zero-based offset of the alpha block
---@return table<string, unknown> normalized alpha record
local function decodeAlphaBlock(block, offset)
  local reader = BinaryReader.new(block, "spl-alpha")
  local levels = reader:u16le(offset)
  local etc = reader:u16le(offset + 2)
  local thresholds = reader:u16le(offset + 4)
  return {
    start = levels % 32,
    normal = math.floor(levels / 32) % 32,
    finish = math.floor(levels / 1024) % 32,
    flick = etc % 256,
    inTick = thresholds % 256,
    outTick = math.floor(thresholds / 256) % 256,
    loop = math.floor(etc / 256) % 2 == 1 or nil,
  }
end

-- Reads one staged texture-animation block: up to eight source texture ids,
-- the per-stage life-rate width, and the random-pick and loop selectors.
---@param block string raw SPL member bytes
---@param offset integer zero-based offset of the texture animation block
---@param byTexture table<integer, table<string, unknown>> staged textures by source id
---@param emitterId integer
---@return table<string, unknown> normalized texture animation record
local function decodeTextureAnim(block, offset, byTexture, emitterId)
  local reader = BinaryReader.new(block, "spl-texture-anim")
  local useNum = reader:u8(offset + 8)
  if useNum < 1 or useNum > 8 then
    sourceError("particle emitter carries an invalid texture animation count", {
      emitter = emitterId,
      count = useNum,
    })
  end
  local textures = {}
  for index = 0, useNum - 1 do
    local textureId = reader:u8(offset + index)
    if byTexture[textureId] == nil then
      sourceError("particle emitter texture animation references a missing texture", {
        emitter = emitterId,
        texture = textureId,
      })
    end
    textures[#textures + 1] = textureId
  end
  local etc = reader:u8(offset + 10)
  return {
    textures = textures,
    diff = reader:u8(offset + 9),
    random = etc % 2 == 1,
    loop = math.floor(etc / 2) % 2 == 1,
  }
end

-- Normalizes one staged child block: spawn, animation, color, draw, and
-- texture records for the particles a parent spawns over its life.
---@param child table<string, unknown> decoded SplResource child record
---@param byTexture table<integer, table<string, unknown>> staged textures by source id
---@param emitterId integer
---@return table<string, unknown> normalized child record
local function normalizeChild(child, byTexture, emitterId)
  local function childBit(bit)
    return math.floor(child.flag / (2 ^ bit)) % 2 == 1
  end
  local function reject(message)
    sourceError(message, { emitter = emitterId, offset = child.offset })
  end
  -- spl_generate.c handles rotation types 0 (none), 1 (parent angle), and
  -- 2 (parent angle and spin); type 3 leaves the angle uninitialized.
  local rotationType = math.floor(child.flag / 8) % 4
  if rotationType == 3 then
    reject("particle child uses an unrepresented rotation")
  end
  if childBit(0) then
    reject("particle child is field-driven")
  end
  if math.floor(child.flag / 128) % 4 ~= 0 then
    reject("particle child uses an unrepresented draw kind")
  end
  if child.reverseS or child.reverseT then
    reject("particle child uses mirrored texture coordinates")
  end
  if child.life <= 0 then
    reject("particle child carries no lifespan")
  end
  if child.genInterval <= 0 then
    reject("particle child carries no generation interval")
  end
  local texture = byTexture[child.texNo]
  if texture == nil then
    sourceError("particle child references a missing texture", {
      emitter = emitterId,
      texture = child.texNo,
    })
  end
  assert(texture ~= nil, "unreachable: a missing child texture always raises")
  return {
    useScaleAnm = childBit(1),
    useAlphaAnm = childBit(2),
    followEmitter = childBit(5),
    useChildColor = childBit(6),
    childColor = child.colorRgb,
    rotationType = rotationType ~= 0 and rotationType or nil,
    drawType = 0,
    initVelRandom = child.initVelMagRndm,
    scaleEnd = child.scaleEnd,
    life = child.life,
    velRatio = child.velRatio,
    sclRatio = child.sclRatio,
    genNum = child.genNum,
    genStart = child.genStart,
    genInterval = child.genInterval,
    texNo = child.texNo,
    textureImage = texture.image,
    texRepeat = { s = child.texRepeatS, t = child.texRepeatT },
  }
end

---@param emitter table<string, unknown> decoded SplResource emitter record
local function validateEmitter(emitter)
  local function reject(message, context)
    context = context or {}
    context.emitter = emitter.id
    sourceError(message, context)
  end
  -- Flag-derived geometry: only the placement kinds and draw kinds the
  -- runtime replays compile.
  if emitter.flag % 16 > 9 then
    reject("particle emitter uses an unrepresented placement kind", { placement = emitter.flag % 16 })
  end
  local circleAxis = math.floor(emitter.flag / 64) % 4
  if circleAxis == 3 then
    reject("particle emitter uses an unrepresented circle axis", { axis = circleAxis })
  end
  local drawType = math.floor(emitter.flag / 16) % 4
  if drawType ~= 0 and drawType ~= 1 then
    reject("particle emitter uses an unrepresented draw kind", { draw = drawType })
  end
  if math.floor(emitter.flag / 16384) % 2 ~= 1 then
    reject("particle emitter does not self-destruct")
  end
  if math.floor(emitter.flag / 4194304) % 2 == 1 then
    reject("particle emitter uses an unrepresented parent draw gate")
  end
  if math.floor(emitter.flag / 8388608) % 2 == 1 then
    reject("particle emitter uses an unrepresented camera-relative draw")
  end
  -- Bounded lifetimes and schedules: a zero generation interval or loop
  -- frame divides by zero in the retail update, and a zero lifespan
  -- divides the life-rate computation or never retires its run case.
  if emitter.generationInterval <= 0 then
    reject("particle emitter carries no generation interval")
  end
  if emitter.emitterLife <= 0 then
    reject("particle emitter carries no emitter lifespan")
  end
  if emitter.particleLife <= 0 then
    reject("particle emitter carries no particle lifespan")
  end
  if emitter.loopFrame <= 0 then
    reject("particle emitter carries no animation loop frame")
  end
  if emitter.baseAlpha > 31 then
    reject("particle emitter carries no 5-bit base alpha", { alpha = emitter.baseAlpha })
  end
  if emitter.reverseTex.s or emitter.reverseTex.t then
    reject("particle emitter uses mirrored texture coordinates")
  end
end

---@param memberBytes string raw SPL member bytes
---@param emitter table<string, unknown> decoded SplResource emitter record
---@param byTexture table<integer, table<string, unknown>> staged textures by source id
---@param group string|nil
---@return table<string, unknown> normalized emitter record
local function normalizeEmitter(memberBytes, emitter, byTexture, group)
  validateEmitter(emitter)
  local animations = {}
  if emitter.blocks.scaleOffset ~= nil then
    animations.scale = decodeScaleBlock(memberBytes, emitter.blocks.scaleOffset)
  end
  if emitter.blocks.colorOffset ~= nil then
    animations.color = decodeColorBlock(memberBytes, emitter.blocks.colorOffset)
  end
  if emitter.blocks.alphaOffset ~= nil then
    animations.alpha = decodeAlphaBlock(memberBytes, emitter.blocks.alphaOffset)
  end
  local textureAnim = nil
  local texture
  if emitter.blocks.textureAnimOffset ~= nil then
    textureAnim = decodeTextureAnim(memberBytes, emitter.blocks.textureAnimOffset, byTexture, emitter.id)
    texture = byTexture[textureAnim.textures[1]]
  else
    texture = byTexture[emitter.textureIndex]
    if texture == nil then
      sourceError("particle emitter references a missing texture", {
        emitter = emitter.id,
        texture = emitter.textureIndex,
      })
    end
  end
  assert(texture ~= nil, "unreachable: a missing emitter texture always raises")
  local child = nil
  if emitter.child ~= nil then
    child = normalizeChild(emitter.child, byTexture, emitter.id)
  end
  local fields = {}
  for _, field in ipairs(emitter.fields) do
    local normalized = normalizeField(field, memberBytes)
    if normalized.kind == "spin" and normalized.axis > 2 then
      sourceError("particle spin field uses an unrepresented axis", {
        emitter = emitter.id,
        axis = normalized.axis,
        offset = field.offset,
      })
    end
    fields[#fields + 1] = normalized
  end
  local textureOffset = nil
  if emitter.offsetPos ~= 0 or emitter.offset.x ~= 0 or emitter.offset.y ~= 0 then
    textureOffset = { mode = emitter.offsetPos, x = emitter.offset.x, y = emitter.offset.y }
  end
  local drawChildFirst = nil
  if math.floor(emitter.flag / 2097152) % 2 == 1 then
    drawChildFirst = true
  end
  return {
    id = emitter.id,
    group = group,
    emitterLife = emitter.emitterLife,
    particleLife = emitter.particleLife,
    startOffset = emitter.startOffset,
    generation = { countFx = emitter.generationCountFx, interval = emitter.generationInterval },
    initPosType = emitter.flag % 16,
    circleAxis = math.floor(emitter.flag / 64) % 4,
    drawType = math.floor(emitter.flag / 16) % 4,
    radius = emitter.radius,
    length = emitter.length,
    position = emitter.position,
    axis = emitter.axis,
    baseColorRgb = emitter.baseColorRgb,
    baseAlpha = emitter.baseAlpha,
    baseScaleFx = emitter.baseScaleFx,
    velocityFx = { pos = emitter.initialVelocityFx, axis = emitter.initialAxisVelocityFx },
    velRandom = emitter.randomRanges.initVelocity,
    scaleRandom = emitter.randomRanges.baseScale,
    lifeRandom = emitter.randomRanges.particleLife,
    rotation = { min = emitter.rotationMin, max = emitter.rotationMax },
    useRotationAnim = math.floor(emitter.flag / 4096) % 2 == 1,
    useInitRotationRandom = math.floor(emitter.flag / 8192) % 2 == 1,
    initRotation = emitter.initRotation,
    airResist = emitter.airResist,
    aspect = emitter.aspect,
    loopFrame = emitter.loopFrame,
    dbbScale = emitter.dbbScale,
    sclAnmDirect = emitter.sclAnmDirect,
    texRepeat = emitter.texRepeat,
    texture = texture.id,
    textureImage = texture.image,
    textureAnim = textureAnim,
    textureOffset = textureOffset,
    drawChildFirst = drawChildFirst,
    animations = animations,
    child = child,
    fields = fields,
  }
end

---@class SplEmitterCompileOptions
---@field texturePath (fun(textureId: integer): string)|nil output path a staged texture image takes; nil exactly when embedPixels is set
---@field embedPixels boolean|nil true to carry each texture's RGBA pixels in its record instead of staging a PNG
---@field emitterCount integer|nil required emitter count, or nil for no requirement
---@field group (fun(emitterId: integer): string|nil)|nil group tag per emitter; returning nil rejects the emitter

-- Compile one SPL member into normalized per-emitter emission records plus
-- staged texture art. The emitter-level `textureAnim` and `textureOffset`
-- fields, `drawChildFirst`, and the `loop`/`random` flags on animation blocks, are absent
-- unless the source sets them. Returns the normalized particle set, its
-- staged files, and the producer dependencies for the job receipt.
---@param memberBytes string raw SPL member bytes
---@param options SplEmitterCompileOptions
---@return table<string, unknown>
local function compileEmitters(memberBytes, options)
  local decoded, decodeErr = SplResource.decode(memberBytes)
  if decoded == nil then
    if Errors.is(decodeErr) then
      error(decodeErr, 0)
    end
    sourceError("particle member could not be decoded", { error = tostring(decodeErr) })
  end
  assert(decoded ~= nil, "unreachable: a failed decode always raises")
  if options.emitterCount ~= nil and #decoded.emitters ~= options.emitterCount then
    sourceError("particle member carries an unexpected emitter count", {
      emitters = #decoded.emitters,
      expected = options.emitterCount,
    })
  end
  local files = {}
  local textures = {}
  local byTexture = {}
  for _, texture in ipairs(decoded.textures) do
    local pixels = decodeTexture(memberBytes, texture)
    local staged = {
      id = texture.id,
      format = texture.format,
      width = texture.width,
      height = texture.height,
      sourceHash = Hashing.sha1hex(
        memberBytes:sub(texture.texelOffset + 1, texture.texelOffset + texture.texelSize)
          .. memberBytes:sub(texture.paletteOffset + 1, texture.paletteOffset + texture.paletteSize)
      ),
    }
    if options.embedPixels then
      staged.pixels = pixels.pixels
    else
      staged.image = options.texturePath(texture.id)
      files[staged.image] = encodeTexturePng(texture, pixels)
    end
    textures[#textures + 1] = staged
    byTexture[texture.id] = staged
  end
  local emitters = {}
  for _, emitter in ipairs(decoded.emitters) do
    local group = nil
    if options.group ~= nil then
      group = options.group(emitter.id)
      if group == nil then
        sourceError("particle emitter is outside the expected set", { emitter = emitter.id })
      end
    end
    emitters[#emitters + 1] = normalizeEmitter(memberBytes, emitter, byTexture, group)
  end
  return {
    particles = { seed = PARTICLE_SEED, emitters = emitters, textures = textures },
    files = files,
    dependencies = { particleMemberHash = Hashing.sha1hex(memberBytes) },
  }
end

---@param memberBytes string raw SPL member bytes
---@param options SplEmitterCompileOptions
---@return table<string, unknown>|nil
---@return Errors.Error|string|nil
function SplEmitterCompiler.compile(memberBytes, options)
  assert(type(memberBytes) == "string", "particle compilation requires the source member bytes")
  assert(
    type(options) == "table" and (type(options.texturePath) == "function") ~= (options.embedPixels == true),
    "particle compilation names its texture paths or embeds pixels"
  )
  -- Per-emitter failures raise with emitter context; the boundary converts
  -- structured failures back to the nil-plus-cause contract.
  local ok, first, second = pcall(compileEmitters, memberBytes, options)
  if ok then
    return first, second
  end
  if Errors.is(first) then
    return nil, first
  end
  error(first, 0)
end

return SplEmitterCompiler
