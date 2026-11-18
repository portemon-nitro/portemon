-- Shared seams for source-timed native battle animation bodies. Each body in
-- this lane reproduces one overlay-07 battle animation callback whose native
-- implementation owns a fixed internal timeline instead of reading timing
-- words from the animation script (battle_anim_funcs.c,
-- battle_anim_effects.c, battle_anim_move_effects.c in the pinned
-- pret/pokeheartgold tree). This module owns the picture-overlay lifecycle,
-- the scene write/restore journal, and the fixed-point motion primitives the
-- bodies share; it never reads script words or producer tables.

local PresentationFxMath = require("libs.hgss.src.presentation.PresentationFxMath")

local Support = {}

Support.VALID_STATES = {
  pending = true,
  running = true,
  complete = true,
  cancelled = true,
}

Support.FX32_ONE = 4096
Support.FX32_SHIFT = 12

---@param kind string task kind under diagnosis
---@param detail string violated construction invariant
function Support.malformed(kind, detail)
  error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " " .. detail, 0)
end

---@param services table<string, unknown>|nil factory services record
---@param kind string task kind under diagnosis
---@return table<string, unknown> scene behind the owned picture overlay
function Support.checkScene(services, kind)
  if type(services) ~= "table" then
    Support.malformed(kind, "constructs without its services record")
  end
  local scene = services --[[@as table<string, unknown>]].scene
  if type(scene) ~= "table" then
    Support.malformed(kind, "constructs without its scene")
  end
  if type(scene.applyTaskPicturePatch) ~= "function" or type(scene.removeTaskPicturePatch) ~= "function" then
    Support.malformed(kind, "constructs without the scene picture overlay seam")
  end
  return scene --[[@as table<string, unknown>]]
end

---@param args table<string, unknown>|nil instruction-derived construction arguments
---@param kind string task kind under diagnosis
---@return table<string, unknown> compiled parameter record, never nil
function Support.parameters(args, kind)
  if args ~= nil and type(args) ~= "table" then
    Support.malformed(kind, "carries instruction arguments as a record")
  end
  local parameters = args ~= nil and args.parameters or nil
  if parameters == nil then
    return {}
  end
  if type(parameters) ~= "table" or parameters[1] ~= nil then
    Support.malformed(kind, "carries its parameters as a record")
  end
  return parameters --[[@as table<string, unknown>]]
end

-- Semantic picture targets resolving to the occurrence attacker side. Each
-- body resolves its own activation here so every picture it patches is one
-- the occurrence actually presents.
local ATTACKER_PICTURE_NAMES = {
  attacker = true,
  ["active-position-first"] = true,
  ["active-battler"] = true,
  ["active-battler-pair-when-enabled"] = true,
  ["all-battler-positions"] = true,
  ["attacker-related-position-when-paired"] = true,
}

local TARGET_PICTURE_NAMES = {
  target = true,
  ["active-position-second"] = true,
  ["opposing-battler"] = true,
  ["opposing-battler-pair-when-enabled"] = true,
  ["other-battler-positions"] = true,
  ["target-related-position-when-paired"] = true,
  ["first-battler-state-one-or-three"] = true,
  ["first-battler-state-five"] = true,
}

---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@return table<string, unknown>? combatant and activation pair behind the owned picture
function Support.activation(args, context)
  local activation = args.activation
  if type(activation) == "table" and type(activation.combatant) == "number" then
    return { combatant = activation.combatant, activation = activation.activation }
  end
  local topology = type(context) == "table" and context.topology or nil
  if type(topology) ~= "table" then
    return nil
  end
  local name = args.battlerTarget
  if type(name) ~= "string" then
    return nil
  end
  if ATTACKER_PICTURE_NAMES[name] == true then
    local attacker = topology.attacker --[[@as table<string, unknown>?]]
    if type(attacker) == "table" and type(attacker.combatant) == "number" then
      return { combatant = attacker.combatant, activation = attacker.activation }
    end
    return nil
  end
  if TARGET_PICTURE_NAMES[name] == true then
    local targets = topology.targets --[[@as table<integer, table<string, unknown>>?]]
    if type(targets) == "table" and type(targets[1]) == "table" and type(targets[1].combatant) == "number" then
      local first = targets[1]
      return { combatant = first.combatant, activation = first.activation }
    end
  end
  return nil
end

