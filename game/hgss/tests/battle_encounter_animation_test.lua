-- Wild opening pacing against subscript_0000_StartEncounter and
-- Task_PlayEncounterAnimation (src/battle/battle_controller_opponent.c):
-- PlayEncounterAnimation starts a task whose own frame counter voices
-- PASA2 on its first frame and PASA3 on frame 23, starts the first terrain
-- emitter set on frame 1 and the second on frame 20, arms the late main
-- background bank fade at frame 50, and ends only after the second
-- emitter system retires. The script then holds WaitTime 122 before the
-- foe health box slides in, and the encounter line prints only after that
-- slide. Palette bookkeeping lives in the battle-local palette evaluator;
-- this file proves the task schedule that drives it.

local Assert = require("tests.support.Assert")
local BattleRuntime = require("game.hgss.src.battle.BattleRuntime")
local BattleTimeline = require("game.hgss.tests.support.BattleTimelineFixture")
local BattleEncounterParticles = require("game.hgss.src.battle.BattleEncounterParticles")
local BattlePresentationSources = require("romdump.src.config.BattlePresentationSources")
local EncounterParticlesFixture = require("tests.support.BattleEncounterParticlesFixture")
local BattleAudio = require("libs.hgss.src.audio.BattleAudio")
local SourceTick = require("libs.hgss.src.field.SourceTick")

local T = {}
local TICK = SourceTick.DT

local function darkenWord(word, coefficient)
  local red = word % 32
  local green = math.floor(word / 32) % 32
  local blue = math.floor(word / 1024) % 32
  return (red + math.floor(-red * coefficient / 16))
    + (green + math.floor(-green * coefficient / 16)) * 32
    + (blue + math.floor(-blue * coefficient / 16)) * 1024
end

local function record(combatant, name, species, own)
  return {
    combatant = combatant,
    participant = combatant,
    side = own and 1 or 2,
    controller = own and "player" or "wild",
    active = true,
    position = combatant,
    activation = combatant,
    hp = 20,
    maxHp = 20,
    species = species,
    form = 0,
    name = name,
    level = 5,
    selector = own and "back" or "front",
    moves = own and { { move = "TACKLE", name = "Tackle", pp = 35, maxPp = 35 } } or nil,
    experience = 0,
  }
end

local function openingView()
  return {
    round = 1,
    status = "running",
    own = { record(1, "LEAD", "EEVEE", true) },
    foes = { record(3, "FOE", "CHIKORITA", false) },
    participants = {},
  }
end

