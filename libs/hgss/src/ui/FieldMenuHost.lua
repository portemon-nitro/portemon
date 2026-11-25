-- FieldMenuHost owns the live field-menu presentation snapshot. It translates
-- physical UI events through the current layout without giving layout or draw
-- code any authority over script results.

local MenuLayout = require("libs.hgss.src.ui.MenuLayout")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

---@class FieldMenuHost.Active
---@field definition FieldMenuController.Spec
---@field selectedIndex integer
---@field layout table<string, unknown>?
---@field closingAtTick integer?
---@field pointerId string?
---@field pointerDrag { y: number, remainder: number }?
---@field pointerCancels boolean?

---@class FieldMenuHost
---@field private _input FieldInput
---@field private _topology ScreenTopology
---@field private _topologyFollowsViewport boolean
---@field private _measureText fun(text: string): number
---@field private _presentation (fun(): { bounds: ScreenTopology.Rectangle, preferredScale: integer })?
---@field private _active FieldMenuHost.Active?
---@field private _resolved table<string, unknown>? the geometry cached for the active menu
local FieldMenuHost = {}
FieldMenuHost.__index = FieldMenuHost

---@class FieldMenuHost.Options
---@field width number
---@field height number
---@field input FieldInput
---@field screenTopology ScreenTopology?
---@field measureText fun(text: string): number
---@field presentation (fun(): { bounds: ScreenTopology.Rectangle, preferredScale: integer })? central 4:3 field UI region

local function contains(rect, x, y)
  return x >= rect.x and y >= rect.y and x < rect.x + rect.width and y < rect.y + rect.height
end

-- Maps a host point into the layout's reference space.
local function toLogical(layout, x, y)
  local placement = layout.placement
  return (x - placement.origin.x) / placement.scale, (y - placement.origin.y) / placement.scale
end

local function itemAt(layout, x, y)
  x, y = toLogical(layout, x, y)
  if not contains(layout.scrollViewport, x, y) then
    return nil
  end
  for itemIndex = 0, layout.itemCount - 1 do
    local rect = layout.itemRects[itemIndex]
    if contains(rect, x, y) then
      return itemIndex
    end
  end
  return nil
end

---@param width number
---@param height number
---@return ScreenTopology
local function topology(width, height)
  return ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    touch = false,
    role = "world",
  })
end

---@param opts FieldMenuHost.Options
---@return FieldMenuHost
function FieldMenuHost.new(opts)
  assert(type(opts) == "table" and opts.input, "field menu host requires input")
  assert(type(opts.width) == "number" and opts.width > 0, "field menu host requires positive width")
  assert(type(opts.height) == "number" and opts.height > 0, "field menu host requires positive height")
  assert(type(opts.measureText) == "function", "field menu host requires presentation text measurement")
  assert(
    opts.presentation == nil or type(opts.presentation) == "function",
    "field menu presentation context must be a function"
  )
  if opts.screenTopology ~= nil then
    assert(
      type(opts.screenTopology) == "table" and type(opts.screenTopology.surfaces) == "table",
      "field menu topology is invalid"
    )
  end
  return setmetatable({
    _input = opts.input,
    _topology = opts.screenTopology or topology(opts.width, opts.height),
    _topologyFollowsViewport = opts.screenTopology == nil,
    _measureText = opts.measureText,
    _presentation = opts.presentation,
    _active = nil,
    _resolved = nil,
  }, FieldMenuHost)
end

function FieldMenuHost:resize(width, height)
  assert(type(width) == "number" and width > 0, "field menu width must be positive")
  assert(type(height) == "number" and height > 0, "field menu height must be positive")
  if self._topologyFollowsViewport then
    self._topology = topology(width, height)
  end
  if self._active then
    self:_resolve(self._active.definition, self._active.selectedIndex)
  end
end

---@param screenTopology ScreenTopology
function FieldMenuHost:setScreenTopology(screenTopology)
  assert(type(screenTopology) == "table" and type(screenTopology.surfaces) == "table", "field menu topology is invalid")
  self._topology = screenTopology
  self._topologyFollowsViewport = false
  if self._active then
    self:_resolve(self._active.definition, self._active.selectedIndex)
  end