---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param kind string task kind under diagnosis
---@return table<string, unknown> combatant and activation pair behind the owned picture
function Support.requiredActivation(args, context, kind)
  local activation = Support.activation(args, context)
  if activation == nil then
    Support.malformed(kind, "addresses a battler picture the occurrence presents")
  end
  return activation --[[@as table<string, unknown>]]
end

---@param value unknown signed native pixel offset under clamping
---@return integer clamped offset in -32768..32767
function Support.clampOffset(value)
  local floored = math.floor(tonumber(value) or 0)
  if floored < -32768 then
    return -32768
  elseif floored > 32767 then
    return 32767
  end
  return floored
end

---@param value unknown native rotation angle index under clamping
---@return integer clamped angle index in 0..65535
function Support.clampRotation(value)
  local floored = math.floor(tonumber(value) or 0)
  if floored < 0 then
    return 0
  elseif floored > 65535 then
    return 65535
  end
  return floored
end

---@param value unknown native crop byte under wrapping
---@return integer wrapped byte in 0..255
function Support.wrapCropByte(value)
  return (math.floor(tonumber(value) or 0) % 256 + 256) % 256
end

---@param value unknown native blend coefficient under clamping
---@return integer clamped coefficient in 0..16
function Support.clampLevel(value)
  local floored = math.floor(tonumber(value) or 0)
  if floored < 0 then
    return 0
  elseif floored > 16 then
    return 16
  end
  return floored
end

---@param value unknown native RGB555 word under splitting
---@return { r: integer, g: integer, b: integer } native color channels
function Support.rgb555(value)
  local word = math.floor(tonumber(value) or 0) % 65536
  return {
    r = math.floor(word / 32) % 32,
    g = math.floor(word / 1024) % 32,
    b = math.floor(word / 32768) % 32,
  }
end

-- BattleAnimUtil_CalcStep: fx32 per-step delta of a start/end pair.
---@param start integer fixed-point start value
---@param finish integer fixed-point end value
---@param ticks integer positive step count
---@return integer fixed-point step
function Support.fxStep(start, finish, ticks)
  assert(type(ticks) == "number" and ticks >= 1, "fixed-point motion names a positive tick count")
  return PresentationFxMath.fxDiv(finish - start, ticks * Support.FX32_ONE)
end

---@class SourceTimedLinearMotion
---@field curX integer fixed-point current horizontal value
---@field curY integer fixed-point current vertical value
---@field x integer whole current horizontal value
---@field y integer whole current vertical value
---@field stepX integer fixed-point horizontal step
---@field stepY integer fixed-point vertical step
---@field remaining integer ticks left behind the motion
local LinearMotion = {}
LinearMotion.__index = LinearMotion

-- BattleAnimUtil_InitLinearMotion: whole-pixel interpolation with the exact
-- native fixed-point step and truncating low-word reads.
---@param startX integer start horizontal value in pixels
---@param endX integer end horizontal value in pixels
---@param startY integer start vertical value in pixels
---@param endY integer end vertical value in pixels
---@param ticks integer positive step count
---@return SourceTimedLinearMotion motion record
function Support.linear(startX, endX, startY, endY, ticks)
  local motion = setmetatable({
    x = math.floor(startX),
    y = math.floor(startY),
    curX = math.floor(startX) * Support.FX32_ONE,
    curY = math.floor(startY) * Support.FX32_ONE,
    stepX = Support.fxStep(math.floor(startX) * Support.FX32_ONE, math.floor(endX) * Support.FX32_ONE, ticks),
    stepY = Support.fxStep(math.floor(startY) * Support.FX32_ONE, math.floor(endY) * Support.FX32_ONE, ticks),
    remaining = ticks,
  }, LinearMotion)
  return motion
end

-- BattleAnimUtil_UpdateLinearMotion: advances one tick and reports whether
-- the motion still had ticks left (false means the native caller retires).
---@param self SourceTimedLinearMotion motion under advancement
---@return boolean active true while the motion had a tick to spend
function LinearMotion:step()
  if self.remaining == 0 then
    return false
  end
  self.curX = self.curX + self.stepX
  self.curY = self.curY + self.stepY
  self.x = math.floor(self.curX / Support.FX32_ONE)
  self.y = math.floor(self.curY / Support.FX32_ONE)
  self.remaining = self.remaining - 1
  return true
end

