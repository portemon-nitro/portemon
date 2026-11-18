-- Source-timed native battle animation bodies: the sprite formation family.
-- Each entry maps one producer task kind to its body constructor and
-- reproduces one overlay-07 callback that spreads script-created copies of the
-- attacker's battler sprite into an afterimage formation
-- (battle_anim_move_effects.c in the pinned pret/pokeheartgold tree). See
-- Support.lua for the journaled write seams and the lifecycle every body
-- shares.

local Support = require("libs.hgss.src.presentation.sourceTimed.Support")

local SpriteFormation = {}

-- The natives in this family address their own battler
-- (BattleAnimSystem_GetAttacker), so the occurrence's attacker picture is the
-- one the body owns. A produced battlerTarget keeps its word; without one the
-- side resolves the presented activation directly, and the producer lowers no
-- battler target for these selectors. The shake branch below addresses the
-- defender instead, so the role names the side the native reads.
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param kind string task kind under diagnosis
---@param role string? "attacker" or "target" side the native addresses
---@return table<string, unknown> combatant and activation pair behind the owned picture
local function ownedActivation(args, context, kind, role)
  if args.activation ~= nil or args.battlerTarget ~= nil then
    return Support.requiredActivation(args, context, kind)
  end
  return Support.requiredActivation({ battlerTarget = role or "attacker" }, context, kind)
end

-- gBattleAnimAttackerAfterimagePasses (asm/battle_anim_data.s): four
-- BattleAnimAfterimagePass rows of {startX, endX, duration}. The pass parity
-- picks rows one and two or rows three and four; the leading pair of copies
-- follows the first of the two rows and the slower pair the second one.
local AFTERIMAGE_PASSES = {
  { startX = 0, endX = 32, duration = 7 },
  { startX = 0, endX = 32, duration = 10 },
  { startX = 32, endX = 0, duration = 7 },
  { startX = 32, endX = 0, duration = 10 },
}
-- The machine starts a pass for every count below nine and only then enters
-- its fade-out state.
local AFTERIMAGE_PASS_COUNT = 9
local AFTERIMAGE_EVA_START = 8 -- work->eva written by the callback
local AFTERIMAGE_EVB_START = 6 -- work->evb written by the callback
local AFTERIMAGE_EVB_END = 15

---@class SourceTimedFourSpriteWave
---@field _activation table<string, unknown> attacker picture the wave owns
---@field _phase string current native state
---@field _count integer passes started so far
---@field _passTicks integer ticks left inside the current pass
---@field _copy SourceTimedLinearMotion? leading copy track under advancement
---@field _eva integer current source sprite alpha weight
---@field _evb integer current source battlefield alpha weight

