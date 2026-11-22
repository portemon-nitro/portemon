-- Compiles the field models a gym mechanism loads at runtime instead of the
-- map scene placing them: the Violet Gym elevator car (build model 111), the
-- Azalea Gym Spinarak (build model 118), the Ecruteak Gym candle (build model
-- 128) and the Blackthorn Gym platforms (build models 120 and 121). All of them
-- are ordinary interior build models of their own map (src/field/gymmick/
-- violet.c, azalea.c, ecruteak.c and blackthorn.c call MapPropManager_LoadOne
-- with the model id, the source transform and a null rotation override), and all
-- of them are listed by their area's build config, which is also how the source
-- area loader registers their animations.
--
-- The Cianwood Gym winch's own animated props are the map scene's placements,
-- so only their records matter here and they already travel with the map.
--
-- The generated bundle therefore carries their normalized model definitions
-- and clips; the runtime mechanism owns nothing but the transform and the clip
-- playback it applies to them. Each model keeps exactly the one clip its source
-- anim-list record declares, and none at all when its area registers no record
-- for it: the Blackthorn platforms are plain static build models the mechanism
-- only ever translates and rotates.

local AreaData = require("romdump.src.digest.map.AreaData")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local G2dRasterizer = require("romdump.src.digest.ui.G2dRasterizer")
local Hashing = require("romdump.src.digest.Hashing")
local LegendAppearanceCompiler = require("romdump.src.digest.field.LegendAppearanceCompiler")
local PngWriter = require("romdump.src.digest.PngEncoder")
local BuildingModelCompiler = require("romdump.src.digest.map.BuildingModelCompiler")
local Errors = require("libs.errors.src.Errors")
local FieldEffectAssetCache = require("libs.assets.src.field.FieldEffectAssetCache")
local FieldEffects = require("romdump.src.config.FieldEffects")
local LandData = require("romdump.src.digest.map.LandData")
local MapResolver = require("romdump.src.digest.map.MapResolver")
local ModelAsset = require("libs.assets.src.model.ModelAsset")

local Compiler = {}

local function member(romFs, alias, memberId)
  local narc = assert(romFs:openNarc(alias))
  if memberId < 0 or memberId >= narc:memberCount() then
    Errors.raise("FIELD_EFFECT_SOURCE_MISSING", "mechanism prop source member is unavailable", {
      archive = alias,
      memberId = memberId,
      count = narc:memberCount(),
    })
  end
  return assert(narc:readMember(memberId))
end

-- One source prop: resolve its map, then compile the single build model the
-- mechanism loads from that map's own archives.
local function compileProp(romFs, source, meshes, textures)
  local resolved, resolveErr = MapResolver.resolve(romFs, source.mapSymbol)
  if not resolved then
    error(resolveErr, 0)
  end
  local area = assert(AreaData.decode(member(romFs, "area_data", resolved.areaDataMemberId), {
    alias = "area_data",
    memberId = resolved.areaDataMemberId,
  }))
  local land = assert(LandData.decode(member(romFs, "land_data", resolved.landDataMemberId), {
    mapId = resolved.map.id,
    alias = "land_data",
    memberId = resolved.landDataMemberId,
  }))
  -- The prop has no generated placement: only the selected model is compiled,
  -- exactly like the source loading it by build model over its own transform.
  local selectedLand = {}
  for key, value in pairs(land) do
    selectedLand[key] = value
  end
  selectedLand.buildings = {}
  local compiled = BuildingModelCompiler.compile(romFs, area, selectedLand, {
    mapId = resolved.map.id,
    mapSymbol = resolved.map.symbol,
    areaDataMemberId = resolved.areaDataMemberId,
    landDataMemberId = resolved.landDataMemberId,
    meshes = meshes,
    textures = textures,
    finalizeMeshes = true,
    requiredModelMembers = { source.modelMemberId },
  })
  local modelKey =
    assert(compiled.modelKeyOf[source.modelMemberId], "mechanism prop model did not compile: " .. source.key)
  local descriptor = assert(compiled.models[modelKey], "mechanism prop descriptor is missing: " .. source.key)
  local animations = descriptor.animations
  if descriptor.kind == "nitro-dynamic" then
    if type(animations) ~= "table" or #animations ~= 1 then
      Errors.raise("FIELD_EFFECT_SOURCE_INVALID", "mechanism prop model must carry its one source clip", {
        key = source.key,
        mapSymbol = source.mapSymbol,
        modelMemberId = source.modelMemberId,
        kind = descriptor.kind,
        animationCount = type(animations) == "table" and #animations or 0,
      })
    end
  elseif descriptor.kind ~= "static" then
    Errors.raise("FIELD_EFFECT_SOURCE_INVALID", "mechanism prop model must be a normalized model", {
      key = source.key,
      mapSymbol = source.mapSymbol,
      modelMemberId = source.modelMemberId,
      kind = descriptor.kind,
    })
  end
  -- The generated definition travels with the field-effect family, so its
  -- key is the semantic effect kind and never the map placement identity.
  descriptor.key = "field-effect:" .. source.key
  FieldEffectAssetCache.rewriteModelPaths(descriptor)
  ModelAsset.validate(descriptor)
  return {
    definition = { model = descriptor },
    hashes = {
      models = compiled.buildingModelShas,
      animations = compiled.animationListMemberSha1s,
      textures = {
        {
          memberId = area.buildingTexturePackId,
          sha1 = assert(compiled.buildingTextureMemberSha1, "mechanism prop texture pack has no source digest"),
        },
      },
    },
  }
end

-- One compiled mechanism prop: the generated effect definition the family
-- publishes for it, keyed by its semantic effect kind.
---@class MechanismPropDefinition
---@field model table<string, unknown> the normalized nitro-dynamic model descriptor

