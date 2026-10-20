-- Shared draw/input placement for the field Pokedex: the complete browser
-- layout family and the registration layout over the same plan mechanics.
-- Dual, wide, and tall preserve both original 256x192 panels at integer
-- scale; the single-display nativeLike case is the complete compact
-- arrangement with all fifteen grid cells and the selected species
-- information visible together. Interface definitions are immutable;
-- sessions own captures. Measure and path lookups never allocate GPU
-- objects, and mapInput never touches mutable game state.

local ApplicationLayout = require("libs.ui.src.ApplicationLayout")
local PokedexSearch = require("game.hgss.src.pokedex.PokedexSearch")

---@class PokedexInterface
local PokedexInterface = {}

local NATIVE_WIDTH = 256
local NATIVE_HEIGHT = 192

local INFORMATION_NATIVE = { id = "information", width = NATIVE_WIDTH, height = NATIVE_HEIGHT }
local CONTROLS_NATIVE = { id = "controls", width = NATIVE_WIDTH, height = NATIVE_HEIGHT }
local REGISTRATION_NATIVE = { id = "registration", width = NATIVE_WIDTH, height = NATIVE_HEIGHT }
local REGISTRATION_TOUCH_NATIVE = { id = "registrationTouch", width = NATIVE_WIDTH, height = NATIVE_HEIGHT }

-- Compact footer buttons: half-open rectangles in the 256x24 footer strip.
local COMPACT_FOOTER = {
  { id = "page-prev", x = 0, width = 24 },
  { id = "page-next", x = 24, width = 24 },
  { id = "cover", x = 48, width = 48 },
  { id = "search", x = 96, width = 48 },
  { id = "cry", x = 144, width = 32 },
  { id = "language", x = 176, width = 40 },
  { id = "exit", x = 216, width = 40 },
}

-- Compact cover footer: SEARCH, OPEN, EXIT thirds.
local COMPACT_COVER_FOOTER = {
  { id = "search", x = 0, width = 80 },
  { id = "open", x = 80, width = 96 },
  { id = "exit", x = 176, width = 80 },
}

-- Compact entry tabs: four 64px tabs across the footer.
local COMPACT_TABS = { "area", "size", "forms", "return" }

-- Source list geometry on the controls pane: five 40px columns from x27
-- and three 40px rows from y4, transcribed from the native list hitboxes.
local NATIVE_LIST = { x = 27, y = 4, step = 40, columns = 5, rows = 3 }
local NATIVE_LIST_X1 = 227
local NATIVE_LIST_Y1 = 124

-- Native page arrows beside the list.
local NATIVE_ARROWS = {
  prev = { x = 0, y = 44, width = 26, height = 40 },
  next = { x = 230, y = 44, width = 26, height = 40 },
}

-- Native search footer strip at the bottom of the 192px controls pane:
-- run, reset, and back on the search page.
local NATIVE_FOOTER_Y = 168
local NATIVE_FOOTER_HEIGHT = 24

-- Native search criteria menu on the controls pane, transcribed from the
-- source menu hitboxes in inclusive {top,bottom,left,right} form: the
-- first box spans x128..215/y8..23 and the second x56..127/y32..47, with
-- the remaining criteria continuing the same two-column rhythm. Entries
-- are matched in source order; the row under a tap never decides.
local NATIVE_SEARCH_MENU = {
  { box = { top = 8, bottom = 23, left = 128, right = 215 }, value = "order" },
  { box = { top = 32, bottom = 47, left = 56, right = 127 }, value = "letter" },
  { box = { top = 56, bottom = 71, left = 128, right = 215 }, value = "type" },
  { box = { top = 80, bottom = 95, left = 56, right = 127 }, value = "shape" },
  { box = { top = 104, bottom = 119, left = 128, right = 215 }, value = "area" },
  { box = { top = 128, bottom = 143, left = 56, right = 127 }, value = "height" },
  { box = { top = 128, bottom = 143, left = 128, right = 215 }, value = "weight" },
}

-- Native order-editor options behind the same two-column menu rhythm.
local NATIVE_ORDER_EDITOR = {
  { box = { top = 8, bottom = 23, left = 128, right = 215 }, value = "numerical" },
  { box = { top = 32, bottom = 47, left = 56, right = 127 }, value = "alphabetical" },
  { box = { top = 56, bottom = 71, left = 128, right = 215 }, value = "heaviest" },
  { box = { top = 80, bottom = 95, left = 56, right = 127 }, value = "lightest" },
  { box = { top = 104, bottom = 119, left = 128, right = 215 }, value = "tallest" },
  { box = { top = 128, bottom = 143, left = 56, right = 127 }, value = "shortest" },
}

-- Native type-editor rows: one single-column list of option slots.
local NATIVE_TYPE_ROWS = { x = 8, firstY = 8, width = 128, height = 12, count = 18 }

-- Native shape-editor grid: five columns over the option slots.
local NATIVE_SHAPE_GRID = { x = 8, y = 40, columnWidth = 48, rowHeight = 40, columns = 5 }

-- Native area-editor rows: the four scope choices in source order.
local NATIVE_AREA_ROWS = {
  { box = { top = 8, bottom = 23, left = 56, right = 167 }, value = "unrestricted" },
  { box = { top = 32, bottom = 47, left = 56, right = 167 }, value = "johto" },
  { box = { top = 56, bottom = 71, left = 56, right = 167 }, value = "kanto" },
  { box = { top = 80, bottom = 95, left = 56, right = 167 }, value = "unknown" },
}

-- Native 27-letter editor grid: seven 32px columns and four 16px rows
-- from the source letter-cell selection order. Index zero clears the
-- filter; indices 1..26 hold A..Z; the final cell stays inert.
local NATIVE_LETTER_GRID = { x = 8, y = 8, columnWidth = 32, rowHeight = 16, columns = 7, rows = 4 }

-- Native browser footer behind the list grid: four bottom actions share
-- the source y152..187 band; the rows below it stay inert.
local NATIVE_LIST_FOOTER = {
  { box = { top = 152, bottom = 187, left = 8, right = 63 }, action = "page-prev" },
  { box = { top = 152, bottom = 187, left = 68, right = 123 }, action = "page-next" },
  { box = { top = 152, bottom = 187, left = 128, right = 183 }, action = "search" },
  { box = { top = 152, bottom = 187, left = 188, right = 243 }, action = "exit" },
}

-- Native entry tabs: four 51px bands at x7, x71, x135, and x199 over the
-- footer strip. Gaps between the bands switch nothing.
local NATIVE_ENTRY_TABS = {
  { box = { top = 168, bottom = 191, left = 7, right = 57 }, value = "area" },
  { box = { top = 168, bottom = 191, left = 71, right = 121 }, value = "size" },
  { box = { top = 168, bottom = 191, left = 135, right = 185 }, value = "forms" },
  { box = { top = 168, bottom = 191, left = 199, right = 249 }, value = "return" },
}

-- Native area daypart selectors: three circle targets carrying the
-- original center and radius. The first circle centers on (40, 32).
local NATIVE_AREA_CIRCLES = {
  { cx = 40, cy = 32, radius = 14, value = 0 },
  { cx = 80, cy = 32, radius = 14, value = 1 },
  { cx = 120, cy = 32, radius = 14, value = 2 },
}

