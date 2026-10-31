-- Software particle simulation for the retail SPL library (lib/src/spl_*.c):
-- the deterministic congruential stream, emitter placement kinds, life-rate
-- scale/color/alpha/texture blocks (plain or looping), random color and
-- texture picks, rotation, fields, and children over compiled emitter
-- records. Each particle carries the texture it currently shows in texNo. Rendering stays with each consumer; this module
-- owns only emitter and particle state. Normalized directions and rotations
-- use host floating point and are deterministic without being bit-identical
-- to the retail fixed-point unit.

---@class SplParticleSimulation
---@field rng integer deterministic stream state
---@field emitters table<string, unknown>[] live emitter runtimes, oldest first
---@field emitterZOffset number added to every emitter's resource z on creation

local M = {}
M.__index = M

-- The retail particle heap bounds one system to 200 particles; exhausted
-- spawns drop instead of growing (ParticleSystem_New).
local MAX_PARTICLE_COUNT = 200

-- C integer division truncates toward zero, unlike a flooring shift: color
-- and scale slopes with negative spans must round the same way.
---@param numerator number
---@param denominator number
---@return integer
local function cdivTrunc(numerator, denominator)
  assert(denominator ~= 0, "source slopes never divide by zero")
  local quotient = numerator / denominator
  if quotient >= 0 then
    return math.floor(quotient)
  end
  return math.ceil(quotient)
end

-- Wrapping reinterpretation between the unsigned draw stream and the
-- signed magnitudes the retail fixed point computes with.
---@param value number
---@return number
local function s32wrap(value)
  local wrapped = value % 4294967296
  if wrapped >= 2147483648 then
    return wrapped - 4294967296
  end
  return wrapped
end

-- Exact 1/4096-unit round trip between the normalized world floats the
-- sim stores and the integer raw values the retail fixed point steps.
-- Stored velocities and normalized magnitudes with power-of-two
-- denominators convert back exactly; field products round to nearest.
---@param world number normalized world-unit value
---@return integer raw value in 1/4096 units
local function worldToRawFx(world)
  if world >= 0 then
    return math.floor(world * 4096 + 0.5)
  end
  return math.ceil(world * 4096 - 0.5)
end

-- One retail damping step: the signed raw velocity times the staged
-- coefficient, wrapped to 32 bits, then shifted right keeping the sign,
-- which floors negative quotients instead of truncating them toward zero.
---@param rawVel integer raw velocity in 1/4096 units
---@param airResist integer staged air resistance 0..255
---@return integer damped raw velocity
local function dampRawFx(rawVel, airResist)
  return math.floor(s32wrap(rawVel * (airResist + 384)) / 512)
end

-- One step of the retail particle library's congruential stream
-- (seed = seed * 0x5EEDF715 + 0x1B0CB173 mod 2^32). The full product
-- exceeds double precision, so 16-bit limbs keep every step exact; the
-- high limb product vanishes modulo 2^32. Limbs derive from the staged
-- constants so no hand-split literal can drift.
local RNG_MULTIPLIER = 0x5EEDF715
local RNG_INCREMENT = 0x1B0CB173
local RNG_MULTIPLIER_LO = RNG_MULTIPLIER % 65536
local RNG_MULTIPLIER_HI = (RNG_MULTIPLIER - RNG_MULTIPLIER_LO) / 65536
---@param sim SplParticleSimulation simulation owning the deterministic particle seed
---@return integer next stream value
local function rngNext(sim)
  local seed = sim.rng --[[@as integer]]
  local seedLo = seed % 65536
  local seedHi = math.floor((seed - seedLo) / 65536)
  local low = seedLo * RNG_MULTIPLIER_LO
  local mid = seedLo * RNG_MULTIPLIER_HI + seedHi * RNG_MULTIPLIER_LO
  sim.rng = ((low + (mid % 65536) * 65536 + RNG_INCREMENT) % 4294967296) --[[@as integer]]
  return sim.rng --[[@as integer]]
end

---@param x number
---@param y number
---@param z number
---@return number nx, number ny, number nz
local function normalize3(x, y, z)
  local length = math.sqrt(x * x + y * y + z * z)
  assert(length > 0, "particle normalizes a zero vector")
  return x / length, y / length, z / length
end

