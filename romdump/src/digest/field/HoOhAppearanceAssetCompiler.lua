-- Compiles the source Clear Bell, corner-bell, and Ho-Oh models for the
-- Bell Tower roof cutscene.

local Errors = require("libs.errors.src.Errors")
local Nsbmd = require("libs.nds.src.nitro.g3d.Nsbmd")
local NitroAnimation = require("libs.nds.src.nitro.g3d.NitroAnimation")
local ModelAsset = require("libs.assets.src.model.ModelAsset")
local FieldEffectAssetCache = require("libs.assets.src.field.FieldEffectAssetCache")
local HoOhCinematicParts = require("libs.assets.src.field.HoOhCinematicParts")
local DynamicModelCompiler = require("romdump.src.digest.model.DynamicModelCompiler")
local MapPropAnimCompiler = require("romdump.src.digest.model.MapPropAnimCompiler")
local Hashing = require("romdump.src.digest.Hashing")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local G2dRasterizer = require("romdump.src.digest.ui.G2dRasterizer")
local PngWriter = require("libs.assets.src.PngWriter")
local Lz11 = require("romdump.src.digest.Lz11")

local Compiler = {}
local ARCHIVE = "NARC_demo_legend"
local CINEMATIC_ARCHIVE = "NARC_a_2_4_3"
local MODELS = {
  {
    id = "bellRising",
    memberId = 18,
    animations = {
      { memberId = 19, format = "NSBCA", id = "bell.rise.joint", category = "joint", kind = "trs" },
      { memberId = 20, format = "NSBTP", id = "bell.rise.pattern", category = "material", kind = "pattern" },
      { memberId = 21, format = "NSBTA", id = "bell.rise.srt", category = "material", kind = "texsrt" },
      { memberId = 22, format = "NSBCA", id = "bell.loop.joint", category = "joint", kind = "trs" },
      { memberId = 23, format = "NSBTP", id = "bell.loop.pattern", category = "material", kind = "pattern" },
      { memberId = 24, format = "NSBTA", id = "bell.loop.srt", category = "material", kind = "texsrt" },
    },
  },
  {
    id = "bellShimmer",
    memberId = 25,
    animations = {
      { memberId = 26, format = "NSBCA", id = "bell.shimmer.joint", category = "joint", kind = "trs" },
      { memberId = 27, format = "NSBTA", id = "bell.shimmer.srt", category = "material", kind = "texsrt" },
    },
  },
  {
    id = "cornerBells",
    memberId = 32,
    animations = {
      { memberId = 33, format = "NSBTA", id = "corner_bells.srt", category = "material", kind = "texsrt" },
    },
  },
  {
    id = "birdApproach",
    memberId = 34,
    animations = {
      { memberId = 35, format = "NSBCA", id = "bird.joint", category = "joint", kind = "trs" },
      { memberId = 36, format = "NSBMA", id = "bird.color", category = "material", kind = "color" },
      { memberId = 37, format = "NSBTP", id = "bird.pattern", category = "material", kind = "pattern" },
    },
  },
  {
    id = "wavesEffect",
    memberId = 38,
    animations = {
      { memberId = 39, format = "NSBCA", id = "waves.joint", category = "joint", kind = "trs" },
      { memberId = 40, format = "NSBTA", id = "waves.srt", category = "material", kind = "texsrt" },
    },
  },
}
local LEAF_MEMBERS = {
  { name = "bg2", members = { 41, 42, 43, 44, 45, 46 } },
  { name = "bg3", members = { 47, 48, 49, 50, 51, 52 } },
}

local CINEMATIC_MODELS = {
  {
    scene = "first",
    modelMembers = { 0, 5, 10 },
    animationFormats = { "NSBCA", "NSBMA", "NSBTA", "NSBTP" },
  },
  {
    scene = "second",
    modelMembers = { 15, 19, 23 },
    animationFormats = { "NSBCA", "NSBMA", "NSBTA" },
  },
}

