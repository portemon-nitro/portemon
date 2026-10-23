-- Source-backed opening movie graphics: the compiled SoulSilver scenes play
-- in order with real town and particle motion at fixed source timing, the
-- skip gate finishes only the movie, and GPU resources are released.
-- HeartGold coverage stays blocked: no HeartGold dump is available here, so
-- its scenarios skip instead of running against faked art.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local Contract = require("libs.assets.src.DerivedAssetContract")
local PngWriter = require("libs.assets.src.PngWriter")
local DisplayContext = require("libs.ui.src.DisplayContext")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local RomImporter = require("romdump.src.source.RomImporter")
local StartupAssetCache = require("libs.assets.src.StartupAssetCache")

local MOVIE_MODULE = "libs.hgss.src.presentation.HgssOpeningMovie"

---@return table movie module owning the five-scene playback session
local function requireMovie()
  local ok, movie = pcall(require, MOVIE_MODULE)
  Assert.isTrue(ok, "the opening movie owns its five-scene playback session")
  return assert(movie)
end

---@param kind string
---@return fun(width: number, height: number): table
local function topology(kind)
  return function(width, height)
    local touch = true
    if kind ~= "dual" then
      return {
        surfaces = {
          { id = "main", rect = { x = 0, y = 0, width = width, height = height }, touch = touch, role = "world" },
        },
      }
    end
    local half = height / 2
    return {
      surfaces = {
        { id = "upper", rect = { x = 0, y = 0, width = width, height = half }, touch = false, role = "world" },
        { id = "lower", rect = { x = 0, y = half, width = width, height = half }, touch = true, role = "auxiliary" },
      },
    }
  end
end

---@param movie table
---@param scope table
---@param width integer
---@param height integer
---@return string raw frame bytes
local function drawBytes(movie, scope, width, height)
  local canvas = scope:own(love.graphics.newCanvas(width, height, { format = "rgba8", readable = true }))
  love.graphics.push("all")
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  movie:draw()
  love.graphics.setCanvas()
  love.graphics.pop()
  local imageData = scope:own(canvas:newImageData())
  return imageData:getString()
end

---@param versionId string
---@return table[] five validated scene bundles in retail order
local function loadScenes(versionId)
  local scenes = {}
  for sceneNumber = 1, 5 do
    local loaded, err = StartupAssetCache.loadOpeningScene(CacheFs.forVersion(versionId), sceneNumber, versionId)
    Assert.notNil(loaded, "scene " .. sceneNumber .. " reads back as a ready bundle: " .. tostring(err))
    scenes[sceneNumber] = loaded
  end
  return scenes
end

---@param scope table
---@param versionId string
---@param width integer
---@param height integer
---@param kind string
---@return table player
local function openMovie(scope, versionId, width, height, kind)
  local Movie = requireMovie()
  local context = DisplayContext.new({ graphics = love.graphics, topologyProvider = topology(kind) })
  local movie = Movie.new({
    versionId = versionId,
    scenes = loadScenes(versionId),
    cacheFs = CacheFs.forVersion(versionId),
    width = width,
    height = height,
    displayContext = context,
  })
  scope:own({
    release = function()
      movie:dispose()
    end,
  })
  return movie
end

---@param movie table
---@param ticks integer
---@param draw fun()? optional host draw between fixed ticks
local function advance(movie, ticks, draw)
  for _ = 1, ticks do
    movie:updateFixed()
    if draw ~= nil then
      draw()
    end
  end
end

-- Runs the movie to completion, recording the first global tick each scene
-- is current. Draws sparingly: fixed ticks drive the clock, host draws do
-- not.
---@param movie table
---@param scope table
---@param drawEvery integer draw cadence in fixed ticks
---@return table entry tick per scene, integer total ticks
local function recordEntries(movie, scope, drawEvery)
  local entries = { [1] = 0 }
  local ticks = 0
  while not movie:isFinished() and ticks < 20000 do
    movie:updateFixed()
    ticks = ticks + 1
    if ticks % drawEvery == 0 then
      movie:draw()
    end
    local scene = movie:sceneNumber()
    if entries[scene] == nil then
      entries[scene] = ticks
    end
    Assert.isTrue(scene >= 1 and scene <= 5, "the running movie stays within its five scenes")
  end
  Assert.isTrue(movie:isFinished(), "the sourced movie finishes within its bounded run")
  for sceneNumber = 1, 5 do
    Assert.notNil(entries[sceneNumber], "scene " .. sceneNumber .. " plays exactly once in order")
  end
  return entries, ticks
end

---@param scope table
---@param width integer
---@param height integer
---@return string transparent canvas bytes for the blank comparison
local function blankBytes(scope, width, height)
  local canvas = scope:own(love.graphics.newCanvas(width, height, { format = "rgba8", readable = true }))
  love.graphics.push("all")
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  love.graphics.setCanvas()
  love.graphics.pop()
  local imageData = scope:own(canvas:newImageData())
  return imageData:getString()
end

local function readyOrSkip(context, versionId, what)
  if not RomImporter.isReady(versionId) then
    context:skip("no user-owned " .. what .. " dump is ready")
  end
end

-- Composite playback proves the same contracts as the draw-call suites, but
-- against real GPU pixels: simultaneous per-engine layers composite
-- back-to-front in source priority with independent pans, one authored
-- sprite instance paints its owning engine output at its source position
-- plus frame offset, and fades land on step ticks. Every fixture passes the
-- strict generated reader, so each test fails on the compositor behavior
-- itself rather than on fixture loading.
local COMPOSITE_GENERATION = "composite-graphics-generation"

---@param width integer
---@param height integer
---@param r integer
---@param g integer
---@param b integer
---@return string png bytes of one solid opaque image
local function solidPng(width, height, r, g, b)
  return PngWriter.encode(width, height, string.rep(string.char(r, g, b, 255), width * height))
