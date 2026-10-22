-- Frozen acceptance for win, flee, capture, defeat, and draw result
-- presentation through the cue player: the native result sequence (its
-- message, music transfer, and acknowledgement) plays through ordered
-- playback exactly once, the committed receipt is never duplicated, and
-- the field return never appears early. Native mechanism: the
-- controller/effect/audio/printer barriers complete before the result
-- commits, and the outcome acknowledgement is required only where the
-- source requires it. Headless: hand-built delivery-shaped packets drive
-- the real cue player and the recording sound sink; no dump capability is
-- needed. The setup guards below are green on the current boundary; the
-- result-sequence gates stay red until the native playback lands.

local Assert = require("tests.support.Assert")
local BattleTimeline = require("game.hgss.src.battle.BattleTimeline")

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

---@return table detached dynamic view with a live lead and a foe
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
      hp = own and 52 or 57,
      maxHp = own and 52 or 57,
      species = "EEVEE",
      form = 0,
      name = own and "LEAD" or "FOE",
      level = 20,
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

---@param id integer
---@param events table ordered sanitized events under test driving
---@param result table? committed terminal receipt carried by the delivery
---@return table delivery-shaped result packet
local function resultPacket(id, events, result)
  return {
    launchId = "outcome-probe",
    packetId = id,
    events = events,
    before = openingView(),
    after = openingView(),
    request = nil,
    result = result,
  }
end

---@return table kernel-shaped failed-escape event under test driving
local function failedEscape()
  return {
    sequence = 1,
    kind = "flee",
    cause = { key = "FLEE" },
    audience = "public",
    actors = { { combatant = 1 } },
    targets = { { combatant = 1 } },
    payload = { combatant = 1, escaped = false },
    after = { hp = { [1] = 52, [3] = 57 } },
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

---@param timeline table cue player under test driving
---@return table ordered fully revealed narration texts
local function collectMessages(timeline)
  local seen = {}
  local texts = {}
  for _ = 1, 3000 do
    timeline:update(TICK, function(_)
      return true
    end)
    local id = timeline:messageId()
    if id ~= 0 and seen[id] == nil and timeline:ack() then
      seen[id] = true
      texts[#texts + 1] = timeline:message()
    end
    if timeline:settled() then
      break
    end
  end
  return texts
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

function T.failed_escape_narrates_and_leaves_the_launch_running()
  local timeline = BattleTimeline.new({})
  timeline:reset(openingView())
  Assert.isTrue(timeline:present(resultPacket(1, { failedEscape() }, nil)), "the failed-escape packet is accepted")
  local texts = collectMessages(timeline)
  Assert.isTrue(timeline:settled(), "the failed escape drains")
  Assert.isTrue(#texts >= 1, "the failed escape narrates its moment in order")
  Assert.isTrue(battler(timeline:battlers(), 3).visible, "the foe stays displayed after a failed escape")
end

function T.repeat_result_delivery_replays_nothing()
  local sounds = sink()
  local timeline = BattleTimeline.new({
    sound = function(name)
      sounds.sound(name)
    end,
  })
  timeline:reset(openingView())
  Assert.isTrue(timeline:present(resultPacket(1, {}, { word = "win" })), "the result-bearing delivery is accepted")
  drain(timeline, 3000)
  local played = #sounds.played
  Assert.isFalse(timeline:present(resultPacket(1, {}, { word = "win" })), "the repeated result delivery is rejected")
  drain(timeline, 3000)
  Assert.equal(#sounds.played, played, "the committed receipt never replays its presentation")
end

function T.won_result_plays_its_ordered_terminal_sequence_once()
  local sounds = sink()
  local timeline = BattleTimeline.new({
    sound = function(name)
      sounds.sound(name)
    end,
  })
  timeline:reset(openingView())
  Assert.isTrue(timeline:present(resultPacket(1, {}, { word = "win" })), "the win result delivery is accepted")
  local texts = collectMessages(timeline)
  Assert.isTrue(timeline:settled(), "the result sequence drains fully")
  Assert.isTrue(#texts >= 1, "the native result message plays through ordered playback")
  -- Native victory is a plain BGM swap (PlayBGM SEQ_GS_WIN2 for wild wins,
  -- battle_controller_player.c / battle_command.c), never a fanfare: the
  -- wild win voices its victory music through a music cue.
  local music = nil
  for _, played in ipairs(sounds.played) do
    if type(played) == "table" and played.kind == "music" then
      music = played
    end
  end
  Assert.notNil(music, "the wild win voices its victory music cue")
  Assert.equal(music.symbol, "SEQ_GS_WIN2", "the wild victory keeps its native wild-win symbol")
  Assert.isFalse(timeline:present(resultPacket(1, {}, { word = "win" })), "the same result never plays twice")
end

function T.result_sequencing_is_owned_by_the_flow_owner()
  local ok, Flow = pcall(require, "game.hgss.src.battle.BattlePresentationFlow")
  Assert.isTrue(ok, "the ordered battle flow owner resolves through the battle boundary")
  Assert.notNil(Flow, "the flow owner loads")
end

return { tests = T }
