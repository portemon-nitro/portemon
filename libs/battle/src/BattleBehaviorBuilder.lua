-- Typed battle behavior, action, effect, format, and ruleset
-- registration. Kinds stay separate: the same key may exist once per kind,
-- and a duplicate within one kind is an error naming both owners. Behavior
-- definitions stay symbolic (a callable module path plus a versioned state
-- contract); freezing validates shapes and transfers detached immutable
-- registries without loading implementation modules. Mechanics timing is
-- owned by the session layer later, never by contribution order here.
-- Registration after a successful freeze fails; freezing is idempotent.

local Errors = require("libs.errors.src.Errors")
local Registry = require("libs.content.src.Registry")

---@class BattleBehaviorBuilder
---@field private _definitions table<string, table<string, table<string, unknown>>>
---@field private _owners table<string, table<string, string>>
---@field private _frozen boolean
---@field private _bound table<string, unknown>?
local BattleBehaviorBuilder = {}
BattleBehaviorBuilder.__index = BattleBehaviorBuilder

local BEHAVIOR_KINDS = { moves = true, effects = true, actions = true, formats = true, rulesets = true }

---@return BattleBehaviorBuilder
function BattleBehaviorBuilder.new()
  return setmetatable({
    _definitions = {},
    _owners = {},
    _frozen = false,
    _bound = nil,
  }, BattleBehaviorBuilder)
end

---@param frozen boolean
---@param action string
local function requireOpen(frozen, action)
  if frozen then
    Errors.raise("BATTLE_FROZEN", "cannot " .. action .. " after freeze", {})
  end
end

---@param container table<string, table<string, table<string, unknown>>>
---@param kind string
---@return table<string, table<string, unknown>>
local function definitionsOf(container, kind)
  local definitions = container[kind]
  if definitions == nil then
    definitions = {}
    container[kind] = definitions
  end
  assert(definitions ~= nil, "the builder carries the kind table")
  return definitions
end

---@param kind string
---@param key string
---@param definition unknown
---@param owner string
local function checkEntry(kind, key, definition, owner)
  assert(type(kind) == "string", "behavior registration requires its kind")
  assert(type(key) == "string" and key ~= "", "behavior registration requires a non-empty key")
  assert(type(owner) == "string" and owner ~= "", "behavior registration requires its owner")
  if type(definition) ~= "table" then
    Errors.raise("BATTLE_INVALID", kind .. " " .. key .. " must be a record", { kind = kind, key = key, owner = owner })
  end
end

---@param kind string
---@param key string
---@param definition table<string, unknown>
---@param owner string
local function assertCallableBehavior(kind, key, definition, owner)
  local context = { kind = kind, key = key, owner = owner }
  if type(definition.module) ~= "string" or definition.module == "" then
    Errors.raise("BATTLE_INVALID", kind .. " " .. key .. " must name its callable module", context)
  end
  if type(definition.version) ~= "number" or definition.version % 1 ~= 0 or definition.version < 1 then
    Errors.raise("BATTLE_INVALID", kind .. " " .. key .. " must carry a positive integer version", context)
  end
  for _, field in ipairs({ "parameters", "state" }) do
    if definition[field] ~= nil and type(definition[field]) ~= "table" then
      Errors.raise("BATTLE_INVALID", kind .. " " .. key .. " " .. field .. " must be a record", context)
    end
  end
end

---@param kind string
---@param key string
---@param definition table<string, unknown>
---@param owner string
local function assertNamedBinding(kind, key, definition, owner)
  local context = { kind = kind, key = key, owner = owner }
  if definition.key ~= key then
    Errors.raise("BATTLE_INVALID", kind .. " " .. key .. " carries a mismatched key", context)
  end
  if definition.chart ~= nil and (type(definition.chart) ~= "string" or definition.chart == "") then
    Errors.raise("BATTLE_INVALID", kind .. " " .. key .. " chart must be a non-empty string", context)
  end
end

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

