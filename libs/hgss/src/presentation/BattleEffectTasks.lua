-- Battle-private effect task factory for normalized battle animations.
-- Native task bodies live in src/battle/battle_anim_effects.c and drive
-- sys tasks through BattleAnimSystem_CreateTaskOfKind (kind 1 counts
-- taskCount, kind 2 counts soundTaskCount); raw visual work uses
-- SysTask_CreateOnMainQueue directly and stays outside both counters.
-- The player schedules work through this factory as
-- Factory.create(kind, args, context, services); unknown kinds fail here
-- instead of returning a timer stand-in. Voice monitoring, sound actions
-- with real voice completion, background blend transitions, battler
-- particle continuations, picture reveals, configured-sprite cell frames,
-- and one source-parameterized visual body per remaining nonparticle
-- task kind have bodies in this lane; only kinds outside the emitted
-- producer vocabulary still fail closed. Visual, blend, and picture
-- bodies mutate only scene state (owned picture patches, scroll sweeps,
-- palette overlays) and publish no drawable picture of their own: only
-- particle tasks and configured-sprite cell tasks draw, and only from
-- staged dependency textures. Completion boundaries come only from
-- compiled source timing operands. A spawn whose instruction carries no compiled timing operand
-- retires synchronously ONLY when its kind belongs to the verified synchronous-marker set below;
-- every other timing-less spawn fails closed with BATTLE_EFFECT_TASK_MALFORMED instead of retiring
-- silently, and malformed shapes fail closed. No fixed budget stands in for source timing anywhere.
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
BattleEffectTasks.EMITTER_BATTLER_PATH_KIND = "battle-particle-emitter-battler-path"
BattleEffectTasks.EMITTER_CURVED_PATH_KIND = "battle-particle-emitter-curved-battler-path"
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
  if not ok or lease == nil then
    rollbackStaged(staged, holder, key)
    local cause = nil
    if ok then
      cause = "no lease staged for key " .. key
    else
      cause = tostring(lease)
    end
    error("BATTLE_EFFECT_TASK_RESOURCE: kind " .. kind .. " requires resource " .. key .. ": " .. cause, 0)
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
-- then approach/settle sums and single-tick fields. Spawns whose
-- instruction carries no compiled timing operand resolve to no boundary:
-- the constructing body retires those synchronously only for kinds in the
-- verified synchronous-marker set, and fails every other kind closed.
-- Completion times come only from the source parameters the producer
-- emitted, never from a fixed budget.
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
  -- Paired-interpolation carries no durationTicks, but its step operands
  -- bound the run: initialSteps at stepIntervalTicks each (producer-packed
  -- word 8; the native emitter-motion task runs its own duration the same
  -- way). Without this product the FLY glide markers a tick-1 retire.
  if isPositiveInt(parameters.initialSteps) and isPositiveInt(parameters.stepIntervalTicks) then
    return parameters.initialSteps * parameters.stepIntervalTicks
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
---@param width integer? staged drawable width behind the picture, 32 when absent
---@param height integer? staged drawable height behind the picture, 32 when absent
---@return table<string, unknown> staged picture state
local function stagedPicture(assetKey, selector, centerX, centerY, alpha, width, height)
  return {
    assetKey = assetKey,
    selector = selector,
    centerX = centerX,
    centerY = centerY,
    zCenter = 0,
    width = width or 32,
    height = height or 32,
    alpha = alpha,
  }
end

-- Kinds whose timing-less spawns retire synchronously, one entry per
-- verified source-synchronous noop. Each entry carries its pinned source
-- pointer, verified against the referenced source:
-- * "pokemon-picture-animation": the animation compiler lowers
--   show-pokemon-picture (romdump/src/digest/battle/BattleAnimationCompiler.lua,
--   opcode 31) with only its battler selector and mode and no timing
--   operands, and the player show handler
--   (libs/hgss/src/presentation/BattleAnimationCommands.lua,
--   handleShowPokemonPicture) spawns it with only battler selector, mode,
--   and activation. The native show applies synchronously while
--   program-level waits own the timing.
-- * "pokemon-picture-reset-position-transition": the producer lowers the
--   reset with no timing boundary
--   (romdump/src/config/BattleAnimationSources.lua,
--   resolveBattleAnimationCallback selector 62, ResetBattlerPosition in
--   battle_anim_funcs.c), which snaps the role picture home at once.
-- Timing-less spawns of every other kind fail closed at construction
-- instead of retiring silently with zero writes.
local SYNCHRONOUS_MARKER_KINDS = {
  ["pokemon-picture-animation"] = true,
  ["pokemon-picture-reset-position-transition"] = true,
}

-- Resolves the blend completion boundary from compiled timing operands:
-- an explicit duration wins, then the compiled per-step product. Spawns
-- without compiled timing resolve to no boundary: the constructing body
-- retires those synchronously only for kinds in the verified
-- synchronous-marker set, and fails every other kind closed.
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
  if duration == nil and SYNCHRONOUS_MARKER_KINDS[BattleEffectTasks.BLEND_TRANSITION_KIND] ~= true then
    error(
      "BATTLE_EFFECT_TASK_MALFORMED: kind "
        .. BattleEffectTasks.BLEND_TRANSITION_KIND
        .. " retires only on compiled timing operands",
      0
    )
  end
  local parameters = args.parameters
  if parameters == nil then
    parameters = {}
  end
  -- Timing-less spawns retire synchronously only for verified marker
  -- kinds; this body fails them closed above. Timed spawns always take
  -- the sweep below.
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
-- Marker-kind spawns without a boundary retire on their first tick: the
-- spawn carries no boundary to interpolate, so there is nothing to sweep.
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

-- Native particle emitter simulation. One normalized staged emitter
-- drives one sprite stream: emission cadence and bounds come from its
-- staged control values, motion from its staged fixed-point words plus
-- occurrence-local jitter, retirement from its own completion boundary.
-- Structural control positions inside the staged u16 params (1-based):
-- activeTicks [29], spriteLife [30], spawnEvery [24], spawnCount [32].
-- Kinematics read staged 12.20 fixed-point pairs: spawn offset from
-- params[1..4], velocity from params[17..18] and params[21..22], gravity
-- from the gravity calculation words when the feature is present.
-- Positions quantize to integer pixels per native fixed-point rounding.
-- Only emitters carrying the random feature draw from the
-- occurrence-local stream, two draws per source tick shared by the
-- emitter's sprites, so grouped and split host reads stay identical.

-- Jitter bound behind seeded placement divergence: draws name 0..8 and
-- center to visible pixel offsets without drowning the source drift.
local PARTICLE_JITTER_BOUND = 9

---@param value unknown candidate fixed-point word under signing
---@return integer signed 32-bit value
local function signed32(value)
  assert(type(value) == "number", "fixed-point words decode numerically")
  if value >= 2 ^ 31 then
    return value - 2 ^ 32
  end
  return value
end

---@param record table<string, unknown> normalized staged emitter under reading
---@param feature string source behavior under probing
---@return boolean active true when the source behavior is present
local function emitterHasFeature(record, feature)
  local features = record.features
  if type(features) ~= "table" then
    return false
  end
  for _, name in ipairs(features) do
    if name == feature then
      return true
    end
  end
  return false
end

---@class BattleParticleContinuation
---@field _scene table<string, unknown> scene behind the transient sprite records
---@field _staged table<integer, BattleEffectLeaseRecord> occurrence leases behind exactly-once release
---@field _resource string semantic particle resource behind the emission
---@field _emitter string normalized battler effect slot behind the emission
---@field _random unknown occurrence-local visual draw behind a positive bound
---@field _center table<string, integer> slot anchor behind spawned sprites
---@field _streams table<integer, table<string, unknown>> emitter streams under simulating
---@field _effectIds table<integer, boolean> live sprite identities behind exactly-once release
---@field _state string pending, running, complete, or cancelled
---@field _cancelReason string? last cancellation cause under diagnosis
---@field _disposed boolean release has run
local BattleParticleContinuation = {}
BattleParticleContinuation.__index = BattleParticleContinuation

---@param record table<string, unknown> staged borrowed record under classifying
---@return boolean native true for normalized emitter state staged by the producer
local function isNormalizedEmitter(record)
  return type(record) == "table" and type(record.features) == "table" and type(record.params) == "table"
end

---@param record table<string, unknown> staged borrowed record under classifying
---@return boolean archive true for a normalized particle archive staged by the producer
local function isNormalizedArchive(record)
  return type(record) == "table" and type(record.emitters) == "table"
end

---@param value unknown candidate drawable field under validating
---@param what string drawable identity behind diagnostics
local function checkDrawableField(value, what)
  if type(value) ~= "number" or value % 1 ~= 0 or value < 1 then
    error(
      "BATTLE_EFFECT_TASK_MALFORMED: kind "
        .. BattleEffectTasks.PARTICLE_CONTINUATION_KIND
        .. " draws staged drawables with positive integer extents: "
        .. what,
      0
    )
  end
end

