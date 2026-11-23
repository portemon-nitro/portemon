-- Host lane for one retail EvolutionScene (evolution_scene.c): composes the
-- native evolution child, replays buffered input, dispatches its sequenced
-- effects onto injected printer, audio, Pokepic-pose, and asset ports, steps
-- the source palette fades, reports cry/picture/message/fade completion, and
-- projects the renderer view that BattleRenderer.drawEvolutionScreen draws.
-- The battle screen and field hosts own their own gating and result handling;
-- this module owns no battle, outcome, or field state.
local BattleChildApplications = require("game.hgss.src.battle.BattleChildApplications")
local BattleScene = require("libs.hgss.src.presentation.BattleScene")
local Mon = require("libs.mons.src.Mon")

---@class EvolutionScenePresenter
---@field _opts EvolutionScenePresenter.Options
---@field _child table<string, unknown>? composed evolution child, nil until assets are ready
---@field _pendingInput table<string, unknown>[]? edges buffered before composition
---@field _effectCursor integer count of child effects already dispatched
---@field _message string last printed message text
---@field _printerMessageId integer? timeline message id owned by the active printer
---@field _printerVoices table<integer, table<string, unknown>> callback voices started by the active message
---@field _menuLabels string[]? resolved learn-menu top and bottom labels
---@field _selectors string[]? the old and new Pokepic portrait selectors once the child opens
---@field _pictures table<string, { identity: { combatant: integer, activation: string }, animation: table<string, unknown>, started: boolean }>? Pokepic pose records by role
---@field _evolvedSpecies string? species key the scene evolves into
---@field _waitingVoice table<string, unknown>? cry or fanfare gating the next step
---@field _musicVoice table<string, unknown>? scene music voice
---@field _paletteFade table<string, table<string, unknown>>? active palette channels by name
---@field _disposed boolean
local EvolutionScenePresenter = {}
EvolutionScenePresenter.__index = EvolutionScenePresenter

-- Every sequence the scene voices (evolution_scene.c): music, particle
-- effects, the congratulations and level-up fanfares, and the learn-menu
-- select. Hosts stage their banks before the scene opens.
EvolutionScenePresenter.AUDIO_SEQUENCES = {
  "SEQ_GS_SHINKA",
  "SEQ_SE_DP_W025",
  "SEQ_SE_DP_W060C",
  "SEQ_SE_DP_W062",
  "SEQ_SE_DP_W080",
  "SEQ_ME_SHINKAOME",
  "SEQ_SE_DP_KON",
  "SEQ_ME_LVUP",
  "SEQ_SE_DP_SELECT",
}

-- Buffered edges replayed at composition; later edges are dropped.
local MAX_PENDING_INPUT = 8

---@class EvolutionScenePresenter.Options
---@field source "battle"|"field_level"|"field_item"|"trade" retail scene origin
---@field subject table<string, unknown> committed mon under evolution
---@field context table<string, unknown> frozen evolution trigger context
---@field partySlot integer committed party slot of the subject
---@field sceneId string unique id scoping the scene's Pokepic pose identities
---@field identity { launchId: string, requestId: integer, epoch: integer, controller: string } child identity
---@field monCatalog table<string, unknown> mon catalog
---@field splRandomState table<string, integer> SPL random state for the particle scene
---@field summary table<string, unknown>? field Summary dependencies behind the move-replacement picker
---@field speed integer presentation speed factor; above 1 voice waits never gate progress
---@field voiced boolean true when cries and fanfares are real voices whose completion gates the scene
---@field manifest table<string, unknown> presentation manifest view; receives the staged evolution sections and resolves Pokepic animation
---@field text fun(key: string, substitutions: string[], controls: { controls: table<integer, table<string, unknown>>, glyphCount: integer }): string decodes one staged message into printable text and printer controls
---@field printer BattleTimeline printer port; uses announce, messageId, messageActive, and message
---@field poses BattleScene Pokepic pose port; uses picturePose and remove, and its owner steps stepAnimationPictures once per source tick
---@field audio BattleAudio voice port; uses startMusic, stopVoice, playEffect, playFanfare, and voiceComplete
---@field playCry fun(cue: { kind: "cry", species: string, form: integer?, waitForVoice: boolean }): table<string, unknown>? voices one cry and returns its handle when voiced
---@field assets BattlePresentationAssets|FieldEvolutionAssets asset port; uses ensureEvolution, drawable, addSelectors, and state

