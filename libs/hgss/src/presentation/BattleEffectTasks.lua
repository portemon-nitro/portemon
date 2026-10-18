-- Battle-private effect task factory for normalized battle animations.
-- Native task bodies live in src/battle/battle_anim_effects.c and drive
-- sys tasks through BattleAnimSystem_CreateTaskOfKind (kind 1 counts
-- taskCount, kind 2 counts soundTaskCount); raw visual work uses
-- SysTask_CreateOnMainQueue directly and stays outside both counters.
-- The player schedules work through this factory as
-- Factory.create(kind, args, context, services); unknown kinds fail here
-- instead of returning a timer stand-in. Voice monitoring, sound actions
-- with real voice completion, background blend transitions, battler
-- particle continuations, picture reveals, and one source-parameterized
-- visual body per remaining nonparticle task kind have bodies in this
-- lane; only kinds outside the emitted producer vocabulary still fail
-- closed. Visual, blend, and picture bodies mutate only scene state
-- (owned picture patches, scroll sweeps, palette overlays) and publish
-- no drawable picture of their own: only particle tasks draw, and only
-- from staged dependency textures. Completion boundaries come only from
-- compiled source timing operands; well-formed spawns without one
-- retire synchronously as validated markers, and malformed shapes fail
-- closed. No fixed budget stands in for source timing anywhere.
-- BattleEffectTasks.supportsKind is the narrow admission view over this
-- same dispatch.

---@class BattleEffectTasks
local BattleEffectTasks = {}

-- Player-support task kind owned by the animation player contract: it
-- completes exactly when its awaited voice finishes, so the player's
-- sound wait retires on a real audio condition rather than a duration.
-- The spelling matches BattleAnimationPlayer.VOICE_TASK_KIND, which owns
-- the contract string as the sole constructor-side consumer.
BattleEffectTasks.VOICE_MONITOR_KIND = "voice-completion-monitor"

-- Normalized task kinds with production bodies in this lane. They repeat
-- the compiler-selected spellings (see
-- romdump.src.config.BattleAnimationSources visual task and particle
-- vocabularies) so the factory, the player, and the tests name one
-- spelling per behavior.
BattleEffectTasks.BLEND_TRANSITION_KIND = "battle-background-blend-transition"
BattleEffectTasks.PARTICLE_CONTINUATION_KIND = "battler-effect-continuation"
BattleEffectTasks.PICTURE_ANIMATION_KIND = "pokemon-picture-animation"

local VALID_TASK_STATES = {
  pending = true,
  running = true,
  complete = true,
  cancelled = true,
}

-- Native battler effect slots behind particle emitter positions, in the
-- source slot order (solo battlers first, then side slots). The runtime
-- carries only this normalized vocabulary and never imports the producer
-- tables; the factory validates membership here so an unknown emitter
-- fails closed with its kind identity.
local EMITTER_POSITIONS = {
  ["solo-player"] = true,
  ["solo-enemy"] = true,
  ["player-side-slot-1"] = true,
  ["enemy-side-slot-1"] = true,
  ["player-side-slot-2"] = true,
  ["enemy-side-slot-2"] = true,
}

-- Sound actions retire on their staged voice; the escape mirrors the
-- player's own voice escape so a voice that never reports cannot park
-- the occurrence past the native sound-wait horizon.
local SOUND_ESCAPE_TICKS = 90

-- Particle emitter centers in explicit scene coordinates, one per native
-- effect slot. Ally emissions stage over the player side and enemy
-- emissions over the foe side instead of collapsing into one rectangle.
local EMITTER_CENTERS = {
  ["solo-player"] = { x = 64, y = 80 },
  ["solo-enemy"] = { x = 192, y = 80 },
  ["player-side-slot-1"] = { x = 48, y = 96 },
  ["enemy-side-slot-1"] = { x = 208, y = 96 },
  ["player-side-slot-2"] = { x = 80, y = 64 },
  ["enemy-side-slot-2"] = { x = 176, y = 64 },
}

---@class BattleVoiceMonitor
---@field _voice string awaited voice key staged by one occurrence
---@field _audio table<string, unknown> narrow audio collaborator behind isFinished
---@field _state string pending, running, complete, or cancelled
---@field _cancelReason string? last cancellation reason under diagnosis
---@field _disposed boolean release has run
local BattleVoiceMonitor = {}
BattleVoiceMonitor.__index = BattleVoiceMonitor

---@param voice string awaited voice key staged by the waiting occurrence
---@param services table<string, unknown> scene, audio, and resource collaborators
---@return BattleVoiceMonitor runnable voice monitor
local function newVoiceMonitor(voice, services)
  assert(type(voice) == "string" and voice ~= "", "voice monitors await a named voice")
  assert(type(services) == "table", "voice monitors read their audio collaborator from services")
  local audio = services.audio --[[@as table<string, unknown>]]
  assert(type(audio) == "table", "voice monitors require their audio collaborator")
  assert(type(audio.isFinished) == "function", "voice monitors require an isFinished audio query")
  return setmetatable({
    _voice = voice,
    _audio = audio,
    _state = "pending",
    _cancelReason = nil,
    _disposed = false,
  }, BattleVoiceMonitor)
end

-- Advances one source tick: completion is the awaited voice finishing,
-- never an elapsed duration. Audio failures propagate so the player can
-- fail the owning occurrence with instruction provenance.
---@param self BattleVoiceMonitor
---@param tick table<string, unknown>? source tick under advancement
function BattleVoiceMonitor:stepSourceTick(tick)
  local _ = tick
  if self._disposed or self._state == "complete" or self._state == "cancelled" then
    return
  end
  self._state = "running"
  local audio = self._audio --[[@as table<string, fun(string): boolean>]]
  if audio.isFinished(self._voice) then
    self._state = "complete"
  end
end

-- Reports the monitor run state for the player's retirement accounting.
-- States are the strings pending, running, complete, and cancelled.
---@param self BattleVoiceMonitor
---@return string
function BattleVoiceMonitor:status()
  assert(VALID_TASK_STATES[self._state] == true, "voice monitors report a known run state")
  return self._state
end

-- Cancels the monitor; completion and cancellation stay separate, so a
-- completed monitor keeps its completion.
---@param self BattleVoiceMonitor
---@param reason string cancellation cause under diagnosis
function BattleVoiceMonitor:cancel(reason)
  if self._state == "complete" then
    return
  end
  self._state = "cancelled"
  self._cancelReason = reason
end

-- Releases the monitor exactly once; the monitor holds no lease, voice,
-- or scene mutation of its own.
---@param self BattleVoiceMonitor
function BattleVoiceMonitor:dispose()
  self._disposed = true
end

---@class BattleEffectLeaseRecord
---@field holder table<string, unknown> collaborator behind resolve and release
---@field lease unknown live lease behind exactly-once release
---@field released boolean release has run for this record

---@param services table<string, unknown>? scene, audio, and resource collaborators
---@return table<string, unknown>? holder collaborator behind resolve and release
local function holderFor(services)
  if type(services) ~= "table" then
    return nil
  end
  local nested = services.resources
  if type(nested) == "table" and type(nested.resolve) == "function" and type(nested.release) == "function" then
    return nested
  end
  if type(services.resolve) == "function" and type(services.release) == "function" then
    return services
  end
  return nil
end

-- Releases every staged lease once, then releases the failed acquisition
-- attempt itself. The failing resolve records its attempt in the
-- occurrence journal, so the rollback releases that attempt too: partial
-- acquisition never leaks an unbalanced journal.
---@param staged table<integer, BattleEffectLeaseRecord> leases acquired so far
---@param holder table<string, unknown> collaborator behind resolve and release
---@param key string failed resource key under rollback
local function rollbackStaged(staged, holder, key)
  for _, record in ipairs(staged) do
    if not record.released then
      record.released = true
      holder.release(record.lease)
    end
  end
  holder.release(key)
end