-- Builds one emitter stream from normalized staged state. Control values
-- read the documented structural positions; kinematics read staged
-- 12.20 fixed-point words.
---@param record table<string, unknown> normalized staged emitter behind the stream
---@param drawable table<string, unknown>? staged drawable behind its sprites
---@param center table<string, integer> slot anchor behind spawned sprites
---@return table<string, unknown> emitter stream under simulating
local function particleStream(record, drawable, center)
  local params = record.params --[[@as table<integer, number>]]
  assert(#params == 42, "normalized emitters carry their full control block")
  local gravity = record.gravity
  local gravityX, gravityY = 0, 0
  if emitterHasFeature(record, "gravity") and type(gravity) == "table" then
    gravityX = signed32(gravity[1] or 0) / 1048576
    gravityY = signed32(gravity[2] or 0) / 1048576
  end
  local function fixedPair(lowIndex)
    local word = params[lowIndex] + params[lowIndex + 1] * 65536
    return signed32(word) / 1048576
  end
  return {
    record = record,
    drawable = drawable,
    assetKey = record.textureKey,
    center = center,
    active = params[29],
    life = params[30],
    every = params[24],
    count = params[32],
    offsetX = fixedPair(1),
    offsetY = fixedPair(3),
    velocityX = fixedPair(17),
    velocityY = fixedPair(21),
    gravityX = gravityX,
    gravityY = gravityY,
    jitter = emitterHasFeature(record, "random"),
    fade = emitterHasFeature(record, "alpha"),
    age = 0,
    jitterX = 0,
    jitterY = 0,
    sprites = {},
  }
end

---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> scene, audio, and resource collaborators
---@return BattleParticleContinuation runnable particle task
local function newParticleContinuation(args, context, services)
  local kind = BattleEffectTasks.PARTICLE_CONTINUATION_KIND
  local resource = args.resource
  if type(resource) ~= "string" or resource == "" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " stages a named semantic particle resource", 0)
  end
  local emitter = args.emitterPosition
  if type(emitter) ~= "string" or EMITTER_POSITIONS[emitter] ~= true then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " emits from a known battler effect slot", 0)
  end
  local scene = checkScene(services, kind)
  checkEffectScene(scene, kind)
  local staged = {}
  stageLease(kind, resource, services, staged)
  local random = checkRandom(context, kind)
  -- Occurrence leases are typed: the holder returns the staged path
  -- beside its decoded record for non-texture kinds, so only the
  -- decoded record may be read as emitter state. A bare path or a
  -- texture lease never masquerades as a particle archive here.
  local lease = staged[1].lease --[[@as table<string, unknown>]]
  local leaseKind = type(lease) == "table" and lease.kind or nil
  if leaseKind ~= "particle" and leaseKind ~= "particle-emitter" then
    releaseStaged(staged)
    error(
      "BATTLE_EFFECT_TASK_MALFORMED: kind "
        .. kind
        .. " stages a typed particle lease for resource "
        .. resource
        .. ", not "
        .. tostring(leaseKind),
      0
    )
  end
  local payload = type(lease) == "table" and lease.data or nil
  if payload == nil then
    releaseStaged(staged)
    error(
      "BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " stages decoded particle records for resource " .. resource,
      0
    )
  end
  local center = EMITTER_CENTERS[emitter]
  assert(center ~= nil, "particle emissions stage over a known effect slot")
  local streams = {}
  if leaseKind == "particle" and isNormalizedArchive(payload) then
    for _, record in ipairs(payload.emitters) do
      if not isNormalizedEmitter(record) then
        releaseStaged(staged)
        error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " simulates normalized emitters", 0)
      end
      local drawable = nil
      if type(record.textureKey) == "string" then
        stageLease(kind, record.textureKey, services, staged)
        drawable = staged[#staged].lease
      end
      if drawable ~= nil then
        checkDrawableField(drawable.width, tostring(record.textureKey))
        checkDrawableField(drawable.height, tostring(record.textureKey))
        if type(drawable.rgba8888) ~= "string" or #drawable.rgba8888 ~= drawable.width * drawable.height * 4 then
          releaseStaged(staged)
          error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " draws exact staged drawables", 0)
        end
      end
      streams[#streams + 1] = particleStream(record, drawable, center)
    end
  elseif leaseKind == "particle-emitter" and isNormalizedEmitter(payload) then
    local drawable = nil
    if type(payload.textureKey) == "string" then
      stageLease(kind, payload.textureKey, services, staged)
      drawable = staged[#staged].lease
    end
    if drawable ~= nil then
      checkDrawableField(drawable.width, tostring(payload.textureKey))
      checkDrawableField(drawable.height, tostring(payload.textureKey))
      if type(drawable.rgba8888) ~= "string" or #drawable.rgba8888 ~= drawable.width * drawable.height * 4 then
        releaseStaged(staged)
        error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " draws exact staged drawables", 0)
      end
    end
    streams[#streams + 1] = particleStream(payload, drawable, center)
  else
    releaseStaged(staged)
    error(
      "BATTLE_EFFECT_TASK_MALFORMED: kind "
        .. kind
        .. " stages normalized particle records for resource "
        .. resource
        .. ", not "
        .. tostring(leaseKind)
        .. " data",
      0
    )
  end
  return setmetatable({
    _scene = scene,
    _staged = staged,
    _resource = resource,
    _emitter = emitter,
    _random = random,
    _center = center,
    _streams = streams,
    _effectIds = {},
    _state = "pending",
    _cancelReason = nil,
    _disposed = false,
  }, BattleParticleContinuation)
end

-- Releases every owned sprite record and every staged lease exactly once.
---@param self BattleParticleContinuation
local function teardownParticle(self)
  for id in pairs(self._effectIds) do
    self._effectIds[id] = nil
    self._scene.releaseEffect(self._scene, id)
  end
  releaseStaged(self._staged)
end

---@param self BattleParticleContinuation
---@param stream table<string, unknown> emitter stream behind spawning
local function spawnParticleSprites(self, stream)
  local drawable = stream.drawable --[[@as table<string, unknown>?]]
  local assetKey = nil
  local width, height = 32, 32
  if drawable ~= nil then
    assetKey = stream.assetKey
    width = drawable.width --[[@as integer]]
    height = drawable.height --[[@as integer]]
  else
    assetKey = self._resource
  end
  for _ = 1, stream.count do
    local id = publishEffect(
      self._scene,
      self._resource,
      stagedPicture(assetKey, self._emitter, stream.center.x, stream.center.y, 1, width, height)
    )
    self._effectIds[id] = true
    stream.sprites[#stream.sprites + 1] = { id = id, born = stream.age }
  end
end

-- Advances one source tick: every emitter draws its fixed visual count
-- so the same seed draws the same sequence at any host schedule, then
-- spawns, moves, and retires its sprites on the native completion
-- boundary. Reads never advance: only this entry point consumes the
-- occurrence-local stream.
---@param self BattleParticleContinuation
---@param tick table<string, unknown>? source tick under advancement
function BattleParticleContinuation:stepSourceTick(tick)
  local _ = tick
  if self._disposed or self._state == "complete" or self._state == "cancelled" then
    return
  end
  self._state = "running"
  local random = self._random --[[@as fun(bound: integer): integer]]
  local done = true
  for _, stream in ipairs(self._streams) do
    stream.age = stream.age + 1
    if stream.jitter then
      stream.jitterX = random(PARTICLE_JITTER_BOUND) - 4
      stream.jitterY = random(PARTICLE_JITTER_BOUND) - 4
    end
    if stream.age <= stream.active and (stream.age - 1) % (stream.every + 1) == 0 then
      if stream.drawable ~= nil then
        spawnParticleSprites(self, stream)
      end
    end
    local sprites = {}
    for _, sprite in ipairs(stream.sprites) do
      local age = stream.age - sprite.born
      if age >= stream.life then
        self._effectIds[sprite.id] = nil
        self._scene.releaseEffect(self._scene, sprite.id)
      else
        local alpha = 1
        if stream.fade then
          alpha = (stream.life - age) / stream.life
        end
        local width, height = 32, 32
        local drawable = stream.drawable --[[@as table<string, unknown>?]]
        if drawable ~= nil then
          width = drawable.width --[[@as integer]]
          height = drawable.height --[[@as integer]]
        end
        self._scene.setEffectPicture(
          self._scene,
          sprite.id,
          stagedPicture(
            stream.drawable ~= nil and stream.assetKey or self._resource,
            self._emitter,
            math.floor(
              stream.center.x
                + stream.offsetX
                + stream.velocityX * age
                + stream.gravityX * age * age / 2
                + stream.jitterX
            ),
            math.floor(
              stream.center.y
                + stream.offsetY
                + stream.velocityY * age
                + stream.gravityY * age * age / 2
                + stream.jitterY
            ),
            alpha,
            width,
            height
          )
        )
        sprites[#sprites + 1] = sprite
      end
    end
    stream.sprites = sprites
    if stream.age <= stream.active or #stream.sprites > 0 then
      done = false
    end
  end
  if done then
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

-- Invisible emitter path driver behind the battler-path particle
-- callbacks: the visible sprites for these paths come from the
-- continuation family, while this task owns only the compiled
-- interpolation timing and retires on its own completion boundary.
-- It publishes no scene records and holds no leases, so cancellation
-- and disposal only move its run state.
---@class BattleEmitterPathTask
---@field _kind string emitter path kind behind the run
---@field _duration integer source ticks behind completion
---@field _ticks integer source ticks advanced
---@field _state string pending, running, complete, or cancelled
---@field _cancelReason string? last cancellation cause under diagnosis
---@field _disposed boolean release has run
local BattleEmitterPathTask = {}
BattleEmitterPathTask.__index = BattleEmitterPathTask

---@param kind string emitter path kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@return integer source ticks behind completion
local function emitterPathDuration(kind, args)
  local parameters = args.parameters
  if type(parameters) ~= "table" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " carries its path operands as a record", 0)
  end
  local completionLimit = parameters.completionLimit
  if type(completionLimit) ~= "number" or completionLimit % 1 ~= 0 or completionLimit < 1 then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " completes on a positive completion limit", 0)
  end
  if kind == BattleEffectTasks.EMITTER_BATTLER_PATH_KIND then
    local interpolation = parameters.interpolationDurationTicks
    if type(interpolation) == "number" and interpolation % 1 == 0 and interpolation > 0 then
      return math.floor(interpolation)
    end
    return math.floor(completionLimit)
  end
  local duration = parameters.durationTicks
  if type(duration) == "number" and duration % 1 == 0 and duration > 0 then
    return math.floor(duration)
  end
  return math.floor(completionLimit)
end

---@param kind string emitter path kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> scene, audio, and resource collaborators
---@return BattleEmitterPathTask runnable emitter path task
local function newEmitterPathTask(kind, args, context, services)
  local _ = context
  if type(services) ~= "table" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " constructs without its services record", 0)
  end
  return setmetatable({
    _kind = kind,
    _duration = emitterPathDuration(kind, args),
    _ticks = 0,
    _state = "pending",
    _cancelReason = nil,
    _disposed = false,
  }, BattleEmitterPathTask)
end

---@param self BattleEmitterPathTask
---@param tick table<string, unknown>? source tick under advancement
function BattleEmitterPathTask:stepSourceTick(tick)
  local _ = tick
  if self._disposed or self._state == "complete" or self._state == "cancelled" then
    return
  end
  self._state = "running"
  self._ticks = self._ticks + 1
  if self._ticks >= self._duration then
    self._state = "complete"
  end
end

---@param self BattleEmitterPathTask
---@return string
function BattleEmitterPathTask:status()
  assert(VALID_TASK_STATES[self._state] == true, "emitter path tasks report a known run state")
  return self._state
end

---@param self BattleEmitterPathTask
---@param reason string cancellation cause under diagnosis
function BattleEmitterPathTask:cancel(reason)
  if self._state == "complete" then
    return
  end
  self._state = "cancelled"
  self._cancelReason = reason
end

---@param self BattleEmitterPathTask
function BattleEmitterPathTask:dispose()
  self._disposed = true
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
    -- A compiled duration drives the animated reveal; spawns without one
    -- retire synchronously only for verified marker kinds, and fail every
    -- other kind closed. Timed reveals always interpolate below.
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
  if duration == nil and SYNCHRONOUS_MARKER_KINDS[kind] ~= true then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " retires only on compiled timing operands", 0)
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
-- zero source offset applies no shift at all. Marker-kind show spawns carry
-- no compiled timing at all: the native show applies synchronously and
-- program-level waits own the timing, so the marker retires
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
-- the producer vocabulary is admitted, and unknown kinds fail closed.
-- Particle emitter families carry their own bodies above.
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
  ["pokemon-picture-attacker-dash-afterimages"] = true,
  ["pokemon-picture-battle-palette-fade-cycle"] = true,
  ["pokemon-picture-battler-pair-scale-transition"] = true,
  ["pokemon-picture-cyclic-two-phase-position-transition"] = true,
  ["pokemon-picture-defender-knockback"] = true,
  ["pokemon-picture-double-sprite-scale-settle"] = true,
  ["pokemon-picture-entry-offset-transition"] = true,
  ["pokemon-picture-five-phase-affine-size-transition"] = true,
  ["pokemon-picture-four-sprite-wave-transition"] = true,
  ["pokemon-picture-height-position-transition"] = true,
  ["pokemon-picture-linear-offscreen-transition"] = true,
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
  ["pokemon-picture-reset-position-transition"] = true,
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
---@field _family string source control law behind per-tick writes
---@field _activation table<string, unknown>? combatant and activation pair behind the owned picture
---@field _activations table<integer, table<string, unknown>> owned activations behind picture writes
---@field _parameters table<string, unknown> copied compiled operands behind per-tick writes
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
---@field _amplitude integer? seeded motion pixels behind randomized writes
---@field _centerX integer staged picture center behind randomized writes
---@field _centerY integer staged picture center behind randomized writes
---@field _dashReach integer? dash pixels behind the out-leg reach
---@field _dashSign integer? dash direction behind sided motion
---@field _phaseFirst integer? first phase ticks behind two-phase writes
---@field _phaseReturn integer? return phase ticks behind two-phase writes
---@field _repeatCount integer? compiled repeats behind palette pulses
---@field _targetColor integer? compiled target color behind palette pulses
---@field _vanishInterval integer? compiled interval ticks behind visibility toggles
---@field _ticks integer source ticks advanced
---@field _duration integer? source ticks behind completion, absent for synchronous markers
---@field _state string pending, running, complete, or cancelled
---@field _cancelReason string? last cancellation cause under diagnosis
---@field _disposed boolean release has run
local BattleNativeVisualTask = {}
BattleNativeVisualTask.__index = BattleNativeVisualTask

