-- Battle Scene preference through the production presentation path: the
-- saved scene choice is snapshotted at launch and gates only the optional
-- move-animation programs. Scene Off omits the native program selected for
-- the executed move (never a synthetic wait), while narration, health,
-- status, appearance, capture, faint, arrival, and the optional
-- stay-or-switch offer keep their exact behavior. Transform always plays.

local Assert = require("tests.support.Assert")
local BattleAnimationCompiler = require("romdump.src.digest.battle.BattleAnimationCompiler")
local BattlePresentationModel = require("game.hgss.src.battle.BattlePresentationModel")
local BattleScreenFixture = require("game.hgss.tests.support.BattleScreenFixture")
local BattleTimelineFixture = require("game.hgss.tests.support.BattleTimelineFixture")
local EffectStagingFixture = require("tests.support.EffectStagingFixture")
local FieldBattleCoordinator = require("game.hgss.src.field.FieldBattleCoordinator")
local ManifestFixture = require("tests.support.BattlePresentationManifestFixture")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {}
local TICK = 1 / 30

---@param value unknown value under test preparation
---@return unknown a detached copy sharing no table with the source
local function deepCopy(value)
  if type(value) ~= "table" then
    return value
  end
  local copy = {}
  for key, item in pairs(value) do
    copy[deepCopy(key)] = deepCopy(item)
  end
  return copy
end

