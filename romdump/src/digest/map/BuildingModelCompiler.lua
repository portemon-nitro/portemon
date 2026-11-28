-- Compiles placed building models, animations, placements, and dependencies.

local BinaryReader = require("libs.codec.src.BinaryReader")
local Nsbmd = require("libs.nds.src.nitro.g3d.Nsbmd")
local Nsbtx = require("libs.nds.src.nitro.g3d.Nsbtx")
local BuildingTransform = require("romdump.src.digest.map.BuildingTransform")
local Hashing = require("romdump.src.digest.Hashing")
local ModelAssetCompiler = require("romdump.src.digest.model.ModelAssetCompiler")
local DynamicModelCompiler = require("romdump.src.digest.model.DynamicModelCompiler")
local MapPropAnimCompiler = require("romdump.src.digest.model.MapPropAnimCompiler")
local ModelAsset = require("libs.assets.src.model.ModelAsset")
local Errors = require("libs.errors.src.Errors")

local BuildingModelCompiler = {}

-- src/field/gymmick/cianwood.c::CianwoodGymmick_RebindAnims binds 174's
-- animation records onto render object 173 and awaits 175's record 0. The
-- generated target definitions own those exact clips so runtime playback never
-- attaches a foreign object or depends on 174 having a map placement.
local CIANWOOD_WATER_MEMBER = 173
local CIANWOOD_WATER_SOURCE_MEMBER = 174
local CIANWOOD_WINCH_MEMBER = 175
local CIANWOOD_WATER_CLIP_PREFIX = "cianwood.water."
local CIANWOOD_WINCH_CLIP_PREFIX = "cianwood.winch.0."

local function copyClipWithId(clip, id)
  local copy = {}
  for key, value in pairs(clip) do
    copy[key] = value
  end
  copy.id = id
  return copy
end

local function readMember(narc, alias, memberId)
  local count = narc:memberCount()
  assert(
    memberId >= 0 and memberId < count,
    string.format("%s member %d out of range (count %d)", alias, memberId, count)
  )
  return assert(narc:readMember(memberId))
end

-- HGSS instantiates only the props the area's build config lists (a u16 count
-- then the ids, the member of the area's prop pack id). A placement of any
-- other model draws model 0, the dummy box, bound to its own embedded TEX0.
local DUMMY_MEMBER = 0

local function loadedPropIds(romFs, area)
  local bytes = readMember(assert(romFs:openNarc("area_build_config")), "area_build_config", area.buildingTexturePackId)
  local reader = BinaryReader.new(bytes, "area_build_config")
  local loaded = {}
  for index = 0, reader:u16le(0) - 1 do
    loaded[reader:u16le(2 + index * 2)] = true
  end
  return loaded
end