-- Own-side exit signs behind directed offscreen motion: player-side
-- battlers (even source side types) exit left, foe-side battlers (odd
-- source side types) exit right, matching the fixed product layout the
-- emitter centers already assume.
local OWN_SIDE_SIGNS = {
  [0] = -1,
  [2] = -1,
  [4] = -1,
  [1] = 1,
  [3] = 1,
  [5] = 1,
}

-- Picture/sprite task kinds owning both selected activations at once.
-- Every other family owns the single planned activation, or nothing
-- when the spawn resolves none.
local PAIR_TASK_KINDS = {
  ["pokemon-picture-battler-pair-scale-transition"] = true,
  ["pokemon-picture-two-battler-crossing-motion"] = true,
  ["pokemon-picture-selected-pair-transition"] = true,
  ["pokemon-picture-managed-sprite-affine-pair-transition"] = true,
}

-- Selects the source control law behind a picture/sprite kind. The timed
-- holds below keep their compiled boundary with no patch, each pinned to
-- its producer shape (romdump/src/config/BattleAnimationSources.lua,
-- resolveBattleAnimationCallback): the defender knockback hold is selector
-- 48, DefenderKnockback in battle_anim_effects.c, which reads no source
-- words and runs its 29 ticks; the sinusoidal hold is selector 10, which
-- lowers oscillation cycles with a duration but no amplitude operand; the
-- selected-position hold is selector 77, which lowers target, basis, and
-- duration with no magnitude operand. Without compiled placement operands
-- the shared motion body keeps those documented timing holds.
---@param kind string task kind under classification
---@return string family behind per-tick writes
local function familyFor(kind)
  if kind == "pokemon-picture-attacker-dash-afterimages" then
    return "dash"
  end
  if PAIR_TASK_KINDS[kind] == true then
    return "pair"
  end
  if kind == "pokemon-picture-cyclic-two-phase-position-transition" then
    return "cyclic"
  end
  if kind == "pokemon-picture-repeated-palette-fade" then
    return "palette-pulse"
  end
  if kind == "pokemon-picture-paired-position-interpolation" then
    return "paired"
  end
  if kind == "pokemon-picture-repeated-vanish-transition" then
    return "vanish"
  end
  if string.find(kind, "randomized", 1, true) ~= nil then
    return "randomized"
  end
  if
    string.find(kind, "affine", 1, true) ~= nil
    or string.find(kind, "rotation", 1, true) ~= nil
    or string.find(kind, "scale", 1, true) ~= nil
  then
    return "affine"
  end
  if
    string.find(kind, "multi-sprite", 1, true) ~= nil
    or string.find(kind, "four-sprite", 1, true) ~= nil
    or string.find(kind, "three-sprite", 1, true) ~= nil
    or string.find(kind, "double-sprite", 1, true) ~= nil
    or string.find(kind, "oam-animation", 1, true) ~= nil
    or string.find(kind, "sprite-animation-lifecycle", 1, true) ~= nil
    or string.find(kind, "relative-sprite-path", 1, true) ~= nil
  then
    return "multi"
  end
  return "motion"
end

---@param kind string task kind under classification
---@return boolean affine true for pair kinds driven by affine operands
local function pairUsesAffine(kind)
  return string.find(kind, "affine", 1, true) ~= nil
    or string.find(kind, "rotation", 1, true) ~= nil
    or string.find(kind, "scale", 1, true) ~= nil
end

-- Converts a compiled scale operand to the scene affine factor:
-- integer source words ride 8.8 fixed point, floats pass through.
---@param value unknown compiled scale operand under conversion
---@return number? affine factor, absent for non-numeric operands
local function affineScale(value)
  if type(value) ~= "number" or value ~= value then
    return nil
  end
  if value % 1 == 0 then
    return value / 256
  end
  return value
end

-- Resolves the dash reach and direction from the occurrence slot
-- geometry: the attacker dashes halfway toward its first target along
-- the battlefield axis. Both slots are required; an unaddressed dash
-- cannot aim and fails closed with its kind identity.
---@param context table<string, unknown> occurrence-bound playback context
---@param kind string task kind under construction
---@return integer reach in native pixels, always positive
---@return integer direction +1 toward increasing X, -1 otherwise
local function dashVector(context, kind)
  local topology = type(context) == "table" and context.topology or nil
  local attacker = type(topology) == "table" and topology.attacker or nil
  local targets = type(topology) == "table" and topology.targets or nil
  local from = type(attacker) == "table" and EMITTER_CENTERS[attacker.slot] or nil
  local first = type(targets) == "table" and targets[1] or nil
  local onto = type(first) == "table" and EMITTER_CENTERS[first.slot] or nil
  if from == nil or onto == nil then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " dashes between known occurrence slots", 0)
  end
  local span = onto.x - from.x
  if span == 0 then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " dashes between distinct occurrence slots", 0)
  end
  local direction = span > 0 and 1 or -1
  return math.max(1, math.floor(math.abs(span) / 2)), direction
end

