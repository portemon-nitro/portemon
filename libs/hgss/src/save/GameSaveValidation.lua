-- Owns version-aware semantic validation for complete persisted GameSave
-- records and the PlayerData boundary used by an in-memory new game.

local CacheFs = require("libs.storage.src.CacheFs")
local FieldFontLoader = require("libs.hgss.src.ui.FieldFontLoader")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local PlayerData = require("libs.hgss.src.save.PlayerData")
local ScriptSave = require("libs.script.src.ScriptSave")
local WorldState = require("libs.hgss.src.script.WorldState")
local AuxiliaryFieldUi = require("libs.hgss.src.ui.AuxiliaryFieldUi")
local FieldAudioSave = require("libs.hgss.src.audio.FieldAudioSave")
local FieldObjectSave = require("libs.hgss.src.save.FieldObjectSave")
local AudioCache = require("libs.assets.src.audio.AudioCache")
local GameSave = require("libs.hgss.src.save.GameSave")
local GameSaveErrors = require("libs.hgss.src.save.GameSaveErrors")
local FieldTravelState = require("libs.hgss.src.field.FieldTravelState")
local FashionCaseState = require("libs.hgss.src.save.FashionCaseState")
local Errors = require("libs.errors.src.Errors")
local FieldScriptCompatibility = require("libs.hgss.src.script.FieldScriptCompatibility")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local MonCache = require("libs.assets.src.MonCache")
local MonCatalog = require("libs.mons.src.MonCatalog")
local ItemCache = require("libs.assets.src.ItemCache")
local ItemCatalog = require("libs.items.src.ItemCatalog")
local BagSave = require("libs.hgss.src.save.BagSave")
local MonsErrors = require("libs.mons.src.errors")
local MonsSave = require("libs.mons.src.MonsSave")
local MartCache = require("libs.assets.src.MartCache")
local MartSave = require("libs.hgss.src.save.MartSave")

---@class GameSaveValidation
---@field contexts table<string, table<string, unknown>>
---@field contextLoader (fun(versionId: string): table<string, unknown>)?
---@field overrideFs table<string, unknown>|nil repository override filesystem for default contexts
local GameSaveValidation = {}
GameSaveValidation.__index = GameSaveValidation

---@param cacheFs CacheFs
---@param overrideFs table<string, unknown>
---@param versionId string
---@return table<string, unknown>
local function contextForCache(cacheFs, overrideFs, versionId)
  local fontDef = FieldFontLoader.load(cacheFs)
  local manifest, loadError = cacheFs:loadLua(FieldUiAssetCache.manifestPath())
  if not manifest then
    error(loadError)
  end
  if type(manifest) ~= "table" or manifest.schema ~= FieldUiAssetCache.SCHEMA then
    error("field UI manifest is invalid")
  end
  local frameIndexes = {}
  for frame = 0, manifest.dialogueFrames.count - 1 do
    frameIndexes[frame] = true
  end
  local index = assert(cacheFs:loadLua(AudioCache.indexPath()), "audio index missing")
  assert(index.schema == AudioCache.INDEX_SCHEMA, "audio index schema is invalid")
  assert(type(index.sequences) == "table", "audio index sequences are required")
  local audioSequenceIds = {}
  for sequenceId, sequence in pairs(index.sequences) do
    assert(type(sequenceId) == "number" and sequence.id == sequenceId, "audio index sequence identity is invalid")
    audioSequenceIds[sequenceId] = true
  end
  -- The mon catalog behind every mons bucket validated in this version:
  -- loaded once per version context through the ready cache path, then
  -- held as the immutable domain catalog its fingerprint belongs to. The
  -- shared item catalog loads beside it: mon composition consumes it now,
  -- and later Bag validation reuses the same version context.
  local monRoot = MonCache.loadCatalog(cacheFs)
  local itemCatalog = ItemCatalog.new(ItemCache.loadCatalog(cacheFs))
  local martCatalog = MartCache.loadCatalog(cacheFs)
  local monCatalog = MonCatalog.new(monRoot, itemCatalog)
  local monLanguage = monRoot.version.language
  assert(
    HgssMonService.GAMES[versionId] ~= nil,
    "GameSave validation requires a native game identity for " .. tostring(versionId)
  )
  assert(
    HgssMonService.LANGUAGES[monLanguage] ~= nil,
    "GameSave validation requires a native language identity for " .. tostring(monLanguage)
  )
  return {
    charmap = fontDef.charmap,
    language = monLanguage,
    frameIndexes = frameIndexes,
    audioSequenceIds = audioSequenceIds,
    scriptCompatibility = FieldScriptCompatibility.new({ cacheFs = cacheFs, overrideFs = overrideFs }),
    monCatalog = monCatalog,
    itemCatalog = itemCatalog,
    martCatalog = martCatalog,
  }
