-- Field-local host for the reusable Naming Screen: the source Pokemon
-- nickname and rival naming commands share this one physical screen.

local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local NamingInterface = require("game.hgss.src.newgame.NamingInterface")
local NamingScreenController = require("libs.hgss.src.ui.NamingScreenController")

---@class MonNamingState.Options
---@field charmap table<string, integer>
---@field measureDisplay fun(): table<string, unknown>
---@field overrides table<string, unknown>?
---@field effect fun(sequence: string)

---@class MonNamingState.Status
---@field done boolean
---@field text string
---@field snapshot NamingScreenSnapshot
---@field presentation ApplicationPlan

---@class MonNamingState
---@field private _charmap table<string, integer>
---@field private _measureDisplay fun(): table<string, unknown>
---@field private _effect fun(sequence: string)
---@field private _overrides table<string, unknown>?
---@field private _controller NamingScreenController?
---@field private _session ApplicationPresentation?
---@field private _presentationReady boolean
---@field isActive fun(self: MonNamingState): boolean
---@field setPresentationReady fun(self: MonNamingState, ready: boolean)
---@field drawPresentation fun(self: MonNamingState, namingRenderer: table<string, function>)
---@field dispose fun(self: MonNamingState)
local MonNamingState = {}
MonNamingState.__index = MonNamingState

---@param options MonNamingState.Options
---@return MonNamingState
function MonNamingState.new(options)
  assert(type(options) == "table", "field naming requires its composition")
  assert(type(options.charmap) == "table", "field naming requires the field charmap")
  assert(type(options.measureDisplay) == "function", "field naming requires display measurement")
  assert(type(options.effect) == "function", "field naming requires its sound effect boundary")
  return setmetatable({
    _charmap = options.charmap,
    _effect = options.effect,
    _measureDisplay = options.measureDisplay,
    _overrides = options.overrides,
    _controller = nil,
    _session = nil,
    _presentationReady = true,
  }, MonNamingState)
end

---@return boolean
function MonNamingState:isActive()
  return self._controller ~= nil
end

local function view(self)
  return assert(self._controller, "field naming is inactive"):snapshot()
end

function MonNamingState:_resolve()
  local session = assert(self._session, "active field naming owns a presentation session")
  session:resolve(self._measureDisplay(), view(self))
end

function MonNamingState:open(spec)
  assert(not self:isActive(), "the field naming screen is already active")
  assert(type(spec) == "table", "the field naming screen open requires a spec")
  local kind = spec.kind or "pokemon"
  local subject = {}
  for key, value in pairs(assert(spec.subject, "field naming requires subject facts")) do
    subject[key] = value
  end
  subject.kind = kind
  local controller = NamingScreenController.new({
    kind = kind,
    maxLength = assert(spec.maxLength, "field naming requires its glyph limit"),
    initialText = assert(spec.currentText, "field naming requires current text"),
    charmap = self._charmap,
    subject = subject,
    effect = self._effect,
  })
  local session = ApplicationPresentation.new(NamingInterface.defaults(), self._overrides)
  self._controller = controller
  self._session = session
  self._presentationReady = true
  local ok, err = pcall(function()
    self:_resolve()
  end)
  if not ok then
    self._session:dispose()
    self._session = nil
    self._controller = nil
    error(err, 0)
  end
end

function MonNamingState:handleInput(events)
  local controller = assert(self._controller, "field naming is inactive")
  assert(type(events) == "table", "field naming requires UI events")
  if not self._presentationReady then
    return
  end
  local session = assert(self._session, "active field naming owns a presentation session")
  self:_resolve()
  for _, event in ipairs(session:mapInput(events, view(self))) do
    controller:applyEvent(event)
  end
  self:_resolve()
end

function MonNamingState:updateFixed()
  local controller = self._controller
  if controller == nil or not self._presentationReady then
    return
  end
  controller:updateFixed(2)
  self:_resolve()
end

---@param ready boolean whether FieldPresentationResources can draw this subject
function MonNamingState:setPresentationReady(ready)
  assert(self:isActive(), "field naming is inactive")
  assert(type(ready) == "boolean", "field naming readiness must be boolean")
  self._presentationReady = ready
end

---@return MonNamingState.Status|nil
function MonNamingState:status()
  local controller = self._controller
  if controller == nil then
    return nil
  end
  local snapshot = controller:snapshot()
  return {
    done = snapshot.settled,
    text = snapshot.text,
    snapshot = snapshot,
    presentation = assert(self._session, "active field naming owns a presentation session"):plan(),
  }
end

function MonNamingState:cancelPointerCapture()
  if self._session ~= nil then
    self._session:cancelPointers()
  end
end

function MonNamingState:drawPresentation(namingRenderer)
  local status = assert(self:status(), "field naming is inactive")
  local graphics = assert(love and love.graphics, "field naming requires graphics")
  ApplicationPresentation.draw(graphics, {
    graphics = graphics,
    namingRenderer = namingRenderer,
  }, status.snapshot, status.presentation)
end

function MonNamingState:close()
  assert(self:isActive(), "field naming is inactive")
  self._session:dispose()
  self._session = nil
  self._controller = nil
  self._presentationReady = false
end

function MonNamingState:dispose()
  if self._session ~= nil then
    self._session:dispose()
  end
  self._session = nil
  self._controller = nil
  self._presentationReady = false
end

return MonNamingState