-- The Rocket hideout's own script-driven effects: the three trap models with
-- their source clips out of the demo/legend archive
-- (src/field/script_field_effects.c sTrapEffects) and the alarm's red overlay,
-- whose palette, character data and tilemap the source loads into the main BG1
-- (Task_ShowHideoutAlarm). The overlay is rasterized once here so the runtime
-- only ever draws a prepared image.
---@param romFs table<string, unknown>
---@param meshes table<string, unknown>
---@param textures table<string, unknown>
---@param memberHashes table[]
---@return table<string, table<string, unknown>> definitions by semantic kind
local function compileHideoutEffects(romFs, meshes, textures, memberHashes)
  local archiveName = FieldEffects.hideoutEffectArchive
  local models, modelMeshes, modelTextures, modelHashes = LegendAppearanceCompiler.compileModels(romFs, {
    archive = archiveName,
    cinematicArchive = archiveName,
    label = "Rocket hideout",
    role = "field-effect-rocket-hideout",
    keyPrefix = "field-effect:rocket-hideout:",
    models = FieldEffects.hideoutTrapModels,
  })
  -- The legend compiler owns its own accumulators; the effect bundle publishes
  -- one shared set, so both the bytes and the provenance join it here.
  for sha1, mesh in pairs(modelMeshes) do
    meshes[sha1] = mesh
  end
  for sha1, texture in pairs(modelTextures) do
    textures[sha1] = texture
  end
  for _, entry in ipairs(modelHashes) do
    memberHashes[#memberHashes + 1] = entry
  end
  local definitions = {}
  for index, source in ipairs(FieldEffects.hideoutTrapModels) do
    local descriptor = assert(models[index], "hideout trap model did not compile: " .. source.key)
    descriptor.key = "field-effect:" .. source.key
    -- One source anim-list record names one animation for every channel kind it
    -- carries, so a poison trap's joint and colour clips share their source
    -- name. A runtime model keeps unique clip names, so the channel kind
    -- qualifies a shared name; each clip keeps its own semantic identity.
    local seen = {}
    for _, clip in ipairs(descriptor.animations or {}) do
      if seen[clip.name] ~= nil then
        clip.name = clip.name .. "." .. clip.kind
      end
      seen[clip.name] = true
    end
    definitions[source.key] = { model = descriptor }
  end
  local overlay = FieldEffects.hideoutAlarmOverlay
  local archive = assert(romFs:openNarc(archiveName), "the hideout effect archive is unavailable")
  local function read(memberId, decode, label)
    if memberId < 0 or memberId >= archive:memberCount() then
      Errors.raise("FIELD_EFFECT_SOURCE_MISSING", "hideout effect source member is unavailable", {
        archive = archiveName,
        memberId = memberId,
        count = archive:memberCount(),
        role = label,
      })
    end
    local bytes = assert(archive:readMember(memberId), "hideout effect source member is unreadable")
    memberHashes[#memberHashes + 1] = { archive = archiveName, memberId = memberId, sha1 = Hashing.sha1hex(bytes) }
    local decoded, err = decode(bytes, { asset = archiveName, member = memberId, role = label })
    if decoded == nil then
      Errors.raise("FIELD_EFFECT_SOURCE_INVALID", "hideout effect source member could not be decoded", {
        archive = archiveName,
        memberId = memberId,
        role = label,
        error = tostring(err),
      })
    end
    return decoded
  end
  -- The reader raises on a member it could not decode, so every record below
  -- is present; the asserts state that contract at the point it is consumed.
  local charData = assert(read(overlay.charMemberId, G2dDecoder.decodeChar, "alarm character data"))
  local palette = assert(read(overlay.paletteMemberId, G2dDecoder.decodePalette, "alarm palette"))
  local screen = assert(read(overlay.screenMemberId, G2dDecoder.decodeScreen, "alarm tilemap"))
  local image = G2dRasterizer.renderScreen(charData, palette, screen, {
    asset = archiveName,
    member = overlay.screenMemberId,
    role = "alarm overlay",
  }, { backdrop = true })
  local png = PngWriter.encode(image.width, image.height, image.pixels)
  local sha1 = Hashing.sha1hex(png)
  textures[sha1] = { data = png, width = image.width, height = image.height }
  definitions[overlay.key] = {
    overlay = {
      texture = FieldEffectAssetCache.texturePath(sha1),
      width = image.width,
      height = image.height,
    },
  }
  return definitions
end

---@param romFs table<string, unknown>
---@param meshes table<string, unknown> shared mesh accumulator
---@param textures table<string, unknown> shared texture accumulator
---@return { definitions: table<string, MechanismPropDefinition>, memberHashes: table[] }
function Compiler.compile(romFs, meshes, textures)
  assert(romFs and romFs.openNarc, "mechanism prop compiler requires RomFs")
  assert(
    type(meshes) == "table" and type(textures) == "table",
    "mechanism prop compilation requires the shared asset accumulators"
  )
  local definitions, memberHashes = {}, {}
  for _, source in ipairs(FieldEffects.mechanismPropModels) do
    local compiled = compileProp(romFs, source, meshes, textures)
    definitions[source.key] = compiled.definition
    for _, group in ipairs({ compiled.hashes.models, compiled.hashes.animations, compiled.hashes.textures }) do
      for _, entry in ipairs(group) do
        memberHashes[#memberHashes + 1] = entry
      end
    end
  end
  for kind, definition in pairs(compileHideoutEffects(romFs, meshes, textures, memberHashes)) do
    definitions[kind] = definition
  end
  return { definitions = definitions, memberHashes = memberHashes }
end

return Compiler
