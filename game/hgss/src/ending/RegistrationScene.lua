-- The Hall of Fame registration application: the source's own two-scene
-- choreography (src/register_hall_of_fame.c) over the recorded party.
-- Every recorded member gets its own reveal, alternating sides by party
-- order: back picture flies in with its cry, the follower sprite flies in,
-- the header prints, the front picture flies in, the species/level print
-- with the front cry, and the caught detail holds before the fly-out. The
-- whole party then flies in for the group photo, which waits for the
-- player's terminal acknowledgment (A/B/touch, never START) between two
-- photo flashes. Only the photo wait answers input; every other stage runs
-- its exact source frame count.
--
-- Stage timings and sprite geometry are transcribed from the retail source:
-- ShowMon_LeftSide/ShowMon_RightSide subproc stages, WholeMonsSceneSubproc,
-- sPicPosScaleAnimParams, the per-side reset positions, and the flash/fade
-- frame counts. Background scrolls replicate the scheduled BG offsets,
-- including the source's own end-of-stage snaps. The follower sprite draws
-- the admitted species front portrait scaled as its 2D stand-in (a
-- documented adaptation: the source flattens the species 3D-model texture
-- over a generic sprite, which the port cannot rasterize, so the port
-- samples the correct mon's own portrait instead of a generic overworld
-- frame); whole-party shadows render dark throughout (the source tints
-- them with the mon palette after the flash).
--
-- Pure state machine: no love, no I/O. Sprite placements are computed here
-- so drawing consumes one snapshot; cry and sound cues are collected for
-- the owner to play exactly once.

local PokepicAnim = require("game.hgss.src.ending.PokepicAnim")

---@class RegistrationSceneMember resolved per-member reveal facts
---@field species string
---@field crySpecies string|nil
---@field form integer
---@field gender string
---@field owLarge boolean
---@field cryDelayBack integer
---@field cryDelayFront integer
---@field height integer
---@field backSteps { next: integer, duration: integer, xOffset: number }[]
---@field frontSteps { next: integer, duration: integer, xOffset: number }[]

---@class RegistrationSceneFade active black fade envelope
---@field mode string "in" | "out"
---@field remaining integer
---@field total integer

---@class RegistrationSceneSprite draw-resolution sprite entry
---@field kind string
---@field slot integer|nil
---@field x number
---@field y number
---@field scale number
---@field frame integer
---@field palette string
---@field visible boolean
---@field alpha number

---@class RegistrationSceneWindows visible indiv/whole window names
---@field header boolean?
---@field nickname boolean?
---@field species boolean?
---@field caught boolean?
---@field top boolean?
---@field bottom boolean?

---@class RegistrationScene
---@field private _party table[] recorded members in party order
---@field private _tracks table<string, unknown>|nil bundle picture tracks by species
---@field private _members table[] resolved scene members
---@field private _phase string "indiv" | "whole"
---@field private _monIndex integer
---@field private _stage integer indiv/whole stage index
---@field private _timer integer ticks spent in the stage
---@field private _side string "left" | "right"
---@field private _anims table<string, PokepicAnim> active picture animations by pic
---@field private _cryAt table[] pending {tick, species, form}
---@field private _cues table[] collected sound cues since the last take
---@field private _tick integer scene ticks since the reveal began
---@field private _done boolean
---@field private _fadeAlpha number
---@field private _fade RegistrationSceneFade? active black fade
---@field private _pendingFadeIn boolean
---@field private _flash integer white flash ticks left
---@field private _flashTotal integer white flash duration
---@field private _finalFade integer black fade ticks elapsed
---@field private _spotlights boolean
---@field private _confetti boolean
---@field private _confettiTick integer?
---@field private _confettiNext integer?
---@field private _confettiParticles table[]?
---@field private _scrolling boolean
---@field private _bgScrollX integer?
---@field private _twinkle { x: number, y: number }? sparkle placement
---@field private _twinkleClock integer?
---@field private _twinkleSeed integer
---@field private _wholeClock integer?
---@field private _outTimer integer?
---@field private _bg { x: number, y: number }[] background layer scrolls
---@field private _spr { front: { x: number, y: number }, frontShadow: { x: number, y: number }, back: { x: number, y: number }, backShadow: { x: number, y: number }, ow: { x: number, y: number }, owShadow: { x: number, y: number } } sprite placements
---@field private _frontScale number?
---@field private _shadowScale number?
local RegistrationScene = {}
RegistrationScene.__index = RegistrationScene

-- One back-picture hold alone is 50 ticks; the whole reveal below is the
-- source per-member total, not an aggregate approximation.
RegistrationScene.INDIV_STAGES = {
  { name = "fly_in_back", ticks = 11 },
  { name = "back_cry", ticks = 1 },
  { name = "hold_back", ticks = 51 },
  { name = "fly_in_ow", ticks = 7 },
  { name = "anim_ow", ticks = 1 },
  { name = "hold_ow", ticks = 21 },
  { name = "show_header", ticks = 1 },
  { name = "hold_header", ticks = 61 },
  { name = "fly_in_front", ticks = 9 },
  { name = "silhouette", ticks = 1 },
  { name = "hold_front", ticks = 41 },
  { name = "print_species", ticks = 1 },
  { name = "hold_species", ticks = 21 },
  { name = "print_caught", ticks = 1 },
  { name = "hold_caught", ticks = 241 },
  { name = "fly_out", ticks = 11 },
  { name = "tail_delay", ticks = 61 },
}

