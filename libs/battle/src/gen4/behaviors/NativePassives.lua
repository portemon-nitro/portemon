-- Complete native passive registration: every usable ability and
-- every holdable item resolves to exactly one executable handler from
-- the timing families, and the registry check fails naming any identity
-- that breaks that contract. Balls and mail stay explicitly unbound --
-- an instance naming one fails loudly through the owned dispatch
-- instead of running a silent fallback. The sentinel ability carries
-- no binding.

local EntryAbilities = require("libs.battle.src.gen4.behaviors.abilities.EntryAbilities")
local ModifierAbilities = require("libs.battle.src.gen4.behaviors.abilities.ModifierAbilities")
local ReactiveAbilities = require("libs.battle.src.gen4.behaviors.abilities.ReactiveAbilities")
local PassiveItems = require("libs.battle.src.gen4.behaviors.items.PassiveItems")
local TriggeredItems = require("libs.battle.src.gen4.behaviors.items.TriggeredItems")
local BattleErrors = require("libs.battle.src.errors")

local NativePassives = {}

NativePassives.SENTINEL_ABILITY = "NONE"

local UNHELD_CLASSES = {
  ball = true,
  no_hold = true,
}

---@param set table<string, unknown> key set under ordering
---@return string[] sorted keys for deterministic diagnostics
local function sortedKeys(set)
  local keys = {}
  for key in pairs(set) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(left, right)
    return tostring(left) < tostring(right)
  end)
  return keys
end

---@param inventory unknown candidate source inventory under inspection
---@return table<string, unknown> usable ability bindings of the inventory
---@return table<string, unknown> held-item bindings of the inventory
local function checkInventory(inventory)
  if type(inventory) ~= "table" then
    error(BattleErrors.invalidState("passive coverage reads a source inventory", {}))
  end
  local sources = inventory --[[@as table<string, unknown>]]
  if type(sources.abilityBindings) ~= "table" or type(sources.heldItemBindings) ~= "table" then
    error(BattleErrors.invalidState("passive coverage reads ability and held-item bindings", {}))
  end
  return sources.abilityBindings, --[[@as table<string, unknown>]]
    sources.heldItemBindings --[[@as table<string, unknown>]]
end

---@param binding unknown candidate held-item binding under inspection
---@return boolean true when the binding can never attach to a combatant
local function neverHeld(binding)
  if type(binding) ~= "table" then
    return false
  end
  return UNHELD_CLASSES[
    (binding --[[@as table<string, unknown>]]).key
  ] == true
end

---@param key string absent identity under report
---@return table<string, unknown> typed failure naming the absent identity
local function absentBinding(key)
  return BattleErrors.missingBehavior("no native passive handler is bound for the source identity", { key = key })
end

--- Fills the handler table with the union of the timing families: one
--- executable handler per usable ability and holdable item.
---@param handlers table<string, fun(instance: table<string, unknown>, context: table<string, unknown>): table<string, unknown>?> handler table receiving the native bindings
function NativePassives.register(handlers)
  assert(type(handlers) == "table", "native passives register into their handler table")
  EntryAbilities.register(handlers)
  ModifierAbilities.register(handlers)
  ReactiveAbilities.register(handlers)
  PassiveItems.register(handlers)
  TriggeredItems.register(handlers)
end

--- Checks the handlers against the source inventory in both directions:
--- every usable ability and holdable item owns an executable handler,
--- and every handler names a usable ability or holdable item. The first
--- break raises naming its identity.
---@param handlers table<string, unknown> registered handlers under inspection
---@param inventory table<string, unknown> source inventory the handlers must match exactly
---@return boolean true when the registration matches the inventory exactly
function NativePassives.assertCoverage(handlers, inventory)
  assert(type(handlers) == "table", "passive coverage reads the registered handlers")
  local abilities, items = checkInventory(inventory)
  for _, key in ipairs(sortedKeys(abilities)) do
    if key ~= NativePassives.SENTINEL_ABILITY then
      if type(handlers[key]) ~= "function" then
        error(absentBinding(key))
      end
    end
  end
  for _, key in ipairs(sortedKeys(items)) do
    if not neverHeld(items[key]) then
      if type(handlers[key]) ~= "function" then
        error(absentBinding(key))
      end
    end
  end
  for _, key in
    ipairs(sortedKeys(handlers --[[@as table<string, unknown>]]))
  do
    local usable = key ~= NativePassives.SENTINEL_ABILITY and abilities[key] ~= nil
    local holdable = items[key] ~= nil and not neverHeld(items[key])
    if not usable and not holdable then
      error(absentBinding(key))
    end
  end
  return true
end

return NativePassives
