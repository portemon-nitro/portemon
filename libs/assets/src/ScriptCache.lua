-- Readiness and paths for the derived script cache. The translated script
-- corpus is one of the independently rebuildable derived classes (map
-- geometry, actor visuals, messages/font, scripts): changing the script
-- translator must not disturb the raw ROM dump or any compiled map.
-- Each immutable generation holds one readable Lua bundle per nonempty script
-- archive member; a single active index selects a generation and carries the
-- logical resource lookup plus the per-member transitive audio/asset-need
-- closures; one aggregate coverage report describes the selected generation.
-- Paths are cache-relative; all IO goes through a CacheFs.

local ScriptCache = {}

---@class ScriptCache.Resource
---@field id string
---@field member integer
---@field scriptIndex integer

---@class ScriptCache.Index
---@field schema string
---@field version string
---@field generation string
---@field marker string
---@field memberCount integer
---@field scriptMemberCount integer
---@field skippedMemberCount integer
---@field scriptCount integer
---@field resourceCount integer
---@field resources ScriptCache.Resource[]
---@field memberAudioSequences table<string, string[]>
---@field memberAssetNeeds table<string, string[]>

local Validate = require("libs.assets.src.Validate")
local Contract = require("libs.assets.src.DerivedAssetContract")

ScriptCache.FORMAT = Contract.scripts.cacheFormat
ScriptCache.INDEX_SCHEMA = Contract.scripts.indexSchema
-- One bundle per nonempty script archive member: the ordered script
-- resources of that member plus their compact direct dependency facts and the
-- member coverage record. The owning member and generation are derived from
-- the bundle path, never repeated inside it.
ScriptCache.MEMBER_SCHEMA = Contract.scripts.memberSchema

local DATA_DIR = "data/generated/script"
local ACTIVE_DIR = DATA_DIR .. "/active"
local GENERATIONS_DIR = DATA_DIR .. "/generations"

local function isSafeGeneration(value)
  return type(value) == "string" and value:match("^[0-9a-f]+$") ~= nil and #value == 40
end

local function memberName(memberId)
  assert(type(memberId) == "number" and memberId % 1 == 0 and memberId >= 0, "member id must be a non-negative integer")
  return string.format("%04d", memberId)
end

function ScriptCache.dir()
  return DATA_DIR
end

function ScriptCache.activeDir()
  return ACTIVE_DIR
end

function ScriptCache.generationsDir()
  return GENERATIONS_DIR
end

-- The one active selection: the indexed resource lookup, the generation it
-- belongs to, and the per-member prefetch closures.
function ScriptCache.activeIndexPath()
  return ACTIVE_DIR .. "/index.lua"
end

-- The one aggregate coverage report of the selected generation.
function ScriptCache.coverageReportPath()
  return ACTIVE_DIR .. "/coverage.md"
end

function ScriptCache.generationDir(generation)
  assert(isSafeGeneration(generation), "generation key must be lowercase hexadecimal")
  return ScriptCache.generationsDir() .. "/" .. generation
end

-- The physical unit of generated script content: every script of one source
-- archive member in source order.
function ScriptCache.memberPath(generation, memberId)
  assert(isSafeGeneration(generation), "generation key must be lowercase hexadecimal")
  return ScriptCache.generationDir(generation) .. "/" .. memberName(memberId) .. ".lua"
end

function ScriptCache.marker(romSha1, depHash)
  return string.format("%s:%s:%s", ScriptCache.FORMAT, romSha1, depHash)
end

local function isSortedUniqueStrings(value, accepts)
  if not Validate.isArray(value) then
    return false
  end
  local previous
  for _, entry in ipairs(value) do
    if type(entry) ~= "string" or entry == "" or (accepts ~= nil and not accepts(entry)) then
      return false
    end
    if previous ~= nil and previous >= entry then
      return false
    end
    previous = entry
  end
  return true
end

-- An asset need is a `kind:id` key, both halves non-empty.
local function isNeedKey(entry)
  return entry:match("^[^:]+:.+$") ~= nil
end

-- True when the value is a well-formed per-member closure mapping: decimal
-- member-id keys to sorted unique arrays whose entries `accepts` (when given).
local function isMemberClosureMapping(value, accepts)
  if type(value) ~= "table" then
    return false
  end
  for key, list in pairs(value) do
    if type(key) ~= "string" or key == "" or tostring(tonumber(key)) ~= key then
      return false
    end
    local memberId = tonumber(key)
    if memberId == nil or memberId < 0 or memberId % 1 ~= 0 then
      return false
    end
    if not isSortedUniqueStrings(list, accepts) then
      return false
    end
  end
  return true
end

local function isMemberAudioMapping(value)
  return isMemberClosureMapping(value)
end

local function isMemberAssetNeedsMapping(value)
  return isMemberClosureMapping(value, isNeedKey)
end

