-- Source-timed native battle animation bodies: the position motion family.
-- Each entry maps one producer task kind to its body constructor and
-- reproduces one overlay-07 callback whose native machine owns a fixed
-- internal timeline instead of reading script timing words
-- (battle_anim_move_effects.c and battle_anim_effects.c in the pinned
-- pret/pokeheartgold tree). See Support.lua for the journaled write seams and
-- the lifecycle every body shares.

local PresentationFxMath = require("libs.hgss.src.presentation.PresentationFxMath")
local Support = require("libs.hgss.src.presentation.sourceTimed.Support")

local PositionMotion = {}

-- The natives in this family address their own battler
-- (BattleAnimSystem_GetAttacker or GetDefender) rather than a
-- producer-lowered target, so an occurrence without one resolves the
-- presented picture of that side directly.
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

-- BattleAnimFunc_ShakeDefenderWithOverlay (battle_anim_move_effects.c,
-- selector 11 of gBattleAnimFuncTable): BattleAnimUtil_InitShake(2, 0, 1, 6)
-- displaces the defender picture two pixels horizontally while two
-- BattleAnimUtil_InitScaleMotionXY legs run — seven ticks stretching a
-- battler sprite from 10/10 to 12/15 and four ticks settling back — and the
-- settle leg's exhausted frame writes the authored X/Y before the following
-- frame destroys the task. Every frame writes POKEPIC_X = x + shake.x and
-- POKEPIC_Y = y + shake.y, which is the whole visible picture timeline.
local SHAKE_OVERLAY_AMPLITUDE_X = 2
local SHAKE_OVERLAY_AMPLITUDE_Y = 0
local SHAKE_OVERLAY_INTERVAL_TICKS = 1
local SHAKE_OVERLAY_ROUNDS = 6
local SHAKE_OVERLAY_STRETCH = { startX = 10, endX = 12, startY = 10, endY = 15, divisor = 10, ticks = 7 }
local SHAKE_OVERLAY_SETTLE = { startX = 12, endX = 10, startY = 15, endY = 10, divisor = 10, ticks = 4 }

---@class SourceTimedShakeDefenderOverlay
---@field _activation table<string, unknown> defender picture the shake owns
---@field _phase string current native state
---@field _shake SourceTimedShake horizontal source shake
---@field _scale SourceTimedScaleMotion scale leg under advancement
---@field _inset integer battler picture inset behind the scale alignment

-- The source applies both scale legs to the script-created battler sprite in
-- slot 0 (BattleAnimSystem_GetBattlerSprite) and blends it over the
-- battlefield through reg_G2_BLDALPHA at 28/15; the scene presents the
-- battler picture, not that sprite copy, so the body publishes the picture
-- position the source writes and leaves the copy's scale and its blend
-- register unreproduced.
---@param own SourceTimedShakeDefenderOverlay run state behind the pose
---@return table<string, unknown> picture overlay behind the native position writes
local function shakeOverlayPatch(own)
  return {
    pictureXOffset = Support.clampOffset(own._shake.x),
    pictureYOffset = Support.clampOffset(own._shake.y),
  }
end

---@param step table<string, integer> one gBattleAnimStretchShake-style row
---@return SourceTimedScaleMotion scale motion behind the row
local function shakeOverlayScale(step)
  return Support.scaleMotion(step.startX, step.endX, step.startY, step.endY, step.divisor, step.ticks)
end

---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return SourceTimedBody runnable defender shake task
local function newShakeDefenderOverlay(kind, args, context, services)
  local activation = ownedActivation(args, context, kind, "defender")
  ---@param self SourceTimedBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    local own = self --[[@as SourceTimedShakeDefenderOverlay]]
    if own._phase == "retire" then
      -- SHAKE_OVERLAY_STATE_FINISH: the source destroys its task without a
      -- write of its own.
      return true
    end
    own._shake:step()
    local stepped = own._scale:step()
    if own._phase == "shake" then
      self:publishPicture(own._activation, shakeOverlayPatch(own))
      if not stepped then
        -- SHAKE_OVERLAY_STATE_SHAKE retired: the source re-initializes the
        -- scale motion from 12/15 back to 10/10 for the settle leg.
        own._scale = shakeOverlayScale(SHAKE_OVERLAY_SETTLE)
        own._phase = "settle"
      end
      return false
    end
    if stepped then
      self:publishPicture(own._activation, shakeOverlayPatch(own))
      return false
    end
    -- SHAKE_OVERLAY_STATE_SETTLE retired: this frame's apply runs first and
    -- then the source writes the authored X/Y back, so the picture lands on
    -- its presented position before the next frame destroys the task.
    self:publishPicture(own._activation, { pictureXOffset = 0, pictureYOffset = 0 })
    own._phase = "retire"
    return false
  end
  return Support.newBody(kind, services, {
    _activation = activation,
    _phase = "shake",
    _shake = Support.shake(
      SHAKE_OVERLAY_AMPLITUDE_X,
      SHAKE_OVERLAY_AMPLITUDE_Y,
      SHAKE_OVERLAY_INTERVAL_TICKS,
      SHAKE_OVERLAY_ROUNDS
    ) --[[@as SourceTimedShake]],
    _scale = shakeOverlayScale(SHAKE_OVERLAY_STRETCH) --[[@as SourceTimedScaleMotion]],
  }, advance)
end

PositionMotion["pokemon-picture-scale-position-transition"] = newShakeDefenderOverlay

-- A coefficient pair walk on the native main queue
-- (BattleAnimUtil_StartBlendAlphaMotion / IsBlendAlphaMotionDone). The native
-- runs it as its own task beside the animation task: one step per source
-- tick, the register written from the stepped pair, and the closing frame
-- that reports done writes nothing.
---@class SourceTimedBlendRamp
---@field motion SourceTimedLinearMotion coefficient pair under advancement
---@field done boolean the closing frame has been reached
local BlendRamp = {}
BlendRamp.__index = BlendRamp

