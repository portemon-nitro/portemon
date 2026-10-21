-- Native move shapes through the real composition path: direct-contact,
-- projectile and particle, screen-wide background and palette, multi
-- picture, looping charge and release, parameter-called, and picture
-- visibility programs each lower to their own operation order with their
-- own completion boundary, and no single generic shape covers two of them.
-- Setup below holds today through the real producer path; the execution
-- gate drives the battle-private program player together with the
-- battle-private effect task factory once both exist.
-- Native mechanism: asm/overlay_07.s task-spawn, particle, blend, branch,
-- loop, and picture words with the called-move overlays
-- (pret/pokeheartgold@9d8b7591f09b65804da2fb2dfd56f320633e0d36).
-- Headless: synthetic command streams use the real producer lowering and
-- the shared program shape; the recorder doubles record only.

local Assert = require("tests.support.Assert")
local BattleAnimationCompiler = require("romdump.src.digest.battle.BattleAnimationCompiler")
local BattleAnimationSchema = require("libs.assets.src.battle.BattleAnimationSchema")
local BattlePresentationModel = require("game.hgss.src.battle.BattlePresentationModel")
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

local function lowered(key, list, extra)
  local probe = { key = key, stream = streamOf(list) }
  if extra ~= nil then
    for field, value in pairs(extra) do
      probe[field] = value
    end
  end
  local program = assert(BattleAnimationCompiler.compile(probe))
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

local function sceneWithPair()
  local scene = BattleScene.new()
  scene:observe({
    { combatant = 1, activation = 1, visible = true },
    { combatant = 3, activation = 3, visible = true },
  })
  return scene
end

local function playbackPacket()
  local packet = BattlePresentationModel.packet({}, { events = {} }, {}, {
    launchId = "move-shapes-probe",
    packetId = 1,
  })
  Assert.equal(packet.launchId, "move-shapes-probe", "the playback input carries its launch identity")
  packet.event = { sequence = 1, actionId = 1, hitIndex = 1, effectKey = "move-shapes-probe" }
  packet.visualSeed = 1
  packet.topology = {
    attacker = { combatant = 1, activation = 1, slot = "solo-player", sideType = 0 },
    targets = { { combatant = 3, activation = 3, slot = "solo-enemy", sideType = 1 } },
  }
  return packet
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

local function vanishedResolver()
  return function(role, _operands)
    Assert.equal(role, "battle-animation-callback", "the picture word asks for its source callback")
    return {
      op = "set-pokemon-picture-vanished",
      pictureSets = { "all-battler-positions" },
      vanished = true,
    }
  end
end

