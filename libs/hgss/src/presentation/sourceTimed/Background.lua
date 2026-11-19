-- Source-timed native battle animation bodies: the background wave family.
-- Each entry maps one producer task kind to its body constructor and
-- reproduces one overlay-07 callback that waves a scanline effect over a
-- battler picture (battle_anim_effects.c, battle_anim_move_effects.c in the
-- pinned pret/pokeheartgold tree). See Support.lua for the journaled write
-- seams and the lifecycle every body shares.

local Support = require("libs.hgss.src.presentation.sourceTimed.Support")

local Background = {}

-- The natives in this family address one battler of their own
-- (BattleAnimSystem_GetDefender for the defender wave,
-- BattleAnimSystem_GetAttacker for the attacker wave), so the occurrence's
-- picture on that side is the one the body owns. A produced battlerTarget
-- keeps its word; without one the side resolves the presented activation
-- directly, and the producer lowers no battler target for these selectors.
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param kind string task kind under diagnosis
---@param role string "attacker" or "target" side the native addresses
---@return table<string, unknown> combatant and activation pair behind the owned picture
local function ownedActivation(args, context, kind, role)
  if args.activation ~= nil or args.battlerTarget ~= nil then
    return Support.requiredActivation(args, context, kind)
  end
  return Support.requiredActivation({ battlerTarget = role }, context, kind)
end

-- BattleAnimUtil_GetBattlerType: the native battler type of one presented
-- combatant, read from the occurrence topology.
---@param context table<string, unknown> occurrence-bound playback context
---@param combatant number combatant whose battler type is under reading
---@param kind string task kind under diagnosis
---@return integer native battler type in 0..5
local function battlerType(context, combatant, kind)
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
          return math.floor(sideType)
        end
      end
    end
  end
  error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " resolves the battler type of the picture it waves", 0)
end

-- BattleAnimFunc_WaveDefenderOnBg (battle_anim_effects.c): the callback
-- writes the effect-over-battlefield register pair and starts the twenty-four
-- tick coefficient walk; the blend machine then holds until its down counter
-- drops below zero before starting the mirrored walk.
local DEFENDER_BLEND_IN_START_A = 0
local DEFENDER_BLEND_IN_END_A = 8
local DEFENDER_BLEND_IN_START_B = 16
local DEFENDER_BLEND_IN_END_B = 8
local DEFENDER_BLEND_OUT_START_A = 8
local DEFENDER_BLEND_OUT_END_A = 0
local DEFENDER_BLEND_OUT_START_B = 8
local DEFENDER_BLEND_OUT_END_B = 16
local DEFENDER_BLEND_TICKS = 24
local DEFENDER_HOLD_TICKS = 32

-- The callback draws its battler sprite copy only for these two native
-- battler types (BATTLER_TYPE_PLAYER_SIDE_SLOT_1 and
-- BATTLER_TYPE_ENEMY_SIDE_SLOT_2) and leaves it undrawn for every other type,
-- so the task's hide state only reaches the pokepic when the copy is drawn.
local DEFENDER_DRAWN_TYPES = {
  [2] = true,
  [5] = true,
}

---@class SourceTimedDefenderWave
---@field _activation table<string, unknown> defender picture the wave owns
---@field _hidesPicture boolean the callback drew the sprite copy the hide state reads
---@field _taskState string current native task state
---@field _blendState string current native blend state
---@field _ramp SourceTimedLinearMotion? coefficient pair under advancement
---@field _timer integer hold ticks left

---@param startA integer first EVA coefficient
---@param endA integer last EVA coefficient
---@param startB integer first EVB coefficient
---@param endB integer last EVB coefficient
---@return SourceTimedLinearMotion coefficient walk record
local function blendWalk(startA, endA, startB, endB)
  return Support.linear(startA, endA, startB, endB, DEFENDER_BLEND_TICKS) --[[@as SourceTimedLinearMotion]]
end

