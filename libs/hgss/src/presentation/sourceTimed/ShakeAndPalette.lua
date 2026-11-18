-- Source-timed native battle animation bodies: the shake and palette family.
-- Each entry maps one producer task kind to its body constructor and
-- reproduces one overlay-07 callback whose native machine owns a fixed
-- internal timeline instead of reading script timing words
-- (battle_anim_effects.c and battle_anim_move_effects.c in the pinned
-- pret/pokeheartgold tree). See Support.lua for the journaled write seams and
-- the lifecycle every body shares.

local Support = require("libs.hgss.src.presentation.sourceTimed.Support")

local ShakeAndPalette = {}

-- The natives in this family address their own battler
-- (BattleAnimSystem_GetAttacker or GetDefender), so the occurrence's picture
-- on that side is the one the body owns. A produced battlerTarget keeps its
-- word; without one the side resolves the presented activation directly, and
-- the producer lowers no battler target for these selectors.
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param kind string task kind under diagnosis
---@param role string "attacker" or "defender" side the native addresses
---@return table<string, unknown> combatant and activation pair behind the owned picture
local function ownedActivation(args, context, kind, role)
  if args.activation ~= nil or args.battlerTarget ~= nil then
    return Support.requiredActivation(args, context, kind)
  end
  local battlerTarget = role == "attacker" and "attacker" or "target"
  return Support.requiredActivation({ battlerTarget = battlerTarget }, context, kind)
end

