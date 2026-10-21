-- Compiles the source Clear Bell, corner-bell, and Ho-Oh models for the
-- Bell Tower roof cutscene.

local Errors = require("libs.errors.src.Errors")
local FieldEffectAssetCache = require("libs.assets.src.field.FieldEffectAssetCache")
local HoOhCinematicParts = require("libs.assets.src.field.HoOhCinematicParts")
local Hashing = require("romdump.src.digest.Hashing")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local G2dRasterizer = require("romdump.src.digest.ui.G2dRasterizer")
local PngWriter = require("libs.assets.src.PngWriter")
local LegendAppearanceCompiler = require("romdump.src.digest.field.LegendAppearanceCompiler")

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

local function cinematicModelList()
  local models = {}
  for _, source in ipairs(MODELS) do
    local entry = { id = source.id, memberId = source.memberId, animations = source.animations }
    models[#models + 1] = entry
  end
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
      models[#models + 1] = {
        id = string.format("cinematic.%s.%d", scene.scene, variant - 1),
        memberId = memberId,
        animations = animations,
        cinematic = true,
      }
    end
  end
  return models
end

local function readMember(archive, memberId)
  if memberId < 0 or memberId >= archive:memberCount() then
    Errors.raise("FIELD_EFFECT_SOURCE_MISSING", "Ho-Oh legend model member is unavailable", {
      archive = ARCHIVE,
      memberId = memberId,
      count = archive:memberCount(),
    })
  end
  local bytes, err = archive:readMember(memberId)
  if bytes == nil then
    Errors.raise("FIELD_EFFECT_SOURCE_MISSING", "Ho-Oh legend model member could not be read", {
      archive = ARCHIVE,
      memberId = memberId,
      error = tostring(err),
    })
  end
  return assert(bytes)
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
  local models, meshes, textures, hashes = LegendAppearanceCompiler.compileModels(romFs, {
    archive = ARCHIVE,
    cinematicArchive = CINEMATIC_ARCHIVE,
    label = "Ho-Oh",
    role = "field-effect-ho-oh-appearance",
    keyPrefix = "field-effect:ho-oh-appearance:",
    models = cinematicModelList(),
  })
  local archive, err = romFs:openNarc(ARCHIVE)
  if archive == nil then
    Errors.raise("FIELD_EFFECT_SOURCE_MISSING", "Ho-Oh legend source archive is unavailable", {
      archive = ARCHIVE,
      error = tostring(err),
    })
  end
  local leaves = romFs.version and romFs:version() == "heartgold" and compileLeaves(assert(archive), textures, hashes)
    or nil
  return {
    definitions = buildParts(models, leaves),
    meshes = meshes,
    textures = textures,
    memberHashes = hashes,
  }
end

return Compiler
