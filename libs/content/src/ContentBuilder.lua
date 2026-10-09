-- Startup-only ordered content composition. Contributors apply
-- definitions, patches, and aliases in declared application order; freezing
-- validates the complete composed definitions once and transfers a detached
-- immutable snapshot. A definition collision is an error naming both owners,
-- a patch requires an existing identity, and aliases resolve before lookup
-- and collision checks. Failed operations and failed freezes publish
-- nothing: the builder keeps its last valid state and the earlier snapshot,
-- when one exists, is never mutated. Freezing is idempotent, and any
-- definition, patch, or alias after a successful freeze fails.

local Errors = require("libs.errors.src.Errors")
local Registry = require("libs.content.src.Registry")

---@class ContentBuilder
---@field private _definitions table<string, table<string, table<string, unknown>>>
---@field private _owners table<string, table<string, string>>
---@field private _patches table<integer, table<string, unknown>>
---@field private _aliases table<string, table<string, table<string, string>>>
---@field private _frozen boolean
---@field private _snapshot table<string, unknown>?
local ContentBuilder = {}
ContentBuilder.__index = ContentBuilder

local MOVE_CATEGORIES = { physical = true, special = true, status = true }

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

---@return ContentBuilder
function ContentBuilder.new()
  return setmetatable({
    _definitions = {},
    _owners = {},
    _patches = {},
    _aliases = {},
    _frozen = false,
    _snapshot = nil,
  }, ContentBuilder)
end

---@param frozen boolean
---@param action string
local function requireOpen(frozen, action)
  if frozen then
    Errors.raise("CONTENT_FROZEN", "cannot " .. action .. " after freeze", {})
  end
end

---@param kind unknown
---@param key unknown
---@param owner unknown
local function checkIdentity(kind, key, owner)
  assert(type(kind) == "string" and kind ~= "", "content kind must be a non-empty string")
  assert(type(key) == "string" and key ~= "", "content key must be a non-empty string")
  assert(type(owner) == "string" and owner ~= "", "content owner must be a non-empty string")
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

---@param container table<string, table<string, table<string, string>>>
---@param kind string
---@return table<string, table<string, string>>
local function aliasesOf(container, kind)
  local aliases = container[kind]
  if aliases == nil then
    aliases = {}
    container[kind] = aliases
  end
  assert(aliases ~= nil, "the builder carries the kind table")
  return aliases
end

---@param aliases table<string, table<string, string>>?
---@param key string
---@return string?
local function aliasTargetOf(aliases, key)
  if aliases == nil then
    return nil
  end
  local entry = aliases[key]
  if entry == nil then
    return nil
  end
  return entry.target
end

---@param kind string
---@param key string
---@param owner string
---@param record table<string, unknown>
function ContentBuilder:define(kind, key, record, owner)
  checkIdentity(kind, key, owner)
  assert(type(record) == "table", "a content definition must be a record")
  -- Domain validation runs before the frozen gate so an invalid operation
  -- reports its most specific diagnostic even on a frozen builder; the
  -- frozen gate guards only otherwise-valid mutations.
  local definitions = definitionsOf(self._definitions, kind)
  if definitions[key] ~= nil then
    local first = self._owners[kind][key]
    assert(type(first) == "string", "every definition carries its owning contributor")
    Errors.raise("CONTENT_CONFLICT", "duplicate definition " .. kind .. " " .. key, {
      kind = kind,
      key = key,
      owner = first,
      newOwner = owner,
    })
  end
  if aliasTargetOf(self._aliases[kind], key) ~= nil then
    local first = assert(self._aliases[kind][key], "the alias table carries the validated entry").owner
    Errors.raise("CONTENT_CONFLICT", "definition " .. kind .. " " .. key .. " collides with an alias", {
      kind = kind,
      key = key,
      owner = first,
      newOwner = owner,
    })
  end
  requireOpen(self._frozen, "define " .. kind .. " " .. key)
  definitions[key] = copyValue(record)
  local owners = self._owners[kind]
  if owners == nil then
    owners = {}
    self._owners[kind] = owners
  end
  owners[key] = owner
end

