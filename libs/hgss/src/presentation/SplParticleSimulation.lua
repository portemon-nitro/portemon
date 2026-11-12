-- Software particle simulation for the retail SPL library (lib/src/spl_*.c):
-- the deterministic congruential stream, emitter placement kinds, life-rate
-- scale/color/alpha/texture blocks (plain or looping), random color and
-- texture picks, rotation, fields, and children over compiled emitter
-- records. Each particle carries the texture it currently shows in texNo. Rendering stays with each consumer; this module
-- owns only emitter and particle state. Stored positions, velocities, and
-- fixed-point magnitudes are binary-exact multiples of 1/4096: every write
-- is an exact raw fixed-point result divided by 4096, never a continuously
-- integrated float. Integer fields (ages, angles, rates, scales) stay raw.

local FxMath = require("libs.hgss.src.presentation.PresentationFxMath")

---@class SplParticleSimulation
---@field randomState table<string, integer> borrowed boot stream record shared by every manager of one boot
---@field rng integer last stream value drawn
---@field emitters table<string, unknown>[] live emitter runtimes, oldest first
---@field emitterZOffset number added to every emitter's resource z on creation
---@field resources table<string, unknown>[] per-manager mutable resource clones, one per compiled emitter
---@field camera table<string, unknown> mutable manager camera behind drawing
---@field _emitterNodes table<string, unknown>[] pooled emitter nodes, live or free
---@field _freeEmitters table<string, unknown>[] free emitter nodes, allocation pops the front
---@field _freeParticles table<string, unknown>[] free particle nodes shared by parents and children
---@field _calcCycle integer manager calculation cycle toggling 0 and 1 each advance
---@field _nextPolygonId integer next cycling polygon identity 6..63

local M = {}
M.__index = M

-- The retail particle heap bounds one system to 20 simultaneous emitters
-- and 200 particles shared across parents, children, and emitters
-- (spl_manager.c, ParticleSystem_New). Exhausted allocation drops the
-- creation or spawn without consuming random draws instead of growing.
local MAX_EMITTER_COUNT = 20
local MAX_PARTICLE_COUNT = 200

-- Default manager camera behind battle drawing (spl camera defaults with
-- the battle-requested perspective applied at each emitter creation).
local CAMERA_DEFAULTS = {
  x = 0,
  y = 0,
  z = 16384,
  targetX = 0,
  targetY = 0,
  targetZ = 0,
  upX = 0,
  upY = 4096,
  upZ = 0,
  distance = 16384,
  angleX = 0,
  angleY = 0,
  angleZ = 0,
  halfFov = 8192,
  aspect = 5461,
  near = 4096,
  far = 3686400,
  perspective = 0,
}

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
---@return integer
local function s32wrap(value)
  local wrapped = math.floor(value) % 4294967296
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

-- Rounded fixed-point multiply: exact signed product, +2048 bias,
-- arithmetic shift 12 (the retail FX_Mul).
---@param a integer raw fixed-point factor
---@param b integer raw fixed-point factor
---@return integer rounded raw product
local function fxMulRound(a, b)
  return FxMath.fxMul(a, b)
end

-- Truncating fixed-point scale: exact signed product, C division toward
-- zero by 4096 (the retail magnet/convergence integer path, not FX_Mul).
---@param product integer exact signed product
---@return integer truncated raw value
local function truncScale12(product)
  return FxMath.truncDiv(FxMath.s32(product), 4096)
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
  local state = assert(sim.randomState, "particle simulation borrows its boot stream record")
  local seed = state.state --[[@as integer]]
  local seedLo = seed % 65536
  local seedHi = math.floor((seed - seedLo) / 65536)
  local low = seedLo * RNG_MULTIPLIER_LO
  local mid = seedLo * RNG_MULTIPLIER_HI + seedHi * RNG_MULTIPLIER_LO
  local next = ((low + (mid % 65536) * 65536 + RNG_INCREMENT) % 4294967296) --[[@as integer]]
  state.state = next
  sim.rng = next
  return next
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
  elseif circleAxis == 3 then
    -- spl_set_cross_to_axis: the emitter's own axis, normalized.
    local axis = record.axis --[[@as { x: number, y: number, z: number }]]
    ax, ay, az = normalize3(axis.x, axis.y, axis.z)
  end
  local bx, by, bz = 0, 1, 0
  if math.abs(ay) >= 1 - 1 / 8192 then
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
-- Kinds 10..15 execute no placement case: the pooled node's prior local
-- position is retained, zero before its first use.
---@param sim SplParticleSimulation
---@param runtime table<string, unknown> live emitter runtime gaining one particle
---@param node table<string, unknown> pooled particle node under initialization
---@param index integer zero-based index of this particle within its generation burst
---@param count integer particles the burst generates
---@return number px, number py, number pz, number? dirX, number? dirY, number? dirZ
local function placeParticle(sim, runtime, node, index, count)
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
  elseif initPosType >= 10 and initPosType <= 15 then
    -- Retained-pool behavior: no placement case executes, so the recycled
    -- node's local position survives; zeroed nodes start at the origin.
    return node.x, node.y, node.z
  end
  return 0, 0, 0
