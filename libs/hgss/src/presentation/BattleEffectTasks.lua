-- Battle-private effect task factory for normalized battle animations.
-- Native task bodies live in src/battle/battle_anim_effects.c and drive
-- sys tasks through BattleAnimSystem_CreateTaskOfKind (kind 1 counts
-- taskCount, kind 2 counts soundTaskCount); raw visual work uses
-- SysTask_CreateOnMainQueue directly and stays outside both counters.
-- The player schedules work through this factory as
-- Factory.create(kind, args, context, services); unknown kinds fail here
-- instead of returning a timer stand-in. Voice monitoring, background
-- blend transitions, battler particle continuations, and animated
-- picture reveals have bodies in this lane; every other native task kind
-- still fails closed until its implementation lands.

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

-- Source-tick budgets behind completion: every body finishes well inside
-- the player's bounded waits (the battler-effects wait escapes after
-- sixteen parked ticks) so completion is the body's own boundary, never
-- the wait backstop.
local BLEND_DURATION_TICKS = 8
local PARTICLE_DURATION_TICKS = 12
local PICTURE_DURATION_TICKS = 6

-- Particle visual draws per source tick and their native coefficient
-- bound. The count stays fixed so the same seed always draws the same
-- sequence at any host schedule.
local PARTICLE_DRAWS_PER_TICK = 2
local PARTICLE_DRAW_BOUND = 256

-- Occurrence-scoped resource keys staged by bodies whose spawning
-- instruction carries no producer selection of its own. The services seam
-- owns these keys; the factory only holds and releases them exactly
-- once per occurrence.
local BLEND_CHARACTER_KEY = "battle/effect-background/character"
local BLEND_PALETTE_KEY = "battle/effect-background/palette"
local PICTURE_ANIMATION_KEY = "battle/pokemon-picture/animation"

-- Fallback selections behind direct (player-bypass) construction, which
-- carries no spawning instruction. Player-spawned continuations always
-- carry their own resource and emitter; the fallback only keeps the
-- argless construction path runnable and deterministic.
local DEFAULT_PARTICLE_RESOURCE = "battle/particle/tackle"
local DEFAULT_PARTICLE_EMITTER = "solo-enemy"

-- Temporary picture offset behind animated reveals. The first
-- application saves the presented values and completion, cancellation,
-- and disposal restore that exact snapshot, so no stale change reaches a
-- replacement activation.
local PICTURE_OFFSET_NUDGE = 8

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

---@param services table<string, unknown>? collaborators under validation
---@param kind string task kind under construction
---@return table<string, unknown> scene behind transient effect records
local function checkScene(services, kind)
  if type(services) ~= "table" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " constructs without its services record", 0)
  end
  local scene = services.scene
  if type(scene) ~= "table" then
    error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " constructs without its scene", 0)
  end
  for _, method in ipairs({ "allocEffect", "setEffectPicture", "releaseEffect" }) do
    if type(scene[method]) ~= "function" then
      error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " constructs without scene effect ownership", 0)
    end
  end
  return scene --[[@as table<string, unknown>]]
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

---@class BattleBlendTransition
---@field _scene table<string, unknown> scene behind the transient effect record
---@field _staged table<integer, BattleEffectLeaseRecord> occurrence leases behind exactly-once release
---@field _effectId integer? live effect identity, when published
---@field _effectReleased boolean transient record has been released
---@field _ticks integer source ticks advanced
---@field _duration integer source ticks behind completion
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
  local scene = checkScene(services, BattleEffectTasks.BLEND_TRANSITION_KIND)
  local staged = {}
  stageLease(BattleEffectTasks.BLEND_TRANSITION_KIND, BLEND_CHARACTER_KEY, services, staged)
  stageLease(BattleEffectTasks.BLEND_TRANSITION_KIND, BLEND_PALETTE_KEY, services, staged)
  local effectId = publishEffect(
    scene,
    BattleEffectTasks.BLEND_TRANSITION_KIND,
    stagedPicture("battle/effect-background/blend", "blend-transition", 128, 80, 1)
  )
  return setmetatable({
    _scene = scene,
    _staged = staged,
    _effectId = effectId,
    _effectReleased = false,
    _ticks = 0,
    _duration = BLEND_DURATION_TICKS,
    _state = "pending",
    _cancelReason = nil,
    _disposed = false,
  }, BattleBlendTransition)
end

-- Releases the transient record and every staged lease exactly once.
---@param self BattleBlendTransition
local function teardownBlend(self)
  if not self._effectReleased then
    self._effectReleased = true
    if self._effectId ~= nil then
      self._scene.releaseEffect(self._scene, self._effectId)
    end
  end
  releaseStaged(self._staged)
end