-- The emitter axis frame for circle, disc, cylinder, and hemisphere
-- placement: two orthonormal vectors across the circle axis plus their
-- normal, matching the retail cross-to-axis setup. The base vector is
-- +Y unless the axis is parallel to it.
---@param record table<string, unknown> compiled starter emitter record
---@return table<string, unknown>? frame with c1x..c2z, or nil for point placement
local function circleFrame(record)
  local circleAxis = record.circleAxis --[[@as integer]]
  local initPosType = record.initPosType --[[@as integer]]
  -- Point emitters keep no frame; every other validated placement kind does.
  if
    initPosType ~= 2
    and initPosType ~= 3
    and initPosType ~= 5
    and initPosType ~= 6
    and initPosType ~= 7
    and initPosType ~= 8
    and initPosType ~= 9
  then
    return nil
  end
  local ax, ay, az = 0, 0, 1
  if circleAxis == 2 then
    ax, ay, az = 1, 0, 0
  elseif circleAxis == 1 then
    ax, ay, az = 0, 1, 0
  end
  local bx, by, bz = 0, 1, 0
  if ay == 1 or ay == -1 then
    bx, by, bz = 1, 0, 0
  end
  local c1x, c1y, c1z = normalize3(ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx)
  local c2x, c2y, c2z = normalize3(ay * c1z - az * c1y, az * c1x - ax * c1z, ax * c1y - ay * c1x)
  local nx, ny, nz = normalize3(c1y * c2z - c1z * c2y, c1z * c2x - c1x * c2z, c1x * c2y - c1y * c2x)
  return { c1x = c1x, c1y = c1y, c1z = c1z, c2x = c2x, c2y = c2y, c2z = c2z, nx = nx, ny = ny, nz = nz }
end

-- Maps circle-frame coordinates into emitter space through the frame
-- normal, matching the retail circle-axis projection.
---@param frame table<string, unknown> circle frame from circleFrame
---@param x number
---@param y number
---@param z number
---@return number px, number py, number pz
local function circleMap(frame, x, y, z)
  local c1x = frame.c1x --[[@as number]]
  local c1y = frame.c1y --[[@as number]]
  local c1z = frame.c1z --[[@as number]]
  local c2x = frame.c2x --[[@as number]]
  local c2y = frame.c2y --[[@as number]]
  local c2z = frame.c2z --[[@as number]]
  local nx = frame.nx --[[@as number]]
  local ny = frame.ny --[[@as number]]
  local nz = frame.nz --[[@as number]]
  return x * c1x + y * c2x + z * nx, x * c1y + y * c2y + z * ny, x * c1z + y * c2z + z * nz
end

-- Scales a fixed-point magnitude by a random factor around one, drawing
-- once from the sim stream even when the range is zero. Integer-exact:
-- every operand stays below 2^41.
---@param valueFx integer fixed-point magnitude in 1/4096 units
---@param range integer random range 0..255
---@param sim SplParticleSimulation
---@return integer randomized magnitude in 1/4096 units
local function randomizeFx(valueFx, range, sim)
  local draw = math.floor(rngNext(sim) / 16777216)
  local factor = range + 255 - math.floor(draw * range / 128)
  return math.floor(factor * valueFx / 256)
end

-- A random fixed-point factor in [0, 1), drawing once from the sim stream
-- (RANDOM_HALF_TO_ONE).
---@param sim SplParticleSimulation
---@return integer factor in 1/4096 units
local function randomHalfToOneFx(sim)
  local draw = math.floor(rngNext(sim) / 8388608)
  return math.floor((draw * 4096 - 1048576) / 512) + 2048
end

-- A random fixed-point factor in [-1, 1), drawing once from the sim stream.
---@param sim SplParticleSimulation
---@return integer factor in 1/4096 units
local function randomSignedOneFx(sim)
  local draw = math.floor(rngNext(sim) / 8388608)
  return math.floor((draw * 4096 - 1048576) / 256)
end

-- A random unit vector in the disc plane, drawing twice.
---@param sim SplParticleSimulation
---@return number x, number y
local function arbVecXy(sim)
  local x = s32wrap(rngNext(sim)) / 256
  local y = s32wrap(rngNext(sim)) / 256
  local length = math.sqrt(x * x + y * y)
  assert(length > 0, "particle random disc degenerates")
  return x / length, y / length
end

-- A random 3D unit vector, drawing three times.
---@param sim SplParticleSimulation
---@return number x, number y, number z
local function arbVecXyz(sim)
  return normalize3(s32wrap(rngNext(sim)) / 256, s32wrap(rngNext(sim)) / 256, s32wrap(rngNext(sim)) / 256)