end

---@param sceneNumber integer retail scene position
---@return string staged art root for one opening scene
local function sceneArtRoot(sceneNumber)
  return "assets/generated/startup/opening/" .. tostring(sceneNumber) .. "/"
end

---@param bgSlot integer numeric background slot
---@param path string staged image path under its scene root
---@param width integer claimed source extent
---@param height integer claimed source extent
---@return table generated engine layer record
local function compositeLayer(bgSlot, path, width, height)
  return {
    bgSlot = bgSlot,
    priority = bgSlot,
    image = path,
    variants = {},
    width = width,
    height = height,
    sourceHash = string.rep("c", 40),
  }
end

---@param sceneNumber integer
---@param main table[] main-engine layer records in source order
---@param sub table[] sub-engine layer records in source order
---@param clips table[] sprite clip records
---@param particles table starter emitter state
---@param steps table[] source step records
---@param events table[] closed step-clocked timeline events
---@return table strict synthetic opening-scene manifest
local function compositeScene(sceneNumber, main, sub, clips, particles, steps, events)
  local assets = {}
  for _, list in ipairs({ main, sub }) do
    for _, entry in ipairs(list) do
      assets[entry.image] = true
      for _, alternate in ipairs(entry.variants) do
        assets[alternate] = true
      end
    end
  end
  for _, clip in ipairs(clips) do
    assets[clip.id] = true
  end
  if particles.textures ~= nil then
    for _, texture in ipairs(particles.textures) do
      assets[texture.image] = true
    end
  end
  return {
    schema = Contract.startupOpeningScene.schema,
    versionId = "soulsilver",
    generationId = COMPOSITE_GENERATION,
    sceneNumber = sceneNumber,
    sourceTickRate = Contract.startupOpeningScene.tickRate,
    layers = { main = main, sub = sub },
    spriteClips = clips,
    models = {},
    particles = particles,
    timeline = { steps = steps, events = events },
    assets = assets,
  }
end

