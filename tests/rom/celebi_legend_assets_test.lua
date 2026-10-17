-- ROM-backed conformance for the original HGSS time-travel legend model.

local Assert = require("tests.support.Assert")
local FieldEffectAssetCache = require("libs.assets.src.field.FieldEffectAssetCache")
local ModelAsset = require("libs.assets.src.model.ModelAsset")
local NitroAnimation = require("libs.nds.src.nitro.g3d.NitroAnimation")
local Nsbmd = require("libs.nds.src.nitro.g3d.Nsbmd")
local FieldEntranceIndicatorCompiler = require("romdump.src.digest.field.FieldEntranceIndicatorCompiler")
local RomSuite = require("tests.rom.support.RomSuite")

local SOURCE_MEMBERS = {
  { memberId = 76, format = "NSBCA", id = "celebi.joint", category = "joint", kind = "trs" },
  { memberId = 78, format = "NSBTP", id = "celebi.pattern", category = "material", kind = "pattern" },
  { memberId = 77, format = "NSBTA", id = "celebi.srt", category = "material", kind = "texsrt" },
}

local function sourceMember(archive, memberId)
  local bytes, err = archive:readMember(memberId)
  assert(bytes, "NARC_demo_legend member " .. memberId .. ": " .. tostring(err))
  return bytes
end

local function testLegendModelAndAnimations(romFs, version)
  local archive = assert(romFs:openNarc("NARC_demo_legend"))
  local modelBytes = sourceMember(archive, 75)
  local sourceModel = assert(Nsbmd.decode(modelBytes, { alias = "NARC_demo_legend", memberId = 75 }))
  Assert.isTrue(#sourceModel.models > 0, version .. " source model member 75 has geometry")
  Assert.notNil(sourceModel.embeddedTextures, version .. " source model member 75 embeds its texture pack")

  local names = {}
  for _, source in ipairs(SOURCE_MEMBERS) do
    local bytes = sourceMember(archive, source.memberId)
    local decoded = assert(
      NitroAnimation.decode(bytes, { alias = "NARC_demo_legend", memberId = source.memberId }),
      version .. " animation member " .. source.memberId .. " decodes"
    )
    Assert.equal(decoded.format, source.format, "source member " .. source.memberId .. " format")
    names[source.id] = assert(decoded.animations[1]).name
  end

  local bundle = assert(FieldEntranceIndicatorCompiler.compile(romFs))
  local effect = assert(bundle.effects.celebi_time_travel, "compiled field effects include the original legend model")
  local descriptor = assert(effect.model, "the time-travel effect publishes one model descriptor")
  ModelAsset.validate(descriptor)
  Assert.equal(descriptor.kind, "nitro-dynamic")
  Assert.equal(#descriptor.animations, 3, "one model carries all three source animations")

  local clipsById = {}
  for _, clip in ipairs(descriptor.animations) do
    clipsById[clip.id] = clip
  end
  for _, source in ipairs(SOURCE_MEMBERS) do
    local clip = assert(clipsById[source.id], "the model publishes semantic clip " .. source.id)
    Assert.equal(clip.category, source.category, source.id .. " category")
    Assert.equal(clip.kind, source.kind, source.id .. " kind")
    Assert.deepEqual(clip.semanticNames, { source.id }, source.id .. " semantic selector")
    Assert.equal(clip.name, names[source.id], source.id .. " preserves its Nitro dictionary name")
  end

  Assert.notNil(
    bundle.index.effects.celebi_time_travel,
    "the generated field-effects index points to the published definition"
  )
  for _, path in ipairs(ModelAsset.referencedPaths(descriptor)) do
    local key = assert(path:match("/([^/]+)%.([^/]+)$"))
    if path:match("%.g4mesh$") then
      Assert.notNil(bundle.meshes[key], "generated model geometry exists for " .. path)
    else
      Assert.isTrue(path:match("%.png$") ~= nil, "model texture uses a PNG path: " .. path)
      Assert.notNil(bundle.textures[key], "generated model texture exists for " .. path)
    end
  end
  Assert.equal(
    FieldEffectAssetCache.definitionPath("celebi_time_travel"),
    bundle.index.effects.celebi_time_travel.path,
    "the index points to the semantic runtime definition path"
  )
end

return RomSuite.fromFacts({
  ["original legend model and three animations compile for each ready game"] = testLegendModelAndAnimations,
})