-- Stages one occurrence lease, rolling back every attempt on failure so
-- the construction error carries the kind, the key, and the native cause.
---@param kind string task kind under construction
---@param key string resource key under staging
---@param services table<string, unknown> scene, audio, and resource collaborators
---@param staged table<integer, BattleEffectLeaseRecord> leases acquired so far
local function stageLease(kind, key, services, staged)
  local holder = holderFor(services)
  if holder == nil then
    error(
      "BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " stages no resource without a resolve and release collaborator",
      0
    )
  end
  local ok, lease = pcall(holder.resolve, key)
  if not ok then
    rollbackStaged(staged, holder, key)
    error("BATTLE_EFFECT_TASK_RESOURCE: kind " .. kind .. " requires resource " .. key .. ": " .. tostring(lease), 0)
  end
  staged[#staged + 1] = { holder = holder, lease = lease, released = false }
end

-- Releases every staged lease exactly once. Staged records clear after
-- release so repeated teardown stays silent.
---@param staged table<integer, BattleEffectLeaseRecord> leases under release
local function releaseStaged(staged)
  for _, record in ipairs(staged) do
    if not record.released then
      record.released = true
      record.holder.release(record.lease)
    end
  end
end

-- Source operand helpers shared by the parameterized bodies. Every
-- helper reads only compiled producer operands; nothing here consults
-- combat mechanics, the host wallclock, or ROM tables.
---@param value unknown candidate tick count under validation
---@return boolean positive true for a usable positive integer tick count
local function isPositiveInt(value)
  return type(value) == "number" and value % 1 == 0 and value >= 1
end

-- Clips a native blend coefficient into its register range instead of
-- rejecting source extremes: the hardware saturates.
---@param value number raw blend coefficient under clipping
---@return integer saturated coefficient in 0..16
local function clipBlendCoefficient(value)
  local floored = math.floor(value)
  if floored < 0 then
    return 0
  end
  if floored > 16 then
    return 16
  end
  return floored
end

-- Wraps a signed native picture offset into the unsigned byte the
-- visible crop field carries, preserving native quantization.
---@param value number signed native pixel offset under wrapping
---@return integer wrapped offset byte in 0..255
local function wrapPictureByte(value)
  return (math.floor(value) % 256 + 256) % 256
end

---@param value number signed native pixel offset under clamping
---@return integer clamped offset in -32768..32767
local function clampPictureOffset(value)
  local floored = math.floor(value)
  if floored < -32768 then
    return -32768
  end
  if floored > 32767 then
    return 32767
  end
  return floored
end

---@param value number native rotation angle index under clamping
---@return integer clamped angle index in 0..65535
local function clampRotationAngle(value)
  local floored = math.floor(value)
  if floored < 0 then
    return 0
  end
  if floored > 65535 then
    return 65535
  end
  return floored
end

---@param value number native RGB555 color under clamping
---@return integer clamped color in 0..32767
local function clampPaletteColor(value)
  local floored = math.floor(value)
  if floored < 0 then
    return 0
  end
  if floored > 32767 then
    return 32767
  end
  return floored
end

-- Resolves the source-tick boundary from compiled timing operands.
-- Explicit durations win, then two-phase sums, then per-step products,
-- then approach/settle sums and single-tick fields. Well-formed spawns
-- whose instruction carries no compiled timing operand resolve to no
-- boundary: the caller retires those synchronously instead of
-- inventing a fixed budget. Completion times come only from the source
-- parameters the producer emitted, never from a fixed budget.
---@param parameters table<string, unknown> compiled task parameters
---@return integer? source ticks behind completion, absent for timing-less spawns
local function visualDuration(parameters)
  if isPositiveInt(parameters.durationTicks) then
    return parameters.durationTicks
  end
  local first = isPositiveInt(parameters.firstDurationTicks) and parameters.firstDurationTicks or 0
  local second = isPositiveInt(parameters.returnDurationTicks) and parameters.returnDurationTicks or 0
  if isPositiveInt(parameters.secondDurationTicks) then
    second = second + parameters.secondDurationTicks
  end
  if first > 0 or second > 0 then
    local delay = isPositiveInt(parameters.phaseDelayTicks) and parameters.phaseDelayTicks or 0
    return first + second + delay
  end
  local perStep, count = nil, nil
  if isPositiveInt(parameters.ticksPerStep) and isPositiveInt(parameters.steps) then
    perStep, count = parameters.ticksPerStep, parameters.steps
  elseif isPositiveInt(parameters.framesPerStep) and isPositiveInt(parameters.repeatCount) then
    perStep, count = parameters.framesPerStep, parameters.repeatCount
  elseif isPositiveInt(parameters.ticksPerDirection) and isPositiveInt(parameters.directionChanges) then
    perStep, count = parameters.ticksPerDirection, parameters.directionChanges
  elseif isPositiveInt(parameters.toggleCount) and isPositiveInt(parameters.intervalTicks) then
    perStep, count = parameters.toggleCount, parameters.intervalTicks
  end
  if perStep ~= nil and count ~= nil then
    return perStep * count
  end
  local approach = isPositiveInt(parameters.approachTicks) and parameters.approachTicks or 0
  local settle = isPositiveInt(parameters.settleTicks) and parameters.settleTicks or 0
  if approach > 0 or settle > 0 then
    return approach + settle
  end
  if isPositiveInt(parameters.frameTicks) then
    return parameters.frameTicks
  end
  if isPositiveInt(parameters.positionTransitionTicks) then
    return parameters.positionTransitionTicks
  end
  if
    type(parameters.startCoefficient) == "number"
    and type(parameters.endCoefficient) == "number"
    and type(parameters.wait) == "number"
  then
    local travel =
      math.abs(clipBlendCoefficient(parameters.endCoefficient) - clipBlendCoefficient(parameters.startCoefficient))
    return math.max(1, travel * math.max(1, math.floor(parameters.wait)))
  end
  return nil
end

-- Semantic picture targets resolving to the occurrence attacker side.
local ATTACKER_PICTURE_NAMES = {
  attacker = true,
  ["active-battler"] = true,
  ["active-battler-pair-when-enabled"] = true,
  ["all-battler-positions"] = true,
  ["attacker-related-position-when-paired"] = true,
}

-- Semantic picture targets resolving to the first occurrence target.
local TARGET_PICTURE_NAMES = {
  target = true,
  ["opposing-battler"] = true,
  ["opposing-battler-pair-when-enabled"] = true,
  ["other-battler-positions"] = true,
  ["target-related-position-when-paired"] = true,
}

-- Resolves the activation a picture body owns: the explicit spawning
-- argument first, then the semantic battler or picture target through
-- the detached occurrence topology. Tasks without a resolvable target
-- own no picture patch and only hold their transient effect record.
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@return table<string, unknown>? combatant and activation pair behind the owned picture
local function plannedActivation(args, context)
  local activation = args.activation
  if type(activation) == "table" then
    return { combatant = activation.combatant, activation = activation.activation }
  end
  local topology = type(context) == "table" and context.topology or nil
  if type(topology) ~= "table" then
    return nil
  end
  local name = args.battlerTarget
  local parameters = args.parameters
  if type(name) ~= "string" and type(parameters) == "table" and type(parameters.pictureTarget) == "string" then
    name = parameters.pictureTarget
  end
  if type(name) ~= "string" then
    return nil
  end
  if ATTACKER_PICTURE_NAMES[name] == true then
    local attacker = topology.attacker --[[@as table<string, unknown>?]]
    if type(attacker) == "table" and type(attacker.combatant) == "number" then
      return { combatant = attacker.combatant, activation = attacker.activation }
    end
    return nil
  end
  if TARGET_PICTURE_NAMES[name] == true then
    local targets = topology.targets --[[@as table<integer, table<string, unknown>>?]]
    if type(targets) == "table" and type(targets[1]) == "table" and type(targets[1].combatant) == "number" then
      local first = targets[1]
      return { combatant = first.combatant, activation = first.activation }
    end
    return nil
  end
  return nil
end

-- Plans the owned picture overlay from compiled placement operands.
-- Palette fades carry their clipped source coefficients, rotations
-- interpolate their angle pair, and offsets interpolate from their
-- source origin; operands naming no placement plan no overlay.
---@param parameters table<string, unknown>|nil compiled task parameters
---@return table<string, unknown>? picture overlay plan behind per-tick writes
local function picturePlanFor(parameters)
  if type(parameters) ~= "table" then
    return nil
  end
  if
    type(parameters.paletteTarget) == "string"
    and type(parameters.startCoefficient) == "number"
    and type(parameters.endCoefficient) == "number"
  then
    return {
      kind = "palette",
      start = clipBlendCoefficient(parameters.startCoefficient),
      finish = clipBlendCoefficient(parameters.endCoefficient),
      framesPer = isPositiveInt(parameters.wait) and parameters.wait or 1,
      targetColor = type(parameters.nextColor) == "number" and clampPaletteColor(parameters.nextColor) or 0,
    }
  end
  if type(parameters.startAngle) == "number" and type(parameters.targetAngle) == "number" then
    return {
      kind = "rotation",
      from = clampRotationAngle(parameters.startAngle),
      to = clampRotationAngle(parameters.targetAngle),
    }
  end
  local fromX, toX, fromY, toY = 0, 0, 0, 0
  local hasX, hasY = false, false
  if type(parameters.startX) == "number" and type(parameters.endX) == "number" then
    fromX, toX, hasX = clampPictureOffset(parameters.startX), clampPictureOffset(parameters.endX), true
  elseif type(parameters.offsetX) == "number" and parameters.offsetX ~= 0 then
    toX, hasX = clampPictureOffset(parameters.offsetX), true
  elseif type(parameters.signedOffset) == "number" and parameters.signedOffset ~= 0 then
    toX, hasX = clampPictureOffset(parameters.signedOffset), true
  elseif type(parameters.endpointX) == "number" and parameters.endpointX ~= 0 then
    toX, hasX = clampPictureOffset(parameters.endpointX), true
  end
  if type(parameters.startY) == "number" and type(parameters.endY) == "number" then
    fromY, toY, hasY = clampPictureOffset(parameters.startY), clampPictureOffset(parameters.endY), true
  elseif type(parameters.offsetY) == "number" and parameters.offsetY ~= 0 then
    toY, hasY = clampPictureOffset(parameters.offsetY), true
  elseif type(parameters.endpointY) == "number" and parameters.endpointY ~= 0 then
    toY, hasY = clampPictureOffset(parameters.endpointY), true
  elseif type(parameters.offsetStep) == "number" and parameters.offsetStep ~= 0 then
    toY, hasY = clampPictureOffset(parameters.offsetStep), true
  end
  if not hasX and not hasY then
    return nil
  end
  return { kind = "offset", fromX = fromX, toX = toX, fromY = fromY, toY = toY }
end

-- Plans the background scroll sweep from compiled scroll operands. The
-- sweep stays relative to the scroll saved at construction; teardown
-- restores that snapshot only while the task still owns the viewport.
---@param parameters table<string, unknown>|nil compiled task parameters
---@param duration integer source ticks behind the sweep
---@return table<string, integer>? scroll sweep totals behind per-tick writes
local function scrollSweepFor(parameters, duration)
  if type(parameters) ~= "table" then
    return nil
  end
  local function num(value)
    return (type(value) == "number" and value == value) and value or nil
  end
  local sweepX = num(parameters.offsetX) or num(parameters.horizontalOffset) or num(parameters.deltaX)
  local sweepY = num(parameters.offsetY) or num(parameters.verticalOffset) or num(parameters.deltaY)
  local stepX = num(parameters.horizontalStep)
  local stepY = num(parameters.verticalStep)
  if stepX ~= nil or stepY ~= nil then
    sweepX = (sweepX or 0) + (stepX or 0) * duration
    sweepY = (sweepY or 0) + (stepY or 0) * duration
  end
  if sweepX == nil and sweepY == nil then
    local startX = num(parameters.startX)
    local startY = num(parameters.startY)
    if startX ~= nil or startY ~= nil then
      sweepX = (startX or 0) + (num(parameters.deltaX) or 0)
      sweepY = (startY or 0) + (num(parameters.deltaY) or 0)
    end
  end
  if sweepX == nil and sweepY == nil then
    return nil
  end
  return { x = math.floor(sweepX or 0), y = math.floor(sweepY or 0) }
end

---@param services table<string, unknown>? collaborators under validation
---@param kind string task kind under construction
---@return table<string, unknown> scene behind visual state
local function checkScene(services, kind)
  if type(services) ~= "table" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " constructs without its services record", 0)
  end
  local scene = services.scene
  if type(scene) ~= "table" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " constructs without its scene", 0)
  end
  return scene --[[@as table<string, unknown>]]