-- BattleAnimFunc_AttackerAfterimages (battle_anim_move_effects.c, selector 7
-- of gBattleAnimFuncTable) hides four script-created copies of the attacker's
-- battler sprite behind it, slides the mirrored pair outward and back through
-- gBattleAnimAttackerAfterimagePasses, and fades the copies out with
-- reg_G2_BLDALPHA. The scene presents the mon itself and cannot spread four
-- copies, so the body slides the presented picture along the leading copy's
-- track and keeps the source's blend registers. The three other copies, the
-- per-copy draw priorities (10 in front, 20 behind the battler), their darker
-- custom palette tints (0x80/0x80/0x80 and 0xC4/0xC4/0xC4), their XLU OAM mode,
-- and their per-sprite frame ticks have no scene expression.
---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return SourceTimedBody runnable afterimage wave task
local function newFourSpriteWave(kind, args, context, services)
  Support.parameters(args, kind)
  local activation = ownedActivation(args, context, kind)
  ---@param self SourceTimedBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    local own = self --[[@as SourceTimedFourSpriteWave]]
    if own._phase == "done" then
      -- AFTERIMAGES default case: the source destroys its task.
      return true
    end
    if own._phase == "fade-out" then
      if own._eva ~= 0 then
        own._eva = own._eva - 1
      end
      if own._evb < AFTERIMAGE_EVB_END then
        own._evb = own._evb + 1
      end
      if own._eva == 0 and own._evb == AFTERIMAGE_EVB_END then
        own._phase = "done"
      end
      self:writeScalar({ blendCoefficientA = own._eva, blendCoefficientB = own._evb })
      return false
    end
    if own._phase == "start-pass" then
      -- AFTERIMAGES_STATE_START_PASS: each pass is a little faster than the
      -- previous one, so the pass delay shortens both row durations, and the
      -- slower pair's shortened duration ends the pass one frame after its
      -- last step.
      local row = (own._count % 2) * 2 + 1
      local delay = math.floor((own._count + 1) / 2)
      local leading = AFTERIMAGE_PASSES[row]
      own._copy = Support.linear(leading.startX, leading.endX, 0, 0, leading.duration - delay) --[[@as SourceTimedLinearMotion]]
      own._passTicks = AFTERIMAGE_PASSES[row + 1].duration - delay + 1
      own._count = own._count + 1
      own._phase = "move"
      -- The start-pass state falls through into the move state on its own
      -- frame, so the pass spends its first tick here.
    end
    own._passTicks = own._passTicks - 1
    local copy = own._copy --[[@as SourceTimedLinearMotion]]
    if copy:step() then
      -- ManagedSprite_SetPositionXY writes the copy's absolute X/Y; the copies
      -- never leave the picture row, so only the horizontal offset reaches the
      -- presented picture.
      self:publishPicture(own._activation, { pictureXOffset = Support.clampOffset(copy.x) })
    end
    if own._passTicks == 0 then
      own._phase = own._count == AFTERIMAGE_PASS_COUNT and "fade-out" or "start-pass"
    end
    return false
  end
  local body = Support.newBody(kind, services, {
    _activation = activation,
    _phase = "start-pass",
    _count = 0,
    _passTicks = 0,
    _copy = nil,
    _eva = AFTERIMAGE_EVA_START,
    _evb = AFTERIMAGE_EVB_START,
  }, advance)
  -- The callback switches the battlefield blend on and writes its opening
  -- register pair before its task starts; the native SetBlendWithBattleBg
  -- coefficients written on the way are overwritten by that pair on the same
  -- frame.
  body:writeScalar({ blendCoefficientA = AFTERIMAGE_EVA_START, blendCoefficientB = AFTERIMAGE_EVB_START })
  return body
end

SpriteFormation["pokemon-picture-four-sprite-wave-transition"] = newFourSpriteWave

-- gBattleAnimSquashAfterimageDelays (asm/battle_anim_data.s): the frames each
-- of the three copies waits before its five-tick 100 -> 5 squash.
local SQUASH_AFTERIMAGE_DELAYS = { 2, 7, 13 }
local SQUASH_SCALE_START = 100
local SQUASH_SCALE_END = 5
local SQUASH_SCALE_DIVISOR = 100
local SQUASH_SCALE_TICKS = 5
local SQUASH_ROUNDS = 3
local SQUASH_BLEND_A = 12 -- reg_G2_BLDALPHA written by the callback
local SQUASH_BLEND_B = 6
-- A copy reports done on the frame after its last squash step, so a round
-- closes once the latest copy has spent its delay, its five steps, and that
-- frame.
local SQUASH_ROUND_TICKS = 0
for _, delay in ipairs(SQUASH_AFTERIMAGE_DELAYS) do
  SQUASH_ROUND_TICKS = math.max(SQUASH_ROUND_TICKS, delay + SQUASH_SCALE_TICKS + 2)
end

---@class SourceTimedThreeSpriteSquash
---@field _activation table<string, unknown> attacker picture the squash owns
---@field _phase string current native state
---@field _round integer squash rounds completed
---@field _roundTicks integer ticks left inside the current round
---@field _timer integer delay frames spent by the presented copy
---@field _copyState string presented copy state inside the squash round
---@field _motion SourceTimedScaleMotion? presented copy scale under advancement

-- BattleAnimUtil_InitScaleMotionXY row of the squash and restore legs: the
-- source moves both axes between the same 1/100 scale words.
---@param startWord integer start scale word
---@param endWord integer end scale word
---@return SourceTimedScaleMotion scale motion record
local function squashMotion(startWord, endWord)
  return Support.scaleMotion(startWord, endWord, startWord, endWord, SQUASH_SCALE_DIVISOR, SQUASH_SCALE_TICKS)
