-- One interactive battle screen over the real battle runtime. Owns
-- command, selection, narration, cue playback and the child slot for a
-- single launch: it forwards accepted choice fragments through the
-- injected submit boundary, plays ordered delivery packets through its
-- cue player, resolves paired complete plans through the shared
-- presentation session, and exposes a detached view with truthful
-- readiness. It never owns battle calculations or persistence; draw
-- calls are read-only and the fixed clock is the only thing that
-- advances presentation. Input after disposal is dropped, never
-- applied.

local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local BattleAnimationPlayer = require("libs.hgss.src.presentation.BattleAnimationPlayer")
local BattleAudio = require("libs.hgss.src.audio.BattleAudio")
local BattleEffectTasks = require("libs.hgss.src.presentation.BattleEffectTasks")
local BattlePresentationAssets = require("game.hgss.src.battle.BattlePresentationAssets")
local MonCache = require("libs.assets.src.MonCache")
local BattlePresentationFlow = require("game.hgss.src.battle.BattlePresentationFlow")
local BattleScene = require("libs.hgss.src.presentation.BattleScene")
local BattleScreenInterface = require("game.hgss.src.battle.BattleScreenInterface")
local BattleChildApplications = require("game.hgss.src.battle.BattleChildApplications")
local BattleSubflows = require("game.hgss.src.battle.BattleSubflows")
local BattleTimeline = require("game.hgss.src.battle.BattleTimeline")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")
local SourceTick = require("libs.hgss.src.field.SourceTick")

---@class BattleScreenState.GraphicsScope
---@field host table<string, unknown> borrowed host graphics namespace
---@field graphics table<string, unknown> forwarder counting push/pop scopes over the host
---@field outstanding integer scopes pushed through the forwarder and not yet popped

---@class BattleScreenState
---@field _launchId string owning launch identity
---@field _manifest table<string, unknown> planning manifest behind the demand
---@field _submit fun(reply: table<string, unknown>): boolean, table<string, unknown>? accepted-choice boundary
---@field _measureDisplay fun(): table<string, unknown> live display facts
---@field _text table<string, unknown> borrowed text services
---@field _windows table<string, unknown> borrowed window services
---@field _audio table<string, unknown> semantic sound boundary
---@field _battleAudio BattleAudio launch-scoped voice operations over the sound boundary
---@field _legacyAudio boolean true while the sink voices string roles without a cry port
---@field _monCatalog table<string, unknown>? borrowed immutable mon catalog behind cry identities, move names, and experience spans
---@field _monIconProvider table<string, unknown>? borrowed field icon page provider behind the command icon
---@field _battleMenus table<string, unknown>? borrowed native battle menu renderers and manifests
---@field _assets BattlePresentationAssets per-launch preparation leases
---@field _timeline BattleTimeline ordered visible-cue player
---@field _player table<string, unknown> battle-private native animation interpreter over the live scene
---@field _nativeHandles table<table<string, unknown>, table<string, unknown>> native occurrence tracks by player handle or pending token
---@field _nativeVoices table<string, table<string, unknown>> staged player voices by name behind launch-owned stops
---@field _waitingCueVoice table<string, unknown>? cry handle blocking the next timeline cue
---@field _nativeRouting boolean true while the effects collaborator routes native cues
---@field _liveEffectHandle table<string, unknown>? player handle behind the running occurrence
---@field _liveEffectRecord table<string, unknown>? loaded effect record behind the running occurrence
---@field _session ApplicationPresentation per-open presentation session
---@field _subflows BattleSubflows battle-local child coordinator
---@field _partySnapshot table<integer, table<string, unknown>>? latest detached own-party facts
---@field _inventorySnapshot table<string, integer>? latest detached battle stock
---@field _mode string closed controller mode
---@field _selection string? highlighted semantic identity
---@field _commandX integer source main-menu cursor column behind keypad focus
---@field _commandY integer source main-menu cursor row behind keypad focus
---@field _savedCommandCursor table<integer, { x: integer, y: integer }> per-combatant main-menu cursor memory
---@field _savedMoveCursor table<integer, { x: integer, y: integer }> per-combatant fight-menu cursor memory
---@field _savedTargetCursor table<integer, { id: string, range: string }> per-combatant target cursor memory
---@field _keyboardFocus boolean true while the last battle-menu input came from keys
---@field _armed table<string, unknown>? pressed control awaiting release
---@field _buttonFeedback table<string, unknown>? native release feedback task owning a pending activation
---@field _child table<string, unknown>? open child intent
---@field _request table<string, unknown>? mirrored open request
---@field _options table<string, unknown>? latest decision options for the open request
---@field _actorIndex integer one-based cursor into the mirrored request actors
---@field _staged table<integer, table<string, unknown>> staged choice fragments by request position
---@field _lastStaged integer? request position behind the latest staged fragment
---@field _targetCandidates table<integer, table<string, unknown>>? projected target variants behind the pending move
---@field _lastTargetSelection string? previous native target slot beneath cancel
---@field _targetGroup table<string, unknown>? native selected move target grouping
---@field _targetRangeKey string? move range identity behind the open target choice
---@field _pendingMoveId string? move control identity behind the pending target choice
---@field _pendingFinal table<string, unknown>? retained final view behind playing cues
---@field _pendingRequest table<string, unknown>? retained request behind playing cues
---@field _pendingResult table<string, unknown>? retained terminal result behind playing cues
---@field _outcomeMessages table<integer, table<string, unknown>>? source-selected terminal messages and waits
---@field _pendingRegistration table<string, unknown>? detached frozen first-catch facts behind the card
---@field _registrationChild table<string, unknown>? open battle-owned registration presentation
---@field _graphicsScope BattleScreenState.GraphicsScope? persistent scope-counting forwarder over the host graphics
---@field _registrationComplete boolean true once the card completes its terminal return
---@field _pokedex table<string, unknown>? borrowed field presentation resource owner behind the card
---@field _registrationAudio table<string, unknown>? borrowed registration audio adapter behind the card
---@field _onResultMusic fun(word: string): boolean? bound terminal-music beat behind the outcome narration
---@field _resultMusicSent boolean true once the bound terminal-music beat fired for this screen
---@field _completion table<string, unknown>? open capture-nickname completion behind its bound identity
---@field _completionChild table<string, unknown>? composed native naming child behind the open completion
---@field _completionResult table<string, unknown>? sealed one-shot completion answer behind consumption
---@field _consumedCompletions table<string, boolean> consumed completion identities behind late-result refusal
---@field _terminalRequest table<string, unknown>? mirrored terminal request identity behind the completion barrier
---@field _introBuilt boolean opening cues queued
---@field _kind string battle kind wording for the opening narration
---@field _queue table<integer, table<string, unknown>> queued raw input batches
---@field _notice string? transient refusal banner
---@field _showTimelineMessage boolean whether a source-selected event message temporarily replaces the command prompt
---@field _signature string? measurement signature behind the published plan
---@field _cursorTick integer keypad corner animation clock in presentation ticks
---@field _cursorWasVisible boolean whether the previous published cursor was visible
---@field _cursorSelection string? selection owning the current corner animation
---@field _activeEffectTick integer active player bob clock in presentation ticks
---@field _activeEffectRunning boolean whether the player selection bob is active
---@field _sourceAccum number accepted seconds banked toward the next source tick
---@field _menuRevealStep integer source menu reveal frame, 0 through 4
---@field _menuGateTicks integer source ticks until menu input opens
---@field _messageScrollY integer source BG1 message-window scroll from -51 to 0
---@field _menuPulseBlend integer source palette blend coefficient from 0 through 16
---@field _menuPulseDirection 0|1 source palette pulse direction
---@field _iconAnimationTick integer mon icon animation clock in source ticks
---@field _scene table<string, unknown> native visual-state owner for entry travel and scroll
---@field _gaugeVisuals table<string, { sideType: integer, kind: string }> active native HUD gauge task destinations
---@field _sceneHasBackground boolean true after staged BG3 state installs
---@field _outcomeDone boolean terminal narration and timed holds have settled
---@field _lastPlayerName string? source player trainer name retained from detached views
---@field _error string? failure context
---@field _disposed boolean
local BattleScreenState = {}
BattleScreenState.__index = BattleScreenState
local BattleMenuRegions = require("game.hgss.src.battle.BattleMenuRegions")

-- One accepted HGSS source tick shared with the field session.
BattleScreenState.SOURCE_FRAME = SourceTick.DT

-- Native command navigation follows the source 3x2 cursor grid
-- (battle_input.c sCursorArrayMainMenu): the upper row is one wide Fight
-- button and the lower row holds Bag, Run, and Pokemon. Keypad motion
-- clamps at the grid edges; a horizontal edge on the Fight row wraps to
-- the lower-row ends, and pushing up from Run is a native no-op. Grid
-- cells name ordinary slots so special contexts navigate by the slot
-- their command replaces: safari, pal-park, and bug-contest keep the
-- same four-slot touch topology with swapped labels.
local COMMAND_GRID = {
  { "fight", "fight", "fight" },
  { "bag", "run", "pokemon" },
}
local COMMAND_GRID_WIDTH = 3
local COMMAND_GRID_HEIGHT = 2

-- Source cursor cell behind one ordinary command slot: the touch
-- rectangle the native cursor frames, inset by the source cursor.
local COMMAND_SLOT_CELLS = {
  fight = { x = 0, y = 0 },
  bag = { x = 0, y = 1 },
  pokemon = { x = 2, y = 1 },
  run = { x = 1, y = 1 },
}

-- Native target-cursor priority behind the opening cell
-- (battle_input.c BattleInput_CursorMove_TargetMenu): the upper-left
-- foe, the upper-right foe, the lower-left ally, else the lower-right
-- ally. Cells name source buttons, not target-choice ordinals.
local TARGET_PRIORITY = { "target:3", "target:1", "target:0", "target:2" }

-- Source target text slots are positional and do not share target-choice
-- ordinals. Native source slot types map to their visible button IDs.
local TARGET_CONTROL_BY_SIDE_TYPE = {
  [0] = "target:1",
  [2] = "target:3",
  [3] = "target:0",
  [4] = "target:1",
  [5] = "target:2",
}

-- Launch kind behind the staged menu mode: safari, pal-park, and
-- bug-contest swap the native command labels; every other kind keeps
-- the standard label family.
local KIND_MENU_MODE = {
  safari = "safari",
  ["pal-park"] = "pal-park",
  ["bug-contest"] = "bug-contest",
}

-- Launch kind behind the command identity surface. Ordinary kinds keep
-- the four native commands. Safari and pal-park throw balls, bait, and
-- mud instead of fighting with moves; bug-contest fights normally but
-- throws contest balls from the bag slot. The catching tutorial only
-- reaches its scripted fight-then-bag sequence, and frontier
-- facilities disallow fleeing, so neither offers the full ordinary set.
-- Unknown launch kinds keep the ordinary surface they always showed.
local KIND_COMMANDS = {
  safari = { "safari-ball", "safari-bait", "safari-mud", "run" },
  ["pal-park"] = { "pal-park-ball", "safari-bait", "safari-mud", "run" },
  ["bug-contest"] = { "fight", "bug-contest-ball", "pokemon", "run" },
  tutorial = { "fight", "bag" },
  frontier = { "fight", "bag", "pokemon" },
}

local ORDINARY_COMMANDS = { "fight", "bag", "pokemon", "run" }

-- Surface slot behind the staged label key: the label family is keyed
-- by ordinary slot even when the command identity is specialized.
local SURFACE_LABEL_KEYS = { "fight", "bag", "pokemon", "run" }

local MOVE_NAV = {
  ["move:0"] = { up = "move:0", down = "move:2", left = "move:0", right = "move:1" },
  ["move:1"] = { up = "move:1", down = "move:3", left = "move:0", right = "move:1" },
  ["move:2"] = { up = "move:0", down = "cancel", left = "move:2", right = "move:3" },
  ["move:3"] = { up = "move:1", down = "cancel", left = "move:2", right = "move:3" },
  cancel = { up = "move:2", down = "cancel", left = "cancel", right = "cancel" },
}

-- Float slack so an accepted-time sum landing exactly on a source-tick
-- boundary never strands a stale full tick in the source accumulator.
local SOURCE_TICK_EPSILON = 1e-12