---@param op unknown
---@param index integer
---@param owner string
local function checkPatchOp(op, index, owner)
  if type(op) ~= "table" then
    Errors.raise("CONTENT_INVALID", "patch operation " .. index .. " must be a record", { owner = owner })
  end
  assert(op ~= nil, "the patch carries the validated operation")
  if op.op ~= "set" and op.op ~= "remove" then
    Errors.raise("CONTENT_INVALID", "patch operation " .. index .. " must be set or remove", { owner = owner })
  end
  if type(op.path) ~= "table" then
    Errors.raise("CONTENT_INVALID", "patch operation " .. index .. " needs a non-empty path", { owner = owner })
  end
  local segments = 0
  for key in pairs(op.path) do
    if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
      Errors.raise("CONTENT_INVALID", "patch operation " .. index .. " carries an invalid path", { owner = owner })
    end
    segments = segments + 1
  end
  if segments == 0 or segments ~= #op.path then
    Errors.raise("CONTENT_INVALID", "patch operation " .. index .. " needs a non-empty path", { owner = owner })
  end
  for _, segment in ipairs(op.path) do
    if type(segment) ~= "string" and (type(segment) ~= "number" or segment % 1 ~= 0 or segment < 1) then
      Errors.raise("CONTENT_INVALID", "patch operation " .. index .. " carries an invalid path", { owner = owner })
    end
  end
  if op.op == "set" and op.value == nil then
    Errors.raise("CONTENT_INVALID", "patch set operation " .. index .. " needs a value", { owner = owner })
  end
  if op.op == "remove" and op.value ~= nil then
    Errors.raise("CONTENT_INVALID", "patch remove operation " .. index .. " carries no value", { owner = owner })
  end
end