end

-- Requires the transient sprite-record seam behind particle tasks, the
-- only family that publishes drawable pictures from staged dependency
-- textures. State-only families never consult this seam.
---@param scene table<string, unknown> scene under validation
---@param kind string task kind under construction
local function checkEffectScene(scene, kind)
  for _, method in ipairs({ "allocEffect", "setEffectPicture", "releaseEffect" }) do
    if type(scene[method]) ~= "function" then
      error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " constructs without scene effect ownership", 0)
    end
  end
end

-- Deterministic fallback behind direct construction without an
-- occurrence-local stream. Player-spawned tasks always carry the
-- occurrence random; the fallback only keeps argless construction
-- runnable and never touches mechanics randomness.
---@param bound integer visual draw bound under validation
---@return integer
local function fallbackRandom(bound)
  assert(type(bound) == "number" and bound >= 1, "visual draws name a positive bound")
  return 0
end

---@param context table<string, unknown> occurrence-bound playback context
---@param kind string task kind under construction
---@return unknown occurrence-local visual draw behind a positive bound
local function checkRandom(context, kind)
  local random = context.random
  if random == nil then
    return fallbackRandom
  end
  if type(random) ~= "function" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " reads visual randomness from a callable stream", 0)
  end
  return random
end

---@param scene table<string, unknown> scene behind transient effect records
---@param sourceKey string semantic source route behind the allocation
---@param picture table<string, unknown> staged picture state
---@return integer live effect identity
local function publishEffect(scene, sourceKey, picture)
  local record = scene.allocEffect(scene, sourceKey)
  assert(type(record) == "table", "effect allocation returns its live record")
  local id = record.id --[[@as integer]]
  assert(type(id) == "number", "effect allocation returns its live identity")
  scene.setEffectPicture(scene, id, picture)
  return id
end

---@param assetKey string staged drawable behind the transient picture
---@param selector string launch selector behind the transient picture
---@param centerX integer explicit scene horizontal center
---@param centerY integer explicit scene vertical center
---@param alpha number normalized transient picture alpha
---@return table<string, unknown> staged picture state
local function stagedPicture(assetKey, selector, centerX, centerY, alpha)
  return {
    assetKey = assetKey,
    selector = selector,
    centerX = centerX,
    centerY = centerY,
    zCenter = 0,
    width = 32,
    height = 32,
    alpha = alpha,
  }
end

-- Resolves the blend completion boundary from compiled timing operands:
-- an explicit duration wins, then the compiled per-step product.
-- Well-formed spawns without compiled timing resolve to no boundary:
-- the caller retires those synchronously instead of inventing a fixed
-- budget.
---@param args table<string, unknown> instruction-derived construction arguments
---@return integer? source ticks behind blend completion, absent for timing-less spawns
local function blendDuration(args)
  local parameters = args.parameters
  if type(parameters) == "table" then
    if isPositiveInt(parameters.durationTicks) then
      return parameters.durationTicks
    end
    if isPositiveInt(parameters.ticksPerStep) and isPositiveInt(parameters.steps) then
      return parameters.ticksPerStep * parameters.steps
    end
  end
  return nil
end

---@class BattleBlendTransition
---@field _scene table<string, unknown> scene behind the background scroll sweep
---@field _sweep table<string, integer>? compiled scroll totals behind per-tick writes
---@field _scrollSaved table<string, number> viewport snapshot behind owned-only restoration
---@field _lastScroll table<string, number>? last applied viewport behind owned-only restoration
---@field _ticks integer source ticks advanced
---@field _duration integer? source ticks behind completion, absent for synchronous markers
---@field _state string pending, running, complete, or cancelled
---@field _cancelReason string? last cancellation cause under diagnosis
---@field _disposed boolean release has run
local BattleBlendTransition = {}
BattleBlendTransition.__index = BattleBlendTransition

