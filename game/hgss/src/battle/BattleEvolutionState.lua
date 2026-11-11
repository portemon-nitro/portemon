-- Native post-battle evolution presentation state. Owns the source entry,
-- old/new picture animation, particle/visual effects, music/cry, progress
-- messages, permitted cancel, successful transformation, and subsequent
-- move-learning offers sequencing for one committed subject. Eligibility,
-- planning, and transformation stay with the evolution domain: the state
-- binds exactly one EvolutionFlow, which selects the first matching
-- source rule, so all returned mons and consumption publish as one staged
-- operation. The state never publishes: the staged records ride the
-- completion command. Effect records (music, cry, messages, sounds,
-- particles, window/affine, summary hook, fanfare wait, palette) are
-- sequenced here as data-only evidence for the audio/visual owners; text
-- and picture resolution stay with the normalized asset producers.
--
-- Retail reference: tmp/pokeheartgold/src/evolution_scene.c. The
-- scene's beats map onto this state's phases as follows:
--   WAIT_FADE_IN/START (+PRINT_WHAT 916)                    -> "entry"
--   PLAY_CRY/WAIT_CRY (old cry, 917 battle / 915 otherwise,
--     PlayBGMDirect SEQ_GS_SHINKA on the way in)            -> "sequence"
--   START_PARTICLES/NARROW_WINDOW (resource 0, emitter 0,
--     SE W025, window narrow, emitters 1/2/7/8/9/11, SE W060C,
--     affine scale-oscillation start)                       -> entry into
--                                                              "transformation"
--   OSCILLATE (B cancels here only, when the source permits;
--     on completion emitters 3/4/5/6/10, SE W062)            -> "transformation"
--   WIDEN_WINDOW (emitter 12, SE W080, window widen,
--     palette fades) then NEW_MON_CRY (new cry)             -> accept beat
--   EVOLVE (message 918, fanfare SEQ_ME_SHINKAOME rides the
--     message's WAIT 3 for the audio owner) then REGISTER   -> accept beat
--   TRY_LEARN_MOVE battery (1193/1194/1195, source move menu,
--     {1,4,0,0} for the full-set replacement path, 1199/1200
--     /1201/1202 plus SEQ_ME_LVUP fanfare wait after learning,
--     1197/1198 after giving up)                            -> "learn"/"fanfare"
--   CANCEL (StopBGM SHINKA, old cry, message 919)           -> cancel beat
-- The sequence starts on its own: entry runs its music beat, the old
-- picture animates with its cry, and the transformation beat follows
-- without any confirmation gate. Only the transformation beat honors
-- cancel input (retail checks B during OSCILLATE alone); entry, sequence,
-- learn, fanfare, key release, focus loss, and teardown decide nothing.

local EvolutionFlow = require("libs.hgss.src.mons.EvolutionFlow")
local SummaryModel = require("libs.hgss.src.ui.SummaryModel")

---@class BattleEvolutionState
---@field _flow table<string, unknown>? single staged domain flow, nil while ineligible
---@field _source string presentation origin: battle, field_level, field_item, or trade
---@field _flags integer retail scene flags derived from the source
---@field _printWhat boolean retail PRINT_WHAT policy derived from the source
---@field _canCancel boolean effective cancel policy: domain rule AND source permits
---@field _species string committed subject species key
---@field _form integer committed subject form index (retail voices both cries and builds both pictures from this form)
---@field _pokepicSelectors { old: string, new: string }? canonical subject portrait selectors used as available staged art
---@field _newSpecies string? staged target species key, nil while ineligible
---@field _assets table<string, unknown>? data-only visual asset manifest, nil while ineligible
---@field _accepted boolean true once the transformation completed and the choice is accepted
---@field _phase string current presentation phase
---@field _beat string retail transformation substate
---@field _clock integer ticks spent in the current phase
---@field _windowTop integer retail main-screen window top edge
---@field _windowBottom integer retail main-screen window bottom edge
---@field _oldScale integer old Pokepic affine scale
---@field _newScale integer new Pokepic affine scale
---@field _scaleStep integer retail affine scale step
---@field _scaleOscillation integer retail affine direction flag
---@field _prompt table<string, unknown>? pending learned-move prompt under answering
---@field _learnedMove table<string, unknown>? pending free-slot learned-move message
---@field _learnStep integer? current full-set printer/timer beat
---@field _replacementStep integer? current replacement-message printer/timer beat
---@field _forgottenMove string? replaced move name for the next retail message
---@field _learnedMoveKey string? incoming move name for the next retail message
---@field _summaryMoveSlot integer? returned move slot held through the Summary close fade
---@field _cancelReason string? pending cancellation reason until retail finish beat
---@field _effects table<integer, table<string, unknown>> sequenced effect requests in order
---@field _paletteRequestId integer latest source palette request sequence
---@field _paletteChannels table<string, integer> active request id for each independent palette manager
---@field _printerPending boolean active source message awaits printer completion
---@field _printerMessageId integer? source message id currently owned by the printer
---@field _particles BattleEvolutionParticles? live retail SPL evolution scene
---@field _result table<string, unknown>? settled choice record
---@field _taken boolean result consumed
---@field _disposed boolean
local BattleEvolutionState = {}
BattleEvolutionState.__index = BattleEvolutionState

BattleEvolutionState.ENTRY_TICKS = 2
BattleEvolutionState.PARTICLE_DELAY_TICKS = 20
BattleEvolutionState.NARROW_WINDOW_TICKS = 40
-- State-only vectors without a compiled particle scene use this short
-- handoff; production waits for the live SPL scene to drain.
BattleEvolutionState.OSCILLATION_TICKS = 2
BattleEvolutionState.WIDEN_WINDOW_TICKS = 8
BattleEvolutionState.FANFARE_TICKS = 30
BattleEvolutionState.CANCEL_MESSAGE_TICKS = 20

-- Retail msg_0197 indices (pokeheartgold msgdata/msg/msg_0197.gmm).
BattleEvolutionState.MSG_WHAT_COMBINED = 915
BattleEvolutionState.MSG_WHAT = 916
BattleEvolutionState.MSG_LEARNED_FREE_SLOT = 4
BattleEvolutionState.MSG_EVOLVING = 917
BattleEvolutionState.MSG_EVOLVED = 918
BattleEvolutionState.MSG_STOPPED = 919
BattleEvolutionState.MSG_WANTS_TO_LEARN = 1193
BattleEvolutionState.MSG_KNOWS_FOUR = 1194
BattleEvolutionState.MSG_SHOULD_DELETE = 1195
BattleEvolutionState.MSG_STOP_TRYING = 1197
BattleEvolutionState.MSG_DID_NOT_LEARN = 1198
BattleEvolutionState.MSG_POOF = 1199
BattleEvolutionState.MSG_FORGOT = 1200
BattleEvolutionState.MSG_AND = 1201
BattleEvolutionState.MSG_LEARNED = 1202

-- Retail sound sequences (pokeheartgold include/constants/sndseq.h).
BattleEvolutionState.SEQ_GS_SHINKA = 1011
BattleEvolutionState.SEQ_ME_LVUP = 1184
BattleEvolutionState.SE_W025 = 1528
BattleEvolutionState.SE_W060C = 1529
BattleEvolutionState.SE_W062 = 1530
BattleEvolutionState.SE_W080 = 1531
BattleEvolutionState.SE_SELECT = 1500

-- Retail scene flags per caller: battle passes 3
-- (CAN_CANCEL | PRINT_WHAT), field level-up passes 1 (CAN_CANCEL),
-- field stone/item passes 0, and trade passes 4 (neither low bit set).
BattleEvolutionState.SOURCES = { battle = 3, field_level = 1, field_item = 0, trade = 4 }

---@param value unknown
---@return unknown detached copy without shared mutable state
local function copyValue(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[key] = copyValue(item)
  end
  return out
end

-- Builds the data-only visual asset manifest the renderer owners must
-- provide. Narc/member/slot selections mirror EvolutionScene_InitGraphics
-- and EvolutionScene_InitSprites; pokepic slots resolve per subject
-- species and form exactly as GetPokemonSpriteCharAndPlttNarcIds does
-- (retail builds both pictures from the subject's form); the
-- particle-scene resource carries the retail emitter sequence; the
-- summary pages name gEvolutionSummaryPages for the full-set path.
---@param species string committed subject species key
---@param form integer committed subject form index
---@param newSpecies string? staged target species key, nil while ineligible
---@return table<string, unknown> data-only asset manifest
local function buildAssets(species, form, newSpecies)
  local pokepicNew = nil
  if newSpecies ~= nil then
    pokepicNew = { species = newSpecies, form = form }
  end
  return {
    mainBg = {
      narc = "a_1_1_5",
      charMember = 0,
      scrnMember = 1,
      paletteMember = 8,
      paletteSlot = 0x40,
      frame = "user_frame",
      framePaletteNarc = "a_0_3_8",
      fontNarc = "graphic_font",
      fontMember = 8,
      fontSlot = 0xB0,
    },
    subBg = {
      narc = "a_2_3_7",
      topCharMember = 16,
      topScrnMember = 17,
      menuCharMember = 1,
      menuScrnMember = 10,
      paletteMembers = { 0, 15 },
      fontMember = 9,
    },
    cursor = {
      narc = "a_2_3_7",
      plttMember = 11,
      charMember = 12,
      cellMember = 13,
      animMember = 14,
    },
    pokepic = {
      variant = 2,
      old = { species = species, form = form },
      new = pokepicNew,
    },
    particles = {
      resource = 0,
      emitterSequence = { { 0 }, { 1, 2, 7, 8, 9, 11 }, { 3, 4, 5, 6, 10 }, { 12 } },
    },
    window = {
      left = 0,
      top = 0,
      right = 255,
      bottom = 160,
      narrowStep = 2,
      narrowTop = 40,
      narrowBottom = 120,
    },
    affine = {
      scaleOscillation = 16,
      scaleStep = 8,
      maxScaleStep = 64,
    },
    summary = {
      pages = { 1, 4, 0, 0 },
      mode = 2,
    },
  }
end

---@param opts { mon: table<string, unknown>, context: table<string, unknown>, catalog: table<string, unknown>, source: string?, particles: table<string, unknown>?, splRandomState: table<string, integer>? } presentation options with optional retail source origin and compiled SPL resources
---@return BattleEvolutionState
function BattleEvolutionState.new(opts)
  assert(type(opts) == "table", "evolution presentation requires options")
  assert(type(opts.mon) == "table", "evolution presents its committed subject")
  assert(type(opts.context) == "table", "evolution presents its trigger context")
  assert(opts.catalog ~= nil, "evolution presents through its mon catalog")
  local source = opts.source or "battle"
  local flags = BattleEvolutionState.SOURCES[source]
  assert(flags ~= nil, "evolution sources name battle, field_level, field_item, or trade")
  local subject = opts.mon --[[@as table<string, unknown>]]
  assert(type(subject.species) == "string", "evolution subjects carry their species key")
  assert(type(subject.form) == "number", "evolution subjects carry their form index")
  local flow = EvolutionFlow.start(copyValue(opts.mon), opts.context, opts.catalog)
  local self = setmetatable({
    _flow = flow,
    _source = source,
    _flags = flags,
    _printWhat = source == "battle",
    _canCancel = false,
    _species = subject.species,
    _form = subject.form,
    _newSpecies = nil,
    _assets = nil,
    _accepted = false,
    _phase = "entry",
    _beat = "entry",
    _clock = 0,
    _prompt = nil,
    _learnStep = nil,
    _replacementStep = nil,
    _summaryMoveSlot = nil,
    _cancelReason = nil,
    _effects = {},
    _paletteRequestId = 0,
    _paletteChannels = {},
    _printerPending = false,
    _printerMessageId = nil,
    _particles = opts.particles ~= nil and require("game.hgss.src.battle.BattleEvolutionParticles").new({
      set = opts.particles,
      emitterPosition = { x = 0, y = 0x560 / 4096, z = 0 },
      splRandomState = opts.splRandomState,
    }) or nil,
    _result = nil,
    _taken = false,
    _disposed = false,
  }, BattleEvolutionState)
  if flow == nil then
    self:_settle({ kind = "choice", choice = { kind = "evolution", evolved = false, reason = "ineligible" } })
    return self
  end
  -- The opening domain prompt names the staged target and the rule's
  -- cancel policy through the public step surface; the state never
  -- answers it here. Effective cancel additionally requires the source
  -- to permit it (battle and field level-up); trade and stone/item
  -- sources never cancel.
  local opening = EvolutionFlow.step(flow)
  assert(opening.prompt == "confirm_evolution", "the staged flow opens on its confirmation")
  assert(type(opening.species) == "string", "the staged flow names its target species")
  self._newSpecies = opening.species
  self._assets = buildAssets(self._species, self._form, self._newSpecies)
  local newSubject = copyValue(subject)
  newSubject.species = self._newSpecies
  self._pokepicSelectors = {
    old = SummaryModel.portraitSelectorFor(opts.catalog, subject),
    new = SummaryModel.portraitSelectorFor(opts.catalog, newSubject),
  }
  self._canCancel = opening.canCancel == true and (source == "battle" or source == "field_level")
  self:_recordPalette(
    { from = 16, to = 0, rate = 1, color = "black" },
    { from = 16, to = 0, duration = 0, color = "black" },
    "entry"
  )
  return self
end

-- Records one sequenced effect request for the audio/visual owners. The
-- sequence owns order and timing; emission belongs to production.
---@param effect table<string, unknown> effect request under sequencing
function BattleEvolutionState:_record(effect)
  self._effects[#self._effects + 1] = effect
  if effect.kind == "message" then
    assert(not self._printerPending, "source message printers do not overlap")
    self._printerPending = true
    self._printerMessageId = assert(effect.msg, "EvolutionScene messages carry their source id") --[[@as integer]]
  end
  if effect.kind == "particles" and self._particles ~= nil then
    for _, emitterId in
      ipairs(effect.emitters --[[@as integer[] ]])
    do
      self._particles:createEmitter(emitterId)
    end
  end
end

---@param scene table<string, unknown>? source background palette fade
---@param pictures table<string, unknown>? source Pokepic palette fade
---@param phase string? source scene beat owning the fade
function BattleEvolutionState:_recordPalette(scene, pictures, phase)
  self._paletteRequestId = self._paletteRequestId + 1
  local requestId = self._paletteRequestId
  local requests = {}
  if scene ~= nil then
    self._paletteChannels.scene = requestId
    requests.scene = requestId
  end
  if pictures ~= nil then
    self._paletteChannels.pictures = requestId
    requests.pictures = requestId
  end
  self:_record({
    kind = "palette",
    phase = phase,
    channels = { scene = scene, pictures = pictures },
    requestIds = requests,
  })
end

---@return boolean pending source scene palette request
function BattleEvolutionState:_scenePalettePending()
  return self._paletteChannels.scene ~= nil
end

-- Settles the complete evolution choice exactly once.
---@param result table<string, unknown> settled choice record under latching
function BattleEvolutionState:_settle(result)
  if self._result ~= nil then
    return
  end
  self._result = result
  self._phase = "settled"
  self._clock = 0
  self._prompt = nil
end

-- Walks the accepted flow to its next source beat: one free-slot message,
-- one pending full-set move, or the terminal descriptor. The settled
-- capture carries the whole staged result. A full set pauses with the
-- retail battery (wants-to-learn, however
-- four-moves, should-delete, which-move) plus the summary-pages hook for the visual
-- owner.
function BattleEvolutionState:_walkAccepted()
  local flow = assert(self._flow, "accepted walks read their staged flow")
  local prompt = EvolutionFlow.step(flow)
  assert(type(prompt) == "table" and type(prompt.prompt) == "string", "accepted flows answer their prompt")
  if prompt.prompt == "learn_move" then
    self._phase = "wants_to_learn"
    self._clock = 0
    self._prompt = copyValue(prompt)
    return
  end
  if prompt.prompt == "move_learned" then
    self._phase = "learned"
    self._clock = 0
    self._learnedMove = copyValue(prompt)
    self:_record({
      kind = "message",
      phase = "learned",
      msg = BattleEvolutionState.MSG_LEARNED_FREE_SLOT,
      species = assert(self._newSpecies, "learned messages name the evolved species"),
      move = assert(prompt.move, "learned messages name the move"),
    })
    return
  end
  assert(prompt.prompt == "complete", "accepted flows end on their terminal descriptor")
  self._phase = "fade_out_ready"
  self._clock = 0
end

-- Accepts the transformation beat: the domain stages its choice and the
-- state sequences the retail completion evidence (oscillation-end and
-- widen beats, palette fades, new cry, congratulations) before walking
-- into learning or settlement.
function BattleEvolutionState:_acceptTransformation()
  local flow = assert(self._flow, "transformations accept their staged flow")
  EvolutionFlow.respond(flow, { choice = "accept" })
  self._accepted = true
  local newSpecies = assert(self._newSpecies, "accepts name their staged target")
  self:_record({ kind = "cry", phase = "transformation", species = newSpecies, form = self._form })
  self._phase = "new_mon_cry"
  self._clock = 0
end

-- EvolutionScene_Run advances the affine pair before polling B, so the
-- accepted cancel frame still owns one source scale step.
local function stepOscillationScale(self)
  if self._scaleOscillation % 2 == 0 then
    self._oldScale = math.max(0, self._oldScale - self._scaleStep)
    self._newScale = math.min(256, self._newScale + self._scaleStep)
    if self._oldScale == 0 then
      self._scaleOscillation = self._scaleOscillation + 1
    end
  else
    self._oldScale = math.min(256, self._oldScale + self._scaleStep)
    self._newScale = math.max(0, self._newScale - self._scaleStep)
    if self._newScale == 0 then
      self._scaleOscillation = self._scaleOscillation - 1
      if self._scaleStep < 64 then
        self._scaleStep = self._scaleStep * 2
      end
    end
  end
end

-- Cancels the unaccepted transformation under the source policy: the
-- domain stages nothing, the BGM stops, the old cry replays, and the
-- choice names its cancellation.
---@param reason string decline reason under settling
function BattleEvolutionState:_cancel(reason)
  local flow = assert(self._flow, "cancels answer their staged flow")
  assert(not self._accepted, "cancels decide before the transformation completes")
  assert(self._canCancel, "cancels honor the source policy")
  EvolutionFlow.respond(flow, { choice = "cancel" })
  self._phase = "cancel"
  self._beat = "cancel_fade_in"
  self._clock = 0
  self._cancelReason = reason
  self:_recordPalette({ from = 0, to = 16, rate = 0, color = "white" }, nil, "cancel")
end

---@param events table<integer, table<string, unknown>> semantic input batch under routing
function BattleEvolutionState:input(events)
  if self._disposed or self._result ~= nil or self._accepted then
    return
  end
  if self._flow == nil then
    return
  end
  assert(type(events) == "table", "evolution input arrives as an event list")
  for _, event in ipairs(events) do
    if self._result ~= nil or self._accepted then
      break
    end
    if type(event) ~= "table" or type(event.type) ~= "string" then
      break
    end
    -- Retail checks B during OSCILLATE alone: startup and window beats,
    -- entry, sequence, learn, and fanfare decide nothing here.
    if event.type == "cancel" and self._phase == "transformation" and self._beat == "oscillate" then
      if self._canCancel then
        stepOscillationScale(self)
        self:_cancel("cancelled")
      end
    end
  end
end

-- Advances the native sequence clock: entry prints its source-specific
-- prompt, the sequence starts the old picture's cry and progress message,
-- and the transformation follows the retail particle delay, window close,
-- affine exchange, and window open boundaries. Completing the transformation
-- accepts the staged choice and walks into learning or settlement; the
-- learning pause waits for an explicit answer and never advances on
-- ticks, while the fanfare pause waits out its small tick beat after
-- each learned move before continuing.
---@param ticks integer? source ticks under stepping, one when omitted
function BattleEvolutionState:stepSourceTick(ticks)
  if self._disposed or self._result ~= nil then
    return
  end
  if self._flow == nil then
    return
  end
  local count = ticks or 1
  assert(type(count) == "number" and count % 1 == 0 and count >= 0, "evolution ticks stay non-negative integers")
  for _ = 1, count do
    if
      self._result ~= nil
      or self._printerPending
      or self._phase == "learn"
      or self._phase == "stop_menu"
      or self._phase == "summary"
    then
      break
    end
    self._clock = self._clock + 1
    if self._phase == "cancel" and self._beat == "cancel_finish" and not self:_scenePalettePending() then
      self:_settle({
        kind = "choice",
        choice = { kind = "evolution", evolved = false, reason = assert(self._cancelReason) },
      })
    elseif self._phase == "cancel" and self._beat == "cancel_cry" then
      self._beat = "cancel_wait_message"
      self._clock = 0
      self:_record({
        kind = "message",
        phase = "cancel",
        msg = BattleEvolutionState.MSG_STOPPED,
        species = self._species,
        form = self._form,
      })
    elseif
      self._phase == "cancel"
      and self._beat == "cancel_wait_message"
      and self._clock >= BattleEvolutionState.CANCEL_MESSAGE_TICKS
    then
      self._beat = "cancel_finish"
      self._clock = 0
      self:_recordPalette(
        { from = 0, to = 16, rate = 1, color = "black" },
        { from = 0, to = 16, duration = 0, color = "black" },
        "cancel"
      )
    elseif self._phase == "entry" and self._clock >= BattleEvolutionState.ENTRY_TICKS then
      self._phase = "start"
      self._clock = 0
    elseif self._phase == "start" then
      if self._printWhat then
        self._phase = "print_what"
      else
        self._phase = "play_cry"
      end
      self._clock = 0
    elseif self._phase == "print_what" and not self:_scenePalettePending() then
      self._phase = "entry_what"
      self:_record({ kind = "message", phase = "entry", msg = BattleEvolutionState.MSG_WHAT })
    elseif self._phase == "wait_what" then
      self._phase = "play_cry"
      self._clock = 0
    elseif self._phase == "play_cry" and not self:_scenePalettePending() then
      self._phase = "sequence"
      self:_record({ kind = "cry", phase = "sequence", species = self._species, form = self._form })
      self:_record({
        kind = "message",
        phase = "sequence",
        msg = self._printWhat and BattleEvolutionState.MSG_EVOLVING or BattleEvolutionState.MSG_WHAT_COMBINED,
        species = self._species,
        form = self._form,
      })
    elseif self._phase == "sequence" then
      self._phase = "transformation"
      self._clock = 0
      self._beat = "particle_delay"
      self._windowTop = 0
      self._windowBottom = 160
      self._oldScale = 256
      self._newScale = 0
      self._scaleStep = 8
      self._scaleOscillation = 16
      self:_record({
        kind = "music_direct",
        phase = "sequence",
        seq = BattleEvolutionState.SEQ_GS_SHINKA,
        name = "SEQ_GS_SHINKA",
      })
    elseif self._phase == "stop_question_transition" then
      self._phase = "stop_message_ready"
      self._clock = 0
    elseif self._phase == "replacement_transition" then
      self._phase = "replacement_ready"
      self._clock = 0
    elseif self._phase == "retry_transition" then
      self._phase = "wants_to_learn"
      self._clock = 0
    elseif
      self._phase == "transformation"
      and self._beat == "particle_delay"
      and self._clock >= BattleEvolutionState.PARTICLE_DELAY_TICKS
    then
      self._beat = "narrow_window"
      self._clock = 0
      self:_record({
        kind = "particles",
        phase = "transformation",
        resource = 0,
        emitters = { 0 },
      })
      self:_recordPalette(nil, { from = 0, to = 16, duration = 4, color = "white" }, "transformation")
      self:_record({
        kind = "sound",
        phase = "transformation",
        se = BattleEvolutionState.SE_W025,
        name = "SEQ_SE_DP_W025",
      })
      self:_record({ kind = "window", phase = "transformation", op = "narrow" })
    elseif self._phase == "transformation" and self._beat == "narrow_window" then
      self._windowTop = math.min(40, self._windowTop + 2)
      self._windowBottom = math.max(120, self._windowBottom - 2)
      if self._clock >= BattleEvolutionState.NARROW_WINDOW_TICKS then
        self._beat = "oscillate"
        self._clock = 0
        self:_record({
          kind = "particles",
          phase = "transformation",
          resource = 0,
          emitters = { 1, 2, 7, 8, 9, 11 },
        })
        self:_record({
          kind = "sound",
          phase = "transformation",
          se = BattleEvolutionState.SE_W060C,
          name = "SEQ_SE_DP_W060C",
        })
        self:_record({
          kind = "affine",
          phase = "transformation",
          op = "oscillate_start",
          scaleOscillation = 16,
          scaleStep = 8,
          maxScaleStep = 64,
        })
      end
    elseif self._phase == "transformation" and self._beat == "oscillate" then
      stepOscillationScale(self)
      if
        (self._particles ~= nil and not self._particles:isActive())
        or (self._particles == nil and self._clock >= BattleEvolutionState.OSCILLATION_TICKS)
      then
        self._beat = "widen_window"
        self._clock = 0
        self:_record({
          kind = "particles",
          phase = "transformation",
          resource = 0,
          emitters = { 3, 4, 5, 6, 10 },
        })
        self:_record({
          kind = "sound",
          phase = "transformation",
          se = BattleEvolutionState.SE_W062,
          name = "SEQ_SE_DP_W062",
        })
        self:_recordPalette({ from = 0, to = 16, rate = 2, color = "white" }, nil, "transformation")
      end
    elseif self._phase == "transformation" and self._beat == "widen_window" then
      self._windowTop = math.max(0, self._windowTop - 2)
      self._windowBottom = math.min(160, self._windowBottom + 2)
      if self._clock >= BattleEvolutionState.WIDEN_WINDOW_TICKS and not self:_scenePalettePending() then
        self._beat = "complete"
        self:_record({ kind = "particles", phase = "transformation", resource = 0, emitters = { 12 } })
        self:_recordPalette(
          { from = 16, to = 0, rate = 4, color = "white" },
          { from = 16, to = 0, duration = 3, color = "white" },
          "transformation"
        )
        self:_record({
          kind = "sound",
          phase = "transformation",
          se = BattleEvolutionState.SE_W080,
          name = "SEQ_SE_DP_W080",
        })
        self:_record({ kind = "window", phase = "transformation", op = "widen" })
        self._beat = "particle_fade"
      end
    elseif
      self._phase == "transformation"
      and self._beat == "particle_fade"
      and (self._particles == nil or not self._particles:isActive())
      and not self:_scenePalettePending()
    then
      self._beat = "complete"
      self:_acceptTransformation()
    elseif self._phase == "new_mon_cry" then
      self._phase = "evolved_message"
      self._clock = 0
      self:_record({
        kind = "message",
        phase = "transformation",
        msg = BattleEvolutionState.MSG_EVOLVED,
        species = assert(self._newSpecies),
        form = self._form,
      })
    elseif self._phase == "evolved_message" and self._clock >= 40 then
      self._phase = "try_learn_move"
      self._clock = 0
    elseif self._phase == "try_learn_move" then
      self:_walkAccepted()
    elseif self._phase == "fade_out_ready" then
      self._phase = "finish"
      self:_recordPalette(
        { from = 0, to = 16, rate = 1, color = "black" },
        { from = 0, to = 16, duration = 0, color = "black" },
        "finish"
      )
    elseif self._phase == "finish" and not self:_scenePalettePending() then
      if self._particles ~= nil then
        self._particles:clear()
      end
      local flow = assert(self._flow, "finished sequences retain their staged flow")
      local captured = EvolutionFlow.capture(flow)
      assert(type(captured) == "table", "completed flows capture their staged result")
      self:_settle({
        kind = "choice",
        choice = {
          kind = "evolution",
          evolved = true,
          staged = {
            mon = captured.mon,
            additionalMons = captured.additionalMons or {},
            inventoryDeltas = captured.inventoryDeltas or {},
          },
        },
      })
    elseif self._phase == "wants_to_learn" then
      local prompt = assert(self._prompt, "move offers retain their pending opportunity")
      self._phase = "learn_messages"
      self._learnStep = 1
      self._clock = 0
      self:_record({
        kind = "message",
        phase = "learn",
        msg = BattleEvolutionState.MSG_WANTS_TO_LEARN,
        species = assert(self._newSpecies),
        move = prompt.move,
      })
    elseif self._phase == "stop_message_ready" then
      local prompt = assert(self._prompt, "the stop question retains its pending move")
      self._phase = "decline_stop_message"
      self._clock = 0
      self:_record({ kind = "message", phase = "learn", msg = BattleEvolutionState.MSG_STOP_TRYING, move = prompt.move })
    elseif self._phase == "stop_message_wait" and self._clock >= 1 then
      self._phase = "stop_menu_ready"
      self._clock = 0
    elseif self._phase == "stop_menu_ready" then
      self._phase = "stop_menu"
      local prompt = assert(self._prompt, "the stop menu retains its pending move")
      self:_record({ kind = "menu", phase = "learn", options = { 1186, 1187 }, move = prompt.move })
    elseif self._phase == "learned_transition" then
      if self._replacementStep == 7 then
        self._replacementStep = nil
        self._phase = "fanfare"
      else
        self._phase = "learned"
      end
      self._clock = 0
    elseif self._phase == "learned" and self._clock >= 30 then
      self._learnedMove = nil
      self._phase = "try_learn_move"
      self._clock = 0
    elseif self._phase == "fanfare" and self._clock >= BattleEvolutionState.FANFARE_TICKS then
      self._phase = "try_learn_move"
      self._clock = 0
    elseif self._phase == "decline_wait" and self._clock >= 30 then
      self._phase = "try_learn_move"
      self._clock = 0
    elseif self._phase == "learn_messages" and self._learnStep == 1 and self._clock >= 30 then
      self._learnStep = 2
      self._clock = 0
    elseif self._phase == "learn_messages" and self._learnStep == 2 then
      self._learnStep = 3
      self._clock = 0
      self:_record({
        kind = "message",
        phase = "learn",
        msg = BattleEvolutionState.MSG_KNOWS_FOUR,
        species = assert(self._newSpecies),
      })
    elseif self._phase == "learn_messages" and self._learnStep == 3 and self._clock >= 30 then
      self._learnStep = 4
      self._clock = 0
    elseif self._phase == "learn_messages" and self._learnStep == 4 then
      self._learnStep = 5
      self._clock = 0
      self:_record({ kind = "message", phase = "learn", msg = BattleEvolutionState.MSG_SHOULD_DELETE })
    elseif self._phase == "learn_messages" and self._learnStep == 5 and self._clock >= 1 then
      self._learnStep = 6
      self._clock = 0
    elseif self._phase == "learn_messages" and self._learnStep == 6 then
      self._phase = "learn"
      self._learnStep = nil
      local prompt = assert(self._prompt, "the menu opens for the pending move")
      self:_record({ kind = "menu", phase = "learn", options = { 1181, 1182 } })
      self:_record({
        kind = "summary",
        phase = "learn",
        pages = { 1, 4, 0, 0 },
        mode = 2,
        move = prompt.move,
        moveToLearn = prompt.move,
        currentMoves = copyValue(prompt.currentMoves),
        species = assert(self._newSpecies),
        form = self._form,
      })
    elseif self._phase == "replacement_ready" then
      self._phase = "replacement_messages"
      self._replacementStep = 1
      self._clock = 0
      self:_record({ kind = "message", phase = "learn", msg = BattleEvolutionState.MSG_POOF })
    elseif self._phase == "replacement_messages" and self._replacementStep == 1 and self._clock >= 30 then
      self._replacementStep = 2
      self._clock = 0
    elseif self._phase == "replacement_messages" and self._replacementStep == 2 then
      self._replacementStep = 3
      self._clock = 0
      self:_record({
        kind = "message",
        phase = "learn",
        msg = BattleEvolutionState.MSG_FORGOT,
        species = assert(self._newSpecies),
        move = assert(self._forgottenMove),
      })
    elseif self._phase == "replacement_messages" and self._replacementStep == 3 and self._clock >= 30 then
      self._replacementStep = 4
      self._clock = 0
    elseif self._phase == "replacement_messages" and self._replacementStep == 4 then
      self._replacementStep = 5
      self._clock = 0
      self:_record({ kind = "message", phase = "learn", msg = BattleEvolutionState.MSG_AND })
    elseif self._phase == "replacement_messages" and self._replacementStep == 5 and self._clock >= 30 then
      self._replacementStep = 6
      self._clock = 0
    elseif self._phase == "replacement_messages" and self._replacementStep == 6 then
      self._replacementStep = 7
      self._clock = 0
      self:_record({
        kind = "message",
        phase = "learn",
        msg = BattleEvolutionState.MSG_LEARNED,
        species = assert(self._newSpecies),
        move = assert(self._learnedMoveKey),
      })
    end
  end
end

-- The retail task draws its particle system every source frame, including
-- while text/audio/palette gates hold the evolution state machine.
---@param ticks integer? presentation ticks under stepping, one when omitted
function BattleEvolutionState:stepPresentationSourceTick(ticks)
  if self._disposed then
    return
  end
  local count = ticks or 1
  assert(
    type(count) == "number" and count % 1 == 0 and count >= 0,
    "evolution presentation ticks stay non-negative integers"
  )
  if self._particles ~= nil then
    for _ = 1, count do
      self._particles:advance()
    end
  end
end

-- Answers the pending learned move: replace names the held zero-based
-- slot taking the incoming move, decline keeps the held set. A menu
-- confirm voices SELECT for the audio owner. Replace sequences the
-- retail summary beats (poof, forgot, and, learned) plus the LVUP
-- fanfare wait before continuing; decline sequences the give-up beats
-- and continues at once. Either answer advances to the next pending
-- move or settles the sequence.
---@param reply { choice: string, slot: integer?, stopQuestionPresented: boolean? } replace-or-decline answer under applying
function BattleEvolutionState:answerLearn(reply)
  assert(not self._disposed, "answers read a live sequence")
  assert(self._result == nil, "answers decide before settlement")
  assert(not self._printerPending, "learning answers wait for the source printer")
  assert(
    (self._phase == "learn" or self._phase == "summary" or self._phase == "summary_in" or self._phase == "stop_menu")
      and self._prompt ~= nil,
    "learning answers name the open prompt"
  )
  assert(type(reply) == "table", "learning answers arrive as a record")
  local flow = assert(self._flow, "learning answers read their staged flow")
  local prompt = assert(self._prompt, "learning answers read their open prompt")
  local newSpecies = assert(self._newSpecies, "learning answers name their evolved species")
  if reply.choice == "decline" then
    assert(reply.stopQuestionPresented == true, "declines answer the rendered stop-trying menu")
    EvolutionFlow.respond(flow, { choice = "decline" })
    self:_record({
      kind = "message",
      phase = "learn",
      msg = BattleEvolutionState.MSG_DID_NOT_LEARN,
      species = newSpecies,
      move = prompt.move,
    })
    self._prompt = nil
    self._phase = "decline_wait"
    self._clock = 0
    return
  end
  if reply.choice == "replace" then
    assert(
      type(reply.slot) == "number" and reply.slot % 1 == 0 and reply.slot >= 0,
      "replacements name a held zero-based move slot"
    )
    local currentMoves = assert(prompt.currentMoves, "learning prompts carry their held moves")
    local forgotten = currentMoves[reply.slot + 1]
    assert(type(forgotten) == "string", "replacements name a held move slot")
    EvolutionFlow.respond(flow, { choice = "replace", slot = reply.slot })
    self._forgottenMove = forgotten
    self._learnedMoveKey = prompt.move
    self._prompt = nil
    self._phase = "replacement_transition"
    self._replacementStep = nil
    self._clock = 0
    return
  end
  error("learning replies decline or replace the incoming move", 0)
end

function BattleEvolutionState:beginLearnSummary()
  assert(self._phase == "learn" and self._prompt ~= nil, "the full-set menu opens a pending move summary")
  assert(not self._printerPending, "the full-set message finishes before Summary opens")
  self._phase = "summary_out"
  self:_recordPalette(
    { from = 0, to = 16, rate = 1, color = "black" },
    { from = 0, to = 16, duration = 0, color = "black" },
    "summary"
  )
end

function BattleEvolutionState:finishLearnSummary(slot)
  assert(self._phase == "summary" and self._prompt ~= nil, "Summary returns a selection while it owns learning")
  assert(
    type(slot) == "number" and slot % 1 == 0 and slot >= 0 and slot <= 4,
    "Summary returns move slots zero through four"
  )
  self._summaryMoveSlot = slot
  self._phase = "summary_in"
  self:_recordPalette(
    { from = 16, to = 0, rate = 1, color = "black" },
    { from = 16, to = 0, duration = 0, color = "black" },
    "summary"
  )
end

---@param channel "scene"|"pictures" source palette manager
---@param requestId integer source request identity
function BattleEvolutionState:completePaletteFade(channel, requestId)
  assert(channel == "scene" or channel == "pictures", "palette acknowledgements name their source manager")
  assert(type(requestId) == "number", "palette acknowledgements carry their source request id")
  if self._paletteChannels[channel] ~= requestId then
    return
  end
  self._paletteChannels[channel] = nil
  if channel ~= "scene" then
    return
  end
  if self._phase == "cancel" and self._beat == "cancel_fade_in" then
    self._oldScale = 256
    self._newScale = 0
    self._scaleOscillation = 0
    self._windowTop = 0
    self._windowBottom = 160
    self:_record({ kind = "affine", phase = "cancel", op = "restore" })
    self:_record({ kind = "window", phase = "cancel", op = "widen" })
    self:_recordPalette(
      { from = 16, to = 0, rate = 0, color = "white" },
      { from = 16, to = 0, duration = 0, color = "white" },
      "cancel"
    )
    self:_record({
      kind = "stop_bgm",
      phase = "cancel",
      seq = BattleEvolutionState.SEQ_GS_SHINKA,
      name = "SEQ_GS_SHINKA",
    })
    if self._particles ~= nil then
      self._particles:clear()
    end
    self._beat = "cancel_restore"
    self._clock = 0
    return
  end
  if self._phase == "cancel" and self._beat == "cancel_restore" then
    self._beat = "cancel_cry"
    self._clock = 0
    self:_record({ kind = "cry", phase = "cancel", species = self._species, form = self._form })
    return
  end
  if self._phase == "cancel" and self._beat == "cancel_finish" then
    return
  end
  if self._phase == "summary_out" then
    self._phase = "summary"
    return
  end
  if self._phase ~= "summary_in" then
    return
  end
  local slot = assert(self._summaryMoveSlot, "the Summary return fade carries its selected slot")
  self._summaryMoveSlot = nil
  if slot == 4 then
    self._phase = "stop_question_transition"
    self._clock = 0
  else
    self:answerLearn({ choice = "replace", slot = slot })
    self._phase = "replacement_transition"
    self._clock = 0
  end
end

function BattleEvolutionState:completeMessage()
  assert(self._printerPending, "message completion requires an active source printer")
  self._printerPending = false
  local messageId = assert(self._printerMessageId, "the active printer retains its source message id")
  self._printerMessageId = nil
  if self._phase == "entry_what" and messageId == BattleEvolutionState.MSG_WHAT then
    self._phase = "wait_what"
    self._clock = 0
    return
  end
  if self._phase == "decline_stop_message" and messageId == BattleEvolutionState.MSG_STOP_TRYING then
    self._phase = "stop_message_wait"
    self._clock = 0
    return
  end
  if messageId == BattleEvolutionState.MSG_LEARNED_FREE_SLOT or messageId == BattleEvolutionState.MSG_LEARNED then
    if messageId == BattleEvolutionState.MSG_LEARNED_FREE_SLOT then
      local flow = assert(self._flow, "free-slot printer completion advances its staged learning flow")
      EvolutionFlow.respond(flow, { choice = "continue" })
    end
    self._phase = "learned_transition"
    self._clock = 0
  end
end

function BattleEvolutionState:menuSelect()
  assert(self._phase == "learn" or self._phase == "stop_menu", "menu selection belongs to an evolution menu")
  self:_record({
    kind = "sound",
    phase = "learn",
    se = BattleEvolutionState.SE_SELECT,
    name = "SEQ_SE_DP_SELECT",
  })
end

function BattleEvolutionState:beginStopQuestion()
  assert(not self._printerPending, "move option text finishes before the stop question")
  assert(
    (self._phase == "learn" or self._phase == "summary" or self._phase == "summary_in") and self._prompt ~= nil,
    "the stop question belongs to a pending move"
  )
  self._phase = "stop_question_transition"
  self._clock = 0
end

function BattleEvolutionState:retryLearn()
  assert(self._phase == "stop_menu" and self._prompt ~= nil, "the stop menu can return to the move offer")
  assert(not self._printerPending, "the stop-trying question finishes before retry")
  self._phase = "retry_transition"
  self._clock = 0
end

---@return table<string, unknown>? pending learned-move prompt, nil outside the learning pause
function BattleEvolutionState:learnPrompt()
  if
    (self._phase ~= "learn" and self._phase ~= "summary" and self._phase ~= "summary_in" and self._phase ~= "stop_menu")
    or self._prompt == nil
  then
    return nil
  end
  return copyValue(self._prompt)
end

---@return table<string, unknown> drawable evolution record (renderer-agnostic data)
function BattleEvolutionState:draw()
  local assets = nil
  if self._assets ~= nil then
    assets = copyValue(self._assets)
  end
  local events, emitters = {}, {}
  for _, effect in ipairs(self._effects) do
    if effect.kind == "particles" then
      for _, emitterId in
        ipairs(effect.emitters --[[@as integer[] ]])
      do
        emitters[#emitters + 1] = emitterId
      end
    elseif effect.kind == "message" then
      events[#events + 1] = { kind = "message", id = effect.msg }
    elseif effect.kind == "cry" then
      events[#events + 1] = { kind = "cry", species = effect.species, form = effect.form }
    elseif effect.kind == "music_direct" then
      events[#events + 1] = { kind = "music", sequence = effect.seq }
    elseif effect.kind == "stop_bgm" then
      events[#events + 1] = { kind = "music_stop", sequence = effect.seq }
    elseif effect.kind == "sound" then
      events[#events + 1] = { kind = "sound", sequence = effect.se }
    elseif effect.kind == "window" then
      events[#events + 1] = { kind = "window", op = effect.op }
    end
  end
  local window = { left = 0, top = self._windowTop or 0, right = 255, bottom = self._windowBottom or 160 }
  local pictureCenter = { x = 128, y = 80 }
  local particleSet = self._particles ~= nil and { identity = "evolution", resource = 0, emitters = emitters } or nil
  local scene = nil
  if self._assets ~= nil then
    scene = {
      main = {
        kind = "main",
        oldSpecies = self._species,
        newSpecies = self._newSpecies,
        pictureCenter = copyValue(pictureCenter),
        window = copyValue(window),
        oldPictureScale = self._oldScale or 256,
        newPictureScale = self._newScale or 0,
      },
      sub = { kind = "sub" },
      particles = particleSet or { identity = "evolution", resource = 0, emitters = emitters },
      events = events,
    }
  end
  return {
    kind = "evolution",
    phase = self._phase,
    beat = self._beat,
    clock = self._clock,
    source = self._source,
    flags = self._flags,
    printWhat = self._printWhat,
    species = self._species,
    form = self._form,
    newSpecies = self._newSpecies,
    assets = assets,
    pokepicSelectors = self._pokepicSelectors ~= nil and copyValue(self._pokepicSelectors) or nil,
    scene = scene,
    presentation = {
      window = window,
      oldPictureScale = self._oldScale or 256,
      newPictureScale = self._newScale or 0,
      pictureCenter = pictureCenter,
      pokepicSelectors = self._pokepicSelectors ~= nil and copyValue(self._pokepicSelectors) or nil,
      particleSystems = self._particles ~= nil and self._particles:systems() or {},
    },
    learnPrompt = self:learnPrompt(),
    learnedMove = self._learnedMove ~= nil and copyValue(self._learnedMove) or nil,
  }
end

---@return table<string, unknown> evolution presentation status
function BattleEvolutionState:status()
  return {
    active = not self._disposed and self._result == nil,
    kind = "evolution",
    phase = self._phase,
    source = self._source,
    flags = self._flags,
    printWhat = self._printWhat,
    canCancel = self._flow ~= nil and self._canCancel or nil,
    learnPending = self._phase == "learn" and self._prompt ~= nil,
    effects = #self._effects,
    palettePending = next(self._paletteChannels) ~= nil,
    paletteChannels = {
      scene = self._paletteChannels.scene,
      pictures = self._paletteChannels.pictures,
    },
    printerPending = self._printerPending,
  }
end

---@return table<integer, table<string, unknown>> sequenced effect requests in order (read-only evidence)
function BattleEvolutionState:effects()
  local out = {}
  for _, effect in ipairs(self._effects) do
    out[#out + 1] = copyValue(effect)
  end
  return out
end

---@return table<string, unknown>? settled evolution choice, exactly once
function BattleEvolutionState:takeResult()
  if self._disposed or self._result == nil or self._taken then
    return nil
  end
  self._taken = true
  return self._result
end

-- Idempotent release of the presentation lifetime: a settled result never
-- reports after disposal, and an unsettled sequence simply ends
-- unsettled without publishing anything.
function BattleEvolutionState:dispose()
  if self._particles ~= nil then
    self._particles:clear()
  end
  self._disposed = true
end

return BattleEvolutionState
