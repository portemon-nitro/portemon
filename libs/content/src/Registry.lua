-- Frozen semantic identity lookup for one composed content kind. The
-- registry takes ownership of detached definition, alias, provenance, and
-- native-index tables at construction and never mutates them afterwards.
-- Key spelling is preserved exactly; declared aliases canonicalize to their
-- definition before lookup. Getters return deep copies so callers cannot
-- mutate the frozen composition. The native index carries only declared
-- numeric identities; entries without one resolve semantically only.

local Errors = require("libs.errors.src.Errors")

---@class Registry
---@field private _kind string
---@field private _definitions table<string, table<string, unknown>>
---@field private _aliases table<string, string>
---@field private _owners table<string, string>
---@field private _byNative table<integer, string>
local Registry = {}
Registry.__index = Registry

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

---@param kind unknown
---@param definitions table<string, table<string, unknown>>?
---@param aliases table<string, string>?
---@param owners table<string, string>?
---@param byNative table<integer, string>?
---@return Registry
function Registry.new(kind, definitions, aliases, owners, byNative)
  assert(type(kind) == "string" and kind ~= "", "a registry requires its content kind")
  local self = setmetatable({
    _kind = kind,
    _definitions = copyValue(definitions or {}),
    _aliases = copyValue(aliases or {}),
    _owners = copyValue(owners or {}),
    _byNative = copyValue(byNative or {}),
  }, Registry)
  return self
end

---@param key string
---@return string the canonical definition key after alias resolution
function Registry:resolve(key)
  assert(type(key) == "string", "registry lookup requires a string key")
  local seen = {}
  local current = key
  while true do
    if self._definitions[current] ~= nil then
      return current
    end
    local target = self._aliases[current]
    if target == nil then
      Errors.raise("CONTENT_UNKNOWN", "unknown " .. self._kind .. " " .. key, { kind = self._kind, key = key })
    end
    assert(target ~= nil, "the alias table carries the validated target")
    if seen[current] then
      Errors.raise(
        "CONTENT_ALIAS_CYCLE",
        "alias cycle reaches " .. self._kind .. " " .. key,
        { kind = self._kind, key = key }
      )
    end
    seen[current] = true
    current = target
  end
end

---@param key string
---@return table<string, unknown> a detached copy of the resolved definition
function Registry:get(key)
  local canonical = self:resolve(key)
  local definition = self._definitions[canonical]
  assert(definition ~= nil, "resolution carries the validated definition")
  return copyValue(definition)
end

---@return string[] the sorted defined keys; alias names are not definitions
function Registry:keys()
  local out = {}
  for key in pairs(self._definitions) do
    out[#out + 1] = key
  end
  table.sort(out)
  return out
end

---@param nativeId integer
---@return string the semantic key carrying the declared numeric identity
function Registry:nativeKey(nativeId)
  local key = self._byNative[nativeId]
  if key == nil then
    Errors.raise(
      "CONTENT_UNKNOWN",
      "unknown native " .. self._kind .. " identity " .. tostring(nativeId),
      { kind = self._kind, nativeId = nativeId }
    )
  end
  assert(key ~= nil, "the native index carries the validated key")
  return key
end

---@param key string
---@return table<string, string> a detached provenance record naming the owning contributor
function Registry:provenance(key)
  local canonical = self:resolve(key)
  local owner = self._owners[canonical]
  assert(type(owner) == "string", "every definition carries its owning contributor")
  return { owner = owner }
end

return Registry
