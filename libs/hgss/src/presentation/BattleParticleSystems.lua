-- Battle move particle systems (src/battle/battle_anim_system.c
-- BattleAnimScriptCmd_LoadParticleSystem / CreateEmitter / WaitForParticles /
-- FreeParticleSystem, battle_anim_emitter.c emitter callbacks, and
-- battle_anim_funcs.c BattleAnimFunc_MoveEmitter). One system task owns one
-- loaded particle system for the occurrence: its SPL simulation, its leased
-- textures, and its scene registration for drawing. Each emitter creation is a
-- particle-group task that owns one emitter of that system until the emitter
-- leaves; the shared per-occurrence registry (context.particles) is how the
-- creation commands, the emitter tasks, and the emitter path callback find
-- each other. Placement comes from the staged battler emitter placement table.
-- Vocabulary the replay does not reproduce (a member the producer could not
-- compile, an emitter callback, a flipped camera, a curved path) fails loudly
-- at construction with its kind and cause: nothing plays invented motion and
-- nothing completes silently.

local SplParticleSimulation = require("libs.hgss.src.presentation.SplParticleSimulation")

local BattleParticleSystems = {}

BattleParticleSystems.SYSTEM_KIND = "battle-particle-system"
BattleParticleSystems.EMITTER_KIND = "battler-effect-continuation"
BattleParticleSystems.PATH_KIND = "battle-particle-emitter-battler-path"
BattleParticleSystems.CURVED_PATH_KIND = "battle-particle-emitter-curved-battler-path"

local MAX_SYSTEM_INDEX = 15

-- Emitter callbacks the replay reproduces: the profile that keeps the
-- resource position, the two that move the emitter onto a battler
-- position, the defender-side profile that pins the emitter over
-- the defender side's solo slot, the physical-battler profiles, the
-- pair-transform family with its convergence/magnet targets, and the
-- attacker-side solo profile. Any other callback fails closed at
-- emitter creation.
local CALLBACK_ROLES = {
  ["particle-emitter-default"] = { placement = false },
  ["particle-emitter-active-battler-relative"] = { placement = "attacker" },
  ["particle-emitter-target-battler-relative"] = { placement = "target" },
  ["particle-emitter-battler-pair-orientation"] = { placement = "defenderSide" },
}

-- The production profile name behind the relative pixel-offset callback
-- (source callback 18); the test alias names the same handler.
local RELATIVE_OFFSET_PROFILES = {
  ["particle-emitter-relative-offset"] = true,
  ["particle-emitter-randomized-position"] = true,
}

-- Configured camera presets by preset index: raw u16 angle triples from
-- the source camera table. The stored z angle never rolls the camera.
local CAMERA_PRESETS = {
  [0] = { x = 49664, y = 5952, z = 4096 },
  [1] = { x = 0, y = 0, z = 59536 },
  [2] = { x = 49664, y = 5952, z = 4096 },
  [3] = { x = 53248, y = 8192, z = 4096 },
  [4] = { x = 8192, y = 8192, z = 0 },
  [5] = { x = 9248, y = 3744, z = 0 },
}

-- One world unit per source pixel step of the emitter motion task
-- (BATTLE_ANIM_EMITTER_PIXEL over the 1/4096 fixed point).
local EMITTER_PIXEL_RAW = 172
local FX_ONE = 4096

---@class BattleParticleEmitterHandle
---@field runtime table<string, unknown>|nil live emitter runtime
---@field system BattleParticleSystemTask|nil owning system
---@field slot integer|nil emitter slot
---@field perspective integer|nil particle perspective type at creation
---@field kind integer|nil staged emitter kind behind path placement

---@class BattleParticleRegistry
---@field systems table<integer, BattleParticleSystemTask> live system tasks by system slot
---@field emitters table<integer, BattleParticleEmitterHandle> persistent emitter handles by emitter slot
---@field perspective table<integer, integer> SetParticlePerspective values by system slot
---@field flipY table<integer, integer> SetParticleFlipY values by system slot

---@return BattleParticleRegistry registry shared by one animation occurrence
function BattleParticleSystems.newRegistry()
  return { systems = {}, emitters = {}, perspective = {}, flipY = {} }
end

---@param kind string task kind under construction
---@param message string failure detail
---@return string
local function malformedMessage(kind, message)
  return "BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " " .. message
end

---@param context table<string, unknown> occurrence-bound playback context
---@param kind string task kind under construction
---@return BattleParticleRegistry
local function registryOf(context, kind)
  local registry = context.particles
  if type(registry) ~= "table" then
    error(malformedMessage(kind, "constructs without its occurrence particle registry"), 0)
  end
  return registry --[[@as BattleParticleRegistry]]
end

---@param value unknown
---@return boolean
local function isNonNegativeInteger(value)
  return type(value) == "number" and value % 1 == 0 and value >= 0
end

