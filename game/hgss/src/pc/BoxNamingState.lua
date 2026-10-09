-- Box-text editor over the existing HGSS Naming Screen.

local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local NamingInterface = require("game.hgss.src.newgame.NamingInterface")
local NamingScreenController = require("libs.hgss.src.ui.NamingScreenController")

local BoxNamingState = {}
BoxNamingState.__index = BoxNamingState

function BoxNamingState.new(options)
  assert(type(options) == "table", "box naming requires composition")
  assert(type(options.charmap) == "table", "box naming requires the shared charmap")
  assert(type(options.measureDisplay) == "function", "box naming requires display measurement")
  return setmetatable({
    _charmap = options.charmap,
    _measureDisplay = options.measureDisplay,
    _overrides = options.overrides,
    _controller = nil,
    _session = nil,
    _taken = false,
  }, BoxNamingState)
end

function BoxNamingState:open(request)
  assert(self._controller == nil, "box naming is already open")
  assert(type(request) == "table", "box naming receives a source request")
  local text = assert(request.currentText, "box naming receives the existing text")
  local maxLength = assert(request.maxLength, "box naming uses the source request glyph limit")
  local controller = NamingScreenController.new({
    kind = "box",
    maxLength = maxLength,
    initialText = text,
    charmap = self._charmap,
    subject = { kind = "box" },
  })
  local session = ApplicationPresentation.new(NamingInterface.defaults(), self._overrides)
  self._controller, self._session, self._taken = controller, session, false
  local ok, err = pcall(function()
    session:resolve(self._measureDisplay(), controller:snapshot())
  end)
  if not ok then
    session:dispose()
    self._controller, self._session = nil, nil
    error(err, 0)
  end
end

function BoxNamingState:updateFixed(events)
  local controller = self._controller
  if controller == nil then
    return
  end
  local session = assert(self._session)
  session:resolve(self._measureDisplay(), controller:snapshot())
  for _, event in ipairs(session:mapInput(events, controller:snapshot())) do
    controller:applyEvent(event)
  end
  controller:updateFixed(2)
  session:resolve(self._measureDisplay(), controller:snapshot())
end

function BoxNamingState:result()
  local controller = self._controller
  if controller == nil or self._taken then
    return nil
  end
  local result = controller:result()
  if result == nil then
    return nil
  end
  self._taken = true
  return result.kind == "submit" and { kind = "submit", text = result.text } or { kind = "cancel" }
end

function BoxNamingState:dispose()
  if self._session ~= nil then
    self._session:dispose()
  end
  self._session, self._controller = nil, nil
  self._taken = false
end

return BoxNamingState
