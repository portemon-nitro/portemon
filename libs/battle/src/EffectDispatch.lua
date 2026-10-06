-- Finite timing dispatch over scoped effect instances. The mechanics
-- timings are a closed vocabulary; definitions bind their handlers to
-- named timings with a source mechanic category, never a numeric mod
-- priority. Collection resolves the source-prescribed ordered candidates
-- for one timing, and invocation rechecks liveness before every call, so
-- instances removed mid-pass stay silent while newborn instances wait for
-- the next pass. A suspended pass publishes a plain-data checkpoint that
-- resumes exactly behind its cursor with the same sequence as an
-- unbounded run.

local BattleErrors = require("libs.battle.src.errors")

---@class DispatchScope
---@field kind string
---@field combatant integer?
---@field activation integer?
---@field side integer?
---@field position integer?

---@class DispatchInstance
---@field id integer
---@field key string
---@field version integer
---@field scope DispatchScope
---@field source table<string, unknown>
---@field state table<string, unknown>
---@field createdOrdinal integer
---@field timings DispatchBinding[]
---@field lifecycle table<string, unknown>

---@class DispatchBinding
---@field timing string
---@field handler string
---@field orderClass string

---@class DispatchEntry
---@field instance DispatchInstance
---@field binding DispatchBinding

---@class DispatchCheckpoint
---@field kind string
---@field version integer
---@field timing string
---@field entries DispatchCheckpointEntry[]
---@field cursor integer

---@class DispatchCheckpointEntry
---@field id integer
---@field key string
---@field scope DispatchScope

---@class DispatchOutcome
---@field events table<string, unknown>[]
---@field done boolean
---@field checkpoint DispatchCheckpoint?

---@class EffectDispatch
---@field private _bag table<string, unknown>
---@field private _handlers table<string, fun(instance: DispatchInstance, context: table<string, unknown>): unknown>
local EffectDispatch = {}
EffectDispatch.__index = EffectDispatch

EffectDispatch.TIMINGS = {
  "entry",
  "beforeAction",
  "modifyStat",
  "beforeHit",
  "afterHit",
  "afterMove",
  "residual",
  "leave",
}

EffectDispatch.CHECKPOINT_KIND = "battle:dispatch"
EffectDispatch.CHECKPOINT_VERSION = 1

local TIMING_SET = {}
for _, timing in ipairs(EffectDispatch.TIMINGS) do
  TIMING_SET[timing] = true
end

-- Source mechanic categories in stable traversal order. This table is a
-- determinism anchor, not the native category law: unknown categories sort
-- after every known one, so registered extensions compose without
-- renumbering native order.
local ORDER_CLASS_RANK = {
  weather = 1,
  expiration = 2,
  affliction = 3,
  recovery = 4,
}

---@param definition unknown
---@return boolean true when every timing binding names the finite vocabulary
function EffectDispatch.validateBindings(definition)
  if type(definition) ~= "table" then
    error(BattleErrors.invalidState("effect definitions are records", {}))
  end
  assert(type(definition) == "table", "effect definition validated above")
  local timings = definition.timings
  if type(timings) ~= "table" or #timings == 0 then
    error(BattleErrors.invalidState("effect definitions bind at least one timing", {}))
  end
  for index, binding in ipairs(timings) do
    if type(binding) ~= "table" then
      error(BattleErrors.invalidState("effect timing bindings are records", { index = index }))
    end
    assert(type(binding) == "table", "timing binding validated above")
    if TIMING_SET[binding.timing] == nil then
      error(BattleErrors.invalidState("effect definitions bind only finite known timings", {
        timing = binding.timing,
      }))
    end
    if type(binding.handler) ~= "string" or binding.handler == "" then
      error(BattleErrors.invalidState("effect timing bindings name their handler", {
        timing = binding.timing,
      }))
    end
    if type(binding.orderClass) ~= "string" or binding.orderClass == "" then
      error(BattleErrors.invalidState("effect timing bindings name their source category", {
        timing = binding.timing,
      }))
    end
  end
  return true
end

---@param bag table<string, unknown> scoped instance owner carrying capture, get, remove, and commitState
---@param handlers table<string, fun(instance: DispatchInstance, context: table<string, unknown>): unknown> handler per definition key
---@return EffectDispatch
function EffectDispatch.new(bag, handlers)
  assert(type(bag) == "table", "dispatch reads its scoped instances from the bag")
  assert(type(handlers) == "table", "dispatch resolves handlers per definition key")
  return setmetatable({ _bag = bag, _handlers = handlers }, EffectDispatch)
end

