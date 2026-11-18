-- Source-timed native battle animation bodies: the scale and offset picture
-- family. Each entry maps one producer task kind to its body constructor and
-- reproduces one overlay-07 callback whose native machine owns a fixed
-- internal timeline instead of reading script timing words
-- (battle_anim_move_effects.c and battle_anim_effects.c in the pinned
-- pret/pokeheartgold tree). See Support.lua for the journaled write seams and
-- the lifecycle every body shares.

local Support = require("libs.hgss.src.presentation.sourceTimed.Support")

local ScaleMotion = {}

-- Authored 1.0 in the scene's 8.8 picture affine units (POKEPIC_AFFINEW/H 256).
local AFFINE_ONE = 256

-- Native side sign (BattleAnimUtil_GetBattlerSideSignByMode): the player side
-- reads +1 and the enemy side reads -1, which is the parity of the native
-- battler side type.
---@param context table<string, unknown> occurrence-bound playback context
---@param activation table<string, unknown> combatant and activation pair under siding
---@param kind string task kind under diagnosis
---@return integer native side sign of the moved battler
local function sideSign(context, activation, kind)
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
    if type(candidate) == "table" and candidate.combatant == activation.combatant then
      local sideType = candidate.sideType
      if type(sideType) == "number" and sideType % 1 == 0 and sideType >= 0 and sideType <= 5 then
        return sideType % 2 == 0 and 1 or -1
      end
    end
  end
  error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " resolves the side of the battler it moves", 0)
end

-- The natives in this family address their own battler
-- (BattleAnimSystem_GetAttacker or GetDefender), so the occurrence's picture
-- on that side is the one the body owns. A produced battlerTarget keeps its
-- word; without one the side resolves the presented activation directly.
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param kind string task kind under diagnosis
---@param role string "attacker" or "defender" side the native addresses
---@return table<string, unknown> combatant and activation pair behind the owned picture
local function ownedActivation(args, context, kind, role)
  if args.activation == nil and args.battlerTarget == nil then
    local topology = type(context) == "table" and context.topology or nil
    local battler = nil
    if type(topology) == "table" then
      if role == "attacker" then
        battler = topology.attacker
      else
        local targets = topology.targets
        battler = type(targets) == "table" and targets[1] or nil
      end
    end
    if type(battler) == "table" and type(battler.combatant) == "number" then
      return { combatant = battler.combatant, activation = battler.activation }
    end
    Support.malformed(kind, "addresses a battler picture the occurrence presents")
  end
  return Support.requiredActivation(args, context, kind)
end

-- BattleAnimSystem_GetBattlerHeight: the battler picture inset behind the
-- native scale alignment. The producer lowers no inset yet, so an absent word
-- reads as the flat-picture inset zero.
---@param parameters table<string, unknown> compiled parameter record
---@param kind string task kind under diagnosis
---@return integer battler picture inset in pixels
local function pictureInset(parameters, kind)
  local inset = parameters.pictureInset
  if inset == nil then
    return 0
  end
  if type(inset) ~= "number" or inset % 1 ~= 0 or inset < 0 then
    Support.malformed(kind, "carries its battler picture inset as a non-negative whole word")
  end
  return inset
end

-- POKEPIC_ZROT is a 16-bit angle index, so a negative signed tilt wraps into
-- the register exactly like the native store.
---@param value integer signed native rotation angle
---@return integer clamped angle index in 0..65535
local function angleIndex(value)
  return Support.clampRotation(value % 65536)
end

---@class SourceTimedScaleValueRamp
---@field value integer current whole native value
---@field stepSize integer whole step per tick
---@field remaining integer ticks left behind the ramp
local ValueRamp = {}
ValueRamp.__index = ValueRamp

-- BattleAnimUtil_InitValueMotion / UpdateValueMotion: the per-tick step is the
-- fixed-point step shifted back down, so the ramp spends its last tick on the
-- endpoint and never overshoots it.
---@param start integer native value at the first tick
---@param finish integer native value after the last tick
---@param ticks integer positive step count
---@return SourceTimedScaleValueRamp whole-value ramp
local function valueRamp(start, finish, ticks)
  assert(type(ticks) == "number" and ticks >= 1, "value ramps name a positive tick count")
  local stepSize =
    math.floor(Support.fxStep(start * Support.FX32_ONE, finish * Support.FX32_ONE, ticks) / Support.FX32_ONE)
  return setmetatable({ value = start, stepSize = stepSize, remaining = ticks }, ValueRamp)
