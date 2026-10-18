-- Picture and presentation state stays keyed by activation identity, so a
-- withdrawn combatant's late work can never reach the replacement sharing
-- its slot: the scene keeps one entry per combatant and activation pair,
-- untouched replacements expose no patched view, and restoring the old
-- activation leaves the new one alone. The delayed-task isolation run
-- drives the battle-private program player once it exists.
-- Native geometry: libs/hgss presentation BattleScene activation-scoped
-- picture state; slot rows resolve per side, never per occupant.
-- Headless: the real scene owns the entries; no battle or field objects
-- are touched.

local Assert = require("tests.support.Assert")
local BattlePresentationFlow = require("game.hgss.src.battle.BattlePresentationFlow")
local BattlePresentationModel = require("game.hgss.src.battle.BattlePresentationModel")
local BattleScene = require("libs.hgss.src.presentation.BattleScene")
local ManifestFixture = require("tests.support.BattlePresentationManifestFixture")

local T = {}

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
    launchId = "slot-identity-probe",
    packetId = 1,
  })
  Assert.equal(packet.launchId, "slot-identity-probe", "the playback input carries its launch identity")
  return packet
end

local function playerModule()
  local ok, Player = pcall(require, "libs.hgss.src.presentation.BattleAnimationPlayer")
  Assert.isTrue(ok, "the battle-private animation player resolves through the presentation boundary")
  Assert.equal(type(Player.new), "function", "the player exposes its construction entry point")
  return Player
end

function T.replacement_activation_keeps_its_own_picture_state()
  local scene = sceneWithPair()
  local old = { combatant = 1, activation = 1 }
  local view = scene:applyPictureState(old, { vanished = true })
  Assert.equal(view.vanished, true, "the old activation records its patched picture state")
  scene:observe({
    { combatant = 1, activation = 9, visible = true },
    { combatant = 3, activation = 3, visible = true },
  })
  local replacement = { combatant = 1, activation = 9 }
  Assert.isNil(scene:pictureState(replacement), "the untouched replacement exposes no patched view")
  local oldPhase = scene:entryStatus(old)
  local newPhase = scene:entryStatus(replacement)
  Assert.equal(oldPhase, "complete", "the withdrawn activation keeps its own entry")
  Assert.equal(newPhase, "complete", "the replacement installs a separate entry")
  local restored = scene:restorePictureState(old)
  Assert.notNil(restored, "the old activation restores its own snapshot")
  Assert.isNil(restored.vanished, "restoration returns the pre-patch appearance")
  Assert.isNil(scene:pictureState(replacement), "restoring the old activation leaves the new one alone")
  Assert.equal(scene:pictureState(old).vanished, nil, "the old activation no longer shows its patch")
end

