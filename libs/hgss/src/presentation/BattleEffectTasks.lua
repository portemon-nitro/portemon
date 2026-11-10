-- Battle-private effect task factory for normalized battle animations.
-- Native task bodies live in src/battle/battle_anim_effects.c and drive
-- sys tasks through BattleAnimSystem_CreateTaskOfKind (kind 1 counts
-- taskCount, kind 2 counts soundTaskCount); raw visual work uses
-- SysTask_CreateOnMainQueue directly and stays outside both counters.
-- The player schedules work through this factory as
-- Factory.create(kind, args, context, services); unknown kinds fail here
-- instead of returning a timer stand-in. Voice monitoring, sound actions
-- with real voice completion, background blend transitions, battle
-- particle systems and their emitters, picture reveals, configured-sprite cell frames,
-- and one source-parameterized visual body per remaining nonparticle
-- task kind have bodies in this lane; only kinds outside the emitted
-- producer vocabulary still fail closed. Visual, blend, and picture
-- bodies mutate only scene state (owned picture patches, scroll sweeps,
-- palette overlays) and publish no drawable picture of their own: only
-- particle systems (through the scene registry the renderer draws) and
-- configured-sprite cell tasks draw, and only from staged dependency textures. Completion boundaries come only from
-- compiled source timing operands. A spawn whose instruction carries no compiled timing operand
-- retires synchronously ONLY when its kind belongs to the verified synchronous-marker set below;
-- every other timing-less spawn fails closed with BATTLE_EFFECT_TASK_MALFORMED instead of retiring
-- silently, and malformed shapes fail closed. No fixed budget stands in for source timing anywhere.
-- BattleEffectTasks.supportsKind is the narrow admission view over this
-- same dispatch.

local BattleParticleSystems = require("libs.hgss.src.presentation.BattleParticleSystems")

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
BattleEffectTasks.PARTICLE_SYSTEM_KIND = BattleParticleSystems.SYSTEM_KIND
BattleEffectTasks.PARTICLE_CONTINUATION_KIND = BattleParticleSystems.EMITTER_KIND
BattleEffectTasks.EMITTER_BATTLER_PATH_KIND = BattleParticleSystems.PATH_KIND
BattleEffectTasks.EMITTER_CURVED_PATH_KIND = BattleParticleSystems.CURVED_PATH_KIND
BattleEffectTasks.PICTURE_ANIMATION_KIND = "pokemon-picture-animation"

local VALID_TASK_STATES = {
  pending = true,
  running = true,
  complete = true,
  cancelled = true,
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
  elseif parameters.framesPerStep == 0 and isPositiveInt(parameters.repeatCount) then
    -- Palette pulse callbacks admit a zero frame interval. It removes the
    -- wait between repeats; each repeat still advances on one source tick.
    return parameters.repeatCount
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
  ["active-position-first"] = true,
  ["active-battler"] = true,
  ["active-battler-pair-when-enabled"] = true,
  ["all-battler-positions"] = true,
  ["attacker-related-position-when-paired"] = true,
}

-- Semantic picture targets resolving to the first occurrence target.
local TARGET_PICTURE_NAMES = {
  target = true,
  ["active-position-second"] = true,
  ["opposing-battler"] = true,
  ["opposing-battler-pair-when-enabled"] = true,
  ["other-battler-positions"] = true,
  ["target-related-position-when-paired"] = true,
  ["first-battler-state-one-or-three"] = true,
  ["first-battler-state-five"] = true,
}

local SOURCE_BATTLER_TYPES = {
  ["first-battler-state-zero-or-two"] = { [0] = true, [2] = true },
  ["first-battler-state-one-or-three"] = { [1] = true, [3] = true },
  ["first-battler-state-four"] = { [4] = true },
  ["first-battler-state-five"] = { [5] = true },
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

local function plannedBattlerSpriteActivation(args, context)
  local name = args.battlerTarget
  if name == "first-battler-for-active-position-first" or name == "first-battler-for-active-position-second" then
    local topology = context.topology --[[@as table<string, unknown>?]]
    local battler = nil
    if name == "first-battler-for-active-position-first" then
      battler = type(topology) == "table" and topology.attacker or nil
    elseif type(topology) == "table" and type(topology.targets) == "table" then
      battler = topology.targets[1]
    end
    if type(battler) ~= "table" or type(battler.sideType) ~= "number" then
      return nil
    end
    local partnerSideType = ({ [0] = 0, [1] = 1, [2] = 4, [3] = 5, [4] = 2, [5] = 3 })[
      battler.sideType --[[@as integer]]
    ]
    local sourceBattlers = context.sourceBattlers --[[@as table<integer, table<string, unknown>>?]]
    if type(sourceBattlers) ~= "table" or partnerSideType == nil then
      return nil
    end
    for _, candidate in ipairs(sourceBattlers) do
      if candidate.sideType == partnerSideType then
        return { combatant = candidate.combatant, activation = candidate.activation }
      end
    end
    return nil
  end
  local sourceTypes = type(name) == "string" and SOURCE_BATTLER_TYPES[name] or nil
  if sourceTypes == nil then
    return plannedActivation(args, context)
  end
  local sourceBattlers = context.sourceBattlers
  if type(sourceBattlers) ~= "table" then
    error("BATTLE_EFFECT_TASK_MALFORMED: battler sprite role reads ordered source battler slots", 0)
  end
  for _, candidate in ipairs(sourceBattlers) do
    if type(candidate.sideType) == "number" and sourceTypes[candidate.sideType] == true then
      return { combatant = candidate.combatant, activation = candidate.activation }
    end
  end
  -- BattleAnimSystem_GetBattlerByRole falls back to battler index zero
  -- when state roles 4–7 have no active match. sourceBattlers keeps
  -- native battler index order, so its first record is that exact fallback.
  local first = sourceBattlers[1]
  return type(first) == "table" and { combatant = first.combatant, activation = first.activation } or nil
end

-- Resolves the native battler-role mask used by MoveBattlerSin. The
-- event-time topology carries the attacker and the complete ordered
-- target set; singles therefore naturally omit partner roles.
---@param parameters table<string, unknown> source MoveBattlerSin operands
---@param context table<string, unknown> occurrence-bound playback context
---@param kind string task kind under construction
---@return table<integer, table<string, unknown>> selected battler activations
local function positionPathActivations(parameters, context, kind)
  local topology = type(context) == "table" and context.topology or nil
  if type(topology) ~= "table" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " reads event-time battler positions", 0)
  end
  local attacker = topology.attacker
  local targets = topology.targets
  if type(attacker) ~= "table" or type(attacker.combatant) ~= "number" or type(targets) ~= "table" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " reads its attacker and target positions", 0)
  end

  local available = { attacker }
  for _, target in ipairs(targets) do
    if type(target) ~= "table" or type(target.combatant) ~= "number" then
      error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " reads ordered target positions", 0)
    end
    available[#available + 1] = target
  end
  local function addUnique(into, candidate)
    for _, current in ipairs(into) do
      if current.combatant == candidate.combatant and current.activation == candidate.activation then
        return
      end
    end
    into[#into + 1] = { combatant = candidate.combatant, activation = candidate.activation }
  end

  local selected = {}
  local path = parameters.positionPath
  if path == "all-battler-positions" then
    for _, candidate in ipairs(available) do
      addUnique(selected, candidate)
    end
  elseif path == "active-and-related-pair" then
    for _, candidate in ipairs(available) do
      if candidate.combatant ~= attacker.combatant then
        addUnique(selected, candidate)
      end
    end
  elseif path == "selected-position-anchors" then
    if parameters.attackerAnchor == true then
      addUnique(selected, attacker)
    end
    if parameters.targetAnchor == true then
      local target = targets[1]
      if type(target) == "table" then
        addUnique(selected, target)
      end
    end
    -- Partner roles only exist in doubles. Resolve them from the
    -- event-time participants when those moves also target the partner.
    local function addPartner(anchor, related)
      if anchor ~= true or type(related) ~= "table" then
        return
      end
      local sideType = related.sideType
      local partnerSideType = sideType == 2 and 4 or sideType == 4 and 2 or sideType == 3 and 5 or sideType == 5 and 3
      for _, candidate in ipairs(available) do
        if candidate.combatant ~= related.combatant and candidate.sideType == partnerSideType then
          addUnique(selected, candidate)
          return
        end
      end
    end
    addPartner(parameters.attackerRelatedAnchor, attacker)
    addPartner(parameters.targetRelatedAnchor, targets[1])
  else
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " selects a known position path", 0)
  end
  if #selected == 0 then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " selects at least one present battler", 0)
  end
  return selected
end

---@class BattlePositionPathTask
---@field _scene table<string, unknown> scene behind owned picture offsets
---@field _kind string source task kind behind the run
---@field _activations table<integer, table<string, unknown>> selected native battlers
---@field _stepTicks integer source circle duration before the multiplier
---@field _duration integer complete source task duration
---@field _ticks integer source ticks advanced
---@field _state string pending, running, complete, or cancelled
---@field _disposed boolean release has run
local BattlePositionPathTask = {}
BattlePositionPathTask.__index = BattlePositionPathTask

-- The source MoveBattlerSin task advances the circle phase by one base
-- duration while its lifetime is multiplied by stepMultiplier. Its
-- authored half-amplitudes are 1 horizontal pixel and -0.25 vertical
-- pixels, with the source's eight-pixel vertical baseline.
---@param self BattlePositionPathTask task under advancement
local function writePositionPathTick(self)
  local angle = 2 * math.pi * self._ticks / self._stepTicks
  local offsetX = math.floor(math.sin(angle))
  local offsetY = 8 + math.floor(-math.cos(angle) / 4)
  for _, activation in ipairs(self._activations) do
    self._scene.applyTaskPicturePatch(self._scene, self, activation, {
      pictureXOffset = offsetX,
      pictureYOffset = offsetY,
    })
  end
end

---@param self BattlePositionPathTask task under advancement
---@param tick table<string, unknown>? source tick under advancement
function BattlePositionPathTask:stepSourceTick(tick)
  local _ = tick
  if self._disposed or self._state == "complete" or self._state == "cancelled" then
    return
  end
  self._state = "running"
  self._ticks = self._ticks + 1
  if self._duration == 0 then
    self._state = "complete"
    return
  end
  local ok, err = pcall(writePositionPathTick, self)
  if not ok then
    for _, activation in ipairs(self._activations) do
      self._scene.removeTaskPicturePatch(self._scene, self, activation)
    end
    error(err, 0)
  end
  if self._ticks >= self._duration then
    self._state = "complete"
    for _, activation in ipairs(self._activations) do
      self._scene.removeTaskPicturePatch(self._scene, self, activation)
    end
  end
end

---@param self BattlePositionPathTask
---@return string
function BattlePositionPathTask:status()
  assert(VALID_TASK_STATES[self._state] == true, "position path tasks report a known run state")
  return self._state
end

---@param self BattlePositionPathTask
---@param reason string cancellation cause under diagnosis
function BattlePositionPathTask:cancel(reason)
  local _ = reason
  if self._state == "complete" then
    return
  end
  self._state = "cancelled"
  for _, activation in ipairs(self._activations) do
    self._scene.removeTaskPicturePatch(self._scene, self, activation)
  end
end

---@param self BattlePositionPathTask
function BattlePositionPathTask:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  for _, activation in ipairs(self._activations) do
    self._scene.removeTaskPicturePatch(self._scene, self, activation)
  end
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

---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> scene collaborator
---@return BattlePositionPathTask runnable MoveBattlerSin task
local function newPositionPathTask(args, context, services)
  local kind = "pokemon-picture-position-path-transition"
  if type(args) ~= "table" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " carries instruction arguments", 0)
  end
  local scene = checkScene(services, kind)
  if type(scene.applyTaskPicturePatch) ~= "function" or type(scene.removeTaskPicturePatch) ~= "function" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " pictures through the scene overlay seam", 0)
  end
  local parameters = args.parameters
  if type(parameters) ~= "table" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " carries its parameters as a record", 0)
  end
  local stepTicks = parameters.durationTicks
  local multiplier = parameters.stepMultiplier
  if not isPositiveInt(stepTicks) or type(multiplier) ~= "number" or multiplier % 1 ~= 0 or multiplier < 0 then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " carries source circle timing", 0)
  end
  local duration = stepTicks * multiplier
  if duration > 0xFFFFFFFF then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " stays within native source timing", 0)
  end
  return setmetatable({
    _scene = scene,
    _kind = kind,
    _activations = positionPathActivations(parameters, context, kind),
    _stepTicks = stepTicks,
    _duration = duration,
    _ticks = 0,
    _state = "pending",
    _disposed = false,
  }, BattlePositionPathTask)
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
  -- Opcode-34 visual spawns carry selectors, never timing operands: the
  -- native visual update retires synchronously behind its preset, so the
  -- typed task owns no interpolation lifetime and retires on its first
  -- tick instead of failing closed.
  ["battle-background-blend-transition"] = true,
  ["battle-palette-fade"] = true,
  ["battle-presentation-state-reset"] = true,
  ["battle-background-position-transition"] = true,
  -- Sprite-effect spawns carry a mode and selector values, never timing
  -- operands: the managed draw loop stages its sprite behind the
  -- manager preset, so the typed task owns no interpolation lifetime
  -- and retires on its first tick instead of failing closed.
  ["managed-sprite-draw-loop"] = true,
  -- Sprite scale-settle presets carry their target behind the resolved
  -- callback without a compiled boundary: the settle owns no
  -- interpolation lifetime, so it retires on its first tick instead of
  -- failing closed.
  ["pokemon-picture-double-sprite-scale-settle"] = true,
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
    local perStep = parameters.ticksPerStep
    local count = parameters.steps
    if type(perStep) == "number" and perStep % 1 == 0 and type(count) == "number" and count % 1 == 0 then
      -- Source timing operands admit zero-step holds: a zero product
      -- carries no scroll sweep but still owns a single completion tick
      -- instead of failing the typed task closed.
      local product = math.abs(perStep * count)
      if product < 1 then
        return 1
      end
      -- Integral operands yield an integral product; floor is identity here
      -- and carries the integer type the annotation requires.
      return math.floor(product)
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

