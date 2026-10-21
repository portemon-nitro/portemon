-- PAT0 target names bind to model material names; unmatched targets are inert.

local Assert = require("tests.support.Assert")
local DynamicModelCompiler = require("romdump.src.digest.model.DynamicModelCompiler")
local Nsbmd = require("libs.nds.src.nitro.g3d.Nsbmd")
local ModelAsset = require("libs.assets.src.model.ModelAsset")
local NsbmdFixture = require("tests.support.NsbmdFixture")
local Tex0Fixture = require("tests.support.Tex0Fixture")

local T = {}

local function compilePattern(targetName, textureName)
  local decoded = assert(Nsbmd.decode(NsbmdFixture.build({
    untextured = true,
    embeddedTex0 = Tex0Fixture.block({ textures = { "base" } }),
  })))
  local clip = {
    id = "fixture:pattern",
    name = "pattern",
    category = "material",
    kind = "pattern",
    frameCount = 1,
    tracks = { { target = targetName, targetIndex = 0 } },
    semanticNames = {},
    compiled = {
      textureNames = { textureName },
      paletteNames = {},
      targets = {
        {
          index = 0,
          name = targetName,
          rate = 0x1000,
          keys = { { frame = 0, texIdx = 0, plttIdx = 0xFF } },
        },
      },
    },
  }
  local meshes, textures = {}, {}
  local descriptor, unresolved = DynamicModelCompiler.compile(
    decoded.models[1],
    decoded,
    decoded.embeddedTextures,
    { clips = { clip } },
    { role = "test", modelArchive = "fixture", modelMemberId = 1 },
    1,
    textures,
    meshes
  )
  ModelAsset.validate(descriptor)
  return descriptor, unresolved
end

function T.unmatched_pattern_target_is_retained_but_does_not_resolve_resources()
  local descriptor, unresolved = compilePattern("not-a-model-material", "missing-texture")
  Assert.equal(#descriptor.animations[1].compiled.targets, 1, "the source PAT0 track is retained")
  Assert.equal(#unresolved, 0, "NNS maps only target names present in the model")
  Assert.isNil(descriptor.materials[1].variants, "the inert target creates no material variants")
end

function T.mapped_pattern_target_keeps_missing_texture_failure_strict()
  local descriptor, unresolved = compilePattern("mat0", "missing-texture")
  Assert.equal(#unresolved, 1)
  Assert.equal(unresolved[1].kind, "texture")
  Assert.equal(unresolved[1].name, "missing-texture")
  Assert.equal(#descriptor.materials[1].variants, 1)
end

return { tests = T }
