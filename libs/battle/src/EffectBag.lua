-- Scoped ownership for battle effect instances. The bag allocates stable
-- nonreused identities, keeps deterministic creation order, and stores only
-- validated typed state; it implements no status, timing, or damage law.
-- Persistent conditions belong on the canonical mon record and are refused
-- here, so battle-local state can never leak into long-lived storage.
-- Every stored record stays plain data: snapshots capture the full ordered
-- set and restore it exactly, which is what lets suspension cross
-- activation and save boundaries without a second live owner.

local BattleErrors = require("libs.battle.src.errors")
local EffectDispatch = require("libs.battle.src.EffectDispatch")

---@class EffectScopeField
---@field kind "field"

---@class EffectScopeSide
---@field kind "side"
---@field side integer

---@class EffectScopePosition
---@field kind "position"
---@field position integer

---@class EffectScopeRoster
---@field kind "roster"
---@field combatant integer

---@class EffectScopeActive
---@field kind "active"
---@field combatant integer
---@field activation integer

---@alias EffectScope EffectScopeField|EffectScopeSide|EffectScopePosition|EffectScopeRoster|EffectScopeActive

---@class EffectCause
---@field kind string
---@field combatant integer?
---@field activation integer?

---@class EffectTimingLink
---@field timing string
---@field handler string
---@field orderClass string

---@class EffectLifecycleLink
---@field stacking string
---@field transfer string
---@field persistent boolean?
---@field maxStacks integer?

---@class EffectDefinitionLink
---@field key string
---@field stateVersion integer
---@field validateState fun(state: unknown): table<string, unknown>
---@field timings EffectTimingLink[]
---@field lifecycle EffectLifecycleLink

---@class EffectInstance
---@field id integer
---@field key string
---@field version integer
---@field scope EffectScope
---@field source EffectCause
---@field state table<string, unknown>
---@field createdOrdinal integer
---@field timings EffectTimingLink[]
---@field lifecycle EffectLifecycleLink

---@class EffectBag
---@field private _records table<integer, EffectInstance>
---@field private _nextId integer
---@field private _nextOrdinal integer
local EffectBag = {}
EffectBag.__index = EffectBag

local STACKING_POLICIES = { replace = true, reject = true, stack = true }
local TRANSFER_POLICIES = { clear = true, carry = true, position = true }

---@param value unknown
---@return unknown
local function copyValue(value)
  local kind = type(value)
  if kind == "table" then
    local out = {}
    for key, item in
      pairs(value --[[@as table<unknown, unknown>]])
    do
      if type(key) == "table" then
        error(BattleErrors.invalidState("effect state keys stay scalar", {}))
      end
      out[key] = copyValue(item)
    end
    return out
  end
  if kind == "function" or kind == "thread" or kind == "userdata" then
    error(BattleErrors.invalidState("effect state stays serializable", { kind = kind }))
  end
  return value
end

---@param scope unknown
---@return EffectScope
local function checkScope(scope)
  if type(scope) ~= "table" then
    error(BattleErrors.invalidState("effect scopes are records", {}))
  end
  assert(type(scope) == "table", "effect scope validated above")
  local kind = scope.kind
  if kind == "field" then
    return { kind = "field" }
  end
  if kind == "side" then
    assert(scope.side ~= nil, "side scopes name their side")
    return { kind = "side", side = scope.side }
  end
  if kind == "position" then
    assert(scope.position ~= nil, "position scopes name their position")
    return { kind = "position", position = scope.position }
  end
  if kind == "roster" then
    assert(scope.combatant ~= nil, "roster scopes name their combatant")
    return { kind = "roster", combatant = scope.combatant }
  end
  if kind == "active" then
    assert(scope.combatant ~= nil, "active scopes name their combatant")
    assert(scope.activation ~= nil, "active scopes name their entry token")
    return { kind = "active", combatant = scope.combatant, activation = scope.activation }
  end
  error(BattleErrors.invalidState("effect scopes name a known owner", { kind = kind }))
end

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

