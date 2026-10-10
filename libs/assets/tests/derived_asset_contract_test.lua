-- DerivedAssetContract is the single consumer-visible identity of derived
-- assets crossing the romdump boundary. Verify cache modules consume its
-- constants so producers and consumers cannot drift apart.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local BattleDataSchema = require("libs.assets.src.battle.BattleDataSchema")
local DerivedAssetContract = require("libs.assets.src.DerivedAssetContract")
local AudioBank = require("libs.assets.src.audio.AudioBank")
local AudioCache = require("libs.assets.src.audio.AudioCache")
local AudioSample = require("libs.assets.src.audio.AudioSample")
local AudioSequence = require("libs.assets.src.audio.AudioSequence")
local CollisionGridAsset = require("libs.assets.src.field.CollisionGridAsset")
local FieldActorCache = require("libs.assets.src.field.FieldActorCache")
local FieldCameraCache = require("libs.assets.src.field.FieldCameraCache")
local FieldFontCache = require("libs.assets.src.field.FieldFontCache")
local FieldEffectAssetCache = require("libs.assets.src.field.FieldEffectAssetCache")
local FieldMapDataCache = require("libs.assets.src.field.FieldMapDataCache")
local FieldMessageCache = require("libs.assets.src.field.FieldMessageCache")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local FieldWeatherCache = require("libs.assets.src.field.FieldWeatherCache")
local NewGameInitCache = require("libs.assets.src.newgame.NewGameInitCache")
local FieldEmoteAssetCache = require("libs.assets.src.field.FieldEmoteAssetCache")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local ScriptCache = require("libs.assets.src.ScriptCache")
local MonCache = require("libs.assets.src.MonCache")
local ItemCache = require("libs.assets.src.ItemCache")
local BattleDataCache = require("libs.assets.src.battle.BattleDataCache")
local BagCache = require("libs.assets.src.BagCache")
local PartyCache = require("libs.assets.src.PartyCache")
local SummaryCache = require("libs.assets.src.SummaryCache")
local SummaryAssetSchema = require("libs.assets.src.SummaryAssetSchema")
local StarterChoiceAssetCache = require("libs.assets.src.StarterChoiceAssetCache")

local T = {}