---@param value unknown
---@return unknown
local function copyValue(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in
    pairs(value --[[@as table<unknown, unknown>]])
  do
    out[key] = copyValue(item)
  end
  return out
end

---@param instance DispatchInstance collected instance under test
---@param speeds table<integer, integer>? sampled speed per combatant
---@return number traversal speed, with slot and field state ahead of combatants
local function traversalSpeed(instance, speeds)
  local combatant = instance.scope.combatant
  if combatant ~= nil then
    if speeds ~= nil and type(speeds[combatant]) == "number" then
      return speeds[combatant]
    end
    return 0
  end
  return math.huge
end

---@param orderClass string
---@return number stable category rank with unknown categories trailing
local function categoryRank(orderClass)
  local rank = ORDER_CLASS_RANK[orderClass]
  if rank ~= nil then
    return rank
  end
  return 5
end

---@class RankedDispatchEntry
---@field instance DispatchInstance
---@field binding DispatchBinding
---@field speed number
---@field rank number
---@field ordinal integer? invocation-local explicit position, when planned

---@param left RankedDispatchEntry
---@param right RankedDispatchEntry
---@return boolean
local function entryBefore(left, right)
  if left.ordinal ~= nil or right.ordinal ~= nil then
    if left.ordinal == nil then
      return false
    end
    if right.ordinal == nil then
      return true
    end
    if left.ordinal ~= right.ordinal then
      return left.ordinal < right.ordinal
    end
  end
  if left.rank ~= right.rank then
    return left.rank < right.rank
  end
  if left.speed ~= right.speed then
    return left.speed > right.speed
  end
  return left.instance.createdOrdinal < right.instance.createdOrdinal
end

---@param planned table<integer, integer> explicit position per planned instance identity
---@param instance DispatchInstance collected instance under planning
---@param seen table<integer, integer> claiming instance per position
---@return integer? explicit position for the instance, absent when unplanned
local function checkPlannedOrdinal(planned, instance, seen)
  local ordinal = planned[instance.id]
  if ordinal == nil then
    return nil
  end
  if type(ordinal) ~= "number" or ordinal % 1 ~= 0 or ordinal < 1 then
    error(BattleErrors.invalidState("dispatch plans carry positive integral positions", { id = instance.id }))
  end
  local claimed = seen[ordinal]
  if claimed ~= nil and claimed ~= instance.id then
    error(BattleErrors.invalidState("dispatch plans carry one position per entry", { ordinal = ordinal }))
  end
  seen[ordinal] = instance.id
  return ordinal
end

--- Collects the ordered candidates for one timing: every live instance
--- bound to it, traversed by source category, then sampled speed order,
--- then creation ordinal. Insertion order never decides. When the context
--- carries an invocation-local explicit order per instance identity, the
--- planned entries traverse by it first while unplanned extensions keep
--- the deterministic fallback order behind them.
---@param timing string mechanics timing under collection
---@param context table<string, unknown> pass context carrying sampled speeds
---@return DispatchEntry[] ordered candidate entries with detached instances
function EffectDispatch:collect(timing, context)
  if TIMING_SET[timing] == nil then
    error(BattleErrors.invalidState("dispatch collects only finite known timings", { timing = timing }))
  end
  assert(type(context) == "table", "dispatch collection carries its pass context")
  local planned = context.orderOrdinal
  if planned ~= nil then
    assert(type(planned) == "table", "dispatch plans map instance identities to positions")
  end
  local bag = self._bag --[[@as DispatchBagView]]
  local speeds = context.speeds --[[@as table<integer, integer>?]]
  local records = bag:capture()
  local seen = {}
  local entries = {}
  for _, instance in ipairs(records) do
    for _, binding in ipairs(instance.timings) do
      if binding.timing == timing then
        local ordinal = nil
        if planned ~= nil then
          ordinal = checkPlannedOrdinal(planned --[[@as table<integer, integer>]], instance, seen)
        end
        entries[#entries + 1] = {
          instance = instance,
          binding = copyValue(binding),
          speed = traversalSpeed(instance, speeds),
          rank = categoryRank(binding.orderClass),
          ordinal = ordinal,
        }
      end
    end
  end
  table.sort(entries, entryBefore)
  local out = {}
  for _, entry in ipairs(entries) do
    out[#out + 1] = { instance = entry.instance, binding = entry.binding }
  end
  return out
end

---@class DispatchBagView
---@field capture fun(self: DispatchBagView): DispatchInstance[]
---@field get fun(self: DispatchBagView, id: integer): DispatchInstance?
---@field commitState fun(self: DispatchBagView, id: integer, state: table<string, unknown>): boolean

---@param left unknown
---@param right unknown
---@return boolean
local function scopesEqual(left, right)
  if type(left) ~= "table" or type(right) ~= "table" then
    return left == right
  end
  assert(type(left) == "table" and type(right) == "table", "scope comparison reads records")
  if left.kind ~= right.kind then
    return false
  end
  for _, field in ipairs({ "side", "position", "combatant", "activation" }) do
    if left[field] ~= right[field] then
      return false
    end
  end
  return true
end

---@param checkpoint unknown
---@param timing string
---@return DispatchCheckpointEntry[] ordered entries
---@return integer resume cursor
local function checkCheckpoint(checkpoint, timing)
  if type(checkpoint) ~= "table" then
    error(BattleErrors.incompatibleSnapshot("dispatch checkpoints resume from a record", {}))
  end
  assert(type(checkpoint) == "table", "dispatch checkpoint validated above")
  if checkpoint.kind ~= EffectDispatch.CHECKPOINT_KIND or checkpoint.version ~= EffectDispatch.CHECKPOINT_VERSION then
    error(BattleErrors.incompatibleSnapshot("dispatch checkpoints carry the current identity", {}))
  end
  if checkpoint.timing ~= timing then
    error(BattleErrors.incompatibleSnapshot("dispatch checkpoints resume their own timing", {
      timing = checkpoint.timing,
    }))
  end
  if type(checkpoint.entries) ~= "table" or type(checkpoint.cursor) ~= "number" then
    error(BattleErrors.incompatibleSnapshot("dispatch checkpoints carry their cursor", {}))
  end
  return checkpoint.entries, checkpoint.cursor
end

---@param result unknown
---@param key string
---@return table<string, unknown>[] emitted events, empty when the handler stays silent
local function normalizeEvents(result, key)
  if result == nil then
    return {}
  end
  if type(result) ~= "table" then
    error(BattleErrors.invalidState("timing handlers return events or silence", { key = key }))
  end
  assert(type(result) == "table", "handler result validated above")
  if result.kind ~= nil then
    return {
      result --[[@as table<string, unknown>]],
    }
  end
  local events = {}
  for index, event in
    ipairs(result --[[@as table<integer, unknown>]])
  do
    if type(event) ~= "table" then
      error(BattleErrors.invalidState("timing handlers emit event records", { key = key, index = index }))
    end
    events[#events + 1] = event --[[@as table<string, unknown>]]
  end
  return events
end

--- Invokes one timing to completion or to its operation budget. Liveness
--- is rechecked before every call: removed instances stay silent, and a
--- replaced entry falls back to the live instance carrying the same key
--- and scope. State mutations the handler makes persist through the bag;
--- unknown handlers fail loudly instead of skipping.
---@param timing string mechanics timing under invocation
---@param context table<string, unknown> pass context, carrying resume and suppression on suspension
---@param budget integer? handler invocations this call may spend before yielding
---@return DispatchOutcome pass events with its completion flag and continuation
function EffectDispatch:invoke(timing, context, budget)
  if TIMING_SET[timing] == nil then
    error(BattleErrors.invalidState("dispatch invokes only finite known timings", { timing = timing }))
  end
  assert(type(context) == "table", "dispatch invocation carries its pass context")
  local allowance = budget
  if allowance ~= nil then
    assert(
      type(allowance) == "number" and allowance % 1 == 0 and allowance >= 1,
      "dispatch passes spend a positive operation budget"
    )
  end
  local bag = self._bag --[[@as DispatchBagView]]
  local ordered = {}
  local cursor = 1
  if context.resume ~= nil then
    local entries, saved = checkCheckpoint(context.resume, timing)
    for _, entry in ipairs(entries) do
      ordered[#ordered + 1] = entry
    end
    cursor = saved
  else
    for _, entry in ipairs(self:collect(timing, context)) do
      ordered[#ordered + 1] = { id = entry.instance.id, key = entry.instance.key, scope = entry.instance.scope }
    end
  end
  local suppressed = context.suppressedIds
  if suppressed ~= nil then
    assert(type(suppressed) == "table", "suppression marks instance identities")
  end
  local events = {}
  local fired = {}
  while cursor <= #ordered do
    local planned = ordered[cursor]
    cursor = cursor + 1
    local live = bag:get(planned.id)
    if live == nil then
      for _, candidate in ipairs(bag:capture()) do
        if
          candidate.key == planned.key
          and scopesEqual(candidate.scope, planned.scope)
          and fired[candidate.id] == nil
        then
          live = candidate
          break
        end
      end
    end
    if live ~= nil and fired[live.id] == nil then
      fired[live.id] = true
      if suppressed == nil or suppressed[live.id] ~= true then
        local handler = self._handlers[live.key]
        if handler == nil then
          error(BattleErrors.missingBehavior("no handler is bound for the effect", { key = live.key }))
        end
        local produced = handler(live, context)
        if type(live.state) ~= "table" then
          error(BattleErrors.invalidState("timing handlers keep typed state a record", { key = live.key }))
        end
        bag:commitState(live.id, live.state)
        for _, event in ipairs(normalizeEvents(produced, live.key)) do
          events[#events + 1] = event
        end
        if allowance ~= nil then
          allowance = allowance - 1
        end
        if allowance ~= nil and allowance < 1 and cursor <= #ordered then
          return {
            events = events,
            done = false,
            checkpoint = {
              kind = EffectDispatch.CHECKPOINT_KIND,
              version = EffectDispatch.CHECKPOINT_VERSION,
              timing = timing,
              entries = ordered,
              cursor = cursor,
            },
          }
        end
      end
    end
  end
  return { events = events, done = true, checkpoint = nil }
end

return EffectDispatch