local function readMember(archive, memberId, archiveName)
  archiveName = archiveName or ARCHIVE
  if memberId < 0 or memberId >= archive:memberCount() then
    Errors.raise("FIELD_EFFECT_SOURCE_MISSING", "Ho-Oh legend model member is unavailable", {
      archive = archiveName,
      memberId = memberId,
      count = archive:memberCount(),
    })
  end
  local bytes, err = archive:readMember(memberId)
  if bytes == nil then
    Errors.raise("FIELD_EFFECT_SOURCE_MISSING", "Ho-Oh legend model member could not be read", {
      archive = archiveName,
      memberId = memberId,
      error = tostring(err),
    })
  end
  return assert(bytes)
end

local function decodeSourceMember(bytes, archiveName, memberId)
  if archiveName ~= CINEMATIC_ARCHIVE then
    return bytes
  end
  local decoded, err = Lz11.decode(bytes)
  if decoded == nil then
    Errors.raise("FIELD_EFFECT_SOURCE_INVALID", "Ho-Oh cinematic member could not be decompressed", {
      archive = archiveName,
      memberId = memberId,
      error = tostring(err),
    })
  end
  return assert(decoded)
end

local function compileAnimation(archive, source, hashes, archiveName)
  archiveName = archiveName or ARCHIVE
  local sourceBytes = readMember(archive, source.memberId, archiveName)
  local bytes = decodeSourceMember(sourceBytes, archiveName, source.memberId)
  local decoded, err = NitroAnimation.decode(bytes, { alias = archiveName, memberId = source.memberId })
  if
    not decoded
    or decoded.format ~= source.format
    or type(decoded.animations) ~= "table"
    or #decoded.animations ~= 1
  then
    Errors.raise("FIELD_EFFECT_SOURCE_INVALID", "Ho-Oh legend animation has an unexpected Nitro format", {
      archive = archiveName,
      memberId = source.memberId,
      expectedFormat = source.format,
      actualFormat = decoded and decoded.format or "unreadable",
      error = tostring(err),
    })
  end
  decoded = assert(decoded)
  local animation = assert(decoded.animations[1])
  local clip = MapPropAnimCompiler.compileDecoded(decoded, {
    name = animation.name,
    id = source.id,
    source = {
      type = "nitro",
      format = source.format,
      archive = archiveName,
      memberId = source.memberId,
      sha1 = Hashing.sha1hex(sourceBytes),
    },
  })
  clip.id = source.id
  clip.semanticNames = { source.id }
  clip.source = nil
  assert(clip.category == source.category and clip.kind == source.kind, "Ho-Oh animation kind changed")
  hashes[#hashes + 1] = {
    archive = archiveName,
    memberId = source.memberId,
    sha1 = Hashing.sha1hex(sourceBytes),
  }
  return clip
end

local function rewritePaths(descriptor)
  for _, batch in ipairs(descriptor.dynamic.batches) do
    local sha1 = assert(batch.geometry:match("/([^/]+)%.g4mesh$"), "Ho-Oh model geometry path is malformed")
    batch.geometry = FieldEffectAssetCache.geometryPath(sha1)
  end
  for _, material in ipairs(descriptor.materials) do
    if material.texture then
      local sha1 = assert(material.texture:match("/([^/]+)%.png$"), "Ho-Oh model texture path is malformed")
      material.texture = FieldEffectAssetCache.texturePath(sha1)
    end
    for _, variant in ipairs(material.variants or {}) do
      if variant.texture then
        local sha1 = assert(variant.texture:match("/([^/]+)%.png$"), "Ho-Oh variant texture path is malformed")
        variant.texture = FieldEffectAssetCache.texturePath(sha1)
      end
    end
  end
end

