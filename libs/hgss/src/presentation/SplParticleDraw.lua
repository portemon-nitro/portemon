-- Projects SplParticleSimulation particles into a 2D destination pane
-- through the single shared primitive producer (spl_draw.c,
-- spl_draw_ptcl.c): draw consumes appendPrimitives clip-space output and
-- maps it onto the pane the host centers at its origin, far-first.
-- Hardware depth testing is approximated by far-first painter ordering.
-- Every draw type the producer emits draws; children draw with their own
-- texture and the emitter's scale parameters; an emitter's hideParent
-- flag draws only its children.

local FxMath = require("libs.hgss.src.presentation.PresentationFxMath")

local M = {}

-- Repeat quads keyed by stable resolved handle, then source dimensions
-- and repeat powers; they hold no image, so the entries release with
-- the handle. Dimensions ride the key so a recycled handle never
-- serves a stale viewport.
local quadsByImage = setmetatable({}, { __mode = "k" })

-- Measures one resolved texture handle: pool leases carry their source
-- dimensions directly, raw images answer through their getters. Anything
-- else fails naming the expected handle shapes instead of drawing garbage.
---@param drawable table<string, unknown>|userdata resolved texture handle
---@return number width source width in pixels
---@return number height source height in pixels
local function textureDimensions(drawable)
  local drawableType = type(drawable)
  assert(
    drawableType == "table" or drawableType == "userdata",
    "particle textures resolve to a pool lease or a raw image"
  )
  if type(drawable.drawQuad) == "function" then
    local width, height = drawable.width, drawable.height
    assert(type(width) == "number" and type(height) == "number", "pooled particle leases carry their source dimensions")
    return width, --[[@as number]]
      height --[[@as number]]
  end
  local getWidth, getHeight = drawable.getWidth, drawable.getHeight
  assert(
    type(getWidth) == "function" and type(getHeight) == "function",
    "particle textures resolve to a pool lease or a raw image"
  )
  return getWidth(drawable), getHeight(drawable)
end

-- Draws one resolved texture handle with a caller viewport: pool leases
-- draw through their palette-exact sampler (a raw draw of indexed pixels
-- would show palette indices as color), raw images draw directly. The
-- transform arguments are identical on both routes.
---@param graphics table<string, function> love-like graphics namespace
---@param drawable table<string, unknown>|userdata resolved texture handle
---@param quad love.Quad caller-owned viewport
---@param x number
---@param y number
---@param rotation number|nil
---@param sx number
---@param sy number
---@param ox number
---@param oy number
local function drawTextureQuad(graphics, drawable, quad, x, y, rotation, sx, sy, ox, oy)
  if type(drawable.drawQuad) == "function" then
    drawable:drawQuad(graphics, quad, x, y, rotation, sx, sy, ox, oy)
    return
  end
  graphics.draw(drawable, quad, x, y, rotation, sx, sy, ox, oy)
end

---@param graphics table<string, function> love-like graphics namespace
---@param drawable table<string, unknown>|userdata resolved texture handle
---@param repS integer horizontal repeat power
---@param repT integer vertical repeat power
---@return love.Quad, number, number
local function repeatQuad(graphics, drawable, repS, repT)
  local width, height = textureDimensions(drawable)
  local quads = quadsByImage[drawable]
  if quads == nil then
    quads = {}
    quadsByImage[drawable] = quads
  end
  local key = width .. "x" .. height .. ":" .. repS .. ":" .. repT
  local entry = quads[key]
  if entry == nil then
    local quadWidth, quadHeight = width * (2 ^ repS), height * (2 ^ repT)
    entry = { graphics.newQuad(0, 0, quadWidth, quadHeight, width, height), quadWidth, quadHeight }
    quads[key] = entry
  end
  return entry[1], entry[2], entry[3]
end

---@class SplParticleDrawOptions
---@field centerX number pane pixel x of the world origin
---@field centerY number pane pixel y of the world origin
---@field resolveTexture fun(runtime: table<string, unknown>, particle: table<string, unknown>, child: table<string, unknown>|nil): table<string, unknown>|userdata|nil
---   texture handle the particle shows: a pool lease or a raw image; child is the emitter's child record for child particles. A nil handle skips the particle.