-- BattleAnimUtil_GetBattlerType: the native battler type of one presented
-- combatant, read from the occurrence topology.
---@param context table<string, unknown> occurrence-bound playback context
---@param combatant number combatant whose battler type is under reading
---@param kind string task kind under diagnosis
---@param detail string diagnosis when the occurrence does not present that side
---@return integer native battler type in 0..5
local function battlerType(context, combatant, kind, detail)
  local topology = type(context) == "table" and context.topology or nil
  local candidates = {}
  if type(topology) == "table" then
    candidates[#candidates + 1] = topology.attacker
    local targets = topology.targets
    if type(targets) == "table" then
      for _, target in ipairs(targets) do
        candidates[#candidates + 1] = target
      end
    end
  end
  for _, candidate in ipairs(candidates) do
    if type(candidate) == "table" and candidate.combatant == combatant then
      local sideType = candidate.sideType
      if type(sideType) == "number" and sideType % 1 == 0 and sideType >= 0 and sideType <= 5 then
        return math.floor(sideType)
      end
    end
  end
  error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " " .. detail, 0)
end

-- BattleAnimUtil_GetBattlerSideSignByMode: the player side reads +1 and the
-- enemy side reads -1, which is the parity of the native battler side type.
---@param context table<string, unknown> occurrence-bound playback context
---@param activation table<string, unknown> combatant and activation pair under siding
---@param kind string task kind under diagnosis
---@return integer native side sign of the addressed battler
local function sideSign(context, activation, kind)
  local sideType = battlerType(context, activation.combatant, kind, "resolves the side of the battler it flashes")
  return sideType % 2 == 0 and 1 or -1
end

-- Pokepic_StartPaletteFade and the PokepicManager palette step
-- (src/pokepic.c, PokepicManager run of drawParam.fadeCur): a fade keeps its
-- current and end coefficient plus a per-step delay, the manager blends one
-- coefficient per frame and clears the fade-active flag on the frame that
-- shows the end coefficient. The battle animation tick and that manager frame
-- advance together, so a fade started on a tick shows its first coefficient
-- on that same tick.
---@class SourceTimedPaletteFade
---@field current integer coefficient the next tick shows
---@field finish integer end coefficient
---@field targetColor integer native RGB555 blend target
---@field active boolean the manager still walks the fade
local PaletteFade = {}
PaletteFade.__index = PaletteFade

---@param start integer first coefficient
---@param finish integer end coefficient
---@param targetColor integer native RGB555 blend target
---@return SourceTimedPaletteFade fade record
local function paletteFade(start, finish, targetColor)
  return setmetatable({
    current = math.floor(start),
    finish = math.floor(finish),
    targetColor = targetColor,
    active = true,
  }, PaletteFade)
end

-- One manager frame: reports the coefficient this tick shows and walks the
-- fade toward its end.
---@return integer shown coefficient applied on this tick
function PaletteFade:step()
  local shown = self.current
  if not self.active then
    return shown
  end
  if shown == self.finish then
    self.active = false
  elseif shown > self.finish then
    self.current = shown - 1
  else
    self.current = shown + 1
  end
  return shown
end

-- The scene palette-fade record for the presented picture. The native delay
-- is zero for every callback in this family, so the scene blends every frame.
---@param shown integer coefficient applied on this tick
---@return table<string, unknown> palette fade overlay
function PaletteFade:record(shown)
  return {
    start = Support.clampLevel(shown),
    finish = Support.clampLevel(self.finish),
    framesPer = 0,
    targetColor = self.targetColor,
  }
end

-- BattleAnimFunc_AttackerPulseWhite (battle_anim_move_effects.c, selector 13
-- of gBattleAnimFuncTable) reads gBattleAnimPulseWhiteSteps
-- (asm/battle_anim_data.s): two BattleAnimScaleStep rows, 100 -> 115 and
-- 115 -> 100 in 1/100 scale words over six ticks each, each wrapped in a
-- six-coefficient white palette fade in the opposite direction.
local PULSE_WHITE_STEPS = {
  { start = 100, finish = 115, ticks = 6 },
  { start = 115, finish = 100, ticks = 6 },
}
local PULSE_WHITE_SCALE_DIVISOR = 100
local PULSE_WHITE_FADE_LEVEL = 6
local PULSE_WHITE_TARGET_COLOR = 0x7FFF -- RGB_WHITE as a native RGB555 word
local PULSE_WHITE_ROUNDS = 4

---@class SourceTimedPalettePulse
---@field _activation table<string, unknown> attacker picture the pulse owns
---@field _phase string current native state
---@field _whitened integer next gBattleAnimPulseWhiteSteps row, 0 or 1
---@field _count integer pulses started so far
---@field _motion SourceTimedScaleMotion? pulse scale motion under advancement
---@field _fade SourceTimedPaletteFade? white palette fade under advancement

---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return SourceTimedBody runnable palette pulse task
local function newPalettePulse(kind, args, context, services)
  Support.parameters(args, kind)
  local activation = ownedActivation(args, context, kind, "attacker")
  ---@param self SourceTimedBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    local own = self --[[@as SourceTimedPalettePulse]]
    if own._phase == "start-pulse" then
      local row = PULSE_WHITE_STEPS[own._whitened + 1]
      own._motion =
        Support.scaleMotion(row.start, row.finish, row.start, row.finish, PULSE_WHITE_SCALE_DIVISOR, row.ticks)
      local whitening = own._whitened == 0
      own._fade = paletteFade(
        whitening and 0 or PULSE_WHITE_FADE_LEVEL,
        whitening and PULSE_WHITE_FADE_LEVEL or 0,
        PULSE_WHITE_TARGET_COLOR
      )
      own._whitened = whitening and 1 or 0
      own._count = own._count + 1
      own._phase = "pulse"
      -- The manager applies the started fade on this frame, and the machine
      -- writes no picture attributes on its initialization frame.
      own._fade:step()
      return false
    end
    if own._phase == "done" then
      -- PULSE_WHITE_STATE_PULSE retired after the fourth pulse: the source's
      -- default case destroys the task.
      return true
    end
    -- PULSE_WHITE_STATE_PULSE: every tick writes the affine pair, including
    -- the frame the scale motion and the palette fade have both finished.
    local stepped = own._motion:step()
    local shown = own._fade:step()
    if not stepped and not own._fade.active then
      own._phase = own._count < PULSE_WHITE_ROUNDS and "start-pulse" or "done"
    end
    self:publishPicture(own._activation, {
      affineMode = true,
      affineWidth = own._motion.x,
      affineHeight = own._motion.y,
      paletteFade = own._fade:record(shown),
    })
    return false
  end
  return Support.newBody(kind, services, {
    _activation = activation,
    _phase = "start-pulse",
    _whitened = 0,
    _count = 0,
    _motion = nil,
    _fade = nil,
  }, advance)
end

ShakeAndPalette["pokemon-picture-palette-pulse-position-transition"] = newPalettePulse

-- BattleAnimFunc_FadeInShrinkSprite (battle_anim_effects.c, selector 17). The
-- callback starts an eight-tick value motion 0 -> 16 and its opening
-- reg_G2_BLDALPHA pair 0/31, then the task walks the pair to 16/15 over eight
-- ticks, holds it thirty-three ticks, shrinks the copy from 14/10 to 10/10
-- over eight ticks, and destroys itself one frame after the exhausted scale
-- frame hides the copy. The shifted subject is a script-created battler
-- sprite copy (BattleAnimSystem_GetBattlerSprite slot 0, made by the effect
-- script): its XLU OAM mode, its draw priority and the terminal
-- ManagedSprite_SetDrawFlag hide have no scene expression, and the scene
-- presents the battler picture instead, so the body drives that picture's
-- affine pair with the copy's scale timeline and keeps the picture drawn.
local FADE_SHRINK_BLEND_LEVEL = 16
local FADE_SHRINK_BLEND_TICKS = 8
local FADE_SHRINK_BLEND_BACKGROUND = 31 -- BattleAnimUtil_SetBlendWithBattleBg(0, 31)
local FADE_SHRINK_HOLD_LIMIT = 32
local FADE_SHRINK_START_SCALE = 14
local FADE_SHRINK_END_SCALE = 10
local FADE_SHRINK_SCALE_DIVISOR = 10
local FADE_SHRINK_SCALE_TICKS = 8

---@class SourceTimedFadeShrinkSprite
---@field _activation table<string, unknown> attacker picture the run owns
---@field _phase string current native state
---@field _blendCurrent integer fixed-point current blend coefficient
---@field _blendValue integer whole current sprite alpha weight
---@field _blendStep integer fixed-point blend coefficient step
---@field _blendTicks integer value-motion ticks left
---@field _timer integer hold frames spent
---@field _scale SourceTimedScaleMotion? shrink leg under advancement

-- reg_G2_BLDALPHA = value | ((31 - value) << 8): the sprite weight rises as
-- the battlefield weight falls.
---@param sourceTimedBody SourceTimedBody body under publication
---@param own SourceTimedFadeShrinkSprite run state behind the register write
local function publishFadeShrinkBlend(sourceTimedBody, own)
  sourceTimedBody:writeScalar({
    blendCoefficientA = own._blendValue,
    blendCoefficientB = FADE_SHRINK_BLEND_BACKGROUND - own._blendValue,
  })
end

---@param sourceTimedBody SourceTimedBody body under publication
---@param own SourceTimedFadeShrinkSprite run state behind the pose
local function publishFadeShrinkScale(sourceTimedBody, own)
  local scale = own._scale --[[@as SourceTimedScaleMotion]]
  sourceTimedBody:publishPicture(own._activation, {
    affineMode = true,
    affineWidth = scale.x,
    affineHeight = scale.y,
  })
end

---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return SourceTimedBody runnable fade-in and shrink task
local function newFadeShrinkSprite(kind, args, context, services)
  Support.parameters(args, kind)
  local activation = ownedActivation(args, context, kind, "attacker")
  ---@param self SourceTimedBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    local own = self --[[@as SourceTimedFadeShrinkSprite]]
    local phase = own._phase
    if phase == "fade-in" then
      -- FADE_SHRINK_STATE_FADE_IN: BattleAnimUtil_UpdateValueMotionFx then the
      -- untouched register pair on the frame the motion exhausts.
      local active = own._blendTicks ~= 0
      if active then
        own._blendCurrent = own._blendCurrent + own._blendStep
        own._blendValue = math.floor(own._blendCurrent / Support.FX32_ONE)
        own._blendTicks = own._blendTicks - 1
      end
      publishFadeShrinkBlend(self, own)
      if not active then
        own._phase = "hold"
        own._timer = 0
      end
      return false
    end
    if phase == "hold" then
      -- FADE_SHRINK_STATE_HOLD: thirty-three frames without a write.
      own._timer = own._timer + 1
      if own._timer > FADE_SHRINK_HOLD_LIMIT then
        own._phase = "shrink"
      end
      return false
    end
    if phase == "shrink" then
      local stepped = own._scale:step()
      -- FADE_SHRINK_STATE_SHRINK writes the copy's affine scale on every
      -- shrink frame, including the exhausted frame that then hides it.
      publishFadeShrinkScale(self, own)
      if not stepped then
        own._phase = "done"
      end
      return false
    end
    -- FADE_SHRINK_STATE_END: the source destroys its task.
    return true
  end
  local body = Support.newBody(kind, services, {
    _activation = activation,
    _phase = "fade-in",
    _blendCurrent = 0,
    _blendValue = 0,
    _blendStep = Support.fxStep(0, FADE_SHRINK_BLEND_LEVEL * Support.FX32_ONE, FADE_SHRINK_BLEND_TICKS),
    _blendTicks = FADE_SHRINK_BLEND_TICKS,
    _timer = 0,
    _scale = Support.scaleMotion(
      FADE_SHRINK_START_SCALE,
      FADE_SHRINK_END_SCALE,
      FADE_SHRINK_START_SCALE,
      FADE_SHRINK_END_SCALE,
      FADE_SHRINK_SCALE_DIVISOR,
      FADE_SHRINK_SCALE_TICKS
    ) --[[@as SourceTimedScaleMotion]],
  }, advance)
  -- The callback writes the copy's opening 14/10 affine scale and its 0/31
  -- blend pair itself, before its task starts, and that pose is the one the
  -- shrink leg walks from.
  publishFadeShrinkScale(body, body --[[@as SourceTimedFadeShrinkSprite]])
  body:writeScalar({ blendCoefficientA = 0, blendCoefficientB = FADE_SHRINK_BLEND_BACKGROUND })
  return body
end

ShakeAndPalette["sprite-affine-scale-and-blend-transition"] = newFadeShrinkSprite

-- BattleAnimFunc_ShakeDefenderBlackFlash (battle_anim_effects.c, selector 18):
-- BattleAnimUtil_InitShake(4, 0, 1, 4) displaces the defender picture every
-- tick, the callback biases the first shake phase with the defender's side
-- sign, and Pokepic_StartPaletteFade(0, 16, 0, RGB_BLACK) walks the picture
-- palette to black. The frame that finds the fade finished starts the walk
-- back to the authored palette, the frame after that one writes the authored
-- X/Y, and the following frame destroys the task. In a same-side battler pair
-- the native also fades and hides the script-created battler sprite copy in
-- slot 1 and un-hides it at the end; the scene does not present that copy, so
-- only the picture writes are reproduced.
local BLACK_FLASH_AMPLITUDE_X = 4
local BLACK_FLASH_AMPLITUDE_Y = 0
local BLACK_FLASH_INTERVAL_TICKS = 1
local BLACK_FLASH_ROUNDS = 4
local BLACK_FLASH_FADE_LEVEL = 16
local BLACK_FLASH_TARGET_COLOR = 0 -- RGB_BLACK

---@class SourceTimedBlackFlash
---@field _activation table<string, unknown> defender picture the flash owns
---@field _phase string current native state
---@field _shake SourceTimedShake defender shake under advancement
---@field _fade SourceTimedPaletteFade? black palette fade under advancement

-- POKEPIC_X = x + shake.x and POKEPIC_Y = y + shake.y address an absolute
-- picture center, which the scene carries as offsets from the presented
-- picture; the source shake is horizontal, so the vertical offset stays zero.
---@param own SourceTimedBlackFlash run state behind the pose
---@param shown integer palette coefficient this tick shows
---@return table<string, unknown> picture overlay behind the native writes
local function blackFlashPatch(own, shown)
  return {
    pictureXOffset = Support.clampOffset(own._shake.x),
    pictureYOffset = Support.clampOffset(own._shake.y),
    paletteFade = (own._fade --[[@as SourceTimedPaletteFade]]):record(shown),
  }
end

---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return SourceTimedBody runnable shake and black-flash task
local function newBlackFlash(kind, args, context, services)
  Support.parameters(args, kind)
  local activation = ownedActivation(args, context, kind, "defender")
  local sign = sideSign(context, activation, kind)
  local shake =
    Support.shake(BLACK_FLASH_AMPLITUDE_X, BLACK_FLASH_AMPLITUDE_Y, BLACK_FLASH_INTERVAL_TICKS, BLACK_FLASH_ROUNDS)
  -- The callback's `shake.x += BattleAnimUtil_GetBattlerSideSignByMode` biases
  -- the first phase, which the native toggle then carries around the cycle.
  shake.x = sign
  ---@param self SourceTimedBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    local own = self --[[@as SourceTimedBlackFlash]]
    own._shake:step()
    local phase = own._phase
    if phase == "fade-out" then
      if not own._fade.active then
        -- BLACK_FLASH_STATE_FADE_OUT retired: the black reached picture starts
        -- its walk back to the authored palette.
        own._fade = paletteFade(BLACK_FLASH_FADE_LEVEL, 0, BLACK_FLASH_TARGET_COLOR)
        own._phase = "fade-in"
      end
      self:publishPicture(own._activation, blackFlashPatch(own, own._fade:step()))
      return false
    end
    if phase == "fade-in" then
      if not own._fade.active then
        -- BLACK_FLASH_STATE_FADE_IN retired: the source writes the authored
        -- X/Y back before the next frame destroys the task.
        self:publishPicture(own._activation, {
          pictureXOffset = 0,
          pictureYOffset = 0,
          paletteFade = own._fade:record(own._fade:step()),
        })
        own._phase = "done"
        return false
      end
      self:publishPicture(own._activation, blackFlashPatch(own, own._fade:step()))
      return false
    end
    -- BLACK_FLASH_STATE_END: the source destroys its task.
    return true
  end
  -- The callback starts the black fade on the activation frame, and that
  -- frame's manager step shows its first coefficient.
  local fade = paletteFade(0, BLACK_FLASH_FADE_LEVEL, BLACK_FLASH_TARGET_COLOR)
  fade:step()
  return Support.newBody(kind, services, {
    _activation = activation,
    _phase = "fade-out",
    _shake = shake --[[@as SourceTimedShake]],
    _fade = fade,
  }, advance)
end

ShakeAndPalette["pokemon-picture-palette-fade"] = newBlackFlash

-- BattleAnimFunc_AttackerCircleFade (battle_anim_effects.c, selector 23): the
-- callback hides the attacker picture (POKEPIC_VANISHED), opens the
-- battlefield blend at 16/0 (BattleAnimUtil_SetBlendWithBattleBg) and starts
-- the 16/0 -> 0/16 coefficient walk plus BattleAnimUtil_InitCircleMotion(2,
-- 16), a sixteen-step sine orbit played twice. The orbit spins a
-- script-created battler sprite copy (BattleAnimSystem_GetBattlerSprite slot
-- 0) in XLU OAM mode around the picture center, which the scene does not
-- present, so only the picture vanish and the blend registers are
-- reproduced. After the orbit the machine waits seventeen frames, starts the
-- reverse walk, and restores the picture visibility on the frame that walk
-- reports finished; the frame after that one destroys the task.
local VANISH_ORBIT_STEPS = 16
local VANISH_ORBIT_MULTIPLIER = 2
local VANISH_ORBIT_TICKS = VANISH_ORBIT_STEPS * VANISH_ORBIT_MULTIPLIER
local VANISH_DELAY_TICKS = 16
local VANISH_BLEND_LEVEL = 16
local VANISH_BLEND_TICKS = 32

---@class SourceTimedVanishRestore
---@field _activation table<string, unknown> attacker picture the run owns
---@field _phase string current native state
---@field _orbit integer orbit ticks left
---@field _timer integer delay frames left
---@field _ramp SourceTimedLinearMotion? queued coefficient walk under advancement
---@field _rampDone boolean the queued walk reported its closing frame

---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return SourceTimedBody runnable vanish and restore task
local function newVanishRestore(kind, args, context, services)
  Support.parameters(args, kind)
  local activation = ownedActivation(args, context, kind, "attacker")
  ---@param self SourceTimedBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    local own = self --[[@as SourceTimedVanishRestore]]
    -- The queued coefficient walk (BattleAnimUtil_StartBlendAlphaMotion) writes
    -- reg_G2_BLDALPHA once per tick and its closing frame only reports done.
    local ramp = own._ramp
    if ramp ~= nil then
      if ramp:step() then
        self:writeScalar({ blendCoefficientA = ramp.x, blendCoefficientB = ramp.y })
      else
        own._ramp = nil
        own._rampDone = true
      end
    end
    local phase = own._phase
    if phase == "orbit" then
      if own._orbit > 0 then
        own._orbit = own._orbit - 1
        return false
      end
      -- CIRCLE_FADE_STATE_CIRCLE retired: the seventeen-frame delay starts.
      own._phase = "delay"
      own._timer = VANISH_DELAY_TICKS
      return false
    end
    if phase == "delay" then
      own._timer = own._timer - 1
      if own._timer >= 0 then
        return false
      end
      -- CIRCLE_FADE_STATE_DELAY retired: the reverse walk starts.
      own._phase = "blend"
      own._ramp = Support.linear(0, VANISH_BLEND_LEVEL, VANISH_BLEND_LEVEL, 0, VANISH_BLEND_TICKS)
      own._rampDone = false
      return false
    end
    if phase == "blend" then
      if not own._rampDone then
        return false
      end
      -- CIRCLE_FADE_STATE_FADE retired: POKEPIC_VANISHED goes back to FALSE.
      -- The native also re-enables the sprite copy's draw flag, which the
      -- scene does not present.
      self:publishPicture(own._activation, { vanished = false, pictureVisible = true })
      own._phase = "done"
      return false
    end
    -- CIRCLE_FADE_STATE_END: the source destroys its task.
    return true
  end
  local body = Support.newBody(kind, services, {
    _activation = activation,
    _phase = "orbit",
    _orbit = VANISH_ORBIT_TICKS,
    _timer = 0,
    _ramp = Support.linear(VANISH_BLEND_LEVEL, 0, 0, VANISH_BLEND_LEVEL, VANISH_BLEND_TICKS) --[[@as SourceTimedLinearMotion]],
    _rampDone = false,
  }, advance)
  -- The callback hides the picture, writes the opening blend pair, and queues
  -- the first coefficient walk before its task starts.
  body:publishPicture(activation, { vanished = true, pictureVisible = false })
  body:writeScalar({ blendCoefficientA = VANISH_BLEND_LEVEL, blendCoefficientB = 0 })
  return body
end

ShakeAndPalette["pokemon-picture-vanish-and-restore-transition"] = newVanishRestore

-- POKEPIC_ZROT is a signed 16-bit angle store, so a negative native value
-- lands on the index the register keeps.
---@param value integer signed native rotation angle
---@return integer clamped angle index in 0..65535
local function angleIndex(value)
  return Support.clampRotation(value % 65536)
end

-- BattleAnimUtil_InitValueMotionFx / UpdateValueMotionFx: the motion keeps
-- the scaled current value in fixed point, writes the truncated whole value,
-- and retires on the frame its tick count is spent.
---@class SourceTimedValueMotionFx
---@field current integer fixed-point current value
---@field stepValue integer fixed-point step per tick
---@field value integer whole current value
---@field remaining integer ticks left behind the motion
local ValueMotionFx = {}
ValueMotionFx.__index = ValueMotionFx

---@param start integer whole value at the first tick
---@param finish integer whole value after the last tick
---@param ticks integer positive step count
---@return SourceTimedValueMotionFx value motion record
local function valueMotionFx(start, finish, ticks)
  return setmetatable({
    current = math.floor(start) * Support.FX32_ONE,
    stepValue = Support.fxStep(math.floor(start) * Support.FX32_ONE, math.floor(finish) * Support.FX32_ONE, ticks),
    value = math.floor(start),
    remaining = ticks,
  }, ValueMotionFx)
end

---@param self SourceTimedValueMotionFx motion under advancement
---@return boolean active true while the motion had a tick to spend
function ValueMotionFx:step()
  if self.remaining == 0 then
    return false
  end
  self.current = self.current + self.stepValue
  self.value = math.floor(self.current / Support.FX32_ONE)
  self.remaining = self.remaining - 1
  return true
end

-- BattleAnimFunc_WaddlePic (battle_anim_effects.c, selector 25): the callback
-- reads the authored X/Y of the picture its script operand names, sets the
-- picture's Y pivot to 50 and the step's X pivot to -16, and starts a
-- three-tick value motion to 0xAAA whose step the attacker's side sign
-- negates. The machine then runs four steps of nine frames each: a tilt frame
-- that only spends the value motion, two hop ticks that descend two pixels
-- while the tilt reaches 0xAAA, a landing that ramps the tilt back to zero
-- while the picture climbs home, and the frame that reports the step done.
-- That reporting frame also starts the next step and spends its tilt frame, so
-- the fourth step retires on the thirty-third frame and the destroy frame
-- takes the thirty-fourth. Every X/Y the native writes is this picture's own
-- authored position plus the hop, so the hop is published as a picture
-- offset. The step's alternating -16/+16 X pivot and the terminal 50 Y pivot
-- have no scene expression; the picture center is the pivot.
local WADDLE_TILT_ANGLE = 0xAAA
local WADDLE_TILT_TICKS = 3
local WADDLE_HOP_PIXELS = 2
local WADDLE_HOP_TICKS = 2
local WADDLE_RETURN_TICKS = 2
local WADDLE_STEPS = 4

---@class SourceTimedWaddlePic
---@field _activation table<string, unknown> picture the waddle owns
---@field _phase string current native state
---@field _stepState string frame inside the current step
---@field _steps integer steps behind the run
---@field _flip boolean the current step tilts the other way
---@field _tilt SourceTimedValueMotionFx tilt motion under advancement
---@field _hop SourceTimedLinearMotion? hop motion in picture offsets

-- BattleAnimTask_WaddlePicStartStep: the fresh tilt motion and its step sign.
---@param flip boolean whether the step negates the tilt
---@return SourceTimedValueMotionFx tilt motion of the started step
local function startWaddleStep(flip)
  local tilt = valueMotionFx(0, WADDLE_TILT_ANGLE, WADDLE_TILT_TICKS)
  if flip then
    tilt.stepValue = -tilt.stepValue
  end
  return tilt
end

-- The hop and landing legs walk the offset pair the native writes as absolute
-- X/Y; the X leg never leaves the authored column.
---@param fromY integer offset the leg starts at
---@param toY integer offset the leg ends at
---@param ticks integer positive tick count
---@return SourceTimedLinearMotion offset leg under advancement
local function waddleLeg(fromY, toY, ticks)
  return Support.linear(0, 0, fromY, toY, ticks)
end

---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return SourceTimedBody runnable waddle task
local function newWaddlePic(kind, args, context, services)
  Support.parameters(args, kind)
  local activation = ownedActivation(args, context, kind, "attacker")
  -- The native sides the whole run by the attacker's sign, whichever picture
  -- its operand names, and player-side attackers tilt with the positive step.
  local attacker = Support.requiredActivation({ battlerTarget = "attacker" }, context, kind)
  local flip = sideSign(context, attacker, kind) ~= 1
  ---@param self SourceTimedBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    local own = self --[[@as SourceTimedWaddlePic]]
    if own._phase == "end" then
      -- WADDLE_STATE_END: the source destroys its task without a write.
      return true
    end
    local stepState = own._stepState
    if stepState == "tilt" then
      -- WADDLE_STEP_STATE_TILT: the tilt motion is spent without being read,
      -- and the frame then drops into the hop.
      own._tilt:step()
      self:publishPicture(own._activation, { rotationZ = angleIndex(own._tilt.value) })
      own._hop = waddleLeg(0, WADDLE_HOP_PIXELS, WADDLE_HOP_TICKS)
      own._stepState = "hop"
      return false
    end
    if stepState == "hop" then
      local tilting = own._tilt:step()
      local hop = own._hop --[[@as SourceTimedLinearMotion]]
      if hop:step() then
        local pose = { pictureXOffset = Support.clampOffset(hop.x), pictureYOffset = Support.clampOffset(hop.y) }
        if tilting then
          pose.rotationZ = angleIndex(own._tilt.value)
        end
        self:publishPicture(own._activation, pose)
        return false
      end
      -- WADDLE_STEP_STATE_HOP retired: the landing starts from the two-pixel
      -- reach and the tilt value it stopped on.
      own._tilt = valueMotionFx(own._tilt.value, 0, WADDLE_TILT_TICKS)
      own._hop = waddleLeg(WADDLE_HOP_PIXELS, 0, WADDLE_RETURN_TICKS)
      own._stepState = "land"
      return false
    end
    if stepState == "land" then
      local hop = own._hop --[[@as SourceTimedLinearMotion]]
      local walked = hop:step()
      local tilting = own._tilt:step()
      if tilting then
        local pose = { rotationZ = angleIndex(own._tilt.value) }
        if walked then
          pose.pictureXOffset = Support.clampOffset(hop.x)
          pose.pictureYOffset = Support.clampOffset(hop.y)
        end
        self:publishPicture(own._activation, pose)
        return false
      end
      if walked then
        self:publishPicture(own._activation, {
          pictureXOffset = Support.clampOffset(hop.x),
          pictureYOffset = Support.clampOffset(hop.y),
        })
        return false
      end
      -- WADDLE_STEP_STATE_LAND retired: the exhausted frame writes the
      -- authored X/Y back with a zero Z rotation before the step is reported.
      self:publishPicture(own._activation, { pictureXOffset = 0, pictureYOffset = 0, rotationZ = 0 })
      own._stepState = "done"
      return false
    end
    -- WADDLE_STEP_STATE_DONE: the step reports itself, and the machine either
    -- starts the next step on this same frame or leaves for WADDLE_STATE_END.
    own._steps = own._steps + 1
    if own._steps >= WADDLE_STEPS then
      own._phase = "end"
      return false
    end
    own._flip = not own._flip
    own._tilt = startWaddleStep(own._flip)
    own._tilt:step()
    self:publishPicture(own._activation, { rotationZ = angleIndex(own._tilt.value) })
    own._hop = waddleLeg(0, WADDLE_HOP_PIXELS, WADDLE_HOP_TICKS)
    own._stepState = "hop"
    return false
  end
  return Support.newBody(kind, services, {
    _activation = activation,
    _phase = "step",
    _stepState = "tilt",
    _steps = 0,
    _flip = flip,
    _tilt = startWaddleStep(flip),
    _hop = nil,
  }, advance)
end

ShakeAndPalette["pokemon-picture-entry-offset-transition"] = newWaddlePic

-- BattleAnimFunc_SpriteDriftFade (battle_anim_move_effects.c, selector 26):
-- the callback picks the defender picture (script arg 0 zero) or the attacker
-- picture, drifts its script-created battler sprite copy (slot 0) twenty
-- pixels away from the picked battler's side sign over twenty ticks, opens
-- the masked battlefield blend at the helper's 26/5 defaults, and walks
-- reg_G2_BLDALPHA 31/0 -> 0/31 over fifteen frames on its own main-queue
-- task. The animation task then holds the exhausted pose on one more frame
-- and destroys itself on the next. The copy is drawn in XLU OAM mode with its
-- own ticking frame and the callback's shake is never initialized nor
-- applied, so the scene presents neither; the body drives the presented
-- picture with the copy's drift timeline and the register pair instead, and
-- the copy's Y origin (the picture Y less its shadow height, which the
-- producer lowers no word for) reads as the flat picture row.
local DRIFT_PIXELS = 20
local DRIFT_TICKS = 20
local DRIFT_BLEND_START = 31
local DRIFT_BLEND_FINISH = 0
local DRIFT_BLEND_EVB = 31
local DRIFT_BLEND_TICKS = 15
local DRIFT_OPEN_EVA = 26 -- BattleAnimUtil_SetBlendWithMask(..., -1, -1)
local DRIFT_OPEN_EVB = 5

