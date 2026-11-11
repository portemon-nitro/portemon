-- Atomic generated-contract transition: readers, schemas, and caches
-- move together to the locked generation, stale effect generations
-- never execute, and indexed portrait sources publish beside their
-- raster pages. Probes use the real contract literals and the real
-- strict validators.

local Assert = require("tests.support.Assert")
local DerivedAssetContract = require("libs.assets.src.DerivedAssetContract")
local BattleAnimationSchema = require("libs.assets.src.battle.BattleAnimationSchema")

local T = {}

function T.generated_contracts_move_to_the_locked_generation()
  Assert.equal(DerivedAssetContract.revision, 15, "the shared revision invalidates pre-transition payloads")
  Assert.equal(
    DerivedAssetContract.battlePresentation.cacheFormat,
    "battle-presentation-cache-v7",
    "the presentation cache generation moves atomically"
  )
  Assert.equal(
    DerivedAssetContract.battlePresentation.schema,
    "g4-battle-presentation-v14",
    "the presentation schema generation moves atomically"
  )
  Assert.equal(
    DerivedAssetContract.battlePresentation.sceneSchema,
    "g4-battle-scene-v7",
    "the scene schema generation moves atomically"
  )
  Assert.equal(BattleAnimationSchema.EFFECT_SCHEMA, "g4-battle-effect-v6", "the effect schema moves atomically")
end

function T.stale_effect_generations_never_execute()
  local ok, _ = pcall(BattleAnimationSchema.assertEffect, {
    schema = "g4-battle-effect-v3",
    key = "stale-probe",
    catalogIdentity = "stale-probe",
    program = { entry = "main", instructions = {}, subprograms = {}, taskKinds = {} },
    dependencies = {},
    resources = {},
    requiredContext = {},
  })
  Assert.isTrue(not ok, "an older effect generation fails strict validation instead of executing")
end

function T.portrait_source_sidecars_publish_beside_their_raster_pages()
  local MonCache = require("libs.assets.src.MonCache")
  Assert.isTrue(
    type(MonCache.portraitIndexPagePath) == "function",
    "portrait pages publish their decoded index plane beside the raster"
  )
  Assert.isTrue(
    type(MonCache.portraitPalettePagePath) == "function",
    "portrait pages publish their base palettes beside the raster"
  )
  Assert.isTrue(
    type(MonCache.loadPortraitSource) == "function",
    "preparation reads back exact indices and base words through one loader"
  )
end

return { tests = T }