RegistrationScene.WHOLE_STAGES = {
  { name = "initial_delay", ticks = 21 },
  { name = "fly_in_mons", ticks = 42 },
  { name = "delay_after_fly_in", ticks = 33 },
  { name = "request_flash", ticks = 1 },
  { name = "animate_shadows", ticks = 81 },
  { name = "wait_button", ticks = nil },
  -- The second flash runs its timer to 30 (requesting the fade to
  -- black), then the final fade-out continues the same 60-frame fly-out
  -- from timer 30 to 60: 31 ticks each.
  { name = "second_flash", ticks = 31 },
  { name = "wait_final_fadeout", ticks = 31 },
}

-- sPicPosScaleAnimParams (register_hall_of_fame.c): fly-in starts/ends for
-- the six whole-party slots, shadow fly-ins, and the fly-out paths.
RegistrationScene.PIC_POS_SCALE_PARAMS = {
  { xStart = 168, yStart = -40, xEnd = 96, yEnd = 120, scaleStart = 1.0, scaleEnd = 1.0 },
  { xStart = -92, yStart = 88, xEnd = 160, yEnd = 120, scaleStart = 1.0, scaleEnd = 1.0 },
  { xStart = 348, yStart = 88, xEnd = 56, yEnd = 104, scaleStart = 1.0, scaleEnd = 1.0 },
  { xStart = 88, yStart = -40, xEnd = 200, yEnd = 104, scaleStart = 1.0, scaleEnd = 1.0 },
  { xStart = 336, yStart = 0, xEnd = 40, yEnd = 80, scaleStart = 1.0, scaleEnd = 1.0 },
  { xStart = -80, yStart = 0, xEnd = 216, yEnd = 80, scaleStart = 1.0, scaleEnd = 1.0 },
  { xStart = 93, yStart = 110, xEnd = 99, yEnd = 110, scaleStart = 1.0, scaleEnd = 1.0 },
  { xStart = 157, yStart = 110, xEnd = 163, yEnd = 110, scaleStart = 1.0, scaleEnd = 1.0 },
  { xStart = 53, yStart = 96, xEnd = 59, yEnd = 96, scaleStart = 1.0, scaleEnd = 1.0 },
  { xStart = 197, yStart = 96, xEnd = 203, yEnd = 96, scaleStart = 1.0, scaleEnd = 1.0 },
  { xStart = 37, yStart = 72, xEnd = 43, yEnd = 72, scaleStart = 1.0, scaleEnd = 1.0 },
  { xStart = 213, yStart = 72, xEnd = 219, yEnd = 72, scaleStart = 1.0, scaleEnd = 1.0 },
  { xStart = 125, yStart = 120, xEnd = 131, yEnd = 120, scaleStart = 1.0, scaleEnd = 1.0 },
  { xStart = 96, yStart = 120, xEnd = 108, yEnd = 100, scaleStart = 1.0, scaleEnd = 0.8 },
  { xStart = 160, yStart = 120, xEnd = 148, yEnd = 100, scaleStart = 1.0, scaleEnd = 0.8 },
  { xStart = 56, yStart = 104, xEnd = 84, yEnd = 90, scaleStart = 1.0, scaleEnd = 0.75 },
  { xStart = 200, yStart = 104, xEnd = 170, yEnd = 90, scaleStart = 1.0, scaleEnd = 0.75 },
  { xStart = 40, yStart = 80, xEnd = 64, yEnd = 75, scaleStart = 1.0, scaleEnd = 0.7 },
  { xStart = 216, yStart = 80, xEnd = 190, yEnd = 75, scaleStart = 1.0, scaleEnd = 0.7 },
  { xStart = 128, yStart = 128, xEnd = 128, yEnd = 120, scaleStart = 1.0, scaleEnd = 0.7 },
  { xStart = 96, yStart = 90, xEnd = 108, yEnd = 100, scaleStart = 1.0, scaleEnd = 0.9 },
  { xStart = 160, yStart = 90, xEnd = 148, yEnd = 100, scaleStart = 1.0, scaleEnd = 0.9 },
  { xStart = 56, yStart = 80, xEnd = 84, yEnd = 90, scaleStart = 1.0, scaleEnd = 0.8 },
  { xStart = 200, yStart = 80, xEnd = 170, yEnd = 90, scaleStart = 1.0, scaleEnd = 0.8 },
  { xStart = 40, yStart = 60, xEnd = 64, yEnd = 75, scaleStart = 1.0, scaleEnd = 0.75 },
  { xStart = 216, yStart = 60, xEnd = 190, yEnd = 75, scaleStart = 1.0, scaleEnd = 0.75 },
  { xStart = 128, yStart = 100, xEnd = 128, yEnd = 120, scaleStart = 1.0, scaleEnd = 0.8 },
}

-- The source's own whole-party flash/fade frame counts.
RegistrationScene.FIRST_FLASH_FADE = 40
RegistrationScene.REFLASH_FADE = 15
RegistrationScene.FINAL_FADE = 15

---@return boolean
function RegistrationScene:isDone()
  return self._done == true
end

