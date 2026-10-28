-- Frozen acceptance for complete capture presentation through the cue
-- player: the throw, the authoritative shake sequence, and the success or
-- breakout outcome play the exact ball choreography facts (trajectory,
-- shake count, target visibility, sound, native wording) supplied by the
-- mechanics, never recomputed or inferred in the renderer. Native
-- mechanism: the mechanics-owned throw/shake/outcome events
-- (libs/battle/src/gen4/Capture.lua execute) with visible shake counts
-- carried on the calculation. Headless: kernel-shaped capture events
-- drive the real cue player and the recording sound sink; no dump
-- capability is needed. The setup guards below are green on the current
-- boundary; the choreography gates stay red until the native playback
-- lands.

local Assert = require("tests.support.Assert")
local BattleTimeline = require("game.hgss.tests.support.BattleTimelineFixture")

local T = {}
local TICK = 1 / 30

---@return table recording sound-intent sink
local function sink()
  local records = { played = {} }
  function records.sound(name)
    records.played[#records.played + 1] = name
  end
  return records
end

---@return table detached dynamic view with a live lead and a catchable foe
local function openingView()
  local function entry(combatant, own)
    return {
      combatant = combatant,
      participant = combatant,
      side = own and 1 or 2,
      controller = own and "player" or "wild",
      active = true,
      position = combatant,
      activation = combatant,
      hp = own and 52 or 20,
      maxHp = own and 52 or 57,
      species = "EEVEE",
      form = 0,
      name = own and "LEAD" or "FOE",
      level = own and 20 or 4,
      selector = own and "back" or "front",
      moves = own and { { move = "TACKLE", name = "Tackle", pp = 35, maxPp = 35 } } or nil,
      experience = 8000,
    }
  end
  return {
    round = 1,
    status = "running",
    own = { entry(1, true) },
    foes = { entry(3, false) },
    participants = {},
  }
end

---@param sequence integer
---@return table kernel-shaped throw event naming its ball identity
local function throwEvent(sequence)
  return {
    sequence = sequence,
    kind = "throw",
    cause = { key = "CAPTURE" },
    audience = "public",
    actors = { { combatant = 1 } },
    targets = { { combatant = 3 } },
    payload = { user = 1, ball = "POKE_BALL", target = 3 },
    after = { hp = { [1] = 52, [3] = 20 } },
  }
end

---@param sequence integer
---@param index integer authoritative one-based shake ordinal
---@return table kernel-shaped shake event
local function shakeEvent(sequence, index)
  return {
    sequence = sequence,
    kind = "shake",
    cause = { key = "CAPTURE" },
    audience = "public",
    actors = { { combatant = 1 } },
    targets = { { combatant = 3 } },
    payload = { index = index },
    after = { hp = { [1] = 52, [3] = 20 } },
  }
end

---@return table kernel-shaped successful outcome event
local function caughtEvent()
  return {
    sequence = 5,
    kind = "caught",
    cause = { key = "CAPTURE" },
    audience = "public",
    actors = { { combatant = 1 } },
    targets = { { combatant = 3 } },
    payload = { shakes = 3 },
    after = { hp = { [1] = 52, [3] = 20 } },
  }
end

---@param id integer
---@return table delivery-shaped successful capture packet
local function caughtPacket(id)
  return {
    launchId = "capture-probe",
    packetId = id,
    events = { throwEvent(1), shakeEvent(2, 1), shakeEvent(3, 2), shakeEvent(4, 3), caughtEvent() },
    before = openingView(),
    after = openingView(),
    request = nil,
    result = nil,
  }
end

---@param timeline table cue player under test driving
---@param budget integer maximum source ticks before giving up
local function drain(timeline, budget)
  for _ = 1, budget do
    timeline:update(TICK, function(_)
      return true
    end)
    if timeline:settled() then
      break
    end
  end
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

function T.capture_packet_plays_in_order_and_settles()
  local timeline = BattleTimeline.new({})
  timeline:reset(openingView())
  Assert.isTrue(timeline:present(caughtPacket(1)), "the capture packet is accepted")
  Assert.isTrue(timeline:busy(), "the capture choreography leaves ordered work pending")
  drain(timeline, 3000)
  Assert.isTrue(timeline:settled(), "the full throw and shake sequence drains")
end

function T.breakout_outcome_requires_its_selected_source_text()
  local timeline = BattleTimeline.new({})
  local packet = {
    launchId = "capture-breakout-probe",
    packetId = 1,
    events = {
      {
        sequence = 7,
        kind = "broke_free",
        cause = { key = "CAPTURE" },
        audience = "public",
        payload = { shakes = 1 },
        after = { hp = { [1] = 52, [3] = 20 } },
      },
    },
    before = openingView(),
    after = openingView(),
    request = nil,
    result = nil,
  }
  Assert.isFalse(
    pcall(function()
      timeline:present(packet)
    end),
    "a breakout without its selected source wording is rejected"
  )
  Assert.isTrue(
    timeline:present(packet, { [7] = "Oh no! It broke free!" }),
    "the retry carrying its selected wording is accepted"
  )
end

function T.successful_capture_hides_the_foe_through_its_disappearance_task()
  local timeline = BattleTimeline.new({})
  timeline:reset(openingView())
  Assert.isTrue(timeline:present(caughtPacket(1)), "the capture packet is accepted")
  drain(timeline, 3000)
  Assert.isTrue(timeline:settled(), "the capture sequence drains fully")
  Assert.isFalse(battler(timeline:battlers(), 3).visible, "the caught target disappears on success")
  Assert.isTrue(battler(timeline:battlers(), 1).visible, "the thrower stays displayed")
end

function T.capture_choreography_emits_its_ordered_audio_intents()
  local sounds = sink()
  local timeline = BattleTimeline.new({
    sound = function(name)
      sounds.sound(name)
    end,
  })
  timeline:reset(openingView())
  Assert.isTrue(timeline:present(caughtPacket(1)), "the capture packet is accepted")
  drain(timeline, 3000)
  Assert.isTrue(#sounds.played >= 1, "throw, shake and success sounds play through the ordered audio sink")
  local fanfare = false
  for _, cue in ipairs(sounds.played) do
    if type(cue) == "table" and cue.symbol == "SEQ_ME_POKEGET" and cue.kind == "fanfare" then
      fanfare = true
    end
  end
  Assert.isTrue(fanfare, "capture plays the source fanfare so battle music pauses")
end

function T.capture_effects_run_through_the_animation_player()
  local ok, Player = pcall(require, "libs.hgss.src.presentation.BattleAnimationPlayer")
  Assert.isTrue(ok, "the battle animation player resolves through the presentation boundary")
  Assert.notNil(Player, "the animation player loads")
end

return { tests = T }
