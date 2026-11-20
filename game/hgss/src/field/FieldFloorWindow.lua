-- The source elevator floor box (ScrCmd_ElevatorCurFloorBox ->
-- src/field/script_menu.c::PrintCurFloorInNewWindow): a non-modal four-tile
-- high main-display window with the source title message and the floor label
-- of the current elevator map. The command only shows it and returns; the
-- source lifetime is the result variable, which the script writes a closing
-- sentinel to elsewhere. This host therefore observes that variable and never
-- writes it: the release happens on the sentinel, on field teardown, or never.
-- It owns no script task, no focus, and no input.
--
-- Both source messages expand through the calling script's buffered text, like
-- the source ScriptMenu_PrintMessage running StringExpandPlaceholders against
-- the script's own MessageFormat: the ordinary floor label is the substitution
-- template the script buffers its floor text into, so the resolver receives
-- those text arguments at show time and the window snapshots only the display
-- string the field text renderer draws.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")

---@class FieldFloorWindow.ResolvedMessage
---@field text string the expanded display text
---@field tokens table<string, unknown>[] the expanded glyph stream

---@class FieldFloorWindowOptions
---@field getVar fun(id: string): unknown
---@field resolveMessage fun(ref: string, textArgs: table<string, unknown>): FieldFloorWindow.ResolvedMessage

---@class FieldFloorWindow.OpenWindow
---@field map unknown the map whose floor label table applies
---@field tileX integer
---@field tileY integer
---@field floor unknown the evaluated current floor
---@field resultId string the observed result variable
---@field heightTiles integer
---@field titleMessage string
---@field labelMessage string
---@field labelInset integer
---@field title string the expanded title display text
---@field label string the expanded floor label display text

---@class FieldFloorWindow
---@field private _getVar fun(id: string): unknown
---@field private _resolveMessage fun(ref: string, textArgs: table<string, unknown>): FieldFloorWindow.ResolvedMessage
---@field private _window FieldFloorWindow.OpenWindow|nil
local FieldFloorWindow = {}
FieldFloorWindow.__index = FieldFloorWindow

-- The closing value the source script writes into the result variable.
FieldFloorWindow.CLOSING_SENTINEL = 0xFFFF

-- The source window geometry and message identities (script_menu.c).
FieldFloorWindow.HEIGHT_TILES = 4
local TITLE_MESSAGE = "msg.hgss.0191.00016"
local ORDINARY_FLOOR_MESSAGE = "msg.hgss.0191.00017"
local BASEMENT_FLOOR_MESSAGE = "msg.hgss.0191.00122"
local ROOF_FLOOR_MESSAGE = "msg.hgss.0191.00125"

-- The source label row offset: the floor label is printed on the second row at
-- the width the label message carries (0x20 ordinary, 0x10 roof).
local ORDINARY_LABEL_INSET = 0x20
local ROOF_LABEL_INSET = 0x10

-- GetFloorNameMessage: the elevator families whose ground/top floor carries its
-- own label instead of the ordinal floor number.
local EXCEPTIONAL_FLOOR_LABEL = {
  MAP_GOLDENROD_DEPARTMENT_STORE_ELEVATOR = {
    floor = 0,
    message = BASEMENT_FLOOR_MESSAGE,
    inset = ORDINARY_LABEL_INSET,
  },
  MAP_CELADON_CONDOMINIUMS_LEFT_ELEVATOR = {
    floor = 3,
    message = ROOF_FLOOR_MESSAGE,
    inset = ROOF_LABEL_INSET,
  },
  MAP_CELADON_CONDOMINIUMS_RIGHT_ELEVATOR = {
    floor = 3,
    message = ROOF_FLOOR_MESSAGE,
    inset = ROOF_LABEL_INSET,
  },
}

