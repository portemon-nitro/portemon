-- Field-local host for the reusable Pokemon Naming Screen.

local ApplicationPresentation = require("game.hgss.src.ui.ApplicationPresentation")
local NamingInterface = require("game.hgss.src.newgame.NamingInterface")
local NamingScreenController = require("libs.hgss.src.ui.NamingScreenController")

---@class PokemonNamingState.Options
---@field charmap table<string, integer>
---@field measureDisplay fun(): table<string, unknown>
---@field overrides table<string, unknown>?

---@class PokemonNamingState.Status
---@field done boolean
---@field text string
---@field snapshot NamingScreenSnapshot
---@field presentation ApplicationPlan

---@class PokemonNamingState
---@field private _charmap table<string, integer>
---@field private _measureDisplay fun(): table<string, unknown>
---@field private _overrides table<string, unknown>?
---@field private _controller NamingScreenController?
---@field private _session ApplicationPresentation?
---@field private _presentationReady boolean
---@field isActive fun(self: PokemonNamingState): boolean
---@field setPresentationReady fun(self: PokemonNamingState, ready: boolean)
---@field drawPresentation fun(self: PokemonNamingState, namingRenderer: table<string, function>)
---@field dispose fun(self: PokemonNamingState)
local PokemonNamingState = {}
PokemonNamingState.__index = PokemonNamingState

---@param options PokemonNamingState.Options
---@return PokemonNamingState
function PokemonNamingState.new(options)
  assert(type(options) == "table", "Pokemon naming requires its composition")
  assert(type(options.charmap) == "table", "Pokemon naming requires the field charmap")
  assert(type(options.measureDisplay) == "function", "Pokemon naming requires display measurement")
  return setmetatable({
    _charmap = options.charmap,
    _measureDisplay = options.measureDisplay,
    _overrides = options.overrides,
    _controller = nil,
    _session = nil,
    _presentationReady = true,
  }, PokemonNamingState)
end

---@return boolean
function PokemonNamingState:isActive()
  return self._controller ~= nil
end

local function view(self)
  return assert(self._controller, "Pokemon naming is inactive"):snapshot()
end

function PokemonNamingState:_resolve()
  local session = assert(self._session, "active Pokemon naming owns a presentation session")
  session:resolve(self._measureDisplay(), view(self))
end

function PokemonNamingState:open(spec)
  assert(not self:isActive(), "Pokemon naming is already active")
  assert(type(spec) == "table", "Pokemon naming open requires a spec")
  local subject = {}
  for key, value in pairs(assert(spec.subject, "Pokemon naming requires subject facts")) do
    subject[key] = value
  end
  subject.kind = "pokemon"
  local controller = NamingScreenController.new({
    kind = "pokemon",
    maxLength = assert(spec.maxLength, "Pokemon naming requires its glyph limit"),
    initialText = assert(spec.currentText, "Pokemon naming requires current text"),
    charmap = self._charmap,
    subject = subject,
  })
  local session = ApplicationPresentation.new(NamingInterface.withOverrides(self._overrides))
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

function PokemonNamingState:handleInput(events)
  local controller = assert(self._controller, "Pokemon naming is inactive")
  assert(type(events) == "table", "Pokemon naming requires UI events")
  if not self._presentationReady then
    return
  end
  local session = assert(self._session, "active Pokemon naming owns a presentation session")
  self:_resolve()
  for _, event in ipairs(session:mapInput(events, view(self))) do
    if event.type == "navigate" then
      controller:press(assert(event.direction, "navigation requires a direction"))
    elseif event.type == "confirm" then
      controller:press("confirm")
    elseif event.type == "cancel" then
      controller:press("cancel")
    elseif event.type == "name_cell" then
      controller:activateAt(event.row, event.column)
    elseif event.type == "name_control" then
      controller:activateControl(event.id)
    elseif event.type == "pointer_cancel" then
      -- Pointer cancellation drops capture without changing naming semantics.
    else
      assert(false, "unknown Pokemon naming event " .. tostring(event.type))
    end
  end
  self:_resolve()
end

function PokemonNamingState:updateFixed()
  local controller = self._controller
  if controller == nil or not self._presentationReady then
    return
  end
  controller:updateFixed(2)
  self:_resolve()
end

---@param ready boolean whether FieldPresentationResources can draw this subject
function PokemonNamingState:setPresentationReady(ready)
  assert(self:isActive(), "Pokemon naming is inactive")
  assert(type(ready) == "boolean", "Pokemon naming readiness must be boolean")
  self._presentationReady = ready
end

---@return PokemonNamingState.Status|nil
function PokemonNamingState:status()
  local controller = self._controller
  if controller == nil then
    return nil
  end
  local snapshot = controller:snapshot()
  return {
    done = snapshot.result ~= nil,
    text = snapshot.text,
    snapshot = snapshot,
    presentation = assert(self._session, "active Pokemon naming owns a presentation session"):plan(),
  }
end

function PokemonNamingState:cancelPointerCapture()
  if self._session ~= nil then
    self._session:cancelPointers()
  end
end

function PokemonNamingState:drawPresentation(namingRenderer)
  local status = assert(self:status(), "Pokemon naming is inactive")
  local graphics = assert(love and love.graphics, "Pokemon naming requires graphics")
  ApplicationPresentation.draw(graphics, {
    graphics = graphics,
    namingRenderer = namingRenderer,
  }, status.snapshot, status.presentation)
end

function PokemonNamingState:close()
  assert(self:isActive(), "Pokemon naming is inactive")
  self._session:dispose()
  self._session = nil
  self._controller = nil
  self._presentationReady = false
end

function PokemonNamingState:dispose()
  if self._session ~= nil then
    self._session:dispose()
  end
  self._session = nil
  self._controller = nil
  self._presentationReady = false
end

return PokemonNamingState