---@class SourceTimedScaleMotion
---@field curX integer fixed-point current horizontal scale in 1/256 units
---@field curY integer fixed-point current vertical scale in 1/256 units
---@field x integer whole current horizontal scale in 1/256 units
---@field y integer whole current vertical scale in 1/256 units
---@field stepX integer fixed-point horizontal scale step
---@field stepY integer fixed-point vertical scale step
---@field remaining integer ticks left behind the motion
local ScaleMotion = {}
ScaleMotion.__index = ScaleMotion

-- BattleAnimUtil_InitScaleMotionXY: source scale words are 1/100 units and
-- the native motion carries 1/256 scale in fixed point.
---@param startX integer start horizontal scale word
---@param endX integer end horizontal scale word
---@param startY integer start vertical scale word
---@param endY integer end vertical scale word
---@param divisor integer source scale divisor, usually 100
---@param ticks integer positive step count
---@return SourceTimedScaleMotion motion record
function Support.scaleMotion(startX, endX, startY, endY, divisor, ticks)
  assert(type(divisor) == "number" and divisor ~= 0, "scale motion names a nonzero divisor")
  local startScaleX = PresentationFxMath.truncDiv(math.floor(startX) * 256, math.floor(divisor))
  local endScaleX = PresentationFxMath.truncDiv(math.floor(endX) * 256, math.floor(divisor))
  local startScaleY = PresentationFxMath.truncDiv(math.floor(startY) * 256, math.floor(divisor))
  local endScaleY = PresentationFxMath.truncDiv(math.floor(endY) * 256, math.floor(divisor))
  return setmetatable({
    x = startScaleX,
    y = startScaleY,
    curX = startScaleX * Support.FX32_ONE,
    curY = startScaleY * Support.FX32_ONE,
    stepX = Support.fxStep(startScaleX * Support.FX32_ONE, endScaleX * Support.FX32_ONE, ticks),
    stepY = Support.fxStep(startScaleY * Support.FX32_ONE, endScaleY * Support.FX32_ONE, ticks),
    remaining = ticks,
  }, ScaleMotion)
end

-- BattleAnimUtil_UpdateScaleMotionXY: spends one tick before reading the new
-- scale, exactly like the native update.
---@param self SourceTimedScaleMotion motion under advancement
---@return boolean active true while the motion had a tick to spend
function ScaleMotion:step()
  if self.remaining == 0 then
    return false
  end
  self.remaining = self.remaining - 1
  self.curX = self.curX + self.stepX
  self.curY = self.curY + self.stepY
  self.x = math.floor(self.curX / Support.FX32_ONE)
  self.y = math.floor(self.curY / Support.FX32_ONE)
  return true
end

-- BattleAnimUtil_CalcScaleYOffset: half the height an 80-pixel picture (less
-- twice the battler inset) loses at the given 1/256 scale, rounded like the
-- native fixed-point helper.
---@param inset integer battler picture inset in pixels
---@param scale integer 1/256 scale under alignment
---@return integer vertical pivot offset in pixels
function Support.scaleYOffset(inset, scale)
  local height = (80 - math.floor(inset) * 2) * Support.FX32_ONE
  local scaled = PresentationFxMath.fxMul(height, math.floor(scale))
  local offset = height - PresentationFxMath.fxDiv(scaled, 256 * Support.FX32_ONE)
  local whole = math.floor(offset / Support.FX32_ONE)
  local frac = offset - whole * Support.FX32_ONE
  local pixels = whole
  if frac ~= 0 then
    pixels = math.floor((whole * Support.FX32_ONE + frac + Support.FX32_ONE / 2) / Support.FX32_ONE)
  end
  return math.floor(pixels / 2)
end

-- BattleAnimUtil_AlignPokepicToScale: writes the scaled picture's Y from its
-- authored baseline. Mode 1 mirrors the offset and drops the inset, exactly
-- like the native second-leg alignment.
---@param y integer authored picture Y
---@param inset integer battler picture inset in pixels
---@param scale integer 1/256 current scale
---@param mode integer native alignment mode, 0 or 1
---@return integer aligned picture Y
function Support.alignY(y, inset, scale, mode)
  local offset = Support.scaleYOffset(inset, scale)
  if mode == 1 then
    offset = -offset
    y = math.floor(y) - math.floor(inset)
  end
  return Support.clampOffset(math.floor(y) + offset)
