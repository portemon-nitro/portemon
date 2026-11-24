-- Projection of the source breeding tables into the semantic care catalog: the
-- PMS egg-species table (ReadFromPersonalPmsNarc) and the personal egg-move
-- list (LoadEggMoves), with the source incense pairs attached. Native species,
-- move, and item identities resolve through the shared producer catalogs; no
-- offsets survive into the payload. Publish through the care cache paths.

local BinaryReader = require("libs.codec.src.BinaryReader")
local Errors = require("libs.errors.src.Errors")
local ItemSources = require("romdump.src.config.ItemSources")
local MonSources = require("romdump.src.config.MonSources")
local PokemonCareAssetSchema = require("libs.assets.src.PokemonCareAssetSchema")
local PokemonCareSources = require("romdump.src.config.PokemonCareSources")

---@class PokemonCareCatalogCompiler
local PokemonCareCatalogCompiler = {}

local EGG_SPECIES = PokemonCareSources.eggSpeciesSource
local EGG_MOVES = PokemonCareSources.eggMoveSource

local SPECIES_KEYS = {}
for _, key in pairs(MonSources.speciesKeys) do
  SPECIES_KEYS[key] = true
end
local ITEM_KEYS = {}
for _, key in pairs(ItemSources.itemKeys) do
  ITEM_KEYS[key] = true
end

---@param code string
---@param message string
---@param context table<string, unknown>
---@return Errors.Error
local function sourceError(code, message, context)
  return Errors.new(code, message, context)
end

---@param speciesId integer
---@param context table<string, unknown>
---@return string|nil, Errors.Error|nil
local function speciesKey(speciesId, context)
  local key = MonSources.speciesKeys[speciesId]
  if key == nil then
    return nil,
      sourceError("POKEMON_CARE_BAD_SPECIES", "unknown species identity " .. tostring(speciesId), context)
  end
  return key
end

-- ReadFromPersonalPmsNarc: one u16 per species at species * 2.
---@param romFs table<string, unknown>
---@return { [string]: string }|nil, Errors.Error|nil
local function readEggSpeciesTable(romFs)
  local bytes, readErr = romFs:readSourcePath(EGG_SPECIES.path)
  if bytes == nil then
    return nil,
      sourceError("POKEMON_CARE_SOURCE_MISSING", "the personal egg-species table is unavailable", {
        path = EGG_SPECIES.path,
        cause = readErr,
      })
  end
  local reader = BinaryReader.new(bytes, EGG_SPECIES.path)
  local count = #bytes / EGG_SPECIES.entrySize
  if count <= EGG_SPECIES.lastSpecies then
    return nil,
      sourceError("POKEMON_CARE_SOURCE_TRUNCATED", "the personal egg-species table ends before its last species", {
        path = EGG_SPECIES.path,
        entries = count,
      })
  end
  local eggSpecies = {}
  for speciesId = EGG_SPECIES.firstSpecies, EGG_SPECIES.lastSpecies do
    local motherKey, keyErr = speciesKey(speciesId, { table = EGG_SPECIES.path, species = speciesId })
    assert(motherKey ~= nil, keyErr)
    local eggId = reader:u16le(speciesId * EGG_SPECIES.entrySize)
    local eggKey, eggErr = speciesKey(eggId, { table = EGG_SPECIES.path, species = speciesId, eggSpecies = eggId })
    if eggKey == nil then
      return nil, eggErr
    end
    eggSpecies[motherKey] = eggKey
  end
  return eggSpecies
end