-- Draws every live particle of the simulation in far-to-near order and
-- restores the draw color. Texture repeat comes from the emitter (or child)
-- record; the handle already carries its repeat sampler from acquisition,
-- so drawing never mutates it.
-- A record `textureOffset` shifts the quad center within the particle's local
-- space by (x, y) half-extents, as the retail quad is drawn around that point.
---@class SplParticlePrimitiveVertex
---@field clipX number homogeneous x before the host Y flip
---@field clipY number homogeneous y before the host Y flip
---@field clipZ number homogeneous z
---@field clipW number preserved homogeneous w
---@field u number normalized texture u
---@field v number normalized texture v

---@class SplParticlePrimitive
---@field vertices SplParticlePrimitiveVertex[] four homogeneous clip-space corners
---@field color5 { r: integer, g: integer, b: integer } source RGB5 vertex color
---@field alpha5 integer effective 5-bit alpha
---@field polygonId integer fixed or cycling polygon identity
---@field material table<string, unknown>|userdata|nil texture handle and sampler metadata
---@field submissionOrdinal integer native submission order
---@field flags table<string, unknown> source polygon flags

-- Repeat span for one primitive: the source texRepeat powers tile the
-- quad (2^s by 2^t), independent from the texture-header sampler; the
-- signed mirror flags negate the span on their axis. The texture matrix
-- scales these spans by the selected texture dimensions at sampling.
---@param record table<string, unknown> emitter record
---@param child table<string, unknown>? child record for child particles
---@return number s horizontal UV span
---@return number t vertical UV span
local function uvSpan(record, child)
  local entry = child or record
  local repeatPowers = entry.texRepeat
  local repS, repT = 0, 0
  if type(repeatPowers) == "table" then
    repS = repeatPowers.s or 0
    repT = repeatPowers.t or 0
  end
  local reverse = entry.reverseTex
  local s, t = 2 ^ repS, 2 ^ repT
  if type(reverse) == "table" then
    if reverse.s then
      s = -s
    end
    if reverse.t then
      t = -t
    end
  end
  return s, t
end

-- Fixed helpers behind the primitive producer: world floats enter as
-- binary-exact multiples of 1/4096 and convert to raw once. Staged
-- cameras mix world and raw units across callers, so small position
-- values scale to raw while large raw values pass through.
local function toRawWorld(value)
  local scaled = (value or 0) * 4096
  if scaled >= 0 then
    return FxMath.s32(math.floor(scaled + 0.5))
  end
  return FxMath.s32(math.ceil(scaled - 0.5))
end

local function camToRaw(value)
  local number = value or 0
  if math.abs(number) < 2000 then
    return toRawWorld(number)
  end
  return FxMath.s32(number)
end

-- Builds the manager view and projection pair behind one primitive batch.
-- An explicit camera wins; otherwise the simulation manager camera feeds
-- the projection. Perspective 0 uses the perspective form, anything else
-- the orthographic form with extents from the half field of view.
function M.cameraViewProjection(simulation, camera)
  local cam = camera or simulation.camera or {}
  local eye = { x = camToRaw(cam.x), y = camToRaw(cam.y), z = camToRaw(cam.z) }
  local target = { x = camToRaw(cam.targetX), y = camToRaw(cam.targetY), z = camToRaw(cam.targetZ) }
  local upY = cam.upY == nil and 4096 or cam.upY
  local up = { x = camToRaw(cam.upX), y = camToRaw(upY), z = camToRaw(cam.upZ) }
  local view = FxMath.lookAtView(eye, target, up)
  local perspective = cam.perspective or 0
  local nearPlane = camToRaw(cam.near == nil and 4096 or cam.near)
  local farPlane = camToRaw(cam.far == nil and 3686400 or cam.far)
  local halfFov = cam.halfFov or 8192
  local aspect = camToRaw(cam.aspect or 5461)
  local distance = camToRaw(cam.distance or 16384)
  local sinHalf = FxMath.sinIdx(halfFov)
  local cosHalf = FxMath.cosIdx(halfFov)
  if perspective == 1 then
    local extentY = FxMath.fxMul(FxMath.fxDiv(sinHalf, cosHalf), distance)
    local extentX = FxMath.fxMul(extentY, aspect)
    return view, FxMath.orthoW(extentY, FxMath.s32(-extentY), FxMath.s32(-extentX), extentX, nearPlane, farPlane, 4096)
  end
  return view, FxMath.perspectiveW(nearPlane, farPlane, sinHalf, cosHalf, aspect, 4096)
end

