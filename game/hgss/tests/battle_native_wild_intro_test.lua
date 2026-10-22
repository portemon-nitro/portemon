-- Frozen acceptance for the wild grass opening through the ordered cue
-- player: the first delivery stages the foe appearance and cry, then the
-- own send-out and cry, then the HUD and first command, in source order.
-- Native mechanism: the player-controller opening
-- (src/battle/battle_controller_player.c GET_BATTLE_MON, START_ENCOUNTER,
-- SEND_OUT) with opponent-controller entry tasks ordering enemy
-- presentation before the own send-out. Headless: hand-built
-- delivery-shaped packets drive the real cue player and the recording
-- sound sink; no dump capability is needed. The setup guards below are
-- green on the current boundary; the ordering gates stay red until the
-- dedicated flow owner lands.

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
---@param name string
---@param species string
---@param own boolean
---@return table displayed battler record under test driving
local function record(combatant, name, species, own)
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
    species = species,
    form = 0,
    name = name,
    level = own and 20 or 4,
    selector = own and "back" or "front",
    moves = own and { { move = "TACKLE", name = "Tackle", pp = 35, maxPp = 35 } } or nil,
    experience = 8000,
  }
end

---@return table detached opening view with a live lead and a wild foe
local function openingView()
  return {
    round = 1,
    status = "running",
    own = { record(1, "LEAD", "EEVEE", true) },
    foes = { record(3, "FOE", "CHIKORITA", false) },
    participants = {},
  }
end

---@param id integer
---@return table delivery-shaped opening packet carrying no events yet
local function openingPacket(id)
  return {
    launchId = "wild-intro-probe",
    packetId = id,
    events = {},
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

function T.opening_delivery_is_accepted_and_installs_both_sides()
  local sounds = sink()
  local timeline = BattleTimeline.new({
    sound = function(name)
      sounds.sound(name)
    end,
  })
  timeline:reset(openingView())
  Assert.isTrue(timeline:present(openingPacket(1)), "the opening delivery is accepted")
  local seen = {}
  for _, shown in ipairs(timeline:battlers()) do
    seen[shown.combatant] = true
  end
  Assert.isTrue(seen[1] == true, "the own lead is installed")
  Assert.isTrue(seen[3] == true, "the wild foe is installed")
end

function T.repeat_opening_delivery_replays_nothing()
  local sounds = sink()
  local timeline = BattleTimeline.new({
    sound = function(name)
      sounds.sound(name)
    end,
  })
  timeline:reset(openingView())
  Assert.isTrue(timeline:present(openingPacket(1)), "the first opening delivery is accepted")
  drain(timeline, 3000)
  local played = #sounds.played
  Assert.isFalse(timeline:present(openingPacket(1)), "the repeated opening delivery is rejected")
  drain(timeline, 3000)
  Assert.equal(#sounds.played, played, "the repeat emits no further sound intent")
end

function T.wild_opening_orders_foe_cry_before_own_send_out_cry()
  local sounds = sink()
  local timeline = BattleTimeline.new({
    sound = function(name)
      sounds.sound(name)
    end,
  })
  timeline:reset(openingView())
  Assert.isTrue(timeline:present(openingPacket(1)), "the opening delivery is accepted")
  drain(timeline, 3000)
  Assert.isTrue(timeline:settled(), "the opening drains fully")
  local cries = {}
  for _, name in ipairs(sounds.played) do
    if tostring(name):sub(1, 4) == "cry:" then
      cries[#cries + 1] = name
    end
  end
  Assert.isTrue(#cries >= 2, "the ordered opening carries both the foe cry and the own send-out cry")
  Assert.equal(cries[1], "cry:CHIKORITA", "the foe cry sounds before the own send-out")
  Assert.equal(cries[2], "cry:EEVEE", "the own send-out cries its lead after the foe")
end

function T.wild_opening_is_sequenced_by_the_flow_owner()
  local ok, Flow = pcall(require, "game.hgss.src.battle.BattlePresentationFlow")
  Assert.isTrue(ok, "the ordered battle flow owner resolves through the battle boundary")
  Assert.notNil(Flow, "the flow owner loads")
end

return { tests = T }
