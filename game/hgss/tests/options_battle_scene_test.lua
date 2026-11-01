-- Battle Scene preference through the production presentation path: the
-- saved scene choice is snapshotted at launch and gates only the optional
-- move-animation programs. Scene Off omits the native program selected for
-- the executed move (never a synthetic wait), while narration, health,
-- status, appearance, capture, faint, arrival, and the optional
-- stay-or-switch offer keep their exact behavior. Transform always plays.

local Assert = require("tests.support.Assert")
local BattleAnimationCompiler = require("romdump.src.digest.battle.BattleAnimationCompiler")
local BattlePresentationModel = require("game.hgss.src.battle.BattlePresentationModel")
local SourceTick = require("libs.hgss.src.field.SourceTick")
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

-- A launch without a scene snapshot keeps the historical behavior: the
-- optional move program still admits, matching every previous caller.
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

-- The trainer knockout flow below reuses the production kernel, scenario,
-- and screen composition: Scene Off must leave the optional stay-or-switch
-- decision, its pending barrier, and the held arrival untouched.

---@param specs table lead/reserve descriptions under test preparation
---@return table live party owner holding the described members in order
local function makePartyOwner(specs)
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
  local Lcrng = require("libs.mons.src.gen4.Lcrng")
  local MonsSave = require("libs.mons.src.MonsSave")
  local Party = require("libs.mons.src.Party")
  local catalog = CatalogFixture.makeCatalog()
  local owner = HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0x22222222):capture()),
    profile = CatalogFixture.profile(),
    game = "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
    mapSection = 7,
    date = CatalogFixture.metDate(),
  })
  for _, member in ipairs(specs) do
    local factory = CatalogFixture.makeFactory(member.seed, catalog)
    local req = { species = member.species, level = member.level }
    if member.ability ~= nil then
      req.ability = member.ability
    end
    local record = factory:createNormal(CatalogFixture.normalRequest(req))
    record.moves = member.moves or { { move = "TACKLE", pp = 35, ppUps = 0 } }
    if member.currentHp ~= nil then
      record.condition.currentHp = member.currentHp
    end
    Assert.isTrue(owner:addMon(record), "the scene path needs its live party member")
  end
  return owner
end

---@param spec table foe description under test preparation
---@return table full mon-domain record for the enemy side
local function makeFoe(spec)
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local catalog = CatalogFixture.makeCatalog()
  local factory = CatalogFixture.makeFactory(spec.seed, catalog)
  local record = factory:createNormal(CatalogFixture.normalRequest({ species = spec.species, level = spec.level }))
  record.moves = spec.moves or { { move = "TACKLE", pp = 35, ppUps = 0 } }
  if spec.currentHp ~= nil then
    record.condition.currentHp = spec.currentHp
  end
  return record
end

---@param style string saved battle style under test driving
---@param scene boolean saved battle scene under test driving
---@return table player record carrying the style and scene beside a valid profile
local function playerRecordFor(style, scene)
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  return {
    profile = CatalogFixture.profile(),
    options = {
      textSpeed = "fastest",
      textFrame = 0,
      battleStyle = style,
      battleScene = scene,
      soundMode = "stereo",
      battleSpeed = 1,
    },
  }
end