---@param args table<string, unknown> create or delete instruction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> scene collaborator
---@return table<string, function> one-tick task for a source battler sprite slot
local function newBattlerSpriteSlotTask(args, context, services)
  local operation = args.operation
  local slot = args.spriteSlot
  if operation ~= "create" and operation ~= "delete" then
    error("BATTLE_EFFECT_TASK_MALFORMED: battler sprite slot has a source operation", 0)
  end
  if type(slot) ~= "number" or slot % 1 ~= 0 or slot < 0 then
    error("BATTLE_EFFECT_TASK_MALFORMED: battler sprite slot carries a nonnegative slot", 0)
  end
  local launchId = context.launchId
  local packetId = context.packetId
  local occurrenceId = context.occurrenceId
  local programKey = context.programKey
  if
    type(launchId) ~= "string"
    or type(packetId) ~= "number"
    or (type(occurrenceId) ~= "number" and type(programKey) ~= "string")
  then
    error("BATTLE_EFFECT_TASK_MALFORMED: battler sprite slots retain source occurrence identity", 0)
  end
  local ownerKey = launchId .. ":" .. tostring(packetId) .. ":" .. tostring(occurrenceId or programKey)
  local scene = checkScene(services, "pokemon-battler-sprite-slot")
  if type(scene.setBattlerSpriteSlot) ~= "function" or type(scene.releaseBattlerSpriteSlots) ~= "function" then
    error("BATTLE_EFFECT_TASK_MALFORMED: battler sprite slots require their scene owner", 0)
  end
  local selected = operation == "create" and plannedBattlerSpriteActivation(args, context) or nil
  if operation == "create" then
    if args.runtimeSelection ~= "battler-pokemon-picture-resource" then
      error("BATTLE_EFFECT_TASK_MALFORMED: battler sprite slots select the runtime battler picture", 0)
    end
    if selected == nil then
      error("BATTLE_EFFECT_TASK_MALFORMED: battler sprite slots resolve their source role", 0)
    end
    if type(args.follow) ~= "boolean" then
      error("BATTLE_EFFECT_TASK_MALFORMED: battler sprite slots preserve the source follow flag", 0)
    end
  end
  local state = "pending"
  local ran = false
  local function stepSourceTick()
    if ran then
      return
    end
    ran = true
    state = "running"
    if operation == "create" then
      scene.setBattlerSpriteSlot(scene, ownerKey, slot, selected, args.follow)
    else
      scene.releaseBattlerSpriteSlots(scene, ownerKey, slot)
    end
    state = "complete"
  end
  local function status()
    return state
  end
  local function cancel() end
  local function dispose() end
  return {
    stepSourceTick = stepSourceTick,
    status = status,
    cancel = cancel,
    dispose = dispose,
  }
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
-- reports alive cannot fake-complete the run. A voice that never reports
-- past the native horizon fails loudly so a silent voice cannot park the
-- occurrence. Audio failures propagate so
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
    stopSoundVoice(self)
    error("BATTLE_EFFECT_TASK_VOICE: voice " .. self._voice .. " never reported completion", 0)
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

-- Effect backdrop plane behind battle-background-resource-load and its
-- cleanup: the producer stages one BG3 tile plane per selected effect
-- background (BattleAnimationSources BACKGROUND_MEMBER_ROWS), and the
-- runtime swaps the live scene through BattleScene:installBackgroundLayer.
-- The load installs on its first tick and retires synchronously; the layer
-- persists past the owning task's disposal until the matching cleanup
-- removes it, mirroring the native SwitchBackground/RestoreBackground
-- pairing (battle_anim_system.c). Double-install and unknown-remove keep
-- the scene ownership errors.
local EFFECT_BACKGROUND_LAYER_KEY = "battle-background-layer-3"

local BACKGROUND_EFFECT_SLOTS = { "character", "palette", "screenDefault", "screenAlternate" }

