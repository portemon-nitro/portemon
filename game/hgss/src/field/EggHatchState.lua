-- The source egg-hatch application: one closed scene state machine over the
-- fixed tick. It presents the two screens the source overlay owns -- the
-- background, the egg and the reveal bars with their source shake tables, the
-- message window, the cry and the fanfare waits, and the nickname question --
-- and it answers the source yes/no the hatch task reads. Nothing here mutates
-- a mon, a statistic or a save: the field's Day Care owner committed the
-- hatched record before the scene started, and the task publishes the receipt
-- when the scene returns.
--
-- The scene is independent of rendering: frames, source waits and audio
-- effects advance on the fixed tick, while the renderer only reads snapshots.
-- Retail sources (tmp/refs/pokeheartgold): src/application/hatch_egg_app.c
-- (HatchEggApp_RunEggScene, HatchEggApp_RunManaphyEggScene, the shake patterns
-- and the yes/no menu) and src/application/hatch_egg_gfx.c
-- (sHatchEggShakeOffsetsX/Y, sHatchEggShakeScalesX/Y).

local PokemonCareInterface = require("libs.hgss.src.ui.PokemonCareInterface")

-- BeginNormalPaletteFade(6 steps, 1 frame per step): the source waits for the
-- palette fade to finish before the scene proper starts.
local FADE_FRAMES = 7
-- HatchEggApp_WaitBeforeShake's timer.
local BEFORE_SHAKE_FRAMES = 25
-- The egg burst keeps the reveal bars on screen for this long before they
-- slide away (HatchEggApp_HatchEgg sub-state 2).
local BURST_HOLD_FRAMES = 10
-- Bars slide one source step per frame and are off screen after 48 + 4 steps.
local BAR_SLIDE_STEP = 4
local BAR_SLIDE_LIMIT = 52
-- The reveal holds the hatched picture for 25 frames before the closing fade.
local REVEAL_HOLD_FRAMES = 25
-- The Manaphy scene's own effects at these frames (HatchEggApp_HatchManaphyEgg).
local MANAPHY_EFFECT_FRAMES = {
  [25] = "SEQ_SE_DP_W278",
  [80] = "SEQ_SE_DP_W080C",
  [142] = "SEQ_SE_DP_W361",
}
local MANAPHY_REVEAL_FRAMES = 160
-- sHatchEggShakeOffsetsX/Y and sHatchEggShakeScalesX/Y: pattern -> ten frames
-- of horizontal offset, vertical offset, and affine scale. 0xFF ends a source
-- pattern frame; 0 ends the scale.
local SHAKE_TABLE = {
  {
    offsetsX = { -1, 1, 1, -1, -1, 1, 1, -1, 0xFF, 0xFF },
    offsetsY = { 0, 0xFF, 0, 0, 0, 0, 0, 0, 0, 0 },
    scalesX = { 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 },
    scalesY = { 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 },
  },
  {
    offsetsX = { -2, 2, 2, -2, -2, 2, 2, -2, 0xFF, 0xFF },
    offsetsY = { 0, 0, 1, 1, 0, -1, -1, 0, 0, 0xFF },
    scalesX = { 1.0, 1.0, 1.1, 1.1, 1.1, 1.1, 1.1, 1.0, 1.0, 0.0 },
    scalesY = { 1.0, 1.0, 0.9, 0.9, 0.9, 0.9, 0.9, 1.0, 1.0, 0.0 },
  },
  {
    offsetsX = { -3, 3, 3, -3, -3, 3, 0xFF, 0xFF, 0, 0 },
    offsetsY = { 0, 0, 1, 1, 1, -1, -1, -1, 0, 0 },
    scalesX = { 1.0, 1.1, 1.1, 1.2, 1.2, 1.2, 1.1, 1.1, 1.0, 0.0 },
    scalesY = { 1.0, 1.0, 0.9, 0.8, 0.7, 0.7, 0.8, 0.9, 1.0, 1.0 },
  },
  {
    offsetsX = { -3, 3, 3, -3, -3, 3, 0xFF, 0xFF, 0, 0 },
    offsetsY = { 0, 0, 1, 1, 1, -1, -1, -1, 0, 0 },
    scalesX = { 1.0, 1.1, 1.1, 1.2, 1.2, 1.2, 1.1, 1.1, 1.0, 0.0 },
    scalesY = { 1.0, 1.0, 0.9, 0.8, 0.7, 0.7, 0.8, 0.9, 1.0, 1.0 },
  },
}
-- The source reports the shake hit on its seventh pattern frame.
local SHAKE_HIT_FRAME = 7
local SHAKE_FRAMES = 10