function T.late_work_for_a_withdrawn_activation_never_touches_its_replacement()
  local Player = playerModule()
  local scene = sceneWithPair()
  local old = { combatant = 1, activation = 1 }
  scene:applyPictureState(old, { zOffset = 3 })
  scene:observe({
    { combatant = 1, activation = 9, visible = true },
    { combatant = 3, activation = 3, visible = true },
  })
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
  local delayed = {}
  local tasks = {}
  function tasks.create(kind, _args, context, _services)
    local task = { _state = "running" }
    function task.stepSourceTick(_tick)
      delayed[#delayed + 1] = { kind = kind, context = context }
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
    return { key = key, lease = key }
  end
  function resources.release(_lease) end
  local player = assert(Player.new({
    scene = scene,
    audio = audio,
    resources = resources,
    tasks = tasks,
  }))
  local packet = playbackPacket()
  local staleHandle = assert(player:start(packet, {
    entry = "main",
    instructions = { { op = "reset-blend-alpha" } },
    subprograms = {},
    taskKinds = {},
  }))
  player:cancel(staleHandle, "withdrawn")
  Assert.equal(player:status(staleHandle), "cancelled", "withdrawing the old occurrence cancels it")
  scene:observe({
    { combatant = 1, activation = 9, visible = true },
    { combatant = 3, activation = 3, visible = true },
  })
  for _ = 1, 5 do
    player:stepSourceTick({ tick = 1 })
  end
  Assert.isNil(scene:pictureState({ combatant = 1, activation = 9 }), "no late write lands on the replacement")
  Assert.equal(#audio.played, 0, "no late voice starts for the withdrawn occurrence")
end

local STABLE_POSITIONS = {
  "solo-player",
  "solo-enemy",
  "player-side-slot-1",
  "enemy-side-slot-1",
  "player-side-slot-2",
  "enemy-side-slot-2",
}

local function strikeEvent(sequence, actors, targets, extra)
  local event = {
    sequence = sequence,
    kind = "strike",
    cause = {},
    audience = "public",
    payload = {},
    actors = actors,
    targets = targets,
  }
  if extra ~= nil then
    for field, value in pairs(extra) do
      event[field] = value
    end
  end
  return event
end

local function packetFor(before, after, rawEvents, launchId, packetId)
  return BattlePresentationModel.packet(before, { events = rawEvents }, after, {
    launchId = launchId,
    packetId = packetId,
  })
end

local function topologyPlayback(packetId, attacker, targets)
  return {
    launchId = "pair-assert-probe",
    packetId = packetId,
    event = { sequence = 11, actionId = 3, hitIndex = 1, effectKey = "assert-pair-probe" },
    visualSeed = 4242,
    topology = { attacker = attacker, targets = targets },
  }
end

local function pairCases(invalidPair)
  local cases = {}
  for _, attacker in ipairs(STABLE_POSITIONS) do
    for _, target in ipairs(STABLE_POSITIONS) do
      cases[attacker .. "/" .. target] = "battle/particle-emitter/standby"
    end
  end
  cases[invalidPair] = "source-assert"
  cases["solo-enemy/solo-player"] = "battle/particle-emitter/candidate-4"
  return cases
end

-- Event-time facts resolve to frozen native slots: one battler per side
-- takes the solo rows, two per side take their sorted double rows, a
-- struck target that already left keeps its pre-event activation instead
-- of the replacement, and the admitted packet never follows later view
-- edits. The bound occurrence carries that same topology and event into
-- factory context, while a picture show without any topology fails
-- instead of guessing from sorted scene entries.
-- Native geometry: BattleScene.slotRow side types 0..5 over the staged
-- slot rows; activation-scoped entries keep withdrawn and replacement
-- identities apart.
-- Headless: synthetic before/after views and the staged manifest slot
-- geometry; the recorder doubles never touch live battle state.
function T.event_time_topology_binds_stable_slots_for_singles_doubles_and_replacements()
  Assert.isTrue(
    type(BattlePresentationFlow.animationPlayback) == "function",
    "the battle flow adapts one sanitized event into a frozen visual topology"
  )
  local geometry = ManifestFixture.manifest().battlefield.slots
  Assert.equal(#geometry, 6, "the staged geometry publishes all six native slot rows")

  local singleBefore = {
    own = { { combatant = 1, activation = 7, side = 1, position = 1 } },
    foes = { { combatant = 2, activation = 9, side = 2, position = 2 } },
  }
  local singleAfter = {
    own = { { combatant = 1, activation = 7, side = 1, position = 1 } },
    foes = { { combatant = 2, activation = 9, side = 2, position = 2 } },
  }
  local singlePacket = packetFor(singleBefore, singleAfter, {
    strikeEvent(4, { { combatant = 1, activation = 7, side = 1, position = 1 } }, {
      { combatant = 2, activation = 9, side = 2, position = 2 },
    }, {
      actionId = 2,
      hitIndex = 1,
      effectKey = "tackle-strike",
      visualSeed = 4242,
      suppression = { missed = true },
    }),
  }, "topology-probe", 1)
  local singlePlayback =
    BattlePresentationFlow.animationPlayback(singlePacket, singlePacket.events[1], geometry)
  Assert.equal(singlePlayback.launchId, "topology-probe", "the playback carries its launch identity")
  Assert.equal(singlePlayback.packetId, 1, "the playback carries its packet identity")
  Assert.equal(singlePlayback.event.sequence, 4, "the playback carries its event sequence")
  Assert.equal(singlePlayback.event.actionId, 2, "the playback carries its action identity")
  Assert.equal(singlePlayback.event.hitIndex, 1, "the playback carries its hit ordinal")
  Assert.equal(singlePlayback.event.effectKey, "tackle-strike", "the playback carries its effect key")
  Assert.equal(singlePlayback.visualSeed, 4242, "the playback carries its deterministic visual seed")
  Assert.deepEqual(
    singlePlayback.event.suppression,
    { missed = true },
    "the playback carries its suppression facts"
  )
  local singleAttacker = singlePlayback.topology.attacker
  Assert.equal(singleAttacker.combatant, 1, "the single attacker keeps its combatant")
  Assert.equal(singleAttacker.activation, 7, "the single attacker keeps its activation")
  Assert.equal(singleAttacker.slot, "solo-player", "the lone ally takes the solo player slot")
  Assert.equal(singleAttacker.sideType, 0, "the lone ally takes the single player side type")
  Assert.equal(#singlePlayback.topology.targets, 1, "the single strike addresses one target")
  local singleTarget = singlePlayback.topology.targets[1]
  Assert.equal(singleTarget.combatant, 2, "the single target keeps its combatant")
  Assert.equal(singleTarget.activation, 9, "the single target keeps its activation")
  Assert.equal(singleTarget.slot, "solo-enemy", "the lone foe takes the solo enemy slot")
  Assert.equal(singleTarget.sideType, 1, "the lone foe takes the single enemy side type")

  local doubleViews = {
    own = {
      { combatant = 1, activation = 7, side = 1, position = 1 },
      { combatant = 5, activation = 8, side = 1, position = 2 },
    },
    foes = {
      { combatant = 2, activation = 9, side = 2, position = 3 },
      { combatant = 4, activation = 10, side = 2, position = 4 },
    },
  }
  local doublePacket = packetFor(doubleViews, doubleViews, {
    strikeEvent(5, { { combatant = 1, activation = 7, side = 1, position = 1 } }, {
      { combatant = 2, activation = 9, side = 2, position = 3 },
      { combatant = 4, activation = 10, side = 2, position = 4 },
    }, { actionId = 3, hitIndex = 1, effectKey = "spread-strike", visualSeed = 5150 }),
  }, "topology-probe", 2)
  local doublePlayback =
    BattlePresentationFlow.animationPlayback(doublePacket, doublePacket.events[1], geometry)
  local spreadAttacker = doublePlayback.topology.attacker
  Assert.equal(spreadAttacker.slot, "player-side-slot-1", "the first sorted ally takes its double slot")
  Assert.equal(spreadAttacker.sideType, 2, "the first sorted ally takes the left double side type")
  Assert.equal(#doublePlayback.topology.targets, 2, "the spread strike keeps its event target order")
  Assert.equal(
    doublePlayback.topology.targets[1].slot,
    "enemy-side-slot-1",
    "the first spread target takes its double slot"
  )
  Assert.equal(doublePlayback.topology.targets[1].sideType, 3, "the first spread target takes its side type")
  Assert.equal(
    doublePlayback.topology.targets[2].slot,
    "enemy-side-slot-2",
    "the second spread target takes its double slot"
  )
  Assert.equal(doublePlayback.topology.targets[2].sideType, 5, "the second spread target takes its side type")
  Assert.equal(
    doublePlayback.topology.targets[2].activation,
    10,
    "the second spread target keeps its own activation"
  )

  local replacedPacket = packetFor({
    own = { { combatant = 1, activation = 7, side = 1, position = 1 } },
    foes = { { combatant = 2, activation = 9, side = 2, position = 2 } },
  }, {
    own = { { combatant = 1, activation = 7, side = 1, position = 1 } },
    foes = { { combatant = 2, activation = 12, side = 2, position = 2 } },
  }, {
    strikeEvent(6, { { combatant = 1, activation = 7, side = 1, position = 1 } }, {
      { combatant = 2, activation = 9, side = 2, position = 2 },
    }, { actionId = 4, hitIndex = 1, effectKey = "late-hit", visualSeed = 99 }),
  }, "topology-probe", 3)
  local replacedPlayback =
    BattlePresentationFlow.animationPlayback(replacedPacket, replacedPacket.events[1], geometry)
  Assert.equal(
    replacedPlayback.topology.targets[1].activation,
    9,
    "a hit against a departed target keeps its pre-event activation"
  )
  Assert.equal(
    replacedPlayback.topology.targets[1].slot,
    "solo-enemy",
    "the departed target keeps its event-time slot"
  )

  singlePacket.before.foes[1].activation = 999
  Assert.equal(
    singlePlayback.topology.targets[1].activation,
    9,
    "the admitted topology never follows later view edits"
  )
  local replayPacket = packetFor({
    own = { { combatant = 1, activation = 7, side = 1, position = 1 } },
    foes = { { combatant = 2, activation = 12, side = 2, position = 2 } },
  }, {
    own = { { combatant = 1, activation = 7, side = 1, position = 1 } },
    foes = { { combatant = 2, activation = 12, side = 2, position = 2 } },
  }, {
    strikeEvent(4, { { combatant = 1, activation = 7, side = 1, position = 1 } }, {
      { combatant = 2, activation = 12, side = 2, position = 2 },
    }, { actionId = 9, hitIndex = 2, effectKey = "late-hit", visualSeed = 100 }),
  }, "topology-probe", 4)
  local replayPlayback =
    BattlePresentationFlow.animationPlayback(replayPacket, replayPacket.events[1], geometry)
  Assert.equal(
    replayPlayback.topology.targets[1].activation,
    12,
    "a replayed sequence resolves against its own packet views"
  )
  Assert.equal(
    singlePlayback.topology.targets[1].activation,
    9,
    "the replay never mutates the earlier admitted occurrence"
  )

  local Player = playerModule()
  local scene = sceneWithPair()
  local captured = {}
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
  function tasks.create(kind, _args, context, _services)
    captured[#captured + 1] = { kind = kind, context = context }
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
    return { key = key, lease = key }
  end
  function resources.release(_lease) end
  local player = assert(Player.new({
    scene = scene,
    audio = audio,
    resources = resources,
    tasks = tasks,
  }))
  local bound = assert(player:start(singlePlayback, {
    entry = "main",
    instructions = {
      { op = "schedule-battle-task", taskKind = "battle-background-blend-transition", values = { 0 } },
    },
    subprograms = {},
    taskKinds = {},
  }))
  for _ = 1, 5 do
    player:stepSourceTick({ tick = 1 })
  end
  Assert.equal(player:status(bound), "complete", "the bound occurrence runs with its admitted topology")
  Assert.equal(#captured, 1, "the bound occurrence exposes its factory context once")
  Assert.equal(
    captured[1].context.topology.attacker.slot,
    "solo-player",
    "factory context carries the admitted attacker slot"
  )
  Assert.equal(
    captured[1].context.topology.attacker.activation,
    7,
    "factory context carries the admitted attacker activation"
  )
  Assert.equal(
    captured[1].context.topology.targets[1].slot,
    "solo-enemy",
    "factory context carries the admitted target slot"
  )
  Assert.equal(
    captured[1].context.event.sequence,
    4,
    "factory context carries the admitted event identity"
  )
  local replayBound = assert(player:start(replayPlayback, {
    entry = "main",
    instructions = {
      { op = "schedule-battle-task", taskKind = "battle-background-blend-transition", values = { 0 } },
    },
    subprograms = {},
    taskKinds = {},
  }))
  for _ = 1, 5 do
    player:stepSourceTick({ tick = 1 })
  end
  Assert.equal(player:status(replayBound), "complete", "the replayed occurrence runs beside the first")
  Assert.equal(
    captured[1].context.topology.targets[1].activation,
    9,
    "the replayed packet never mutates the bound occurrence topology"
  )
  Assert.equal(
    captured[2].context.topology.targets[1].activation,
    12,
    "the replayed occurrence binds its own event-time activation"
  )

  local bare = BattlePresentationModel.packet({}, { events = {} }, {}, {
    launchId = "bare-probe",
    packetId = 7,
  })
  local guessing = assert(player:start(bare, {
    entry = "main",
    instructions = { { op = "show-pokemon-picture", values = { 0, 0 } } },
    subprograms = {},
    taskKinds = {},
  }))
  for _ = 1, 5 do
    player:stepSourceTick({ tick = 1 })
  end
  Assert.equal(
    player:status(guessing),
    "failed",
    "a picture show without event topology fails instead of guessing from sorted entries"
  )
  local detail = player:failure(guessing)
  Assert.notNil(detail, "the topology-less picture show carries its failure detail")
  Assert.equal(detail.op, "show-pokemon-picture", "the failure names its picture operation")
end

-- An invalid native position pair stays invalid: the occurrence fails
-- naming its pair and effect, leases nothing, spawns nothing, and leaves
-- no scene effect behind, while the valid pairs around it stay
-- selectable through the same table.
-- Native mechanism: the attacker/target particle lookup tables carry
-- explicit invalid holes beside their selectable resources.
-- Headless: a synthetic pair table with one invalid hole and valid
-- neighbors; the recorder doubles count leases and spawns.
function T.invalid_position_pair_fails_naming_its_pair_without_leasing()
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
  local program = {
    key = "assert-pair-probe",
    entry = "main",
    instructions = {
      {
        op = "create-parameterized-battler-effect",
        taskKind = "battler-effect-continuation",
        actionProfile = "particle-emitter-target-battler-relative",
        emitterPosition = "solo-enemy",
        runtimeSelection = "battler-particle-position-pair",
        resourceCases = pairCases("solo-player/solo-enemy"),
      },
      { op = "wait-for-battler-effects" },
    },
    subprograms = {},
    taskKinds = {},
  }
  local playback = topologyPlayback(1, { combatant = 1, activation = 7, slot = "solo-player", sideType = 0 }, {
    { combatant = 2, activation = 9, slot = "solo-enemy", sideType = 1 },
  })
  local handle = assert(player:start(playback, program))
  for _ = 1, 30 do
    player:stepSourceTick({ tick = 1 })
    if player:status(handle) == "failed" then
      break
    end
  end
  Assert.equal(
    player:status(handle),
    "failed",
    "the native invalid pair fails instead of emitting a plausible particle"
  )
  local detail = player:failure(handle)
  Assert.notNil(detail, "the invalid pair carries its occurrence and instruction detail")
  Assert.equal(detail.programKey, "assert-pair-probe", "the failure names the effect it refused")
  local reason = detail.reason
  Assert.equal(type(reason), "string", "the invalid pair failure carries a readable reason")
  Assert.isTrue(
    (reason --[[@as string]]):find("solo-player/solo-enemy", 1, true) ~= nil,
    "the failure names the invalid pair instead of a generic topology error"
  )
  Assert.equal(#leased, 0, "the invalid pair leases no dependency")
  Assert.equal(#spawned, 0, "the invalid pair spawns no emitter")
  Assert.equal(#scene:effectViews(), 0, "the invalid pair leaves no scene effect behind")
end

-- A struck foe that already left the live views keeps its event-time
-- slot: the adapter prefers the pre-event record when the after view no
-- longer pictures the target, and neither the admitted playback nor the
-- factory context leaks reserve, party, or source-archive facts.
-- Headless: synthetic before/after views with a missing foe and a
-- switched ally activation; the recorder doubles count only leases.
function T.fainted_target_missing_from_after_view_keeps_event_slot_without_reserve_leak()
  local geometry = ManifestFixture.manifest().battlefield.slots
  Assert.equal(#geometry, 6, "the staged geometry publishes all six native slot rows")
  local before = {
    own = { { combatant = 1, activation = 7, side = 1, position = 1 } },
    foes = { { combatant = 2, activation = 9, side = 2, position = 2 } },
  }
  local after = {
    own = { { combatant = 1, activation = 20, side = 1, position = 1 } },
    foes = {},
  }
  local packet = packetFor(before, after, {
    strikeEvent(8, { { combatant = 1, activation = 7, side = 1, position = 1 } }, {
      { combatant = 2, activation = 9, side = 2, position = 2 },
    }, { actionId = 5, hitIndex = 1, effectKey = "faint-strike", visualSeed = 31337 }),
  }, "faint-probe", 9)
  local playback =
    BattlePresentationFlow.animationPlayback(packet, packet.events[1], geometry)
  Assert.equal(playback.topology.attacker.activation, 7, "the switched attacker keeps its striking activation")
  Assert.equal(playback.topology.attacker.slot, "solo-player", "the switched attacker keeps its event slot")
  Assert.equal(
    playback.topology.targets[1].activation,
    9,
    "the fainted target keeps its pre-event activation"
  )
  Assert.equal(
    playback.topology.targets[1].slot,
    "solo-enemy",
    "the missing target keeps its event-time slot"
  )
  for _, field in ipairs({ "party", "inventory", "reserves", "kernel", "narcId", "memberId" }) do
    Assert.isNil(playback[field], "the admitted playback leaks no " .. field)
    Assert.isNil(playback.event[field], "the admitted event leaks no " .. field)
  end
  local Player = playerModule()
  local scene = sceneWithPair()
  local captured = {}
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
  function tasks.create(kind, _args, context, _services)
    captured[#captured + 1] = { kind = kind, context = context }
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
    return { key = key, lease = key }
  end
  function resources.release(_lease) end
  local player = assert(Player.new({
    scene = scene,
    audio = audio,
    resources = resources,
    tasks = tasks,
  }))
  local bound = assert(player:start(playback, {
    entry = "main",
    instructions = {
      { op = "schedule-battle-task", taskKind = "battle-background-blend-transition", values = { 0 } },
    },
    subprograms = {},
    taskKinds = {},
  }))
  for _ = 1, 5 do
    player:stepSourceTick({ tick = 1 })
  end
  Assert.equal(player:status(bound), "complete", "the fainted-target occurrence runs with its frozen slot")
  Assert.equal(#captured, 1, "the fainted-target occurrence exposes its factory context once")
  local context = captured[1].context
  Assert.equal(
    context.topology.targets[1].activation,
    9,
    "factory context carries the event-time target activation"
  )
  for _, field in ipairs({ "before", "after", "party", "inventory", "reserves", "kernel", "combatants", "combatantOrder" }) do
    Assert.isNil(context[field], "factory context leaks no " .. field)
  end
end

-- Event-time sides select the side branches: a player-side user takes
-- the ordinary predicate target while a foe-side user takes the
-- special one, and a cross-side pair falls through the equality
-- alternate target while a same-side ally pair takes the equal
-- target. Native mechanism: ov07_0221D174 selector-to-side rule and
-- ov07_0221D270 attacker/target side-class comparison over the frozen
-- event topology; no live battle state is consulted.
-- Headless: synthetic singles/doubles views through animationPlayback
-- and the real player with recorder doubles.
function T.event_time_sides_select_the_side_branches()
  local geometry = ManifestFixture.manifest().battlefield.slots
  local views = {
    own = { { combatant = 1, activation = 7, side = 1, position = 1 } },
    foes = { { combatant = 2, activation = 9, side = 2, position = 2 } },
  }
  local outward = packetFor(views, views, {
    strikeEvent(12, { { combatant = 1, activation = 7, side = 1, position = 1 } }, {
      { combatant = 2, activation = 9, side = 2, position = 2 },
    }, { actionId = 11, hitIndex = 1, effectKey = "side-branch-strike", visualSeed = 77 }),
  }, "side-branch-probe", 12)
  local outwardPlayback = BattlePresentationFlow.animationPlayback(outward, outward.events[1], geometry)
  Assert.equal(
    outwardPlayback.topology.attacker.slot,
    "solo-player",
    "the outward strike keeps its player-side user"
  )
  local inward = packetFor(views, views, {
    strikeEvent(13, { { combatant = 2, activation = 9, side = 2, position = 2 } }, {
      { combatant = 1, activation = 7, side = 1, position = 1 },
    }, { actionId = 12, hitIndex = 1, effectKey = "side-branch-reply", visualSeed = 78 }),
  }, "side-branch-probe", 13)
  local inwardPlayback = BattlePresentationFlow.animationPlayback(inward, inward.events[1], geometry)
  Assert.equal(
    inwardPlayback.topology.attacker.slot,
    "solo-enemy",
    "the reply strike keeps its foe-side user"
  )
  local doubleViews = {
    own = {
      { combatant = 1, activation = 7, side = 1, position = 1 },
      { combatant = 5, activation = 8, side = 1, position = 2 },
    },
    foes = {
      { combatant = 2, activation = 9, side = 2, position = 3 },
      { combatant = 4, activation = 10, side = 2, position = 4 },
    },
  }
  local allyAid = packetFor(doubleViews, doubleViews, {
    strikeEvent(14, { { combatant = 1, activation = 7, side = 1, position = 1 } }, {
      { combatant = 5, activation = 8, side = 1, position = 2 },
    }, { actionId = 13, hitIndex = 1, effectKey = "side-branch-aid", visualSeed = 79 }),
  }, "side-branch-probe", 14)
  local allyPlayback = BattlePresentationFlow.animationPlayback(allyAid, allyAid.events[1], geometry)
  Assert.equal(
    allyPlayback.topology.targets[1].slot,
    "player-side-slot-2",
    "the ally aid keeps its same-side target"
  )

  local Player = playerModule()
  local scene = sceneWithPair()
  local played = {}
  local audio = { stopped = {}, done = {} }
  function audio.play(name)
    played[#played + 1] = name
  end
  function audio.stop(name)
    audio.stopped[#audio.stopped + 1] = name
  end
  function audio.isFinished(name)
    return audio.done[name] == true
  end
  local tasks = {}
  function tasks.create(_kind, _args, _context, _services)
    error("side branch probes stage no task")
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
    tasks = tasks,
  }))
  local predicateProgram = {
    entry = "main",
    instructions = {
      { op = "branch-on-side-predicate", values = { 0 }, branchTarget = 4, alternateTarget = 2 },
      { op = "play-sound", sound = "user-player-cue" },
      { op = "skip-words", target = 5 },
      { op = "play-sound", sound = "user-foe-cue" },
    },
    subprograms = {},
    taskKinds = {},
  }
  local outwardHandle = assert(player:start(outwardPlayback, predicateProgram))
  player:stepSourceTick({ tick = 1 })
  Assert.deepEqual(played, { "user-player-cue" }, "the player-side user takes the ordinary branch")
  Assert.equal(player:status(outwardHandle), "waiting", "the outward predicate settles on its branch")
  local inwardHandle = assert(player:start(inwardPlayback, predicateProgram))
  player:stepSourceTick({ tick = 2 })
  Assert.equal(played[#played], "user-foe-cue", "the foe-side user takes the special branch")
  Assert.equal(player:status(inwardHandle), "waiting", "the reply predicate settles on its branch")
  local equalityProgram = {
    entry = "main",
    instructions = {
      { op = "branch-on-side-equality", values = {}, branchTarget = 4, alternateTarget = 2 },
      { op = "play-sound", sound = "cross-side-cue" },
      { op = "skip-words", target = 5 },
      { op = "play-sound", sound = "equal-side-cue" },
    },
    subprograms = {},
    taskKinds = {},
  }
  local crossHandle = assert(player:start(outwardPlayback, equalityProgram))
  player:stepSourceTick({ tick = 3 })
  Assert.equal(played[#played], "cross-side-cue", "the cross-side pair falls through")
  Assert.equal(player:status(crossHandle), "waiting", "the cross-side equality settles on its branch")
  local allyHandle = assert(player:start(allyPlayback, equalityProgram))
  player:stepSourceTick({ tick = 4 })
  Assert.equal(played[#played], "equal-side-cue", "the same-side ally pair takes the equal branch")
  Assert.equal(player:status(allyHandle), "waiting", "the ally equality settles on its branch")
end

return { tests = T }