end

---@param bucket table<string, unknown>
---@param options table<string, unknown>
---@return table<string, unknown>
local function rebindScripts(bucket, options)
  local rebound = {}
  for key, value in pairs(bucket) do
    rebound[key] = value
  end
  rebound.registryFingerprint =
    assert(options.expectedRegistryFingerprint, "script compatibility must supply the current registry fingerprint")
  rebound.taskFingerprint =
    assert(options.expectedTaskFingerprint, "script compatibility must supply the current task fingerprint")
  return rebound
end

---@param options table<string, unknown>?
---@return GameSaveValidation
function GameSaveValidation.new(options)
  options = options or {}
  return setmetatable({
    contexts = {},
    contextLoader = options.contextLoader,
    overrideFs = options.overrideFs,
  }, GameSaveValidation)
end

---@param versionId string
---@return table<string, unknown> context borrowed from this validator, read-only
function GameSaveValidation:contextForVersion(versionId)
  local context = self.contexts[versionId]
  if context then
    return context
  end
  context = self.contextLoader and self.contextLoader(versionId)
    or contextForCache(
      CacheFs.forVersion(versionId),
      assert(self.overrideFs, "override filesystem is required"),
      versionId
    )
  assert(type(context) == "table", "GameSave validation context must be a table")
  assert(type(context.audioSequenceIds) == "table", "GameSave validation audio sequence ids are required")
  assert(type(context.scriptCompatibility) == "table", "GameSave script compatibility context is required")
  self.contexts[versionId] = context
  return context
end

