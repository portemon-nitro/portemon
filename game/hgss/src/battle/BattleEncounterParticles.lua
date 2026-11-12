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
---@field textureAlphaUsage table<integer, table<string, unknown>>? compiled transparency classification by source texture id
---@field setIndex integer staged set order behind second-system status
---@field sceneId unknown? scene manager slot identity, nil while unallocated

---@class BattleEncounterParticles
---@field _started table<integer, boolean> staged set indexes that already started
---@field _systems BattleEncounterParticleSystem[] live systems in set order
---@field _drawSystems BattleEncounterParticleSystem[] last published pre-advance systems for drawing
---@field _secondStarted boolean true once the second staged set started, retained until clear
---@field _splRandomState table<string, integer>? borrowed boot stream record shared by every manager of one boot
---@field _scene table<string, unknown>? scene manager-slot owner for first-free physical allocation
local BattleEncounterParticles = {}
BattleEncounterParticles.__index = BattleEncounterParticles

-- Battle emitters keep their resource position; only the opening scene's
-- emitter callback offsets z.
local EMITTER_Z_OFFSET = 0
-- The native encounter stages exactly two emitter sets in start order; the
-- second set's retirement is the encounter task's completion condition.
local SECOND_SET_INDEX = 2

---@param opts { splRandomState: table<string, integer>, scene: table<string, unknown>? } borrowed boot stream record and scene manager-slot owner
---@return BattleEncounterParticles
function BattleEncounterParticles.new(opts)
  opts = opts or {}
  assert(type(opts.splRandomState) == "table", "encounter particles borrow the boot stream record")
  return setmetatable({
    _started = {},
    _systems = {},
    _drawSystems = {},
    _secondStarted = false,
    _splRandomState = opts.splRandomState,
    _scene = opts.scene,
  }, BattleEncounterParticles)
end

---@param set table<string, unknown> staged encounter particle set
---@param setIndex integer staged set order behind second-system status
---@param splRandomState table<string, integer> borrowed boot stream record shared by one boot
---@return BattleEncounterParticleSystem
local function startSystem(set, setIndex, splRandomState)
  local randomState = assert(splRandomState, "encounter particles borrow their boot stream record")
  local simulation = SplParticleSimulation.new(randomState, EMITTER_Z_OFFSET, set.emitters)
  -- Native Task_PlayEncounterAnimation selects the orthographic camera
  -- for both encounter emitter sets: particle size never depends on
  -- perspective depth on this path.
  simulation.camera.perspective = 1
  for ordinal in
    ipairs(set.emitters --[[@as table<string, unknown>[] ]])
  do
    SplParticleSimulation.addEmitter(simulation, ordinal - 1, nil)
  end
  local textures = {}
  local textureAlphaUsage = {}
  for _, texture in
    ipairs(set.textures --[[@as table<string, unknown>[] ]])
  do
    textures[
      texture.id --[[@as integer]]
    ] = texture.drawable
    -- The generated descriptor carries the decoder's exact coverage
    -- flags: translucent texels must not harden into the cutout/opaque
    -- classification downstream. The start-tick closure already proved
    -- every texture carries them.
    textureAlphaUsage[
      texture.id --[[@as integer]]
    ] =
      assert(texture.alphaUsage, "encounter particle textures stage their alpha usage")
  end
  return { simulation = simulation, textures = textures, textureAlphaUsage = textureAlphaUsage, setIndex = setIndex }
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
    -- The staged texture closure carries the decoder's exact coverage
    -- flags: a set without them fails loudly instead of hardening
    -- translucent texels into the cutout/opaque classification.
    assert(
      type(entry) == "table" and type(entry.alphaUsage) == "table",
      "encounter particle set " .. tostring(setIndex) .. " stages its texture alpha usage for frame " .. tostring(frame)
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
        local system = startSystem(staged, index, self._splRandomState)
        if self._scene ~= nil and type(self._scene.allocParticleSystem) == "function" then
          system.sceneId = self._scene:allocParticleSystem(system)
        end
        self._systems[#self._systems + 1] = system
      end
    end
  end
  -- Publish the pre-advance frame for drawing before the simulation
  -- tick: the compositor paints this immutable geometry (including
  -- newborn and terminal polygons) while the live systems advance
  -- underneath. Retired systems leave the live list but stay visible
  -- through this frame.
  local published = {}
  for _, system in ipairs(self._systems) do
    published[#published + 1] = {
      simulation = SplParticleSimulation.copyForDraw(system.simulation),
      textures = system.textures,
      textureAlphaUsage = system.textureAlphaUsage,
      setIndex = system.setIndex,
      sceneId = system.sceneId,
    }
  end
  self._drawSystems = published
  for index = #self._systems, 1, -1 do
    local system = self._systems[index]
    SplParticleSimulation.advance(system.simulation)
    if #system.simulation.emitters == 0 then
      self:dropSystem(index)
    end
  end
end

---@return BattleEncounterParticleSystem[] live systems in set order
function BattleEncounterParticles:systems()
  return self._systems
end

-- The published pre-advance systems for drawing, in set order: the exact
-- geometry the last step captured. Absent before the first step, when
-- drawing falls back to the live systems.
---@return BattleEncounterParticleSystem[] published or live systems for drawing
function BattleEncounterParticles:drawSystems()
  if self._drawSystems ~= nil and #self._drawSystems > 0 then
    return self._drawSystems
  end
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

-- Releases one live system from the draw list and its scene manager slot.
---@param index integer position in the live systems
function BattleEncounterParticles:dropSystem(index)
  local system = self._systems[index]
  table.remove(self._systems, index)
  if system ~= nil and system.sceneId ~= nil and self._scene ~= nil then
    self._scene:releaseParticleSystem(system.sceneId)
  end
end

-- Drops every live system and forgets which sets started.
function BattleEncounterParticles:clear()
  for index = #self._systems, 1, -1 do
    self:dropSystem(index)
  end
  self._started = {}
  self._systems = {}
  self._drawSystems = {}
  self._secondStarted = false
end

return BattleEncounterParticles
