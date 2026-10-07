-- Frozen executable battle binding set for one game instance. The
-- content owns behavior bindings plus action, format, and ruleset
-- definitions; species, move, ability, and item records stay in their
-- catalog owners and are never duplicated here. Every lookup returns a
-- detached copy. Binding resolves every behavior reference eagerly: each
-- resolved moves, effects, actions, formats, and rulesets record that
-- names a behavior key must name a key bound in the same-named registry,
-- and an unresolvable reference fails here instead of reaching a session.
-- The effectiveness chart is a session-scoped view over the
-- composition's own type matrix with exact integer rationals: zero stays an
-- immunity, halves stay exact, and unknown types or pairs fail instead of
-- falling back to neutral. Separate compositions never share chart state.

local Errors = require("libs.errors.src.Errors")

---@class BattleContent
---@field private _resolved ResolvedContent
---@field private _bound BoundBehaviors
local BattleContent = {}
BattleContent.__index = BattleContent

-- Every resolved content kind whose records may name a behavior key, each
-- checked against the same-named bound behavior registry. No other binding
-- kinds exist; builders keep freezing independently and meet only here.
local REFERENCE_KINDS = { "moves", "effects", "actions", "formats", "rulesets" }

---@param kind string
---@param key string
---@param record table<string, unknown>
---@return string? the referenced behavior key, or nil when the record names none
local function boundReferenceOf(kind, key, record)
  local reference = record.behavior
  if reference == nil then
    return nil
  end
  if type(reference) ~= "table" or type(reference.key) ~= "string" or reference.key == "" then
    Errors.raise("BATTLE_INVALID", kind .. " " .. key .. " carries a malformed behavior reference", {
      kind = kind,
      key = key,
    })
  end
  assert(reference.key ~= nil, "the shape check carries the validated behavior key")
  return reference.key
end

---@param resolved ResolvedContent the frozen composed content snapshot
---@param bound BoundBehaviors the frozen bound behavior registries
local function assertReferencesBound(resolved, bound)
  for _, kind in ipairs(REFERENCE_KINDS) do
    local known, keys = pcall(resolved.keys, resolved, kind)
    if known then
      assert(type(keys) == "table", "the resolved snapshot lists its defined keys")
      for _, key in ipairs(keys) do
        local record = resolved:get(kind, key)
        local reference = boundReferenceOf(kind, key, record)
        if reference ~= nil then
          local ok = pcall(bound.get, bound, kind, reference)
          if not ok then
            Errors.raise(
              "BATTLE_UNKNOWN",
              kind .. " " .. key .. " names an unknown behavior " .. reference,
              { kind = kind, key = key, behavior = reference }
            )
          end
        end
      end
    end
  end
end

---@class TypeChart
---@field private _matrix table<string, table<string, unknown>>
local TypeChart = {}
TypeChart.__index = TypeChart

---@param resolved ResolvedContent the frozen composed content snapshot
---@param bound BoundBehaviors the frozen bound behavior registries
---@return BattleContent
function BattleContent.new(resolved, bound)
  assert(type(resolved) == "table", "battle content requires its resolved snapshot")
  assert(type(bound) == "table", "battle content requires its bound behaviors")
  assert(type(resolved.get) == "function", "battle content requires a resolved snapshot")
  assert(type(resolved.keys) == "function", "battle content requires an enumerable snapshot")
  assert(type(bound.get) == "function", "battle content requires bound behaviors")
  assertReferencesBound(resolved, bound)
  return setmetatable({ _resolved = resolved, _bound = bound }, BattleContent)
end

---@param kind string
---@param key string
---@return table<string, unknown> a detached copy of the bound behavior definition
function BattleContent:behavior(kind, key)
  assert(type(kind) == "string", "behavior lookup requires its kind")
  assert(type(key) == "string", "behavior lookup requires its key")
  return self._bound:get(kind, key)
end

---@param key string
---@return table<string, unknown> a detached copy of the bound action definition
function BattleContent:action(key)
  return self:behavior("actions", key)
end

---@param key string
---@return table<string, unknown> a detached copy of the bound format definition
function BattleContent:format(key)
  return self:behavior("formats", key)
end

---@param key string
---@return table<string, unknown> a detached copy of the bound ruleset definition
function BattleContent:ruleset(key)
  return self:behavior("rulesets", key)
end

---@param attack string
---@param defend string
---@return table<string, integer> a fresh exact rational for the directed pair
function TypeChart:effectiveness(attack, defend)
  assert(type(attack) == "string", "effectiveness requires its attacking type")
  assert(type(defend) == "string", "effectiveness requires its defending type")
  local row = self._matrix[attack]
  if row == nil then
    Errors.raise("BATTLE_UNKNOWN", "unknown attacking type " .. attack, { attack = attack })
  end
  assert(row ~= nil, "the presence check carries the validated row")
  local rational = row[defend]
  if type(rational) ~= "table" then
    Errors.raise("BATTLE_UNKNOWN", "unknown type pair " .. attack .. " into " .. defend, {
      attack = attack,
      defend = defend,
    })
  end
  assert(rational ~= nil, "the presence check carries the validated rational")
  return { numerator = rational.numerator, denominator = rational.denominator }
end

---@param rulesetKey string
---@return TypeChart an isolated chart view over the composition type matrix
function BattleContent:typeChart(rulesetKey)
  assert(type(rulesetKey) == "string", "a chart lookup requires its ruleset key")
  local ruleset = self:ruleset(rulesetKey)
  if ruleset.chart ~= nil and ruleset.chart ~= rulesetKey then
    Errors.raise("BATTLE_UNKNOWN", "ruleset " .. rulesetKey .. " names an unknown chart", {
      ruleset = rulesetKey,
      chart = ruleset.chart,
    })
  end
  local kinds = self._resolved:kinds()
  local hasTypes = false
  for _, kind in ipairs(kinds) do
    if kind == "types" then
      hasTypes = true
    end
  end
  if not hasTypes then
    Errors.raise("BATTLE_UNKNOWN", "composition defines no types for ruleset " .. rulesetKey, {
      ruleset = rulesetKey,
    })
  end
  local keys = self._resolved:keys("types")
  local matrix = {}
  for _, key in ipairs(keys) do
    matrix[key] = {}
  end
  for _, key in ipairs(keys) do
    local record = self._resolved:get("types", key)
    for _, relation in ipairs(assert(record.relations, "frozen types carry their relations")) do
      local row = matrix[relation.attack]
      if row ~= nil then
        row[relation.defend] = { numerator = relation.numerator, denominator = relation.denominator }
      end
    end
  end
  return setmetatable({ _matrix = matrix }, TypeChart)
end

return BattleContent
