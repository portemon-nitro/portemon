-- Projection of native encounter members into version-specific semantic
-- tables. Members follow the EncounterData layout in
-- include/wild_encounter.h with slot and replacement selection in
-- src/field/encounter_check.c
-- (pret/pokeheartgold@0985e8718df4f25e64d6507d89c0c97c0d288981): per-method
-- ordered slots keep their level windows and native interval weights, equal
-- species slots never merge, and radio/swarm/night-fishing replacements
-- point at their original native slots with their supported game. Special
-- contexts (Safari, Bug Contest, Unown, roaming sources) travel as records,
-- never campaigns. No LOVE objects or filesystem writes; callers publish
-- through the battle-data cache paths.

local BinaryReader = require("libs.codec.src.BinaryReader")
local Errors = require("libs.errors.src.Errors")
local MonSources = require("romdump.src.config.MonSources")
local BattleSources = require("romdump.src.config.BattleSources")
local BattleDataCache = require("libs.assets.src.battle.BattleDataCache")
local BattleDataSchema = require("libs.assets.src.battle.BattleDataSchema")

---@class EncounterCatalogCompiler
local EncounterCatalogCompiler = {}

local SOURCES = BattleSources.encounterSources
local SUPPORTED_VERSIONS = { heartgold = true, soulsilver = true }

---@generic T
---@param value T?
---@param err unknown?
---@return T
local function must(value, err)
  if value == nil then
    error(err, 0)
  end
  return value
end

---@param memberId integer
---@param speciesId integer
---@return string|nil, Errors.Error|nil
local function resolveSpecies(memberId, speciesId)
  local key = MonSources.speciesKeys[speciesId]
  if key == nil then
    return nil,
      Errors.new(
        "ENCOUNTER_BAD_SPECIES",
        "encounter member " .. memberId .. " references unknown species " .. speciesId,
        { member = memberId, species = speciesId }
      )
  end
  if speciesId == 0 then
    return nil,
      Errors.new("ENCOUNTER_BAD_SPECIES", "encounter member " .. memberId .. " carries an empty slot species", {
        member = memberId,
        species = speciesId,
      })
  end
  return key
end

---@param memberId integer
---@param speciesId integer
---@return string|nil, Errors.Error|nil
local function resolveSlotSpecies(memberId, speciesId)
  -- A zero slot species marks an inert slot: ROM-wide it coincides with a
  -- zero level window and a zero method rate, so selection never reaches
  -- it. It projects to the NONE sentinel with its slot order preserved.
  if speciesId == 0 then
    return assert(MonSources.speciesKeys[0])
  end
  return resolveSpecies(memberId, speciesId)
end