---@param definition unknown
---@return EffectDefinitionLink
local function checkDefinition(definition)
  if type(definition) ~= "table" then
    error(BattleErrors.invalidState("effect definitions are records", {}))
  end
  assert(type(definition) == "table", "effect definition validated above")
  if type(definition.key) ~= "string" or definition.key == "" then
    error(BattleErrors.invalidState("effect definitions carry a non-empty key", {}))
  end
  if type(definition.stateVersion) ~= "number" or definition.stateVersion % 1 ~= 0 or definition.stateVersion < 1 then
    error(BattleErrors.invalidState("effect definitions version their typed state", { key = definition.key }))
  end
  if type(definition.validateState) ~= "function" then
    error(BattleErrors.invalidState("effect definitions validate their typed state", { key = definition.key }))
  end
  EffectDispatch.validateBindings(definition)
  local lifecycle = definition.lifecycle
  if type(lifecycle) ~= "table" then
    error(BattleErrors.invalidState("effect definitions declare their lifecycle policy", { key = definition.key }))
  end
  assert(type(lifecycle) == "table", "lifecycle policy validated above")
  if STACKING_POLICIES[lifecycle.stacking] == nil then
    error(BattleErrors.invalidState("effect definitions name a known stacking policy", {
      key = definition.key,
      stacking = lifecycle.stacking,
    }))
  end
  if TRANSFER_POLICIES[lifecycle.transfer] == nil then
    error(BattleErrors.invalidState("effect definitions name a known transfer policy", {
      key = definition.key,
      transfer = lifecycle.transfer,
    }))
  end
  if lifecycle.maxStacks ~= nil then
    assert(
      type(lifecycle.maxStacks) == "number" and lifecycle.maxStacks % 1 == 0 and lifecycle.maxStacks >= 1,
      "stacking bounds are positive integers"
    )
  end
  return definition --[[@as EffectDefinitionLink]]
end

---@param snapshot unknown
---@return table<integer, EffectInstance> restored records by identity
---@return integer next identity after the restored set
---@return integer next creation ordinal after the restored set
local function checkSnapshot(snapshot)
  if type(snapshot) ~= "table" then
    error(BattleErrors.incompatibleSnapshot("effect snapshots restore from an ordered record list", {}))
  end
  assert(type(snapshot) == "table", "effect snapshot validated above")
  local records = {}
  local seenIds = {}
  local seenOrdinals = {}
  local nextId = 1
  local nextOrdinal = 1
  for index, record in
    ipairs(snapshot --[[@as table<integer, unknown>]])
  do
    if type(record) ~= "table" then
      error(BattleErrors.incompatibleSnapshot("effect snapshots carry records", { index = index }))
    end
    assert(type(record) == "table", "snapshot record validated above")
    if
      type(record.id) ~= "number"
      or record.id % 1 ~= 0
      or record.id < 1
      or type(record.createdOrdinal) ~= "number"
      or record.createdOrdinal % 1 ~= 0
      or record.createdOrdinal < 1
    then
      error(BattleErrors.incompatibleSnapshot("effect snapshots carry stable identities", { index = index }))
    end
    if type(record.key) ~= "string" or record.key == "" then
      error(BattleErrors.incompatibleSnapshot("effect snapshots carry definition keys", { index = index }))
    end
    if type(record.version) ~= "number" or record.version % 1 ~= 0 or record.version < 1 then
      error(BattleErrors.incompatibleSnapshot("effect snapshots carry state versions", { index = index }))
    end
    if type(record.state) ~= "table" or type(record.source) ~= "table" then
      error(BattleErrors.incompatibleSnapshot("effect snapshots carry typed state and cause", { index = index }))
    end
    if seenIds[record.id] or seenOrdinals[record.createdOrdinal] then
      error(BattleErrors.incompatibleSnapshot("effect snapshots carry unique identities", { index = index }))
    end
    seenIds[record.id] = true
    seenOrdinals[record.createdOrdinal] = true
    local stored = {
      id = record.id,
      key = record.key,
      version = record.version,
      scope = checkScope(record.scope),
      source = copyValue(record.source),
      state = copyValue(record.state),
      createdOrdinal = record.createdOrdinal,
      timings = copyValue(record.timings or {}),
      lifecycle = copyValue(record.lifecycle or { stacking = "replace", transfer = "clear" }),
    }
    records[record.id] = stored
    if record.id >= nextId then
      nextId = record.id + 1
    end
    if record.createdOrdinal >= nextOrdinal then
      nextOrdinal = record.createdOrdinal + 1
    end
  end
  return records, nextId, nextOrdinal
end

---@param snapshot table<integer, unknown>? ordered records from a previous capture
---@return EffectBag
function EffectBag.new(snapshot)
  if snapshot == nil then
    return setmetatable({ _records = {}, _nextId = 1, _nextOrdinal = 1 }, EffectBag)
  end
  local records, nextId, nextOrdinal = checkSnapshot(snapshot)
  return setmetatable({ _records = records, _nextId = nextId, _nextOrdinal = nextOrdinal }, EffectBag)
end

---@param record EffectInstance
---@return EffectInstance detached copy of the stored instance
local function detach(record)
  return {
    id = record.id,
    key = record.key,
    version = record.version,
    scope = copyValue(record.scope),
    source = copyValue(record.source),
    state = copyValue(record.state),
    createdOrdinal = record.createdOrdinal,
    timings = copyValue(record.timings),
    lifecycle = copyValue(record.lifecycle),
  } --[[@as EffectInstance]]
end

