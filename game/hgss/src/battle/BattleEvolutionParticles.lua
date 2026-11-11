-- Owns one retail EvolutionScene SPL system. Emitters share its seeded
-- simulation, texture leases, perspective, source placement and lifetime.

local SplParticleSimulation = require("libs.hgss.src.presentation.SplParticleSimulation")

---@class BattleEvolutionParticles.Options
---@field set { seed: integer?, emitters: table<string, unknown>[], textures: { id: integer, drawable: table<string, unknown> }[] } compiled EvolutionScene resource
---@field emitterPosition { x: number, y: number, z: number } retail scene emitter placement
---@field splRandomState table<string, integer>? borrowed boot stream record shared by every manager of one boot

---@class BattleEvolutionParticles
---@field _simulation SplParticleSimulation one source EvolutionScene particle system
---@field _textures table<integer, table<string, unknown>> staged texture images by source id
---@field _emitters table<integer, boolean> emitter resources already created
---@field _records table<integer, table<string, unknown>> compiled emitter records
---@field _position { x: number, y: number, z: number } retail scene emitter position
---@field _splRandomState table<string, integer>? borrowed boot stream record, or nil for the staged seed fallback
local BattleEvolutionParticles = {}
BattleEvolutionParticles.__index = BattleEvolutionParticles

---@param opts BattleEvolutionParticles.Options
---@return BattleEvolutionParticles
function BattleEvolutionParticles.new(opts)
  assert(type(opts) == "table", "evolution particles require their staged scene resource")
  local set = assert(opts.set, "evolution particles need their compiled SPL set")
  assert(type(opts.splRandomState) == "table", "evolution particles borrow the boot stream record")
  assert(
    type(set.emitters) == "table" and #set.emitters == 13,
    "EvolutionScene resource zero carries emitters 0 through 12"
  )
  local position = assert(opts.emitterPosition, "evolution SPL needs its retail emitter placement")
  local textures = {}
  for _, texture in ipairs(assert(set.textures, "evolution SPL carries staged textures")) do
    local id = assert(texture.id, "evolution texture carries its source id")
    local drawable = assert(texture.drawable, "evolution texture is uploaded before scene creation")
    assert(textures[id] == nil, "evolution SPL texture ids are unique")
    textures[id] = drawable
  end
  local randomState = assert(opts.splRandomState, "evolution particles borrow their boot stream record")
  local simulation = SplParticleSimulation.new(randomState, 0, set.emitters)
  for expectedId, record in ipairs(set.emitters) do
    assert(type(record) == "table" and record.id == expectedId - 1, "EvolutionScene emitter ids stay contiguous")
  end
  return setmetatable({
    _simulation = simulation,
    _textures = textures,
    _emitters = {},
    _records = set.emitters,
    _splRandomState = opts.splRandomState,
    _position = { x = position.x, y = position.y, z = position.z },
  }, BattleEvolutionParticles)
end

---@param emitterId integer retail emitter resource id
function BattleEvolutionParticles:createEmitter(emitterId)
  assert(
    type(emitterId) == "number" and emitterId % 1 == 0 and emitterId >= 0 and emitterId < 13,
    "EvolutionScene names emitter ids 0 through 12"
  )
  assert(self._emitters[emitterId] ~= true, "EvolutionScene creates each emitter resource once")
  assert(self._records[emitterId + 1], "evolution resource carries every requested emitter")
  -- The scene placement rides the runtime position; the shared resource
  -- clone keeps its immutable base for the camera-offset drawing path.
  local runtime = SplParticleSimulation.addEmitter(self._simulation, emitterId, nil)
  assert(runtime ~= nil, "EvolutionScene creates its emitter while manager nodes are free")
  runtime.x, runtime.y, runtime.z = self._position.x, self._position.y, self._position.z
  self._emitters[emitterId] = true
end

function BattleEvolutionParticles:advance()
  SplParticleSimulation.advance(self._simulation)
end

---@return boolean whether a scene emitter remains active
function BattleEvolutionParticles:isActive()
  return #self._simulation.emitters > 0
end

---@return { simulation: SplParticleSimulation, textures: table<integer, table<string, unknown>> }[] live draw systems
function BattleEvolutionParticles:systems()
  if not self:isActive() then
    return {}
  end
  return { { simulation = self._simulation, textures = self._textures } }
end

function BattleEvolutionParticles:clear()
  local randomState = assert(self._splRandomState, "evolution particles borrow their boot stream record")
  self._simulation = SplParticleSimulation.new(randomState, 0, self._records)
  self._emitters = {}
end

return BattleEvolutionParticles
