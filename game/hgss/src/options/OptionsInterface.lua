-- Shared geometry and input mapping for the scrolling Options menu. This
-- module places the seven setting rows, the fixed footer, and the preview
-- region inside one published layout per display case and maps one logical
-- event batch to the semantic actions the screen state owns. It retains no
-- draft, resources, or selection history: every resolver is a pure function
-- of its context and view.

local ApplicationLayout = require("libs.ui.src.ApplicationLayout")
local ChoiceGroup = require("libs.ui.src.ChoiceGroup")
local NativeDisplay = require("libs.ui.src.NativeDisplay")
local ScrollViewport = require("libs.ui.src.ScrollViewport")
local Slider = require("libs.ui.src.Slider")

---@class OptionsInterface
local OptionsInterface = {}

OptionsInterface.ROW_IDS = {
  "textSpeed",
  "battleScene",
  "battleStyle",
  "soundMode",
  "textFrame",
  "volume",
  "battleSpeed",
}
OptionsInterface.FOOTER_IDS = { "confirm", "quit" }
OptionsInterface.TEXT_CHOICES = { "mid", "fast", "fastest" }
OptionsInterface.SPEED_STOPS = { 1, 2, 4 }
OptionsInterface.VOLUME_COUNT = 101
OptionsInterface.ROW_HEIGHT = 24
OptionsInterface.HEADER_HEIGHT = 24
OptionsInterface.FOOTER_HEIGHT = 24
OptionsInterface.LABEL_X = 12
OptionsInterface.CONTROL_LEFT = 112
OptionsInterface.CONTROL_RIGHT = 248
OptionsInterface.INPUT_KEY = "options"

local CONTENT_NATIVE = { id = "content", width = NativeDisplay.WIDTH, height = NativeDisplay.HEIGHT }
local ZERO_CROP = { left = 0, right = 0, top = 0, bottom = 0 }
local KNOB_EXTENT = 8

---@alias OptionsInterface.Rect { x: number, y: number, width: number, height: number }
---@alias OptionsInterface.Point { x: number, y: number }
---@class OptionsInterface.SliderControl
---@field kind "slider"
---@field rect OptionsInterface.Rect
---@field slider Slider.Resolved
---@class OptionsInterface.ChoiceControl
---@field kind "choice"
---@field rect OptionsInterface.Rect
---@field choices OptionsInterface.Rect[]
---@class OptionsInterface.CycleControl
---@field kind "cycle"
---@field rect OptionsInterface.Rect
---@field leftArrow OptionsInterface.Rect
---@field rightArrow OptionsInterface.Rect
---@field value OptionsInterface.Rect
---@alias OptionsInterface.ControlGeometry OptionsInterface.SliderControl|OptionsInterface.ChoiceControl|OptionsInterface.CycleControl
---@class OptionsInterface.RowLayout
---@field id string
---@field position integer
---@field rect OptionsInterface.Rect
---@field labelAnchor OptionsInterface.Point
---@field control OptionsInterface.ControlGeometry
---@field clipped boolean
---@class OptionsInterface.FooterLayout
---@field x number
---@field y number
---@field width number
---@field height number
---@field confirmRect OptionsInterface.Rect
---@field quitRect OptionsInterface.Rect
---@class OptionsInterface.ContentGeometry
---@field rows OptionsInterface.RowLayout[]
---@field listViewport OptionsInterface.Rect
---@field scrollOffset number
---@field scrollMax number
---@field footer OptionsInterface.FooterLayout
---@field preview OptionsInterface.Rect?
---@class OptionsInterface.Hit
---@field target string rowId, "confirm", or "quit"
---@field control "value"|"left"|"right"|"thumb"|"footer"
---@field index integer?