---@param definition EffectDefinitionLink
---@param scope EffectScope
---@return EffectInstance[] live instances sharing the definition key and owner scope
function EffectBag:_scopedSiblings(definition, scope)
  local siblings = {}
  for _, record in pairs(self._records) do
    if record.key == definition.key and scopesEqual(record.scope, scope) then
      siblings[#siblings + 1] = record
    end
  end
  return siblings
end

--- Publishes a validated instance. Rejected additions raise before touching
--- live state. Replacement stacking clears same-key same-scope siblings;
--- rejection stacking refuses them; counted stacking enforces its bound.
---@param definition EffectDefinitionLink definition carrying key, version, validator, timings, and lifecycle
---@param scope EffectScope owner scope the instance attaches to
---@param source EffectCause causal source attributed to the instance
---@param state unknown candidate typed state validated by the definition
---@return EffectInstance detached copy of the stored instance
function EffectBag:add(definition, scope, source, state)
  local checked = checkDefinition(definition)
  if checked.lifecycle.persistent == true then
    error(BattleErrors.invalidState("persistent conditions live on the canonical mon, never in the bag", {
      key = checked.key,
    }))
  end
  local ownedScope = checkScope(scope)
  if type(source) ~= "table" then
    error(BattleErrors.invalidState("effect instances carry a causal source", { key = checked.key }))
  end
  local validated = checked.validateState(state)
  if type(validated) ~= "table" then
    error(BattleErrors.invalidState("effect validators return typed state records", { key = checked.key }))
  end
  assert(type(validated) == "table", "validated state checked above")
  if validated.version ~= checked.stateVersion then
    error(BattleErrors.invalidState("effect state carries its definition version", {
      key = checked.key,
      version = validated.version,
    }))
  end
  local siblings = self:_scopedSiblings(checked, ownedScope)
  if checked.lifecycle.stacking == "reject" and #siblings > 0 then
    error(BattleErrors.invalidState("the definition rejects a second live instance", { key = checked.key }))
  end
  if
    checked.lifecycle.stacking == "stack"
    and checked.lifecycle.maxStacks ~= nil
    and #siblings >= checked.lifecycle.maxStacks
  then
    error(BattleErrors.invalidState("the definition reached its stacking bound", { key = checked.key }))
  end
  if checked.lifecycle.stacking == "replace" then
    for _, sibling in ipairs(siblings) do
      self._records[sibling.id] = nil
    end
  end
  local record = {
    id = self._nextId,
    key = checked.key,
    version = checked.stateVersion,
    scope = ownedScope,
    source = copyValue(source),
    state = copyValue(validated),
    createdOrdinal = self._nextOrdinal,
    timings = copyValue(checked.timings),
    lifecycle = copyValue(checked.lifecycle),
  }
  self._records[record.id] = record
  self._nextId = self._nextId + 1
  self._nextOrdinal = self._nextOrdinal + 1
  return detach(record)
end

--- Reads one instance without sharing mutable state with the caller.
---@param id integer stable instance identity
---@return EffectInstance? detached copy of the stored instance, or nil when absent
function EffectBag:get(id)
  assert(type(id) == "number", "instance lookup requires its identity")
  local record = self._records[id]
  if record == nil then
    return nil
  end
  return detach(record)
end

--- Drops one instance; unknown identities report false instead of failing.
---@param id integer stable instance identity
---@return boolean true when a live instance was removed
function EffectBag:remove(id)
  assert(type(id) == "number", "instance removal requires its identity")
  if self._records[id] == nil then
    return false
  end
  self._records[id] = nil
  return true
end

--- Moves one instance onto a new owner scope with its identity, version,
--- and typed state intact. This is how carry-policy state follows a
--- replacement entry; unknown identities report nil instead of failing.
---@param id integer stable instance identity
---@param scope EffectScope the incoming owner scope
---@return EffectInstance? detached copy of the re-anchored instance, or nil when absent
function EffectBag:transfer(id, scope)
  assert(type(id) == "number", "instance transfer requires its identity")
  local record = self._records[id]
  if record == nil then
    return nil
  end
  record.scope = checkScope(scope)
  return detach(record)
end

--- Commits a new typed state record for one instance without touching its
--- identity, scope, or creation order. Unknown identities report false.
---@param id integer stable instance identity
---@param state table<string, unknown> replacement typed state, already definition-shaped
---@return boolean true when the state was committed
function EffectBag:commitState(id, state)
  assert(type(id) == "number", "state commitment requires its identity")
  local record = self._records[id]
  if record == nil then
    return false
  end
  if type(state) ~= "table" then
    error(BattleErrors.invalidState("committed effect state stays a record", { key = record.key }))
  end
  record.state = copyValue(state)
  return true
end

--- Captures every live instance as plain ordered data for suspension.
---@return EffectInstance[] detached records in creation order
function EffectBag:capture()
  local records = {}
  for _, record in pairs(self._records) do
    records[#records + 1] = record
  end
  table.sort(records, function(left, right)
    return left.createdOrdinal < right.createdOrdinal
  end)
  local out = {}
  for _, record in ipairs(records) do
    out[#out + 1] = detach(record)
  end
  return out
end

return EffectBag