-- LoadEggMoves: headers encode `species + headerBase`; a block runs until the
-- next header, bounded by the source's own block width.
---@param member string
---@return { [string]: string[] }|nil, Errors.Error|nil
local function decodeEggMoves(member)
  if #member % 2 ~= 0 then
    return nil,
      sourceError("POKEMON_CARE_SOURCE_TRUNCATED", "the egg-move list has a halfword remainder", {
        path = EGG_MOVES.path,
        size = #member,
      })
  end
  local reader = BinaryReader.new(member, EGG_MOVES.path)
  local count = #member / 2
  local eggMoves = {}
  local index = 0
  -- LoadEggMoves scans at most scanLimit entries for a species header, so a
  -- trailing entry past that bound never opens a block.
  local scanLimit = math.min(count, EGG_MOVES.scanLimit)
  while index < scanLimit do
    local header = reader:u16le(index * 2)
    if header <= EGG_MOVES.headerBase then
      return nil,
        sourceError("POKEMON_CARE_SOURCE_INVALID", "the egg-move list starts without a species header", {
          path = EGG_MOVES.path,
          index = index,
        })
    end
    local speciesId = header - EGG_MOVES.headerBase
    local key, keyErr = speciesKey(speciesId, { table = EGG_MOVES.path, index = index, species = speciesId })
    if key == nil then
      return nil, keyErr
    end
    if eggMoves[key] ~= nil then
      return nil,
        sourceError("POKEMON_CARE_SOURCE_INVALID", "the egg-move list repeats a species block", {
          path = EGG_MOVES.path,
          index = index,
          species = key,
        })
    end
    local moves = {}
    index = index + 1
    while index < count and #moves < EGG_MOVES.maxMoves do
      local moveId = reader:u16le(index * 2)
      if moveId > EGG_MOVES.headerBase then
        break
      end
      local moveKey = MonSources.moveKeys[moveId]
      if moveKey == nil then
        return nil,
          sourceError("POKEMON_CARE_BAD_MOVE", "the egg-move list references an unknown move", {
            path = EGG_MOVES.path,
            index = index,
            move = moveId,
          })
      end
      moves[#moves + 1] = moveKey
      index = index + 1
    end
    if #moves == 0 then
      return nil,
        sourceError("POKEMON_CARE_SOURCE_INVALID", "an egg-move block names no move", {
          path = EGG_MOVES.path,
          species = key,
        })
    end
    if index < count and #moves == EGG_MOVES.maxMoves and reader:u16le(index * 2) <= EGG_MOVES.headerBase then
      return nil,
        sourceError("POKEMON_CARE_SOURCE_INVALID", "an egg-move block exceeds the source block width", {
          path = EGG_MOVES.path,
          species = key,
          index = index,
        })
    end
    eggMoves[key] = moves
  end
  return eggMoves
end

---@param romFs table<string, unknown>
---@return { [string]: string[] }|nil, Errors.Error|nil
local function readEggMoves(romFs)
  local archive, openErr = romFs:openNarc(EGG_MOVES.alias)
  if archive == nil then
    return nil,
      sourceError("POKEMON_CARE_SOURCE_MISSING", "the personal egg-move archive is unavailable", {
        archive = EGG_MOVES.alias,
        cause = openErr,
      })
  end
  local member, memberErr = archive:readMember(EGG_MOVES.memberId)
  if member == nil then
    return nil,
      sourceError("POKEMON_CARE_SOURCE_MISSING", "the egg-move archive has no list member", {
        archive = EGG_MOVES.alias,
        memberId = EGG_MOVES.memberId,
        cause = memberErr,
      })
  end
  return decodeEggMoves(member)
end

---@return table<string, unknown>[]|nil, Errors.Error|nil
local function checkIncenseRows()
  local rows = {}
  for index, row in ipairs(PokemonCareSources.incenseRows) do
    for _, field in ipairs({ "baby", "parent" }) do
      if not SPECIES_KEYS[row[field]] then
        return nil,
          sourceError("POKEMON_CARE_BAD_SPECIES", "the incense table names an unknown species", {
            row = index,
            species = row[field],
          })
      end
    end
    if not ITEM_KEYS[row.item] then
      return nil,
        sourceError("POKEMON_CARE_BAD_ITEM", "the incense table names an unknown item", {
          row = index,
          item = row.item,
        })
    end
    rows[#rows + 1] = { baby = row.baby, item = row.item, parent = row.parent }
  end
  assert(#rows > 0, "the source incense table carries its rows")
  return rows
end

-- Compile the care catalog from one cartridge view.
---@param romFs table<string, unknown>
---@return table<string, unknown>|nil, Errors.Error|nil
function PokemonCareCatalogCompiler.compile(romFs)
  assert(type(romFs) == "table", "care compilation requires a source reader")
  local eggSpecies, speciesErr = readEggSpeciesTable(romFs)
  if eggSpecies == nil then
    return nil, speciesErr
  end
  local eggMoves, movesErr = readEggMoves(romFs)
  if eggMoves == nil then
    return nil, movesErr
  end
  local incense, incenseErr = checkIncenseRows()
  if incense == nil then
    return nil, incenseErr
  end
  local catalog = {
    schema = PokemonCareAssetSchema.CATALOG_SCHEMA,
    eggSpecies = eggSpecies,
    eggMoves = eggMoves,
    incense = incense,
  }
  local valid, validationErr = pcall(PokemonCareAssetSchema.assertCatalog, catalog)
  if not valid then
    return nil,
      sourceError("POKEMON_CARE_CATALOG_INVALID", "the compiled care catalog is invalid", {
        cause = tostring(validationErr),
      })
  end
  return catalog
end

return PokemonCareCatalogCompiler
