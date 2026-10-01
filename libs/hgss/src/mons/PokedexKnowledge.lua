-- Minimal Pokedex knowledge: the seen/caught flags battle rules need
-- (repeat-ball eligibility, caught registration) without the Pokedex
-- application. Knowledge is semantic species keys from the resolved game
-- content; unknown keys fail instead of recording. Caught registration
-- means the game recorded a capture, not that any storage holds the mon.
-- Changes stage as one-use candidates and publish exactly once through
-- the same prepared-candidate convention as the party and bag owners, so
-- battle results commit dex facts together with everything else.

local Errors = require("libs.errors.src.Errors")

---@class PokedexKnowledge
---@field private _allowed table<string, boolean>
---@field private _seen table<string, boolean>
---@field private _caught table<string, boolean>
---@field private _revision integer
local PokedexKnowledge = {}
PokedexKnowledge.__index = PokedexKnowledge

---@param species unknown
---@return table<string, boolean>
local function checkSpeciesSet(species)
  if type(species) ~= "table" then
    Errors.raise("POKEDEX_INVALID", "dex knowledge requires a resolved species set", {})
  end
  local allowed = {}
  for key, known in pairs(species) do
    if type(key) ~= "string" or key == "" or known ~= true then
      Errors.raise("POKEDEX_INVALID", "dex knowledge species must map keys to true", { species = key })
    end
    allowed[key] = true
  end
  if next(allowed) == nil then
    Errors.raise("POKEDEX_INVALID", "dex knowledge requires a non-empty species set", {})
  end
  return allowed
end

---@param allowed table<string, boolean>
---@param species unknown
---@return string
local function checkKey(allowed, species)
  if type(species) ~= "string" or allowed[species] ~= true then
    Errors.raise("POKEDEX_INVALID", "dex knowledge names an unknown species", { species = species })
  end
  return species
end

---@param allowed table<string, boolean>
---@param keys unknown
---@param what string
---@return string[]
local function checkKeys(allowed, keys, what)
  if type(keys) ~= "table" then
    Errors.raise("POKEDEX_INVALID", "dex knowledge " .. what .. " must be an array", {})
  end
  local checked = {}
  local seen = {}
  for _, key in ipairs(keys) do
    local species = checkKey(allowed, key)
    if seen[species] == true then
      Errors.raise("POKEDEX_INVALID", "dex knowledge " .. what .. " names a duplicate species", { species = species })
    end
    seen[species] = true
    checked[#checked + 1] = species
  end
  return checked
end

-- Builds empty knowledge over the resolved species set. Historic catches
-- are never inferred: only explicitly staged captures mark species
-- caught, so migrated saves start empty unless their bucket says
-- otherwise.
---@param args { species: table<string, boolean> }
---@return PokedexKnowledge
function PokedexKnowledge.new(args)
  if type(args) ~= "table" then
    Errors.raise("POKEDEX_INVALID", "dex knowledge requires an argument record", {})
  end
  assert(type(args) == "table", "dex knowledge reads its construction record")
  return setmetatable({
    _allowed = checkSpeciesSet(args.species),
    _seen = {},
    _caught = {},
    _revision = 0,
  }, PokedexKnowledge)
end

-- Rebuilds knowledge from a validated persisted bucket over the same
-- resolved species set. Unknown persisted keys fail; nothing is
-- inferred from the current party.
---@param bucket table<string, unknown>
---@param refs { species: table<string, boolean> }
---@return PokedexKnowledge
function PokedexKnowledge.restore(bucket, refs)
  local PokedexSave = require("libs.hgss.src.save.PokedexSave")
  if type(refs) ~= "table" then
    Errors.raise("POKEDEX_INVALID", "dex restore requires a species reference set", {})
  end
  local valid = PokedexSave.validate(bucket, refs)
  local knowledge = PokedexKnowledge.new({ species = refs.species })
  for _, key in ipairs(valid.seen) do
    knowledge._seen[key] = true
  end
  for _, key in ipairs(valid.caught) do
    knowledge._caught[key] = true
    knowledge._seen[key] = true
  end
  return knowledge
end

---@param key string
---@return boolean
function PokedexKnowledge:isSeen(key)
  checkKey(self._allowed, key)
  return self._seen[key] == true
end

---@param key string
---@return boolean
function PokedexKnowledge:isCaught(key)
  checkKey(self._allowed, key)
  return self._caught[key] == true
end

---@return integer
function PokedexKnowledge:revision()
  return self._revision
end

-- Stages a seen/caught batch without touching live knowledge. Every key
-- resolves before the candidate is allocated; the publish installs the
-- staged flags and advances the revision exactly once when the batch
-- changed anything. A repeated publish is a programming error.
---@class DexPreparation
---@field changed boolean
---@field isCurrent fun(): boolean
---@field publish fun()
---@param changes { seen: string[]?, caught: string[]? }
---@return DexPreparation
function PokedexKnowledge:prepareChanges(changes)
  if type(changes) ~= "table" then
    Errors.raise("POKEDEX_INVALID", "dex changes must be a record", {})
  end
  local seen = {}
  local caught = {}
  if changes.seen ~= nil then
    seen = checkKeys(self._allowed, changes.seen, "seen")
  end
  if changes.caught ~= nil then
    caught = checkKeys(self._allowed, changes.caught, "caught")
  end
  local changed = false
  for _, key in ipairs(seen) do
    changed = changed or self._seen[key] ~= true
  end
  for _, key in ipairs(caught) do
    changed = changed or self._caught[key] ~= true
  end
  local capturedRevision = self._revision
  local consumed = false
  local function isCurrent()
    return self._revision == capturedRevision
  end
  local function publish()
    assert(not consumed, "dex preparation publishes exactly once")
    consumed = true
    for _, key in ipairs(seen) do
      self._seen[key] = true
    end
    for _, key in ipairs(caught) do
      self._caught[key] = true
      self._seen[key] = true
    end
    if changed then
      self._revision = self._revision + 1
    end
  end
  return { changed = changed, isCurrent = isCurrent, publish = publish }
end

-- Stages one caught registration: the species counts as both seen and
-- caught once published.
---@param species string
---@return DexPreparation
function PokedexKnowledge:capture(species)
  return self:prepareChanges({ caught = { checkKey(self._allowed, species) } })
end

-- Reads the persistable bucket: sorted seen/caught arrays over the
-- resolved species set.
---@return { schema: string, stateVersion: integer, seen: string[], caught: string[] }
function PokedexKnowledge:bucket()
  local PokedexSave = require("libs.hgss.src.save.PokedexSave")
  local seen = {}
  for key in pairs(self._seen) do
    seen[#seen + 1] = key
  end
  table.sort(seen)
  local caught = {}
  for key in pairs(self._caught) do
    caught[#caught + 1] = key
  end
  table.sort(caught)
  return { schema = PokedexSave.SCHEMA, stateVersion = PokedexSave.STATE_VERSION, seen = seen, caught = caught }
end

return PokedexKnowledge