---@param kind string
---@param key string
---@param ops table<integer, table<string, unknown>>
---@param owner string
function ContentBuilder:patch(kind, key, ops, owner)
  checkIdentity(kind, key, owner)
  assert(type(ops) == "table", "a content patch must carry its operations")
  for index, op in ipairs(ops) do
    checkPatchOp(op, index, owner)
  end
  local definitions = self._definitions[kind]
  if definitions == nil or (definitions[key] == nil and aliasTargetOf(self._aliases[kind], key) == nil) then
    Errors.raise("CONTENT_UNKNOWN", "patch names missing " .. kind .. " " .. key, {
      kind = kind,
      key = key,
      owner = owner,
    })
  end
  requireOpen(self._frozen, "patch " .. kind .. " " .. key)
  self._patches[#self._patches + 1] = { kind = kind, key = key, ops = copyValue(ops), owner = owner }
end

---@param kind string
---@param oldKey string
---@param key string
---@param owner string
function ContentBuilder:alias(kind, oldKey, key, owner)
  checkIdentity(kind, oldKey, owner)
  assert(type(key) == "string" and key ~= "", "an alias destination must be a non-empty string")
  if oldKey == key then
    Errors.raise("CONTENT_ALIAS_CYCLE", "alias " .. kind .. " " .. oldKey .. " names itself", {
      kind = kind,
      key = oldKey,
      owner = owner,
    })
  end
  local definitions = self._definitions[kind]
  if definitions ~= nil and definitions[oldKey] ~= nil then
    local first = self._owners[kind][oldKey]
    assert(type(first) == "string", "every definition carries its owning contributor")
    Errors.raise("CONTENT_CONFLICT", "alias " .. kind .. " " .. oldKey .. " collides with a definition", {
      kind = kind,
      key = oldKey,
      owner = first,
      newOwner = owner,
    })
  end
  local aliases = aliasesOf(self._aliases, kind)
  if aliases[oldKey] ~= nil then
    Errors.raise("CONTENT_CONFLICT", "duplicate alias " .. kind .. " " .. oldKey, {
      kind = kind,
      key = oldKey,
      owner = aliases[oldKey].owner,
      newOwner = owner,
    })
  end
  requireOpen(self._frozen, "alias " .. kind .. " " .. oldKey)
  aliases[oldKey] = { target = key, owner = owner }
end

---@param record table<string, unknown>
---@param path table<integer, string|integer>
---@param value unknown
---@param context table<string, unknown>
local function applySet(record, path, value, context)
  local node = record
  for position = 1, #path - 1 do
    local segment = path[position]
    local nextNode = node[segment]
    if nextNode == nil then
      nextNode = {}
      node[segment] = nextNode
    end
    if type(nextNode) ~= "table" then
      Errors.raise("CONTENT_INVALID", "patch path crosses a scalar value", context)
    end
    node = nextNode
  end
  node[path[#path]] = copyValue(value)
end

---@param record table<string, unknown>
---@param path table<integer, string|integer>
---@param context table<string, unknown>
local function applyRemove(record, path, context)
  local node = record
  for position = 1, #path - 1 do
    local nextNode = node[path[position]]
    if type(nextNode) ~= "table" then
      Errors.raise("CONTENT_INVALID", "patch remove names a missing path", context)
    end
    node = nextNode
  end
  if node[path[#path]] == nil then
    Errors.raise("CONTENT_INVALID", "patch remove names a missing path", context)
  end
  node[path[#path]] = nil
end

---@param aliases table<string, table<string, string>>
---@param key string
---@param context table<string, unknown>
---@return string the canonical definition key
local function resolveAlias(aliases, key, context)
  local seen = {}
  local current = key
  while true do
    local entry = aliases[current]
    if entry == nil then
      return current
    end
    if seen[current] then
      Errors.raise("CONTENT_ALIAS_CYCLE", "alias cycle reaches " .. current, context)
    end
    seen[current] = true
    current = entry.target
  end
end

---@param value unknown
---@param field string
---@param context table<string, unknown>
local function checkInteger(value, field, context)
  if type(value) ~= "number" or value % 1 ~= 0 then
    Errors.raise("CONTENT_INVALID", field .. " must be an integer", context)
  end
end

---@param value unknown
---@param field string
---@param context table<string, unknown>
local function checkText(value, field, context)
  if type(value) ~= "string" or value == "" then
    Errors.raise("CONTENT_INVALID", field .. " must be a non-empty string", context)
  end
end

---@param key string
---@param record table<string, unknown>
-- Composed move numbers admit any finite integral count the runtime can
-- represent: power, PP, and accuracy stay non-negative, priority stays
-- signed, and non-integers never pass. Native field widths stay with the
-- producer and the save codec, which still reject what they cannot encode.
local function assertMove(key, record)
  local context = { kind = "moves", key = key }
  if record.key ~= key then
    Errors.raise("CONTENT_INVALID", "move " .. key .. " carries a mismatched key", context)
  end
  checkText(record.name, "move " .. key .. " name", context)
  if type(record.description) ~= "string" then
    Errors.raise("CONTENT_INVALID", "move " .. key .. " description must be a string", context)
  end
  checkText(record.moveType, "move " .. key .. " moveType", context)
  if MOVE_CATEGORIES[record.category] == nil then
    Errors.raise("CONTENT_INVALID", "move " .. key .. " has an unknown category", context)
  end
  checkInteger(record.power, "move " .. key .. " power", context)
  if record.power < 0 or record.power > 9007199254740991 then
    Errors.raise("CONTENT_INVALID", "move " .. key .. " power must be 0..9007199254740991", context)
  end
  checkInteger(record.basePp, "move " .. key .. " basePp", context)
  if record.basePp < 0 or record.basePp > 9007199254740991 then
    Errors.raise("CONTENT_INVALID", "move " .. key .. " basePp must be 0..9007199254740991", context)
  end
  if record.accuracy ~= nil then
    checkInteger(record.accuracy, "move " .. key .. " accuracy", context)
    if record.accuracy < 0 or record.accuracy > 9007199254740991 then
      Errors.raise("CONTENT_INVALID", "move " .. key .. " accuracy must be 0..9007199254740991", context)
    end
  end
  checkInteger(record.priority, "move " .. key .. " priority", context)
  if record.priority < -9007199254740991 or record.priority > 9007199254740991 then
    Errors.raise("CONTENT_INVALID", "move " .. key .. " priority must be -9007199254740991..9007199254740991", context)
  end
  checkText(record.target, "move " .. key .. " target", context)
  if type(record.flags) ~= "table" then
    Errors.raise("CONTENT_INVALID", "move " .. key .. " flags must be a record", context)
  end
  if type(record.behavior) ~= "table" or type(record.behavior.key) ~= "string" or record.behavior.key == "" then
    Errors.raise("CONTENT_INVALID", "move " .. key .. " behavior must name its key", context)
  end
end

---@param key string
---@param record table<string, unknown>
local function assertTypeShape(key, record)
  local context = { kind = "types", key = key }
  if record.key ~= key then
    Errors.raise("CONTENT_INVALID", "type " .. key .. " carries a mismatched key", context)
  end
  checkText(record.name, "type " .. key .. " name", context)
  if record.nativeId ~= nil then
    checkInteger(record.nativeId, "type " .. key .. " nativeId", context)
    if record.nativeId < 0 then
      Errors.raise("CONTENT_INVALID", "type " .. key .. " nativeId must be non-negative", context)
    end
  end
  if type(record.relations) ~= "table" then
    Errors.raise("CONTENT_INVALID", "type " .. key .. " must carry its relations", context)
  end
  for index, relation in ipairs(record.relations) do
    if type(relation) ~= "table" then
      Errors.raise("CONTENT_INVALID", "type " .. key .. " relation " .. index .. " must be a record", context)
    end
    checkText(relation.attack, "type " .. key .. " relation " .. index .. " attack", context)
    checkText(relation.defend, "type " .. key .. " relation " .. index .. " defend", context)
    checkInteger(relation.numerator, "type " .. key .. " relation " .. index .. " numerator", context)
    if relation.numerator < 0 then
      Errors.raise(
        "CONTENT_INVALID",
        "type " .. key .. " relation " .. index .. " numerator must be non-negative",
        context
      )
    end
    checkInteger(relation.denominator, "type " .. key .. " relation " .. index .. " denominator", context)
    if relation.denominator <= 0 then
      Errors.raise(
        "CONTENT_INVALID",
        "type " .. key .. " relation " .. index .. " denominator must stay positive",
        context
      )
    end
  end
end

---@param definitions table<string, table<string, unknown>>
local function assertTypeChart(definitions)
  local union = {}
  for key, record in pairs(definitions) do
    assertTypeShape(key, record)
    local relations = assert(record.relations, "the shape check carries the validated relations")
    for _, relation in ipairs(relations) do
      if definitions[relation.attack] == nil or definitions[relation.defend] == nil then
        Errors.raise("CONTENT_INVALID", "type relation names an unknown type", {
          kind = "types",
          attack = relation.attack,
          defend = relation.defend,
        })
      end
      local pair = relation.attack .. "\0" .. relation.defend
      local seen = union[pair]
      if seen ~= nil then
        if seen.numerator ~= relation.numerator or seen.denominator ~= relation.denominator then
          Errors.raise("CONTENT_CONFLICT", "type relation conflicts for one directed pair", {
            kind = "types",
            attack = relation.attack,
            defend = relation.defend,
          })
        end
      else
        union[pair] = { numerator = relation.numerator, denominator = relation.denominator }
      end
    end
  end
  -- Omitted known-known directed pairs stay sparse here: they resolve
  -- to neutral at chart construction instead of failing the freeze.
end

---@param definitionsByKind table<string, table<string, table<string, unknown>>>
---@param aliasesByKind table<string, table<string, table<string, string>>>
---@param patches table<integer, table<string, unknown>>
---@param ownersByKind table<string, table<string, string>>
---@return table<string, table<string, table<string, unknown>>> working copies with patches applied
---@return table<string, table<string, string>> working provenance copies with patch owners applied
local function composedDefinitions(definitionsByKind, aliasesByKind, patches, ownersByKind)
  local composed = {}
  local owners = {}
  for kind, definitions in pairs(definitionsByKind) do
    local kindCopy = {}
    for key, record in pairs(definitions) do
      kindCopy[key] = copyValue(record)
    end
    composed[kind] = kindCopy
    local ownerCopy = {}
    for key, owner in pairs(ownersByKind[kind] or {}) do
      ownerCopy[key] = owner
    end
    owners[kind] = ownerCopy
  end
  for _, patch in ipairs(patches) do
    local aliases = aliasesByKind[patch.kind] or {}
    local canonical = resolveAlias(aliases, patch.key, { kind = patch.kind, key = patch.key, owner = patch.owner })
    local record = composed[patch.kind][canonical]
    if record == nil then
      Errors.raise("CONTENT_UNKNOWN", "patch names missing " .. patch.kind .. " " .. patch.key, {
        kind = patch.kind,
        key = patch.key,
        owner = patch.owner,
      })
    end
    assert(record ~= nil, "the missing-target check carries the validated record")
    local recordOwners = owners[patch.kind]
    assert(recordOwners ~= nil, "the definition carries its provenance table")
    for _, op in ipairs(patch.ops) do
      local context = { kind = patch.kind, key = canonical, owner = patch.owner }
      if op.op == "set" then
        applySet(record, op.path, op.value, context)
      else
        applyRemove(record, op.path, context)
      end
    end
    recordOwners[canonical] = patch.owner
  end
  return composed, owners
end

---@param kind string
---@param definitions table<string, table<string, unknown>>
local function assertComposedKind(kind, definitions)
  if kind == "moves" then
    for key, record in pairs(definitions) do
      assertMove(key, record)
    end
  elseif kind == "types" then
    assertTypeChart(definitions)
  else
    for key, record in pairs(definitions) do
      if type(record) ~= "table" then
        Errors.raise("CONTENT_INVALID", kind .. " " .. key .. " must be a record", { kind = kind, key = key })
      end
    end
  end
end

---@param kind string
---@param definitions table<string, table<string, unknown>>
---@return table<integer, string> native index carrying only declared identities
local function nativeIndexOf(kind, definitions)
  local byNative = {}
  for key, record in pairs(definitions) do
    local nativeId = record.nativeId
    if nativeId ~= nil then
      if type(nativeId) ~= "number" or nativeId % 1 ~= 0 then
        Errors.raise("CONTENT_INVALID", kind .. " " .. key .. " nativeId must be an integer", {
          kind = kind,
          key = key,
        })
      end
      if byNative[nativeId] ~= nil then
        Errors.raise("CONTENT_CONFLICT", "duplicate native identity in " .. kind, {
          kind = kind,
          key = key,
          nativeId = nativeId,
        })
      end
      byNative[nativeId] = key
    end
  end
  return byNative
end

---@class ResolvedContent
---@field private _registries table<string, Registry>
local ResolvedContent = {}
ResolvedContent.__index = ResolvedContent

---@param kind string
---@return Registry the registry for the composed kind
function ResolvedContent:_registryFor(kind)
  local registry = self._registries[kind]
  if registry == nil then
    Errors.raise("CONTENT_UNKNOWN", "unknown content kind " .. kind, { kind = kind })
  end
  assert(registry ~= nil, "the kind check carries the validated registry")
  return registry
end

---@param kind string
---@param key string
---@return table<string, unknown> a detached copy of the resolved definition
function ResolvedContent:get(kind, key)
  assert(type(kind) == "string", "content lookup requires its kind")
  return self:_registryFor(kind):get(key)
end

---@param kind string
---@return string[] the sorted defined keys of the composed kind
function ResolvedContent:keys(kind)
  assert(type(kind) == "string", "content lookup requires its kind")
  return self:_registryFor(kind):keys()
end

---@return string[] the sorted composed kind names
function ResolvedContent:kinds()
  local out = {}
  for kind in pairs(self._registries) do
    out[#out + 1] = kind
  end
  table.sort(out)
  return out
end

---@param kind string
---@param key string
---@return table<string, string> a detached provenance record naming the owning contributor
function ResolvedContent:provenance(kind, key)
  assert(type(kind) == "string", "content lookup requires its kind")
  return self:_registryFor(kind):provenance(key)
end

---@return ResolvedContent the detached immutable snapshot of the composition
function ContentBuilder:freeze()
  if self._frozen then
    assert(self._snapshot ~= nil, "a frozen builder carries its snapshot")
    return self._snapshot
  end
  -- Alias destinations must resolve to defined keys; cycles fail here when
  -- they were not already rejected at declaration.
  for kind, aliases in pairs(self._aliases) do
    local definitions = self._definitions[kind] or {}
    for oldKey, entry in pairs(aliases) do
      local canonical = resolveAlias(aliases, entry.target, { kind = kind, key = oldKey, owner = entry.owner })
      if definitions[canonical] == nil then
        Errors.raise("CONTENT_UNKNOWN", "alias " .. kind .. " " .. oldKey .. " names a missing identity", {
          kind = kind,
          key = oldKey,
          target = entry.target,
          owner = entry.owner,
        })
      end
    end
  end
  local composed, owners = composedDefinitions(self._definitions, self._aliases, self._patches, self._owners)
  for kind, definitions in pairs(composed) do
    assertComposedKind(kind, definitions)
  end
  local registries = {}
  for kind, definitions in pairs(composed) do
    local plainAliases = {}
    for oldKey, entry in pairs(self._aliases[kind] or {}) do
      plainAliases[oldKey] = entry.target
    end
    registries[kind] =
      Registry.new(kind, definitions, plainAliases, owners[kind] or {}, nativeIndexOf(kind, definitions))
  end
  local snapshot = setmetatable({ _registries = registries }, ResolvedContent)
  self._frozen = true
  self._snapshot = snapshot
  return snapshot
end

return ContentBuilder
