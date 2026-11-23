-- Reusable out-of-battle Rare Candy planning through the shared owners.
-- One use raises exactly one level through the shared progression
-- arithmetic and stages the retail health result (UseItemOnMonInParty:
-- CalcMonLevelAndStats, then RestoreMonHPBy for a mon that was fainted).
-- The plan reports the six derived stats before and after for the stat
-- windows and the moves the new level offers; it never decides learning,
-- evolution, or consumption. Planning never mutates its input.

local ItemErrors = require("libs.items.src.errors")
local Experience = require("libs.mons.src.gen4.Experience")
local LevelProgression = require("libs.mons.src.gen4.LevelProgression")
local MonStats = require("libs.mons.src.gen4.MonStats")
local Stats = require("libs.mons.src.gen4.Stats")

---@class ProgressionItemUse
local ProgressionItemUse = {}

local LEVEL_ITEM = "RARE_CANDY"

---@param facts MonStats.Facts
---@return table<string, integer>
local function statWindow(facts)
  return {
    maxHp = facts.maxHp,
    attack = facts.attack,
    defense = facts.defense,
    specialAttack = facts.specialAttack,
    specialDefense = facts.specialDefense,
    speed = facts.speed,
  }
end

-- Staged health. A living mon keeps its damage across the recalculated
-- maximum; a fainted mon stays at zero there and RestoreMonHPBy then adds
-- the maximum change (one health point when the maximum is one), capped at
-- the new maximum.
---@param currentHp integer
---@param oldMaxHp integer
---@param newMaxHp integer
---@return integer
local function stagedHp(currentHp, oldMaxHp, newMaxHp)
  if currentHp ~= 0 then
    return MonStats.adjustHpForMaxChange(oldMaxHp, newMaxHp, currentHp)
  end
  if newMaxHp == 1 then
    return 1
  end
  return math.min(newMaxHp - oldMaxHp, newMaxHp)
end

-- Plans one Rare Candy use. A level-100 mon reports no application;
-- foreign items fail. Bag stock is the caller's concern.
---@param mon table<string, unknown>
---@param itemKey string
---@param context table<string, unknown>
---@return table<string, unknown>
function ProgressionItemUse.planLevelItem(mon, itemKey, context)
  assert(type(mon) == "table", "level planning reads a mon record")
  assert(type(itemKey) == "string" and itemKey ~= "", "level planning names its item")
  assert(type(context) == "table", "level planning reads an item-use context")
  local catalog = assert(context.catalog, "level planning reads a catalog")
  if itemKey ~= LEVEL_ITEM then
    ItemErrors.raise(ItemErrors.CATALOG_INVALID, "item " .. itemKey .. " carries no level progression", {
      item = itemKey,
    })
  end
  catalog:item(LEVEL_ITEM)
  local species = catalog:species(mon.species)
  local curve = catalog:growthCurve(species.growthCurve)
  local oldLevel = Experience.level(curve, mon.experience)
  if oldLevel >= Stats.MAX_LEVEL then
    return { applied = false }
  end
  local shared = LevelProgression.award(mon, Experience.expFor(curve, oldLevel + 1) - mon.experience, catalog)
  local staged = shared.mon
  local condition = assert(staged.condition, "level planning reads the condition record") --[[@as table<string, unknown>]]
  condition.currentHp = stagedHp(
    assert(condition.currentHp, "level planning reads current health") --[[@as integer]],
    shared.maxHpBefore,
    shared.maxHpAfter
  )
  return {
    applied = true,
    mon = staged,
    level = oldLevel + 1,
    statsBefore = statWindow(MonStats.derive(mon, catalog)),
    statsAfter = statWindow(MonStats.derive(staged, catalog)),
    learningOpportunities = shared.learningOpportunities,
  }
end

return ProgressionItemUse