-- Resolves a directed offscreen offset from the occurrence side type:
-- the run slides its activation away from the battlefield center over
-- the compiled distance. Anything unaddressed stays loud instead of
-- guessing an exit direction from a missing topology.
---@param parameters table<string, unknown> compiled task parameters carrying the offscreen distance
---@param activation table<string, unknown>? combatant and activation pair behind the owned picture
---@param context table<string, unknown> occurrence-bound playback context carrying the visual topology
---@param kind string task kind under construction
---@return table<string, unknown> effective parameters with the directed offset
local function directedOffscreenParameters(parameters, activation, context, kind)
  local distance = parameters.offscreenDistance
  if not isPositiveInt(distance) then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " directs its offscreen run by a positive distance", 0)
  end
  if type(activation) ~= "table" or type(activation.combatant) ~= "number" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " exits the side of a resolved activation", 0)
  end
  local topology = context.topology
  if type(topology) ~= "table" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " exits the side of the occurrence topology", 0)
  end
  local candidates = {}
  if type(topology.attacker) == "table" then
    candidates[#candidates + 1] = topology.attacker
  end
  if type(topology.targets) == "table" then
    for _, target in ipairs(topology.targets) do
      candidates[#candidates + 1] = target
    end
  end
  local sign = nil
  for _, candidate in ipairs(candidates) do
    if type(candidate) == "table" and candidate.combatant == activation.combatant then
      local sideType = candidate.sideType
      if type(sideType) == "number" and OWN_SIDE_SIGNS[sideType] ~= nil then
        sign = OWN_SIDE_SIGNS[sideType]
      end
      break
    end
  end
  if sign == nil then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " exits the side of a known occurrence side type", 0)
  end
  local directed = {}
  for field, value in pairs(parameters) do
    directed[field] = value
  end
  directed.offsetX = sign * distance
  return directed
end

-- Interpolates the affine rotation/scale operands over one tick:
-- rotation follows the compiled angle pair, scale follows the compiled
-- start/end pair (8.8 fixed words or floats). Absent operands hold.
---@param self BattleNativeVisualTask visual task under advancement
---@param progress number completed fraction in 0..1
---@return table<string, unknown>? picture overlay behind the tick
local function affinePatchFor(self, progress)
  local patch = {}
  local parameters = self._parameters
  local fromAngle = parameters.startAngle
  local toAngle = parameters.targetAngle
  if type(fromAngle) == "number" and type(toAngle) == "number" then
    patch.rotationZ = clampRotationAngle(fromAngle + (toAngle - fromAngle) * progress)
  end
  local fromScale = affineScale(parameters.scaleStart)
  local toScale = affineScale(parameters.scaleEnd)
  if fromScale ~= nil and toScale ~= nil then
    local first = self._phaseFirst
    local second = self._phaseReturn
    if first ~= nil and second ~= nil and (first > 0 or second > 0) then
      local tick = self._ticks
      if tick <= first then
        local phase = first > 0 and tick / first or 1
        patch.scaleX = fromScale + (toScale - fromScale) * phase
        patch.scaleY = fromScale + (toScale - fromScale) * phase
      else
        local phase = second > 0 and (tick - first) / second or 1
        if phase > 1 then
          phase = 1
        end
        patch.scaleX = toScale + (fromScale - toScale) * phase
        patch.scaleY = toScale + (fromScale - toScale) * phase
      end
    else
      patch.scaleX = fromScale + (toScale - fromScale) * progress
      patch.scaleY = fromScale + (toScale - fromScale) * progress
    end
  end
  if next(patch) == nil then
    return nil
  end
  return patch
end

-- Interpolates the cyclic two-phase offsets: the first leg runs from
-- the compiled start to the end, the return leg runs back.
---@param self BattleNativeVisualTask visual task under advancement
---@return table<string, unknown>? picture overlay behind the tick
local function cyclicPatchFor(self)
  local parameters = self._parameters
  if
    type(parameters.startX) ~= "number"
    or type(parameters.endX) ~= "number"
    or type(parameters.startY) ~= "number"
    or type(parameters.endY) ~= "number"
  then
    return nil
  end
  local first = self._phaseFirst or 0
  local fromX = clampPictureOffset(parameters.startX)
  local toX = clampPictureOffset(parameters.endX)
  local fromY = clampPictureOffset(parameters.startY)
  local toY = clampPictureOffset(parameters.endY)
  local currentX, currentY = fromX + 0.0, fromY + 0.0
  if self._ticks <= first then
    local phase = first > 0 and self._ticks / first or 1
    currentX = fromX + (toX - fromX) * phase
    currentY = fromY + (toY - fromY) * phase
  else
    local second = self._phaseReturn or 0
    local phase = second > 0 and (self._ticks - first) / second or 1
    if phase > 1 then
      phase = 1
    end
    currentX = toX + (fromX - toX) * phase
    currentY = toY + (fromY - toY) * phase
  end
  return {
    pictureXOffset2 = wrapPictureByte(currentX),
    pictureYOffset = clampPictureOffset(currentY),
  }
end

-- Pulses the palette overlay through one full-range triangle per
-- compiled repeat: each slice rises from zero to the native maximum
-- and back, carrying the compiled target color.
---@param self BattleNativeVisualTask visual task under advancement
---@return table<string, unknown>? picture overlay behind the tick
local function pulsePatchFor(self)
  local repeatCount = self._repeatCount
  local targetColor = self._targetColor
  local duration = self._duration
  if repeatCount == nil or targetColor == nil or duration == nil or duration < 1 then
    return nil
  end
  local slice = duration / repeatCount
  if slice < 1 then
    return nil
  end
  local position = ((self._ticks - 1) % slice) / slice * 2
  local intensity = position <= 1 and position * 16 or (2 - position) * 16
  return {
    paletteFade = {
      start = math.floor(intensity),
      finish = math.floor(intensity),
      framesPer = 1,
      targetColor = targetColor,
    },
  }
end

-- Interpolates the paired picture from its origin to the compiled
-- endpoint; the reversed source flag swaps the two ends.
---@param self BattleNativeVisualTask visual task under advancement
---@param progress number completed fraction in 0..1
---@return table<string, unknown>? picture overlay behind the tick
local function pairedPatchFor(self, progress)
  local parameters = self._parameters
  if type(parameters.endpointX) ~= "number" or type(parameters.endpointY) ~= "number" then
    return nil
  end
  local fromX, toX = 0, clampPictureOffset(parameters.endpointX)
  local fromY, toY = 0, clampPictureOffset(parameters.endpointY)
  if parameters.reverseEndpoints == true then
    fromX, toX, fromY, toY = toX, fromX, toY, fromY
  end
  if fromX == toX and fromY == toY then
    return nil
  end
  local patch = {}
  if fromX ~= toX then
    patch.pictureXOffset2 = wrapPictureByte(fromX + (toX - fromX) * progress)
  end
  if fromY ~= toY then
    patch.pictureYOffset = clampPictureOffset(fromY + (toY - fromY) * progress)
  end
  if next(patch) == nil then
    return nil
  end
  return patch
end

-- Toggles picture visibility on the compiled interval.
---@param self BattleNativeVisualTask visual task under advancement
---@return table<string, unknown>? picture overlay behind the tick
local function vanishPatchFor(self)
  local interval = self._vanishInterval
  if interval == nil or interval < 1 then
    return nil
  end
  return { pictureVisible = (math.floor((self._ticks - 1) / interval) % 2 == 0) }
end

-- Advances the multi-sprite formation across its compiled endpoint;
-- formations without a compiled endpoint hold their activation.
---@param self BattleNativeVisualTask visual task under advancement
---@param progress number completed fraction in 0..1
---@return table<string, unknown>? picture overlay behind the tick
local function multiPatchFor(self, progress)
  local parameters = self._parameters
  local endX = type(parameters.endpointX) == "number" and clampPictureOffset(parameters.endpointX) or nil
  local endY = type(parameters.endpointY) == "number" and clampPictureOffset(parameters.endpointY) or nil
  if endX == nil and type(parameters.spriteSpacingX) == "number" then
    endX = clampPictureOffset(parameters.spriteSpacingX)
  end
  if endY == nil and type(parameters.spriteSpacingY) == "number" then
    endY = clampPictureOffset(parameters.spriteSpacingY)
  end
  if endX == nil and endY == nil then
    return nil
  end
  local patch = {}
  if endX ~= nil and endX ~= 0 then
    patch.pictureXOffset2 = wrapPictureByte(endX * progress)
  end
  if endY ~= nil and endY ~= 0 then
    patch.pictureYOffset = clampPictureOffset(endY * progress)
  end
  if next(patch) == nil then
    return nil
  end
  return patch
end

-- Interpolates the approach/settle offset pair: the first leg runs
-- from the origin to the approach offset, the second settles onward.
---@param self BattleNativeVisualTask visual task under advancement
---@return table<string, unknown>? picture overlay behind the tick
local function approachPatchFor(self)
  local parameters = self._parameters
  if type(parameters.approachOffset) ~= "number" or type(parameters.settleOffset) ~= "number" then
    return nil
  end
  local approach = self._phaseFirst or 0
  local approachX = clampPictureOffset(parameters.approachOffset)
  local settleX = clampPictureOffset(parameters.settleOffset)
  local current = approachX + 0.0
  if self._ticks <= approach then
    current = approach > 0 and approachX * (self._ticks / approach) or approachX
  else
    local settle = self._phaseReturn or 0
    local phase = settle > 0 and (self._ticks - approach) / settle or 1
    if phase > 1 then
      phase = 1
    end
    current = approachX + (settleX - approachX) * phase
  end
  return { pictureXOffset2 = wrapPictureByte(current) }
end

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

-- Background source families with dedicated bodies: the generic visual
-- task above only interpolates picture placement and viewport totals,
-- which cannot express the power-selected four-picture transition, the
-- alternating sweep, the scanline sine wave, or the OAM blend register
-- program. Each body below owns exactly its compiled operands and its
-- scene writes, stages no leases, and restores its writes on completion
-- and cancellation.

-- Resolves the battler pictures one background transition owns from the
-- compiled picture sets and the frozen occurrence topology. The
-- all-positions set names every live battler; every other set keeps the
-- producer's attacker/target partition. Unknown sets fail instead of
-- guessing a picture from an unaddressed slot.
---@param pictureSets table<integer, string> compiled picture sets behind the transition
---@param context table<string, unknown> occurrence-bound playback context
---@param kind string task kind under construction
---@return table<integer, table<string, unknown>> owned combatant and activation pairs
local function backgroundActivations(pictureSets, context, kind)
  local topology = type(context) == "table" and context.topology or nil
  local attacker = type(topology) == "table" and topology.attacker or nil
  local targets = type(topology) == "table" and topology.targets or nil
  local wantAttacker, wantTargets = false, false
  for _, set in ipairs(pictureSets) do
    if set == "all-battler-positions" then
      wantAttacker, wantTargets = true, true
    elseif ATTACKER_PICTURE_NAMES[set] == true then
      wantAttacker = true
    elseif TARGET_PICTURE_NAMES[set] == true then
      wantTargets = true
    else
      error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " pictures a known battler set, not " .. tostring(set), 0)
    end
  end
  local activations = {}
  if wantAttacker then
    if type(attacker) ~= "table" or type(attacker.combatant) ~= "number" then
      error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " pictures its occurrence attacker", 0)
    end
    activations[#activations + 1] = { combatant = attacker.combatant, activation = attacker.activation }
  end
  if wantTargets then
    if type(targets) ~= "table" or #targets < 1 then
      error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " pictures its occurrence targets", 0)
    end
    for _, target in ipairs(targets) do
      if type(target) == "table" and type(target.combatant) == "number" and #activations < 4 then
        activations[#activations + 1] = { combatant = target.combatant, activation = target.activation }
      end
    end
  end
  if #activations < 1 then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " pictures at least one occurrence battler", 0)
  end
  return activations
end

-- Selects the source power profile behind the four-picture transition:
-- an exact ladder match wins, otherwise the compiled default covers
-- present-but-unmatched powers. A missing runtime power or an
-- unmatched power without a default fails naming the kind and power;
-- no numeric stand-in ever selects a profile.
---@param parameters table<string, unknown> compiled transition operands
---@param context table<string, unknown> occurrence-bound playback context
---@param kind string task kind under construction
---@return integer selected source profile behind the visible frames
local function movePowerProfile(parameters, context, kind)
  local event = type(context) == "table" and context.event or nil
  local move = type(event) == "table" and event.move or nil
  local power = type(move) == "table" and move.power or nil
  if type(power) ~= "number" or power % 1 ~= 0 or power < 0 or power > 65535 then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " requires the executed move power", 0)
  end
  local rows = parameters.profileByMovePower
  if type(rows) ~= "table" or #rows < 1 then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " selects its profile from a compiled ladder", 0)
  end
  for _, row in ipairs(rows) do
    if type(row) ~= "table" then
      error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " selects its profile from ladder rows", 0)
    end
    if row.movePower == power then
      if type(row.profile) ~= "number" or row.profile % 1 ~= 0 or row.profile < 0 then
        error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " selects a usable source profile", 0)
      end
      return row.profile
    end
    if type(row.movePower) ~= "number" or row.movePower % 1 ~= 0 then
      error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " selects its profile from ladder rows", 0)
    end
  end
  local fallback = parameters.defaultProfile
  if type(fallback) ~= "number" or fallback % 1 ~= 0 or fallback < 0 then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " has no profile for executed power " .. power, 0)
  end
  return fallback
end

---@class BattleMovePowerProfileTask
---@field _scene table<string, unknown> scene behind owned picture overlays
---@field _kind string task kind behind the run
---@field _activations table<integer, table<string, unknown>> owned battler pictures behind the sweep
---@field _reach integer profile-scaled sweep reach in native pixels
---@field _duration integer source ticks behind completion
---@field _ticks integer source ticks advanced
---@field _state string pending, running, complete, or cancelled
---@field _disposed boolean release has run
local BattleMovePowerProfileTask = {}
BattleMovePowerProfileTask.__index = BattleMovePowerProfileTask