-- Opens one wild task with its two emitter systems staged, mirroring the
-- screen's per-tick order: the timeline advances first, then the particle
-- owner steps with the published task frame.
---@param secondCount integer emitter count for the second set
---@param firstLife integer emitter lifespan for the first set
---@param secondLife integer emitter lifespan for the second set
---@return table task rig under test driving
local function openTask(secondCount, firstLife, secondLife)
  local task = { tick = 0, sounds = {}, frame = {}, systems = {}, lateMask = {}, mainBg = {} }
  local timeline = BattleTimeline.new({
    encounterFadeColor = "white",
    sound = function(cue)
      if type(cue) == "table" and cue.kind == "effect" then
        task.sounds[#task.sounds + 1] = { tick = task.tick, symbol = cue.symbol }
      end
    end,
  })
  local owner = BattleEncounterParticles.new({ splRandomState = { state = 0 } })
  local view = openingView()
  timeline:reset(view)
  timeline:intro(view, true)
  task.timeline = timeline
  task.owner = owner
  task.sets = EncounterParticlesFixture.sizedSets("grass/day/forest", 5, secondCount, firstLife, secondLife)
  for _, set in ipairs(task.sets) do
    for _, texture in ipairs(set.textures) do
      texture.drawable = { id = "encounter-drawable-" .. set.startTick .. "-" .. texture.id }
    end
  end
  return task
end

-- Advances one task rig a number of source ticks, recording the published
-- task frame, live system count, and palette evaluator state per tick.
---@param task table task rig under advancement
---@param count integer source ticks to consume
local function advance(task, count)
  for _ = 1, count do
    task.tick = task.tick + 1
    task.timeline:update(TICK, function(_)
      return true
    end)
    local presentation = task.timeline:openingPresentation() or {}
    task.owner:step(presentation.encounterFrame, task.sets)
    task.frame[task.tick] = presentation.encounterFrame
    task.systems[task.tick] = #task.owner:systems()
    local palette = presentation.encounterPalette
    if palette ~= nil then
      task.lateMask[task.tick] = palette.lateBgMask
      task.mainBg[task.tick] = palette.mainBg
    end
  end
end

---@param task table task rig under inspection
---@return integer? first tick with no published task frame, nil while the task runs
local function firstSilentTick(task)
  for index = 1, task.tick do
    if task.frame[index] == nil then
      return index
    end
  end
  return nil
end

---@param task table task rig under inspection
---@param symbol string staged sequence symbol under inspection
---@return integer[] ticks that voiced the symbol
local function soundTicks(task, symbol)
  local found = {}
  for _, sound in ipairs(task.sounds) do
    if sound.symbol == symbol then
      found[#found + 1] = sound.tick
    end
  end
  return found
end

function T.encounter_task_voices_its_two_source_sounds_once_on_their_frames()
  local task = openTask(11, 200, 200)
  advance(task, 200)
  Assert.deepEqual(
    soundTicks(task, BattleAudio.SINK_SOUNDS.encounterStart),
    { 1 },
    "PASA2 voices once on the task's first frame"
  )
  Assert.deepEqual(
    soundTicks(task, BattleAudio.SINK_SOUNDS.encounterSettle),
    { 23 },
    "PASA3 voices once on the task's 23rd frame"
  )
end

function T.encounter_task_runs_the_native_frame_and_emitter_schedule()
  local grass = BattlePresentationSources.encounterParticleSets("grass")
  Assert.deepEqual(grass, {
    { member = 5, emitterCount = 5 },
    { member = 6, emitterCount = 11 },
  }, "the grass terrain stages source members 5 and 6 with five and eleven emitters")
  local task = openTask(11, 200, 200)
  advance(task, 55)
  Assert.equal(#task.sets[1].emitters, 5, "the first staged set carries the five member-5 emitters")
  Assert.equal(#task.sets[2].emitters, 11, "the second staged set carries the eleven member-6 emitters")
  for _, frame in ipairs({ 1, 10, 20, 23, 28, 50 }) do
    Assert.equal(task.frame[frame], frame, "the task publishes frame " .. frame)
  end
  Assert.equal(task.systems[1], 1, "the first member starts on frame 1")
  Assert.equal(task.systems[10], 1, "the second member waits for frame 20")
  Assert.equal(task.systems[20], 2, "the second member starts on frame 20")
  Assert.equal(task.systems[55], 2, "neither member restarts or retires early")
  local live = task.owner:systems()
  Assert.equal(#live, 2, "both members run without duplicates")
  Assert.equal(#live[1].simulation.emitters, 5, "the first system runs all five member-5 emitters")
  Assert.equal(#live[2].simulation.emitters, 11, "the second system runs all eleven member-6 emitters")
  local silent = firstSilentTick(task)
  Assert.isTrue(
    silent == nil or silent > 50,
    "the task publishes no silence of its own before the frame-50 fade, got " .. tostring(silent)
  )
end

function T.encounter_task_arms_the_late_bank_fade_only_at_frame_50()
  local task = openTask(11, 200, 200)
  advance(task, 58)
  local opaqueLateWords = { [160] = 2861, [175] = 2966, [191] = 3251 }
  Assert.isNil(task.lateMask[44], "no late bank operation runs before frame 50")
  Assert.isNil(task.lateMask[49], "the restore still owns frames 28 through 49")
  Assert.equal(task.lateMask[50], 0x0C00, "frame 50 arms the late fade over background banks 10 and 11")
  Assert.equal(task.lateMask[51], 0x0C00, "the late fade arms once and is not reissued")
  for _, index in ipairs({ 160, 175, 191 }) do
    Assert.equal(task.mainBg[50][index + 1], 0, "frame 50 starts selected background entry " .. index .. " at black")
    Assert.equal(
      task.mainBg[51][index + 1],
      darkenWord(opaqueLateWords[index], 14),
      "frame 51 advances selected background entry " .. index .. " to coefficient 14"
    )
    Assert.equal(
      task.mainBg[58][index + 1],
      opaqueLateWords[index],
      "frame 58 returns selected background entry " .. index .. " to its opaque source"
    )
  end
  Assert.equal(task.mainBg[50][121], task.mainBg[49][121], "frame 50 leaves an unselected background bank unchanged")
  Assert.isTrue(
    task.mainBg[10][113] ~= task.mainBg[11][113],
    "the scheduled frame-10 event advances an unfilled selected background entry"
  )
end

function T.encounter_palette_restore_class_matches_the_accepted_battle_format()
  local function objectPalette(format, wild)
    local timeline = BattleTimeline.new()
    local view = openingView()
    view.format = format
    timeline:reset(view)
    timeline:intro(view, wild)
    for _ = 1, 30 do
      timeline:update(TICK, function(_)
        return true
      end)
    end
    local opening = assert(timeline:openingPresentation())
    return assert(opening.encounterPalette).mainObj
  end

  local wild = objectPalette("single", true)
  local trainer = objectPalette("single", false)
  local ordinaryDoubles = objectPalette("double", false)
  Assert.equal(wild[65], 24 + 12 * 32 + 3 * 1024, "wild singles restore only the native first 64 OBJ words")
  Assert.isTrue(trainer[65] ~= wild[65], "trainer singles restore their native first 80 OBJ words")
  Assert.isTrue(ordinaryDoubles[101] ~= wild[101], "ordinary doubles restore their native first 112 OBJ words")

  local function entryClass(kind, format)
    local plan = nil
    local runtime = BattleRuntime.new({
      request = {
        id = "palette-class-" .. kind .. "-" .. format,
        kind = kind,
        payload = kind == "wild" and { species = "EEVEE", level = 5 } or { trainer = "YOUNGSTER" },
      },
      scenario = { format = format },
      presentation = {
        enter = function(value)
          plan = value
          return true
        end,
        present = function(_) end,
        ready = function()
          return true
        end,
        leave = function(_)
          return true
        end,
        dispose = function() end,
        openCompletion = function(_)
          return false
        end,
        takeCompletion = function()
          return nil
        end,
      },
    })
    Assert.isTrue(runtime:_enterPresentation(), "the presentation accepts the battle entry plan")
    return assert(plan).encounterPaletteRestoreType
  end

  Assert.equal(entryClass("wild", "wild-single"), "wild", "wild singles use the wild OBJ restore span")
  Assert.equal(entryClass("trainer", "single"), "trainer", "trainer singles use the trainer OBJ restore span")
  Assert.equal(entryClass("wild", "wild-double"), "ordinary-doubles", "wild doubles use the ordinary doubles span")
  Assert.equal(entryClass("trainer", "double"), "ordinary-doubles", "trainer doubles use the ordinary doubles span")
  Assert.isFalse(
    pcall(function()
      entryClass("scripted", "single")
    end),
    "an unsupported scripted restore class fails with launch context"
  )
end

function T.encounter_task_outlives_the_script_hold()
  local sounds = {}
  local tick = 0
  local timeline = BattleTimeline.new({
    encounterFadeColor = "white",
    sound = function(cue)
      if type(cue) == "table" and cue.kind == "effect" then
        sounds[#sounds + 1] = { tick = tick, symbol = cue.symbol }
      end
    end,
  })
  local view = openingView()
  timeline:reset(view)
  timeline:intro(view, true)
  local frame = {}
  for index = 1, 150 do
    tick = index
    timeline:update(TICK, function(_)
      return true
    end)
    local opening = timeline:openingPresentation() or {}
    frame[index] = opening.encounterFrame
  end
  Assert.equal(frame[1], 1, "the task starts on the script's first tick")
  Assert.equal(frame[100], 100, "the task still runs while the script hold continues")
  Assert.equal(frame[122], 122, "the task outlives the full WaitTime 122")
end

function T.encounter_line_waits_for_the_122_frame_hold_and_the_foe_health_slide()
  local sounds = {}
  local tick = 0
  local timeline = BattleTimeline.new({
    encounterFadeColor = "white",
    sound = function(cue)
      if type(cue) == "table" and cue.kind == "effect" then
        sounds[#sounds + 1] = { tick = tick, symbol = cue.symbol }
      end
    end,
  })
  local view = openingView()
  timeline:reset(view)
  timeline:intro(view, true)
  local messageTick = nil
  local foeHud = {}
  for index = 1, 200 do
    tick = index
    timeline:update(TICK, function(_)
      return true
    end)
    if messageTick == nil and timeline:message() ~= "" then
      messageTick = index
    end
    for _, battler in ipairs(timeline:battlers()) do
      if battler.combatant == 3 then
        foeHud[index] = { visible = battler.hudVisible == true, offset = battler.hudOffsetX }
      end
    end
  end
  Assert.isTrue(messageTick ~= nil, "the encounter line prints")
  Assert.isTrue(messageTick > 122, "the line prints only after WaitTime 122")
  for tickIndex = 1, 122 do
    local hud = foeHud[tickIndex]
    Assert.isTrue(hud == nil or hud.visible == false, "the foe health box stays hidden through the hold")
  end
  Assert.isTrue(foeHud[messageTick].visible, "the foe health box arrived before the line")
  Assert.equal(foeHud[messageTick].offset, 0, "the foe health slide finished before the line")
end

function T.encounter_task_outlives_both_emitter_retirement_orders()
  local late = openTask(1, 10, 56)
  advance(late, 90)
  Assert.equal(late.frame[75], 75, "the task still runs while the second system stays active")
  local lateSilent = firstSilentTick(late)
  Assert.isTrue(
    lateSilent == nil or lateSilent > 75,
    "the task ends only after the second system retires, got " .. tostring(lateSilent)
  )
  local early = openTask(1, 10, 43)
  advance(early, 70)
  Assert.equal(early.frame[30], 30, "the task runs on while the first system is already gone")
  Assert.equal(early.systems[30], 1, "the retired first system leaves the second running")
  Assert.equal(early.frame[60], 60, "the task still runs while the second system stays active")
  Assert.equal(early.frame[62], 62, "the task reaches the second system's retirement tick")
  local earlySilent = firstSilentTick(early)
  Assert.isTrue(
    earlySilent == nil or earlySilent > 62,
    "the task ends only after the second system retires, got " .. tostring(earlySilent)
  )
end

function T.encounter_reset_and_dispose_control_the_task_lifecycle()
  local task = openTask(1, 10, 43)
  advance(task, 30)
  Assert.equal(task.frame[30], 30, "the task runs before the reset")
  local view = openingView()
  task.timeline:reset(view)
  task.timeline:intro(view, true)
  task.owner:clear()
  local soundsBefore = #task.sounds
  advance(task, 30)
  Assert.equal(task.frame[31], 1, "the restarted task begins at frame 1 again")
  Assert.equal(task.frame[60], 30, "the restarted task counts its own frames")
  local restarts = 0
  for _, sound in ipairs(task.sounds) do
    if sound.symbol == BattleAudio.SINK_SOUNDS.encounterStart then
      restarts = restarts + 1
    end
  end
  Assert.equal(
    restarts,
    2,
    "the reset voices the opening sound once per run, heard " .. tostring(#task.sounds - soundsBefore) .. " new voices"
  )
  Assert.equal(task.systems[60], 1, "the cleared systems restart from the first set")
  task.timeline:dispose()
  Assert.isNil(task.timeline:openingPresentation(), "disposal drops the opening presentation")
  local disposedSounds = #task.sounds
  task.timeline:update(TICK, function(_)
    return true
  end)
  Assert.equal(#task.sounds, disposedSounds, "disposal voices no further sounds")
end

return { tests = T }
