-- Party-screen presentation semantics: the HP bar zone and the persistent
-- status key/label consumed by the party view and renderer. The zone
-- replicates the source 48-pixel bar (pret/pokeheartgold@0985e8718d,
-- src/unk_0208805C.c CalculateHpBarPixelsLength/HpBar_GetColorIdx, with the
-- full-HP fast path of CalculateHpBarColor): pixels hp*48/maxHp (at least
-- one while HP remains), green above half the bar, yellow above a fifth,
-- red otherwise, fainted at zero. The status key follows the source icon
-- order (include/party_menu.h PartyMonStatusIconId with the
-- include/constants/pokemon.h MON_STATUS_* masks): no HP is fainted, then
-- sleep, poison (including toxic), burn, freeze, paralysis. Labels reuse
-- the source icon codes. Pure module: no love, no I/O.

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
---@param statusKey "ok"|"sleep"|"poison"|"burn"|"freeze"|"paralysis"|"faint"
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
      or statusKey == "faint",
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

local STATUS_SLEEP_MASK = 0x7
local STATUS_POISON_MASK = 0x8
local STATUS_BURN_MASK = 0x10
local STATUS_FREEZE_MASK = 0x20
local STATUS_PARALYSIS_MASK = 0x40
local STATUS_TOXIC_MASK = 0x80

---@param statusBits integer
---@param bit integer
---@return boolean
local function hasBit(statusBits, bit)
  return math.floor(statusBits / bit) % 2 == 1
end

---@param statusBits integer
---@param currentHp integer
---@return "ok"|"sleep"|"poison"|"burn"|"freeze"|"paralysis"|"faint"
function PartyScreenTheme.statusKey(statusBits, currentHp)
  assert(
    type(statusBits) == "number" and statusBits % 1 == 0 and statusBits >= 0,
    "the status key requires non-negative integer status bits"
  )
  assert(
    type(currentHp) == "number" and currentHp % 1 == 0 and currentHp >= 0,
    "the status key requires non-negative integer current HP"
  )
  if currentHp == 0 then
    return "faint"
  end
  if statusBits % 8 ~= 0 then
    assert(STATUS_SLEEP_MASK == 0x7, "sleep occupies the low three bits")
    return "sleep"
  end
  if hasBit(statusBits, STATUS_POISON_MASK) or hasBit(statusBits, STATUS_TOXIC_MASK) then
    return "poison"
  end
  if hasBit(statusBits, STATUS_BURN_MASK) then
    return "burn"
  end
  if hasBit(statusBits, STATUS_FREEZE_MASK) then
    return "freeze"
  end
  if hasBit(statusBits, STATUS_PARALYSIS_MASK) then
    return "paralysis"
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
      or key == "faint",
    "unknown party status key " .. key
  )
  return STATUS_LABELS[key]
end

return PartyScreenTheme
