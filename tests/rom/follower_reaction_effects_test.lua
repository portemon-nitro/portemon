-- ROM conformance for the follower reaction source members used by renderer 0x12.

local Assert = require("tests.support.Assert")
local Nsbmd = require("libs.nds.src.nitro.g3d.Nsbmd")
local Nsbtx = require("libs.nds.src.nitro.g3d.Nsbtx")
local Compiler = require("romdump.src.digest.field.FollowerInteractionCompiler")
local FieldEffects = require("romdump.src.config.FieldEffects")
local PatternAnimation = require("romdump.src.digest.field.FieldEffectPatternAnimation")
local MapPropAnimCompiler = require("romdump.src.digest.model.MapPropAnimCompiler")
local DynamicModelCompiler = require("romdump.src.digest.model.DynamicModelCompiler")
local ModelAsset = require("libs.assets.src.model.ModelAsset")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

function T.reaction_source_resources_match_the_rom(romFs)
  local narc = assert(romFs:openNarc(FieldEffects.archive.alias))
  Assert.equal(#FieldEffects.followerReactions, 14)
  local modelBytes = assert(narc:readMember(130))
  Assert.equal(modelBytes:sub(1, 4), "BMD0")
  local decodedModel = assert(Nsbmd.decode(modelBytes, {
    alias = FieldEffects.archive.alias,
    memberId = 130,
    section = "follower-reaction-model",
  }))
  Assert.equal(#decodedModel.models[1].materials, 1)
  Assert.equal(#decodedModel.embeddedTextures.textures, 1)
  Assert.equal(#decodedModel.embeddedTextures.palettes, 1)
  local member28Bytes = assert(narc:readMember(28))
  Assert.equal(member28Bytes:sub(1, 4), "BTX0")
  Assert.isTrue(Nsbtx.decode(member28Bytes, {
    alias = FieldEffects.archive.alias,
    memberId = 28,
    section = "follower-reaction-base-textures",
  }) ~= nil, "base texture member decodes as NSBTX")
  local basePack = assert(Nsbtx.decode(member28Bytes))
  Assert.equal(#basePack.textures, 1)
  Assert.equal(#basePack.palettes, 1)
  local setupPatternBytes = assert(narc:readMember(140))
  local setupPattern = assert(PatternAnimation.decode(setupPatternBytes, {
    alias = FieldEffects.archive.alias,
    memberId = 140,
    section = "follower-reaction-setup-pattern",
  }))
  Assert.equal(#setupPattern.keys, 4)
  -- ov01_02203A18's follower caller does not advance the generic pattern
  -- clock; it samples member 140 at frame 0. Tall-grass callers do advance it.
  for index, key in ipairs(setupPattern.keys) do
    Assert.equal(key.frame, (index - 1) * 4)
    Assert.equal(key.texIdx, index - 1)
    Assert.equal(key.plttIdx, 0)
  end
  Assert.equal(setupPattern.keys[1].texIdx, 0, "follower setup samples key zero")
  for selector, source in ipairs(FieldEffects.followerReactions) do
    Assert.equal(source.key, "follower_reaction_" .. selector)
    local textureBytes = assert(narc:readMember(source.textureMember))
    Assert.equal(textureBytes:sub(1, 4), "BTX0")
    Assert.isTrue(Nsbtx.decode(textureBytes, {
      alias = FieldEffects.archive.alias,
      memberId = source.textureMember,
      section = source.key,
    }) ~= nil, "reaction source member decodes as NSBTX")
    local pack = assert(Nsbtx.decode(textureBytes))
    Assert.equal(#pack.textures, 2)
    Assert.equal(#pack.palettes, 1)
    local descriptorBytes = assert(narc:readMember(source.descriptorMember))
    local descriptor = Compiler.decodeReactionDescriptor(descriptorBytes)
    Assert.equal(#descriptor.keys, 4)
    Assert.equal(descriptor.keys[1].frame, 0)
    Assert.equal(descriptor.keys[2].frame, 4)
    Assert.equal(descriptor.keys[3].frame, 8)
    Assert.equal(descriptor.keys[4].frame, 12)
    Assert.equal(descriptor.keys[1].texIdx, 0)
    Assert.equal(descriptor.keys[2].texIdx, 1)
    Assert.equal(descriptor.keys[3].texIdx, 0)
    Assert.equal(descriptor.keys[4].texIdx, 1)
    for _, key in ipairs(descriptor.keys) do
      Assert.equal(key.plttIdx, 0)
    end
  end
end

function T.dynamic_model_compiler_binds_base_pack_and_selector_clip_locally(romFs)
  local narc = assert(romFs:openNarc(FieldEffects.archive.alias))
  local source = FieldEffects.followerReactions[1]
  local modelNsbmd = assert(Nsbmd.decode(assert(narc:readMember(130)), {
    alias = FieldEffects.archive.alias,
    memberId = 130,
    section = "follower-reaction-model",
  }))
  local basePack = assert(Nsbtx.decode(assert(narc:readMember(28)), {
    alias = FieldEffects.archive.alias,
    memberId = 28,
    section = "follower-reaction-base-textures",
  }))
  local selectorPack = assert(Nsbtx.decode(assert(narc:readMember(source.textureMember)), {
    alias = FieldEffects.archive.alias,
    memberId = source.textureMember,
    section = source.key,
  }))
  local patternBytes = assert(narc:readMember(source.descriptorMember))
  local pattern = assert(Compiler.decodeReactionDescriptor(patternBytes))
  local textureNames, paletteNames = {}, {}
  for _, texture in ipairs(selectorPack.textures) do
    textureNames[#textureNames + 1] = texture.name
  end
  for _, palette in ipairs(selectorPack.palettes) do
    paletteNames[#paletteNames + 1] = palette.name
  end
  local animation = {
    format = "NSBTP",
    bytes = patternBytes,
    animations = {
      {
        name = "follower-reaction-pattern",
        resource = {
          numFrame = pattern.lastFrame + 1,
          textureNames = textureNames,
          paletteNames = paletteNames,
          targets = {
            {
              index = 0,
              name = modelNsbmd.models[1].materials[1].name,
              rate = 1,
              keys = pattern.keys,
            },
          },
        },
      },
    },
  }
  local clip = MapPropAnimCompiler.compileDecoded(animation, {
    name = "follower-reaction-pattern",
    id = source.key .. ":animation",
    source = { type = "field-effect", format = PatternAnimation.FORMAT },
  })
  local meshes, textures = {}, {}
  local descriptor, unresolved = DynamicModelCompiler.compile(
    modelNsbmd.models[1],
    { embeddedTextures = selectorPack },
    basePack,
    { clips = { clip } },
    {
      role = "field-effect-follower-reaction",
      modelArchive = FieldEffects.archive.alias,
      modelMemberId = 130,
      modelName = modelNsbmd.models[1].name,
      textureArchive = FieldEffects.archive.alias,
    },
    130,
    textures,
    meshes
  )
  Assert.equal(#unresolved, 0, "base material and selector variants resolve from separate packs")
  ModelAsset.validate(descriptor)
  Assert.equal(descriptor.kind, "nitro-dynamic")
  Assert.equal(descriptor.memberId, 130)
  Assert.equal(#descriptor.animations, 1)
  Assert.equal(descriptor.animations[1].source.format, PatternAnimation.FORMAT)
  Assert.notNil(descriptor.materials[1].texture, "base BTX0 supplies the material")
  Assert.equal(#descriptor.materials[1].variants, 2, "selector BTX0 supplies two texture variants")
end

local suite = RomSuite.fromFacts(T)
suite.metadata.capabilities = { "rom_dump" }
return suite
