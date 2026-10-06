-- Top-level battle-era save envelope: the current schema carries typed
-- encounter and dex buckets plus the native battle-style option, supported
-- older saves migrate without losing existing state, and malformed new
-- state fails at its owning boundary. A battle-era record always restores
-- its actual saved location instead of starting a new game.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local GameSave = require("libs.hgss.src.save.GameSave")
local EncounterSave = require("libs.hgss.src.save.EncounterSave")
local PokedexSave = require("libs.hgss.src.save.PokedexSave")
local BagSave = require("libs.hgss.src.save.BagSave")

local T = {}

local BATTLE_ERA_SCHEMA = "g4-game-save-v6"

local function battleEraRecord(overrides)
  local value = {
    schema = BATTLE_ERA_SCHEMA,
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
    playerData = {
      profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000, badges = 0 },
      options = { textFrame = 0, textSpeed = "mid", battleStyle = "shift" },
    },
    fieldTravel = { lastHealSpawn = "SPAWN_NEW_BARK" },
    world = { flags = {}, variables = {}, objects = {}, rng = { state = 1, calls = 0 } },
    scripts = {},
    auxiliaryUi = {},
    audio = {},
    mons = {},
    bag = BagSave.empty(),
    encounters = EncounterSave.initial(),
    pokedex = PokedexSave.initial(),
  }
  for key, replacement in pairs(overrides or {}) do
    rawset(value, key, replacement)
  end
  return value
end

local function previousRecord(overrides)
  local value = battleEraRecord(overrides)
  value.schema = GameSave.SCHEMA
  value.encounters = nil
  value.pokedex = nil
  value.playerData.options.battleStyle = nil
  return value
end

function T.current_envelope_carries_encounter_dex_and_battle_style()
  Assert.equal(GameSave.SCHEMA, BATTLE_ERA_SCHEMA, "the top-level save envelope carries the battle-era schema")

  local valid = assert(GameSave.validate(battleEraRecord()))
  Assert.equal(valid.schema, BATTLE_ERA_SCHEMA)
  Assert.equal(valid.encounters.schema, EncounterSave.SCHEMA, "the encounter bucket persists under its owner")
  Assert.equal(valid.pokedex.schema, PokedexSave.SCHEMA, "the dex bucket persists under its owner")
  Assert.equal(valid.playerData.options.battleStyle, "shift", "the native battle style persists with options")

  local envelope = assert(GameSave.metadata(battleEraRecord()))
  Assert.equal(envelope.saveId, "save-00000001")
  Assert.equal(envelope.versionId, "heartgold")

  -- The battle-era location restores as field state: the envelope carries
  -- the real saved map and coordinates, never a new-game spawn.
  Assert.equal(valid.mapId, 60)
  Assert.equal(valid.fieldX, 684)
  Assert.equal(valid.fieldZ, 393)
  Assert.equal(valid.facing, "south")
end

function T.supported_saves_migrate_without_losing_state()
  Assert.isTrue(
    type(GameSave.migrateV4) == "function",
    "missing save migration owner: previous supported saves migrate to the battle-era envelope"
  )

  local input = previousRecord({
    world = { flags = { [10] = true }, variables = { [3] = 9 }, objects = {}, rng = { state = 5, calls = 11 } },
    playerData = {
      profile = { name = "GOLD", gender = 0, trainerId = 1, money = 4200, badges = 3 },
      options = { textFrame = 0, textSpeed = "fast" },
    },
  })
  input.schema = GameSave.HISTORICAL_SCHEMA_V4
  input.encounters = nil
  input.pokedex = nil
  local migrated = GameSave.migrateV5(GameSave.migrateV4(input))
  Assert.equal(migrated.schema, BATTLE_ERA_SCHEMA)
  Assert.deepEqual(migrated.world, input.world, "migration preserves world flags, variables, and generator state")
  Assert.deepEqual(migrated.mons, input.mons, "migration preserves the party bucket")
  Assert.deepEqual(migrated.bag, input.bag, "migration preserves the bag bucket")
  Assert.deepEqual(migrated.scripts, input.scripts, "migration preserves the script bucket")
  Assert.deepEqual(migrated.audio, input.audio, "migration preserves the audio bucket")
  Assert.equal(migrated.playerData.profile.money, 4200, "migration preserves the profile")
  Assert.equal(migrated.playerData.profile.badges, 3, "migration preserves earned badges")
  Assert.equal(migrated.mapId, 60, "migration preserves the actual saved location")
  Assert.equal(migrated.fieldX, 684, "migration preserves the actual saved coordinates")
  Assert.deepEqual(migrated.encounters, EncounterSave.initial(), "only genuinely absent encounter state initializes")
  Assert.deepEqual(migrated.pokedex, PokedexSave.initial(), "only genuinely absent dex knowledge initializes")
  Assert.isNil(migrated.battleFrontier, "no Frontier bucket is synthesized")
  Assert.isNil(migrated.fieldTravel.specialSpawn, "an absent special spawn migrates as nil")
  Assert.equal(
    migrated.playerData.options.battleStyle,
    "shift",
    "only the genuinely absent battle style takes the source default"
  )
  Assert.isNil(input.encounters, "migration leaves the input record untouched")

  local validated = assert(GameSave.validate(migrated))
  Assert.equal(validated.schema, BATTLE_ERA_SCHEMA, "the migrated record validates as the current envelope")
end

function T.malformed_new_state_fails_at_its_owning_boundary()
  local function failsWithBucket(bucket, record)
    local valid, err = GameSave.validate(record)
    Assert.isNil(valid, "malformed " .. bucket .. " state never validates")
    Assert.isTrue(Errors.is(err), "malformed " .. bucket .. " state reports a structured failure")
    Assert.equal(err.code, "GAME_SAVE_BUCKET_INVALID")
    Assert.equal(err.context.bucket, bucket)
  end

  local brokenEncounters = battleEraRecord()
  brokenEncounters.encounters = { schema = "bogus-encounter", stateVersion = 1 }
  failsWithBucket("encounters", brokenEncounters)

  local brokenDex = battleEraRecord()
  brokenDex.pokedex = { schema = PokedexSave.SCHEMA, stateVersion = 1, seen = { "EEVEE", "EEVEE" }, caught = {} }
  failsWithBucket("pokedex", brokenDex)

  local brokenStyle = battleEraRecord()
  brokenStyle.playerData.options.battleStyle = "auto"
  local valid, err = GameSave.validate(brokenStyle)
  Assert.isNil(valid, "an unknown battle style never validates")
  Assert.isTrue(Errors.is(err))

  -- Custom content still resolves through selected references: known
  -- custom species validate while removed references fail naming theirs.
  local customRefs = { species = { CHIKORITA = true, CUSTOM_MON = true }, maps = { [60] = true } }
  local customDex = { schema = PokedexSave.SCHEMA, stateVersion = 1, seen = { "CUSTOM_MON" }, caught = {} }
  Assert.notNil(PokedexSave.validate(customDex, customRefs), "selected custom species validate")
  local removedRefs = { species = { CHIKORITA = true } }
  local removedOk, removedErr = pcall(PokedexSave.validate, customDex, removedRefs)
  Assert.isFalse(removedOk, "removed references fail instead of loading")
  Assert.isTrue(Errors.is(removedErr))
end

return { tests = T }