end

-- Evaluates one staged scale block at a life rate: integer-exact stage
-- interpolation with truncating slopes, matching the retail in/out law.
---@param anim table<string, unknown> normalized scale record
---@param rate integer life rate 0..255
---@return integer animated scale in fx16 units
local function evalScaleFx(anim, rate)
  local startFx = anim.startFx --[[@as integer]]
  local normalFx = anim.normalFx --[[@as integer]]
  local finishFx = anim.finishFx --[[@as integer]]
  local inTick = anim.inTick --[[@as integer]]
  local outTick = anim.outTick --[[@as integer]]
  if rate < inTick then
    return startFx + cdivTrunc((normalFx - startFx) * rate, inTick)
  elseif rate < outTick then
    return normalFx
  end
  local span = 255 - outTick
  if span <= 0 then
    return finishFx
  end
  return finishFx + cdivTrunc((finishFx - normalFx) * (rate - 255), span)
end

-- Evaluates one staged color block at a life rate: the start color below
-- the entry threshold, the interpolated or snapped base-to-endpoint
-- slopes, then the end color. Channel arithmetic is integer-exact.
---@param anim table<string, unknown> normalized color record
---@param baseRgb table<string, integer> base color channels
---@param rate integer life rate 0..255
---@return table<string, integer> animated color channels
local function evalColorRgb(anim, baseRgb, rate)
  local startRgb = anim.startRgb --[[@as table<string, integer>]]
  local endRgb = anim.endRgb --[[@as table<string, integer>]]
  local inTick = anim.inTick --[[@as integer]]
  local peakTick = anim.peakTick --[[@as integer]]
  local outTick = anim.outTick --[[@as integer]]
  if rate < inTick then
    return { r = startRgb.r, g = startRgb.g, b = startRgb.b }
  elseif rate < peakTick then
    if not anim.interpolate then
      return { r = baseRgb.r, g = baseRgb.g, b = baseRgb.b }
    end
    local t, span = rate - inTick, peakTick - inTick
    return {
      r = startRgb.r + cdivTrunc(t * (baseRgb.r - startRgb.r), span),
      g = startRgb.g + cdivTrunc(t * (baseRgb.g - startRgb.g), span),
      b = startRgb.b + cdivTrunc(t * (baseRgb.b - startRgb.b), span),
    }
  elseif rate < outTick then
    if not anim.interpolate then
      return { r = endRgb.r, g = endRgb.g, b = endRgb.b }
    end
    local t, span = rate - peakTick, outTick - peakTick
    return {
      r = baseRgb.r + cdivTrunc(t * (endRgb.r - baseRgb.r), span),
      g = baseRgb.g + cdivTrunc(t * (endRgb.g - baseRgb.g), span),
      b = baseRgb.b + cdivTrunc(t * (endRgb.b - baseRgb.b), span),
    }
  end
  return { r = endRgb.r, g = endRgb.g, b = endRgb.b }
end

-- Evaluates one staged alpha block at a life rate and applies the flicker
-- draw: the level scales down by a random fraction of the flicker
-- magnitude. The flicker draw happens on every evaluation even when the
-- magnitude is zero, keeping the stream position sourced.
---@param anim table<string, unknown> normalized alpha record
---@param rate integer life rate 0..255
---@param sim SplParticleSimulation
---@return integer animated alpha 0..31
local function evalAlpha(anim, rate, sim)
  local start = anim.start --[[@as integer]]
  local normal = anim.normal --[[@as integer]]
  local finish = anim.finish --[[@as integer]]
  local inTick = anim.inTick --[[@as integer]]
  local outTick = anim.outTick --[[@as integer]]
  local level
  if rate < inTick then
    level = start + cdivTrunc(rate * (normal - start), inTick)
  elseif rate < outTick then
    level = normal
  else
    local span = 255 - outTick
    if span <= 0 then
      level = finish
    else
      level = finish + cdivTrunc((rate - 255) * (finish - normal), span)
    end
  end
  local flickDraw = math.floor(rngNext(sim) / 16777216)
  local flick = anim.flick --[[@as integer]]
  return math.floor(level * (255 - math.floor(flick * flickDraw / 256)) / 256)
end

---@param sim SplParticleSimulation
---@return integer live parent and child particles across every emitter
local function liveParticleCount(sim)
  local count = 0
  for _, runtime in ipairs(sim.emitters) do
    count = count + #runtime.particles + #runtime.children
  end
  return count
end

