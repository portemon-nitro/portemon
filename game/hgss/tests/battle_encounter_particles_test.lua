-- The battle encounter particle owner: two retail emitter sets start on
-- their own encounter-animation frames (Task_PlayEncounterAnimation), each in
-- its own particle system, and keep simulating after the animation ends
-- until their emitters retire.

local Assert = require("tests.support.Assert")
local BattleEncounterParticles = require("game.hgss.src.battle.BattleEncounterParticles")
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

function T.a_late_scene_layer_starts_the_sets_late()
  local owner = BattleEncounterParticles.new()
  owner:step(5, nil)
  Assert.equal(#owner:systems(), 0, "no staged sets means nothing to run")
  owner:step(6, stagedSets())
  Assert.equal(#owner:systems(), 1, "the first set starts once its art is available")
end

function T.clear_drops_every_system_and_allows_a_fresh_run()
  local owner = BattleEncounterParticles.new()
  local sets = stagedSets()
  owner:step(1, sets)
  owner:clear()
  Assert.equal(#owner:systems(), 0, "clear drops live systems")
  owner:step(1, sets)
  Assert.equal(#owner:systems(), 1, "a fresh run starts again")
end

return { tests = T }
