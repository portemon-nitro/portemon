-- Validated encounter-table lookup over a compiled native catalog. Lookup
-- resolves one map member with its swarm, radio-music, and fishing
-- replacements applied, preserving the ordered native intervals: duplicate
-- species slots never merge. Replacements apply only for their supported
-- game and only while their species names a real entry; an absent optional
-- feature reads as its inactive state. Every lookup returns a detached
-- copy, so callers can never mutate the published catalog. Rod arrays
-- without a requested rod resolve to the member's neutral surf content.
-- Pure domain module: no love dependency and no native decoding.

local BattleDataSchema = require("libs.assets.src.battle.BattleDataSchema")
local Errors = require("libs.errors.src.Errors")
local Validate = require("libs.assets.src.Validate")

---@class HgssEncounterCatalog
---@field private _compiled table<string, unknown>
local HgssEncounterCatalog = {}
HgssEncounterCatalog.__index = HgssEncounterCatalog

HgssEncounterCatalog.NONE_SPECIES = "NONE"

local LAND_TIMES = { "morning", "day", "night" }

local ROD_KEYS = {
  old_rod = "oldRod",
  good_rod = "goodRod",
  super_rod = "superRod",
}

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

---@param compiled unknown
---@return HgssEncounterCatalog
function HgssEncounterCatalog.new(compiled)
  if type(compiled) ~= "table" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "the encounter catalog requires a compiled record", {})
  end
  assert(type(compiled) == "table", "catalog construction validates the compiled record")
  local ok, validationErr = pcall(function()
    return BattleDataSchema.assertEncounterCatalog(compiled)
  end)
  if not ok then
    if Errors.is(validationErr) then
      Errors.raise("ENCOUNTER_INVALID_INPUT", "the compiled encounter catalog is invalid", {
        reason = Errors.format(validationErr),
      })
    end
    error(validationErr, 0)
  end
  return setmetatable({ _compiled = copyValue(compiled) }, HgssEncounterCatalog)
end

---@param record unknown
---@param game string?
---@return boolean
local function replacementIsActive(record, game)
  return type(record) == "table"
    and (game == nil or record.game == game)
    and type(record.species) == "string"
    and record.species ~= HgssEncounterCatalog.NONE_SPECIES
end

---@param array unknown
---@param index integer
---@param species string
local function setSlotSpecies(array, index, species)
  if type(array) == "table" and type(array[index]) == "table" then
    array[index].species = species
  end
end

---@param resolved table<string, unknown>
---@param species string
local function applyRadioPair(resolved, species)
  local land = resolved.land
  if type(land) ~= "table" then
    return
  end
  assert(type(land) == "table", "replacement reads the resolved land arrays")
  for _, timeOfDay in ipairs(LAND_TIMES) do
    local slots = land[timeOfDay]
    setSlotSpecies(slots, 3, species)
    setSlotSpecies(slots, 4, species)
  end
end

---@param opts unknown
---@return table<string, unknown>
local function checkLookupOptions(opts)
  if type(opts) ~= "table" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter lookup requires an options record", {})
  end
  assert(type(opts) == "table", "lookup reads its resolution options")
  return opts
end

