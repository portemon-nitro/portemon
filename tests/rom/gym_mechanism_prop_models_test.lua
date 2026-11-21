-- ROM conformance for the three source map props the gym mechanisms load at
-- runtime: the Violet Gym elevator car (build model 111), the Azalea Gym
-- Spinarak (build model 118) and the Ecruteak Gym candle (build model 128).
-- All three are interior build models listed by their area's build config, so
-- the area loader also registers their anim-list records; none has a generated
-- map placement.

local AreaData = require("romdump.src.digest.map.AreaData")
local Assert = require("tests.support.Assert")
local BinaryReader = require("libs.codec.src.BinaryReader")
local MapResolver = require("romdump.src.digest.map.MapResolver")
local Nsbmd = require("libs.nds.src.nitro.g3d.Nsbmd")
local RomSuite = require("tests.rom.support.RomSuite")
local StoryEffectAssetCompiler = require("romdump.src.digest.field.StoryEffectAssetCompiler")

local SOURCES = {
  {
    key = "violet_gym_car",
    mapSymbol = "MAP_VIOLET_GYM",
    modelMemberId = 111,
    clipName = "gym01_lift",
    animationResourceId = 18,
    frameCount = 360,
    ambientLoop = true,
  },
  {
    key = "azalea_gym_spinarak",
    mapSymbol = "MAP_AZALEA_GYM",
    modelMemberId = 118,
    clipName = "gym02lift",
    animationResourceId = 43,
    frameCount = 30,
    ambientLoop = false,
  },
  {
    key = "ecruteak_gym_candle",
    mapSymbol = "MAP_ECRUTEAK_GYM",
    modelMemberId = 128,
    clipName = "g04_light",
    animationResourceId = 44,
    frameCount = 8,
    ambientLoop = true,
  },
}

-- The area's build config lists every prop id the area loader instantiates,
-- which is why a runtime-loaded prop still gets its anim-list record.
local function loadedPropIds(romFs, mapSymbol)
  local resolved = assert(MapResolver.resolve(romFs, mapSymbol))
  local area = assert(AreaData.decode(assert(romFs:openNarc("area_data"):readMember(resolved.areaDataMemberId)), {
    alias = "area_data",
    memberId = resolved.areaDataMemberId,
  }))
  local bytes = assert(romFs:openNarc("area_build_config"):readMember(area.buildingTexturePackId))
  local reader = BinaryReader.new(bytes, "area_build_config")
  local ids = {}
  for index = 0, reader:u16le(0) - 1 do
    ids[reader:u16le(2 + index * 2)] = true
  end
  return ids
end

local function assertSourceMember(romFs, source)
  local models = assert(romFs:openNarc("interior_build_models"))
  local bytes = assert(models:readMember(source.modelMemberId))
  Assert.equal(bytes:sub(1, 4), "BMD0", source.key .. " source model is a Nitro model")
  local decoded = assert(Nsbmd.decode(bytes, {
    alias = "interior_build_models",
    memberId = source.modelMemberId,
    section = source.key,
  }))
  Assert.notNil(decoded.models[1], source.key .. " source model decodes")
  Assert.isTrue(
    loadedPropIds(romFs, source.mapSymbol)[source.modelMemberId] == true,
    source.key .. " is listed by its area's build config"
  )
end

local function assertCompiledSource(compiled, definition, source, meshes, textures)
  Assert.notNil(definition, source.key .. " is published in the bundle")
  local model = assert(definition.model)
  Assert.equal(model.key, "field-effect:" .. source.key)
  Assert.equal(model.kind, "nitro-dynamic")
  Assert.equal(#model.animations, 1, source.key .. " carries exactly its one source clip")
  local clip = model.animations[1]
  Assert.equal(clip.name, source.clipName)
  Assert.equal(clip.frameCount, source.frameCount)
  Assert.equal(clip.ambientLoop or false, source.ambientLoop)
  for _, batch in ipairs(model.dynamic.batches) do
    local sha1 = assert(
      batch.geometry:match("^assets/generated/field/effects/geometry/([0-9a-f]+)%.g4mesh$"),
      source.key .. " geometry publishes under the effect root"
    )
    Assert.notNil(meshes[sha1], source.key .. " geometry bytes are compiled")
  end
  for _, material in ipairs(model.materials) do
    if material.texture then
      local sha1 = assert(
        material.texture:match("^assets/generated/field/effects/textures/([0-9a-f]+)%.png$"),
        source.key .. " texture publishes under the effect root"
      )
      Assert.notNil(textures[sha1], source.key .. " texture bytes are compiled")
    end
  end
  -- Provenance covers the model member, its anim-list record and every
  -- animation resource the compiled clip was built from.
  local hashed = {}
  for _, entry in ipairs(compiled.memberHashes) do
    hashed[entry.memberId or entry.resourceId] = true
  end
  Assert.isTrue(hashed[source.modelMemberId] == true, source.key .. " model member is part of the provenance")
  local listed = {}
  for _, entry in ipairs(compiled.memberHashes) do
    listed[#listed + 1] = tostring(entry.memberId or entry.resourceId)
      .. ":"
      .. tostring(entry.kind or entry.alias or "")
  end
  Assert.isTrue(
    hashed[source.modelMemberId] == true and hashed[source.animationResourceId] == true,
    source.key .. " animation resource is part of the provenance (" .. table.concat(listed, ",") .. ")"
  )
end

local suite = RomSuite.fromFacts({
  ["compiles every mechanism prop model from its own map archives"] = function(romFs)
    local meshes, textures = {}, {}
    local compiled = assert(StoryEffectAssetCompiler.compile(romFs, meshes, textures))
    for _, source in ipairs(SOURCES) do
      assertSourceMember(romFs, source)
      assertCompiledSource(compiled, assert(compiled.definitions[source.key]), source, meshes, textures)
    end
  end,
})
suite.metadata.capabilities = { "rom_dump" }
suite.metadata.tags = { "field", "gym", "source" }
return suite
