-- Immutable resolved mon definitions. The constructor borrows the
-- already-published generated asset root read-only for the catalog's
-- lifetime (callers must treat the root as immutable and keep it alive as
-- long as the catalog) plus the shared item catalog, and indexes semantic
-- and native identities. Item identity is never copied here: item lookups
-- delegate to the injected catalog. Lookups never mutate and never reach
-- source formats: native numeric identities stay only because exact native
-- encoding gives them current use.

local MonsErrors = require("libs.mons.src.errors")
local ResolvedMonSchema = require("libs.mons.src.ResolvedMonSchema")

---@class MonCatalog
---@field private _root table<string, unknown>
---@field private _items table<string, unknown> the shared item catalog behind item lookups
---@field private _speciesByNative table<integer, string>
---@field private _moveByNative table<integer, string>
---@field private _abilityByNative table<integer, string>
local MonCatalog = {}
MonCatalog.__index = MonCatalog

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

-- Index builder for composed catalogs: entries without a declared numeric
-- identity resolve semantically only and never occupy the native index,
-- while duplicate declared identities fail loudly.
---@param owned table<string, unknown>
---@return table<integer, string> speciesByNative
---@return table<integer, string> moveByNative
---@return table<integer, string> abilityByNative
local function buildComposedIndexes(owned)
  local indexes = { species = {}, moves = {}, abilities = {} }
  local sections = {
    { records = owned.species, index = indexes.species, what = "species" },
    { records = owned.moves, index = indexes.moves, what = "move" },
    { records = owned.abilities, index = indexes.abilities, what = "ability" },
  }
  for _, section in ipairs(sections) do
    for key, record in pairs(section.records) do
      local nativeId = record.nativeId
      if nativeId ~= nil then
        if section.index[nativeId] ~= nil then
          MonsErrors.raise(
            MonsErrors.RECORD_INVALID,
            "duplicate native " .. section.what .. " identity " .. tostring(nativeId),
            { [section.what] = key }
          )
        end
        section.index[nativeId] = key
      end
    end
  end
  return indexes.species, indexes.moves, indexes.abilities
end

---@param root table<string, unknown> borrowed published generated root; the caller keeps it alive and immutable for the catalog's lifetime
---@param items table<string, unknown> shared item catalog; item lookups delegate to it
---@return MonCatalog
function MonCatalog.new(root, items)
  assert(type(root) == "table", "MonCatalog requires the generated asset root")
  assert(
    type(items) == "table"
      and type(items.item) == "function"
      and type(items.itemByNativeId) == "function"
      and type(items.itemKeyByNativeId) == "function",
    "MonCatalog requires the shared item catalog"
  )
  assert(type(root.species) == "table", "MonCatalog requires the species table")
  assert(type(root.moves) == "table", "MonCatalog requires the moves table")
  assert(type(root.abilities) == "table", "MonCatalog requires the abilities table")
  assert(type(root.growthCurves) == "table", "MonCatalog requires the growth curves table")
  local self = setmetatable({
    _root = root,
    _items = items,
    _speciesByNative = {},
    _moveByNative = {},
    _abilityByNative = {},
  }, MonCatalog)
  for key, species in pairs(root.species) do
    if self._speciesByNative[species.nativeId] ~= nil then
      MonsErrors.raise(
        MonsErrors.RECORD_INVALID,
        "duplicate native species identity " .. tostring(species.nativeId),
        { species = key }
      )
    end
    self._speciesByNative[species.nativeId] = key
  end
  for key, move in pairs(root.moves) do
    if self._moveByNative[move.nativeId] ~= nil then
      MonsErrors.raise(
        MonsErrors.RECORD_INVALID,
        "duplicate native move identity " .. tostring(move.nativeId),
        { move = key }
      )
    end
    self._moveByNative[move.nativeId] = key
  end
  for key, ability in pairs(root.abilities) do
    if self._abilityByNative[ability.nativeId] ~= nil then
      MonsErrors.raise(
        MonsErrors.RECORD_INVALID,
        "duplicate native ability identity " .. tostring(ability.nativeId),
        { ability = key }
      )
    end
    self._abilityByNative[ability.nativeId] = key
  end
  return self
end

-- Composed catalog construction: validates through the resolved schema so
-- namespaced custom entries without numeric identities resolve, then shares
-- the single lookup implementation with native construction. The owned root
-- is detached from the caller.
---@param root table<string, unknown>
---@param items table<string, unknown> shared item catalog; item lookups delegate to it
---@return MonCatalog
function MonCatalog.fromResolved(root, items)
  assert(type(root) == "table", "MonCatalog requires the generated asset root")
  assert(
    type(items) == "table"
      and type(items.item) == "function"
      and type(items.itemByNativeId) == "function"
      and type(items.itemKeyByNativeId) == "function",
    "MonCatalog requires the shared item catalog"
  )
  ResolvedMonSchema.assertCatalog(root)
  local owned = copyValue(root)
  local speciesByNative, moveByNative, abilityByNative = buildComposedIndexes(owned)
  return setmetatable({
    _root = owned,
    _items = items,
    _speciesByNative = speciesByNative,
    _moveByNative = moveByNative,
    _abilityByNative = abilityByNative,
  }, MonCatalog)
end

-- Lookups below return the borrowed published records themselves: callers
-- must not mutate or retain them beyond the catalog's lifetime. Fresh
-- tables are built only where a method assembles a new collection
-- (speciesKeys, moveKeys); those are caller-owned.

