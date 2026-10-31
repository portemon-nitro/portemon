-- Synthetic encounter particle sets in the shape the battle scene record
-- stages: two retail emitter sets in start order, each with compiled emitter
-- records and RGBA texture images under the scene's particle paths. Set 1
-- carries one plain emitter; set 2 carries a texture-animated emitter with a
-- child, so both optional record branches have a valid example.

local Fixture = {}

local ASSET_DIR = "assets/generated/battle/scenes/"

---@param sceneKey string
---@param setIndex integer
---@param textureId integer
---@return string
function Fixture.texturePath(sceneKey, setIndex, textureId)
  return ASSET_DIR .. sceneKey:gsub("/", "-") .. "-particles-" .. setIndex .. "-" .. textureId .. ".png"
end

---@param id integer
---@param texture integer
---@param image string
---@return table<string, unknown>
local function emitter(id, texture, image)
  return {
    id = id,
    emitterLife = 40,
    particleLife = 20,
    startOffset = 0,
    generation = { countFx = 4096, interval = 2 },
    initPosType = 2,
    circleAxis = 1,
    drawType = 0,
    radius = 1.5,
    length = 0,
    position = { x = 0, y = 0.25, z = 0 },
    axis = { x = 0, y = 1, z = 0 },
    baseColorRgb = { r = 31, g = 31, b = 31 },
    baseAlpha = 31,
    baseScaleFx = 4096,
    velocityFx = { pos = 2048, axis = 0 },
    velRandom = 10,
    scaleRandom = 0,
    lifeRandom = 5,
    rotation = { min = 0, max = 0 },
    useRotationAnim = false,
    useInitRotationRandom = false,
    initRotation = 0,
    airResist = 8,
    aspect = 1,
    loopFrame = 30,
    dbbScale = 0,
    sclAnmDirect = 0,
    texRepeat = { s = 0, t = 0 },
    texture = texture,
    textureImage = image,
    animations = {
      scale = { startFx = 0, normalFx = 4096, finishFx = 0, inTick = 10, outTick = 80 },
      color = {
        startRgb = { r = 31, g = 31, b = 31 },
        endRgb = { r = 0, g = 0, b = 0 },
        inTick = 0,
        peakTick = 50,
        outTick = 100,
        interpolate = true,
      },
      alpha = { start = 0, normal = 31, finish = 0, flick = 0, inTick = 10, outTick = 80 },
    },
    fields = { { kind = "gravity", magnitude = { x = 0, y = -0.01, z = 0 } } },
  }
end

---@param sceneKey string
---@return table<string, unknown>[] sets
function Fixture.sets(sceneKey)
  local image1 = Fixture.texturePath(sceneKey, 1, 0)
  local image2 = Fixture.texturePath(sceneKey, 2, 0)
  local image3 = Fixture.texturePath(sceneKey, 2, 3)
  local animated = emitter(0, 0, image2)
  animated.textureAnim = { textures = { 0, 3 }, diff = 4, random = false, loop = true }
  animated.child = {
    useScaleAnm = false,
    useAlphaAnm = true,
    followEmitter = false,
    useChildColor = false,
    childColor = { r = 31, g = 31, b = 31 },
    drawType = 0,
    initVelRandom = 0,
    scaleEnd = 1,
    life = 12,
    velRatio = 200,
    sclRatio = 255,
    genNum = 2,
    genStart = 0,
    genInterval = 3,
    texNo = 3,
    textureImage = image3,
    texRepeat = { s = 0, t = 0 },
  }
  return {
    {
      startTick = 1,
      seed = 0,
      emitters = { emitter(0, 0, image1) },
      textures = { { id = 0, width = 32, height = 32, image = image1 } },
    },
    {
      startTick = 20,
      seed = 0,
      emitters = { animated },
      textures = {
        { id = 0, width = 32, height = 32, image = image2 },
        { id = 3, width = 16, height = 64, image = image3 },
      },
    },
  }
end

return Fixture