end

-- BattleAnimUtil_InitShake / UpdateShake: the native four-phase square shake.
---@class SourceTimedShake
---@field ampX integer horizontal amplitude in pixels
---@field ampY integer vertical amplitude in pixels
---@field interval integer ticks per phase step
---@field count integer remaining shake rounds
---@field phase integer phase inside the current round
---@field timer integer ticks spent inside the current phase step
---@field prevX integer previous horizontal offset
---@field prevY integer previous vertical offset
---@field x integer current horizontal offset
---@field y integer current vertical offset
local Shake = {}
Shake.__index = Shake

---@param ampX integer horizontal amplitude in pixels
---@param ampY integer vertical amplitude in pixels
---@param interval integer ticks per phase step
---@param count integer shake rounds
---@return SourceTimedShake shake record
function Support.shake(ampX, ampY, interval, count)
  return setmetatable({
    ampX = math.floor(ampX),
    ampY = math.floor(ampY),
    interval = math.floor(interval),
    count = math.floor(count),
    phase = 0,
    timer = math.floor(interval),
    prevX = -math.floor(ampX),
    prevY = -math.floor(ampY),
    x = 0,
    y = 0,
  }, Shake)
end

---@param self SourceTimedShake shake under advancement
---@return boolean active true while rounds remain
function Shake:step()
  if self.count == 0 then
    return false
  end
  self.timer = self.timer + 1
  if self.timer >= self.interval then
    self.timer = 0
    local prevX = self.prevX
    self.prevX = self.x
    self.x = prevX == 0 and 0 or -prevX
    local prevY = self.prevY
    self.prevY = self.y
    self.y = prevY == 0 and 0 or -prevY
    self.phase = self.phase + 1
    if self.phase >= 4 then
      self.phase = 0
      self.count = self.count - 1
    end
  end
  return true
end

---@class SourceTimedBody
---@field _kind string task kind behind the run
---@field _scene table<string, unknown> scene behind every owned write
---@field _advance fun(self: SourceTimedBody): boolean?|nil native phase-machine step
---@field _patched table<integer, table<string, unknown>> activations this body patched
---@field _persist boolean terminal patch survives completion
---@field _compositor boolean the body wrote the animation compositor
---@field _scrollSaved { x: integer, y: integer }? viewport snapshot behind owned restoration
---@field _lastScroll { x: integer, y: integer }? last applied viewport behind owned restoration
---@field _scalar boolean the body wrote the scalar blend patch
---@field _ticks integer source ticks advanced
---@field _duration integer? source ticks behind completion, absent for self-retiring bodies
---@field _state string pending, running, complete, or cancelled
---@field _cancelReason string? last cancellation cause under diagnosis
---@field _disposed boolean release has run
local Body = {}
Body.__index = Body

-- One source-timed body: the native phase machine lives in `advance`, which
-- returns true on the tick it retires. Writes publish through the journaled
-- helpers below so completion, cancellation, and disposal restore exactly
-- what this body owns and nothing else.
---@param kind string task kind under construction
---@param services table<string, unknown> factory services record
---@param fields table<string, unknown> body-specific initial fields
---@param advance fun(self: SourceTimedBody): boolean? native phase-machine step
---@return SourceTimedBody runnable body
function Support.newBody(kind, services, fields, advance)
  local scene = Support.checkScene(services, kind)
  local body = setmetatable({
    _kind = kind,
    _scene = scene,
    _advance = advance,
    _patched = {},
    _persist = false,
    _compositor = false,
    _scalar = false,
    _ticks = 0,
    _state = "pending",
    _disposed = false,
  }, Body)
  for field, value in pairs(fields or {}) do
    body[field] = value
  end
  return body
end

---@return table<string, unknown> scene behind the owned writes
function Body:scene()
  return self._scene
end

---@return integer source ticks advanced
function Body:ticks()
  return self._ticks
end

---@param activation table<string, unknown> activation under keying
---@return string
local function activationKey(activation)
  return tostring(activation.combatant) .. ":" .. tostring(activation.activation)
end