---@param startEva integer first EVA coefficient
---@param endEva integer last EVA coefficient
---@param startEvb integer first EVB coefficient
---@param endEvb integer last EVB coefficient
---@param ticks integer positive step count
---@return SourceTimedBlendRamp ramp record
local function blendRamp(startEva, endEva, startEvb, endEvb, ticks)
  return setmetatable({ motion = Support.linear(startEva, endEva, startEvb, endEvb, ticks), done = false }, BlendRamp)
end

---@param self SourceTimedBlendRamp ramp under advancement
---@return boolean done true on the closing frame
function BlendRamp:step()
  if self.done then
    return true
  end
  if not self.motion:step() then
    self.done = true
  end
  return self.done
end

-- BattleAnimFunc_SkewSlideAttackerBg (battle_anim_effects.c, selector 12):
-- the callback hides the attacker picture (POKEPIC_VANISHED), runs its own
-- first frame, and then shears the script-staged effect plane for the
-- twenty-four ticks of BattleAnimUtil_InitLinearMotion(0, 80, 0, 40, 24),
-- blends that plane over the battlefield (31/0 to 0/31 over sixteen frames),
-- holds ten ticks, blends back, and restores VANISHED on the frame the
-- reverse blend finishes. The skew itself is per-scanline registration
-- (BattleAnimTask_SkewSlideAttackerBgUpdateScroll) of a plane the scene does
-- not draw, so the body publishes the picture vanish and the blend register
-- the native drives, and leaves the shear, the plane's BG2 position, and its
-- cleared tile data unreproduced.
local SKEW_SLIDE_START_X = 0
local SKEW_SLIDE_END_X = 80
local SKEW_SLIDE_START_Y = 0
local SKEW_SLIDE_END_Y = 40
local SKEW_SLIDE_SCROLL_TICKS = 24
local SKEW_SLIDE_BLEND_TICKS = 16
local SKEW_SLIDE_HOLD_LIMIT = 8
local SKEW_SLIDE_PLANE_EVA = 31
local SKEW_SLIDE_PLANE_EVB = 0

---@class SourceTimedSkewSlide
---@field _activation table<string, unknown> attacker picture the slide owns
---@field _phase string current native state
---@field _slide SourceTimedLinearMotion source shear motion behind the scroll boundary
---@field _blend SourceTimedBlendRamp? coefficient pair under advancement
---@field _hold integer hold ticks spent

-- The coefficients are the native five-bit reg_G2_BLDALPHA field (0..31);
-- the scene blend register reads them clamped to its own 0..16 range.
---@param sourceTimedBody SourceTimedBody body under publication
---@param own SourceTimedSkewSlide run state behind the register write
local function publishSkewBlend(sourceTimedBody, own)
  local blend = own._blend --[[@as SourceTimedBlendRamp]]
  sourceTimedBody:writeScalar({
    blendCoefficientA = blend.motion.x,
    blendCoefficientB = blend.motion.y,
  })
end

---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return SourceTimedBody runnable effect-plane slide task
local function newSkewSlide(kind, args, context, services)
  local activation = ownedActivation(args, context, kind, "attacker")
  ---@param self SourceTimedBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    local own = self --[[@as SourceTimedSkewSlide]]
    local phase = own._phase
    if phase == "scroll" then
      if own._slide:step() then
        return false
      end
      -- SKEW_SLIDE_STATE_SCROLL retired: BattleAnimUtil_SetBlendBgOverBattleBg
      -- writes the effect plane's 31/0 register pair and the reverse walk
      -- starts on the following frame.
      own._blend = blendRamp(SKEW_SLIDE_PLANE_EVA, 0, SKEW_SLIDE_PLANE_EVB, 31, SKEW_SLIDE_BLEND_TICKS)
      own._phase = "blend-in"
      self:writeScalar({ blendCoefficientA = SKEW_SLIDE_PLANE_EVA, blendCoefficientB = SKEW_SLIDE_PLANE_EVB })
      return false
    end
    if phase == "blend-in" then
      if own._blend:step() then
        -- SKEW_SLIDE_STATE_BLEND_IN retired: the plane cross-fade finished and
        -- the scanline wave is disabled; the hold then re-writes the plane's
        -- BG2 position for ten frames while the register keeps 0/31.
        own._phase = "hold"
        own._hold = 0
        return false
      end
      publishSkewBlend(self, own)
      return false
    end
    if phase == "hold" then
      -- SKEW_SLIDE_STATE_HOLD re-writes the effect plane's BG2 position every
      -- frame; work->timer counts up and the tenth frame starts the reverse
      -- walk from the held 0/31 pair back to 31/0.
      own._hold = own._hold + 1
      if own._hold > SKEW_SLIDE_HOLD_LIMIT then
        own._blend = blendRamp(0, SKEW_SLIDE_PLANE_EVA, 31, SKEW_SLIDE_PLANE_EVB, SKEW_SLIDE_BLEND_TICKS)
        own._phase = "blend-out"
      end
      return false
    end
    if phase == "blend-out" then
      if own._blend:step() then
        -- SKEW_SLIDE_STATE_BLEND_OUT retired: POKEPIC_VANISHED goes back to
        -- FALSE, so the picture returns on this frame.
        own._phase = "retire"
        self:publishPicture(own._activation, { vanished = false, pictureVisible = true })
        return false
      end
      publishSkewBlend(self, own)
      return false
    end
    -- SKEW_SLIDE_STATE_END: the source frees the scanline wave, restores the
    -- battle BG priorities, and destroys its task.
    return true
  end
  local body = Support.newBody(kind, services, {
    _activation = activation,
    _phase = "scroll",
    _slide = Support.linear(
      SKEW_SLIDE_START_X,
      SKEW_SLIDE_END_X,
      SKEW_SLIDE_START_Y,
      SKEW_SLIDE_END_Y,
      SKEW_SLIDE_SCROLL_TICKS
    ) --[[@as SourceTimedLinearMotion]],
    _blend = nil,
    _hold = 0,
  }, advance)
  -- The callback itself hides the picture and runs its first machine frame.
  body:publishPicture(activation, { vanished = true, pictureVisible = false })
  advance(body)
  return body
end

PositionMotion["battle-background-pokepic-slide"] = newSkewSlide