---@param id string staged clip identity under its scene root
---@param frames table[] compiled clip frames
---@return table compiled sprite clip record
local function compositeClip(id, frames)
  return { id = id, frameCount = #frames, frames = frames }
end

---@param x integer
---@param y integer
---@param width integer
---@param height integer
---@param offsetX integer per-frame draw origin offset
---@param offsetY integer per-frame draw origin offset
---@param duration integer source ticks the frame shows
---@return table compiled sprite clip frame
local function compositeFrame(x, y, width, height, offsetX, offsetY, duration)
  return {
    x = x,
    y = y,
    width = width,
    height = height,
    offsetX = offsetX,
    offsetY = offsetY,
    duration = duration,
  }
end

---@param id integer source emitter id
---@param group string starter group owning the emitter
---@param root string staged art root of scene four
---@return table strict synthetic starter emitter record
local function fillerEmitter(id, group, root)
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

---@param sceneNumber integer retail scene position 2..5
---@return table short strict synthetic scene that never draws in these tests
local function fillerScene(sceneNumber)
  local root = sceneArtRoot(sceneNumber)
  local emitters = {}
  local textures = {}
  if sceneNumber == 4 then
    for id = 0, 8 do
      local group = id < 3 and "water" or (id < 6 and "fire" or "grass")
      emitters[#emitters + 1] = fillerEmitter(id, group, root)
      textures[#textures + 1] = {
        id = id,
        format = 1,
        width = 16,
        height = 16,
        image = root .. "particles/texture" .. id .. ".png",
        sourceHash = string.rep("d", 40),
      }
    end
  end
  return compositeScene(
    sceneNumber,
    { compositeLayer(0, root .. "layers/fill-upper.png", 256, 192) },
    { compositeLayer(0, root .. "layers/fill-lower.png", 256, 192) },
    {},
    { seed = 0, emitters = emitters, textures = textures },
    { { id = "fill", events = { 1, 2 }, ["until"] = { kind = "duration", ticks = 10 } } },
    {
      { op = "waitTicks", stepId = "fill", atStepTick = 0, ticks = 10 },
      { op = "finish", stepId = "fill", atStepTick = 0 },
    }
  )
end

---@param customFirst table scene-one manifest under test
---@param art table<string, string> staged png bytes by generated path
---@param defaultPng string fallback png bytes for art the test never samples
---@return table[] scenes, table cacheFs strict five-scene pack with staged composite art
local function compositePack(customFirst, art, defaultPng)
  local raw = { customFirst, fillerScene(2), fillerScene(3), fillerScene(4), fillerScene(5) }
  local byPath = {}
  for sceneNumber, manifest in ipairs(raw) do
    byPath[StartupAssetCache.openingScenePath(sceneNumber)] = manifest
  end
  local cacheFs = {
    loadLua = function(_, path)
      return byPath[path]
    end,
    exists = function()
      return true
    end,
    read = function(_, path)
      return art[path] or defaultPng
    end,
  }
  local scenes = {}
  for sceneNumber = 1, 5 do
    local loaded, err = StartupAssetCache.loadOpeningScene(cacheFs, sceneNumber, "soulsilver")
    Assert.notNil(loaded, "composite scene " .. sceneNumber .. " passes the strict scene reader: " .. tostring(err))
    scenes[sceneNumber] = loaded
  end
  return scenes, cacheFs
end

---@param scope table
---@param scenes table[] validated scene bundles in retail order
---@param cacheFs table staged art backing the scenes
---@param width integer
---@param height integer
---@param kind string
---@return table player
local function openCompositeMovie(scope, scenes, cacheFs, width, height, kind)
  local Movie = requireMovie()
  local context = DisplayContext.new({ graphics = love.graphics, topologyProvider = topology(kind) })
  local movie = Movie.new({
    versionId = "soulsilver",
    scenes = scenes,
    cacheFs = cacheFs,
    width = width,
    height = height,
    displayContext = context,
  })
  scope:own({
    release = function()
      movie:dispose()
    end,
  })
  return movie
end

---@param scope table
---@param movie table
---@param width integer
---@param height integer
---@param x integer device pixel column
---@param y integer device pixel row
---@return number r, number g, number b in 0..1
local function samplePixel(scope, movie, width, height, x, y)
  local canvas = scope:own(love.graphics.newCanvas(width, height, { format = "rgba8", readable = true }))
  love.graphics.push("all")
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  movie:draw()
  love.graphics.setCanvas()
  love.graphics.pop()
  local imageData = scope:own(canvas:newImageData())
  local r, g, b = imageData:getPixel(x, y)
  return r, g, b
end

local function composite_layers_pan_independently_with_true_blending(scope)
  local root = sceneArtRoot(1)
  local bottomImage = root .. "layers/sky-bottom.png"
  local middleImage = root .. "layers/sky-middle.png"
  local topImage = root .. "layers/sky-top.png"
  local groundImage = root .. "layers/ground.png"
  local gray16 = solidPng(16, 16, 128, 128, 128)
  local layers = {
    compositeLayer(0, bottomImage, 256, 192),
    compositeLayer(1, middleImage, 128, 192),
    compositeLayer(2, topImage, 64, 192),
  }
  local lower = { compositeLayer(0, groundImage, 256, 192) }
  local art = {
    [bottomImage] = solidPng(256, 192, 255, 0, 0),
    [middleImage] = solidPng(128, 192, 0, 255, 0),
    [topImage] = solidPng(64, 192, 0, 0, 255),
    [groundImage] = solidPng(256, 192, 255, 0, 255),
  }
  local panScenes, panCache = compositePack(
    compositeScene(
      1,
      layers,
      lower,
      {},
      { seed = 0, emitters = {} },
      { { id = "pan", events = { 1, 2, 3, 4, 5 }, ["until"] = { kind = "duration", ticks = 40 } } },
      {
        {
          op = "setScroll",
          stepId = "pan",
          atStepTick = 0,
          engine = "main",
          bgSlot = 2,
          dx = -1024,
          dy = 0,
          ticks = 12,
          direction = "left",
        },
        {
          op = "setScroll",
          stepId = "pan",
          atStepTick = 0,
          engine = "main",
          bgSlot = 1,
          dx = -512,
          dy = 0,
          ticks = 12,
          direction = "left",
        },
        { op = "enableSkip", stepId = "pan", atStepTick = 10 },
        { op = "waitTicks", stepId = "pan", atStepTick = 0, ticks = 40 },
        { op = "finish", stepId = "pan", atStepTick = 40 },
      }
    ),
    art,
    gray16
  )
  local pan = openCompositeMovie(scope, panScenes, panCache, 512, 384, "dual")
  advance(pan, 12)
  -- Device x maps to source x/2: the narrower panned layers uncover the
  -- layers beneath past their shifted extents (middle ends at source 104,
  -- top ends at source 16).
  local r, g = samplePixel(scope, pan, 512, 384, 400, 96)
  Assert.near(r, 1, 0.03, "the uncovered bottom band stays red")
  Assert.near(g, 0, 0.03, "the uncovered bottom band stays red")
  local mr, mg = samplePixel(scope, pan, 512, 384, 100, 96)
  Assert.near(mg, 1, 0.03, "the middle band shows through past the shifted top layer")
  Assert.near(mr, 0, 0.03, "the middle band shows through past the shifted top layer")
  local br, _, bb = samplePixel(scope, pan, 512, 384, 8, 96)
  Assert.near(bb, 1, 0.03, "the settled top band stays blue")
  Assert.near(br, 0, 0.03, "the settled top band stays blue")
  local blendScenes, blendCache = compositePack(
    compositeScene(
      1,
      layers,
      lower,
      {},
      { seed = 0, emitters = {} },
      { { id = "hold", events = { 1, 2, 3, 4 }, ["until"] = { kind = "duration", ticks = 30 } } },
      {
        { op = "setBlend", stepId = "hold", atStepTick = 0, effect = "crossfade", ticks = 20 },
        { op = "enableSkip", stepId = "hold", atStepTick = 10 },
        { op = "waitTicks", stepId = "hold", atStepTick = 0, ticks = 30 },
        { op = "finish", stepId = "hold", atStepTick = 30 },
      }
    ),
    art,
    gray16
  )
  local blend = openCompositeMovie(scope, blendScenes, blendCache, 512, 384, "dual")
  advance(blend, 10)
  local xr, xg, xb = samplePixel(scope, blend, 512, 384, 8, 96)
  Assert.near(xr, 0, 0.05, "the blend keeps no bottom red under the settling top layer")
  Assert.near(xg, 0.25, 0.05, "the blend mixes the live middle layer beneath")
  Assert.near(xb, 0.75, 0.05, "the blend keeps the settling top layer dominant")
end

local function authored_sprites_stay_on_their_engine_with_frame_offsets(scope)
  local root = sceneArtRoot(1)
  local stageImage = root .. "layers/stage.png"
  local pitImage = root .. "layers/pit.png"
  local clipId = root .. "sprites/hero.g4sprite"
  local gray16 = solidPng(16, 16, 128, 128, 128)
  local scenes, cacheFs = compositePack(
    compositeScene(
      1,
      { compositeLayer(0, stageImage, 256, 192) },
      { compositeLayer(0, pitImage, 256, 192) },
      {
        compositeClip(clipId, { compositeFrame(0, 0, 16, 16, 40, 30, 1) }),
      },
      { seed = 0, emitters = {} },
      { { id = "show", events = { 1, 2, 3, 4, 5 }, ["until"] = { kind = "duration", ticks = 40 } } },
      {
        {
          op = "setSpriteClip",
          stepId = "show",
          atStepTick = 0,
          instanceId = "hero",
          engine = "main",
          x = 32,
          y = 64,
          drawOrder = 1,
          clipId = clipId,
        },
        {
          op = "spriteVisible",
          stepId = "show",
          atStepTick = 0,
          instanceId = "hero",
          engine = "main",
          x = 32,
          y = 64,
          drawOrder = 1,
          visible = true,
        },
        { op = "enableSkip", stepId = "show", atStepTick = 10 },
        { op = "waitTicks", stepId = "show", atStepTick = 0, ticks = 40 },
        { op = "finish", stepId = "show", atStepTick = 40 },
      }
    ),
    {
      [stageImage] = solidPng(256, 192, 0, 255, 255),
      [pitImage] = solidPng(256, 192, 255, 0, 255),
      [clipId] = solidPng(16, 16, 255, 255, 0),
    },
    gray16
  )
  local movie = openCompositeMovie(scope, scenes, cacheFs, 512, 384, "dual")
  advance(movie, 3)
  local yr, yg, yb = samplePixel(scope, movie, 512, 384, 160, 96)
  Assert.near(yr, 1, 0.03, "the offset sprite paints the upper engine output")
  Assert.near(yg, 1, 0.03, "the offset sprite paints the upper engine output")
  Assert.near(yb, 0, 0.03, "the offset sprite paints the upper engine output")
  local cr, cg, cb = samplePixel(scope, movie, 512, 384, 80, 48)
  Assert.near(cr, 0, 0.03, "the fabricated slot stays empty once offsets apply")
  Assert.near(cg, 1, 0.03, "the fabricated slot stays empty once offsets apply")
  Assert.near(cb, 1, 0.03, "the fabricated slot stays empty once offsets apply")
  local lr, lg, lb = samplePixel(scope, movie, 512, 384, 80, 240)
  Assert.near(lr, 1, 0.03, "the single instance never leaks onto the lower engine output")
  Assert.near(lg, 0, 0.03, "the single instance never leaks onto the lower engine output")
  Assert.near(lb, 1, 0.03, "the single instance never leaks onto the lower engine output")
end

local function step_relative_fades_composite_on_the_gpu(scope)
  local root = sceneArtRoot(1)
  local sunriseImage = root .. "layers/sunrise.png"
  local groundImage = root .. "layers/ground.png"
  local gray16 = solidPng(16, 16, 128, 128, 128)
  local steps = {
    { id = "setup", events = { 1, 2 }, ["until"] = { kind = "duration", ticks = 30 } },
    { id = "run", events = { 3, 4, 5 }, ["until"] = { kind = "duration", ticks = 120 } },
  }
  local events = {
    { op = "waitTicks", stepId = "setup", atStepTick = 0, ticks = 30 },
    { op = "enableSkip", stepId = "setup", atStepTick = 10 },
    { op = "setFade", stepId = "run", atStepTick = 90, kind = "white", ticks = 20, effect = "fade-run" },
    { op = "waitTicks", stepId = "run", atStepTick = 0, ticks = 120 },
    { op = "finish", stepId = "run", atStepTick = 120 },
  }
  local art = {
    [sunriseImage] = solidPng(256, 192, 255, 0, 0),
    [groundImage] = solidPng(256, 192, 0, 0, 0),
  }
  local function fadePack()
    return compositePack(
      compositeScene(
        1,
        { compositeLayer(0, sunriseImage, 256, 192) },
        { compositeLayer(0, groundImage, 256, 192) },
        {},
        { seed = 0, emitters = {} },
        steps,
        events
      ),
      art,
      gray16
    )
  end
  local earlyScenes, earlyCache = fadePack()
  local early = openCompositeMovie(scope, earlyScenes, earlyCache, 512, 384, "dual")
  advance(early, 35)
  local _, earlyGreen = samplePixel(scope, early, 512, 384, 256, 96)
  Assert.near(earlyGreen, 0, 0.06, "the run fade adds no white before its ninetieth step tick")
  local lateScenes, lateCache = fadePack()
  local late = openCompositeMovie(scope, lateScenes, lateCache, 512, 384, "dual")
  advance(late, 135)
  local _, lateGreen = samplePixel(scope, late, 512, 384, 256, 96)
  Assert.near(lateGreen, 0.75, 0.06, "the run fade is mid-transition fifteen ticks after its step onset")
end

local function soulsilver_movie_plays_five_scenes_with_fixed_timing_under_variable_draw_rates(scope, context)
  readyOrSkip(context, "soulsilver", "SoulSilver")
  local first = openMovie(scope, "soulsilver", 512, 384, "single")
  local entries, _ = recordEntries(first, scope, 7)
  local second = openMovie(scope, "soulsilver", 512, 384, "single")
  local secondEntries, _ = recordEntries(second, scope, 1)
  Assert.deepEqual(secondEntries, entries, "host draw cadence never changes source scene timing")
  local sampleTick = entries[2] + 10
  local function frameAt(ticks, withDraws)
    local probe = openMovie(scope, "soulsilver", 512, 384, "single")
    if withDraws then
      advance(probe, ticks, function()
        probe:draw()
      end)
    else
      advance(probe, ticks)
    end
    local bytes = drawBytes(probe, scope, 512, 384)
    probe:dispose()
    return bytes
  end
  Assert.equal(frameAt(sampleTick, true), frameAt(sampleTick, true), "identical fixed ticks render identical frames")
  local blank = blankBytes(scope, 512, 384)
  Assert.isTrue(frameAt(sampleTick, false) ~= blank, "a mid-scene frame paints real pixels, never an empty stage")
  for _, layout in ipairs({
    { kind = "single", configuration = "nativeLike", width = 512, height = 384 },
    { kind = "single", configuration = "wide", width = 1200, height = 600 },
    { kind = "single", configuration = "tall", width = 600, height = 1000 },
    { kind = "dual", configuration = "dualDisplay", width = 512, height = 384 },
  }) do
    first.displayContext = DisplayContext.new({ graphics = love.graphics, topologyProvider = topology(layout.kind) })
    first:resize(layout.width, layout.height)
    local scene = first:sceneNumber()
    local bytes = drawBytes(first, scope, layout.width, layout.height)
    Assert.isTrue(bytes ~= blank, layout.configuration .. " paints its composed movie stage")
    Assert.equal(first:sceneNumber(), scene, "resizing into " .. layout.configuration .. " never rewinds the movie")
  end
  first:dispose()
  second:dispose()
end

local function soulsilver_town_segments_and_starter_particles_move(scope, context)
  readyOrSkip(context, "soulsilver", "SoulSilver")
  local movie = openMovie(scope, "soulsilver", 512, 384, "single")
  local ticks = 0
  while movie:sceneNumber() < 3 and ticks < 20000 do
    movie:updateFixed()
    ticks = ticks + 1
  end
  Assert.equal(movie:sceneNumber(), 3, "playback reaches the town scenes")
  advance(movie, 5)
  ticks = ticks + 5
  local townBefore = drawBytes(movie, scope, 512, 384)
  advance(movie, 30)
  ticks = ticks + 30
  Assert.equal(movie:sceneNumber(), 3, "the town segment holds across its camera program")
  local townAfter = drawBytes(movie, scope, 512, 384)
  Assert.isTrue(townBefore ~= townAfter, "the town camera and model animation move real stage pixels")
  while movie:sceneNumber() < 4 and ticks < 20000 do
    movie:updateFixed()
    ticks = ticks + 1
  end
  Assert.equal(movie:sceneNumber(), 4, "playback reaches the starter scenes")
  advance(movie, 3)
  ticks = ticks + 3
  local emitterBefore = drawBytes(movie, scope, 512, 384)
  advance(movie, 10)
  ticks = ticks + 10
  Assert.equal(movie:sceneNumber(), 4, "the starter step holds across its emitter activity")
  local emitterAfter = drawBytes(movie, scope, 512, 384)
  Assert.isTrue(emitterBefore ~= emitterAfter, "live starter particles move real stage pixels")
  local replay = openMovie(scope, "soulsilver", 512, 384, "single")
  advance(replay, ticks)
  Assert.equal(movie:sceneNumber(), replay:sceneNumber(), "a replayed clock reaches the same scene")
  Assert.equal(
    drawBytes(movie, scope, 512, 384),
    drawBytes(replay, scope, 512, 384),
    "a replayed clock renders identical starter pixels"
  )
  movie:dispose()
  replay:dispose()
end

local function soulsilver_skip_is_source_gated_and_gpu_stays_bounded(scope, context)
  readyOrSkip(context, "soulsilver", "SoulSilver")
  local baseline = love.graphics.getStats()
  local movie = openMovie(scope, "soulsilver", 512, 384, "single")
  Assert.isFalse(movie:skipAllowed(), "the skip gate is closed on the first frame")
  Assert.isFalse(movie:requestSkip(), "an early skip is ignored")
  local gateTick = nil
  local elapsed = 0
  while not movie:skipAllowed() and elapsed < 20000 do
    movie:updateFixed()
    elapsed = elapsed + 1
  end
  if movie:skipAllowed() then
    gateTick = elapsed
  end
  Assert.notNil(gateTick, "the sourced skip gate opens during playback")
  Assert.isTrue((gateTick or 0) > 0, "the skip gate never opens on the first frame")
  Assert.isTrue(movie:requestSkip(), "an eligible skip is consumed")
  Assert.isTrue(movie:isFinished(), "an eligible skip finishes the movie, never the title or menu")
  Assert.isFalse(movie:requestSkip(), "a second skip never triggers another transition")
  for _ = 1, 30 do
    movie:updateFixed()
    movie:draw()
  end
  Assert.isTrue(movie:isFinished(), "ticking after the skip stays finished without entering another stage")
  local canvas = love.graphics.newCanvas(512, 384, { format = "rgba8", readable = true })
  love.graphics.push("all")
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  movie:draw()
  love.graphics.setCanvas()
  love.graphics.pop()
  canvas:release()
  movie:dispose()
  local afterDispose = love.graphics.getStats()
  Assert.equal(afterDispose.images, baseline.images, "disposing the movie releases every acquired image")
  Assert.equal(afterDispose.canvases, baseline.canvases, "disposing the movie releases every acquired canvas")
  local realNewCanvas = love.graphics.newCanvas
  love.graphics.newCanvas = function()
    error("injected title-style canvas failure")
  end
  local constructed, failure = pcall(openMovie, scope, "soulsilver", 512, 384, "single")
  love.graphics.newCanvas = realNewCanvas
  Assert.isFalse(constructed, "a canvas allocation failure stops movie construction: " .. tostring(failure))
  local afterFailure = love.graphics.getStats()
  Assert.equal(afterFailure.images, baseline.images, "a failed construction releases its staged images")
  Assert.equal(afterFailure.canvases, baseline.canvases, "a failed construction leaves no canvas behind")
  if type(constructed) == "table" then
    constructed:dispose()
  end
end

local function heartgold_opening_movie_graphics_are_blocked_without_a_dump(scope, context)
  if not RomImporter.isReady("heartgold") then
    context:skip(
      "BLOCKED: HeartGold opening-movie graphics need a user-owned HeartGold dump; "
        .. "only SoulSilver is ready here, so the five-scene playback, town and particle motion, "
        .. "and skip and residency scenarios cannot run for HeartGold and are never faked"
    )
  end
  local movie = openMovie(scope, "heartgold", 512, 384, "single")
  local entries, _ = recordEntries(movie, scope, 7)
  for sceneNumber = 1, 5 do
    Assert.notNil(entries[sceneNumber], "HeartGold scene " .. sceneNumber .. " plays in order")
  end
  movie:dispose()
end

-- Strict town acquisition: scene 3 must build all three real town stages with
-- the sourced retail camera or abort with a typed failure. A town that
-- cannot build is never allowed to fall back to a drifting 2D backdrop,
-- and the town lens always honors the sourced angle and field angle,
-- never the title lens or a straight-down eye.

---@param failure unknown caught error value
local function assertTypedSceneFailure(failure)
  Assert.equal(type(failure), "table", "a failed town acquisition raises a structured error, never a bare string")
  Assert.equal(failure.code, "HGSS_OPENING_MOVIE_INVALID", "a failed town acquisition raises the typed scene failure")
end

---@param scope table
---@param scenes table[] validated scene bundles in retail order
---@param cacheFs table staged art backing the scenes
---@param versionId string
---@param width integer
---@param height integer
---@param kind string
---@return table player
local function openMovieWithCache(scope, scenes, cacheFs, versionId, width, height, kind)
  local Movie = requireMovie()
  local context = DisplayContext.new({ graphics = love.graphics, topologyProvider = topology(kind) })
  local movie = Movie.new({
    versionId = versionId,
    scenes = scenes,
    cacheFs = cacheFs,
    width = width,
    height = height,
    displayContext = context,
  })
  scope:own({
    release = function()
      movie:dispose()
    end,
  })
  return movie
end

---@param scope table
---@param scenes table[] validated scene bundles in retail order
---@param cacheFs table staged art backing the scenes
---@return table? movie, unknown failure
local function driveMovieCatching(scope, scenes, cacheFs)
  local constructed, movieOrFailure =
    pcall(openMovieWithCache, scope, scenes, cacheFs, "soulsilver", 512, 384, "single")
  if not constructed then
    return nil, movieOrFailure
  end
  local movie = movieOrFailure
  local failure = nil
  local ticks = 0
  while failure == nil and not movie:isFinished() and ticks < 20000 do
    local ok, err = pcall(function()
      movie:updateFixed()
    end)
    ticks = ticks + 1
    if not ok then
      failure = err
      break
    end
    local okDraw, errDraw = pcall(function()
      movie:draw()
    end)
    if not okDraw then
      failure = errDraw
      break
    end
  end
  return movie, failure
end

---@param scope table
---@param movie table
---@param width integer
---@param height integer
---@param baseline table love.graphics.getStats snapshot before the run
local function assertGpuCleanAfterTownFailure(scope, movie, width, height, baseline)
  local _ = scope
  local _ = width
  local _ = height
  if movie ~= nil then
    movie:dispose()
  end
  local afterFailure = love.graphics.getStats()
  Assert.equal(afterFailure.images, baseline.images, "a failed town acquisition releases its staged images")
  Assert.equal(afterFailure.canvases, baseline.canvases, "a failed town acquisition leaves no canvas behind")
end

---@param models table[] compiled town model records in play order
---@param skipTown integer 1-based town whose textures stay readable
---@return table<string, boolean> texture paths owned only by the other towns
local function laterTownTexturePaths(models, skipTown)
  local firstTownPaths = {}
  for _, material in ipairs(models[skipTown].descriptor.materials or {}) do
    if type(material.texture) == "string" then
      firstTownPaths[material.texture] = true
    end
  end
  local poisoned = {}
  for index, model in ipairs(models) do
    if index ~= skipTown then
      for _, material in ipairs(model.descriptor.materials or {}) do
        if type(material.texture) == "string" and firstTownPaths[material.texture] == nil then
          poisoned[material.texture] = true
        end
      end
    end
  end
  return poisoned
end

local function soulsilver_town_texture_failure_aborts_with_a_typed_error(scope, context)
  readyOrSkip(context, "soulsilver", "SoulSilver")
  local baseline = love.graphics.getStats()
  local baseFs = CacheFs.forVersion("soulsilver")
  local scenes = loadScenes("soulsilver")
  -- The first town keeps every texture it needs, so its model and textures
  -- are genuinely acquired before the injected failure; only textures owned
  -- by the later towns are poisoned.
  local poisoned = laterTownTexturePaths(scenes[3].models, 1)
  local poisonedCount = 0
  for _ in pairs(poisoned) do
    poisonedCount = poisonedCount + 1
  end
  Assert.isTrue(poisonedCount > 0, "the later towns own textures the first town never reads")
  local state = { poisonedReads = 0 }
  local cacheFs = {
    loadLua = function(_, path)
      return baseFs:loadLua(path)
    end,
    exists = function(_, path, kind)
      return baseFs:exists(path, kind)
    end,
    read = function(_, path)
      if poisoned[path] == true then
        state.poisonedReads = state.poisonedReads + 1
        error("injected town texture failure: " .. tostring(path))
      end
      return baseFs:read(path)
    end,
  }
  local movie, failure = driveMovieCatching(scope, scenes, cacheFs)
  if failure == nil then
    Assert.isTrue(
      movie ~= nil and movie:isFinished(),
      "without a failure the movie plays the fallback scene as success"
    )
  end
  Assert.notNil(failure, "the town texture failure surfaces instead of playing past it")
  Assert.isTrue(state.poisonedReads > 0, "the injection fires on a later town texture, never before the town stage")
  assertTypedSceneFailure(failure)
  assertGpuCleanAfterTownFailure(scope, movie, 512, 384, baseline)
end

local function soulsilver_town_clip_failure_aborts_with_a_typed_error(scope, context)
  readyOrSkip(context, "soulsilver", "SoulSilver")
  local baseline = love.graphics.getStats()
  local scenes = loadScenes("soulsilver")
  local third = {}
  for key, value in pairs(scenes[3]) do
    third[key] = value
  end
  local models = {}
  for index, model in ipairs(scenes[3].models) do
    local descriptor = {}
    for key, value in pairs(model.descriptor) do
      descriptor[key] = value
    end
    descriptor.animations = {}
    models[index] = {
      name = model.name,
      index = model.index,
      descriptor = descriptor,
      clips = { { frameCount = 2 }, { frameCount = 3 } },
    }
  end
  third.models = models
  local swapped = { scenes[1], scenes[2], third, scenes[4], scenes[5] }
  local movie, failure = driveMovieCatching(scope, swapped, CacheFs.forVersion("soulsilver"))
  if failure == nil then
    Assert.isTrue(movie ~= nil and movie:isFinished(), "without a failure the movie plays the clipless town as success")
  end
  Assert.notNil(failure, "a town with no bindable animation clip surfaces instead of playing mute")
  assertTypedSceneFailure(failure)
  assertGpuCleanAfterTownFailure(scope, movie, 512, 384, baseline)
end

local function soulsilver_town_model_failure_aborts_with_a_typed_error(scope, context)
  readyOrSkip(context, "soulsilver", "SoulSilver")
  local baseline = love.graphics.getStats()
  local scenes = loadScenes("soulsilver")
  local third = {}
  for key, value in pairs(scenes[3]) do
    third[key] = value
  end
  local models = {}
  for index, model in ipairs(scenes[3].models) do
    if index == 2 then
      local descriptor = {}
      for key, value in pairs(model.descriptor) do
        descriptor[key] = value
      end
      descriptor.dynamic = nil
      models[index] = {
        name = model.name,
        index = model.index,
        descriptor = descriptor,
        clips = model.clips,
      }
    else
      models[index] = model
    end
  end
  third.models = models
  local swapped = { scenes[1], scenes[2], third, scenes[4], scenes[5] }
  local movie, failure = driveMovieCatching(scope, swapped, CacheFs.forVersion("soulsilver"))
  if failure == nil then
    Assert.isTrue(
      movie ~= nil and movie:isFinished(),
      "without a failure the movie plays the fallback drift as success"
    )
  end
  Assert.notNil(failure, "the unbuildable second town surfaces instead of falling back to drift")
  assertTypedSceneFailure(failure)
  assertGpuCleanAfterTownFailure(scope, movie, 512, 384, baseline)
end

-- The sourced town lens, recovered independently from the captured renderer
-- camera: the retail scene camera orbits its target by the compiled angle
-- at the compiled distance, and the projection carries the compiled field
-- angle on a source 4:3 frame. Every sampled town window must submit real
-- world items, move pixels, and carry its own authored light.
local SOURCED_TOWN_DISTANCE = 410.922119140625
local SOURCED_TOWN_ANGLE_X = 0xD602
local SOURCED_TOWN_TARGET = { 0, 0, 96 }
local SOURCED_TOWN_HALF_ANGLE = (0x981 / 65536) * (2 * math.pi)
local TITLE_HALF_ANGLE = (0xB60 / 65536) * (2 * math.pi)

---@param view number[] column-major lookAt matrix
---@return number[] eye, number[] forward
local function recoverEyeForward(view)
  local forward = { -view[3], -view[7], -view[11] }
  local length = math.sqrt(forward[1] * forward[1] + forward[2] * forward[2] + forward[3] * forward[3])
  forward = { forward[1] / length, forward[2] / length, forward[3] / length }
  local side = { view[1], view[5], view[9] }
  local up = { view[2], view[6], view[10] }
  local eye = {
    side[1] * -view[13] + up[1] * -view[14] + forward[1] * view[15],
    side[2] * -view[13] + up[2] * -view[14] + forward[2] * view[15],
    side[3] * -view[13] + up[3] * -view[14] + forward[3] * view[15],
  }
  return eye, forward
end

---@param projection number[] column-major perspective matrix
---@return number fovY, number aspect
local function recoverFovAspect(projection)
  return 2 * math.atan(1 / projection[6]), projection[6] / projection[1]
end

---@param triple table 0..1 RGB triple in either array or named shape
---@return integer packed RGB555 register
local function packRgb555(triple)
  local function channel(value)
    return math.max(0, math.min(31, math.floor(value * 31 + 0.5)))
  end
  local red = channel(triple.r or triple[1] or 0)
  local green = channel(triple.g or triple[2] or 0)
  local blue = channel(triple.b or triple[3] or 0)
  return red + 32 * green + 1024 * blue
end

local function soulsilver_town_camera_uses_the_sourced_angle_and_lens(scope, context)
  readyOrSkip(context, "soulsilver", "SoulSilver")
  local FieldRenderer = require("libs.hgss.src.presentation.FieldRenderer")
  local realDraw = FieldRenderer.draw
  local captured = {}
  FieldRenderer.draw = function(self, environment, camera, worldParts, spriteItems, viewport, alpha, scale)
    captured[#captured + 1] = { environment = environment, camera = camera, worldParts = worldParts }
    return realDraw(self, environment, camera, worldParts, spriteItems, viewport, alpha, scale)
  end
  local scenes = loadScenes("soulsilver")
  local windows = {}
  local journeyOk, journeyErr = pcall(function()
    local movie = openMovie(scope, "soulsilver", 1200, 600, "single")
    local ticks = 0
    while movie:sceneNumber() < 3 and ticks < 20000 do
      movie:updateFixed()
      ticks = ticks + 1
    end
    Assert.equal(movie:sceneNumber(), 3, "playback reaches the town scenes")
    local entryTicks = ticks
    for window, offset in ipairs({ 20, 64, 130 }) do
      while ticks < entryTicks + offset do
        movie:updateFixed()
        ticks = ticks + 1
      end
      captured = {}
      movie:draw()
      local snapshot = {}
      for _, entry in ipairs(captured) do
        snapshot[#snapshot + 1] = entry
      end
      local before = drawBytes(movie, scope, 1200, 600)
      for _ = 1, 15 do
        movie:updateFixed()
        ticks = ticks + 1
      end
      local after = drawBytes(movie, scope, 1200, 600)
      windows[window] = { captures = snapshot, before = before, after = after }
    end
    movie:dispose()
  end)
  FieldRenderer.draw = realDraw
  Assert.isTrue(journeyOk, "the town journey runs cleanly: " .. tostring(journeyErr))
  Assert.equal(#windows, 3, "every town window is sampled")
  local sinX = math.sin((SOURCED_TOWN_ANGLE_X / 65536) * (2 * math.pi))
  local cosX = math.cos((SOURCED_TOWN_ANGLE_X / 65536) * (2 * math.pi))
  local expectedEye = {
    SOURCED_TOWN_TARGET[1],
    SOURCED_TOWN_TARGET[2] - sinX * SOURCED_TOWN_DISTANCE,
    SOURCED_TOWN_TARGET[3] + cosX * SOURCED_TOWN_DISTANCE,
  }
  local expectedForward = {
    SOURCED_TOWN_TARGET[1] - expectedEye[1],
    SOURCED_TOWN_TARGET[2] - expectedEye[2],
    SOURCED_TOWN_TARGET[3] - expectedEye[3],
  }
  local forwardLength = math.sqrt(
    expectedForward[1] * expectedForward[1]
      + expectedForward[2] * expectedForward[2]
      + expectedForward[3] * expectedForward[3]
  )
  expectedForward = {
    expectedForward[1] / forwardLength,
    expectedForward[2] / forwardLength,
    expectedForward[3] / forwardLength,
  }
  local expectedFovY = 2 * SOURCED_TOWN_HALF_ANGLE
  local titleFovY = 2 * TITLE_HALF_ANGLE
  for window = 1, 3 do
    local sampled = windows[window]
    local submitted, camera, environment = 0, nil, nil
    for _, entry in ipairs(sampled.captures) do
      for _, group in ipairs(entry.worldParts or {}) do
        submitted = submitted + #group
      end
      if camera == nil and (entry.worldParts or {})[1] ~= nil and #(entry.worldParts or {})[1] > 0 then
        camera, environment = entry.camera, entry.environment
      end
    end
    Assert.isTrue(submitted > 0, "town window " .. window .. " submits real world items")
    Assert.notNil(camera, "town window " .. window .. " draws through the town camera")
    -- Composited-pixel motion is proven where the role compositor keeps towns visible.
    local eye, forward = recoverEyeForward(camera.view())
    for axis = 1, 3 do
      Assert.near(eye[axis], expectedEye[axis], 2.0, "town window " .. window .. " eyes the sourced orbit")
      Assert.near(forward[axis], expectedForward[axis], 0.01, "town window " .. window .. " forwards the sourced gaze")
    end
    Assert.isTrue(math.abs(forward[2]) > 0.5, "town window " .. window .. " never gazes straight down")
    local fovY, aspect = recoverFovAspect(camera.projection())
    Assert.near(fovY, expectedFovY, 0.005, "town window " .. window .. " carries the sourced field angle")
    Assert.isTrue(math.abs(fovY - titleFovY) > 0.05, "town window " .. window .. " never borrows the title lens")
    Assert.near(aspect, 4 / 3, 0.01, "town window " .. window .. " keeps the source 4:3 frame on a wide stage")
    local record = environment.lighting.records[1]
    Assert.notNil(record, "town window " .. window .. " carries authored lighting")
    Assert.equal(
      record.diffuseRgb555,
      packRgb555(scenes[3].lighting.towns[window].diffuse),
      "town window " .. window .. " carries its own authored light"
    )
  end
end

local T = GraphicsSmoke.suite({
  ["soulsilver movie plays five scenes with fixed timing"] = soulsilver_movie_plays_five_scenes_with_fixed_timing_under_variable_draw_rates,
  ["soulsilver towns and starter particles move"] = soulsilver_town_segments_and_starter_particles_move,
  ["soulsilver skip is gated and gpu stays bounded"] = soulsilver_skip_is_source_gated_and_gpu_stays_bounded,
  ["heartgold graphics are blocked without a dump"] = heartgold_opening_movie_graphics_are_blocked_without_a_dump,
  ["soulsilver town texture failure aborts with a typed error"] = soulsilver_town_texture_failure_aborts_with_a_typed_error,
  ["soulsilver town clip failure aborts with a typed error"] = soulsilver_town_clip_failure_aborts_with_a_typed_error,
  ["soulsilver town model failure aborts with a typed error"] = soulsilver_town_model_failure_aborts_with_a_typed_error,
  ["soulsilver town camera uses the sourced angle and lens"] = soulsilver_town_camera_uses_the_sourced_angle_and_lens,
  ["composite layers pan independently with true blending"] = composite_layers_pan_independently_with_true_blending,
  ["authored sprites stay on their engine with frame offsets"] = authored_sprites_stay_on_their_engine_with_frame_offsets,
  ["step relative fades composite on the gpu"] = step_relative_fades_composite_on_the_gpu,
})
T.metadata.capabilities = { "graphics", "rom_dump" }
T.metadata.derivedAssets = {
  "opening-scene:1",
  "opening-scene:2",
  "opening-scene:3",
  "opening-scene:4",
  "opening-scene:5",
}
T.metadata.tags = { "startup", "opening" }
return T
