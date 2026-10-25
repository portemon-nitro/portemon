-- Production presented-battle integration through the real field runtime
-- and the real battle screen: one envelope per field lifetime, one fresh
-- port and screen per launch, covered entry and return, audio arbitration,
-- and the distinct continuing, scripted-defeat, and automatic-defeat
-- continuations. Only host boundaries are substituted: recording
-- window/text doubles, deterministic clocks, and isolated save namespaces
-- (through direct runtime boots). Weak staged foes keep each leg fast and
-- deterministic; timing-sensitive frozen acceptance owns the long walks.

local SourceTick = require("libs.hgss.src.field.SourceTick")
local Assert = require("tests.support.Assert")
local BattleAnimationSchema = require("libs.assets.src.battle.BattleAnimationSchema")
local BattleDataCache = require("libs.assets.src.battle.BattleDataCache")
local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldRuntime = require("game.hgss.src.field.FieldRuntime")
local FieldBattleCoordinator = require("game.hgss.src.field.FieldBattleCoordinator")
local FieldBattlePresentation = require("game.hgss.src.field.FieldBattlePresentation")
local BattleTask = require("libs.hgss.src.script.tasks.BattleTask")
local ScreenTopology = require("libs.ui.src.ScreenTopology")
local SessionFixture = require("libs.battle.tests.session_fixture")
local PlayTime = require("libs.hgss.src.save.PlayTime")

local T = {}

local TICK = 1 / 30

local function dualMeasurement(signature)
  return {
    width = 256,
    height = 384,
    topology = ScreenTopology.dualDisplay(
      { id = "main", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
      { id = "lower", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" }
    ),
    pixelRatio = 1,
    signature = signature,
  }
end

local function compactMeasurement(signature)
  return {
    width = 256,
    height = 192,
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 256, height = 192 },
      touch = true,
      role = "world",
    }),
    pixelRatio = 1,
    signature = signature,
  }
end

