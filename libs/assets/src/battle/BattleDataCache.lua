-- Readiness and paths for the derived battle input class. The class carries
-- three independently rebuildable families (move battle facts, trainer
-- records, encounter tables) published by the native import pipeline. Each
-- family stages its whole semantic payload plus a completion marker; a
-- family reads as ready only when its marker is exact and its payload still
-- satisfies the semantic schema. Runtime loads trust the staged root
-- identity and never rescan whole catalogs; explicit readiness revalidates
-- the payload through its semantic schema. Paths are cache-relative; all IO goes
-- through a CacheFs. No native decoding happens here and no ROM handle is
-- retained.

---@class BattleDataCache
local BattleDataCache = {}

local Contract = require("libs.assets.src.DerivedAssetContract")
local BattleDataSchema = require("libs.assets.src.battle.BattleDataSchema")

BattleDataCache.BATTLE_DATA_SCHEMA = Contract.battleData.schema
BattleDataCache.TRAINER_SCHEMA = Contract.trainerCatalog.schema
BattleDataCache.ENCOUNTER_SCHEMA = Contract.encounterCatalog.schema

local DATA_DIR = "data/generated/battle"

---@return string
function BattleDataCache.dir()
  return DATA_DIR
end

---@return string cache-relative staged battle-data payload path
function BattleDataCache.battleDataPath()
  return DATA_DIR .. "/battle_data.lua"
end

---@return string cache-relative staged trainer-catalog payload path
function BattleDataCache.trainersPath()
  return DATA_DIR .. "/trainers.lua"
end

---@return string cache-relative staged encounter-catalog payload path
function BattleDataCache.encountersPath()
  return DATA_DIR .. "/encounters.lua"
end

---@return string cache-relative battle-data completion marker path
function BattleDataCache.battleDataMarkerPath()
  return DATA_DIR .. "/battle_data.complete"
end

---@return string cache-relative trainer-catalog completion marker path
function BattleDataCache.trainersMarkerPath()
  return DATA_DIR .. "/trainers.complete"
end

---@return string cache-relative encounter-catalog completion marker path
function BattleDataCache.encountersMarkerPath()
  return DATA_DIR .. "/encounters.complete"
end

---@return { battleData: string, trainers: string, encounters: string } cache-relative payload paths
function BattleDataCache.paths()
  return {
    battleData = BattleDataCache.battleDataPath(),
    trainers = BattleDataCache.trainersPath(),
    encounters = BattleDataCache.encountersPath(),
  }
end

---@param romSha1 string
---@param depHash string
---@return string
function BattleDataCache.marker(romSha1, depHash)
  return string.format("%s:%s:%s", Contract.battleData.cacheFormat, romSha1, depHash)
end

---@param romSha1 string
---@param depHash string
---@return string
function BattleDataCache.trainersMarker(romSha1, depHash)
  return string.format("%s:%s:%s", Contract.trainerCatalog.cacheFormat, romSha1, depHash)
end

---@param romSha1 string
---@param depHash string
---@return string
function BattleDataCache.encountersMarker(romSha1, depHash)
  return string.format("%s:%s:%s", Contract.encounterCatalog.cacheFormat, romSha1, depHash)
end

---@param cacheFs CacheFs
---@return table<string, unknown> compiled move battle facts
function BattleDataCache.loadBattleData(cacheFs)
  local compiled = assert(cacheFs:loadLua(BattleDataCache.battleDataPath()))
  assert(
    type(compiled) == "table" and compiled.schema == BattleDataCache.BATTLE_DATA_SCHEMA,
    "battle data is unavailable"
  )
  return compiled
end

---@param cacheFs CacheFs
---@return table<string, unknown> projected trainer catalog
function BattleDataCache.loadTrainers(cacheFs)
  local compiled = assert(cacheFs:loadLua(BattleDataCache.trainersPath()))
  assert(
    type(compiled) == "table" and compiled.schema == BattleDataCache.TRAINER_SCHEMA,
    "trainer catalog is unavailable"
  )
  return compiled
end

---@param cacheFs CacheFs
---@return table<string, unknown> projected encounter catalog
function BattleDataCache.loadEncounters(cacheFs)
  local compiled = assert(cacheFs:loadLua(BattleDataCache.encountersPath()))
  assert(
    type(compiled) == "table" and compiled.schema == BattleDataCache.ENCOUNTER_SCHEMA,
    "encounter catalog is unavailable"
  )
  return compiled
end

-- True only when the family marker is exact and the staged payload is
-- present and still satisfies its semantic schema. Marker presence alone
-- never reads as readiness.
---@param cacheFs CacheFs
---@param expectedMarker string
---@return boolean
function BattleDataCache.isBattleDataReady(cacheFs, expectedMarker)
  if cacheFs:read(BattleDataCache.battleDataMarkerPath()) ~= expectedMarker then
    return false
  end
  local ok = pcall(function()
    BattleDataSchema.assertBattleData(assert(cacheFs:loadLua(BattleDataCache.battleDataPath())))
  end)
  return ok
end

---@param cacheFs CacheFs
---@param expectedMarker string
---@return boolean
function BattleDataCache.isTrainersReady(cacheFs, expectedMarker)
  if cacheFs:read(BattleDataCache.trainersMarkerPath()) ~= expectedMarker then
    return false
  end
  local ok = pcall(function()
    BattleDataSchema.assertTrainerCatalog(assert(cacheFs:loadLua(BattleDataCache.trainersPath())))
  end)
  return ok
end

---@param cacheFs CacheFs
---@param expectedMarker string
---@return boolean
function BattleDataCache.isEncountersReady(cacheFs, expectedMarker)
  if cacheFs:read(BattleDataCache.encountersMarkerPath()) ~= expectedMarker then
    return false
  end
  local ok = pcall(function()
    BattleDataSchema.assertEncounterCatalog(assert(cacheFs:loadLua(BattleDataCache.encountersPath())))
  end)
  return ok
end

return BattleDataCache
