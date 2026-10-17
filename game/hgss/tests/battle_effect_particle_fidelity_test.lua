-- Native particle fidelity at the production task boundary: pinned
-- particle members resolve to their own semantic resources, creation
-- words carry their emitter position with that resource, the source
-- clock advances effect age deterministically while reads stay free of
-- side effects, and no visual step may consume the mechanics random
-- stream. Setup below holds today through the real producer and scene
-- paths; the measurement gate drives the battle-private effect task
-- factory once it exists.
-- Native mechanism: the overlay-7 particle words and their emitter,
-- lifetime, trajectory, color, alpha, and size behavior with child
-- emission (pret/pokeheartgold@9d8b7591f09b65804da2fb2dfd56f320633e0d36).
-- Headless: synthetic command streams use the real producer lowering and
-- the shared program shape; the recorder doubles record only.

local Assert = require("tests.support.Assert")
local BattleAnimationCompiler = require("romdump.src.digest.battle.BattleAnimationCompiler")
local BattleAnimationSchema = require("libs.assets.src.battle.BattleAnimationSchema")
local BattleAnimationSources = require("romdump.src.config.BattleAnimationSources")
local BattleScene = require("libs.hgss.src.presentation.BattleScene")

local T = {}

local function u32(value)
  return string.char(
    value % 256,
    math.floor(value / 256) % 256,
    math.floor(value / 65536) % 256,
    math.floor(value / 16777216) % 256
  )
end