---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> scene, audio, and resource collaborators
---@return BattleBlendTransition runnable blend task
local function newBlendTransition(args, context, services)
  local _ = context
  if args.values ~= nil and type(args.values) ~= "table" then
    error(
      "BATTLE_EFFECT_TASK_MALFORMED: kind "
        .. BattleEffectTasks.BLEND_TRANSITION_KIND
        .. " carries its operands as a record",
      0
    )
  end
  if args.parameters ~= nil and type(args.parameters) ~= "table" then
    error(
      "BATTLE_EFFECT_TASK_MALFORMED: kind "
        .. BattleEffectTasks.BLEND_TRANSITION_KIND
        .. " carries its placement operands as a record",
      0
    )
  end
  local scene = checkScene(services, BattleEffectTasks.BLEND_TRANSITION_KIND)
  if type(scene.scroll) ~= "function" or type(scene.applyScrollPatch) ~= "function" then
    error(
      "BATTLE_EFFECT_TASK_MALFORMED: kind "
        .. BattleEffectTasks.BLEND_TRANSITION_KIND
        .. " constructs without the scene scroll seam",
      0
    )
  end
  local duration = blendDuration(args)
  local parameters = args.parameters
  if parameters == nil then
    parameters = {}
  end
  -- Timing-less spawns carry a compiled scroll shape but no boundary:
  -- those retire synchronously as validated markers instead of
  -- sweeping on an invented budget. Only the source retail census
  -- gates this path: timed spawns always take the sweep below.
  local sweep = nil
  if duration ~= nil then
    sweep = scrollSweepFor(parameters, duration)
  end
  local saved = scene.scroll(scene)
  return setmetatable({
    _scene = scene,
    _sweep = sweep,
    _scrollSaved = { x = saved.x, y = saved.y },
    _lastScroll = nil,
    _ticks = 0,
    _duration = duration,
    _state = "pending",
    _cancelReason = nil,
    _disposed = false,
  }, BattleBlendTransition)
end

-- Restores the viewport only while no newer sweep has moved it since:
-- the task owns its scroll interpolation for its whole lifetime, so a
-- finished blend never strands the viewport over the next effect. The
-- task stages no leases and publishes no drawable picture.
---@param self BattleBlendTransition
local function teardownBlend(self)
  if self._lastScroll ~= nil then
    local current = self._scene.scroll(self._scene)
    if current.x == self._lastScroll.x and current.y == self._lastScroll.y then
      self._scene.applyScrollPatch(self._scene, self._scrollSaved.x, self._scrollSaved.y)
    end
    self._lastScroll = nil
  end
end

-- Advances one source tick toward the blend boundary: the background
-- viewport follows the compiled sweep while the task holds it, and
-- completion restores the exact snapshot it saved at construction.
-- Timing-less markers retire on their first tick: the validated spawn
-- carries no boundary to interpolate, so there is nothing to sweep.
---@param self BattleBlendTransition
---@param tick table<string, unknown>? source tick under advancement
function BattleBlendTransition:stepSourceTick(tick)
  local _ = tick
  if self._disposed or self._state == "complete" or self._state == "cancelled" then
    return
  end
  self._state = "running"
  self._ticks = self._ticks + 1
  if self._duration == nil then
    self._state = "complete"
    teardownBlend(self)
    return
  end
  local progress = self._ticks / self._duration
  if progress > 1 then
    progress = 1
  end
  if self._sweep ~= nil then
    local x = self._scrollSaved.x + self._sweep.x * progress
    local y = self._scrollSaved.y + self._sweep.y * progress
    self._scene.applyScrollPatch(self._scene, x, y)
    self._lastScroll = { x = x, y = y }
  end
  if self._ticks >= self._duration then
    self._state = "complete"
    teardownBlend(self)
  end
end

-- Reports the blend run state for the player's retirement accounting.
---@param self BattleBlendTransition
---@return string
function BattleBlendTransition:status()
  assert(VALID_TASK_STATES[self._state] == true, "blend transitions report a known run state")
  return self._state
end

-- Cancels the blend; completion and cancellation stay separate, so a
-- completed blend keeps its completion.
---@param self BattleBlendTransition
---@param reason string cancellation cause under diagnosis
function BattleBlendTransition:cancel(reason)
  if self._state == "complete" then
    return
  end
  self._state = "cancelled"
  self._cancelReason = reason
  teardownBlend(self)
end

-- Restores the owned viewport exactly once; the blend stages nothing else.
---@param self BattleBlendTransition
function BattleBlendTransition:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  teardownBlend(self)
end

---@class BattleParticleContinuation
---@field _scene table<string, unknown> scene behind the transient effect record
---@field _staged table<integer, BattleEffectLeaseRecord> occurrence leases behind exactly-once release
---@field _resource string semantic particle resource behind the emission
---@field _emitter string normalized battler effect slot behind the emission
---@field _random unknown occurrence-local visual draw behind a positive bound
---@field _effectId integer? live effect identity, when published
---@field _effectReleased boolean transient record has been released
---@field _ticks integer source ticks advanced
---@field _duration integer source ticks behind completion
---@field _state string pending, running, complete, or cancelled
---@field _cancelReason string? last cancellation cause under diagnosis
---@field _disposed boolean release has run
local BattleParticleContinuation = {}
BattleParticleContinuation.__index = BattleParticleContinuation

---@param scene table<string, unknown> scene behind the transient effect record
---@param resource string semantic particle resource behind the emission
---@param emitter string normalized battler effect slot behind the emission
---@param alpha number normalized transient picture alpha
---@return table<string, unknown> staged picture state
local function particlePicture(scene, resource, emitter, alpha)
  local _ = scene
  local center = EMITTER_CENTERS[emitter]
  assert(center ~= nil, "particle emissions stage over a known effect slot")
  return stagedPicture(resource, emitter, center.x, center.y, alpha)
end

---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> scene, audio, and resource collaborators
---@return BattleParticleContinuation runnable particle task
local function newParticleContinuation(args, context, services)
  local resource = args.resource
  if resource == nil then
    resource = DEFAULT_PARTICLE_RESOURCE
  end
  if type(resource) ~= "string" or resource == "" then
    error(
      "BATTLE_EFFECT_TASK_MALFORMED: kind "
        .. BattleEffectTasks.PARTICLE_CONTINUATION_KIND
        .. " stages a named semantic particle resource",
      0
    )
  end
  local emitter = args.emitterPosition
  if emitter == nil then
    emitter = DEFAULT_PARTICLE_EMITTER
  end
  if type(emitter) ~= "string" or EMITTER_POSITIONS[emitter] ~= true then
    error(
      "BATTLE_EFFECT_TASK_MALFORMED: kind "
        .. BattleEffectTasks.PARTICLE_CONTINUATION_KIND
        .. " emits from a known battler effect slot",
      0
    )
  end
  local scene = checkScene(services, kind)
  checkEffectScene(scene, kind)
  local staged = {}
  stageLease(BattleEffectTasks.PARTICLE_CONTINUATION_KIND, resource, services, staged)
  local random = checkRandom(context, BattleEffectTasks.PARTICLE_CONTINUATION_KIND)
  local effectId = publishEffect(scene, resource, particlePicture(scene, resource, emitter, 1))
  return setmetatable({
    _scene = scene,
    _staged = staged,
    _resource = resource,
    _emitter = emitter,
    _random = random,
    _effectId = effectId,
    _effectReleased = false,
    _ticks = 0,
    _duration = PARTICLE_DURATION_TICKS,
    _state = "pending",
    _cancelReason = nil,
    _disposed = false,
  }, BattleParticleContinuation)
end

