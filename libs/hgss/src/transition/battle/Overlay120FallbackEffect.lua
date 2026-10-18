-- Owns one overlay 120 wild-fallback window/mosaic reveal task.
--
-- The native family runs an eight-phase task: allocate and load the
-- route-selected background set with engine-A planes on, wait on the shared
-- cover sub-runner, then drive the mosaic reveal over the pinned order
-- tables with BG scroll and scanline paths before releasing everything at
-- completion. Day and late routes differ only by polarity, read from the
-- semantic route key; which terrain each worker renders is not decoded, so
-- all three fallback roles share this worker.

local Overlay120FallbackEffect = {}
Overlay120FallbackEffect.__index = Overlay120FallbackEffect

local FALLBACK_ROLES = {
  ["plain-wild-fallback"] = true,
  ["water-wild-fallback"] = true,
  ["cave-wild-fallback"] = true,
}

-- Day routes pass the opening polarity word, late routes the inverted word.
-- The reading comes from three identical call sites, noted as an inference.
local DAY_POLARITY = 0x10
local LATE_POLARITY = -16

-- Shared cover sub-runner arm counts. These are the helper's own setup
-- counts, not per-site cover durations, so no site timing is asserted here.
local COVER_ARM_COUNT = 8
local COVER_REVERSE_COUNT = 3

-- Mosaic order tables hold one entry per reveal step.
local MOSAIC_STEPS = 24

-- Background scanline driver countdown from the pinned BG path.
local SCANLINE_COUNTDOWN = 10

---@param step integer current reveal step
---@return table[] native 256x192 scanline spans sweeping left to right
local function makeSweepRows(step)
  local width = math.floor(256 * step / MOSAIC_STEPS)
  local rows = {}
  for y = 1, 192 do
    if width > 0 then
      rows[y] = { { 0, width } }
    else
      rows[y] = {}
    end
  end
  return rows
end

---@param route table<string, unknown> source-normalized route
---@param resources table<string, unknown> decoded route resources
---@param context table<string, unknown> immutable semantic launch context
---@return table<string, unknown>
function Overlay120FallbackEffect.new(route, resources, context)
  assert(
    type(route) == "table" and type(resources) == "table" and type(context) == "table",
    "overlay 120 fallback requires its selected route, resources, and launch context"
  )
  assert(FALLBACK_ROLES[route.role] == true, "overlay 120 fallback accepts its three semantic wild roles")
  local timeOfDay = context.timeOfDay
  assert(timeOfDay == "day" or timeOfDay == "late", "overlay 120 fallback routes name their source time of day")
  local terrain = context.terrain
  assert(type(terrain) == "string" and terrain ~= "", "overlay 120 fallback routes name their source terrain")
  local polarity = DAY_POLARITY
  if timeOfDay == "late" then
    -- The late reading is a strong inference from three identical call
    -- sites, not an explicit comment in the pinned callback table.
    polarity = LATE_POLARITY
  end
  local sceneAssets =
    assert(route.assetGroups and route.assetGroups.sceneAssets, "overlay 120 fallback route selects its background set")
  assert(type(resources[sceneAssets.palette]) == "table", "fallback background palette is loaded")
  local transitionBackground = assert(sceneAssets.transitionBackground, "fallback transition background is declared")
  assert(type(resources[transitionBackground.palette]) == "table", "transition background palette is loaded")
  return setmetatable({
    _route = route,
    _resources = resources,
    _polarity = polarity,
    _terrain = terrain,
    _timeOfDay = timeOfDay,
    _sourcePhase = 0,
    _coverWait = nil,
    _mosaicStep = 0,
    _wipe = nil,
    _backgroundScroll = { x = 0, y = 0 },
    _scanlineCountdown = 0,
    _whiteFadeAlpha = 0,
    _planesEnabled = false,
    _disposed = false,
    _started = false,
  }, Overlay120FallbackEffect)
end

function Overlay120FallbackEffect:start()
  assert(not self._started, "overlay 120 fallback task starts exactly once")
  self._started = true
end

---@return boolean complete when the native task has released its resources
function Overlay120FallbackEffect:stepSourceTick()
  assert(not self._disposed, "disposed overlay 120 fallback task cannot advance")
  assert(self._started, "overlay 120 fallback task advances after start")
  local phase = self._sourcePhase
  if phase == 0 then
    self._planesEnabled = true
    self._mosaicStep = 0
    self._wipe = { kind = "mosaic-reveal", step = 0, steps = MOSAIC_STEPS, rows = makeSweepRows(0) }
    self._sourcePhase = 1
  elseif phase == 1 then
    self._coverWait = { stage = 0, tick = 0, polarity = self._polarity }
    self._sourcePhase = 2
  elseif phase == 2 then
    local cover = assert(self._coverWait)
    cover.tick = cover.tick + 1
    if cover.stage == 0 and cover.tick >= COVER_ARM_COUNT then
      cover.stage = 1
      cover.tick = 0
    elseif cover.stage == 1 and cover.tick >= COVER_REVERSE_COUNT then
      self._coverWait = nil
      self._sourcePhase = 3
    end
  elseif phase == 3 then
    -- The mosaic stepper advances one order-table step per source tick;
    -- the host-visible sweep follows the step count. Table contents are
    -- data, so only the step bounds are pinned here.
    self._mosaicStep = math.min(self._mosaicStep + 1, MOSAIC_STEPS)
    local wipe = assert(self._wipe)
    wipe.step = self._mosaicStep
    wipe.rows = makeSweepRows(self._mosaicStep)
    self._backgroundScroll = { x = self._polarity * self._mosaicStep, y = 0 }
    if self._mosaicStep >= MOSAIC_STEPS then
      self._scanlineCountdown = SCANLINE_COUNTDOWN
      self._sourcePhase = 4
    end
  elseif phase == 4 then
    self._scanlineCountdown = self._scanlineCountdown - 1
    if self._scanlineCountdown <= 0 then
      self._sourcePhase = 5
    end
  elseif phase == 5 then
    -- Host-visible settle flash standing in for the native palette-fade
    -- layer whose target color is not decoded. The reveal itself is the
    -- mosaic sweep; this flash only marks the completion boundary.
    self._whiteFadeAlpha = 1
    self._sourcePhase = 6
  elseif phase == 6 then
    self._whiteFadeAlpha = 0
    self._sourcePhase = 7
  elseif phase == 7 then
    self:dispose()
    return true
  else
    error("overlay 120 fallback task entered an unknown phase")
  end
  return false
end

---@return table<string, unknown> current source task outputs for the native compositor
function Overlay120FallbackEffect:frame()
  assert(not self._disposed, "disposed overlay 120 fallback task has no frame")
  return {
    sourcePhase = self._sourcePhase,
    routeKey = self._route.key,
    family = "wild-fallback",
    terrain = self._terrain,
    timeOfDay = self._timeOfDay,
    polarity = self._polarity,
    mosaicStep = self._mosaicStep,
    mosaicSteps = MOSAIC_STEPS,
    wipe = self._wipe,
    backgroundScroll = self._backgroundScroll,
    scanlineCountdown = self._scanlineCountdown,
    whiteFadeAlpha = self._whiteFadeAlpha,
    planesEnabled = self._planesEnabled,
    coverWait = self._coverWait,
    requiresCurrentFieldLayers = true,
    ownsResources = not self._disposed and self._resources ~= nil,
  }
end

function Overlay120FallbackEffect:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  self._resources = nil
  self._coverWait = nil
  self._wipe = nil
end

return Overlay120FallbackEffect