-- BattleAnimFunc_WaveDefenderOnBg (battle_anim_effects.c, selector 20 of
-- gBattleAnimFuncTable): the callback stages the defender as a wavy scanline
-- effect layer, hides the pokepic when the battler sprite copy is drawn,
-- cross-fades the effect layer over the battlefield for twenty-four ticks,
-- holds, fades back, and destroys its task on the frame after the reverse
-- walk reports done. The scene presents the pokepic and the shared
-- coefficient registers only, so the scanline wave over the effect BG layer
-- (rows from the picture top to its bottom, step 910, amplitude 5.0 pixels,
-- speed 100, base offset -(x - 40)/-top in the effect layer's own
-- BGnHOFS/BGnVOFS registers), the BG layer priorities that pick which side
-- keeps the picture, the MAIN_BG palette blend toward black at level 8, and
-- the effect layer's character and tilemap clear stay unreproduced.
---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return SourceTimedBody runnable defender wave task
local function newDefenderWave(kind, args, context, services)
  Support.parameters(args, kind)
  local activation = ownedActivation(args, context, kind, "target")
  local sideType = battlerType(context, activation.combatant, kind)
  ---@param self SourceTimedBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    local own = self --[[@as SourceTimedDefenderWave]]
    local ramp = own._ramp
    local rampDone = false
    if ramp ~= nil then
      if ramp:step() then
        -- BattleAnimTask_BlendAlphaMotion writes reg_G2_BLDALPHA from the
        -- stepped pair on every tick of the walk; the blend mode and plane
        -- masks BattleAnimUtil_SetBlendBgOverBattleBg selects (the effect BG
        -- layer over the battle BG, BG0, and the object plane) have no scene
        -- expression.
        self:writeScalar({ blendCoefficientA = ramp.x, blendCoefficientB = ramp.y })
      else
        own._ramp = nil
        rampDone = true
      end
    end
    local state = own._taskState
    if state == "hide-pic" then
      -- WAVE_ON_BG_STATE_HIDE_PIC: the drawn battler sprite copy covers the
      -- defender, so the pokepic vanishes one frame after the callback and
      -- keeps drawing when the callback left the copy undrawn. The copy's own
      -- draw flag and its priority 2 write have no scene expression.
      if own._hidesPicture then
        self:publishPicture(own._activation, { vanished = true, pictureVisible = false })
      end
      own._taskState = "wave"
      return false
    end
    if state == "wave" then
      local blend = own._blendState
      if blend == "blend-in" then
        -- WAVE_BLEND_STATE_WAIT_BLEND_IN retires on the walk's closing frame.
        if rampDone then
          own._blendState = "hold"
          own._timer = DEFENDER_HOLD_TICKS
        end
        return false
      end
      if blend == "hold" then
        -- WAVE_BLEND_STATE_HOLD counts down and starts the mirrored walk on
        -- the frame its pre-decrement drops below zero.
        own._timer = own._timer - 1
        if own._timer < 0 then
          own._blendState = "blend-out"
          own._ramp = blendWalk(
            DEFENDER_BLEND_OUT_START_A,
            DEFENDER_BLEND_OUT_END_A,
            DEFENDER_BLEND_OUT_START_B,
            DEFENDER_BLEND_OUT_END_B
          )
        end
        return false
      end
      if blend == "blend-out" then
        -- WAVE_BLEND_STATE_BLEND_OUT frees the scanline wave on the closing
        -- frame of the mirrored walk and only then reaches its done state.
        if rampDone then
          own._blendState = "done"
        end
        return false
      end
      -- WAVE_BLEND_STATE_DONE reports done, which advances the task state.
      own._taskState = "end"
      return false
    end
    -- WAVE_ON_BG_STATE_END: POKEPIC_VANISHED goes back to FALSE, the effect
    -- layer's character data and tilemap are cleared, both BG priorities are
    -- restored, and the task is destroyed. Only a picture this body hid is
    -- published again; the layer and priority writes have no scene expression.
    if own._hidesPicture then
      self:publishPicture(own._activation, { vanished = false, pictureVisible = true })
    end
    return true
  end
  local body = Support.newBody(kind, services, {
    _activation = activation,
    _hidesPicture = DEFENDER_DRAWN_TYPES[sideType] == true,
    _taskState = "hide-pic",
    _blendState = "blend-in",
    _ramp = blendWalk(
      DEFENDER_BLEND_IN_START_A,
      DEFENDER_BLEND_IN_END_A,
      DEFENDER_BLEND_IN_START_B,
      DEFENDER_BLEND_IN_END_B
    ),
    _timer = 0,
  }, advance)
  -- BattleAnimUtil_SetBlendBgOverBattleBg writes the opening coefficient pair
  -- before the first scheduled frame, and that frame's walk step re-writes it.
  body:writeScalar({ blendCoefficientA = DEFENDER_BLEND_IN_START_A, blendCoefficientB = DEFENDER_BLEND_IN_START_B })
  return body
