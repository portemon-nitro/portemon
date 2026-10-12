-- The gear region-map card: source navigation and marking modes with
-- detached owner snapshots. The controller owns pan, discrete zoom, the
-- selection cursor, the icon drag state machine, and the typed word-entry
-- handoff; live roamer, contact, and catalog inputs are sampled only at
-- refresh boundaries and never moved. Pointer and keyboard keep separate
-- interaction state. One state write per successful swap or delete;
-- cancelled drags publish nothing. Zoom preference persists; drag and
-- editor snapshots stay transient. Pure module: no love, no I/O.

local MapProjection = require("game.hgss.src.pokegear.MapProjection")

---@class MapController
---@field _state table<string, unknown> the borrowed durable companion owner
---@field _assets table<string, unknown> the borrowed compiled asset family
---@field _catalog table<string, unknown> the borrowed compiled map catalog
---@field _mapContext table<string, unknown> the source-normalized map context
---@field _phoneProjection fun(location: string): table<integer, table<string, unknown>> the shared contact availability query
---@field _roamers table<integer, table<string, unknown>> the creation-time roamer snapshot
---@field _wordEntry table<string, unknown> the narrow word-selector handoff
---@field _pan table<string, number> the current viewport pan in pixels
---@field _zoomCells integer the discrete cell size, eight or sixteen pixels
---@field _cursor table<string, integer> the selected world cell
---@field _playerCell table<string, integer> the player world cell at refresh
---@field _mode string the marking mode: map or marking
---@field _transition table<string, unknown>? the active entrance transition
---@field _drag table<string, unknown>? the active pointer capture
---@field _press table<string, unknown>? the active button or word press
---@field _markers table<integer, table<string, unknown>> the refresh-time marker snapshot
---@field _wordOutbox table<string, unknown>? the untaken word request
---@field _wordPending table<string, unknown>? the unresolved word request
---@field _consumed table<string, boolean> consumed word operation identities
---@field _operations integer word operation counter
---@field _ticks integer source ticks since open
---@field _disposed boolean
local MapController = {}
MapController.__index = MapController

-- Pane-local layout in source pixels: entry and zoom buttons above the
-- world, the marking panel across the lower band with its icon pool,
-- four icon slots, four word slots, and the trash action.
local LOCAL_PANE = { x = 0, y = 0, width = 256, height = 192 }
local MARKINGS_BUTTON = { x = 200, y = 8, width = 48, height = 24 }
local ZOOM_BUTTON = { x = 8, y = 8, width = 48, height = 24 }
local PANEL = { x = 8, y = 96, width = 240, height = 88 }
local POOL_TOP = 100
local POOL_LEFT = 16
local POOL_STEP = 24
local POOL_SIZE = 20
local SLOT_TOP = 128
local SLOT_LEFT = 16
local SLOT_STEP = 28
local SLOT_SIZE = 24
local WORD_WIDTH = 44
local TRASH_RECT = { x = 216, y = 128, width = 24, height = 48 }

local ICON_SLOTS = 4
local WORD_SLOTS = 4
local NATIVE_ICONS = 9
local NATIVE_NULL_ICON = 15
local TAP_RADIUS = 4

-- Source marking entrance: the ordered fade and panel slide both finish
-- before the panel accepts input.
local FADE_TICKS = 8
local SLIDE_TICKS = 12

-- Native icon vocabulary behind pool positions one through nine.
local POOL_ICONS = { 1, 2, 3, 4, 5, 6, 7, 8, 9 }

---@param rect table<string, number>
---@return table<string, number>
local function copyRect(rect)
  return { x = rect.x, y = rect.y, width = rect.width, height = rect.height }
end

---@param point table<string, unknown>
---@param rect table<string, number>
---@return boolean
local function inRect(point, rect)
  return type(point.x) == "number"
    and type(point.y) == "number"
    and point.x >= rect.x
    and point.x < rect.x + rect.width
    and point.y >= rect.y
    and point.y < rect.y + rect.height
end

---@param value table<string, unknown>
---@return table<string, unknown>
local function copyCell(value)
  return { x = value.x, y = value.y }
end

