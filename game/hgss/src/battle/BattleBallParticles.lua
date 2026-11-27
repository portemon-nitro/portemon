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
---@field textureAlphaUsage table<integer, table<string, unknown>>? compiled transparency classification by source texture id
---@field sceneId unknown? scene manager slot identity, nil while unallocated

---@class BattleBallParticleResolver
---@field particles fun(ballKey: string): table<string, unknown>|nil staged particles of a ball, nil when it has none
---@field has (fun(ballKey: string): boolean|nil)? entry probe, false when the ball stages no particles by contract, nil while its entry is unstaged
---@field texture fun(ballKey: string, kind: "seal"|"burst"|"genericBurst", textureId: integer): table<string, unknown>|nil drawable handle, nil while staging

---@class BattleBallParticles
---@field _pending { start: table<string, unknown>, age: integer, waited: integer }[] effects waiting for their start tick or textures
---@field _failed { start: table<string, unknown>, reason: string }[] required effects lost to staging failure, in failure order
---@field _systems BattleBallParticleSystem[] live systems in start order
---@field _drawSystems BattleBallParticleSystem[] last published pre-advance systems for drawing
---@field _splRandomState table<string, integer> borrowed boot stream record shared by one boot
---@field _scene table<string, unknown>? scene manager-slot owner for first-free physical allocation
local BattleBallParticles = {}
BattleBallParticles.__index = BattleBallParticles

-- Particle-space units per screen pixel in the seal and burst position
-- callbacks (172 raw fx32 per pixel).
local RAW_PER_PIXEL = 172
local RAW_ONE = 4096

-- CaptureStateClick creates its burst once the darken completes and
-- starts it on the following state step: the timeline pushes the click
-- start after the darken cue, so the particle system only bridges one
-- handoff tick.
local CLICK_START_TICK = 1
-- BallThrow_OpenInPlace creates the generic burst at step 2 and starts
-- it at step 3: five ticks after the open starts.
local GENERIC_BURST_START_TICK = 5

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

---@param opts { splRandomState: table<string, integer>, scene: table<string, unknown>? } borrowed boot stream record and scene manager-slot owner
---@return BattleBallParticles
function BattleBallParticles.new(opts)
  opts = opts or {}
  assert(type(opts.splRandomState) == "table", "ball particles borrow the boot stream record")
  return setmetatable({
    _pending = {},
    _failed = {},
    _systems = {},
    _drawSystems = {},
    _splRandomState = opts.splRandomState,
    _scene = opts.scene,
  }, BattleBallParticles)
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
---@return string? kind staged set the effect plays, nil when the required set is missing
---@return (fun(emitterId: integer): boolean)? included emitters the effect creates
---@return string? missing-set reason when the required set is missing
local function plan(start, particles)
  if start.effect == "seal" then
    if particles.seal == nil then
      return nil, nil, "missing-seal-set"
    end
    return "seal", function()
      return true
    end
  end
  -- The breakout's mode-1 open plays the generic burst (virtual ball
  -- 1027, NARC_a_0_9_5 member 52): all of its emitters, never the
  -- attempted ball's catch-opening burst and never the seal.
  if start.effect == "generic-burst" then
    if particles.genericBurst == nil then
      return nil, nil, "missing-generic-set"
    end
    return "genericBurst", function()
      return true
    end
  end
  if start.effect == "click" then
    if particles.burst == nil then
      return nil, nil, "missing-burst-set"
    end
    local click = particles.clickEmitter
    return "burst", function(emitterId)
      return emitterId == click
    end
  end
  if start.effect ~= "burst" then
    return nil, nil, "unknown-effect"
  end
  if particles.burst == nil then
    return nil, nil, "missing-burst-set"
  end
  local skipped = particles.clickEmitter
  return "burst", function(emitterId)
    return emitterId ~= skipped
  end
end

-- Ticks after the cue before the effect creates its emitters: the
-- staged source tick of the selected effect.
---@param start table<string, unknown> timeline start
---@param particles table<string, unknown> staged ball particles
---@return integer ticks
local function startTick(start, particles)
  if start.effect == "burst" then
    return particles.burstStartTick --[[@as integer]]
  end
  if start.effect == "generic-burst" then
    return GENERIC_BURST_START_TICK
  end
  return start.effect == "click" and CLICK_START_TICK or 0