end

Background["battle-background-picture-wipe-transition"] = newDefenderWave

-- BattleAnimFunc_WaveAttackerOnBg (battle_anim_move_effects.c): the callback
-- starts the sixteen-tick coefficient walk, the wave gate waits for it, the
-- wave runs for 120 frames, and the mirrored walk follows before the restore.
local ATTACKER_BLEND_IN_START_A = 16
local ATTACKER_BLEND_IN_END_A = 2
local ATTACKER_BLEND_IN_START_B = 2
local ATTACKER_BLEND_IN_END_B = 16
local ATTACKER_BLEND_OUT_START_A = 2
local ATTACKER_BLEND_OUT_END_A = 16
local ATTACKER_BLEND_OUT_START_B = 16
local ATTACKER_BLEND_OUT_END_B = 2
local ATTACKER_BLEND_TICKS = 16
local ATTACKER_WAVE_TICKS = 120

---@class SourceTimedAttackerWave
---@field _activation table<string, unknown> attacker picture the wave owns
---@field _taskState string current native task state
---@field _ramp SourceTimedLinearMotion? coefficient pair under advancement
---@field _timer integer wave frames spent

-- BattleAnimFunc_WaveAttackerOnBg (battle_anim_move_effects.c, selector 55 of
-- gBattleAnimFuncTable): the callback turns the attacker's battler sprite copy
-- into an object window and stages a battle background copy on BG2, hides the
-- pokepic, cross-fades the effect layer for sixteen ticks, waves the effect
-- layer for 120 frames, fades back, restores POKEPIC_VANISHED, and destroys
-- its task on the frame after that restore. The scene presents the pokepic and
-- the shared coefficient registers only, so the scanline wave over the effect
-- BG layer (rows 0..160, step 364, amplitude 12.0 pixels, speed 200, zero base
-- offset), the object-window mask writes and the window sprite's OAM mode, the
-- BG2 background load with its layer toggle and reset, and the sprite copy's
-- XLU OAM mode stay unreproduced.
---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return SourceTimedBody runnable attacker wave task
local function newAttackerWave(kind, args, context, services)
  Support.parameters(args, kind)
  local activation = ownedActivation(args, context, kind, "attacker")
  ---@param self SourceTimedBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    local own = self --[[@as SourceTimedAttackerWave]]
    local ramp = own._ramp
    local rampDone = false
    if ramp ~= nil then
      if ramp:step() then
        -- BattleAnimTask_BlendAlphaMotion writes reg_G2_BLDALPHA from the
        -- stepped pair on every tick of the walk; the blend mode the callback
        -- leaves in place has no scene expression.
        self:writeScalar({ blendCoefficientA = ramp.x, blendCoefficientB = ramp.y })
      else
        own._ramp = nil
        rampDone = true
      end
    end
    local state = own._taskState
    if state == "hide-pic" then
      -- WAVE_ATTACKER_STATE_HIDE_PIC: the object window covers the attacker
      -- silhouette, so the pokepic vanishes on the first scheduled frame. The
      -- window sprite's OAM mode and plane masks have no scene expression.
      self:publishPicture(own._activation, { vanished = true, pictureVisible = false })
      own._taskState = "start-wave"
      return false
    end
    if state == "start-wave" then
      -- WAVE_ATTACKER_STATE_START_WAVE starts the wave only once the walk
      -- reports done, so the wave never overlaps the opening fade.
      if rampDone then
        own._timer = 0
        own._taskState = "wave"
      end
      return false
    end
    if state == "wave" then
      -- WAVE_ATTACKER_STATE_WAVE counts its own frames and frees the wave on
      -- the frame the count reaches 120, starting the mirrored walk there.
      own._timer = own._timer + 1
      if own._timer >= ATTACKER_WAVE_TICKS then
        own._ramp = Support.linear(
          ATTACKER_BLEND_OUT_START_A,
          ATTACKER_BLEND_OUT_END_A,
          ATTACKER_BLEND_OUT_START_B,
          ATTACKER_BLEND_OUT_END_B,
          ATTACKER_BLEND_TICKS
        ) --[[@as SourceTimedLinearMotion]]
        own._taskState = "fade-out"
      end
      return false
    end
    if state == "fade-out" then
      -- WAVE_ATTACKER_STATE_FADE_OUT restores POKEPIC_VANISHED on the closing
      -- frame of the mirrored walk.
      if not rampDone then
        return false
      end
      self:publishPicture(own._activation, { vanished = false, pictureVisible = true })
      own._taskState = "end"
      return false
    end
    -- The default state hides every window, resets the BG2 layer, and destroys
    -- the task; both writes have no scene expression.
    return true
  end
  return Support.newBody(kind, services, {
    _activation = activation,
    _taskState = "hide-pic",
    _ramp = Support.linear(
      ATTACKER_BLEND_IN_START_A,
      ATTACKER_BLEND_IN_END_A,
      ATTACKER_BLEND_IN_START_B,
      ATTACKER_BLEND_IN_END_B,
      ATTACKER_BLEND_TICKS
    ) --[[@as SourceTimedLinearMotion]],
    _timer = 0,
  }, advance)