end

---@param self SourceTimedScaleValueRamp ramp under advancement
---@return boolean active true while the ramp had a tick to spend
function ValueRamp:step()
  if self.remaining == 0 then
    return false
  end
  self.value = self.value + self.stepSize
  self.remaining = self.remaining - 1
  return true
end

-- BattleAnimFunc_AttackerRecoilTilt (battle_anim_move_effects.c, selector 9 of
-- gBattleAnimFuncTable): the attacker recoils 32 pixels away from the defender
-- over three ticks, tilts 0xE38 into its own side over eight ticks, waits two,
-- returns over two, holds for 32, untilts over four, and restores the authored
-- X/Y/ZROT on the retirement tick. The native also moves the picture's OAM
-- pivot (POKEPIC_XPIVOT/YPIVOT at 40 pixels, signed by the two battlers'
-- sides); the scene carries no rotation pivot, so the tilt turns around the
-- picture centre instead.
local RECOIL_PIXELS = -32
local RECOIL_TICKS = 3
local RECOIL_RETURN_TICKS = 2
local TILT_ANGLE = 0xE38
local TILT_TICKS = 8
local TILT_WAIT_TICKS = 2
local TILT_HOLD_TICKS = 32
local UNTILT_TICKS = 4

---@class SourceTimedRecoilTilt
---@field _activation table<string, unknown> attacker picture the tilt owns
---@field _phase string current native state
---@field _offset SourceTimedLinearMotion horizontal recoil motion
---@field _rotation SourceTimedScaleValueRamp Z-rotation ramp
---@field _timer integer countdown behind the native wait and hold states

-- The source writes the picture position with the re-initialized offset
-- around each recoil leg, so every pose carries the offset pair and the
-- current Z rotation together.
---@param sourceTimedBody SourceTimedBody body under advancement
---@param own SourceTimedRecoilTilt tilt state behind the pose
local function publishRecoilTilt(sourceTimedBody, own)
  sourceTimedBody:publishPicture(own._activation --[[@as table<string, unknown>]], {
    pictureXOffset = Support.clampOffset(own._offset.x),
    pictureYOffset = Support.clampOffset(own._offset.y),
    rotationZ = angleIndex(own._rotation.value),
  })
end

---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return SourceTimedBody runnable recoil and tilt task
local function newRecoilTilt(kind, args, context, services)
  Support.parameters(args, kind)
  local activation = ownedActivation(args, context, kind, "attacker")
  local sign = sideSign(context, activation, kind)
  -- The source recoils to -32 pixels and multiplies that step and the rotation
  -- step by BattleAnimUtil_GetBattlerSideSignByMode, so an enemy-side attacker
  -- recoils and tilts the other way.
  local rotation = valueRamp(0, TILT_ANGLE, TILT_TICKS)
  rotation.stepSize = rotation.stepSize * sign
  ---@param self SourceTimedBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    local own = self --[[@as SourceTimedRecoilTilt]]
    local phase = own._phase
    if phase == "recoil" then
      if own._offset:step() then
        publishRecoilTilt(self, own)
        return false
      end
      -- RECOIL_TILT_STATE_RECOIL retired: the source re-initializes the
      -- offset motion from its whole-pixel reach back to zero.
      own._offset = Support.linear(own._offset.x, 0, 0, 0, RECOIL_RETURN_TICKS)
      own._phase = "tilt"
      return false
    end
    if phase == "tilt" then
      if own._rotation:step() then
        publishRecoilTilt(self, own)
        return false
      end
      -- RECOIL_TILT_STATE_TILT retired: the untilt ramps from the reached
      -- angle back to zero while the wait counts its two ticks down to -1.
      own._rotation = valueRamp(own._rotation.value, 0, UNTILT_TICKS)
      own._phase = "wait-tilt"
      own._timer = TILT_WAIT_TICKS
      return false
    end
    if phase == "wait-tilt" then
      own._timer = own._timer - 1
      if own._timer < 0 then
        own._phase = "return"
      end
      return false
    end
    if phase == "return" then
      if own._offset:step() then
        publishRecoilTilt(self, own)
        return false
      end
      -- RECOIL_TILT_STATE_RETURN retired: the tilt holds its reached angle
      -- while the source waits out its hold counter.
      own._phase = "hold"
      own._timer = TILT_HOLD_TICKS
      return false
    end
    if phase == "hold" then
      own._timer = own._timer - 1
      if own._timer < 0 then
        own._phase = "untilt"
      end
      return false
    end
    if phase == "untilt" then
      if own._rotation:step() then
        publishRecoilTilt(self, own)
        return false
      end
      own._phase = "finish"
      return false
    end
    -- RECOIL_TILT_STATE_FINISH: the source writes the authored X and Y and a
    -- zero rotation, then destroys its task on this same tick.
    publishRecoilTilt(self, own)
    return true
  end
  return Support.newBody(kind, services, {
    _activation = activation,
    _phase = "recoil",
    _offset = Support.linear(0, RECOIL_PIXELS * sign, 0, 0, RECOIL_TICKS) --[[@as SourceTimedLinearMotion]],
    _rotation = rotation --[[@as SourceTimedScaleValueRamp]],
    _timer = 0,
  }, advance)