-- The semantic battler position an emitter callback or path names. The
-- target role needs exactly one event target, as the retail defender is one
-- battler per animation run; any other count fails loudly instead of leaving
-- the work unplayed.
---@param context table<string, unknown> occurrence-bound playback context
---@param role "attacker"|"target"
---@param kind string task kind under construction
---@return string position semantic battler position
local function battlerPosition(context, role, kind)
  local topology = context.topology --[[@as table<string, unknown>?]]
  if type(topology) ~= "table" then
    error(malformedMessage(kind, "positions emitters from an occurrence topology the packet does not carry"), 0)
  end
  local battler = nil
  if role == "attacker" then
    battler = topology.attacker
  else
    local targets = topology.targets --[[@as table<integer, table<string, unknown>>?]]
    if type(targets) ~= "table" or #targets == 0 then
      error(malformedMessage(kind, "positions emitters at an event target the packet does not carry"), 0)
    end
    if #targets ~= 1 then
      error(
        malformedMessage(kind, "positions emitters at one event target but the packet carries " .. tostring(#targets)),
        0
      )
    end
    battler = (targets --[[@as table<integer, table<string, unknown>>]])[1]
  end
  local slot = type(battler) == "table" and (battler --[[@as table<string, unknown>]]).slot or nil
  if type(slot) ~= "string" then
    error(malformedMessage(kind, "positions emitters at a battler slot the packet does not carry"), 0)
  end
  return slot --[[@as string]]
end

---@param payload table<string, unknown> staged particle system payload
---@param position string semantic battler position
---@param perspective integer particle perspective type 0 or 1
---@param kind string task kind under construction
---@param emitterKind integer staged emitter kind 0..11 behind placement
---@return table<string, number> emitter world position
local function placementOf(payload, position, perspective, kind, emitterKind)
  if type(emitterKind) ~= "number" or emitterKind % 1 ~= 0 or emitterKind < 0 or emitterKind > 11 then
    error(malformedMessage(kind, "positions emitters at a staged emitter kind 0..11"), 0)
  end
  local kinds = payload.placements[position]
  local vector = nil
  if type(kinds) == "table" and type(kinds[emitterKind + 1]) == "table" then
    vector = kinds[emitterKind + 1][perspective + 1]
  end
  if vector == nil then
    error(malformedMessage(kind, "has no staged emitter placement for " .. tostring(position)), 0)
  end
  return vector --[[@as table<string, number>]]
end

-- The retail IsEmitterActive: true unless the oldest live particle is on its
-- last tick. An emitter with no particle reports inactive.
---@param runtime table<string, unknown> live emitter runtime
---@return boolean
local function emitterActive(runtime)
  local oldest = (runtime.particles --[[@as table[] ]])[1]
  return oldest ~= nil and oldest.age ~= oldest.life
end

---@class BattleParticleSystemTask
---@field _index integer system slot
---@field _registry BattleParticleRegistry
---@field _scene table<string, unknown>
---@field _staged table<integer, unknown> leases behind exactly-once release
---@field _release fun(staged: table<integer, unknown>) lease release
---@field payload table<string, unknown> staged particle system payload
---@field simulation SplParticleSimulation live emitters and particles
---@field _sceneId integer scene registration identity
---@field _state string running or complete or cancelled
---@field _torn boolean teardown has run
local SystemTask = {}
SystemTask.__index = SystemTask

-- LoadParticleSystem: leases the staged system and its textures, builds the
-- simulation, and registers it with the scene for drawing.
---@param args table<string, unknown> instruction arguments carrying systemIndex and resource
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> scene, audio, and resource collaborators
---@param lease { stage: function, release: function } lease helpers owned by the task factory
---@return BattleParticleSystemTask
function BattleParticleSystems.newSystemTask(args, context, services, lease)
  local kind = BattleParticleSystems.SYSTEM_KIND
  local index = args.systemIndex
  if not isNonNegativeInteger(index) or index > MAX_SYSTEM_INDEX then
    error(malformedMessage(kind, "loads a system slot in 0.." .. MAX_SYSTEM_INDEX), 0)
  end
  local resource = args.resource
  if type(resource) ~= "string" or resource == "" then
    error(malformedMessage(kind, "stages a named particle resource"), 0)
  end
  local registry = registryOf(context, kind)
  if registry.systems[index] ~= nil then
    error(malformedMessage(kind, "loads system slot " .. tostring(index) .. " twice"), 0)
  end
  local scene = services.scene --[[@as table<string, unknown>]]
  if type(scene) ~= "table" or type(scene.allocParticleSystem) ~= "function" then
    error(malformedMessage(kind, "registers its system through the scene particle seam"), 0)
  end
  local staged = {}
  lease.stage(kind, resource, services, staged)
  local record = (staged[1] --[[@as table<string, unknown>]]).lease --[[@as table<string, unknown>]]
  local payload = type(record) == "table" and record.kind == "particle" and record.data or nil
  if type(payload) ~= "table" then
    lease.release(staged)
    error(malformedMessage(kind, "stages a typed particle system lease for " .. resource), 0)
  end
  if payload.unsupported ~= nil then
    -- An uncompilable member fails loudly instead of occupying its slot
    -- with a silent inert system: nothing here plays invented motion.
    lease.release(staged)
    error(
      malformedMessage(
        kind,
        "stages a compilable particle system for " .. resource .. ": " .. tostring(payload.unsupported)
      ),
      0
    )
  end
  local ok, built = pcall(function()
    local textures = {}
    for _, texture in ipairs(payload.textures) do
      lease.stage(kind, texture.image, services, staged)
      local textureLease = (staged[#staged] --[[@as table<string, unknown>]]).lease --[[@as table<string, unknown>]]
      textures[texture.id] = textureLease.handle
    end
    -- Every manager borrows the one boot stream the whole boot shares;
    -- the persisted payload carries no seed, so a missing record fails
    -- loudly instead of reseeding behind production's back.
    local randomState = nil
    if type(services) == "table" and type(services.splRandomState) == "table" then
      randomState = services.splRandomState
    end
    if randomState == nil then
      error(malformedMessage(kind, "borrows its boot stream record through services"), 0)
    end
    local simulation = SplParticleSimulation.new(randomState, 0, payload.emitters)
    local view = { simulation = simulation, textures = textures }
    return { simulation = simulation, sceneId = scene.allocParticleSystem(scene, view) }
  end)
  if not ok then
    lease.release(staged)
    error(built, 0)
  end
  local self = setmetatable({
    _kind = kind,
    _index = index,
    _registry = registry,
    _scene = scene,
    _staged = staged,
    _release = lease.release,
    payload = payload,
    simulation = built.simulation,
    _sceneId = built.sceneId,
    _state = "pending",
    _torn = false,
  }, SystemTask)
  registry.systems[index] = self
  return self
end

---@param self BattleParticleSystemTask
local function teardownSystem(self)
  if self._torn then
    return
  end
  self._torn = true
  local emitters = self.simulation.emitters
  for position = #emitters, 1, -1 do
    table.remove(emitters, position)
  end
  for slot, handle in pairs(self._registry.emitters) do
    if handle.system == self then
      self._registry.emitters[slot] = nil
    end
  end
  if self._registry.systems[self._index] == self then
    self._registry.systems[self._index] = nil
  end
  self._scene.releaseParticleSystem(self._scene, self._sceneId)
  self._release(self._staged)
end

-- Advances the system's emitters one source tick.
---@param self BattleParticleSystemTask
---@param tick table<string, unknown>? source tick under advancement
function SystemTask:stepSourceTick(tick)
  local _ = tick
  if self._torn then
    return
  end
  self._state = "running"
  SplParticleSimulation.advance(self.simulation)
end

---@param self BattleParticleSystemTask
---@return string
function SystemTask:status()
  return self._state
end

-- FreeParticleSystem: drops every emitter and releases the system.
---@param self BattleParticleSystemTask
function SystemTask:free()
  if self._state ~= "cancelled" then
    self._state = "complete"
  end
  teardownSystem(self)
end

---@param self BattleParticleSystemTask
---@param reason string cancellation cause under diagnosis
function SystemTask:cancel(reason)
  local _ = reason
  if self._state == "complete" then
    return
  end
  self._state = "cancelled"
  teardownSystem(self)
end

---@param self BattleParticleSystemTask
function SystemTask:dispose()
  teardownSystem(self)
end

---@class BattleParticleEmitterTask
---@field _system BattleParticleSystemTask
---@field _runtime table<string, unknown> live emitter runtime
---@field _state string running or complete or cancelled
---@field _axis table<string, number>? effective emitter axis behind orientation
local EmitterTask = {}
EmitterTask.__index = EmitterTask

-- Semantic battler types behind configured emitter work, in native
-- BATTLER_TYPE order: solo and doubles slots grouped by side.
local CONFIGURED_BATTLER_TYPES = {
  ["solo-player"] = 0,
  ["solo-enemy"] = 1,
  ["player-side-slot-1"] = 2,
  ["enemy-side-slot-1"] = 3,
  ["player-side-slot-2"] = 4,
  ["enemy-side-slot-2"] = 5,
}

-- Position modes the configured emitter reproduces, mapping each mode to
-- its emitter kind and battler role, a literal raw placement, a staged
-- XY table, or a side-based solo placement. Offset modes add the carried
-- script offset with all three components mirrored; mode 3 carries the
-- offset alone with only X/Y mirrored. Anything else fails loudly
-- instead of inventing a placement.
local CONFIGURED_POSITIONS = {
  [0] = {},
  [1] = { kind = 0, battler = "a" },
  [2] = { kind = 0, battler = "b" },
  [3] = { offset = true },
  [4] = { kind = 0, battler = "a", offset = true },
  [5] = { kind = 0, battler = "b", offset = true },
  [6] = { kind = 1, battler = "a" },
  [7] = { kind = 1, battler = "b" },
  [8] = { kind = 11, battler = "a" },
  [9] = { kind = 11, battler = "b" },
  [10] = { kind = 2, battler = "a" },
  [11] = { kind = 2, battler = "b" },
  [12] = { kind = 0, side = "a", offset = true },
  [13] = { kind = 0, side = "b", offset = true },
  [14] = { kind = 3, battler = "a" },
  [15] = { kind = 3, battler = "b" },
  [16] = { kind = 4, battler = "a" },
  [17] = { kind = 4, battler = "b" },
  [18] = { kind = 5, battler = "a" },
  [19] = { kind = 5, battler = "b" },
  [20] = { kind = 6, battler = "a" },
  [21] = { kind = 6, battler = "b" },
  [22] = { kind = 7, battler = "a" },
  [23] = { kind = 7, battler = "b" },
  [24] = { kind = 8, battler = "a" },
  [25] = { kind = 8, battler = "b" },
  [26] = { kind = 9, battler = "a" },
  [27] = { kind = 9, battler = "b" },
  [28] = { literal = { x = 11488, y = 0, z = 0 } },
  [30] = { table = "position30" },
  [31] = { table = "position31" },
  [32] = { table = "position32" },
  [33] = { literal = { x = -5000, y = -6000, z = 0 } },
  [34] = { kind = 0, battler = "a" },
  [100] = { kind = 0, battler = "a", typeOffsets = true },
  [101] = { kind = 0, battler = "b", typeOffsets = true },
}

-- Axis modes the configured emitter reproduces: 0 keeps the staged
-- record axis, 3/22/24/25/26 select source literals or the staged XY
-- table, 6/7 select the static rows with the native flag choices, and
-- the remaining modes read the staged per-pair tables by ordered
-- battler types exactly like the native lookup. Anything else fails
-- loudly instead of inventing an orientation.
local CONFIGURED_AXES = {
  [0] = true,
  [1] = true,
  [2] = true,
  [3] = true,
  [4] = true,
  [5] = true,
  [6] = true,
  [7] = true,
  [8] = true,
  [9] = true,
  [10] = true,
  [11] = true,
  [12] = true,
  [13] = true,
  [14] = true,
  [15] = true,
  [16] = true,
  [17] = true,
  [18] = true,
  [19] = true,
  [20] = true,
  [21] = true,
  [22] = true,
  [24] = true,
  [25] = true,
  [26] = true,
}

-- The configured side sign behind battler A: -1 for enemy battler
-- types, +1 otherwise, matching the native configured side sign.
---@param typeA integer battler-A type behind the lookup
---@return integer sign +1 or -1
local function configuredSideSign(typeA)
  return (typeA == 1 or typeA == 3 or typeA == 5) and -1 or 1
end

---@param slot string semantic battler position under side lookup
---@param kind string task kind under diagnosis
---@return integer side 3 for the player side, 4 for the foe side
local function configuredSide(slot, kind)
  if slot == "solo-enemy" or slot == "enemy-side-slot-1" or slot == "enemy-side-slot-2" then
    return 4
  end
  if slot == "solo-player" or slot == "player-side-slot-1" or slot == "player-side-slot-2" then
    return 3
  end
  error(malformedMessage(kind, "resolves the side of a known occurrence slot"), 0)
end

-- Resolves the configured battler pair behind one occurrence: the event
-- attacker always names a slot, while the defender needs exactly one
-- event target, as the native run names a single defender battler.
-- Orders 1 and 3 name the defender first; every other order (matching
-- the native default arm) names the attacker first.
---@param context table<string, unknown> occurrence-bound playback context
---@param kind string task kind under diagnosis
---@return table<string, unknown> attacker battler record behind the run
---@return table<string, unknown> defender battler record behind the run
local function configuredBattlers(context, kind)
  local topology = context.topology
  if type(topology) ~= "table" then
    error(malformedMessage(kind, "configures emitters from an occurrence topology the packet does not carry"), 0)
  end
  local attacker = topology.attacker
  if type(attacker) ~= "table" or type(attacker.slot) ~= "string" then
    error(malformedMessage(kind, "configures emitters at an attacker slot the packet does not carry"), 0)
  end
  local targets = topology.targets
  if type(targets) ~= "table" or #targets ~= 1 then
    error(
      malformedMessage(
        kind,
        "configures emitters at one event target but the packet carries "
          .. tostring(type(targets) == "table" and #targets or 0)
      ),
      0
    )
  end
  local defender = targets[1]
  if type(defender) ~= "table" or type(defender.slot) ~= "string" then
    error(malformedMessage(kind, "configures emitters at a target slot the packet does not carry"), 0)
  end
  return attacker, defender
end

-- Resolves the configured pair into battlerA/battlerB roles behind one
-- occurrence: orders 1 and 3 name the defender first while every
-- other order names the attacker first, matching the native switch
-- including its default arm.
---@param attacker table<string, unknown> event attacker behind the run
---@param defender table<string, unknown> event defender behind the run
---@param order integer script battler order under resolution
---@return table<string, unknown> battlerA behind the configured run
---@return table<string, unknown> battlerB behind the configured run
local function configuredRoles(attacker, defender, order)
  if order == 1 or order == 3 then
    return defender, attacker
  end
  return attacker, defender
end

-- C integer division truncates toward zero.
---@param numerator number
---@param denominator number
---@return integer
local function configuredDiv(numerator, denominator)
  local quotient = numerator / denominator
  return quotient >= 0 and math.floor(quotient) or math.ceil(quotient)
end

-- Applies the carried script offset to a world position: the native
-- mode-3 reader scales x and y by the battler-A side sign (unless the
-- block ignores the side) while z rides unscaled.
---@param position table<string, number> world position under adjustment
---@param offset table<string, integer> carried signed script offset block
---@param sideSign integer +1 or -1 behind the battler-A side
---@return table<string, number> adjusted world position
local function applyConfiguredOffset(position, offset, sideSign)
  local sign = sideSign
  if offset.ignoreSide == 1 then
    sign = 1
  end
  return {
    x = position.x + offset.x * sign / 4096,
    y = position.y + offset.y * sign / 4096,
    z = position.z + offset.z / 4096,
  }
end

-- Applies the carried script offset with all three components mirrored:
-- the native battler-type offset reader scales x, y, and z alike.
---@param position table<string, number> world position under adjustment
---@param offset table<string, integer> carried signed script offset block
---@param sideSign integer +1 or -1 behind the battler-A side
---@return table<string, number> adjusted world position
local function applyConfiguredOffsetFull(position, offset, sideSign)
  local sign = sideSign
  if offset.ignoreSide == 1 then
    sign = 1
  end
  return {
    x = position.x + offset.x * sign / 4096,
    y = position.y + offset.y * sign / 4096,
    z = position.z + offset.z * sign / 4096,
  }
end

-- Narrows one script component to its source signed 16-bit value.
---@param value number script component under narrowing
---@return integer narrowed component
local function narrowScriptComponent(value)
  local narrowed = math.floor(value) % 65536
  return narrowed >= 32768 and narrowed - 65536 or narrowed
end

-- Applies the occurrence-requested camera state to one manager at emitter
-- creation: the requested perspective replaces the initial perspective 0,
-- and a nonzero flip request negates the current camera up Y once, so
-- repeated flipped creations toggle it back.
---@param simulation table<string, unknown> loaded manager simulation behind the camera
---@param registry table<string, unknown> occurrence particle registry behind slot handles
---@param systemIndex integer logical system slot under creation
local function applyCreationCamera(simulation, registry, systemIndex)
  local camera = simulation.camera
  if type(camera) ~= "table" then
    return
  end
  camera.perspective = registry.perspective[systemIndex] or 0
  if (registry.flipY[systemIndex] or 0) ~= 0 then
    camera.upY = -(camera.upY or 4096)
  end
end

-- Recalculates the manager camera eye around its existing target and
-- distance from its current angles, as the source angle/position setter
-- does. The stored z angle never rolls the camera.
---@param camera table<string, unknown> mutable manager camera behind the eye
---@param FxMath table<string, unknown> shared integer/trig core
local function refreshCameraEye(camera, FxMath)
  local dist = camera.distance --[[@as integer]]
  local sinY = FxMath.sinIdx(camera.angleY)
  local cosY = FxMath.cosIdx(camera.angleY)
  local cosX = FxMath.cosIdx(camera.angleX)
  local sinNegX = FxMath.sinIdx(FxMath.u16(-camera.angleX))
  camera.x = (FxMath.fxMul(FxMath.fxMul(sinY, dist), cosX) + (camera.targetX or 0) * 4096) / 4096
  camera.z = (FxMath.fxMul(FxMath.fxMul(cosY, dist), cosX) + (camera.targetZ or 0) * 4096) / 4096
  camera.y = (FxMath.fxMul(sinNegX, dist) + (camera.targetY or 0) * 4096) / 4096
end

---@param simulation table<string, unknown> loaded manager simulation behind creation
---@param ordinal integer emitter ordinal under creation
---@param kind string task kind under diagnosis
---@return table<string, unknown> live emitter runtime, or loud pool exhaustion
local function createManagedEmitter(simulation, ordinal, kind)
  local runtime = SplParticleSimulation.addEmitter(simulation, ordinal, nil)
  if runtime == nil then
    error(malformedMessage(kind, "creates its emitter while all 20 manager nodes are occupied"), 0)
  end
  return runtime
end

-- Creates one relative-offset emitter: the immutable resource base plus
-- the source pixel offsets (172 raw fx32 per pixel) on X and Y, with
-- resource Z preserved. The placement consumes no random values. The
-- production profile carries its offsets in an emitterOffset block once
-- the compiler stages the per-pair source tables; the direct pixel
-- offsets serve the same handler.
---@param args table<string, unknown> instruction arguments carrying the pixel offsets
---@param context table<string, unknown> occurrence-bound playback context
---@param kind string task kind under diagnosis
---@param registry table<string, unknown> occurrence particle registry behind slot handles
---@param system table<string, unknown> loaded particle system behind the simulation
---@param ordinal integer zero-based emitter ordinal into the loaded manager
---@return table<string, unknown> runnable relative-offset emitter task
local function newRelativeOffsetEmitter(args, context, kind, registry, system, ordinal)
  local offsetX = args.offsetX or 0
  local offsetY = args.offsetY or 0
  local block = args.emitterOffset
  if type(block) == "table" then
    if type(block.x) == "number" then
      offsetX = block.x
    end
    if type(block.y) == "number" then
      offsetY = block.y
    end
  end
  if type(offsetX) ~= "number" or type(offsetY) ~= "number" then
    error(malformedMessage(kind, "carries numeric relative pixel offsets"), 0)
  end
  local slot = args.continuationSlot or 0
  local perspective = registry.perspective[args.systemIndex] or 0
  applyCreationCamera(system.simulation, registry, args.systemIndex)
  local runtime = createManagedEmitter(system.simulation, ordinal, kind)
  local record = runtime.record --[[@as table<string, unknown>]]
  local base = record.position or { x = 0, y = 0, z = 0 }
  runtime.x = (base.x or 0) + offsetX * EMITTER_PIXEL_RAW / FX_ONE
  runtime.y = (base.y or 0) + offsetY * EMITTER_PIXEL_RAW / FX_ONE
  runtime.z = base.z or 0
  if record.persistent then
    registry.emitters[slot] = { runtime = runtime, system = system, slot = slot, perspective = perspective }
  end
  local _ = context
  return setmetatable({ _system = system, _runtime = runtime, _state = "running" }, EmitterTask)
end

-- Resolves one configured axis row behind the ordered battler types:
-- row-major attacker-major indexing over the staged 36 vectors,
-- mirroring the native table lookup including its z divisor.
---@param tableVectors table<integer, table<string, number>> staged axis vectors in row-major order
---@param typeA integer attacker battler type behind the lookup
---@param typeB integer defender battler type behind the lookup
---@param divZ integer native z divisor behind the lookup
---@param signX integer +1 or -1 behind the lookup
---@param kind string task kind under diagnosis
---@return table<string, number> configured axis vector
local function configuredAxisRow(tableVectors, typeA, typeB, divZ, signX, kind)
  local entry = tableVectors[typeA * 6 + typeB + 1]
  if type(entry) ~= "table" then
    error(malformedMessage(kind, "reads a staged configured axis row"), 0)
  end
  return { x = signX * entry.x, y = entry.y, z = configuredDiv(entry.z * 4096, divZ) / 4096 }
end

---@param tables table<string, unknown> staged configured tables behind the lookup
---@param modeKey string axis table key behind the lookup
---@param kind string task kind under diagnosis
---@return table<integer, table<string, number>> axis vectors in row-major order
local function configuredModeTable(tables, modeKey, kind)
  if type(tables) ~= "table" then
    error(malformedMessage(kind, "reads staged configured axis tables"), 0)
  end
  local tableVectors = tables[modeKey]
  if type(tableVectors) ~= "table" then
    error(malformedMessage(kind, "reads a staged configured axis table for " .. modeKey), 0)
  end
  return tableVectors --[[@as table<integer, table<string, number>>]]
end

-- Applies one static row to the battle axis: a set mirror flag keeps the
-- row, any other flag negates it, matching the native row/flag choices
-- including the documented partner-sign irregularities.
---@param row table<string, number> staged static row with its mirror flag
---@param negate boolean true when the native choice negates the row
---@return table<string, number> battle axis vector
local function staticAxisRow(row, negate)
  local sign = negate and -1 or 1
  return { x = sign * row.x, y = sign * row.y, z = sign * row.z }
end

---@param row table<string, number> staged static row with its mirror flag
---@return boolean true when the native choice keeps the row
local function rowKeeps(row)
  return row.mirrorFlag == 1
end

-- Resolves one static-row axis behind the ordered battler types exactly
-- like the native mode-6/7 selection, preserving the native partner
-- flag choices.
---@param rows table<integer, table<string, number>> seven staged static rows a..g
---@param typeA integer attacker battler type behind the lookup
---@param typeB integer defender battler type behind the lookup
---@return table<string, number> battle axis vector
local function staticConfiguredAxis(rows, typeA, typeB)
  local a, b, c, d, e, f, g = rows[1], rows[2], rows[3], rows[4], rows[5], rows[6], rows[7]
  if typeA == 0 then
    return staticAxisRow(a, false)
  end
  if typeA == 1 then
    return staticAxisRow(a, not rowKeeps(a))
  end
  if typeA == 2 then
    if typeB == 3 then
      return staticAxisRow(b, false)
    end
    if typeB == 5 then
      return staticAxisRow(d, false)
    end
    return staticAxisRow(c, false)
  end
  if typeA == 3 then
    if typeB == 2 then
      return staticAxisRow(b, not rowKeeps(b))
    end
    if typeB == 5 then
      return staticAxisRow(e, rowKeeps(c))
    end
    return staticAxisRow(f, not rowKeeps(f))
  end
  if typeA == 4 then
    if typeB == 3 then
      return staticAxisRow(f, false)
    end
    if typeB == 5 then
      return staticAxisRow(g, false)
    end
    return staticAxisRow(e, false)
  end
  if typeB == 3 then
    return staticAxisRow(e, not rowKeeps(b))
  end
  if typeB == 2 then
    return staticAxisRow(d, not rowKeeps(b))
  end
  return staticAxisRow(g, not rowKeeps(b))
end

---@param axisMode integer script axis mode under resolution
---@param typeA integer attacker battler type behind the lookup
---@param typeB integer defender battler type behind the lookup
---@param sideA integer attacker native side behind same-side checks
---@param sideB integer defender native side behind same-side checks
---@param axisTables table<string, unknown> staged configured axis tables behind the lookup
---@param emitterTables table<string, unknown> staged configured emitter tables behind the lookup
---@param kind string task kind under diagnosis
---@return table<string, number>? configured axis vector, nil to keep the record axis
local function configuredAxis(axisMode, typeA, typeB, sideA, sideB, axisTables, emitterTables, kind)
  if axisMode == 0 then
    return nil
  end
  if CONFIGURED_AXES[axisMode] ~= true then
    error(malformedMessage(kind, "reproduces configured axis mode " .. tostring(axisMode)), 0)
  end
  if axisMode == 1 or axisMode == 2 then
    return configuredAxisRow(configuredModeTable(axisTables, "mode1", kind), typeA, typeB, 2, 1, kind)
  end
  if axisMode == 3 then
    return { x = -800 / 4096, y = 1200 / 4096, z = 500 / 4096 }
  end
  if axisMode == 4 or axisMode == 5 then
    if sideA == sideB then
      return configuredAxisRow(configuredModeTable(axisTables, "mode1", kind), typeA, typeB, 2, 1, kind)
    end
    if sideA == 3 then
      return { x = 3776 / 4096, y = 2112 / 4096, z = 1532 / 4096 }
    end
    return { x = -4228 / 4096, y = -2728 / 4096, z = 1532 / 4096 }
  end
  if axisMode == 6 or axisMode == 7 then
    if type(emitterTables) ~= "table" then
      error(malformedMessage(kind, "reads staged configured emitter tables"), 0)
    end
    local rows = emitterTables.axisRows
    if type(rows) ~= "table" then
      error(malformedMessage(kind, "reads staged configured static axis rows"), 0)
    end
    return staticConfiguredAxis(rows --[[@as table<integer, table<string, number>>]], typeA, typeB)
  end
  if axisMode == 8 or axisMode == 9 then
    return configuredAxisRow(configuredModeTable(axisTables, "mode8", kind), typeA, typeB, 2, 1, kind)
  end
  if axisMode == 10 or axisMode == 11 then
    local rowsX = configuredModeTable(axisTables, "mode10", kind)
    local rowsYZ = configuredModeTable(axisTables, "mode8", kind)
    local entryX = rowsX[typeA * 6 + typeB + 1]
    local entryYZ = rowsYZ[typeA * 6 + typeB + 1]
    if type(entryX) ~= "table" or type(entryYZ) ~= "table" then
      error(malformedMessage(kind, "reads a staged configured axis row"), 0)
    end
    return { x = entryX.x, y = entryYZ.y, z = configuredDiv(entryYZ.z * 4096, 2) / 4096 }
  end
  if axisMode == 12 or axisMode == 13 then
    return configuredAxisRow(configuredModeTable(axisTables, "mode12", kind), typeA, typeB, 1, 1, kind)
  end
  if axisMode == 14 or axisMode == 15 then
    return configuredAxisRow(configuredModeTable(axisTables, "mode14", kind), typeA, typeB, 1, 1, kind)
  end
  if axisMode == 16 or axisMode == 17 then
    return configuredAxisRow(configuredModeTable(axisTables, "mode16", kind), typeA, typeB, 1, 1, kind)
  end
  if axisMode == 18 or axisMode == 19 then
    return configuredAxisRow(configuredModeTable(axisTables, "mode18", kind), typeA, typeB, 1, 1, kind)
  end
  if axisMode == 20 or axisMode == 21 then
    return configuredAxisRow(configuredModeTable(axisTables, "mode20", kind), typeA, typeB, 1, 1, kind)
  end
  if axisMode == 22 then
    return { x = -3410 / 4096, y = -2644 / 4096, z = 0 }
  end
  if axisMode == 24 then
    if type(emitterTables) ~= "table" then
      error(malformedMessage(kind, "reads staged configured emitter tables"), 0)
    end
    local positions = emitterTables.axisPositions
    if type(positions) ~= "table" or type(positions[typeA + 1]) ~= "table" then
      error(malformedMessage(kind, "reads a staged configured axis position"), 0)
    end
    local pair = positions[typeA + 1] --[[@as table<string, number>]]
    return { x = pair.x, y = pair.y, z = 0 }
  end
  if axisMode == 25 then
    return { x = -3440 / 4096, y = 1952 / 4096, z = 0 }
  end
  -- Axis mode 26 selects by the attacker side.
  if sideA == 3 then
    return { x = 3776 / 4096, y = 2112 / 4096, z = 0 }
  end
  return { x = -6000 / 4096, y = -2200 / 4096, z = 0 }
end

-- Applies one configured camera mode to the manager camera: mode 0 resets
-- the angles preserving target/distance/up, modes 1/3/4/5/6 install their
-- source preset and force orthographic projection, mode 2 carries its own
-- angle triple, and modes 7/8 retarget to the kind-10 placement keeping
-- eye, stored distance, and angles. The stored z angle never rolls.
---@param config table<string, integer> six script configuration words
---@param args table<string, unknown> instruction arguments carrying trailers
---@param battlerA table<string, unknown> configured battler A behind the run
---@param battlerB table<string, unknown> configured battler B behind the run
---@param system table<string, unknown> loaded particle system behind the simulation
---@param kind string task kind under diagnosis
local function applyConfiguredCamera(config, args, battlerA, battlerB, system, kind)
  local camera = system.simulation.camera
  if type(camera) ~= "table" then
    return
  end
  local FxMath = require("libs.hgss.src.presentation.PresentationFxMath")
  local _ = args
  local function setAngles(preset)
    camera.angleX, camera.angleY, camera.angleZ = preset.x, preset.y, preset.z
    refreshCameraEye(camera, FxMath)
  end
  local mode = config.cameraMode
  if mode == 0 then
    camera.angleX, camera.angleY, camera.angleZ = 0, 0, 0
  elseif mode == 1 then
    setAngles(CAMERA_PRESETS[4])
    camera.perspective = 1
  elseif mode == 2 then
    local angles = args.cameraAngles
    if
      type(angles) ~= "table"
      or type(angles.x) ~= "number"
      or type(angles.y) ~= "number"
      or type(angles.z) ~= "number"
    then
      error(malformedMessage(kind, "carries its configured camera angle triple for camera mode 2"), 0)
    end
    camera.angleX = FxMath.u16(angles.x)
    camera.angleY = FxMath.u16(angles.y)
    camera.angleZ = FxMath.u16(angles.z)
  elseif mode == 3 then
    setAngles(CAMERA_PRESETS[3])
    camera.perspective = 1
  elseif mode == 4 then
    setAngles(CAMERA_PRESETS[5])
    camera.perspective = 1
  elseif mode == 5 then
    setAngles(CAMERA_PRESETS[0])
    camera.perspective = 1
  elseif mode == 6 then
    setAngles(CAMERA_PRESETS[1])
    camera.perspective = 1
  elseif mode == 7 or mode == 8 then
    local whose = mode == 7 and battlerA or battlerB
    local vector = placementOf(system.payload, whose.slot, 0, kind, 10)
    camera.targetX, camera.targetY, camera.targetZ = vector.x, vector.y, vector.z
  else
    error(malformedMessage(kind, "reproduces configured camera modes"), 0)
  end
end

-- Wraps one script value to its source unsigned 16-bit value.
---@param value number script value under narrowing
---@return integer narrowed value
local function wrapU16(value)
  return math.floor(value) % 65536
end

-- Finds the manager's shared field block of one kind, creating it with
-- source-zero defaults when the resource carries none, so a configured
-- callback mutates the same block every emitter of this ordinal shares.
-- All-zero entries are simulation-neutral by the source update rules.
---@param system table<string, unknown> loaded particle system behind the simulation
---@param ordinal integer zero-based emitter ordinal into the loaded manager
---@param fieldKind string field kind behind the lookup
---@param kind string task kind under diagnosis
---@return table<string, unknown> shared mutable field block
local function sharedFieldBlock(system, ordinal, fieldKind, kind)
  local shared = system.simulation.resources[ordinal + 1]
  if type(shared) ~= "table" then
    error(malformedMessage(kind, "mutates a loaded manager resource"), 0)
  end
  local fields = shared.fields
  if type(fields) ~= "table" then
    error(malformedMessage(kind, "mutates a loaded manager resource"), 0)
  end
  for _, field in ipairs(fields) do
    if field.kind == fieldKind then
      return field --[[@as table<string, unknown>]]
    end
  end
  local defaults = {
    gravity = { kind = "gravity", magnitude = { x = 0, y = 0, z = 0 } },
    magnet = { kind = "magnet", position = { x = 0, y = 0, z = 0 }, magnitude = 0 },
    spin = { kind = "spin", rotation = 0, axis = 0 },
    convergence = { kind = "convergence", position = { x = 0, y = 0, z = 0 }, ratio = 0 },
  }
  local created = defaults[fieldKind]
  fields[#fields + 1] = created
  return created --[[@as table<string, unknown>]]
end

-- Applies every configured field block in ascending mask order to the
-- manager's shared resource clone, matching the native flag-callback
-- order and mutation. Position reads reject the uninitialized
-- configured variable exactly like the native stack local.
---@param system table<string, unknown> loaded particle system behind the simulation
---@param ordinal integer zero-based emitter ordinal into the loaded manager
---@param scripts table<integer, table<string, integer>> staged field blocks in mask order
---@param sign integer +1 or -1 behind the battler-A side
---@param position table<string, number>? configured argument-space position
---@param battlerA table<string, unknown> configured battler A behind the run
---@param battlerB table<string, unknown> configured battler B behind the run
---@param perspective integer particle perspective type at creation
---@param kind string task kind under diagnosis
local function applyConfiguredFlags(system, ordinal, scripts, sign, position, battlerA, battlerB, perspective, kind)
  local function kindZero(slot)
    local vector = placementOf(system.payload, slot, perspective, kind, 0)
    return { x = vector.x, y = vector.y, z = vector.z }
  end
  local function raw(world)
    return math.floor(world * 4096 + 0.5)
  end
  for _, script in ipairs(scripts) do
    if type(script) ~= "table" or type(script.mask) ~= "number" then
      error(malformedMessage(kind, "carries its field script blocks for flag masks"), 0)
    end
    if type(script.mode) ~= "number" or script.mode % 1 ~= 0 then
      error(malformedMessage(kind, "carries an integral field script mode"), 0)
    end
    for _, name in ipairs({ "x", "y", "z" }) do
      if type(script[name]) ~= "number" or script[name] % 1 ~= 0 then
        error(malformedMessage(kind, "carries an integral field script " .. name), 0)
      end
    end
    if script.ignoreSide ~= 0 and script.ignoreSide ~= 1 then
      error(malformedMessage(kind, "carries a field script ignore-side marker"), 0)
    end
    local useSign = script.ignoreSide == 1 and 1 or sign
    local mask = script.mask
    if mask == 2 then
      local gravity = sharedFieldBlock(system, ordinal, "gravity", kind)
      if script.mode == 1 then
        gravity.magnitude = {
          x = narrowScriptComponent(script.x * useSign) / 4096,
          y = narrowScriptComponent(script.y * useSign) / 4096,
          z = narrowScriptComponent(script.z * useSign) / 4096,
        }
      else
        if position == nil then
          error(
            malformedMessage(
              kind,
              "reads an uninitialized configured position for gravity mode " .. tostring(script.mode)
            ),
            0
          )
        end
        gravity.magnitude = {
          x = narrowScriptComponent(0 - raw(position.x)) / 4096,
          y = narrowScriptComponent(0 - raw(position.y)) / 4096,
          z = narrowScriptComponent(0 - raw(position.z)) / 4096,
        }
      end
    elseif mask == 16 then
      local entry = sharedFieldBlock(system, ordinal, "magnet", kind)
      local value = nil
      if script.mode == 0 then
        value = {
          x = entry.position.x * useSign,
          y = entry.position.y * useSign,
          z = entry.position.z * useSign,
        }
      elseif script.mode == 1 then
        value = { x = script.x * useSign / 4096, y = script.y * useSign / 4096, z = script.z * useSign / 4096 }
      elseif script.mode == 2 then
        value = kindZero(battlerA.slot)
      elseif script.mode == 3 then
        value = kindZero(battlerB.slot)
      else
        value = { x = 0, y = 0, z = 0 }
      end
      if position == nil then
        error(
          malformedMessage(kind, "reads an uninitialized configured position for magnet mode " .. tostring(script.mode)),
          0
        )
      end
      entry.position = { x = value.x - position.x, y = value.y - position.y, z = value.z }
    elseif mask == 32 then
      local entry = sharedFieldBlock(system, ordinal, "magnet", kind)
      if script.mode == 0 then
        entry.magnitude = narrowScriptComponent(entry.magnitude * 4096 * useSign) / 4096
      elseif script.mode == 1 then
        entry.magnitude = narrowScriptComponent(script.x * useSign) / 4096
      else
        entry.magnitude = 0
      end
    elseif mask == 64 then
      local entry = sharedFieldBlock(system, ordinal, "spin", kind)
      if script.mode == 0 then
        entry.rotation = wrapU16(entry.rotation * useSign)
      elseif script.mode == 1 then
        entry.rotation = wrapU16(script.x * useSign)
      else
        entry.rotation = 0
      end
    elseif mask == 128 then
      local entry = sharedFieldBlock(system, ordinal, "spin", kind)
      if script.mode == 0 then
        entry.axis = wrapU16(entry.axis)
      elseif script.mode == 1 then
        entry.axis = wrapU16(script.x)
      else
        entry.axis = 0
      end
    elseif mask == 4096 then
      local entry = sharedFieldBlock(system, ordinal, "convergence", kind)
      local value = nil
      if script.mode == 0 then
        value = {
          x = entry.position.x * useSign,
          y = entry.position.y * useSign,
          z = entry.position.z * useSign,
        }
      elseif script.mode == 1 then
        value = { x = script.x * useSign / 4096, y = script.y * useSign / 4096, z = script.z * useSign / 4096 }
      elseif script.mode == 2 then
        value = kindZero(battlerA.slot)
      elseif script.mode == 3 then
        value = kindZero(battlerB.slot)
      elseif script.mode == 4 then
        local base = kindZero(battlerB.slot)
        if script.y == 0 then
          error(malformedMessage(kind, "scales a convergence target by a zero divisor"), 0)
        end
        value = {
          x = configuredDiv(raw(base.x) * script.x, script.y) / 4096,
          y = configuredDiv(raw(base.y) * script.x, script.y) / 4096,
          z = configuredDiv(raw(base.z) * script.x, script.y) / 4096,
        }
      else
        value = { x = 0, y = 0, z = 0 }
      end
      if position == nil then
        error(
          malformedMessage(
            kind,
            "reads an uninitialized configured position for convergence mode " .. tostring(script.mode)
          ),
          0
        )
      end
      entry.position = { x = value.x - position.x, y = value.y - position.y, z = value.z - position.z }
    elseif mask == 8192 then
      local entry = sharedFieldBlock(system, ordinal, "convergence", kind)
      if script.mode == 0 then
        entry.ratio = narrowScriptComponent(entry.ratio * useSign)
      elseif script.mode == 1 then
        entry.ratio = narrowScriptComponent(script.x * useSign)
      else
        entry.ratio = 0
      end
    else
      error(malformedMessage(kind, "reproduces configured emitter flags"), 0)
    end
  end
end

-- Creates one emitter positioned by its configure-from-script block:
-- the battler order selects attacker/defender roles, the position mode
-- selects a staged kind column, literal, XY table, or side placement
-- (plus the carried script offsets where the mode reads them), and the
-- axis mode selects the staged record axis, literal, static row, or
-- per-pair table vector. Flag masks mutate the shared per-manager
-- field in ascending mask order. The camera mode always executes,
-- and the z mode overrides depth through the argument-space setter.
-- Undefined modes fail loudly instead of inventing motion.
---@param args table<string, unknown> instruction arguments carrying the configured emitter
---@param context table<string, unknown> occurrence-bound playback context
---@param kind string task kind under diagnosis
---@param registry table<string, unknown> occurrence particle registry behind slot handles
---@param system table<string, unknown> loaded particle system behind the simulation
---@param ordinal integer zero-based emitter ordinal into the loaded manager
---@return table<string, unknown> runnable configured emitter task
local function newConfiguredEmitter(args, context, kind, registry, system, ordinal)
  local config = args.emitterConfig
  if type(config) ~= "table" then
    error(malformedMessage(kind, "configures its emitter from six script words"), 0)
  end
  for _, name in ipairs({ "zMode", "battlerOrder", "positionMode", "axisMode", "flags", "cameraMode" }) do
    local value = config[name]
    if type(value) ~= "number" or value % 1 ~= 0 then
      error(malformedMessage(kind, "configures its emitter with an integral " .. name), 0)
    end
  end
  -- Camera presets replace the manager camera angle without inventing
  -- roll; only the documented 0..8 range is accepted.
  if config.cameraMode < 0 or config.cameraMode > 8 then
    error(malformedMessage(kind, "reproduces configured camera modes"), 0)
  end
  -- Z mode 3 leaves a native stack local undefined and rejects; modes
  -- 0..2 execute through the argument-space setter below.
  if config.zMode < 0 or config.zMode > 2 then
    error(malformedMessage(kind, "reproduces configured z modes"), 0)
  end
  if config.positionMode == 29 then
    error(malformedMessage(kind, "reproduces configured position mode 29"), 0)
  end
  if config.axisMode == 23 then
    error(malformedMessage(kind, "reproduces configured axis mode 23"), 0)
  end
  -- Authentic no-op masks consume no trailer; every meaningful mask
  -- mutates the shared per-manager field in ascending mask order. Any
  -- other set bit fails loudly instead of inventing a force.
  local allowedMasks = {
    [0] = true,
    [2] = true,
    [4] = true,
    [8] = true,
    [16] = true,
    [32] = true,
    [64] = true,
    [128] = true,
    [256] = true,
    [512] = true,
    [1024] = true,
    [2048] = true,
    [4096] = true,
    [8192] = true,
  }
  local remaining = config.flags
  local scanned = 0
  while remaining > 0 do
    if remaining % 2 == 1 and not allowedMasks[2 ^ scanned] then
      error(malformedMessage(kind, "reproduces configured emitter flags"), 0)
    end
    remaining = math.floor(remaining / 2)
    scanned = scanned + 1
  end
  local masked = 0
  for bit = 1, 15 do
    if math.floor(config.flags / (2 ^ bit)) % 2 == 1 then
      masked = masked + 2 ^ bit
    end
  end
  if masked == 0xFEFE then
    error(malformedMessage(kind, "reproduces configured emitter flags"), 0)
  end
  local attacker, defender = configuredBattlers(context, kind)
  local battlerA, battlerB = configuredRoles(attacker, defender, config.battlerOrder)
  local slotA = battlerA.slot
  local slotB = battlerB.slot
  local typeA = CONFIGURED_BATTLER_TYPES[slotA]
  local typeB = CONFIGURED_BATTLER_TYPES[slotB]
  if typeA == nil or typeB == nil then
    error(malformedMessage(kind, "resolves configured battlers at known occurrence slots"), 0)
  end
  local slot = args.continuationSlot or 0
  local perspective = registry.perspective[args.systemIndex] or 0
  local mode = CONFIGURED_POSITIONS[config.positionMode]
  if mode == nil then
    error(malformedMessage(kind, "reproduces configured position mode " .. tostring(config.positionMode)), 0)
  end
  local offset = args.emitterOffset
  if mode.offset == true then
    if type(offset) ~= "table" then
      error(malformedMessage(kind, "carries its script offset block for offset position modes"), 0)
    end
    for _, name in ipairs({ "x", "y", "z" }) do
      if type(offset[name]) ~= "number" or offset[name] % 1 ~= 0 then
        error(malformedMessage(kind, "carries an integral offset " .. name), 0)
      end
    end
    if offset.ignoreSide ~= 0 and offset.ignoreSide ~= 1 then
      error(malformedMessage(kind, "carries a flag offset ignore-side marker"), 0)
    end
  elseif offset ~= nil then
    error(malformedMessage(kind, "carries no offset block for direct position modes"), 0)
  end
  local typeOffsets = args.typeOffsets
  if mode.typeOffsets == true then
    if type(typeOffsets) ~= "table" or #typeOffsets ~= 6 then
      error(malformedMessage(kind, "carries six battler-type offset blocks for battler-type position modes"), 0)
    end
  elseif typeOffsets ~= nil then
    error(malformedMessage(kind, "carries no type offsets for direct position modes"), 0)
  end
  local position = nil
  if mode.kind ~= nil and mode.side == nil then
    local whose = nil
    if mode.battler == "a" then
      whose = battlerA
    elseif mode.battler == "b" then
      whose = battlerB
    else
      error(malformedMessage(kind, "addresses a configured kind battler"), 0)
    end
    local vector = placementOf(system.payload, whose.slot, perspective, kind, mode.kind)
    position = { x = vector.x, y = vector.y, z = vector.z }
  elseif mode.side ~= nil then
    local whose = mode.side == "a" and battlerA or battlerB
    local sideSlot = configuredSide(whose.slot, kind) == 3 and "solo-player" or "solo-enemy"
    local vector = placementOf(system.payload, sideSlot, perspective, kind, mode.kind)
    position = { x = vector.x, y = vector.y, z = vector.z }
  elseif mode.literal ~= nil then
    position = { x = mode.literal.x / 4096, y = mode.literal.y / 4096, z = mode.literal.z / 4096 }
  elseif mode.table ~= nil then
    local tables = system.payload.emitterTables
    if type(tables) ~= "table" then
      error(malformedMessage(kind, "reads staged configured emitter tables"), 0)
    end
    local pairs = tables[mode.table]
    if type(pairs) ~= "table" or type(pairs[typeA + 1]) ~= "table" then
      error(malformedMessage(kind, "reads a staged configured position pair"), 0)
    end
    local pair = pairs[typeA + 1] --[[@as table<string, number>]]
    position = { x = pair.x, y = pair.y, z = 0 }
  elseif mode.offset == true then
    position = { x = 0, y = 0, z = 0 }
  end
  if mode.offset == true or mode.typeOffsets == true then
    -- Every offset mode resolves its base position through a kind, side,
    -- literal, table, or plain offset above, so the base is always set here.
    position = assert(position, malformedMessage(kind, "resolves a configured base position for offset modes"))
    local sign = configuredSideSign(typeA)
    if mode.offset == true and config.positionMode == 3 then
      position = applyConfiguredOffset(position, offset, sign)
    elseif mode.offset == true then
      position = applyConfiguredOffsetFull(position, offset, sign)
    else
      local whoseType = mode.battler == "a" and typeA or typeB
      local block = typeOffsets[whoseType + 1]
      if type(block) ~= "table" then
        error(malformedMessage(kind, "reads a staged battler-type offset block"), 0)
      end
      position = applyConfiguredOffsetFull(position, block, sign)
    end
  end
  local axis = configuredAxis(
    config.axisMode,
    typeA,
    typeB,
    configuredSide(slotA, kind),
    configuredSide(slotB, kind),
    system.payload.axisTables,
    system.payload.emitterTables,
    kind
  )
  -- Every meaningful flag mask writes the manager's shared resource
  -- clone in ascending mask order, so every existing and future emitter
  -- of this ordinal feels it; the cached payload and other managers
  -- stay independent. Position reads reject the uninitialized
  -- configured variable exactly like the native stack local.
  if args.fieldScripts ~= nil then
    if type(args.fieldScripts) ~= "table" then
      error(malformedMessage(kind, "carries its field script blocks for flag masks"), 0)
    end
    applyConfiguredFlags(
      system,
      ordinal,
      args.fieldScripts,
      configuredSideSign(typeA),
      position,
      battlerA,
      battlerB,
      perspective,
      kind
    )
  end
  applyCreationCamera(system.simulation, registry, args.systemIndex)
  local runtime = createManagedEmitter(system.simulation, ordinal, kind)
  local record = runtime.record --[[@as table<string, unknown>]]
  if axis ~= nil then
    -- The axis stays per-emitter: sibling emitters of this ordinal keep
    -- their own orientation while sharing the field blocks.
    runtime.axis = axis
    record.axis = axis
  end
  if position ~= nil then
    runtime.x, runtime.y, runtime.z = position.x, position.y, position.z
  end
  -- Z modes 1 and 2 pass their selector through the argument-space
  -- setter, which adds the immutable resource base Z once.
  if config.zMode == 1 or config.zMode == 2 then
    local base = record.position --[[@as table<string, number>]]
    local baseRawZ = math.floor((base.z or 0) * 4096 + 0.5)
    local value = 0
    if config.zMode == 1 then
      value = typeB == 0 and 256 or -5120
    else
      value = typeB == 0 and 0 or -5376
    end
    local raw = baseRawZ + value
    runtime.z = (raw >= 2147483648 and raw - 4294967296 or (raw < -2147483648 and raw + 4294967296 or raw)) / 4096
  end
  -- The camera mode always executes, after position, axis, and fields.
  applyConfiguredCamera(config, args, battlerA, battlerB, system, kind)
  if record.persistent then
    registry.emitters[slot] = { runtime = runtime, system = system, slot = slot, perspective = perspective }
  end
  return setmetatable(
    { _system = system, _runtime = runtime, _state = "running", _axis = axis or record.axis },
    EmitterTask
  )
end

-- Inverse slot/type map behind physical battler resolution: native
-- battler indices stay fixed while the occurrence only names slots.
local SLOT_BY_BATTLER_TYPE = {
  [0] = "solo-player",
  [1] = "solo-enemy",
  [2] = "player-side-slot-1",
  [3] = "enemy-side-slot-1",
  [4] = "player-side-slot-2",
  [5] = "enemy-side-slot-2",
}

-- Opposing battler type per type, matching the native opposing-type map.
local OPPOSING_BATTLER_TYPE = { [0] = 1, [1] = 0, [2] = 3, [3] = 2, [4] = 5, [5] = 4 }

-- Resolves the battler type behind a physical battler index: the exact
-- production identity reads the ordered source battlers, while the
-- battle family named by the attacker slot covers index-only contexts.
---@param context table<string, unknown> occurrence-bound playback context
---@param index integer physical battler index behind the lookup
---@return integer battler type 0..5
local function physicalBattlerType(context, index)
  local wanted = index == 0 and { 0, 2 } or { 1, 3 }
  local battlers = context.sourceBattlers
  if type(battlers) == "table" then
    for _, entry in ipairs(battlers) do
      if type(entry) == "table" then
        for _, sideType in ipairs(wanted) do
          if entry.sideType == sideType then
            return sideType
          end
        end
      end
    end
  end
  local topology = context.topology
  local attacker = type(topology) == "table" and topology.attacker or nil
  local slot = type(attacker) == "table" and attacker.slot or nil
  local solo = slot == "solo-player" or slot == "solo-enemy"
  if index == 0 then
    return solo and 0 or 2
  end
  return solo and 1 or 3
end

-- The pair-transform family behind source callbacks 5..16: the shared
-- script transform reads seven axis triples plus one position triple,
-- with a four-word script target for the from-script convergence and
-- magnet kinds. Battler roles A/B follow the native per-callback
-- attacker/defender assignment.
local PAIR_TRANSFORMS = {
  ["particle-emitter-position-pair-primary-primary"] = { a = "attacker", b = "defender", mode = "none" },
  ["particle-emitter-position-pair-primary-secondary"] = { a = "defender", b = "attacker", mode = "none" },
  ["particle-emitter-position-pair-primary-partner"] = { a = "attacker", b = "defender", mode = "converge", target = 1 },
  ["particle-emitter-position-pair-primary-opponent"] = {
    a = "attacker",
    b = "defender",
    mode = "converge",
    target = 2,
  },
  ["particle-emitter-position-pair-primary-opposing-partner"] = {
    a = "attacker",
    b = "defender",
    mode = "converge",
    target = 3,
  },
  ["particle-emitter-position-pair-primary-active"] = { a = "attacker", b = "defender", mode = "converge", target = 4 },
  ["particle-emitter-position-pair-secondary-primary"] = {
    a = "attacker",
    b = "defender",
    mode = "converge",
    target = 5,
  },
  ["particle-emitter-position-pair-secondary-secondary"] = {
    a = "attacker",
    b = "defender",
    mode = "magnet",
    target = 1,
  },
  ["particle-emitter-position-pair-secondary-partner"] = { a = "attacker", b = "defender", mode = "magnet", target = 2 },
  ["particle-emitter-position-pair-secondary-opponent"] = {
    a = "attacker",
    b = "defender",
    mode = "magnet",
    target = 3,
  },
  ["particle-emitter-position-pair-secondary-opposing-partner"] = {
    a = "attacker",
    b = "defender",
    mode = "magnet",
    target = 4,
  },
  ["particle-emitter-position-pair-secondary-active"] = { a = "attacker", b = "defender", mode = "magnet", target = 5 },
}

-- Selects one shared script axis by ordered battler types, matching the
-- native per-type table/negation choices over the seven staged triples.
---@param vectors table<integer, table<string, integer>> seven staged script axis triples
---@param typeA integer attacker battler type behind the lookup
---@param typeB integer defender battler type behind the lookup
---@param kind string task kind under diagnosis
---@return table<string, number> battle axis vector narrowed to s16
local function pairTransformAxis(vectors, typeA, typeB, kind)
  local function triple(index)
    local entry = vectors[index]
    if type(entry) ~= "table" then
      error(malformedMessage(kind, "carries seven script axis triples for pair-transform profiles"), 0)
    end
    return entry --[[@as table<string, integer>]]
  end
  local selected = nil
  local negate = false
  if typeA == 0 then
    selected = triple(1)
  elseif typeA == 1 then
    selected, negate = triple(1), true
  elseif typeA == 2 then
    if typeB == 3 then
      selected = triple(2)
    elseif typeB == 5 then
      selected = triple(3)
    else
      selected = triple(4)
    end
  elseif typeA == 3 then
    negate = true
    if typeB == 2 then
      selected = triple(2)
    elseif typeB == 5 then
      selected = triple(4)
    else
      selected = triple(5)
    end
  elseif typeA == 4 then
    if typeB == 3 then
      selected = triple(5)
    elseif typeB == 5 then
      selected = triple(6)
    else
      selected = triple(7)
    end
  else
    negate = true
    if typeB == 3 then
      selected = triple(7)
    elseif typeB == 2 then
      selected = triple(3)
    else
      selected = triple(6)
    end
  end
  local sign = negate and -1 or 1
  return {
    x = narrowScriptComponent(sign * selected.x) / 4096,
    y = narrowScriptComponent(sign * selected.y) / 4096,
    z = narrowScriptComponent(sign * selected.z) / 4096,
  }
end

-- Scales one script target triple by the side sign per its scale kind,
-- matching the native per-component target scaling.
---@param target table<string, integer> staged script target with its scale kind
---@param sign integer +1 or -1 behind the battler-A side
---@param kind string task kind under diagnosis
---@return table<string, number> scaled argument-space target
local function scalePairTarget(target, sign, kind)
  if
    type(target.x) ~= "number"
    or type(target.y) ~= "number"
    or type(target.z) ~= "number"
    or type(target.scaleKind) ~= "number"
  then
    error(malformedMessage(kind, "carries a script target for from-script pair profiles"), 0)
  end
  local scaleKind = target.scaleKind
  local x, y, z = target.x / 4096, target.y / 4096, target.z / 4096
  if scaleKind == 1 or scaleKind == 4 or scaleKind == 5 or scaleKind == 7 then
    x = x * sign
  end
  if scaleKind == 2 or scaleKind == 4 or scaleKind == 6 or scaleKind == 7 then
    y = y * sign
  end
  if scaleKind == 3 or scaleKind == 5 or scaleKind == 6 or scaleKind == 7 then
    z = z * sign
  end
  return { x = x, y = y, z = z }
end

-- Creates one emitter positioned by the shared pair-transform script:
-- seven axis triples and one position triple select the axis, the
-- kind-0 column, and the convergence/magnet target by ordered battler
-- types exactly like the native transform.
---@param args table<string, unknown> instruction arguments carrying the script vectors
---@param context table<string, unknown> occurrence-bound playback context
---@param kind string task kind under diagnosis
---@param registry table<string, unknown> occurrence particle registry behind slot handles
---@param system table<string, unknown> loaded particle system behind the simulation
---@param ordinal integer zero-based emitter ordinal into the loaded manager
---@param transform table<string, unknown> battler roles and target selection behind the profile
---@return table<string, unknown> runnable pair-transform emitter task
local function newPairTransformEmitter(args, context, kind, registry, system, ordinal, transform)
  local attackerSlot = battlerPosition(context, "attacker", kind)
  local defenderSlot = battlerPosition(context, "target", kind)
  local slotA = transform.a == "attacker" and attackerSlot or defenderSlot
  local slotB = transform.b == "attacker" and attackerSlot or defenderSlot
  local typeA = CONFIGURED_BATTLER_TYPES[slotA]
  local typeB = CONFIGURED_BATTLER_TYPES[slotB]
  if typeA == nil or typeB == nil then
    error(malformedMessage(kind, "resolves pair-transform battlers at known occurrence slots"), 0)
  end
  local sign = configuredSideSign(typeA)
  local slot = args.continuationSlot or 0
  local perspective = registry.perspective[args.systemIndex] or 0
  local vectors = args.scriptVectors
  if type(vectors) ~= "table" or #vectors ~= 7 then
    error(malformedMessage(kind, "carries seven script axis triples for pair-transform profiles"), 0)
  end
  local axis = pairTransformAxis(vectors --[[@as table<integer, table<string, integer>>]], typeA, typeB, kind)
  local scriptPosition = args.scriptPosition
  if type(scriptPosition) ~= "table" then
    error(malformedMessage(kind, "carries a script position for pair-transform profiles"), 0)
  end
  local position = nil
  if scriptPosition.x == 0 and scriptPosition.y == 0 and scriptPosition.z == 0 then
    local vector = placementOf(system.payload, slotA, perspective, kind, 0)
    position = { x = vector.x, y = vector.y, z = vector.z }
  else
    if scriptPosition.x == 0 and scriptPosition.y == 3200 then
      sign = 1
    end
    local kindZero = placementOf(system.payload, slotA, perspective, kind, 0)
    position = {
      x = scriptPosition.x * sign / 4096,
      y = scriptPosition.y * sign / 4096,
      z = kindZero.z * sign,
    }
  end
  if transform.mode == "converge" or transform.mode == "magnet" then
    local fieldKind = transform.mode == "converge" and "convergence" or "magnet"
    local entry = sharedFieldBlock(system, ordinal, fieldKind, kind)
    local target = nil
    local targetKind = transform.target
    if targetKind == 1 then
      target = { x = entry.position.x * sign, y = entry.position.y * sign, z = entry.position.z * sign }
    elseif targetKind == 2 then
      target = { x = 0, y = 3200 * sign / 4096, z = 0 }
    elseif targetKind == 3 then
      local vector = placementOf(system.payload, slotB, perspective, kind, 0)
      target = { x = vector.x, y = vector.y, z = vector.z }
    elseif targetKind == 4 then
      local vector = placementOf(system.payload, slotA, perspective, kind, 0)
      target = { x = vector.x, y = vector.y, z = vector.z }
    else
      target = scalePairTarget(args.scriptTarget, sign, kind)
    end
    entry.position = { x = target.x - position.x, y = target.y - position.y, z = target.z - position.z }
  end
  applyCreationCamera(system.simulation, registry, args.systemIndex)
  local runtime = createManagedEmitter(system.simulation, ordinal, kind)
  local record = runtime.record --[[@as table<string, unknown>]]
  runtime.axis = axis
  record.axis = axis
  runtime.x, runtime.y, runtime.z = position.x, position.y, position.z
  if record.persistent then
    registry.emitters[slot] = { runtime = runtime, system = system, slot = slot, perspective = perspective }
  end
  return setmetatable({ _system = system, _runtime = runtime, _state = "running" }, EmitterTask)
end

-- Creates one emitter at physical battler 1: its own kind-0 placement
-- on the player side, otherwise the opposing type's kind-0, then the
-- current camera angle reapplies around the current target.
---@param args table<string, unknown> instruction arguments carrying the emitter ordinal
---@param context table<string, unknown> occurrence-bound playback context
---@param kind string task kind under diagnosis
---@param registry table<string, unknown> occurrence particle registry behind slot handles
---@param system table<string, unknown> loaded particle system behind the simulation
---@param ordinal integer zero-based emitter ordinal into the loaded manager
---@return table<string, unknown> runnable physical-battler emitter task
local function newFirstOpponentEmitter(args, context, kind, registry, system, ordinal)
  local slot = args.continuationSlot or 0
  local perspective = registry.perspective[args.systemIndex] or 0
  local type1 = physicalBattlerType(context, 1)
  local playerSide = type1 == 0 or type1 == 2 or type1 == 4
  local positionSlot = playerSide and SLOT_BY_BATTLER_TYPE[type1] or SLOT_BY_BATTLER_TYPE[OPPOSING_BATTLER_TYPE[type1]]
  local vector = placementOf(system.payload, positionSlot, perspective, kind, 0)
  applyCreationCamera(system.simulation, registry, args.systemIndex)
  local runtime = createManagedEmitter(system.simulation, ordinal, kind)
  runtime.x, runtime.y, runtime.z = vector.x, vector.y, vector.z
  local camera = system.simulation.camera
  if type(camera) == "table" then
    local FxMath = require("libs.hgss.src.presentation.PresentationFxMath")
    refreshCameraEye(camera, FxMath)
  end
  if runtime.record.persistent then
    registry.emitters[slot] = { runtime = runtime, system = system, slot = slot, perspective = perspective }
  end
  return setmetatable({ _system = system, _runtime = runtime, _state = "running" }, EmitterTask)
end

-- Creates one emitter at physical battler 0 with the camera up selected
-- by the defender index: default up exactly when the defender is
-- battler 0, flipped otherwise.
---@param args table<string, unknown> instruction arguments carrying the emitter ordinal
---@param context table<string, unknown> occurrence-bound playback context
---@param kind string task kind under diagnosis
---@param registry table<string, unknown> occurrence particle registry behind slot handles
---@param system table<string, unknown> loaded particle system behind the simulation
---@param ordinal integer zero-based emitter ordinal into the loaded manager
---@return table<string, unknown> runnable physical-battler emitter task
local function newBattlerZeroEmitter(args, context, kind, registry, system, ordinal)
  local slot = args.continuationSlot or 0
  local perspective = registry.perspective[args.systemIndex] or 0
  local zeroSlot = SLOT_BY_BATTLER_TYPE[physicalBattlerType(context, 0)]
  local vector = placementOf(system.payload, zeroSlot, perspective, kind, 0)
  local defenderSlot = battlerPosition(context, "target", kind)
  local defenderType = CONFIGURED_BATTLER_TYPES[defenderSlot]
  if defenderType == nil then
    error(malformedMessage(kind, "resolves the defender at a known occurrence slot"), 0)
  end
  applyCreationCamera(system.simulation, registry, args.systemIndex)
  local runtime = createManagedEmitter(system.simulation, ordinal, kind)
  runtime.x, runtime.y, runtime.z = vector.x, vector.y, vector.z
  local camera = system.simulation.camera
  if type(camera) == "table" then
    camera.upX, camera.upZ = 0, 0
    camera.upY = (defenderType == 0 or defenderType == 2) and 4096 or -4096
  end
  if runtime.record.persistent then
    registry.emitters[slot] = { runtime = runtime, system = system, slot = slot, perspective = perspective }
  end
  return setmetatable({ _system = system, _runtime = runtime, _state = "running" }, EmitterTask)
end

-- Creates one emitter over the attacker side's solo slot at kind 0.
---@param args table<string, unknown> instruction arguments carrying the emitter ordinal
---@param context table<string, unknown> occurrence-bound playback context
---@param kind string task kind under diagnosis
---@param registry table<string, unknown> occurrence particle registry behind slot handles
---@param system table<string, unknown> loaded particle system behind the simulation
---@param ordinal integer zero-based emitter ordinal into the loaded manager
---@return table<string, unknown> runnable solo-side emitter task
local function newAttackerSideEmitter(args, context, kind, registry, system, ordinal)
  local slot = args.continuationSlot or 0
  local perspective = registry.perspective[args.systemIndex] or 0
  local attackerSlot = battlerPosition(context, "attacker", kind)
  local sideSlot = configuredSide(attackerSlot, kind) == 3 and "solo-player" or "solo-enemy"
  local vector = placementOf(system.payload, sideSlot, perspective, kind, 0)
  applyCreationCamera(system.simulation, registry, args.systemIndex)
  local runtime = createManagedEmitter(system.simulation, ordinal, kind)
  runtime.x, runtime.y, runtime.z = vector.x, vector.y, vector.z
  if runtime.record.persistent then
    registry.emitters[slot] = { runtime = runtime, system = system, slot = slot, perspective = perspective }
  end
  return setmetatable({ _system = system, _runtime = runtime, _state = "running" }, EmitterTask)
end

-- Occurrence-bound emitter handles behind the path callbacks: the
-- registry slot validates the owning system, and the identity guard
-- keeps stale or mismatched lookups from touching a successor.
---@param owner table<string, unknown> occurrence-bound context carrying the particle registry
---@param systemSlot integer logical system slot under validation, 0..15
---@param emitterSlot integer global emitter slot under validation, 0..15
---@return table<string, unknown> identity-safe emitter handle
function BattleParticleSystems.getEmitterHandle(owner, systemSlot, emitterSlot)
  local kind = "battle-particle-emitter-handle"
  if type(owner) ~= "table" then
    error(malformedMessage(kind, "binds handles through its occurrence context"), 0)
  end
  local registry = registryOf(owner, kind)
  if not isNonNegativeInteger(systemSlot) or systemSlot > MAX_SYSTEM_INDEX then
    error(malformedMessage(kind, "binds a system slot in 0.." .. MAX_SYSTEM_INDEX), 0)
  end
  if not isNonNegativeInteger(emitterSlot) or emitterSlot > MAX_SYSTEM_INDEX then
    error(malformedMessage(kind, "binds an emitter slot in 0.." .. MAX_SYSTEM_INDEX), 0)
  end
  local system = registry.systems[systemSlot]
  if system == nil then
    error(malformedMessage(kind, "binds system slot " .. systemSlot .. " before loading it"), 0)
  end
  local handle = registry.emitters[emitterSlot]
  if handle == nil or handle.system ~= system then
    error(malformedMessage(kind, "binds emitter slot " .. emitterSlot .. " before creating it"), 0)
  end
  local identity = handle
  local base = { x = 0, y = 0, z = 0 }
  local stored = identity.runtime
  if type(stored) == "table" and type(stored.record) == "table" then
    local position = stored.record.position
    if type(position) == "table" then
      base = { x = position.x or 0, y = position.y or 0, z = position.z or 0 }
    end
  end
  local facade = {}
  -- Detached signed raw fx32 coordinates in source setter-argument
  -- space: the stored position minus the immutable resource base.
  function facade:getPositionFx32()
    if registry.emitters[emitterSlot] ~= identity then
      error(malformedMessage(kind, "reads a handle its slot no longer references"), 0)
    end
    local runtime = identity.runtime
    if type(runtime) ~= "table" then
      error(malformedMessage(kind, "reads a deleted emitter handle"), 0)
    end
    return {
      x = math.floor((runtime.x or 0) * FX_ONE + 0.5) - math.floor(base.x * FX_ONE + 0.5),
      y = math.floor((runtime.y or 0) * FX_ONE + 0.5) - math.floor(base.y * FX_ONE + 0.5),
      z = math.floor((runtime.z or 0) * FX_ONE + 0.5) - math.floor(base.z * FX_ONE + 0.5),
    }
  end
  -- Stores s32(resource base + value) per supplied axis; omitted axes
  -- stay untouched. Base is added here once, never in task code again.
  function facade:setPositionFx32(position)
    if registry.emitters[emitterSlot] ~= identity then
      error(malformedMessage(kind, "writes a handle its slot no longer references"), 0)
    end
    local runtime = identity.runtime
    if type(runtime) ~= "table" then
      error(malformedMessage(kind, "writes a deleted emitter handle"), 0)
    end
    assert(type(position) == "table", "emitter handle writes carry their coordinates as a record")
    local function storedAxis(current, resourceBase, value)
      if value == nil then
        return current
      end
      local raw = resourceBase + value
      if raw >= 2147483648 then
        raw = raw - 4294967296
      elseif raw < -2147483648 then
        raw = raw + 4294967296
      end
      return raw / FX_ONE
    end
    local baseFx = {
      x = math.floor(base.x * FX_ONE + 0.5),
      y = math.floor(base.y * FX_ONE + 0.5),
      z = math.floor(base.z * FX_ONE + 0.5),
    }
    runtime.x = storedAxis(runtime.x, baseFx.x, position.x)
    runtime.y = storedAxis(runtime.y, baseFx.y, position.y)
    runtime.z = storedAxis(runtime.z, baseFx.z, position.z)
  end
  -- Oldest live parent has age != life; no-parent boundary is
  -- deterministically false and children never count.
  function facade:isActive()
    if registry.emitters[emitterSlot] ~= identity then
      return false
    end
    local runtime = identity.runtime
    if type(runtime) ~= "table" then
      return false
    end
    return emitterActive(runtime)
  end
  -- Idempotently deletes this exact emitter; clears the script slot
  -- only while it still references this identity.
  function facade:delete()
    if registry.emitters[emitterSlot] == identity then
      registry.emitters[emitterSlot] = nil
    end
    local runtime = identity.runtime
    if type(runtime) == "table" and type(identity.system) == "table" then
      SplParticleSimulation.removeEmitter(identity.system.simulation, runtime)
      identity.runtime = nil
    end
  end
  return facade
end

-- One source particle draw phase: capture every manager's geometry
-- first, then calculate all systems once in native physical slot
-- order. Later host rendering reuses that captured result; no
-- per-system task calculates twice.
---@param scene table<string, unknown> scene carrying the physical manager registry
---@param sourceTick table<string, unknown>? accepted source tick under advancement
function BattleParticleSystems.stepSourceDrawPhase(scene, sourceTick)
  local _ = sourceTick
  assert(type(scene) == "table", "the source draw phase captures through its scene")
  if type(scene.particleSystems) ~= "function" then
    return
  end
  local systems = scene:particleSystems()
  if type(systems) ~= "table" then
    return
  end
  local captured = {}
  for slot, view in ipairs(systems) do
    local simulation = type(view) == "table" and view.simulation or nil
    if type(simulation) == "table" and type(simulation.emitters) == "table" then
      local snapshot = {}
      for _, runtime in ipairs(simulation.emitters) do
        snapshot[#snapshot + 1] = {
          runtime = runtime,
          x = runtime.x,
          y = runtime.y,
          z = runtime.z,
          particles = #runtime.particles,
        }
      end
      captured[slot] = { simulation = simulation, snapshot = snapshot }
    end
  end
  for slot = 1, #systems do
    local entry = captured[slot]
    if entry ~= nil then
      SplParticleSimulation.advance(entry.simulation)
    end
  end
end

-- CreateEmitter: adds one emitter of the loaded system, positioned by its
-- callback profile, and holds it as a particle-group task until the emitter
-- leaves the system.
---@param args table<string, unknown> instruction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@return BattleParticleEmitterTask
function BattleParticleSystems.newEmitterTask(args, context)
  local kind = BattleParticleSystems.EMITTER_KIND
  local registry = registryOf(context, kind)
  local system = registry.systems[args.systemIndex]
  if system == nil then
    error(
      malformedMessage(kind, "creates an emitter in system slot " .. tostring(args.systemIndex) .. " before loading it"),
      0
    )
  end
  local slot = args.continuationSlot or 0
  local ordinal = args.emitter --[[@as integer]]
  if type(ordinal) ~= "number" or ordinal % 1 ~= 0 or ordinal < 0 or system.payload.emitters[ordinal + 1] == nil then
    error(malformedMessage(kind, "names an emitter ordinal outside its loaded system"), 0)
  end
  if RELATIVE_OFFSET_PROFILES[args.actionProfile] then
    return newRelativeOffsetEmitter(args, context, kind, registry, system, ordinal)
  end
  local pairTransform = PAIR_TRANSFORMS[args.actionProfile]
  if pairTransform ~= nil then
    return newPairTransformEmitter(args, context, kind, registry, system, ordinal, pairTransform)
  end
  if args.actionProfile == "particle-emitter-camera-relative" then
    return newFirstOpponentEmitter(args, context, kind, registry, system, ordinal)
  end
  if args.actionProfile == "particle-emitter-world-position" then
    return newBattlerZeroEmitter(args, context, kind, registry, system, ordinal)
  end
  if args.actionProfile == "particle-emitter-battler-pair-position" then
    return newAttackerSideEmitter(args, context, kind, registry, system, ordinal)
  end
  local callback = CALLBACK_ROLES[args.actionProfile]
  if callback == nil then
    if args.actionProfile == "particle-emitter-battler-class-camera-position" then
      return newConfiguredEmitter(args, context, kind, registry, system, ordinal)
    end
    error(malformedMessage(kind, "reproduces emitter callback " .. tostring(args.actionProfile)), 0)
  end
  applyCreationCamera(system.simulation, registry, args.systemIndex)
  local perspective = registry.perspective[args.systemIndex] or 0
  local x, y, z = nil, nil, nil
  if callback.placement then
    local placementSlot = nil
    if callback.placement == "defenderSide" then
      local _, defender = configuredBattlers(context, kind)
      if configuredSide(defender.slot, kind) == 4 then
        placementSlot = "solo-enemy"
      else
        placementSlot = "solo-player"
      end
    else
      placementSlot = battlerPosition(context, callback.placement == "attacker" and "attacker" or "target", kind)
    end
    local vector = placementOf(system.payload, placementSlot, perspective, kind, 0)
    x, y, z = vector.x, vector.y, vector.z
  end
  local runtime = createManagedEmitter(system.simulation, ordinal, kind)
  if x ~= nil then
    runtime.x, runtime.y, runtime.z = x, y, z
  end
  -- A self-destroying emitter is never handed to the script, so no path
  -- callback can target it.
  if runtime.record.persistent then
    registry.emitters[slot] = { runtime = runtime, system = system, slot = slot, perspective = perspective }
  end
  return setmetatable({ _system = system, _runtime = runtime, _state = "running" }, EmitterTask)
end

---@param self BattleParticleEmitterTask
---@param tick table<string, unknown>? source tick under advancement
function EmitterTask:stepSourceTick(tick)
  local _ = tick
  if self._state == "running" and not SplParticleSimulation.hasEmitter(self._system.simulation, self._runtime) then
    self._state = "complete"
  end
end

---@param self BattleParticleEmitterTask
---@return string
function EmitterTask:status()
  if self._state == "running" and not SplParticleSimulation.hasEmitter(self._system.simulation, self._runtime) then
    self._state = "complete"
  end
  return self._state
end

---@param self BattleParticleEmitterTask
---@param reason string cancellation cause under diagnosis
function EmitterTask:cancel(reason)
  local _ = reason
  if self._state == "complete" then
    return
  end
  self._state = "cancelled"
  SplParticleSimulation.removeEmitter(self._system.simulation, self._runtime)
end

---@param self BattleParticleEmitterTask
function EmitterTask:dispose()
  SplParticleSimulation.removeEmitter(self._system.simulation, self._runtime)
end

-- C integer division truncates toward zero.
---@param numerator integer
---@param denominator integer
---@return integer
local function cdiv(numerator, denominator)
  local quotient = numerator / denominator
  return quotient >= 0 and math.floor(quotient) or math.ceil(quotient)
end

-- The retail 16-bit position cast of the emitter pixel coordinates.
---@param value integer
---@return integer
local function toS16(value)
  value = value % 65536
  return value >= 32768 and value - 65536 or value
end

---@param slot string semantic battler position
---@return integer sign -1 for the enemy side, +1 for the player side (retail mode zero)
local function sideSign(slot)
  return (slot == "solo-enemy" or slot:sub(1, 5) == "enemy") and -1 or 1
end

---@class BattleParticlePathTask
---@field _handle table<string, unknown> emitter handle being moved
---@field _linear table<string, integer> linear motion state
---@field _delay integer
---@field _counter integer
---@field _windowOpen boolean
---@field _wave boolean
---@field _angle integer
---@field _waveStep integer
---@field _registry BattleParticleRegistry
---@field _state string running or complete or cancelled
local PathTask = {}
PathTask.__index = PathTask

---@param linear table<string, integer>
---@return boolean moved
local function updateLinear(linear)
  if linear.duration == 0 then
    return false
  end
  linear.curX = linear.curX + linear.stepX
  linear.curY = linear.curY + linear.stepY
  linear.x = math.floor(linear.curX / FX_ONE)
  linear.y = math.floor(linear.curY / FX_ONE)
  linear.duration = linear.duration - 1
  return true
end

---@param self BattleParticlePathTask
local function placeEmitter(self)
  local runtime = self._handle.runtime --[[@as table<string, unknown>]]
  local linear = self._linear
  runtime.x = linear.x * EMITTER_PIXEL_RAW / FX_ONE
  local y = linear.y * EMITTER_PIXEL_RAW
  if self._wave then
    self._angle = self._angle + self._waveStep
    y = y + math.floor(math.sin(math.rad(self._angle)) * FX_ONE)
  end
  runtime.y = y / FX_ONE
end

-- BattleAnimFunc_MoveEmitter: moves a persistent emitter between the attacker
-- and target emitter placements over the callback duration, then removes it
-- once its motion ends and its oldest particle is on its last tick.
-- The curved emitter path is not reproduced: the factory dispatch fails
-- loudly at construction instead of keeping a silently unmoved emitter.

---@param args table<string, unknown> instruction arguments carrying the path parameters
---@param context table<string, unknown> occurrence-bound playback context
---@return BattleParticlePathTask
function BattleParticleSystems.newPathTask(args, context)
  local kind = BattleParticleSystems.PATH_KIND
  local parameters = args.parameters --[[@as table<string, unknown>?]]
  if type(parameters) ~= "table" then
    error(malformedMessage(kind, "carries its path operands as a record"), 0)
  end
  local registry = registryOf(context, kind)
  local handle = registry.emitters[parameters.emitterSlot]
  if handle == nil then
    error(malformedMessage(kind, "moves an emitter slot that holds no persistent emitter"), 0)
  end
  local duration = parameters.durationTicks --[[@as integer]]
  if type(duration) ~= "number" or duration % 1 ~= 0 or duration < 1 then
    error(malformedMessage(kind, "moves over a positive duration"), 0)
  end
  local fromRole, toRole = "attacker", "target"
  if parameters.pairOrder == "target-attacker" then
    fromRole, toRole = "target", "attacker"
  end
  local attackerSlot = battlerPosition(context, "attacker", kind) --[[@as string]]
  local fromSlot = battlerPosition(context, fromRole, kind) --[[@as string]]
  local toSlot = battlerPosition(context, toRole, kind)
  local payload = handle.system.payload --[[@as table<string, unknown>]]
  local perspective = handle.perspective --[[@as integer]]
  local from = placementOf(payload, fromSlot, perspective, kind, handle.kind or 0)
  local to = placementOf(payload, toSlot, perspective, kind, handle.kind or 0)
  local side = sideSign(attackerSlot)
  local function pixel(world)
    return toS16(cdiv(math.floor(world * FX_ONE + 0.5), EMITTER_PIXEL_RAW))
  end
  local startX, endX = pixel(from.x), toS16(pixel(to.x) + parameters.offsetX --[[@as integer]] * side)
  local startY, endY = pixel(from.y), toS16(pixel(to.y) + parameters.offsetY --[[@as integer]] * side)
  local linear = {
    x = startX,
    y = startY,
    duration = duration,
    stepX = cdiv((endX - startX) * FX_ONE, duration),
    stepY = cdiv((endY - startY) * FX_ONE, duration),
    curX = startX * FX_ONE,
    curY = startY * FX_ONE,
  }
  for _ = 1, parameters.startFrame --[[@as integer]] do
    updateLinear(linear)
  end
  local endFrame = parameters.endFrame --[[@as integer]]
  -- The retail frame window never advances: it stays open only for the
  -- 255 end frame, and a bounded end frame leaves it past its own end.
  local frame = endFrame ~= 255 and endFrame + 1 or 0
  local startFrame = parameters.startFrame --[[@as integer]]
  local self = setmetatable({
    _handle = handle,
    _linear = linear,
    _delay = parameters.delayTicks --[[@as integer]],
    _counter = 0,
    _windowOpen = endFrame == 255 or (startFrame <= frame and endFrame >= frame),
    _wave = parameters.wave == true,
    _angle = 0,
    _waveStep = cdiv(360, duration),
    _registry = registry,
    _state = "running",
  }, PathTask)
  -- The retail setup writes the position before the first task tick.
  local runtime = handle.runtime --[[@as table<string, unknown>]]
  runtime.x = linear.x * EMITTER_PIXEL_RAW / FX_ONE
  runtime.y = linear.y * EMITTER_PIXEL_RAW / FX_ONE
  return self
end

---@param self BattleParticlePathTask
---@param tick table<string, unknown>? source tick under advancement
function PathTask:stepSourceTick(tick)
  local _ = tick
  if self._state ~= "running" then
    return
  end
  local handle = self._handle
  local simulation = handle.system.simulation --[[@as SplParticleSimulation]]
  if not SplParticleSimulation.hasEmitter(simulation, handle.runtime) then
    self._state = "complete"
    return
  end
  local active = emitterActive(handle.runtime --[[@as table<string, unknown>]])
  if self._counter < self._delay then
    self._counter = self._counter + 1
    return
  end
  if not updateLinear(self._linear) and not active then
    SplParticleSimulation.removeEmitter(simulation, handle.runtime)
    if self._registry.emitters[handle.slot] == handle then
      self._registry.emitters[handle.slot] = nil
    end
    self._state = "complete"
    return
  end
  if self._windowOpen then
    placeEmitter(self)
  end
end

---@param self BattleParticlePathTask
---@return string
function PathTask:status()
  return self._state
end

---@param self BattleParticlePathTask
---@param reason string cancellation cause under diagnosis
function PathTask:cancel(reason)
  local _ = reason
  if self._state == "complete" then
    return
  end
  self._state = "cancelled"
end

---@param self BattleParticlePathTask
function PathTask:dispose()
  self._state = self._state == "running" and "cancelled" or self._state
end

return BattleParticleSystems
