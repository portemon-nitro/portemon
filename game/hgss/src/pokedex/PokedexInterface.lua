-- Shared draw/input placement for the field Pokedex: the complete browser
-- layout family and the registration layout over the same plan mechanics.
-- Dual, wide, and tall preserve both original 256x192 panels at integer
-- scale; the single-display nativeLike case is the complete compact
-- arrangement with all fifteen grid cells and the selected species
-- information visible together. Interface definitions are immutable;
-- sessions own captures. Measure and path lookups never allocate GPU
-- objects, and mapInput never touches mutable game state.

local ApplicationLayout = require("libs.ui.src.ApplicationLayout")
local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
local PokedexSearch = require("game.hgss.src.pokedex.PokedexSearch")

---@class PokedexInterface
local PokedexInterface = {}

local NATIVE_WIDTH = 256
local NATIVE_HEIGHT = 192

local INFORMATION_NATIVE = { id = "information", width = NATIVE_WIDTH, height = NATIVE_HEIGHT }
local CONTROLS_NATIVE = { id = "controls", width = NATIVE_WIDTH, height = NATIVE_HEIGHT }
local REGISTRATION_NATIVE = { id = "registration", width = NATIVE_WIDTH, height = NATIVE_HEIGHT }
local REGISTRATION_TOUCH_NATIVE = { id = "registrationTouch", width = NATIVE_WIDTH, height = NATIVE_HEIGHT }

-- Compact footer geometry: one 256x24 controls-pane strip shared by the
-- drawn record and the hit mapper. Button records carry their own
-- enabled/selected state plus the source-backed visible mark behind
-- each action, so no parallel hit table exists.

-- Source list geometry on the controls pane: five 40px columns from x27
-- and three 40px rows from y4, transcribed from the native list hitboxes.
local NATIVE_LIST = { x = 27, y = 4, step = 40, columns = 5, rows = 3 }
local NATIVE_LIST_X1 = 227
local NATIVE_LIST_Y1 = 124

-- Native page arrows beside the list. The vertical scrollbar band
-- between the two arrows pages nothing and keeps its own gesture.
local NATIVE_ARROWS = {
  prev = { box = { top = 5, bottom = 20, left = 231, right = 252 } },
  next = { box = { top = 131, bottom = 146, left = 231, right = 252 } },
}

-- Native search criteria menu on the controls pane, transcribed from the
-- source menu hitboxes in inclusive {top,bottom,left,right} form.
-- Entries are matched in source order; the row under a tap never decides.
local NATIVE_SEARCH_MENU = {
  { box = { top = 8, bottom = 23, left = 128, right = 215 }, value = "order" },
  { box = { top = 32, bottom = 47, left = 56, right = 127 }, value = "letter" },
  { box = { top = 56, bottom = 71, left = 56, right = 177 }, value = "type" },
  { box = { top = 80, bottom = 95, left = 56, right = 183 }, value = "height" },
  { box = { top = 104, bottom = 119, left = 56, right = 239 }, value = "weight" },
  { box = { top = 128, bottom = 143, left = 56, right = 111 }, value = "area" },
  { box = { top = 56, bottom = 87, left = 208, right = 239 }, value = "shape" },
}

-- Native search root bottom band: left reset, center run, right back.
-- The gap between the three controls stays inert.
local NATIVE_SEARCH_BOTTOM = {
  { box = { top = 164, bottom = 187, left = 4, right = 75 }, action = "search-reset" },
  { box = { top = 164, bottom = 187, left = 92, right = 163 }, action = "search-run" },
  { box = { top = 164, bottom = 187, left = 180, right = 251 }, action = "cancel" },
}

-- Native option-editor bottom band: left commit, right cancel. The gap
-- between the two controls stays inert.
local NATIVE_EDITOR_BOTTOM = {
  { box = { top = 164, bottom = 187, left = 4, right = 75 }, action = "editor-ok" },
  { box = { top = 164, bottom = 187, left = 180, right = 251 }, action = "editor-cancel" },
}

-- Native order-editor options: six choices in row-major order over two
-- columns and three rows. The first choice sorts numerically and the
-- last sorts by shortest.
local NATIVE_ORDER_EDITOR = {
  { box = { top = 48, bottom = 63, left = 24, right = 111 }, value = "numerical" },
  { box = { top = 48, bottom = 63, left = 144, right = 231 }, value = "alphabetical" },
  { box = { top = 80, bottom = 95, left = 24, right = 111 }, value = "heaviest" },
  { box = { top = 80, bottom = 95, left = 144, right = 231 }, value = "lightest" },
  { box = { top = 112, bottom = 127, left = 24, right = 111 }, value = "tallest" },
  { box = { top = 112, bottom = 127, left = 144, right = 231 }, value = "shortest" },
}

-- Native type-editor grid: eighteen positional cells in row-major order
-- over four columns; the final row holds only the first two cells.
-- Positional indices 0..16 select the published type order and index 17
-- clears the filter.
local NATIVE_TYPE_COLUMNS = { { 3, 60 }, { 67, 124 }, { 131, 188 }, { 195, 252 } }
local NATIVE_TYPE_ROWS = { { 40, 55 }, { 64, 79 }, { 88, 104 }, { 112, 127 } }
local NATIVE_TYPE_LAST_ROW = { top = 136, bottom = 151 }

