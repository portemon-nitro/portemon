-- Pure incremental mon progression. Native anchor:
-- pret/pokeheartgold src/battle/battle_command.c Task_GetExp (level-up
-- detection per crossed level, learnset traversal in source order, learned
-- moves reset to base power points) composed with the existing
-- Experience/MonStats/learnset owners. This module owns caller-neutral mon
-- arithmetic only: it advances experience, reports crossed levels with
-- ordered learning chances and the source maximum-health pair, and applies
-- single learning decisions. It never selects recipients, never touches
-- live party state, and never prompts; battle and out-of-battle callers
-- share the identical arithmetic.

local Experience = require("libs.mons.src.gen4.Experience")
local MonStats = require("libs.mons.src.gen4.MonStats")
local Moves = require("libs.mons.src.gen4.Moves")
local Stats = require("libs.mons.src.gen4.Stats")

---@class LevelProgressionOpportunity
---@field level integer crossed level teaching the move
---@field move string move key taught at that level

---@class LevelProgressionResult
---@field mon table<string, unknown> detached mon carrying the awarded experience
---@field crossedLevels integer[] levels crossed in order
---@field learningOpportunities LevelProgressionOpportunity[] ordered new learning chances
---@field maxHpBefore integer recalculated maximum before the award
---@field maxHpAfter integer recalculated maximum after the award

---@class LevelProgression
local LevelProgression = {}

---@param value unknown
---@return unknown
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

---@param mon table<string, unknown>
local function checkMon(mon)
  assert(type(mon) == "table", "progression awards read a mon record")
  assert(type(mon.species) == "string", "progression awards read the species key")
  assert(type(mon.form) == "number", "progression awards read the form index")
  assert(
    type(mon.experience) == "number" and mon.experience % 1 == 0 and mon.experience >= 0,
    "progression awards read non-negative integer experience"
  )
  assert(type(mon.moves) == "table", "progression awards read the move set")
end

---@param catalog table<string, unknown>
local function checkCatalog(catalog)
  assert(catalog ~= nil, "progression needs a catalog for curves, stats, and base power points")
end

---@param gain unknown
local function checkGain(gain)
  assert(type(gain) == "number" and gain % 1 == 0 and gain >= 0, "progression gains must be non-negative integers")
end

---@param mon table<string, unknown>
---@param catalog table<string, unknown>
---@return integer[]
local function growthCurve(mon, catalog)
  local species = catalog:species(mon.species)
  return catalog:growthCurve(species.growthCurve)
end

---@param mon table<string, unknown>
---@param move unknown
---@return boolean
local function knowsMove(mon, move)
  for _, entry in ipairs(mon.moves) do
    if type(entry) == "table" and entry.move == move then
      return true
    end
  end
  return false
end

--- Advances experience by a non-negative gain and reports the crossed
--- levels with ordered learning chances. Experience saturates at the
--- level-100 entry so the result stays a valid record; current health is
--- preserved, never healed. Learning chances cover crossed levels only, in
--- learnset order, skipping moves the mon already knows and repeated
--- entries of the same move. The input is never mutated.
---@param mon table<string, unknown>
---@param gain integer
---@param catalog table<string, unknown>
---@return LevelProgressionResult
function LevelProgression.award(mon, gain, catalog)
  checkMon(mon)
  checkGain(gain)
  checkCatalog(catalog)
  local curve = growthCurve(mon, catalog)
  local oldLevel = Experience.level(curve, mon.experience)
  local ceiling = curve[Stats.MAX_LEVEL]
  local rested = mon.experience + gain
  if rested > ceiling then
    rested = ceiling
  end
  local updated = copyValue(mon)
  assert(type(updated) == "table", "progression copies the mon record")
  updated.experience = rested
  local newLevel = Experience.level(curve, rested)
  local crossedLevels = {}
  for level = oldLevel + 1, newLevel do
    crossedLevels[#crossedLevels + 1] = level
  end
  local maxHpBefore = MonStats.derive(mon, catalog).maxHp
  local maxHpAfter = MonStats.derive(updated, catalog).maxHp
  local learningOpportunities = {}
  if newLevel > oldLevel then
    local form = catalog:form(mon.species, mon.form)
    assert(type(form.levelUpMoves) == "table", "progression reads the form learnset")
    local queued = {}
    for _, entry in ipairs(form.levelUpMoves) do
      assert(type(entry) == "table", "learnset entries are records")
      if entry.level > newLevel then
        break
      end
      if entry.level > oldLevel and not knowsMove(updated, entry.move) and not queued[entry.move] then
        queued[entry.move] = true
        learningOpportunities[#learningOpportunities + 1] = { level = entry.level, move = entry.move }
      end
    end
  end
  return {
    mon = updated,
    crossedLevels = crossedLevels,
    learningOpportunities = learningOpportunities,
    maxHpBefore = maxHpBefore,
    maxHpAfter = maxHpAfter,
  }
end

--- Fills the first free slot with a base-point move. A full set refuses
--- the fill and keeps every move. The input is never mutated.
---@param mon table<string, unknown>
---@param move string
---@param catalog table<string, unknown>
---@return { applied: boolean, mon: table<string, unknown> }
function LevelProgression.learn(mon, move, catalog)
  checkMon(mon)
  assert(type(move) == "string" and move ~= "", "learning names a move key")
  checkCatalog(catalog)
  local updated = copyValue(mon)
  assert(type(updated) == "table", "learning copies the mon record")
  if #updated.moves >= Moves.MAX_SLOTS then
    return { applied = false, mon = updated }
  end
  local definition = catalog:move(move)
  updated.moves[#updated.moves + 1] = { move = move, pp = definition.basePp, ppUps = 0 }
  return { applied = true, mon = updated }
end

--- Replaces the zero-based slot with a base-point move, leaving every
--- other slot untouched. The input is never mutated.
---@param mon table<string, unknown>
---@param slot0 integer
---@param move string
---@param catalog table<string, unknown>
---@return table<string, unknown>
function LevelProgression.replace(mon, slot0, move, catalog)
  checkMon(mon)
  assert(
    type(slot0) == "number" and slot0 % 1 == 0 and slot0 >= 0 and slot0 < #mon.moves,
    "replacement names a held zero-based move slot"
  )
  assert(type(move) == "string" and move ~= "", "replacement names a move key")
  checkCatalog(catalog)
  local updated = copyValue(mon)
  assert(type(updated) == "table", "replacement copies the mon record")
  local definition = catalog:move(move)
  updated.moves[slot0 + 1] = { move = move, pp = definition.basePp, ppUps = 0 }
  return updated
end

--- Declines a learning chance without touching the move set.
---@param mon table<string, unknown>
---@param move string
---@return { declined: string, mon: table<string, unknown> }
function LevelProgression.decline(mon, move)
  checkMon(mon)
  assert(type(move) == "string" and move ~= "", "a decline names the refused move")
  return { declined = move, mon = copyValue(mon) }
end

return LevelProgression