---@class EggHatchState.Line
---@field messageId integer source msg_0187 line index
---@field frames integer print frames the line needs

---@class EggHatchState
---@field private _variant string "egg"|"manaphy"
---@field private _audio table<string, unknown> source audio host
---@field private _species integer native species identity for the cry
---@field private _form integer form for the cry
---@field private _hatched EggHatchState.Line the hatch line
---@field private _question EggHatchState.Line the nickname question
---@field private _phase string
---@field private _frame integer
---@field private _eggFrame integer
---@field private _eggOffsetX integer
---@field private _eggOffsetY integer
---@field private _scaleX number
---@field private _scaleY number
---@field private _bars boolean
---@field private _barsOffset integer
---@field private _messageId integer?
---@field private _printRemaining integer
---@field private _questionShown boolean
---@field private _selection string
---@field private _wantToName boolean
---@field private _done boolean
---@field private _shakeFrame integer one-based frame of the active shake pattern
---@field private _burstDone boolean whether the egg burst already finished
---@field private _barSliding boolean whether the reveal bars are sliding away
---@field private _presentationReady boolean
---@field private _preparationError string?
---@field private _particles integer[] emitter ids the source emits on this frame
local EggHatchState = {}
EggHatchState.__index = EggHatchState

---@param opts { variant: string, species: integer, form: integer, audio: table<string, unknown>, hatched: EggHatchState.Line, question: EggHatchState.Line }
---@return EggHatchState
function EggHatchState.new(opts)
  assert(type(opts) == "table", "the hatch scene requires its options")
  assert(PokemonCareInterface.isHatchVariant(opts.variant), "the hatch scene requires its source variant")
  assert(type(opts.audio) == "table", "the hatch scene requires the source audio host")
  assert(type(opts.species) == "number", "the hatch scene requires the hatched species identity")
  assert(type(opts.form) == "number", "the hatch scene requires the hatched form")
  local hatched = assert(opts.hatched, "the hatch scene requires its hatch line")
  local question = assert(opts.question, "the hatch scene requires its nickname question")
  return setmetatable({
    _variant = opts.variant,
    _audio = opts.audio,
    _species = opts.species,
    _form = opts.form,
    _hatched = hatched,
    _question = question,
    _phase = PokemonCareInterface.HATCH_PHASES.FADE_IN,
    _frame = 0,
    _eggFrame = -1,
    _eggOffsetX = 0,
    _eggOffsetY = 0,
    _scaleX = 1,
    _scaleY = 1,
    _bars = true,
    _barsOffset = 0,
    _messageId = nil,
    _printRemaining = 0,
    _questionShown = false,
    _selection = "yes",
    _wantToName = false,
    _done = false,
    _shakeFrame = 1,
    _burstDone = false,
    _barSliding = false,
    _presentationReady = false,
    _preparationError = nil,
    _particles = {},
  }, EggHatchState)
end

---@param audio table<string, unknown>
---@param sound string
local function playSound(audio, sound)
  if type(audio.play) == "function" then
    audio:play(sound)
  end
end

---@param audio table<string, unknown>
---@param query { isCryFinished: fun(self: table<string, unknown>): boolean }|nil
---@return boolean
local function cryFinished(audio)
  local query = audio --[[@as { isCryFinished: fun(self: table): boolean }]]
  if type(query.isCryFinished) ~= "function" then
    return true
  end
  return query:isCryFinished() == true
end

---@param audio table<string, unknown>
---@return boolean
local function fanfareFinished(audio)
  local query = audio --[[@as { isFanfarePlaying: fun(self: table): boolean }]]
  if type(query.isFanfarePlaying) ~= "function" then
    return true
  end
  return query:isFanfarePlaying() ~= true
end

-- Marks the generated presentation bundle as ready for drawing, or records why
-- it is unusable. The scene keeps running either way: gameplay never waits for
-- a renderer.
---@param ready boolean
---@param failure string?
function EggHatchState:setPresentation(ready, failure)
  self._presentationReady = ready == true
  self._preparationError = failure
end

---@return string
function EggHatchState:phase()
  return self._phase
end

---@return boolean
function EggHatchState:isDone()
  return self._done
end

