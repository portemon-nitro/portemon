-- The per-open Start Menu wrapper: the existing gameplay controller beside
-- one presentation session, mirroring the Bag/Party wrapper pattern. Each
-- tick resolves a complete plan against fresh display facts, maps one
-- ordered batch, advances the controller once, then resolves again for the
-- resulting snapshot without advancing semantic clocks. Geometry lives in
-- the session, never in the host. Construction is failure-safe: a failed
-- session or controller releases whatever the open acquired.

local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local StartMenuController = require("libs.hgss.src.ui.StartMenuController")
local StartMenuInterface = require("game.hgss.src.field.StartMenuInterface")

---@class StartMenuState
---@field _controller StartMenuController the existing selection/action/result owner
---@field _session ApplicationPresentation the per-open presentation session
---@field _measureDisplay fun(): DisplayMeasurement the live display facts
---@field _cursorAnimation StartMenuState.CursorAnimation the generated retail cursor sequence
---@field _fixedTick integer number of fixed updates since the menu opened
---@field _disposed boolean
local StartMenuState = {}
StartMenuState.__index = StartMenuState

---@class StartMenuState.Options
---@field entries StartMenuController.Entry[] the runtime-composed final interactive action list
---@field interactive StartMenuController.Interactive the generated manifest interactive record
---@field cursorAnimation StartMenuState.CursorAnimation the generated cursor art and sequence timing
---@field rememberedActionId string? selection remembered across a child-application round trip
---@field effect (fun(sequence: string))? source UI sound effect boundary
---@field runningShoes StartMenuController.RunningShoes the Running Shoes toggle port
---@field measureDisplay fun(): DisplayMeasurement the current display facts
---@field overrides table<string, unknown>? per-case function overrides for this application

---@class StartMenuState.CursorFrame
---@field x integer atlas x
---@field y integer atlas y
---@field width integer
---@field height integer
---@field offset { x: integer, y: integer } source cell origin plus this frame's translation
---@field duration integer source frame duration in fixed ticks

---@class StartMenuState.CursorAnimation
---@field playMode "forward"|"forward_loop"|"reverse"|"reverse_loop"
---@field loopStartFrameIdx integer zero-based source loop start
---@field frames StartMenuState.CursorFrame[]

---@class StartMenuState.View: StartMenuController.OpenStatus
---@field cursor { position: integer, frameIndex: integer }? the source-animated cursor when an action owns focus

---@param opts StartMenuState.Options
---@return StartMenuState
function StartMenuState.new(opts)
  assert(type(opts) == "table", "the start menu wrapper requires options")
  assert(type(opts.measureDisplay) == "function", "the start menu wrapper requires the display facts")
  assert(type(opts.cursorAnimation) == "table", "the start menu wrapper requires the source cursor animation")
  local interactive = assert(opts.interactive, "the start menu wrapper requires the interactive record")
  local controller = StartMenuController.new({
    entries = assert(opts.entries, "the start menu wrapper requires its entries"),
    interactive = interactive,
    rememberedActionId = opts.rememberedActionId,
    effect = opts.effect,
    runningShoes = assert(opts.runningShoes, "the start menu wrapper requires the Running Shoes port"),
  })
  local built, sessionOrError = pcall(function()
    return ApplicationPresentation.new(StartMenuInterface.defaults(), opts.overrides)
  end)
  if not built then
    controller:dispose()
    error(sessionOrError, 0)
  end
  local ready = assert(sessionOrError, "the start menu wrapper requires its presentation session")
  local self = setmetatable({
    _controller = controller,
    _session = ready,
    _measureDisplay = opts.measureDisplay,
    _cursorAnimation = opts.cursorAnimation,
    _fixedTick = 0,
    _disposed = false,
  }, StartMenuState)
  local resolveOk, resolveErr = pcall(function()
    self._session:resolve(self:_measured(), self:_view())
  end)
  if not resolveOk then
    controller:dispose()
    ready:dispose()
    error(resolveErr, 0)
  end
  return self
end

