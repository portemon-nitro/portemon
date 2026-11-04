-- Owns the retail battle encounter terrain particles
-- (Task_PlayEncounterAnimation): two emitter sets, each in its own particle
-- system, started on their staged animation frames. A set starts exactly on
-- its own start tick: staged art that arrives after the tick never starts
-- the set late, and a set whose compiled emitters or texture closure are
-- missing at its start tick fails loudly instead of running silent. A
-- started system keeps simulating once the animation ends and leaves the
-- draw list when its emitters retire, while the second set's started
-- identity is retained so the encounter task can tell a retired second
-- system from one that never started. Rendering reads the live systems;
-- nothing here draws.

local SplParticleSimulation = require("libs.hgss.src.presentation.SplParticleSimulation")

---@class BattleEncounterParticleSystem
---@field simulation SplParticleSimulation live emitter and particle state
---@field textures table<integer, table<string, unknown>> drawable handles by source texture id
---@field setIndex integer staged set order behind second-system status

---@class BattleEncounterParticles
---@field _started table<integer, boolean> staged set indexes that already started
---@field _systems BattleEncounterParticleSystem[] live systems in set order
---@field _secondStarted boolean true once the second staged set started, retained until clear
local BattleEncounterParticles = {}
BattleEncounterParticles.__index = BattleEncounterParticles

-- Battle emitters keep their resource position; only the opening scene's
-- emitter callback offsets z.
local EMITTER_Z_OFFSET = 0
-- The native encounter stages exactly two emitter sets in start order; the
-- second set's retirement is the encounter task's completion condition.
local SECOND_SET_INDEX = 2

---@return BattleEncounterParticles
function BattleEncounterParticles.new()
  return setmetatable({ _started = {}, _systems = {}, _secondStarted = false }, BattleEncounterParticles)
end

---@param set table<string, unknown> staged encounter particle set
---@param setIndex integer staged set order behind second-system status
---@return BattleEncounterParticleSystem
local function startSystem(set, setIndex)
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
  return { simulation = simulation, textures = textures, setIndex = setIndex }
end

-- A set that reaches its start tick must arrive with its compiled emitters
-- and every texture drawable staged; anything less fails the launch with
-- the set and frame instead of starting late or running silent.
---@param set table<string, unknown> staged encounter particle set under validation
---@param setIndex integer staged set order behind the diagnostic
---@param frame integer encounter animation frame behind the diagnostic
local function checkSetClosure(set, setIndex, frame)
  local emitters = set.emitters --[[@as table<string, unknown>[] ]]
  assert(
    type(emitters) == "table" and #emitters > 0,
    "encounter particle set " .. tostring(setIndex) .. " stages its compiled emitters for frame " .. tostring(frame)
  )
  local textures = set.textures --[[@as table<string, unknown>[] ]]
  assert(
    type(textures) == "table" and #textures > 0,
    "encounter particle set " .. tostring(setIndex) .. " stages its texture closure for frame " .. tostring(frame)
  )
  for _, texture in ipairs(textures) do
    local entry = texture --[[@as table<string, unknown>]]
    local drawable = type(entry) == "table" and entry.drawable or nil
    local image = type(entry) == "table" and entry.image or nil
    assert(
      type(entry) == "table" and (drawable ~= nil or (type(image) == "string" and image ~= "")),
      "encounter particle set " .. tostring(setIndex) .. " stages its texture drawables for frame " .. tostring(frame)
    )
  end
end

-- Advances every live system one source tick, first starting the set whose
-- start frame is exactly this tick. A set whose start tick already passed
-- never starts late.
---@param frame integer|nil encounter animation frame of this tick, nil outside the animation
---@param sets table<string, unknown>[]|nil staged encounter particle sets with resolved drawables
function BattleEncounterParticles:step(frame, sets)
  if frame ~= nil and sets ~= nil then
    for index, set in ipairs(sets) do
      local staged = set --[[@as table<string, unknown>]]
      if not self._started[index] and frame == staged.startTick then
        checkSetClosure(staged, index, frame)
        self._started[index] = true
        if index == SECOND_SET_INDEX then
          self._secondStarted = true
        end
        self._systems[#self._systems + 1] = startSystem(staged, index)
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

-- True once the second staged set started, retained after its system
-- retires so the encounter task can tell retirement from never-started.
---@return boolean
function BattleEncounterParticles:secondStarted()
  return self._secondStarted
end

-- True while the second system runs active source emitters; false both
-- before it starts and after it retires, so callers must read
-- secondStarted alongside this status.
---@return boolean
function BattleEncounterParticles:secondSystemActive()
  for _, system in ipairs(self._systems) do
    if system.setIndex == SECOND_SET_INDEX and #system.simulation.emitters > 0 then
      return true
    end
  end
  return false
end

-- Drops every live system and forgets which sets started.
function BattleEncounterParticles:clear()
  self._started = {}
  self._systems = {}
  self._secondStarted = false
end

return BattleEncounterParticles
