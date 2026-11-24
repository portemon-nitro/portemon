-- The move reminder / singleton tutor application's drawing: the source's own
-- two screens -- the main screen's surface with the subject's Pokémon picture
-- and its name window, and the bottom screen's framed windows, list rows,
-- detail pane, description, message window and TEACH/RETURN buttons -- plus
-- the yes/no prompt the source opens over the message window. Every value
-- drawn comes from an immutable reminder snapshot and from the generated
-- reminder family; the renderer never loads an asset, advances a timer or
-- mutates the lesson.
--
-- The host placement mirrors the other dual-screen children: a genuine
-- world/touch pair draws both screens through their own placements, a wide or
-- tall host places them side by side or stacked, and a single surface shows
-- the interactive screen alone. Pointer taps resolve through the published
-- plan, so the source's list rows, its two buttons and the prompt answers are
-- reachable by mouse and touch as well as by the pad.
--
-- Retail sources (tmp/refs/pokeheartgold):
-- src/application/move_relearner/move_relearner_app.c
-- (sMoveRelearnerWindowTemplates, sMoveRelearnerMessageIds,
-- MoveRelearner_DrawListRows, MoveRelearner_PrintMoveInfo,
-- MoveRelearner_PrintStaticTexts, MoveRelearner_GridOnTouch,
-- MoveRelearner_ShowYesNo) and src/yes_no_prompt.c (the prompt's own button
-- boxes), with the art from NARC_a_1_1_0.

local ApplicationLayout = require("libs.ui.src.ApplicationLayout")
local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
local LogicalSurface = require("libs.ui.src.LogicalSurface")
local PokemonCareInterface = require("libs.hgss.src.ui.PokemonCareInterface")

---@class MoveRelearnerRenderer
---@field private _graphics table<string, unknown>
---@field private _manifest table<string, unknown>
---@field private _images table<string, table<string, unknown>>
---@field private _picture { page: string, frame: { x: integer, y: integer, width: integer, height: integer } }
---@field private _measureDisplay fun(): table<string, unknown>
---@field private _session ApplicationPresentation
---@field private _text table<string, unknown> borrowed field text renderer
---@field private _window table<string, unknown>? borrowed window frame renderer
---@field private _frameIndex integer? the player's selected window frame
---@field private _lines table<integer, table<string, unknown>> compiled source lines by id
local MoveRelearnerRenderer = {}
MoveRelearnerRenderer.__index = MoveRelearnerRenderer

-- The source text ink inside the framed windows (MoveRelearner_PrintString
-- MAKE_TEXT_COLOR(1, 2, 0)).
local TEXT_PALETTE = {
  foreground = { r = 248, g = 248, b = 248, a = 255 },
  shadow = { r = 88, g = 88, b = 88, a = 255 },
  background = { r = 0, g = 0, b = 0, a = 255 },
}
-- MOVE_RELEARNER_VISIBLE_ROWS and the source row height inside the list
-- window's own tiles.
local VISIBLE_ROWS = 4
local ROW_HEIGHT = 32
-- The compiled line columns (sMoveRelearnerMessageIds): the tutor lesson reads
-- its prompts from the first eleven ids and the reminder from the next eleven.
local COLUMN_BASE = {
  tutor = 0,
  relearn = 11,
}
-- The label ids the detail pane, the buttons and the titles draw (msg_0747).
local LABEL = {
  category = 22,
  power = 23,
  accuracy = 24,
  none = 33,
  returnButton = 34,
  teach = 35,
  title = 36,
  monName = 37,
  knownMoves = 39,
}

local MAIN_NATIVE = { id = "main", width = 256, height = 192 }
local SUB_NATIVE = { id = "sub", width = 256, height = 192 }
local INPUT_KEY = "move-relearner"
local ZERO_CROP = { left = 0, right = 0, top = 0, bottom = 0 }

---@param manifest table<string, unknown>
---@return table<integer, table<string, unknown>>
local function lineIndex(manifest)
  local index = {}
  for _, line in ipairs(assert(manifest.messages, "the reminder manifest carries its lines")) do
    local record = assert(line, "a compiled line is a record") --[[@as table<string, unknown>]]
    local id = assert(record.id) --[[@as integer]]
    index[id] = record
  end
  return index
end

---@class MoveRelearnerRenderer.Options
---@field graphics table<string, unknown>
---@field manifest table<string, unknown>
---@field images table<string, table<string, unknown>>
---@field picture { page: string, frame: table<string, integer> }
---@field measureDisplay fun(): table<string, unknown>
---@field text table<string, unknown>
---@field window table<string, unknown>?
---@field frameIndex integer?