---@class BattleEffectBackgroundLoad
---@field _scene table<string, unknown> scene behind the owned BG3 layer
---@field _kind string task kind behind the run
---@field _staged table<integer, BattleEffectLeaseRecord> staged occurrence leases
---@field _resourceKeys table<string, string> staged resource keys by slot
---@field _screenKey string selected staged screen slot
---@field _installed boolean the staged layer is live in the scene
---@field _ticks integer source ticks advanced
---@field _state string pending, running, complete, or cancelled
---@field _cancelReason string? last cancellation cause under diagnosis
---@field _disposed boolean release has run
local BattleEffectBackgroundLoad = {}
BattleEffectBackgroundLoad.__index = BattleEffectBackgroundLoad

---@param lease unknown staged lease under validation
---@param slot string staged slot under diagnosis
---@param kind string task kind under diagnosis
---@return table<string, unknown> decoded payload behind the lease
local function backgroundPayload(lease, slot, kind)
  if type(lease) ~= "table" or type(lease.data) ~= "table" then
    error("BATTLE_EFFECT_TASK_RESOURCE: kind " .. kind .. " stages decoded records for slot " .. slot, 0)
  end
  return lease.data --[[@as table<string, unknown>]]
end

-- Names the staged lease behind one owned background slot: leases are
-- occurrence journals in acquisition order, so the slot key selects
-- deterministically.
---@param staged table<integer, BattleEffectLeaseRecord> staged occurrence leases
---@param key string owned resource key behind lookup
---@param kind string task kind under diagnosis
---@return table<string, unknown> staged lease behind the slot
local function backgroundLease(staged, key, kind)
  for _, record in ipairs(staged) do
    local lease = record.lease
    if type(lease) == "table" and lease.key == key then
      return lease --[[@as table<string, unknown>]]
    end
  end
  error("BATTLE_EFFECT_TASK_RESOURCE: kind " .. kind .. " stages no lease for resource " .. key, 0)
end

---@param args table<string, unknown> instruction-derived construction arguments
---@param kind string task kind under construction
---@return table<string, string> staged resource keys by slot
local function backgroundResourceKeys(args, kind)
  local resourceKeys = args.resourceKeys
  if type(resourceKeys) ~= "table" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " installs its staged background slots", 0)
  end
  for _, slot in ipairs(BACKGROUND_EFFECT_SLOTS) do
    if type(resourceKeys[slot]) ~= "string" or resourceKeys[slot] == "" then
      error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " installs its staged slot " .. slot, 0)
    end
  end
  return resourceKeys --[[@as table<string, string>]]
end

---@param value unknown candidate source side type under validation
---@param kind string task kind under diagnosis
---@param role string topology role under diagnosis
---@return boolean isPlayer
local function backgroundSideIsPlayer(value, kind, role)
  if type(value) ~= "number" or value % 1 ~= 0 or value < 0 or value > 5 then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " requires a valid " .. role .. " background side", 0)
  end
  return value % 2 == 0
end

---@param arg integer source background screen selector
---@param attackerIsPlayer boolean whether the source attacker is on the player side
---@param defenderIsPlayer boolean whether the first source target is on the player side
---@return boolean flip whether the alternate staged screen is selected
local function shouldFlipBackground(arg, attackerIsPlayer, defenderIsPlayer)
  if arg == 2 then
    if attackerIsPlayer == defenderIsPlayer then
      return not defenderIsPlayer
    end
    return defenderIsPlayer
  end
  return arg ~= 0 and defenderIsPlayer
end

---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> scene, audio, and resource collaborators
---@return table<string, unknown> runnable background load task
local function newBackgroundResourceLoadTask(kind, args, context, services)
  checkVisualArgs(args, kind)
  local scene = checkScene(services, kind)
  if type(scene.installBackgroundLayer) ~= "function" or type(scene.removeBackgroundLayer) ~= "function" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " swaps through the scene background layer seam", 0)
  end
  local values = args.values
  if type(values) ~= "table" or type(values[1]) ~= "number" or values[1] % 1 ~= 0 or values[1] < 0 then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " loads its selected background by selector", 0)
  end
  if type(values[2]) ~= "number" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " carries its packed effect flags numerically", 0)
  end
  if args.runtimeSelection ~= "battle-background-screen-selection" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " selects its screen through the source selection", 0)
  end
  local screenFlipArg = args.screenFlipArg
  if type(screenFlipArg) ~= "number" or screenFlipArg % 1 ~= 0 then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " requires source background parameter 7", 0)
  end
  local topology = type(context) == "table" and context.topology or nil
  local attacker = type(topology) == "table" and topology.attacker or nil
  local targets = type(topology) == "table" and topology.targets or nil
  local defender = type(targets) == "table" and targets[1] or nil
  if type(attacker) ~= "table" or type(defender) ~= "table" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " requires attacker and first target background context", 0)
  end
  local attackerIsPlayer = backgroundSideIsPlayer(attacker.sideType, kind, "attacker")
  local defenderIsPlayer = backgroundSideIsPlayer(defender.sideType, kind, "defender")
  local screenKey = shouldFlipBackground(screenFlipArg, attackerIsPlayer, defenderIsPlayer) and "screenAlternate"
    or "screenDefault"
  local resourceKeys = backgroundResourceKeys(args, kind)
  local staged = {}
  for _, slot in ipairs(BACKGROUND_EFFECT_SLOTS) do
    stageLease(kind, resourceKeys[slot], services, staged)
  end
  local character = backgroundPayload(backgroundLease(staged, resourceKeys.character, kind), "character", kind)
  if character.depth ~= 3 or type(character.tiles) ~= "string" then
    releaseStaged(staged)
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " installs 4bpp tiled background characters", 0)
  end
  local palette = backgroundPayload(backgroundLease(staged, resourceKeys.palette, kind), "palette", kind)
  if type(palette.colors) ~= "table" or #palette.colors < 1 then
    releaseStaged(staged)
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " installs its staged background palette", 0)
  end
  local screen = backgroundPayload(backgroundLease(staged, resourceKeys[screenKey], kind), screenKey, kind)
  if type(screen.width) ~= "number" or type(screen.height) ~= "number" or type(screen.entries) ~= "table" then
    releaseStaged(staged)
    error(
      "BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " installs its staged " .. screenKey .. " background screen",
      0
    )
  end
  return setmetatable({
    _scene = scene,
    _kind = kind,
    _staged = staged,
    _resourceKeys = resourceKeys,
    _screenKey = screenKey,
    _installed = false,
    _ticks = 0,
    _state = "pending",
    _cancelReason = nil,
    _disposed = false,
  }, BattleEffectBackgroundLoad)
end

-- Composes the selected staged screen with shared characters and palette.
---@param self BattleEffectBackgroundLoad load task under advancement
local function installEffectBackground(self)
  local character =
    backgroundPayload(backgroundLease(self._staged, self._resourceKeys.character, self._kind), "character", self._kind)
  local palette =
    backgroundPayload(backgroundLease(self._staged, self._resourceKeys.palette, self._kind), "palette", self._kind)
  local screen = backgroundPayload(
    backgroundLease(self._staged, self._resourceKeys[self._screenKey], self._kind),
    self._screenKey,
    self._kind
  )
  self._scene.installBackgroundLayer(self._scene, EFFECT_BACKGROUND_LAYER_KEY, {
    character = { depth = character.depth, tiles = character.tiles },
    screen = { width = screen.width, height = screen.height, entries = screen.entries },
    palette = { colors = palette.colors },
  })
end

---@param self BattleEffectBackgroundLoad load task under advancement
---@param tick table<string, unknown>? source tick under advancement
function BattleEffectBackgroundLoad:stepSourceTick(tick)
  local _ = tick
  if self._disposed or self._state == "complete" or self._state == "cancelled" then
    return
  end
  self._state = "running"
  self._ticks = self._ticks + 1
  if not self._installed then
    local ok, err = pcall(installEffectBackground, self)
    if not ok then
      releaseStaged(self._staged)
      error(err, 0)
    end
    self._installed = true
  end
  self._state = "complete"
end

---@param self BattleEffectBackgroundLoad
---@return string
function BattleEffectBackgroundLoad:status()
  assert(VALID_TASK_STATES[self._state] == true, "background loads report a known run state")
  return self._state
end

-- Cancels the load; completion and cancellation stay separate, and the
-- installed layer persists until the matching cleanup: cancellation only
-- reaches loads that never installed.
---@param self BattleEffectBackgroundLoad
---@param reason string cancellation cause under diagnosis
function BattleEffectBackgroundLoad:cancel(reason)
  if self._state == "complete" then
    return
  end
  self._state = "cancelled"
  self._cancelReason = reason
  releaseStaged(self._staged)
end

-- Releases the staged leases exactly once; the installed layer persists
-- until cleanup or scene release, so disposal never removes it.
---@param self BattleEffectBackgroundLoad
function BattleEffectBackgroundLoad:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  releaseStaged(self._staged)
end

---@class BattleEffectBackgroundCleanup
---@field _scene table<string, unknown> scene behind the owned BG3 layer
---@field _kind string task kind behind the run
---@field _removed boolean the layer left the scene through this task
---@field _ticks integer source ticks advanced
---@field _state string pending, running, complete, or cancelled
---@field _cancelReason string? last cancellation cause under diagnosis
---@field _disposed boolean release has run
local BattleEffectBackgroundCleanup = {}
BattleEffectBackgroundCleanup.__index = BattleEffectBackgroundCleanup

