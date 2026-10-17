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

return { tests = T }