-- Owns one power-selected four-picture transition: the compiled ladder
-- resolves the executed power to its authored profile, and each owned
-- battler picture sweeps a staggered out-and-back arc scaled by that
-- profile. Distinct ladder powers select distinct reaches, so the
-- visible frames differ instead of sharing one generic motion.
---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> scene, audio, and resource collaborators
---@return table<string, unknown> runnable profile task
local function newMovePowerProfileTask(kind, args, context, services)
  checkVisualArgs(args, kind)
  local scene = checkScene(services, kind)
  if type(scene.applyTaskPicturePatch) ~= "function" or type(scene.removeTaskPicturePatch) ~= "function" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " pictures through the scene overlay seam", 0)
  end
  local parameters = args.parameters
  if type(parameters) ~= "table" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " carries its parameters as a record", 0)
  end
  if not isPositiveInt(parameters.durationTicks) then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " sweeps over a compiled duration", 0)
  end
  local pictureSets = parameters.pictureSets
  if type(pictureSets) ~= "table" or #pictureSets < 1 then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " sweeps its compiled picture sets", 0)
  end
  local profile = movePowerProfile(parameters, context or {}, kind)
  local activations = backgroundActivations(pictureSets, context or {}, kind)
  return setmetatable({
    _scene = scene,
    _kind = kind,
    _activations = activations,
    _reach = profile * 8,
    _duration = parameters.durationTicks,
    _ticks = 0,
    _state = "pending",
    _disposed = false,
  }, BattleMovePowerProfileTask)
end

-- Writes one staggered profile tick: picture i sweeps its quarter of
-- the compiled duration, rising to the profile reach and settling
-- back, so every ladder profile paints its own arc heights.
---@param self BattleMovePowerProfileTask profile task under advancement
local function writeProfileTick(self)
  local window = self._duration / 4
  for index, activation in ipairs(self._activations) do
    local local_ = (self._ticks - (index - 1) * window) / window
    if local_ < 0 then
      local_ = 0
    end
    if local_ > 1 then
      local_ = 1
    end
    local arc = math.sin(math.pi * local_)
    self._scene.applyTaskPicturePatch(self._scene, self, activation, {
      pictureXOffset2 = wrapPictureByte(self._reach * arc),
      pictureYOffset = clampPictureOffset(math.floor(self._reach / 4) * arc),
    })
  end
end

-- Drops every owned picture overlay exactly while this task still owns
-- its slot, so a newer overlay is never restored away.
---@param self BattleMovePowerProfileTask profile task under teardown
local function teardownProfile(self)
  for _, activation in ipairs(self._activations) do
    self._scene.removeTaskPicturePatch(self._scene, self, activation)
  end
end

---@param self BattleMovePowerProfileTask profile task under advancement
---@param tick table<string, unknown>? source tick under advancement
function BattleMovePowerProfileTask:stepSourceTick(tick)
  local _ = tick
  if self._disposed or self._state == "complete" or self._state == "cancelled" then
    return
  end
  self._state = "running"
  self._ticks = self._ticks + 1
  local ok, err = pcall(writeProfileTick, self)
  if not ok then
    teardownProfile(self)
    error(err, 0)
  end
  if self._ticks >= self._duration then
    self._state = "complete"
    teardownProfile(self)
  end
end

---@param self BattleMovePowerProfileTask
---@return string
function BattleMovePowerProfileTask:status()
  assert(VALID_TASK_STATES[self._state] == true, "profile tasks report a known run state")
  return self._state
end

---@param self BattleMovePowerProfileTask
---@param reason string cancellation cause under diagnosis
function BattleMovePowerProfileTask:cancel(reason)
  local _ = reason
  if self._state == "complete" then
    return
  end
  self._state = "cancelled"
  teardownProfile(self)
end

---@param self BattleMovePowerProfileTask
function BattleMovePowerProfileTask:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  teardownProfile(self)
end

---@class BattleViewportSweepTask
---@field _scene table<string, unknown> scene behind the owned viewport sweep
---@field _kind string task kind behind the run
---@field _sweep fun(tick: integer): table<string, integer> authored viewport behind the tick
---@field _duration integer source ticks behind completion
---@field _saved table<string, number> viewport snapshot behind owned-only restoration
---@field _last table<string, number>? last applied viewport behind owned-only restoration
---@field _applied boolean sweep has written the viewport
---@field _ticks integer source ticks advanced
---@field _state string pending, running, complete, or cancelled
---@field _disposed boolean release has run
local BattleViewportSweepTask = {}
BattleViewportSweepTask.__index = BattleViewportSweepTask

-- Owns one authored viewport sweep over the scene scroll seam: the
-- per-tick function carries the source control law, teardown restores
-- the saved viewport only while no newer sweep has moved it since.
---@param kind string task kind under construction
---@param duration integer source ticks behind completion
---@param sweep fun(tick: integer): table<string, integer> authored viewport behind the tick
---@param scene table<string, unknown> scene behind the sweep
---@return table<string, unknown> runnable sweep task
local function newViewportSweepTask(kind, duration, sweep, scene)
  local saved = scene.scroll(scene)
  return setmetatable({
    _scene = scene,
    _kind = kind,
    _sweep = sweep,
    _duration = duration,
    _saved = { x = saved.x, y = saved.y },
    _last = nil,
    _applied = false,
    _ticks = 0,
    _state = "pending",
    _disposed = false,
  }, BattleViewportSweepTask)
end

---@param self BattleViewportSweepTask sweep task under teardown
local function teardownSweep(self)
  if self._applied then
    self._applied = false
    if self._last ~= nil then
      local current = self._scene.scroll(self._scene)
      if current.x == self._last.x and current.y == self._last.y then
        self._scene.applyScrollPatch(self._scene, self._saved.x, self._saved.y)
      end
    end
    self._last = nil
  end
end

---@param self BattleViewportSweepTask sweep task under advancement
---@param tick table<string, unknown>? source tick under advancement
function BattleViewportSweepTask:stepSourceTick(tick)
  local _ = tick
  if self._disposed or self._state == "complete" or self._state == "cancelled" then
    return
  end
  self._state = "running"
  self._ticks = self._ticks + 1
  local ok, position = pcall(self._sweep, self._ticks)
  if not ok then
    teardownSweep(self)
    error(position, 0)
  end
  assert(type(position) == "table", "sweep laws answer their viewport position")
  local x = self._saved.x + (position.x or 0)
  local y = self._saved.y + (position.y or 0)
  local writeOk, writeErr = pcall(self._scene.applyScrollPatch, self._scene, x, y)
  if not writeOk then
    teardownSweep(self)
    error(writeErr, 0)
  end
  self._applied = true
  self._last = { x = x, y = y }
  if self._ticks >= self._duration then
    self._state = "complete"
    teardownSweep(self)
  end
end

---@param self BattleViewportSweepTask
---@return string
function BattleViewportSweepTask:status()
  assert(VALID_TASK_STATES[self._state] == true, "sweep tasks report a known run state")
  return self._state
end

---@param self BattleViewportSweepTask
---@param reason string cancellation cause under diagnosis
function BattleViewportSweepTask:cancel(reason)
  local _ = reason
  if self._state == "complete" then
    return
  end
  self._state = "cancelled"
  teardownSweep(self)
end

---@param self BattleViewportSweepTask
function BattleViewportSweepTask:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  teardownSweep(self)
end

-- Owns one alternating background scroll: each compiled phase sweeps
-- toward its extreme over the compiled direction ticks, holds the
-- extreme over the compiled phase interval, then reverses. The phase
-- count and direction ticks come only from the producer operands.
---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param services table<string, unknown> scene, audio, and resource collaborators
---@return table<string, unknown> runnable sweep task
local function newAlternatingScrollTask(kind, args, _, services)
  checkVisualArgs(args, kind)
  local scene = checkScene(services, kind)
  if type(scene.scroll) ~= "function" or type(scene.applyScrollPatch) ~= "function" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " sweeps through the scene scroll seam", 0)
  end
  local parameters = args.parameters
  if type(parameters) ~= "table" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " carries its parameters as a record", 0)
  end
  local perDirection = parameters.ticksPerDirection
  local changes = parameters.directionChanges
  if not isPositiveInt(perDirection) or not isPositiveInt(changes) then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " alternates over compiled phase ticks", 0)
  end
  local interval = parameters.phaseIntervalTicks
  if interval ~= nil and (type(interval) ~= "number" or interval % 1 ~= 0 or interval < 0) then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " holds its extremes over a phase interval", 0)
  end
  interval = interval or 0
  local offsetX, offsetY = parameters.horizontalOffset, parameters.verticalOffset
  if type(offsetX) ~= "number" or type(offsetY) ~= "number" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " alternates its compiled offsets", 0)
  end
  local cycle = perDirection + interval
  local function sweep(tick)
    local phase = math.floor((tick - 1) / cycle)
    local within = (tick - 1) % cycle
    local sign = phase % 2 == 0 and 1 or -1
    local previous = phase % 2 == 0 and -sign or sign
    local fromX, fromY
    if phase == 0 then
      fromX, fromY = 0, 0
    else
      fromX, fromY = previous * offsetX, previous * offsetY
    end
    local toX, toY = sign * offsetX, sign * offsetY
    local progress = within < perDirection and (within + 1) / perDirection or 1
    return {
      x = math.floor(fromX + (toX - fromX) * progress),
      y = math.floor(fromY + (toY - fromY) * progress),
    }
  end
  return newViewportSweepTask(kind, changes * cycle, sweep, scene)
end

-- Owns one scanline sine-wave sweep: the viewport rides a full sine
-- cycle over the compiled duration at the minimal one-pixel native
-- amplitude the wave law can express, since the normalized program
-- carries no amplitude operand. Completion restores the saved viewport.
---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param services table<string, unknown> scene, audio, and resource collaborators
---@return table<string, unknown> runnable sweep task
local function newSineScrollTask(kind, args, _, services)
  checkVisualArgs(args, kind)
  local scene = checkScene(services, kind)
  if type(scene.scroll) ~= "function" or type(scene.applyScrollPatch) ~= "function" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " sweeps through the scene scroll seam", 0)
  end
  local parameters = args.parameters
  if type(parameters) ~= "table" or not isPositiveInt(parameters.durationTicks) then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " rides its compiled duration", 0)
  end
  local duration = parameters.durationTicks
  local function sweep(tick)
    return { x = 0, y = math.floor(math.sin(2 * math.pi * tick / duration) + 0.5) }
  end
  return newViewportSweepTask(kind, duration, sweep, scene)