---@param icon unknown
---@return integer|false the semantic slot value
local function semanticIcon(icon)
  if icon == false or icon == nil then
    return false
  end
  assert(type(icon) == "number" and icon % 1 == 0, "icon slots carry native icon identities")
  if icon == NATIVE_NULL_ICON then
    return false
  end
  assert(icon >= 1 and icon <= NATIVE_ICONS, "icon slots carry the nine native icon identities")
  return icon
end

---@return table<integer, table<string, number>> pool rects in pool order
local function buildPool()
  local pool = {}
  for index = 1, NATIVE_ICONS do
    pool[index] = { x = POOL_LEFT + (index - 1) * POOL_STEP, y = POOL_TOP, width = POOL_SIZE, height = POOL_SIZE }
  end
  return pool
end

---@param top integer
---@param left integer
---@param step integer
---@param size integer
---@param width integer?
---@param count integer
---@return table<integer, table<string, number>>
local function buildRow(top, left, step, size, width, count)
  local row = {}
  for index = 1, count do
    row[index] = { x = left + (index - 1) * step, y = top, width = width or size, height = size }
  end
  return row
end

---@param word unknown
local function checkWord(word)
  assert(type(word) == "string" and word:match("^[0-9]+$") ~= nil, "word slots carry decimal word identities")
end

---@class MapController.Options
---@field state table<string, unknown> the durable companion owner
---@field assets table<string, unknown> the borrowed compiled asset family
---@field mapContext table<string, unknown> the source-normalized map context
---@field phoneProjection fun(location: string): table<integer, table<string, unknown>> the shared contact availability query
---@field roamerProjection table<integer, table<string, unknown>> the creation-time roamer snapshot
---@field wordEntry table<string, unknown> the narrow word-selector handoff

---@param opts MapController.Options
---@return MapController
function MapController.new(opts)
  assert(type(opts) == "table", "the region map requires its options")
  assert(
    type(opts.state) == "table"
      and type(opts.state.capture) == "function"
      and type(opts.state.setMarking) == "function"
      and type(opts.state.setPreference) == "function"
      and type(opts.state.readPreferences) == "function"
      and type(opts.state.revision) == "function",
    "the region map requires the durable companion owner"
  )
  assert(type(opts.assets) == "table", "the region map requires its compiled asset family")
  local context = assert(opts.mapContext, "the region map requires its normalized map context")
  assert(type(context) == "table", "the region map context is a record")
  assert(
    type(context.fieldMap) == "string"
      and type(context.location) == "string"
      and type(context.matrixX) == "number"
      and type(context.matrixY) == "number"
      and type(context.region) == "string"
      and type(context.unlockLevel) == "number"
      and (context.specialMode == nil or type(context.specialMode) == "string")
      and type(context.playerGender) == "string",
    "the region map context carries field, location, matrix, region, tier, and gender facts"
  )
  assert(type(opts.phoneProjection) == "function", "the region map reads contacts through the shared phone query")
  assert(type(opts.roamerProjection) == "table", "the region map samples roamers once at creation")
  assert(type(opts.wordEntry) == "table", "the region map requires its word-entry handoff")
  local wordEntry = opts.wordEntry --[[@as table<string, unknown>]]
  for _, method in ipairs({ "open", "step", "result", "cancel" }) do
    assert(type(wordEntry[method]) == "function", "the word-entry handoff needs " .. method)
  end
  local catalog = opts.assets.catalog
  assert(type(catalog) == "table" and type(catalog.locations) == "table", "the region map borrows its location table")
  local self = setmetatable({
    _state = opts.state,
    _assets = opts.assets,
    _catalog = catalog,
    _mapContext = {
      fieldMap = context.fieldMap,
      location = context.location,
      matrixX = context.matrixX,
      matrixY = context.matrixY,
      region = context.region,
      unlockLevel = context.unlockLevel,
      specialMode = context.specialMode,
      playerGender = context.playerGender,
    },
    _phoneProjection = opts.phoneProjection,
    _roamers = {},
    _wordEntry = wordEntry,
    _pan = { x = 0, y = 0 },
    _zoomCells = MapProjection.ZOOM_OUT,
    _cursor = { x = 0, y = 0 },
    _playerCell = { x = 0, y = 0 },
    _mode = "map",
    _transition = nil,
    _drag = nil,
    _press = nil,
    _wordOutbox = nil,
    _wordPending = nil,
    _consumed = {},
    _operations = 0,
    _ticks = 0,
    _disposed = false,
  }, MapController)
  for _, roamer in ipairs(opts.roamerProjection) do
    assert(type(roamer) == "table", "the roamer snapshot carries records")
    self._roamers[#self._roamers + 1] = {
      key = roamer.key,
      species = roamer.species,
      location = roamer.location,
      lifecycle = roamer.lifecycle,
    }
  end
  local preferences = self._state:readPreferences()
  assert(type(preferences) == "table", "the region map reads its saved preferences")
  if preferences.mapZoomed == true then
    self._zoomCells = MapProjection.ZOOM_IN
  end
  local playerCell = self:_contextCell()
  self._playerCell = playerCell
  self._cursor = copyCell(playerCell)
  self._markers = self:_sampleMarkers()
  return self