---@param record table<string, unknown>
---@param context table<string, unknown>?
---@return table<string, unknown>|nil, Errors.Error?
function GameSaveValidation:validate(record, context)
  local ok, result, err = pcall(function()
    if context == nil and (type(record) ~= "table" or type(record.versionId) ~= "string") then
      return GameSave.validate(record)
    end
    local selected = context or self:contextForVersion(record.versionId)
    -- Explicit v3 -> v4 -> v5 migration before canonical validation. Quiescent
    -- old script buckets rebind to the current fingerprints (counters and
    -- world/RNG data preserved); an incompatible active graph is rejected
    -- with the save bytes untouched, never cleared or rewritten.
    local effective = record
    if type(record) == "table" and (record.schema == "g4-game-save-v3" or record.schema == "g4-game-save-v4") then
      local schema = record.schema
      local options = selected.scriptCompatibility:validationOptions()
      if not ScriptSave.isQuiescent(record.scripts) then
        return nil,
          Errors.new(
            GameSaveErrors.GAME_SAVE_SCHEMA_UNSUPPORTED,
            "historical save carries an active script graph that cannot migrate",
            { schema = schema }
          )
      end
      local oldRecord = schema == "g4-game-save-v3" and GameSave.migrateV3(record) or record
      if schema == "g4-game-save-v3" then
        -- Preserve the existing v3 -> v4 script compatibility boundary.
        oldRecord.scripts = rebindScripts(record.scripts, options)
        oldRecord = GameSave.migrateV4(oldRecord)
      else
        oldRecord = GameSave.migrateV4(oldRecord)
      end
      effective = oldRecord
      effective.scripts = rebindScripts(record.scripts, options)
    end
    if type(effective) == "table" and effective.schema == "g4-game-save-v4" then
      if not isQuiescentScripts(effective.scripts) then
        return nil,
          Errors.new(
            GameSaveErrors.GAME_SAVE_SCHEMA_UNSUPPORTED,
            "v4 save carries an active script graph that cannot migrate to v5",
            { schema = "g4-game-save-v4" }
          )
      end
      local options = selected.scriptCompatibility:validationOptions()
      effective = GameSave.migrateV4(effective)
      effective.scripts = rebindScripts(effective.scripts, options)
    end
    local function playerDataValidate(value)
      return PlayerData.validate(value, selected)
    end
    local function scriptsValidate(value)
      local options = selected.scriptCompatibility:validationOptions()
      return ScriptSave.validate(value, options)
    end
    local function worldValidate(value)
      return WorldState.validate(value, { objectsValidate = FieldObjectSave.validate })
    end
    local function auxiliaryUiValidate(value)
      return AuxiliaryFieldUi.validate(value)
    end
    local function audioValidate(value)
      return FieldAudioSave.validate(value, selected)
    end
    -- The single application owner of mons validation context: the domain
    -- catalog, its fingerprint, the generated charmap, the native
    -- version/language mapping, and the structural met-date checks owned by
    -- the mon record validator. A context without a mon catalog fails
    -- closed: no bucket is ever accepted unvalidated.
    local function monsValidate(value)
      local monCatalog = selected.monCatalog
      if monCatalog == nil then
        MonsErrors.raise(MonsErrors.SAVE_INVALID, "mons validation requires a mon catalog", {})
      end
      assert(monCatalog ~= nil, "mons validation requires a mon catalog")
      -- MonsSave.validate reports success as a boolean; the canonical
      -- bucket itself is what the save record carries forward, so a
      -- re-validated record never degrades the bucket into `true`.
      MonsSave.validate(value, {
        catalog = monCatalog,
        charmap = selected.charmap,
        games = selected.monGames or HgssMonService.GAMES,
        languages = selected.monLanguages or HgssMonService.LANGUAGES,
      })
      return value
    end
    -- The single application owner of bag validation context: the version
    -- item catalog the bag bucket validates against. A context without an
    -- item catalog fails closed: no bucket is ever accepted unvalidated.
    local function bagValidate(value)
      local itemCatalog = selected.itemCatalog
      if itemCatalog == nil then
        Errors.raise(GameSaveErrors.GAME_SAVE_BUCKET_INVALID, "bag validation requires an item catalog", {
          bucket = "bag",
        })
      end
      assert(itemCatalog ~= nil, "bag validation requires an item catalog")
      return BagSave.validate(value, itemCatalog)
    end
    local function martValidate(value)
      local martCatalog = selected.martCatalog
      if martCatalog == nil then
        Errors.raise(GameSaveErrors.GAME_SAVE_BUCKET_INVALID, "mart validation requires a generated mart catalog", {
          bucket = "mart",
        })
      end
      return MartSave.validate(value, martCatalog)
    end
    -- The single application owner of travel validation: the runtime
    -- travel state canonicalizes the record into a copied value record.
    -- Malformed current data fails closed here and is never repaired as
    -- legacy.
    local function fieldTravelValidate(value)
      local travelOk, state = pcall(FieldTravelState.new, value)
      if not travelOk then
        return nil,
          Errors.new(
            GameSaveErrors.GAME_SAVE_BUCKET_INVALID,
            "game save fieldTravel bucket is invalid",
            { bucket = "fieldTravel" }
          )
      end
      return state:capture()
    end
    local function fashionCaseValidate(value)
      local stateOk, state = pcall(FashionCaseState.new, value)
      if not stateOk then
        return nil,
          Errors.new(
            GameSaveErrors.GAME_SAVE_BUCKET_INVALID,
            "game save fashionCase bucket is invalid",
            { bucket = "fashionCase" }
          )
      end
      ---@cast state FashionCaseState
      return state:capture()
    end
    return GameSave.validate(effective, {
      playerDataValidate = playerDataValidate,
      scriptsValidate = scriptsValidate,
      worldValidate = worldValidate,
      auxiliaryUiValidate = auxiliaryUiValidate,
      audioValidate = audioValidate,
      monsValidate = monsValidate,
      bagValidate = bagValidate,
      martValidate = martValidate,
      fieldTravelValidate = fieldTravelValidate,
      fashionCaseValidate = fashionCaseValidate,
    })
  end)
  if ok then
    return result, err
  end
  if Errors.is(result) then
    return nil, result --[[@as Errors.Error]]
  end
  error(result)
end

function GameSaveValidation:validatePlayerData(playerData, context)
  local ok, result, err = pcall(function()
    return PlayerData.validate(playerData, context)
  end)
  if ok then
    return result, err
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result)
end

return GameSaveValidation