local function sortedNumbers(set)
  local out = {}
  for value in pairs(set) do
    out[#out + 1] = value
  end
  table.sort(out)
  return out
end

local function archiveForArea(area)
  if area.areaType == "indoor" then
    return "interior_build_models"
  end
  if area.areaType == "outdoor" then
    return "exterior_build_models"
  end
  Errors.raise(
    "MAP_COMPILE_UNSUPPORTED_AREA",
    "unsupported area type for building model selection: " .. tostring(area.areaTypeRaw),
    { areaTypeRaw = area.areaTypeRaw }
  )
end

local function animListAliasForArea(area)
  if area.areaType == "indoor" then
    return "interior_build_anim_list"
  end
  if area.areaType == "outdoor" then
    return "exterior_build_anim_list"
  end
  Errors.raise(
    "MAP_COMPILE_UNSUPPORTED_AREA",
    "unsupported area type for building animation selection: " .. tostring(area.areaTypeRaw),
    { areaTypeRaw = area.areaTypeRaw }
  )
end

local function appendUnresolved(target, source)
  for _, entry in ipairs(source.unresolved) do
    target[#target + 1] = entry
  end
end

local function modelContext(opts, area, archiveAlias, memberId, buildingNsbmd, buildingModel, placementIndices)
  return {
    mapId = opts.mapId,
    mapSymbol = opts.mapSymbol,
    role = "building",
    areaDataMemberId = opts.areaDataMemberId,
    landDataMemberId = opts.landDataMemberId,
    textureArchive = "building_textures",
    textureMemberId = area.buildingTexturePackId,
    modelArchive = archiveAlias,
    modelMemberId = memberId,
    modelName = buildingModel.name,
    embeddedTex0Present = buildingNsbmd.embeddedTextures ~= nil,
    placementIndices = placementIndices,
    finalizeMeshes = opts.finalizeMeshes,
    geometryArena = opts.geometryArena,
    gxScratch = opts.gxScratch,
  }
end

---@param romFs RomFs
---@param area table<string, unknown>
---@param land table<string, unknown>
---@param opts table<string, unknown>
---@return table<string, unknown>
function BuildingModelCompiler.compile(romFs, area, land, opts)
  assert(type(opts) == "table" and opts.meshes and opts.textures, "building compilation requires accumulators")
  local archiveAlias = archiveForArea(area)
  local loadedProps = #land.buildings > 0 and loadedPropIds(romFs, area) or {}
  local function placedMember(placement)
    return loadedProps[placement.modelMemberId] and placement.modelMemberId or DUMMY_MEMBER
  end
  local uniqueMembers, placementIndicesByMember = {}, {}
  for _, placement in ipairs(land.buildings) do
    local memberId = placedMember(placement)
    uniqueMembers[memberId] = true
    local indices = placementIndicesByMember[memberId] or {}
    indices[#indices + 1] = placement.index
    placementIndicesByMember[memberId] = indices
  end
  for _, memberId in ipairs(opts.requiredModelMembers or {}) do
    uniqueMembers[memberId] = true
  end
  local memberIds = sortedNumbers(uniqueMembers)

  local bldNarc, bldTexPack, bldTexSha1
  if #memberIds > 0 then
    bldNarc = assert(romFs:openNarc(archiveAlias))
    local bldTexBytes =
      readMember(assert(romFs:openNarc("building_textures")), "building_textures", area.buildingTexturePackId)
    bldTexSha1 = Hashing.sha1hex(bldTexBytes)
    bldTexPack =
      assert(Nsbtx.decode(bldTexBytes, { alias = "building_textures", memberId = area.buildingTexturePackId }))
  end

  local animListNarc, animResNarc
  if #memberIds > 0 then
    animListNarc = assert(romFs:openNarc(animListAliasForArea(area)))
    animResNarc = assert(romFs:openNarc("build_anim"))
  end

  local models, modelKeyOf, memberShaOf = {}, {}, {}
  local unresolvedMaterials, animDeps = {}, {}
  local animResults = {}
  local function animationsFor(memberId)
    if animResults[memberId] ~= nil then
      return animResults[memberId]
    end
    assert(memberId < animListNarc:memberCount(), "building animation source member is unavailable")
    local listBytes = assert(animListNarc:readMember(memberId))
    animDeps[#animDeps + 1] = { memberId = memberId, sha1 = Hashing.sha1hex(listBytes) }
    local result = MapPropAnimCompiler.compile(listBytes, animResNarc, {
      archiveAlias = animListAliasForArea(area),
      memberId = memberId,
      resourceCache = opts.resourceCache,
    })
    for _, clip in ipairs(result.clips) do
      animDeps[#animDeps + 1] = { resourceId = clip.source.memberId, sha1 = clip.source.sha1 }
    end
    animResults[memberId] = result
    return result
  end

  for _, memberId in ipairs(memberIds) do
    local modelBytes = readMember(bldNarc, archiveAlias, memberId)
    local modelSha1 = Hashing.sha1hex(modelBytes)
    local buildingNsbmd = assert(Nsbmd.decode(modelBytes, { alias = archiveAlias, memberId = memberId }))
    local buildingModel = buildingNsbmd.models[1]
    local context =
      modelContext(opts, area, archiveAlias, memberId, buildingNsbmd, buildingModel, placementIndicesByMember[memberId])
    local texturePack = bldTexPack
    if memberId == DUMMY_MEMBER then
      texturePack = assert(buildingNsbmd.embeddedTextures, "the dummy box carries its own TEX0")
    end
    local modelDescriptor
    local animated = false
    if memberId < animListNarc:memberCount() then
      local animResult = animationsFor(memberId)
      -- The Cianwood rebinding is scoped to the indoor building archive:
      -- 173/175 are the Cianwood objects in the indoor archive, not a
      -- global member identity across indoor and outdoor archives.
      local isIndoorArchive = archiveAlias == "interior_build_models"
      if memberId == CIANWOOD_WATER_MEMBER and isIndoorArchive then
        local source = animationsFor(CIANWOOD_WATER_SOURCE_MEMBER)
        local clips = {}
        for _, clip in ipairs(animResult.clips) do
          clips[#clips + 1] = clip
        end
        for recordIndex, clip in ipairs(source.clips) do
          clips[#clips + 1] =
            copyClipWithId(clip, string.format("%s%d.%s", CIANWOOD_WATER_CLIP_PREFIX, recordIndex, clip.id))
        end
        animResult = { clips = clips, doorSoundType = animResult.doorSoundType }
      elseif memberId == CIANWOOD_WINCH_MEMBER and isIndoorArchive then
        assert(#animResult.clips > 0, "the Cianwood winch carries source record 0")
        animResult.clips[1].id = CIANWOOD_WINCH_CLIP_PREFIX .. animResult.clips[1].id
      end
      if #animResult.clips > 0 then
        local descriptor, unresolved = DynamicModelCompiler.compile(
          buildingModel,
          buildingNsbmd,
          texturePack,
          animResult,
          context,
          memberId,
          opts.textures,
          opts.meshes
        )
        for _, entry in ipairs(unresolved) do
          unresolvedMaterials[#unresolvedMaterials + 1] = entry
        end
        modelDescriptor, animated = descriptor, true
      end
    end
    if not animated then
      local compiled = ModelAssetCompiler.compileModel(buildingModel, texturePack, opts.meshes, opts.textures, context)
      appendUnresolved(unresolvedMaterials, compiled)
      modelDescriptor = {
        schema = ModelAsset.SCHEMA,
        memberId = memberId,
        kind = "static",
        batches = compiled.batches,
        materials = compiled.materials,
      }
    end
    local descriptorSha = Hashing.hashLua(modelDescriptor)
    local modelKey =
      string.format("%s:%d:%s", area.areaType == "indoor" and "indoor" or "outdoor", memberId, descriptorSha:sub(1, 12))
    modelDescriptor.key = modelKey
    models[modelKey] = modelDescriptor
    modelKeyOf[memberId] = modelKey
    memberShaOf[memberId] = modelSha1
  end

  local buildingInstances = {}
  for _, placement in ipairs(land.buildings) do
    buildingInstances[#buildingInstances + 1] = {
      placementIndex = placement.index,
      modelKey = modelKeyOf[placedMember(placement)],
      transform = BuildingTransform.build(placement),
    }
  end
  local buildingModelShas = {}
  for _, memberId in ipairs(memberIds) do
    buildingModelShas[#buildingModelShas + 1] = { memberId = memberId, sha1 = memberShaOf[memberId] }
  end
  return {
    buildingInstances = buildingInstances,
    models = models,
    unresolvedMaterials = unresolvedMaterials,
    buildingModelShas = buildingModelShas,
    animationListMemberSha1s = animDeps,
    archiveAlias = archiveAlias,
    buildingTextureMemberId = #memberIds > 0 and area.buildingTexturePackId or nil,
    buildingTextureMemberSha1 = bldTexSha1,
    modelKeyOf = modelKeyOf,
  }
end

function BuildingModelCompiler.compileSelected(romFs, area, land, memberId, opts)
  assert(type(memberId) == "number" and memberId % 1 == 0, "selected building member must be an integer")
  local selectedLand = {}
  for key, value in pairs(land) do
    selectedLand[key] = value
  end
  selectedLand.buildings = {}
  local compiled = BuildingModelCompiler.compile(romFs, area, selectedLand, {
    mapId = opts.mapId,
    mapSymbol = opts.mapSymbol,
    areaDataMemberId = opts.areaDataMemberId,
    landDataMemberId = opts.landDataMemberId,
    resourceCache = opts.resourceCache,
    meshes = opts.meshes,
    textures = opts.textures,
    finalizeMeshes = opts.finalizeMeshes,
    geometryArena = opts.geometryArena,
    gxScratch = opts.gxScratch,
    requiredModelMembers = { memberId },
  })
  local modelKey = assert(compiled.modelKeyOf[memberId], "selected building member did not compile")
  return {
    modelKey = modelKey,
    model = assert(compiled.models[modelKey]),
    meshes = opts.meshes,
    textures = opts.textures,
    source = {
      memberId = memberId,
      archive = compiled.archiveAlias,
      textureMemberId = compiled.buildingTextureMemberId,
      textureMemberSha1 = compiled.buildingTextureMemberSha1,
    },
    unresolvedMaterials = compiled.unresolvedMaterials,
  }
end

return BuildingModelCompiler