-- Pure source-order primitive production shared by the battle pass and the
-- retained sibling overlay wrapper: one record per native particle
-- polygon with homogeneous clip-space positions, normalized UVs, and
-- material state, in native submission order. Host drawing never re-sorts
-- it and simulation never advances while producing it. Alpha-zero
-- particles append no polygon.
-- Emitter scale pair for one particle: the base times the parent aspect,
-- then the animated scale on the axes the draw mode animates. Billboard
-- quads animate Y for any direction at or above 2; directional and
-- polygon quads only animate the named 0/1/2 directions.
local function particleScales(record, particle, drawType)
  local base = particle.baseScale or 4096
  local anim = particle.animScale or 4096
  local aspect = toRawWorld(record.aspect or 1)
  local sx = FxMath.fxMul(FxMath.s32(base), aspect)
  local sy = FxMath.s32(base)
  local direct = record.sclAnmDirect or 0
  if drawType == 0 then
    if direct == 0 then
      sx = FxMath.fxMul(sx, FxMath.s32(anim))
      sy = FxMath.fxMul(sy, FxMath.s32(anim))
    elseif direct == 1 then
      sx = FxMath.fxMul(sx, FxMath.s32(anim))
    else
      sy = FxMath.fxMul(sy, FxMath.s32(anim))
    end
  else
    if direct == 0 then
      sx = FxMath.fxMul(sx, FxMath.s32(anim))
      sy = FxMath.fxMul(sy, FxMath.s32(anim))
    elseif direct == 1 then
      sx = FxMath.fxMul(sx, FxMath.s32(anim))
    elseif direct == 2 then
      sy = FxMath.fxMul(sy, FxMath.s32(anim))
    end
  end
  return sx, sy
end

-- Local quad corners for one particle: the parent offset rides the XY
-- quad, children center on the origin, and the XZ plane swaps the second
-- coordinate to depth. Every component passes through the hardware quad
-- packing before any matrix.
local function localCorners(record, child, plane)
  local offX, offY = 0, 0
  if child == nil and type(record.textureOffset) == "table" then
    offX = toRawWorld(record.textureOffset.x or 0)
    offY = toRawWorld(record.textureOffset.y or 0)
  end
  local corners
  if plane == "xz" then
    corners = {
      { x = offX - 4096, y = 0, z = offY + 4096 },
      { x = offX + 4096, y = 0, z = offY + 4096 },
      { x = offX + 4096, y = 0, z = offY - 4096 },
      { x = offX - 4096, y = 0, z = offY - 4096 },
    }
  else
    corners = {
      { x = offX - 4096, y = offY + 4096, z = 0 },
      { x = offX + 4096, y = offY + 4096, z = 0 },
      { x = offX + 4096, y = offY - 4096, z = 0 },
      { x = offX - 4096, y = offY - 4096, z = 0 },
    }
  end
  for _, corner in ipairs(corners) do
    corner.x = FxMath.vtx10Quantize(corner.x)
    corner.y = FxMath.vtx10Quantize(corner.y)
    corner.z = FxMath.vtx10Quantize(corner.z)
  end
  return corners
end

local function resourceBase(record, runtime)
  local source = (runtime.resource or {}).position or record.position
  if type(source) ~= "table" then
    return { x = 0, y = 0, z = 0 }
  end
  return { x = toRawWorld(source.x), y = toRawWorld(source.y), z = toRawWorld(source.z) }
end

local function worldRaw(particle)
  return {
    x = toRawWorld((particle.x or 0) + (particle.ex or 0)),
    y = toRawWorld((particle.y or 0) + (particle.ey or 0)),
    z = toRawWorld((particle.z or 0) + (particle.ez or 0)),
  }
end

local function rotationY(sin, cos)
  return { cos, 0, FxMath.s32(-sin), 0, 4096, 0, sin, 0, cos }
end

local function rotationDiagonal(sin, cos)
  local a = FxMath.fxMul(FxMath.s32(4096 - cos), 1365)
  local b = FxMath.fxMul(sin, 2365)
  local d = FxMath.s32(a + cos)
  local p = FxMath.s32(a + b)
  local n = FxMath.s32(a - b)
  return { d, n, p, p, d, n, n, p, d }
end

local function polygonRotation(axis, sin, cos)
  if axis == "diagonal" then
    return rotationDiagonal(sin, cos)
  end
  return rotationY(sin, cos)
end

