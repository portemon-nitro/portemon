-- ROM conformance for the Rocket hideout's own script-driven field effects: the
-- three trap models and their source clips out of the demo/legend archive
-- (src/field/script_field_effects.c sTrapEffects) and the alarm's red overlay,
-- whose palette, character data and tilemap the source loads into the main BG1
-- (Task_ShowHideoutAlarm). Every member the runtime presents is compiled here
-- and named in the bundle's provenance.

local Assert = require("tests.support.Assert")
local FieldEffects = require("romdump.src.config.FieldEffects")
local RomSuite = require("tests.rom.support.RomSuite")
local StoryEffectAssetCompiler = require("romdump.src.digest.field.StoryEffectAssetCompiler")

local ARCHIVE = "NARC_demo_legend"

-- The trap kinds and the number of animation resources each source anim-list
-- record names (sElectricTrapAnims, sPoisonTrapAnims, sRockTrapAnims).
local TRAPS = {
  { key = "rocket_trap_electric", clipCount = 1 },
  { key = "rocket_trap_poison", clipCount = 2 },
  { key = "rocket_trap_rock", clipCount = 3 },
}

local function hashedMembers(compiled)
  local hashed = {}
  for _, entry in ipairs(compiled.memberHashes) do
    local memberId = entry.memberId or entry.resourceId
    if type(memberId) == "number" then
      hashed[memberId] = true
    end
  end
  return hashed
end

local suite = RomSuite.fromFacts({
  ["compiles the three trap models with their source clips and provenance"] = function(romFs)
    local meshes, textures = {}, {}
    local compiled = assert(StoryEffectAssetCompiler.compile(romFs, meshes, textures))
    local hashed = hashedMembers(compiled)
    for _, trap in ipairs(TRAPS) do
      local definition = assert(compiled.definitions[trap.key], trap.key .. " is published in the bundle")
      local model = assert(definition.model)
      Assert.equal(model.key, "field-effect:" .. trap.key)
      Assert.equal(model.kind, "nitro-dynamic", trap.key .. " is a normalized animated model")
      Assert.equal(#model.animations, trap.clipCount, trap.key .. " carries every clip its source record names")
      for _, clip in ipairs(model.animations) do
        Assert.isTrue(type(clip.name) == "string" and clip.name ~= "", trap.key .. " clip is named")
        Assert.isTrue(clip.frameCount >= 1, trap.key .. " clip carries its source frame count")
      end
      for _, batch in ipairs(model.dynamic.batches) do
        local sha1 = assert(
          batch.geometry:match("^assets/generated/field/effects/geometry/([0-9a-f]+)%.g4mesh$"),
          trap.key .. " geometry publishes under the effect root"
        )
        Assert.notNil(meshes[sha1], trap.key .. " geometry bytes are compiled")
      end
      for _, material in ipairs(model.materials) do
        if material.texture then
          local sha1 = assert(
            material.texture:match("^assets/generated/field/effects/textures/([0-9a-f]+)%.png$"),
            trap.key .. " texture publishes under the effect root"
          )
          Assert.notNil(textures[sha1], trap.key .. " texture bytes are compiled")
        end
      end
    end
    -- The source members behind the three trap models and their animation
    -- records are the bundle's provenance.
    for _, source in ipairs(FieldEffects.hideoutTrapModels) do
      Assert.isTrue(hashed[source.memberId] == true, source.key .. " model member is part of the provenance")
      for _, animation in ipairs(source.animations) do
        Assert.isTrue(
          hashed[animation.memberId] == true,
          source.key .. " animation member " .. animation.memberId .. " is part of the provenance"
        )
      end
    end
  end,

  ["compiles the alarm overlay from its own palette, character data and tilemap"] = function(romFs)
    local meshes, textures = {}, {}
    local compiled = assert(StoryEffectAssetCompiler.compile(romFs, meshes, textures))
    local overlay = FieldEffects.hideoutAlarmOverlay
    local definition = assert(compiled.definitions[overlay.key], "the alarm overlay is published in the bundle")
    local record = assert(definition.overlay)
    Assert.isTrue(record.width > 0 and record.height > 0, "the overlay carries its rasterized dimensions")
    Assert.equal(record.width % 8, 0, "the overlay keeps whole source tiles in x")
    Assert.equal(record.height % 8, 0, "the overlay keeps whole source tiles in y")
    local sha1 = assert(
      record.texture:match("^assets/generated/field/effects/textures/([0-9a-f]+)%.png$"),
      "the overlay texture publishes under the effect root"
    )
    Assert.notNil(textures[sha1], "the overlay texture bytes are compiled")
    local hashed = hashedMembers(compiled)
    for _, memberId in ipairs({ overlay.paletteMemberId, overlay.charMemberId, overlay.screenMemberId }) do
      Assert.isTrue(hashed[memberId] == true, "overlay member " .. memberId .. " is part of the provenance")
    end
  end,

  ["the hideout effects travel with the archive the source loads them from"] = function(romFs)
    local archive = assert(romFs:openNarc(ARCHIVE), "the source effect archive is available at " .. ARCHIVE)
    for _, source in ipairs(FieldEffects.hideoutTrapModels) do
      local bytes = assert(archive:readMember(source.memberId))
      Assert.equal(bytes:sub(1, 4), "BMD0", source.key .. " source member is a Nitro model")
    end
    local overlay = FieldEffects.hideoutAlarmOverlay
    Assert.equal(
      assert(archive:readMember(overlay.paletteMemberId)):sub(1, 4),
      "RLCN",
      "the alarm palette is a Nitro palette resource"
    )
    Assert.equal(
      assert(archive:readMember(overlay.charMemberId)):sub(1, 4),
      "RGCN",
      "the alarm character data is a Nitro character resource"
    )
    Assert.equal(
      assert(archive:readMember(overlay.screenMemberId)):sub(1, 4),
      "RCSN",
      "the alarm tilemap is a Nitro screen resource"
    )
  end,
})

suite.metadata.capabilities = { "rom_dump" }
suite.metadata.tags = { "field", "rocket", "source" }
return suite