end

---@param fieldMap string
---@return table<string, unknown>? the compiled location record
function MapController:_locationRecord(fieldMap)
  local locations = self._catalog.locations
  assert(type(locations) == "table", "the region map borrows its location table")
  for _, entry in ipairs(locations) do
    if type(entry) == "table" and (entry.fieldMap == fieldMap or entry.location == fieldMap) then
      return entry
    end
  end
  return nil
end

---@return { x: integer, y: integer } the player world cell at refresh
function MapController:_contextCell()
  local context = self._mapContext
  local record = self:_locationRecord(context.fieldMap)
  local explicitX, explicitY, special = nil, nil, context.specialMode
  if type(record) == "table" then
    if type(record.explicitX) == "number" and type(record.explicitY) == "number" then
      explicitX, explicitY = record.explicitX, record.explicitY
    end
    if special == nil and type(record.special) == "string" then
      special = record.special
    end
  end
  local ok, cell = pcall(MapProjection.contextCell, {
    matrixX = context.matrixX,
    matrixY = context.matrixY,
    explicitX = explicitX,
    explicitY = explicitY,
    lastExterior = nil,
    specialSpawn = nil,
    special = special,
  })
  if ok and type(cell) == "table" then
    return { x = cell.x, y = cell.y }
  end
  return {
    x = math.floor(context.matrixX / 32),
    y = math.floor(context.matrixY / 32),
  }
end

-- Samples roamer and contact markers once at refresh: only roamers active
-- at creation appear, and contact markers follow the shared phone query
-- per catalog location. The snapshot never touches the live owners again.
---@return table<integer, table<string, unknown>>
function MapController:_sampleMarkers()
  local markers = {}
  for _, roamer in ipairs(self._roamers) do
    if roamer.lifecycle == "roaming" then
      markers[#markers + 1] = {
        kind = "roamer",
        key = roamer.key,
        species = roamer.species,
        location = roamer.location,
        point = self:_roamerPoint(roamer.location),
      }
    end
  end
  local locations = self._catalog.locations
  assert(type(locations) == "table", "the region map borrows its location table")
  for _, entry in ipairs(locations) do
    if type(entry) == "table" and type(entry.key) == "string" then
      local ok, found = pcall(self._phoneProjection, entry.key)
      assert(ok, "contact markers follow the shared phone query")
      if type(found) == "table" then
        for _, marker in ipairs(found) do
          assert(type(marker) == "table", "the phone query carries marker records")
          markers[#markers + 1] = {
            kind = "contact",
            contact = marker.contact,
            tier = marker.tier,
            ready = marker.ready,
            gift = marker.gift,
            location = entry.key,
            point = self:_locationPoint(entry),
          }
        end
      end
    end
  end
  return markers
end

---@param location unknown the encounter map fact from the roamer snapshot
---@return table<string, number>? the pane point, or nil when unresolvable
function MapController:_roamerPoint(location)
  local locations = self._catalog.locations
  assert(type(locations) == "table", "the region map borrows its location table")
  for _, entry in ipairs(locations) do
    if type(entry) == "table" and (entry.key == location or entry.location == location or entry.mapRef == location) then
      return self:_locationPoint(entry)
    end
  end
  return nil
end

