-- Defines the strict project-owned GameSave record. The storage service owns
-- publication, while PlayerData, world, scripts, UI, audio, and mons modules
-- may inject their authoritative validators at this boundary. Pure domain code.

local Errors = require("libs.errors.src.Errors")
local GameSaveErrors = require("libs.hgss.src.save.GameSaveErrors")
local FieldTravelState = require("libs.hgss.src.field.FieldTravelState")
local EncounterSave = require("libs.hgss.src.save.EncounterSave")
local PokedexSave = require("libs.hgss.src.save.PokedexSave")
local PlayerData = require("libs.hgss.src.save.PlayerData")

local GameSave = {}

GameSave.SCHEMA = "g4-game-save-v6"
-- Historical envelopes listing still recognizes: v4 records predate the
-- encounter and dex buckets and the battle-style option; v3 records predate
-- those plus the travel bucket and the badge mask. Listing an old envelope
-- implies nothing loadable; semantic validation migrates or rejects it
-- separately.
GameSave.HISTORICAL_SCHEMA_V4 = "g4-game-save-v4"
GameSave.HISTORICAL_SCHEMA_V5 = "g4-game-save-v5"
GameSave.HISTORICAL_SCHEMA_V3 = "g4-game-save-v3"
GameSave.MAX_PLAY_TIME_SECONDS = 999 * 60 * 60 + 59 * 60 + 59

local FACING = { north = true, south = true, west = true, east = true }
local TOP_LEVEL_FIELDS = {
  avatar = true,
  audio = true,
  auxiliaryUi = true,
  bag = true,
  encounters = true,
  facing = true,
  fieldTravel = true,
  fieldX = true,
  fieldZ = true,
  mapId = true,
  mons = true,
  playTimeSeconds = true,
  pokedex = true,
  playerData = true,
  saveId = true,
  schema = true,
  scripts = true,
  surfaceId = true,
  suppression = true,
  terrainDependencyHash = true,
  versionId = true,
  world = true,
  worldY = true,
  weatherId = true,
}