local function recordingText()
  local text = { measures = 0, draws = {} }
  function text.measure(content)
    text.measures = text.measures + 1
    return { width = 8 * #tostring(content), height = 16 }
  end
  function text.drawText(content, x, y)
    text.draws[#text.draws + 1] = { content = tostring(content), x = x, y = y }
  end
  return text
end

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

local function recordingAudio()
  local audio = { plays = {} }
  function audio.play(name)
    audio.plays[#audio.plays + 1] = name
    return true
  end
  return audio
end

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
        gender = 0,
        trainerId = 1,
        money = 3000,
        badges = 0,
        nationalDex = false,
        runningShoes = false,
        runningShoesLock = false,
        rivalName = "Silver",
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

local function runtimeOptions()
  local Fixture = require("tests.support.FieldStatePresentationFixture")
  local LocalClock = require("game.src.LocalClock")
  return {
    presentation = false,
    derivedAssets = Fixture.iconHost().derivedAssets,
    localClock = LocalClock.new(function()
      return { year = 2024, month = 6, day = 1, hour = 12, minute = 0, second = 0 }
    end),
  }
end

---@param versionId string
---@param location table? map entry overriding the house interior
---@return FieldRuntime live headless production runtime with a stocked party
local function bootRuntime(versionId, location)
  local entry = validEntry(versionId)
  if location ~= nil then
    entry.location = location
  end
  local runtime = FieldRuntime.new(entry, runtimeOptions())
  Assert.isTrue(runtime.monService:giveMon({ species = "CHIKORITA", level = 9 }), "the route needs its lead")
  Assert.isTrue(runtime.monService:giveMon({ species = "CHIKORITA", level = 9 }), "the route needs its reserve")
  return runtime
end

-- A scripted stand-in for the shared generated-image owner: answers
-- ready borrows immediately, or one terminal failure for every request
-- when constructed with a cause. Request counts stay observable so
-- callers can prove single-attempt and latched-failure behavior.
---@param failure string? terminal classification cause behind every request, nil answers ready
---@return table scripted pool behind the envelope under test
local function scriptedPool(failure)
  local pool = { requests = 0 }
  function pool:request(_, _, _)
    self.requests = self.requests + 1
    return self.requests
  end
  function pool:poll(_)
    if failure ~= nil then
      return "failed", failure
    end
    return "ready"
  end
  function pool:acquire(_)
    return { image = {}, width = 256, height = 256 }
  end
  function pool:release(_) end
  return pool
end

---@param runtime FieldRuntime
---@param versionId string
---@param measurement table
---@param graphics table? borrowed graphics namespace staging pixels behind explicit draws
---@param transition table? native transition collaborators behind effect initialization
---@return table envelope
---@return integer binding
---@return table doubles
-- Synthetic battle-effect staging for scheduled headless battles. The
-- versioned cache stages no battle effects and no derived worker runs
-- in these tests, so every demanded effect key resolves to the same
-- closed probe program through a cacheFs overlay while every other
-- cache path delegates verbatim with zero real-cache writes. The probe
-- runs the real player, factory, and scene path (resourceless and
-- source-timed) so strikes complete natively instead of wedging
-- behind effects that will never stage here.
---@param realFs table<string, unknown> versioned derived cache behind delegation
---@return table<string, unknown> cache filesystem overlay serving synthetic closed effects
local function syntheticEffectCacheFs(realFs)
  local BattleAnimationCompiler = require("romdump.src.digest.battle.BattleAnimationCompiler")
  local effectPrefix = BattlePresentationCache.effectPath("EFFECTKEY"):gsub("EFFECTKEY%.lua$", "")
  local markerPrefix = BattlePresentationCache.effectMarkerPath("EFFECTKEY"):gsub("EFFECTKEY%.complete$", "")
  local function effectKeyOfLua(path)
    if type(path) ~= "string" then
      return nil
    end
    return path:match("^" .. effectPrefix .. "([^/]+)%.lua$")
  end
  local function effectKeyOfMarker(path)
    if type(path) ~= "string" then
      return nil
    end
    return path:match("^" .. markerPrefix .. "([^/]+)%.complete$")
  end
  local probeProgram = nil
  ---@param key string flat semantic effect key under staging
  ---@return table<string, unknown> schema-valid closed synthetic effect record
  local function syntheticRecord(key)
    if probeProgram == nil then
      local function u32(value)
        return string.char(
          value % 256,
          math.floor(value / 256) % 256,
          math.floor(value / 65536) % 256,
          math.floor(value / 16777216) % 256
        )
      end
      local stream = u32(34) .. u32(1) .. u32(2) .. u32(3) .. u32(29) .. u32(50) .. u32(4)
      probeProgram = assert(BattleAnimationCompiler.compile({ key = key, stream = stream }))
    end
    return {
      schema = BattleAnimationSchema.EFFECT_SCHEMA,
      key = key,
      catalogIdentity = "synthetic-scheduled-effect",
      program = {
        entry = probeProgram.entry,
        instructions = probeProgram.instructions,
        subprograms = probeProgram.subprograms,
        taskKinds = probeProgram.taskKinds,
      },
      dependencies = {},
      resources = {},
      requiredContext = {},
    }
  end
  local wrapper = {}
  function wrapper.loadLua(_, path)
    local key = effectKeyOfLua(path)
    if key ~= nil then
      return syntheticRecord(key)
    end
    return realFs:loadLua(path)
  end
  function wrapper.read(_, path)
    if effectKeyOfMarker(path) ~= nil then
      return "synthetic-scheduled-marker"
    end
    return realFs:read(path)
  end
  function wrapper.exists(_, path, expectedType)
    if effectKeyOfLua(path) ~= nil or effectKeyOfMarker(path) ~= nil then
      return true
    end
    return realFs:exists(path, expectedType)
  end
  return setmetatable(wrapper, {
    __index = function(_, key)
      local value = realFs[key]
      if type(value) == "function" then
        return function(_, ...)
          return value(realFs, ...)
        end
      end
      return value
    end,
  })
end

local function bindEnvelope(runtime, versionId, measurement, graphics, transition)
  local doubles = { audio = recordingAudio(), windows = recordingWindows(), text = recordingText() }
  local envelope = FieldBattlePresentation.new({
    cacheFs = syntheticEffectCacheFs(CacheFs.forVersion(versionId)),
    windows = doubles.windows,
    text = doubles.text,
    audio = doubles.audio,
    graphics = graphics,
    derivedAssets = transition ~= nil and transition.derivedAssets or nil,
    fieldRenderer = transition ~= nil and transition.fieldRenderer or nil,
    captureFieldLayers = transition ~= nil and transition.captureFieldLayers or nil,
    measureDisplay = function()
      return measurement
    end,
  })
  local ports = {}
  doubles.descriptors = {}
  local factory = envelope:factory()
  local function admit(descriptor)
    doubles.descriptors[#doubles.descriptors + 1] = descriptor
    local port = factory(descriptor)
    ports[#ports + 1] = port
    return port
  end
  local binding = runtime:bindBattlePresentation(admit)
  doubles.ports = ports
  -- The admission closure is also returned so a journey can withdraw and
  -- rebind the same presentation across rounds; existing callers keep
  -- ignoring the fourth value.
  return envelope, binding, doubles, admit
end

local function readyVersions()
  local GameVersion = require("romdump.src.source.GameVersion")
  local RomImporter = require("romdump.src.source.RomImporter")
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      return { versionId }
    end
  end
  error("presented battle integration needs a ready versioned cache", 0)
end

function T.presented_launch_captures_semantic_transition_context_before_mutation()
  local runtime = bootRuntime(readyVersions()[1])
  local envelope, binding, doubles = bindEnvelope(runtime, runtime.versionId, dualMeasurement("transition-context"))
  local ok, failure = xpcall(function()
    runtime:launchBattle({ kind = "wild", details = { species = "HO_OH", level = 45 } })
    local context = assert(doubles.descriptors[1].transitionContext)
    Assert.deepEqual(context, {
      kind = "wild",
      wildSpecies = "HO_OH",
      doubleBattle = false,
      specialBattle = false,
      alternateTransition = false,
      playerGender = "male",
      wildSetupFallback = false,
      terrain = "plain",
      timeOfDay = "day",
    })
  end, debug.traceback)
  pcall(function()
    runtime:unbindBattlePresentation(binding)
  end)
  pcall(function()
    runtime:dispose()
  end)
  if not ok then
    error(failure, 0)
  end
  envelope:dispose()
end

---@param actor table addressed combatant under test driving
---@return table single-target strike at the opposing singles slot
local function strike(actor)
  return { actor = actor, kind = "attack", payload = { moveSlot = 0, target = { kind = "position", position = 2 } } }
end

---@param runtime FieldRuntime
---@param envelope table
---@param ticks integer fixed ticks to advance under test driving
local function pump(runtime, envelope, ticks)
  for _ = 1, ticks do
    runtime:update(SourceTick.DT)
    envelope:updateFixed(TICK)
  end
end

-- Waits for the source menu input gate to open before answering: the
-- production command menu drops input during its entry travel, so an
-- input sent earlier would never reach the live screen.
---@param runtime FieldRuntime live production runtime under test driving
---@param envelope table live presented-battle envelope under test driving
local function waitMenuInput(runtime, envelope)
  for _ = 1, 300 do
    local screen = envelope:liveScreen()
    if screen ~= nil and screen:view().menuInputEnabled then
      return
    end
    pump(runtime, envelope, 1)
  end
  error("the source menu input gate never opened", 0)
end

---@param runtime FieldRuntime
---@param envelope table
local function waitConstructed(runtime, envelope)
  local ticks = 0
  while runtime.battleCoordinator:activeBattle() == nil and ticks < 900 do
    runtime:update(SourceTick.DT)
    envelope:updateFixed(TICK)
    ticks = ticks + 1
  end
  Assert.notNil(runtime.battleCoordinator:activeBattle(), "the covered launch constructs its battle")
end

---@param runtime FieldRuntime
---@param envelope table
---@param choose fun(request: table): table
---@param budget integer
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
      local answer = choose(current.request)
      local choices = answer
      if type(answer) == "table" and answer.kind ~= nil then
        choices = { answer }
      end
      local accepted, replyErr = battle:submit(SessionFixture.replyFor(current.request, choices))
      Assert.isTrue(accepted, "a legal presented decision is accepted: " .. tostring(replyErr))
    end
    -- Terminal leave carries an explicit final-page acknowledgment, so
    -- every narration page is acknowledged through the real envelope
    -- input path exactly as a player would, alongside the decisions.
    local screen = envelope:liveScreen()
    if screen ~= nil then
      local shown = screen:status()
      if shown.mode == "intro" or shown.mode == "narration" or shown.mode == "outcome" then
        envelope:input({ { type = "confirm" } })
      end
    end
    runtime:update(SourceTick.DT)
    envelope:updateFixed(TICK)
    ticks = ticks + 1
  end
  Assert.isNil(runtime.battleCoordinator:activeBattle(), "answered decisions settle the owned presented lifetime")
  return turns
end

-- Drives one defeat leg through kernel decisions and genuine battle
-- narration acknowledgment until the launch enters automatic recovery.
-- Every open kernel request is answered through the live battle while
-- every narration page is acknowledged through the real envelope input
-- path, exactly as a player would; nothing is synthesized. Stops as soon
-- as the launch reaches recovering so the later recovery edge stays a
-- separate genuine press.
---@param runtime FieldRuntime
---@param envelope table
---@param choose fun(request: table): table
---@param budget integer
---@return integer answered player turns before recovery began
local function driveDefeatToRecovery(runtime, envelope, choose, budget)
  local turns, ticks = 0, 0
  while ticks < budget do
    local launch = runtime.battleCoordinator._battleLaunch
    if launch ~= nil and launch.phase == "recovering" then
      return turns
    end
    if launch == nil or launch.phase == "failed" then
      error("the defeat never entered recovery", 0)
    end
    local battle = runtime.battleCoordinator:activeBattle()
    if battle ~= nil then
      local current = battle:status()
      if current.phase == "failed" then
        error("the presented battle failed: " .. tostring(current.error), 0)
      end
      if current.phase == "running" and current.request ~= nil then
        turns = turns + 1
        local answer = choose(current.request)
        local choices = answer
        if type(answer) == "table" and answer.kind ~= nil then
          choices = { answer }
        end
        local accepted, replyErr = battle:submit(SessionFixture.replyFor(current.request, choices))
        Assert.isTrue(accepted, "a legal presented decision is accepted: " .. tostring(replyErr))
      end
    end
    local screen = envelope:liveScreen()
    if screen ~= nil then
      local shown = screen:status()
      if shown.mode == "intro" or shown.mode == "narration" or shown.mode == "outcome" then
        envelope:input({ { type = "confirm" } })
      end
    end
    runtime:update(SourceTick.DT)
    envelope:updateFixed(TICK)
    ticks = ticks + 1
  end
  error("the defeat never entered recovery within its tick budget", 0)
end

-- Pumps until the recovery flow reports the wanted phase, checking every
-- tick so even a one-tick wait is still observed. Returns false when the
-- field restores first or the budget runs out, so the caller can name the
-- missing wait instead of failing deep inside the pump.
---@param runtime FieldRuntime
---@param envelope table
---@param wanted string recovery phase under wait
---@param budget integer
---@return boolean reached true while the flow reported the wanted phase
local function reachBlackoutPhase(runtime, envelope, wanted, budget)
  local ticks = 0
  while ticks < budget do
    local flow = assert(runtime.blackoutFlow, "the runtime composes its recovery flow")
    local status = flow:status()
    if status.phase == wanted then
      return true
    end
    if status.error ~= nil then
      error("the recovery failed: " .. tostring(status.error), 0)
    end
    if runtime.overworld:phase() == "present" then
      return false
    end
    runtime:update(SourceTick.DT)
    envelope:updateFixed(TICK)
    ticks = ticks + 1
  end
  local flow = assert(runtime.blackoutFlow, "the runtime composes its recovery flow")
  return flow:status().phase == wanted
end

-- Answer every exposed request: strikes for commands, prepared fragments
-- for replacements and learning, learned from the projected options.
---@param runtime FieldRuntime
---@param request table<string, unknown> pending player decision
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

-- Native encounter admission starts battle music with the selected effect
-- task. The field stays present until that task completes; music must not be
-- deferred until an emergency black cover reaches full opacity.
function T.encounter_music_starts_with_transition_before_full_cover()
  for _, versionId in ipairs(readyVersions()) do
    -- The ordering intent needs an outdoor fallback route: the compiled
    -- catalog carries no indoor fallback, so the house interior fails
    -- selection closed by design. Route selection itself is unchanged.
    local runtime = bootRuntime(versionId, { mapSymbol = "MAP_NEW_BARK", fieldX = 10, fieldZ = 10, facing = "south" })
    local envelope, binding =
      bindEnvelope(runtime, versionId, dualMeasurement("encounter-transition:dual"), love.graphics, {
        derivedAssets = {
          requestBattleScene = function()
            return true
          end,
        },
        fieldRenderer = {},
        captureFieldLayers = function()
          return {
            dispose = function() end,
          }
        end,
      })
    local ok, failure = xpcall(function()
      runtime:launchBattle({ kind = "wild", details = { species = "CATERPIE", level = 3 } })

      local ticks = 0
      while envelope:musicNote() == nil and ticks < 30 do
        runtime:update(TICK)
        envelope:updateFixed(TICK)
        ticks = ticks + 1
      end

      Assert.notNil(envelope:musicNote(), "the selected transition emits its battle-music operation")
      Assert.isTrue(
        envelope:cover().coefficient < 16,
        "transition music starts with effect initialization before any full-cover handoff"
      )
      Assert.equal(runtime.overworld:phase(), "present", "the field remains present while the transition runs")
      Assert.isNil(
        runtime.battleCoordinator:activeBattle(),
        "the battle is not constructed until the native transition completes"
      )
    end, debug.traceback)
    pcall(function()
      runtime:unbindBattlePresentation(binding)
    end)
    pcall(function()
      runtime:dispose()
    end)
    if not ok then
      error(failure, 0)
    end
  end
end

-- A presented trainer win pays its prize exactly once through the live
-- wallet, with no second publication across the return.
function T.presented_trainer_win_pays_once()
  for _, versionId in ipairs(readyVersions()) do
    local runtime = bootRuntime(versionId)
    local envelope, binding, _ = bindEnvelope(runtime, versionId, dualMeasurement("presented-prize:dual"))
    local ok, failure = xpcall(function()
      runtime:launchBattle({ kind = "trainer", details = { trainer = 4 } })
      waitConstructed(runtime, envelope)
      local moneyBefore = runtime.playerData.profile.money
      settle(runtime, envelope, function(request)
        return sparringChoose(runtime, request)
      end, 8000)
      pump(runtime, envelope, 60)
      Assert.equal(runtime:lastBattleResult().result, "win", "the trainer win reports its word")
      Assert.isTrue(runtime.playerData.profile.money > moneyBefore, "the win pays its prize once")
      local paid = runtime.playerData.profile.money
      pump(runtime, envelope, 30)
      Assert.equal(runtime.playerData.profile.money, paid, "settling pays no second prize")
    end, debug.traceback)
    local unbound = pcall(function()
      runtime:unbindBattlePresentation(binding)
    end)
    local closed = pcall(function()
      runtime:dispose()
    end)
    if not ok then
      error(failure, 0)
    end
    Assert.isTrue(unbound, "the lifetime releases its factory binding")
    Assert.isTrue(closed, "teardown releases the presented lifetime")
  end
end

-- A scripted defeat publishes its receipt while absent for the authored
-- continuation: no ordinary restoration runs and no automatic recovery
-- starts behind the source script.
function T.scripted_defeat_stays_absent_without_recovery()
  for _, versionId in ipairs(readyVersions()) do
    local runtime = bootRuntime(versionId)
    local envelope, binding, _ = bindEnvelope(runtime, versionId, dualMeasurement("presented-scripted:dual"))
    local ok, failure = xpcall(function()
      local blackout = assert(runtime.blackoutFlow, "the runtime composes its recovery flow")
      local recoveries = 0
      local realStart = blackout.start
      blackout.start = function(self, spawnKey)
        recoveries = recoveries + 1
        return realStart(self, spawnKey)
      end
      local launchId
      local done, launchErr = pcall(function()
        launchId = runtime._battleHost:launchBattle({ kind = "wild", details = { species = "EEVEE", level = 30 } })
      end)
      Assert.isTrue(done, "the script host launches: " .. tostring(launchErr))
      waitConstructed(runtime, envelope)
      settle(runtime, envelope, function(request)
        return sparringChoose(runtime, request)
      end, 15000)
      pump(runtime, envelope, 60)
      blackout.start = realStart
      Assert.equal(recoveries, 0, "scripted defeat starts no automatic recovery")
      Assert.equal(runtime:lastBattleResult().result, "loss", "the scripted loss reports its exact word")
      Assert.equal(runtime:lastBattleResult().sourceResult, 0, "the loss reads back not-won")
      Assert.equal(runtime.overworld:phase(), "absent", "scripted defeat holds cover while absent")
      local status = runtime:battleStatus(launchId)
      Assert.isTrue(status ~= nil and status.committed, "the receipt reaches the launching task while absent")
    end, debug.traceback)
    local unbound = pcall(function()
      runtime:unbindBattlePresentation(binding)
    end)
    local closed = pcall(function()
      runtime:dispose()
    end)
    if not ok then
      error(failure, 0)
    end
    Assert.isTrue(unbound, "the lifetime releases its factory binding")
    Assert.isTrue(closed, "teardown releases the presented lifetime")
  end
end

-- An automatic defeat waits at its recovery message for a real player
-- edge, then runs the existing recovery exactly once to its message,
-- destination, and follow-up before returning safely with the gate open
-- and the wallet debited once. Hundreds of input-free ticks never leave
-- the wait; one routed confirm resumes it.
function T.automatic_defeat_recovers_once_and_returns_safely()
  for _, versionId in ipairs(readyVersions()) do
    local runtime = bootRuntime(versionId)
    local envelope, binding, _ = bindEnvelope(runtime, versionId, dualMeasurement("presented-auto:dual"))
    local ok, failure = xpcall(function()
      local blackout = assert(runtime.blackoutFlow, "the runtime composes its recovery flow")
      local recoveries = 0
      local realStart = blackout.start
      blackout.start = function(self, spawnKey)
        recoveries = recoveries + 1
        return realStart(self, spawnKey)
      end
      local moneyAtLoss = runtime.playerData.profile.money
      runtime:launchBattle({ kind = "wild", details = { species = "EEVEE", level = 30 } })
      waitConstructed(runtime, envelope)
      local turns = driveDefeatToRecovery(runtime, envelope, function(request)
        return sparringChoose(runtime, request)
      end, 15000)
      Assert.isTrue(turns > 0, "the defeat answers decisions before its recovery")
      Assert.isTrue(
        reachBlackoutPhase(runtime, envelope, "message_wait", 1500),
        "the defeat reaches its recovery message wait"
      )
      -- The wait holds without input: it neither restores nor completes.
      pump(runtime, envelope, 600)
      local waiting = blackout:status()
      Assert.equal(waiting.phase, "message_wait", "the recovery waits for a real edge instead of completing alone")
      Assert.isTrue(waiting.waitingInput, "the wait keeps asking for input")
      Assert.notNil(waiting.message, "the wait keeps its message visible")
      Assert.isTrue(runtime.overworld:phase() ~= "present", "the wait restores nothing on its own")
      -- One real routed confirm resumes the waiting message.
      envelope:input({ { type = "confirm" } })
      local ticks = 0
      while runtime.overworld:phase() ~= "present" and ticks < 1500 do
        runtime:update(SourceTick.DT)
        envelope:updateFixed(TICK)
        ticks = ticks + 1
      end
      blackout.start = realStart
      Assert.equal(recoveries, 1, "automatic defeat runs the existing recovery exactly once")
      Assert.equal(runtime.overworld:phase(), "present", "the recovery returns to the live field")
      Assert.equal(runtime:lastBattleResult().result, "loss", "the automatic loss reports its exact word")
      Assert.isTrue(runtime.playerData.profile.money < moneyAtLoss, "the defeat debits once")
      local healed = assert(runtime.monService:partyMon(0), "the recovered lead is readable")
      Assert.isTrue(healed.hp == nil or healed.hp > 0, "the recovery heals the party")
      local _, reason = runtime.saveCoordinator:capture(false)
      Assert.isNil(reason, "the save gate opens at the safe field")
      local snapshot, saveErr = runtime.saveCoordinator:capture(false)
      Assert.notNil(snapshot, "the safe field captures: " .. tostring(saveErr))
    end, debug.traceback)
    local unbound = pcall(function()
      runtime:unbindBattlePresentation(binding)
    end)
    local closed = pcall(function()
      runtime:dispose()
    end)
    if not ok then
      error(failure, 0)
    end
    Assert.isTrue(unbound, "the lifetime releases its factory binding")
    Assert.isTrue(closed, "teardown releases the presented lifetime")
  end
end

-- The recovery message answers only a matched genuine edge: an Action
-- pressed before the wait, a pointer release with no press, and a press
-- canceled before its release all leave the wait untouched, while one
-- matched tap advances it exactly once without replaying or leaking into
-- field input.
function T.recovery_message_answers_only_a_matched_genuine_edge()
  for _, versionId in ipairs(readyVersions()) do
    local runtime = bootRuntime(versionId)
    local envelope, binding, _ = bindEnvelope(runtime, versionId, dualMeasurement("presented-recovery-edges:dual"))
    local ok, failure = xpcall(function()
      local blackout = assert(runtime.blackoutFlow, "the runtime composes its recovery flow")
      local recoveries = 0
      local realStart = blackout.start
      blackout.start = function(self, spawnKey)
        recoveries = recoveries + 1
        return realStart(self, spawnKey)
      end
      local moneyAtLoss = runtime.playerData.profile.money
      runtime:launchBattle({ kind = "wild", details = { species = "EEVEE", level = 30 } })
      waitConstructed(runtime, envelope)
      local turns = driveDefeatToRecovery(runtime, envelope, function(request)
        return sparringChoose(runtime, request)
      end, 15000)
      Assert.isTrue(turns > 0, "the defeat answers decisions before its recovery")
      Assert.isTrue(
        reachBlackoutPhase(runtime, envelope, "message_in", 1500),
        "the defeat reaches its recovery message"
      )
      Assert.isTrue(envelope:ownsInput(), "the envelope holds input through the recovery")
      -- Premature and unmatched edges arrive before the wait: an early
      -- Action under cover, a release with no matching press, and a press
      -- canceled before its release.
      envelope:input({ { type = "confirm" } })
      envelope:input({ { type = "pointer_up", pointerId = "touch:9", x = 4, y = 4 } })
      envelope:input({ { type = "pointer_down", pointerId = "touch:9", x = 40, y = 40 } })
      envelope:cancelPointerCapture()
      envelope:input({ { type = "pointer_up", pointerId = "touch:9", x = 40, y = 40 } })
      pump(runtime, envelope, 5)
      local early = blackout:status()
      Assert.isTrue(early.complete ~= true, "premature edges never finish the recovery")
      Assert.isTrue(runtime.overworld:phase() ~= "present", "premature edges never restore the field")
      Assert.isTrue(
        reachBlackoutPhase(runtime, envelope, "message_wait", 1500),
        "the recovery still reaches its message wait"
      )
      -- The wait holds without input across hundreds of ticks.
      pump(runtime, envelope, 600)
      local waiting = blackout:status()
      Assert.equal(waiting.phase, "message_wait", "the recovery waits for a real edge instead of completing alone")
      Assert.isTrue(waiting.waitingInput, "the wait keeps asking for input")
      -- An outside press records no recovery edge, so its matching
      -- release stays orphaned and the wait holds.
      envelope:input({ { type = "pointer_down", pointerId = "touch:8", x = 128, y = 96, outside = true } })
      pump(runtime, envelope, 2)
      envelope:input({ { type = "pointer_up", pointerId = "touch:8", x = 128, y = 96 } })
      pump(runtime, envelope, 5)
      local outside = blackout:status()
      Assert.equal(outside.phase, "message_wait", "an outside press never answers the waiting message")
      Assert.isTrue(outside.waitingInput, "an outside press keeps the wait asking for input")
      -- One matched tap advances the waiting message.
      envelope:input({ { type = "pointer_down", pointerId = "touch:7", x = 128, y = 96 } })
      pump(runtime, envelope, 2)
      envelope:input({ { type = "pointer_up", pointerId = "touch:7", x = 128, y = 96 } })
      local advanced = 0
      while blackout:status().phase == "message_wait" and advanced < 60 do
        runtime:update(SourceTick.DT)
        envelope:updateFixed(TICK)
        advanced = advanced + 1
      end
      Assert.isTrue(blackout:status().phase ~= "message_wait", "a matched tap advances the waiting message")
      local ticks = 0
      while runtime.overworld:phase() ~= "present" and ticks < 1500 do
        runtime:update(SourceTick.DT)
        envelope:updateFixed(TICK)
        ticks = ticks + 1
      end
      blackout.start = realStart
      Assert.equal(recoveries, 1, "automatic defeat runs the existing recovery exactly once")
      Assert.equal(runtime.overworld:phase(), "present", "the recovery returns to the live field")
      Assert.equal(runtime:lastBattleResult().result, "loss", "the automatic loss reports its exact word")
      Assert.isTrue(runtime.playerData.profile.money < moneyAtLoss, "the defeat debits once")
      local settledMoney = runtime.playerData.profile.money
      -- The recovered tile is the reference: the defeat relocates to its
      -- blackout destination, so only movement past this point would prove
      -- a post-completion input leak.
      local before = { fieldX = runtime.player.fieldX, fieldZ = runtime.player.fieldZ }
      -- A second press after completion replays nothing.
      envelope:input({ { type = "confirm" } })
      envelope:input({ { type = "pointer_down", pointerId = "touch:7", x = 128, y = 96 } })
      envelope:input({ { type = "pointer_up", pointerId = "touch:7", x = 128, y = 96 } })
      pump(runtime, envelope, 30)
      Assert.equal(recoveries, 1, "a press after completion starts no second recovery")
      Assert.equal(runtime.playerData.profile.money, settledMoney, "a press after completion debits nothing")
      Assert.deepEqual(
        { fieldX = runtime.player.fieldX, fieldZ = runtime.player.fieldZ },
        before,
        "recovery input never moves the player"
      )
      local _, reason = runtime.saveCoordinator:capture(false)
      Assert.isNil(reason, "the save gate opens at the safe field")
    end, debug.traceback)
    local unbound = pcall(function()
      runtime:unbindBattlePresentation(binding)
    end)
    local closed = pcall(function()
      runtime:dispose()
    end)
    if not ok then
      error(failure, 0)
    end
    Assert.isTrue(unbound, "the lifetime releases its factory binding")
    Assert.isTrue(closed, "teardown releases the presented lifetime")
  end
end

-- Two consecutive wins build two fresh ports and screens, each disposed
-- exactly once, while withdrawing between rounds keeps the in-flight
-- launch on its admitted port and fails later admissions loudly: the
-- first round runs under a withdrawn binding to prove the admitted
-- launch completes on its own port, the second round rebinds the same
-- presentation for a fresh port, and a third admission without a
-- binding is refused instead of presenting without a screen.
function T.launches_reuse_ports_across_rebinds_and_refuse_without_a_binding()
  for _, versionId in ipairs(readyVersions()) do
    local runtime = bootRuntime(versionId)
    local envelope, binding, doubles, admit = bindEnvelope(runtime, versionId, dualMeasurement("presented-rebind:dual"))
    local disposed = {}
    local function watchDispose(round, port)
      local firstDispose = port.dispose
      port.dispose = function()
        disposed[#disposed + 1] = round
        return firstDispose()
      end
    end
    local ok, failure = xpcall(function()
      local firstField = runtime.session
      -- Round one runs under a withdrawn binding: the in-flight launch
      -- keeps the port it was admitted with and completes normally.
      runtime:launchBattle({ kind = "wild", details = { species = "CATERPIE", level = 3 } })
      waitConstructed(runtime, envelope)
      watchDispose(1, doubles.ports[#doubles.ports])
      runtime:unbindBattlePresentation(binding)
      settle(runtime, envelope, function(request)
        return sparringChoose(runtime, request)
      end, 6000)
      pump(runtime, envelope, 60)
      Assert.equal(runtime:lastBattleResult().result, "win", "round 1 reports its own win")
      Assert.isTrue(runtime.session == firstField, "round 1 reuses the live field session")
      -- Round two rebinds the same presentation for a fresh port.
      binding = runtime:bindBattlePresentation(admit)
      runtime:launchBattle({ kind = "wild", details = { species = "CATERPIE", level = 3 } })
      waitConstructed(runtime, envelope)
      local secondPort = doubles.ports[#doubles.ports]
      Assert.isTrue(secondPort ~= nil, "the second launch owns its port")
      watchDispose(2, secondPort)
      settle(runtime, envelope, function(request)
        return sparringChoose(runtime, request)
      end, 6000)
      pump(runtime, envelope, 60)
      Assert.equal(runtime:lastBattleResult().result, "win", "round 2 reports its own win")
      Assert.isTrue(runtime.session == firstField, "round 2 reuses the live field session")
      Assert.equal(#doubles.ports, 2, "two launches build two fresh ports")
      Assert.isTrue(doubles.ports[1] ~= doubles.ports[2], "each launch owns its port")
      Assert.deepEqual(disposed, { 1, 2 }, "each port disposes exactly once in launch order")
      -- A third admission without a binding fails loudly.
      runtime:unbindBattlePresentation(binding)
      local admitted, admitErr = pcall(runtime.launchBattle, runtime, {
        kind = "wild",
        details = { species = "CATERPIE", level = 3 },
      })
      Assert.isFalse(admitted, "admission without its factory fails loudly: " .. tostring(admitErr))
    end, debug.traceback)
    local unbound = pcall(function()
      runtime:unbindBattlePresentation(binding)
    end)
    local closed = pcall(function()
      runtime:dispose()
    end)
    if not ok then
      error(failure, 0)
    end
    Assert.isTrue(unbound, "the lifetime releases its factory binding")
    Assert.isTrue(closed, "teardown releases the presented lifetime")
  end
end

-- Quitting mid-battle releases the live battle and screen exactly once
-- while borrowed field services survive for their owner.
function T.quit_mid_battle_releases_once()
  for _, versionId in ipairs(readyVersions()) do
    local runtime = bootRuntime(versionId)
    local envelope, binding, doubles = bindEnvelope(runtime, versionId, dualMeasurement("presented-quit:dual"))
    local ok, failure = xpcall(function()
      runtime:launchBattle({ kind = "wild", details = { species = "CATERPIE", level = 3 } })
      waitConstructed(runtime, envelope)
      Assert.notNil(runtime.battleCoordinator:activeBattle(), "the launch is live before the quit")
      assert(envelope:liveScreen(), "the live screen owns the launch")
      runtime:dispose()
      Assert.isNil(runtime.battleCoordinator, "quitting releases the battle owner")
      Assert.isNil(envelope:liveScreen(), "quitting releases the live screen")
      Assert.isTrue(doubles.text.measures >= 0, "borrowed text services survive the quit")
    end, debug.traceback)
    local unbound = pcall(function()
      runtime:unbindBattlePresentation(binding)
    end)
    if not ok then
      error(failure, 0)
    end
    Assert.isTrue(unbound, "the lifetime releases its factory binding")
  end
end

-- The launch scene keeps its background, time-of-day, and fallback rules
-- while standing tiles select their own terrain classes: surfing still
-- forces the ocean background while the terrain follows the standing tile,
-- interiors still pin day, unknown tiles still fall back to the background
-- default, and scene selection stays deterministic across repeated captures.
-- Both wild step and scripted trainer launches share the one capture path.
local function launchHarness(overrides)
  local base = {
    session = { currentMap = { mapId = 33, fieldData = { battleBackground = "general" } } },
    player = { fieldX = 5, fieldZ = 6, surfaceId = 0 },
    playerAvatar = {
      status = function()
        return { durableState = "walking" }
      end,
    },
    localClock = {
      nowLocal = function()
        return { hour = 12 }
      end,
    },
  }
  for key, value in pairs(overrides or {}) do
    base[key] = value
  end
  local runtime = setmetatable(base, FieldRuntime)
  runtime.battleCoordinator = FieldBattleCoordinator.new(runtime)
  return runtime
end

local function launchStandingMap(background, behavior)
  return {
    mapId = 33,
    coordinateOrigin = { x = 0, z = 0 },
    collision = {
      containsLocal = function()
        return true
      end,
      getLocal = function()
        return { behavior = behavior }
      end,
    },
    fieldData = { battleBackground = background },
  }
end

function T.surfing_background_time_and_fallback_rules_hold_for_both_launch_kinds()
  local kinds = {
    { kind = "wild", method = "grass", payload = {} },
    { kind = "trainer", method = nil, payload = {} },
  }
  for _, launch in ipairs(kinds) do
    local function capture(overrides, method)
      local runtime = launchHarness(overrides)
      return runtime.battleCoordinator:_captureLaunchEnvironment(
        { kind = launch.kind, payload = launch.payload },
        method
      )
    end
    -- Outdoor night without a readable tile keeps the background default.
    local night = capture({
      session = { currentMap = { mapId = 33, fieldData = { battleBackground = "general" } } },
      localClock = {
        nowLocal = function()
          return { hour = 22 }
        end,
      },
    }, launch.method)
    Assert.equal(night.background, "general", "the compiled background resolves")
    Assert.equal(night.terrain, "plain", "an unreadable tile keeps the background default")
    Assert.equal(night.time, "night", "outdoor night reads night")
    Assert.equal(night.sceneKey, "general/plain/night", "the fallback joins its scene")
    -- Interiors pin day even at night.
    local interior = capture({
      session = { currentMap = { mapId = 61, fieldData = { battleBackground = "building_1" } } },
      localClock = {
        nowLocal = function()
          return { hour = 22 }
        end,
      },
    }, launch.method)
    Assert.equal(interior.background, "building_1", "interiors resolve their background")
    Assert.equal(interior.time, "day", "indoor backgrounds pin day")
    Assert.equal(interior.terrain, "building", "buildings default to building")
    -- A pond tile selects water without surfing.
    local pond = capture({
      session = { currentMap = launchStandingMap("general", 42) },
    }, launch.method)
    Assert.equal(pond.background, "general", "the compiled background resolves")
    Assert.equal(pond.terrain, "water", "a pond tile selects water without surfing")
    Assert.equal(pond.sceneKey, "general/water/day", "the water tile joins its scene")
    -- Surfing forces the ocean background while the terrain still follows
    -- the standing tile.
    local surfing = { durableState = "surfing" }
    local surfedPond = capture({
      session = { currentMap = launchStandingMap("general", 42) },
      playerAvatar = {
        status = function()
          return surfing
        end,
      },
    }, launch.method)
    Assert.equal(surfedPond.background, "ocean", "surfing overrides to ocean")
    Assert.equal(surfedPond.terrain, "water", "the standing tile still selects the terrain")
    Assert.equal(surfedPond.sceneKey, "ocean/water/day", "surfing water selects its scene")
    local surfedIce = capture({
      session = { currentMap = launchStandingMap("general", 32) },
      playerAvatar = {
        status = function()
          return surfing
        end,
      },
    }, launch.method)
    Assert.equal(surfedIce.background, "ocean", "surfing overrides to ocean")
    Assert.equal(surfedIce.terrain, "ice", "the standing tile selects the terrain while surfing")
    -- An unrecognized tile falls back to the background default.
    local unknown = capture({
      session = { currentMap = launchStandingMap("general", 99) },
    }, launch.method)
    Assert.equal(unknown.terrain, "plain", "an unknown tile keeps the background default")
    Assert.equal(unknown.sceneKey, "general/plain/day", "the unknown tile joins its fallback scene")
    -- The step method rides along, and repeated captures stay identical.
    Assert.equal(pond.method, launch.method, "the step method rides along")
    local again = capture({
      session = { currentMap = launchStandingMap("general", 42) },
    }, launch.method)
    Assert.deepEqual(again, pond, "scene selection consumes no hidden state between captures")
    Assert.notNil(
      BattlePresentationCache.parseSceneKey(surfedIce.sceneKey),
      "the surfing override scene passes the staged scene parser"
    )
  end
end

-- Forces the live screen into its failed mode with probe error text: the
-- envelope observes it on the next fixed tick exactly like a genuine
-- asset, audio, or draw failure.
---@param envelope table live presented-battle envelope under test driving
---@param message string probe failure text carried into the receipt
local function failLiveScreen(envelope, message)
  local screen = assert(envelope:liveScreen(), "the launch owns a live screen before the fault")
  screen._mode = "failed"
  screen._error = message
end

-- Answers open kernel decisions and acknowledges narration pages until the
-- owned launch reaches the wanted phase, exactly as a player would.
---@param runtime FieldRuntime live production runtime under test driving
---@param envelope table live presented-battle envelope under test driving
---@param wanted string launch phase under wait
---@param budget integer tick bound before a stuck launch fails loudly
local function driveLaunchToPhase(runtime, envelope, wanted, budget)
  local ticks = 0
  while ticks < budget do
    local launch = runtime.battleCoordinator._battleLaunch
    if launch ~= nil and launch.phase == wanted then
      return
    end
    if launch == nil then
      error("the launch settled before reaching " .. wanted, 0)
    end
    if launch.phase == "failed" then
      error("the launch failed before reaching " .. wanted .. ": " .. tostring(launch.error), 0)
    end
    local battle = runtime.battleCoordinator.battleRuntime
    if battle ~= nil then
      local current = battle:status()
      if current.phase == "failed" then
        error("the battle failed before the launch reached " .. wanted .. ": " .. tostring(current.error), 0)
      end
      if current.phase == "running" and current.request ~= nil then
        local answer = sparringChoose(runtime, current.request)
        local choices = answer
        if type(answer) == "table" and answer.kind ~= nil then
          choices = { answer }
        end
        local accepted, replyErr = battle:submit(SessionFixture.replyFor(current.request, choices))
        Assert.isTrue(accepted, "a legal decision is accepted: " .. tostring(replyErr))
      end
    end
    local screen = envelope:liveScreen()
    if screen ~= nil then
      local shown = screen:status()
      if shown.mode == "intro" or shown.mode == "narration" or shown.mode == "outcome" then
        envelope:input({ { type = "confirm" } })
      end
    end
    runtime:update(SourceTick.DT)
    envelope:updateFixed(TICK)
    ticks = ticks + 1
  end
  error("the launch never reached " .. wanted .. " within its tick budget", 0)
end

-- A lost renderer is a bug, never a recoverable battle outcome: wherever
-- it lands, before or after mechanics commit, the next pump faults the
-- runtime with the original screen error instead of quietly restoring
-- the field.
function T.failed_screen_faults_the_runtime()
  for _, versionId in ipairs(readyVersions()) do
    for _, point in ipairs({ "active", "terminal" }) do
      local runtime = bootRuntime(versionId)
      local envelope, binding, _ =
        bindEnvelope(runtime, versionId, dualMeasurement("lost-renderer-precommit:" .. point))
      local ok, failure = xpcall(function()
        runtime:launchBattle({ kind = "wild", details = { species = "CATERPIE", level = 3 } })
        -- Host-only updates never advance a presented launch: presence
        -- holds, nothing constructs, and cover stays down.
        for _ = 1, 10 do
          runtime:update(SourceTick.DT)
        end
        Assert.equal(runtime.overworld:phase(), "present", "host updates never request leave")
        Assert.isNil(runtime.battleCoordinator:activeBattle(), "host updates never construct")
        Assert.equal(envelope:cover().coefficient, 0, "host updates never advance cover")
        if point == "leaving" then
          local ticks = 0
          while runtime.overworld:phase() ~= "leaving" and ticks < 900 do
            runtime:update(SourceTick.DT)
            envelope:updateFixed(TICK)
            ticks = ticks + 1
          end
          Assert.equal(runtime.overworld:phase(), "leaving", "the fault lands while the world is leaving")
        elseif point == "active" then
          waitConstructed(runtime, envelope)
          Assert.equal(runtime.overworld:phase(), "absent", "the fault lands while the world is absent")
          -- Host-only updates never advance the owned battle clock either.
          local phaseBefore = runtime.battleCoordinator:activeBattle():status().phase
          for _ = 1, 10 do
            runtime:update(SourceTick.DT)
          end
          Assert.equal(
            runtime.battleCoordinator:activeBattle():status().phase,
            phaseBefore,
            "host updates never advance the owned battle clock"
          )
        elseif point == "terminal" then
          driveLaunchToPhase(runtime, envelope, "terminal", 2400)
        else
          Assert.equal(runtime.overworld:phase(), "present", "the covering fault lands before the world leaves")
        end
        failLiveScreen(envelope, "probe render failure at " .. point)
        local survived, raised = pcall(function()
          for _ = 1, 10 do
            runtime:update(SourceTick.DT)
            envelope:updateFixed(TICK)
          end
        end)
        Assert.isFalse(survived, "a lost renderer faults the runtime at " .. point)
        Assert.isTrue(
          tostring(raised):find("probe render failure at " .. point, 1, true) ~= nil,
          "the fault carries the original screen error at " .. point .. ": " .. tostring(raised)
        )
      end, debug.traceback)
      local unbound = pcall(function()
        runtime:unbindBattlePresentation(binding)
      end)
      local closed = pcall(function()
        runtime:dispose()
      end)
      if not ok then
        error(failure, 0)
      end
      Assert.isTrue(unbound, "the lifetime releases its factory binding")
      Assert.isTrue(closed, "teardown releases the presented lifetime")
    end
  end
end

-- Portrait demands speak exact canonical selectors, never shorthand
-- species/form/facing keys: one staged exact selector prepares, a
-- shorthand key fails instead of expanding to a guessed male/plain
-- variant, and an unknown exact selector fails naming that selector
-- instead of substituting a plausible visual.
function T.portrait_demands_speak_exact_canonical_selectors()
  local MonCache = require("libs.assets.src.MonCache")
  local versionId = readyVersions()[1]
  local cacheFs = CacheFs.forVersion(versionId)
  local portraits =
    assert(cacheFs:loadLua(MonCache.portraitManifestPath()), versionId .. " carries its staged portrait manifest")
  local markers =
    assert(cacheFs:loadLua(MonCache.indexPath()), versionId .. " carries its staged mon index").portraitPages
  local staged = nil
  local keys = {}
  for selector in pairs(assert(portraits.entries, versionId .. " plans its portrait entries")) do
    keys[#keys + 1] = selector
  end
  table.sort(keys)
  for _, selector in ipairs(keys) do
    local entry = portraits.entries[selector]
    if type(entry) == "table" and type(entry.pageId) == "number" then
      local ready = MonCache.isPageReady(cacheFs, "portraits", entry.pageId, markers[entry.pageId + 1])
      if ready and staged == nil then
        staged = selector
      end
    end
  end
  Assert.notNil(staged, versionId .. " stages at least one ready portrait cell")
  local envelope = FieldBattlePresentation.new({
    cacheFs = cacheFs,
    windows = recordingWindows(),
    text = recordingText(),
    measureDisplay = function()
      return dualMeasurement("portrait-demand:dual")
    end,
  })
  local function demand(pages)
    return {
      launchId = "demand-probe",
      scenes = {},
      pages = pages,
      audio = { roles = {}, banks = {}, cries = {} },
    }
  end
  local services = envelope:_preparationServices()
  Assert.isTrue(services.prepare(demand({ staged })), "one staged exact selector prepares")
  local shorthand, shorthandErr = services.prepare(demand({ "CHIKORITA/0/back" }))
  Assert.isTrue(
    shorthand == nil and type(shorthandErr) == "string" and shorthandErr ~= "",
    "a shorthand key fails instead of expanding to a guessed variant"
  )
  local missing, missingErr = services.prepare(demand({ "NOPE/f9/female/plain" }))
  Assert.isTrue(missing == nil, "an unknown exact selector never prepares")
  Assert.isTrue(
    type(missingErr) == "string" and missingErr:find("NOPE/f9/female/plain", 1, true) ~= nil,
    "the unknown selector failure names its exact selector"
  )
  envelope:dispose()
end

-- A staged scene whose shared-owner classification fails reports a
-- terminal keyed failure instead of an unusable nil: the failed key is
-- attempted once, later polls replay the latched error without
-- re-entering the owner, and disposal stays idempotent.
function T.staged_scene_upload_failure_reports_its_key_once()
  local sceneKey = "general/plain/day"
  local imagePath = BattlePresentationCache.sceneImagePath(sceneKey)
  local pool = scriptedPool("probe-decode-boom")
  local cacheFs = { versionId = "upload-probe" }
  function cacheFs:loadLua(_)
    return nil
  end
  local envelope = FieldBattlePresentation.new({
    cacheFs = cacheFs,
    windows = recordingWindows(),
    text = recordingText(),
    measureDisplay = function()
      return dualMeasurement("upload-failure:dual")
    end,
    graphics = {},
    imagePool = pool,
  })
  local services = envelope:_preparationServices()
  local handle, reason = services.drawable("scene:" .. sceneKey)
  Assert.isNil(handle, "the failed upload hands out no image")
  Assert.isTrue(type(reason) == "string" and reason ~= "", "the failed upload names its reason")
  Assert.isTrue(reason:find(sceneKey, 1, true) ~= nil, "the failure names its scene key")
  Assert.isTrue(reason:find(imagePath, 1, true) ~= nil, "the failure names its staged path")
  local handleAgain, reasonAgain = services.drawable("scene:" .. sceneKey)
  Assert.isNil(handleAgain, "the failed key stays failed without a substitute")
  Assert.equal(reasonAgain, reason, "the latched failure replays identically")
  Assert.equal(pool.requests, 1, "the failed upload is attempted once, never retried per tick")
  envelope:dispose()
  envelope:dispose()
end

-- A scene the worker has not staged yet waits instead of failing: the
-- launch demand reaches the borrowed host once, preparation answers
-- pending while the entrance cover holds, and the same demand prepares
-- once the host reports ready and the staged bytes validate. Nothing
-- paints a blank success and nothing fails before the build settles.
function T.cold_scene_demand_waits_then_enters_once_staged()
  local PngWriter = require("libs.assets.src.PngWriter")
  local sceneKey = "general/plain/day"
  local recordPath = BattlePresentationCache.scenePath(sceneKey)
  local imagePath = BattlePresentationCache.sceneImagePath(sceneKey)
  local charactersPath = BattlePresentationCache.sceneCharactersPath(sceneKey)
  local mapPath = BattlePresentationCache.sceneMapPath(sceneKey)
  local palettePath = BattlePresentationCache.scenePalettePath(sceneKey)
  local mapEntries = {}
  for index = 1, 2048 do
    mapEntries[index] = { tile = 0, flipH = false, flipV = false, palette = 0 }
  end
  local paletteColors = {}
  for index = 1, 256 do
    paletteColors[index] = { r = 0, g = 0, b = 0 }
  end
  for _, versionId in ipairs(readyVersions()) do
    local cacheFs = CacheFs.forVersion(versionId)
    local stagedRecord = {
      schema = BattlePresentationCache.SCENE_SCHEMA,
      key = sceneKey,
      background = "general",
      terrain = "plain",
      time = "day",
      canvasWidth = 512,
      canvasHeight = 256,
      viewport = { x = 0, y = 0, width = 256, height = 192 },
      layers = {
        {
          key = "background",
          backing = { width = 512, height = 256, mapWidth = 64, mapHeight = 32 },
          viewport = { x = 0, y = 0, width = 256, height = 192 },
          scroll = { x = 0, y = 0 },
          characters = {
            key = "battle-scene/general-plain-day/background/characters",
            path = charactersPath,
            format = "indexed8",
          },
          map = {
            key = "battle-scene/general-plain-day/background/map",
            path = mapPath,
            format = "tilemap",
          },
          palette = {
            key = "battle-scene/general-plain-day/background/palette",
            path = palettePath,
            format = "rgb888",
          },
        },
      },
      imagePath = imagePath,
    }
    local stagedBytes = PngWriter.encode(512, 256, string.rep(string.char(9, 9, 9, 255), 512 * 256))
    local revealed = false
    local view = { versionId = cacheFs.versionId }
    function view.loadLua(_, path)
      if path == recordPath then
        return revealed and stagedRecord or nil
      end
      if path == mapPath then
        return revealed and { width = 512, height = 256, entries = mapEntries } or nil
      end
      if path == palettePath then
        return revealed and { colors = paletteColors } or nil
      end
      return cacheFs:loadLua(path)
    end
    function view.read(_, path)
      if path == imagePath then
        return revealed and stagedBytes or nil
      end
      if path == charactersPath then
        return revealed and string.rep("c", 65536) or nil
      end
      return cacheFs:read(path)
    end
    local asked = {}
    local answer = { ready = nil, failure = nil }
    local derivedAssets = {}
    function derivedAssets.requestBattleScene(key, urgency)
      asked[#asked + 1] = { key = key, urgency = urgency }
      return answer.ready, answer.failure
    end
    local envelope = FieldBattlePresentation.new({
      cacheFs = view,
      windows = recordingWindows(),
      text = recordingText(),
      measureDisplay = function()
        return dualMeasurement("cold-scene:dual")
      end,
      graphics = {},
      derivedAssets = derivedAssets,
    })
    local function demand()
      return {
        launchId = "cold-scene-probe",
        scenes = { sceneKey },
        pages = {},
        audio = { roles = {}, banks = {}, cries = {} },
      }
    end
    local services = envelope:_preparationServices()
    local waiting, waitErr = services.prepare(demand())
    Assert.isTrue(waiting == false, versionId .. " holds its cold scene pending instead of failing")
    Assert.isNil(waitErr, versionId .. " carries no failure while the scene builds")
    Assert.equal(#asked, 1, versionId .. " demands its scene through the borrowed host")
    Assert.equal(asked[1].key, sceneKey, versionId .. " demands exactly its launch scene")
    Assert.equal(asked[1].urgency, "required", versionId .. " demands its scene urgently")
    answer.ready = true
    revealed = true
    Assert.isTrue(services.prepare(demand()), versionId .. " enters once the staged scene validates")
    envelope:dispose()
  end
end

-- A genuine scene build failure is terminal with its scene named: the
-- preparation answers failed carrying both the scene key and the worker
-- cause, deterministically on every poll, instead of waiting forever or
-- painting a blank success.
function T.scene_host_failure_fails_closed_naming_its_scene()
  local sceneKey = "city/sand/night"
  local recordPath = BattlePresentationCache.scenePath(sceneKey)
  local imagePath = BattlePresentationCache.sceneImagePath(sceneKey)
  for _, versionId in ipairs(readyVersions()) do
    local cacheFs = CacheFs.forVersion(versionId)
    local view = { versionId = cacheFs.versionId }
    function view.loadLua(_, path)
      if path == recordPath then
        return nil
      end
      return cacheFs:loadLua(path)
    end
    function view.read(_, path)
      if path == imagePath then
        return nil
      end
      return cacheFs:read(path)
    end
    local asked = 0
    local derivedAssets = {}
    function derivedAssets.requestBattleScene(_, _)
      asked = asked + 1
      return nil, "probe-controller-boom"
    end
    local envelope = FieldBattlePresentation.new({
      cacheFs = view,
      windows = recordingWindows(),
      text = recordingText(),
      measureDisplay = function()
        return dualMeasurement("failed-scene:dual")
      end,
      graphics = {},
      derivedAssets = derivedAssets,
    })
    local function demand()
      return {
        launchId = "failed-scene-probe",
        scenes = { sceneKey },
        pages = {},
        audio = { roles = {}, banks = {}, cries = {} },
      }
    end
    local services = envelope:_preparationServices()
    local failed, failure = services.prepare(demand())
    Assert.isNil(failed, versionId .. " never reads ready for its failed scene")
    Assert.isTrue(
      type(failure) == "string" and failure:find(sceneKey, 1, true) ~= nil,
      versionId .. " names its failed scene: " .. tostring(failure)
    )
    Assert.isTrue(
      tostring(failure):find("probe-controller-boom", 1, true) ~= nil,
      versionId .. " carries its worker cause: " .. tostring(failure)
    )
    local failedAgain, failureAgain = services.prepare(demand())
    Assert.isNil(failedAgain, versionId .. " stays failed across polls")
    Assert.equal(failureAgain, failure, versionId .. " keeps its failure context across polls")
    Assert.isTrue(asked >= 1, versionId .. " routes its scene demand through the borrowed host")
    envelope:dispose()
  end
end

-- An upload-capable graphics double behind worker-backed launches: real
-- staged bytes still decode through the host image loader while the owned
-- handle stays a lightweight test record, so entry can prove readiness
-- without GPU objects. A namespace without an uploader stays unusable
-- for entry; only a present uploader answers handles.
---@return table upload-capable graphics namespace
local function uploadCapableGraphics()
  local graphics = {}
  function graphics.newImage(_)
    local handle = {}
    function handle.setFilter(...) end
    return handle
  end
  return graphics
end

-- A scene worker failure aborts the pending launch without ever showing
-- a screen: the admitted port carries all five operations yet stays
-- unacknowledged while the build is pending, the worker cause fails the
-- launch exactly once naming its scene, and the abort reveal releases
-- the launch with no interactive battle and no second report. Disposal
-- stays idempotent throughout.
function T.scene_worker_failure_aborts_the_pending_launch_without_a_result()
  local sceneKey = "general/plain/day"
  for _, versionId in ipairs(readyVersions()) do
    local cacheFs = CacheFs.forVersion(versionId)
    local worker = { ready = nil, failure = nil, asks = {} }
    local derivedAssets = {}
    function derivedAssets.requestBattleScene(key, urgency)
      worker.asks[#worker.asks + 1] = { key = key, urgency = urgency }
      return worker.ready, worker.failure
    end
    local host = { phase = "active", notifies = {} }
    function host.status()
      return { phase = host.phase }
    end
    function host.advance() end
    function host.submit(_)
      return true
    end
    function host.notify(event, reason)
      host.notifies[#host.notifies + 1] = { event = event, reason = reason }
    end
    local envelope = FieldBattlePresentation.new({
      cacheFs = cacheFs,
      windows = recordingWindows(),
      text = recordingText(),
      audio = recordingAudio(),
      measureDisplay = function()
        return dualMeasurement("pending-failure:dual")
      end,
      graphics = {},
      derivedAssets = derivedAssets,
    })
    local launchId = "pending-failure-probe"
    local port = envelope:factory()({
      launchId = launchId,
      kind = "wild",
      environment = { sceneKey = sceneKey },
      host = host,
    })
    Assert.isTrue(type(port.enter) == "function", "the admitted port enters")
    Assert.isTrue(type(port.present) == "function", "the admitted port presents")
    Assert.isTrue(type(port.ready) == "function", "the admitted port reports readiness")
    Assert.isTrue(type(port.leave) == "function", "the admitted port leaves")
    Assert.isTrue(type(port.dispose) == "function", "the admitted port disposes")
    Assert.isNil(envelope:liveScreen(), "the pending launch holds no screen while its scene builds")
    for _ = 1, 30 do
      envelope:updateFixed(TICK)
    end
    Assert.isFalse(port.enter({ launchId = launchId, kind = "wild" }), "the pending launch stays unacknowledged")
    Assert.isFalse(port.ready(), "the pending launch never reads interactive")
    Assert.isNil(envelope:liveScreen(), "polling never builds a screen before the scene stages")
    Assert.isTrue(#worker.asks >= 1, "the pending launch demands its scene through the borrowed host")
    for _, ask in ipairs(worker.asks) do
      Assert.equal(ask.key, sceneKey, "every demand names exactly the launch scene")
      Assert.equal(ask.urgency, "required", "every demand arrives urgently")
    end
    Assert.equal(#host.notifies, 0, "pending reports no failure")
    worker.failure = "probe-controller-boom"
    for _ = 1, 60 do
      envelope:updateFixed(TICK)
    end
    Assert.isFalse(port.ready(), "the failed launch never reads interactive")
    Assert.isNil(envelope:liveScreen(), "the failed launch owns no screen")
    local failures = {}
    for _, note in ipairs(host.notifies) do
      if note.event == "screen-failed" then
        failures[#failures + 1] = note
      end
    end
    Assert.equal(#failures, 1, "the worker failure reports exactly once")
    Assert.isTrue(
      type(failures[1].reason) == "string" and failures[1].reason:find(sceneKey, 1, true) ~= nil,
      "the report names its scene: " .. tostring(failures[1].reason)
    )
    Assert.isTrue(
      tostring(failures[1].reason):find("probe-controller-boom", 1, true) ~= nil,
      "the report carries its worker cause: " .. tostring(failures[1].reason)
    )
    for _ = 1, 30 do
      envelope:updateFixed(TICK)
    end
    local failuresAgain = 0
    for _, note in ipairs(host.notifies) do
      if note.event == "screen-failed" then
        failuresAgain = failuresAgain + 1
      end
    end
    Assert.equal(failuresAgain, 1, "later polls report no second failure")
    host.phase = "aborting"
    for _ = 1, 10 do
      envelope:updateFixed(TICK)
    end
    host.phase = "abort-revealing"
    for _ = 1, 10 do
      envelope:updateFixed(TICK)
    end
    host.phase = "complete"
    for _ = 1, 5 do
      envelope:updateFixed(TICK)
    end
    Assert.isFalse(envelope:ownsInput(), "the abort reveal releases the launch")
    Assert.isNil(envelope:liveScreen(), "the settled launch owns no screen")
    port.dispose()
    port.dispose()
    envelope:dispose()
    envelope:dispose()
  end
end

-- Disposing a pending launch builds nothing late and leaves the next
-- launch alone: the first port admits no screen while its scene builds,
-- disposal plus a late worker answer still builds nothing, the next
-- admission constructs at most one screen once its own scene is ready,
-- and every stale callback on the old port stays inert.
function T.disposed_pending_launch_builds_no_screen_for_the_next_launch()
  local firstScene = "general/plain/day"
  local secondScene = "general/grass/day"
  for _, versionId in ipairs(readyVersions()) do
    local cacheFs = CacheFs.forVersion(versionId)
    local worker = { ready = nil, failure = nil, asks = {} }
    local derivedAssets = {}
    function derivedAssets.requestBattleScene(key, urgency)
      worker.asks[#worker.asks + 1] = { key = key, urgency = urgency }
      return worker.ready, worker.failure
    end
    local function launchHost()
      local host = { phase = "active", notifies = {} }
      function host.status()
        return { phase = host.phase }
      end
      function host.advance() end
      function host.submit(_)
        return true
      end
      function host.notify(event, reason)
        host.notifies[#host.notifies + 1] = { event = event, reason = reason }
      end
      return host
    end
    local ScreenState = require("game.hgss.src.battle.BattleScreenState")
    local realNew = ScreenState.new
    local constructions = {}
    ScreenState.new = function(opts)
      constructions[#constructions + 1] = opts ~= nil and opts.launchId or nil
      return realNew(opts)
    end
    local ok, failure = xpcall(function()
      local envelope = FieldBattlePresentation.new({
        cacheFs = cacheFs,
        windows = recordingWindows(),
        text = recordingText(),
        audio = recordingAudio(),
        measureDisplay = function()
          return dualMeasurement("disposed-pending:dual")
        end,
        graphics = uploadCapableGraphics(),
        derivedAssets = derivedAssets,
        imagePool = scriptedPool(),
      })
      local host1 = launchHost()
      local firstId = "disposed-first-probe"
      local port1 = envelope:factory()({
        launchId = firstId,
        kind = "wild",
        environment = { sceneKey = firstScene },
        host = host1,
      })
      Assert.isNil(envelope:liveScreen(), "the pending first launch holds no screen")
      Assert.equal(#constructions, 0, "the pending first launch constructs no screen")
      for _ = 1, 10 do
        envelope:updateFixed(TICK)
      end
      Assert.equal(#constructions, 0, "polling never constructs before the scene stages")
      port1.dispose()
      port1.dispose()
      worker.ready = true
      for _ = 1, 60 do
        envelope:updateFixed(TICK)
      end
      Assert.equal(#constructions, 0, "a late answer builds no screen for the disposed launch")
      Assert.isNil(envelope:liveScreen(), "the disposed launch stays screenless")
      Assert.equal(#host1.notifies, 0, "the disposed launch reports nothing late")
      Assert.isFalse(port1.enter({ launchId = firstId, kind = "wild" }), "the disposed port stays unacknowledged")
      Assert.isFalse(port1.ready(), "the disposed port never reads interactive")
      host1.phase = "complete"
      for _ = 1, 5 do
        envelope:updateFixed(TICK)
      end
      worker.ready = nil
      local host2 = launchHost()
      local secondId = "disposed-second-probe"
      local port2 = envelope:factory()({
        launchId = secondId,
        kind = "wild",
        environment = { sceneKey = secondScene },
        host = host2,
      })
      for _ = 1, 10 do
        envelope:updateFixed(TICK)
      end
      Assert.equal(#constructions, 0, "the pending second launch holds no screen either")
      Assert.isNil(envelope:liveScreen(), "polling never builds the second screen early")
      worker.ready = true
      local entered = false
      for _ = 1, 120 do
        envelope:updateFixed(TICK)
        if port2.enter({ launchId = secondId, kind = "wild" }) then
          entered = true
          break
        end
      end
      Assert.isTrue(entered, "the staged second launch enters")
      Assert.equal(#constructions, 1, "the next launch constructs exactly one screen")
      Assert.equal(constructions[1], secondId, "the one screen belongs to the second launch")
      local live = assert(envelope:liveScreen(), "the second launch owns its live screen")
      Assert.isFalse(port1.enter({ launchId = firstId, kind = "wild" }), "the stale port never reacknowledges")
      Assert.isFalse(port1.ready(), "the stale port never reads interactive")
      local presentOk = pcall(port1.present, { launchId = firstId, packetId = 1 })
      Assert.isTrue(presentOk, "a stale delivery never raises")
      Assert.isTrue(envelope:liveScreen() == live, "a stale delivery never swaps the live screen")
      Assert.equal(#constructions, 1, "stale callbacks construct nothing further")
      port1.dispose()
      port2.dispose()
      port2.dispose()
      envelope:dispose()
    end, debug.traceback)
    ScreenState.new = realNew
    if not ok then
      error(failure, 0)
    end
  end
end

-- Entry waits for the staged scene through the real runtime gate: the
-- admitted port answers no entry and no readiness while the scene
-- builds, so a live battle runtime stays in preparing; once the worker
-- publishes, the same port enters and the runtime leaves preparing
-- without a second admission.
function T.preparing_waits_for_the_staged_scene_through_the_runtime_gate()
  local BattleRuntime = require("game.hgss.src.battle.BattleRuntime")
  local sceneKey = "general/grass/day"
  for _, versionId in ipairs(readyVersions()) do
    local cacheFs = CacheFs.forVersion(versionId)
    local worker = { ready = nil, failure = nil, asks = {} }
    local derivedAssets = {}
    function derivedAssets.requestBattleScene(key, urgency)
      worker.asks[#worker.asks + 1] = { key = key, urgency = urgency }
      return worker.ready, worker.failure
    end
    local host = { phase = "active", notifies = {} }
    function host.status()
      return { phase = host.phase }
    end
    function host.advance() end
    function host.submit(_)
      return true
    end
    function host.notify(event, reason)
      host.notifies[#host.notifies + 1] = { event = event, reason = reason }
    end
    local envelope = FieldBattlePresentation.new({
      cacheFs = cacheFs,
      windows = recordingWindows(),
      text = recordingText(),
      audio = recordingAudio(),
      measureDisplay = function()
        return dualMeasurement("preparing-gate:dual")
      end,
      graphics = uploadCapableGraphics(),
      derivedAssets = derivedAssets,
      imagePool = scriptedPool(),
    })
    local launchId = "preparing-gate-probe"
    local port = envelope:factory()({
      launchId = launchId,
      kind = "wild",
      environment = { sceneKey = sceneKey },
      host = host,
    })
    local battle = BattleRuntime.new({
      request = { id = launchId, kind = "wild", payload = { species = "CATERPIE", level = 3 } },
      presentation = port,
    })
    local ok, failure = xpcall(function()
      for _ = 1, 10 do
        envelope:updateFixed(TICK)
        battle:update()
      end
      Assert.isFalse(port.enter({ launchId = launchId, kind = "wild" }), "entry waits while the scene builds")
      Assert.isFalse(port.ready(), "readiness waits while the scene builds")
      Assert.equal(battle:status().phase, "preparing", "the runtime holds preparing behind the pending port")
      Assert.isNil(envelope:liveScreen(), "no screen exists before the worker publishes")
      worker.ready = true
      local left = false
      for _ = 1, 120 do
        envelope:updateFixed(TICK)
        battle:update()
        if battle:status().phase ~= "preparing" then
          left = true
          break
        end
      end
      Assert.isTrue(left, "the staged scene lets the runtime leave preparing")
      Assert.isTrue(port.enter({ launchId = launchId, kind = "wild" }), "entry acknowledges after the build")
      Assert.notNil(envelope:liveScreen(), "the staged scene owns its live screen")
      Assert.equal(#host.notifies, 0, "the staged build reports no failure")
    end, debug.traceback)
    local closed = pcall(function()
      battle:dispose()
    end)
    local released = pcall(function()
      envelope:dispose()
    end)
    if not ok then
      error(failure, 0)
    end
    Assert.isTrue(closed, "teardown releases the live battle")
    Assert.isTrue(released, "teardown releases the envelope")
  end
end

-- A scene failure reports once without driving the host: under cover and
-- while active the launch names its scene and cause exactly once, owns
-- no screen and never reads interactive, and no port callback advances
-- the host on its own.
function T.scene_failure_reports_once_without_driving_the_host()
  local sceneKey = "general/plain/day"
  for _, point in ipairs({ "covering", "active" }) do
    for _, versionId in ipairs(readyVersions()) do
      local cacheFs = CacheFs.forVersion(versionId)
      local worker = { ready = nil, failure = nil }
      local derivedAssets = {}
      function derivedAssets.requestBattleScene(_, _)
        return worker.ready, worker.failure
      end
      local host = { phase = point, notifies = {}, advances = 0, advancing = false, violations = 0 }
      function host.status()
        return { phase = host.phase }
      end
      function host.advance()
        host.advancing = true
        host.advances = host.advances + 1
        host.advancing = false
      end
      function host.submit(_)
        return true
      end
      function host.notify(event, reason)
        if host.advancing then
          host.violations = host.violations + 1
        end
        host.notifies[#host.notifies + 1] = { event = event, reason = reason }
      end
      local envelope = FieldBattlePresentation.new({
        cacheFs = cacheFs,
        windows = recordingWindows(),
        text = recordingText(),
        audio = recordingAudio(),
        measureDisplay = function()
          return dualMeasurement("failure-without-advance:" .. point)
        end,
        graphics = uploadCapableGraphics(),
        derivedAssets = derivedAssets,
      })
      local launchId = "failure-without-advance-" .. point
      local port = envelope:factory()({
        launchId = launchId,
        kind = "wild",
        environment = { sceneKey = sceneKey },
        host = host,
      })
      for _ = 1, 5 do
        envelope:updateFixed(SourceTick.DT)
      end
      Assert.equal(host.advances, 5, "fixed updates advance the host once each at " .. point)
      Assert.equal(#host.notifies, 0, "pending reports no failure at " .. point)
      local driven = host.advances
      Assert.isFalse(port.enter({ launchId = launchId, kind = "wild" }), "entry waits at " .. point)
      Assert.isFalse(port.ready(), "readiness waits at " .. point)
      Assert.isFalse(port.leave({ launchId = launchId }), "leave waits at " .. point)
      local presentOk = pcall(port.present, { launchId = launchId, packetId = 1 })
      Assert.isTrue(presentOk, "a pending delivery never raises at " .. point)
      Assert.equal(host.advances, driven, "port callbacks never advance the host at " .. point)
      worker.failure = "probe-controller-boom"
      for _ = 1, 10 do
        envelope:updateFixed(SourceTick.DT)
      end
      Assert.equal(host.advances, driven + 10, "failure ticks advance the host once each at " .. point)
      Assert.equal(host.violations, 0, "the report never fires inside a host advance at " .. point)
      Assert.isFalse(port.ready(), "the failed launch never reads interactive at " .. point)
      Assert.isNil(envelope:liveScreen(), "the failed launch owns no screen at " .. point)
      local failures = {}
      for _, note in ipairs(host.notifies) do
        if note.event == "screen-failed" then
          failures[#failures + 1] = note
        end
      end
      Assert.equal(#failures, 1, "the worker failure reports exactly once at " .. point)
      Assert.isTrue(
        type(failures[1].reason) == "string" and failures[1].reason:find(sceneKey, 1, true) ~= nil,
        "the report names its scene at " .. point .. ": " .. tostring(failures[1].reason)
      )
      Assert.isTrue(
        tostring(failures[1].reason):find("probe-controller-boom", 1, true) ~= nil,
        "the report carries its worker cause at " .. point .. ": " .. tostring(failures[1].reason)
      )
      for _ = 1, 5 do
        envelope:updateFixed(TICK)
      end
      local failuresAgain = 0
      for _, note in ipairs(host.notifies) do
        if note.event == "screen-failed" then
          failuresAgain = failuresAgain + 1
        end
      end
      Assert.equal(failuresAgain, 1, "later polls report no second failure at " .. point)
      Assert.equal(host.violations, 0, "later polls never report inside a host advance at " .. point)
      port.dispose()
      port.dispose()
      envelope:dispose()
      envelope:dispose()
    end
  end
end

-- A caller-owned graphics double behind explicit draws: paint operations
-- are counted together while image creation is tracked apart, since
-- uploads may legitimately happen during updates but painting may not.
local function paintCountingGraphics()
  local graphics = { paint = 0, uploads = 0, draws = {} }
  local function paint()
    graphics.paint = graphics.paint + 1
  end
  function graphics.push(_)
    paint()
  end
  function graphics.pop()
    paint()
  end
  function graphics.getDepthMode()
    return nil
  end
  function graphics.setDepthMode(_, _)
    paint()
  end
  function graphics.setShader(_)
    paint()
  end
  function graphics.setBlendMode(_, _)
    paint()
  end
  function graphics.setScissor(_, _, _, _)
    paint()
  end
  function graphics.origin()
    paint()
  end
  function graphics.intersectScissor(_, _, _, _)
    paint()
  end
  function graphics.translate(_, _)
    paint()
  end
  function graphics.scale(_, _)
    paint()
  end
  function graphics.transformPoint(x, y)
    return x, y
  end
  function graphics.getColor()
    return 1, 1, 1, 1
  end
  function graphics.setColor(_, _, _, _)
    paint()
  end
  function graphics.rectangle(_, _, _, _, _)
    paint()
  end
  function graphics.newQuad(x, y, w, h, imgW, imgH)
    return { x = x, y = y, w = w, h = h, imgW = imgW, imgH = imgH }
  end
  function graphics.draw(drawable, quad, x, y)
    paint()
    if type(quad) == "number" then
      quad, x, y = nil, quad, x
    end
    local key = drawable
    if type(drawable) == "table" then
      key = drawable.key or drawable.handle or tostring(drawable)
    end
    graphics.draws[#graphics.draws + 1] = { key = key, quad = quad, x = x, y = y }
  end
  function graphics.newImage(data)
    graphics.uploads = graphics.uploads + 1
    local width, height = 8, 8
    if type(data) == "table" and type(data.getDimensions) == "function" then
      local decoded, decodedWidth, decodedHeight = pcall(function()
        return data:getDimensions()
      end)
      if decoded and type(decodedWidth) == "number" and type(decodedHeight) == "number" then
        width, height = decodedWidth, decodedHeight
      end
    end
    local image = { key = "test-image", width = width, height = height }
    function image.setFilter(_, _, _) end
    function image.release() end
    function image.getWidth()
      return width
    end
    function image.getHeight()
      return height
    end
    function image.getDimensions()
      return width, height
    end
    return image
  end
  -- The native picture and menu passes compose through canvases,
  -- meshes, and shaders: construction stays untracked like uploads
  -- above so repeated draws stay comparable, while the state calls
  -- around them still count as paint.
  function graphics.newCanvas(width, height)
    local canvas = { width = width, height = height }
    function canvas.setFilter(_, _, _) end
    function canvas.release() end
    function canvas.getWidth()
      return width
    end
    function canvas.getHeight()
      return height
    end
    function canvas.getDimensions()
      return width, height
    end
    return canvas
  end
  function graphics.newMesh(_, _, _, _)
    local mesh = {}
    function mesh.setVertices(_) end
    function mesh.setTexture(_) end
    function mesh.release() end
    return mesh
  end
  function graphics.newShader(_)
    local shader = {}
    function shader.send(_, _, _) end
    function shader.release() end
    return shader
  end
  function graphics.getCanvas()
    return nil
  end
  function graphics.setCanvas(_)
    paint()
  end
  function graphics.clear(_, _, _, _)
    paint()
  end
  function graphics.getShader()
    return nil
  end
  function graphics.getBlendMode()
    return nil
  end
  function graphics.getScissor()
    return nil
  end
  function graphics.isWireframe()
    return false
  end
  function graphics.getMeshCullMode()
    return nil
  end
  function graphics.setWireframe(_)
    paint()
  end
  function graphics.setMeshCullMode(_)
    paint()
  end
  return graphics
end

-- Drives one launched battle until its screen exposes the command view,
-- failing loudly when the launch never arrives there.
---@param runtime FieldRuntime live production runtime under test driving
---@param envelope table live presented-battle envelope under test driving
---@return table live battle screen on its command view
local function driveToCommandMode(runtime, envelope)
  local ticks = 0
  while ticks < 900 do
    runtime:update(SourceTick.DT)
    envelope:updateFixed(TICK)
    ticks = ticks + 1
    local screen = envelope:liveScreen()
    if screen ~= nil and screen:status().mode == "command" then
      return screen
    end
  end
  error("the presented battle never reached its command", 0)
end

-- Settles the live command view inside one native arrow run before a
-- frozen draw pair: the selection arrow cycles its cells on accepted
-- ticks, so two draws spaced by updates only paint identically inside
-- a single run. Ten consecutive equal paints prove the long two-object
-- run with margin left for the frozen gap.
---@param envelope table live presented-battle envelope under test driving
local function settleArrowRun(envelope)
  local paint, run = nil, 0
  for _ = 1, 200 do
    local spy = paintCountingGraphics()
    if envelope:drawBattle({ graphics = spy }) then
      if spy.paint == paint then
        run = run + 1
      else
        paint, run = spy.paint, 1
      end
      if run >= 10 then
        return
      end
    end
    envelope:updateFixed(TICK)
  end
  error("the live command view never settled into one arrow run", 0)
end

-- One presented wild win carries every phase-shaped assertion of the
-- shared fixture: cover completes before construction with semantic
-- leave under full cover, follower clocks freeze under the hold, fixed
-- updates paint nothing without an explicit draw at the command root,
-- menu input reaches the screen without leaking to the field, the
-- reveal withholds its receipt until the safe field commits, and the
-- return reports its word with experience and resumed clocks. A single
-- fought battle proves all phases in journey order instead of replaying
-- the opening once per phase.
function T.presented_win_carries_every_phase_assertion()
  for _, versionId in ipairs(readyVersions()) do
    local runtime = bootRuntime(versionId)
    local envelope, binding, doubles =
      bindEnvelope(runtime, versionId, dualMeasurement("presented-win-phases:dual"), paintCountingGraphics())
    local followerSteps, transitionSteps = 0, 0
    runtime.followingMon = {
      update = function()
        followerSteps = followerSteps + 1
      end,
      dispose = function() end,
    }
    runtime.followingMonTransition = {
      updateFixed = function()
        transitionSteps = transitionSteps + 1
      end,
      dispose = function() end,
    }
    local ok, failure = xpcall(function()
      local before = { fieldX = runtime.player.fieldX, fieldZ = runtime.player.fieldZ }
      local launchId = runtime:launchBattle({ kind = "wild", details = { species = "CATERPIE", level = 3 } })
      -- The claim holds presence while covering: cover completes before
      -- construction and semantic leave follows under full cover, with
      -- the battle starting one reveal step after full cover.
      Assert.equal(runtime.overworld:phase(), "present", "the claim holds presence while covering")
      local coveredAt, leftAt, coverAtLeave = nil, nil, nil
      local ticks = 0
      while runtime.battleCoordinator:activeBattle() == nil and ticks < 900 do
        runtime:update(SourceTick.DT)
        envelope:updateFixed(TICK)
        ticks = ticks + 1
        if coveredAt == nil and envelope:cover().coefficient == 16 then
          coveredAt = ticks
        end
        local phase = runtime.overworld:phase()
        if leftAt == nil and phase ~= "present" then
          leftAt = ticks
          coverAtLeave = envelope:cover().coefficient
        end
      end
      Assert.notNil(runtime.battleCoordinator:activeBattle(), "the covered launch constructs its battle")
      Assert.notNil(coveredAt, "cover completes before construction")
      Assert.notNil(leftAt, "semantic leave follows cover")
      Assert.isTrue(coveredAt <= leftAt, "leave never precedes full cover")
      Assert.equal(coverAtLeave, 16, "semantic leave happens under full cover")
      -- Construction follows the full-cover leave by one accepted tick, and that
      -- tick performs the reveal's single cover step first, so the battle starts
      -- one step into the reveal beside its intro instead of under full cover.
      Assert.equal(envelope:cover().coefficient, 14, "the battle starts one reveal step after full cover")
      local experienceBefore = assert(runtime.monService:partyMon(0), "the live lead is readable").experience
      -- Follower clocks freeze under the hold.
      local heldFollower, heldTransition = followerSteps, transitionSteps
      pump(runtime, envelope, 20)
      Assert.equal(followerSteps, heldFollower, "the follower freezes under the hold")
      Assert.equal(transitionSteps, heldTransition, "follower transitions freeze under the hold")
      -- The command root holds still without paint until an explicit draw.
      local screen = driveToCommandMode(runtime, envelope)
      doubles.text.draws = {}
      doubles.windows.calls = {}
      local audioBefore = #doubles.audio.plays
      for _ = 1, 5 do
        envelope:updateFixed(SourceTick.DT)
      end
      Assert.equal(#doubles.text.draws, 0, "fixed updates paint no text without a draw")
      Assert.equal(#doubles.windows.calls, 0, "fixed updates paint no windows without a draw")
      Assert.equal(screen:status().mode, "command", "semantics hold still without paint")
      local spy = paintCountingGraphics()
      Assert.isTrue(envelope:drawBattle({ graphics = spy }), "the explicit draw reaches the live screen")
      Assert.isTrue(#doubles.text.draws > 0, "the explicit draw prints its wording")
      Assert.isTrue(#doubles.windows.calls > 0, "the explicit draw frames its windows")
      Assert.isTrue(spy.paint > 0, "the explicit draw reaches host graphics")
      local texts, frames = #doubles.text.draws, #doubles.windows.calls
      for _ = 1, 2 do
        envelope:updateFixed(SourceTick.DT)
      end
      Assert.equal(#doubles.text.draws, texts, "later updates paint no further text")
      Assert.equal(#doubles.windows.calls, frames, "later updates paint no further windows")
      Assert.equal(#doubles.audio.plays, audioBefore, "updates and draws play no extra cues")
      -- Semantic input reaches the live screen before field controls.
      Assert.equal(screen:status().mode, "command", "the root shows its commands")
      waitMenuInput(runtime, envelope)
      envelope:input({ { type = "confirm" } })
      pump(runtime, envelope, 5)
      Assert.equal(screen:status().mode, "moves", "a confirm enters the move view")
      Assert.deepEqual(
        { fieldX = runtime.player.fieldX, fieldZ = runtime.player.fieldZ },
        before,
        "battle input never moves the player"
      )
      Assert.isFalse(runtime.applicationHost:isActive(), "battle input never opens the Start Menu")
      waitMenuInput(runtime, envelope)
      envelope:input({ { type = "cancel" } })
      pump(runtime, envelope, 5)
      Assert.equal(screen:status().mode, "command", "a cancel returns to the command root")
      -- The fought win settles through the reveal: mid-reveal polls stay
      -- pending while the safe field commits.
      local revealing = false
      local turns = 0
      ticks = 0
      while runtime.battleCoordinator:activeBattle() ~= nil and ticks < 6000 do
        local battle = runtime.battleCoordinator:activeBattle()
        local current = battle:status()
        if current.phase == "failed" then
          error("the presented battle failed: " .. tostring(current.error), 0)
        end
        if current.phase == "running" and current.request ~= nil then
          turns = turns + 1
          local answer = sparringChoose(runtime, current.request)
          local choices = answer
          if type(answer) == "table" and answer.kind ~= nil then
            choices = { answer }
          end
          local accepted, replyErr = battle:submit(SessionFixture.replyFor(current.request, choices))
          Assert.isTrue(accepted, "a legal presented decision is accepted: " .. tostring(replyErr))
        end
        -- The terminal leave needs its explicit final-page acknowledgment.
        local live = envelope:liveScreen()
        if live ~= nil then
          local shown = live:status()
          if shown.mode == "intro" or shown.mode == "narration" or shown.mode == "outcome" then
            envelope:input({ { type = "confirm" } })
          end
        end
        runtime:update(SourceTick.DT)
        envelope:updateFixed(TICK)
        ticks = ticks + 1
        local launch = runtime.battleCoordinator._battleLaunch
        if launch ~= nil and launch.phase == "revealing" then
          revealing = true
          local status = runtime:battleStatus(launchId)
          Assert.isTrue(status ~= nil and not status.committed, "mid-reveal polls stay pending")
        end
      end
      Assert.isNil(runtime.battleCoordinator:activeBattle(), "answered decisions settle the owned presented lifetime")
      Assert.isTrue(turns > 0, "the presented battle answers decisions to its committed words")
      Assert.isTrue(turns > 0, "the presented battle answers decisions")
      Assert.isTrue(revealing, "the return reveals before publishing")
      Assert.isNil(runtime.battleCoordinator._battleLaunch, "the receipt clears the launch")
      -- The continuing return restores presence with the win word,
      -- experience, an open save gate, and resumed clocks.
      pump(runtime, envelope, 60)
      Assert.equal(runtime:lastBattleResult().result, "win", "the win reports its exact word")
      Assert.equal(runtime:lastBattleResult().sourceResult, 1, "the win reads back won")
      Assert.equal(runtime:battleStatus(launchId).result, "win", "the launch receipt carries the win")
      Assert.isTrue(runtime:battleStatus(launchId).committed, "the receipt commits only at the safe field")
      Assert.isTrue(runtime.monService:partyMon(0).experience > experienceBefore, "the win publishes experience once")
      Assert.equal(runtime.overworld:phase(), "present", "the continuing return restores presence")
      Assert.isTrue(followerSteps > heldFollower, "the follower resumes with the field")
      Assert.isTrue(transitionSteps > heldTransition, "follower transitions resume with the field")
      local _, reason = runtime.saveCoordinator:capture(false)
      Assert.isNil(reason, "the save gate opens at the safe field")
    end, debug.traceback)
    local unbound = pcall(function()
      runtime:unbindBattlePresentation(binding)
    end)
    local closed = pcall(function()
      runtime:dispose()
    end)
    if not ok then
      error(failure, 0)
    end
    Assert.isTrue(unbound, "the lifetime releases its factory binding")
    Assert.isTrue(closed, "teardown releases the presented lifetime")
  end
end

-- Explicit draws stay stable and genuine render failures fault the
-- runtime: repeated draws paint the same frame with no cues or semantic
-- advance, updates between draws add no paint, and a throwing window
-- renderer marks the screen so the next tick raises its original error.
function T.explicit_draws_stay_stable_and_render_failures_fault_the_runtime()
  for _, versionId in ipairs(readyVersions()) do
    local runtime = bootRuntime(versionId)
    local envelope, binding, doubles =
      bindEnvelope(runtime, versionId, dualMeasurement("stable-draws:dual"), paintCountingGraphics())
    local ok, failure = xpcall(function()
      runtime:launchBattle({ kind = "wild", details = { species = "CATERPIE", level = 3 } })
      driveToCommandMode(runtime, envelope)
      waitMenuInput(runtime, envelope)
      settleArrowRun(envelope)
      local function drawnCounts()
        doubles.text.draws = {}
        doubles.windows.calls = {}
        local spy = paintCountingGraphics()
        local audioBefore = #doubles.audio.plays
        local drew = envelope:drawBattle({ graphics = spy })
        Assert.isTrue(drew, "each explicit draw reaches the live screen")
        return {
          texts = #doubles.text.draws,
          frames = #doubles.windows.calls,
          paint = spy.paint,
          audio = #doubles.audio.plays - audioBefore,
          mode = envelope:liveScreen():status().mode,
        }
      end
      local first = drawnCounts()
      Assert.isTrue(first.texts > 0, "the command view prints its wording")
      Assert.isTrue(first.frames > 0, "the command view frames its windows")
      for _ = 1, 3 do
        envelope:updateFixed(SourceTick.DT)
      end
      Assert.equal(#doubles.text.draws, first.texts, "updates between draws paint no extra text")
      Assert.equal(#doubles.windows.calls, first.frames, "updates between draws frame no extra windows")
      local second = drawnCounts()
      Assert.equal(second.texts, first.texts, "repeated draws print the same wording")
      Assert.equal(second.frames, first.frames, "repeated draws frame the same windows")
      Assert.equal(second.paint, first.paint, "repeated draws reach host graphics identically")
      Assert.equal(second.audio, 0, "drawing plays no cues")
      Assert.equal(second.mode, first.mode, "drawing advances no semantics")
      doubles.windows.drawWindow = function()
        error("probe window failure", 0)
      end
      doubles.windows.drawApplicationFrame = function()
        error("probe window failure", 0)
      end
      doubles.text.draws = {}
      doubles.windows.calls = {}
      local spy = paintCountingGraphics()
      Assert.isTrue(envelope:drawBattle({ graphics = spy }), "the failing draw still reaches the live screen")
      local failed = assert(envelope:liveScreen(), "the failed screen stays observable for its handoff")
      Assert.equal(failed:status().mode, "failed", "a genuine render failure marks the screen")
      local survived, raised = pcall(function()
        for _ = 1, 3 do
          envelope:updateFixed(SourceTick.DT)
        end
      end)
      Assert.isFalse(survived, "the render failure faults the runtime")
      Assert.isTrue(
        tostring(raised):find("probe window failure", 1, true) ~= nil,
        "the fault carries the original render error: " .. tostring(raised)
      )
    end, debug.traceback)
    local unbound = pcall(function()
      runtime:unbindBattlePresentation(binding)
    end)
    local closed = pcall(function()
      runtime:dispose()
    end)
    if not ok then
      error(failure, 0)
    end
    Assert.isTrue(unbound, "the lifetime releases its factory binding")
    Assert.isTrue(closed, "teardown releases the presented lifetime")
  end
end

-- A scripted defeat holds the field covered until its authored release:
-- while absent with no observed recovery the launch stays with its holds
-- and music untouched, and both authored releases (a restored present
-- field, or an observed recovery running idle) clear the same holds,
-- replay no music, and release the owned port exactly once.
function T.scripted_transfer_holds_cover_until_its_authored_release()
  local function transferRuntime(double)
    local runtime = {
      overworld = {
        phase = function()
          return double.overworldPhase
        end,
      },
      session = {
        setBattleActive = function(_, active)
          double.session[#double.session + 1] = active
        end,
        setForegroundHold = function(_, active)
          double.session[#double.session + 1] = active
        end,
      },
      audio = {
        resumeFieldPolicy = function(_, token, restore)
          double.audio[#double.audio + 1] = { token = token, restore = restore }
        end,
      },
      input = {
        clearAll = function()
          double.clears = double.clears + 1
        end,
      },
      blackoutFlow = double.flow,
    }
    runtime.battleCoordinator = FieldBattleCoordinator.new(runtime)
    return runtime
  end

  local function checkReleased(double, runtime, id)
    Assert.isNil(runtime.battleCoordinator._battleLaunch, "an authored release clears the launch")
    Assert.isNil(runtime.battleCoordinator.battleRuntime, "an authored release clears the owned port")
    Assert.deepEqual(double.session, { false, false }, "an authored release clears both holds")
    Assert.equal(#double.audio, 1, "an authored release touches the music policy once")
    Assert.equal(double.audio[1].token, id, "the music handoff names the released launch")
    Assert.isFalse(double.audio[1].restore, "a defeat handoff replays no music")
    Assert.equal(double.clears, 1, "an authored release clears stale input once")
  end

  local observed = { overworldPhase = "absent", session = {}, audio = {}, clears = 0, flowPhase = "message_wait" }
  observed.flow = {
    status = function()
      return { phase = observed.flowPhase }
    end,
  }
  local observedRuntime = transferRuntime(observed)
  local held =
    { launchId = "scripted-transfer-observed#1", phase = "transfer", request = { id = "scripted-transfer-observed#1" } }
  observedRuntime.battleCoordinator.battleRuntime = {}
  observedRuntime.battleCoordinator._battleLaunch = held
  observedRuntime.battleCoordinator._battleReceipt = held
  observedRuntime.battleCoordinator:_finishScriptedTransfer(held)
  Assert.isTrue(
    observedRuntime.battleCoordinator._battleLaunch == held,
    "the scripted defeat stays absent until its authored release"
  )
  Assert.isTrue(held.transferBlackoutSeen, "an observed recovery marks the transfer")
  Assert.equal(#observed.audio, 0, "a held transfer replays no music")
  Assert.equal(#observed.session, 0, "a held transfer keeps its holds")
  Assert.equal(observed.clears, 0, "a held transfer keeps its input")
  observed.flowPhase = "idle"
  observedRuntime.battleCoordinator:_finishScriptedTransfer(held)
  checkReleased(observed, observedRuntime, "scripted-transfer-observed#1")
  Assert.isTrue(
    observedRuntime.battleCoordinator._battleReceipt == held,
    "the release keeps the receipt published at the transfer"
  )

  local restored = { overworldPhase = "present", session = {}, audio = {}, clears = 0, flow = nil }
  local restoredRuntime = transferRuntime(restored)
  local returning =
    { launchId = "scripted-transfer-restored#1", phase = "transfer", request = { id = "scripted-transfer-restored#1" } }
  restoredRuntime.battleCoordinator.battleRuntime = {}
  restoredRuntime.battleCoordinator._battleLaunch = returning
  restoredRuntime.battleCoordinator._battleReceipt = returning
  restoredRuntime.battleCoordinator:_finishScriptedTransfer(returning)
  checkReleased(restored, restoredRuntime, "scripted-transfer-restored#1")
end

-- A deferred production envelope behind a scene-demand host: graphics
-- presence selects the pending facade, while the demand answers through
-- the real staged inventory. Construction still proves the staged scene,
-- yet entry stays observably pending until a fixed tick builds the live
-- screen behind the same port.
---@param runtime FieldRuntime
---@param versionId string
---@param measurement table
---@param graphicsOverride table? failing graphics namespace under fault driving
---@return table envelope
---@return integer binding
---@return table doubles
local function bindScheduledEnvelope(runtime, versionId, measurement, graphicsOverride)
  local doubles = { audio = recordingAudio(), windows = recordingWindows(), text = recordingText() }
  local worker = { ready = true, failure = nil }
  local derivedAssets = {}
  function derivedAssets.requestBattleScene(_, _)
    return worker.ready, worker.failure
  end
  local envelope = FieldBattlePresentation.new({
    cacheFs = syntheticEffectCacheFs(CacheFs.forVersion(versionId)),
    windows = doubles.windows,
    text = doubles.text,
    audio = doubles.audio,
    measureDisplay = function()
      return measurement
    end,
    graphics = graphicsOverride or uploadCapableGraphics(),
    derivedAssets = derivedAssets,
  })
  local ports = {}
  local factory = envelope:factory()
  local binding = runtime:bindBattlePresentation(function(descriptor)
    local port = factory(descriptor)
    ports[#ports + 1] = port
    return port
  end)
  doubles.ports = ports
  doubles.worker = worker
  return envelope, binding, doubles
end

-- Proves the admission selected the deferred production port without
-- reading implementation text: while the scene builds the admitted port
-- acknowledges nothing and owns no screen; once staged the same port
-- enters and owns its live screen.
---@param envelope table live deferred envelope under test driving
---@param port table admitted facade under test driving
---@param launchId string admitted launch identity under test driving
---@param kind string admitted launch kind under test driving
local function requirePendingAdmission(envelope, port, launchId, kind)
  Assert.isFalse(
    port.enter({ launchId = launchId, kind = kind }),
    "the admitted launch stays unacknowledged while its scene builds"
  )
  Assert.isFalse(port.ready(), "the admitted launch never reads interactive while its scene builds")
  Assert.isNil(envelope:liveScreen(), "the admitted launch holds no screen while its scene builds")
end

---@param request table<string, unknown> pending player decision under inspection
---@param wanted string choice kind under search
---@return boolean true when the request admits the kind
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

-- Projects one executable thrown ball through the battle's own decision
-- options and copies its prepared fragment: availability follows real
-- stock instead of driver guesses. Nil when the ball is not executable
-- on this request.
---@param runtime FieldRuntime
---@param request table<string, unknown> pending player decision under test driving
---@param item string battle item key under projection
---@return table? prepared native choice fragment when the ball is executable now
local function ballFragment(runtime, request, item)
  local battle = runtime.battleCoordinator:activeBattle()
  if battle == nil or type(battle.decisionOptions) ~= "function" then
    return nil
  end
  local options = battle:decisionOptions(request.requestId)
  if type(options) ~= "table" or type(options.actors) ~= "table" then
    return nil
  end
  for _, entry in ipairs(options.actors) do
    for _, choice in ipairs(entry.choices or {}) do
      if
        choice.enabled == true
        and type(choice.choice) == "table"
        and type(choice.choice.payload) == "table"
        and choice.choice.payload.item == item
      then
        return choice.choice
      end
    end
  end
  return nil
end

-- Answers open kernel decisions and acknowledges narration pages until
-- the owned launch leaves the coordinator, whether through a committed
-- return or a settled abort. Fails loudly with the stranding phase when
-- the return driver is lost instead of settling.
---@param runtime FieldRuntime live production runtime under test driving
---@param envelope table live deferred envelope under test driving
---@param choose fun(request: table): table decision choice for the open request
---@param budget integer tick bound before a stranded launch fails loudly
local function driveToSettled(runtime, envelope, choose, budget)
  local ticks = 0
  while ticks < budget do
    local launch = runtime.battleCoordinator._battleLaunch
    if launch == nil then
      return
    end
    local battle = runtime.battleCoordinator.battleRuntime
    if battle ~= nil then
      local current = battle:status()
      if current.phase == "running" and current.request ~= nil then
        local answer = choose(current.request)
        local choices = answer
        if type(answer) == "table" and answer.kind ~= nil then
          choices = { answer }
        end
        local accepted, replyErr = battle:submit(SessionFixture.replyFor(current.request, choices))
        Assert.isTrue(accepted, "a legal deferred decision is accepted: " .. tostring(replyErr))
      end
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
  local stranded = runtime.battleCoordinator._battleLaunch
  Assert.isNil(
    stranded,
    "the deferred return settles instead of stranding in "
      .. (stranded ~= nil and tostring(stranded.phase) or "no phase")
  )
end

-- A deferred win returns through cover and receipt: the admitted facade
-- stays pending until its staged scene builds, then the same port plays
-- the win to its committed words and the return restores the present
-- field, releases holds and input, publishes one receipt, and opens the
-- save gate. Disposing the facade under terminal cover must not strand
-- the envelope that still owns restoration and reveal.
function T.scheduled_win_returns_through_cover_and_receipt()
  for _, versionId in ipairs(readyVersions()) do
    local runtime = bootRuntime(versionId)
    local envelope, binding, doubles = bindScheduledEnvelope(runtime, versionId, dualMeasurement("deferred-win:dual"))
    local ok, failure = xpcall(function()
      local launchId = runtime:launchBattle({ kind = "wild", details = { species = "CATERPIE", level = 3 } })
      local port = assert(doubles.ports[#doubles.ports], "the admission owns its port")
      requirePendingAdmission(envelope, port, launchId, "wild")
      waitConstructed(runtime, envelope)
      Assert.notNil(envelope:liveScreen(), "the staged launch builds its live screen")
      Assert.isTrue(port.enter({ launchId = launchId, kind = "wild" }), "the staged launch acknowledges its entry")
      local experienceBefore = assert(runtime.monService:partyMon(0), "the live lead is readable").experience
      local turns = settle(runtime, envelope, function(request)
        return sparringChoose(runtime, request)
      end, 6000)
      Assert.isTrue(turns > 0, "the deferred battle answers decisions to its committed words")
      pump(runtime, envelope, 60)
      Assert.equal(runtime:lastBattleResult().result, "win", "the win reports its exact word")
      Assert.equal(runtime:lastBattleResult().sourceResult, 1, "the win reads back won")
      local receipt = assert(runtime:battleStatus(launchId), "the settled launch leaves a readable receipt")
      Assert.equal(receipt.result, "win", "the receipt carries the win")
      Assert.isTrue(receipt.committed, "the receipt commits only at the safe field")
      Assert.isTrue(runtime.monService:partyMon(0).experience > experienceBefore, "the win publishes experience once")
      local settledExperience = runtime.monService:partyMon(0).experience
      pump(runtime, envelope, 30)
      Assert.equal(runtime.monService:partyMon(0).experience, settledExperience, "settling publishes no second effect")
      Assert.equal(runtime.overworld:phase(), "present", "the continuing return restores presence")
      Assert.isNil(runtime.battleCoordinator._battleLaunch, "the return clears the launch")
      Assert.isNil(envelope:liveScreen(), "the return releases the live screen")
      Assert.isFalse(runtime.session:isForegroundHoldActive(), "the return releases the foreground hold")
      Assert.isFalse(envelope:ownsInput(), "the return releases envelope input")
      local _, reason = runtime.saveCoordinator:capture(false)
      Assert.isNil(reason, "the save gate opens at the safe field")
    end, debug.traceback)
    local unbound = pcall(function()
      runtime:unbindBattlePresentation(binding)
    end)
    local closed = pcall(function()
      runtime:dispose()
    end)
    if not ok then
      error(failure, 0)
    end
    Assert.isTrue(unbound, "the lifetime releases its factory binding")
    Assert.isTrue(closed, "teardown releases the presented lifetime")
  end
end

-- Deferred flight and capture complete after the first return: one owned
-- fixture plays a win, a flight, and a thrown-ball capture to their
-- receipts; every launch receives a new identity behind a fresh port
-- disposed exactly once; the first demand waits cold until its scene
-- stages; and stale callbacks from a settled launch never touch the
-- next one.
function T.scheduled_escape_and_capture_complete_with_fresh_identities()
  for _, versionId in ipairs(readyVersions()) do
    local runtime = bootRuntime(versionId)
    local envelope, binding, doubles =
      bindScheduledEnvelope(runtime, versionId, dualMeasurement("deferred-alternatives:dual"))
    Assert.isTrue(runtime.bagService:add("MASTER_BALL", 1), "the capture leg stocks its thrown ball")
    local disposed = {}
    local ok, failure = xpcall(function()
      doubles.worker.ready = nil
      local firstId = runtime:launchBattle({ kind = "wild", details = { species = "CATERPIE", level = 3 } })
      local firstPort = assert(doubles.ports[#doubles.ports], "the first launch owns its port")
      pump(runtime, envelope, 5)
      Assert.isFalse(firstPort.enter({ launchId = firstId, kind = "wild" }), "the cold demand stays unacknowledged")
      Assert.isNil(envelope:liveScreen(), "the cold demand builds no screen before its scene stages")
      doubles.worker.ready = true
      waitConstructed(runtime, envelope)
      Assert.notNil(envelope:liveScreen(), "the staged demand builds its live screen")
      local function watchDispose(round, port)
        local firstDispose = port.dispose
        port.dispose = function()
          disposed[#disposed + 1] = round
          return firstDispose()
        end
      end
      watchDispose(1, firstPort)
      settle(runtime, envelope, function(request)
        return sparringChoose(runtime, request)
      end, 6000)
      pump(runtime, envelope, 60)
      Assert.equal(runtime:lastBattleResult().result, "win", "the first leg reports its own win")
      Assert.isFalse(firstPort.ready(), "the settled port never reads interactive again")
      Assert.isFalse(firstPort.enter({ launchId = firstId, kind = "wild" }), "the settled port never reacknowledges")
      local secondId = runtime:launchBattle({ kind = "wild", details = { species = "CATERPIE", level = 3 } })
      Assert.isTrue(secondId ~= firstId, "the next launch receives a new identity")
      local secondPort = assert(doubles.ports[#doubles.ports], "the second launch owns its port")
      Assert.isTrue(secondPort ~= firstPort, "each launch owns its port")
      requirePendingAdmission(envelope, secondPort, secondId, "wild")
      watchDispose(2, secondPort)
      waitConstructed(runtime, envelope)
      settle(runtime, envelope, function(request)
        local actor = assert(request.actors[1], "every player decision addresses its combatant")
        if admitsKind(request, "run") then
          return { actor = actor, kind = "run", payload = {} }
        end
        return strike(actor)
      end, 6000)
      pump(runtime, envelope, 60)
      Assert.equal(runtime:lastBattleResult().result, "flee", "flight reports its exact word")
      Assert.equal(runtime:battleStatus(secondId).result, "flee", "the flight receipt carries the flight")
      local presentOk = pcall(firstPort.present, { launchId = firstId, packetId = 1 })
      Assert.isTrue(presentOk, "a stale delivery never raises")
      Assert.isTrue(runtime:battleStatus(secondId).result == "flee", "a stale delivery never rewrites the live receipt")
      local ballsBefore = runtime.bagService:quantity("MASTER_BALL")
      local partyBefore = runtime.monService:partyCount()
      local thirdId = runtime:launchBattle({ kind = "wild", details = { species = "CATERPIE", level = 3 } })
      Assert.isTrue(thirdId ~= secondId, "the capture launch receives a new identity")
      local thirdPort = assert(doubles.ports[#doubles.ports], "the capture launch owns its port")
      watchDispose(3, thirdPort)
      waitConstructed(runtime, envelope)
      settle(runtime, envelope, function(request)
        local actor = assert(request.actors[1], "every player decision addresses its combatant")
        if admitsKind(request, "item") then
          local fragment = ballFragment(runtime, request, "MASTER_BALL")
          if fragment ~= nil then
            return fragment
          end
        end
        return strike(actor)
      end, 6000)
      pump(runtime, envelope, 60)
      Assert.equal(runtime:lastBattleResult().result, "capture", "capture reports its exact word")
      Assert.equal(runtime.bagService:quantity("MASTER_BALL"), ballsBefore - 1, "the capture spends one ball")
      Assert.equal(runtime.monService:partyCount(), partyBefore + 1, "the capture publishes one mon")
      Assert.deepEqual(disposed, { 1, 2, 3 }, "each port disposes exactly once in launch order")
      Assert.equal(runtime.overworld:phase(), "present", "the third return restores presence")
      local _, reason = runtime.saveCoordinator:capture(false)
      Assert.isNil(reason, "the save gate opens at the safe field")
    end, debug.traceback)
    local unbound = pcall(function()
      runtime:unbindBattlePresentation(binding)
    end)
    local closed = pcall(function()
      runtime:dispose()
    end)
    if not ok then
      error(failure, 0)
    end
    Assert.isTrue(unbound, "the lifetime releases its factory binding")
    Assert.isTrue(closed, "teardown releases the presented lifetime")
  end
end

-- Deferred pre-commit faults fault the runtime with their original cause:
-- a construction failure, an asset-upload failure, and a port-present
-- exception each raise through the field update instead of restoring the
-- field. Real screen draw failures are covered at active and terminal phases
-- by failed_screen_faults_the_runtime.
function T.scheduled_precommit_faults_raise_their_original_cause()
  local points = { "construction", "upload", "present" }
  for _, versionId in ipairs(readyVersions()) do
    for _, point in ipairs(points) do
      local runtime = bootRuntime(versionId)
      local graphics = uploadCapableGraphics()
      if point == "upload" then
        graphics = {}
        function graphics.newImage(_)
          error("probe upload failure", 0)
        end
      end
      local envelope, binding, _ =
        bindScheduledEnvelope(runtime, versionId, dualMeasurement("deferred-precommit:" .. point), graphics)
      local ScreenState = require("game.hgss.src.battle.BattleScreenState")
      local realNew = ScreenState.new
      if point == "construction" then
        ScreenState.new = function(_)
          error("probe construction failure", 0)
        end
      end
      local ok, failure = xpcall(function()
        runtime:launchBattle({ kind = "wild", details = { species = "CATERPIE", level = 3 } })
        if point == "present" or point == "draw" then
          waitConstructed(runtime, envelope)
          if point == "present" then
            local inner = assert(envelope._innerPort, "the live launch owns its inner port before the fault")
            inner.present = function(_)
              error("probe present failure", 0)
            end
          else
            failLiveScreen(envelope, "probe draw failure")
          end
        end
        local survived, raised = pcall(driveToSettled, runtime, envelope, function(request)
          return sparringChoose(runtime, request)
        end, 1200)
        Assert.isFalse(survived, "the " .. point .. " fault faults the runtime")
        Assert.isTrue(
          tostring(raised):find("probe " .. point .. " failure", 1, true) ~= nil,
          "the fault carries its original cause at " .. point .. ": " .. tostring(raised)
        )
      end, debug.traceback)
      ScreenState.new = realNew
      local unbound = pcall(function()
        runtime:unbindBattlePresentation(binding)
      end)
      local closed = pcall(function()
        runtime:dispose()
      end)
      if not ok then
        error(failure, 0)
      end
      Assert.isTrue(unbound, "the lifetime releases its factory binding")
      Assert.isTrue(closed, "teardown releases the presented lifetime")
    end
  end
end

-- Deferred losses keep their authored and automatic returns: a scripted
-- loss holds cover while absent for its authored continuation with no
-- automatic recovery, then releases through the continuation's restore;
-- a random loss runs the existing recovery exactly once through one
-- genuine message edge. Both retain an advance path after the battle
-- screen is disposed.
function T.scheduled_losses_keep_their_authored_and_automatic_returns()
  for _, versionId in ipairs(readyVersions()) do
    do
      local runtime = bootRuntime(versionId)
      local envelope, binding, doubles =
        bindScheduledEnvelope(runtime, versionId, dualMeasurement("deferred-scripted-loss:dual"))
      local ok, failure = xpcall(function()
        local blackout = assert(runtime.blackoutFlow, "the runtime composes its recovery flow")
        local recoveries = 0
        local realStart = blackout.start
        blackout.start = function(self, spawnKey)
          recoveries = recoveries + 1
          return realStart(self, spawnKey)
        end
        local launchId
        local done, launchErr = pcall(function()
          launchId = runtime._battleHost:launchBattle({ kind = "wild", details = { species = "EEVEE", level = 30 } })
        end)
        Assert.isTrue(done, "the script host launches: " .. tostring(launchErr))
        local port = assert(doubles.ports[#doubles.ports], "the scripted launch owns its port")
        requirePendingAdmission(envelope, port, launchId, "wild")
        waitConstructed(runtime, envelope)
        driveLaunchToPhase(runtime, envelope, "terminal", 15000)
        Assert.equal(runtime.battleCoordinator._battleLaunch.result, "loss", "the defeat reaches terminal as a loss")
        pump(runtime, envelope, 90)
        blackout.start = realStart
        Assert.equal(recoveries, 0, "scripted defeat starts no automatic recovery")
        local held = runtime.battleCoordinator._battleLaunch
        Assert.notNil(held, "scripted defeat keeps its launch for the authored continuation")
        Assert.equal(held.phase, "transfer", "scripted defeat transfers while absent")
        Assert.equal(runtime.overworld:phase(), "absent", "scripted defeat holds cover while absent")
        local published = runtime:battleStatus(launchId)
        Assert.isTrue(published ~= nil and published.committed, "the receipt reaches the launching task")
        Assert.equal(published.result, "loss", "the scripted loss keeps its word")
        runtime.overworld:requestRestore()
        driveToSettled(runtime, envelope, function(request)
          return sparringChoose(runtime, request)
        end, 1200)
        Assert.isNil(runtime.battleCoordinator._battleLaunch, "the authored release clears the launch")
        local kept = assert(runtime:battleStatus(launchId), "the release keeps the receipt readable")
        Assert.equal(kept.result, "loss", "the release keeps the loss")
        Assert.isTrue(kept.committed, "the release keeps the commit")
        Assert.isFalse(runtime.session:isForegroundHoldActive(), "the release clears the foreground hold")
        Assert.equal(runtime.overworld:phase(), "present", "the release restores presence")
      end, debug.traceback)
      local unbound = pcall(function()
        runtime:unbindBattlePresentation(binding)
      end)
      local closed = pcall(function()
        runtime:dispose()
      end)
      if not ok then
        error(failure, 0)
      end
      Assert.isTrue(unbound, "the lifetime releases its factory binding")
      Assert.isTrue(closed, "teardown releases the presented lifetime")
    end
    do
      local runtime = bootRuntime(versionId)
      local envelope, binding, doubles =
        bindScheduledEnvelope(runtime, versionId, dualMeasurement("deferred-automatic-loss:dual"))
      local ok, failure = xpcall(function()
        local blackout = assert(runtime.blackoutFlow, "the runtime composes its recovery flow")
        local recoveries = 0
        local realStart = blackout.start
        blackout.start = function(self, spawnKey)
          recoveries = recoveries + 1
          return realStart(self, spawnKey)
        end
        local moneyAtLoss = runtime.playerData.profile.money
        local launchId = runtime:launchBattle({ kind = "wild", details = { species = "EEVEE", level = 30 } })
        local port = assert(doubles.ports[#doubles.ports], "the random loss owns its port")
        requirePendingAdmission(envelope, port, launchId, "wild")
        waitConstructed(runtime, envelope)
        local turns = driveDefeatToRecovery(runtime, envelope, function(request)
          return sparringChoose(runtime, request)
        end, 15000)
        Assert.isTrue(turns > 0, "the defeat answers decisions before its recovery")
        Assert.isTrue(
          reachBlackoutPhase(runtime, envelope, "message_wait", 1500),
          "the defeat reaches its recovery message wait"
        )
        pump(runtime, envelope, 600)
        local waiting = blackout:status()
        Assert.equal(waiting.phase, "message_wait", "the recovery waits for a real edge")
        Assert.isTrue(waiting.waitingInput, "the wait keeps asking for input")
        envelope:input({ { type = "confirm" } })
        local ticks = 0
        while runtime.overworld:phase() ~= "present" and ticks < 1500 do
          runtime:update(1 / 30)
          envelope:updateFixed(TICK)
          ticks = ticks + 1
        end
        blackout.start = realStart
        Assert.equal(recoveries, 1, "automatic defeat runs the existing recovery exactly once")
        Assert.equal(runtime.overworld:phase(), "present", "the recovery returns to the live field")
        Assert.equal(runtime:lastBattleResult().result, "loss", "the automatic loss reports its exact word")
        Assert.isTrue(runtime.playerData.profile.money < moneyAtLoss, "the defeat debits once")
        local healed = assert(runtime.monService:partyMon(0), "the recovered lead is readable")
        Assert.isTrue(healed.hp == nil or healed.hp > 0, "the recovery heals the party")
        local _, reason = runtime.saveCoordinator:capture(false)
        Assert.isNil(reason, "the save gate opens at the safe field")
      end, debug.traceback)
      local unbound = pcall(function()
        runtime:unbindBattlePresentation(binding)
      end)
      local closed = pcall(function()
        runtime:dispose()
      end)
      if not ok then
        error(failure, 0)
      end
      Assert.isTrue(unbound, "the lifetime releases its factory binding")
      Assert.isTrue(closed, "teardown releases the presented lifetime")
    end
  end
end

-- A quit during a pending build publishes nothing late: quitting before
-- the scene stages builds no screen afterwards and disposes the pending
-- port safely.
function T.scheduled_pending_quit_builds_nothing_late()
  for _, versionId in ipairs(readyVersions()) do
    do
      local runtime = bootRuntime(versionId)
      local envelope, binding, doubles =
        bindScheduledEnvelope(runtime, versionId, dualMeasurement("deferred-pending-quit:dual"))
      doubles.worker.ready = nil
      local ScreenState = require("game.hgss.src.battle.BattleScreenState")
      local realNew = ScreenState.new
      local constructions = 0
      ScreenState.new = function(opts)
        constructions = constructions + 1
        return realNew(opts)
      end
      local ok, failure = xpcall(function()
        runtime:launchBattle({ kind = "wild", details = { species = "CATERPIE", level = 3 } })
        local port = assert(doubles.ports[#doubles.ports], "the pending launch owns its port")
        pump(runtime, envelope, 5)
        Assert.isNil(envelope:liveScreen(), "the pending launch holds no screen before the quit")
        runtime:dispose()
        Assert.isNil(runtime.battleCoordinator, "quitting releases the battle owner")
        Assert.isNil(envelope:liveScreen(), "quitting releases the pending screen")
        doubles.worker.ready = true
        for _ = 1, 30 do
          envelope:updateFixed(TICK)
        end
        Assert.equal(constructions, 0, "a late answer builds no screen for the quit launch")
        Assert.isNil(envelope:liveScreen(), "the quit launch stays screenless")
        local disposedOk = pcall(port.dispose)
        Assert.isTrue(disposedOk, "disposing the pending port after quit stays safe")
      end, debug.traceback)
      ScreenState.new = realNew
      local unbound = pcall(function()
        runtime:unbindBattlePresentation(binding)
      end)
      if not ok then
        error(failure, 0)
      end
      Assert.isTrue(unbound, "the lifetime releases its factory binding")
    end
  end
end

-- A live deferred port reports each operation failure once with its own
-- context: the first failing operation notifies carrying its operation,
-- launch, and original cause, while every later failing operation and
-- every stale callback collapses without a second report or a raise.
function T.scheduled_port_operation_failures_report_once_with_their_context()
  for _, versionId in ipairs(readyVersions()) do
    local cacheFs = CacheFs.forVersion(versionId)
    local worker = { ready = nil, failure = nil }
    local derivedAssets = {}
    function derivedAssets.requestBattleScene(_, _)
      return worker.ready, worker.failure
    end
    local host = { phase = "active", notifies = {} }
    function host.status()
      return { phase = host.phase }
    end
    function host.advance() end
    function host.submit(_)
      return true
    end
    function host.notify(event, reason)
      host.notifies[#host.notifies + 1] = { event = event, reason = reason }
    end
    local envelope = FieldBattlePresentation.new({
      cacheFs = cacheFs,
      windows = recordingWindows(),
      text = recordingText(),
      audio = recordingAudio(),
      measureDisplay = function()
        return dualMeasurement("deferred-operation-failure:dual")
      end,
      graphics = uploadCapableGraphics(),
      derivedAssets = derivedAssets,
    })
    local launchId = "operation-failure-probe"
    local port = envelope:factory()({
      launchId = launchId,
      kind = "wild",
      environment = { sceneKey = "general/grass/day" },
      host = host,
    })
    local ok, failure = xpcall(function()
      Assert.isFalse(port.enter({ launchId = launchId, kind = "wild" }), "the pending operation stays unacknowledged")
      Assert.isFalse(port.ready(), "the pending operation never reads interactive")
      Assert.isFalse(port.leave({ launchId = launchId }), "the pending return stays unacknowledged")
      worker.ready = true
      local entered = false
      for _ = 1, 120 do
        envelope:updateFixed(TICK)
        if port.enter({ launchId = launchId, kind = "wild" }) then
          entered = true
          break
        end
      end
      Assert.isTrue(entered, "the staged operation acknowledges its entry")
      local inner = assert(envelope._innerPort, "the live launch owns its inner operation target")
      local realEnter, realPresent, realReady, realLeave = inner.enter, inner.present, inner.ready, inner.leave
      inner.enter = function(_)
        error("probe enter failure at active", 0)
      end
      Assert.isFalse(port.enter({ launchId = launchId, kind = "wild" }), "a failing entry never acknowledges")
      Assert.equal(#host.notifies, 1, "the failing entry reports exactly once")
      Assert.equal(host.notifies[1].event, "screen-failed", "the entry report carries its handoff")
      Assert.isTrue(
        type(host.notifies[1].reason) == "string"
          and host.notifies[1].reason:find("enter", 1, true) ~= nil
          and host.notifies[1].reason:find(launchId, 1, true) ~= nil
          and host.notifies[1].reason:find("probe enter failure at active", 1, true) ~= nil,
        "the entry report names its operation, launch, and cause: " .. tostring(host.notifies[1].reason)
      )
      inner.present = function(_)
        error("probe present failure at active", 0)
      end
      local presentOk = pcall(port.present, { launchId = launchId, packetId = 1 })
      Assert.isTrue(presentOk, "a failing delivery never raises")
      Assert.equal(#host.notifies, 1, "a later delivery keeps the first report")
      inner.ready = function()
        error("probe ready failure at active", 0)
      end
      Assert.isFalse(port.ready(), "a failing readiness never reads interactive")
      Assert.equal(#host.notifies, 1, "a later readiness keeps the first report")
      inner.leave = function(_)
        error("probe leave failure at active", 0)
      end
      Assert.isFalse(port.leave({ launchId = launchId }), "a failing return never acknowledges")
      Assert.equal(#host.notifies, 1, "a later return keeps the first report")
      inner.enter, inner.present, inner.ready, inner.leave = realEnter, realPresent, realReady, realLeave
      port.dispose()
      port.dispose()
      Assert.isNil(envelope:liveScreen(), "the disposed operation owns no screen")
      Assert.isFalse(port.enter({ launchId = launchId, kind = "wild" }), "the disposed entry never reacknowledges")
      Assert.isFalse(port.ready(), "the disposed operation never reads interactive")
      local staleOk = pcall(port.present, { launchId = launchId, packetId = 2 })
      Assert.isTrue(staleOk, "a stale delivery never raises")
      Assert.equal(#host.notifies, 1, "disposal and stale calls report nothing further")
    end, debug.traceback)
    local released = pcall(function()
      envelope:dispose()
    end)
    if not ok then
      error(failure, 0)
    end
    Assert.isTrue(released, "teardown releases the envelope")
  end
end

-- Disposing a live deferred port releases its screen exactly once while
-- the envelope keeps its descriptor and launch until the host settles:
-- later polls build nothing, later operations stay inert, and only the
-- observed settlement forgets the launch.
function T.scheduled_live_port_dispose_releases_the_screen_once_and_keeps_the_envelope()
  for _, versionId in ipairs(readyVersions()) do
    local cacheFs = CacheFs.forVersion(versionId)
    local worker = { ready = true, failure = nil }
    local derivedAssets = {}
    function derivedAssets.requestBattleScene(_, _)
      return worker.ready, worker.failure
    end
    local host = { phase = "active", notifies = {} }
    function host.status()
      return { phase = host.phase }
    end
    function host.advance() end
    function host.submit(_)
      return true
    end
    function host.notify(event, reason)
      host.notifies[#host.notifies + 1] = { event = event, reason = reason }
    end
    local envelope = FieldBattlePresentation.new({
      cacheFs = cacheFs,
      windows = recordingWindows(),
      text = recordingText(),
      audio = recordingAudio(),
      measureDisplay = function()
        return dualMeasurement("deferred-live-dispose:dual")
      end,
      graphics = uploadCapableGraphics(),
      derivedAssets = derivedAssets,
    })
    local launchId = "live-dispose-probe"
    local port = envelope:factory()({
      launchId = launchId,
      kind = "wild",
      environment = { sceneKey = "general/grass/day" },
      host = host,
    })
    local ok, failure = xpcall(function()
      local entered = false
      for _ = 1, 120 do
        envelope:updateFixed(TICK)
        if port.enter({ launchId = launchId, kind = "wild" }) then
          entered = true
          break
        end
      end
      Assert.isTrue(entered, "the staged launch acknowledges its entry")
      local screen = assert(envelope:liveScreen(), "the live launch owns its screen")
      local disposals = 0
      local realDispose = screen.dispose
      screen.dispose = function(self)
        disposals = disposals + 1
        return realDispose(self)
      end
      port.dispose()
      Assert.equal(disposals, 1, "the live disposal releases the screen exactly once")
      Assert.isNil(envelope:liveScreen(), "the disposal releases the live screen")
      Assert.notNil(envelope._descriptor, "the disposal keeps the envelope descriptor")
      Assert.equal(envelope._launchId, launchId, "the disposal keeps the launch identity")
      Assert.isFalse(port.enter({ launchId = launchId, kind = "wild" }), "the disposed entry never reacknowledges")
      Assert.isFalse(port.ready(), "the disposed operation never reads interactive")
      Assert.isFalse(port.leave({ launchId = launchId }), "the disposed return never reacknowledges")
      port.dispose()
      Assert.equal(disposals, 1, "a second disposal releases nothing further")
      Assert.equal(#host.notifies, 0, "a clean disposal reports no failure")
      for _ = 1, 30 do
        envelope:updateFixed(TICK)
      end
      Assert.isNil(envelope:liveScreen(), "later polls build no screen for the disposed launch")
      Assert.notNil(envelope._descriptor, "later polls keep the unsettled descriptor")
      host.phase = "complete"
      for _ = 1, 5 do
        envelope:updateFixed(TICK)
      end
      Assert.isNil(envelope._launchId, "the settled host forgets the launch")
      Assert.isNil(envelope._descriptor, "the settled host drops the descriptor")
      local settledOk = pcall(port.dispose)
      Assert.isTrue(settledOk, "disposing after settlement stays safe")
    end, debug.traceback)
    local released = pcall(function()
      envelope:dispose()
    end)
    if not ok then
      error(failure, 0)
    end
    Assert.isTrue(released, "teardown releases the envelope")
  end
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