end

---@param sourceTimedBody SourceTimedBody body under publication
---@param own SourceTimedThreeSpriteSquash run state behind the pose
local function publishSquash(sourceTimedBody, own)
  local motion = own._motion --[[@as SourceTimedScaleMotion]]
  sourceTimedBody:publishPicture(own._activation --[[@as table<string, unknown>]], {
    affineMode = true,
    affineWidth = motion.x,
    affineHeight = motion.y,
    -- BattleAnimUtil_AlignSpriteToScale aligns each copy to the picture row
    -- through the scale offset. The producer lowers no battler picture height,
    -- so the flat-picture inset zero reads.
    pictureYOffset = Support.alignY(0, 0, motion.curY, 0),
  })
end

-- BattleAnimFunc_AttackerSquashAfterimages (battle_anim_move_effects.c,
-- selector 22 of gBattleAnimFuncTable) shows the attacker picture and runs
-- three rounds in which three script-created copies of its battler sprite wait
-- out gBattleAnimSquashAfterimageDelays, squash to 5/100 over five ticks each,
-- then restore from 5/100 to 100/100 before the destroy frame hides the
-- picture. The scene presents the mon itself, so the body squashes the
-- presented picture along the first copy's delay and keeps the callback's
-- reg_G2_BLDALPHA pair; the native picture scale stays authored throughout.
-- The second and third copies (delays 7 and 13), the per-copy draw priorities
-- (i + 1), their XLU OAM mode, their double affine overwrite mode, and their
-- per-sprite frame ticks have no scene expression; those later delays alone
-- set the round length.
---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return SourceTimedBody runnable afterimage squash task
local function newThreeSpriteSquash(kind, args, context, services)
  Support.parameters(args, kind)
  local activation = ownedActivation(args, context, kind)
  ---@param self SourceTimedBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    local own = self --[[@as SourceTimedThreeSpriteSquash]]
    local phase = own._phase
    if phase == "show-pic" then
      -- SQUASH_AFTERIMAGES_STATE_SHOW_PIC: POKEPIC_VISIBLE goes TRUE and the
      -- copies start their first delay on the following frame.
      self:publishPicture(own._activation, { pictureVisible = true })
      own._phase = "squash"
      own._roundTicks = SQUASH_ROUND_TICKS
      return false
    end
    if phase == "squash" then
      own._roundTicks = own._roundTicks - 1
      if own._copyState == "delay" then
        -- SQUASH_AFTERIMAGE_STATE_DELAY: the frame that spends the delay only
        -- initializes the squash motion.
        own._timer = own._timer + 1
        if own._timer >= SQUASH_AFTERIMAGE_DELAYS[1] then
          own._motion = squashMotion(SQUASH_SCALE_START, SQUASH_SCALE_END)
          own._copyState = "scale"
        end
      elseif own._copyState == "scale" then
        -- SQUASH_AFTERIMAGE_STATE_SCALE: every stepped frame writes the affine
        -- pair and the aligned row; the exhausted frame only retires the copy.
        if own._motion:step() then
          publishSquash(self, own)
        else
          own._copyState = "done"
        end
      end
      if own._roundTicks ~= 0 then
        return false
      end
      own._round = own._round + 1
      if own._round >= SQUASH_ROUNDS then
        own._phase = "start-restore"
        return false
      end
      -- The round reset re-seats every copy on the picture row at its authored
      -- scale and returns to the squashing state with the delay timer cleared.
      own._copyState = "delay"
      own._timer = 0
      own._roundTicks = SQUASH_ROUND_TICKS
      return false
    end
    if phase == "start-restore" then
      -- SQUASH_AFTERIMAGES_STATE_START_RESTORE: every copy returns to the
      -- normal OAM mode (no scene expression) and starts its restore motion.
      own._motion = squashMotion(SQUASH_SCALE_END, SQUASH_SCALE_START)
      own._phase = "restore"
      return false
    end
    if phase == "restore" then
      -- SQUASH_AFTERIMAGES_STATE_RESTORE: the exhausted frame retires the
      -- whole state instead of writing a pose.
      if own._motion:step() then
        publishSquash(self, own)
        return false
      end
      own._phase = "done"
      return false
    end
    -- SQUASH_AFTERIMAGES default case: POKEPIC_VISIBLE goes FALSE and the
    -- source destroys its task, so the picture keeps that hidden pose. The
    -- native store is the picture's visible flag, not its vanish attribute.
    self._persist = true
    self:publishPicture(own._activation, { pictureVisible = false })
    return true
  end
  local body = Support.newBody(kind, services, {
    _activation = activation,
    _phase = "show-pic",
    _round = 0,
    _roundTicks = 0,
    _timer = 0,
    _copyState = "delay",
    _motion = nil,
  }, advance)
  -- The callback switches the battlefield blend on and writes its register pair
  -- before its task starts; no state of the machine touches it again.
  body:writeScalar({ blendCoefficientA = SQUASH_BLEND_A, blendCoefficientB = SQUASH_BLEND_B })
  return body