---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> scene collaborator
---@return table<string, unknown> runnable background cleanup task
local function newBackgroundResourceCleanupTask(kind, args, context, services)
  local _ = context
  checkVisualArgs(args, kind)
  local scene = checkScene(services, kind)
  if type(scene.removeBackgroundLayer) ~= "function" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " removes through the scene background layer seam", 0)
  end
  return setmetatable({
    _scene = scene,
    _kind = kind,
    _removed = false,
    _ticks = 0,
    _state = "pending",
    _cancelReason = nil,
    _disposed = false,
  }, BattleEffectBackgroundCleanup)
end

---@param self BattleEffectBackgroundCleanup cleanup task under advancement
---@param tick table<string, unknown>? source tick under advancement
function BattleEffectBackgroundCleanup:stepSourceTick(tick)
  local _ = tick
  if self._disposed or self._state == "complete" or self._state == "cancelled" then
    return
  end
  self._state = "running"
  self._ticks = self._ticks + 1
  if not self._removed then
    local ok, err = pcall(self._scene.removeBackgroundLayer, self._scene, EFFECT_BACKGROUND_LAYER_KEY)
    if not ok then
      error(err, 0)
    end
    self._removed = true
  end
  self._state = "complete"
end

---@param self BattleEffectBackgroundCleanup
---@return string
function BattleEffectBackgroundCleanup:status()
  assert(VALID_TASK_STATES[self._state] == true, "background cleanups report a known run state")
  return self._state
end

---@param self BattleEffectBackgroundCleanup
---@param reason string cancellation cause under diagnosis
function BattleEffectBackgroundCleanup:cancel(reason)
  if self._state == "complete" then
    return
  end
  self._state = "cancelled"
  self._cancelReason = reason
end

---@param self BattleEffectBackgroundCleanup
function BattleEffectBackgroundCleanup:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
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
      -- The working fade visibly progresses toward its requested
      -- strength every tick instead of idling on a timer.
      local current = math.floor(plan.start + (plan.finish - plan.start) * progress + 0.5)
      if current < 0 then
        current = 0
      elseif current > 16 then
        current = 16
      end
      for _, activation in ipairs(self._activations) do
        scene.applyTaskPicturePatch(scene, self, activation, {
          paletteFade = {
            start = current,
            finish = plan.finish,
            framesPer = plan.framesPer,
            targetColor = plan.targetColor,
          },
        })
      end
      self._patchActive = true
      self._paletteApplied = true
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
-- only while no newer sweep has moved it since. A completed palette
-- fade keeps its explicit terminal record instead of bare removal. The
-- run stages no leases and publishes no drawable picture, so teardown
-- owns patches only.
---@param self BattleNativeVisualTask
local function teardownNativeVisual(self)
  if self._patchActive then
    self._patchActive = false
    if self._canPatch then
      local persistFade = self._state == "complete" and self._picturePlan ~= nil and self._picturePlan.kind == "palette"
      if not persistFade then
        for _, activation in ipairs(self._activations) do
          self._scene.removeTaskPicturePatch(self._scene, self, activation)
        end
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
-- defender screen position, shared with the emitter slot anchors so
-- attacker and target sides resolve without inventing coordinates.
---@param context table<string, unknown> occurrence-bound playback context
---@param kind string task kind under diagnosis
---@return table<string, integer> native slot center behind object placement
local function configuredAnchor(context, kind)
  local topology = type(context) == "table" and context.topology or nil
  local targets = type(topology) == "table" and topology.targets or nil
  local defender = type(targets) == "table" and targets[1] or nil
  local slot = type(defender) == "table" and defender.slot or nil
  local center = type(slot) == "string" and EMITTER_CENTERS[slot] or nil
  if type(center) ~= "table" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " anchors its sprite on the occurrence defender slot", 0)
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

-- Synchronous no-op behind the argument-free empty callback: no counter
-- change, no lease, no drawable state. One step retires it.
---@class BattleSyncMarkerTask
---@field _state string pending, running, complete, or cancelled
---@field _disposed boolean release has run
local BattleSyncMarkerTask = {}
BattleSyncMarkerTask.__index = BattleSyncMarkerTask

---@param kind string task kind under construction
---@return BattleSyncMarkerTask runnable empty task
local function newSyncNoopTask(kind)
  local _ = kind
  return setmetatable({ _state = "pending", _disposed = false }, BattleSyncMarkerTask)
end

---@param self BattleSyncMarkerTask
---@param tick table<string, unknown>? source tick under advancement
function BattleSyncMarkerTask:stepSourceTick(tick)
  local _ = tick
  if self._disposed or self._state == "complete" or self._state == "cancelled" then
    return
  end
  self._state = "complete"
end

---@param self BattleSyncMarkerTask
---@return string
function BattleSyncMarkerTask:status()
  assert(VALID_TASK_STATES[self._state] == true, "empty tasks report a known run state")
  return self._state
end

---@param self BattleSyncMarkerTask
---@param reason string cancellation cause under diagnosis
function BattleSyncMarkerTask:cancel(reason)
  local _ = reason
  if self._state == "complete" then
    return
  end
  self._state = "cancelled"
end

---@param self BattleSyncMarkerTask
function BattleSyncMarkerTask:dispose()
  self._disposed = true
end

-- Two-state counted task behind the one-frame callbacks: a wait state
-- then an end state, retiring on the second tick instead of collapsing
-- to a synchronous completion.
---@class BattleTwoStateTask
---@field _state string pending, running, complete, or cancelled
---@field _disposed boolean release has run
local BattleTwoStateTask = {}
BattleTwoStateTask.__index = BattleTwoStateTask

---@param kind string task kind under construction
---@return BattleTwoStateTask runnable two-state task
local function newTwoStateTask(kind)
  local _ = kind
  return setmetatable({ _state = "pending", _ticks = 0, _disposed = false }, BattleTwoStateTask)
end

---@param self BattleTwoStateTask
---@param tick table<string, unknown>? source tick under advancement
function BattleTwoStateTask:stepSourceTick(tick)
  local _ = tick
  if self._disposed or self._state == "complete" or self._state == "cancelled" then
    return
  end
  self._ticks = self._ticks + 1
  if self._ticks >= 2 then
    self._state = "complete"
  else
    self._state = "running"
  end
end

---@param self BattleTwoStateTask
---@return string
function BattleTwoStateTask:status()
  assert(VALID_TASK_STATES[self._state] == true, "one-frame tasks report a known run state")
  return self._state
end

---@param self BattleTwoStateTask
---@param reason string cancellation cause under diagnosis
function BattleTwoStateTask:cancel(reason)
  local _ = reason
  if self._state == "complete" then
    return
  end
  self._state = "cancelled"
end

---@param self BattleTwoStateTask
function BattleTwoStateTask:dispose()
  self._disposed = true
end

-- Object-window sprite task with native delay/show/hold phasing: an
-- invisible delay, one show tick publishing the object-window state,
-- a hold, then exact window cleanup and completion.
---@class BattleObjWindowTask
---@field _scene table<string, unknown> scene behind the window writes
---@field _ticks integer source ticks advanced
---@field _released boolean window cleanup has run
---@field _state string pending, running, complete, or cancelled
---@field _disposed boolean release has run
local BattleObjWindowTask = {}
BattleObjWindowTask.__index = BattleObjWindowTask

local OBJ_WINDOW_DELAY_TICKS = 10
local OBJ_WINDOW_HOLD_TICKS = 10

---@param kind string task kind under construction
---@param services table<string, unknown> scene collaborator
---@return BattleObjWindowTask runnable window task
local function newObjWindowTask(kind, services)
  local scene = checkScene(services, kind)
  return setmetatable({
    _scene = scene,
    _kind = kind,
    _ticks = 0,
    _released = false,
    _state = "pending",
    _disposed = false,
  }, BattleObjWindowTask)
end

---@param self BattleObjWindowTask window task under window publication
local function publishObjWindow(self)
  if type(self._scene.writeAnimationCompositor) == "function" then
    self._scene:writeAnimationCompositor(self, "main", {
      objectWindow = {
        visible = "object-window",
        outside = { bg0 = false, bg1 = false, bg2 = false, bg3 = false, obj = false },
        inside = { bg1 = false, obj = false },
      },
    })
  end
end

---@param self BattleObjWindowTask window task under window cleanup
local function teardownObjWindow(self)
  if self._released then
    return
  end
  self._released = true
  if type(self._scene.writeAnimationCompositor) == "function" then
    self._scene:writeAnimationCompositor(self, "main", {
      objectWindow = { visible = "none" },
    })
  end
end