function T.contract_pins_the_current_asset_identities()
  -- The audio contracts moved to explicit class schemas while the global
  -- revision identifies the current shared generated-asset contracts. The
  -- sequence initial-volume domain is the current NNS table domain.
  Assert.deepEqual(DerivedAssetContract, {
    revision = 12,
    map = {
      cacheFormat = "map-cache-v7",
      sceneSchema = "g4-map-scene-v12",
      terrainSchema = "g4-terrain-surfaces-v1",
      collisionVersion = 1,
    },
    world = {
      schema = "g4-world-v1",
    },
    fieldCells = {
      cacheFormat = "field-cell-cache-v3",
      indexSchema = "g4-field-cell-index-v3",
      cellSchema = "g4-field-cell-v4",
    },
    fieldActors = {
      cacheFormat = "field-actor-cache-v2",
      schema = "g4-field-actor-v4",
      indexSchema = "g4-field-actor-index-v3",
    },
    fieldCamera = {
      cacheFormat = "g4-field-camera-cache-v1",
      schema = "g4-field-camera-profiles-v1",
    },
    fieldMapData = {
      cacheFormat = "g4-field-map-cache-v1",
      fieldSchema = "g4-field-map-v13",
      spawnIndexSchema = "g4-field-spawn-index-v3",
    },
    messages = {
      cacheFormat = "field-message-cache-v3",
      schema = "g4-field-message-bank-v1",
      indexSchema = "g4-field-message-index-v1",
      provenanceSchema = "g4-field-message-provenance-v1",
    },
    font = {
      cacheFormat = "field-font-cache-v6",
      schema = "g4-field-font-v5",
    },
    scripts = {
      cacheFormat = "script-cache-v5",
      indexSchema = "g4-script-index-v4",
      provenanceSchema = "g4-script-provenance-v2",
    },
    fieldWeather = {
      cacheFormat = "field-weather-cache-v1",
      schema = "g4-field-weather-v1",
    },
    newGameInit = {
      cacheFormat = "g4-new-game-init-cache-v1",
      schema = "g4-new-game-init-v3",
    },
    fieldEffects = {
      cacheFormat = "field-effect-cache-v10",
      indexSchema = "g4-field-effect-index-v3",
    },
    followerInteractions = {
      cacheFormat = "follower-interaction-cache-v1",
      schema = "g4-follower-interactions-v4",
    },
    fieldEmotes = {
      cacheFormat = "field-emotes-cache-v3",
      schema = "g4-field-emote-v2",
    },
    fieldUi = {
      cacheFormat = "field-ui-cache-v1",
      schema = "g4-field-ui-v20",
    },
    intro = {
      cacheFormat = "intro-cache-v14",
      schema = "g4-intro-assets-v14",
      provenanceSchema = "g4-intro-provenance-v1",
    },
    starterChoice = {
      cacheFormat = "starter-choice-cache-v7",
      schema = "g4-starter-choice-v7",
    },
    mons = {
      cacheFormat = "mon-cache-v2",
      catalogSchema = "g4-mon-catalog-v4",
      indexSchema = "g4-mon-index-v2",
      iconManifestSchema = "g4-mon-icon-manifest-v2",
      portraitManifestSchema = "g4-mon-portrait-manifest-v2",
    },
    battleData = {
      cacheFormat = "battle-data-cache-v1",
      schema = "g4-battle-data-v1",
    },
    trainerCatalog = {
      cacheFormat = "trainer-catalog-cache-v2",
      schema = "g4-trainer-catalog-v2",
    },
    battlePresentation = {
      cacheFormat = "battle-presentation-cache-v1",
      schema = "g4-battle-presentation-v1",
      sceneSchema = "g4-battle-scene-v1",
    },
    encounterCatalog = {
      cacheFormat = "encounter-catalog-cache-v1",
      schema = "g4-encounter-catalog-v1",
    },
    items = {
      cacheFormat = "item-cache-v4",
      catalogSchema = "g4-item-catalog-v4",
      indexSchema = "g4-item-index-v1",
      iconManifestSchema = "g4-item-icons-v1",
    },
    mart = {
      cacheFormat = "mart-cache-v1",
      catalogSchema = "g4-mart-catalog-v1",
      schema = "g4-mart-presentation-v2",
    },
    bag = {
      cacheFormat = "bag-cache-v2",
      schema = "g4-bag-assets-v17",
    },
    party = {
      cacheFormat = "party-cache-v1",
      schema = "g4-party-presentation-v6",
    },
    pc = {
      cacheFormat = "pc-cache-v1",
      schema = "g4-pc-v2",
    },
    summary = {
      cacheFormat = "g4-summary-cache-v2",
      schema = "g4-summary-manifest-v4",
    },
    audio = {
      cacheFormat = "g4-audio-cache-v1",
      -- The sequence vocabulary and initial-volume domain are strict current
      -- contracts; earlier sequence assets are stale.
      indexSchema = "g4-audio-index-v5",
      sequenceSchema = "g4-audio-sequence-v9",
      bankSchema = "g4-audio-bank-v5",
      sampleSchema = "g4-audio-sample-v4",
      provenanceSchema = "g4-audio-provenance-v1",
    },
  })
end