-- The deterministic focus graph: rows walk in their fixed order, the two
-- footer actions sit past the last row, and footer left/right clamp.
-- Row left/right never moves focus; only up/down and footer left/right do.
local FOCUS_DOWN = {
  textSpeed = "battleScene",
  battleScene = "battleStyle",
  battleStyle = "soundMode",
  soundMode = "textFrame",
  textFrame = "volume",
  volume = "battleSpeed",
  battleSpeed = "confirm",
  confirm = "textSpeed",
  quit = "textSpeed",
}
local FOCUS_UP = {
  textSpeed = "quit",
  battleScene = "textSpeed",
  battleStyle = "battleScene",
  soundMode = "battleStyle",
  textFrame = "soundMode",
  volume = "textFrame",
  battleSpeed = "volume",
  confirm = "battleSpeed",
  quit = "battleSpeed",
}

---@param currentId string
---@param direction string "up"|"down"|"left"|"right"
---@return string the focused id after the move
function OptionsInterface.focusNext(currentId, direction)
  if direction == "down" then
    return assert(FOCUS_DOWN[currentId], "options focus needs a known id")
  elseif direction == "up" then
    return assert(FOCUS_UP[currentId], "options focus needs a known id")
  elseif direction == "left" then
    if currentId == "quit" then
      return "confirm"
    end
    return currentId
  elseif direction == "right" then
    if currentId == "confirm" then
      return "quit"
    end
    return currentId
  end
  error("unknown options focus direction " .. tostring(direction), 0)
end

---@param rowId string
---@return boolean
function OptionsInterface.isRow(rowId)
  for _, id in ipairs(OptionsInterface.ROW_IDS) do
    if id == rowId then
      return true
    end
  end
  return false
end

---@param rowId string
---@return string "choice"|"cycle"|"slider"
function OptionsInterface.rowKind(rowId)
  if rowId == "volume" or rowId == "battleSpeed" then
    return "slider"
  end
  if rowId == "textFrame" then
    return "cycle"
  end
  return "choice"
end

---@param rowId string
---@return integer the published value stop count
function OptionsInterface.valueCount(rowId)
  if rowId == "textSpeed" then
    return #OptionsInterface.TEXT_CHOICES
  end
  if rowId == "textFrame" then
    return 20
  end
  if rowId == "volume" then
    return OptionsInterface.VOLUME_COUNT
  end
  if rowId == "battleSpeed" then
    return #OptionsInterface.SPEED_STOPS
  end
  return 2
end

