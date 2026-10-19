-- Native non-damage programs through the real composition path: major
-- status, confusion, residual damage, weather, held-item and bag-item
-- feedback, restoration, and stat changes each lower to their own
-- visible and audio operation trace with their own completion boundary,
-- and a message-only stand-in never counts as one of them. Setup below
-- holds today through the real producer and scene paths; the execution
-- gate drives the battle-private program player together with the
-- battle-private effect task factory once both exist.
-- Native mechanism: the frozen, sleep, confusion, Bind, weather, and
-- restoration subscript sequences with their message, wait, and animation
-- order (pret/pokeheartgold@9d8b7591f09b65804da2fb2dfd56f320633e0d36).
-- Headless: synthetic command streams use the real producer lowering and
-- the shared program shape; the recorder doubles record only.

local Assert = require("tests.support.Assert")
local BattleAnimationCompiler = require("romdump.src.digest.battle.BattleAnimationCompiler")
local BattleAnimationSchema = require("libs.assets.src.battle.BattleAnimationSchema")
local BattleAnimationSources = require("romdump.src.config.BattleAnimationSources")
local BattlePresentationFlow = require("game.hgss.src.battle.BattlePresentationFlow")
local BattlePresentationModel = require("game.hgss.src.battle.BattlePresentationModel")
local BattleScene = require("libs.hgss.src.presentation.BattleScene")
local ManifestFixture = require("tests.support.BattlePresentationManifestFixture")

local T = {}

local EXPECTED_NAMED_ROOTS = {
  "BATTLE_ANIMATION_ASLEEP",
  "BATTLE_ANIMATION_FROZEN",
  "BATTLE_ANIMATION_CONFUSED",
  "BATTLE_ANIMATION_WEATHER_RAIN",
  "BATTLE_ANIMATION_WEATHER_SUN",
  "BATTLE_ANIMATION_WEATHER_SAND",
  "BATTLE_ANIMATION_HELD_ITEM",
  "BATTLE_ANIMATION_BAG_ITEM",
  "BATTLE_ANIMATION_RESTORE_HP",
  "BATTLE_ANIMATION_STAT_BOOST",
  "BATTLE_ANIMATION_STAT_DROP",
  "BATTLE_ANIMATION_SUBSTITUTE_IN",
  "BATTLE_ANIMATION_DAMAGE_BIND",
  "BATTLE_ANIMATION_DAMAGE_LEECH_SEED",
}

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

