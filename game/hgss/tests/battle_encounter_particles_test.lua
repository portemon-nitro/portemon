-- The battle encounter particle owner: two retail emitter sets start on
-- their own encounter-animation frames (Task_PlayEncounterAnimation), each in
-- its own particle system, and keep simulating after the animation ends
-- until their emitters retire. A set starts exactly on its own start tick:
-- staged art that arrives after the tick never starts the set late.
-- Rendering reads the live systems; nothing here draws.

local Assert = require("tests.support.Assert")
local BattleEncounterParticles = require("game.hgss.src.battle.BattleEncounterParticles")
local BattlePresentationSources = require("romdump.src.config.BattlePresentationSources")
local Fixture = require("tests.support.BattleEncounterParticlesFixture")

local T = {}

local function stagedSets()
  local sets = Fixture.sets("grass/day/forest")
  for _, set in ipairs(sets) do
    for _, texture in ipairs(set.textures) do
      texture.drawable = { id = "drawable-" .. set.startTick .. "-" .. texture.id }
    end
  end
  return sets
end

local function liveParticles(owner)
  local count = 0
  for _, entry in ipairs(owner:systems()) do
    for _, runtime in ipairs(entry.simulation.emitters) do
      count = count + #runtime.particles + #runtime.children
    end
  end
  return count
end

function T.each_set_starts_on_its_own_animation_frame()
  local owner = BattleEncounterParticles.new()
  local sets = stagedSets()
  owner:step(nil, sets)
  Assert.equal(#owner:systems(), 0, "nothing starts before the animation runs")
  owner:step(1, sets)
  Assert.equal(#owner:systems(), 1, "the first set starts on frame 1")
  for frame = 2, 19 do
    owner:step(frame, sets)
  end
  Assert.equal(#owner:systems(), 1, "the second set waits for frame 20")
  owner:step(20, sets)
  Assert.equal(#owner:systems(), 2, "the second set starts on frame 20")
  Assert.equal(owner:systems()[2].textures[3], sets[2].textures[2].drawable, "textures resolve by source id")
end

function T.sets_keep_running_after_the_animation_and_retire_without_restarting()
  local owner = BattleEncounterParticles.new()
  local sets = stagedSets()
  for frame = 1, 20 do
    owner:step(frame, sets)
  end
  Assert.isTrue(liveParticles(owner) > 0, "started emitters spawn particles")
  local frame = 21
  while #owner:systems() > 0 and frame < 2000 do
    owner:step(nil, sets)
    frame = frame + 1
  end
  Assert.equal(#owner:systems(), 0, "retired systems leave the draw list")
  owner:step(1, sets)
  Assert.equal(#owner:systems(), 0, "a finished set never restarts")
end

function T.a_late_scene_layer_does_not_start_a_missed_set()
  local owner = BattleEncounterParticles.new()
  owner:step(5, nil)
  Assert.equal(#owner:systems(), 0, "nothing starts without staged art")
  owner:step(18, stagedSets())
  Assert.equal(#owner:systems(), 0, "the first set never starts after its frame-1 tick")
end

function T.sets_with_missed_start_ticks_never_start_late()
  local owner = BattleEncounterParticles.new()
  owner:step(49, stagedSets())
  Assert.equal(#owner:systems(), 0, "sets whose start ticks already passed never start")
end

function T.an_exact_start_only_starts_its_own_set()
  local owner = BattleEncounterParticles.new()
  local sets = stagedSets()
  owner:step(20, sets)
  Assert.equal(#owner:systems(), 1, "frame 20 starts exactly one set")
  Assert.equal(
    owner:systems()[1].textures[3],
    sets[2].textures[2].drawable,
    "frame 20 starts the second set, never the missed first"
  )
end

function T.staged_sets_carry_the_retail_emitter_counts()
  local grass = BattlePresentationSources.encounterParticleSets("grass")
  Assert.deepEqual(
    grass,
    {
      { member = 5, emitterCount = 5 },
      { member = 6, emitterCount = 11 },
    },
    "the grass terrain stages source members 5 and 6 with five and eleven emitters"
  )
  local sets = Fixture.sizedSets("grass/day/forest", 5, 11, 200, 200)
  local owner = BattleEncounterParticles.new()
  owner:step(1, sets)
  Assert.equal(#owner:systems(), 1, "the first set starts on frame 1")
  Assert.equal(#owner:systems()[1].simulation.emitters, 5, "the first system runs all five member-5 emitters")
  owner:step(20, sets)
  Assert.equal(#owner:systems(), 2, "the second set starts on frame 20")
  Assert.equal(#owner:systems()[2].simulation.emitters, 11, "the second system runs all eleven member-6 emitters")
  owner:step(20, sets)
  Assert.equal(#owner:systems(), 2, "started sets never start twice")
end

function T.a_retired_first_system_leaves_the_second_running()
  local sets = Fixture.sizedSets("grass/day/forest", 1, 1, 10, 43)
  local owner = BattleEncounterParticles.new()
  for frame = 1, 30 do
    owner:step(frame, sets)
  end
  Assert.equal(#owner:systems(), 1, "the retired first system leaves the second running")
  local frame = 31
  while #owner:systems() > 0 and frame < 500 do
    owner:step(nil, sets)
    frame = frame + 1
  end
  Assert.equal(#owner:systems(), 0, "the second system retires on its own emitter lifespan")
  owner:step(1, sets)
  Assert.equal(#owner:systems(), 0, "a finished set never restarts")
end

function T.clear_drops_every_system_and_allows_a_fresh_run()
  local owner = BattleEncounterParticles.new()
  local sets = stagedSets()
  owner:step(1, sets)
  owner:clear()
  Assert.equal(#owner:systems(), 0, "clear drops live systems")
  owner:step(1, sets)
  Assert.equal(#owner:systems(), 1, "a fresh run starts again")
  for frame = 2, 20 do
    owner:step(frame, sets)
  end
  Assert.equal(#owner:systems(), 2, "a fresh run restarts both sets on their own ticks")
end

return { tests = T }
