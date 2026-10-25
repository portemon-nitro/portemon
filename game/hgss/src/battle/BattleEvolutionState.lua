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
-- Retail reference: tmp/refs/pokeheartgold/src/evolution_scene.c. The
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
--   TRY_LEARN_MOVE battery (1193/1194/1195/1196, summary pages
--     {1,4,0,0} for the full-set replacement path, 1199/1200
--     /1201/1202 plus SEQ_ME_LVUP fanfare wait after learning,
--     1197/1198 after giving up)                            -> "learn"/"fanfare"
--   CANCEL (StopBGM SHINKA, old cry, message 919)           -> cancel beat
-- The sequence starts on its own: entry runs its music beat, the old
-- picture animates with its cry, and the transformation beat follows
-- without any confirmation gate. Only the transformation beat honors
-- cancel input (retail checks B during OSCILLATE alone); entry, sequence,
-- learn, fanfare, key release, focus loss, and teardown decide nothing.
-- Two deliberate compressions stay: free move slots fill silently inside
-- the domain step with no presentation beats (retail prints its battle
-- "learned" copy per append), and the two full-set menus plus the
-- summary screen collapse into one replace-or-decline answer, with the
-- summary pages hook recorded as evidence for the visual owner.

local EvolutionFlow = require("libs.hgss.src.mons.EvolutionFlow")

---@class BattleEvolutionState
---@field _flow table<string, unknown>? single staged domain flow, nil while ineligible
---@field _source string presentation origin: battle, field_level, field_item, or trade
---@field _flags integer retail scene flags derived from the source
---@field _printWhat boolean retail PRINT_WHAT policy derived from the source
---@field _canCancel boolean effective cancel policy: domain rule AND source permits
---@field _species string committed subject species key
---@field _form integer committed subject form index (retail voices both cries and builds both pictures from this form)
---@field _newSpecies string? staged target species key, nil while ineligible
---@field _assets table<string, unknown>? data-only visual asset manifest, nil while ineligible
---@field _accepted boolean true once the transformation completed and the choice is accepted
---@field _phase string current presentation phase
---@field _clock integer ticks spent in the current phase
---@field _prompt table<string, unknown>? pending learned-move prompt under answering
---@field _effects table<integer, table<string, unknown>> sequenced effect requests in order
---@field _result table<string, unknown>? settled choice record
---@field _taken boolean result consumed
---@field _disposed boolean
local BattleEvolutionState = {}
BattleEvolutionState.__index = BattleEvolutionState

BattleEvolutionState.ENTRY_TICKS = 2
BattleEvolutionState.SEQUENCE_TICKS = 4
BattleEvolutionState.TRANSFORMATION_TICKS = 2
BattleEvolutionState.FANFARE_TICKS = 2

-- Retail msg_0197 indices (pokeheartgold msgdata/msg/msg_0197.gmm).
BattleEvolutionState.MSG_WHAT_COMBINED = 915
BattleEvolutionState.MSG_WHAT = 916
BattleEvolutionState.MSG_EVOLVING = 917
BattleEvolutionState.MSG_EVOLVED = 918
BattleEvolutionState.MSG_STOPPED = 919
BattleEvolutionState.MSG_WANTS_TO_LEARN = 1193
BattleEvolutionState.MSG_KNOWS_FOUR = 1194
BattleEvolutionState.MSG_SHOULD_DELETE = 1195
BattleEvolutionState.MSG_WHICH_MOVE = 1196
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

---@param opts { mon: table<string, unknown>, context: table<string, unknown>, catalog: table<string, unknown>, source: string? } presentation options with optional retail source origin
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
    _clock = 0,
    _prompt = nil,
    _effects = {},
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
  self._canCancel = opening.canCancel == true and (source == "battle" or source == "field_level")
  -- Retail START runs its music beat via PlayBGMDirect, then the PRINT_WHAT
  -- state shows 916 before the cry beat whenever the source prints What.
  self:_record({
    kind = "music_direct",
    phase = "entry",
    seq = BattleEvolutionState.SEQ_GS_SHINKA,
    name = "SEQ_GS_SHINKA",
  })
  if self._printWhat then
    self:_record({ kind = "message", phase = "entry", msg = BattleEvolutionState.MSG_WHAT })
  end
  return self
end

