-- Knockout experience follows the native recipient and rounding rules:
-- only conscious non-egg participants and share holders below the level
-- cap earn, shared awards split the integer stages, and trainer, trade,
-- foreign, and lucky-egg multipliers apply as ordered floors.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")

local T = {}

---@param behavior string missing owner under test
---@return table the loaded knockout-experience owner
local function experienceOwner(behavior)
  return SessionFixture.requirePresent("libs.battle.src.gen4.Experience", behavior)
end

---@param overrides table<string, unknown>|nil field replacements for this battler
---@return table battler record in recipient-selection order
local function battler(overrides)
  local record = {
    combatant = 1,
    participated = true,
    fainted = false,
    isEgg = false,
    level = 9,
    expShare = false,
    traded = false,
    foreign = false,
    luckyEgg = false,
  }
  if overrides ~= nil then
    for key, value in pairs(overrides) do
      record[key] = value
    end
  end
  return record
end

---@param overrides table<string, unknown>|nil field replacements for this knockout
---@return table knockout facts shared by every recipient
local function knockout(overrides)
  local facts = { baseYield = 64, level = 5, trainerBattle = false }
  if overrides ~= nil then
    for key, value in pairs(overrides) do
      facts[key] = value
    end
  end
  return facts
end

-- Only eligible recipients earn: fainted battlers, eggs, level-100 mons,
-- and idle non-holders are excluded, while conscious participants and
-- idle share holders below the cap are named with their kind.
function T.only_eligible_recipients_earn_from_a_knockout()
  local Experience = experienceOwner("knockout experience owns recipient selection and award stages")
  Assert.isTrue(type(Experience.recipients) == "function", "the experience owner selects recipients")
  Assert.isTrue(type(Experience.calculate) == "function", "the experience owner stages awards")
  local selected = Experience.recipients({
    battlers = {
      battler({ combatant = 1 }),
      battler({ combatant = 2, fainted = true }),
      battler({ combatant = 3, isEgg = true }),
      battler({ combatant = 4, level = 100 }),
      battler({ combatant = 5, participated = false }),
      battler({ combatant = 6, participated = false, expShare = true }),
    },
    knockout = knockout(),
  })
  local kinds = {}
  for _, recipient in ipairs(selected) do
    kinds[recipient.combatant] = recipient.kind
  end
  Assert.equal(kinds[1], "battler", "a conscious participant earns a battler share")
  Assert.isNil(kinds[2], "a fainted battler earns nothing")
  Assert.isNil(kinds[3], "an egg earns nothing")
  Assert.isNil(kinds[4], "a level-capped battler earns no experience")
  Assert.isNil(kinds[5], "an idle battler without a share earns nothing")
  Assert.equal(kinds[6], "share", "an idle share holder earns a share portion")
  Assert.equal(#selected, 2, "exactly the participant and the holder are named")
end

-- Wild and trainer awards follow staged integer order: the base stage
-- floors yield times fainted level over seven, shares split the staged
-- total, and each per-recipient multiplier floors in turn. Base yield 64
-- at level 5 opens at 45; the trainer battle lifts it to 67; a
-- same-language trade lifts that to 100; a foreign original takes
-- seventeen tenths of the trainer award instead of the trade bonus for
-- 113; and the lucky egg applies before the trainer and foreign awards
-- for 170.
function T.trainer_trade_foreign_and_lucky_egg_stage_in_order()
  local Experience = experienceOwner("knockout experience owns recipient selection and award stages")
  local plain = Experience.calculate(knockout(), { kind = "battler", battlers = 1, holders = 0 })
  Assert.equal(plain, 45, "the wild base stage floors yield times level over seven")
  local trainer = Experience.calculate(knockout({ trainerBattle = true }), { kind = "battler", battlers = 1, holders = 0 })
  Assert.equal(trainer, 67, "the trainer stage floors the base by three halves")
  local traded = Experience.calculate(
    knockout({ trainerBattle = true }),
    { kind = "battler", battlers = 1, holders = 0, traded = true }
  )
  Assert.equal(traded, 100, "the trade stage floors the trainer award by three halves")
  local foreign = Experience.calculate(
    knockout({ trainerBattle = true }),
    { kind = "battler", battlers = 1, holders = 0, traded = true, foreign = true }
  )
  Assert.equal(foreign, 113, "the foreign stage replaces the trade bonus with seventeen tenths")
  local lucky = Experience.calculate(
    knockout({ trainerBattle = true }),
    { kind = "battler", battlers = 1, holders = 0, traded = true, foreign = true, luckyEgg = true }
  )
  Assert.equal(lucky, 170, "the egg stage applies before the trainer and foreign awards")
end

-- Shared awards split the staged total before per-recipient multipliers:
-- two battlers halve the wild 45 to 22 each, while one battler beside one
-- holder divides the halved trainer award into 33 and 33, and a second
-- holder halves the holder half to 16. Six battlers prove the split lands
-- first: the staged 45 splits to 7 before the trainer lift to 10, where
-- a trainer-first order would read 11. Tiny totals prove the minimum-one
-- floors: a base yield of one at level one stages zero yet still awards
-- one to each side of the split.
function T.shared_awards_split_the_staged_total()
  local Experience = experienceOwner("knockout experience owns recipient selection and award stages")
  local split = Experience.calculate(knockout(), { kind = "battler", battlers = 2, holders = 0 })
  Assert.equal(split, 22, "two battlers halve the wild award")
  local halved = Experience.calculate(
    knockout({ trainerBattle = true }),
    { kind = "battler", battlers = 1, holders = 1 }
  )
  Assert.equal(halved, 33, "a battler beside a holder keeps half the staged award before the trainer lift")
  local holder = Experience.calculate(
    knockout({ trainerBattle = true }),
    { kind = "share", battlers = 1, holders = 1 }
  )
  Assert.equal(holder, 33, "a lone holder takes the other half before the trainer lift")
  local paired = Experience.calculate(
    knockout({ trainerBattle = true }),
    { kind = "share", battlers = 1, holders = 2 }
  )
  Assert.equal(paired, 16, "two holders split the holder half evenly before the trainer lift")
  local crowded = Experience.calculate(
    knockout({ trainerBattle = true }),
    { kind = "battler", battlers = 6, holders = 0 }
  )
  Assert.equal(crowded, 10, "six battlers split the staged total before the trainer lift")
  local tiny = knockout({ baseYield = 1, level = 1 })
  local tinyBattler = Experience.calculate(tiny, { kind = "battler", battlers = 1, holders = 1 })
  Assert.equal(tinyBattler, 1, "a zero staged total still awards the minimum one to battlers")
  local tinyHolder = Experience.calculate(tiny, { kind = "share", battlers = 1, holders = 1 })
  Assert.equal(tinyHolder, 1, "a zero staged total still awards the minimum one to holders")
  local egged = Experience.calculate(
    knockout({ trainerBattle = true }),
    { kind = "share", battlers = 1, holders = 2, luckyEgg = true }
  )
  Assert.equal(egged, 24, "a holder egg applies to the split share before the trainer lift")
end

-- The owner exposes exactly its two operations, so capture-time awards
-- have no surface to attach to: experience is a knockout settlement only.
function T.experience_exposes_only_recipients_and_calculate()
  local Experience = experienceOwner("knockout experience owns recipient selection and award stages")
  Assert.keySet(Experience, "calculate,recipients", "experience carries exactly its two operations")
end

-- Malformed inputs fail before publication: unknown recipient kinds,
-- empty battler shares, and negative yields never stage an award.
function T.malformed_inputs_fail_before_publication()
  local Experience = experienceOwner("knockout experience owns recipient selection and award stages")
  Assert.throws(function()
    Experience.calculate(knockout(), { kind = "cheerleader", battlers = 1, holders = 0 })
  end, "an unknown recipient kind fails")
  Assert.throws(function()
    Experience.calculate(knockout(), { kind = "battler", battlers = 0, holders = 0 })
  end, "a battler share across zero battlers fails")
  Assert.throws(function()
    Experience.calculate(knockout({ baseYield = -1 }), { kind = "battler", battlers = 1, holders = 0 })
  end, "a negative base yield fails")
  Assert.throws(function()
    Experience.recipients({ battlers = { { combatant = 0 } } })
  end, "a battler without an identity fails")
end

return { tests = T }