-- Advances one source tick toward the blend boundary. The task holds its
-- effect-background staging for its whole lifetime and releases it on
-- completion, so a finished blend never lingers over the next effect.
---@param self BattleBlendTransition
---@param tick table<string, unknown>? source tick under advancement
function BattleBlendTransition:stepSourceTick(tick)
  local _ = tick
  if self._disposed or self._state == "complete" or self._state == "cancelled" then
    return
  end
  self._state = "running"
  self._ticks = self._ticks + 1
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

-- Releases the transient record and every staged lease exactly once.
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
  local scene = checkScene(services, BattleEffectTasks.PARTICLE_CONTINUATION_KIND)
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
---@field _scene table<string, unknown> scene behind the transient effect record
---@field _staged table<integer, BattleEffectLeaseRecord> occurrence leases behind exactly-once release
---@field _activation table<string, unknown>? combatant and activation pair behind the picture change
---@field _applied boolean temporary picture change is active
---@field _effectId integer? live effect identity, when published
---@field _effectReleased boolean transient record has been released
---@field _ticks integer source ticks advanced
---@field _duration integer source ticks behind completion
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

---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> scene, audio, and resource collaborators
---@return BattlePictureAnimation runnable picture task
local function newPictureAnimation(args, context, services)
  local _ = context
  if args.battlerSelector ~= nil and type(args.battlerSelector) ~= "number" then
    error(
      "BATTLE_EFFECT_TASK_MALFORMED: kind "
        .. BattleEffectTasks.PICTURE_ANIMATION_KIND
        .. " addresses its battler with a numeric selector",
      0
    )
  end
  if args.mode ~= nil and type(args.mode) ~= "number" then
    error(
      "BATTLE_EFFECT_TASK_MALFORMED: kind "
        .. BattleEffectTasks.PICTURE_ANIMATION_KIND
        .. " carries its picture mode numerically",
      0
    )
  end
  local activation = args.activation
  if activation ~= nil and not validActivation(activation) then
    error(
      "BATTLE_EFFECT_TASK_MALFORMED: kind "
        .. BattleEffectTasks.PICTURE_ANIMATION_KIND
        .. " pictures a combatant activation pair",
      0
    )
  end
  local scene = checkScene(services, BattleEffectTasks.PICTURE_ANIMATION_KIND)
  local staged = {}
  stageLease(BattleEffectTasks.PICTURE_ANIMATION_KIND, PICTURE_ANIMATION_KEY, services, staged)
  local owned = nil
  local applied = false
  if activation ~= nil then
    owned = { combatant = activation.combatant, activation = activation.activation }
    if type(scene.applyPictureState) == "function" and type(scene.restorePictureState) == "function" then
      scene.applyPictureState(scene, owned, { pictureXOffset2 = PICTURE_OFFSET_NUDGE })
      applied = true
    end
  end
  local effectId = publishEffect(
    scene,
    BattleEffectTasks.PICTURE_ANIMATION_KIND,
    stagedPicture("battle/pokemon-picture/reveal", "picture-animation", 128, 80, 1)
  )
  return setmetatable({
    _scene = scene,
    _staged = staged,
    _activation = owned,
    _applied = applied,
    _effectId = effectId,
    _effectReleased = false,
    _ticks = 0,
    _duration = PICTURE_DURATION_TICKS,
    _state = "pending",
    _cancelReason = nil,
    _disposed = false,
  }, BattlePictureAnimation)
end

-- Restores the exact pre-effect picture snapshot (only when this
-- occurrence still owns the activation), then releases the transient
-- record and every staged lease exactly once.
---@param self BattlePictureAnimation
local function teardownPicture(self)
  if self._applied then
    self._applied = false
    if self._activation ~= nil then
      self._scene.restorePictureState(self._scene, self._activation)
    end
  end
  if not self._effectReleased then
    self._effectReleased = true
    if self._effectId ~= nil then
      self._scene.releaseEffect(self._scene, self._effectId)
    end
  end
  releaseStaged(self._staged)
end

-- Advances one source tick toward the picture boundary. The temporary
-- change stays owned by this occurrence's activation, so withdrawing or
-- replacing the activation never lets a stale restore reach the new
-- owner: withdrawal drops the stored patch with the old activation.
---@param self BattlePictureAnimation
---@param tick table<string, unknown>? source tick under advancement
function BattlePictureAnimation:stepSourceTick(tick)
  local _ = tick
  if self._disposed or self._state == "complete" or self._state == "cancelled" then
    return
  end
  self._state = "running"
  self._ticks = self._ticks + 1
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

-- Releases the picture snapshot, the transient record, and every staged
-- lease exactly once.
---@param self BattlePictureAnimation
function BattlePictureAnimation:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  teardownPicture(self)
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
  error("BATTLE_EFFECT_TASK_UNKNOWN: no native task implementation for kind " .. tostring(kind), 0)
end

return BattleEffectTasks
