local Assert = require("tests.support.Assert")
local FieldBattlePresentation = require("game.hgss.src.field.FieldBattlePresentation")

local T = {}

function T.accepted_transition_ticks_refresh_owned_planes_and_draw_only_reads_the_frame()
  local steps = 0
  local draws = 0
  local disposed = 0
  local captures = 0
  local captureCalls = {}
  local function acceptFieldLayers(_, layers)
    Assert.equal(layers.index, captures, "the active family receives its matching source capture")
  end
  local function disposeCapture()
    disposed = disposed + 1
  end
  local function capture(spare)
    captures = captures + 1
    captureCalls[#captureCalls + 1] = { index = captures, spare = spare }
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
  Assert.isNil(captureCalls[2].spare, "the first tick fills a fresh spare")
  Assert.equal(disposed, 0, "an accepted tick swaps slots instead of disposing the previous frame")
  Assert.equal(envelope._transitionCapture.index, 2, "the latest accepted capture publishes the draw frame")
  Assert.equal(envelope._transitionCaptureSpare.index, 1, "the previous frame survives as the reusable spare")
  Assert.isTrue(envelope:drawTransition({ x = 0, y = 0, width = 512, height = 384 }), "running route draws")
  Assert.isTrue(
    envelope:drawTransition({ x = 0, y = 0, width = 512, height = 384 }),
    "repeated draw reads the same route frame"
  )
  Assert.equal(steps, 1, "draw never advances source time")
  Assert.equal(captures, 2, "draw never captures or regenerates source planes")
  Assert.equal(draws, 2, "each host draw presents the latest frame")

  envelope:_stepTransition()
  Assert.equal(steps, 2, "the next accepted update advances the source task again")
  Assert.equal(captures, 3, "the next tick captures after its own mutation")
  Assert.isTrue(
    captureCalls[3].spare ~= nil and captureCalls[3].spare.index == 1,
    "the next tick refills the retired spare instead of allocating"
  )
  Assert.equal(disposed, 1, "a spare the producer did not reuse releases exactly once")
  Assert.equal(envelope._transitionCapture.index, 3, "approval publishes the newest frame")
  Assert.equal(envelope._transitionCaptureSpare.index, 2, "roles swap on every accepted tick")
  Assert.isTrue(envelope:drawTransition({ x = 0, y = 0, width = 512, height = 384 }), "draw reads the newest frame")
  Assert.equal(draws, 3, "each host draw presents the latest frame")

  envelope:_disposeTransition()
  envelope:_disposeTransition()
  Assert.equal(disposed, 3, "launch disposal releases every distinct slot exactly once")
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

-- A capture failure mid-launch keeps the last published frame untouched
-- until teardown: the failed tick releases only its replacement, the
-- active and spare slots release exactly once each, and the host hears
-- the source-update failure.
function T.transition_capture_failure_releases_replacement_and_reports_source_update()
  local events = {}
  local activeDisposed = 0
  local spareDisposed = 0
  local transitionDisposed = 0
  local captures = 0
  local active = {
    index = 1,
    dispose = function()
      activeDisposed = activeDisposed + 1
    end,
  }
  local spare = {
    index = 0,
    dispose = function()
      spareDisposed = spareDisposed + 1
    end,
  }
  local function capture(_)
    captures = captures + 1
    error("injected captureFieldLayers failure")
  end
  local phase = "running"
  local transition = {
    status = function()
      return { phase = phase }
    end,
    stepSourceTick = function() end,
    acceptFieldLayers = function() end,
    frame = function()
      return { sourcePhase = 1, requiresCurrentFieldLayers = phase == "running" }
    end,
    dispose = function()
      transitionDisposed = transitionDisposed + 1
    end,
  }
  local envelope = setmetatable({
    _launchId = "wild#capture-fail",
    _descriptor = {
      launchId = "wild#capture-fail",
      host = {
        notify = function(event, detail)
          events[#events + 1] = { event = event, detail = detail }
        end,
      },
    },
    _transition = transition,
    _transitionCapture = active,
    _transitionCaptureSpare = spare,
    _captureFieldLayers = capture,
    _transitionContext = {},
  }, FieldBattlePresentation)

  envelope:_stepTransition()
  Assert.equal(captures, 1, "the failed tick attempted its capture after the source mutation")
  Assert.equal(activeDisposed, 1, "teardown releases the last published frame exactly once")
  Assert.equal(spareDisposed, 1, "teardown releases the retired spare exactly once")
  Assert.equal(transitionDisposed, 1, "the native family releases exactly once through the failure path")
  Assert.isNil(envelope._transition, "a failed fill drops the native family")
  Assert.isNil(envelope._transitionCapture, "a failed fill drops the published capture")
  Assert.isNil(envelope._transitionCaptureSpare, "a failed fill drops the spare slot")
  Assert.isTrue(envelope._transitionFailed, "a failed fill marks the launch failed")
  Assert.equal(#events, 1, "the launch host hears the failure exactly once")
  Assert.isTrue(
    events[1].detail:find("injected captureFieldLayers failure", 1, true) ~= nil,
    "failure context carries the original capture cause"
  )
end

-- Completion releases both distinct slots exactly once: the published
-- frame and the retired spare never outlive the transition, and a second
-- observation stays a no-op.
function T.transition_completion_releases_active_and_spare_slots_once()
  local disposed = {}
  local function slot(index)
    return {
      index = index,
      dispose = function()
        disposed[#disposed + 1] = index
      end,
    }
  end
  local active, spare = slot(2), slot(1)
  local phase = "running"
  local transition = {
    status = function()
      return { phase = phase }
    end,
    stepSourceTick = function()
      phase = "complete"
    end,
    acceptFieldLayers = function()
      error("completion accepts no new field planes", 0)
    end,
    frame = function()
      return { sourcePhase = 1, requiresCurrentFieldLayers = phase == "running" }
    end,
    dispose = function() end,
  }
  local envelope = setmetatable({
    _transition = transition,
    _transitionCapture = active,
    _transitionCaptureSpare = spare,
    _captureFieldLayers = function()
      error("completion captures no new field planes", 0)
    end,
  }, FieldBattlePresentation)

  envelope:_stepTransition()
  Assert.equal(#disposed, 2, "completion releases both distinct slots")
  Assert.isTrue(
    (disposed[1] == 2 and disposed[2] == 1) or (disposed[1] == 1 and disposed[2] == 2),
    "completion releases the published frame and the spare"
  )
  Assert.isNil(envelope._transitionCapture, "completion drops the published capture")
  Assert.isNil(envelope._transitionCaptureSpare, "completion drops the spare slot")
  envelope:_stepTransition()
  envelope:_disposeTransition()
  Assert.equal(#disposed, 2, "repeat observations never redispose either slot")
end

-- The replacement predicate stays read-only and conservative: only a
-- running launch with published planes and a full-viewport replace
-- motion-blur frame without wipe reports a proven cover.
function T.replaces_field_world_reports_only_proven_full_replacement()
  local function envelopeFor(options)
    local transition = nil
    if options.hasTransition then
      transition = {
        status = function()
          return { phase = options.phase or "running" }
        end,
        frame = function()
          return options.frame or {}
        end,
      }
    end
    return setmetatable({
      _transitionFailed = options.failed == true,
      _transition = transition,
      _transitionCapture = options.capture,
    }, FieldBattlePresentation)
  end
  local function liveCapture()
    return { dispose = function() end }
  end
  local function liveBlur()
    return { dispose = function() end }
  end
  local fullReplace = { motionBlur = liveBlur() }
  Assert.isFalse(
    envelopeFor({}):replacesFieldWorld(),
    "no transition never replaces the field world"
  )
  Assert.isFalse(
    envelopeFor({ hasTransition = true, failed = true, capture = liveCapture(), frame = fullReplace })
      :replacesFieldWorld(),
    "a failed launch never replaces the field world"
  )
  Assert.isFalse(
    envelopeFor({ hasTransition = true, phase = "complete", capture = liveCapture(), frame = fullReplace })
      :replacesFieldWorld(),
    "a settled transition never replaces the field world"
  )
  Assert.isFalse(
    envelopeFor({ hasTransition = true, frame = fullReplace }):replacesFieldWorld(),
    "a missing published capture never replaces the field world"
  )
  Assert.isFalse(
    envelopeFor({ hasTransition = true, capture = { _disposed = true, dispose = function() end }, frame = fullReplace })
      :replacesFieldWorld(),
    "a disposed capture never replaces the field world"
  )
  Assert.isFalse(
    envelopeFor({ hasTransition = true, capture = liveCapture(), frame = {} }):replacesFieldWorld(),
    "a frame without motion blur never replaces the field world"
  )
  Assert.isFalse(
    envelopeFor({
      hasTransition = true,
      capture = liveCapture(),
      frame = { motionBlur = { _disposed = true, dispose = function() end } },
    }):replacesFieldWorld(),
    "disposed feedback never replaces the field world"
  )
  Assert.isFalse(
    envelopeFor({
      hasTransition = true,
      capture = liveCapture(),
      frame = { motionBlur = liveBlur(), wipe = { rows = {} } },
    }):replacesFieldWorld(),
    "a wipe frame still exposes the underlying field"
  )
  Assert.isFalse(
    envelopeFor({
      hasTransition = true,
      capture = liveCapture(),
      frame = { motionBlur = liveBlur(), blendAlpha = 8 },
    }):replacesFieldWorld(),
    "a translucent composite still exposes the underlying field"
  )
  Assert.isTrue(
    envelopeFor({ hasTransition = true, capture = liveCapture(), frame = fullReplace }):replacesFieldWorld(),
    "an opaque motion-blur frame provably covers the field world"
  )
  Assert.isTrue(
    envelopeFor({
      hasTransition = true,
      capture = liveCapture(),
      frame = { motionBlur = liveBlur(), blendAlpha = 16 },
    }):replacesFieldWorld(),
    "a fully opaque blend still counts as replacement"
  )
  local queried = envelopeFor({ hasTransition = true, capture = liveCapture(), frame = fullReplace })
  queried:replacesFieldWorld()
  Assert.isTrue(queried._transition ~= nil, "the predicate advances nothing")
  Assert.isTrue(queried._transitionCapture ~= nil, "the predicate releases nothing")
end

return { tests = T }
