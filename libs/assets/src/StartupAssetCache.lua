-- Paths and strict readers for the source-independent startup visual bundles.

local Errors = require("libs.errors.src.Errors")
local Contract = require("libs.assets.src.DerivedAssetContract")
local ModelAsset = require("libs.assets.src.model.ModelAsset")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")

local StartupAssetCache = {}

local TITLE_PATH = "data/generated/startup/title.lua"

-- Canonical 32-choice walking pair: indices 1..16 name Ethan with each of
-- sixteen followers in fixed order, 17..32 name Lyra with the same order.
local FOLLOWER_SPECIES_IDS = { 1, 4, 7, 152, 155, 158, 252, 255, 258, 387, 390, 393, 133, 25, 143, 183 }
local EDITIONS = { heartgold = true, soulsilver = true }
local SOURCE_FIELDS = { fileId = true, narcId = true, memberId = true }

local function invalid(reason, context)
  return Errors.new("STARTUP_ASSET_INVALID", "startup asset is invalid: " .. reason, {
    reason = reason,
    context = context,
  })
end

local function containsSourceIdentity(value, ancestors)
  if type(value) ~= "table" then
    return false
  end
  if ancestors[value] then
    return true
  end
  ancestors[value] = true
  for key, child in pairs(value) do
    if SOURCE_FIELDS[key] or containsSourceIdentity(child, ancestors) then
      ancestors[value] = nil
      return true
    end
  end
  ancestors[value] = nil
  return false
end

local function onlyKeys(value, allowed)
  for key in pairs(value) do
    if not allowed[key] then
      return false
    end
  end
  return true
end

local function generatedPath(path, family)
  return type(path) == "string" and path:match("^assets/generated/startup/" .. family .. "/.+$") ~= nil
end

