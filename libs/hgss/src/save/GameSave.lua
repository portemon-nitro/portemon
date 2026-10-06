-- Defines the strict project-owned GameSave record. The storage service owns
-- publication, while PlayerData, world, scripts, UI, audio, and mons modules
-- may inject their authoritative validators at this boundary. Pure domain code.

local Errors = require("libs.errors.src.Errors")
local GameSaveErrors = require("libs.hgss.src.save.GameSaveErrors")
local FieldTravelState = require("libs.hgss.src.field.FieldTravelState")
local FashionCaseState = require("libs.hgss.src.save.FashionCaseState")
local MartSave = require("libs.hgss.src.save.MartSave")
local Mailbox = require("libs.hgss.src.save.Mailbox")
local PhotoAlbum = require("libs.hgss.src.save.PhotoAlbum")

local GameSave = {}

GameSave.SCHEMA = "g4-game-save-v7"
GameSave.LEGACY_V5_SCHEMA = "g4-game-save-v5"
GameSave.LEGACY_V6_SCHEMA = "g4-game-save-v6"
GameSave.MAX_PLAY_TIME_SECONDS = 999 * 60 * 60 + 59 * 60 + 59

local FACING = { north = true, south = true, west = true, east = true }
local TOP_LEVEL_FIELDS = {
  avatar = true,
  audio = true,
  auxiliaryUi = true,
  bag = true,
  facing = true,
  fashionCase = true,
  fieldTravel = true,
  fieldX = true,
  fieldZ = true,
  mapId = true,
  mart = true,
  mailbox = true,
  mons = true,
  playTimeSeconds = true,
  playerData = true,
  photoAlbum = true,
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

local function deepCopy(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, child in pairs(value) do
    result[key] = deepCopy(child)
  end
  return result
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

local function validateLegacyShape(record, schema)
  assert(type(record) == "table" and record.schema == schema, "legacy migration requires its declared schema")
  local allowed = {}
  for key, value in pairs(TOP_LEVEL_FIELDS) do
    if key ~= "fashionCase" and key ~= "mart" and key ~= "mailbox" and key ~= "photoAlbum" then
      allowed[key] = value
    end
  end
  local required = {
    "saveId",
    "versionId",
    "playTimeSeconds",
    "mapId",
    "fieldX",
    "fieldZ",
    "worldY",
    "surfaceId",
    "terrainDependencyHash",
    "facing",
    "playerData",
    "world",
    "scripts",
    "auxiliaryUi",
    "audio",
    "mons",
    "bag",
  }
  if schema == "g4-game-save-v4" then
    required[#required + 1] = "fieldTravel"
  end
  for key in pairs(record) do
    if not allowed[key] then
      Errors.raise(GameSaveErrors.GAME_SAVE_INVALID, "legacy save has an unknown field", { field = key })
    end
  end
  for _, key in ipairs(required) do
    if record[key] == nil then
      Errors.raise(GameSaveErrors.GAME_SAVE_BUCKET_INVALID, "legacy save field is required", { bucket = key })
    end
  end
  for _, key in ipairs({ "playerData", "world", "scripts", "auxiliaryUi", "audio", "mons", "bag" }) do
    if type(record[key]) ~= "table" then
      Errors.raise(GameSaveErrors.GAME_SAVE_BUCKET_INVALID, "legacy save bucket must be a record", { bucket = key })
    end
  end
  if schema == "g4-game-save-v4" and type(record.fieldTravel) ~= "table" then
    Errors.raise(
      GameSaveErrors.GAME_SAVE_BUCKET_INVALID,
      "legacy save fieldTravel bucket is invalid",
      { bucket = "fieldTravel" }
    )
  end
end

local function validateBucket(record, key, opts, validatorKey)
  if type(record[key]) ~= "table" then
    Errors.raise(
      GameSaveErrors.GAME_SAVE_BUCKET_INVALID,
      "game save " .. key .. " bucket is required",
      { bucket = key }
    )
  end
  local validator = opts and opts[validatorKey]
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
        { bucket = key, cause = result.code }
      )
    end
    error(result)
  end
  if Errors.is(result) or result == false or (result == nil and validationErr ~= nil) then
    local cause = Errors.is(validationErr) and validationErr.code or nil
    Errors.raise(GameSaveErrors.GAME_SAVE_BUCKET_INVALID, "game save " .. key .. " bucket is invalid", {
      bucket = key,
      cause = cause,
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

local function validate(record, opts, expectedSchema, requirePc, requireFashionCase)
  expectedSchema = expectedSchema or GameSave.SCHEMA
  if requirePc == nil then
    requirePc = expectedSchema == GameSave.SCHEMA
  end
  if requireFashionCase == nil then
    requireFashionCase = expectedSchema == GameSave.SCHEMA
  end
  if type(record) ~= "table" then
    Errors.raise(GameSaveErrors.GAME_SAVE_INVALID, "game save must be a table", {})
  end
  if record.schema ~= expectedSchema then
    Errors.raise(
      GameSaveErrors.GAME_SAVE_SCHEMA_UNSUPPORTED,
      "unsupported game save schema",
      { schema = record.schema }
    )
  end
  if expectedSchema == GameSave.LEGACY_V6_SCHEMA then
    local hasFashionCase = record.fashionCase ~= nil
    local hasMailbox = record.mailbox ~= nil
    local hasPhotoAlbum = record.photoAlbum ~= nil
    if hasFashionCase and not hasMailbox and not hasPhotoAlbum then
      requireFashionCase = true
    elseif not hasFashionCase and hasMailbox and hasPhotoAlbum then
      requirePc = true
    else
      Errors.raise(GameSaveErrors.GAME_SAVE_INVALID, "v6 save has an incomplete or mixed bucket layout", {})
    end
  end
  for key in pairs(record) do
    if not TOP_LEVEL_FIELDS[key] then
      Errors.raise(GameSaveErrors.GAME_SAVE_INVALID, "unknown game save field", { field = key })
    end
    if
      (not requirePc and (key == "mailbox" or key == "photoAlbum"))
      or (not requireFashionCase and key == "fashionCase")
    then
      Errors.raise(GameSaveErrors.GAME_SAVE_INVALID, "legacy game save carries a current-only bucket", { field = key })
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
  local canonicalMart = validateBucket(record, "mart", opts, "martValidate")
  local canonicalMailbox, canonicalPhotoAlbum
  if requirePc then
    local mailbox = validateBucket(record, "mailbox", opts, "mailboxValidate")
    local photoAlbum = validateBucket(record, "photoAlbum", opts, "photoAlbumValidate")
    Mailbox.validate(mailbox)
    PhotoAlbum.validate(photoAlbum)
    canonicalMailbox, canonicalPhotoAlbum = mailbox, photoAlbum
  end
  local canonicalFieldTravel = validateBucket(record, "fieldTravel", opts, "fieldTravelValidate")
  local canonicalFashionCase
  if requireFashionCase then
    canonicalFashionCase = validateBucket(record, "fashionCase", opts, "fashionCaseValidate")
    FashionCaseState.validate(canonicalFashionCase)
  end
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
  canonical.mart = canonicalMart
  if requirePc then
    canonical.mailbox = canonicalMailbox
    canonical.photoAlbum = canonicalPhotoAlbum
  end
  canonical.fieldTravel = canonicalFieldTravel
  if requireFashionCase then
    canonical.fashionCase = canonicalFashionCase
  end
  canonical.auxiliaryUi = canonicalAuxiliaryUi
  canonical.audio = canonicalAudio
  canonical.avatar = canonicalAvatar
  return canonical
end

-- Pure v3 -> v4 migration: copies every known field without mutating the
-- input, initializes the badge mask to zero (old profiles had no badge
-- owner, so no achievement is invented), and falls back to the documented
-- mother-spawn respawn with no cave entrance. The result still passes
-- through canonical v4 validation afterwards; this step never repairs
-- malformed current data.
---@param record table<string, unknown> a v3 save record
---@return table<string, unknown> the migrated v4 record
function GameSave.migrateV3(record)
  validateLegacyShape(record, "g4-game-save-v3")
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
  migrated.schema = "g4-game-save-v4"
  migrated.fieldTravel = { lastHealSpawn = FieldTravelState.DEFAULT_LAST_HEAL_SPAWN }
  return migrated
end

-- v4 saves predate the national Dex flag and the durable mart bucket.
-- Preserve the existing state and initialize only that master-era delta;
-- Fashion Case arrives through a later dedicated step.
---@param record table<string, unknown> a v4 save record
---@return table<string, unknown> the migrated master-era v5 record
function GameSave.migrateV4(record)
  validateLegacyShape(record, "g4-game-save-v4")
  assert(
    type(record.playerData) == "table" and type(record.playerData.profile) == "table",
    "v4 player data is required"
  )
  if record.fashionCase ~= nil or record.mart ~= nil then
    Errors.raise(GameSaveErrors.GAME_SAVE_INVALID, "v4 save cannot contain v5 buckets", {})
  end
  local migrated = deepCopy(record)
  local profile = migrated.playerData.profile
  profile.nationalDex = false
  migrated.mart = MartSave.empty()
  migrated.schema = GameSave.LEGACY_V5_SCHEMA
  return migrated
end

-- Pure v5 -> v6 conversion. Semantic validation of the old envelope and
-- nested mon records is performed by GameSaveValidation before this copy is
-- accepted for publication.
function GameSave.migrateV5(record)
  assert(type(record) == "table" and record.schema == GameSave.LEGACY_V5_SCHEMA, "GameSave.migrateV5 requires v5")
  local valid, validationError = GameSave.validateV5(record)
  if not valid then
    error(validationError, 0)
  end
  assert(type(record.mons) == "table" and record.mons.schema == "g4-mons-save-v1", "v5 requires the v1 mons bucket")
  local migrated = deepCopy(record)
  migrated.schema = GameSave.LEGACY_V6_SCHEMA
  migrated.fashionCase = FashionCaseState.empty()
  local MonsSave = require("libs.mons.src.MonsSave")
  migrated.mons = MonsSave.migrateV1(migrated.mons)
  return migrated
end

-- Reconciles either independently published v6 layout into the current save.
-- Each historical layout is validated before missing state is initialized.
function GameSave.migrateV6(record)
  assert(type(record) == "table" and record.schema == GameSave.LEGACY_V6_SCHEMA, "GameSave.migrateV6 requires v6")
  local valid, validationError = GameSave.validateV6(record)
  if not valid then
    error(validationError, 0)
  end
  local migrated = deepCopy(record)
  migrated.schema = GameSave.SCHEMA
  migrated.fashionCase = migrated.fashionCase or FashionCaseState.empty()
  migrated.mailbox = migrated.mailbox or Mailbox.new():capture()
  migrated.photoAlbum = migrated.photoAlbum or PhotoAlbum.new():capture()
  return migrated
end

function GameSave.validateV5(record, opts)
  return GameSave.validate(record, opts, GameSave.LEGACY_V5_SCHEMA, false)
end

function GameSave.validateV6(record, opts)
  return GameSave.validate(record, opts, GameSave.LEGACY_V6_SCHEMA)
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
-- is not thereby loadable. Never throws a validation failure: malformed
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
      and record.schema ~= GameSave.LEGACY_V6_SCHEMA
      and record.schema ~= GameSave.LEGACY_V5_SCHEMA
      and record.schema ~= "g4-game-save-v4"
      and record.schema ~= "g4-game-save-v3"
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

---@param record table<string, unknown>
---@param opts table<string, unknown>?
---@param expectedSchema string?
---@param requirePc boolean?
---@return table<string, unknown>|nil, Errors.Error?
function GameSave.validate(record, opts, expectedSchema, requirePc)
  local ok, result = pcall(validate, record, opts, expectedSchema, requirePc)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result --[[@as Errors.Error]]
  end
  error(result)
end

return GameSave
