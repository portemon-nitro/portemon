-- FieldPoison owns the overworld poison step rule: a 0..3 step counter
-- that fires every fourth committed step, and the pure per-tick party
-- damage rule transcribed from the retail field system
-- (tmp/refs/pokeheartgold src/field/field_control.c FieldSystem_UpdatePoison
-- and src/script_pokemon_util.c ApplyPoisonStep/SurvivePoisoning).

local Assert = require("tests.support.Assert")
local FieldPoison = require("libs.hgss.src.field.FieldPoison")

local T = { metadata = { capabilities = {} }, tests = {} }

local function mon(fields)
  local record = {
    isEgg = false,
    friendship = 70,
    mood = 0,
    condition = { currentHp = 20, effects = {} },
  }
  for key, value in pairs(fields or {}) do
    record[key] = value
  end
  return record
end

local function poisoned(hp, key)
  return mon({
    condition = { currentHp = hp, effects = { { key = key or "poison", version = 1, state = {} } } },
  })
end

-- The 0..3 phase fires every fourth committed step and survives a
-- capture/restore round trip without shifting the cadence.
function T.tests.counter_fires_every_fourth_step_and_round_trips()
  local poison = FieldPoison.new()
  Assert.equal(poison:steps(), 0)
  Assert.isFalse(poison:noteStep())
  Assert.isFalse(poison:noteStep())
  Assert.isFalse(poison:noteStep())
  Assert.isTrue(poison:noteStep(), "the fourth committed step fires the poison tick")
  Assert.equal(poison:steps(), 0, "the counter wraps instead of growing")
  Assert.isFalse(poison:noteStep())
  poison:noteStep()
  local restored = FieldPoison.restore(poison:capture())
  Assert.equal(restored:steps(), 2)
  Assert.isFalse(restored:noteStep())
  Assert.isTrue(restored:noteStep(), "the restored counter keeps its phase")
end

-- One damage matrix for the pure per-tick rule: clean parties tick
-- quietly, poison (and toxic) drains 1 HP floored at 1 without fainting,
-- and eggs, fainted mons, and unpoisoned mons never take field damage.
-- A mon already at 1 HP still reports the survive outcome.
function T.tests.tick_reports_none_damage_or_survive_with_floor_at_one()
  local clean = FieldPoison.tickParty({ mon(), mon() })
  Assert.equal(clean.kind, "none")
  Assert.deepEqual(clean.updates, {}, "no party mutation without poison")

  local damage = FieldPoison.tickParty({ poisoned(20) })
  Assert.equal(damage.kind, "damage")
  Assert.equal(damage.updates[0].currentHp, 19)
  Assert.isFalse(damage.updates[0].cured, "status stays until 1 HP")
  Assert.isNil(damage.updates[0].effects, "unchanged effects ride along untouched")

  local floored = FieldPoison.tickParty({ poisoned(20), poisoned(2) })
  Assert.equal(floored.kind, "survive", "a mon reaching 1 HP reports the survive outcome")
  Assert.equal(floored.updates[0].currentHp, 19)
  Assert.equal(floored.updates[1].currentHp, 1, "damage floors at 1 HP, never faints")

  local already = FieldPoison.tickParty({ poisoned(1) })
  Assert.equal(already.kind, "survive", "a 1-HP poisoned mon still triggers the cure outcome")
  Assert.equal(already.updates[0].currentHp, 1)
  Assert.isTrue(already.updates[0].cured)

  local filtered = FieldPoison.tickParty({
    poisoned(20, "toxic"),
    mon({ isEgg = true, condition = poisoned(20).condition }),
    mon({ condition = { currentHp = 0, effects = { { key = "poison", version = 1, state = {} } } } }),
  })
  Assert.equal(filtered.kind, "damage")
  Assert.equal(filtered.updates[0].currentHp, 19, "badly poisoned drains like poison")
  Assert.isNil(filtered.updates[1], "eggs never take field damage")
  Assert.isNil(filtered.updates[2], "fainted mons never take field damage")
end

-- The survive cure mirrors SurvivePoisoning: poison and toxic records
-- clear together while other effects would ride along, low and mid tier
-- friendship drops by 5, high tier by 10 clamped at zero, and mood takes
-- the survived-poisoning modifier.
function T.tests.survive_cure_applies_retail_friendship_mood_and_status_clear()
  local outcome = FieldPoison.tickParty({ poisoned(2) })
  local update = assert(outcome.updates[0])
  Assert.isTrue(update.cured, "the 1-HP mon shakes its status like SurvivePoisoning")
  Assert.deepEqual(update.effects, {}, "poison and toxic records clear together")
  Assert.equal(update.friendship, 65, "low-tier friendship drops by 5")
  Assert.equal(update.mood, -50, "mood takes the survived-poisoning modifier")

  local cases = {
    { friendship = 150, want = 145, note = "mid-tier friendship drops by 5" },
    { friendship = 220, want = 210, note = "high-tier friendship drops by 10" },
    { friendship = 3, want = 0, note = "friendship clamps at zero" },
  }
  for _, case in ipairs(cases) do
    local record = mon({ friendship = case.friendship })
    record.condition = poisoned(2).condition
    local tick = FieldPoison.tickParty({ record })
    Assert.equal(tick.updates[0].friendship, case.want, case.note)
  end
end

return T