-- Native shape-editor grid: fifteen positional cells in row-major order
-- over five columns and three rows. Positional indices 0..13 select the
-- published shape order and index 14 clears the filter.
local NATIVE_SHAPE_COLUMNS = { { 16, 47 }, { 64, 95 }, { 112, 143 }, { 160, 191 }, { 208, 239 } }
local NATIVE_SHAPE_ROWS = { { 40, 71 }, { 80, 111 }, { 120, 151 } }

-- Native area-editor grid: the four scope choices in row-major order
-- over two columns and two rows. Positional indices select johto,
-- kanto, unknown, then the clearing choice.
local NATIVE_AREA_CELLS = {
  { box = { top = 64, bottom = 79, left = 48, right = 103 }, index = 0 },
  { box = { top = 64, bottom = 79, left = 152, right = 207 }, index = 1 },
  { box = { top = 120, bottom = 135, left = 48, right = 103 }, index = 2 },
  { box = { top = 120, bottom = 135, left = 152, right = 207 }, index = 3 },
}

-- Native 27-letter editor grid: the first three rows hold seven cells
-- each and the last row holds six with the 184..199 slot missing.
-- Positional indices 0..25 hold A..Z and index 26 clears the filter.
local NATIVE_LETTER_COLUMNS =
  { { 24, 39 }, { 56, 71 }, { 88, 103 }, { 120, 135 }, { 152, 167 }, { 184, 199 }, { 216, 231 } }
local NATIVE_LETTER_ROWS = { { 40, 55 }, { 72, 87 }, { 104, 119 } }
local NATIVE_LETTER_LAST_ROW = { top = 136, bottom = 151 }

-- Native browser footer behind the list grid: search, cry, entry, and
-- exit share the source y152..187 band. The entry cell opens the entry
-- on the area tab; the rows above and below the band stay inert.
local NATIVE_LIST_FOOTER = {
  { box = { top = 152, bottom = 187, left = 0, right = 63 }, action = "search" },
  { box = { top = 152, bottom = 187, left = 64, right = 127 }, action = "cry" },
  { box = { top = 152, bottom = 187, left = 128, right = 191 }, action = "entry-tab", value = "area" },
  { box = { top = 152, bottom = 187, left = 192, right = 255 }, action = "cancel" },
}

-- Native entry tabs: four source bands over the y168..183 strip. Gaps
-- between the bands and the rows above and below switch nothing.
local NATIVE_ENTRY_TABS = {
  { box = { top = 168, bottom = 183, left = 7, right = 57 }, value = "area" },
  { box = { top = 168, bottom = 183, left = 71, right = 121 }, value = "size" },
  { box = { top = 168, bottom = 183, left = 135, right = 185 }, value = "forms" },
  { box = { top = 168, bottom = 183, left = 199, right = 249 }, value = "return" },
}

-- Native area daypart selectors: three circle targets carrying the
-- original centers and radius on the controls pane.
local NATIVE_AREA_CIRCLES = {
  { cx = 77, cy = 33, radius = 13, value = 0 },
  { cx = 109, cy = 33, radius = 13, value = 1 },
  { cx = 141, cy = 33, radius = 13, value = 2 },
}

-- Native height/weight slider geometry on the controls pane: the upper
-- track drives the maximum endpoint and the lower track drives the
-- minimum endpoint. The authored step counts handle-center pixels from
-- the x52 origin, clamped to 0..152, never a fraction of the hitbox.
local NATIVE_SLIDER_TRACKS = {
  max = { box = { top = 46, bottom = 73, left = 26, right = 229 } },
  min = { box = { top = 118, bottom = 145, left = 26, right = 229 } },
}
local NATIVE_SLIDER_STEP_ORIGIN_X = 52