end

ScaleMotion["pokemon-picture-battler-pair-scale-transition"] = newRecoilTilt

-- gBattleAnimAttackerStretchSteps (asm/battle_anim_data.s) holds three
-- BattleAnimScaleStepXY rows in 1/100 scale words, each with its own tick
-- count; BattleAnimFunc_AttackerStretchSteps (battle_anim_move_effects.c,
-- selector 14) starts one row, then writes the affine pair and the
-- scale-aligned picture row until that row's motion exhausts.
local STRETCH_STEPS = {
  { startX = 100, endX = 150, startY = 100, endY = 50, duration = 8 },
  { startX = 150, endX = 50, startY = 50, endY = 150, duration = 8 },
  { startX = 50, endX = 100, startY = 150, endY = 100, duration = 8 },
}

---@class SourceTimedStretchSteps
---@field _activation table<string, unknown> attacker picture the rows own
---@field _inset integer battler picture inset behind the row alignment
---@field _phase string current native state
---@field _row integer next source row behind the run
---@field _motion SourceTimedScaleMotion? row motion under advancement

---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return SourceTimedBody runnable stretch-steps task
local function newStretchSteps(kind, args, context, services)
  local parameters = Support.parameters(args, kind)
  local activation = ownedActivation(args, context, kind, "attacker")
  local inset = pictureInset(parameters, kind)
  ---@param self SourceTimedBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    local own = self --[[@as SourceTimedStretchSteps]]
    if own._phase == "start-row" then
      local row = STRETCH_STEPS[own._row]
      own._motion = Support.scaleMotion(row.startX, row.endX, row.startY, row.endY, 100, row.duration)
      own._row = own._row + 1
      own._phase = "step"
      return false
    end
    if own._phase == "done" then
      return true
    end
    if not own._motion:step() then
      own._phase = own._row > #STRETCH_STEPS and "done" or "start-row"
    end
    -- STRETCH_STEPS_STATE_STEP writes the affine pair and the aligned row on
    -- every tick, including the tick the row's scale motion exhausts.
    local motion = own._motion --[[@as SourceTimedScaleMotion]]
    self:publishPicture(own._activation, {
      affineMode = true,
      affineWidth = motion.x,
      affineHeight = motion.y,
      pictureYOffset = Support.alignY(0, own._inset, motion.curY, 0),
    })
    return false
  end
  return Support.newBody(kind, services, {
    _activation = activation,
    _inset = inset,
    _phase = "start-row",
    _row = 1,
    _motion = nil,
  }, advance)
end

ScaleMotion["pokemon-picture-table-driven-position-transition"] = newStretchSteps

