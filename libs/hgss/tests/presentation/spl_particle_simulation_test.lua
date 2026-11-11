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
  local sim = SplParticleSimulation.new({ state = 0 }, 0, { record(overrides) })
  SplParticleSimulation.addEmitter(sim, 0, nil)
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
  local sim = SplParticleSimulation.new({ state = 0 }, 0, { record(overrides) })
  SplParticleSimulation.addEmitter(sim, 0, nil)
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

-- spl_generate.c spawns children with rotation type 0 (none), 1 (the parent
-- angle), or 2 (the parent angle and spin); children then turn by their own
-- spin each tick like every particle.
function T.tests.children_inherit_the_parent_rotation_by_their_rotation_type()
  local function childRotation(rotationType)
    local _, runtime = spawnBurst({
      initRotation = 1000,
      useRotationAnim = true,
      rotation = { min = 500, max = 500 },
      child = {
        rotationType = rotationType,
        useScaleAnm = false,
        useAlphaAnm = false,
        followEmitter = false,
        useChildColor = false,
        childColor = { r = 0, g = 0, b = 0 },
        initVelRandom = 0,
        scaleEnd = 0,
        life = 5,
        velRatio = 0,
        sclRatio = 63,
        genNum = 1,
        genStart = 0,
        genInterval = 1,
        texNo = 1,
        texRepeat = { s = 0, t = 0 },
      },
    }, 1)
    Assert.equal(#runtime.particles, 1, "the parent spawns")
    Assert.equal(#runtime.children, 1, "the parent spawns its child on its birth tick")
    return runtime.children[1]
  end
  Assert.equal(childRotation(nil).rtt, 0, "a child without rotation type starts unrotated")
  Assert.equal(childRotation(1).rtt, 1500, "type 1 copies the parent angle without its spin")
  Assert.equal(childRotation(2).rtt, 2000, "type 2 also keeps turning by the parent spin")
end

function T.tests.emitter_axis_circle_axis_orients_the_circle_across_the_emitter_axis()
  -- Circle axis 3 takes the emitter's own axis: an x axis puts the ring in
  -- the y/z plane, an axis tilted off +y keeps the ring perpendicular to it.
  local _, onX = spawnBurst({ initPosType = 3, circleAxis = 3, axis = { x = 2, y = 0, z = 0 } }, 8)
  for _, particle in ipairs(onX.particles) do
    Assert.isTrue(math.abs(particle.x) < EPSILON, "a ring about the x axis stays in the y/z plane")
    Assert.isTrue(math.abs(distance(particle) - RADIUS) < 1e-6, "the ring keeps its radius")
  end
  local tilt = { x = 0, y = 0.99, z = 0.15 }
  local length = math.sqrt(tilt.x ^ 2 + tilt.y ^ 2 + tilt.z ^ 2)
  local _, tilted = spawnBurst({ initPosType = 3, circleAxis = 3, axis = tilt }, 8)
  for _, particle in ipairs(tilted.particles) do
    local along = (particle.x * tilt.x + particle.y * tilt.y + particle.z * tilt.z) / length
    Assert.isTrue(math.abs(along) < 1e-6, "a tilted-axis ring stays perpendicular to its axis")
  end
end

function T.tests.convergence_field_pulls_the_position_toward_its_target_by_the_ratio()
  local field = { kind = "convergence", position = { x = 4, y = -4, z = 0 }, ratio = 2048 }
  local particle = ageOne({ initPosType = 0, fields = { field } }, 1)
  -- Born at the origin with no velocity: half the distance to the target.
  Assert.near(particle.x, 2, EPSILON, "x closes half the gap")
  Assert.near(particle.y, -2, EPSILON, "y closes half the gap")
  Assert.near(particle.z, 0, EPSILON, "z stays on its target plane")
  local again = ageOne({ initPosType = 0, fields = { field } }, 2)
  Assert.near(again.x, 3, EPSILON, "the next tick closes half the remaining gap")
end

function T.tests.following_emitters_carry_their_particles_with_the_emitter()
  local function worldXAfterMove(follow)
    local sim = SplParticleSimulation.new({ state = 0 }, 0, { record({ followEmitter = follow, emitterLife = 5 }) })
    SplParticleSimulation.addEmitter(sim, 0, nil)
    SplParticleSimulation.advance(sim)
    sim.emitters[1].x = 3
    SplParticleSimulation.advance(sim)
    local particle = sim.emitters[1].particles[1]
    return particle.x + particle.ex
  end
  Assert.near(worldXAfterMove(true), 3, EPSILON, "a following particle tracks the moved emitter")
  Assert.near(worldXAfterMove(nil), 0, EPSILON, "a plain particle keeps its birth emitter position")
end

function T.tests.persistent_emitters_outlive_their_life_until_removed_with_their_particles()
  local sim = SplParticleSimulation.new({ state = 0 }, 0, { record({ persistent = true, particleLife = 2 }) })
  local runtime = SplParticleSimulation.addEmitter(sim, 0, nil)
  for _ = 1, 10 do
    SplParticleSimulation.advance(sim)
  end
  Assert.equal(#sim.emitters, 1, "a persistent emitter outlives its life and its last particle")
  Assert.equal(#runtime.particles, 0, "its particles still retire on their own life")
  local plain = SplParticleSimulation.new({ state = 0 }, 0, { record({ particleLife = 2 }) })
  SplParticleSimulation.addEmitter(plain, 0, nil)
  for _ = 1, 10 do
    SplParticleSimulation.advance(plain)
  end
  Assert.equal(#plain.emitters, 0, "a self-destroying emitter leaves once its particles retire")
  local held = SplParticleSimulation.new({ state = 0 }, 0, { record({ persistent = true }) })
  local owned = SplParticleSimulation.addEmitter(held, 0, nil)
  SplParticleSimulation.advance(held)
  Assert.equal(#owned.particles, 1, "the emitter holds a live particle")
  SplParticleSimulation.removeEmitter(held, owned)
  SplParticleSimulation.removeEmitter(held, owned)
  Assert.equal(#held.emitters, 0, "removal drops the emitter and its particles at once, and repeats silently")
end

-- One boot owns one stream: every manager borrows the same record, draws
-- consume it in source call order, and no manager reseeds or keeps a
-- private stream. Sibling state below is independent today.
function T.tests.sibling_managers_share_one_boot_stream()
  local boot = { state = 0 }
  local first = SplParticleSimulation.new(boot, 0, { record({}) })
  SplParticleSimulation.addEmitter(first, 0, nil)
  SplParticleSimulation.advance(first)
  local second = SplParticleSimulation.new(boot, 0, { record({}) })
  SplParticleSimulation.addEmitter(second, 0, nil)
  SplParticleSimulation.advance(second)
  Assert.isTrue(
    second.rng ~= first.rng,
    "a second manager continues the boot stream where the first left off "
      .. "instead of replaying the same draws from zero"
  )
end

function T.tests.simulations_borrow_their_boot_stream_record()
  local boot = { state = 0 }
  local ok, sim = pcall(SplParticleSimulation.new, boot, 0, {})
  Assert.isTrue(
    ok,
    "simulations borrow one boot stream record instead of a numeric seed: " .. tostring(sim)
  )
  if ok then
    Assert.isTrue(
      sim.randomState == boot,
      "draws advance the borrowed boot record the whole boot shares"
    )
  end
end

function T.tests.zero_life_emitters_generate_without_a_duration_cap()
  local sim = SplParticleSimulation.new({ state = 0 }, 0, { record({ emitterLife = 0, particleLife = 2 }) })
  local runtime = SplParticleSimulation.addEmitter(sim, 0, nil)
  for _ = 1, 6 do
    SplParticleSimulation.advance(sim)
  end
  Assert.equal(#sim.emitters, 1, "a zero-life emitter never expires on its own")
  Assert.isTrue(#runtime.particles > 0, "it keeps generating until explicitly stopped or deleted")
end

function T.tests.simultaneous_emitters_are_capped_at_twenty_without_random_draws()
  local boot = { state = 0 }
  local sim = SplParticleSimulation.new(boot, 0, { record({ persistent = true, emitterLife = 0 }) })
  for _ = 1, 20 do
    Assert.notNil(SplParticleSimulation.addEmitter(sim, 0, nil), "the first twenty emitters allocate")
  end
  local before = boot.state
  Assert.isNil(SplParticleSimulation.addEmitter(sim, 0, nil), "the twenty-first emitter drops")
  Assert.equal(boot.state, before, "exhausted emitter allocation consumes no random draws")
  Assert.equal(#sim.emitters, 20, "only twenty emitters stay live")
end

function T.tests.a_full_particle_pool_generates_nothing_and_draws_nothing()
  local boot = { state = 0 }
  local sim = SplParticleSimulation.new(
    boot,
    0,
    { record({ persistent = true, emitterLife = 0, particleLife = 10000, generation = { countFx = 10 * 4096, interval = 1 } }) }
  )
  for _ = 1, 20 do
    SplParticleSimulation.addEmitter(sim, 0, nil)
  end
  -- Twenty emitters generating ten per tick fill the shared 200 nodes.
  -- Generation rides the per-emitter runtime copy taken at creation, so
  -- the burst rate is staged in the initial record, not poked later.
  SplParticleSimulation.advance(sim)
  local live = 0
  for _, runtime in ipairs(sim.emitters) do
    live = live + #runtime.particles
  end
  Assert.equal(live, 200, "the shared pool holds two hundred particles")
  local before = boot.state
  SplParticleSimulation.advance(sim)
  Assert.equal(boot.state, before, "a full pool consumes no random draws on generation")
end

function T.tests.retained_placements_keep_the_recycled_node_position()
  local function retainedRecord(velocity)
    return record({
      persistent = true,
      emitterLife = 0,
      particleLife = 3,
      initPosType = 12,
      velocityFx = { pos = velocity, axis = 0 },
      generation = { countFx = 4096, interval = 100 },
    })
  end
  -- A first-use retained node starts at the zeroed origin: with no
  -- velocity the newborn never moves away from it on its birth tick.
  local still = SplParticleSimulation.new({ state = 0 }, 0, { retainedRecord(0) })
  local idle = SplParticleSimulation.addEmitter(still, 0, nil)
  SplParticleSimulation.advance(still)
  local newborn = idle.particles[1]
  Assert.isTrue(
    math.abs(newborn.x) < EPSILON and math.abs(newborn.y) < EPSILON and math.abs(newborn.z) < EPSILON,
    "a first-use retained node starts at the zeroed origin"
  )
  local boot = { state = 0 }
  local sim = SplParticleSimulation.new(boot, 0, { retainedRecord(4096) })
  local runtime = SplParticleSimulation.addEmitter(sim, 0, nil)
  SplParticleSimulation.advance(sim)
  for _ = 1, 2 do
    SplParticleSimulation.advance(sim)
  end
  local last = runtime.particles[1]
  Assert.notNil(last, "the particle still lives on its third tick")
  Assert.isTrue(
    math.sqrt(last.x ^ 2 + last.y ^ 2 + last.z ^ 2) > 1,
    "the live particle moved away from the origin"
  )
  for _ = 1, 2 do
    SplParticleSimulation.advance(sim)
  end
  Assert.equal(#runtime.particles, 0, "the short-lived particle retires")
  SplParticleSimulation.removeEmitter(sim, runtime)
  local again = SplParticleSimulation.addEmitter(sim, 0, nil)
  SplParticleSimulation.advance(sim)
  local second = again.particles[1]
  local moved = math.sqrt(second.x ^ 2 + second.y ^ 2 + second.z ^ 2)
  Assert.isTrue(moved > 0.5, "a recycled retained node keeps its prior local position instead of zeroing")
end

function T.tests.retained_placements_draw_no_placement_random_values()
  for placement = 10, 15 do
    local sim = spawnBurst({ initPosType = placement, length = 1 }, 1)
    local seed = 0
    -- First-use nodes sit at the origin, so the outward direction draws
    -- three values exactly like the point kind, then the shared four.
    for _ = 1, 7 do
      seed = nextSeed(seed)
    end
    Assert.equal(sim.rng, seed, "retained placement " .. placement .. " draws its source count on first use")
  end
end

function T.tests.child_rotation_three_retains_the_recycled_node_pair()
  local function childRecord(rotationType, life)
    return record({
      persistent = true,
      emitterLife = 0,
      particleLife = 2,
      initRotation = 1000,
      useRotationAnim = true,
      rotation = { min = 500, max = 500 },
      generation = { countFx = 4096, interval = 100 },
      child = {
        rotationType = rotationType,
        useScaleAnm = false,
        useAlphaAnm = false,
        followEmitter = false,
        useChildColor = true,
        childColor = { r = 0, g = 0, b = 0 },
        initVelRandom = 0,
        scaleEnd = 1,
        life = life,
        velRatio = 0,
        sclRatio = 63,
        genNum = 1,
        genStart = 0,
        genInterval = 1,
        texNo = 1,
        texRepeat = { s = 0, t = 0 },
      },
    })
  end
  local boot = { state = 0 }
  local sim = SplParticleSimulation.new(boot, 0, { childRecord(2, 2), childRecord(3, 50) })
  local first = SplParticleSimulation.addEmitter(sim, 0, nil)
  SplParticleSimulation.advance(sim)
  Assert.equal(#first.children, 1, "the rotating parent spawns its child")
  for _ = 1, 5 do
    SplParticleSimulation.advance(sim)
  end
  Assert.equal(#first.particles + #first.children, 0, "the short-lived family retires")
  SplParticleSimulation.removeEmitter(sim, first)
  local second = SplParticleSimulation.addEmitter(sim, 1, nil)
  SplParticleSimulation.advance(sim)
  local child = second.children[1]
  Assert.notNil(child, "the rotation-three parent spawns its child")
  Assert.isTrue(child.rtt ~= 0, "rotation kind 3 retains the recycled node angle instead of zeroing")
  Assert.equal(child.rttVel, 500, "rotation kind 3 retains the recycled node spin")
end

function T.tests.random_fields_fire_on_their_interval_with_three_draws()
  local field = { kind = "random", magnitude = { x = 0, y = 0, z = 0 }, interval = 1 }
  local boot = { state = 0 }
  local sim = SplParticleSimulation.new(
    boot,
    0,
    { record({ persistent = true, emitterLife = 0, particleLife = 100, fields = { field }, generation = { countFx = 4096, interval = 100 } }) }
  )
  local runtime = SplParticleSimulation.addEmitter(sim, 0, nil)
  SplParticleSimulation.advance(sim)
  Assert.equal(#runtime.particles, 1, "the emitter spawns")
  -- Spawn tick: three placement draws plus the shared four, then the
  -- birth-tick update fires the newborn field for three more.
  local expected = 0
  for _ = 1, 10 do
    expected = nextSeed(expected)
  end
  Assert.equal(sim.rng, expected, "the spawn tick draws its source count")
  for _ = 1, 3 do
    expected = nextSeed(expected)
  end
  SplParticleSimulation.advance(sim)
  Assert.equal(sim.rng, expected, "a zero-magnitude random field still draws three values per update")
end

function T.tests.random_fields_skip_off_interval_ticks_without_draws()
  local field = { kind = "random", magnitude = { x = 1, y = 1, z = 1 }, interval = 2 }
  local boot = { state = 0 }
  local sim = SplParticleSimulation.new(
    boot,
    0,
    { record({ persistent = true, emitterLife = 0, particleLife = 100, fields = { field }, generation = { countFx = 4096, interval = 100 } }) }
  )
  SplParticleSimulation.addEmitter(sim, 0, nil)
  SplParticleSimulation.advance(sim)
  -- Birth tick: the newborn age 0 fires on its interval; the next tick
  -- age 1 skips and draws nothing.
  local before = boot.state
  SplParticleSimulation.advance(sim)
  Assert.equal(boot.state, before, "a skipped random-field interval consumes nothing")
end

function T.tests.collision_fields_kill_bounce_or_pass_through()
  local function fallingSim(response)
    local boot = { state = 0 }
    local sim = SplParticleSimulation.new(boot, 0, {
      record({
        emitterLife = 1,
        particleLife = 100,
        axis = { x = 0, y = -1, z = 0 },
        velocityFx = { pos = 0, axis = 4096 },
        generation = { countFx = 4096, interval = 100 },
        fields = { { kind = "collision", height = -0.5, bounceFx = 2048, response = response } },
      }),
    })
    local runtime = SplParticleSimulation.addEmitter(sim, 0, nil)
    SplParticleSimulation.advance(sim)
    return sim, runtime
  end
  local killSim, killRuntime = fallingSim("kill")
  Assert.equal(#killRuntime.particles, 1, "the falling particle lives before the plane")
  SplParticleSimulation.advance(killSim)
  Assert.equal(#killRuntime.particles, 0, "a kill response retires the particle at the plane")
  local bounceSim, bounceRuntime = fallingSim("bounce")
  SplParticleSimulation.advance(bounceSim)
  local bounced = bounceRuntime.particles[1]
  Assert.notNil(bounced, "a bounce response keeps the particle")
  -- The zero-range axis velocity scales by 255/256 (4080 raw), damps to
  -- -3060 raw, clamps at the plane, reflects through the rounded
  -- multiply to +1530 raw, then damps to 1147 raw with movement running.
  Assert.near(bounced.y, -901 / 4096, 1e-9, "the bounce clamps to the plane then leaves with the reflected velocity")
  Assert.near(bounced.vy, 1147 / 4096, 1e-9, "the reflected velocity damps through the retail shift")
  SplParticleSimulation.advance(bounceSim)
  local risen = bounceRuntime.particles[1]
  Assert.notNil(risen, "the bounced particle keeps rising")
  Assert.near(risen.y, -41 / 4096, 1e-9, "it leaves the plane on the next tick")
  local passSim, passRuntime = fallingSim("none")
  SplParticleSimulation.advance(passSim)
  SplParticleSimulation.advance(passSim)
  local passed = passRuntime.particles[1]
  Assert.notNil(passed, "a no-op response keeps falling")
  Assert.isTrue(passed.y < -0.5, "it crosses the plane without clamping")
end

function T.tests.child_affect_fields_runs_the_shared_fields_for_children()
  local function childSim(affect)
    local boot = { state = 0 }
    local sim = SplParticleSimulation.new(boot, 0, {
      record({
        emitterLife = 1,
        particleLife = 100,
        velocityFx = { pos = 0, axis = 0 },
        generation = { countFx = 4096, interval = 100 },
        fields = { { kind = "gravity", magnitude = { x = 0, y = -1, z = 0 } } },
        child = {
          useScaleAnm = false,
          useAlphaAnm = false,
          followEmitter = false,
          useChildColor = true,
          childColor = { r = 0, g = 0, b = 0 },
          affectFields = affect and true or nil,
          initVelRandom = 0,
          scaleEnd = 1,
          life = 50,
          velRatio = 0,
          sclRatio = 63,
          genNum = 1,
          genStart = 0,
          genInterval = 1,
          texNo = 1,
          texRepeat = { s = 0, t = 0 },
        },
      }),
    })
    local runtime = SplParticleSimulation.addEmitter(sim, 0, nil)
    SplParticleSimulation.advance(sim)
    return runtime.children[1]
  end
  local affected = childSim(true)
  Assert.notNil(affected, "the parent spawns its child")
  Assert.near(affected.vy, -1, 1e-9, "an affected child falls with the shared gravity")
  local plain = childSim(false)
  Assert.notNil(plain, "the unaffected parent spawns its child")
  Assert.equal(plain.vy, 0, "an unaffected child ignores the shared fields")
end

function T.tests.per_manager_clones_isolate_fields_from_siblings_and_the_cache()
  local cached = record({ fields = {} })
  local bootA, bootB = { state = 0 }, { state = 0 }
  local first = SplParticleSimulation.new(bootA, 0, { cached })
  local second = SplParticleSimulation.new(bootB, 0, { cached })
  Assert.isTrue(first.resources[1] ~= cached, "the manager clones its resource record")
  first.resources[1].fields[#first.resources[1].fields + 1] =
    { kind = "gravity", magnitude = { x = 0, y = -1, z = 0 } }
  Assert.equal(#second.resources[1].fields, 0, "a sibling manager keeps its own fields")
  Assert.equal(#cached.fields, 0, "the cached payload stays immutable")
  SplParticleSimulation.addEmitter(first, 0, nil)
  SplParticleSimulation.addEmitter(first, 0, nil)
  SplParticleSimulation.advance(first)
  for _, runtime in ipairs(first.emitters) do
    Assert.isTrue(
      (runtime.particles[1] or {}).y ~= nil and runtime.particles[1].y < 0,
      "every same-ordinal emitter feels the shared field mutation"
    )
  end
end

function T.tests.cycling_polygon_identities_wrap_from_sixty_three_to_six()
  local boot = { state = 0 }
  local sim = SplParticleSimulation.new(
    boot,
    0,
    { record({ persistent = true, emitterLife = 0, particleLife = 200, generation = { countFx = 4096, interval = 200 } }) }
  )
  local runtime = SplParticleSimulation.addEmitter(sim, 0, nil)
  local seen = {}
  for _ = 1, 60 do
    SplParticleSimulation.advance(sim)
    seen[#seen + 1] = runtime.particles[1].pid
  end
  Assert.equal(seen[1], 6, "calculation assigns the first cycling identity")
  Assert.equal(seen[58], 63, "the cycle reaches sixty-three")
  Assert.equal(seen[59], 6, "the cycle wraps back to six")
  Assert.equal(seen[60], 7, "drawing consumes no identities")
end

function T.tests.zeroed_ranges_still_consume_their_stream_draws()
  local boot = { state = 0 }
  local sim = SplParticleSimulation.new(boot, 0, {
    record({
      persistent = true,
      emitterLife = 0,
      particleLife = 100,
      velRandom = 0,
      scaleRandom = 0,
      lifeRandom = 0,
      generation = { countFx = 4096, interval = 100 },
      animations = {
        alpha = { start = 0, normal = 31, finish = 31, flick = 0, inTick = 10, outTick = 200 },
      },
      fields = { { kind = "random", magnitude = { x = 0, y = 0, z = 0 }, interval = 1 } },
    }),
  })
  SplParticleSimulation.addEmitter(sim, 0, nil)
  SplParticleSimulation.advance(sim)
  -- Spawn: three placement plus four shared draws; first update: one
  -- alpha flicker plus three random-field draws.
  local expected = 0
  for _ = 1, 11 do
    expected = nextSeed(expected)
  end
  Assert.equal(sim.rng, expected, "zero ranges still advance the stream")
end

return T