-- Queues one cry for the owner to play exactly once.
---@param species string
---@param form integer
function RegistrationScene:_queueCry(species, form)
  self._cues[#self._cues + 1] = { kind = "cry", species = species, form = form }
end

-- Queues one sound effect for the owner to play exactly once.
---@param name string
function RegistrationScene:_queueSound(name)
  self._cues[#self._cues + 1] = { kind = "sound", name = name }
end

-- Takes and clears the cues collected since the last take.
---@return table[] cues
function RegistrationScene:takeCues()
  local cues = self._cues
  self._cues = {}
  return cues
end

-- The static fallback script for compositions without bundle tracks
-- (test-only): one frame, then done.
local STATIC_STEPS = {
  { next = 0, duration = 1, xOffset = 0 },
  { next = -1, duration = 0, xOffset = 0 },
  { next = -1, duration = 0, xOffset = 0 },
  { next = -1, duration = 0, xOffset = 0 },
  { next = -1, duration = 0, xOffset = 0 },
  { next = -1, duration = 0, xOffset = 0 },
  { next = -1, duration = 0, xOffset = 0 },
  { next = -1, duration = 0, xOffset = 0 },
  { next = -1, duration = 0, xOffset = 0 },
  { next = -1, duration = 0, xOffset = 0 },
}

---@param tracks table<string, unknown>|nil bundle picture tracks by species key
---@param species string
---@param facing string "front" | "back"
---@return integer cry delay ticks
local function trackCryDelay(tracks, species, facing)
  if type(tracks) ~= "table" then
    return 0
  end
  local entry = tracks[species]
  if type(entry) ~= "table" then
    return 0
  end
  local side = entry[facing]
  if type(side) ~= "table" then
    return 0
  end
  return math.floor(tonumber(side.cryDelay) or 0)
end

---@param tracks table<string, unknown>|nil bundle picture tracks by species key
---@param species string
---@param facing string "front" | "back"
---@return table[] ten animation steps
local function trackSteps(tracks, species, facing)
  if type(tracks) ~= "table" then
    return STATIC_STEPS
  end
  local entry = tracks[species]
  if type(entry) ~= "table" then
    return STATIC_STEPS
  end
  local side = entry[facing]
  if type(side) ~= "table" or type(side.steps) ~= "table" or #side.steps ~= 10 then
    return STATIC_STEPS
  end
  return side.steps
end

---@param tracks table<string, unknown>|nil bundle picture tracks by species key
---@param species string
---@param form integer
---@param gender string
---@return integer picture height
local function trackHeight(tracks, species, form, gender)
  if type(tracks) ~= "table" then
    return 40
  end
  local entry = tracks[species]
  if type(entry) ~= "table" or type(entry.heights) ~= "table" then
    return 40
  end
  local byForm = entry.heights[form] or entry.heights[0]
  if type(byForm) ~= "table" then
    return 40
  end
  return math.floor(tonumber(byForm[gender]) or 40)
end

-- Resolves one recorded member's scene facts from the bundle tracks.
---@param self RegistrationScene
---@param mon table<string, unknown>
---@return RegistrationSceneMember resolved member
function RegistrationScene:_resolveMember(mon)
  local tracks = self._tracks
  local species = assert(mon.species, "a recorded member names its species")
  local form = math.floor(tonumber(mon.form) or 0)
  local gender = mon.gender == "female" and "female" or "male"
  return {
    species = species,
    crySpecies = mon.crySpecies,
    form = form,
    gender = gender,
    owLarge = mon.owLarge == true,
    cryDelayBack = trackCryDelay(tracks, species, "back"),
    cryDelayFront = trackCryDelay(tracks, species, "front"),
    height = trackHeight(tracks, species, form, gender),
    backSteps = trackSteps(tracks, species, "back"),
    frontSteps = trackSteps(tracks, species, "front"),
  }
end

---@param self RegistrationScene
---@return integer picture top offset for the back picture
function RegistrationScene:_yOffset()
  local mon = self._members[self._monIndex + 1]
  if mon == nil then
    return 8
  end
  return (mon.height or 32) + 8
end

-- Interpolates one sprite's position/scale exactly like
-- MonSpritePosScaleAnimStep: step 0 snaps to the start, the terminal step
-- snaps to the end, intermediate steps lerp with the source's fixed-point
-- rounding.
---@param index integer 1-based position table entry
---@return table<string, number> source position/scale parameters
local function animParam(index)
  local param = RegistrationScene.PIC_POS_SCALE_PARAMS[index]
  assert(type(param) == "table", "a whole-party animation names its source parameters")
  return param
end

---@param param table<string, number>
---@param duration integer
---@param step integer
---@return number x, number y, number scale
local function posScaleStep(param, duration, step)
  if step == 0 then
    return param.xStart, param.yStart, param.scaleStart
  elseif step == duration then
    return param.xEnd, param.yEnd, param.scaleEnd
  end
  local function axis(startValue, endValue)
    local distance = math.abs(startValue - endValue)
    local delta = math.floor((distance * 256 / duration) * step / 256)
    if startValue > endValue then
      return startValue - delta
    else
      return startValue + delta
    end
  end
  local scale = param.scaleStart + (param.scaleEnd - param.scaleStart) / duration * step
  return axis(param.xStart, param.xEnd), axis(param.yStart, param.yEnd), scale
end

-- Whether the tick's input is the source terminal acknowledgment (A/B/touch,
-- never START): the field forwards the raw cancel edge and its modal
-- pointer batch while the ending owns the input lifetime.
---@param input table<string, unknown>|nil
---@return boolean
local function terminalAck(input)
  if input == nil then
    return false
  end
  if input.actionPressed == true or input.cancelPressed == true then
    return true
  end
  if type(input.uiEvents) == "table" then
    for _, event in ipairs(input.uiEvents) do
      if type(event) == "table" and event.type == "pointer_down" then
        return true
      end
    end
  end
  return false
end

-- Advances the black fade overlay one tick.
---@param self RegistrationScene
function RegistrationScene:_fadeStep()
  local fade = self._fade
  if fade == nil then
    return
  end
  fade.remaining = fade.remaining - 1
  if fade.remaining <= 0 then
    if fade.mode == "in" then
      self._fadeAlpha = 0
    else
      self._fadeAlpha = 1
    end
    self._fade = nil
    if self._pendingFadeIn then
      self._pendingFadeIn = false
      self._fade = { mode = "in", remaining = 6, total = 6 }
    end
    return
  end
  if fade.mode == "in" then
    self._fadeAlpha = fade.remaining / fade.total
  else
    self._fadeAlpha = 1 - fade.remaining / fade.total
  end
end

-- Fires due scheduled cries.
---@param self RegistrationScene
function RegistrationScene:_cryStep()
  local due = {}
  local pending = {}
  for _, request in ipairs(self._cryAt) do
    if self._tick >= request.tick then
      due[#due + 1] = request
    else
      pending[#pending + 1] = request
    end
  end
  self._cryAt = pending
  for _, request in ipairs(due) do
    self:_queueCry(request.species, request.form)
  end
end

-- Advances started picture animations one tick.
---@param self RegistrationScene
function RegistrationScene:_animStep()
  for _, anim in pairs(self._anims) do
    anim:update()
  end
end

-- Schedules one cry delay ticks after the current tick.
---@param self RegistrationScene
---@param member RegistrationSceneMember resolved scene member
---@param delay integer
function RegistrationScene:_scheduleCry(member, delay)
  self._cryAt[#self._cryAt + 1] = {
    tick = self._tick + 1 + delay,
    species = member.crySpecies ~= nil and member.crySpecies or member.species,
    form = member.form,
  }
end

---@param self RegistrationScene
---@return RegistrationSceneMember resolved current member
function RegistrationScene:_currentMember()
  return assert(self._members[self._monIndex + 1], "an individual reveal names its member")
end

-- Resets sprite/background positions for one member's reveal, exactly like
-- the source reset case: sides mirror left/right, the overworld sprite
-- starts offscreen, both pictures start scaled (front 1.0, shadow 1.5).
---@param self RegistrationScene
function RegistrationScene:_resetIndivPositions()
  local y = self:_yOffset()
  local left = self._side == "left"
  if left then
    self._bg = { { x = 0, y = 0 }, { x = 0, y = 0 }, { x = 0, y = 0 }, { x = 0, y = 0 } }
    self._spr = {
      front = { x = 256, y = -40 },
      frontShadow = { x = 296, y = -80 },
      back = { x = 288, y = y },
      backShadow = { x = 296, y = y },
      ow = { x = -82, y = -2 },
      owShadow = { x = -89, y = -3 },
    }
  else
    self._bg = { { x = 0, y = 0 }, { x = 0, y = 256 }, { x = -184, y = 0 }, { x = 256, y = 0 } }
    self._spr = {
      front = { x = 0, y = -40 },
      frontShadow = { x = -40, y = -80 },
      back = { x = -80, y = y },
      backShadow = { x = -92, y = y },
      ow = { x = 338, y = -2 },
      owShadow = { x = 345, y = -3 },
    }
  end
  self._frontScale = 1.0
  self._shadowScale = 1.5
end

-- Enters one individual stage: resets its timer and runs the stage's entry
-- effects (cry scheduling and picture animation starts; the follower is a
-- static portrait stand-in with no animation clock).
---@param self RegistrationScene
---@param stageIdx integer
function RegistrationScene:_enterIndivStage(stageIdx)
  self._stage = stageIdx
  self._timer = 0
  local name = RegistrationScene.INDIV_STAGES[stageIdx].name
  if stageIdx == 1 then
    self:_resetIndivPositions()
  end
  local mon = self:_currentMember()
  if name == "back_cry" then
    self:_scheduleCry(mon, mon.cryDelayBack)
    self._anims.back = PokepicAnim.new(mon.backSteps)
  elseif name == "print_species" then
    self:_scheduleCry(mon, mon.cryDelayFront)
    self._anims.front = PokepicAnim.new(mon.frontSteps)
  end
end

-- Advances one individual-scene tick. Positions and scrolls integrate
-- exactly like the source per-tick offsets; end-of-stage snaps apply on
-- the terminal tick before the handover. Returns true once the whole
-- individual run completed into the whole party.
---@param self RegistrationScene
---@return boolean handedOver
function RegistrationScene:_indivStep()
  self._timer = self._timer + 1
  local stage = RegistrationScene.INDIV_STAGES[self._stage]
  local name = stage.name
  local left = self._side == "left"
  local y = self:_yOffset()
  local spr = self._spr
  local bg = self._bg
  local adj = { x = -16, y = -16 }
  local mon = self:_currentMember()
  if mon.owLarge then
    adj = { x = -32, y = -32 }
  end
  local terminal = self._timer >= stage.ticks
  if name == "fly_in_back" then
    if terminal then
      bg[2].x, bg[3].x = left and -72 or 72, left and 72 or -256
      spr.back.x, spr.back.y = left and 48 or 160, y
      spr.backShadow.x, spr.backShadow.y = left and 46 or 158, y
    elseif left then
      bg[2].x = bg[2].x - 7
      bg[3].x = bg[3].x + 7
      spr.back.x = spr.back.x - 24
      spr.backShadow.x = spr.backShadow.x - 25
    else
      bg[2].x = bg[2].x + 7
      bg[3].x = bg[3].x - 7
      spr.back.x = spr.back.x + 24
      spr.backShadow.x = spr.backShadow.x + 25
    end
  elseif name == "fly_in_ow" then
    if terminal then
      if left then
        spr.ow.x, spr.ow.y = 32 + adj.x, 40 + adj.y
        spr.owShadow.x, spr.owShadow.y = 31 + adj.x, 39 + adj.y
      else
        spr.ow.x, spr.ow.y = 224 + adj.x, 40 + adj.y
        spr.owShadow.x, spr.owShadow.y = 225 + adj.x, 39 + adj.y
      end
    elseif left then
      spr.ow.x, spr.ow.y = spr.ow.x + 19, spr.ow.y + 7
      spr.owShadow.x, spr.owShadow.y = spr.owShadow.x + 20, spr.owShadow.y + 7
    else
      spr.ow.x, spr.ow.y = spr.ow.x - 19, spr.ow.y + 7
      spr.owShadow.x, spr.owShadow.y = spr.owShadow.x - 20, spr.owShadow.y + 7
    end
  elseif name == "hold_header" and terminal then
    if left then
      bg[3].x, bg[3].y = -16, 256
    else
      bg[3].x, bg[3].y = 272, 256
    end
  elseif name == "fly_in_front" then
    if terminal then
      bg[3].x, bg[3].y = left and 112 or 144, 192
      bg[4].y = 256
      spr.front.x, spr.front.y = left and 88 or 168, 88
      spr.frontShadow.x, spr.frontShadow.y = left and 104 or 152, 72
    elseif left then
      bg[3].x, bg[3].y = bg[3].x + 16, bg[3].y - 8
      spr.front.x, spr.front.y = spr.front.x - 21, spr.front.y + 16
      spr.frontShadow.x, spr.frontShadow.y = spr.frontShadow.x - 24, spr.frontShadow.y + 19
    else
      bg[3].x, bg[3].y = bg[3].x - 16, bg[3].y - 8
      spr.front.x, spr.front.y = spr.front.x + 21, spr.front.y + 16
      spr.frontShadow.x, spr.frontShadow.y = spr.frontShadow.x + 24, spr.frontShadow.y + 19
    end
  elseif name == "hold_caught" and terminal then
    bg[3].x, bg[3].y = left and 72 or -256, 0
    self._frontScale = 1.0
    self._shadowScale = 1.5
  elseif name == "fly_out" then
    if terminal then
      if left then
        bg[1].x, bg[1].y = -80, -200
        bg[2].x = 0
        bg[3].x = 0
        bg[4].x, bg[4].y = 60, 226
      else
        bg[1].x, bg[1].y = 80, -200
        bg[2].x = 0
        bg[3].x = -184
        bg[4].x, bg[4].y = 196, 226
      end
      spr.back.x, spr.back.y = left and 148 or 260, 252
      spr.backShadow.x, spr.backShadow.y = left and 64 or 192, 192
      spr.ow.x, spr.ow.y = left and -28 or 164, -30
      spr.owShadow.x, spr.owShadow.y = left and -29 or 165, -31
      spr.front.x, spr.front.y = left and 48 or 208, 128
      spr.frontShadow.x, spr.frontShadow.y = left and 64 or 192, 112
      self._frontScale = 1.8
      self._shadowScale = 2.0
    else
      local dx = left and -8 or 8
      bg[1].x, bg[1].y = bg[1].x + dx, bg[1].y + 20
      bg[2].x = bg[2].x + (left and 7 or -7)
      bg[3].x = bg[3].x + (left and -7 or 7)
      bg[4].x, bg[4].y = bg[4].x + (left and 6 or -6), bg[4].y - 3
      spr.back.x, spr.back.y = spr.back.x + (left and 10 or -10), spr.back.y + 10
      spr.backShadow.x, spr.backShadow.y = spr.backShadow.x + (left and 10 or -10), spr.backShadow.y + 10
      spr.ow.x, spr.ow.y = spr.ow.x + (left and -6 or 6), spr.ow.y - 7
      spr.owShadow.x, spr.owShadow.y = spr.owShadow.x + (left and -6 or 6), spr.owShadow.y - 7
      spr.front.x, spr.front.y = spr.front.x + (left and -4 or 4), spr.front.y + 4
      spr.frontShadow.x, spr.frontShadow.y = spr.frontShadow.x + (left and -4 or 4), spr.frontShadow.y + 4
      self._frontScale = (self._frontScale or 1.0) + 0.08
      self._shadowScale = (self._shadowScale or 1.5) + 0.05
    end
  end
  if not terminal then
    return false
  end
  if self._stage < #RegistrationScene.INDIV_STAGES then
    self:_enterIndivStage(self._stage + 1)
    return false
  end
  -- The reveal chain ends: delete-on-exit is draw's snapshot reset, the
  -- next member starts on the reset stage, the last hands to the whole.
  self._anims = {}
  self._monIndex = self._monIndex + 1
  if self._monIndex >= #self._members then
    self._phase = "whole"
    self._stage = 1
    self._timer = 0
    self._fadeAlpha = 0
    self._fade = { mode = "out", remaining = 6, total = 6 }
    self._pendingFadeIn = true
    return true
  end
  self._side = self._monIndex % 2 == 0 and "left" or "right"
  self:_enterIndivStage(1)
  return false
end

-- Advances one whole-party tick. Photo flashes queue their sound cues and
-- start their white envelopes; the terminal wait answers A/B/touch only.
---@param self RegistrationScene
---@param input table<string, unknown>|nil
function RegistrationScene:_wholeStep(input)
  local stage = RegistrationScene.WHOLE_STAGES[self._stage]
  if stage.name == "wait_button" then
    if terminalAck(input) then
      self:_queueSound("SEQ_SE_GS_DENDOUIRI_FLASH")
      self:_queueSound("SEQ_SE_GS_DENDOUIRI_KANSEI")
      self._flash = RegistrationScene.REFLASH_FADE
      self._flashTotal = RegistrationScene.REFLASH_FADE
      self._outTimer = 0
      self._stage = self._stage + 1
      self._timer = 0
    end
    return
  end
  self._timer = self._timer + 1
  if stage.name == "second_flash" or stage.name == "wait_final_fadeout" then
    self._outTimer = (self._outTimer or 0) + 1
  end
  if stage.name == "request_flash" then
    -- Single-tick stage: the flash, kansei, spotlights, confetti, scroll
    -- and twinkle all start together, exactly like the source request.
    self:_queueSound("SEQ_SE_GS_DENDOUIRI_FLASH")
    self:_queueSound("SEQ_SE_GS_DENDOUIRI_KANSEI")
    self._flash = RegistrationScene.FIRST_FLASH_FADE
    self._flashTotal = RegistrationScene.FIRST_FLASH_FADE
    self._spotlights = true
    self._confetti = true
    self._scrolling = true
    self._twinkle = { x = 128, y = 96 }
    self._twinkleClock = 0
  elseif stage.name == "second_flash" and self._timer == 30 then
    self._finalFade = 1
  end
  if self._finalFade > 0 and self._finalFade < 15 then
    self._finalFade = self._finalFade + 1
  end
  if self._timer >= (stage.ticks or 0) then
    if self._stage >= #RegistrationScene.WHOLE_STAGES then
      self._done = true
      self._spotlights = false
      self._confetti = false
      self._scrolling = false
      return
    end
    self._stage = self._stage + 1
    self._timer = 0
  end
end

-- Advances the white photo-flash envelope one tick.
---@param self RegistrationScene
function RegistrationScene:_flashStep()
  if self._flash > 0 then
    self._flash = self._flash - 1
  end
end

-- Deterministic twinkle/confetti drive: a tiny LCG over a fixed seed, so
-- the sparkle cadence is stable without touching the world stream.
---@param self RegistrationScene
---@return integer 0..2^31-1
function RegistrationScene:_nextTwinkle()
  self._twinkleSeed = (self._twinkleSeed * 1103515245 + 12345) % 2147483648
  return self._twinkleSeed
end

---@param options { party: table<string, unknown>[], tracks: table<string, unknown>|nil }
---  recorded non-egg members in party order with bundle picture tracks
---@return RegistrationScene
function RegistrationScene.new(options)
  assert(type(options) == "table", "the registration scene needs its recorded party")
  local party = assert(options.party, "the registration scene needs its recorded party")
  assert(type(party) == "table", "the registration scene needs its recorded party")
  local self = setmetatable({
    _party = party,
    _tracks = options.tracks,
    _members = {},
    _phase = #party == 0 and "whole" or "indiv",
    _monIndex = 0,
    _stage = 1,
    _timer = 0,
    _side = "left",
    _anims = {},
    _cryAt = {},
    _cues = {},
    _tick = 0,
    _done = false,
    _fadeAlpha = #party == 0 and 0 or 1,
    _fade = #party == 0 and nil or { mode = "in", remaining = 6, total = 6 },
    _pendingFadeIn = false,
    _flash = 0,
    _flashTotal = 0,
    _finalFade = 0,
    _spotlights = false,
    _confetti = false,
    _scrolling = false,
    _twinkleSeed = 1,
    _twinkle = nil,
  }, RegistrationScene)
  for _, mon in ipairs(party) do
    assert(type(mon) == "table", "a recorded member is a record")
    assert(type(mon.species) == "string", "a recorded member names its species")
    self._members[#self._members + 1] = self:_resolveMember(mon)
  end
  self:_resetIndivPositions()
  if #party > 0 then
    self._side = "left"
    self:_enterIndivStage(1)
  end
  return self
end
-- One fixed tick of the registration application.
---@param input table<string, unknown>|nil the tick's field input snapshot
function RegistrationScene:step(input)
  if self._done then
    return
  end
  self._tick = self._tick + 1
  self:_fadeStep()
  self:_flashStep()
  self:_cryStep()
  self:_animStep()
  if self._twinkleClock ~= nil then
    self._twinkleClock = self._twinkleClock + 1
  end
  if self._phase == "indiv" then
    self:_indivStep()
  else
    if self._wholeClock == nil then
      self._wholeClock = 0
    else
      self._wholeClock = self._wholeClock + 1
    end
    self:_wholeStep(input)
  end
  -- The twinkle sparkle repositions on a source-like cadence while the
  -- whole-party effects run; confetti drifts down while generated.
  if self._confetti then
    self._confettiTick = (self._confettiTick or 0) + 1
    if self._confettiTick >= (self._confettiNext or 28) then
      self._confettiTick = 0
      self._confettiNext = 28 + self:_nextTwinkle() % 256
      self._twinkle = { x = 16 + self:_nextTwinkle() % 224, y = 16 + self:_nextTwinkle() % 64 }
      self._twinkleClock = 0
    end
    local particles = self._confettiParticles or {}
    self._confettiParticles = particles
    if #particles < 48 and self._tick % 4 == 0 then
      particles[#particles + 1] = { x = self:_nextTwinkle() % 256, y = -8, spin = 0 }
    end
    local kept = {}
    for _, particle in ipairs(particles) do
      particle.y = particle.y + 2
      particle.spin = particle.spin + 1
      if particle.y < 200 then
        kept[#kept + 1] = particle
      end
    end
    self._confettiParticles = kept
  end
  -- The polka-dot background scrolls while the whole-party effects run.
  if self._scrolling then
    self._bgScrollX = (self._bgScrollX or 0) - 2
  end
end

-- Background layer scrolls for the current tick, in layer order. Whole-party
-- draws its two layers (the polka-dot layer scrolls); individual scenes
-- draw their three screen layers over the text layer.
---@param self RegistrationScene
---@return table[] {key, x, y} in draw order
function RegistrationScene:_bgScroll()
  if self._phase == "whole" then
    return {
      { key = "bgWhole1", x = self._bgScrollX or 0, y = 0 },
      { key = "bgWhole2", x = 0, y = 0 },
    }
  end
  local bg = self._bg or { { x = 0, y = 0 }, { x = 0, y = 0 }, { x = 0, y = 0 }, { x = 0, y = 0 } }
  return {
    { key = nil, x = 0, y = 0 },
    { key = "bgIndiv1", x = bg[2].x, y = bg[2].y },
    { key = "bgIndiv2", x = bg[3].x, y = bg[3].y },
    { key = "bgIndiv3", x = bg[4].x, y = bg[4].y },
  }
end

-- One sprite entry for draw resolution.
---@param kind string
---@param x number
---@param y number
---@param opts table<string, unknown>?
---@return RegistrationSceneSprite
local function sprite(kind, x, y, opts)
  opts = opts or {}
  return {
    kind = kind,
    slot = opts.slot,
    x = x,
    y = y,
    scale = opts.scale or 1.0,
    frame = opts.frame or 0,
    palette = opts.palette or "normal",
    visible = opts.visible ~= false,
    alpha = opts.alpha or 1.0,
  }
end

-- Sprite snapshot for the current tick: individual pics/overworld sprite
-- and shadows with source silhouette palettes, or the whole-party group
-- with its shadows, player, and twinkle placements.
---@param self RegistrationScene
---@param backFrame integer
---@param frontFrame integer
---@return table[] sprites in draw order (shadows before pics)
function RegistrationScene:_sprites(backFrame, frontFrame)
  if self._phase == "whole" then
    return self:_wholeSprites()
  end
  local spr = self._spr
  if spr == nil then
    return {}
  end
  local silhouetted = self._stage >= 10
  local list = {}
  list[#list + 1] = sprite("backShadow", spr.backShadow.x, spr.backShadow.y, {
    frame = 0,
    palette = silhouetted and "red" or "black",
  })
  list[#list + 1] = sprite("back", spr.back.x, spr.back.y, {
    frame = backFrame,
    palette = silhouetted and "black" or "normal",
  })
  list[#list + 1] = sprite("owShadow", spr.owShadow.x, spr.owShadow.y, {
    frame = 0,
    palette = silhouetted and "red" or "black",
  })
  list[#list + 1] = sprite("ow", spr.ow.x, spr.ow.y, {
    frame = 0,
    palette = silhouetted and "black" or "normal",
  })
  list[#list + 1] = sprite("frontShadow", spr.frontShadow.x, spr.frontShadow.y, {
    frame = 0,
    palette = "black",
    scale = self._shadowScale or 1.5,
  })
  list[#list + 1] = sprite("front", spr.front.x, spr.front.y, {
    frame = frontFrame,
    scale = self._frontScale or 1.0,
  })
  return list