---@param entry table<string, unknown> the compiled location record
---@return table<string, number>? the pane point, or nil when unresolvable
function MapController:_locationPoint(entry)
  local ok, cell = pcall(MapProjection.contextCell, {
    matrixX = type(entry.matrix) == "table" and entry.matrix.x or nil,
    matrixY = type(entry.matrix) == "table" and entry.matrix.y or nil,
    explicitX = type(entry.explicitX) == "number" and entry.explicitX or nil,
    explicitY = type(entry.explicitY) == "number" and entry.explicitY or nil,
    lastExterior = nil,
    specialSpawn = nil,
    special = type(entry.special) == "string" and entry.special or nil,
  })
  if not ok or type(cell) ~= "table" then
    return nil
  end
  return MapProjection.markerPoint(cell, self._pan, self._zoomCells, LOCAL_PANE)
end

---@return table<string, unknown> the current marking record with explicit empty slots
function MapController:_currentMarking()
  local bucket = self._state:capture()
  assert(type(bucket) == "table" and type(bucket.markings) == "table", "the region map reads its markings")
  local stored = (bucket --[[@as table<string, unknown>]]).markings[self._mapContext.location]
  if type(stored) == "table" then
    local icons, words = {}, {}
    for index = 1, ICON_SLOTS do
      icons[index] = stored.icons[index] ~= nil and stored.icons[index] or false
    end
    for index = 1, WORD_SLOTS do
      words[index] = stored.words[index] ~= nil and stored.words[index] or false
    end
    return { icons = icons, words = words }
  end
  return { icons = { false, false, false, false }, words = { false, false, false, false } }
end

-- Commits one marking mutation exactly once, removing records emptied by
-- the source empty-record rules instead of storing blank residue.
---@param marking table<string, unknown>
function MapController:_commitMarking(marking)
  local empty = true
  for _, slot in ipairs({ "icons", "words" }) do
    for index = 1, ICON_SLOTS do
      if marking[slot][index] ~= false then
        empty = false
        break
      end
    end
  end
  if empty then
    self._state:setMarking(self._mapContext.location, nil)
    return
  end
  self._state:setMarking(self._mapContext.location, marking)
end

-- Starts the ordered marking entrance: fade and slide run together and
-- both completions gate input.
function MapController:_beginMarkingEntrance()
  self._transition = { kind = "marking-enter", fade = 0, slide = 0 }
end

---@param event table<string, unknown>
function MapController:_handleNavigate(event)
  if self._mode ~= "map" then
    return
  end
  local direction = event.direction
  if type(direction) ~= "string" then
    return
  end
  local cursor = copyCell(self._cursor)
  if direction == "left" then
    cursor.x = cursor.x - 1
  elseif direction == "right" then
    cursor.x = cursor.x + 1
  elseif direction == "up" then
    cursor.y = cursor.y - 1
  elseif direction == "down" then
    cursor.y = cursor.y + 1
  else
    return
  end
  self._cursor = MapProjection.clampCursor(cursor, self._zoomCells, self._mapContext.unlockLevel)
end

function MapController:_handleConfirm()
  if self._mode == "map" and self._transition == nil and self._wordPending == nil then
    self:_beginMarkingEntrance()
  end
end

---@param event table<string, unknown>
function MapController:_handlePointerDown(event)
  if type(event.x) ~= "number" or type(event.y) ~= "number" then
    return
  end
  local point = { x = event.x, y = event.y }
  local pointerId = event.pointerId
  if self._mode == "marking" then
    local panel = self:_panelRects()
    for index, rect in ipairs(panel.pool) do
      if inRect(point, rect) then
        self._drag = { pointerId = pointerId, kind = "pool", icon = POOL_ICONS[index], x = point.x, y = point.y }
        return
      end
    end
    for index, rect in ipairs(panel.icons) do
      if inRect(point, rect) then
        local marking = self:_currentMarking()
        if marking.icons[index] ~= false then
          self._drag = {
            pointerId = pointerId,
            kind = "slot",
            from = index,
            icon = marking.icons[index],
            x = point.x,
            y = point.y,
          }
        else
          self._press = { pointerId = pointerId, kind = "panel", x = point.x, y = point.y }
        end
        return
      end
    end
    for index, rect in ipairs(panel.words) do
      if inRect(point, rect) then
        self._press = { pointerId = pointerId, kind = "word", slot = index, x = point.x, y = point.y }
        return
      end
    end
    self._press = { pointerId = pointerId, kind = "panel", x = point.x, y = point.y }
    return
  end
  if inRect(point, MARKINGS_BUTTON) then
    self._press = { pointerId = pointerId, kind = "markings", x = point.x, y = point.y }
  elseif inRect(point, ZOOM_BUTTON) then
    self._press = { pointerId = pointerId, kind = "zoom", x = point.x, y = point.y }
  else
    self._drag = { pointerId = pointerId, kind = "pan", startX = point.x, startY = point.y, x = point.x, y = point.y }
  end
