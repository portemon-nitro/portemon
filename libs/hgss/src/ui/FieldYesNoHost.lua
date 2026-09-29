-- Live field Yes/No presentation host. It owns the reconstructable choice
-- geometry shared by fixed-tick pointer mapping and draw, plus the modal
-- input lifetime and physical-to-semantic event translation. Script result
-- semantics stay with the choice controller and its task; this host never
-- owns a result.

local FieldDialogueTheme = require("libs.hgss.src.ui.FieldDialogueTheme")
local NativeDisplay = require("libs.ui.src.NativeDisplay")

---@class FieldYesNoHost.Active
---@field yesText string
---@field noText string
---@field frameIndex integer?
---@field selectedIndex integer
---@field pointerId string?
---@field pressRow integer?

---@class FieldYesNoHost.PresentationContext
---@field topology table<string, unknown>
---@field bounds { x: number, y: number, width: number, height: number }
---@field dialogueBox { x: number, y: number, width: number, height: number }?
---@field preferredScale integer

---@class FieldYesNoHost
---@field private _input FieldInput
---@field private _topology table<string, unknown>
---@field private _topologyFollowsViewport boolean
---@field private _measureText fun(text: string): number
---@field private _presentation (fun(): FieldYesNoHost.PresentationContext)?
---@field private _viewportWidth number
---@field private _viewportHeight number
---@field private _active FieldYesNoHost.Active?
local FieldYesNoHost = {}
FieldYesNoHost.__index = FieldYesNoHost

---@class FieldYesNoHost.Options
---@field width number
---@field height number
---@field input FieldInput
---@field screenTopology table<string, unknown>?
---@field measureText fun(text: string): number
---@field presentation (fun(): FieldYesNoHost.PresentationContext)?

-- Source dual-display geometry: the native 48x32 choice body on the
-- 256x192 reference canvas. Adapted single-display bodies keep the source
-- two-row height while their width follows the measured labels.
local NATIVE_CONTENT = { x = 25 * 8, y = 13 * 8, width = 6 * 8, height = 4 * 8 }
local REFERENCE = { width = NativeDisplay.WIDTH, height = NativeDisplay.HEIGHT }
local ROW_HEIGHT = 16
local LABEL_X = 8
local TRAILING_X = 8

local function surfaceFor(topology)
  assert(type(topology) == "table" and type(topology.surfaces) == "table", "choice layout requires a screen topology")
  for _, surface in ipairs(topology.surfaces) do
    if surface.role == "auxiliary" then
      return surface
    end
  end
  return assert(topology.surfaces[1], "choice layout requires a display surface")
end

---@param topology table<string, unknown>?
---@param width number
---@param height number
---@return table<string, unknown>
local function fallbackTopology(topology, width, height)
  if topology ~= nil then
    assert(type(topology) == "table" and type(topology.surfaces) == "table", "choice topology is invalid")
    return topology
  end
  return {
    surfaces = {
      {
        id = "main",
        rect = { x = 0, y = 0, width = width, height = height },
        touch = false,
        role = "world",
      },
    },
  }
end

---@param contentWidth number
---@return { x: number, y: number, width: number, height: number }
local function adaptedFrameBounds(contentWidth)
  local minX, minY = 0, 0
  local maxX, maxY = contentWidth, NATIVE_CONTENT.height
  for _, tile in
    ipairs(
      FieldDialogueTheme.frameTilePlacements({ x = 0, y = 0, width = contentWidth, height = NATIVE_CONTENT.height })
    )
  do
    minX = math.min(minX, tile.x)
    minY = math.min(minY, tile.y)
    maxX = math.max(maxX, tile.x + FieldDialogueTheme.frameTileSize * (tile.spanX or 1))
    maxY = math.max(maxY, tile.y + FieldDialogueTheme.frameTileSize * (tile.spanY or 1))
  end
  return { x = minX, y = minY, width = maxX - minX, height = maxY - minY }
end

---@return FieldYesNoHost.PresentationContext
function FieldYesNoHost:_context()
  if self._presentation ~= nil then
    local resolved = self._presentation()
    assert(type(resolved) == "table", "choice presentation context is required")
    return resolved
  end
  return {
    topology = self._topology,
    bounds = {
      x = 0,
      y = 0,
      width = self._viewportWidth,
      height = self._viewportHeight,
    },
    dialogueBox = nil,
    preferredScale = 1,
  }