---@class SourceTimedSpriteDriftFade
---@field _activation table<string, unknown> picture the drift owns
---@field _phase string current native state
---@field _motion SourceTimedLinearMotion drift motion in picture offsets
---@field _blend SourceTimedLinearMotion? coefficient walk under advancement

---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return SourceTimedBody runnable drift and fade task
local function newSpriteDriftFade(kind, args, context, services)
  Support.parameters(args, kind)
  local activation = ownedActivation(args, context, kind, "defender")
  local sign = sideSign(context, activation, kind)
  ---@param self SourceTimedBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    local own = self --[[@as SourceTimedSpriteDriftFade]]
    -- The queued coefficient walk (BattleAnimUtil_StartBlendAlphaMotion)
    -- writes reg_G2_BLDALPHA once per tick, and the closing frame that reports
    -- itself done writes nothing.
    local blend = own._blend
    if blend ~= nil then
      if blend:step() then
        self:writeScalar({ blendCoefficientA = blend.x, blendCoefficientB = blend.y })
      else
        own._blend = nil
      end
    end
    if own._phase == "retire" then
      -- The source destroys its task on the frame after the drift retired.
      return true
    end
    local motion = own._motion
    if not motion:step() then
      -- SPRITE_DRIFT_STATE_MOVE retired: this frame still places the copy on
      -- the held pose before the next frame destroys the task.
      own._phase = "retire"
    end
    self:publishPicture(own._activation, {
      pictureXOffset = Support.clampOffset(motion.x),
      pictureYOffset = Support.clampOffset(motion.y),
    })
    return false
  end
  local body = Support.newBody(kind, services, {
    _activation = activation,
    _phase = "drift",
    _motion = Support.linear(0, -DRIFT_PIXELS * sign, 0, DRIFT_PIXELS * sign, DRIFT_TICKS) --[[@as SourceTimedLinearMotion]],
    _blend = Support.linear(
      DRIFT_BLEND_START,
      DRIFT_BLEND_FINISH,
      DRIFT_BLEND_FINISH,
      DRIFT_BLEND_EVB,
      DRIFT_BLEND_TICKS
    ) --[[@as SourceTimedLinearMotion]],
  }, advance)
  -- The callback opens the masked blend pair and queues both motions before
  -- its task starts, so the first tick already spends one step of each.
  body:writeScalar({ blendCoefficientA = DRIFT_OPEN_EVA, blendCoefficientB = DRIFT_OPEN_EVB })
  return body
