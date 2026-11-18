-- Source-timed native bodies for the attacker picture sequences whose
-- overlay-07 implementations own their whole timeline. Every phase table and
-- every tick boundary below is the pinned source's, named at the kind.

local Support = require("libs.hgss.src.presentation.sourceTimed.Support")

local Core = {}

-- Battler picture row lift behind absolute-Y natives. The native machine
-- writes an absolute picture center Y of 0 (screen top) as its rise target;
-- the product layout puts the presented picture center at 40 minus the
-- battler picture height, the same row rule the ball cues use
-- (game/hgss/src/battle/BattleTimeline.lua, faint/ball appearance row).
local PICTURE_ROW_CENTER = 40

-- BattleAnimFunc_AttackerLeapOffscreen (battle_anim_move_effects.c): two
-- gBattleAnimLeapOffscreenSteps scale phases with a five-tick rise between
-- them, then the terminal vanish write. Each step is a
-- BattleAnimScaleStepXY record {startX, endX, startY, endY, duration} in
-- 1/100 scale words; the machine aligns the picture Y to the current scale on
-- both legs, the second leg mirrored (mode 1) from the risen Y.
local LEAP_STEPS = {
  { startX = 100, endX = 10, startY = 100, endY = 180, duration = 10 },
  { startX = 10, endX = 10, startY = 180, endY = 0, duration = 5 },
}
local LEAP_RISE_TICKS = 5

---@class SourceTimedSilhouetteCycle
---@field _activation table<string, unknown> attacker picture the cycle owns

---@class SourceTimedLeapOffscreen
---@field _activation table<string, unknown> attacker picture the leap owns
---@field _inset integer battler picture height behind the scale alignment
---@field _step integer next leap step behind initialization
---@field _motion SourceTimedScaleMotion? scale motion under advancement
---@field _rise SourceTimedLinearMotion? rise motion under advancement
---@field _leg string current leg behind per-tick writes
---@field _baseY integer authored picture row center behind the rise target
---@field _high integer aligned row at the end of the first scale leg
---@field _risen integer row the picture rose to behind the second leg
local LeapOffscreen = {}

---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return SourceTimedBody runnable leap task
local function newLeapOffscreen(kind, args, context, services)
  Support.parameters(args, kind)
  local activation = Support.requiredActivation(args, context, kind)
  local parameters = Support.parameters(args, kind)
  local inset = parameters.pictureInset
  if inset ~= nil and (type(inset) ~= "number" or inset % 1 ~= 0 or inset < 0) then
    Support.malformed(kind, "carries its battler picture inset as a non-negative whole word")
  end
  local pictureInset = type(inset) == "number" and inset or 0
  local body
  ---@param self SourceTimedBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    local own = self --[[@as SourceTimedLeapOffscreen]]
    if own._leg == "scale" then
      if own._motion:step() then
        self:publishPicture(own._activation, {
          affineMode = true,
          affineWidth = own._motion.x,
          affineHeight = own._motion.y,
          pictureYOffset = Support.alignY(0, own._inset, own._motion.curY, 0),
        })
        return false
      end
      own._high = Support.alignY(0, own._inset, own._motion.curY, 0)
      if own._step == 1 then
        -- LEAP_OFFSCREEN_STATE_START_RISE: the native rise re-reads the
        -- picture's absolute Y and walks it to the screen top.
        own._rise = Support.linear(0, 0, own._high, -own._baseY, LEAP_RISE_TICKS)
        own._leg = "rise"
      else
        -- LEAP_OFFSCREEN_STATE_SCALE_AGAIN retired: the terminal state writes
        -- the base Y and vanish, keeping the task patch as its presented pose.
        self._persist = true
        self:publishPicture(own._activation, {
          affineMode = true,
          affineWidth = 256,
          affineHeight = 256,
          pictureYOffset = 0,
          vanished = true,
          pictureVisible = false,
        })
        return true
      end
      return false
    end
    if own._leg == "rise" then
      if own._rise:step() then
        self:publishPicture(own._activation, {
          affineMode = true,
          affineWidth = own._motion.x,
          affineHeight = own._motion.y,
          pictureYOffset = Support.clampOffset(own._rise.y),
        })
        return false
      end
      -- The rise parked the picture at the top; the second scale leg now
      -- squashes it away from that risen Y with the mirrored alignment.
      own._risen = own._high - own._baseY
      own._motion = Support.scaleMotion(
        LEAP_STEPS[2].startX,
        LEAP_STEPS[2].endX,
        LEAP_STEPS[2].startY,
        LEAP_STEPS[2].endY,
        100,
        LEAP_STEPS[2].duration
      )
      own._leg = "shrinking"
      return false
    end
    if own._leg == "shrinking" then
      if own._motion:step() then
        self:publishPicture(own._activation, {
          affineMode = true,
          affineWidth = own._motion.x,
          affineHeight = own._motion.y,
          pictureYOffset = Support.clampOffset(
            own._risen - own._inset + Support.scaleYOffset(own._inset, own._motion.curY)
          ),
        })
        return false
      end
      -- LEAP_OFFSCREEN_STATE_SCALE_AGAIN retired: the terminal state restores
      -- the authored Y and scale, then hides the picture for good.
      self._persist = true
      self:publishPicture(own._activation, {
        affineMode = true,
        affineWidth = 256,
        affineHeight = 256,
        pictureYOffset = 0,
        vanished = true,
        pictureVisible = false,
      })
      return true
    end
    -- First tick: initialize the first scale step and publish its start pose.
    own._motion = Support.scaleMotion(
      LEAP_STEPS[1].startX,
      LEAP_STEPS[1].endX,
      LEAP_STEPS[1].startY,
      LEAP_STEPS[1].endY,
      100,
      LEAP_STEPS[1].duration
    )
    own._step = 1
    own._leg = "scale"
    self:publishPicture(own._activation, {
      affineMode = true,
      affineWidth = own._motion.x,
      affineHeight = own._motion.y,
      pictureYOffset = Support.alignY(0, own._inset, own._motion.curY, 0),
    })
    return false
  end
  body = Support.newBody(kind, services, {
    _activation = activation,
    _inset = pictureInset,
    _step = 1,
    _motion = nil,
    _rise = nil,
    _leg = "start",
    _baseY = math.max(1, PICTURE_ROW_CENTER - pictureInset),
    _high = 0,
    _risen = 0,
  }, advance)
  return body