-- Native slider step arrows beside each track: each arrow steps only its
-- own endpoint in its own direction.
local NATIVE_SLIDER_ARROWS = {
  { box = { top = 49, bottom = 70, left = 10, right = 25 }, endpoint = "max", direction = -1 },
  { box = { top = 49, bottom = 70, left = 230, right = 245 }, endpoint = "max", direction = 1 },
  { box = { top = 121, bottom = 142, left = 10, right = 25 }, endpoint = "min", direction = -1 },
  { box = { top = 121, bottom = 142, left = 230, right = 245 }, endpoint = "min", direction = 1 },
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

-- Compact single-display reflow (host adaptation, non-retail
-- arrangement over native message ids and art): everything below down to
-- the compact input mapper reflows the browser onto one 256x192 display
-- instead of the retail dual panels. Roles reuse native ids and art;
-- only the geometry and the footer/row records are host-owned.
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

-- Converts one native slider-track position to the authored 0..152 drag
-- step. The source counts handle-center pixels from the x52 origin,
-- clamped to the valid range, never a fraction of the touch hitbox.
---@param x number pane-local x
---@return integer clamped author step
local function nativeSliderStep(x)
  local step = math.floor(x - NATIVE_SLIDER_STEP_ORIGIN_X + 0.5)
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
  if insideSourceRect(x, y, NATIVE_ARROWS.prev.box) then
    return { type = "activate", action = "page-prev" }
  end
  if insideSourceRect(x, y, NATIVE_ARROWS.next.box) then
    return { type = "activate", action = "page-next" }
  end
  for _, button in ipairs(NATIVE_LIST_FOOTER) do
    if insideSourceRect(x, y, button.box) then
      if button.action == "cancel" then
        return { type = "cancel" }
      end
      if button.value ~= nil then
        return { type = "activate", action = button.action, value = button.value }
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

-- Maps one pane-local slider-track position to its drag edge. Native
-- tracks convert from the handle origin; compact tracks keep the
-- proportional mapping behind their own drawn rectangles.
---@param eventType string pointer edge type
---@param criterion string height or weight criterion
---@param endpoint string min or max endpoint
---@param event table<string, unknown> pane-local pointer event
---@param track table<string, unknown> slider track behind the endpoint
---@param native boolean true on the native source tracks
---@return table<string, unknown>? finite model command
local function sliderEdge(eventType, criterion, endpoint, event, track, native)
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
  local value = nil
  if native == true then
    value = nativeSliderStep(event.x)
  else
    -- Compact tracks carry flat pane geometry; native tracks carry a source box.
    if track.box ~= nil then
      error("native slider tracks never reach the compact conversion", 0)
    end
    value = sliderStep(event.x, track)
  end
  return { type = "drag", target = criterion .. "-" .. endpoint, phase = phase, value = value }
end

-- Maps pointer edges on a height/weight slider editor behind its track
-- pair. A press on a track captures that endpoint; every later move or
-- release carries the captured endpoint regardless of the pointer's
-- later vertical band, projected and clamped on the original track. A
-- move or release with no captured endpoint maps to nothing.
---@param event table<string, unknown> pane-local pointer event
---@param editor table<string, unknown> open slider editor
---@param minTrack { x: number, y: number, width: number, height: number }|{ box: table<string, integer> } minimum track
---@param maxTrack { x: number, y: number, width: number, height: number }|{ box: table<string, integer> } maximum track
---@param okRect { x: number, y: number, width: number, height: number }|{ box: table<string, integer> } commit button
---@param cancelRect { x: number, y: number, width: number, height: number }|{ box: table<string, integer> } cancel button
---@param captured string? in-flight captured slider target behind the gesture
---@param native boolean true on the native source geometry with step arrows
---@return table<string, unknown>? finite model command
local function sliderEditorInput(event, editor, minTrack, maxTrack, okRect, cancelRect, captured, native)
  local criterion = editor.kind
  local function onTrack(x, y, track)
    if native == true then
      return insideSourceRect(x, y, track.box)
    end
    return inside(x, y, track)
  end
  local function onButton(x, y, button)
    if native == true then
      return insideSourceRect(x, y, button.box)
    end
    return inside(x, y, button)
  end
  if event.type == "pointer_down" then
    local x, y = event.x, event.y
    if native == true then
      for _, arrow in ipairs(NATIVE_SLIDER_ARROWS) do
        if insideSourceRect(x, y, arrow.box) then
          return {
            type = "activate",
            action = "slider-step",
            criterion = criterion,
            endpoint = arrow.endpoint,
            direction = arrow.direction,
          }
        end
      end
    end
    if onTrack(x, y, minTrack) then
      return sliderEdge(event.type, criterion, "min", event, minTrack, native)
    end
    if onTrack(x, y, maxTrack) then
      return sliderEdge(event.type, criterion, "max", event, maxTrack, native)
    end
    if onButton(x, y, okRect) then
      return { type = "activate", action = "editor-ok" }
    end
    if onButton(x, y, cancelRect) then
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
  return sliderEdge(event.type, criterion, endpoint, event, track, native)
end

-- Maps pointer edges on an option editor: one row per projected option
-- plus the commit/cancel pair. Disabled options stay semantically inert.
---@param event table<string, unknown> pane-local pointer event
---@param editor table<string, unknown> open option editor with its options
---@param rows { rect: { x: number, y: number, width: number, height: number }, value: string, enabled: boolean? }[] option rows
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
    if row.enabled ~= false and inside(x, y, row.rect) then
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
-- fewer options fit, otherwise a three-column grid. The letter editor
-- alone uses its own compact four-column grid so all twenty-seven
-- choices stay above the commit/cancel row.
---@param options string[] projected editor options
---@param originX number list left edge in pane-local coordinates
---@param originY number list top edge in pane-local coordinates
---@param columnWidth number single-column row width
---@param rowHeight number single-column row height
---@param kind string? open editor criterion behind the rows
---@return { rect: { x: number, y: number, width: number, height: number }, value: string }[] option rows
local function optionRowsFor(options, originX, originY, columnWidth, rowHeight, kind)
  local rows = {}
  if kind == "letter" then
    for index, option in ipairs(options) do
      local column = (index - 1) % 4
      local row = math.floor((index - 1) / 4)
      rows[#rows + 1] = {
        rect = { x = 8 + column * 40, y = 8 + row * 16, width = 38, height = 16 },
        value = option,
      }
    end
    return rows
  end
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

-- Reads the positional option index behind one pane-local point in the
-- native type grid. The final row holds only its first two cells.
---@param x number pane-local x
---@param y number pane-local y
---@return integer? zero-based positional index behind the point
local function nativeTypeIndex(x, y)
  local column = nil
  for position, range in ipairs(NATIVE_TYPE_COLUMNS) do
    if x >= range[1] and x <= range[2] then
      column = position - 1
    end
  end
  if column == nil then
    return nil
  end
  for position, range in ipairs(NATIVE_TYPE_ROWS) do
    if y >= range[1] and y <= range[2] then
      return (position - 1) * 4 + column
    end
  end
  if y >= NATIVE_TYPE_LAST_ROW.top and y <= NATIVE_TYPE_LAST_ROW.bottom and column <= 1 then
    return 16 + column
  end
  return nil
end

-- Reads the positional option index behind one pane-local point in the
-- native shape grid.
---@param x number pane-local x
---@param y number pane-local y
---@return integer? zero-based positional index behind the point
local function nativeShapeIndex(x, y)
  local column = nil
  for position, range in ipairs(NATIVE_SHAPE_COLUMNS) do
    if x >= range[1] and x <= range[2] then
      column = position - 1
    end
  end
  if column == nil then
    return nil
  end
  for position, range in ipairs(NATIVE_SHAPE_ROWS) do
    if y >= range[1] and y <= range[2] then
      return (position - 1) * 5 + column
    end
  end
  return nil
end

-- Reads the letter option behind one pane-local point in the native
-- 27-letter grid. The first three rows hold seven cells each and the
-- last row holds six with the 184..199 slot missing; positional indices
-- 0..25 hold A..Z and index 26 clears the filter. The letters are fixed
-- source facts, so the mapper resolves them directly.
---@param x number pane-local x
---@param y number pane-local y
---@return string? letter option behind the point
local function nativeLetterValue(x, y)
  local column = nil
  for position, range in ipairs(NATIVE_LETTER_COLUMNS) do
    if x >= range[1] and x <= range[2] then
      column = position - 1
    end
  end
  if column == nil then
    return nil
  end
  local index = nil
  for position, range in ipairs(NATIVE_LETTER_ROWS) do
    if y >= range[1] and y <= range[2] then
      index = (position - 1) * 7 + column
    end
  end
  if index == nil then
    if y < NATIVE_LETTER_LAST_ROW.top or y > NATIVE_LETTER_LAST_ROW.bottom then
      return nil
    end
    if column == 5 then
      return nil
    end
    if column == 6 then
      index = 26
    else
      index = 21 + column
    end
  end
  if index == 26 then
    return "unrestricted"
  end
  return string.char(string.byte("A") + index)
end

-- Reads the enabled flag behind one native area scope: the locked scope
-- stays inert like its blank native window.
---@param editor table<string, unknown> open area editor with its scope flags
---@param option string candidate scope key
---@return boolean true when the scope stays selectable
local function nativeAreaEnabled(editor, option)
  if type(editor.choices) == "table" then
    local scope = editor.choices[option]
    if type(scope) == "table" then
      return scope.enabled == true
    end
  end
  return true
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
      NATIVE_SLIDER_TRACKS.min,
      NATIVE_SLIDER_TRACKS.max,
      NATIVE_EDITOR_BOTTOM[1],
      NATIVE_EDITOR_BOTTOM[2],
      capturedTargetOf(view),
      true
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
    local options = nil
    if type(editor.options) == "table" then
      options = editor.options
    end
    if editor.kind == "letter" then
      local value = nativeLetterValue(x, y)
      if value ~= nil then
        return { type = "activate", action = "editor-choice", value = value }
      end
    elseif editor.kind == "order" then
      for _, box in ipairs(NATIVE_ORDER_EDITOR) do
        if insideSourceRect(x, y, box.box) then
          return { type = "activate", action = "editor-choice", value = box.value }
        end
      end
    elseif editor.kind == "type" and options ~= nil then
      local index = nativeTypeIndex(x, y)
      if index ~= nil and type(options[index + 1]) == "string" then
        return { type = "activate", action = "editor-choice", value = options[index + 1] }
      end
    elseif editor.kind == "shape" and options ~= nil then
      local index = nativeShapeIndex(x, y)
      if index ~= nil and type(options[index + 1]) == "string" then
        return { type = "activate", action = "editor-choice", value = options[index + 1] }
      end
    elseif editor.kind == "area" and options ~= nil then
      for _, cell in ipairs(NATIVE_AREA_CELLS) do
        if insideSourceRect(x, y, cell.box) then
          local option = options[cell.index + 1]
          if type(option) == "string" and nativeAreaEnabled(editor, option) then
            return { type = "activate", action = "editor-choice", value = option }
          end
          return nil
        end
      end
    end
    for _, button in ipairs(NATIVE_EDITOR_BOTTOM) do
      if insideSourceRect(x, y, button.box) then
        return { type = "activate", action = button.action }
      end
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
  for _, button in ipairs(NATIVE_SEARCH_BOTTOM) do
    if insideSourceRect(x, y, button.box) then
      if button.action == "cancel" then
        return { type = "cancel" }
      end
      return { type = "activate", action = button.action }
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

-- Reads the grid paging behind the projection: page and last page default
-- to zero when the projection stages no grid buffer.
---@param view table<string, unknown>? detached browser projection
---@return integer page zero-based grid page
---@return integer lastPage zero-based final grid page
local function gridPagingOf(view)
  local page, lastPage = 0, 0
  if type(view) == "table" and type(view.grid) == "table" then
    if type(view.grid.page) == "number" then
      page = math.floor(view.grid.page)
    end
    if type(view.grid.lastPage) == "number" then
      lastPage = math.floor(view.grid.lastPage)
    end
  end
  return page, lastPage
end

-- Reads the staged cursor entry behind the projection, if any.
---@param view table<string, unknown>? detached browser projection
---@return table<string, unknown>? staged grid entry with species/seen/caught
local function gridCursorEntryOf(view)
  if type(view) ~= "table" or type(view.grid) ~= "table" then
    return nil
  end
  local grid = view.grid
  local cursor = 0
  if type(grid.cursor) == "number" then
    cursor = math.floor(grid.cursor)
  end
  local buffers = grid.buffers
  if type(buffers) ~= "table" then
    return nil
  end
  local first = buffers[1]
  if type(first) ~= "table" or type(first.entries) ~= "table" then
    return nil
  end
  local entry = first.entries[cursor + 1]
  if type(entry) == "table" then
    return entry
  end
  return nil
end

-- Reads the selection behind the projection, if any.
---@param view table<string, unknown>? detached browser projection
---@return table<string, unknown>? detached selection with species/seen/caught
local function selectionOf(view)
  if type(view) == "table" and type(view.selection) == "table" then
    return view.selection
  end
  return nil
end

-- Lists the compact footer buttons behind one page: the cover triple,
-- the browser actions, the search run/reset/back triple (or the editor
-- commit/cancel pair while an editor stays open), or the four entry
-- tabs. Every button carries its enabled/selected state plus the
-- source-backed visible mark the renderer paints and the mapper gates:
-- labelRole names a ready prepared message, iconRole names a prepared
-- pictogram (source arrow subject or selected species icon).
-- Coordinates are controls-pane-local.
---@param view table<string, unknown>? detached browser projection
---@param page string? top-level page behind the plan
---@return table[] footer buttons with enablement and visible marks
local function compactFooterButtons(view, page)
  local buttons = {}
  local function add(id, x, width, mark)
    local button = {
      id = id,
      x = x,
      y = COMPACT_FOOTER_Y,
      width = width,
      height = COMPACT_FOOTER_HEIGHT,
      enabled = true,
      selected = false,
    }
    if type(mark) == "table" then
      for key, value in pairs(mark) do
        button[key] = value
      end
    end
    buttons[#buttons + 1] = button
  end
  if page == "cover" then
    add("search", 0, 80, { labelRole = "compact.action-search" })
    add("open", 80, 96, { labelRole = "compact.action-open" })
    add("exit", 176, 80, { labelRole = "compact.action-back" })
  elseif page == "search" and openEditorOf(view) ~= nil then
    add("editor-ok", 0, 128, { labelRole = "search.button-ok" })
    add("editor-cancel", 128, 128, { labelRole = "search.button-cancel" })
  elseif page == "search" then
    add("search-run", 0, 80, { labelRole = "search.button-run" })
    add("search-reset", 80, 80, { labelRole = "search.button-reset" })
    add("back", 160, 96, { labelRole = "search.button-back" })
  elseif page == "area" or page == "size" or page == "forms" or page == "return" then
    local tabs = {
      { id = "area", labelRole = "compact.tab-area" },
      { id = "size", labelRole = "compact.tab-size" },
      { id = "forms", labelRole = "compact.tab-forms" },
      { id = "return", labelRole = "compact.tab-return" },
    }
    for index, tab in ipairs(tabs) do
      add(tab.id, (index - 1) * 64, 64, { labelRole = tab.labelRole, selected = page == tab.id })
    end
  else
    local gridPage, gridLast = gridPagingOf(view)
    add("page-prev", 0, 24, {
      enabled = gridPage > 0,
      iconRole = "arrow-up",
      iconChoice = gridPage > 0 and "enabled" or "disabled",
    })
    add("page-next", 24, 24, {
      enabled = gridPage < gridLast,
      iconRole = "arrow-down",
      iconChoice = gridPage < gridLast and "enabled" or "disabled",
    })
    add("cover", 48, 48, { labelRole = "compact.action-cover" })
    add("search", 96, 48, { labelRole = "compact.action-search" })
    local entry = gridCursorEntryOf(view)
    local crySpecies = nil
    if type(entry) == "table" and type(entry.species) == "string" and entry.seen == true then
      crySpecies = entry.species
    end
    local cryOn = crySpecies ~= nil
    add("cry", 144, 32, { enabled = cryOn, iconRole = "species-icon", iconSpecies = crySpecies })
    local selection = selectionOf(view)
    local languageOn = type(selection) == "table" and type(selection.species) == "string" and selection.seen == true
    add("language", 176, 40, { enabled = languageOn, labelRole = "compact.detail-name" })
    add("exit", 216, 40, { labelRole = "compact.action-back" })
  end
  return buttons
end

-- Names the staged value roles behind one search criterion for the compact
-- row: order/letter/area paint one staged word, type and the slider
-- criteria paint their staged pair, and shape stages no value role.
---@param criterion string staged criterion behind the row
---@return string|string[]? prepared value role or roles behind the row
local function stagedValueRole(criterion)
  if criterion == "order" then
    return "search.value-order"
  elseif criterion == "letter" then
    return "search.value-letter"
  elseif criterion == "type" then
    return { "search.value-type-1", "search.value-type-2" }
  elseif criterion == "height" then
    return { "search.value-height-min", "search.value-height-max" }
  elseif criterion == "weight" then
    return { "search.value-weight-min", "search.value-weight-max" }
  elseif criterion == "area" then
    return "search.value-area"
  end
  return nil
end

-- Tests whether one editor option carries the staged choice: the focused
-- option for single-value editors, the pending type pair for the type
-- editor. Unknown editor shapes never claim a selection.
---@param editor table<string, unknown>? open editor projection
---@param kind string editor criterion
---@param option string candidate option key
---@return boolean true when the option stages the current choice
local function editorOptionSelected(editor, kind, option)
  if type(editor) ~= "table" then
    return false
  end
  if type(editor.focus) == "string" and editor.focus == option then
    return true
  end
  if kind == "type" and type(editor.types) == "table" then
    for _, staged in ipairs(editor.types) do
      if staged == option then
        return true
      end
    end
  end
  return false
end

-- Reads the enabled flag behind one editor option: the area editor
-- publishes per-scope flags (a locked scope stays blank like its native
-- window); every other editor enables all its options.
---@param editor table<string, unknown>? open editor projection
---@param kind string editor criterion
---@param option string candidate option key
---@return boolean true when the option stays selectable
local function editorOptionEnabled(editor, kind, option)
  if kind == "area" and type(editor) == "table" and type(editor.choices) == "table" then
    local scope = editor.choices[option]
    if type(scope) == "table" then
      return scope.enabled == true
    end
  end
  return true
end

-- Builds the page-dependent compact rows on the information pane:
-- criteria or editor options on search, selectable habitat/form rows on
-- area/forms, entry actions, and the Return confirmation. Every visible
-- row carries its enabled/selected state plus the source-backed label
-- and value roles the renderer paints; the same records drive the hit
-- mapper, so no invisible active row exists. The area/forms list rows
-- mirror the controller's six-row window around the cursor so their
-- label roles match the published slots.
---@param view table<string, unknown>? detached browser projection
---@param page string? top-level page behind the plan
---@return table[] action rows with enablement and visible roles
local function compactRowsFor(view, page)
  local rows = {}
  if page == "search" then
    local editor = openEditorOf(view)
    if editor ~= nil then
      local kind = editor.kind
      if type(kind) ~= "string" then
        kind = editor.criterion
      end
      if type(kind) == "string" and kind ~= "height" and kind ~= "weight" and type(editor.options) == "table" then
        local options =
          optionRowsFor(editor.options, COMPACT_ROW.x, COMPACT_ROW.firstY, COMPACT_ROW.width, COMPACT_ROW.height, kind)
        for _, option in ipairs(options) do
          rows[#rows + 1] = {
            action = "editor-choice",
            value = option.value,
            rect = option.rect,
            enabled = editorOptionEnabled(editor, kind, option.value),
            selected = editorOptionSelected(editor, kind, option.value),
            labelRole = "search.option-" .. kind .. "-" .. tostring(option.value),
          }
        end
      end
      rows[#rows + 1] = {
        action = "editor-ok",
        rect = COMPACT_DIALOG.ok,
        enabled = true,
        selected = false,
        labelRole = "search.button-ok",
      }
      rows[#rows + 1] = {
        action = "editor-cancel",
        rect = COMPACT_DIALOG.cancel,
        enabled = true,
        selected = false,
        labelRole = "search.button-cancel",
      }
      return rows
    end
    local focus = nil
    if type(view) == "table" and type(view.search) == "table" then
      focus = view.search.focus
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
        enabled = true,
        selected = focus == criterion,
        labelRole = "search.caption-" .. criterion,
        valueRole = stagedValueRole(criterion),
      }
    end
    return rows
  end
  if page == "area" then
    local area = nil
    if type(view) == "table" then
      area = view.area
    end
    local cursor = 0
    if type(area) == "table" and type(area.row) == "number" then
      cursor = math.floor(area.row)
    end
    local areaCount = entryRowCount(view, page)
    for position = 1, 6 do
      local index = cursor + position - 2
      if index >= 0 and index < areaCount then
        local labelRole = position == 1 and "area.location" or ("area.row-" .. position)
        rows[#rows + 1] = {
          action = "area-row",
          value = index,
          rect = { x = 8, y = 8 + (position - 1) * 14, width = 160, height = 14 },
          enabled = true,
          selected = index == cursor,
          labelRole = labelRole,
        }
      end
    end
    rows[#rows + 1] = {
      action = "confirm",
      rect = COMPACT_ACTIONS.primary,
      enabled = true,
      selected = false,
      labelRole = "area.time",
    }
    rows[#rows + 1] = {
      action = "select",
      rect = COMPACT_ACTIONS.secondary,
      enabled = true,
      selected = false,
      labelRole = "area.caption",
    }
    return rows
  end
  if page == "size" then
    rows[#rows + 1] = {
      action = "size-restart",
      rect = COMPACT_ACTIONS.primary,
      enabled = true,
      selected = false,
      labelRole = "size.title",
    }
    return rows
  end
  if page == "forms" then
    local forms = nil
    if type(view) == "table" then
      forms = view.forms
    end
    if type(forms) == "table" and forms.comparison ~= nil then
      local compareRows = {
        { action = "compare-side", value = 0, labelRole = "forms.compare-label-left" },
        { action = "compare-side", value = 1, labelRole = "forms.compare-label-right" },
        { action = "compare-flip", labelRole = "forms.compare-caption" },
        { action = "compare-back", labelRole = "forms.title" },
      }
      for index, row in ipairs(compareRows) do
        rows[#rows + 1] = {
          action = row.action,
          value = row.value,
          rect = COMPACT_COMPARE[index],
          enabled = true,
          selected = false,
          labelRole = row.labelRole,
        }
      end
      return rows
    end
    local cursor = 0
    if type(forms) == "table" and type(forms.row) == "number" then
      cursor = math.floor(forms.row)
    end
    local formsCount = entryRowCount(view, page)
    for position = 1, 6 do
      local index = cursor + position - 2
      if index >= 0 and index < formsCount then
        rows[#rows + 1] = {
          action = "forms-row",
          value = index,
          rect = { x = 8, y = 8 + (position - 1) * 14, width = 160, height = 14 },
          enabled = true,
          selected = index == cursor,
          labelRole = "forms.row-" .. position,
        }
      end
    end
    rows[#rows + 1] = {
      action = "compare",
      rect = COMPACT_ACTIONS.primary,
      enabled = true,
      selected = false,
      labelRole = "forms.title",
    }
    return rows
  end
  if page == "return" then
    rows[#rows + 1] = {
      action = "return-list",
      rect = { x = 8, y = 8, width = 160, height = 20 },
      enabled = true,
      selected = true,
      labelRole = "return.action",
    }
    return rows
  end
  return rows
end

-- Builds the compact slider tracks behind a height/weight editor with the
-- source-backed caption and staged bound roles the renderer paints.
---@param view table<string, unknown>? detached browser projection
---@return table[] slider tracks with visible roles
local function compactSlidersFor(view)
  local editor = openEditorOf(view)
  if editor == nil or (editor.kind ~= "height" and editor.kind ~= "weight") then
    return {}
  end
  local kind = editor.kind --[[@as string]]
  return {
    {
      target = kind .. "-min",
      rect = COMPACT_SLIDERS.min,
      captionRole = "search.title-" .. kind,
      valueRole = "search.current-" .. kind .. "-min",
    },
    {
      target = kind .. "-max",
      rect = COMPACT_SLIDERS.max,
      captionRole = "search.title-" .. kind,
      valueRole = "search.current-" .. kind .. "-max",
    },
  }
end

-- Names the inspector detail roles behind one page: the compact
-- selection family on the list pages, the entry specimen family on the
-- entry pages, and no detail roles elsewhere. The renderer paints only
-- the roles the ready bundle actually carries.
---@param page string? top-level page behind the plan
---@return table<string, string> named detail roles behind the inspector body
local function inspectorDetailRoles(page)
  if page == "grid" or page == "results" then
    return {
      number = "compact.detail-number",
      name = "compact.detail-name",
      category = "compact.detail-category",
      flavor = "compact.detail-flavor",
      height = "compact.detail-height",
      weight = "compact.detail-weight",
    }
  end
  if page == "area" or page == "size" or page == "forms" or page == "return" then
    return {
      number = "entry.dex-number",
      name = "entry.species-name",
      category = "entry.category",
      flavor = "entry.flavor",
      height = "entry.height",
      weight = "entry.weight",
    }
  end
  return {}
end

-- Builds the one feature-local compact geometry record shared by the
-- mapper and the renderer: grid, portrait, inspection toggle, footer,
-- page rows, slider tracks, and the inspector role inventory. Native
-- plans carry no record.
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
    inspection = { closeRole = "compact.action-back", roles = inspectorDetailRoles(page) },
  }