end

ShakeAndPalette["pokemon-picture-randomized-position-motion"] = newSpriteDriftFade

-- BattleAnimUtil_GetBattlerType rows: the Y each native battler type's
-- picture row sits on (gBattleAnimBattlerTypePositions, asm/battle_anim_data.s).
-- Only the difference between two rows is a picture-relative quantity, which
-- is why only the leg below reads it.
local BATTLER_ROWS = { [0] = 112, [1] = 48, [2] = 112, [3] = 50, [4] = 120, [5] = 42 }

-- BattleAnimFunc_SlideOutAndTransform (battle_anim_move_effects.c, selector
-- 71): the callback collects the pictures its script operand selects, sided by
-- the attacker's own side, and slides them through three fifteen-tick legs:
-- onto the near battler's picture column, across to the opposite column (the
-- mon reloaded with the opposite facing unless both battlers share a side),
-- and back onto the attacker's column with the picture restored. Every leg
-- frame writes the motion's X/Y, each leg start also writes the leg's picture
-- depth and requests a shadow Y adjust, and the frame after the third leg
-- clears that request and destroys the task.
--
-- The native stops are absolute picture-space columns (335 and -80) whose
-- authored picture positions the scene does not carry, so the body keeps the
-- reach between those two columns, the row difference between the two battler
-- columns, and the return to the presented position of the picture it owns. A
-- collected picture starts on its own column, so the first leg only parks it.
-- The leg's depth pop (POKEPIC_Z 10 / -650 against the authored picture
-- depth), the opposite-facing picture reload, and the other collected
-- pictures have no scene expression.
local SLIDE_LEG_TICKS = 15
-- The reach 335 - (-80) between the two native picture columns.
local SLIDE_PICTURE_COLUMN_REACH = 415
local SLIDE_LEG_COUNT = 3

