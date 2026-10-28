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
local BattlePresentationModel = require("game.hgss.src.battle.BattlePresentationModel")
local BattleTimeline = require("game.hgss.tests.support.BattleTimelineFixture")
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
  Assert.isNil(restorationShape.instructions[2].taskKind, "the plain picture reveal schedules no animation task")

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
      if player:status(handle) == "complete" or player:status(handle) == "failed" then
        break
      end
    end
    if name == "status" then
      -- Opcode-34 visual spawns carry selectors, never timing operands:
      -- the frozen blend retires synchronously as a verified marker, so
      -- the run reaches its completion boundary instead of failing the
      -- spawn closed. Its opening voice still plays ahead of the marker.
      Assert.equal(player:status(handle), "complete", name .. " retires its marker spawn")
    else
      Assert.equal(player:status(handle), "complete", name .. " reaches its own completion boundary")
    end
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

-- Successful status and stage execution through the real kernel session:
-- Swords Dance raises the user's own stage and Thunder Wave afflicts its
-- target, both without any strike event, and each admits exactly one
-- native visual behind its own attack announcement. The recording native
-- collaborator stays pending until the test releases it, so the trace
-- proves the announcement is readable before the visual starts and the
-- dependent stage/status narration waits for the visual to complete.
local STATUS_KERNEL_FORMAT = "test:native-format"
local STATUS_KERNEL_SEED = 0x1BADB002
local STATUS_TICK = 1 / 30

local function statusKernelExecutor()
  local SessionFixture = require("libs.battle.tests.session_fixture")
  return SessionFixture.requirePresent(
    "libs.battle.src.gen4.HgssSessionExecutor",
    "the private native lifecycle owns HGSS ruleset sessions"
  )
end

local function statusKernelContent()
  local SessionFixture = require("libs.battle.tests.session_fixture")
  local ContentBuilder = require("libs.content.src.ContentBuilder")
  local BattleBehaviorBuilder = require("libs.battle.src.BattleBehaviorBuilder")
  local BattleContent = require("libs.battle.src.BattleContent")
  local NativeTypeChart = require("libs.battle.src.gen4.NativeTypeChart")
  local Executor = statusKernelExecutor()
  local builder = ContentBuilder.new()
  NativeTypeChart.install(builder, "status-visual-tests")
  local behaviors = BattleBehaviorBuilder.new()
  behaviors:registerRuleset(
    Executor.RULESET,
    { key = Executor.RULESET, chart = Executor.RULESET },
    "status-visual-tests"
  )
  behaviors:registerFormat(STATUS_KERNEL_FORMAT, { key = STATUS_KERNEL_FORMAT }, "status-visual-tests")
  return BattleContent.new(builder:freeze(), behaviors:freeze())
end

local function statusKernelMoveFacts()
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local catalog = CatalogFixture.makeCatalog()
  return {
    TACKLE = catalog:move("TACKLE"),
    SPLASH = { power = 0, accuracy = 100, category = "other", moveType = "normal", priority = 0 },
    SWORDS_DANCE = { power = 0, accuracy = 100, category = "other", moveType = "normal", priority = 0 },
    THUNDER_WAVE = { power = 0, accuracy = 100, category = "other", moveType = "electric", priority = 0 },
  }
end

local function statusKernelSpeciesFacts(seeds)
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local catalog = CatalogFixture.makeCatalog()
  local facts = {}
  for _, seed in ipairs(seeds) do
    local mon = seed.mon
    local bucket = facts[mon.species] or {}
    facts[mon.species] = bucket
    bucket[mon.form] = {
      baseStats = catalog:form(mon.species, mon.form).baseStats,
      growthCurve = catalog:growthCurve(catalog:species(mon.species).growthCurve),
      types = { "normal" },
      levelUpMoves = {},
      baseExpYield = 100,
      evYield = {},
    }
  end
  return facts
end

local function statusScriptedCombatant(id, seed, moves)
  local SessionFixture = require("libs.battle.tests.session_fixture")
  local entry = SessionFixture.combatant(id, seed)
  entry.mon.moves = moves
  return entry