-- BattleAnimFunc_AttackerHop (battle_anim_move_effects.c, selector 19) walks
-- the three gBattleAnimAttackerHopScales rows together with the matching
-- gBattleAnimAttackerHopOffsets rows (asm/battle_anim_data.s), three rounds
-- of three legs, then destroys its task. Each leg writes the affine pair and
-- the hop row aligned to the current scale.
local HOP_SCALES = {
  { startX = 100, endX = 120, startY = 100, endY = 80, duration = 5 },
  { startX = 120, endX = 100, startY = 80, endY = 120, duration = 5 },
  { startX = 100, endX = 100, startY = 120, endY = 100, duration = 5 },
}
local HOP_OFFSETS = {
  { startY = 0, endY = 16, duration = 5 },
  { startY = 16, endY = 0, duration = 5 },
  { startY = 0, endY = 0, duration = 5 },
}
local HOP_SCALE_DIVISOR = 100
local HOP_ROUNDS = 3

---@class SourceTimedAttackerHop
---@field _activation table<string, unknown> attacker picture the hop owns
---@field _inset integer battler picture inset behind the row alignment
---@field _phase string current native state
---@field _hop integer next source leg behind the run
---@field _round integer completed source rounds
---@field _scale SourceTimedScaleMotion? leg scale motion under advancement
---@field _row SourceTimedLinearMotion? leg hop motion under advancement

---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return SourceTimedBody runnable attacker-hop task
local function newAttackerHop(kind, args, context, services)
  local parameters = Support.parameters(args, kind)
  local activation = ownedActivation(args, context, kind, "attacker")
  local inset = pictureInset(parameters, kind)
  ---@param self SourceTimedBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    local own = self --[[@as SourceTimedAttackerHop]]
    if own._phase == "start-hop" then
      local scale = HOP_SCALES[own._hop]
      local offset = HOP_OFFSETS[own._hop]
      own._scale =
        Support.scaleMotion(scale.startX, scale.endX, scale.startY, scale.endY, HOP_SCALE_DIVISOR, scale.duration)
      own._row = Support.linear(0, 0, offset.startY, offset.endY, offset.duration)
      own._hop = own._hop + 1
      own._phase = "hop"
      return false
    end
    if own._phase == "done" then
      return true
    end
    local done = 0
    local scale = own._scale --[[@as SourceTimedScaleMotion]]
    local row = own._row --[[@as SourceTimedLinearMotion]]
    if not scale:step() then
      done = done + 1
    end
    if not row:step() then
      done = done + 1
    end
    if done >= 2 then
      if own._hop > #HOP_SCALES then
        own._round = own._round + 1
        own._hop = 1
        own._phase = own._round >= HOP_ROUNDS and "done" or "start-hop"
      else
        own._phase = "start-hop"
      end
    end
    self:publishPicture(own._activation, {
      affineMode = true,
      affineWidth = scale.x,
      affineHeight = scale.y,
      pictureYOffset = Support.alignY(row.y, own._inset, scale.curY, 0),
    })
    return false
  end
  return Support.newBody(kind, services, {
    _activation = activation,
    _inset = inset,
    _phase = "start-hop",
    _hop = 1,
    _round = 0,
    _scale = nil,
    _row = nil,
  }, advance)
end

ScaleMotion["pokemon-picture-repeated-scale-position-transition"] = newAttackerHop

-- BattleAnimFunc_StretchShakeDefender (battle_anim_effects.c, selector 43):
-- one four-tick stretch to 7/10 by 30/10 wrapped in a two-round horizontal
-- shake of two pixels, then the three-tick reciprocal restore, then the
-- authored X, Y and 1.0 affine pair on the retirement tick.
local STRETCH_SHAKE_START_X = 10
local STRETCH_SHAKE_END_X = 7
local STRETCH_SHAKE_START_Y = 10
local STRETCH_SHAKE_END_Y = 30
local STRETCH_SHAKE_DIVISOR = 10
local STRETCH_SHAKE_OUT_TICKS = 4
local STRETCH_SHAKE_BACK_TICKS = 3
local STRETCH_SHAKE_REPEATS = 1
local STRETCH_SHAKE_AMPLITUDE = 2
local STRETCH_SHAKE_INTERVAL = 1
local STRETCH_SHAKE_ROUNDS = 2

---@class SourceTimedStretchShake
---@field _activation table<string, unknown> defender picture the stretch owns
---@field _inset integer battler picture inset behind the row alignment
---@field _phase string current native state
---@field _repeats integer remaining stretch and restore cycles
---@field _shake SourceTimedShake horizontal source shake
---@field _shakeX integer last published shake offset
---@field _motion SourceTimedScaleMotion? leg scale motion under advancement
---@field _affineWidth integer last stepped horizontal scale
---@field _affineHeight integer last stepped vertical scale
---@field _curScaleY integer last stepped vertical scale in fixed point