-- Collects the staged battle-music and interface role symbols behind the
-- launch demand: every staged wild, trainer, rival, and select symbol the
-- manifest verifies. A planning manifest stages no roles and demands
-- none; the preparation services fail closed on unstaged roles where
-- pixels are actually required.
---@param manifest table<string, unknown> staged or planning presentation manifest
---@param musicRole string? chosen battle-music symbol behind the exact demand closure
---@return string[] staged audio role symbols
local function stagedAudioRoles(manifest, musicRole)
  if type(musicRole) == "string" and musicRole ~= "" then
    -- The exact launch demand stages only its chosen music closure
    -- beside the interface role: unrelated battle tracks never ride.
    local roles = { musicRole }
    if
      type(manifest) == "table"
      and manifest.verified == true
      and type(manifest.audioRoles) == "table"
      and type(manifest.audioRoles.select) == "string"
      and manifest.audioRoles.select ~= musicRole
    then
      roles[#roles + 1] = manifest.audioRoles.select
    end
    for _, symbol in pairs(BattleAudio.SINK_SOUNDS) do
      roles[#roles + 1] = symbol
    end
    table.sort(roles)
    return roles
  end
  local roles = {}
  if type(manifest) == "table" and type(manifest.hud) == "table" and type(manifest.audioRoles) == "table" then
    for _, role in ipairs({ "wild", "trainer", "rival", "select" }) do
      if type(manifest.audioRoles[role]) == "string" then
        roles[#roles + 1] = manifest.audioRoles[role]
      end
    end
    for _, symbol in pairs(BattleAudio.SINK_SOUNDS) do
      roles[#roles + 1] = symbol
    end
  end
  table.sort(roles)
  return roles
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

---@param manifest table<string, unknown> planning manifest with staged message entries
---@param key string semantic message key
---@param substitutions string[] values for source string-variable tokens
---@return string printable source message: glyphs and line breaks only
local function stagedBattleText(manifest, key, substitutions)
  local messages = assert(manifest.messages, "battle narration requires staged message entries")
  local entries = assert(messages.entries, "battle narration requires semantic message entries")
  local record = assert(entries[key], "battle narration message is staged: " .. key)
  local sourceTokens = record.tokens --[[@as table<integer, table<string, unknown>>]]
  local out = {}
  local substitutionIndex = 1
  for _, token in ipairs(sourceTokens) do
    if token.kind == "eos" then
      break
    elseif token.kind == "glyph" then
      out[#out + 1] = token.text
    elseif token.kind == "line_break" then
      out[#out + 1] = "\n"
    elseif token.kind == "substitution" then
      out[#out + 1] = assert(substitutions[substitutionIndex], "source message substitution is supplied: " .. key)
      substitutionIndex = substitutionIndex + 1
    end
    -- Style, pause, printer-callback, continuation, page/prompt-break and
    -- focus tokens have no glyphs: narration paces itself on the timeline and
    -- the command child draws its own Yes/No choices.
  end
  assert(
    substitutionIndex == #substitutions + 1,
    "source message " .. key .. " consumes " .. (substitutionIndex - 1) .. " substitutions, got " .. #substitutions
  )
  return table.concat(out)
end

---@param screen BattleScreenState screen owning the staged message manifest
---@param key string semantic battle message key
---@param substitutions string[] source substitutions in message order
---@return string decoded source battle text
local function resolveBattleText(screen, key, substitutions)
  return stagedBattleText(screen._manifest, key, substitutions)
end

---@class BattleScreenState.Options
---@field launchId string owning launch identity
---@field manifest table<string, unknown> planning manifest behind the demand
---@field model table<string, unknown> detached opening and packet boundary
---@field submit fun(reply: table<string, unknown>): boolean, table<string, unknown>? accepted-choice boundary
---@field onResultMusic fun(word: string): boolean? bound terminal-music beat behind the outcome narration
---@field measureDisplay fun(): table<string, unknown> live display facts
---@field assets BattlePresentationAssets.Services preparation services carrying prepare/drawable/release
---@field text table<string, unknown> borrowed text services
---@field windows table<string, unknown> borrowed window services
---@field audio table<string, unknown> semantic sound boundary
---@field pokedex table<string, unknown>? borrowed field presentation resource owner behind the card
---@field registrationAudio table<string, unknown>? borrowed registration audio adapter behind the card
---@field itemCatalog table<string, unknown>? borrowed immutable item catalog for battle bag grouping
---@field monCatalog table<string, unknown>? borrowed immutable mon catalog for machine display facts
---@field monIconProvider table<string, unknown>? borrowed field icon page provider for presented battle composition
---@field battleMenus table<string, unknown>? borrowed field-owned native menu renderers and manifests
---@field textSpeed string? narration pace for this launch, defaulting to the middle pace
---@field musicRole string? chosen battle-music symbol behind the exact demand closure
---@field musicBanks integer[]? chosen track bank identities behind the demand
---@field overrides table<string, unknown>? per-instance scene/frame/case inputs

-- The battle screen owns one animation player and its per-launch
-- effect services behind the live cue clock. The timeline sequences
-- native-effect cues, the player runs the selected programs on the
-- live scene, and this owner demands and loads exact selected
-- effects, maps accepted packets onto frozen visual-topology playback, polls real
-- completion or failure, and retires every handle exactly once. The
-- player, task factory, and asset holder are injected collaborators,
-- never clones; there is no second scheduler and no gameplay event
-- field.

---@param screen BattleScreenState owning screen behind voice routing
---@param name unknown staged voice identity under playback
---@param extra unknown? voice operands behind playback
---@return string staged voice key under monitoring
local function nativeVoicePlay(screen, name, extra)
  assert(type(name) == "string" and name ~= "", "player voices play by name")
  local handle
  if type(extra) == "table" and extra.kind == "cry" then
    assert(type(extra.combatant) == "number", "animation cries name their attacker")
    local battler = nil
    for _, record in ipairs(screen._timeline:battlers()) do
      if record.combatant == extra.combatant then
        battler = record
        break
      end
    end
    assert(battler ~= nil and type(battler.species) == "string", "animation cries need the attacker's species")
    if screen._legacyAudio then
      screen._nativeVoices[name] = screen._battleAudio:playEffect("cry:" .. battler.species)
      return name
    end
    handle = screen._battleAudio:playCry({
      species = screen:_crySpecies(battler),
      speciesKey = battler.species,
      form = battler.form,
      pattern = extra.pattern,
      pan = extra.pan,
      volume = extra.volume,
    })
  elseif type(extra) == "number" then
    handle = screen._battleAudio:playEffect(name, extra --[[@as integer]])
  else
    -- Sound-task operand records (pan motion, repeats) drive the task
    -- itself; the voice starts unpanned.
    assert(extra == nil or type(extra) == "table", "player voice operands are a pan or a task record")
    handle = screen._battleAudio:playEffect(name)
  end
  screen._nativeVoices[name] = handle
  return name
end

---@param screen BattleScreenState owning screen behind voice routing
---@param name unknown staged voice identity under release
local function nativeVoiceStop(screen, name)
  local handle = screen._nativeVoices[name]
  if handle == nil then
    return
  end
  screen._nativeVoices[name] = nil
  -- Best effort over launch-owned handles only: a sink without a
  -- stop port simply keeps its shared player.
  pcall(function()
    screen._battleAudio:stopVoice(handle)
  end)
end

---@param screen BattleScreenState owning screen behind voice routing
---@param name unknown staged voice identity under query
---@return boolean complete true once the owned voice needs no further wait
local function nativeVoiceFinished(screen, name)
  local handle = screen._nativeVoices[name]
  if handle == nil then
    return true
  end
  -- An unanswerable completion query never fails the occurrence and
  -- never fakes completion: the wait parks until the native voice
  -- escape retires the run, so legacy sinks without query ports still
  -- terminate instead of hanging.
  local ok, done = pcall(function()
    return screen._battleAudio:voiceComplete(handle)
  end)
  if not ok then
    return false
  end
  return done == true
end

---@param screen BattleScreenState owning screen behind voice routing
---@return table<string, unknown> narrow player voice collaborator over the launch battle audio
local function nativeVoiceAdapter(screen)
  ---@param name unknown staged voice identity under playback
  ---@param extra unknown? voice operands behind playback
  ---@return string staged voice key under monitoring
  local function play(name, extra)
    return nativeVoicePlay(screen, name, extra)
  end
  ---@param name unknown staged voice identity under release
  local function stop(name)
    nativeVoiceStop(screen, name)
  end
  ---@param name unknown staged voice identity under query
  ---@return boolean complete true once the owned voice needs no further wait
  local function isFinished(name)
    return nativeVoiceFinished(screen, name)
  end
  return { play = play, stop = stop, isFinished = isFinished }
end

---@param screen BattleScreenState owning screen behind lease routing
---@return table<string, unknown> narrow player resource collaborator behind resolve and release
local function nativeResourceAdapter(screen)
  local adapter = {}
  ---@param key unknown semantic resource key under resolving
  ---@return table<string, unknown>? occurrence lease, nil when the holder refuses
  function adapter.resolve(key)
    assert(type(key) == "string" and key ~= "", "effect leases resolve by key")
    local record = screen._liveEffectRecord
    if record ~= nil and type(record.resources) == "table" and record.resources[key] ~= nil then
      -- Declared dependencies resolve through the effect-asset holder:
      -- textures upload with refcounted ownership and failures latch
      -- loud with launch, effect, and resource provenance.
      local lease = screen._assets:resolveEffectResource(record, key)
      return lease
    end
    -- Staging invariant: only keys declared by the live effect closure
    -- resolve through the holder. Anything else fails closed with launch,
    -- effect, and resource provenance instead of minting a synthetic
    -- journal token: an undeclared key is a broken closure, never a
    -- plumbable dependency. State-only visual task bodies stage no keys;
    -- they borrow player-held dependencies or touch scene state directly.
    local effectKey = type(record) == "table" and record.key or "no-live-effect"
    error(
      "unknown battle effect resource "
        .. key
        .. " for effect "
        .. tostring(effectKey)
        .. " for launch "
        .. tostring(screen._launchId),
      0
    )
  end
  ---@param lease unknown occurrence lease under release
  ---@return boolean? released
  function adapter.release(lease)
    if type(lease) ~= "table" then
      return true
    end
    local ok, released = pcall(function()
      return screen._assets:releaseEffectResource(lease)
    end)
    if not ok then
      return nil
    end
    return released
  end
  return adapter
end

---@param screen BattleScreenState owning screen behind failure reporting
---@param reason string terminal failure context under latching
local function failNative(screen, reason)
  if screen._mode == "failed" then
    return
  end
  screen._mode = "failed"
  screen._error = reason
end

---@param fault unknown player failure detail under rendering
---@return string readable provenance behind the failed occurrence
local function renderFault(fault)
  if type(fault) ~= "table" then
    return tostring(fault)
  end
  local detail = fault --[[@as table<string, unknown>]]
  return "instruction "
    .. tostring(detail.instructionIndex)
    .. " ("
    .. tostring(detail.op)
    .. "): "
    .. tostring(detail.reason)
end

---@param view table<string, unknown>? event-time view under copying
---@return table<string, unknown>? view copy with defaulted activation and position facts
local function enrichedViewForTopology(view)
  if type(view) ~= "table" then
    return nil
  end
  local out = {}
  for _, group in ipairs({ "own", "foes" }) do
    local records = view[group]
    if type(records) == "table" then
      local filled = {}
      for index, record in ipairs(records) do
        if type(record) == "table" then
          local copy = copyValue(record) --[[@as table<string, unknown>]]
          -- Legacy emissions predate activation and position facts;
          -- default to the native combatant identity so the
          -- visual-topology resolver still binds the event-time slot.
          -- Records carrying real facts pass through untouched.
          -- Explicitly benched reserves keep no slot facts: inventing
          -- positions from combatant identities would pollute the live
          -- side order (the full own roster pictures bench) with phantom
          -- slots, failing singles playback or misresolving it as
          -- doubles. Records predating the active flag read as active.
          if copy.active ~= false then
            if copy.activation == nil then
              copy.activation = copy.combatant
            end
            if copy.position == nil then
              copy.position = copy.combatant
            end
          end
          filled[index] = copy
        end
      end
      out[group] = filled
    end
  end
  return out
end

---@param event table<string, unknown> accepted event carrying its playback facts
---@param visualSeed integer deterministic visual seed behind the occurrence
---@return table<string, unknown> detached event with defaulted actor, target, and seed facts
local function enrichedEventForTopology(event, visualSeed)
  local out = copyValue(event) --[[@as table<string, unknown>]]
  for _, group in ipairs({ "actors", "targets" }) do
    local entries = out[group]
    if type(entries) == "table" then
      for _, entry in
        ipairs(entries --[[@as table<integer, table<string, unknown>>]])
      do
        if type(entry) == "table" and entry.activation == nil then
          entry.activation = entry.combatant
        end
      end
    end
  end
  if out.visualSeed == nil then
    out.visualSeed = visualSeed
  end
  return out
end

---@param screen BattleScreenState owning screen behind effect admission
---@param cue table<string, unknown> native-effect cue carrying accepted event/packet identity and semantic effect key
---@param effectKey string flat semantic effect key under admission
---@return table<string, unknown>? player handle behind the running occurrence, nil on terminal refusal
local function nativeEffectAdmit(screen, cue, effectKey)
  local record, loadFailure = screen._assets:loadEffect(effectKey)
  if record == nil then
    failNative(
      screen,
      "battle effect " .. effectKey .. " failed for launch " .. screen._launchId .. ": " .. tostring(loadFailure)
    )
    return nil
  end
  local program = record.program --[[@as table<string, unknown>?]]
  if type(program) ~= "table" then
    failNative(
      screen,
      "battle effect " .. effectKey .. " failed for launch " .. screen._launchId .. ": no compiled program"
    )
    return nil
  end
  -- C05 consumer obligation: reject any program whose task kind
  -- lacks a real factory body before anything stages.
  for _, kind in ipairs(program.taskKinds or {}) do
    if not BattleEffectTasks.supportsKind(kind) then
      failNative(
        screen,
        "battle effect "
          .. effectKey
          .. " failed for launch "
          .. screen._launchId
          .. ": task kind "
          .. tostring(kind)
          .. " has no real factory body"
      )
      return nil
    end
  end
  -- Admission probe: every declared staged texture must upload
  -- before the occurrence starts, so a terminal driver or payload
  -- failure names its resource instead of failing mid-run. The probe
  -- releases immediately; the run stages its own leases.
  local declared = record.resources
  if type(declared) == "table" then
    for resourceKey, descriptor in pairs(declared) do
      if type(descriptor) == "table" and descriptor.kind == "texture" then
        local lease, resolveFailure = screen._assets:resolveEffectResource(record, resourceKey)
        if lease == nil then
          failNative(
            screen,
            "battle effect "
              .. effectKey
              .. " failed for launch "
              .. screen._launchId
              .. ": "
              .. tostring(resolveFailure)
          )
          return nil
        end
        screen._assets:releaseEffectResource(lease)
      end
    end
  end
  -- Required-context probe: a program declaring resolved move power
  -- admits only a cue carrying the executed unsigned value. A missing
  -- or malformed fact fails with launch, effect, packet, and event
  -- provenance before anything stages; effects without the declaration
  -- start exactly as before.
  local required = record.requiredContext
  if type(required) == "table" and required.movePower ~= nil then
    local admitted = cue.event.move
    local power = type(admitted) == "table" and admitted.power or nil
    if type(power) ~= "number" or power % 1 ~= 0 or power < 0 or power > 65535 then
      failNative(
        screen,
        "battle effect "
          .. effectKey
          .. " failed for launch "
          .. screen._launchId
          .. ": required movePower has no usable resolved value for packet "
          .. tostring(cue.packetId)
          .. " event "
          .. tostring(cue.eventSequence)
          .. " kind "
          .. tostring(cue.event.kind)
      )
      return nil
    end
  end
  local slots = screen._manifest.battlefield.slots
  local enriched = enrichedEventForTopology(cue.event, cue.visualSeed)
  local ok, playback = pcall(BattlePresentationFlow.animationPlayback, {
    launchId = cue.launchId,
    packetId = cue.packetId,
    before = enrichedViewForTopology(cue.before),
    after = enrichedViewForTopology(cue.after),
  }, enriched, slots)
  if not ok then
    failNative(
      screen,
      "battle effect "
        .. effectKey
        .. " failed for launch "
        .. screen._launchId
        .. ": bad source topology: "
        .. tostring(playback)
    )
    return nil
  end
  screen._liveEffectRecord = record
  local handle = screen._player:start(playback, program)
  if handle == nil then
    screen._liveEffectRecord = nil
    failNative(
      screen,
      "battle effect " .. effectKey .. " failed for launch " .. screen._launchId .. ": program refused admission"
    )
    return nil
  end
  screen._liveEffectHandle = handle
  screen._nativeHandles[handle] = { handle = handle, effectKey = effectKey }
  return handle
end

---@param screen BattleScreenState owning screen behind effect admission
---@param cue table<string, unknown> native-effect cue carrying accepted event/packet identity and semantic effect key
---@return table<string, unknown>? player handle or pending token, nil on terminal refusal
local function nativeEffectStart(screen, cue)
  if screen._disposed or screen._mode == "failed" then
    return nil
  end
  local effectKey = cue.effectKey
  if type(effectKey) ~= "string" or effectKey == "" then
    return nil
  end
  local ready, demandFailure = screen._assets:demandEffect(effectKey)
  if demandFailure ~= nil then
    failNative(
      screen,
      "battle effect " .. effectKey .. " failed for launch " .. screen._launchId .. ": " .. tostring(demandFailure)
    )
    return nil
  end
  if ready ~= true then
    -- Still staging: park behind a pending token; status promotes
    -- once the worker closure validates, so pending stalls only
    -- presentation, never mechanics.
    local token = { pending = true }
    screen._nativeHandles[token] = { token = token, pending = true, effectKey = effectKey, cue = cue }
    return token
  end
  return nativeEffectAdmit(screen, cue, effectKey)
end

---@param screen BattleScreenState owning screen behind occurrence polling
---@param handleOrToken table<string, unknown> player handle or pending token under query
---@return string phase behind the hold: pending, running, waiting, complete, failed, or cancelled
local function nativeEffectStatus(screen, handleOrToken)
  local track = screen._nativeHandles[handleOrToken]
  if track == nil then
    -- Unknown or retired handles never settle silently: polling a
    -- handle the screen does not track fails the launch with provenance
    -- instead of parking the cue behind a pending that can never clear.
    failNative(
      screen,
      "battle effect handle for launch " .. screen._launchId .. " is unknown or retired; it never settles silently"
    )
    return "failed"
  end
  if track.pending == true then
    local ready, demandFailure = screen._assets:demandEffect(track.effectKey)
    if demandFailure ~= nil then
      track.pending = false
      track.failed = true
      failNative(
        screen,
        "battle effect "
          .. track.effectKey
          .. " failed for launch "
          .. screen._launchId
          .. ": "
          .. tostring(demandFailure)
      )
      return "failed"
    end
    if ready ~= true then
      return "pending"
    end
    track.pending = false
    local handle = nativeEffectAdmit(screen, track.cue, track.effectKey)
    if handle == nil then
      track.failed = true
      return "failed"
    end
    -- The token stays the stable track identity so every collaborator
    -- poll keeps resolving: the admitted handle rides the same track.
    track.handle = handle
  end
  if track.failed == true then
    return "failed"
  end
  if track.handle == nil then
    return "pending"
  end
  local phase = screen._player:status(track.handle)
  if phase == nil then
    return "pending"
  end
  if phase == "failed" then
    -- A failed program never counts as a completed invisible
    -- animation: the screen fails with launch, effect, packet, and
    -- instruction provenance and releases through disposal.
    local fault = screen._player:failure(track.handle)
    local holderError = screen._assets:error()
    local context = "battle effect "
      .. track.effectKey
      .. " failed for launch "
      .. screen._launchId
      .. ": "
      .. renderFault(fault)
    if type(holderError) == "string" and holderError ~= "" then
      context = context .. "; assets: " .. holderError
    end
    failNative(screen, context)
    return "failed"
  end
  return phase
end

---@param screen BattleScreenState owning screen behind occurrence polling
---@param handleOrToken table<string, unknown> player handle or pending token under cancellation
---@param reason string cancellation cause under diagnosis
local function nativeEffectCancel(screen, handleOrToken, reason)
  local track = screen._nativeHandles[handleOrToken]
  if track == nil then
    return
  end
  screen._nativeHandles[handleOrToken] = nil
  if track.handle ~= nil then
    screen._player:cancel(track.handle, reason)
    if screen._liveEffectHandle == track.handle then
      screen._liveEffectHandle = nil
      screen._liveEffectRecord = nil
    end
  end
end

-- Polls every tracked native occurrence once: pending tokens promote
-- when staged, failed programs fail the screen with provenance, and
-- the live record clears once its occurrence settles so a later
-- effect admits against its own closure. The generic poll never
-- releases: only the timeline consumption point retires a track.
---@param screen BattleScreenState owning screen behind occurrence polling
local function pollNativeEffects(screen)
  local keys = {}
  for key in pairs(screen._nativeHandles) do
    keys[#keys + 1] = key
  end
  for _, key in ipairs(keys) do
    if screen._nativeHandles[key] ~= nil then
      nativeEffectStatus(screen, key)
    end
  end
  local live = screen._liveEffectHandle
  if live ~= nil then
    local phase = screen._player:status(live)
    if phase ~= "preparing" and phase ~= "running" and phase ~= "waiting" then
      screen._liveEffectHandle = nil
      screen._liveEffectRecord = nil
    end
  end
end

-- Releases one consumed native occurrence after its timeline cue
-- observes completion: the track leaves the map, the player drops the
-- terminal record, and the live record clears when it names the retired
-- handle. Only the timeline consumption point calls this; the generic
-- poll never retires. Unknown or already-released identities refuse
-- without touching live work, and a release failure fails the launch
-- with provenance instead of counting a false completion.
---@param screen BattleScreenState owning screen behind occurrence retirement
---@param handleOrToken table<string, unknown> player handle or pending token under release
---@return boolean released true once the track and its terminal record were dropped
local function nativeEffectRetire(screen, handleOrToken)
  -- A promoted token keeps its stable track while admission also files
  -- the admitted handle beside it, so one retired identity can own two
  -- tracks. The release resolves the occurrence handle behind either
  -- identity first, then drops every track naming the token or that
  -- handle, and retires the single player occurrence behind them.
  local handle = nil
  local direct = screen._nativeHandles[handleOrToken]
  if direct ~= nil then
    handle = direct.handle
  else
    for _, track in pairs(screen._nativeHandles) do
      if track.handle == handleOrToken then
        handle = handleOrToken
        break
      end
    end
  end
  if direct == nil and handle == nil then
    return false
  end
  local keys = {}
  local effectKey = nil
  for key, track in pairs(screen._nativeHandles) do
    if key == handleOrToken or (handle ~= nil and (key == handle or track.handle == handle)) then
      keys[#keys + 1] = key
      if effectKey == nil then
        effectKey = track.effectKey
      end
    end
  end
  if handle == nil then
    for _, key in ipairs(keys) do
      screen._nativeHandles[key] = nil
    end
    return true
  end
  -- A refused player release leaves every track in place, so the next
  -- poll still resolves and the launch fails loudly instead of
  -- aliasing a live occurrence.
  local ok, retired = pcall(screen._player.retire, screen._player, handle)
  if not ok then
    failNative(
      screen,
      "battle effect "
        .. tostring(effectKey)
        .. " failed for launch "
        .. screen._launchId
        .. ": release failure: "
        .. tostring(retired)
    )
    return false
  end
  if retired ~= true then
    return false
  end
  for _, key in ipairs(keys) do
    screen._nativeHandles[key] = nil
  end
  if screen._liveEffectHandle == handle then
    screen._liveEffectHandle = nil
    screen._liveEffectRecord = nil
  end
  return true
end

---@param screen BattleScreenState owning screen behind effect admission
---@return table<string, unknown> battle-private native-effect collaborator behind start/status/cancel/retire
local function nativeEffectsFor(screen)
  ---@param cue table<string, unknown> native-effect cue carrying accepted event/packet identity and semantic effect key
  ---@return table<string, unknown>? player handle or pending token, nil on terminal refusal
  local function start(cue)
    return nativeEffectStart(screen, cue)
  end
  ---@param handleOrToken table<string, unknown> player handle or pending token under query
  ---@return string phase behind the hold
  local function status(handleOrToken)
    return nativeEffectStatus(screen, handleOrToken)
  end
  ---@param handleOrToken table<string, unknown> player handle or pending token under cancellation
  ---@param reason string cancellation cause under diagnosis
  local function cancel(handleOrToken, reason)
    nativeEffectCancel(screen, handleOrToken, reason)
  end
  ---@param handleOrToken table<string, unknown> player handle or pending token under release
  ---@return boolean released true once the track and its terminal record were dropped
  local function retire(handleOrToken)
    return nativeEffectRetire(screen, handleOrToken)
  end
  return { start = start, status = status, cancel = cancel, retire = retire }
end

---@param opts BattleScreenState.Options
---@return BattleScreenState
function BattleScreenState.new(opts)
  assert(type(opts) == "table", "the battle screen requires options")
  assert(type(opts.launchId) == "string" and opts.launchId ~= "", "the battle screen needs its launch identity")
  assert(type(opts.manifest) == "table", "the battle screen needs its planning manifest")
  assert(type(opts.model) == "table", "the battle screen needs its detached view boundary")
  assert(type(opts.submit) == "function", "the battle screen needs its accepted-choice boundary")
  if opts.onResultMusic ~= nil then
    assert(type(opts.onResultMusic) == "function", "the battle screen takes its terminal-music beat as a function")
  end
  assert(type(opts.measureDisplay) == "function", "the battle screen needs its display facts")
  assert(type(opts.assets) == "table", "the battle screen needs its preparation services")
  assert(type(opts.text) == "table", "the battle screen borrows its text services")
  assert(type(opts.windows) == "table", "the battle screen borrows its window services")
  assert(type(opts.audio) == "table", "the battle screen needs its sound boundary")
  if opts.monCatalog ~= nil then
    assert(type(opts.monCatalog) == "table", "the mon catalog arrives as a record")
  end
  if opts.monIconProvider ~= nil then
    assert(type(opts.monIconProvider) == "table", "the icon provider arrives as a record")
  end
  local overrides = opts.overrides or {}
  assert(type(overrides) == "table", "per-instance inputs arrive as a record")
  local manifest = opts.manifest --[[@as table<string, unknown>]]
  local sceneKey = overrides.sceneKey
  if sceneKey == nil and type(manifest.scenes) == "table" and type(manifest.scenes[1]) == "table" then
    sceneKey = manifest.scenes[1].key
  end
  assert(type(sceneKey) == "string" and sceneKey ~= "", "the battle screen resolves its scene identity")
  local self = setmetatable({
    _launchId = opts.launchId,
    _manifest = manifest,
    _model = opts.model,
    _submit = opts.submit,
    _measureDisplay = opts.measureDisplay,
    _text = opts.text,
    _windows = opts.windows,
    _audio = opts.audio,
    _battleAudio = BattleAudio.new({ sink = opts.audio, launchId = opts.launchId }),
    _legacyAudio = type(opts.audio.playCry) ~= "function",
    _monCatalog = opts.monCatalog,
    _monIconProvider = opts.monIconProvider,
    _battleMenus = opts.battleMenus,
    _assets = BattlePresentationAssets.new({
      assets = opts.assets,
      launchId = opts.launchId,
      sceneKey = sceneKey --[[@as string]],
      audioRoles = stagedAudioRoles(manifest, opts.musicRole),
      audioBanks = opts.musicBanks,
      shadowRegions = manifest.pictures.shadow.regions,
      sceneImage = overrides.sceneImage --[[@as string?]],
      frameKey = overrides.frameKey --[[@as string?]],
      frames = overrides.frames --[[@as table<string, table<string, unknown>>?]],
    }),
    _timeline = nil,
    _player = nil,
    _nativeRouting = false,
    _nativeHandles = {},
    _nativeVoices = {},
    _waitingCueVoice = nil,
    _liveEffectHandle = nil,
    _liveEffectRecord = nil,
    _session = nil,
    _subflows = BattleSubflows.new({
      launchId = opts.launchId,
      itemCatalog = opts.itemCatalog,
      monCatalog = opts.monCatalog,
      battleMenus = opts.battleMenus,
    }),
    _partySnapshot = nil,
    _inventorySnapshot = nil,
    _mode = "preparing",
    _selection = "fight",
    _commandX = 0,
    _commandY = 0,
    _savedCommandCursor = {},
    _savedMoveCursor = {},
    _savedTargetCursor = {},
    _keyboardFocus = false,
    _armed = nil,
    _buttonFeedback = nil,
    _child = nil,
    _request = nil,
    _options = nil,
    _actorIndex = 1,
    _staged = {},
    _lastStaged = nil,
    _targetCandidates = nil,
    _lastTargetSelection = nil,
    _targetGroup = nil,
    _targetRangeKey = nil,
    _pendingMoveId = nil,
    _pendingFinal = nil,
    _pendingRequest = nil,
    _pendingResult = nil,
    _outcomeMessages = nil,
    _pendingRegistration = nil,
    _registrationChild = nil,
    _registrationComplete = false,
    _pokedex = opts.pokedex,
    _registrationAudio = opts.registrationAudio,
    _onResultMusic = opts.onResultMusic,
    _resultMusicSent = false,
    _completion = nil,
    _completionChild = nil,
    _completionResult = nil,
    _consumedCompletions = {},
    _terminalRequest = nil,
    _introBuilt = false,
    _kind = "wild",
    _queue = {},
    _notice = nil,
    _showTimelineMessage = false,
    _signature = nil,
    _cursorTick = 0,
    _cursorWasVisible = false,
    _cursorSelection = nil,
    _activeEffectTick = 0,
    _activeEffectRunning = false,
    _sourceAccum = 0,
    _menuRevealStep = 4,
    _menuGateTicks = 0,
    _messageScrollY = -51,
    _menuPulseBlend = 0,
    _menuPulseDirection = 0,
    _iconAnimationTick = 0,
    _scene = BattleScene.new(),
    _gaugeVisuals = {},
    _sceneHasBackground = false,
    _sceneAccum = 0,
    _outcomeDone = false,
    _lastPlayerName = nil,
    _error = nil,
    _disposed = false,
  }, BattleScreenState)
  -- Foe move sets never enter the detached views, so foe narration
  -- resolves display names through the borrowed mon catalog. The
  -- resolver stays optional: views and raw identities cover its absence.
  local moveNameOf = nil
  local speciesNameOf = nil
  if type(opts.monCatalog) == "table" and type(opts.monCatalog.move) == "function" then
    local catalog = opts.monCatalog
    local lookup = opts.monCatalog.move --[[@as fun(self: table<string, unknown>, key: string): table<string, unknown>]]
    local function resolveMoveName(move)
      local ok, facts = pcall(lookup, catalog, move)
      if ok and type(facts) == "table" and type(facts.name) == "string" then
        return facts.name --[[@as string]]
      end
      return nil
    end
    moveNameOf = resolveMoveName
  end
  if type(opts.monCatalog) == "table" and type(opts.monCatalog.species) == "function" then
    local catalog = opts.monCatalog --[[@as table<string, unknown>]]
    local lookup = opts.monCatalog.species --[[@as fun(self: table<string, unknown>, key: string): table<string, unknown>]]
    local function resolveSpeciesName(species)
      local facts = lookup(catalog, species)
      return type(facts.name) == "string" and facts.name or nil
    end
    speciesNameOf = resolveSpeciesName
  end
  local itemNameOf = nil
  local battleItemUseOf = nil
  if type(opts.itemCatalog) == "table" and type(opts.itemCatalog.item) == "function" then
    local catalog = assert(opts.itemCatalog, "item lookup requires the borrowed catalog")
    local lookup = opts.itemCatalog.item --[[@as fun(self: table<string, unknown>, key: string): table<string, unknown>]]
    local function resolveItemName(item)
      local facts = lookup(catalog, item)
      assert(type(facts.name) == "string", "item catalog entries carry their display name")
      return facts.name --[[@as string]]
    end
    itemNameOf = resolveItemName
    local function resolveBattleItemUse(item)
      local definition = lookup(catalog, item)
      local battleUse = definition.battleUse
      return type(battleUse) == "table" and battleUse or nil
    end
    battleItemUseOf = resolveBattleItemUse
  end
  -- One animation player per battle screen over the live scene: the
  -- real task factory, a semantic voice adapter over the existing
  -- battle audio path, and a selected-effect resource adapter over the
  -- selected effect record and its dependencies. These are the real
  -- collaborators, not fake task or voice doubles.
  self._player = BattleAnimationPlayer.new({
    scene = self._scene,
    audio = nativeVoiceAdapter(self),
    resources = nativeResourceAdapter(self),
    tasks = BattleEffectTasks,
  })
  -- Native-effect routing engages only when the injected preparation
  -- services expose the lazy effect staging callbacks; legacy rigs without
  -- them keep the established generic cue vocabulary untouched.
  local assetServices = opts.assets
  local effects = nil
  if
    type(assetServices.requestEffect) == "function"
    and type(assetServices.loadEffect) == "function"
    and type(assetServices.resolveEffectResource) == "function"
    and type(assetServices.releaseEffectResource) == "function"
  then
    effects = nativeEffectsFor(self)
  end
  -- Without lazy effect staging callbacks the screen cannot admit
  -- native occurrences, so it presents the established generic cue
  -- vocabulary instead of wedging effect-keyed cues behind a
  -- collaborator that will never arrive.
  self._nativeRouting = effects ~= nil
  local function faintAppearance(battler)
    if type(battler.portraitSelector) ~= "string" then
      return nil
    end
    local attributes = BattleScene.pictureAttributes(self._manifest, battler.portraitSelector)
    if attributes == nil or type(attributes.height) ~= "number" then
      return nil
    end
    local picture = self._scene:pictureState(battler)
    local shadow = attributes.shadow --[[@as table<string, integer>?]]
    local height = battler.side ~= 1 and shadow and shadow.height or 0
    if picture ~= nil and type(picture.shadowHeight) == "number" then
      height = picture.shadowHeight
    end
    return {
      height = attributes.height --[[@as integer]],
      shadowHeight = height --[[@as integer]],
    }
  end
  local function ballFadeColor(ballKey)
    local balls = assert(self._manifest.battleBalls, "battle manifests inventory ball art")
    local entry = assert(balls.entries["ball:" .. ballKey], "recall and send-out balls are in the ball inventory")
    return entry.fadeColor
  end
  self._timeline = BattleTimeline.new({
    ballFadeColor = ballFadeColor,
    trainerPictures = self._manifest.trainerPictures.entries,
    moveName = moveNameOf,
    speciesName = speciesNameOf,
    itemName = itemNameOf,
    battleItemUse = battleItemUseOf,
    messageText = resolveBattleText,
    messageTextContext = self,
    textSpeed = opts.textSpeed or "mid",
    effects = effects,
    faintAppearance = faintAppearance,
  })
  local cases = nil
  if type(overrides.cases) == "table" then
    cases = overrides.cases
  end
  local ok, session = pcall(ApplicationPresentation.new, BattleScreenInterface.defaults(), cases)
  if not ok then
    self._mode = "failed"
    self._error = tostring(session)
    return self
  end
  self._session = session
  local measuredOk, measurement = pcall(self._measureDisplay)
  if measuredOk and measurement ~= nil then
    pcall(function()
      self._session:resolve(measurement, self:_snapshot())
    end)
    self._signature = (measurement --[[@as table<string, unknown>]]).signature --[[@as string?]]
  end
  return self
end

-- Resolves one battler's experience progress within its level from the
-- borrowed mon catalog growth curve: the absolute experience minus the
-- level base over the level span. Anything unanswerable stays absent;
-- the renderer draws an empty experience row without a span.
---@param catalog table<string, unknown>? borrowed immutable mon catalog
---@param battler table<string, unknown> displayed battler facts under reading
---@return number? progress within the level, nil when unanswerable
---@return number? level span, nil when unanswerable
local function expProgress(catalog, battler)
  if type(catalog) ~= "table" then
    return nil, nil
  end
  local speciesKey = battler.species
  local level = battler.level
  local exp = battler.exp
  if type(speciesKey) ~= "string" or speciesKey == "" then
    return nil, nil
  end
  if type(level) ~= "number" or level % 1 ~= 0 or level < 1 or level >= 100 then
    return nil, nil
  end
  if type(exp) ~= "number" then
    return nil, nil
  end
  local speciesOf = catalog.species --[[@as fun(self: table<string, unknown>, key: string): table<string, unknown>?]]
  local curveOf = catalog.growthCurve --[[@as fun(self: table<string, unknown>, key: string): table<integer, integer>?]]
  if type(speciesOf) ~= "function" or type(curveOf) ~= "function" then
    return nil, nil
  end
  local okSpecies, species = pcall(speciesOf, catalog, speciesKey)
  if not okSpecies or type(species) ~= "table" or type(species.growthCurve) ~= "string" then
    return nil, nil
  end
  local okCurve, curve = pcall(curveOf, catalog, species.growthCurve --[[@as string]])
  if not okCurve or type(curve) ~= "table" then
    return nil, nil
  end
  local base, top = curve[level], curve[level + 1]
  if type(base) ~= "number" or type(top) ~= "number" or top <= base then
    return nil, nil
  end
  local into = exp - base
  if into < 0 then
    into = 0
  elseif into > top - base then
    into = top - base
  end
  return into, top - base
end

---@param battlers table<integer, table<string, unknown>> displayed battlers
---@return integer[], integer[] foe then player occupied positions
local function sceneSlotOrders(battlers)
  local foeOrder, allyOrder = {}, {}
  local foeSeen, allySeen = {}, {}
  for _, battler in ipairs(battlers) do
    if type(battler) == "table" and type(battler.position) == "number" then
      if battler.side == 1 then
        if not allySeen[battler.position] then
          allySeen[battler.position] = true
          allyOrder[#allyOrder + 1] = battler.position --[[@as integer]]
        end
      elseif not foeSeen[battler.position] then
        foeSeen[battler.position] = true
        foeOrder[#foeOrder + 1] = battler.position --[[@as integer]]
      end
    end
  end
  table.sort(foeOrder)
  table.sort(allyOrder)
  return foeOrder, allyOrder
end

-- Applies the effective blend-coefficient overlay to one battler: when
-- the battler's sprite-context slot appears in the active patch, the
-- per-item alpha takes the clamped sprite weight, exactly what the
-- picture pass already consumes. Retail EVA is the sprite weight
-- against the background at nominal full-strength 16, so
-- alpha = clamp(EVA, 0, 16) / 16. EVB weights the background plane the
-- composite always draws first and BLDCNT plane masks have no pixel
-- expression for this task kind, so both stay out of the mapping.
-- Sprite-context slots follow retail battler order: slot 0 names the
-- first player-side battler, slot 1 the first foe-side battler, slot 2
-- the second player-side battler, slot 3 the second foe-side battler.
-- Left/right resolves by sorted position order within the side, the
-- same order the slot geometry path trusts.
---@param battler table<string, unknown> displayed battler fact under blending
---@param order integer[] canonical claimed positions of the battler side in slot order
---@param blendSlots table<string, boolean> active sprite-context slot names
---@param coefficients table<string, unknown> effective blend register view
local function applyBlendAlpha(battler, order, blendSlots, coefficients)
  local sideBit = battler.side == 1 and 0 or 1
  for index, slot in ipairs(order) do
    if slot == battler.position then
      local name = "sprite-context-slot-" .. ((index - 1) * 2 + sideBit)
      if blendSlots[name] == true then
        local eva = coefficients.blendCoefficientA
        assert(type(eva) == "number", "blend overlays carry a numeric sprite weight")
        if eva < 0 then
          eva = 0
        elseif eva > 16 then
          eva = 16
        end
        battler.alpha = eva / 16
      end
      return
    end
  end
end

---@param self BattleScreenState
---@param battlers table<integer, table<string, unknown>> displayed battler facts under enriching
local function enrichScene(self, battlers)
  local foeOrder, allyOrder = sceneSlotOrders(battlers)
  local coefficients = self._scene:blendCoefficients()
  local blendSlots = nil
  if coefficients ~= nil and type(coefficients.spriteSlots) == "table" then
    blendSlots = {}
    for _, slot in ipairs(coefficients.spriteSlots) do
      blendSlots[slot] = true
    end
  end
  for _, battler in ipairs(battlers) do
    if type(battler) == "table" then
      local pictureState = self._scene:pictureState(battler)
      if pictureState ~= nil then
        for key, value in pairs(pictureState) do
          local faintOwned = battler.fainting == true
            and (
              key == "pictureVisible"
              or key == "pictureWidth"
              or key == "pictureHeight"
              or key == "pictureXOffset2"
              or key == "pictureYOffset2"
              or key == "pictureYOffset"
              or key == "shadowHeight"
            )
          if not faintOwned then
            if key == "pictureXOffset" and type(battler.pictureXOffset) == "number" then
              battler[key] = battler.pictureXOffset + value
            else
              battler[key] = value
            end
          end
        end
      end
      if type(battler.portraitSelector) == "string" then
        local pictureAttributes = BattleScene.pictureAttributes(self._manifest, battler.portraitSelector)
        if pictureAttributes ~= nil then
          battler.sourceHeight = pictureAttributes.height
          -- BattleControllerOpponent_CreatePokepic gives opponent pictures
          -- the species shadow: grounded 36 pixels below the settled row
          -- and the picture lifted by the shadow height. Animation patches
          -- already copied above keep precedence.
          local shadow = pictureAttributes.shadow --[[@as table<string, integer>?]]
          if battler.side ~= 1 and shadow ~= nil then
            local defaults = {
              shadowSize = shadow.size,
              shadowOffsetX = shadow.xOffset,
              shadowOffsetY = 36 - pictureAttributes.height,
              shadowHeight = shadow.height,
            }
            for key, value in pairs(defaults) do
              if battler[key] == nil then
                battler[key] = value
              end
            end
          end
          battler.pictureAnimation = pictureAttributes.animation
          local pose = self._scene:picturePose(battler, pictureAttributes.animation)
          battler.pictureFrame = pose.frame
          battler.pictureXOffset = pose.xOffset
          battler.pictureAnimationActive = pose.active
        end
      end
      local order = nil
      if type(battler.position) == "number" then
        order = battler.side == 1 and allyOrder or foeOrder
      end
      if blendSlots ~= nil and coefficients ~= nil and order ~= nil then
        applyBlendAlpha(battler, order, blendSlots, coefficients)
      end
      local row = BattleScene.slotRow(battler, order, self._manifest.battlefield.slots)
      battler.sideType = row.sideType
      if battler.side == 1 and (row.sideType == 2 or row.sideType == 4) then
        local modeSideType = self._scene:healthBoxModeSideType(battler)
        assert(
          modeSideType == nil or modeSideType == row.sideType,
          "health-box mode remains attached to its native row"
        )
        battler.healthBoxMode = self._scene:healthBoxMode(battler)
      end
      local dx, dy = self._scene:entryOffsetFor(battler, row)
      battler.entryDx = dx
      battler.entryDy = dy
      local into, span = expProgress(self._monCatalog, battler)
      if into ~= nil and span ~= nil then
        battler.expInto = into
        battler.expSpan = span
      end
    end
  end
end

---@param step integer source slide update count from zero through four
---@param sideType integer source battler position type
---@return table<string, unknown> detached native lower-plane window and scroll state
local function menuSlideState(step, sideType)
  local updates = math.min(step, 4)
  local x = -25500 + updates * 6375
  local y = 4000 - updates * 1000
  local bgY = 40
  if updates > 0 and updates < 4 then
    bgY = -(40 - updates * 10)
  end
  if updates == 4 then
    x = 0
    y = 144
    bgY = 0
  end
  -- Source BG IDs 4/5 are the first two lower menu planes (physical 0/1).
  local edge = 144 + math.floor(y / 100)
  local windowEdge
  local bg0x
  local bg1x
  if sideType == 4 then
    windowEdge = math.floor(-x / 100)
    bg0x = math.max(0, 255 - windowEdge)
    bg1x = 255 - windowEdge
    return {
      edge = edge,
      outsideTop = { x = windowEdge + 1, y = 0, width = 255 - windowEdge, height = 144 },
      outsideBottom = { x = 0, y = edge, width = 256, height = 192 - edge },
      scroll = {
        [0] = { x = bg0x, topY = 0, bottomY = bgY },
        [1] = { x = bg1x, topY = 0, bottomY = bgY },
      },
    }
  end
  local hundredths = math.modf(x / 100)
  windowEdge = 255 + hundredths
  if windowEdge == 0 then
    windowEdge = 1
  end
  bg0x = math.max(0, windowEdge)
  bg1x = windowEdge
  return {
    edge = edge,
    outsideTop = { x = 1, y = 0, width = windowEdge - 1, height = 144 },
    outsideBottom = { x = 0, y = edge, width = 256, height = 192 - edge },
    scroll = {
      [0] = { x = bg0x, topY = 0, bottomY = bgY },
      [1] = { x = bg1x, topY = 0, bottomY = bgY },
    },
  }
end

-- Applies a source appearance/transform update to the active visual scene.
-- Runtime simulation records remain owned by the battle timeline.
---@param battler table<string, unknown> activation receiving the presentation update
---@param attributes table<string, unknown> source picture attributes
---@return table<string, unknown> detached presentation view
function BattleScreenState:applyPictureState(battler, attributes)
  assert(type(attributes) == "table", "picture updates carry source attributes")
  if type(attributes.portraitSelector) == "string" and attributes.portraitSelector ~= "" then
    self._assets:addSelectors({ attributes.portraitSelector })
  end
  return self._scene:applyPictureState(battler, attributes)
end

-- Restores the activation's saved visual snapshot when its transform ends.
---@param battler table<string, unknown> activation being restored
---@return table<string, unknown>? restored presentation view
function BattleScreenState:restorePictureState(battler)
  return self._scene:restorePictureState(battler)
end

-- Starts the scene-owned portion of a send-out task at the controller's
-- event boundary. Task start policy stays with its event owner.
---@param battler table<string, unknown> displayed activation entering the scene
---@param stepX integer native controller horizontal step for this route
function BattleScreenState:startPictureEntry(battler, stepX)
  assert(type(battler) == "table", "picture entry names its activation")
  local battlers = self._timeline:battlers()
  local target = nil
  for _, candidate in ipairs(battlers) do
    if candidate.combatant == battler.combatant and candidate.activation == battler.activation then
      target = candidate
      break
    end
  end
  if target == nil then
    target = battler
    battlers[#battlers + 1] = target
  end
  local foes, allies = sceneSlotOrders(battlers)
  local order = target.side == 1 and allies or foes
  local row = BattleScene.slotRow(target, order, self._manifest.battlefield.slots)
  self._scene:install(target)
  self._scene:startEntry(target, row, stepX)
end

---@param battler table<string, unknown> activation whose entry phase is queried
---@return string phase
---@return integer remaining source wait ticks
function BattleScreenState:pictureEntryStatus(battler)
  return self._scene:entryStatus(battler)
end

---@param battler table<string, unknown> activation whose entry controller completed
---@param readiness { battlerReady: boolean, pictureAnimationActive: boolean, followupTaskRequired: boolean, followupTaskComplete: boolean } detached controller observations
---@return boolean true when the entry task completed
function BattleScreenState:completePictureEntry(battler, readiness)
  return self._scene:completeEntry(battler, readiness)
end

-- Starts one event-owned health task using its detached source checkpoint.
-- This screen exposes the visual mechanism; the controller owns timing and
-- decides which checkpoint starts or replaces the task.
---@param key string stable event-time task identity
---@param spec { maximum: integer, current: integer, delta: integer, amount?: integer, sideType: integer } detached source health facts
function BattleScreenState:startHealthGaugeTask(key, spec)
  assert(type(spec) == "table", "health tasks receive detached source facts")
  assert(
    type(spec.sideType) == "number" and spec.sideType == math.floor(spec.sideType),
    "health task identifies its native side type"
  )
  self._scene:startGaugeTask(key, {
    maximum = spec.maximum,
    current = spec.current,
    delta = spec.delta,
    tiles = BattleScene.HP_TILES,
    amount = spec.amount,
  })
  self._gaugeVisuals[key] = { sideType = spec.sideType, kind = "health" }
end

-- Starts one event-owned experience task at its supplied level checkpoint.
---@param key string stable event-time task identity
---@param spec { maximum: integer, current: integer, delta: integer, sideType: integer } detached source experience facts
function BattleScreenState:startExperienceGaugeTask(key, spec)
  assert(type(spec) == "table", "experience tasks receive detached source facts")
  assert(
    type(spec.sideType) == "number" and spec.sideType == math.floor(spec.sideType),
    "experience task identifies its native side type"
  )
  self._scene:startExpGaugeTask(key, spec)
  self._gaugeVisuals[key] = { sideType = spec.sideType, kind = "experience" }
end

---@param key string task identity under reading
---@return boolean true while the source task is moving
function BattleScreenState:gaugeTaskActive(key)
  return self._scene:gaugeTaskActive(key)
end

---@param key string task identity under reading
---@return number displayed task checkpoint
function BattleScreenState:gaugeTaskValue(key)
  return self._scene:gaugeTaskValue(key)
end

---@param key string task identity under patching
---@param sideType integer? native side type for a health bar
---@return table<integer, { barIndex: integer, tile: integer, sourceTile: integer, fill: integer }> native character-buffer writes
function BattleScreenState:gaugeTaskPatchTiles(key, sideType)
  return self._scene:gaugeTaskPatchTiles(self._manifest.hud.patchSpans, key, sideType)
end

-- Removes the completed task's visual override after its controller has
-- observed the completion gate and accepted the endpoint checkpoint.
---@param key string completed task identity
function BattleScreenState:completeGaugeTask(key)
  self._scene:completeGaugeTask(key)
  self._gaugeVisuals[key] = nil
end

-- Exposes the controller-selected visual state; event timing stays with its owner.
---@param battler table<string, unknown> active player activation
---@param sideType integer native double-player side type
---@param mode string source health-box mode
function BattleScreenState:setHealthBoxMode(battler, sideType, mode)
  self._scene:setHealthBoxMode(battler, sideType, mode)
end

-- Allocates a screen-lifetime transient visual slot for an animation owner.
---@param sourceKey string semantic source route key
---@return { id: integer, sourceKey: string, age: integer } launch-owned instance identity
function BattleScreenState:allocateEffect(sourceKey)
  assert(not self._disposed, "disposed screens allocate no effects")
  return self._scene:allocEffect(sourceKey)
end

-- Supplies the currently selected staged picture and native attributes for
-- one transient slot. Animation policy and source timing remain with the caller.
---@param id integer live screen effect identity
---@param picture table<string, unknown> staged drawable key and native picture state
---@return boolean applied true only when the requested drawable is ready
---@return string? failure terminal staging failure, nil while pending or ready
function BattleScreenState:setEffectPicture(id, picture)
  assert(not self._disposed, "disposed screens update no effects")
  assert(type(picture) == "table" and type(picture.selector) == "string", "transient pictures carry a demand selector")
  self._assets:addSelectors({ picture.selector })
  local assetKey = assert(picture.assetKey, "transient pictures name a staged drawable")
  local image, failure = self._assets:drawable(assetKey --[[@as string]])
  if image == nil then
    return false, failure
  end
  self._scene:setEffectPicture(id, picture)
  return true
end

-- Removes one transient visual slot from future immutable render snapshots.
---@param id integer effect identity under release
function BattleScreenState:releaseEffect(id)
  assert(not self._disposed, "disposed screens release no effects")
  self._scene:releaseEffect(id)
end

---@param tokens table<integer, table<string, unknown>> source menu label token stream
---@return string rendered menu label containing only source glyphs
local function menuLabelText(tokens)
  local glyphs = {}
  for _, token in ipairs(tokens) do
    if token.kind == "eos" then
      break
    elseif token.kind == "glyph" then
      glyphs[#glyphs + 1] = assert(token.text, "menu label glyphs carry decoded text")
    elseif token.kind == "unsupported_control" and token.control == FieldMessageText.ALN_CENTER then
      -- The source text object centers the label at its authored x anchor.
    else
      assert(false, "two-option labels contain only alignment and glyph tokens")
    end
  end
  return table.concat(glyphs)
end

-- Resolves the source nickname question through the staged battle message bank.
---@param manifest table<string, unknown> staged battle manifest
---@param catalog table<string, unknown>? borrowed mon catalog
---@param subject table<string, unknown> exact committed caught mon under naming
---@return string question wording for the Yes/No decision
local function completionQuestionText(manifest, catalog, subject)
  local name = subject.nickname
  if type(name) ~= "string" or name == "" then
    local species = subject.species
    local facts = nil
    if type(species) == "string" then
      facts = assert(catalog, "nickname questions resolve species through the borrowed mon catalog"):species(species)
    elseif type(species) == "number" then
      facts = assert(catalog, "nickname questions resolve species through the borrowed mon catalog"):speciesByNativeId(
        species
      )
    end
    name = type(facts) == "table" and facts.name or nil
  end
  assert(type(name) == "string" and name ~= "", "nickname questions carry the caught mon's visible name")
  return stagedBattleText(manifest, "battle/narration/caught-nickname-question", { name })
end

---@param child table<string, unknown>? detached current child view
---@return table<string, unknown>? child view with source menu labels when confirmation is active
function BattleScreenState:_twoOptionChildView(child)
  if type(child) ~= "table" or child.kind ~= "learn" or type(child.confirmation) ~= "table" then
    return child
  end
  local confirmation = child.confirmation --[[@as table<string, unknown>]]
  local routeKey, topKey, bottomKey
  if confirmation.kind == "replace" then
    routeKey, topKey, bottomKey = "menu/keep-forget", "label/forget-move", "label/keep-move"
  else
    routeKey, topKey, bottomKey = "menu/yes-no", "label/yes", "label/no"
  end
  local menus = assert(self._manifest.menus, "learning confirmations require the staged menu catalog") --[[@as table<string, unknown>]]
  local routes = assert(menus.routes, "learning confirmations require staged source routes") --[[@as table<string, unknown>]]
  local route = assert(routes[routeKey], "learning confirmation selects its source menu route") --[[@as table<string, unknown>]]
  local selected = {}
  for _, key in
    ipairs(route.messageEntries --[[@as table<integer, string>]])
  do
    selected[key] = true
  end
  assert(selected[topKey] == true and selected[bottomKey] == true, "the selected text set stages both source labels")
  local messages = assert(self._manifest.messages, "learning labels require staged battle text") --[[@as table<string, unknown>]]
  local entries = assert(messages.entries, "learning labels require staged message entries") --[[@as table<string, table<string, unknown>>]]
  local topRecord = assert(entries[topKey], "the top source option has a staged label")
  local bottomRecord = assert(entries[bottomKey], "the bottom source option has a staged label")
  child.twoOption = {
    route = routeKey,
    top = menuLabelText(topRecord.tokens --[[@as table<integer, table<string, unknown>>]]),
    bottom = menuLabelText(bottomRecord.tokens --[[@as table<integer, table<string, unknown>>]]),
  }
  return child
end

---@param names table<integer, table<string, unknown>> displayed battlers by combatant identity
---@return string? retained select prompt while the command menu is open, nil otherwise
function BattleScreenState:_commandPrompt(names)
  -- The framed top-screen narration keeps the select prompt through
  -- command root: the menu opens over the printed question instead of
  -- clearing it, so the settled command view carries the wording while
  -- the cue player stays settled behind the open decision. The prompt
  -- names the acting entry only; an unresolvable actor keeps the cue
  -- wording so the slot binding below still guards the resolution.
  if self._mode ~= "command" then
    return nil
  end
  if self._request == nil or type(self._request.actors) ~= "table" then
    return nil
  end
  local actors = self._request.actors --[[@as table<integer, table<string, unknown>>]]
  local addressed = actors[self._actorIndex]
  if type(addressed) ~= "table" or type(addressed.combatant) ~= "number" then
    return nil
  end
  local battler = names[
    addressed.combatant --[[@as integer]]
  ]
  if type(battler) ~= "table" or type(battler.name) ~= "string" or battler.name == "" then
    return nil
  end
  return stagedBattleText(self._manifest, "battle/child/command-prompt", {
    battler.name --[[@as string]],
  })
end

---@return table<string, unknown> internal semantic snapshot for resolvers and renderers
function BattleScreenState:_snapshot()
  local battlers = self._timeline:battlers()
  local openingPresentation = self._timeline:openingPresentation()
  local sceneAssets = self._assets:sceneLayer()
  local introLayer = type(sceneAssets) == "table" and sceneAssets.introLayer or nil
  local terrainSprites = type(sceneAssets) == "table" and sceneAssets.terrainSprites or nil
  if openingPresentation ~= nil then
    local trainerEntries = self._manifest.trainerPictures.entries
    for _, slide in ipairs(openingPresentation.trainerSlides or {}) do
      local selector =
        assert(type(slide.selector) == "string" and slide.selector, "trainer slides name a staged picture")
      local entry = assert(trainerEntries[selector], "trainer slides resolve to staged picture metadata")
      local frame = assert(type(slide.frame) == "number" and slide.frame, "trainer slides select a source frame")
      local sourceSequence = assert(slide.sourceSequence, "trainer slides identify their source animation sequence")
      local animationData = assert(entry.animation, "trainer picture metadata stages animation frames")
      local animation = sourceSequence == 0 and animationData or animationData.sequences[sourceSequence + 1]
      assert(animation ~= nil, "trainer slide sequence is staged")
      local sourceFrame = assert(animation.frames[frame + 1], "trainer slide frame resolves to staged source metadata")
      local offset = assert(sourceFrame.rasterOffset, "trainer frame metadata includes its raster origin")
      slide.drawableKey = assert(sourceFrame.drawableKey, "trainer frame metadata includes its exact drawable key")
      slide.x = assert(type(slide.x) == "number" and slide.x, "trainer slides carry an origin x") + offset.x
      slide.y = assert(type(slide.y) == "number" and slide.y, "trainer slides carry an origin y") + offset.y
    end
    local trainerPictures = {} ---@type string[]
    local latestView = self._pendingFinal or self._latestView
    if openingPresentation.playerTrainerVisible == true and type(latestView) == "table" then
      local playerTrainer = latestView.playerTrainer
      if type(playerTrainer) == "table" and type(playerTrainer.classKey) == "string" then
        trainerPictures[#trainerPictures + 1] = "back:" .. playerTrainer.classKey
      end
    end
    if openingPresentation.foeTrainerVisible == true and type(latestView) == "table" then
      local foeTrainers = latestView.foeTrainers
      if type(foeTrainers) == "table" then
        for _, trainer in ipairs(foeTrainers) do
          if type(trainer) == "table" and type(trainer.classKey) == "string" then
            trainerPictures[#trainerPictures + 1] = "front:" .. trainer.classKey
          end
        end
      end
    end
    self._assets:addTrainerPictures(trainerPictures)
    local battleBalls = {} ---@type string[]
    if type(latestView) == "table" then
      for _, groupName in ipairs({ "own", "foes" }) do
        local group = latestView[groupName]
        if type(group) == "table" then
          for _, record in ipairs(group) do
            if type(record) == "table" and record.active ~= false and type(record.ballKey) == "string" then
              battleBalls[#battleBalls + 1] = "ball:" .. record.ballKey
            end
          end
        end
      end
    end
    self._assets:addBattleBalls(battleBalls)
  end
  for _, battler in ipairs(battlers) do
    battler.shakeDx = self._timeline:shake(battler.combatant --[[@as integer]])
  end
  self._scene:observe(battlers)
  enrichScene(self, battlers)
  local roster = {}
  local latest = self._pendingFinal or self._latestView
  if type(latest) == "table" and type(latest.own) == "table" then
    for _, record in ipairs(latest.own) do
      if type(record) == "table" then
        roster[#roster + 1] = { slot = record.slot, hp = record.hp, maxHp = record.maxHp }
      end
    end
  end
  local foes = 1
  if type(latest) == "table" and type(latest.foes) == "table" then
    foes = math.max(1, #latest.foes)
  end
  local names = {}
  for _, battler in ipairs(battlers) do
    if type(battler) == "table" and type(battler.combatant) == "number" then
      names[battler.combatant] = battler
    end
  end
  local commandPrompt = self:_commandPrompt(names)
  local timelineMessage = self._timeline:message()
  local timelineMessageActive = self._timeline:messageActive()
  local levelUpStats = self._timeline:levelUpStats()
  local message = self._notice
  if message == nil or message == "" then
    if (self._showTimelineMessage or timelineMessageActive) and timelineMessage ~= "" then
      message = timelineMessage
    else
      message = commandPrompt or timelineMessage
    end
  end
  local acting = nil
  local activeBattler = nil
  local addressedActor = false
  if self._request ~= nil and type(self._request.actors) == "table" then
    local actors = self._request.actors --[[@as table<integer, table<string, unknown>>]]
    local addressed = actors[self._actorIndex]
    if type(addressed) == "table" then
      addressedActor = true
      activeBattler = type(addressed.combatant) == "number" and names[addressed.combatant] or nil
      if activeBattler == nil and type(addressed.combatant) ~= "number" then
        -- A command actor that names no combatant still acts for the
        -- near side: resolve the lead live player-side record so the
        -- menu slide keeps its source slot instead of vanishing. A
        -- combatant that names no displayed battler stays dangling
        -- and trips the slot binding below.
        local lead = nil
        for _, id in ipairs(self._timeline:order()) do
          local shown = names[id]
          if type(shown) == "table" and shown.side == 1 and shown.visible ~= false then
            lead = shown
            break
          end
        end
        activeBattler = lead
      end
      acting = {
        index = self._actorIndex,
        total = #actors,
        combatant = addressed.combatant,
        activation = addressed.activation,
        sideType = type(activeBattler) == "table" and activeBattler.sideType or nil,
      }
    end
  end
  if
    activeBattler == nil
    and not addressedActor
    and (self._mode == "command" or self._mode == "moves" or self._mode == "target")
  then
    for _, battler in ipairs(battlers) do
      if battler.side == 1 and battler.visible ~= false then
        activeBattler = battler
        break
      end
    end
  end
  if
    activeBattler ~= nil
    and activeBattler.side == 1
    and (self._mode == "command" or self._mode == "moves" or self._mode == "target")
  then
    local angle = math.rad(20 * self._activeEffectTick)
    activeBattler.hudOffsetY = math.modf(1.5 * math.sin(angle))
    if self._kind ~= "safari" and self._kind ~= "pal-park" then
      activeBattler.pictureYOffset = (
        type(activeBattler.pictureYOffset) == "number" and activeBattler.pictureYOffset or 0
      ) + math.modf(1.5 * math.sin(math.rad(180 + 20 * self._activeEffectTick)))
    end
  end
  local commandIcon = nil
  if type(latest) == "table" and type(latest.own) == "table" then
    local iconRecord = nil
    if type(acting) == "table" then
      for _, record in ipairs(latest.own) do
        if type(record) == "table" and record.combatant == acting.combatant and record.active ~= false then
          iconRecord = record
          break
        end
      end
    end
    if iconRecord == nil then
      for _, record in ipairs(latest.own) do
        if type(record) == "table" and record.active ~= false and type(record.slot) == "number" then
          iconRecord = record
          break
        end
      end
    end
    if
      iconRecord ~= nil
      and type(iconRecord.species) == "string"
      and type(iconRecord.form) == "number"
      and iconRecord.form % 1 == 0
      and iconRecord.form >= 0
    then
      local iconKey = MonCache.iconSelector(iconRecord.species, iconRecord.form --[[@as integer]], false)
      if self._monIconProvider ~= nil then
        local hp = tonumber(iconRecord.hp) or 0
        local maxHp = tonumber(iconRecord.maxHp) or 0
        local condition = type(iconRecord.condition) == "string" and iconRecord.condition:lower() or ""
        local animation = 0
        if hp > 0 and condition ~= "sleep" then
          if condition == "poison" or condition == "bad-poison" then
            animation = 5
          elseif maxHp > 0 then
            local pixels = math.max(1, math.floor(hp * 48 / maxHp))
            animation = hp == maxHp and 1 or pixels > 24 and 2 or pixels > 9 and 3 or 4
          end
        end
        commandIcon = {
          key = iconKey,
          hp = hp,
          maxHp = maxHp,
          animation = animation,
          frameIndex = animation == 0 and 1 or math.floor(self._iconAnimationTick / (animation + 2)) % 2 + 1,
          rightOfLabel = type(acting) == "table" and acting.sideType == 4,
        }
      end
    end
  end
  local iconKeys = commandIcon ~= nil and { commandIcon.key } or {}
  local activeChildView = self._subflows:status().childView
  local childNative = type(activeChildView) == "table" and activeChildView.native or nil
  local childParty = type(childNative) == "table" and childNative.view or nil
  local childSlots = type(childParty) == "table" and childParty.slots or nil
  if type(childSlots) == "table" then
    for _, slot in ipairs(childSlots) do
      if type(slot) == "table" and slot.occupied == true and type(slot.iconKey) == "string" then
        iconKeys[#iconKeys + 1] = slot.iconKey
      end
    end
  end
  local menuWindows = nil
  if self._mode == "command" and self._menuGateTicks > 0 and type(acting) == "table" then
    local sideType = acting.sideType
    assert(
      type(sideType) == "number" and sideType % 1 == 0,
      "the active command actor resolves its integer source battle slot"
    )
    menuWindows = menuSlideState(self._menuRevealStep, sideType --[[@as integer]])
  end
  local targets = nil
  if self._targetCandidates ~= nil then
    targets = {}
    for _, candidate in ipairs(self._targetCandidates) do
      local known = type(candidate.combatant) == "number" and names[candidate.combatant] or nil
      local iconKey = nil
      if
        type(known) == "table"
        and known.visible ~= false
        and type(known.species) == "string"
        and type(known.form) == "number"
        and known.form % 1 == 0
        and known.form >= 0
      then
        iconKey = MonCache.iconSelector(known.species, known.form --[[@as integer]], false)
        iconKeys[#iconKeys + 1] = iconKey
      end
      local iconFrameIndex = nil
      if iconKey ~= nil then
        assert(type(known) == "table" and known.visible ~= false, "a target icon belongs to a visible battler")
        local hp = tonumber(known.hp) or 0
        local maxHp = tonumber(known.maxHp) or 0
        local condition = type(known.condition) == "string" and known.condition:lower() or ""
        local animation = 0
        if hp > 0 and condition ~= "sleep" then
          if condition == "poison" or condition == "bad-poison" then
            animation = 5
          elseif maxHp > 0 then
            local pixels = math.max(1, math.floor(hp * 48 / maxHp))
            animation = hp == maxHp and 1 or pixels > 24 and 2 or pixels > 9 and 3 or 4
          end
        end
        iconFrameIndex = animation == 0 and 1 or math.floor(self._iconAnimationTick / (animation + 2)) % 2 + 1
      end
      local gender = type(known) == "table" and known.gender or nil
      if gender == nil and type(known) == "table" and type(known.portraitSelector) == "string" then
        gender = known.portraitSelector:match("^[^/]+/f%d+/([^/]+)/")
      end
      local controlId = type(known) == "table"
          and known.visible ~= false
          and TARGET_CONTROL_BY_SIDE_TYPE[
            known.sideType --[[@as integer?]]
          ]
        or nil
      candidate.controlId = controlId
      targets[#targets + 1] = {
        id = controlId,
        fragmentId = candidate.id,
        position = candidate.position,
        enabled = candidate.enabled == true,
        reason = candidate.reason,
        name = (type(known) == "table" and known.visible ~= false and type(known.name) == "string") and known.name
          or nil,
        level = type(known) == "table" and known.level or nil,
        gender = gender,
        iconKey = iconKey,
        iconFrameIndex = iconFrameIndex,
        sideType = type(known) == "table" and known.sideType or nil,
        visible = type(known) == "table" and known.visible ~= false,
        side = type(known) == "table" and known.side or nil,
      }
    end
  end
  self._assets:setIconKeys(iconKeys)
  local staged = {}
  if self._request ~= nil and type(self._request.actors) == "table" then
    local actors = self._request.actors --[[@as table<integer, table<string, unknown>>]]
    for index, addressed in ipairs(actors) do
      local fragment = self._staged[index]
      if type(fragment) == "table" and type(addressed) == "table" then
        staged[#staged + 1] = {
          index = index,
          combatant = addressed.combatant,
          kind = fragment.kind,
        }
      end
    end
  end
  local gaugePatchTiles = {}
  for key, visual in pairs(self._gaugeVisuals) do
    local side = gaugePatchTiles[visual.sideType]
    if side == nil then
      side = {}
      gaugePatchTiles[visual.sideType] = side
    end
    side[visual.kind] = self._scene:gaugeTaskPatchTiles(self._manifest.hud.patchSpans, key, visual.sideType)
  end
  local childView = self:_completionChildView(self:_twoOptionChildView(copyValue(self._subflows:status().childView)))
  if type(childView) == "table" then
    if childView.kind == "party" then
      childView.sourceTitle = stagedBattleText(self._manifest, "battle/child/party-title", {})
    elseif childView.kind == "target" then
      childView.sourceTitle = stagedBattleText(self._manifest, "battle/child/target-title", {})
    elseif childView.kind == "move" then
      childView.sourcePrompt = stagedBattleText(self._manifest, "battle/child/move-prompt", {})
    elseif childView.kind == "learn" and childView.twoOption == nil then
      childView.sourcePrompt = stagedBattleText(self._manifest, "battle/child/learn-prompt", {})
    end
  end
  -- While the nickname question waits for its answer, the prompt names
  -- the decision instead of the settled terminal cue behind it.
  local completionPrompt = nil
  if self._completion ~= nil and self._outcomeDone and self._completion.stage == "question" then
    completionPrompt = completionQuestionText(
      self._manifest,
      self._monCatalog,
      self._completion.subject --[[@as table<string, unknown>]]
    )
  end
  local buttonFeedback = nil
  local armed = self._armed
  if self._buttonFeedback ~= nil then
    local feedback = self._buttonFeedback --[[@as table<string, unknown>]]
    local ticks = feedback.ticks --[[@as integer]]
    buttonFeedback = {
      scope = feedback.scope,
      id = feedback.id,
      offsetY = ticks == 0 and -2 or ticks == 1 and -1 or 0,
    }
    if ticks == 0 then
      armed = { scope = feedback.scope, id = feedback.id }
    end
  end
  return {
    battleKind = self._kind,
    menuMode = self:_menuMode(),
    menuLayoutVariant = self:_menuLayoutVariant(),
    menuDynamicFields = self:_menuDynamicFields(),
    mode = self._mode,
    menuRevealEdge = type(menuWindows) == "table" and menuWindows.edge or nil,
    menuWindows = menuWindows,
    menuInputEnabled = self._menuGateTicks == 0,
    selection = self._selection,
    cursorVisible = self._keyboardFocus and self._mode ~= "child",
    cursorTick = self._cursorTick,
    armed = armed ~= nil and { scope = armed.scope, id = armed.id } or nil,
    buttonFeedback = buttonFeedback,
    touchFeedback = self._armed ~= nil and self._armed.id == "dialogue" and self._armed.pointerId ~= nil or false,
    requestId = self._request ~= nil and self._request.requestId or 0,
    message = (self._notice ~= nil and self._notice ~= "" and self._notice or completionPrompt or message),
    messageScrollY = self._messageScrollY,
    menuPulse = self._menuPulseBlend,
    battlers = battlers,
    bgScroll = self._scene:scroll(),
    backgroundRaster = self._scene:hasBackground() and self._scene:backgroundRaster() or nil,
    effectInstances = self._scene:effectViews(),
    slotGeometry = self._manifest.battlefield.slots,
    hudSections = { player = self._manifest.hud.player, enemy = self._manifest.hud.enemy },
    gaugeFamilies = {
      player = copyValue(self._manifest.hud.partyGauges[2]),
      enemy = copyValue(self._manifest.hud.partyGauges[1]),
    },
    openingPresentation = openingPresentation,
    introScene = type(introLayer) == "table" and introLayer.drawable or nil,
    terrainSprites = terrainSprites,
    playerTrainer = type(latest) == "table" and latest.playerTrainer or nil,
    foeTrainers = type(latest) == "table" and latest.foeTrainers or nil,
    levelUpStats = levelUpStats,
    menuLayers = {
      command = self._manifest.menus.command.screens,
      moves = self._manifest.menus.moves.screens,
      target = self._manifest.menus.target.screens,
      twoOption = self._manifest.menus.twoOption.screens,
    },
    hudPatchSpans = self._manifest.hud.patchSpans,
    cursor = self._manifest.hud.cursor,
    menuText = self:_menuText(),
    textPalettes = {
      narration = self._manifest.messages.roles.narration.palette,
      hud = self._manifest.messages.roles.hud.palette,
      menu = self._manifest.messages.roles.menu.palette,
    },
    gaugePatchTiles = gaugePatchTiles,
    commands = self:_commands(),
    moves = self:_moves(),
    partyRoster = roster,
    foeCount = foes,
    actor = acting,
    commandIcon = self._mode == "command" and commandIcon or nil,
    targetCandidates = targets,
    targetGroup = copyValue(self._targetGroup),
    stagedChoices = staged,
    childIntent = self._child ~= nil and copyValue(self._child) or nil,
    childView = childView,
  }
end

---@return table<string, unknown>? options entry for the acting request position, nil without an open request
function BattleScreenState:_actorOptions()
  if self._request == nil or self._options == nil then
    return nil
  end
  local actors = self._request.actors --[[@as table<integer, table<string, unknown>>?]]
  if type(actors) ~= "table" then
    return nil
  end
  local addressed = actors[self._actorIndex]
  if type(addressed) ~= "table" then
    return nil
  end
  local entries = self._options.actors --[[@as table<integer, table<string, unknown>>?]]
  if type(entries) ~= "table" then
    return nil
  end
  for _, entry in ipairs(entries) do
    if
      type(entry) == "table"
      and entry.combatant == addressed.combatant
      and entry.activation == addressed.activation
    then
      return entry --[[@as table<string, unknown>]]
    end
  end
  return nil
end

---@return string staged menu mode behind the launch kind
function BattleScreenState:_menuMode()
  local mode = KIND_MENU_MODE[self._kind]
  if type(mode) == "string" then
    return mode
  end
  return "standard"
end

---@return string[] command identities offered by the launch kind in slot order
function BattleScreenState:_surfaceIds()
  local ids = KIND_COMMANDS[self._kind]
  if type(ids) == "table" then
    return ids
  end
  return ORDINARY_COMMANDS
end

---@return string first command identity behind the launch kind surface
function BattleScreenState:_defaultCommandSelection()
  local ids = self:_surfaceIds()
  local first = ids[1]
  if type(first) == "string" then
    return first
  end
  return "fight"
end

---@return table<string, string> staged label keys by ordinary slot key for the launch kind
function BattleScreenState:_menuLabels()
  local manifest = self._manifest --[[@as table<string, unknown>]]
  local menus = type(manifest) == "table" and manifest.menus --[[@as table<string, unknown>?]]
  local modeRules = type(menus) == "table" and menus.modeRules --[[@as table<string, unknown>?]]
  local rule = type(modeRules) == "table" and modeRules[self:_menuMode()] --[[@as table<string, unknown>?]]
  local labels = type(rule) == "table" and rule.labels --[[@as table<string, string>?]]
  if type(labels) ~= "table" then
    return {}
  end
  return labels --[[@as table<string, string>]]
end

---@return string[] staged dynamic field names behind the launch kind menu mode
function BattleScreenState:_menuDynamicFields()
  local manifest = self._manifest --[[@as table<string, unknown>]]
  local menus = type(manifest) == "table" and manifest.menus --[[@as table<string, unknown>?]]
  local modeRules = type(menus) == "table" and menus.modeRules --[[@as table<string, unknown>?]]
  local rule = type(modeRules) == "table" and modeRules[self:_menuMode()] --[[@as table<string, unknown>?]]
  local dynamicFields = type(rule) == "table" and rule.dynamicFields --[[@as string[]?]]
  if type(dynamicFields) ~= "table" then
    return {}
  end
  return copyValue(dynamicFields) --[[@as string[] ]]
end

---@return string menu layout variant behind the launch kind
function BattleScreenState:_menuLayoutVariant()
  if self._kind == "frontier" then
    return "frontier"
  end
  return "standard"
end

---@return table<string, string> source fight-menu labels: the PP marker and the cancel control
function BattleScreenState:_menuText()
  local entries = self._manifest.messages.entries --[[@as table<string, table<string, unknown>>]]
  local function text(key)
    local record = assert(entries[key], "the fight menu stages its source label " .. key)
    return menuLabelText(record.tokens --[[@as table<integer, table<string, unknown>>]])
  end
  return { pp = text("label/pp-max"), cancel = text("label/target-cancel") }
end

---@return table<integer, table<string, unknown>> command facts with kernel refusal reasons
function BattleScreenState:_commands()
  local runEnabled = true
  local runReason = nil
  local entry = self:_actorOptions()
  if type(entry) == "table" and type(entry.choices) == "table" then
    for _, choice in ipairs(entry.choices) do
      if type(choice) == "table" and choice.role == "run" then
        runEnabled = choice.enabled == true
        if type(choice.reason) == "string" and choice.reason ~= "" then
          runReason = choice.reason
        end
      end
    end
  end
  local labels = self:_menuLabels()
  local menus = self._manifest.menus --[[@as table<string, unknown>]]
  local runLabels = assert(menus.runLabelSelector, "the staged menu catalog selects the run label") --[[@as table<string, string>]]
  local entries = self._manifest.messages.entries --[[@as table<string, table<string, unknown>>]]
  local commands = {} ---@type table<integer, table<string, unknown>>
  for index, id in ipairs(self:_surfaceIds()) do
    local fact = { id = id, enabled = true } ---@type table<string, unknown>
    if id == "run" then
      fact.enabled = runEnabled
      if runReason ~= nil then
        fact.reason = runReason
      end
    end
    -- Every control carries the source label its text object prints.
    local slotKey = SURFACE_LABEL_KEYS[index]
    local labelKey = slotKey == "run" and runLabels.ordinary or labels[slotKey]
    local record = assert(entries[labelKey], "the command menu stages its source label " .. tostring(labelKey))
    fact.label = menuLabelText(record.tokens --[[@as table<integer, table<string, unknown>>]])
    commands[#commands + 1] = fact
  end
  return commands
end

---@param id string command identity under membership check
---@return boolean true when the identity belongs to the current kind surface
function BattleScreenState:_isOfferedCommand(id)
  for _, offered in ipairs(self:_surfaceIds()) do
    if offered == id then
      return true
    end
  end
  return false
end

---@param actor table<string, unknown> option actor carrying the move fragments
---@return table<integer|string, table<string, unknown>> move choices keyed by slot
local function moveChoices(actor)
  local found = {} ---@type table<integer|string, table<string, unknown>>
  if type(actor.choices) == "table" then
    for _, choice in ipairs(actor.choices) do
      if type(choice) == "table" and choice.role == "move" and type(choice.id) == "string" then
        local slot = choice.id:match("^move:(%d+)$")
        if slot ~= nil then
          found[tonumber(slot)] = choice
        elseif choice.id == "move:struggle" then
          found.struggle = choice
        end
      end
    end
  end
  return found
end

---@return table<integer, table<string, unknown>> four native move slots plus the kernel struggle entry when present
function BattleScreenState:_moves()
  local slots = {}
  local struggle = nil
  local entry = self:_actorOptions()
  if type(entry) == "table" then
    local found = moveChoices(entry)
    for slot = 0, 3 do
      if found[slot] ~= nil and slots[slot + 1] == nil then
        local choice = found[slot] --[[@as table<string, unknown>]]
        local display = choice.display --[[@as table<string, unknown>]]
        local record = {
          slot = slot,
          name = display.name,
          pp = display.pp,
          maxPp = display.maxPp,
          moveType = display.type,
          enabled = choice.enabled == true,
        } --[[@as table<string, unknown>]]
        if type(choice.reason) == "string" and choice.reason ~= "" then
          record.reason = choice.reason
        end
        slots[slot + 1] = record
      end
    end
    if found.struggle ~= nil and struggle == nil then
      local choice = found.struggle --[[@as table<string, unknown>]]
      local display = choice.display --[[@as table<string, unknown>]]
      struggle = {
        slot = 4,
        name = display.name,
        pp = 0,
        maxPp = 0,
        enabled = choice.enabled == true,
      } --[[@as table<string, unknown>]]
      if type(choice.reason) == "string" and choice.reason ~= "" then
        struggle.reason = choice.reason
      end
    end
  end
  for slot = 0, 3 do
    if slots[slot + 1] == nil then
      slots[slot + 1] = { slot = slot, enabled = false, reason = "empty" }
    end
  end
  if struggle ~= nil then
    slots[#slots + 1] = struggle
  end
  return slots
end

---@return table<string, unknown> detached public view for the current frame
function BattleScreenState:view()
  local snapshot = self:_snapshot()
  -- Displayed battlers stay player-first with only their visible
  -- facts: identities never leave this boundary, so unrevealed enemy
  -- reserves cannot leak through the detached copy.
  local battlers = {}
  for _, battler in ipairs(snapshot.battlers) do
    battlers[#battlers + 1] = {
      side = battler.side,
      hp = battler.hp,
      maxHp = battler.maxHp,
      visible = battler.visible,
    }
  end
  return {
    message = snapshot.message,
    battleKind = snapshot.battleKind,
    menuMode = snapshot.menuMode,
    menuLayoutVariant = snapshot.menuLayoutVariant,
    menuDynamicFields = copyValue(snapshot.menuDynamicFields),
    menuRevealEdge = snapshot.menuRevealEdge,
    menuWindows = copyValue(snapshot.menuWindows),
    menuInputEnabled = snapshot.menuInputEnabled,
    effectInstances = copyValue(snapshot.effectInstances),
    messageId = self._timeline:messageId(),
    selection = self._selection,
    commands = copyValue(snapshot.commands),
    moves = copyValue(snapshot.moves),
    commandIcon = copyValue(snapshot.commandIcon),
    targetGroup = copyValue(snapshot.targetGroup),
    cursorVisible = snapshot.cursorVisible,
    cursorTick = snapshot.cursorTick,
    battlers = battlers,
    openingPresentation = copyValue(snapshot.openingPresentation),
    introScene = snapshot.introScene,
    terrainSprites = snapshot.terrainSprites,
    playerTrainer = copyValue((self._pendingFinal or self._latestView or {}).playerTrainer),
    foeTrainers = copyValue((self._pendingFinal or self._latestView or {}).foeTrainers),
    actor = copyValue(snapshot.actor),
    targets = copyValue(snapshot.targetCandidates),
    staged = copyValue(snapshot.stagedChoices),
    childIntent = snapshot.childIntent,
  }
end

---@return boolean interactive true once preparation and the opening finish their cues
function BattleScreenState:_ready()
  if self._disposed or self._mode == "failed" or self._mode == "disposed" then
    return false
  end
  if self._assets:state() ~= "ready" then
    return false
  end
  if self._child ~= nil then
    return false
  end
  -- A retained terminal registration holds the ready barrier from packet
  -- acceptance through card completion: pending or active cards block,
  -- while a completed card keeps its static exit and releases the hold.
  if self._pendingRegistration ~= nil then
    return false
  end
  if self._registrationChild ~= nil and self._registrationComplete ~= true then
    return false
  end
  return self._timeline:settled()
end

---@return table<string, unknown> detached lifecycle status with the published plan
function BattleScreenState:status()
  local plan = nil
  if self._session ~= nil then
    local ok, published = pcall(self._session.plan, self._session)
    if ok then
      plan = published
    end
  end
  -- Postbattle choices open after the terminal narration and its waits settle.
  local completion = nil
  if self._completion ~= nil and self._completionResult == nil and self._outcomeDone then
    local open = self._completion --[[@as table<string, unknown>]]
    completion = {
      completionId = open.completionId,
      kind = open.kind,
      stage = open.stage,
    }
    if open.kind == "evolution" and self._completionChild ~= nil then
      local learnOf = self._completionChild.learnPrompt
      if type(learnOf) == "function" then
        local okLearn, pending = pcall(learnOf, self._completionChild)
        if okLearn and pending ~= nil then
          completion.stage = "learn"
        else
          completion.stage = "sequence"
        end
      end
    end
    if open.stage == "naming" and self._completionChild ~= nil then
      local namingText = self._completionChild.namingText
      if type(namingText) == "function" then
        local ok, staged = pcall(namingText, self._completionChild)
        if ok and type(staged) == "string" then
          completion.text = staged
        end
      end
    end
  end
  return {
    mode = self._mode,
    ready = self:_ready(),
    request = copyValue(self._request),
    presentation = plan,
    error = self._error,
    completion = completion,
  }
end

-- Opens one bound postbattle completion: capture-nickname or evolution.
-- Idempotent for the same current identity; a different, foreign,
-- consumed, or concurrent decision is refused without touching the open
-- one. The lane stays exclusive: one completion at a time.
---@param intent table<string, unknown> bound completion intent under opening
---@return boolean opened true while this screen owns the decision
function BattleScreenState:openCompletion(intent)
  if self._disposed or self._mode == "failed" then
    return false
  end
  if type(intent) ~= "table" then
    return false
  end
  if intent.launchId ~= self._launchId then
    return false
  end
  if type(intent.completionId) ~= "string" or intent.completionId == "" then
    return false
  end
  if intent.kind ~= "capture_nickname" and intent.kind ~= "evolution" then
    return false
  end
  if type(intent.subject) ~= "table" then
    return false
  end
  if intent.kind == "evolution" then
    -- The evolution lane carries its committed party slot and the full
    -- frozen trigger context beside the subject; anything less refuses
    -- instead of planning behind invented facts.
    if type(intent.partySlot) ~= "number" or type(intent.context) ~= "table" then
      return false
    end
  elseif intent.placement ~= nil then
    local placement = intent.placement --[[@as table<string, unknown>?]]
    if type(placement) ~= "table" or (placement.destination ~= "party" and placement.destination ~= "box") then
      return false
    end
    if placement.destination == "box" then
      if
        type(placement.pcHasSpace) ~= "boolean"
        or type(placement.boxName) ~= "string"
        or type(placement.previousBoxName) ~= "string"
        or type(intent.metBill) ~= "boolean"
      then
        return false
      end
    end
  end
  if self._consumedCompletions[intent.completionId] then
    return false
  end
  if self._completion ~= nil then
    return self._completion.completionId == intent.completionId
  end
  -- The completion lane never runs beside a battle-action child.
  if self._child ~= nil or self._subflows:status().active then
    return false
  end
  if intent.kind == "evolution" then
    self._completion = {
      launchId = self._launchId,
      completionId = intent.completionId,
      kind = "evolution",
      subject = copyValue(intent.subject),
      partySlot = intent.partySlot,
      context = copyValue(intent.context),
      stage = "sequence",
    }
  else
    self._completion = {
      launchId = self._launchId,
      completionId = intent.completionId,
      kind = "capture_nickname",
      subject = copyValue(intent.subject),
      placement = type(intent.placement) == "table" and copyValue(intent.placement) or nil,
      metBill = intent.metBill,
      stage = "question",
      answer = 1,
    }
  end
  self._completionChild = nil
  self._completionResult = nil
  return true
end

-- Consumes the sealed completion answer exactly once. Late answers after
-- disposal or consumption read as nothing.
---@return table<string, unknown>? bound completion answer, nil while unanswered
function BattleScreenState:takeCompletion()
  if self._disposed then
    return nil
  end
  local result = self._completionResult
  if result == nil then
    return nil
  end
  self._completionResult = nil
  if self._completionChild ~= nil then
    self._completionChild:dispose()
    self._completionChild = nil
  end
  if self._completion ~= nil then
    self._consumedCompletions[self._completion.completionId] = true
    self._completion = nil
  end
  return copyValue(result)
end

---@param result table<string, unknown> sealed completion answer under latching
function BattleScreenState:_sealCompletion(result)
  if self._completion == nil or self._completionResult ~= nil then
    return
  end
  self._completionResult = copyValue(result)
end

---@param completion table<string, unknown> answered capture completion
---@return string? source PC-transfer text, nil when the catch stayed in the party
function BattleScreenState:_pcTransferText(completion)
  local placement = completion.placement --[[@as table<string, unknown>?]]
  if type(placement) ~= "table" or placement.destination ~= "box" then
    return nil
  end
  local subject = completion.subject --[[@as table<string, unknown>]]
  local nickname = subject.nickname
  if type(nickname) ~= "string" or nickname == "" then
    local catalog = assert(self._monCatalog, "PC transfer names uncensored species through the mon catalog")
    local species = assert(subject.species, "PC transfer subjects carry their species")
    local facts = catalog:species(species --[[@as string]])
    nickname = assert(facts.name, "PC transfer species carry their localized display name")
  end
  local metBill = completion.metBill
  assert(type(metBill) == "boolean", "PC transfer narration carries the save's Bill flag")
  local pcHasSpace = placement.pcHasSpace
  assert(type(pcHasSpace) == "boolean", "PC transfer narration carries the active-box space fact")
  local boxName = placement.boxName
  assert(type(boxName) == "string", "PC transfer placement carries its destination box name")
  local owner = metBill and "bill" or "someone"
  if pcHasSpace then
    return stagedBattleText(self._manifest, "battle/pc-transfer/has-space/" .. owner, { nickname, boxName })
  end
  local previousBoxName = placement.previousBoxName
  assert(type(previousBoxName) == "string", "PC transfer placement carries the full active box name")
  return stagedBattleText(self._manifest, "battle/pc-transfer/box-full/" .. owner, {
    nickname,
    previousBoxName,
    boxName,
  })
end

---@param declined boolean true for an explicit No instead of a typed name
function BattleScreenState:_answerCompletionQuestion(declined)
  local completion = assert(self._completion, "answers bind the open completion")
  if declined then
    local transferText = self:_pcTransferText(completion)
    if transferText ~= nil then
      self._timeline:announce(transferText, false, 30)
      self._mode = "outcome"
    end
    self:_sealCompletion({
      launchId = completion.launchId,
      completionId = completion.completionId,
      kind = "declined",
    })
    return
  end
  self:_openCompletionNaming()
end

-- Resolves the native naming subject for the caught mon: a numeric
-- species passes through, a species key resolves through the borrowed mon
-- catalog, and anything else declines with the default name instead of
-- inventing a subject.
---@return table<string, unknown>? native naming subject, nil while unresolvable
function BattleScreenState:_completionNamingSubject()
  local completion = assert(self._completion, "naming resolves the open completion")
  local subject = completion.subject --[[@as table<string, unknown>]]
  if type(subject.species) == "number" then
    local naming = { kind = "pokemon", species = subject.species }
    if type(subject.form) == "number" then
      naming.form = subject.form
    end
    return naming
  end
  if type(subject.species) == "string" and self._monCatalog ~= nil then
    local catalog = assert(self._monCatalog, "naming resolves through the borrowed mon catalog")
    local ok, facts = pcall(function()
      return catalog:species(subject.species --[[@as string]])
    end)
    if ok and type(facts) == "table" and type(facts.nativeId) == "number" then
      local naming = { kind = "pokemon", species = facts.nativeId }
      if type(subject.form) == "number" then
        naming.form = subject.form
      end
      return naming
    end
  end
  return nil
end

-- Opens the native naming controller for the open completion with its
-- actual caught subject. An unresolvable subject declines with the
-- default name so the committed catch survives.
function BattleScreenState:_openCompletionNaming()
  local completion = assert(self._completion, "naming opens for the open completion")
  local namingSubject = self:_completionNamingSubject()
  if namingSubject == nil then
    self:_answerCompletionQuestion(true)
    return
  end
  local terminal = self._terminalRequest or { requestId = 0, epoch = 0, controller = "player" }
  local child, childErr = BattleChildApplications.open({
    kind = "naming",
    purpose = "nickname",
    launchId = self._launchId,
    requestId = terminal.requestId,
    epoch = terminal.epoch,
    controller = terminal.controller,
    cancellable = true,
    subject = namingSubject,
  }, {})
  if child == nil then
    self._mode = "failed"
    self._error = "capture naming failed for launch " .. self._launchId .. ": " .. tostring(childErr)
    return
  end
  self._completionChild = child
  completion.stage = "naming"
end

-- Opens the native evolution controller for the open completion with
-- its committed subject, party slot, and full frozen trigger context.
-- A composition failure fails the screen loudly so the committed
-- battle result survives instead of skipping a mandatory evolution.
function BattleScreenState:_openCompletionEvolution()
  local completion = assert(self._completion, "evolution opens for the open completion")
  local terminal = self._terminalRequest or { requestId = 0, epoch = 0, controller = "player" }
  local child, childErr = BattleChildApplications.open({
    kind = "evolution",
    purpose = "evolution",
    launchId = self._launchId,
    requestId = terminal.requestId,
    epoch = terminal.epoch,
    controller = terminal.controller,
    cancellable = true,
    subject = copyValue(completion.subject),
    partySlot = completion.partySlot,
    context = copyValue(completion.context),
  }, { monCatalog = self._monCatalog })
  if child == nil then
    self._mode = "failed"
    self._error = "postbattle evolution failed for launch " .. self._launchId .. ": " .. tostring(childErr)
    return
  end
  self._completionChild = child
  completion.stage = "sequence"
  -- Edges that arrived before composition replay exactly once in order.
  -- Replay still meets only its own window: a cancel replayed into the
  -- entry beat decides nothing, so the holder presses again once the
  -- transformation beat opens.
  local pending = completion.pendingInput
  completion.pendingInput = nil
  if type(pending) == "table" then
    for _, event in ipairs(pending) do
      if type(event) == "table" then
        local ok, inputErr = pcall(function()
          child:input({ event })
        end)
        if not ok then
          self._mode = "failed"
          self._error = "postbattle evolution failed for launch " .. self._launchId .. ": " .. tostring(inputErr)
          return
        end
      end
    end
  end
end

-- Routes one mapped semantic input to the open evolution lane. The
-- sequence owns confirm, cancel, and navigate ahead of the battle
-- handlers: confirmation never gates the beats, cancellation decides
-- only where the source method permits it, and navigation steers the
-- pending learned-move picker. Anything the lane refuses falls through.
---@param event table<string, unknown> mapped semantic input under routing
---@return boolean consumed true while the evolution lane owned the input
function BattleScreenState:_consumeEvolutionCompletion(event)
  local completion = assert(self._completion, "evolution input binds the open completion")
  if
    event.type ~= "confirm"
    and event.type ~= "cancel"
    and event.type ~= "navigate"
    and event.type ~= "pointer_cancel"
  then
    return false
  end
  local child = self._completionChild
  if child == nil then
    -- The lane owns its edges even before the controller composes on
    -- the next drain: buffer the edge for exactly-once replay at
    -- composition so a held button neither leaks into the battle
    -- handlers nor misses the animation window behind it.
    local buffered = completion.pendingInput
    if buffered == nil then
      buffered = {}
      completion.pendingInput = buffered
    end
    if #buffered < 8 then
      buffered[#buffered + 1] = event
    end
    return true
  end
  local _ = completion
  local ok, inputErr = pcall(function()
    child:input({ event })
  end)
  if not ok then
    self._mode = "failed"
    self._error = "postbattle evolution failed for launch " .. self._launchId .. ": " .. tostring(inputErr)
  end
  return true
end

-- Advances the open evolution lane once: the native child steps its
-- presentation clock and its sealed typed answer translates into the
-- bound completion identity. The typed answer never enters the action
-- reply parser or the battle-action child poll.
---@param completion table<string, unknown> open evolution completion under advancing
function BattleScreenState:_drainEvolutionCompletion(completion)
  if not self._outcomeDone then
    return
  end
  if self._completionChild == nil then
    self:_openCompletionEvolution()
    if self._completionChild == nil then
      return
    end
  end
  local child = assert(self._completionChild, "evolution drains its open child")
  local okStep, stepErr = pcall(function()
    child:stepSourceTick(1)
  end)
  if not okStep then
    self._mode = "failed"
    self._error = "postbattle evolution failed for launch " .. self._launchId .. ": " .. tostring(stepErr)
    return
  end
  local promptOf = child.learnPrompt
  if type(promptOf) == "function" then
    local okPrompt, pending = pcall(promptOf, child)
    if okPrompt and pending ~= nil then
      completion.stage = "learn"
    else
      completion.stage = "sequence"
    end
  end
  local okTake, result = pcall(function()
    return child:takeResult()
  end)
  if not okTake then
    self._mode = "failed"
    self._error = "postbattle evolution failed for launch " .. self._launchId .. ": " .. tostring(result)
    return
  end
  if result == nil then
    return
  end
  if result.kind == "evolution_complete" then
    self:_sealCompletion({
      launchId = completion.launchId,
      completionId = completion.completionId,
      kind = "evolution_complete",
      staged = copyValue(result.staged),
    })
    return
  end
  if result.kind == "evolution_cancelled" then
    self:_sealCompletion({
      launchId = completion.launchId,
      completionId = completion.completionId,
      kind = "evolution_cancelled",
      reason = result.reason,
    })
  end
end

-- Routes one mapped semantic input to the open completion. The question
-- answers Yes on confirm, toggles on navigate, and declines on cancel;
-- the naming lane forwards its semantic edges to the native controller.
-- Every other input falls through to the battle handlers.
---@param event table<string, unknown> mapped semantic input under routing
---@return boolean consumed true while the completion owned the input
function BattleScreenState:_consumeCompletion(event)
  local completion = self._completion
  if completion == nil or self._completionResult ~= nil then
    return false
  end
  -- Postbattle choices run after the terminal narration and its waits settle.
  if not self._outcomeDone then
    return false
  end
  if completion.kind == "evolution" then
    return self:_consumeEvolutionCompletion(event)
  end
  if completion.stage == "question" then
    if event.type == "navigate" then
      completion.answer = completion.answer == 1 and 2 or 1
      return true
    end
    if event.type == "confirm" then
      self:_answerCompletionQuestion(completion.answer ~= 1)
      return true
    end
    if event.type == "cancel" then
      self:_answerCompletionQuestion(true)
      return true
    end
    return false
  end
  local child = self._completionChild
  if child == nil then
    return false
  end
  if
    event.type == "confirm"
    or event.type == "cancel"
    or event.type == "navigate"
    or event.type == "text"
    or event.type == "name_cell"
    or event.type == "name_control"
    or event.type == "pointer_cancel"
  then
    child:input({ event })
    return true
  end
  return false
end

-- Advances the open completion once: the native naming child steps its
-- presentation clock and its sealed native answer translates into the
-- bound completion identity. The typed answer never enters the action
-- reply parser.
function BattleScreenState:_drainCompletion()
  local completion = self._completion
  if completion == nil or self._completionResult ~= nil then
    return
  end
  if completion.kind == "evolution" then
    self:_drainEvolutionCompletion(completion)
    return
  end
  if completion.stage ~= "naming" then
    return
  end
  local child = self._completionChild
  if child == nil then
    return
  end
  child:stepSourceTick(1)
  local result = child:takeResult()
  if result == nil then
    return
  end
  if result.kind == "cancelled" then
    self:_sealCompletion({
      launchId = completion.launchId,
      completionId = completion.completionId,
      kind = "declined",
    })
    return
  end
  if result.kind == "choice" and type(result.choice) == "table" and type(result.choice.text) == "string" then
    self:_sealCompletion({
      launchId = completion.launchId,
      completionId = completion.completionId,
      kind = "named",
      nickname = result.choice.text,
    })
  end
end

---@param current table<string, unknown>? action child view under projection
---@return table<string, unknown>? action child view with the completion question, naming, or evolution state
function BattleScreenState:_completionChildView(current)
  local completion = self._completion
  if completion == nil or not self._outcomeDone then
    return current
  end
  if completion.kind == "evolution" then
    local child = self._completionChild
    if child == nil then
      return {
        kind = "evolution",
        purpose = "evolution",
        interactive = false,
        cancellable = false,
        application = "evolution",
        phase = "sequence",
      } --[[@as table<string, unknown>]]
    end
    local inner = child:status()
    assert(type(inner) == "table", "the evolution child reports its status")
    return {
      kind = "evolution",
      purpose = "evolution",
      interactive = true,
      cancellable = inner.canCancel == true,
      application = "evolution",
      phase = inner.phase,
      learn = child:learnPrompt(),
    } --[[@as table<string, unknown>]]
  end
  if completion.stage == "question" then
    local view = {
      kind = "naming",
      purpose = "nickname",
      interactive = true,
      cancellable = true,
      rows = {
        { id = "yes", label = "Yes", detail = "", enabled = true },
        { id = "no", label = "No", detail = "", enabled = true },
      },
      focusId = completion.answer == 1 and "yes" or "no",
      prompt = completionQuestionText(
        self._manifest,
        self._monCatalog,
        completion.subject --[[@as table<string, unknown>]]
      ),
      application = "naming",
    } --[[@as table<string, unknown>]]
    local menus = self._manifest.menus
    local routes = type(menus) == "table" and menus.routes or nil
    local messages = self._manifest.messages
    local entries = type(messages) == "table" and messages.entries or nil
    local route = type(routes) == "table" and routes["menu/yes-no"] or nil
    if type(route) == "table" and type(entries) == "table" then
      local top = entries["label/yes"]
      local bottom = entries["label/no"]
      if type(top) == "table" and type(bottom) == "table" then
        view.twoOption = {
          route = "menu/yes-no",
          top = menuLabelText(top.tokens --[[@as table<integer, table<string, unknown>>]]),
          bottom = menuLabelText(bottom.tokens --[[@as table<integer, table<string, unknown>>]]),
        }
      end
    end
    return view
  end
  local child = self._completionChild
  if child == nil then
    return current
  end
  local text = ""
  local namingText = child.namingText
  if type(namingText) == "function" then
    local ok, staged = pcall(namingText, child)
    if ok and type(staged) == "string" then
      text = staged
    end
  end
  return {
    kind = "naming",
    purpose = "nickname",
    interactive = true,
    cancellable = true,
    rows = {},
    focusId = nil,
    text = text,
    application = "naming",
  } --[[@as table<string, unknown>]]
end

---@return table<string, fun(...)> seven closure operations sharing one idempotent release guard
function BattleScreenState:presentationPort()
  local screen = self
  ---@param plan table<string, unknown> runtime entry plan carrying the launch kind
  ---@return boolean acknowledged true once required resources resolve
  local function portEnter(plan)
    return screen:_portEnter(plan)
  end
  ---@param packet table<string, unknown> detached delivery packet
  local function portPresent(packet)
    screen:_portPresent(packet)
  end
  ---@return boolean interactive true once preparation and the opening finish their cues
  local function portReady()
    return screen:_ready()
  end
  ---@param plan table<string, unknown> runtime return plan
  ---@return boolean acknowledged true once the terminal narration is shown
  local function portLeave(plan)
    return screen:_portLeave(plan)
  end
  local function portDispose()
    screen:dispose()
  end
  ---@param intent table<string, unknown> bound capture-nickname completion under opening
  ---@return boolean opened true while the screen owns the decision
  local function portOpenCompletion(intent)
    return screen:openCompletion(intent)
  end
  ---@return table<string, unknown>? one-shot bound completion answer, nil while unanswered
  local function portTakeCompletion()
    return screen:takeCompletion()
  end
  return {
    enter = portEnter,
    present = portPresent,
    ready = portReady,
    leave = portLeave,
    dispose = portDispose,
    openCompletion = portOpenCompletion,
    takeCompletion = portTakeCompletion,
  }
end

---@param plan table<string, unknown> runtime entry plan carrying the launch kind
---@return boolean acknowledged true once required resources resolve
function BattleScreenState:_portEnter(plan)
  if self._disposed or self._mode == "failed" then
    return false
  end
  if type(plan) == "table" and type(plan.kind) == "string" then
    self._kind = plan.kind --[[@as string]]
  end
  return self._assets:state() == "ready"
end

---@param view table<string, unknown> detached after view carrying portrait facts
---@return string[] sorted canonical portrait selectors for the demand
local function selectorsOf(view)
  -- Demands name exact canonical selectors only: the active own lead
  -- (and ally in doubles) plus every currently revealed foe. Only an
  -- explicitly benched reserve stays undemanded until a later packet
  -- makes it active; records predating the active flag read as active,
  -- matching the displayed lead. Unrevealed foe reserves never enter
  -- the view, so they stay undemanded until they actually arrive.
  local selectors = {}
  local seen = {}
  -- Shiny state rides the picture demand key: a shiny battler demands
  -- its shiny-variant selector even when it shares the plain canonical
  -- selector, so plain and shiny pictures never collapse onto one
  -- image. Non-shiny records demand their selector verbatim.
  local function demandKey(record, selector)
    if record.shiny == true then
      local species, form, gender, variant, facing = selector:match("^([^/]+)/([^/]+)/([^/]+)/([^/]+)/([^/]+)$")
      if species ~= nil and variant == "plain" then
        return species .. "/" .. form .. "/" .. gender .. "/shiny/" .. facing
      end
    end
    return selector
  end
  local function add(record, activeOnly)
    if type(record) ~= "table" then
      return
    end
    if activeOnly and record.active == false then
      return
    end
    local selector = record.portraitSelector
    if type(selector) == "string" and selector ~= "" then
      local key = demandKey(record, selector)
      if not seen[key] then
        seen[key] = true
        selectors[#selectors + 1] = key
      end
    end
  end
  if type(view.own) == "table" then
    for _, record in ipairs(view.own) do
      add(record, true)
    end
  end
  if type(view.foes) == "table" then
    for _, record in ipairs(view.foes) do
      add(record, false)
    end
  end
  table.sort(selectors)
  return selectors
end

---@param packet table<string, unknown> detached delivery packet
function BattleScreenState:_portPresent(packet)
  if self._disposed or self._mode == "failed" then
    return
  end
  if type(packet) ~= "table" or packet.launchId ~= self._launchId then
    return
  end
  if type(packet.packetId) ~= "number" then
    self._mode = "failed"
    self._error = "malformed battle packet for launch " .. self._launchId
    return
  end
  if not self._introBuilt then
    -- The first delivery installs the opening facts and queues the
    -- introduction before its events translate, so the accepted event
    -- cues play behind the opening instead of being reset away.
    local opening = packet.before
    if type(opening) ~= "table" then
      opening = packet.after
    end
    if type(opening) == "table" then
      self._timeline:reset(opening)
      self._timeline:intro(opening, self._kind ~= "trainer")
      self._introBuilt = true
      if self._mode == "preparing" then
        self._mode = "intro"
      end
    end
  end
  if not self._nativeRouting and type(packet.events) == "table" then
    -- No effect staging callbacks means no native occurrences: present
    -- the established generic cues by withholding the source effect
    -- routing fact. Narration, checkpoints, and packet identity read
    -- nothing else from the withheld key, so the generic path is
    -- exact. The delivery packet itself is never mutated.
    local generic = nil
    for index, event in ipairs(packet.events) do
      if type(event) == "table" and event.effectKey ~= nil then
        if generic == nil then
          generic = {}
          for position, entry in ipairs(packet.events) do
            generic[position] = entry
          end
        end
        local detached = copyValue(event) --[[@as table<string, unknown>]]
        detached.effectKey = nil
        generic[index] = detached
      end
    end
    if generic ~= nil then
      local routed = {}
      for field, value in pairs(packet) do
        routed[field] = value
      end
      routed.events = generic
      packet = routed --[[@as table<string, unknown>]]
    end
  end
  local sourceMessages = {}
  for _, event in ipairs(packet.events or {}) do
    local payload = type(event) == "table" and event.payload or nil
    local cause = type(event) == "table" and event.cause or nil
    if
      type(event) == "table"
      and event.kind == "move-used"
      and type(payload) == "table"
      and payload.phase == "release"
      and type(cause) == "table"
      and cause.key == "BIDE"
    then
      local args = assert(event.messageArgs, "Bide release requires named message arguments")
      local name = assert(args.userName, "Bide release names its battler")
      assert(type(name) == "string", "Bide release battler name is text")
      -- TAG_NICKNAME selects msg_0197_00335 + 1 for an enemy battler and
      -- + 2 against a trainer.
      local actors = event.actors --[[@as table<integer, table<string, unknown>>?]]
      local user = type(actors) == "table" and type(actors[1]) == "table" and actors[1].combatant or cause.combatant
      local key = "battle/bide-release"
      for _, view in ipairs({ packet.before, packet.after }) do
        if type(view) == "table" and type(view.foes) == "table" then
          for _, foe in ipairs(view.foes) do
            if type(foe) == "table" and foe.combatant == user then
              key = foe.controller == "wild" and "battle/bide-release/wild" or "battle/bide-release/foe"
            end
          end
        end
      end
      sourceMessages[
        event.sequence --[[@as integer]]
      ] = stagedBattleText(self._manifest, key, { name })
    elseif type(event) == "table" and event.kind == "broke_free" then
      local args = event.messageArgs --[[@as table<string, unknown>?]]
      local shakes = type(args) == "table" and args.shakes or nil
      local messages = assert(self._manifest.messages, "capture outcomes require staged messages") --[[@as table<string, unknown>]]
      local dynamicRoutes = messages.dynamicRoutes
      local route = type(dynamicRoutes) == "table" and dynamicRoutes.captureShake or nil
      assert(type(route) == "table", "capture outcomes require the staged source message route")
      local minimum = route.minimum --[[@as integer]]
      local maximum = route.maximum --[[@as integer]]
      assert(
        type(shakes) == "number" and shakes % 1 == 0 and shakes >= minimum and shakes <= maximum,
        "capture message selection uses the typed shake count"
      )
      local firstRecord = route.firstRecord --[[@as string]]
      local messageKey = firstRecord:gsub("0$", tostring(shakes))
      sourceMessages[
        event.sequence --[[@as integer]]
      ] =
        stagedBattleText(self._manifest, messageKey, {})
    end
  end
  if not self._timeline:present(packet, sourceMessages) then
    return
  end
  if next(sourceMessages) ~= nil then
    self._showTimelineMessage = true
  end
  if type(packet.after) == "table" then
    self._latestView = packet.after
  end
  -- Both provenances disclose before their requiresImage cues proceed:
  -- the incoming battler arrives in after, the departing one stays
  -- named in before, and benched reserves appear in neither until a
  -- packet makes them active. Either provenance may be absent on the
  -- opening delivery, so absent views are skipped without ending the
  -- scan: a literal with a nil first element would stop the traversal
  -- before the present view.
  local provenances = {} ---@type table<integer, table<string, unknown>>
  if type(packet.before) == "table" then
    provenances[#provenances + 1] = packet.before --[[@as table<string, unknown>]]
  end
  if type(packet.after) == "table" then
    provenances[#provenances + 1] = packet.after --[[@as table<string, unknown>]]
  end
  do
    local demanded, seen = {}, {} ---@type string[], table<string, boolean>
    for _, view in ipairs(provenances) do
      for _, selector in ipairs(selectorsOf(view)) do
        if not seen[selector] then
          seen[selector] = true
          demanded[#demanded + 1] = selector
        end
      end
    end
    self._assets:addSelectors(demanded)
  end
  for _, view in ipairs(provenances) do
    if self._lastPlayerName == nil and type(view.playerName) == "string" then
      self._lastPlayerName = view.playerName --[[@as string]]
    end
    if type(view.foes) == "table" then
      for _, foe in ipairs(view.foes) do
        if type(foe) == "table" and type(foe.name) == "string" and self._lastFoeName == nil then
          self._lastFoeName = foe.name --[[@as string]]
        end
      end
    end
  end
  if packet.request ~= nil then
    self._pendingRequest = copyValue(packet.request)
  end
  if packet.result ~= nil then
    self._pendingResult = copyValue(packet.result)
    if packet.result.word == "flee" then
      for _, event in ipairs(packet.events or {}) do
        local payload = type(event) == "table" and event.payload or nil
        if type(event) == "table" and event.kind == "flee" and type(payload) == "table" and payload.escaped == true then
          local source = payload.escapeSource
          if source ~= nil then
            self._pendingResult.escapeSource = copyValue(source)
            local args = event.messageArgs --[[@as table<string, unknown>?]]
            self._pendingResult.escapeName = type(args) == "table" and args.combatantName or nil
          end
          break
        end
      end
    end
    self._outcomeMessages = nil
    local registration = packet.result.registration --[[@as table<string, unknown>?]]
    if type(registration) == "table" then
      self._pendingRegistration = copyValue(registration)
    end
  end
  if type(packet.party) == "table" then
    self._partySnapshot = copyValue(packet.party)
  end
  if type(packet.inventory) == "table" then
    self._inventorySnapshot = copyValue(packet.inventory)
  end
  self._pendingFinal = copyValue(packet.after)
end

---@param plan table<string, unknown> runtime return plan
---@return boolean acknowledged true once the terminal narration is shown
function BattleScreenState:_portLeave(plan)
  local _ = plan
  if self._disposed or self._mode == "failed" then
    return false
  end
  if
    not self._outcomeDone
    and self._kind == "trainer"
    and self._pendingResult ~= nil
    and self._outcomeMessages ~= nil
    and #self._outcomeMessages == 0
    and self._timeline:settled()
  then
    self:_drain(true)
  end
  -- Terminal source waits drain on their own; leave follows the last page
  -- and any registration card without an outcome acknowledgment gate.
  if
    self._outcomeDone
    and self._timeline:settled()
    and self._pendingRegistration == nil
    and (self._registrationChild == nil or self._registrationComplete == true)
  then
    return true
  end
  return false
end

-- Queues one raw input batch. Batches map through the published plan on
-- the next fixed update; after disposal every batch is dropped.
---@param events table<integer, table<string, unknown>> semantic input batch
function BattleScreenState:input(events)
  if self._disposed then
    return
  end
  assert(type(events) == "table", "battle input arrives as an event list")
  for _, event in ipairs(events) do
    assert(type(event) == "table" and type(event.type) == "string", "battle events need a type")
  end
  -- Pointer and key edges act through the published plan immediately
  -- so pressed art follows the press without waiting for the next
  -- tick; clocks still advance only on fixed updates. After disposal
  -- every batch is dropped.
  if self._session == nil or self._mode == "failed" then
    return
  end
  local measurement = self._measureDisplay()
  if measurement ~= nil then
    local signature = measurement.signature
    if signature ~= nil and signature ~= self._signature then
      self:cancelPointerCapture()
      self._signature = signature
    end
    -- An open registration card owns its input exclusively: the raw host
    -- batch routes straight to the child, never through the stale battle
    -- plan. Layout remeasure and pointer cancellation above still apply.
    if self._registrationChild ~= nil then
      local card = self._registrationChild --[[@as table<string, unknown>]]
      local takeInput = card.input --[[@as fun(self: table<string, unknown>, events: table<integer, table<string, unknown>>)?]]
      if type(takeInput) == "function" then
        takeInput(card, events)
      end
      return
    end
    pcall(function()
      self._session:resolve(measurement, self:_snapshot())
    end)
    -- Non-pointer semantic edges pass the published plan untouched, so
    -- the completion lane owns its text and naming edges behind the
    -- same contract the action children use.
    local converted = self._session:mapInput(events, self:_snapshot())
    for _, event in ipairs(converted) do
      self:_consume(event)
      -- Constructing the card consumes its creating edge and drops the
      -- rest of the batch so no stale choice seals behind it.
      if self._registrationChild ~= nil then
        break
      end
    end
    pcall(function()
      self._session:resolve(measurement, self:_snapshot())
    end)
  end
end

-- Cancels a held press through both owners so a stale release never
-- activates after remeasure, submission, or disposal.
function BattleScreenState:cancelPointerCapture()
  if self._session ~= nil then
    local ok = pcall(self._session.cancelPointers, self._session)
    local _ = ok
  end
  self._armed = nil
  self._buttonFeedback = nil
  if self._registrationChild ~= nil then
    pcall(self._registrationChild.cancelPointerCapture, self._registrationChild)
  end
  if self._subflows ~= nil then
    self._subflows:cancelPointerCapture()
  end
end

---@param armed table<string, unknown>? pressed control awaiting release
---@param control table<string, unknown>? activated control under sealing
---@param pointerId string? identity of the pointer edge
---@return boolean sealed
local function sameControl(armed, control, pointerId)
  return armed ~= nil
    and control ~= nil
    and armed.scope == control.scope
    and armed.id == control.id
    and armed.pointerId == pointerId
end

---@param scope unknown control scope under validation
---@param id unknown control identity under validation
---@return boolean known true when the native menu declares the control
local function knownMenuControl(scope, id)
  if type(scope) ~= "string" or type(id) ~= "string" then
    return false
  end
  local regions = BattleMenuRegions.forLayout(scope)
  if regions == nil then
    return false
  end
  for _, region in ipairs(regions) do
    if region.id == id then
      return true
    end
  end
  return false
end

---@param reason string? supplied refusal reason under display
function BattleScreenState:_refuse(reason)
  if type(reason) == "string" and reason ~= "" then
    self._notice = reason
  else
    self._notice = "That choice is unavailable."
  end
end

---@param role string fragment role under lookup for the acting entry
---@return table<string, unknown>? prepared choice fragment, nil when absent or refused
function BattleScreenState:_fragmentFor(role)
  local entry = self:_actorOptions()
  if type(entry) ~= "table" or type(entry.choices) ~= "table" then
    return nil
  end
  for _, choice in ipairs(entry.choices) do
    if type(choice) == "table" and choice.role == role and choice.enabled == true then
      return choice.choice --[[@as table<string, unknown>]]
    end
  end
  return nil
end

---@param id string move fragment identity under lookup for the acting entry
---@return table<string, unknown>? prepared move option with its enabled flag
function BattleScreenState:_moveEntry(id)
  local entry = self:_actorOptions()
  if type(entry) ~= "table" or type(entry.choices) ~= "table" then
    return nil
  end
  for _, choice in ipairs(entry.choices) do
    if type(choice) == "table" and choice.id == id then
      return choice
    end
  end
  return nil
end

-- Names one typed cue for failure context and legacy string sinks.
---@param cue table<string, unknown>|string typed sound cue under dispatch
---@return string role name behind failure context
local function cueRole(cue)
  if type(cue) == "string" then
    return cue
  end
  if cue.kind == "select" then
    return "select"
  end
  if cue.kind == "effect" then
    return tostring(cue.symbol)
  end
  if cue.kind == "fanfare" then
    return tostring(cue.symbol)
  end
  if cue.kind == "cry" then
    return "cry:" .. tostring(cue.species)
  end
  return tostring(cue.kind)
end

-- Resolves the staged interface symbol behind menu feedback.
---@return string staged select symbol
function BattleScreenState:_selectSymbol()
  local manifest = self._manifest --[[@as table<string, unknown>]]
  local audioRoles = type(manifest) == "table" and manifest.audioRoles or nil
  assert(type(audioRoles) == "table", "battle sound needs its staged select role for launch " .. self._launchId)
  local symbol = audioRoles.select
  assert(
    type(symbol) == "string" and symbol ~= "",
    "battle sound needs its staged select role for launch " .. self._launchId
  )
  return symbol --[[@as string]]
end

-- Resolves one cry cue to its numeric species identity: the borrowed
-- mon catalog names the cry, never a guessed integer.
---@param cue table<string, unknown> typed cry cue under resolution
---@return integer numeric species identity behind the cry voice
function BattleScreenState:_crySpecies(cue)
  local speciesKey = cue.species
  assert(
    type(speciesKey) == "string" and speciesKey ~= "",
    "battle cries name their species for launch " .. self._launchId
  )
  local catalog = self._monCatalog
  assert(catalog ~= nil, "battle cries need their mon catalog for launch " .. self._launchId)
  local facts = catalog:species(speciesKey)
  assert(
    type(facts) == "table" and type(facts.nativeId) == "number",
    "battle cries name a cataloged species for launch " .. self._launchId .. ": cry:" .. tostring(speciesKey)
  )
  return facts.nativeId --[[@as integer]]
end

-- Dispatches one typed cue through the launch voice operations. A
-- rejected cue fails the launch once with launch and role context; the
-- envelope then reports the failed screen and later ticks replay
-- nothing because the timeline queue already drained exactly once.
-- Sinks without a cry port voice the legacy string roles directly.
---@param cue table<string, unknown>|string typed sound cue under dispatch
---@return boolean played true when the sink accepted the cue
function BattleScreenState:_playCue(cue)
  local role = cueRole(cue)
  local ok, err = pcall(function()
    if type(cue) == "string" then
      if cue == "select" then
        self._battleAudio:playEffect(self:_selectSymbol())
      else
        error("unknown battle sound role for launch " .. self._launchId .. ": " .. tostring(cue), 0)
      end
      return
    end
    if cue.kind == "select" then
      self._battleAudio:playEffect(self:_selectSymbol())
    elseif cue.kind == "effect" then
      assert(type(cue.symbol) == "string" and cue.symbol ~= "", "effect cues name their staged symbol")
      -- Legacy string-role sinks carry no mix; they voice the role alone.
      local pan = not self._legacyAudio and cue.pan or nil
      local handle = self._battleAudio:playEffect(cue.symbol --[[@as string]], pan --[[@as integer?]])
      if type(cue.voiceKey) == "string" then
        self._nativeVoices[cue.voiceKey] = handle
      end
    elseif cue.kind == "stop-effect" then
      local voiceKey = assert(cue.voiceKey, "effect stops name their started voice") --[[@as string]]
      local handle = assert(self._nativeVoices[voiceKey], "effect stops own a started voice")
      self._battleAudio:stopVoice(handle)
      self._nativeVoices[voiceKey] = nil
    elseif cue.kind == "fanfare" then
      assert(type(cue.symbol) == "string" and cue.symbol ~= "", "fanfare cues name their staged symbol")
      local handle = self._battleAudio:playFanfare(cue.symbol --[[@as string]])
      if cue.waitForVoice == true then
        self._waitingCueVoice = handle
      end
    elseif cue.kind == "music" then
      self:_notifyResultMusic("win")
    elseif cue.kind == "cry" then
      self:_playCryCue(cue --[[@as table<string, unknown>]])
    else
      error("unknown battle sound role for launch " .. self._launchId .. ": " .. tostring(role), 0)
    end
  end)
  if ok then
    return true
  end
  if self._mode ~= "failed" then
    self._mode = "failed"
    self._error = "battle sound failed for launch " .. self._launchId .. ": role " .. role .. ": " .. tostring(err)
  end
  return false
end

-- Voices one send-out cry through the launch operations: the plain
-- pattern over the view-carried form, panned by side at the subsystem
-- primary volume. Sinks without a cry port voice the legacy string
-- role instead so headless recording boundaries keep their shape.
---@param cue table<string, unknown> typed cry cue under dispatch
function BattleScreenState:_playCryCue(cue)
  local speciesKey = type(cue.species) == "string" and cue.species or nil
  assert(speciesKey ~= nil, "cry cues name their view species")
  if self._legacyAudio then
    self._battleAudio:playEffect("cry:" .. speciesKey --[[@as string]])
    return
  end
  local species = self:_crySpecies(cue)
  local form = cue.form
  if type(form) ~= "number" or form % 1 ~= 0 or form < 0 then
    form = 0
  end
  local pan = BattleAudio.SIDE_PAN.player
  if cue.foe == true then
    pan = BattleAudio.SIDE_PAN.foe
  end
  local defaults = BattleAudio.DEFAULT_CRY
  local pattern = cue.pattern
  if type(pattern) ~= "number" then
    pattern = defaults.pattern
  end
  local handle = self._battleAudio:playCry({
    species = species,
    speciesKey = speciesKey,
    pattern = pattern,
    form = form,
    mode = defaults.mode,
    pan = pan,
    volume = defaults.volume,
    pitch = defaults.pitch,
  })
  if cue.waitForVoice == true then
    self._waitingCueVoice = handle
  end
end

---@param cue table<string, unknown> active held audio cue
---@return boolean complete true once its owned voice finishes
function BattleScreenState:_soundCueComplete(cue)
  if cue.waitForVoice ~= true or self._legacyAudio then
    return true
  end
  local handle = self._waitingCueVoice
  if handle == nil then
    return false
  end
  local ok, done = pcall(function()
    return self._battleAudio:voiceComplete(handle)
  end)
  if ok and done == true then
    self._waitingCueVoice = nil
    return true
  end
  return false
end

-- Records one menu-cancel feedback voice behind the backing-out edge.
function BattleScreenState:_playCancelFeedback()
  self:_playCue({ kind = "effect", symbol = BattleAudio.SINK_SOUNDS.slide })
end

---@param fragment table<string, unknown> prepared choice fragment under staging
function BattleScreenState:_seal(fragment)
  assert(self._request ~= nil and self._options ~= nil, "replies answer the open request")
  local actors = assert(self._request.actors, "the open request addresses its actors")
  local addressed = assert(actors[self._actorIndex], "staged fragments answer the acting entry")
  local actor = assert(fragment.actor, "staged fragments address their entry")
  assert(
    actor.combatant == addressed.combatant and actor.activation == addressed.activation,
    "staged fragments answer the acting entry"
  )
  -- Staging never reaches the kernel: the fragment waits with the staged
  -- choices until every addressed entry holds its own choice.
  self._staged[self._actorIndex] = copyValue(fragment)
  self._lastStaged = self._actorIndex
  self._notice = nil
  local pending = nil
  for index in ipairs(actors) do
    if self._staged[index] == nil then
      pending = index
      break
    end
  end
  if pending == nil then
    self:_submitStaged()
    return
  end
  self._actorIndex = pending
  self:_enterActorPrompt()
end

-- Submits the completed staged choices once in kernel request order. A refusal
-- keeps the request and every staged fragment on screen and returns
-- the cursor to the latest staged entry for correction; only an
-- accepted reply clears the staged choices and waits for resolution.
function BattleScreenState:_submitStaged()
  local request = assert(self._request, "completed staged choices answer the open request")
  local actors = assert(request.actors, "the open request addresses its actors")
  local choices = {}
  for index, addressed in ipairs(actors) do
    local fragment = assert(self._staged[index], "complete replies need every requested actor")
    local actor = assert(fragment.actor, "staged fragments address their entry")
    assert(actor.combatant == addressed.combatant)
    assert(actor.activation == addressed.activation)
    choices[index] = copyValue(fragment)
  end
  local reply = {
    requestId = request.requestId,
    epoch = request.epoch,
    controller = request.controller,
    choices = choices,
  }
  local ok, accepted, failure = pcall(self._submit, reply)
  if not ok then
    self._mode = "failed"
    self._error = "battle submission failed for launch " .. self._launchId .. ": " .. tostring(accepted)
    return
  end
  if accepted ~= true then
    local reason = nil
    if type(failure) == "table" then
      reason = failure.message or failure.reason
    end
    self:_refuse(type(reason) == "string" and reason or nil)
    if type(self._lastStaged) == "number" then
      self._actorIndex = self._lastStaged
    end
    self:_enterActorPrompt()
    return
  end
  self._notice = nil
  -- The answered request is no longer open; its options stay cached
  -- for display until the next delivery replaces them.
  self._request = nil
  self._staged = {}
  self._lastStaged = nil
  self._actorIndex = 1
  self._targetCandidates = nil
  self._pendingMoveId = nil
  self._mode = "awaiting_resolution"
  self:cancelPointerCapture()
  self:_playCue("select")
end

-- Names the acting combatant behind per-battler cursor memory: the
-- native cursor position is saved per battler, not per screen.
---@return integer? acting combatant, nil without an open request
function BattleScreenState:_actingCombatant()
  if self._request == nil or type(self._request.actors) ~= "table" then
    return nil
  end
  local addressed = self._request.actors[self._actorIndex]
  if type(addressed) == "table" and type(addressed.combatant) == "number" then
    return addressed.combatant
  end
  return nil
end

-- Maps one ordinary command slot to the launch kind surface identity.
---@param slot string ordinary command slot behind the cursor cell
---@return string? offered surface identity, nil while the kind hides the slot
function BattleScreenState:_surfaceCommand(slot)
  local ids = self:_surfaceIds()
  for index, key in ipairs(SURFACE_LABEL_KEYS) do
    if key == slot then
      local id = ids[index]
      if type(id) == "string" and self:_isOfferedCommand(id) then
        return id
      end
      return nil
    end
  end
  return nil
end

-- Syncs the keypad cursor cell to one offered command identity without
-- saving: presses move the cell while only the accepted choice
-- remembers it, like the native touch/keypad split.
---@param id string offered command identity under syncing
function BattleScreenState:_syncCommandCursor(id)
  local ids = self:_surfaceIds()
  for index, offered in ipairs(ids) do
    if offered == id then
      local slot = SURFACE_LABEL_KEYS[index]
      local cell = slot ~= nil and COMMAND_SLOT_CELLS[slot] or nil
      if cell ~= nil then
        self._commandX, self._commandY = cell.x, cell.y
      end
      return
    end
  end
end

-- Restores the acting entry's remembered main-menu cursor: the saved
-- per-combatant cell while it still names an offered command, else the
-- first surface slot. Matches the native cursor save/restore behind
-- menu opens (battle_input.c cursor save/CheckCursorInput).
function BattleScreenState:_restoreCommandSelection()
  local combatant = self:_actingCombatant()
  local saved = combatant ~= nil and self._savedCommandCursor[combatant] or nil
  if type(saved) == "table" and type(saved.x) == "number" and type(saved.y) == "number" then
    local row = COMMAND_GRID[saved.y + 1]
    local slot = row ~= nil and row[saved.x + 1] or nil
    local destination = type(slot) == "string" and self:_surfaceCommand(slot) or nil
    if destination ~= nil then
      self._commandX, self._commandY = saved.x, saved.y
      self._selection = destination
      return
    end
  end
  self._commandX, self._commandY = 0, 0
  self._selection = self:_defaultCommandSelection()
end

-- Restores the acting entry's remembered fight-menu cursor: the saved
-- per-combatant cell while its slot stays enabled, else the first
-- enabled slot. Matches the native move-cursor save/reset behind
-- fight-menu opens.
---@return string restored move selection
function BattleScreenState:_restoreMoveSelection()
  local combatant = self:_actingCombatant()
  local saved = combatant ~= nil and self._savedMoveCursor[combatant] or nil
  if type(saved) == "table" and type(saved.x) == "number" and type(saved.y) == "number" then
    local slot = saved.y * 2 + saved.x
    for _, move in ipairs(self:_moves()) do
      if move.slot == slot and move.enabled == true then
        self._selection = "move:" .. tostring(slot)
        return self._selection
      end
    end
  end
  self._selection = self:_defaultMoveSelection()
  return self._selection
end

-- Picks the opening target cell for the projected candidates: the saved
-- per-combatant cell while its range still applies and the cell stays
-- enabled, else the native priority order (upper-left foe,
-- upper-right foe, lower-left ally, lower-right ally).
---@param candidates table<integer, table<string, unknown>>? projected target variants under selection
---@param rangeKey string? move range identity behind the open target choice
---@return string? first enabled control by native priority, nil without an enabled candidate
function BattleScreenState:_initialTargetSelection(candidates, rangeKey)
  if type(candidates) == "table" then
    local combatant = self:_actingCombatant()
    local saved = combatant ~= nil and self._savedTargetCursor[combatant] or nil
    if saved ~= nil and saved.range == rangeKey then
      for _, candidate in ipairs(candidates) do
        if type(candidate) == "table" and candidate.controlId == saved.id and candidate.enabled == true then
          return saved.id
        end
      end
    end
    local enabled = {}
    for _, candidate in ipairs(candidates) do
      if type(candidate) == "table" and type(candidate.controlId) == "string" and candidate.enabled == true then
        enabled[candidate.controlId] = true
      end
    end
    for _, id in ipairs(TARGET_PRIORITY) do
      if enabled[id] == true then
        return id
      end
    end
  end
  return nil
end

-- Moves the prompt to the acting entry: command selection for ordinary
-- turns, or the forced child for replacement and learning decisions.
function BattleScreenState:_enterActorPrompt()
  self._targetCandidates = nil
  self._targetRangeKey = nil
  self._pendingMoveId = nil
  self:cancelPointerCapture()
  self._notice = nil
  local mode = self:_modeForOptions(self._options)
  if mode ~= "child" then
    self._subflows:closeChild()
    self._mode = "command"
    self:_restoreCommandSelection()
    self._menuRevealStep = 0
    self._menuGateTicks = 5
    self._child = nil
    return
  end
  local kind = "learn"
  local purpose = "learn"
  if type(self._options) == "table" and type(self._options.actors) == "table" then
    for _, actor in ipairs(self._options.actors) do
      if type(actor) == "table" and actor.kind == "replacement" then
        kind = "party"
        purpose = "replacement"
      end
    end
  end
  local intent = self:_childIntent(kind, purpose, false)
  if intent == nil then
    self._mode = "failed"
    self._error = "the battle screen mirrors its request"
    self._child = nil
    return
  end
  -- A later forced entry may step back to an earlier one, so only the
  -- first entry opens without cancellation.
  intent.cancellable = kind == "party" and purpose == "replacement" and self._actorIndex > 1
  local ok, failure = self._subflows:open(intent)
  if not ok then
    self._mode = "failed"
    self._error = type(failure) == "string" and failure
      or "the requested child failed to open for launch " .. self._launchId
    self._child = nil
    return
  end
  local request = assert(self._request, "forced children answer the open request")
  self._child =
    { kind = kind, cancellable = intent.cancellable == true, purpose = purpose, requestId = request.requestId }
  self._selection = nil
  self._mode = "child"
end

-- Builds the child intent for the acting entry of the mirrored open
-- request: battle-owned snapshots and exactly the acting entry's
-- projected options travel with the launch and request identity so every
-- child result binds back to this decision. Fragments already staged for
-- sibling entries mask their exact resources locally: an already staged
-- reserve or a spent single-stock serving stays unavailable to later
-- entries without reimplementing kernel legality, which still judges the
-- final batch.
---@param kind string child kind under opening
---@param purpose string selection purpose under opening
---@param cancellable boolean cancel permission under opening
---@return table<string, unknown>? child intent, nil without an open request
function BattleScreenState:_childIntent(kind, purpose, cancellable)
  if self._request == nil or self._options == nil then
    return nil
  end
  local entry = self:_actorOptions()
  if entry == nil then
    return nil
  end
  local narrowed = copyValue(entry) --[[@as table<string, unknown>]]
  self:_maskStagedResources(narrowed)
  local options = {
    requestId = self._options.requestId,
    epoch = self._options.epoch,
    controller = self._options.controller,
    kind = self._options.kind,
    actors = { narrowed },
  } --[[@as table<string, unknown>]]
  return {
    kind = kind,
    purpose = purpose,
    launchId = self._launchId,
    requestId = self._request.requestId,
    epoch = self._request.epoch,
    controller = self._request.controller,
    cancellable = cancellable,
    request = copyValue(self._request),
    options = options,
    party = copyValue(self._partySnapshot or {}),
    inventory = copyValue(self._inventorySnapshot or {}),
  }
end

---@param entry table<string, unknown> acting entry options under masking
function BattleScreenState:_maskStagedResources(entry)
  local stagedReplacements = {}
  local stagedItems = {}
  for index, fragment in pairs(self._staged) do
    if index ~= self._actorIndex and type(fragment) == "table" then
      local payload = fragment.payload --[[@as table<string, unknown>?]]
      if fragment.kind == "switch" and type(payload) == "table" and type(payload.replacement) == "number" then
        stagedReplacements[payload.replacement] = true
      elseif fragment.kind == "item" and type(payload) == "table" and type(payload.item) == "string" then
        stagedItems[payload.item] = (stagedItems[payload.item] or 0) + 1
      end
    end
  end
  if next(stagedReplacements) == nil and next(stagedItems) == nil then
    return
  end
  local stock = {}
  if type(self._inventorySnapshot) == "table" then
    for key, quantity in pairs(self._inventorySnapshot) do
      if type(key) == "string" and type(quantity) == "number" then
        stock[key] = quantity --[[@as integer]]
      end
    end
  end
  if type(entry.choices) ~= "table" then
    return
  end
  for _, choice in ipairs(entry.choices) do
    if type(choice) == "table" and choice.enabled == true and type(choice.choice) == "table" then
      local fragment = choice.choice --[[@as table<string, unknown>]]
      local payload = fragment.payload --[[@as table<string, unknown>?]]
      if type(payload) == "table" then
        if
          fragment.kind == "switch"
          and type(payload.replacement) == "number"
          and stagedReplacements[payload.replacement] == true
        then
          choice.enabled = false
          choice.reason = "reserved"
        elseif
          fragment.kind == "item"
          and type(payload.item) == "string"
          and (stock[payload.item] or 0) - (stagedItems[payload.item] or 0) < 1
        then
          choice.enabled = false
          choice.reason = "reserved"
        end
      end
    end
  end
end

-- Opens a voluntary child over the open command decision. A child that
-- cannot open keeps the command request with a visible refusal instead
-- of a half-open selection.
---@param kind string child kind under opening
---@param purpose string selection purpose under opening
function BattleScreenState:_openVoluntaryChild(kind, purpose)
  local intent = self:_childIntent(kind, purpose, true)
  if intent == nil then
    return
  end
  local ok, failure = self._subflows:open(intent)
  if not ok then
    self:_refuse(type(failure) == "string" and failure or nil)
    return
  end
  self._child = { kind = kind, cancellable = true, purpose = purpose, requestId = intent.requestId }
  self._mode = "child"
  self._notice = nil
end

---@return table<string, unknown>? enabled native struggle option when it is the only usable move, nil otherwise
function BattleScreenState:_struggleOnlyOption()
  local entry = self:_actorOptions()
  if type(entry) ~= "table" or type(entry.choices) ~= "table" then
    return nil
  end
  local struggle = nil
  for _, choice in ipairs(entry.choices) do
    if type(choice) == "table" and choice.role == "move" and type(choice.id) == "string" then
      if choice.id == "move:struggle" then
        if choice.enabled == true then
          struggle = choice
        end
      elseif choice.enabled == true then
        return nil
      end
    end
  end
  return struggle
end

---@return boolean usable true while some move choice stays enabled
---@return string? reason first kernel refusal in slot order with struggle last, nil while usable or reasonless
function BattleScreenState:_usableMove()
  local entry = self:_actorOptions()
  local reasons = {} ---@type table<integer, string>
  local struggleReason = nil
  local usable = false
  if type(entry) == "table" and type(entry.choices) == "table" then
    for _, choice in ipairs(entry.choices) do
      if type(choice) == "table" and choice.role == "move" and type(choice.id) == "string" then
        if choice.enabled == true then
          usable = true
        else
          local reason = (type(choice.reason) == "string" and choice.reason ~= "") and choice.reason or nil
          local slot = tonumber((choice.id --[[@as string]]):match("^move:(%d+)$") or "")
          if slot ~= nil then
            if reason ~= nil and reasons[slot] == nil then
              reasons[slot] = reason
            end
          elseif choice.id == "move:struggle" and reason ~= nil and struggleReason == nil then
            struggleReason = reason
          end
        end
      end
    end
  end
  local firstReason = struggleReason
  for slot = 0, 3 do
    if reasons[slot] ~= nil then
      firstReason = reasons[slot]
      break
    end
  end
  return usable, firstReason
end

---@param id string command identity under activation
function BattleScreenState:_activateCommand(id)
  -- Commands outside the launch kind surface never act: pointer or
  -- key input naming a phantom identity refuses instead of sealing an
  -- unoffered choice.
  if not self:_isOfferedCommand(id) then
    self:_refuse(nil)
    return
  end
  -- The accepted choice remembers its cursor cell per battler, like
  -- the native cursor save behind touch and keypad confirms.
  self:_syncCommandCursor(id)
  local combatant = self:_actingCombatant()
  if combatant ~= nil then
    self._savedCommandCursor[combatant] = { x = self._commandX, y = self._commandY }
  end
  if id == "fight" then
    local struggle = self:_struggleOnlyOption()
    if struggle ~= nil then
      self:_submitMove(struggle)
      return
    end
    -- With no usable move Fight refuses with the kernel reason
    -- instead of opening a dead move list.
    local usable, reason = self:_usableMove()
    if not usable then
      self:_refuse(reason)
      return
    end
    self._mode = "moves"
    self:_restoreMoveSelection()
    self._menuRevealStep = 4
    self._menuGateTicks = 1
    self._notice = nil
  elseif id == "bag" then
    -- Frontier facilities refuse bag items natively, so the command
    -- refuses at selection instead of opening a usable bag.
    if self._kind == "frontier" then
      self:_refuse(nil)
      return
    end
    self:_openVoluntaryChild("bag", "bag")
  elseif id == "pokemon" then
    self:_openVoluntaryChild("party", "switch")
  elseif id == "run" then
    local fragment = self:_fragmentFor("run")
    if fragment == nil then
      self:_refuse(self:_runReason())
    else
      self:_seal(fragment)
    end
  elseif id == "safari-ball" or id == "pal-park-ball" or id == "bug-contest-ball" then
    self:_sealSpecialAction("ball")
  elseif id == "safari-bait" then
    self:_sealSpecialAction("bait")
  elseif id == "safari-mud" then
    self:_sealSpecialAction("mud")
  end
end

---@param role string kernel choice role under refusal lookup
---@return string? kernel refusal reason for the role, nil when unoffered
function BattleScreenState:_roleReason(role)
  local entry = self:_actorOptions()
  if type(entry) == "table" and type(entry.choices) == "table" then
    for _, choice in ipairs(entry.choices) do
      if type(choice) == "table" and choice.role == role and type(choice.reason) == "string" then
        return choice.reason --[[@as string]]
      end
    end
  end
  return nil
end

---@return string? kernel refusal reason for flight, nil when flight is legal
function BattleScreenState:_runReason()
  return self:_roleReason("run")
end

-- Seals one special-context action through the kernel's matching role
-- when the open request offers it; without an offered fragment the
-- command refuses instead of inventing a choice.
---@param role string kernel choice role behind the special action
function BattleScreenState:_sealSpecialAction(role)
  local fragment = self:_fragmentFor(role)
  if fragment ~= nil then
    self:_seal(fragment)
    return
  end
  self:_refuse(self:_roleReason(role))
end

---@return string first enabled move selection, falling back to the first slot
function BattleScreenState:_defaultMoveSelection()
  for _, move in ipairs(self:_moves()) do
    if move.enabled == true and type(move.slot) == "number" and move.slot < 4 then
      return "move:" .. tostring(move.slot)
    end
  end
  return "move:0"
end

---@param id string move control identity under activation
---@param armed table<string, unknown>? pressed control behind the release
function BattleScreenState:_activateMove(id, armed)
  if id == "cancel" then
    self._mode = "command"
    self:_restoreCommandSelection()
    self._notice = nil
    self:_playCancelFeedback()
    return
  end
  local entry = self:_moveEntry(id)
  if entry == nil or entry.enabled ~= true then
    local reason = (entry ~= nil and type(entry.reason) == "string") and entry.reason or "empty"
    self:_refuse(reason --[[@as string]])
    return
  end
  -- A matched release whose press began on the already-focused slot
  -- seals the projected fragment exactly like semantic confirm; any
  -- other release only moves focus.
  if armed ~= nil and armed.focused == true and self._selection == id then
    self:_submitMove(entry)
    return
  end
  self._selection = id
  self._notice = nil
end

---@param id string target control identity under activation
---@return table<string, unknown>? projected target variant, nil when absent
function BattleScreenState:_targetVariant(id)
  if self._targetCandidates == nil then
    return nil
  end
  for _, candidate in ipairs(self._targetCandidates) do
    if type(candidate) == "table" and candidate.controlId == id then
      return candidate
    end
  end
  return nil
end

---@param id string target control identity under activation
---@param armed table<string, unknown>? pressed control behind the release
function BattleScreenState:_activateTarget(id, armed)
  local _ = armed
  if id == "cancel" then
    self._targetCandidates = nil
    self._lastTargetSelection = nil
    self._targetGroup = nil
    self._targetRangeKey = nil
    self:_playCancelFeedback()
    if self._pendingMoveId == "move:struggle" then
      self._pendingMoveId = nil
      self._mode = "command"
      self:_restoreCommandSelection()
    else
      self._mode = "moves"
      if self._pendingMoveId ~= nil then
        self._selection = self._pendingMoveId
        self._pendingMoveId = nil
      end
    end
    self._notice = nil
    self:cancelPointerCapture()
    return
  end
  local candidate = self:_targetVariant(id)
  if candidate == nil or candidate.enabled ~= true then
    local reason = (candidate ~= nil and type(candidate.reason) == "string") and candidate.reason or nil
    self:_refuse(reason)
    return
  end
  self._targetCandidates = nil
  self._lastTargetSelection = nil
  self._targetGroup = nil
  -- The sealed target remembers its cell beside its move range, like
  -- the native target-cursor save behind the accepted choice.
  local combatant = self:_actingCombatant()
  if combatant ~= nil and self._targetRangeKey ~= nil then
    self._savedTargetCursor[combatant] = { id = id, range = self._targetRangeKey }
  end
  self._targetRangeKey = nil
  self._pendingMoveId = nil
  self:_seal(copyValue(candidate.choice) --[[@as table<string, unknown>]])
end

---@param control table<string, unknown> sealed control under dispatch
---@param armed table<string, unknown>? pressed control behind the release
function BattleScreenState:_sealControl(control, armed)
  if self._mode == "command" then
    self:_activateCommand(control.id --[[@as string]])
  elseif self._mode == "moves" then
    self:_activateMove(control.id --[[@as string]], armed)
  elseif self._mode == "target" then
    self:_activateTarget(control.id --[[@as string]], armed)
  end
end

---@param scope string selected menu scope
---@param id string selected source control identity
---@param armed table<string, unknown>? pointer press state under activation
function BattleScreenState:_startButtonFeedback(scope, id, armed)
  local regions = BattleMenuRegions.forLayout(scope)
  if regions == nil then
    return
  end
  local known = false
  for _, region in ipairs(regions) do
    if region.id == id then
      known = true
      break
    end
  end
  if not known then
    return
  end
  if scope == "command" then
    -- Pointer regions name ordinary slots while special kinds relabel
    -- the same four-slot topology: the feedback arms the resolved
    -- surface identity exactly like the press path.
    local offered = self:_isOfferedCommand(id) and id or self:_surfaceCommand(id)
    if offered == nil then
      self:_refuse(nil)
      return
    end
    id = offered
  elseif scope == "moves" and id ~= "cancel" then
    local entry = self:_moveEntry(id)
    if entry == nil or entry.enabled ~= true then
      local reason = (entry ~= nil and type(entry.reason) == "string") and entry.reason or "empty"
      self:_refuse(reason --[[@as string]])
      return
    end
  elseif scope == "target" and id ~= "cancel" then
    local candidate = self:_targetVariant(id)
    if candidate == nil or candidate.enabled ~= true then
      self:_refuse(candidate ~= nil and candidate.reason or nil)
      return
    end
  end
  self._buttonFeedback = {
    scope = scope,
    id = id,
    ticks = 0,
    armed = armed,
  }
end

-- The held press supplies the down frame; release recovers through one
-- source pixel, settles at rest, then activates.
function BattleScreenState:_advanceButtonFeedback()
  local feedback = self._buttonFeedback
  if feedback == nil then
    return
  end
  feedback.ticks = feedback.ticks + 1
  if feedback.ticks < 3 then
    return
  end
  self._buttonFeedback = nil
  self:_sealControl({ id = feedback.id }, feedback.armed)
end

-- Checks one staged child result against the mirrored open request.
-- Only the current launch, request, epoch, and controller seal.
---@param identity table<string, unknown> staged result or reply identity under validation
---@return boolean current true for the mirrored open request
function BattleScreenState:_childIdentityMatches(identity)
  if self._request == nil then
    return false
  end
  if type(identity.launchId) == "string" and identity.launchId ~= self._launchId then
    return false
  end
  return identity.requestId == self._request.requestId
    and identity.epoch == self._request.epoch
    and identity.controller == self._request.controller
end

-- Collects one staged child result: a bound choice seals through the
-- accepted-choice boundary, a permitted cancellation returns to the
-- mirrored request, and a stale identity discards without sealing. A
-- refused seal keeps the child open for another selection.
-- Polls the open registration card after the parent timeline: a card
-- failure fails the screen exactly once, completion releases the readiness hold, and the active
-- card steps on accepted time. Never replays the creating edge into the
-- card and never advances battle choices behind it.
---@param dt number accepted presentation seconds
function BattleScreenState:_pollRegistrationChild(dt)
  local child = self._registrationChild --[[@as table<string, unknown>?]]
  if child == nil then
    return
  end
  local statusOf = child.status --[[@as fun(self: table<string, unknown>)?]]
  local stepChild = child.updateFixed --[[@as fun(self: table<string, unknown>, dt: number)?]]
  if type(statusOf) ~= "function" or type(stepChild) ~= "function" then
    self._mode = "failed"
    self._error = "battle registration failed for launch " .. self._launchId .. ": missing card operations"
    return
  end
  local okStatus, status = pcall(statusOf, child)
  if not okStatus or type(status) ~= "table" then
    self._mode = "failed"
    self._error = "battle registration failed for launch " .. self._launchId .. ": " .. tostring(status)
    return
  end
  if type(status.error) == "string" then
    self._mode = "failed"
    self._error = "battle registration failed for launch " .. self._launchId .. ": " .. status.error
    return
  end
  if status.complete == true then
    if self._registrationComplete ~= true then
      self._registrationComplete = true
    end
    return
  end
  local okStep, stepErr = pcall(stepChild, child, dt)
  if not okStep then
    self._mode = "failed"
    self._error = "battle registration failed for launch " .. self._launchId .. ": " .. tostring(stepErr)
    return
  end
  local okDone, done = pcall(statusOf, child)
  if okDone and type(done) == "table" and type(done.error) == "string" then
    self._mode = "failed"
    self._error = "battle registration failed for launch " .. self._launchId .. ": " .. done.error
    return
  end
  if okDone and type(done) == "table" and done.complete == true and self._registrationComplete ~= true then
    self._registrationComplete = true
  end
end

function BattleScreenState:_pollChild()
  local result = self._subflows:takeResult()
  if result == nil then
    local notice = self._subflows:status().notice
    if type(notice) == "string" and notice ~= "" then
      self._notice = notice
    end
    return
  end
  if result.kind == "cancelled" then
    if not self:_childIdentityMatches(result) then
      self._armed = nil
      return
    end
    self:_cancelChild()
    return
  end
  if result.kind == "choice" then
    local reply = result.reply --[[@as table<string, unknown>]]
    if not self:_childIdentityMatches(reply) then
      self._subflows:closeChild()
      self._child = nil
      self._armed = nil
      self._notice = "The selection expired."
      if self._request ~= nil then
        self:_enterActorPrompt()
      else
        self._mode = "command"
      end
      return
    end
    local fragments = reply.choices --[[@as table<integer, table<string, unknown>>]]
    local fragment = fragments[1]
    if not self:_fragmentAddressesActor(fragment) then
      self._subflows:closeChild()
      self._child = nil
      self._armed = nil
      self._notice = "The selection expired."
      if self._request ~= nil then
        self:_enterActorPrompt()
      else
        self._mode = "command"
      end
      return
    end
    self:_seal(copyValue(fragment))
    if self._mode == "awaiting_resolution" or self._mode == "command" then
      self._subflows:closeChild()
      self._child = nil
    end
  end
end

-- Checks one staged child fragment against the acting entry: only the
-- current request position seals with the staged choices.
---@param fragment unknown staged child fragment under validation
---@return boolean acting true for the acting entry
function BattleScreenState:_fragmentAddressesActor(fragment)
  if type(fragment) ~= "table" then
    return false
  end
  if self._request == nil or type(self._request.actors) ~= "table" then
    return false
  end
  local actors = self._request.actors --[[@as table<integer, table<string, unknown>>]]
  local addressed = actors[self._actorIndex]
  if type(addressed) ~= "table" then
    return false
  end
  local actor = (fragment --[[@as table<string, unknown>]]).actor --[[@as table<string, unknown>?]]
  if type(actor) ~= "table" then
    return false
  end
  return actor.combatant == addressed.combatant and actor.activation == addressed.activation
end

---@param event table<string, unknown> mapped semantic input under consumption
function BattleScreenState:_consume(event)
  local eventType = event.type
  local menuKeyboardEdge = (self._mode == "command" or self._mode == "moves" or self._mode == "target")
    and (eventType == "navigate" or eventType == "confirm" or eventType == "cancel")
  local revealCursor = eventType == "navigate" and menuKeyboardEdge and not self._keyboardFocus
  if eventType == "navigate" or eventType == "confirm" or eventType == "cancel" then
    self._keyboardFocus = true
  elseif eventType == "battle_press" or eventType == "child_press" then
    self._keyboardFocus = false
  end
  if eventType == "pointer_cancel" then
    self._armed = nil
    self._buttonFeedback = nil
    self._subflows:cancelPointerCapture()
    return
  end
  if self._buttonFeedback ~= nil or revealCursor then
    return
  end
  -- The bound nickname completion owns its semantic edges ahead of the
  -- battle handlers; anything it refuses falls through below.
  if self:_consumeCompletion(event) then
    return
  end
  if self._menuGateTicks > 0 then
    return
  end
  if self._mode == "child" and self._subflows:status().active then
    if eventType == "confirm" or eventType == "cancel" or eventType == "navigate" then
      self._subflows:update({ event })
      self:_pollChild()
    elseif eventType == "child_press" then
      local control = event.control --[[@as table<string, unknown>?]]
      if type(control) == "table" and type(control.id) == "string" then
        self._armed = { scope = "child", id = control.id, pointerId = event.pointerId }
      end
    elseif eventType == "child_slide" then
      if
        not sameControl(self._armed, event.control --[[@as table<string, unknown>?]], event.pointerId)
      then
        self._armed = nil
      end
    elseif eventType == "child_activate" then
      local armed = self._armed
      self._armed = nil
      local control = event.control --[[@as table<string, unknown>?]]
      if type(control) == "table" and type(control.id) == "string" and sameControl(armed, control, event.pointerId) then
        local consumed = control.id == "native"
            and type(event.x) == "number"
            and type(event.y) == "number"
            and self._subflows:activatePoint(event.x --[[@as number]], event.y --[[@as number]])
          or self._subflows:activateControl(control.id --[[@as string]])
        if consumed then
          self:_pollChild()
        end
      end
    elseif eventType == "child_cancel" then
      self._armed = nil
      self._subflows:cancelPointerCapture()
    end
    return
  end
  if eventType == "battle_press" then
    if self._mode == "command" or self._mode == "moves" or self._mode == "target" then
      local scope = event.control.scope --[[@as string]]
      local id = event.control.id --[[@as string]]
      if not knownMenuControl(scope, id) then
        return
      end
      if scope == "command" then
        -- Pointer regions name ordinary slots while special kinds
        -- relabel the same four-slot topology: resolve the press to
        -- the offered surface identity before arming.
        local offered = self:_isOfferedCommand(id) and id or self:_surfaceCommand(id)
        if offered == nil then
          return
        end
        id = offered
      end
      if scope == "target" and id ~= "cancel" then
        -- The native touch callback ignores illegal target cells
        -- without feedback: only an admitted candidate arms.
        local candidate = self:_targetVariant(id)
        if candidate == nil or candidate.enabled ~= true then
          return
        end
      end
      self._armed = { scope = scope, id = event.control.id, pointerId = event.pointerId }
      if scope == "command" then
        self._selection = id
        self:_syncCommandCursor(id)
      elseif event.control.scope == "moves" then
        if id ~= "cancel" then
          local entry = self:_moveEntry(id)
          if entry ~= nil and entry.enabled == true then
            -- Remember whether the press began on the focused slot so
            -- the matched release can tell a focusing tap from a seal.
            self._armed.focused = (self._selection == id)
            self._selection = id
          end
        end
      end
      -- Target presses arm through the shared capture above without
      -- moving selection: the matched release seals the pressed
      -- candidate (or Back) directly, so pointer taps settle the
      -- identical fragment as keyboard confirm on every layout.
      -- Keyboard focus still moves through navigate; command and move
      -- presses keep their focus bookkeeping above.
    elseif self._mode == "narration" or self._mode == "outcome" then
      -- A dialogue tap arms exactly like a command press so the matched
      -- release can acknowledge the shown page; an unmatched press never
      -- arms and its release falls away through the shared capture check.
      local control = event.control --[[@as table<string, unknown>?]]
      if type(control) == "table" and control.scope == self._mode then
        self._armed = { scope = control.scope, id = control.id, pointerId = event.pointerId }
      end
    end
    return
  end
  if eventType == "battle_slide" then
    if
      not sameControl(self._armed, event.control --[[@as table<string, unknown>?]], event.pointerId)
    then
      self._armed = nil
    end
    return
  end
  if eventType == "battle_activate" then
    local armed = self._armed
    self._armed = nil
    if
      sameControl(armed, event.control --[[@as table<string, unknown>?]], event.pointerId)
    then
      if self._mode == "narration" or self._mode == "outcome" then
        local control = event.control --[[@as table<string, unknown>?]]
        if type(control) == "table" and control.scope == self._mode then
          self._timeline:ack()
        end
      else
        self:_startButtonFeedback(self._mode, event.control.id --[[@as string]], armed)
      end
    end
    return
  end
  if eventType == "confirm" then
    self:_confirm()
    return
  end
  if eventType == "cancel" then
    self:_cancel()
    return
  end
  if eventType == "navigate" then
    self:_navigate(event.direction --[[@as string]])
    return
  end
end

function BattleScreenState:_confirm()
  if self._timeline:levelUpStats() ~= nil or self._timeline:messageActive() then
    self._timeline:ack()
  elseif self._mode == "command" and type(self._selection) == "string" then
    self:_activateCommand(self._selection --[[@as string]])
  elseif self._mode == "moves" and type(self._selection) == "string" then
    local selection = self._selection --[[@as string]]
    if selection == "cancel" then
      self:_activateMove("cancel")
    else
      local entry = self:_moveEntry(selection)
      if entry == nil or entry.enabled ~= true then
        local reason = (entry ~= nil and type(entry.reason) == "string") and entry.reason or "empty"
        self:_refuse(reason --[[@as string]])
      else
        self:_submitMove(entry)
      end
    end
  elseif self._mode == "target" and type(self._selection) == "string" then
    local selection = self._selection --[[@as string]]
    if selection == "cancel" then
      self:_activateTarget("cancel")
    else
      self:_activateTarget(selection)
    end
  elseif self._mode == "narration" or self._mode == "intro" then
    self._timeline:ack()
  elseif self._mode == "outcome" then
    self._timeline:ack()
  end
end

-- Releases the registration card exactly once, converging normal, failure,
-- and disposal paths on one idempotent release.
function BattleScreenState:_disposeRegistrationChild()
  local child = self._registrationChild
  self._registrationChild = nil
  if child ~= nil then
    pcall(child.dispose, child)
  end
end

-- Constructs the battle-owned registration card once from the retained
-- terminal facts. Missing presentation capability fails explicitly
-- instead of faking a card or silently dropping the registration.
function BattleScreenState:_openRegistrationChild()
  if self._registrationChild ~= nil or self._pendingRegistration == nil then
    return
  end
  local registration = assert(self._pendingRegistration, "registration children open from retained facts")
  self._pendingRegistration = nil
  local pokedex = self._pokedex
  local audio = self._registrationAudio
  if type(pokedex) ~= "table" or type(audio) ~= "table" then
    self._mode = "failed"
    self._error = "battle registration needs its presentation resources for launch " .. self._launchId
    return
  end
  local RegistrationState = require("game.hgss.src.pokedex.PokedexRegistrationState")
  local ok, child = pcall(RegistrationState.new, {
    registration = registration,
    pokedex = pokedex,
    timeline = self._timeline,
    audio = audio,
    measureDisplay = self._measureDisplay,
  })
  if not ok or type(child) ~= "table" then
    self._mode = "failed"
    self._error = "battle registration failed to open for launch " .. self._launchId .. ": " .. tostring(child)
    return
  end
  self._registrationChild = child --[[@as table<string, unknown>]]
end

---@param entry table<string, unknown> accepted move option under sealing
function BattleScreenState:_submitMove(entry)
  -- Every enabled move option already carries its complete legal
  -- fragment: a single admitted position seals its projected fragment
  -- unchanged, while several admitted positions open the projected
  -- target list for an explicit choice. Nothing here rewrites targets.
  -- The accepted move remembers its fight-menu cell per battler, like
  -- the native move-cursor save behind keypad and touch confirms.
  local combatant = self:_actingCombatant()
  if combatant ~= nil and type(entry.id) == "string" then
    local slot = tonumber(entry.id:match("^move:(%d+)$") or "")
    if slot ~= nil and slot < 4 then
      self._savedMoveCursor[combatant] = { x = math.floor(slot % 2), y = math.floor(slot / 2) }
    end
  end
  local candidates = nil
  if type(entry.targets) == "table" then
    candidates = {}
    for _, variant in ipairs(entry.targets) do
      if type(variant) == "table" and variant.enabled == true then
        candidates[#candidates + 1] = variant
      end
    end
  end
  local displayedCombatants = {}
  local battlers = self._timeline:battlers()
  local foeOrder, allyOrder = sceneSlotOrders(battlers)
  local sideTypes = {}
  local sides = {}
  for _, battler in ipairs(battlers) do
    if type(battler.combatant) == "number" and battler.visible ~= false then
      displayedCombatants[battler.combatant] = true
      local order = battler.side == 1 and allyOrder or foeOrder
      local row = BattleScene.slotRow(battler, order, self._manifest.battlefield.slots)
      sideTypes[battler.combatant] = row.sideType
      sides[battler.combatant] = battler.side
    end
  end
  if candidates == nil or #candidates <= 1 then
    if candidates ~= nil and #candidates == 1 then
      if type(candidates[1].combatant) == "number" and displayedCombatants[candidates[1].combatant] ~= true then
        self:_refuse(candidates[1].reason)
        return
      end
      self:_seal(copyValue(candidates[1].choice) --[[@as table<string, unknown>]])
    else
      self:_seal(copyValue(entry.choice) --[[@as table<string, unknown>]])
    end
    return
  end
  self._pendingMoveId = entry.id
  self._targetCandidates = copyValue(entry.targets)
  self._lastTargetSelection = nil
  for _, candidate in ipairs(self._targetCandidates) do
    local candidateCombatant = candidate.combatant
    local sideType = type(candidateCombatant) == "number" and sideTypes[candidateCombatant] or nil
    candidate.controlId = type(sideType) == "number" and TARGET_CONTROL_BY_SIDE_TYPE[sideType] or nil
    candidate.side = type(candidateCombatant) == "number" and sides[candidateCombatant] or nil
  end
  self._targetGroup = nil
  local display = entry.display
  local moveKey = type(display) == "table" and (display.move or display.name) or nil
  -- The target cursor is remembered per move range, matching the
  -- native per-battler target position saved beside its target type.
  local rangeKey = "move:" .. tostring(moveKey)
  if type(moveKey) == "string" and self._monCatalog ~= nil then
    local range = self._monCatalog:move(moveKey).range
    if type(range) == "number" then
      rangeKey = "range:" .. tostring(range)
    end
    local includeSide = range == 4 and 2 or range == 32 and 1 or range == 128 and 2 or nil
    local groups = { own = {}, foes = {} }
    for _, candidate in ipairs(self._targetCandidates) do
      if candidate.enabled == true and type(candidate.controlId) == "string" then
        local include = includeSide == nil or candidate.side == includeSide
        if range == 8 or range == 64 then
          include = true
        end
        if include then
          local side = candidate.side == 2 and groups.foes or groups.own
          side[#side + 1] = candidate.controlId
        end
      end
    end
    local groupCount = #groups.own + #groups.foes
    if (range == 4 or range == 8 or range == 32 or range == 64 or range == 128) and groupCount > 1 then
      self._targetGroup = { range = range, groups = groups }
    end
  end
  self._targetRangeKey = rangeKey
  self._mode = "target"
  local firstControlId = self:_initialTargetSelection(self._targetCandidates, rangeKey)
  if firstControlId == nil then
    self._targetCandidates = nil
    self._targetRangeKey = nil
    self._pendingMoveId = nil
    self._targetGroup = nil
    self:_refuse(nil)
    return
  end
  self._selection = firstControlId
  self._notice = nil
  self:cancelPointerCapture()
end

function BattleScreenState:_cancel()
  if self._mode == "target" then
    self:_activateTarget("cancel")
  elseif self._mode == "moves" then
    self._mode = "command"
    self:_restoreCommandSelection()
    self._notice = nil
    self:_playCancelFeedback()
  elseif self._mode == "command" then
    -- Back across staged choices returns to the previous entry with its
    -- staged fragment intact and editable; the request itself is kept.
    -- Every backing-out edge voices its interface feedback.
    self:_playCancelFeedback()
    if self._request ~= nil and self._actorIndex > 1 then
      self._actorIndex = self._actorIndex - 1
      self._mode = "command"
      self:_restoreCommandSelection()
      self._notice = nil
      self:cancelPointerCapture()
    end
  elseif self._mode == "child" and self._child ~= nil then
    self:_cancelChild()
  end
end

-- Cancels the open child: a voluntary child returns to the acting
-- entry prompt, a later forced entry steps back to the earlier entry
-- with its staged fragment intact, and the first forced entry refuses.
function BattleScreenState:_cancelChild()
  if self._child == nil then
    return
  end
  if self._child.purpose == "replacement" and self._request ~= nil and self._actorIndex > 1 then
    self._actorIndex = self._actorIndex - 1
    self:_enterActorPrompt()
    return
  end
  if self._child.cancellable == true then
    self._subflows:closeChild()
    self._child = nil
    self._armed = nil
    self._notice = nil
    if self._request ~= nil then
      self._mode = "command"
    else
      self._mode = "command"
    end
    return
  end
  self:_refuse("That choice cannot be cancelled.")
end

---@param direction string? navigation direction under selection
function BattleScreenState:_navigate(direction)
  if self._mode == "target" then
    self:_navigateTargets(direction)
    return
  end
  if self._mode == "command" then
    self:_navigateCommand(direction)
    return
  end
  if self._mode ~= "moves" or type(self._selection) ~= "string" then
    return
  end
  local links = MOVE_NAV[self._selection]
  local destination = links ~= nil and links[direction] or nil
  if type(direction) == "string" and type(destination) == "string" then
    self._selection = destination
  end
end

-- Steps the main-menu cursor across the source 3x2 grid: motion clamps
-- at the edges, a horizontal edge on the wide Fight row wraps to the
-- lower-row ends, and pushing up from Run is a native no-op. The
-- cursor only settles on offered kind slots.
---@param direction string? source keypad direction under selection
function BattleScreenState:_navigateCommand(direction)
  if type(direction) ~= "string" then
    return
  end
  local x, y = self._commandX, self._commandY
  -- The native cursor ignores an upward edge from the Run cell.
  if x == 1 and y == 1 and direction == "up" then
    return
  end
  if direction == "left" then
    x = x - 1
  elseif direction == "right" then
    x = x + 1
  elseif direction == "up" then
    y = y - 1
  elseif direction == "down" then
    y = y + 1
  else
    return
  end
  x = math.max(0, math.min(COMMAND_GRID_WIDTH - 1, x))
  y = math.max(0, math.min(COMMAND_GRID_HEIGHT - 1, y))
  local before = COMMAND_GRID[self._commandY + 1][self._commandX + 1]
  local slot = COMMAND_GRID[y + 1][x + 1]
  if slot == before and slot == "fight" and (direction == "left" or direction == "right") then
    if direction == "left" then
      x = 0
    else
      x = 2
    end
    y = 1
    slot = COMMAND_GRID[y + 1][x + 1]
  end
  local destination = self:_surfaceCommand(slot)
  if destination == nil then
    return
  end
  self._commandX, self._commandY = x, y
  self._selection = destination
end

---@param direction string? source keypad direction under selection
function BattleScreenState:_navigateTargets(direction)
  if self._targetCandidates == nil or type(self._selection) ~= "string" then
    return
  end
  local grid = {
    ["target:0"] = { x = 0, y = 1 },
    ["target:1"] = { x = 1, y = 0 },
    ["target:2"] = { x = 1, y = 1 },
    ["target:3"] = { x = 0, y = 0 },
  }
  local available = {}
  for _, candidate in ipairs(self._targetCandidates) do
    local id = type(candidate) == "table" and candidate.controlId or nil
    if type(id) == "string" and grid[id] ~= nil then
      available[id] = candidate.enabled == true
    end
  end
  if self._targetGroup ~= nil then
    if self._selection == "cancel" then
      if direction == "up" then
        self._selection = self._lastTargetSelection or self._selection
      end
    elseif direction == "down" then
      self._lastTargetSelection = self._selection
      self._selection = "cancel"
    end
    return
  end
  if self._selection == "cancel" then
    if direction == "up" then
      for _, candidate in ipairs(self._targetCandidates) do
        local candidateId = type(candidate) == "table" and candidate.controlId or nil
        if candidateId == self._lastTargetSelection and candidate.enabled == true then
          self._selection = candidateId
          return
        end
      end
    end
    return
  end
  local origin = grid[self._selection]
  if origin == nil or available[self._selection] ~= true then
    return
  end
  if direction == "down" and origin.y == 1 then
    self._lastTargetSelection = self._selection
    self._selection = "cancel"
    return
  end
  local delta = ({
    left = { x = -1, y = 0 },
    right = { x = 1, y = 0 },
    up = { x = 0, y = -1 },
    down = { x = 0, y = 1 },
  })[
    direction --[[@as string?]]
  ]
  if delta == nil then
    return
  end
  local x = origin.x + delta.x
  local y = origin.y + delta.y
  while x >= 0 and x <= 1 and y >= 0 and y <= 1 do
    for id, point in pairs(grid) do
      if point.x == x and point.y == y and available[id] == true then
        self._lastTargetSelection = self._selection
        self._selection = id
        return
      end
    end
    x = x + delta.x
    y = y + delta.y
  end
end

---@param options table<string, unknown>? decision options carrying the actor kinds
---@return string mode for the request actor kind
function BattleScreenState:_modeForOptions(options)
  if type(options) == "table" and type(options.actors) == "table" then
    for _, actor in ipairs(options.actors) do
      if type(actor) == "table" and (actor.kind == "replacement" or actor.kind == "learn_move") then
        return "child"
      end
    end
  end
  return "command"
end

---@return table<integer, table<string, unknown>> source-selected terminal messages and holds
function BattleScreenState:_outcomeTexts()
  local result = assert(self._pendingResult, "terminal text reads its retained result")
  if result.word == "flee" then
    local escapeSource = result.escapeSource --[[@as table<string, unknown>?]]
    if escapeSource == nil then
      return { { text = stagedBattleText(self._manifest, "battle/narration/got-away", {}), holdTicks = 30 } }
    end
    local runnerName = assert(result.escapeName, "item and ability flight narration names its runner")
    local key = escapeSource.key
    assert(type(key) == "string", "flight source carries its catalog key")
    if escapeSource.kind == "item" then
      local item = assert(self._monCatalog, "flight item names resolve through the mon catalog"):item(key)
      local itemName = item.name
      assert(type(itemName) == "string", "flight items carry a localized name")
      return {
        {
          text = stagedBattleText(self._manifest, "battle/narration/fled-with-item", { runnerName, itemName }),
          holdTicks = 30,
        },
      }
    end
    assert(escapeSource.kind == "ability", "flight source is an item or ability")
    local ability = assert(self._monCatalog, "flight abilities resolve through the mon catalog"):ability(key)
    local abilityName = ability.name
    assert(type(abilityName) == "string", "flight abilities carry a localized name")
    return {
      {
        text = stagedBattleText(self._manifest, "battle/narration/fled-run-away", { runnerName, abilityName }),
        holdTicks = 30,
      },
    }
  end
  if result.word == "win" and self._kind == "trainer" then
    local latest = self._pendingFinal or self._latestView
    local trainers = type(latest) == "table" and latest.foeTrainers or nil
    local trainer = type(trainers) == "table" and trainers[1] or nil
    assert(type(trainer) == "table", "trainer victory narration reads its trainer facts")
    local classKey = trainer.classKey
    local trainerName = trainer.name
    assert(type(classKey) == "string", "trainer victory carries the class key")
    assert(type(trainerName) == "string", "trainer victory carries the trainer name")
    local className = stagedBattleText(self._manifest, "battle/trainer-class/" .. classKey, {})
    local messages = {
      {
        text = stagedBattleText(self._manifest, "battle/narration/trainer-victory", { className, trainerName }),
        holdTicks = 15,
      },
    }
    local loseSpeechKey = trainer.loseSpeechKey
    local messageEntries = self._manifest.messages.entries --[[@as table<string, unknown>]]
    if type(loseSpeechKey) == "string" and type(messageEntries[loseSpeechKey]) == "table" then
      messages[#messages + 1] = {
        text = resolveBattleText(self, loseSpeechKey, {}),
        holdTicks = 60,
      }
    end
    local moneyGained = result.moneyGained
    assert(
      type(moneyGained) == "number" and moneyGained % 1 == 0 and moneyGained >= 0,
      "trainer victory carries its planned payout"
    )
    if moneyGained > 0 then
      local playerName = assert(self._lastPlayerName, "trainer payout narration names the player")
      messages[#messages + 1] = {
        text = stagedBattleText(self._manifest, "battle/narration/won-money", { playerName, tostring(moneyGained) }),
        holdTicks = 60,
      }
    end
    return messages
  end
  if result.word ~= "loss" then
    return {}
  end
  local playerName = assert(self._lastPlayerName, "loss narration names the player")
  local messages = {
    { text = stagedBattleText(self._manifest, "battle/narration/defeated-last-mon", { playerName }), holdTicks = 30 },
  }
  local moneyLost = assert(result.moneyLost, "loss narration carries its planned prize penalty")
  assert(type(moneyLost) == "number" and moneyLost % 1 == 0 and moneyLost >= 0, "loss money stays nonnegative")
  if moneyLost > 0 then
    local key = self._kind == "trainer" and "battle/narration/trainer-lost-money" or "battle/narration/wild-lost-money"
    messages[#messages + 1] = {
      text = stagedBattleText(self._manifest, key, { playerName, tostring(moneyLost) }),
      holdTicks = 30,
    }
  end
  messages[#messages + 1] = { text = stagedBattleText(self._manifest, "battle/narration/ellipsis", {}), holdTicks = 30 }
  messages[#messages + 1] = {
    text = stagedBattleText(self._manifest, "battle/narration/player-blacked-out", { playerName }),
    holdTicks = 30,
  }
  return messages
end

-- Fires the bound terminal-music beat once at the outcome narration
-- entry: wins and captures notify exactly once per screen, before any
-- explicit acknowledgement; other terminal words notify nothing and a
-- headless screen without a bound beat keeps its cue contract. A
-- rejected beat fails the screen with its launch provenance while the
-- already-committed result keeps its existing return path.
---@param word unknown terminal result word under notification
function BattleScreenState:_notifyResultMusic(word)
  if self._resultMusicSent then
    return
  end
  if word ~= "win" and word ~= "capture" then
    return
  end
  local notify = self._onResultMusic
  if notify == nil then
    return
  end
  self._resultMusicSent = true
  local ok, err = pcall(notify, word)
  if not ok then
    self._mode = "failed"
    self._error = "result music failed for launch " .. self._launchId .. ": " .. tostring(err)
  end
end

-- Applies the retained delivery once its cues drain: reconcile exact
-- final facts, then expose the next request or the terminal result.
-- Exposure waits for a fully settled tick so the finished frame
-- presents first: the next request never appears before, or on the
-- same tick as, the earlier cues finishing.
---@param settledTick boolean true when no cue played on this update
function BattleScreenState:_drain(settledTick)
  if self._mode == "failed" then
    return
  end
  if not self._timeline:settled() then
    return
  end
  if self._pendingFinal ~= nil then
    self:_reconcile(self._pendingFinal)
    self._pendingFinal = nil
  end
  if not settledTick then
    return
  end
  if self._pendingResult ~= nil then
    local word = self._pendingResult.word
    self:_notifyResultMusic(word)
    if self._outcomeMessages == nil then
      self._outcomeMessages = self:_outcomeTexts()
    end
    local nextMessage = table.remove(self._outcomeMessages, 1)
    if nextMessage ~= nil then
      local record = nextMessage --[[@as table<string, unknown>]]
      self._timeline:announce(
        assert(record.text, "terminal entries carry staged wording") --[[@as string]],
        false,
        assert(record.holdTicks, "terminal entries carry source holds") --[[@as integer]]
      )
      self._mode = "outcome"
      return
    end
    self._pendingResult = nil
    self._outcomeMessages = nil
    self._outcomeDone = true
    if self._pendingRegistration ~= nil then
      self:_openRegistrationChild()
    end
    self._pendingRequest = nil
    -- The terminal request identity stays behind for the completion
    -- barrier: post-commit nickname children bind this settled decision
    -- instead of inventing an action identity.
    if self._request ~= nil then
      self._terminalRequest = {
        requestId = self._request.requestId,
        epoch = self._request.epoch,
        controller = self._request.controller,
      }
    end
    self._request = nil
    self._options = nil
    self._staged = {}
    self._lastStaged = nil
    self._actorIndex = 1
    self._targetCandidates = nil
    self._pendingMoveId = nil
    self._mode = "outcome"
    self._notice = nil
    self._child = nil
    return
  end
  if self._mode == "child" and self._subflows:status().active then
    return
  end
  if self._pendingRequest ~= nil then
    local request = self._pendingRequest --[[@as table<string, unknown>]]
    self._pendingRequest = nil
    self._request = request
    self._options = request.options --[[@as table<string, unknown>?]]
    -- A fresh packet owns fresh staged choices: obsolete staged fragments never
    -- answer a new request identity.
    self._staged = {}
    self._lastStaged = nil
    self._actorIndex = 1
    self:_enterActorPrompt()
  end
end

---@param view table<string, unknown> detached final view under reconciliation
function BattleScreenState:_reconcile(view)
  local known = {}
  for _, id in ipairs(self._timeline:order()) do
    known[id] = true
  end
  local function apply(records)
    if type(records) ~= "table" then
      return
    end
    for _, record in ipairs(records) do
      if type(record) == "table" and type(record.combatant) == "number" then
        self._timeline:reconcileBattler(record --[[@as table<string, unknown>]], known[
          record.combatant --[[@as integer]]
        ] == true)
      end
    end
  end
  apply(view.own)
  apply(view.foes)
end

-- One fixed update: prepare, cancel held presses across remeasure, map
-- one queued batch batch per waiting slot in order, advance the cue
-- player on accepted time, then reconcile drained deliveries and
-- re-resolve the published plan.
---@param dt number accepted presentation seconds
function BattleScreenState:updateFixed(dt)
  if self._disposed then
    return
  end
  assert(type(dt) == "number" and dt == dt and dt >= 0, "battle updates take accepted seconds")
  local menuGateAtStart = self._menuGateTicks
  self._assets:update()
  if not self._sceneHasBackground then
    local layer = self._assets:sceneLayer()
    if layer ~= nil then
      self._scene:installBackground(layer)
      self._sceneHasBackground = true
    end
  end
  if self._assets:state() == "failed" then
    self._mode = "failed"
    self._error = self._assets:error()
  end
  local measurement = self._measureDisplay()
  assert(measurement ~= nil, "the battle screen requires current display facts")
  local signature = measurement.signature
  if signature ~= nil and signature ~= self._signature then
    if self._signature ~= nil then
      self:cancelPointerCapture()
    end
    self._signature = signature
  end
  if self._session ~= nil and self._mode ~= "failed" then
    self._session:resolve(measurement, self:_snapshot())
  end
  -- One accepted HGSS source tick advances the cue player, the
  -- native animation player, and the visual scene exactly once,
  -- with the menu reveal gate and the selection arrow riding the same
  -- quantum. Phase order per tick is stable: cue admission (a native
  -- start runs here), drained voices, one player step, one scene
  -- step, then completion observation before the next ordered cue.
  -- Draws and polls never advance any of them.
  self._sourceAccum = self._sourceAccum + dt
  local sourceTicks = 0
  while self._sourceAccum + SOURCE_TICK_EPSILON >= BattleScreenState.SOURCE_FRAME do
    self._sourceAccum = self._sourceAccum - BattleScreenState.SOURCE_FRAME
    sourceTicks = sourceTicks + 1
  end
  if self._mode ~= "failed" then
    ---@param key string image key under availability probe
    ---@return boolean available true while the preparation services resolve the key
    local function isAvailable(key)
      return self._assets:drawable(key) ~= nil
    end
    local hadCues = self._timeline:busy()
    for _ = 1, sourceTicks do
      if self._mode == "failed" then
        break
      end
      self:_advanceButtonFeedback()
      self._timeline:update(BattleScreenState.SOURCE_FRAME, isAvailable, function(cue)
        return self:_soundCueComplete(cue)
      end)
      for _, name in ipairs(self._timeline:drainSounds()) do
        if not self:_playCue(name) then
          break
        end
      end
      if self._mode == "failed" then
        break
      end
      self._player:stepSourceTick({ tick = 1 })
      self._scene:stepSourceTick()
      self._iconAnimationTick = self._iconAnimationTick + 1
      self._messageScrollY = math.min(0, self._messageScrollY + 6)
      if self._menuPulseDirection == 0 then
        self._menuPulseBlend = self._menuPulseBlend + 2
        if self._menuPulseBlend >= 17 then
          self._menuPulseBlend = 15
          self._menuPulseDirection = 1
        end
      else
        self._menuPulseBlend = self._menuPulseBlend - 2
        if self._menuPulseBlend <= 0 then
          self._menuPulseBlend = 1
          self._menuPulseDirection = 0
        end
      end
      if menuGateAtStart > 0 and self._menuGateTicks > 0 then
        self._menuGateTicks = self._menuGateTicks - 1
        if self._menuRevealStep < 4 then
          self._menuRevealStep = self._menuRevealStep + 1
        end
      end
    end
    pollNativeEffects(self)
    self:_drain(not hadCues and self._timeline:settled())
    if self._timeline:settled() then
      self._showTimelineMessage = false
    end
    if self._mode == "intro" and self._introBuilt and self._timeline:settled() and self._pendingRequest == nil then
      self._mode = "narration"
    end
    -- A cue-gated portrait that failed upload latches the holder during
    -- the availability probe above: the screen fails once with that
    -- context instead of holding the cue forever. The envelope reports
    -- the failed screen through its existing one-time failure path.
    if self._assets:state() == "failed" then
      self._mode = "failed"
      self._error = self._assets:error()
    end
  end
  if self._mode == "child" and self._subflows:status().active then
    self._subflows:tick()
    self:_pollChild()
    local menus = self._battleMenus
    local child = self._subflows:status().childView
    if type(menus) == "table" and type(child) == "table" and child.kind == "bag" then
      local bag = menus.bag --[[@as table<string, unknown>?]]
      local native = child.native
      if type(bag) == "table" and type(bag.renderer) == "table" and type(native) == "table" then
        bag.renderer:prepare(native)
      end
    end
  end
  -- The parent timeline advances exactly once above before the card is
  -- polled or stepped; no battle choice or other subflow advances while
  -- the card is open. Completion releases the readiness hold, keeping the
  -- static final view and its lease until disposal. A card failure fails
  -- the screen once.
  if self._registrationChild ~= nil and self._mode ~= "failed" then
    self:_pollRegistrationChild(dt)
  end
  if self._mode == "failed" then
    self:_disposeRegistrationChild()
  end
  self:_drainCompletion()
  local activeEffectMode = self._mode == "command" or self._mode == "moves" or self._mode == "target"
  if activeEffectMode then
    if not self._activeEffectRunning then
      self._activeEffectTick = 0
    end
    self._activeEffectTick = self._activeEffectTick + sourceTicks
    self._activeEffectRunning = true
  else
    self._activeEffectTick = 0
    self._activeEffectRunning = false
  end
  local cursorVisible = self._keyboardFocus and self._mode ~= "child"
  if not cursorVisible or not self._cursorWasVisible or self._cursorSelection ~= self._selection then
    self._cursorTick = 0
  else
    self._cursorTick = self._cursorTick + sourceTicks
  end
  self._cursorWasVisible = cursorVisible
  self._cursorSelection = cursorVisible and self._selection or nil
  if self._session ~= nil then
    pcall(function()
      self._session:resolve(measurement, self:_snapshot())
    end)
  end
end

-- Renders the published plan with the displayed view. Read-only: never
-- advances clocks, consumes input, submits, plays a sound, or mutates
-- health. After disposal or before the first plan it draws nothing.
---@param resources table<string, unknown> draw resources carrying the host graphics
function BattleScreenState:draw(resources)
  if self._disposed or self._session == nil then
    return
  end
  assert(type(resources) == "table" and resources.graphics ~= nil, "battle drawing needs its host graphics")
  local ok, plan = pcall(self._session.plan, self._session)
  if not ok or plan == nil then
    return
  end
  -- Scope-counting forwarder over the borrowed namespace: every push and
  -- pop on the battle render path runs through the injected graphics, so
  -- this boundary drains exactly the scopes a failing render leaves
  -- behind. Shared scopes intentionally leak theirs for the host to observe
  -- (see LogicalSurface), and this host drains them; text and window
  -- services hold the real namespace directly but never push, so the count
  -- stays exact. All battle rendering calls graphics dot-style, which the
  -- forwarder preserves. The forwarder persists per host namespace so
  -- caches keyed by the namespace stay warm across frames.
  local hostGraphics = resources.graphics
  local scope = self._graphicsScope
  if scope == nil or scope.host ~= hostGraphics then
    local created = { host = hostGraphics, outstanding = 0 }
    local forwarder = setmetatable({}, { __index = hostGraphics })
    function forwarder.push(...)
      created.outstanding = created.outstanding + 1
      return hostGraphics.push(...)
    end
    function forwarder.pop(...)
      created.outstanding = created.outstanding - 1
      return hostGraphics.pop(...)
    end
    created.graphics = forwarder
    self._graphicsScope = created
    scope = created
  end
  scope.outstanding = 0
  local scoped = scope.graphics
  local owned = {
    graphics = scoped,
    text = self._text,
    windows = self._windows,
    assets = self._assets,
    battleMenus = self._battleMenus,
    doublesHud = type(self._manifest.hud) == "table" and self._manifest.hud.doubles or nil,
    frameKey = self._assets:frameKey(),
    sceneImageKey = self._assets:sceneImage(),
  }
  -- The render runs under a bounded guard with the pushed scope owned
  -- here: the boundary selects the neutral image state (white tint, default
  -- shader and blend, unclipped viewport and depth) so hostile incoming
  -- state never reaches battle pixels, while the caller canvas stays put.
  -- A production-data render failure becomes failed with context instead of
  -- an unhandled host error. Depth rides outside the native stack and is
  -- saved here; restoration runs on success and failure alike, then every
  -- outstanding scope drains, so no nested leak survives. Draws never
  -- substitute, never paint a blank success, and never raise.
  local snapshot = self:_snapshot()
  local graphics = scoped
  local depthMode, depthWrite = graphics.getDepthMode()
  local pushed, pushErr = pcall(graphics.push, "all")
  if not pushed then
    self._mode = "failed"
    self._error = "battle render failed for launch " .. self._launchId .. ": " .. tostring(pushErr)
    return
  end
  local renderOk, renderErr = pcall(function()
    graphics.setColor(1, 1, 1, 1)
    graphics.setShader()
    graphics.setBlendMode("alpha")
    graphics.setScissor()
    graphics.setDepthMode()
    return plan.render(owned, snapshot, plan)
  end)
  local _, _ = pcall(function()
    if depthMode then
      graphics.setDepthMode(depthMode, depthWrite)
    else
      graphics.setDepthMode()
    end
    while scope.outstanding > 0 do
      graphics.pop()
    end
  end)
  if not renderOk then
    self._mode = "failed"
    self._error = "battle render failed for launch " .. self._launchId .. ": " .. tostring(renderErr)
  end
  -- The retained parent view draws first; the card draws its own phase
  -- over it without advancing any state. The completed card keeps its
  -- static final view and terminal cover so the old foe cannot reappear.
  if self._mode ~= "failed" and self._mode ~= "disposed" and self._registrationChild ~= nil then
    local child = self._registrationChild --[[@as table<string, unknown>]]
    local drawFn = child.draw --[[@as fun(self: table<string, unknown>, resources: table<string, unknown>)?]]
    if type(drawFn) ~= "function" then
      self._mode = "failed"
      self._error = "battle registration draw failed for launch " .. self._launchId .. ": missing card draw"
      self:_disposeRegistrationChild()
    else
      local cardOk, cardErr = pcall(drawFn, child, resources)
      if not cardOk then
        self._mode = "failed"
        self._error = "battle registration draw failed for launch " .. self._launchId .. ": " .. tostring(cardErr)
        self:_disposeRegistrationChild()
      end
    end
  end
end

-- Idempotent release of the launch lifetime: owned native handles
-- cancel and retire only their own occurrence, every staged effect media lease
-- releases exactly once, queued input is discarded, and a diagnosed
-- failure persists so late deliveries and stale worker returns stay
-- ignored under the stale launch identity. Borrowed field services
-- stay usable.
function BattleScreenState:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  local wasFailed = self._mode == "failed"
  if self._player ~= nil then
    local keys = {}
    for key in pairs(self._nativeHandles) do
      keys[#keys + 1] = key
    end
    for _, key in ipairs(keys) do
      nativeEffectCancel(self, key, "screen released")
    end
    self._player:dispose()
  end
  self._nativeHandles = {}
  self._liveEffectHandle = nil
  self._liveEffectRecord = nil
  -- A diagnosed failure persists through teardown: disposal keeps the
  -- reported launch, effect, and instruction provenance instead of
  -- reviving the screen or masking it as a clean release.
  if not wasFailed then
    self._mode = "disposed"
  end
  self:cancelPointerCapture()
  self._queue = {}
  -- The card releases before the borrowed presentation context: one
  -- idempotent release on the normal, failure, and disposal paths.
  self:_disposeRegistrationChild()
  -- A disposed screen owns no input and seals nothing, so pending
  -- completion evidence clears with it instead of leaking into a later
  -- answer. Consumed identities persist so late replays stay refused.
  if self._completionChild ~= nil then
    self._completionChild:dispose()
    self._completionChild = nil
  end
  self._completion = nil
  self._completionResult = nil
  if self._timeline ~= nil then
    self._timeline:dispose()
  end
  if self._subflows ~= nil then
    self._subflows:dispose()
  end
  if self._assets ~= nil then
    self._assets:dispose()
  end
  if self._scene ~= nil then
    self._scene:release()
  end
  if self._session ~= nil then
    self._session:dispose()
  end
end

return BattleScreenState
