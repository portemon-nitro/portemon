-- Bounded battle-resource closure over real dumps: representative move roots
-- spanning every geometrically distinct particle family compile their
-- particle systems without rejecting a valid source mode, and every staged
-- particle texture carries the sampler and transparency metadata the shared
-- renderer stages through. HeartGold minimum; SoulSilver runs when ready.
-- Breadth only: per-effect emitter counts, pixel-exact textures, and
-- placement tables belong to the animation smoke, and quad projection
-- belongs to the synthetic draw/simulation suites.

local Assert = require("tests.support.Assert")
local GameVersion = require("romdump.src.source.GameVersion")
local RomImporter = require("romdump.src.source.RomImporter")
local RomSuite = require("tests.rom.support.RomSuite")
local RomSourcePath = require("tests.rom.support.RomSourcePath")

local T = {}

-- One root per geometrically distinct particle family: direct strikers,
-- element breaths and beams, sleep control, vortex pairs, spray and beam
-- water, screen setters, wave pair, and multi-needle scatter.
local REPRESENTATIVE_ROOTS = {
  "TACKLE",
  "EMBER",
  "THUNDERBOLT",
  "SHADOW_BALL",
  "HYPNOSIS",
  "GUST",
  "TWISTER",
  "WATER_GUN",
  "HYPER_BEAM",
  "MIST",
  "REFLECT",
  "SURF",
  "ROCK_SLIDE",
  "PIN_MISSILE",
  "SLUDGE_BOMB",
}

local function compileRoot(compiler, romFs, versionId, effectKey)
  local effect, err = compiler.compileEffect(romFs, { versionId = versionId }, effectKey)
  Assert.isNil(err, effectKey .. " stages without rejecting a valid particle mode: " .. tostring(err))
  Assert.notNil(effect, effectKey .. " closes through its selected source member")
  return effect
end

function T.representative_roots_stage_complete_particle_resources(romFs, versionId)
  local compiler = require("romdump.src.digest.battle.BattlePresentationCompiler")
  for _, effectKey in ipairs(REPRESENTATIVE_ROOTS) do
    local effect = compileRoot(compiler, romFs, versionId, effectKey)
    local particleCount = 0
    for resourceKey, descriptor in pairs(effect.resources) do
      if descriptor.kind == "particle" then
        particleCount = particleCount + 1
        local payload = effect.resourcePayloads[descriptor.payload]
        Assert.notNil(payload, effectKey .. " publishes its particle payload for " .. resourceKey)
        Assert.isTrue(
          type(payload.emitters) == "table" and #payload.emitters >= 1,
          effectKey .. " stages every source emitter instead of dropping modes"
        )
        for _, texture in ipairs(payload.textures or {}) do
          Assert.notNil(texture.sampler, effectKey .. " stages the texture sampler the shared pool keys on")
          Assert.notNil(
            texture.alphaUsage,
            effectKey .. " stages the transparency classification the renderer composites with"
          )
        end
      end
    end
    Assert.isTrue(particleCount >= 1, effectKey .. " stages at least one particle system")
  end
end

local readyVersions = {}
for _, versionId in ipairs(GameVersion.ORDER) do
  if RomImporter.isReady(versionId) then
    readyVersions[#readyVersions + 1] = versionId
  end
end

return RomSuite.build({
  tests = T,
  readyVersions = readyVersions,
  open = RomSourcePath.openReader,
})