local function finite(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function integer(value)
  return finite(value) and value % 1 == 0
end

local function safeComponent(value)
  return type(value) == "string" and value ~= "" and value:match("^[%w%-_]+$") ~= nil
end

-- Only durable avatar modes persist. A missing record canonicalizes to
-- walking (every save produced before avatar state existed boots walking);
-- any present malformed record is rejected.
local DURABLE_AVATAR_STATES = {
  walking = true,
  cycling = true,
  surfing = true,
  rocket = true,
}

local function validateAvatar(record)
  if record.avatar == nil then
    return { state = "walking" }
  end
  local avatar = record.avatar
  if type(avatar) ~= "table" then
    Errors.raise(GameSaveErrors.GAME_SAVE_FIELD_INVALID, "game save avatar must be a table", {})
  end
  local fieldCount = 0
  for _ in pairs(avatar) do
    fieldCount = fieldCount + 1
  end
  if fieldCount ~= 1 or type(avatar.state) ~= "string" or DURABLE_AVATAR_STATES[avatar.state] ~= true then
    Errors.raise(GameSaveErrors.GAME_SAVE_FIELD_INVALID, "game save avatar state is invalid", { avatar = avatar })
  end
  return { state = avatar.state }
end

local function validateSaveIdRaised(saveId)
  if not safeComponent(saveId) then
    Errors.raise(
      GameSaveErrors.GAME_SAVE_SAVE_ID_INVALID,
      "save id must be one safe path component",
      { saveId = saveId }
    )
  end
end

-- Structural validators for the battle-era buckets. The envelope owns shape
-- and intra-bucket consistency only: references are checked against the
-- bucket's own entries, so unknown selected content still fails loudly at
-- the application validation boundary (which resolves the real content
-- composition) while malformed present data fails here. An existing
-- malformed bucket is never equivalent to an absent one.
---@param bucket unknown
---@return table<string, unknown> canonical detached shape without reference checks
local function defaultEncountersValidate(bucket)
  local species = {}
  local maps = {}
  if type(bucket) == "table" and type(bucket.roamers) == "table" then
    for _, record in pairs(bucket.roamers) do
      if type(record) == "table" then
        if type(record.mon) == "table" and type(record.mon.species) == "string" then
          species[record.mon.species] = true
        end
        local location = record.location
        if type(location) == "string" or (type(location) == "number" and location == location) then
          maps[location] = true
        end
      end
    end
  end
  return EncounterSave.validate(bucket, { species = species, maps = maps })
end

---@param bucket unknown
---@return table<string, unknown> canonical detached shape without reference checks
local function defaultPokedexValidate(bucket)
  local species = {}
  if type(bucket) == "table" then
    for _, key in ipairs({ "seen", "caught" }) do
      if type(bucket[key]) == "table" then
        for _, entry in ipairs(bucket[key]) do
          if type(entry) == "string" then
            species[entry] = true
          end
        end
      end
    end
  end
  return PokedexSave.validate(bucket, { species = species })
end

-- The native battle style defaults to shift for envelopes predating the
-- option; a present unknown style fails at this boundary. PlayerData owns
-- the same rule, so application validation (which runs that owner) and
-- this structural pass always agree.
---@param playerData table<string, unknown>
---@return table<string, unknown> canonical player data with its battle style
local function canonicalizeBattleStyle(playerData)
  if type(playerData) ~= "table" or type(playerData.options) ~= "table" then
    return playerData
  end
  local style = playerData.options.battleStyle
  if style == nil then
    local canonical = {}
    for key, value in pairs(playerData) do
      canonical[key] = value
    end
    local options = {}
    for key, value in pairs(playerData.options) do
      options[key] = value
    end
    options.battleStyle = PlayerData.DEFAULT_BATTLE_STYLE
    canonical.options = options
    return canonical
  end
  if PlayerData.BATTLE_STYLES[style] ~= true then
    Errors.raise(GameSaveErrors.GAME_SAVE_BUCKET_INVALID, "game save playerData battle style is invalid", {
      bucket = "playerData",
      battleStyle = style,
    })
  end
  return playerData
end

local function validateBucket(record, key, opts, validatorKey, defaultValidate)
  if type(record[key]) ~= "table" then
    Errors.raise(
      GameSaveErrors.GAME_SAVE_BUCKET_INVALID,
      "game save " .. key .. " bucket is required",
      { bucket = key }
    )
  end
  local validator = opts and opts[validatorKey]
  if validator == nil then
    validator = defaultValidate
  end
  if validator == nil then
    return record[key]
  end
  assert(type(validator) == "function", validatorKey .. " must be a function")
  local ok, result, validationErr = pcall(validator, record[key])
  if not ok then
    if Errors.is(result) then
      Errors.raise(
        GameSaveErrors.GAME_SAVE_BUCKET_INVALID,
        "game save " .. key .. " bucket is invalid: " .. result.message,
        { bucket = key, cause = result.code, causeContext = result.context }
      )
    end
    error(result)
  end
  if Errors.is(result) or result == false or (result == nil and validationErr ~= nil) then
    local causeErr = Errors.is(result) and result or (Errors.is(validationErr) and validationErr or nil)
    local message = "game save " .. key .. " bucket is invalid"
    if causeErr ~= nil then
      message = message .. ": " .. causeErr.message
    end
    Errors.raise(GameSaveErrors.GAME_SAVE_BUCKET_INVALID, message, {
      bucket = key,
      cause = causeErr and causeErr.code or nil,
      causeContext = causeErr and causeErr.context or nil,
    })
  end
  return result or record[key]
end

local function validateFieldState(record, opts)
  if not safeComponent(record.versionId) then
    Errors.raise(
      GameSaveErrors.GAME_SAVE_VERSION_INVALID,
      "game save version is missing",
      { versionId = record.versionId }
    )
  end
  if not integer(record.mapId) or record.mapId < 0 or record.mapId > 0xFFFF then
    Errors.raise(GameSaveErrors.GAME_SAVE_FIELD_INVALID, "game save map id is invalid", { mapId = record.mapId })
  end
  if not integer(record.fieldX) or record.fieldX < 0 or record.fieldX > 0xFFFF then
    Errors.raise(GameSaveErrors.GAME_SAVE_FIELD_INVALID, "game save field x is invalid", { fieldX = record.fieldX })
  end
  if not integer(record.fieldZ) or record.fieldZ < 0 or record.fieldZ > 0xFFFF then
    Errors.raise(GameSaveErrors.GAME_SAVE_FIELD_INVALID, "game save field z is invalid", { fieldZ = record.fieldZ })
  end
  if not finite(record.worldY) then
    Errors.raise(GameSaveErrors.GAME_SAVE_FIELD_INVALID, "game save world y is invalid", { worldY = record.worldY })
  end
  if not integer(record.surfaceId) or record.surfaceId < 0 or record.surfaceId > 0xFFFF then
    Errors.raise(
      GameSaveErrors.GAME_SAVE_FIELD_INVALID,
      "game save surface id is invalid",
      { surfaceId = record.surfaceId }
    )
  end
  if record.weatherId ~= nil and (not integer(record.weatherId) or record.weatherId < 0 or record.weatherId > 13) then
    Errors.raise(
      GameSaveErrors.GAME_SAVE_FIELD_INVALID,
      "game save weather id is invalid",
      { weatherId = record.weatherId }
    )
  end
  if type(record.terrainDependencyHash) ~= "string" or record.terrainDependencyHash == "" then
    Errors.raise(GameSaveErrors.GAME_SAVE_FIELD_INVALID, "game save terrain dependency is missing", {})
  end
  if not FACING[record.facing] then
    Errors.raise(GameSaveErrors.GAME_SAVE_FIELD_INVALID, "game save facing is invalid", { facing = record.facing })
  end
  local validator = opts and opts.fieldValidate
  if validator ~= nil then
    assert(type(validator) == "function", "fieldValidate must be a function")
    validator(record)
  end
end

local function validate(record, opts)
  if type(record) ~= "table" then
    Errors.raise(GameSaveErrors.GAME_SAVE_INVALID, "game save must be a table", {})
  end
  if record.schema ~= GameSave.SCHEMA then
    Errors.raise(
      GameSaveErrors.GAME_SAVE_SCHEMA_UNSUPPORTED,
      "unsupported game save schema",
      { schema = record.schema }
    )
  end
  for key in pairs(record) do
    if not TOP_LEVEL_FIELDS[key] then
      Errors.raise(GameSaveErrors.GAME_SAVE_INVALID, "unknown game save field", { field = key })
    end
  end
  validateSaveIdRaised(record.saveId)
  validateFieldState(record, opts)
  if
    not integer(record.playTimeSeconds)
    or record.playTimeSeconds < 0
    or record.playTimeSeconds > GameSave.MAX_PLAY_TIME_SECONDS
  then
    Errors.raise(
      GameSaveErrors.GAME_SAVE_PLAY_TIME_INVALID,
      "game save play time exceeds 999:59:59",
      { playTimeSeconds = record.playTimeSeconds }
    )
  end
  local canonicalPlayerData = validateBucket(record, "playerData", opts, "playerDataValidate")
  canonicalPlayerData = canonicalizeBattleStyle(canonicalPlayerData)
  local world = validateBucket(record, "world", opts, "worldValidate")
  for _, key in ipairs({ "flags", "variables", "objects", "rng" }) do
    if type(world[key]) ~= "table" then
      Errors.raise(
        GameSaveErrors.GAME_SAVE_BUCKET_INVALID,
        "game save world bucket is incomplete",
        { bucket = "world." .. key }
      )
    end
  end
  local canonicalScripts = validateBucket(record, "scripts", opts, "scriptsValidate")
  local canonicalMons = validateBucket(record, "mons", opts, "monsValidate")
  local canonicalBag = validateBucket(record, "bag", opts, "bagValidate")
  local canonicalEncounters =
    validateBucket(record, "encounters", opts, "encountersValidate", defaultEncountersValidate)
  local canonicalPokedex = validateBucket(record, "pokedex", opts, "pokedexValidate", defaultPokedexValidate)
  local canonicalFieldTravel = validateBucket(record, "fieldTravel", opts, "fieldTravelValidate")
  local canonicalAuxiliaryUi = validateBucket(record, "auxiliaryUi", opts, "auxiliaryUiValidate")
  local canonicalAudio = validateBucket(record, "audio", opts, "audioValidate")
  local canonicalAvatar = validateAvatar(record)
  local canonical = {}
  for key, value in pairs(record) do
    canonical[key] = value
  end
  canonical.playerData = canonicalPlayerData
  canonical.world = world
  canonical.scripts = canonicalScripts
  canonical.mons = canonicalMons
  canonical.bag = canonicalBag
  canonical.encounters = canonicalEncounters
  canonical.pokedex = canonicalPokedex
  canonical.fieldTravel = canonicalFieldTravel
  canonical.auxiliaryUi = canonicalAuxiliaryUi
  canonical.audio = canonicalAudio
  canonical.avatar = canonicalAvatar
  return canonical
end

-- Pure v3 -> v4 migration: copies every known field without mutating the
-- input, initializes the badge mask to zero (old profiles had no badge
-- owner, so no achievement is invented), and falls back to the documented
-- mother-spawn respawn with no cave entrance. The result is a historical
-- v4 envelope: the battle-era migration carries it the rest of the way.
-- This step never repairs malformed data.
---@param record table<string, unknown> a v3 save record
---@return table<string, unknown> the migrated v4 record
function GameSave.migrateV3(record)
  assert(type(record) == "table", "GameSave.migrateV3 requires a record")
  assert(type(record.playerData) == "table", "GameSave.migrateV3 requires a playerData bucket")
  assert(type(record.playerData.profile) == "table", "GameSave.migrateV3 requires a player profile")
  local migrated = {}
  for key, value in pairs(record) do
    migrated[key] = value
  end
  local profile = {}
  for key, value in pairs(record.playerData.profile) do
    profile[key] = value
  end
  profile.badges = 0
  local playerData = {}
  for key, value in pairs(record.playerData) do
    playerData[key] = value
  end
  playerData.profile = profile
  migrated.playerData = playerData
  migrated.schema = GameSave.HISTORICAL_SCHEMA_V4
  migrated.fieldTravel = { lastHealSpawn = FieldTravelState.DEFAULT_LAST_HEAL_SPAWN }
  return migrated
end

---@param saveId string
---@return boolean|nil, Errors.Error?
function GameSave.validateSaveId(saveId)
  local ok, result = pcall(validateSaveIdRaised, saveId)
  if ok then
    return true
  end
  if Errors.is(result) then
    return nil, result --[[@as Errors.Error]]
  end
  error(result)
end

-- Read-only display envelope for menu listing: save schema/id/version, the
-- display profile name and the integral bounded play time. It performs no
-- generated-cache lookup and implies no semantic validity; a listed record
-- is not thereby loadable. The current schema and the one supported
-- historical envelopes (v5, v4, v3) list; anything else stays unsupported.
-- Never throws a validation failure: malformed
-- input returns a structured error instead.
---@param record unknown
---@return table<string, unknown>|nil, Errors.Error?
function GameSave.metadata(record)
  local ok, envelopeOrError = pcall(function()
    if type(record) ~= "table" then
      Errors.raise(GameSaveErrors.GAME_SAVE_INVALID, "game save must be a table", {})
    end
    assert(type(record) == "table")
    if
      record.schema ~= GameSave.SCHEMA
      and record.schema ~= GameSave.HISTORICAL_SCHEMA_V5
      and record.schema ~= GameSave.HISTORICAL_SCHEMA_V4
      and record.schema ~= GameSave.HISTORICAL_SCHEMA_V3
    then
      Errors.raise(
        GameSaveErrors.GAME_SAVE_SCHEMA_UNSUPPORTED,
        "unsupported game save schema",
        { schema = record.schema }
      )
    end
    validateSaveIdRaised(record.saveId)
    if not safeComponent(record.versionId) then
      Errors.raise(
        GameSaveErrors.GAME_SAVE_VERSION_INVALID,
        "game save version is missing",
        { versionId = record.versionId }
      )
    end
    if
      not integer(record.playTimeSeconds)
      or record.playTimeSeconds < 0
      or record.playTimeSeconds > GameSave.MAX_PLAY_TIME_SECONDS
    then
      Errors.raise(
        GameSaveErrors.GAME_SAVE_PLAY_TIME_INVALID,
        "game save play time exceeds 999:59:59",
        { playTimeSeconds = record.playTimeSeconds }
      )
    end
    local playerData = record.playerData
    if type(playerData) ~= "table" then
      Errors.raise(
        GameSaveErrors.GAME_SAVE_BUCKET_INVALID,
        "game save playerData bucket is required",
        { bucket = "playerData" }
      )
    end
    local profile = playerData.profile
    if type(profile) ~= "table" or type(profile.name) ~= "string" or profile.name == "" then
      Errors.raise(
        GameSaveErrors.GAME_SAVE_BUCKET_INVALID,
        "game save display profile name is required",
        { bucket = "playerData.profile" }
      )
    end
    return {
      saveId = record.saveId,
      versionId = record.versionId,
      playerData = { profile = { name = profile.name } },
      playTimeSeconds = record.playTimeSeconds,
    }
  end)
  if ok then
    return envelopeOrError
  end
  if Errors.is(envelopeOrError) then
    return nil, envelopeOrError --[[@as Errors.Error]]
  end
  error(envelopeOrError)
end

-- V4 migration: fills the genuinely absent battle-era buckets with
-- their defined source defaults while preserving every carried value. The
-- input record is never mutated. Only absence initializes: a present
-- bucket (even an empty one) rides through untouched for validation to
-- judge, and a present malformed battle style fails loudly instead of
-- being repaired. Safe to run over an already-current record.
---@param record table<string, unknown> a previous supported save record
---@return table<string, unknown> the migrated v5 record
function GameSave.migrateV4(record)
  assert(type(record) == "table", "GameSave.migrateV4 requires a record")
  if type(record.playerData) ~= "table" or type(record.playerData.options) ~= "table" then
    Errors.raise(GameSaveErrors.GAME_SAVE_BUCKET_INVALID, "game save playerData bucket is required", {
      bucket = "playerData",
    })
  end
  assert(type(record.playerData) == "table", "the bucket check carries the player record")
  local migrated = {}
  for key, value in pairs(record) do
    migrated[key] = value
  end
  migrated.schema = GameSave.HISTORICAL_SCHEMA_V5
  if migrated.encounters == nil then
    migrated.encounters = EncounterSave.initial()
  end
  if migrated.pokedex == nil then
    migrated.pokedex = PokedexSave.initial()
  end
  local playerData = {}
  for key, value in pairs(migrated.playerData) do
    playerData[key] = value
  end
  local options = {}
  for key, value in pairs(playerData.options) do
    options[key] = value
  end
  if options.battleStyle == nil then
    options.battleStyle = PlayerData.DEFAULT_BATTLE_STYLE
  elseif PlayerData.BATTLE_STYLES[options.battleStyle] ~= true then
    Errors.raise(GameSaveErrors.GAME_SAVE_BUCKET_INVALID, "game save playerData battle style is invalid", {
      bucket = "playerData",
      battleStyle = options.battleStyle,
    })
  end
  playerData.options = options
  migrated.playerData = playerData
  return migrated
end

-- V5 carries no special-spawn writer: migration copies the record, stamps
-- the current schema, and preserves fieldTravel exactly. An absent special
-- spawn stays absent (nil is the canonical unestablished state); neither a
-- Frontier bucket nor a special spawn is fabricated here.
---@param record table<string, unknown> a v5 save record
---@return table<string, unknown> the migrated v6 record
function GameSave.migrateV5(record)
  assert(type(record) == "table", "GameSave.migrateV5 requires a record")
  if record.schema ~= GameSave.HISTORICAL_SCHEMA_V5 then
    Errors.raise(GameSaveErrors.GAME_SAVE_SCHEMA_UNSUPPORTED, "GameSave.migrateV5 requires a v5 save", {
      schema = record.schema,
    })
  end
  local migrated = {}
  for key, value in pairs(record) do
    migrated[key] = value
  end
  migrated.schema = GameSave.SCHEMA
  return migrated
end

---@param record table<string, unknown>
---@param opts table<string, unknown>?
---@return table<string, unknown>|nil, Errors.Error?
function GameSave.validate(record, opts)
  local ok, result = pcall(validate, record, opts)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result --[[@as Errors.Error]]
  end
  error(result)
end

return GameSave