---@return table<string, unknown> immutable renderer input
function EggHatchState:snapshot()
  return {
    kind = PokemonCareInterface.KINDS.hatch,
    variant = self._variant,
    phase = self._phase,
    frame = self._frame,
    eggFrame = self._eggFrame,
    eggOffsetX = self._eggOffsetX,
    eggOffsetY = self._eggOffsetY,
    scaleX = self._scaleX,
    scaleY = self._scaleY,
    bars = self._bars,
    barsOffset = self._barsOffset,
    messageId = self._messageId,
    question = self._questionShown,
    selection = self._selection,
    done = self._done,
    presentationReady = self._presentationReady,
    preparationError = self._preparationError,
    particles = self._particles,
  }
end

-- The terminal source answer: whether the player asked to name the mon. Only
-- meaningful once the scene finished.
---@return PokemonCareHatchResult
function EggHatchState:result()
  assert(self._done, "the hatch scene answers after it finished")
  return PokemonCareInterface.assertHatchResult({
    kind = PokemonCareInterface.KINDS.hatch,
    wantToName = self._wantToName,
    done = true,
  })
end

-- One source frame of the active shake pattern. Returns "hit" on the pattern's
-- source hit frame, "running" while the pattern continues, and "ended" when the
-- current pattern finished.
---@param pattern integer one-based shake pattern
---@param frame integer one-based pattern frame
---@return string
function EggHatchState:_applyShakeFrame(pattern, frame)
  local row = assert(SHAKE_TABLE[pattern], "the shake pattern exists")
  if frame > SHAKE_FRAMES then
    -- The source advances past the tenth pattern frame and ends the pattern on
    -- the next call, whatever the last frame's end markers said.
    self._eggOffsetX = 0
    self._eggOffsetY = 0
    return "ended"
  end
  local offsetsX = row.offsetsX --[[@as integer[] ]]
  local offsetsY = row.offsetsY --[[@as integer[] ]]
  local scalesX = row.scalesX --[[@as number[] ]]
  local scalesY = row.scalesY --[[@as number[] ]]
  local offsetX = assert(offsetsX[frame], "the shake pattern names its frame")
  local offsetY = assert(offsetsY[frame], "the shake pattern names its frame")
  local scaleX = assert(scalesX[frame], "the shake pattern names its frame")
  local scaleY = assert(scalesY[frame], "the shake pattern names its frame")
  local finished = 0
  if offsetX == 0xFF then
    offsetX = 0
    finished = finished + 1
  end
  if offsetY == 0xFF then
    offsetY = 0
    finished = finished + 1
  end
  if scaleX == 0 then
    finished = finished + 1
  end
  if finished == 3 then
    self._eggOffsetX = 0
    self._eggOffsetY = 0
    return "ended"
  end
  self._eggOffsetX = offsetX
  self._eggOffsetY = offsetY
  if scaleX ~= 0 then
    self._scaleX = scaleX
    self._scaleY = scaleY
  end
  if frame == SHAKE_HIT_FRAME then
    return "hit"
  end
  return "running"
end

-- Begins the shared tail of both scenes: the hatched picture's cry, the fanfare
-- and the nickname question.
function EggHatchState:_beginCry()
  self._phase = PokemonCareInterface.HATCH_PHASES.WAIT_CRY
  self._frame = 0
  self._eggFrame = -1
  self._bars = false
  self._messageId = self._hatched.messageId
  self._printRemaining = self._hatched.frames
  local audio = self._audio
  if type(audio.playCry) == "function" then
    audio:playCry(self._species, 0, self._form)
  end
end

