local BattleAudio = require("libs.hgss.src.audio.BattleAudio")
local BattlePresentationFlow = require("game.hgss.src.battle.BattlePresentationFlow")
local SourceTick = require("libs.hgss.src.field.SourceTick")

-- Bounded visible-cue player for one battle launch. Translates the
-- detached delivery packets of the battle runtime into an ordered queue
-- of small typed cues (messages, health interpolation, hit recoil,
-- fainting, withdrawal, reveal, experience, waits, one-shot sounds) over
-- a displayed-state model, advanced only by accepted presentation time
-- at the shared HGSS source cadence. The screen feeds packets in, ticks the
-- clock, and reads the displayed facts; drawing and input never advance
-- it. Unknown required effects are recorded only in the diagnostic channel.
-- Every narration cue resolves through the staged source bank.

local TextSpeedPolicy = require("libs.hgss.src.ui.TextSpeedPolicy")
local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")

---@class BattleTimeline
---@field _effects table<string, unknown>? battle-private native-effect collaborator behind start/status/cancel/retire
---@field _nativeSeen table<string, boolean> claimed visual occurrences by launch, round, action, effect key, and source phase
---@field _announced table<string, boolean> narrated attack occurrences by the same occurrence identity
---@field _pendingSounds table<integer, table<string, unknown>> queued one-shot sound cues for the screen drain
---@field _battlers table<integer, table<string, unknown>> displayed facts by combatant identity
---@field _order integer[] player-first combatant identities for view order
---@field _queue table<integer, table<string, unknown>> ordered unplayed cues
---@field _active table<string, unknown>? cue consuming ticks
---@field _message string currently displayed narration page
---@field _messageId integer stable identity of the displayed narration
---@field _messageSeq integer narration counter
---@field _lastPacketId integer highest accepted per-launch packet identity
---@field _seen table<string, boolean> played event identities by launch and sequence
---@field _latest table<string, unknown>? newest after view for name and move facts
---@field _openingPresentation table<string, unknown>? detached opening-stage presentation facts
---@field _trainerSlideTracks table<integer, table<string, unknown>> source animation and slide tracks
---@field _trainerPictures table<string, table<string, unknown>> staged trainer frame and throw metadata
---@field _terrainSlideTracks table<integer, { role: "player"|"foe", delay: integer, elapsed: integer, direction: integer, targetX: integer, speed: integer }> source timing for both terrain bases
---@field _wildIntroTrack { combatant: integer, delay: integer, elapsed: integer, x: integer, targetX: integer, speed: integer, arrived: boolean, fadeElapsed: integer }? source timing for the wild foe entrance
---@field _names table<integer, string> visible names by combatant identity across packets
---@field _addressing table<integer, "own"|"wild"|"foe"> source nickname-tag variant by combatant identity
---@field _lastStruck integer? most recent strike recipient, the source of a following drain
---@field _playerName string? player trainer name from the views
---@field _inBall integer? capture target drawn into the thrown ball, awaiting its outcome
---@field _foeHpMark integer? lead foe health at the last switch-in (source hpTemp)
---@field _ownMoves table<string, string> own move display names by combatant and move identity
---@field _moveName (fun(move: string): string?)? borrowed move display-name resolver for foe narration
---@field _speciesName (fun(species: string): string?)? borrowed species display-name resolver for tagged narration
---@field _itemName (fun(item: string): string?)? borrowed item display-name resolver for use narration
---@field _battleItemUse (fun(item: string): table<string, unknown>?)? borrowed generated battle-use facts
---@field _ballFadeColor (fun(ballKey: string): integer)? Pokepic palette-fade target of a ball (sBallColors)
---@field _faintAppearance (fun(battler: table<string, unknown>): { height: integer, shadowHeight: integer }?)? source picture facts
---@field _messageText fun(context: unknown, key: string, substitutions: string[]): string source text resolver supplied by the battle screen or test fixture
---@field _messageTextContext unknown? owner passed to the source text resolver
---@field _revealPolicy { interGlyphDelay: integer, glyphBudget: integer, abAcceleration: boolean } per-launch narration cadence copied from the shared pace table
---@field _accum number fractional accepted seconds awaiting their tick
---@field _diagnostics string[] recorded unknown-effect occurrences
local BattleTimeline = {}
BattleTimeline.__index = BattleTimeline

-- BattleAnim's gOpponentBallKinds and BallThrow_GetStartPosition place the
-- already-created foe ball independently of the trainer backpic anchors.
local FOE_BALL_START_BY_BATTLER_TYPE = {
  [1] = { x = 192, y = 86 },
  [3] = { x = 216, y = 88 },
  [5] = { x = 176, y = 80 },
}

BattleTimeline.TICKS_PER_SECOND = SourceTick.HZ
BattleTimeline.MESSAGE_HOLD_TICKS = 12
BattleTimeline.HIT_TICKS = 6
BattleTimeline.HIT_DISPLACEMENT = 2
BattleTimeline.VANISH_TICKS = 12
-- Task_RecallPokemon / Task_PokemonSendOut: the Pokepic palette fade toward
-- the ball color steps once per frame over 17 updates (0 -> 16 or 16 -> 0)
-- and the picture's affine scale moves 32/256 per frame (8 steps).
BattleTimeline.BALL_FADE_TICKS = 17
BattleTimeline.BALL_SCALE_TICKS = 8
-- party_gauge.c mid-battle show (arrow and balls slide at 18 px/frame, then
-- the gauge task polls) and hide (arrow alpha fades 16 -> 0 at 1 per frame).
BattleTimeline.PARTY_GAUGE_SHOW_TICKS = 11
BattleTimeline.PARTY_GAUGE_HIDE_TICKS = 19
-- subscript_0009_SwitchMon WaitTime between PokemonSendOut and HealthbarSlideIn.
BattleTimeline.SWITCH_SETTLE_TICKS = 72
BattleTimeline.HP_BAR_PIXELS = 48
BattleTimeline.EXP_BAR_PIXELS = 96
BattleTimeline.PAGE_GLYPHS = 54
-- A battle line ending in \r auto-waits 100 printer updates (two per
-- source tick) before its script's own WaitButtonABTime; A/B skips both.
BattleTimeline.AUTO_SCROLL_TICKS = 50
local SOURCE_TICK_EPSILON = 1e-12

local LEVEL_UP_STATS = {
  { key = "hp", field = "maxHp", label = "HP" },
  { key = "attack", field = "attack", label = "Attack" },
  { key = "defense", field = "defense", label = "Defense" },
  { key = "specialAttack", field = "specialAttack", label = "Sp. Atk" },
  { key = "specialDefense", field = "specialDefense", label = "Sp. Def" },
  { key = "speed", field = "speed", label = "Speed" },
}

