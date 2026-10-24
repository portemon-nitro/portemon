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
      { op = "circleWipe", stepId = "close", atStepTick = 0, engine = "main", kind = 0, ticks = 10 },
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
    { op = "circleWipe", stepId = "wipe", atStepTick = 0, engine = "main", kind = 1, ticks = 18 },
    { op = "setScreenMapping", stepId = "wipe", atStepTick = 0, mainPhysical = "upper" },
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
  -- tick past completion, no early release while it runs. Exact blend
  -- coefficients and scanline coverage stay owned by the later effect
  -- deliverable; this step only proves the wait binds the wipe effect.
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

return { tests = T }