end

---@param sim SplParticleSimulation
---@param runtime table<string, unknown> live emitter runtime gaining one particle
---@param node table<string, unknown> pooled particle node under initialization
---@param index integer zero-based index of this particle within its generation burst
---@param count integer particles the burst generates
---@return table<string, unknown> initialized particle node
local function spawnParticle(sim, runtime, node, index, count)
  -- The caller allocates the pooled node before any placement draw, so a
  -- missing node never reaches this path and failed allocation consumes
  -- no random values.
  local record = runtime.record --[[@as table<string, unknown>]]
  local px, py, pz, dirX, dirY, dirZ = placeParticle(sim, runtime, node, index, count)
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
  local axis = runtime.axis --[[@as { x: number, y: number, z: number }]]
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
  local phase = 0
  if record.randomLoopPhase then
    phase = math.floor(rngNext(sim) / 16777216)
  end
  node.x, node.y, node.z = px, py, pz
  node.vx = nx * velPos / 4096 + axis.x * velAxis / 4096
  node.vy = ny * velPos / 4096 + axis.y * velAxis / 4096
  node.vz = nz * velPos / 4096 + axis.z * velAxis / 4096
  node.rtt, node.rttVel = rtt, rttVel
  node.life, node.age = life, 0
  node.diffLoop = math.floor(65535 / loopFrame) % 65536
  node.diffNoloop = math.floor(65535 / life) % 65536
  node.phase = phase
  node.baseScale = baseScale
  node.animScale = 4096
  node.colorRgb.r, node.colorRgb.g, node.colorRgb.b = pickedRgb.r, pickedRgb.g, pickedRgb.b
  node.baseAlpha = record.baseAlpha --[[@as integer]]
  node.animAlpha = 31
  node.texNo = texNo
  node.pid = 5
  node.ex = runtime.x --[[@as number]]
  node.ey = runtime.y --[[@as number]]
  node.ez = runtime.z --[[@as number]]
  return node
end

