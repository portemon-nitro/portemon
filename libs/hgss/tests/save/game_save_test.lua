-- GameSave envelope tests cover the strict persisted routing boundary while
-- leaving nested-bucket rules with their owning runtime domains.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local GameSave = require("libs.hgss.src.save.GameSave")
local BagSave = require("libs.hgss.src.save.BagSave")
local FashionCaseState = require("libs.hgss.src.save.FashionCaseState")
local MartSave = require("libs.hgss.src.save.MartSave")
local Mailbox = require("libs.hgss.src.save.Mailbox")
local PhotoAlbum = require("libs.hgss.src.save.PhotoAlbum")
local EncounterSave = require("libs.hgss.src.save.EncounterSave")
local PokedexSave = require("libs.hgss.src.save.PokedexSave")

local T = {}

local function record(overrides)
  local value = {
    schema = GameSave.SCHEMA,
    saveId = "save-00000001",
    versionId = "heartgold",
    playTimeSeconds = 0,
    mapId = 60,
    fieldX = 684,
    fieldZ = 393,
    worldY = 0,
    surfaceId = 0,
    terrainDependencyHash = "terrain-heartgold",
    facing = "south",
    playerData = { profile = {}, options = {} },
    fieldTravel = { lastHealSpawn = "SPAWN_NEW_BARK" },
    fashionCase = FashionCaseState.empty(),
    world = { flags = {}, variables = {}, objects = {}, rng = {} },
    scripts = {},
    auxiliaryUi = {},
    audio = {},
    mons = {},
    bag = BagSave.empty(),
    mart = MartSave.empty(),
    mailbox = Mailbox.new():capture(),
    photoAlbum = PhotoAlbum.new():capture(),
    encounters = EncounterSave.initial(),
    pokedex = PokedexSave.initial(),
  }
  for key, replacement in pairs(overrides or {}) do
    rawset(value, key, replacement)
  end
  return value
end

local function returnsCode(code, fn)
  local normalized, err = fn()
  Assert.isNil(normalized)
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, code)
end

function T.normalizes_the_envelope_and_leaves_nested_buckets_untouched()
  local normalized = assert(GameSave.normalize(record()))
  Assert.equal(normalized.saveId, "save-00000001")

  returnsCode("GAME_SAVE_SCHEMA_UNSUPPORTED", function()
    return GameSave.normalize(record({ schema = "g4-field-save-v3" }))
  end)
  returnsCode("GAME_SAVE_SAVE_ID_INVALID", function()
    return GameSave.normalize(record({ saveId = "../escape" }))
  end)
  returnsCode("GAME_SAVE_PLAY_TIME_INVALID", function()
    return GameSave.normalize(record({ playTimeSeconds = 3599999 + 1 }))
  end)
  returnsCode("GAME_SAVE_FIELD_INVALID", function()
    return GameSave.normalize(record({ facing = "up" }))
  end)
  -- Nested buckets travel to their owning domains untouched: a missing or
  -- placeholder bucket still normalizes, and the owner reports the failure
  -- when it restores the state it actually uses.
  Assert.notNil(GameSave.normalize(record({ scripts = nil })))
  Assert.notNil(GameSave.normalize(record({ mons = { fingerprint = "drifted" } })))
end

function T.metadata_extracts_only_the_display_envelope_without_semantic_checks()
  local named = record({ playerData = { profile = { name = "GOLD" } } })
  local envelope = assert(GameSave.metadata(named))
  Assert.deepEqual(envelope, {
    saveId = "save-00000001",
    versionId = "heartgold",
    playerData = { profile = { name = "GOLD" } },
    playTimeSeconds = 0,
  })

  -- Envelope extraction never implies loadability: nested breakage the
  -- owning domains would reject still lists a menu card.
  local nestedBroken = record({ playerData = { profile = { name = "GOLD" } } })
  nestedBroken.mons = { fingerprint = "drifted" }
  nestedBroken.world = {}
  Assert.notNil(GameSave.normalize(nestedBroken))
  Assert.notNil(GameSave.metadata(nestedBroken))

  returnsCode("GAME_SAVE_SCHEMA_UNSUPPORTED", function()
    return GameSave.metadata(record({ schema = "g4-field-save-v3" }))
  end)
  returnsCode("GAME_SAVE_SAVE_ID_INVALID", function()
    return GameSave.metadata(record({ saveId = "../escape" }))
  end)
  returnsCode("GAME_SAVE_VERSION_INVALID", function()
    return GameSave.metadata(record({ versionId = "" }))
  end)
  returnsCode("GAME_SAVE_PLAY_TIME_INVALID", function()
    return GameSave.metadata(record({ playTimeSeconds = -1 }))
  end)
  returnsCode("GAME_SAVE_BUCKET_INVALID", function()
    local value = record()
    value.playerData = { profile = {} }
    return GameSave.metadata(value)
  end)
  returnsCode("GAME_SAVE_INVALID", function()
    return GameSave.metadata("not a record")
  end)
end

function T.live_weather_is_optional_for_legacy_records_and_strict_when_present()
  Assert.isTrue(GameSave.normalize(record({ weatherId = 0 })) ~= nil)
  Assert.isTrue(GameSave.normalize(record({ weatherId = 13 })) ~= nil)
  Assert.isTrue(GameSave.normalize(record({ weatherId = -1 })) == nil)
  Assert.isTrue(GameSave.normalize(record({ weatherId = 14 })) == nil)
  Assert.isTrue(GameSave.normalize(record({ weatherId = 1.5 })) == nil)
  Assert.isTrue(GameSave.normalize(record()) ~= nil)
end


function T.preserves_unrelated_top_level_fields_and_rejects_non_tables()

  returnsCode("GAME_SAVE_INVALID", function()
    ---@diagnostic disable-next-line: param-type-mismatch -- test deliberately exercises an invalid call
    return GameSave.normalize(nil)
  end)




  for _, field in ipairs({ "scenario", "currentState" }) do
    local input = record({ [field] = {} })
    local canonical = assert(GameSave.normalize(input))
    Assert.deepEqual(canonical[field], {})
  end
  Assert.notNil(GameSave.normalize(record()))
end

return { tests = T }
