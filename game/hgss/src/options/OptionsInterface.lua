-- Shared geometry and input mapping for the scrolling Options menu. This
-- module places the seven setting rows, the fixed footer, and the preview
-- region inside one published layout per display case and maps one logical
-- event batch to the semantic actions the screen state owns. It retains no
-- draft, resources, or selection history: every resolver is a pure function
-- of its context and view.

local ApplicationLayout = require("libs.ui.src.ApplicationLayout")
local NativeDisplay = require("libs.ui.src.NativeDisplay")
local OptionsRows = require("game.hgss.src.options.OptionsRows")
local ScrollViewport = require("libs.ui.src.ScrollViewport")
local Slider = require("libs.ui.src.Slider")

---@class OptionsInterface
local OptionsInterface = {}

OptionsInterface.ROW_IDS = OptionsRows.ROW_IDS
OptionsInterface.FOOTER_IDS = { "confirm", "quit" }
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
---@field valueWindow OptionsInterface.Rect reserved numeric-label window left of the rail
---@field slider Slider.Resolved
---@class OptionsInterface.ChoiceStop
---@field hitRect OptionsInterface.Rect touch region for this stop
---@field chromeAnchor OptionsInterface.Point sprite origin for this stop
---@field textCenterX number glyph center for this stop
---@field labelWindow OptionsInterface.Rect clip window for this stop
---@class OptionsInterface.ChoiceControl
---@field kind "choice"
---@field rect OptionsInterface.Rect
---@field chromeKind string "small"|"wide"
---@field choices OptionsInterface.ChoiceStop[]
---@class OptionsInterface.ArrowControl
---@field hitRect OptionsInterface.Rect touch region
---@field chromeAnchor OptionsInterface.Point sprite origin
---@class OptionsInterface.CycleValue
---@field hitRect OptionsInterface.Rect touch region
---@field textCenterX number glyph center
---@field labelWindow OptionsInterface.Rect clip window
---@class OptionsInterface.CycleControl
---@field kind "cycle"
---@field rect OptionsInterface.Rect
---@field leftArrow OptionsInterface.ArrowControl
---@field rightArrow OptionsInterface.ArrowControl
---@field value OptionsInterface.CycleValue
---@alias OptionsInterface.ControlGeometry OptionsInterface.SliderControl|OptionsInterface.ChoiceControl|OptionsInterface.CycleControl
---@class OptionsInterface.RowLayout
---@field id string
---@field position integer
---@field rect OptionsInterface.Rect
---@field labelAnchor OptionsInterface.Point
---@field control OptionsInterface.ControlGeometry
---@field previewRect OptionsInterface.Rect? live sample window in content coordinates, frame row only
---@field clipped boolean
---@class OptionsInterface.FooterAction
---@field hitRect OptionsInterface.Rect touch region
---@field chromeAnchor OptionsInterface.Point sprite origin
---@field labelWindow OptionsInterface.Rect label clip window
---@class OptionsInterface.FooterLayout
---@field x number
---@field y number
---@field width number
---@field height number
---@field confirmRect OptionsInterface.Rect touch region alias of confirm.hitRect
---@field quitRect OptionsInterface.Rect touch region alias of quit.hitRect
---@field confirm OptionsInterface.FooterAction
---@field quit OptionsInterface.FooterAction
---@class OptionsInterface.ContentGeometry
---@field rows OptionsInterface.RowLayout[]
---@field listViewport OptionsInterface.Rect
---@field totalHeight number summed content height in logical pixels
---@field scrollOffset number
---@field scrollMax number
---@field footer OptionsInterface.FooterLayout
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
  soundMode = "volume",
  volume = "battleSpeed",
  battleSpeed = "textFrame",
  textFrame = "confirm",
  confirm = "textSpeed",
  quit = "textSpeed",
}
local FOCUS_UP = {
  textSpeed = "quit",
  battleScene = "textSpeed",
  battleStyle = "battleScene",
  soundMode = "battleStyle",
  volume = "soundMode",
  battleSpeed = "volume",
  textFrame = "battleSpeed",
  confirm = "textFrame",
  quit = "textFrame",
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

-- The one variable-height content list: six 24px setting rows plus the
-- closing 64px frame item (24px selector band, 32px sample window inset
-- 28px below the item top, 4px bottom margin). Cumulative content offsets
-- are the single source of row geometry; nothing recomputes y from an
-- index.
OptionsInterface.FRAME_ITEM_HEIGHT = 64

---@param rowId string
---@return integer row height in logical pixels
local function rowHeight(rowId)
  if rowId == "textFrame" then
    return OptionsInterface.FRAME_ITEM_HEIGHT
  end
  return OptionsInterface.ROW_HEIGHT
end

---@return integer summed content height in logical pixels
function OptionsInterface.totalHeight()
  local total = 0
  for _, rowId in ipairs(OptionsInterface.ROW_IDS) do
    total = total + rowHeight(rowId)
  end
  return total
end

---@param offset number current scroll offset
---@param rowId string focused row
---@param extent integer visible list height
---@return number scroll offset revealing the whole row interval
function OptionsInterface.revealRow(offset, rowId, extent)
  local y = 0
  for _, id in ipairs(OptionsInterface.ROW_IDS) do
    local height = rowHeight(id)
    if id == rowId then
      return ScrollViewport.reveal(offset, extent, y, height)
    end
    y = y + height
  end
  error("unknown options row " .. tostring(rowId), 0)
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
  return OptionsRows.rowKind(rowId)
end

---@param rowId string
---@return integer the published value stop count
function OptionsInterface.valueCount(rowId)
  return OptionsRows.valueCount(rowId)
end

-- Native per-row control geometry: explicit source sprite anchors, glyph
-- centers, and touch regions per row. Choice chrome is row-specific, never
-- inferred from the stop count: Text Speed and Battle Scene wear the
-- narrow pill, Battle Style and Sound wear the wide pill.
local CHOICE_GEOMETRY = {
  textSpeed = {
    anchors = { 112, 160, 208 },
    centers = { 124, 172, 220 },
    hits = { { 112, 152 }, { 160, 201 }, { 208, 249 } },
  },
  battleScene = {
    anchors = { 112, 160 },
    centers = { 124, 172 },
    hits = { { 112, 152 }, { 160, 201 } },
  },
  battleStyle = {
    anchors = { 112, 192 },
    centers = { 132, 212 },
    hits = { { 112, 168 }, { 192, 248 } },
  },
  soundMode = {
    anchors = { 112, 192 },
    centers = { 132, 212 },
    hits = { { 112, 168 }, { 192, 248 } },
  },
}

-- Lays one row's concrete control geometry inside the 256-wide logical
-- row: discrete choices use their row-specific source anchors, the frame
-- row keeps its arrow pair with a centered value, and sliders resolve
-- their track and thumb with Slider. All origins snap to whole logical
-- pixels.
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
    -- The numeric value owns x112..155; the rail owns x164..243 with an
    -- 8px gap between the regions. Both rects share the row's content
    -- coordinates; input resolves through the same Slider geometry.
    local resolved = Slider.resolve({
      rect = { x = 164, y = controlRect.y + 6, width = 80, height = 12 },
      count = OptionsInterface.valueCount(rowId),
      index = index,
      knobExtent = KNOB_EXTENT,
    })
    local valueWindow = { x = 112, y = rowRect.y + 5, width = 44, height = 18 }
    return { kind = kind, rect = controlRect, valueWindow = valueWindow, slider = resolved }
  end
  if kind == "cycle" then
    -- The frame row keeps 32px source arrows at x115/x213 with the value
    -- centered about x172. Touch bands are row-local.
    local arrowY = rowRect.y + 2
    return {
      kind = kind,
      rect = controlRect,
      leftArrow = {
        hitRect = { x = 110, y = arrowY, width = 40, height = 20 },
        chromeAnchor = { x = 115, y = rowRect.y },
      },
      rightArrow = {
        hitRect = { x = 208, y = arrowY, width = 45, height = 20 },
        chromeAnchor = { x = 213, y = rowRect.y },
      },
      value = {
        hitRect = { x = 150, y = arrowY, width = 58, height = 20 },
        textCenterX = 172,
        labelWindow = { x = 150, y = arrowY, width = 58, height = 20 },
      },
    }
  end
  local geometry = assert(CHOICE_GEOMETRY[rowId], "choice rows carry their source geometry")
  local chromeKind = assert(OptionsRows.chromeKind(rowId), "choice rows carry their source chrome kind")
  local choices = {}
  for stop, anchorX in ipairs(geometry.anchors) do
    local hit = geometry.hits[stop]
    local hitRect = { x = hit[1], y = rowRect.y + 2, width = hit[2] - hit[1], height = 20 }
    choices[stop] = {
      hitRect = hitRect,
      chromeAnchor = { x = anchorX, y = rowRect.y },
      textCenterX = geometry.centers[stop],
      labelWindow = hitRect,
    }
  end
  return { kind = kind, rect = controlRect, chromeKind = chromeKind, choices = choices }
end

-- Builds the row rectangles and footer placement for one 256x192 logical
-- body: a fixed header, the scrolling list region, and a footer pinned
-- below the list. Rows stack cumulatively from content y=0; only the
-- closing frame row carries a child sample rect inset 28px below its own
-- top.
---@param listY integer list top within the body
---@param listHeight integer visible list height within the body
---@param footerY integer footer top within the body
---@param view table<string, unknown> the screen semantic snapshot
---@return OptionsInterface.ContentGeometry content geometry for paint and hit testing
local function buildContent(listY, listHeight, footerY, view)
  local rows = {}
  local y = 0
  for position, rowId in ipairs(OptionsInterface.ROW_IDS) do
    local height = rowHeight(rowId)
    local rect = { x = 0, y = y, width = 256, height = height }
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
      labelAnchor = { x = OptionsInterface.LABEL_X, y = y + 5 },
      control = layoutControl(rowId, rect, index),
      previewRect = rowId == "textFrame" and { x = 16, y = y + 28, width = 216, height = 32 } or nil,
      clipped = false,
    }
    y = y + height
  end
  local scrollOffset = 0
  if type(view.scrollOffset) == "number" then
    scrollOffset = view.scrollOffset
  end
  local totalHeight = y
  scrollOffset = ScrollViewport.clamp(scrollOffset, totalHeight, listHeight)
  local viewportEnd = scrollOffset + listHeight
  for _, row in ipairs(rows) do
    row.clipped = not (row.rect.y < viewportEnd and row.rect.y + row.rect.height > scrollOffset)
  end
  local confirmHit = { x = 128, y = footerY + 4, width = 53, height = 20 }
  local quitHit = { x = 183, y = footerY + 4, width = 73, height = 20 }
  return {
    rows = rows,
    listViewport = { x = 0, y = listY, width = 256, height = listHeight },
    totalHeight = totalHeight,
    scrollOffset = scrollOffset,
    scrollMax = math.max(0, totalHeight - listHeight),
    footer = {
      x = 0,
      y = footerY,
      width = 256,
      height = OptionsInterface.FOOTER_HEIGHT,
      confirmRect = confirmHit,
      quitRect = quitHit,
      confirm = {
        hitRect = confirmHit,
        chromeAnchor = { x = 116, y = footerY + 2 },
        labelWindow = { x = 120, y = footerY, width = 56, height = 24 },
      },
      quit = {
        hitRect = quitHit,
        chromeAnchor = { x = 188, y = footerY + 2 },
        labelWindow = { x = 192, y = footerY, width = 56, height = 24 },
      },
    },
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
      -- The frame row answers only inside its 24px selector band: the
      -- child sample and its margins stay passive so a press there may
      -- start a list drag instead of cycling the frame.
      if row.previewRect ~= nil then
        local contentY = y - viewport.y + offset
        if contentY >= rect.y + OptionsInterface.ROW_HEIGHT then
          return nil
        end
      end
      local control = row.control
      if control.kind == "slider" then
        -- Only the resolved rail/thumb answers: the numeric window and
        -- the gap between the regions never arm a stop.
        local resolved = assert(control.slider, "slider rows carry resolved geometry")
        local contentY = y - viewport.y + offset
        local rail = assert(resolved.rect, "resolved sliders carry their rail rect")
        local insideRail = x >= rail.x
          and x < rail.x + rail.width
          and contentY >= rail.y
          and contentY < rail.y + rail.height
        if not insideRail then
          local thumb = assert(resolved.thumbRect, "resolved sliders carry their thumb rect")
          local insideThumb = x >= thumb.x
            and x < thumb.x + thumb.width
            and contentY >= thumb.y
            and contentY < thumb.y + thumb.height
          if not insideThumb then
            return nil
          end
        end
        return { target = row.id, control = "thumb", index = Slider.indexAt(resolved, x) }
      end
      if control.kind == "cycle" then
        local left = assert(control.leftArrow, "cycle rows carry their left arrow")
        local leftHit = assert(left.hitRect, "cycle arrows carry their touch region")
        if x >= leftHit.x and x < leftHit.x + leftHit.width then
          return { target = row.id, control = "left" }
        end
        local right = assert(control.rightArrow, "cycle rows carry their right arrow")
        local rightHit = assert(right.hitRect, "cycle arrows carry their touch region")
        if x >= rightHit.x and x < rightHit.x + rightHit.width then
          return { target = row.id, control = "right" }
        end
        return { target = row.id, control = "value" }
      end
      for choiceIndex, choice in ipairs(assert(control.choices, "choice rows carry choice rects")) do
        local hitRect = assert(choice.hitRect, "choice stops carry their touch region")
        if x >= hitRect.x and x < hitRect.x + hitRect.width then
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
    local dy = event.dy
    assert(type(dy) == "number" and dy == dy and dy ~= math.huge and dy ~= -math.huge, "field wheel has dy")
    local mapped = { type = "scroll", delta = -dy * 24 }
    if event.pointerId ~= nil then
      mapped.pointerId = event.pointerId
    end
    return mapped
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

-- Single-pane 256x192 body over the owned target region: header, the one
-- tall scrolling list, and a pinned footer. The frame sample scrolls with
-- its own closing row inside the list, never as a fixed copy below it.
---@param context ApplicationLayout.Context
---@param view table<string, unknown>
---@return ApplicationPlan plan
local function compactPlan(context, view)
  local geometry = ApplicationLayout.coverOrFrame(context, CONTENT_NATIVE, { maxOverdraw = ZERO_CROP })
  local placement = geometry.placements[CONTENT_NATIVE.id]
  if placement == nil then
    return inactivePlan()
  end
  local content = buildContent(24, 144, 168, view)
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
  local content = buildContent(24, 144, 168, view)
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
-- while the upper world surface keeps only its decorative source
-- backdrop. The list region fills the whole controls allocation below
-- the header.
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
  local content = buildContent(24, 144, 168, view)
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