function T.cache_modules_consume_the_contract_constants()
  Assert.equal(MapAssetCache.FORMAT, DerivedAssetContract.map.cacheFormat)
  Assert.equal(MapAssetCache.SCENE_SCHEMA, DerivedAssetContract.map.sceneSchema)
  Assert.equal(MapAssetCache.TERRAIN_SCHEMA, DerivedAssetContract.map.terrainSchema)
  Assert.equal(CollisionGridAsset.VERSION, DerivedAssetContract.map.collisionVersion)
  Assert.equal(FieldActorCache.FORMAT, DerivedAssetContract.fieldActors.cacheFormat)
  Assert.equal(FieldActorCache.SCHEMA, DerivedAssetContract.fieldActors.schema)
  Assert.equal(FieldActorCache.INDEX_SCHEMA, DerivedAssetContract.fieldActors.indexSchema)
  Assert.equal(FieldCameraCache.FORMAT, DerivedAssetContract.fieldCamera.cacheFormat)
  Assert.equal(FieldCameraCache.SCHEMA, DerivedAssetContract.fieldCamera.schema)
  Assert.equal(FieldMapDataCache.FORMAT, DerivedAssetContract.fieldMapData.cacheFormat)
  Assert.equal(FieldMapDataCache.FIELD_SCHEMA, DerivedAssetContract.fieldMapData.fieldSchema)
  Assert.equal(FieldMapDataCache.SPAWN_INDEX_SCHEMA, DerivedAssetContract.fieldMapData.spawnIndexSchema)
  Assert.equal(FieldMessageCache.FORMAT, DerivedAssetContract.messages.cacheFormat)
  Assert.equal(FieldMessageCache.SCHEMA, DerivedAssetContract.messages.schema)
  Assert.equal(FieldMessageCache.INDEX_SCHEMA, DerivedAssetContract.messages.indexSchema)
  Assert.equal(FieldMessageCache.PROVENANCE_SCHEMA, DerivedAssetContract.messages.provenanceSchema)
  Assert.equal(FieldFontCache.FORMAT, DerivedAssetContract.font.cacheFormat)
  Assert.equal(FieldFontCache.SCHEMA, DerivedAssetContract.font.schema)
  Assert.equal(ScriptCache.FORMAT, DerivedAssetContract.scripts.cacheFormat)
  Assert.equal(ScriptCache.INDEX_SCHEMA, DerivedAssetContract.scripts.indexSchema)
  Assert.equal(ScriptCache.PROVENANCE_SCHEMA, DerivedAssetContract.scripts.provenanceSchema)
  Assert.equal(FieldUiAssetCache.FORMAT, DerivedAssetContract.fieldUi.cacheFormat)
  Assert.equal(FieldUiAssetCache.SCHEMA, DerivedAssetContract.fieldUi.schema)
  Assert.equal(AudioCache.FORMAT, DerivedAssetContract.audio.cacheFormat)
  Assert.equal(AudioCache.INDEX_SCHEMA, DerivedAssetContract.audio.indexSchema)
  Assert.equal(AudioCache.SEQUENCE_SCHEMA, DerivedAssetContract.audio.sequenceSchema)
  Assert.equal(AudioCache.BANK_SCHEMA, DerivedAssetContract.audio.bankSchema)
  Assert.equal(AudioCache.SAMPLE_SCHEMA, DerivedAssetContract.audio.sampleSchema)
  Assert.equal(AudioCache.PROVENANCE_SCHEMA, DerivedAssetContract.audio.provenanceSchema)
  Assert.equal(AudioSequence.SCHEMA, DerivedAssetContract.audio.sequenceSchema)
  Assert.equal(AudioBank.SCHEMA, DerivedAssetContract.audio.bankSchema)
  Assert.equal(AudioSample.SCHEMA, DerivedAssetContract.audio.sampleSchema)
  Assert.equal(FieldWeatherCache.FORMAT, DerivedAssetContract.fieldWeather.cacheFormat)
  Assert.equal(FieldWeatherCache.SCHEMA, DerivedAssetContract.fieldWeather.schema)
  Assert.equal(NewGameInitCache.FORMAT, DerivedAssetContract.newGameInit.cacheFormat)
  Assert.equal(NewGameInitCache.SCHEMA, DerivedAssetContract.newGameInit.schema)
  Assert.equal(FieldEmoteAssetCache.FORMAT, DerivedAssetContract.fieldEmotes.cacheFormat)
  Assert.equal(FieldEmoteAssetCache.SCHEMA, DerivedAssetContract.fieldEmotes.schema)
  Assert.equal(FieldEffectAssetCache.FORMAT, DerivedAssetContract.fieldEffects.cacheFormat)
  Assert.equal(MonCache.FORMAT, DerivedAssetContract.mons.cacheFormat)
  Assert.equal(MonCache.CATALOG_SCHEMA, DerivedAssetContract.mons.catalogSchema)
  Assert.equal(MonCache.INDEX_SCHEMA, DerivedAssetContract.mons.indexSchema)
  Assert.equal(MonCache.ICON_MANIFEST_SCHEMA, DerivedAssetContract.mons.iconManifestSchema)
  Assert.equal(MonCache.PORTRAIT_MANIFEST_SCHEMA, DerivedAssetContract.mons.portraitManifestSchema)
  Assert.equal(BattleDataCache.BATTLE_DATA_SCHEMA, DerivedAssetContract.battleData.schema)
  Assert.equal(BattleDataCache.TRAINER_SCHEMA, DerivedAssetContract.trainerCatalog.schema)
  Assert.equal(BattleDataCache.ENCOUNTER_SCHEMA, DerivedAssetContract.encounterCatalog.schema)
  Assert.equal(ItemCache.FORMAT, DerivedAssetContract.items.cacheFormat)
  Assert.equal(ItemCache.CATALOG_SCHEMA, DerivedAssetContract.items.catalogSchema)
  Assert.equal(ItemCache.INDEX_SCHEMA, DerivedAssetContract.items.indexSchema)
  Assert.equal(ItemCache.ICON_MANIFEST_SCHEMA, DerivedAssetContract.items.iconManifestSchema)
  Assert.equal(BagCache.FORMAT, DerivedAssetContract.bag.cacheFormat)
  Assert.equal(BagCache.SCHEMA, DerivedAssetContract.bag.schema)
  Assert.equal(PartyCache.FORMAT, DerivedAssetContract.party.cacheFormat)
  Assert.equal(PartyCache.SCHEMA, DerivedAssetContract.party.schema)
  Assert.equal(SummaryCache.FORMAT, DerivedAssetContract.summary.cacheFormat)
  Assert.equal(SummaryCache.SCHEMA, DerivedAssetContract.summary.schema)
  Assert.equal(StarterChoiceAssetCache.FORMAT, DerivedAssetContract.starterChoice.cacheFormat)
  Assert.equal(StarterChoiceAssetCache.SCHEMA, DerivedAssetContract.starterChoice.schema)