end

local function statusDuelScenario(leads)
  local SessionFixture = require("libs.battle.tests.session_fixture")
  local Executor = statusKernelExecutor()
  return {
    ruleset = Executor.RULESET,
    format = STATUS_KERNEL_FORMAT,
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
    participants = {
      SessionFixture.participant(1, 1, "alpha", { leads[1] }),
      SessionFixture.participant(2, 2, "beta", { leads[2] }),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, leads[1].id),
      SessionFixture.position(2, 2, { 2 }, leads[2].id),
    },
    inventories = {},
    environment = { weather = "none" },
    random = { seed = STATUS_KERNEL_SEED },
    formatState = {},
    moveFacts = statusKernelMoveFacts(),
    speciesFacts = statusKernelSpeciesFacts(leads),
  }
end

local function statusPlayTurn(session, answer)
  local SessionFixture = require("libs.battle.tests.session_fixture")
  local frame = SessionFixture.driveUntilSettled(session)
  Assert.equal(frame.status, "waiting", "each scripted turn opens its decision batch")
  for _, request in ipairs(frame.request.requests) do
    local ok, err = session:submit(SessionFixture.replyFor(request, answer(request)))
    Assert.isTrue(ok, "scripted turn replies are accepted")
    Assert.isNil(err, "accepted turn replies carry no input error")
  end
  local events = {}
  for _ = 1, 64 do
    frame = session:advance()
    Assert.notNil(frame, "advance returns a battle frame")
    if frame.events ~= nil then
      for _, event in ipairs(frame.events) do
        events[#events + 1] = event
      end
    end
    if frame.status ~= "running" then
      return frame, events
    end
  end
  error("the scripted turn did not settle within its operation bound")
end

local function statusTimelineView()
  return {
    own = {
      {
        combatant = 1,
        side = 1,
        controller = "alpha",
        active = true,
        position = 1,
        activation = 1,
        hp = 100,
        maxHp = 100,
        species = "EEVEE",
        form = 0,
        name = "LEAD",
        level = 20,
        moves = {
          { move = "SWORDS_DANCE", name = "Swords Dance", pp = 30, maxPp = 30 },
          { move = "THUNDER_WAVE", name = "Thunder Wave", pp = 30, maxPp = 30 },
        },
      },
    },
    foes = {
      {
        combatant = 2,
        side = 2,
        controller = "beta",
        active = true,
        position = 2,
        activation = 2,
        hp = 100,
        maxHp = 100,
        species = "EEVEE",
        form = 0,
        name = "FOE",
        level = 20,
      },
    },
  }
end

---@param events table[] real kernel events from one scripted turn
---@param packetId integer per-launch delivery identity for the turn
---@param key string executed move identity whose visual is under test
---@param displayName string visible move name in the attack announcement
---@param dependentWord string dependent narration word that must wait for the visual
local function checkStatusTurn(events, packetId, key, displayName, dependentWord)
  local alphaUsed = nil
  for _, event in ipairs(events) do
    if event.kind == "move-used" and event.cause.key == key then
      alphaUsed = event
    end
  end
  Assert.notNil(alphaUsed, key .. " emits its own move-used event")
  Assert.equal(alphaUsed.effectKey, key, key .. " selects its own visual route")
  Assert.equal(alphaUsed.move.executed, key, key .. " visualizes the executed move")
  for _, event in ipairs(events) do
    if event.kind == "struck" then
      Assert.isTrue(event.actionId ~= alphaUsed.actionId, key .. " succeeds with zero strikes on its own action")
    end
  end
  local view = statusTimelineView()
  local started = {}
  local handles = {}
  local timeline = nil
  local effects = {
    start = function(cue)
      local handle = { phase = "pending" }
      started[#started + 1] = {
        effectKey = cue.effectKey,
        actionId = cue.actionId,
        message = timeline:message(),
        handle = handle,
      }
      handles[#handles + 1] = handle
      return handle
    end,
    status = function(handle)
      return handle.phase
    end,
    cancel = function(handle)
      handle.phase = "cancelled"
      return true
    end,
  }
  timeline = BattleTimeline.new({ effects = effects })
  timeline:reset(view)
  local packet = BattlePresentationModel.packet(
    view,
    { events = events },
    view,
    { launchId = "status-visual-probe", packetId = packetId }
  )
  Assert.isTrue(timeline:present(packet), key .. " packet is accepted")
  local initialHp = {}
  for _, entry in ipairs(timeline:battlers()) do
    initialHp[entry.combatant] = entry.hp
  end
  -- The cue player blocks at the first unfinished visual, so unrelated
  -- handles complete as soon as they start; only the visual under
  -- test stays pending, proving its own announcement and hold.
  local announcementTick = nil
  local startTick = nil
  local startMessage = nil
  local dependentBeforeVisual = false
  local firstCompletionTick = nil
  local tick = 0
  while tick < 3000 and startTick == nil do
    tick = tick + 1
    timeline:update(STATUS_TICK, function(_)
      return true
    end)
    local message = timeline:message()
    if announcementTick == nil and message:find(displayName, 1, true) ~= nil then
      announcementTick = tick
    end
    if message:find(dependentWord, 1, true) ~= nil then
      dependentBeforeVisual = true
    end
    for _, record in ipairs(started) do
      if record.effectKey == key and startTick == nil then
        startTick = tick
        startMessage = record.message
      elseif record.effectKey ~= key and record.released ~= true then
        record.released = true
        record.handle.phase = "complete"
        if firstCompletionTick == nil then
          firstCompletionTick = tick
        end
      end
    end
    if firstCompletionTick == nil then
      for _, entry in ipairs(timeline:battlers()) do
        Assert.equal(entry.hp, initialHp[entry.combatant], "no checkpoint health moves ahead of the unfinished visual")
      end
    end
  end
  Assert.notNil(announcementTick, key .. " attack announcement becomes readable")
  Assert.notNil(startTick, key .. " visual starts exactly once")
  Assert.isTrue(announcementTick < startTick, key .. " announcement reads before its visual starts")
  local startsForKey = 0
  for _, record in ipairs(started) do
    if record.effectKey == key then
      startsForKey = startsForKey + 1
    end
  end
  Assert.equal(startsForKey, 1, key .. " admits exactly one visual occurrence")
  Assert.isTrue(
    type(startMessage) == "string" and startMessage:find(displayName, 1, true) ~= nil,
    key .. " visual starts behind its own attack announcement"
  )
  Assert.isFalse(dependentBeforeVisual, key .. " dependent narration waits for the visual boundary")
  Assert.isTrue(timeline:busy(), "the unfinished visual still holds the cue player")
  for _, handle in ipairs(handles) do
    handle.phase = "complete"
  end
  local dependentAfterVisual = false
  tick = 0
  while tick < 3000 and not timeline:settled() do
    tick = tick + 1
    timeline:update(STATUS_TICK, function(_)
      return true
    end)
    if timeline:message():find(dependentWord, 1, true) ~= nil then
      dependentAfterVisual = true
    end
  end
  Assert.isTrue(timeline:settled(), key .. " turn drains fully once its visuals complete")
  Assert.isTrue(dependentAfterVisual, key .. " dependent narration follows the completed visual")
  local finalStarts = 0
  for _, record in ipairs(started) do
    if record.effectKey == key then
      finalStarts = finalStarts + 1
    end
  end
  Assert.equal(finalStarts, 1, key .. " never replays its visual across the drain")
end

function T.successful_status_and_stage_execution_admits_one_visual_after_announcement()
  local SessionFixture = require("libs.battle.tests.session_fixture")
  local contracts = SessionFixture.sessionContracts()
  local content = statusKernelContent()
  local alpha = statusScriptedCombatant(1, 11, {
    { move = "SWORDS_DANCE", pp = 30, ppUps = 0 },
    { move = "THUNDER_WAVE", pp = 30, ppUps = 0 },
  })
  local beta = statusScriptedCombatant(2, 31, { { move = "TACKLE", pp = 35, ppUps = 0 } })
  local session = contracts.Battle.newSession(statusDuelScenario({ alpha, beta }), content)
  local function answerFor(slot)
    return function(request)
      local choices = {}
      for _, actor in ipairs(request.actors) do
        if request.controller == "alpha" then
          choices[#choices + 1] = SessionFixture.attackChoice(actor, slot, SessionFixture.positionTarget(1))
        else
          choices[#choices + 1] = SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(1))
        end
      end
      return choices
    end
  end
  local _, danceEvents = statusPlayTurn(session, answerFor(0))
  local _, waveEvents = statusPlayTurn(session, answerFor(1))
  session:dispose()
  checkStatusTurn(danceEvents, 1, "SWORDS_DANCE", "Swords Dance", "rose")
  checkStatusTurn(waveEvents, 2, "THUNDER_WAVE", "Thunder Wave", "paralyzed")
end

-- A missed status attempt through the production packet path follows
-- HGSS subscript_0007_Miss: it announces the attack and the miss without
-- starting the move's program or afflicting anyone.
function T.missed_status_attempt_plays_no_program_and_afflicts_no_one()
  local view = statusTimelineView()
  local started = {}
  local handles = {}
  local timeline = nil
  local effects = {
    start = function(cue)
      local handle = { phase = "pending" }
      started[#started + 1] = { effectKey = cue.effectKey, message = timeline:message(), handle = handle }
      handles[#handles + 1] = handle
      return handle
    end,
    status = function(handle)
      return handle.phase
    end,
    cancel = function(handle)
      handle.phase = "cancelled"
      return true
    end,
  }
  timeline = BattleTimeline.new({ effects = effects })
  timeline:reset(view)
  local packet = BattlePresentationModel.packet(view, {
    events = {
      {
        sequence = 1,
        kind = "missed",
        cause = { key = "THUNDER_WAVE", kind = "move" },
        audience = "public",
        actionId = 21,
        effectKey = "THUNDER_WAVE",
        actors = { { combatant = 1 } },
        targets = { { combatant = 2 } },
        move = { selected = "THUNDER_WAVE", executed = "THUNDER_WAVE", phase = "direct" },
        payload = { target = 2 },
        suppression = { missed = true },
        visualSeed = 7,
      },
    },
  }, view, { launchId = "missed-status-probe", packetId = 1 })
  Assert.isTrue(timeline:present(packet), "the missed packet is accepted")
  local announcementTick = nil
  local startTick = nil
  local seen = {}
  local texts = {}
  local tick = 0
  while tick < 6000 and not timeline:settled() do
    tick = tick + 1
    timeline:update(STATUS_TICK, function(_)
      return true
    end)
    local id = timeline:messageId()
    if id ~= 0 and seen[id] == nil and timeline:ack() then
      seen[id] = true
      texts[#texts + 1] = timeline:message()
    end
    if announcementTick == nil and timeline:message() ~= "" then
      announcementTick = tick
    end
    if #started > 0 then
      if startTick == nil then
        startTick = tick
      end
      for _, handle in ipairs(handles) do
        handle.phase = "complete"
      end
    end
  end
  Assert.isNil(startTick, "the miss starts no move program")
  Assert.notNil(announcementTick, "the miss narrates its outcome")
  Assert.equal(#started, 0, "the miss plays no program")
  local missed = false
  local afflicted = false
  for _, text in ipairs(texts) do
    if tostring(text):find("missed", 1, true) ~= nil then
      missed = true
    end
    if tostring(text):find("paralyzed", 1, true) ~= nil then
      afflicted = true
    end
  end
  Assert.isTrue(missed, "the miss narration reaches the player")
  Assert.isFalse(afflicted, "the miss afflicts no one")
  Assert.isTrue(timeline:settled(), "the miss drains fully")
end

return { tests = T }
