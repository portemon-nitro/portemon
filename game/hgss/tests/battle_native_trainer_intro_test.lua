-- Frozen acceptance for the trainer opening with a fainted first party
-- slot: the benched fainted slot never walks out, the live lead is sent,
-- and the trainer entry (message, foe cry, send-out cry) plays in source
-- order. Native mechanism: the player-controller opening with trainer
-- presentation (src/battle/battle_controller_player.c TRAINER_MESSAGE,
-- SEND_OUT) alongside the opponent-controller entry tasks
-- (asm/overlay_12_battle_controller_opponent.s). Headless: hand-built
-- delivery-shaped packets drive the real cue player and the recording
-- sound sink; no dump capability is needed. The setup guards below are
-- green on the current boundary; the ordering gates stay red until the
-- dedicated flow owner lands.

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

---@return table detached opening view whose first slot is benched fainted
local function openingView()
  local fainted = {
    combatant = 1,
    participant = 1,
    side = 1,
    controller = "player",
    active = false,
    position = 1,
    activation = 1,
    hp = 0,
    maxHp = 52,
    species = "STARLY",
    form = 0,
    name = "BENCHED",
    level = 8,
    selector = "back",
    moves = { { move = "TACKLE", name = "Tackle", pp = 35, maxPp = 35 } },
    experience = 8000,
  }
  local live = {
    combatant = 2,
    participant = 2,
    side = 1,
    controller = "player",
    active = true,
    position = 2,
    activation = 2,
    hp = 38,
    maxHp = 38,
    species = "SHINX",
    form = 0,
    name = "LIVE",
    level = 9,
    selector = "back",
    moves = { { move = "TACKLE", name = "Tackle", pp = 35, maxPp = 35 } },
    experience = 8000,
  }
  local foe = {
    combatant = 3,
    participant = 3,
    side = 2,
    controller = "trainer",
    active = true,
    position = 3,
    activation = 3,
    hp = 45,
    maxHp = 45,
    species = "GEODUDE",
    form = 0,
    name = "FOE",
    level = 10,
    selector = "front",
    experience = 8000,
  }
  return {
    round = 1,
    status = "running",
    own = { fainted, live },
    foes = { foe },
    participants = {},
  }
end

---@param id integer
---@return table delivery-shaped opening packet carrying no events yet
local function openingPacket(id)
  return {
    launchId = "trainer-intro-probe",
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

function T.reset_installs_the_live_lead_and_never_the_benched_fainted_slot()
  local timeline = BattleTimeline.new({})
  timeline:reset(openingView())
  local ids = {}
  for _, shown in ipairs(timeline:battlers()) do
    ids[#ids + 1] = shown.combatant
  end
  Assert.deepEqual(ids, { 2, 3 }, "only the live lead and the foe open as displayed battlers")
end

function T.trainer_opening_cries_the_foe_then_the_live_lead()
  local sounds = sink()
  local timeline = BattleTimeline.new({
    sound = function(name)
      sounds.sound(name)
    end,
  })
  timeline:reset(openingView())
  Assert.isTrue(timeline:present(openingPacket(1)), "the trainer opening delivery is accepted")
  drain(timeline, 3000)
  Assert.isTrue(timeline:settled(), "the trainer opening drains fully")
  local cries = {}
  for _, name in ipairs(sounds.played) do
    if tostring(name):sub(1, 4) == "cry:" then
      cries[#cries + 1] = name
    end
  end
  Assert.isTrue(#cries >= 2, "the ordered trainer opening carries both the foe cry and the send-out cry")
  Assert.equal(cries[1], "cry:GEODUDE", "the foe cry sounds before the send-out")
  Assert.equal(cries[2], "cry:SHINX", "the send-out cries the live lead, never the benched fainted slot")
  for _, name in ipairs(cries) do
    Assert.isTrue(name ~= "cry:STARLY", "the fainted first slot never lends its cry")
  end
end

function T.trainer_opening_is_sequenced_by_the_flow_owner()
  local ok, Flow = pcall(require, "game.hgss.src.battle.BattlePresentationFlow")
  Assert.isTrue(ok, "the ordered battle flow owner resolves through the battle boundary")
  Assert.notNil(Flow, "the flow owner loads")
end

return { tests = T }
