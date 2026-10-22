-- Opening movie lifecycle edges: disposal in the middle of a run and after
-- a failed acquisition, malformed event operands at construction, a
-- zero-duration effect step that costs no extra tick, and graphics state
-- restoration when a draw fails. Fixtures reuse the strict synthetic scene
-- shape validated through the real startup cache reader.

local Assert = require("tests.support.Assert")
local Contract = require("libs.assets.src.DerivedAssetContract")
local DisplayContext = require("libs.ui.src.DisplayContext")
local FakeGraphics = require("tests.support.FakeGraphics")
local StartupAssetCache = require("libs.assets.src.StartupAssetCache")

local MOVIE_MODULE = "libs.hgss.src.presentation.HgssOpeningMovie"
local VERSION_ID = "soulsilver"
local WIDTH, HEIGHT = 512, 384

local T = {}

---@return table movie module owning the five-scene playback session
local function requireMovie()
  local ok, movie = pcall(require, MOVIE_MODULE)
  Assert.isTrue(ok, "the opening movie owns its five-scene playback session")
  return assert(movie)
end

---@param sceneNumber integer
---@return string
local function sceneRoot(sceneNumber)
  return "assets/generated/startup/opening/" .. tostring(sceneNumber) .. "/"
end

---@param image string
---@return table
local function layer(image)
  return { image = image, width = 256, height = 192, sourceHash = string.rep("c", 40) }
end

---@param sceneNumber integer
---@return table[]
local function sceneEvents(sceneNumber)
  local root = sceneRoot(sceneNumber)
  if sceneNumber == 1 then
    return {
      { op = "setLayer", stepId = "copyright", atTick = 0, role = "upper" },
      { op = "waitTicks", stepId = "copyright", atTick = 0, ticks = 30 },
      { op = "setLayer", stepId = "setup", atTick = 30, role = "lower" },
      { op = "waitTicks", stepId = "setup", atTick = 30, ticks = 20 },
      { op = "enableSkip", stepId = "setup", atTick = 40 },
      { op = "waitTicks", stepId = "logo", atTick = 50, ticks = 40 },
      { op = "finish", stepId = "logo", atTick = 90 },
    }
  elseif sceneNumber == 2 then
    return {
      { op = "setScroll", stepId = "open", atTick = 0, ticks = 25, direction = "left" },
      { op = "waitTicks", stepId = "open", atTick = 0, ticks = 25 },
      { op = "circleWipe", stepId = "close", atTick = 25, ticks = 10 },
      { op = "waitTicks", stepId = "close", atTick = 25, ticks = 15 },
      { op = "finish", stepId = "close", atTick = 40 },
    }
  elseif sceneNumber == 3 then
    return {
      { op = "setCamera", stepId = "arrive", atTick = 0, distance = 100 },
      { op = "setModelClip", stepId = "arrive", atTick = 0, model = "town-0", clip = "arrive-pose" },
      { op = "setLighting", stepId = "hold", atTick = 20, map = 1 },
      { op = "waitTicks", stepId = "hold", atTick = 20, ticks = 30 },
      { op = "finish", stepId = "hold", atTick = 50 },
    }
  elseif sceneNumber == 4 then
    return {
      { op = "setSpriteClip", stepId = "intro", atTick = 0, sprite = "ethan", clip = root .. "sprites/ethan.g4sprite" },
      { op = "waitTicks", stepId = "intro", atTick = 0, ticks = 10 },
      { op = "startEmitters", stepId = "starters", atTick = 10, group = "grass", emitters = { 6, 7, 8 } },
      { op = "waitEffects", stepId = "starters", atTick = 10, effects = { "emitters-grass" } },
      { op = "waitTicks", stepId = "outro", atTick = 10, ticks = 10 },
      { op = "finish", stepId = "outro", atTick = 10 },
    }
  end
  return {
    { op = "circleWipe", stepId = "wipe", atTick = 0, ticks = 18 },
    { op = "setScreenRoles", stepId = "wipe", atTick = 0, upper = "main", lower = "sub" },
    { op = "setScroll", stepId = "scroll", atTick = 18, ticks = 20, direction = "left" },
    { op = "waitTicks", stepId = "scroll", atTick = 18, ticks = 20 },
    { op = "setFade", stepId = "fade", atTick = 38, ticks = 15 },
    { op = "finish", stepId = "fade", atTick = 53 },
  }