-- Native search criteria rows and editor geometry on the controls pane.
local NATIVE_SEARCH = {
  runButton = { x = 204, y = 8, width = 44, height = 30 },
  resetButton = { x = 204, y = 46, width = 44, height = 30 },
  okButton = { x = 204, y = 140, width = 44, height = 20 },
  cancelButton = { x = 204, y = 164, width = 44, height = 20 },
  minTrack = { x = 8, y = 40, width = 180, height = 16 },
  maxTrack = { x = 8, y = 80, width = 180, height = 16 },
}

-- Native entry-page controls on the controls pane: the tab strip plus
-- one action group per page, transcribed from the source action groups.
local NATIVE_ENTRY = {
  timeButton = { x = 200, y = 8, width = 48, height = 24 },
  regionButton = { x = 200, y = 40, width = 48, height = 24 },
  rowFirstY = 72,
  rowHeight = 16,
  rowWidth = 184,
  restartButton = { x = 8, y = 8, width = 96, height = 24 },
  compareButton = { x = 200, y = 8, width = 48, height = 24 },
  sideLButton = { x = 8, y = 140, width = 48, height = 24 },
  sideRButton = { x = 64, y = 140, width = 48, height = 24 },
  flipButton = { x = 120, y = 140, width = 48, height = 24 },
  backButton = { x = 176, y = 140, width = 48, height = 24 },
}

-- Compact grid geometry on the 256x168 information region: five 32px
-- columns at a 34px step and three 32px rows at a 43px step, so all
-- fifteen cells, the focus ring, and the selected portrait fit together.
local COMPACT_GRID_XS = { 0, 34, 68, 102, 136 }
local COMPACT_GRID_YS = { 22, 65, 108 }
local COMPACT_ICON_SIZE = 32
local COMPACT_FOOTER_Y = 0
local COMPACT_FOOTER_HEIGHT = 24
local COMPACT_ROW = { x = 8, width = 160, firstY = 8, height = 18 }
local COMPACT_SLIDERS = {
  min = { x = 8, y = 40, width = 160, height = 16 },
  max = { x = 8, y = 80, width = 160, height = 16 },
}
local COMPACT_DIALOG = {
  ok = { x = 8, y = 144, width = 76, height = 20 },
  cancel = { x = 92, y = 144, width = 76, height = 20 },
}
local COMPACT_ACTIONS = {
  primary = { x = 8, y = 144, width = 76, height = 20 },
  secondary = { x = 92, y = 144, width = 76, height = 20 },
}
local COMPACT_COMPARE = {
  { x = 8, y = 144, width = 36, height = 20 },
  { x = 48, y = 144, width = 36, height = 20 },
  { x = 88, y = 144, width = 36, height = 20 },
  { x = 128, y = 144, width = 36, height = 20 },
}

-- Renders the prepared browser bundle through the one shared renderer.
-- The browser prepared view carries the detached projection, the
-- committed assets, and the private compact record.
---@param resources table<string, unknown> borrowed draw resources with the renderer
---@param preparedView table<string, unknown> { view, assets, compact }
---@param plan table<string, unknown> the resolved application plan
local function renderBrowser(resources, preparedView, plan)
  local renderer = assert(resources.renderer, "browser drawing borrows its shared renderer")
  assert(type(renderer.drawBrowser) == "function", "browser drawing reaches the shared renderer")
  renderer:drawBrowser({
    view = assert(preparedView.view, "browser draws carry their projection"),
    assets = assert(preparedView.assets, "browser draws carry their committed bundle"),
    compact = preparedView.compact,
  }, plan)
end

-- Tests one pane-local point against a half-open rectangle.
---@param x number pane-local x
---@param y number pane-local y
---@param rect { x: number, y: number, width: number, height: number } hit rectangle
---@return boolean true inside the rectangle
local function inside(x, y, rect)
  return x >= rect.x and y >= rect.y and x < rect.x + rect.width and y < rect.y + rect.height
end

-- Converts one slider-track position to the authored 0..152 drag step.
---@param x number pane-local x
---@param track { x: number, width: number } slider track
---@return integer clamped author step
local function sliderStep(x, track)
  local step = math.floor((x - track.x) / track.width * 152 + 0.5)
  if step < 0 then
    step = 0
  end
  if step > 152 then
    step = 152
  end
  return step
end

-- Tests one pane-local point against one inclusive source rectangle.
-- Source hitboxes include both ends, so the right and bottom edges
-- belong to the box.
---@param x number pane-local x
---@param y number pane-local y
---@param box { top: integer, bottom: integer, left: integer, right: integer } source hitbox
---@return boolean true inside the source rectangle
local function insideSourceRect(x, y, box)
  return x >= box.left and x <= box.right and y >= box.top and y <= box.bottom
end

-- Tests one pane-local point against one source circle target.
---@param x number pane-local x
---@param y number pane-local y
---@param circle { cx: integer, cy: integer, radius: integer } source circle target
---@return boolean true inside the circle
local function insideCircle(x, y, circle)
  local dx, dy = x - circle.cx, y - circle.cy
  return dx * dx + dy * dy <= circle.radius * circle.radius
end

-- Maps one pane-local browser footer segment to its finite action: page
-- paging, cover, search, cry, language, or exit. Exit cancels; cry plays
-- through the menu edge like its keyboard source.
---@param x number pane-local x
---@param y number pane-local y
---@param footerY number strip top in pane-local coordinates
---@return table<string, unknown>? finite model command
local function footerCommand(x, y, footerY)
  if y < footerY or y >= footerY + 24 then
    return nil
  end
  for _, button in ipairs(COMPACT_FOOTER) do
    if x >= button.x and x < button.x + button.width then
      if button.id == "exit" then
        return { type = "cancel" }
      elseif button.id == "cry" then
        return { type = "menu" }
      else
        return { type = "activate", action = button.id }
      end
    end
  end
  return nil
end

-- Maps one pane-local entry tab strip to its finite tab command.
---@param x number pane-local x
---@param y number pane-local y
---@param footerY number strip top in pane-local coordinates
---@return table<string, unknown>? finite model command
local function tabCommand(x, y, footerY)
  if y < footerY or y >= footerY + 24 then
    return nil
  end
  local slot = math.floor(x / 64)
  local tab = COMPACT_TABS[slot + 1]
  if tab ~= nil then
    return { type = "activate", action = "entry-tab", value = tab }
  end
  return nil
end

-- Maps one pane-local tap to the native entry tabs: four 51px source
-- bands matched in source order. Gaps between the bands switch nothing.
---@param x number pane-local x
---@param y number pane-local y
---@return table<string, unknown>? finite model command
local function nativeTabCommand(x, y)
  for _, tab in ipairs(NATIVE_ENTRY_TABS) do
    if insideSourceRect(x, y, tab.box) then
      return { type = "activate", action = "entry-tab", value = tab.value }
    end
  end
  return nil
end

-- Maps pointer down/move/up on the native cover swipe zone to the source
-- cover drag phases. The value is the pane-local swipe position the
-- controller gates at its 64/192 thresholds.
---@param event table<string, unknown> pane-local pointer event
---@return table<string, unknown>? finite model command
local function coverDrag(event)
  if event.type == "pointer_down" then
    return { type = "drag", target = "cover", phase = "begin", value = event.x }
  elseif event.type == "pointer_move" then
    return { type = "drag", target = "cover", phase = "move", value = event.x }
  elseif event.type == "pointer_up" then
    return { type = "drag", target = "cover", phase = "end", value = event.x }
  end
  return nil