-- Spawns one child particle from a live parent: the parent position, its
-- velocity scaled by the velocity ratio plus a random spread, the scaled
-- base, and the child color or inherited color. Each spawn draws three
-- times, even when the spread magnitude is zero. Rotation kind 3 writes
-- neither rotation nor rotation velocity, retaining the pooled node's
-- prior values; other kinds write both fields.
---@param sim SplParticleSimulation
---@param runtime table<string, unknown> live emitter runtime
---@param parent table<string, unknown> live parent particle
---@param node table<string, unknown> pooled child node under initialization
local function spawnChild(sim, runtime, parent, node)
  local record = runtime.record --[[@as table<string, unknown>]]
  local child = record.child --[[@as table<string, unknown>]]
  local velRatio = child.velRatio --[[@as integer]]
  local spreadRawFx = worldToRawFx(child.initVelRandom --[[@as number]])
  local ratioFx = fxMulRound(velRatio * 4096, 16)
  local draws = {
    math.floor(rngNext(sim) / 8388608),
    math.floor(rngNext(sim) / 8388608),
    math.floor(rngNext(sim) / 8388608),
  }
  local parentVel = { parent.vx, parent.vy, parent.vz }
  local vel = {}
  for axis = 1, 3 do
    local scaled = fxMulRound(worldToRawFx(parentVel[axis] --[[@as number]]), ratioFx)
    vel[axis] = (scaled + math.floor((spreadRawFx * draws[axis] - spreadRawFx * 256) / 256)) / 4096
  end
  local scaledBase = math.floor(
    (
      worldToRawFx(parent.baseScale --[[@as integer]] / 4096) * parent.animScale --[[@as integer]]
    ) / 4096
  )
  local colorRgb = child.childColor --[[@as table<string, integer>]]
  if not child.useChildColor then
    local inherited = parent.colorRgb --[[@as table<string, integer>]]
    colorRgb = { r = inherited.r, g = inherited.g, b = inherited.b }
  end
  -- Rotation type 1 inherits the parent angle, 2 also its spin; absent
  -- means unrotated; 3 retains the pooled node's prior rotation pair.
  local rotationType = child.rotationType --[[@as integer|nil]]
  local rtt, rttVel = 0, 0
  if rotationType == 1 or rotationType == 2 then
    rtt = parent.rtt --[[@as integer]]
  elseif rotationType == 3 then
    rtt, rttVel = node.rtt, node.rttVel
  end
  if rotationType == 2 then
    rttVel = parent.rttVel --[[@as integer]]
  elseif rotationType == 3 then
    rttVel = node.rttVel
  end
  node.x, node.y, node.z = parent.x, parent.y, parent.z
  node.vx, node.vy, node.vz = vel[1], vel[2], vel[3]
  node.rtt, node.rttVel = rtt, rttVel
  node.life, node.age =
    child.life, --[[@as integer]]
    0
  node.diffLoop, node.diffNoloop = 0, 0
  node.phase = 0
  node.baseScale = math.floor(
    scaledBase
      * (
        child.sclRatio --[[@as integer]]
        + 1
      )
      / 64
  )
  node.animScale = 4096
  node.colorRgb.r, node.colorRgb.g, node.colorRgb.b = colorRgb.r, colorRgb.g, colorRgb.b
  node.baseAlpha = math.floor(
    parent.baseAlpha --[[@as integer]]
      * (
        parent.animAlpha --[[@as integer]]
        + 1
      )
      / 32
  )
  node.animAlpha = 31
  node.texNo = child.texNo --[[@as integer]]
  node.pid = 5
  node.ex, node.ey, node.ez = parent.ex, parent.ey, parent.ez
end

-- One convergence step on a single axis: the position plus the retail
-- rounded fixed-point product of the field ratio and the remaining distance.
---@param position number emitter-relative world position
---@param target number field world position
---@param ratio integer staged signed fx16 ratio
---@return number converged world position
local function convergeFx(position, target, ratio)
  local positionFx = worldToRawFx(position)
  return (positionFx + fxMulRound(ratio, worldToRawFx(target) - positionFx)) / 4096
end

-- Rotates a position about one source axis by a retail rotation step,
-- using the indexed sine/cosine lookup and the truncating matrix-vector
-- multiply (sums of signed products, arithmetic shift 12, no +2048 bias).
-- It rotates position only, never velocity.
---@param x number
---@param y number
---@param z number
---@param axis integer 0, 1, or 2
---@param rotation integer rotation step 0..65535
---@return number rx, number ry, number rz
local function spinRotate(x, y, z, axis, rotation)
  local sine = FxMath.sinIdx(rotation)
  local cosine = FxMath.cosIdx(rotation)
  local raw = { worldToRawFx(x), worldToRawFx(y), worldToRawFx(z) }
  local function row(a, b, c)
    return FxMath.s32(math.floor((a + b + c) / 4096))
  end
  if axis == 0 then
    return x, row(cosine * raw[2], -sine * raw[3], 0) / 4096, row(sine * raw[2], cosine * raw[3], 0) / 4096
  elseif axis == 1 then
    return row(cosine * raw[1], sine * raw[3], 0) / 4096, y, row(-sine * raw[1], cosine * raw[3], 0) / 4096
  end
  return row(cosine * raw[1], -sine * raw[2], 0) / 4096, row(sine * raw[1], cosine * raw[2], 0) / 4096, z
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