-- Releases the transient record and every staged lease exactly once.
---@param self BattleParticleContinuation
local function teardownParticle(self)
  if not self._effectReleased then
    self._effectReleased = true
    if self._effectId ~= nil then
      self._scene.releaseEffect(self._scene, self._effectId)
    end
  end
  releaseStaged(self._staged)
end

-- Advances one source tick: a fixed visual draw count runs every tick so
-- the same seed draws the same sequence at any host schedule, then the
-- staged alpha follows the remaining lifetime. Reads never advance: only
-- this entry point consumes the occurrence-local stream.
---@param self BattleParticleContinuation
---@param tick table<string, unknown>? source tick under advancement
function BattleParticleContinuation:stepSourceTick(tick)
  local _ = tick
  if self._disposed or self._state == "complete" or self._state == "cancelled" then
    return
  end
  self._state = "running"
  self._ticks = self._ticks + 1
  local random = self._random --[[@as fun(bound: integer): integer]]
  random(PARTICLE_DRAW_BOUND)
  random(PARTICLE_DRAW_BOUND)
  assert(PARTICLE_DRAWS_PER_TICK == 2, "particle ticks draw a fixed visual count")
  local remaining = self._duration - self._ticks
  if remaining < 0 then
    remaining = 0
  end
  self._scene.setEffectPicture(
    self._scene,
    self._effectId,
    particlePicture(self._scene, self._resource, self._emitter, remaining / self._duration)
  )
  if self._ticks >= self._duration then
    self._state = "complete"
    teardownParticle(self)
  end
end

-- Reports the particle run state for the player's retirement accounting.
---@param self BattleParticleContinuation
---@return string
function BattleParticleContinuation:status()
  assert(VALID_TASK_STATES[self._state] == true, "particle continuations report a known run state")
  return self._state
end

-- Cancels the particle run; completion and cancellation stay separate,
-- so a completed emission keeps its completion.
---@param self BattleParticleContinuation
---@param reason string cancellation cause under diagnosis
function BattleParticleContinuation:cancel(reason)
  if self._state == "complete" then
    return
  end
  self._state = "cancelled"
  self._cancelReason = reason
  teardownParticle(self)
end

-- Releases the transient record and every staged lease exactly once.
---@param self BattleParticleContinuation
function BattleParticleContinuation:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  teardownParticle(self)
end

---@class BattlePictureAnimation
---@field _scene table<string, unknown> scene behind the owned picture change
---@field _activation table<string, unknown>? combatant and activation pair behind the picture change
---@field _applied boolean temporary picture change is active
---@field _signedOffset number compiled signed horizontal offset behind the reveal
---@field _ticks integer source ticks advanced
---@field _duration integer? source ticks behind completion, absent for synchronous show markers
---@field _state string pending, running, complete, or cancelled
---@field _cancelReason string? last cancellation cause under diagnosis
---@field _disposed boolean release has run
local BattlePictureAnimation = {}
BattlePictureAnimation.__index = BattlePictureAnimation

---@param value unknown activation identity under validation
---@return boolean valid true for a combatant activation pair
local function validActivation(value)
  return type(value) == "table" and type(value.combatant) == "number"
end

-- Semantic battler-picture targets behind show-picture spawns, in the
-- runtime's normalized vocabulary. The factory validates membership
-- here and never imports the producer tables; an unknown target fails
-- closed with its kind identity.
local PICTURE_SPAWN_TARGETS = {
  ["active-position-first"] = true,
  ["active-position-second"] = true,
  ["first-battler-for-active-position-first"] = true,
  ["first-battler-for-active-position-second"] = true,
  ["first-battler-state-zero-or-two"] = true,
  ["first-battler-state-one-or-three"] = true,
  ["first-battler-state-four"] = true,
  ["first-battler-state-five"] = true,
}

---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> scene, audio, and resource collaborators
---@return BattlePictureAnimation runnable picture task
local function newPictureAnimation(args, context, services)
  local _ = context
  local kind = BattleEffectTasks.PICTURE_ANIMATION_KIND
  if args.battlerSelector ~= nil and type(args.battlerSelector) ~= "number" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " addresses its battler with a numeric selector", 0)
  end
  if args.mode ~= nil and type(args.mode) ~= "number" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " carries its picture mode numerically", 0)
  end
  if args.parameters ~= nil and type(args.parameters) ~= "table" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " carries its placement operands as a record", 0)
  end
  if args.values ~= nil and type(args.values) ~= "table" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " carries its operands as a record", 0)
  end
  if args.battlerTarget ~= nil then
    if type(args.battlerTarget) ~= "string" or PICTURE_SPAWN_TARGETS[args.battlerTarget] ~= true then
      error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " names a known battler picture target", 0)
    end
  end
  if args.runtimeSelection ~= nil and type(args.runtimeSelection) ~= "string" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " names its runtime selection semantically", 0)
  end
  local activation = args.activation
  if activation ~= nil and not validActivation(activation) then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " pictures a combatant activation pair", 0)
  end
  if activation == nil and args.battlerTarget == nil and args.battlerSelector == nil then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " addresses a battler to picture", 0)
  end
  local scene = checkScene(services, kind)
  if type(scene.applyPictureState) ~= "function" or type(scene.restorePictureState) ~= "function" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " constructs without the scene picture seam", 0)
  end
  local parameters = args.parameters
  local duration = nil
  local signedOffset = 0
  if type(parameters) == "table" then
    -- A compiled duration drives the animated reveal; a well-formed
    -- spawn without one retires synchronously as a validated marker.
    -- Only the source retail census gates that path: timed reveals
    -- always interpolate below.
    if isPositiveInt(parameters.durationTicks) then
      duration = parameters.durationTicks
    end
    if parameters.signedOffset ~= nil then
      if type(parameters.signedOffset) ~= "number" then
        error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " carries its signed offset numerically", 0)
      end
      signedOffset = parameters.signedOffset
    end
  end
  local owned = nil
  if activation ~= nil then
    owned = { combatant = activation.combatant, activation = activation.activation }
  end
  return setmetatable({
    _scene = scene,
    _activation = owned,
    _applied = false,
    _signedOffset = signedOffset,
    _ticks = 0,
    _duration = duration,
    _state = "pending",
    _cancelReason = nil,
    _disposed = false,
  }, BattlePictureAnimation)
end

-- Restores the exact pre-effect picture snapshot (only when this
-- occurrence still owns the activation). The reveal stages no leases
-- and publishes no drawable picture.
---@param self BattlePictureAnimation
local function teardownPicture(self)
  if self._applied then
    self._applied = false
    if self._activation ~= nil then
      self._scene.restorePictureState(self._scene, self._activation)
    end
  end
end

-- Advances one source tick toward the picture boundary. The reveal
-- interpolates its compiled signed offset onto the owned activation; a
-- zero source offset applies no shift at all. Show-marker spawns carry
-- no compiled timing at all: the native show applies synchronously and
-- program-level waits own the timing, so the validated marker retires
-- on its first tick instead of inventing a duration or pixels. The
-- temporary change stays owned by this occurrence's activation, so
-- withdrawing or replacing the activation never lets a stale restore
-- reach the new owner: withdrawal drops the stored patch with the old
-- activation.
---@param self BattlePictureAnimation
---@param tick table<string, unknown>? source tick under advancement
function BattlePictureAnimation:stepSourceTick(tick)
  local _ = tick
  if self._disposed or self._state == "complete" or self._state == "cancelled" then
    return
  end
  self._state = "running"
  self._ticks = self._ticks + 1
  if self._duration == nil then
    self._state = "complete"
    teardownPicture(self)
    return
  end
  if self._signedOffset ~= 0 and self._activation ~= nil then
    local progress = self._ticks / self._duration
    if progress > 1 then
      progress = 1
    end
    self._scene.applyPictureState(self._scene, self._activation, {
      pictureXOffset2 = wrapPictureByte(self._signedOffset * progress),
    })
    self._applied = true
  end
  if self._ticks >= self._duration then
    self._state = "complete"
    teardownPicture(self)
  end
end

-- Reports the picture run state for the player's retirement accounting.
---@param self BattlePictureAnimation
---@return string
function BattlePictureAnimation:status()
  assert(VALID_TASK_STATES[self._state] == true, "picture animations report a known run state")
  return self._state
