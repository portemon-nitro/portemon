-- Reusable out-of-battle progression item planning through the shared
-- owners. Sweets raise exactly one level through the shared progression
-- arithmetic and report an evolution the new level earns; evolution items
-- stage real candidate plans that spend exactly one item on accept and
-- nothing on decline. Planning never mutates its input and never consumes
-- on its own: the caller publishes the staged spend together with the
-- accepted result, so declined or retried uses cost nothing and stay
-- retryable.

local ItemErrors = require("libs.items.src.errors")
local Evolution = require("libs.mons.src.gen4.Evolution")
local Experience = require("libs.mons.src.gen4.Experience")
local LevelProgression = require("libs.mons.src.gen4.LevelProgression")
local Stats = require("libs.mons.src.gen4.Stats")

---@class ProgressionItemUse
local ProgressionItemUse = {}

local LEVEL_ITEM = "RARE_CANDY"

---@param context table<string, unknown>
---@param trigger table<string, unknown>
---@return table<string, unknown>
local function evolutionContext(context, trigger)
  return {
    game = context.game,
    timeOfDay = context.timeOfDay,
    location = context.location,
    party = context.party,
    inventory = context.inventory,
    trigger = trigger,
  }
end

---@param context table<string, unknown>
---@return table<string, unknown>
local function checkContext(context)
  assert(type(context) == "table", "progression planning reads an item-use context")
  local catalog = assert(context.catalog, "progression planning reads a catalog")
  assert(type(catalog) == "table", "progression planning reads a catalog")
  local inventory = assert(context.inventory, "progression planning reads the bag facts")
  assert(type(inventory) == "table", "bag facts form a record")
  return catalog
end

-- Plans one sweet use: exactly one level through the shared progression,
-- with its learning chances, maximum-health pair, single staged spend, and
-- the evolution the new level earns, if any. Capped mons and empty pockets
-- report no application and no spend; foreign items fail without consuming.
---@param mon table<string, unknown>
---@param itemKey string
---@param context table<string, unknown>
---@return table<string, unknown>
function ProgressionItemUse.planLevelItem(mon, itemKey, context)
  assert(type(mon) == "table", "level planning reads a mon record")
  assert(type(itemKey) == "string" and itemKey ~= "", "level planning names its item")
  local catalog = checkContext(context)
  if itemKey ~= LEVEL_ITEM then
    ItemErrors.raise(ItemErrors.CATALOG_INVALID, "item " .. itemKey .. " carries no level progression", {
      item = itemKey,
    })
  end
  catalog:item(LEVEL_ITEM)
  local inventory = assert(context.inventory, "level planning reads the bag facts")
  if (inventory[itemKey] or 0) < 1 then
    return { applied = false, consumed = 0 }
  end
  local species = catalog:species(mon.species)
  local curve = catalog:growthCurve(species.growthCurve)
  local oldLevel = Experience.level(curve, mon.experience)
  if oldLevel >= Stats.MAX_LEVEL then
    return { applied = false, consumed = 0 }
  end
  local shared = LevelProgression.award(mon, Experience.expFor(curve, oldLevel + 1) - mon.experience, catalog)
  local slot = Evolution.check(shared.mon, evolutionContext(context, { kind = "level" }), catalog)
  local evolution = nil
  if slot ~= nil then
    evolution = slot.target
  end
  return {
    applied = true,
    consumed = 1,
    mon = shared.mon,
    crossedLevels = shared.crossedLevels,
    learningOpportunities = shared.learningOpportunities,
    maxHpBefore = shared.maxHpBefore,
    maxHpAfter = shared.maxHpAfter,
    evolution = evolution,
  }
end

-- Plans one evolution-item use: the staged candidate plus exactly one spend
-- on accept and none on decline. A mismatched item or an empty pocket
-- stages nothing; unknown items fail without staging.
---@param mon table<string, unknown>
---@param itemKey string
---@param context table<string, unknown>
---@return table<string, unknown>?
function ProgressionItemUse.planEvolutionItem(mon, itemKey, context)
  assert(type(mon) == "table", "evolution planning reads a mon record")
  assert(type(itemKey) == "string" and itemKey ~= "", "evolution planning names its item")
  local catalog = checkContext(context)
  local inventory = assert(context.inventory, "evolution planning reads the bag facts")
  local stock = inventory[itemKey] or 0
  local triggerContext = evolutionContext(context, { kind = "item", item = itemKey })
  if Evolution.check(mon, triggerContext, catalog) == nil then
    if stock > 0 then
      return nil
    end
    catalog:item(itemKey)
    return nil
  end
  catalog:item(itemKey)
  if stock < 1 then
    return nil
  end
  local plan = Evolution.plan(mon, triggerContext, catalog)
  assert(plan ~= nil, "a matched evolution item stages its plan")
  plan.inventoryDeltas = { { item = itemKey, delta = -1 } }
  return { plan = plan, consumedOnAccept = 1, consumedOnCancel = 0 }
end

return ProgressionItemUse