---@return string[] caller-owned species keys in native identity order
function MonCatalog:speciesKeys()
  local keys = {}
  for key in pairs(self._root.species) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(a, b)
    local aId = self._root.species[a].nativeId
    local bId = self._root.species[b].nativeId
    return aId == bId and a < b or aId < bId
  end)
  return keys
end

---@param key string
---@return table<string, unknown>
function MonCatalog:species(key)
  assert(type(key) == "string", "species lookup requires a string key")
  local definition = self._root.species[key]
  if definition == nil then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "unknown species " .. key, { species = key })
  end
  assert(definition ~= nil, "catalog index carries the validated entry")
  return definition
end

---@param nativeId integer
---@return string
function MonCatalog:speciesKeyByNativeId(nativeId)
  local key = self._speciesByNative[nativeId]
  if key == nil then
    MonsErrors.raise(
      MonsErrors.RECORD_INVALID,
      "unknown native species identity " .. tostring(nativeId),
      { nativeId = nativeId }
    )
  end
  assert(key ~= nil, "catalog index carries the validated entry")
  return key
end

---@param nativeId integer
---@return table<string, unknown>
function MonCatalog:speciesByNativeId(nativeId)
  return self._root.species[self:speciesKeyByNativeId(nativeId)]
end

---@param speciesKey string
---@param form integer
---@return table<string, unknown>
function MonCatalog:form(speciesKey, form)
  local definition = self:species(speciesKey)
  local formDefinition = definition.forms[form]
  if formDefinition == nil then
    MonsErrors.raise(
      MonsErrors.RECORD_INVALID,
      "unknown form " .. tostring(form) .. " for species " .. speciesKey,
      { species = speciesKey, form = form }
    )
  end
  assert(formDefinition ~= nil, "catalog index carries the validated entry")
  return formDefinition
end

---@param key string
---@return table<string, unknown>
function MonCatalog:move(key)
  assert(type(key) == "string", "move lookup requires a string key")
  local definition = self._root.moves[key]
  if definition == nil then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "unknown move " .. key, { move = key })
  end
  assert(definition ~= nil, "catalog index carries the validated entry")
  return definition
end

---@param nativeId integer
---@return string
function MonCatalog:moveKeyByNativeId(nativeId)
  local key = self._moveByNative[nativeId]
  if key == nil then
    MonsErrors.raise(
      MonsErrors.RECORD_INVALID,
      "unknown native move identity " .. tostring(nativeId),
      { nativeId = nativeId }
    )
  end
  assert(key ~= nil, "catalog index carries the validated entry")
  return key
end

---@return string[] caller-owned move keys in native identity order
function MonCatalog:moveKeys()
  local keys = {}
  for key in pairs(self._root.moves) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(a, b)
    local aId = self._root.moves[a].nativeId
    local bId = self._root.moves[b].nativeId
    return aId == bId and a < b or aId < bId
  end)
  return keys
end

---@param nativeId integer
---@return table<string, unknown>
function MonCatalog:moveByNativeId(nativeId)
  return self._root.moves[self:moveKeyByNativeId(nativeId)]
end

---@param key string
---@return table<string, unknown>
function MonCatalog:ability(key)
  assert(type(key) == "string", "ability lookup requires a string key")
  local definition = self._root.abilities[key]
  if definition == nil then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "unknown ability " .. key, { ability = key })
  end
  assert(definition ~= nil, "catalog index carries the validated entry")
  return definition
end

---@param nativeId integer
---@return string
function MonCatalog:abilityKeyByNativeId(nativeId)
  local key = self._abilityByNative[nativeId]
  if key == nil then
    MonsErrors.raise(
      MonsErrors.RECORD_INVALID,
      "unknown native ability identity " .. tostring(nativeId),
      { nativeId = nativeId }
    )
  end
  assert(key ~= nil, "catalog index carries the validated entry")
  return key
end

---@param nativeId integer
---@return table<string, unknown>
function MonCatalog:abilityByNativeId(nativeId)
  return self._root.abilities[self:abilityKeyByNativeId(nativeId)]
end

-- Item lookups delegate to the injected shared catalog; this package owns
-- no second item store.
---@param key string
---@return table<string, unknown>
function MonCatalog:item(key)
  return self._items:item(key)
end

---@param nativeId integer
---@return string
function MonCatalog:itemKeyByNativeId(nativeId)
  return self._items:itemKeyByNativeId(nativeId)
end

---@param nativeId integer
---@return table<string, unknown>
function MonCatalog:itemByNativeId(nativeId)
  return self._items:itemByNativeId(nativeId)
end

---@param key string
---@return integer[]
function MonCatalog:growthCurve(key)
  assert(type(key) == "string", "growth curve lookup requires a string key")
  local curve = self._root.growthCurves[key]
  if curve == nil then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "unknown growth curve " .. key, { curve = key })
  end
  assert(curve ~= nil, "catalog index carries the validated entry")
  return curve
end

---@param selector table<string, unknown>
---@return table<string, unknown>
local function formOfSelector(self, selector)
  assert(type(selector) == "table", "form selection requires a mon or selector record")
  return self:form(selector.species, selector.form)
end

---@param monOrSelector table<string, unknown>
---@return string
function MonCatalog:iconSelection(monOrSelector)
  return formOfSelector(self, monOrSelector).icon
end

---@param monOrSelector table<string, unknown>
---@return string
function MonCatalog:portraitSelection(monOrSelector)
  return formOfSelector(self, monOrSelector).portrait
end

---@param monOrSelector table<string, unknown>
---@return table<string, unknown>?
function MonCatalog:followerSelection(monOrSelector)
  return formOfSelector(self, monOrSelector).follower
end

return MonCatalog
