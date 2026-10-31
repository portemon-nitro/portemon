-- Owns the retail ball particle effects (src/battle/battle_anim_ball.c): the
-- seal sparkle of a ball send-out (BallSealEffect), the opening ball's burst
-- and the capture click's single emitter (BallBurstEffect). Each started
-- effect is its own particle system placed in screen pixels, started on its
-- retail tick and simulated until its emitters retire. Rendering reads the
-- live systems; nothing here draws.

local SplParticleSimulation = require("libs.hgss.src.presentation.SplParticleSimulation")

---@class BattleBallParticleSystem
---@field simulation SplParticleSimulation live emitter and particle state
---@field textures table<integer, table<string, unknown>> drawable handles by source texture id

---@class BattleBallParticleResolver
---@field particles fun(ballKey: string): table<string, unknown>|nil staged particles of a ball, nil when it has none
---@field texture fun(ballKey: string, kind: "seal"|"burst", textureId: integer): table<string, unknown>|nil drawable handle, nil while staging

---@class BattleBallParticles
---@field _pending { start: table<string, unknown>, age: integer, waited: integer }[] effects waiting for their start tick or textures
---@field _systems BattleBallParticleSystem[] live systems in start order
local BattleBallParticles = {}
BattleBallParticles.__index = BattleBallParticles

-- Particle-space units per screen pixel in the seal and burst position
-- callbacks (172 raw fx32 per pixel).
local RAW_PER_PIXEL = 172
local RAW_ONE = 4096

-- BallThrow_CaptureStateClick fades the ball for two frames, then creates
-- the burst; the emitter starts on the following state step.
local CLICK_START_TICK = 3

-- Ticks past an effect's start tick that its textures may still be staging
-- before the effect is dropped.
local TEXTURE_WAIT_LIMIT = 60

-- sBattleAnimEmitterPositions (kind 0, orthographic) per BATTLER_TYPE_*, in
-- raw fx32, with BallSealEffect_GetBasePosition's pixel offsets.
local SEAL_ORIGINS = {
  [0] = { x = -10240, y = -6400, z = 64, offsetX = 0, offsetY = -16 },
  [1] = { x = 10240, y = 3072, z = -5248, offsetX = -15, offsetY = -25 },
  [2] = { x = -15360, y = -6272, z = 64, offsetX = -8, offsetY = -12 },
  [3] = { x = 13568, y = 2944, z = -5248, offsetX = -14, offsetY = -25 },
  [4] = { x = -7552, y = -6912, z = -1024, offsetX = -8, offsetY = -12 },
  [5] = { x = 6912, y = 4096, z = -7344, offsetX = -16, offsetY = -29 },
}

---@return BattleBallParticles
function BattleBallParticles.new()
  return setmetatable({ _pending = {}, _systems = {} }, BattleBallParticles)
end

-- World position of one effect's emitters before each emitter's own
-- resource position is added.
---@param start table<string, unknown> timeline start
---@return number x, number y, number z
local function origin(start)
  if start.effect == "seal" then
    local base = assert(
      SEAL_ORIGINS[
        start.battlerType --[[@as integer]]
      ],
      "seal effects name a battler type"
    )
    return (base.x - (base.offsetX + 10) * RAW_PER_PIXEL) / RAW_ONE,
      (base.y - (base.offsetY + 32) * RAW_PER_PIXEL) / RAW_ONE,
      base.z / RAW_ONE
  end
  -- BallBurstEffect_SetEmitterPosition
  return (
    start.x --[[@as number]]
    - 129
  )
    * RAW_PER_PIXEL
    / RAW_ONE,
    (
      100 - start.y --[[@as number]]
    )
      * RAW_PER_PIXEL
      / RAW_ONE,
    0
end

---@param start table<string, unknown> timeline start
---@param particles table<string, unknown> staged ball particles
---@return string kind staged set the effect plays
---@return fun(emitterId: integer): boolean included emitters the effect creates
local function plan(start, particles)
  if start.effect == "seal" then
    return "seal", function()
      return true
    end
  end
  local click = particles.clickEmitter
  if start.effect == "click" then
    return "burst", function(emitterId)
      return emitterId == click
    end
  end
  assert(start.effect == "burst", "ball particle effects are seal, burst, or click")
  return "burst", function(emitterId)
    return emitterId ~= click
  end
