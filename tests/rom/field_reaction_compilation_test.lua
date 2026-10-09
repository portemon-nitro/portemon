-- ROM conformance for normalized reaction model resources and selector clips.

local Assert = require("tests.support.Assert")
local FieldEffectAssetCache = require("libs.assets.src.field.FieldEffectAssetCache")
local FieldEffects = require("romdump.src.config.FieldEffects")
local FieldEffectPatternAnimation = require("romdump.src.digest.field.FieldEffectPatternAnimation")
local FieldEntranceIndicatorCompiler = require("romdump.src.digest.field.FieldEntranceIndicatorCompiler")
local MaterialCompiler = require("romdump.src.digest.model.MaterialCompiler")
local ModelAsset = require("libs.assets.src.model.ModelAsset")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local Nsbmd = require("libs.nds.src.nitro.g3d.Nsbmd")
local Nsbtx = require("libs.nds.src.nitro.g3d.Nsbtx")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

function T.compiles_base_binding_and_selector_pattern_resources(romFs)
  local bundle = FieldEntranceIndicatorCompiler.compile(romFs)
  local narc = assert(romFs:openNarc(FieldEffects.archive.alias))
  local model = assert(Nsbmd.decode(assert(narc:readMember(130))))
  local basePack = assert(Nsbtx.decode(assert(narc:readMember(28))))
  local commonBytes = assert(narc:readMember(140))
  local common = assert(FieldEffectPatternAnimation.decode(commonBytes))
  Assert.equal(common.keys[1].frame, 0)
  Assert.equal(common.keys[1].texIdx, 0)
  local compiledBase = MaterialCompiler.compile(model.models[1].materials, basePack, {
    context = { textureArchive = FieldEffects.archive.alias, textureMemberId = 28 },
  })
  local expectedBaseTexture = FieldEffectAssetCache.texturePath(compiledBase.materials[1].texture)

  Assert.equal(#FieldEffects.followerReactions, 14)
  for selector, source in ipairs(FieldEffects.followerReactions) do
    local definition = assert(bundle.effects[source.key])
    Assert.equal(definition.definition, source.key)
    Assert.equal(definition.lifecycle.mode, "once")
    local descriptor = assert(definition.model)
    Assert.equal(descriptor.kind, "nitro-dynamic")
    Assert.equal(descriptor.key, "field-effect:follower-reaction-" .. selector)
    ModelAsset.validate(descriptor)

    local clip = assert(descriptor.animations[1])
    Assert.equal(#descriptor.animations, 1)
    Assert.equal(clip.kind, "pattern")
    Assert.equal(definition.lifecycle.frameCount, clip.frameCount)
    local sourcePack = assert(Nsbtx.decode(assert(narc:readMember(source.textureMember))))
    local sourcePattern = assert(FieldEffectPatternAnimation.decode(assert(narc:readMember(source.descriptorMember))))
    Assert.equal(#clip.compiled.textureNames, #sourcePack.textures)
    Assert.equal(#clip.compiled.paletteNames, #sourcePack.palettes)
    -- ov01_02203DF8 reads the source frame table as per-texture durations:
    -- each update counts one frame, then advances once the count reaches the
    -- current entry, so a zero duration still lasts one update.
    local compiledKeys = clip.compiled.targets[1].keys
    Assert.equal(#compiledKeys, #sourcePattern.keys)
    local start = 0
    for keyIndex, sourceKey in ipairs(sourcePattern.keys) do
      Assert.equal(compiledKeys[keyIndex].frame, start)
      Assert.equal(compiledKeys[keyIndex].texIdx, sourceKey.texIdx)
      Assert.equal(compiledKeys[keyIndex].plttIdx, 0)
      start = start + math.max(sourceKey.frame, 1)
    end
    Assert.equal(clip.frameCount, start, "the clip ends when the final duration elapses")
    Assert.equal(clip.frameCount, 25, "the retail durations 0, 4, 8, 12 span 25 updates")

    local material = assert(descriptor.materials[1])
    Assert.equal(material.name, "obj")
    Assert.equal(material.texture, expectedBaseTexture, "frame-zero base binding must come from BTX0 member 28")
    Assert.isTrue(#material.variants > 0, "selector texture pack must compile into pattern variants")
    local entry = assert(bundle.index.effects[source.key])
    Assert.equal(entry.kind, "reaction")
    Assert.equal(entry.path, FieldEffectAssetCache.definitionPath(source.key))
  end
end

return RomSuite.fromFacts(T)