end

-- Maps one drawn footer button to its finite command, preserving the
-- established per-page shapes: cover opens/confirms/cancels, search
-- runs/resets/cancels (or commits/cancels an editor), entry buttons
-- switch tabs, and the list footer pages, covers, searches, cries
-- through the menu edge, re-languages, or cancels.
---@param id string drawn button identity
---@param page string? top-level page behind the plan
---@return table<string, unknown> finite model command
local function footerButtonCommand(id, page)
  if page == "cover" then
    if id == "open" then
      return { type = "confirm" }
    elseif id == "exit" then
      return { type = "cancel" }
    else
      return { type = "activate", action = id }
    end
  end
  if page == "search" then
    if id == "back" then
      return { type = "cancel" }
    else
      return { type = "activate", action = id }
    end
  end
  if page == "area" or page == "size" or page == "forms" or page == "return" then
    return { type = "activate", action = "entry-tab", value = id }
  end
  if id == "exit" then
    return { type = "cancel" }
  elseif id == "cry" then
    return { type = "menu" }
  else
    return { type = "activate", action = id }
  end
end

-- Maps one compact footer press through the one shared button record:
-- only an enabled button inside its drawn rectangle produces its finite
-- command. Disabled buttons stay semantically inert.
---@param event table<string, unknown> pane-local pointer event
---@param page string? top-level page behind the plan
---@param compact table<string, unknown> shared compact geometry record
---@return table<string, unknown>? finite model command
local function compactFooter(event, page, compact)
  if event.type ~= "pointer_down" then
    return nil
  end
  local x, y = event.x, event.y
  local footer = compact.footer
  if type(footer) ~= "table" or type(footer.buttons) ~= "table" then
    return nil
  end
  for _, button in ipairs(footer.buttons) do
    if type(button) == "table" and button.enabled ~= false and inside(x, y, button) then
      return footerButtonCommand(button.id, page)
    end
  end
  return nil