end

-- Ticks after the cue before the effect creates its emitters.
---@param start table<string, unknown> timeline start
---@param particles table<string, unknown> staged ball particles
---@return integer ticks
local function startTick(start, particles)
  if start.effect == "burst" then
    return particles.burstStartTick --[[@as integer]]
  end
  return start.effect == "click" and CLICK_START_TICK or 0
end

---@param resolver BattleBallParticleResolver
---@param ballKey string
---@param kind "seal"|"burst"
---@param set table<string, unknown> staged particle set
---@return table<integer, table<string, unknown>>|nil textures by id, nil while a texture is staging
local function resolveTextures(resolver, ballKey, kind, set)
  local textures = {}
  for _, texture in
    ipairs(set.textures --[[@as table<string, unknown>[] ]])
  do
    local id = texture.id --[[@as integer]]
    local handle = resolver.texture(ballKey, kind, id)
    if handle == nil then
      return nil
    end
    textures[id] = handle
  end
  return textures
end

---@param start table<string, unknown> timeline start
---@param set table<string, unknown> staged particle set
---@param included fun(emitterId: integer): boolean
---@param textures table<integer, table<string, unknown>>
---@return BattleBallParticleSystem
local function startSystem(start, set, included, textures)
  local x, y, z = origin(start)
  local simulation = SplParticleSimulation.new(set.seed --[[@as integer]], 0)
  for _, record in
    ipairs(set.emitters --[[@as table<string, unknown>[] ]])
  do
    local id = record.id --[[@as integer]]
    if included(id) then
      -- The emitter callbacks add the effect origin to the resource position.
      local position = record.position --[[@as { x: number, y: number, z: number }]]
      local placed = {}
      for key, value in pairs(record) do
        placed[key] = value
      end
      placed.position = { x = position.x + x, y = position.y + y, z = position.z + z }
      SplParticleSimulation.addEmitter(simulation, id, nil, placed)
    end
  end
  return { simulation = simulation, textures = textures }
end

-- Advances one source tick: queued balls warm their textures, new starts
-- wait for their retail tick, due effects create their systems, and every
-- live system simulates. An effect whose ball stages no particles never
-- starts.
---@param starts table<string, unknown>[] effects whose cues started this tick
---@param queuedBalls table<string, boolean> balls with ball particle cues still queued
---@param resolver BattleBallParticleResolver
function BattleBallParticles:step(starts, queuedBalls, resolver)
  for ballKey in pairs(queuedBalls) do
    local particles = resolver.particles(ballKey)
    if particles ~= nil then
      resolveTextures(resolver, ballKey, "seal", particles.seal --[[@as table<string, unknown>]])
      resolveTextures(resolver, ballKey, "burst", particles.burst --[[@as table<string, unknown>]])
    end
  end
  for _, start in ipairs(starts) do
    self._pending[#self._pending + 1] = { start = start, age = 0, waited = 0 }
  end
  for index = #self._pending, 1, -1 do
    local item = self._pending[index]
    local start = item.start
    local ballKey = start.ballKey --[[@as string]]
    local particles = resolver.particles(ballKey)
    local settled = particles == nil
    if particles ~= nil then
      local due = startTick(start, particles)
      if item.age < due then
        item.age = item.age + 1
      else
        local kind, included = plan(start, particles)
        local set = particles[kind] --[[@as table<string, unknown>]]
        local textures = resolveTextures(resolver, ballKey, kind, set)
        if textures ~= nil then
          self._systems[#self._systems + 1] = startSystem(start, set, included, textures)
          settled = true
        else
          item.waited = item.waited + 1
          settled = item.waited > TEXTURE_WAIT_LIMIT
        end
      end
    end
    if settled then
      table.remove(self._pending, index)
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

---@return boolean idle true when no effect waits to start or plays
function BattleBallParticles:isIdle()
  return #self._pending == 0 and #self._systems == 0
end

---@return BattleBallParticleSystem[] live systems for drawing, in start order
function BattleBallParticles:systems()
  return self._systems
end

-- Drops every pending effect and live system.
function BattleBallParticles:clear()
  self._pending = {}
  self._systems = {}
end

return BattleBallParticles
