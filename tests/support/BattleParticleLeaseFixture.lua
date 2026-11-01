-- Resource-holder lease for battle move particle tests: a staged particle
-- system with one self-destroying point emitter per ordinal and the retail
-- placement vectors, and an image-handle texture lease, shaped like the
-- production holder's answers. Tests that drive real animation programs
-- resolve every particle dependency through this one source.

local M = {}

M.TEXTURE_KEY = "battle/particle/texture/fixture-0"

local POSITIONS = {
  "solo-player",
  "solo-enemy",
  "player-side-slot-1",
  "enemy-side-slot-1",
  "player-side-slot-2",
  "enemy-side-slot-2",
}

---@param ordinal integer
---@return table<string, unknown>
local function emitter(ordinal)
  return {
    id = ordinal,
    emitterLife = 1,
    particleLife = 6,
    startOffset = 0,
    generation = { countFx = 4096, interval = 1 },
    initPosType = 0,
    circleAxis = 0,
    drawType = 0,
    radius = 0,
    length = 0,
    position = { x = 0, y = 0, z = 0 },
    axis = { x = 0, y = 0, z = 0 },
    baseColorRgb = { r = 31, g = 31, b = 31 },
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
    dbbScale = 0,
    sclAnmDirect = 0,
    texRepeat = { s = 0, t = 0 },
    texture = 0,
    animations = {},
    fields = {},
  }
end

---@param emitterCount integer|nil emitters the system carries, 12 when absent
---@return table<string, unknown> payload staged particle system
function M.payload(emitterCount)
  local emitters = {}
  for ordinal = 0, (emitterCount or 12) - 1 do
    emitters[#emitters + 1] = emitter(ordinal)
  end
  local placements = {}
  for index, position in ipairs(POSITIONS) do
    local x = -4 + (index - 1) * 1.5
    placements[position] = { { x = x, y = -1, z = 0 }, { x = x + 0.5, y = -1, z = 0 } }
  end
  return {
    seed = 0,
    emitters = emitters,
    textures = { { id = 0, width = 8, height = 8, image = M.TEXTURE_KEY } },
    placements = placements,
  }
end

---@param key string resource key under resolution
---@return table<string, unknown> lease the holder would answer
function M.resolve(key)
  if key == M.TEXTURE_KEY then
    return { key = key, kind = "texture", width = 8, height = 8, handle = { image = key } }
  end
  return { key = key, kind = "particle", payloadPath = "probe/particle", data = M.payload() }
end

return M
