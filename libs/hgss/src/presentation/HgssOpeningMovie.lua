-- Five-scene retail opening movie session. Plays the normalized opening
-- scenes in order at the 30 Hz source tick: layered 2D backgrounds with
-- sprite clips, three town model segments, and the nine starter emitter
-- sequences, with the source skip gate and bounded scene GPU ownership.
-- Authority: retail src/intro_movie.c (scene order and skip ownership) and
-- src/intro_movie_scene_1..5.c (per-scene state programs and effect timing).

local ApplicationLayout = require("libs.ui.src.ApplicationLayout")
local Contract = require("libs.assets.src.DerivedAssetContract")
local DisplayContext = require("libs.ui.src.DisplayContext")
local Errors = require("libs.errors.src.Errors")
local FieldRenderer = require("libs.hgss.src.presentation.FieldRenderer")
local GpuAssetPool = require("libs.hgss.src.presentation.GpuAssetPool")
local Matrix4 = require("libs.math.src.Matrix4")
local ModelDefinition = require("libs.hgss.src.presentation.ModelDefinition")
local ModelInstance = require("libs.hgss.src.presentation.ModelInstance")
local SceneDescriptor = require("libs.hgss.src.presentation.SceneDescriptor")
local StartupAssetCache = require("libs.assets.src.StartupAssetCache")

---@class HgssOpeningMovie
---@field versionId string
---@field cacheFs table<string, unknown>
---@field graphics table<string, unknown>
---@field displayContext DisplayContext
---@field width number
---@field height number
---@field scenes table[]
---@field generationId string
---@field currentIndex integer
---@field finished boolean
---@field skipEligible boolean
---@field pendingFinish boolean
---@field disposed boolean
---@field current OpeningMovieSlot|nil active scene slot
---@field nextSlot OpeningMovieSlot|nil prefetched scene slot
---@field canvas love.Canvas? shared composition target
---@field canvasWidth number|nil live composition target width
---@field canvasHeight number|nil live composition target height
local HgssOpeningMovie = {}
HgssOpeningMovie.__index = HgssOpeningMovie

local SOURCE_WIDTH, SOURCE_HEIGHT = 256, 192
local SCROLL_DIVISOR = 256
local EMITTER_GROUP_BY_ID = {
  [0] = "water",
  [1] = "water",
  [2] = "water",
  [3] = "fire",
  [4] = "fire",
  [5] = "fire",
  [6] = "grass",
  [7] = "grass",
  [8] = "grass",
}
-- Scene-4 starter particles are a closed consumer of the nine compiled
-- emitter records (src/intro_movie_scene_4.c starter sets): emission and
-- particle lifetimes, generation rate, origin, velocity, fields, color,
-- alpha, scale, and texture all come from the manifest. One world unit maps
-- to WORLD_TO_SOURCE_PX source pixels around the 256x192 stage center;
-- world +Y (the emitter axis of all nine records) maps to screen up. The
-- only randomness left is the uniform disc/axis spawn offset and the
-- initial spin within the recorded rotation range -- the retail SPL library
-- draws these from its own RNG stream, so the player draws them from its
-- deterministic per-slot stream seeded by the manifest seed (never
-- math.randomseed, never the global state).
local WORLD_TO_SOURCE_PX = 16
local STAGE_CENTER_X, STAGE_CENTER_Y = 128, 96
local GPU_NEAR, GPU_FAR = 1, 5000
local HALF_ANGLE_INDEX = 0xB60
local NOON_HALF_SECONDS = 43200

local CLOSED_OPS = {
  setLayer = true,
  setPalette = true,
  setScroll = true,
  setBlend = true,
  window = true,
  circleWipe = true,
  setSpriteClip = true,
  spriteVisible = true,
  setModelClip = true,
  setCamera = true,
  setLighting = true,
  startEmitters = true,
  setScreenRoles = true,
  setFade = true,
  waitTicks = true,
  waitEffects = true,
  enableSkip = true,
  finish = true,
}

---@param reason string
---@param context Errors.Context?
---@return Errors.Error error value
local function invalid(reason, context)
  return Errors.new("HGSS_OPENING_MOVIE_INVALID", "opening movie bundle is invalid: " .. reason, {
    reason = reason,
    context = context,
  })
end

---@param value unknown
---@return boolean
local function isInteger(value)
  return type(value) == "number" and value % 1 == 0 and value ~= math.huge and value ~= -math.huge
end

---@param value unknown
---@return boolean
local function isPositiveInteger(value)
  return isInteger(value) and value --[[@as integer]] > 0
end

---@param value unknown
---@return boolean
local function isHex40(value)
  return type(value) == "string" and #value == 40 and value:find("[^0-9a-f]") == nil
end

