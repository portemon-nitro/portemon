-- The source app71 in-game trade sequence: one closed scene state machine over
-- the fixed tick. It presents the seven sTradeSequenceScenes in source order --
-- the send, depart and recede scenes for the departure, the shared exchange
-- scene, and the approach, arrive and receive scenes for the arrival -- with
-- their own sounds, cries, fanfare, palette pulses, background zoom/scroll, the
-- Poke Ball model's flight, the depart light-streak fall, the mon pictures and
-- the bank-179 message lines. Nothing here mutates a mon, a statistic or a
-- save: the exchange receipt is committed before the sequence opens, and the
-- scene presents detached subjects only.
--
-- Every scene is ported as the source's own sub-state chain: each state either
-- counts its source timer out or waits on a task this file also runs (message
-- prints, the ball flight, the streak fall, the pulse walk). Tasks the source
-- keeps on the main/vblank queues step once per fixed tick here, so a snapshot
-- always describes exactly one source frame.
--
-- The scene is independent of rendering: frames, waits and audio effects
-- advance on the fixed tick, while the renderer only reads snapshots. Model
-- geometry never enters this file: the flight's out-of-view decision projects
-- the model's own origin through the scene camera (the source tests the
-- model's bounding box, which only shifts that decision by its half-extent).
-- Retail sources (tmp/refs/pokeheartgold): src/application/trade_sequence/
-- trade_sequence.c and the seven scene modules.

local PokemonCareInterface = require("libs.hgss.src.ui.PokemonCareInterface")

local bit = require("bit")

local FX32_ONE = 4096
local U32 = 4294967296
local TAU = math.pi * 2
local ANGLE_UNIT = TAU / 65536
local U16 = 65536

-- TradeSequence_ApplyBgZoom's affine reference points: index 0 is the main
-- screen's y 144, index 1 the sub screen's y 56.
local ZOOM_CENTER_Y = { 144, 56 }

-- The shared effect sheet's burst sequences total 21 NANR ticks, which is what
-- the source's `Sprite_IsAnimated` waits gate on (send ball open, receive
-- burst, recede/approach effect). The state machine owns that clock, so the
-- length is a scene constant here; the graphics suite pins it against the
-- compiled sheet.
local EFFECT_SEQUENCE_TICKS = 21

-- TradeSequence_CreatePulses: eight slots, one white colour walking a fifteen
-- colour stretch of the layer palette at one colour every two frames, with a
-- new pulse starting every thirty frames.
local PULSE_SLOTS = 8
local PULSE_STEP_FRAMES = 2
local PULSE_SPAWN_FRAMES = 30
local PULSE_COLOR_START = -1
local PULSE_COLOR_END = 15

-- TradeSequenceDepart_CreateStreaks: twenty head/tail pairs placed by the
-- source's own Mersenne Twister stream (seed 0x35947D1), falling 33 pixels a
-- frame, wrapping 452 pixels, and revealed one per twelve frames once the
-- scroll passes 128 pixels.
local STREAK_COUNT = 20
local STREAK_SEED = 0x35947D1
local STREAK_X_MODULUS = 232
local STREAK_X_BASE = 12
local STREAK_Y_MODULUS = 452
local STREAK_Y_BASE = -28
local STREAK_TAIL_OFFSET = 56
local STREAK_FALL_STEP = 33
local STREAK_WRAP_AT = 424
local STREAK_WRAP_SPAN = 452
local STREAK_REVEAL_FRAMES = 12
local STREAK_FALL_DISTANCE = 128

-- The source's MT19937 (src/math_util.c): SetMTRNGSeed then MTRandom, used for
-- the streak layout only. Products are split into 16-bit halves so 32-bit
-- multiplication stays exact.
---@param value number
---@return integer
local function u32(value)
  return value % U32
end

---@param a integer
---@param b integer
---@return integer
local function mul32(a, b)
  local aLo = bit.band(a, 0xFFFF)
  local aHi = bit.rshift(a, 16)
  local bLo = bit.band(b, 0xFFFF)
  local bHi = bit.rshift(b, 16)
  local low = aLo * bLo
  local middle = u32((aLo * bHi + aHi * bLo) % 65536) * 65536
  return u32(low + middle)
end

---@param seed integer
---@return fun(): integer
local function newMtRandom(seed)
  local state = { seed }
  for cycle = 1, 623 do
    local previous = state[cycle]
    state[cycle + 1] = u32(mul32(1812433253, bit.bxor(previous, bit.rshift(previous, 30))) + cycle)
  end
  local index = 624
  return function()
    if index >= 624 then
      for position = 1, 624 do
        local nextState = state[position % 624 + 1]
        local value = bit.bor(bit.band(state[position], 0x80000000), bit.band(nextState, 0x7FFFFFFF))
        local twisted = bit.bxor(
          state[(position + 396) % 624 + 1],
          bit.rshift(value, 1),
          bit.band(value, 1) == 1 and 0x9908B0DF or 0
        )
        state[position] = u32(twisted)
      end
      index = 0
    end
    index = index + 1
    local value = state[index]
    value = bit.bxor(value, bit.rshift(value, 11))
    value = bit.bxor(value, bit.band(bit.lshift(value, 7), 0x9D2C5680))
    value = bit.bxor(value, bit.band(bit.lshift(value, 15), 0xEFC60000))
    value = bit.bxor(value, bit.rshift(value, 18))
    return u32(value)
  end
end

---@param value number
---@return integer
local function round(value)
  if value >= 0 then
    return math.floor(value + 0.5)
  end
  return math.ceil(value - 0.5)
end

---@param index integer binary angle index
---@return number
local function sinIdx(index)
  return math.sin((index % U16) * ANGLE_UNIT)
end

---@param index integer binary angle index
---@return number
local function cosIdx(index)
  return math.cos((index % U16) * ANGLE_UNIT)
end

-- The source's fx32 cosine table read by whole degrees
-- (GF_CosDegNoWrap / GF_SinDegNoWrap), quantized to fx32 like the table.
---@param degrees integer
---@return number
local function cosDegFixed(degrees)
  return round(math.cos(math.rad(degrees % 360)) * FX32_ONE)
end

---@param degrees integer
---@return number
local function sinDegFixed(degrees)
  return round(math.sin(math.rad(degrees % 360)) * FX32_ONE)
end

-- The source's fx32 multiply: (a * b) >> 12 with the +0x800 rounding the model
-- flight uses before the shift.
---@param a number
---@param b number
---@return number
local function fxMulRound(a, b)
  return math.floor((round(a * b) + 0x800) / FX32_ONE)
end

-- One scene's source camera: TradeSequence_InitCamera allocates it from the
-- target (0, 0, 0) at distance 300 with perspective angle 4004 and type 0; each
-- scene then overrides the angle, the fov/type, or the clipping plane
-- (Camera_SetPerspectiveClippingPlane(0, 1000)).
---@class NpcTradeCamera
---@field angleX integer binary angle index
---@field angleY integer binary angle index
---@field distance number model units
---@field fov integer half field-of-view binary angle index
---@field perspectiveType integer 0 perspective, 1 orthographic
---@field near number model units
---@field far number model units

---@return NpcTradeCamera
local function newCamera()
  return { angleX = 0, angleY = 0, distance = 300, fov = 4004, perspectiveType = 0, near = 0, far = 1000 }
end

-- The source's look-at position for a target at the origin
-- (Camera_CalcLookAtPosFromTargetAndAngle).
---@param camera NpcTradeCamera
---@return { x: number, y: number, z: number }
local function cameraEye(camera)
  local cosX = cosIdx(camera.angleX)
  return {
    x = sinIdx(camera.angleY) * camera.distance * cosX,
    y = -sinIdx(camera.angleX) * camera.distance,
    z = cosIdx(camera.angleY) * camera.distance * cosX,
  }
end