-- BattleAnimFunc_AttackerDip (battle_anim_effects.c, selector 29): four
-- six-tick BattleAnimUtil_InitLinearMotion legs over y 0 -> 32 -> 0 -> 32 ->
-- 0, each initialized on its own frame and every leg tick writing
-- POKEPIC_X/Y = x + move.x, y + move.y. The leg's exhausted frame only
-- advances the leg counter, and the frame after the fourth leg destroys the
-- task.
local DIP_LEG_TICKS = 6
local DIP_DEPTH = 32
local DIP_LEG_COUNT = 4

---@class SourceTimedAttackerDip
---@field _activation table<string, unknown> attacker picture the dip owns
---@field _phase string current native state
---@field _leg integer source leg behind the current motion
---@field _move SourceTimedLinearMotion? vertical leg motion under advancement

-- BattleAnimTask_AttackerDipSetLeg: the outward legs lower the picture by 32
-- pixels and the return legs raise it back.
---@param leg integer source leg index in 0..3
---@return SourceTimedLinearMotion vertical leg motion
local function dipLeg(leg)
  local outward = leg % 2 == 0
  return Support.linear(0, 0, outward and 0 or DIP_DEPTH, outward and DIP_DEPTH or 0, DIP_LEG_TICKS)
end

---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return SourceTimedBody runnable attacker dip task
local function newAttackerDip(kind, args, context, services)
  local activation = ownedActivation(args, context, kind, "attacker")
  ---@param self SourceTimedBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    local own = self --[[@as SourceTimedAttackerDip]]
    if own._phase == "next-leg" then
      own._move = dipLeg(own._leg)
      own._phase = "move"
      return false
    end
    if own._phase == "retire" then
      -- DIP_STATE_END: the source destroys its task without a write.
      return true
    end
    local move = own._move --[[@as SourceTimedLinearMotion]]
    if move:step() then
      self:publishPicture(own._activation, {
        pictureXOffset = Support.clampOffset(move.x),
        pictureYOffset = Support.clampOffset(move.y),
      })
      return false
    end
    own._leg = own._leg + 1
    own._phase = own._leg < DIP_LEG_COUNT and "next-leg" or "retire"
    return false
  end
  return Support.newBody(kind, services, {
    _activation = activation,
    _phase = "next-leg",
    _leg = 0,
    _move = nil,
  }, advance)
end

PositionMotion["pokemon-picture-oscillating-axis-motion"] = newAttackerDip

-- BattleAnimUtil_GetBattlerSideSignByMode: the player side reads +1 and the
-- enemy side reads -1, the parity of the native battler side type. This
-- callback sides its ellipse, its lunge, and both returns with the attacker's
-- sign.
---@param context table<string, unknown> occurrence-bound playback context
---@param combatant number combatant whose side is under reading
---@param kind string task kind under diagnosis
---@return integer native side sign of the moved battler
local function sideSign(context, combatant, kind)
  local topology = type(context) == "table" and context.topology or nil
  if type(topology) == "table" then
    local candidates = { topology.attacker }
    local targets = topology.targets
    if type(targets) == "table" then
      for _, target in ipairs(targets) do
        candidates[#candidates + 1] = target
      end
    end
    for _, candidate in ipairs(candidates) do
      if type(candidate) == "table" and candidate.combatant == combatant then
        local sideType = candidate.sideType
        if type(sideType) == "number" and sideType % 1 == 0 and sideType >= 0 and sideType <= 5 then
          return sideType % 2 == 0 and 1 or -1
        end
      end
    end
  end
  error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " resolves the side of the battler it moves", 0)
end

-- BattleAnimUtil_InitSinMotion (battle_anim_emitter.c) plus
-- BattleAnimUtil_UpdateSinMotion (battle_anim_util.c): the native assigns the
-- frame count directly and derives the per-frame angle step as
-- (end - start) / duration, so the angle pair walks one authored range and
-- wraps to sixteen bits per frame. This is not
-- BattleAnimUtil_InitSinMotionFromStep (battle_anim_util.c), which instead
-- derives the frame count from a step count; the circle below is the former.
---@class SourceTimedSinMotion
---@field x integer current horizontal offset in pixels
---@field y integer current vertical offset in pixels
---@field angleX integer current horizontal angle index in 0..65535
---@field angleY integer current vertical angle index in 0..65535
---@field ampX integer horizontal amplitude in fx32
---@field ampY integer vertical amplitude in fx32
---@field stepX integer horizontal angle step per tick
---@field stepY integer vertical angle step per tick
---@field remaining integer ticks left behind the motion
local SinMotion = {}
SinMotion.__index = SinMotion

---@param startX integer horizontal angle index at the first tick
---@param endX integer horizontal angle index at the last tick
---@param startY integer vertical angle index at the first tick
---@param endY integer vertical angle index at the last tick
---@param ampX integer horizontal amplitude in fx32
---@param ampY integer vertical amplitude in fx32
---@param ticks integer positive frame count
---@return SourceTimedSinMotion motion record
local function sinMotion(startX, endX, startY, endY, ampX, ampY, ticks)
  assert(type(ticks) == "number" and ticks >= 1, "sinusoidal motions name a positive tick count")
  return setmetatable({
    x = 0,
    y = 0,
    angleX = math.floor(startX),
    angleY = math.floor(startY),
    ampX = math.floor(ampX),
    ampY = math.floor(ampY),
    stepX = PresentationFxMath.truncDiv(math.floor(endX) - math.floor(startX), ticks),
    stepY = PresentationFxMath.truncDiv(PresentationFxMath.u16(endY) - math.floor(startY), ticks),
    remaining = ticks,
  }, SinMotion)
end