end

function T.summary_family_carries_the_v4_manifest_schema()
  Assert.equal(
    DerivedAssetContract.summary.cacheFormat,
    "g4-summary-cache-v2",
    "the summary publication roots stay on their cache format"
  )
  Assert.equal(
    DerivedAssetContract.summary.schema,
    "g4-summary-manifest-v4",
    "the summary manifest carries its source-authored schema"
  )
  Assert.equal(
    DerivedAssetContract.mons.catalogSchema,
    "g4-mon-catalog-v4",
    "the mon sibling identity survives the summary schema change"
  )
  Assert.equal(
    DerivedAssetContract.party.schema,
    "g4-party-presentation-v6",
    "the party sibling identity survives the summary schema change"
  )
  Assert.equal(
    DerivedAssetContract.bag.schema,
    "g4-bag-assets-v17",
    "the bag sibling identity survives the summary schema change"
  )
end

function T.party_contract_advertises_the_v6_presentation_schema()
  Assert.equal(DerivedAssetContract.party.cacheFormat, "party-cache-v1")
  Assert.equal(DerivedAssetContract.party.schema, "g4-party-presentation-v6")
end

-- The corrected cursor rasterization invalidates every earlier summary
-- cache: the contract carries the new cache and manifest identities so
-- stale pixels cannot validate or read ready.
function T.corrected_cursor_pixels_invalidate_earlier_summary_caches()
  Assert.equal(
    DerivedAssetContract.summary.cacheFormat,
    "g4-summary-cache-v2",
    "the summary publication roots move past the earlier cursor pixels"
  )
  Assert.equal(
    DerivedAssetContract.summary.schema,
    "g4-summary-manifest-v4",
    "the summary manifest carries the corrected cursor schema"
  )
  Assert.equal(SummaryCache.FORMAT, "g4-summary-cache-v2", "the summary cache reads through the new format")
  Assert.equal(SummaryCache.SCHEMA, "g4-summary-manifest-v4", "the summary cache reads through the new schema")
end

