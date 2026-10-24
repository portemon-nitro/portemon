-- Battle audio operations through the real presented-battle composition.
--
-- The battle must play its native sounds at their source-defined moments:
-- the chosen encounter track rises on the exact transition tick with only
-- its own staged closure, send-out cries cover both battlers, move and
-- effect cues carry their source mix parameters, one-shot cues start
-- exactly once across redraws and repeated deliveries, missing or rejected
-- sounds fail the launch with their identity instead of succeeding
-- silently, every outcome hands music back exactly once without retiring
-- the shared engine, and quiet visual modes keep every mandatory cue with
-- no substitute sounds.
--
-- Operation traces come from the real envelope, screen, timeline, and
-- coordinator path; sample proof comes from the same normalized engine
-- classes the production composition uses, played over synthetic staged
-- bundles with known audible and known silent fixtures. A recording sink
-- alone never proves audibility, and a skipped capability never counts as
-- sample evidence. Synthetic fixtures only: no commercial bytes enter the
-- repository.

local Assert = require("tests.support.Assert")
local AudioAssetProvider = require("libs.hgss.src.audio.AudioAssetProvider")
local AudioFixture = require("tests.support.AudioFixture")
local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
local BattleTimeline = require("game.hgss.src.battle.BattleTimeline")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local FieldBattlePresentation = require("game.hgss.src.field.FieldBattlePresentation")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldRuntime = require("game.hgss.src.field.FieldRuntime")
local GameSound = require("libs.hgss.src.audio.GameSound")
local PlayTime = require("libs.hgss.src.save.PlayTime")
local ScreenTopology = require("libs.ui.src.ScreenTopology")
local SequencePlayer = require("libs.nds.src.nitro.sound.SequencePlayer")
local SessionFixture = require("libs.battle.tests.session_fixture")
local VoiceMixer = require("libs.nds.src.nitro.sound.VoiceMixer")

local T = {}

local TICK = 1 / 30
local FULL_COVER = 16
local SAMPLE_RATE = 48000