end

---@param event table<string, unknown>
function MapController:_handlePointerMove(event)
  local drag = self._drag
  if drag == nil or drag.pointerId ~= event.pointerId then
    return
  end
  if type(event.x) ~= "number" or type(event.y) ~= "number" then
    return
  end
  if drag.kind == "pan" then
    local pan = {
      x = self._pan.x + (event.x - drag.x),
      y = self._pan.y + (event.y - drag.y),
    }
    self._pan = MapProjection.clampPan(pan, self._zoomCells, LOCAL_PANE)
  end
  drag.x, drag.y = event.x, event.y
end

---@param point table<string, unknown>
---@param panel table<string, unknown>
---@return string kind, integer? slot
local function dropTarget(point, panel)
  for index, rect in ipairs(panel.icons) do
    if inRect(point, rect) then
      return "slot", index
    end
  end
  if inRect(point, panel.trash) then
    return "trash", nil
  end
  return "void", nil
end

---@param event table<string, unknown>
function MapController:_handlePointerUp(event)
  if type(event.x) ~= "number" or type(event.y) ~= "number" then
    self._drag, self._press = nil, nil
    return
  end
  local point = { x = event.x, y = event.y }
  local drag = self._drag
  if drag ~= nil and drag.pointerId == event.pointerId then
    self._drag, self._press = nil, nil
    if drag.kind == "pool" or drag.kind == "slot" then
      local panel = self:_panelRects()
      local target, slot = dropTarget(point, panel)
      if target == "slot" and slot ~= nil then
        self:_dropIcon(drag, slot)
      elseif target == "trash" and drag.kind == "slot" and drag.from ~= nil then
        self:_deleteIcon(drag.from)
      end
    elseif drag.kind == "pan" then
      local moved = math.abs(point.x - drag.startX) + math.abs(point.y - drag.startY)
      if moved <= TAP_RADIUS and self._mode == "map" then
        local cell = MapProjection.inverse(point, self._pan, self._zoomCells, LOCAL_PANE)
        if cell ~= nil and MapProjection.tierOfColumn(cell.x) <= self._mapContext.unlockLevel then
          self._cursor = MapProjection.clampCursor(cell, self._zoomCells, self._mapContext.unlockLevel)
        end
      end
    end
    return
  end
  local press = self._press
  if press ~= nil and press.pointerId == event.pointerId then
    self._press = nil
    if press.kind == "markings" and inRect(point, MARKINGS_BUTTON) then
      self:_beginMarkingEntrance()
    elseif press.kind == "zoom" and inRect(point, ZOOM_BUTTON) then
      self:_toggleZoom()
    elseif press.kind == "word" and press.slot ~= nil then
      local panel = self:_panelRects()
      local rect = panel.words[press.slot]
      if rect ~= nil and inRect(point, rect) then
        self:_requestWord(press.slot)
      end
    end
  end
end

-- Drops a dragged icon into its target slot: pool icons land, occupied
-- slots swap. Exactly one state write.
---@param drag table<string, unknown>
---@param slot integer
function MapController:_dropIcon(drag, slot)
  assert(slot >= 1 and slot <= ICON_SLOTS, "icon drops name their slot")
  local marking = self:_currentMarking()
  if drag.kind == "pool" then
    marking.icons[slot] = semanticIcon(drag.icon)
  elseif drag.kind == "slot" and drag.from ~= nil then
    local from = drag.from --[[@as integer]]
    assert(from >= 1 and from <= ICON_SLOTS, "icon drags start in their slot")
    if from == slot then
      return
    end
    marking.icons[from], marking.icons[slot] = semanticIcon(marking.icons[slot]), semanticIcon(marking.icons[from])
  else
    return
  end
  self:_commitMarking(marking)
end