-- The picture the collected set names: the first selected set when the
-- producer lowered one, otherwise the attacker picture the collection falls
-- back on.
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param kind string task kind under diagnosis
---@return table<string, unknown> combatant and activation pair behind the owned picture
local function selectedActivation(args, context, kind)
  local parameters = Support.parameters(args, kind)
  local sets = parameters.pictureSets
  if sets == nil then
    return ownedActivation(args, context, kind, "attacker")
  end
  if type(sets) ~= "table" or sets[1] ~= nil and type(sets[1]) ~= "string" then
    Support.malformed(kind, "carries its picture sets as named sets")
  end
  if sets[1] == nil then
    return ownedActivation(args, context, kind, "attacker")
  end
  local activation = Support.activation({ battlerTarget = sets[1] }, context)
  if activation == nil then
    Support.malformed(kind, "collects a battler picture the occurrence presents")
  end
  return activation --[[@as table<string, unknown>]]
end

---@class SourceTimedSlideOutTransform
---@field _activation table<string, unknown> picture the slide owns
---@field _legs table<integer, table<string, number>> per-leg offsets the run walks
---@field _leg integer legs behind the run
---@field _legStart boolean the next frame starts a leg
---@field _legY integer vertical offset of the current leg
---@field _shadowAdjustY boolean the run's shadow Y adjust request
---@field _motion SourceTimedLinearMotion? horizontal leg under advancement
---@field _phase string current native state