---@param text string
---@return string[] pages of at most PAGE_GLYPHS glyphs, never empty
local function paginate(text)
  local pages = {}
  local glyphs = 0
  local current = {}
  -- Pagination counts glyphs, not bytes, so multibyte names never
  -- split a codepoint across pages.
  local codepoints = {}
  for char in Utf8Glyphs.iter(text) do
    codepoints[#codepoints + 1] = char
  end
  for index, char in ipairs(codepoints) do
    current[#current + 1] = char
    glyphs = glyphs + 1
    if glyphs >= BattleTimeline.PAGE_GLYPHS and (char == " " or index == #codepoints) then
      pages[#pages + 1] = table.concat(current)
      current = {}
      glyphs = 0
    end
  end
  if #current > 0 or #pages == 0 then
    pages[#pages + 1] = table.concat(current)
  end
  return pages
end

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

---@class BattleTimeline.Options
---@field sound (fun(cue: table<string, unknown>))? sound-cue sink, drained immediately when supplied
---@field moveName (fun(move: string): string?)? display-name resolver for move identities the views never name
---@field speciesName (fun(species: string): string?)? display-name resolver for species identities in source tags
---@field itemName (fun(item: string): string?)? display-name resolver for item identities
---@field battleItemUse (fun(item: string): table<string, unknown>?)? generated battle-use facts for item narration
---@field textSpeed string? narration pace for this launch, defaulting to the middle pace
---@field effects table<string, unknown>? battle-private native-effect collaborator behind start/status/cancel/retire, absent without a screen owner
---@field ballFadeColor (fun(ballKey: string): integer)? source recall and send-out fade color of a ball
---@field faintAppearance (fun(battler: table<string, unknown>): { height: integer, shadowHeight: integer }?)? source picture facts for fainting
---@field trainerPictures table<string, table<string, unknown>>? staged source trainer metadata
---@field messageText fun(context: unknown, key: string, substitutions: string[]): string staged retail battle message resolver
---@field messageTextContext unknown? explicit owner passed to the staged retail message resolver

---@param opts BattleTimeline.Options?
---@return BattleTimeline
function BattleTimeline.new(opts)
  opts = opts or {}
  assert(type(opts) == "table", "the cue player requires options")
  assert(type(opts.messageText) == "function", "battle narration requires its staged message resolver")
  local revealPolicy = TextSpeedPolicy.forSpeed(opts.textSpeed or "mid")
  return setmetatable({
    _sound = opts.sound,
    _moveName = opts.moveName,
    _speciesName = opts.speciesName,
    _itemName = opts.itemName,
    _battleItemUse = opts.battleItemUse,
    _ballFadeColor = opts.ballFadeColor,
    _faintAppearance = opts.faintAppearance,
    _messageText = opts.messageText,
    _messageTextContext = opts.messageTextContext,
    _revealPolicy = revealPolicy,
    _effects = opts.effects,
    _nativeSeen = {},
    _announced = {},
    _pendingSounds = {},
    _names = {},
    _addressing = {},
    _ownMoves = {},
    _battlers = {},
    _order = {},
    _queue = {},
    _active = nil,
    _message = "",
    _messageId = 0,
    _messageSeq = 0,
    _lastPacketId = 0,
    _seen = {},
    _latest = nil,
    _openingPresentation = nil,
    _trainerSlideTracks = {},
    _trainerPictures = opts.trainerPictures or {},
    _terrainSlideTracks = {},
    _wildIntroTrack = nil,
    _wildVictoryMusicStarted = false,
    _accum = 0,
    _diagnostics = {},
    _flowIntroDone = false,
  }, BattleTimeline)
end

---@param self BattleTimeline
---@param view table<string, unknown>? detached view carrying name and move facts
local function indexFacts(self, view)
  -- Names and own move labels index from every delivery so narration
  -- keeps working after its battler leaves the newest view.
  if type(view) ~= "table" then
    return
  end
  if type(view.playerName) == "string" and view.playerName ~= "" then
    self._playerName = view.playerName --[[@as string]]
  end
  for groupIndex, group in ipairs({ view.own, view.foes }) do
    if type(group) == "table" then
      for _, record in ipairs(group) do
        if type(record) == "table" and type(record.combatant) == "number" then
          local id = record.combatant --[[@as integer]]
          if type(record.name) == "string" and self._names[id] == nil then
            self._names[id] = record.name --[[@as string]]
          end
          if groupIndex == 1 then
            self._addressing[id] = "own"
          elseif record.controller == "wild" or record.controller == nil then
            self._addressing[id] = "wild"
          else
            self._addressing[id] = "foe"
          end
          if type(record.moves) == "table" then
            for _, entry in ipairs(record.moves) do
              if type(entry) == "table" and type(entry.move) == "string" and type(entry.name) == "string" then
                local key = tostring(id) .. "\0" .. entry.move
                if
                  self._ownMoves[
                    key --[[@as string]]
                  ] == nil
                then
                  self._ownMoves[
                    key --[[@as string]]
                  ] = entry.name --[[@as string]]
                end
              end
            end
          end
        end
      end
    end
  end
end

---@param record table<string, unknown> model battler record under display
---@return table<string, unknown> displayed facts for one battler
local function displayedOf(record)
  local shown = {
    combatant = record.combatant,
    side = record.side,
    hp = record.hp,
    maxHp = record.maxHp,
    visible = true,
    name = record.name,
    level = record.level,
    species = record.species,
    form = record.form,
    exp = record.experience,
    condition = record.condition,
    moves = copyValue(record.moves),
    ballKey = record.ballKey,
  }
  -- The native slot identity rides the displayed record for live
  -- active battlers only: benched or historic records never claim a
  -- slot, and the model position stays opaque (keyed verbatim, never
  -- reinterpreted here).
  if record.active ~= false then
    if type(record.position) == "number" then
      shown.position = record.position
    end
    if type(record.activation) == "number" then
      shown.activation = record.activation
    end
  end
  if type(record.portraitSelector) == "string" and record.portraitSelector ~= "" then
    shown.portraitSelector = record.portraitSelector
  end
  -- Presentation-only picture facts ride the displayed record when the
  -- model answers them: gender and caught marks, the signed height
  -- displacement, and the substitute channel. Absent facts stay absent;
  -- the renderer defaults them. A present gender or form must be
  -- source-meaningful: unknown genders and negative forms fail here
  -- instead of rendering a plausible battler.
  if record.gender ~= nil then
    assert(
      record.gender == "male" or record.gender == "female" or record.gender == "genderless",
      "battle appearance carries a known gender for combatant " .. tostring(record.combatant)
    )
    shown.gender = record.gender
  end
  if record.form ~= nil then
    assert(
      type(record.form) == "number" and record.form % 1 == 0 and record.form >= 0,
      "battle appearance carries a non-negative form for combatant " .. tostring(record.combatant)
    )
  end
  if type(record.caught) == "boolean" then
    shown.caught = record.caught
  end
  if type(record.height) == "number" then
    shown.height = record.height
  end
  if record.substitute == true then
    shown.substitute = true
  end
  return shown
end

-- Loud slot coherence: every currently visible record claiming a native
-- slot must hold a whole slot identity, and no slot is ever visibly
-- claimed twice. Records without a slot (legacy singles fixtures) are
-- exempt; hidden, benched and historic records never claim.
---@param self BattleTimeline
local function checkSlotClaims(self)
  local claimed = {}
  for id, shown in pairs(self._battlers) do
    if type(shown) == "table" and shown.visible ~= false and type(shown.position) == "number" then
      local slot = shown.position --[[@as integer]]
      assert(slot % 1 == 0, "native slots are whole slot identities (combatant " .. tostring(id) .. ")")
      local other = claimed[slot]
      assert(
        other == nil,
        "native slot "
          .. tostring(slot)
          .. " is visibly claimed twice (combatants "
          .. tostring(other)
          .. " and "
          .. tostring(id)
          .. ")"
      )
      claimed[slot] = id
    end
  end
end

-- True while a queued or playing cue still owns the slot transition for
-- one combatant: withdrawal, reveal and faint cues gate position and
-- activation updates so reconciliation can never outrun them.
---@param self BattleTimeline
---@param id integer combatant identity under reconciliation
---@return boolean gated
local function slotGated(self, id)
  local function gates(cue)
    if type(cue) ~= "table" or (cue.combatant ~= id and cue.slideCombatant ~= id) then
      return false
    end
    return cue.kind == "withdraw" or cue.kind == "reveal" or cue.kind == "faint" or cue.slideCombatant == id
  end
  if gates(self._active) then
    return true
  end
  for _, cue in ipairs(self._queue) do
    if gates(cue) then
      return true
    end
  end
  return false
end

-- Installs the opening displayed facts from the first detached view:
-- every listed battler shown at its exact health, player side first.
---@param view table<string, unknown> detached opening dynamic view
function BattleTimeline:reset(view)
  assert(type(view) == "table", "the cue player opens from its view")
  self._battlers = {}
  self._order = {}
  local function active(record)
    return record.active ~= false
  end
  local function installActive(records)
    if type(records) ~= "table" then
      return
    end
    for _, record in ipairs(records) do
      if type(record) == "table" and type(record.combatant) == "number" and active(record) then
        local id = record.combatant --[[@as integer]]
        if self._battlers[id] == nil then
          self._battlers[id] = displayedOf(record --[[@as table<string, unknown>]])
          self._order[#self._order + 1] = id
        end
      end
    end
  end
  installActive(view.own)
  installActive(view.foes)
  indexFacts(self, view)
  self._latest = view
  checkSlotClaims(self)
  self._queue = {}
  self._active = nil
  self._flowIntroDone = false
  self._wildVictoryMusicStarted = false
  self._terrainSlideTracks = {}
  self._wildIntroTrack = nil
  -- A fresh opening starts new actions: occurrence and narration claims
  -- never leak from the previous launch into the next one.
  self._nativeSeen = {}
  self._announced = {}
end

-- Drops transient visual tracks when the owning battle screen is disposed.
function BattleTimeline:dispose()
  self._queue = {}
  self._active = nil
  self._openingPresentation = nil
  self._trainerSlideTracks = {}
  self._terrainSlideTracks = {}
  self._wildIntroTrack = nil
end

---@param cue table<string, unknown>
local function enqueue(self, cue)
  cue.elapsed = 0
  cue.started = false
  self._queue[#self._queue + 1] = cue
end

---@param self BattleTimeline
---@param changes table<string, boolean> visibility values for one native opening stage
local function enqueueOpeningPresentation(self, changes)
  enqueue(self, { kind = "opening-presentation", changes = changes })
end

---@param self BattleTimeline
---@param combatant integer battler receiving the source send-out
---@param role "player"|"foe" source side selected for the opening throw
local function enqueueBallThrow(self, combatant, role)
  if self._openingPresentation == nil then
    return
  end
  local view = assert(self._latest, "send-out ball selection uses the newest detached battle view")
  local record = nil
  for _, group in ipairs({ view.own, view.foes }) do
    if type(group) == "table" then
      for _, candidate in ipairs(group) do
        if type(candidate) == "table" and candidate.combatant == combatant then
          record = candidate
        end
      end
    end
  end
  local sendOutRecord =
    assert(type(record) == "table" and record, "send-out events resolve their detached battler record") --[[@as { ballKey: unknown, participant?: unknown }]]
  local ballKeyValue = sendOutRecord.ballKey
  local ballKey =
    assert(type(ballKeyValue) == "string" and ballKeyValue, "send-out records carry their semantic ball key")
  local trainerSelector = nil
  local throwOffsets = nil
  local participant = nil
  if role == "player" then
    local trainer = assert(view.playerTrainer, "player throws carry their trainer class") --[[@as table<string, unknown>]]
    trainerSelector = "back:" .. assert(trainer.classKey, "player throws carry their backpic selector") --[[@as string]]
    local playerTrack = nil
    for index, slide in ipairs(self._openingPresentation.trainerSlides) do
      if slide.selector == trainerSelector and slide.visible == true then
        playerTrack = self._trainerSlideTracks[index]
        break
      end
    end
    if playerTrack == nil or playerTrack.throwQueued == true then
      return
    end
    local entry = assert(self._trainerPictures[trainerSelector], "player trainer backpic metadata is staged")
    assert(type(entry.animation) == "table", "player trainer backpic carries its sequence-zero compatibility record")
    assert(type(entry.animation.sequences) == "table", "player trainer backpic stages source animation sequences")
    throwOffsets = assert(entry.throwOffsets, "animated player trainer backpics carry source throw anchors")
    playerTrack.throwQueued = true
  else
    local participantValue = sendOutRecord.participant
    participant =
      assert(type(participantValue) == "number" and participantValue, "foe send-outs carry their trainer participant")
    local slideTrack = nil
    for index, slide in ipairs(self._openingPresentation.trainerSlides) do
      local track = self._trainerSlideTracks[index]
      if slide.role == "foe" and slide.visible == true and track.participant == participant then
        slideTrack = track
        break
      end
    end
    if slideTrack == nil then
      return
    end
    local start = assert(
      FOE_BALL_START_BY_BATTLER_TYPE[
        slideTrack.sourceBattlerType --[[@as integer]]
      ],
      "foe trainer type has a source ball start position"
    )
    enqueue(self, {
      kind = "trainer-exit",
      role = "foe",
      participant = participant,
      selector = "ball:" .. ballKey,
      ballX = start.x,
      ballY = start.y,
      requiresImage = "battle-ball:" .. ballKey .. ":0",
    })
    return
  end
  local selector = "ball:" .. ballKey
  enqueue(self, {
    kind = "ball-throw",
    selector = selector,
    trainerSelector = trainerSelector,
    throwOffsets = throwOffsets,
    requiresImage = "battle-ball:" .. ballKey .. ":0",
  })
end

---@param view table<string, unknown> detached view carrying semantic trainer keys
---@param wild boolean
---@return table<integer, table<string, unknown>> public trainer slide states
---@return table<integer, { delay: integer, elapsed: integer, direction: integer, targetX: integer, speed: integer }> source slide tracks
local function openingTrainerSlides(self, view, wild)
  local slides = {}
  local tracks = {}
  local playerTrainerValue = view.playerTrainer
  assert(type(playerTrainerValue) == "table", "opening views carry the player's semantic trainer class")
  local playerTrainer = playerTrainerValue --[[@as table<string, unknown>]]
  local playerClassKey = playerTrainer.classKey
  assert(type(playerClassKey) == "string", "opening player trainer class is semantic")
  assert(playerClassKey ~= "", "opening player trainer class is semantic")
  local foeTrainerParticipants = {}
  local participants = assert(view.participants, "battle views carry the source participant roster")
  for _, participant in ipairs(participants) do
    if
      participant.side == 2
      and type(participant.controller) == "string"
      and participant.controller:match("^trainer:")
    then
      foeTrainerParticipants[#foeTrainerParticipants + 1] = participant.participant
    end
  end
  local function addSlide(role, selector, x, y, direction, targetX, participant, sourceBattlerType)
    local entry = assert(self._trainerPictures[selector], "opening trainers use staged source frame metadata")
    local animationData = assert(entry.animation, "opening trainer metadata carries sequence-zero source frames")
    local sequences = assert(animationData.sequences, "trainer metadata carries the staged source sequence inventory")
    local animation = #sequences > 2 and sequences[3] or animationData
    local sourceSequence = animation.sourceSequence --[[@as integer]]
    local frames = assert(animation.frames, "opening trainer metadata carries ordered source frames")
    assert(type(frames) == "table" and #frames > 0, "opening trainer metadata carries source frames")
    local initialFrame = assert(animation.loopStartFrameIdx, "trainer source sequences declare their initial frame")
    slides[#slides + 1] = {
      role = role,
      selector = selector,
      sourceSequence = sourceSequence,
      x = x,
      y = y,
      frame = initialFrame,
      visible = true,
      phase = "intro-delay",
    }
    tracks[#tracks + 1] = {
      delay = 28,
      elapsed = 0,
      direction = direction,
      targetX = targetX,
      speed = 8,
      frames = frames,
      animation = animation,
      sourceSequenceCount = #sequences,
      throwQueued = false,
      frame = initialFrame,
      frameElapsed = 0,
      frameDirection = 1,
      animationActive = true,
      encounterWaiting = false,
      encounterComplete = false,
      attributeFrame = nil,
      participant = participant,
      sourceBattlerType = sourceBattlerType,
    }
  end
  addSlide("player", "back:" .. playerClassKey, 336, 112, -1, 64)
  if not wild then
    local trainers = view.foeTrainers --[[@as table<integer, table<string, unknown>>]]
    assert(type(trainers) == "table", "trainer openings carry foe class records")
    assert(#trainers > 0, "trainer openings carry at least one opponent trainer")
    assert(#foeTrainerParticipants >= #trainers, "each foe trainer picture resolves to its source participant")
    local entrance = #trainers == 1 and {
      { x = -80, y = 50, targetX = 192 },
    } or {
      { x = -60, y = 50, targetX = 216 },
      { x = -100, y = 42, targetX = 176 },
    }
    assert(#trainers <= #entrance, "HGSS has at most two physical trainers on the opposing side")
    for index, trainerRecord in ipairs(trainers) do
      local trainer = trainerRecord --[[@as table<string, unknown>]]
      local classKey = assert(trainer.classKey, "foe trainer class is semantic") --[[@as string]]
      assert(classKey ~= "", "foe trainer class is semantic")
      local slot = entrance[index]
      local sourceBattlerType = #trainers == 1 and 1 or (index == 1 and 3 or 5)
      addSlide(
        "foe",
        "front:" .. classKey,
        slot.x,
        slot.y,
        1,
        slot.targetX,
        foeTrainerParticipants[index],
        sourceBattlerType
      )
    end
  end
  return slides, tracks
end

---@param self BattleTimeline
---@param slide table<string, unknown> trainer pose under selection
---@param track table<string, unknown> source trainer track under selection
---@param sourceSequence integer source NANR sequence ID
local function selectTrainerSequence(self, slide, track, sourceSequence)
  local entry = assert(self._trainerPictures[
    slide.selector --[[@as string]]
  ])
  local animationData = assert(entry.animation, "trainer source metadata carries sequence zero")
  local animation = sourceSequence == 0 and animationData or animationData.sequences[sourceSequence + 1]
  assert(animation ~= nil, "trainer source sequence is staged")
  track.animation = animation
  track.frames = assert(animation.frames, "trainer sequences carry source frames")
  track.frame = assert(animation.loopStartFrameIdx, "trainer source sequences declare their initial frame")
  track.frameElapsed = 0
  track.frameDirection = 1
  track.animationActive = true
  track.attributeFrame = nil
  slide.sourceSequence = sourceSequence
  slide.frame = track.frame
end

---@return table<integer, table<string, unknown>> detached player and foe terrain positions
---@return table<integer, { role: "player"|"foe", delay: integer, elapsed: integer, direction: integer, targetX: integer, speed: integer }> source slide tracks
local function openingTerrainSlides()
  return {
    { role = "player", x = 336, y = 136, visible = true, phase = "intro-delay" },
    { role = "foe", x = -80, y = 88, visible = true, phase = "intro-delay" },
  }, {
    { role = "player", delay = 28, elapsed = 0, direction = -1, targetX = 64, speed = 8 },
    { role = "foe", delay = 28, elapsed = 0, direction = 1, targetX = 192, speed = 8 },
  }
end

---@param cue table<string, unknown> typed one-shot sound cue under queueing
local function emitSound(self, cue)
  assert(type(cue) == "table" and type(cue.kind) == "string", "sound cues carry their typed kind")
  self._pendingSounds[#self._pendingSounds + 1] = cue
  if self._sound ~= nil then
    self._sound(cue)
    -- Headless recording sinks voice the legacy string cry role while
    -- the screen drains the typed cue: the pending table keeps the
    -- single production voice, and the extra string keeps the direct
    -- timeline boundary legible without a second production sound.
    if cue.kind == "cry" and type(cue.species) == "string" and cue.species ~= "" then
      self._sound("cry:" .. cue.species)
    end
  end
end

-- One staged effect cue behind battle flows.
---@param symbol string staged effect sequence symbol
---@param mix table<string, unknown>? optional source mix facts
---@return table<string, unknown> typed effect cue
local function effectCue(symbol, mix)
  assert(type(symbol) == "string" and symbol ~= "", "effect cues name their staged symbol")
  local cue = { kind = "effect", symbol = symbol }
  if mix ~= nil then
    for key, value in pairs(mix) do
      cue[key] = value
    end
  end
  return cue
end

-- One staged victory-music cue behind terminal results. Unlike effect
-- cues it swaps the battle BGM instead of firing the sound machine.
---@param symbol string staged victory BGM symbol
---@return table<string, unknown> typed music cue
local function musicCue(symbol)
  assert(type(symbol) == "string" and symbol ~= "", "music cues name their staged symbol")
  return { kind = "music", symbol = symbol }
end

---@param symbol string staged fanfare sequence symbol
---@param waitForVoice boolean? hold following cues until the fanfare completes
---@return table<string, unknown> typed fanfare cue
local function fanfareCue(symbol, waitForVoice)
  assert(type(symbol) == "string" and symbol ~= "", "fanfare cues name their staged symbol")
  return { kind = "fanfare", symbol = symbol, waitForVoice = waitForVoice == true }
end

-- One send-out cry cue for a battler: the view-carried species and
-- form with its player/foe side. The screen resolves the numeric cry
-- identity and the side mix convention at dispatch.
---@param species string view-carried species key
---@param form integer|nil view-carried form, nil reads as the species bank
---@param foe boolean true for the foe send-out, false for the player send-out
---@param pattern integer? source cry pattern, absent for ordinary send-out
---@param waitForVoice boolean? hold following cues until this cry ends
---@return table<string, unknown> typed cry cue
local function cryCue(species, form, foe, pattern, waitForVoice)
  assert(type(species) == "string" and species ~= "", "cry cues name their view species")
  return {
    kind = "cry",
    species = species,
    form = form,
    foe = foe == true,
    pattern = pattern,
    waitForVoice = waitForVoice == true,
  }
end

---@param sequence unknown event sequence ordinal under visual seeding
---@return integer deterministic visual seed scoped to the event identity
local function visualSeedFor(sequence)
  local ordinal = 0
  if type(sequence) == "number" and sequence % 1 == 0 and sequence >= 0 then
    ordinal = sequence --[[@as integer]]
  end
  -- The canonical stream lives in PresentationFacts.visualSeedFor;
  -- this mirrors its arithmetic so cue identities stay deterministic
  -- without pulling the mechanics package into the cue player.
  return (ordinal * 1103515245 + 12345) % 2147483648
end

---@param event table<string, unknown> sanitized kernel event under inspection
---@return string? accepted semantic effect key, nil when the source names no effect
local function nativeEffectKeyOf(event)
  local key = event.effectKey
  if type(key) == "string" and key ~= "" then
    return key --[[@as string]]
  end
  return nil
end

--- One visual occurrence belongs to one action and one source phase: the
--- launch, round, action identity, executed effect key, and move
--- phase. Every hit of a multi-hit sequence and every recipient of a
--- spread move shares the source action identity, while a distinct action
--- identity starts its own occurrence. The charged and struck halves of a
--- two-turn action stay distinct through their source phases, so the
--- strike half never collapses onto the charge cue. An action without an
--- identity (a strike-only legacy emission) falls back to its event
--- sequence; a present but mistyped action identity is malformed and
--- claims nothing rather than silently visualizing another user's action.
---@param launch string owning launch identity under emission
---@param event table<string, unknown> sanitized kernel event under emission
---@param packet table<string, unknown> delivery carrying event-time views
---@return string? action-scoped occurrence identity, nil when the source action identity is malformed
local function occurrenceIdentityOf(launch, event, packet)
  local action = event.actionId
  if type(action) ~= "number" and type(action) ~= "string" then
    if action ~= nil then
      return nil
    end
    action = event.sequence
  end
  local phase = event.kind
  local move = event.move --[[@as table<string, unknown>?]]
  if type(move) == "table" and type(move.phase) == "string" then
    phase = move.phase
  end
  local before = packet.before --[[@as table<string, unknown>?]]
  local after = packet.after --[[@as table<string, unknown>?]]
  local round = type(before) == "table" and before.round or nil
  if round == nil and type(after) == "table" then
    round = after.round
  end
  return launch
    .. "\0"
    .. tostring(round)
    .. "\0"
    .. tostring(action)
    .. "\0"
    .. tostring(event.effectKey)
    .. "\0"
    .. tostring(phase)
end

---@param packet table<string, unknown> delivery carrying launch identity
---@return string owning launch identity under emission, empty when unnamed
local function launchOf(packet)
  if type(packet.launchId) == "string" then
    return packet.launchId --[[@as string]]
  end
  return ""
end

-- Demands the exact selected effect the first time its source event is
-- admitted, once its announcement has played. The cue itself stays
-- ordered behind the event narration and ahead of its hit and health
-- work, and still holds every later cue until the player occurrence
-- actually completes. Emission is exactly once per launch, action,
-- executed effect key, and source phase: later hits, spread recipients,
-- and redeliveries of the same action queue nothing new. Generic impact
-- and effectiveness voices stay silent on this path because the selected
-- program owns audio timing.
---@param self BattleTimeline
---@param cue table<string, unknown> native-effect cue under admission
local function beginNativeEffect(self, cue)
  if cue.startAttempted == true then
    return
  end
  cue.startAttempted = true
  if self._effects == nil then
    if cue.collaboratorMissing ~= true then
      cue.collaboratorMissing = true
      self._diagnostics[#self._diagnostics + 1] = "native effect "
        .. tostring(cue.effectKey)
        .. " for launch "
        .. tostring(cue.launchId)
        .. " has no animation collaborator"
    end
    return
  end
  local starter = self._effects.start --[[@as fun(cue: table<string, unknown>): table<string, unknown>?]]
  if type(starter) ~= "function" then
    if cue.collaboratorMissing ~= true then
      cue.collaboratorMissing = true
      self._diagnostics[#self._diagnostics + 1] = "native effect "
        .. tostring(cue.effectKey)
        .. " for launch "
        .. tostring(cue.launchId)
        .. " has no animation start"
    end
    return
  end
  local ok, handle = pcall(starter, cue)
  if ok then
    cue.handle = handle
  elseif cue.startNoted ~= true then
    cue.startNoted = true
    self._diagnostics[#self._diagnostics + 1] = "native effect "
      .. tostring(cue.effectKey)
      .. " for launch "
      .. tostring(cue.launchId)
      .. " start failed: "
      .. tostring(handle)
  end
end

-- Queues one native-effect cue for an effect-keyed source event behind
-- its attack announcement and ahead of the event's hit and health work.
-- A malformed source action identity claims nothing: the outcome still
-- narrates, but no visual is assigned to another user's action.
---@param self BattleTimeline
---@param event table<string, unknown> sanitized kernel event carrying its accepted playback facts
---@param packet table<string, unknown> delivery carrying launch identity and event-time views
local function enqueueNativeEffect(self, event, packet)
  local launch = launchOf(packet)
  local identity = occurrenceIdentityOf(launch, event, packet)
  if identity == nil then
    self._diagnostics[#self._diagnostics + 1] = "native effect "
      .. tostring(event.effectKey)
      .. " for launch "
      .. tostring(packet.launchId)
      .. " names no usable action identity; the visual is skipped"
    return
  end
  if self._nativeSeen[identity] == true then
    return
  end
  self._nativeSeen[identity] = true
  local hitOrdinal = event.hitIndex
  if type(hitOrdinal) ~= "number" then
    local payload = event.payload --[[@as table<string, unknown>?]]
    if type(payload) == "table" and type(payload.hitIndex) == "number" then
      hitOrdinal = payload.hitIndex
    end
  end
  local seed = event.visualSeed
  if type(seed) ~= "number" then
    seed = visualSeedFor(event.sequence)
  end
  local cue = {
    kind = "native-effect",
    launchId = packet.launchId,
    packetId = packet.packetId,
    eventSequence = event.sequence,
    actionId = event.actionId,
    hitOrdinal = hitOrdinal,
    effectKey = event.effectKey,
    event = event,
    visualSeed = seed,
    before = packet.before,
    after = packet.after,
  }
  enqueue(self, cue)
end

---@param text string narration wording under presentation
---@param ackable boolean true when the page waits for acknowledgement instead of holding
---@param holdTicks integer? explicit post-text hold in internal ticks, defaulting to the narration hold
---@param ackSkipsHold boolean? whether acknowledgement skips this explicit hold
---@return table<string, unknown> queued narration cue
local function enqueueMessage(self, text, ackable, holdTicks, ackSkipsHold)
  self._messageSeq = self._messageSeq + 1
  local cue = {
    kind = "message",
    text = text,
    id = self._messageSeq,
    pages = paginate(text),
    page = 1,
    revealed = 0,
    hold = 0,
    holdTicks = holdTicks,
    ackSkipsHold = ackSkipsHold == true,
    ackable = ackable == true,
  }
  enqueue(self, cue)
  return cue
end

---@param self BattleTimeline
---@param key string semantic key for a staged retail message
---@param substitutions string[] ordered text substitutions for the source record
---@return string staged text resolved from the source message bank
local function messageText(self, key, substitutions)
  return self._messageText(self._messageTextContext, key, substitutions)
end

-- Flow helpers defined beside the translators that share them.
local eventObservation
local foeHealthAt, recallText, enqueueSendOut, speciesOf, enqueueEncounterMessage
local combatName, moveName
local tickBallPoof

---@param self BattleTimeline
---@return table<string, unknown>? first trainer semantic key and name from the current view
local function firstTrainer(self)
  local trainers = type(self._latest) == "table" and self._latest.foeTrainers or nil
  local trainer = type(trainers) == "table" and trainers[1] or nil
  if type(trainer) == "table" then
    return trainer
  end
  return nil
end

---@param self BattleTimeline
---@param trainer table<string, unknown> trainer identity under narration
---@return string staged class label
local function trainerClassText(self, trainer)
  local classKey = trainer.classKey
  assert(type(classKey) == "string", "trainer narration resolves a semantic class")
  return messageText(self, "battle/trainer-class/" .. classKey, {})
end

local function moveUseText(self, user, move)
  local combatant = assert(user, "move-use narration names its user")
  local address = self._addressing[combatant]
  local side = address == "wild" and "wild" or address == "foe" and "foe" or "own"
  local name = combatName(self, combatant)
  return messageText(self, "battle/move-use/" .. move .. "/" .. side, { name })
end

-- The encounter line: msg_0197_00965 ends in \r, then WaitButtonABTime 30.
---@param self BattleTimeline
---@param wild boolean true for a wild encounter
---@param foeName string lead foe name
function enqueueEncounterMessage(self, wild, foeName)
  if wild then
    enqueueMessage(
      self,
      messageText(self, "battle/narration/wild-appeared", { foeName }),
      false,
      BattleTimeline.AUTO_SCROLL_TICKS + 30,
      true
    )
  else
    local trainer = assert(firstTrainer(self), "trainer encounters name their opponent")
    local trainerName = assert(trainer.name, "trainer encounters carry the opponent name")
    enqueueMessage(
      self,
      messageText(self, "battle/narration/trainer-challenged", { trainerClassText(self, trainer), trainerName }),
      false,
      BattleTimeline.AUTO_SCROLL_TICKS + 30,
      true
    )
  end
end

-- Queues the headless opening flow in native order: encounter narration,
-- foe cry, the player ball and send-out, then the own cry. The screen
-- entry already queued this sequence through its explicit opening, so
-- this helper runs only for direct timeline drivers behind the same
-- packet identity.
---@param self BattleTimeline
---@param view table<string, unknown> detached opening dynamic view
local function queueOpening(self, view)
  local wild = BattlePresentationFlow.isWild(view)
  local foe = BattlePresentationFlow.firstFoe(view)
  assert(type(foe) == "table", "the opening needs its lead foe")
  local foeRecord = foe --[[@as table<string, unknown>]]
  local lead = BattlePresentationFlow.activeLead(view)
  assert(lead ~= nil, "the opening needs its active lead")
  local foeName = foeRecord.name
  assert(type(foeName) == "string", "opening foe view carries its display name")
  foeName = foeName --[[@as string]]
  local foeSpecies = nil
  local foeForm = nil
  if type(foeRecord.species) == "string" then
    foeSpecies = foeRecord.species --[[@as string]]
  end
  if type(foeRecord.form) == "number" then
    foeForm = foeRecord.form --[[@as integer]]
  end
  local own = lead --[[@as table<string, unknown>]]
  local ownName = own.name
  assert(type(ownName) == "string", "opening player lead carries its display name")
  local ownSpecies = nil
  local ownForm = nil
  if type(own.species) == "string" then
    ownSpecies = own.species --[[@as string]]
  end
  if type(own.form) == "number" then
    ownForm = own.form --[[@as integer]]
  end
  self._foeHpMark = foeHealthAt(self, nil)
  local trainerSlides, trainerTracks = openingTrainerSlides(self, view, wild)
  local terrainSlides, terrainTracks = openingTerrainSlides()
  self._openingPresentation = {
    playerTrainerVisible = true,
    foeTrainerVisible = not wild,
    playerGaugeVisible = false,
    enemyGaugeVisible = false,
    trainerSlides = trainerSlides,
    terrainSlides = terrainSlides,
  }
  self._trainerSlideTracks = trainerTracks
  self._terrainSlideTracks = terrainTracks
  if not wild then
    enqueue(self, { kind = "trainer-intro-wait" })
  end
  if type(foeSpecies) == "string" then
    enqueue(self, { kind = "sound", cue = cryCue(foeSpecies, foeForm, true), duration = 0 })
  end
  enqueueEncounterMessage(self, wild, foeName)
  enqueueMessage(self, messageText(self, "battle/narration/player-sent-out", { ownName }), false)
  enqueueBallThrow(self, own.combatant --[[@as integer]], "player")
  if type(ownSpecies) == "string" then
    enqueue(self, { kind = "sound", cue = cryCue(ownSpecies, ownForm, false), duration = 0 })
  end
  self._flowIntroDone = true
end

-- Queues only the terminal victory music cue. Outcome narration belongs
-- to the screen's committed-receipt lifecycle, never a second timeline page.
---@param self BattleTimeline
---@param packet table<string, unknown> detached delivery packet carrying its committed result
local function queueResult(self, packet)
  local result = packet.result --[[@as table<string, unknown>]]
  local word = type(result.word) == "string" and result.word or ""
  local view = self._latest
  if type(packet.after) == "table" then
    view = packet.after
  end
  local wild = true
  if type(view) == "table" then
    wild = BattlePresentationFlow.isWild(view --[[@as table<string, unknown>]])
  end
  local victory = BattlePresentationFlow.resultMusicSymbol(word, wild)
  if type(victory) == "string" and victory ~= "" and not (wild and self._wildVictoryMusicStarted) then
    enqueue(self, { kind = "sound", cue = musicCue(victory), duration = 0 })
  end
end

---@param id integer combatant identity under display
---@return table<string, unknown>? displayed facts, nil when never shown
function BattleTimeline:_shown(id)
  return self._battlers[id]
end

---@param self BattleTimeline
---@param combatant integer combatant identity under lookup
---@return string visible name required by source-tagged narration
function combatName(self, combatant)
  local known = self._names[combatant]
  assert(type(known) == "string", "source-tagged battle narration names combatant " .. tostring(combatant))
  assert(known ~= "", "source-tagged battle narration names combatant " .. tostring(combatant))
  return known
end

---@param self BattleTimeline
---@param combatant integer striking combatant under lookup
---@param move string move identity under lookup
---@return string catalog display name for the move identity
function moveName(self, combatant, move)
  local known = self._ownMoves[tostring(combatant) .. "\0" .. move]
  if type(known) == "string" then
    return known
  end
  assert(type(self._moveName) == "function", "source move tags resolve through the move catalog")
  local name = self._moveName(move)
  assert(type(name) == "string", "move catalog provides its display name")
  assert(name ~= "", "move catalog provides its display name")
  return name
end

---@param self BattleTimeline
---@param item string item identity under display lookup
---@return string catalog display name for the item identity
local function itemName(self, item)
  assert(type(self._itemName) == "function", "source item tags resolve through the item catalog")
  local name = self._itemName(item)
  assert(type(name) == "string", "item catalog provides its display name")
  assert(name ~= "", "item catalog provides its display name")
  return name
end

---@param view unknown battle view under condition lookup
---@param combatant integer identity under condition lookup
---@return string? persistent condition shown on this combatant
local function viewCondition(view, combatant)
  if type(view) ~= "table" then
    return nil
  end
  local record = view --[[@as table<string, unknown>]]
  for _, groupName in ipairs({ "own", "foes" }) do
    local group = record[groupName]
    if type(group) == "table" then
      for _, member in ipairs(group) do
        if type(member) == "table" then
          local mon = member --[[@as table<string, unknown>]]
          if mon.combatant == combatant and type(mon.condition) == "string" then
            return mon.condition --[[@as string]]
          end
        end
      end
    end
  end
  return nil
end

---@param self BattleTimeline
---@param move string move identity under ownership lookup
---@return integer? combatant identity owning the move, nil when no view named it
local function moveOwner(self, move)
  for key, _ in pairs(self._ownMoves) do
    local sep = key:find("\0", 1, true)
    if sep ~= nil and key:sub(sep + 1) == move then
      local owner = tonumber(key:sub(1, sep - 1))
      if type(owner) == "number" and owner % 1 == 0 then
        return owner --[[@as integer]]
      end
    end
  end
  return nil
end

---@param self BattleTimeline
---@param target integer damaged combatant under translation
---@param to integer checkpoint health under translation
---@param noBlink boolean? suppress health-box flicker for source reloads
local function enqueueHealth(self, target, to, noBlink)
  local shown = self:_shown(target)
  local maxHp = to
  if shown ~= nil and type(shown.maxHp) == "number" then
    maxHp = shown.maxHp --[[@as integer]]
  end
  -- BattleHpBar_CalculatePixelsChangeFrame steps once per source tick:
  -- one HP at a time from 48 max HP up, otherwise one bar pixel at a time.
  local ticks = BattleTimeline.HP_BAR_PIXELS
  if shown ~= nil and type(shown.hp) == "number" then
    local delta = math.abs(shown.hp --[[@as integer]] - to)
    if maxHp >= BattleTimeline.HP_BAR_PIXELS then
      ticks = delta
    else
      ticks = math.ceil(delta * BattleTimeline.HP_BAR_PIXELS / math.max(1, maxHp))
    end
  end
  ticks = math.max(1, ticks)
  enqueue(self, {
    kind = "hp",
    combatant = target,
    to = to,
    from = nil,
    duration = ticks,
    flicker = noBlink ~= true,
    flickerToggles = 0,
    requiresImage = self:_imageKeyFor(target),
  })
end

-- Forward declaration: explicit playback readers below fall back to the
-- cause identity owned further down beside the intent translators.
local causeMoveKey

---@param event table<string, unknown> sanitized kernel event carrying its explicit playback facts
---@return integer? combatant identity of the first named actor, nil for legacy emissions
local function explicitActor(event)
  local actors = event.actors --[[@as table<integer, unknown>?]]
  if type(actors) ~= "table" then
    return nil
  end
  local first = actors[1] --[[@as table<string, unknown>?]]
  if type(first) ~= "table" then
    return nil
  end
  local id = (first --[[@as table<string, unknown>]]).combatant
  if type(id) == "number" and id % 1 == 0 and id >= 1 then
    return id --[[@as integer]]
  end
  return nil
end

---@param event table<string, unknown> sanitized kernel event carrying its explicit playback facts
---@return integer? combatant identity of the first named target, nil for legacy emissions
local function explicitTarget(event)
  local targets = event.targets --[[@as table<integer, unknown>?]]
  if type(targets) ~= "table" then
    return nil
  end
  local first = targets[1] --[[@as table<string, unknown>?]]
  if type(first) ~= "table" then
    return nil
  end
  local id = (first --[[@as table<string, unknown>]]).combatant
  if type(id) == "number" and id % 1 == 0 and id >= 1 then
    return id --[[@as integer]]
  end
  return nil
end

---@param event table<string, unknown> sanitized kernel event carrying its explicit playback facts
---@return string executed move identity: explicit facts first, cause identity next
local function explicitMove(event)
  local move = event.move --[[@as table<string, unknown>?]]
  if type(move) == "table" and type(move.executed) == "string" then
    return move.executed --[[@as string]]
  end
  return causeMoveKey(event)
end

---@param self BattleTimeline
---@param event table<string, unknown> sanitized kernel event under translation
---@param packet table<string, unknown> delivery carrying launch identity and event-time views
---@param narrated table<string, boolean>? attack keys already narrated in this delivery
local function translateStruck(self, event, packet, narrated)
  local payload = event.payload --[[@as table<string, unknown>]]
  -- Explicit playback facts name the true attacker and recipient;
  -- only legacy emissions without them fall back to display order.
  local target = explicitTarget(event)
  if target == nil and type(payload.target) == "number" then
    target = payload.target --[[@as integer]]
  end
  assert(type(target) == "number", "strikes name their recipient")
  self._lastStruck = target
  local attacker = explicitActor(event)
  if attacker == nil then
    for _, id in ipairs(self._order) do
      if id ~= target then
        local shown = self:_shown(id)
        if shown ~= nil and shown.visible ~= false then
          attacker = id
          break
        end
      end
    end
  end
  local moveKey = explicitMove(event)
  local wording = moveUseText(self, attacker, moveKey)
  -- One attack occurrence narrates once across its hits: the first
  -- strike voices the attack while later hits keep their impact,
  -- sound, and checkpoint motion in native order. The announcement
  -- runs before the visual, and the visual runs once per action and
  -- phase behind that announcement. Strikes without an effect key
  -- keep generic voices; their action identity still scopes narration.
  local nativeKey = nativeEffectKeyOf(event)
  local occurrence = nil
  if nativeKey ~= nil or event.actionId ~= nil then
    occurrence = occurrenceIdentityOf(launchOf(packet), event, packet)
  end
  if occurrence ~= nil then
    if self._announced[occurrence] ~= true then
      self._announced[occurrence] = true
      enqueueMessage(self, wording, false, 0)
    end
    if nativeKey ~= nil then
      enqueueNativeEffect(self, event, packet)
    end
  else
    local narrationKey = BattlePresentationFlow.attackKey(attacker, moveKey)
    local already = narrated ~= nil and narrated[narrationKey] == true
    if not already then
      enqueueMessage(self, wording, false, 0)
      if narrated ~= nil then
        narrated[narrationKey] = true
      end
    end
    if nativeKey ~= nil then
      enqueueNativeEffect(self, event, packet)
    end
  end
  -- subscript_0002_UpdateHp: every landed hit plays one impact voice
  -- chosen by effectiveness and panned toward the struck side
  -- (OpponentData_PlayMoveSE), whether or not the move has a program.
  local effectiveness = payload.effectiveness
  local impact = BattleAudio.SINK_SOUNDS.impact
  if effectiveness == "super" then
    impact = BattleAudio.SINK_SOUNDS.impactSuper
  elseif effectiveness == "weak" then
    impact = BattleAudio.SINK_SOUNDS.impactWeak
  end
  local struckFoe = self._addressing[target] ~= "own"
  enqueue(self, {
    kind = "sound",
    cue = effectCue(impact, {
      pan = struckFoe and BattleAudio.SIDE_PAN.foe or BattleAudio.SIDE_PAN.player,
      foe = struckFoe,
    }),
    duration = 0,
  })
  local after = event.after --[[@as table<string, unknown>]]
  local hp = after.hp --[[@as table<string, unknown>?]]
  if type(hp) == "table" and type(hp[target]) == "number" then
    enqueueHealth(self, target, hp[target] --[[@as integer]], payload.noBlink == true)
  end
  -- subscript_0016_CriticalHit, then subscript_0021_MoveFollowupMessage
  -- (WaitButtonABTime 15 before the effectiveness line).
  if payload.critical == true then
    enqueueMessage(self, messageText(self, "battle/narration/critical-hit", {}), false, 30, true)
  end
  local sequenceHitIndex = payload.sequenceHitIndex
  local sequenceHitTotal = payload.sequenceHitTotal
  local finalHit = type(sequenceHitTotal) ~= "number" or sequenceHitIndex == sequenceHitTotal
  if finalHit and (effectiveness == "super" or effectiveness == "weak") then
    enqueue(self, { kind = "wait", duration = 15 })
    local key = effectiveness == "super" and "battle/narration/super-effective" or "battle/narration/not-very-effective"
    local line = messageText(self, key, {})
    enqueueMessage(self, line, false, 30, true)
  end
end

---@param id integer combatant identity under image lookup
---@return string|boolean exact battler image key, or false when the battler carries no image demand
function BattleTimeline:_imageKeyFor(id)
  -- The cue gates on the displayed combatant's exact canonical
  -- portrait selector. A battler without one carries no image demand:
  -- nothing plausible stands in for its picture.
  local function selectorOf(record)
    if type(record) == "table" and type(record.portraitSelector) == "string" and record.portraitSelector ~= "" then
      return "mon:" .. record.portraitSelector
    end
    return nil
  end
  if self._latest ~= nil then
    for _, group in ipairs({ self._latest.own, self._latest.foes }) do
      if type(group) == "table" then
        for _, record in ipairs(group) do
          if type(record) == "table" and record.combatant == id then
            local key = selectorOf(record)
            if key ~= nil then
              return key
            end
          end
        end
      end
    end
  end
  local shown = self:_shown(id)
  local key = selectorOf(shown)
  if key ~= nil then
    return key
  end
  return false
end

---@param self BattleTimeline
---@param event table<string, unknown> sanitized kernel event under translation
local function translateFaint(self, event)
  local payload = event.payload --[[@as table<string, unknown>]]
  local target = payload.combatant --[[@as integer]]
  -- The faint cry belongs to the animation; the retail flow announces
  -- the knockout after the battler's faint animation completes.
  local shown = self:_shown(target)
  local species = shown ~= nil and shown.species or nil
  local form = shown ~= nil and shown.form or nil
  if type(species) == "string" and species ~= "" then
    local foe = shown ~= nil and shown.side == 2
    enqueue(self, {
      kind = "sound",
      cue = cryCue(species, type(form) == "number" and form or nil, foe, 5, true),
      duration = 0,
    })
  end
  local foe = shown ~= nil and shown.side == 2
  enqueue(self, {
    kind = "sound",
    cue = effectCue(BattleAudio.SINK_SOUNDS.faint, {
      pan = foe and BattleAudio.SIDE_PAN.foe or BattleAudio.SIDE_PAN.player,
      foe = foe,
    }),
    duration = 0,
  })
  enqueue(self, {
    kind = "faint",
    combatant = target,
    duration = BattleTimeline.VANISH_TICKS,
    requiresImage = self:_imageKeyFor(target),
  })
  local address = self._addressing[target]
  local side = address == "wild" and "wild" or address == "foe" and "foe" or "own"
  local message = enqueueMessage(
    self,
    messageText(self, "battle/narration/fainted/" .. side, { combatName(self, target) }),
    false,
    BattleTimeline.AUTO_SCROLL_TICKS + 30,
    true
  )
  message.slideCombatant = target
end

---@param view table<string, unknown>? detached view carrying progression facts
---@param combatant integer combatant identity under lookup
---@return integer experience, integer? level
local function progressionOf(view, combatant)
  if type(view) == "table" and type(view.own) == "table" then
    for _, record in ipairs(view.own) do
      if type(record) == "table" and record.combatant == combatant then
        local exp = record.experience
        local level = record.level
        if type(exp) == "number" then
          local total = exp --[[@as integer]]
          local tier = (type(level) == "number" and level or nil) --[[@as integer?]]
          return total, tier
        end
      end
    end
  end
  return 0, nil
end

---@param self BattleTimeline
---@param levelUp table<string, unknown> boundary snapshot from the reward event
local function enqueueLevelUpStats(self, levelUp)
  local before = assert(levelUp.statsBefore, "level-up windows carry prior stats") --[[@as table<string, unknown>]]
  local after = assert(levelUp.statsAfter, "level-up windows carry recalculated stats") --[[@as table<string, unknown>]]
  local deltaRows, totalRows = {}, {}
  for _, stat in ipairs(LEVEL_UP_STATS) do
    local beforeValue = stat.field == "maxHp" and (before.maxHp or before.hp) or before[stat.field]
    local afterValue = stat.field == "maxHp" and (after.maxHp or after.hp) or after[stat.field]
    assert(type(beforeValue) == "number" and type(afterValue) == "number", "level-up snapshots carry all six stats")
    local beforeStat = beforeValue --[[@as number]]
    local afterStat = afterValue --[[@as number]]
    local delta = afterStat - beforeStat
    assert(delta >= 0, "level-up stat gains are non-negative")
    local sourceLabel = messageText(self, "battle/stat/" .. stat.key, {})
    local label = messageText(self, "battle/level-up/stat-name", { sourceLabel })
    deltaRows[#deltaRows + 1] = {
      label = label,
      value = messageText(self, "battle/level-up/stat-delta", { tostring(delta) }),
    }
    totalRows[#totalRows + 1] = {
      label = label,
      value = messageText(self, "battle/level-up/stat-total", { tostring(afterValue) }),
    }
  end
  local level = assert(levelUp.level, "level-up windows name their new level") --[[@as integer]]
  enqueue(self, { kind = "stats-window", level = level, page = "delta", rows = deltaRows, acknowledged = false })
  enqueue(self, { kind = "stats-window", level = level, page = "total", rows = totalRows, acknowledged = false })
end

---@param packet table<string, unknown> event delivery under inspection
---@param target integer recipient whose reward is being shown
---@return boolean true if the after view is a surviving player's wild victory
local function wildVictoryAtExperience(packet, target)
  local view = packet.after
  if
    type(view) ~= "table" or not BattlePresentationFlow.isWild(view --[[@as table<string, unknown>]])
  then
    return false
  end
  local foes = view.foes --[[@as table[]?]]
  local own = view.own --[[@as table[]?]]
  if type(foes) ~= "table" or #foes == 0 or type(own) ~= "table" then
    return false
  end
  local livingFoe = false
  for _, foe in ipairs(foes) do
    if type(foe.hp) == "number" and foe.hp > 0 then
      livingFoe = true
      break
    end
  end
  if livingFoe then
    return false
  end
  for _, mon in ipairs(own) do
    if mon.combatant == target and type(mon.hp) == "number" and mon.hp > 0 then
      return true
    end
  end
  return false
end

---@param self BattleTimeline
---@param event table<string, unknown> sanitized kernel event under translation
---@param packet table<string, unknown> delivery carrying the before and after views
local function translateExp(self, event, packet)
  local payload = event.payload --[[@as table<string, unknown>]]
  local target = payload.combatant --[[@as integer]]
  local gained = payload.gained --[[@as integer]]
  local _, beforeLevel = progressionOf(packet.before, target)
  local afterExp, afterLevel = progressionOf(packet.after, target)
  assert(type(gained) == "number" and gained >= 0, "experience events carry a non-negative award")
  if gained == 0 then
    return
  end
  if not self._wildVictoryMusicStarted and wildVictoryAtExperience(packet, target) then
    local music = BattlePresentationFlow.resultMusicSymbol("win", true)
    if music ~= nil then
      self._wildVictoryMusicStarted = true
      enqueue(self, { kind = "sound", cue = musicCue(music), duration = 0 })
    end
  end
  local boosted = payload.boosted == true
  local experienceKey = boosted and "battle/narration/experience/boosted" or "battle/narration/experience"
  enqueueMessage(
    self,
    messageText(self, experienceKey, { combatName(self, target), tostring(gained) }),
    false,
    BattleTimeline.AUTO_SCROLL_TICKS + 7,
    true
  )
  local levelUps = payload.levelUps --[[@as table[]?]]
  local levelUpByLevel = {}
  for _, levelUp in ipairs(levelUps or {}) do
    levelUpByLevel[levelUp.level] = levelUp
  end
  local segments = payload.expSegments --[[@as table[]?]]
  if type(segments) ~= "table" or #segments == 0 then
    local startExp = payload.experienceBefore or select(1, progressionOf(packet.before, target))
    local endExp = payload.experienceAfter or afterExp
    segments = {
      {
        level = beforeLevel or afterLevel or 1,
        startExp = startExp,
        targetExp = endExp,
        fromPixels = 0,
        toPixels = BattleTimeline.EXP_BAR_PIXELS,
      },
    }
  end
  for index, segment in ipairs(segments) do
    local level = assert(segment.level, "experience segments name their current level") --[[@as integer]]
    local startExp = assert(segment.startExp, "experience segments name their stored start") --[[@as integer]]
    local targetExp = assert(segment.targetExp, "experience segments name their exact end") --[[@as integer]]
    local fromPixels = assert(segment.fromPixels, "experience segments name their start pixel") --[[@as integer]]
    local toPixels = assert(segment.toPixels, "experience segments name their end pixel") --[[@as integer]]
    local levelUp = levelUpByLevel[level + 1]
    enqueue(self, {
      kind = "exp",
      combatant = target,
      targetExp = targetExp,
      targetLevel = levelUp ~= nil and levelUp.level or afterLevel or level,
      startExp = startExp,
      startLevel = level,
      duration = math.max(1, toPixels - fromPixels),
      soundStopTicks = math.max(8, toPixels - fromPixels),
      soundKey = "battle-exp:" .. tostring(target) .. ":" .. tostring(self._messageSeq) .. ":" .. tostring(index),
      levelUp = levelUp,
    })
    if levelUp ~= nil then
      local nextLevel = levelUp.level --[[@as integer]]
      enqueueMessage(
        self,
        messageText(self, "battle/narration/level-up", { combatName(self, target), tostring(nextLevel) }),
        false,
        0,
        true
      )
      enqueue(self, {
        kind = "sound",
        cue = fanfareCue(BattleAudio.SINK_SOUNDS.levelUp, true),
        duration = 0,
      })
      enqueueLevelUpStats(self, levelUp)
    end
  end
end

---@param self BattleTimeline
---@param event table<string, unknown> sanitized kernel event under translation
local function translateStats(self, event)
  local payload = event.payload --[[@as table<string, unknown>]]
  local target = payload.combatant --[[@as integer]]
  local shown = self:_shown(target)
  if shown ~= nil and type(payload.maxHpAfter) == "number" then
    shown.maxHp = payload.maxHpAfter
  end
end

---@param event table<string, unknown> event carrying its event-time checkpoint
---@return table<string, unknown>? event-time checkpoint exposed by the event
function eventObservation(event)
  local observation = event.observation
  if type(observation) == "table" then
    return observation --[[@as table<string, unknown>]]
  end
  -- Public presentation events expose the same checkpoint as `after`.
  local after = event.after
  return type(after) == "table" and after --[[@as table<string, unknown>?]] or nil
end

---@param self BattleTimeline
---@param target integer combatant identity under checkpoint lookup
---@param event table<string, unknown> sanitized kernel event carrying its event-time checkpoint
local function enqueueCheckpointHealth(self, target, event)
  local observation = eventObservation(event)
  local hp = type(observation) == "table" and observation.hp or nil
  if type(hp) == "table" and type(hp[target]) == "number" then
    local payload = event.payload --[[@as table<string, unknown>?]] or {}
    enqueueHealth(self, target, hp[target] --[[@as integer]], payload.noBlink == true)
  end
end

---@param self BattleTimeline
---@param event table<string, unknown> sanitized kernel event under translation
local function translateFainted(self, event)
  local payload = event.payload --[[@as table<string, unknown>]]
  -- Self-inflicted knockouts (Memento and its kin) address their victim
  -- as the move target rather than the faint owner.
  local target = payload.target
  if type(target) ~= "number" then
    target = payload.combatant
  end
  if type(target) ~= "number" then
    return
  end
  enqueue(self, {
    kind = "faint",
    combatant = target,
    duration = BattleTimeline.VANISH_TICKS,
    requiresImage = self:_imageKeyFor(target),
  })
  local address = self._addressing[target]
  local variant = address == "own" and "own" or address == "wild" and "wild" or "foe"
  local message = enqueueMessage(
    self,
    messageText(self, "battle/narration/fainted/" .. variant, {
      combatName(self, target --[[@as integer]]),
    }),
    false,
    BattleTimeline.AUTO_SCROLL_TICKS + 30,
    true
  )
  message.slideCombatant = target
end

---@param self BattleTimeline
---@param event table<string, unknown> sanitized kernel event under translation
---@param holdTicks integer? explicit move-announcement hold
---@param ackSkipsHold boolean? whether acknowledgement skips the explicit hold
local function translateMoveUsed(self, event, holdTicks, ackSkipsHold)
  local payload = event.payload --[[@as table<string, unknown>]]
  if payload.phase == "release" and explicitMove(event) == "BIDE" then
    assert(type(event.sourceText) == "string", "Bide release requires its selected source message")
    enqueueMessage(self, event.sourceText --[[@as string]], false, 30, true)
    return
  end
  local moveKey = explicitMove(event)
  local user = explicitActor(event)
  if user == nil and type(payload.user) == "number" then
    user = payload.user --[[@as integer]]
  end
  if user == nil then
    user = moveOwner(self, moveKey)
  end
  local narration = moveUseText(self, user, moveKey)
  enqueueMessage(self, narration, false, holdTicks, ackSkipsHold)
end

---@param event table<string, unknown> sanitized kernel event
---@return string
function causeMoveKey(event)
  local cause = event.cause --[[@as table<string, unknown>]]
  assert(type(cause.key) == "string" and cause.key ~= "", "move narration has a semantic cause key")
  return cause.key
end

-- Task_RecallPokemon and Task_PokemonSendOut voice the ball sound panned
-- at the switching battler's side.
---@param self BattleTimeline
---@param combatant integer recalled or arriving combatant
local function enqueueBallSound(self, combatant)
  local own = self._addressing[combatant] == "own"
  enqueue(self, {
    kind = "sound",
    cue = effectCue(BattleAudio.SINK_SOUNDS.ballOpen, {
      pan = own and BattleAudio.SIDE_PAN.player or BattleAudio.SIDE_PAN.foe,
    }),
    duration = 0,
  })
end

-- ShowPartyGauge/HidePartyGauge: the trainer's ball gauge slides in with its
-- start sound, or fades out, before the command completes. The gauge sprites
-- are not staged, so only the retail pacing and sound are reproduced.
---@param self BattleTimeline
---@param own boolean whether the switching battler is on the player side
---@param ticks integer retail frames until the gauge task completes
---@param show boolean true for ShowPartyGauge
local function enqueuePartyGauge(self, own, ticks, show)
  if show then
    enqueue(self, {
      kind = "sound",
      cue = effectCue(BattleAudio.SINK_SOUNDS.partyGaugeShow, {
        pan = own and BattleAudio.SIDE_PAN.player or BattleAudio.SIDE_PAN.foe,
      }),
      duration = 0,
    })
  end
  enqueue(self, { kind = "wait", duration = ticks })
end

-- The ball-colored poof of a recall or send-out: the staged sBallColors
-- fade target of the mon's ball, nil when the mon or the source is unknown.
---@param self BattleTimeline
---@param combatant integer battler leaving or entering its ball
---@return integer? color RGB555 fade target
local function ballFadeColorOf(self, combatant)
  if self._ballFadeColor == nil then
    return nil
  end
  local ballKey = nil
  local shown = self._battlers[combatant]
  if shown ~= nil then
    ballKey = shown.ballKey
  end
  local view = self._latest
  if type(view) == "table" then
    for _, group in ipairs({ view.own, view.foes }) do
      if type(group) == "table" then
        for _, record in ipairs(group) do
          if type(record) == "table" and record.combatant == combatant and type(record.ballKey) == "string" then
            ballKey = record.ballKey
          end
        end
      end
    end
  end
  if type(ballKey) ~= "string" then
    return nil
  end
  return self._ballFadeColor(ballKey)
end

---@param self BattleTimeline
---@param combatant integer combatant to reveal
---@param holdHud boolean? keep the health box hidden for a later slide-in
local function enqueueReveal(self, combatant, holdHud)
  local fadeColor = ballFadeColorOf(self, combatant)
  enqueue(self, {
    kind = "reveal",
    combatant = combatant,
    holdHud = holdHud,
    fadeColor = fadeColor,
    duration = fadeColor ~= nil and BattleTimeline.BALL_SCALE_TICKS + BattleTimeline.BALL_FADE_TICKS
      or BattleTimeline.VANISH_TICKS,
    requiresImage = self:_imageKeyFor(combatant),
  })
end

---@param self BattleTimeline
---@param event table<string, unknown>? event whose checkpoint carries health, nil for the latest view
---@return integer? hp, integer? maxHp of the lead foe
function foeHealthAt(self, event)
  local view = self._latest
  local foes = type(view) == "table" and view.foes or nil
  local foe = type(foes) == "table" and foes[1] or nil
  if type(foe) ~= "table" or type(foe.combatant) ~= "number" then
    return nil, nil
  end
  local hp = foe.hp
  local observation = event ~= nil and eventObservation(event) or nil
  local checkpoint = type(observation) == "table" and observation.hp or nil
  if type(checkpoint) == "table" and type(checkpoint[foe.combatant]) == "number" then
    hp = checkpoint[foe.combatant]
  end
  return hp, --[[@as integer?]]
    foe.maxHp --[[@as integer?]]
end

---@param self BattleTimeline
---@return boolean true when the player fields more than one battler
local function playerDoubles(self)
  local view = self._latest
  local own = type(view) == "table" and view.own or nil
  local active = 0
  if type(own) == "table" then
    for _, record in ipairs(own) do
      if type(record) == "table" and record.active ~= false and record.position ~= nil then
        active = active + 1
      end
    end
  end
  return active > 1
end

-- BattleControllerOpponent_GetReturnMessage: a single player recall scales
-- its line by the foe health lost since the last switch-in.
---@param self BattleTimeline
---@param departed integer withdrawing combatant
---@param event table<string, unknown> switch event carrying its checkpoint
---@return string
function recallText(self, departed, event)
  local name = combatName(self, departed)
  if self._addressing[departed] ~= "own" then
    local trainer = assert(firstTrainer(self), "opponent recall carries its trainer identity")
    local trainerName = assert(trainer.name, "trainer recall carries the opponent name")
    return messageText(
      self,
      "battle/narration/trainer-withdrew",
      { trainerClassText(self, trainer), trainerName, name }
    )
  end
  local mark = self._foeHpMark
  local hp = foeHealthAt(self, event)
  local key = "battle/narration/player-withdrew/come-back"
  if playerDoubles(self) or type(mark) ~= "number" or mark <= 0 or type(hp) ~= "number" then
    return messageText(self, key, { name })
  end
  local value = math.floor(100 * (mark - hp) / mark)
  if value <= 0 then
    key = "battle/narration/player-withdrew/switch-out"
  elseif value < 25 then
    key = "battle/narration/player-withdrew/come-back"
  elseif value < 50 then
    key = "battle/narration/player-withdrew/good"
  elseif value < 75 then
    key = "battle/narration/player-withdrew/ok"
  else
    key = "battle/narration/player-withdrew/enough"
  end
  return messageText(self, key, { name })
end

-- BattleControllerOpponent_GetSendOutMessage for the player side, then the
-- arrival with its cry (subscript_0009_SwitchMon).
---@param self BattleTimeline
---@param incoming integer arriving combatant
---@param event table<string, unknown>? arrival event carrying its checkpoint
---@param switching boolean? true for subscript SwitchMon/ReplaceFainted sequencing: party gauge, settle wait, health box slide-in
function enqueueSendOut(self, incoming, event, switching)
  local ownSide = self._addressing[incoming] == "own"
  if switching == true then
    enqueuePartyGauge(self, ownSide, BattleTimeline.PARTY_GAUGE_SHOW_TICKS, true)
  end
  if ownSide then
    local name = combatName(self, incoming)
    local key = "battle/narration/player-sent-out"
    local hp, maxHp = foeHealthAt(self, event)
    if not playerDoubles(self) and type(hp) == "number" and type(maxHp) == "number" and maxHp > 0 then
      local value = hp == 0 and 1000 or math.floor(1000 * hp / maxHp)
      if value < 100 then
        key = "battle/narration/player-sent-out/foe-weak"
      elseif value < 325 then
        key = "battle/narration/player-sent-out/foe-hurt"
      elseif value < 550 then
        key = "battle/narration/player-sent-out/go-for-it"
      elseif value < 775 then
        key = "battle/narration/player-sent-out/in-charge"
      end
    end
    enqueueMessage(self, messageText(self, key, { name }), false, 0)
  else
    local trainer = firstTrainer(self)
    if trainer ~= nil then
      local trainerName = assert(trainer.name, "trainer send-outs carry the opponent name")
      local monName = combatName(self, incoming)
      enqueueMessage(
        self,
        messageText(
          self,
          "battle/narration/trainer-sent-out",
          { trainerClassText(self, trainer), trainerName, monName }
        ),
        false,
        0
      )
    end
  end
  if switching == true then
    enqueuePartyGauge(self, ownSide, BattleTimeline.PARTY_GAUGE_HIDE_TICKS, false)
  end
  enqueueBallThrow(self, incoming, ownSide and "player" or "foe")
  enqueueBallSound(self, incoming)
  local species, form = speciesOf(self, incoming)
  if species ~= nil then
    enqueue(self, {
      kind = "sound",
      cue = cryCue(species, form, not ownSide),
      duration = 0,
    })
  end
  enqueueReveal(self, incoming, switching)
  if switching == true then
    -- WaitTime 72, then HealthbarSlideIn; the arriving health box stays
    -- hidden until that slide.
    enqueue(self, { kind = "wait", duration = BattleTimeline.SWITCH_SETTLE_TICKS })
    enqueue(self, { kind = "hud-slide", combatant = incoming, direction = "in" })
  end
end

---@param self BattleTimeline
---@param combatant integer battler under lookup
---@return string? species, integer? form from the newest view naming it
function speciesOf(self, combatant)
  local view = self._latest
  if type(view) == "table" then
    for _, group in ipairs({ view.own, view.foes }) do
      if type(group) == "table" then
        for _, record in ipairs(group) do
          if type(record) == "table" and record.combatant == combatant and type(record.species) == "string" then
            local form = type(record.form) == "number" and record.form or nil
            return record.species, --[[@as string]]
              form --[[@as integer?]]
          end
        end
      end
    end
  end
  return nil, nil
end

-- Health facts drive the bar without inventing narration absent a native
-- message record; source scripts emit their own message events where needed.
local function translateHealed(self, event)
  local target = (event.payload --[[@as table<string, unknown>]]).target
  if type(target) == "number" then
    enqueueCheckpointHealth(self, target, event)
  end
end

---@param self BattleTimeline
---@param event table<string, unknown>
local function translateFlee(self, event)
  local payload = event.payload --[[@as table<string, unknown>]]
  if payload.escaped == true then
    -- The terminal result owns the successful-escape narration; the
    -- event itself yields its moment with the parting voice in order.
    enqueue(self, {
      kind = "sound",
      cue = effectCue(BattleAudio.SINK_SOUNDS.escape),
      duration = 0,
    })
  else
    -- subscript_0008_RunAwayFail: msg 42 (ending in \r), WaitButtonABTime 30.
    enqueueMessage(
      self,
      messageText(self, "battle/narration/cannot-escape", {}),
      false,
      BattleTimeline.AUTO_SCROLL_TICKS + 30,
      true
    )
  end
end

---@param self BattleTimeline
---@param event table<string, unknown>
local function translateStage(self, event)
  local payload = event.payload --[[@as table<string, unknown>]]
  local before = payload.before
  local after = payload.after
  local statKey = payload.stat
  assert(type(statKey) == "string" and statKey ~= "", "stage changes name a battle stat")
  local stat = messageText(self, "battle/stat/" .. tostring(statKey), {})
  local target = type(payload.target) == "number" and payload.target or explicitTarget(event)
  local address = target ~= nil and self._addressing[target] or "own"
  local side = address == "wild" and "wild" or address == "foe" and "foe" or "own"
  local cause = event.cause --[[@as table<string, unknown>?]]
  if type(before) == "number" and type(after) == "number" and after ~= before then
    local shown = type(payload.target) == "number" and self:_shown(payload.target --[[@as integer]]) or nil
    if type(cause) == "table" and cause.kind == "item" and type(cause.item) == "string" then
      local name = combatName(self, assert(target, "stage narration names its target"))
      if shown ~= nil and shown.side == 1 then
        -- The player's bag task prints msg_0197_01203.
        enqueueMessage(self, messageText(self, "battle/narration/bag-stat-up", { name, stat }), false)
      else
        local strength = math.abs(after - before) >= 2 and "sharp" or "normal"
        enqueueMessage(
          self,
          messageText(
            self,
            "battle/narration/trainer-stat-raised/" .. strength .. "/" .. side,
            { itemName(self, cause.item), name, stat }
          ),
          false
        )
      end
      return
    end
    local action = after > before and (math.abs(after - before) >= 2 and "up/sharp" or "up/normal")
      or (math.abs(after - before) >= 2 and "down/harsh" or "down/normal")
    local key = "battle/narration/stage/" .. action .. "/" .. side
    local name = combatName(self, assert(target, "stage narration names its target"))
    -- subscript_0012_UpdateStatStage holds each stat line for 30 frames.
    enqueueMessage(self, messageText(self, key, { name, stat }), false, 30, true)
  elseif before == 6 then
    local name = combatName(self, assert(target, "stage narration names its target"))
    enqueueMessage(self, messageText(self, "battle/narration/stage/max-up/" .. side, { name, stat }), false, 30, true)
  elseif before == -6 then
    local name = combatName(self, assert(target, "stage narration names its target"))
    enqueueMessage(self, messageText(self, "battle/narration/stage/max-down/" .. side, { name, stat }), false, 30, true)
  end
end

---@param self BattleTimeline
---@param event table<string, unknown>
---@param packet table<string, unknown> event delivery carrying before view under narration
local function translateItem(self, event, packet)
  local payload = event.payload --[[@as table<string, unknown>]]
  if type(payload.refused) == "string" then
    if payload.refused == "no_effect" or payload.refused == "invalid_target" then
      enqueueMessage(self, messageText(self, "battle/narration/item-no-effect", {}), false)
    else
      enqueueMessage(self, messageText(self, "battle/narration/item-could-not-be-used", {}), false)
    end
    return
  end
  local itemKey = payload.item
  assert(type(itemKey) == "string", "item narration carries its item identity")
  itemKey = itemKey --[[@as string]]
  local itemText = itemName(self, itemKey)
  local actor = explicitActor(event)
  local shown = actor ~= nil and self:_shown(actor) or nil
  local playerUse = not (type(shown) == "table" and shown.side == 2)
  -- The bag subscripts and the battle party menu voice SEQ_SE_DP_KAIFUKU
  -- at the user's pan before the use line.
  enqueue(self, {
    kind = "sound",
    cue = effectCue(BattleAudio.SINK_SOUNDS.recovery, {
      pan = playerUse and BattleAudio.SIDE_PAN.player or BattleAudio.SIDE_PAN.foe,
      foe = not playerUse,
    }),
    duration = 0,
  })
  if playerUse then
    -- The player's bag task narrates msg_0197_01206.
    enqueueMessage(self, messageText(self, "battle/narration/bag-used-item", { itemText }), false)
  else
    local trainer = assert(firstTrainer(self), "trainer item use carries its trainer identity")
    local trainerName = assert(trainer.name, "trainer item use carries the trainer name")
    enqueueMessage(
      self,
      messageText(
        self,
        "battle/narration/trainer-used-item",
        { trainerClassText(self, trainer), trainerName, itemText }
      ),
      false
    )
  end
  local target = type(payload.target) == "table" and payload.target.combatant or nil
  if type(target) ~= "number" then
    local cause = event.cause --[[@as table<string, unknown>?]]
    target = type(cause) == "table" and cause.combatant or nil
  end
  if type(target) == "number" and target % 1 == 0 then
    ---@cast target integer
    local who = combatName(self, target)
    local beforeCondition = viewCondition(packet.before, target)
    local checkpoint = eventObservation(event)
    local checkpointCombatants = type(checkpoint) == "table" and checkpoint.combatants or nil
    local checkpointTarget = type(checkpointCombatants) == "table" and checkpointCombatants[target] or nil
    local afterCondition = type(checkpointTarget) == "table" and checkpointTarget.condition or nil
    if type(beforeCondition) == "string" and afterCondition ~= beforeCondition then
      local cureKeys = {
        sleep = "bag-woke-up",
        poison = "bag-cured-poison",
        toxic = "bag-cured-poison",
        burn = "bag-healed-burn",
        freeze = "bag-thawed",
        paralysis = "bag-cured-paralysis",
        confusion = "bag-snapped-out",
      }
      local cureKey = cureKeys[beforeCondition]
      if playerUse and cureKey ~= nil then
        enqueueMessage(self, messageText(self, "battle/narration/" .. cureKey, { who }), false)
      end
    end
    if type(payload.restored) == "number" and payload.restored > 0 then
      enqueueCheckpointHealth(self, target, event)
      if playerUse then
        enqueueMessage(
          self,
          messageText(self, "battle/narration/bag-restored-hp", { who, tostring(payload.restored) }),
          false
        )
      end
    end
  end
  if type(payload.restoredPp) == "number" and payload.restoredPp > 0 then
    -- Battle party-menu result for PP servings (msg_0006_00087).
    enqueueMessage(self, messageText(self, "battle/narration/pp-restored", {}), false)
  end
  if type(payload.item) == "string" and type(self._battleItemUse) == "function" then
    local effects = self._battleItemUse(payload.item)
    if type(effects) == "table" then
      if effects.guardSpec == true then
        if playerUse then
          enqueueMessage(self, messageText(self, "battle/narration/bag-guard-spec", {}), false)
        end
      end
      local stages = effects.stages
      if
        type(stages) == "table"
        and type(stages.critical) == "number"
        and stages.critical > 0
        and type(target) == "number"
        and target % 1 == 0
      then
        enqueueMessage(
          self,
          messageText(self, "battle/narration/bag-getting-pumped", {
            combatName(self, target --[[@as integer]]),
          }),
          false
        )
      end
    end
  end
end

-- Narrates a source move-learning record with its ordered source tags.
---@param messageKey string semantic key for the retail message record
---@param targetField string payload field naming the combatant
---@param moveField string payload field naming the move
---@return fun(self: BattleTimeline, event: table<string, unknown>)
local function moveOutcome(messageKey, targetField, moveField)
  local function translate(self, event)
    local payload = event.payload --[[@as table<string, unknown>]]
    local target = payload[targetField]
    assert(type(target) == "number", "move outcome names its battler")
    target = target --[[@as integer]]
    local move = payload[moveField]
    assert(type(move) == "string", "move outcome names its move")
    move = move --[[@as string]]
    enqueueMessage(
      self,
      messageText(self, messageKey, { combatName(self, target), moveName(self, target, move) }),
      false
    )
  end
  return translate
end

---@param self BattleTimeline
---@param event table<string, unknown>
---@param packet table<string, unknown> delivery carrying launch identity and event-time views
local function translateTransformed(self, event, packet)
  -- The transform narration runs before its selected native program
  -- while the essential appearance below still applies synchronously:
  -- the visual update is never silenced, even on paths where optional
  -- artwork is suppressed.
  local payload = event.payload --[[@as table<string, unknown>]]
  local target = payload.target
  assert(type(target) == "number", "transform target is named")
  target = target --[[@as integer]]
  local who = combatName(self, target)
  local copied = payload.copiedFrom
  if type(copied) == "number" then
    local donor = assert(self:_shown(copied --[[@as integer]]), "transform donor is visible")
    local speciesKey = assert(donor.species, "transform donor view carries its species")
    local speciesName = type(self._speciesName) == "function" and self._speciesName(speciesKey) or nil
    assert(type(speciesName) == "string" and speciesName ~= "", "transform source tags resolve the species name")
    enqueueMessage(self, messageText(self, "battle/narration/transformed", { who, speciesName }), false)
  end
  if nativeEffectKeyOf(event) ~= nil then
    enqueueNativeEffect(self, event, packet)
  end
  -- The displayed appearance tracks the copied battler even when
  -- effects are suppressed: the disabled animation path still applies
  -- the essential visual update behind its native wait.
  local donorId = BattlePresentationFlow.transformDonor(event)
  if donorId ~= nil then
    local donor = self:_shown(donorId --[[@as integer]])
    local shown = self:_shown(target --[[@as integer]])
    if donor ~= nil and shown ~= nil and type(donor.species) == "string" then
      shown.species = donor.species
      if type(donor.form) == "number" then
        shown.form = donor.form
      end
      -- The transformed battler draws the donor's picture, never the
      -- stale pre-transform selector: the exact canonical selector
      -- switches to the donor's alongside the species and form.
      if type(donor.portraitSelector) == "string" and donor.portraitSelector ~= "" then
        shown.portraitSelector = donor.portraitSelector
      end
      if donor.gender == "male" or donor.gender == "female" or donor.gender == "genderless" then
        shown.gender = donor.gender
      end
    end
  end
end

-- Replacements name their departure and arrival combatants; older shapes
-- named a withdrawing battler plus its incoming record.
---@param self BattleTimeline
---@param event table<string, unknown>
local function translateSwitch(self, event)
  local payload = event.payload --[[@as table<string, unknown>]]
  local cause = event.cause --[[@as table<string, unknown>?]]
  local replacesFaint = type(cause) == "table" and cause.kind == "faint"
  local departed = payload.from
  if type(departed) ~= "number" then
    departed = payload.combatant
  end
  if type(departed) == "number" and not replacesFaint then
    enqueueMessage(self, recallText(self, departed --[[@as integer]], event), false, 0)
    enqueueBallSound(self, departed --[[@as integer]])
    local fadeColor = ballFadeColorOf(self, departed --[[@as integer]])
    enqueue(self, {
      kind = "withdraw",
      combatant = departed,
      fadeColor = fadeColor,
      duration = fadeColor ~= nil and BattleTimeline.BALL_FADE_TICKS + BattleTimeline.BALL_SCALE_TICKS
        or BattleTimeline.VANISH_TICKS,
      requiresImage = self:_imageKeyFor(departed),
      keepHud = true,
    })
    enqueue(self, { kind = "hud-slide", combatant = departed, direction = "out" })
  end
  local incoming = payload.to
  if type(incoming) ~= "number" then
    incoming = payload.replacement
  end
  if type(incoming) ~= "number" then
    incoming = payload.incoming
  end
  if type(incoming) == "number" then
    enqueueSendOut(self, incoming --[[@as integer]], event, true)
  end
  -- SwitchAndUpdateMon re-marks the foe health behind recall wording.
  self._foeHpMark = foeHealthAt(self, event)
end

---@param self BattleTimeline
---@param event table<string, unknown>
local function translateStatusGate(self, event)
  local payload = event.payload --[[@as table<string, unknown>]]
  local target = nil
  if type(payload.combatant) == "number" then
    target = payload.combatant --[[@as integer]]
  else
    target = explicitTarget(event)
  end
  local address = target ~= nil and self._addressing[target] or "own"
  local side = address == "wild" and "wild" or address == "foe" and "foe" or "own"
  local outcome = payload.outcome == "woke" and "woke" or payload.outcome == "thawed" and "thawed" or nil
  local condition = payload.key == "sleep" and "asleep" or payload.key
  local route = outcome or (condition == "paralysis" and "paralysis" or condition == "freeze" and "freeze" or "asleep")
  local key = "battle/narration/status-gate/" .. tostring(route) .. "/" .. side
  assert(type(target) == "number", "status gate narration names its battler")
  local name = combatName(self, target)
  enqueueMessage(self, messageText(self, key, { name }), false)
end

-- Forcing and item moves narrate through their target: any following
-- switch event owns the withdrawal/reveal presentation.
-- Pure action bookkeeping with no observable change: the matching strike,
-- switch, item, or flee event already carries the moment.
local function translateSilent(_, event)
  local _ = event
end

---@param self BattleTimeline
---@param event table<string, unknown>
local function translateIntent(self, event)
  -- Intent packets carry mechanical targeting facts. The native script's
  -- message event owns the retail narration and its placeholder tags.
  translateSilent(self, event)
end

-- Reserve arrivals outside the replacement switch path still reveal their
-- battler; any withdrawal narration belongs to the switch.
---@param self BattleTimeline
---@param event table<string, unknown>
local function translateJoin(self, event)
  local incoming = (event.payload --[[@as table<string, unknown>]]).combatant
  if type(incoming) == "number" then
    enqueueReveal(self, incoming --[[@as integer]])
  end
end

local function translateMissed(self, event)
  local payload = event.payload --[[@as table<string, unknown>]]
  if payload.reason == "failed" then
    enqueueMessage(self, messageText(self, "battle/narration/move-failed", {}), false, 30, true)
    return
  end
  translateMoveUsed(self, event, 30, true)
  -- subscript_0007_Miss names the attacker (msg_0197_00012-00014).
  local attacker = explicitActor(event)
  local address = attacker ~= nil and self._addressing[attacker] or "own"
  local variant = address == "wild" and "wild" or address == "foe" and "foe" or "own"
  local key = "battle/narration/missed/" .. variant
  local name = combatName(self, assert(attacker, "miss narration names its attacker"))
  local text = messageText(self, key, { name })
  enqueueMessage(self, text, false, 30, true)
end

local function translateMultiHit(self, event)
  local hits = (event.payload --[[@as table<string, unknown>]]).hits
  assert(type(hits) == "number" and hits > 1 and hits % 1 == 0, "multi-hit summary carries connected hit count")
  enqueueMessage(self, messageText(self, "battle/narration/multi-hit", { tostring(hits) }), false, 30, true)
end

local function translateAvoided(self, event)
  local target = explicitTarget(event)
  local address = target ~= nil and self._addressing[target] or "own"
  local variant = address == "wild" and "wild" or address == "foe" and "foe" or "own"
  local name = combatName(self, assert(target, "miss avoidance narration names its battler"))
  enqueueMessage(self, messageText(self, "battle/narration/avoided/" .. variant, { name }), false, 30, true)
end

local function translateImmune(self, event)
  local payload = event.payload --[[@as table<string, unknown>]]
  local target = type(payload.target) == "number" and payload.target or explicitTarget(event)
  local address = target ~= nil and self._addressing[target] or "own"
  local variant = address == "wild" and "wild" or address == "foe" and "foe" or "own"
  local name = combatName(self, assert(target, "immunity narration names its battler"))
  enqueueMessage(self, messageText(self, "battle/narration/immune/" .. variant, { name }), false, 30, true)
end

---@param self BattleTimeline
---@param event table<string, unknown>
local function translateStatus(self, event)
  local payload = event.payload --[[@as table<string, unknown>]]
  local target = type(payload.target) == "number" and payload.target or explicitTarget(event)
  local address = target ~= nil and self._addressing[target] or "own"
  local side = address == "wild" and "wild" or address == "foe" and "foe" or "own"
  local status = tostring(payload.key)
  local key = "battle/narration/status/" .. status .. "/" .. side
  assert(type(target) == "number", "status narration names its target")
  local name = combatName(self, target)
  enqueueMessage(self, messageText(self, key, { name }), false, 30, true)
end

---@param self BattleTimeline
---@param event table<string, unknown>
local function translateCured(self, event)
  local payload = event.payload --[[@as table<string, unknown>]]
  local cause = event.cause --[[@as table<string, unknown>?]]
  if type(cause) == "table" and cause.kind == "item" then
    return
  end
  local target = nil
  if type(payload.target) == "number" then
    target = payload.target --[[@as integer]]
  else
    target = explicitTarget(event)
  end
  local key = tostring(payload.key)
  local address = target ~= nil and self._addressing[target] or "own"
  local side = address == "wild" and "wild" or address == "foe" and "foe" or "own"
  local route = key == "freeze" and "thawed"
    or key == "paralysis" and "paralysis-healed"
    or key == "confusion" and "confusion-cured"
    or nil
  if route ~= nil then
    local messageKey = "battle/narration/cured/" .. route .. "/" .. side
    assert(type(target) == "number", "cured-status narration names its target")
    enqueueMessage(self, messageText(self, messageKey, { combatName(self, target) }), false)
  end
end

---@param self BattleTimeline
---@param event table<string, unknown>
local function translateTick(self, event)
  local payload = event.payload --[[@as table<string, unknown>]]
  local target = payload.combatant
  if type(target) == "number" then
    local address = self._addressing[target]
    local side = address == "wild" and "wild" or address == "foe" and "foe" or "own"
    local key = "battle/narration/residual/" .. tostring(payload.key) .. "/" .. side
    enqueueMessage(
      self,
      messageText(self, key, {
        combatName(self, target --[[@as integer]]),
      }),
      false,
      30,
      true
    )
    enqueueCheckpointHealth(self, target --[[@as integer]], event)
  end
end

-- subscript_0063_Recoil_1_4: the attacker's bar moves, then its line holds.
---@param self BattleTimeline
---@param event table<string, unknown>
local function translateRecoil(self, event)
  local target = (event.payload --[[@as table<string, unknown>]]).target
  if type(target) == "number" then
    enqueueCheckpointHealth(self, target --[[@as integer]], event)
    local address = self._addressing[target]
    local side = address == "wild" and "wild" or address == "foe" and "foe" or "own"
    enqueueMessage(
      self,
      messageText(self, "battle/narration/recoil/" .. side, {
        combatName(self, target --[[@as integer]]),
      }),
      false,
      30,
      true
    )
  end
end

-- subscript_0024_DrainHalfDamageDealt: the drainer's bar fills, then the
-- line names the battler the energy came from.
---@param self BattleTimeline
---@param event table<string, unknown>
local function translateDrained(self, event)
  local drainer = (event.payload --[[@as table<string, unknown>]]).target
  if type(drainer) ~= "number" then
    return
  end
  enqueueCheckpointHealth(self, drainer --[[@as integer]], event)
  local source = self._lastStruck
  if type(source) == "number" and source ~= drainer then
    local address = self._addressing[source]
    local side = address == "wild" and "wild" or address == "foe" and "foe" or "own"
    enqueueMessage(
      self,
      messageText(self, "battle/narration/drained/" .. side, {
        combatName(self, source --[[@as integer]]),
      }),
      false,
      30,
      true
    )
  end
end
local translateLeveled = translateHealed
local translateLearn = moveOutcome("battle/narration/learn-move", "combatant", "move")
local translateDeclined = moveOutcome("battle/narration/did-not-learn", "combatant", "move")
local function translateSketched(self, event)
  local payload = event.payload --[[@as table<string, unknown>]]
  local targetValue = payload.target
  assert(type(targetValue) == "number", "Sketch event names its user")
  local target = targetValue --[[@as integer]]
  local copiedValue = payload.copied
  assert(type(copiedValue) == "string", "Sketch event names its copied move")
  local copied = copiedValue --[[@as string]]
  local address = self._addressing[target]
  local side = address == "wild" and "wild" or address == "foe" and "foe" or "own"
  enqueueMessage(
    self,
    messageText(
      self,
      "battle/narration/sketched/" .. side,
      { combatName(self, target), moveName(self, target, copied) }
    ),
    false
  )
end
local translateMimicked = translateSilent
local function translateCharged(self, event)
  local targetValue = (event.payload --[[@as table<string, unknown>]]).target
  assert(type(targetValue) == "number", "charged event names its battler")
  local target = targetValue --[[@as integer]]
  local address = self._addressing[target]
  local side = address == "wild" and "wild" or address == "foe" and "foe" or "own"
  enqueueMessage(self, messageText(self, "battle/narration/charged/" .. side, { combatName(self, target) }), false)
end
local function translateProtected(self, event)
  local target = (event.payload --[[@as table<string, unknown>]]).target
  local address = type(target) == "number" and self._addressing[target] or "own"
  local variant = address == "wild" and "wild" or address == "foe" and "foe" or "own"
  local key = "battle/narration/protected/" .. variant
  assert(type(target) == "number", "protection narration names its battler")
  local name = combatName(self, target)
  enqueueMessage(self, messageText(self, key, { name }), false)
end
local function translateSubstituteBroke(self, event)
  local target = (event.payload --[[@as table<string, unknown>]]).target
  assert(type(target) == "number", "substitute event names its battler")
  local address = self._addressing[target]
  local side = address == "wild" and "wild" or address == "foe" and "foe" or "own"
  enqueueMessage(
    self,
    messageText(self, "battle/narration/substitute-broke/" .. side, { combatName(self, target) }),
    false
  )
end

---@param self BattleTimeline
---@param event table<string, unknown>
local function translateDelayed(self, event)
  local target = (event.payload --[[@as table<string, unknown>]]).target
  if type(target) == "number" then
    local address = self._addressing[target]
    local side = address == "wild" and "wild" or address == "foe" and "foe" or "own"
    enqueueMessage(self, messageText(self, "battle/narration/foretold/" .. side, { combatName(self, target) }), false)
  end
end

---@param self BattleTimeline
---@param event table<string, unknown> capture event under translation
---@return integer? the single wild foe under capture
local function captureTargetOf(self, event)
  local target = BattlePresentationFlow.captureTarget(event)
  if target == nil then
    target = explicitTarget(event)
  end
  if target == nil and self._latest ~= nil then
    local foes = (self._latest --[[@as table<string, unknown>]]).foes
    local first = type(foes) == "table" and foes[1] or nil
    if type(first) == "table" and type(first.combatant) == "number" then
      target = first.combatant --[[@as integer]]
    end
  end
  return target
end

-- Ball sounds pan to the foe side like the source's PlaySE_SetPan(.., 117).
---@param symbol string staged ball sound symbol
---@return table<string, unknown> typed effect cue
local function ballCue(symbol)
  return effectCue(symbol, { pan = BattleAudio.SIDE_PAN.foe, foe = true })
end

-- sBallThrowBounceSounds (asm/battle_anim_data.s): ground-bounce frame and sound.
local BALL_BOUNCE_SOUNDS = {
  { frame = 1, symbol = BattleAudio.SINK_SOUNDS.ballBounce1 },
  { frame = 8, symbol = BattleAudio.SINK_SOUNDS.ballBounce1 },
  { frame = 14, symbol = BattleAudio.SINK_SOUNDS.ballBounce2 },
  { frame = 18, symbol = BattleAudio.SINK_SOUNDS.ballBounce3 },
  { frame = 20, symbol = BattleAudio.SINK_SOUNDS.ballBounce4 },
}

-- BallThrow_BallAnimThrow for the player's ball (battle_anim_ball.c, kinds
-- 15-17): the ball starts off screen at (-30, 160) and arcs 64 pixels high
-- to the foe's sBattleAnimScreenPositions entry plus 8 pixels in 16 frames.
-- The motion starts on the third frame (modeFrames init, then spin init) and
-- the arc state finishes on the 20th.
local BALL_THROW_START_X, BALL_THROW_START_Y = -30, 160
local BALL_THROW_ARC_HEIGHT, BALL_THROW_MOTION_TICKS = 64, 16
local BALL_THROW_LEAD_TICKS, BALL_THROW_TICKS = 2, 20
-- CaptureStateDeflect: from the throw's end to (60, 180) in 10 frames and a
-- 12 pixel arc, starting on the third frame after the state change, and
-- ending with the ball's removal on the 15th.
local BALL_DEFLECT_TARGET_X, BALL_DEFLECT_TARGET_Y = 60, 180
local BALL_DEFLECT_ARC_HEIGHT, BALL_DEFLECT_MOTION_TICKS = 12, 10
local BALL_DEFLECT_LEAD_TICKS, BALL_DEFLECT_TICKS = 3, 15
-- gBattleAnimBattlerScreenPositions plus 8: foe slot -> ball target.
local BALL_THROW_FOE_TARGETS = {
  single = { x = 192, y = 56 },
  first = { x = 216, y = 58 },
  second = { x = 176, y = 50 },
}

-- BattleAnimUtil_UpdateLinearSinMotion after n updates: fixed-point linear
-- motion plus the amplitude * cos(0x3FFF + n * step) lift of the sin motion.
---@param cue table<string, unknown> ball flight cue
---@param n integer motion updates applied
---@return integer x
---@return integer y
local function ballArcPoint(cue, n)
  local ticks = cue.motionTicks --[[@as integer]]
  local startX, startY =
    cue.startX, --[[@as integer]]
    cue.startY --[[@as integer]]
  if n <= 0 then
    return startX, startY
  end
  local function linear(start, target)
    local quotient = (target - start) * 4096 / ticks
    local step = quotient < 0 and math.ceil(quotient) or math.floor(quotient)
    return math.floor((start * 4096 + step * n) / 4096)
  end
  local angle = (0x3FFF + n * math.floor(0x8000 / ticks)) % 0x10000
  local cos = math.floor(math.cos(2 * math.pi * math.floor(angle / 16) / 4096) * 4096)
  local lift = math.floor(cos * cue.arcHeight --[[@as integer]] / 4096)
  return linear(startX, cue.targetX --[[@as integer]]), linear(startY, cue.targetY --[[@as integer]]) + lift
end

-- Where the thrown ball lands on the foe: the single-battle target, or in a
-- doubles battle the target's claimed foe slot (kinds 16 and 17).
---@param self BattleTimeline
---@param event table<string, unknown> throw event under translation
---@return { x: integer, y: integer } ball target
local function ballThrowTarget(self, event)
  local foePositions, playerPositions = {}, {}
  local seen = {}
  for _, id in ipairs(self._order) do
    local shown = self._battlers[id]
    if shown ~= nil and type(shown.position) == "number" then
      local key = tostring(shown.side) .. ":" .. tostring(shown.position)
      if not seen[key] then
        seen[key] = true
        local list = shown.side == 1 and playerPositions or foePositions
        list[#list + 1] = shown.position --[[@as integer]]
      end
    end
  end
  if #foePositions < 2 and #playerPositions < 2 then
    return BALL_THROW_FOE_TARGETS.single
  end
  table.sort(foePositions)
  local target = captureTargetOf(self, event)
  local shown = target ~= nil and self._battlers[target] or nil
  assert(shown ~= nil and type(shown.position) == "number", "doubles ball throws target a placed foe")
  return foePositions[1] == shown.position and BALL_THROW_FOE_TARGETS.first or BALL_THROW_FOE_TARGETS.second
end

---@param self BattleTimeline
---@param event table<string, unknown> capture throw event under translation
local function translateThrow(self, event)
  local payload = event.payload --[[@as table<string, unknown>]]
  assert(type(payload.ball) == "string", "capture throws name their ball")
  local ballKey = payload.ball --[[@as string]]
  local ball = itemName(self, ballKey)
  -- subscript_0011_ThrowBall: msg_0197_00857 names the throwing trainer and
  -- finishes before StartCatchMonTask launches the ball with SEQ_SE_DP_THROW.
  local who = assert(self._playerName, "capture narration carries the player trainer name")
  enqueueMessage(self, messageText(self, "battle/narration/throw-ball", { who, ball }), false, 0)
  enqueue(self, { kind = "sound", cue = effectCue(BattleAudio.SINK_SOUNDS.throw), duration = 0 })
  if payload.blocked == true then
    -- STATE_GET_POKEMON_CHECK_IF_TRAINER: once the throw arc ends a trainer's
    -- Pokemon deflects the ball with SEQ_SE_DP_KON, the ball bounces away,
    -- then msg_0197_00859 and 00860 print.
    local target = ballThrowTarget(self, event)
    local throw = {
      kind = "ball-flight",
      selector = "ball:" .. ballKey,
      startX = BALL_THROW_START_X,
      startY = BALL_THROW_START_Y,
      targetX = target.x,
      targetY = target.y,
      arcHeight = BALL_THROW_ARC_HEIGHT,
      motionTicks = BALL_THROW_MOTION_TICKS,
      leadTicks = BALL_THROW_LEAD_TICKS,
      duration = BALL_THROW_TICKS,
      hideAtEnd = false,
      requiresImage = "battle-ball:" .. ballKey .. ":0",
    }
    enqueue(self, throw)
    enqueue(self, { kind = "sound", cue = ballCue(BattleAudio.SINK_SOUNDS.ballBounce1), duration = 0 })
    local landedX, landedY = ballArcPoint(throw, BALL_THROW_MOTION_TICKS)
    enqueue(self, {
      kind = "ball-flight",
      selector = throw.selector,
      startX = landedX,
      startY = landedY,
      targetX = BALL_DEFLECT_TARGET_X,
      targetY = BALL_DEFLECT_TARGET_Y,
      arcHeight = BALL_DEFLECT_ARC_HEIGHT,
      motionTicks = BALL_DEFLECT_MOTION_TICKS,
      leadTicks = BALL_DEFLECT_LEAD_TICKS,
      duration = BALL_DEFLECT_TICKS,
      hideAtEnd = true,
    })
    enqueueMessage(self, messageText(self, "battle/narration/ball-blocked", {}), false)
    enqueueMessage(self, messageText(self, "battle/narration/no-stealing", {}), false)
    return
  end
  -- Task_GetPokemon draws the target into the ball before any shake.
  local target = captureTargetOf(self, event)
  if target ~= nil then
    self._inBall = target
    -- BtlCmd_ThrowPokeball opens the ball with SEQ_SE_DP_BOWA4 at the
    -- throw's end.
    enqueue(self, { kind = "sound", cue = ballCue(BattleAudio.SINK_SOUNDS.captureOpen), duration = 0 })
    -- STATE_GET_POKEMON_CALCULATE_SHAKES counts 23 frames before the
    -- target enters the ball.
    enqueue(self, { kind = "wait", duration = 23 })
    enqueue(self, {
      kind = "withdraw",
      combatant = target,
      duration = BattleTimeline.VANISH_TICKS,
      requiresImage = self:_imageKeyFor(target),
    })
    -- sBallThrowBounceSounds: frames 1, 8, 14, 18 and 20 of the ground bounce.
    local previous = 0
    for _, bounce in ipairs(BALL_BOUNCE_SOUNDS) do
      if bounce.frame > previous then
        enqueue(self, { kind = "wait", duration = bounce.frame - previous })
      end
      previous = bounce.frame
      enqueue(self, { kind = "sound", cue = ballCue(bounce.symbol), duration = 0 })
    end
  end
end

---@param self BattleTimeline
---@param event table<string, unknown> capture shake event under translation
local function translateShake(self, event)
  local _ = event
  -- The source shakes the ball with its sound only; no line prints.
  -- BallThrow_CaptureStateShakeWait holds 14 frames, the wobble sounds
  -- BOWA on its fifth frame and ends on its twelfth, and
  -- STATE_GET_POKEMON_BALL_SHAKE_DECREMENT then waits 12 frames.
  enqueue(self, { kind = "wait", duration = 20 })
  enqueue(self, {
    kind = "sound",
    cue = ballCue(BattleAudio.SINK_SOUNDS.shake),
    duration = 0,
  })
  enqueue(self, { kind = "wait", duration = 19 })
end

---@param self BattleTimeline
---@return string visible name of the single wild foe under capture narration
local function captureFoeName(self)
  -- Captures only run in single wild encounters, so the one visible
  -- foe is structural, never a display-order guess among several.
  local view = assert(self._latest, "capture narration has a current battle view")
  local foes = view.foes --[[@as table<integer, table<string, unknown>>]]
  local foeValue = foes[1]
  assert(type(foeValue) == "table", "capture narration names its single foe")
  local foe = foeValue --[[@as table<string, unknown>]]
  local name = foe.name
  assert(type(name) == "string", "capture narration uses the visible foe name")
  return name
end

---@param self BattleTimeline
---@param event table<string, unknown> native capture success event under translation
local function translateCaught(self, event)
  -- msg_0197_00867 opens with {WAIT 3}: the capture fanfare starts as
  -- the Gotcha line begins printing.
  enqueue(self, {
    kind = "sound",
    cue = fanfareCue(BattleAudio.SINK_SOUNDS.caught, true),
    duration = 0,
  })
  local caughtName = captureFoeName(self)
  enqueueMessage(self, messageText(self, "battle/narration/gotcha", { caughtName }), false)
  -- The target already entered the ball at the throw; a capture that
  -- never threw still hides it here.
  local target = captureTargetOf(self, event)
  local inBall = target ~= nil and self._inBall == target
  self._inBall = nil
  if target ~= nil and not inBall then
    enqueue(self, {
      kind = "withdraw",
      combatant = target,
      duration = BattleTimeline.VANISH_TICKS,
      requiresImage = self:_imageKeyFor(target --[[@as integer]]),
    })
  end
  enqueue(self, { kind = "wait", duration = BattleTimeline.MESSAGE_HOLD_TICKS })
end

---@param self BattleTimeline
---@param event table<string, unknown> native capture event under translation
local function translateBrokeFree(self, event)
  local sourceText = assert(event.sourceText, "capture outcomes require selected native source text")
  assert(type(sourceText) == "string", "capture outcome source text is a string")
  -- BREAK_OUT sends the target back out before its line prints.
  local target = captureTargetOf(self, event)
  if target ~= nil and self._inBall == target then
    enqueueReveal(self, target)
  end
  self._inBall = nil
  enqueueMessage(self, sourceText, false)
  enqueue(self, { kind = "wait", duration = BattleTimeline.HIT_TICKS })
end

---@param self BattleTimeline
---@param event table<string, unknown> generic scripted-kernel strike under translation
local function translateStrike(self, event)
  local payload = event.payload --[[@as table<string, unknown>]]
  local target = explicitTarget(event)
  if target == nil and type(payload.resolved) == "number" then
    target = payload.resolved --[[@as integer]]
  end
  if target ~= nil then
    enqueueCheckpointHealth(self, target --[[@as integer]], event)
  end
end

-- Every remaining kernel event kind the native session actually emits
-- receives its intentional treatment here. Accounting-only events stay
-- silent; everything else narrates, moves health, or changes visibility.
-- Kinds outside this table are genuinely unknown and keep the explicit
-- diagnostic instead of vanishing.
---@type table<string, fun(self: BattleTimeline, event: table<string, unknown>)>
local OTHER_TRANSLATORS = {
  flee = translateFlee,
  missed = translateMissed,
  ["move-used"] = translateMoveUsed,
  status = translateStatus,
  cured = translateCured,
  stage = translateStage,
  healed = translateHealed,
  tick = translateTick,
  recoil = translateRecoil,
  drained = translateDrained,
  fainted = translateFainted,
  leveled = translateLeveled,
  item = translateItem,
  learn = translateLearn,
  declined = translateDeclined,
  charged = translateCharged,
  delayed = translateDelayed,
  protected = translateProtected,
  ["multi-hit"] = translateMultiHit,
  avoided = translateAvoided,
  immune = translateImmune,
  transformed = translateTransformed,
  sketched = translateSketched,
  mimicked = translateMimicked,
  switch = translateSwitch,
  ["status-gate"] = translateStatusGate,
  ["item-intent"] = translateIntent,
  ["switch-intent"] = translateIntent,
  ["substitute-broke"] = translateSubstituteBroke,
  acknowledge = translateSilent,
  join = translateJoin,
  throw = translateThrow,
  shake = translateShake,
  caught = translateCaught,
  broke_free = translateBrokeFree,
  strike = translateStrike,
}

---@param self BattleTimeline
---@param event table<string, unknown> sanitized kernel event under translation
---@param packet table<string, unknown> delivery carrying launch identity and event-time views
local function translateOther(self, event, packet)
  local kind = event.kind --[[@as string]]
  if kind == "move-used" then
    -- A successful no-strike execution admits its visual behind its own
    -- use announcement. A striking action owns the same occurrence
    -- through its strike, so whichever event claims it first wins and
    -- the other stays silent: one action still plays one visual.
    local nativeKey = nativeEffectKeyOf(event)
    local occurrence = (nativeKey ~= nil or event.actionId ~= nil)
        and occurrenceIdentityOf(launchOf(packet), event, packet)
      or nil
    if occurrence == nil or self._announced[occurrence] ~= true then
      translateMoveUsed(self, event)
      if occurrence ~= nil then
        self._announced[occurrence] = true
      end
    end
    if nativeKey ~= nil then
      enqueueNativeEffect(self, event, packet)
    end
    return
  end
  if kind == "transformed" then
    translateTransformed(self, event, packet)
    return
  end
  -- Any effect-keyed source event narrates before its selected native
  -- program, except misses: HGSS subscript_0007 announces and waits but
  -- does not start a move animation. Other source-attributed kinds keep
  -- their selected programs instead of collapsing onto a generic hit.
  local translate = OTHER_TRANSLATORS[kind]
  if translate == nil then
    self._diagnostics[#self._diagnostics + 1] = "unrepresentable effect: " .. kind
    if nativeEffectKeyOf(event) ~= nil then
      enqueueNativeEffect(self, event, packet)
    end
    return
  end
  translate(self, event, packet)
  if kind ~= "missed" and nativeEffectKeyOf(event) ~= nil then
    enqueueNativeEffect(self, event, packet)
  end
end

-- Accepts one delivery packet in order: unseen identities translate
-- their events into cues behind the retained final facts; a repeated
-- identity is rejected without touching state. A completion naming an
-- entry token without actor identity is stale and never unblocks.
---@param packet table<string, unknown> detached delivery packet
---@param sourceMessages table<integer, string>? selected source text by event sequence
---@return boolean accepted
function BattleTimeline:present(packet, sourceMessages)
  assert(type(packet) == "table", "the cue player consumes delivery packets")
  local id = packet.packetId --[[@as integer]]
  assert(type(id) == "number" and id % 1 == 0 and id >= 1, "delivery packets carry a monotonic identity")
  if id <= self._lastPacketId then
    return false
  end
  local launch = type(packet.launchId) == "string" and packet.launchId or ""
  local events = {} ---@type table<integer, table<string, unknown>>
  if type(packet.events) == "table" then
    for _, event in
      ipairs(packet.events --[[@as table<integer, unknown>]])
    do
      if type(event) == "table" then
        if event.kind == "broke_free" then
          assert(
            type(event.sequence) == "number" and event.sequence % 1 == 0 and event.sequence >= 0,
            "capture outcomes carry an event sequence"
          )
        end
        local sourceText = sourceMessages ~= nil and sourceMessages[event.sequence] or nil
        if event.kind == "broke_free" then
          assert(type(sourceText) == "string", "capture outcomes require selected native source text")
        end
        if type(sourceText) == "string" then
          local detached = copyValue(event) --[[@as table<string, unknown>]]
          detached.sourceText = sourceText
          events[#events + 1] = detached
        else
          events[#events + 1] = event --[[@as table<string, unknown>]]
        end
      end
    end
  end
  for _, event in ipairs(events) do
    if event.kind == "acknowledge" then
      local payload = event.payload --[[@as table<string, unknown>?]]
      if type(payload) == "table" and type(payload.activation) == "number" and explicitActor(event) == nil then
        return false
      end
    end
  end
  -- Exactly-once across deliveries: an event already played under its
  -- launch identity never queues again, and a delivery carrying
  -- nothing new changes nothing. Emissions without a sequence predate
  -- identities and always play.
  local fresh = {} ---@type table<integer, table<string, unknown>>
  for _, event in ipairs(events) do
    local key = nil
    if type(event.sequence) == "number" and type(event.kind) == "string" then
      key = launch .. "\0" .. tostring(event.sequence) .. "\0" .. event.kind
    end
    if
      key == nil or self._seen[
        key --[[@as string]]
      ] ~= true
    then
      fresh[#fresh + 1] = event
    end
  end
  if #events > 0 and #fresh == 0 then
    return false
  end
  self._lastPacketId = id
  for _, event in ipairs(fresh) do
    if type(event.sequence) == "number" and type(event.kind) == "string" then
      self._seen[launch .. "\0" .. tostring(event.sequence) .. "\0" .. event.kind] = true
    end
  end
  indexFacts(self, packet.before)
  if type(packet.after) == "table" then
    self._latest = packet.after
  end
  indexFacts(self, packet.after)
  -- The use event of a no-strike execution closes its action: within
  -- each action group it translates first, so its announcement and
  -- visual lead the action's cue block and stage or status siblings
  -- of the same action never play ahead of the visual they belong to.
  -- Grouping never crosses actions and never rewrites kernel event
  -- identities; only cue scheduling changes.
  local groups = {} ---@type table<integer, table<integer, table<string, unknown>>>
  local groupIndex = {} ---@type table<string, integer>
  for _, event in ipairs(fresh) do
    local action = event.actionId
    if type(action) ~= "number" and type(action) ~= "string" then
      action = event.sequence
    end
    local groupKey = launch .. "\0" .. tostring(action)
    local slot = groupIndex[groupKey]
    if slot == nil then
      groups[#groups + 1] = {}
      slot = #groups
      groupIndex[groupKey] = slot
    end
    groups[slot][#groups[slot] + 1] = event
  end
  fresh = {}
  for _, group in ipairs(groups) do
    for _, event in ipairs(group) do
      if event.kind == "move-used" then
        fresh[#fresh + 1] = event
      end
    end
    for _, event in ipairs(group) do
      if event.kind == "item" then
        fresh[#fresh + 1] = event
      end
    end
    for _, event in ipairs(group) do
      if event.kind ~= "move-used" and event.kind ~= "item" then
        fresh[#fresh + 1] = event
      end
    end
  end
  -- One attack occurrence narrates once per delivery: the set lives
  -- only for this packet so later packets narrate their own attacks.
  local narrated = {} ---@type table<string, boolean>
  for _, event in ipairs(fresh) do
    if type(event.kind) == "string" then
      local kind = event.kind --[[@as string]]
      if kind == "struck" then
        translateStruck(self, event, packet, narrated)
      elseif kind == "faint" then
        translateFaint(self, event)
      elseif kind == "exp" then
        translateExp(self, event, packet)
      elseif kind == "stats" then
        translateStats(self, event)
      else
        translateOther(self, event, packet)
      end
    end
  end
  -- Headless opening and terminal sequencing behind the same packet
  -- boundary: the screen already queued its introduction through its
  -- explicit entry, so a delivery that arrives after that entry never
  -- replays it here. Direct timeline drivers without the screen entry
  -- still receive the ordered native flow exactly once by identity.
  if type(packet.result) == "table" and self._flowIntroDone ~= true then
    queueResult(self, packet)
  elseif BattlePresentationFlow.isOpeningPacket(packet) and self._flowIntroDone ~= true then
    local opening = packet.after
    if type(opening) ~= "table" then
      opening = packet.before
    end
    if type(opening) == "table" then
      queueOpening(self, opening --[[@as table<string, unknown>]])
    end
  end
  return true
end

-- Queues the source opening: trainer slides run alongside the encounter
-- lead-in, battlers stay hidden until their send-out cues, and the staged
-- ball image holds the cue until its exact asset is ready.
---@param view table<string, unknown> detached opening dynamic view
---@param wild boolean true for a wild encounter, false for a trainer challenge
function BattleTimeline:intro(view, wild)
  assert(type(view) == "table", "the opening needs its view")
  indexFacts(self, view)
  self._latest = view
  local foeName = nil
  local foeSpecies = nil
  local foeForm = nil
  local foeRecord = nil
  local openingFoes = view.foes
  if type(openingFoes) == "table" then
    foeRecord = openingFoes[1]
  end
  if type(foeRecord) == "table" then
    local foe = foeRecord --[[@as table<string, unknown>]]
    if type(foe.name) == "string" then
      foeName = foe.name --[[@as string]]
    end
    if type(foe.species) == "string" then
      foeSpecies = foe.species --[[@as string]]
    end
    if type(foe.form) == "number" then
      foeForm = foe.form --[[@as integer]]
    end
  end
  assert(type(foeName) == "string", "opening foe view carries its display name")
  foeName = foeName --[[@as string]]
  -- The send-out names the actual active lead, never the first party
  -- slot: a benched fainted slot stays silent while the live lead
  -- walks out. Records that predate the active flag read as active,
  -- matching the previous first-slot opening; an opening with no
  -- active lead at all is impossible and fails loudly instead of
  -- hailing a guessed battler.
  local lead = nil
  if type(view.own) == "table" then
    for _, record in ipairs(view.own) do
      if type(record) == "table" and record.active ~= false then
        lead = record --[[@as table<string, unknown>]]
        break
      end
    end
  end
  assert(lead ~= nil, "the opening needs its active lead")
  local own = lead --[[@as table<string, unknown>]]
  -- subscript_0000_StartEncounter: the foe cries as its encounter slide
  -- settles, before the encounter line; the lead cries on its send-out
  -- after "Go!".
  self._foeHpMark = foeHealthAt(self, nil)
  local trainerSlides, trainerTracks = openingTrainerSlides(self, view, wild)
  local terrainSlides, terrainTracks = openingTerrainSlides()
  self._openingPresentation = {
    playerTrainerVisible = true,
    foeTrainerVisible = not wild,
    playerGaugeVisible = false,
    enemyGaugeVisible = false,
    trainerSlides = trainerSlides,
    terrainSlides = terrainSlides,
  }
  self._trainerSlideTracks = trainerTracks
  self._terrainSlideTracks = terrainTracks
  self._wildIntroTrack = nil
  for _, battler in ipairs(self:battlers()) do
    local shown = self:_shown(battler.combatant --[[@as integer]])
    if shown ~= nil then
      shown.visible = false
      shown.hudVisible = false
    end
  end
  if not wild then
    enqueue(self, { kind = "trainer-intro-wait" })
  end
  if wild then
    local wildFoe = assert(foeRecord, "wild openings carry one foe") --[[@as table<string, unknown>]]
    if type(wildFoe.combatant) == "number" then
      local foeCombatant = wildFoe.combatant --[[@as integer]]
      local shownFoe = self:_shown(foeCombatant)
      if shownFoe ~= nil then
        shownFoe.visible = true
        shownFoe.pictureXOffset = -272
        shownFoe.paletteFade = { applied = true, targetColor = 0, intensity = 8 }
        self._wildIntroTrack = {
          combatant = foeCombatant,
          delay = 28,
          elapsed = 0,
          x = -80,
          targetX = 192,
          speed = 8,
          arrived = false,
          fadeElapsed = 0,
        }
      end
    end
    enqueue(self, { kind = "wait", duration = 61 })
    if type(foeSpecies) == "string" then
      enqueue(self, { kind = "sound", cue = cryCue(foeSpecies, foeForm, true), duration = 0 })
    end
    enqueueEncounterMessage(self, true, foeName)
  else
    enqueue(self, { kind = "wait", duration = 96 })
    enqueueOpeningPresentation(self, { playerGaugeVisible = true, enemyGaugeVisible = true })
    enqueueEncounterMessage(self, false, foeName)
    enqueueOpeningPresentation(self, { enemyGaugeVisible = false })
    local trainerValue = firstTrainer(self)
    assert(type(trainerValue) == "table", "trainer send-out carries its class and name")
    local foesValue = view.foes
    assert(type(foesValue) == "table", "trainer opening carries its lead foe")
    local foes = foesValue --[[@as table<integer, table<string, unknown>>]]
    local sentOutFoe = false
    for _, foe in ipairs(foes) do
      if foe.active ~= false then
        enqueueSendOut(self, foe.combatant --[[@as integer]], nil)
        enqueue(self, { kind = "wait", duration = 112 })
        sentOutFoe = true
      end
    end
    assert(sentOutFoe, "trainer openings send out an active foe")
  end
  if wild then
    enqueue(self, { kind = "wait", duration = 96 })
  else
    enqueueOpeningPresentation(self, { playerGaugeVisible = false })
  end
  enqueueSendOut(self, own.combatant --[[@as integer]], nil)
  if type(view.own) == "table" then
    for _, partner in ipairs(view.own) do
      if partner.active ~= false and partner.combatant ~= own.combatant then
        enqueueSendOut(self, partner.combatant --[[@as integer]], nil)
      end
    end
  end
  enqueue(self, { kind = "wait", duration = 96 })
  enqueueOpeningPresentation(self, {
    playerTrainerVisible = false,
    foeTrainerVisible = false,
    playerGaugeVisible = wild,
    enemyGaugeVisible = false,
  })
  self._flowIntroDone = true
end

---@param cue table<string, unknown>
---@param isAvailable (fun(key: string): boolean)? image availability probe
---@return boolean true when the cue may tick under the available images
local function cueReady(cue, isAvailable)
  local key = cue.requiresImage
  if type(key) == "string" and isAvailable ~= nil and not isAvailable(key) then
    return false
  end
  return true
end

---@param self BattleTimeline
local function tickTrainerSlides(self)
  local presentation = self._openingPresentation
  if presentation == nil then
    return
  end
  local slides = presentation.trainerSlides --[[@as table<integer, table<string, unknown>>]]
  local flashElapsed = presentation.trainerFlashElapsed
  if type(flashElapsed) == "number" then
    flashElapsed = flashElapsed + 1
    if flashElapsed > 8 then
      presentation.trainerFlashElapsed = nil
      presentation.trainerFlashCoefficient = nil
    else
      presentation.trainerFlashElapsed = flashElapsed
      presentation.trainerFlashCoefficient = flashElapsed <= 4 and 16 - flashElapsed * 4 or (flashElapsed - 4) * 4
    end
  end
  for index, track in ipairs(self._trainerSlideTracks) do
    local slide = assert(slides[index], "trainer slide tracks stay aligned with their public states")
    if slide.visible == true then
      if track.animationActive == true then
        local frame = track.frames[track.frame + 1]
        assert(type(frame) == "table", "trainer animation frame indices resolve to staged source frames")
        local sequenceChanged = false
        if track.encounterWaiting == true and track.attributeFrame ~= track.frame then
          local userAttr = frame.userAttr --[[@as integer]]
          track.attributeFrame = track.frame
          if userAttr == 1 then
            presentation.trainerFlashElapsed = 0
            presentation.trainerFlashCoefficient = 16
          elseif userAttr == 0xFFF then
            track.encounterWaiting = false
            track.encounterComplete = true
          elseif userAttr >= 0x100 and userAttr < 0x200 then
            local animation = userAttr % 0x100
            if animation ~= 0 then
              selectTrainerSequence(self, slide, track, animation - 1)
              sequenceChanged = true
              track.encounterWaiting = false
              track.encounterComplete = true
            end
          end
        end
        if not sequenceChanged then
          track.frameElapsed = track.frameElapsed + 1
          local frameDuration = frame.durationTicks --[[@as integer]]
          if frameDuration == 0 or track.frameElapsed >= frameDuration then
            track.frameElapsed = 0
            local animation = track.animation --[[@as table<string, unknown>]]
            local playMode = animation.playMode --[[@as string]]
            local skippedZeroFrames = 0
            repeat
              local loopStart = assert(animation.loopStartFrameIdx, "trainer sequences declare their loop start")
              local nextFrame = track.frame + track.frameDirection
              local completed = false
              if track.frameDirection > 0 and nextFrame >= #track.frames then
                if playMode == "forward_loop" then
                  nextFrame = loopStart
                elseif playMode == "forward" then
                  nextFrame = #track.frames - 1
                  completed = true
                elseif playMode == "reverse" or playMode == "reverse_loop" then
                  track.frameDirection = -1
                  nextFrame = #track.frames - 1
                else
                  error("unsupported source trainer play mode " .. tostring(playMode), 0)
                end
              elseif track.frameDirection < 0 and nextFrame < loopStart then
                if playMode == "reverse_loop" then
                  track.frameDirection = 1
                  nextFrame = loopStart
                elseif playMode == "reverse" then
                  nextFrame = math.max(0, loopStart - 1)
                  completed = true
                else
                  error("unsupported source trainer play mode " .. tostring(playMode), 0)
                end
              end
              if nextFrame == track.frame then
                if completed then
                  track.animationActive = false
                  track.encounterWaiting = false
                  track.encounterComplete = true
                elseif frameDuration == 0 then
                  skippedZeroFrames = skippedZeroFrames + 1
                  assert(
                    skippedZeroFrames < #track.frames,
                    "source trainer animations cannot cycle only zero-duration frames"
                  )
                else
                  break
                end
              end
              track.frame = nextFrame
              if completed then
                track.animationActive = false
                track.encounterWaiting = false
                track.encounterComplete = true
              end
              track.attributeFrame = nil
              local nextFrameRecord = assert(track.frames[nextFrame + 1], "next trainer frame is staged")
              if
                nextFrameRecord.durationTicks --[[@as integer]]
                > 0
              then
                break
              end
              skippedZeroFrames = skippedZeroFrames + 1
              assert(
                skippedZeroFrames < #track.frames,
                "source trainer animations cannot cycle only zero-duration frames"
              )
            until false
            slide.frame = track.frame
          end
        end
      end
      if slide.phase == "exit-slide" then
        local x = assert(type(slide.x) == "number" and slide.x, "trainer exits carry a source x position")
        local nextX = x + track.exitDirection * 5
        if
          (track.exitDirection < 0 and nextX <= track.exitTargetX)
          or (track.exitDirection > 0 and nextX >= track.exitTargetX)
        then
          slide.x = track.exitTargetX
          slide.visible = false
          slide.phase = "intro-settle"
          local stillVisible = false
          for _, other in ipairs(slides) do
            stillVisible = stillVisible or (other.role == slide.role and other.visible == true)
          end
          if not stillVisible then
            presentation[slide.role == "player" and "playerTrainerVisible" or "foeTrainerVisible"] = false
          end
        else
          slide.x = nextX
        end
      elseif slide.phase ~= "intro-settle" then
        if track.elapsed < track.delay then
          track.elapsed = track.elapsed + 1
        else
          local x = assert(type(slide.x) == "number" and slide.x, "trainer slides carry a source x position")
          local nextX = x + track.direction * track.speed
          if (track.direction < 0 and nextX <= track.targetX) or (track.direction > 0 and nextX >= track.targetX) then
            nextX = track.targetX
            slide.phase = "intro-settle"
            if slide.role == "foe" and track.sourceSequenceCount > 1 then
              selectTrainerSequence(self, slide, track, 1)
              track.encounterWaiting = true
              track.encounterComplete = false
            else
              track.encounterWaiting = false
              track.encounterComplete = true
            end
          else
            slide.phase = "intro-slide"
          end
          slide.x = nextX
          track.elapsed = track.elapsed + 1
          if track.throwPending == true then
            track.throwPending = false
            track.exitDirection = -1
            track.exitTargetX = -40
            slide.phase = "exit-slide"
            selectTrainerSequence(self, slide, track, 1)
          end
        end
      end
    end
  end
end

---@param self BattleTimeline
local function tickTerrainSlides(self)
  local presentation = self._openingPresentation
  if presentation == nil then
    return
  end
  local slides = presentation.terrainSlides --[[@as table<integer, table<string, unknown>>]]
  for index, track in ipairs(self._terrainSlideTracks) do
    local slide = assert(slides[index], "terrain slide tracks stay aligned with their published positions")
    if slide.visible == true and slide.phase ~= "intro-settle" then
      if track.elapsed < track.delay then
        track.elapsed = track.elapsed + 1
      else
        local x = assert(type(slide.x) == "number" and slide.x, "terrain slides carry source x positions")
        local nextX = x + track.direction * track.speed
        if (track.direction < 0 and nextX <= track.targetX) or (track.direction > 0 and nextX >= track.targetX) then
          nextX = track.targetX
          slide.phase = "intro-settle"
        else
          slide.phase = "intro-slide"
        end
        slide.x = nextX
        track.elapsed = track.elapsed + 1
      end
    end
  end
end

---@param self BattleTimeline
local function tickWildIntro(self)
  local track = self._wildIntroTrack
  if track == nil then
    return
  end
  local shown = self:_shown(track.combatant)
  assert(shown ~= nil, "the wild intro track keeps its foe installed")
  if not track.arrived then
    if track.elapsed < track.delay then
      track.elapsed = track.elapsed + 1
      return
    end
    track.x = math.min(track.x + track.speed, track.targetX)
    shown.pictureXOffset = track.x - track.targetX
    if track.x == track.targetX then
      track.arrived = true
      track.fadeElapsed = 0
    end
    return
  end
  if track.fadeElapsed < 8 then
    track.fadeElapsed = track.fadeElapsed + 1
    shown.paletteFade = {
      applied = true,
      targetColor = 0,
      intensity = 8 - track.fadeElapsed,
    }
    if track.fadeElapsed == 8 then
      shown.hudVisible = true
      local presentation = assert(self._openingPresentation, "the wild intro keeps its opening terrain")
      local slides = presentation.terrainSlides --[[@as table<integer, table<string, unknown>>]]
      for _, slide in ipairs(slides) do
        slide.visible = false
      end
    end
  end
end

---@param self BattleTimeline
---@param cue table<string, unknown> native-effect cue under advancement
---@return boolean finished true only after the player occurrence actually completed
local function pollNativeEffect(self, cue)
  if cue.collaboratorMissing == true then
    return false
  end
  local handle = cue.handle
  if handle == nil then
    -- The collaborator refused admission: the owning screen already
    -- latched its failure with provenance, so this cue holds instead
    -- of settling silently or replaying generic voices.
    return false
  end
  local poller = type(self._effects) == "table" and self._effects.status or nil
  if type(poller) ~= "function" then
    return false
  end
  local ok, phase = pcall(poller, handle)
  if not ok then
    if cue.pollNoted ~= true then
      cue.pollNoted = true
      self._diagnostics[#self._diagnostics + 1] = "native effect "
        .. tostring(cue.effectKey)
        .. " for launch "
        .. tostring(cue.launchId)
        .. " status query failed: "
        .. tostring(phase)
    end
    return false
  end
  if phase == "complete" then
    -- Only this consumption point releases the occurrence, after the
    -- player advanced it to completion: the collaborator drops its
    -- track and terminal record before the cue leaves the queue, so a
    -- later poll never aliases a reused identity. Collaborators without
    -- a release hook predate it and keep the legacy completion.
    local retirer = type(self._effects) == "table" and self._effects.retire or nil
    if type(retirer) == "function" then
      local okRetire, retired = pcall(retirer, handle)
      if not okRetire then
        if cue.retireNoted ~= true then
          cue.retireNoted = true
          self._diagnostics[#self._diagnostics + 1] = "native effect "
            .. tostring(cue.effectKey)
            .. " for launch "
            .. tostring(cue.launchId)
            .. " retirement failed: "
            .. tostring(retired)
        end
        return false
      end
      if retired ~= true then
        if cue.retireNoted ~= true then
          cue.retireNoted = true
          self._diagnostics[#self._diagnostics + 1] = "native effect "
            .. tostring(cue.effectKey)
            .. " for launch "
            .. tostring(cue.launchId)
            .. " refuses retirement; the cue holds"
        end
        return false
      end
    end
    return true
  end
  if phase == "failed" and cue.failureNoted ~= true then
    cue.failureNoted = true
    self._diagnostics[#self._diagnostics + 1] = "native effect "
      .. tostring(cue.effectKey)
      .. " for launch "
      .. tostring(cue.launchId)
      .. " failed; the owning screen reports with provenance"
  end
  return false
end

---@param self BattleTimeline
---@param cue table<string, unknown> cue consuming its first tick
local function startCue(self, cue)
  cue.started = true
  if cue.kind == "opening-presentation" then
    local changes = cue.changes --[[@as table<string, boolean>]]
    local state = assert(self._openingPresentation, "opening stages follow an installed opening")
    for key, value in pairs(changes) do
      assert(type(state[key]) == "boolean", "opening stages update known visibility fields")
      state[key] = value
      if key == "playerTrainerVisible" or key == "foeTrainerVisible" then
        local role = key == "playerTrainerVisible" and "player" or "foe"
        local slides = state.trainerSlides --[[@as table<integer, table<string, unknown>>]]
        for _, slide in ipairs(slides) do
          if slide.role == role then
            slide.visible = value
          end
        end
      end
    end
  elseif cue.kind == "ball-throw" then
    local state = assert(self._openingPresentation, "opening ball throws follow an installed opening")
    local trainerTracks = self._trainerSlideTracks
    local slides = state.trainerSlides --[[@as table<integer, table<string, unknown>>]]
    for index, slide in ipairs(slides) do
      local track = assert(trainerTracks[index], "trainer slides retain their source animation tracks")
      if slide.selector == cue.trainerSelector then
        if slide.phase == "intro-settle" and slide.x == track.targetX then
          track.exitDirection = -1
          track.exitTargetX = -40
          slide.phase = "exit-slide"
          selectTrainerSequence(self, slide, track, 1)
        else
          track.throwPending = true
        end
      end
    end
    state.ballThrow = {
      selector = cue.selector,
      x = 0,
      y = 0,
      frame = 0,
      rotation = 0,
      trainerSelector = cue.trainerSelector,
      throwOffsets = cue.throwOffsets,
      visible = false,
    }
  elseif cue.kind == "trainer-exit" then
    local state = assert(self._openingPresentation, "trainer exits follow an installed opening")
    for index, slide in
      ipairs(state.trainerSlides --[[@as table<integer, table<string, unknown>>]])
    do
      local track = assert(self._trainerSlideTracks[index], "trainer slides retain their source animation tracks")
      if slide.role == cue.role and track.participant == cue.participant then
        track.exitDirection = 1
        track.exitTargetX = 296
        slide.phase = "exit-slide"
      end
    end
  elseif cue.kind == "ball-flight" then
    local state = self._openingPresentation
    if state ~= nil then
      state.ballThrow = {
        selector = cue.selector,
        x = cue.startX,
        y = cue.startY,
        frame = 0,
        rotation = 0,
        visible = true,
      }
    end
  elseif cue.kind == "sound" then
    emitSound(self, cue.cue --[[@as table<string, unknown>]])
  elseif cue.kind == "exp" then
    emitSound(self, effectCue(BattleAudio.SINK_SOUNDS.experience, { voiceKey = cue.soundKey }))
  elseif cue.kind == "faint" then
    local shown = self:_shown(cue.combatant --[[@as integer]])
    if shown ~= nil then
      shown.fainting = true
      local appearance = self._faintAppearance and self._faintAppearance(shown) or nil
      cue.sourceHeight = appearance and appearance.height or shown.height
      cue.elevation = appearance and math.max(0, appearance.shadowHeight) or 0
      if appearance ~= nil then
        shown.shadowHeight = cue.elevation
      end
      shown.pictureVisible = cue.elevation == 0
      shown.pictureWidth = 80
      shown.pictureXOffset2 = 0
      shown.pictureYOffset2 = 0
      shown.pictureHeight = math.max(0, 80 - (type(cue.sourceHeight) == "number" and cue.sourceHeight or 0))
      shown.pictureYOffset = 0
      shown.hudVisible = true
      shown.hudOffsetX = 0
    end
  elseif cue.kind == "message" then
    cue.revealedCount = 0
    cue.delayCounter = 0
    self._message = cue.pages[1] or ""
    self._messageId = cue.id --[[@as integer]]
  elseif cue.kind == "hp" and cue.from == nil then
    local shown = self:_shown(cue.combatant --[[@as integer]])
    cue.from = (shown ~= nil and type(shown.hp) == "number") and shown.hp or cue.to
    if cue.flicker == true and shown ~= nil then
      shown.visible = not shown.visible
      cue.flickerToggles = 1
    end
  elseif cue.kind == "reveal" then
    self:_installReveal(cue.combatant --[[@as integer]])
    if cue.holdHud == true then
      local arriving = self:_shown(cue.combatant --[[@as integer]])
      if arriving ~= nil then
        arriving.hudVisible = false
      end
    end
  elseif cue.kind == "hud-slide" then
    -- HealthbarSlideIn starts the box off-screen on its own edge.
    local sliding = self:_shown(cue.combatant --[[@as integer]])
    if sliding ~= nil then
      sliding.hudVisible = true
      sliding.hudOffsetX = cue.direction == "in" and (sliding.side == 1 and 160 or -160) or 0
    end
  elseif cue.kind == "native-effect" then
    -- Admission already demanded the effect; the first visit only
    -- retries the demand when admission never ran it.
    beginNativeEffect(self, cue)
  end
end

---@param id integer incoming combatant identity under reveal
function BattleTimeline:_installReveal(id)
  -- A new activation clears its transient pose and starts hidden; the
  -- reveal cue shows it at completion from the newest known facts.
  local record = nil
  if self._latest ~= nil then
    for _, group in ipairs({ self._latest.own, self._latest.foes }) do
      if type(group) == "table" then
        for _, entry in ipairs(group) do
          if type(entry) == "table" and entry.combatant == id then
            record = entry
          end
        end
      end
    end
  end
  if record ~= nil then
    local displayed = displayedOf(record --[[@as table<string, unknown>]])
    local current = self._battlers[id]
    if current ~= nil and type(current.hp) == "number" then
      displayed.hp = current.hp
    end
    self._battlers[id] = displayed
    self._battlers[id].visible = false
    checkSlotClaims(self)
    local seen = false
    for _, known in ipairs(self._order) do
      if known == id then
        seen = true
      end
    end
    if not seen then
      self._order[#self._order + 1] = id
    end
  elseif self._battlers[id] ~= nil then
    self._battlers[id].visible = false
  end
end

---@param self BattleTimeline
---@param cue table<string, unknown> narration cue under reveal
---@return boolean finished
local function tickMessage(self, cue)
  local pages = cue.pages --[[@as string[] ]]
  local page = pages[
    cue.page --[[@as integer]] or 1
  ] or ""
  -- The reveal counts glyphs so a multibyte name never shows a torn
  -- codepoint mid-reveal.
  local glyphs = {}
  for char in Utf8Glyphs.iter(page) do
    glyphs[#glyphs + 1] = char
  end
  cue.glyphTotal = #glyphs
  local full = #glyphs
  local policy = self._revealPolicy
  if type(cue.revealedCount) ~= "number" then
    cue.revealedCount = 0
  end
  if type(cue.delayCounter) ~= "number" then
    cue.delayCounter = 0
  end
  local shown = cue.revealedCount --[[@as integer]]
  if shown < full then
    -- NitroMain runs the print-task queue twice per battle source tick.
    -- Keep those printer updates inside the tick so reveal speed matches
    -- retail while waits and animation cues remain on the source cadence.
    local updates = 0
    local printed = 0
    while updates < 2 and shown < full do
      updates = updates + 1
      if
        cue.delayCounter --[[@as integer]]
        > 0
      then
        cue.delayCounter = cue.delayCounter --[[@as integer]] - 1
      elseif printed < policy.glyphBudget then
        local glyphCount = math.min(policy.glyphBudget - printed, full - shown)
        local target = shown + glyphCount
        cue.revealedCount = target
        cue.delayCounter = policy.interGlyphDelay
        shown = target
        printed = printed + glyphCount
        self._message = table.concat(glyphs, "", 1, target)
        self._messageId = cue.id --[[@as integer]]
      end
    end
    if shown < full then
      self._message = table.concat(glyphs, "", 1, shown)
      self._messageId = cue.id --[[@as integer]]
      return false
    end
  else
    self._message = page
    self._messageId = cue.id --[[@as integer]]
  end
  if
    cue.page --[[@as integer]]
    < #pages
  then
    -- An acknowledged page turns only on its explicit edge; ordinary
    -- narration still turns on its hold so pacing never waits.
    if cue.ackable == true then
      return false
    end
    cue.hold = (cue.hold or 0) + 1
    if cue.hold >= BattleTimeline.MESSAGE_HOLD_TICKS then
      cue.page = cue.page --[[@as integer]] + 1
      cue.hold = 0
      cue.revealedCount = 0
      cue.delayCounter = 0
    end
    return false
  end
  if cue.ackable == true then
    -- A fully revealed terminal page holds until its explicit final
    -- acknowledgment; glyph completion alone never releases it.
    return cue.acknowledged == true
  end
  cue.hold = (cue.hold or 0) + 1
  local need = cue.holdTicks --[[@as integer?]]
  if type(need) ~= "number" then
    need = BattleTimeline.MESSAGE_HOLD_TICKS
  end
  return cue.hold >= need
end

---@param self BattleTimeline
---@param cue table<string, unknown> narration cue with concurrent health-box exit
---@return boolean finished
local function tickHealthBoxExit(self, cue)
  local id = cue.slideCombatant
  if type(id) ~= "number" or cue.slideDone == true then
    return true
  end
  local shown = self:_shown(id --[[@as integer]])
  if shown == nil then
    return true
  end
  local offset = (
    shown.hudOffsetX --[[@as integer?]]
    or 0
  ) + (shown.side == 1 and 24 or -24)
  shown.hudOffsetX = shown.side == 1 and math.min(160, offset) or math.max(-24, offset)
  if (shown.side ~= 1 or shown.hudOffsetX == 160) and cue.slideStarted == true then
    shown.hudVisible = false
    cue.slideDone = true
    return true
  end
  cue.slideStarted = true
  return false
end

-- Task_RecallPokemon / Task_PokemonSendOut picture poof for one tick: the
-- recall fades the picture to the ball color (0 -> 16, one step per tick)
-- then shrinks it by 32/256 per tick; the send-out grows the picture from
-- zero while the fade holds 16, then fades back (16 -> 0).
-- Pokepic_SetYOffsetForAffineHeight keeps the picture on its row while it
-- scales; the send-out measures it by the shadow height, the recall by the
-- picture height.
---@param self BattleTimeline
---@param cue table<string, unknown> withdraw or reveal cue carrying its fade color
---@param shown table<string, unknown> displayed battler under the poof
---@param entering boolean true for the send-out, false for the recall
function tickBallPoof(self, cue, shown, entering)
  local elapsed = cue.elapsed --[[@as integer]]
  local fadeTicks = BattleTimeline.BALL_FADE_TICKS
  local scaleTicks = BattleTimeline.BALL_SCALE_TICKS
  local intensity, affine
  if entering then
    -- Affine 0 on the first tick, full size once the eight steps are added.
    affine = math.min(0x100, 0x20 * (elapsed - 1))
    intensity = elapsed <= scaleTicks + 1 and 16 or math.max(0, 16 - (elapsed - scaleTicks - 1))
    shown.visible = true
  else
    intensity = math.min(16, elapsed - 1)
    affine = elapsed <= fadeTicks and 0x100 or math.max(0, 0x100 - 0x20 * (elapsed - fadeTicks))
  end
  if
    elapsed >= cue.duration --[[@as integer]]
  then
    shown.paletteFade = nil
    shown.affineMode = nil
    shown.affineWidth = nil
    shown.affineHeight = nil
    shown.pictureYOffset = nil
    return
  end
  shown.paletteFade = { applied = true, targetColor = cue.fadeColor, intensity = intensity }
  if affine < 0x100 then
    if cue.rowHeight == nil then
      local appearance = self._faintAppearance and self._faintAppearance(shown) or nil
      local height = appearance and (entering and appearance.shadowHeight or appearance.height) or 0
      cue.rowHeight = 40 - height
    end
    local lift = cue.rowHeight --[[@as number]]
    shown.affineMode = true
    shown.affineWidth = affine
    shown.affineHeight = affine
    shown.pictureYOffset = lift - math.floor(lift * affine / 0x100)
  else
    shown.affineMode = nil
    shown.affineWidth = nil
    shown.affineHeight = nil
    shown.pictureYOffset = nil
  end
end

---@param self BattleTimeline
---@param cue table<string, unknown> active cue under advancement
---@param soundComplete (fun(cue: table<string, unknown>): boolean)? held sound cue completion probe
---@return boolean finished
local function tickCue(self, cue, soundComplete)
  if cue.kind == "native-effect" then
    -- Only the player occurrence's real completion releases the cue;
    -- every other phase holds without consuming invented timers.
    return pollNativeEffect(self, cue)
  elseif cue.kind == "message" then
    local slideDone = tickHealthBoxExit(self, cue)
    local previousHold = cue.hold
    local messageDone = tickMessage(self, cue)
    if not slideDone then
      cue.hold = previousHold
    end
    return slideDone and messageDone
  elseif cue.kind == "sound" then
    local sound = cue.cue --[[@as table<string, unknown>?]]
    if type(sound) == "table" and sound.waitForVoice == true and soundComplete ~= nil then
      return soundComplete(sound) == true
    end
    return true
  elseif cue.kind == "stats-window" then
    return cue.acknowledged == true
  elseif cue.kind == "opening-presentation" then
    return true
  elseif cue.kind == "trainer-intro-wait" then
    for _, track in ipairs(self._trainerSlideTracks) do
      if track.encounterComplete ~= true then
        return false
      end
    end
    return true
  elseif cue.kind == "trainer-exit" then
    local found = false
    local finished = true
    for index, slide in ipairs(self._openingPresentation and self._openingPresentation.trainerSlides or {}) do
      local track = assert(self._trainerSlideTracks[index], "trainer exits retain their source slide tracks")
      if slide.role == cue.role and track.participant == cue.participant then
        found = true
        finished = finished and slide.visible ~= true
        local x = assert(type(slide.x) == "number" and slide.x, "foe trainer exits carry their native x")
        if x >= 160 then
          local ball = self._openingPresentation.ballThrow
          if ball == nil or ball.trainerParticipant ~= cue.participant then
            ball = {
              selector = cue.selector,
              x = cue.ballX,
              y = cue.ballY,
              frame = 0,
              rotation = 0,
              trainerParticipant = cue.participant,
              visible = true,
            }
            self._openingPresentation.ballThrow = ball
            cue.ballElapsed = 0
          else
            cue.ballElapsed = (cue.ballElapsed or 0) + 1
          end
          if cue.ballElapsed >= 12 then
            ball.visible = false
          end
        end
      end
    end
    assert(found, "trainer exit resolves to its source participant slide")
    return finished
  elseif cue.kind == "ball-throw" then
    local ball =
      assert(self._openingPresentation and self._openingPresentation.ballThrow, "active throws publish a ball sprite")
    local offsets = ball.throwOffsets --[[@as table<integer, table<string, integer>>]]
    local slide, track
    for index, candidate in ipairs(self._openingPresentation.trainerSlides) do
      if candidate.selector == ball.trainerSelector then
        slide = candidate
        track = self._trainerSlideTracks[index]
        break
      end
    end
    assert(slide ~= nil and track ~= nil, "trainer throws retain their backpic slide")
    if track.throwPending == true then
      return false
    end
    if slide.visible ~= true then
      ball.visible = false
      return true
    end
    local pose = assert(track.frames[track.frame + 1], "trainer pose resolves its staged source frame")
    local frame = pose.sourceFrame --[[@as integer]]
    local offset = assert(
      offsets[frame + 1],
      "trainer source frame "
        .. tostring(frame)
        .. " at sequence position "
        .. tostring(track.frame)
        .. " resolves its throw anchor"
    )
    if offset.x ~= 32767 then
      ball.x = slide.x + offset.x
      ball.y = slide.y + offset.y
      ball.visible = true
    end
    return false
  elseif cue.kind == "ball-flight" then
    local elapsed = cue.elapsed --[[@as integer]]
    local duration = cue.duration --[[@as integer]]
    local motionTicks = cue.motionTicks --[[@as integer]]
    local lead = cue.leadTicks --[[@as integer]]
    local n = math.min(motionTicks, math.max(0, elapsed - lead))
    local ball = self._openingPresentation and self._openingPresentation.ballThrow or nil
    if ball ~= nil then
      ball.x, ball.y = ballArcPoint(cue, n)
      -- Each update spins the ball 45 degrees; the frame after the last
      -- update resets the rotation.
      ball.rotation = elapsed <= lead + motionTicks and (n * 0x2000) % 0x10000 or 0
      if elapsed >= duration and cue.hideAtEnd == true then
        ball.visible = false
      end
    end
    return elapsed >= duration
  elseif cue.kind == "wait" then
    local elapsed = cue.elapsed --[[@as integer]]
    local duration = cue.duration --[[@as integer]]
    return elapsed >= duration
  elseif cue.kind == "hp" then
    local shown = self:_shown(cue.combatant --[[@as integer]])
    local from = cue.from --[[@as integer]]
    local to = cue.to --[[@as integer]]
    local duration = cue.duration --[[@as integer]]
    local progress = math.min(1, cue.elapsed --[[@as integer]] / math.max(1, duration))
    local value = from + math.floor((to - from) * progress + 0.5)
    if
      cue.elapsed --[[@as integer]]
      >= duration
    then
      value = to
    end
    if shown ~= nil then
      shown.hp = value
      if cue.flicker == true then
        local toggles = cue.flickerToggles --[[@as integer]]
        if
          toggles < 6
          and cue.elapsed --[[@as integer]]
            == toggles * 3 + 1
        then
          shown.visible = not shown.visible
          cue.flickerToggles = toggles + 1
        elseif
          cue.elapsed --[[@as integer]]
          >= 17
        then
          shown.visible = true
        end
      end
    end
    return cue.elapsed --[[@as integer]] >= math.max(duration, cue.flicker == true and 17 or 0)
  elseif cue.kind == "hit" then
    return cue.elapsed --[[@as integer]] >= BattleTimeline.HIT_TICKS
  elseif cue.kind == "faint" then
    local shown = self:_shown(cue.combatant --[[@as integer]])
    if shown == nil then
      return true
    end
    if
      cue.elevation --[[@as integer]]
      > 0
    then
      cue.elevation = math.max(0, cue.elevation --[[@as integer]] - 8)
      shown.shadowHeight = cue.elevation
      if cue.elevation > 0 then
        return false
      end
      shown.pictureVisible = true
      cue.sinkElapsed = 0
      return false
    end
    cue.sinkElapsed = (cue.sinkElapsed or 0) + 1
    local initialPictureHeight = math.max(0, 80 - (type(cue.sourceHeight) == "number" and cue.sourceHeight or 0))
    local pictureHeight = math.max(0, initialPictureHeight - cue.sinkElapsed * 8)
    shown.pictureHeight = pictureHeight
    shown.pictureYOffset = cue.sinkElapsed * 8
    if pictureHeight == 0 then
      shown.visible = false
      shown.pictureVisible = false
      return true
    end
    return false
  elseif cue.kind == "hud-slide" then
    -- BattleHpBar_StartSlide/Task_BattleHpBarSlide: 24 px per frame; the
    -- player boxes travel 160 px to the right edge, the foe boxes 24 px left.
    local sliding = self:_shown(cue.combatant --[[@as integer]])
    if sliding == nil then
      return true
    end
    local player = sliding.side == 1
    local offset = (
      sliding.hudOffsetX --[[@as integer?]]
      or 0
    )
    if cue.direction == "in" then
      offset = player and math.max(0, offset - 24) or math.min(0, offset + 24)
      sliding.hudOffsetX = offset
      return offset == 0
    end
    offset = player and math.min(160, offset + 24) or math.max(-24, offset - 24)
    sliding.hudOffsetX = offset
    if offset == (player and 160 or -24) then
      sliding.hudVisible = false
      return true
    end
    return false
  elseif cue.kind == "withdraw" then
    local shown = self:_shown(cue.combatant --[[@as integer]])
    if shown ~= nil and cue.fadeColor ~= nil then
      tickBallPoof(self, cue, shown, false)
    end
    if
      cue.elapsed --[[@as integer]]
      >= cue.duration --[[@as integer]]
    then
      if shown ~= nil then
        shown.visible = false
        if cue.keepHud == true then
          shown.hudVisible = true
        end
      end
      return true
    end
    return false
  elseif cue.kind == "reveal" then
    local shown = self:_shown(cue.combatant --[[@as integer]])
    if shown ~= nil and cue.fadeColor ~= nil then
      tickBallPoof(self, cue, shown, true)
    end
    if
      cue.elapsed --[[@as integer]]
      >= cue.duration --[[@as integer]]
    then
      if shown ~= nil then
        shown.visible = true
      end
      return true
    end
    return false
  elseif cue.kind == "exp" then
    local shown = self:_shown(cue.combatant --[[@as integer]])
    local duration = cue.duration --[[@as integer]]
    local progress = math.min(1, cue.elapsed --[[@as integer]] / math.max(1, duration --[[@as integer]]))
    local startExp = cue.startExp --[[@as integer]]
    local targetExp = cue.targetExp --[[@as integer]]
    local targetLevel = cue.targetLevel --[[@as integer]]
    if type(startExp) ~= "number" or type(targetExp) ~= "number" then
      return cue.elapsed --[[@as integer]] >= duration
    end
    local value = startExp + (targetExp - startExp) * progress
    if progress >= 1 then
      value = targetExp
    end
    if shown ~= nil then
      shown.exp = math.floor(value + 0.5)
      if progress >= 1 and type(targetLevel) == "number" then
        shown.level = targetLevel
      end
    end
    if
      cue.elapsed --[[@as integer]]
      >= cue.soundStopTicks --[[@as integer]]
    then
      emitSound(self, { kind = "stop-effect", voiceKey = cue.soundKey })
      if cue.levelUp ~= nil then
        emitSound(self, effectCue(BattleAudio.SINK_SOUNDS.experienceMax))
      end
      return true
    end
    return false
  end
  return true
end

-- Advances the player by accepted presentation seconds. Only whole
-- source ticks run cues, one cue at a time; a cue needing an
-- unavailable image holds the clock without advancing.
---@param dt number accepted presentation seconds
---@param isAvailable (fun(key: string): boolean)? image availability probe, all available when absent
---@param soundComplete (fun(cue: table<string, unknown>): boolean)? completion probe for held sound cues
function BattleTimeline:update(dt, isAvailable, soundComplete)
  assert(type(dt) == "number" and dt == dt and dt >= 0, "the cue player advances on accepted seconds")
  self._accum = self._accum + dt
  local step = SourceTick.DT
  while self._accum + SOURCE_TICK_EPSILON >= step do
    if self._active == nil then
      local next = self._queue[1]
      if next == nil then
        self._accum = 0
        break
      end
      if not cueReady(next, isAvailable) then
        self._accum = 0
        break
      end
      tickTrainerSlides(self)
      table.remove(self._queue, 1)
      self._active = next
      startCue(self, next)
      local nextSound = next.kind == "sound" and next.cue or nil
      if type(nextSound) == "table" and nextSound.waitForVoice == true and soundComplete ~= nil then
        self._accum = self._accum - step
        tickTerrainSlides(self)
        tickWildIntro(self)
        if math.abs(self._accum) < SOURCE_TICK_EPSILON then
          self._accum = 0
        end
        next.elapsed = 1
        break
      elseif next.kind == "sound" or next.kind == "opening-presentation" then
        self._active = nil
      else
        self._accum = self._accum - step
        tickTerrainSlides(self)
        tickWildIntro(self)
        if math.abs(self._accum) < SOURCE_TICK_EPSILON then
          self._accum = 0
        end
        next.elapsed = (next.elapsed or 0) + 1
        if tickCue(self, next) then
          self._active = nil
        end
      end
    else
      local current = assert(self._active, "advancement consumes its active cue")
      if not cueReady(current, isAvailable) then
        self._accum = 0
        break
      end
      tickTrainerSlides(self)
      local currentSound = current.kind == "sound" and current.cue or nil
      if type(currentSound) == "table" and currentSound.waitForVoice == true then
        if soundComplete ~= nil and soundComplete(currentSound) ~= true then
          self._accum = 0
          break
        end
        self._accum = self._accum - step
        tickTerrainSlides(self)
        tickWildIntro(self)
        if math.abs(self._accum) < SOURCE_TICK_EPSILON then
          self._accum = 0
        end
        self._active = nil
      else
        self._accum = self._accum - step
        tickTerrainSlides(self)
        tickWildIntro(self)
        if math.abs(self._accum) < SOURCE_TICK_EPSILON then
          self._accum = 0
        end
        local elapsed = current.elapsed
        assert(type(elapsed) == "number", "active cues carry their elapsed ticks")
        current.elapsed = elapsed + 1
        if tickCue(self, current, soundComplete) then
          self._active = nil
        end
      end
    end
  end
end

-- Completes the revealed page (or advances to the next one) for an
-- acknowledgement edge. The edge is always consumed while narration is
-- active so it never leaks into command input. An edge that finishes a
-- running reveal never acknowledges in the same edge; only an edge on a
-- fully revealed final ackable page reports its completion.
---@return boolean consumed
---@return boolean completedFinalPage true exactly on the explicit final-page acknowledgment
function BattleTimeline:ack()
  local current = self._active
  if current == nil then
    -- An edge arriving before the clock starts its narration still
    -- belongs to that page when the page is already queued first.
    local head = self._queue[1]
    if head ~= nil and head.kind == "stats-window" then
      table.remove(self._queue, 1)
      self._active = head
      current = head
    elseif head == nil or head.kind ~= "message" then
      return false, false
    else
      table.remove(self._queue, 1)
      self._active = head
      startCue(self, head)
      current = head
    end
  end
  if current.kind == "stats-window" then
    current.acknowledged = true
    local finalPage = current.page == "total"
    self._active = nil
    return true, finalPage
  end
  if current.kind ~= "message" then
    return false, false
  end
  local pages = current.pages --[[@as string[] ]]
  local page = pages[
    current.page --[[@as integer]] or 1
  ] or ""
  local total = current.glyphTotal
  if type(total) ~= "number" then
    total = 0
    for _ in Utf8Glyphs.iter(page) do
      total = total + 1
    end
  end
  if (current.revealedCount or 0) < total then
    current.revealedCount = total
    current.delayCounter = 0
    self._message = page
    return true, false
  end
  if
    current.page --[[@as integer]]
    < #pages
  then
    current.page = current.page --[[@as integer]] + 1
    current.hold = 0
    current.revealedCount = 0
    current.delayCounter = 0
    return true, false
  end
  if current.ackable == true then
    -- The same edge never both accelerates and acknowledges: arrival
    -- here means the final page was already fully revealed, so this
    -- edge is the explicit acknowledgment. A repeated edge on an
    -- already acknowledged page consumes without completing again.
    if current.acknowledged == true then
      return true, false
    end
    current.acknowledged = true
    return true, true
  end
  -- Explicit source waits usually ignore dialogue input, but a native
  -- WaitButtonABTime-style hold ends early on acknowledgement.
  if current.ackSkipsHold == true and (current.slideCombatant == nil or current.slideDone == true) then
    current.hold = current.holdTicks --[[@as integer]]
  elseif current.holdTicks == nil then
    -- Ordinary narration keeps its existing fast-forward behavior.
    current.hold = BattleTimeline.MESSAGE_HOLD_TICKS
  end
  return true, false
end

---@return boolean true when no cue is waiting or consuming ticks
function BattleTimeline:settled()
  return self._active == nil and #self._queue == 0
end

---@return boolean true while a cue is waiting or consuming ticks
function BattleTimeline:busy()
  return self._active ~= nil or #self._queue > 0
end

---@return table<integer, table<string, unknown>> displayed battler facts, player side first
function BattleTimeline:battlers()
  local out = {}
  for _, id in ipairs(self._order) do
    local shown = self._battlers[id]
    if shown ~= nil then
      out[#out + 1] = copyValue(shown)
    end
  end
  return out
end

---@return table<string, unknown>? detached visibility facts for the current intro stage
function BattleTimeline:openingPresentation()
  return self._openingPresentation ~= nil and copyValue(self._openingPresentation) or nil
end

---@return string currently displayed narration page, possibly empty
function BattleTimeline:message()
  return self._message
end

---@return integer stable identity of the displayed narration
function BattleTimeline:messageId()
  return self._messageId
end

---@return boolean true while an event narration cue owns the message line
function BattleTimeline:messageActive()
  return self._active ~= nil and self._active.kind == "message"
end

---@return table<string, unknown>? detached active level-up page
function BattleTimeline:levelUpStats()
  local current = self._active
  if current == nil or current.kind ~= "stats-window" then
    return nil
  end
  return { level = current.level, page = current.page, rows = copyValue(current.rows) }
end

---@param id integer combatant identity under recoil
---@return integer horizontal logical-pixel displacement for the current tick
function BattleTimeline:shake(id)
  local current = self._active
  if current == nil or current.kind ~= "hit" or current.combatant ~= id then
    return 0
  end
  local step = (current.elapsed or 1) % BattleTimeline.HIT_TICKS
  local pattern = { 0, 1, 2, 1, 0, 0 }
  local offset = pattern[step + 1] or 0
  if offset > BattleTimeline.HIT_DISPLACEMENT then
    offset = BattleTimeline.HIT_DISPLACEMENT
  end
  return offset
end

---@return string[] recorded unknown-effect occurrences
function BattleTimeline:diagnostics()
  return copyValue(self._diagnostics) --[[@as string[] ]]
end

-- Queues one product-owned narration page outside event translation:
-- the opening encounter, send-out, and terminal result texts.
---@param text string narration wording under presentation
---@param ackable boolean true when the page waits for acknowledgement instead of holding
---@param holdTicks integer? explicit post-text hold in internal ticks, defaulting to the narration hold
---@return integer stable narration identity
function BattleTimeline:announce(text, ackable, holdTicks)
  assert(type(text) == "string" and text ~= "", "announced narration carries its wording")
  if holdTicks ~= nil then
    assert(
      type(holdTicks) == "number" and holdTicks % 1 == 0 and holdTicks >= 0,
      "announced holds stay finite nonnegative integers"
    )
  end
  self._messageSeq = self._messageSeq + 1
  local id = self._messageSeq
  enqueue(self, {
    kind = "message",
    text = text,
    id = id,
    pages = paginate(text),
    page = 1,
    revealed = 0,
    hold = 0,
    holdTicks = holdTicks,
    ackable = ackable == true,
  })
  return id
end

-- Drains the queued one-shot sound cues in order. Playback
-- availability never gates a cue; the screen routes each cue to its
-- audio boundary and drops the results.
---@return table<integer, table<string, unknown>> typed sound cues in cue-start order
function BattleTimeline:drainSounds()
  local sounds = self._pendingSounds
  self._pendingSounds = {}
  return sounds
end

---@return integer[] player-first combatant identities known to the player
function BattleTimeline:order()
  return copyValue(self._order) --[[@as integer[] ]]
end

-- Reconciles one final-view battler record: exact numbers always,
-- visibility never. Hidden battlers stay hidden until an explicit
-- reveal; unknown activations install hidden.
---@param record table<string, unknown> detached final-view battler record
---@param known boolean true when the identity already plays
function BattleTimeline:reconcileBattler(record, known)
  local id = record.combatant --[[@as integer]]
  if known and self._battlers[id] ~= nil then
    local shown = self._battlers[id] --[[@as table<string, unknown>]]
    shown.hp = record.hp
    shown.maxHp = record.maxHp
    shown.name = record.name
    shown.level = record.level
    shown.exp = record.experience
    shown.condition = record.condition
    shown.moves = copyValue(record.moves)
    if record.gender == "male" or record.gender == "female" or record.gender == "genderless" then
      shown.gender = record.gender
    else
      shown.gender = nil
    end
    if type(record.caught) == "boolean" then
      shown.caught = record.caught
    else
      shown.caught = nil
    end
    if type(record.height) == "number" then
      shown.height = record.height
    else
      shown.height = nil
    end
    if record.substitute == true then
      shown.substitute = true
    else
      shown.substitute = nil
    end
    -- The displayed image identity tracks the active combatant: a
    -- switch or reveal rebinds the exact canonical selector while
    -- visibility still changes only through explicit cues.
    if type(record.portraitSelector) == "string" and record.portraitSelector ~= "" then
      shown.portraitSelector = record.portraitSelector
    else
      shown.portraitSelector = nil
    end
    -- Slot identity follows only when no withdrawal, reveal or faint
    -- cue for this combatant is still queued or playing: a withdrawn
    -- record keeps its old slot until its withdrawal cue hides it,
    -- and a new occupant takes its slot on its reveal cue. Health and
    -- name reconciliation never moves a slot and never changes
    -- visibility; cue owns that.
    if not slotGated(self, id) and record.active ~= false then
      if type(record.position) == "number" then
        shown.position = record.position
      end
      if type(record.activation) == "number" then
        shown.activation = record.activation
      end
    end
    checkSlotClaims(self)
  elseif not known then
    self._battlers[id] = displayedOf(record)
    self._battlers[id].visible = false
    local seen = false
    for _, knownId in ipairs(self._order) do
      if knownId == id then
        seen = true
      end
    end
    if not seen then
      self._order[#self._order + 1] = id
    end
  end
end

return BattleTimeline
