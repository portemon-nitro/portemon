-- The standalone Town/Fly map selector: a distinct source application
-- sharing region-map data and affine projection with the gear Map tab
-- but owning its own entry, chrome, and terminal result. Fly mode
-- confirms one semantic flypoint from the permitted set and reports it
-- with its operation identity; the view-only Town mode never emits a
-- destination. Geometry reuses MapProjection only; marking and tab state
-- stay with the Map tab. Pure module: no love dependency.

local MapProjection = require("game.hgss.src.pokegear.MapProjection")

---@class FlyMapController
---@field _mode string the source entry: view-only townMap or selecting fly
---@field _operationId string the owning operation identity echoed in the terminal
---@field _context table<string, unknown> the source-normalized map context
---@field _destinations table<integer, string> the permitted semantic flypoint keys in order
---@field _assets table<string, unknown> the borrowed compiled asset family
---@field _presentation table<string, unknown> the borrowed presentation facts
---@field _terminal table<string, unknown>? the single settled result
---@field _disposed boolean
local FlyMapController = {}
FlyMapController.__index = FlyMapController

-- Pane-local layout in source pixels: the standalone entry paints its
-- own confirmation control in the lower band, never a tab strip.
local LOCAL_PANE = { x = 0, y = 0, width = 256, height = 192 }
local CONFIRM_BUTTON = { x = 184, y = 160, width = 64, height = 24 }

---@param rect table<string, number>
---@return table<string, number>
local function copyRect(rect)
  return { x = rect.x, y = rect.y, width = rect.width, height = rect.height }
end

-- The origin context behind a view-only map opened without live field
-- facts: the selector presents the region chrome with no markers rather
-- than inventing a position.
---@return table<string, unknown>
local function defaultContext()
  return {
    fieldMap = "",
    location = "",
    matrixX = 0,
    matrixY = 0,
    region = "",
    unlockLevel = 1,
    specialMode = nil,
    playerGender = "boy",
  }
end

---@param context unknown
---@return table<string, unknown> the detached validated context
local function checkContext(context)
  assert(type(context) == "table", "the fly selector reads a normalized map context")
  assert(type(context.fieldMap) == "string", "the map context carries its field map")
  assert(type(context.location) == "string", "the map context carries its location")
  assert(
    type(context.matrixX) == "number" and type(context.matrixY) == "number",
    "the map context carries matrix facts"
  )
  assert(type(context.region) == "string", "the map context carries its region")
  assert(
    type(context.unlockLevel) == "number" and context.unlockLevel % 1 == 0,
    "the map context carries its progression tier"
  )
  assert(
    context.specialMode == nil or type(context.specialMode) == "string",
    "the map context carries its special mode"
  )
  assert(type(context.playerGender) == "string", "the map context carries its player gender")
  return {
    fieldMap = context.fieldMap,
    location = context.location,
    matrixX = context.matrixX,
    matrixY = context.matrixY,
    region = context.region,
    unlockLevel = context.unlockLevel,
    specialMode = context.specialMode,
    playerGender = context.playerGender,
  }
end

---@param node unknown
---@return string? path
local function imageOf(node)
  if type(node) == "table" and type(node.image) == "string" then
    return node.image --[[@as string]]
  end
  return nil
end