end

Core["pokemon-picture-leap-offscreen-transition"] = newLeapOffscreen

-- BattleAnimFunc_AttackerSilhouette (battle_anim_move_effects.c): fades the
-- battlefield background palette toward white while the attacker picture
-- palette fades toward black, holds the silhouette, then fades both back.
-- The background fade steps four coefficients per frame and the picture fade
-- one per frame, so the picture owns the boundary: seventeen ticks out, the
-- six-tick hold, seventeen ticks back, plus the two start ticks.
local SILHOUETTE_FADE_TICKS = 17
local SILHOUETTE_HOLD_TICKS = 6
local SILHOUETTE_BG_STEP = 4
local SILHOUETTE_TARGET_COLOR = 0 -- Pokepic_StartPaletteFade target RGB_BLACK
local SILHOUETTE_BG_COLOR = { r = 31, g = 31, b = 31 } -- RGB_WHITE

---@param level integer picture fade level under publication
---@param finish integer fade endpoint under publication
---@return table<string, unknown> picture palette overlay
local function silhouettePicturePatch(level, finish)
  return {
    paletteFade = {
      start = Support.clampLevel(level),
      finish = Support.clampLevel(finish),
      framesPer = 0,
      targetColor = SILHOUETTE_TARGET_COLOR,
    },
  }
end

---@param body SourceTimedBody silhouette body under writing
---@param activation table<string, unknown> attacker picture the cycle owns
---@param level integer picture fade level under publication
---@param finish integer fade endpoint under publication
local function publishSilhouette(body, activation, level, finish)
  body:writeCompositor({
    battlefieldFade = {
      color = SILHOUETTE_BG_COLOR,
      amount = Support.clampLevel(math.floor(level / SILHOUETTE_BG_STEP + 0.5) * SILHOUETTE_BG_STEP),
    },
  })
  body:publishPicture(activation, silhouettePicturePatch(level, finish))
end

---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return SourceTimedBody runnable silhouette cycle task
local function newSilhouetteCycle(kind, args, context, services)
  Support.parameters(args, kind)
  local activation = Support.requiredActivation(args, context, kind)
  local outEnd = 1 + SILHOUETTE_FADE_TICKS
  local holdEnd = outEnd + SILHOUETTE_HOLD_TICKS
  local inEnd = holdEnd + SILHOUETTE_FADE_TICKS
  ---@param self SourceTimedBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    local tick = self._ticks
    local own = self --[[@as SourceTimedSilhouetteCycle]]
    if tick <= outEnd then
      publishSilhouette(self, own._activation, math.min(16, tick - 1), 16)
      return false
    end
    if tick <= holdEnd then
      publishSilhouette(self, own._activation, 16, 16)
      return false
    end
    if tick < inEnd then
      -- The return leg mirrors the out leg, one coefficient per frame.
      publishSilhouette(self, own._activation, math.max(0, 16 - (tick - holdEnd)), 0)
      return false
    end
    return true
  end
  return Support.newBody(kind, services, {
    _activation = activation,
    _duration = inEnd,
  }, advance)
end

Core["pokemon-picture-and-battle-palette-fade-cycle"] = newSilhouetteCycle

return Core