end

SpriteFormation["pokemon-picture-three-sprite-affine-transition"] = newThreeSpriteSquash

-- BattleAnimUtil_InitValueMotion / UpdateValueMotion: the per-tick step is the
-- fixed-point step shifted back down as a whole value, so a ramp lands on its
-- endpoint or up to one unit short of it and never overshoots.
---@class SourceTimedValueRamp
---@field value integer current whole native value
---@field stepSize integer whole step per tick
---@field remaining integer ticks left behind the ramp
local ValueRamp = {}
ValueRamp.__index = ValueRamp

---@param start integer native value at the first tick
---@param finish integer native value after the last tick
---@param ticks integer positive step count
---@return SourceTimedValueRamp whole-value ramp
local function valueRamp(start, finish, ticks)
  assert(type(ticks) == "number" and ticks >= 1, "value ramps name a positive tick count")
  local stepSize = math.floor(
    Support.fxStep(math.floor(start) * Support.FX32_ONE, math.floor(finish) * Support.FX32_ONE, ticks)
      / Support.FX32_ONE
  )
  return setmetatable({ value = math.floor(start), stepSize = stepSize, remaining = ticks }, ValueRamp)
end

---@param self SourceTimedValueRamp ramp under advancement
---@return boolean active true while the ramp had a tick to spend
function ValueRamp:step()
  if self.remaining == 0 then
    return false
  end
  self.value = self.value + self.stepSize
  self.remaining = self.remaining - 1
  return true
end

-- POKEPIC_ZROT stores a 16-bit angle index, so a negative signed native value
-- lands on the word the register keeps.
---@param value integer signed native rotation angle
---@return integer clamped angle index in 0..65535
local function angleIndex(value)
  return Support.clampRotation(value % 65536)
end

-- A lowered script operand the native reads as an integer word.
---@param parameters table<string, unknown> compiled parameter record
---@param name string lowered operand name
---@param kind string task kind under diagnosis
---@return integer? whole lowered operand, absent when the producer lowered none
local function wholeOperand(parameters, name, kind)
  local value = parameters[name]
  if value == nil then
    return nil
  end
  if type(value) ~= "number" or value % 1 ~= 0 then
    Support.malformed(kind, "carries its " .. name .. " operand as a whole source word")
  end
  return value
end

-- gBattleAnimRockAttackerSteps (asm/battle_anim_data.s): five BattleAnimRockStep
-- rows of {angle, duration}. The rock machine plays every row twice, once from
-- its negative angle and once back, and the parity of the pass picks which leg
-- the row starts on.
local ROCK_ROTATION_STEPS = {
  { angle = 0x0E38, duration = 3 },
  { angle = 0x0AAA, duration = 3 },
  { angle = 0x071C, duration = 2 },
  { angle = 0x038E, duration = 2 },
  { angle = 0x0000, duration = 1 },
}

---@class SourceTimedRockRotation
---@field _activation table<string, unknown> attacker picture the rotation owns
---@field _phase string current native state
---@field _row integer gBattleAnimRockAttackerSteps row under play
---@field _flip boolean the next pass reads the row from its positive angle
---@field _rocking boolean the current pass still owns a rotation motion
---@field _motion SourceTimedValueRamp? rotation motion under advancement