end

-- Maps one native grid/results tap to its slot selection. All fifteen
-- cells map, including blank slots the controller keeps selectable but
-- non-openable and the results return sentinel the model distinguishes.
---@param event table<string, unknown> pane-local pointer event
---@return table<string, unknown>? finite model command
local function gridTap(event)
  if event.type ~= "pointer_down" then
    return nil
  end
  local x, y = event.x, event.y
  if x >= NATIVE_LIST.x and x < NATIVE_LIST_X1 and y >= NATIVE_LIST.y and y < NATIVE_LIST_Y1 then
    local slot = math.floor((y - NATIVE_LIST.y) / NATIVE_LIST.step) * NATIVE_LIST.columns
      + math.floor((x - NATIVE_LIST.x) / NATIVE_LIST.step)
    return { type = "activate", action = "grid-slot", value = slot }
  end
  if inside(x, y, NATIVE_ARROWS.prev) then
    return { type = "activate", action = "page-prev" }
  end
  if inside(x, y, NATIVE_ARROWS.next) then
    return { type = "activate", action = "page-next" }
  end
  for _, button in ipairs(NATIVE_LIST_FOOTER) do
    if insideSourceRect(x, y, button.box) then
      if button.action == "exit" then
        return { type = "cancel" }
      end
      return { type = "activate", action = button.action }
    end
  end
  return nil
end

-- Reads the open search editor behind the projection, if any.
---@param view table<string, unknown>? detached browser projection
---@return table<string, unknown>? open editor projection
local function openEditorOf(view)
  if type(view) ~= "table" then
    return nil
  end
  local search = view.search
  if type(search) ~= "table" then
    return nil
  end
  local editor = search.editor
  if type(editor) ~= "table" then
    return nil
  end
  return editor
end

-- Maps one pane-local slider-track position to its drag edge.
---@param eventType string pointer edge type
---@param criterion string height or weight criterion
---@param endpoint string min or max endpoint
---@param event table<string, unknown> pane-local pointer event
---@param track { x: number, y: number, width: number, height: number } slider track
---@return table<string, unknown>? finite model command
local function sliderEdge(eventType, criterion, endpoint, event, track)
  local phase = nil
  if eventType == "pointer_down" then
    phase = "begin"
  elseif eventType == "pointer_move" then
    phase = "move"
  elseif eventType == "pointer_up" then
    phase = "end"
  end
  if phase == nil then
    return nil
  end
  return { type = "drag", target = criterion .. "-" .. endpoint, phase = phase, value = sliderStep(event.x, track) }
end

-- Maps pointer edges on a height/weight slider editor behind its track
-- pair. A press on a track captures that endpoint; every later move or
-- release carries the captured endpoint regardless of the pointer's
-- later vertical band, projected and clamped on the original track. A
-- move or release with no captured endpoint maps to nothing.
---@param event table<string, unknown> pane-local pointer event
---@param editor table<string, unknown> open slider editor
---@param minTrack { x: number, y: number, width: number, height: number } minimum track
---@param maxTrack { x: number, y: number, width: number, height: number } maximum track
---@param okRect { x: number, y: number, width: number, height: number } commit button
---@param cancelRect { x: number, y: number, width: number, height: number } cancel button
---@param captured string? in-flight captured slider target behind the gesture
---@return table<string, unknown>? finite model command
local function sliderEditorInput(event, editor, minTrack, maxTrack, okRect, cancelRect, captured)
  local criterion = editor.kind
  if event.type == "pointer_down" then
    local x, y = event.x, event.y
    if inside(x, y, minTrack) then
      return sliderEdge(event.type, criterion, "min", event, minTrack)
    end
    if inside(x, y, maxTrack) then
      return sliderEdge(event.type, criterion, "max", event, maxTrack)
    end
    if inside(x, y, okRect) then
      return { type = "activate", action = "editor-ok" }
    end
    if inside(x, y, cancelRect) then
      return { type = "activate", action = "editor-cancel" }
    end
    return nil
  end
  if event.type ~= "pointer_move" and event.type ~= "pointer_up" then
    return nil
  end
  local endpoint = nil
  if captured == criterion .. "-min" then
    endpoint = "min"
  elseif captured == criterion .. "-max" then
    endpoint = "max"
  end
  if endpoint == nil then
    return nil
  end
  local track = minTrack
  if endpoint == "max" then
    track = maxTrack
  end
  return sliderEdge(event.type, criterion, endpoint, event, track)
end

-- Maps pointer edges on an option editor: one row per projected option
-- plus the commit/cancel pair.
---@param event table<string, unknown> pane-local pointer event
---@param editor table<string, unknown> open option editor with its options
---@param rows { rect: { x: number, y: number, width: number, height: number }, value: string }[] option rows
---@param okRect { x: number, y: number, width: number, height: number } commit button
---@param cancelRect { x: number, y: number, width: number, height: number } cancel button
---@return table<string, unknown>? finite model command
local function optionEditorInput(event, editor, rows, okRect, cancelRect)
  if event.type ~= "pointer_down" then
    return nil
  end
  local _ = editor
  local x, y = event.x, event.y
  for _, row in ipairs(rows) do
    if inside(x, y, row.rect) then
      return { type = "activate", action = "editor-choice", value = row.value }
    end
  end
  if inside(x, y, okRect) then
    return { type = "activate", action = "editor-ok" }
  end
  if inside(x, y, cancelRect) then
    return { type = "activate", action = "editor-cancel" }
  end
  return nil
end

-- Builds option rows behind one editor: a single column while eight or
-- fewer options fit, otherwise a three-column grid so all twenty-seven
-- letters stay reachable without clipping.
---@param options string[] projected editor options
---@param originX number list left edge in pane-local coordinates
---@param originY number list top edge in pane-local coordinates
---@param columnWidth number single-column row width
---@param rowHeight number single-column row height
---@return { rect: { x: number, y: number, width: number, height: number }, value: string }[] option rows
local function optionRowsFor(options, originX, originY, columnWidth, rowHeight)
  local rows = {}
  if #options > 8 then
    for index, option in ipairs(options) do
      local column = (index - 1) % 3
      local row = math.floor((index - 1) / 3)
      rows[#rows + 1] = {
        rect = { x = originX + column * 54, y = originY + row * 16, width = 52, height = 16 },
        value = option,
      }
    end
    return rows
  end
  for index, option in ipairs(options) do
    rows[#rows + 1] = {
      rect = {
        x = originX,
        y = originY + (index - 1) * rowHeight,
        width = columnWidth,
        height = rowHeight,
      },
      value = option,
    }
  end
  return rows
end

-- Reads the letter option behind one pane-local point in the native
-- 27-letter grid. The first cell clears the filter, the next
-- twenty-six hold A..Z in selection order, and the final cell is inert.
---@param x number pane-local x
---@param y number pane-local y
---@return string? letter option behind the point
local function nativeLetterValue(x, y)
  local grid = NATIVE_LETTER_GRID
  local column = math.floor((x - grid.x) / grid.columnWidth)
  local row = math.floor((y - grid.y) / grid.rowHeight)
  if column < 0 or column >= grid.columns or row < 0 or row >= grid.rows then
    return nil
  end
  local index = row * grid.columns + column
  if index == 0 then
    return "unrestricted"
  end
  if index >= 1 and index <= 26 then
    return string.char(string.byte("A") + index - 1)
  end
  return nil