-- Manifests rasterized under the earlier cursor mapping fail the
-- current gate instead of validating beside corrected output.
function T.superseded_cursor_manifests_fail_the_manifest_gate()
  Assert.equal(
    SummaryAssetSchema.SCHEMA,
    "g4-summary-manifest-v4",
    "the manifest gate carries the corrected cursor schema"
  )
  local ok = pcall(SummaryAssetSchema.assertManifest, { schema = "g4-summary-manifest-v3" })
  Assert.isFalse(ok, "a manifest carrying the earlier cursor pixels never validates")
end

local function battleCacheFs()
  return CacheFs.forVersion("heartgold", FakeCache.new())
end

local function validBattlePayloads()
  return {
    battleData = {
      schema = BattleDataCache.BATTLE_DATA_SCHEMA,
      version = { id = "test" },
      moves = {},
    },
    trainers = {
      schema = BattleDataCache.TRAINER_SCHEMA,
      version = { id = "test" },
      trainers = {},
    },
    encounters = {
      schema = BattleDataCache.ENCOUNTER_SCHEMA,
      version = { id = "test" },
      tables = {},
    },
  }
end

-- Runtime loads trust the published schema identity instead of rescanning
-- whole catalogs; full structural rejection stays with explicit readiness.
function T.battle_runtime_loads_skip_full_schema_validation()
  local payloads = validBattlePayloads()
  local c = battleCacheFs()
  c:writeLua(BattleDataCache.battleDataPath(), payloads.battleData)
  c:writeLua(BattleDataCache.trainersPath(), payloads.trainers)
  c:writeLua(BattleDataCache.encountersPath(), payloads.encounters)
  local calls = { battleData = 0, trainers = 0, encounters = 0 }
  local originals = {
    assertBattleData = BattleDataSchema.assertBattleData,
    assertTrainerCatalog = BattleDataSchema.assertTrainerCatalog,
    assertEncounterCatalog = BattleDataSchema.assertEncounterCatalog,
  }
  BattleDataSchema.assertBattleData = function(compiled)
    calls.battleData = calls.battleData + 1
    return originals.assertBattleData(compiled)
  end
  BattleDataSchema.assertTrainerCatalog = function(compiled)
    calls.trainers = calls.trainers + 1
    return originals.assertTrainerCatalog(compiled)
  end
  BattleDataSchema.assertEncounterCatalog = function(compiled)
    calls.encounters = calls.encounters + 1
    return originals.assertEncounterCatalog(compiled)
  end
  local ok, err = pcall(function()
    Assert.deepEqual(
      BattleDataCache.loadBattleData(c),
      payloads.battleData,
      "the published move facts load exactly"
    )
    Assert.deepEqual(
      BattleDataCache.loadTrainers(c),
      payloads.trainers,
      "the published trainer catalog loads exactly"
    )
    Assert.deepEqual(
      BattleDataCache.loadEncounters(c),
      payloads.encounters,
      "the published encounter catalog loads exactly"
    )
    Assert.equal(calls.battleData, 0, "an ordinary battle-data load never rescans the catalog")
    Assert.equal(calls.trainers, 0, "an ordinary trainer load never rescans the catalog")
    Assert.equal(calls.encounters, 0, "an ordinary encounter load never rescans the catalog")
  end)
  BattleDataSchema.assertBattleData = originals.assertBattleData
  BattleDataSchema.assertTrainerCatalog = originals.assertTrainerCatalog
  BattleDataSchema.assertEncounterCatalog = originals.assertEncounterCatalog
  if not ok then
    error(err, 0)
  end
  -- A payload carrying the wrong schema identity still fails at first use.
  local foreign = battleCacheFs()
  foreign:writeLua(BattleDataCache.battleDataPath(), {
    schema = "g4-other-v1",
    version = { id = "test" },
    moves = {},
  })
  local foreignOk = pcall(BattleDataCache.loadBattleData, foreign)
  Assert.isFalse(foreignOk, "a battle payload with the wrong schema never loads")
end