-- True while one model-space point projects inside the source's 256x192 frame:
-- the orthographic scenes compare against the source's half extents
-- (tan(fov) * distance, widened by the 4:3 aspect), the perspective scenes
-- against the same half angle at the point's depth.
---@param camera NpcTradeCamera
---@param x number
---@param y number
---@param z number
---@return boolean
local function pointInView(camera, x, y, z)
  local eye = cameraEye(camera)
  local fx, fy, fz = -eye.x, -eye.y, -eye.z
  local length = math.sqrt(fx * fx + fy * fy + fz * fz)
  if length == 0 then
    return true
  end
  fx, fy, fz = fx / length, fy / length, fz / length
  -- up is +Y; right = up x forward.
  local sx, sy, sz = fy * 0 - fz * 1, fz * 0 - fx * 0, fx * 1 - fy * 0
  local sideways = math.sqrt(sx * sx + sy * sy + sz * sz)
  if sideways == 0 then
    return true
  end
  sx, sy, sz = sx / sideways, sy / sideways, sz / sideways
  local ux, uy, uz = sy * fz - sz * fy, sz * fx - sx * fz, sx * fy - sy * fx
  local dx, dy, dz = x - eye.x, y - eye.y, z - eye.z
  local viewX = dx * sx + dy * sy + dz * sz
  local viewY = dx * ux + dy * uy + dz * uz
  local viewZ = dx * fx + dy * fy + dz * fz
  local halfFov = camera.fov * ANGLE_UNIT
  local aspect = 4 / 3
  local tanHalf = math.tan(halfFov)
  if camera.perspectiveType == 1 then
    local halfHeight = tanHalf * camera.distance
    local halfWidth = halfHeight * aspect
    return viewZ <= 0 and math.abs(viewX) <= halfWidth and math.abs(viewY) <= halfHeight
  end
  if viewZ <= 0 then
    return false
  end
  return math.abs(viewX) <= viewZ * tanHalf * aspect and math.abs(viewY) <= viewZ * tanHalf
end

-- TradeSequence_Init plays the trade music before the first scene.
local TRADE_MUSIC = "SEQ_GS_KOUKAN"

---@class NpcTradeBalloon
---@field x number model units
---@field y number model units
---@field z number model units
---@field rotation { x: integer, y: integer, z: integer }
---@field scale number
---@field alpha integer 0..31
---@field visible boolean

---@return NpcTradeBalloon
local function newBalloon()
  return { x = 0, y = 0, z = 0, rotation = { x = 0, y = 0, z = 0 }, scale = 1, alpha = 31, visible = false }
end