end

-- Reads the captured slider target behind the projection, if any.
---@param view table<string, unknown>? detached browser projection
---@return string? in-flight captured slider target
local function capturedTargetOf(view)
  if type(view) == "table" and type(view.capturedSliderTarget) == "string" then
    return view.capturedSliderTarget
  end
  return nil
end

-- Maps pointer edges on the native search page: the source criteria
-- menu and the run/reset pair, or the open editor geometry.
---@param event table<string, unknown> pane-local pointer event
---@param view table<string, unknown>? detached browser projection
---@return table<string, unknown>? finite model command
local function searchInput(event, view)
  local x, y = event.x, event.y
  local editor = openEditorOf(view)
  if editor ~= nil and (editor.kind == "height" or editor.kind == "weight") then
    local gesture = sliderEditorInput(
      event,
      editor,
      NATIVE_SEARCH.minTrack,
      NATIVE_SEARCH.maxTrack,
      NATIVE_SEARCH.okButton,
      NATIVE_SEARCH.cancelButton,
      capturedTargetOf(view)
    )
    if gesture ~= nil then
      return gesture
    end
    return nil
  end
  if editor ~= nil then
    if event.type ~= "pointer_down" then
      return nil
    end
    if editor.kind == "letter" then
      local value = nativeLetterValue(x, y)
      if value ~= nil then
        return { type = "activate", action = "editor-choice", value = value }
      end
      if inside(x, y, NATIVE_SEARCH.okButton) then
        return { type = "activate", action = "editor-ok" }
      end
      if inside(x, y, NATIVE_SEARCH.cancelButton) then
        return { type = "activate", action = "editor-cancel" }
      end
      return nil
    end
    if editor.kind == "order" then
      for _, box in ipairs(NATIVE_ORDER_EDITOR) do
        if insideSourceRect(x, y, box.box) then
          return { type = "activate", action = "editor-choice", value = box.value }
        end
      end
    elseif editor.kind == "type" then
      local row = math.floor((y - NATIVE_TYPE_ROWS.firstY) / NATIVE_TYPE_ROWS.height)
      if
        row >= 0
        and row < NATIVE_TYPE_ROWS.count
        and x >= NATIVE_TYPE_ROWS.x
        and x < NATIVE_TYPE_ROWS.x + NATIVE_TYPE_ROWS.width
        and type(editor.options) == "table"
        and type(editor.options[row + 1]) == "string"
      then
        return { type = "activate", action = "editor-choice", value = editor.options[row + 1] }
      end
    elseif editor.kind == "shape" then
      local column = math.floor((x - NATIVE_SHAPE_GRID.x) / NATIVE_SHAPE_GRID.columnWidth)
      local row = math.floor((y - NATIVE_SHAPE_GRID.y) / NATIVE_SHAPE_GRID.rowHeight)
      if column >= 0 and column < NATIVE_SHAPE_GRID.columns and row >= 0 then
        local index = row * NATIVE_SHAPE_GRID.columns + column
        if type(editor.options) == "table" and type(editor.options[index + 1]) == "string" then
          return { type = "activate", action = "editor-choice", value = editor.options[index + 1] }
        end
      end
    elseif editor.kind == "area" then
      for _, box in ipairs(NATIVE_AREA_ROWS) do
        if insideSourceRect(x, y, box.box) then
          return { type = "activate", action = "editor-choice", value = box.value }
        end
      end
    end
    if inside(x, y, NATIVE_SEARCH.okButton) then
      return { type = "activate", action = "editor-ok" }
    end
    if inside(x, y, NATIVE_SEARCH.cancelButton) then
      return { type = "activate", action = "editor-cancel" }
    end
    return nil
  end
  if event.type == "pointer_move" or event.type == "pointer_up" then
    return nil
  end
  for _, entry in ipairs(NATIVE_SEARCH_MENU) do
    if insideSourceRect(x, y, entry.box) then
      return { type = "activate", action = "criterion", value = entry.value }
    end
  end
  if inside(x, y, NATIVE_SEARCH.runButton) then
    return { type = "activate", action = "search-run" }
  end
  if inside(x, y, NATIVE_SEARCH.resetButton) then
    return { type = "activate", action = "search-reset" }
  end
  if y >= NATIVE_FOOTER_Y and y < NATIVE_FOOTER_Y + NATIVE_FOOTER_HEIGHT then
    if x >= 0 and x < 80 then
      return { type = "activate", action = "search-run" }
    elseif x >= 80 and x < 160 then
      return { type = "activate", action = "search-reset" }
    elseif x >= 160 and x < 256 then
      return { type = "cancel" }
    end
  end
  return nil
end

-- Counts the selectable rows behind an area or forms projection.
---@param view table<string, unknown>? detached browser projection
---@param page string entry page behind the tap
---@return integer visible row count
local function entryRowCount(view, page)
  if type(view) ~= "table" then
    return 0
  end
  if page == "area" and type(view.area) == "table" and type(view.area.rows) == "table" then
    return #view.area.rows
  end
  if page == "forms" and type(view.forms) == "table" and type(view.forms.variants) == "table" then
    return #view.forms.variants
  end
  return 0
end

-- Maps pointer edges on native entry pages: the tab strip plus one
-- action group per page. Comparison controls replace the forms list
-- while the comparison stays open.
---@param event table<string, unknown> pane-local pointer event
---@param view table<string, unknown>? detached browser projection
---@param page string entry page behind the tap
---@return table<string, unknown>? finite model command
local function entryInput(event, view, page)
  if event.type ~= "pointer_down" then
    return nil
  end
  local x, y = event.x, event.y
  local tabbed = nativeTabCommand(x, y)
  if tabbed ~= nil then
    return tabbed
  end
  if page == "area" then
    for _, circle in ipairs(NATIVE_AREA_CIRCLES) do
      if insideCircle(x, y, circle) then
        return { type = "activate", action = "area-time", value = circle.value }
      end
    end
    if inside(x, y, NATIVE_ENTRY.timeButton) then
      return { type = "confirm" }
    end
    if inside(x, y, NATIVE_ENTRY.regionButton) then
      return { type = "select" }
    end
    for row = 0, entryRowCount(view, page) - 1 do
      local rect = {
        x = 8,
        y = NATIVE_ENTRY.rowFirstY + row * NATIVE_ENTRY.rowHeight,
        width = NATIVE_ENTRY.rowWidth,
        height = NATIVE_ENTRY.rowHeight,
      }
      if inside(x, y, rect) then
        return { type = "activate", action = "area-row", value = row }
      end
    end
    return nil
  end
  if page == "size" then
    if inside(x, y, NATIVE_ENTRY.restartButton) then
      return { type = "activate", action = "size-restart" }
    end
    return nil
  end
  if page == "forms" then
    local forms = nil
    if type(view) == "table" then
      forms = view.forms
    end
    if type(forms) == "table" and forms.comparison ~= nil then
      if inside(x, y, NATIVE_ENTRY.sideLButton) then
        return { type = "activate", action = "compare-side", value = 0 }
      end
      if inside(x, y, NATIVE_ENTRY.sideRButton) then
        return { type = "activate", action = "compare-side", value = 1 }
      end
      if inside(x, y, NATIVE_ENTRY.flipButton) then
        return { type = "activate", action = "compare-flip" }
      end
      if inside(x, y, NATIVE_ENTRY.backButton) then
        return { type = "activate", action = "compare-back" }
      end
      return nil
    end
    if inside(x, y, NATIVE_ENTRY.compareButton) then
      return { type = "activate", action = "compare" }
    end
    for row = 0, entryRowCount(view, page) - 1 do
      local rect = {
        x = 8,
        y = NATIVE_ENTRY.rowFirstY + row * NATIVE_ENTRY.rowHeight,
        width = NATIVE_ENTRY.rowWidth,
        height = NATIVE_ENTRY.rowHeight,
      }
      if inside(x, y, rect) then
        return { type = "activate", action = "forms-row", value = row }
      end
    end
    return nil
  end
  if page == "return" then
    return { type = "activate", action = "return-list" }
  end
  return nil