---@return table detached dual-surface display facts for the scene harness
local function dualMeasurement()
  return {
    width = 256,
    height = 384,
    topology = ScreenTopology.dualDisplay(
      { id = "main", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
      { id = "lower", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" }
    ),
    pixelRatio = 1,
    signature = "battle-scene-test:dual",
  }
end

---@return table detached dynamic view with a live lead and a wild foe
local function sceneView(foeHp)
  return {
    own = {
      {
        combatant = 1,
        side = 1,
        controller = "player",
        active = true,
        position = 1,
        activation = 1,
        hp = 100,
        maxHp = 100,
        species = "EEVEE",
        form = 0,
        name = "LEAD",
        level = 20,
        moves = { { move = "TACKLE", name = "Tackle", pp = 35, maxPp = 35 } },
      },
    },
    foes = {
      {
        combatant = 2,
        side = 2,
        controller = "wild",
        active = true,
        position = 2,
        activation = 2,
        hp = foeHp,
        maxHp = 100,
        species = "PICHU",
        form = 0,
        name = "FOE",
        level = 20,
      },
    },
  }
end

---@param seq integer event sequence under test driving
---@param action integer action identity under test driving
---@param executed string executed move identity under test driving
---@param causeKey string? selected command identity, defaulting to the executed move
---@param target integer damaged combatant under test driving
---@param damage integer dealt damage under test driving
---@param foeHp integer foe health after the checkpoint under test driving
---@param hit integer? multi-hit ordinal, defaulting to the first hit
---@return table one struck event carrying its accepted native playback identity
local function struckEvent(seq, action, executed, causeKey, target, damage, foeHp, hit)
  return {
    sequence = seq,
    kind = "struck",
    cause = { key = causeKey or executed },
    audience = "public",
    actors = { { combatant = 1 } },
    targets = { { combatant = target } },
    move = { executed = executed },
    actionId = action,
    hitIndex = hit or 1,
    effectKey = executed,
    payload = { target = target, damage = damage },
    after = { hp = { [1] = 100, [target] = foeHp } },
  }
end

---@param value integer unsigned word under staging
---@return string four little-endian bytes staging one command word
local function probeU32(value)
  return string.char(
    value % 256,
    math.floor(value / 256) % 256,
    math.floor(value / 65536) % 256,
    math.floor(value / 16777216) % 256
  )
end

---@param staging table staged-effect double behind the launch
---@param key string flat semantic effect key under staging
local function stageProgram(staging, key)
  local parts = {}
  for _, word in ipairs({ 29, 50, 4 }) do
    parts[#parts + 1] = probeU32(word)
  end
  local program = assert(BattleAnimationCompiler.compile({ key = key, stream = table.concat(parts) }))
  local record = EffectStagingFixture.effectRecord(key, {})
  record.program = {
    entry = program.entry,
    instructions = program.instructions,
    subprograms = program.subprograms,
    taskKinds = program.taskKinds,
  }
  staging:stageEffect(key, record, {})
end

---@param staging table staged-effect double behind the launch
---@return table preparation services double over the staged store
local function screenAssets(staging)
  local assets = {}
  function assets.prepare(demand)
    return staging.services.prepare(demand)
  end
  function assets.drawable(imageKey)
    local staged = staging.services.drawable(imageKey)
    if staged ~= nil then
      return staged
    end
    return { handle = imageKey, width = 256, height = 192 }
  end
  function assets.release(imageKey)
    staging.services.release(imageKey)
  end
  assets.requestEffect = staging.services.requestEffect
  assets.loadEffect = staging.services.loadEffect
  assets.resolveEffectResource = staging.services.resolveEffectResource
  assets.releaseEffectResource = staging.services.releaseEffectResource
  return assets
end

---@param opts table rig options under test preparation
---@return table live screen rig over the real timeline and animation player
local function openScreenRig(opts)
  local launchId = opts.launchId or "launch-battle-scene"
  local staging = EffectStagingFixture.new({ launchId = launchId })
  for _, key in ipairs(opts.stage or {}) do
    stageProgram(staging, key)
  end
  local rig = { staging = staging, launchId = launchId, measurement = dualMeasurement() }
  local audio = {}
  function audio.play(_name)
    return true
  end
  function audio.stop(_name) end
  function audio.isFinished(_name)
    return true
  end
  local screenOpts = {
    launchId = launchId,
    manifest = deepCopy(ManifestFixture.manifest()),
    model = BattlePresentationModel,
    submit = function(_reply)
      return true
    end,
    measureDisplay = function()
      return rig.measurement
    end,
    assets = screenAssets(staging),
    text = {
      measure = function(text)
        return { width = 8 * #tostring(text), height = 16 }
      end,
      drawText = function(_text, _x, _y) end,
    },
    windows = {
      drawWindow = function(_box, _frame, _background) end,
    },
    audio = audio,
    battleScene = opts.battleScene,
  }
  if opts.monCatalog ~= nil then
    screenOpts.monCatalog = opts.monCatalog
  end
  local screen = BattleScreenFixture.new(screenOpts)
  rig.screen = screen
  for _ = 1, 4 do
    screen:updateFixed(TICK)
  end
  Assert.isTrue(screen:presentationPort().enter({ kind = "wild" }), "the scene screen enters its wild opening")
  screen._timeline:reset(sceneView(100))
  return rig
end

---@param screen table live battle screen under test driving
---@param events table ordered sanitized-shaped events under test driving
---@param packetId integer per-launch delivery identity under test driving
local function presentEvents(screen, events, packetId)
  local before = sceneView(100)
  local after = sceneView(100)
  for _, event in ipairs(events) do
    local hp = event.after ~= nil and event.after.hp or nil
    if type(hp) == "table" then
      for combatant, value in pairs(hp) do
        for _, group in ipairs({ after.own, after.foes }) do
          for _, record in ipairs(group) do
            if record.combatant == combatant then
              record.hp = value
            end
          end
        end
      end
    end
  end
  screen:presentationPort().present({
    launchId = screen._launchId,
    packetId = packetId,
    events = events,
    before = before,
    after = after,
  })
end

---@param rig table live screen rig under test driving
---@param budget integer maximum source ticks before giving up
---@return integer ticks consumed, boolean whether the timeline settled
local function driveSettled(rig, budget)
  local started = false
  local ticks = 0
  local screen = rig.screen
  while ticks < budget do
    ticks = ticks + 1
    screen:updateFixed(TICK)
    screen._timeline:ack()
    for _, track in pairs(screen._nativeHandles) do
      if track.effectKey == rig.watchEffect and track.handle ~= nil then
        started = true
      end
    end
    if screen._timeline:settled() then
      break
    end
  end
  return ticks, started
end

---@param battlers table displayed battler facts under inspection
---@param combatant integer
---@return table the displayed facts for one combatant
local function battler(battlers, combatant)
  for _, entry in ipairs(battlers) do
    if entry.combatant == combatant then
      return entry
    end
  end
  error("no displayed battler " .. tostring(combatant), 0)
end

---@param requests table<string> recorded effect demands under inspection
---@param key string effect key under inspection
---@return integer demands recorded for the key
local function demandCount(requests, key)
  local total = 0
  for _, requested in ipairs(requests) do
    if requested == key then
      total = total + 1
    end
  end
  return total
end

-- Scene Off omits the optional move program without a synthetic wait,
-- while Scene On runs it: both launches settle with identical narration,
-- health, and final party facts, but only the On launch demands and
-- starts its selected program. The Off launch stages no optional program
-- at all, so any demand would also fail instead of draining.
function T.scene_off_omits_the_optional_move_program()
  local offRig = openScreenRig({ launchId = "launch-scene-off", battleScene = false })
  offRig.watchEffect = "TACKLE"
  presentEvents(offRig.screen, { struckEvent(1, 41, "TACKLE", nil, 2, 14, 86) }, 1)
  local offTicks, offStarted = driveSettled(offRig, 3000)
  Assert.isTrue(offRig.screen._timeline:settled(), "the omitted launch still drains")
  Assert.equal(offRig.screen:status().mode == "failed", false, "the omitted launch never fails")
  Assert.equal(battler(offRig.screen._timeline:battlers(), 2).hp, 86, "the checkpoint applies without the program")
  Assert.isTrue(
    tostring(offRig.screen._timeline:message()):find("Tackle", 1, true) ~= nil,
    "the attack narration still reads without the program"
  )
  Assert.equal(demandCount(offRig.staging.requests, "TACKLE"), 0, "the omitted program is never demanded")
  Assert.isFalse(offStarted, "the omitted program never starts a native occurrence")

  local onRig = openScreenRig({ launchId = "launch-scene-on", battleScene = true, stage = { "TACKLE" } })
  onRig.watchEffect = "TACKLE"
  presentEvents(onRig.screen, { struckEvent(1, 41, "TACKLE", nil, 2, 14, 86) }, 1)
  local onTicks, onStarted = driveSettled(onRig, 3000)
  Assert.isTrue(onRig.screen._timeline:settled(), "the admitted launch drains after real completion")
  Assert.equal(demandCount(onRig.staging.requests, "TACKLE"), 1, "the admitted program is demanded exactly once")
  Assert.isTrue(onStarted, "the admitted program starts its native occurrence")
  Assert.equal(battler(onRig.screen._timeline:battlers(), 2).hp, 86, "the admitted checkpoint matches")
  Assert.isTrue(
    onTicks > offTicks,
    "the omitted launch settles without the program wait (on=" .. onTicks .. ", off=" .. offTicks .. ")"
  )
  offRig.screen:dispose()
  onRig.screen:dispose()
  offRig.staging:dispose()
  onRig.staging:dispose()
end

-- Suppression keys on the executed move, not the selected command: a
-- move performed through another move's call still omits its program
-- under Scene Off while its checkpoint applies.
function T.scene_off_suppresses_by_executed_move_not_selected_command()
  local rig = openScreenRig({ launchId = "launch-scene-indirect", battleScene = false })
  rig.watchEffect = "TACKLE"
  presentEvents(rig.screen, { struckEvent(1, 42, "TACKLE", "METRONOME", 2, 14, 86) }, 1)
  driveSettled(rig, 3000)
  Assert.isTrue(rig.screen._timeline:settled(), "the indirect launch still drains")
  Assert.equal(rig.screen:status().mode == "failed", false, "the indirect launch never fails")
  Assert.equal(battler(rig.screen._timeline:battlers(), 2).hp, 86, "the indirect checkpoint applies")
  Assert.equal(demandCount(rig.staging.requests, "TACKLE"), 0, "the indirect program is never demanded")
  Assert.equal(demandCount(rig.staging.requests, "METRONOME"), 0, "no selected-command program is demanded either")
  rig.screen:dispose()
  rig.staging:dispose()
end

-- Multi-hit strikes share one action occurrence: Scene Off narrates the
-- attack once, applies every health checkpoint in order, and demands no
-- program for any hit.
function T.scene_off_keeps_multi_hit_narration_singular_and_health()
  local rig = openScreenRig({ launchId = "launch-scene-multihit", battleScene = false })
  rig.watchEffect = "TACKLE"
  presentEvents(rig.screen, {
    struckEvent(1, 43, "TACKLE", nil, 2, 10, 90, 1),
    struckEvent(2, 43, "TACKLE", nil, 2, 10, 80, 2),
  }, 1)
  driveSettled(rig, 3000)
  Assert.isTrue(rig.screen._timeline:settled(), "the multi-hit launch still drains")
  Assert.equal(battler(rig.screen._timeline:battlers(), 2).hp, 80, "every hit checkpoint applies in order")
  Assert.equal(demandCount(rig.staging.requests, "TACKLE"), 0, "no hit demands the omitted program")
  local announced = 0
  for _ in pairs(rig.screen._timeline._announced) do
    announced = announced + 1
  end
  Assert.equal(announced, 1, "the shared action narrates its attack once")
  rig.screen:dispose()
  rig.staging:dispose()
end

-- Transform is the explicit exception: even under Scene Off its program
-- starts and the displayed appearance tracks the copied battler.
function T.scene_off_transform_still_plays_and_updates_appearance()
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local rig = openScreenRig({
    launchId = "launch-scene-transform",
    battleScene = false,
    stage = { "TRANSFORM" },
    monCatalog = CatalogFixture.makeCatalog(),
  })
  rig.watchEffect = "TRANSFORM"
  presentEvents(rig.screen, {
    {
      sequence = 1,
      kind = "transformed",
      cause = { key = "TRANSFORM" },
      audience = "public",
      actors = { { combatant = 2 } },
      targets = { { combatant = 2 } },
      move = { executed = "TRANSFORM" },
      actionId = 44,
      effectKey = "TRANSFORM",
      payload = { target = 2, copiedFrom = 1 },
      after = { hp = { [1] = 100, [2] = 100 } },
    },
  }, 1)
  local _, started = driveSettled(rig, 3000)
  Assert.isTrue(rig.screen._timeline:settled(), "the transform drains fully")
  Assert.equal(demandCount(rig.staging.requests, "TRANSFORM"), 1, "the transform program is still demanded")
  Assert.isTrue(started, "the transform starts its native occurrence")
  Assert.equal(
    battler(rig.screen._timeline:battlers(), 2).species,
    "EEVEE",
    "the transformed battler displays the copied appearance"
  )
  rig.screen:dispose()
  rig.staging:dispose()
end

-- Required visual facts survive suppression: fainting hides the battler
-- and a capture throw still draws its target into the ball, all under
-- Scene Off with no native move program involved.
function T.scene_off_preserves_faint_and_capture_intake()
  local timeline = BattleTimelineFixture.new({
    battleScene = false,
    itemName = function(item)
      return item
    end,
  })
  timeline:reset(sceneView(100))
  Assert.isTrue(timeline:present({
    launchId = "scene-required-probe",
    packetId = 1,
    events = {
      {
        sequence = 1,
        kind = "fainted",
        cause = { key = "TACKLE" },
        audience = "public",
        actors = { { combatant = 1 } },
        targets = { { combatant = 2 } },
        payload = { target = 2 },
      },
      {
        sequence = 2,
        kind = "throw",
        cause = { key = "POKE_BALL" },
        audience = "public",
        actors = { { combatant = 1 } },
        targets = { { combatant = 2 } },
        payload = { ball = "POKE_BALL" },
      },
    },
    before = sceneView(100),
    after = sceneView(0),
  }), "the required packet is accepted under Scene Off")
  for _ = 1, 3000 do
    timeline:update(TICK, function(_)
      return true
    end)
    if timeline:settled() then
      break
    end
  end
  Assert.isTrue(timeline:settled(), "required cues drain under Scene Off")
  Assert.equal(battler(timeline:battlers(), 2).visible, false, "fainting still hides the battler")
end

-- A launch without a scene snapshot defaults to On: the optional move
-- program still admits, matching the long-standing default for records
-- predating the scene field.
function T.scene_defaults_to_on_without_a_snapshot()
  local started = {}
  local effects = {
    start = function(cue)
      started[#started + 1] = cue.effectKey
      return "default-scene-handle"
    end,
    status = function(_handle)
      return "complete"
    end,
    cancel = function(_handle, _reason)
      return true
    end,
    retire = function(_handle)
      return true
    end,
  }
  local timeline = BattleTimelineFixture.new({ effects = effects })
  timeline:reset(sceneView(100))
  Assert.isTrue(timeline:present({
    launchId = "scene-default-probe",
    packetId = 1,
    events = { struckEvent(1, 45, "TACKLE", nil, 2, 14, 86) },
    before = sceneView(100),
    after = sceneView(86),
  }), "the effect-keyed strike is accepted")
  for _ = 1, 3000 do
    timeline:update(TICK, function(_)
      return true
    end)
    if timeline:settled() then
      break
    end
  end
  Assert.isTrue(timeline:settled(), "the default launch drains")
  Assert.equal(#started, 1, "the default launch still admits its optional program")
  Assert.equal(started[1], "TACKLE", "the admission carries the accepted effect key")
  Assert.equal(battler(timeline:battlers(), 2).hp, 86, "the checkpoint applies")
end

-- The launch descriptor snapshots the saved scene choice beside the
-- narration pace: one frozen boolean rides the launch, never a live
-- global read during playback.
function T.launch_descriptor_snapshots_the_scene_choice_beside_text_speed()
  for _, scene in ipairs({ true, false }) do
    local admitted = nil
    local runtime = {
      session = {
        currentMap = { mapId = 33, fieldData = { battleBackground = "general" } },
        setBattleActive = function() end,
        setForegroundHold = function() end,
      },
      player = { fieldX = 5, fieldZ = 6, surfaceId = 0 },
      playerData = { profile = { gender = 0 }, options = { textSpeed = "fastest", battleScene = scene } },
      arrivalBehavior = function()
        return nil
      end,
      localClock = {
        nowLocal = function()
          return { hour = 12 }
        end,
      },
      audio = {},
      monService = {
        partyMon = function(_, _slot)
          return { species = "CHIKORITA", form = 0 }
        end,
      },
      refreshPartyWarmup = function() end,
    }
    local coordinator = FieldBattleCoordinator.new(runtime)
    coordinator:bindBattlePresentation(function(descriptor)
      admitted = descriptor
      return {}
    end)
    local foe = { species = "PIDGEY", form = 0 }
    local launchId = coordinator:launchPresentedBattle("wild#scene", {
      id = "wild#scene",
      kind = "wild",
      payload = { species = "PIDGEY", mon = foe },
    }, nil)
    Assert.equal(launchId, "wild#scene", "admission keeps its issued launch identity")
    Assert.notNil(admitted, "admission builds its presentation port")
    Assert.equal(admitted.battleScene, scene, "the descriptor snapshots the saved scene choice")
    Assert.equal(admitted.textSpeed, "fastest", "the descriptor keeps snapshotting the narration pace")
  end
end

return { tests = T }