end

---@class BattleBlendCoefficientTask
---@field _scene table<string, unknown> scene behind the owned register overlay
---@field _kind string task kind behind the run
---@field _fromA number compiled start coefficient behind the A channel
---@field _toA number compiled target coefficient behind the A channel
---@field _fromB number compiled start coefficient behind the B channel
---@field _toB number compiled target coefficient behind the B channel
---@field _slots table<integer, string>? compiled sprite context slots behind the blend
---@field _duration integer source ticks behind completion
---@field _ticks integer source ticks advanced
---@field _state string pending, running, complete, or cancelled
---@field _disposed boolean release has run
local BattleBlendCoefficientTask = {}
BattleBlendCoefficientTask.__index = BattleBlendCoefficientTask

-- Owns one sprite blend-alpha program: the compiled A/B coefficient
-- pairs interpolate linearly over the compiled duration and land in
-- the task-owned register overlay the scene carries for source blend
-- hardware. No invented pixels: the register values are the effect.
-- Completion holds the final pair the way hardware holds BLDALPHA until
-- teardown or reset overwrites it; the fact-enrichment layer consumes
-- the overlay as per-sprite alpha, and cancel/dispose still restore.
---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param services table<string, unknown> scene, audio, and resource collaborators
---@return table<string, unknown> runnable blend task
local function newBlendCoefficientTask(kind, args, _, services)
  checkVisualArgs(args, kind)
  local scene = checkScene(services, kind)
  if type(scene.applyTaskScalarPatch) ~= "function" or type(scene.removeTaskScalarPatch) ~= "function" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " blends through the scene register seam", 0)
  end
  local parameters = args.parameters
  if type(parameters) ~= "table" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " carries its parameters as a record", 0)
  end
  if not isPositiveInt(parameters.durationTicks) then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " blends over a compiled duration", 0)
  end
  for _, field in ipairs({ "startCoefficientA", "startCoefficientB", "targetCoefficientA", "targetCoefficientB" }) do
    local value = parameters[field]
    if type(value) ~= "number" or value ~= value then
      error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " interpolates its compiled " .. field, 0)
    end
  end
  local slots = parameters.oamModeSpriteSlots
  if slots ~= nil then
    if type(slots) ~= "table" or #slots < 1 then
      error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " blends its compiled sprite slots", 0)
    end
    for _, slot in ipairs(slots) do
      if type(slot) ~= "string" or slot == "" then
        error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " blends its compiled sprite slots", 0)
      end
    end
  end
  return setmetatable({
    _scene = scene,
    _kind = kind,
    _fromA = parameters.startCoefficientA,
    _toA = parameters.targetCoefficientA,
    _fromB = parameters.startCoefficientB,
    _toB = parameters.targetCoefficientB,
    _slots = slots,
    _duration = parameters.durationTicks,
    _ticks = 0,
    _state = "pending",
    _disposed = false,
  }, BattleBlendCoefficientTask)
end

-- Drops the owned register overlay exactly while this task still owns
-- its slot, so a newer blend is never restored away.
---@param self BattleBlendCoefficientTask blend task under teardown
local function teardownCoefficientBlend(self)
  self._scene.removeTaskScalarPatch(self._scene, self)
end

---@param self BattleBlendCoefficientTask blend task under advancement
---@param tick table<string, unknown>? source tick under advancement
function BattleBlendCoefficientTask:stepSourceTick(tick)
  local _ = tick
  if self._disposed or self._state == "complete" or self._state == "cancelled" then
    return
  end
  self._state = "running"
  self._ticks = self._ticks + 1
  local progress = self._ticks / self._duration
  if progress > 1 then
    progress = 1
  end
  local overlay = {
    blendCoefficientA = math.floor(self._fromA + (self._toA - self._fromA) * progress + 0.5),
    blendCoefficientB = math.floor(self._fromB + (self._toB - self._fromB) * progress + 0.5),
  }
  if self._slots ~= nil then
    overlay.spriteSlots = self._slots
  end
  local ok, err = pcall(self._scene.applyTaskScalarPatch, self._scene, self, overlay)
  if not ok then
    teardownCoefficientBlend(self)
    error(err, 0)
  end
  if self._ticks >= self._duration then
    self._state = "complete"
  end
end

---@param self BattleBlendCoefficientTask
---@return string
function BattleBlendCoefficientTask:status()
  assert(VALID_TASK_STATES[self._state] == true, "blend tasks report a known run state")
  return self._state
end

---@param self BattleBlendCoefficientTask
---@param reason string cancellation cause under diagnosis
function BattleBlendCoefficientTask:cancel(reason)
  local _ = reason
  if self._state == "complete" then
    return
  end
  self._state = "cancelled"
  teardownCoefficientBlend(self)
end

---@param self BattleBlendCoefficientTask
function BattleBlendCoefficientTask:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  teardownCoefficientBlend(self)
end

-- Dedicated background bodies by emitted kind. Every other admitted
-- kind keeps its established picture/sprite body below; the generic native
-- visual task never sees these four spellings again.
local BACKGROUND_TASK_CONSTRUCTORS = {
  ["battle-background-four-picture-move-power-transition"] = newMovePowerProfileTask,
  ["battle-background-alternating-scroll-transition"] = newAlternatingScrollTask,
  ["battle-background-scanline-sine-wave-transition"] = newSineScrollTask,
  ["battle-sprite-blend-alpha-transition"] = newBlendCoefficientTask,
}

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
  if parameters.exitOwnSide == true then
    parameters = directedOffscreenParameters(parameters, activation, context or {}, kind)
  end
  local family = familyFor(kind)
  local activations = {}
  if activation ~= nil then
    activations[#activations + 1] = activation
  end
  if family == "pair" then
    local topology = context.topology
    local targets = type(topology) == "table" and topology.targets or nil
    local first = type(targets) == "table" and targets[1] or nil
    if type(first) ~= "table" or type(first.combatant) ~= "number" then
      error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " pairs two selected activations", 0)
    end
    local partner = { combatant = first.combatant, activation = first.activation }
    if activation == nil then
      activations[#activations + 1] = partner
    elseif activation.combatant ~= partner.combatant or activation.activation ~= partner.activation then
      activations[#activations + 1] = partner
    end
  end
  local canPatch = type(scene.applyTaskPicturePatch) == "function" and type(scene.removeTaskPicturePatch) == "function"
  local picturePlan = nil
  local canScroll = type(scene.scroll) == "function" and type(scene.applyScrollPatch) == "function"
  local scrollSweep = nil
  -- Timing-less spawns retire synchronously only for verified marker
  -- kinds: without a source boundary there is no owned interpolation
  -- lifetime, so the run owns no patch or sweep, and every other kind
  -- fails closed below instead of retiring silently. Timed spawns always
  -- interpolate below.
  if duration == nil and SYNCHRONOUS_MARKER_KINDS[kind] ~= true then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " retires only on compiled timing operands", 0)
  end
  if duration ~= nil then
    if #activations > 0 and canPatch and (family == "motion" or (family == "pair" and not pairUsesAffine(kind))) then
      picturePlan = picturePlanFor(parameters)
    end
    if picturePlan == nil and canScroll then
      scrollSweep = scrollSweepFor(parameters, duration)
    end
  end
  local copied = {}
  if type(parameters) == "table" then
    for field, value in pairs(parameters) do
      copied[field] = value
    end
  end
  local random = checkRandom(context or {}, kind)
  local amplitude = nil
  local centerX, centerY = 0, 0
  if family == "randomized" and duration ~= nil then
    if type(copied.amplitude) == "number" and copied.amplitude % 1 == 0 and copied.amplitude >= 1 then
      amplitude = math.min(127, copied.amplitude)
    end
    if type(copied.centerX) == "number" then
      centerX = clampPictureOffset(copied.centerX)
    end
    if type(copied.centerY) == "number" then
      centerY = clampPictureOffset(copied.centerY)
    end
  end
  local dashReach, dashSign = nil, nil
  if family == "dash" then
    if duration == nil then
      error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " dashes over a compiled duration", 0)
    end
    if activation == nil then
      error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " dashes its resolved activation", 0)
    end
    dashReach, dashSign = dashVector(context or {}, kind)
  end
  local phaseFirst, phaseReturn = nil, nil
  if isPositiveInt(copied.firstDurationTicks) then
    phaseFirst = copied.firstDurationTicks
  elseif isPositiveInt(copied.approachTicks) then
    phaseFirst = copied.approachTicks
  end
  if isPositiveInt(copied.returnDurationTicks) then
    phaseReturn = copied.returnDurationTicks
  elseif isPositiveInt(copied.secondDurationTicks) then
    phaseReturn = copied.secondDurationTicks
  elseif isPositiveInt(copied.settleTicks) then
    phaseReturn = copied.settleTicks
  end
  local repeatCount = nil
  if isPositiveInt(copied.repeatCount) then
    repeatCount = copied.repeatCount
  end
  local targetColor = nil
  if type(copied.targetColor) == "number" and copied.targetColor % 1 == 0 then
    targetColor = clampPaletteColor(copied.targetColor)
  end
  local vanishInterval = nil
  if isPositiveInt(copied.intervalTicks) then
    vanishInterval = copied.intervalTicks
  end
  local scrollSaved = { x = 0, y = 0 }
  if canScroll then
    local saved = scene.scroll(scene)
    scrollSaved = { x = saved.x, y = saved.y }
  end
  return setmetatable({
    _scene = scene,
    _kind = kind,
    _family = family,
    _activation = activation,
    _activations = activations,
    _parameters = copied,
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
    _amplitude = amplitude,
    _centerX = centerX,
    _centerY = centerY,
    _dashReach = dashReach,
    _dashSign = dashSign,
    _phaseFirst = phaseFirst,
    _phaseReturn = phaseReturn,
    _repeatCount = repeatCount,
    _targetColor = targetColor,
    _vanishInterval = vanishInterval,
    _ticks = 0,
    _duration = duration,
    _state = "pending",
    _cancelReason = nil,
    _disposed = false,
  }, BattleNativeVisualTask)
end

-- Writes the dash coordinate stages: a phased out leg, a back leg, and
-- a settle tail over the compiled duration, from the slot-derived reach.
-- Phase boundaries come only from the compiled duration.
---@param self BattleNativeVisualTask visual task under advancement
local function writeDashTick(self)
  local duration = self._duration --[[@as integer]]
  local out = math.max(1, math.floor(duration * 8 / 20))
  local back = math.max(1, math.floor(duration * 9 / 20))
  local reach = self._dashReach --[[@as integer]]
  local sign = self._dashSign --[[@as integer]]
  local offset = 0
  if self._ticks <= out then
    offset = reach * (self._ticks / out)
  elseif self._ticks <= out + back then
    offset = reach * (1 - (self._ticks - out) / back)
  else
    offset = 0
  end
  self._scene.applyTaskPicturePatch(self._scene, self, self._activation, {
    pictureXOffset2 = wrapPictureByte(sign * offset),
  })
  self._patchActive = true
