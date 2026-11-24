-- The generated Day Care care family: a strict semantic catalog carrying the
-- source breeding and NPC trade tables plus the hatch and NPC trade
-- applications' own generated presentations. Validation rejects unknown fields, dangling shells, duplicated
-- entries, and stale schema identities; the cache publishes only validated
-- payloads behind its completion marker.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local DerivedAssetContract = require("libs.assets.src.DerivedAssetContract")
local PokemonCareAssetSchema = require("libs.assets.src.PokemonCareAssetSchema")
local PokemonCareCache = require("libs.assets.src.PokemonCareCache")

local T = {}

local function tradeRecord()
  return {
    offeredSpecies = "ONIX",
    requestedSpecies = "BELLSPROUT",
    personality = 9711,
    otId = 48926,
    ivs = { hp = 25, attack = 20, defense = 25, speed = 15, specialAttack = 15, specialDefense = 15 },
    contest = { cool = 0, beauty = 0, cute = 0, smart = 0, tough = 0 },
    heldItem = "PERSIM_BERRY",
    otGender = 0,
    language = "english",
    nickname = "Rocky",
    otName = "Rudy",
    unusedFlag = 0,
  }
end

local function catalog()
  return {
    schema = PokemonCareAssetSchema.CATALOG_SCHEMA,
    eggSpecies = { PIKACHU = "PICHU", SNORLAX = "MUNCHLAX" },
    eggMoves = { PICHU = { "REVERSAL", "BIDE" } },
    incense = { { baby = "MUNCHLAX", item = "FULL_INCENSE", parent = "SNORLAX" } },
    trades = { tradeRecord() },
  }
end

