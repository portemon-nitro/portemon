-- Paths and strict readers for the source-independent startup visual bundles.

local Errors = require("libs.errors.src.Errors")
local Contract = require("libs.assets.src.DerivedAssetContract")
local ModelAsset = require("libs.assets.src.model.ModelAsset")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")

local StartupAssetCache = {}

local LOADER_PATH = "data/generated/startup/loader.lua"
local TITLE_PATH = "data/generated/startup/title.lua"
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
  local expectedRoles = { editionLogo = true, subscreenLower = true, subscreenDecor = true }
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
    or camera.movement.unitsPerFrame ~= 5
    or camera.movement.tolerance ~= 1
    or camera.movement.waitFramesPerSecond ~= 30
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
    and animation.startFrame == 0
    and animation.framesPerUpdate == 1
    and type(reveal) == "table"
    and onlyKeys(reveal, { delayFrames = true, durationFrames = true })
    and reveal.delayFrames == 3
    and reveal.durationFrames == 32
    and type(start) == "table"
    and onlyKeys(start, { initialDelayFrames = true, activeDurationFrames = true })
    and start.initialDelayFrames == 30
    and start.activeDurationFrames == 2340
    and type(glow) == "table"
    and onlyKeys(glow, { fadeInSteps = true, fadeOutSteps = true, pauseFrames = true, color = true })
    and glow.fadeInSteps == 61
    and glow.fadeOutSteps == 61
    and glow.pauseFrames == 21
    and type(glow.color) == "table"
    and #glow.color == 3
    and glow.color[1] == 12
    and glow.color[2] == 12
    and glow.color[3] == 12
    and type(attachments) == "table"
    and onlyKeys(attachments, { model = true, sparkle = true })
    and type(attachments.model) == "table"
    and onlyKeys(attachments.model, { framesPerUpdate = true, endFrame = true })
    and attachments.model.framesPerUpdate == 1
    and attachments.model.endFrame == "wrap-to-zero"
    and type(attachments.sparkle) == "table"
    and onlyKeys(attachments.sparkle, { framesPerUpdate = true, endFrame = true })
    and attachments.sparkle.framesPerUpdate == 1
    and attachments.sparkle.endFrame == "wrap-to-zero"
end

local function validateTitlePrompt(prompt)
  local parsedOk, parsedText = false, nil
  if type(prompt) == "table" and type(prompt.tokens) == "table" then
    parsedOk, parsedText = pcall(FieldMessageText.tokensToText, prompt.tokens)
  end
  if
    type(prompt) ~= "table"
    or not onlyKeys(prompt, { text = true, alignment = true, tokens = true, color = true, flash = true })
    or prompt.text ~= "TOUCH TO START"
    or prompt.alignment ~= "center"
    or type(prompt.tokens) ~= "table"
    or not parsedOk
    or parsedText ~= "{ALN_CENTER}TOUCH TO START"
    or type(prompt.color) ~= "table"
    or type(prompt.flash) ~= "table"
    or not onlyKeys(prompt.flash, {
      initialDelayFrames = true,
      initialPhaseFrame = true,
      cycleFrames = true,
      visibleFrames = true,
      hiddenFrames = true,
    })
    or prompt.flash.initialDelayFrames ~= 30
    or prompt.flash.initialPhaseFrame ~= 30
    or prompt.flash.cycleFrames ~= 45
    or prompt.flash.visibleFrames ~= 30
    or prompt.flash.hiddenFrames ~= 15
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
  local allowed = schema == Contract.startupLoader.schema
      and {
        schema = true,
        versionId = true,
        generationId = true,
        heroes = true,
        followers = true,
        backdrop = true,
      }
    or {
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
    }
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

function StartupAssetCache.loaderPath()
  return LOADER_PATH
end

function StartupAssetCache.titlePath()
  return TITLE_PATH
end

---@param cacheFs CacheFs
---@return table<string, unknown>|nil
---@return Errors.Error|string|nil
function StartupAssetCache.loadLoader(cacheFs)
  local bundle, err = read(cacheFs, LOADER_PATH, Contract.startupLoader.schema)
  if bundle == nil then
    return nil, err
  end
  if
    type(bundle.heroes) ~= "table"
    or not onlyKeys(bundle.heroes, { ethan = true, lyra = true })
    or type(bundle.followers) ~= "table"
    or #bundle.followers < 4
    or #bundle.followers > 8
  then
    return nil, invalid("loader requires two heroes and at least four followers", LOADER_PATH)
  end
  for _, identity in ipairs({ "ethan", "lyra" }) do
    local hero = bundle.heroes[identity]
    if
      type(hero) ~= "table"
      or not onlyKeys(hero, { visual = true, atlasPath = true })
      or not hasAnimatedEastWalk(hero.visual)
      or not generatedPath(hero.atlasPath, "loader")
    then
      return nil, invalid("hero " .. identity .. " needs an animated east walk atlas", LOADER_PATH)
    end
    if not cacheFs:exists(hero.atlasPath, "file") then
      return nil, invalid("hero atlas is missing", hero.atlasPath)
    end
  end
  for index, follower in ipairs(bundle.followers) do
    if
      type(follower) ~= "table"
      or type(follower.speciesId) ~= "number"
      or follower.speciesId % 1 ~= 0
      or not generatedPath(follower.atlasPath, "loader")
      or not hasAnimatedEastWalk(follower.visual)
    then
      return nil, invalid("follower " .. index .. " needs an animated east walk atlas", LOADER_PATH)
    end
    if not cacheFs:exists(follower.atlasPath, "file") then
      return nil, invalid("follower atlas is missing", follower.atlasPath)
    end
  end
  local species = {}
  for index, follower in ipairs(bundle.followers) do
    if species[follower.speciesId] then
      return nil, invalid("follower species are duplicated", index)
    end
    species[follower.speciesId] = true
  end
  if
    type(bundle.backdrop) ~= "table"
    or not onlyKeys(bundle.backdrop, { kind = true, width = true, height = true, image = true })
    or (bundle.backdrop.kind ~= "authored" and bundle.backdrop.kind ~= "rom-derived")
    or bundle.backdrop.width ~= 256
    or bundle.backdrop.height ~= 192
    or not generatedPath(bundle.backdrop.image, "loader")
  then
    return nil, invalid("loader backdrop kind is invalid", LOADER_PATH)
  end
  if not cacheFs:exists(bundle.backdrop.image, "file") then
    return nil, invalid("loader backdrop is missing", bundle.backdrop.image)
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
    if
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
  if not validateTitlePrompt(bundle.prompt) then
    return nil, invalid("title prompt is malformed", TITLE_PATH)
  end
  local expectedColor = versionId == "heartgold" and { foreground = 1, shadow = 1, background = 0 }
    or { foreground = 2, shadow = 2, background = 0 }
  if
    not onlyKeys(bundle.prompt.color, { foreground = true, shadow = true, background = true })
    or bundle.prompt.color.foreground ~= expectedColor.foreground
    or bundle.prompt.color.shadow ~= expectedColor.shadow
    or bundle.prompt.color.background ~= expectedColor.background
  then
    return nil, invalid("title prompt palette does not match edition", TITLE_PATH)
  end
  return bundle
end

return StartupAssetCache