local function compileModel(archive, source, meshes, textures, hashes, archiveName)
  archiveName = archiveName or ARCHIVE
  local sourceBytes = readMember(archive, source.memberId, archiveName)
  local modelBytes = decodeSourceMember(sourceBytes, archiveName, source.memberId)
  local decoded, err = Nsbmd.decode(modelBytes, { alias = archiveName, memberId = source.memberId })
  if not decoded or not decoded.models[1] or not decoded.embeddedTextures then
    Errors.raise("FIELD_EFFECT_SOURCE_INVALID", "Ho-Oh legend model has no geometry or embedded textures", {
      archive = archiveName,
      memberId = source.memberId,
      error = tostring(err),
    })
  end
  decoded = assert(decoded)
  hashes[#hashes + 1] = { archive = archiveName, memberId = source.memberId, sha1 = Hashing.sha1hex(sourceBytes) }
  local clips = {}
  for _, animation in ipairs(source.animations) do
    clips[#clips + 1] = compileAnimation(archive, animation, hashes, archiveName)
  end
  local model = assert(decoded.models[1])
  local descriptor, unresolved = DynamicModelCompiler.compile(
    model,
    decoded,
    decoded.embeddedTextures,
    { clips = clips },
    {
      role = "field-effect-ho-oh-appearance",
      modelArchive = archiveName,
      modelMemberId = source.memberId,
      modelName = model.name,
      textureArchive = archiveName,
      textureMemberId = source.memberId,
    },
    source.memberId,
    textures,
    meshes
  )
  if #unresolved > 0 then
    Errors.raise("FIELD_EFFECT_SOURCE_INVALID", "Ho-Oh legend model has unresolved material resources", {
      archive = archiveName,
      memberId = source.memberId,
      unresolved = unresolved,
    })
  end
  descriptor.key = "field-effect:ho-oh-appearance:" .. source.id
  rewritePaths(descriptor)
  ModelAsset.validate(descriptor)
  return descriptor
end

local function compileCinematicModels(romFs, meshes, textures, hashes, models)
  local archive, err = romFs:openNarc(CINEMATIC_ARCHIVE)
  if archive == nil then
    Errors.raise("FIELD_EFFECT_SOURCE_MISSING", "Ho-Oh cinematic model archive is unavailable", {
      archive = CINEMATIC_ARCHIVE,
      error = tostring(err),
    })
  end
  archive = assert(archive)
  for _, scene in ipairs(CINEMATIC_MODELS) do
    for variant, memberId in ipairs(scene.modelMembers) do
      local animations = {}
      for index, format in ipairs(scene.animationFormats) do
        local category, kind
        if format == "NSBCA" then
          category, kind = "joint", "trs"
        elseif format == "NSBMA" then
          category, kind = "material", "color"
        elseif format == "NSBTP" then
          category, kind = "material", "pattern"
        else
          assert(format == "NSBTA", "unknown Ho-Oh cinematic animation format")
          category, kind = "material", "texsrt"
        end
        animations[#animations + 1] = {
          memberId = memberId + index,
          format = format,
          id = string.format("cinematic.%s.%d.%s", scene.scene, variant - 1, kind),
          category = category,
          kind = kind,
        }
      end
      models[#models + 1] = compileModel(archive, {
        id = string.format("cinematic.%s.%d", scene.scene, variant - 1),
        memberId = memberId,
        animations = animations,
      }, meshes, textures, hashes, CINEMATIC_ARCHIVE)
    end
  end
end

local function decodeG2d(archive, memberId, decoder, label)
  local value, err = decoder(readMember(archive, memberId), { label = ARCHIVE .. ":" .. memberId })
  if value == nil then
    Errors.raise("FIELD_EFFECT_SOURCE_INVALID", "Ho-Oh leaf resource could not be decoded", {
      archive = ARCHIVE,
      memberId = memberId,
      role = label,
      error = tostring(err),
    })
  end
  return assert(value)
end

local function compileLeaves(archive, textures, hashes)
  local charData = decodeG2d(archive, 53, G2dDecoder.decodeChar, "character tiles")
  local palette = decodeG2d(archive, 54, G2dDecoder.decodePalette, "palette")
  hashes[#hashes + 1] = { archive = ARCHIVE, memberId = 53, sha1 = Hashing.sha1hex(readMember(archive, 53)) }
  hashes[#hashes + 1] = { archive = ARCHIVE, memberId = 54, sha1 = Hashing.sha1hex(readMember(archive, 54)) }
  local layers = {}
  for _, layerSource in ipairs(LEAF_MEMBERS) do
    local layerName, memberIds = layerSource.name, layerSource.members
    local frames = {}
    for frameIndex, memberId in ipairs(memberIds) do
      local screen = decodeG2d(archive, memberId, G2dDecoder.decodeScreen, layerName .. " tilemap")
      if screen.width ~= 256 or screen.height ~= 256 then
        Errors.raise("FIELD_EFFECT_SOURCE_INVALID", "Ho-Oh leaf tilemap is not a 32 by 32 screen", {
          archive = ARCHIVE,
          memberId = memberId,
          width = screen.width,
          height = screen.height,
        })
      end
      for _, entry in ipairs(screen.entries) do
        -- Retail loads this NCLR at VRAM offset 0xC0 (slot 6), but its
        -- resource contains palette bank 0, which the tilemap entries select.
        entry.palette = 0
      end
      local image = G2dRasterizer.renderScreen(charData, palette, screen, {
        asset = ARCHIVE,
        member = memberId,
        role = layerName,
      })
      local png = PngWriter.encode(image.width, image.height, image.pixels)
      local sha1 = Hashing.sha1hex(png)
      textures[sha1] = { data = png, width = image.width, height = image.height }
      hashes[#hashes + 1] = {
        archive = ARCHIVE,
        memberId = memberId,
        sha1 = Hashing.sha1hex(readMember(archive, memberId)),
      }
      frames[frameIndex] =
        { path = FieldEffectAssetCache.texturePath(sha1), width = image.width, height = image.height }
    end
    layers[layerName] = { frames = frames }
  end
  return layers
end

-- Publishes the eleven compiled models in parts: the core (five models, the
-- leaf overlay and the clip summary), and per cinematic shot one shared part
-- plus one overlay per variant. Variants that differ beyond the stored
-- strings fail the build (HoOhCinematicParts.split).
local function buildParts(models, leaves)
  local coreModels, frames = {}, {}
  for index = 1, #MODELS do
    coreModels[index] = models[index]
    for _, clip in ipairs(models[index].animations) do
      frames[clip.id] = clip.frameCount
    end
  end
  local definitions, cinematic = {}, {}
  local cursor = #MODELS
  for _, scene in ipairs(CINEMATIC_MODELS) do
    local variantModels = {}
    for variant = 1, #scene.modelMembers do
      cursor = cursor + 1
      variantModels[variant] = models[cursor]
    end
    local shared, overlays = HoOhCinematicParts.split(scene.scene, variantModels)
    definitions[FieldEffectAssetCache.hoOhCinematicKind(scene.scene)] = shared
    local longest = 0
    for _, clip in ipairs(shared.animations) do
      longest = math.max(longest, clip.frameCount)
    end
    cinematic[scene.scene] = {}
    for variant, overlay in ipairs(overlays) do
      definitions[FieldEffectAssetCache.hoOhCinematicKind(scene.scene, variant - 1)] = overlay
      cinematic[scene.scene][variant] = longest
    end
  end
  definitions.ho_oh_appearance =
    { models = coreModels, leaves = leaves, clips = { frames = frames, cinematic = cinematic } }
  return definitions
end

function Compiler.compile(romFs)
  assert(romFs and romFs.openNarc, "Ho-Oh appearance compiler requires RomFs")
  local archive, err = romFs:openNarc(ARCHIVE)
  if archive == nil then
    Errors.raise("FIELD_EFFECT_SOURCE_MISSING", "Ho-Oh legend source archive is unavailable", {
      archive = ARCHIVE,
      error = tostring(err),
    })
  end
  local meshes, textures, hashes, models = {}, {}, {}, {}
  for _, source in ipairs(MODELS) do
    models[#models + 1] = compileModel(archive, source, meshes, textures, hashes)
  end
  compileCinematicModels(romFs, meshes, textures, hashes, models)
  local leaves = romFs.version and romFs:version() == "heartgold" and compileLeaves(archive, textures, hashes) or nil
  return {
    definitions = buildParts(models, leaves),
    meshes = meshes,
    textures = textures,
    memberHashes = hashes,
  }
end

return Compiler