---@param self BattleObjWindowTask
---@param tick table<string, unknown>? source tick under advancement
function BattleObjWindowTask:stepSourceTick(tick)
  local _ = tick
  if self._disposed or self._state == "complete" or self._state == "cancelled" then
    return
  end
  self._state = "running"
  self._ticks = self._ticks + 1
  if self._ticks == OBJ_WINDOW_DELAY_TICKS + 1 then
    publishObjWindow(self)
  elseif self._ticks >= OBJ_WINDOW_DELAY_TICKS + 1 + OBJ_WINDOW_HOLD_TICKS then
    teardownObjWindow(self)
    self._state = "complete"
  end
end

---@param self BattleObjWindowTask
---@return string
function BattleObjWindowTask:status()
  assert(VALID_TASK_STATES[self._state] == true, "object-window tasks report a known run state")
  return self._state
end

---@param self BattleObjWindowTask
---@param reason string cancellation cause under diagnosis
function BattleObjWindowTask:cancel(reason)
  local _ = reason
  if self._state == "complete" then
    return
  end
  self._state = "cancelled"
  teardownObjWindow(self)
end

---@param self BattleObjWindowTask
function BattleObjWindowTask:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
end

-- Resolves the picture activation a motion task owns: the explicit
-- spawning argument first, the semantic battler or picture target
-- through the detached occurrence topology, and the occurrence
-- attacker when the probe carries no explicit target.
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param kind string task kind under diagnosis
---@return table<string, unknown> combatant and activation pair behind the owned picture
local function motionActivation(args, context, kind)
  local resolved = plannedActivation(args, context)
  if resolved ~= nil then
    return resolved
  end
  local topology = type(context) == "table" and context.topology or nil
  local attacker = type(topology) == "table" and topology.attacker or nil
  if type(attacker) == "table" and type(attacker.combatant) == "number" then
    return { combatant = attacker.combatant, activation = attacker.activation }
  end
  error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " pictures its occurrence attacker", 0)
end

-- Sinusoidal picture motion writing the canonical battler center: the
-- native circle writes POKEPIC_X/Y, never the crop byte. The terminal
-- center persists after completion; cancellation removes the owned
-- overlay instead.
---@class BattleSinusoidalMotionTask
---@field _scene table<string, unknown> scene behind the owned overlay
---@field _activation table<string, unknown> combatant and activation pair behind the motion
---@field _fromX integer motion start in native pixels
---@field _toX integer motion end in native pixels
---@field _duration integer source ticks behind completion
---@field _ticks integer source ticks advanced
---@field _state string pending, running, complete, or cancelled
---@field _disposed boolean release has run
local BattleSinusoidalMotionTask = {}
BattleSinusoidalMotionTask.__index = BattleSinusoidalMotionTask

---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> scene collaborator
---@return BattleSinusoidalMotionTask runnable motion task
local function newSinusoidalMotionTask(kind, args, context, services)
  checkVisualArgs(args, kind)
  local scene = checkScene(services, kind)
  if type(scene.applyTaskPicturePatch) ~= "function" or type(scene.removeTaskPicturePatch) ~= "function" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " motions through the scene overlay seam", 0)
  end
  local activation = motionActivation(args, context, kind)
  local parameters = args.parameters
  if parameters == nil then
    parameters = {}
  end
  if type(parameters) ~= "table" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " carries its parameters as a record", 0)
  end
  local duration = parameters.durationTicks
  if not isPositiveInt(duration) then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " motions over a compiled duration", 0)
  end
  local fromX = parameters.startX or 0
  local toX = parameters.endX
  if toX == nil then
    toX = 16
  end
  if type(fromX) ~= "number" or type(toX) ~= "number" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " motions between numeric endpoints", 0)
  end
  return setmetatable({
    _scene = scene,
    _kind = kind,
    _activation = activation,
    _fromX = clampPictureOffset(fromX),
    _toX = clampPictureOffset(toX),
    _duration = duration,
    _ticks = 0,
    _state = "pending",
    _disposed = false,
  }, BattleSinusoidalMotionTask)
end

---@param self BattleSinusoidalMotionTask motion task under advancement
---@param tick table<string, unknown>? source tick under advancement
function BattleSinusoidalMotionTask:stepSourceTick(tick)
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
  local centerX = math.floor(self._fromX + (self._toX - self._fromX) * progress + 0.5)
  local ok, err = pcall(self._scene.applyTaskPicturePatch, self._scene, self, self._activation, {
    centerX = clampPictureOffset(centerX),
  })
  if not ok then
    pcall(self._scene.removeTaskPicturePatch, self._scene, self, self._activation)
    error(err, 0)
  end
  if self._ticks >= self._duration then
    -- Normal completion keeps the terminal center: no overlay reset.
    self._state = "complete"
  end
end

---@param self BattleSinusoidalMotionTask
---@return string
function BattleSinusoidalMotionTask:status()
  assert(VALID_TASK_STATES[self._state] == true, "sinusoidal motion tasks report a known run state")
  return self._state
end

---@param self BattleSinusoidalMotionTask
---@param reason string cancellation cause under diagnosis
function BattleSinusoidalMotionTask:cancel(reason)
  local _ = reason
  if self._state == "complete" then
    return
  end
  self._state = "cancelled"
  pcall(self._scene.removeTaskPicturePatch, self._scene, self, self._activation)
end

---@param self BattleSinusoidalMotionTask
function BattleSinusoidalMotionTask:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
end

-- Native side sign behind defender knockback: an even native sideType
-- reads side 3 (+1), an odd sideType reads side 4 (-1).
---@param context table<string, unknown> occurrence-bound playback context
---@param kind string task kind under diagnosis
---@return integer side sign behind the displacement
local function knockbackSideSign(context, kind)
  local topology = type(context) == "table" and context.topology or nil
  local targets = type(topology) == "table" and topology.targets or nil
  local first = type(targets) == "table" and targets[1] or nil
  local sideType = type(first) == "table" and first.sideType or nil
  if type(sideType) ~= "number" or sideType % 1 ~= 0 or sideType < 0 or sideType > 5 then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " knocks back a sided event target", 0)
  end
  return sideType % 2 == 0 and 1 or -1
end

-- Defender knockback with its source start/move/shake/return/end states:
-- a linear displacement, a shake at the displaced endpoint, a linear
-- return and an exact reset to the original center. Positions use the
-- exact fixed-point linear steps; the shake accumulates literally like
-- the source read of the current attribute each tick.
---@class BattleKnockbackTask
---@field _scene table<string, unknown> scene behind the owned overlay
---@field _kind string task kind behind the run
---@field _activation table<string, unknown> combatant and activation pair behind the motion
---@field _baseX number motion start center in native pixels
---@field _baseY number motion start center in native pixels
---@field _endX number displaced endpoint in native pixels
---@field _endY number displaced endpoint in native pixels
---@field _sign integer side sign behind the displacement
---@field _phase integer knockback phase behind advancement
---@field _moveX table<string, number> fixed-point horizontal motion under advancement
---@field _moveY table<string, number> fixed-point vertical motion under advancement
---@field _shake table<string, integer> shake state at the displaced endpoint
---@field _state string pending, running, complete, or cancelled
---@field _disposed boolean release has run
local BattleKnockbackTask = {}
BattleKnockbackTask.__index = BattleKnockbackTask

local KNOCKBACK_PHASES = { start = 1, move = 2, shake = 3, returning = 4, done = 5 }

---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> scene collaborator
---@return BattleKnockbackTask runnable knockback task
local function newKnockbackTask(kind, args, context, services)
  checkVisualArgs(args, kind)
  local scene = checkScene(services, kind)
  if type(scene.applyTaskPicturePatch) ~= "function" or type(scene.removeTaskPicturePatch) ~= "function" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " displaces through the scene overlay seam", 0)
  end
  local activation = motionActivation(args, context, kind)
  local present = scene:pictureState(activation)
  local baseX = 0
  local baseY = 0
  if type(present) == "table" then
    if type(present.centerX) == "number" then
      baseX = present.centerX
    end
    if type(present.centerY) == "number" then
      baseY = present.centerY
    end
  end
  local sign = knockbackSideSign(context, kind)
  local Fx = require("libs.hgss.src.presentation.PresentationFxMath")
  local endX = baseX + sign * -40
  local endY = baseY + sign * 16
  local function linearStep(fromValue, toValue, duration)
    return Fx.fxDiv((toValue - fromValue) * 4096, duration * 4096)
  end
  local moveX = { cur = baseX * 4096, step = linearStep(baseX, endX, 4), remaining = 4 }
  local moveY = { cur = baseY * 4096, step = linearStep(baseY, endY, 4), remaining = 4 }
  return setmetatable({
    _scene = scene,
    _kind = kind,
    _activation = activation,
    _baseX = baseX,
    _baseY = baseY,
    _endX = endX,
    _endY = endY,
    _sign = sign,
    _phase = KNOCKBACK_PHASES.start,
    _moveX = moveX,
    _moveY = moveY,
    _shake = { timer = 1, interval = 1, count = 4, phase = 0, prevX = -4, x = 0 },
    _state = "pending",
    _disposed = false,
  }, BattleKnockbackTask)
end

