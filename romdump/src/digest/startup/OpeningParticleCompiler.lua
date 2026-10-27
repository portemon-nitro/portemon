-- Normalizes the retail SPL starter emitter resources behind opening-movie
-- scene 4 (NARC_a_0_5_9 member 4) into the source-independent particle
-- vocabulary the scene manifest carries. The retail library starts one
-- emitter per starter group: grass {6,7,8} for Chikorita, fire {3,4,5} for
-- Cyndaquil, water {0,1,2} for Totodile (src/intro_movie_scene_4.c
-- sStarterParticleResIds). The SPL binary layout stays with SplResource;
-- this module owns only the starter assignment, the deterministic source
-- seed, and the per-emitter emission record. Texture pixels decode through
-- the shared TextureDecoder; any emitter or texture the narrow decoder
-- cannot represent fails the build with emitter context instead of
-- silently dropping a starter effect.

local Errors = require("libs.errors.src.Errors")
local Hashing = require("romdump.src.digest.Hashing")
local PngWriter = require("romdump.src.digest.PngEncoder")
local SplResource = require("libs.nds.src.nitro.spl.SplResource")
local TextureDecoder = require("libs.nds.src.gx.TextureDecoder")

local OpeningParticleCompiler = {}

OpeningParticleCompiler.ERROR = { SOURCE_INVALID = "OPENING_PARTICLE_SOURCE_INVALID" }

-- Retail deterministic seed: the particle heap starts zeroed, so the
-- library random stream opens at zero. Later scenes or builds never reseed
-- it; the record pins zero rather than the host random state.
local PARTICLE_SEED = 0

local EMITTER_GROUPS = {
  [0] = "water",
  [1] = "water",
  [2] = "water",
  [3] = "fire",
  [4] = "fire",
  [5] = "fire",
  [6] = "grass",
  [7] = "grass",
  [8] = "grass",
}

---@param message string
---@param context table<string, unknown>|nil
local function sourceError(message, context)
  Errors.raise(OpeningParticleCompiler.ERROR.SOURCE_INVALID, message, context or {})
end

---@param block string raw SPL member bytes
---@param record table<string, unknown> decoded SplResource texture record
---@return string pngBytes
local function decodeTexturePng(block, record)
  local texels = block:sub(record.texelOffset + 1, record.texelOffset + record.texelSize)
  local palette = block:sub(record.paletteOffset + 1, record.paletteOffset + record.paletteSize)
  local ok, decoded = pcall(TextureDecoder.decode, {
    format = record.format,
    width = record.width,
    height = record.height,
    texel = texels,
    palette = palette,
    color0Transparent = true,
  }, { name = "opening-scene-4-particle-texture-" .. tostring(record.id) })
  if not ok then
    sourceError("opening scene 4 particle texture could not be decoded", {
      texture = record.id,
      error = tostring(decoded),
    })
  end
  assert(type(decoded) == "table" and type(decoded.pixels) == "string", "particle texture decode is malformed")
  local png = PngWriter.encode(decoded.width, decoded.height, decoded.pixels)
  if png == nil then
    sourceError("opening scene 4 particle texture could not be encoded", { texture = record.id })
  end
  return assert(png, "particle texture encoding is malformed")
end