-- BattleAnimTask_RockAttacker (battle_anim_move_effects.c): the start state
-- seats one row's motion and falls through into the rocking state on the same
-- frame, so a pass spends its duration frames turning the picture and one frame
-- finding the motion exhausted. The exhausted frame either returns to the start
-- state or leaves for the destroy frame once the fifth row is behind it.
---@param kind string task kind under construction
---@param activation table<string, unknown> attacker picture the rotation owns
---@param services table<string, unknown> factory services record
---@return SourceTimedBody runnable rock rotation task
local function newRockRotation(kind, activation, services)
  ---@param self SourceTimedBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    local own = self --[[@as SourceTimedRockRotation]]
    if own._phase == "end" then
      -- ROCK_ATTACKER default case: the source writes the upright angle back
      -- and destroys its task. The POKEPIC_YPIVOT 100 the callback sets has no
      -- scene expression, so the rotation turns around the picture centre.
      self:publishPicture(own._activation, { rotationZ = 0 })
      return true
    end
    if not own._rocking then
      -- ROCK_ATTACKER_STATE_START_ROCK reads the row before the parity flips
      -- and before the row index advances for the return leg.
      local row = ROCK_ROTATION_STEPS[own._row + 1]
      local from, to = -row.angle, row.angle
      if own._flip then
        from, to = row.angle, -row.angle
      end
      own._motion = valueRamp(from, to, row.duration)
      if own._flip then
        own._row = own._row + 1
      end
      own._flip = not own._flip
      own._rocking = true
    end
    local motion = own._motion --[[@as SourceTimedValueRamp]]
    if motion:step() then
      -- ROCK_ATTACKER_STATE_ROCK writes the turned angle every active frame.
      self:publishPicture(own._activation, { rotationZ = angleIndex(motion.value) })
      return false
    end
    own._rocking = false
    if own._row >= #ROCK_ROTATION_STEPS then
      own._phase = "end"
    end
    return false
  end
  return Support.newBody(kind, services, {
    _activation = activation,
    _phase = "rock",
    _row = 0,
    _flip = false,
    _rocking = false,
    _motion = nil,
  }, advance)
end

---@class SourceTimedDefenderShake
---@field _activation table<string, unknown> target picture the shake owns
---@field _phase string current native state
---@field _shake SourceTimedShake target displacement under advancement

-- BattleAnimTask_ShakePic (battle_anim_move_effects.c): the init frame only
-- seats BattleAnimUtil_InitShake, every active frame writes the picture's
-- position as its authored row plus the shake offset, and the frame that finds
-- the rounds spent hands over to the destroy frame.
---@param kind string task kind under construction
---@param activation table<string, unknown> target picture the shake owns
---@param shake SourceTimedShake target displacement under advancement
---@param services table<string, unknown> factory services record
---@return SourceTimedBody runnable target shake task
local function newTargetShake(kind, activation, shake, services)
  ---@param self SourceTimedBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    local own = self --[[@as SourceTimedDefenderShake]]
    if own._phase == "init" then
      -- SHAKE_PIC_STATE_INIT seats the shake and returns without a write.
      own._phase = "shake"
      return false
    end
    if own._phase == "end" then
      -- SHAKE_PIC default case: the source destroys its task.
      return true
    end
    if own._shake:step() then
      -- SHAKE_PIC_STATE_SHAKE writes POKEPIC_X/Y as the authored position plus
      -- the shake offset, which the scene carries as picture offsets.
      self:publishPicture(own._activation, {
        pictureXOffset = Support.clampOffset(own._shake.x),
        pictureYOffset = Support.clampOffset(own._shake.y),
      })
      return false
    end
    own._phase = "end"
    return false
  end
  return Support.newBody(kind, services, {
    _activation = activation,
    _phase = "init",
    _shake = shake,
  }, advance)
end