end

---@param id integer source emitter id
---@param group string starter group owning the emitter
---@return table strict synthetic emitter record mirroring the compiled shape
local function testEmitter(id, group)
  local root = sceneRoot(4)
  return {
    id = id,
    group = group,
    emitterLife = 30,
    particleLife = 30,
    generation = { count = 2, interval = 1 },
    radius = 0.5,
    length = 0,
    position = { x = 0, y = 0, z = 0 },
    axis = { x = 0, y = 1, z = 0 },
    baseColor = { r = 1, g = 1, b = 1 },
    baseAlpha = 31,
    baseScale = 1,
    velocity = { initial = 0.2, axis = 0 },
    rotation = { min = 0, max = 0 },
    texture = id,
    textureImage = root .. "particles/texture" .. id .. ".png",
    animations = { scale = false, color = false, alpha = true },
    fields = {},
  }
end

---@param sceneNumber integer
---@return table[]
local function sceneSteps(sceneNumber)
  if sceneNumber == 1 then
    return {
      { id = "copyright", events = { 1, 2 }, ["until"] = { kind = "duration", ticks = 30 } },
      { id = "setup", events = { 3, 4, 5 }, ["until"] = { kind = "duration", ticks = 20 } },
      { id = "logo", events = { 6, 7 }, ["until"] = { kind = "duration", ticks = 40 } },
    }
  elseif sceneNumber == 2 then
    return {
      { id = "open", events = { 1, 2 }, ["until"] = { kind = "duration", ticks = 25 } },
      { id = "close", events = { 3, 4, 5 }, ["until"] = { kind = "duration", ticks = 15 } },
    }
  elseif sceneNumber == 3 then
    return {
      { id = "arrive", events = { 1, 2 }, ["until"] = { kind = "duration", ticks = 20 } },
      { id = "hold", events = { 3, 4, 5 }, ["until"] = { kind = "duration", ticks = 30 } },
    }
  elseif sceneNumber == 4 then
    return {
      { id = "intro", events = { 1, 2 }, ["until"] = { kind = "duration", ticks = 10 } },
      { id = "starters", events = { 3, 4 }, ["until"] = { kind = "effect", effect = "emitters-grass" } },
      { id = "outro", events = { 5, 6 }, ["until"] = { kind = "duration", ticks = 10 } },
    }
  end
  return {
    { id = "wipe", events = { 1, 2 }, ["until"] = { kind = "duration", ticks = 18 } },
    { id = "scroll", events = { 3, 4 }, ["until"] = { kind = "duration", ticks = 20 } },
    { id = "fade", events = { 5, 6 }, ["until"] = { kind = "duration", ticks = 15 } },
  }
end