---@param kind string
---@param key string
---@param definition table<string, unknown>
---@param owner string
---@param validate fun(kind: string, key: string, definition: table<string, unknown>, owner: string)
function BattleBehaviorBuilder:_register(kind, key, definition, owner, validate)
  checkEntry(kind, key, definition, owner)
  assert(definition ~= nil, "the entry check carries the validated record")
  validate(kind, key, definition, owner)
  local definitions = definitionsOf(self._definitions, kind)
  if definitions[key] ~= nil then
    local first = self._owners[kind][key]
    assert(type(first) == "string", "every behavior carries its owning contributor")
    Errors.raise("BATTLE_CONFLICT", "duplicate behavior " .. kind .. " " .. key, {
      kind = kind,
      key = key,
      owner = first,
      newOwner = owner,
    })
  end
  requireOpen(self._frozen, "register " .. kind .. " " .. key)
  definitions[key] = copyValue(definition)
  local owners = self._owners[kind]
  if owners == nil then
    owners = {}
    self._owners[kind] = owners
  end
  owners[key] = owner
end

---@param key string
---@param definition table<string, unknown>
---@param owner string
function BattleBehaviorBuilder:registerMove(key, definition, owner)
  self:_register("moves", key, definition, owner, assertCallableBehavior)
end

---@param key string
---@param definition table<string, unknown>
---@param owner string
function BattleBehaviorBuilder:registerEffect(key, definition, owner)
  self:_register("effects", key, definition, owner, assertCallableBehavior)
end

---@param key string
---@param definition table<string, unknown>
---@param owner string
function BattleBehaviorBuilder:registerAction(key, definition, owner)
  self:_register("actions", key, definition, owner, assertCallableBehavior)
end

---@param key string
---@param definition table<string, unknown>
---@param owner string
function BattleBehaviorBuilder:registerFormat(key, definition, owner)
  self:_register("formats", key, definition, owner, assertNamedBinding)
end

---@param key string
---@param definition table<string, unknown>
---@param owner string
function BattleBehaviorBuilder:registerRuleset(key, definition, owner)
  self:_register("rulesets", key, definition, owner, assertNamedBinding)
end

---@class BoundBehaviors
---@field private _registries table<string, Registry>
local BoundBehaviors = {}
BoundBehaviors.__index = BoundBehaviors

---@param kind string
---@return Registry the registry for the behavior kind
function BoundBehaviors:_registryFor(kind)
  if BEHAVIOR_KINDS[kind] == nil then
    Errors.raise("BATTLE_INVALID", "unknown behavior kind " .. kind, { kind = kind })
  end
  local registry = self._registries[kind]
  if registry == nil then
    Errors.raise("BATTLE_UNKNOWN", "unknown behavior kind " .. kind, { kind = kind })
  end
  assert(registry ~= nil, "the kind check carries the validated registry")
  return registry
end

---@param kind string
---@param key string
---@return table<string, unknown> a detached copy of the bound behavior definition
function BoundBehaviors:get(kind, key)
  return self:_registryFor(kind):get(key)
end

---@param kind string
---@return string[] the sorted registered keys of the behavior kind
function BoundBehaviors:keys(kind)
  return self:_registryFor(kind):keys()
end

---@return BoundBehaviors the frozen bound behavior registries
function BattleBehaviorBuilder:freeze()
  if self._frozen then
    assert(self._bound ~= nil, "a frozen builder carries its bound behaviors")
    return self._bound
  end
  local registries = {}
  for kind in pairs(BEHAVIOR_KINDS) do
    local definitions = {}
    for key, definition in pairs(self._definitions[kind] or {}) do
      definitions[key] = definition
    end
    local owners = {}
    for key, owner in pairs(self._owners[kind] or {}) do
      owners[key] = owner
    end
    registries[kind] = Registry.new(kind, definitions, {}, owners, {})
  end
  local bound = setmetatable({ _registries = registries }, BoundBehaviors)
  self._frozen = true
  self._bound = bound
  return bound
end

return BattleBehaviorBuilder