-- Publishes one picture overlay on an activation this body owns.
---@param activation table<string, unknown> combatant and activation pair
---@param patch table<string, unknown> rendered appearance writes
function Body:publishPicture(activation, patch)
  local scene = self._scene
  local ok, err = pcall(scene.applyTaskPicturePatch, scene, self, activation, patch)
  if not ok then
    self:_restoreOwned()
    error(err, 0)
  end
  local key = activationKey(activation)
  local recorded = false
  for _, owned in ipairs(self._patched) do
    if activationKey(owned) == key then
      recorded = true
      break
    end
  end
  if not recorded then
    self._patched[#self._patched + 1] = activation
  end
end

-- Writes the battlefield compositor fade this body owns.
---@param patch table<string, unknown> compositor write record
function Body:writeCompositor(patch)
  local scene = self._scene
  if type(scene.writeAnimationCompositor) ~= "function" or type(scene.restoreAnimationCompositor) ~= "function" then
    Support.malformed(self._kind, "fades through the scene compositor seam")
  end
  local ok, err = pcall(scene.writeAnimationCompositor, scene, self, "main", patch)
  if not ok then
    self:_restoreOwned()
    error(err, 0)
  end
  self._compositor = true
end

-- Moves the battlefield viewport, snapshotting it on the first write.
---@param x integer viewport horizontal position
---@param y integer viewport vertical position
function Body:writeScroll(x, y)
  local scene = self._scene
  if type(scene.scroll) ~= "function" or type(scene.applyScrollPatch) ~= "function" then
    Support.malformed(self._kind, "shakes through the scene viewport seam")
  end
  if self._scrollSaved == nil then
    local current = scene.scroll(scene)
    self._scrollSaved = { x = current.x, y = current.y }
  end
  scene.applyScrollPatch(scene, math.floor(x), math.floor(y))
  self._lastScroll = { x = math.floor(x), y = math.floor(y) }
end

-- Writes the shared blend-coefficient registers this body owns.
---@param patch table<string, unknown> scalar register writes
function Body:writeScalar(patch)
  local scene = self._scene
  if type(scene.applyTaskScalarPatch) ~= "function" or type(scene.removeTaskScalarPatch) ~= "function" then
    Support.malformed(self._kind, "blends through the scene scalar seam")
  end
  scene.applyTaskScalarPatch(scene, self, patch)
  self._scalar = true
end

-- Restores exactly the writes this body still owns. A completed body keeps
-- its terminal picture patch only when the native task leaves one behind.
---@param completed boolean? whether the run reached its own completion
function Body:_restoreOwned(completed)
  local scene = self._scene
  local keepPictures = completed == true and self._persist == true
  if not keepPictures then
    for _, activation in ipairs(self._patched) do
      scene.removeTaskPicturePatch(scene, self, activation)
    end
    self._patched = {}
  end
  if self._compositor then
    self._compositor = false
    scene.restoreAnimationCompositor(scene, self, "main")
  end
  if self._scalar then
    self._scalar = false
    scene.removeTaskScalarPatch(scene, self)
  end
  if self._lastScroll ~= nil and self._scrollSaved ~= nil then
    local current = scene.scroll(scene)
    if current.x == self._lastScroll.x and current.y == self._lastScroll.y then
      scene.applyScrollPatch(scene, self._scrollSaved.x, self._scrollSaved.y)
    end
  end
  self._lastScroll = nil
end

-- Advances one source tick. Bodies with their own native retirement report it
-- from `advance`; bodies with a compiled boundary retire on their last tick.
---@param tick table<string, unknown>? source tick under advancement
function Body:stepSourceTick(tick)
  local _ = tick
  if self._disposed or self._state == "complete" or self._state == "cancelled" then
    return
  end
  self._state = "running"
  self._ticks = self._ticks + 1
  local ok, advanced = pcall(self._advance, self)
  if not ok then
    self:_restoreOwned(false)
    error(advanced, 0)
  end
  local retired = advanced == true
  if not retired and self._duration ~= nil and self._ticks >= self._duration then
    retired = true
  end
  if retired then
    self._state = "complete"
    self:_restoreOwned(true)
  end
end

---@return string run state
function Body:status()
  assert(Support.VALID_STATES[self._state] == true, "source-timed bodies report a known run state")
  return self._state
end

---@param reason string cancellation cause under diagnosis
function Body:cancel(reason)
  if self._state == "complete" then
    return
  end
  self._state = "cancelled"
  self._cancelReason = reason
  self:_restoreOwned(false)
end

function Body:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  if self._state ~= "complete" then
    self:_restoreOwned(false)
  end
end

Support.Body = Body

return Support