local function streamOf(list)
  local parts = {}
  for _, word in ipairs(list) do
    parts[#parts + 1] = u32(word)
  end
  return table.concat(parts)
end

local function lowered(key, list)
  local program = assert(BattleAnimationCompiler.compile({ key = key, stream = streamOf(list) }))
  Assert.isTrue(
    BattleAnimationSchema.assertProgram({
      entry = program.entry,
      instructions = program.instructions,
      subprograms = program.subprograms,
      taskKinds = program.taskKinds,
    }),
    "the lowered program validates against the shared program shape"
  )
  return program
end

local function sceneWithPair()
  local scene = BattleScene.new()
  scene:observe({
    { combatant = 1, activation = 1, visible = true },
    { combatant = 3, activation = 3, visible = true },
  })
  return scene
end

local function effectFactoryModule()
  local ok, Factory = pcall(require, "libs.hgss.src.presentation.BattleEffectTasks")
  Assert.isTrue(ok, "the battle-private effect task factory resolves through the presentation boundary")
  Assert.equal(type(Factory.create), "function", "the factory exposes its task construction entry point")
  return Factory
end

function T.pinned_particle_members_resolve_to_their_own_semantic_resources()
  Assert.equal(
    BattleAnimationSources.resolveParticleResource(64),
    "battle/particle/tackle",
    "the striking particle keeps its semantic resource"
  )
  Assert.equal(
    BattleAnimationSources.resolveParticleResource(27),
    "battle/particle/asleep",
    "the sleep particle keeps its semantic resource"
  )
  Assert.equal(
    BattleAnimationSources.resolveParticleResource(79),
    "battle/particle/supersonic",
    "the confusion particle keeps its semantic resource"
  )
  Assert.isNil(BattleAnimationSources.resolveParticleResource(0), "an unmapped member resolves to nothing")
  Assert.notNil(
    BattleAnimationSources.resolveParticleSource("battle/particle/tackle"),
    "the striking resource keeps its producer-side source detail"
  )
end

function T.particle_creation_lowers_with_emitter_position_and_resource()
  local foe = lowered("particle-foe-emitter", { 51, 1, 64, 50, 4 })
  Assert.equal(foe.instructions[1].op, "create-battler-effect", "the creation word keeps its own operation")
  Assert.equal(foe.instructions[1].emitterPosition, "solo-enemy", "the foe emitter keeps its battler position")
  Assert.equal(
    foe.instructions[1].resource,
    "battle/particle/tackle",
    "the foe emission keeps its semantic resource"
  )
  Assert.equal(
    foe.instructions[1].taskKind,
    "battler-effect-continuation",
    "the foe emission keeps its continuation kind"
  )
  local ally = lowered("particle-ally-emitter", { 51, 0, 27, 50, 4 })
  Assert.equal(ally.instructions[1].emitterPosition, "solo-player", "the ally emitter keeps its battler position")
  Assert.equal(
    ally.instructions[1].resource,
    "battle/particle/asleep",
    "the ally emission keeps its own semantic resource"
  )
  Assert.isTrue(
    foe.instructions[1].resource ~= ally.instructions[1].resource,
    "two emitters never share one collapsed resource"
  )
end

function T.source_ticks_advance_effect_age_deterministically_and_reads_stay_pure()
  local first = sceneWithPair()
  local second = sceneWithPair()
  local firstEffect = first:allocEffect("particle-probe")
  local secondEffect = second:allocEffect("particle-probe")
  for _ = 1, 10 do
    for _ = 1, 3 do
      first:effectViews()
    end
    first:stepSourceTick()
    second:stepSourceTick()
  end
  local function ageOf(scene, id)
    for _, view in ipairs(scene:effectViews()) do
      if view.id == id then
        return view.age
      end
    end
    return nil
  end
  Assert.equal(ageOf(first, firstEffect.id), 10, "ten accepted ticks age the effect by ten")
  Assert.equal(
    ageOf(first, firstEffect.id),
    ageOf(second, secondEffect.id),
    "the same tick count gives the same age on both scenes"
  )
  for _ = 1, 5 do
    first:stepSourceTick()
  end
  Assert.equal(ageOf(first, firstEffect.id), 15, "further ticks advance the age by exactly their count")
end

function T.particle_spawn_lifetime_and_render_match_source_measurements_under_a_fixed_seed()
  local Factory = effectFactoryModule()
  local scene = sceneWithPair()
  local draws = {}
  local randomDraws = {}
  local context = {
    actors = { attacker = 1, target = 3 },
    seed = 4242,
    random = function(bound)
      Assert.isTrue(type(bound) == "number" and bound > 0, "visual draws name a positive bound")
      randomDraws[#randomDraws + 1] = bound
      return 0
    end,
  }
  local services = { scene = scene, audio = {}, resources = {} }
  function services.resolve(key)
    return { key = key, lease = key }
  end
  function services.release(_lease) end
  local task = assert(Factory.create("battler-effect-continuation", {
    resource = "battle/particle/tackle",
    emitterPosition = "solo-enemy",
  }, context, services), "the factory constructs the particle continuation")
  local trace = {}
  for tick = 1, 30 do
    task:stepSourceTick({ tick = tick })
    trace[#trace + 1] = task:status()
    draws[#draws + 1] = #randomDraws
  end
  Assert.equal(task:status(), "complete", "the particle run reaches its own completion boundary")
  Assert.isTrue(#randomDraws > 0, "the run draws its visual randomness from the occurrence-local stream")
  local rerunScene = sceneWithPair()
  local rerunServices = { scene = rerunScene, audio = {}, resources = {} }
  function rerunServices.resolve(key)
    return { key = key, lease = key }
  end
  function rerunServices.release(_lease) end
  local rerunDraws = {}
  local rerun = assert(Factory.create("battler-effect-continuation", {
    resource = "battle/particle/tackle",
    emitterPosition = "solo-enemy",
  }, {
    actors = { attacker = 1, target = 3 },
    seed = 4242,
    random = function(bound)
      rerunDraws[#rerunDraws + 1] = bound
      return 0
    end,
  }, rerunServices), "the rerun constructs the same continuation")
  local rerunTrace = {}
  for tick = 1, 30 do
    rerun:stepSourceTick({ tick = tick })
    rerunTrace[#rerunTrace + 1] = rerun:status()
  end
  Assert.deepEqual(rerunTrace, trace, "the same seed gives the same source-tick trace at any host schedule")
  Assert.deepEqual(rerunDraws, randomDraws, "the same seed draws the same visual sequence")
  task:dispose()
  rerun:dispose()
  Assert.isTrue(#draws == 30, "every source tick of the run is observed")
end

return { tests = T }
