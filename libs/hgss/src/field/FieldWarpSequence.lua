-- Warping field-move animation: the player-visible sequence of Teleport,
-- Dig, Escape Rope and Fly around the map warp (src/field/
-- field_move_warp_tasks.c, src/field_warp_state.c). Departure plays the
-- effect sound, zooms the camera out by 0x96000 over 15 ticks, spins the
-- avatar through the source movement scripts (asm/field_move_effects_data.s)
-- and fades to the move's color; arrival fades back in, snaps the camera in
-- and eases it out over 60 ticks while the avatar finishes its spin. Fly
-- waits for the lead mon's cry, presents the cut-in, then fades to white;
-- arrival fades back in from white and runs the landing sequence.
-- State is a plain table so it can ride a serializable plan; behavior is
-- reached only through the injected port (effects, avatar facing, camera
-- zoom, screen fade, cry, cut-in, landing). Pure domain module: no love
-- dependency.
--
-- Fly follows FieldTask_Fly (field_warp_state.c): the cry, then the cut-in
-- (kind 1, the 23-step sFieldMoveCutInFlySteps table, or kind 2 with the
-- follower, the 12-step sFieldMoveCutInFlyWithObjectSteps table), then the
-- warp; arrival runs the 6-step sFlyLandingTaskSteps landing
-- (field_move_warp_tasks.c CallTask_FlyLanding, field_move_cut_in_effects.c
-- Task_FlyLanding, fly_landing_effect.c FlyLandingEffect_Update over
-- sFlyLandingPhases). The banner, sprites, and landing models are
-- presenter-owned waits here: the sequence only orders them around the
-- warp-cover fades it owns, so cancellation clears exactly once. The
-- follower jump/recall and the player spin-movement ahead of the cut-in
-- stay with the avatar/follower owners, as do the Dig rock-debris model
-- and the following-Pokemon Teleport/Dig variants.

local FieldWarpSequence = {}

-- fx32 zoom delta of every departure/arrival zoom (source -0x96000).
FieldWarpSequence.ZOOM_BY_FX32 = -0x96000
-- Source landing zoom (fly_landing_effect.c FlyLandingEffect_Start): the
-- landing dives the camera by FX32_CONST(-120) over 12 ticks, and StartClimb
-- eases it back over 12 ticks.
FieldWarpSequence.LANDING_ZOOM_BY_FX32 = -491520
local LANDING_ZOOM_TICKS = 12
local LANDING_ZOOM_BACK_TICKS = 12
local ZOOM_OUT_TICKS = 15
local ZOOM_SNAP_TICKS = 1
local ZOOM_BACK_TICKS = 60
local DEPARTURE_SPINS = 8
local ARRIVAL_SPINS = 4

local KINDS = {
  teleport = { effect = "SEQ_SE_DP_TELE", start = "spin_start", color = "black" },
  escape_rope = { effect = "SEQ_SE_DP_KAIDAN2", start = "spin_start", color = "white" },
  dig = { effect = "SEQ_SE_DP_KAIDAN2", start = "dig_sink", hole = true, color = "white" },
  fly = { color = "white" },
}

-- Source movement scripts as (kind, direction-or-ticks, count) triples:
-- face commands last one tick, a delay command of n lasts n + 1 ticks.
local SCRIPT_COMMANDS = {
  spin = { "N", "E", "S", "W", "N", "E", "S", "W" },
  dig_hole = { "S", "W", "N", "E", "S", "W", "N", "E" },
  spin_start = {
    "S",
    4,
    "W",
    4,
    "N",
    4,
    "E",
    4,
    "S",
    2,
    "W",
    2,
    "N",
    2,
    "E",
    2,
    "S",
    "W",
    "N",
    "E",
    "S",
    "W",
    "N",
    "E",
  },
  dig_sink = {
    "S",
    4,
    "W",
    4,
    "N",
    4,
    "E",
    4,
    "S",
    2,
    "W",
    2,
    "N",
    2,
    "E",
    2,
  },
  arrival_spin = {
    "S",
    "W",
    "N",
    "E",
    "S",
    "W",
    "N",
    "E",
    "S",
    2,
    "W",
    2,
    "N",
    2,
    "E",
    2,
    "S",
    4,
    "W",
    6,
    "N",
    8,
    "E",
    10,
    "S",
  },
}

local DIRECTIONS = { N = "north", S = "south", W = "west", E = "east" }

