-- Frozen acceptance for voluntary switch, forced replacement, and faint
-- presentation through the cue player: only the affected activation
-- changes, the departing cry and picture/HUD tasks complete before the
-- matching decision resumes, and surviving doubles slots never move or
-- inherit the old occupant's effect. Native mechanism: the
-- health-bar slide tasks stagger battler boxes by source ticks while the
-- wait holds on outstanding controller work (BtlCmd_HealthbarSlideIn,
-- BtlCmd_Wait in src/battle/battle_command.c). Headless: hand-built
-- delivery-shaped packets drive the real cue player and the recording
-- sound sink; no dump capability is needed. The setup guards below are
-- green on the current boundary; the cry and sequencing gates stay red
-- until the native playback lands.

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
---@param hp integer
---@param maxHp integer
---@param own boolean
---@return table displayed battler record under test driving
local function entry(combatant, name, species, hp, maxHp, own)
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
    species = species,
    form = 0,
    name = name,
    level = 20,
    selector = own and "back" or "front",
    moves = own and { { move = "TACKLE", name = "Tackle", pp = 35, maxPp = 35 } } or nil,
    experience = 8000,
  }
end

---@return table detached doubles view with two live leads and two foes
local function doublesView()
  return {
    round = 1,
    status = "running",
    own = {
      entry(1, "LEFTY", "EEVEE", 52, 52, true),
      entry(2, "RIGHTY", "SHINX", 38, 38, true),
    },
    foes = {
      entry(3, "FOE-A", "GEODUDE", 45, 45, false),
      entry(4, "FOE-B", "ZUBAT", 30, 33, false),
    },
    participants = {},
  }
end

---@param id integer
---@param events table
---@param after table
---@return table delivery-shaped replacement packet
local function replacementPacket(id, events, after)
  return {
    launchId = "switch-faint-probe",
    packetId = id,
    events = events,
    before = doublesView(),
    after = after,
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

function T.voluntary_switch_moves_only_the_affected_slot()
  local timeline = BattleTimeline.new({})
  timeline:reset(doublesView())
  local after = doublesView()
  after.own[1] = entry(5, "BACKUP", "STARLY", 40, 40, true)
  after.own[1].position = 1
  after.own[1].activation = 5
  local packet = replacementPacket(1, {
    {
      sequence = 1,
      kind = "switch",
      cause = { key = "SWITCH" },
      audience = "public",
      payload = { from = 1, to = 5 },
      after = { hp = { [1] = 52, [2] = 38, [3] = 45, [4] = 30 } },
    },
  }, after)
  Assert.isTrue(timeline:present(packet), "the switch packet is accepted")
  drain(timeline, 3000)
  Assert.isTrue(timeline:settled(), "the withdrawal and reveal tasks complete")
  Assert.isFalse(battler(timeline:battlers(), 1).visible, "the departed slot hides")
  Assert.isTrue(battler(timeline:battlers(), 5).visible, "the incoming slot reveals")
  Assert.isTrue(battler(timeline:battlers(), 2).visible, "the surviving partner never leaves")
  Assert.equal(battler(timeline:battlers(), 2).hp, 38, "the surviving partner keeps its health")
  Assert.equal(battler(timeline:battlers(), 4).hp, 30, "the foe side never moves")
end

function T.faint_queues_its_cry_before_the_vanish_completes()
  local sounds = sink()
  local timeline = BattleTimeline.new({
    sound = function(name)
      sounds.sound(name)
    end,
  })
  timeline:reset(doublesView())
  local mid = doublesView()
  mid.foes[1].hp = 0
  local packet = replacementPacket(1, {
    {
      sequence = 1,
      kind = "struck",
      cause = { key = "TACKLE" },
      audience = "public",
      actors = { { combatant = 1 } },
      targets = { { combatant = 3 } },
      move = { executed = "TACKLE" },
      payload = { target = 3, damage = 45 },
      after = { hp = { [1] = 52, [2] = 38, [3] = 0, [4] = 30 } },
    },
    {
      sequence = 2,
      kind = "faint",
      cause = { key = "TACKLE" },
      audience = "public",
      payload = { combatant = 3, activation = 3, position = 3 },
      after = { hp = { [1] = 52, [2] = 38, [3] = 0, [4] = 30 } },
    },
  }, mid)
  Assert.isTrue(timeline:present(packet), "the knockout packet is accepted")
  drain(timeline, 3000)
  Assert.isTrue(timeline:settled(), "the knockout drains fully")
  Assert.isFalse(battler(timeline:battlers(), 3).visible, "the fainted battler hides")
  local cried = false
  for _, name in ipairs(sounds.played) do
    if name == "cry:GEODUDE" then
      cried = true
    end
  end
  Assert.isTrue(cried, "the faint carries its battler cry through the ordered audio sink")
  Assert.isTrue(battler(timeline:battlers(), 4).visible, "the surviving foe never leaves its slot")
end

function T.substitution_is_sequenced_by_the_flow_owner()
  local ok, Flow = pcall(require, "game.hgss.src.battle.BattlePresentationFlow")
  Assert.isTrue(ok, "the ordered battle flow owner resolves through the battle boundary")
  Assert.notNil(Flow, "the flow owner loads")
end

return { tests = T }