end

---@param resolver BattleBallParticleResolver
---@param ballKey string
---@param kind "seal"|"burst"|"genericBurst"
---@param set table<string, unknown> staged particle set
---@return table<integer, table<string, unknown>>|nil textures by id, nil while a texture is staging
---@return table<integer, table<string, unknown>>? transparency classification by id
local function resolveTextures(resolver, ballKey, kind, set)
  local textures = {}
  local textureAlphaUsage = {}
  for _, texture in
    ipairs(set.textures --[[@as table<string, unknown>[] ]])
  do
    local id = texture.id --[[@as integer]]
    local handle = resolver.texture(ballKey, kind, id)
    if handle == nil then
      return nil
    end
    textures[id] = handle
    -- The staged set carries the decoder's exact coverage flags:
    -- translucent texels must not harden into the cutout/opaque
    -- classification downstream. The manifest contract requires them on
    -- every staged particle texture.
    textureAlphaUsage[id] = assert(texture.alphaUsage, "ball particle textures stage their alpha usage")
  end
  return textures, textureAlphaUsage
end

---@param start table<string, unknown> timeline start
---@param set table<string, unknown> staged particle set
---@param included fun(emitterId: integer): boolean
---@param textures table<integer, table<string, unknown>>
---@param textureAlphaUsage table<integer, table<string, unknown>>? transparency classification by id
---@param splRandomState table<string, integer> borrowed boot stream record shared by one boot
---@return BattleBallParticleSystem
local function startSystem(start, set, included, textures, textureAlphaUsage, splRandomState)
  local x, y, z = origin(start)
  local randomState = assert(splRandomState, "ball particles borrow their boot stream record")
  local simulation = SplParticleSimulation.new(randomState, 0, set.emitters)
  -- The seal, burst, and click effects all select the orthographic
  -- camera (battle_anim_ball.c): particle size never depends on
  -- perspective depth on this path.
  simulation.camera.perspective = 1
  for ordinal, record in
    ipairs(set.emitters --[[@as table<string, unknown>[] ]])
  do
    local id = record.id --[[@as integer]]
    if included(id) then
      -- The emitter callbacks add the effect origin to the resource base
      -- through the runtime position; the shared resource clone keeps its
      -- immutable base for later emitters of the same ordinal.
      local runtime = SplParticleSimulation.addEmitter(simulation, ordinal - 1, nil)
      if runtime ~= nil then
        local position = record.position --[[@as { x: number, y: number, z: number }]]
        runtime.x = position.x + x
        runtime.y = position.y + y
        runtime.z = position.z + z
      end
    end
  end
  return { simulation = simulation, textures = textures, textureAlphaUsage = textureAlphaUsage }
end