-- Runs the manager's shared field blocks over one particle in source
-- order: gravity adds its magnitudes to the acceleration, random fires on
-- its interval with three draws, magnet pulls with the truncating 32-bit
-- product, spin rotates the position only, collision clamps against its
-- plane, and convergence steps the position by its ratio. Gravity,
-- magnet, and random accumulate into the acceleration the later movement
-- consumes; spin, collision, and convergence rewrite the position and
-- velocity immediately. Returns the accumulated acceleration.
---@param sim SplParticleSimulation
---@param runtime table<string, unknown> live emitter runtime
---@param particle table<string, unknown> live particle under update
---@return number accX, number accY, number accZ field acceleration in world units
local function applyFields(sim, runtime, particle)
  local record = runtime.record --[[@as table<string, unknown>]]
  local accX, accY, accZ = 0, 0, 0
  local age = particle.age --[[@as integer]]
  for _, field in
    ipairs(record.fields --[[@as table<string, unknown>[] ]])
  do
    local entry = field --[[@as table<string, unknown>]]
    if entry.kind == "gravity" then
      local magnitude = entry.magnitude --[[@as { x: number, y: number, z: number }]]
      accX, accY, accZ = accX + magnitude.x, accY + magnitude.y, accZ + magnitude.z
    elseif entry.kind == "random" then
      local interval = entry.interval --[[@as integer]]
      if age % interval == 0 then
        -- Each axis draws once and adds the signed expression, even when
        -- the magnitude is zero, keeping the stream position sourced.
        local magnitude = entry.magnitude --[[@as { x: number, y: number, z: number }]]
        local axes = { "x", "y", "z" }
        local adds = { accX, accY, accZ }
        for axis = 1, 3 do
          local magRaw = worldToRawFx(magnitude[axes[axis]])
          local draw = math.floor(rngNext(sim) / 8388608)
          adds[axis] = adds[axis] + math.floor((magRaw * draw - magRaw * 256) / 256) / 4096
        end
        accX, accY, accZ = adds[1], adds[2], adds[3]
      end
    elseif entry.kind == "magnet" then
      -- The retail magnet is a truncating 32-bit product and shift, not a
      -- rounded FX_Mul: each axis adds magnitude*(target-position-velocity)
      -- scaled by 1/4096 toward zero.
      local target = entry.position --[[@as { x: number, y: number, z: number }]]
      local magRaw = worldToRawFx(entry.magnitude --[[@as number]])
      local deltas = {
        worldToRawFx(target.x) - worldToRawFx(particle.x --[[@as number]]) - worldToRawFx(particle.vx --[[@as number]]),
        worldToRawFx(target.y) - worldToRawFx(particle.y --[[@as number]]) - worldToRawFx(particle.vy --[[@as number]]),
        worldToRawFx(target.z) - worldToRawFx(particle.z --[[@as number]]) - worldToRawFx(particle.vz --[[@as number]]),
      }
      local adds = { accX, accY, accZ }
      for axis = 1, 3 do
        adds[axis] = adds[axis] + truncScale12(s32wrap(magRaw * deltas[axis])) / 4096
      end
      accX, accY, accZ = adds[1], adds[2], adds[3]
    elseif entry.kind == "convergence" then
      -- Pulls the emitter-relative position toward the field position by the
      -- staged ratio with the retail rounded fixed-point multiply.
      local target = entry.position --[[@as { x: number, y: number, z: number }]]
      local ratio = entry.ratio --[[@as integer]]
      particle.x = convergeFx(particle.x --[[@as number]], target.x, ratio)
      particle.y = convergeFx(particle.y --[[@as number]], target.y, ratio)
      particle.z = convergeFx(particle.z --[[@as number]], target.z, ratio)
    elseif entry.kind == "spin" then
      particle.x, particle.y, particle.z = spinRotate(
        particle.x --[[@as number]],
        particle.y --[[@as number]],
        particle.z --[[@as number]],
        entry.axis --[[@as integer]],
        entry.rotation --[[@as integer]]
      )
    elseif entry.kind == "collision" then
      local plane = worldToRawFx(entry.height --[[@as number]])
      local originRaw = worldToRawFx(particle.ey --[[@as number]])
      local localRaw = worldToRawFx(particle.y --[[@as number]])
      local worldRaw = originRaw + localRaw
      local crossed = (originRaw < plane and worldRaw > plane) or (originRaw >= plane and worldRaw < plane)
      if crossed then
        particle.y = (plane - originRaw) / 4096
        local response = entry.response --[[@as string]]
        if response == "kill" then
          particle.age = particle.life
        elseif response == "bounce" then
          local oldVel = worldToRawFx(particle.vy --[[@as number]])
          particle.vy = -fxMulRound(oldVel, entry.bounceFx --[[@as integer]]) / 4096
        end
      end
    end
  end
  return accX, accY, accZ
end

