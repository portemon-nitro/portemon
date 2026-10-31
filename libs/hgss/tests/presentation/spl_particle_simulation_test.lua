-- Replay semantics of the retail SPL particle simulation over hand-built
-- emitter records: placement kinds and their stream draw counts, the random
-- color pick, texture animation, and looping life rates (spl_generate.c,
-- spl_anim.c, spl_emitter.c).

local Assert = require("tests.support.Assert")
local SplParticleSimulation = require("libs.hgss.src.presentation.SplParticleSimulation")

local T = { metadata = { capabilities = {} }, tests = {} }

local RADIUS = 2
local EPSILON = 1e-9

-- Independent copy of the retail congruential step with exact 16-bit limbs.
---@param seed integer
---@return integer
local function nextSeed(seed)
  local multiplier, increment = 0x5EEDF715, 0x1B0CB173
  local seedLo, seedHi = seed % 65536, math.floor(seed / 65536)
  local multLo, multHi = multiplier % 65536, math.floor(multiplier / 65536)
  local low = seedLo * multLo
  local mid = (seedLo * multHi + seedHi * multLo) % 65536
  return (low + mid * 65536 + increment) % 4294967296
end

---@param overrides table<string, unknown>|nil
---@return table<string, unknown>
local function record(overrides)
  local base = {
    id = 0,
    emitterLife = 1,
    particleLife = 100,
    startOffset = 0,
    generation = { countFx = 4096, interval = 1 },
    initPosType = 0,
    circleAxis = 0,
    drawType = 0,
    radius = RADIUS,
    length = 0,
    position = { x = 0, y = 0, z = 0 },
    axis = { x = 0, y = 0, z = 0 },
    baseColorRgb = { r = 0, g = 31, b = 0 },
    baseAlpha = 31,
    baseScaleFx = 4096,
    velocityFx = { pos = 0, axis = 0 },
    velRandom = 0,
    scaleRandom = 0,
    lifeRandom = 0,
    rotation = { min = 0, max = 0 },
    useRotationAnim = false,
    useInitRotationRandom = false,
    initRotation = 0,
    airResist = 0,
    aspect = 1,
    loopFrame = 10,
    texture = 3,
    animations = {},
    fields = {},
  }
  for key, value in pairs(overrides or {}) do
    base[key] = value
  end
  return base
end

-- Spawns `count` particles in one burst and returns the sim and its emitter.
---@param overrides table<string, unknown>
---@param count integer
---@return SplParticleSimulation sim
---@return table<string, unknown> runtime
local function spawnBurst(overrides, count)
  overrides.generation = { countFx = count * 4096, interval = 1 }
  local sim = SplParticleSimulation.new(0, 0)
  SplParticleSimulation.addEmitter(sim, 0, nil, record(overrides))
  SplParticleSimulation.advance(sim)
  return sim, sim.emitters[1]
end

---@param particle table<string, unknown>
---@return number
local function distance(particle)
  return math.sqrt(particle.x ^ 2 + particle.y ^ 2 + particle.z ^ 2)
end