-- Projects one particle quad to clip space: selects the draw mode, builds
-- the local-to-view matrix in source order, then projects each corner.
-- Directional billboards with a zero velocity cross draw nothing. Parent
-- matrices scale before rotating; child matrices rotate before scaling.
function M.particleClipQuad(runtime, particle, child, view, proj)
  local record = runtime.record
  local entry = child or record
  local drawType = entry.drawType or 0
  local plane = entry.polygonPlane or "xy"
  local rotationAxis = entry.polygonRotationAxis or "y"
  local sx, sy = particleScales(record, particle, drawType)
  local corners = localCorners(record, child, plane)
  local world = worldRaw(particle)
  local base = resourceBase(record, runtime)
  local offset = record.cameraOffset == true
  if drawType == 0 or drawType == 1 then
    local viewOrigin
    if offset then
      local shifted =
        { x = FxMath.s32(world.x - base.x), y = FxMath.s32(world.y - base.y), z = FxMath.s32(world.z - base.z) }
      local moved = FxMath.viewPoint(view, shifted)
      viewOrigin =
        { x = FxMath.s32(moved.x + base.x), y = FxMath.s32(moved.y + base.y), z = FxMath.s32(moved.z + base.z) }
    else
      viewOrigin = FxMath.viewPoint(view, world)
    end
    local matrix
    if drawType == 0 then
      local sin = FxMath.sinIdx(particle.rtt or 0)
      local cos = FxMath.cosIdx(particle.rtt or 0)
      matrix = {
        FxMath.fxMul(cos, sx),
        FxMath.fxMul(sin, sx),
        0,
        FxMath.fxMul(FxMath.s32(-sin), sy),
        FxMath.fxMul(cos, sy),
        0,
        0,
        0,
        4096,
        viewOrigin.x,
        viewOrigin.y,
        viewOrigin.z,
      }
    else
      local vel =
        { x = toRawWorld(particle.vx or 0), y = toRawWorld(particle.vy or 0), z = toRawWorld(particle.vz or 0) }
      local camZ = { x = view[3], y = view[6], z = view[9] }
      local cross = FxMath.vecCross32({ x = vel.x, y = vel.y, z = vel.z }, camZ)
      if cross.x == 0 and cross.y == 0 and cross.z == 0 then
        return nil
      end
      local nx, ny, nz = FxMath.normalize32(cross.x, cross.y, cross.z)
      local nvx, nvy, nvz = FxMath.normalize32(vel.x, vel.y, vel.z)
      local dot = FxMath.s32(
        FxMath.fxMul(nvx, FxMath.s32(-camZ.x))
          + FxMath.fxMul(nvy, FxMath.s32(-camZ.y))
          + FxMath.fxMul(nvz, FxMath.s32(-camZ.z))
      )
      if dot < 0 then
        dot = FxMath.s32(-dot)
      end
      local dbb = record.dbbScale or 0
      local stretched = FxMath.fxMul(sy, FxMath.s32(FxMath.fxMul(FxMath.s32(4096 - dot), FxMath.s32(dbb)) + 4096))
      local dx = FxMath.s32(math.floor((nx * view[1] + ny * view[2] + nz * view[3]) / 4096))
      local dy = FxMath.s32(math.floor((nx * view[4] + ny * view[5] + nz * view[6]) / 4096))
      matrix = {
        FxMath.fxMul(dx, sx),
        FxMath.fxMul(dy, sx),
        0,
        FxMath.fxMul(FxMath.s32(-dy), stretched),
        FxMath.fxMul(dx, stretched),
        0,
        0,
        0,
        4096,
        viewOrigin.x,
        viewOrigin.y,
        viewOrigin.z,
      }
    end
    local quad = {}
    for index, corner in ipairs(corners) do
      local moved = FxMath.matVec43(matrix, corner)
      quad[index] = FxMath.projectViewPoint(moved, proj)
    end
    return quad
  end
  local sin = FxMath.sinIdx(particle.rtt or 0)
  local cos = FxMath.cosIdx(particle.rtt or 0)
  local rotation = polygonRotation(rotationAxis, sin, cos)
  if drawType == 3 then
    local fromCenter = entry.directionFromCenter == true
    local direction
    if fromCenter then
      local localPos =
        { x = toRawWorld(particle.x or 0), y = toRawWorld(particle.y or 0), z = toRawWorld(particle.z or 0) }
      local nx, ny, nz = FxMath.normalize32(localPos.x, localPos.y, localPos.z)
      direction = { x = FxMath.s32(-nx), y = FxMath.s32(-ny), z = FxMath.s32(-nz) }
    else
      local vel =
        { x = toRawWorld(particle.vx or 0), y = toRawWorld(particle.vy or 0), z = toRawWorld(particle.vz or 0) }
      local nx, ny, nz = FxMath.normalize32(vel.x, vel.y, vel.z)
      direction = { x = nx, y = ny, z = nz }
    end
    local up = { x = 0, y = 4096, z = 0 }
    local steep = FxMath.vecDot32(direction, up)
    if steep > 3277 or steep < -3277 then
      up = { x = 4096, y = 0, z = 0 }
    end
    local cross1 = FxMath.vecCross32(direction, up)
    local cross2 = FxMath.vecCross32(direction, cross1)
    local basis = { cross1.x, cross1.y, cross1.z, direction.x, direction.y, direction.z, cross2.x, cross2.y, cross2.z }
    rotation = FxMath.concat33(rotation, basis)
  end
  local scale = { sx, 0, 0, 0, sy, 0, 0, 0, sy }
  local combined
  if child ~= nil then
    combined = FxMath.concat33(rotation, scale)
  else
    combined = FxMath.concat33(scale, rotation)
  end
  local affine = {
    combined[1],
    combined[2],
    combined[3],
    combined[4],
    combined[5],
    combined[6],
    combined[7],
    combined[8],
    combined[9],
    world.x,
    world.y,
    world.z,
  }
  local quad = {}
  for index, corner in ipairs(corners) do
    local placed = FxMath.matVec43(affine, corner)
    local viewed
    if offset then
      local shifted =
        { x = FxMath.s32(placed.x - base.x), y = FxMath.s32(placed.y - base.y), z = FxMath.s32(placed.z - base.z) }
      local moved = FxMath.viewPoint(view, shifted)
      viewed = { x = FxMath.s32(moved.x + base.x), y = FxMath.s32(moved.y + base.y), z = FxMath.s32(moved.z + base.z) }
    else
      viewed = FxMath.viewPoint(view, placed)
    end
    quad[index] = FxMath.projectViewPoint(viewed, proj)
  end
  return quad
