-- Per-open purchase child binding the semantic controller to host geometry.

local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local MartController = require("libs.hgss.src.ui.MartController")
local MartInterface = require("game.hgss.src.mart.MartInterface")

---@class MartScreenState
---@field private _controller MartController
---@field private _session table<string, unknown>
---@field private _published table<string, unknown>?
---@field private _publishedKey integer?
---@field private _publishedValid boolean
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

local function copyPublic(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, child in pairs(value) do
    result[key] = copyPublic(child)
  end
  return result
end

---@param opts MartScreenState.Options
---@return MartScreenState
function MartScreenState.new(opts)
  assert(type(opts) == "table", "mart screen options must be a record")
  -- The mart manifest is a trusted published artifact; the controller below
  -- asserts the sections it actually reads.
  local manifest = assert(opts.manifest, "mart screen requires the complete generated mart manifest")
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
    _session = assert(opts.session, "mart screen requires the active session"),
    _published = nil,
    _publishedKey = nil,
    _publishedValid = false,
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
  -- One status serves each input/publication stage. The published status
  -- is reused while the controller left it untouched and the session
  -- projection generation holds; the caller-visible copy stays detached.
  if self._publishedValid and self._published ~= nil and self._publishedKey == self._session:projectionKey() then
    return self._published
  end
  local fresh = self._controller:status()
  self._published, self._publishedKey, self._publishedValid = fresh, self._session:projectionKey(), true
  return fresh
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
  local before = self:_view()
  presentation:resolve(measured, before)
  local mapped = presentation:mapInput(uiEvents, before)
  self._controller:step(mapped)
  self._publishedValid = false
  presentation:resolve(measured, self:_view())
end

---@return table<string, unknown>
function MartScreenState:status()
  assert(not self._disposed, "a disposed mart screen has no status")
  local public = copyPublic(self:_view())
  public.presentation = self._presentation:plan()
  public.plan = public.presentation
  return public
end

---@return table<string, unknown>?
function MartScreenState:takeResult()
  assert(not self._disposed, "a disposed mart screen has no result")
  local result = self._controller:takeResult()
  if result ~= nil then
    self._publishedValid = false
  end
  return result
end

function MartScreenState:cancelPointerCapture()
  assert(not self._disposed, "a disposed mart screen has no capture")
  self._presentation:cancelPointers()
  self._controller:cancelPointerCapture()
  self._publishedValid = false
end

function MartScreenState:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  self._published, self._publishedKey, self._publishedValid = nil, nil, false
  self._presentation:dispose()
  self._controller:dispose()
end

return MartScreenState