-- Explicit readiness still rejects malformed nested records per family,
-- even when the completion marker matches, and accepts valid payloads.
function T.battle_readiness_rejects_malformed_nested_records()
  local sha = string.rep("c", 40)
  local dep = "readiness-fixture"
  local markers = {
    battleData = BattleDataCache.marker(sha, dep),
    trainers = BattleDataCache.trainersMarker(sha, dep),
    encounters = BattleDataCache.encountersMarker(sha, dep),
  }
  local malformed = {
    battleData = {
      schema = BattleDataCache.BATTLE_DATA_SCHEMA,
      version = { id = "test" },
      moves = { BROKEN = {} },
    },
    trainers = {
      schema = BattleDataCache.TRAINER_SCHEMA,
      version = { id = "test" },
      trainers = { [1] = {} },
    },
    encounters = {
      schema = BattleDataCache.ENCOUNTER_SCHEMA,
      version = { id = "test" },
      tables = { [1] = {} },
    },
  }
  local bad = battleCacheFs()
  bad:writeLua(BattleDataCache.battleDataPath(), malformed.battleData)
  bad:write(BattleDataCache.battleDataMarkerPath(), markers.battleData)
  bad:writeLua(BattleDataCache.trainersPath(), malformed.trainers)
  bad:write(BattleDataCache.trainersMarkerPath(), markers.trainers)
  bad:writeLua(BattleDataCache.encountersPath(), malformed.encounters)
  bad:write(BattleDataCache.encountersMarkerPath(), markers.encounters)
  Assert.isFalse(
    BattleDataCache.isBattleDataReady(bad, markers.battleData),
    "malformed nested move facts fail readiness"
  )
  Assert.isFalse(
    BattleDataCache.isTrainersReady(bad, markers.trainers),
    "malformed nested trainer records fail readiness"
  )
  Assert.isFalse(
    BattleDataCache.isEncountersReady(bad, markers.encounters),
    "malformed nested encounter tables fail readiness"
  )
  local payloads = validBattlePayloads()
  local good = battleCacheFs()
  good:writeLua(BattleDataCache.battleDataPath(), payloads.battleData)
  good:write(BattleDataCache.battleDataMarkerPath(), markers.battleData)
  good:writeLua(BattleDataCache.trainersPath(), payloads.trainers)
  good:write(BattleDataCache.trainersMarkerPath(), markers.trainers)
  good:writeLua(BattleDataCache.encountersPath(), payloads.encounters)
  good:write(BattleDataCache.encountersMarkerPath(), markers.encounters)
  Assert.isTrue(
    BattleDataCache.isBattleDataReady(good, markers.battleData),
    "valid move facts with a matching marker stay ready"
  )
  Assert.isTrue(
    BattleDataCache.isTrainersReady(good, markers.trainers),
    "valid trainer records with a matching marker stay ready"
  )
  Assert.isTrue(
    BattleDataCache.isEncountersReady(good, markers.encounters),
    "valid encounter tables with a matching marker stay ready"
  )
  local unmarked = battleCacheFs()
  unmarked:writeLua(BattleDataCache.battleDataPath(), payloads.battleData)
  unmarked:writeLua(BattleDataCache.trainersPath(), payloads.trainers)
  unmarked:writeLua(BattleDataCache.encountersPath(), payloads.encounters)
  Assert.isFalse(
    BattleDataCache.isBattleDataReady(unmarked, markers.battleData),
    "a missing marker is never ready even when the payload exists"
  )
  Assert.isFalse(
    BattleDataCache.isTrainersReady(unmarked, markers.trainers),
    "a missing trainer marker is never ready even when the payload exists"
  )
  Assert.isFalse(
    BattleDataCache.isEncountersReady(unmarked, markers.encounters),
    "a missing encounter marker is never ready even when the payload exists"
  )
  -- Failed readiness stages nothing: the malformed payload is preserved
  -- verbatim for diagnosis.
  Assert.deepEqual(
    bad:loadLua(BattleDataCache.battleDataPath()),
    malformed.battleData,
    "failed readiness preserves the staged payload"
  )
  Assert.equal(
    bad:read(BattleDataCache.battleDataMarkerPath()),
    markers.battleData,
    "failed readiness preserves the staged marker"
  )
end

return { tests = T }
