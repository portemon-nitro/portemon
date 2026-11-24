-- Source projection of the Day Care breeding tables: the personal
-- egg-species table becomes the semantic mother-to-offspring map, the
-- personal egg-move list becomes ordered move keys per species, and the
-- source incense pairs travel beside them. The compiler rejects malformed
-- source data instead of substituting a plausible table.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local PokemonCareAssetSchema = require("libs.assets.src.PokemonCareAssetSchema")
local PokemonCareCatalogCompiler = require("romdump.src.digest.mons.PokemonCareCatalogCompiler")
local PokemonCareSources = require("romdump.src.config.PokemonCareSources")

local T = {}

local PIKACHU = 25
local PICHU = 172
local SNORLAX = 143
local MUNCHLAX = 446
local MANAPHY = 490
local DITTO = 132

local function u16(value)
  return string.char(value % 256, math.floor(value / 256) % 256)
end

-- The personal egg-species table: one u16 per species, defaulting to itself.
---@param overrides table<integer, integer>
---@return string
local function eggSpeciesTable(overrides)
  local parts = {}
  for speciesId = 0, PokemonCareSources.eggSpeciesSource.lastSpecies + 1 do
    parts[#parts + 1] = u16(overrides[speciesId] or speciesId)
  end
  return table.concat(parts)
end

-- LoadEggMoves' flat list: headers above the header base open each block.
---@param blocks table<integer, integer[]>
---@return string
local function eggMoveList(blocks)
  local parts = {}
  for _, speciesId in ipairs({ PIKACHU, SNORLAX, DITTO }) do
    local moves = blocks[speciesId]
    if moves ~= nil then
      parts[#parts + 1] = u16(PokemonCareSources.eggMoveSource.headerBase + speciesId)
      for _, moveId in ipairs(moves) do
        parts[#parts + 1] = u16(moveId)
      end
    end
  end
  return table.concat(parts)
end

---@param options { eggSpecies: string, eggMoves: string }?
---@return table romFs-shaped source reader
local function romFsFor(options)
  options = options or {}
  local eggSpecies = options.eggSpecies
    or eggSpeciesTable({ [PIKACHU] = PICHU, [SNORLAX] = MUNCHLAX, [MANAPHY] = MANAPHY, [DITTO] = DITTO })
  local eggMoves = options.eggMoves or eggMoveList({ [PIKACHU] = { 179, 117 }, [SNORLAX] = { 187 } })
  local reads = {}
  return {
    readSourcePath = function(_, path)
      reads[#reads + 1] = path
      if path ~= PokemonCareSources.eggSpeciesSource.path then
        return nil, Errors.new("ROMFS_PATH_UNKNOWN", "no such source file", { sourcePath = path })
      end
      return eggSpecies
    end,
    openNarc = function(_, alias)
      if alias ~= PokemonCareSources.eggMoveSource.alias then
        return nil, Errors.new("ROMFS_NARC_UNRESOLVED", "no such archive", { alias = alias })
      end
      return {
        readMember = function(_, memberId)
          if memberId ~= PokemonCareSources.eggMoveSource.memberId then
            return nil, Errors.new("NARC_MEMBER_MISSING", "no such member", { memberId = memberId })
          end
          return eggMoves
        end,
      }
    end,
    reads = reads,
  }
end

function T.compiles_the_source_breeding_tables_into_semantic_keys()
  local catalog = assert(PokemonCareCatalogCompiler.compile(romFsFor()))
  Assert.equal(catalog.schema, PokemonCareAssetSchema.CATALOG_SCHEMA, "the catalog carries its own schema")
  Assert.equal(catalog.eggSpecies.PIKACHU, "PICHU", "the mother resolves through the egg-species table")
  Assert.equal(catalog.eggSpecies.SNORLAX, "MUNCHLAX", "an incense baby stays the source egg species")
  Assert.equal(catalog.eggSpecies.MANAPHY, "MANAPHY", "the Manaphy override belongs to the runtime rule")
  Assert.equal(catalog.eggSpecies.DITTO, "DITTO", "a Ditto entry keeps its own identity")
  Assert.deepEqual(catalog.eggMoves.PIKACHU, { "REVERSAL", "BIDE" }, "egg moves keep source order")
  Assert.deepEqual(catalog.eggMoves.SNORLAX, { "BELLY_DRUM" }, "each block carries its own moves")
  Assert.isNil(catalog.eggMoves.DITTO, "a species without an egg-move block publishes none")
  Assert.equal(#catalog.incense, #PokemonCareSources.incenseRows, "every source incense pair travels")
  Assert.deepEqual(catalog.incense[5], { baby = "MUNCHLAX", item = "FULL_INCENSE", parent = "SNORLAX" })
  Assert.isTrue(PokemonCareAssetSchema.isValidCatalog(catalog), "the compiled catalog satisfies its schema")
end

function T.rejects_an_unknown_source_species()
  local catalog, err = PokemonCareCatalogCompiler.compile(romFsFor({
    eggSpecies = eggSpeciesTable({ [PIKACHU] = 600 }),
  }))
  Assert.isNil(catalog, "an unknown egg species fails the projection")
  Assert.equal(assert(err).code, "POKEMON_CARE_BAD_SPECIES", "the failure names the source identity")
end

function T.rejects_a_truncated_egg_species_table()
  local catalog, err = PokemonCareCatalogCompiler.compile(romFsFor({ eggSpecies = u16(0) .. u16(1) }))
  Assert.isNil(catalog, "a truncated table fails the projection")
  Assert.equal(assert(err).code, "POKEMON_CARE_SOURCE_TRUNCATED", "the failure names the truncation")
end

function T.rejects_an_unknown_egg_move()
  local catalog, err = PokemonCareCatalogCompiler.compile(romFsFor({
    eggMoves = eggMoveList({ [PIKACHU] = { 900 } }),
  }))
  Assert.isNil(catalog, "an unknown move fails the projection")
  Assert.equal(assert(err).code, "POKEMON_CARE_BAD_MOVE", "the failure names the move identity")
end

function T.rejects_a_block_wider_than_the_source_list()
  local moves = {}
  for index = 1, PokemonCareSources.eggMoveSource.maxMoves + 1 do
    moves[index] = index
  end
  local catalog, err = PokemonCareCatalogCompiler.compile(romFsFor({
    eggMoves = eggMoveList({ [PIKACHU] = moves }),
  }))
  Assert.isNil(catalog, "an oversized block fails the projection")
  Assert.equal(assert(err).code, "POKEMON_CARE_SOURCE_INVALID", "the failure names the block width")
end

return { tests = T }
