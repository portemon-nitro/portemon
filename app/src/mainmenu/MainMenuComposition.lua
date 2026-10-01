-- Constructs the app-owned Main Menu and transfers its renderer resources.

local CacheFs = require("libs.storage.src.CacheFs")
local SaveFs = require("libs.storage.src.SaveFs")
local GameSaveStore = require("libs.hgss.src.save.GameSaveStore")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local DisplayContext = require("libs.ui.src.DisplayContext")
local MainMenuRenderer = require("app.src.mainmenu.MainMenuRenderer")
local MainMenuState = require("app.src.mainmenu.MainMenuState")

---@class MainMenuCompositionOptions
---@field versionId string
---@field onResult fun(result: table<string, unknown>)
---@field width number?
---@field height number?

local MainMenuComposition = {}

---@param options MainMenuCompositionOptions
---@return MainMenuState
function MainMenuComposition.new(options)
  assert(type(options) == "table", "Main Menu composition needs options")
  assert(type(options.versionId) == "string" and options.versionId ~= "", "Main Menu needs a selected version")
  assert(type(options.onResult) == "function", "Main Menu needs a result handler")

  local displayContext = DisplayContext.new({})
  local saveStore = GameSaveStore.new(SaveFs.global())
  local text = FieldTextRenderer.new({ cacheFs = CacheFs.forVersion(options.versionId) })
  local rendererOk, rendererOrError = pcall(MainMenuRenderer.new, {
    text = text,
    versionId = options.versionId,
  })
  if not rendererOk then
    pcall(function()
      text:release()
    end)
    error(rendererOrError, 0)
  end
  local renderer = assert(rendererOrError)

  local stateOk, stateOrError = pcall(MainMenuState.new, {
    saveStore = saveStore,
    readyVersions = { options.versionId },
    width = options.width,
    height = options.height,
    renderer = renderer,
    onResult = options.onResult,
    displayContext = displayContext,
  })
  if not stateOk then
    pcall(function()
      renderer:dispose()
    end)
    error(stateOrError, 0)
  end
  return assert(stateOrError)
end

return MainMenuComposition
