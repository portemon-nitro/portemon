-- Pure source-shaped held-item form effects on a copied mon
-- (pret/pokeheartgold src/pokemon.c BoxMon_UpdateArceusForm and
-- BoxMon_UpdateGiratinaForm): an Arceus plate selects the plate type's form
-- behind the Multitype gate, the griseous orb selects the origin form, and
-- any other held item restores the base form. A form change recomputes the
-- PID-selected ability for the new form and clamps current HP to the
-- service-derived maximum; the semantic condition records, personality,
-- experience and every other field survive. Stat derivation stays with the
-- mon service: the caller supplies it, and gated-out mons never touch it.

local Personality = require("libs.mons.src.gen4.Personality")

---@class HeldItemFormPolicy
local HeldItemFormPolicy = {}

HeldItemFormPolicy.ARCEUS = "ARCEUS"
HeldItemFormPolicy.GIRATINA = "GIRATINA"
HeldItemFormPolicy.MULTITYPE = "MULTITYPE"

-- Plate native identities in ItemSources order to Gen-IV type identities
-- (include/constants/pokemon.h), which are the Arceus form values behind
-- GetArceusTypeByHeldItemEffect: flame 10, splash 11, zap 13, meadow 12,
-- icicle 15, fist 1, toxic 3, earth 4, sky 2, mind 14, insect 6, stone 5,
-- spooky 7, draco 16, dread 17, iron 8.
local PLATE_FORMS = {
  [298] = 10,
  [299] = 11,
  [300] = 13,
  [301] = 12,
  [302] = 15,
  [303] = 1,
  [304] = 3,
  [305] = 4,
  [306] = 2,
  [307] = 14,
  [308] = 6,
  [309] = 5,
  [310] = 7,
  [311] = 16,
  [312] = 17,
  [313] = 8,
}

---@generic T
---@param value T
---@return T
local function copyValue(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[key] = copyValue(item)
  end
  return out
end

-- Applies the held-item form rule for the already-assigned held item. The
-- input record is never mutated; the result is a fresh record. Gated-out
-- mons return an unchanged copy without consulting the service.
---@param mon table<string, unknown>
---@param itemDef table<string, unknown>
---@param mons table<string, unknown>|nil
---@return table<string, unknown>
function HeldItemFormPolicy.apply(mon, itemDef, mons)
  assert(type(mon) == "table", "form policy requires a mon record")
  assert(type(itemDef) == "table", "form policy requires an item definition")
  assert(type(itemDef.heldFormEffect) == "string", "form policy requires the item held-item form effect")
  local targetForm = nil
  if mon.species == HeldItemFormPolicy.ARCEUS and mon.ability == HeldItemFormPolicy.MULTITYPE then
    if itemDef.heldFormEffect == "arceus_plate" then
      local form = PLATE_FORMS[itemDef.nativeId]
      assert(form ~= nil, "plate identity must map to an Arceus form")
      targetForm = form
    else
      targetForm = 0
    end
  elseif mon.species == HeldItemFormPolicy.GIRATINA then
    if itemDef.heldFormEffect == "griseous_orb" then
      targetForm = 1
    else
      targetForm = 0
    end
  end
  if targetForm == nil or targetForm == mon.form then
    return copyValue(mon)
  end
  assert(mons ~= nil, "a form change requires the mon service derivation")
  assert(type(mon.condition) == "table", "form policy requires the mon condition record")
  local candidate = copyValue(mon)
  candidate.form = targetForm
  local abilities = mons:catalog():form(candidate.species, targetForm).abilities
  assert(type(abilities) == "table", "the target form must list its abilities")
  if #abilities == 1 then
    candidate.ability = abilities[1]
  elseif #abilities == 2 then
    candidate.ability = abilities[Personality.abilitySlot(2, candidate.personality)]
  end
  local maxHp = mons:derive(candidate).maxHp
  assert(type(maxHp) == "number", "derivation must report the new maximum HP")
  local kept = assert(candidate.condition) --[[@as table<string, unknown>]]
  candidate.condition = {
    currentHp = math.min(kept.currentHp --[[@as integer]], maxHp),
    effects = kept.effects,
  }
  return candidate
end

return HeldItemFormPolicy