end

Background["pokemon-picture-vanish-affine-transition"] = newAttackerWave

-- gBattleAnimShakeBattlefieldAmplitudes (asm/battle_anim_data.s): the eight
-- s16 words the shake walks in order.
local SHAKE_FLASH_AMPLITUDES = { 12, 10, 8, 6, 4, 2, 1, 0 }
-- BattleAnimUtil_InitShake(amplitude, 0, 0, 5): a zero interval spends one of
-- the four phases per tick, so one amplitude takes twenty ticks and the next
-- call reports the exhausted counter.
local SHAKE_FLASH_INTERVAL = 0
local SHAKE_FLASH_ROUNDS = 5
-- work->flashFrames = 3 blends the battle BG palette for the start frame and
-- the two frames after it; PaletteData_BlendPalettes(..., 0xFF, 10, target)
-- blends ten sixteenths toward the alternating target color.
local SHAKE_FLASH_FRAMES = 3
local SHAKE_FLASH_BLEND = 10
-- PaletteData_BeginPaletteFade(PLTTBUF_MAIN_BG_F, mask, wait 1, cur 0, end 10,
-- RGB_BLACK): a two-coefficient step every other frame, so the darken
-- publishes 0, 2, 4, 6, 8, and 10 across ten frames.
local SHAKE_FLASH_DARKEN_TICKS = 10
local SHAKE_FLASH_DARKEN_STEP = 2
local SHAKE_FLASH_BLACK = { r = 0, g = 0, b = 0 }
local SHAKE_FLASH_WHITE = { r = 31, g = 31, b = 31 }

---@class SourceTimedBattlefieldFlashShake
---@field _attacker table<string, unknown> attacker picture the shake owns
---@field _defender table<string, unknown> defender picture the shake owns
---@field _taskState string current native task state
---@field _shake SourceTimedShake? the amplitude round under advancement
---@field _shakeCount integer amplitudes already spent
---@field _white integer alternating flash selector, 0 for black and 1 for white
---@field _flashFrames integer blend frames left inside the current flash
---@field _fadeFrame integer frames spent inside the opening darken
---@field _scrollY integer authored viewport row behind every shake write