---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return SourceTimedBody runnable stretch and shake task
local function newStretchShake(kind, args, context, services)
  local parameters = Support.parameters(args, kind)
  local activation = ownedActivation(args, context, kind, "defender")
  local inset = pictureInset(parameters, kind)
  ---@param self SourceTimedBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    local own = self --[[@as SourceTimedStretchShake]]
    if own._phase == "stretch-start" then
      own._motion = Support.scaleMotion(
        STRETCH_SHAKE_START_X,
        STRETCH_SHAKE_END_X,
        STRETCH_SHAKE_START_Y,
        STRETCH_SHAKE_END_Y,
        STRETCH_SHAKE_DIVISOR,
        STRETCH_SHAKE_OUT_TICKS
      )
      own._phase = "stretch"
    elseif own._phase == "restore-start" then
      own._motion = Support.scaleMotion(
        STRETCH_SHAKE_END_X,
        STRETCH_SHAKE_START_X,
        STRETCH_SHAKE_END_Y,
        STRETCH_SHAKE_START_Y,
        STRETCH_SHAKE_DIVISOR,
        STRETCH_SHAKE_BACK_TICKS
      )
      own._phase = "restore"
    end
    if own._phase ~= "stretch" and own._phase ~= "restore" then
      -- STRETCH_SHAKE_STATE_END: the source restores the authored X, Y and the
      -- 1.0 affine pair, then destroys its task.
      self:publishPicture(own._activation, {
        affineMode = true,
        affineWidth = AFFINE_ONE,
        affineHeight = AFFINE_ONE,
        pictureXOffset = 0,
        pictureYOffset = 0,
      })
      return true
    end
    if own._shake:step() then
      -- UpdateShakePokepic writes X = x + shake.x and Y = y + shake.y, and the
      -- scale alignment below rewrites Y from the authored row; the source
      -- amplitudes are horizontal only, so the shake publishes as X.
      own._shakeX = own._shake.x
    end
    local motion = own._motion --[[@as SourceTimedScaleMotion]]
    local stepped = motion:step()
    if stepped then
      own._affineWidth = motion.x
      own._affineHeight = motion.y
      own._curScaleY = motion.curY
    end
    self:publishPicture(own._activation, {
      affineMode = true,
      affineWidth = own._affineWidth,
      affineHeight = own._affineHeight,
      pictureXOffset = Support.clampOffset(own._shakeX),
      pictureYOffset = Support.alignY(0, own._inset, own._curScaleY, 0),
    })
    if stepped then
      return false
    end
    if own._phase == "stretch" then
      own._phase = "restore-start"
      return false
    end
    own._repeats = own._repeats - 1
    own._phase = own._repeats <= 0 and "done" or "stretch-start"
    return false
  end
  return Support.newBody(kind, services, {
    _activation = activation,
    _inset = inset,
    _phase = "stretch-start",
    _repeats = STRETCH_SHAKE_REPEATS,
    _shake = Support.shake(STRETCH_SHAKE_AMPLITUDE, 0, STRETCH_SHAKE_INTERVAL, STRETCH_SHAKE_ROUNDS) --[[@as SourceTimedShake]],
    _shakeX = 0,
    _motion = nil,
    _affineWidth = AFFINE_ONE,
    _affineHeight = AFFINE_ONE,
    _curScaleY = AFFINE_ONE,
  }, advance)
end

ScaleMotion["pokemon-picture-reciprocal-position-palette-transition"] = newStretchShake

