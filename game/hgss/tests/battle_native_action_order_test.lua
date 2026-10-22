-- Frozen acceptance for ordered native action playback through the cue
-- player: one action occurrence narrates its attack once however many
-- hits it lands, checkpoints apply in order, one-shot sounds never repeat
-- from polling, and the visual execution runs through the battle
-- animation player. Native mechanism: the controller tasks order attack
-- narration before per-hit updates while BtlCmd_Wait holds on outstanding
-- controller work rather than fixed host time
-- (src/battle/battle_command.c). Headless: hand-built delivery-shaped
-- packets drive the real cue player; no dump capability is needed. The
-- setup guards below are green on the current boundary; the ordering and
-- player gates stay red until the native playback lands.

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

---@param combatant integer
---@param hp integer
---@param maxHp integer
---@return table checkpoint fragment for one combatant
local function checkpoint(combatant, hp, maxHp)
  return {
    activation = combatant,
    controller = combatant == 1 and "player" or "wild",
    experience = 100,
    form = 0,
    hp = hp,
    maxHp = maxHp,
    participant = combatant,
    position = combatant,
    side = combatant == 1 and 1 or 2,
    species = "EEVEE",
  }
end

---@return table detached dynamic view with a full-health player lead and foe
local function openingView()
  local function entry(combatant, hp, maxHp, own)
    return {
      combatant = combatant,
      participant = combatant,
      side = own and 1 or 2,
      controller = own and "player" or "wild",
      active = true,
      position = combatant,
      activation = combatant,
      hp = hp,
      maxHp = maxHp,
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
    own = { entry(1, 52, 52, true) },
    foes = { entry(3, 57, 57, false) },
    participants = {},
  }
end

---@param sequence integer
---@param foeHp integer foe health after this hit
---@return table one sanitized strike event for the shared attack occurrence
local function strikeEvent(sequence, foeHp)
  local combatants = {
    [1] = checkpoint(1, 52, 52),
    [3] = checkpoint(3, foeHp, 57),
  }
  return {
    sequence = sequence,
    kind = "struck",
    cause = { key = "TACKLE" },
    audience = "public",
    actors = { { combatant = 1 } },
    targets = { { combatant = 3 } },
    move = { executed = "TACKLE" },
    payload = { target = 3, damage = 14, hitIndex = sequence },
    after = { hp = { [1] = 52, [3] = foeHp }, combatants = combatants },
  }
end

---@param id integer
---@param events table
---@param foeHp integer final foe health for the after view
---@return table delivery-shaped action packet
local function actionPacket(id, events, foeHp)
  local after = openingView()
  after.foes[1].hp = foeHp
  return {
    launchId = "action-order-probe",
    packetId = id,
    events = events,
    before = openingView(),
    after = after,
    request = nil,
    result = nil,
  }
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

---@param texts table
---@param needle string
---@return integer occurrences of the needle across collected narration
local function countContaining(texts, needle)
  local total = 0
  for _, text in ipairs(texts) do
    if tostring(text):find(needle, 1, true) ~= nil then
      total = total + 1
    end
  end
  return total
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

function T.single_strike_narrates_its_attack_once_then_moves_health()
  local timeline = BattleTimeline.new({})
  timeline:reset(openingView())
  Assert.isTrue(timeline:present(actionPacket(1, { strikeEvent(1, 43) }, 43)), "the strike packet is accepted")
  local texts = collectMessages(timeline)
  Assert.isTrue(timeline:settled(), "the strike drains fully")
  Assert.equal(countContaining(texts, "used Tackle"), 1, "the attack narration plays exactly once")
  Assert.equal(battler(timeline:battlers(), 3).hp, 43, "the exact final health applies at completion")
  Assert.equal(battler(timeline:battlers(), 1).hp, 52, "untouched health never moves")
end

function T.repeated_action_delivery_replays_nothing()
  local sounds = sink()
  local timeline = BattleTimeline.new({
    sound = function(name)
      sounds.sound(name)
    end,
  })
  timeline:reset(openingView())
  Assert.isTrue(timeline:present(actionPacket(1, { strikeEvent(1, 43) }, 43)), "the first packet is accepted")
  collectMessages(timeline)
  local played = #sounds.played
  Assert.isFalse(
    timeline:present(actionPacket(1, { strikeEvent(1, 43) }, 43)),
    "the repeated packet identity is rejected"
  )
  collectMessages(timeline)
  Assert.equal(#sounds.played, played, "polling and repeats emit no further one-shot sound")
end

function T.multi_hit_occurrence_narrates_its_attack_once()
  local timeline = BattleTimeline.new({})
  timeline:reset(openingView())
  Assert.isTrue(
    timeline:present(actionPacket(1, { strikeEvent(1, 43), strikeEvent(2, 30) }, 30)),
    "the two-hit packet is accepted"
  )
  local texts = collectMessages(timeline)
  Assert.isTrue(timeline:settled(), "both hits drain fully")
  Assert.equal(countContaining(texts, "used Tackle"), 1, "one attack occurrence narrates once across both hits")
  Assert.equal(battler(timeline:battlers(), 3).hp, 30, "both hit checkpoints apply in order")
end

function T.attack_animation_runs_through_the_animation_player()
  local ok, Player = pcall(require, "libs.hgss.src.presentation.BattleAnimationPlayer")
  Assert.isTrue(ok, "the battle animation player resolves through the presentation boundary")
  Assert.notNil(Player, "the animation player loads")
end

return { tests = T }
