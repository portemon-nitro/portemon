-- Party-screen presentation semantics: the HP bar zone and the persistent
-- status key/label consumed by the party view and renderer. The zone
-- replicates the source 48-pixel bar (pret/pokeheartgold@0985e8718d,
-- src/unk_0208805C.c CalculateHpBarPixelsLength/HpBar_GetColorIdx, with the
-- full-HP fast path of CalculateHpBarColor): pixels hp*48/maxHp (at least
-- one while HP remains), green above half the bar, yellow above a fifth,
-- red otherwise, fainted at zero. The status key projects the semantic
-- condition records to the source icon order (include/party_menu.h
-- PartyMonStatusIconId over the native persistent conditions): no HP is
-- fainted, then sleep, poison (including toxic), burn, freeze, paralysis.
-- Labels reuse the source icon codes. Pure module: no love, no I/O.

---@class PartyScreenTheme
local PartyScreenTheme = {}

PartyScreenTheme.HP_BAR_PIXELS = 48

-- Shared fill-length computation for the 48-pixel HP bar: quantized
-- floor pixels with a one-pixel minimum while HP remains. Color tests
-- elsewhere use this quantized length, never a floating fraction.
---@param currentHp integer
---@param maxHp integer
---@return integer
function PartyScreenTheme.fillLength(currentHp, maxHp)
  assert(
    type(currentHp) == "number" and currentHp % 1 == 0 and currentHp >= 0,
    "the fill length requires a non-negative integer current HP"
  )
  assert(type(maxHp) == "number" and maxHp % 1 == 0 and maxHp > 0, "the fill length requires a positive max HP")
  assert(currentHp <= maxHp, "current HP cannot exceed max HP")
  local pixels = math.floor((currentHp * PartyScreenTheme.HP_BAR_PIXELS) / maxHp)
  if pixels == 0 and currentHp ~= 0 then
    pixels = 1
  end
  return pixels
end

---@param currentHp integer
---@param maxHp integer
---@return "full"|"green"|"yellow"|"red"|"fainted"
function PartyScreenTheme.hpZone(currentHp, maxHp)
  assert(
    type(currentHp) == "number" and currentHp % 1 == 0 and currentHp >= 0,
    "the HP zone requires a non-negative integer current HP"
  )
  assert(type(maxHp) == "number" and maxHp % 1 == 0 and maxHp > 0, "the HP zone requires a positive integer max HP")
  assert(currentHp <= maxHp, "current HP cannot exceed max HP")
  if currentHp == maxHp then
    return "full"
  end
  local pixels = PartyScreenTheme.fillLength(currentHp, maxHp)
  if pixels * 2 > PartyScreenTheme.HP_BAR_PIXELS then
    return "green"
  end
  if pixels * 5 > PartyScreenTheme.HP_BAR_PIXELS then
    return "yellow"
  end
  if pixels > 0 then
    return "red"
  end
  return "fainted"
end

-- Source icon animation sequence for one slot: fainted selects 0 and
-- any persistent status selects 5; healthy mons follow their HP zone
-- (full 1, green 2, yellow 3, red 4). The controller preserves phase
-- within a sequence and resets it only when the sequence changes.
---@param zone "full"|"green"|"yellow"|"red"|"fainted"
---@param statusKey "ok"|"sleep"|"poison"|"burn"|"freeze"|"paralysis"|"faint"|"custom"
---@return integer
function PartyScreenTheme.iconSequence(zone, statusKey)
  assert(
    zone == "full" or zone == "green" or zone == "yellow" or zone == "red" or zone == "fainted",
    "unknown HP zone " .. tostring(zone)
  )
  assert(
    statusKey == "ok"
      or statusKey == "sleep"
      or statusKey == "poison"
      or statusKey == "burn"
      or statusKey == "freeze"
      or statusKey == "paralysis"
      or statusKey == "faint"
      or statusKey == "custom",
    "unknown status key " .. tostring(statusKey)
  )
  if zone == "fainted" then
    return 0
  end
  if statusKey ~= "ok" then
    return 5
  end
  if zone == "full" then
    return 1
  end
  if zone == "green" then
    return 2
  end
  if zone == "yellow" then
    return 3
  end
  return 4
end

local STATUS_SLEEP = "sleep"
local STATUS_POISON = "poison"
local STATUS_TOXIC = "toxic"
local STATUS_BURN = "burn"
local STATUS_FREEZE = "freeze"
local STATUS_PARALYSIS = "paralysis"

---@param effects table<integer, table<string, unknown>>
---@param key string
---@return boolean
local function hasEffect(effects, key)
  for _, effect in ipairs(effects) do
    if type(effect) == "table" and effect.key == key then
      return true
    end
  end
  return false
end

-- Projects the semantic condition to the source status icon key. Native
-- visual precedence applies (faint, sleep, poison including toxic, burn,
-- freeze, paralysis); a custom condition resolves to an explicit
-- presentation key instead of borrowing a native icon.
---@param condition { currentHp: integer, effects: table<integer, table<string, unknown>> }
---@return "ok"|"sleep"|"poison"|"burn"|"freeze"|"paralysis"|"faint"|"custom"
function PartyScreenTheme.statusKey(condition)
  assert(type(condition) == "table", "the status key requires the mon condition")
  local currentHp = assert(condition.currentHp) --[[@as integer]]
  assert(
    type(currentHp) == "number" and currentHp % 1 == 0 and currentHp >= 0,
    "the status key requires non-negative integer current HP"
  )
  local effects = assert(condition.effects) --[[@as table<integer, table<string, unknown>>]]
  assert(type(effects) == "table", "the status key requires the condition effects")
  if currentHp == 0 then
    return "faint"
  end
  if hasEffect(effects, STATUS_SLEEP) then
    return "sleep"
  end
  if hasEffect(effects, STATUS_POISON) or hasEffect(effects, STATUS_TOXIC) then
    return "poison"
  end
  if hasEffect(effects, STATUS_BURN) then
    return "burn"
  end
  if hasEffect(effects, STATUS_FREEZE) then
    return "freeze"
  end
  if hasEffect(effects, STATUS_PARALYSIS) then
    return "paralysis"
  end
  if #effects > 0 then
    return "custom"
  end
  return "ok"
end

local STATUS_LABELS = {
  poison = "PSN",
  burn = "BRN",
  freeze = "FRZ",
  paralysis = "PRZ",
  sleep = "SLP",
  faint = "FNT",
}

---@param key string
---@return string?
function PartyScreenTheme.statusLabel(key)
  assert(type(key) == "string", "the status label requires a status key")
  assert(
    key == "ok"
      or key == "sleep"
      or key == "poison"
      or key == "burn"
      or key == "freeze"
      or key == "paralysis"
      or key == "faint"
      or key == "custom",
    "unknown party status key " .. key
  )
  return STATUS_LABELS[key]
end

return PartyScreenTheme