end

---@param opts FieldYesNoHost.Options
---@return FieldYesNoHost
function FieldYesNoHost.new(opts)
  assert(type(opts) == "table" and opts.input, "choice host requires input")
  assert(type(opts.width) == "number" and opts.width > 0, "choice host requires positive width")
  assert(type(opts.height) == "number" and opts.height > 0, "choice host requires positive height")
  assert(type(opts.measureText) == "function", "choice host requires presentation text measurement")
  if opts.presentation ~= nil then
    assert(type(opts.presentation) == "function", "choice presentation context must be a function")
  end
  return setmetatable({
    _input = opts.input,
    _topology = fallbackTopology(opts.screenTopology, opts.width, opts.height),
    _topologyFollowsViewport = opts.screenTopology == nil,
    _measureText = opts.measureText,
    _presentation = opts.presentation,
    _viewportWidth = opts.width,
    _viewportHeight = opts.height,
    _active = nil,
  }, FieldYesNoHost)
end

function FieldYesNoHost:resize(width, height)
  assert(type(width) == "number" and width > 0, "choice width must be positive")
  assert(type(height) == "number" and height > 0, "choice height must be positive")
  self._viewportWidth = width
  self._viewportHeight = height
  if self._topologyFollowsViewport then
    self._topology = fallbackTopology(nil, width, height)
  end
  -- A resize invalidates the geometry a held gesture started in.
  if self._active then
    self._active.pointerId = nil
    self._active.pressRow = nil
  end
end

---@param screenTopology table<string, unknown>
function FieldYesNoHost:setScreenTopology(screenTopology)
  assert(type(screenTopology) == "table" and type(screenTopology.surfaces) == "table", "choice topology is invalid")
  self._topology = screenTopology
  self._topologyFollowsViewport = false
  -- A topology change invalidates the geometry a held gesture started in.
  if self._active then
    self._active.pointerId = nil
    self._active.pressRow = nil
  end
end

-- Replaces reconstructable presentation metrics. The active geometry is
-- resolved on demand, so only a held gesture needs invalidation.
---@param measureText fun(text: string): number
function FieldYesNoHost:setPresentationMetrics(measureText)
  assert(type(measureText) == "function", "choice presentation requires text measurement")
  self._measureText = measureText
  if self._active then
    self._active.pointerId = nil
    self._active.pressRow = nil
  end
end

---@param yesText string
---@param noText string
---@return integer adapted body width
function FieldYesNoHost:_adaptedContentWidth(yesText, noText)
  local widest = math.max(self._measureText(yesText), self._measureText(noText))
  local raw = LABEL_X + widest + TRAILING_X
  local aligned = math.ceil(raw / FieldDialogueTheme.frameTileSize) * FieldDialogueTheme.frameTileSize
  return math.min(NATIVE_CONTENT.width, aligned)
end