---@param memberId integer
---@param reader BinaryReader
---@param offset integer
---@param weights integer[]
---@return table<string, unknown>[]|nil, Errors.Error|nil
local function decodeLandArray(memberId, reader, offset, weights)
  local levels = {}
  for slot = 0, SOURCES.landSlots - 1 do
    levels[#levels + 1] = reader:u8(SOURCES.offsets.landLevels + slot)
  end
  local slots = {}
  for slot = 0, SOURCES.landSlots - 1 do
    local speciesId = reader:u16le(offset + slot * 2)
    local speciesKey, speciesErr = resolveSlotSpecies(memberId, speciesId)
    if speciesKey == nil then
      return nil, speciesErr
    end
    slots[#slots + 1] = {
      species = speciesKey,
      form = 0,
      minLevel = levels[slot + 1],
      maxLevel = levels[slot + 1],
      weight = weights[slot + 1],
    }
  end
  return slots
end

---@param memberId integer
---@param reader BinaryReader
---@param offset integer
---@param count integer
---@param weights integer[]
---@return table<string, unknown>[]|nil, Errors.Error|nil
local function decodeWaterArray(memberId, reader, offset, count, weights)
  local slots = {}
  for slot = 0, count - 1 do
    local base = offset + slot * 4
    local minLevel = reader:u8(base)
    local maxLevel = reader:u8(base + 1)
    local speciesId = reader:u16le(base + 2)
    local speciesKey, speciesErr = resolveSlotSpecies(memberId, speciesId)
    if speciesKey == nil then
      return nil, speciesErr
    end
    if minLevel > maxLevel then
      return nil,
        Errors.new(
          "ENCOUNTER_BAD_LEVELS",
          "encounter member " .. memberId .. " carries an inverted level window",
          { member = memberId, slot = slot }
        )
    end
    slots[#slots + 1] = {
      species = speciesKey,
      form = 0,
      minLevel = minLevel,
      maxLevel = maxLevel,
      weight = weights[slot + 1],
    }
  end
  return slots
end

---@param memberId integer
---@param speciesId integer
---@param slot integer
---@param versionId string
---@return table<string, unknown>|nil, Errors.Error|nil
local function replacementRecord(memberId, speciesId, slot, versionId)
  -- A zero replacement field is the native NONE sentinel: the map carries
  -- no replacement there. It projects to the NONE key, never to a species.
  if speciesId == 0 then
    return { species = assert(MonSources.speciesKeys[0]), slot = slot, game = versionId }
  end
  local speciesKey, speciesErr = resolveSpecies(memberId, speciesId)
  if speciesKey == nil then
    return nil, speciesErr
  end
  return { species = speciesKey, slot = slot, game = versionId }
end

-- Decode one 0xC4-byte EncounterData member into its semantic table.
-- Truncated members and unknown slot species fail naming the member.
---@param memberId integer
---@param versionId string
---@param member string
---@return table<string, unknown>|nil, Errors.Error|nil
function EncounterCatalogCompiler.decodeMember(memberId, versionId, member)
  if #member ~= SOURCES.memberSize then
    return nil,
      Errors.new(
        "ENCOUNTER_MEMBER_BAD_SIZE",
        "encounter member " .. memberId .. " is " .. #member .. " bytes, expected " .. SOURCES.memberSize,
        { member = memberId, size = #member, expected = SOURCES.memberSize }
      )
  end
  local offsets = SOURCES.offsets
  local reader = BinaryReader.new(member, "encounter member " .. memberId)
  local weights = BattleSources.slotWeights
  local ok, result = pcall(function()
    local morning = must(decodeLandArray(memberId, reader, offsets.morning, weights.land))
    local day = must(decodeLandArray(memberId, reader, offsets.day, weights.land))
    local night = must(decodeLandArray(memberId, reader, offsets.night, weights.land))
    local surf = must(decodeWaterArray(memberId, reader, offsets.surf, SOURCES.surfSlots, weights.surf))
    local rock = must(decodeWaterArray(memberId, reader, offsets.rock, SOURCES.rockSlots, weights.rock))
    local oldRod = must(decodeWaterArray(memberId, reader, offsets.oldRod, SOURCES.rodSlots, weights.rod))
    local goodRod = must(decodeWaterArray(memberId, reader, offsets.goodRod, SOURCES.rodSlots, weights.rod))
    local superRod = must(decodeWaterArray(memberId, reader, offsets.superRod, SOURCES.rodSlots, weights.rod))
    local radioHoennFirst = reader:u16le(offsets.radioHoenn)
    local radioHoennSecond = reader:u16le(offsets.radioHoenn + 2)
    local radioSinnohFirst = reader:u16le(offsets.radioSinnoh)
    local radioSinnohSecond = reader:u16le(offsets.radioSinnoh + 2)
    local radioSlots = BattleSources.replacementSlots
    local radioHoenn = must(replacementRecord(memberId, radioHoennFirst, radioSlots.radioFirst[1], versionId))
    radioHoenn.slots = { radioSlots.radioFirst[1], radioSlots.radioFirst[2] }
    local radioHoennAlt = must(replacementRecord(memberId, radioHoennSecond, radioSlots.radioSecond[1], versionId))
    radioHoennAlt.slots = { radioSlots.radioSecond[1], radioSlots.radioSecond[2] }
    local radioSinnoh = must(replacementRecord(memberId, radioSinnohFirst, radioSlots.radioFirst[1], versionId))
    radioSinnoh.slots = { radioSlots.radioFirst[1], radioSlots.radioFirst[2] }
    local radioSinnohAlt = must(replacementRecord(memberId, radioSinnohSecond, radioSlots.radioSecond[1], versionId))
    radioSinnohAlt.slots = { radioSlots.radioSecond[1], radioSlots.radioSecond[2] }
    local landSwarm =
      must(replacementRecord(memberId, reader:u16le(offsets.landSwarm), radioSlots.landSwarm[1], versionId))
    landSwarm.slots = { radioSlots.landSwarm[1], radioSlots.landSwarm[2] }
    local surfSwarm =
      must(replacementRecord(memberId, reader:u16le(offsets.surfSwarm), radioSlots.surfSwarm[1], versionId))
    local nightFish = must(replacementRecord(memberId, reader:u16le(offsets.nightFish), 3, versionId))
    nightFish.rods = {
      good_rod = radioSlots.nightFishRods.good_rod,
      super_rod = radioSlots.nightFishRods.super_rod,
    }
    local fishSwarm = must(replacementRecord(memberId, reader:u16le(offsets.fishSwarm), 2, versionId))
    fishSwarm.rods = {
      old_rod = radioSlots.fishSwarmRods.old_rod,
      good_rod = radioSlots.fishSwarmRods.good_rod,
      super_rod = radioSlots.fishSwarmRods.super_rod,
    }
    return {
      rates = {
        walking = reader:u8(offsets.walkRate),
        surfing = reader:u8(offsets.surfRate),
        rockSmash = reader:u8(offsets.rockRate),
        oldRod = reader:u8(offsets.oldRate),
        goodRod = reader:u8(offsets.goodRate),
        superRod = reader:u8(offsets.superRate),
      },
      land = { morning = morning, day = day, night = night },
      surf = surf,
      rockSmash = rock,
      oldRod = oldRod,
      goodRod = goodRod,
      superRod = superRod,
      replacements = {
        landSwarm = landSwarm,
        surfSwarm = surfSwarm,
        nightFish = nightFish,
        fishSwarm = fishSwarm,
        radioHoenn = radioHoenn,
        radioHoennAlt = radioHoennAlt,
        radioSinnoh = radioSinnoh,
        radioSinnohAlt = radioSinnohAlt,
      },
      special = {
        safari = { context = "safari", version = versionId },
        bugContest = { context = "bug_contest", version = versionId },
        unown = { context = "unown", version = versionId },
        roaming = { context = "roaming", version = versionId },
      },
    }
  end)
  if not ok then
    if Errors.is(result) then
      return nil, result
    end
    error(result, 0)
  end
  return result
end

-- Compile synthetic native input into the encounter catalog. The input
-- carries one raw member per map identity with its supported game; version
-- tables keep their own replacement slots and game.
---@param nativeInput { versionId: string, members: table<integer, string> }
---@return table<string, unknown>|nil, Errors.Error|nil
function EncounterCatalogCompiler.compile(nativeInput)
  local versionId = nativeInput.versionId
  if SUPPORTED_VERSIONS[versionId] ~= true then
    return nil,
      Errors.new(
        "ENCOUNTER_VERSION_UNSUPPORTED",
        "encounter data has no source contract for " .. tostring(versionId),
        { versionId = versionId }
      )
  end
  if type(nativeInput.members) ~= "table" then
    return nil, Errors.new("ENCOUNTER_INPUT_INVALID", "encounter input carries no members", {})
  end
  local tables = {}
  local ok, result = pcall(function()
    for memberId, member in pairs(nativeInput.members) do
      if type(memberId) ~= "number" or memberId % 1 ~= 0 then
        error(Errors.new("ENCOUNTER_INPUT_INVALID", "encounter member identities must be integers", {}), 0)
      end
      if type(member) ~= "string" then
        error(
          Errors.new("ENCOUNTER_MEMBER_BAD_SIZE", "encounter member " .. memberId .. " carries no bytes", {
            member = memberId,
          }),
          0
        )
      end
      tables[memberId] = must(EncounterCatalogCompiler.decodeMember(memberId, versionId, member))
    end
    local compiled = {
      schema = BattleDataCache.ENCOUNTER_SCHEMA,
      version = { id = versionId },
      tables = tables,
    }
    must(BattleDataSchema.assertEncounterCatalog(compiled))
    return compiled
  end)
  if not ok then
    if Errors.is(result) then
      return nil, result
    end
    error(result, 0)
  end
  return result
end

-- Compile the encounter catalog from a supported dump. Members resolve by
-- map identity through the version-neutral encounter archive; every member
-- must fill the native record exactly.
---@param romFs RomFs
---@param opts { versionId: string|nil }|nil
---@return table<string, unknown>|nil, Errors.Error|string|nil
function EncounterCatalogCompiler.compileFromDump(romFs, opts)
  opts = opts or {}
  local versionId = opts.versionId or romFs:version()
  if SUPPORTED_VERSIONS[versionId] ~= true then
    return nil,
      Errors.new(
        "ENCOUNTER_VERSION_UNSUPPORTED",
        "encounter data has no source contract for " .. tostring(versionId),
        { versionId = versionId }
      )
  end
  local archive, archiveErr = romFs:openNarc("encounters")
  if archive == nil then
    return nil, archiveErr
  end
  local ok, result = pcall(function()
    local members = {}
    local count = archive:memberCount()
    for memberId = 0, count - 1 do
      members[memberId] = must(archive:readMember(memberId))
    end
    return must(EncounterCatalogCompiler.compile({ versionId = versionId, members = members }))
  end)
  if not ok then
    if Errors.is(result) then
      return nil, result
    end
    error(result, 0)
  end
  return result
end

return EncounterCatalogCompiler