---@param opts MoveRelearnerRenderer.Options
---@return MoveRelearnerRenderer
function MoveRelearnerRenderer.new(opts)
  assert(type(opts) == "table", "the reminder renderer requires its options")
  assert(type(opts.graphics) == "table", "the reminder renderer draws through the graphics namespace")
  local manifest = assert(opts.manifest, "the reminder renderer requires its family")
  assert(type(manifest) == "table", "the reminder family arrives as a record")
  assert(type(opts.measureDisplay) == "function", "the reminder renderer requires the display facts")
  assert(type(opts.images) == "table", "the reminder renderer requires its realized images")
  local picture = assert(opts.picture, "the reminder renderer requires its subject picture")
  assert(type(picture.frame) == "table", "the subject picture carries its frame")
  local self = setmetatable({
    _graphics = opts.graphics,
    _manifest = manifest,
    _images = opts.images,
    _picture = picture,
    _measureDisplay = opts.measureDisplay,
    _text = assert(opts.text, "the reminder renderer requires the field text renderer"),
    _window = opts.window,
    _frameIndex = opts.frameIndex,
    _lines = lineIndex(manifest),
  }, MoveRelearnerRenderer)
  local renderer = self
  local function resolveTarget(view, x, y)
    return renderer:targetAt(view, x, y)
  end
  self._session = ApplicationPresentation.new(MoveRelearnerRenderer.interface(manifest, resolveTarget))
  return self
end

---@param path string
---@return table<string, unknown>
function MoveRelearnerRenderer:_image(path)
  return assert(self._images[path], "the reminder image is not realized: " .. tostring(path))
end

-- One framed source window in pixels (the templates carry 8px tiles).
---@param key string
---@return { x: integer, y: integer, width: integer, height: integer, framed: boolean }
function MoveRelearnerRenderer:_box(key)
  local windows = assert(self._manifest.windows, "the reminder manifest carries its windows")
  local record = assert(windows[key], "the reminder manifest carries the " .. key .. " window")
  return {
    x = assert(record.x) --[[@as integer]],
    y = assert(record.y) --[[@as integer]],
    width = assert(record.width) --[[@as integer]],
    height = assert(record.height) --[[@as integer]],
    framed = record.framed == true,
  }
end

-- One compiled source line with its source substitutions filled from the
-- snapshot: the subject's display name and the selected move's name.
---@param id integer
---@param status table<string, unknown>
---@return string?
function MoveRelearnerRenderer:lineText(id, status)
  local line = self._lines[id]
  if line == nil then
    return nil
  end
  local text = assert(line.text, "a compiled line carries its text") --[[@as string]]
  local selected = status.moves[status.cursor + 1 + (status.scrollOffset or 0)]
  local moveName = selected ~= nil and selected.label or nil
  ---@param value string
  ---@return string
  local function escape(value)
    return (value:gsub("%%", "%%%%"))
  end
  text = text:gsub("{mon}", escape(status.nickname --[[@as string]]))
  if moveName ~= nil then
    text = text:gsub("{move}", escape(moveName --[[@as string]]))
  end
  return text
end

---@param box { x: integer, y: integer, width: integer, height: integer, framed: boolean }
---@param text string
local function drawLine(self, box, text)
  assert(type(text) == "string" and text ~= "", "a drawn source line carries its text")
  if box.framed and self._window ~= nil then
    self._window:drawWindow(box, self._frameIndex, self._text:windowBackgroundColor())
  end
  self._text:drawTextWithPalette(text, box.x + 4, box.y + 2, TEXT_PALETTE)
end

-- Prints one source line inside a window the caller already framed.
---@param box { x: integer, y: integer, width: integer, height: integer, framed: boolean }
---@param text string
local function drawTextIn(self, box, text)
  assert(type(text) == "string" and text ~= "", "a drawn source line carries its text")
  self._text:drawTextWithPalette(text, box.x + 4, box.y + 2, TEXT_PALETTE)
end

-- The source list: four rows inside the list window, the focused row drawn
-- with the selection ink and rows past the end of the list left empty.
---@param status table<string, unknown>
function MoveRelearnerRenderer:_drawList(status)
  local box = self:_box("list")
  local rowTop = box.y + 4
  for index, rowIndex in ipairs(status.visible) do
    local record = assert(status.moves[rowIndex], "a drawn list row names its move") --[[@as table<string, unknown>]]
    local y = rowTop + (index - 1) * ROW_HEIGHT
    if (index - 1) == status.cursor then
      self._text:drawFocusIndicator(nil, box.x + 4, y + 2)
    end
    self._text:drawTextWithPalette(assert(record.label) --[[@as string]], box.x + 8, y + 6, TEXT_PALETTE)
  end
  local knownTitle = self._lines[LABEL.knownMoves]
  if knownTitle ~= nil then
    drawLine(self, self:_box("knownTitle"), assert(knownTitle.text) --[[@as string]])
  end
