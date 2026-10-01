-- Complete native move registry: every usable source move resolves to
-- exactly one executable handler from the behavior families, and the
-- coverage check fails naming any identity that breaks that contract in
-- either direction. Family handlers union exactly to this registration,
-- so no usable move is merely declared and no silent damage, status, or
-- no-op fallback can serve an unbound move. The inventory stays a
-- parameter: runtime never decodes native bytes itself. Source inventory:
-- romdump battle-data move bindings over MonSources move keys 1..467.

local CalledMoves = require("libs.battle.src.gen4.behaviors.moves.CalledMoves")
local ConditionMoves = require("libs.battle.src.gen4.behaviors.moves.ConditionMoves")
local DamageMoves = require("libs.battle.src.gen4.behaviors.moves.DamageMoves")
local IdentityMoves = require("libs.battle.src.gen4.behaviors.moves.IdentityMoves")
local SequenceMoves = require("libs.battle.src.gen4.behaviors.moves.SequenceMoves")
local BattleErrors = require("libs.battle.src.errors")

---@class NativeMoves
local NativeMoves = {}

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
---@return table<string, unknown> usable move bindings of the inventory
local function checkInventory(inventory)
  if type(inventory) ~= "table" then
    error(BattleErrors.invalidState("move coverage reads a source inventory", {}))
  end
  local sources = inventory --[[@as table<string, unknown>]]
  if type(sources.moveBindings) ~= "table" then
    error(BattleErrors.invalidState("move coverage reads the move bindings", {}))
  end
  return sources.moveBindings --[[@as table<string, unknown>]]
end

---@param key string absent identity under report
---@return table<string, unknown> typed failure naming the absent identity
local function absentBinding(key)
  return BattleErrors.missingBehavior("no native move handler is bound for the source identity", { key = key })
end

--- Fills the handler table with the union of the behavior families: one
--- executable handler per usable native move.
---@param handlers table<string, fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown>> handler table receiving the native bindings
function NativeMoves.register(handlers)
  assert(type(handlers) == "table", "native moves register into their handler table")
  DamageMoves.register(handlers)
  ConditionMoves.register(handlers)
  SequenceMoves.register(handlers)
  IdentityMoves.register(handlers)
  CalledMoves.register(handlers)
end

--- Checks the handlers against the source inventory in both directions:
--- every usable move owns an executable handler, and every handler names
--- a usable move. The first break raises naming its identity.
---@param handlers table<string, unknown> registered handlers under inspection
---@param inventory table<string, unknown> source inventory the handlers must match exactly
---@return boolean true when the registration matches the inventory exactly
function NativeMoves.assertCoverage(handlers, inventory)
  assert(type(handlers) == "table", "move coverage reads the registered handlers")
  local bindings = checkInventory(inventory)
  for _, key in ipairs(sortedKeys(bindings)) do
    if type(handlers[key]) ~= "function" then
      error(absentBinding(key))
    end
  end
  for _, key in
    ipairs(sortedKeys(handlers --[[@as table<string, unknown>]]))
  do
    if bindings[key] == nil then
      error(absentBinding(key))
    end
  end
  return true
end

return NativeMoves
