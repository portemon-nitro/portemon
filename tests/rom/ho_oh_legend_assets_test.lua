-- ROM-backed conformance for the Clear Bell and Ho-Oh field cutscene models.

local Assert = require("tests.support.Assert")
local FieldEffectAssetCache = require("libs.assets.src.field.FieldEffectAssetCache")
local HoOhCinematicParts = require("libs.assets.src.field.HoOhCinematicParts")
local ModelAsset = require("libs.assets.src.model.ModelAsset")
local FieldEntranceIndicatorCompiler = require("romdump.src.digest.field.FieldEntranceIndicatorCompiler")
local RomSuite = require("tests.rom.support.RomSuite")

local CORE_NAMES = { "bellRising", "bellShimmer", "cornerBells", "birdApproach", "wavesEffect" }
local SHOTS = { "first", "second" }

local function checkDescriptor(bundle, descriptor, name, version)
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

local function testHoOhLegendModels(romFs, version)
  local bundle = assert(FieldEntranceIndicatorCompiler.compile(romFs))
  local effect = assert(bundle.effects.ho_oh_appearance, "field effects include the original Ho-Oh cutscene core")
  Assert.equal(#effect.models, #CORE_NAMES, "the core keeps each non-cinematic source model role separate")
  for index, name in ipairs(CORE_NAMES) do
    checkDescriptor(bundle, assert(effect.models[index], "the core includes " .. name), name, version)
  end
  for _, shot in ipairs(SHOTS) do
    local shared = assert(bundle.effects[FieldEffectAssetCache.hoOhCinematicKind(shot)], shot .. " shared part")
    local longest = 0
    for _, clip in ipairs(shared.animations) do
      longest = math.max(longest, clip.frameCount)
    end
    for variant = 0, 2 do
      local overlay = assert(bundle.effects[FieldEffectAssetCache.hoOhCinematicKind(shot, variant)], shot .. " overlay")
      local descriptor = HoOhCinematicParts.merge(shared, overlay)
      local name = "cinematic." .. shot .. "." .. variant
      Assert.equal(descriptor.key, "field-effect:ho-oh-appearance:" .. name)
      checkDescriptor(bundle, descriptor, name, version)
      for _, clip in ipairs(descriptor.animations) do
        Assert.isTrue(clip.id:find("^cinematic%." .. shot .. "%." .. variant .. "%.") ~= nil, "clip ids keep their variant")
      end
      Assert.equal(effect.clips.cinematic[shot][variant + 1], longest, "the summary names the shot length")
    end
  end
  for _, kind in ipairs(FieldEffectAssetCache.hoOhPartKinds()) do
    Assert.equal(
      bundle.index.effects[kind].path,
      FieldEffectAssetCache.definitionPath(kind),
      "the field-effect index publishes " .. kind
    )
  end
  Assert.equal(
    FieldEffectAssetCache.definitionPath("ho_oh_appearance"),
    bundle.index.effects.ho_oh_appearance.path,
    "the field-effect index publishes the core"
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