-- BattleAnimFunc_ShakeBattlefieldFlashing (battle_anim_move_effects.c,
-- selector 24 of gBattleAnimFuncTable): the callback darkens the battle BG
-- palette, then repeats the amplitude table: each round shakes every
-- collected battler picture and the battlefield BG3 layer for twenty ticks
-- while a three-frame palette blink alternates between black and white, and
-- the task destroys itself one frame after the last round reports exhausted.
-- BattleAnimUtil_CollectPicsByFlags selects the attacker and defender pictures
-- in a single battle (BATTLE_ANIM_ROLE_ATTACKER | BATTLE_ANIM_ROLE_DEFENDER)
-- and all four battler pictures in a double battle (BATTLE_ANIM_ROLE_ALL); the
-- occurrence presents one picture per side, so the partner slots the double
-- battle flag set also shakes stay unreproduced. The battle BG palette mask
-- and the palette fade buffers have no scene expression beyond the compositor
-- fade, and the BG3 Y register and its immediate commit stay unreproduced.
---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return SourceTimedBody runnable battlefield flash shake task
local function newBattlefieldFlashShake(kind, args, context, services)
  Support.parameters(args, kind)
  local attacker = ownedActivation(args, context, kind, "attacker")
  local defender = ownedActivation(args, context, kind, "target")
  ---@param self SourceTimedBody body under advancement
  ---@param own SourceTimedBattlefieldFlashShake body under its own fields
  ---@param offset integer horizontal shake offset in pixels
  local function shakePictures(self, own, offset)
    -- SHAKE_FIELD_FLASH_STATE_SHAKE writes POKEPIC_X as the shake offset over
    -- each collected picture's authored X; the scene keeps that as a relative
    -- offset. BgSetPosTextAndCommit(GF_BG_LYR_MAIN_3, X) moves the battlefield
    -- background layer's own horizontal register, which the scene expresses as
    -- the battlefield viewport.
    local pictureXOffset = Support.clampOffset(offset)
    self:publishPicture(own._attacker, { pictureXOffset = pictureXOffset })
    self:publishPicture(own._defender, { pictureXOffset = pictureXOffset })
    if own._scrollY == nil then
      own._scrollY = self:scene():scroll().y
    end
    self:writeScroll(pictureXOffset, own._scrollY)
  end
  ---@param self SourceTimedBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    local own = self --[[@as SourceTimedBattlefieldFlashShake]]
    if own._taskState == "darken" then
      -- SHAKE_FIELD_FLASH_STATE_DARKEN arms the battle BG palette fade; its
      -- opening application leaves the palette on its authored colors.
      self:writeCompositor({ battlefieldFade = { color = SHAKE_FLASH_BLACK, amount = 0 } })
      own._taskState = "wait-darken"
      return false
    end
    if own._taskState == "wait-darken" then
      -- SHAKE_FIELD_FLASH_STATE_WAIT_DARKEN polls the palette fade buffers and
      -- advances on the frame the fade task clears its own buffer bit, so the
      -- last darken coefficient and the first blink share that frame.
      own._fadeFrame = own._fadeFrame + 1
      if own._fadeFrame < SHAKE_FLASH_DARKEN_TICKS then
        if own._fadeFrame % 2 == 0 then
          local amount = math.floor(own._fadeFrame / 2) * SHAKE_FLASH_DARKEN_STEP
          self:writeCompositor({ battlefieldFade = { color = SHAKE_FLASH_BLACK, amount = amount } })
        end
        return false
      end
      own._taskState = "start-shake"
    end
    if own._taskState == "start-shake" then
      -- SHAKE_FIELD_FLASH_STATE_START_SHAKE opens the next amplitude round and
      -- the blink the round starts with, then falls through into its shake.
      own._shake =
        Support.shake(SHAKE_FLASH_AMPLITUDES[own._shakeCount + 1], 0, SHAKE_FLASH_INTERVAL, SHAKE_FLASH_ROUNDS)
      self:writeCompositor({
        battlefieldFade = {
          color = own._white == 0 and SHAKE_FLASH_BLACK or SHAKE_FLASH_WHITE,
          amount = SHAKE_FLASH_BLEND,
        },
      })
      own._flashFrames = SHAKE_FLASH_FRAMES
      own._white = own._white == 0 and 1 or 0
      own._shakeCount = own._shakeCount + 1
      own._taskState = "shake"
    end
    if own._taskState == "shake" then
      -- SHAKE_FIELD_FLASH_STATE_SHAKE spends one shake tick, then counts the
      -- blink down and re-writes both the collected picture X words and the
      -- battlefield layer X, including on the tick the shake exhausts.
      local shake = own._shake --[[@as SourceTimedShake]]
      if not shake:step() then
        own._taskState = own._shakeCount >= #SHAKE_FLASH_AMPLITUDES and "end" or "start-shake"
      end
      if own._flashFrames > 0 then
        own._flashFrames = own._flashFrames - 1
        if own._flashFrames == 0 then
          -- PaletteData_BlendPalettes(PLTTBUF_MAIN_BG, 0xFF, 0, 0) returns the
          -- battle BG palette to its opaque colors.
          self:writeCompositor({ battlefieldFade = { color = SHAKE_FLASH_BLACK, amount = 0 } })
        end
      end
      shakePictures(self, own, shake.x)
      return false
    end
    -- The default state destroys the task and frees its work.
    return true
  end
  return Support.newBody(kind, services, {
    _attacker = attacker,
    _defender = defender,
    _taskState = "darken",
    _shake = nil,
    _shakeCount = 0,
    _white = 0,
    _flashFrames = 0,
    _fadeFrame = 0,
    _scrollY = nil,
  }, advance)
