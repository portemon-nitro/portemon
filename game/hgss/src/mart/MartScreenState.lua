-- Per-open purchase child binding the semantic controller to host geometry.

local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local MartAssetSchema = require("libs.assets.src.MartAssetSchema")
local MartController = require("libs.hgss.src.ui.MartController")
local MartInterface = require("game.hgss.src.mart.MartInterface")

---@class MartScreenState
---@field private _controller MartController
---@field private _presentation ApplicationPresentation
---@field private _measureDisplay fun(): DisplayMeasurement
---@field private _disposed boolean
local MartScreenState = {}
MartScreenState.__index = MartScreenState

---@class MartScreenState.Options
---@field session table<string, unknown>
---@field manifest table<string, unknown>
---@field uiManifest table<string, unknown>
---@field fontDef table<string, unknown>
---@field textPolicy table<string, unknown>
---@field effect (fun(sequence: string|integer))?
---@field measureDisplay fun(): DisplayMeasurement
---@field frameIndex integer
---@field overrides table<string, fun(context: ApplicationLayout.Context, view: table<string, unknown>): ApplicationPlan>?

---@param opts MartScreenState.Options
---@return MartScreenState
function MartScreenState.new(opts)
  assert(type(opts) == "table", "mart screen options must be a record")
  local manifest = assert(opts.manifest, "mart screen requires the complete generated mart manifest")
  MartAssetSchema.assertManifest(manifest)
  local uiManifest = assert(opts.uiManifest, "mart screen requires the field-UI manifest")
  local dialogue = assert(uiManifest.dialogueFrames, "field-UI manifest carries dialogue frames")
  local cursor = assert(dialogue.continueCursor, "field-UI manifest carries the source continuation cursor")
  local prompt = assert(uiManifest.yesNoPrompt, "field-UI manifest carries the compact prompt")
  local promptShape =
    assert(prompt.shapes and prompt.shapes.compact, "field-UI manifest carries compact prompt geometry")
  assert(type(opts.measureDisplay) == "function", "mart screen requires live display measurement")
  assert(
    type(opts.frameIndex) == "number" and opts.frameIndex >= 0 and opts.frameIndex % 1 == 0,
    "mart screen requires the selected frame index"
  )
  local presentation = ApplicationPresentation.new(MartInterface.defaults(manifest), opts.overrides)
  local controller
  local built, buildErr = pcall(function()
    controller = MartController.new({
      session = opts.session,
      manifest = manifest,
      fontDef = opts.fontDef,
      textPolicy = opts.textPolicy,
      effect = opts.effect,
      continueCursor = cursor,
      promptShape = promptShape,
      frameIndex = opts.frameIndex,
    })
  end)
  if not built then
    presentation:dispose()
    if controller ~= nil then
      controller:dispose()
    end
    error(buildErr, 0)
  end
  local self = setmetatable({
    _controller = assert(controller),
    _presentation = presentation,
    _measureDisplay = opts.measureDisplay,
    _disposed = false,
  }, MartScreenState)
  local resolved, resolveErr = pcall(function()
    presentation:resolve(self:_measured(), self:_view())
  end)
  if not resolved then
    self._controller:dispose()
    self._presentation:dispose()
    self._disposed = true
    error(resolveErr, 0)
  end
  return self
end

function MartScreenState:_measured()
  return assert(self._measureDisplay(), "mart display measurement is available")
end

function MartScreenState:_view()
  return self._controller:status()
end

---@return ApplicationPlan
function MartScreenState:refreshPresentation()
  assert(not self._disposed, "a disposed mart screen refreshes nothing")
  return self._presentation:resolve(self:_measured(), self:_view())
end

---@param uiEvents table[]
function MartScreenState:step(uiEvents)
  assert(not self._disposed, "a disposed mart screen steps nothing")
  assert(type(uiEvents) == "table", "mart screen input is an ordered event array")
  local presentation = self._presentation
  local measured = self:_measured()
  presentation:resolve(measured, self:_view())
  local mapped = presentation:mapInput(uiEvents, self:_view())
  self._controller:step(mapped)
  presentation:resolve(measured, self:_view())
end

---@return table<string, unknown>
function MartScreenState:status()
  assert(not self._disposed, "a disposed mart screen has no status")
  local status = self._controller:status()
  status.presentation = self._presentation:plan()
  status.plan = status.presentation
  return status
end

---@return table<string, unknown>?
function MartScreenState:takeResult()
  assert(not self._disposed, "a disposed mart screen has no result")
  return self._controller:takeResult()
end

function MartScreenState:cancelPointerCapture()
  assert(not self._disposed, "a disposed mart screen has no capture")
  self._presentation:cancelPointers()
  self._controller:cancelPointerCapture()
end

function MartScreenState:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  self._presentation:dispose()
  self._controller:dispose()
end

return MartScreenState