-- Advances one source tick: queued balls warm their textures, new starts
-- wait for their retail tick, due effects create their systems, and every
-- live system simulates. Pending starts distinguish warming, running,
-- and failed: a ball the resolver never stages fails loudly after the
-- wait limit instead of vanishing like a completed effect, while a ball
-- whose entry exists but stages no particles keeps its valid no-effect
-- semantics. Failures accumulate on failures(), never on the idle path.
---@param starts table<string, unknown>[] effects whose cues started this tick
---@param queuedBalls table<string, boolean> balls with ball particle cues still queued
---@param resolver BattleBallParticleResolver
function BattleBallParticles:step(starts, queuedBalls, resolver)
  for ballKey in pairs(queuedBalls) do
    local particles = resolver.particles(ballKey)
    if particles ~= nil then
      resolveTextures(resolver, ballKey, "seal", particles.seal --[[@as table<string, unknown>]])
      resolveTextures(resolver, ballKey, "burst", particles.burst --[[@as table<string, unknown>]])
      if particles.genericBurst ~= nil then
        resolveTextures(resolver, ballKey, "genericBurst", particles.genericBurst --[[@as table<string, unknown>]])
      end
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
    local settled = false
    if particles == nil then
      -- Balls the resolver affirmatively stages without particles keep
      -- no-effect semantics; anywhere else a missing record past the
      -- limit is a staging failure, never a silent completion.
      local staged = nil
      if resolver.has ~= nil then
        staged = resolver.has(ballKey)
      end
      if staged == false then
        settled = true
      else
        item.waited = item.waited + 1
        if item.waited > TEXTURE_WAIT_LIMIT then
          self._failed[#self._failed + 1] = { start = start, reason = "missing-particles" }
          settled = true
        end
      end
    else
      local due = startTick(start, particles)
      if item.age < due then
        item.age = item.age + 1
      else
        local kind, included, planErr = plan(start, particles)
        if kind == nil then
          assert(type(planErr) == "string", "unplannable effects name their missing set")
          self._failed[#self._failed + 1] = { start = start, reason = planErr }
          settled = true
        else
          assert(type(included) == "function", "planned effects name their emitters")
          local set = particles[kind] --[[@as table<string, unknown>]]
          local textures, textureAlphaUsage = resolveTextures(resolver, ballKey, kind, set)
          if textures ~= nil then
            local system = startSystem(start, set, included, textures, textureAlphaUsage, self._splRandomState)
            if self._scene ~= nil and type(self._scene.allocParticleSystem) == "function" then
              system.sceneId = self._scene:allocParticleSystem(system)
            end
            self._systems[#self._systems + 1] = system
            settled = true
          else
            item.waited = item.waited + 1
            if item.waited > TEXTURE_WAIT_LIMIT then
              self._failed[#self._failed + 1] = { start = start, reason = "missing-textures" }
              settled = true
            end
          end
        end
      end
    end
    if settled then
      table.remove(self._pending, index)
    end
  end
  -- Publish the pre-advance frame for drawing before the simulation
  -- tick: the compositor paints this immutable geometry while the live
  -- systems advance underneath. Retired systems leave the live list but
  -- stay visible through this frame.
  local published = {}
  for _, system in ipairs(self._systems) do
    published[#published + 1] = {
      simulation = SplParticleSimulation.copyForDraw(system.simulation),
      textures = system.textures,
      textureAlphaUsage = system.textureAlphaUsage,
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

---@return boolean idle true when no effect waits to start or plays
function BattleBallParticles:isIdle()
  return #self._pending == 0 and #self._systems == 0
end

---@return BattleBallParticleSystem[] live systems in start order
function BattleBallParticles:systems()
  return self._systems
end

-- Required effects lost to staging failure, in failure order: a missing
-- particle record or missing textures past the wait limit. The owning
-- screen surfaces these through its diagnostic path; the queue already
-- drained, so the idle probe never reports a discarded effect as
-- completed work.
---@return { start: table<string, unknown>, reason: string }[] staging failures
function BattleBallParticles:failures()
  return self._failed
end

-- The published pre-advance systems for drawing, in start order: the exact
-- geometry the last step captured. Absent before the first step, when
-- drawing falls back to the live systems.
---@return BattleBallParticleSystem[] published or live systems for drawing
function BattleBallParticles:drawSystems()
  if self._drawSystems ~= nil and #self._drawSystems > 0 then
    return self._drawSystems
  end
  return self._systems
end

-- Releases one live system from the draw list and its scene manager slot.
---@param index integer position in the live systems
function BattleBallParticles:dropSystem(index)
  local system = self._systems[index]
  table.remove(self._systems, index)
  if system ~= nil and system.sceneId ~= nil and self._scene ~= nil then
    self._scene:releaseParticleSystem(system.sceneId)
  end
end

-- Drops every pending effect and live system. Pending starts retire as
-- cancelled: exactly-once scene-slot release still owns every system,
-- while the recorded failures persist for the diagnostic path.
function BattleBallParticles:clear()
  for index = #self._systems, 1, -1 do
    self:dropSystem(index)
  end
  self._cancelled = (self._cancelled or 0) + #self._pending
  self._pending = {}
  self._systems = {}
  self._drawSystems = {}
end

---@return integer pending starts dropped by cancellation
function BattleBallParticles:cancelled()
  return self._cancelled or 0
end

return BattleBallParticles