---@param opts table rig options under test preparation
---@return table live rig with the runtime, screen, stocked bag, and submit log
local function openShiftRig(opts)
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local HgssBagService = require("libs.hgss.src.items.HgssBagService")
  local ItemFixture = require("libs.items.tests.item_fixture")
  local BattleRuntime = require("game.hgss.src.battle.BattleRuntime")
  local BattleScreenState = require("game.hgss.tests.support.BattleScreenFixture")
  local ScenarioFactory = require("libs.hgss.src.battle.HgssBattleScenarioFactory")
  local holder = {}
  local rig = {
    submits = {},
    packets = {},
    measurement = dualMeasurement(),
    text = { draws = {} },
    windows = { calls = {}, background = { 0.2, 0.3, 0.1, 1 } },
    audio = { plays = {} },
    assets = { prepared = {}, released = {} },
  }
  function rig.text.measure(content)
    return { width = 8 * #tostring(content), height = 16 }
  end
  function rig.text.drawText(content, x, y)
    rig.text.draws[#rig.text.draws + 1] = { content = tostring(content), x = x, y = y }
  end
  function rig.windows.drawWindow(box, frameKey, background)
    rig.windows.calls[#rig.windows.calls + 1] = { box = box, frame = frameKey, background = background }
  end
  function rig.windows.drawApplicationFrame(box, frameIndex)
    rig.windows.calls[#rig.windows.calls + 1] = { applicationBox = box, frame = frameIndex }
  end
  function rig.audio.play(first, second)
    rig.audio.plays[#rig.audio.plays + 1] = second ~= nil and second or first
    return true
  end
  function rig.audio.playPanned(_, symbol, pan)
    rig.audio.plays[#rig.audio.plays + 1] = symbol
    rig.audio.pans = rig.audio.pans or {}
    rig.audio.pans[#rig.audio.pans + 1] = pan
    return true
  end
  function rig.audio.playFanfare(_, symbol)
    rig.audio.plays[#rig.audio.plays + 1] = symbol
    return true
  end
  function rig.audio.stop(_, symbol)
    rig.audio.stops = rig.audio.stops or {}
    rig.audio.stops[#rig.audio.stops + 1] = symbol
    return true
  end
  function rig.assets.prepare(demand)
    rig.assets.prepared[#rig.assets.prepared + 1] = demand
    return true
  end
  function rig.assets.drawable(key)
    if rig.assets.images == nil then
      rig.assets.images = {}
    end
    if rig.assets.images[key] == nil then
      local hudImage = key:match("^hud:") ~= nil
      rig.assets.images[key] = {
        handle = key,
        width = hudImage and 1648 or 80,
        height = hudImage and 8 or 80,
        getWidth = function(image)
          return image.width
        end,
        getHeight = function(image)
          return image.height
        end,
        getDimensions = function(image)
          return image.width, image.height
        end,
        setFilter = function() end,
      }
    end
    return rig.assets.images[key]
  end
  function rig.assets.release(key)
    rig.assets.released[key] = (rig.assets.released[key] or 0) + 1
  end
  local party = makePartyOwner(opts.party or {
    { species = "EEVEE", level = 20, seed = 0x33333333 },
    { species = "EEVEE", level = 5, seed = 0x44444444 },
  })
  local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  party.swapPartyMons = function()
    error("a battle switch never reorders the persistent party", 2)
  end
  rig.party = party
  rig.bag = bag
  local launchId = opts.launchId or "launch-battle-scene"
  local foeLead = makeFoe(opts.foeLead or { species = "EEVEE", level = 4, seed = 0x5EED0002, currentHp = 1 })
  local foeReserve = makeFoe(opts.foeReserve or { species = "PICHU", level = 4, seed = 0x5EED0003 })
  local trainerId = launchId .. "-trainer"
  local scenario = ScenarioFactory.fromTrainer({
    id = launchId .. "-scenario",
    format = "single",
    trainers = {
      {
        id = trainerId,
        name = "JOEY",
        class = "YOUNGSTER",
        party = { foeLead, foeReserve },
        aiPasses = {},
      },
    },
  }, {
    party = party,
    bag = bag,
    player = { trainerId = 99, trainerName = "MINT", language = "english", trainerClassKey = "PKMN_TRAINER_ETHAN" },
  })
  rig.scenario = scenario
  local screen = BattleScreenState.new({
    launchId = launchId,
    manifest = (function()
      local BattlePresentationSchema = require("libs.assets.src.battle.BattlePresentationSchema")
      local manifest = deepCopy(ManifestFixture.manifest())
      manifest.scenes = { { key = "general/plain/day", background = "general", terrain = "plain", time = "day" } }
      BattlePresentationSchema.assertManifest(manifest)
      return manifest
    end)(),
    model = BattlePresentationModel,
    submit = function(reply)
      rig.submits[#rig.submits + 1] = reply
      return holder.battle:submit(reply)
    end,
    measureDisplay = function()
      return rig.measurement
    end,
    itemCatalog = ItemFixture.makeCatalog(),
    monCatalog = CatalogFixture.makeCatalog(),
    assets = rig.assets,
    text = rig.text,
    windows = rig.windows,
    audio = rig.audio,
    battleScene = opts.battleScene,
  })
  rig.screen = screen
  local port = screen:presentationPort()
  local present = port.present
  port.present = function(packet)
    rig.packets[#rig.packets + 1] = packet
    return present(packet)
  end
  rig.port = port
  holder.battle = BattleRuntime.new({
    request = { id = launchId, kind = "trainer", payload = { trainer = trainerId } },
    scenario = scenario,
    party = party,
    bag = bag,
    player = { record = playerRecordFor(opts.battleStyle or "shift", opts.battleScene), context = {} },
    presentation = rig.port,
    seed = opts.seedNum or 0x12345678,
  })
  rig.battle = holder.battle
  function rig.pump(ticks)
    for _ = 1, ticks or 1 do
      rig.battle:update()
      rig.screen:updateFixed(SourceTick.DT)
    end
  end
  return rig
end

---@param rig table live shift rig under test driving
local function ackShiftNarration(rig)
  local mode = rig.screen:status().mode
  if
    mode == "intro"
    or mode == "narration"
    or mode == "outcome"
    or rig.screen._timeline:messageActive()
    or rig.screen._timeline:levelUpStats() ~= nil
  then
    rig.screen:input({ { type = "confirm" } })
  end
end

---@param rig table live shift rig under test driving
---@param wanted string awaited battle decision kind under test driving
---@return table the battle request once the kernel asks for the wanted decision
local function waitForShiftRequest(rig, wanted)
  local lastPhase, lastKind, lastError = nil, nil, nil
  for _ = 1, 240 do
    ackShiftNarration(rig)
    local status = rig.battle:status()
    lastPhase = status.phase
    lastError = status.error
    lastKind = status.request ~= nil and status.request.kind or nil
    if status.phase == "failed" then
      error("the battle failed while awaiting " .. wanted .. ": " .. tostring(status.error), 0)
    end
    if status.phase == "complete" then
      error("the battle settled before asking for " .. wanted, 0)
    end
    if status.request ~= nil then
      if wanted == "shift" then
        local options = rig.battle:decisionOptions(status.request.requestId)
        if options ~= nil then
          for _, actor in ipairs(options.actors or {}) do
            if type(actor) == "table" and actor.kind == "shift" then
              return status.request
            end
          end
        end
      elseif status.request.kind == wanted then
        return status.request
      end
    end
    rig.pump(4)
  end
  error(
    "the battle never asked for "
      .. wanted
      .. " (phase="
      .. tostring(lastPhase)
      .. ", kind="
      .. tostring(lastKind)
      .. ", error="
      .. tostring(lastError)
      .. ")",
    0
  )
end

---@param rig table live shift rig under test driving
---@param request table open battle request under submission
local function submitFirstEnabledShiftMove(rig, request)
  local options = rig.battle:decisionOptions(request.requestId)
  Assert.notNil(options, "the opening turn projects its options")
  for _, actor in ipairs(options.actors or {}) do
    for _, choice in ipairs(actor.choices or {}) do
      if choice.role == "move" and choice.enabled == true then
        local ok, submitErr = rig.battle:submit({
          requestId = request.requestId,
          epoch = request.epoch,
          controller = request.controller,
          choices = { choice.choice },
        })
        Assert.isTrue(ok, "the opening strike is accepted: " .. tostring(submitErr))
        return
      end
    end
  end
  error("the opening request carries an enabled move", 0)
end

---@param request table shift decision options under inspection
---@return table the shift actor entry
local function shiftActorOf(request, rig)
  local options = rig.battle:decisionOptions(request.requestId)
  Assert.notNil(options, "the shift request projects its options")
  for _, actor in ipairs(options.actors or {}) do
    if type(actor) == "table" and actor.kind == "shift" then
      return actor
    end
  end
  error("the shift request addresses its shift actor", 0)
end

-- Scene Off leaves the optional stay-or-switch decision intact: the
-- knockout still publishes a pending shift offer, the offer holds
-- without input, and answering stay releases the frozen arrival.
function T.scene_off_shift_offer_stays_pending_then_settles()
  local rig = openShiftRig({ launchId = "launch-scene-shift", battleStyle = "shift", battleScene = false })
  local leadBefore = rig.party:partyMon(0)
  local opening = waitForShiftRequest(rig, "action")
  submitFirstEnabledShiftMove(rig, opening)
  local request = waitForShiftRequest(rig, "shift")
  local actor = shiftActorOf(request, rig)
  local stay = nil
  for _, choice in ipairs(actor.choices or {}) do
    if choice.id == "shift:stay" then
      stay = choice.choice
    end
  end
  Assert.notNil(stay, "the shift offer carries its stay fragment")
  for _ = 1, 20 do
    ackShiftNarration(rig)
    rig.pump(1)
  end
  local pending = rig.battle:status()
  Assert.notNil(pending.request, "the shift offer holds without input")
  Assert.equal(pending.request.requestId, request.requestId, "no input answers the offer early")
  local ok, submitErr = rig.battle:submit({
    requestId = request.requestId,
    epoch = request.epoch,
    controller = request.controller,
    choices = { stay },
  })
  Assert.isTrue(ok, "the stay answer is accepted: " .. tostring(submitErr))
  local following = waitForShiftRequest(rig, "action")
  Assert.isTrue(following.requestId ~= request.requestId, "the answered offer releases its decision")
  local arrivals = 0
  for _, packet in ipairs(rig.packets) do
    for _, event in ipairs(packet.events or {}) do
      if event.kind == "switch" and type(event.payload) == "table" and event.payload.to ~= nil then
        arrivals = arrivals + 1
      end
    end
  end
  Assert.isTrue(arrivals >= 1, "staying still releases the frozen arrival under Scene Off")
  Assert.deepEqual(rig.party:partyMon(0), leadBefore, "staying never touches the persistent party")
  rig.screen:dispose()
end

return { tests = T }