---@param mapSymbol unknown
---@param floor unknown
---@return string message, integer inset
local function floorLabel(mapSymbol, floor)
  local exceptional = EXCEPTIONAL_FLOOR_LABEL[
    mapSymbol --[[@as string]]
  ]
  if exceptional ~= nil and exceptional.floor == floor then
    return exceptional.message, exceptional.inset
  end
  return ORDINARY_FLOOR_MESSAGE, ORDINARY_LABEL_INSET
end

-- The injected resolver answers with the formatted-message record a source
-- text expansion produces, not a rendered string: the window snapshots the
-- display text the field text renderer draws, so a resolver that answers
-- anything else faults here instead of reaching the renderer.
---@param resolved unknown
---@param message string
---@return string
local function displayText(resolved, message)
  local text = type(resolved) == "table" and resolved.text or nil
  assert(type(text) == "string", "the floor window message resolver answers a formatted message for " .. message)
  return text
end

---@param opts FieldFloorWindowOptions
---@return FieldFloorWindow
function FieldFloorWindow.new(opts)
  assert(type(opts) == "table", "the floor window host needs its options")
  assert(type(opts.getVar) == "function", "the floor window host reads the script variables")
  assert(type(opts.resolveMessage) == "function", "the floor window host resolves source messages")
  return setmetatable({ _getVar = opts.getVar, _resolveMessage = opts.resolveMessage, _window = nil }, FieldFloorWindow)
end

-- Show one source floor box. `request` carries the source tile placement, the
-- evaluated floor value, the map whose label table applies, the calling
-- script's buffered text arguments, and the result variable reference the
-- script later closes. A second box may not open on top of the current one:
-- the source has exactly one such window.
---@param request { map: unknown, tileX: integer, tileY: integer, floor: unknown, textArgs: table<string, unknown>?, result: unknown }
function FieldFloorWindow:show(request)
  assert(type(request) == "table", "the floor window starts from its request")
  if self._window ~= nil then
    Errors.raise(FieldErrors.FIELD_FLOOR_WINDOW_ALREADY_OPEN, "a source floor window is already open", {
      tileX = request.tileX,
      tileY = request.tileY,
    })
  end
  local result = request.result
  assert(
    type(result) == "table" and result.value == "var" and type(result.id) == "string",
    "the floor window lifetime observes the source result variable"
  )
  local floor = assert(request.floor, "the floor window needs the evaluated floor")
  local textArgs = request.textArgs or {}
  local titleMessage = TITLE_MESSAGE
  local labelMessage, labelInset = floorLabel(request.map, floor)
  self._window = {
    map = request.map,
    tileX = request.tileX,
    tileY = request.tileY,
    floor = floor,
    resultId = result.id,
    heightTiles = FieldFloorWindow.HEIGHT_TILES,
    titleMessage = titleMessage,
    labelMessage = labelMessage,
    labelInset = labelInset,
    title = displayText(self._resolveMessage(titleMessage, textArgs), titleMessage),
    label = displayText(self._resolveMessage(labelMessage, textArgs), labelMessage),
  }
end

-- The window the field presents, or nil while no floor box is open.
---@return table<string, unknown>|nil
function FieldFloorWindow:snapshot()
  local window = self._window
  if window == nil then
    return nil
  end
  return {
    map = window.map,
    tileX = window.tileX,
    tileY = window.tileY,
    floor = window.floor,
    result = { value = "var", id = window.resultId },
    heightTiles = window.heightTiles,
    titleMessage = window.titleMessage,
    labelMessage = window.labelMessage,
    labelInset = window.labelInset,
    title = window.title,
    label = window.label,
  }
end

-- The source window task: released when the observed result variable reaches
-- the closing sentinel. Never writes the variable.
function FieldFloorWindow:poll()
  local window = self._window
  if window == nil then
    return
  end
  if self._getVar(window.resultId) == FieldFloorWindow.CLOSING_SENTINEL then
    self._window = nil
  end
end

-- Field teardown: close whatever is open; idempotent.
function FieldFloorWindow:dispose()
  self._window = nil
end

return FieldFloorWindow
