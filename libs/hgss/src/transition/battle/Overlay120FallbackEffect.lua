-- Recreates the row, wave, and diagonal wild encounter effects from
-- pokeheartgold/src/field/encounter_effect_wild.c.

local Overlay120FallbackEffect = {}
Overlay120FallbackEffect.__index = Overlay120FallbackEffect

local TERRAIN_BY_ROLE = {
  ["plain-wild-fallback"] = "plain",
  ["water-wild-fallback"] = "water",
  ["cave-wild-fallback"] = "cave",
}

local GRID_WIDTH = 8
local GRID_CELL = 32
local HALF_CELL = math.floor(GRID_CELL / 2)
local GRID_STEPS = 24
local GRID_GROW_TICKS = 4
local FLASHES = 2
local WAVE_DELAY = 10
local WAVE_AMPLITUDE = 3
local WAVE_STEP = 3410
local WAVE_SPEED = 400
local SINE_INDEX_COUNT = 192
local FULL_TURN = 65536

---@param value number
---@return integer truncation toward zero used by signed source arithmetic
local function trunc(value)
  return value < 0 and math.ceil(value) or math.floor(value)
end

---@param frame integer interpolation frame
---@param start integer starting value
---@param finish integer final value
---@param duration integer update duration
---@return integer source interpolation value
local function interpolate(frame, start, finish, duration)
  return start + trunc((finish - start) * math.min(frame, duration) / duration)
end

---@param index integer zero-based grid cell
---@return integer, integer cell center x and y
local function gridCenter(index)
  return (index % GRID_WIDTH) * GRID_CELL + HALF_CELL, math.floor(index / GRID_WIDTH) * GRID_CELL + HALF_CELL
end

