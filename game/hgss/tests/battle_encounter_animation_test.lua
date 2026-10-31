-- Wild opening pacing against subscript_0000_StartEncounter and
-- Task_PlayEncounterAnimation (src/battle/battle_controller_opponent.c):
-- PlayEncounterAnimation starts a task whose own frame counter voices
-- PASA2 on its first frame and PASA3 on frame 23, fades the main screen
-- toward the background fade color over frames 10-26 and back over frames
-- 28-44, and drives the lower screen through a black-to-white ramp. The
-- script then holds WaitTime 122 before the foe health box slides in, and
-- the encounter line prints only after that slide.

local Assert = require("tests.support.Assert")
local BattleTimeline = require("game.hgss.tests.support.BattleTimelineFixture")
local BattleAudio = require("libs.hgss.src.audio.BattleAudio")
local SourceTick = require("libs.hgss.src.field.SourceTick")

local T = {}
local TICK = SourceTick.DT

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

---@param fadeColor string
---@return table timeline, table log per-tick facts
local function runWildOpening(fadeColor, ticks)
  local sounds = {}
  local tick = 0
  local timeline = BattleTimeline.new({
    encounterFadeColor = fadeColor,
    sound = function(cue)
      if type(cue) == "table" and cue.kind == "effect" then
        sounds[#sounds + 1] = { tick = tick, symbol = cue.symbol }
      end
    end,
  })
  local view = openingView()
  timeline:reset(view)
  timeline:intro(view, true)
  local log = { sounds = sounds, flash = {}, lower = {}, messageTick = nil, foeHud = {} }
  for index = 1, ticks do
    tick = index
    timeline:update(TICK, function(_)
      return true
    end)
    local opening = timeline:openingPresentation() or {}
    log.flash[index] = opening.encounterFlash
    log.lower[index] = opening.encounterLower
    if log.messageTick == nil and timeline:message() ~= "" then
      log.messageTick = index
    end
    for _, battler in ipairs(timeline:battlers()) do
      if battler.combatant == 3 then
        log.foeHud[index] = { visible = battler.hudVisible == true, offset = battler.hudOffsetX }
      end
    end
  end
  return timeline, log
end

function T.encounter_animation_voices_its_two_source_sounds_on_their_frames()
  local _, log = runWildOpening("white", 40)
  local first, second = nil, nil
  for _, sound in ipairs(log.sounds) do
    if sound.symbol == BattleAudio.SINK_SOUNDS.encounterStart then
      first = first or sound.tick
    elseif sound.symbol == BattleAudio.SINK_SOUNDS.encounterSettle then
      second = second or sound.tick
    end
  end
  Assert.equal(first, 1, "PASA2 voices on the task's first frame")
  Assert.equal(second, 23, "PASA3 voices on the task's 23rd frame")
end

function T.encounter_animation_fades_the_main_screen_toward_the_background_color_and_back()
  local _, log = runWildOpening("white", 60)
  Assert.equal(log.flash[9], nil, "no fade runs before frame 10")
  Assert.equal(log.flash[10].coefficient, 0, "the fade starts from zero on frame 10")
  Assert.equal(log.flash[10].color, "white", "the fade names its background color")
  Assert.equal(log.flash[26].coefficient, 16, "the fade peaks sixteen steps later")
  Assert.equal(log.flash[28].coefficient, 16, "the peak holds until the restore on frame 28")
  Assert.equal(log.flash[44].coefficient, 0, "the restore fade takes sixteen steps")
  Assert.equal(log.flash[45], nil, "the fade ends after the restore")
end

function T.cave_backgrounds_fade_to_black()
  local _, log = runWildOpening("black", 30)
  Assert.equal(log.flash[20].color, "black", "caves fade to black")
end

function T.lower_screen_ramps_from_black_to_white_then_reveals()
  local _, log = runWildOpening("white", 60)
  Assert.equal(log.lower[5].level, 0, "the lower screen starts black")
  Assert.equal(log.lower[10].level, 1, "the gray ramp advances one step on frame 10")
  Assert.equal(log.lower[25].level, 16, "the ramp reaches white after sixteen steps")
  Assert.equal(log.lower[27].level, 16, "white holds until frame 28")
  Assert.equal(log.lower[28].level, nil, "the restore reveals the real lower screen")
  Assert.equal(log.lower[28].whiteCoefficient, 16, "the reveal fades from white")
  Assert.equal(log.lower[44].whiteCoefficient, 0, "the reveal takes sixteen steps")
end

function T.encounter_line_waits_for_the_122_frame_hold_and_the_foe_health_slide()
  local _, log = runWildOpening("white", 200)
  Assert.isTrue(log.messageTick ~= nil, "the encounter line prints")
  Assert.isTrue(log.messageTick > 122, "the line prints only after WaitTime 122")
  for tick = 1, 122 do
    local hud = log.foeHud[tick]
    Assert.isTrue(hud == nil or hud.visible == false, "the foe health box stays hidden through the hold")
  end
  Assert.isTrue(log.foeHud[log.messageTick].visible, "the foe health box arrived before the line")
  Assert.equal(log.foeHud[log.messageTick].offset, 0, "the foe health slide finished before the line")
end

return { tests = T }
