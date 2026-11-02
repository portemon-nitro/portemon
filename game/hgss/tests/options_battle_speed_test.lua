-- Battle presentation speed through the single envelope-owned clock: the
-- frozen launch factor scales accepted wall time and the catch-up budget
-- once, while every inner iteration still runs the complete ordered source
-- quantum. Screens, transitions, children, and delivery drains receive one
-- source quantum per call, never a scaled delta. Real audio completion,
-- asset readiness, and human choices stay truthful barriers; the world
-- clock and play time keep wall time; no credit crosses a launch, failure,
-- disposal, or ownership handoff.

local Assert = require("tests.support.Assert")
local FieldBattlePresentation = require("game.hgss.src.field.FieldBattlePresentation")
local FieldBattleCoordinator = require("game.hgss.src.field.FieldBattleCoordinator")
local SourceTick = require("libs.hgss.src.field.SourceTick")

local T = {}

local FRAME = SourceTick.DT

---@return table versioned derived-cache double behind the pending launch
local function stubCache()
  local cache = { versionId = "battle-speed-probe" }
  function cache:loadLua(_)
    return nil
  end
  function cache:read(_)
    return nil
  end
  function cache:exists(...)
    return false
  end
  return cache
end

---@return table envelope behind a forever-pending scene demand (no screen build)
local function newEnvelope()
  local derived = {}
  function derived.requestBattleScene(_, _)
    return false
  end
  return FieldBattlePresentation.new({
    cacheFs = stubCache(),
    windows = {},
    text = {},
    measureDisplay = function()
      return { width = 256, height = 384, topology = {}, pixelRatio = 1, signature = "battle-speed" }
    end,
    graphics = {},
    derivedAssets = derived,
  })
end