-- Places a particle by the retail placement kind (spl_gen_ptcl), returning
-- its emitter-relative position and, for cylinder walls, its outward
-- direction. Draw counts per kind follow the retail stream order.
---@param sim SplParticleSimulation
---@param runtime table<string, unknown> live emitter runtime gaining one particle
---@param index integer zero-based index of this particle within its generation burst
---@param count integer particles the burst generates
---@return number px, number py, number pz, number? dirX, number? dirY, number? dirZ
local function placeParticle(sim, runtime, index, count)
  local record = runtime.record --[[@as table<string, unknown>]]
  local initPosType = record.initPosType --[[@as integer]]
  local radius = record.radius --[[@as number]]
  local frame = runtime.frame --[[@as table<string, unknown>]]
  local lengthFx = math.floor(record.length --[[@as number]] * 4096 + 0.5)
  if initPosType == 1 then
    local nx, ny, nz = arbVecXyz(sim)
    return nx * radius, ny * radius, nz * radius
  elseif initPosType == 2 then
    local nx, ny = arbVecXy(sim)
    return circleMap(frame, nx * radius, ny * radius, 0)
  elseif initPosType == 3 then
    -- Evenly spaced on the circle: the burst index maps to a 4096-step angle.
    local step = math.floor(math.floor(index * 65536 / count) / 16)
    local angle = step / 4096 * 2 * math.pi
    return circleMap(frame, math.sin(angle) * radius, math.cos(angle) * radius, 0)
  elseif initPosType == 4 then
    local nx, ny, nz = arbVecXyz(sim)
    local fx = randomSignedOneFx(sim)
    local fy = randomSignedOneFx(sim)
    local fz = randomSignedOneFx(sim)
    return nx * radius * fx / 4096, ny * radius * fy / 4096, nz * radius * fz / 4096
  elseif initPosType == 5 then
    local vx, vy = arbVecXy(sim)
    local lx = vx * radius * randomSignedOneFx(sim) / 4096
    local ly = vy * radius * randomSignedOneFx(sim) / 4096
    return circleMap(frame, lx, ly, 0)
  elseif initPosType == 8 or initPosType == 9 then
    local nx, ny, nz = arbVecXyz(sim)
    local axisX, axisY, axisZ =
      frame.nx, --[[@as number]]
      frame.ny, --[[@as number]]
      frame.nz --[[@as number]]
    local dot = nx * axisX + ny * axisY + nz * axisZ
    -- The surface keeps the axis-side hemisphere; a zero dot flips the
    -- surface kind but not the volume kind.
    if dot < 0 or (initPosType == 8 and dot == 0) then
      nx, ny, nz = -nx, -ny, -nz
    end
    if initPosType == 8 then
      return nx * radius, ny * radius, nz * radius
    end
    local fx = randomHalfToOneFx(sim)
    local fy = randomHalfToOneFx(sim)
    local fz = randomHalfToOneFx(sim)
    return nx * radius * fx / 4096, ny * radius * fy / 4096, nz * radius * fz / 4096
  elseif initPosType == 6 or initPosType == 7 then
    local vx, vy = arbVecXy(sim)
    local lx, ly = vx * radius, vy * radius
    if initPosType == 7 then
      lx = lx * randomSignedOneFx(sim) / 4096
      ly = ly * randomSignedOneFx(sim) / 4096
    end
    local draw = math.floor(rngNext(sim) / 8388608)
    local lz = math.floor(s32wrap(lengthFx * draw - s32wrap(lengthFx * 256)) / 256) / 4096
    local px, py, pz = circleMap(frame, lx, ly, lz)
    if initPosType == 6 then
      -- Cylinder walls orient along the disc velocity mapped through the
      -- frame directly, without the normal term.
      return px,
        py,
        pz,
        vx * frame.c1x --[[@as number]] + vy * frame.c2x, --[[@as number]]
        vx * frame.c1y --[[@as number]] + vy * frame.c2y, --[[@as number]]
        vx * frame.c1z --[[@as number]] + vy * frame.c2z --[[@as number]]
    end
    return px, py, pz
  end
  return 0, 0, 0
end