-- BattleAnimUtil_UpdateSinMotion: one frame of the indexed sine and cosine
-- pair, narrowed to the native s16 picture offsets after the fixed-point
-- shift.
---@param self SourceTimedSinMotion motion under advancement
---@return boolean active true while the motion had a tick to spend
function SinMotion:step()
  if self.remaining == 0 then
    return false
  end
  self.angleX = PresentationFxMath.u16(self.angleX + self.stepX)
  self.angleY = PresentationFxMath.u16(self.angleY + self.stepY)
  self.remaining = self.remaining - 1
  self.x = PresentationFxMath.s16(
    PresentationFxMath.arithmeticShift(
      PresentationFxMath.fxMul(PresentationFxMath.sinIdx(self.angleX), self.ampX),
      Support.FX32_SHIFT
    )
  )
  self.y = PresentationFxMath.s16(
    PresentationFxMath.arithmeticShift(
      PresentationFxMath.fxMul(PresentationFxMath.cosIdx(self.angleY), self.ampY),
      Support.FX32_SHIFT
    )
  )
  return true
end

-- BattleAnimFunc_AttackerLungeKnockback (battle_anim_effects.c, selector 30):
-- LUNGE_KNOCKBACK_STATE_INIT starts a one-orbit
-- BattleAnimUtil_InitCircleMotion(1, 64) ellipse of the attacker picture
-- (32-pixel horizontal and 8-pixel vertical amplitudes around an eight-pixel
-- row baseline) and LUNGE_KNOCKBACK_STATE_CIRCLE writes POKEPIC_X/Y from it
-- for the sixty-four orbit frames. The exhausted orbit frame restores the
-- authored X/Y and starts the two-tick 32-pixel lunge; the defender is then
-- knocked back the same distance over two ticks and both pictures walk home
-- over eight ticks each, every leg frame writing the X it owns before the
-- state machine destroys the task.
local LUNGE_ORBIT_TICKS = 64
local LUNGE_ORBIT_ANGLE_END = 0xFFFF
local LUNGE_ORBIT_AMPLITUDE_X = 131072 -- the source's 2 << 16: a 32-pixel horizontal reach
local LUNGE_ORBIT_AMPLITUDE_Y = -0x8000 -- a negative eight-pixel vertical reach
local LUNGE_ORBIT_ROW = 8
local LUNGE_DISTANCE = 32
local LUNGE_LEG_TICKS = 2
local RETURN_LEG_TICKS = 8

---@class SourceTimedLungeKnockback
---@field _attacker table<string, unknown> attacker picture the ellipse and lunge own
---@field _defender table<string, unknown> defender picture the knockback owns
---@field _sign integer native attacker side sign behind every leg
---@field _phase string current native state
---@field _orbit SourceTimedSinMotion? attacker ellipse under advancement
---@field _move SourceTimedLinearMotion? horizontal leg under advancement

---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return SourceTimedBody runnable lunge and knockback task
local function newLungeKnockback(kind, args, context, services)
  local attacker = ownedActivation(args, context, kind, "attacker")
  -- The knockback leg owns the defender picture as well, so it resolves the
  -- occurrence target directly instead of reusing the attacker binding.
  local defender = Support.requiredActivation({ battlerTarget = "target" }, context, kind)
  local sign = sideSign(context, attacker.combatant, kind)
  ---@param self SourceTimedBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    local own = self --[[@as SourceTimedLungeKnockback]]
    local phase = own._phase
    if phase == "init" then
      -- LUNGE_KNOCKBACK_STATE_INIT: the ellipse takes the attacker's sign.
      own._orbit = sinMotion(
        0,
        LUNGE_ORBIT_ANGLE_END,
        0,
        LUNGE_ORBIT_ANGLE_END,
        LUNGE_ORBIT_AMPLITUDE_X * sign,
        LUNGE_ORBIT_AMPLITUDE_Y,
        LUNGE_ORBIT_TICKS
      )
      own._phase = "orbit"
      return false
    end
    if phase == "orbit" then
      local orbit = own._orbit --[[@as SourceTimedSinMotion]]
      if orbit:step() then
        self:publishPicture(own._attacker, {
          pictureXOffset = Support.clampOffset(orbit.x),
          pictureYOffset = Support.clampOffset(LUNGE_ORBIT_ROW + orbit.y),
        })
        return false
      end
      -- LUNGE_KNOCKBACK_STATE_CIRCLE retired: the source restores the
      -- authored X/Y, starts the two-tick lunge, and spends its first step on
      -- this same frame.
      own._move = Support.linear(0, LUNGE_DISTANCE * sign, 0, 0, LUNGE_LEG_TICKS)
      own._move:step()
      own._phase = "lunge"
      self:publishPicture(own._attacker, { pictureXOffset = Support.clampOffset(own._move.x), pictureYOffset = 0 })
      return false
    end
    if phase == "lunge" then
      local move = own._move --[[@as SourceTimedLinearMotion]]
      if move:step() then
        self:publishPicture(own._attacker, { pictureXOffset = Support.clampOffset(move.x), pictureYOffset = 0 })
        return false
      end
      -- LUNGE_KNOCKBACK_STATE_LUNGE retired: the defender's knockback leg
      -- starts from the defender's authored column.
      own._move = Support.linear(0, LUNGE_DISTANCE * sign, 0, 0, LUNGE_LEG_TICKS)
      own._phase = "knockback"
      return false
    end
    if phase == "knockback" then
      local move = own._move --[[@as SourceTimedLinearMotion]]
      if move:step() then
        self:publishPicture(own._defender, { pictureXOffset = Support.clampOffset(move.x) })
        return false
      end
      -- LUNGE_KNOCKBACK_STATE_KNOCKBACK retired: the attacker walks from its
      -- lunge reach back to its authored column.
      own._move = Support.linear(LUNGE_DISTANCE * sign, 0, 0, 0, RETURN_LEG_TICKS)
      own._phase = "attacker-return"
      return false
    end
    if phase == "attacker-return" then
      local move = own._move --[[@as SourceTimedLinearMotion]]
      if move:step() then
        self:publishPicture(own._attacker, { pictureXOffset = Support.clampOffset(move.x), pictureYOffset = 0 })
        return false
      end
      -- LUNGE_KNOCKBACK_STATE_ATTACKER_RETURN retired: the source parks the
      -- attacker on its authored X and starts the defender's return.
      own._move = Support.linear(LUNGE_DISTANCE * sign, 0, 0, 0, RETURN_LEG_TICKS)
      own._phase = "defender-return"
      self:publishPicture(own._attacker, { pictureXOffset = 0, pictureYOffset = 0 })
      return false
    end
    if phase == "defender-return" then
      local move = own._move --[[@as SourceTimedLinearMotion]]
      if move:step() then
        self:publishPicture(own._defender, { pictureXOffset = Support.clampOffset(move.x) })
        return false
      end
      -- LUNGE_KNOCKBACK_STATE_DEFENDER_RETURN retired: the source parks the
      -- defender on its authored X.
      own._phase = "retire"
      self:publishPicture(own._defender, { pictureXOffset = 0 })
      return false
    end
    -- LUNGE_KNOCKBACK_STATE_END: the source destroys its task without a write.
    return true
  end
  return Support.newBody(kind, services, {
    _attacker = attacker,
    _defender = defender,
    _sign = sign,
    _phase = "init",
    _orbit = nil,
    _move = nil,
  }, advance)