function T.tests.evenly_spaced_circle_places_the_burst_at_equal_angles()
  local _, runtime = spawnBurst({ initPosType = 3 }, 4)
  Assert.equal(#runtime.particles, 4, "the burst spawns every particle")
  -- Axis z frame: the first particle sits at angle zero, then quarter turns.
  local expected = { { 0, -RADIUS }, { -RADIUS, 0 }, { 0, RADIUS }, { RADIUS, 0 } }
  for index, point in ipairs(expected) do
    local particle = runtime.particles[index]
    Assert.isTrue(math.abs(particle.x - point[1]) < 1e-6, "particle " .. index .. " keeps its x angle step")
    Assert.isTrue(math.abs(particle.y - point[2]) < 1e-6, "particle " .. index .. " keeps its y angle step")
    Assert.isTrue(math.abs(particle.z) < EPSILON, "the circle stays in its plane")
  end
end

function T.tests.sphere_and_volume_placements_stay_inside_their_shapes()
  local _, surface = spawnBurst({ initPosType = 1 }, 20)
  for _, particle in ipairs(surface.particles) do
    Assert.isTrue(math.abs(distance(particle) - RADIUS) < 1e-6, "sphere surface particles sit on the radius")
  end
  local _, volume = spawnBurst({ initPosType = 4 }, 20)
  for _, particle in ipairs(volume.particles) do
    Assert.isTrue(distance(particle) <= RADIUS * math.sqrt(3) + 1e-6, "sphere volume stays inside the bounding radius")
  end
  local _, disc = spawnBurst({ initPosType = 5 }, 20)
  for _, particle in ipairs(disc.particles) do
    Assert.isTrue(math.abs(particle.z) < EPSILON, "disc particles stay in the emitter plane")
  end
end

function T.tests.hemisphere_placements_stay_on_the_axis_side()
  local _, surface = spawnBurst({ initPosType = 8 }, 20)
  for _, particle in ipairs(surface.particles) do
    Assert.isTrue(particle.z >= 0, "hemisphere surface particles keep the axis side")
    Assert.isTrue(math.abs(distance(particle) - RADIUS) < 1e-6, "hemisphere surface particles sit on the radius")
  end
  local _, volume = spawnBurst({ initPosType = 9 }, 20)
  for _, particle in ipairs(volume.particles) do
    Assert.isTrue(particle.z >= 0, "hemisphere volume particles keep the axis side")
    Assert.isTrue(distance(particle) <= RADIUS + 1e-6, "hemisphere volume particles stay inside the radius")
  end
end

function T.tests.each_placement_kind_draws_its_source_stream_count()
  -- Placement draws, plus the shared draws: two velocities, the base scale,
  -- and the life. Zero-position kinds add the random outward direction.
  local placementDraws = { [0] = 3, [1] = 3, [2] = 2, [3] = 0, [4] = 6, [5] = 4, [6] = 3, [7] = 5, [8] = 3, [9] = 6 }
  local sharedDraws = 4
  for placement = 0, 9 do
    local sim = spawnBurst({ initPosType = placement, length = 1 }, 1)
    local seed = 0
    for _ = 1, placementDraws[placement] + sharedDraws do
      seed = nextSeed(seed)
    end
    Assert.equal(sim.rng, seed, "placement " .. placement .. " consumes its source draw count")
  end
end

function T.tests.random_color_pick_chooses_among_start_base_and_end()
  local color = {
    startRgb = { r = 31, g = 0, b = 0 },
    endRgb = { r = 0, g = 0, b = 31 },
    inTick = 10,
    peakTick = 100,
    outTick = 200,
    interpolate = false,
    random = true,
  }
  local sim, runtime = spawnBurst({ animations = { color = color } }, 30)
  local seen = {}
  for _, particle in ipairs(runtime.particles) do
    local rgb = particle.colorRgb
    seen[rgb.r * 10000 + rgb.g * 100 + rgb.b] = true
  end
  Assert.isTrue(seen[310000], "the start color is picked")
  Assert.isTrue(seen[3100], "the base color is picked")
  Assert.isTrue(seen[31], "the end color is picked")
  local plain = spawnBurst({ animations = {} }, 30)
  Assert.isTrue(sim.rng ~= plain.rng, "the pick draws from the stream once per particle")
  for _ = 1, 20 do
    SplParticleSimulation.advance(sim)
  end
  for _, particle in ipairs(runtime.particles) do
    local rgb = particle.colorRgb
    Assert.isTrue(seen[rgb.r * 10000 + rgb.g * 100 + rgb.b], "a picked color is not animated afterwards")
  end
end

-- Runs one particle born on the first tick through `ticks` ticks.
---@param overrides table<string, unknown>
---@param ticks integer
---@return table<string, unknown> particle
local function ageOne(overrides, ticks)
  local sim = SplParticleSimulation.new(0, 0)
  SplParticleSimulation.addEmitter(sim, 0, nil, record(overrides))
  for _ = 1, ticks do
    SplParticleSimulation.advance(sim)
  end
  return sim.emitters[1].particles[1]
end

function T.tests.texture_animation_steps_through_textures_by_life_rate()
  local anim = { textures = { 5, 6, 7 }, diff = 85, random = false, loop = false }
  Assert.equal(ageOne({ textureAnim = anim }, 1).texNo, 5, "a newborn shows the first texture")
  -- Life 100: the byte life rate is 102 at age 40, inside the second stage.
  Assert.equal(ageOne({ textureAnim = anim }, 41).texNo, 6, "the second stage shows the second texture")
  Assert.equal(ageOne({ textureAnim = anim }, 81).texNo, 7, "the third stage shows the third texture")
  Assert.equal(ageOne({}, 1).texNo, 3, "an emitter without a texture animation keeps its texture")
end

function T.tests.random_texture_pick_is_drawn_once_at_spawn()
  local anim = { textures = { 5, 6, 7 }, diff = 85, random = true, loop = false }
  local sim, runtime = spawnBurst({ textureAnim = anim }, 30)
  local seen = {}
  for _, particle in ipairs(runtime.particles) do
    seen[particle.texNo] = true
  end
  Assert.isTrue(seen[5] and seen[6] and seen[7], "every animation texture is picked")
  local before = {}
  for index, particle in ipairs(runtime.particles) do
    before[index] = particle.texNo
  end
  for _ = 1, 50 do
    SplParticleSimulation.advance(sim)
  end
  for index, particle in ipairs(runtime.particles) do
    Assert.equal(particle.texNo, before[index], "a randomly picked texture never changes")
  end
end

function T.tests.looping_blocks_run_on_the_loop_frame_life_rate()
  local scale = { startFx = 0, normalFx = 4096, finishFx = 4096, inTick = 200, outTick = 255 }
  local alpha = { start = 0, normal = 31, finish = 31, flick = 0, inTick = 200, outTick = 255 }
  local anim = { textures = { 5, 6, 7 }, diff = 85, random = false }
  local plain = ageOne({ animations = { scale = scale, alpha = alpha }, textureAnim = anim }, 6)
  scale = { startFx = 0, normalFx = 4096, finishFx = 4096, inTick = 200, outTick = 255, loop = true }
  alpha = { start = 0, normal = 31, finish = 31, flick = 0, inTick = 200, outTick = 255, loop = true }
  anim = { textures = { 5, 6, 7 }, diff = 85, random = false, loop = true }
  local looping = ageOne({ animations = { scale = scale, alpha = alpha }, textureAnim = anim }, 6)
  -- Age 5: the life rate is 12 over the life and 127 over the 10-frame loop.
  Assert.equal(plain.animScale, math.floor(4096 * 12 / 200), "the plain scale follows the life rate")
  Assert.equal(looping.animScale, math.floor(4096 * 127 / 200), "the looping scale follows the loop rate")
  Assert.equal(
    plain.animAlpha,
    math.floor(math.floor(12 * 31 / 200) * 255 / 256),
    "the plain alpha follows the life rate"
  )
  Assert.equal(
    looping.animAlpha,
    math.floor(math.floor(127 * 31 / 200) * 255 / 256),
    "the looping alpha follows the loop rate"
  )
  Assert.equal(plain.texNo, 5, "the plain texture animation stays in its first stage")
  Assert.equal(looping.texNo, 6, "the looping texture animation reaches its second stage")
end

return T