---@param cells table[] started source cells
---@param terrain string encounter terrain
---@return table<integer, table<integer, integer[]>> field-visible horizontal spans by scanline
local function unfilledRows(cells, terrain)
  local rows = {}
  for y = 0, 191 do
    local covered = {}
    for _, cell in ipairs(cells) do
      local centerX, centerY = gridCenter(cell.index)
      local width = interpolate(cell.elapsed, 0, GRID_CELL, GRID_GROW_TICKS)
      local height = terrain == "cave" and interpolate(cell.elapsed, 0, GRID_CELL, GRID_GROW_TICKS) or GRID_CELL
      local top = centerY - math.floor(height / 2)
      if y >= top and y < top + height and width > 0 then
        local left = math.max(0, centerX - math.floor(width / 2))
        local right = math.min(256, left + width)
        if right > left then
          covered[#covered + 1] = { left, right }
        end
      end
    end
    table.sort(covered, function(left, right)
      return left[1] < right[1]
    end)
    local spans = {}
    local left = 0
    for _, span in ipairs(covered) do
      if span[1] > left then
        spans[#spans + 1] = { left, span[1] }
      end
      left = math.max(left, span[2])
    end
    if left < 256 then
      spans[#spans + 1] = { left, 256 }
    end
    rows[y + 1] = spans
  end
  return rows
end

---@param order integer[] source cell indices in task order
---@param field string
local function checkGridOrder(order, field)
  assert(type(order) == "table" and #order == GRID_STEPS, field .. " carries 24 source cell indices")
  local seen = {}
  for _, index in ipairs(order) do
    assert(type(index) == "number" and index % 1 == 0 and index >= 0 and index < 48, field .. " contains a grid cell")
    assert(not seen[index], field .. " contains each grid cell once")
    seen[index] = true
  end
end

---@param route table<string, unknown> source-normalized route
---@param resources table<string, unknown> decoded route resources
---@param context table<string, unknown> immutable semantic launch context
---@return table<string, unknown>
function Overlay120FallbackEffect.new(route, resources, context)
  assert(type(route) == "table" and type(resources) == "table" and type(context) == "table")
  local terrain = TERRAIN_BY_ROLE[route.role]
  assert(terrain ~= nil, "overlay 120 accepts its three wild transition roles")
  assert(context.terrain == terrain, "selected route and captured terrain agree")
  local timeOfDay = context.timeOfDay
  assert(timeOfDay == "day" or timeOfDay == "late", "wild transition routes carry their source time of day")
  local groups = assert(route.assetGroups, "wild transition route carries source asset groups")
  local orderKey = assert(groups.wildCellOrders, "wild transition route stages the retail grid cell orders")
  local orders = assert(resources[orderKey], "wild transition cell orders are loaded for this route")
  checkGridOrder(orders.rows, "row order")
  checkGridOrder(orders.rowsReverse, "reverse row order")
  checkGridOrder(orders.diagonalsA, "diagonal A order")
  checkGridOrder(orders.diagonalsB, "diagonal B order")
  assert(type(groups.sceneAssets) == "table", "wild transition route selects its background assets")
  return setmetatable({
    _route = route,
    _resources = resources,
    _orders = orders,
    _terrain = terrain,
    _timeOfDay = timeOfDay,
    _white = timeOfDay == "day",
    _tick = 0,
    _phase = "setup",
    _flashState = 0,
    _flashFrame = 0,
    _flashCount = 0,
    _flashValue = 0,
    _mosaicStep = 0,
    _sourceCells = {},
    _lastPair = {},
    _waveTick = 0,
    _waveDelay = WAVE_DELAY,
    _bg1ScrollTick = 0,
    _bg3ScrollTick = 0,
    _screenBrightness = 0,
    _wipe = nil,
    _planesEnabled = false,
    _disposed = false,
    _started = false,
  }, Overlay120FallbackEffect)
end

function Overlay120FallbackEffect:start()
  assert(not self._started, "overlay 120 wild task starts once")
  self._started = true
end

---@return boolean complete when the source effect has covered the field
function Overlay120FallbackEffect:stepSourceTick()
  assert(not self._disposed and self._started, "overlay 120 wild task advances while owned")
  self._tick = self._tick + 1
  if self._phase == "setup" then
    self._planesEnabled = true
    self._phase = "flash"
  elseif self._phase == "flash" then
    self:_stepFlash()
  elseif self._phase == "grid-start" then
    self._phase = "grid"
  elseif self._phase == "grid" then
    self:_stepGrid()
    if self._mosaicStep == GRID_STEPS and self:_gridFinished() then
      self._screenBrightness = 0
      self._phase = "complete"
      self:dispose()
      return true
    end
  elseif self._phase == "wave-start" then
    self._phase = "wave"
    self._backgroundScroll = { bg1 = { x = 0, y = 0 }, bg3 = { x = 0, y = 8 } }
    self._scanlineOffsets = self:_waveOffsets()
  elseif self._phase == "wave" then
    if self:_stepWave() then
      self._phase = "complete"
      self:dispose()
      return true
    end
  elseif self._phase == "complete" then
    self:dispose()
    return true
  else
    error("overlay 120 wild task entered an unknown phase")
  end
  return false
end

function Overlay120FallbackEffect:_stepFlash()
  if self._flashState == 0 then
    self._flashState = 1
  elseif self._flashState == 1 then
    self._flashState = 2
    self._flashFrame = 0
  elseif self._flashState == 2 or self._flashState == 4 then
    local rising = self._flashState == 2
    local brightness = rising and interpolate(self._flashFrame, 0, 16, 3) or interpolate(self._flashFrame, 16, 0, 3)
    self._flashValue = self._white and brightness or -brightness
    self._screenBrightness = self._flashValue
    if self._flashFrame == 3 then
      if rising then
        self._flashState = 3
      else
        self._flashCount = self._flashCount + 1
        self._flashState = self._flashCount == FLASHES and 5 or 1
      end
    else
      self._flashFrame = self._flashFrame + 1
    end
  elseif self._flashState == 3 then
    self._flashState = 4
    self._flashFrame = 0
  elseif self._flashState == 5 then
    self._screenBrightness = 0
    self._phase = self._terrain == "water" and "wave-start" or "grid-start"
  else
    error("overlay 120 wild flash entered an unknown task state")
  end
end

function Overlay120FallbackEffect:_stepGrid()
  local step = self._mosaicStep
  for _, cell in ipairs(self._sourceCells) do
    cell.elapsed = math.min(cell.elapsed + 1, GRID_GROW_TICKS)
  end
  self._lastPair = {}
  if step < GRID_STEPS then
    local first
    local second
    if self._terrain == "plain" then
      local order = self._white and self._orders.rowsReverse or self._orders.rows
      first = order[step + 1]
      second = 47 - first
    else
      local a = self._orders.diagonalsA[step + 1]
      local b = self._orders.diagonalsB[step + 1]
      first = self._white and a or 47 - a
      second = self._white and b or 47 - b
    end
    self._lastPair = { first, second }
    self._sourceCells[#self._sourceCells + 1] = { index = first, elapsed = 0 }
    self._sourceCells[#self._sourceCells + 1] = { index = second, elapsed = 0 }
    self._mosaicStep = step + 1
  end
  self._wipe = {
    kind = "mosaic-cover",
    step = self._mosaicStep,
    steps = GRID_STEPS,
    rows = unfilledRows(self._sourceCells, self._terrain),
  }
end

function Overlay120FallbackEffect:_gridFinished()
  for _, cell in ipairs(self._sourceCells) do
    if cell.elapsed < GRID_GROW_TICKS then
      return false
    end
  end
  return true
end

---@return integer[] horizontal source offsets for each native scanline
function Overlay120FallbackEffect:_waveOffsets()
  local offsets = {}
  local phase = trunc(self._waveTick * WAVE_SPEED / 100)
  for line = 0, SINE_INDEX_COUNT - 1 do
    local index = (line + phase) % SINE_INDEX_COUNT
    offsets[line + 1] = trunc(WAVE_AMPLITUDE * math.sin(2 * math.pi * (index * WAVE_STEP % FULL_TURN) / FULL_TURN))
  end
  return offsets
end

function Overlay120FallbackEffect:_stepWave()
  if self._waveDelay > 0 then
    self._waveDelay = self._waveDelay - 1
  else
    self._bg1ScrollTick = math.min(self._bg1ScrollTick + 1, 19)
  end
  self._bg3ScrollTick = math.min(self._bg3ScrollTick + 1, 31)
  self._waveTick = self._waveTick + 1
  self._backgroundScroll = {
    bg1 = { x = 0, y = interpolate(math.max(self._bg1ScrollTick - 1, 0), 0, 320, 18) },
    bg3 = {
      x = trunc(16 * math.sin(math.rad((self._bg3ScrollTick - 1) * 15))),
      y = interpolate(math.max(self._bg3ScrollTick - 1, 0), 8, 328, 30),
    },
  }
  self._scanlineOffsets = self:_waveOffsets()
  if self._bg1ScrollTick >= 19 then
    self._screenBrightness = 0
    return true
  end
  return false
end

---@return table<string, unknown> current field compositor operations
function Overlay120FallbackEffect:frame()
  assert(not self._disposed, "disposed overlay 120 task has no frame")
  return {
    sourcePhase = self._phase,
    routeKey = self._route.key,
    family = self._terrain == "water" and "wild-wave" or "wild-cell-grid",
    terrain = self._terrain,
    timeOfDay = self._timeOfDay,
    sourceWhite = self._white,
    mosaicStep = self._mosaicStep,
    mosaicSteps = GRID_STEPS,
    sourceCells = self._lastPair,
    wipe = self._wipe,
    screenBrightness = self._screenBrightness,
    backgroundScroll = self._backgroundScroll,
    scanlineOffsets = self._scanlineOffsets,
    planesEnabled = self._planesEnabled,
    requiresCurrentFieldLayers = true,
    ownsResources = self._resources ~= nil,
  }
end

function Overlay120FallbackEffect:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  self._resources = nil
  self._orders = nil
  self._sourceCells = {}
  self._wipe = nil
  self._scanlineOffsets = nil
end

return Overlay120FallbackEffect