-- One minimal valid trade presentation payload: the source window, every
-- played scene with its own layers, the chained scene's effect sprite sheet,
-- and the four bank-179 lines.
local function tradeManifest()
  local image = "data/generated/pokemon-care/trade/staged.png"
  local surface = { image = image, width = 256, height = 192 }
  local banked = {
    variants = {
      day = { image = image, width = 256, height = 512 },
      evening = { image = image, width = 256, height = 512 },
      night = { image = image, width = 256, height = 512 },
    },
  }
  local affine = {
    affine = true,
    indices = "data/generated/pokemon-care/trade/depart-1.indices.r8",
    variants = {
      day = { image = image, width = 1024, height = 1024 },
      evening = { image = image, width = 1024, height = 1024 },
      night = { image = image, width = 1024, height = 1024 },
    },
  }
  return {
    schema = PokemonCareAssetSchema.TRADE_SCHEMA,
    window = { x = 16, y = 152, width = 216, height = 32 },
    scenes = {
      send = { layers = { surface } },
      depart = { layers = { affine, surface } },
      recede = { layers = { banked } },
      exchange = { layers = { surface } },
      approach = { layers = { banked } },
      arrive = { layers = { affine, surface } },
      receive = { layers = { surface } },
    },
    balloon = {
      model = {
        schema = "g4-model-v6",
        key = "trade-balloon",
        kind = "static",
        batches = {
          {
            geometry = "data/generated/pokemon-care/trade/geometry/abc.g4mesh",
            material = 0,
            node = 0,
            alphaClass = "opaque",
            cullMode = "back",
            polygonAlpha = 31,
            polygonMode = "modulation",
            polygonId = 0,
            translucentDepthWrite = false,
            depthEqual = false,
            lightMask = 0,
            fogEnabled = false,
            texMtxMode = 0,
            farClipEnabled = false,
            oneDotEnabled = false,
          },
        },
        materials = {
          {
            id = 0,
            name = "ball",
            baseColor = { r = 255, g = 255, b = 255, a = 255 },
            colors = {
              diffuse = { r = 255, g = 255, b = 255 },
              ambient = { r = 255, g = 255, b = 255 },
              specular = { r = 255, g = 255, b = 255 },
              emission = { r = 0, g = 0, b = 0 },
            },
            alphaMode = "opaque",
            polygonMode = "modulation",
            doubleSided = false,
            polygonAlpha = 31,
            texMtxMode = 0,
            texWidth = 8,
            texHeight = 8,
            wrap = { x = "clamp", y = "clamp" },
            flip = { x = false, y = false },
            diffuse = { r = 255, g = 255, b = 255, a = 255 },
            texture = "data/generated/pokemon-care/trade/textures/abc.png",
            textureFormat = 7,
            alphaUsage = { zeroTransparent = false, oneTransparent = false },
          },
        },
      },
    },
    pictures = {
      baseY = 80,
      sentTileX = 20,
      receivedTileX = 2,
      heights = {
        ["BELLSPROUT/f0/male/plain"] = 0,
        ["BELLSPROUT/f0/female/plain"] = 2,
      },
    },
    sprites = {
      effect = {
        sequences = {
          { sequence = 0, frames = { { image = image, width = 8, height = 8, durationTicks = 4 } } },
          { sequence = 1, frames = { { image = image, width = 8, height = 8, durationTicks = 2 } } },
          { sequence = 2, frames = { { image = image, width = 8, height = 8, durationTicks = 1 } } },
          { sequence = 3, frames = { { image = image, width = 8, height = 8, durationTicks = 1 } } },
        },
      },
    },
    messages = {
      send = { id = 0, text = "{sent} will be sent to {player}." },
      farewell = { id = 1, text = "Bye-bye, {sent}!" },
      received = { id = 2, text = "{player} sent over {received}." },
      takeCare = { id = 3, text = "Take good care of {received}!" },
    },
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

local function stage(cacheFsValue, payload, marker, hatch, trade)
  cacheFsValue:writeLua(PokemonCareCache.catalogPath(), payload)
  cacheFsValue:writeLua(PokemonCareCache.hatchManifestPath(), hatch or hatchManifest())
  cacheFsValue:writeLua(PokemonCareCache.tradeManifestPath(), trade or tradeManifest())
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

-- The NPC trade records are part of the same strict catalog: every identity
-- column is required, the individual values and contest values are bounded, and
-- the source's unused ability and sheen columns are not carried at all.
function T.catalog_validation_covers_the_npc_trade_records()
  local withoutTrades = catalog()
  withoutTrades.trades = {}
  Assert.isFalse(PokemonCareAssetSchema.isValidCatalog(withoutTrades), "an empty trade table fails validation")

  local missingNickname = catalog()
  missingNickname.trades[1].nickname = nil
  Assert.isFalse(PokemonCareAssetSchema.isValidCatalog(missingNickname), "a trade record needs its nickname")

  local badIv = catalog()
  badIv.trades[1].ivs.speed = 32
  Assert.isFalse(PokemonCareAssetSchema.isValidCatalog(badIv), "an out-of-range individual value fails")

  local badGender = catalog()
  badGender.trades[1].otGender = 2
  Assert.isFalse(PokemonCareAssetSchema.isValidCatalog(badGender), "an unknown OT gender fails")

  local carriedSheen = catalog()
  carriedSheen.trades[1].sheen = 0
  Assert.isFalse(
    PokemonCareAssetSchema.isValidCatalog(carriedSheen),
    "the source's unused sheen column is never published"
  )
end

function T.trade_manifest_validation_rejects_unknown_fields_and_stale_schemas()
  do
    local ok, failure = pcall(PokemonCareAssetSchema.assertTradeManifest, tradeManifest())
    Assert.isTrue(ok, "the trade payload validates: " .. tostring(failure))
  end

  local extra = tradeManifest()
  extra.version = "soulsilver"
  Assert.isFalse(PokemonCareAssetSchema.isValidTradeManifest(extra), "an unknown field fails validation")

  local stale = tradeManifest()
  stale.schema = "g4-pokemon-care-trade-v0"
  Assert.isFalse(PokemonCareAssetSchema.isValidTradeManifest(stale), "a stale schema identity fails validation")

  local missingBanks = tradeManifest()
  missingBanks.scenes.recede.layers[1].variants.night = nil
  Assert.isFalse(
    PokemonCareAssetSchema.isValidTradeManifest(missingBanks),
    "a banked surface carries every time-of-day bank"
  )

  local mixed = tradeManifest()
  mixed.scenes.send.layers[1] = {
    image = "data/generated/pokemon-care/trade/staged.png",
    width = 8,
    height = 8,
    variants = mixed.scenes.depart.layers[1].variants,
  }
  Assert.isFalse(
    PokemonCareAssetSchema.isValidTradeManifest(mixed),
    "a layer carries either one surface or its banks, never both"
  )

  local missingPhase = tradeManifest()
  missingPhase.scenes.approach = nil
  Assert.isFalse(
    PokemonCareAssetSchema.isValidTradeManifest(missingPhase),
    "every played phase carries its own source scene"
  )

  local emptyScene = tradeManifest()
  emptyScene.scenes.receive.layers = {}
  Assert.isFalse(
    PokemonCareAssetSchema.isValidTradeManifest(emptyScene),
    "a scene draws at least one source layer"
  )

  local missingLine = tradeManifest()
  missingLine.messages.takeCare = nil
  Assert.isFalse(PokemonCareAssetSchema.isValidTradeManifest(missingLine), "the four source lines are required")

  local unindexed = tradeManifest()
  unindexed.scenes.depart.layers[1].indices = nil
  Assert.isFalse(
    PokemonCareAssetSchema.isValidTradeManifest(unindexed),
    "the affine layer publishes its palette-index plane"
  )

  local indexedText = tradeManifest()
  indexedText.scenes.send.layers[1].indices = "data/generated/pokemon-care/trade/send-1.indices.r8"
  Assert.isFalse(
    PokemonCareAssetSchema.isValidTradeManifest(indexedText),
    "only the affine layer carries an index plane"
  )

  local missingSheet = tradeManifest()
  missingSheet.sprites.effect = nil
  Assert.isFalse(PokemonCareAssetSchema.isValidTradeManifest(missingSheet), "the effect sheet is required")

  local emptySheet = tradeManifest()
  emptySheet.sprites.effect.sequences = {}
  Assert.isFalse(
    PokemonCareAssetSchema.isValidTradeManifest(emptySheet),
    "the effect sheet realizes at least one animation sequence"
  )

  local repeatedSequence = tradeManifest()
  repeatedSequence.sprites.effect.sequences[2].sequence = 0
  Assert.isFalse(
    PokemonCareAssetSchema.isValidTradeManifest(repeatedSequence),
    "a sheet publishes each source sequence once"
  )

  local untimedFrame = tradeManifest()
  untimedFrame.sprites.effect.sequences[1].frames[1].durationTicks = nil
  Assert.isFalse(
    PokemonCareAssetSchema.isValidTradeManifest(untimedFrame),
    "a sprite frame carries its source duration"
  )

  local blankWithPixels = tradeManifest()
  blankWithPixels.sprites.effect.sequences[1].frames[1].blank = true
  Assert.isFalse(
    PokemonCareAssetSchema.isValidTradeManifest(blankWithPixels),
    "a blank frame carries no staged pixels"
  )

  local blankFrame = tradeManifest()
  blankFrame.sprites.effect.sequences[4].frames[2] = { blank = true, durationTicks = 3 }
  Assert.isTrue(
    PokemonCareAssetSchema.isValidTradeManifest(blankFrame),
    "the source's blank animation frames carry their own timing"
  )

  local unnamedImage = tradeManifest()
  unnamedImage.sprites.effect.sequences[1].frames[1].image = 8
  Assert.isFalse(
    PokemonCareAssetSchema.isValidTradeManifest(unnamedImage),
    "a sprite frame names its staged image path"
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

function T.readiness_requires_the_trade_presentation()
  local payload = catalog()
  local marker = markerFor(payload)
  local stale = tradeManifest()
  stale.schema = "g4-pokemon-care-trade-v0"
  local withoutTrade = cacheFs()
  stage(withoutTrade, payload, marker, nil, stale)
  Assert.isFalse(PokemonCareCache.isReady(withoutTrade, marker), "a family without its trade payload is not ready")
  Assert.equal(
    #PokemonCareCache.referencedTradePaths(tradeManifest()),
    1,
    "the trade family requests one staged image per distinct surface"
  )
end

return { tests = T }