---@return DisplayMeasurement
function StartMenuState:_measured()
  local measurement = self._measureDisplay()
  return assert(measurement, "the start menu wrapper requires current display facts")
end

---@return table<string, unknown> the controller snapshot for resolvers and renderers
function StartMenuState:_view()
  local view = self._controller:status()
  local shoes = view.runningShoes
  if view.open and (shoes == nil or not shoes.focused) then
    ---@cast view StartMenuState.View
    view.cursor = {
      position = view.selectedPosition,
      frameIndex = self:_cursorFrameIndex(),
    }
  end
  return view
end

---@return integer one-based frame index
function StartMenuState:_cursorFrameIndex()
  local animation = self._cursorAnimation
  local tick = self._fixedTick
  local frames = animation.frames
  assert(type(frames) == "table" and #frames > 0, "the cursor animation requires frames")
  local order = {}
  if animation.playMode == "reverse" or animation.playMode == "reverse_loop" then
    for index = #frames, 1, -1 do
      order[#order + 1] = index
    end
  else
    for index = 1, #frames do
      order[#order + 1] = index
    end
  end
  local loopDuration = 0
  local firstLoopPosition = animation.loopStartFrameIdx + 1
  if animation.playMode == "reverse_loop" then
    firstLoopPosition = #frames - animation.loopStartFrameIdx
  end
  if animation.playMode == "forward_loop" or animation.playMode == "reverse_loop" then
    for index = firstLoopPosition, #order do
      loopDuration = loopDuration + frames[order[index]].duration
    end
    assert(loopDuration > 0, "the cursor loop must advance")
  end
  local totalDuration = 0
  for _, index in ipairs(order) do
    totalDuration = totalDuration + frames[index].duration
  end
  if animation.playMode == "forward_loop" or animation.playMode == "reverse_loop" then
    if tick >= totalDuration then
      local prefixDuration = 0
      for index = 1, firstLoopPosition - 1 do
        prefixDuration = prefixDuration + frames[order[index]].duration
      end
      tick = prefixDuration + (tick - totalDuration) % loopDuration
    end
  else
    tick = math.min(tick, math.max(totalDuration - 1, 0))
  end
  for _, index in ipairs(order) do
    local duration = frames[index].duration
    if tick < duration then
      return index
    end
    tick = tick - duration
  end
  return assert(order[#order], "the cursor animation has a terminal frame")
end

-- One fixed tick: resolve, map once, advance the controller once, resolve
-- again for the resulting snapshot. pointer_cancel flows in batch order;
-- the controller absorbs it without changing selection.
---@param uiInput table[]
function StartMenuState:updateFixed(uiInput)
  assert(not self._disposed, "a disposed start menu wrapper steps nothing")
  local session = self._session
  local measurement = self:_measured()
  session:resolve(measurement, self:_view())
  local mapped = session:mapInput(assert(uiInput, "the start menu input must be an event list"), self:_view())
  self._controller:updateFixed(mapped)
  self._fixedTick = self._fixedTick + 1
  session:resolve(measurement, self:_view())
end

-- The presentation snapshot: the controller's semantic fields plus
-- presentation=plan, the single host-facing layout authority. Fresh tables
-- per call.
---@return table<string, unknown>
function StartMenuState:status()
  local status = self:_view()
  status.presentation = self._session:plan()
  return status
end

-- The host result contract: launch, field action, and close forward
-- unchanged from the controller.
---@return { kind: "close"|"launch"|"field_action", applicationId?: string, actionId?: string }?
function StartMenuState:takeResult()
  return self._controller:takeResult()
end

-- Cancels a held press through both owners: the session drops its capture
-- and the controller releases its own, so a stale release never activates.
function StartMenuState:cancelPointerCapture()
  self._session:cancelPointers()
  self._controller:cancelPointerCapture()
end

-- Releases the session and the controller exactly once; a pending result
-- is discarded and no close is reported after disposal.
function StartMenuState:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  self._session:dispose()
  self._controller:dispose()
end

return StartMenuState