-- BattleAnimFunc_StretchFadeSprite (battle_anim_move_effects.c, selector 49)
-- runs an entry tick inside its own callback (the picture flattens to 5/100),
-- then twelve stretch ticks that raise the alpha pair, a four-tick hold,
-- twelve shrink ticks, and the free frame one tick after the last scale step.
-- The native animates a raw effect sprite (BattleAnimSystem_GetSprite) at an
-- absolute screen row (76/120 on the player side, 144/64 on the enemy side,
-- 179/120 in a contest) and blends it against the battlefield through
-- reg_G2_BLDALPHA; the sprite frames, its XLU OAM mode, and that absolute
-- placement have no scene expression, so the body drives the presented
-- attacker picture with the same scale and alpha timeline. The native reads
-- script arg 0 and discards it.
local STRETCH_FADE_INSET = 16
local STRETCH_FADE_ENTRY_START_Y = 5
local STRETCH_FADE_ENTRY_TICKS = 1
local STRETCH_FADE_START_X = 100
local STRETCH_FADE_TURN_X = 60
local STRETCH_FADE_START_Y = 5
local STRETCH_FADE_TALL_Y = 150
local STRETCH_FADE_SHORT_Y = 10
local STRETCH_FADE_TICKS = 12
local STRETCH_FADE_HOLD_TICKS = 4
local STRETCH_FADE_PEAK_EVA = 31
local STRETCH_FADE_PEAK_EVB = 4
local STRETCH_FADE_START_EVB = 31
local STRETCH_FADE_END_EVA = 0
local STRETCH_FADE_END_EVB = 31

---@class SourceTimedStretchFade
---@field _activation table<string, unknown> attacker picture the run owns
---@field _phase string current native state
---@field _motion SourceTimedScaleMotion? leg scale motion under advancement
---@field _hold integer source hold ticks spent
---@field _eva integer current source sprite alpha weight
---@field _evb integer current source background alpha weight

-- Publishes the affine pair, the scale-aligned row, and the source alpha pair
-- the run owns. The coefficients are the native five-bit field (0..31); the
-- scene blend register reads them clamped to its 0..16 register range.
---@param sourceTimedBody SourceTimedBody body under publication
---@param own SourceTimedStretchFade run state behind the pose
local function publishStretchFade(sourceTimedBody, own)
  local motion = own._motion --[[@as SourceTimedScaleMotion]]
  sourceTimedBody:publishPicture(own._activation --[[@as table<string, unknown>]], {
    affineMode = true,
    affineWidth = motion.x,
    affineHeight = motion.y,
    pictureYOffset = Support.alignY(0, STRETCH_FADE_INSET, motion.curY, 0),
  })
  sourceTimedBody:writeScalar({ blendCoefficientA = own._eva, blendCoefficientB = own._evb })
end

---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return SourceTimedBody runnable stretch and fade task
local function newStretchFade(kind, args, context, services)
  Support.parameters(args, kind)
  local activation = ownedActivation(args, context, kind, "attacker")
  ---@param self SourceTimedBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    local own = self --[[@as SourceTimedStretchFade]]
    local phase = own._phase
    if phase == "init" then
      -- STRETCH_FADE_STATE_INIT: the source initializes the stretch leg and
      -- writes nothing on this tick.
      own._motion = Support.scaleMotion(
        STRETCH_FADE_START_X,
        STRETCH_FADE_TURN_X,
        STRETCH_FADE_START_Y,
        STRETCH_FADE_TALL_Y,
        100,
        STRETCH_FADE_TICKS
      )
      own._phase = "stretch"
      return false
    end
    if phase == "hold" then
      -- STRETCH_FADE_STATE_HOLD: four ticks with no write.
      own._hold = own._hold + 1
      if own._hold >= STRETCH_FADE_HOLD_TICKS then
        own._phase = "shrink"
      end
      return false
    end
    if phase == "done" then
      return true
    end
    local motion = own._motion --[[@as SourceTimedScaleMotion]]
    if not motion:step() then
      if phase == "stretch" then
        own._motion = Support.scaleMotion(
          STRETCH_FADE_TURN_X,
          STRETCH_FADE_TALL_Y,
          STRETCH_FADE_TALL_Y,
          STRETCH_FADE_SHORT_Y,
          100,
          STRETCH_FADE_TICKS
        )
        own._hold = 0
        own._phase = "hold"
      else
        own._phase = "done"
      end
      return false
    end
    if phase == "stretch" then
      own._eva = math.min(STRETCH_FADE_PEAK_EVA, own._eva + 1)
      own._evb = math.max(STRETCH_FADE_PEAK_EVB, own._evb - 1)
    else
      own._eva = math.max(STRETCH_FADE_END_EVA, own._eva - 1)
      own._evb = math.min(STRETCH_FADE_END_EVB, own._evb + 1)
    end
    publishStretchFade(self, own)
    return false
  end
  local body = Support.newBody(kind, services, {
    _activation = activation,
    _phase = "init",
    _motion = nil,
    _hold = 0,
    _eva = 0,
    _evb = STRETCH_FADE_START_EVB,
  }, advance)
  -- The callback itself writes the flattened entry pose before its task starts
  -- (InitScaleMotionXYS16 with a one-tick step and the aligned row write).
  local entry = Support.scaleMotion(
    STRETCH_FADE_START_X,
    STRETCH_FADE_START_X,
    STRETCH_FADE_START_X,
    STRETCH_FADE_ENTRY_START_Y,
    100,
    STRETCH_FADE_ENTRY_TICKS
  )
  entry:step()
  body:publishPicture(activation, {
    affineMode = true,
    affineWidth = entry.x,
    affineHeight = entry.y,
    pictureYOffset = Support.alignY(0, STRETCH_FADE_INSET, entry.curY, 0),
  })
  return body