end

Background["battle-background-picture-palette-scroll"] = newBattlefieldFlashShake

-- BattleAnimFunc_WindowSweepFlashWhite (battle_anim_effects.c): the callback
-- arms an eight-tick window interior sweep, waits seven frames, fades the
-- battle BG palette to white over sixteen coefficients, then fades it back.
local WINDOW_SWEEP_TICKS = 8
local WINDOW_SWEEP_DELAY_TICKS = 7
local WINDOW_SWEEP_FADE_LEVEL = 16
-- SelectedPaletteData_SetTimedFadeParams with wait 0 advances two coefficients
-- per frame, so the white fade and the return fade take eight frames each.
local WINDOW_SWEEP_FADE_STEP = 2
local WINDOW_SWEEP_WHITE = { r = 31, g = 31, b = 31 }

---@class SourceTimedWindowSweepFlash
---@field _taskState string current native task state
---@field _timer integer delay frames left before the white fade
---@field _sweepTicks integer window interior sweep ticks spent
---@field _fade { cur: integer, finish: integer }? scheduled palette fade under advancement

-- BattleAnimFunc_WindowSweepFlashWhite (battle_anim_effects.c, selector 41 of
-- gBattleAnimFuncTable): WINDOW_SWEEP_STATE_INIT arms
-- BattleAnimUtil_InitLinearMotion(127, 0, 0, 0, 8) for the window interior,
-- DELAY counts its seven frames down, SWEEP walks the interior while the
-- palette rises to white, WAIT_FLASH closes the window and starts the return
-- fade, WAIT_RESTORE holds until it clears, and END destroys the task. The
-- scene presents the battle BG palette only, so reg_G2_WIN0H/reg_G2_WIN0V (the
-- swept interior rectangle), GX_SetVisibleWnd(GX_WNDMASK_W0/NONE), the window
-- plane masks and the windowed palette update stay unreproduced and the whole
-- battlefield plane takes the flash.
---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param _ table<string, unknown> unused occurrence context, this native owns no picture
---@param services table<string, unknown> factory services record
---@return SourceTimedBody runnable window sweep flash task
local function newWindowSweepFlash(kind, args, _, services)
  Support.parameters(args, kind)
  ---@param self SourceTimedBody body under advancement
  ---@param own SourceTimedWindowSweepFlash body under its own fields
  local function applyFadeStep(self, own)
    local fade = own._fade
    if fade == nil then
      return
    end
    -- The scheduled palette task applies one coefficient per frame and clears
    -- its own selected-buffer bit on the frame it applies the last one.
    self:writeCompositor({ battlefieldFade = { color = WINDOW_SWEEP_WHITE, amount = fade.cur } })
    if fade.cur == fade.finish then
      own._fade = nil
    elseif fade.cur < fade.finish then
      fade.cur = math.min(fade.cur + WINDOW_SWEEP_FADE_STEP, fade.finish)
    else
      fade.cur = math.max(fade.cur - WINDOW_SWEEP_FADE_STEP, fade.finish)
    end
  end
  ---@param self SourceTimedBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    local own = self --[[@as SourceTimedWindowSweepFlash]]
    applyFadeStep(self, own)
    local state = own._taskState
    if state == "init" then
      own._timer = WINDOW_SWEEP_DELAY_TICKS
      own._taskState = "delay"
      return false
    end
    if state == "delay" then
      -- WINDOW_SWEEP_STATE_DELAY pre-decrements, so the seventh frame leaves
      -- the counter below zero and starts the white fade.
      own._timer = own._timer - 1
      if own._timer < 0 then
        own._fade = { cur = 0, finish = WINDOW_SWEEP_FADE_LEVEL }
        applyFadeStep(self, own)
        own._taskState = "sweep"
      end
      return false
    end
    if state == "sweep" then
      -- WINDOW_SWEEP_STATE_SWEEP spends a sweep tick and steps into the flash
      -- gate on the frame after the motion reports exhausted.
      own._sweepTicks = own._sweepTicks + 1
      if own._sweepTicks > WINDOW_SWEEP_TICKS then
        own._taskState = "wait-flash"
      end
      return false
    end
    if state == "wait-flash" then
      -- WINDOW_SWEEP_STATE_WAIT_FLASH waits for the white fade, closes the
      -- window, and starts the return fade from the white endpoint.
      if own._fade == nil then
        own._fade = { cur = WINDOW_SWEEP_FADE_LEVEL, finish = 0 }
        applyFadeStep(self, own)
        own._taskState = "wait-restore"
      end
      return false
    end
    if state == "wait-restore" then
      -- WINDOW_SWEEP_STATE_WAIT_RESTORE retires the state machine once the
      -- return fade clears its buffers.
      if own._fade == nil then
        own._taskState = "end"
      end
      return false
    end
    -- WINDOW_SWEEP_STATE_END frees the work and destroys the task.
    return true
  end
  return Support.newBody(kind, services, {
    _taskState = "init",
    _timer = 0,
    _sweepTicks = 0,
    _fade = nil,
  }, advance)