function T.contact_projectile_and_wide_shapes_keep_their_own_operation_order()
  local contact = lowered("shape-contact", { 34, 1, 2, 3, 50, 4 })
  Assert.deepEqual(opsOf(contact), {
    "schedule-battle-task",
    "wait-for-battler-effects",
    "reset-battle-presentation",
  }, "contact work spawns its task, awaits its effects, then closes the presentation")
  Assert.equal(#contact.taskKinds, 1, "the contact shape reaches exactly one task kind")

  local projectile = lowered("shape-projectile", { 51, 1, 64, 50, 4 })
  Assert.deepEqual(opsOf(projectile), {
    "create-battler-effect",
    "wait-for-battler-effects",
    "reset-battle-presentation",
  }, "projectile work creates its particle effect before awaiting it")
  Assert.equal(projectile.instructions[1].emitterPosition, "solo-enemy", "the particle leaves its own battler")
  Assert.equal(
    projectile.instructions[1].resource,
    "battle/particle/tackle",
    "the particle carries its own semantic resource"
  )

  local wide = lowered("shape-wide-screen", { 8, 16, 0, 17, 2, 8, 9, 4 })
  Assert.deepEqual(opsOf(wide), {
    "set-blend-alpha",
    "set-background-component",
    "reset-blend-alpha",
    "reset-battle-presentation",
  }, "screen-wide work owns blend and background state instead of battler tasks")
  Assert.deepEqual(wide.instructions[1].values, { 16, 0 }, "the blend coefficients keep source order")

  Assert.isTrue(
    contact.instructions[1].op ~= projectile.instructions[1].op
      and projectile.instructions[1].op ~= wide.instructions[1].op,
    "no single generic shape covers contact, projectile, and screen-wide work"
  )
end

function T.multi_picture_loop_called_and_visibility_shapes_keep_their_boundaries()
  local multi = lowered("shape-multi-picture", { 31, 0, 1, 31, 1, 1, 50, 4 })
  Assert.equal(multi.instructions[1].op, "show-pokemon-picture", "the first picture addresses its battler")
  Assert.equal(multi.instructions[2].op, "show-pokemon-picture", "the second picture addresses its own battler")
  Assert.isTrue(
    multi.instructions[1].values[1] ~= multi.instructions[2].values[1],
    "the two pictures keep distinct battler selectors"
  )
  Assert.equal(multi.instructions[2].op, "show-pokemon-picture", "both pictures share the closing wait")
  Assert.equal(multi.instructions[#multi.instructions].op, "reset-battle-presentation", "the pair closes its presentation")

  local looped = lowered("shape-charge-release", { 2, 2, 1, 5, 1, 3, 4 })
  Assert.deepEqual(opsOf(looped), {
    "reserve-loop-slot",
    "wait-interpreter-counter",
    "play-sound",
    "advance-loop-slot",
    "reset-battle-presentation",
  }, "charge and release work loops its voice before closing")
  Assert.equal(looped.instructions[3].sound, "SEQ_PV001", "the looped voice keeps its pinned sound identity")

  local called = lowered("shape-called-move", { 30, 0, 7, 16, 5, 1, 4 })
  Assert.equal(called.instructions[1].op, "branch-on-parameter", "the called shape selects on its parameter")
  Assert.equal(called.instructions[2].op, "play-sound", "the selected arm keeps its voice")
  Assert.equal(
    called.instructions[1].branchTarget,
    2,
    "the parameter branch lands on its own instruction boundary"
  )

  local vanished = lowered("shape-transformation", { 45, 9, 0, 4 }, {
    resolveSourceInput = vanishedResolver(),
  })
  Assert.equal(vanished.instructions[1].op, "set-pokemon-picture-vanished", "the visibility word keeps its own operation")
  Assert.isTrue(vanished.instructions[1].vanished, "the visibility word records its picture state")
end

function T.shapes_execute_with_source_order_targets_completion_and_audio()
  local programs = {
    lowered("run-contact", { 34, 1, 2, 3, 50, 4 }),
    lowered("run-projectile", { 51, 1, 64, 50, 4 }),
    lowered("run-wide-screen", { 8, 16, 0, 17, 2, 8, 9, 4 }),
    lowered("run-multi-picture", { 31, 0, 1, 31, 1, 1, 50, 4 }),
    lowered("run-charge-release", { 2, 2, 1, 5, 1, 3, 4 }),
    lowered("run-called-move", { 30, 0, 7, 16, 5, 1, 4 }),
    lowered("run-transformation", { 45, 9, 0, 4 }, {
      resolveSourceInput = vanishedResolver(),
    }),
  }
  local Player = playerModule()
  local Factory = effectFactoryModule()
  local scene = sceneWithPair()
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
    local params = {}
    for index = 1, 42 do
      params[index] = 0
    end
    params[29], params[30], params[24], params[32] = 12, 12, 0, 1
    return {
      key = key,
      kind = "particle-emitter",
      payloadPath = "probe/particle-emitter",
      data = { features = { "alpha", "random" }, params = params },
    }
  end
  function resources.release(_lease) end
  local player = assert(Player.new({
    scene = scene,
    audio = audio,
    resources = resources,
    tasks = Factory,
  }))
  for _, program in ipairs(programs) do
    for _, name in ipairs(audio.played) do
      audio.done[name] = true
    end
    local voicedBefore = #audio.played
    local handle = assert(player:start(playbackPacket(), program))
    for _ = 1, 120 do
      player:stepSourceTick({ tick = 1 })
      for _, name in ipairs(audio.played) do
        audio.done[name] = true
      end
      if player:status(handle) == "complete" or player:status(handle) == "failed" then
        break
      end
    end
    if program.key == "run-contact" then
      -- The contact shape schedules its blend without compiled timing
      -- operands (opcode 34), so the run fails closed with instruction
      -- provenance instead of retiring the spawn silently.
      Assert.equal(player:status(handle), "failed", program.key .. " fails closed on its timing-less spawn")
      local fault = player:failure(handle)
      Assert.isTrue(type(fault) == "table", program.key .. " carries its failure detail")
      assert(type(fault) == "table", "the shape failure stays available")
      Assert.isTrue(
        string.find(tostring(fault.reason), "BATTLE_EFFECT_TASK_MALFORMED", 1, true) ~= nil,
        program.key .. " fails on the malformed timing-less spawn: " .. tostring(fault.reason)
      )
    else
      Assert.equal(player:status(handle), "complete", program.key .. " reaches its own completion boundary")
    end
    Assert.isTrue(#audio.played >= voicedBefore, program.key .. " never retracts an earlier voice")
  end
  local sounded = 0
  for _, program in ipairs(programs) do
    for _, instruction in ipairs(program.instructions) do
      if instruction.op == "play-sound" then
        sounded = sounded + 1
      end
    end
  end
  Assert.isTrue(sounded >= 2, "the sounded shapes keep their audio usage in the run")
  Assert.isTrue(#audio.played >= 1, "at least one sounded shape played its voice during the run")
end

local PAIR_POSITIONS = {
  "solo-player",
  "solo-enemy",
  "player-side-slot-1",
  "enemy-side-slot-1",
  "player-side-slot-2",
  "enemy-side-slot-2",
}

local function pairCases()
  local cases = {}
  for _, attacker in ipairs(PAIR_POSITIONS) do
    for _, target in ipairs(PAIR_POSITIONS) do
      cases[attacker .. "/" .. target] = "battle/particle-emitter/standby"
    end
  end
  cases["solo-player/solo-enemy"] = "battle/particle-emitter/candidate-1"
  cases["solo-enemy/solo-player"] = "battle/particle-emitter/candidate-4"
  return cases
end

local function pairProgram(key)
  return {
    key = key,
    entry = "main",
    instructions = {
      {
        op = "create-parameterized-battler-effect",
        taskKind = "battler-effect-continuation",
        actionProfile = "particle-emitter-target-battler-relative",
        emitterPosition = "solo-enemy",
        runtimeSelection = "battler-particle-position-pair",
        resourceCases = pairCases(),
      },
      { op = "wait-for-battler-effects" },
    },
    subprograms = {},
    taskKinds = {},
  }
end

local function pairPlayback(packetId, attackerSlot, attackerType, targetSlot, targetType)
  return {
    launchId = "pair-selection-probe",
    packetId = packetId,
    event = { sequence = 11, actionId = 3, hitIndex = 1, effectKey = "pair-selection-probe" },
    visualSeed = 777,
    topology = {
      attacker = { combatant = 1, activation = 7, slot = attackerSlot, sideType = attackerType },
      targets = { { combatant = 2, activation = 9, slot = targetSlot, sideType = targetType } },
    },
  }
end

local function runToCompletion(player, handle)
  for _ = 1, 30 do
    player:stepSourceTick({ tick = 1 })
    if player:status(handle) == "complete" or player:status(handle) == "failed" then
      break
    end
  end
end

-- Position-pair emitters resolve through the event-time topology: the
-- occurrence leases only the resource published for its own attacker and
-- target slots, spawns its emitter exactly once across parked ticks, and
-- a second occurrence with the reverse pair leases only its own
-- resource without touching the first.
-- Native mechanism: the attacker/target particle lookup tables select
-- the emitter by position pair, with one semantic resource per pair.
-- Headless: a synthetic pair table with two distinct resources; the
-- recorder doubles count leases and spawns.
function T.position_pair_selects_only_its_matching_emitter_resource()
  local Player = playerModule()
  local scene = sceneWithPair()
  local leased = {}
  local spawned = {}
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
  local tasks = {}
  function tasks.create(kind, args, _context, _services)
    spawned[#spawned + 1] = { kind = kind, resource = args.resource }
    local task = { _state = "running" }
    function task.stepSourceTick(_tick)
      task._state = "complete"
    end
    function task.status()
      return task._state
    end
    function task.cancel(_reason)
      task._state = "cancelled"
    end
    function task.dispose() end
    return task
  end
  local resources = {}
  function resources.resolve(key)
    leased[#leased + 1] = key
    return { key = key }
  end
  function resources.release(_lease) end
  local player = assert(Player.new({
    scene = scene,
    audio = audio,
    resources = resources,
    tasks = tasks,
  }))
  local first =
    assert(player:start(pairPlayback(1, "solo-player", 0, "solo-enemy", 1), pairProgram("pair-selection-first")))
  runToCompletion(player, first)
  Assert.equal(player:status(first), "complete", "the matching pair case runs to its own completion")
  Assert.deepEqual(
    leased,
    { "battle/particle-emitter/candidate-1" },
    "only the selected pair resource is leased"
  )
  Assert.equal(#spawned, 1, "the selected pair spawns exactly once across parked ticks")
  Assert.equal(
    spawned[1].resource,
    "battle/particle-emitter/candidate-1",
    "the spawned emitter carries the selected resource"
  )
  local second =
    assert(player:start(pairPlayback(2, "solo-enemy", 1, "solo-player", 0), pairProgram("pair-selection-second")))
  runToCompletion(player, second)
  Assert.equal(player:status(second), "complete", "the reverse pair runs to its own completion")
  Assert.deepEqual(leased, {
    "battle/particle-emitter/candidate-1",
    "battle/particle-emitter/candidate-4",
  }, "each pair leases only its own resource")
  Assert.equal(#spawned, 2, "the reverse pair spawns without re-leasing the first pair")
  Assert.equal(
    spawned[2].resource,
    "battle/particle-emitter/candidate-4",
    "the reverse emitter carries its own selected resource"
  )
end

function T.attacker_dash_stages_timed_afterimages_and_settles()
  local Factory = require("libs.hgss.src.presentation.BattleEffectTasks")
  local scene = sceneWithPair()
  local journal = { acquired = {}, released = {} }
  local resources = {}
  function resources.resolve(key)
    journal.acquired[#journal.acquired + 1] = key
    return { key = key, lease = key }
  end
  function resources.release(lease)
    journal.released[#journal.released + 1] = lease
  end
  local attacker = { combatant = 1, activation = 1 }
  local context = {
    launchId = "dash-probe",
    visualSeed = 4242,
    random = function(bound)
      assert(type(bound) == "number" and bound >= 1, "visual draws name a positive bound")
      return 0
    end,
    topology = {
      attacker = { combatant = 1, activation = 1, slot = "solo-player", sideType = 0 },
      targets = { { combatant = 3, activation = 3, slot = "solo-enemy", sideType = 1 } },
    },
  }
  local task = assert(Factory.create("pokemon-picture-attacker-dash-afterimages", {
    battlerTarget = "attacker",
    activation = attacker,
    parameters = { durationTicks = 20 },
  }, context, { scene = scene, audio = {}, resources = resources }))
  task:stepSourceTick({ tick = 1 })
  task:stepSourceTick({ tick = 1 })
  local early = assert(scene:pictureState(attacker), "the dash stages source coordinates instead of idling on a timer")
  for _ = 1, 8 do
    task:stepSourceTick({ tick = 1 })
  end
  Assert.isTrue(task:status() == "running", "the dash outlives its midpoint")
  local mid = assert(scene:pictureState(attacker), "the mid-dash run keeps its coordinates")
  Assert.isTrue(mid.pictureXOffset2 ~= early.pictureXOffset2, "the out leg advances the dash coordinates")
  for _ = 1, 6 do
    task:stepSourceTick({ tick = 1 })
  end
  local returning = assert(scene:pictureState(attacker), "the back leg keeps its coordinates")
  Assert.isTrue(returning.pictureXOffset2 ~= mid.pictureXOffset2, "the back leg retreats from the out-leg reach")
  for _ = 1, 4 do
    task:stepSourceTick({ tick = 1 })
  end
  Assert.equal(task:status(), "complete", "the dash completes at its source duration")
  Assert.equal(#scene:effectViews(), 0, "the dash publishes no orphan records")
  Assert.isNil(scene:pictureState(attacker), "completion restores the attacker picture")
  task:dispose()
  Assert.equal(#journal.released, #journal.acquired, "the dash run leaks no lease")
end

return { tests = T }