-- BattleAnimFunc_RockOrShakeAttacker (battle_anim_move_effects.c, selector 27
-- of gBattleAnimFuncTable): the callback sets the attacker picture's Y pivot to
-- 100 and reads script arg 0 as its branch selector. A zero selector runs the
-- rock task on the attacker picture's Z rotation; any other selector shakes the
-- defender picture with script args 1..4 as amplitude, interval, and count (arg
-- 5 is stored in the work and never read). The scene presents one picture per
-- battler, so the body owns exactly the picture its branch writes.
---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return SourceTimedBody runnable rock or shake task
local function newRockOrShakeAttacker(kind, args, context, services)
  local parameters = Support.parameters(args, kind)
  local selector = wholeOperand(parameters, "shake", kind)
  if selector == nil or selector == 0 then
    return newRockRotation(kind, ownedActivation(args, context, kind), services)
  end
  local ampX = wholeOperand(parameters, "shakeAmpX", kind)
  local ampY = wholeOperand(parameters, "shakeAmpY", kind)
  local interval = wholeOperand(parameters, "shakeInterval", kind)
  local count = wholeOperand(parameters, "shakeCount", kind)
  if ampX == nil or ampY == nil or interval == nil or count == nil then
    Support.malformed(kind, "reads the shake amplitude, interval, and count words its selector names")
  end
  return newTargetShake(
    kind,
    ownedActivation(args, context, kind, "target"),
    Support.shake(
      math.floor(ampX --[[@as number]]),
      math.floor(ampY --[[@as number]]),
      math.floor(interval --[[@as number]]),
      math.floor(count --[[@as number]])
    ),
    services
  )
end

SpriteFormation["battle-background-picture-scroll-oscillation"] = newRockOrShakeAttacker

-- Authored 1.0 in the scene's 8.8 picture affine units (POKEPIC_AFFINEW/H 256).
local AFFINE_ONE = 256
-- BattleAnimUtil_InitScaleMotionXY / InitScaleMotion divisor of every affine
-- pair the dark sprite jump seats, in 1/100 scale words.
local DARK_JUMP_SCALE_DIVISOR = 10
local DARK_JUMP_STRETCH_TICKS = 8 -- InitScaleMotionXY(stretch, 10, 10, 10, 20, 10, 8)
local DARK_JUMP_SHRINK_TICKS = 4 -- InitScaleMotion(scale, 10, 10, 1, 4)
local DARK_JUMP_STRETCH_TIMER = 6 -- work->partTimer behind the stretching frames
local DARK_JUMP_DELAY_TIMER = 2 -- work->timer behind the delay state
local DARK_JUMP_DROP_PIXELS = 64 -- the falling copy's reach above its row
local DARK_JUMP_DROP_TICKS = 8 -- InitLinearMotion(drop, x, x, y - 64, y, 8)
local DARK_JUMP_SPRITE_WEIGHT = 8 -- work->blend end weight of the sprite side
local DARK_JUMP_BACKGROUND_WEIGHT = 16 -- and of the battlefield side
local DARK_JUMP_BLEND_TICKS = 8

---@class SourceTimedAffinePairJump
---@field _attacker table<string, unknown> attacker picture the rising copy stands in for
---@field _defender table<string, unknown> target picture the falling copy stands in for
---@field _inset integer battler picture height behind the row alignment
---@field _phase string current native state
---@field _part string current rise or drop part state
---@field _partTimer integer frames left inside the current part state
---@field _timer integer delay frames left behind the fall
---@field _stretch SourceTimedScaleMotion? stretched pair under advancement
---@field _scale SourceTimedScaleMotion? shrinking width leg under advancement
---@field _drop SourceTimedLinearMotion? falling leg under advancement
---@field _ramp SourceTimedLinearMotion? coefficient walk under advancement
---@field _rampDone boolean the queued walk reported its closing frame

-- BattleAnimUtil_AlignSpriteToScale rows the rising copy: the written picture Y
-- is that row plus half the height the current scale gains.
---@param sourceTimedBody SourceTimedBody body under publication
---@param own SourceTimedAffinePairJump run state behind the pose
---@param width integer whole 1/256 affine width
---@param height integer whole 1/256 affine height
---@param scale integer fixed-point scale behind the row alignment
local function publishRise(sourceTimedBody, own, width, height, scale)
  sourceTimedBody:publishPicture(own._attacker, {
    affineMode = true,
    affineWidth = width,
    affineHeight = height,
    pictureYOffset = Support.alignY(0, own._inset, scale, 0),
  })
end