-- Assigns one particle its polygon identity for this calculation tick:
-- the manager fixed identity 5 when its fixed flag is set, otherwise the
-- current cycling identity, advancing and wrapping 63 to 6 afterwards.
-- Drawing consumes no identities and allocates none.
---@param sim SplParticleSimulation
---@param particle table<string, unknown> live particle under update
---@param fixed boolean fixed-identity flag behind this particle
local function assignPolygonId(sim, particle, fixed)
  if fixed then
    particle.pid = 5
    return
  end
  particle.pid = sim._nextPolygonId
  if sim._nextPolygonId >= 63 then
    sim._nextPolygonId = 6
  else
    sim._nextPolygonId = sim._nextPolygonId + 1
  end
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
  local rateLoop = math.floor(
    (
      particle.phase --[[@as integer]]
      + particle.diffLoop --[[@as integer]]
        * age
        / 256
    )
  ) % 256
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
  if record.followEmitter then
    particle.ex = runtime.x
    particle.ey = runtime.y
    particle.ez = runtime.z
  end
  local accX, accY, accZ = applyFields(sim, runtime, particle)
  moveParticle(particle, record.airResist --[[@as integer]], accX, accY, accZ)
  if record.child ~= nil then
    local child = record.child --[[@as table<string, unknown>]]
    local genStart = child.genStart --[[@as integer]]
    local genInterval = child.genInterval --[[@as integer]]
    local genNum = child.genNum --[[@as integer]]
    local life = particle.life --[[@as integer]]
    if genNum > 0 and genInterval > 0 then
      local since = age * 4096 - life * genStart * 16
      if since >= 0 and math.floor(since / 4096) % genInterval == 0 then
        for _ = 1, genNum do
          if #sim._freeParticles > 0 or liveParticleCount(sim) < MAX_PARTICLE_COUNT then
            local node = table.remove(sim._freeParticles, 1)
            assert(node ~= nil, "particle pool exhaustion matches its live count")
            spawnChild(sim, runtime, particle, node)
            runtime.children[#runtime.children + 1] = node
          end
        end
      end
    end
  end
  assignPolygonId(sim, particle, record.fixedPolygonId == true)
  -- A collision kill writes particle.age directly above; advance from the
  -- live value, not the entry snapshot, so the kill retires this tick.
  particle.age = (particle.age + 1) % 65536
end

-- Runs one child particle for a source tick: its life-rate scale/alpha
-- curves (or none), emitter tracking, the shared fields when its
-- affectFields flag is set, and motion. The animated scale stays in raw
-- fx16 units, starting at unity and interpolating toward the staged end
-- with truncating slopes; the renderer normalizes once. The child rate
-- wraps 256 back to 0 at age equal to life.
---@param sim SplParticleSimulation
---@param runtime table<string, unknown> live emitter runtime
---@param particle table<string, unknown> live child particle
local function updateChild(sim, runtime, particle)
  local record = runtime.record --[[@as table<string, unknown>]]
  local child = record.child --[[@as table<string, unknown>]]
  local age = particle.age --[[@as integer]]
  local life = particle.life --[[@as integer]]
  local rate = math.floor(age * 256 / life) % 256
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
  local accX, accY, accZ = 0, 0, 0
  if child.affectFields then
    accX, accY, accZ = applyFields(sim, runtime, particle)
  end
  moveParticle(particle, record.airResist --[[@as integer]], accX, accY, accZ)
  assignPolygonId(sim, particle, child.fixedPolygonId == true)
  particle.age = (particle.age + 1) % 65536
end

-- Clones one compiled emitter record for this manager: scalars and small
-- parameter tables copy, animation and texture bindings stay shared and
-- immutable, and the field blocks clone once so every emitter of this
-- resource ordinal mutates the same per-manager field state. The cached
-- payload, other managers, and other occurrences stay independent.
---@param record table<string, unknown> compiled emitter record
---@return table<string, unknown> per-manager mutable resource clone
local function cloneResource(record)
  local clone = {}
  for key, value in pairs(record) do
    clone[key] = value
  end
  local function copyVec(vec)
    if type(vec) ~= "table" then
      return vec
    end
    return { x = vec.x, y = vec.y, z = vec.z }
  end
  clone.position = copyVec(record.position)
  clone.axis = copyVec(record.axis)
  if type(record.velocityFx) == "table" then
    clone.velocityFx = { pos = record.velocityFx.pos, axis = record.velocityFx.axis }
  end
  if type(record.rotation) == "table" then
    clone.rotation = { min = record.rotation.min, max = record.rotation.max }
  end
  if type(record.generation) == "table" then
    clone.generation = { countFx = record.generation.countFx, interval = record.generation.interval }
  end
  if type(record.baseColorRgb) == "table" then
    local rgb = record.baseColorRgb --[[@as table<string, integer>]]
    clone.baseColorRgb = { r = rgb.r, g = rgb.g, b = rgb.b }
  end
  if type(record.texRepeat) == "table" then
    clone.texRepeat = { s = record.texRepeat.s, t = record.texRepeat.t }
  end
  if type(record.reverseTex) == "table" then
    clone.reverseTex = { s = record.reverseTex.s, t = record.reverseTex.t }
  end
  local fields = {}
  for index, field in
    ipairs(record.fields --[[@as table<string, unknown>[] ]])
  do
    local entry = field --[[@as table<string, unknown>]]
    local copy = { kind = entry.kind }
    for key, value in pairs(entry) do
      if key ~= "kind" then
        if type(value) == "table" then
          local vec = value --[[@as table<string, number>]]
          if vec.x ~= nil then
            copy[key] = { x = vec.x, y = vec.y, z = vec.z }
          else
            copy[key] = value
          end
        else
          copy[key] = value
        end
      end
    end
    fields[index] = copy
  end
  clone.fields = fields
  return clone
end

-- Zeroes one pooled particle node exactly once; later reuse preserves any
-- field the initialization path does not rewrite (retained local position
-- for placements 10..15 and the retained rotation pair for child kind 3).
---@return table<string, unknown> zeroed particle node
local function zeroParticleNode()
  return {
    x = 0,
    y = 0,
    z = 0,
    vx = 0,
    vy = 0,
    vz = 0,
    rtt = 0,
    rttVel = 0,
    life = 0,
    age = 0,
    diffLoop = 0,
    diffNoloop = 0,
    phase = 0,
    baseScale = 0,
    animScale = 4096,
    colorRgb = { r = 0, g = 0, b = 0 },
    baseAlpha = 0,
    animAlpha = 31,
    texNo = 0,
    pid = 5,
    ex = 0,
    ey = 0,
    ez = 0,
  }
end

---@param randomState table<string, integer> borrowed boot stream record shared by every manager of one boot
---@param emitterZOffset number z offset applied to every emitter position
---@param records table<string, unknown>[]? complete compiled emitter array for this loaded manager
---@return SplParticleSimulation
function M.new(randomState, emitterZOffset, records)
  assert(
    type(randomState) == "table"
      and type(randomState.state) == "number"
      and randomState.state % 1 == 0
      and randomState.state >= 0
      and randomState.state < 4294967296,
    "particle simulation borrows its boot stream record"
  )
  local owned = records or {}
  assert(type(owned) == "table", "particle simulation loads its manager resource array")
  local resources = {}
  for index, record in ipairs(owned) do
    resources[index] = cloneResource(record --[[@as table<string, unknown>]])
  end
  -- The retail heap zeroes every node exactly once, then pushes nodes in
  -- ascending memory order onto each inactive-list front; the first
  -- allocation therefore takes the highest-index node.
  local emitterNodes = {}
  local freeEmitters = {}
  for index = 1, MAX_EMITTER_COUNT do
    local node = { live = false }
    emitterNodes[index] = node
    table.insert(freeEmitters, 1, node)
  end
  local freeParticles = {}
  for _ = 1, MAX_PARTICLE_COUNT do
    table.insert(freeParticles, 1, zeroParticleNode())
  end
  local camera = {}
  for key, value in pairs(CAMERA_DEFAULTS) do
    camera[key] = value
  end
  return setmetatable({
    randomState = randomState,
    rng = randomState.state,
    emitters = {},
    emitterZOffset = emitterZOffset,
    records = owned,
    resources = resources,
    camera = camera,
    _emitterNodes = emitterNodes,
    _freeEmitters = freeEmitters,
    _freeParticles = freeParticles,
    _calcCycle = 0,
    _nextPolygonId = 6,
  }, M)
end

-- Adds one emitter runtime for the manager's resource ordinal: the shared
-- per-manager clone selects axis, initial position, generation, scale,
-- lifetime, velocity, alpha, color, and flags, copied into the runtime at
-- creation, while the field blocks stay in the shared clone. Returns nil
-- when all 20 emitter nodes are occupied, consuming no random draws.
---@param sim SplParticleSimulation
---@param resourceOrdinal integer zero-based ordinal into the manager resource array
---@param group string|nil consumer-owned group tag that advance may filter on
---@return table<string, unknown>|nil runtime live emitter runtime; its x, y, z may be moved by the owner
function M.addEmitter(sim, resourceOrdinal, group)
  assert(
    type(resourceOrdinal) == "number" and resourceOrdinal % 1 == 0 and resourceOrdinal >= 0,
    "particle creation names its manager resource ordinal"
  )
  local shared = sim.resources[resourceOrdinal + 1]
  if shared == nil then
    error("particle creation names an emitter ordinal outside its loaded manager: " .. tostring(resourceOrdinal), 0)
  end
  local node = table.remove(sim._freeEmitters, 1)
  if node == nil then
    return nil
  end
  -- The runtime record copies per-emitter defaults out of the shared
  -- clone; only the field blocks stay shared so a configured field write
  -- reaches every existing and future emitter of this ordinal.
  local shaped = {}
  for key, value in
    pairs(shared --[[@as table<string, unknown>]])
  do
    shaped[key] = value
  end
  local sharedAxis = shared.axis --[[@as { x: number, y: number, z: number }]]
  local axis = { x = sharedAxis.x, y = sharedAxis.y, z = sharedAxis.z }
  shaped.axis = axis
  local position = shared.position --[[@as { x: number, y: number, z: number }]]
  local runtime = {
    id = shared.id,
    ordinal = resourceOrdinal,
    group = group,
    record = shaped,
    resource = shared,
    axis = axis,
    age = 0,
    started = false,
    carry = 0,
    x = position.x,
    y = position.y,
    z = position.z + sim.emitterZOffset,
    frame = circleFrame(shaped),
    particles = {},
    children = {},
    quad = nil,
    _node = node,
  }
  node.live = true
  node.runtime = runtime
  sim.emitters[#sim.emitters + 1] = runtime
  return runtime
end

---@param sim SplParticleSimulation
---@param runtime table<string, unknown> runtime returned by addEmitter
---@return boolean live true while the emitter is still in the simulation
function M.hasEmitter(sim, runtime)
  for _, live in ipairs(sim.emitters) do
    if live == runtime then
      return true
    end
  end
  return false
end

-- Removes one emitter and returns every parent node, then every child
-- node, then the emitter node to their inactive fronts, as the retail
-- emitter deletion does. Removing a runtime that already left is a no-op.
---@param sim SplParticleSimulation
---@param runtime table<string, unknown> runtime returned by addEmitter
function M.removeEmitter(sim, runtime)
  for index, live in ipairs(sim.emitters) do
    if live == runtime then
      table.remove(sim.emitters, index)
      for particleIndex = #runtime.particles, 1, -1 do
        table.insert(sim._freeParticles, 1, runtime.particles[particleIndex])
      end
      for childIndex = #runtime.children, 1, -1 do
        table.insert(sim._freeParticles, 1, runtime.children[childIndex])
      end
      runtime.particles = {}
      runtime.children = {}
      local node = runtime._node
      if type(node) == "table" then
        node.live = false
        node.runtime = nil
        table.insert(sim._freeEmitters, 1, node)
      end
      return
    end
  end
end

---@param sim SplParticleSimulation
---@param group string|nil only emitters of this group advance; nil advances every emitter
function M.advance(sim, group)
  -- Younger emitters update first in the retail newest-first walk; the
  -- live list stays oldest-first and every traversal runs in reverse.
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
            if #sim._freeParticles > 0 then
              local node = table.remove(sim._freeParticles, 1)
              assert(node ~= nil, "particle pool exhaustion matches its live count")
              if spawnParticle(sim, runtime, node, burstIndex, due) ~= nil then
                runtime.particles[#runtime.particles + 1] = node
              else
                table.insert(sim._freeParticles, 1, node)
              end
            end
          end
        end
      end
      -- Youngest particles update first: newborns join at the back of the
      -- live list and update on their birth tick in reverse traversal.
      for particleIndex = #runtime.particles, 1, -1 do
        local particle = runtime.particles[particleIndex]
        updateParticle(sim, runtime, particle)
        if
          particle.age --[[@as integer]]
          > particle.life --[[@as integer]]
        then
          table.remove(runtime.particles, particleIndex)
          table.insert(sim._freeParticles, 1, particle)
        end
      end
      for childIndex = #runtime.children, 1, -1 do
        local childParticle = runtime.children[childIndex]
        updateChild(sim, runtime, childParticle)
        if
          childParticle.age --[[@as integer]]
          > childParticle.life --[[@as integer]]
        then
          table.remove(runtime.children, childIndex)
          table.insert(sim._freeParticles, 1, childParticle)
        end
      end
      runtime.age = (
        runtime.age --[[@as integer]]
        + 1
      ) % 65536
      -- Self-destroying emitters leave the active set once their age
      -- passes their lifespan and their last particle retires; persistent
      -- emitters stay until their owner removes them. A zero life means
      -- infinite generation until stopped or deleted.
      if
        not record.persistent
        and emitterLife ~= 0
        and runtime.started
        and runtime.age --[[@as integer]]
          > emitterLife
        and #runtime.particles == 0
        and #runtime.children == 0
      then
        table.remove(sim.emitters, index)
        for particleIndex = #runtime.particles, 1, -1 do
          table.insert(sim._freeParticles, 1, runtime.particles[particleIndex])
        end
        for childIndex = #runtime.children, 1, -1 do
          table.insert(sim._freeParticles, 1, runtime.children[childIndex])
        end
        local node = runtime._node
        if type(node) == "table" then
          node.live = false
          node.runtime = nil
          table.insert(sim._freeEmitters, 1, node)
        end
      end
    end
  end
  sim._calcCycle = 1 - sim._calcCycle
end

-- One detached pre-advance particle of a draw copy: every scalar the
-- primitive producer reads, with the color triple detached so later
-- simulation writes never alias the published frame.
---@param particle table<string, unknown> live particle under capture
---@return table<string, unknown> detached particle copy for drawing only
local function copyDrawParticle(particle)
  local color = particle.colorRgb --[[@as table<string, integer>?]]
  return {
    x = particle.x,
    y = particle.y,
    z = particle.z,
    vx = particle.vx,
    vy = particle.vy,
    vz = particle.vz,
    rtt = particle.rtt,
    rttVel = particle.rttVel,
    life = particle.life,
    age = particle.age,
    diffLoop = particle.diffLoop,
    diffNoloop = particle.diffNoloop,
    phase = particle.phase,
    baseScale = particle.baseScale,
    animScale = particle.animScale,
    colorRgb = color ~= nil and { r = color.r, g = color.g, b = color.b } or { r = 31, g = 31, b = 31 },
    baseAlpha = particle.baseAlpha,
    animAlpha = particle.animAlpha,
    texNo = particle.texNo,
    pid = particle.pid,
    ex = particle.ex,
    ey = particle.ey,
    ez = particle.ez,
  }
end

-- Detached pre-advance draw copy of one manager: the emitter runtimes
-- with copied particle lists and a copied camera, sharing only the
-- immutable compiled records, resources, frames, and texture handles.
-- The primitive producer reads exactly this shape, so the compositor can
-- paint the published copy while the live simulation advances underneath.
---@param sim SplParticleSimulation live simulation under capture
---@return { emitters: table<string, unknown>[], camera: table<string, unknown> } detached draw copy
function M.copyForDraw(sim)
  assert(type(sim) == "table" and type(sim.emitters) == "table", "draw copies capture a live simulation")
  local cameraCopy = {}
  local camera = sim.camera
  if type(camera) == "table" then
    for key, value in pairs(camera) do
      cameraCopy[key] = value
    end
  end
  local emitters = {}
  for _, runtime in ipairs(sim.emitters) do
    local particles = {}
    for _, particle in ipairs(runtime.particles) do
      particles[#particles + 1] = copyDrawParticle(particle)
    end
    local children = {}
    for _, child in ipairs(runtime.children) do
      children[#children + 1] = copyDrawParticle(child)
    end
    emitters[#emitters + 1] = {
      id = runtime.id,
      ordinal = runtime.ordinal,
      group = runtime.group,
      record = runtime.record,
      resource = runtime.resource,
      axis = runtime.axis,
      age = runtime.age,
      started = runtime.started,
      carry = runtime.carry,
      x = runtime.x,
      y = runtime.y,
      z = runtime.z,
      frame = runtime.frame,
      particles = particles,
      children = children,
      quad = runtime.quad,
    }
  end
  return { emitters = emitters, camera = cameraCopy }
end

return M