end

-- Writes seeded motion: two occurrence-local draws per tick become the
-- picture offsets, so the same seed paints the same positions on every
-- host schedule while another seed varies them.
---@param self BattleNativeVisualTask visual task under advancement
local function writeRandomizedTick(self)
  local amplitude = self._amplitude --[[@as integer]]
  local random = self._random --[[@as fun(bound: integer): integer]]
  local span = amplitude * 2 + 1
  local dx = random(span) - amplitude
  local dy = random(span) - amplitude
  self._scene.applyTaskPicturePatch(self._scene, self, self._activation, {
    pictureXOffset2 = wrapPictureByte(self._centerX + dx),
    pictureYOffset = clampPictureOffset(self._centerY + dy),
  })
  self._patchActive = true
end

-- Writes one tick of owned visual state: the scroll sweep interpolates
-- its compiled totals and the family writer interpolates its compiled
-- placement from the occurrence-local stream when the family is seeded.
-- Palette overlays apply once: the scene steps them natively afterward.
-- The run publishes no drawable picture.
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
  if self._family == "dash" then
    writeDashTick(self)
    return
  end
  if self._family == "randomized" and self._amplitude ~= nil and self._activation ~= nil and self._canPatch then
    writeRandomizedTick(self)
    return
  end
  local patch = nil
  if self._family == "affine" or (self._family == "pair" and pairUsesAffine(self._kind)) then
    patch = affinePatchFor(self, progress)
  elseif self._family == "cyclic" then
    patch = cyclicPatchFor(self)
  elseif self._family == "palette-pulse" then
    patch = pulsePatchFor(self)
  elseif self._family == "paired" then
    patch = pairedPatchFor(self, progress)
  elseif self._family == "vanish" then
    patch = vanishPatchFor(self)
  elseif self._family == "multi" then
    patch = multiPatchFor(self, progress)
  elseif self._family == "motion" and self._parameters.approachOffset ~= nil then
    patch = approachPatchFor(self)
  end
  if patch ~= nil and self._canPatch then
    for _, activation in ipairs(self._activations) do
      scene.applyTaskPicturePatch(scene, self, activation, patch)
    end
    self._patchActive = true
    return
  end
  local plan = self._picturePlan
  if plan ~= nil and self._canPatch then
    if plan.kind == "palette" then
      if not self._paletteApplied then
        self._paletteApplied = true
        for _, activation in ipairs(self._activations) do
          scene.applyTaskPicturePatch(scene, self, activation, {
            paletteFade = {
              start = plan.start,
              finish = plan.finish,
              framesPer = plan.framesPer,
              targetColor = plan.targetColor,
            },
          })
        end
        self._patchActive = true
      end
    elseif plan.kind == "rotation" then
      for _, activation in ipairs(self._activations) do
        scene.applyTaskPicturePatch(scene, self, activation, {
          rotationZ = clampRotationAngle(plan.from + (plan.to - plan.from) * progress),
        })
      end
      self._patchActive = true
    else
      local offsetPatch = {}
      if plan.fromX ~= 0 or plan.toX ~= 0 then
        offsetPatch.pictureXOffset2 = wrapPictureByte(plan.fromX + (plan.toX - plan.fromX) * progress)
      end
      if plan.fromY ~= 0 or plan.toY ~= 0 then
        offsetPatch.pictureYOffset = clampPictureOffset(plan.fromY + (plan.toY - plan.fromY) * progress)
      end
      if next(offsetPatch) ~= nil then
        for _, activation in ipairs(self._activations) do
          scene.applyTaskPicturePatch(scene, self, activation, offsetPatch)
        end
        self._patchActive = true
      end
    end
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
    if self._canPatch then
      for _, activation in ipairs(self._activations) do
        self._scene.removeTaskPicturePatch(self._scene, self, activation)
      end
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
-- Timing-less marker-kind spawns retire on their first tick: the spawn
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

-- Required per-occurrence roles behind one configured sprite: the
-- normalized semantic slots the producer lowers for its sprite setup
-- word. Multi-cell resources stay manager-owned through their loader
-- opcodes, so this lane stages exactly the four roles it draws from.
local CONFIGURED_SPRITE_REQUIRED_ROLES = { "character", "palette", "cell", "animation" }

---@param args table<string, unknown> instruction-derived construction arguments
---@return boolean configured true when the spawn carries the full sprite role map
local function isConfiguredSpriteSpawn(args)
  if type(args) ~= "table" then
    return false
  end
  local resourceKeys = args.resourceKeys
  if type(resourceKeys) ~= "table" then
    return false
  end
  for _, role in ipairs(CONFIGURED_SPRITE_REQUIRED_ROLES) do
    if type(resourceKeys[role]) ~= "string" or resourceKeys[role] == "" then
      return false
    end
  end
  return true
end

---@class BattleConfiguredSpriteTask
---@field _scene table<string, unknown> scene behind owned transient records
---@field _kind string configured sprite kind behind the run
---@field _staged table<integer, BattleEffectLeaseRecord> staged occurrence leases
---@field _characterKey string staged texture role behind picture submissions
---@field _stripWidth integer staged strip width in pixels behind tile crops
---@field _anchor table<string, integer> native slot center behind object placement
---@field _frames table<integer, { cell: integer, duration: integer }> authored display frames
---@field _total integer authored source ticks behind completion
---@field _cells table<integer, table<string, unknown>> normalized NCER cells
---@field _effectIds table<integer, integer> live transient identities behind the shown frame
---@field _shown integer last published display frame, 0 before the first tick
---@field _ticks integer source ticks advanced
---@field _state string pending, running, complete, or cancelled
---@field _cancelReason string? last cancellation cause under diagnosis
---@field _disposed boolean release has run
local BattleConfiguredSpriteTask = {}
BattleConfiguredSpriteTask.__index = BattleConfiguredSpriteTask

-- Names the staged lease behind one owned role: leases are occurrence
-- journals in acquisition order, so the role key selects deterministically.
---@param staged table<integer, BattleEffectLeaseRecord> staged occurrence leases
---@param key string owned resource key behind lookup
---@param kind string task kind under diagnosis
---@return table<string, unknown> staged lease behind the role
local function configuredLease(staged, key, kind)
  for _, record in ipairs(staged) do
    local lease = record.lease
    if type(lease) == "table" and lease.key == key then
      return lease --[[@as table<string, unknown>]]
    end
  end
  error("BATTLE_EFFECT_TASK_RESOURCE: kind " .. kind .. " stages no lease for resource " .. key, 0)
end

-- Validates one enabled NCER object for the picture-layer path: only
-- axis-aligned integer geometry with a staged tile origin is
-- representable, so affine objects fail here instead of drawing
-- unrotated stand-ins.
---@param obj table<string, unknown> normalized cell object under validation
---@param kind string task kind under diagnosis
---@param key string sprite cell resource key behind provenance
local function checkSpriteObject(obj, kind, key)
  if obj.affine == true then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " draws no affine sprite object from " .. key, 0)
  end
  for _, field in ipairs({ "x", "y", "tile", "width", "height", "priority" }) do
    if type(obj[field]) ~= "number" or obj[field] % 1 ~= 0 then
      error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " pictures integer sprite geometry from " .. key, 0)
    end
  end
  local width = obj.width --[[@as integer]]
  local height = obj.height --[[@as integer]]
  if width < 8 or width > 64 or width % 8 ~= 0 or height < 8 or height > 64 or height % 8 ~= 0 then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " pictures native sprite geometry from " .. key, 0)
  end
  if obj.tile < 0 then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " pictures staged sprite tiles from " .. key, 0)
  end
end

-- Selects the sprite anchor from the frozen occurrence topology: the
-- attacker slot center, shared with the emitter slot anchors so
-- attacker and target sides resolve without inventing coordinates.
---@param context table<string, unknown> occurrence-bound playback context
---@param kind string task kind under diagnosis
---@return table<string, integer> native slot center behind object placement
local function configuredAnchor(context, kind)
  local topology = type(context) == "table" and context.topology or nil
  local attacker = type(topology) == "table" and topology.attacker or nil
  local slot = type(attacker) == "table" and attacker.slot or nil
  local center = type(slot) == "string" and EMITTER_CENTERS[slot] or nil
  if type(center) ~= "table" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " anchors its sprite on the occurrence attacker slot", 0)
  end
  return { x = center.x, y = center.y }
end