-- Records one sequenced effect request for the audio/visual owners. The
-- sequence owns order and timing; emission belongs to production.
---@param effect table<string, unknown> effect request under sequencing
function BattleEvolutionState:_record(effect)
  self._effects[#self._effects + 1] = effect
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

-- Walks the accepted flow to its next pause: one pending learned move or
-- the terminal descriptor. Free move slots fill silently inside the
-- domain step; the settled capture carries the whole staged result. A
-- full set pauses with the retail battery (wants-to-learn, however
-- four-moves, should-delete, which-move) plus the summary-pages hook for the visual
-- owner; silent fills and the final settlement record no extra messages.
function BattleEvolutionState:_walkAccepted()
  local flow = assert(self._flow, "accepted walks read their staged flow")
  local prompt = EvolutionFlow.step(flow)
  assert(type(prompt) == "table" and type(prompt.prompt) == "string", "accepted flows answer their prompt")
  if prompt.prompt == "learn_move" then
    self._phase = "learn"
    self._clock = 0
    self._prompt = copyValue(prompt)
    local newSpecies = assert(self._newSpecies, "learning answers name their evolved species")
    self:_record({
      kind = "message",
      phase = "learn",
      msg = BattleEvolutionState.MSG_WANTS_TO_LEARN,
      species = newSpecies,
      move = prompt.move,
    })
    self:_record({
      kind = "message",
      phase = "learn",
      msg = BattleEvolutionState.MSG_KNOWS_FOUR,
      species = newSpecies,
    })
    self:_record({ kind = "message", phase = "learn", msg = BattleEvolutionState.MSG_SHOULD_DELETE })
    self:_record({ kind = "message", phase = "learn", msg = BattleEvolutionState.MSG_WHICH_MOVE })
    self:_record({
      kind = "summary",
      phase = "learn",
      pages = { 1, 4, 0, 0 },
      mode = 2,
      move = prompt.move,
      moveToLearn = prompt.move,
      currentMoves = copyValue(prompt.currentMoves),
      species = newSpecies,
      form = self._form,
    })
    return
  end
  assert(prompt.prompt == "complete", "accepted flows end on their terminal descriptor")
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
  self:_record({
    kind = "particles",
    phase = "transformation",
    resource = 0,
    emitters = { 12 },
  })
  self:_record({
    kind = "sound",
    phase = "transformation",
    se = BattleEvolutionState.SE_W080,
    name = "SEQ_SE_DP_W080",
  })
  self:_record({ kind = "window", phase = "transformation", op = "widen" })
  self:_record({ kind = "palette", phase = "transformation" })
  self:_record({ kind = "cry", phase = "transformation", species = newSpecies, form = self._form })
  -- The WAIT 3 inside 918 voices SEQ_ME_SHINKAOME for the audio owner;
  -- the nickname/species placeholders resolve from the evolved subject.
  self:_record({
    kind = "message",
    phase = "transformation",
    msg = BattleEvolutionState.MSG_EVOLVED,
    species = newSpecies,
    form = self._form,
  })
  self:_walkAccepted()
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
  self:_record({
    kind = "stop_bgm",
    phase = "transformation",
    seq = BattleEvolutionState.SEQ_GS_SHINKA,
    name = "SEQ_GS_SHINKA",
  })
  self:_record({ kind = "cry", phase = "transformation", species = self._species, form = self._form })
  self:_record({
    kind = "message",
    phase = "transformation",
    msg = BattleEvolutionState.MSG_STOPPED,
    species = self._species,
    form = self._form,
  })
  self:_settle({ kind = "choice", choice = { kind = "evolution", evolved = false, reason = reason } })
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
    -- Retail checks B during OSCILLATE alone: entry, sequence, learn,
    -- fanfare, and every foreign edge decide nothing here.
    if event.type == "cancel" and self._phase == "transformation" then
      if self._canCancel then
        self:_cancel("cancelled")
      end
    end
  end
end

-- Advances the native sequence clock: entry runs its music beat, the
-- sequence runs the old-picture animation with its cry and progress
-- message, and the transformation beat runs the particle/window/affine
-- evidence before accepting on its own. Completing the transformation
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
    if self._result ~= nil or self._phase == "learn" then
      break
    end
    self._clock = self._clock + 1
    if self._phase == "entry" and self._clock >= BattleEvolutionState.ENTRY_TICKS then
      self._phase = "sequence"
      self._clock = 0
      -- Retail PLAY_CRY: the old picture animates, the old cry voices
      -- with the subject form, and the progress message follows the
      -- PRINT_WHAT policy (917 after 916 for battle, 915 alone otherwise).
      self:_record({ kind = "cry", phase = "sequence", species = self._species, form = self._form })
      if self._printWhat then
        self:_record({
          kind = "message",
          phase = "sequence",
          msg = BattleEvolutionState.MSG_EVOLVING,
          species = self._species,
          form = self._form,
        })
      else
        self:_record({
          kind = "message",
          phase = "sequence",
          msg = BattleEvolutionState.MSG_WHAT_COMBINED,
          species = self._species,
          form = self._form,
        })
      end
    elseif self._phase == "sequence" and self._clock >= BattleEvolutionState.SEQUENCE_TICKS then
      self._phase = "transformation"
      self._clock = 0
      -- Retail particle start plus narrow-window completion beats,
      -- compressed onto the transformation entry: resource 0 with
      -- emitter 0 and SE W025, the window narrow, then the narrow-done
      -- emitters with SE W060C and the affine oscillation start. The
      -- cancel window opens here.
      self:_record({
        kind = "particles",
        phase = "transformation",
        resource = 0,
        emitters = { 0 },
      })
      self:_record({
        kind = "sound",
        phase = "transformation",
        se = BattleEvolutionState.SE_W025,
        name = "SEQ_SE_DP_W025",
      })
      self:_record({ kind = "window", phase = "transformation", op = "narrow" })
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
    elseif self._phase == "transformation" and self._clock >= BattleEvolutionState.TRANSFORMATION_TICKS then
      self:_acceptTransformation()
    elseif self._phase == "fanfare" and self._clock >= BattleEvolutionState.FANFARE_TICKS then
      self:_walkAccepted()
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
---@param reply { choice: string, slot: integer? } replace-or-decline answer under applying
function BattleEvolutionState:answerLearn(reply)
  assert(not self._disposed, "answers read a live sequence")
  assert(self._result == nil, "answers decide before settlement")
  assert(self._phase == "learn" and self._prompt ~= nil, "learning answers name the open prompt")
  assert(type(reply) == "table", "learning answers arrive as a record")
  local flow = assert(self._flow, "learning answers read their staged flow")
  local prompt = assert(self._prompt, "learning answers read their open prompt")
  local newSpecies = assert(self._newSpecies, "learning answers name their evolved species")
  self:_record({
    kind = "sound",
    phase = "learn",
    se = BattleEvolutionState.SE_SELECT,
    name = "SEQ_SE_DP_SELECT",
  })
  if reply.choice == "decline" then
    EvolutionFlow.respond(flow, { choice = "decline" })
    self:_record({
      kind = "message",
      phase = "learn",
      msg = BattleEvolutionState.MSG_STOP_TRYING,
      move = prompt.move,
    })
    self:_record({
      kind = "message",
      phase = "learn",
      msg = BattleEvolutionState.MSG_DID_NOT_LEARN,
      species = newSpecies,
      move = prompt.move,
    })
    self._prompt = nil
    self:_walkAccepted()
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
    self:_record({ kind = "message", phase = "learn", msg = BattleEvolutionState.MSG_POOF })
    self:_record({
      kind = "message",
      phase = "learn",
      msg = BattleEvolutionState.MSG_FORGOT,
      species = newSpecies,
      move = forgotten,
    })
    self:_record({ kind = "message", phase = "learn", msg = BattleEvolutionState.MSG_AND })
    self:_record({
      kind = "message",
      phase = "learn",
      msg = BattleEvolutionState.MSG_LEARNED,
      species = newSpecies,
      move = prompt.move,
    })
    -- Retail WAIT_FANFARE: the LVUP fanfare (message WAIT 5) plays out
    -- on a short timer before learning continues. Recorded for the
    -- audio owner; no audio plumbing lives here.
    self:_record({
      kind = "fanfare_wait",
      phase = "fanfare",
      seq = BattleEvolutionState.SEQ_ME_LVUP,
      name = "SEQ_ME_LVUP",
      ticks = BattleEvolutionState.FANFARE_TICKS,
    })
    self._prompt = nil
    self._phase = "fanfare"
    self._clock = 0
    return
  end
  error("learning replies decline or replace the incoming move", 0)
end

---@return table<string, unknown>? pending learned-move prompt, nil outside the learning pause
function BattleEvolutionState:learnPrompt()
  if self._prompt == nil then
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
  return {
    kind = "evolution",
    phase = self._phase,
    clock = self._clock,
    source = self._source,
    flags = self._flags,
    printWhat = self._printWhat,
    species = self._species,
    form = self._form,
    newSpecies = self._newSpecies,
    assets = assets,
    learnPrompt = self:learnPrompt(),
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
    learnPending = self._prompt ~= nil,
    effects = #self._effects,
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
  self._disposed = true
end

return BattleEvolutionState
