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
---@field private _headless boolean
---@field private _vsRed integer
---@field private _previouslyCleared boolean
---@field private _sceneParty table[] recorded members for the registration scene
---@field private _scene table<string, unknown>? the active registration scene
---@field private _choreography table<string, unknown>? the active credit-roll choreography
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

-- The source B key edge behind the registration and The End terminal
-- acknowledgment (A/B/touch). The field forwards the raw cancel edge while
-- the ending owns the modal lane.
---@param input table<string, unknown>|nil
---@return boolean pressed the source B key this tick
local function pressedCancel(input)
  return input ~= nil and input.cancelPressed == true
end

---@param options { vsRed: integer, previouslyCleared: boolean, presentation: table<string, unknown>|nil, audio: table<string, unknown>|nil, sceneParty: table<string, unknown>[]?, headless: boolean? }
---@return GameClearState
function GameClearState.new(options)
  assert(type(options) == "table", "the game-clear state needs its source facts")
  local vsRed = options.vsRed
  assert(type(vsRed) == "number" and vsRed % 1 == 0 and vsRed >= 0, "the game-clear state needs its raw vsRed word")
  local sceneParty = options.sceneParty or {}
  assert(type(sceneParty) == "table", "the game-clear state needs its recorded scene party")
  local state = setmetatable({
    _phase = vsRed == 0 and "congratulations" or "saving",
    _timer = 0,
    _savingTimer = 0,
    _musicBoxTimer = 0,
    _skipped = false,
    _presentation = options.presentation,
    _audio = options.audio,
    _headless = options.headless == true,
    _vsRed = vsRed,
    _previouslyCleared = options.previouslyCleared == true,
    _sceneParty = sceneParty,
    _scene = nil,
    _choreography = nil,
    _frozenCredits = nil,
    _fadeTarget = 0,
    _savingArmed = false,
    _savingPresented = false,
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

-- Whether the composed presentation is still pending its actual required
-- receipt for the advancing phase: sections present is not enough. A
-- composed owner without its full admitted receipt stays pending and holds
-- phase clocks, presentation starts, and phase-owned input, while a
-- composition without any presentation owner keeps the explicit headless
-- timeline. Production advances on the full draw receipt (static +
-- dynamic party/header/save text, images, icons), never on text alone, so
-- the timeline cannot run ahead of its surface. A terminal admission
-- failure also blocks: the coordinator surfaces it instead of advancing
-- with cold art. Headless compositions (no display owner) advance on bundle
-- readiness alone: the coordinator still validates the generated bundle
-- every tick, but no GPU/icon receipt is required without a surface.
---@return boolean
function GameClearState:_presentationBlocked()
  local presentation = self._presentation
  if presentation == nil or type(presentation.isReady) ~= "function" then
    return false
  end
  if not presentation:isReady() then
    return true
  end
  if self._headless then
    if type(presentation.admissionFailure) == "function" then
      return presentation:admissionFailure() ~= nil
    end
    return false
  end
  if type(presentation.isDrawReady) == "function" then
    return not presentation:isDrawReady(self:_requiredSections())
  end
  return false
end

-- The generated sections the current phase actually draws, through the one
-- feature-owned mapping. Saving draws only save text, never party icons.
-- A composed presentation owns the mapping; the nil-owner table below
-- serves only headless/test compositions with no presentation owner.
---@return string[]
function GameClearState:_requiredSections()
  local presentation = self._presentation
  if presentation ~= nil and type(presentation.requiredSectionsForPhase) == "function" then
    return presentation.requiredSectionsForPhase(self._phase)
  end
  local phase = self._phase
  if phase == "congratulations" then
    return { "registration" }
  end
  if phase == "credits" or phase == "credits_fade" then
    return { "credits" }
  end
  if
    phase == "the_end"
    or phase == "the_end_music_box"
    or phase == "the_end_fade_in"
    or phase == "the_end_fade_out"
  then
    return { "credits" }
  end
  if
    phase == "saving"
    or phase == "save_failed"
    or phase == "save_status"
    or phase == "save_se"
    or phase == "save_fade"
  then
    return { "save" }
  end
  return { "registration" }
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
  -- Freezing the visible credit choreography before resetting the clock:
  -- the fade must retain the last rendered roll frame instead of
  -- rewinding to page 0 (the choreography clock itself stays frozen
  -- because step() no longer advances it off the credits phase).
  if self._phase == "credits" and self._choreography ~= nil then
    local ok, snapshot = pcall(function()
      return self._choreography:status()
    end)
    if ok and type(snapshot) == "table" then
      self._frozenCredits = snapshot
    end
  end
  self._phase = phase
  self._timer = 0
  self._fadeTarget = self:_fadeFrames(frames)
end

-- Marks the saving surface as genuinely presented: the draw owner calls
-- this after painting the saving phase so the transaction cannot publish
-- on a fixed tick that no draw ever displayed.
function GameClearState:noteSavingPresented()
  self._savingPresented = true
end

---@param sound string
function GameClearState:_play(sound)
  local audio = self._audio
  if audio ~= nil and type(audio.play) == "function" then
    audio:play(sound)
  end
end

-- One recorded cry through the shared cry boundary (pattern 0, like the
-- source PlayCryDelayed): the registration unsilhouettes play the back
-- and front cries with their baked delays. A composition without a cry
-- owner stays silent instead of failing the mandatory sequence.
---@param species integer
---@param form integer
function GameClearState:_playCry(species, form)
  local audio = self._audio
  if audio ~= nil and type(audio.playCry) == "function" then
    audio:playCry(species, 0, form)
  end
end

---@param music string
function GameClearState:_playMusic(music)
  local audio = self._audio
  if audio ~= nil and type(audio.playMusic) == "function" then
    audio:playMusic(music)
  end
end

-- The registration scene, built once the bundle is ready: the reveal
-- cannot time cries or place pictures without its picture tracks. A
-- composition without any presentation owner keeps the explicit headless
-- timeline with trackless members instead of deadlocking.
---@return RegistrationScene? scene
function GameClearState:_registrationScene()
  if self._scene ~= nil then
    return self._scene
  end
  local presentation = self._presentation
  local tracks = nil
  if presentation ~= nil then
    if not presentation:isReady() then
      return nil
    end
    if type(presentation.monTracks) == "function" then
      tracks = presentation:monTracks()
    end
  end
  local RegistrationScene = require("game.hgss.src.ending.RegistrationScene")
  self._scene = RegistrationScene.new({ party = self._sceneParty, tracks = tracks })
  return self._scene
end

-- The credit-roll choreography, built once the bundle is ready: scene
-- transitions, flips and cutscenes need their baked sequences and the
-- noted player gender. A composition without any presentation owner keeps
-- the explicit headless timeline instead of deadlocking.
---@return table<string, unknown>? scene
function GameClearState:_creditsScene()
  if self._choreography ~= nil then
    return self._choreography
  end
  local presentation = self._presentation
  if presentation == nil or not presentation:isReady() then
    return nil
  end
  local choreography = nil
  if type(presentation.creditChoreography) == "function" then
    choreography = presentation:creditChoreography()
  end
  local gender = nil
  if type(presentation.cutsceneGender) == "function" then
    gender = presentation:cutsceneGender()
  end
  if choreography == nil or gender == nil then
    return nil
  end
  local transitions = choreography.transitionTimings
  local flips = choreography.flipTimings
  assert(type(transitions) == "table", "the bundle carries its scene transition timings")
  assert(type(flips) == "table", "the bundle carries its screen flip timings")
  local newChoreography = require("game.hgss.src.ending.CreditsScene").new
  local built = newChoreography({
    danceSequences = choreography.danceSequences,
    danceSeqsByScene = choreography.danceSeqsByScene,
    cloudSeq = choreography.cloudSeq,
    cutscenes = choreography.cutscenes,
    cutsceneSprites = choreography.cutsceneSprites,
    gender = gender,
    totalFrames = self:_creditFrames(),
    transitionTimings = transitions,
    flipTimings = flips,
  })
  assert(type(built) == "table", "the choreography builds its scene")
  self._choreography = built
  return self._choreography
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
    -- The transaction owns the write, but the source prints its saving
    -- message and waits for completion before writing (game_clear.c
    -- states 2-4). Never publish while the presented save surface is cold;
    -- a Red start holds here until its save receipt admits. The
    -- congratulations acknowledgment lands here with wait (never publish
    -- in the same tick), and this phase waits until a saving-message frame
    -- has been drawn before the write: the first admitted tick only arms
    -- the timer, the second tick publishes, so the message is visible for
    -- at least one presented frame (headless simulates the same wait
    -- without a surface). This establishes the source print-then-write
    -- order instead of publishing synchronously with the phase entry.
    if self:_presentationBlocked() then
      return "wait"
    end
    -- The first admitted tick only arms the timer; publication additionally
    -- requires a genuinely presented saving frame (headless simulates the
    -- same wait without a surface). A fixed tick is not proof of a draw:
    -- catch-up ticks in one outer update must not publish over a surface
    -- the player never saw.
    if not self._savingArmed then
      self._savingArmed = true
      self._savingTimer = (self._savingTimer or 0) + 1
      return "wait"
    end
    if self._presentation ~= nil and not self._headless and not self._savingPresented then
      return "wait"
    end
    self._savingTimer = (self._savingTimer or 0) + 1
    if self._savingTimer <= 1 then
      return "wait"
    end
    -- The coordinator owns the write; the state never advances past this
    -- phase until the transaction reports its outcome.
    return self._published == true and "wait" or "publish"
  end
  if phase == "save_failed" then
    if self:_presentationBlocked() then
      return "wait"
    end
    if pressedAction(input) or pressedCancel(input) or touched(input) then
      self._phase = "saving"
      self._timer = 0
      self._savingTimer = 0
      self._savingArmed = false
      self._savingPresented = false
      return "wait"
    end
    return "wait"
  end
  if phase == "congratulations" then
    -- The registration application reveals every recorded member in party
    -- order (back picture with cry, follower sprite, header, front picture
    -- with cry, species/level, caught detail) before the whole-party photo
    -- waits for the terminal A/B/touch acknowledgment. Input is ignored
    -- everywhere else; a pending receipt holds the reveal's clock. A
    -- headless composition advances the same scene without a surface. The
    -- source plays its registration BGM (SEQ_GS_E_DENDOUIRI) over the reveal.
    if self:_presentationBlocked() then
      return "wait"
    end
    local scene = self:_registrationScene()
    if scene == nil then
      return "wait"
    end
    if not self._registrationBgm then
      self:_playMusic("SEQ_GS_E_DENDOUIRI")
      self._registrationBgm = true
    end
    scene:step(input)
    for _, cue in ipairs(scene:takeCues()) do
      if cue.kind == "cry" then
        self:_playCry(cue.species, cue.form)
      elseif cue.kind == "sound" then
        self:_play(cue.name)
      end
    end
    if scene:isDone() then
      self._phase = "saving"
      self._timer = 0
      self._savingTimer = 0
      self._savingArmed = false
      self._savingPresented = false
      return "wait"
    end
    return "wait"
  end
  if phase == "save_status" then
    if self:_presentationBlocked() then
      return "wait"
    end
    self._timer = self._timer + 1
    -- The source waits for the save-result print to finish before the
    -- save sound (game_clear.c state 5). The bundle owns the print
    -- duration when composed, otherwise at least one admitted frame, and
    -- the sound fires only after strictly more ticks than the print
    -- duration so the result message paints for its full duration.
    local printFrames = self:_presentationFrames("saveStatusFrames")
    if printFrames < 1 then
      printFrames = 1
    end
    if self._timer > printFrames then
      self._phase = "save_se"
      self._timer = 0
      self:_play("SEQ_SE_DP_SAVE")
    end
    return "wait"
  end
  if phase == "save_se" then
    if self:_presentationBlocked() then
      return "wait"
    end
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
    -- A headless composition owns no surface: it advances the explicit
    -- roll clock on bundle readiness instead of stepping the choreography.
    if self._headless then
      self._timer = self._timer + 1
      if self._timer >= self:_creditFrames() then
        self:_beginFade("credits_fade", CREDITS_FADE_FRAMES)
      end
      return "wait"
    end
    -- The choreography owns the roll clock: transitions, flips and
    -- cutscenes advance with the scene, and the roll ends on its source
    -- frame count. A pending bundle holds the clock like the registration
    -- holds its reveal.
    local scene = self:_creditsScene()
    if scene == nil then
      return "wait"
    end
    scene:step(input)
    self._timer = scene:status().timer
    if scene:isDone() then
      self:_beginFade("credits_fade", CREDITS_FADE_FRAMES)
    end
    return "wait"
  end
  if phase == "the_end" then
    if self:_presentationBlocked() then
      return "wait"
    end
    -- The End accepts START/A/touch (credits.c THE_END), unlike the
    -- registration's A/B/touch terminal acknowledgment.
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
  -- A pending receipt holds the fade: fading with no admitted surface would
  -- play the source timeline over nothing.
  if self:_presentationBlocked() then
    return "wait"
  end
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
      self._fadeTarget = self:_fadeFrames(THE_END_FADE_FRAMES)
      return "wait"
    end
    self._phase = "credits"
    self._timer = 0
    self._fadeTarget = 0
    return "wait"
  end
  if phase == "the_end_fade_in" then
    self._phase = "the_end"
    self._musicBoxTimer = 0
    self._fadeTarget = 0
    return "wait"
  end
  assert(phase == "the_end_fade_out", "the game-clear state is a closed phase set")
  self._phase = "complete"
  self._fadeTarget = 0
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

-- The immutable per-tick snapshot the field draws. Fade is a phase-owned
-- envelope, never a stale generic timer: steady phases publish zero,
-- fade-out phases publish 0->1, and the_end_fade_in publishes 1->0. Fade
-- timing rides the fade phase's own timer, independent of the frozen
-- roll/page timer the credits_fade snapshot retains.
---@return table<string, unknown>
function GameClearState:status()
  local phase = self._phase
  local target = self._fadeTarget or 0
  local fadeAlpha = 0
  if phase == "save_fade" or phase == "credits_fade" or phase == "the_end_fade_out" then
    if target > 0 then
      fadeAlpha = math.min(1, math.max(0, self._timer / target))
    else
      fadeAlpha = 0
    end
  elseif phase == "the_end_fade_in" then
    if target > 0 then
      fadeAlpha = 1 - math.min(1, math.max(0, self._timer / target))
    else
      fadeAlpha = 0
    end
  else
    fadeAlpha = 0
  end
  local status = {
    phase = self._phase,
    timer = self._timer,
    musicBoxTimer = self._musicBoxTimer,
    skipped = self._skipped,
    previouslyCleared = self._previouslyCleared,
    vsRed = self._vsRed,
    fadeTarget = self._fadeTarget or 0,
    fadeAlpha = fadeAlpha,
  }
  if self._phase == "congratulations" and self._scene ~= nil then
    status.registration = self._scene:status()
  end
  if self._phase == "credits" and self._choreography ~= nil then
    status.credits = self._choreography:status()
  end
  -- The fade retains the last visible roll frame: drawing the reset timer
  -- would rewind to page 0, losing dancers and cutscenes during the fade.
  if self._phase == "credits_fade" then
    local frozen = self._frozenCredits
    if frozen == nil and self._choreography ~= nil then
      local ok, snapshot = pcall(function()
        return self._choreography:status()
      end)
      if ok and type(snapshot) == "table" then
        frozen = snapshot
      end
    end
    if type(frozen) == "table" then
      status.credits = frozen
      status.timer = tonumber(frozen.timer) or self._timer
    end
  end
  return status
end

return GameClearState
