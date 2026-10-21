-- ROM-backed conformance for the eye-glimmer and Lugia cinematic models.

local Assert = require("tests.support.Assert")
local FieldEffectAssetCache = require("libs.assets.src.field.FieldEffectAssetCache")
local ModelAsset = require("libs.assets.src.model.ModelAsset")
local FieldEntranceIndicatorCompiler = require("romdump.src.digest.field.FieldEntranceIndicatorCompiler")
local RomSuite = require("tests.rom.support.RomSuite")

local MODEL_NAMES = {
  "eyeGlimmer",
  "cinematic.lugia.0",
  "cinematic.lugia.1",
}

local CLIP_IDS = {
  eyeGlimmer = { "eye.color", "eye.pattern", "eye.joint" },
  ["cinematic.lugia.0"] = { "lugia.joint", "lugia.color", "lugia.srt", "lugia.pattern" },
  ["cinematic.lugia.1"] = { "lugia.far.joint" },
}

local function testLugiaLegendModels(romFs, version)
  local bundle = assert(FieldEntranceIndicatorCompiler.compile(romFs))
  local effect = assert(bundle.effects.lugia_appearance, "field effects include the original Lugia reveal models")
  Assert.equal(#effect.models, #MODEL_NAMES, "the definition keeps each source model role separate")
  Assert.isNil(effect.leaves, "the Lugia reveal has no leaf overlay")
  for index, name in ipairs(MODEL_NAMES) do
    local descriptor = assert(effect.models[index], "the definition includes " .. name)
    ModelAsset.validate(descriptor)
    Assert.equal(descriptor.kind, "nitro-dynamic", version .. " " .. name .. " keeps its Nitro animations")
    local expected = assert(CLIP_IDS[name], "the test pins the clips of " .. name)
    Assert.equal(#descriptor.animations, #expected, version .. " " .. name .. " has its source clips")
    for clipIndex, clipId in ipairs(expected) do
      Assert.equal(descriptor.animations[clipIndex].id, clipId, version .. " " .. name .. " keeps its clip role")
    end
    -- Retail loads the far Lugia model with its material colors disabled
    -- (noMaterialColors): the cinematic ignores the source diffuse/ambient
    -- registers so the distant Lugia and its shadow draw unlit. The
    -- descriptor must carry white registers for that model, never the
    -- source gray.
    if name == "cinematic.lugia.1" then
      for _, material in ipairs(assert(descriptor.materials, version .. " far model has materials")) do
        for _, channel in ipairs({ "diffuse", "ambient", "specular", "emission" }) do
          local color = assert(
            material.colors and material.colors[channel],
            version .. " far material " .. material.name .. " keeps a " .. channel .. " register"
          )
          Assert.deepEqual(
            { color.r, color.g, color.b },
            { 255, 255, 255 },
            version .. " far material " .. material.name .. " ignores its source " .. channel
          )
        end
      end
    end
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
    FieldEffectAssetCache.definitionPath("lugia_appearance"),
    bundle.index.effects.lugia_appearance.path,
    "the field-effect index publishes the source models"
  )
end

return RomSuite.fromFacts({
  ["original Lugia reveal cutscene models compile for each ready game"] = testLugiaLegendModels,
})
