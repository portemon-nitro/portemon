-- Owns the retail battle encounter terrain particles
-- (Task_PlayEncounterAnimation): two emitter sets, each in its own particle
-- system, started on their staged animation frames. A started system keeps
-- simulating once the animation ends and leaves the draw list when its
-- emitters retire. Rendering reads the live systems; nothing here draws.

local SplParticleSimulation = require("libs.hgss.src.presentation.SplParticleSimulation")

---@class BattleEncounterParticleSystem
---@field simulation SplParticleSimulation live emitter and particle state
---@field textures table<integer, table<string, unknown>> drawable handles by source texture id

---@class BattleEncounterParticles
---@field _started table<integer, boolean> staged set indexes that already started
---@field _systems BattleEncounterParticleSystem[] live systems in set order
local BattleEncounterParticles = {}
BattleEncounterParticles.__index = BattleEncounterParticles

-- Battle emitters keep their resource position; only the opening scene's
-- emitter callback offsets z.
local EMITTER_Z_OFFSET = 0

---@return BattleEncounterParticles
function BattleEncounterParticles.new()
  return setmetatable({ _started = {}, _systems = {} }, BattleEncounterParticles)
end

---@param set table<string, unknown> staged encounter particle set
---@return BattleEncounterParticleSystem
local function startSystem(set)
  local simulation = SplParticleSimulation.new(set.seed --[[@as integer]], EMITTER_Z_OFFSET)
  for _, record in
    ipairs(set.emitters --[[@as table<string, unknown>[] ]])
  do
    SplParticleSimulation.addEmitter(simulation, record.id --[[@as integer]], nil, record)
  end
  local textures = {}
  for _, texture in
    ipairs(set.textures --[[@as table<string, unknown>[] ]])
  do
    textures[
      texture.id --[[@as integer]]
    ] = texture.drawable
  end
  return { simulation = simulation, textures = textures }
end

-- Advances every live system one source tick, first starting any set whose
-- start frame has been reached. A set whose art is not staged yet starts on
-- the first tick after it arrives.
---@param frame integer|nil encounter animation frame of this tick, nil outside the animation
---@param sets table<string, unknown>[]|nil staged encounter particle sets with resolved drawables
function BattleEncounterParticles:step(frame, sets)
  if frame ~= nil and sets ~= nil then
    for index, set in ipairs(sets) do
      if not self._started[index] and frame >= set.startTick then
        self._started[index] = true
        self._systems[#self._systems + 1] = startSystem(set)
      end
    end
  end
  for index = #self._systems, 1, -1 do
    local system = self._systems[index]
    SplParticleSimulation.advance(system.simulation)
    if #system.simulation.emitters == 0 then
      table.remove(self._systems, index)
    end
  end
end

---@return BattleEncounterParticleSystem[] live systems for drawing, in set order
function BattleEncounterParticles:systems()
  return self._systems
end

-- Drops every live system and forgets which sets started.
function BattleEncounterParticles:clear()
  self._started = {}
  self._systems = {}
end

return BattleEncounterParticles