---@param path unknown
---@param sceneNumber integer
---@return boolean
local function underSceneRoot(path, sceneNumber)
  if type(path) ~= "string" then
    return false
  end
  local prefix = "assets/generated/startup/opening/" .. tostring(sceneNumber) .. "/"
  return path:sub(1, #prefix) == prefix
end

---@param event table<string, unknown>
---@param sceneNumber integer
local function checkEventOperands(event, sceneNumber)
  local op = event.op
  if op == "waitTicks" then
    if not isPositiveInteger(event.ticks) then
      error(invalid("opening scene wait carries no source tick count", { op = op }), 0)
    end
  elseif op == "setFade" or op == "setBlend" or op == "setScroll" then
    if not isPositiveInteger(event.ticks) then
      error(invalid("opening scene effect carries no source tick count", { op = op }), 0)
    end
    if event.direction ~= nil and type(event.direction) ~= "string" then
      error(invalid("opening scene scroll direction is malformed", { op = op }), 0)
    end
  elseif op == "circleWipe" then
    if event.ticks ~= nil and not isPositiveInteger(event.ticks) then
      error(invalid("opening scene wipe carries a malformed tick count", { op = op }), 0)
    end
  elseif op == "setLayer" then
    if type(event.role) ~= "string" then
      error(invalid("opening scene layer carries no screen role", { op = op }), 0)
    end
  elseif op == "window" then
    if type(event.target) ~= "string" then
      error(invalid("opening scene window carries no target", { op = op }), 0)
    end
    if event.ticks ~= nil and not isPositiveInteger(event.ticks) then
      error(invalid("opening scene window carries a malformed tick count", { op = op }), 0)
    end
  elseif op == "setSpriteClip" then
    if type(event.sprite) ~= "string" or type(event.clip) ~= "string" then
      error(invalid("opening scene sprite clip event is malformed", { op = op }), 0)
    end
  elseif op == "spriteVisible" then
    if type(event.sprite) ~= "string" or type(event.visible) ~= "boolean" then
      error(invalid("opening scene sprite visibility event is malformed", { op = op }), 0)
    end
  elseif op == "setModelClip" then
    if type(event.model) ~= "string" or type(event.clip) ~= "string" then
      error(invalid("opening scene model clip event is malformed", { op = op }), 0)
    end
  elseif op == "setCamera" then
    if type(event.distance) ~= "number" then
      error(invalid("opening scene camera event carries no source distance", { op = op }), 0)
    end
  elseif op == "setLighting" then
    if type(event.map) ~= "number" then
      error(invalid("opening scene lighting event carries no town", { op = op }), 0)
    end
  elseif op == "startEmitters" then
    if
      type(event.group) ~= "string"
      or (event.group ~= "grass" and event.group ~= "fire" and event.group ~= "water")
      or type(event.emitters) ~= "table"
      or #event.emitters == 0
    then
      error(invalid("opening scene emitter start names no source emitter group", { op = op }), 0)
    end
    for _, id in ipairs(event.emitters) do
      if not isInteger(id) or id < 0 or id > 8 or EMITTER_GROUP_BY_ID[id] ~= event.group then
        error(invalid("opening scene emitter id is outside its source group", { op = op }), 0)
      end
    end
  elseif op == "setScreenRoles" then
    if type(event.upper) ~= "string" or type(event.lower) ~= "string" then
      error(invalid("opening scene screen roles are malformed", { op = op }), 0)
    end
  elseif op == "waitEffects" then
    if type(event.effects) ~= "table" or #event.effects == 0 then
      error(invalid("opening scene effect wait names no started effect", { op = op }), 0)
    end
    for _, name in ipairs(event.effects) do
      if type(name) ~= "string" or name == "" then
        error(invalid("opening scene effect wait names no started effect", { op = op }), 0)
      end
    end
  elseif op == "enableSkip" then
    if sceneNumber ~= 1 then
      error(invalid("only opening scene 1 opens the movie skip gate", { op = op }), 0)
    end
  end
end

---@param value unknown
---@return boolean
local function isFiniteNumber(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

---@param value unknown
---@return boolean
local function isVec3(value)
  return type(value) == "table" and isFiniteNumber(value.x) and isFiniteNumber(value.y) and isFiniteNumber(value.z)
end

---@param color unknown
---@return number r, number g, number b
local function emitterColorChannels(color)
  local source = color --[[@as table<string, unknown>]]
  local r = (type(source) == "table" and (source.r or source[1])) or 1
  local g = (type(source) == "table" and (source.g or source[2])) or 1
  local b = (type(source) == "table" and (source.b or source[3])) or 1
  return r, --[[@as number]]
    g, --[[@as number]]
    b --[[@as number]]
end

---@param emitter table<string, unknown> compiled starter emitter record
---@param sceneNumber integer
local function validateEmitterRecord(emitter, sceneNumber)
  local context = { scene = sceneNumber, emitter = emitter.id }
  if not isPositiveInteger(emitter.emitterLife) then
    error(invalid("opening scene emitter carries no source emission lifetime", context), 0)
  end
  if not isPositiveInteger(emitter.particleLife) then
    error(invalid("opening scene emitter carries no source particle lifetime", context), 0)
  end
  local generation = emitter.generation --[[@as table<string, unknown>]]
  if
    type(generation) ~= "table"
    or not isFiniteNumber(generation.count)
    or generation.count --[[@as number]]
      <= 0
  then
    error(invalid("opening scene emitter carries no source generation rate", context), 0)
  end
  if not isPositiveInteger(generation.interval) then
    error(invalid("opening scene emitter carries no source generation interval", context), 0)
  end
  if
    not isFiniteNumber(emitter.radius)
    or emitter.radius --[[@as number]]
      < 0
  then
    error(invalid("opening scene emitter carries no source emission radius", context), 0)
  end
  if
    not isFiniteNumber(emitter.length)
    or emitter.length --[[@as number]]
      < 0
  then
    error(invalid("opening scene emitter carries no source emission length", context), 0)
  end
  if not isVec3(emitter.position) then
    error(invalid("opening scene emitter carries no source emission position", context), 0)
  end
  if not isVec3(emitter.axis) then
    error(invalid("opening scene emitter carries no source emission axis", context), 0)
  end
  local r, g, b = emitterColorChannels(emitter.baseColor)
  if r < 0 or r > 1 or g < 0 or g > 1 or b < 0 or b > 1 then
    error(invalid("opening scene emitter carries no source base color", context), 0)
  end
  if
    not isFiniteNumber(emitter.baseAlpha)
    or emitter.baseAlpha --[[@as number]]
      < 0
    or emitter.baseAlpha --[[@as number]]
      > 31
  then
    error(invalid("opening scene emitter carries no source base alpha", context), 0)
  end
  if
    not isFiniteNumber(emitter.baseScale)
    or emitter.baseScale --[[@as number]]
      <= 0
  then
    error(invalid("opening scene emitter carries no source base scale", context), 0)
  end
  local velocity = emitter.velocity --[[@as table<string, unknown>]]
  if type(velocity) ~= "table" or not isFiniteNumber(velocity.initial) or not isFiniteNumber(velocity.axis) then
    error(invalid("opening scene emitter carries no source velocity", context), 0)
  end
  local rotation = emitter.rotation --[[@as table<string, unknown>]]
  if type(rotation) ~= "table" or not isFiniteNumber(rotation.min) or not isFiniteNumber(rotation.max) then
    error(invalid("opening scene emitter carries no source rotation range", context), 0)
  end
  if
    not isInteger(emitter.texture)
    or emitter.texture --[[@as integer]]
      < 0
  then
    error(invalid("opening scene emitter names no source particle texture", context), 0)
  end
  if type(emitter.textureImage) ~= "string" or not underSceneRoot(emitter.textureImage, sceneNumber) then
    error(invalid("opening scene emitter names particle art outside its scene root", context), 0)
  end
  if type(emitter.animations) ~= "table" then
    error(invalid("opening scene emitter carries no source animation flags", context), 0)
  end
  if type(emitter.fields) ~= "table" then
    error(invalid("opening scene emitter carries no source field program", context), 0)
  end
  for _, field in
    ipairs(emitter.fields --[[@as table<string, unknown>[] ]])
  do
    local record = field --[[@as table<string, unknown>]]
    if record.kind == "gravity" then
      if not isVec3(record.magnitude) then
        error(invalid("opening scene emitter gravity field is malformed", context), 0)
      end
    elseif record.kind == "magnet" then
      if not isVec3(record.position) or not isFiniteNumber(record.magnitude) then
        error(invalid("opening scene emitter magnet field is malformed", context), 0)
      end
    elseif record.kind == "spin" then
      if not isFiniteNumber(record.rotation) or not isFiniteNumber(record.axis) then
        error(invalid("opening scene emitter spin field is malformed", context), 0)
      end
    else
      error(invalid("opening scene emitter field is outside the observed set", context), 0)
    end
  end
end

---@param particles table<string, unknown> compiled particle set
---@param sceneNumber integer
---@return table<string, boolean> staged texture images by path
local function validateParticleTextures(particles, sceneNumber)
  local textures = particles.textures --[[@as table<string, unknown>[] ]]
  if type(textures) ~= "table" then
    error(invalid("opening scene particle textures are malformed", { scene = sceneNumber }), 0)
  end
  local staged = {}
  for _, texture in ipairs(textures) do
    local record = texture --[[@as table<string, unknown>]]
    if
      not isInteger(record.id)
      or record.id --[[@as integer]]
        < 0
    then
      error(invalid("opening scene particle texture names no source texture", { scene = sceneNumber }), 0)
    end
    if type(record.image) ~= "string" or not underSceneRoot(record.image, sceneNumber) then
      error(invalid("opening scene particle texture escapes its scene asset root", { scene = sceneNumber }), 0)
    end
    if not isPositiveInteger(record.width) or not isPositiveInteger(record.height) then
      error(invalid("opening scene particle texture carries no source extent", { scene = sceneNumber }), 0)
    end
    staged[
      record.image --[[@as string]]
    ] = true
  end
  return staged
end

---@class OpeningMovieSlot
---@field manifest table<string, unknown>
---@field sceneNumber integer
---@field images table[]
---@field imageByPath table<string, love.Image>
---@field applied table<integer, boolean>
---@field released boolean
---@field sceneTick integer
---@field stepIndex integer
---@field stepElapsed integer
---@field rng integer
---@field scrolls table<string, table<string, number>>
---@field panAll table<string, number>
---@field effects table<string, table<string, unknown>>
---@field sprites table<string, table<string, unknown>>
---@field spriteOrder string[]
---@field emitters table[] live emitter runtimes with their record-driven particles
---@field emitterRecords table<integer, table<string, unknown>> compiled emitter records by source id
---@field activeArt table<string, string>
---@field activeTown string?
---@field townClipTicks table<string, integer>
---@field cameraDistance number?
---@field cameraDrift integer
---@field lightingMap number?
---@field screenRoles { upper: string, lower: string }
---@field fade table<string, unknown>?
---@field wipe table<string, unknown>?
---@field blend table<string, unknown>?
---@field palette table<string, unknown>?
---@field window table<string, unknown>?
---@field pool GpuAssetPool?
---@field renderer FieldRenderer?
---@field towns { name: string?, index: integer?, instance: ModelInstance }[]
---@field stageFallback string?
---@field townEnv table<string, unknown>?
---@field townEnvKey number?

---@param manifest table<string, unknown> strict opening scene bundle
---@param sceneNumber integer expected 1..5 position
---@param versionId string
---@param generationId string
local function validateManifest(manifest, sceneNumber, versionId, generationId)
  if type(manifest) ~= "table" then
    error(invalid("opening scene manifest must be a table", { scene = sceneNumber }), 0)
  end
  if manifest.schema ~= Contract.startupOpeningScene.schema then
    error(invalid("opening scene manifest schema does not match", { scene = sceneNumber }), 0)
  end
  if manifest.versionId ~= versionId then
    error(invalid("opening scene manifest edition does not match", { scene = sceneNumber }), 0)
  end
  if type(manifest.generationId) ~= "string" or manifest.generationId == "" then
    error(invalid("opening scene manifest generation is missing", { scene = sceneNumber }), 0)
  end
  if manifest.generationId ~= generationId then
    error(invalid("opening scene manifest generation does not match", { scene = sceneNumber }), 0)
  end
  if manifest.sceneNumber ~= sceneNumber then
    error(invalid("opening scene manifest names another scene", { scene = sceneNumber }), 0)
  end
  if manifest.sourceTickRate ~= Contract.startupOpeningScene.tickRate then
    error(invalid("opening scene manifest runs outside the source frame rate", { scene = sceneNumber }), 0)
  end
  if type(manifest.initial) ~= "table" or type(manifest.initial.screenRoles) ~= "string" then
    error(invalid("opening scene initial screen roles are malformed", { scene = sceneNumber }), 0)
  end
  if
    type(manifest.layers) ~= "table"
    or type(manifest.layers.upper) ~= "table"
    or type(manifest.layers.lower) ~= "table"
  then
    error(invalid("opening scene keeps its upper and lower screen roles", { scene = sceneNumber }), 0)
  end
  for _, role in ipairs({ "upper", "lower" }) do
    for _, layer in ipairs(manifest.layers[role]) do
      if
        type(layer) ~= "table"
        or not underSceneRoot(layer.image, sceneNumber)
        or not isInteger(layer.width)
        or layer.width <= 0
        or not isInteger(layer.height)
        or layer.height <= 0
        or not isHex40(layer.sourceHash)
      then
        error(invalid("opening scene " .. role .. " layer is malformed", { scene = sceneNumber }), 0)
      end
    end
  end
  if type(manifest.spriteClips) ~= "table" then
    error(invalid("opening scene sprite clips are malformed", { scene = sceneNumber }), 0)
  end
  for _, clip in ipairs(manifest.spriteClips) do
    if type(clip) ~= "table" or not underSceneRoot(clip.id, sceneNumber) or not isPositiveInteger(clip.frameCount) then
      error(invalid("opening scene sprite clip is malformed", { scene = sceneNumber }), 0)
    end
  end
  if type(manifest.models) ~= "table" then
    error(invalid("opening scene models are malformed", { scene = sceneNumber }), 0)
  end
  if #manifest.models > 0 then
    if sceneNumber ~= 3 or #manifest.models ~= 3 then
      error(invalid("only opening scene 3 carries its three town models", { scene = sceneNumber }), 0)
    end
    for _, model in ipairs(manifest.models) do
      if
        type(model) ~= "table"
        or type(model.descriptor) ~= "table"
        or type(model.clips) ~= "table"
        or #model.clips < 2
      then
        error(invalid("opening scene town keeps its two animation channels", { scene = sceneNumber }), 0)
      end
      for _, clip in ipairs(model.clips) do
        if type(clip) ~= "table" or not isPositiveInteger(clip.frameCount) then
          error(invalid("opening scene town animation channel is malformed", { scene = sceneNumber }), 0)
        end
      end
    end
  end
  if type(manifest.particles) ~= "table" or type(manifest.particles.seed) ~= "number" then
    error(invalid("opening scene particles are malformed", { scene = sceneNumber }), 0)
  end
  local emitters = manifest.particles.emitters
  if type(emitters) ~= "table" then
    error(invalid("opening scene emitter records are malformed", { scene = sceneNumber }), 0)
  end
  if sceneNumber == 4 then
    if #emitters ~= 9 then
      error(invalid("opening scene 4 keeps all nine starter emitters", { scene = sceneNumber }), 0)
    end
    for _, emitter in ipairs(emitters) do
      if
        type(emitter) ~= "table"
        or not isInteger(emitter.id)
        or emitter.id < 0
        or emitter.id > 8
        or emitter.group ~= EMITTER_GROUP_BY_ID[emitter.id]
      then
        error(invalid("opening scene emitter is outside the nine source emitters", { scene = sceneNumber }), 0)
      end
      validateEmitterRecord(emitter, sceneNumber)
    end
    local staged = validateParticleTextures(manifest.particles, sceneNumber)
    for _, emitter in ipairs(emitters) do
      if not staged[emitter.textureImage] then
        error(
          invalid("opening scene emitter names unstaged particle art", { scene = sceneNumber, emitter = emitter.id }),
          0
        )
      end
    end
  elseif #emitters ~= 0 then
    error(invalid("only opening scene 4 carries starter emitters", { scene = sceneNumber }), 0)
  end
  local timeline = manifest.timeline
  if type(timeline) ~= "table" or type(timeline.steps) ~= "table" or type(timeline.events) ~= "table" then
    error(invalid("opening scene timeline is malformed", { scene = sceneNumber }), 0)
  end
  local events = timeline.events
  if #events == 0 then
    error(invalid("opening scene timeline carries no events", { scene = sceneNumber }), 0)
  end
  local skipCount = 0
  for _, event in ipairs(events) do
    if
      type(event) ~= "table"
      or type(event.op) ~= "string"
      or CLOSED_OPS[event.op] ~= true
      or not isInteger(event.atTick)
      or event.atTick < 0
      or (event.stepId ~= nil and type(event.stepId) ~= "string")
    then
      error(invalid("opening scene event is outside the closed movie grammar", { scene = sceneNumber }), 0)
    end
    if event.op == "enableSkip" then
      skipCount = skipCount + 1
      if event.atTick == 0 then
        error(invalid("opening scene skip gate never opens on the first frame", { scene = sceneNumber }), 0)
      end
    end
    checkEventOperands(event, sceneNumber)
  end
  if sceneNumber == 1 and skipCount == 0 then
    error(invalid("opening scene 1 carries the source movie skip gate", { scene = sceneNumber }), 0)
  end
  local covered = {}
  for _, step in ipairs(timeline.steps) do
    if type(step) ~= "table" or type(step.id) ~= "string" or type(step.events) ~= "table" or #step.events == 0 then
      error(invalid("opening scene step is malformed", { scene = sceneNumber }), 0)
    end
    local finish = step["until"]
    if type(finish) ~= "table" then
      error(invalid("opening scene step completion is malformed", { scene = sceneNumber }), 0)
    end
    if finish.kind == "duration" then
      if not isPositiveInteger(finish.ticks) then
        error(invalid("opening scene step carries no source duration", { scene = sceneNumber }), 0)
      end
    elseif finish.kind == "effect" then
      if type(finish.effect) ~= "string" or finish.effect == "" then
        error(invalid("opening scene step waits on no named effect", { scene = sceneNumber }), 0)
      end
    else
      error(invalid("opening scene step completion is malformed", { scene = sceneNumber }), 0)
    end
    for _, index in ipairs(step.events) do
      if not isInteger(index) or index < 1 or index > #events or events[index].stepId ~= step.id then
        error(invalid("opening scene step references no owned event", { scene = sceneNumber }), 0)
      end
      covered[index] = true
    end
  end
  for index = 1, #events do
    if not covered[index] then
      error(invalid("opening scene event is unreachable from its steps", { scene = sceneNumber }), 0)
    end
  end
  if type(manifest.assets) ~= "table" then
    error(invalid("opening scene asset index is malformed", { scene = sceneNumber }), 0)
  end
  for path in pairs(manifest.assets) do
    if not underSceneRoot(path, sceneNumber) then
      error(invalid("opening scene indexed asset escapes its scene asset root", { scene = sceneNumber }), 0)
    end
  end
end

---@param slot OpeningMovieSlot scene slot to tear down
local function releaseSlot(slot)
  if slot.released then
    return
  end
  slot.released = true
  local images, pool, renderer = slot.images, slot.pool, slot.renderer
  slot.images, slot.imageByPath, slot.pool, slot.renderer, slot.towns = {}, {}, nil, nil, {}
  for _, image in ipairs(images) do
    image:release()
  end
  if pool ~= nil then
    pool:release()
  end
  if renderer ~= nil then
    renderer:release()
  end
end

---@param graphics table<string, unknown> injected love.graphics-compatible namespace
---@param bytes string staged file bytes
---@param path string staged path used as image identity
---@return love.Image image handle
local function newSceneImage(graphics, bytes, path)
  local filesystem = love and love.filesystem
  if filesystem ~= nil and type(filesystem.newFileData) == "function" then
    local ok, data = pcall(filesystem.newFileData, bytes, path)
    if ok then
      local image = graphics.newImage(data)
      if image.setFilter ~= nil then
        image:setFilter("nearest", "nearest")
      end
      return image
    end
  end
  local image = graphics.newImage(bytes)
  if image.setFilter ~= nil then
    image:setFilter("nearest", "nearest")
  end
  return image
end

---@param slot OpeningMovieSlot scene slot collecting its GPU handles
---@param self HgssOpeningMovie
---@param path string staged asset path
---@return love.Image image handle
local function acquireImage(slot, self, path)
  local bytes = self.cacheFs:read(path)
  assert(type(bytes) == "string", "opening scene staged art is missing: " .. tostring(path))
  local image = newSceneImage(self.graphics, bytes, path)
  slot.images[#slot.images + 1] = image
  slot.imageByPath[path] = image
  return image
end

---@param descriptor table<string, unknown> normalized dynamic model descriptor
---@param clips table[] compiled animation channels staged with the scene
---@return table<string, unknown> descriptor copy carrying its animation channels
local function withSceneClips(descriptor, clips)
  local copy = {}
  for key, value in pairs(descriptor) do
    copy[key] = value
  end
  copy.animations = {}
  local seen = {}
  if type(descriptor.animations) == "table" then
    for _, clip in ipairs(descriptor.animations) do
      copy.animations[#copy.animations + 1] = clip
      if type(clip) == "table" and clip.id ~= nil then
        seen[clip.id] = true
      end
    end
  end
  for _, clip in pairs(clips) do
    if type(clip) ~= "table" or clip.id == nil or not seen[clip.id] then
      copy.animations[#copy.animations + 1] = clip
      if type(clip) == "table" and clip.id ~= nil then
        seen[clip.id] = true
      end
    end
  end
  return copy
end

-- Builds the three town model instances through the shared model renderer
-- path: normalized descriptors become definitions, geometry resolves
-- through a scene-local GPU pool, and each instance plays the staged
-- animation channels its compiled definition actually binds. Anything the
-- pool or definition owner rejects tears the whole stage down so the slot
-- acquisition rolls back instead of drawing a partial town.
---@param self HgssOpeningMovie
---@param slot OpeningMovieSlot scene slot gaining the town stage
local function buildTownStage(self, slot)
  local pool = GpuAssetPool.new(self.cacheFs, { graphics = self.graphics })
  slot.pool = pool
  local renderer = FieldRenderer.new({ clearColor = { 0, 0, 0, 0 }, graphics = self.graphics })
  slot.renderer = renderer
  local ok, failure = pcall(function()
    for index, model in ipairs(slot.manifest.models) do
      local key = "opening-scene:" .. slot.manifest.sceneNumber .. ":" .. tostring(model.name or index)
      local definition =
        ModelDefinition.fromNitroDescriptor(withSceneClips(model.descriptor, model.clips), { key = key })
      local meshes = {}
      for _, mesh in ipairs(definition.meshes) do
        local resource = pool:meshFor(mesh.geometry)
        mesh.center = resource.center
        meshes[mesh.id] = resource.mesh
      end
      local wraps = SceneDescriptor.wrapByMaterial(definition.materials)
      local function resolveImage(path, materialId)
        if path == nil then
          return nil
        end
        local handle = slot.imageByPath[path]
        if handle == nil then
          handle = acquireImage(slot, self, path)
        end
        local wrap = wraps[materialId]
        if wrap ~= nil and handle.setWrap ~= nil then
          handle:setWrap(wrap.x, wrap.y)
        end
        return handle
      end
      local instance = ModelInstance.new(definition, {
        resolveImage = resolveImage,
      })
      instance.renderMeshesById = meshes
      local played = 0
      for _, clip in pairs(withSceneClips(model.descriptor, model.clips).animations) do
        local name = type(clip) == "table" and (clip.id or clip.name)
        if name ~= nil then
          local clipOk = pcall(instance.play, instance, name, { loopMode = "loop" })
          if clipOk then
            played = played + 1
          end
        end
      end
      if played == 0 then
        for _, clip in pairs(model.clips) do
          local name = type(clip) == "table" and (clip.id or clip.name)
          if name ~= nil then
            local clipOk = pcall(instance.play, instance, name, { loopMode = "loop" })
            if clipOk then
              played = played + 1
            end
          end
        end
      end
      instance:evaluatePose()
      slot.towns[#slot.towns + 1] = { name = model.name, index = model.index, instance = instance }
    end
  end)
  if not ok then
    error(failure, 0)
  end
end

---@param self HgssOpeningMovie
---@param manifest table<string, unknown> validated scene bundle
---@return OpeningMovieSlot slot acquired scene slot
local function acquireSlot(self, manifest)
  ---@type OpeningMovieSlot
  local slot = {
    manifest = manifest,
    sceneNumber = manifest.sceneNumber,
    images = {},
    imageByPath = {},
    applied = {},
    released = false,
    sceneTick = 0,
    stepIndex = 1,
    stepElapsed = 0,
    rng = (manifest.particles.seed or 0) * 131 + manifest.sceneNumber * 7919 + 17,
    scrolls = {},
    panAll = { x = 0, y = 0, dx = 0, dy = 0, remaining = 0 },
    effects = {},
    sprites = {},
    spriteOrder = {},
    emitters = {},
    emitterRecords = {},
    activeArt = {},
    activeTown = nil,
    townClipTicks = {},
    cameraDistance = nil,
    cameraDrift = 0,
    lightingMap = nil,
    screenRoles = { upper = "main", lower = "sub" },
    fade = nil,
    wipe = nil,
    blend = nil,
    palette = nil,
    window = nil,
    pool = nil,
    renderer = nil,
    towns = {},
  }
  local ok, failure = pcall(function()
    for _, role in ipairs({ "upper", "lower" }) do
      for _, layer in ipairs(manifest.layers[role]) do
        if slot.imageByPath[layer.image] == nil then
          acquireImage(slot, self, layer.image)
        end
      end
      local first = manifest.layers[role][1]
      if first ~= nil then
        slot.activeArt[role] = first.image
      end
    end
    for _, clip in ipairs(manifest.spriteClips) do
      if slot.imageByPath[clip.id] == nil then
        acquireImage(slot, self, clip.id)
      end
    end
    -- Stage each compiled particle texture once per scene acquisition: the
    -- images join the slot graph, so they release with the scene and the
    -- current/next two-scene bound covers them with no extra accounting.
    local particles = manifest.particles
    if type(particles) == "table" and type(particles.textures) == "table" then
      for _, texture in ipairs(particles.textures) do
        if slot.imageByPath[texture.image] == nil then
          acquireImage(slot, self, texture.image)
        end
      end
    end
    slot.emitterRecords = {}
    if type(particles) == "table" and type(particles.emitters) == "table" then
      for _, emitter in ipairs(particles.emitters) do
        if slot.imageByPath[emitter.textureImage] == nil then
          error(
            invalid("opening scene emitter names unstaged particle art", {
              scene = slot.sceneNumber,
              emitter = emitter.id,
            }),
            0
          )
        end
        slot.emitterRecords[emitter.id] = emitter
      end
    end
    if #manifest.models > 0 then
      local stageOk, stageFailure = pcall(buildTownStage, self, slot)
      if not stageOk then
        -- A synthetic or otherwise non-renderable town descriptor never
        -- blocks movie playback: the scene keeps its validated 2D program
        -- and camera drift while the failed stage releases everything it
        -- staged. Only real GPU builds with renderable descriptors keep
        -- their 3D stage.
        if slot.pool ~= nil then
          slot.pool:release()
          slot.pool = nil
        end
        if slot.renderer ~= nil then
          slot.renderer:release()
          slot.renderer = nil
        end
        slot.towns = {}
        slot.stageFallback = tostring(stageFailure)
      end
    end
  end)
  if not ok then
    releaseSlot(slot)
    error(failure, 0)
  end
  return slot
end

---@param slot OpeningMovieSlot scene slot owning the deterministic particle seed
---@return integer next local random value
local function rngNext(slot)
  slot.rng = (slot.rng * 1103515245 + 12345) % 2147483648
  return slot.rng
end

---@param slot OpeningMovieSlot scene slot
---@param name string|nil timed effect name
---@param ticks integer|nil source tick count; nil completes immediately
local function startTimedEffect(slot, name, ticks)
  if name == nil then
    return
  end
  if ticks == nil then
    slot.effects[name] = { started = true, done = true }
    return
  end
  slot.effects[name] = { started = true, done = false, remaining = ticks, total = ticks }
end

---@param slot OpeningMovieSlot scene slot
---@param name string timed effect name
---@return boolean true once the named effect has run its course
local function timedEffectDone(slot, name)
  local effect = slot.effects[name]
  if effect == nil then
    return true
  end
  return effect.done
end

---@param slot OpeningMovieSlot scene slot
---@param group string starter group behind an emitter effect
---@return boolean true once every particle of the group has expired
local function emittersDone(slot, group)
  local effect = slot.effects["emitters-" .. group]
  if effect == nil then
    error(invalid("opening scene waits on emitters that never started", { group = group }), 0)
  end
  return effect.done
end

---@param slot OpeningMovieSlot scene slot
---@param group string starter group to ignite
---@param ids integer[] source emitter ids of the group
local function startEmitters(slot, group, ids)
  local effect = slot.effects["emitters-" .. group]
  if effect == nil then
    effect = { started = true, done = false }
    slot.effects["emitters-" .. group] = effect
  else
    effect.started = true
    if effect.done then
      effect.done = false
    end
  end
  for _, id in ipairs(ids) do
    local record = slot.emitterRecords[id]
    if record == nil then
      error(invalid("opening scene emitter start names no compiled emitter", { emitter = id }), 0)
    end
    if record.group ~= group then
      error(invalid("opening scene emitter start leaves its source group", { emitter = id, group = group }), 0)
    end
    slot.emitters[#slot.emitters + 1] = {
      id = id,
      group = group,
      record = record,
      age = 0,
      credit = 0,
      particles = {},
    }
  end
end

---@param record table<string, unknown> compiled starter emitter record
---@return number originX, number originY source-pixel emission origin
local function emitterOrigin(record)
  local position = record.position --[[@as { x: number, y: number, z: number }]]
  return STAGE_CENTER_X + position.x * WORLD_TO_SOURCE_PX, STAGE_CENTER_Y - position.y * WORLD_TO_SOURCE_PX
end

---@param record table<string, unknown> compiled starter emitter record
---@return number axisX, number axisY normalized screen-space emission axis
local function emitterScreenAxis(record)
  local axis = record.axis --[[@as { x: number, y: number, z: number }]]
  local length = math.sqrt(axis.x * axis.x + axis.y * axis.y)
  if length <= 0 then
    return 0, -1
  end
  return axis.x / length, -axis.y / length
end

---@param record table<string, unknown> compiled starter emitter record
---@return number spinRate radians added to each particle per source tick
local function emitterSpinRate(record)
  local fields = record.fields --[[@as table<string, unknown>[] ]]
  for _, field in ipairs(fields) do
    local entry = field --[[@as table<string, unknown>]]
    if entry.kind == "spin" then
      return entry.rotation --[[@as number]] / 65536 * 2 * math.pi
    end
  end
  return 0
end

---@param slot OpeningMovieSlot scene slot
---@param runtime table<string, unknown> live emitter runtime gaining one particle
local function spawnParticle(slot, runtime)
  local record = runtime.record --[[@as table<string, unknown>]]
  local radius = record.radius --[[@as number]]
  local length = record.length --[[@as number]]
  local originX, originY = emitterOrigin(record)
  local axisX, axisY = emitterScreenAxis(record)
  local angle = (rngNext(slot) % 3600) / 3600 * 2 * math.pi
  local radial = (rngNext(slot) % 1000) / 1000
  local along = ((rngNext(slot) % 1000) / 1000 - 0.5) * length * WORLD_TO_SOURCE_PX
  local spread = radius * WORLD_TO_SOURCE_PX * radial
  local velocity = record.velocity --[[@as { initial: number, axis: number }]]
  local speed = velocity.initial * WORLD_TO_SOURCE_PX
  local drift = velocity.axis * WORLD_TO_SOURCE_PX
  local rotation = record.rotation --[[@as { min: number, max: number }]]
  local spin = 0
  if rotation.max ~= rotation.min then
    local span = math.floor(rotation.max - rotation.min + 1)
    spin = rotation.min + (rngNext(slot) % span)
  else
    spin = rotation.min
  end
  local life = record.particleLife --[[@as integer]]
  runtime.particles[#runtime.particles + 1] = {
    x = originX + math.cos(angle) * spread + axisX * along,
    y = originY + math.sin(angle) * spread + axisY * along,
    vx = axisX * speed - axisY * drift,
    vy = axisY * speed + axisX * drift,
    life = life,
    maxLife = life,
    rot = spin / 65536 * 2 * math.pi + emitterSpinRate(record),
  }
end

---@param record table<string, unknown> compiled starter emitter record
---@param particle table<string, unknown> live particle gaining field acceleration
---@param originX number source-pixel emitter origin
---@param originY number source-pixel emitter origin
local function applyEmitterFields(record, particle, originX, originY)
  local fields = record.fields --[[@as table<string, unknown>[] ]]
  for _, field in ipairs(fields) do
    local entry = field --[[@as table<string, unknown>]]
    if entry.kind == "gravity" then
      local magnitude = entry.magnitude --[[@as { x: number, y: number, z: number }]]
      particle.vx = particle.vx --[[@as number]] + magnitude.x * WORLD_TO_SOURCE_PX
      particle.vy = particle.vy --[[@as number]] - magnitude.y * WORLD_TO_SOURCE_PX
    elseif entry.kind == "magnet" then
      local target = entry.position --[[@as { x: number, y: number, z: number }]]
      local dx = originX + target.x * WORLD_TO_SOURCE_PX - particle.x --[[@as number]]
      local dy = originY - target.y * WORLD_TO_SOURCE_PX - particle.y --[[@as number]]
      local distance = math.sqrt(dx * dx + dy * dy)
      if distance > 1e-6 then
        local pull = entry.magnitude --[[@as number]] * WORLD_TO_SOURCE_PX
        particle.vx = particle.vx --[[@as number]] + dx / distance * pull
        particle.vy = particle.vy --[[@as number]] + dy / distance * pull
      end
    end
    -- Spin advances the rendered rotation (see spawnParticle); it carries
    -- no trajectory term in the observed records.
  end
end

---@param slot OpeningMovieSlot scene slot
---@param group string starter group to advance one source tick
local function advanceEmitters(slot, group)
  for _, runtime in ipairs(slot.emitters) do
    if runtime.group == group then
      local record = runtime.record --[[@as table<string, unknown>]]
      runtime.age = runtime.age --[[@as integer]] + 1
      local emitterLife = record.emitterLife --[[@as integer]]
      if runtime.age <= emitterLife then
        local generation = record.generation --[[@as { count: number, interval: integer }]]
        runtime.credit = runtime.credit --[[@as number]] + generation.count / generation.interval
        local due = math.floor(runtime.credit --[[@as number]])
        runtime.credit = runtime.credit --[[@as number]] - due
        for _ = 1, due do
          spawnParticle(slot, runtime)
        end
      end
      local originX, originY = emitterOrigin(record)
      local spin = emitterSpinRate(record)
      local live = {}
      for _, particle in ipairs(runtime.particles) do
        local entry = particle --[[@as table<string, unknown>]]
        applyEmitterFields(record, entry, originX, originY)
        entry.x = entry.x --[[@as number]] + entry.vx --[[@as number]]
        entry.y = entry.y --[[@as number]] + entry.vy --[[@as number]]
        entry.rot = entry.rot --[[@as number]] + spin
        entry.life = entry.life --[[@as integer]] - 1
        if
          entry.life --[[@as integer]]
          > 0
        then
          live[#live + 1] = entry
        end
      end
      runtime.particles = live
    end
  end
  for name, effect in pairs(slot.effects) do
    local effectGroup = name:match("^emitters%-(.+)$")
    if effectGroup ~= nil and not effect.done then
      local live = false
      for _, runtime in ipairs(slot.emitters) do
        if runtime.group == effectGroup then
          local record = runtime.record --[[@as table<string, unknown>]]
          if
            runtime.age --[[@as integer]]
              <= record.emitterLife --[[@as integer]]
            or #runtime.particles > 0
          then
            live = true
            break
          end
        end
      end
      if not live then
        effect.done = true
      end
    end
  end
end

---@param self HgssOpeningMovie
---@param slot OpeningMovieSlot scene slot
---@param event table<string, unknown> authored timeline event
local function applyEvent(self, slot, event)
  local op = event.op
  if op == "setLayer" then
    if event.art ~= nil then
      slot.activeArt[event.role] = event.art
    elseif slot.activeArt[event.role] == nil then
      local layers = slot.manifest.layers[event.role]
      if type(layers) == "table" and layers[1] ~= nil then
        slot.activeArt[event.role] = layers[1].image
      end
    end
  elseif op == "setPalette" then
    slot.palette = event
  elseif op == "setScroll" then
    local key = event.layer or event.target
    local entry = {
      dx = (event.dx or 0) / SCROLL_DIVISOR,
      dy = (event.dy or 0) / SCROLL_DIVISOR,
      remaining = event.ticks,
      total = event.ticks,
      x = 0,
      y = 0,
    }
    if key ~= nil then
      slot.scrolls[key] = entry
      startTimedEffect(slot, "scroll-" .. tostring(key), event.ticks)
    else
      slot.panAll = entry
    end
  elseif op == "setBlend" then
    slot.blend = { effect = event.effect, from = event.from, to = event.to, ticks = event.ticks, elapsed = 0 }
    startTimedEffect(slot, event.effect, event.ticks)
  elseif op == "window" then
    slot.window = { target = event.target, kind = event.kind, ticks = event.ticks, elapsed = 0 }
    startTimedEffect(slot, "window-" .. tostring(event.kind or event.target), event.ticks)
  elseif op == "circleWipe" then
    slot.wipe = { mode = event.mode, ticks = event.ticks or 18, elapsed = 0 }
    startTimedEffect(slot, "wipe-circle", event.ticks)
  elseif op == "setSpriteClip" then
    local sprite = slot.sprites[event.sprite]
    if sprite == nil then
      sprite = { tick = 0, visible = false, quads = {} }
      slot.sprites[event.sprite] = sprite
      slot.spriteOrder[#slot.spriteOrder + 1] = event.sprite
    end
    sprite.clipId = event.clip
    sprite.tick = 0
    sprite.quads = {}
  elseif op == "spriteVisible" then
    local sprite = slot.sprites[event.sprite]
    if sprite == nil then
      sprite = { tick = 0, visible = event.visible, quads = {} }
      slot.sprites[event.sprite] = sprite
      slot.spriteOrder[#slot.spriteOrder + 1] = event.sprite
    else
      sprite.visible = event.visible
    end
  elseif op == "setModelClip" then
    slot.activeTown = event.model
    slot.townClipTicks[event.model] = 0
  elseif op == "setCamera" then
    slot.cameraDistance = event.distance
  elseif op == "setLighting" then
    slot.lightingMap = event.map
  elseif op == "startEmitters" then
    startEmitters(slot, event.group, event.emitters)
  elseif op == "setScreenRoles" then
    slot.screenRoles = { upper = event.upper, lower = event.lower }
  elseif op == "setFade" then
    slot.fade = { kind = event.kind, ticks = event.ticks, elapsed = 0 }
    startTimedEffect(slot, "fade-" .. tostring(event.kind), event.ticks)
  elseif op == "waitTicks" then
    -- Duration steps own the wait; the event only marks the authored beat.
  elseif op == "waitEffects" then
    for _, name in ipairs(event.effects) do
      local group = name:match("^emitters%-(.+)$")
      if group ~= nil and slot.effects[name] == nil then
        error(invalid("opening scene waits on emitters that never started", { effect = name }), 0)
      end
    end
  elseif op == "enableSkip" then
    self.skipEligible = true
  elseif op == "finish" then
    self.pendingFinish = true
  else
    error(invalid("opening scene event is outside the closed movie grammar", { op = op }), 0)
  end
end

---@param self HgssOpeningMovie
---@param slot OpeningMovieSlot scene slot
local function applyDueEvents(self, slot)
  local steps = slot.manifest.timeline.steps
  local events = slot.manifest.timeline.events
  local step = steps[slot.stepIndex]
  if step == nil then
    return
  end
  for _, index in ipairs(step.events) do
    if not slot.applied[index] and events[index].atTick <= slot.sceneTick then
      slot.applied[index] = true
      applyEvent(self, slot, events[index])
    end
  end
end

---@param slot OpeningMovieSlot scene slot
local function advanceContinuous(slot)
  for _, scroll in pairs(slot.scrolls) do
    if scroll.remaining > 0 then
      scroll.x = scroll.x + scroll.dx
      scroll.y = scroll.y + scroll.dy
      scroll.remaining = scroll.remaining - 1
    end
  end
  local pan = slot.panAll
  if pan.remaining > 0 then
    pan.x = pan.x + pan.dx
    pan.y = pan.y + pan.dy
    pan.remaining = pan.remaining - 1
  end
  for _, effect in pairs(slot.effects) do
    if not effect.done and effect.remaining ~= nil then
      effect.remaining = effect.remaining - 1
      if effect.remaining <= 0 then
        effect.done = true
      end
    end
  end
  if slot.blend ~= nil and slot.blend.elapsed < slot.blend.ticks then
    slot.blend.elapsed = slot.blend.elapsed + 1
  end
  if slot.fade ~= nil and slot.fade.elapsed < slot.fade.ticks then
    slot.fade.elapsed = slot.fade.elapsed + 1
  end
  if slot.wipe ~= nil and slot.wipe.elapsed < slot.wipe.ticks then
    slot.wipe.elapsed = slot.wipe.elapsed + 1
  end
  if slot.window ~= nil and slot.window.ticks ~= nil and slot.window.elapsed < slot.window.ticks then
    slot.window.elapsed = slot.window.elapsed + 1
  end
  for _, sprite in pairs(slot.sprites) do
    sprite.tick = sprite.tick + 1
  end
  for name in pairs(slot.townClipTicks) do
    slot.townClipTicks[name] = slot.townClipTicks[name] + 1
  end
  if #slot.manifest.models > 0 and slot.renderer == nil then
    slot.cameraDrift = slot.cameraDrift + 1
  end
  for name in pairs(slot.effects) do
    local group = name:match("^emitters%-(.+)$")
    if group ~= nil then
      advanceEmitters(slot, group)
    end
  end
  for _, town in ipairs(slot.towns) do
    town.instance:updateFixed()
    town.instance:evaluatePose()
  end
end

---@param slot OpeningMovieSlot scene slot
---@return number longest authored tick count inside the step
local function stepOwnTicks(slot)
  local steps = slot.manifest.timeline.steps
  local events = slot.manifest.timeline.events
  local step = steps[slot.stepIndex]
  if step == nil then
    return 0
  end
  local longest = 0
  for _, index in ipairs(step.events) do
    local ticks = events[index].ticks
    if type(ticks) == "number" and ticks > longest then
      longest = ticks
    end
  end
  return longest
end

---@param slot OpeningMovieSlot scene slot
---@return boolean true when the active step has run its source course
local function stepComplete(slot)
  local steps = slot.manifest.timeline.steps
  local step = steps[slot.stepIndex]
  if step == nil then
    return true
  end
  local finish = step["until"]
  if finish.kind == "duration" then
    return slot.stepElapsed >= finish.ticks
  end
  local group = finish.effect:match("^emitters%-(.+)$")
  if group ~= nil then
    return emittersDone(slot, group)
  end
  return slot.stepElapsed >= stepOwnTicks(slot) and timedEffectDone(slot, finish.effect)
end

---@param self HgssOpeningMovie
local function ensureNext(self)
  if self.currentIndex >= 5 or self.nextSlot ~= nil then
    return
  end
  self.nextSlot = acquireSlot(self, self.scenes[self.currentIndex + 1])
end

---@param self HgssOpeningMovie
local function finishCurrentScene(self)
  local finished = self.currentIndex >= 5
  if finished then
    self.finished = true
    self.pendingFinish = false
    return
  end
  local old = assert(self.current)
  local replacement = self.nextSlot
  self.nextSlot = nil
  if replacement == nil then
    replacement = acquireSlot(self, self.scenes[self.currentIndex + 1])
  end
  self.currentIndex = self.currentIndex + 1
  self.current = replacement
  self.pendingFinish = false
  releaseSlot(old)
end

-- Loads the five strictly validated scene manifests for the selected edition
-- in retail order. This is the movie-owner scene-loading seam through which
-- the app startup owner reaches generated opening scenes: callers keep the owned
-- manifests and pass them to the constructor, which retains its input shape.
---@param cacheFs table<string, unknown> generated cache access
---@param versionId string selected edition
---@return table[]? scenes five validated manifests in retail order
---@return unknown? failure first scene load failure
function HgssOpeningMovie.loadValidatedScenes(cacheFs, versionId)
  local scenes = {}
  for sceneNumber = 1, 5 do
    local manifest, failure = StartupAssetCache.loadOpeningScene(cacheFs, sceneNumber, versionId)
    if manifest == nil then
      return nil, failure
    end
    scenes[sceneNumber] = manifest
  end
  return scenes, nil
end

---@param options { versionId: string, scenes: table<string, unknown>[], cacheFs: table<string, unknown>, width: number, height: number, graphics?: table<string, unknown>, displayContext?: DisplayContext }
---@return HgssOpeningMovie
function HgssOpeningMovie.new(options)
  assert(type(options) == "table", "opening movie requires composition options")
  assert(options.versionId == "heartgold" or options.versionId == "soulsilver", "opening movie edition is invalid")
  assert(type(options.scenes) == "table", "opening movie requires five validated scene bundles")
  assert(options.cacheFs and type(options.cacheFs.read) == "function", "opening movie requires generated cache access")
  assert(
    type(options.width) == "number" and options.width > 0 and type(options.height) == "number" and options.height > 0,
    "opening movie dimensions must be positive"
  )
  local graphics = options.graphics or love.graphics
  assert(type(graphics) == "table", "opening movie requires a graphics namespace")
  local displayContext = options.displayContext or DisplayContext.new({ graphics = graphics })
  local scenes = options.scenes
  for sceneNumber = 1, 5 do
    if scenes[sceneNumber] == nil then
      error(invalid("opening movie needs all five scenes in retail order", { scene = sceneNumber }), 0)
    end
  end
  if #scenes ~= 5 then
    error(invalid("opening movie needs all five scenes in retail order", { count = #scenes }), 0)
  end
  local first = scenes[1]
  if type(first) ~= "table" or type(first.generationId) ~= "string" or first.generationId == "" then
    error(invalid("opening movie generation is missing", {}), 0)
  end
  for sceneNumber = 1, 5 do
    validateManifest(scenes[sceneNumber], sceneNumber, options.versionId, first.generationId)
  end
  local self = setmetatable({
    versionId = options.versionId,
    cacheFs = options.cacheFs,
    graphics = graphics,
    displayContext = displayContext,
    width = options.width,
    height = options.height,
    scenes = scenes,
    generationId = first.generationId,
    currentIndex = 1,
    finished = false,
    skipEligible = false,
    pendingFinish = false,
    disposed = false,
    current = nil,
    nextSlot = nil,
    canvas = nil,
    canvasWidth = nil,
    canvasHeight = nil,
  }, HgssOpeningMovie)
  local ok, failure = pcall(function()
    local canvas = graphics.newCanvas(options.width, options.height, {
      format = "rgba8",
      readable = true,
      dpiscale = 1,
    })
    self.canvas = canvas
    self.canvasWidth, self.canvasHeight = options.width, options.height
    self.current = acquireSlot(self, scenes[1])
  end)
  if not ok then
    self:dispose()
    error(failure, 0)
  end
  return self
end

function HgssOpeningMovie:updateFixed()
  assert(not self.disposed, "disposed movie cannot advance")
  if self.finished then
    return
  end
  ensureNext(self)
  local slot = assert(self.current)
  slot.sceneTick = slot.sceneTick + 1
  slot.stepElapsed = slot.stepElapsed + 1
  applyDueEvents(self, slot)
  advanceContinuous(slot)
  local guard = 0
  while not self.finished do
    guard = guard + 1
    assert(guard < 4096, "opening movie step cascade cannot settle")
    if not stepComplete(slot) then
      break
    end
    if self.pendingFinish then
      finishCurrentScene(self)
      break
    end
    local steps = slot.manifest.timeline.steps
    slot.stepIndex = slot.stepIndex + 1
    slot.stepElapsed = 0
    if slot.stepIndex > #steps then
      finishCurrentScene(self)
      break
    end
    applyDueEvents(self, slot)
  end
end

---@return boolean
function HgssOpeningMovie:skipAllowed()
  return self.skipEligible and not self.finished and not self.disposed
end

---@return boolean true when an eligible skip finishes the movie
function HgssOpeningMovie:requestSkip()
  if self.disposed or self.finished or not self.skipEligible then
    return false
  end
  self.finished = true
  self.pendingFinish = false
  return true
end

---@return boolean
function HgssOpeningMovie:isFinished()
  return self.finished
end

---@return integer
function HgssOpeningMovie:sceneNumber()
  return self.currentIndex
end

---@param width number
---@param height number
function HgssOpeningMovie:resize(width, height)
  assert(width > 0 and height > 0, "movie dimensions must be positive")
  self.width, self.height = width, height
  if self.disposed or self.canvas == nil then
    return
  end
  if self.canvasWidth == width and self.canvasHeight == height then
    return
  end
  local ok, canvas = pcall(self.graphics.newCanvas, self.graphics, width, height, {
    format = "rgba8",
    readable = true,
    dpiscale = 1,
  })
  if not ok then
    return
  end
  local old = assert(self.canvas)
  self.canvas, self.canvasWidth, self.canvasHeight = canvas, width, height
  old:release()
end

-- Maps the semantic upper/lower source roles onto the measured host
-- surfaces: physical dual honors both surfaces, tall stacks them, and
-- single-screen stages fill with the upper role while the lower role
-- rides as a subordinate strip. Reflow never touches source time.
---@param rect { x: number, y: number, width: number, height: number }
---@return { x: number, y: number, width: number, height: number }
local function copyRect(rect)
  return { x = rect.x, y = rect.y, width = rect.width, height = rect.height }
end

---@param self HgssOpeningMovie
---@return { configuration: string, upper: { x: number, y: number, width: number, height: number }, lower: { x: number, y: number, width: number, height: number } }
local function roleRects(self)
  local measurement = self.displayContext:measure(self.width, self.height)
  local configuration = ApplicationLayout.classify(measurement, nil)
  local selection = ApplicationLayout.selectSurfaces(measurement)
  local primary = selection.primary.usableBounds
  if primary == nil then
    primary = { x = 0, y = 0, width = self.width, height = self.height }
  end
  if configuration == "dualDisplay" and selection.secondary ~= nil and selection.secondary.usableBounds ~= nil then
    return {
      configuration = configuration,
      upper = copyRect(primary),
      lower = copyRect(selection.secondary.usableBounds),
    }
  end
  if configuration == "tall" then
    local half = primary.height / 2
    return {
      configuration = configuration,
      upper = { x = primary.x, y = primary.y, width = primary.width, height = half },
      lower = { x = primary.x, y = primary.y + half, width = primary.width, height = primary.height - half },
    }
  end
  local stripHeight = math.min(primary.height * 0.3, 128)
  return {
    configuration = configuration,
    upper = copyRect(primary),
    lower = { x = primary.x, y = primary.y, width = primary.width, height = stripHeight },
  }
end

---@param slot OpeningMovieSlot scene slot
---@param clipId string staged sprite clip identity
---@return table<string, unknown>? clip record
local function clipById(slot, clipId)
  for _, clip in ipairs(slot.manifest.spriteClips) do
    if clip.id == clipId then
      return clip
    end
  end
  return nil
end

---@param sprite table<string, unknown> sprite animation state
---@param clip table<string, unknown> staged sprite clip record
---@return integer 1-based frame index
local function spriteFrameIndex(sprite, clip)
  local count = clip.frameCount or 1
  if count <= 1 then
    return 1
  end
  if type(clip.frames) == "table" and #clip.frames > 0 then
    local total = 0
    for _, frame in ipairs(clip.frames) do
      total = total + (frame.duration or 1)
    end
    total = math.max(total, 1)
    local elapsed = sprite.tick % total
    for index, frame in ipairs(clip.frames) do
      local duration = frame.duration or 1
      if elapsed < duration then
        return index
      end
      elapsed = elapsed - duration
    end
    return #clip.frames
  end
  return (math.floor(sprite.tick / 8) % count) + 1
end

---@param order integer appearance order of the sprite in its scene
---@return number x, number y slot origin in source pixels
local function spriteSlotPosition(order)
  return 32 + ((order - 1) * 56) % 192, 64 + ((order - 1) * 37) % 96
end

---@param slot OpeningMovieSlot scene slot
---@param role string upper or lower
---@return number x, number y accumulated scroll offset in source pixels
local function roleScrollOffset(slot, role)
  local x, y = slot.panAll.x, slot.panAll.y
  local layers = slot.manifest.layers[role]
  if type(layers) == "table" then
    for key, scroll in pairs(slot.scrolls) do
      for _, layer in ipairs(layers) do
        if layer.slot == key or layer.image == key then
          x = x + scroll.x
          y = y + scroll.y
        end
      end
    end
  end
  return x, y
end

---@param slot OpeningMovieSlot scene slot
---@return number layer alpha following the active blend program
local function layerAlpha(slot)
  local blend = slot.blend
  if blend == nil or blend.ticks <= 0 then
    return 1
  end
  return 1 - 0.5 * math.min(blend.elapsed / blend.ticks, 1)
end

---@param slot OpeningMovieSlot scene slot
---@param role string upper or lower
---@return number inset shrinking the role clip in source pixels
local function windowInset(slot, role)
  local window = slot.window
  if window == nil then
    return 0
  end
  if window.target == "upper" or window.target == "lower" then
    if window.target ~= role then
      return 0
    end
  end
  if window.ticks == nil or window.ticks <= 0 then
    return 0
  end
  return 24 * math.min(window.elapsed / window.ticks, 1)
end

---@param value unknown raw channel value in 0..1
---@return integer quantized 5-bit channel
local function channel31(value)
  if type(value) ~= "number" then
    return 0
  end
  return math.max(0, math.min(31, math.floor(value * 31 + 0.5)))
end

---@param value unknown raw 0..1 RGB triple in either array or named shape
---@return number[] normalized triple with numeric channels
local function tripleOrZero(value)
  if type(value) ~= "table" then
    return { 0, 0, 0 }
  end
  local function channel(valueChannel)
    return (type(valueChannel) == "number") and valueChannel or 0
  end
  return {
    channel(value[1] or value.r),
    channel(value[2] or value.g),
    channel(value[3] or value.b),
  }
end

---@param triple unknown 0..1 RGB triple in either array or named shape
---@return integer packed RGB555 register
local function toRgb555(triple)
  if triple == nil then
    return 0
  end
  local rgb = tripleOrZero(triple)
  return channel31(rgb[1]) + 32 * channel31(rgb[2]) + 1024 * channel31(rgb[3])
end

---@param slot OpeningMovieSlot scene slot
---@return number town index backing the active model or lighting step
local function activeTownIndex(slot)
  if slot.lightingMap ~= nil then
    return slot.lightingMap
  end
  for index, town in ipairs(slot.towns) do
    if town.name == slot.activeTown then
      return town.index or (index - 1)
    end
  end
  return 0
end

---@param slot OpeningMovieSlot scene slot
---@return table<string, unknown> render environment with source town lighting
local function townEnvironment(slot)
  local lighting = slot.manifest.lighting
  local towns = (type(lighting) == "table") and lighting.towns or nil
  local record = (type(towns) == "table") and towns[activeTownIndex(slot) + 1] or nil
  local vectors = (type(record) == "table") and record.vectors or nil
  local colors = (type(record) == "table") and record.colors or nil
  if slot.townEnvKey ~= activeTownIndex(slot) or slot.townEnv == nil then
    local lights = {}
    for index = 1, 4 do
      local rawVector = (type(vectors) == "table") and vectors[index] or nil
      local rawColor = (type(colors) == "table") and colors[index] or nil
      local color = tripleOrZero(rawColor)
      local vector = tripleOrZero(rawVector)
      local lit = (color[1] + color[2] + color[3]) > 0
      lights[index] = {
        enabled = lit,
        color = lit and { color[1], color[2], color[3] } or { 0, 0, 0 },
        direction = { vector[1], vector[2], vector[3] },
        colorRgb555 = lit and toRgb555(color) or 0,
        vectorFx12 = {
          math.floor(vector[1] * 4096 + 0.5),
          math.floor(vector[2] * 4096 + 0.5),
          math.floor(vector[3] * 4096 + 0.5),
        },
      }
    end
    slot.townEnv = {
      lighting = {
        records = {
          {
            endHalfSeconds = NOON_HALF_SECONDS * 2,
            lights = lights,
            diffuseRgb555 = toRgb555(record and record.diffuse),
            ambientRgb555 = toRgb555(record and record.ambient),
            specularRgb555 = toRgb555(record and record.specular),
            emissionRgb555 = toRgb555(record and record.emission),
          },
        },
      },
      edgeColors = { [0] = 0, 0, 0, 0, 0, 0, 0, 0 },
      fog = {
        enabled = false,
        color = 0,
        offset = 0,
        slope = 0,
        alpha = 0,
        table = {
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
        },
      },
    }
    slot.townEnvKey = activeTownIndex(slot)
  end
  return slot.townEnv
end

---@param slot OpeningMovieSlot scene slot
---@param rect { x: number, y: number, width: number, height: number } device-space role rectangle
---@return table<string, unknown> camera track for the shared field renderer
local function townCamera(slot, rect)
  local camera = slot.manifest.camera
  local target = (camera and camera.target) or { 0, 0, 96 }
  local distance = slot.cameraDistance or (camera and camera.distance) or 410
  local eye = { target[1], target[2], target[3] + distance }
  local viewMatrix = Matrix4.lookAt(eye, target, { 0, 1, 0 })
  local halfAngle = (HALF_ANGLE_INDEX / 65536) * (2 * math.pi)
  local projectionMatrix = Matrix4.perspective(2 * halfAngle, rect.width / math.max(rect.height, 1), GPU_NEAR, GPU_FAR)
  local function cameraView()
    return viewMatrix
  end
  local function cameraProjection()
    return projectionMatrix
  end
  return {
    far = GPU_FAR,
    zoom = 1,
    view = cameraView,
    projection = cameraProjection,
    billboardProjection = cameraProjection,
  }
end

local function worldDrawItems(instance, meshes)
  local items = instance:drawItems(meshes)
  for _, item in ipairs(items) do
    item.worldSpace = true
  end
  return items
end

---@param slot OpeningMovieSlot scene slot
---@param rect { x: number, y: number, width: number, height: number } device-space role rectangle
local function drawTowns(slot, rect)
  local active = slot.towns[1]
  for _, town in ipairs(slot.towns) do
    if town.name == slot.activeTown then
      active = town
      break
    end
  end
  if active == nil or active.instance == nil then
    return
  end
  local instance = active.instance
  local meshes = assert(instance.renderMeshesById)
  local items = worldDrawItems(instance, meshes)
  local viewport = {
    worldViewport = { x = rect.x, y = rect.y, width = rect.width, height = rect.height },
    referenceFrame = { x = rect.x, y = rect.y, width = rect.width, height = rect.height },
  }
  slot.renderer:draw(townEnvironment(slot), townCamera(slot, rect), { items }, nil, viewport, 1)
end

---@param slot OpeningMovieSlot scene slot
local function drawSprites(self, slot)
  local graphics = self.graphics
  for order, name in ipairs(slot.spriteOrder) do
    local sprite = slot.sprites[name]
    if sprite ~= nil and sprite.visible and sprite.clipId ~= nil then
      local image = slot.imageByPath[sprite.clipId]
      if image ~= nil then
        local clip = clipById(slot, sprite.clipId)
        local frame = (clip ~= nil) and spriteFrameIndex(sprite, clip) or 1
        local x, y = spriteSlotPosition(order)
        x = x + slot.panAll.x
        y = y + slot.panAll.y
        local quad = nil
        if clip ~= nil and type(clip.frames) == "table" and clip.frames[frame] ~= nil then
          local record = clip.frames[frame]
          if type(record.x) == "number" and type(record.width) == "number" and record.width > 0 then
            quad = sprite.quads[frame]
            if quad == nil then
              local imageWidth, imageHeight = image:getWidth(), image:getHeight()
              local clipped = pcall(function()
                sprite.quads[frame] = graphics.newQuad(
                  math.max(record.x, 0),
                  math.max(record.y or 0, 0),
                  math.min(record.width, imageWidth),
                  math.min(record.height or imageHeight, imageHeight),
                  imageWidth,
                  imageHeight
                )
              end)
              if clipped then
                quad = sprite.quads[frame]
              end
            end
          end
        end
        if quad ~= nil then
          graphics.draw(image, quad, x, y)
        else
          graphics.draw(image, x, y)
        end
      end
    end
  end
end

---@param slot OpeningMovieSlot scene slot
local function drawParticles(self, slot)
  local graphics = self.graphics
  -- Each live particle paints its own recorded texture, tinted by the
  -- recorded base color, faded by the recorded base alpha (linearly to
  -- zero over its life when the record carries the alpha animation flag),
  -- and drawn at the recorded base scale (settling to half size when the
  -- record carries the scale animation flag).
  for _, runtime in ipairs(slot.emitters) do
    local record = runtime.record --[[@as table<string, unknown>]]
    local textureImage = record.textureImage --[[@as string]]
    local image = slot.imageByPath[textureImage]
    assert(image ~= nil, "opening scene staged particle art is missing: " .. tostring(textureImage))
    local imageWidth, imageHeight = image:getWidth(), image:getHeight()
    local tintR, tintG, tintB = emitterColorChannels(record.baseColor)
    local baseAlpha = record.baseAlpha --[[@as number]] / 31
    local baseScale = record.baseScale --[[@as number]]
    local animations = record.animations --[[@as table<string, unknown>]]
    for _, particle in ipairs(runtime.particles) do
      local entry = particle --[[@as table<string, unknown>]]
      local life = entry.life --[[@as integer]]
      if life > 0 then
        local maxLife = entry.maxLife --[[@as integer]]
        local fade = 1
        if animations.alpha == true then
          fade = life / maxLife
        end
        local scale = baseScale
        if animations.scale == true then
          scale = scale * (0.5 + 0.5 * life / maxLife)
        end
        graphics.setColor(tintR, tintG, tintB, baseAlpha * fade)
        graphics.draw(
          image,
          entry.x --[[@as number]],
          entry.y --[[@as number]],
          entry.rot --[[@as number]],
          scale,
          scale,
          imageWidth / 2,
          imageHeight / 2
        )
      end
    end
  end
  graphics.setColor(1, 1, 1, 1)
end

---@param slot OpeningMovieSlot scene slot
local function drawFade(self, slot)
  local fade = slot.fade
  if fade == nil then
    return
  end
  local progress = math.min(fade.elapsed / math.max(fade.ticks, 1), 1)
  local kind = fade.kind or ""
  local clearing = kind:find("in", 1, true) ~= nil or kind:find("open", 1, true) ~= nil
  local alpha = clearing and (1 - progress) or progress
  local white = kind:find("white", 1, true) ~= nil
  if white then
    self.graphics.setColor(1, 1, 1, alpha)
  else
    self.graphics.setColor(0, 0, 0, alpha)
  end
  self.graphics.rectangle("fill", 0, 0, SOURCE_WIDTH, SOURCE_HEIGHT)
  self.graphics.setColor(1, 1, 1, 1)
end

---@param slot OpeningMovieSlot scene slot
local function drawWipe(self, slot)
  local wipe = slot.wipe
  if wipe == nil then
    return
  end
  local progress = math.min(wipe.elapsed / math.max(wipe.ticks, 1), 1)
  local hole = (wipe.mode == "in") and progress or (1 - progress)
  if hole <= 0 then
    self.graphics.setColor(0, 0, 0, 1)
    self.graphics.rectangle("fill", 0, 0, SOURCE_WIDTH, SOURCE_HEIGHT)
    self.graphics.setColor(1, 1, 1, 1)
    return
  end
  if hole >= 1 then
    return
  end
  local graphics = self.graphics
  graphics.setColor(0, 0, 0, 1)
  local halfWidth, halfHeight = (SOURCE_WIDTH / 2) * hole, (SOURCE_HEIGHT / 2) * hole
  local left, top = SOURCE_WIDTH / 2 - halfWidth, SOURCE_HEIGHT / 2 - halfHeight
  graphics.rectangle("fill", 0, 0, SOURCE_WIDTH, top)
  graphics.rectangle("fill", 0, top + halfHeight * 2, SOURCE_WIDTH, SOURCE_HEIGHT - top - halfHeight * 2)
  graphics.rectangle("fill", 0, top, left, halfHeight * 2)
  graphics.rectangle("fill", left + halfWidth * 2, top, SOURCE_WIDTH - left - halfWidth * 2, halfHeight * 2)
  graphics.setColor(1, 1, 1, 1)
end

---@param self HgssOpeningMovie
---@param slot OpeningMovieSlot scene slot
---@param role string upper or lower
---@param rect { x: number, y: number, width: number, height: number } device-space role rectangle
local function drawRoleBody(self, slot, role, rect)
  local graphics = self.graphics
  local inset = windowInset(slot, role)
  graphics.intersectScissor(rect.x + inset, rect.y + inset, rect.width - inset * 2, rect.height - inset * 2)
  if role == "upper" and slot.renderer ~= nil and #slot.towns > 0 then
    drawTowns(slot, rect)
  end
  local scale = math.max(rect.width / SOURCE_WIDTH, rect.height / SOURCE_HEIGHT)
  local drawnWidth, drawnHeight = SOURCE_WIDTH * scale, SOURCE_HEIGHT * scale
  graphics.translate(rect.x + (rect.width - drawnWidth) / 2, rect.y + (rect.height - drawnHeight) / 2)
  graphics.scale(scale, scale)
  local scrollX, scrollY = roleScrollOffset(slot, role)
  if #slot.manifest.models > 0 and slot.renderer == nil and role == "upper" then
    scrollX = scrollX + (slot.cameraDrift % 64) * 0.25
  end
  local active = slot.activeArt[role]
  local image = active and slot.imageByPath[active] or nil
  graphics.setColor(1, 1, 1, layerAlpha(slot))
  if image ~= nil then
    graphics.draw(image, scrollX, scrollY)
  end
  graphics.setColor(1, 1, 1, 1)
  drawSprites(self, slot)
  drawParticles(self, slot)
  drawFade(self, slot)
  drawWipe(self, slot)
end

---@param self HgssOpeningMovie
---@param slot OpeningMovieSlot scene slot
---@param role string upper or lower
---@param rect { x: number, y: number, width: number, height: number } device-space role rectangle
local function drawRole(self, slot, role, rect)
  local graphics = self.graphics
  graphics.push("all")
  local ok, failure = pcall(drawRoleBody, self, slot, role, rect)
  graphics.pop()
  if not ok then
    error(failure, 0)
  end
end

function HgssOpeningMovie:_render()
  local slot = self.current
  if slot == nil or self.canvas == nil then
    return
  end
  local graphics = self.graphics
  local rects = roleRects(self)
  local previous = graphics.getCanvas()
  graphics.setCanvas(self.canvas)
  graphics.clear(0, 0, 0, 1)
  drawRole(self, slot, "upper", rects.upper)
  drawRole(self, slot, "lower", rects.lower)
  graphics.setCanvas(previous)
  graphics.setColor(1, 1, 1, 1)
  local canvasWidth = self.canvasWidth or self.width
  local canvasHeight = self.canvasHeight or self.height
  graphics.draw(self.canvas, 0, 0, 0, self.width / canvasWidth, self.height / canvasHeight)
end

function HgssOpeningMovie:draw()
  if self.disposed then
    return
  end
  if self.canvas == nil then
    return
  end
  local graphics = self.graphics
  graphics.push("all")
  local ok, failure = pcall(function()
    self:_render()
  end)
  graphics.pop()
  if not ok then
    error(failure, 0)
  end
end

function HgssOpeningMovie:dispose()
  if self.disposed then
    return
  end
  self.disposed = true
  local current, nextSlot, canvas = self.current, self.nextSlot, self.canvas
  self.current, self.nextSlot, self.canvas = nil, nil, nil
  self.canvasWidth, self.canvasHeight = nil, nil
  if current ~= nil then
    releaseSlot(current)
  end
  if nextSlot ~= nil then
    releaseSlot(nextSlot)
  end
  if canvas ~= nil then
    canvas:release()
  end
end

return HgssOpeningMovie