-- Deletes one icon slot. Exactly one state write.
---@param slot integer
function MapController:_deleteIcon(slot)
  assert(slot >= 1 and slot <= ICON_SLOTS, "icon deletes name their slot")
  local marking = self:_currentMarking()
  marking.icons[slot] = false
  self:_commitMarking(marking)
end

function MapController:_toggleZoom()
  if self._zoomCells == MapProjection.ZOOM_OUT then
    self._zoomCells = MapProjection.ZOOM_IN
    self._state:setPreference("mapZoomed", true)
  else
    self._zoomCells = MapProjection.ZOOM_OUT
    self._state:setPreference("mapZoomed", false)
  end
  self._pan = MapProjection.clampPan(self._pan, self._zoomCells, LOCAL_PANE)
  self._cursor = MapProjection.clampCursor(self._cursor, self._zoomCells, self._mapContext.unlockLevel)
end

-- Pends one typed word request for the current location and slot. The
-- external selector answers through acceptWordResult; a pending edit
-- ignores further taps until it resolves.
---@param slot integer
function MapController:_requestWord(slot)
  assert(slot >= 1 and slot <= WORD_SLOTS, "word edits name their slot")
  if self._wordPending ~= nil then
    return
  end
  local marking = self:_currentMarking()
  local oldWord = marking.words[slot]
  if oldWord == nil then
    oldWord = false
  end
  self._operations = self._operations + 1
  local request = {
    locationKey = self._mapContext.location,
    slot = slot,
    oldWord = oldWord,
    operationId = "map-word-" .. tostring(self._operations),
    session = {
      pan = { x = self._pan.x, y = self._pan.y },
      zoomCells = self._zoomCells,
      cursor = copyCell(self._cursor),
      markingMode = self._mode,
    },
  }
  self._wordPending = request
  self._wordOutbox = request
end

-- One fixed tick: entrance transitions advance, gated input changes
-- nothing, and the marking state machine consumes its semantic events.
---@param uiInput table[]
function MapController:updateFixed(uiInput)
  assert(not self._disposed, "a disposed region map steps nothing")
  assert(type(uiInput) == "table", "the region map input must be an event list")
  self._ticks = self._ticks + 1
  if self._transition ~= nil then
    local transition = self._transition --[[@as table<string, unknown>]]
    transition.fade = transition.fade --[[@as integer]] + 1
    transition.slide = transition.slide --[[@as integer]] + 1
    if transition.fade >= FADE_TICKS and transition.slide >= SLIDE_TICKS then
      self._transition = nil
      self._mode = "marking"
      self._markers = self:_sampleMarkers()
    end
    return
  end
  for _, event in ipairs(uiInput) do
    if type(event) == "table" and type(event.type) == "string" then
      self:_handle(event)
    end
  end
end

---@param event table<string, unknown>
function MapController:_handle(event)
  if event.type == "cancel" then
    if self._drag ~= nil then
      self._drag, self._press = nil, nil
      return
    end
    if self._wordPending ~= nil then
      self._wordPending, self._wordOutbox = nil, nil
      return
    end
    if self._mode == "marking" then
      self._mode = "map"
    end
    self._press = nil
  elseif event.type == "pointer_down" then
    if self._wordPending == nil then
      self:_handlePointerDown(event)
    end
  elseif event.type == "pointer_move" then
    if self._wordPending == nil then
      self:_handlePointerMove(event)
    end
  elseif event.type == "pointer_up" then
    if self._wordPending == nil then
      self:_handlePointerUp(event)
    end
  elseif event.type == "navigate" then
    if self._wordPending == nil then
      self:_handleNavigate(event)
    end
  elseif event.type == "confirm" then
    if self._wordPending == nil then
      self:_handleConfirm()
    end
  end
end

---@return table<string, unknown> the marking panel hit regions
function MapController:_panelRects()
  return {
    panel = copyRect(PANEL),
    pool = buildPool(),
    icons = buildRow(SLOT_TOP, SLOT_LEFT, SLOT_STEP, SLOT_SIZE, nil, ICON_SLOTS),
    words = buildRow(SLOT_TOP + 32, SLOT_LEFT, SLOT_STEP + 24, SLOT_SIZE, WORD_WIDTH, WORD_SLOTS),
    trash = copyRect(TRASH_RECT),
  }
end