end

-- Whole-party placements for the current tick: the six slots fly in one
-- at a time, shadows fly in during the shadow animation, and the group
-- photo pose animates through the two flashes.
---@param self RegistrationScene
---@return table[] sprites in draw order (shadows before pics)
function RegistrationScene:_wholeSprites()
  local list = {}
  local numMons = #self._members
  local function addShadow(kind, slot, x, y, scale, visible)
    list[#list + 1] = sprite(kind, x, y, {
      slot = slot,
      scale = scale,
      palette = "white",
      alpha = 0.5,
      visible = visible,
    })
  end
  if self._stage == 2 then
    local curSlot = math.min(math.floor((self._timer - 1) / 7), 5)
    local stepInSlot = (self._timer - 1) % 7
    for i = 0, 5 do
      if i < numMons then
        local x, y, scale
        if i < curSlot then
          x, y, scale = posScaleStep(animParam(i + 1), 6, 6)
        elseif i == curSlot then
          x, y, scale = posScaleStep(animParam(i + 1), 6, math.min(stepInSlot, 6))
        else
          x, y, scale = posScaleStep(animParam(i + 1), 6, 0)
        end
        list[#list + 1] = sprite("mon", x, y, { slot = i, scale = scale })
      end
    end
    return list
  end
  local flyingOut = self._stage >= 7
  local outTimer = math.min(self._outTimer or 0, 60)
  local photos = self._stage >= 4
  -- Shadows rest at their fly-in ends once shown, then ride the photo pose.
  local shadowShown = photos
  for i = 0, 5 do
    if i < numMons then
      local x, y, scale
      if self._stage == 5 then
        x, y, scale = posScaleStep(animParam(6 + i + 1), 80, math.min(self._timer, 80))
      elseif flyingOut then
        x, y, scale = posScaleStep(animParam(20 + i + 1), 60, outTimer)
      else
        x, y, scale = posScaleStep(animParam(6 + i + 1), 80, 80)
      end
      addShadow("monShadow", i, x, y, scale, shadowShown)
    end
  end
  for i = 0, 5 do
    if i < numMons then
      local x, y, scale
      if flyingOut then
        x, y, scale = posScaleStep(animParam(13 + i + 1), 60, outTimer)
      else
        x, y, scale = posScaleStep(animParam(i + 1), 6, 6)
      end
      list[#list + 1] = sprite("mon", x, y, {
        slot = i,
        scale = scale,
        palette = photos and "normal" or "white",
      })
    end
  end
  if photos then
    local px, py, pscale = 128, 128, 1.0
    local sx, sy, sscale = 125, 120, 1.0
    if self._stage == 5 then
      sx, sy, sscale = posScaleStep(animParam(12 + 1), 80, math.min(self._timer, 80))
    elseif flyingOut then
      px, py, pscale = posScaleStep(animParam(19 + 1), 60, outTimer)
      sx, sy, sscale = posScaleStep(animParam(26 + 1), 60, outTimer)
    end
    addShadow("playerShadow", nil, sx, sy, sscale, true)
    list[#list + 1] = sprite("player", px, py, { scale = pscale })
    if self._twinkle ~= nil then
      list[#list + 1] = sprite("twinkle", self._twinkle.x, self._twinkle.y, {})
    end
  end
  return list
end

-- Which indiv windows are visible: the header prints first, then nickname,
-- species/level, and the caught detail accumulate per reveal.
---@param self RegistrationScene
---@return RegistrationSceneWindows visible window names
function RegistrationScene:_windows()
  if self._phase ~= "indiv" then
    return { top = true, bottom = true }
  end
  return {
    header = self._stage >= 7,
    nickname = self._stage >= 10,
    species = self._stage >= 12,
    caught = self._stage >= 14,
  }
end
---@return table<string, unknown>
function RegistrationScene:status()
  local stageName
  if self._phase == "indiv" then
    stageName = RegistrationScene.INDIV_STAGES[self._stage].name
  else
    stageName = RegistrationScene.WHOLE_STAGES[self._stage].name
  end
  local backFrame = 0
  local frontFrame = 0
  if self._anims.back ~= nil then
    backFrame = self._anims.back.step
  end
  if self._anims.front ~= nil then
    frontFrame = self._anims.front.step
  end
  local mon = self._members[self._monIndex + 1]
  local twinkle = nil
  if self._twinkle ~= nil then
    twinkle = { x = self._twinkle.x, y = self._twinkle.y, clock = self._twinkleClock or 0 }
  end
  local status = {
    phase = self._phase,
    monIndex = self._monIndex,
    side = self._side,
    stage = stageName,
    timer = self._timer,
    tick = self._tick,
    done = self._done,
    photoWait = self._phase == "whole" and stageName == "wait_button",
    backFrame = backFrame,
    frontFrame = frontFrame,
    owLarge = mon ~= nil and mon.owLarge == true,
    wholeClock = self._wholeClock,
    outTimer = math.min(self._outTimer or 0, 60),
    fadeAlpha = self._fadeAlpha,
    flashAlpha = self._flashTotal > 0 and self._flash / self._flashTotal or 0,
    finalFadeAlpha = math.min(1, (self._finalFade or 0) / 15),
    spotlights = self._spotlights,
    confetti = self._confetti,
    scrolling = self._scrolling,
    twinkle = twinkle,
    confettiParticles = self._confettiParticles or {},
    bg = self:_bgScroll(),
    sprites = self:_sprites(backFrame, frontFrame),
    windows = self:_windows(),
  }
  return status
end

return RegistrationScene