end

-- Cancels the picture reveal; completion and cancellation stay separate,
-- so a completed reveal keeps its completion.
---@param self BattlePictureAnimation
---@param reason string cancellation cause under diagnosis
function BattlePictureAnimation:cancel(reason)
  if self._state == "complete" then
    return
  end
  self._state = "cancelled"
  self._cancelReason = reason
  teardownPicture(self)
end

-- Releases the owned picture snapshot exactly once; the reveal stages
-- nothing else.
---@param self BattlePictureAnimation
function BattlePictureAnimation:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  teardownPicture(self)
end

---@class BattleSoundTask
---@field _audio table<string, unknown> semantic voice collaborator behind play and completion
---@field _voice string staged voice identity behind completion
---@field _armed boolean run has observed its voice unfinished at least once
---@field _ticks integer source ticks advanced without voice completion
---@field _escape integer bounded ticks behind the native voice escape
---@field _state string pending, running, complete, or cancelled
---@field _cancelReason string? last cancellation cause under diagnosis
---@field _stopped boolean staged voice has been stopped
---@field _disposed boolean release has run
local BattleSoundTask = {}
BattleSoundTask.__index = BattleSoundTask

---@param self BattleSoundTask
local function stopSoundVoice(self)
  if self._stopped then
    return
  end
  self._stopped = true
  local audio = self._audio --[[@as table<string, unknown>]]
  if type(audio.stop) == "function" then
    pcall(audio.stop, self._voice)
  elseif type(audio.stopVoice) == "function" then
    pcall(audio.stopVoice, self._voice)
  end
end

---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> scene, audio, and resource collaborators
---@return BattleSoundTask runnable sound task
local function newSoundTask(kind, args, context, services)
  local _ = context
  local sound = args.sound
  if type(sound) ~= "string" or sound == "" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " stages a named semantic voice", 0)
  end
  if args.values ~= nil and type(args.values) ~= "table" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " carries its voice operands as a record", 0)
  end
  if type(services) ~= "table" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " constructs without its services record", 0)
  end
  local audio = services.audio
  if type(audio) ~= "table" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " constructs without its audio collaborator", 0)
  end
  local stageVoice = audio.playEffect or audio.play
  if type(stageVoice) ~= "function" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " stages its voice through a semantic audio port", 0)
  end
  if type(audio.isFinished) ~= "function" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " reads its voice through an audio completion query", 0)
  end
  local ok, staged = pcall(stageVoice, sound, args.values)
  if not ok then
    error(
      "BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " stages no voice for " .. sound .. ": " .. tostring(staged),
      0
    )
  end
  local _ = staged
  return setmetatable({
    _audio = audio,
    _voice = sound,
    _armed = false,
    _ticks = 0,
    _escape = SOUND_ESCAPE_TICKS,
    _state = "pending",
    _cancelReason = nil,
    _stopped = false,
    _disposed = false,
  }, BattleSoundTask)
end

-- Advances one source tick: completion is the staged voice ending.
-- The run arms on its first unfinished observation and completes on
-- the first finished observation after that, so a voice that never
-- reports alive cannot fake-complete the run; the bounded escape
-- retires such runs instead, so a silent voice cannot park the
-- occurrence past the native horizon. Audio failures propagate so
-- the player fails the owning occurrence.
---@param self BattleSoundTask
---@param tick table<string, unknown>? source tick under advancement
function BattleSoundTask:stepSourceTick(tick)
  local _ = tick
  if self._disposed or self._state == "complete" or self._state == "cancelled" then
    return
  end
  self._state = "running"
  self._ticks = self._ticks + 1
  local audio = self._audio --[[@as table<string, fun(string): boolean>]]
  if audio.isFinished(self._voice) then
    if self._armed then
      self._state = "complete"
      return
    end
  else
    self._armed = true
  end
  if self._ticks >= self._escape then
    self._state = "complete"
    stopSoundVoice(self)
  end
end

-- Reports the sound run state for the player's retirement accounting.
---@param self BattleSoundTask
---@return string
function BattleSoundTask:status()
  assert(VALID_TASK_STATES[self._state] == true, "sound tasks report a known run state")
  return self._state
end

-- Cancels the sound run and stops the staged voice; completion and
-- cancellation stay separate, so a completed voice keeps its completion.
---@param self BattleSoundTask
---@param reason string cancellation cause under diagnosis
function BattleSoundTask:cancel(reason)
  if self._state == "complete" then
    return
  end
  self._state = "cancelled"
  self._cancelReason = reason
  stopSoundVoice(self)
end

-- Releases the staged voice exactly once; the sound run holds no lease
-- or scene mutation of its own.
---@param self BattleSoundTask
function BattleSoundTask:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  if self._state ~= "complete" then
    stopSoundVoice(self)
  end
end

-- Emitted nonparticle visual task kinds with real bodies in this lane.
-- The blend, picture, and sound families above come first; every other
-- spelling here routes to the source-parameterized body below. Only
-- the producer vocabulary is admitted: the particle emitter family
-- stays out until its own lane lands, and unknown kinds fail closed.
local NATIVE_VISUAL_KINDS = {
  ["battle-background-alpha-scroll-transition"] = true,
  ["battle-background-alternating-scroll-transition"] = true,
  ["battle-background-four-picture-move-power-transition"] = true,
  ["battle-background-picture-coordinate-sweep"] = true,
  ["battle-background-picture-palette-scroll"] = true,
  ["battle-background-picture-scroll-oscillation"] = true,
  ["battle-background-picture-wipe-transition"] = true,
  ["battle-background-pokepic-slide"] = true,
  ["battle-background-position-transition"] = true,
  ["battle-background-resource-load"] = true,
  ["battle-background-scanline-sine-wave-transition"] = true,
  ["battle-background-sprite-slide-transition"] = true,
  ["battle-display-window-palette-transition"] = true,
  ["battle-palette-fade"] = true,
  ["battle-presentation-resource-cleanup"] = true,
  ["battle-presentation-state-reset"] = true,
  ["battle-sprite-affine-appearance-transition"] = true,
  ["battle-sprite-blend-alpha-transition"] = true,
  ["battle-sprite-mosaic-transition"] = true,
  ["battle-sprite-panel-slide"] = true,
  ["battle-sprite-priority-appearance-transition"] = true,
  ["battle-sprite-sinusoidal-position-animation"] = true,
  ["managed-sprite-draw-loop"] = true,
  ["multi-sprite-battler-animation"] = true,
  ["multi-sprite-picture-animation"] = true,
  ["multi-sprite-position-tick"] = true,
  ["multi-sprite-position-transition"] = true,
  ["pokemon-picture-affine-blend-palette-transition"] = true,
  ["pokemon-picture-affine-sprite-entry-transition"] = true,
  ["pokemon-picture-affine-transition"] = true,
  ["pokemon-picture-and-battle-palette-fade"] = true,
  ["pokemon-picture-and-battle-palette-fade-cycle"] = true,
  ["pokemon-picture-animation-palette-fade"] = true,
  ["pokemon-picture-animation-position-transition"] = true,
  ["pokemon-picture-animation-speed-transition"] = true,
  ["pokemon-picture-battle-palette-fade-cycle"] = true,
  ["pokemon-picture-battler-pair-scale-transition"] = true,
  ["pokemon-picture-cyclic-two-phase-position-transition"] = true,
  ["pokemon-picture-double-sprite-scale-settle"] = true,
  ["pokemon-picture-entry-offset-transition"] = true,
  ["pokemon-picture-five-phase-affine-size-transition"] = true,
  ["pokemon-picture-four-sprite-wave-transition"] = true,
  ["pokemon-picture-height-position-transition"] = true,
  ["pokemon-picture-managed-sprite-affine-pair-transition"] = true,
  ["pokemon-picture-managed-sprite-scale-pulse"] = true,
  ["pokemon-picture-multi-sprite-animation"] = true,
  ["pokemon-picture-oam-animation-transition"] = true,
  ["pokemon-picture-oscillating-axis-motion"] = true,
  ["pokemon-picture-paired-position-interpolation"] = true,
  ["pokemon-picture-palette-fade"] = true,
  ["pokemon-picture-palette-fade-position-transition"] = true,
  ["pokemon-picture-palette-pulse-position-transition"] = true,
  ["pokemon-picture-position-offset-transition"] = true,
  ["pokemon-picture-position-path-transition"] = true,
  ["pokemon-picture-priority-motion"] = true,
  ["pokemon-picture-randomized-position-motion"] = true,
  ["pokemon-picture-reciprocal-position-palette-transition"] = true,
  ["pokemon-picture-relative-sprite-path-transition"] = true,
  ["pokemon-picture-repeated-palette-fade"] = true,
  ["pokemon-picture-repeated-scale-position-transition"] = true,
  ["pokemon-picture-repeated-vanish-transition"] = true,
  ["pokemon-picture-scale-position-transition"] = true,
  ["pokemon-picture-selected-horizontal-offset-transition"] = true,
  ["pokemon-picture-selected-pair-transition"] = true,
  ["pokemon-picture-selected-position-offset-transition"] = true,
  ["pokemon-picture-selected-position-transition"] = true,
  ["pokemon-picture-sinusoidal-position-motion"] = true,
  ["pokemon-picture-sprite-position-transition"] = true,
  ["pokemon-picture-table-driven-position-transition"] = true,
  ["pokemon-picture-target-background-slide"] = true,
  ["pokemon-picture-target-priority-transition"] = true,
  ["pokemon-picture-three-sprite-affine-transition"] = true,
  ["pokemon-picture-three-sprite-position-wave-transition"] = true,
  ["pokemon-picture-two-battler-crossing-motion"] = true,
  ["pokemon-picture-two-phase-entry-motion"] = true,
  ["pokemon-picture-two-phase-scale-transition"] = true,
  ["pokemon-picture-vanish-affine-transition"] = true,
  ["pokemon-picture-vanish-and-restore-transition"] = true,
  ["pokemon-picture-vertical-offset-visibility-transition"] = true,
  ["pokemon-picture-z-rotation-transition"] = true,
  ["sprite-affine-animation"] = true,
  ["sprite-affine-animation-lifecycle"] = true,
  ["sprite-affine-rotation-motion"] = true,
  ["sprite-affine-rotation-transition"] = true,
  ["sprite-affine-scale-and-blend-transition"] = true,
  ["sprite-affine-scale-draw-transition"] = true,
  ["sprite-affine-transform-motion"] = true,
  ["sprite-alpha-transition"] = true,
  ["sprite-animation-affine-scale-transition"] = true,
  ["sprite-animation-completion"] = true,
  ["sprite-animation-lifecycle"] = true,
  ["sprite-animation-palette-offset"] = true,
  ["sprite-animation-position-transition"] = true,
  ["sprite-brightness-transition"] = true,
  ["sprite-flip-and-offset-transition"] = true,
  ["sprite-flip-animation-transition"] = true,
  ["sprite-position-offset"] = true,
  ["sprite-randomized-affine-motion"] = true,
}

