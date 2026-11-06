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
-- position, and the defender-side profile that pins the emitter over
-- the defender side's solo slot. Every other callback fails closed at emitter creation.
local CALLBACK_ROLES = {
  ["particle-emitter-default"] = { placement = false },
  ["particle-emitter-active-battler-relative"] = { placement = "attacker" },
  ["particle-emitter-target-battler-relative"] = { placement = "target" },
  ["particle-emitter-battler-pair-orientation"] = { placement = "defenderSide" },
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
    local simulation = SplParticleSimulation.new(payload.seed, 0)
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
-- its emitter kind and battler role. Literal-offset modes add the
-- carried script offset; every other listed mode reads its kind
-- column. Anything else fails loudly instead of inventing a placement.
local CONFIGURED_POSITIONS = {
  [0] = {},
  [1] = { kind = 0, battler = "a" },
  [2] = { kind = 0, battler = "b" },
  [3] = { offset = true },
  [4] = { kind = 0, battler = "a", offset = true },
  [5] = { kind = 0, battler = "b", offset = true },
  [6] = { kind = 1, battler = "a" },
  [16] = { kind = 4, battler = "a" },
}

-- Axis modes the configured emitter reproduces: 0 keeps the staged
-- record axis while modes 1, 5, and 10 read the staged Mode1/Mode10
-- tables by ordered battler types exactly like the native lookup (the
-- host Field08 flag is only ever zero-initialized, so the table path
-- always applies). Anything else fails loudly instead of inventing an
-- orientation.
local CONFIGURED_AXES = { [0] = true, [1] = true, [5] = true, [10] = true }

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
-- reader scales x and y by the battler-A side sign (unless the block
-- ignores the side) while z rides unscaled.
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

---@param axisMode integer script axis mode under resolution
---@param typeA integer attacker battler type behind the lookup
---@param typeB integer defender battler type behind the lookup
---@param sideA integer attacker native side behind same-side checks
---@param sideB integer defender native side behind same-side checks
---@param axisTables table<string, unknown> staged configured axis tables behind the lookup
---@param kind string task kind under diagnosis
---@return table<string, number>? configured axis vector, nil to keep the record axis
local function configuredAxis(axisMode, typeA, typeB, sideA, sideB, axisTables, kind)
  if axisMode == 0 then
    return nil
  end
  if CONFIGURED_AXES[axisMode] ~= true then
    error(malformedMessage(kind, "reproduces configured axis mode " .. tostring(axisMode)), 0)
  end
  if type(axisTables) ~= "table" then
    error(malformedMessage(kind, "reads staged configured axis tables"), 0)
  end
  local modeKey = (axisMode == 5 or axisMode == 1) and "mode1" or "mode10"
  local tableVectors = axisTables[modeKey]
  if type(tableVectors) ~= "table" then
    error(malformedMessage(kind, "reads a staged configured axis table for mode " .. tostring(axisMode)), 0)
  end
  if axisMode == 1 then
    return configuredAxisRow(tableVectors, typeA, typeB, 2, 1, kind)
  end
  if axisMode == 5 then
    if sideA == sideB then
      return configuredAxisRow(tableVectors, typeA, typeB, 2, 1, kind)
    end
    if sideA == 3 then
      return { x = 3776 / 4096, y = 2112 / 4096, z = 1532 / 4096 }
    end
    return { x = -4228 / 4096, y = -2728 / 4096, z = 1532 / 4096 }
  end
  return configuredAxisRow(tableVectors, typeA, typeB, 2, 1, kind)
end

-- Creates one emitter positioned by its configure-from-script block:
-- the battler order selects attacker/defender roles, the position mode
-- selects a staged kind column (plus the carried script offset where
-- the mode reads one), and the axis mode selects the staged record
-- axis or a Mode1/Mode10 table vector. Camera, flag, and z modes
-- other than the staged no-ops fail loudly instead of inventing
-- camera motion, forces, or depth.
---@param args table<string, unknown> instruction arguments carrying the configured emitter
---@param context table<string, unknown> occurrence-bound playback context
---@param kind string task kind under diagnosis
---@param registry table<string, unknown> occurrence particle registry behind slot handles
---@param system table<string, unknown> loaded particle system behind the simulation
---@param record table<string, unknown> staged emitter record behind the runtime
---@return table<string, unknown> runnable configured emitter task
local function newConfiguredEmitter(args, context, kind, registry, system, record)
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
  if config.flags ~= 0 then
    error(malformedMessage(kind, "reproduces configured emitter flags"), 0)
  end
  if config.cameraMode ~= 0 then
    error(malformedMessage(kind, "reproduces configured camera modes"), 0)
  end
  if config.zMode ~= 0 then
    error(malformedMessage(kind, "reproduces configured z modes"), 0)
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
  local position = nil
  if mode.kind ~= nil then
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
  elseif mode.offset == true then
    position = { x = 0, y = 0, z = 0 }
  end
  if mode.offset == true then
    local base = position
    if base == nil then
      base = { x = 0, y = 0, z = 0 }
    end
    local sign = (typeA == 1 or typeA == 3 or typeA == 5) and -1 or 1
    local applied = offset
    position = applyConfiguredOffset(base, applied, sign)
  end
  local axis = configuredAxis(
    config.axisMode,
    typeA,
    typeB,
    configuredSide(slotA, kind),
    configuredSide(slotB, kind),
    system.payload.axisTables,
    kind
  )
  local placed = record
  if axis ~= nil then
    local shaped = {}
    for field, value in pairs(record) do
      shaped[field] = value
    end
    shaped.axis = axis
    placed = shaped
  end
  local runtime = SplParticleSimulation.addEmitter(system.simulation, record.id, nil, placed)
  if position ~= nil then
    runtime.x, runtime.y, runtime.z = position.x, position.y, position.z
  end
  if record.persistent then
    registry.emitters[slot] = { runtime = runtime, system = system, slot = slot, perspective = perspective }
  end
  return setmetatable(
    { _system = system, _runtime = runtime, _state = "running", _axis = axis or record.axis },
    EmitterTask
  )
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
  local record = system.payload.emitters[
    (args.emitter --[[@as integer]] or -1) + 1
  ]
  if record == nil then
    error(malformedMessage(kind, "names an emitter ordinal outside its loaded system"), 0)
  end
  local callback = CALLBACK_ROLES[args.actionProfile]
  if callback == nil then
    if args.actionProfile == "particle-emitter-battler-class-camera-position" then
      return newConfiguredEmitter(args, context, kind, registry, system, record)
    end
    error(malformedMessage(kind, "reproduces emitter callback " .. tostring(args.actionProfile)), 0)
  end
  if (registry.flipY[args.systemIndex] or 0) ~= 0 then
    error(malformedMessage(kind, "reproduces emitters under a flipped particle camera"), 0)
  end
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
  local runtime = SplParticleSimulation.addEmitter(system.simulation, record.id, nil, record)
  if x ~= nil then
    runtime.x, runtime.y, runtime.z = x, y, z
  end
  -- A self-destroying emitter is never handed to the script, so no path
  -- callback can target it.
  if record.persistent then
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
