-- Loads and validates one selected save after its derived assets are ready.

local CacheFs = require("libs.storage.src.CacheFs")
local Errors = require("libs.errors.src.Errors")
local RepoFs = require("libs.storage.src.RepoFs")
local SaveFs = require("libs.storage.src.SaveFs")
local GameSaveStore = require("libs.hgss.src.save.GameSaveStore")
local GameSaveValidation = require("libs.hgss.src.save.GameSaveValidation")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local BagCache = require("libs.assets.src.BagCache")
local ScriptSave = require("libs.script.src.ScriptSave")
local SaveEditorSession = require("app.src.saveeditor.SaveEditorSession")

local SaveEditorComposition = {}

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, item in pairs(value) do
    result[key] = copy(item)
  end
  return result
end

---@param options table<string, unknown>
---@return table<string, unknown>
function SaveEditorComposition.open(options)
  assert(type(options) == "table", "save editor composition options are required")
  local versionId = assert(options.versionId)
  local saveId = assert(options.saveId)
  local repoFs = RepoFs.new(assert(options.repositoryRoot))
  local cacheFs = CacheFs.forVersion(versionId)
  local saveFs = SaveFs.global()
  local validation = GameSaveValidation.new({ overrideFs = repoFs })
  local context = validation:contextForVersion(versionId)
  local function validateRecord(record)
    if record.saveId ~= saveId or record.versionId ~= versionId then
      return nil,
        Errors.new("SAVE_EDITOR_IDENTITY_MISMATCH", "The selected save no longer matches its catalog entry.", {
          saveId = saveId,
          versionId = versionId,
        })
    end
    return validation:validate(record, context)
  end
  local store = GameSaveStore.new(saveFs, { recordValidate = validateRecord })
  local validated, loadError = store:load(saveId)
  if validated == nil then
    error(assert(loadError, "save load failed without a structured error"), 0)
  end
  if not ScriptSave.isQuiescent(validated.scripts) then
    error(Errors.new("SAVE_EDITOR_NOT_QUIESCENT", "Resume and save at a stable point before editing this save."), 0)
  end
  local world, worldError = cacheFs:loadLua(MapAssetCache.worldPath())
  if world == nil then
    error(assert(worldError, "field world metadata is missing"), 0)
  end
  local session, sessionError = SaveEditorSession.new({
    record = validated,
    context = context,
    saveStore = store,
    saveFs = saveFs,
    validateRecord = validateRecord,
    symbols = FieldScriptSymbols,
  })
  if session == nil then
    error(assert(sessionError, "save editor session creation failed"), 0)
  end
  return {
    session = session,
    context = context,
    cacheFs = cacheFs,
    bagManifest = BagCache.loadManifest(cacheFs),
    saveFs = saveFs,
    world = world,
    derivedAssets = options.derivedAssets,
    savedObjects = copy(validated.world.objects),
    validation = validation,
    saveStore = store,
  }
end

return SaveEditorComposition