---@param self BattleKnockbackTask knockback task under overlay publication
---@param centerX number displaced horizontal center
---@param centerY number displaced vertical center
local function publishKnockback(self, centerX, centerY)
  local ok, err = pcall(
    self._scene.applyTaskPicturePatch,
    self._scene,
    self,
    self._activation,
    { centerX = clampPictureOffset(centerX), centerY = clampPictureOffset(centerY) }
  )
  if not ok then
    pcall(self._scene.removeTaskPicturePatch, self._scene, self, self._activation)
    error(err, 0)
  end
end

---@param motion table<string, number> fixed-point linear motion under advancement
---@return boolean advanced true while motion remains
local function advanceKnockbackLinear(motion)
  if motion.remaining ~= 0 then
    motion.cur = motion.cur + motion.step
    motion.remaining = motion.remaining - 1
    return true
  end
  return false
end

---@param self BattleKnockbackTask knockback task under advancement
---@param tick table<string, unknown>? source tick under advancement
function BattleKnockbackTask:stepSourceTick(tick)
  local _ = tick
  if self._disposed or self._state == "complete" or self._state == "cancelled" then
    return
  end
  self._state = "running"
  if self._phase == KNOCKBACK_PHASES.start then
    self._phase = KNOCKBACK_PHASES.move
    return
  end
  if self._phase == KNOCKBACK_PHASES.move then
    if advanceKnockbackLinear(self._moveX) then
      advanceKnockbackLinear(self._moveY)
      publishKnockback(self, math.floor(self._moveX.cur / 4096), math.floor(self._moveY.cur / 4096))
      return
    end
    self._phase = KNOCKBACK_PHASES.shake
    return
  end
  if self._phase == KNOCKBACK_PHASES.shake then
    local shake = self._shake
    local advanced = false
    if shake.count ~= 0 then
      shake.timer = shake.timer + 1
      if shake.timer >= shake.interval then
        shake.timer = 0
        local previous = shake.prevX
        shake.prevX = shake.x
        shake.x = previous == 0 and 0 or -previous
        shake.phase = shake.phase + 1
        if shake.phase >= 4 then
          shake.phase = 0
          shake.count = shake.count - 1
        end
      end
      advanced = true
    end
    if advanced then
      local present = self._scene:pictureState(self._activation)
      local currentX = self._baseX
      local currentY = self._baseY
      if type(present) == "table" then
        if type(present.centerX) == "number" then
          currentX = present.centerX
        end
        if type(present.centerY) == "number" then
          currentY = present.centerY
        end
      end
      publishKnockback(self, currentX + shake.x, currentY)
      return
    end
    local Fx = require("libs.hgss.src.presentation.PresentationFxMath")
    local function linearStep(fromValue, toValue, duration)
      return Fx.fxDiv((toValue - fromValue) * 4096, duration * 4096)
    end
    self._moveX = { cur = self._endX * 4096, step = linearStep(self._endX, self._baseX, 4), remaining = 4 }
    self._moveY = { cur = self._endY * 4096, step = linearStep(self._endY, self._baseY, 4), remaining = 4 }
    self._phase = KNOCKBACK_PHASES.returning
    return
  end
  if self._phase == KNOCKBACK_PHASES.returning then
    if advanceKnockbackLinear(self._moveX) then
      publishKnockback(self, math.floor(self._moveX.cur / 4096), math.floor(self._moveY.cur / 4096))
      return
    end
    self._phase = KNOCKBACK_PHASES.done
    return
  end
  publishKnockback(self, self._baseX, self._baseY)
  pcall(self._scene.removeTaskPicturePatch, self._scene, self, self._activation)
  self._state = "complete"
end

---@param self BattleKnockbackTask
---@return string
function BattleKnockbackTask:status()
  assert(VALID_TASK_STATES[self._state] == true, "knockback tasks report a known run state")
  return self._state
end

---@param self BattleKnockbackTask
---@param reason string cancellation cause under diagnosis
function BattleKnockbackTask:cancel(reason)
  local _ = reason
  if self._state == "complete" then
    return
  end
  self._state = "cancelled"
  pcall(self._scene.removeTaskPicturePatch, self._scene, self, self._activation)
end

---@param self BattleKnockbackTask
function BattleKnockbackTask:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
end

-- Attacker squash and stretch with its five source scale phases: each
-- phase interpolates XY scales with the source start/end/divisor and
-- duration, and completion writes the explicit 1.0 terminal reset.
-- Scale arithmetic uses the exact fixed-point steps.
---@class BattleFivePhaseTask
---@field _scene table<string, unknown> scene behind the owned overlay
---@field _kind string task kind behind the run
---@field _activation table<string, unknown> combatant and activation pair behind the motion
---@field _phase integer one-based phase behind initialization
---@field _scaleX table<string, integer>? fixed-point horizontal scale motion under advancement
---@field _scaleY table<string, integer>? fixed-point vertical scale motion under advancement
---@field _state string pending, running, complete, or cancelled
---@field _disposed boolean release has run
---@field _fx PresentationFxMath fixed-point arithmetic behind the phase steps
local BattleFivePhaseTask = {}
BattleFivePhaseTask.__index = BattleFivePhaseTask

local FIVE_PHASES = {
  { startX = 100, endX = 150, startY = 100, endY = 50, divisor = 100, duration = 10 },
  { startX = 150, endX = 50, startY = 50, endY = 150, divisor = 100, duration = 10 },
  { startX = 50, endX = 100, startY = 150, endY = 100, divisor = 100, duration = 5 },
  { startX = 100, endX = 150, startY = 100, endY = 150, divisor = 100, duration = 5 },
  { startX = 150, endX = 100, startY = 150, endY = 100, divisor = 100, duration = 5 },
}

---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> scene collaborator
---@return BattleFivePhaseTask runnable squash/stretch task
local function newFivePhaseTask(kind, args, context, services)
  checkVisualArgs(args, kind)
  local scene = checkScene(services, kind)
  if type(scene.applyTaskPicturePatch) ~= "function" or type(scene.removeTaskPicturePatch) ~= "function" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " scales through the scene overlay seam", 0)
  end
  local activation = motionActivation(args, context, kind)
  local Fx = require("libs.hgss.src.presentation.PresentationFxMath")
  return setmetatable({
    _scene = scene,
    _kind = kind,
    _activation = activation,
    _phase = 1,
    _scaleX = nil,
    _scaleY = nil,
    _state = "pending",
    _disposed = false,
    _fx = Fx,
  }, BattleFivePhaseTask)
end

---@param self BattleFivePhaseTask squash/stretch task under phase initialization
---@param phase integer one-based phase behind initialization
local function initFivePhase(self, phase)
  local spec = FIVE_PHASES[phase]
  local startScaleX = math.floor(spec.startX * 256 / spec.divisor)
  local endScaleX = math.floor(spec.endX * 256 / spec.divisor)
  local startScaleY = math.floor(spec.startY * 256 / spec.divisor)
  local endScaleY = math.floor(spec.endY * 256 / spec.divisor)
  self._scaleX = {
    cur = startScaleX * 4096,
    step = self._fx.fxDiv((endScaleX - startScaleX) * 4096, spec.duration * 4096),
    remaining = spec.duration,
  }
  self._scaleY = {
    cur = startScaleY * 4096,
    step = self._fx.fxDiv((endScaleY - startScaleY) * 4096, spec.duration * 4096),
    remaining = spec.duration,
  }
end

---@param motion table<string, integer> fixed-point scale motion under advancement
---@return boolean advanced true while motion remains
local function advanceFivePhaseScale(motion)
  if motion.remaining ~= 0 then
    motion.remaining = motion.remaining - 1
    motion.cur = motion.cur + motion.step
    return true
  end
  return false
end

---@param self BattleFivePhaseTask squash/stretch task under scale publication
local function publishFivePhase(self)
  local scaleX = math.floor(self._scaleX.cur / 4096) / 256
  local scaleY = math.floor(self._scaleY.cur / 4096) / 256
  local ok, err =
    pcall(self._scene.applyTaskPicturePatch, self._scene, self, self._activation, { scaleX = scaleX, scaleY = scaleY })
  if not ok then
    pcall(self._scene.removeTaskPicturePatch, self._scene, self, self._activation)
    error(err, 0)
  end
end

---@param self BattleFivePhaseTask
---@param tick table<string, unknown>? source tick under advancement
function BattleFivePhaseTask:stepSourceTick(tick)
  local _ = tick
  if self._disposed or self._state == "complete" or self._state == "cancelled" then
    return
  end
  self._state = "running"
  if self._scaleX == nil then
    initFivePhase(self, 1)
  end
  if advanceFivePhaseScale(self._scaleX) then
    advanceFivePhaseScale(self._scaleY)
    publishFivePhase(self)
    return
  end
  if self._phase < #FIVE_PHASES then
    self._phase = self._phase + 1
    initFivePhase(self, self._phase)
    return
  end
  -- Explicit terminal reset on the final transition tick, not an
  -- overlay removal: the completed run reports its reset at once.
  local ok, err =
    pcall(self._scene.applyTaskPicturePatch, self._scene, self, self._activation, { scaleX = 1.0, scaleY = 1.0 })
  if not ok then
    pcall(self._scene.removeTaskPicturePatch, self._scene, self, self._activation)
    error(err, 0)
  end
  self._state = "complete"
end