-- Strict validation of one active index: the current schema, its generation
-- and marker, the indexed resource mapping (each logical id to exactly one
-- member and source script slot), and every planned member's transitive
-- closure. Returns true, or nil plus the cause.
---@param index unknown
---@return true|nil
---@return string|nil
local function checkIndex(index)
  if type(index) ~= "table" or index.schema ~= ScriptCache.INDEX_SCHEMA then
    return nil, "active script selection is malformed"
  end
  if not isSafeGeneration(index.generation) or type(index.marker) ~= "string" or index.marker == "" then
    return nil, "active script selection is incomplete"
  end
  if not Validate.isArray(index.resources) then
    return nil, "active script selection has no resource mapping"
  end
  -- Every planned member carries its transitive audio closure (possibly
  -- empty) under its decimal id; a mapping without it belongs to an
  -- incompatible older index, and a malformed list can never attest audio.
  if not isMemberAudioMapping(index.memberAudioSequences) then
    return nil, "active script selection has no usable audio closure"
  end
  -- Asset needs follow the same rule: every planned member carries its
  -- transitive closure (possibly empty).
  if not isMemberAssetNeedsMapping(index.memberAssetNeeds) then
    return nil, "active script selection has no usable asset needs"
  end
  local seenIds = {}
  local seenSlots = {}
  local seenMembers = {}
  for _, entry in ipairs(index.resources) do
    if
      type(entry) ~= "table"
      or type(entry.id) ~= "string"
      or entry.id == ""
      or not Validate.isNonNegativeInteger(entry.member)
      or not Validate.isNonNegativeInteger(entry.scriptIndex)
    then
      return nil, "active script selection has a malformed resource"
    end
    if seenIds[entry.id] then
      return nil, "active script selection attests " .. entry.id .. " twice"
    end
    local slot = entry.member .. ":" .. entry.scriptIndex
    if seenSlots[slot] then
      return nil, "active script selection attests one source script slot twice"
    end
    seenIds[entry.id] = true
    seenSlots[slot] = true
    seenMembers[entry.member] = true
  end
  for member in pairs(seenMembers) do
    if index.memberAudioSequences[tostring(member)] == nil then
      return nil, "active script selection is missing the audio closure of member " .. tostring(member)
    end
    local needs = index.memberAssetNeeds[tostring(member)]
    if needs == nil then
      return nil, "active script selection is missing the asset needs of member " .. tostring(member)
    end
  end
  return true
end

-- The active selection, or nil plus the cause when no current selection is
-- published. A malformed index is never treated as empty.
---@param cacheFs CacheFs
---@return { generation: string, marker: string, index: ScriptCache.Index }|nil
---@return string|nil
function ScriptCache.loadActive(cacheFs)
  local index = cacheFs:loadLua(ScriptCache.activeIndexPath())
  if type(index) ~= "table" then
    return nil, "no active script selection is published"
  end
  local ok, reason = checkIndex(index)
  if not ok then
    return nil, reason
  end
  index = index --[[@as ScriptCache.Index]]
  return { generation = index.generation, marker = index.marker, index = index }
end

-- The transitive audio closure for one script member: sorted unique
-- canonical sequence symbols, possibly empty. Returns the list, or nil plus
-- a cause when the index carries no usable closure for the member. No IO.
---@param index table<string, unknown>
---@param memberId integer
---@return string[]|nil, string|nil
function ScriptCache.audioSequencesForMember(index, memberId)
  if type(index) ~= "table" or not isMemberAudioMapping(index.memberAudioSequences) then
    return nil, "script member audio metadata is malformed"
  end
  if type(memberId) ~= "number" or memberId < 0 or memberId % 1 ~= 0 then
    return nil, "script member identity is invalid: " .. tostring(memberId)
  end
  local closure = index.memberAudioSequences[tostring(memberId)]
  if closure == nil then
    return nil, "script member " .. tostring(memberId) .. " has no published audio closure"
  end
  if not isSortedUniqueStrings(closure) then
    return nil, "script member " .. tostring(memberId) .. " audio closure is malformed"
  end
  return closure
end

-- The transitive asset needs for one script member: sorted unique `kind:id`
-- keys, possibly empty. Returns the list, or nil plus a cause when the index
-- carries no usable closure for the member. No IO.
---@param index table<string, unknown>
---@param memberId integer
---@return string[]|nil, string|nil
function ScriptCache.assetNeedsForMember(index, memberId)
  if type(index) ~= "table" or not isMemberAssetNeedsMapping(index.memberAssetNeeds) then
    return nil, "script member asset needs metadata is malformed"
  end
  if type(memberId) ~= "number" or memberId < 0 or memberId % 1 ~= 0 then
    return nil, "script member identity is invalid: " .. tostring(memberId)
  end
  local needs = index.memberAssetNeeds[tostring(memberId)]
  if needs == nil then
    return nil, "script member " .. tostring(memberId) .. " has no published asset needs"
  end
  return needs
end

-- True when the active index carries the expected marker and every member it
-- indexes has a published bundle. Ordinary readiness never decodes the bundle
-- bodies; the member and summary validators prove their contents.
---@param cacheFs CacheFs
---@param expectedMarker string
---@return boolean
function ScriptCache.isReady(cacheFs, expectedMarker)
  local ok, ready = pcall(function()
    if type(expectedMarker) ~= "string" or expectedMarker == "" then
      return false
    end
    local active = ScriptCache.loadActive(cacheFs)
    if active == nil or active.marker ~= expectedMarker then
      return false
    end
    local seen = {}
    for _, entry in ipairs(active.index.resources) do
      if not seen[entry.member] then
        seen[entry.member] = true
        if not cacheFs:exists(ScriptCache.memberPath(active.generation, entry.member), "file") then
          return false
        end
      end
    end
    return true
  end)
  return ok and ready == true
end

return ScriptCache