---@param sceneNumber integer
---@return table strict synthetic opening-scene manifest
local function manifestFor(sceneNumber)
  local root = sceneRoot(sceneNumber)
  local manifest = {
    schema = Contract.startupOpeningScene.schema,
    versionId = VERSION_ID,
    generationId = "movie-test-generation",
    sceneNumber = sceneNumber,
    sourceTickRate = Contract.startupOpeningScene.tickRate,
    initial = { screenRoles = "opening" },
    layers = {
      upper = { layer(root .. "upper-bg.png") },
      lower = { layer(root .. "lower-bg.png") },
    },
    spriteClips = {
      { id = root .. "sprites/clip0.g4sprite", frameCount = 4 },
    },
    models = {},
    particles = { seed = 0, emitters = {} },
    timeline = { steps = sceneSteps(sceneNumber), events = sceneEvents(sceneNumber) },
    assets = { [root .. "upper-bg.png"] = true, [root .. "lower-bg.png"] = true },
  }
  if sceneNumber == 3 then
    manifest.models = {}
    for town = 0, 2 do
      manifest.models[#manifest.models + 1] = {
        name = "town-" .. town,
        index = town,
        descriptor = { key = "synthetic:town-" .. town, materials = {}, meshes = {} },
        clips = { { frameCount = 2 }, { frameCount = 3 } },
      }
    end
  end
  if sceneNumber == 4 then
    local emitters = {}
    for id = 0, 8 do
      local group = id < 3 and "water" or (id < 6 and "fire" or "grass")
      emitters[#emitters + 1] = testEmitter(id, group)
    end
    local textures = {}
    for id = 0, 8 do
      textures[#textures + 1] = {
        id = id,
        format = 1,
        width = 16,
        height = 16,
        image = root .. "particles/texture" .. id .. ".png",
        sourceHash = string.rep("d", 40),
      }
      manifest.assets[root .. "particles/texture" .. id .. ".png"] = true
    end
    manifest.particles = {
      seed = 0,
      emitters = emitters,
      textures = textures,
    }
  end
  return manifest
end

---@param manifests table[] manifests keyed by scene number
---@return table cacheFs stub serving those manifests with all art present
local function stubCache(manifests)
  local byPath = {}
  for sceneNumber, manifest in pairs(manifests) do
    byPath[StartupAssetCache.openingScenePath(sceneNumber)] = manifest
  end
  return {
    loadLua = function(_, path)
      return byPath[path]
    end,
    exists = function()
      return true
    end,
    read = function(_, path)
      return "bytes:" .. tostring(path)
    end,
  }
end

---@return table[] scenes, table cacheFs
local function validPack()
  local raw = {}
  for sceneNumber = 1, 5 do
    raw[sceneNumber] = manifestFor(sceneNumber)
  end
  local cacheFs = stubCache(raw)
  local scenes = {}
  for sceneNumber = 1, 5 do
    local loaded, err = StartupAssetCache.loadOpeningScene(cacheFs, sceneNumber, VERSION_ID)
    Assert.notNil(loaded, "synthetic scene " .. sceneNumber .. " passes the strict scene reader: " .. tostring(err))
    scenes[sceneNumber] = loaded
  end
  return scenes, cacheFs
end

---@param fakeOpts table|nil mutable fake graphics options
---@return table graphics, table fakeOpts
local function movieGraphics(fakeOpts)
  fakeOpts = fakeOpts or {}
  local graphics = FakeGraphics.new(fakeOpts)
  graphics.getDimensions = function()
    return WIDTH, HEIGHT
  end
  graphics.getDPIScale = function()
    return 1
  end
  graphics.meshes = {}
  graphics.newMesh = function()
    local mesh = { released = false, releaseCount = 0 }
    mesh.release = function()
      mesh.released = true
      mesh.releaseCount = mesh.releaseCount + 1
    end
    graphics.meshes[#graphics.meshes + 1] = mesh
    return mesh
  end
  return graphics, fakeOpts
end

---@param scenes table[]
---@param cacheFs table
---@param graphics table
---@return table player
local function openMovie(scenes, cacheFs, graphics)
  local context = DisplayContext.new({
    graphics = graphics,
    topologyProvider = function(width, height)
      return {
        surfaces = {
          { id = "main", rect = { x = 0, y = 0, width = width, height = height }, touch = false, role = "world" },
        },
      }
    end,
  })
  local Movie = requireMovie()
  return Movie.new({
    versionId = VERSION_ID,
    scenes = scenes,
    cacheFs = cacheFs,
    width = WIDTH,
    height = HEIGHT,
    graphics = graphics,
    displayContext = context,
  })
end

---@param graphics table
---@return integer live (acquired but unreleased) GPU handles owned through the fake
local function liveHandles(graphics)
  local live = 0
  for _, group in ipairs({ graphics.images, graphics.canvases, graphics.meshes or {} }) do
    for _, handle in ipairs(group) do
      if not handle.released then
        live = live + 1
      end
    end
  end
  return live
end

function T.disposes_cleanly_mid_transition_and_stays_safe()
  local scenes, cacheFs = validPack()
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  for _ = 1, 100 do
    movie:updateFixed()
    movie:draw()
  end
  Assert.equal(movie:sceneNumber(), 2, "the run is mid-transition in scene two")
  Assert.isFalse(movie:isFinished(), "the movie is still running")
  movie:dispose()
  Assert.equal(liveHandles(graphics), 0, "disposing mid-transition releases every handle")
  movie:draw()
  Assert.isFalse(movie:isFinished(), "drawing after disposal never finishes the movie")
  movie:dispose()
  Assert.equal(liveHandles(graphics), 0, "disposing twice stays safe")
  Assert.throws(function()
    movie:updateFixed()
  end, "ticking after disposal is a programming error")
end

function T.dispose_after_a_failed_prefetch_releases_everything_once()
  local scenes, cacheFs = validPack()
  local fakeOpts = {}
  local graphics = movieGraphics(fakeOpts)
  local movie = openMovie(scenes, cacheFs, graphics)
  fakeOpts.failOnImageCall = #graphics.images + 1
  local ok, failure = pcall(function()
    movie:updateFixed()
  end)
  Assert.isFalse(ok, "a failed next-scene acquisition surfaces explicitly: " .. tostring(failure))
  Assert.equal(movie:sceneNumber(), 1, "the failed acquisition keeps the current scene")
  fakeOpts.failOnImageCall = nil
  movie:dispose()
  Assert.equal(liveHandles(graphics), 0, "disposing after the failure releases everything")
  for _, group in ipairs({ graphics.images, graphics.canvases, graphics.meshes or {} }) do
    for _, handle in ipairs(group) do
      Assert.equal(handle.releaseCount, 1, "every acquired handle is released exactly once")
    end
  end
  movie:dispose()
  Assert.equal(liveHandles(graphics), 0, "disposing twice after failure stays safe")
end

function T.rejects_malformed_event_operands_at_construction()
  local scenes, cacheFs = validPack()
  local Movie = requireMovie()
  local function attempt(candidate)
    local host = movieGraphics()
    local context = DisplayContext.new({
      graphics = host,
      topologyProvider = function(width, height)
        return {
          surfaces = {
            { id = "main", rect = { x = 0, y = 0, width = width, height = height }, touch = false, role = "world" },
          },
        }
      end,
    })
    return pcall(Movie.new, {
      versionId = VERSION_ID,
      scenes = candidate,
      cacheFs = cacheFs,
      width = WIDTH,
      height = HEIGHT,
      graphics = host,
      displayContext = context,
    })
  end
  local function withSceneTwo(events, steps)
    local pack = { scenes[1], manifestFor(2), scenes[3], scenes[4], scenes[5] }
    pack[2].timeline = { steps = steps or sceneSteps(2), events = events }
    return pack
  end
  local zeroWait = sceneEvents(2)
  zeroWait[2].ticks = 0
  Assert.isFalse(attempt(withSceneTwo(zeroWait)), "a zero tick wait carries no source duration")
  local badDirection = sceneEvents(2)
  badDirection[1].direction = 5
  Assert.isFalse(attempt(withSceneTwo(badDirection)), "a non-string scroll direction is malformed")
  local foreignSkip = sceneEvents(2)
  foreignSkip[1] = { op = "enableSkip", stepId = "open", atTick = 5 }
  local foreignSteps = { { id = "open", events = { 1, 2 }, ["until"] = { kind = "duration", ticks = 25 } } }
  local foreignPack = withSceneTwo({ foreignSkip[1], foreignSkip[1] }, foreignSteps)
  foreignPack[2].timeline.events[2] = { op = "waitTicks", stepId = "open", atTick = 5, ticks = 25 }
  Assert.isFalse(attempt(foreignPack), "a skip gate outside scene 1 never opens the movie")
  local emptyWait = sceneEvents(2)
  emptyWait[2] = { op = "waitEffects", stepId = "open", atTick = 0, effects = {} }
  Assert.isFalse(attempt(withSceneTwo(emptyWait)), "an effect wait with no names is malformed")
  local danglingSteps = {
    { id = "open", events = { 1, 2 }, ["until"] = { kind = "duration", ticks = 25 } },
    { id = "close", events = { 3, 4 }, ["until"] = { kind = "duration", ticks = 15 } },
  }
  local danglingEvents = sceneEvents(2)
  danglingEvents[5] = { op = "finish", stepId = "open", atTick = 40 }
  Assert.isFalse(
    attempt(withSceneTwo(danglingEvents, danglingSteps)),
    "a finish owned by another step never joins the run"
  )
end

function T.unknown_named_effect_steps_cost_no_extra_ticks()
  local scenes, cacheFs = validPack()
  local root = sceneRoot(2)
  local instant = {
    schema = Contract.startupOpeningScene.schema,
    versionId = VERSION_ID,
    generationId = "movie-test-generation",
    sceneNumber = 2,
    sourceTickRate = Contract.startupOpeningScene.tickRate,
    initial = { screenRoles = "opening" },
    layers = {
      upper = { layer(root .. "upper-bg.png") },
      lower = { layer(root .. "lower-bg.png") },
    },
    spriteClips = {},
    models = {},
    particles = { seed = 0, emitters = {} },
    timeline = {
      steps = {
        { id = "open", events = { 1, 2 }, ["until"] = { kind = "duration", ticks = 25 } },
        { id = "close", events = { 3, 4 }, ["until"] = { kind = "effect", effect = "wipe-unknown" } },
      },
      events = {
        { op = "setLayer", stepId = "open", atTick = 0, role = "upper" },
        { op = "waitTicks", stepId = "open", atTick = 0, ticks = 25 },
        { op = "circleWipe", stepId = "close", atTick = 25, mode = "out" },
        { op = "finish", stepId = "close", atTick = 25 },
      },
    },
    assets = { [root .. "upper-bg.png"] = true, [root .. "lower-bg.png"] = true },
  }
  local pack = { scenes[1], instant, scenes[3], scenes[4], scenes[5] }
  local graphics = movieGraphics()
  local movie = openMovie(pack, cacheFs, graphics)
  local entries = { [1] = 0 }
  local ticks = 0
  while not movie:isFinished() and ticks < 5000 do
    movie:updateFixed()
    ticks = ticks + 1
    movie:draw()
    if entries[movie:sceneNumber()] == nil then
      entries[movie:sceneNumber()] = ticks
    end
  end
  Assert.isTrue(movie:isFinished(), "the movie finishes within its bounded run")
  Assert.equal(entries[2], 90, "scene 2 still starts on its authored tick")
  Assert.equal(entries[3], 115, "a zero-duration effect step costs no extra tick")
  movie:dispose()
  Assert.equal(liveHandles(graphics), 0, "the instant step leaves no handle behind")
end

function T.a_failed_draw_restores_graphics_state_and_keeps_playing()
  local scenes, cacheFs = validPack()
  local fakeOpts = {}
  local graphics = movieGraphics(fakeOpts)
  local movie = openMovie(scenes, cacheFs, graphics)
  for _ = 1, 10 do
    movie:updateFixed()
  end
  local canvas, shader = graphics.getCanvas(), graphics.getShader()
  local r, g, b, a = graphics.getColor()
  local blend, alpha = graphics.getBlendMode()
  fakeOpts.failOnDrawCall = #graphics.draws + 2
  local ok = pcall(function()
    movie:draw()
  end)
  Assert.isFalse(ok, "a failed draw surfaces explicitly")
  Assert.equal(graphics.getCanvas(), canvas, "a failed draw restores the borrowed canvas")
  Assert.equal(graphics.getShader(), shader, "a failed draw restores the borrowed shader")
  local r2, g2, b2, a2 = graphics.getColor()
  Assert.equal(r2, r, "a failed draw restores the borrowed color")
  Assert.equal(g2, g, "a failed draw restores the borrowed color")
  Assert.equal(b2, b, "a failed draw restores the borrowed color")
  Assert.equal(a2, a, "a failed draw restores the borrowed color")
  local blend2, alpha2 = graphics.getBlendMode()
  Assert.equal(blend2, blend, "a failed draw restores the borrowed blend mode")
  Assert.equal(alpha2, alpha, "a failed draw restores the borrowed blend mode")
  Assert.equal(graphics.pushDepth(), 0, "a failed draw leaves no pushed scope behind")
  fakeOpts.failOnDrawCall = nil
  movie:draw()
  local ticks = 0
  while not movie:isFinished() and ticks < 5000 do
    movie:updateFixed()
    ticks = ticks + 1
    movie:draw()
  end
  Assert.isTrue(movie:isFinished(), "playback resumes and completes after the failed draw")
  movie:dispose()
  Assert.equal(liveHandles(graphics), 0, "disposing after the failed draw releases everything")
end

return { tests = T }
