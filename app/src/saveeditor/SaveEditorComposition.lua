-- Loads one selected save after its derived assets are ready. The generated
-- catalogs below exist so the editor can present and check edited values;
-- the save itself loads through store normalization without a
-- whole-record validation pass.

local CacheFs = require("libs.storage.src.CacheFs")
local Errors = require("libs.errors.src.Errors")
local SaveFs = require("libs.storage.src.SaveFs")
local GameSaveStore = require("libs.hgss.src.save.GameSaveStore")
local FieldFontLoader = require("libs.hgss.src.ui.FieldFontLoader")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local BagCache = require("libs.assets.src.BagCache")
local MonCache = require("libs.assets.src.MonCache")
local MonCatalog = require("libs.mons.src.MonCatalog")
local ItemCache = require("libs.assets.src.ItemCache")
local ItemCatalog = require("libs.items.src.ItemCatalog")
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
  local cacheFs = CacheFs.forVersion(versionId)
  -- The field-UI manifest is a trusted published artifact: presence through
  -- the ready cache path is sufficient, and the producer pipeline plus
  -- explicit audit own whole-manifest validation.
  local fieldUiManifest, fieldUiError = cacheFs:loadLua(FieldUiAssetCache.manifestPath())
  if type(fieldUiManifest) ~= "table" then
    error(assert(fieldUiError, "field UI manifest is missing"), 0)
  end
  local dialogueFrames = assert(fieldUiManifest.dialogueFrames, "field UI manifest carries dialogue frames")
  assert(type(dialogueFrames.count) == "number", "field UI manifest carries its frame count")
  local frameIndexes = {}
  for frame = 0, dialogueFrames.count - 1 do
    frameIndexes[frame] = true
  end
  local monRoot = MonCache.loadCatalog(cacheFs)
  local itemCatalog = ItemCatalog.new(ItemCache.loadCatalog(cacheFs))
  local context = {
    language = monRoot.version.language,
    charmap = FieldFontLoader.load(cacheFs).charmap,
    frameIndexes = frameIndexes,
    monCatalog = MonCatalog.new(monRoot, itemCatalog),
    itemCatalog = itemCatalog,
  }
  local saveFs = SaveFs.global()
  local store = GameSaveStore.new(saveFs)
  local validated, loadError = store:load(saveId)
  if validated == nil then
    error(assert(loadError, "save load failed without a structured error"), 0)
  end
  if validated.versionId ~= versionId then
    error(
      Errors.new("SAVE_EDITOR_IDENTITY_MISMATCH", "The selected save no longer matches its catalog entry.", {
        saveId = saveId,
        versionId = versionId,
      }),
      0
    )
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
    symbols = FieldScriptSymbols,
  })
  if session == nil then
    error(assert(sessionError, "save editor session creation failed"), 0)
  end
  return {
    session = session,
    context = context,
    cacheFs = cacheFs,
    fieldUiManifest = fieldUiManifest,
    bagManifest = BagCache.loadManifest(cacheFs),
    saveFs = saveFs,
    world = world,
    derivedAssets = options.derivedAssets,
    savedObjects = copy(validated.world.objects),
    saveStore = store,
  }
end

return SaveEditorComposition