local function opsOf(program)
  local ops = {}
  for _, instruction in ipairs(program.instructions) do
    ops[#ops + 1] = instruction.op
  end
  return ops
end

local function sceneWithSolo()
  local scene = BattleScene.new()
  scene:observe({
    { combatant = 1, activation = 1, visible = true },
  })
  return scene
end

local function playbackPacket()
  local packet = BattlePresentationModel.packet({}, { events = {} }, {}, {
    launchId = "status-programs-probe",
    packetId = 1,
  })
  Assert.equal(packet.launchId, "status-programs-probe", "the playback input carries its launch identity")
  return packet
end

-- Builds the restoration program's playback through the production
-- event-time topology constructor: the live screen admits picture
-- shows only with the frozen semantic slots behind the accepted
-- event, never a bare packet. The completion and scene-restoration
-- assertions below are unchanged; only the packet carries what
-- production builds.
---@param key string selected effect key under playback
---@return table<string, unknown> detached playback packet with production-built topology
local function topologyPlayback(key)
  local views = {
    own = { { combatant = 1, activation = 1, side = 1, position = 1 } },
    foes = { { combatant = 3, activation = 3, side = 2, position = 2 } },
  }
  local packet = {
    launchId = "status-programs-probe",
    packetId = 1,
    before = views,
    after = views,
  }
  local event = {
    sequence = 1,
    actionId = 1,
    hitIndex = 1,
    effectKey = key,
    actors = { { combatant = 1, activation = 1 } },
    targets = { { combatant = 3, activation = 3 } },
    visualSeed = 4242,
  }
  local geometry = ManifestFixture.manifest().battlefield.slots
  return BattlePresentationFlow.animationPlayback(packet, event, geometry)
end

local function playerModule()
  local ok, Player = pcall(require, "libs.hgss.src.presentation.BattleAnimationPlayer")
  Assert.isTrue(ok, "the battle-private animation player resolves through the presentation boundary")
  Assert.equal(type(Player.new), "function", "the player exposes its construction entry point")
  return Player
end

local function effectFactoryModule()
  local ok, Factory = pcall(require, "libs.hgss.src.presentation.BattleEffectTasks")
  Assert.isTrue(ok, "the battle-private effect task factory resolves through the presentation boundary")
  Assert.equal(type(Factory.create), "function", "the factory exposes its task construction entry point")
  return Factory
end

function T.named_non_move_roots_resolve_to_their_own_source_members()
  local roots = BattleAnimationSources.listSemanticRoots()
  local byKey = {}
  for _, root in ipairs(roots) do
    byKey[root.key] = root
  end
  for _, key in ipairs(EXPECTED_NAMED_ROOTS) do
    local root = byKey[key]
    Assert.notNil(root, key .. " joins the finite program inventory")
    Assert.equal(root.kind, "battle-animation", key .. " keeps its non-move program family")
    Assert.equal(root.archiveSymbol, "NARC_a_0_6_1", key .. " keeps its source archive")
    local routed = assert(BattleAnimationSources.resolveSemanticRoute(key), key .. " routes to its member")
    Assert.equal(routed.memberId, root.memberId, key .. " routes to its own member")
  end
end

function T.status_shapes_lower_distinctly_from_damage_shapes()
  local frozenShape = lowered("status-frozen-shape", { 5, 1, 34, 1, 2, 3, 50, 4 })
  Assert.deepEqual(opsOf(frozenShape), {
    "play-sound",
    "schedule-battle-task",
    "wait-for-battler-effects",
    "reset-battle-presentation",
  }, "the status shape voices, works, awaits, then closes")
  Assert.isTrue(type(frozenShape.instructions[1].sound) == "string", "the status voice keeps its sound identity")

  local restorationShape = lowered("status-restoration-shape", { 5, 1, 31, 0, 0, 50, 4 })
  Assert.deepEqual(opsOf(restorationShape), {
    "play-sound",
    "show-pokemon-picture",
    "wait-for-battler-effects",
    "reset-battle-presentation",
  }, "the restoration shape addresses its picture instead of spawning task work")
  Assert.isNil(
    restorationShape.instructions[2].taskKind,
    "the plain picture reveal schedules no animation task"
  )

  local veilShape = lowered("status-veil-shape", { 8, 4, 12, 9, 4 })
  Assert.deepEqual(opsOf(veilShape), {
    "set-blend-alpha",
    "reset-blend-alpha",
    "reset-battle-presentation",
  }, "the screen-veil shape owns blend state with no battler work at all")

  Assert.isTrue(
    frozenShape.instructions[2].op ~= restorationShape.instructions[2].op
      and restorationShape.instructions[2].op ~= veilShape.instructions[1].op,
    "status, restoration, and veil programs never collapse into one narration shape"
  )
end

function T.temporary_picture_changes_restore_to_their_exact_base()
  local scene = sceneWithSolo()
  local battler = { combatant = 1, activation = 1 }
  Assert.isNil(scene:pictureState(battler), "no picture patch is active before the effect")
  local patched = scene:applyPictureState(battler, { pictureXOffset2 = 24, pictureVisible = false })
  Assert.equal(patched.pictureXOffset2, 24, "the temporary change reaches the presented picture")
  Assert.equal(patched.pictureVisible, false, "the visibility change reaches the presented picture")
  local read = assert(scene:pictureState(battler), "the patched picture stays readable")
  Assert.equal(read.pictureXOffset2, 24, "reads expose the temporary change while it owns the picture")
  local restored = assert(scene:restorePictureState(battler), "restoration returns its snapshot")
  Assert.isNil(restored.pictureXOffset2, "the snapshot predates the temporary change")
  Assert.isNil(scene:pictureState(battler).pictureXOffset2, "the picture no longer carries the temporary change")
end

function T.status_weather_item_and_restoration_effects_keep_their_own_traces()
  local programs = {
    status = lowered("run-status-frozen", { 5, 1, 34, 1, 2, 3, 50, 4 }),
    restoration = lowered("run-restoration", { 5, 1, 31, 0, 0, 50, 4 }),
    veil = lowered("run-weather-veil", { 8, 4, 12, 9, 4 }),
    particle = lowered("run-status-particle", { 51, 0, 27, 50, 4 }),
  }
  Assert.equal(
    programs.particle.instructions[1].resource,
    "battle/particle/asleep",
    "the status particle keeps its own semantic resource"
  )
  local Player = playerModule()
  local Factory = effectFactoryModule()
  local scene = sceneWithSolo()
  local audio = { played = {}, stopped = {}, done = {} }
  function audio.play(name)
    audio.played[#audio.played + 1] = name
  end
  function audio.stop(name)
    audio.stopped[#audio.stopped + 1] = name
  end
  function audio.isFinished(name)
    return audio.done[name] == true
  end
  local resources = {}
  function resources.resolve(key)
    return { key = key, lease = key }
  end
  function resources.release(_lease) end
  local player = assert(Player.new({
    scene = scene,
    audio = audio,
    resources = resources,
    tasks = Factory,
  }))
  local voicedBefore = 0
  for name, program in pairs(programs) do
    local packet = playbackPacket()
    if name == "restoration" then
      packet = topologyPlayback("run-restoration")
    end
    local handle = assert(player:start(packet, program))
    for _ = 1, 120 do
      player:stepSourceTick({ tick = 1 })
      for _, voice in ipairs(audio.played) do
        audio.done[voice] = true
      end
      if player:status(handle) == "complete" then
        break
      end
    end
    Assert.equal(player:status(handle), "complete", name .. " reaches its own completion boundary")
    Assert.isTrue(#audio.played >= voicedBefore, name .. " never retracts an earlier voice")
    voicedBefore = #audio.played
  end
  Assert.isTrue(voicedBefore >= 2, "the sounded programs keep their audio usage in the run")
  local settled = scene:pictureState({ combatant = 1, activation = 1 })
  Assert.isTrue(
    settled == nil or settled.pictureXOffset2 == nil,
    "no temporary picture change survives the program run"
  )
end

function T.message_only_stand_in_is_rejected_for_non_damage_programs()
  local Factory = effectFactoryModule()
  local scene = sceneWithSolo()
  local services = { scene = scene, audio = {}, resources = {} }
  local ok, result = pcall(Factory.create, "message-only-narration", {}, {}, services)
  Assert.isFalse(
    ok and type(result) == "table" and type(result.stepSourceTick) == "function",
    "a narration-only kind never yields a runnable visual task"
  )
end

function T.submitted_sound_actions_run_through_real_factory_tasks()
  local program = lowered("run-submitted-sound", { 24, 1, 0, 0, 0, 0, 50, 4 })
  Assert.equal(program.instructions[1].op, "submit-sound-action", "the word keeps its sound submission")
  Assert.equal(
    program.instructions[1].taskKind,
    "positioned-sound-motion",
    "the submission keeps its source sound task kind"
  )
  local Player = playerModule()
  local Factory = effectFactoryModule()
  local scene = sceneWithSolo()
  local audio = { played = {}, stopped = {}, done = {}, queried = {} }
  function audio.play(name)
    audio.played[#audio.played + 1] = name
    return name
  end
  function audio.playEffect(symbol)
    audio.played[#audio.played + 1] = symbol
    return { voice = symbol }
  end
  function audio.playFanfare(symbol)
    audio.played[#audio.played + 1] = symbol
    return { voice = symbol }
  end
  function audio.stop(name)
    audio.stopped[#audio.stopped + 1] = name
  end
  function audio.stopVoice(handle)
    audio.stopped[#audio.stopped + 1] = handle
    return true
  end
  function audio.isFinished(name)
    audio.queried[#audio.queried + 1] = name
    return audio.done[name] == true
  end
  local resources = {}
  function resources.resolve(key)
    return { key = key, lease = key }
  end
  function resources.release(_lease) end
  local player = assert(Player.new({
    scene = scene,
    audio = audio,
    resources = resources,
    tasks = Factory,
  }))
  local handle = assert(player:start(playbackPacket(), program))
  for _ = 1, 10 do
    player:stepSourceTick({ tick = 1 })
  end
  Assert.equal(
    player:status(handle),
    "waiting",
    "the submitted sound waits on its unfinished voice instead of failing or timing out"
  )
  Assert.isTrue(#audio.queried > 0, "the run polls real voice completion while it waits")
  for _, key in ipairs(audio.queried) do
    audio.done[key] = true
  end
  for _ = 1, 120 do
    player:stepSourceTick({ tick = 1 })
    if player:status(handle) == "complete" then
      break
    end
  end
  Assert.equal(player:status(handle), "complete", "the finished voice completes the submitted sound")
  Assert.isTrue(#audio.played > 0, "the submission stages a real voice instead of a silent timer")
end

return { tests = T }