-- Expand a script into one facing per tick (a delay holds the last facing).
local function expand(commands)
  local facings = {}
  local current
  for _, command in ipairs(commands) do
    if type(command) == "number" then
      for _ = 1, command do
        facings[#facings + 1] = current
      end
    else
      current = DIRECTIONS[command]
      facings[#facings + 1] = current
    end
  end
  return facings
end

local SCRIPTS = {}
for name, commands in pairs(SCRIPT_COMMANDS) do
  SCRIPTS[name] = expand(commands)
end

local function kindConfig(sequence)
  return assert(KINDS[sequence.kind], "unknown warp sequence kind")
end

local function beginMovement(sequence, name)
  assert(SCRIPTS[name], "unknown warp movement script")
  sequence.movement = { script = name, index = 0 }
end

local function movementFinished(sequence)
  local movement = sequence.movement
  return movement == nil or movement.index >= #SCRIPTS[movement.script]
end

local function stepMovement(sequence, port)
  local movement = sequence.movement
  if movement == nil then
    return
  end
  local facings = SCRIPTS[movement.script]
  if movement.index < #facings then
    movement.index = movement.index + 1
    port:faceAvatar(facings[movement.index])
  end
end

local function startZoom(sequence, port, mode, amount, duration)
  sequence.zoomStarted = true
  port:zoomSet(mode, amount, duration)
end

local function releaseZoom(sequence, port)
  if sequence.zoomStarted then
    sequence.zoomStarted = false
    port:zoomRelease()
  end
end

local function tickEnd(sequence, port)
  stepMovement(sequence, port)
  if sequence.zoomStarted then
    port:zoomStep()
  end
  return "running"
end

-- The color the move fades to and back from.
---@param sequence table<string, unknown>
---@return "black"|"white"
function FieldWarpSequence.departureColor(sequence)
  return kindConfig(sequence).color
end

-- Whether the follower performs the move: next to the player and holding
-- the used party slot (Task_FieldDig/Task_FieldTeleport). The follower path
-- cries and runs its own flash and spin with no cut-in; the solo path shows
-- the cut-in with no cry. Escape Rope never takes either path.
---@param kind "teleport"|"dig"|"escape_rope"|"fly"
---@param opts { withFollowMon: boolean? }?
---@return table<string, unknown> sequence plain-data state
function FieldWarpSequence.new(kind, opts)
  assert(KINDS[kind], "unknown warp sequence kind " .. tostring(kind))
  assert(opts == nil or type(opts) == "table", "warp sequence options are a record")
  return {
    kind = kind,
    phase = "departure",
    step = "start",
    spinCount = 0,
    movement = nil,
    zoomStarted = false,
    fadeStarted = false,
    cutinStarted = false,
    landingStarted = false,
    zoomBack = false,
    withFollowMon = opts ~= nil and opts.withFollowMon == true,
  }
end

local function stepFlyDeparture(sequence, port)
  if sequence.step == "start" then
    port:startCry()
    sequence.step = "cry"
    return "running"
  end
  if sequence.step == "cry" then
    if not port:cryDone() then
      return "running"
    end
    port:startCutIn()
    sequence.cutinStarted = true
    sequence.step = "cutin"
    return "running"
  end
  if sequence.step == "cutin" then
    if not port:cutInDone() then
      return "running"
    end
    sequence.cutinStarted = false
    port:fadeStart("out", "white")
    sequence.fadeStarted = true
    sequence.step = "fade"
    return "running"
  end
  if not port:fadeDone() then
    return "running"
  end
  sequence.phase = "warp"
  return "warp"
end

-- Dig and Teleport open with the move cut-in when the follower is not
-- performing the move, or with the lead cry when it is (sDigSteps and
-- sTeleportSteps ShowCutIn/WaitCutIn versus the follower cry and steps).
-- Escape Rope takes neither path. The follower jump and mood, the follower
-- flash and spin, the rock debris, and the post-cut-in recall stay with
-- the follower and effect owners: this sequence only orders the cry and
-- cut-in waits the warp-cover fades own around the shared spin.
local function startGroundedSpin(sequence, port, config)
  startZoom(sequence, port, "by", FieldWarpSequence.ZOOM_BY_FX32, ZOOM_OUT_TICKS)
  beginMovement(sequence, config.start)
  port:playEffect(config.effect)
  sequence.step = config.hole and "hole" or "spin"
  return tickEnd(sequence, port)
end

-- Advance the departure one source tick. "warp" once the cover is complete
-- and the avatar/camera are released for the map change.
---@param sequence table<string, unknown>
---@param port table<string, unknown>
---@return "running"|"warp"
function FieldWarpSequence.stepDeparture(sequence, port)
  assert(sequence.phase == "departure", "departure steps only run in the departure phase")
  local config = kindConfig(sequence)
  if sequence.kind == "fly" then
    return stepFlyDeparture(sequence, port)
  end
  if sequence.step == "start" then
    if sequence.kind == "dig" or sequence.kind == "teleport" then
      if sequence.withFollowMon then
        port:startCry()
        sequence.step = "cry"
      else
        port:startCutIn()
        sequence.cutinStarted = true
        sequence.step = "cutin"
      end
      return "running"
    end
    return startGroundedSpin(sequence, port, config)
  end
  if sequence.step == "cry" then
    if not port:cryDone() then
      return "running"
    end
    return startGroundedSpin(sequence, port, config)
  end
  if sequence.step == "cutin" then
    if not port:cutInDone() then
      return "running"
    end
    sequence.cutinStarted = false
    return startGroundedSpin(sequence, port, config)
  end
  if sequence.step == "hole" then
    if movementFinished(sequence) then
      beginMovement(sequence, "dig_hole")
      sequence.step = "spin"
    end
    return tickEnd(sequence, port)
  end
  if sequence.step == "spin" then
    if movementFinished(sequence) then
      beginMovement(sequence, "spin")
      sequence.spinCount = sequence.spinCount + 1
      if sequence.spinCount >= DEPARTURE_SPINS then
        port:fadeStart("out", config.color)
        sequence.fadeStarted = true
        sequence.step = "fade"
      end
    end
    return tickEnd(sequence, port)
  end
  assert(sequence.step == "fade", "unknown departure step")
  if movementFinished(sequence) then
    beginMovement(sequence, "spin")
  end
  if not port:fadeDone() then
    return tickEnd(sequence, port)
  end
  sequence.movement = nil
  releaseZoom(sequence, port)
  sequence.phase = "warp"
  return "warp"
end

-- Advance the arrival one source tick; "done" once the screen, avatar and
-- camera have all settled.
---@param sequence table<string, unknown>
---@param port table<string, unknown>
---@return "running"|"done"
function FieldWarpSequence.stepArrival(sequence, port)
  local config = kindConfig(sequence)
  if sequence.phase == "warp" then
    sequence.phase = "arrival"
    sequence.step = "start"
    sequence.spinCount = 0
  end
  assert(sequence.phase == "arrival", "arrival steps only run after the warp")
  if sequence.step == "start" then
    port:fadeStart("in", config.color)
    sequence.fadeStarted = true
    if sequence.kind == "fly" then
      sequence.step = "fly_fade"
      return "running"
    end
    startZoom(sequence, port, "by", FieldWarpSequence.ZOOM_BY_FX32, ZOOM_SNAP_TICKS)
    beginMovement(sequence, "spin")
    sequence.step = "fade"
    return tickEnd(sequence, port)
  end
  if sequence.step == "fly_fade" then
    if not port:fadeDone() then
      return "running"
    end
    sequence.fadeStarted = false
    startZoom(sequence, port, "by", FieldWarpSequence.LANDING_ZOOM_BY_FX32, LANDING_ZOOM_TICKS)
    port:startLanding()
    sequence.landingStarted = true
    sequence.step = "landing"
    return "running"
  end
  if sequence.step == "landing" then
    if not sequence.zoomBack and port:zoomDone() and port:landingClimbed() then
      startZoom(sequence, port, "back", 0, LANDING_ZOOM_BACK_TICKS)
      sequence.zoomBack = true
    end
    port:zoomStep()
    if port:landingDone() and port:zoomDone() then
      sequence.landingStarted = false
      sequence.zoomBack = false
      releaseZoom(sequence, port)
      return "done"
    end
    return "running"
  end
  if sequence.step == "fade" then
    if movementFinished(sequence) then
      beginMovement(sequence, "spin")
    end
    if not port:fadeDone() then
      return tickEnd(sequence, port)
    end
    sequence.fadeStarted = false
    startZoom(sequence, port, "back", 0, ZOOM_BACK_TICKS)
    sequence.step = "spin"
  end
  if sequence.step == "spin" then
    if movementFinished(sequence) then
      sequence.spinCount = sequence.spinCount + 1
      if sequence.spinCount < ARRIVAL_SPINS then
        beginMovement(sequence, "spin")
      else
        beginMovement(sequence, "arrival_spin")
        sequence.step = "finish"
      end
    end
    return tickEnd(sequence, port)
  end
  assert(sequence.step == "finish", "unknown arrival step")
  if not movementFinished(sequence) or not port:zoomDone() then
    return tickEnd(sequence, port)
  end
  sequence.movement = nil
  releaseZoom(sequence, port)
  return "done"
end

-- Release the zoom and the screen cover a cancelled sequence still holds,
-- exactly once. The cover stays held from the departure fade until the
-- arrival fade-in completes, so a failed warp never strands a covered screen.
---@param sequence table<string, unknown>
---@param port table<string, unknown>
function FieldWarpSequence.cancel(sequence, port)
  sequence.movement = nil
  if sequence.cutinStarted then
    sequence.cutinStarted = false
    port:cancelCutIn()
  end
  if sequence.landingStarted then
    sequence.landingStarted = false
    sequence.zoomBack = false
    port:cancelLanding()
  end
  releaseZoom(sequence, port)
  if sequence.fadeStarted then
    sequence.fadeStarted = false
    port:fadeClear()
  end
end

return FieldWarpSequence