end

---@param simulation SplParticleSimulation captured simulation state, never advanced here
---@param camera table<string, unknown>? current system camera (kept for the full camera-aware geometry)
---@param resolveTexture fun(runtime: table<string, unknown>, particle: table<string, unknown>, child: table<string, unknown>|nil): table<string, unknown>|userdata|nil texture handle per particle
---@param out SplParticlePrimitive[]? caller-owned storage the records append to
---@return SplParticlePrimitive[] ordered primitive array
function M.appendPrimitives(simulation, camera, resolveTexture, out)
  local primitives = out or {}
  local view, proj = M.cameraViewProjection(simulation, camera)
  local ordinal = #primitives
  local function append(runtime, particle, child, spanS, spanT)
    local effective = math.floor(particle.baseAlpha * (particle.animAlpha + 1) / 32)
    if effective <= 0 then
      return
    end
    local quad = M.particleClipQuad(runtime, particle, child, view, proj)
    if quad == nil then
      return
    end
    ordinal = ordinal + 1
    local color = particle.colorRgb or { r = 31, g = 31, b = 31 }
    local s, t = spanS or 1, spanT or 1
    primitives[#primitives + 1] = {
      vertices = {
        { clipX = quad[1].x, clipY = quad[1].y, clipZ = quad[1].z, clipW = quad[1].w, u = 0, v = 0 },
        { clipX = quad[2].x, clipY = quad[2].y, clipZ = quad[2].z, clipW = quad[2].w, u = s, v = 0 },
        { clipX = quad[3].x, clipY = quad[3].y, clipZ = quad[3].z, clipW = quad[3].w, u = s, v = t },
        { clipX = quad[4].x, clipY = quad[4].y, clipZ = quad[4].z, clipW = quad[4].w, u = 0, v = t },
      },
      color5 = { r = color.r, g = color.g, b = color.b },
      alpha5 = effective,
      polygonId = particle.pid or 5,
      material = resolveTexture ~= nil and resolveTexture(runtime, particle, child) or nil,
      submissionOrdinal = ordinal,
      flags = { cullMode = "none", fogEnabled = false, translucentDepthWrite = false, depthEqual = false },
    }
  end
  for emitterIndex = #simulation.emitters, 1, -1 do
    local runtime = simulation.emitters[emitterIndex]
    local childFirst = runtime.record.drawChildFirst == true
    local childRecord = runtime.record.child
    local parentS, parentT = uvSpan(runtime.record, nil)
    local childS, childT = uvSpan(runtime.record, childRecord)
    if childFirst then
      for childIndex = #runtime.children, 1, -1 do
        append(runtime, runtime.children[childIndex], childRecord, childS, childT)
      end
    end
    if not runtime.record.hideParent then
      for particleIndex = #runtime.particles, 1, -1 do
        append(runtime, runtime.particles[particleIndex], nil, parentS, parentT)
      end
    end
    if not childFirst then
      for childIndex = #runtime.children, 1, -1 do
        append(runtime, runtime.children[childIndex], childRecord, childS, childT)
      end
    end
  end
  return primitives
