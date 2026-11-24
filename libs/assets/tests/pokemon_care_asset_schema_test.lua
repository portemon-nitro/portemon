-- The generated Day Care care family: a strict semantic catalog carrying the
-- source breeding tables plus the hatch application's own generated
-- presentation. Validation rejects unknown fields, dangling shells, duplicated
-- entries, and stale schema identities; the cache publishes only validated
-- payloads behind its completion marker.

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

-- One minimal valid hatch presentation payload: the family readiness contract
-- requires it beside the catalog the same job publishes.
local function hatchManifest()
  local image = "data/generated/pokemon-care/hatch/staged.png"
  local set = {
    emitters = { { id = 0, textureImage = image } },
    textures = { { image = image, width = 8, height = 8 } },
  }
  return {
    schema = PokemonCareAssetSchema.HATCH_SCHEMA,
    background = { image = image, width = 256, height = 256 },
    window = { x = 16, y = 152, width = 216, height = 32 },
    egg = { frames = { { image = image, width = 8, height = 8, durationTicks = 1 } } },
    bars = { frames = { { image = image, width = 8, height = 8, durationTicks = 1 } } },
    messages = {
      hatched = { id = 0, text = "{name} hatched!" },
      nicknameQuestion = { id = 1, text = "Nickname {name}?" },
      yes = { id = 2, text = "Yes" },
      no = { id = 3, text = "No" },
    },
    particles = { egg = set, manaphy = set },
  }
end

local function cacheFs(backend)
  return CacheFs.forVersion("heartgold", backend or FakeCache.new())
end

local function stage(cacheFsValue, payload, marker, hatch)
  cacheFsValue:writeLua(PokemonCareCache.catalogPath(), payload)
  cacheFsValue:writeLua(PokemonCareCache.hatchManifestPath(), hatch or hatchManifest())
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

function T.hatch_manifest_validation_rejects_unknown_fields_and_stale_schemas()
  Assert.isTrue(PokemonCareAssetSchema.isValidHatchManifest(hatchManifest()), "the hatch payload validates")

  local extra = hatchManifest()
  extra.version = "soulsilver"
  Assert.isFalse(PokemonCareAssetSchema.isValidHatchManifest(extra), "an unknown field fails validation")

  local stale = hatchManifest()
  stale.schema = "g4-pokemon-care-hatch-v0"
  Assert.isFalse(PokemonCareAssetSchema.isValidHatchManifest(stale), "a stale schema identity fails validation")

  local noFrames = hatchManifest()
  noFrames.egg.frames = {}
  Assert.isFalse(PokemonCareAssetSchema.isValidHatchManifest(noFrames), "an empty animation group fails")

  local noParticles = hatchManifest()
  noParticles.particles.egg.emitters = {}
  Assert.isFalse(PokemonCareAssetSchema.isValidHatchManifest(noParticles), "an empty particle set fails")

  local badAlign = hatchManifest()
  badAlign.messages.yes.align = "left"
  Assert.isFalse(PokemonCareAssetSchema.isValidHatchManifest(badAlign), "an unknown alignment fails")
end

function T.readiness_requires_the_hatch_presentation()
  local fs = cacheFs()
  local payload = catalog()
  local marker = markerFor(payload)
  stage(fs, payload, marker)
  Assert.isTrue(PokemonCareCache.isReady(fs, marker), "a staged family is ready")
  local stale = hatchManifest()
  stale.schema = "g4-pokemon-care-hatch-v0"
  local withoutHatch = cacheFs()
  stage(withoutHatch, payload, marker, stale)
  Assert.isFalse(PokemonCareCache.isReady(withoutHatch, marker), "a family without its hatch payload is not ready")
end

return { tests = T }
