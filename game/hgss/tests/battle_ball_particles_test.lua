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
  local owner = BattleBallParticles.new({ splRandomState = { state = 0 } })
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
  local owner = BattleBallParticles.new({ splRandomState = { state = 0 } })
  local res = resolver(stagedParticles(), { value = true })
  owner:step({ { effect = "burst", ballKey = "POKE_BALL", x = 129, y = 100 } }, {}, res)
  for _ = 1, 5 do
    Assert.equal(#owner:systems(), 0, "the burst waits for the ball to open")
    owner:step({}, {}, res)
  end
  Assert.equal(#owner:systems(), 1, "the burst starts on its staged tick")
  Assert.deepEqual(emitterIds(owner), { 0 }, "the opening burst skips the click emitter")
  Assert.equal(owner:systems()[1].simulation.emitters[1].x, 0, "a ball at (129, 100) sits on the world origin")
  local click = BattleBallParticles.new({ splRandomState = { state = 0 } })
  click:step({ { effect = "click", ballKey = "POKE_BALL", x = 129, y = 100 } }, {}, res)
  for _ = 1, 4 do
    click:step({}, {}, res)
  end
  Assert.deepEqual(emitterIds(click), { 1 }, "the click plays only its own emitter")
end

function T.effects_wait_for_textures_and_ballless_particles_never_start()
  local owner = BattleBallParticles.new({ splRandomState = { state = 0 } })
  local ready = { value = false }
  local res = resolver(stagedParticles(), ready)
  owner:step({ { effect = "seal", ballKey = "POKE_BALL", battlerType = 1 } }, {}, res)
  owner:step({}, {}, res)
  Assert.equal(#owner:systems(), 0, "a seal waits while its textures stage")
  ready.value = true
  owner:step({}, {}, res)
  Assert.equal(#owner:systems(), 1, "the seal starts once its textures resolve")
  local none = BattleBallParticles.new({ splRandomState = { state = 0 } })
  none:step({ { effect = "seal", ballKey = "CHERISH_BALL", battlerType = 0 } }, {}, res)
  Assert.isTrue(none:isIdle(), "a ball without staged particles starts nothing")
end

function T.systems_retire_with_their_emitters_and_clear_drops_everything()
  local owner = BattleBallParticles.new({ splRandomState = { state = 0 } })
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

function T.started_systems_use_the_source_orthographic_camera()
  -- The seal, burst, and click effects all select the orthographic
  -- camera: particle size never depends on perspective depth on this
  -- path.
  local owner = BattleBallParticles.new({ splRandomState = { state = 0 } })
  local res = resolver(stagedParticles(), { value = true })
  owner:step({ { effect = "seal", ballKey = "POKE_BALL", battlerType = 0 } }, {}, res)
  Assert.equal(#owner:systems(), 1, "the seal system starts on its cue tick")
  Assert.equal(
    owner:systems()[1].simulation.camera.perspective,
    1,
    "the seal system selects the orthographic camera"
  )
end

function T.started_systems_carry_the_compiled_alpha_usage()
  -- The staged set's exact coverage flags ride the live system beside
  -- the drawable handles for the shared depth/blend classification.
  local owner = BattleBallParticles.new({ splRandomState = { state = 0 } })
  local particles = stagedParticles()
  local res = resolver(particles, { value = true })
  owner:step({ { effect = "seal", ballKey = "POKE_BALL", battlerType = 0 } }, {}, res)
  local usage = owner:systems()[1].textureAlphaUsage
  Assert.notNil(usage, "the started system carries the compiled usage table")
  for _, texture in ipairs(particles.seal.textures) do
    Assert.deepEqual(
      usage[texture.id],
      texture.alphaUsage,
      "texture " .. tostring(texture.id) .. " keeps its exact coverage flags"
    )
  end
end

function T.sets_without_alpha_usage_fail_loudly()
  -- A staged seal set without its texture coverage flags fails loudly
  -- instead of hardening translucent texels into the cutout/opaque
  -- classification.
  local owner = BattleBallParticles.new({ splRandomState = { state = 0 } })
  local particles = stagedParticles()
  for _, texture in ipairs(particles.seal.textures) do
    texture.alphaUsage = nil
  end
  local res = resolver(particles, { value = true })
  local ok, err = pcall(function()
    owner:step({ { effect = "seal", ballKey = "POKE_BALL", battlerType = 0 } }, {}, res)
  end)
  Assert.isFalse(ok, "a seal without texture alpha usage never starts silently")
  Assert.isTrue(type(err) == "string" and err ~= "", "the missing coverage flags name their contract")
end

function T.draw_systems_publish_the_pre_advance_frame()
  -- The compositor paints the published pre-advance geometry while the
  -- live systems advance underneath.
  local owner = BattleBallParticles.new({ splRandomState = { state = 0 } })
  local res = resolver(stagedParticles(), { value = true })
  owner:step({ { effect = "seal", ballKey = "POKE_BALL", battlerType = 0 } }, {}, res)
  local live = owner:systems()[1].simulation
  local published = owner:drawSystems()[1].simulation
  Assert.equal(
    #published.emitters,
    #live.emitters,
    "the first capture precedes the first simulation tick"
  )
  for index in ipairs(published.emitters) do
    Assert.equal(
      #published.emitters[index].particles,
      0,
      "newborn emitters carry no particles before their first tick"
    )
  end
  Assert.isTrue(#live.emitters[1].particles > 0, "the live simulation advanced once underneath")
end

-- Every particle consumer borrows the one boot stream instead of reading a
-- staged numeric seed: opening, encounter, ball, and move managers consume
-- one continuous sequence until a new selected boot replaces the record.
function T.ball_particles_borrow_the_boot_stream_record()
  local boot = { state = 0 }
  local ok, owner = pcall(BattleBallParticles.new, { splRandomState = boot, scene = nil })
  Assert.isTrue(ok, "ball particles construct against the borrowed boot stream")
  if ok then
    Assert.isTrue(
      owner._splRandomState == boot,
      "ball managers draw from the shared boot record instead of a private seed"
    )
  end
end

return { tests = T }