-- Takes the pending word request for the external selector, exactly once.
---@return table<string, unknown>? the typed request, or nil when no edit is pending
function MapController:takeWordRequest()
  local request = self._wordOutbox
  self._wordOutbox = nil
  return request
end

-- Applies the external selector result to its original edit: a selected
-- word writes once, a cancellation preserves the old word, and every
-- return restores the map session exactly. Unknown or already-consumed
-- operation identities fail without touching marking state.
---@param answer { operationId: string, result: table<string, unknown> }
function MapController:acceptWordResult(answer)
  assert(type(answer) == "table", "word answers carry their operation identity")
  assert(type(answer.operationId) == "string", "word answers name their operation")
  assert(type(answer.result) == "table", "word answers carry the selector result")
  if self._consumed[answer.operationId] == true then
    error("a replayed word result edits nothing: " .. answer.operationId, 0)
  end
  local pending = self._wordPending
  if pending == nil or pending.operationId ~= answer.operationId then
    error("a stale word result edits nothing: " .. tostring(answer.operationId), 0)
  end
  local result = answer.result --[[@as table<string, unknown>]]
  local session = pending.session --[[@as table<string, unknown>]]
  if result.cancelled == true then
    self._wordPending, self._wordOutbox = nil, nil
    self._consumed[answer.operationId] = true
    self:_restoreSession(session)
    return
  end
  assert(type(result.word) == "string", "selected words carry their word identity")
  checkWord(result.word)
  local marking = self:_currentMarking()
  marking.words[pending.slot] = result.word
  self:_commitMarking(marking)
  self._wordPending, self._wordOutbox = nil, nil
  self._consumed[answer.operationId] = true
  self:_restoreSession(session)
end

---@param session table<string, unknown>
function MapController:_restoreSession(session)
  local pan = session.pan --[[@as table<string, number>]]
  local cursor = session.cursor --[[@as table<string, integer>]]
  self._pan = { x = pan.x, y = pan.y }
  self._zoomCells = session.zoomCells --[[@as integer]]
  self._cursor = { x = cursor.x, y = cursor.y }
  self._mode = session.markingMode --[[@as string]]
end