-- Sound task kinds with real voice bodies in this lane.
local SOUND_TASK_KINDS = {
  ["positioned-sound-motion"] = true,
  ["repeated-sound-playback"] = true,
  ["delayed-sound-playback"] = true,
}

---@class BattleNativeVisualTask
---@field _scene table<string, unknown> scene behind owned visual state
---@field _kind string emitted task kind behind the run
---@field _activation table<string, unknown>? combatant and activation pair behind the owned picture
---@field _picturePlan table<string, unknown>? compiled placement plan behind per-tick writes
---@field _canPatch boolean scene carries the task-owned overlay seam
---@field _patchActive boolean task-owned overlay is applied
---@field _paletteApplied boolean palette overlay applied once, never reset by stepping
---@field _scrollSweep table<string, integer>? compiled scroll totals behind per-tick writes
---@field _canScroll boolean scene carries the scroll seam
---@field _scrollSaved table<string, number> viewport snapshot behind owned-only restoration
---@field _lastScroll table<string, number>? last applied viewport behind owned-only restoration
---@field _scrollApplied boolean sweep has written the viewport
---@field _random unknown occurrence-local visual draw behind a positive bound
---@field _jitter boolean run carries occurrence-local visual jitter
---@field _ticks integer source ticks advanced
---@field _duration integer? source ticks behind completion, absent for synchronous markers
---@field _state string pending, running, complete, or cancelled
---@field _cancelReason string? last cancellation cause under diagnosis
---@field _disposed boolean release has run
local BattleNativeVisualTask = {}
BattleNativeVisualTask.__index = BattleNativeVisualTask

---@param args table<string, unknown> instruction-derived construction arguments
---@param kind string task kind under construction
local function checkVisualArgs(args, kind)
  if args.parameters ~= nil then
    if type(args.parameters) ~= "table" or args.parameters[1] ~= nil then
      error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " carries its parameters as a record", 0)
    end
  end
  if args.values ~= nil and type(args.values) ~= "table" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " carries its operands as a record", 0)
  end
  if args.battlerTarget ~= nil and type(args.battlerTarget) ~= "string" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " names its battler target semantically", 0)
  end
  if args.taskContext ~= nil and type(args.taskContext) ~= "string" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " names its task context semantically", 0)
  end
  if args.resourceKeys ~= nil and type(args.resourceKeys) ~= "table" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " carries its resource keys as a record", 0)
  end
  if args.callback ~= nil and type(args.callback) ~= "string" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " names its source callback semantically", 0)
  end
  if args.runtimeSelection ~= nil and type(args.runtimeSelection) ~= "string" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " names its runtime selection semantically", 0)
  end
  if args.activation ~= nil and not validActivation(args.activation) then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " pictures a combatant activation pair", 0)
  end
end

---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> scene, audio, and resource collaborators
---@return BattleNativeVisualTask runnable visual task
local function newNativeVisualTask(kind, args, context, services)
  checkVisualArgs(args, kind)
  local scene = checkScene(services, kind)
  local parameters = args.parameters
  if parameters == nil then
    parameters = {}
  end
  local duration = visualDuration(parameters)
  local activation = plannedActivation(args, context or {})
  local canPatch = type(scene.applyTaskPicturePatch) == "function" and type(scene.removeTaskPicturePatch) == "function"
  local picturePlan = nil
  local canScroll = type(scene.scroll) == "function" and type(scene.applyScrollPatch) == "function"
  local scrollSweep = nil
  local jitter = false
  -- Timing-less spawns retire synchronously as validated markers:
  -- without a source boundary there is no owned interpolation
  -- lifetime, so the run owns no patch or sweep. Only the source
  -- retail census gates this path: timed spawns always interpolate
  -- below.
  if duration ~= nil then
    if activation ~= nil and canPatch then
      picturePlan = picturePlanFor(parameters)
    end
    if picturePlan == nil and canScroll then
      scrollSweep = scrollSweepFor(parameters, duration)
    end
    jitter = string.find(kind, "randomized", 1, true) ~= nil
  end
  local random = checkRandom(context or {}, kind)
  local scrollSaved = { x = 0, y = 0 }
  if canScroll then
    local saved = scene.scroll(scene)
    scrollSaved = { x = saved.x, y = saved.y }
  end
  return setmetatable({
    _scene = scene,
    _kind = kind,
    _activation = activation,
    _picturePlan = picturePlan,
    _canPatch = canPatch,
    _patchActive = false,
    _paletteApplied = false,
    _scrollSweep = scrollSweep,
    _canScroll = canScroll,
    _scrollSaved = scrollSaved,
    _lastScroll = nil,
    _scrollApplied = false,
    _random = random,
    _jitter = jitter,
    _ticks = 0,
    _duration = duration,
    _state = "pending",
    _cancelReason = nil,
    _disposed = false,
  }, BattleNativeVisualTask)
end