end

Background["battle-display-window-palette-transition"] = newWindowSweepFlash

---@class SourceTimedObjWindowBackgroundAppearance
---@field _activation table<string, unknown> attacker picture whose silhouette feeds the window
---@field _silhouette boolean the body still owns the scene silhouette

-- The silhouette seam is not one of the journaled Support writes, so the body
-- releases it on the frame BattleAnimTask_EndObjWindow clears the window and on
-- cancellation, whichever lands first.
---@param body SourceTimedBody body under release
local function releaseSilhouette(body)
  local own = body --[[@as SourceTimedObjWindowBackgroundAppearance]]
  if own._silhouette ~= true then
    return
  end
  own._silhouette = false
  local scene = body:scene()
  scene.setObjWindowSilhouette(scene, nil)
end

-- BattleAnimFunc_ShowBattleBgInObjWindow (battle_anim_funcs.c, selector 56 of
-- gBattleAnimFuncTable): the callback reads and discards its first script
-- word, loads the battle background copy onto BG2, turns battler sprite 0 into
-- the object window at 1.2 affine scale, writes the WINOUT plane split, and
-- arms BattleAnimTask_EndObjWindow. That task clears the object-window
-- DISPCNT mask, resets the BG2 layer, and destroys itself on its own frame, so
-- the appearance lives exactly one source tick. The scene presents the battler
-- silhouette as the window coverage through its compositor, so the unreproduced
-- details are the BG2 copy load (BattleAnimBackground_LoadBattleBgToLayerDefault
-- stages the default battle background, which the scene already presents as its
-- battlefield), the sprite's GX_OAM_MODE_OBJWND mode, its
-- NNS_G2D_RND_AFFINE_OVERWRITE_DOUBLE 1.2 scale, and the priority writes: no
-- copy exists to reveal, so the inside mask keeps the battlefield plane instead
-- of punching the mon-shaped hole the native BG3 mask would leave.
---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return SourceTimedBody runnable object-window background appearance
local function newObjWindowBackgroundAppearance(kind, args, context, services)
  Support.parameters(args, kind)
  local activation = ownedActivation(args, context, kind, "attacker")
  local scene = Support.checkScene(services, kind)
  if type(scene.setObjWindowSilhouette) ~= "function" then
    Support.malformed(kind, "presents its object window through the scene silhouette seam")
  end
  ---@param self SourceTimedBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    -- BattleAnimTask_EndObjWindow: the window masks drop with the journaled
    -- compositor restore and the silhouette clears here.
    releaseSilhouette(self)
    return true
  end
  local body = Support.newBody(kind, services, {
    _activation = activation,
    _silhouette = false,
  }, advance)
  -- The callback's own writes, one frame before EndObjWindow runs: the WINOUT
  -- pair splits the planes around the object window, and battler sprite 0 (the
  -- attacker's) becomes the window coverage.
  body:writeCompositor({
    windows = {
      objWindow = {
        mask = { world3d = true, window = true, transition = true, battlefield = true },
      },
      outside = {
        mask = { world3d = true, window = true, transition = false, battlefield = true },
      },
    },
  })
  scene.setObjWindowSilhouette(scene, activation)
  local own = body --[[@as table<string, unknown>]]
  own._silhouette = true
  -- The native task owns the window until it destroys itself, so cancellation
  -- has to clear the silhouette the journaled restore cannot reach.
  local baseCancel = body.cancel
  local function cancel(self, reason)
    if self._state ~= "complete" then
      releaseSilhouette(self)
    end
    return baseCancel(self, reason)
  end
  own.cancel = cancel
  return body
end

Background["battle-sprite-affine-appearance-transition"] = newObjWindowBackgroundAppearance

return Background