end

PositionMotion["pokemon-picture-two-battler-crossing-motion"] = newLungeKnockback

-- BattleAnimFunc_AttackerStretchUp (battle_anim_effects.c, selector 31): the
-- callback starts BattleAnimUtil_InitScaleMotion(10, 10, 15, 8) — 1/100
-- words, so a uniform 256 -> 384 scale over eight ticks — with a four-tick
-- delay word, and BattleAnimTask_AttackerStretchUpStep walks four step states:
-- the stretch leg writing the affine pair and the scale-aligned row, the delay
-- word retiring one frame after it passes below zero, the settle leg
-- InitScaleMotion(15, 10, 10, 8) walking the same way back, and the reset
-- state writing the identity pair. The outer machine then waits sixteen frames
-- before its teardown frame destroys the task.
local STRETCH_UP_STRETCH = { startX = 10, endX = 15, divisor = 10, ticks = 8 }
local STRETCH_UP_SETTLE = { startX = 15, endX = 10, divisor = 10, ticks = 8 }
local STRETCH_UP_HOLD_LIMIT = 4
local STRETCH_UP_DELAY_TIMER = 16
local STRETCH_UP_IDENTITY_SCALE = 256

---@class SourceTimedAttackerStretchUp
---@field _activation table<string, unknown> attacker picture the stretch owns
---@field _phase string current native state
---@field _motion SourceTimedScaleMotion? uniform scale leg under advancement
---@field _hold integer hold frames spent
---@field _timer integer delay frames left behind the settle

---@param leg table<string, integer> one uniform scale leg of the native machine
---@return SourceTimedScaleMotion uniform scale motion behind the leg
local function stretchUpScale(leg)
  return Support.scaleMotion(leg.startX, leg.endX, leg.startX, leg.endX, leg.divisor, leg.ticks)
end

-- BattleAnimUtil_SetPokepicScale writes POKEPIC_AFFINEW/H from the stepped
-- scale and BattleAnimUtil_AlignPokepicToScale then rewrites POKEPIC_Y from
-- the authored row. That alignment reads an inset of
-- BattleAnimSystem_GetBattlerHeight for this callback, which the producer does
-- not lower, so the body aligns from the flat-picture inset zero.
---@param own SourceTimedAttackerStretchUp run state behind the pose
---@return table<string, unknown> picture overlay behind the native affine writes
local function stretchUpPatch(own)
  local motion = own._motion --[[@as SourceTimedScaleMotion]]
  return {
    affineMode = true,
    affineWidth = motion.x,
    affineHeight = motion.y,
    pictureYOffset = Support.alignY(0, 0, motion.curY, 0),
  }
end

---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return SourceTimedBody runnable stretch task
local function newAttackerStretchUp(kind, args, context, services)
  local activation = ownedActivation(args, context, kind, "attacker")
  ---@param self SourceTimedBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    local own = self --[[@as SourceTimedAttackerStretchUp]]
    local phase = own._phase
    if phase == "stretch" or phase == "settle" then
      local motion = own._motion --[[@as SourceTimedScaleMotion]]
      if motion:step() then
        self:publishPicture(own._activation, stretchUpPatch(own))
        return false
      end
      -- STRETCH_UP_STEP_STATE_STRETCH/SHRINK retired: the exhausted frame
      -- advances the step state without a write of its own.
      own._phase = phase == "stretch" and "hold" or "reset"
      return false
    end
    if phase == "hold" then
      -- STRETCH_UP_STEP_STATE_HOLD: --work->delay retires one frame after it
      -- passes below zero and starts the settle leg.
      own._hold = own._hold + 1
      if own._hold > STRETCH_UP_HOLD_LIMIT then
        own._motion = stretchUpScale(STRETCH_UP_SETTLE)
        own._phase = "settle"
      end
      return false
    end
    if phase == "reset" then
      -- STRETCH_UP_STEP_STATE_RESET writes the identity pair only; POKEPIC_Y
      -- keeps the row the last settle tick aligned, which is the authored row
      -- at the returned 256 scale.
      own._phase = "delay"
      own._timer = STRETCH_UP_DELAY_TIMER
      self:publishPicture(own._activation, {
        affineMode = true,
        affineWidth = STRETCH_UP_IDENTITY_SCALE,
        affineHeight = STRETCH_UP_IDENTITY_SCALE,
        pictureYOffset = 0,
      })
      return false
    end
    if phase == "delay" then
      -- STRETCH_UP_STATE_DELAY: work->timer retires one frame after it passes
      -- below zero.
      own._timer = own._timer - 1
      if own._timer < 0 then
        own._phase = "end"
      end
      return false
    end
    -- STRETCH_UP_STATE_END: the source frees its work and destroys the task.
    return true
  end
  return Support.newBody(kind, services, {
    _activation = activation,
    _phase = "stretch",
    _motion = stretchUpScale(STRETCH_UP_STRETCH) --[[@as SourceTimedScaleMotion]],
    _hold = 0,
    _timer = 0,
  }, advance)
end

PositionMotion["pokemon-picture-two-phase-entry-motion"] = newAttackerStretchUp

