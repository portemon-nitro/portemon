-- The source Fly-with-object presentation owner
-- (src/field/field_move_cut_in_effects.c::CutInFlyer). It owns the Dragonite
-- model players, trainer/flyer readiness and the flyer state producer. Script
-- waits read these states; they never advance status on the consumer's behalf.

local LanceDepartureEffect = {}
LanceDepartureEffect.__index = LanceDepartureEffect

-- FieldMoveCutIn_StartFlyWithObject offsets the cut-in sprites by the
-- departing trainer's (playerObject) world position relative to the player:
-- offset.x is half-tile fx32 scaled to pixels, offset.z is full-tile.
-- Both the presented and headless compositions share this conversion.
---@param player { x: number, y: number, z: number } live player world position
---@param lance { x: number, y: number, z: number } departing trainer world position
---@return { x: number, z: number }
function LanceDepartureEffect.screenOffsetFor(player, lance)
  assert(type(player) == "table" and type(lance) == "table", "the departure offset needs both world positions")
  assert(type(player.x) == "number" and type(lance.x) == "number", "the departure offset needs world x")
  assert(type(player.z) == "number" and type(lance.z) == "number", "the departure offset needs world z")
  return { x = (lance.x - player.x) * 8, z = (lance.z - player.z) * 16 }
end

local function radians(degrees)
  return degrees * math.pi / 180
end

local function copyVector(vector)
  return { x = vector.x, y = vector.y, z = vector.z }
end

---@class LanceDepartureEffect.Options
---@field model table<string, unknown> presented model handle
---@field clipIds string[] source Dragonite animation clip ids
---@field trainerFrameDurations integer[] source trainer animation frame durations
---@field screenOffset { x: number, z: number }? source object offset from the player
---@field onDispose (fun())? releases the presentation's prepared sprite resources