end

-- Maps pane-local pointer edges on the paired native layout by the
-- trusted host pane identity. The information pane carries no touch
-- controls; every controls action follows the source hitboxes.
---@param event table<string, unknown> pane-local pointer event with its pane identity
---@param view table<string, unknown>? detached browser projection
---@param page string? top-level page behind the tap
---@return table<string, unknown>? finite model command
local function mapNativeInput(event, view, page)
  local paneId = event.paneId
  if paneId ~= "information" and paneId ~= "controls" then
    return nil
  end
  if paneId == "information" then
    return nil
  end
  if page == "cover" then
    return coverDrag(event)
  end
  if page == "grid" or page == "results" then
    return gridTap(event)
  end
  if page == "search" then
    return searchInput(event, view)
  end
  if page == "area" or page == "size" or page == "forms" or page == "return" then
    return entryInput(event, view, page)
  end
  return nil
end

-- Builds the compact icon grid: five 32px columns and three 32px rows
-- with the focus ring around each cell.
---@return { iconRects: { x: number, y: number, width: number, height: number }[], cursorRects: { x: number, y: number, width: number, height: number }[] }
local function compactIconGrid()
  local iconRects, cursorRects = {}, {}
  for row = 1, 3 do
    for column = 1, 5 do
      local x, y = COMPACT_GRID_XS[column], COMPACT_GRID_YS[row]
      iconRects[#iconRects + 1] = { x = x, y = y, width = COMPACT_ICON_SIZE, height = COMPACT_ICON_SIZE }
      cursorRects[#cursorRects + 1] = { x = x - 4, y = y - 4, width = 40, height = 40 }
    end
  end
  return { columns = 5, rows = 3, iconRects = iconRects, cursorRects = cursorRects }
end

-- Lists the compact footer buttons behind one page: the cover triple,
-- the browser actions, the search run/reset/back triple (or the editor
-- commit/cancel pair while an editor stays open), or the four entry
-- tabs. Coordinates are controls-pane-local.
---@param view table<string, unknown>? detached browser projection
---@param page string? top-level page behind the plan
---@return { id: string, x: number, y: number, width: number, height: number }[] footer buttons
local function compactFooterButtons(view, page)
  local buttons = {}
  local function add(id, x, width)
    buttons[#buttons + 1] = { id = id, x = x, y = COMPACT_FOOTER_Y, width = width, height = COMPACT_FOOTER_HEIGHT }
  end
  if page == "cover" then
    add("search", 0, 80)
    add("open", 80, 96)
    add("exit", 176, 80)
  elseif page == "search" and openEditorOf(view) ~= nil then
    add("editor-ok", 0, 128)
    add("editor-cancel", 128, 128)
  elseif page == "search" then
    add("search-run", 0, 80)
    add("search-reset", 80, 80)
    add("back", 160, 96)
  elseif page == "area" or page == "size" or page == "forms" or page == "return" then
    add("area", 0, 64)
    add("size", 64, 64)
    add("forms", 128, 64)
    add("return", 192, 64)
  else
    for _, button in ipairs(COMPACT_FOOTER) do
      add(button.id, button.x, button.width)
    end
  end
  return buttons
end

-- Builds the page-dependent compact rows on the information pane:
-- criteria or editor options on search, selectable habitat/form rows on
-- area/forms, entry actions, and the Return confirmation.
---@param view table<string, unknown>? detached browser projection
---@param page string? top-level page behind the plan
---@return { action: string, value: string|integer?, rect: { x: number, y: number, width: number, height: number } }[] action rows
local function compactRowsFor(view, page)
  local rows = {}
  if page == "search" then
    local editor = openEditorOf(view)
    if editor ~= nil then
      if editor.kind == "height" or editor.kind == "weight" then
        return rows
      end
      if type(editor.options) == "table" then
        local options =
          optionRowsFor(editor.options, COMPACT_ROW.x, COMPACT_ROW.firstY, COMPACT_ROW.width, COMPACT_ROW.height)
        for _, option in ipairs(options) do
          rows[#rows + 1] = { action = "editor-choice", value = option.value, rect = option.rect }
        end
      end
      return rows
    end
    for index, criterion in ipairs(PokedexSearch.CRITERIA) do
      rows[#rows + 1] = {
        action = "criterion",
        value = criterion,
        rect = {
          x = COMPACT_ROW.x,
          y = COMPACT_ROW.firstY + (index - 1) * COMPACT_ROW.height,
          width = COMPACT_ROW.width,
          height = COMPACT_ROW.height,
        },
      }
    end
    return rows
  end
  if page == "area" then
    for row = 0, math.min(entryRowCount(view, page), 10) - 1 do
      rows[#rows + 1] = {
        action = "area-row",
        value = row,
        rect = { x = 8, y = 8 + row * 14, width = 160, height = 14 },
      }
    end
    rows[#rows + 1] = { action = "confirm", rect = COMPACT_ACTIONS.primary }
    rows[#rows + 1] = { action = "select", rect = COMPACT_ACTIONS.secondary }
    return rows
  end
  if page == "size" then
    rows[#rows + 1] = { action = "size-restart", rect = COMPACT_ACTIONS.primary }
    return rows
  end
  if page == "forms" then
    local forms = nil
    if type(view) == "table" then
      forms = view.forms
    end
    if type(forms) == "table" and forms.comparison ~= nil then
      rows[#rows + 1] = { action = "compare-side", value = 0, rect = COMPACT_COMPARE[1] }
      rows[#rows + 1] = { action = "compare-side", value = 1, rect = COMPACT_COMPARE[2] }
      rows[#rows + 1] = { action = "compare-flip", rect = COMPACT_COMPARE[3] }
      rows[#rows + 1] = { action = "compare-back", rect = COMPACT_COMPARE[4] }
      return rows
    end
    for row = 0, math.min(entryRowCount(view, page), 10) - 1 do
      rows[#rows + 1] = {
        action = "forms-row",
        value = row,
        rect = { x = 8, y = 8 + row * 14, width = 160, height = 14 },
      }
    end
    rows[#rows + 1] = { action = "compare", rect = COMPACT_ACTIONS.primary }
    return rows
  end
  if page == "return" then
    rows[#rows + 1] = {
      action = "return-list",
      rect = { x = 8, y = 8, width = 160, height = 20 },
    }
    return rows
  end
  return rows
end

-- Builds the compact slider tracks behind a height/weight editor.
---@param view table<string, unknown>? detached browser projection
---@return { target: string, rect: { x: number, y: number, width: number, height: number } }[] slider tracks
local function compactSlidersFor(view)
  local editor = openEditorOf(view)
  if editor == nil or (editor.kind ~= "height" and editor.kind ~= "weight") then
    return {}
  end
  return {
    { target = editor.kind .. "-min", rect = COMPACT_SLIDERS.min },
    { target = editor.kind .. "-max", rect = COMPACT_SLIDERS.max },
  }
end

-- Builds the one feature-local compact geometry record shared by the
-- mapper and the renderer: grid, portrait, inspection toggle, footer,
-- page rows, and slider tracks. Native plans carry no record.
---@param view table<string, unknown>? detached browser projection selecting the page
---@return table<string, unknown> shared compact geometry record
local function buildCompactRecord(view)
  local page = nil
  if type(view) == "table" then
    page = view.page
  end
  return {
    grid = compactIconGrid(),
    portraitRect = { x = 176, y = 48, width = 80, height = 80 },
    inspectRect = { x = 176, y = 132, width = 80, height = 20 },
    footer = { buttons = compactFooterButtons(view, page) },
    rows = compactRowsFor(view, page),
    sliders = compactSlidersFor(view),
  }
end

-- Maps one compact footer button by the page behind the plan.
---@param event table<string, unknown> pane-local pointer event
---@param view table<string, unknown>? detached browser projection
---@param page string? top-level page behind the plan
---@return table<string, unknown>? finite model command
local function compactFooter(event, view, page)
  if event.type ~= "pointer_down" then
    return nil
  end
  local x, y = event.x, event.y
  if page == "cover" then
    for _, button in ipairs(COMPACT_COVER_FOOTER) do
      if x >= button.x and x < button.x + button.width and y >= 0 and y < 24 then
        if button.id == "open" then
          return { type = "confirm" }
        elseif button.id == "exit" then
          return { type = "cancel" }
        else
          return { type = "activate", action = button.id }
        end
      end
    end
    return nil
  end
  if page == "search" then
    if y < 0 or y >= 24 then
      return nil
    end
    if openEditorOf(view) ~= nil then
      if x >= 0 and x < 128 then
        return { type = "activate", action = "editor-ok" }
      elseif x >= 128 and x < 256 then
        return { type = "activate", action = "editor-cancel" }
      end
      return nil
    end
    if x >= 0 and x < 80 then
      return { type = "activate", action = "search-run" }
    elseif x >= 80 and x < 160 then
      return { type = "activate", action = "search-reset" }
    elseif x >= 160 and x < 256 then
      return { type = "cancel" }
    end
    return nil
  end
  if page == "area" or page == "size" or page == "forms" or page == "return" then
    return tabCommand(x, y, COMPACT_FOOTER_Y)
  end
  return footerCommand(x, y, COMPACT_FOOTER_Y)
end

-- Maps one compact row tap to its finite command. Confirm/select rows
-- carry no action payload; every other row activates by name.
---@param row { action: string, value: string|integer? } row behind the tap
---@return table<string, unknown> finite model command
local function compactRowCommand(row)
  if row.action == "confirm" or row.action == "select" then
    return { type = row.action }
  end
  return { type = "activate", action = row.action, value = row.value }
end

-- Maps pane-local pointer edges on the compact single-display layout by
-- the trusted host pane identity and the one shared geometry record.
-- While the inspection overlay stays open only its toggle maps.
---@param event table<string, unknown> pane-local pointer event with its pane identity
---@param view table<string, unknown>? detached browser projection
---@param page string? top-level page behind the tap
---@param compact table<string, unknown> shared compact geometry record
---@return table<string, unknown>? finite model command
local function mapCompactInput(event, view, page, compact)
  local paneId = event.paneId
  local x, y = event.x, event.y
  local inspectOn = type(view) == "table" and type(view.compact) == "table" and view.compact.inspect == true
  if inspectOn then
    if event.type == "pointer_down" and paneId == "information" and inside(x, y, compact.inspectRect) then
      return { type = "inspect" }
    end
    return nil
  end
  if paneId == "controls" then
    return compactFooter(event, view, page)
  end
  if paneId ~= "information" then
    return nil
  end
  if event.type == "pointer_move" or event.type == "pointer_up" then
    local editor = openEditorOf(view)
    if editor ~= nil and (editor.kind == "height" or editor.kind == "weight") then
      return sliderEditorInput(
        event,
        editor,
        COMPACT_SLIDERS.min,
        COMPACT_SLIDERS.max,
        COMPACT_DIALOG.ok,
        COMPACT_DIALOG.cancel,
        capturedTargetOf(view)
      )
    end
    return nil
  end
  if event.type ~= "pointer_down" then
    return nil
  end
  if page == "cover" then
    return nil
  end
  if page == "grid" or page == "results" then
    local iconRects = compact.grid.iconRects
    for index, rect in ipairs(iconRects) do
      if inside(x, y, rect) then
        return { type = "activate", action = "grid-slot", value = index - 1 }
      end
    end
    if inside(x, y, compact.portraitRect) then
      return { type = "inspect" }
    end
    return nil
  end
  if page == "search" then
    local editor = openEditorOf(view)
    if editor ~= nil and (editor.kind == "height" or editor.kind == "weight") then
      return sliderEditorInput(
        event,
        editor,
        COMPACT_SLIDERS.min,
        COMPACT_SLIDERS.max,
        COMPACT_DIALOG.ok,
        COMPACT_DIALOG.cancel,
        capturedTargetOf(view)
      )
    end
    if editor ~= nil then
      local rows = {}
      for _, option in ipairs(compact.rows) do
        rows[#rows + 1] = { rect = option.rect, value = option.value }
      end
      return optionEditorInput(event, editor, rows, COMPACT_DIALOG.ok, COMPACT_DIALOG.cancel)
    end
    for _, row in ipairs(compact.rows) do
      if inside(x, y, row.rect) then
        return compactRowCommand(row)
      end
    end
    return nil
  end
  if page == "area" or page == "size" or page == "forms" or page == "return" then
    for _, row in ipairs(compact.rows) do
      if inside(x, y, row.rect) then
        return compactRowCommand(row)
      end
    end
    if inside(x, y, compact.portraitRect) or inside(x, y, compact.inspectRect) then
      return { type = "inspect" }
    end
    return nil
  end
  return nil
end

-- Maps one pane-local pointer edge to the finite browser commands by the
-- trusted host pane identity. Unknown panes, outside presses, and hidden
-- compact controls map to nothing; host-only inspection stays distinct
-- from model commands. Native geometry is untouched on paired plans; the
-- compact record drives both mapping and drawing on single-display plans.
---@param event table<string, unknown> pane-local pointer event with its pane identity
---@param view table<string, unknown> detached projection selecting the page
---@param plan table<string, unknown> the resolved application plan
---@return table<string, unknown>? finite model or host command
local function mapBrowserInput(event, view, plan)
  if type(event) ~= "table" or event.outside == true then
    return nil
  end
  if type(event.x) ~= "number" or type(event.y) ~= "number" then
    return nil
  end
  local paneId = event.paneId
  if paneId ~= "information" and paneId ~= "controls" then
    return nil
  end
  local page = nil
  if type(view) == "table" then
    page = view.page
  end
  local compact = nil
  if type(plan) == "table" and type(plan.content) == "table" then
    local record = plan.content.pokedexCompact
    if type(record) == "table" then
      compact = record
    end
  end
  if compact ~= nil then
    return mapCompactInput(event, view, page, compact)
  end
  return mapNativeInput(event, view, page)
end

---@param geometry table<string, unknown>? layout geometry with placements by pane id
---@param paneIds string[] ordered pane identities, later panes hit-test first
---@param interactive boolean
---@return { id: string, placement: table<string, unknown>, interactive: boolean }[] plan panes
local function panesFrom(geometry, paneIds, interactive)
  assert(type(geometry) == "table", "browser geometry resolves its placements")
  local placements = assert(geometry.placements, "browser geometry carries its placements")
  assert(type(placements) == "table", "browser placements stay a record")
  local panes = {}
  for _, id in ipairs(paneIds) do
    local placement = assert(placements[id], "browser geometry places pane " .. id)
    panes[#panes + 1] = { id = id, placement = placement, interactive = interactive }
  end
  return panes
end

---@param panes table<string, unknown>[] resolved plan panes
---@param inputKey string stable input-geometry identity
---@param compact table<string, unknown>? shared compact geometry record, nil on native plans
---@return table<string, unknown> complete application plan
local function browserPlan(panes, inputKey, compact)
  local content = {}
  if compact ~= nil then
    content.pokedexCompact = compact
  end
  return {
    panes = panes,
    frames = {},
    content = content,
    inputKey = inputKey,
    render = renderBrowser,
    mapInput = mapBrowserInput,
  }
end

local function mapUnavailableInput()
  return nil
end

-- The unavailable plan below the minimum compact size: no interactive
-- controls and no pointer mapping, so hidden content can never activate.
---@param inputKey string
---@return table<string, unknown> complete application plan
local function unavailablePlan(inputKey)
  return {
    panes = {},
    frames = {},
    content = { unavailable = true },
    inputKey = inputKey,
    render = renderBrowser,
    mapInput = mapUnavailableInput,
  }
end

---@param measurement table<string, unknown> fresh host facts
---@return boolean true when the display cannot fit the compact arrangement
local function belowMinimum(measurement)
  local width = measurement.width
  local height = measurement.height
  if type(width) == "number" and type(height) == "number" then
    return width < NATIVE_WIDTH or height < NATIVE_HEIGHT
  end
  return false
end

-- Builds the compact information plus controls panes over the single
-- 256x192 surface: the information region carries the grid, portrait,
-- and metadata while the footer strip carries the finite buttons.
---@return { information: table<string, unknown>, controls: table<string, unknown> } placements
local function compactPlacements()
  local information = {
    frame = { x = 0, y = 0, width = NATIVE_WIDTH, height = 168 },
    origin = { x = 0, y = 0 },
    scale = 1,
    logicalWidth = NATIVE_WIDTH,
    logicalHeight = 168,
  }
  local controls = {
    frame = { x = 0, y = 168, width = NATIVE_WIDTH, height = 24 },
    origin = { x = 0, y = 168 },
    scale = 1,
    logicalWidth = NATIVE_WIDTH,
    logicalHeight = 24,
  }
  return { information = information, controls = controls }
end

---@param view table<string, unknown> detached projection selecting the page
---@return string input-geometry identity for the browser plan
local function browserInputKey(view)
  local page = view.page
  if type(page) ~= "string" then
    page = "cover"
  end
  local compact = view.compact
  local inspect = "closed"
  local size = "weight"
  if type(compact) == "table" then
    if compact.inspect == true then
      inspect = "open"
    end
    if compact.size == "height" then
      size = "height"
    end
  end
  local editorKind = "none"
  local search = view.search
  if type(search) == "table" and type(search.editor) == "table" and type(search.editor.kind) == "string" then
    editorKind = search.editor.kind
  end
  local compare = "single"
  if type(view.forms) == "table" and view.forms.comparison ~= nil then
    compare = "compare"
  end
  return "pokedex-browser:" .. page .. ":" .. inspect .. ":" .. size .. ":" .. editorKind .. ":" .. compare
end

-- Resolves one browser plan for the paired native configuration: both
-- original 256x192 panels at integer scale through the shared pair
-- helpers, falling back to the compact arrangement when the pair cannot
-- fit and to the unavailable plan below the minimum size.
---@param context table<string, unknown> layout context with the selected surfaces
---@param measurement table<string, unknown> fresh host facts
---@param upper table<string, unknown> information native pane
---@param lower table<string, unknown> controls native pane
---@param pair fun(context: table<string, unknown>, upper: table<string, unknown>, lower: table<string, unknown>): table<string, unknown>?
---@param view table<string, unknown> detached projection owning the page and compact record
---@return table<string, unknown> complete application plan
local function pairedBrowserPlan(context, measurement, upper, lower, pair, view)
  if belowMinimum(measurement) then
    return unavailablePlan(browserInputKey(view) .. ":unavailable")
  end
  local geometry = pair(context, upper, lower)
  if geometry == nil then
    local placements = compactPlacements()
    return browserPlan({
      { id = "information", placement = placements.information, interactive = true },
      { id = "controls", placement = placements.controls, interactive = true },
    }, browserInputKey(view) .. ":compact-fallback", buildCompactRecord(view))
  end
  return browserPlan(panesFrom(geometry, { "information", "controls" }, true), browserInputKey(view) .. ":paired")
end

-- Renders the prepared registration bundle through the one shared
-- renderer. The registration prepared view carries the terminal card
-- projection and the committed card bundle.
---@param resources table<string, unknown> borrowed draw resources with the renderer
---@param preparedView table<string, unknown> { view, assets }
---@param plan table<string, unknown> the resolved application plan
local function renderRegistration(resources, preparedView, plan)
  local renderer = assert(resources.renderer, "registration drawing borrows its shared renderer")
  assert(type(renderer.drawRegistration) == "function", "registration drawing reaches the shared renderer")
  renderer:drawRegistration({
    view = assert(preparedView.view, "registration draws carry their card projection"),
    assets = assert(preparedView.assets, "registration draws carry their committed bundle"),
  }, plan)
end

-- Either registration pane turns a fresh pointer-down into one touch
-- edge; there is no matched-release requirement and no other pointer
-- shape maps.
---@param event table<string, unknown> logical pointer event in pane space
---@return table<string, unknown>? one fresh touch edge
local function mapRegistrationInput(event)
  if event.type ~= "pointer_down" then
    return nil
  end
  return { type = "touch_new", pointerId = event.pointerId }
end

---@param panes table<string, unknown>[] resolved plan panes
---@param inputKey string stable input-geometry identity
---@return table<string, unknown> complete application plan
local function registrationPlan(panes, inputKey)
  return {
    panes = panes,
    frames = {},
    content = {},
    inputKey = inputKey,
    render = renderRegistration,
    mapInput = mapRegistrationInput,
  }
end

---@param overrides table<string, fun(context: table<string, unknown>, view: table<string, unknown>): table<string, unknown>>? per-case resolver replacements
---@return { dualDisplay: fun(context: table<string, unknown>, view: table<string, unknown>): table<string, unknown>, nativeLike: fun(context: table<string, unknown>, view: table<string, unknown>): table<string, unknown>, wide: fun(context: table<string, unknown>, view: table<string, unknown>): table<string, unknown>, tall: fun(context: table<string, unknown>, view: table<string, unknown>): table<string, unknown> }
function PokedexInterface.browser(overrides)
  ---@param context table<string, unknown>
  ---@param view table<string, unknown>
  ---@return table<string, unknown> complete application plan
  local function dualDisplay(context, view)
    local measurement = assert(context.measurement, "browser plans measure their display")
    return pairedBrowserPlan(context, measurement, INFORMATION_NATIVE, CONTROLS_NATIVE, function(inner, upper, lower)
      return ApplicationLayout.nativeDual(inner, upper, lower)
    end, view)
  end
  ---@param context table<string, unknown>
  ---@param view table<string, unknown>
  ---@return table<string, unknown> complete application plan
  local function wide(context, view)
    local measurement = assert(context.measurement, "browser plans measure their display")
    return pairedBrowserPlan(context, measurement, INFORMATION_NATIVE, CONTROLS_NATIVE, function(inner, upper, lower)
      return ApplicationLayout.sideBySide(inner, upper, lower)
    end, view)
  end
  ---@param context table<string, unknown>
  ---@param view table<string, unknown>
  ---@return table<string, unknown> complete application plan
  local function tall(context, view)
    local measurement = assert(context.measurement, "browser plans measure their display")
    return pairedBrowserPlan(context, measurement, INFORMATION_NATIVE, CONTROLS_NATIVE, function(inner, upper, lower)
      return ApplicationLayout.stacked(inner, upper, lower)
    end, view)
  end
  ---@param context table<string, unknown>
  ---@param view table<string, unknown>
  ---@return table<string, unknown> complete application plan
  local function nativeLike(context, view)
    local measurement = assert(context.measurement, "browser plans measure their display")
    assert(type(view) == "table", "browser plans place their projection")
    local _ = context
    if belowMinimum(measurement) then
      return unavailablePlan(browserInputKey(view) .. ":unavailable")
    end
    local placements = compactPlacements()
    return browserPlan({
      { id = "information", placement = placements.information, interactive = true },
      { id = "controls", placement = placements.controls, interactive = true },
    }, browserInputKey(view) .. ":compact", buildCompactRecord(view))
  end
  local interfaces = { dualDisplay = dualDisplay, nativeLike = nativeLike, wide = wide, tall = tall }
  if overrides ~= nil then
    assert(type(overrides) == "table", "interface overrides arrive as a record")
    for key, resolver in pairs(overrides) do
      assert(
        key == "dualDisplay" or key == "nativeLike" or key == "wide" or key == "tall",
        "interface overrides replace a known case"
      )
      assert(type(resolver) == "function", "interface overrides replace whole render and input pairs")
      interfaces[key] = resolver
    end
  end
  return interfaces
end

---@param overrides table<string, fun(context: table<string, unknown>, view: table<string, unknown>): table<string, unknown>>? per-case resolver replacements
---@return { dualDisplay: fun(context: table<string, unknown>, view: table<string, unknown>): table<string, unknown>, nativeLike: fun(context: table<string, unknown>, view: table<string, unknown>): table<string, unknown>, wide: fun(context: table<string, unknown>, view: table<string, unknown>): table<string, unknown>, tall: fun(context: table<string, unknown>, view: table<string, unknown>): table<string, unknown> }
function PokedexInterface.registration(overrides)
  ---@param context table<string, unknown>
  ---@param view table<string, unknown>
  ---@return table<string, unknown> complete application plan
  local function dualDisplay(context, view)
    local measurement = assert(context.measurement, "registration plans measure their display")
    local _ = view
    if belowMinimum(measurement) then
      return unavailablePlan("pokedex-registration:unavailable")
    end
    local geometry = ApplicationLayout.nativeDual(context, REGISTRATION_NATIVE, REGISTRATION_TOUCH_NATIVE)
    if geometry == nil then
      return unavailablePlan("pokedex-registration:unavailable")
    end
    return registrationPlan(
      panesFrom(geometry, { "registration", "registrationTouch" }, true),
      "pokedex-registration:paired"
    )
  end
  ---@param context table<string, unknown>
  ---@param view table<string, unknown>
  ---@return table<string, unknown> complete application plan
  local function wide(context, view)
    local measurement = assert(context.measurement, "registration plans measure their display")
    local _ = view
    if belowMinimum(measurement) then
      return unavailablePlan("pokedex-registration:unavailable")
    end
    local geometry = ApplicationLayout.sideBySide(context, REGISTRATION_NATIVE, REGISTRATION_TOUCH_NATIVE)
    if geometry == nil then
      return unavailablePlan("pokedex-registration:unavailable")
    end
    return registrationPlan(
      panesFrom(geometry, { "registration", "registrationTouch" }, true),
      "pokedex-registration:paired"
    )
  end
  ---@param context table<string, unknown>
  ---@param view table<string, unknown>
  ---@return table<string, unknown> complete application plan
  local function tall(context, view)
    local measurement = assert(context.measurement, "registration plans measure their display")
    local _ = view
    if belowMinimum(measurement) then
      return unavailablePlan("pokedex-registration:unavailable")
    end
    local geometry = ApplicationLayout.stacked(context, REGISTRATION_NATIVE, REGISTRATION_TOUCH_NATIVE)
    if geometry == nil then
      return unavailablePlan("pokedex-registration:unavailable")
    end
    return registrationPlan(
      panesFrom(geometry, { "registration", "registrationTouch" }, true),
      "pokedex-registration:paired"
    )
  end
  ---@param context table<string, unknown>
  ---@param view table<string, unknown>
  ---@return table<string, unknown> complete application plan
  local function nativeLike(context, view)
    local measurement = assert(context.measurement, "registration plans measure their display")
    local _ = view
    if belowMinimum(measurement) then
      return unavailablePlan("pokedex-registration:unavailable")
    end
    -- The compact card keeps the full 256x192 pane: the opaque cover
    -- owns the whole single display, not the browser footer split.
    local placement = {
      frame = { x = 0, y = 0, width = NATIVE_WIDTH, height = NATIVE_HEIGHT },
      origin = { x = 0, y = 0 },
      scale = 1,
      logicalWidth = NATIVE_WIDTH,
      logicalHeight = NATIVE_HEIGHT,
    }
    return registrationPlan(
      { { id = "registration", placement = placement, interactive = true } },
      "pokedex-registration:compact"
    )
  end
  local interfaces = { dualDisplay = dualDisplay, nativeLike = nativeLike, wide = wide, tall = tall }
  if overrides ~= nil then
    assert(type(overrides) == "table", "interface overrides arrive as a record")
    for key, resolver in pairs(overrides) do
      assert(
        key == "dualDisplay" or key == "nativeLike" or key == "wide" or key == "tall",
        "interface overrides replace a known case"
      )
      assert(type(resolver) == "function", "interface overrides replace whole render and input pairs")
      interfaces[key] = resolver
    end
  end
  return interfaces
end

return PokedexInterface
