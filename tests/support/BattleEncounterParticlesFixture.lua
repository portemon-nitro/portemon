-- Synthetic encounter particle sets in the shape the battle scene record
-- stages: two retail emitter sets in start order, each with compiled emitter
-- records and RGBA texture images under the scene's particle paths. Set 1
-- carries one plain emitter; set 2 carries a texture-animated emitter with a
-- child, so both optional record branches have a valid example.

local Fixture = {}

-- Sampler and transparency metadata every staged particle texture
-- carries: nearest sampling with the texture header's clamp wrap, and
-- the decoder's exact coverage flags for these opaque RGBA fixtures.
local function textureRecord(id, width, height, image)
  return {
    id = id,
    width = width,
    height = height,
    image = image,
    sampler = { minFilter = "nearest", magFilter = "nearest", wrapX = "clamp", wrapY = "clamp" },
    alphaUsage = { hasZero = false, hasPartial = false, hasOpaque = true },
  }
end

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
    reverseTex = { s = false, t = false },
    polygonRotationAxis = "y",
    polygonPlane = "xy",
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

--- Deterministic compiled encounter emitter record with an exact
--- self-destruction lifespan: no random life extension, so the owning
--- system retires a known number of advances after its start tick.
---@param id integer source emitter identity within its set
---@param emitterLife integer source emitter lifespan in advances
---@return table<string, unknown> compiled emitter record
function Fixture.encounterEmitter(id, emitterLife)
  return {
    id = id,
    emitterLife = emitterLife,
    particleLife = 2,
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
    lifeRandom = 0,
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
    reverseTex = { s = false, t = false },
    polygonRotationAxis = "y",
    polygonPlane = "xy",
    texture = 0,
    textureImage = "img",
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
    fields = {},
  }
end

--- Two retail-shaped encounter emitter sets with caller-sized emitter
--- counts and lifespans, in staged start order (frames 1 and 20).
---@param sceneKey string scene identity behind staged texture paths
---@param firstCount integer emitter count for the first set
---@param secondCount integer emitter count for the second set
---@param firstLife integer emitter lifespan for the first set
---@param secondLife integer emitter lifespan for the second set
---@return table<string, unknown>[] sets
function Fixture.sizedSets(sceneKey, firstCount, secondCount, firstLife, secondLife)
  local first = {}
  for id = 0, firstCount - 1 do
    first[#first + 1] = Fixture.encounterEmitter(id, firstLife)
  end
  local second = {}
  for id = 0, secondCount - 1 do
    second[#second + 1] = Fixture.encounterEmitter(id, secondLife)
  end
  return {
    {
      startTick = 1,
      emitters = first,
      textures = { textureRecord(0, 32, 32, Fixture.texturePath(sceneKey, 1, 0)) },
    },
    {
      startTick = 20,
      emitters = second,
      textures = { textureRecord(0, 32, 32, Fixture.texturePath(sceneKey, 2, 0)) },
    },
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
    polygonRotationAxis = "y",
    polygonPlane = "xy",
    reverseTex = { s = false, t = false },
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
      emitters = { emitter(0, 0, image1) },
      textures = { textureRecord(0, 32, 32, image1) },
    },
    {
      startTick = 20,
      emitters = { animated },
      textures = {
        textureRecord(0, 32, 32, image2),
        textureRecord(3, 16, 64, image3),
      },
    },
  }
end

return Fixture