end

-- Reads the slider tracks behind the shared record for one editor kind.
---@param compact table<string, unknown> shared compact geometry record
---@param kind string height or weight editor kind
---@return table<string, unknown>? minimum track rectangle
---@return table<string, unknown>? maximum track rectangle
local function sliderTracksOf(compact, kind)
  local minTrack, maxTrack = nil, nil
  if type(compact.sliders) == "table" then
    for _, slider in ipairs(compact.sliders) do
      if type(slider) == "table" and type(slider.rect) == "table" then
        if slider.target == kind .. "-min" then
          minTrack = slider.rect
        elseif slider.target == kind .. "-max" then
          maxTrack = slider.rect
        end
      end
    end
  end
  return minTrack, maxTrack
end

-- Reads the editor commit/cancel rectangles behind the shared record.
---@param compact table<string, unknown> shared compact geometry record
---@return table<string, unknown> commit rectangle
---@return table<string, unknown> cancel rectangle
local function dialogRectsOf(compact)
  local okRect, cancelRect = nil, nil
  if type(compact.rows) == "table" then
    for _, row in ipairs(compact.rows) do
      if type(row) == "table" and type(row.rect) == "table" then
        if row.action == "editor-ok" then
          okRect = row.rect
        elseif row.action == "editor-cancel" then
          cancelRect = row.rect
        end
      end
    end
  end
  return assert(okRect, "the compact record carries its editor commit"),
    assert(cancelRect, "the compact record carries its editor cancel")
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
    return compactFooter(event, page, compact)
  end
  if paneId ~= "information" then
    return nil
  end
  if event.type == "pointer_move" or event.type == "pointer_up" then
    local editor = openEditorOf(view)
    if editor ~= nil and (editor.kind == "height" or editor.kind == "weight") then
      local minTrack, maxTrack = sliderTracksOf(compact, editor.kind)
      assert(minTrack ~= nil, "the compact record carries the slider minimum")
      assert(maxTrack ~= nil, "the compact record carries the slider maximum")
      local okRect, cancelRect = dialogRectsOf(compact)
      return sliderEditorInput(event, editor, minTrack, maxTrack, okRect, cancelRect, capturedTargetOf(view), false)
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
      local minTrack, maxTrack = sliderTracksOf(compact, editor.kind)
      assert(minTrack ~= nil, "the compact record carries the slider minimum")
      assert(maxTrack ~= nil, "the compact record carries the slider maximum")
      local okRect, cancelRect = dialogRectsOf(compact)
      return sliderEditorInput(event, editor, minTrack, maxTrack, okRect, cancelRect, capturedTargetOf(view), false)
    end
    if editor ~= nil then
      local rows = {}
      for _, option in ipairs(compact.rows) do
        if type(option) == "table" and option.action == "editor-choice" and type(option.rect) == "table" then
          rows[#rows + 1] = { rect = option.rect, value = option.value, enabled = option.enabled }
        end
      end
      local okRect, cancelRect = dialogRectsOf(compact)
      return optionEditorInput(event, editor, rows, okRect, cancelRect)
    end
    for _, row in ipairs(compact.rows) do
      if row.enabled ~= false and inside(x, y, row.rect) then
        return compactRowCommand(row)
      end
    end
    return nil
  end
  if page == "area" or page == "size" or page == "forms" or page == "return" then
    for _, row in ipairs(compact.rows) do
      if row.enabled ~= false and inside(x, y, row.rect) then
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

-- Resolves the one compact browser plan: a single 256x192 logical parent
-- centered at the largest integer scale inside the selected display's
-- usable safe bounds, split into the 256x168 information and 256x24
-- controls children that share the parent scale, offset, and clipping.
-- When no integer 1x parent fits, the plan stays non-interactive instead
-- of publishing a clipped or fractionally scaled fallback.
---@param context table<string, unknown> layout context with the selected surfaces
---@param view table<string, unknown> detached projection owning the page and compact record
---@param inputKey string stable input-geometry identity for the browser plan
---@param suffix string input-key suffix behind the resolved plan
---@return table<string, unknown> complete application plan
local function fitCompactPlan(context, inputKey, view, suffix)
  local key = inputKey
  local geometry =
    ApplicationLayout.centered(context, { id = "pokedexCompact", width = NATIVE_WIDTH, height = NATIVE_HEIGHT })
  local parent = nil
  if type(geometry) == "table" and type(geometry.placements) == "table" then
    parent = geometry.placements.pokedexCompact
  end
  if parent == nil then
    return unavailablePlan(key .. ":unavailable")
  end
  local information = LayoutGeometry.subPlacement(parent, { x = 0, y = 0, width = NATIVE_WIDTH, height = 168 })
  assert(information ~= nil, "the fitted parent contains its information child")
  local controls = LayoutGeometry.subPlacement(parent, { x = 0, y = 168, width = NATIVE_WIDTH, height = 24 })
  assert(controls ~= nil, "the fitted parent contains its controls child")
  return browserPlan({
    { id = "information", placement = information, interactive = true },
    { id = "controls", placement = controls, interactive = true },
  }, key .. suffix, buildCompactRecord(view))
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
  local _ = measurement
  local geometry = pair(context, upper, lower)
  if geometry == nil then
    return fitCompactPlan(context, browserInputKey(view), view, ":compact-fallback")
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
    assert(type(view) == "table", "browser plans place their projection")
    return fitCompactPlan(context, browserInputKey(view), view, ":compact")
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