end

-- The resolved geometry is one immutable table: pointer hit-testing, drawing,
-- and callers that observe snapshot layout identity keep the same geometry for
-- as long as the frozen menu definition, the selected row and the presentation
-- context it was resolved against stay the same.
---@param definition FieldMenuController.Spec
---@param selectedIndex integer
function FieldMenuHost:_resolve(definition, selectedIndex)
  local context = self._presentation and self._presentation() or {}
  local bounds = context.bounds
  local cached = self._resolved
  if
    cached ~= nil
    and cached.definition == definition
    and cached.selectedIndex == selectedIndex
    and cached.topology == self._topology
    and cached.preferredScale == context.preferredScale
    and cached.boundsX == (bounds and bounds.x)
    and cached.boundsY == (bounds and bounds.y)
    and cached.boundsWidth == (bounds and bounds.width)
    and cached.boundsHeight == (bounds and bounds.height)
  then
    self._active.layout = cached.layout
    return
  end
  local layout = MenuLayout.resolve({
    topology = self._topology,
    menu = {
      kind = definition.kind,
      tileX = definition.tileX,
      tileY = definition.tileY,
      anchorRight = definition.anchorRight,
      items = definition.items,
      selectedIndex = selectedIndex,
      cancellable = definition.cancellable,
    },
    bounds = bounds,
    preferredScale = context.preferredScale,
    measureText = self._measureText,
  })
  self._resolved = {
    definition = definition,
    selectedIndex = selectedIndex,
    topology = self._topology,
    preferredScale = context.preferredScale,
    boundsX = bounds and bounds.x,
    boundsY = bounds and bounds.y,
    boundsWidth = bounds and bounds.width,
    boundsHeight = bounds and bounds.height,
    layout = layout,
  }
  self._active.layout = layout
end

-- MenuTask calls sync after each controller step. The host acquires logical
-- UI focus exactly once and drops any edge that existed before that focus.
function FieldMenuHost:sync(state, tick)
  assert(type(state) == "table" and type(state.menuDefinition) == "table", "menu state is required")
  if self._active == nil then
    self._active = {
      definition = state.menuDefinition,
      selectedIndex = state.selectedIndex,
      pointerId = nil,
      pointerDrag = nil,
      pointerCancels = false,
    }
    self._input:beginUi(tick)
  end
  self._active.selectedIndex = state.selectedIndex
  self:_resolve(self._active.definition, state.selectedIndex)
end

function FieldMenuHost:close(tick)
  if self._active == nil then
    return
  end
  assert(type(tick) == "number" and tick == math.floor(tick), "menu close tick is required")
  self._active.closingAtTick = tick
  self._input:clearUi()
end

-- The scheduler publishes a completed task result on the following tick.
-- Keep the closing snapshot through that boundary so observing a closed menu
-- always also observes its result, without changing scheduler task timing.
function FieldMenuHost:advance(tick)
  if self._active and self._active.closingAtTick and tick > self._active.closingAtTick then
    self._active = nil
  end
end

---@return boolean
function FieldMenuHost:isModal()
  return self._active ~= nil and self._active.closingAtTick == nil
end

-- The renderer receives a value snapshot instead of reaching into the host's
-- private live state. The task remains the only owner of menu interaction.
---@return { status: { selectedIndex: integer }, layout: table<string, unknown> }|nil
function FieldMenuHost:presentation()
  if not self:isModal() then
    return nil
  end
  local active = assert(self._active, "modal menu requires active state")
  return {
    status = { selectedIndex = active.selectedIndex },
    layout = assert(active.layout, "active menu layout is missing"),
  }
end

