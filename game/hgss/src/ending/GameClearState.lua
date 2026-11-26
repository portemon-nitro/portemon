-- The League ending's presentation and input state: the source save-status
-- sequence (src/game_clear.c::Task_GameClear) followed by the credit roll
-- (src/credits/credits.c). It owns only phases, source frame counters and the
-- skip gate; the transaction that writes the clear lives in
-- GameClearCoordinator, and every drawn surface comes from the prepared
-- presentation bundle.
--
-- Source facts this state reproduces:
--   * the first clear's credit roll is never skippable
--     (`args->gameCleared` gates the skip), a later clear ends on START or a
--     touch;
--   * the roll itself runs CREDITS_FRAMES frames;
--   * "The End" accepts START/A/touch, and without input it plays the ending
--     music-box track after MUSIC_BOX_WAIT_FRAMES and keeps waiting;
--   * the save-status message waits WAIT_SE_SAVE_FRAMES after the save sound
--     before the screen darkens into the credits.
-- A composition without the generated presentation bundle draws nothing, so
-- its palette fades and text prints take no frames; the source timeline the
-- roll and its gates own stays exact either way.

---@class GameClearState
---@field private _phase string
---@field private _timer integer
---@field private _musicBoxTimer integer
---@field private _skipped boolean
---@field private _presentation table<string, unknown>|nil
---@field private _audio table<string, unknown>|nil
---@field private _vsRed integer
---@field private _previouslyCleared boolean
---@field private _partySize integer?
local GameClearState = {}
GameClearState.__index = GameClearState

-- src/credits/credits.c CREDITS_FRAMES and MUSIC_BOX_WAIT_FRAMES.
GameClearState.CREDITS_FRAMES = 4976
GameClearState.MUSIC_BOX_WAIT_FRAMES = 380
-- src/game_clear.c WAIT_SE_SAVE_FRAMES.
GameClearState.WAIT_SE_SAVE_FRAMES = 32

-- The source's own fade lengths for the sequences this state drives.
local SAVE_FADE_FRAMES = 8
local CREDITS_FADE_FRAMES = 30
local THE_END_FADE_FRAMES = 60

---@param input table<string, unknown>|nil
---@return boolean started the source START key this tick
local function pressedStart(input)
  return input ~= nil and input.menuPressed == true
end

---@param input table<string, unknown>|nil
---@return boolean pressed the source A key this tick
local function pressedAction(input)
  return input ~= nil and input.actionPressed == true
end

-- A touch is the source's third accept input (gSystem.touchNew). The field
-- hands its modal pointer batch to the ending only while the ending owns the
-- input lifetime, so an unmapped touch simply never arrives.
---@param input table<string, unknown>|nil
---@return boolean touched this tick
local function touched(input)
  if input == nil or type(input.uiEvents) ~= "table" then
    return false
  end
  for _, event in ipairs(input.uiEvents) do
    if type(event) == "table" and event.type == "pointer_down" then
      return true
    end
  end
  return false
end

---@param options { vsRed: integer, previouslyCleared: boolean, presentation: table<string, unknown>|nil, audio: table<string, unknown>|nil, partySize: integer? }
---@return GameClearState
function GameClearState.new(options)
  assert(type(options) == "table", "the game-clear state needs its source facts")
  local vsRed = options.vsRed
  assert(type(vsRed) == "number" and vsRed % 1 == 0 and vsRed >= 0, "the game-clear state needs its raw vsRed word")
  local partySize = options.partySize
  if partySize ~= nil then
    assert(
      type(partySize) == "number" and partySize % 1 == 0 and partySize >= 0,
      "the game-clear state needs its recorded party size"
    )
  end
  local state = setmetatable({
    _phase = vsRed == 0 and "congratulations" or "saving",
    _timer = 0,
    _musicBoxTimer = 0,
    _skipped = false,
    _presentation = options.presentation,
    _audio = options.audio,
    _vsRed = vsRed,
    _previouslyCleared = options.previouslyCleared == true,
    _partySize = partySize,
  }, GameClearState)
  return state
end

---@return string
function GameClearState:phase()
  return self._phase
end

---@return boolean
function GameClearState:isComplete()
  return self._phase == "complete"
end

---@return boolean whether the roll was skipped by the player
function GameClearState:wasSkipped()
  return self._skipped
end

---@return boolean whether the source save sound still owns the tick
function GameClearState:isSaveSoundRunning()
  return self._phase == "save_se"