end

ScaleMotion["pokemon-picture-affine-sprite-entry-transition"] = newStretchFade

-- BattleAnimFunc_ShrinkSpriteOnDefender (battle_anim_move_effects.c, selector
-- 58): ten ticks shrinking the defender's battler sprites from 100/100 to
-- 20/100, each aligned to the defender picture row, then a tick that hides two
-- of the three copies and destroys the task (the source repeats its second
-- hide and leaves the third copy drawn). Those copies are script-created
-- battler sprites, which the scene does not present, so the body drives the
-- presented defender picture and restores it when the task retires instead of
-- publishing the copy hide as a terminal pose.
local SHRINK_START_SCALE = 100
local SHRINK_END_SCALE = 20
local SHRINK_SCALE_DIVISOR = 100
local SHRINK_TICKS = 10

---@class SourceTimedShrinkSprite
---@field _activation table<string, unknown> defender picture the shrink owns
---@field _inset integer battler picture inset behind the row alignment
---@field _motion SourceTimedScaleMotion shrink motion under advancement

---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return SourceTimedBody runnable shrink task
local function newShrinkSprite(kind, args, context, services)
  local parameters = Support.parameters(args, kind)
  local activation = ownedActivation(args, context, kind, "defender")
  local inset = pictureInset(parameters, kind)
  ---@param self SourceTimedBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    local own = self --[[@as SourceTimedShrinkSprite]]
    if not own._motion:step() then
      return true
    end
    self:publishPicture(own._activation, {
      affineMode = true,
      affineWidth = own._motion.x,
      affineHeight = own._motion.y,
      pictureYOffset = Support.alignY(0, own._inset, own._motion.curY, 0),
    })
    return false
  end
  return Support.newBody(kind, services, {
    _activation = activation,
    _inset = inset,
    _motion = Support.scaleMotion(
      SHRINK_START_SCALE,
      SHRINK_END_SCALE,
      SHRINK_START_SCALE,
      SHRINK_END_SCALE,
      SHRINK_SCALE_DIVISOR,
      SHRINK_TICKS
    ) --[[@as SourceTimedScaleMotion]],
  }, advance)
end

ScaleMotion["pokemon-picture-three-sprite-position-wave-transition"] = newShrinkSprite

-- BattleAnimFunc_SquashSprite (battle_anim_move_effects.c, selector 70) runs
-- its first machine frame inside the callback (BattleAnim_CreateTaskAndRun):
-- fifteen frames raise reg_G2_BLDALPHA from 0/15 to 15/0 while the copy's
-- palette blends toward white, three frames squash it to 1.6 by 0.4, the
-- fourth frame reaches 0.2 height and hides it, then the source frees both
-- palette blends, starts the reverse blend on its second copy, and destroys
-- the task on the frame after that blend finishes. The native squashes a copy
-- of the attacker's battler sprite placed 32 pixels beside the original, whose
-- flip mode owns the copy's horizontal scale sign, and its palette blends
-- target the copies; the scene presents the mon itself, so the body squashes
-- the attacker picture in place (no copy offset, no mirrored scale sign) and
-- drives the white palette blend on it as the only presentable flash.
local SQUASH_BLEND_TICKS = 15
local SQUASH_SQUASH_TICKS = 4
local SQUASH_SCALE_STEP = 0.2
local SQUASH_START_EVA = 0
local SQUASH_START_EVB = 15
local SQUASH_PALETTE_LEVELS = 15
local SQUASH_PALETTE_TICKS = 16
local SQUASH_PALETTE_COLOR = 0x7FFF -- RGB_WHITE as a native RGB555 word
local SQUASH_START_BLEND_FRAME = SQUASH_BLEND_TICKS + SQUASH_SQUASH_TICKS + 1
local SQUASH_RETIRE_FRAME = SQUASH_START_BLEND_FRAME + SQUASH_PALETTE_TICKS + 1