-- BattleAnimFunc_AttackerShakeLunge (battle_anim_effects.c, selector 47):
-- BattleAnimUtil_InitShake(4, 0, 1, 4) shakes the authored column for sixteen
-- frames, then the picture lunges 40 pixels along the attacker's side sign and
-- seven pixels against its vertical side sign over four ticks, holds a delay
-- word of eight, walks the same leg home over four ticks, and the teardown
-- state writes the authored X/Y back before it destroys the task. Every write
-- here is a picture position, so the body reproduces the whole timeline.
local SHAKE_LUNGE_AMPLITUDE_X = 4
local SHAKE_LUNGE_AMPLITUDE_Y = 0
local SHAKE_LUNGE_INTERVAL_TICKS = 1
local SHAKE_LUNGE_ROUNDS = 4
local SHAKE_LUNGE_REACH = 40
local SHAKE_LUNGE_LIFT = -7
local SHAKE_LUNGE_LEG_TICKS = 4
local SHAKE_LUNGE_HOLD_LIMIT = 8

---@class SourceTimedHeightPositionTransition
---@field _activation table<string, unknown> attacker picture the shake and lunge own
---@field _reachX integer signed horizontal lunge reach
---@field _reachY integer signed vertical lunge reach
---@field _phase string current native state
---@field _shake SourceTimedShake? source shake under advancement
---@field _move SourceTimedLinearMotion? lunge or return leg under advancement
---@field _hold integer hold frames spent

---@param startX integer leg start horizontal offset
---@param startY integer leg start vertical offset
---@param endX integer leg end horizontal offset
---@param endY integer leg end vertical offset
---@return SourceTimedLinearMotion leg motion behind the picture
local function shakeLungeLeg(startX, startY, endX, endY)
  return Support.linear(startX, endX, startY, endY, SHAKE_LUNGE_LEG_TICKS)
end

---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return SourceTimedBody runnable shake and lunge task
local function newHeightPositionTransition(kind, args, context, services)
  local activation = ownedActivation(args, context, kind, "attacker")
  -- work->dirX reads BattleAnimUtil_GetBattlerSideSignByMode and work->dirY
  -- reads BattleAnimUtil_GetBattlerSideSign; both derive from the battler's
  -- side outside contest mode, so the occurrence presents one side sign.
  local sign = sideSign(context, activation.combatant, kind)
  ---@param self SourceTimedBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    local own = self --[[@as SourceTimedHeightPositionTransition]]
    local phase = own._phase
    if phase == "start-shake" then
      -- SHAKE_LUNGE_STATE_START_SHAKE: BattleAnimUtil_InitShake(4, 0, 1, 4).
      own._shake =
        Support.shake(SHAKE_LUNGE_AMPLITUDE_X, SHAKE_LUNGE_AMPLITUDE_Y, SHAKE_LUNGE_INTERVAL_TICKS, SHAKE_LUNGE_ROUNDS)
      own._phase = "shake"
      return false
    end
    if phase == "shake" then
      local shake = own._shake --[[@as SourceTimedShake]]
      if shake:step() then
        self:publishPicture(own._activation, {
          pictureXOffset = Support.clampOffset(shake.x),
          pictureYOffset = Support.clampOffset(shake.y),
        })
        return false
      end
      -- SHAKE_LUNGE_STATE_SHAKE retired: the source starts the lunge leg from
      -- the authored row.
      own._move = shakeLungeLeg(0, 0, own._reachX, own._reachY)
      own._phase = "lunge"
      return false
    end
    if phase == "lunge" or phase == "return" then
      local move = own._move --[[@as SourceTimedLinearMotion]]
      if move:step() then
        self:publishPicture(own._activation, {
          pictureXOffset = Support.clampOffset(move.x),
          pictureYOffset = Support.clampOffset(move.y),
        })
        return false
      end
      if phase == "lunge" then
        -- SHAKE_LUNGE_STATE_LUNGE retired: work->timer takes the hold word.
        own._hold = 0
        own._phase = "hold"
      else
        own._phase = "end"
      end
      return false
    end
    if phase == "hold" then
      -- SHAKE_LUNGE_STATE_HOLD: --work->timer retires one frame after it
      -- passes below zero and starts the walk home from the lunge reach.
      own._hold = own._hold + 1
      if own._hold > SHAKE_LUNGE_HOLD_LIMIT then
        own._move = shakeLungeLeg(own._reachX, own._reachY, 0, 0)
        own._phase = "return"
      end
      return false
    end
    -- SHAKE_LUNGE_STATE_END: the teardown frame writes the authored X/Y back
    -- and destroys the task, leaving the picture on its presented pose.
    self:publishPicture(own._activation, { pictureXOffset = 0, pictureYOffset = 0 })
    return true
  end
  return Support.newBody(kind, services, {
    _activation = activation,
    _reachX = SHAKE_LUNGE_REACH * sign,
    _reachY = SHAKE_LUNGE_LIFT * sign,
    _phase = "start-shake",
    _shake = nil,
    _move = nil,
    _hold = 0,
  }, advance)
end

PositionMotion["pokemon-picture-height-position-transition"] = newHeightPositionTransition

-- Pokepic_SetVisible selects the source crop window: x and y are its origin
-- inside the eighty-pixel picture box and width/height its size. The scene
-- crop fields carry the same origin and size, so a body publishes them
-- verbatim. Two native draw facts stay unreproduced here: a crop with no area
-- draws no pixels (the scene has no zero-area crop, so the picture is marked
-- undrawn instead), and while the crop is active the native also suppresses
-- the picture shadow, which the scene shadow pass does not follow.
---@param x integer crop origin column inside the eighty-pixel picture
---@param y integer crop origin row inside the eighty-pixel picture
---@param width integer crop width in pixels
---@param height integer crop height in pixels
---@return table<string, unknown> picture overlay behind the native crop window
local function pictureCrop(x, y, width, height)
  return {
    pictureVisible = true,
    pictureXOffset2 = Support.wrapCropByte(x),
    pictureYOffset2 = Support.wrapCropByte(y),
    pictureWidth = Support.wrapCropByte(width),
    pictureHeight = Support.wrapCropByte(height),
    dontDraw = not (width > 0 and height > 0),
  }