-- One sprite the active scene draws from the shared effect sheet, in draw
-- order (the source's OAM priority, front-most last).
---@class NpcTradeSpriteSlot
---@field sequence integer
---@field x integer
---@field y integer

-- The depart scene's falling light streaks.
---@class NpcTradeStreakFall
---@field positions { x: integer, y: number }[]
---@field visible boolean[]
---@field delay integer
---@field revealed integer

---@class NpcTradeState
---@field private _request PokemonCareTradeRequest
---@field private _audio table<string, unknown>
---@field private _sceneIndex integer the active source scene
---@field private _phase string
---@field private _frame integer frames spent in the active scene
---@field private _state integer the active scene's sub-state
---@field private _timer integer the active sub-state's own timer
---@field private _messageId integer?
---@field private _balloon NpcTradeBalloon
---@field private _camera NpcTradeCamera
---@field private _spriteTicks table<integer, integer>
---@field private _streakFall NpcTradeStreakFall?
---@field private _pictures { subject: string, visible: boolean, x: number, y: number }[]
---@field private _pulses { running: boolean, stopping: boolean?, direction: integer, timer: integer, nextSlot: integer, slots: table<integer, table> }
---@field private _zoomScale number
---@field private _zoomSpeed number
---@field private _zoomCenterY integer
---@field private _zoom table<string, unknown>?
---@field private _scrollY number the affine layer's map y position in pixels
---@field private _scroll table<string, unknown>?
---@field private _flight table<string, unknown>?
---@field private _bounce table<string, unknown>?
---@field private _brightness table<string, unknown>?
---@field private _lower table<string, unknown>?
---@field private _fade table<string, unknown>?
---@field private _slide table<string, unknown>?
---@field private _done boolean
---@field private _presentationReady boolean
---@field private _preparationError string?
---@field private _musicStarted boolean
local NpcTradeState = {}
NpcTradeState.__index = NpcTradeState

NpcTradeState.EFFECT_SEQUENCE_TICKS = EFFECT_SEQUENCE_TICKS
NpcTradeState.STREAK_COUNT = STREAK_COUNT
NpcTradeState.PULSE_SLOTS = PULSE_SLOTS

---@param opts { request: PokemonCareTradeRequest, audio: table<string, unknown> }
---@return NpcTradeState
function NpcTradeState.new(opts)
  assert(type(opts) == "table", "the trade sequence requires its options")
  local request = PokemonCareInterface.assertTradeRequest(opts.request)
  assert(type(opts.audio) == "table", "the trade sequence requires the source audio host")
  local state = setmetatable({
    _request = request,
    _audio = opts.audio,
    _sceneIndex = 1,
    _phase = PokemonCareInterface.TRADE_PHASES.SEND,
    _frame = 0,
    _state = 0,
    _timer = 0,
    _messageId = nil,
    _balloon = newBalloon(),
    _camera = newCamera(),
    _spriteTicks = {},
    _streakFall = nil,
    _pictures = {},
    _pulses = { running = false, direction = 1, timer = 0, nextSlot = 0, slots = {} },
    _zoomScale = 1,
    _zoomSpeed = 0,
    _zoomCenterY = ZOOM_CENTER_Y[1],
    _zoom = nil,
    _scrollY = 0,
    _scroll = nil,
    _flight = nil,
    _bounce = nil,
    _brightness = nil,
    _lower = nil,
    _fade = nil,
    _slide = nil,
    _done = false,
    _presentationReady = false,
    _preparationError = nil,
    _musicStarted = false,
  }, NpcTradeState)
  state:_enterScene(1)
  return state
end

-- Marks the generated presentation bundle as ready for drawing, or records why
-- it is unusable. The sequence keeps running either way: gameplay never waits
-- for a renderer.
---@param ready boolean
---@param failure string?
function NpcTradeState:setPresentation(ready, failure)
  self._presentationReady = ready == true
  self._preparationError = failure
end

---@return string
function NpcTradeState:phase()
  return self._phase
end

---@return boolean
function NpcTradeState:isDone()
  return self._done
end

---@param sound string
function NpcTradeState:_sound(sound)
  if type(self._audio.play) == "function" then
    self._audio:play(sound)
  end
end

---@param which string "outgoing" or "incoming"
function NpcTradeState:_cry(which)
  local subject = which == "outgoing" and self._request.outgoing or self._request.incoming
  if type(self._audio.playCry) == "function" then
    self._audio:playCry(subject.species, 0, subject.form)
  end
end

---@param sound string
function NpcTradeState:_fanfare(sound)
  if type(self._audio.playFanfare) == "function" then
    self._audio:playFanfare(sound)
  end
end

-- Renders the white palette indices the pulse walk currently holds.
---@return integer[]
function NpcTradeState:_whiteIndices()
  local indices = {}
  for _, slot in pairs(self._pulses.slots) do
    if type(slot.index) == "number" and slot.index >= 0 then
      indices[#indices + 1] = slot.index
    end
  end
  table.sort(indices)
  return indices
end

-- The scene's effect-sheet sprites that are on screen this frame, in the
-- scene's draw order, each with the source tick its animation runs at.
---@return table[]
function NpcTradeState:_visibleSprites()
  local slots = self:_spriteSlots()
  local drawn = {}
  for index, sprite in ipairs(slots) do
    local tick = self._spriteTicks[index]
    if tick ~= nil then
      drawn[#drawn + 1] = { sequence = sprite.sequence, x = sprite.x, y = sprite.y, tick = tick }
    end
  end
  return drawn
end

-- The depart streaks that are currently on screen, head and tail.
---@return table[]
function NpcTradeState:_visibleStreaks()
  local fall = self._streakFall
  if fall == nil then
    return {}
  end
  local drawn = {}
  for index = 1, STREAK_COUNT do
    if fall.visible[index] then
      local position = assert(fall.positions[index], "the streak fall keeps every position")
      drawn[#drawn + 1] = {
        x = position.x,
        headY = math.floor(position.y),
        tailY = math.floor(position.y) + STREAK_TAIL_OFFSET,
        tick = self._frame,
      }
    end
  end
  return drawn
end

---@return table<string, unknown>
function NpcTradeState:snapshot()
  local pictures = {}
  for index, picture in ipairs(self._pictures) do
    pictures[index] = { subject = picture.subject, visible = picture.visible, x = picture.x, y = picture.y }
  end
  return PokemonCareInterface.assertTradeStatus({
    kind = PokemonCareInterface.KINDS.trade,
    phase = self._phase,
    frame = self._frame,
    backdrop = self._request.backdrop,
    messageId = self._messageId,
    bgZoom = self._zoomScale,
    bgZoomCenterY = self._zoomCenterY,
    bgScrollY = math.floor(self._scrollY),
    sprites = self:_visibleSprites(),
    streaks = self:_visibleStreaks(),
    pictures = pictures,
    pulses = self:_whiteIndices(),
    balloon = self._balloon.visible and {
      x = self._balloon.x,
      y = self._balloon.y,
      z = self._balloon.z,
      rotX = self._balloon.rotation.x % U16,
      rotY = self._balloon.rotation.y % U16,
      rotZ = self._balloon.rotation.z % U16,
      scale = self._balloon.scale,
      alpha = self._balloon.alpha,
    } or nil,
    camera = self._balloon.visible and {
      angleX = self._camera.angleX % U16,
      angleY = self._camera.angleY % U16,
      distance = self._camera.distance,
      fov = self._camera.fov,
      perspectiveType = self._camera.perspectiveType,
      near = self._camera.near,
      far = self._camera.far,
    } or nil,
    outgoing = self._request.outgoing,
    incoming = self._request.incoming,
    done = self._done,
    presentationReady = self._presentationReady,
    preparationError = self._preparationError,
  })
end

---@return PokemonCareTradeResult
function NpcTradeState:result()
  assert(self._done, "the trade sequence answers after it finished")
  return PokemonCareInterface.assertTradeResult({ kind = PokemonCareInterface.KINDS.trade, done = true })
end

-- Advances every shown sprite slot by one animation tick
-- (TradeSequence_CreateSprite sets anim speed FX32_ONE).
function NpcTradeState:_advanceSprites()
  local slots = self:_spriteSlots()
  for index = 1, #slots do
    local tick = self._spriteTicks[index]
    if tick ~= nil then
      self._spriteTicks[index] = tick + 1
    end
  end
end

-- Shows one scene sprite slot: the source's Sprite_SetAnimCtrlSeq plus
-- Sprite_SetDrawFlag pair.
---@param index integer
function NpcTradeState:_showSprite(index)
  self._spriteTicks[index] = 0
end

-- Starts one background zoom (TradeSequence_StartBgZoom). Scales are fx32
-- like the source's.
---@param from integer
---@param target integer
---@param centerYIndex integer
---@param speed integer
---@param acceleration integer
function NpcTradeState:_startZoom(from, target, centerYIndex, speed, acceleration)
  self._zoom = {
    scale = from,
    target = target,
    speed = speed,
    acceleration = acceleration,
    grow = from < target,
    finished = false,
  }
  self._zoomScale = from / FX32_ONE
  self._zoomSpeed = speed
  self._zoomCenterY = ZOOM_CENTER_Y[centerYIndex + 1]
end

-- TradeSequence_BgZoomTask: amount = ((scale * speed) >> 12) / 32, applied
-- until the target lands; the speed keeps accelerating meanwhile.
function NpcTradeState:_stepZoom()
  local zoom = self._zoom
  if zoom == nil or zoom.finished then
    return
  end
  local scale = assert(zoom.scale --[[@as integer]])
  local speed = assert(zoom.speed --[[@as integer]])
  local amount = math.floor(math.floor(scale * speed / FX32_ONE) / 32)
  local target = assert(zoom.target --[[@as integer]])
  if zoom.grow == true then
    local nextScale = scale + amount
    if nextScale < target then
      zoom.scale = nextScale
    else
      zoom.scale = target
      zoom.finished = true
    end
  else
    local nextScale = scale - amount
    if nextScale > target then
      zoom.scale = nextScale
    else
      zoom.scale = target
      zoom.finished = true
    end
  end
  if zoom.finished ~= true then
    zoom.speed = speed + assert(zoom.acceleration --[[@as integer]])
  end
  self._zoomScale = assert(zoom.scale --[[@as number]]) / FX32_ONE
  self._zoomSpeed = assert(zoom.speed --[[@as number]])
end

-- TradeSequenceDepart_StartScroll + ScrollTask: an accelerating scroll
-- distance subtracted from the map's resting y, which starts the streak fall
-- once it passes 128 pixels.
---@param base number the map's resting y in pixels
function NpcTradeState:_startDepartScroll(base)
  self._scroll = { base = base, distance = 0, speed = 0 }
end

function NpcTradeState:_stepDepartScroll()
  local scroll = self._scroll
  if scroll == nil then
    return
  end
  local distance = assert(scroll.distance --[[@as number]])
  if distance >= 512 * FX32_ONE then
    return
  end
  local speed = assert(scroll.speed --[[@as number]]) + 0x120
  distance = distance + speed
  scroll.speed = speed
  scroll.distance = distance
  self._scrollY = assert(scroll.base --[[@as number]]) - distance / FX32_ONE
  if distance >= STREAK_FALL_DISTANCE * FX32_ONE and self._streakFall == nil then
    self:_startStreakFall()
  end
end

-- TradeSequenceArrive_StartScroll + ScrollTask: a fixed speed for forty
-- frames, then the source's own snap into place.
---@param base number the map's resting y in pixels
function NpcTradeState:_startArriveScroll(base)
  self._scroll = { mainY = base * FX32_ONE, speed = 0x9999, frames = 40 }
end

function NpcTradeState:_stepArriveScroll()
  local scroll = self._scroll
  if scroll == nil then
    return
  end
  local frames = assert(scroll.frames --[[@as integer]])
  if frames > 0 then
    scroll.mainY = assert(scroll.mainY --[[@as number]]) + assert(scroll.speed --[[@as number]])
    scroll.frames = frames - 1
    self._scrollY = assert(scroll.mainY --[[@as number]]) / FX32_ONE
    return
  end
  self._scrollY = 0
  self._scroll = nil
end

-- TradeSequenceDepart_StartStreakFall: every streak falls 33 pixels a frame
-- and wraps 452 pixels back; one more streak is revealed every twelve frames.
function NpcTradeState:_startStreakFall()
  local random = newMtRandom(STREAK_SEED)
  local positions = {}
  local visible = {}
  for index = 1, STREAK_COUNT do
    local x = random() % STREAK_X_MODULUS + STREAK_X_BASE
    local y = random() % STREAK_Y_MODULUS + STREAK_Y_BASE
    positions[index] = { x = x, y = y }
    visible[index] = false
  end
  self._streakFall = { positions = positions, visible = visible, delay = 0, revealed = 0 }
end

function NpcTradeState:_stepStreakFall()
  local fall = self._streakFall
  if fall == nil then
    return
  end
  fall.delay = fall.delay + 1
  if fall.delay > STREAK_REVEAL_FRAMES then
    fall.delay = 0
    if fall.revealed < STREAK_COUNT then
      fall.revealed = fall.revealed + 1
      fall.visible[fall.revealed] = true
    end
  end
  for index = 1, STREAK_COUNT do
    local position = assert(fall.positions[index], "the streak fall keeps every position")
    position.y = position.y + STREAK_FALL_STEP
    if position.y >= STREAK_WRAP_AT then
      position.y = position.y - STREAK_WRAP_SPAN
    end
  end
end

-- TradeSequence_CreatePulses + TradeSequence_PulsesTask: a pulse starts every
-- thirty frames (playing the source sound), walks one white palette index
-- every two frames, and clears it as the walk moves on.
---@param direction integer 1 walks up, -1 walks down
function NpcTradeState:_startPulses(direction)
  self._pulses = { running = true, direction = direction, timer = 0, nextSlot = 0, slots = {} }
end

function NpcTradeState:_stepPulses()
  local pulses = self._pulses
  if not pulses.running then
    return
  end
  if pulses.stopping ~= true then
    pulses.timer = pulses.timer - 1
    if pulses.timer <= 0 then
      self:_sound("SEQ_SE_DP_KOUKAN08")
      pulses.timer = PULSE_SPAWN_FRAMES
      self:_startPulse()
    end
  end
  local finished = {}
  for slotIndex, slot in pairs(pulses.slots) do
    slot.frames = slot.frames + 1
    if slot.frames >= PULSE_STEP_FRAMES then
      slot.frames = 0
      if pulses.direction == 1 then
        if slot.index + 1 >= PULSE_COLOR_END then
          slot.index = nil
          finished[#finished + 1] = slotIndex
        else
          slot.index = slot.index + 1
        end
      else
        if slot.index < 0 then
          slot.index = nil
          finished[#finished + 1] = slotIndex
        else
          slot.index = slot.index - 1
        end
      end
    end
  end
  for _, slotIndex in ipairs(finished) do
    pulses.slots[slotIndex] = nil
  end
  if next(pulses.slots) == nil and pulses.stopping == true then
    pulses.running = false
  end
end

-- TradeSequence_StartPulse: a new pulse takes the next slot when it is free.
function NpcTradeState:_startPulse()
  local pulses = self._pulses
  local slotIndex = pulses.nextSlot
  if pulses.slots[slotIndex] ~= nil then
    return
  end
  pulses.slots[slotIndex] = {
    index = pulses.direction == 1 and PULSE_COLOR_START or PULSE_COLOR_END,
    frames = 0,
  }
  pulses.nextSlot = (pulses.nextSlot + 1) % PULSE_SLOTS
end

-- TradeSequence_StopPulses: no new pulse starts and the running ones drain.
function NpcTradeState:_stopPulses()
  local pulses = self._pulses
  pulses.stopping = true
  if next(pulses.slots) == nil then
    pulses.running = false
  end
end

-- A scene's own sprite slots (the shared effect sheet).
---@return NpcTradeSpriteSlot[]
function NpcTradeState:_spriteSlots()
  local scene = NpcTradeState.SCENES[self._sceneIndex]
  if scene == nil then
    return {}
  end
  return scene.sprites or {}
end

-- One model alpha fade (TradeSequenceDepart_StartAlphaFade and the arrive
-- equivalent): alpha walks from start to target over the scene's frames.
---@param start integer
---@param target integer
---@param frames integer
function NpcTradeState:_startAlphaFade(start, target, frames)
  self._fade = {
    alpha = start * FX32_ONE,
    target = target * FX32_ONE,
    step = (target - start) * FX32_ONE / frames,
    frames = frames,
  }
  self._balloon.alpha = start
end

function NpcTradeState:_stepAlphaFade()
  local fade = self._fade
  if fade == nil then
    return
  end
  fade.frames = assert(fade.frames --[[@as integer]]) - 1
  if fade.frames > 0 then
    fade.alpha = assert(fade.alpha --[[@as number]]) + assert(fade.step --[[@as number]])
    self._balloon.alpha = math.floor(assert(fade.alpha --[[@as number]]) / FX32_ONE)
    return
  end
  self._balloon.alpha = math.floor(assert(fade.target --[[@as number]]) / FX32_ONE)
  self._fade = nil
end

-- The scene background brightness flashes (G2_SetBlendBrightness) have no
-- screen blend in this port; their timers still gate the scene states exactly
-- like the source's brightness task.
---@param frames integer
function NpcTradeState:_startBrightness(frames)
  self._brightness = { frames = frames }
end

function NpcTradeState:_stepBrightness()
  local brightness = self._brightness
  if brightness == nil then
    return
  end
  brightness.frames = assert(brightness.frames --[[@as integer]]) - 1
  if brightness.frames <= 0 then
    self._brightness = nil
  end
end

---@return boolean
function NpcTradeState:_brightnessDone()
  return self._brightness == nil
end

-- Resets the per-scene presentation state and runs the scene's own
-- SetupScreens actions (background transforms, camera, model, sprites).
---@param index integer
function NpcTradeState:_enterScene(index)
  self._sceneIndex = index
  local scene = assert(NpcTradeState.SCENES[index], "the trade sequence plays a known scene")
  self._phase = scene.phase
  self._frame = 0
  self._state = 0
  self._timer = 0
  self._messageId = nil
  self._spriteTicks = {}
  self._pictures = {}
  self._streakFall = nil
  self._scroll = nil
  self._scrollY = 0
  self._zoom = nil
  self._zoomScale = 1
  self._zoomCenterY = ZOOM_CENTER_Y[1]
  self._balloon = newBalloon()
  self._camera = newCamera()
  self._flight = nil
  self._bounce = nil
  self._brightness = nil
  self._lower = nil
  self._fade = nil
  self._slide = nil
  self._pulses.running = false
  self._pulses.slots = {}
  scene.enter(self)
end

-- Advances one source frame of the active scene: its own tasks, then the
-- scene's state machine. A scene that returns true hands over to the next one.
---@param _ table<string, unknown>|nil scheduler input
function NpcTradeState:updateFixed(_)
  if self._done then
    return
  end
  if not self._musicStarted then
    if type(self._audio.playMusic) == "function" then
      self._audio:playMusic(TRADE_MUSIC)
    end
    self._musicStarted = true
  end
  local scene = assert(NpcTradeState.SCENES[self._sceneIndex], "the trade sequence plays a known scene")
  self._frame = self._frame + 1
  self:_advanceSprites()
  self:_stepZoom()
  if scene.scroll == "depart" then
    self:_stepDepartScroll()
  elseif scene.scroll == "arrive" then
    self:_stepArriveScroll()
  end
  self:_stepStreakFall()
  self:_stepPulses()
  self:_stepAlphaFade()
  self:_stepBrightness()
  if scene.step(self) then
    local nextIndex = self._sceneIndex + 1
    if NpcTradeState.SCENES[nextIndex] == nil then
      self._phase = PokemonCareInterface.TRADE_PHASES.DONE
      self._done = true
      self._balloon.visible = false
      return
    end
    self:_enterScene(nextIndex)
  end
end

-- Releases nothing: the scene owns no lease. The host owns the presentation
-- bundle and the field owns the audio host.
function NpcTradeState:dispose()
  self._done = true
end

-- ---------------------------------------------------------------------------
-- The scenes, in sTradeSequenceScenes order.
-- ---------------------------------------------------------------------------

---@type { phase: string, scroll: string?, sprites: NpcTradeSpriteSlot[]?, enter: fun(self: NpcTradeState), step: fun(self: NpcTradeState): boolean }[]
NpcTradeState.SCENES = {}

-- The send scene's bounce task (TradeSequenceSend_BounceTask): the ball model
-- hops twice and settles while it spins.
function NpcTradeState:_stepSendBounce()
  local bounce = self._bounce
  if bounce == nil then
    return
  end
  local balloon = self._balloon
  if bounce.landed ~= true then
    balloon.y = balloon.y + bounce.speed / FX32_ONE
    bounce.speed = bounce.speed - 1920
    if bounce.speed < 0 and balloon.y <= -4 then
      balloon.y = -4
      bounce.speed = -math.floor(bounce.speed * 44 / 100)
      if bounce.speed < 4000 then
        bounce.landed = true
      end
      self:_sound("SEQ_SE_DP_KON")
      bounce.bounces = bounce.bounces + 1
      if bounce.bounces == 1 then
        bounce.spin = 176
      elseif bounce.bounces == 3 then
        bounce.spin = bounce.spin + 80
      end
    end
  end
  balloon.rotation.x = balloon.rotation.x + bounce.spin
  balloon.rotation.z = balloon.rotation.z - bounce.spin
  balloon.x = balloon.x + bounce.spin * 5 / FX32_ONE
  balloon.z = balloon.z + bounce.spin * 5 / FX32_ONE
  if bounce.landed == true then
    bounce.spin = bounce.spin - 14
    bounce.frames = bounce.frames + 1
    if bounce.frames > 30 then
      self._bounce = nil
    end
  end
end

-- The depart scene's flight task (TradeSequenceDepart_FlightTask_*), advanced
-- one source frame per tick.
function NpcTradeState:_stepDepartFlight()
  local flight = self._flight
  if flight == nil then
    return
  end
  local stage = assert(flight.stage --[[@as string]])
  if stage == "appear" then
    if flight.frames ~= 0 then
      flight.height = flight.height + flight.speed
      self._balloon.y = flight.height / FX32_ONE
      flight.frames = flight.frames - 1
      if flight.frames <= 0 then
        flight.acceleration = 0.125 * FX32_ONE
        flight.speed = 0
        self:_setFlightRadius(flight, 4 * FX32_ONE, 4 * FX32_ONE, 60)
        self:_setFlightSpin(flight, 1, -0x800, 30)
        flight.flyingAway = true
        flight.stage = "flyAway"
      end
    end
    self:_updateDepartFlight(flight)
  elseif stage == "flyAway" then
    if flight.outOfView ~= true then
      flight.speed = flight.speed + flight.acceleration
      flight.height = flight.height + flight.speed
      self._balloon.y = flight.height / FX32_ONE
      self:_updateDepartFlight(flight)
      if not pointInView(self._camera, self._balloon.x, self._balloon.y, self._balloon.z) then
        self._balloon.visible = false
        flight.outOfView = true
      end
    end
  elseif stage == "rise" then
    self:_updateDepartFlight(flight)
    if flight.frames ~= 0 then
      flight.height = flight.height + flight.speed
      self._balloon.y = flight.height / FX32_ONE
      flight.frames = flight.frames - 1
      if flight.frames == 0 then
        flight.stage = "hover"
      end
    end
  elseif stage == "hover" then
    self:_updateDepartFlight(flight)
    flight.frames = flight.frames + 1
    if flight.frames > 110 then
      flight.speed = (-58.5 * FX32_ONE - flight.height) / 53
      flight.frames = 53
      flight.stage = "sink"
    end
  elseif stage == "sink" then
    self:_updateDepartFlight(flight)
    if flight.frames ~= 0 then
      flight.height = flight.height + flight.speed
      self._balloon.y = flight.height / FX32_ONE
      flight.frames = flight.frames - 1
      if flight.frames == 0 then
        flight.stage = "pause"
      end
    end
  elseif stage == "pause" then
    self:_updateDepartFlight(flight)
    flight.frames = flight.frames + 1
    if flight.frames > 1 then
      flight.speed = 32 * FX32_ONE
      flight.stage = "leave"
    end
  elseif stage == "leave" then
    if flight.outOfView ~= true then
      self:_updateDepartFlight(flight)
      flight.height = flight.height + flight.speed
      self._balloon.y = flight.height / FX32_ONE
      if not pointInView(self._camera, self._balloon.x, self._balloon.y, self._balloon.z) then
        flight.outOfView = true
      end
    end
  end
end

---@param flight table<string, unknown>
---@param target integer
---@param frames integer
function NpcTradeState:_setFlightAngleSpeed(flight, target, frames)
  if frames ~= 0 then
    flight.angleSpeedStep = math.floor((target - flight.angleSpeed) / frames)
    flight.angleSpeed = flight.angleSpeed + flight.angleSpeedStep
  else
    flight.angleSpeed = target
  end
  flight.angleSpeedTarget = target
  flight.angleSpeedFrames = frames
end

---@param flight table<string, unknown>
---@param radiusX number
---@param radiusZ number
---@param frames integer
function NpcTradeState:_setFlightRadius(flight, radiusX, radiusZ, frames)
  if frames ~= 0 then
    flight.radiusXStep = math.floor((radiusX - flight.radiusX) / frames)
    flight.radiusZStep = math.floor((radiusZ - flight.radiusZ) / frames)
    flight.radiusX = flight.radiusX + flight.radiusXStep
    flight.radiusZ = flight.radiusZ + flight.radiusZStep
    flight.radiusXTarget = radiusX
    flight.radiusZTarget = radiusZ
  end
  flight.radiusFrames = frames
end

---@param flight table<string, unknown>
---@param axis integer
---@param target integer
---@param frames integer
function NpcTradeState:_setFlightSpin(flight, axis, target, frames)
  local spins = assert(flight.spins --[[@as table[] ]])
  if frames ~= 0 then
    spins[axis].step = math.floor((target - spins[axis].speed) / frames)
  end
  spins[axis].target = target
  spins[axis].frames = frames
end

-- TradeSequenceDepart_UpdateFlight: the ellipse orbit, the angle speed
-- recursion and the three spin axes.
---@param flight table<string, unknown>
function NpcTradeState:_updateDepartFlight(flight)
  if flight.angleSpeedFrames ~= 0 then
    flight.angleSpeedFrames = flight.angleSpeedFrames - 1
    if flight.angleSpeedFrames ~= 0 then
      flight.angleSpeed = flight.angleSpeed + flight.angleSpeedStep
    else
      flight.angleSpeed = flight.angleSpeedTarget
    end
  end
  flight.angle = flight.angle + flight.angleSpeed
  local degrees = math.floor((flight.angle % U16) / 182)
  if degrees >= 360 then
    degrees = degrees - 360
  end
  if flight.radiusFrames ~= 0 then
    flight.radiusX = flight.radiusX + flight.radiusXStep
    flight.radiusZ = flight.radiusZ + flight.radiusZStep
    flight.radiusFrames = flight.radiusFrames - 1
    if flight.radiusFrames == 0 then
      flight.radiusX = flight.radiusXTarget
      flight.radiusZ = flight.radiusZTarget
    end
  end
  local center = assert(flight.center --[[@as table]])
  self._balloon.x = (center.x + fxMulRound(cosDegFixed(degrees), flight.radiusX)) / FX32_ONE
  self._balloon.z = (center.z + fxMulRound(sinDegFixed(degrees), flight.radiusZ)) / FX32_ONE
  self._balloon.rotation.y = self._balloon.rotation.y + math.floor(flight.angleSpeed)
  local spins = assert(flight.spins --[[@as table[] ]])
  for index = 1, 3 do
    local spin = spins[index]
    if spin.frames ~= 0 then
      spin.frames = spin.frames - 1
      if spin.frames == 0 then
        spin.speed = spin.target
      else
        spin.speed = spin.speed + spin.step
      end
    end
  end
  self._balloon.rotation.x = self._balloon.rotation.x + spins[1].speed
  self._balloon.rotation.y = self._balloon.rotation.y + math.floor(spins[2].speed)
  self._balloon.rotation.z = self._balloon.rotation.z + spins[3].speed
end

-- The receive scene's ball bounce task (TradeSequenceReceive_BounceTask).
function NpcTradeState:_stepReceiveBounce()
  local bounce = self._bounce
  if bounce == nil then
    return
  end
  local balloon = self._balloon
  if bounce.spinFrames ~= 0 then
    bounce.spinSpeed = bounce.spinSpeed + bounce.spinStep
    bounce.spinFrames = bounce.spinFrames - 1
    if bounce.spinFrames == 0 then
      bounce.spinSpeed = bounce.spinTarget
    end
  end
  balloon.rotation.y = balloon.rotation.y + bounce.spinSpeed
  local stage = assert(bounce.stage --[[@as string]])
  if stage == "fadeIn" then
    if bounce.alphaFrames ~= 0 then
      bounce.alpha = bounce.alpha + bounce.alphaStep
      bounce.alphaFrames = bounce.alphaFrames - 1
      balloon.alpha = math.floor(bounce.alpha / FX32_ONE)
    else
      balloon.alpha = 31
      bounce.stage = "startSpin"
    end
  elseif stage == "startSpin" then
    bounce.spinStep = math.floor((384 - bounce.spinSpeed) / 30)
    bounce.spinFrames = 30
    bounce.timer = 0
    bounce.stage = "delay"
  elseif stage == "delay" then
    bounce.timer = bounce.timer + 1
    if bounce.timer > 10 then
      bounce.speed = 0
      bounce.stage = "fall"
    end
  elseif stage == "fall" then
    balloon.y = balloon.y + bounce.speed / FX32_ONE
    bounce.speed = bounce.speed - 1920
    if balloon.y < -11 then
      self:_sound("SEQ_SE_DP_KON")
      bounce.speed = -bounce.speed
      self:_startBrightness(8)
      bounce.stage = "rise"
    end
  elseif stage == "rise" then
    balloon.y = balloon.y + bounce.speed / FX32_ONE
    if balloon.y >= 19 then
      balloon.y = 19
    end
    if balloon.y == 19 then
      bounce.stage = "waitBrightness"
    end
  elseif stage == "waitBrightness" then
    if self:_brightnessDone() then
      self._bounce = nil
    end
  end
end

-- The recede scene's flight (TradeSequenceRecede_FlightTask).
function NpcTradeState:_stepRecedeFlight()
  local flight = self._flight
  if flight == nil then
    return
  end
  if flight.elapsed < 60 then
    flight.elapsed = flight.elapsed + 1
  end
  local center = assert(flight.center --[[@as table]])
  local stage = assert(flight.stage --[[@as string]])
  local function advance()
    center.y = center.y + flight.centerStepY
    center.z = center.z + flight.centerStepZ
    self:_updateRecedeFlight(flight)
  end
  if stage == "enterView" then
    advance()
    if pointInView(self._camera, self._balloon.x, self._balloon.y, self._balloon.z) then
      flight.stage = "leaveView"
    end
  elseif stage == "leaveView" then
    if not pointInView(self._camera, self._balloon.x, self._balloon.y, self._balloon.z) then
      self._camera.angleX = self._camera.angleX + 0x1150
      flight.stage = "fly"
      return
    end
    advance()
  elseif stage == "fly" then
    advance()
    if flight.elapsed >= 60 then
      flight.radiusXStep = math.floor((0.5 * FX32_ONE - flight.radiusX) / 12)
      flight.radiusYStep = math.floor((0.5 * FX32_ONE - flight.radiusY) / 12)
      flight.scaleStep = math.floor((0.125 * FX32_ONE - flight.scale) / 12)
      flight.stepFrames = 12
      flight.timer = 0
      flight.stage = "shrink"
    end
  elseif stage == "shrink" then
    self:_updateRecedeFlight(flight)
    flight.timer = flight.timer + 1
    if flight.timer >= 12 then
      self._balloon.visible = false
      flight.timer = 0
      flight.stage = "end"
    end
  elseif stage == "end" then
    flight.timer = flight.timer + 1
    if flight.timer > 8 then
      self._flight = nil
    end
  end
end

---@param flight table<string, unknown>
function NpcTradeState:_updateRecedeFlight(flight)
  local degrees = math.floor((flight.angle % U16) / 182)
  if degrees >= 360 then
    degrees = degrees - 360
  end
  flight.angle = flight.angle + flight.angleSpeed
  if flight.stepFrames ~= 0 then
    flight.radiusX = flight.radiusX + flight.radiusXStep
    flight.radiusY = flight.radiusY + flight.radiusYStep
    flight.scale = flight.scale + flight.scaleStep
    self._balloon.scale = flight.scale / FX32_ONE
    flight.stepFrames = flight.stepFrames - 1
  end
  local center = assert(flight.center --[[@as table]])
  self._balloon.x = (center.x + fxMulRound(cosDegFixed(degrees), flight.radiusX)) / FX32_ONE
  self._balloon.y = (center.y + fxMulRound(sinDegFixed(degrees), flight.radiusY)) / FX32_ONE
  self._balloon.z = center.z / FX32_ONE
  self._balloon.rotation.x = self._balloon.rotation.x + 0x300
end

-- The approach scene's flight (TradeSequenceApproach_FlightTask).
function NpcTradeState:_stepApproachFlight()
  local flight = self._flight
  if flight == nil then
    return
  end
  if flight.frames < 70 then
    flight.frames = flight.frames + 1
  end
  local center = assert(flight.center --[[@as table]])
  local stage = assert(flight.stage --[[@as string]])
  if stage == "start" then
    self:_updateApproachFlight(flight)
    flight.frames = flight.frames + 1
    if flight.frames >= 12 then
      flight.frames = 0
      flight.stage = "leaveView"
    end
  elseif stage == "leaveView" then
    if not pointInView(self._camera, self._balloon.x, self._balloon.y, self._balloon.z) then
      self._camera.angleX = self._camera.angleX + 0xEEB0
      flight.stage = "fly"
    else
      center.y = center.y + flight.centerStepY
      center.z = center.z + flight.centerStepZ
      self:_updateApproachFlight(flight)
    end
  elseif stage == "fly" then
    center.y = center.y + flight.centerStepY
    center.z = center.z + flight.centerStepZ
    self:_updateApproachFlight(flight)
    if flight.frames >= 70 then
      self._balloon.visible = false
      flight.timer = 0
      flight.stage = "end"
    end
  elseif stage == "end" then
    flight.timer = flight.timer + 1
    if flight.timer > 8 then
      self._flight = nil
    end
  end
end

---@param flight table<string, unknown>
function NpcTradeState:_updateApproachFlight(flight)
  local degrees = math.floor((flight.angle % U16) / 182)
  if degrees >= 360 then
    degrees = degrees - 360
  end
  flight.angle = flight.angle - flight.angleSpeed
  if flight.stepFrames ~= 0 then
    flight.stepFrames = flight.stepFrames - 1
    if flight.stepFrames ~= 0 then
      flight.radiusX = flight.radiusX + flight.radiusXStep
      flight.radiusY = flight.radiusY + flight.radiusYStep
      flight.scale = flight.scale + flight.scaleStep
    else
      flight.radiusX = flight.radiusXTarget
      flight.radiusY = flight.radiusYTarget
      flight.scale = flight.scaleTarget
    end
    self._balloon.scale = flight.scale / FX32_ONE
  end
  local center = assert(flight.center --[[@as table]])
  self._balloon.x = (center.x + fxMulRound(cosDegFixed(degrees), flight.radiusX)) / FX32_ONE
  self._balloon.y = (center.y + fxMulRound(sinDegFixed(degrees), flight.radiusY)) / FX32_ONE
  self._balloon.z = center.z / FX32_ONE
  self._balloon.rotation.x = self._balloon.rotation.x - 0x300
end

-- The arrive scene's lower task: the ball descends to its final height.
function NpcTradeState:_stepArriveLower()
  local lower = self._lower
  if lower == nil then
    return
  end
  if lower.frames ~= 0 then
    lower.position = lower.position + lower.step / FX32_ONE
    self._balloon.y = lower.position
    lower.frames = lower.frames - 1
    return
  end
  self._balloon.y = 50
  self._lower = nil
end

-- ---------------------------------------------------------------------------

local scenes = NpcTradeState.SCENES

-- Scene 0 (trade_sequence_send.c): the sent record's picture and its two
-- lines, then a brightness flash, the burst sprite and the bouncing ball.
scenes[1] = {
  phase = PokemonCareInterface.TRADE_PHASES.SEND,
  sprites = {
    { sequence = 0, x = 128, y = 90 },
    { sequence = 1, x = 128, y = 100 },
  },
  enter = function(self)
    self._pictures = { { subject = "outgoing", visible = true, x = 128, y = 80 } }
  end,
  step = function(self)
    self._timer = self._timer + 1
    local state = self._state
    if state == 0 then
      -- WaitFadeIn: sixteen-frame fade, then the send effect appears.
      if self._timer >= 16 then
        self:_showSprite(2)
        self._state, self._timer = 1, 0
      end
    elseif state == 1 then
      -- ShowMessages / PRINT_SENDING (timer > 10).
      if self._timer > 10 then
        self._messageId = 0
        self._state, self._timer = 2, 0
      end
    elseif state == 2 then
      -- PRINT_BYE_BYE (timer > 60) with the sent record's cry.
      if self._timer > 60 then
        self._messageId = 1
        self:_cry("outgoing")
        self._state, self._timer = 3, 0
      end
    elseif state == 3 then
      -- CLEAR (timer > 60).
      if self._timer > 60 then
        self._messageId = nil
        self._state, self._timer = 4, 0
      end
    elseif state == 4 then
      -- WAIT_END (timer > 20).
      if self._timer > 20 then
        self._state, self._timer = 5, 0
      end
    elseif state == 5 then
      -- ReplaceMonWithModel / START_FLASH.
      self:_sound("SEQ_SE_DP_KOUKAN01")
      self:_startBrightness(12)
      self._state, self._timer = 6, 0
    elseif state == 6 then
      -- WAIT_FLASH: the picture goes, the burst replaces it.
      if self:_brightnessDone() then
        for _, picture in ipairs(self._pictures) do
          picture.visible = false
        end
        self:_showSprite(1)
        self._state, self._timer = 7, 0
      end
    elseif state == 7 then
      -- WAIT_BALL_ANIM: the burst animation ends, the model appears.
      if self._timer >= EFFECT_SEQUENCE_TICKS then
        self._balloon.visible = true
        self:_startBrightness(16)
        self._bounce = { speed = 0x2F60, bounces = 0, spin = 0, landed = false, frames = 0 }
        self._state, self._timer = 8, 0
      end
    elseif state == 8 then
      self:_stepSendBounce()
      -- WAIT_BOUNCES: two bounces (or a landed model) start the fade-out.
      if self._bounce == nil or self._bounce.bounces >= 2 then
        self._state, self._timer = 9, 0
      end
    elseif state == 9 then
      self:_stepSendBounce()
      -- WAIT_FADE_OUT: the source's 24-frame fade, then the bounce settles.
      if self._timer >= 24 and self._bounce == nil then
        return true
      end
    end
    return false
  end,
}

-- Scene 1 (trade_sequence_depart.c): the ball flies off the top screen, rises
-- through the bottom one while the light streaks fall, then the screen scrolls
-- and fades.
scenes[2] = {
  phase = PokemonCareInterface.TRADE_PHASES.DEPART,
  scroll = "depart",
  enter = function(self)
    self._camera.angleX = 0xEBE0
    self._balloon.x = 0
    self._balloon.y = -55.5
    self._balloon.z = 0
    self._balloon.scale = 1.75
    self._scrollY = -256
    self:_startZoom(0x480, FX32_ONE, 0, 1, 0x128)
    self:_startPulses(1)
  end,
  step = function(self)
    self._timer = self._timer + 1
    local state = self._state
    if state == 0 then
      -- WaitBgZoom: the eight-frame fade and the zoom task.
      local zoom = self._zoom
      if self._timer >= 8 and zoom ~= nil and zoom.finished == true then
        self._state, self._timer = 1, 0
      end
    elseif state == 1 then
      -- FlyOffTopScreen / INIT then DELAY (timer > 8): the ball fades in and
      -- starts its flight.
      if self._timer > 8 then
        self:_startAlphaFade(0, 31, 24)
        self._balloon.visible = true
        self._flight = {
          stage = "appear",
          center = { x = 0, y = -55.5 * FX32_ONE, z = 0 },
          height = -55.5 * FX32_ONE,
          speed = (-8 * FX32_ONE + 55.5 * FX32_ONE) / 30,
          acceleration = 0,
          radiusX = 0,
          radiusZ = 0,
          radiusXStep = 0,
          radiusZStep = 0,
          radiusXTarget = 0,
          radiusZTarget = 0,
          radiusFrames = 0,
          angle = 0,
          angleSpeed = 0x4000,
          angleSpeedStep = 0,
          angleSpeedTarget = 0,
          angleSpeedFrames = 0,
          spins = {
            { speed = 0, step = 0, target = 0, frames = 0 },
            { speed = 0, step = 0, target = 0, frames = 0 },
            { speed = 0, step = 0, target = 0, frames = 0 },
          },
          outOfView = false,
          flyingAway = false,
          frames = 30,
        }
        self:_setFlightAngleSpeed(self._flight, 0xD00, 30)
        self:_setFlightRadius(self._flight, 41 * FX32_ONE, 20 * FX32_ONE, 30)
        self._state, self._timer = 2, 0
      end
    elseif state == 2 then
      self:_stepDepartFlight()
      -- WAIT_FLYING_AWAY.
      if self._flight ~= nil and self._flight.flyingAway == true then
        self._state = 3
      end
    elseif state == 3 then
      self:_stepDepartFlight()
      -- WAIT_OUT_OF_VIEW.
      if self._flight ~= nil and self._flight.outOfView == true then
        self._state = 4
      end
    elseif state == 4 then
      -- SWAP_SCREENS: the bottom screen's map becomes the top screen's.
      self._scrollY = -256
      self._state, self._timer = 5, 0
    elseif state == 5 then
      -- FlyThroughBottomScreen / RESTART_FLIGHT: the ball rises from below
      -- with an orthographic camera and twice its scale.
      local flight = self._flight
      assert(flight ~= nil, "the restart follows the departed flight")
      flight.stage = "rise"
      flight.outOfView = false
      self._camera.angleX = 0
      self._camera.angleY = 0
      self._camera.perspectiveType = 1
      flight.speed = 0x58CC
      flight.height = 0x58CC - 128 * FX32_ONE
      flight.frames = 20
      self._balloon.y = flight.height / FX32_ONE
      self:_setFlightRadius(flight, 0, 0, 20)
      self:_setFlightSpin(flight, 2, -flight.angleSpeed, 30)
      self:_setFlightSpin(flight, 3, 0x100, 50)
      self._balloon.scale = 2
      self._balloon.visible = true
      self._state, self._timer = 6, 0
    elseif state == 6 then
      self:_stepDepartFlight()
      -- STOP_PULSES (timer > 2).
      if self._timer > 2 then
        self:_stopPulses()
        self._state, self._timer = 7, 0
      end
    elseif state == 7 then
      self:_stepDepartFlight()
      -- WAIT_PULSES: the scroll starts once the pulses drained.
      if not self._pulses.running then
        self:_startDepartScroll(-256)
        self._state, self._timer = 8, 0
      end
    elseif state == 8 then
      self:_stepDepartFlight()
      -- WAIT_OUT_OF_VIEW: the ball leaves the view at frame forty.
      if self._timer == 40 then
        self:_sound("SEQ_SE_DP_KOUKAN10")
      end
      if self._flight == nil or self._flight.outOfView == true then
        self._state, self._timer = 9, 0
      end
    elseif state == 9 then
      -- WAIT_FADE_OUT: the four-frame white fade.
      if self._timer >= 4 then
        return true
      end
    end
    return false
  end,
}

-- Scene 2 (trade_sequence_recede.c): the ball spirals across the top screen,
-- shrinks into the distance; then the effect sprite plays and the scene fades.
scenes[3] = {
  phase = PokemonCareInterface.TRADE_PHASES.RECEDE,
  sprites = {
    { sequence = 3, x = 128, y = 96 },
  },
  enter = function(self)
    self._camera.angleX = 0x18E3
    self._camera.fov = 0x7D2
  end,
  step = function(self)
    self._timer = self._timer + 1
    local state = self._state
    if state == 0 then
      -- Run / DELAY (timer > 10): the flight starts.
      if self._timer > 10 then
        self:_sound("SEQ_SE_DP_KOUKAN06")
        self._balloon.rotation.x = 0x2000
        self._balloon.rotation.y = -0x2000
        self._balloon.scale = 1
        self._balloon.visible = true
        self._flight = {
          stage = "enterView",
          center = { x = 0, y = -0xAF200, z = 226 * FX32_ONE },
          angle = -10128,
          angleSpeed = -2736,
          centerStepY = 0x134C4,
          centerStepZ = -0xB2AA,
          elapsed = 0,
          timer = 0,
          scale = FX32_ONE,
          radiusX = 18.5 * FX32_ONE,
          radiusY = 24.75 * FX32_ONE,
          radiusXStep = 0,
          radiusYStep = 0,
          scaleStep = 0,
          stepFrames = 0,
        }
        self._state, self._timer = 1, 0
      end
    elseif state == 1 then
      self:_stepRecedeFlight()
      -- WAIT_FLIGHT: the flight ends, the effect sprite appears.
      if self._flight == nil then
        self:_sound("SEQ_SE_DP_KOUKAN07")
        self:_showSprite(1)
        self._state, self._timer = 2, 0
      end
    elseif state == 2 then
      -- WAIT_SPRITE_ANIM.
      if self._timer >= EFFECT_SEQUENCE_TICKS then
        self._state, self._timer = 3, 0
      end
    elseif state == 3 then
      -- WAIT_FADE_OUT (sixteen frames).
      if self._timer >= 16 then
        return true
      end
    end
    return false
  end,
}

-- Scene 3 (trade_sequence_exchange.c): the two pictures slide past each other,
-- then the screen fades to white.
--
-- The pictures ride a 256x512 text background whose tilemaps sit at tile
-- columns 20 (sent) and 2 (received). The scene scrolls that background with
-- BgSetPosTextAndCommit(..., BG_POS_OP_SET_Y, offset & 0x1FF), so the picture's
-- screen y is (512 - (offset & 0x1FF)) mod 512: the sent picture rises from
-- y=384 to y=48 over the sixty slide frames and the received one from y=432,
-- and the source's own final SetMonPicPositions(-48, -48) lands both at y=48.
scenes[4] = {
  phase = PokemonCareInterface.TRADE_PHASES.EXCHANGE,
  enter = function(self)
    self._pictures = {
      { subject = "incoming", visible = true, x = 56, y = 432 },
      { subject = "outgoing", visible = true, x = 200, y = 384 },
    }
  end,
  step = function(self)
    self._timer = self._timer + 1
    local state = self._state
    if state == 0 then
      -- Slide / WAIT_FADE_IN (eight frames).
      if self._timer >= 8 then
        self._slide = { frames = 60, sentY = -384 * FX32_ONE, receivedY = 80 * FX32_ONE }
        self._state, self._timer = 1, 0
      end
    elseif state == 1 then
      local slide = assert(self._slide, "the slide state owns its task")
      local frames = assert(slide.frames --[[@as integer]])
      if frames > 0 then
        slide.frames = frames - 1
        slide.sentY = assert(slide.sentY --[[@as number]]) + 0x5999
        slide.receivedY = assert(slide.receivedY --[[@as number]]) - 0x2222
        self:_placeExchangePictures(slide.sentY, slide.receivedY)
      else
        self:_placeExchangePictures(-48 * FX32_ONE, -48 * FX32_ONE)
        self:_sound("SEQ_SE_DP_KOUKAN03")
        self._state, self._timer = 2, 0
      end
    elseif state == 2 then
      -- WAIT_FADE_OUT (sixteen frames).
      if self._timer >= 16 then
        return true
      end
    end
    return false
  end,
}

-- The exchange pictures' screen y from the source's background y offset
-- (offset & 0x1FF scrolled through a 512-pixel map).
---@param sentY number
---@param receivedY number
function NpcTradeState:_placeExchangePictures(sentY, receivedY)
  local function screenY(offset)
    local wrapped = math.floor(offset / FX32_ONE) % 512
    return (512 - wrapped) % 512
  end
  for _, picture in ipairs(self._pictures) do
    if picture.subject == "outgoing" then
      picture.y = screenY(sentY)
    else
      picture.y = screenY(receivedY)
    end
  end
end

-- Scene 4 (trade_sequence_approach.c): the effect sprite plays, then the ball
-- spirals in from below and leaves the view.
scenes[5] = {
  phase = PokemonCareInterface.TRADE_PHASES.APPROACH,
  sprites = {
    { sequence = 3, x = 128, y = 96 },
  },
  enter = function(self)
    self._camera.angleX = 0x18E3 + 0x1150
    self._camera.fov = 0x7D2
  end,
  step = function(self)
    self._timer = self._timer + 1
    local state = self._state
    if state == 0 then
      -- WAIT_FADE_IN (eight frames) then the sprite plays.
      if self._timer >= 8 then
        self:_showSprite(1)
        self._state, self._timer = 1, 0
      end
    elseif state == 1 then
      -- WAIT_SPRITE_ANIM: its end starts the flight.
      if self._timer >= EFFECT_SEQUENCE_TICKS then
        self:_sound("SEQ_SE_DP_KOUKAN05")
        self._balloon.rotation.x = 0x2000
        self._balloon.rotation.y = -0x2000
        self._balloon.scale = 0.125
        self._balloon.visible = true
        self._flight = {
          stage = "start",
          center = { x = 0, y = 982.75 * FX32_ONE, z = -444 * FX32_ONE },
          angle = -10128,
          angleSpeed = -2736,
          centerStepY = -0x10D3A,
          centerStepZ = 0x936D,
          frames = 0,
          timer = 0,
          scale = 0.125 * FX32_ONE,
          radiusX = 0.5 * FX32_ONE,
          radiusY = 0.5 * FX32_ONE,
          radiusXStep = (74 * 1024 - 0.5 * FX32_ONE) / 12,
          radiusYStep = (99 * 1024 - 0.5 * FX32_ONE) / 12,
          scaleStep = (FX32_ONE - 0.125 * FX32_ONE) / 12,
          radiusXTarget = 74 * 1024,
          radiusYTarget = 99 * 1024,
          scaleTarget = FX32_ONE,
          stepFrames = 12,
        }
        self._state, self._timer = 2, 0
      end
    elseif state == 2 then
      self:_stepApproachFlight()
      -- WAIT_FLIGHT.
      if self._flight == nil then
        self._state, self._timer = 3, 0
      end
    elseif state == 3 then
      -- WAIT_FADE_OUT (sixteen frames).
      if self._timer >= 16 then
        return true
      end
    end
    return false
  end,
}

-- Scene 5 (trade_sequence_arrive.c): the spinning ball lands, the map scrolls
-- into place, the pulses walk, and the background zooms out.
scenes[6] = {
  phase = PokemonCareInterface.TRADE_PHASES.ARRIVE,
  scroll = "arrive",
  enter = function(self)
    self._camera.perspectiveType = 1
    self._balloon.x = 0
    self._balloon.y = 140
    self._balloon.z = 0
    self._balloon.scale = 2
    self._balloon.visible = true
    self._scrollY = -384
  end,
  step = function(self)
    self._timer = self._timer + 1
    self._balloon.rotation.y = self._balloon.rotation.y + 0x1000
    local state = self._state
    if state == 0 then
      -- LowerAndFade / WAIT_FADE_IN: the lower task starts.
      if self._timer >= 8 then
        self._lower = {
          position = self._balloon.y,
          step = (50 - self._balloon.y) * FX32_ONE / 16,
          frames = 16,
        }
        self._state, self._timer = 1, 0
      end
    elseif state == 1 then
      self:_stepArriveLower()
      -- DELAY (timer > 8): the map scrolls into place.
      if self._timer > 8 then
        self:_startArriveScroll(-384)
        self._state, self._timer = 2, 0
      end
    elseif state == 2 then
      self:_stepArriveLower()
      -- WAIT_SCROLL: both tasks finished.
      if self._scroll == nil and self._lower == nil then
        self._state, self._timer = 3, 0
      end
    elseif state == 3 then
      -- START_PULSES (direction -1).
      self:_startPulses(-1)
      self._state, self._timer = 4, 0
    elseif state == 4 then
      -- DELAY_FADE (timer > 30): the ball fades out.
      if self._timer > 30 then
        self:_startAlphaFade(31, 0, 40)
        self._state, self._timer = 5, 0
      end
    elseif state == 5 then
      -- WAIT_ALPHA_FADE.
      if self._fade == nil then
        self:_stopPulses()
        self._state, self._timer = 6, 0
      end
    elseif state == 6 then
      -- WAIT_PULSES.
      if not self._pulses.running then
        self._state, self._timer = 7, 0
      end
    elseif state == 7 then
      -- ZoomOut / ZOOM_START.
      self:_startZoom(FX32_ONE, 1024, 1, 1, 0x128)
      self._state, self._timer = 8, 0
    elseif state == 8 then
      -- ZOOM_DELAY (timer > 13) then the eight-frame fade to black.
      if self._timer > 13 then
        self._state, self._timer = 9, 0
      end
    elseif state == 9 then
      -- ZOOM_WAIT_FADE_OUT.
      local zoom = self._zoom
      if self._timer >= 8 and zoom ~= nil and zoom.finished == true then
        return true
      end
    end
    return false
  end,
}

-- Scene 6 (trade_sequence_receive.c): the ball bounces in, the received record
-- appears with its cry and its two lines, then the scene fades out.
scenes[7] = {
  phase = PokemonCareInterface.TRADE_PHASES.RECEIVE,
  sprites = {
    { sequence = 2, x = 128, y = 90 },
    { sequence = 1, x = 128, y = 100 },
  },
  enter = function(self)
    self._balloon.y = 19
    self._balloon.z = 120
    self._balloon.rotation.y = -0x1000
    self._balloon.alpha = 0
    self._pictures = { { subject = "incoming", visible = false, x = 128, y = 80 } }
  end,
  step = function(self)
    self._timer = self._timer + 1
    local state = self._state
    if state == 0 then
      -- WaitFadeIn (sixteen frames) then the receive effect.
      if self._timer >= 16 then
        self:_showSprite(2)
        self._state, self._timer = 1, 0
      end
    elseif state == 1 then
      -- ShowMon / START_BOUNCE.
      self._balloon.visible = true
      self._bounce = {
        stage = "fadeIn",
        alpha = 0,
        alphaStep = 0x18CC,
        alphaFrames = 20,
        spinSpeed = 0x1000,
        spinStep = 0,
        spinTarget = 0,
        spinFrames = 0,
        speed = 0,
        timer = 0,
      }
      self._state, self._timer = 2, 0
    elseif state == 2 then
      self:_stepReceiveBounce()
      -- WAIT_BOUNCE: the burst takes over and the ball goes.
      if self._bounce == nil then
        self:_showSprite(1)
        self._balloon.visible = false
        self._state, self._timer = 3, 0
      end
    elseif state == 3 then
      -- DELAY (timer > 10): the received picture appears with the flash.
      if self._timer > 10 then
        for _, picture in ipairs(self._pictures) do
          picture.visible = true
        end
        self:_startBrightness(12)
        self._state, self._timer = 4, 0
      end
    elseif state == 4 then
      -- WAIT_BRIGHTNESS: the received record's cry.
      if self:_brightnessDone() then
        self:_cry("incoming")
        self._state, self._timer = 5, 0
      end
    elseif state == 5 then
      -- WAIT_END (timer > 30).
      if self._timer > 30 then
        self._state, self._timer = 6, 0
      end
    elseif state == 6 then
      -- ShowMessages / PRINT_RECEIVED (timer > 10) with its fanfare.
      if self._timer > 10 then
        self._messageId = 2
        self:_fanfare("SEQ_ME_SHINKAOME")
        self._state, self._timer = 7, 0
      end
    elseif state == 7 then
      -- PRINT_TAKE_CARE (sixty frames).
      if self._timer >= 60 then
        self._messageId = 3
        self._state, self._timer = 8, 0
      end
    elseif state == 8 then
      -- CLEAR (sixty frames).
      if self._timer >= 60 then
        self._messageId = nil
        self._state, self._timer = 9, 0
      end
    elseif state == 9 then
      -- FADE_OUT (timer > 10).
      if self._timer > 10 then
        self._state, self._timer = 10, 0
      end
    elseif state == 10 then
      -- WAIT_FADE_OUT (sixteen frames).
      if self._timer >= 16 then
        return true
      end
    end
    return false
  end,
}

return NpcTradeState