-- Lays one row's concrete control geometry inside the 256-wide logical
-- row: discrete choices distribute with ChoiceGroup, the frame row keeps
-- its arrow pair, and sliders resolve their track and thumb with Slider.
-- All origins snap to whole logical pixels.
---@param rowId string
---@param rowRect OptionsInterface.Rect logical row rectangle
---@param index integer the current 1-based value stop
---@return OptionsInterface.ControlGeometry control geometry for hit testing and painting
local function layoutControl(rowId, rowRect, index)
  local controlRect = {
    x = OptionsInterface.CONTROL_LEFT,
    y = rowRect.y,
    width = OptionsInterface.CONTROL_RIGHT - OptionsInterface.CONTROL_LEFT,
    height = rowRect.height,
  }
  local kind = OptionsInterface.rowKind(rowId)
  if kind == "slider" then
    local resolved = Slider.resolve({
      rect = { x = controlRect.x, y = controlRect.y + 6, width = controlRect.width, height = 12 },
      count = OptionsInterface.valueCount(rowId),
      index = index,
      knobExtent = KNOB_EXTENT,
    })
    return { kind = kind, rect = controlRect, slider = resolved }
  end
  local count = OptionsInterface.valueCount(rowId)
  local height = 16
  local widths = {}
  if kind == "cycle" then
    -- The frame row keeps a left arrow, a centered value label, and a
    -- right arrow at natural source extents.
    return {
      kind = kind,
      rect = controlRect,
      leftArrow = { x = controlRect.x, y = rowRect.y + 4, width = 16, height = 16 },
      rightArrow = {
        x = controlRect.x + controlRect.width - 16,
        y = rowRect.y + 4,
        width = 16,
        height = 16,
      },
      value = {
        x = controlRect.x + 16,
        y = rowRect.y,
        width = controlRect.width - 32,
        height = rowRect.height,
      },
    }
  end
  local per = math.floor(controlRect.width / count)
  for _ = 1, count do
    widths[#widths + 1] = per
  end
  local resolved = ChoiceGroup.resolve({ rect = controlRect, widths = widths, height = height })
  return { kind = kind, rect = controlRect, choices = resolved.rects }
end

-- Builds the row rectangles and footer placement for one 256x192 logical
-- body: a fixed header, the scrolling list region, and a footer pinned
-- below the list. The caller supplies the preview placement per case.
---@param listY integer list top within the body
---@param listHeight integer visible list height within the body
---@param footerY integer footer top within the body
---@param preview OptionsInterface.Rect? case preview placement in body coordinates
---@param view table<string, unknown> the screen semantic snapshot
---@return OptionsInterface.ContentGeometry content geometry for paint and hit testing
local function buildContent(listY, listHeight, footerY, preview, view)
  local rows = {}
  local y = 0
  for position, rowId in ipairs(OptionsInterface.ROW_IDS) do
    local rect = { x = 0, y = y, width = 256, height = OptionsInterface.ROW_HEIGHT }
    local rowView = nil
    if type(view.rows) == "table" then
      for _, entry in ipairs(view.rows) do
        if entry.id == rowId then
          rowView = entry
          break
        end
      end
    end
    local index = (rowView ~= nil and rowView.valueIndex) or 1
    rows[#rows + 1] = {
      id = rowId,
      position = position,
      rect = rect,
      labelAnchor = { x = OptionsInterface.LABEL_X, y = y + 4 },
      control = layoutControl(rowId, rect, index),
      clipped = false,
    }
    y = y + OptionsInterface.ROW_HEIGHT
  end
  local scrollOffset = 0
  if type(view.scrollOffset) == "number" then
    scrollOffset = view.scrollOffset
  end
  local totalHeight = #rows * OptionsInterface.ROW_HEIGHT
  scrollOffset = ScrollViewport.clamp(scrollOffset, totalHeight, listHeight)
  local startY, endY = ScrollViewport.visibleRange(scrollOffset, listHeight, OptionsInterface.ROW_HEIGHT, 0, #rows)
  for position, row in ipairs(rows) do
    row.clipped = position < startY or position > endY
  end
  return {
    rows = rows,
    listViewport = { x = 0, y = listY, width = 256, height = listHeight },
    scrollOffset = scrollOffset,
    scrollMax = math.max(0, totalHeight - listHeight),
    footer = {
      x = 0,
      y = footerY,
      width = 256,
      height = OptionsInterface.FOOTER_HEIGHT,
      confirmRect = { x = 24, y = footerY + 4, width = 96, height = 16 },
      quitRect = { x = 136, y = footerY + 4, width = 96, height = 16 },
    },
    preview = preview,
  }
end

---@param content OptionsInterface.ContentGeometry resolved options content
---@param x number logical x
---@param y number logical y
---@return OptionsInterface.Hit? { target = rowId|"confirm"|"quit", control = "value"|"left"|"right"|"thumb"|"footer", index = integer? }
function OptionsInterface.hitTest(content, x, y)
  if type(x) ~= "number" or type(y) ~= "number" then
    return nil
  end
  local footer = assert(content.footer, "options content carries its footer")
  if y >= footer.y and y < footer.y + footer.height then
    local confirm = footer.confirmRect
    if x >= confirm.x and x < confirm.x + confirm.width then
      return { target = "confirm", control = "footer" }
    end
    local quit = footer.quitRect
    if x >= quit.x and x < quit.x + quit.width then
      return { target = "quit", control = "footer" }
    end
    return nil
  end
  local viewport = assert(content.listViewport, "options content carries its list viewport")
  if y < viewport.y or y >= viewport.y + viewport.height then
    return nil
  end
  local offset = assert(content.scrollOffset, "options content carries its scroll offset")
  for _, row in ipairs(assert(content.rows, "options content carries its rows")) do
    local rect = row.rect
    local top = viewport.y + (rect.y - offset)
    if y >= top and y < top + rect.height and x >= 0 and x < 256 then
      if row.clipped then
        return nil
      end
      local control = row.control
      if control.kind == "slider" then
        local resolved = assert(control.slider, "slider rows carry resolved geometry")
        return { target = row.id, control = "thumb", index = Slider.indexAt(resolved, x) }
      end
      if control.kind == "cycle" then
        if x >= control.leftArrow.x and x < control.leftArrow.x + control.leftArrow.width then
          return { target = row.id, control = "left" }
        end
        if x >= control.rightArrow.x and x < control.rightArrow.x + control.rightArrow.width then
          return { target = row.id, control = "right" }
        end
        return { target = row.id, control = "value" }
      end
      for choiceIndex, choiceRect in ipairs(assert(control.choices, "choice rows carry choice rects")) do
        if x >= choiceRect.x and x < choiceRect.x + choiceRect.width then
          return { target = row.id, control = "value", index = choiceIndex }
        end
      end
      return nil
    end
  end
  return nil
end

---@param content OptionsInterface.ContentGeometry resolved options content
---@param x number logical x
---@param y number logical y
---@return boolean inside the scroll list but on no control
function OptionsInterface.inList(content, x, y)
  local viewport = content.listViewport
  if viewport == nil or type(x) ~= "number" or type(y) ~= "number" then
    return false
  end
  if y < viewport.y or y >= viewport.y + viewport.height then
    return false
  end
  if x < viewport.x or x >= viewport.x + viewport.width then
    return false
  end
  return OptionsInterface.hitTest(content, x, y) == nil
end

local function noopRender(_, _, _) end

---@return nil
local function noopMap(_, _, _)
  return nil
end

---@return ApplicationPlan a valid inactive plan: no panes, no targets
local function inactivePlan()
  return {
    panes = {},
    frames = {},
    content = { rows = {}, footer = nil },
    inputKey = "options-inactive",
    render = noopRender,
    mapInput = noopMap,
  }
end

-- Maps one session-inverted logical event to the semantic action the
-- screen owns. Pointer scroll drives the list; a true outside down ends
-- the whole draft; footer presses arm footer actions; row presses arm
-- value edits; wheel input during a slider capture is forwarded and the
-- state drops it while captured.
---@param event table<string, unknown> session-inverted logical input
---@param view table<string, unknown> the screen semantic snapshot
---@param plan table<string, unknown> the resolved plan
---@return table<string, unknown>? the semantic app event
local function mapOptionsInput(event, view, plan)
  local _ = view
  if type(event) ~= "table" then
    return nil
  end
  if event.type == "pointer_scroll" then
    return { type = "scroll", delta = event.deltaY or event.delta or 0 }
  end
  if event.type == "pointer_down" and event.outside == true then
    return { type = "dismiss" }
  end
  if event.type == "pointer_down" or event.type == "pointer_move" or event.type == "pointer_up" then
    event.hit = OptionsInterface.hitTest(assert(plan.content, "the options plan carries its content"), event.x, event.y)
    return event
  end
  if event.type == "pointer_cancel" then
    return event
  end
  return event
end

---@param resources table<string, unknown> borrowed application collaborators
---@param view table<string, unknown> the wrapper semantic snapshot
---@param plan table<string, unknown>
local function renderOptions(resources, view, plan)
  local renderer = assert(resources.optionsRenderer, "the options plan borrows its renderer")
  renderer:draw(view, plan)
end

-- Single-pane 256x192 body over the owned target region: header, list,
-- preview sample, and pinned footer. The preview occupies the lower body
-- below the list in the compact arrangement.
---@param context ApplicationLayout.Context
---@param view table<string, unknown>
---@return ApplicationPlan plan
local function compactPlan(context, view)
  local geometry = ApplicationLayout.coverOrFrame(context, CONTENT_NATIVE, { maxOverdraw = ZERO_CROP })
  local placement = geometry.placements[CONTENT_NATIVE.id]
  if placement == nil then
    return inactivePlan()
  end
  local content = buildContent(24, 88, 168, { x = 20, y = 128, width = 216, height = 32 }, view)
  return {
    panes = { { id = CONTENT_NATIVE.id, placement = placement, interactive = true } },
    frames = geometry.frames or {},
    content = content,
    inputKey = OptionsInterface.INPUT_KEY,
    render = renderOptions,
    mapInput = mapOptionsInput,
  }
end

---@param context ApplicationLayout.Context
---@param view table<string, unknown>
---@return ApplicationPlan plan
function OptionsInterface.fullscreen(context, view)
  return compactPlan(context, view)
end

---@param context ApplicationLayout.Context
---@param view table<string, unknown>
---@return ApplicationPlan plan
function OptionsInterface.framed(context, view)
  local geometry = ApplicationLayout.framed(context, CONTENT_NATIVE, {})
  if geometry == nil then
    return OptionsInterface.fullscreen(context, view)
  end
  local placement = geometry.placements[CONTENT_NATIVE.id]
  if placement == nil then
    return inactivePlan()
  end
  local content = buildContent(24, 88, 168, { x = 20, y = 128, width = 216, height = 32 }, view)
  return {
    panes = { { id = CONTENT_NATIVE.id, placement = placement, interactive = true } },
    frames = geometry.frames or {},
    content = content,
    inputKey = OptionsInterface.INPUT_KEY,
    render = renderOptions,
    mapInput = mapOptionsInput,
  }
end

-- Dual-display arrangement: the controls own the auxiliary 256x192 body
-- while the preview sample rides the world surface. The list region grows
-- to fill the taller control allocation.
---@param context ApplicationLayout.Context
---@param view table<string, unknown>
---@return ApplicationPlan plan
function OptionsInterface.dual(context, view)
  local upper = { id = "preview", width = NativeDisplay.WIDTH, height = NativeDisplay.HEIGHT }
  local lower = { id = "controls", width = NativeDisplay.WIDTH, height = NativeDisplay.HEIGHT }
  local ok, geometry = pcall(ApplicationLayout.nativeDual, context, upper, lower, {})
  if not ok or geometry == nil then
    return OptionsInterface.fullscreen(context, view)
  end
  local placement = geometry.placements and geometry.placements[lower.id] or nil
  if placement == nil then
    return OptionsInterface.fullscreen(context, view)
  end
  local panes = {}
  if geometry.placements[upper.id] ~= nil then
    panes[#panes + 1] = { id = upper.id, placement = geometry.placements[upper.id], interactive = false }
  end
  panes[#panes + 1] = { id = lower.id, placement = placement, interactive = true }
  local content = buildContent(24, 144, 168, { x = 0, y = 0, width = 256, height = 192 }, view)
  return {
    panes = panes,
    frames = geometry.frames or {},
    content = content,
    inputKey = OptionsInterface.INPUT_KEY,
    render = renderOptions,
    mapInput = mapOptionsInput,
  }
end

OptionsInterface.dualDisplay = OptionsInterface.dual
OptionsInterface.nativeLike = OptionsInterface.fullscreen
OptionsInterface.wide = OptionsInterface.framed
OptionsInterface.tall = OptionsInterface.framed

---@return table<string, fun(context: ApplicationLayout.Context, view: table<string, unknown>): ApplicationPlan>
function OptionsInterface.defaults()
  return {
    dualDisplay = OptionsInterface.dual,
    nativeLike = OptionsInterface.fullscreen,
    wide = OptionsInterface.framed,
    tall = OptionsInterface.framed,
  }
end

return OptionsInterface
