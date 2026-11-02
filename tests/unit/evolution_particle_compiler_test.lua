-- EvolutionScene's selected SPL resource is normalized and staged by the
-- battle presentation producer without retaining source archive identity.

local Assert = require("tests.support.Assert")
local SplMemberFixture = require("tests.support.SplMemberFixture")
local BattlePresentationCompiler = require("romdump.src.digest.battle.BattlePresentationCompiler")
local BattlePresentationSources = require("romdump.src.config.BattlePresentationSources")

local T = {}

local function romFsForMember(member)
  local openedArchive
  local selectedMember
  local romFs = {
    openNarc = function(_, archiveSymbol)
      openedArchive = archiveSymbol
      return {
        readMember = function(_, memberId)
          selectedMember = memberId
          return member
        end,
      }
    end,
  }
  return romFs, function()
    return openedArchive, selectedMember
  end
end

function T.evolution_source_compiles_thirteen_emitters_and_embeds_texture_pixels()
  local source = BattlePresentationSources.EVOLUTION_PARTICLES
  local member = SplMemberFixture.member(13, 1)
  local romFs, selectedSource = romFsForMember(member)

  local particles, pngs, provenance = BattlePresentationCompiler.compileEvolutionParticles(romFs)
  local archiveSymbol, memberId = selectedSource()
  Assert.equal(archiveSymbol, source.archiveSymbol, "EvolutionScene reads its configured source archive")
  Assert.equal(memberId, source.memberId, "EvolutionScene reads its configured source member")
  Assert.equal(particles.seed, 0, "the generated record pins the retail particle seed")
  Assert.equal(#particles.emitters, 13, "the generated record contains every EvolutionScene emitter")
  for index, emitter in ipairs(particles.emitters) do
    Assert.equal(emitter.id, index - 1, "emitter records retain their retail sequence IDs")
  end
  Assert.deepEqual(particles.textures, {
    { id = 0, width = 32, height = 32, image = "assets/generated/battle/evolution-particles-0.png" },
  }, "the payload exposes normalized texture metadata and a cache path")
  Assert.isTrue(type(pngs[particles.textures[1].image]) == "string", "decoded texture pixels are embedded as a staged PNG")
  Assert.equal(provenance.archiveSymbol, source.archiveSymbol, "producer provenance records the selected archive")
  Assert.equal(provenance.memberId, source.memberId, "producer provenance records the selected member")
  Assert.isTrue(type(provenance.particleMemberHash) == "string", "producer provenance records the member content hash")
  Assert.isNil(particles.archiveSymbol, "the runtime payload has no source archive identity")
  Assert.isNil(particles.memberId, "the runtime payload has no source member identity")
end

function T.evolution_source_rejects_a_member_with_the_wrong_emitter_count()
  local romFs = romFsForMember(SplMemberFixture.member(12, 1))
  local ok, failure = pcall(BattlePresentationCompiler.compileEvolutionParticles, romFs)
  Assert.isFalse(ok, "a source member without all thirteen emitters fails compilation")
  Assert.isTrue(tostring(failure):find("BATTLE_PARTICLES_INVALID", 1, true) ~= nil, "the error identifies invalid particle source data")
end

return { tests = T }
