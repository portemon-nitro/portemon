-- Single canonical battle-stat projection for Generation-IV mons
-- (pret/pokeheartgold@0985e8718d src/pokemon.c CalcMonStats): level from
-- the growth curve, stats from the exact stat formula, one health point
-- for the single-health species, and source health adjustment across a
-- recalculated maximum. This module composes the existing
-- Experience/Stats/Personality owners and adds no formula of its own; it
-- only owns the derivation so every consumer (live party reads, battle
-- entry, explicit reload points) shares one interpretation. Computing a
-- projection never publishes it: callers decide when materialized battle
-- facts move, so effort awards never rewrite live stats by themselves.

local Experience = require("libs.mons.src.gen4.Experience")
local Personality = require("libs.mons.src.gen4.Personality")
local Stats = require("libs.mons.src.gen4.Stats")

---@class MonStats
local MonStats = {}

---@alias MonStats.Facts { level: integer, maxHp: integer, attack: integer, defense: integer, speed: integer, specialAttack: integer, specialDefense: integer }

-- Derives level and battle stats from the authoritative record fields.
-- The mon must already be valid; only its species, form, personality,
-- experience, individual values, and effort values are read.
---@param mon { species: string, form: integer, personality: integer, experience: integer, ivs: table<string, integer>, evs: table<string, integer> }
---@param catalog MonCatalog
---@return MonStats.Facts
function MonStats.derive(mon, catalog)
  assert(type(mon) == "table", "stat projection requires a mon record")
  assert(catalog ~= nil, "stat projection requires a catalog")
  local species = catalog:species(mon.species)
  local level = Experience.level(catalog:growthCurve(species.growthCurve), mon.experience)
  local form = catalog:form(mon.species, mon.form)
  local stats = Stats.calculate(form.baseStats, mon.ivs, mon.evs, level, Personality.nature(mon.personality))
  local maxHp = stats.hp
  if mon.species == "SHEDINJA" then
    maxHp = 1
  end
  return {
    level = level,
    maxHp = maxHp,
    attack = stats.attack,
    defense = stats.defense,
    speed = stats.speed,
    specialAttack = stats.specialAttack,
    specialDefense = stats.specialDefense,
  }
end

-- Source maximum-health adjustment for a recalculated mon
-- (pret/pokeheartgold@0985e8718d src/pokemon.c CalcMonStats tail): a
-- fainted mon keeps zero health; a living mon keeps its damage by gaining
-- the maximum change, clamped down when the maximum shrinks.
---@param oldMaxHp integer
---@param newMaxHp integer
---@param currentHp integer
---@return integer
function MonStats.adjustHpForMaxChange(oldMaxHp, newMaxHp, currentHp)
  assert(
    type(oldMaxHp) == "number" and oldMaxHp % 1 == 0 and oldMaxHp >= 1,
    "health adjustment needs the previous maximum"
  )
  assert(
    type(newMaxHp) == "number" and newMaxHp % 1 == 0 and newMaxHp >= 1,
    "health adjustment needs the recalculated maximum"
  )
  assert(
    type(currentHp) == "number" and currentHp % 1 == 0 and currentHp >= 0 and currentHp <= oldMaxHp,
    "health adjustment needs the current health within the previous maximum"
  )
  if currentHp == 0 then
    return 0
  end
  local adjusted = currentHp + newMaxHp - oldMaxHp
  if adjusted > newMaxHp then
    return newMaxHp
  end
  if adjusted < 0 then
    return 0
  end
  return adjusted
end

return MonStats