-- ManagedSprite_SetPositionXY of the falling copy against its authored row,
-- together with the affine pair it carries.
---@param sourceTimedBody SourceTimedBody body under publication
---@param own SourceTimedAffinePairJump run state behind the pose
local function publishDrop(sourceTimedBody, own)
  local stretch = own._stretch --[[@as SourceTimedScaleMotion]]
  local drop = own._drop --[[@as SourceTimedLinearMotion]]
  sourceTimedBody:publishPicture(own._defender, {
    affineMode = true,
    affineWidth = stretch.x,
    affineHeight = stretch.y,
    pictureYOffset = Support.clampOffset(drop.y),
  })
end

-- BattleAnimFunc_DarkSpriteJump (battle_anim_effects.c, selector 32 of
-- gBattleAnimFuncTable): the machine walks the battlefield blend pair from 0/16
-- to 8/8, stretches the attacker's rising copy from 1.0 to twice its height,
-- shrinks its width to a tenth, hides it, drops the defender's falling copy from
-- sixty-four pixels above through an eight-frame fall and a widening landing
-- leg, and walks the pair back out. The callback never touches a Pokepic
-- attribute: it drives four script-created managed sprite copies, so the scene
-- presents the attacker and target pictures in place of the rising and falling
-- copies and no mon is hidden anywhere. Those copies' XLU OAM mode, draw
-- priority 100, BG priority 1, double affine overwrite mode, the falling copy's
-- (0, 40) affine translation, the two afterimage copies with their
-- gBattleAnimDarkSpriteDrawFlags type-dependent draw flags, the per-frame
-- SpriteSystem_DrawSprites of all four, and the palette darkening each shown
-- copy receives (PaletteData_BlendPalettes toward black at coefficient 8) have
-- no scene expression.
---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return SourceTimedBody runnable affine pair jump task
local function newAffinePairJump(kind, args, context, services)
  local parameters = Support.parameters(args, kind)
  local inset = wholeOperand(parameters, "pictureInset", kind)
  if inset ~= nil and inset < 0 then
    Support.malformed(kind, "carries its battler picture inset as a non-negative whole word")
  end
  local attacker = ownedActivation(args, context, kind)
  local defender = ownedActivation(args, context, kind, "target")
  ---@param self SourceTimedBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    local own = self --[[@as SourceTimedAffinePairJump]]
    -- The queued coefficient walk (BattleAnimUtil_StartBlendAlphaMotion) writes
    -- reg_G2_BLDALPHA once per tick; its closing frame only reports itself done.
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
    if phase == "fade-in" then
      -- DARK_JUMP_STATE_FADE_IN: BattleAnimUtil_SetBlendWithBattleBg(0, 16) then
      -- the walk toward the sprite and battlefield weights of 8.
      self:writeScalar({ blendCoefficientA = 0, blendCoefficientB = DARK_JUMP_BACKGROUND_WEIGHT })
      own._ramp = Support.linear(
        0,
        DARK_JUMP_SPRITE_WEIGHT,
        DARK_JUMP_BACKGROUND_WEIGHT,
        DARK_JUMP_SPRITE_WEIGHT,
        DARK_JUMP_BLEND_TICKS
      )
      own._rampDone = false
      own._phase = "wait-fade-in"
      return false
    end
    if phase == "wait-fade-in" then
      if not own._rampDone then
        return false
      end
      -- DARK_JUMP_STATE_WAIT_FADE_IN retired: BattleAnimTask_DarkSpriteJumpStartRise
      -- seats both motions, shows the rising copy, and writes its authored
      -- affine scale without aligning the row on this frame.
      own._stretch = Support.scaleMotion(10, 10, 10, 20, DARK_JUMP_SCALE_DIVISOR, DARK_JUMP_STRETCH_TICKS)
      own._scale = Support.scaleMotion(10, 1, 10, 1, DARK_JUMP_SCALE_DIVISOR, DARK_JUMP_SHRINK_TICKS)
      own._partTimer = DARK_JUMP_STRETCH_TIMER
      own._part = "stretch"
      own._phase = "rise"
      publishRise(self, own, own._stretch.x, own._stretch.y, own._stretch.curY)
      return false
    end
    if phase == "rise" then
      if own._part == "stretch" then
        -- JUMP_RISE_STATE_STRETCH: the stretched pair writes its scale and the
        -- row aligned to it, and the frame after the seventh one re-seats the
        -- pair for the width leg.
        own._stretch:step()
        publishRise(self, own, own._stretch.x, own._stretch.y, own._stretch.curY)
        own._partTimer = own._partTimer - 1
        if own._partTimer < 0 then
          own._part = "scale"
          own._stretch = Support.scaleMotion(10, 1, 20, 20, DARK_JUMP_SCALE_DIVISOR, DARK_JUMP_SHRINK_TICKS)
        end
        return false
      end
      -- JUMP_RISE_STATE_SCALE: the stretch keeps advancing for the row, and the
      -- shrinking width leg supplies the written width.
      own._stretch:step()
      if own._scale:step() then
        publishRise(self, own, own._scale.x, own._stretch.y, own._stretch.curY)
        return false
      end
      own._part = "done"
      own._phase = "delay"
      own._timer = DARK_JUMP_DELAY_TIMER
      -- The exhausted frame hides the rising copy (ManagedSprite_SetDrawFlag);
      -- the presented picture returns to its authored affine because the hidden
      -- copy is the one it stands in for.
      self:publishPicture(own._attacker, {
        affineMode = true,
        affineWidth = AFFINE_ONE,
        affineHeight = AFFINE_ONE,
        pictureYOffset = 0,
      })
      return false
    end
    if phase == "delay" then
      own._timer = own._timer - 1
      if own._timer >= 0 then
        return false
      end
      -- DARK_JUMP_STATE_DELAY retired: BattleAnimTask_DarkSpriteJumpStartDrop
      -- seats the falling leg and the widening pair, shows the falling copy,
      -- and spends the leg's first step on this frame.
      own._drop = Support.linear(0, 0, -DARK_JUMP_DROP_PIXELS, 0, DARK_JUMP_DROP_TICKS)
      own._stretch = Support.scaleMotion(2, 10, 20, 10, DARK_JUMP_SCALE_DIVISOR, DARK_JUMP_DROP_TICKS)
      own._drop:step()
      own._partTimer = DARK_JUMP_STRETCH_TIMER
      own._part = "fall"
      own._phase = "drop"
      publishDrop(self, own)
      return false
    end
    if phase == "drop" then
      if own._part == "fall" then
        -- JUMP_DROP_STATE_FALL: only the falling leg writes while the widening
        -- pair waits for the landing.
        own._partTimer = own._partTimer - 1
        own._drop:step()
        publishDrop(self, own)
        if own._partTimer < 0 then
          own._part = "land"
        end
        return false
      end
      -- JUMP_DROP_STATE_LAND: every frame, including the exhausted one, writes
      -- the widening pair; the falling leg has nothing left to spend.
      own._drop:step()
      local active = own._stretch:step()
      publishDrop(self, own)
      if active then
        return false
      end
      own._part = "done"
      own._phase = "fade-out"
      own._ramp = Support.linear(
        DARK_JUMP_SPRITE_WEIGHT,
        0,
        DARK_JUMP_SPRITE_WEIGHT,
        DARK_JUMP_BACKGROUND_WEIGHT,
        DARK_JUMP_BLEND_TICKS
      )
      own._rampDone = false
      return false
    end
    if phase == "fade-out" then
      -- DARK_JUMP_STATE_FADE_OUT retires on the frame the walk reports itself
      -- done, so the following frame is the destroy frame.
      if own._rampDone then
        own._phase = "end"
      end
      return false
    end
    -- DARK_JUMP_STATE_END: the source destroys its task without a write.
    return true
  end
  return Support.newBody(kind, services, {
    _attacker = attacker,
    _defender = defender,
    _inset = inset or 0,
    _phase = "fade-in",
    _part = "stretch",
    _partTimer = 0,
    _timer = 0,
    _stretch = nil,
    _scale = nil,
    _drop = nil,
    _ramp = nil,
    _rampDone = false,
  }, advance)
end

SpriteFormation["pokemon-picture-managed-sprite-affine-pair-transition"] = newAffinePairJump

return SpriteFormation