-- The detached information lines behind the info-panel windows: region
-- and location always, plus one rematch line per ready contact marker.
---@return table<integer, table<string, string>>
function MapController:_infoLines()
  local lines = {
    { window = "region", text = self._mapContext.region },
    { window = "location", text = self._mapContext.location },
  }
  for _, marker in ipairs(self._markers) do
    if marker.kind == "contact" and marker.ready == true then
      lines[#lines + 1] = { window = "rematch", text = marker.contact }
    end
  end
  return lines
end

---@param node unknown
---@param skin integer
---@return string? path
local function pickPath(node, skin)
  if type(node) ~= "table" then
    return nil
  end
  local record = node --[[@as table<string, unknown>]]
  if type(record.image) == "string" then
    return record.image
  end
  local skinned = record[skin]
  if type(skinned) == "table" and type(skinned.image) == "string" then
    return skinned.image
  end
  local keys = {}
  for key in pairs(record) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  for _, key in ipairs(keys) do
    local child = record[key]
    if type(child) == "table" then
      local found = pickPath(child, skin)
      if found ~= nil then
        return found
      end
    end
  end
  return nil
end

-- Resolves the content image paths behind the current skin, tolerating
-- companion fixtures that carry one shared plane per section.
---@return table<string, unknown>
function MapController:_contentPaths()
  local preferences = self._state:readPreferences()
  local skin = 0
  if type(preferences) == "table" and type(preferences.skin) == "number" then
    skin = preferences.skin --[[@as integer]]
  end
  local map = self._assets.map
  assert(type(map) == "table", "the region map borrows its visuals")
  local section = map --[[@as table<string, unknown>]]
  local foreground = pickPath(section.foreground, skin)
  if foreground == nil then
    foreground = pickPath(section, skin)
  end
  return {
    world = pickPath(section.world, skin) or pickPath(section, skin),
    foreground = foreground,
    upper = pickPath(section.upper, skin) or pickPath(section.upperBase, skin),
    patch = pickPath(section.patches, skin),
  }
end

-- The presentation snapshot: lifetime flags the shell routes on, the
-- marking mode, the active transition, and the detached map view with
-- its hit regions, marker snapshot, and renderer content. Fresh tables
-- per call; status performs no mutation.
---@return table<string, unknown>
function MapController:status()
  local cursorPoint = MapProjection.forward(self._cursor, self._pan, self._zoomCells, LOCAL_PANE)
  local playerPoint = MapProjection.markerPoint(self._playerCell, self._pan, self._zoomCells, LOCAL_PANE)
  local markers = {}
  for _, marker in ipairs(self._markers) do
    local copy = {}
    for key, value in pairs(marker) do
      if key == "point" and type(value) == "table" then
        copy.point = { x = value.x, y = value.y }
      else
        copy[key] = value
      end
    end
    markers[#markers + 1] = copy
  end
  local transition = nil
  if self._transition ~= nil then
    transition = { kind = self._transition.kind, completed = false }
  end
  local panel = nil
  if self._mode == "marking" then
    panel = self:_panelRects()
  end
  return {
    open = true,
    tab = "map",
    busy = self._wordPending ~= nil,
    dismissible = true,
    nestedCancel = self._mode == "marking" or self._drag ~= nil or self._wordPending ~= nil,
    markingMode = self._mode,
    transition = transition,
    view = {
      cursor = copyCell(self._cursor),
      cursorPoint = { x = cursorPoint.x, y = cursorPoint.y },
      playerCell = copyCell(self._playerCell),
      playerPoint = { x = playerPoint.x, y = playerPoint.y },
      pan = { x = self._pan.x, y = self._pan.y },
      zoomCells = self._zoomCells,
      markers = markers,
      markingsButton = copyRect(MARKINGS_BUTTON),
      zoomButton = copyRect(ZOOM_BUTTON),
      markingPanel = panel,
      maskRects = self:_maskRects(),
      unlockLevel = self._mapContext.unlockLevel,
      region = self._mapContext.region,
      locationKey = self._mapContext.location,
      playerGender = self._mapContext.playerGender,
      infoLines = self:_infoLines(),
      content = self:_contentPaths(),
      cursorFrame = self:_cursorFrame(),
      marking = self:_currentMarking(),
    },
  }
end

-- The locked-tier mask rects in pane space: every column band above the
-- unlocked progression tier.
---@return table<integer, table<string, number>>
function MapController:_maskRects()
  local bands = {
    { fromX = 28, toX = 31, tier = 2 },
    { fromX = 32, toX = 63, tier = 3 },
  }
  local rects = {}
  for _, band in ipairs(bands) do
    if band.tier > self._mapContext.unlockLevel then
      local topLeft = MapProjection.forward({ x = band.fromX, y = 0 }, self._pan, self._zoomCells, LOCAL_PANE)
      local bottomRight = MapProjection.forward({ x = band.toX + 1, y = 0 }, self._pan, self._zoomCells, LOCAL_PANE)
      rects[#rects + 1] = {
        x = topLeft.x,
        y = LOCAL_PANE.y,
        width = bottomRight.x - topLeft.x,
        height = LOCAL_PANE.height,
      }
    end
  end
  return rects
end

-- The current cursor animation frame behind the double-size affine
-- cursor, resolved from the compiled cursor sequences when present.
---@return table<string, unknown>? frame
function MapController:_cursorFrame()
  local sequences = self._assets.sequences
  if type(sequences) ~= "table" then
    return nil
  end
  local clip = sequences["shell.cursor.1"]
  if type(clip) ~= "table" or type(clip.frames) ~= "table" or #clip.frames == 0 then
    return nil
  end
  local frames = clip.frames --[[@as table]]
  local frame = frames[(math.floor(self._ticks / 8) % #frames) + 1]
  if type(frame) ~= "table" then
    return nil
  end
  return {
    image = frame.image,
    width = frame.width,
    height = frame.height,
    anchorX = frame.anchorX or 0,
    anchorY = frame.anchorY or 0,
  }
end

-- The region map never closes itself: the shell owns dismissal.
---@return nil
function MapController:takeResult()
  return nil
end

-- Idempotent release of the logical lifetime: drops transient edit state
-- and reports nothing further. Committed markings already live in the
-- borrowed state owner.
function MapController:dispose()
  self._drag, self._press = nil, nil
  self._transition = nil
  self._wordOutbox, self._wordPending = nil, nil
  self._disposed = true
end

return MapController
