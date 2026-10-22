-- Owns one overlay 118 background-scroll transition task.
--
-- The native callback is a pure background effect with no sprites at all: a
-- nine-phase task re-inits two background layers from inline templates,
-- parks their scrolls, waits on the shared cover sub-runner, then steps an
-- eased interpolator that live-applies both scrolls, snaps them through a
-- counted repeat, and tears down. There is no palette fade and no brightness
-- call anywhere in the path; the frame carries no fade keys, and that
-- absence is the distinguishing vector.

local Overlay118Effect = {}
Overlay118Effect.__index = Overlay118Effect

-- Shared cover sub-runner arm counts. These are the helper's own setup
-- counts, not per-site cover durations, so no site timing is asserted here.
local COVER_ARM_COUNT = 8
local COVER_REVERSE_COUNT = 3

-- Raw eased-interpolator setup words. Reported raw, never converted: the
-- visual speed depends on the fixed-point contract, so the words are
-- carried, not mapped to pixels per frame.
local SCROLL_ARM_DURATION = 0x12

-- Raw repeat bound from the pinned snap state.
local SCROLL_REPEAT_COUNT = 5

-- Pinned scroll parks. BG1 parks at its origin row, BG3 at its scanline row,
-- and the second snap moves BG3 to the doubled row.
local PARK_BG1 = { x = 0, y = 0x80 }
local PARK_BG3 = { x = 0, y = 0xFD }
local SNAP_BG1 = { x = 0, y = 0 }
local SNAP_BG3 = { x = 0, y = 0x3 * 0x80 }

---@param route table<string, unknown> source-normalized route
---@param resources table<string, unknown> decoded route resources
---@return table<string, unknown>
function Overlay118Effect.new(route, resources)
  assert(type(route) == "table" and type(resources) == "table", "overlay 118 requires its selected route and resources")
  assert(route.role == "background-transition", "overlay 118 family accepts its background-scroll role")
  local group =
    assert(route.assetGroups and route.assetGroups.background, "overlay 118 route selects its transition background")
  assert(type(resources[group.palette]) == "table", "transition background palette is loaded")
  assert(type(resources[group.character]) == "table", "transition background characters are loaded")
  assert(type(resources[group.map]) == "table", "transition background map is loaded")
  return setmetatable({
    _route = route,
    _resources = resources,
    _sourcePhase = 0,
    _coverWait = nil,
    _backgroundScroll = { bg1 = { x = 0, y = 0 }, bg3 = { x = 0, y = 0 } },
    _scroll = nil,
    _repeatCount = 0,
    _planesEnabled = false,
    _disposed = false,
    _started = false,
  }, Overlay118Effect)
end

function Overlay118Effect:start()
  assert(not self._started, "overlay 118 source task starts exactly once")
  self._started = true
end

---@return boolean complete when the native task has released its resources
function Overlay118Effect:stepSourceTick()
  assert(not self._disposed, "disposed overlay 118 task cannot advance")
  assert(self._started, "overlay 118 source task advances after start")
  local phase = self._sourcePhase
  if phase == 0 then
    self._planesEnabled = true
    self._backgroundScroll = {
      bg1 = { x = PARK_BG1.x, y = PARK_BG1.y },
      bg3 = { x = PARK_BG3.x, y = PARK_BG3.y },
    }
    self._sourcePhase = 1
  elseif phase == 1 then
    self._coverWait = { stage = 0, tick = 0 }
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
    self._scroll = { frame = 0, duration = SCROLL_ARM_DURATION }
    self._sourcePhase = 4
  elseif phase == 4 then
    local scroll = assert(self._scroll)
    scroll.frame = math.min(scroll.frame + 1, scroll.duration)
    self:_applyScroll(scroll.frame / scroll.duration)
    if scroll.frame >= scroll.duration then
      self._sourcePhase = 5
    end
  elseif phase == 5 then
    self._backgroundScroll = {
      bg1 = { x = SNAP_BG1.x, y = SNAP_BG1.y },
      bg3 = { x = SNAP_BG3.x, y = SNAP_BG3.y },
    }
    self._repeatCount = self._repeatCount + 1
    if self._repeatCount >= SCROLL_REPEAT_COUNT then
      -- The counted first scroll is done; a fresh second scroll arms for
      -- the following state.
      self._scroll = { frame = 0, duration = SCROLL_ARM_DURATION }
      self._sourcePhase = 6
    else
      self._scroll = { frame = 0, duration = SCROLL_ARM_DURATION }
      self._sourcePhase = 4
    end
  elseif phase == 6 then
    local scroll = assert(self._scroll)
    scroll.frame = math.min(scroll.frame + 1, scroll.duration)
    self:_applyScroll(scroll.frame / scroll.duration)
    if scroll.frame >= scroll.duration then
      self._sourcePhase = 7
    end
  elseif phase == 7 then
    -- Single-tick host settle; the native state body past the second scroll
    -- handoff is not decoded.
    self._sourcePhase = 8
  elseif phase == 8 then
    self:dispose()
    return true
  else
    error("overlay 118 source task entered an unknown phase")
  end
  return false
end

---@param progress number eased scroll progress from zero to one
function Overlay118Effect:_applyScroll(progress)
  local span1 = SNAP_BG1.y - PARK_BG1.y
  local span3 = SNAP_BG3.y - PARK_BG3.y
  self._backgroundScroll = {
    bg1 = { x = PARK_BG1.x, y = math.floor(PARK_BG1.y + span1 * progress + 0.5) },
    bg3 = { x = PARK_BG3.x, y = math.floor(PARK_BG3.y + span3 * progress + 0.5) },
  }
end

---@return table<string, unknown> current source task outputs for the native compositor
function Overlay118Effect:frame()
  assert(not self._disposed, "disposed overlay 118 task has no frame")
  return {
    sourcePhase = self._sourcePhase,
    routeKey = self._route.key,
    family = "kimono",
    backgroundScroll = self._backgroundScroll,
    scrollArm = self._scroll,
    scrollDuration = SCROLL_ARM_DURATION,
    repeatCount = self._repeatCount,
    repeatBound = SCROLL_REPEAT_COUNT,
    planesEnabled = self._planesEnabled,
    coverWait = self._coverWait,
    -- The native path draws no field layers per tick: the effect owns only
    -- background registers, so no recapture is requested.
    requiresCurrentFieldLayers = false,
    ownsResources = not self._disposed and self._resources ~= nil,
  }
end

function Overlay118Effect:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  self._resources = nil
  self._coverWait = nil
  self._scroll = nil
end

return Overlay118Effect