local function isFiniteNumber(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function isVector3(value)
  return type(value) == "table"
    and #value == 3
    and isFiniteNumber(value[1])
    and isFiniteNumber(value[2])
    and isFiniteNumber(value[3])
end

local function isNonnegativeInteger(value)
  return type(value) == "number" and value % 1 == 0 and value >= 0 and value ~= math.huge
end

local function isPositiveInteger(value)
  return type(value) == "number" and value % 1 == 0 and value > 0 and value ~= math.huge
end

local function isBoundedChannel(value)
  return isFiniteNumber(value) and value >= 0 and value <= 255
end

local function hasAnimationClips(model, clips)
  local descriptor = {}
  for key, value in pairs(model) do
    descriptor[key] = value
  end
  descriptor.animations = {}
  for _, clip in pairs(clips) do
    descriptor.animations[#descriptor.animations + 1] = clip
  end
  return pcall(ModelAsset.validate, descriptor)
end

local function validateTitleSurfaces(cacheFs, surfaces)
  local expectedRoles = { editionLogo = true, subscreenLower = true }
  if type(surfaces) ~= "table" or not onlyKeys(surfaces, expectedRoles) then
    return false, "title surface roles are incomplete"
  end
  for role in pairs(expectedRoles) do
    local surface = surfaces[role]
    if
      type(surface) ~= "table"
      or not onlyKeys(surface, { image = true, width = true, height = true, sourceHash = true })
      or surface.width ~= 256
      or surface.height ~= 192
      or not generatedPath(surface.image, "title")
      or type(surface.sourceHash) ~= "string"
      or #surface.sourceHash ~= 40
      or surface.sourceHash:find("[^0-9a-f]") ~= nil
    then
      return false, "title surface " .. role .. " is malformed"
    end
    if not cacheFs:exists(surface.image, "file") then
      return false, "title surface " .. role .. " image is missing"
    end
  end
  return true
end

-- The title timing contract is structural and playable: every phase
-- carries its required fields with finite coordinates, positive
-- durations and integer frame counts, but no single sample of retail
-- constants is frozen here. Source timing authority stays with the
-- producer; the reader only rejects what cannot play.
local function validateTitleTimeline(timeline)
  if
    type(timeline) ~= "table"
    or not onlyKeys(timeline, {
      camera = true,
      animation = true,
      titleReveal = true,
      start = true,
      glow = true,
      attachments = true,
    })
  then
    return false
  end
  local camera = timeline.camera
  if
    type(camera) ~= "table"
    or not onlyKeys(camera, { start = true, target = true, endPosition = true, points = true, movement = true })
    or type(camera.start) ~= "table"
    or not onlyKeys(camera.start, { position = true, target = true })
    or not isVector3(camera.start.position)
    or not isVector3(camera.start.target)
    or not isVector3(camera.target)
    or not isVector3(camera.endPosition)
    or type(camera.points) ~= "table"
    or #camera.points ~= 4
    or type(camera.movement) ~= "table"
    or not onlyKeys(camera.movement, { unitsPerFrame = true, tolerance = true, waitFramesPerSecond = true })
    or not isFiniteNumber(camera.movement.unitsPerFrame)
    or camera.movement.unitsPerFrame <= 0
    or not isFiniteNumber(camera.movement.tolerance)
    or camera.movement.tolerance < 0
    or not isFiniteNumber(camera.movement.waitFramesPerSecond)
    or camera.movement.waitFramesPerSecond <= 0
  then
    return false
  end
  for _, point in ipairs(camera.points) do
    if
      type(point) ~= "table"
      or not onlyKeys(point, { position = true, durationSeconds = true })
      or not isVector3(point.position)
      or not isFiniteNumber(point.durationSeconds)
      or point.durationSeconds <= 0
    then
      return false
    end
  end
  local animation = timeline.animation
  local reveal = timeline.titleReveal
  local start = timeline.start
  local glow = timeline.glow
  local attachments = timeline.attachments
  return type(animation) == "table"
    and onlyKeys(animation, { startFrame = true, framesPerUpdate = true })
    and isNonnegativeInteger(animation.startFrame)
    and isPositiveInteger(animation.framesPerUpdate)
    and type(reveal) == "table"
    and onlyKeys(reveal, { delayFrames = true, durationFrames = true })
    and isNonnegativeInteger(reveal.delayFrames)
    and isPositiveInteger(reveal.durationFrames)
    and type(start) == "table"
    and onlyKeys(start, { initialDelayFrames = true, activeDurationFrames = true })
    and isNonnegativeInteger(start.initialDelayFrames)
    and isPositiveInteger(start.activeDurationFrames)
    and type(glow) == "table"
    and onlyKeys(glow, { fadeInSteps = true, fadeOutSteps = true, pauseFrames = true, color = true })
    and isPositiveInteger(glow.fadeInSteps)
    and isPositiveInteger(glow.fadeOutSteps)
    and isNonnegativeInteger(glow.pauseFrames)
    and type(glow.color) == "table"
    and #glow.color == 3
    and isBoundedChannel(glow.color[1])
    and isBoundedChannel(glow.color[2])
    and isBoundedChannel(glow.color[3])
    and type(attachments) == "table"
    and onlyKeys(attachments, { model = true, sparkle = true })
    and type(attachments.model) == "table"
    and onlyKeys(attachments.model, { framesPerUpdate = true, endFrame = true })
    and isPositiveInteger(attachments.model.framesPerUpdate)
    and attachments.model.endFrame == "wrap-to-zero"
    and type(attachments.sparkle) == "table"
    and onlyKeys(attachments.sparkle, { framesPerUpdate = true, endFrame = true })
    and isPositiveInteger(attachments.sparkle.framesPerUpdate)
    and attachments.sparkle.endFrame == "wrap-to-zero"
end

local function isRgb555(value)
  return type(value) == "number" and value % 1 == 0 and value >= 0 and value <= 32767
end

local function isFx12Vector(value)
  return type(value) == "table"
    and #value == 3
    and type(value[1]) == "number"
    and value[1] % 1 == 0
    and value[1] >= -4096
    and value[1] <= 4096
    and type(value[2]) == "number"
    and value[2] % 1 == 0
    and value[2] >= -4096
    and value[2] <= 4096
    and type(value[3]) == "number"
    and value[3] % 1 == 0
    and value[3] >= -4096
    and value[3] <= 4096
end

local function isFloatTriple(value)
  return type(value) == "table"
    and #value == 3
    and isFiniteNumber(value[1])
    and isFiniteNumber(value[2])
    and isFiniteNumber(value[3])
end

local function isWhiteTriple(value)
  return isFloatTriple(value) and value[1] == value[2] and value[2] == value[3] and value[1] > 0
end

local function isNonzeroTriple(value)
  return isFloatTriple(value) and (value[1] ~= 0 or value[2] ~= 0 or value[3] ~= 0)
end

-- The projection contract pins the single source constant the runtime
-- camera executes: Nitro half-angle index 0xB60 on a 4:3 source frame
-- with the raw (0, 0.5) clip facts. Aspect accepts the packed number or
-- either table shape the producer may serialize.
local function validateTitleProjection(projection)
  if
    type(projection) ~= "table"
    or not onlyKeys(projection, {
      nitroHalfAngleIndex = true,
      sourceAspect = true,
      sourceNear = true,
      sourceFar = true,
    })
    or projection.nitroHalfAngleIndex ~= 0xB60
  then
    return false
  end
  local aspect = projection.sourceAspect
  local aspectOk = false
  if type(aspect) == "number" then
    aspectOk = math.abs(aspect - 4 / 3) < 1e-6
  elseif type(aspect) == "table" then
    aspectOk = (aspect.width == 4 and aspect.height == 3) or (aspect[1] == 4 and aspect[2] == 3)
  end
  return aspectOk
    and type(projection.sourceNear) == "number"
    and type(projection.sourceFar) == "number"
    and projection.sourceFar > projection.sourceNear
    and projection.sourceFar > 0
end

-- The lighting contract pins the constant original title profile: exactly
-- two enabled neutral-white lights with nonzero directions over four
-- slots, plus the four packed material registers. Every slot carries the
-- packed RGB555 register the GPU upload reads and the normalized float
-- aliases the shared lighting selection exposes; enabled slots must agree
-- on white in both spellings.
local function validateTitleLighting(lighting)
  if
    type(lighting) ~= "table"
    or not onlyKeys(lighting, { records = true })
    or type(lighting.records) ~= "table"
    or #lighting.records < 1
  then
    return false
  end
  local record = lighting.records[1]
  if
    type(record) ~= "table"
    or not onlyKeys(record, {
      endHalfSeconds = true,
      lights = true,
      diffuseRgb555 = true,
      ambientRgb555 = true,
      specularRgb555 = true,
      emissionRgb555 = true,
    })
    or not isNonnegativeInteger(record.endHalfSeconds)
    or type(record.lights) ~= "table"
    or #record.lights ~= 4
    or not isRgb555(record.diffuseRgb555)
    or not isRgb555(record.ambientRgb555)
    or not isRgb555(record.specularRgb555)
    or not isRgb555(record.emissionRgb555)
  then
    return false
  end
  local enabledCount = 0
  for _, light in ipairs(record.lights) do
    if
      type(light) ~= "table"
      or not onlyKeys(light, {
        enabled = true,
        colorRgb555 = true,
        color = true,
        vectorFx12 = true,
        direction = true,
      })
      or type(light.enabled) ~= "boolean"
      or not isRgb555(light.colorRgb555)
      or not isFloatTriple(light.color)
      or not isFx12Vector(light.vectorFx12)
      or not isFloatTriple(light.direction)
    then
      return false
    end
    if light.enabled then
      enabledCount = enabledCount + 1
      if not isWhiteTriple(light.color) or light.colorRgb555 == 0 or not isNonzeroTriple(light.direction) then
        return false
      end
    end
  end
  return enabledCount == 2
end

-- The prompt contract is relational: centered text whose token stream
-- renders that same text, with a flash cycle split into visible and
-- hidden phases. No retail flash count is frozen here.
local function validateTitlePrompt(prompt)
  local parsedOk, parsedText = false, nil
  if type(prompt) == "table" and type(prompt.tokens) == "table" then
    parsedOk, parsedText = pcall(FieldMessageText.tokensToText, prompt.tokens)
  end
  if
    type(prompt) ~= "table"
    or not onlyKeys(prompt, { text = true, alignment = true, tokens = true, color = true, flash = true })
    or type(prompt.text) ~= "string"
    or prompt.text == ""
    or prompt.alignment ~= "center"
    or type(prompt.tokens) ~= "table"
    or not parsedOk
    or parsedText ~= "{ALN_CENTER}" .. prompt.text
    or type(prompt.color) ~= "table"
    or type(prompt.flash) ~= "table"
    or not onlyKeys(prompt.flash, {
      initialDelayFrames = true,
      initialPhaseFrame = true,
      cycleFrames = true,
      visibleFrames = true,
      hiddenFrames = true,
    })
    or not isNonnegativeInteger(prompt.flash.initialDelayFrames)
    or not isNonnegativeInteger(prompt.flash.initialPhaseFrame)
    or not isPositiveInteger(prompt.flash.cycleFrames)
    or not isNonnegativeInteger(prompt.flash.visibleFrames)
    or not isNonnegativeInteger(prompt.flash.hiddenFrames)
    or prompt.flash.visibleFrames + prompt.flash.hiddenFrames ~= prompt.flash.cycleFrames
  then
    return false
  end
  return true
end

local function read(cacheFs, path, schema, versionId)
  assert(cacheFs and type(cacheFs.loadLua) == "function", "startup assets require a cache filesystem")
  local record, loadError = cacheFs:loadLua(path)
  if record == nil then
    return nil, loadError or invalid("manifest is missing", path)
  end
  if type(record) ~= "table" then
    return nil, invalid("manifest must be a table", path)
  end
  if record.schema ~= schema then
    return nil, invalid("manifest schema does not match", path)
  end
  local allowed
  if schema == Contract.startupWalker.schema then
    allowed = {
      schema = true,
      versionId = true,
      generationId = true,
      pairIndex = true,
      hero = true,
      follower = true,
    }
  elseif schema == Contract.startupOpeningScene.schema then
    allowed = {
      schema = true,
      versionId = true,
      generationId = true,
      sceneNumber = true,
      sourceTickRate = true,
      initial = true,
      layers = true,
      spriteClips = true,
      models = true,
      particles = true,
      timeline = true,
      assets = true,
      camera = true,
      lighting = true,
    }
  else
    allowed = {
      schema = true,
      versionId = true,
      generationId = true,
      kind = true,
      legendary = true,
      crySpeciesId = true,
      sequence = true,
      menuSelectSequence = true,
      model = true,
      clips = true,
      surfaces = true,
      sparkle = true,
      timeline = true,
      prompt = true,
      projection = true,
      lighting = true,
    }
  end
  if not onlyKeys(record, allowed) then
    return nil, invalid("manifest contains an unknown field", path)
  end
  if not EDITIONS[record.versionId] or (versionId ~= nil and record.versionId ~= versionId) then
    return nil, invalid("manifest edition does not match", path)
  end
  if type(record.generationId) ~= "string" or record.generationId == "" then
    return nil, invalid("manifest generation is missing", path)
  end
  if containsSourceIdentity(record, {}) then
    return nil, invalid("manifest contains a source-only identity", path)
  end
  return record
end

local function hasAnimatedEastWalk(visual)
  if type(visual) ~= "table" or type(visual.render) ~= "table" or type(visual.directions) ~= "table" then
    return false
  end
  local render = visual.render
  local east = visual.directions.east
  local walk = east and east.walk
  if
    render.kind ~= "atlas"
    or type(render.frameWidth) ~= "number"
    or render.frameWidth <= 0
    or type(render.frameHeight) ~= "number"
    or render.frameHeight <= 0
    or type(render.frameCount) ~= "number"
    or render.frameCount < 2
    or type(walk) ~= "table"
    or type(walk.frames) ~= "table"
    or #walk.frames < 2
  then
    return false
  end
  local frameIndexes = {}
  for _, frame in ipairs(walk.frames) do
    if
      type(frame.frameIndex) ~= "number"
      or frame.frameIndex % 1 ~= 0
      or frame.frameIndex < 1
      or frame.frameIndex > render.frameCount
      or type(frame.ticks) ~= "number"
      or frame.ticks % 1 ~= 0
      or frame.ticks <= 0
    then
      return false
    end
    frameIndexes[frame.frameIndex] = true
  end
  local count = 0
  for _ in pairs(frameIndexes) do
    count = count + 1
  end
  return count > 1
end

---@param pairIndex integer
---@return { heroId: string, followerSpeciesId: integer }
function StartupAssetCache.walkerChoice(pairIndex)
  assert(
    type(pairIndex) == "number" and pairIndex % 1 == 0 and pairIndex >= 1 and pairIndex <= 32,
    "walking pair index must be an integer 1..32"
  )
  local ordinal = (pairIndex - 1) % 16 + 1
  local heroId = pairIndex <= 16 and "ethan" or "lyra"
  return { heroId = heroId, followerSpeciesId = FOLLOWER_SPECIES_IDS[ordinal] }
end

---@param heroId string
---@param speciesId integer
---@return integer
function StartupAssetCache.walkerIndex(heroId, speciesId)
  assert(heroId == "ethan" or heroId == "lyra", "walking pair hero must be ethan or lyra")
  assert(type(speciesId) == "number" and speciesId % 1 == 0, "walking pair species must be an integer")
  local ordinal = nil
  for position, candidate in ipairs(FOLLOWER_SPECIES_IDS) do
    if candidate == speciesId then
      ordinal = position
      break
    end
  end
  assert(ordinal ~= nil, "walking pair species is not one of the sixteen followers")
  if heroId == "ethan" then
    return ordinal
  end
  return 16 + ordinal
end

---@param pairIndex integer
---@return string
function StartupAssetCache.walkerPath(pairIndex)
  assert(
    type(pairIndex) == "number" and pairIndex % 1 == 0 and pairIndex >= 1 and pairIndex <= 32,
    "walking pair index must be an integer 1..32"
  )
  return "data/generated/startup/loader/pairs/" .. tostring(pairIndex) .. ".lua"
end

function StartupAssetCache.titlePath()
  return TITLE_PATH
end

-- The five opening-movie scenes form one closed numeric family beside the
-- walking pair and title scopes: each scene addresses its own versioned
-- manifest, and no other key shape is routable.
---@param sceneNumber integer
---@return string
function StartupAssetCache.openingScenePath(sceneNumber)
  assert(
    type(sceneNumber) == "number" and sceneNumber % 1 == 0 and sceneNumber >= 1 and sceneNumber <= 5,
    "opening scene number must be an integer 1..5"
  )
  return "data/generated/startup/opening/" .. tostring(sceneNumber) .. ".lua"
end

-- Source starter emitter identities behind scene 4: the retail
-- sStarterParticleResIds rows group grass, fire, and water in this order.
-- The group vocabulary is closed; any other emitter id or group is a
-- malformed particle record, never a silent omission.
local OPENING_EMITTER_GROUPS = {
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

local OPENING_OPS = {
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

local function isOpeningSceneRoot(path, sceneNumber)
  if type(path) ~= "string" then
    return false
  end
  local prefix = "assets/generated/startup/opening/" .. tostring(sceneNumber) .. "/"
  return path:sub(1, #prefix) == prefix
end

local function checkOpeningAssetPath(cacheFs, path, sceneNumber, role)
  if not isOpeningSceneRoot(path, sceneNumber) then
    return nil, invalid("opening scene " .. role .. " escapes its scene asset root", path)
  end
  if not cacheFs:exists(path, "file") then
    return nil, invalid("opening scene " .. role .. " is missing", path)
  end
  return true
end

local function isHexHash(value)
  return type(value) == "string" and #value == 40 and value:find("[^0-9a-f]") == nil
end

local function validateOpeningLayer(cacheFs, layer, sceneNumber, role)
  if
    type(layer) ~= "table"
    or type(layer.image) ~= "string"
    or not isNonnegativeInteger(layer.width)
    or layer.width == 0
    or not isNonnegativeInteger(layer.height)
    or layer.height == 0
    or not isHexHash(layer.sourceHash)
  then
    return nil,
      invalid("opening scene " .. role .. " layer is malformed", StartupAssetCache.openingScenePath(sceneNumber))
  end
  local ok, err = checkOpeningAssetPath(cacheFs, layer.image, sceneNumber, role .. " layer art")
  if not ok then
    return nil, err
  end
  return true
end

local function validateOpeningClip(clip, sceneNumber)
  if type(clip) ~= "table" or type(clip.id) ~= "string" or not isPositiveInteger(clip.frameCount) then
    return nil, invalid("opening scene sprite clip is malformed", StartupAssetCache.openingScenePath(sceneNumber))
  end
  if not isOpeningSceneRoot(clip.id, sceneNumber) then
    return nil, invalid("opening scene sprite clip escapes its scene asset root", clip.id)
  end
  return true
end

local function validateOpeningEmitters(emitters, sceneNumber)
  if type(emitters) ~= "table" then
    return nil, invalid("opening scene emitter records are malformed", StartupAssetCache.openingScenePath(sceneNumber))
  end
  if sceneNumber == 4 then
    if #emitters ~= 9 then
      return nil, invalid("opening scene 4 keeps all nine starter emitters", StartupAssetCache.openingScenePath(4))
    end
    for _, emitter in ipairs(emitters) do
      if
        type(emitter) ~= "table"
        or type(emitter.id) ~= "number"
        or emitter.id % 1 ~= 0
        or emitter.id < 0
        or emitter.id > 8
        or emitter.group ~= OPENING_EMITTER_GROUPS[emitter.id]
      then
        return nil,
          invalid("opening scene emitter is outside the nine source emitters", StartupAssetCache.openingScenePath(4))
      end
    end
    return true
  end
  if #emitters ~= 0 then
    return nil,
      invalid("only opening scene 4 carries starter emitters", StartupAssetCache.openingScenePath(sceneNumber))
  end
  return true
end

local function validateOpeningEventOperands(event, sceneNumber)
  local op = event.op
  if op == "waitTicks" then
    if not isPositiveInteger(event.ticks) then
      return nil, "opening scene wait carries no source tick count"
    end
  elseif op == "setFade" or op == "setBlend" or op == "setScroll" then
    if not isPositiveInteger(event.ticks) then
      return nil, "opening scene effect carries no source tick count"
    end
    if event.direction ~= nil and type(event.direction) ~= "string" then
      return nil, "opening scene scroll direction is malformed"
    end
  elseif op == "circleWipe" then
    if event.ticks ~= nil and not isPositiveInteger(event.ticks) then
      return nil, "opening scene wipe carries a malformed tick count"
    end
  elseif op == "setLayer" then
    if type(event.role) ~= "string" then
      return nil, "opening scene layer carries no screen role"
    end
  elseif op == "window" then
    if type(event.target) ~= "string" then
      return nil, "opening scene window carries no target"
    end
    if event.ticks ~= nil and not isPositiveInteger(event.ticks) then
      return nil, "opening scene window carries a malformed tick count"
    end
  elseif op == "setSpriteClip" then
    if type(event.sprite) ~= "string" or type(event.clip) ~= "string" then
      return nil, "opening scene sprite clip event is malformed"
    end
    if not isOpeningSceneRoot(event.clip, sceneNumber) then
      return nil, "opening scene sprite clip event escapes its scene asset root"
    end
  elseif op == "spriteVisible" then
    if type(event.sprite) ~= "string" or type(event.visible) ~= "boolean" then
      return nil, "opening scene sprite visibility event is malformed"
    end
  elseif op == "setModelClip" then
    if type(event.model) ~= "string" or type(event.clip) ~= "string" then
      return nil, "opening scene model clip event is malformed"
    end
  elseif op == "setCamera" then
    if type(event.distance) ~= "number" then
      return nil, "opening scene camera event carries no source distance"
    end
  elseif op == "setLighting" then
    if type(event.map) ~= "number" then
      return nil, "opening scene lighting event carries no town"
    end
  elseif op == "startEmitters" then
    if
      type(event.group) ~= "string"
      or (event.group ~= "grass" and event.group ~= "fire" and event.group ~= "water")
      or type(event.emitters) ~= "table"
      or #event.emitters == 0
    then
      return nil, "opening scene emitter start names no source emitter group"
    end
  elseif op == "setScreenRoles" then
    if type(event.upper) ~= "string" or type(event.lower) ~= "string" then
      return nil, "opening scene screen roles are malformed"
    end
  elseif op == "waitEffects" then
    if type(event.effects) ~= "table" or #event.effects == 0 then
      return nil, "opening scene effect wait names no started effect"
    end
    for _, name in ipairs(event.effects) do
      if type(name) ~= "string" or name == "" then
        return nil, "opening scene effect wait names no started effect"
      end
    end
  elseif op == "enableSkip" then
    if sceneNumber ~= 1 then
      return nil, "only opening scene 1 opens the movie skip gate"
    end
  end
  return true
end

local function validateOpeningTimeline(timeline, sceneNumber)
  local path = StartupAssetCache.openingScenePath(sceneNumber)
  if type(timeline) ~= "table" or type(timeline.steps) ~= "table" or type(timeline.events) ~= "table" then
    return nil, invalid("opening scene timeline is malformed", path)
  end
  local events = timeline.events
  if #events == 0 then
    return nil, invalid("opening scene timeline carries no events", path)
  end
  local skipCount = 0
  for _, event in ipairs(events) do
    if
      type(event) ~= "table"
      or type(event.op) ~= "string"
      or OPENING_OPS[event.op] ~= true
      or type(event.atTick) ~= "number"
      or event.atTick % 1 ~= 0
      or event.atTick < 0
      or (event.stepId ~= nil and type(event.stepId) ~= "string")
    then
      return nil, invalid("opening scene event is outside the closed movie grammar", path)
    end
    if event.op == "enableSkip" then
      skipCount = skipCount + 1
      if event.atTick == 0 then
        return nil, invalid("opening scene skip gate never opens on the first frame", path)
      end
    end
    local ok, reason = validateOpeningEventOperands(event, sceneNumber)
    if not ok then
      return nil, invalid(assert(reason, "event rejection names its cause"), path)
    end
  end
  if sceneNumber == 1 and skipCount == 0 then
    return nil, invalid("opening scene 1 carries the source movie skip gate", path)
  end
  local covered = {}
  for _, step in ipairs(timeline.steps) do
    if
      type(step) ~= "table"
      or type(step.id) ~= "string"
      or type(step.events) ~= "table"
      or #step.events == 0
      or type(step["until"]) ~= "table"
    then
      return nil, invalid("opening scene step is malformed", path)
    end
    if step["until"].kind == "duration" then
      if not isPositiveInteger(step["until"].ticks) then
        return nil, invalid("opening scene step carries no source duration", path)
      end
    elseif step["until"].kind == "effect" then
      if type(step["until"].effect) ~= "string" or step["until"].effect == "" then
        return nil, invalid("opening scene step waits on no named effect", path)
      end
    else
      return nil, invalid("opening scene step completion is malformed", path)
    end
    for _, index in ipairs(step.events) do
      if
        type(index) ~= "number"
        or index % 1 ~= 0
        or index < 1
        or index > #events
        or events[index].stepId ~= step.id
      then
        return nil, invalid("opening scene step references no owned event", path)
      end
      covered[index] = true
    end
  end
  for index = 1, #events do
    if not covered[index] then
      return nil, invalid("opening scene event is unreachable from its steps", path)
    end
  end
  return true
end

-- One independently staged opening-movie scene: strict source-independent
-- g4-startup-opening-scene-v1 package with numbered scene, edition, 30Hz
-- duration, upper/lower 2D layer roles, sprite clips, model descriptors
-- and animations where used, starter emitter records where used, and the
-- closed source-timed event program. Every image, mesh, and clip lives
-- under that scene's asset root; source member identities, executable
-- payloads, and sibling roots never cross into the runtime manifest.
---@param cacheFs CacheFs
---@param sceneNumber integer
---@param versionId string
---@return table<string, unknown>|nil
---@return Errors.Error|string|nil
function StartupAssetCache.loadOpeningScene(cacheFs, sceneNumber, versionId)
  assert(
    type(sceneNumber) == "number" and sceneNumber % 1 == 0 and sceneNumber >= 1 and sceneNumber <= 5,
    "opening scene number must be an integer 1..5"
  )
  assert(EDITIONS[versionId], "opening scene edition must be heartgold or soulsilver")
  local path = StartupAssetCache.openingScenePath(sceneNumber)
  local record, loadError = read(cacheFs, path, Contract.startupOpeningScene.schema, versionId)
  if record == nil then
    return nil, loadError
  end
  if record.sceneNumber ~= sceneNumber then
    return nil, invalid("opening scene manifest names another scene", path)
  end
  if record.sourceTickRate ~= Contract.startupOpeningScene.tickRate then
    return nil, invalid("opening scene manifest runs outside the source frame rate", path)
  end
  if type(record.initial) ~= "table" or type(record.initial.screenRoles) ~= "string" then
    return nil, invalid("opening scene initial screen roles are malformed", path)
  end
  if type(record.layers) ~= "table" or type(record.layers.upper) ~= "table" or type(record.layers.lower) ~= "table" then
    return nil, invalid("opening scene keeps its upper and lower screen roles", path)
  end
  for _, role in ipairs({ "upper", "lower" }) do
    for _, layer in ipairs(record.layers[role]) do
      local ok, err = validateOpeningLayer(cacheFs, layer, sceneNumber, role)
      if not ok then
        return nil, err
      end
    end
  end
  if type(record.spriteClips) ~= "table" then
    return nil, invalid("opening scene sprite clips are malformed", path)
  end
  for _, clip in ipairs(record.spriteClips) do
    local ok, err = validateOpeningClip(clip, sceneNumber)
    if not ok then
      return nil, err
    end
  end
  if type(record.models) ~= "table" then
    return nil, invalid("opening scene models are malformed", path)
  end
  if #record.models > 0 then
    if sceneNumber ~= 3 or #record.models ~= 3 then
      return nil, invalid("only opening scene 3 carries its three town models", path)
    end
    for _, model in ipairs(record.models) do
      if
        type(model) ~= "table"
        or type(model.descriptor) ~= "table"
        or type(model.clips) ~= "table"
        or #model.clips < 2
      then
        return nil, invalid("opening scene town keeps its two animation channels", path)
      end
      for _, clip in ipairs(model.clips) do
        if type(clip) ~= "table" or not isPositiveInteger(clip.frameCount) then
          return nil, invalid("opening scene town animation channel is malformed", path)
        end
      end
    end
  end
  if type(record.particles) ~= "table" or type(record.particles.seed) ~= "number" then
    return nil, invalid("opening scene particles are malformed", path)
  end
  local ok, err = validateOpeningEmitters(record.particles.emitters, sceneNumber)
  if not ok then
    return nil, err
  end
  ok, err = validateOpeningTimeline(record.timeline, sceneNumber)
  if not ok then
    return nil, err
  end
  if type(record.assets) ~= "table" then
    return nil, invalid("opening scene asset index is malformed", path)
  end
  for assetPath in pairs(record.assets) do
    ok, err = checkOpeningAssetPath(cacheFs, assetPath, sceneNumber, "indexed asset")
    if not ok then
      return nil, err
    end
  end
  return record
end

local function hasWalkerPivot(visual)
  local pivot = type(visual) == "table" and visual.pivot
  return type(pivot) == "table" and pivot.x == 0.5 and pivot.y == 1
end

local function walkerAtlasPath(path, pairIndex)
  if not generatedPath(path, "loader") then
    return false
  end
  local prefix = "assets/generated/startup/loader/pairs/" .. tostring(pairIndex) .. "/"
  return type(path) == "string" and path:sub(1, #prefix) == prefix
end

---@param cacheFs CacheFs
---@param pairIndex integer
---@return table<string, unknown>|nil
---@return Errors.Error|string|nil
function StartupAssetCache.loadWalker(cacheFs, pairIndex)
  assert(
    type(pairIndex) == "number" and pairIndex % 1 == 0 and pairIndex >= 1 and pairIndex <= 32,
    "walking pair index must be an integer 1..32"
  )
  local path = StartupAssetCache.walkerPath(pairIndex)
  local bundle, err = read(cacheFs, path, Contract.startupWalker.schema)
  if bundle == nil then
    return nil, err
  end
  if bundle.pairIndex ~= pairIndex then
    return nil, invalid("walking pair manifest names another pair", path)
  end
  local hero = bundle.hero
  if
    type(hero) ~= "table"
    or not onlyKeys(hero, { visual = true, atlasPath = true })
    or not hasAnimatedEastWalk(hero.visual)
    or not hasWalkerPivot(hero.visual)
    or not walkerAtlasPath(hero.atlasPath, pairIndex)
  then
    return nil, invalid("walking pair hero needs an animated east walk atlas with source pivot", path)
  end
  if not cacheFs:exists(hero.atlasPath, "file") then
    return nil, invalid("walking pair hero atlas is missing", hero.atlasPath)
  end
  local follower = bundle.follower
  if
    type(follower) ~= "table"
    or not onlyKeys(follower, { speciesId = true, visual = true, atlasPath = true })
    or type(follower.speciesId) ~= "number"
    or follower.speciesId % 1 ~= 0
    or not hasAnimatedEastWalk(follower.visual)
    or not hasWalkerPivot(follower.visual)
    or not walkerAtlasPath(follower.atlasPath, pairIndex)
  then
    return nil, invalid("walking pair follower needs an animated east walk atlas with source pivot", path)
  end
  if not cacheFs:exists(follower.atlasPath, "file") then
    return nil, invalid("walking pair follower atlas is missing", follower.atlasPath)
  end
  return bundle
end

---@param cacheFs CacheFs
---@param versionId string
---@return table<string, unknown>|nil
---@return Errors.Error|string|nil
function StartupAssetCache.loadTitle(cacheFs, versionId)
  assert(EDITIONS[versionId], "title edition must be heartgold or soulsilver")
  local bundle, err = read(cacheFs, TITLE_PATH, Contract.startupTitle.schema, versionId)
  if bundle == nil then
    return nil, err
  end
  if
    type(bundle.model) ~= "table"
    or bundle.model.kind ~= "nitro-dynamic"
    or not pcall(ModelAsset.validate, bundle.model)
  then
    return nil, invalid("title model is malformed", TITLE_PATH)
  end
  for _, assetPath in ipairs(ModelAsset.referencedPaths(bundle.model)) do
    if not generatedPath(assetPath, "title") then
      return nil, invalid("title model references an asset outside its generated root", assetPath)
    end
    if not cacheFs:exists(assetPath, "file") then
      return nil, invalid("title model asset is missing", assetPath)
    end
  end
  if type(bundle.surfaces) ~= "table" or type(bundle.clips) ~= "table" or type(bundle.timeline) ~= "table" then
    return nil, invalid("title layers, clips, and timeline are required", TITLE_PATH)
  end
  if bundle.sequence ~= "SEQ_GS_POKEMON_THEME" then
    return nil, invalid("title theme identity is missing", TITLE_PATH)
  end
  local crySpeciesId = versionId == "heartgold" and 250 or 249
  if bundle.crySpeciesId ~= crySpeciesId then
    return nil, invalid("title legendary cry does not match edition", TITLE_PATH)
  end
  if
    bundle.kind ~= "animated-title"
    or bundle.legendary ~= (versionId == "heartgold" and "ho-oh" or "lugia")
    or bundle.menuSelectSequence ~= "SEQ_SE_DP_SELECT"
  then
    return nil, invalid("title identity or menu effect is incomplete", TITLE_PATH)
  end
  if
    type(bundle.clips) ~= "table"
    or not onlyKeys(bundle.clips, { joint = true, srt = true, color = true, pattern = true })
  then
    return nil, invalid("title animation channels are incomplete", TITLE_PATH)
  end
  local expectedClips = {
    joint = { category = "joint", kind = "trs" },
    srt = { category = "material", kind = "texsrt" },
    color = { category = "material", kind = "color" },
    pattern = { category = "material", kind = "pattern" },
  }
  for name, expected in pairs(expectedClips) do
    local clip = bundle.clips[name]
    if clip == nil then
      -- Only the pattern channel may be absent: an edition whose title
      -- PAT0 carries no targets omits it instead of publishing a
      -- trackless clip. Every other channel is required.
      if name ~= "pattern" then
        return nil, invalid("title " .. name .. " channel is missing", TITLE_PATH)
      end
    elseif
      type(clip) ~= "table"
      or clip.category ~= expected.category
      or clip.kind ~= expected.kind
      or type(clip.compiled) ~= "table"
      or type(clip.tracks) ~= "table"
      or #clip.tracks == 0
    then
      return nil, invalid("title " .. name .. " channel is malformed", TITLE_PATH)
    end
  end
  if not hasAnimationClips(bundle.model, bundle.clips) then
    return nil, invalid("title animation channels do not validate against the model contract", TITLE_PATH)
  end
  local surfacesValid, surfaceError = validateTitleSurfaces(cacheFs, bundle.surfaces)
  if not surfacesValid then
    return nil, invalid(surfaceError, TITLE_PATH)
  end
  if
    type(bundle.sparkle) ~= "table"
    or not onlyKeys(bundle.sparkle, { model = true, clips = true })
    or type(bundle.sparkle.model) ~= "table"
    or bundle.sparkle.model.kind ~= "nitro-dynamic"
    or not pcall(ModelAsset.validate, bundle.sparkle.model)
    or type(bundle.sparkle.clips) ~= "table"
    or not onlyKeys(bundle.sparkle.clips, { joint = true, pattern = true })
  then
    return nil, invalid("title sparkle model or channels are malformed", TITLE_PATH)
  end
  for _, assetPath in ipairs(ModelAsset.referencedPaths(bundle.sparkle.model)) do
    if not generatedPath(assetPath, "title") then
      return nil, invalid("title sparkle model references an asset outside its generated root", assetPath)
    end
    if not cacheFs:exists(assetPath, "file") then
      return nil, invalid("title sparkle model asset is missing", assetPath)
    end
  end
  local sparkleExpected =
    { joint = { category = "joint", kind = "trs" }, pattern = { category = "material", kind = "pattern" } }
  for name, expected in pairs(sparkleExpected) do
    local clip = bundle.sparkle.clips[name]
    if
      type(clip) ~= "table"
      or clip.category ~= expected.category
      or clip.kind ~= expected.kind
      or type(clip.compiled) ~= "table"
      or type(clip.tracks) ~= "table"
      or #clip.tracks == 0
    then
      return nil, invalid("title sparkle " .. name .. " channel is malformed", TITLE_PATH)
    end
  end
  if not hasAnimationClips(bundle.sparkle.model, bundle.sparkle.clips) then
    return nil, invalid("title sparkle channels do not validate against the model contract", TITLE_PATH)
  end
  if not validateTitleTimeline(bundle.timeline) then
    return nil, invalid("title camera or animation timeline is malformed", TITLE_PATH)
  end
  if type(bundle.projection) ~= "table" or not validateTitleProjection(bundle.projection) then
    return nil, invalid("title source projection is malformed", TITLE_PATH)
  end
  if type(bundle.lighting) ~= "table" or not validateTitleLighting(bundle.lighting) then
    return nil, invalid("title lighting profile is malformed", TITLE_PATH)
  end
  if not validateTitlePrompt(bundle.prompt) then
    return nil, invalid("title prompt is malformed", TITLE_PATH)
  end
  -- The prompt ink pins the edition text-palette entry compiled from
  -- src/title_screen.c: HeartGold RGB(27, 8, 0), SoulSilver
  -- RGB(0, 28, 31), each as 0..1 floats with shadow matching foreground.
  local expectedColor = versionId == "heartgold" and { foreground = 1, shadow = 1, background = 0 }
    or { foreground = 2, shadow = 2, background = 0 }
  local expectedRgb = versionId == "heartgold" and { 27 / 31, 8 / 31, 0 } or { 0, 28 / 31, 1 }
  local function isExpectedPromptRgb(value)
    return type(value) == "table"
      and #value == 3
      and isFiniteNumber(value[1])
      and isFiniteNumber(value[2])
      and isFiniteNumber(value[3])
      and math.abs(value[1] - expectedRgb[1]) < 1e-6
      and math.abs(value[2] - expectedRgb[2]) < 1e-6
      and math.abs(value[3] - expectedRgb[3]) < 1e-6
  end
  if
    not onlyKeys(bundle.prompt.color, {
      foreground = true,
      shadow = true,
      background = true,
      foregroundRgb = true,
      shadowRgb = true,
    })
    or bundle.prompt.color.foreground ~= expectedColor.foreground
    or bundle.prompt.color.shadow ~= expectedColor.shadow
    or bundle.prompt.color.background ~= expectedColor.background
    or not isExpectedPromptRgb(bundle.prompt.color.foregroundRgb)
    or not isExpectedPromptRgb(bundle.prompt.color.shadowRgb)
  then
    return nil, invalid("title prompt palette does not match edition", TITLE_PATH)
  end
  return bundle
end

return StartupAssetCache