-- Resolves one member with its active replacements. The result keeps the
-- member shape with the requested land time flattened beside it, so table
-- selection can read either spelling.
---@param memberId integer
---@param opts table<string, unknown>?
---@return table<string, unknown>
function HgssEncounterCatalog:tableFor(memberId, opts)
  local options = checkLookupOptions(opts or {})
  local tables = self._compiled.tables
  assert(type(tables) == "table", "the catalog carries its member tables")
  local member = tables[memberId]
  if type(member) ~= "table" then
    Errors.raise("ENCOUNTER_MISSING_TABLE", "no encounter table for member " .. tostring(memberId), {
      member = memberId,
    })
  end
  assert(type(member) == "table", "lookup resolves a present member")
  local timeOfDay = options.timeOfDay
  if timeOfDay ~= "morning" and timeOfDay ~= "day" and timeOfDay ~= "night" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter lookup requires a known time of day", {
      member = memberId,
      timeOfDay = timeOfDay,
    })
  end
  local radio = options.radio or "none"
  if radio ~= "none" and radio ~= "hoenn" and radio ~= "sinnoh" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter lookup requires a known radio station", {
      member = memberId,
      radio = radio,
    })
  end
  local rod = options.rod
  if rod ~= nil and (type(rod) ~= "string" or ROD_KEYS[rod] == nil) then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter lookup requires a known rod", {
      member = memberId,
      rod = rod,
    })
  end
  local game = options.game
  if game ~= nil and (type(game) ~= "string" or game == "") then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "encounter lookup requires a known game", {
      member = memberId,
      game = game,
    })
  end
  local swarm = options.swarm == true
  local resolved = copyValue(member)
  assert(type(resolved) == "table", "lookup resolves a detached member")
  local replacements = resolved.replacements
  assert(type(replacements) == "table", "the member carries its replacement records")
  if swarm then
    local landSwarm = replacements.landSwarm
    if replacementIsActive(landSwarm, game) then
      assert(type(landSwarm) == "table", "the active swarm carries its species")
      local land = resolved.land
      assert(type(land) == "table", "the swarm reads the resolved land arrays")
      for _, time in ipairs(LAND_TIMES) do
        setSlotSpecies(land[time], 1, landSwarm.species)
        setSlotSpecies(land[time], 2, landSwarm.species)
      end
    end
    local surfSwarm = replacements.surfSwarm
    if replacementIsActive(surfSwarm, game) then
      assert(type(surfSwarm) == "table", "the active swarm carries its species")
      setSlotSpecies(resolved.surf, 1, surfSwarm.species)
    end
  end
  if radio == "hoenn" then
    local hoenn = replacements.radioHoenn
    if replacementIsActive(hoenn, game) then
      assert(type(hoenn) == "table", "the active music carries its species")
      applyRadioPair(resolved, hoenn.species)
    end
  elseif radio == "sinnoh" then
    local sinnoh = replacements.radioSinnoh
    if replacementIsActive(sinnoh, game) then
      assert(type(sinnoh) == "table", "the active music carries its species")
      applyRadioPair(resolved, sinnoh.species)
    end
  end
  local rodKey = type(rod) == "string" and ROD_KEYS[rod] or nil
  if rodKey ~= nil then
    if (rod == "good_rod" or rod == "super_rod") and replacementIsActive(replacements.nightFish, game) then
      local nightFish = replacements.nightFish
      assert(type(nightFish) == "table", "the active night record carries its slot")
      assert(type(nightFish.slot) == "number", "the night record carries its native slot")
      setSlotSpecies(resolved[rodKey], nightFish.slot + 1, nightFish.species)
    end
    if swarm and replacementIsActive(replacements.fishSwarm, game) then
      local fishSwarm = replacements.fishSwarm
      assert(type(fishSwarm) == "table", "the active swarm carries its slot")
      local indices = nil
      if type(fishSwarm.rods) == "table" then
        local perRod = fishSwarm.rods[rod]
        if Validate.isArray(perRod) then
          indices = perRod
        end
      end
      if indices == nil then
        assert(type(fishSwarm.slot) == "number", "the swarm record carries its native slot")
        indices = { fishSwarm.slot }
      end
      assert(type(indices) == "table", "the swarm resolves its native slots")
      for _, nativeSlot in ipairs(indices) do
        setSlotSpecies(resolved[rodKey], nativeSlot + 1, fishSwarm.species)
      end
    end
  end
  -- Rod arrays without a requested rod carry the member's neutral surf
  -- content rather than an unrequested rod table.
  local neutralSurf = copyValue(member.surf)
  for _, key in ipairs({ "oldRod", "goodRod", "superRod" }) do
    if key ~= rodKey then
      resolved[key] = copyValue(neutralSurf)
    end
  end
  local land = resolved.land
  assert(type(land) == "table", "the resolved member carries its land arrays")
  for _, time in ipairs(LAND_TIMES) do
    resolved[time] = land[time]
  end
  return resolved
end

-- Resolves one special encounter context without inventing slots: safari,
-- bug contest, unown, and roaming sources travel as records, never as
-- campaigns.
---@param memberId integer
---@param context string
---@return table<string, unknown>
function HgssEncounterCatalog:specialTable(memberId, context)
  local tables = self._compiled.tables
  assert(type(tables) == "table", "the catalog carries its member tables")
  local member = tables[memberId]
  if type(member) ~= "table" then
    Errors.raise("ENCOUNTER_MISSING_TABLE", "no encounter table for member " .. tostring(memberId), {
      member = memberId,
    })
  end
  assert(type(member) == "table", "special lookup resolves a present member")
  local special = member.special
  if type(special) == "table" then
    for _, record in pairs(special) do
      if type(record) == "table" and record.context == context then
        return copyValue(record)
      end
    end
  end
  Errors.raise(
    "ENCOUNTER_MISSING_TABLE",
    "no special encounter context " .. tostring(context) .. " for member " .. tostring(memberId),
    { member = memberId, context = context }
  )
  error("unreachable special lookup", 0)
end

return HgssEncounterCatalog