-- Writes one tick of owned visual state: the scroll sweep interpolates
-- its compiled totals, the picture overlay interpolates its compiled
-- placement, and randomized runs draw their jitter from the
-- occurrence-local stream. Palette overlays apply once: the scene steps
-- them natively afterward. The run publishes no drawable picture.
---@param self BattleNativeVisualTask
---@param progress number completed fraction in 0..1
local function writeVisualTick(self, progress)
  local scene = self._scene
  if self._scrollSweep ~= nil and self._canScroll then
    local x = self._scrollSaved.x + self._scrollSweep.x * progress
    local y = self._scrollSaved.y + self._scrollSweep.y * progress
    scene.applyScrollPatch(scene, x, y)
    self._scrollApplied = true
    self._lastScroll = { x = x, y = y }
  end
  local plan = self._picturePlan
  if plan ~= nil and self._activation ~= nil and self._canPatch then
    if plan.kind == "palette" then
      if not self._paletteApplied then
        self._paletteApplied = true
        scene.applyTaskPicturePatch(scene, self, self._activation, {
          paletteFade = {
            start = plan.start,
            finish = plan.finish,
            framesPer = plan.framesPer,
            targetColor = plan.targetColor,
          },
        })
        self._patchActive = true
      end
    elseif plan.kind == "rotation" then
      scene.applyTaskPicturePatch(scene, self, self._activation, {
        rotationZ = clampRotationAngle(plan.from + (plan.to - plan.from) * progress),
      })
      self._patchActive = true
    else
      local patch = {}
      if plan.fromX ~= 0 or plan.toX ~= 0 then
        patch.pictureXOffset2 = wrapPictureByte(plan.fromX + (plan.toX - plan.fromX) * progress)
      end
      if plan.fromY ~= 0 or plan.toY ~= 0 then
        patch.pictureYOffset = clampPictureOffset(plan.fromY + (plan.toY - plan.fromY) * progress)
      end
      if next(patch) ~= nil then
        scene.applyTaskPicturePatch(scene, self, self._activation, patch)
        self._patchActive = true
      end
    end
  end
  if self._jitter then
    local random = self._random --[[@as fun(bound: integer): integer]]
    random(65)
    random(65)
  end
end

-- Restores only still-owned visual state: the picture overlay drops
-- exactly when this task still owns its slot, and the viewport restores
-- only while no newer sweep has moved it since. The run stages no leases
-- and publishes no drawable picture, so teardown owns patches only.
---@param self BattleNativeVisualTask
local function teardownNativeVisual(self)
  if self._patchActive then
    self._patchActive = false
    if self._activation ~= nil and self._canPatch then
      self._scene.removeTaskPicturePatch(self._scene, self, self._activation)
    end
  end
  if self._scrollApplied then
    self._scrollApplied = false
    if self._canScroll and self._lastScroll ~= nil then
      local current = self._scene.scroll(self._scene)
      if current.x == self._lastScroll.x and current.y == self._lastScroll.y then
        self._scene.applyScrollPatch(self._scene, self._scrollSaved.x, self._scrollSaved.y)
      end
    end
    self._lastScroll = nil
  end
end

-- Advances one source tick toward the compiled boundary. Mid-task scene
-- failures restore the task's own partial visuals before the failure
-- reaches the player, so a withdrawn activation never strands a patch.
-- Timing-less markers retire on their first tick: the validated spawn
-- carries no boundary to interpolate, so there is nothing to write.
---@param self BattleNativeVisualTask
---@param tick table<string, unknown>? source tick under advancement
function BattleNativeVisualTask:stepSourceTick(tick)
  local _ = tick
  if self._disposed or self._state == "complete" or self._state == "cancelled" then
    return
  end
  self._state = "running"
  self._ticks = self._ticks + 1
  if self._duration == nil then
    self._state = "complete"
    teardownNativeVisual(self)
    return
  end
  local progress = self._ticks / self._duration
  if progress > 1 then
    progress = 1
  end
  local ok, err = pcall(writeVisualTick, self, progress)
  if not ok then
    teardownNativeVisual(self)
    error(err, 0)
  end
  if self._ticks >= self._duration then
    self._state = "complete"
    teardownNativeVisual(self)
  end
end

-- Reports the visual run state for the player's retirement accounting.
---@param self BattleNativeVisualTask
---@return string
function BattleNativeVisualTask:status()
  assert(VALID_TASK_STATES[self._state] == true, "native visual tasks report a known run state")
  return self._state
end

-- Cancels the visual run; completion and cancellation stay separate, so
-- a completed run keeps its completion.
---@param self BattleNativeVisualTask
---@param reason string cancellation cause under diagnosis
function BattleNativeVisualTask:cancel(reason)
  if self._state == "complete" then
    return
  end
  self._state = "cancelled"
  self._cancelReason = reason
  teardownNativeVisual(self)
end

-- Releases the transient record and any owned scene patch exactly once.
---@param self BattleNativeVisualTask
function BattleNativeVisualTask:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  teardownNativeVisual(self)
end

-- Reports whether the factory constructs a real task for a kind. The
-- predicate is a direct view of the constructor dispatch below: only
-- emitted producer kinds with implemented bodies are admitted.
---@param kind unknown task kind under admission
---@return boolean admitted true for kinds with real constructor bodies
function BattleEffectTasks.supportsKind(kind)
  if type(kind) ~= "string" or kind == "" then
    return false
  end
  if kind == BattleEffectTasks.VOICE_MONITOR_KIND then
    return true
  end
  if kind == BattleEffectTasks.BLEND_TRANSITION_KIND then
    return true
  end
  if kind == BattleEffectTasks.PARTICLE_CONTINUATION_KIND then
    return true
  end
  if kind == BattleEffectTasks.PICTURE_ANIMATION_KIND then
    return true
  end
  if SOUND_TASK_KINDS[kind] == true then
    return true
  end
  return NATIVE_VISUAL_KINDS[kind] == true
end

-- Constructs one runnable task for a normalized task kind. The player
-- passes its scene, audio, and resource collaborators through services
-- untouched; task bodies own only what services delegate at construction.
-- Argless construction stays runnable for directly probed kinds; unknown
-- kinds fail with their kind identity instead of returning a timer
-- stand-in.
---@param kind string normalized task kind scheduled by one instruction
---@param args table<string, unknown>? instruction-derived construction arguments
---@param context table<string, unknown>? occurrence-bound playback context
---@param services table<string, unknown>? scene, audio, and resource collaborators
---@return table<string, unknown> runnable task behind stepSourceTick, status, cancel, dispose
function BattleEffectTasks.create(kind, args, context, services)
  assert(args == nil or type(args) == "table", "task construction carries its arguments as a record")
  assert(context == nil or type(context) == "table", "task construction carries its context as a record")
  if kind == BattleEffectTasks.VOICE_MONITOR_KIND then
    assert(type(args) == "table", "voice monitors carry their awaited voice in args")
    assert(type(services) == "table", "voice monitors require their services record")
    local voice = args.voice --[[@as string]]
    return newVoiceMonitor(voice, services)
  end
  if kind == BattleEffectTasks.BLEND_TRANSITION_KIND then
    assert(type(services) == "table", "blend transitions require their services record")
    return newBlendTransition(args or {}, context or {}, services)
  end
  if kind == BattleEffectTasks.PARTICLE_CONTINUATION_KIND then
    assert(type(services) == "table", "particle continuations require their services record")
    return newParticleContinuation(args or {}, context or {}, services)
  end
  if kind == BattleEffectTasks.PICTURE_ANIMATION_KIND then
    assert(type(services) == "table", "picture animations require their services record")
    return newPictureAnimation(args or {}, context or {}, services)
  end
  if SOUND_TASK_KINDS[kind] == true then
    assert(type(services) == "table", "sound tasks require their services record")
    return newSoundTask(kind, args or {}, context or {}, services)
  end
  if NATIVE_VISUAL_KINDS[kind] == true then
    assert(type(services) == "table", "native visual tasks require their services record")
    return newNativeVisualTask(kind, args or {}, context or {}, services)
  end
  error("BATTLE_EFFECT_TASK_UNKNOWN: no native task implementation for kind " .. tostring(kind), 0)
end

return BattleEffectTasks