---@param self BattleFivePhaseTask
---@return string
function BattleFivePhaseTask:status()
  assert(VALID_TASK_STATES[self._state] == true, "squash/stretch tasks report a known run state")
  return self._state
end

---@param self BattleFivePhaseTask
---@param reason string cancellation cause under diagnosis
function BattleFivePhaseTask:cancel(reason)
  local _ = reason
  if self._state == "complete" then
    return
  end
  self._state = "cancelled"
  pcall(self._scene.removeTaskPicturePatch, self._scene, self, self._activation)
end

---@param self BattleFivePhaseTask
function BattleFivePhaseTask:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
end

-- Sprite mosaic task stepping both mosaic dimensions toward the source
-- target: the sizes persist after retirement until an explicit reset.
---@class BattleMosaicTask
---@field _scene table<string, unknown> scene behind the owned compositor overlay
---@field _kind string task kind behind the run
---@field _sizeH number current horizontal mosaic dimension
---@field _sizeV number current vertical mosaic dimension
---@field _step integer compiled step toward the mosaic target
---@field _target integer mosaic target dimension behind completion
---@field _duration integer source ticks behind completion
---@field _ticks integer source ticks advanced
---@field _state string pending, running, complete, or cancelled
---@field _disposed boolean release has run
local BattleMosaicTask = {}
BattleMosaicTask.__index = BattleMosaicTask

---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param services table<string, unknown> scene collaborator
---@return BattleMosaicTask runnable mosaic task
local function newMosaicTask(kind, args, services)
  checkVisualArgs(args, kind)
  local scene = checkScene(services, kind)
  if type(scene.writeAnimationCompositor) ~= "function" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " mosaics through the scene compositor seam", 0)
  end
  local parameters = args.parameters
  if type(parameters) ~= "table" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " carries its parameters as a record", 0)
  end
  local step = parameters.step
  local sizeH = parameters.initialHorizontal
  local sizeV = parameters.initialVertical
  local duration = parameters.durationTicks
  if type(step) ~= "number" or step % 1 ~= 0 or step == 0 then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " steps toward its mosaic target", 0)
  end
  if type(sizeH) ~= "number" or type(sizeV) ~= "number" or not isPositiveInt(duration) then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " mosaics from compiled dimensions", 0)
  end
  local target = step < 0 and 0 or 15
  return setmetatable({
    _scene = scene,
    _kind = kind,
    _sizeH = sizeH,
    _sizeV = sizeV,
    _step = step,
    _target = target,
    _duration = duration,
    _ticks = 0,
    _state = "pending",
    _disposed = false,
  }, BattleMosaicTask)
end

---@param self BattleMosaicTask mosaic task under advancement
---@param tick table<string, unknown>? source tick under advancement
function BattleMosaicTask:stepSourceTick(tick)
  local _ = tick
  if self._disposed or self._state == "complete" or self._state == "cancelled" then
    return
  end
  self._state = "running"
  self._ticks = self._ticks + 1
  if self._sizeH ~= self._target and self._sizeV ~= self._target then
    local nextH = self._sizeH + self._step
    local nextV = self._sizeV + self._step
    if self._step < 0 then
      if nextH <= self._target then
        nextH = self._target
      end
      if nextV <= self._target then
        nextV = self._target
      end
    else
      if nextH >= self._target then
        nextH = self._target
      end
      if nextV >= self._target then
        nextV = self._target
      end
    end
    self._sizeH = nextH
    self._sizeV = nextV
  end
  local ok, err = pcall(self._scene.writeAnimationCompositor, self._scene, self, "main", {
    mosaic = {
      horizontal = self._sizeH,
      vertical = self._sizeV,
      bgEnabled = true,
      objEnabled = true,
    },
  })
  if not ok then
    error(err, 0)
  end
  if self._ticks >= self._duration then
    self._state = "complete"
  end
end

---@param self BattleMosaicTask
---@return string
function BattleMosaicTask:status()
  assert(VALID_TASK_STATES[self._state] == true, "mosaic tasks report a known run state")
  return self._state
end

---@param self BattleMosaicTask
---@param reason string cancellation cause under diagnosis
function BattleMosaicTask:cancel(reason)
  local _ = reason
  if self._state == "complete" then
    return
  end
  self._state = "cancelled"
end

---@param self BattleMosaicTask
function BattleMosaicTask:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
end

-- Source scanline wave writing per-row offsets into the 192-row buffer:
-- rows carry independent sine offsets every tick instead of shifting
-- one viewport. Completion frees the wave with an explicit zeroing.
---@class BattleScanlineWaveTask
---@field _scene table<string, unknown> scene behind the owned scanline rows
---@field _kind string task kind behind the run
---@field _duration integer source ticks behind completion
---@field _ticks integer source ticks advanced
---@field _state string pending, running, complete, or cancelled
---@field _disposed boolean release has run
local BattleScanlineWaveTask = {}
BattleScanlineWaveTask.__index = BattleScanlineWaveTask

local SCANLINE_ROWS = 192
local SCANLINE_WAVE_ROWS = 160
local SCANLINE_WAVE_STEP = 341
local SCANLINE_WAVE_AMPLITUDE = 32

---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param services table<string, unknown> scene collaborator
---@return BattleScanlineWaveTask runnable wave task
local function newScanlineWaveTask(kind, args, _, services)
  checkVisualArgs(args, kind)
  local scene = checkScene(services, kind)
  if type(scene.writeScanlineRows) ~= "function" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " waves through the scene scanline seam", 0)
  end
  local parameters = args.parameters
  if type(parameters) ~= "table" or not isPositiveInt(parameters.durationTicks) then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " rides its compiled duration", 0)
  end
  return setmetatable({
    _scene = scene,
    _kind = kind,
    _duration = parameters.durationTicks,
    _ticks = 0,
    _state = "pending",
    _disposed = false,
  }, BattleScanlineWaveTask)
end

---@param self BattleScanlineWaveTask wave task under row publication
local function publishScanlineRows(self)
  local Fx = require("libs.hgss.src.presentation.PresentationFxMath")
  local rows = {}
  for row = 0, SCANLINE_ROWS - 1 do
    if row < SCANLINE_WAVE_ROWS then
      local angle = (row * SCANLINE_WAVE_STEP + self._ticks * 1024) % 65536
      local sine = Fx.sinIdx(angle)
      local offset = sine >= 0 and math.floor(sine * SCANLINE_WAVE_AMPLITUDE / 4096 + 0.5)
        or math.ceil(sine * SCANLINE_WAVE_AMPLITUDE / 4096 - 0.5)
      rows[row + 1] = { x = offset, y = 0 }
    else
      rows[row + 1] = { x = 0, y = 0 }
    end
  end
  self._scene:writeScanlineRows(rows)
end

---@param self BattleScanlineWaveTask wave task under wave cleanup
local function clearScanlineRows(self)
  local rows = {}
  for index = 1, SCANLINE_ROWS do
    rows[index] = { x = 0, y = 0 }
  end
  self._scene:writeScanlineRows(rows)
end

---@param self BattleScanlineWaveTask
---@param tick table<string, unknown>? source tick under advancement
function BattleScanlineWaveTask:stepSourceTick(tick)
  local _ = tick
  if self._disposed or self._state == "complete" or self._state == "cancelled" then
    return
  end
  self._state = "running"
  self._ticks = self._ticks + 1
  if self._ticks >= self._duration then
    clearScanlineRows(self)
    self._state = "complete"
    return
  end
  publishScanlineRows(self)
end

---@param self BattleScanlineWaveTask
---@return string
function BattleScanlineWaveTask:status()
  assert(VALID_TASK_STATES[self._state] == true, "scanline wave tasks report a known run state")
  return self._state
end

---@param self BattleScanlineWaveTask
---@param reason string cancellation cause under diagnosis
function BattleScanlineWaveTask:cancel(reason)
  local _ = reason
  if self._state == "complete" then
    return
  end
  self._state = "cancelled"
  pcall(clearScanlineRows, self)
end

---@param self BattleScanlineWaveTask
function BattleScanlineWaveTask:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
end

-- Dedicated background bodies by emitted kind. Every other admitted
-- kind keeps its established picture/sprite body in the dispatch below;
-- the generic native visual task never sees these six spellings again.
local BACKGROUND_TASK_CONSTRUCTORS = {
  ["battle-background-four-picture-move-power-transition"] = newMovePowerProfileTask,
  ["battle-background-alternating-scroll-transition"] = newAlternatingScrollTask,
  ["battle-background-scanline-sine-wave-transition"] = newScanlineWaveTask,
  ["battle-sprite-blend-alpha-transition"] = newBlendCoefficientTask,
  ["battle-background-resource-load"] = newBackgroundResourceLoadTask,
  ["battle-presentation-resource-cleanup"] = newBackgroundResourceCleanupTask,
}

