-- ROM-backed provenance for the compiled movement-emote billboard: proves
-- the exclamation model compiles from field_static_models member 118 into a
-- nonempty, source-dimensioned texture surface rather than an invented or
-- degenerate one. Mirrors field_entrance_indicator_alpha_test's shape for
-- the sibling field-effect model.

local Assert = require("tests.support.Assert")
local CompiledAsset = require("tests.rom.support.CompiledAsset")
local FieldActorEmoteCompiler = require("romdump.src.digest.actor.FieldActorEmoteCompiler")
local Nsbmd = require("libs.nds.src.nitro.g3d.Nsbmd")
local RomSuite = require("tests.rom.support.RomSuite")

local MEMBER_ID = 118

local function hasVisibleTexel(pixels)
  for offset = 4, #pixels, 4 do
    if string.byte(pixels, offset) ~= 0 then
      return true
    end
  end
  return false
end

local function testExclamationModelSurface(romFs)
  local bundle = assert(FieldActorEmoteCompiler.compile(romFs))

  Assert.equal(bundle.model.schema, "g4-field-emote-v3")
  Assert.equal(bundle.model.model.key, "field-emote:exclamation")
  Assert.isTrue(#bundle.model.model.batches > 0, "the compiled exclamation model must have at least one drawable batch")
  Assert.isTrue(#bundle.model.model.materials > 0, "the compiled exclamation model must have at least one material")

  local narc = assert(romFs:openNarc("field_static_models"))
  local decoded =
    assert(Nsbmd.decode(assert(narc:readMember(MEMBER_ID)), { alias = "field_static_models", memberId = MEMBER_ID }))
  local sourcePack = assert(decoded.embeddedTextures)

  local boundTextures = 0
  for _, material in ipairs(bundle.model.model.materials) do
    if material.texture then
      local where = "exclamation material " .. tostring(material.name)
      local sourceTexture = assert(
        sourcePack.textureByName[material.texture.textureName],
        where .. " names a source texture: " .. tostring(material.texture.textureName)
      )
      local compiled =
        CompiledAsset.texturePixels(bundle.textures --[[@as table<string, unknown>]], material.texture, where)
      Assert.isTrue(compiled.width > 0, "the compiled exclamation texture must have a nonzero width")
      Assert.isTrue(compiled.height > 0, "the compiled exclamation texture must have a nonzero height")
      Assert.equal(compiled.width, sourceTexture.width, where .. " keeps its source width")
      Assert.equal(compiled.height, sourceTexture.height, where .. " keeps its source height")
      Assert.isTrue(
        hasVisibleTexel(compiled.pixels),
        "the compiled exclamation texture must not be fully transparent/blank"
      )
      boundTextures = boundTextures + 1
    end
  end
  Assert.isTrue(boundTextures > 0, "member 118 must bind at least one source texture")
end

return RomSuite.fromFacts({
  ["member 118 compiles a nonempty source-dimensioned exclamation surface"] = testExclamationModelSurface,
})