end

-- Whether the composed presentation bundle is still pending: a composed
-- owner without its generated sections gates both frames and input, while a
-- composition without any presentation owner keeps the headless timeline.
---@return boolean
function GameClearState:_presentationBlocked()
  local presentation = self._presentation
  if presentation == nil or type(presentation.isReady) ~= "function" then
    return false
  end
  return not presentation:isReady()
end

-- The prepared bundle's frame count for one surface, or zero when no bundle is
-- composed: nothing is printed or faded, so nothing has to be waited for.
---@param method string
---@return integer
function GameClearState:_presentationFrames(method)
  local presentation = self._presentation
  if presentation == nil or type(presentation[method]) ~= "function" then
    return 0
  end
  local resolved = presentation[method](presentation)
  if type(resolved) ~= "number" or resolved < 0 then
    return 0
  end
  return math.floor(resolved)
end

---@param frames integer
---@return integer
function GameClearState:_fadeFrames(frames)
  local presentation = self._presentation
  if presentation == nil or type(presentation.fadeFrames) ~= "function" then
    return 0
  end
  local resolved = presentation:fadeFrames(frames)
  if type(resolved) ~= "number" or resolved < 0 then
    return 0
  end
  return math.floor(resolved)
end

-- The credit roll's own source frame count: the prepared bundle owns the
-- timeline when composed, otherwise the source constant applies.
---@return integer
function GameClearState:_creditFrames()
  local presentation = self._presentation
  if presentation ~= nil and type(presentation.creditFrames) == "function" then
    local resolved = presentation:creditFrames()
    if type(resolved) == "number" and resolved > 0 then
      return math.floor(resolved)
    end
  end
  return GameClearState.CREDITS_FRAMES
end

-- The End's own source music-box wait: the prepared bundle owns it when
-- composed, otherwise the source constant applies.
---@return integer
function GameClearState:_musicBoxWaitFrames()
  local presentation = self._presentation
  if presentation ~= nil and type(presentation.musicBoxWaitFrames) == "function" then
    local resolved = presentation:musicBoxWaitFrames()
    if type(resolved) == "number" and resolved > 0 then
      return math.floor(resolved)
    end
  end
  return GameClearState.MUSIC_BOX_WAIT_FRAMES
end

---@param phase string
---@param frames integer
function GameClearState:_beginFade(phase, frames)
  self._phase = phase
  self._timer = 0
  self._fadeTarget = self:_fadeFrames(frames)
end

---@param sound string
function GameClearState:_play(sound)
  local audio = self._audio
  if audio ~= nil and type(audio.play) == "function" then
    audio:play(sound)
  end
end

---@param music string
function GameClearState:_playMusic(music)
  local audio = self._audio
  if audio ~= nil and type(audio.playMusic) == "function" then
    audio:playMusic(music)
  end
end

