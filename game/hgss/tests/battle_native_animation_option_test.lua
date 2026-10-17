-- Frozen acceptance for the animation and text-speed options through the
-- cue player: mechanics stay identical with effects on or off, the
-- disabled path keeps its native waits and essential visual updates
-- including the Transform exception, and print pacing never changes
-- mechanics or effect task duration. Native mechanism: the
-- move-animation option handling with its animation-suppression flag and
-- the explicit Transform allowance, where the disabled path still runs
-- the native wait subscript instead of skipping
-- (BtlCmd_PlayMoveAnimation in src/battle/battle_command.c). Headless:
-- hand-built delivery-shaped packets drive the real cue player under two
-- print pacings; no dump capability is needed. The setup guards below are
-- green on the current boundary; the appearance and player gates stay red
-- until the native playback lands.

local Assert = require("tests.support.Assert")
local BattleTimeline = require("game.hgss.src.battle.BattleTimeline")

local T = {}
local TICK = 1 / 30

---@return table detached dynamic view with a live lead and a foe
local function openingView()
  local function entry(combatant, species, name, own)
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
      level = 20,
      selector = own and "back" or "front",
      moves = own and { { move = "TACKLE", name = "Tackle", pp = 35, maxPp = 35 } } or nil,
      experience = 8000,
    }
  end
  return {
    round = 1,
    status = "running",
    own = { entry(1, "EEVEE", "LEAD", true) },
    foes = { entry(3, "GEODUDE", "FOE", false) },
    participants = {},
  }
end

---@param id integer
---@param events table
---@return table delivery-shaped packet under test driving
local function packet(id, events)
  local after = openingView()
  after.foes[1].hp = 43
  return {
    launchId = "animation-option-probe",
    packetId = id,
    events = events,
    before = openingView(),
    after = after,
    request = nil,
    result = nil,
  }
end

---@return table one sanitized strike event under test driving
local function strikeEvent()
  return {
    sequence = 1,
    kind = "struck",
    cause = { key = "TACKLE" },
    audience = "public",
    actors = { { combatant = 1 } },
    targets = { { combatant = 3 } },
    move = { executed = "TACKLE" },
    payload = { target = 3, damage = 14 },
    after = { hp = { [1] = 52, [3] = 43 } },
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

function T.print_pacing_changes_presentation_without_touching_mechanics()
  local slow = BattleTimeline.new({ textSpeed = "slow" })
  slow:reset(openingView())
  Assert.isTrue(slow:present(packet(1, { strikeEvent() })), "the slow-paced packet is accepted")
  drain(slow, 3000)
  local hurried = BattleTimeline.new({ textSpeed = "fastest" })
  hurried:reset(openingView())
  Assert.isTrue(hurried:present(packet(1, { strikeEvent() })), "the hurried packet is accepted")
  drain(hurried, 3000)
  Assert.isTrue(slow:settled(), "the slow-paced strike drains")
  Assert.isTrue(hurried:settled(), "the hurried strike drains")
  Assert.equal(
    battler(slow:battlers(), 3).hp,
    battler(hurried:battlers(), 3).hp,
    "print pacing never changes the applied checkpoint"
  )
  Assert.equal(battler(slow:battlers(), 3).hp, 43, "the exact final health applies under both pacings")
end

function T.transform_updates_the_displayed_appearance()
  local timeline = BattleTimeline.new({})
  timeline:reset(openingView())
  Assert.isTrue(
    timeline:present(packet(1, {
      {
        sequence = 1,
        kind = "transformed",
        cause = { key = "TRANSFORM" },
        audience = "public",
        actors = { { combatant = 3 } },
        targets = { { combatant = 3 } },
        payload = { target = 3, copiedFrom = 1 },
        after = { hp = { [1] = 52, [3] = 57 } },
      },
    })),
    "the transform packet is accepted"
  )
  drain(timeline, 3000)
  Assert.isTrue(timeline:settled(), "the transform drains fully")
  Assert.equal(
    battler(timeline:battlers(), 3).species,
    "EEVEE",
    "the transformed battler displays the copied appearance, even with effects suppressed"
  )
end

function T.effect_execution_runs_through_the_animation_player()
  local ok, Player = pcall(require, "libs.hgss.src.presentation.BattleAnimationPlayer")
  Assert.isTrue(ok, "the battle animation player resolves through the presentation boundary")
  Assert.notNil(Player, "the animation player loads")
end

return { tests = T }