end

-- BattleAnimUtil_CollectPicsByFlags collects a picture set in role order and
-- BattleAnimUtil_GetRoleBattler reads the same word as one role, so only the
-- four single-role words name one presented picture. A doubled partner
-- picture is a second activation this side resolution cannot address, so the
-- pair words reveal the side's first presented picture.
---@param parameters table<string, unknown> compiled parameter record
---@param name string compiled parameter name under reading
---@param kind string task kind under diagnosis
---@return integer whole source word
local function revealWord(parameters, name, kind)
  local value = parameters[name]
  if value == nil then
    return 0
  end
  if type(value) ~= "number" or value % 1 ~= 0 then
    Support.malformed(kind, "carries its " .. name .. " as a whole source word")
  end
  return value
end

---@param args table<string, unknown> instruction-derived construction arguments
---@param parameters table<string, unknown> compiled parameter record
---@param context table<string, unknown> occurrence-bound playback context
---@param kind string task kind under diagnosis
---@return table<string, unknown> combatant and activation pair behind the revealed picture
local function revealedActivation(args, parameters, context, kind)
  if args.activation ~= nil or args.battlerTarget ~= nil then
    return Support.requiredActivation(args, context, kind)
  end
  local pictureTarget = parameters.pictureTarget
  if type(pictureTarget) ~= "string" then
    Support.malformed(kind, "reveals the picture its source flags collect")
  end
  return Support.requiredActivation({ battlerTarget = pictureTarget }, context, kind)
end

-- BattleAnimFunc_RevealBattler (battle_anim_funcs.c, selector 67 of
-- gBattleAnimFuncTable): the callback reads the picture flags, the step word,
-- the interval word, and the upward flag, then starts one of three reveal
-- machines over one eighty-pixel battler picture. Every machine writes on
-- every tick its pre-incremented timer reaches the interval word, and every
-- machine retires one tick after the tick it retired its reveal state.
local REVEAL_PICTURE_SIZE = 80

---@class SourceTimedRevealBattler
---@field _activation table<string, unknown> revealed picture
---@field _branch string upward, sink, or rise
---@field _phase string current native state
---@field _step integer source step word the reveal walks
---@field _interval integer source ticks between writes
---@field _timer integer ticks spent inside the current interval
---@field _height integer crop origin the upward branch walks, or the crop height
---@field _maxHeight integer crop height the upward branch grows
---@field _y integer picture row offset from the row the callback read

-- POKEPIC_Y is the picture's absolute screen row; the scene carries it as an
-- offset from the authored row, so the row the callback read is the offset
-- zero and every sink and rise write shifts from it.
---@param height integer visible crop height
---@param y integer picture row offset from the authored row
---@return table<string, unknown> picture overlay behind the native row writes
local function revealRowPatch(height, y)
  local patch = pictureCrop(0, 0, REVEAL_PICTURE_SIZE, height)
  patch.pictureYOffset = Support.clampOffset(y)
  return patch
end

---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return SourceTimedBody runnable reveal task
local function newRevealVisibilityTransition(kind, args, context, services)
  local parameters = Support.parameters(args, kind)
  local activation = revealedActivation(args, parameters, context, kind)
  local step = revealWord(parameters, "offsetStep", kind)
  local interval = revealWord(parameters, "ticksPerStep", kind)
  local upward = parameters.applyVisibilityOffset
  if upward ~= nil and type(upward) ~= "boolean" then
    Support.malformed(kind, "carries its upward flag as a boolean")
  end
  -- REVEAL_BATTLER_STATE_REVEAL walks its height until it crosses a bound; a
  -- zero step never crosses one, so the native machine would write the same
  -- crop forever.
  if step == 0 then
    Support.malformed(kind, "reveals with a nonzero source step")
  end
  -- BattleAnimSystem_GetBattlerHeight reads the battler picture inset every
  -- reveal starts below. The producer lowers no inset, so the reveal starts
  -- from the whole eighty-pixel picture box.
  local startHeight = REVEAL_PICTURE_SIZE
  local branch = upward == true and "upward" or (step > 0 and "sink" or "rise")
  ---@param self SourceTimedBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    local own = self --[[@as SourceTimedRevealBattler]]
    if own._phase == "end" then
      -- REVEAL_BATTLER_STATE_END clears the crop window (POKEPIC_VISIBLE = 0
      -- draws the whole picture), restores POKEPIC_Y to the row the callback
      -- read and POKEPIC_H to the box height, resets the affine pair, and
      -- destroys the task. The cleared crop is the only observable write: the
      -- authored row and identity scale are what the completion restore
      -- returns the picture to anyway.
      self:publishPicture(own._activation, { pictureVisible = false, dontDraw = false, pictureYOffset = 0 })
      return true
    end
    own._timer = own._timer + 1
    if own._timer < own._interval then
      return false
    end
    own._timer = 0
    if own._branch == "upward" then
      -- BattleAnimTask_RevealBattlerUpward walks the crop origin up the
      -- picture while the visible height grows from the picture bottom.
      own._height = own._height - own._step
      own._maxHeight = own._maxHeight + own._step
      if own._height < 0 then
        own._height = 0
        own._phase = "end"
      end
      self:publishPicture(own._activation, pictureCrop(0, own._height, REVEAL_PICTURE_SIZE, own._maxHeight))
      return false
    end
    -- Both row machines shift POKEPIC_Y by the step word and walk the crop
    -- height the other way on the same tick.
    own._y = own._y + own._step
    own._height = own._height - own._step
    if own._branch == "sink" then
      -- BattleAnimTask_RevealBattlerSink retires once the cropped height
      -- passes below zero as the picture slides down.
      if own._height < 0 then
        own._height = 0
        own._phase = "end"
      end
    elseif own._height > own._maxHeight then
      -- BattleAnimTask_RevealBattlerRise retires once the growing crop passes
      -- the box height as the picture climbs back to its authored row.
      own._height = own._maxHeight
      own._phase = "end"
    end
    self:publishPicture(own._activation, revealRowPatch(own._height, own._y))
    return false
  end
  -- The callback leaves the upward machine with no grown height, while both
  -- row machines carry the box height they measured. The rise then zeroes its
  -- height and parks the picture one box below the authored row.
  local phaseHeight = startHeight
  local phaseMaxHeight = branch == "upward" and 0 or startHeight
  local phaseY = 0
  if branch == "rise" then
    phaseHeight = 0
    phaseY = startHeight
  end
  local body = Support.newBody(kind, services, {
    _activation = activation,
    _branch = branch,
    _phase = "reveal",
    _step = step,
    _interval = interval,
    _timer = 0,
    _height = phaseHeight,
    _maxHeight = phaseMaxHeight,
    _y = phaseY,
  }, advance)
  if branch == "upward" then
    -- Pokepic_SetVisible(0, height, 80, 0): the upward reveal starts with no
    -- visible row at the picture bottom.
    body:publishPicture(activation, pictureCrop(0, startHeight, REVEAL_PICTURE_SIZE, 0))
  elseif branch == "sink" then
    -- Pokepic_SetVisible(0, 0, 80, height): the sink opens on the whole box
    -- and crops it short as it slides down.
    body:publishPicture(activation, revealRowPatch(phaseHeight, phaseY))
  else
    -- Pokepic_SetAttr(POKEPIC_Y, baseY + maxHeight) and
    -- Pokepic_SetVisible(0, 0, 80, 0): the rise parks the picture one box
    -- height below its authored row with nothing revealed yet.
    body:publishPicture(activation, revealRowPatch(phaseHeight, phaseY))
  end
  return body