---@param opts EvolutionScenePresenter.Options all ports and scene facts; every field is required
---@return EvolutionScenePresenter
function EvolutionScenePresenter.new(opts)
  assert(type(opts) == "table", "evolution presenters require options")
  for _, name in ipairs({
    "source",
    "subject",
    "context",
    "partySlot",
    "sceneId",
    "identity",
    "monCatalog",
    "splRandomState",
    "speed",
    "voiced",
    "manifest",
    "text",
    "printer",
    "poses",
    "audio",
    "playCry",
    "assets",
  }) do
    assert(opts[name] ~= nil, "evolution presenters require " .. name)
  end
  return setmetatable({
    _opts = opts,
    _child = nil,
    _pendingInput = nil,
    _effectCursor = 0,
    _message = "",
    _printerMessageId = nil,
    _printerVoices = {},
    _menuLabels = nil,
    _pictures = nil,
    _selectors = nil,
    _evolvedSpecies = nil,
    _waitingVoice = nil,
    _musicVoice = nil,
    _paletteFade = nil,
    _disposed = false,
  }, EvolutionScenePresenter)
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

---@param self EvolutionScenePresenter
---@param effect table<string, unknown> staged evolution message request
---@return string message with committed mon and catalog move names
---@return table<integer, table<string, unknown>> controls at source glyph boundaries
local function resolveText(self, effect)
  local opts = self._opts
  local catalog = opts.monCatalog --[[@as MonCatalog]]
  local messageId = assert(effect.msg, "evolution messages carry their source id") --[[@as integer]]
  local shownMon = copyValue(opts.subject) --[[@as table<string, unknown>]]
  if messageId ~= 915 and messageId ~= 916 and messageId ~= 917 and messageId ~= 918 and messageId ~= 919 then
    shownMon.species = effect.species or self._evolvedSpecies
  end
  local monName = Mon.displayName(shownMon, catalog)
  local function moveName(moveKey)
    local move = catalog:move(assert(moveKey, "evolution message moves name their catalog key"))
    local name = assert(move.name, "catalog moves carry their localized display name") --[[@as string]]
    return name
  end
  local substitutions = {}
  if messageId == 915 or messageId == 917 or messageId == 919 or messageId == 1194 then
    substitutions = { monName }
  elseif messageId == 918 then
    local species = catalog:species(assert(effect.species, "evolution congratulations name the target species"))
    local targetSpeciesName = assert(species.name, "catalog species carry their display name") --[[@as string]]
    substitutions = { monName, targetSpeciesName }
  elseif messageId == 4 or messageId == 1193 or messageId == 1198 or messageId == 1202 then
    substitutions = { monName, moveName(effect.move) }
  elseif messageId == 1186 or messageId == 1187 or messageId == 1197 then
    substitutions = { moveName(effect.move) }
  elseif messageId == 1200 then
    substitutions = { monName, moveName(effect.move) }
  elseif
    messageId ~= 916
    and messageId ~= 1181
    and messageId ~= 1182
    and messageId ~= 1195
    and messageId ~= 1196
    and messageId ~= 1199
    and messageId ~= 1201
  then
    error("unknown EvolutionScene message id " .. tostring(messageId), 0)
  end
  local controls = { controls = {}, glyphCount = 0 }
  local text = opts.text("evolution/" .. tostring(messageId), substitutions, controls)
  return text, controls.controls
end

---@param self EvolutionScenePresenter
---@param role "old"|"new" source Pokepic under reading
---@return { frame: integer, xOffset: integer, active: boolean, step: integer, delay: integer }? current source pose
local function picturePose(self, role)
  local picture = self._pictures ~= nil and self._pictures[role] or nil
  if picture == nil or not picture.started then
    return nil
  end
  return self._opts.poses:picturePose(picture.identity, picture.animation)
