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
-- compile, an emitter callback, a flipped camera, a curved path) never plays
-- invented motion: the owning task is inert, the occurrence keeps running, and
-- the reason is recorded in registry.skipped for diagnosis.

local SplParticleSimulation = require("libs.hgss.src.presentation.SplParticleSimulation")

local BattleParticleSystems = {}

BattleParticleSystems.SYSTEM_KIND = "battle-particle-system"
BattleParticleSystems.EMITTER_KIND = "battler-effect-continuation"
BattleParticleSystems.PATH_KIND = "battle-particle-emitter-battler-path"
BattleParticleSystems.CURVED_PATH_KIND = "battle-particle-emitter-curved-battler-path"

local MAX_SYSTEM_INDEX = 15

-- Emitter callbacks the replay reproduces: the profile that keeps the
-- resource position, and the two that move the emitter onto a battler's
-- placement. Every other callback fails closed at emitter creation.
local CALLBACK_ROLES = {
  ["particle-emitter-default"] = { placement = false },
  ["particle-emitter-active-battler-relative"] = { placement = "attacker" },
  ["particle-emitter-target-battler-relative"] = { placement = "target" },
}

-- One world unit per source pixel step of the emitter motion task
-- (BATTLE_ANIM_EMITTER_PIXEL over the 1/4096 fixed point).
local EMITTER_PIXEL_RAW = 172
local FX_ONE = 4096

---@class BattleParticleEmitterHandle
---@field inert boolean|nil true for an emitter the replay left unplayed
---@field runtime table<string, unknown>|nil live emitter runtime
---@field system BattleParticleSystemTask|nil owning system
---@field slot integer|nil emitter slot
---@field perspective integer|nil particle perspective type at creation

---@class BattleParticleRegistry
---@field systems table<integer, BattleParticleSystemTask> live system tasks by system slot
---@field emitters table<integer, BattleParticleEmitterHandle> persistent emitter handles by emitter slot
---@field perspective table<integer, integer> SetParticlePerspective values by system slot
---@field flipY table<integer, integer> SetParticleFlipY values by system slot
---@field skipped string[] reasons particle work was left unplayed, in order

---@return BattleParticleRegistry registry shared by one animation occurrence
function BattleParticleSystems.newRegistry()
  return { systems = {}, emitters = {}, perspective = {}, flipY = {}, skipped = {} }
end

---@param kind string task kind under construction
---@param message string failure detail
---@return string
local function malformedMessage(kind, message)
  return "BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " " .. message
end

-- A task for particle work the replay does not reproduce: it plays nothing,
-- reports complete, and owns nothing to release.
---@class BattleInertParticleTask
local InertTask = {}
InertTask.__index = InertTask

---@return string
function InertTask.status()
  return "complete"
end

function InertTask.stepSourceTick() end

function InertTask.cancel() end

function InertTask.dispose() end

---@param registry BattleParticleRegistry
---@param reason string why the work stays unplayed
local function skip(registry, reason)
  registry.skipped[#registry.skipped + 1] = reason
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
-- battler per animation run; any other count is a gap the replay does not
-- reproduce.
---@param context table<string, unknown> occurrence-bound playback context
---@param role "attacker"|"target"
---@param kind string task kind under construction
---@return string|nil position semantic battler position
---@return string|nil skipped reason the replay leaves the work unplayed
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
      return nil, "emitters placed at one of several event targets"
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
---@return table<string, number> emitter world position
local function placementOf(payload, position, perspective, kind)
  local placements = payload.placements --[[@as table<string, table<integer, table<string, number>>>]]
  local vector = placements[position] and placements[position][perspective + 1] or nil
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
---@field inert boolean|nil true for a system the replay left unplayed
---@field _kind string
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
    -- The slot stays occupied by an inert system so the script's emitter
    -- creations and free still resolve; none of them plays anything.
    lease.release(staged)
    skip(registry, "particle system " .. resource .. ": " .. tostring(payload.unsupported))
    local inert = setmetatable({ inert = true, _state = "pending", _index = index, _registry = registry }, SystemTask)
    registry.systems[index] = inert
    return inert
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
  if self.inert then
    if self._registry.systems[self._index] == self then
      self._registry.systems[self._index] = nil
    end
    return
  end
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
  if not self.inert then
    SplParticleSimulation.advance(self.simulation)
  end
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
local EmitterTask = {}
EmitterTask.__index = EmitterTask

-- CreateEmitter: adds one emitter of the loaded system, positioned by its
-- callback profile, and holds it as a particle-group task until the emitter
-- leaves the system.
---@param args table<string, unknown> instruction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@return BattleParticleEmitterTask|BattleInertParticleTask
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
  local function unplayed(reason)
    skip(registry, reason)
    registry.emitters[slot] = { inert = true }
    return setmetatable({}, InertTask)
  end
  if system.inert then
    return unplayed("emitter " .. tostring(args.emitter) .. " of an unplayed particle system")
  end
  local record = system.payload.emitters[
    (args.emitter --[[@as integer]] or -1) + 1
  ]
  if record == nil then
    error(malformedMessage(kind, "names an emitter ordinal outside its loaded system"), 0)
  end
  local callback = CALLBACK_ROLES[args.actionProfile]
  if callback == nil then
    return unplayed("emitter callback " .. tostring(args.actionProfile))
  end
  if (registry.flipY[args.systemIndex] or 0) ~= 0 then
    return unplayed("emitters under a flipped particle camera")
  end
  local perspective = registry.perspective[args.systemIndex] or 0
  local x, y, z = nil, nil, nil
  if callback.placement then
    local position, reason = battlerPosition(context, callback.placement, kind)
    if position == nil then
      return unplayed(reason --[[@as string]])
    end
    local vector = placementOf(system.payload, position, perspective, kind)
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
-- The curved emitter path is not reproduced: the emitter it would move keeps
-- its placement.
---@param context table<string, unknown> occurrence-bound playback context
---@return BattleInertParticleTask
function BattleParticleSystems.newCurvedPathTask(context)
  skip(registryOf(context, BattleParticleSystems.CURVED_PATH_KIND), "curved emitter path")
  return setmetatable({}, InertTask)
end

---@param args table<string, unknown> instruction arguments carrying the path parameters
---@param context table<string, unknown> occurrence-bound playback context
---@return BattleParticlePathTask|BattleInertParticleTask
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
  if handle.inert then
    return setmetatable({}, InertTask)
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
  local toSlot, reason = battlerPosition(context, toRole, kind)
  if toSlot == nil then
    skip(registry, reason --[[@as string]])
    return setmetatable({}, InertTask)
  end
  local payload = handle.system.payload --[[@as table<string, unknown>]]
  local perspective = handle.perspective --[[@as integer]]
  local from = placementOf(payload, fromSlot, perspective, kind)
  local to = placementOf(payload, toSlot, perspective, kind)
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