---@param events table[]
---@return table[]
function FieldMenuHost:inputEvents(events)
  assert(type(events) == "table", "menu UI events are required")
  local active = self._active
  if active == nil then
    return {}
  end
  local layout = assert(active.layout, "active menu layout is missing")
  local translated = {}
  local selectedIndex = active.selectedIndex
  for _, event in ipairs(events) do
    if event.type == "pointer_move" then
      local pointerId = event.pointerId or "default"
      if active.pointerId == nil or active.pointerId == pointerId then
        local drag = active.pointerDrag
        if drag then
          local rowHeight = assert(layout.itemRects[0], "menu layout needs an item row").height
          local _, pointerY = toLogical(layout, event.x, event.y)
          drag.remainder = drag.remainder + drag.y - pointerY
          drag.y = pointerY
          while math.abs(drag.remainder) >= rowHeight / 2 do
            local direction = drag.remainder > 0 and "down" or "up"
            local itemIndex = MenuLayout.adjacentItem(layout, selectedIndex, direction)
            if itemIndex == nil then
              drag.remainder = 0
              break
            end
            translated[#translated + 1] = { type = "focus", itemIndex = itemIndex }
            selectedIndex = itemIndex
            drag.remainder = drag.remainder - (drag.remainder > 0 and rowHeight / 2 or -rowHeight / 2)
          end
        else
          local itemIndex = itemAt(layout, event.x, event.y)
          translated[#translated + 1] = { type = "pointer_move", itemIndex = itemIndex }
          selectedIndex = itemIndex or selectedIndex
        end
      end
    elseif event.type == "pointer_down" then
      if active.pointerId == nil then
        active.pointerId = event.pointerId or "default"
        local logicalX, logicalY = toLogical(layout, event.x, event.y)
        if layout.cancelRect and contains(layout.cancelRect, logicalX, logicalY) then
          active.pointerCancels = true
          translated[#translated + 1] = { type = "pointer_down", itemIndex = nil }
        else
          active.pointerDrag = { y = logicalY, remainder = 0 }
          translated[#translated + 1] = { type = "pointer_down", itemIndex = itemAt(layout, event.x, event.y) }
        end
      end
    elseif event.type == "pointer_up" then
      local pointerId = event.pointerId or "default"
      if active.pointerId == pointerId then
        active.pointerId = nil
        active.pointerDrag = nil
        if active.pointerCancels then
          active.pointerCancels = false
          local logicalX, logicalY = toLogical(layout, event.x, event.y)
          if not event.dragged and layout.cancelRect and contains(layout.cancelRect, logicalX, logicalY) then
            translated[#translated + 1] = { type = "cancel" }
          else
            translated[#translated + 1] = { type = "pointer_up", itemIndex = nil, dragged = true }
          end
        else
          translated[#translated + 1] = {
            type = "pointer_up",
            itemIndex = itemAt(layout, event.x, event.y),
            dragged = event.dragged == true,
          }
        end
      end
    elseif event.type == "pointer_scroll" then
      local direction = event.dy > 0 and "up" or event.dy < 0 and "down" or nil
      local itemIndex = direction and MenuLayout.adjacentItem(layout, selectedIndex, direction)
      if itemIndex ~= nil then
        translated[#translated + 1] = { type = "focus", itemIndex = itemIndex }
        selectedIndex = itemIndex
      end
    elseif event.type == "navigate" then
      local itemIndex = MenuLayout.adjacentItem(layout, selectedIndex, event.direction)
      if itemIndex ~= nil then
        translated[#translated + 1] = { type = "focus", itemIndex = itemIndex }
        selectedIndex = itemIndex
      end
    else
      translated[#translated + 1] = event
    end
  end
  return translated
end

-- This is semantic presentation state for non-rendering hosts, in host
-- coordinates. Closed menus deliberately expose no geometry, so no stale
-- surface state survives.
---@return table<string, unknown>
function FieldMenuHost:snapshot()
  -- A menu that already committed its result is no longer modal: the retained
  -- closing snapshot keeps the result observable on the following tick without
  -- presenting a menu the field has finished with.
  if not self:isModal() then
    return { modal = false }
  end
  local layout = assert(self._active.layout, "active menu layout is missing")
  local placement = layout.placement
  local itemRects = {}
  for itemIndex = 0, layout.itemCount - 1 do
    local rect = layout.itemRects[itemIndex]
    itemRects[itemIndex] = {
      x = placement.origin.x + rect.x * placement.scale,
      y = placement.origin.y + rect.y * placement.scale,
      width = rect.width * placement.scale,
      height = rect.height * placement.scale,
    }
  end
  return { modal = true, itemRects = itemRects, layout = layout }
end

return FieldMenuHost