---@class SourceTimedSquashSprite
---@field _activation table<string, unknown> attacker picture the squash owns
---@field _frame integer native machine frame reached
---@field _eva integer current source sprite alpha weight
---@field _evb integer current source background alpha weight
---@field _palette integer current source white blend level
---@field _affineWidth integer last stepped horizontal scale
---@field _affineHeight integer last stepped vertical scale

-- Publishes the affine pair, the source white palette blend level, and the
-- copy visibility the source store applies. The blend keeps its register pair
-- while the squash frames run, exactly like the untouched hardware register.
---@param sourceTimedBody SourceTimedBody body under publication
---@param own SourceTimedSquashSprite run state behind the pose
---@param visible boolean whether the squashed element is still drawn
local function publishSquash(sourceTimedBody, own, visible)
  sourceTimedBody:publishPicture(own._activation --[[@as table<string, unknown>]], {
    affineMode = true,
    affineWidth = own._affineWidth,
    affineHeight = own._affineHeight,
    vanished = not visible,
    pictureVisible = visible,
    paletteFade = {
      start = Support.clampLevel(own._palette),
      finish = Support.clampLevel(own._palette),
      framesPer = 0,
      targetColor = SQUASH_PALETTE_COLOR,
    },
  })
end

---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return SourceTimedBody runnable squash task
local function newSquashSprite(kind, args, context, services)
  Support.parameters(args, kind)
  local activation = ownedActivation(args, context, kind, "attacker")
  ---@param self SourceTimedBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    local own = self --[[@as SourceTimedSquashSprite]]
    own._frame = own._frame + 1
    local frame = own._frame
    if frame <= SQUASH_BLEND_TICKS then
      own._eva = own._eva + 1
      own._evb = own._evb - 1
      own._palette = math.min(SQUASH_PALETTE_LEVELS, frame - 1)
      self:writeScalar({ blendCoefficientA = own._eva, blendCoefficientB = own._evb })
      publishSquash(self, own, true)
      return false
    end
    local squashFrame = frame - SQUASH_BLEND_TICKS
    if squashFrame <= SQUASH_SQUASH_TICKS then
      own._palette = SQUASH_PALETTE_LEVELS
      if squashFrame == SQUASH_SQUASH_TICKS then
        publishSquash(self, own, false)
        return false
      end
      own._affineWidth = math.floor((1 + SQUASH_SCALE_STEP * squashFrame) * 256)
      own._affineHeight = math.floor((1 - SQUASH_SCALE_STEP * squashFrame) * 256)
      publishSquash(self, own, true)
      return false
    end
    if frame == SQUASH_START_BLEND_FRAME then
      -- SQUASH_SPRITE_STATE_START_BLEND: the source frees both copy palette
      -- blends and starts the reverse blend on its second copy, which the
      -- scene does not present.
      return false
    end
    if frame < SQUASH_RETIRE_FRAME then
      -- SQUASH_SPRITE_STATE_WAIT_BLEND: the source waits out that reverse
      -- blend one frame at a time.
      return false
    end
    return true
  end
  local body = Support.newBody(kind, services, {
    _activation = activation,
    _frame = 0,
    _eva = SQUASH_START_EVA,
    _evb = SQUASH_START_EVB,
    _palette = 0,
    _affineWidth = AFFINE_ONE,
    _affineHeight = AFFINE_ONE,
  }, advance)
  advance(body)
  return body
end

ScaleMotion["pokemon-picture-affine-blend-palette-transition"] = newSquashSprite

return ScaleMotion