---@param node table<string, unknown>
---@param out table<integer, string>
local function collectImages(node, out)
  local keys = {}
  for key in pairs(node) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  for _, key in ipairs(keys) do
    local child = node[key]
    if type(child) == "table" then
      local path = imageOf(child)
      if path ~= nil then
        out[#out + 1] = path
      else
        collectImages(child --[[@as table<string, unknown>]], out)
      end
    end
  end
end

---@class FlyMapController.Options
---@field mode string the source entry: townMap or fly
---@field operationId string the owning operation identity
---@field context table<string, unknown>? the source-normalized map context
---@field destinations table<integer, string>? the permitted semantic flypoint keys
---@field assets table<string, unknown> the borrowed compiled asset family
---@field presentation table<string, unknown>? the borrowed presentation facts

---@param opts FlyMapController.Options
---@return FlyMapController
function FlyMapController.new(opts)
  assert(type(opts) == "table", "the fly selector requires its options")
  assert(opts.mode == "townMap" or opts.mode == "fly", "the fly selector opens view-only or for selection")
  assert(
    type(opts.operationId) == "string" and opts.operationId ~= "",
    "the fly selector carries its operation identity"
  )
  local context = defaultContext()
  if opts.context ~= nil then
    context = checkContext(opts.context)
  end
  local destinations = {}
  if opts.destinations ~= nil then
    assert(type(opts.destinations) == "table", "fly destinations arrive as a key list")
    for index, key in ipairs(opts.destinations) do
      assert(type(key) == "string" and key ~= "", "fly destinations name semantic flypoint keys")
      destinations[index] = key
    end
  end
  assert(type(opts.assets) == "table", "the fly selector borrows its asset family")
  local presentation = opts.presentation
  if presentation == nil then
    presentation = {}
  end
  assert(type(presentation) == "table", "the fly selector borrows its presentation facts")
  return setmetatable({
    _mode = opts.mode,
    _operationId = opts.operationId,
    _context = context,
    _destinations = destinations,
    _assets = opts.assets,
    _presentation = presentation,
    _terminal = nil,
    _disposed = false,
  }, FlyMapController)
end

---@param key string
---@return boolean
function FlyMapController:_isPermitted(key)
  for _, permitted in ipairs(self._destinations) do
    if permitted == key then
      return true
    end
  end
  return false
end

---@param event table<string, unknown>
function FlyMapController:_handle(event)
  if self._terminal ~= nil then
    return
  end
  if event.type == "cancel" then
    self._terminal = { kind = "cancelled", operationId = self._operationId }
    return
  end
  if event.type ~= "confirm" or self._mode ~= "fly" then
    return
  end
  -- View-only Town mode never reaches this branch, so confirmation there
  -- settles nothing; Fly confirmation past an unknown or missing key
  -- publishes nothing and leaves the pending selection usable.
  local key = event.flypoint
  if type(key) ~= "string" or key == "" or not self:_isPermitted(key) then
    return
  end
  self._terminal = { kind = "destination", operationId = self._operationId, flypointKey = key }
end

-- One fixed tick: confirmation and cancellation settle the single
-- terminal result. A settled selector ignores further input, so repeats
-- never publish a second operation.
---@param events table[]
function FlyMapController:updateFixed(events)
  assert(not self._disposed, "a disposed fly selector steps nothing")
  assert(type(events) == "table", "the fly selector steps an event list")
  for _, event in ipairs(events) do
    if type(event) == "table" and type(event.type) == "string" then
      self:_handle(event --[[@as table<string, unknown>]])
    end
  end
end

-- Reads back the one terminal result, or nil while the selection is
-- live. The result stays readable until the owner disposes the selector.
---@return table<string, unknown>?
function FlyMapController:takeResult()
  return self._terminal
end

---@param key string the semantic flypoint key
---@return table<string, number>? the pane point, or nil when unresolvable
function FlyMapController:_destinationPoint(key)
  local assets = self._assets --[[@as table<string, unknown>]]
  local catalog = assets.catalog
  if type(catalog) ~= "table" then
    return nil
  end
  local flypoints = (catalog --[[@as table<string, unknown>]]).flypoints
  if type(flypoints) ~= "table" then
    return nil
  end
  local known = false
  for _, entry in ipairs(flypoints) do
    if type(entry) == "table" and entry.key == key then
      known = true
      break
    end
  end
  if not known then
    return nil
  end
  local locations = (catalog --[[@as table<string, unknown>]]).locations
  if type(locations) ~= "table" then
    return nil
  end
  for _, entry in ipairs(locations) do
    if type(entry) == "table" and entry.flypoint == key then
      local ok, cell = pcall(MapProjection.contextCell, {
        matrixX = type(entry.matrix) == "table" and entry.matrix.x or nil,
        matrixY = type(entry.matrix) == "table" and entry.matrix.y or nil,
        explicitX = type(entry.explicitX) == "number" and entry.explicitX or nil,
        explicitY = type(entry.explicitY) == "number" and entry.explicitY or nil,
        lastExterior = nil,
        specialSpawn = nil,
        special = type(entry.special) == "string" and entry.special or nil,
      })
      if ok and type(cell) == "table" then
        return MapProjection.markerPoint(
          cell --[[@as table<string, integer>]],
          self:_pan(),
          MapProjection.ZOOM_OUT,
          LOCAL_PANE
        )
      end
      return nil
    end
  end
  return nil
end

---@return table<string, number>
function FlyMapController:_pan()
  return { x = 0, y = 0 }
end

-- Resolves the content image paths behind the Fly section, tolerating
-- companion fixtures that carry one shared plane: named roles win, then
-- the first collected plane. Absent visuals resolve to an empty content
-- record the renderer paints procedurally.
---@return table<string, unknown>
function FlyMapController:_contentPaths()
  local assets = self._assets --[[@as table<string, unknown>]]
  local section = assets.fly
  if type(section) ~= "table" then
    return {}
  end
  local record = section --[[@as table<string, unknown>]]
  local planes = {}
  collectImages(record, planes)
  local background = imageOf(record.base) or imageOf(record.foreground) or planes[1]
  local content = { planes = planes }
  if background ~= nil then
    content.background = background
  end
  return content
end

-- The presentation snapshot: the mode, the detached destination markers
-- with their semantic keys, the confirmation control in Fly mode only,
-- and the resolved content. Fresh tables per call; status performs no
-- mutation. The view exposes no tab strip and no marking controls.
---@return table<string, unknown>
function FlyMapController:status()
  local markers = {}
  for _, key in ipairs(self._destinations) do
    local marker = { key = key }
    local point = self:_destinationPoint(key)
    if point ~= nil then
      marker.point = { x = point.x, y = point.y }
    end
    markers[#markers + 1] = marker
  end
  local context = self._context --[[@as table<string, unknown>]]
  local view = {
    markers = markers,
    content = self:_contentPaths(),
    pan = self:_pan(),
    zoomCells = MapProjection.ZOOM_OUT,
    region = context.region,
    locationKey = context.location,
  }
  if self._mode == "fly" then
    view.confirmButton = copyRect(CONFIRM_BUTTON)
  end
  return {
    open = true,
    mode = self._mode,
    busy = false,
    dismissible = true,
    view = view,
  }
end

-- Idempotent release of the logical lifetime: drops nothing committed
-- because the selector owns only its terminal choice.
function FlyMapController:dispose()
  self._disposed = true
end

return FlyMapController
