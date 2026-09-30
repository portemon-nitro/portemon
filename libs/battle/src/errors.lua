-- Battle domain error vocabulary. Expected invalid external decisions use
-- BATTLE_INPUT and leave simulation state untouched; broken simulation
-- invariants, unknown executable behavior, and incompatible interruption
-- state each carry their own code so callers never confuse a rejected reply
-- with a programming failure. Pure domain module: no love dependency.

local Errors = require("libs.errors.src.Errors")

---@class BattleErrors
local BattleErrors = {}

BattleErrors.INPUT = "BATTLE_INPUT"
BattleErrors.INVALID_STATE = "BATTLE_INVALID_STATE"
BattleErrors.MISSING_BEHAVIOR = "BATTLE_MISSING_BEHAVIOR"
BattleErrors.INCOMPATIBLE_SNAPSHOT = "BATTLE_INCOMPATIBLE_SNAPSHOT"

---@param message string
---@param context table<string, unknown>?
---@return Errors.Error
function BattleErrors.input(message, context)
  assert(type(message) == "string", "battle input errors require a message")
  return Errors.new(BattleErrors.INPUT, message, context or {})
end

---@param message string
---@param context table<string, unknown>?
---@return Errors.Error
function BattleErrors.invalidState(message, context)
  assert(type(message) == "string", "battle state errors require a message")
  return Errors.new(BattleErrors.INVALID_STATE, message, context or {})
end

---@param message string
---@param context table<string, unknown>?
---@return Errors.Error
function BattleErrors.missingBehavior(message, context)
  assert(type(message) == "string", "battle behavior errors require a message")
  return Errors.new(BattleErrors.MISSING_BEHAVIOR, message, context or {})
end

---@param message string
---@param context table<string, unknown>?
---@return Errors.Error
function BattleErrors.incompatibleSnapshot(message, context)
  assert(type(message) == "string", "battle snapshot errors require a message")
  return Errors.new(BattleErrors.INCOMPATIBLE_SNAPSHOT, message, context or {})
end

return BattleErrors