---@param field table<string, unknown> decoded SplResource field record
---@param block string raw SPL member bytes
---@return table<string, unknown> normalized field record
local function normalizeField(field, block)
  local reader = require("libs.codec.src.BinaryReader").new(block, "spl-field")
  if field.kind == "gravity" then
    local function fx(offset)
      local value = reader:u16le(offset)
      if value >= 32768 then
        value = value - 65536
      end
      return value / 4096
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
    local function s16(offset)
      local value = reader:u16le(offset)
      if value >= 32768 then
        return value - 65536
      end
      return value
    end
    return {
      kind = "magnet",
      position = { x = fx(field.offset), y = fx(field.offset + 4), z = fx(field.offset + 8) },
      magnitude = s16(field.offset + 12) / 4096,
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
  error(
    Errors.new(
      OpeningParticleCompiler.ERROR.SOURCE_INVALID,
      "opening scene 4 particle field is outside the observed set",
      { kind = field.kind }
    ),
    0
  )
end

-- Reads one staged scale block: three signed fx16 stages with entry/exit
-- life-rate thresholds and the loop selector.
---@param block string raw SPL member bytes
---@param offset integer zero-based offset of the scale block
---@param emitterId integer
---@return table<string, unknown> normalized scale record
local function decodeScaleBlock(block, offset, emitterId)
  local reader = require("libs.codec.src.BinaryReader").new(block, "spl-scale")
  local function fx16(value)
    if value >= 32768 then
      return value - 65536
    end
    return value
  end
  local thresholds = reader:u16le(offset + 6)
  local etc = reader:u16le(offset + 8)
  if etc % 2 ~= 0 then
    sourceError("opening scene 4 particle uses an unrepresented looping scale", {
      emitter = emitterId,
      offset = offset,
    })
  end
  return {
    startFx = fx16(reader:u16le(offset)),
    normalFx = fx16(reader:u16le(offset + 2)),
    finishFx = fx16(reader:u16le(offset + 4)),
    inTick = thresholds % 256,
    outTick = math.floor(thresholds / 256) % 256,
  }
end

-- Reads one staged color block: RGB555 endpoints with entry/peak/exit
-- life-rate thresholds, the random-pick selector, and interpolation.
---@param block string raw SPL member bytes
---@param offset integer zero-based offset of the color block
---@param emitterId integer
---@return table<string, unknown> normalized color record
local function decodeColorBlock(block, offset, emitterId)
  local reader = require("libs.codec.src.BinaryReader").new(block, "spl-color")
  local function channels(value)
    return { r = value % 32, g = math.floor(value / 32) % 32, b = math.floor(value / 1024) % 32 }
  end
  local rates = reader:u32le(offset + 4)
  local etc = reader:u16le(offset + 8)
  if etc % 2 ~= 0 then
    sourceError("opening scene 4 particle uses an unrepresented random color pick", {
      emitter = emitterId,
      offset = offset,
    })
  end
  if math.floor(etc / 2) % 2 ~= 0 then
    sourceError("opening scene 4 particle uses an unrepresented looping color", {
      emitter = emitterId,
      offset = offset,
    })
  end
  return {
    startRgb = channels(reader:u16le(offset)),
    endRgb = channels(reader:u16le(offset + 2)),
    inTick = rates % 256,
    peakTick = math.floor(rates / 256) % 256,
    outTick = math.floor(rates / 65536) % 256,
    interpolate = math.floor(etc / 4) % 2 == 1,
  }
end

-- Reads one staged alpha block: three 5-bit levels with entry/exit
-- life-rate thresholds and the flicker magnitude.
---@param block string raw SPL member bytes
---@param offset integer zero-based offset of the alpha block
---@param emitterId integer
---@return table<string, unknown> normalized alpha record
local function decodeAlphaBlock(block, offset, emitterId)
  local reader = require("libs.codec.src.BinaryReader").new(block, "spl-alpha")
  local levels = reader:u16le(offset)
  local etc = reader:u16le(offset + 2)
  if math.floor(etc / 256) % 2 ~= 0 then
    sourceError("opening scene 4 particle uses an unrepresented looping alpha", {
      emitter = emitterId,
      offset = offset,
    })
  end
  local thresholds = reader:u16le(offset + 4)
  return {
    start = levels % 32,
    normal = math.floor(levels / 32) % 32,
    finish = math.floor(levels / 1024) % 32,
    flick = etc % 256,
    inTick = thresholds % 256,
    outTick = math.floor(thresholds / 256) % 256,
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
  if math.floor(child.flag / 8) % 4 ~= 0 then
    sourceError("opening scene 4 particle uses an unrepresented child rotation", {
      emitter = emitterId,
      offset = child.offset,
    })
  end
  if childBit(0) then
    sourceError("opening scene 4 particle uses an unrepresented field-driven child", {
      emitter = emitterId,
      offset = child.offset,
    })
  end
  if math.floor(child.flag / 128) % 4 ~= 0 then
    sourceError("opening scene 4 particle uses an unrepresented child draw kind", {
      emitter = emitterId,
      offset = child.offset,
    })
  end
  if child.reverseS or child.reverseT then
    sourceError("opening scene 4 particle uses mirrored child texture coordinates", {
      emitter = emitterId,
      offset = child.offset,
    })
  end
  if child.life <= 0 then
    sourceError("opening scene 4 particle child carries no lifespan", {
      emitter = emitterId,
      offset = child.offset,
    })
  end
  if child.genInterval <= 0 then
    sourceError("opening scene 4 particle child carries no generation interval", {
      emitter = emitterId,
      offset = child.offset,
    })
  end
  local texture = byTexture[child.texNo]
  if texture == nil then
    sourceError("opening scene 4 particle child references a missing particle texture", {
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
-- Compile the starter emitter set from the raw scene 4 SPL member into
-- normalized per-emitter emission records plus staged texture art. The
-- member must carry exactly the nine retail starter emitters; the texture
-- chosen by each emitter's own texture index stages under the scene 4
-- asset root. Returns the normalized particle set, its staged files, and
-- the producer dependencies for the job receipt.
---@param memberBytes string raw NARC_a_0_5_9 member 4 bytes
---@param sceneRoot string scene asset root the texture art stages under
---@return table<string, unknown>
local function compileEmitters(memberBytes, sceneRoot)
  local decoded, decodeErr = SplResource.decode(memberBytes)
  if decoded == nil then
    if Errors.is(decodeErr) then
      error(decodeErr, 0)
    end
    sourceError("opening scene 4 particle member could not be decoded", {
      error = tostring(decodeErr),
    })
  end
  assert(decoded ~= nil, "unreachable: a failed decode always raises")
  if #decoded.emitters ~= 9 then
    sourceError("opening scene 4 particle member carries no nine starter emitters", {
      emitters = #decoded.emitters,
    })
  end
  local files = {}
  local textures = {}
  for _, texture in ipairs(decoded.textures) do
    local path = sceneRoot .. "/particles/texture" .. texture.id .. ".png"
    local png = decodeTexturePng(memberBytes, texture)
    files[path] = png
    textures[#textures + 1] = {
      id = texture.id,
      format = texture.format,
      width = texture.width,
      height = texture.height,
      image = path,
      sourceHash = Hashing.sha1hex(
        memberBytes:sub(texture.texelOffset + 1, texture.texelOffset + texture.texelSize)
          .. memberBytes:sub(texture.paletteOffset + 1, texture.paletteOffset + texture.paletteSize)
      ),
    }
  end
  local byTexture = {}
  for _, texture in ipairs(textures) do
    byTexture[texture.id] = texture
  end
  local emitters = {}
  for _, emitter in ipairs(decoded.emitters) do
    if EMITTER_GROUPS[emitter.id] == nil then
      sourceError("opening scene 4 emitter is outside the nine source emitters", { emitter = emitter.id })
    end
    if emitter.id ~= #emitters then
      sourceError("opening scene 4 emitters are out of source order", {
        emitter = emitter.id,
        expected = #emitters,
      })
    end
    local texture = byTexture[emitter.textureIndex]
    if texture == nil then
      sourceError("opening scene 4 emitter references a missing particle texture", {
        emitter = emitter.id,
        texture = emitter.textureIndex,
      })
    end
    assert(texture ~= nil, "unreachable: a missing emitter texture always raises")
    -- Flag-derived geometry: the placement kind, the circle frame axis,
    -- and the draw kind. Only the observed retail combinations compile;
    -- anything else would silently mistune the replay.
    local initPosType = emitter.flag % 16
    if initPosType ~= 0 and initPosType ~= 2 and initPosType ~= 6 and initPosType ~= 7 then
      sourceError("opening scene 4 emitter uses an unrepresented placement kind", {
        emitter = emitter.id,
        placement = initPosType,
      })
    end
    local circleAxis = math.floor(emitter.flag / 64) % 4
    if circleAxis == 3 then
      sourceError("opening scene 4 emitter uses an unrepresented circle axis", {
        emitter = emitter.id,
        axis = circleAxis,
      })
    end
    local drawType = math.floor(emitter.flag / 16) % 4
    if drawType ~= 0 and drawType ~= 1 then
      sourceError("opening scene 4 emitter uses an unrepresented draw kind", {
        emitter = emitter.id,
        draw = drawType,
      })
    end
    if math.floor(emitter.flag / 4194304) % 2 == 1 then
      sourceError("opening scene 4 emitter uses an unrepresented parent draw gate", { emitter = emitter.id })
    end
    if math.floor(emitter.flag / 8388608) % 2 == 1 then
      sourceError("opening scene 4 emitter uses an unrepresented camera-relative draw", { emitter = emitter.id })
    end
    -- Bounded lifetimes and schedules: a zero generation interval or loop
    -- frame divides by zero in the retail update, and a zero lifespan
    -- divides the life-rate computation or never retires its run case.
    if emitter.generationInterval <= 0 then
      sourceError("opening scene 4 emitter carries no generation interval", { emitter = emitter.id })
    end
    if emitter.emitterLife <= 0 then
      sourceError("opening scene 4 emitter carries no emitter lifespan", { emitter = emitter.id })
    end
    if emitter.particleLife <= 0 then
      sourceError("opening scene 4 emitter carries no particle lifespan", { emitter = emitter.id })
    end
    if emitter.loopFrame <= 0 then
      sourceError("opening scene 4 emitter carries no animation loop frame", { emitter = emitter.id })
    end
    if emitter.baseAlpha > 31 then
      sourceError("opening scene 4 emitter carries no 5-bit base alpha", {
        emitter = emitter.id,
        alpha = emitter.baseAlpha,
      })
    end
    -- Unrepresented texture modes: mirrored coordinates and nonzero UV
    -- offsets have no path in the quad replay.
    if emitter.reverseTex.s or emitter.reverseTex.t then
      sourceError("opening scene 4 emitter uses mirrored texture coordinates", { emitter = emitter.id })
    end
    if emitter.offsetPos ~= 0 or emitter.offset.x ~= 0 or emitter.offset.y ~= 0 then
      sourceError("opening scene 4 emitter uses an unrepresented texture offset", { emitter = emitter.id })
    end
    local animations = {}
    if emitter.blocks.scaleOffset ~= nil then
      animations.scale = decodeScaleBlock(memberBytes, emitter.blocks.scaleOffset, emitter.id)
    end
    if emitter.blocks.colorOffset ~= nil then
      animations.color = decodeColorBlock(memberBytes, emitter.blocks.colorOffset, emitter.id)
    end
    if emitter.blocks.alphaOffset ~= nil then
      animations.alpha = decodeAlphaBlock(memberBytes, emitter.blocks.alphaOffset, emitter.id)
    end
    local child = nil
    if emitter.child ~= nil then
      child = normalizeChild(emitter.child, byTexture, emitter.id)
    end
    local fields = {}
    for _, field in ipairs(emitter.fields) do
      if field.kind == "spin" then
        local spinReader = require("libs.codec.src.BinaryReader").new(memberBytes, "spl-spin")
        local axis = spinReader:u16le(field.offset + 2)
        if axis > 2 then
          sourceError("opening scene 4 particle uses an unrepresented spin axis", {
            emitter = emitter.id,
            axis = axis,
            offset = field.offset,
          })
        end
        fields[#fields + 1] = { kind = "spin", rotation = spinReader:u16le(field.offset), axis = axis }
      else
        fields[#fields + 1] = normalizeField(field, memberBytes)
      end
    end
    emitters[#emitters + 1] = {
      id = emitter.id,
      group = EMITTER_GROUPS[emitter.id],
      emitterLife = emitter.emitterLife,
      particleLife = emitter.particleLife,
      startOffset = emitter.startOffset,
      generation = { countFx = emitter.generationCountFx, interval = emitter.generationInterval },
      initPosType = initPosType,
      circleAxis = circleAxis,
      drawType = drawType,
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
      animations = animations,
      child = child,
      fields = fields,
    }
  end
  return {
    particles = { seed = PARTICLE_SEED, emitters = emitters, textures = textures },
    files = files,
    dependencies = { particleMemberHash = Hashing.sha1hex(memberBytes) },
  }
end

---@param memberBytes string raw NARC_a_0_5_9 member 4 bytes
---@param sceneRoot string scene asset root the texture art stages under
---@return table<string, unknown>|nil
---@return Errors.Error|string|nil
function OpeningParticleCompiler.compile(memberBytes, sceneRoot)
  assert(type(memberBytes) == "string", "opening particles require the source member bytes")
  assert(type(sceneRoot) == "string" and sceneRoot ~= "", "opening particles require their scene asset root")
  -- Per-emitter failures raise with emitter context; the boundary converts
  -- structured failures back to the nil-plus-cause contract, mirroring the
  -- byte decoder below.
  local ok, first, second = pcall(function()
    return compileEmitters(memberBytes, sceneRoot)
  end)
  if ok then
    return first, second
  end
  if Errors.is(first) then
    return nil, first
  end
  error(first, 0)
end

return OpeningParticleCompiler
