local Assert = require("tests.support.Assert")
local FieldBattlePresentation = require("game.hgss.src.field.FieldBattlePresentation")

local T = {}

function T.accepted_transition_ticks_refresh_owned_planes_and_draw_only_reads_the_frame()
  local steps = 0
  local draws = 0
  local disposed = 0
  local captures = 0
  local function acceptFieldLayers(_, layers)
    Assert.equal(layers.index, captures, "the active family receives its matching source capture")
  end
  local function disposeCapture()
    disposed = disposed + 1
  end
  local function capture()
    captures = captures + 1
    return { index = captures, dispose = disposeCapture }
  end
  local function transitionStatus()
    return { phase = "running" }
  end
  local function stepSourceTick()
    steps = steps + 1
  end
  local function transitionFrame()
    return { sourcePhase = steps, requiresCurrentFieldLayers = true }
  end
  local function disposeTransition() end
  local function drawTransition(_, sourceCapture, frame, destination)
    draws = draws + 1
    Assert.equal(sourceCapture.index, captures, "draw reads the latest accepted field capture")
    Assert.equal(frame.sourcePhase, steps, "draw sees the current native source task frame")
    Assert.equal(destination.width, 512, "resize destination is a draw-only mapping input")
  end
  local transition = {
    status = transitionStatus,
    stepSourceTick = stepSourceTick,
    acceptFieldLayers = acceptFieldLayers,
    frame = transitionFrame,
    dispose = disposeTransition,
  }
  local envelope = setmetatable({
    _transition = transition,
    _transitionCapture = capture(),
    _captureFieldLayers = capture,
    _fieldRenderer = { drawTransition = drawTransition },
  }, FieldBattlePresentation)

  envelope:_stepTransition()
  Assert.equal(steps, 1, "one accepted update advances one source task tick")
  Assert.equal(captures, 2, "the source task captures fresh field planes after its mutation")
  Assert.equal(disposed, 1, "replaced launch-owned planes are released exactly once")
  Assert.isTrue(envelope:drawTransition({ x = 0, y = 0, width = 512, height = 384 }), "running route draws")
  Assert.isTrue(
    envelope:drawTransition({ x = 0, y = 0, width = 512, height = 384 }),
    "repeated draw reads the same route frame"
  )
  Assert.equal(steps, 1, "draw never advances source time")
  Assert.equal(captures, 2, "draw never captures or regenerates source planes")
  Assert.equal(draws, 2, "each host draw presents the latest frame")

  envelope:_disposeTransition()
  envelope:_disposeTransition()
  Assert.equal(disposed, 2, "launch disposal releases the final field capture once")
end

