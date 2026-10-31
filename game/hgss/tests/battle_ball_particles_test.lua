-- The ball particle owner: seal, burst, and click effects start on their
-- retail ticks at their source positions, play only their emitters, wait for
-- staging textures, and never start for balls without staged particles.

local Assert = require("tests.support.Assert")
local BattleBallParticles = require("game.hgss.src.battle.BattleBallParticles")
local Fixture = require("tests.support.BattleEncounterParticlesFixture")

local T = {}

local function stagedParticles()
  local set = Fixture.sets("grass/day/forest")[1]
  local second = Fixture.sets("grass/day/forest")[1]
  second.emitters[1].id = 1
  second.emitters[1].position = { x = 0, y = 0, z = 0 }
  set.emitters[2] = second.emitters[1]
  set.emitters[1].position = { x = 0, y = 0, z = 0 }
  return { seal = set, burst = set, clickEmitter = 1, burstStartTick = 5 }
end

local function resolver(particles, ready)
  return {
    particles = function(key)
      return key == "POKE_BALL" and particles or nil
    end,
    texture = function()
      if ready.value then
        return { name = "texture" }
      end
      return nil
    end,
  }
end

local function emitterIds(owner)
  local ids = {}
  for _, runtime in ipairs(owner:systems()[1].simulation.emitters) do
    ids[#ids + 1] = runtime.id
  end
  return ids
end

function T.seal_starts_at_once_at_the_battler_origin_with_every_emitter()
  local owner = BattleBallParticles.new()
  local res = resolver(stagedParticles(), { value = true })
  owner:step({ { effect = "seal", ballKey = "POKE_BALL", battlerType = 0 } }, {}, res)
  Assert.equal(#owner:systems(), 1, "the seal system starts on its cue tick")
  Assert.deepEqual(emitterIds(owner), { 0, 1 }, "the seal creates every emitter")
  -- Solo player origin: (-10240 - 10 * 172) / 4096 world units.
  local runtime = owner:systems()[1].simulation.emitters[1]
  Assert.isTrue(math.abs(runtime.x - (-10240 - 1720) / 4096) < 1e-9, "the origin offsets the emitter x")
  Assert.isTrue(math.abs(runtime.y - (-6400 + 16 * 172 - 32 * 172) / 4096) < 1e-9, "the origin offsets the emitter y")
end

function T.burst_waits_its_start_tick_and_skips_the_click_emitter_which_plays_alone()
  local owner = BattleBallParticles.new()
  local res = resolver(stagedParticles(), { value = true })
  owner:step({ { effect = "burst", ballKey = "POKE_BALL", x = 129, y = 100 } }, {}, res)
  for _ = 1, 5 do
    Assert.equal(#owner:systems(), 0, "the burst waits for the ball to open")
    owner:step({}, {}, res)
  end
  Assert.equal(#owner:systems(), 1, "the burst starts on its staged tick")
  Assert.deepEqual(emitterIds(owner), { 0 }, "the opening burst skips the click emitter")
  Assert.equal(owner:systems()[1].simulation.emitters[1].x, 0, "a ball at (129, 100) sits on the world origin")
  local click = BattleBallParticles.new()
  click:step({ { effect = "click", ballKey = "POKE_BALL", x = 129, y = 100 } }, {}, res)
  for _ = 1, 4 do
    click:step({}, {}, res)
  end
  Assert.deepEqual(emitterIds(click), { 1 }, "the click plays only its own emitter")
end

function T.effects_wait_for_textures_and_ballless_particles_never_start()
  local owner = BattleBallParticles.new()
  local ready = { value = false }
  local res = resolver(stagedParticles(), ready)
  owner:step({ { effect = "seal", ballKey = "POKE_BALL", battlerType = 1 } }, {}, res)
  owner:step({}, {}, res)
  Assert.equal(#owner:systems(), 0, "a seal waits while its textures stage")
  ready.value = true
  owner:step({}, {}, res)
  Assert.equal(#owner:systems(), 1, "the seal starts once its textures resolve")
  local none = BattleBallParticles.new()
  none:step({ { effect = "seal", ballKey = "CHERISH_BALL", battlerType = 0 } }, {}, res)
  Assert.isTrue(none:isIdle(), "a ball without staged particles starts nothing")
end

function T.systems_retire_with_their_emitters_and_clear_drops_everything()
  local owner = BattleBallParticles.new()
  local res = resolver(stagedParticles(), { value = true })
  owner:step({ { effect = "seal", ballKey = "POKE_BALL", battlerType = 0 } }, {}, res)
  for _ = 1, 200 do
    owner:step({}, {}, res)
  end
  Assert.isTrue(owner:isIdle(), "a finished effect leaves the draw list")
  owner:step({ { effect = "seal", ballKey = "POKE_BALL", battlerType = 0 } }, {}, res)
  owner:clear()
  Assert.isTrue(owner:isIdle(), "clearing drops live systems")
end

return { tests = T }
