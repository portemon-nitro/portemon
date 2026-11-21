-- Compiles the field models a gym mechanism loads at runtime instead of the
-- map scene placing them: the Violet Gym elevator car (build model 111), the
-- Azalea Gym Spinarak (build model 118) and the Ecruteak Gym candle (build
-- model 128). All three are ordinary interior build models of their own map
-- (src/field/gymmick/violet.c, azalea.c and ecruteak.c call
-- MapPropManager_LoadOne with the model id, the source transform and a null
-- rotation override), and all three are listed by their area's build config,
-- which is also how the source area loader registers their animations.
--
-- The Cianwood Gym winch's own animated props are the map scene's placements,
-- so only their records matter here and they already travel with the map.
--
-- The generated bundle therefore carries their normalized model definitions
-- and clips; the runtime mechanism owns nothing but the transform and the clip
-- playback it applies to them. Each model keeps exactly the one clip its source
-- anim-list record declares.

local AreaData = require("romdump.src.digest.map.AreaData")
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
  if descriptor.kind ~= "nitro-dynamic" or type(animations) ~= "table" or #animations ~= 1 then
    Errors.raise("FIELD_EFFECT_SOURCE_INVALID", "mechanism prop model must carry its one source clip", {
      key = source.key,
      mapSymbol = source.mapSymbol,
      modelMemberId = source.modelMemberId,
      kind = descriptor.kind,
      animationCount = type(animations) == "table" and #animations or 0,
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
  return { definitions = definitions, memberHashes = memberHashes }
end

return Compiler
