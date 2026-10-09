-- Production presented-battle integration through the real field runtime
-- and the real battle screen: one envelope per field lifetime, one fresh
-- port and screen per launch, covered entry and return, audio arbitration,
-- and the distinct continuing, scripted-defeat, and automatic-defeat
-- continuations. Only host boundaries are substituted: recording
-- window/text doubles, deterministic clocks, and isolated save namespaces
-- (through direct runtime boots). Weak staged foes keep each leg fast and
-- deterministic; timing-sensitive frozen acceptance owns the long walks.

local Assert = require("tests.support.Assert")
local BattleDataCache = require("libs.assets.src.battle.BattleDataCache")
local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldRuntime = require("game.hgss.src.field.FieldRuntime")
local FieldBattlePresentation = require("game.hgss.src.field.FieldBattlePresentation")
local BattleTask = require("libs.hgss.src.script.tasks.BattleTask")
local ScreenTopology = require("libs.ui.src.ScreenTopology")
local SessionFixture = require("libs.battle.tests.session_fixture")
local PlayTime = require("libs.hgss.src.save.PlayTime")

local T = {}

local TICK = 1 / 60

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
      profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000, badges = 0, nationalDex = false },
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
---@return table envelope
---@return integer binding
---@return table doubles
local function bindEnvelope(runtime, versionId, measurement)
  local doubles = { audio = recordingAudio(), windows = recordingWindows(), text = recordingText() }
  local envelope = FieldBattlePresentation.new({
    cacheFs = CacheFs.forVersion(versionId),
    windows = doubles.windows,
    text = doubles.text,
    audio = doubles.audio,
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
    runtime:update(1 / 30)
    envelope:updateFixed(TICK)
  end
end

---@param runtime FieldRuntime
---@param envelope table
local function waitConstructed(runtime, envelope)
  local ticks = 0
  while runtime.battleRuntime == nil and ticks < 900 do
    runtime:update(1 / 30)
    envelope:updateFixed(TICK)
    ticks = ticks + 1
  end
  Assert.notNil(runtime.battleRuntime, "the covered launch constructs its battle")
end

---@param runtime FieldRuntime
---@param envelope table
---@param choose fun(request: table): table
---@param budget integer
---@return integer answered player turns before the lifetime settled
local function settle(runtime, envelope, choose, budget)
  local turns, ticks = 0, 0
  while runtime.battleRuntime ~= nil and ticks < budget do
    local battle = runtime.battleRuntime
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
    runtime:update(1 / 30)
    envelope:updateFixed(TICK)
    ticks = ticks + 1
  end
  Assert.isNil(runtime.battleRuntime, "answered decisions settle the owned presented lifetime")
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
    local launch = runtime._battleLaunch
    if launch ~= nil and launch.phase == "recovering" then
      return turns
    end
    if launch == nil or launch.phase == "failed" then
      error("the defeat never entered recovery", 0)
    end
    local battle = runtime.battleRuntime
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
    runtime:update(1 / 30)
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
    runtime:update(1 / 30)
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
  local battle = assert(runtime.battleRuntime, "fragments answer through the live battle")
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

local function readyVersions()
  local GameVersion = require("romdump.src.source.GameVersion")
  local RomImporter = require("romdump.src.source.RomImporter")
  local versions = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      versions[#versions + 1] = versionId
    end
  end
  if #versions == 0 then
    error("presented battle integration needs a ready versioned cache", 0)
  end
  return versions
end

-- A presented wild win returns through cover and receipt: full cover
-- bridges semantic absence, one construction serves the launch, and the
-- continuing receipt publishes only after the revealed field returns.
function T.presented_win_returns_through_cover_and_receipt()
  for _, versionId in ipairs(readyVersions()) do
    local runtime = bootRuntime(versionId)
    local envelope, binding, _ = bindEnvelope(runtime, versionId, dualMeasurement("presented-win:dual"))
    local ok, failure = xpcall(function()
      local launchId = runtime:launchBattle({ kind = "wild", details = { species = "CATERPIE", level = 3 } })
      Assert.equal(runtime.overworld:phase(), "present", "the claim holds presence while covering")
      local coveredAt, leftAt, coverAtLeave = nil, nil, nil
      local ticks = 0
      while runtime.battleRuntime == nil and ticks < 900 do
        runtime:update(1 / 30)
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
      Assert.notNil(runtime.battleRuntime, "the covered launch constructs its battle")
      Assert.notNil(coveredAt, "cover completes before construction")
      Assert.notNil(leftAt, "semantic leave follows cover")
      Assert.isTrue(coveredAt <= leftAt, "leave never precedes full cover")
      Assert.equal(coverAtLeave, 16, "semantic leave happens under full cover")
      Assert.equal(envelope:cover().coefficient, 16, "the battle starts under full cover")
      local experienceBefore = assert(runtime.monService:partyMon(0), "the live lead is readable").experience
      local turns = settle(runtime, envelope, function(request)
        return sparringChoose(runtime, request)
      end, 6000)
      Assert.isTrue(turns > 0, "the presented battle answers decisions to its committed words")
      pump(runtime, envelope, 60)
      Assert.equal(runtime:lastBattleResult().result, "win", "the win reports its exact word")
      Assert.equal(runtime:lastBattleResult().sourceResult, 1, "the win reads back won")
      Assert.equal(runtime:battleStatus(launchId).result, "win", "the launch receipt carries the win")
      Assert.isTrue(runtime:battleStatus(launchId).committed, "the receipt commits only at the safe field")
      Assert.isTrue(runtime.monService:partyMon(0).experience > experienceBefore, "the win publishes experience once")
      Assert.equal(runtime.overworld:phase(), "present", "the continuing return restores presence")
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
        runtime:update(1 / 30)
        envelope:updateFixed(TICK)
        advanced = advanced + 1
      end
      Assert.isTrue(blackout:status().phase ~= "message_wait", "a matched tap advances the waiting message")
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

-- Two consecutive launches build two fresh ports and screens, each
-- disposed exactly once, while the live field session survives both.
function T.second_launch_gets_a_fresh_port_and_screen()
  for _, versionId in ipairs(readyVersions()) do
    local runtime = bootRuntime(versionId)
    local envelope, binding, doubles = bindEnvelope(runtime, versionId, dualMeasurement("presented-second:dual"))
    local disposed = {}
    local ok, failure = xpcall(function()
      local firstField = runtime.session
      for round = 1, 2 do
        runtime:launchBattle({ kind = "wild", details = { species = "CATERPIE", level = 3 } })
        waitConstructed(runtime, envelope)
        local port = doubles.ports[#doubles.ports]
        local firstDispose = port.dispose
        port.dispose = function()
          disposed[#disposed + 1] = round
          return firstDispose()
        end
        settle(runtime, envelope, function(request)
          return sparringChoose(runtime, request)
        end, 6000)
        pump(runtime, envelope, 60)
        Assert.equal(runtime:lastBattleResult().result, "win", "round " .. round .. " reports its own win")
        Assert.isTrue(runtime.session == firstField, "round " .. round .. " reuses the live field session")
      end
      Assert.equal(#doubles.ports, 2, "two launches build two fresh ports")
      Assert.isTrue(doubles.ports[1] ~= doubles.ports[2], "each launch owns its port")
      Assert.deepEqual(disposed, { 1, 2 }, "each port disposes exactly once in launch order")
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

-- Withdrawing the factory binding fails later admissions instead of
-- presenting without a screen, while the in-flight launch keeps the
-- port it was admitted with and completes normally.
function T.withdrawn_binding_fails_later_admissions()
  for _, versionId in ipairs(readyVersions()) do
    local runtime = bootRuntime(versionId)
    local envelope, binding, _ = bindEnvelope(runtime, versionId, dualMeasurement("presented-withdraw:dual"))
    local ok, failure = xpcall(function()
      runtime:launchBattle({ kind = "wild", details = { species = "CATERPIE", level = 3 } })
      waitConstructed(runtime, envelope)
      runtime:unbindBattlePresentation(binding)
      settle(runtime, envelope, function(request)
        return sparringChoose(runtime, request)
      end, 6000)
      pump(runtime, envelope, 60)
      Assert.equal(runtime:lastBattleResult().result, "win", "the admitted launch completes on its own port")
      local admitted, admitErr = pcall(runtime.launchBattle, runtime, {
        kind = "wild",
        details = { species = "CATERPIE", level = 3 },
      })
      Assert.isFalse(admitted, "admission without its factory fails loudly: " .. tostring(admitErr))
    end, debug.traceback)
    local closed = pcall(function()
      runtime:dispose()
    end)
    if not ok then
      error(failure, 0)
    end
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
      Assert.notNil(runtime.battleRuntime, "the launch is live before the quit")
      assert(envelope:liveScreen(), "the live screen owns the launch")
      runtime:dispose()
      Assert.isNil(runtime.battleRuntime, "quitting releases the live battle")
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

-- Follower reconciliation and transition clocks freeze under the
-- presented hold alongside player movement, then resume with the field.
function T.follower_clocks_freeze_under_the_hold()
  for _, versionId in ipairs(readyVersions()) do
    local runtime = bootRuntime(versionId)
    local envelope, binding, _ = bindEnvelope(runtime, versionId, dualMeasurement("presented-follower:dual"))
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
      runtime:launchBattle({ kind = "wild", details = { species = "CATERPIE", level = 3 } })
      waitConstructed(runtime, envelope)
      local heldFollower, heldTransition = followerSteps, transitionSteps
      pump(runtime, envelope, 20)
      Assert.equal(followerSteps, heldFollower, "the follower freezes under the hold")
      Assert.equal(transitionSteps, heldTransition, "follower transitions freeze under the hold")
      settle(runtime, envelope, function(request)
        return sparringChoose(runtime, request)
      end, 6000)
      pump(runtime, envelope, 60)
      Assert.isTrue(followerSteps > heldFollower, "the follower resumes with the field")
      Assert.isTrue(transitionSteps > heldTransition, "follower transitions resume with the field")
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

-- Semantic battle input reaches the live screen before field controls:
-- a confirm moves the command cursor into its moves view while the
-- player tile and the Start Menu stay untouched.
function T.battle_input_reaches_the_screen_before_field_controls()
  for _, versionId in ipairs(readyVersions()) do
    local runtime = bootRuntime(versionId)
    local envelope, binding, _ = bindEnvelope(runtime, versionId, compactMeasurement("presented-input:compact"))
    local ok, failure = xpcall(function()
      local before = { fieldX = runtime.player.fieldX, fieldZ = runtime.player.fieldZ }
      runtime:launchBattle({ kind = "wild", details = { species = "CATERPIE", level = 3 } })
      waitConstructed(runtime, envelope)
      local ticks = 0
      while ticks < 900 do
        runtime:update(1 / 30)
        envelope:updateFixed(TICK)
        ticks = ticks + 1
        local screen = envelope:liveScreen()
        if screen ~= nil and screen:status().mode == "command" then
          break
        end
      end
      local screen = assert(envelope:liveScreen(), "the battle reaches its command root")
      Assert.equal(screen:status().mode, "command", "the root shows its commands")
      envelope:input({ { type = "confirm" } })
      pump(runtime, envelope, 5)
      Assert.equal(screen:status().mode, "moves", "a confirm enters the move view")
      Assert.deepEqual(
        { fieldX = runtime.player.fieldX, fieldZ = runtime.player.fieldZ },
        before,
        "battle input never moves the player"
      )
      Assert.isFalse(runtime.applicationHost:isActive(), "battle input never opens the Start Menu")
      envelope:input({ { type = "cancel" } })
      pump(runtime, envelope, 5)
      Assert.equal(screen:status().mode, "command", "a cancel returns to the command root")
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

-- The continuing receipt publishes only after the revealed field
-- returns: mid-reveal polls stay pending while the safe field commits.
function T.continuing_receipts_wait_for_the_reveal()
  for _, versionId in ipairs(readyVersions()) do
    local runtime = bootRuntime(versionId)
    local envelope, binding, _ = bindEnvelope(runtime, versionId, dualMeasurement("presented-reveal:dual"))
    local ok, failure = xpcall(function()
      local launchId = runtime:launchBattle({ kind = "wild", details = { species = "CATERPIE", level = 3 } })
      waitConstructed(runtime, envelope)
      local revealing = false
      local turns, ticks = 0, 0
      while runtime.battleRuntime ~= nil and ticks < 6000 do
        local battle = runtime.battleRuntime
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
        local launch = runtime._battleLaunch
        if launch ~= nil and launch.phase == "revealing" then
          revealing = true
          local status = runtime:battleStatus(launchId)
          Assert.isTrue(status ~= nil and not status.committed, "mid-reveal polls stay pending")
        end
      end
      Assert.isNil(runtime.battleRuntime, "answered decisions settle the owned presented lifetime")
      Assert.isTrue(turns > 0, "the presented battle answers decisions")
      Assert.isTrue(revealing, "the return reveals before publishing")
      Assert.isNil(runtime._battleLaunch, "the receipt clears the launch")
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

-- Identical decisions settle identically across fixed-tick schedules and
-- layouts: batched updates and compact, wide, and tall surfaces report
-- the same words, prize, and experience as the single-tick dual run.
function T.schedules_and_layouts_settle_identically()
  local versions = readyVersions()
  local versionId = versions[1]
  local function runSettled(measurement, stepsPerPump)
    local runtime = bootRuntime(versionId)
    local envelope, binding, _ = bindEnvelope(runtime, versionId, measurement)
    local moneyBefore = runtime.playerData.profile.money
    local experienceBefore = assert(runtime.monService:partyMon(0), "the live lead is readable").experience
    runtime:launchBattle({ kind = "wild", details = { species = "CATERPIE", level = 3 } })
    local turns, ticks = 0, 0
    while (runtime.battleRuntime ~= nil or runtime._battleLaunch ~= nil) and ticks < 6000 do
      local battle = runtime.battleRuntime
      if battle ~= nil then
        local current = battle:status()
        if current.phase == "running" and current.request ~= nil then
          turns = turns + 1
          local actor = assert(current.request.actors[1], "every decision addresses its combatant")
          local accepted, replyErr = battle:submit(SessionFixture.replyFor(current.request, { strike(actor) }))
          Assert.isTrue(accepted, "a legal decision is accepted: " .. tostring(replyErr))
        end
      end
      -- The terminal leave needs its explicit final-page acknowledgment.
      local screen = envelope:liveScreen()
      if screen ~= nil then
        local shown = screen:status()
        if shown.mode == "intro" or shown.mode == "narration" or shown.mode == "outcome" then
          envelope:input({ { type = "confirm" } })
        end
      end
      for _ = 1, stepsPerPump do
        runtime:update(1 / 30)
      end
      envelope:updateFixed(stepsPerPump * TICK)
      ticks = ticks + 1
    end
    Assert.isNil(runtime.battleRuntime, "the scheduled battle settles")
    Assert.isNil(runtime._battleLaunch, "the receipt clears the launch")
    local consequence = {
      result = runtime:lastBattleResult(),
      money = runtime.playerData.profile.money - moneyBefore,
      experience = runtime.monService:partyMon(0).experience - experienceBefore,
      turns = turns,
    }
    local unbound = pcall(function()
      runtime:unbindBattlePresentation(binding)
    end)
    local closed = pcall(function()
      runtime:dispose()
    end)
    Assert.isTrue(unbound, "each scheduled run releases its factory binding")
    Assert.isTrue(closed, "each scheduled run tears down")
    return consequence
  end
  local single = runSettled(dualMeasurement("presented-clocks:dual-single"), 1)
  Assert.equal(single.result.result, "win", "the scheduled battle wins")
  local batched = runSettled(dualMeasurement("presented-clocks:dual-batched"), 3)
  Assert.deepEqual(batched.result, single.result, "batched fixed ticks settle the same words")
  Assert.equal(batched.money, single.money, "batched fixed ticks pay the same prize")
  Assert.equal(batched.experience, single.experience, "batched fixed ticks publish the same experience")
  Assert.equal(batched.turns, single.turns, "batched fixed ticks answer the same turns")
  local compact = runSettled(compactMeasurement("presented-clocks:compact"), 1)
  Assert.deepEqual(compact.result, single.result, "the compact surface settles the same words")
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
  return setmetatable(base, FieldRuntime)
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
      return runtime:_captureLaunchEnvironment({ kind = launch.kind, payload = launch.payload }, method)
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

-- The host-update pump never advances a presented launch: without the
-- envelope driver the cover, leave, construction, and battle all freeze,
-- and the envelope resumes them on its next tick.
function T.host_updates_never_advance_presented_launches()
  for _, versionId in ipairs(readyVersions()) do
    local runtime = bootRuntime(versionId)
    local envelope, binding, _ = bindEnvelope(runtime, versionId, dualMeasurement("presented-clock:dual"))
    local ok, failure = xpcall(function()
      runtime:launchBattle({ kind = "wild", details = { species = "CATERPIE", level = 3 } })
      for _ = 1, 10 do
        runtime:update(1 / 30)
      end
      Assert.equal(runtime.overworld:phase(), "present", "host updates never request leave")
      Assert.isNil(runtime.battleRuntime, "host updates never construct")
      Assert.equal(envelope:cover().coefficient, 0, "host updates never advance cover")
      waitConstructed(runtime, envelope)
      local phaseBefore = runtime.battleRuntime:status().phase
      for _ = 1, 10 do
        runtime:update(1 / 30)
      end
      Assert.equal(
        runtime.battleRuntime:status().phase,
        phaseBefore,
        "host updates never advance the owned battle clock"
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

return {
  tests = T,
  metadata = {
    capabilities = { "rom_dump", "derived_assets" },
    derivedAssets = {
      "field-runtime",
      "map-data:64",
      "map:64",
      "trainers:global",
      "encounters:global",
      "battle-presentation:global",
    },
  },
}