-- A rejected field-layer accept releases the replacement capture
-- exactly once and still fails the launch through the established
-- failure path: the previous launch capture is released exactly once
-- instead of leaking, and the host hears the source-update failure.
function T.transition_accept_failure_disposes_the_replacement_and_releases_the_launch_capture()
  local events = {}
  local previousDisposed = 0
  local replacementDisposed = 0
  local transitionDisposed = 0
  local captures = 0
  local function capture()
    captures = captures + 1
    if captures == 1 then
      return {
        index = 1,
        dispose = function()
          previousDisposed = previousDisposed + 1
        end,
      }
    end
    return {
      index = captures,
      dispose = function()
        replacementDisposed = replacementDisposed + 1
      end,
    }
  end
  local previous = capture()
  local transition = {
    status = function()
      return { phase = "running" }
    end,
    stepSourceTick = function() end,
    acceptFieldLayers = function()
      error("injected acceptFieldLayers failure")
    end,
    frame = function()
      return { requiresCurrentFieldLayers = true }
    end,
    dispose = function()
      transitionDisposed = transitionDisposed + 1
    end,
  }
  local envelope = setmetatable({
    _launchId = "wild#accept-fail",
    _descriptor = {
      launchId = "wild#accept-fail",
      host = {
        notify = function(event, detail)
          events[#events + 1] = { event = event, detail = detail }
        end,
      },
    },
    _transition = transition,
    _transitionCapture = previous,
    _captureFieldLayers = capture,
    _transitionContext = {},
  }, FieldBattlePresentation)

  envelope:_stepTransition()

  Assert.equal(captures, 2, "the source task captures fresh field planes before the accept")
  Assert.equal(replacementDisposed, 1, "the rejected replacement capture is released exactly once")
  Assert.equal(previousDisposed, 1, "the launch-owned capture is released exactly once, never leaked")
  Assert.equal(transitionDisposed, 1, "the native family is released exactly once through the failure path")
  Assert.isNil(envelope._transition, "a failed accept drops the native family")
  Assert.isNil(envelope._transitionCapture, "a failed accept drops the field capture")
  Assert.isTrue(envelope._transitionFailed, "a failed accept marks the launch failed")
  Assert.equal(#events, 1, "the launch host hears the failure exactly once")
  Assert.equal(events[1].event, "screen-failed", "the launch failure reaches the host")
  Assert.isTrue(
    events[1].detail:find("wild#accept-fail", 1, true) ~= nil,
    "failure context carries the launch identity"
  )
  Assert.isTrue(
    events[1].detail:find("source update", 1, true) ~= nil,
    "failure context carries the source-update operation"
  )
  Assert.isTrue(
    events[1].detail:find("injected acceptFieldLayers failure", 1, true) ~= nil,
    "failure context carries the original accept cause"
  )
  Assert.isTrue(
    envelope:drawTransition({ x = 0, y = 0, width = 512, height = 384 }),
    "draw stays consumed while the failed launch awaits recovery"
  )
end

function T.transition_draw_failure_reports_launch_and_releases_route_resources()
  local notified = nil
  local transitionDisposed = 0
  local captureDisposed = 0
  local function transitionStatus()
    return { phase = "running" }
  end
  local function transitionFrame()
    return { sourcePhase = 1 }
  end
  local function disposeTransition()
    transitionDisposed = transitionDisposed + 1
  end
  local function notify(event, detail)
    notified = { event = event, detail = detail }
  end
  local function disposeCapture()
    captureDisposed = captureDisposed + 1
  end
  local function drawTransition()
    error("injected transition image draw failure")
  end
  local transition = {
    status = transitionStatus,
    frame = transitionFrame,
    dispose = disposeTransition,
  }
  local envelope = setmetatable({
    _launchId = "wild#23",
    _descriptor = {
      launchId = "wild#23",
      host = { notify = notify },
    },
    _transition = transition,
    _transitionCapture = { dispose = disposeCapture },
    _fieldRenderer = { drawTransition = drawTransition },
  }, FieldBattlePresentation)

  Assert.isTrue(
    envelope:drawTransition({ x = 0, y = 0, width = 256, height = 192 }),
    "a failed transition consumes the current draw without invoking a generic fallback"
  )
  Assert.equal(notified.event, "screen-failed", "the launch host receives the failure event")
  Assert.isTrue(
    notified.detail:find("battle transition draw failed for launch wild#23:", 1, true) ~= nil,
    "failure context carries the launch identity"
  )
  Assert.isTrue(
    notified.detail:find("injected transition image draw failure", 1, true) ~= nil,
    "failure context carries the original renderer cause"
  )
  Assert.equal(envelope:transitionStatus(), nil, "failed transition status is released")
  Assert.equal(transitionDisposed, 1, "the native family is disposed once")
  Assert.equal(captureDisposed, 1, "the field capture is disposed once")
  Assert.isTrue(
    envelope:drawTransition({ x = 0, y = 0, width = 256, height = 192 }),
    "repeat draws remain consumed while C01 recovers"
  )
  Assert.equal(transitionDisposed, 1, "repeat draw does not redispose the family")
  Assert.equal(captureDisposed, 1, "repeat draw does not redispose the capture")
end

-- One verified core serves every preparation round and the selected
-- transition without another disk parse: repeat preparation and the
-- production transition loader borrow the identical table the envelope
-- verified once, while a new field selection verifies its own core.
function T.verified_core_serves_repeat_preparation_and_transition_without_rereading()
  local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
  local ManifestFixture = require("tests.support.BattlePresentationManifestFixture")
  local manifestPath = BattlePresentationCache.manifestPath()
  local stored = ManifestFixture.coreManifest()
  local leaves = {
    [BattlePresentationCache.trainerPicturePath("front:YOUNGSTER")] = ManifestFixture.trainerPictureRecord(
      "front:YOUNGSTER"
    ),
    [BattlePresentationCache.ballPath("ball:POKE_BALL")] = ManifestFixture.ballRecord("ball:POKE_BALL"),
  }
  local resourcePath = "data/generated/battle/resources/menu/layout/bug-contest/palette.lua"
  local resourceDoc = {}
  local globalReads = 0
  local function deepCopyDoc(value)
    if type(value) ~= "table" then
      return value
    end
    local copy = {}
    for key, item in pairs(value) do
      copy[deepCopyDoc(key)] = deepCopyDoc(item)
    end
    return copy
  end
  local cache = { versionId = "verified-core-probe" }
  function cache:loadLua(path)
    if path == manifestPath then
      globalReads = globalReads + 1
      -- Every disk read parses afresh, exactly like the versioned cache
      -- filesystem, so shared references prove borrowing rather than
      -- coincidentally identical table returns.
      return deepCopyDoc(stored)
    end
    if path == resourcePath then
      return resourceDoc
    end
    return leaves[path]
  end
  function cache:exists()
    return true
  end
  local host = {}
  function host.requestBattlePresentation(_)
    return true
  end
  function host.requestBattleScene(_, _)
    return true
  end
  function host.requestBattleTrainerPicture(_, _)
    return true
  end
  function host.requestBattleBall(_, _)
    return true
  end
  local function openEnvelope()
    return FieldBattlePresentation.new({
      cacheFs = cache,
      windows = { drawWindow = function() end },
      text = {
        measure = function(_)
          return { width = 8, height = 16 }
        end,
        drawText = function() end,
      },
      measureDisplay = function()
        return {}
      end,
      derivedAssets = host,
      fieldRenderer = {},
      captureFieldLayers = function()
        return { dispose = function() end }
      end,
    })
  end
  local envelope = openEnvelope()
  local ok, failure = xpcall(function()
    Assert.equal(globalReads, 1, "construction verifies the core once")
    local services = envelope:_preparationServices()
    local demand = {
      launchId = "verified-core-launch",
      scenes = {},
      pages = {},
      trainerPictures = { "front:YOUNGSTER" },
      battleBalls = { "ball:POKE_BALL" },
      audio = { roles = {}, banks = {}, cries = {} },
    }
    local firstReady = services.prepare(demand)
    local secondReady = services.prepare(demand)
    Assert.equal(globalReads, 1, "repeat preparation shares the single verified parse")
    Assert.isTrue(firstReady and secondReady, "both preparation rounds stage their selected leaves from the core")
    envelope:_startTransition({
      launchId = "verified-core-launch",
      environment = { sceneKey = "general/grass/day" },
      transitionContext = {
        kind = "trainer",
        trainerClass = "trainer/red",
        doubleBattle = false,
        specialBattle = false,
        alternateTransition = false,
      },
    })
    local transition = assert(envelope._transition, "the launch owns its selected transition")
    Assert.equal(
      transition:prepare(envelope._transitionContext),
      "ready",
      "the selected transition prepares from the verified core"
    )
    Assert.equal(transition:status().routeKey, "trainer/red", "the transition resolves its source route")
    Assert.equal(globalReads, 1, "the transition loader borrows the core without another parse")
    envelope:dispose()
    local fresh = openEnvelope()
    local freshOk, freshFailure = xpcall(function()
      Assert.equal(globalReads, 2, "a new field selection verifies its own core once")
    end, debug.traceback)
    pcall(function()
      fresh:dispose()
    end)
    if not freshOk then
      error(freshFailure, 0)
    end
  end, debug.traceback)
  pcall(function()
    envelope:dispose()
  end)
  if not ok then
    error(failure, 0)
  end
end

return { tests = T }