end

-- The detail pane (MoveRelearner_PrintMoveInfo): the selected move's category,
-- its power or "---", its accuracy or "---" and its PP.
---@param status table<string, unknown>
function MoveRelearnerRenderer:_drawDetail(status)
  local selected = status.moves[status.cursor + 1 + (status.scrollOffset or 0)]
  local none = self._lines[LABEL.none]
  local noneText = none ~= nil and assert(none.text) --[[@as string]] or "---"
  local function label(id, key)
    local line = self._lines[id]
    if line ~= nil then
      drawLine(self, self:_box(key), assert(line.text) --[[@as string]])
    end
  end
  label(LABEL.category, "categoryLabel")
  label(LABEL.power, "powerLabel")
  label(LABEL.accuracy, "accuracyLabel")
  if selected == nil then
    return
  end
  local value = assert(selected) --[[@as table<string, unknown>]]
  drawLine(self, self:_box("power"), value.power > 1 and tostring(value.power) or noneText)
  drawLine(self, self:_box("accuracy"), value.accuracy ~= 0 and tostring(value.accuracy) or noneText)
  local description = assert(value.description, "a catalog move carries its description") --[[@as string]]
  if description ~= "" then
    drawLine(self, self:_box("description"), description)
  end
end

-- The source buttons: the TEACH/RETURN tile sheet under the framed captions,
-- with the flashing button drawn in the source's pressed state.
---@param status table<string, unknown>
function MoveRelearnerRenderer:_drawButtons(status)
  local buttons = assert(self._manifest.buttons, "the reminder manifest carries its button tiles") --[[@as table]]
  local lg = self._graphics
  lg.setColor(1, 1, 1, 1)
  lg.draw(self:_image(assert(buttons.image) --[[@as string]]), 0, 0)
  local teach = self:_box("teach")
  local returnButton = self:_box("returnButton")
  local teachLine = self._lines[LABEL.teach]
  if teachLine ~= nil then
    drawLine(self, teach, assert(teachLine.text) --[[@as string]])
  end
  local returnLine = self._lines[LABEL.returnButton]
  if returnLine ~= nil then
    drawLine(self, returnButton, assert(returnLine.text) --[[@as string]])
  end
  if status.flash == "teach" then
    self._text:drawFocusIndicator(nil, teach.x, teach.y)
  elseif status.flash == "return" then
    self._text:drawFocusIndicator(nil, returnButton.x, returnButton.y)
  end
end

-- The message window prints the current source line; an open question draws the
-- source's two prompt boxes with the held answer highlighted.
---@param status table<string, unknown>
function MoveRelearnerRenderer:_drawMessage(status)
  local window = self._window
  if window == nil then
    return
  end
  local box = self:_box("message")
  window:drawWindow(box, self._frameIndex, self._text:windowBackgroundColor())
  local message = status.message
  if message ~= nil then
    local mode = assert(status.mode, "a reminder snapshot names its mode")
    local base = assert(COLUMN_BASE[mode], "a reminder snapshot names the source line column")
    local line = self:lineText(base + message, status)
    if line ~= nil then
      drawTextIn(self, box, line)
    end
  end
  local question = status.question
  if question == nil then
    return
  end
  for _, entry in ipairs({ { key = "promptYes", answer = "yes" }, { key = "promptNo", answer = "no" } }) do
    local target = self:_box(entry.key)
    window:drawWindow(target, self._frameIndex, self._text:windowBackgroundColor())
    if question.selection == entry.answer then
      self._text:drawFocusIndicator(nil, target.x + 4, target.y + 4)
    end
  end
end

-- The main screen: the source's own surface, the subject's Pokémon picture at
-- the source centre and the mon-name window.
---@param status table<string, unknown>
function MoveRelearnerRenderer:_drawMain(status)
  local lg = self._graphics
  local main = assert(self._manifest.main, "the reminder manifest carries its top screen") --[[@as table]]
  lg.setColor(1, 1, 1, 1)
  lg.draw(self:_image(assert(main.image) --[[@as string]]), 0, 0)
  local picture = self._picture
  local frame = picture.frame
  local image = self:_image(picture.page)
  local width = assert(frame.width) --[[@as number]]
  local height = assert(frame.height) --[[@as number]]
  -- The source centres the Pokémon picture over its main screen and stands it on
  -- the screen's lower edge; the picture's own frame carries the size.
  local x = (256 - width) / 2
  local y = 192 - height
  lg.draw(image, x - frame.x, y - frame.y)
  local monName = self:lineText(LABEL.monName, status)
  if monName ~= nil then
    drawLine(self, self:_box("monName"), monName)
  end