end

-- Resolves every staged image the scene draws. Returns nil while any is
-- pending; raises on a terminal failure.
---@param self EvolutionScenePresenter
---@return table<string, unknown>? particleSet detached SPL scene with uploaded textures
---@return table<string, table<string, unknown>>? cursorAnimations idle and select cursor animations
local function stageImages(self)
  local opts = self._opts
  local assets = opts.assets
  local manifest = opts.manifest
  local evolution, evolutionErr = assets:ensureEvolution()
  if evolutionErr ~= nil then
    error(tostring(evolutionErr), 0)
  end
  if evolution == nil then
    return nil
  end
  if manifest.evolutionParticles == nil then
    manifest.evolutionParticles = evolution.particles
    manifest.evolutionGraphics = evolution.graphics
  end
  local stagedParticles = assert(manifest.evolutionParticles, "evolution stages its SPL scene") --[[@as table<string, unknown>]]
  local particleSet = {
    seed = stagedParticles.seed,
    emitters = copyValue(assert(stagedParticles.emitters, "the SPL scene carries normalized emitters")),
    textures = {},
  } --[[@as table<string, unknown>]]
  local textures = particleSet.textures --[[@as table<integer, table<string, unknown>>]]
  for _, sourceTexture in
    ipairs(stagedParticles.textures --[[@as table<integer, table<string, unknown>>]])
  do
    local textureId = assert(sourceTexture.id, "SPL texture records carry their source identity") --[[@as integer]]
    local drawable, drawableErr = assets:drawable("battle:evolution-particle:" .. tostring(textureId))
    if drawableErr ~= nil then
      error("evolution particle image failed: " .. drawableErr, 0)
    end
    if drawable == nil then
      return nil
    end
    textures[#textures + 1] = { id = textureId, drawable = drawable }
  end
  local graphics = assert(manifest.evolutionGraphics, "evolution stages its screen graphics") --[[@as table<string, unknown>]]
  for _, layer in ipairs({ "main", "sub", "menu" }) do
    local drawable, drawableErr = assets:drawable("battle:evolution:" .. layer)
    if drawableErr ~= nil then
      error("evolution " .. layer .. " image failed: " .. drawableErr, 0)
    end
    if drawable == nil then
      return nil
    end
  end
  local cursor = assert(graphics.cursor, "EvolutionScene graphics carry their menu cursor") --[[@as table<string, unknown>]]
  local cursorAnimations = assert(cursor.animations, "EvolutionScene cursors carry idle and selected animations") --[[@as table<string, unknown>]]
  for _, role in ipairs({ "idle", "select" }) do
    local animation = assert(cursorAnimations[role], "EvolutionScene cursors carry animation " .. role) --[[@as table<string, unknown>]]
    for _, frame in
      ipairs(animation.frames --[[@as table<integer, table<string, unknown>>]])
    do
      local key = assert(frame.drawableKey, "evolution cursor frames carry semantic drawable keys") --[[@as string]]
      local drawable, drawableErr = assets:drawable(key)
      if drawableErr ~= nil then
        error("evolution cursor image failed: " .. drawableErr, 0)
      end
      if drawable == nil then
        return nil
      end
    end
  end
  return particleSet, cursorAnimations
end

-- Composes the evolution child once the late leaf and its images are
-- ready. Returns false while any is pending and raises on a terminal
-- failure; an open presenter returns true without recomposing. Edges
-- buffered earlier replay once, in order, against the new child: a
-- cancel replayed into the entry beat decides nothing, so the holder
-- presses again once the transformation beat opens.
---@return boolean open true once the child is composed
function EvolutionScenePresenter:open()
  assert(not self._disposed, "disposed evolution presenters open nothing")
  if self._child ~= nil then
    return true
  end
  local opts = self._opts
  local particleSet, cursorAnimations = stageImages(self)
  if particleSet == nil then
    return false
  end
  local identity = opts.identity
  local child, childErr = BattleChildApplications.open({
    kind = "evolution",
    purpose = "evolution",
    source = opts.source,
    launchId = identity.launchId,
    requestId = identity.requestId,
    epoch = identity.epoch,
    controller = identity.controller,
    cancellable = opts.source == "battle" or opts.source == "field_level",
    subject = copyValue(opts.subject),
    partySlot = opts.partySlot,
    context = copyValue(opts.context),
  }, {
    monCatalog = opts.monCatalog,
    evolutionParticles = particleSet,
    splRandomState = opts.splRandomState,
    evolutionCursor = cursorAnimations,
    summary = opts.summary,
  })
  if child == nil then
    error(tostring(childErr), 0)
  end
  self._child = child
  local childView = child:draw()
  self._evolvedSpecies = childView.newSpecies
  local selectors = childView.pokepicSelectors --[[@as table<string, string>?]]
  if selectors ~= nil then
    self._selectors = { selectors.old, selectors.new }
    opts.assets:addSelectors(self._selectors)
    self._pictures = {}
    for _, role in ipairs({ "old", "new" }) do
      local selector = assert(selectors[role], "evolution Pokepics carry canonical portrait selectors")
      local attributes = assert(
        BattleScene.pictureAttributes(opts.manifest, selector),
        "verified evolution portraits carry source Pokepic animation metadata: " .. selector
      )
      self._pictures[role] = {
        identity = {
          combatant = role == "old" and -100 or -101,
          activation = opts.sceneId .. ":" .. role,
        },
        animation = assert(attributes.animation, "verified evolution portraits carry their source animation"),
        started = false,
      }
    end
  end
  local pending = self._pendingInput
  self._pendingInput = nil
  for _, event in ipairs(pending or {}) do
    child:input({ event })
  end
  return true
end

-- Routes one mapped semantic input to the scene: confirm, cancel, pointer
-- cancel, navigate, and new touches in lower-screen local coordinates are
-- the scene's edges. Before composition the edge
-- is buffered for exactly-once replay so a held button neither leaks to
-- the host nor misses the animation window behind it.
---@param event table<string, unknown> mapped semantic input
---@return boolean consumed true while the scene owned the input
function EvolutionScenePresenter:input(event)
  assert(not self._disposed, "disposed evolution presenters take no input")
  if
    event.type ~= "confirm"
    and event.type ~= "cancel"
    and event.type ~= "navigate"
    and event.type ~= "pointer_cancel"
    and event.type ~= "pointer_down"
  then
    return false
  end
  local child = self._child
  if child == nil then
    local buffered = self._pendingInput
    if buffered == nil then
      buffered = {}
      self._pendingInput = buffered
    end
    if #buffered < MAX_PENDING_INPUT then
      buffered[#buffered + 1] = event
    end
    return true
  end
  child:input({ event })
  return true
end

---@return boolean complete true when the owned cry or fanfare finished
local function voiceComplete(self)
  local handle = self._waitingVoice
  if handle == nil then
    return true
  end
  local opts = self._opts
  if opts.speed > 1 or opts.audio:voiceComplete(handle) then
    self._waitingVoice = nil
    return true
  end
  return false
end

-- Starts one source palette request per named channel. Returns nothing;
-- the fade runs on stepTick.
---@param self EvolutionScenePresenter
---@param effect table<string, unknown> staged palette request
local function startPaletteFade(self, effect)
  local channels = assert(effect.channels, "evolution palette requests carry their source channels")
  local requestIds = assert(effect.requestIds, "evolution palette requests identify each source manager request")
  local active = self._paletteFade or {} ---@type table<string, { color: string, coefficient: integer, target: integer, interval: integer, wait: integer, requestId: integer }>
  for _, channelName in ipairs({ "scene", "pictures" }) do
    local spec = channels[channelName]
    if spec ~= nil then
      local color = assert(spec.color, "palette channels name their blend color")
      assert(color == "black" or color == "white", "evolution fades target black or white")
      local from = assert(spec.from, "palette channels carry their source coefficient")
      local to = assert(spec.to, "palette channels carry their target coefficient")
      assert(
        type(from) == "number" and from % 1 == 0 and from >= 0 and from <= 16,
        "palette start coefficients stay within the source 0..16 range"
      )
      assert(
        type(to) == "number" and to % 1 == 0 and to >= 0 and to <= 16,
        "palette end coefficients stay within the source 0..16 range"
      )
      local interval = channelName == "scene" and spec.rate or spec.duration
      assert(
        type(interval) == "number" and interval % 1 == 0 and interval >= 0,
        "palette channels carry a non-negative source interval"
      )
      active[channelName] = {
        color = color,
        coefficient = from --[[@as integer]],
        target = to --[[@as integer]],
        interval = interval --[[@as integer]],
        wait = 0,
        requestId = assert(requestIds[channelName], "palette channels carry their manager request id") --[[@as integer]],
      }
    end
  end
  assert(next(active) ~= nil, "evolution palette requests fade at least one channel")
  self._paletteFade = active
end

---@param self EvolutionScenePresenter
---@param effect table<string, unknown> sequenced child effect under dispatch
local function dispatchEffect(self, effect)
  local opts = self._opts
  local audio = opts.audio
  if effect.kind == "message" then
    local controls
    self._message, controls = resolveText(self, effect)
    self._printerVoices = {}
    self._printerMessageId = opts.printer:announce(self._message, false, 0, controls)
  elseif effect.kind == "menu" then
    local options = assert(effect.options, "evolution menus carry both source options") --[[@as integer[] ]]
    assert(#options == 2, "evolution menus carry top and bottom options")
    self._menuLabels = {
      (resolveText(self, { msg = options[1], move = effect.move })),
      (resolveText(self, { msg = options[2], move = effect.move })),
    }
  elseif effect.kind == "cry" then
    local role = effect.species == self._evolvedSpecies and "new" or "old"
    local picture = self._pictures ~= nil and self._pictures[role] or nil
    if picture ~= nil then
      opts.poses:remove(picture.identity.combatant, picture.identity.activation)
      opts.poses:picturePose(picture.identity, picture.animation)
      picture.started = true
    end
    local handle = opts.playCry({
      kind = "cry",
      species = effect.species,
      form = effect.form,
      waitForVoice = opts.voiced,
    })
    if opts.voiced then
      self._waitingVoice = handle
    end
  elseif effect.kind == "music_direct" then
    self._musicVoice = audio:startMusic(assert(effect.name))
  elseif effect.kind == "stop_bgm" then
    if self._musicVoice ~= nil then
      audio:stopVoice(self._musicVoice)
      self._musicVoice = nil
    end
  elseif effect.kind == "sound" then
    audio:playEffect(assert(effect.name))
  elseif effect.kind == "fanfare_wait" then
    local voice = audio:playFanfare(assert(effect.name))
    if opts.voiced then
      self._waitingVoice = voice
    end
  elseif effect.kind == "palette" then
    startPaletteFade(self, effect)
  end
end

-- Dispatches newly sequenced child effects in order, stopping after an
-- effect that holds the scene on a printer or palette fade.
---@param self EvolutionScenePresenter
---@return boolean drained true when no effect holds the scene
local function dispatchEffects(self)
  local child = self._child --[[@as table<string, unknown>]]
  local effects = child:effects()
  while self._effectCursor < #effects do
    local effect = effects[self._effectCursor + 1]
    assert(type(effect) == "table", "evolution effects are records")
    dispatchEffect(self, effect)
    self._effectCursor = self._effectCursor + 1
    if self._paletteFade ~= nil or self._printerMessageId ~= nil then
      return false
    end
  end
  return true
end

-- Releases the scene once the exact announced line finished its glyph
-- reveal and post-print wait.
---@param self EvolutionScenePresenter
---@return boolean complete true when no printer owns the scene
local function completePrinter(self)
  local messageId = self._printerMessageId
  if messageId == nil then
    return true
  end
  local printer = self._opts.printer
  if printer:messageId() ~= messageId or printer:messageActive() then
    return false
  end
  self._printerMessageId = nil
  self._printerVoices = {}
  self._message = printer:message()
  local child = self._child --[[@as table<string, unknown>]]
  child:completeMessage()
  return true
end

-- Runs one source message callback control at its glyph boundary. Pass
-- this to the timeline as its printer-callback owner. Start callbacks
-- are one-shot; WAIT callbacks query the voice started earlier in the
-- same message.
---@param messageId integer owning timeline message identity
---@param callback integer source callback id 1..5
---@param controlIndex integer occurrence within the staged message
---@return boolean complete whether a WAIT callback has released
function EvolutionScenePresenter:printerCallback(messageId, callback, controlIndex)
  assert(self._printerMessageId == messageId, "evolution callbacks belong to their active message")
  local voices = self._printerVoices
  local audio = self._opts.audio
  local fast = self._opts.speed > 1
  if callback == 1 or callback == 2 then
    if fast then
      return true
    end
    local kind = callback == 1 and "effect" or "fanfare"
    for _, voice in pairs(voices) do
      if voice.kind == kind and not audio:voiceComplete(voice) then
        return false
      end
    end
    return true
  elseif callback == 3 then
    assert(voices[controlIndex] == nil, "evolution fanfare callback starts once")
    voices[controlIndex] = audio:playFanfare("SEQ_ME_SHINKAOME")
  elseif callback == 4 then
    assert(voices[controlIndex] == nil, "evolution sound callback starts once")
    voices[controlIndex] = audio:playEffect("SEQ_SE_DP_KON")
  elseif callback == 5 then
    assert(voices[controlIndex] == nil, "level-up fanfare callback starts once")
    voices[controlIndex] = audio:playFanfare("SEQ_ME_LVUP")
  else
    error("unsupported evolution printer callback " .. tostring(callback), 0)
  end
  return true
end

-- True once the prepared assets also resolve both Pokepic portraits as
-- drawable images: prepared pages may still be uploading, and the scene
-- never plays a beat over a missing portrait. Raises on a terminal image
-- failure.
---@param self EvolutionScenePresenter
---@return boolean
local function assetsReady(self)
  local assets = self._opts.assets
  local state = assets:state()
  if state == "failed" then
    error(assert(assets:error(), "failed evolution assets carry a diagnostic"), 0)
  end
  if state ~= "ready" then
    return false
  end
  local selectors = self._selectors
  if selectors == nil then
    return true
  end
  for _, selector in ipairs(selectors) do
    local drawable, drawableErr = assets:drawable("mon:" .. selector)
    if drawableErr ~= nil then
      error("evolution portrait image failed: " .. drawableErr, 0)
    end
    if drawable == nil then
      return false
    end
  end
  return true
end

-- Advances the scene once: the child steps its clocks, holds release
-- when their printer, voice, or Pokepic pose finished, and sequenced
-- effects dispatch. Opens the child first while its assets are pending.
-- Raises on any scene failure.
---@return table<string, unknown>? result sealed child result (`evolution_complete` with `staged`, or `evolution_cancelled` with `reason`), nil while the scene runs
function EvolutionScenePresenter:advance()
  assert(not self._disposed, "disposed evolution presenters advance nothing")
  if not self:open() or not assetsReady(self) then
    return nil
  end
  local child = self._child --[[@as table<string, unknown>]]
  child:stepPresentationSourceTick(1)
  if not voiceComplete(self) or not completePrinter(self) or not dispatchEffects(self) then
    return nil
  end
  local status = child:status()
  if status.cryPending and voiceComplete(self) then
    child:completeCry()
  end
  if status.picturePending then
    local pose = picturePose(self, assert(status.pictureRole))
    if pose == nil or not pose.active then
      child:completePicture()
    end
  end
  child:stepSourceTick(1)
  if not dispatchEffects(self) or not voiceComplete(self) then
    return nil
  end
  return child:takeResult()
end

-- Advances the palette fades once per accepted source tick. Scene fades
-- step by two every `rate + 1` ticks; Pokepic fades by one every
-- `duration + 1` ticks, each reporting completion to the child. The host
-- steps the Pokepic poses in the same tick.
function EvolutionScenePresenter:stepTick()
  assert(not self._disposed, "disposed evolution presenters step nothing")
  local child = self._child
  local channels = self._paletteFade
  if child == nil or channels == nil then
    return
  end
  local completed = {} ---@type { channel: string, requestId: integer }[]
  for channelName, channel in pairs(channels) do
    local target = channel.target --[[@as integer]]
    local coefficient = channel.coefficient --[[@as integer]]
    if coefficient ~= target then
      local wait = channel.wait --[[@as integer]]
      if wait > 0 then
        channel.wait = wait - 1
      else
        local step = channelName == "scene" and 2 or 1
        if coefficient < target then
          coefficient = math.min(target, coefficient + step)
        else
          coefficient = math.max(target, coefficient - step)
        end
        channel.coefficient = coefficient
        channel.wait = channel.interval
        if coefficient == target then
          completed[#completed + 1] = {
            channel = channelName,
            requestId = channel.requestId --[[@as integer]],
          }
        end
      end
    end
  end
  for _, request in ipairs(completed) do
    channels[request.channel] = nil
    child:completePaletteFade(request.channel, request.requestId)
  end
  if next(channels) == nil then
    self._paletteFade = nil
  end
end

---@return boolean open true while the Summary move picker owns the scene
function EvolutionScenePresenter:summaryOpen()
  return self._child ~= nil and self._child:status().phase == "summary"
end

---@return boolean pending true while the scene waits on the learned-move picker
function EvolutionScenePresenter:learnPending()
  return self._child ~= nil and self._child:learnPrompt() ~= nil
end

-- Projects the view BattleRenderer.drawEvolutionScreen draws: the child's
-- presentation joined with the printer text, palette fades, Pokepic poses,
-- learn-menu labels, and the staged menu text palette. Before composition
-- it is a non-interactive placeholder carrying no presentation.
---@return table<string, unknown> evolution view with `kind = "evolution"`
function EvolutionScenePresenter:view()
  local child = self._child
  if child == nil then
    return {
      kind = "evolution",
      purpose = "evolution",
      interactive = false,
      cancellable = false,
      application = "evolution",
      phase = "sequence",
    }
  end
  local opts = self._opts
  local inner = child:status()
  local presentation = child:draw()
  presentation.assetsReady = assetsReady(self)
  local graphics = assert(opts.manifest.evolutionGraphics, "evolution carries its staged screen graphics") --[[@as table<string, unknown>]]
  local menuTextPalette = assert(graphics.menuTextPalette, "evolution carries EvolutionScene's menu text palette") --[[@as table<string, unknown>]]
  presentation.menuTextPalette = copyValue(assert(menuTextPalette.colors))
  local scene = assert(presentation.presentation, "evolution children carry their renderer state")
  if self._printerMessageId ~= nil then
    local printer = opts.printer
    scene.message = printer:messageId() == self._printerMessageId and printer:message() or ""
  else
    scene.message = self._message
  end
  local fade = self._paletteFade
  scene.scenePaletteFade = fade ~= nil and copyValue(fade.scene) or nil
  scene.picturePaletteFade = fade ~= nil and copyValue(fade.pictures) or nil
  scene.paletteFadeComplete = fade == nil
  if type(presentation.learnMenu) == "table" and self._menuLabels ~= nil then
    presentation.learnMenu.topText = self._menuLabels[1]
    presentation.learnMenu.bottomText = self._menuLabels[2]
  end
  for _, role in ipairs({ "old", "new" }) do
    local pose = picturePose(self, role)
    scene[role .. "PictureFrame"] = pose ~= nil and pose.frame or 0
    scene[role .. "PictureActive"] = pose ~= nil and pose.active or false
    scene[role .. "PictureXOffset"] = pose ~= nil and pose.xOffset or 0
  end
  return {
    kind = "evolution",
    purpose = "evolution",
    interactive = true,
    cancellable = inner.canCancel == true,
    application = "evolution",
    phase = inner.phase,
    learn = child:learnPrompt(),
    presentation = presentation,
  }
end

-- Releases the child. Safe to call once; later calls are no-ops.
function EvolutionScenePresenter:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  if self._child ~= nil then
    self._child:dispose()
    self._child = nil
  end
end

return EvolutionScenePresenter