-- Curved emitter path with lazy handle binding: construction validates
-- its operands, the first tick binds the occurrence handle, and an
-- absent emitter completes at once while a bound emitter runs the
-- source linear-plus-half-cosine arc against the occurrence-bound handle.
---@class BattleEmitterArcTask
---@field _kind string task kind behind the run
---@field _context table<string, unknown> occurrence-bound playback context behind handle binding
---@field _systemSlot integer logical particle system slot behind handle binding
---@field _slot integer emitter slot behind handle binding
---@field _duration integer source ticks behind the arc
---@field _bound boolean an emitter backs the path
---@field _handle table<string, unknown>? bound emitter handle, nil before binding
---@field _linear table<string, integer>? fixed-point linear motion under advancement, nil before binding
---@field _sin table<string, integer>? fixed-point sine motion under advancement, nil before binding
---@field _origin table<string, integer>? bound emitter origin, nil before binding
---@field _fx PresentationFxMath? fixed-point arithmetic behind the arc, nil before binding
---@field _ticks integer source ticks advanced
---@field _state string pending, running, complete, or cancelled
---@field _disposed boolean release has run
local BattleEmitterArcTask = {}
BattleEmitterArcTask.__index = BattleEmitterArcTask

---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> scene, audio, and resource collaborators
---@return BattleEmitterArcTask runnable arc task
local function newEmitterArcTask(kind, args, context, services)
  local _ = services
  if type(args) ~= "table" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " carries its path operands as a record", 0)
  end
  local parameters = args.parameters
  if type(parameters) ~= "table" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " carries its path operands as a record", 0)
  end
  local duration = parameters.durationTicks
  if type(duration) ~= "number" or duration % 1 ~= 0 or duration < 1 then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " arcs over a positive duration", 0)
  end
  local slot = parameters.emitterSlot
  if type(slot) ~= "number" or slot % 1 ~= 0 or slot < 0 or slot > 15 then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " arcs an emitter slot in 0..15", 0)
  end
  return setmetatable({
    _kind = kind,
    _context = context,
    _systemSlot = parameters.systemSlot or 0,
    _slot = slot,
    _duration = duration,
    _bound = false,
    _handle = nil,
    _linear = nil,
    _sin = nil,
    _ticks = 0,
    _state = "pending",
    _disposed = false,
  }, BattleEmitterArcTask)
end

---@param self BattleEmitterArcTask arc task under handle binding
---@return boolean bound true while an emitter backs the path
local function bindEmitterArc(self)
  local ParticleSystems = require("libs.hgss.src.presentation.BattleParticleSystems")
  local ok, handle = pcall(ParticleSystems.getEmitterHandle, self._context, self._systemSlot, self._slot)
  if not ok or type(handle) ~= "table" then
    return false
  end
  self._handle = handle
  local Fx = require("libs.hgss.src.presentation.PresentationFxMath")
  local position = handle:getPositionFx32()
  self._linear = { x = 0, y = 0, curX = 0, curY = 0, stepX = 0, stepY = 0, remaining = self._duration }
  self._sin = {
    angleX = 0,
    angleY = 0,
    stepX = math.floor(16383 / self._duration),
    stepY = math.floor(49151 / self._duration),
    remaining = self._duration,
  }
  self._origin = { x = position.x, y = position.y }
  self._fx = Fx
  self._bound = true
  return true
end

---@param motion table<string, integer> fixed-point linear motion under advancement
---@return boolean advanced true while motion remains
local function advanceArcLinear(motion)
  if motion.remaining ~= 0 then
    motion.curX = motion.curX + motion.stepX
    motion.curY = motion.curY + motion.stepY
    motion.x = math.floor(motion.curX / 4096)
    motion.y = math.floor(motion.curY / 4096)
    motion.remaining = motion.remaining - 1
    return true
  end
  return false
end

---@param self BattleEmitterArcTask arc task under sine advancement
---@return boolean advanced true while the arc remains
local function advanceArcSine(self)
  local sin = self._sin
  assert(sin ~= nil, "bound emitter arcs advance their sine motion")
  if sin.remaining == 0 then
    return false
  end
  sin.angleX = (sin.angleX + sin.stepX) % 65536
  sin.angleY = (sin.angleY + sin.stepY) % 65536
  sin.remaining = sin.remaining - 1
  return true
end

---@param self BattleEmitterArcTask arc task under advancement
---@param tick table<string, unknown>? source tick under advancement
function BattleEmitterArcTask:stepSourceTick(tick)
  local _ = tick
  if self._disposed or self._state == "complete" or self._state == "cancelled" then
    return
  end
  self._state = "running"
  if not self._bound then
    if not bindEmitterArc(self) then
      -- No emitter backs the slot: the source-null path completes at
      -- once instead of refusing to construct.
      self._state = "complete"
      return
    end
  end
  self._ticks = self._ticks + 1
  local linearActive = advanceArcLinear(self._linear)
  local sineActive = advanceArcSine(self)
  local active = false
  local ok, isActive = pcall(self._handle.isActive, self._handle)
  if ok then
    active = isActive
  end
  if not linearActive and not sineActive and not active then
    pcall(self._handle.delete, self._handle)
    self._state = "complete"
    return
  end
  local okPosition, position = pcall(self._handle.getPositionFx32, self._handle)
  if okPosition and type(position) == "table" then
    pcall(self._handle.setPositionFx32, self._handle, {
      x = self._origin.x + self._linear.x,
      y = self._origin.y + self._linear.y,
    })
  end
end

---@param self BattleEmitterArcTask
---@return string
function BattleEmitterArcTask:status()
  assert(VALID_TASK_STATES[self._state] == true, "curved emitter paths report a known run state")
  return self._state
end

---@param self BattleEmitterArcTask
---@param reason string cancellation cause under diagnosis
function BattleEmitterArcTask:cancel(reason)
  local _ = reason
  if self._state == "complete" then
    return
  end
  self._state = "cancelled"
end

---@param self BattleEmitterArcTask
function BattleEmitterArcTask:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
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
  if kind == BattleEffectTasks.PARTICLE_SYSTEM_KIND or kind == BattleEffectTasks.PARTICLE_CONTINUATION_KIND then
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
  if kind == "pokemon-battler-sprite-slot" then
    return true
  end
  if SOUND_TASK_KINDS[kind] == true then
    return true
  end
  if
    kind == "battle-visual-none"
    or kind == "battle-visual-one-frame-task"
    or kind == "battle-visual-one-frame-sound-task"
    or kind == "battle-visual-one-frame-uncounted-task"
    or kind == "battle-visual-show-attacker-obj-window-sprites"
  then
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
  if kind == BattleEffectTasks.PARTICLE_SYSTEM_KIND then
    assert(type(services) == "table", "particle systems require their services record")
    return BattleParticleSystems.newSystemTask(
      args or {},
      context or {},
      services,
      { stage = stageLease, release = releaseStaged }
    )
  end
  if kind == BattleEffectTasks.PARTICLE_CONTINUATION_KIND then
    return BattleParticleSystems.newEmitterTask(args or {}, context or {})
  end
  if kind == BattleEffectTasks.EMITTER_BATTLER_PATH_KIND then
    return BattleParticleSystems.newPathTask(args or {}, context or {})
  end
  if kind == BattleEffectTasks.EMITTER_CURVED_PATH_KIND then
    return newEmitterArcTask(kind, args or {}, context or {}, services or {})
  end
  if kind == BattleEffectTasks.PICTURE_ANIMATION_KIND then
    assert(type(services) == "table", "picture animations require their services record")
    return newPictureAnimation(args or {}, context or {}, services)
  end
  if kind == "pokemon-battler-sprite-slot" then
    assert(type(services) == "table", "battler sprite slots require their services record")
    return newBattlerSpriteSlotTask(args or {}, context or {}, services)
  end
  if kind == "battle-visual-none" then
    return newSyncNoopTask(kind)
  end
  if
    kind == "battle-visual-one-frame-task"
    or kind == "battle-visual-one-frame-sound-task"
    or kind == "battle-visual-one-frame-uncounted-task"
  then
    return newTwoStateTask(kind)
  end
  if kind == "battle-visual-show-attacker-obj-window-sprites" then
    assert(type(services) == "table", "object-window sprites require their services record")
    return newObjWindowTask(kind, services)
  end
  if kind == "pokemon-picture-sinusoidal-position-motion" then
    assert(type(services) == "table", "sinusoidal motion requires its services record")
    return newSinusoidalMotionTask(kind, args or {}, context or {}, services)
  end
  if kind == "pokemon-picture-defender-knockback" then
    assert(type(services) == "table", "defender knockback requires its services record")
    return newKnockbackTask(kind, args or {}, context or {}, services)
  end
  if kind == "pokemon-picture-five-phase-affine-size-transition" then
    assert(type(services) == "table", "squash/stretch requires its services record")
    return newFivePhaseTask(kind, args or {}, context or {}, services)
  end
  if kind == "battle-sprite-mosaic-transition" then
    assert(type(services) == "table", "sprite mosaic requires its services record")
    return newMosaicTask(kind, args or {}, services)
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
    if kind == "pokemon-picture-position-path-transition" then
      return newPositionPathTask(args or {}, context or {}, services)
    end
    return newNativeVisualTask(kind, args or {}, context or {}, services)
  end
  error("BATTLE_EFFECT_TASK_UNKNOWN: no native task implementation for kind " .. tostring(kind), 0)
end

return BattleEffectTasks
