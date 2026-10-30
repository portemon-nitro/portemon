-- FieldWarpSequence: the Teleport/Dig/Escape Rope/Fly field animations
-- (field_move_warp_tasks.c, field_warp_state.c): effect sound, camera zoom,
-- the spin movement scripts, the colored fade, then the warp, and the
-- mirrored arrival.

local Assert = require("tests.support.Assert")
local FieldWarpSequence = require("libs.hgss.src.field.FieldWarpSequence")

local T = {}

local function newPort()
  local port = {
    events = {},
    faces = {},
    fadeIsDone = false,
    zoomIsDone = false,
    cryIsDone = false,
    cutinIsDone = false,
    landingHasClimbed = false,
    landingIsDone = false,
  }
  local function log(event)
    port.events[#port.events + 1] = event
  end
  function port:playEffect(sequence)
    log("se:" .. sequence)
  end
  function port:faceAvatar(direction)
    self.faces[#self.faces + 1] = direction
  end
  function port:zoomSet(mode, amount, duration)
    self.zoomIsDone = false
    log(string.format("zoom:%s:%d:%d", mode, amount, duration))
  end
  function port:zoomStep() end
  function port:zoomDone()
    return self.zoomIsDone
  end
  function port:zoomRelease()
    log("zoom_release")
  end
  function port:fadeStart(direction, color)
    self.fadeIsDone = false
    log("fade:" .. direction .. ":" .. color)
  end
  function port:fadeDone()
    return self.fadeIsDone
  end
  function port:fadeClear()
    log("fade_clear")
  end
  function port:startCry()
    log("cry")
  end
  function port:cryDone()
    return self.cryIsDone
  end
  function port:startCutIn()
    log("cutin_start")
  end
  function port:cutInDone()
    return self.cutinIsDone
  end
  function port:cancelCutIn()
    log("cutin_cancel")
  end
  function port:startLanding()
    log("landing_start")
  end
  function port:landingClimbed()
    return self.landingHasClimbed
  end
  function port:landingDone()
    return self.landingIsDone
  end
  function port:cancelLanding()
    log("landing_cancel")
  end
  return port
end

local function run(sequence, port, step, limit)
  for tick = 1, limit do
    local result = step(sequence, port)
    if result ~= "running" then
      return result, tick
    end
  end
  error("sequence never settled", 0)
end

local indexOf

local function departToWarp(sequence, port)
  local result
  for _ = 1, 300 do
    if indexOf(port, "fade:out:" .. FieldWarpSequence.departureColor(sequence)) then
      port.fadeIsDone = true
    end
    port.cryIsDone = true
    result = FieldWarpSequence.stepDeparture(sequence, port)
    if result == "warp" then
      port.events = {}
      port.faces = {}
      port.fadeIsDone = false
      return
    end
  end
  error("departure never reached the warp", 0)
end

function indexOf(port, event)
  for index, value in ipairs(port.events) do
    if value == event then
      return index
    end
  end
  return nil
end

function T.teleport_plays_the_effect_zooms_spins_eight_times_and_fades_to_black()
  local sequence = FieldWarpSequence.new("teleport")
  local port = newPort()
  Assert.equal(FieldWarpSequence.stepDeparture(sequence, port), "running")
  Assert.deepEqual(
    port.events,
    { "zoom:by:-614400:15", "se:SEQ_SE_DP_TELE" },
    "the first tick starts the 15-tick zoom, then plays the source effect"
  )
  -- 40-tick spin-start script, then seven 8-tick spins; the eighth spin
  -- begins on the next evaluation and starts the black fade.
  for _ = 2, 96 do
    Assert.equal(FieldWarpSequence.stepDeparture(sequence, port), "running")
    Assert.isNil(indexOf(port, "fade:out:black"), "no fade before the eighth spin")
  end
  Assert.equal(FieldWarpSequence.stepDeparture(sequence, port), "running")
  Assert.notNil(indexOf(port, "fade:out:black"), "the eighth spin begins the fade")
  Assert.equal(port.faces[1], "south", "the start script opens facing south")
  for _ = 1, 20 do
    Assert.equal(FieldWarpSequence.stepDeparture(sequence, port), "running")
  end
  port.fadeIsDone = true
  Assert.equal(FieldWarpSequence.stepDeparture(sequence, port), "warp", "a finished fade releases the warp")
  Assert.equal(port.events[#port.events], "zoom_release", "the departure zoom ends before the warp")
end

function T.dig_sinks_before_the_hole_and_fades_to_white()
  local sequence = FieldWarpSequence.new("dig")
  local port = newPort()
  FieldWarpSequence.stepDeparture(sequence, port)
  Assert.deepEqual(port.events, { "zoom:by:-614400:15", "se:SEQ_SE_DP_KAIDAN2" })
  local _, ticks = run(sequence, port, function(seq, p)
    if indexOf(p, "fade:out:white") then
      p.fadeIsDone = true
    end
    return FieldWarpSequence.stepDeparture(seq, p)
  end, 200)
  Assert.equal(ticks + 1, 98, "32-tick sink, 8-tick hole, then eight spins precede the fade-out completing")
  Assert.notNil(indexOf(port, "fade:out:white"), "dig leaves through white")
end

function T.escape_rope_uses_the_dig_sound_with_the_teleport_spin()
  local sequence = FieldWarpSequence.new("escape_rope")
  local port = newPort()
  FieldWarpSequence.stepDeparture(sequence, port)
  Assert.equal(port.events[2], "se:SEQ_SE_DP_KAIDAN2")
  run(sequence, port, function(seq, p)
    if indexOf(p, "fade:out:white") then
      p.fadeIsDone = true
    end
    return FieldWarpSequence.stepDeparture(seq, p)
  end, 200)
  Assert.notNil(indexOf(port, "fade:out:white"))
end

function T.arrival_fades_in_zooms_back_and_finishes_after_the_final_spin()
  local sequence = FieldWarpSequence.new("teleport")
  local port = newPort()
  departToWarp(sequence, port)
  Assert.equal(FieldWarpSequence.stepArrival(sequence, port), "running")
  Assert.deepEqual(
    port.events,
    { "fade:in:black", "zoom:by:-614400:1" },
    "arrival fades in from the departure color and snaps the camera in"
  )
  port.fadeIsDone = true
  FieldWarpSequence.stepArrival(sequence, port)
  Assert.equal(port.events[#port.events], "zoom:back:0:60", "the zoom returns once the fade is in")
  for _ = 1, 400 do
    if FieldWarpSequence.stepArrival(sequence, port) == "done" then
      error("arrival must wait for the camera zoom", 0)
    end
    if port.events[#port.events] == "zoom:back:0:60" and #port.faces > 80 then
      break
    end
  end
  port.zoomIsDone = true
  local result = run(sequence, port, FieldWarpSequence.stepArrival, 100)
  Assert.equal(result, "done")
  Assert.equal(port.events[#port.events], "zoom_release")
  Assert.equal(port.faces[#port.faces], "south", "the arrival spin ends facing south")
end

function T.a_failed_warp_still_clears_the_departure_cover()
  local sequence = FieldWarpSequence.new("dig")
  local port = newPort()
  departToWarp(sequence, port)
  FieldWarpSequence.cancel(sequence, port)
  FieldWarpSequence.cancel(sequence, port)
  local clears = 0
  for _, event in ipairs(port.events) do
    if event == "fade_clear" then
      clears = clears + 1
    end
  end
  Assert.equal(clears, 1, "the cover held through the warp clears once when the warp fails")
end

function T.fly_departure_presents_the_cutin_between_the_cry_and_the_white_fade()
  local sequence = FieldWarpSequence.new("fly")
  local port = newPort()
  Assert.equal(FieldWarpSequence.stepDeparture(sequence, port), "running")
  Assert.deepEqual(port.events, { "cry" })
  Assert.equal(FieldWarpSequence.stepDeparture(sequence, port), "running")
  Assert.isNil(indexOf(port, "fade:out:white"), "the fade waits for the cry")
  Assert.isNil(indexOf(port, "cutin_start"), "the cut-in waits for the cry")
  port.cryIsDone = true
  Assert.equal(FieldWarpSequence.stepDeparture(sequence, port), "running")
  Assert.equal(port.events[#port.events], "cutin_start", "the cry hands off to the cut-in")
  Assert.equal(FieldWarpSequence.stepDeparture(sequence, port), "running")
  Assert.isNil(indexOf(port, "fade:out:white"), "the cover waits for the cut-in")
  port.cutinIsDone = true
  Assert.equal(FieldWarpSequence.stepDeparture(sequence, port), "running")
  Assert.equal(port.events[#port.events], "fade:out:white", "the finished cut-in fades to white")
  port.fadeIsDone = true
  Assert.equal(FieldWarpSequence.stepDeparture(sequence, port), "warp")
end

function T.fly_arrival_runs_the_landing_after_the_white_fade()
  local sequence = FieldWarpSequence.new("fly")
  local port = newPort()
  port.cryIsDone = true
  port.cutinIsDone = true
  for _ = 1, 10 do
    if FieldWarpSequence.stepDeparture(sequence, port) == "warp" then
      break
    end
    port.fadeIsDone = true
  end
  port.fadeIsDone = false
  port.events = {}
  Assert.equal(FieldWarpSequence.stepArrival(sequence, port), "running")
  Assert.equal(port.events[#port.events], "fade:in:white")
  Assert.isNil(indexOf(port, "landing_start"), "the landing waits for the fade")
  port.fadeIsDone = true
  Assert.equal(FieldWarpSequence.stepArrival(sequence, port), "running")
  Assert.equal(port.events[#port.events], "landing_start", "the faded-in screen hands off to the landing")
  Assert.deepEqual(
    port.events[#port.events - 1],
    "zoom:by:-491520:12",
    "the landing dives the camera over twelve ticks"
  )
  port.zoomIsDone = true
  port.landingHasClimbed = true
  Assert.equal(FieldWarpSequence.stepArrival(sequence, port), "running")
  Assert.equal(port.events[#port.events], "zoom:back:0:12", "the climb eases the camera back over twelve ticks")
  port.zoomIsDone = true
  port.landingIsDone = true
  Assert.equal(FieldWarpSequence.stepArrival(sequence, port), "done")
  Assert.equal(port.events[#port.events], "zoom_release", "the finished landing releases the zoom")
end

function T.fly_arrival_holds_the_landing_until_the_climb_zoom_and_effect_settle()
  local sequence = FieldWarpSequence.new("fly")
  local port = newPort()
  port.cryIsDone = true
  port.cutinIsDone = true
  for _ = 1, 10 do
    if FieldWarpSequence.stepDeparture(sequence, port) == "warp" then
      break
    end
    port.fadeIsDone = true
  end
  port.fadeIsDone = false
  port.events = {}
  FieldWarpSequence.stepArrival(sequence, port)
  port.fadeIsDone = true
  FieldWarpSequence.stepArrival(sequence, port)
  port.zoomIsDone = false
  port.landingIsDone = true
  Assert.equal(
    FieldWarpSequence.stepArrival(sequence, port),
    "running",
    "an unfinished landing zoom holds the arrival"
  )
  port.zoomIsDone = true
  port.landingHasClimbed = true
  Assert.equal(FieldWarpSequence.stepArrival(sequence, port), "running")
  port.zoomIsDone = true
  port.landingIsDone = true
  Assert.equal(FieldWarpSequence.stepArrival(sequence, port), "done")
end

function T.cancel_during_the_fly_cutin_releases_it_exactly_once()
  local sequence = FieldWarpSequence.new("fly")
  local port = newPort()
  FieldWarpSequence.stepDeparture(sequence, port)
  port.cryIsDone = true
  FieldWarpSequence.stepDeparture(sequence, port)
  FieldWarpSequence.cancel(sequence, port)
  FieldWarpSequence.cancel(sequence, port)
  local cancels, clears = 0, 0
  for _, event in ipairs(port.events) do
    if event == "cutin_cancel" then
      cancels = cancels + 1
    elseif event == "fade_clear" then
      clears = clears + 1
    end
  end
  Assert.equal(cancels, 1, "cancellation releases the in-flight cut-in once")
  Assert.equal(clears, 0, "a fade that never started clears nothing")
end

function T.cancel_during_the_fly_landing_releases_it_and_the_zoom_exactly_once()
  local sequence = FieldWarpSequence.new("fly")
  local port = newPort()
  port.cryIsDone = true
  port.cutinIsDone = true
  for _ = 1, 10 do
    if FieldWarpSequence.stepDeparture(sequence, port) == "warp" then
      break
    end
    port.fadeIsDone = true
  end
  port.fadeIsDone = false
  port.events = {}
  FieldWarpSequence.stepArrival(sequence, port)
  port.fadeIsDone = true
  FieldWarpSequence.stepArrival(sequence, port)
  FieldWarpSequence.cancel(sequence, port)
  FieldWarpSequence.cancel(sequence, port)
  local cancels, releases = 0, 0
  for _, event in ipairs(port.events) do
    if event == "landing_cancel" then
      cancels = cancels + 1
    elseif event == "zoom_release" then
      releases = releases + 1
    end
  end
  Assert.equal(cancels, 1, "cancellation releases the in-flight landing once")
  Assert.equal(releases, 1, "cancellation releases the landing zoom once")
end

function T.grounded_warps_never_touch_the_fly_cutin_or_landing()
  for _, kind in ipairs({ "teleport", "dig", "escape_rope" }) do
    local sequence = FieldWarpSequence.new(kind)
    local port = newPort()
    port.cryIsDone = true
    for _ = 1, 300 do
      if FieldWarpSequence.stepDeparture(sequence, port) == "warp" then
        break
      end
      port.fadeIsDone = true
    end
    port.fadeIsDone = false
    FieldWarpSequence.stepArrival(sequence, port)
    for _, event in ipairs(port.events) do
      Assert.isTrue(
        event ~= "cutin_start" and event ~= "landing_start",
        kind .. " leaves the fly presentation untouched: " .. event
      )
    end
  end
end

function T.cancel_releases_the_zoom_and_fade_once()
  local sequence = FieldWarpSequence.new("teleport")
  local port = newPort()
  FieldWarpSequence.stepDeparture(sequence, port)
  port.fadeIsDone = false
  for _ = 1, 96 do
    FieldWarpSequence.stepDeparture(sequence, port)
  end
  FieldWarpSequence.stepDeparture(sequence, port)
  FieldWarpSequence.cancel(sequence, port)
  FieldWarpSequence.cancel(sequence, port)
  local releases, clears = 0, 0
  for _, event in ipairs(port.events) do
    if event == "zoom_release" then
      releases = releases + 1
    elseif event == "fade_clear" then
      clears = clears + 1
    end
  end
  Assert.equal(releases, 1, "cancellation releases the zoom exactly once")
  Assert.equal(clears, 1, "cancellation clears the started fade exactly once")
end

return { tests = T }