---@param sim SplParticleSimulation
---@param runtime table<string, unknown> live emitter runtime gaining one particle
---@param index integer zero-based index of this particle within its generation burst
---@param count integer particles the burst generates
local function spawnParticle(sim, runtime, index, count)
  if liveParticleCount(sim) >= MAX_PARTICLE_COUNT then
    return
  end
  local record = runtime.record --[[@as table<string, unknown>]]
  local px, py, pz, dirX, dirY, dirZ = placeParticle(sim, runtime, index, count)
  local velocityFx = record.velocityFx --[[@as { pos: integer, axis: integer }]]
  local velRandom = record.velRandom --[[@as integer]]
  local velPos = randomizeFx(velocityFx.pos, velRandom, sim)
  local velAxis = randomizeFx(velocityFx.axis, velRandom, sim)
  local nx, ny, nz
  if dirX ~= nil then
    nx, ny, nz = normalize3(dirX, dirY --[[@as number]], dirZ --[[@as number]])
  elseif px == 0 and py == 0 and pz == 0 then
    nx, ny, nz = arbVecXyz(sim)
  else
    nx, ny, nz = normalize3(px, py, pz)
  end
  local axis = record.axis --[[@as { x: number, y: number, z: number }]]
  local baseScale = randomizeFx(record.baseScaleFx --[[@as integer]], record.scaleRandom --[[@as integer]], sim)
  local baseRgb = record.baseColorRgb --[[@as table<string, integer>]]
  local animations = record.animations --[[@as table<string, unknown>]]
  local pickedRgb = baseRgb
  local colorAnim = animations.color --[[@as table<string, unknown>|nil]]
  if colorAnim ~= nil and colorAnim.random then
    -- A random color pick replaces the color animation: start, base, or end.
    local pick = math.floor(rngNext(sim) / 1048576) % 3
    if pick == 0 then
      pickedRgb = colorAnim.startRgb --[[@as table<string, integer>]]
    elseif pick == 2 then
      pickedRgb = colorAnim.endRgb --[[@as table<string, integer>]]
    end
  end
  local rotation = record.rotation --[[@as { min: integer, max: integer }]]
  local rtt
  if record.useInitRotationRandom then
    rtt = rngNext(sim) % 65536
  else
    rtt = record.initRotation --[[@as integer]]
  end
  local rttVel = 0
  if record.useRotationAnim then
    local draw = math.floor(rngNext(sim) / 1048576)
    rttVel = math.floor((rotation.min * 4096 + (rotation.max - rotation.min) * draw) / 4096)
  end
  local lifeDraw = math.floor(rngNext(sim) / 16777216)
  local lifeRandom = record.lifeRandom --[[@as integer]]
  local particleLife = record.particleLife --[[@as integer]]
  local life = math.floor((255 - math.floor(lifeDraw * lifeRandom / 256)) * particleLife / 256) + 1
  local texNo = record.texture --[[@as integer]]
  local textureAnim = record.textureAnim --[[@as table<string, unknown>|nil]]
  if textureAnim ~= nil then
    local textures = textureAnim.textures --[[@as integer[] ]]
    if textureAnim.random then
      texNo = textures[math.floor(rngNext(sim) / 1048576) % #textures + 1]
    else
      texNo = textures[1]
    end
  end
  local loopFrame = record.loopFrame --[[@as integer]]
  runtime.particles[#runtime.particles + 1] = {
    x = px,
    y = py,
    z = pz,
    vx = nx * velPos / 4096 + axis.x * velAxis / 4096,
    vy = ny * velPos / 4096 + axis.y * velAxis / 4096,
    vz = nz * velPos / 4096 + axis.z * velAxis / 4096,
    rtt = rtt,
    rttVel = rttVel,
    life = life,
    age = 0,
    diffLoop = math.floor(65535 / loopFrame),
    diffNoloop = math.floor(65535 / life),
    baseScale = baseScale,
    animScale = 4096,
    colorRgb = { r = pickedRgb.r, g = pickedRgb.g, b = pickedRgb.b },
    baseAlpha = record.baseAlpha --[[@as integer]],
    animAlpha = 31,
    texNo = texNo,
    ex = runtime.x --[[@as number]],
    ey = runtime.y --[[@as number]],
    ez = runtime.z --[[@as number]],
  }
end

-- Spawns one child particle from a live parent: the parent position, its
-- velocity scaled by the velocity ratio plus a random spread, the scaled
-- base, and the child color or inherited color. Each spawn draws three
-- times, even when the spread magnitude is zero.
---@param sim SplParticleSimulation
---@param runtime table<string, unknown> live emitter runtime
---@param parent table<string, unknown> live parent particle
local function spawnChild(sim, runtime, parent)
  local record = runtime.record --[[@as table<string, unknown>]]
  local child = record.child --[[@as table<string, unknown>]]
  local velRatio = child.velRatio --[[@as integer]]
  local spreadRawFx = worldToRawFx(child.initVelRandom --[[@as number]])
  local function spreadAxis(parentVel)
    local scaled = math.floor(worldToRawFx(parentVel) * velRatio / 256)
    local draw = math.floor(rngNext(sim) / 8388608)
    return (scaled + math.floor((spreadRawFx * draw - spreadRawFx * 256) / 256)) / 4096
  end
  local scaledBase = math.floor(parent.baseScale --[[@as integer]] * parent.animScale --[[@as integer]] / 4096)
  local colorRgb = child.childColor --[[@as table<string, integer>]]
  if not child.useChildColor then
    local inherited = parent.colorRgb --[[@as table<string, integer>]]
    colorRgb = { r = inherited.r, g = inherited.g, b = inherited.b }
  end
  -- Rotation type 1 inherits the parent angle, 2 also its spin; absent
  -- means unrotated.
  local rotationType = child.rotationType --[[@as integer|nil]]
  runtime.children[#runtime.children + 1] = {
    x = parent.x,
    y = parent.y,
    z = parent.z,
    vx = spreadAxis(parent.vx --[[@as number]]),
    vy = spreadAxis(parent.vy --[[@as number]]),
    vz = spreadAxis(parent.vz --[[@as number]]),
    rtt = rotationType ~= nil and parent.rtt or 0,
    rttVel = rotationType == 2 and parent.rttVel or 0,
    life = child.life --[[@as integer]],
    age = 0,
    baseScale = math.floor(
      scaledBase
        * (
          child.sclRatio --[[@as integer]]
          + 1
        )
        / 64
    ),
    animScale = 4096,
    colorRgb = { r = colorRgb.r, g = colorRgb.g, b = colorRgb.b },
    baseAlpha = math.floor(
      parent.baseAlpha --[[@as integer]]
        * (
          parent.animAlpha --[[@as integer]]
          + 1
        )
        / 32
    ),
    animAlpha = 31,
    texNo = child.texNo --[[@as integer]],
    ex = parent.ex,
    ey = parent.ey,
    ez = parent.ez,
  }
end

-- Rotates a position about one source axis by a retail rotation step.
---@param x number
---@param y number
---@param z number
---@param axis integer 0, 1, or 2
---@param rotation integer rotation step 0..65535
---@return number rx, number ry, number rz
local function spinRotate(x, y, z, axis, rotation)
  local angle = rotation / 65536 * 2 * math.pi
  local sine, cosine = math.sin(angle), math.cos(angle)
  if axis == 0 then
    return x, cosine * y - sine * z, sine * y + cosine * z
  elseif axis == 1 then
    return cosine * x + sine * z, y, cosine * z - sine * x
  end
  return cosine * x - sine * y, sine * x + cosine * y, z
end

-- Moves one particle for a source tick: rotation advance, damping of the
-- raw 1/4096-unit velocity with the retail signed shift, then field
-- acceleration, then position integration. Damping first keeps sub-unit
-- velocities significant instead of flooring world units to 0 or -1.
---@param particle table<string, unknown> live particle
---@param airResist integer staged air resistance 0..255
---@param accX number field acceleration in world units along x
---@param accY number field acceleration in world units along y
---@param accZ number field acceleration in world units along z
local function moveParticle(particle, airResist, accX, accY, accZ)
  particle.rtt = (
    particle.rtt --[[@as integer]]
    + particle.rttVel --[[@as integer]]
  ) % 65536
  local vxFx = s32wrap(dampRawFx(worldToRawFx(particle.vx --[[@as number]]), airResist) + worldToRawFx(accX))
  local vyFx = s32wrap(dampRawFx(worldToRawFx(particle.vy --[[@as number]]), airResist) + worldToRawFx(accY))
  local vzFx = s32wrap(dampRawFx(worldToRawFx(particle.vz --[[@as number]]), airResist) + worldToRawFx(accZ))
  particle.vx, particle.vy, particle.vz = vxFx / 4096, vyFx / 4096, vzFx / 4096
  particle.x = particle.x --[[@as number]] + particle.vx --[[@as number]]
  particle.y = particle.y --[[@as number]] + particle.vy --[[@as number]]
  particle.z = particle.z --[[@as number]] + particle.vz --[[@as number]]
end

-- Runs one particle through its staged scale/color/alpha blocks at its
-- current age, then its fields and motion. Newborn particles update on
-- their birth tick, matching the retail generation-then-update order.
---@param sim SplParticleSimulation
---@param runtime table<string, unknown> live emitter runtime
---@param particle table<string, unknown> live particle
local function updateParticle(sim, runtime, particle)
  local record = runtime.record --[[@as table<string, unknown>]]
  local age = particle.age --[[@as integer]]
  -- The retail life rates are bytes: one over the particle's life, one
  -- looping over the emitter's loop frame.
  local rateNoloop = math.floor(particle.diffNoloop --[[@as integer]] * age / 256) % 256
  local rateLoop = math.floor(particle.diffLoop --[[@as integer]] * age / 256) % 256
  local animations = record.animations --[[@as table<string, unknown>]]
  local scale = animations.scale --[[@as table<string, unknown>|nil]]
  if scale ~= nil then
    particle.animScale = evalScaleFx(scale, scale.loop and rateLoop or rateNoloop)
  end
  local color = animations.color --[[@as table<string, unknown>|nil]]
  if color ~= nil and not color.random then
    particle.colorRgb =
      evalColorRgb(color, record.baseColorRgb --[[@as table<string, integer>]], color.loop and rateLoop or rateNoloop)
  end
  local alpha = animations.alpha --[[@as table<string, unknown>|nil]]
  if alpha ~= nil then
    particle.animAlpha = evalAlpha(alpha, alpha.loop and rateLoop or rateNoloop, sim)
  end
  local textureAnim = record.textureAnim --[[@as table<string, unknown>|nil]]
  if textureAnim ~= nil and not textureAnim.random then
    local textureRate = textureAnim.loop and rateLoop or rateNoloop
    local textures = textureAnim.textures --[[@as integer[] ]]
    local diff = textureAnim.diff --[[@as integer]]
    for index = 1, #textures do
      if textureRate < diff * index then
        particle.texNo = textures[index]
        break
      end
    end
  end
  local accX, accY, accZ = 0, 0, 0
  for _, field in
    ipairs(record.fields --[[@as table<string, unknown>[] ]])
  do
    local entry = field --[[@as table<string, unknown>]]
    if entry.kind == "gravity" then
      local magnitude = entry.magnitude --[[@as { x: number, y: number, z: number }]]
      accX, accY, accZ = accX + magnitude.x, accY + magnitude.y, accZ + magnitude.z
    elseif entry.kind == "magnet" then
      -- The retail magnet pulls toward its resource position with the
      -- velocity-damped offset; positions here are emitter-relative, so
      -- the attraction runs in the emitter frame exactly as staged.
      local target = entry.position --[[@as { x: number, y: number, z: number }]]
      local magnitude = entry.magnitude --[[@as number]]
      local dx = target.x - particle.x --[[@as number]] - particle.vx --[[@as number]]
      local dy = target.y - particle.y --[[@as number]] - particle.vy --[[@as number]]
      local dz = target.z - particle.z --[[@as number]] - particle.vz --[[@as number]]
      accX, accY, accZ = accX + magnitude * dx, accY + magnitude * dy, accZ + magnitude * dz
    elseif entry.kind == "spin" then
      particle.x, particle.y, particle.z = spinRotate(
        particle.x --[[@as number]],
        particle.y --[[@as number]],
        particle.z --[[@as number]],
        entry.axis --[[@as integer]],
        entry.rotation --[[@as integer]]
      )
    end
  end
  moveParticle(particle, record.airResist --[[@as integer]], accX, accY, accZ)
  if record.child ~= nil then
    local child = record.child --[[@as table<string, unknown>]]
    local genStart = child.genStart --[[@as integer]]
    local genInterval = child.genInterval --[[@as integer]]
    local life = particle.life --[[@as integer]]
    local since = age * 4096 - life * genStart * 16
    if since >= 0 and math.floor(since / 4096) % genInterval == 0 then
      for _ = 1, child.genNum --[[@as integer]] do
        if liveParticleCount(sim) < MAX_PARTICLE_COUNT then
          spawnChild(sim, runtime, particle)
        end
      end
    end
  end
  particle.age = age + 1
end

-- Runs one child particle for a source tick: its life-rate scale/alpha
-- curves (or none), emitter tracking, and motion. The animated scale
-- stays in raw fx16 units, starting at unity and interpolating toward
-- the staged end with truncating slopes; the renderer normalizes once.
---@param runtime table<string, unknown> live emitter runtime
---@param particle table<string, unknown> live child particle
local function updateChild(runtime, particle)
  local record = runtime.record --[[@as table<string, unknown>]]
  local child = record.child --[[@as table<string, unknown>]]
  local age = particle.age --[[@as integer]]
  local life = particle.life --[[@as integer]]
  local rate = math.floor(age * 256 / life)
  if child.useScaleAnm then
    local endRawFx = worldToRawFx(child.scaleEnd --[[@as number]])
    particle.animScale = endRawFx + cdivTrunc((endRawFx - 4096) * (rate - 255), 255)
  end
  if child.useAlphaAnm then
    particle.animAlpha = cdivTrunc((255 - rate) * 31, 255)
  end
  if child.followEmitter then
    particle.ex = runtime.x
    particle.ey = runtime.y
    particle.ez = runtime.z
  end
  moveParticle(particle, record.airResist --[[@as integer]], 0, 0, 0)
  particle.age = age + 1
end

---@param seed integer opening value of the deterministic stream
---@param emitterZOffset number z offset applied to every emitter position
---@return SplParticleSimulation
function M.new(seed, emitterZOffset)
  assert(seed % 1 == 0 and seed >= 0 and seed < 4294967296, "particle seed is a 32-bit value")
  return setmetatable({ rng = seed, emitters = {}, emitterZOffset = emitterZOffset }, M)
end

-- Adds one emitter runtime for a compiled record; it starts generating once
-- its start offset elapses.
---@param sim SplParticleSimulation
---@param id integer source emitter id
---@param group string|nil consumer-owned group tag that advance may filter on
---@param record table<string, unknown> compiled emitter record
function M.addEmitter(sim, id, group, record)
  local position = record.position --[[@as { x: number, y: number, z: number }]]
  sim.emitters[#sim.emitters + 1] = {
    id = id,
    group = group,
    record = record,
    age = 0,
    started = false,
    carry = 0,
    x = position.x,
    y = position.y,
    z = position.z + sim.emitterZOffset,
    frame = circleFrame(record),
    particles = {},
    children = {},
    quad = nil,
  }
end

---@param sim SplParticleSimulation
---@param group string|nil only emitters of this group advance; nil advances every emitter
function M.advance(sim, group)
  -- walk, keeping the shared stream position sourced across emitters.
  for index = #sim.emitters, 1, -1 do
    local runtime = sim.emitters[index]
    if group == nil or runtime.group == group then
      local record = runtime.record --[[@as table<string, unknown>]]
      local emitterLife = record.emitterLife --[[@as integer]]
      local age = runtime.age --[[@as integer]]
      if
        not runtime.started and age >= record.startOffset --[[@as integer]]
      then
        runtime.started = true
        runtime.age = 0
        age = 0
      end
      if runtime.started and (emitterLife == 0 or age < emitterLife) then
        local generation = record.generation --[[@as { countFx: integer, interval: integer }]]
        if age % generation.interval == 0 then
          local total = generation.countFx + runtime.carry --[[@as integer]]
          local due = math.floor(total / 4096)
          runtime.carry = total - due * 4096
          for burstIndex = 0, due - 1 do
            if liveParticleCount(sim) < MAX_PARTICLE_COUNT then
              spawnParticle(sim, runtime, burstIndex, due)
            end
          end
        end
      end
      -- Youngest particles update first: newborns join at the front of
      -- the retail active list and update on their birth tick.
      for particleIndex = #runtime.particles, 1, -1 do
        local particle = runtime.particles[particleIndex]
        updateParticle(sim, runtime, particle)
        if
          particle.age --[[@as integer]]
          > particle.life --[[@as integer]]
        then
          table.remove(runtime.particles, particleIndex)
        end
      end
      for childIndex = #runtime.children, 1, -1 do
        local childParticle = runtime.children[childIndex]
        updateChild(runtime, childParticle)
        if
          childParticle.age --[[@as integer]]
          > childParticle.life --[[@as integer]]
        then
          table.remove(runtime.children, childIndex)
        end
      end
      runtime.age = runtime.age --[[@as integer]] + 1
      -- Self-destroying emitters leave the active set once their age
      -- passes their lifespan and their last particle retires.
      if
        emitterLife ~= 0
        and runtime.started
        and runtime.age --[[@as integer]]
          > emitterLife
        and #runtime.particles == 0
        and #runtime.children == 0
      then
        table.remove(sim.emitters, index)
      end
    end
  end
end

return M