end

-- Draws one screen of the pair through its placement. Only the sub screen is
-- interactive: the source's touch targets live on the touch screen.
---@param status table<string, unknown>
---@param paneId string
function MoveRelearnerRenderer:drawPane(status, paneId)
  if paneId == "main" then
    self:_drawMain(status)
    return
  end
  assert(paneId == "sub", "the reminder draws its main and sub screens")
  local lg = self._graphics
  local sub = assert(self._manifest.sub, "the reminder manifest carries its bottom screen") --[[@as table]]
  lg.setColor(1, 1, 1, 1)
  lg.draw(self:_image(assert(sub.image) --[[@as string]]), 0, 0)
  local title = self._lines[LABEL.title]
  if title ~= nil then
    drawLine(self, self:_box("title"), assert(title.text) --[[@as string]])
  end
  self:_drawList(status)
  self:_drawDetail(status)
  self:_drawButtons(status)
  self:_drawMessage(status)
  lg.setColor(1, 1, 1, 1)
end

-- Draws one immutable snapshot through the published plan.
---@param status table<string, unknown> the live reminder snapshot
---@param _ string? the subject name the application carries
function MoveRelearnerRenderer:draw(status, _)
  assert(type(status) == "table", "the reminder renderer draws a snapshot")
  assert(
    status.kind == PokemonCareInterface.KINDS.move_relearner,
    "the reminder renderer draws the reminder application"
  )
  local measurement = self._measureDisplay()
  self._session:resolve(measurement, status)
  local plan = self._session:plan() --[[@as table<string, unknown>]]
  local panes = plan.panes or {}
  for _, pane in ipairs(panes) do
    local renderer = self
    LogicalSurface.draw(self._graphics, pane.placement, function()
      renderer:drawPane(status, assert(pane.id, "reminder panes carry identities"))
    end)
  end
  self._graphics.setColor(1, 1, 1, 1)
end

---@param box { x: integer, y: integer, width: integer, height: integer }
---@param x integer
---@param y integer
---@return boolean
local function inside(box, x, y)
  return x >= box.x and x < box.x + box.width and y >= box.y and y < box.y + box.height
end

-- The source touch targets on the bottom screen: the four list rows, the two
-- buttons, and the prompt's own answer boxes while a question is open.
---@param status table<string, unknown>
---@param x number logical x on the bottom screen
---@param y number logical y on the bottom screen
---@return table<string, unknown>? target
function MoveRelearnerRenderer:targetAt(status, x, y)
  local question = status.question
  if question ~= nil then
    if inside(self:_box("promptYes"), x, y) then
      return { kind = "answer", answer = "yes" }
    end
    if inside(self:_box("promptNo"), x, y) then
      return { kind = "answer", answer = "no" }
    end
    return nil
  end
  if inside(self:_box("teach"), x, y) then
    return { kind = "teach" }
  end
  if inside(self:_box("returnButton"), x, y) then
    return { kind = "return" }
  end
  local list = self:_box("list")
  if not inside(list, x, y) then
    return nil
  end
  local row = math.floor((y - list.y - 4) / ROW_HEIGHT)
  if row < 0 or row >= VISIBLE_ROWS then
    return nil
  end
  local index = (status.scrollOffset or 0) + row
  if status.moves[index + 1] == nil then
    return nil
  end
  return { kind = "row", index = index }
end

-- Maps the scheduler's pointer edges into the source touch targets. The
-- published plan inverts the host point into the interactive screen's own
-- logical coordinates, so the same rectangles drive mouse and touch.
---@param uiEvents table[] the scheduler UI event list
---@param view table<string, unknown> the live reminder snapshot
---@return table<string, unknown>? the first resolved target
function MoveRelearnerRenderer:mapPointer(uiEvents, view)
  local measurement = self._measureDisplay()
  self._session:resolve(measurement, view)
  local mapped = self._session:mapInput(uiEvents or {}, view)
  for _, event in ipairs(mapped) do
    if event.type == "pointer_target" then
      return event.target --[[@as table<string, unknown>]]
    end
  end
  return nil
end

local function noopRender(_, _, _) end

---@return nil
local function noopMap(_, _, _)
  return nil