---@param yesText string
---@param noText string
---@param resolved FieldYesNoHost.PresentationContext
---@return table<string, unknown> layout
function FieldYesNoHost:_resolve(yesText, noText, resolved)
  local topology = assert(resolved.topology, "choice layout requires a screen topology")
  local surface = surfaceFor(topology)
  local safe = assert(surface.safeRect or surface.rect)
  if
    surface.role == "auxiliary"
    and surface.rect.width >= REFERENCE.width
    and surface.rect.height >= REFERENCE.height
  then
    local scale = math.min(safe.width / REFERENCE.width, safe.height / REFERENCE.height)
    assert(scale > 0, "choice source presentation requires a positive scale")
    local originX = safe.x + (safe.width - REFERENCE.width * scale) / 2
    local originY = safe.y + (safe.height - REFERENCE.height * scale) / 2
    return {
      surface = surface,
      presentation = "source",
      content = NATIVE_CONTENT,
      placement = {
        frame = { x = originX, y = originY, width = REFERENCE.width * scale, height = REFERENCE.height * scale },
        origin = { x = originX, y = originY },
        scale = scale,
        clipRect = safe,
      },
    }
  end

  local bounds = assert(resolved.bounds, "adapted choice layout requires field UI bounds")
  assert(
    type(bounds.x) == "number"
      and type(bounds.y) == "number"
      and type(bounds.width) == "number"
      and type(bounds.height) == "number"
      and bounds.width > 0
      and bounds.height > 0,
    "adapted choice layout requires positive field UI bounds"
  )
  local preferredScale = resolved.preferredScale
  assert(
    type(preferredScale) == "number" and preferredScale > 0 and preferredScale == math.floor(preferredScale),
    "adapted choice layout requires a positive integer preferred scale"
  )
  local contentWidth = self:_adaptedContentWidth(yesText, noText)
  local outer = adaptedFrameBounds(contentWidth)
  local hostFit = math.min(bounds.width / outer.width, bounds.height / outer.height)
  local scale
  if hostFit >= 1 then
    scale = math.min(preferredScale, math.floor(hostFit))
  else
    scale = hostFit
  end
  assert(scale > 0, "choice adapted presentation requires a positive scale")
  local width = outer.width * scale
  local height = outer.height * scale
  local hostFrame =
    { x = bounds.x + bounds.width - width, y = bounds.y + bounds.height - height, width = width, height = height }
  local dialogueBox = resolved.dialogueBox
  if dialogueBox then
    local dialogueRight = dialogueBox.x + dialogueBox.width
    local fitAbove = math.min((dialogueRight - bounds.x) / outer.width, (dialogueBox.y - bounds.y) / (outer.height + 2))
    if fitAbove > 0 then
      local fitScale = fitAbove >= 1 and math.floor(fitAbove) or fitAbove
      scale = math.min(scale, fitScale)
      width = outer.width * scale
      height = outer.height * scale
      hostFrame = {
        x = dialogueRight - width,
        y = dialogueBox.y - 2 * scale - height,
        width = width,
        height = height,
      }
      hostFrame.x = math.max(bounds.x, math.min(hostFrame.x, bounds.x + bounds.width - width))
      hostFrame.y = math.max(bounds.y, math.min(hostFrame.y, bounds.y + bounds.height - height))
    end
  end
  local function fits(rect)
    return rect.x >= bounds.x
      and rect.y >= bounds.y
      and rect.x + rect.width <= bounds.x + bounds.width
      and rect.y + rect.height <= bounds.y + bounds.height
  end
  assert(fits(hostFrame), "choice frame leaves field UI bounds")
  local hostContentOrigin = {
    x = hostFrame.x - outer.x * scale,
    y = hostFrame.y - outer.y * scale,
  }
  return {
    surface = surface,
    presentation = "adapted",
    content = { x = 0, y = 0, width = contentWidth, height = NATIVE_CONTENT.height },
    placement = {
      frame = hostFrame,
      origin = hostContentOrigin,
      scale = scale,
      clipRect = bounds,
    },
  }
end

---@param layout table<string, unknown>
---@param x number
---@param y number
---@return integer? row
local function rowAt(layout, x, y)
  local content = assert(layout.content, "choice layout must publish its content box")
  local placement = assert(layout.placement, "choice layout must publish its placement")
  local origin = assert(placement.origin, "choice placement must publish its content origin")
  local scale = assert(placement.scale, "choice placement must publish its scale")
  assert(type(scale) == "number" and scale > 0, "choice placement scale must be positive")
  local contentX = (x - origin.x) / scale
  local contentY = (y - origin.y) / scale
  if
    contentX < content.x
    or contentX >= content.x + content.width
    or contentY < content.y
    or contentY >= content.y + NATIVE_CONTENT.height
  then
    return nil
  end
  return math.floor((contentY - content.y) / ROW_HEIGHT)
end

---@param request { yesText: string, noText: string, frameIndex: integer?, selectedIndex: integer? }
---@param tick integer
function FieldYesNoHost:openChoice(request, tick)
  assert(self._active == nil, "choice is already active")
  assert(type(request) == "table", "choice request is required")
  assert(type(request.yesText) == "string" and type(request.noText) == "string", "choice labels are required")
  assert(
    request.frameIndex == nil
      or (type(request.frameIndex) == "number" and request.frameIndex % 1 == 0 and request.frameIndex >= 0),
    "choice frame is invalid"
  )
  local selectedIndex = request.selectedIndex or 0
  assert(selectedIndex == 0 or selectedIndex == 1, "choice selection is outside the two choices")
  assert(type(tick) == "number" and tick == math.floor(tick) and tick >= 0, "choice open tick is required")
  self._active = {
    yesText = request.yesText,
    noText = request.noText,
    frameIndex = request.frameIndex,
    selectedIndex = selectedIndex,
    pointerId = nil,
    pressRow = nil,
  }
  -- One modal lifetime per choice, acquired exactly once at the scheduler
  -- tick boundary; stale edges from before the choice are dropped here.
  self._input:beginUi(tick)
