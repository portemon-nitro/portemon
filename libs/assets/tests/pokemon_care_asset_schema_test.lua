-- The generated Day Care care catalog: a strict semantic record carrying the
-- source breeding tables. Validation rejects unknown fields, dangling shells,
-- duplicated entries, and stale schema identities; the cache publishes only
-- validated payloads behind its completion marker.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local DerivedAssetContract = require("libs.assets.src.DerivedAssetContract")
local PokemonCareAssetSchema = require("libs.assets.src.PokemonCareAssetSchema")
local PokemonCareCache = require("libs.assets.src.PokemonCareCache")

local T = {}

local function catalog()
  return {
    schema = PokemonCareAssetSchema.CATALOG_SCHEMA,
    eggSpecies = { PIKACHU = "PICHU", SNORLAX = "MUNCHLAX" },
    eggMoves = { PICHU = { "REVERSAL", "BIDE" } },
    incense = { { baby = "MUNCHLAX", item = "FULL_INCENSE", parent = "SNORLAX" } },
  }
end

local function cacheFs(backend)
  return CacheFs.forVersion("heartgold", backend or FakeCache.new())
end

local function stage(cacheFsValue, payload, marker)
  cacheFsValue:writeLua(PokemonCareCache.catalogPath(), payload)
  cacheFsValue:write(PokemonCareCache.markerPath(), marker)
end

local function markerFor(payload)
  return PokemonCareCache.marker(string.rep("a", 40), tostring(#payload))
end

function T.cache_identity_comes_from_the_shared_contract()
  Assert.equal(PokemonCareCache.FORMAT, DerivedAssetContract.pokemonCare.cacheFormat)
  Assert.equal(PokemonCareCache.CATALOG_SCHEMA, DerivedAssetContract.pokemonCare.catalogSchema)
end

function T.catalog_validation_accepts_the_source_tables()
  Assert.isTrue(PokemonCareAssetSchema.isValidCatalog(catalog()), "the source shape validates")
end

function T.catalog_validation_rejects_unknown_fields_and_stale_schemas()
  local extra = catalog()
  extra.version = "soulsilver"
  Assert.isFalse(PokemonCareAssetSchema.isValidCatalog(extra), "an unknown field fails validation")

  local stale = catalog()
  stale.schema = "g4-pokemon-care-catalog-v0"
  Assert.isFalse(PokemonCareAssetSchema.isValidCatalog(stale), "a stale schema identity fails validation")

  local empty = catalog()
  empty.eggSpecies = {}
  Assert.isFalse(PokemonCareAssetSchema.isValidCatalog(empty), "an empty egg-species table fails validation")
end

function T.catalog_validation_rejects_malformed_move_and_incense_rows()
  local repeated = catalog()
  repeated.eggMoves.PICHU = { "REVERSAL", "REVERSAL" }
  Assert.isTrue(
    PokemonCareAssetSchema.isValidCatalog(repeated),
    "the source list may repeat a move inside one block"
  )

  local emptyBlock = catalog()
  emptyBlock.eggMoves.PICHU = {}
  Assert.isFalse(PokemonCareAssetSchema.isValidCatalog(emptyBlock), "an empty egg-move block fails validation")

  local brokenRow = catalog()
  brokenRow.incense = { { baby = "MUNCHLAX", item = "FULL_INCENSE" } }
  Assert.isFalse(PokemonCareAssetSchema.isValidCatalog(brokenRow), "an incomplete incense row fails validation")

  local repeatedBaby = catalog()
  repeatedBaby.incense = {
    { baby = "MUNCHLAX", item = "FULL_INCENSE", parent = "SNORLAX" },
    { baby = "MUNCHLAX", item = "LAX_INCENSE", parent = "WOBBUFFET" },
  }
  Assert.isFalse(
    PokemonCareAssetSchema.isValidCatalog(repeatedBaby),
    "a repeated incense baby fails validation"
  )
end

function T.readiness_proves_the_marker_and_payload()
  local fs = cacheFs()
  local payload = catalog()
  local marker = markerFor(payload)
  Assert.isFalse(PokemonCareCache.isReady(fs, marker), "a cold cache is not ready")
  stage(fs, payload, marker)
  Assert.isTrue(PokemonCareCache.isReady(fs, marker), "a staged payload behind its marker is ready")
  Assert.equal(PokemonCareCache.loadCatalog(fs).schema, payload.schema, "the runtime load returns the payload")
  Assert.isFalse(PokemonCareCache.isReady(fs, marker .. ":stale"), "a superseded marker is not ready")

  local invalid = catalog()
  invalid.incense = {}
  local invalidMarker = markerFor("invalid")
  stage(fs, invalid, invalidMarker)
  Assert.isFalse(PokemonCareCache.isReady(fs, invalidMarker), "an invalid payload never reports ready")
end

return { tests = T }