---@param signature string display signature under measurement
---@return table caller-owned dual-surface display facts
local function dualMeasurement(signature)
  return {
    width = 256,
    height = 384,
    topology = ScreenTopology.dualDisplay(
      { id = "main", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
      { id = "lower", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" },
      signature
    ),
    pixelRatio = 1,
    signature = signature,
  }
end

---@return table recording text boundary keeping every drawn string
local function recordingText()
  local text = { draws = {} }
  function text.measure(content)
    return { width = 8 * #tostring(content), height = 16 }
  end
  function text.drawText(content, x, y)
    text.draws[#text.draws + 1] = { content = tostring(content), x = x, y = y }
  end
  return text
end

---@return table recording window-frame boundary
local function recordingWindows()
  local windows = { calls = {} }
  function windows.drawWindow(box, frameKey, background)
    windows.calls[#windows.calls + 1] = { box = box, frame = frameKey, background = background }
  end
  function windows.drawApplicationFrame(box, frameKey)
    windows.calls[#windows.calls + 1] = { box = box, frame = frameKey }
  end
  return windows
end

-- A method-faithful cue double: every cue records its receiver so the
-- tests can tell a correctly bound dispatch from a free call, and every
-- entry records the exact arguments the sink received so missing source
-- parameters fail loudly instead of hiding behind a bare call count.
-- Cry entries record the full voice argument list the engine port
-- carries: species, pattern, form, mode, pan, volume, and pitch.
---@param log table recorded cue operations under inspection
---@return table cue double with bound play and playCry
local function richCueDouble(log)
  local controller = {}
  function controller:play(symbol)
    log[#log + 1] = { method = "play", receiver = self, symbol = symbol }
    return true
  end
  function controller:playCry(species, pattern, form, mode, pan, volume, pitch)
    log[#log + 1] = {
      method = "playCry",
      receiver = self,
      species = species,
      pattern = pattern,
      form = form,
      mode = mode,
      pan = pan,
      volume = volume,
      pitch = pitch,
    }
    return true
  end
  return controller
end

-- A cue double whose dispatch answers without throwing: the recorded
-- answer stands in for a silent engine that accepts a cue and never
-- starts it. The launch must treat the answer as a failure, never as a
-- successful silent cue.
---@param log table recorded cue operations under inspection
---@param answer unknown non-throwing dispatch answer under test
---@return table cue double answering without throwing
local function flatCueDouble(log, answer)
  local controller = {}
  function controller:play(symbol)
    log[#log + 1] = { method = "play", receiver = self, symbol = symbol }
    return answer
  end
  function controller:playCry(species, pattern, form, mode, pan, volume, pitch)
    log[#log + 1] = {
      method = "playCry",
      receiver = self,
      species = species,
      pattern = pattern,
      form = form,
      mode = mode,
      pan = pan,
      volume = volume,
      pitch = pitch,
    }
    return answer
  end
  return controller
end

---@param versionId string
---@return table save entry the production runtime boots
local function validEntry(versionId)
  return {
    saveId = "save-00000001",
    versionId = versionId,
    location = {
      mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F",
      fieldX = 6,
      fieldZ = 6,
      facing = "south",
    },
    playerData = {
      profile = {
        name = "GOLD",
        rivalName = "Silver",
        gender = 0,
        trainerId = 1,
        money = 3000,
        badges = 0,
        nationalDex = false,
        runningShoes = false,
        runningShoesLock = false,
      },
      options = { textSpeed = "mid", textFrame = 0 },
    },
    fieldTravel = { lastHealSpawn = "SPAWN_NEW_BARK" },
    fashionCase = require("libs.hgss.src.save.FashionCaseState").empty(),
    playTime = PlayTime.new(),
    worldState = FieldEventState.new(),
    mons = require("tests.support.MonBucket").emptyForVersion(versionId),
    bag = require("libs.hgss.src.save.BagSave").empty(),
    mart = require("libs.hgss.src.save.MartSave").empty(),
  }
end

---@return table headless production runtime options under test driving
local function runtimeOptions()
  local Fixture = require("tests.support.FieldStatePresentationFixture")
  return { presentation = false, derivedAssets = Fixture.iconHost().derivedAssets }
end

---@param versionId string
---@return FieldRuntime live headless production runtime with a stocked party
local function bootRuntime(versionId)
  local runtime = FieldRuntime.new(validEntry(versionId), runtimeOptions())
  Assert.isTrue(runtime.monService:giveMon({ species = "CHIKORITA", level = 9 }), "the route needs its lead")
  Assert.isTrue(runtime.monService:giveMon({ species = "CHIKORITA", level = 9 }), "the route needs its reserve")
  return runtime
end

---@param runtime FieldRuntime
---@param versionId string
---@param measurement table
---@param audio table envelope cue double under borrowing
---@return table envelope
---@return integer binding
---@return table doubles
local function bindEnvelope(runtime, versionId, measurement, audio)
  local doubles = { audio = audio, windows = recordingWindows(), text = recordingText() }
  local envelope = FieldBattlePresentation.new({
    cacheFs = CacheFs.forVersion(versionId),
    windows = doubles.windows,
    text = doubles.text,
    audio = doubles.audio,
    itemCatalog = runtime.itemCatalog,
    monCatalog = runtime.monCatalog,
    measureDisplay = function()
      return measurement
    end,
  })
  local ports = {}
  local factory = envelope:factory()
  local binding = runtime:bindBattlePresentation(function(descriptor)
    local port = factory(descriptor)
    ports[#ports + 1] = port
    return port
  end)
  doubles.ports = ports
  return envelope, binding, doubles
end

---@param runtime FieldRuntime
---@param envelope table
local function waitConstructed(runtime, envelope)
  local ticks = 0
  while runtime.battleCoordinator:activeBattle() == nil and ticks < 900 do
    runtime:update(1 / 30)
    envelope:updateFixed(TICK)
    ticks = ticks + 1
  end
  Assert.notNil(runtime.battleCoordinator:activeBattle(), "the covered launch constructs its battle")
end

---@param runtime FieldRuntime
---@param envelope table
---@param ticks integer fixed ticks to advance under test driving
local function pump(runtime, envelope, ticks)
  for _ = 1, ticks do
    runtime:update(1 / 30)
    envelope:updateFixed(TICK)
  end
end

-- Drives one launch until the screen exposes its command decision,
-- acknowledging opening narration through the real envelope input path.
---@param runtime FieldRuntime
---@param envelope table
---@return table live screen at its command decision
local function driveToCommand(runtime, envelope)
  for _ = 1, 1500 do
    local screen = envelope:liveScreen()
    if screen ~= nil then
      local shown = screen:status()
      if shown.mode == "failed" then
        error("the presented battle failed before its command: " .. tostring(shown.error), 0)
      end
      if shown.mode == "command" then
        return screen
      end
      if shown.mode == "intro" or shown.mode == "narration" or shown.mode == "outcome" then
        envelope:input({ { type = "confirm" } })
      end
    end
    runtime:update(1 / 30)
    envelope:updateFixed(TICK)
  end
  error("the presented battle never reached its command", 0)
end

-- Waits for the source menu input gate to open before answering: the
-- production command menu drops input during its entry travel, so a
-- reply or cancel sent earlier would never reach the cue sink.
---@param runtime FieldRuntime
---@param envelope table
local function waitMenuInput(runtime, envelope)
  for _ = 1, 300 do
    local screen = envelope:liveScreen()
    if screen ~= nil and screen:view().menuInputEnabled then
      return
    end
    runtime:update(1 / 30)
    envelope:updateFixed(TICK)
  end
  error("the source menu input gate never opened", 0)
end

---@param actor table addressed combatant under test driving
---@return table single-target strike at the opposing singles slot
local function strike(actor)
  return { actor = actor, kind = "attack", payload = { moveSlot = 0, target = { kind = "position", position = 2 } } }
end

-- Answer every exposed request with a strike, acknowledging narration
-- through the real envelope input path exactly as a player would.
---@param runtime FieldRuntime
---@param request table pending player decision under answering
---@return table decision choice for the open request
local function sparringChoose(runtime, request)
  local actor = assert(request.actors[1], "every player decision addresses its combatant")
  local legal = request.legalChoices
  local kinds = {}
  if type(legal) == "table" and type(legal.kinds) == "table" then
    for _, kind in ipairs(legal.kinds) do
      kinds[kind] = true
    end
  end
  if kinds["attack"] == true then
    return strike(actor)
  end
  local battle = assert(runtime.battleCoordinator:activeBattle(), "fragments answer through the live battle")
  local options = battle:decisionOptions(request.requestId)
  assert(options ~= nil, "options project for the open request")
  for _, entry in ipairs(options.actors) do
    for _, choice in ipairs(entry.choices or {}) do
      if choice.enabled == true and choice.choice ~= nil then
        return choice.choice
      end
    end
  end
  error("no prepared fragment answers the request", 0)
end

-- True while the open kernel request admits a choice of the wanted kind.
---@param request table open kernel request under inspection
---@param wanted string choice kind under test
---@return boolean admitted true while the kind is legal now
local function admitsKind(request, wanted)
  local legal = request.legalChoices
  if type(legal) ~= "table" or type(legal.kinds) ~= "table" then
    return false
  end
  for _, kind in ipairs(legal.kinds) do
    if kind == wanted then
      return true
    end
  end
  return false
end

-- Answers every kernel request through the choosing function until the
-- presented lifetime settles, acknowledging narration through the real
-- envelope input path.
---@param runtime FieldRuntime
---@param envelope table
---@param choose fun(runtime: FieldRuntime, request: table): table choice for the open request
---@param budget integer tick budget under driving
---@return integer answered player turns before the lifetime settled
local function settle(runtime, envelope, choose, budget)
  local turns, ticks = 0, 0
  while runtime.battleCoordinator:activeBattle() ~= nil and ticks < budget do
    local battle = runtime.battleCoordinator:activeBattle()
    local current = battle:status()
    if current.phase == "failed" then
      error("the presented battle failed: " .. tostring(current.error), 0)
    end
    if current.phase == "running" and current.request ~= nil then
      turns = turns + 1
      local answer = choose(runtime, current.request)
      local choices = answer
      if type(answer) == "table" and answer.kind ~= nil then
        choices = { answer }
      end
      local accepted, replyErr = battle:submit(SessionFixture.replyFor(current.request, choices))
      Assert.isTrue(accepted, "a legal presented decision is accepted: " .. tostring(replyErr))
    end
    local screen = envelope:liveScreen()
    if screen ~= nil then
      local shown = screen:status()
      if shown.mode == "intro" or shown.mode == "narration" or shown.mode == "outcome" then
        envelope:input({ { type = "confirm" } })
      end
    end
    runtime:update(1 / 30)
    envelope:updateFixed(TICK)
    ticks = ticks + 1
  end
  Assert.isNil(runtime.battleCoordinator:activeBattle(), "answered decisions settle the owned presented lifetime")
  return turns
end

-- Answers every kernel request with flight when legal and strikes
-- otherwise, until the presented lifetime settles.
---@param runtime FieldRuntime
---@param request table pending player decision under answering
---@return table decision choice for the open request
local function fleeingChoose(runtime, request)
  local actor = assert(request.actors[1], "every player decision addresses its combatant")
  if admitsKind(request, "run") then
    return { actor = actor, kind = "run", payload = {} }
  end
  return sparringChoose(runtime, request)
end

---@return string[] ready version identities under the private cache
local function readyVersions()
  local GameVersion = require("romdump.src.source.GameVersion")
  local RomImporter = require("romdump.src.source.RomImporter")
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      return { versionId }
    end
  end
  error("presented battle audio needs a ready versioned cache", 0)
end

---@param versionId string
---@return table staged audio role symbols by role
local function stagedRoleSymbols(versionId)
  local manifest = BattlePresentationCache.load(CacheFs.forVersion(versionId))
  Assert.isTrue(type(manifest.audioRoles) == "table", "the staged manifest carries its audio roles")
  return manifest.audioRoles
end

---@return integer canonical cry identity for a catalog species
---@param catalog table borrowed mon catalog under lookup
---@param species string catalog species under lookup
local function cryIdentity(catalog, species)
  local facts = catalog:species(species)
  Assert.isTrue(type(facts) == "table" and type(facts.nativeId) == "number", "cries name a cataloged species: " .. species)
  return facts.nativeId
end

---@param log table recorded cue operations under inspection
---@param method string operation method under counting
---@return integer matching operations
local function countMethod(log, method)
  local total = 0
  for _, entry in ipairs(log) do
    if entry.method == method then
      total = total + 1
    end
  end
  return total
end

---@param log table recorded cue operations under inspection
---@param species integer cry identity under counting
---@return integer matching cry operations
local function countCries(log, species)
  local total = 0
  for _, entry in ipairs(log) do
    if entry.method == "playCry" and entry.species == species then
      total = total + 1
    end
  end
  return total
end


-- Wraps the live field audio service with counting recorders so music
-- selection, starts, and policy transfers stay observable without
-- changing what the service plays. Every wrapper delegates to the
-- original behavior.
---@param audio table live field audio service under observation
---@param trace table recorded music operations under inspection
local function watchMusic(audio, trace)
  local innerSuspend = audio.suspendFieldPolicy
  local innerResume = audio.resumeFieldPolicy
  local innerPlayMusic = audio.playMusic
  local innerStopMusic = audio.stopMusic
  local innerFanfare = audio.playFanfare
  function audio:suspendFieldPolicy(token)
    trace.suspends = trace.suspends + 1
    return innerSuspend(self, token)
  end
  function audio:resumeFieldPolicy(token, restore)
    trace.resumes = trace.resumes + 1
    trace.lastRestore = restore
    return innerResume(self, token, restore)
  end
  function audio:playMusic(reference)
    trace.starts[#trace.starts + 1] = { symbol = reference }
    return innerPlayMusic(self, reference)
  end
  function audio:stopMusic()
    trace.stops = trace.stops + 1
    return innerStopMusic(self)
  end
  function audio:playFanfare(reference)
    trace.fanfares[#trace.fanfares + 1] = { symbol = reference }
    return innerFanfare(self, reference)
  end
end

---@return table fresh music trace under observation
local function freshMusicTrace()
  return { suspends = 0, resumes = 0, lastRestore = nil, starts = {}, stops = 0, fanfares = {} }
end

---@param problems string[] collected contract misses under reporting
---@param condition boolean true when the observed behavior holds
---@param message string contract miss naming the missing behavior
local function check(problems, condition, message)
  if not condition then
    problems[#problems + 1] = message
  end
end

---@param problems string[] collected contract misses under reporting
local function report(problems)
  if #problems > 0 then
    error("battle audio missed its native behavior:\n- " .. table.concat(problems, "\n- "), 0)
  end
end

---@param envelope table presented envelope under inspection
---@return string? battle-music start note, nil once the diagnostic is removed
local function startedNote(envelope)
  local ok, note = pcall(function()
    return envelope:musicNote()
  end)
  if not ok then
    return nil
  end
  return note
end

---@param problems string[] collected contract misses under reporting
---@param envelope table presented envelope under inspection
---@param expected string expected started track symbol under the old diagnostic
---@param versionId string version identity under reporting
---@param where string leg name under reporting
local function checkStartedNote(problems, envelope, expected, versionId, where)
  local note = startedNote(envelope)
  if note == nil then
    return
  end
  check(
    problems,
    note == "started:" .. expected,
    "the " .. where .. " music start succeeds on " .. versionId .. ", not " .. tostring(note)
  )
end

-- A synthetic normalized bundle shaped like the production audio cache:
-- one finite voice per battle case over distinct waves, plus one
-- legitimately silent control whose program plays no voice. Every case
-- resolves through the real provider, player, and mixer, so rendered
-- output proves the shared engine can voice these shapes audibly.
---@param selectSymbol string staged menu role symbol under voicing
---@return table bundle the ready-cache writer consumes
local function caseBundle(selectSymbol)
  local keys = {}
  for index = 1, 8 do
    keys[index] = AudioFixture.key(100 + index)
  end
  local waves = {
    { 1000, 2000, 3000, 4000, 5000, 6000, 7000, 8000 },
    { 8000, 7000, 6000, 5000, 4000, 3000, 2000, 1000 },
    { 4000, -4000, 4000, -4000, 4000, -4000 },
    { 2000, 4000, 6000, 8000, 6000, 4000, 2000, 1000 },
    { 6000, 6000, -6000, -6000, 6000, 6000 },
    { 1500, 3000, 4500, 6000, 7500, 9000 },
    { 9000, 7500, 6000, 4500, 3000, 1500 },
    { 0, 0, 0, 0 },
  }
  local symbols = {
    selectSymbol,
    "synthetic-battle-move",
    "synthetic-battle-cry-voice",
    "synthetic-battle-fanfare",
    "synthetic-battle-impact",
    "synthetic-battle-progression",
    "synthetic-battle-menu-cancel",
    "synthetic-battle-silent-control",
  }
  local sequences, banks, samples, metadata = {}, {}, {}, {}
  local instruments = {}
  for index, symbol in ipairs(symbols) do
    local playerId = index + 1
    local instructions
    if symbol == "synthetic-battle-silent-control" then
      instructions = {
        { op = "program", program = 0 },
        { op = "end" },
      }
    else
      instructions = {
        { op = "program", program = 0 },
        { op = "note", key = 60, velocity = 127, duration = 8 },
        { op = "end" },
      }
    end
    sequences[index - 1] = AudioFixture.sequence(index - 1, symbol, 12, playerId, {
      entry = 1,
      initialTrackMask = 0x0001,
      instructions = instructions,
    }, {
      id = playerId,
      initialVolume = 127,
      playerPriority = 64,
      channelPriority = 64,
    })
    instruments[index - 1] = {
      kind = "direct",
      voice = {
        generator = { kind = "sample", sample = keys[index] },
        originalKey = 60,
        envelope = { attack = 0, decay = 0, sustain = 127, release = 0 },
        pan = 64,
      },
    }
    samples[keys[index]] = AudioFixture.pcm16le(waves[index])
    metadata[keys[index]] = AudioFixture.sampleMetadata(keys[index], {
      frames = #waves[index],
      loop = { startFrame = 0, endFrame = #waves[index] },
    })
  end
  local bundle = AudioFixture.bundle()
  local indexSequences, indexPlayers, bySymbol = {}, {}, {}
  for id, sequence in pairs(sequences) do
    indexSequences[id] = { id = id, symbol = sequence.symbol, bankId = sequence.bankId, playerId = sequence.player.id }
    indexPlayers[sequence.player.id] = { id = sequence.player.id, maxSequences = 16, channelMask = 0xFFFF }
    bySymbol[sequence.symbol] = id
  end
  bundle.index.sequences = indexSequences
  bundle.index.players = indexPlayers
  bundle.index.banks = { [12] = { id = 12, symbol = "BANK_TEST" } }
  bundle.index.sequenceBySymbol = bySymbol
  bundle.index.bankBySymbol = { BANK_TEST = 12 }
  bundle.sequences = sequences
  bundle.banks = { [12] = AudioFixture.bank(12, "BANK_TEST", nil, instruments) }
  bundle.samples = samples
  bundle.sampleMetadata = metadata
  return bundle
end

-- Composes the real normalized engine over a synthetic staged bundle:
-- the same provider, sequence player, mixer, and semantic facade classes
-- the production composition wires, so rendered samples prove these
-- operation shapes voice audibly through the shared path.
---@param selectSymbol string staged menu role symbol under voicing
---@return table sound semantic facade under test driving
---@return table player engine player behind rendering
local function composeCaseEngine(selectSymbol)
  local provider = AudioAssetProvider.new(AudioFixture.readyCache(caseBundle(selectSymbol)))
  ---@cast provider AudioAssetProvider
  local mixer = VoiceMixer.new({ sampleRate = SAMPLE_RATE })
  local player = SequencePlayer.new({ sampleRate = SAMPLE_RATE, mixer = mixer, provider = provider })
  ---@cast player SequencePlayer
  local sound = GameSound.new({ provider = provider, player = player, completionAvailable = true })
  return sound, player
end

---@param pcm table interleaved stereo samples under measurement
---@param frames integer frames under measurement
---@return table left-channel samples
local function leftChannel(pcm, frames)
  local out = {}
  for index = 1, frames do
    out[index] = pcm[index * 2 - 1]
  end
  return out
end

---@param pcm table samples under measurement
---@return number peak absolute sample
local function peakAbs(pcm)
  local peak = 0
  for _, value in ipairs(pcm) do
    local magnitude = math.abs(value)
    if magnitude > peak then
      peak = magnitude
    end
  end
  return peak
end

-- The cold envelope: no staged manifest, so the loader falls back to its
-- planning inventory with known scenes and no audio roles. The covering
-- host drives the envelope to full cover exactly like the production
-- driver, while the music double records whether a start was ever
-- attempted and the notify log records whether the launch failed loudly.
---@return table envelope cold presented envelope under test driving
---@return table musicLog recorded music operations under inspection
---@return table notifies recorded host notifications under inspection
local function bootColdEnvelope()
  local musicLog, notifies = {}, {}
  local audio = richCueDouble(musicLog)
  function audio:playMusic(symbol)
    musicLog[#musicLog + 1] = { method = "playMusic", receiver = self, symbol = symbol }
    return true
  end
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local envelope = FieldBattlePresentation.new({
    cacheFs = cache,
    windows = recordingWindows(),
    text = recordingText(),
    audio = audio,
    measureDisplay = function()
      return dualMeasurement("battle-audio:cold")
    end,
  })
  return envelope, musicLog, notifies
end

-- Cold ordinary and special starts stage only the chosen music closure
-- and raise it on the exact transition tick: ordinary wild and trainer
-- launches raise their staged tracks, a rival override raises the rival
-- track instead of the generic trainer one, a special-species encounter
-- never collapses onto the ordinary wild track, and a cold start with no
-- staged roles fails loudly instead of latching permanent silence.
function T.cold_and_special_starts_raise_only_the_chosen_track_on_the_cover_tick()
  local problems = {}
  for _, versionId in ipairs(readyVersions()) do
    local roles = stagedRoleSymbols(versionId)
    local wildId = roles.wild
    local trainerId = roles.trainer
    local rivalId = roles.rival

    local legs = {
      {
        name = "ordinary wild",
        spec = { kind = "wild", details = { species = "CATERPIE", level = 3 } },
        expected = wildId,
      },
      {
        name = "ordinary trainer",
        spec = { kind = "trainer", details = { trainer = 4 } },
        expected = trainerId,
      },
      {
        name = "rival override",
        spec = { kind = "trainer", details = { trainer = 4, rivalName = "RIVAL" } },
        expected = rivalId,
      },
    }
    for _, leg in ipairs(legs) do
      local runtime = bootRuntime(versionId)
      local log = {}
      local envelope, binding, _ = bindEnvelope(runtime, versionId, dualMeasurement("cover-tick:" .. leg.name), richCueDouble(log))
      local trace = freshMusicTrace()
      watchMusic(runtime.audio, trace)
      local ok, legErr = xpcall(function()
        local launchId = runtime:launchBattle(leg.spec)
        Assert.isTrue(type(launchId) == "string", "the " .. leg.name .. " start admits its launch")
        local startedAtCover = nil
        local earlyStart = false
        local ticks = 0
        while runtime.battleCoordinator:activeBattle() == nil and ticks < 1500 do
          runtime:update(1 / 30)
          envelope:updateFixed(TICK)
          ticks = ticks + 1
          for _, start in ipairs(trace.starts) do
            if start.tick == nil then
              start.tick = ticks
              start.cover = envelope:cover().coefficient
              if start.cover < FULL_COVER then
                earlyStart = true
              end
              if startedAtCover == nil then
                startedAtCover = start.cover
              end
            end
          end
        end
        Assert.notNil(runtime.battleCoordinator:activeBattle(), "the " .. leg.name .. " start constructs its battle")
        checkStartedNote(problems, envelope, leg.expected, versionId, leg.name .. " start")
        check(problems, #trace.starts == 1, "the " .. leg.name .. " start raises its music exactly once on " .. versionId)
        if trace.starts[1] ~= nil then
          check(
            problems,
            trace.starts[1].symbol == leg.expected,
            "the " .. leg.name .. " start raises " .. tostring(leg.expected) .. ", not "
              .. tostring(trace.starts[1].symbol) .. ", on " .. versionId
          )
        else
          check(problems, false, "the " .. leg.name .. " start raises " .. tostring(leg.expected) .. " on " .. versionId)
        end
        check(problems, not earlyStart, "the " .. leg.name .. " music waits for full cover on " .. versionId)
        check(
          problems,
          startedAtCover == FULL_COVER,
          "the " .. leg.name .. " music starts on the exact cover tick on " .. versionId
        )
        local demands = envelope:preparedDemands()
        local staged = false
        for _, demand in ipairs(demands) do
          local audio = type(demand) == "table" and demand.audio or nil
          if type(audio) == "table" then
            for _, role in ipairs(audio.roles or {}) do
              if role == leg.expected then
                staged = true
              elseif role == wildId or role == trainerId or role == rivalId then
                check(
                  problems,
                  false,
                  "the " .. leg.name .. " demand stages only its chosen closure, never " .. tostring(role)
                )
              end
            end
            check(
              problems,
              type(audio.banks) == "table" and #audio.banks > 0,
              "the " .. leg.name .. " demand stages the chosen track bank on " .. versionId
            )
          end
        end
        check(problems, staged, "the " .. leg.name .. " demand stages its chosen track on " .. versionId)
      end, debug.traceback)
      pcall(function()
        runtime:unbindBattlePresentation(binding)
      end)
      pcall(function()
        runtime:dispose()
      end)
      if not ok then
        problems[#problems + 1] = "the " .. leg.name .. " start failed outside its contract on "
          .. versionId .. ": " .. tostring(legErr)
      end
    end

    do
      local runtime = bootRuntime(versionId)
      local log = {}
      local envelope, binding, _ =
        bindEnvelope(runtime, versionId, dualMeasurement("cover-tick:special"), richCueDouble(log))
      local trace = freshMusicTrace()
      watchMusic(runtime.audio, trace)
      local ok, legErr = xpcall(function()
        runtime:launchBattle({ kind = "wild", details = { species = "LUGIA", level = 3 } })
        local ticks = 0
        while runtime.battleCoordinator:activeBattle() == nil and ticks < 1500 do
          runtime:update(1 / 30)
          envelope:updateFixed(TICK)
          ticks = ticks + 1
        end
        Assert.notNil(runtime.battleCoordinator:activeBattle(), "the special start constructs its battle")
        check(problems, #trace.starts == 1, "the special start raises its music exactly once on " .. versionId)
        if trace.starts[1] ~= nil then
          check(
            problems,
            trace.starts[1].symbol ~= wildId,
            "the special-species encounter never collapses onto the ordinary wild track on " .. versionId
          )
        else
          check(problems, false, "the special-species encounter raises its own track on " .. versionId)
        end
      end, debug.traceback)
      pcall(function()
        runtime:unbindBattlePresentation(binding)
      end)
      pcall(function()
        runtime:dispose()
      end)
      if not ok then
        problems[#problems + 1] = "the special start failed outside its contract on " .. versionId .. ": " .. tostring(legErr)
      end
    end

    do
      local envelope, musicLog, notifies = bootColdEnvelope()
      local host = {
        phase = "covering",
        notifies = notifies,
      }
      function host.status()
        return { phase = host.phase }
      end
      function host.advance() end
      function host.submit(_)
        return false
      end
      function host.notify(event, detail)
        notifies[#notifies + 1] = { event = event, detail = detail }
      end
      local ok, legErr = xpcall(function()
        envelope:factory()({
          launchId = "launch-cold-audio",
          environment = { sceneKey = "general/grass/day" },
          musicRole = nil,
          audio = (function()
            local log = musicLog
            local controller = richCueDouble(log)
            function controller:playMusic(symbol)
              log[#log + 1] = { method = "playMusic", receiver = self, symbol = symbol }
              return true
            end
            return controller
          end)(),
          host = host,
        })
        for _ = 1, 40 do
          envelope:updateFixed(TICK)
        end
        local attempted = false
        for _, entry in ipairs(musicLog) do
          if entry.method == "playMusic" then
            attempted = true
          end
        end
        local failedLoudly = false
        for _, note in ipairs(notifies) do
          if note.event == "screen-failed" then
            failedLoudly = true
          end
        end
        check(
          problems,
          attempted or failedLoudly,
          "a cold start with no staged roles fails loudly instead of latching permanent silence on " .. versionId
        )
        envelope:dispose()
      end, debug.traceback)
      if not ok then
        problems[#problems + 1] = "the cold start failed outside its contract on " .. versionId .. ": " .. tostring(legErr)
      end
    end
  end
  report(problems)
end

-- Native move, cry, impact, menu, progression, and fanfare cases play
-- through the shared normalized engine with exact operation timing: the
-- known audible fixtures render non-silent samples while a legitimate
-- silent control stays silent, the accepted menu reply plays its staged
-- role, both battlers cry exactly once in source order, damaging turns
-- record effect operations, and victory swaps to the wild-win BGM.
function T.heard_battle_cases_trace_their_cues_and_render_audible_samples()
  local problems = {}
  for _, versionId in ipairs(readyVersions()) do
    local roles = stagedRoleSymbols(versionId)
    local selectSymbol = roles.select
    -- Native program voices arrive behind staged closure keys: only symbols
    -- no staged index resolves (bare or closure-prefixed) still count as
    -- unknown, exactly like the quiet journey below.
    local stagedProvider = AudioAssetProvider.new(CacheFs.forVersion(versionId))
    local function stagedSymbol(symbol)
      local ok = pcall(function()
        return stagedProvider:sequence(symbol)
      end)
      if not ok and type(symbol) == "string" then
        local bare = symbol:match("^audio/sequence/(.+)$")
        if bare ~= nil then
          ok = pcall(function()
            return stagedProvider:sequence(bare)
          end)
        end
      end
      return ok
    end
    do
      local sound, player = composeCaseEngine(selectSymbol)
      sound:play("synthetic-battle-silent-control")
      local silentPeak = peakAbs(leftChannel(player:render(4000), 4000))
      check(problems, silentPeak == 0, "the silent control renders silence on " .. versionId)
      for _, symbol in ipairs({
        selectSymbol,
        "synthetic-battle-move",
        "synthetic-battle-cry-voice",
        "synthetic-battle-fanfare",
      }) do
        sound:play(symbol)
        local peak = peakAbs(leftChannel(player:render(4000), 4000))
        check(
          problems,
          peak > 0,
          "the staged fixture " .. tostring(symbol) .. " renders non-silent samples on " .. versionId
        )
        sound:stop(symbol)
      end
      for _, symbol in ipairs({ "synthetic-battle-impact", "synthetic-battle-progression" }) do
        sound:play(symbol)
        Assert.isTrue(sound:isEffectPlaying(symbol), "the staged fixture " .. symbol .. " starts on " .. versionId)
        player:render(2000)
      end
    end

    do
      local runtime = bootRuntime(versionId)
      local log = {}
      local envelope, binding, _ =
        bindEnvelope(runtime, versionId, dualMeasurement("heard-cases"), richCueDouble(log))
      local trace = freshMusicTrace()
      watchMusic(runtime.audio, trace)
      local ok, legErr = xpcall(function()
        runtime:launchBattle({ kind = "wild", details = { species = "CATERPIE", level = 3 } })
        local screen = driveToCommand(runtime, envelope)
        waitMenuInput(runtime, envelope)
        screen:input({ { type = "confirm" } })
        pump(runtime, envelope, 2)
        screen:input({ { type = "confirm" } })
        pump(runtime, envelope, 2)
        settle(runtime, envelope, sparringChoose, 6000)
        Assert.equal(runtime:lastBattleResult().result, "win", "the heard journey wins its words")
        local leadCry = cryIdentity(runtime.monCatalog, "CHIKORITA")
        local foeCry = cryIdentity(runtime.monCatalog, "CATERPIE")
        local selects = 0
        for _, entry in ipairs(log) do
          if entry.method == "play" and entry.symbol == selectSymbol then
            selects = selects + 1
          end
          check(
            problems,
            entry.receiver ~= nil,
            "every cue reaches its controller with its receiver on " .. versionId
          )
        end
        check(problems, selects >= 1, "the accepted menu reply plays its staged role on " .. versionId)
        check(
          problems,
          countCries(log, leadCry) == 1,
          "the lead send-out cries exactly once on " .. versionId
        )
        check(
          problems,
          countCries(log, foeCry) == 2,
          "the wild foe cries at send-out and at faint on " .. versionId
        )
        local programVoices, unstagedVoices = 0, {}
        for _, entry in ipairs(log) do
          if entry.method == "play" and entry.symbol ~= selectSymbol then
            if stagedSymbol(entry.symbol) then
              programVoices = programVoices + 1
            else
              unstagedVoices[#unstagedVoices + 1] = tostring(entry.symbol)
            end
          end
        end
        check(
          problems,
          programVoices >= 1,
          "damaging turns voice their staged native program on " .. versionId
        )
        check(
          problems,
          #unstagedVoices == 0,
          "damaging turns invent no unstaged operation on " .. versionId .. ": " .. table.concat(unstagedVoices, ", ")
        )
        check(problems, #trace.fanfares == 0, "victory voices no fanfare on " .. versionId)
        local lastStart = trace.starts[#trace.starts]
        check(
          problems,
          lastStart ~= nil and lastStart.symbol == "SEQ_GS_WIN2",
          "victory swaps to the wild-win BGM on " .. versionId
        )
      end, debug.traceback)
      pcall(function()
        runtime:unbindBattlePresentation(binding)
      end)
      pcall(function()
        runtime:dispose()
      end)
      if not ok then
        problems[#problems + 1] = "the heard journey failed outside its contract on " .. versionId .. ": " .. tostring(legErr)
      end
    end

    do
      local runtime = bootRuntime(versionId)
      local log = {}
      local envelope, binding, _ =
        bindEnvelope(runtime, versionId, dualMeasurement("menu-feedback"), richCueDouble(log))
      local ok, legErr = xpcall(function()
        runtime:launchBattle({ kind = "wild", details = { species = "CATERPIE", level = 3 } })
        driveToCommand(runtime, envelope)
        waitMenuInput(runtime, envelope)
        envelope:input({ { type = "cancel" } })
        pump(runtime, envelope, 4)
        local feedback = false
        for _, entry in ipairs(log) do
          if entry.method == "play" and entry.symbol ~= selectSymbol then
            feedback = true
          end
        end
        check(problems, feedback, "menu cancel records its feedback operation on " .. versionId)
      end, debug.traceback)
      pcall(function()
        runtime:unbindBattlePresentation(binding)
      end)
      pcall(function()
        runtime:dispose()
      end)
      if not ok then
        problems[#problems + 1] = "the menu journey failed outside its contract on " .. versionId .. ": " .. tostring(legErr)
      end
    end
  end
  report(problems)
end

-- Source mix parameters and overlapping voices keep their owned timing:
-- overlapping effect voices both stay audible, volume ramps apply their
-- exact levels, completion queries never advance the clock, and battle
-- cry operations carry their species, form, voice mode, and mix
-- parameters with independent per-cue timing, waits, and stops.
function T.source_mix_parameters_and_overlapping_voices_keep_their_owned_timing()
  local problems = {}
  for _, versionId in ipairs(readyVersions()) do
    do
      local sound, player = composeCaseEngine(stagedRoleSymbols(versionId).select)
      sound:play("synthetic-battle-move")
      sound:play("synthetic-battle-impact")
      check(
        problems,
        sound:isEffectPlaying("synthetic-battle-move") and sound:isEffectPlaying("synthetic-battle-impact"),
        "overlapping effect voices both stay active on " .. versionId
      )
      local peak = peakAbs(leftChannel(player:render(4000), 4000))
      check(problems, peak > 0, "overlapping effect voices render audibly together on " .. versionId)
      sound:stop("synthetic-battle-move")
      sound:stop("synthetic-battle-impact")
      sound:play("synthetic-battle-progression")
      sound:moveSequenceVolume("synthetic-battle-progression", 64, 4)
      for _ = 1, 6 do
        sound:updateSoundFrame()
      end
      player:render(500)
      local first = sound:isEffectWaitComplete("synthetic-battle-progression")
      player:render(500)
      local second = sound:isEffectWaitComplete("synthetic-battle-progression")
      check(problems, first == second, "completion queries never advance the clock on " .. versionId)
    end

    do
      local runtime = bootRuntime(versionId)
      local log = {}
      local envelope, binding, _ =
        bindEnvelope(runtime, versionId, dualMeasurement("mix-parameters"), richCueDouble(log))
      local ok, legErr = xpcall(function()
        runtime:launchBattle({ kind = "wild", details = { species = "CATERPIE", level = 3 } })
        driveToCommand(runtime, envelope)
        local leadCry = cryIdentity(runtime.monCatalog, "CHIKORITA")
        local foeCry = cryIdentity(runtime.monCatalog, "CATERPIE")
        local leadOps, foeOps = {}, {}
        for _, entry in ipairs(log) do
          if entry.method == "playCry" and entry.species == leadCry then
            leadOps[#leadOps + 1] = entry
          elseif entry.method == "playCry" and entry.species == foeCry then
            foeOps[#foeOps + 1] = entry
          end
        end
        check(problems, #leadOps == 1, "the lead cry starts exactly once on " .. versionId)
        check(problems, #foeOps == 1, "the foe cry overlaps with its own operation on " .. versionId)
        for _, entry in ipairs(leadOps) do
          check(
            problems,
            entry.form ~= nil and entry.mode ~= nil and entry.pan ~= nil and entry.volume ~= nil
              and entry.pitch ~= nil,
            "the lead cry carries its source mix parameters on " .. versionId
          )
        end
        for _, entry in ipairs(foeOps) do
          check(
            problems,
            entry.form ~= nil and entry.mode ~= nil and entry.pan ~= nil and entry.volume ~= nil
              and entry.pitch ~= nil,
            "the foe cry carries its source mix parameters on " .. versionId
          )
        end
      end, debug.traceback)
      pcall(function()
        runtime:unbindBattlePresentation(binding)
      end)
      pcall(function()
        runtime:dispose()
      end)
      if not ok then
        problems[#problems + 1] = "the mix journey failed outside its contract on " .. versionId .. ": " .. tostring(legErr)
      end
    end
  end
  report(problems)
end

-- Repeated delivery and old voices never replay or steal a cue: redraws,
-- status queries, and repeated port entry never replay a drained
-- one-shot, duplicate and stale deliveries are rejected with no new
-- cues, and each battler's send-out cry starts exactly once even when
-- both battlers share one species.
function T.repeated_delivery_and_old_voices_never_replay_or_steal_a_cue()
  local problems = {}
  do
    local first = BattleTimeline.new({})
    check(problems, first:present({ packetId = 1, events = {} }) == true, "the first delivery is accepted")
    check(
      problems,
      first:present({ packetId = 1, events = {} }) == false,
      "a duplicate delivery is rejected with no new cues"
    )
    check(problems, #first:drainSounds() == 0, "duplicate deliveries queue no sounds")
    local stale = BattleTimeline.new({})
    check(
      problems,
      stale:present({
        launchId = "launch-stale-audio",
        packetId = 7,
        events = {
          {
            sequence = 9999,
            kind = "acknowledge",
            cause = { kind = "switch", combatant = 1 },
            audience = "public",
            payload = { activation = 1 },
            after = { hp = {} },
          },
        },
      }) == false,
      "a stale entry completion never unblocks a newer request"
    )
  end
  for _, versionId in ipairs(readyVersions()) do
    local runtime = bootRuntime(versionId)
    local log = {}
    local envelope, binding, doubles =
      bindEnvelope(runtime, versionId, dualMeasurement("exactly-once"), richCueDouble(log))
    local ok, legErr = xpcall(function()
      local launchId = runtime:launchBattle({ kind = "wild", details = { species = "CHIKORITA", level = 3 } })
      local screen = driveToCommand(runtime, envelope)
      local sharedCry = cryIdentity(runtime.monCatalog, "CHIKORITA")
      local before = #log
      for _ = 1, 20 do
        screen:status()
        screen:view()
      end
      local port = doubles.ports[1]
      for _ = 1, 10 do
        port.enter({ launchId = launchId, kind = "wild" })
      end
      pump(runtime, envelope, 60)
      check(problems, #log == before, "redraws, queries, and repeated entry never replay a cue on " .. versionId)
      check(
        problems,
        countCries(log, sharedCry) == 2,
        "both same-species send-out cries start exactly once each on " .. versionId
      )
    end, debug.traceback)
    pcall(function()
      runtime:unbindBattlePresentation(binding)
    end)
    pcall(function()
      runtime:dispose()
    end)
    if not ok then
      problems[#problems + 1] = "the exactly-once journey failed outside its contract on " .. versionId .. ": " .. tostring(legErr)
    end
  end
  report(problems)
end

-- Missing or rejected sounds fail the launch with their identity:
-- rejected cue dispatches never become silent success, an answering sink
-- that never starts a cue never reads as played, a missing music bank
-- never becomes a silent battle, and a genuinely unknown cue still names
-- its launch and role.
function T.missing_or_rejected_sounds_fail_the_launch_with_their_identity()
  local problems = {}
  for _, versionId in ipairs(readyVersions()) do
    do
      local runtime = bootRuntime(versionId)
      local log = {}
      local failing = {}
      function failing:play(symbol)
        log[#log + 1] = { method = "play", symbol = symbol }
        error("injected cue fault", 0)
      end
      function failing:playCry(species, pattern)
        log[#log + 1] = { method = "playCry", species = species, pattern = pattern }
        error("injected cue fault", 0)
      end
      local envelope, binding, _ = bindEnvelope(runtime, versionId, dualMeasurement("unknown-cue"), failing)
      local ok, legErr = xpcall(function()
        local launchId = runtime:launchBattle({ kind = "wild", details = { species = "CATERPIE", level = 3 } })
        local reachedCommand = false
        local survived, raised = pcall(function()
          for _ = 1, 900 do
            local screen = envelope:liveScreen()
            if screen ~= nil then
              local shown = screen:status()
              if shown.mode == "command" then
                reachedCommand = true
                return
              end
              if shown.mode == "intro" or shown.mode == "narration" or shown.mode == "outcome" then
                envelope:input({ { type = "confirm" } })
              end
            end
            runtime:update(1 / 30)
            envelope:updateFixed(TICK)
          end
        end)
        local failureText = not survived and tostring(raised) or nil
        check(problems, failureText ~= nil, "a genuinely unknown cue faults the runtime on " .. versionId)
        check(problems, not reachedCommand, "a genuinely unknown cue never reaches command on " .. versionId)
        if failureText ~= nil then
          check(
            problems,
            failureText:find(launchId, 1, true) ~= nil,
            "the cue failure names its launch on " .. versionId .. ": " .. failureText
          )
          check(
            problems,
            failureText:find("cry:CATERPIE", 1, true) ~= nil or failureText:find("SEQ_", 1, true) ~= nil,
            "the cue failure names its cue role on " .. versionId .. ": " .. failureText
          )
        else
          check(
            problems,
            false,
            "the cue failure carries readable launch and role identity on " .. versionId
          )
        end
        check(problems, #log >= 1, "the faulty cue was dispatched before failing on " .. versionId)
      end, debug.traceback)
      pcall(function()
        runtime:unbindBattlePresentation(binding)
      end)
      pcall(function()
        runtime:dispose()
      end)
      if not ok then
        problems[#problems + 1] = "the unknown-cue journey failed outside its contract on " .. versionId .. ": " .. tostring(legErr)
      end
    end

    for _, leg in ipairs({ { name = "false", value = false }, { name = "nil", value = nil } }) do
      local runtime = bootRuntime(versionId)
      local log = {}
      local envelope, binding, _ =
        bindEnvelope(runtime, versionId, dualMeasurement("flat-" .. leg.name), flatCueDouble(log, leg.value))
      local ok, legErr = xpcall(function()
        runtime:launchBattle({ kind = "wild", details = { species = "CATERPIE", level = 3 } })
        local reachedCommand = false
        for _ = 1, 900 do
          local screen = envelope:liveScreen()
          if screen == nil then
            break
          end
          local shown = screen:status()
          if shown.mode == "failed" then
            break
          end
          if shown.mode == "command" then
            reachedCommand = true
            break
          end
          if shown.mode == "intro" or shown.mode == "narration" or shown.mode == "outcome" then
            envelope:input({ { type = "confirm" } })
          end
          runtime:update(1 / 30)
          envelope:updateFixed(TICK)
        end
        check(
          problems,
          not reachedCommand,
          "a cue dispatch that never starts its sound never reads as played on " .. versionId
        )
      end, debug.traceback)
      pcall(function()
        runtime:unbindBattlePresentation(binding)
      end)
      pcall(function()
        runtime:dispose()
      end)
      if not ok then
        problems[#problems + 1] = "the flat-answer journey failed outside its contract on " .. versionId .. ": " .. tostring(legErr)
      end
    end

    do
      local runtime = bootRuntime(versionId)
      local log = {}
      local envelope, binding, _ =
        bindEnvelope(runtime, versionId, dualMeasurement("missing-bank"), richCueDouble(log))
      local innerPlayMusic = runtime.audio.playMusic
      function runtime.audio:playMusic(_)
        error("unknown battle music sequence", 0)
      end
      local ok, legErr = xpcall(function()
        runtime:launchBattle({ kind = "wild", details = { species = "CATERPIE", level = 3 } })
        local reachedCommand = false
        local survived, raised = pcall(function()
          for _ = 1, 900 do
            local screen = envelope:liveScreen()
            if screen ~= nil then
              local shown = screen:status()
              if shown.mode == "command" then
                reachedCommand = true
                return
              end
              if shown.mode == "intro" or shown.mode == "narration" or shown.mode == "outcome" then
                envelope:input({ { type = "confirm" } })
              end
            end
            runtime:update(1 / 30)
            envelope:updateFixed(TICK)
          end
        end)
        check(
          problems,
          not reachedCommand,
          "a missing music bank never becomes a successful silent battle on " .. versionId
        )
        check(
          problems,
          not survived and tostring(raised):find("SEQ_", 1, true) ~= nil,
          "a missing music bank faults the runtime naming its sequence on " .. versionId .. ": " .. tostring(raised)
        )
      end, debug.traceback)
      runtime.audio.playMusic = innerPlayMusic
      pcall(function()
        runtime:unbindBattlePresentation(binding)
      end)
      pcall(function()
        runtime:dispose()
      end)
      if not ok then
        problems[#problems + 1] = "the missing-bank journey failed outside its contract on " .. versionId .. ": " .. tostring(legErr)
      end
    end
  end
  report(problems)
end

-- Every outcome hands music back exactly once without retiring the
-- engine: the field policy suspends at admission, the battle track
-- starts once, victory swaps to the wild-win BGM instead of pausing for a
-- fanfare, the escape restores the field track exactly once, and the
-- shared service and sink stay usable after the battle disposes.
function T.every_outcome_hands_music_back_exactly_once_without_retiring_the_engine()
  local problems = {}
  for _, versionId in ipairs(readyVersions()) do
    do
      local runtime = bootRuntime(versionId)
      local log = {}
      local envelope, binding, _ = bindEnvelope(runtime, versionId, dualMeasurement("win-handoff"), richCueDouble(log))
      local trace = freshMusicTrace()
      watchMusic(runtime.audio, trace)
      local ok, legErr = xpcall(function()
        runtime:launchBattle({ kind = "wild", details = { species = "CATERPIE", level = 3 } })
        local ticks = 0
        while runtime.battleCoordinator:activeBattle() == nil and ticks < 1500 do
          runtime:update(1 / 30)
          envelope:updateFixed(TICK)
          ticks = ticks + 1
          for _, start in ipairs(trace.starts) do
            if start.tick == nil then
              start.tick = ticks
              start.cover = envelope:cover().coefficient
            end
          end
        end
        Assert.notNil(runtime.battleCoordinator:activeBattle(), "the win handoff constructs its battle")
        local turns = settle(runtime, envelope, sparringChoose, 6000)
        Assert.isTrue(turns > 0, "the win handoff answers decisions to its committed words")
        Assert.equal(runtime:lastBattleResult().result, "win", "the win handoff reports its exact word")
        check(problems, trace.suspends == 1, "the field policy suspends once at admission on " .. versionId)
        check(
          problems,
          #trace.starts == 2,
          "the battle track starts once and victory swaps once on " .. versionId
        )
        if trace.starts[1] ~= nil then
          check(
            problems,
            trace.starts[1].cover == FULL_COVER,
            "the battle track starts on the exact cover tick on " .. versionId
          )
          check(
            problems,
            trace.starts[1].symbol ~= "SEQ_GS_WIN2",
            "the opening start keeps the battle track on " .. versionId
          )
        end
        local demands = envelope:preparedDemands()
        local banked = false
        for _, demand in ipairs(demands) do
          local audio = type(demand) == "table" and demand.audio or nil
          if type(audio) == "table" and type(audio.banks) == "table" and #audio.banks > 0 then
            banked = true
          end
        end
        check(problems, banked, "the win demand stages the chosen track bank on " .. versionId)
        check(problems, #trace.fanfares == 0, "victory voices no fanfare on " .. versionId)
        local lastWinStart = trace.starts[#trace.starts]
        check(
          problems,
          lastWinStart ~= nil and lastWinStart.symbol == "SEQ_GS_WIN2",
          "victory swaps to the wild-win BGM on " .. versionId
        )
        check(
          problems,
          trace.resumes == 1,
          "the covered win return restores the field policy once on " .. versionId
        )
        check(
          problems,
          runtime.audio:currentMusic() == runtime.audio:effectiveMusic(),
          "the win leaves the field track current on " .. versionId
        )
        checkStartedNote(problems, envelope, stagedRoleSymbols(versionId).wild, versionId, "win handoff")
        local fieldTrack = runtime.audio:effectiveMusic()
        check(problems, fieldTrack ~= nil, "the win return leaves a current field track on " .. versionId)
        if fieldTrack ~= nil then
          local startsBefore = #trace.starts
          runtime.audio:playMusic(fieldTrack)
          check(
            problems,
            #trace.starts == startsBefore + 1,
            "the shared engine accepts new starts after the win handoff on " .. versionId
          )
        end
      end, debug.traceback)
      pcall(function()
        runtime:unbindBattlePresentation(binding)
      end)
      pcall(function()
        runtime:dispose()
      end)
      if not ok then
        problems[#problems + 1] = "the win handoff failed outside its contract on " .. versionId .. ": " .. tostring(legErr)
      end
    end

    do
      local runtime = bootRuntime(versionId)
      local log = {}
      local envelope, binding, _ =
        bindEnvelope(runtime, versionId, dualMeasurement("flee-handoff"), richCueDouble(log))
      local trace = freshMusicTrace()
      watchMusic(runtime.audio, trace)
      local ok, legErr = xpcall(function()
        runtime:launchBattle({ kind = "wild", details = { species = "CATERPIE", level = 3 } })
        waitConstructed(runtime, envelope)
        settle(runtime, envelope, fleeingChoose, 6000)
        Assert.equal(runtime:lastBattleResult().result, "flee", "the escape reports its exact word")
        check(problems, trace.suspends == 1, "the escape suspends once at admission on " .. versionId)
        check(problems, #trace.starts == 1, "the escape starts its battle track exactly once on " .. versionId)
        local escaped = false
        for _, entry in ipairs(log) do
          if entry.method == "play" then
            escaped = true
          end
        end
        check(problems, escaped, "the escape records its parting operation on " .. versionId)
        check(problems, trace.resumes == 1, "the escape restores the field policy exactly once on " .. versionId)
        check(problems, trace.lastRestore == true, "the escape restores the field track on " .. versionId)
        check(
          problems,
          runtime.audio:currentMusic() == runtime.audio:effectiveMusic(),
          "the escape leaves the field track current on " .. versionId
        )
        local fieldTrack = runtime.audio:effectiveMusic()
        check(problems, fieldTrack ~= nil, "the escape return leaves a current field track on " .. versionId)
        if fieldTrack ~= nil then
          local startsBefore = #trace.starts
          runtime.audio:playMusic(fieldTrack)
          check(
            problems,
            #trace.starts == startsBefore + 1,
            "the shared engine accepts new starts after the escape handoff on " .. versionId
          )
        end
      end, debug.traceback)
      pcall(function()
        runtime:unbindBattlePresentation(binding)
      end)
      pcall(function()
        runtime:dispose()
      end)
      if not ok then
        problems[#problems + 1] = "the flee handoff failed outside its contract on " .. versionId .. ": " .. tostring(legErr)
      end
    end
  end
  report(problems)
end

-- Quiet visual modes keep the mandatory cues and no substitutes: with
-- move effects disabled the battle dispatches the identical mandatory
-- set as the ordinary path, every send-out cry and the wild-win BGM swap
-- included, every dispatched operation names a staged role or a
-- cataloged battler cry, and no invented stand-in ever appears.
function T.quiet_visual_modes_keep_the_mandatory_cues_and_no_substitutes()
  local problems = {}
  for _, versionId in ipairs(readyVersions()) do
    local roles = stagedRoleSymbols(versionId)
    local selectSymbol = roles.select
    local journeys = {
      { name = "ordinary path", details = { species = "CATERPIE", level = 3 } },
      { name = "quiet path", details = { species = "CATERPIE", level = 3, moveEffects = false } },
    }
    local counts = {}
    -- Staged battle-domain operations (move, impact, and menu feedback
    -- voices the quiet path keeps) are mandatory-adjacent cues, not
    -- invented substitutes: only symbols no staged index resolves still
    -- count as unknown.
    local stagedProvider = AudioAssetProvider.new(CacheFs.forVersion(versionId))
    local function stagedSymbol(symbol)
      local ok = pcall(function()
        return stagedProvider:sequence(symbol)
      end)
      if not ok and type(symbol) == "string" then
        local bare = symbol:match("^audio/sequence/(.+)$")
        if bare ~= nil then
          ok = pcall(function()
            return stagedProvider:sequence(bare)
          end)
        end
      end
      return ok
    end
    for _, journey in ipairs(journeys) do
      local runtime = bootRuntime(versionId)
      local log = {}
      local envelope, binding, _ =
        bindEnvelope(runtime, versionId, dualMeasurement("quiet:" .. journey.name), richCueDouble(log))
      local trace = freshMusicTrace()
      watchMusic(runtime.audio, trace)
      local ok, legErr = xpcall(function()
        runtime:launchBattle({ kind = "wild", details = journey.details })
        local leadCry = cryIdentity(runtime.monCatalog, "CHIKORITA")
        local foeCry = cryIdentity(runtime.monCatalog, "CATERPIE")
        local screen = driveToCommand(runtime, envelope)
        waitMenuInput(runtime, envelope)
        screen:input({ { type = "confirm" } })
        pump(runtime, envelope, 2)
        screen:input({ { type = "confirm" } })
        pump(runtime, envelope, 2)
        settle(runtime, envelope, sparringChoose, 6000)
        Assert.equal(runtime:lastBattleResult().result, "win", "the " .. journey.name .. " wins its words")
        local observed = { lead = 0, foe = 0, selects = 0, staged = 0, winMusic = 0, unknown = {} }
        for _, start in ipairs(trace.starts) do
          if type(start) == "table" and start.symbol == "SEQ_GS_WIN2" then
            observed.winMusic = observed.winMusic + 1
          end
        end
        for _, entry in ipairs(log) do
          if entry.method == "playCry" and entry.species == leadCry then
            observed.lead = observed.lead + 1
          elseif entry.method == "playCry" and entry.species == foeCry then
            observed.foe = observed.foe + 1
          elseif entry.method == "play" and entry.symbol == selectSymbol then
            observed.selects = observed.selects + 1
          elseif entry.method == "play" and stagedSymbol(entry.symbol) then
            observed.staged = observed.staged + 1
          elseif entry.method == "play" then
            observed.unknown[#observed.unknown + 1] = tostring(entry.symbol)
          elseif entry.method == "playCry" then
            observed.unknown[#observed.unknown + 1] = "cry:" .. tostring(entry.species)
          else
            observed.unknown[#observed.unknown + 1] = tostring(entry.method)
          end
        end
        check(problems, observed.lead == 1, "the " .. journey.name .. " keeps its lead cry on " .. versionId)
        check(
          problems,
          observed.foe == 2,
          "the " .. journey.name .. " keeps its send-out and faint foe cries on " .. versionId
        )
        check(
          problems,
          observed.selects >= 1,
          "the " .. journey.name .. " keeps its interface feedback on " .. versionId
        )
        check(problems, observed.winMusic == 1, "the " .. journey.name .. " swaps its wild-win BGM on " .. versionId)
        check(
          problems,
          #observed.unknown == 0,
          "the " .. journey.name .. " invents no substitute operations on " .. versionId .. ": "
            .. table.concat(observed.unknown, ", ")
        )
        counts[journey.name] = observed
      end, debug.traceback)
      pcall(function()
        runtime:unbindBattlePresentation(binding)
      end)
      pcall(function()
        runtime:dispose()
      end)
      if not ok then
        problems[#problems + 1] = "the "
          .. journey.name
          .. " failed outside its contract on "
          .. versionId
          .. ": "
          .. tostring(legErr)
      end
    end
    if counts["ordinary path"] ~= nil and counts["quiet path"] ~= nil then
      local ordinary = counts["ordinary path"]
      local quiet = counts["quiet path"]
      check(
        problems,
        quiet.lead == ordinary.lead and quiet.foe == ordinary.foe and quiet.winMusic == ordinary.winMusic,
        "quiet modes keep the identical mandatory set as the ordinary path on " .. versionId
      )
    end
  end
  report(problems)
end

return {
  tests = T,
  metadata = {
    capabilities = { "rom_dump", "derived_assets" },
    derivedAssets = {
      "field-runtime",
      "map-data:63",
      "map-data:64",
      "map:63",
      "map:64",
      "trainers:global",
      "encounters:global",
      "battle-presentation:global",
      "battle-scene:building_1/building/day",
      "battle-scene:general/grass/day",
      "battle-scene:general/plain/day",
    },
  },
}