---@param phase string launch phase reported by the host double
---@return table recording host double behind the admitted launch
local function newHost(phase)
  local host = { phase = phase or "active", advances = 0, notifies = {}, submits = 0 }
  function host.status()
    return { phase = host.phase }
  end
  function host.advance()
    host.advances = host.advances + 1
  end
  function host.submit(_)
    host.submits = host.submits + 1
    return true
  end
  function host.notify(event, reason)
    host.notifies[#host.notifies + 1] = { event = event, reason = reason }
  end
  return host
end

---@return table counting screen double stepped once per source quantum
local function newScreen()
  local screen = { updates = 0, dts = {}, disposed = false }
  function screen:updateFixed(dt)
    screen.updates = screen.updates + 1
    screen.dts[#screen.dts + 1] = dt
  end
  function screen:status()
    return { mode = "ready" }
  end
  function screen:dispose()
    screen.disposed = true
  end
  function screen:cancelPointerCapture() end
  return screen
end

---@param envelope table admitted envelope under test
---@param host table recording host double behind the launch
---@param speed integer? frozen launch factor, nil for the historical default
---@param launchId string? launch identity, defaulting to the probe launch
---@return table pending port behind the admitted launch
local function admit(envelope, host, speed, launchId)
  local descriptor = {
    launchId = launchId or "speed-probe",
    kind = "wild",
    environment = { sceneKey = "general/grass/day" },
    host = host,
  }
  if speed ~= nil then
    descriptor.battleSpeed = speed
  end
  local port = envelope:factory()(descriptor)
  Assert.notNil(port, "admission hands back its pending port")
  return port
end

---@param envelope table admitted envelope under test
---@param host table recording host double behind the launch
---@param speed integer? frozen launch factor, nil for the historical default
---@param launchId string? launch identity, defaulting to the probe launch
---@return table live rig with the admitted envelope, host, screen, and port
local function admitWithScreen(envelope, host, speed, launchId)
  local port = admit(envelope, host, speed, launchId)
  local screen = newScreen()
  envelope._screen = screen
  return { envelope = envelope, host = host, screen = screen, port = port }
end

---@param port table pending port behind the test launch
---@param envelope table admitted envelope under test
local function closeRig(port, envelope)
  pcall(function()
    port.dispose()
  end)
  pcall(function()
    envelope:dispose()
  end)
end

function T.single_speed_runs_one_complete_quantum_per_accepted_tick()
  local envelope = newEnvelope()
  local host = newHost("active")
  local rig = admitWithScreen(envelope, host, nil, "speed-single")
  local ok, failure = xpcall(function()
    local order = {}
    local realAdvance = host.advance
    function host.advance()
      order[#order + 1] = "host"
      realAdvance()
    end
    local screen = rig.screen
    local realUpdate = screen.updateFixed
    function screen:updateFixed(dt)
      order[#order + 1] = "screen"
      realUpdate(screen, dt)
    end
    for _ = 1, 3 do
      envelope:updateFixed(FRAME)
    end
    Assert.equal(host.advances, 3, "one launch advance runs per accepted source tick")
    Assert.equal(screen.updates, 3, "one screen quantum runs per accepted source tick")
    Assert.deepEqual(order, { "host", "screen", "host", "screen", "host", "screen" }, "quanta keep host-then-screen order")
    for index, dt in ipairs(screen.dts) do
      Assert.equal(dt, FRAME, "quantum " .. index .. " steps exactly one source quantum")
    end
  end, debug.traceback)
  closeRig(rig.port, envelope)
  if not ok then
    error(failure, 0)
  end
end

function T.speed_factor_runs_that_many_complete_quanta_per_accepted_tick()
  for _, factor in ipairs({ 2, 4 }) do
    local envelope = newEnvelope()
    local host = newHost("active")
    local rig = admitWithScreen(envelope, host, factor, "speed-factor-" .. factor)
    local ok, failure = xpcall(function()
      envelope:updateFixed(FRAME)
      Assert.equal(host.advances, factor, factor .. "x advances its launch once per virtual quantum")
      Assert.equal(rig.screen.updates, factor, factor .. "x steps its screen once per virtual quantum")
      Assert.equal(#rig.screen.dts, factor, factor .. "x records one delta per virtual quantum")
      for index, dt in ipairs(rig.screen.dts) do
        Assert.equal(dt, FRAME, factor .. "x quantum " .. index .. " keeps the source quantum")
      end
    end, debug.traceback)
    closeRig(rig.port, envelope)
    if not ok then
      error(failure, 0)
    end
  end
end

function T.speed_banks_fractional_host_frames_without_rounding()
  local envelope = newEnvelope()
  local host = newHost("active")
  local rig = admitWithScreen(envelope, host, 4, "speed-fractional")
  local ok, failure = xpcall(function()
    envelope:updateFixed(FRAME / 2)
    Assert.equal(host.advances, 2, "a half host frame at 4x banks two whole quanta")
    envelope:updateFixed(FRAME / 2)
    Assert.equal(host.advances, 4, "the next half host frame banks two more whole quanta")
    Assert.equal(rig.screen.updates, 4, "banked credit steps the screen without rounding source time")
  end, debug.traceback)
  closeRig(rig.port, envelope)
  if not ok then
    error(failure, 0)
  end
end

function T.speed_budget_caps_low_host_fps_without_backlog_burst()
  local envelope = newEnvelope()
  local host = newHost("active")
  local rig = admitWithScreen(envelope, host, 4, "speed-budget")
  local ok, failure = xpcall(function()
    envelope:updateFixed(24 * FRAME)
    Assert.equal(host.advances, 24, "a long frame at 4x admits six virtual ticks per factor")
    Assert.equal(rig.screen.updates, 24, "the capped budget steps the screen once per admitted tick")
    envelope:updateFixed(FRAME)
    Assert.equal(host.advances, 28, "discarded excess never bursts into the next update")
  end, debug.traceback)
  closeRig(rig.port, envelope)
  if not ok then
    error(failure, 0)
  end
  local single = newEnvelope()
  local singleHost = newHost("active")
  local singleRig = admitWithScreen(single, singleHost, 1, "speed-baseline-budget")
  local singleOk, singleFailure = xpcall(function()
    single:updateFixed(24 * FRAME)
    Assert.equal(singleHost.advances, 6, "the single-rate budget stays at six virtual ticks")
  end, debug.traceback)
  closeRig(singleRig.port, single)
  if not singleOk then
    error(singleFailure, 0)
  end
end

function T.missing_speed_defaults_to_single_rate()
  local envelope = newEnvelope()
  local host = newHost("active")
  local rig = admitWithScreen(envelope, host, nil, "speed-default")
  local ok, failure = xpcall(function()
    envelope:updateFixed(FRAME)
    Assert.equal(host.advances, 1, "a launch without a frozen factor keeps single rate")
    Assert.equal(rig.screen.updates, 1, "the default launch steps one quantum per accepted tick")
  end, debug.traceback)
  closeRig(rig.port, envelope)
  if not ok then
    error(failure, 0)
  end
end

function T.speed_rejects_malformed_factors_at_admission()
  for _, bad in ipairs({ 0, 3, 8, -1, "fast", true }) do
    local envelope = newEnvelope()
    local host = newHost("active")
    local ok, _ = pcall(function()
      admit(envelope, host, bad, "speed-malformed")
    end)
    pcall(function()
      envelope:dispose()
    end)
    Assert.isFalse(ok, "factor " .. tostring(bad) .. " fails admission instead of launching")
  end
end

function T.speed_freezes_at_admission_and_resets_between_launches()
  local envelope = newEnvelope()
  local host = newHost("active")
  local rig = admitWithScreen(envelope, host, 4, "speed-first")
  local ok, failure = xpcall(function()
    envelope:updateFixed(FRAME)
    Assert.equal(host.advances, 4, "the first launch runs at its frozen factor")
    host.phase = "complete"
    envelope:updateFixed(FRAME)
    Assert.equal(host.advances, 4, "settlement stops accelerated stepping")
    local secondHost = newHost("active")
    admit(envelope, secondHost, 1, "speed-second")
    local secondScreen = newScreen()
    envelope._screen = secondScreen
    envelope:updateFixed(FRAME / 2)
    Assert.equal(secondHost.advances, 0, "no fast credit survives into the next launch")
    envelope:updateFixed(FRAME / 2)
    Assert.equal(secondHost.advances, 1, "the next launch starts from a clean accumulator")
  end, debug.traceback)
  closeRig(rig.port, envelope)
  if not ok then
    error(failure, 0)
  end
end

function T.speed_stops_mid_burst_when_the_launch_fails_without_touching_released_state()
  local envelope = newEnvelope()
  local host = newHost("active")
  local rig = admitWithScreen(envelope, host, 4, "speed-failing")
  local advances = 0
  local realAdvance = host.advance
  function host.advance()
    advances = advances + 1
    realAdvance()
    if advances == 2 then
      host.phase = "failed"
    end
  end
  local ok, failure = xpcall(function()
    envelope:updateFixed(10 * FRAME)
    Assert.equal(host.advances, 2, "the failing launch stops its burst at the observed failure")
    Assert.equal(rig.screen.updates, 2, "no quantum steps the screen after the launch drops")
    envelope:updateFixed(FRAME)
    Assert.equal(host.advances, 2, "the dropped launch stays dropped on later updates")
    Assert.equal(#host.notifies, 0, "a bare host failure drops the launch without inventing a report")
  end, debug.traceback)
  closeRig(rig.port, envelope)
  if not ok then
    error(failure, 0)
  end
end

function T.speed_never_invents_input_replies_or_audio_completion()
  local envelope = newEnvelope()
  local host = newHost("active")
  local rig = admitWithScreen(envelope, host, 4, "speed-barriers")
  local ok, failure = xpcall(function()
    local voice = { polls = 0, needed = 3, volume = 0, done = false }
    local screen = rig.screen
    local realUpdate = screen.updateFixed
    function screen:updateFixed(dt)
      realUpdate(screen, dt)
      voice.polls = voice.polls + 1
      if voice.polls >= voice.needed then
        voice.done = true
      end
    end
    local decisionPending = true
    envelope:updateFixed(FRAME / 4)
    Assert.equal(voice.polls, 1, "one virtual quantum polls real completion once")
    Assert.isFalse(voice.done, "a single quantum never fakes voice completion")
    Assert.isTrue(decisionPending, "visual ticks never answer the pending human choice")
    Assert.equal(host.submits, 0, "visual ticks never submit an input reply")
    envelope:updateFixed(2 * FRAME)
    Assert.isTrue(voice.done, "truthful polling still completes at zero volume")
    Assert.equal(voice.polls, 9, "completion follows real polls, never a guessed duration")
    Assert.isTrue(decisionPending, "the choice still waits for its real edge")
    decisionPending = host.submit({ kind = "confirm" }) and false or decisionPending
    Assert.equal(host.submits, 1, "one delivered edge records one reply")
    envelope:updateFixed(2 * FRAME)
    Assert.equal(host.submits, 1, "later fast ticks never replay the consumed edge")
  end, debug.traceback)
  closeRig(rig.port, envelope)
  if not ok then
    error(failure, 0)
  end
end

function T.speed_and_scene_modes_keep_the_same_callback_trace()
  local function runTrace(speed, sceneChoice, ticks, dt)
    local envelope = newEnvelope()
    local host = newHost("active")
    local descriptor = {
      launchId = "speed-trace",
      kind = "wild",
      environment = { sceneKey = "general/grass/day" },
      battleScene = sceneChoice,
      host = host,
    }
    if speed ~= nil then
      descriptor.battleSpeed = speed
    end
    local port = envelope:factory()(descriptor)
    local screen = newScreen()
    envelope._screen = screen
    local trace = {}
    local realAdvance = host.advance
    function host.advance()
      trace[#trace + 1] = "host"
      realAdvance()
    end
    local realUpdate = screen.updateFixed
    function screen:updateFixed(delta)
      trace[#trace + 1] = "screen:" .. tostring(delta == FRAME)
      realUpdate(screen, delta)
    end
    for _ = 1, ticks do
      envelope:updateFixed(dt)
    end
    closeRig(port, envelope)
    return trace
  end
  local singleRate = runTrace(nil, true, 4, FRAME)
  local fastRate = runTrace(4, true, 1, FRAME)
  Assert.deepEqual(fastRate, singleRate, "1x over four ticks matches 4x over one tick callback for callback")
  local sceneOff = runTrace(4, false, 1, FRAME)
  Assert.deepEqual(sceneOff, fastRate, "scene suppression never changes the acceleration factor")
end

function T.speed_credit_never_survives_disposal()
  local envelope = newEnvelope()
  local host = newHost("active")
  local rig = admitWithScreen(envelope, host, 4, "speed-disposed")
  envelope:updateFixed(FRAME / 8)
  Assert.equal(host.advances, 0, "a sub-quantum credit performs no work yet")
  envelope:dispose()
  local ok, _ = pcall(function()
    envelope:updateFixed(FRAME)
  end)
  Assert.isFalse(ok, "a disposed envelope steps nothing")
  pcall(function()
    rig.port.dispose()
  end)
end

---@return table field-runtime double behind the coordinator probe
---@param speed unknown battle-speed value carried by the validated options
local function coordinatorRuntime(speed)
  local options = { textSpeed = "mid", battleScene = true, battleSpeed = speed }
  return {
    playerData = { options = options, profile = { gender = 0 } },
    session = {
      setBattleActive = function(_, _) end,
      setForegroundHold = function(_, _) end,
    },
    input = {
      clearAll = function(_) end,
    },
    audio = {},
    arrivalBehavior = function(_, _, _)
      return nil
    end,
  }
end

function T.coordinator_freezes_the_validated_speed_in_the_launch_descriptor()
  for _, speed in ipairs({ 1, 2, 4 }) do
    local runtime = coordinatorRuntime(speed)
    local coordinator = FieldBattleCoordinator.new(runtime)
    local seen = nil
    coordinator:bindBattlePresentation(function(descriptor)
      seen = descriptor
      return {
        enter = function(_)
          return true
        end,
        present = function(_)
          return true
        end,
        leave = function(_)
          return true
        end,
        dispose = function(_) end,
      }
    end)
    coordinator:launchPresentedBattle("speed-launch-" .. speed, { id = "speed-launch-" .. speed, kind = "wild", payload = {} }, nil)
    Assert.notNil(seen, "the factory receives the launch descriptor at factor " .. speed)
    Assert.equal(seen.battleSpeed, speed, "the descriptor freezes the validated factor " .. speed)
  end
end

function T.coordinator_defaults_a_missing_speed_and_rejects_malformed_speeds()
  do
    local runtime = coordinatorRuntime(nil)
    runtime.playerData.options.battleSpeed = nil
    local coordinator = FieldBattleCoordinator.new(runtime)
    local seen = nil
    coordinator:bindBattlePresentation(function(descriptor)
      seen = descriptor
      return {
        enter = function(_)
          return true
        end,
        present = function(_)
          return true
        end,
        leave = function(_)
          return true
        end,
        dispose = function(_) end,
      }
    end)
    coordinator:launchPresentedBattle("speed-launch-default", { id = "speed-launch-default", kind = "wild", payload = {} }, nil)
    Assert.notNil(seen, "the factory receives the defaulted descriptor")
    Assert.equal(seen.battleSpeed, 1, "a missing factor defaults to single rate")
  end
  for _, bad in ipairs({ 0, 3, 8, "fast" }) do
    local runtime = coordinatorRuntime(bad)
    local coordinator = FieldBattleCoordinator.new(runtime)
    coordinator:bindBattlePresentation(function(_)
      return {
        enter = function(_)
          return true
        end,
        present = function(_)
          return true
        end,
        leave = function(_)
          return true
        end,
        dispose = function(_) end,
      }
    end)
    local ok, _ = pcall(function()
      coordinator:launchPresentedBattle("speed-launch-bad", { id = "speed-launch-bad", kind = "wild", payload = {} }, nil)
    end)
    Assert.isFalse(ok, "factor " .. tostring(bad) .. " fails the launch instead of freezing")
  end
end

return { tests = T }