-- Builds the display walk from the authored NANR frames: zero-duration
-- frames are skipped, and an all-zero animation shows its first frame
-- for exactly one tick. No fixed budget stands in for authored timing.
---@param frames table<integer, table<string, unknown>> authored animation frames
---@param kind string task kind under diagnosis
---@param key string sprite animation resource key behind provenance
---@return table<integer, { cell: integer, duration: integer }> display frames in order
local function displayFrames(frames, kind, key)
  local walk = {}
  for _, frame in ipairs(frames) do
    if type(frame.cell) ~= "number" or frame.cell % 1 ~= 0 or frame.cell < 0 then
      error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " advances normalized sprite frames from " .. key, 0)
    end
    local duration = frame.duration
    if type(duration) ~= "number" or duration % 1 ~= 0 or duration < 0 then
      error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " advances authored sprite durations from " .. key, 0)
    end
    if duration >= 1 then
      walk[#walk + 1] = { cell = frame.cell, duration = duration }
    end
  end
  if #walk == 0 and #frames >= 1 then
    walk[1] = { cell = frames[1].cell, duration = 1 }
  end
  return walk
end

-- Owns one source-cell sprite occurrence over its decoded leases: the
-- task stages each role once, walks authored NANR frames over NCER
-- objects, and publishes transient strip-band pictures through the
-- existing scene/renderer path.
---@param kind string configured sprite kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> scene, audio, and resource collaborators
---@return table<string, unknown> runnable sprite task
local function newConfiguredSpriteTask(kind, args, context, services)
  checkVisualArgs(args, kind)
  local scene = checkScene(services, kind)
  checkEffectScene(scene, kind)
  local resourceKeys = args.resourceKeys --[[@as table<string, string>]]
  local staged = {}
  for _, role in ipairs(CONFIGURED_SPRITE_REQUIRED_ROLES) do
    stageLease(kind, resourceKeys[role], services, staged)
  end
  local characterKey = resourceKeys.character
  local failurePrefix = "BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind
  local texture = configuredLease(staged, characterKey, kind)
  if texture.kind ~= "texture" then
    releaseStaged(staged)
    error(failurePrefix .. " draws sprite strips from a staged texture, not " .. tostring(texture.kind), 0)
  end
  if type(texture.width) ~= "number" or texture.width % 1 ~= 0 or texture.width < 8 then
    releaseStaged(staged)
    error(failurePrefix .. " draws sprite strips from a sized staged texture", 0)
  end
  local palette = configuredLease(staged, resourceKeys.palette, kind)
  local paletteData = type(palette) == "table" and palette.data or nil
  if palette.kind == "texture" or type(paletteData) ~= "table" or type(paletteData.colors) ~= "table" then
    releaseStaged(staged)
    error(failurePrefix .. " stages decoded palette records for resource " .. resourceKeys.palette, 0)
  end
  local cellLease = configuredLease(staged, resourceKeys.cell, kind)
  local cellData = type(cellLease) == "table" and cellLease.data or nil
  if cellLease.kind == "texture" or type(cellData) ~= "table" or type(cellData.cells) ~= "table" then
    releaseStaged(staged)
    error(failurePrefix .. " stages decoded cell records for resource " .. resourceKeys.cell, 0)
  end
  local animationLease = configuredLease(staged, resourceKeys.animation, kind)
  local animationData = type(animationLease) == "table" and animationLease.data or nil
  if animationLease.kind == "texture" or type(animationData) ~= "table" or type(animationData.anims) ~= "table" then
    releaseStaged(staged)
    error(failurePrefix .. " stages decoded animation records for resource " .. resourceKeys.animation, 0)
  end
  local cells = cellData.cells --[[@as table<integer, table<string, unknown>>]]
  if #cells < 1 then
    releaseStaged(staged)
    error(failurePrefix .. " pictures staged sprite cells from " .. resourceKeys.cell, 0)
  end
  local anims = animationData.anims --[[@as table<integer, table<string, unknown>>]]
  if #anims < 1 or type(anims[1].frames) ~= "table" or #anims[1].frames < 1 then
    releaseStaged(staged)
    error(failurePrefix .. " advances normalized sprite frames from " .. resourceKeys.animation, 0)
  end
  local ok, walk = pcall(displayFrames, anims[1].frames, kind, resourceKeys.animation)
  if not ok then
    releaseStaged(staged)
    error(walk, 0)
  end
  assert(type(walk) == "table" and #walk >= 1, "the display walk keeps at least one authored frame")
  for _, frame in ipairs(walk) do
    local cell = cells[frame.cell + 1]
    if type(cell) ~= "table" or type(cell.objs) ~= "table" then
      releaseStaged(staged)
      error(failurePrefix .. " pictures staged sprite cell " .. frame.cell .. " from " .. resourceKeys.cell, 0)
    end
    for _, obj in
      ipairs(cell.objs --[[@as table<integer, table<string, unknown>>]])
    do
      if type(obj) == "table" and obj.disabled ~= true then
        local valid, cause = pcall(checkSpriteObject, obj, kind, resourceKeys.cell)
        if not valid then
          releaseStaged(staged)
          error(cause, 0)
        end
      end
    end
  end
  local total = 0
  for _, frame in ipairs(walk) do
    total = total + frame.duration
  end
  local anchorOk, anchor = pcall(configuredAnchor, context, kind)
  if not anchorOk then
    releaseStaged(staged)
    error(anchor, 0)
  end
  assert(type(anchor) == "table", "the sprite anchor resolves before the first tick")
  return setmetatable({
    _scene = scene,
    _kind = kind,
    _staged = staged,
    _characterKey = characterKey,
    _stripWidth = texture.width,
    _anchor = anchor,
    _frames = walk,
    _total = total,
    _cells = cells,
    _effectIds = {},
    _shown = 0,
    _ticks = 0,
    _state = "pending",
    _cancelReason = nil,
    _disposed = false,
  }, BattleConfiguredSpriteTask)
end

-- Releases owned transient identities without touching the persistent
-- battler scene: unknown or repeated identities stay silent.
---@param self BattleConfiguredSpriteTask
local function teardownConfiguredSprite(self)
  if #self._effectIds > 0 then
    local scene = self._scene
    for _, id in ipairs(self._effectIds) do
      scene.releaseEffect(scene, id)
    end
    self._effectIds = {}
  end
  self._shown = 0
end

-- Releases owned transient records and staged leases exactly once:
-- teardown clears scene state while the staged journal guards the
-- double release, so complete, cancel, and dispose share this path.
---@param self BattleConfiguredSpriteTask
local function retireConfiguredSprite(self)
  teardownConfiguredSprite(self)
  releaseStaged(self._staged)
end

-- Selects the display frame behind a source tick count over the
-- authored cumulative durations.
---@param self BattleConfiguredSpriteTask
---@param tick integer source ticks advanced
---@return integer display frame behind the tick
local function frameAt(self, tick)
  local elapsed = 0
  for index, frame in ipairs(self._frames) do
    elapsed = elapsed + frame.duration
    if tick <= elapsed then
      return index
    end
  end
  return #self._frames
end

-- Publishes one authored cell as transient strip-band pictures: each
-- 8-pixel object row crops its staged tile band through the existing
-- scene record, ordered by NCER object order with native offsets,
-- flips, and priority depth.
---@param self BattleConfiguredSpriteTask
---@param cellIndex integer zero-based authored cell behind publishing
local function publishConfiguredCell(self, cellIndex)
  teardownConfiguredSprite(self)
  local scene = self._scene
  local cell = self._cells[cellIndex + 1]
  assert(type(cell) == "table", "published cells stay in the staged range")
  local objs = cell.objs --[[@as table<integer, table<string, unknown>>]]
  assert(type(objs) == "table", "published cells carry their staged objects")
  local anchor = self._anchor --[[@as table<string, integer>]]
  for _, obj in ipairs(objs) do
    if type(obj) == "table" and obj.disabled ~= true then
      local width = obj.width --[[@as integer]]
      local height = obj.height --[[@as integer]]
      local tilesPerRow = math.floor(width / 8)
      local rows = math.floor(height / 8)
      for band = 0, rows - 1 do
        local origin = (obj.tile + band * tilesPerRow) * 8
        if origin < 0 or origin + width > self._stripWidth then
          teardownConfiguredSprite(self)
          error(
            "BATTLE_EFFECT_TASK_RESOURCE: kind "
              .. self._kind
              .. " crops staged sprite tiles from "
              .. self._characterKey,
            0
          )
        end
        local record = scene.allocEffect(scene, "configured-sprite")
        local id = record.id --[[@as integer]]
        scene.setEffectPicture(scene, id, {
          assetKey = self._characterKey,
          selector = self._kind .. "/cell-" .. cellIndex .. "/band-" .. band,
          centerX = anchor.x + obj.x,
          centerY = anchor.y + obj.y + band * 8,
          zCenter = -obj.priority,
          width = width,
          height = 8,
          alpha = 1,
          xOffset2 = origin,
          yOffset2 = 0,
          flipH = obj.flipH == true,
          flipV = obj.flipV == true,
        })
        self._effectIds[#self._effectIds + 1] = id
      end
    end
  end
end

-- Advances one source tick toward the authored animation boundary.
-- Mid-task scene failures restore the task's own partial visuals
-- before the failure reaches the player.
---@param self BattleConfiguredSpriteTask
---@param tick table<string, unknown>? source tick under advancement
function BattleConfiguredSpriteTask:stepSourceTick(tick)
  local _ = tick
  if self._disposed or self._state == "complete" or self._state == "cancelled" then
    return
  end
  self._state = "running"
  self._ticks = self._ticks + 1
  local index = frameAt(self, self._ticks)
  if index ~= self._shown then
    local ok, err = pcall(publishConfiguredCell, self, self._frames[index].cell)
    if not ok then
      retireConfiguredSprite(self)
      error(err, 0)
    end
    self._shown = index
  end
  if self._ticks >= self._total then
    self._state = "complete"
    retireConfiguredSprite(self)
  end
end

-- Reports the sprite run state for the player's retirement accounting.
---@param self BattleConfiguredSpriteTask
---@return string
function BattleConfiguredSpriteTask:status()
  assert(VALID_TASK_STATES[self._state] == true, "configured sprite tasks report a known run state")
  return self._state
end

-- Cancels the sprite run; completion and cancellation stay separate, so
-- a completed run keeps its completion.
---@param self BattleConfiguredSpriteTask
---@param reason string cancellation cause under diagnosis
function BattleConfiguredSpriteTask:cancel(reason)
  if self._state == "complete" then
    return
  end
  self._state = "cancelled"
  self._cancelReason = reason
  retireConfiguredSprite(self)
end

-- Releases owned transient records and staged leases exactly once.
---@param self BattleConfiguredSpriteTask
function BattleConfiguredSpriteTask:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  retireConfiguredSprite(self)
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
  if kind == BattleEffectTasks.EMITTER_BATTLER_PATH_KIND then
    return true
  end
  if kind == BattleEffectTasks.EMITTER_CURVED_PATH_KIND then
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
  if kind == BattleEffectTasks.EMITTER_BATTLER_PATH_KIND or kind == BattleEffectTasks.EMITTER_CURVED_PATH_KIND then
    assert(type(services) == "table", "emitter path tasks require their services record")
    return newEmitterPathTask(kind, args or {}, context or {}, services)
  end
  if kind == BattleEffectTasks.PICTURE_ANIMATION_KIND then
    assert(type(services) == "table", "picture animations require their services record")
    return newPictureAnimation(args or {}, context or {}, services)
  end
  if SOUND_TASK_KINDS[kind] == true then
    assert(type(services) == "table", "sound tasks require their services record")
    return newSoundTask(kind, args or {}, context or {}, services)
  end
  if isConfiguredSpriteSpawn(args or {}) then
    assert(type(services) == "table", "configured sprite tasks require their services record")
    return newConfiguredSpriteTask(kind, args or {}, context or {}, services)
  end
  local backgroundConstructor = BACKGROUND_TASK_CONSTRUCTORS[kind]
  if backgroundConstructor ~= nil then
    assert(type(services) == "table", "background tasks require their services record")
    return backgroundConstructor(kind, args or {}, context or {}, services)
  end
  if NATIVE_VISUAL_KINDS[kind] == true then
    assert(type(services) == "table", "native visual tasks require their services record")
    return newNativeVisualTask(kind, args or {}, context or {}, services)
  end
  error("BATTLE_EFFECT_TASK_UNKNOWN: no native task implementation for kind " .. tostring(kind), 0)
end

return BattleEffectTasks
