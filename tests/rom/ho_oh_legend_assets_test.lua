-- ROM-backed conformance for the Clear Bell and Ho-Oh field cutscene models.

local Assert = require("tests.support.Assert")
local FieldEffectAssetCache = require("libs.assets.src.field.FieldEffectAssetCache")
local ModelAsset = require("libs.assets.src.model.ModelAsset")
local FieldEntranceIndicatorCompiler = require("romdump.src.digest.field.FieldEntranceIndicatorCompiler")
local RomSuite = require("tests.rom.support.RomSuite")

local MODEL_NAMES = {
  "bellRising",
  "bellShimmer",
  "cornerBells",
  "birdApproach",
  "wavesEffect",
  "cinematic.first.0",
  "cinematic.first.1",
  "cinematic.first.2",
  "cinematic.second.0",
  "cinematic.second.1",
  "cinematic.second.2",
}

local function testHoOhLegendModels(romFs, version)
  local bundle = assert(FieldEntranceIndicatorCompiler.compile(romFs))
  local effect = assert(bundle.effects.ho_oh_appearance, "field effects include the original Ho-Oh cutscene models")
  Assert.equal(#effect.models, #MODEL_NAMES, "the definition keeps each source model role separate")
  for index, name in ipairs(MODEL_NAMES) do
    local descriptor = assert(effect.models[index], "the definition includes " .. name)
    ModelAsset.validate(descriptor)
    Assert.equal(descriptor.kind, "nitro-dynamic", version .. " " .. name .. " keeps its Nitro animations")
    Assert.isTrue(#descriptor.animations > 0, version .. " " .. name .. " has an animation")
    local program = descriptor.dynamic.transformProgram
    if program.scalingRule == 1 then
      for _, node in ipairs(program.nodes) do
        if not node.scaleOne then
          Assert.notNil(node.inverseScale, version .. " " .. name .. " retains Maya inverse scale for " .. node.name)
        end
      end
    end
    for _, path in ipairs(ModelAsset.referencedPaths(descriptor)) do
      Assert.isTrue(
        path:match("^assets/generated/field/effects/") ~= nil,
        version .. " " .. name .. " references only owned field-effect assets"
      )
      local key = assert(path:match("/([^/]+)%.([^/]+)$"))
      if path:match("%.g4mesh$") then
        Assert.notNil(bundle.meshes[key], "compiled geometry exists for " .. path)
      else
        Assert.notNil(bundle.textures[key], "compiled texture exists for " .. path)
      end
    end
  end
  Assert.equal(
    FieldEffectAssetCache.definitionPath("ho_oh_appearance"),
    bundle.index.effects.ho_oh_appearance.path,
    "the field-effect index publishes the source models"
  )
  if version == "heartgold" then
    local leaves = assert(effect.leaves, "HeartGold publishes the original leaf overlay layers")
    for _, layerName in ipairs({ "bg2", "bg3" }) do
      local layer = assert(leaves[layerName], "HeartGold publishes " .. layerName)
      Assert.equal(#layer.frames, 6, "the " .. layerName .. " layer has six source tilemaps")
      for _, frame in ipairs(layer.frames) do
        Assert.notNil(bundle.textures[assert(frame.path:match("/([^/]+)%.png$"))], "leaf frame texture is compiled")
      end
    end
  end
end

return RomSuite.fromFacts({
  ["original Ho-Oh appearance cutscene models compile for each ready game"] = testHoOhLegendModels,
})