end

PositionMotion["pokemon-picture-vertical-offset-visibility-transition"] = newRevealVisibilityTransition

-- BattleAnimFunc_WipeOutDefender (battle_anim_move_effects.c, selector 79 of
-- gBattleAnimFuncTable): the callback dims the defender picture to alpha 8,
-- opens an eighty-pixel-wide object window over it, and walks one two-pixel
-- crop band up the picture, alternating the band between the left and right
-- edges, over thirty-nine rows. Each row spends one band tick, one window
-- grow tick, and one row-count tick; the following hide tick clears the crop
-- and the teardown tick restores the authored alpha.
local WIPE_STRIP_HEIGHT = 2
local WIPE_STRIP_STEP = 79
local WIPE_STRIP_FULL = 80
local WIPE_ROW_BIAS = 2
local WIPE_LAST_ROW = 38
local WIPE_POLYGON_ALPHA = 8

---@class SourceTimedWipeOutDefender
---@field _activation table<string, unknown> defender picture the wipe owns
---@field _phase string current native state
---@field _count integer wiped rows behind the current band
---@field _stripWidth integer current crop band width
---@field _fromRight boolean the current band starts at the right edge

-- The wipe dims the picture through POKEPIC_ALPHA for its whole run, so every
-- band keeps the five-bit polygon alpha the callback wrote. The object window
-- (G2_SetWnd0Position), the window plane masks, and the two BG priority
-- rewrites the callback also performs have no scene expression.
---@param own SourceTimedWipeOutDefender run state behind the pose
---@return table<string, unknown> picture overlay behind the native band write
local function wipeStripPatch(own)
  local column = own._fromRight and WIPE_STRIP_FULL - own._stripWidth or 0
  local row = WIPE_STRIP_FULL - (own._count + WIPE_ROW_BIAS) * WIPE_STRIP_HEIGHT
  local patch = pictureCrop(column, row, own._stripWidth, WIPE_STRIP_HEIGHT)
  patch.polygonAlpha = WIPE_POLYGON_ALPHA
  return patch
end

---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return SourceTimedBody runnable defender wipe task
local function newWipeOutDefender(kind, args, context, services)
  local activation = ownedActivation(args, context, kind, "defender")
  ---@param self SourceTimedBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    local own = self --[[@as SourceTimedWipeOutDefender]]
    local state = own._phase
    if state == "wipe" then
      own._stripWidth = own._stripWidth + WIPE_STRIP_STEP
      if own._stripWidth >= WIPE_STRIP_FULL then
        -- WIPE_OUT_STATE_WIPE hands the row to the window grow state and
        -- flips the band side without a picture write.
        own._fromRight = not own._fromRight
        own._stripWidth = 0
        own._phase = "grow-window"
        return false
      end
      self:publishPicture(own._activation, wipeStripPatch(own))
      return false
    end
    if state == "grow-window" then
      -- WIPE_OUT_STATE_GROW_WINDOW widens the object window by one row above
      -- and below the band; only the window registers move.
      own._phase = "next-row"
      return false
    end
    if state == "next-row" then
      -- WIPE_OUT_STATE_NEXT_ROW widens the window again and counts the wiped
      -- row; the thirty-ninth row hands over to the hide state.
      own._count = own._count + 1
      own._phase = own._count > WIPE_LAST_ROW and "hide" or "wipe"
      return false
    end
    if state == "hide" then
      -- WIPE_OUT_STATE_HIDE clears the crop window, which draws the whole
      -- revealed picture again while the dimmed alpha stays in place.
      own._phase = "teardown"
      self:publishPicture(own._activation, { pictureVisible = false, dontDraw = false })
      return false
    end
    -- The teardown frame disables the object window, restores the BG
    -- priorities, writes POKEPIC_ALPHA back to the value the callback read,
    -- and destroys the task. The transient alpha this body published restores
    -- with the run, so the authored alpha never needs re-reading.
    return true
  end
  local body = Support.newBody(kind, services, {
    _activation = activation,
    _phase = "wipe",
    _count = 0,
    _stripWidth = 0,
    _fromRight = false,
  }, advance)
  -- The callback itself dims the picture before its first scheduled frame and
  -- opens a zero-height object window at the picture row less its shadow
  -- height, which the window seam does not express.
  body:publishPicture(activation, { polygonAlpha = WIPE_POLYGON_ALPHA })
  return body
end

PositionMotion["pokemon-picture-target-priority-transition"] = newWipeOutDefender

return PositionMotion
