-- Draws SplParticleSimulation particles as 2D billboards under the retail
-- default particle camera (spl_draw.c, spl_draw_ptcl.c): an orthographic
-- projection of 24 pixels per world unit centered on the pane origin, depth
-- clipped to 1..900 from a camera 4 units out. Hardware depth testing is
-- approximated by far-first painter ordering. Billboards and directional
-- billboards (draw type 1) are supported; children always draw as billboards
-- with their own texture.

local M = {}

local PX_PER_UNIT = 24
local DEPTH_NEAR, DEPTH_FAR = 1, 900
local CAMERA_DISTANCE = 4

-- Repeat quads keyed by image and repeat powers; they hold no image, so the
-- entries release with the image.
local quadsByImage = setmetatable({}, { __mode = "k" })

---@param graphics table<string, function> love-like graphics namespace
---@param image love.Image
---@param repS integer horizontal repeat power
---@param repT integer vertical repeat power
---@return love.Quad, number, number
local function repeatQuad(graphics, image, repS, repT)
  local quads = quadsByImage[image]
  if quads == nil then
    quads = {}
    quadsByImage[image] = quads
  end
  local key = repS * 4 + repT
  local entry = quads[key]
  if entry == nil then
    local width, height = image:getWidth(), image:getHeight()
    local quadWidth, quadHeight = width * (2 ^ repS), height * (2 ^ repT)
    entry = { graphics.newQuad(0, 0, quadWidth, quadHeight, width, height), quadWidth, quadHeight }
    quads[key] = entry
  end
  return entry[1], entry[2], entry[3]
end

---@param simulation SplParticleSimulation
---@return table<string, unknown>[] draws far-first draw list
local function orderedDraws(simulation)
  -- The sequence tiebreak keeps replay order deterministic where depths
  -- coincide; draw_child_first emitters sequence children before parents.
  local draws = {}
  local sequence = 0
  local function add(runtime, particle, child)
    sequence = sequence + 1
    draws[#draws + 1] = { runtime = runtime, particle = particle, child = child, seq = sequence }
  end
  for emitterIndex = #simulation.emitters, 1, -1 do
    local runtime = simulation.emitters[emitterIndex]
    local childFirst = runtime.record.drawChildFirst == true
    if childFirst then
      for childIndex = #runtime.children, 1, -1 do
        add(runtime, runtime.children[childIndex], runtime.record.child)
      end
    end
    for particleIndex = #runtime.particles, 1, -1 do
      add(runtime, runtime.particles[particleIndex], nil)
    end
    if not childFirst then
      for childIndex = #runtime.children, 1, -1 do
        add(runtime, runtime.children[childIndex], runtime.record.child)
      end
    end
  end
  table.sort(draws, function(a, b)
    local za = a.particle.z + a.particle.ez
    local zb = b.particle.z + b.particle.ez
    if za ~= zb then
      return za < zb
    end
    return a.seq < b.seq
  end)
  return draws
end

---@param record table<string, unknown> emitter record
---@param particle table<string, unknown>
---@param isChild boolean
---@return number|nil rotation radians, nil when the particle draws nothing
---@return number sx
---@return number sy
local function billboardShape(record, particle, isChild)
  local baseScale = particle.baseScale / 4096
  local animScale = particle.animScale / 4096
  local sx = baseScale * record.aspect
  local sy = baseScale
  local direct = record.sclAnmDirect
  if direct == 0 then
    sx, sy = sx * animScale, sy * animScale
  elseif direct == 1 then
    sx = sx * animScale
  else
    sy = sy * animScale
  end
  if isChild or record.drawType == 0 then
    return particle.rtt / 65536 * 2 * math.pi, sx, sy
  end
  -- Directional billboards stretch along the 3D velocity: the quad x-axis
  -- follows velocity cross camera-z in view space, and the y extent grows as
  -- the motion turns screen-parallel.
  local vx, vy, vz = particle.vx, particle.vy, particle.vz
  local dirX, dirY = vy, -vx
  local dirLength = math.sqrt(dirX * dirX + dirY * dirY)
  if dirLength == 0 then
    return nil, sx, sy
  end
  dirX, dirY = dirX / dirLength, dirY / dirLength
  local speed = math.sqrt(vx * vx + vy * vy + vz * vz)
  local parallel = 1
  if speed > 0 then
    parallel = math.abs(vz / speed)
  end
  sy = sy * (1 + (1 - parallel) * record.dbbScale / 4096)
  return math.atan2(-dirY, dirX), sx, sy
end

---@class SplParticleDrawOptions
---@field centerX number pane pixel x of the world origin
---@field centerY number pane pixel y of the world origin
---@field resolveTexture fun(runtime: table<string, unknown>, particle: table<string, unknown>, child: table<string, unknown>|nil): love.Image|nil
---   image the particle shows; child is the emitter's child record for child particles. A nil image skips the particle.

-- Draws every live particle of the simulation in far-to-near order and
-- restores the draw color. Texture repeat comes from the emitter (or child)
-- record; the image must already wrap in repeat mode when the record repeats.
-- A record `textureOffset` shifts the quad center within the particle's local
-- space by (x, y) half-extents, as the retail quad is drawn around that point.
---@param graphics table<string, function> love-like graphics namespace
---@param simulation SplParticleSimulation
---@param options SplParticleDrawOptions
function M.draw(graphics, simulation, options)
  local resolveTexture = options.resolveTexture
  for _, draw in ipairs(orderedDraws(simulation)) do
    local runtime = draw.runtime
    local particle = draw.particle
    local record = runtime.record
    local alpha = math.floor(particle.baseAlpha * (particle.animAlpha + 1) / 32)
    local worldX = particle.x + particle.ex
    local worldY = particle.y + particle.ey
    local worldZ = particle.z + particle.ez
    local depth = CAMERA_DISTANCE - worldZ
    if alpha > 0 and depth >= DEPTH_NEAR and depth <= DEPTH_FAR then
      local rotation, sx, sy = billboardShape(record, particle, draw.child ~= nil)
      local image = rotation ~= nil and resolveTexture(runtime, particle, draw.child) or nil
      if image ~= nil then
        local repeatPowers = (draw.child or record).texRepeat
        local quad, quadWidth, quadHeight = repeatQuad(graphics, image, repeatPowers.s, repeatPowers.t)
        local offset = draw.child == nil and record.textureOffset or nil
        local originX = quadWidth / 2
        local originY = quadHeight / 2
        if offset ~= nil then
          originX = originX * (1 - offset.x)
          originY = originY * (1 + offset.y)
        end
        local color = particle.colorRgb
        graphics.setColor(color.r / 31, color.g / 31, color.b / 31, alpha / 31)
        graphics.draw(
          image,
          quad,
          options.centerX + worldX * PX_PER_UNIT,
          options.centerY - worldY * PX_PER_UNIT,
          rotation,
          2 * sx * PX_PER_UNIT / quadWidth,
          2 * sy * PX_PER_UNIT / quadHeight,
          originX,
          originY
        )
      end
    end
  end
  graphics.setColor(1, 1, 1, 1)
end

return M