-- Advances the source frames of the ordinary egg scene.
function EggHatchState:_updateEggScene()
  local phase = self._phase
  if phase == PokemonCareInterface.HATCH_PHASES.WAIT_BEFORE_SHAKE then
    if self._frame == 0 then
      self._eggFrame = 0
    end
    if self._frame >= BEFORE_SHAKE_FRAMES then
      playSound(self._audio, "SEQ_SE_DP_EGG01")
      self._phase = PokemonCareInterface.HATCH_PHASES.SHAKE_ONCE
      self._frame = 0
      self._eggFrame = 1
      self._shakeFrame = 1
    end
    return
  end
  if phase == PokemonCareInterface.HATCH_PHASES.SHAKE_ONCE then
    local frame = assert(self._shakeFrame, "the shake pattern carries its frame")
    local outcome = self:_applyShakeFrame(1, frame)
    if outcome == "ended" then
      playSound(self._audio, "SEQ_SE_DP_EGG01")
      self._eggFrame = 2
      self._phase = PokemonCareInterface.HATCH_PHASES.SHAKE_TWICE
      self._shakeFrame = 1
      return
    end
    self._shakeFrame = frame + 1
    return
  end
  if phase == PokemonCareInterface.HATCH_PHASES.SHAKE_TWICE then
    local frame = assert(self._shakeFrame, "the shake pattern carries its frame")
    local outcome = self:_applyShakeFrame(2, frame)
    if outcome == "hit" then
      playSound(self._audio, "SEQ_SE_DP_EGG01")
      self._eggFrame = 3
      self._particles[#self._particles + 1] = 0
    end
    if outcome == "ended" then
      self._phase = PokemonCareInterface.HATCH_PHASES.SHAKE_CRACK
      self._shakeFrame = 1
      return
    end
    self._shakeFrame = frame + 1
    return
  end
  if phase == PokemonCareInterface.HATCH_PHASES.SHAKE_CRACK then
    local frame = assert(self._shakeFrame, "the shake pattern carries its frame")
    local outcome = self:_applyShakeFrame(3, frame)
    if outcome == "hit" then
      playSound(self._audio, "SEQ_SE_DP_EGG01")
      self._eggFrame = 4
      self._particles[#self._particles + 1] = 1
    end
    if outcome == "ended" then
      self._phase = PokemonCareInterface.HATCH_PHASES.HATCH
      self._frame = 0
      self._shakeFrame = 1
      self._burstDone = false
      return
    end
    self._shakeFrame = frame + 1
    return
  end
  if phase == PokemonCareInterface.HATCH_PHASES.HATCH then
    if self._burstDone ~= true then
      local frame = assert(self._shakeFrame, "the shake pattern carries its frame")
      local outcome = self:_applyShakeFrame(4, frame)
      if outcome == "hit" then
        self._eggFrame = 5
        playSound(self._audio, "SEQ_SE_DP_BOWA3")
        self._particles[#self._particles + 1] = 2
        self._particles[#self._particles + 1] = 3
      end
      if outcome == "ended" then
        self._eggFrame = -1
        self._burstDone = true
        self._frame = 0
      else
        self._shakeFrame = frame + 1
        return
      end
    end
    self:_updateReveal()
  end
end

-- Advances the source frames of the Ranger Manaphy scene: no egg shakes, its
-- own three effects, and its own reveal timing.
function EggHatchState:_updateManaphyScene()
  if self._phase == PokemonCareInterface.HATCH_PHASES.HATCH then
    if self._barSliding == true then
      self:_updateReveal()
      return
    end
    local frame = self._frame
    local sound = MANAPHY_EFFECT_FRAMES[frame]
    if sound ~= nil then
      playSound(self._audio, sound)
    end
    if frame == 1 then
      -- HatchEggApp_HatchManaphyEgg emits its four emitters before the reveal
      -- timer starts.
      self._particles[#self._particles + 1] = 0
      self._particles[#self._particles + 1] = 1
      self._particles[#self._particles + 1] = 2
      self._particles[#self._particles + 1] = 3
    end
    if frame >= MANAPHY_REVEAL_FRAMES then
      self._eggFrame = -1
      self._frame = 0
      self._barSliding = true
      self:_updateReveal()
      return
    end
    return
  end
  if self._phase == PokemonCareInterface.HATCH_PHASES.FADE_IN then
    -- The Manaphy scene hides the egg and bursts straight into the particles.
    self._eggFrame = -1
  end
end

-- The shared reveal: the bars slide off screen, the hatched picture holds for
-- its source frames, and the closing fade begins.
function EggHatchState:_updateReveal()
  if self._barSliding ~= true then
    if self._frame >= BURST_HOLD_FRAMES then
      self._barSliding = true
      self._frame = 0
    end
    return
  end
  if self._barsOffset < BAR_SLIDE_LIMIT then
    self._barsOffset = self._barsOffset + BAR_SLIDE_STEP
    if self._barsOffset >= BAR_SLIDE_LIMIT then
      self._bars = false
    end
    self._frame = 0
    return
  end
  if self._frame >= REVEAL_HOLD_FRAMES then
    self:_beginCry()
    return
  end
end

-- Advances the shared tail after the hatched picture appeared.
function EggHatchState:_updateTail()
  local phase = self._phase
  if self._printRemaining > 0 then
    self._printRemaining = self._printRemaining - 1
  end
  if phase == PokemonCareInterface.HATCH_PHASES.WAIT_CRY then
    if not cryFinished(self._audio) then
      return
    end
    if self._printRemaining > 0 then
      return
    end
    if type(self._audio.playFanfare) == "function" then
      self._audio:playFanfare("SEQ_ME_SHINKAOME")
    end
    self._phase = PokemonCareInterface.HATCH_PHASES.WAIT_FANFARE
    self._frame = 0
    return
  end
  if phase == PokemonCareInterface.HATCH_PHASES.WAIT_FANFARE then
    if not fanfareFinished(self._audio) then
      return
    end
    self._phase = PokemonCareInterface.HATCH_PHASES.ASK_NICKNAME
    self._frame = 0
    self._messageId = self._question.messageId
    self._printRemaining = self._question.frames
    return
  end
  if phase == PokemonCareInterface.HATCH_PHASES.ASK_NICKNAME then
    if self._printRemaining > 0 then
      return
    end
    self._questionShown = true
    self._phase = PokemonCareInterface.HATCH_PHASES.CHOOSE_NICKNAME
    self._frame = 0
    return
  end
  if phase == PokemonCareInterface.HATCH_PHASES.FADE_OUT then
    if self._frame >= FADE_FRAMES then
      self._phase = PokemonCareInterface.HATCH_PHASES.DONE
      self._done = true
    end
  end
end

---@param input { pressedAction: boolean?, pressedCancel: boolean?, pressedDirection: string? }?
function EggHatchState:updateFixed(input)
  if self._done then
    return
  end
  -- The source creates its particles from the scene frame that asks for them;
  -- the request is visible for exactly that snapshot.
  self._particles = {}
  self._frame = self._frame + 1
  local phase = self._phase
  if phase == PokemonCareInterface.HATCH_PHASES.FADE_IN then
    if self._frame >= FADE_FRAMES then
      if type(self._audio.playMusic) == "function" then
        self._audio:playMusic("SEQ_GS_SHINKA")
      end
      if self._variant == PokemonCareInterface.HATCH_VARIANTS.manaphy then
        self._phase = PokemonCareInterface.HATCH_PHASES.HATCH
      else
        self._phase = PokemonCareInterface.HATCH_PHASES.WAIT_BEFORE_SHAKE
      end
      self._frame = 0
      self._shakeFrame = 1
    end
    return
  end
  if
    phase == PokemonCareInterface.HATCH_PHASES.WAIT_CRY
    or phase == PokemonCareInterface.HATCH_PHASES.WAIT_FANFARE
    or phase == PokemonCareInterface.HATCH_PHASES.ASK_NICKNAME
    or phase == PokemonCareInterface.HATCH_PHASES.FADE_OUT
  then
    self:_updateTail()
    return
  end
  if phase == PokemonCareInterface.HATCH_PHASES.CHOOSE_NICKNAME then
    self:handleInput(input)
    return
  end
  if self._variant == PokemonCareInterface.HATCH_VARIANTS.manaphy then
    self:_updateManaphyScene()
  else
    self:_updateEggScene()
  end
end

-- The source yes/no menu: up/down (or left/right) move the cursor, A confirms
-- the current answer and B answers no. Frames outside the question ignore
-- input, exactly like the source's own scene states.
---@param input { pressedAction: boolean?, pressedCancel: boolean?, pressedDirection: string? }?
function EggHatchState:handleInput(input)
  if self._phase ~= PokemonCareInterface.HATCH_PHASES.CHOOSE_NICKNAME then
    return
  end
  local typed = input or {}
  local direction = typed.pressedDirection
  if direction == "up" or direction == "left" then
    self._selection = "yes"
  elseif direction == "down" or direction == "right" then
    self._selection = "no"
  end
  if typed.pressedCancel == true then
    self._selection = "no"
    self._wantToName = false
    self:_beginFadeOut()
    return
  end
  if typed.pressedAction == true then
    self._wantToName = self._selection == "yes"
    self:_beginFadeOut()
  end
end

function EggHatchState:_beginFadeOut()
  self._questionShown = false
  self._messageId = nil
  self._phase = PokemonCareInterface.HATCH_PHASES.FADE_OUT
  self._frame = 0
end

-- Releases nothing: the scene owns no lease. The host owns the presentation
-- bundle and the field owns the audio host.
function EggHatchState:dispose()
  self._done = true
end

return EggHatchState