-- One fixed tick. Answers "publish" when the transaction must attempt its one
-- publication, "complete" once the ending released the host route, and "wait"
-- otherwise.
---@param input table<string, unknown>|nil the tick's field input snapshot
---@return string
function GameClearState:step(input)
  local phase = self._phase
  if phase == "complete" then
    return "complete"
  end
  if phase == "saving" then
    -- The coordinator owns the write; the state never advances past this
    -- phase until the transaction reports its outcome.
    return self._published == true and "wait" or "publish"
  end
  if phase == "save_failed" then
    if pressedStart(input) or pressedAction(input) or touched(input) then
      self._phase = "saving"
      return "publish"
    end
    return "wait"
  end
  if phase == "congratulations" then
    -- The registration application shows the recorded party and returns after
    -- the player acknowledges it. A pending bundle gates both the reveal
    -- frames and the input; a headless composition has no frames to play,
    -- so the acknowledgement alone advances the sequence. The source plays
    -- its registration BGM (SEQ_GS_E_DENDOUIRI) over the reveal.
    if self:_presentationBlocked() then
      return "wait"
    end
    if self._timer == 0 and not self._registrationBgm then
      self:_playMusic("SEQ_GS_E_DENDOUIRI")
      self._registrationBgm = true
    end
    self._timer = self._timer + 1
    local presentation = self._presentation
    local frames = 0
    if presentation ~= nil and type(presentation.congratulationsFrames) == "function" then
      local resolved = presentation:congratulationsFrames(self._partySize)
      if type(resolved) == "number" and resolved >= 0 then
        frames = math.floor(resolved)
      end
    end
    if self._timer > frames and (pressedStart(input) or pressedAction(input) or touched(input)) then
      self._phase = "saving"
      return "publish"
    end
    return "wait"
  end
  if phase == "save_status" then
    self._timer = self._timer + 1
    if self._timer >= self:_presentationFrames("saveStatusFrames") then
      self._phase = "save_se"
      self._timer = 0
      self:_play("SEQ_SE_DP_SAVE")
    end
    return "wait"
  end
  if phase == "save_se" then
    self._timer = self._timer + 1
    if self._timer >= GameClearState.WAIT_SE_SAVE_FRAMES then
      self:_beginFade("save_fade", SAVE_FADE_FRAMES)
    end
    return "wait"
  end
  if phase == "credits" then
    -- A pending bundle holds the roll: the first clear's full timeline and
    -- a later clear's START/touch skip both need their prepared surfaces.
    -- The source plays its credit BGM (SEQ_GS_ENDING, 0x3f8) under the roll.
    if self:_presentationBlocked() then
      return "wait"
    end
    if self._timer == 0 and not self._creditsBgm then
      self:_playMusic("SEQ_GS_ENDING")
      self._creditsBgm = true
    end
    -- The first clear never skips; a later clear ends on START or a touch.
    if self._previouslyCleared and (pressedStart(input) or touched(input)) then
      self._skipped = true
      self:_beginFade("credits_fade", CREDITS_FADE_FRAMES)
      return "wait"
    end
    self._timer = self._timer + 1
    if self._timer >= self:_creditFrames() then
      self:_beginFade("credits_fade", CREDITS_FADE_FRAMES)
    end
    return "wait"
  end
  if phase == "the_end" then
    if self:_presentationBlocked() then
      return "wait"
    end
    if pressedStart(input) or pressedAction(input) or touched(input) then
      self:_beginFade("the_end_fade_out", THE_END_FADE_FRAMES)
      return "wait"
    end
    if self._musicBoxTimer >= self:_musicBoxWaitFrames() then
      self:_playMusic("SEQ_GS_ENDING2")
      self._phase = "the_end_music_box"
      return "wait"
    end
    self._musicBoxTimer = self._musicBoxTimer + 1
    return "wait"
  end
  if phase == "the_end_music_box" then
    if self:_presentationBlocked() then
      return "wait"
    end
    if pressedStart(input) or pressedAction(input) or touched(input) then
      self:_beginFade("the_end_fade_out", THE_END_FADE_FRAMES)
    end
    return "wait"
  end
  -- Fade phases advance one frame each and then hand over to their successor.
  local fadeTarget = self._fadeTarget or 0
  if self._timer < fadeTarget then
    self._timer = self._timer + 1
    if self._timer < fadeTarget then
      return "wait"
    end
  end
  if phase == "save_fade" or phase == "credits_fade" then
    if phase == "credits_fade" then
      self._phase = "the_end_fade_in"
      self._timer = 0
      self._fadeTarget = self:_fadeFrames(1)
      return "wait"
    end
    self._phase = "credits"
    self._timer = 0
    return "wait"
  end
  if phase == "the_end_fade_in" then
    self._phase = "the_end"
    self._musicBoxTimer = 0
    return "wait"
  end
  assert(phase == "the_end_fade_out", "the game-clear state is a closed phase set")
  self._phase = "complete"
  return "complete"
end

-- The transaction published the ending's one candidate: the save-status
-- message now reports success and the sequence continues to the credits.
function GameClearState:saveSucceeded()
  assert(self._phase == "saving", "a published ending continues from its saving phase")
  self._published = true
  self._phase = "save_status"
  self._timer = 0
end

-- The publication failed: the previous save stays on disk, the same candidate
-- stays staged, and the source save-status surface reports the failure while
-- the ending waits for the player's retry.
function GameClearState:saveFailed()
  assert(self._phase == "saving", "a failed ending publication reports from its saving phase")
  self._phase = "save_failed"
  self._timer = 0
end

-- The immutable per-tick snapshot the field draws.
---@return table<string, unknown>
function GameClearState:status()
  return {
    phase = self._phase,
    timer = self._timer,
    musicBoxTimer = self._musicBoxTimer,
    skipped = self._skipped,
    previouslyCleared = self._previouslyCleared,
    vsRed = self._vsRed,
  }
end

return GameClearState