end

-- Repeat power behind one primitive UV span: the source repeat powers
-- tile the quad by exact powers of two, so the span magnitude recovers
-- them; the sign only mirrors sampling and never changes the viewport.
---@param span number|nil primitive UV span along one axis
---@return integer repeat power tiling the sampled viewport
local function repeatPower(span)
  local magnitude = math.abs(span or 1)
  if magnitude < 1 then
    return 0
  end
  return math.floor(math.log(magnitude) / math.log(2) + 0.5)
end

-- Draws every primitive the shared producer emits, mapped into the
-- destination pane and restored to the draw color. The pane spans twice
-- the center on each axis with the host Y flip, matching the battle
-- composition's normalized mapping. Primitives behind the camera or with
-- no resolved texture draw nothing; the rest paint far-first with native
-- submission order breaking depth ties. The quad transform is recovered
-- from the projected corners, so billboard rotation, directional
-- stretch, polygon orientation, and texture offsets arrive through the
-- producer instead of a parallel geometry path.
---@param graphics table<string, function> love-like graphics namespace
---@param simulation SplParticleSimulation captured simulation state, never advanced here
---@param options SplParticleDrawOptions
function M.draw(graphics, simulation, options)
  local centerX, centerY = options.centerX, options.centerY
  assert(type(centerX) == "number" and type(centerY) == "number", "particle panes center their destination rect")
  local primitives = M.appendPrimitives(simulation, nil, options.resolveTexture)
  local ordered = {}
  for _, primitive in ipairs(primitives) do
    if primitive.material ~= nil then
      local corners = {}
      local depth = 0
      local usable = true
      for _, vertex in ipairs(primitive.vertices) do
        local w = vertex.clipW
        if type(w) ~= "number" or w <= 0 then
          usable = false
          break
        end
        local px = centerX + (vertex.clipX / w) * centerX
        local py = centerY - (vertex.clipY / w) * centerY
        if px ~= px or py ~= py then
          usable = false
          break
        end
        corners[#corners + 1] = { x = px, y = py }
        depth = depth + vertex.clipZ / w
      end
      if usable then
        ordered[#ordered + 1] = { primitive = primitive, corners = corners, depth = depth / #corners }
      end
    end
  end
  table.sort(ordered, function(a, b)
    if a.depth ~= b.depth then
      return a.depth > b.depth
    end
    return a.primitive.submissionOrdinal < b.primitive.submissionOrdinal
  end)
  for _, entry in ipairs(ordered) do
    local primitive = entry.primitive
    local corners = entry.corners
    local image = primitive.material
    local quad, quadWidth, quadHeight =
      repeatQuad(graphics, image, repeatPower(primitive.vertices[2].u), repeatPower(primitive.vertices[3].v))
    local axisX = {
      x = ((corners[2].x - corners[1].x) + (corners[3].x - corners[4].x)) / 2,
      y = ((corners[2].y - corners[1].y) + (corners[3].y - corners[4].y)) / 2,
    }
    local axisY = {
      x = ((corners[4].x - corners[1].x) + (corners[3].x - corners[2].x)) / 2,
      y = ((corners[4].y - corners[1].y) + (corners[3].y - corners[2].y)) / 2,
    }
    local color = primitive.color5
    graphics.setColor(color.r / 31, color.g / 31, color.b / 31, primitive.alpha5 / 31)
    drawTextureQuad(
      graphics,
      image,
      quad,
      (corners[1].x + corners[2].x + corners[3].x + corners[4].x) / 4,
      (corners[1].y + corners[2].y + corners[3].y + corners[4].y) / 4,
      math.atan2(axisX.y, axisX.x),
      math.sqrt(axisX.x * axisX.x + axisX.y * axisX.y) / quadWidth,
      math.sqrt(axisY.x * axisY.x + axisY.y * axisY.y) / quadHeight,
      quadWidth / 2,
      quadHeight / 2
    )
  end
  graphics.setColor(1, 1, 1, 1)
end

return M
