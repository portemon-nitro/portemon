local Assert = require("tests.support.Assert")
local SplEmitterCompiler = require("romdump.src.digest.particle.SplEmitterCompiler")
local SplMemberFixture = require("tests.support.SplMemberFixture")
local BattleEvolutionParticles = require("game.hgss.src.battle.BattleEvolutionParticles")

local T = {}

---@return table<string, unknown> compiled 13-emitter test resource
local function particleSet()
  local result, err = SplEmitterCompiler.compile(SplMemberFixture.member(13, 1), { embedPixels = true })
  assert(result ~= nil, tostring(err))
  local textures = {}
  for _, texture in ipairs(result.particles.textures) do
    textures[#textures + 1] = { id = texture.id, drawable = { id = texture.id } }
  end
  return {
    seed = result.particles.seed,
    emitters = result.particles.emitters,
    textures = textures,
  }
end

function T.evolution_scene_creates_requested_emitters_in_one_live_system()
  local particles = BattleEvolutionParticles.new({ set = particleSet(), emitterPosition = { x = 0, y = 0x560 / 4096, z = 0 } })
  particles:createEmitter(0)
  particles:createEmitter(1)
  local systems = particles:systems()
  Assert.equal(#systems, 1, "the retail ParticleScene owns one SPL system")
  Assert.equal(#systems[1].simulation.emitters, 2, "created emitters share that system")
  Assert.equal(systems[1].simulation.emitters[1].y, 0x560 / 4096, "emitters use ParticleScene_SetEmitterPosition")
  local emitterAge = systems[1].simulation.emitters[1].age
  particles:advance()
  Assert.equal(
    particles:systems()[1].simulation.emitters[1].age,
    emitterAge + 1,
    "the evolution scene particle owner advances on each presentation tick"
  )
  Assert.isTrue(particles:isActive(), "live emitters hold the scene active")
  particles:clear()
  Assert.isFalse(particles:isActive(), "clearing the scene retires its active state")
  Assert.equal(#particles:systems(), 0, "clearing removes the draw system")
end

return { tests = T }
