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
local PngWriter = require("libs.assets.src.PngWriter")
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

-- Compile the starter emitter set from the raw scene 4 SPL member into
-- normalized per-emitter emission records plus staged texture art. The
-- member must carry exactly the nine retail starter emitters; the texture
-- chosen by each emitter's own texture index stages under the scene 4
-- asset root. Returns the normalized particle set, its staged files, and
-- the producer dependencies for the job receipt.
---@param memberBytes string raw NARC_a_0_5_9 member 4 bytes
---@param sceneRoot string scene asset root the texture art stages under
---@return table<string, unknown>|nil
---@return Errors.Error|string|nil
function OpeningParticleCompiler.compile(memberBytes, sceneRoot)
  assert(type(memberBytes) == "string", "opening particles require the source member bytes")
  assert(type(sceneRoot) == "string" and sceneRoot ~= "", "opening particles require their scene asset root")
  local decoded, decodeErr = SplResource.decode(memberBytes)
  if decoded == nil then
    return nil, decodeErr
  end
  if #decoded.emitters ~= 9 then
    return nil,
      Errors.new(
        OpeningParticleCompiler.ERROR.SOURCE_INVALID,
        "opening scene 4 particle member carries no nine starter emitters",
        { emitters = #decoded.emitters }
      )
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
      return nil,
        Errors.new(
          OpeningParticleCompiler.ERROR.SOURCE_INVALID,
          "opening scene 4 emitter is outside the nine source emitters",
          { emitter = emitter.id }
        )
    end
    if emitter.id ~= #emitters then
      return nil,
        Errors.new(
          OpeningParticleCompiler.ERROR.SOURCE_INVALID,
          "opening scene 4 emitters are out of source order",
          { emitter = emitter.id, expected = #emitters }
        )
    end
    local texture = byTexture[emitter.textureIndex]
    if texture == nil then
      return nil,
        Errors.new(
          OpeningParticleCompiler.ERROR.SOURCE_INVALID,
          "opening scene 4 emitter references a missing particle texture",
          { emitter = emitter.id, texture = emitter.textureIndex }
        )
    end
    local fields = {}
    for _, field in ipairs(emitter.fields) do
      fields[#fields + 1] = normalizeField(field, memberBytes)
    end
    emitters[#emitters + 1] = {
      id = emitter.id,
      group = EMITTER_GROUPS[emitter.id],
      emitterLife = emitter.emitterLife,
      particleLife = emitter.particleLife,
      generation = { count = emitter.generationCount, interval = emitter.generationInterval },
      radius = emitter.radius,
      length = emitter.length,
      position = emitter.position,
      axis = emitter.axis,
      baseColor = emitter.baseColor,
      baseAlpha = emitter.baseAlpha,
      baseScale = emitter.baseScale,
      velocity = { initial = emitter.initialVelocity, axis = emitter.initialAxisVelocity },
      rotation = { min = emitter.rotationMin, max = emitter.rotationMax },
      texture = texture.id,
      textureImage = texture.image,
      animations = {
        scale = emitter.blocks.scaleOffset ~= nil,
        color = emitter.blocks.colorOffset ~= nil,
        alpha = emitter.blocks.alphaOffset ~= nil,
      },
      fields = fields,
    }
  end
  return {
    particles = { seed = PARTICLE_SEED, emitters = emitters, textures = textures },
    files = files,
    dependencies = { particleMemberHash = Hashing.sha1hex(memberBytes) },
  }
end

return OpeningParticleCompiler