---@class LanceDepartureEffect
---@field private _model table<string, unknown>?
---@field private _clipIds string[]
---@field private _plays table<string, unknown>[]
---@field private _modelVisible boolean
---@field private _modelDone boolean
---@field private _modelPosition { x: number, y: number, z: number }
---@field private _spriteTransfer { active: boolean, ready: boolean, ticks: integer }
---@field private _flyTransfer { active: boolean, ready: boolean, ticks: integer }
---@field private _trainer { visible: boolean, frame: integer, elapsed: integer, x: number, y: number, scale: number, rotation: number }
---@field private _frameDurations integer[]
---@field private _screenOffset { x: number, z: number }
---@field private _onDispose (fun())?
---@field private _disposed boolean
---@field private _flyer table<string, unknown>?
function LanceDepartureEffect.new(options)
  assert(type(options) == "table" and options.model, "the departure effect needs its model handle")
  assert(type(options.clipIds) == "table" and #options.clipIds > 0, "the departure effect needs its model clips")
  assert(
    type(options.trainerFrameDurations) == "table" and #options.trainerFrameDurations > 0,
    "the departure effect needs its trainer animation"
  )
  for _, duration in ipairs(options.trainerFrameDurations) do
    assert(type(duration) == "number" and duration >= 0 and duration % 1 == 0, "trainer frame duration is invalid")
  end
  local screenOffset = options.screenOffset or { x = 0, z = 0 }
  assert(type(screenOffset.x) == "number" and type(screenOffset.z) == "number", "departure screen offset is invalid")
  return setmetatable({
    _model = options.model,
    _clipIds = options.clipIds,
    _plays = {},
    _modelVisible = false,
    _modelDone = false,
    _modelPosition = { x = 0, y = 0, z = 0 },
    _spriteTransfer = { active = false, ready = false, ticks = 0 },
    _flyTransfer = { active = false, ready = false, ticks = 0 },
    _trainer = {
      visible = false,
      frame = 1,
      elapsed = 0,
      x = 128 + screenOffset.x,
      y = 320 + screenOffset.z,
      scale = 1,
      rotation = 0,
    },
    _frameDurations = options.trainerFrameDurations,
    _screenOffset = screenOffset,
    _onDispose = options.onDispose,
    _disposed = false,
    _flyer = nil,
  }, LanceDepartureEffect)
end

function LanceDepartureEffect:loadSpriteGraphics()
  assert(not self._spriteTransfer.active, "trainer sprite transfer already started")
  self._spriteTransfer = { active = true, ready = false, ticks = 0 }
end

function LanceDepartureEffect:spritesReady()
  return self._spriteTransfer.ready
end

function LanceDepartureEffect:createTrainer()
  assert(self._spriteTransfer.ready, "trainer sprite resources are not ready")
  self._trainer.visible = true
end

function LanceDepartureEffect:showOtherObject(position)
  assert(not self._modelVisible, "the Dragonite model effect already owns the model")
  self._modelPosition = copyVector(position)
  self._plays = {}
  for _, id in ipairs(self._clipIds) do
    self._plays[#self._plays + 1] = self._model:play(id, { loopMode = "once" })
  end
  self._modelVisible = true
  self._modelDone = false
end

function LanceDepartureEffect:isModelDone()
  return self._modelDone
end

function LanceDepartureEffect:releaseModel()
  if self._model == nil then
    return
  end
  for _, handle in ipairs(self._plays) do
    self._model:stop(handle)
  end
  self._plays = {}
  self._modelVisible = false
  self._modelDone = true
  self._model:dispose()
  self._model = nil
end

function LanceDepartureEffect:loadFlyGraphics()
  assert(not self._flyTransfer.active, "flyer sprite transfer already started")
  self._flyTransfer = { active = true, ready = false, ticks = 0 }
end

function LanceDepartureEffect:flyerReady()
  return self._flyTransfer.ready
end

function LanceDepartureEffect:createFlyer()
  assert(self._flyTransfer.ready and self._flyer == nil, "CreateFlyer needs ready graphics and no live flyer")
  self._flyer = {
    status = 0,
    phase = "hidden",
    distance = 0,
    speed = 0,
    angle = 225,
    rotation = 315,
    scale = 1.25,
    x = 128 + self._screenOffset.x,
    y = 384 + self._screenOffset.z,
    visible = false,
    trainerOffsetY = 0,
  }
end

function LanceDepartureEffect:flyerStatus()
  return self._flyer ~= nil and self._flyer.status or nil
end

function LanceDepartureEffect:startPickup()
  local flyer = assert(self._flyer, "StartFlyerPickUp needs a created flyer")
  assert(flyer.status == 0, "StartFlyerPickUp needs a hidden flyer")
  flyer.status = 1
  flyer.phase = "swoop"
  flyer.distance = 192
  flyer.speed = 32
  flyer.angle = 225
  flyer.rotation = 315
  flyer.scale = 1.25
  flyer.x = 128 + self._screenOffset.x + math.cos(radians(315)) * flyer.distance
  flyer.y = 384 + self._screenOffset.z + math.sin(radians(225)) * flyer.distance
  flyer.visible = true
end

function LanceDepartureEffect:destroyFlyer()
  self._flyer = nil
end

local function advanceTransfer(transfer)
  if transfer.active and not transfer.ready then
    transfer.ticks = transfer.ticks + 1
    transfer.ready = transfer.ticks >= 1
  end
end

local function advanceTrainer(effect)
  local trainer = effect._trainer
  if not trainer.visible then
    return
  end
  trainer.elapsed = trainer.elapsed + 1
  local advanced = 0
  while true do
    local duration = effect._frameDurations[trainer.frame]
    if duration > 0 and trainer.elapsed < duration then
      return
    end
    if duration > 0 then
      trainer.elapsed = trainer.elapsed - duration
    else
      trainer.elapsed = 0
    end
    trainer.frame = trainer.frame % #effect._frameDurations + 1
    advanced = advanced + 1
    assert(advanced <= #effect._frameDurations, "trainer animation has no positive frame duration")
  end
end

local function advanceFlyer(effect)
  local flyer = effect._flyer
  if flyer == nil or not flyer.visible then
    return
  end
  if flyer.phase == "swoop" then
    flyer.distance = math.max(0, flyer.distance - flyer.speed)
    flyer.speed = math.max(0.5, flyer.speed - 1.5)
    flyer.angle = math.min(270, flyer.angle + 4)
    flyer.rotation = math.min(360, flyer.rotation + 8)
    flyer.scale = math.min(1.5, flyer.scale + 1 / 256)
    flyer.x = 128 + effect._screenOffset.x + math.cos(radians(315)) * flyer.distance
    flyer.y = 384 + effect._screenOffset.z + math.sin(radians(flyer.angle)) * flyer.distance
    if flyer.distance == 0 then
      flyer.phase = "pickup"
    end
    return
  end
  if flyer.phase == "pickup" then
    flyer.status = 3
    flyer.phase = "away"
    flyer.trainerOffsetY = effect._trainer.y - flyer.y
    flyer.angle = 128
    flyer.distance = 0
    flyer.speed = 0.5
    return
  end
  assert(flyer.phase == "away", "the flyer has a closed phase set")
  flyer.distance = flyer.distance + flyer.speed
  flyer.speed = math.min(16, flyer.speed + 1)
  flyer.angle = math.min(135, flyer.angle + 1)
  flyer.scale = math.min(2, flyer.scale + 1 / 256)
  flyer.x = 128 + effect._screenOffset.x + math.cos(radians(flyer.angle)) * flyer.distance
  flyer.y = 384 + effect._screenOffset.z + math.sin(radians(128)) * flyer.distance
  if flyer.y >= 230 then
    flyer.status = 2
    flyer.phase = "done"
  end
  flyer.trainerOffsetY = flyer.trainerOffsetY - 1
  effect._trainer.x = flyer.x
  effect._trainer.y = flyer.y + flyer.trainerOffsetY
  effect._trainer.scale = math.min(2, effect._trainer.scale + 1 / 256)
end

function LanceDepartureEffect:updateFixed()
  advanceTransfer(self._spriteTransfer)
  advanceTransfer(self._flyTransfer)
  if self._modelVisible then
    self._model:updateFixed()
    self._modelDone = true
    for _, handle in ipairs(self._plays) do
      if not handle.player:isComplete() then
        self._modelDone = false
      end
    end
  end
  advanceTrainer(self)
  advanceFlyer(self)
end

function LanceDepartureEffect:snapshot()
  local trainer = self._trainer
  local flyer = self._flyer
  return {
    trainer = {
      visible = trainer.visible,
      frame = trainer.frame,
      x = trainer.x,
      y = trainer.y,
      scale = trainer.scale,
      rotation = trainer.rotation,
    },
    flyer = flyer ~= nil and {
      visible = flyer.visible,
      x = flyer.x,
      y = flyer.y,
      scale = flyer.scale,
      rotation = flyer.rotation,
    } or nil,
    model = self._modelVisible and {
      handle = self._model,
      x = self._modelPosition.x,
      y = self._modelPosition.y,
      z = self._modelPosition.z,
    } or nil,
  }
end

function LanceDepartureEffect:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  self:releaseModel()
  self:destroyFlyer()
  self._trainer.visible = false
  self._spriteTransfer = { active = false, ready = false, ticks = 0 }
  self._flyTransfer = { active = false, ready = false, ticks = 0 }
  if self._onDispose ~= nil then
    self._onDispose()
    self._onDispose = nil
  end
end

return LanceDepartureEffect
