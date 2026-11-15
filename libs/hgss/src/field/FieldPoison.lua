-- The overworld poison step rule: a 0..3 step counter that fires every
-- fourth committed step, and the pure per-tick party damage rule. Both
-- transcribe the retail field system (tmp/refs/pokeheartgold
-- src/field/field_control.c FieldSystem_UpdatePoison and
-- src/script_pokemon_util.c ApplyPoisonStep/SurvivePoisoning): each tick
-- deducts 1 HP from every poisoned non-egg conscious mon floored at 1,
-- mons ending at 1 HP take the HEAL_FIELD_PSN friendship tier penalty and
-- the SURVIVED_PSN mood modifier and shake their status, and the tick
-- reports survive when any mon ends at 1 HP, damage when poison drained
-- without reaching 1, or none. Pure domain module: no love dependency.

---@class FieldPoison
---@field private _steps integer poison steps since the last tick, 0..3
local FieldPoison = {}
FieldPoison.__index = FieldPoison

-- The retail toxic distinction (bad poison) drains identically in the
-- field; only the battle icon treats it separately.
local POISON_KEYS = { poison = true, toxic = true }

local FRIENDSHIP_TIER_HI_MIN = 200
local FRIENDSHIP_MAX = 255
local MOOD_MIN = -127
local MOOD_MAX = 127
local SURVIVED_PSN_MOOD_MODIFIER = -50

---@return FieldPoison
function FieldPoison.new()
  return setmetatable({ _steps = 0 }, FieldPoison)
end

---@param record unknown persisted { steps } record or nil for a fresh counter
---@return FieldPoison
function FieldPoison.restore(record)
  if record == nil then
    return FieldPoison.new()
  end
  assert(type(record) == "table", "poison counter restore requires a record")
  local steps = record.steps
  assert(
    type(steps) == "number" and steps % 1 == 0 and steps >= 0 and steps <= 3,
    "poison counter restore requires steps in 0..3"
  )
  return setmetatable({ _steps = steps }, FieldPoison)
end

---@return integer steps since the last tick, 0..3
function FieldPoison:steps()
  return self._steps
end

-- Notes one committed step: the counter advances mod 4 like the native
-- poison step counter, firing exactly when it wraps.
---@return boolean true on the fourth step, when the damage tick runs
function FieldPoison:noteStep()
  self._steps = (self._steps + 1) % 4
  return self._steps == 0
end

---@return { steps: integer } detached persistable counter
function FieldPoison:capture()
  return { steps = self._steps }
end

---@param effects table[] condition effect records
---@return boolean
local function isPoisonedEffects(effects)
  if type(effects) ~= "table" then
    return false
  end
  for _, effect in ipairs(effects) do
    if type(effect) == "table" and POISON_KEYS[effect.key] == true then
      return true
    end
  end
  return false
end

---@param effects table[] condition effect records
---@return table[] the records without poison/toxic, preserving order
local function curedEffects(effects)
  local kept = {}
  for _, effect in ipairs(effects) do
    if not (type(effect) == "table" and POISON_KEYS[effect.key] == true) then
      kept[#kept + 1] = effect
    end
  end
  return kept
end

---@param friendship integer
---@return integer the HEAL_FIELD_PSN tier penalty, already negative
local function healFieldPsnFriendshipMod(friendship)
  -- Low and mid tiers share the -5 penalty; only high friendship drops 10.
  if friendship >= FRIENDSHIP_TIER_HI_MIN then
    return -10
  end
  return -5
end

---@param mon table<string, unknown> plain party mon record
---@return boolean true for a damageable poisoned mon: no egg, conscious, poisoned
local function isDamageable(mon)
  if type(mon) ~= "table" or mon.isEgg == true then
    return false
  end
  local condition = mon.condition
  if type(condition) ~= "table" then
    return false
  end
  if type(condition.currentHp) ~= "number" or condition.currentHp <= 0 then
    return false
  end
  return isPoisonedEffects(condition.effects)
end

-- Runs one damage tick over plain party mon records (1-based array, slot
-- number = index - 1). Pure: input records are never mutated. Updates are
-- keyed by zero-based slot and carry the full replacement condition
-- fields plus the friendship/mood/cured facts the caller stages.
---@param party table[] plain party mon records
---@return { kind: "none"|"damage"|"survive", updates: table<integer, table<string, unknown>> }
function FieldPoison.tickParty(party)
  assert(type(party) == "table", "poison tick requires the party records")
  local updates = {}
  local kind = "none"
  for index, mon in ipairs(party) do
    if isDamageable(mon) then
      local slot = index - 1
      local condition = assert(mon.condition)
      local hp = condition.currentHp
      if hp > 1 then
        hp = hp - 1
      end
      if kind == "none" then
        kind = "damage"
      end
      if hp == 1 then
        kind = "survive"
        local friendship = type(mon.friendship) == "number" and mon.friendship or 0
        local mood = type(mon.mood) == "number" and mon.mood or 0
        updates[slot] = {
          currentHp = hp,
          friendship = math.max(0, math.min(FRIENDSHIP_MAX, friendship + healFieldPsnFriendshipMod(friendship))),
          mood = math.max(MOOD_MIN, math.min(MOOD_MAX, mood + SURVIVED_PSN_MOOD_MODIFIER)),
          cured = true,
          effects = curedEffects(condition.effects),
        }
      else
        updates[slot] = { currentHp = hp, cured = false }
      end
    end
  end
  return { kind = kind, updates = updates }
end

return FieldPoison