end

---@param selectedIndex integer
function FieldYesNoHost:syncSelection(selectedIndex)
  local active = assert(self._active, "no active choice to sync")
  assert(selectedIndex == 0 or selectedIndex == 1, "choice selection is outside the two choices")
  active.selectedIndex = selectedIndex
end

function FieldYesNoHost:close()
  if self._active == nil then
    return
  end
  self._active = nil
  self._input:clearUi()
end

---@return boolean
function FieldYesNoHost:isModal()
  return self._active ~= nil
end

-- The renderer receives a value snapshot instead of reaching into the
-- host's private live state. Resolved on demand so draw and fixed-tick hit
-- testing consume one geometry.
---@return { status: { active: boolean, selectedIndex: integer, yesText: string, noText: string, frameIndex: integer? }, layout: table<string, unknown> }|nil
function FieldYesNoHost:presentation()
  local active = self._active
  if active == nil then
    return nil
  end
  return {
    status = {
      active = true,
      selectedIndex = active.selectedIndex,
      yesText = active.yesText,
      noText = active.noText,
      frameIndex = active.frameIndex,
    },
    layout = self:_resolve(active.yesText, active.noText, self:_context()),
  }
end

-- Pure layout for a choice the live host does not own (such as a contextual
-- two-choice prompt presented through the same visuals). No lifetime or
-- capture is touched.
---@param status { active: boolean, selectedIndex: integer, yesText: string, noText: string }
---@return table<string, unknown> layout
function FieldYesNoHost:layoutFor(status)
  assert(type(status) == "table" and status.active == true, "choice layout requires an active choice")
  assert(status.selectedIndex == 0 or status.selectedIndex == 1, "choice selection is outside the two choices")
  assert(type(status.yesText) == "string" and type(status.noText) == "string", "choice labels are required")
  return self:_resolve(status.yesText, status.noText, self:_context())
end

---@param events table[]
---@return table[] semantic choice events
function FieldYesNoHost:inputEvents(events)
  assert(type(events) == "table", "choice UI events are required")
  local active = self._active
  if active == nil then
    return {}
  end
  local layout = self:_resolve(active.yesText, active.noText, self:_context())
  local translated = {}
  for _, event in ipairs(events) do
    assert(type(event) == "table" and type(event.type) == "string", "choice UI event is invalid")
    if event.type == "pointer_down" then
      if active.pointerId ~= nil then
        goto continue
      end
      active.pointerId = event.pointerId or "default"
      local row = rowAt(layout, event.x, event.y)
      active.pressRow = row
      if row ~= nil then
        translated[#translated + 1] = { type = "focus", row = row }
      end
    elseif event.type == "pointer_move" then
      local pointerId = event.pointerId or "default"
      if active.pointerId ~= pointerId then
        goto continue
      end
      -- Hover never moves selection; only the press row can confirm.
    elseif event.type == "pointer_up" then
      local pointerId = event.pointerId or "default"
      if active.pointerId ~= pointerId then
        goto continue
      end
      local pressRow = active.pressRow
      active.pointerId = nil
      active.pressRow = nil
      if event.dragged then
        goto continue
      end
      local row = rowAt(layout, event.x, event.y)
      if row ~= nil and pressRow ~= nil and row == pressRow then
        translated[#translated + 1] = { type = "focus", row = row }
        translated[#translated + 1] = { type = "confirm" }
      end
    elseif event.type == "pointer_scroll" then
      -- Two rows need no wheel traversal; the gesture is consumed here so
      -- it can never reach the task as an unknown event.
    elseif event.type == "focus" or event.type == "navigate" or event.type == "confirm" or event.type == "cancel" then
      translated[#translated + 1] = event
    else
      assert(false, "unknown choice UI event " .. event.type)
    end
    ::continue::
  end
  return translated
end

return FieldYesNoHost