end

-- The reminder's host placements. The pair resolver draws both source screens;
-- a single-surface host shows the interactive screen alone, exactly like the
-- other dual-screen children.
---@param manifest table<string, unknown>
---@param resolveTarget fun(view: table<string, unknown>, x: number, y: number): table<string, unknown>?
---@return table<string, fun(context: ApplicationLayout.Context, view: table<string, unknown>): table<string, unknown>>
function MoveRelearnerRenderer.interface(manifest, resolveTarget)
  assert(type(manifest) == "table", "the reminder interface requires its family")
  assert(type(resolveTarget) == "function", "the reminder interface resolves its source touch targets")

  ---@param panes table[]
  ---@param frames table[]
  ---@param mapInput fun(event: table<string, unknown>, view: table<string, unknown>, plan: table<string, unknown>): table<string, unknown>?
  ---@return table<string, unknown>
  local function plan(panes, frames, mapInput)
    return {
      panes = panes,
      frames = frames,
      content = { family = manifest },
      inputKey = INPUT_KEY,
      render = noopRender,
      mapInput = mapInput,
    }
  end

  ---@param event table<string, unknown> session-inverted logical input on its own pane
  ---@param view table<string, unknown>
  ---@return table<string, unknown>?
  local function mapPairedInput(event, view)
    if event.type ~= "pointer_down" or event.paneId ~= SUB_NATIVE.id then
      return nil
    end
    local target = resolveTarget(view, event.x, event.y)
    if target == nil then
      return nil
    end
    return { type = "pointer_target", target = target }
  end

  ---@return table<string, unknown>
  local function inactivePlan()
    return {
      panes = {},
      frames = {},
      content = {},
      inputKey = INPUT_KEY .. "-inactive",
      render = noopRender,
      mapInput = noopMap,
    }
  end

  ---@param context ApplicationLayout.Context
  ---@return table<string, unknown>
  local function nativeLike(context)
    local geometry = ApplicationLayout.coverOrFrame(context, SUB_NATIVE, { maxOverdraw = ZERO_CROP })
    local placement = geometry.placements[SUB_NATIVE.id]
    if placement == nil then
      return inactivePlan()
    end
    return plan({
      { id = MAIN_NATIVE.id, placement = placement, interactive = false },
      { id = SUB_NATIVE.id, placement = placement, interactive = true },
    }, geometry.frames or {}, mapPairedInput)
  end

  ---@param context ApplicationLayout.Context
  ---@return table<string, unknown>
  local function dualDisplay(context)
    local geometry = ApplicationLayout.nativeDual(context, MAIN_NATIVE, SUB_NATIVE, {
      lower = { maxOverdraw = ZERO_CROP },
    })
    local main = geometry.placements[MAIN_NATIVE.id]
    local sub = geometry.placements[SUB_NATIVE.id]
    if main == nil or sub == nil then
      return inactivePlan()
    end
    return plan({
      { id = MAIN_NATIVE.id, placement = main, interactive = false },
      { id = SUB_NATIVE.id, placement = sub, interactive = true },
    }, geometry.frames or {}, mapPairedInput)
  end

  ---@param context ApplicationLayout.Context
  ---@param view table<string, unknown>
  ---@param horizontal boolean
  ---@return table<string, unknown>
  local function paired(context, view, horizontal)
    local geometry
    if horizontal then
      geometry = ApplicationLayout.sideBySide(context, MAIN_NATIVE, SUB_NATIVE)
    else
      geometry = ApplicationLayout.stacked(context, MAIN_NATIVE, SUB_NATIVE)
    end
    if geometry == nil then
      return nativeLike(context)
    end
    local main = geometry.placements[MAIN_NATIVE.id]
    local sub = geometry.placements[SUB_NATIVE.id]
    if main == nil or sub == nil then
      return inactivePlan()
    end
    return plan({
      { id = MAIN_NATIVE.id, placement = main, interactive = false },
      { id = SUB_NATIVE.id, placement = sub, interactive = true },
    }, geometry.frames or {}, mapPairedInput)
  end

  return {
    dualDisplay = dualDisplay,
    nativeLike = nativeLike,
    wide = function(context, view)
      return paired(context, view, true)
    end,
    tall = function(context, view)
      return paired(context, view, false)
    end,
  }
end

-- Releases the owned presentation session. Realized images and the borrowed
-- text/window renderers belong to the field presentation that created them.
function MoveRelearnerRenderer:release()
  if self._session ~= nil then
    self._session:dispose()
    self._session = nil
  end
end

return MoveRelearnerRenderer
