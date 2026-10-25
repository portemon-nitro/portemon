-- Opening movie lifecycle edges: disposal in the middle of a run and after
-- a failed acquisition, malformed event operands rejected at load, a
-- wipe-effect step that holds exactly its authored ticks, and graphics
-- state restoration when a draw fails. Fixtures reuse the strict synthetic
-- scene shape validated through the real startup cache reader.

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

---@param bgSlot integer numeric background slot
---@param image string staged image path under its scene root
---@return table compiled engine layer record
local function layer(bgSlot, image)
  return {
    bgSlot = bgSlot,
    priority = bgSlot,
    image = image,
    variants = {},
    width = 256,
    height = 192,
    sourceHash = string.rep("c", 40),
    initialVisible = true,
  }
end

---@return table single-frame still clip frame
local function stillFrame()
  return { x = 0, y = 0, width = 16, height = 16, offsetX = 0, offsetY = 0, duration = 1 }
end

---@param sceneNumber integer
---@return table[]
local function sceneEvents(sceneNumber)
  local root = sceneRoot(sceneNumber)
  if sceneNumber == 1 then
    return {
      {
        op = "setLayer",
        stepId = "copyright",
        atStepTick = 0,
        engine = "main",
        bgSlot = 0,
        image = root .. "upper-bg.png",
        visible = true,
        priority = 0,
      },
      { op = "waitTicks", stepId = "copyright", atStepTick = 0, ticks = 30 },
      {
        op = "setLayer",
        stepId = "setup",
        atStepTick = 0,
        engine = "sub",
        bgSlot = 0,
        image = root .. "lower-bg.png",
        visible = true,
        priority = 0,
      },
      { op = "waitTicks", stepId = "setup", atStepTick = 0, ticks = 20 },
      { op = "enableSkip", stepId = "setup", atStepTick = 10 },
      { op = "waitTicks", stepId = "logo", atStepTick = 0, ticks = 40 },
      { op = "finish", stepId = "logo", atStepTick = 0 },
    }
  elseif sceneNumber == 2 then
    return {
      {
        op = "setScroll",
        stepId = "open",
        atStepTick = 0,
        engine = "main",
        bgSlot = 0,
        dx = -256,
        dy = 0,
        ticks = 25,
      },
      { op = "waitTicks", stepId = "open", atStepTick = 0, ticks = 25 },
      { op = "circleWipe", stepId = "close", atStepTick = 0, engine = "main", kind = 1, ticks = 8 },
      { op = "waitTicks", stepId = "close", atStepTick = 0, ticks = 15 },
      { op = "finish", stepId = "close", atStepTick = 0 },
    }
  elseif sceneNumber == 3 then
    return {
      { op = "setCamera", stepId = "arrive", atStepTick = 0, distance = 100 },
      { op = "setModelClip", stepId = "arrive", atStepTick = 0, model = "town-0", clip = "arrive-pose" },
      { op = "waitTicks", stepId = "arrive", atStepTick = 0, ticks = 20 },
      { op = "setLighting", stepId = "hold", atStepTick = 0, map = 1 },
      { op = "waitTicks", stepId = "hold", atStepTick = 0, ticks = 30 },
      { op = "finish", stepId = "hold", atStepTick = 0 },
    }
  elseif sceneNumber == 4 then
    return {
      {
        op = "setSpriteClip",
        stepId = "intro",
        atStepTick = 0,
        instanceId = "ethan",
        engine = "main",
        x = 64,
        y = 96,
        drawOrder = 1,
        clipId = root .. "sprites/ethan.g4sprite",
      },
      { op = "waitTicks", stepId = "intro", atStepTick = 0, ticks = 10 },
      { op = "startEmitters", stepId = "starters", atStepTick = 0, group = "grass", emitters = { 6, 7, 8 } },
      { op = "waitEffects", stepId = "starters", atStepTick = 0, effects = { "emitters-grass" } },
      { op = "waitTicks", stepId = "outro", atStepTick = 0, ticks = 10 },
      { op = "finish", stepId = "outro", atStepTick = 0 },
    }
  end
  return {
    { op = "setScreenMapping", stepId = "wipe", atStepTick = 0, mainPhysical = "upper" },
    {
      op = "shutterFade",
      stepId = "wipe",
      atStepTick = 0,
      order = "main-then-sub",
      mainPattern = "center-out",
      subPattern = "bottom-up",
      color = "black",
      steps = 18,
      framesPerStep = 1,
      effect = "scene5-shutter",
    },
    {
      op = "setScroll",
      stepId = "scroll",
      atStepTick = 0,
      engine = "main",
      bgSlot = 0,
      dx = -512,
      dy = 0,
      ticks = 20,
    },
    { op = "waitTicks", stepId = "scroll", atStepTick = 0, ticks = 20 },
    { op = "setFade", stepId = "fade", atStepTick = 0, kind = "white", ticks = 15 },
    { op = "finish", stepId = "fade", atStepTick = 0 },
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
      { id = "arrive", events = { 1, 2, 3 }, ["until"] = { kind = "duration", ticks = 20 } },
      { id = "hold", events = { 4, 5, 6 }, ["until"] = { kind = "duration", ticks = 30 } },
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
  local upperImage = root .. "upper-bg.png"
  local lowerImage = root .. "lower-bg.png"
  local clips = {}
  if sceneNumber == 1 then
    clips = { { id = root .. "sprites/clip0.g4sprite", frameCount = 1, frames = { stillFrame() } } }
  elseif sceneNumber == 4 then
    clips = { { id = root .. "sprites/ethan.g4sprite", frameCount = 1, frames = { stillFrame() } } }
  end
  local manifest = {
    schema = Contract.startupOpeningScene.schema,
    versionId = VERSION_ID,
    generationId = "movie-test-generation",
    sceneNumber = sceneNumber,
    sourceTickRate = Contract.startupOpeningScene.tickRate,
    layers = {
      main = { layer(0, upperImage) },
      sub = { layer(0, lowerImage) },
    },
    spriteClips = clips,
    models = {},
    particles = { seed = 0, emitters = {} },
    timeline = { steps = sceneSteps(sceneNumber), events = sceneEvents(sceneNumber) },
    assets = { [upperImage] = true, [lowerImage] = true },
  }
  for _, clip in ipairs(clips) do
    manifest.assets[clip.id] = true
  end
  -- Scene 3 carries no town stage here: the player strictly acquires every
  -- staged town model, so a bundle that names towns must name buildable
  -- ones. These synthetic timelines exercise the 2D program only; town
  -- acquisition has its own fixtures with renderable descriptors.
  if sceneNumber == 3 then
    manifest.models = {}
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

-- A scene-five filler that stages art and finishes on a bare duration:
-- wipe and shutter isolation tests replace another scene and need a
-- fifth scene that starts no effect of its own.
---@return table strict synthetic scene-five manifest with no effect program
local function neutralSceneFive()
  local root = sceneRoot(5)
  local upperImage = root .. "upper-bg.png"
  local lowerImage = root .. "lower-bg.png"
  return {
    schema = Contract.startupOpeningScene.schema,
    versionId = VERSION_ID,
    generationId = "movie-test-generation",
    sceneNumber = 5,
    sourceTickRate = Contract.startupOpeningScene.tickRate,
    layers = {
      main = { layer(0, upperImage) },
      sub = { layer(0, lowerImage) },
    },
    spriteClips = {},
    models = {},
    particles = { seed = 0, emitters = {} },
    timeline = {
      steps = { { id = "fill", events = { 1, 2 }, ["until"] = { kind = "duration", ticks = 10 } } },
      events = {
        { op = "waitTicks", stepId = "fill", atStepTick = 0, ticks = 10 },
        { op = "finish", stepId = "fill", atStepTick = 0 },
      },
    },
    assets = { [upperImage] = true, [lowerImage] = true },
  }
end

---@param overrides table[] custom scene manifests keyed by scene number
---@return table[] scenes, table cacheFs strict five-scene pack with a neutral fifth scene unless overridden
local function packWithOverrides(overrides)
  local raw = {}
  for sceneNumber = 1, 5 do
    if overrides[sceneNumber] ~= nil then
      raw[sceneNumber] = overrides[sceneNumber]
    elseif sceneNumber == 5 then
      raw[sceneNumber] = neutralSceneFive()
    else
      raw[sceneNumber] = manifestFor(sceneNumber)
    end
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

---@param manifest table raw scene-two manifest carrying a custom timeline
---@return nil rejected reason the strict reader reports
local function strictLoadSceneTwo(manifest)
  local FakeCache = require("tests.support.FakeCache")
  local CacheFs = require("libs.storage.src.CacheFs")
  local backend = FakeCache.new()
  local cacheFs = CacheFs.forVersion(VERSION_ID, backend)
  manifest.generationId = "movie-test-generation"
  for path in pairs(manifest.assets) do
    cacheFs:write(path, "bytes:" .. tostring(path))
  end
  cacheFs:writeLua(StartupAssetCache.openingScenePath(2), manifest)
  local loaded, err = StartupAssetCache.loadOpeningScene(cacheFs, 2, VERSION_ID)
  Assert.isNil(loaded, "a malformed scene-two program never validates")
  Assert.notNil(err, "a malformed scene-two program reports its cause")
  return err
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
  -- Construction preflights the first prefetch, so the next lazy
  -- acquisition fires when the opening scene hands over: drive tick by
  -- tick until it surfaces.
  fakeOpts.failOnImageCall = #graphics.images + 1
  local failure = nil
  local heldScene = movie:sceneNumber()
  local ticks = 0
  while failure == nil and ticks < 500 do
    heldScene = movie:sceneNumber()
    local callOk, err = pcall(function()
      movie:updateFixed()
    end)
    ticks = ticks + 1
    if not callOk then
      failure = err
      break
    end
    movie:draw()
  end
  fakeOpts.failOnImageCall = nil
  Assert.notNil(failure, "a failed next-scene acquisition surfaces explicitly")
  Assert.equal(movie:sceneNumber(), heldScene, "the failed acquisition keeps the current scene")
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
  -- Malformed programs never validate: the strict generated-asset reader
  -- rejects them with typed errors, so they never reach the player.
  local function withSceneTwo(events, steps)
    local manifest = manifestFor(2)
    manifest.timeline = { steps = steps or sceneSteps(2), events = events }
    return manifest
  end
  local zeroWait = sceneEvents(2)
  zeroWait[2].ticks = 0
  strictLoadSceneTwo(withSceneTwo(zeroWait))
  local badScroll = sceneEvents(2)
  badScroll[1].ticks = -2
  strictLoadSceneTwo(withSceneTwo(badScroll))
  local foreignSkip = {
    {
      op = "enableSkip",
      stepId = "open",
      atStepTick = 5,
    },
    { op = "waitTicks", stepId = "open", atStepTick = 5, ticks = 25 },
  }
  local foreignSteps = { { id = "open", events = { 1, 2 }, ["until"] = { kind = "duration", ticks = 25 } } }
  strictLoadSceneTwo(withSceneTwo(foreignSkip, foreignSteps))
  local emptyWait = sceneEvents(2)
  emptyWait[2] = { op = "waitEffects", stepId = "open", atStepTick = 0, effects = {} }
  strictLoadSceneTwo(withSceneTwo(emptyWait))
  local danglingSteps = {
    { id = "open", events = { 1, 2 }, ["until"] = { kind = "duration", ticks = 25 } },
    { id = "close", events = { 3, 4 }, ["until"] = { kind = "duration", ticks = 15 } },
  }
  local danglingEvents = sceneEvents(2)
  danglingEvents[5] = { op = "finish", stepId = "open", atStepTick = 0 }
  strictLoadSceneTwo(withSceneTwo(danglingEvents, danglingSteps))
end

function T.started_wipe_effects_hold_the_close_step_for_their_authored_ticks()
  -- The closed v4 grammar always counts wipe ticks, so a started wipe
  -- orders the close step for exactly its authored duration: no extra
  -- tick past completion, no early release while it runs. The wipe also
  -- follows the per-scanline cosine law with endpoint handling, stays on
  -- its owning engine, and varies with its kind.
  local root = sceneRoot(2)
  local instant = manifestFor(2)
  instant.timeline = {
    steps = {
      { id = "open", events = { 1, 2 }, ["until"] = { kind = "duration", ticks = 25 } },
      { id = "close", events = { 3, 4 }, ["until"] = { kind = "effect", effect = "wipe-circle" } },
    },
    events = {
      {
        op = "setScroll",
        stepId = "open",
        atStepTick = 0,
        engine = "main",
        bgSlot = 0,
        dx = -256,
        dy = 0,
        ticks = 25,
      },
      { op = "waitTicks", stepId = "open", atStepTick = 0, ticks = 25 },
      {
        op = "circleWipe",
        stepId = "close",
        atStepTick = 0,
        engine = "main",
        kind = 0,
        ticks = 10,
        effect = "wipe-circle",
      },
      { op = "finish", stepId = "close", atStepTick = 0 },
    },
  }
  local raw = {}
  for sceneNumber = 1, 5 do
    raw[sceneNumber] = manifestFor(sceneNumber)
  end
  raw[2] = instant
  local cacheFs = stubCache(raw)
  local scenes = {}
  for sceneNumber = 1, 5 do
    local loaded, err = StartupAssetCache.loadOpeningScene(cacheFs, sceneNumber, VERSION_ID)
    Assert.notNil(loaded, "synthetic scene " .. sceneNumber .. " passes the strict scene reader: " .. tostring(err))
    scenes[sceneNumber] = loaded
  end
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
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
  local function truncTowardZero(value)
    if value >= 0 then
      return math.floor(value)
    end
    return math.ceil(value)
  end
  local function wipeBoundary(n, ticks, vcount)
    local theta = math.pi * n / ticks
    local x, y = math.cos(theta), math.sin(theta)
    if x == 1 then
      return 255
    end
    if x == -1 then
      return 0
    end
    if math.abs(y) < 1e-9 then
      if x > 0 then
        return 255
      end
      return 0
    end
    return math.max(0, math.min(255, 127 + truncTowardZero(vcount * x / y)))
  end
  Assert.equal(wipeBoundary(0, 10, 0), 255, "the opening edge starts fully closed")
  Assert.equal(wipeBoundary(0, 10, 191), 255, "the opening edge starts fully closed on every row")
  Assert.equal(wipeBoundary(10, 10, 48), 0, "the final edge ends fully open")
  Assert.equal(wipeBoundary(10, 10, 191), 0, "the final edge ends fully open on every row")
  Assert.isFalse(
    wipeBoundary(2, 10, 48) == wipeBoundary(2, 10, 96),
    "early edges already slope with the scanline"
  )
  local probeGraphics = movieGraphics()
  local probeMovie = openMovie(scenes, cacheFs, probeGraphics)
  while probeMovie:sceneNumber() < 2 do
    probeMovie:updateFixed()
  end
  for _ = 1, 27 do
    probeMovie:updateFixed()
  end
  local probeBaseline = #probeGraphics.scissorIntersections
  local probeCanvases = #probeGraphics.canvases
  probeMovie:draw()
  local function probeEdges(y)
    local edges = {}
    for index = probeBaseline + 1, #probeGraphics.scissorIntersections do
      local entry = probeGraphics.scissorIntersections[index]
      if probeGraphics.scissorCanvases[index].canvas == probeMovie.mainCanvas then
        local requested = entry.requested
        if y >= requested[2] and y < requested[2] + requested[4] then
          edges[#edges + 1] = requested[1]
        end
      end
    end
    return edges
  end
  local probeLow = probeEdges(48)
  local probeHigh = probeEdges(96)
  local probeMasked = #probeGraphics.canvases > probeCanvases
  if #probeLow == 0 and #probeHigh == 0 then
    Assert.isTrue(probeMasked, "the scanline wipe clips per row instead of one centered rectangle")
  else
    Assert.isTrue(#probeLow > 0, "the wipe clips the upper probe row on its owning engine")
    Assert.isTrue(#probeHigh > 0, "the wipe clips the lower probe row on its owning engine")
    -- Normative kind0 covers the left [0, boundary): every span starts at
    -- the left edge, so the scanline slope rides on the span width.
    for _, edge in ipairs(probeLow) do
      Assert.equal(edge, 0, "the kind0 cover starts at the left edge")
    end
    for _, edge in ipairs(probeHigh) do
      Assert.equal(edge, 0, "the kind0 cover starts at the left edge on every row")
    end
    local function probeWidths(y)
      local widths = {}
      for index = probeBaseline + 1, #probeGraphics.scissorIntersections do
        local entry = probeGraphics.scissorIntersections[index]
        if probeGraphics.scissorCanvases[index].canvas == probeMovie.mainCanvas then
          local requested = entry.requested
          if y >= requested[2] and y < requested[2] + requested[4] then
            widths[#widths + 1] = requested[3]
          end
        end
      end
      table.sort(widths)
      return widths
    end
    local sortedLow, sortedHigh = probeWidths(48), probeWidths(96)
    Assert.isFalse(
      #sortedLow == #sortedHigh and sortedLow[1] == sortedHigh[1],
      "the wipe cover width slopes with the scanline instead of a centered rectangle"
    )
    local expectedLow = wipeBoundary(2, 10, 48)
    local expectedHigh = wipeBoundary(2, 10, 96)
    local foundLow, foundHigh = false, false
    for _, width in ipairs(sortedLow) do
      if math.abs(width - expectedLow) <= 1 then
        foundLow = true
      end
    end
    for _, width in ipairs(sortedHigh) do
      if math.abs(width - expectedHigh) <= 1 then
        foundHigh = true
      end
    end
    Assert.isTrue(foundLow, "the upper row matches the scanline law")
    Assert.isTrue(foundHigh, "the lower row matches the scanline law")
  end
  local subScissors = 0
  for index = probeBaseline + 1, #probeGraphics.scissorIntersections do
    if probeGraphics.scissorCanvases[index].canvas == probeMovie.subCanvas then
      subScissors = subScissors + 1
    end
  end
  Assert.equal(subScissors, 0, "the wipe never spills onto the other engine")
  probeMovie:dispose()
  local other = manifestFor(2)
  other.timeline = {
    steps = {
      { id = "open", events = { 1, 2 }, ["until"] = { kind = "duration", ticks = 25 } },
      { id = "close", events = { 3, 4 }, ["until"] = { kind = "effect", effect = "wipe-other" } },
    },
    events = {
      {
        op = "setScroll",
        stepId = "open",
        atStepTick = 0,
        engine = "main",
        bgSlot = 0,
        dx = -256,
        dy = 0,
        ticks = 25,
      },
      { op = "waitTicks", stepId = "open", atStepTick = 0, ticks = 25 },
      {
        op = "circleWipe",
        stepId = "close",
        atStepTick = 0,
        engine = "main",
        kind = 1,
        ticks = 10,
        effect = "wipe-other",
      },
      { op = "finish", stepId = "close", atStepTick = 0 },
    },
  }
  local otherRaw = {}
  for sceneNumber = 1, 5 do
    otherRaw[sceneNumber] = manifestFor(sceneNumber)
  end
  otherRaw[2] = other
  local otherCache = stubCache(otherRaw)
  local otherScenes = {}
  for sceneNumber = 1, 5 do
    local loaded, err = StartupAssetCache.loadOpeningScene(otherCache, sceneNumber, VERSION_ID)
    Assert.notNil(loaded, "synthetic scene " .. sceneNumber .. " passes the strict scene reader: " .. tostring(err))
    otherScenes[sceneNumber] = loaded
  end
  local otherGraphics = movieGraphics()
  local otherMovie = openMovie(otherScenes, otherCache, otherGraphics)
  while otherMovie:sceneNumber() < 2 do
    otherMovie:updateFixed()
  end
  for _ = 1, 27 do
    otherMovie:updateFixed()
  end
  local otherBaseline = #otherGraphics.scissorIntersections
  otherMovie:draw()
  local function otherEdges(y)
    local edges = {}
    for index = otherBaseline + 1, #otherGraphics.scissorIntersections do
      local entry = otherGraphics.scissorIntersections[index]
      if otherGraphics.scissorCanvases[index].canvas == otherMovie.mainCanvas then
        local requested = entry.requested
        if y >= requested[2] and y < requested[2] + requested[4] then
          edges[#edges + 1] = requested[1]
        end
      end
    end
    table.sort(edges)
    return edges
  end
  local kindLow = otherEdges(48)
  local kindHigh = otherEdges(96)
  if #probeLow > 0 and #kindLow > 0 then
    Assert.isFalse(
      #probeLow == #kindLow and probeLow[1] == kindLow[1],
      "different wipe kinds target different windows"
    )
  elseif #probeHigh > 0 and #kindHigh > 0 then
    Assert.isFalse(
      #probeHigh == #kindHigh and probeHigh[1] == kindHigh[1],
      "different wipe kinds target different windows"
    )
  else
    Assert.isTrue(
      #kindLow > 0 or #kindHigh > 0 or #otherGraphics.canvases > probeCanvases,
      "the other kind also clips per row instead of one centered rectangle"
    )
  end
  otherMovie:dispose()
  Assert.isTrue(movie:isFinished(), "the movie finishes within its bounded run")
  Assert.equal(entries[2], 90, "scene 2 still starts on its authored tick")
  Assert.equal(entries[3], 125, "the close step holds exactly the wipe's ten authored ticks")
  movie:dispose()
  Assert.equal(liveHandles(graphics), 0, "the wipe step leaves no handle behind")
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

-- Bounded-preflight evidence: the constructor must prove every scene with a
-- real offscreen render while never holding more than two retained graphs
-- plus one transient. Images attribute to scenes through the staged-art
-- read that stages them (acquisition always reads art immediately before
-- creating its image), so the peak counts live scene graphs rather than
-- raw handles or a post-construction snapshot.
---@param graphics table fake graphics namespace with creation order intact
---@param cacheFs table staged art backing the scenes
---@return table tracker peak/live scene-graph record with a pendingScene probe
---@return table watchedCacheFs art access attributing each read to its scene
local function watchSceneGraphs(graphics, cacheFs)
  local tracker = { peak = 0, liveByScene = {}, unattributed = 0, pendingScene = nil }
  local function sample()
    local live = 0
    for _, count in pairs(tracker.liveByScene) do
      if count > 0 then
        live = live + 1
      end
    end
    if live > tracker.peak then
      tracker.peak = live
    end
  end
  local watchedCacheFs = {
    loadLua = function(_, path)
      return cacheFs:loadLua(path)
    end,
    exists = function()
      return true
    end,
    read = function(_, path)
      local scene = string.match(tostring(path), "opening/(%d+)/")
      tracker.pendingScene = scene ~= nil and tonumber(scene) or nil
      return cacheFs:read(path)
    end,
  }
  local realNewImage = graphics.newImage
  graphics.newImage = function(data)
    local image = realNewImage(data)
    local scene = tracker.pendingScene
    tracker.pendingScene = nil
    if scene == nil then
      tracker.unattributed = tracker.unattributed + 1
    else
      tracker.liveByScene[scene] = (tracker.liveByScene[scene] or 0) + 1
    end
    sample()
    local realRelease = image.release
    image.release = function()
      realRelease()
      if scene ~= nil then
        tracker.liveByScene[scene] = tracker.liveByScene[scene] - 1
      end
      sample()
    end
    return image
  end
  return tracker, watchedCacheFs
end

---@param Movie table movie module owning the compositor under test
---@return table rendered scene numbers in render order
---@return fun() restore releasing the watch without touching the module otherwise
local function watchRenders(Movie)
  local rendered = {}
  local realRender = Movie._renderRoles
  Movie._renderRoles = function(self, slot)
    rendered[#rendered + 1] = slot.sceneNumber
    return realRender(self, slot)
  end
  return rendered, function()
    Movie._renderRoles = realRender
  end
end

function T.preflight_holds_at_most_three_scene_graphs_while_readying_all_five()
  local scenes, cacheFs = validPack()
  local graphics = movieGraphics()
  local tracker, watchedCacheFs = watchSceneGraphs(graphics, cacheFs)
  local Movie = requireMovie()
  local rendered, stopWatching = watchRenders(Movie)
  local movie = nil
  local ok, failure = pcall(function()
    movie = openMovie(scenes, watchedCacheFs, graphics)
  end)
  stopWatching()
  Assert.isTrue(ok, "bounded preflight still readies a drawable movie: " .. tostring(failure))
  Assert.equal(#rendered, 5, "every scene proves its first frame before handoff, never a manifest-only check")
  for sceneNumber = 1, 5 do
    Assert.equal(rendered[sceneNumber], sceneNumber, "preflight renders scenes in retail order without overlap")
  end
  Assert.isTrue(tracker.peak <= 3, "at most two retained graphs plus one transient coexist, peak " .. tracker.peak)
  Assert.equal(tracker.unattributed, 0, "every staged image attributes to exactly one scene graph")
  Assert.isTrue((tracker.liveByScene[1] or 0) > 0, "the current scene graph stays resident")
  Assert.isTrue((tracker.liveByScene[2] or 0) > 0, "the next scene graph stays resident")
  for sceneNumber = 3, 5 do
    Assert.equal(tracker.liveByScene[sceneNumber] or 0, 0, "transient scene " .. sceneNumber .. " releases before return")
  end
  Assert.equal(#graphics.canvases, 2, "preflight keeps exactly two bounded role targets")
  for _, canvas in ipairs(graphics.canvases) do
    Assert.equal(canvas.width, 256, "every role target keeps the source engine width")
    Assert.equal(canvas.height, 192, "every role target keeps the source engine height")
  end
  Assert.equal(movie:sceneNumber(), 1, "preflight consumes no source time")
  Assert.equal(movie.current.sceneTick, 0, "the retained current scene starts on its first tick")
  Assert.equal(movie.nextSlot.sceneTick, 0, "the retained next scene starts on its first tick")
  Assert.isFalse(movie:skipAllowed(), "preflight leaves the skip gate closed")
  Assert.isFalse(movie:isFinished(), "preflight never finishes the movie")
  movie:draw()
  movie:resize(640, 480)
  Assert.equal(movie:sceneNumber(), 1, "host draws and resizes before the first tick never advance source time")
  local ticks = 0
  while movie:sceneNumber() < 3 and ticks < 5000 do
    movie:updateFixed()
    ticks = ticks + 1
    movie:draw()
  end
  Assert.equal(movie:sceneNumber(), 3, "the retained graphs hand off to a lazily acquired third scene")
  Assert.isTrue(tracker.peak <= 3, "playback prefetch never exceeds the preflight bound, peak " .. tracker.peak)
  movie:dispose()
  Assert.equal(liveHandles(graphics), 0, "disposing the preflighted movie releases every handle")
  for _, group in ipairs({ graphics.images, graphics.canvases, graphics.meshes or {} }) do
    for _, handle in ipairs(group) do
      Assert.equal(handle.releaseCount, 1, "every acquired handle is released exactly once")
    end
  end
end

function T.later_scene_preflight_failure_releases_every_owner_and_stays_reusable()
  local scenes, cacheFs = validPack()
  local Movie = requireMovie()
  -- A scene-four acquisition failure must release the two retained graphs
  -- and the fixed targets without ever publishing a partial movie.
  do
    local graphics = movieGraphics()
    local tracker, watchedCacheFs = watchSceneGraphs(graphics, cacheFs)
    local innerNewImage = graphics.newImage
    graphics.newImage = function(data)
      if tracker.pendingScene == 4 then
        error("injected scene-four acquisition failure")
      end
      return innerNewImage(data)
    end
    local movie = nil
    local ok, failure = pcall(function()
      movie = openMovie(scenes, watchedCacheFs, graphics)
    end)
    Assert.isNil(movie, "a failed preflight never publishes a partial movie")
    Assert.isFalse(ok, "a scene-four acquisition failure surfaces explicitly")
    Assert.equal(type(failure), "table", "a failed acquisition raises a structured error")
    Assert.equal(failure.code, "HGSS_OPENING_MOVIE_INVALID", "a failed acquisition raises the typed scene failure")
    Assert.equal(liveHandles(graphics), 0, "a scene-four failure releases every staged handle")
    for _, group in ipairs({ graphics.images, graphics.canvases, graphics.meshes or {} }) do
      for _, handle in ipairs(group) do
        Assert.equal(handle.releaseCount, 1, "every acquired handle is released exactly once")
      end
    end
    Assert.isTrue(tracker.peak <= 3, "a scene-four failure never exceeds the bound, peak " .. tracker.peak)
  end
  -- A scene-five render failure after full acquisition must release the
  -- transient alongside the retained graphs and propagate the original
  -- failure value unchanged.
  do
    local graphics = movieGraphics()
    local tracker, watchedCacheFs = watchSceneGraphs(graphics, cacheFs)
    local rendered = {}
    local realRender = Movie._renderRoles
    local sentinel = "injected scene-five render failure"
    Movie._renderRoles = function(self, slot)
      rendered[#rendered + 1] = slot.sceneNumber
      if slot.sceneNumber == 5 then
        error(sentinel, 0)
      end
      return realRender(self, slot)
    end
    local movie = nil
    local ok, failure = pcall(function()
      movie = openMovie(scenes, watchedCacheFs, graphics)
    end)
    Movie._renderRoles = realRender
    Assert.isNil(movie, "a failed preflight never publishes a partial movie")
    Assert.isFalse(ok, "a scene-five render failure surfaces explicitly")
    Assert.equal(failure, sentinel, "a transient render failure propagates the original error value")
    Assert.equal(#rendered, 5, "the fifth scene renders after the earlier scenes preflighted")
    Assert.equal(liveHandles(graphics), 0, "a scene-five failure releases every staged handle and canvas")
    for _, group in ipairs({ graphics.images, graphics.canvases, graphics.meshes or {} }) do
      for _, handle in ipairs(group) do
        Assert.equal(handle.releaseCount, 1, "every acquired handle is released exactly once")
      end
    end
    Assert.isTrue(tracker.peak <= 3, "a scene-five failure never exceeds the bound, peak " .. tracker.peak)
  end
  -- A healthy construction after both failures proves no shared state was
  -- contaminated by the rolled-back attempts.
  do
    local graphics = movieGraphics()
    local movie = openMovie(scenes, cacheFs, graphics)
    Assert.equal(movie:sceneNumber(), 1, "a healthy constructor restarts from the first scene")
    movie:draw()
    movie:dispose()
    Assert.equal(liveHandles(graphics), 0, "the healthy rerun releases every handle")
  end
end

-- Only the retail completion colors survive: kinds 1 and 3 keep a full
-- white and black hold on their own engine past completion, while kinds
-- 0 and 2 retire neutral with no wash and no further row spans. A later
-- open on the same engine resets a hold instead of stacking washes, and
-- the idle engine never carries a span or a wash.
function T.finished_wipe_brightness_holds_only_for_the_retail_kinds_until_the_next_open()
  local root = sceneRoot(1)
  local beats = { 1, 0, 3, 2 }
  local steps, events = {}, {}
  for position, kind in ipairs(beats) do
    steps[#steps + 1] =
      { id = "wipe-" .. kind, events = { #events + 1 }, ["until"] = { kind = "effect", effect = "wipe-" .. kind } }
    events[#events + 1] = {
      op = "circleWipe",
      stepId = "wipe-" .. kind,
      atStepTick = 0,
      engine = "main",
      kind = kind,
      ticks = 8,
      effect = "wipe-" .. kind,
    }
    local holdEvents = { #events + 1 }
    events[#events + 1] = { op = "waitTicks", stepId = "hold-" .. kind, atStepTick = 0, ticks = 6 }
    if position == 1 then
      -- The opening scene carries its skip gate exactly once; later beats
      -- need no second gate.
      holdEvents[#holdEvents + 1] = #events + 1
      events[#events + 1] = { op = "enableSkip", stepId = "hold-" .. kind, atStepTick = 5 }
    end
    steps[#steps + 1] = { id = "hold-" .. kind, events = holdEvents, ["until"] = { kind = "duration", ticks = 6 } }
  end
  steps[#steps + 1] = { id = "done", events = { #events + 1, #events + 2 }, ["until"] = { kind = "duration", ticks = 5 } }
  events[#events + 1] = { op = "waitTicks", stepId = "done", atStepTick = 0, ticks = 5 }
  events[#events + 1] = { op = "finish", stepId = "done", atStepTick = 0 }
  local scenes, cacheFs = packWithOverrides({
    [1] = {
      schema = Contract.startupOpeningScene.schema,
      versionId = VERSION_ID,
      generationId = "movie-test-generation",
      sceneNumber = 1,
      sourceTickRate = Contract.startupOpeningScene.tickRate,
      layers = {
        main = { layer(0, root .. "layers/hold-upper.png") },
        sub = { layer(0, root .. "layers/hold-lower.png") },
      },
      spriteClips = {},
      models = {},
      particles = { seed = 0, emitters = {} },
      timeline = { steps = steps, events = events },
      assets = { [root .. "layers/hold-upper.png"] = true, [root .. "layers/hold-lower.png"] = true },
    },
  })
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  local function enterWipe(stepId)
    for _ = 1, 5000 do
      local slot = assert(movie.current, "the running movie owns its current slot")
      local step = assert(slot.manifest.timeline.steps[slot.stepIndex], "the movie stays on a known step")
      if slot.sceneNumber == 1 and step.id == stepId and slot.wipe ~= nil then
        return slot
      end
      movie:updateFixed()
      movie:draw()
    end
    error("the movie never reaches " .. tostring(stepId), 0)
  end
  local function fullCanvasWashes(baseline)
    local found = {}
    for index = baseline + 1, #graphics.rectangles do
      local rect = graphics.rectangles[index]
      if rect.mode == "fill" and rect.w == 256 and rect.h == 192 then
        found[#found + 1] = rect.color
      end
    end
    return found
  end
  local function mainRowSpans(baseline)
    local count = 0
    for index = baseline + 1, #graphics.scissorIntersections do
      if graphics.scissorCanvases[index].canvas == movie.mainCanvas then
        local requested = graphics.scissorIntersections[index].requested
        if requested[4] == 1 and requested[3] < 256 then
          count = count + 1
        end
      end
    end
    return count
  end
  local function subSpans(baseline)
    local count = 0
    for index = baseline + 1, #graphics.scissorIntersections do
      if graphics.scissorCanvases[index].canvas == movie.subCanvas then
        count = count + 1
      end
    end
    return count
  end
  local holds = {
    [1] = { r = 1, g = 1, b = 1 },
    [3] = { r = 0, g = 0, b = 0 },
  }
  for _, kind in ipairs(beats) do
    local slot = enterWipe("wipe-" .. kind)
    Assert.equal(slot.wipe.engine, "main", "kind " .. kind .. " owns the main engine")
    Assert.equal(slot.wipe.kind, kind, "kind " .. kind .. " runs its own program")
    do
      local baseline = #graphics.scissorIntersections
      movie:draw()
      Assert.equal(subSpans(baseline), 0, "kind " .. kind .. " never clips the idle engine")
    end
    for _ = 1, 8 do
      movie:updateFixed()
    end
    Assert.equal(slot.wipe.elapsed, 8, "kind " .. kind .. " reaches its final edge on its eighth tick")
    local finishBaseline = #graphics.rectangles
    local finishScissors = #graphics.scissorIntersections
    movie:draw()
    Assert.equal(movie.current.wipe.elapsed, 8, "a draw advances no source tick")
    local finishes = fullCanvasWashes(finishBaseline)
    local hold = holds[kind]
    if hold ~= nil then
      Assert.equal(#finishes, 1, "kind " .. kind .. " finishes with its own full hold")
      Assert.equal(finishes[1][1], hold.r, "kind " .. kind .. " holds its source red channel")
      Assert.equal(finishes[1][2], hold.g, "kind " .. kind .. " holds its source green channel")
      Assert.equal(finishes[1][3], hold.b, "kind " .. kind .. " holds its source blue channel")
    else
      Assert.equal(#finishes, 0, "kind " .. kind .. " finishes neutral with no wash")
    end
    Assert.equal(mainRowSpans(finishScissors), 0, "the finished kind " .. kind .. " clips no further rows")
    for _ = 1, 3 do
      movie:updateFixed()
    end
    local holdBaseline = #graphics.rectangles
    movie:draw()
    local held = fullCanvasWashes(holdBaseline)
    if hold ~= nil then
      Assert.equal(#held, 1, "kind " .. kind .. " keeps its hold past completion")
      Assert.equal(held[1][1], hold.r, "the kept hold keeps its source red channel")
      Assert.equal(held[1][2], hold.g, "the kept hold keeps its source green channel")
      Assert.equal(held[1][3], hold.b, "the kept hold keeps its source blue channel")
    else
      Assert.equal(#held, 0, "kind " .. kind .. " stays neutral past completion")
    end
  end
  movie:dispose()
  Assert.equal(liveHandles(graphics), 0, "the hold movie releases every handle")
end

-- The fifth-scene line shutter runs its two engine fades strictly in
-- order: one event arms both row masks masked black with main active,
-- main opens center-out while sub stays black, sub rises bottom-up only
-- after main finishes, and the named wait stays pending until both engine
-- cleanups terminate. Host draws and resizes never advance the shutters.
function T.scene_five_shutter_opens_main_center_out_before_sub_bottom_up_and_waits_for_both_cleanups()
  local root = sceneRoot(5)
  local upperImage = root .. "upper-bg.png"
  local lowerImage = root .. "lower-bg.png"
  local scenes, cacheFs = packWithOverrides({
    [5] = {
      schema = Contract.startupOpeningScene.schema,
      versionId = VERSION_ID,
      generationId = "movie-test-generation",
      sceneNumber = 5,
      sourceTickRate = Contract.startupOpeningScene.tickRate,
      layers = {
        main = { layer(0, upperImage) },
        sub = { layer(0, lowerImage) },
      },
      spriteClips = {},
      models = {},
      particles = { seed = 0, emitters = {} },
      timeline = {
        steps = {
          { id = "wipe", events = { 1, 2, 3, 4 }, ["until"] = { kind = "duration", ticks = 18 } },
          { id = "scroll", events = { 5 }, ["until"] = { kind = "effect", effect = "scene5-shutter" } },
          { id = "tail", events = { 6, 7 }, ["until"] = { kind = "duration", ticks = 5 } },
        },
        events = {
          { op = "setScreenMapping", stepId = "wipe", atStepTick = 0, mainPhysical = "lower" },
          { op = "setScroll", stepId = "wipe", atStepTick = 0, engine = "main", bgSlot = 0, dx = 0, dy = 160, ticks = 0 },
          { op = "setScroll", stepId = "wipe", atStepTick = 0, engine = "sub", bgSlot = 0, dx = 0, dy = 160, ticks = 0 },
          {
            op = "shutterFade",
            stepId = "wipe",
            atStepTick = 0,
            order = "main-then-sub",
            mainPattern = "center-out",
            subPattern = "bottom-up",
            color = "black",
            steps = 18,
            framesPerStep = 1,
            effect = "scene5-shutter",
          },
          { op = "waitEffects", stepId = "scroll", atStepTick = 0, effects = { "scene5-shutter" } },
          { op = "waitTicks", stepId = "tail", atStepTick = 0, ticks = 5 },
          { op = "finish", stepId = "tail", atStepTick = 0 },
        },
      },
      assets = { [upperImage] = true, [lowerImage] = true },
    },
  })
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  local ticks = 0
  while movie:sceneNumber() < 5 and ticks < 5000 do
    movie:updateFixed()
    movie:draw()
    ticks = ticks + 1
  end
  Assert.equal(movie:sceneNumber(), 5, "playback reaches the shutter scene")
  local slot = assert(movie.current, "the running movie owns its current slot")
  local step = assert(slot.manifest.timeline.steps[slot.stepIndex], "the movie stays on a known step")
  Assert.equal(step.id, "wipe", "the shutter scene opens on its wipe step")
  local shutter = assert(slot.shutter, "the wipe step arms the ordered line shutter")
  Assert.equal(shutter.active, "main", "the shutter opens the main engine first")
  Assert.equal(shutter.main.elapsed, 0, "the main shutter starts closed")
  Assert.equal(shutter.sub.elapsed, 0, "the sub shutter starts closed")
  Assert.isFalse(slot.effects["scene5-shutter"].done, "the shutter wait starts pending")
  for _ = 1, 9 do
    movie:updateFixed()
  end
  Assert.equal(shutter.main.elapsed, 9, "nine ticks open nine main steps")
  Assert.equal(shutter.sub.elapsed, 0, "the sub shutter waits while main runs")
  Assert.equal(shutter.active, "main", "main stays active halfway through")
  Assert.isFalse(slot.effects["scene5-shutter"].done, "the shutter wait stays pending mid-main")
  local function snapshot()
    return {
      main = shutter.main.elapsed,
      sub = shutter.sub.elapsed,
      active = shutter.active,
      done = slot.effects["scene5-shutter"].done,
    }
  end
  local function assertStill(snapshotBefore, message)
    local now = snapshot()
    Assert.deepEqual(now, snapshotBefore, message)
  end
  local frozen = snapshot()
  movie:draw()
  assertStill(frozen, "a host draw advances no shutter step")
  movie:resize(600, 1000)
  movie:draw()
  assertStill(frozen, "a resize and draw advance no shutter step")
  movie:resize(WIDTH, HEIGHT)
  movie:draw()
  assertStill(frozen, "restoring the stage advances no shutter step")
  for _ = 1, 9 do
    movie:updateFixed()
  end
  Assert.equal(shutter.sub.elapsed, 0, "the sub shutter stays masked through the main finish")
  Assert.isFalse(slot.effects["scene5-shutter"].done, "the shutter wait stays pending at the main finish")
  local handedOff = false
  for _ = 1, 36 do
    movie:updateFixed()
    if shutter.sub.elapsed > 0 or shutter.active == "sub" then
      handedOff = true
      break
    end
  end
  Assert.isTrue(handedOff, "the sub shutter starts after main completes")
  Assert.isFalse(slot.effects["scene5-shutter"].done, "the handoff itself completes no wait")
  for _ = 1, 200 do
    if shutter.sub.elapsed >= 9 then
      break
    end
    movie:updateFixed()
  end
  Assert.isTrue(shutter.sub.elapsed >= 9, "the sub shutter advances bottom-up once active")
  Assert.isFalse(slot.effects["scene5-shutter"].done, "the shutter wait stays pending mid-sub")
  frozen = snapshot()
  movie:draw()
  movie:resize(600, 1000)
  movie:draw()
  movie:resize(WIDTH, HEIGHT)
  assertStill(frozen, "draws and resizes never advance the sub shutter either")
  local finished = false
  for _ = 1, 120 do
    movie:updateFixed()
    if slot.effects["scene5-shutter"].done then
      finished = true
      break
    end
  end
  Assert.isTrue(finished, "both engine cleanups terminate the shutter wait")
  local advanced = false
  for _ = 1, 60 do
    local current = assert(movie.current, "the running movie owns its current slot")
    local currentStep = assert(current.manifest.timeline.steps[current.stepIndex], "the movie stays on a known step")
    if currentStep.id == "tail" or current.sceneNumber ~= 5 then
      advanced = true
      break
    end
    movie:updateFixed()
  end
  Assert.isTrue(advanced, "the gated step advances only after both cleanups")
  movie:dispose()
  Assert.equal(liveHandles(graphics), 0, "the shutter movie releases every handle")
end

-- A first-target blend program for the compositor ownership proofs: two
-- opaque main planes with the top selected and the middle underneath.
---@return table strict synthetic opening scene carrying one blend program
local function blendScene()
  local root = sceneRoot(1)
  local upperImage = root .. "layers/blend-upper.png"
  local midImage = root .. "layers/blend-mid.png"
  local lowerImage = root .. "layers/blend-lower.png"
  return {
    schema = Contract.startupOpeningScene.schema,
    versionId = VERSION_ID,
    generationId = "movie-test-generation",
    sceneNumber = 1,
    sourceTickRate = Contract.startupOpeningScene.tickRate,
    layers = {
      main = { layer(0, upperImage), layer(1, midImage) },
      sub = { layer(0, lowerImage) },
    },
    spriteClips = {},
    models = {},
    particles = { seed = 0, emitters = {} },
    timeline = {
      steps = { { id = "hold", events = { 1, 2, 3, 4 }, ["until"] = { kind = "duration", ticks = 40 } } },
      events = {
        {
          op = "setBlend",
          stepId = "hold",
          atStepTick = 0,
          engine = "main",
          firstMask = 1,
          secondMask = 2,
          direction = 0,
          effect = "blend-hold",
          ticks = 31,
        },
        { op = "enableSkip", stepId = "hold", atStepTick = 10 },
        { op = "waitTicks", stepId = "hold", atStepTick = 0, ticks = 40 },
        { op = "finish", stepId = "hold", atStepTick = 40 },
      },
    },
    assets = { [upperImage] = true, [midImage] = true, [lowerImage] = true },
  }
end

---@return table[] scenes, table cacheFs strict pack with the blend scene first
local function packWithBlend()
  local raw = {
    blendScene(),
    manifestFor(2),
    manifestFor(3),
    manifestFor(4),
    neutralSceneFive(),
  }
  local cacheFs = stubCache(raw)
  local scenes = {}
  for sceneNumber = 1, 5 do
    local loaded, err = StartupAssetCache.loadOpeningScene(cacheFs, sceneNumber, VERSION_ID)
    Assert.notNil(loaded, "synthetic scene " .. sceneNumber .. " passes the strict scene reader: " .. tostring(err))
    scenes[sceneNumber] = loaded
  end
  return scenes, cacheFs
end

---@param graphics table fake graphics namespace
---@return integer total shader uniform sends recorded so far
local function shaderSendCount(graphics)
  local total = 0
  for _, shader in ipairs(graphics.shaders) do
    total = total + #shader.sends
  end
  return total
end

function T.compositor_targets_stay_bounded_across_draws_and_resizes()
  local scenes, cacheFs = packWithBlend()
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  Assert.equal(#graphics.shaders, 2, "the compositor acquires exactly two private shaders once")
  local auxiliary = 0
  for _, canvas in ipairs(graphics.canvases) do
    if canvas.width == 256 and canvas.height == 192 and canvas ~= movie.mainCanvas and canvas ~= movie.subCanvas then
      auxiliary = auxiliary + 1
    end
  end
  Assert.equal(auxiliary, 5, "the compositor owns exactly five fixed auxiliary targets")
  Assert.isTrue(#graphics.canvases <= 8, "standing native targets stay bounded")
  for _ = 1, 5 do
    movie:updateFixed()
  end
  -- Construction preflight already renders the opening frame through the
  -- compositor, so the replay comparison counts frame deltas exactly like
  -- the draws assertion instead of doubling the construction total.
  local drawsAfterConstruct = #graphics.draws
  local sendsAfterConstruct = shaderSendCount(graphics)
  movie:draw()
  local firstFrameDraws = #graphics.draws - drawsAfterConstruct
  local firstFrameSends = shaderSendCount(graphics) - sendsAfterConstruct
  Assert.isTrue(firstFrameSends > 0, "a blend frame drives the compositor shaders")
  local sceneTick = assert(movie.current, "the running movie owns its current slot").sceneTick
  movie:draw()
  Assert.equal(
    #graphics.draws - drawsAfterConstruct - firstFrameDraws,
    firstFrameDraws,
    "a repeated draw replays the identical frame"
  )
  Assert.equal(
    shaderSendCount(graphics) - sendsAfterConstruct,
    firstFrameSends * 2,
    "a repeated draw replays the identical compositor passes"
  )
  Assert.equal(
    assert(movie.current, "the running movie owns its current slot").sceneTick,
    sceneTick,
    "repeated draws never advance source time"
  )
  local canvasCount = #graphics.canvases
  movie:resize(800, 600)
  movie:draw()
  Assert.equal(#graphics.shaders, 2, "a resize acquires no additional shader")
  Assert.equal(#graphics.canvases, canvasCount, "a resize keeps the standing targets")
  Assert.equal(
    assert(movie.current, "the running movie owns its current slot").sceneTick,
    sceneTick,
    "a resize never advances source time"
  )
  movie:resize(WIDTH, HEIGHT)
  movie:dispose()
  Assert.equal(liveHandles(graphics), 0, "disposing the bounded movie releases every handle")
  for _, canvas in ipairs(graphics.canvases) do
    Assert.equal(canvas.releaseCount, 1, "every standing target releases exactly once")
  end
  for _, shader in ipairs(graphics.shaders) do
    Assert.isTrue(shader.released, "every private shader releases exactly once")
  end
end

---@param graphics table fake graphics namespace
---@param message string assertion context
local function assertReleasedExactlyOnce(graphics, message)
  for _, group in ipairs({ graphics.images, graphics.canvases, graphics.meshes or {} }) do
    for _, handle in ipairs(group) do
      Assert.isTrue(handle.released, message)
      Assert.equal(handle.releaseCount, 1, message)
    end
  end
  for _, shader in ipairs(graphics.shaders) do
    Assert.isTrue(shader.released, message)
  end
end

function T.compositor_acquisition_failures_release_every_handle_exactly_once()
  for _, failing in ipairs({
    { failOnShaderCall = 1, label = "first shader" },
    { failOnShaderCall = 2, label = "second shader" },
    { failOnCanvasCall = 4, label = "middle auxiliary target" },
  }) do
    local scenes, cacheFs = packWithBlend()
    local fakeOpts = {}
    if failing.failOnShaderCall ~= nil then
      fakeOpts.failOnShaderCall = failing.failOnShaderCall
    else
      fakeOpts.failOnCanvasCall = failing.failOnCanvasCall
    end
    local graphics = movieGraphics(fakeOpts)
    Assert.throws(function()
      openMovie(scenes, cacheFs, graphics)
    end, "a failed " .. failing.label .. " acquisition aborts construction")
    Assert.equal(liveHandles(graphics), 0, "a failed " .. failing.label .. " leaves no live handle")
    assertReleasedExactlyOnce(
      graphics,
      "a failed " .. failing.label .. " releases every acquired handle exactly once"
    )
  end
end

function T.failed_compositor_draws_restore_graphics_state_and_keep_playing()
  local scenes, cacheFs = packWithBlend()
  local fakeOpts = {}
  local graphics = movieGraphics(fakeOpts)
  local movie = openMovie(scenes, cacheFs, graphics)
  Assert.equal(#graphics.shaders, 2, "the failing frame routes through the compositor shaders")
  for _ = 1, 5 do
    movie:updateFixed()
  end
  local canvas, shader = graphics.getCanvas(), graphics.getShader()
  local r, g, b, a = graphics.getColor()
  local blend, alpha = graphics.getBlendMode()
  fakeOpts.failOnDrawCall = #graphics.draws + 2
  local ok = pcall(function()
    movie:draw()
  end)
  Assert.isFalse(ok, "a failed compositor draw surfaces explicitly")
  Assert.isTrue(shaderSendCount(graphics) > 0, "the failing draw reached the compositor passes")
  Assert.equal(graphics.getCanvas(), canvas, "a failed compositor draw restores the borrowed canvas")
  Assert.equal(graphics.getShader(), shader, "a failed compositor draw restores the borrowed shader")
  local r2, g2, b2, a2 = graphics.getColor()
  Assert.equal(r2, r, "a failed compositor draw restores the borrowed color")
  Assert.equal(g2, g, "a failed compositor draw restores the borrowed color")
  Assert.equal(b2, b, "a failed compositor draw restores the borrowed color")
  Assert.equal(a2, a, "a failed compositor draw restores the borrowed color")
  local blend2, alpha2 = graphics.getBlendMode()
  Assert.equal(blend2, blend, "a failed compositor draw restores the borrowed blend mode")
  Assert.equal(alpha2, alpha, "a failed compositor draw restores the borrowed blend mode")
  Assert.equal(graphics.pushDepth(), 0, "a failed compositor draw leaves no pushed scope behind")
  fakeOpts.failOnDrawCall = nil
  movie:draw()
  local ticks = 0
  while not movie:isFinished() and ticks < 5000 do
    movie:updateFixed()
    ticks = ticks + 1
    movie:draw()
  end
  Assert.isTrue(movie:isFinished(), "playback resumes and completes after the failed compositor draw")
  movie:dispose()
  Assert.equal(liveHandles(graphics), 0, "disposing after the failed draw releases everything")
  assertReleasedExactlyOnce(graphics, "every handle releases exactly once after the failed draw")
end

return { tests = T }