---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return SourceTimedBody runnable slide and transform task
local function newSlideOutAndTransform(kind, args, context, services)
  local activation = selectedActivation(args, context, kind)
  local attacker = Support.requiredActivation({ battlerTarget = "attacker" }, context, kind)
  local defender = Support.requiredActivation({ battlerTarget = "target" }, context, kind)
  -- The native slides the attacker toward its own side and across to the
  -- opposite picture column, so a player-side attacker keeps the positive
  -- direction value of SLIDE_TRANSFORM's leg table.
  local direction = sideSign(context, attacker, kind)
  local rowShift = BATTLER_ROWS[battlerType(
    context,
    defender.combatant,
    kind,
    "resolves the row of the battler it crosses"
  )] - BATTLER_ROWS[battlerType(context, attacker.combatant, kind, "resolves the row of the battler it slides")]
  local reach = -SLIDE_PICTURE_COLUMN_REACH * direction
  local legs = {
    { fromX = 0, toX = 0, y = 0 },
    { fromX = 0, toX = reach, y = rowShift },
    { fromX = reach, toX = 0, y = 0 },
  }
  ---@param self SourceTimedBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    local own = self --[[@as SourceTimedSlideOutTransform]]
    if own._phase == "end" then
      -- The source's default case clears the shadow adjust request and
      -- destroys its task.
      self:publishPicture(own._activation, { shadowAdjustY = false })
      return true
    end
    if own._legStart then
      -- SLIDE_TRANSFORM_STATE_START_LEG writes the leg's picture depth (no
      -- scene expression), requests the shadow Y adjust that stays on for the
      -- rest of the run, and falls through to the move on this same frame.
      local leg = own._legs[own._leg + 1]
      own._legStart = false
      own._legY = math.floor(leg.y)
      own._shadowAdjustY = true
      own._motion = Support.linear(math.floor(leg.fromX), math.floor(leg.toX), 0, 0, SLIDE_LEG_TICKS)
    end
    local motion = own._motion --[[@as SourceTimedLinearMotion]]
    if motion:step() then
      self:publishPicture(own._activation, {
        pictureXOffset = Support.clampOffset(motion.x),
        pictureYOffset = Support.clampOffset(own._legY),
        shadowAdjustY = own._shadowAdjustY,
      })
      return false
    end
    -- MOVE retired: the source counts the leg, reloads the collected
    -- picture with its opposite facing for the crossing leg (and back for the
    -- return), and still writes the held pose on this frame.
    own._leg = own._leg + 1
    if own._leg >= SLIDE_LEG_COUNT then
      own._phase = "end"
    else
      own._legStart = true
    end
    self:publishPicture(own._activation, {
      pictureXOffset = Support.clampOffset(motion.x),
      pictureYOffset = Support.clampOffset(own._legY),
      shadowAdjustY = own._shadowAdjustY,
    })
    return false
  end
  return Support.newBody(kind, services, {
    _activation = activation,
    _legs = legs,
    _leg = 0,
    _legStart = true,
    _legY = 0,
    _shadowAdjustY = false,
    _motion = nil,
    _phase = "legs",
  }, advance)
end

ShakeAndPalette["pokemon-picture-selected-pair-transition"] = newSlideOutAndTransform

return ShakeAndPalette
