-- Source-backed opening movie graphics: the compiled scenes from the selected
-- user-owned edition play in order with real town and particle motion at fixed
-- source timing, the skip gate finishes only the movie, and GPU resources are
-- released. HeartGold coverage stays blocked: no HeartGold dump is available
-- here, so its dedicated scenario skips instead of running against faked art;
-- every other real-source scenario runs against whichever edition is ready.

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

-- Samples one device pixel out of a captured RGBA frame. Defined early
-- because the engine-target probes below sample through it.
---@param bytes string raw RGBA frame bytes
---@param width integer device frame width
---@param x integer device pixel column
---@param y integer device pixel row
---@return number r, number g, number b in 0..1
local function pixelOf(bytes, width, x, y)
  local base = (y * width + x) * 4 + 1
  local r, g, b = string.byte(bytes, base, base + 2)
  return r / 255, g / 255, b / 255
end

-- The opening cinema runs against whichever user-owned edition the runner
-- selected: SoulSilver here, HeartGold where that dump is ready. Beats are
-- addressed by scene/step identity, so one scenario covers either edition;
-- a missing dump skips instead of faking the other game's art.
---@param context table runner context owning skip
---@return string selected edition identity
local function selectedVersionId(context)
  if RomImporter.isReady("soulsilver") then
    return "soulsilver"
  end
  if RomImporter.isReady("heartgold") then
    return "heartgold"
  end
  context:skip("no user-owned HeartGold or SoulSilver dump is ready")
  error("unreachable selected edition", 0)
end

-- Reads one fixed 256x192 source engine target after a draw. The caller
-- draws first so the canvases carry the current source tick; reading never
-- advances the movie clock.
---@param scope table test scope owning the readback
---@param canvas love.Canvas fixed source engine target
---@return string raw RGBA bytes of the engine target
local function sourceBytes(scope, canvas)
  local imageData = scope:own(canvas:newImageData())
  return imageData:getString()
end

-- Names the source step the movie currently plays, so beats are addressed
-- by authored identity instead of hardcoded tick counts.
---@param movie table running opening movie
---@return string current source step identity
local function currentStepId(movie)
  local slot = assert(movie.current, "the running movie owns its current slot")
  local timeline = assert(slot.manifest.timeline, "the current scene carries its timeline")
  local step = assert(timeline.steps[slot.stepIndex], "the movie stays on a known source step")
  return assert(step.id, "the current step carries its source identity")
end

-- Ticks the movie until it plays the named step of the named scene.
---@param movie table running opening movie
---@param sceneNumber integer retail scene position
---@param stepId string authored step identity
---@param budget integer maximum fixed ticks to spend seeking
local function advanceToSceneStep(movie, sceneNumber, stepId, budget)
  local elapsed = 0
  while elapsed < budget and not movie:isFinished() do
    if movie:sceneNumber() == sceneNumber and currentStepId(movie) == stepId then
      return
    end
    movie:updateFixed()
    elapsed = elapsed + 1
  end
  Assert.equal(movie:sceneNumber(), sceneNumber, "playback reaches scene " .. sceneNumber .. " step " .. stepId)
  Assert.equal(currentStepId(movie), stepId, "playback reaches scene " .. sceneNumber .. " step " .. stepId)
end

---@param r1 number
---@param g1 number
---@param b1 number
---@param r2 number
---@param g2 number
---@param b2 number
---@return number summed per-channel distance in 0..3
local function colorDistance(r1, g1, b1, r2, g2, b2)
  return math.abs(r1 - r2) + math.abs(g1 - g2) + math.abs(b1 - b2)
end

-- A host region shows the mapped engine when its center color is clearly
-- nearer the mapped source target than the other engine's target.
---@param r number
---@param g number
---@param b number sampled host region color
---@param mr number
---@param mg number
---@param mb number mapped engine target color
---@param or_ number
---@param og number
---@param ob number other engine target color
---@param message string assertion context
local function assertPaneShowsEngine(r, g, b, mr, mg, mb, or_, og, ob, message)
  local mapped = colorDistance(r, g, b, mr, mg, mb)
  local other = colorDistance(r, g, b, or_, og, ob)
  Assert.isTrue(
    mapped + 0.2 < other,
    message .. (" (mapped %.3f vs other %.3f)"):format(mapped, other)
  )
end

-- Fraction of coarsely sampled pixels that change between two frames.
---@param before string raw RGBA bytes of the earlier frame
---@param after string raw RGBA bytes of the later frame
---@param width integer frame width
---@param height integer frame height
---@return number changed fraction in 0..1
-- Majority color of an arbitrary device rectangle on a coarse grid: solid
-- authored art resolves exactly, so a region owned by one engine reports it.
---@param bytes string raw RGBA frame bytes
---@param width integer device frame width
---@param x0 integer first device column in the region
---@param x1 integer last device column in the region
---@param y0 integer first device row in the region
---@param y1 integer last device row in the region
---@return number r, number g, number b region majority color in 0..1
local function rectMajority(bytes, width, x0, x1, y0, y1)
  local buckets = {}
  local order = {}
  for y = y0, y1, 8 do
    for x = x0, x1, 8 do
      local r, g, b = pixelOf(bytes, width, x, y)
      local key = string.format("%d:%d:%d", math.floor(r * 4 + 0.5), math.floor(g * 4 + 0.5), math.floor(b * 4 + 0.5))
      local entry = buckets[key]
      if entry == nil then
        entry = { count = 0, r = r, g = g, b = b }
        buckets[key] = entry
        order[#order + 1] = key
      end
      entry.count = entry.count + 1
    end
  end
  local best = nil
  for _, key in ipairs(order) do
    if best == nil or buckets[key].count > buckets[best].count then
      best = key
    end
  end
  return buckets[best].r, buckets[best].g, buckets[best].b
end

-- Majority color of a small window around a mapped engine point. Object
-- beats (town, starters) occupy only part of their 256x192 target, so
-- probes sample the authored point instead of averaging whole frames.
-- Every blit centers its source canvas, so an engine point maps to the
-- pane center on every host layout.
---@param bytes string raw RGBA frame bytes
---@param width integer frame width
---@param cx integer mapped point column
---@param cy integer mapped point row
---@return number r, number g, number b point majority color in 0..1
local function pointMajority(bytes, width, cx, cy)
  return rectMajority(bytes, width, math.max(cx - 10, 0), cx + 10, math.max(cy - 10, 0), cy + 10)
end

-- Fraction of lit device pixels in a rectangle on a coarse grid.
---@param bytes string raw RGBA frame bytes
---@param width integer device frame width
---@param x0 integer first device column in the region
---@param x1 integer last device column in the region
---@param y0 integer first device row in the region
---@param y1 integer last device row in the region
---@return number lit fraction in 0..1
local function regionLit(bytes, width, x0, x1, y0, y1)
  local lit, total = 0, 0
  for y = y0, y1, 4 do
    for x = x0, x1, 4 do
      total = total + 1
      local r, g, b = pixelOf(bytes, width, x, y)
      if r + g + b > 0.05 then
        lit = lit + 1
      end
    end
  end
  return lit / total
end

local function changeFraction(before, after, width, height)
  local changed, total = 0, 0
  for y = 0, height - 1, 4 do
    for x = 0, width - 1, 4 do
      total = total + 1
      local r1, g1, b1 = pixelOf(before, width, x, y)
      local r2, g2, b2 = pixelOf(after, width, x, y)
      if math.abs(r1 - r2) + math.abs(g1 - g2) + math.abs(b1 - b2) > 0.05 then
        changed = changed + 1
      end
    end
  end
  return changed / total
end

-- Fraction of coarsely sampled pixels that change between two frames
-- inside one vertical half of the frame.
---@param before string raw RGBA bytes of the earlier frame
---@param after string raw RGBA bytes of the later frame
---@param width integer frame width
---@param height integer frame height
---@param left boolean true for the left half, false for the right half
---@return number changed fraction in 0..1
local function halfChangeFraction(before, after, width, height, left)
  local half = math.floor(width / 2)
  local x0, x1 = 0, half - 1
  if not left then
    x0, x1 = half, width - 1
  end
  local changed, total = 0, 0
  for y = 0, height - 1, 4 do
    for x = x0, x1, 4 do
      total = total + 1
      local r1, g1, b1 = pixelOf(before, width, x, y)
      local r2, g2, b2 = pixelOf(after, width, x, y)
      if math.abs(r1 - r2) + math.abs(g1 - g2) + math.abs(b1 - b2) > 0.05 then
        changed = changed + 1
      end
    end
  end
  return changed / total
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
---@param initialVisible boolean|nil source plane enable state, defaults to visible
---@param priority integer|nil source priority, defaults to the slot
---@return table generated engine layer record
local function compositeLayer(bgSlot, path, width, height, initialVisible, priority)
  return {
    bgSlot = bgSlot,
    priority = priority == nil and bgSlot or priority,
    image = path,
    variants = {},
    width = width,
    height = height,
    sourceHash = string.rep("c", 40),
    initialVisible = initialVisible ~= false,
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
        assets[alternate.image or alternate] = true
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
  local events = {
    { op = "waitTicks", stepId = "fill", atStepTick = 0, ticks = 10 },
    { op = "finish", stepId = "fill", atStepTick = 0 },
  }
  local eventIndexes = { 1, 2 }
  if sceneNumber == 1 then
    events[2] = { op = "enableSkip", stepId = "fill", atStepTick = 5 }
    events[3] = { op = "finish", stepId = "fill", atStepTick = 0 }
    eventIndexes = { 1, 2, 3 }
  end
  return compositeScene(
    sceneNumber,
    { compositeLayer(0, root .. "layers/fill-upper.png", 256, 192) },
    { compositeLayer(0, root .. "layers/fill-lower.png", 256, 192) },
    {},
    { seed = 0, emitters = emitters, textures = textures },
    { { id = "fill", events = eventIndexes, ["until"] = { kind = "duration", ticks = 10 } } },
    events
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
  -- Back-to-front band order is authored priority, not slot order: the
  -- fullscreen bottom paints first (priority 2) so the panned middle and
  -- top uncover it past their shifted extents.
  -- Every layer claims a valid source extent; the pans below reproduce
  -- the authored offsets on full-size art.
  local layers = {
    compositeLayer(0, bottomImage, 256, 192, true, 2),
    compositeLayer(1, middleImage, 256, 192, true, 1),
    compositeLayer(2, topImage, 256, 192, true, 0),
  }
  local lower = { compositeLayer(0, groundImage, 256, 192) }
  local art = {
    [bottomImage] = solidPng(256, 192, 255, 0, 0),
    [middleImage] = solidPng(256, 192, 0, 255, 0),
    [topImage] = solidPng(256, 192, 0, 0, 255),
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
  -- Both pans are exact multiples of the 256-wide native extent, so the
  -- wrapped viewports resample the origin: the frontmost solid still
  -- covers every pixel with no gaps and no uncovered strips, while the
  -- slot offsets below prove each layer panned its own full displacement.
  local slot = assert(pan.current, "the running movie owns its current slot")
  Assert.equal(slot.backgrounds.main[2].scrollX, -1024, "the top layer lands exactly on its full displacement")
  Assert.equal(slot.backgrounds.main[1].scrollX, -512, "the middle layer pans at its own authored displacement")
  for _, x in ipairs({ 480, 440, 8 }) do
    local br, bg, bb = samplePixel(scope, pan, 512, 384, x, 96)
    Assert.near(bb, 1, 0.03, "the settled top band stays blue at column " .. x)
    Assert.near(br, 0, 0.03, "no bottom red leaks through at column " .. x)
    Assert.near(bg, 0, 0.03, "no middle green leaks through at column " .. x)
  end
  local blendScenes, blendCache = compositePack(
    compositeScene(
      1,
      layers,
      lower,
      {},
      { seed = 0, emitters = {} },
      { { id = "hold", events = { 1, 2, 3, 4 }, ["until"] = { kind = "duration", ticks = 30 } } },
      {
        {
          op = "setBlend",
          stepId = "hold",
          atStepTick = 0,
          engine = "main",
          firstMask = 4,
          secondMask = 2,
          direction = 0,
          effect = "crossfade",
          ticks = 20,
        },
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

-- Four-quadrant chart: wrap sampling must rearrange the quadrants
-- instead of shifting one copy and uncovering cleared strips.
---@param size integer chart edge in pixels
---@param topLeft integer[] RGB corner colors
---@param topRight integer[] RGB corner colors
---@param bottomLeft integer[] RGB corner colors
---@param bottomRight integer[] RGB corner colors
---@return string png bytes of the opaque quadrant chart
local function quadrantPng(size, topLeft, topRight, bottomLeft, bottomRight)
  local half = math.floor(size / 2)
  local rows = {}
  for y = 0, size - 1 do
    local cells = {}
    for x = 0, size - 1 do
      local corner
      if y < half then
        corner = (x < half) and topLeft or topRight
      else
        corner = (x < half) and bottomLeft or bottomRight
      end
      cells[#cells + 1] = string.char(corner[1], corner[2], corner[3], 255)
    end
    rows[#rows + 1] = table.concat(cells)
  end
  return PngWriter.encode(size, size, table.concat(rows))
end

---@param width integer chart width in pixels
---@param height integer chart height in pixels
---@param left integer[] RGB left-half color
---@param right integer[] RGB right-half color
---@return string png bytes of the opaque two-band chart
local function halvesPng(width, height, left, right)
  local half = math.floor(width / 2)
  local rows = {}
  for _ = 1, height do
    local cells = {}
    for x = 0, width - 1 do
      local band = (x < half) and left or right
      cells[#cells + 1] = string.char(band[1], band[2], band[3], 255)
    end
    rows[#rows + 1] = table.concat(cells)
  end
  return PngWriter.encode(width, height, table.concat(rows))
end

local function native_viewports_wrap_across_source_extents(scope)
  local root = sceneArtRoot(1)
  local baseImage = root .. "layers/chart-base.png"
  local groundImage = root .. "layers/chart-ground.png"
  local gray16 = solidPng(16, 16, 128, 128, 128)
  local art = {
    [baseImage] = quadrantPng(512, { 255, 0, 0 }, { 0, 255, 0 }, { 0, 0, 255 }, { 255, 255, 0 }),
    [groundImage] = solidPng(256, 192, 40, 40, 40),
  }
  local scenes, cacheFs = compositePack(
    compositeScene(
      1,
      {
        {
          bgSlot = 0,
          priority = 0,
          image = baseImage,
          variants = {},
          width = 512,
          height = 512,
          sourceHash = string.rep("c", 40),
          initialVisible = true,
        },
      },
      { compositeLayer(0, groundImage, 256, 192) },
      {},
      { seed = 0, emitters = {} },
      { { id = "show", events = { 1, 2, 3, 4 }, ["until"] = { kind = "duration", ticks = 40 } } },
      {
        {
          op = "setScroll",
          stepId = "show",
          atStepTick = 0,
          engine = "main",
          bgSlot = 0,
          dx = 384,
          dy = 400,
          ticks = 0,
        },
        { op = "enableSkip", stepId = "show", atStepTick = 10 },
        { op = "waitTicks", stepId = "show", atStepTick = 0, ticks = 40 },
        { op = "finish", stepId = "show", atStepTick = 40 },
      }
    ),
    art,
    gray16
  )
  local movie = openCompositeMovie(scope, scenes, cacheFs, 512, 384, "dual")
  advance(movie, 5)
  movie:draw()
  -- An offset of (384, 400) on the 512 chart samples each engine pixel
  -- from ((x + 384) % 512, (y + 400) % 512): the viewport straddles both
  -- wrap seams, so every quadrant shows exactly once.
  local base = sourceBytes(scope, movie.mainCanvas)
  local yr, yg, yb = pixelOf(base, 256, 8, 8)
  Assert.near(yr, 1, 0.06, "the wrapped top-left viewport pixel is bottom-right yellow")
  Assert.near(yg, 1, 0.06, "the wrapped top-left viewport pixel is bottom-right yellow")
  Assert.near(yb, 0, 0.06, "the wrapped top-left viewport pixel is bottom-right yellow")
  local br, bg, bb = pixelOf(base, 256, 200, 8)
  Assert.near(br, 0, 0.06, "the wrapped top-right viewport pixel is bottom-left blue")
  Assert.near(bg, 0, 0.06, "the wrapped top-right viewport pixel is bottom-left blue")
  Assert.near(bb, 1, 0.06, "the wrapped top-right viewport pixel is bottom-left blue")
  local gr, gg, gb = pixelOf(base, 256, 8, 180)
  Assert.near(gr, 0, 0.06, "the wrapped bottom-left viewport pixel is top-right green")
  Assert.near(gg, 1, 0.06, "the wrapped bottom-left viewport pixel is top-right green")
  Assert.near(gb, 0, 0.06, "the wrapped bottom-left viewport pixel is top-right green")
  local rr, rg, rb = pixelOf(base, 256, 200, 180)
  Assert.near(rr, 1, 0.06, "the wrapped bottom-right viewport pixel is top-left red")
  Assert.near(rg, 0, 0.06, "the wrapped bottom-right viewport pixel is top-left red")
  Assert.near(rb, 0, 0.06, "the wrapped bottom-right viewport pixel is top-left red")
  movie:dispose()
end

local function swapped_viewports_follow_the_active_image_extents(scope)
  local root = sceneArtRoot(1)
  local baseImage = root .. "layers/swap-base.png"
  local altImage = root .. "layers/swap-alt.png"
  local groundImage = root .. "layers/swap-ground.png"
  local gray16 = solidPng(16, 16, 128, 128, 128)
  local art = {
    [baseImage] = solidPng(512, 512, 255, 0, 0),
    [altImage] = halvesPng(256, 192, { 255, 0, 255 }, { 0, 255, 255 }),
    [groundImage] = solidPng(256, 192, 40, 40, 40),
  }
  local scenes, cacheFs = compositePack(
    compositeScene(
      1,
      {
        {
          bgSlot = 0,
          priority = 0,
          image = baseImage,
          variants = { { image = altImage, width = 256, height = 192 } },
          width = 512,
          height = 512,
          sourceHash = string.rep("c", 40),
          initialVisible = true,
        },
      },
      { compositeLayer(0, groundImage, 256, 192) },
      {},
      { seed = 0, emitters = {} },
      { { id = "show", events = { 1, 2, 3, 4, 5 }, ["until"] = { kind = "duration", ticks = 40 } } },
      {
        {
          op = "setScroll",
          stepId = "show",
          atStepTick = 0,
          engine = "main",
          bgSlot = 0,
          dx = 384,
          dy = 400,
          ticks = 0,
        },
        { op = "enableSkip", stepId = "show", atStepTick = 10 },
        {
          op = "setLayer",
          stepId = "show",
          atStepTick = 20,
          engine = "main",
          bgSlot = 0,
          image = altImage,
          visible = true,
          priority = 0,
        },
        { op = "waitTicks", stepId = "show", atStepTick = 0, ticks = 40 },
        { op = "finish", stepId = "show", atStepTick = 40 },
      }
    ),
    art,
    gray16
  )
  local movie = openCompositeMovie(scope, scenes, cacheFs, 512, 384, "dual")
  for _ = 1, 25 do
    movie:updateFixed()
  end
  movie:draw()
  -- Past the swap the same offsets sample the smaller alternate extents:
  -- ((x + 384) % 256, (y + 400) % 192) lands on the alternate bands.
  local swapped = sourceBytes(scope, movie.mainCanvas)
  local cr, cg, cb = pixelOf(swapped, 256, 0, 0)
  Assert.near(cr, 0, 0.06, "the swapped viewport origin samples the alternate right band")
  Assert.near(cg, 1, 0.06, "the swapped viewport origin samples the alternate right band")
  Assert.near(cb, 1, 0.06, "the swapped viewport origin samples the alternate right band")
  local pr, pg, pb = pixelOf(swapped, 256, 200, 100)
  Assert.near(pr, 1, 0.06, "the swapped viewport samples the alternate left band past its seam")
  Assert.near(pg, 0, 0.06, "the swapped viewport samples the alternate left band past its seam")
  Assert.near(pb, 1, 0.06, "the swapped viewport samples the alternate left band past its seam")
  movie:dispose()
end

-- A strict town-free filler scene that acquires no models or particles,
-- so sourced scroll legs can play through its position without depending
-- on town acquisition.
---@param versionId string selected edition identity
---@param generationId string project generation shared by the pack
---@param sceneNumber integer retail scene position of the filler
---@param art table<string, string> staged png bytes by generated path
---@return table strict synthetic opening-scene manifest
local function fillerRomScene(versionId, generationId, sceneNumber, art)
  local root = sceneArtRoot(sceneNumber)
  local upperImage = root .. "layers/fill-upper.png"
  local lowerImage = root .. "layers/fill-lower.png"
  art[upperImage] = solidPng(256, 192, 64, 64, 64)
  art[lowerImage] = solidPng(256, 192, 64, 64, 64)
  -- The fourth scene always carries its nine staged starter emitters, so
  -- the filler keeps them staged (but never starts them) exactly like the
  -- sourced scene it stands in for.
  local emitters, textures = {}, {}
  if sceneNumber == 4 then
    for id = 0, 8 do
      local group = id < 3 and "water" or (id < 6 and "fire" or "grass")
      local textureImage = root .. "particles/texture" .. id .. ".png"
      emitters[#emitters + 1] = fillerEmitter(id, group, root)
      textures[#textures + 1] = {
        id = id,
        format = 1,
        width = 16,
        height = 16,
        image = textureImage,
        sourceHash = string.rep("d", 40),
      }
      art[textureImage] = solidPng(16, 16, 128, 128, 128)
    end
  end
  local assets = { [upperImage] = true, [lowerImage] = true }
  for _, texture in ipairs(textures) do
    assets[texture.image] = true
  end
  return {
    schema = Contract.startupOpeningScene.schema,
    versionId = versionId,
    generationId = generationId,
    sceneNumber = sceneNumber,
    sourceTickRate = Contract.startupOpeningScene.tickRate,
    layers = {
      main = { compositeLayer(0, upperImage, 256, 192) },
      sub = { compositeLayer(0, lowerImage, 256, 192) },
    },
    spriteClips = {},
    models = {},
    particles = { seed = 0, emitters = emitters, textures = textures },
    timeline = {
      steps = { { id = "fill", events = { 1, 2 }, ["until"] = { kind = "duration", ticks = 10 } } },
      events = {
        { op = "waitTicks", stepId = "fill", atStepTick = 0, ticks = 10 },
        { op = "finish", stepId = "fill", atStepTick = 0 },
      },
    },
    assets = assets,
  }
end

-- Loads the sourced scenes for one edition, substituting town-free
-- fillers for the listed positions. Filler manifests pass the same strict
-- reader; every real scene still reads its own staged bytes.
---@param versionId string selected edition identity
---@param fillerIndexes integer[] retail scene positions to substitute
---@return table[] scenes, table cacheFs strict five-scene pack with staged art
local function loadRomPackWithFillers(versionId, fillerIndexes)
  local baseFs = CacheFs.forVersion(versionId)
  local probe = {}
  for sceneNumber = 1, 5 do
    local loaded, err = StartupAssetCache.loadOpeningScene(baseFs, sceneNumber, versionId)
    Assert.notNil(loaded, "scene " .. sceneNumber .. " reads back as a ready bundle: " .. tostring(err))
    probe[sceneNumber] = loaded
  end
  local fillerSet = {}
  for _, sceneNumber in ipairs(fillerIndexes) do
    fillerSet[sceneNumber] = true
  end
  local fillerArt = {}
  local fillerManifests = {}
  for _, sceneNumber in ipairs(fillerIndexes) do
    fillerManifests[sceneNumber] =
      fillerRomScene(versionId, probe[1].generationId, sceneNumber, fillerArt)
  end
  local cacheFs = {
    loadLua = function(_, path)
      for sceneNumber, manifest in pairs(fillerManifests) do
        if path == StartupAssetCache.openingScenePath(sceneNumber) then
          return manifest
        end
      end
      return baseFs:loadLua(path)
    end,
    exists = function(_, path, kind)
      if fillerArt[path] ~= nil then
        return true
      end
      return baseFs:exists(path, kind)
    end,
    read = function(_, path)
      if fillerArt[path] ~= nil then
        return fillerArt[path]
      end
      return baseFs:read(path)
    end,
  }
  local scenes = {}
  for sceneNumber = 1, 5 do
    local loaded, err = StartupAssetCache.loadOpeningScene(cacheFs, sceneNumber, versionId)
    Assert.notNil(loaded, "scene " .. sceneNumber .. " reads back as a ready bundle: " .. tostring(err))
    scenes[sceneNumber] = loaded
  end
  Assert.isFalse(fillerSet[1], "the opening scene is never substituted")
  Assert.isFalse(fillerSet[2], "the scene under test is never substituted")
  return scenes, cacheFs
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
  local versionId = selectedVersionId(context)
  local first = openMovie(scope, versionId, 512, 384, "single")
  local entries, _ = recordEntries(first, scope, 7)
  local second = openMovie(scope, versionId, 512, 384, "single")
  local secondEntries, _ = recordEntries(second, scope, 1)
  Assert.deepEqual(secondEntries, entries, "host draw cadence never changes source scene timing")
  local sampleTick = entries[2] + 10
  local function frameAt(ticks, withDraws)
    local probe = openMovie(scope, versionId, 512, 384, "single")
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
  local versionId = selectedVersionId(context)
  local movie = openMovie(scope, versionId, 512, 384, "single")
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
  local replay = openMovie(scope, versionId, 512, 384, "single")
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
  local versionId = selectedVersionId(context)
  local baseline = love.graphics.getStats()
  local movie = openMovie(scope, versionId, 512, 384, "single")
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
  local constructed, failure = pcall(openMovie, scope, versionId, 512, 384, "single")
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
---@param versionId string selected edition identity
---@return table? movie, unknown failure
local function driveMovieCatching(scope, scenes, cacheFs, versionId)
  local constructed, movieOrFailure =
    pcall(openMovieWithCache, scope, scenes, cacheFs, versionId, 512, 384, "single")
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
  local versionId = selectedVersionId(context)
  local baseline = love.graphics.getStats()
  local baseFs = CacheFs.forVersion(versionId)
  local scenes = loadScenes(versionId)
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
  local movie, failure = driveMovieCatching(scope, scenes, cacheFs, versionId)
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
  local versionId = selectedVersionId(context)
  local baseline = love.graphics.getStats()
  local scenes = loadScenes(versionId)
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
  local movie, failure = driveMovieCatching(scope, swapped, CacheFs.forVersion(versionId), versionId)
  if failure == nil then
    Assert.isTrue(movie ~= nil and movie:isFinished(), "without a failure the movie plays the clipless town as success")
  end
  Assert.notNil(failure, "a town with no bindable animation clip surfaces instead of playing mute")
  assertTypedSceneFailure(failure)
  assertGpuCleanAfterTownFailure(scope, movie, 512, 384, baseline)
end

local function soulsilver_town_model_failure_aborts_with_a_typed_error(scope, context)
  local versionId = selectedVersionId(context)
  local baseline = love.graphics.getStats()
  local scenes = loadScenes(versionId)
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
  local movie, failure = driveMovieCatching(scope, swapped, CacheFs.forVersion(versionId), versionId)
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
-- Staged camera facts arrive in model units; the runtime consumes tiles at
-- sixteen model units per tile, so sourced expectations convert the same way.
local MODEL_UNITS_PER_TILE = 16
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
  local versionId = selectedVersionId(context)
  local FieldRenderer = require("libs.hgss.src.presentation.FieldRenderer")
  local realDraw = FieldRenderer.draw
  local captured = {}
  FieldRenderer.draw = function(self, environment, camera, worldParts, spriteItems, viewport, alpha, scale)
    captured[#captured + 1] = { environment = environment, camera = camera, worldParts = worldParts }
    return realDraw(self, environment, camera, worldParts, spriteItems, viewport, alpha, scale)
  end
  local scenes = loadScenes(versionId)
  local windows = {}
  local journeyOk, journeyErr = pcall(function()
    local movie = openMovie(scope, versionId, 1200, 600, "single")
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
    SOURCED_TOWN_TARGET[1] / MODEL_UNITS_PER_TILE,
    (SOURCED_TOWN_TARGET[2] - sinX * SOURCED_TOWN_DISTANCE) / MODEL_UNITS_PER_TILE,
    (SOURCED_TOWN_TARGET[3] + cosX * SOURCED_TOWN_DISTANCE) / MODEL_UNITS_PER_TILE,
  }
  local expectedForward = {
    SOURCED_TOWN_TARGET[1] / MODEL_UNITS_PER_TILE - expectedEye[1],
    SOURCED_TOWN_TARGET[2] / MODEL_UNITS_PER_TILE - expectedEye[2],
    SOURCED_TOWN_TARGET[3] / MODEL_UNITS_PER_TILE - expectedEye[3],
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
      Assert.near(eye[axis], expectedEye[axis], 0.5, "town window " .. window .. " eyes the sourced orbit")
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

-- Asserts two device pixels carry the same color: one composed role paints
-- both spots, never two overlapping role passes.
---@param bytes string raw RGBA frame bytes
---@param width integer device frame width
---@param x1 integer first device pixel column
---@param y1 integer first device pixel row
---@param x2 integer second device pixel column
---@param y2 integer second device pixel row
---@param tolerance number per-channel tolerance in 0..1
---@param message string assertion context
local function assertSamePixel(bytes, width, x1, y1, x2, y2, tolerance, message)
  local r1, g1, b1 = pixelOf(bytes, width, x1, y1)
  local r2, g2, b2 = pixelOf(bytes, width, x2, y2)
  Assert.near(r1, r2, tolerance, message .. " (red channel)")
  Assert.near(g1, g2, tolerance, message .. " (green channel)")
  Assert.near(b1, b2, tolerance, message .. " (blue channel)")
end

-- Majority color of a horizontal device band on a coarse grid: solid role
-- art resolves exactly, so a band owned by one role reports that role.
---@param bytes string raw RGBA frame bytes
---@param width integer device frame width
---@param y0 integer first device row in the band
---@param y1 integer last device row in the band
---@return number r, number g, number b band majority color in 0..1
local function majorityColor(bytes, width, y0, y1)
  local buckets = {}
  local order = {}
  for y = y0, y1, 8 do
    for x = 0, width - 1, 8 do
      local r, g, b = pixelOf(bytes, width, x, y)
      local key = string.format("%d:%d:%d", math.floor(r * 4 + 0.5), math.floor(g * 4 + 0.5), math.floor(b * 4 + 0.5))
      local entry = buckets[key]
      if entry == nil then
        entry = { count = 0, r = r, g = g, b = b }
        buckets[key] = entry
        order[#order + 1] = key
      end
      entry.count = entry.count + 1
    end
  end
  local best = nil
  for _, key in ipairs(order) do
    if best == nil or buckets[key].count > buckets[best].count then
      best = key
    end
  end
  return buckets[best].r, buckets[best].g, buckets[best].b
end

-- Majority color of a vertical device band on a coarse grid: solid role
-- art resolves exactly, so a band owned by one role reports that role.
---@param bytes string raw RGBA frame bytes
---@param width integer device frame width
---@param height integer device frame height
---@param x0 integer first device column in the band
---@param x1 integer last device column in the band
---@return number r, number g, number b band majority color in 0..1
local function majorityColorColumns(bytes, width, height, x0, x1)
  local buckets = {}
  local order = {}
  for y = 0, height - 1, 8 do
    for x = x0, x1, 8 do
      local r, g, b = pixelOf(bytes, width, x, y)
      local key = string.format("%d:%d:%d", math.floor(r * 4 + 0.5), math.floor(g * 4 + 0.5), math.floor(b * 4 + 0.5))
      local entry = buckets[key]
      if entry == nil then
        entry = { count = 0, r = r, g = g, b = b }
        buckets[key] = entry
        order[#order + 1] = key
      end
      entry.count = entry.count + 1
    end
  end
  local best = nil
  for _, key in ipairs(order) do
    if best == nil or buckets[key].count > buckets[best].count then
      best = key
    end
  end
  return buckets[best].r, buckets[best].g, buckets[best].b
end

---@param r1 number
---@param g1 number
---@param b1 number
---@param r2 number
---@param g2 number
---@param b2 number
---@param tolerance number per-channel tolerance in 0..1
---@param message string assertion context
local function assertSameColor(r1, g1, b1, r2, g2, b2, tolerance, message)
  Assert.near(r1, r2, tolerance, message .. " (red channel)")
  Assert.near(g1, g2, tolerance, message .. " (green channel)")
  Assert.near(b1, b2, tolerance, message .. " (blue channel)")
end

-- Counts near-yellow device pixels (the hero sprite tint) on a coarse
-- grid, scaled back to full-frame Equivalent pixels.
---@param bytes string raw RGBA frame bytes
---@param width integer device frame width
---@param height integer device frame height
---@return integer full-frame equivalent yellow pixel count
local function countYellow(bytes, width, height)
  local count = 0
  for y = 0, height - 1, 2 do
    for x = 0, width - 1, 2 do
      local r, g, b = pixelOf(bytes, width, x, y)
      if r > 0.9 and g > 0.9 and b < 0.1 then
        count = count + 1
      end
    end
  end
  return count * 4
end

---@param custom table scene manifest under test
---@param customIndex integer retail position of the custom scene
---@param art table<string, string> staged png bytes by generated path
---@param defaultPng string fallback png bytes for art the test never samples
---@return table[] scenes, table cacheFs strict five-scene pack with one custom scene
local function customPack(custom, customIndex, art, defaultPng)
  local raw = {}
  for sceneNumber = 1, 5 do
    if sceneNumber == customIndex then
      raw[sceneNumber] = custom
    else
      raw[sceneNumber] = fillerScene(sceneNumber)
    end
  end
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
    Assert.notNil(loaded, "custom scene " .. sceneNumber .. " passes the strict scene reader: " .. tostring(err))
    scenes[sceneNumber] = loaded
  end
  return scenes, cacheFs
end

-- One single-beat scene: solid red on the main engine, solid blue on the
-- sub engine, no mapping flips. Whatever the composition policy selects
-- for this beat, the single-screen stage must show it without an
-- overlapping band of the other role.
---@return table scene manifest, table<string, string> staged art
local function singleBeatScene()
  local root = sceneArtRoot(1)
  local upperImage = root .. "layers/solid-upper.png"
  local lowerImage = root .. "layers/solid-lower.png"
  local scene = compositeScene(
    1,
    { compositeLayer(0, upperImage, 256, 192) },
    { compositeLayer(0, lowerImage, 256, 192) },
    {},
    { seed = 0, emitters = {} },
    { { id = "hold", events = { 1, 2, 3 }, ["until"] = { kind = "duration", ticks = 40 } } },
    {
      { op = "enableSkip", stepId = "hold", atStepTick = 10 },
      { op = "waitTicks", stepId = "hold", atStepTick = 0, ticks = 40 },
      { op = "finish", stepId = "hold", atStepTick = 40 },
    }
  )
  local art = {
    [upperImage] = solidPng(256, 192, 255, 0, 0),
    [lowerImage] = solidPng(256, 192, 0, 0, 255),
  }
  return scene, art
end

-- One paired scene with a mid-scene physical mapping flip and one hero
-- sprite on the main engine: both roles must stay visible on every
-- layout, the flip must move each engine output between physical roles,
-- and the sprite must paint exactly once.
---@return table scene manifest, table<string, string> staged art
local function pairedFlipScene()
  local root = sceneArtRoot(4)
  local upperImage = root .. "layers/pair-upper.png"
  local lowerImage = root .. "layers/pair-lower.png"
  local clipId = root .. "sprites/hero.g4sprite"
  local emitters = {}
  local textures = {}
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
  local scene = compositeScene(
    4,
    { compositeLayer(0, upperImage, 256, 192) },
    { compositeLayer(0, lowerImage, 256, 192) },
    { compositeClip(clipId, { compositeFrame(0, 0, 16, 16, 0, 0, 1) }) },
    { seed = 0, emitters = emitters, textures = textures },
    {
      { id = "intro", events = { 1, 2, 3, 4 }, ["until"] = { kind = "duration", ticks = 20 } },
      { id = "flip", events = { 5, 6, 7 }, ["until"] = { kind = "duration", ticks = 20 } },
    },
    {
      {
        op = "setSpriteClip",
        stepId = "intro",
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
        stepId = "intro",
        atStepTick = 0,
        instanceId = "hero",
        engine = "main",
        x = 32,
        y = 64,
        drawOrder = 1,
        visible = true,
      },
      { op = "setScreenMapping", stepId = "intro", atStepTick = 0, mainPhysical = "upper" },
      { op = "waitTicks", stepId = "intro", atStepTick = 0, ticks = 20 },
      { op = "setScreenMapping", stepId = "flip", atStepTick = 0, mainPhysical = "lower" },
      { op = "waitTicks", stepId = "flip", atStepTick = 0, ticks = 20 },
      { op = "finish", stepId = "flip", atStepTick = 20 },
    }
  )
  local art = {
    [upperImage] = solidPng(256, 192, 255, 0, 0),
    [lowerImage] = solidPng(256, 192, 0, 0, 255),
    [clipId] = solidPng(16, 16, 255, 255, 0),
  }
  return scene, art
end

local function a_single_active_source_screen_fills_the_whole_single_screen_stage(scope)
  local gray16 = solidPng(16, 16, 128, 128, 128)
  for _, layout in ipairs({
    { width = 512, height = 384, kind = "single" },
    { width = 1200, height = 600, kind = "single" },
  }) do
    local scene, art = singleBeatScene()
    local scenes, cacheFs = compositePack(scene, art, gray16)
    local movie = openCompositeMovie(scope, scenes, cacheFs, layout.width, layout.height, layout.kind)
    advance(movie, 5)
    local bytes = drawBytes(movie, scope, layout.width, layout.height)
    local where = layout.width .. "x" .. layout.height
    if layout.width == 512 then
      assertSamePixel(
        bytes,
        512,
        256,
        20,
        256,
        134,
        0.05,
        where .. ": the compact stage shows no band over the active screen"
      )
      assertSamePixel(
        bytes,
        512,
        256,
        250,
        256,
        364,
        0.05,
        where .. ": the compact stage keeps one composed role below the fold"
      )
    else
      assertSamePixel(bytes, 1200, 300, 20, 300, 580, 0.05, where .. ": the wide stage shows no overlay band")
      assertSamePixel(
        bytes,
        1200,
        300,
        210,
        300,
        390,
        0.05,
        where .. ": the wide stage keeps one composed role across its middle band"
      )
    end
    movie:dispose()
  end
end

local function paired_beats_and_flips_keep_both_source_screens_across_every_layout(scope)
  local gray16 = solidPng(16, 16, 128, 128, 128)
  local layouts = {
    { width = 512, height = 384, kind = "single" },
    { width = 1200, height = 600, kind = "single" },
    { width = 600, height = 1000, kind = "single" },
    { width = 512, height = 384, kind = "dual" },
  }
  for _, layout in ipairs(layouts) do
    local scene, art = pairedFlipScene()
    local scenes, cacheFs = customPack(scene, 4, art, gray16)
    local movie = openCompositeMovie(scope, scenes, cacheFs, layout.width, layout.height, layout.kind)
    local where = layout.width .. "x" .. layout.height .. layout.kind
    local guard = 0
    while movie:sceneNumber() < 4 and guard < 5000 do
      movie:updateFixed()
      guard = guard + 1
    end
    Assert.equal(movie:sceneNumber(), 4, where .. ": playback reaches the paired scene")
    advance(movie, 2)
    local before = drawBytes(movie, scope, layout.width, layout.height)
    advance(movie, 20)
    local after = drawBytes(movie, scope, layout.width, layout.height)
    local width, height = layout.width, layout.height
    -- The wide stage arranges the pair side by side, so its halves split
    -- left/right; compact, tall, and dual stages stack them top/bottom.
    -- Each half is sampled along the stacking axis it owns.
    local sideBySide = layout.kind == "single" and width == 1200
    if sideBySide then
      local row = math.floor(height / 2)
      local midLeft = math.floor(width * 0.3)
      local midRight = math.floor(width * 0.7)
      assertSamePixel(
        before,
        width,
        20,
        row,
        midLeft,
        row,
        0.05,
        where .. ": the paired beat shows no overlay band before the flip"
      )
      assertSamePixel(
        after,
        width,
        20,
        row,
        midLeft,
        row,
        0.05,
        where .. ": the paired beat shows no overlay band after the flip"
      )
      assertSamePixel(
        before,
        width,
        midRight,
        row,
        width - 20,
        row,
        0.05,
        where .. ": the paired beat shows no overlay band before the flip"
      )
      assertSamePixel(
        after,
        width,
        midRight,
        row,
        width - 20,
        row,
        0.05,
        where .. ": the paired beat shows no overlay band after the flip"
      )
    else
      local midTop = math.floor(height * 0.2)
      local botTop = math.floor(height * 0.7)
      assertSamePixel(
        before,
        width,
        math.floor(width / 2),
        20,
        math.floor(width / 2),
        midTop,
        0.05,
        where .. ": the upper physical screen keeps its own role"
      )
      assertSamePixel(
        before,
        width,
        math.floor(width / 2),
        botTop,
        math.floor(width / 2),
        height - 20,
        0.05,
        where .. ": the lower physical screen keeps its own role"
      )
    end
    local firstBeforeR, firstBeforeG, firstBeforeB
    local secondBeforeR, secondBeforeG, secondBeforeB
    local firstAfterR, firstAfterG, firstAfterB
    local secondAfterR, secondAfterG, secondAfterB
    if sideBySide then
      firstBeforeR, firstBeforeG, firstBeforeB =
        majorityColorColumns(before, width, height, 0, math.floor(width / 2) - 1)
      secondBeforeR, secondBeforeG, secondBeforeB =
        majorityColorColumns(before, width, height, math.floor(width / 2), width - 1)
      firstAfterR, firstAfterG, firstAfterB = majorityColorColumns(after, width, height, 0, math.floor(width / 2) - 1)
      secondAfterR, secondAfterG, secondAfterB =
        majorityColorColumns(after, width, height, math.floor(width / 2), width - 1)
    else
      firstBeforeR, firstBeforeG, firstBeforeB = majorityColor(before, width, 0, math.floor(height / 2) - 1)
      secondBeforeR, secondBeforeG, secondBeforeB = majorityColor(before, width, math.floor(height / 2), height - 1)
      firstAfterR, firstAfterG, firstAfterB = majorityColor(after, width, 0, math.floor(height / 2) - 1)
      secondAfterR, secondAfterG, secondAfterB = majorityColor(after, width, math.floor(height / 2), height - 1)
    end
    assertSameColor(
      firstBeforeR,
      firstBeforeG,
      firstBeforeB,
      secondAfterR,
      secondAfterG,
      secondAfterB,
      0.05,
      where .. ": the flip moves the upper visuals into the lower physical role"
    )
    assertSameColor(
      secondBeforeR,
      secondBeforeG,
      secondBeforeB,
      firstAfterR,
      firstAfterG,
      firstAfterB,
      0.05,
      where .. ": the flip moves the lower visuals into the upper physical role"
    )
    local yellow = countYellow(before, width, height)
    Assert.isTrue(yellow > 200, where .. ": the hero sprite paints its owning engine output")
    Assert.isTrue(yellow < 20000, where .. ": the hero sprite never smears across both roles")
    movie:dispose()
  end
end

local function movie_targets_stay_bounded_across_resizes_to_very_large_stages(scope)
  local gray16 = solidPng(16, 16, 128, 128, 128)
  local baseline = love.graphics.getStats()
  local realNewCanvas = love.graphics.newCanvas
  local calls = {}
  love.graphics.newCanvas = function(width, height, opts)
    calls[#calls + 1] = { width = width, height = height }
    return realNewCanvas(width, height, opts)
  end
  local scene, art = singleBeatScene()
  local constructed, movieOrFailure = pcall(function()
    local scenes, cacheFs = compositePack(scene, art, gray16)
    return openCompositeMovie(scope, scenes, cacheFs, 512, 384, "single")
  end)
  love.graphics.newCanvas = realNewCanvas
  Assert.isTrue(constructed, "construction allocates its role targets and returns")
  local movie = movieOrFailure
  for _, call in ipairs(calls) do
    Assert.equal(
      type(call.width),
      "number",
      "every canvas allocation passes numeric dimensions, never the graphics namespace"
    )
    Assert.equal(
      type(call.height),
      "number",
      "every canvas allocation passes numeric dimensions, never the graphics namespace"
    )
    Assert.isTrue(
      call.width <= 256 and call.height <= 192,
      "every canvas allocation stays within the 256x192 source frame"
    )
  end
  Assert.equal(#calls, 2, "construction allocates exactly two bounded role targets")
  local afterConstruction = love.graphics.getStats()
  Assert.equal(afterConstruction.canvases, baseline.canvases + 2, "construction retains two canvases")
  Assert.equal(movie:sceneNumber(), 1, "a preflighted movie still starts at the first scene")
  local resizeCalls = {}
  love.graphics.newCanvas = function(width, height, opts)
    resizeCalls[#resizeCalls + 1] = { width = width, height = height }
    return realNewCanvas(width, height, opts)
  end
  local resizeOk, resizeFailure = pcall(function()
    movie:resize(3840, 2160)
    movie:resize(7680, 4320)
    movie:resize(600, 1000)
    movie:resize(512, 384)
  end)
  love.graphics.newCanvas = realNewCanvas
  Assert.isTrue(resizeOk, "resizing across size classes never fails: " .. tostring(resizeFailure))
  Assert.equal(#resizeCalls, 0, "resizing allocates no host-sized targets")
  Assert.equal(movie:sceneNumber(), 1, "resizing across size classes never rewinds the movie clock")
  Assert.isFalse(movie:skipAllowed(), "resizing never advances the source timeline")
  movie:draw()
  local final = drawBytes(movie, scope, 512, 384)
  local blank = blankBytes(scope, 512, 384)
  Assert.isTrue(final ~= blank, "the resized movie still paints its composed stage")
  movie:dispose()
  local afterDispose = love.graphics.getStats()
  -- The two frame captures above stay owned by the test scope (released
  -- at teardown), so the movie is proven clean when only those two
  -- remain: any retained role target would read back as a third.
  Assert.equal(afterDispose.canvases, baseline.canvases + 2, "disposing the movie releases its role targets")
end

local function construction_fails_before_the_first_frame_unless_all_five_scenes_acquire(scope)
  local gray16 = solidPng(16, 16, 128, 128, 128)
  local poisoned = sceneArtRoot(5) .. "layers/fill-lower.png"
  local state = { poisonedReads = 0 }
  local healthyScenes, healthyFs = customPack(fillerScene(5), 5, {}, gray16)
  local _ = healthyScenes
  local cacheFs = {
    loadLua = function(_, path)
      return healthyFs:loadLua(path)
    end,
    exists = function()
      return true
    end,
    read = function(_, path)
      if path == poisoned then
        state.poisonedReads = state.poisonedReads + 1
        error("injected scene five art failure")
      end
      return healthyFs:read(path)
    end,
  }
  local baseline = love.graphics.getStats()
  local movie = nil
  local ok, failure = pcall(function()
    movie = openCompositeMovie(scope, healthyScenes, cacheFs, 512, 384, "single")
  end)
  if ok then
    movie:dispose()
  end
  Assert.isFalse(ok, "construction fails before the first frame unless all five scenes acquire")
  Assert.isTrue(state.poisonedReads > 0, "the fifth scene acquisition is attempted before return")
  Assert.equal(type(failure), "table", "a failed preflight raises a structured error, never a bare string")
  Assert.equal(failure.code, "HGSS_OPENING_MOVIE_INVALID", "a failed preflight raises the typed scene failure")
  local afterFailure = love.graphics.getStats()
  Assert.equal(afterFailure.images, baseline.images, "a failed preflight releases its staged images")
  Assert.equal(afterFailure.canvases, baseline.canvases, "a failed preflight leaves no canvas behind")
  local retryScenes, retryFs = customPack(fillerScene(5), 5, {}, gray16)
  local retry = openCompositeMovie(scope, retryScenes, retryFs, 512, 384, "single")
  Assert.equal(retry:sceneNumber(), 1, "a repaired retry still starts at the first scene with its clock at zero")
  Assert.isFalse(retry:skipAllowed(), "a repaired retry still opens with the skip gate closed")
  local afterRetry = love.graphics.getStats()
  Assert.equal(afterRetry.canvases, baseline.canvases + 2, "a repaired retry retains exactly two role targets")
  Assert.equal(
    afterRetry.images,
    baseline.images + 4,
    "a repaired retry retains only the current and next scene graphs"
  )
  local twinScenes, twinFs = customPack(fillerScene(5), 5, {}, gray16)
  local twin = openCompositeMovie(scope, twinScenes, twinFs, 512, 384, "single")
  Assert.equal(
    drawBytes(retry, scope, 512, 384),
    drawBytes(twin, scope, 512, 384),
    "two preflighted movies render the identical first frame"
  )
  twin:dispose()
  retry:dispose()
end

-- The relocated composited-town proof: scene-three town pixels must render
-- visibly in the final composed output and animate across hold ticks that
-- no wipe covers. The window matches the earlier town-camera sampling, so
-- the motion cannot come from a circle-wipe reveal.
local function composited_town_pixels_stay_visible_and_animate_across_hold_ticks(scope, context)
  local versionId = selectedVersionId(context)
  local realNewCanvas = love.graphics.newCanvas
  local calls = {}
  love.graphics.newCanvas = function(width, height, opts)
    calls[#calls + 1] = { width = width, height = height, at = debug.traceback("", 2):sub(1, 500) }
    return realNewCanvas(width, height, opts)
  end
  local constructed, movieOrFailure = pcall(openMovie, scope, versionId, 512, 384, "dual")
  love.graphics.newCanvas = realNewCanvas
  Assert.isTrue(constructed, "a town-staging movie constructs on bounded targets")
  local movie = movieOrFailure
  local movieCalls = 0
  for index, call in ipairs(calls) do
    Assert.isTrue(
      call.width <= 256 and call.height <= 192,
      "canvas call " .. index .. " stays within the 256x192 source frame"
    )
    -- Only the movie's own targets count toward its standing budget: the
    -- shared field renderer lazily owns its reused scene targets outside
    -- it, at the same bounded source size.
    if call.at:find("HgssOpeningMovie", 1, true) ~= nil then
      movieCalls = movieCalls + 1
      Assert.equal(call.width, 256, "movie canvas call " .. movieCalls .. " keeps the source engine width")
      Assert.equal(call.height, 192, "movie canvas call " .. movieCalls .. " keeps the source engine height")
    end
  end
  Assert.equal(movieCalls, 3, "a town-staging movie keeps two role targets plus one fixed town scratch")
  local ticks = 0
  while movie:sceneNumber() < 3 and ticks < 20000 do
    movie:updateFixed()
    ticks = ticks + 1
  end
  Assert.equal(movie:sceneNumber(), 3, "playback reaches the town scenes")
  local entryTicks = ticks
  while ticks < entryTicks + 20 do
    movie:updateFixed()
    ticks = ticks + 1
  end
  -- The town composites on the main-mapped upper pane while the sub panels
  -- hold the lower pane; both panes are asserted on the same composed frame.
  local function paneLitCells(bytes, y0)
    local lit = 0
    for y = y0, y0 + 191, 4 do
      for x = 0, 511, 4 do
        local r, g, b = pixelOf(bytes, 512, x, y)
        if r + g + b > 0.05 then
          lit = lit + 1
        end
      end
    end
    return lit
  end
  local function lowerLitCells(bytes)
    local lit = 0
    for y = 192, 383, 4 do
      for x = 0, 511, 4 do
        local r, g, b = pixelOf(bytes, 512, x, y)
        if r + g + b > 0.05 then
          lit = lit + 1
        end
      end
    end
    return lit
  end
  Assert.equal(movie.current.mainPhysical, "upper", "the town beat maps main to physical upper")
  movie:draw()
  local before = drawBytes(movie, scope, 512, 384)
  Assert.isTrue(paneLitCells(before, 0) > 3000, "the composed town lights the main-mapped upper pane")
  Assert.isTrue(lowerLitCells(before) > 500, "the town beat keeps the sub panels lit")
  for _ = 1, 15 do
    movie:updateFixed()
  end
  local after = drawBytes(movie, scope, 512, 384)
  Assert.isTrue(before ~= after, "town pixels animate across non-wipe hold ticks")
  -- The authored stop lands 167 ticks later and a wipe covers the
  -- transition, so the test waits for the panels to return instead of
  -- asserting a fixed post-stop tick.
  advance(movie, 167)
  local waited, panelsBack = 0, false
  local stopped = before
  while waited < 200 do
    movie:updateFixed()
    waited = waited + 1
    if waited % 5 == 0 then
      stopped = drawBytes(movie, scope, 512, 384)
      if lowerLitCells(stopped) > 500 then
        panelsBack = true
        break
      end
    end
  end
  Assert.isTrue(panelsBack, "the sub panels persist past the town stop")
  Assert.isTrue(paneLitCells(stopped, 0) < 50, "the authored stop clears the main-mapped upper pane")
  movie:dispose()
end

local function synthetic_color_overlap_proves_bg_ordering(scope)
  local root = sceneArtRoot(1)
  local frontImage = root .. "layers/front.png"
  local middleImage = root .. "layers/middle.png"
  local backImage = root .. "layers/back.png"
  local hiddenImage = root .. "layers/hidden.png"
  local groundImage = root .. "layers/ground.png"
  local art = {
    [frontImage] = solidPng(256, 192, 255, 0, 0),
    [middleImage] = solidPng(256, 192, 0, 255, 0),
    [backImage] = solidPng(256, 192, 0, 0, 255),
    [hiddenImage] = solidPng(256, 192, 255, 255, 0),
    [groundImage] = solidPng(256, 192, 128, 128, 128),
  }
  local scenes, cacheFs = compositePack(
    compositeScene(
      1,
      {
        compositeLayer(2, backImage, 256, 192),
        compositeLayer(0, frontImage, 256, 192),
        compositeLayer(1, middleImage, 256, 192),
        compositeLayer(3, hiddenImage, 256, 192, false),
      },
      { compositeLayer(0, groundImage, 256, 192) },
      {},
      { seed = 0, emitters = {} },
      { { id = "show", events = { 1, 2, 3 }, ["until"] = { kind = "duration", ticks = 40 } } },
      {
        { op = "enableSkip", stepId = "show", atStepTick = 10 },
        { op = "waitTicks", stepId = "show", atStepTick = 0, ticks = 40 },
        { op = "finish", stepId = "show", atStepTick = 40 },
      }
    ),
    art,
    solidPng(16, 16, 128, 128, 128)
  )
  local movie = openCompositeMovie(scope, scenes, cacheFs, 512, 384, "single")
  movie:updateFixed()
  movie:updateFixed()
  local r, g, b = samplePixel(scope, movie, 512, 384, 256, 192)
  Assert.isTrue(r > 0.9 and g < 0.1 and b < 0.1, "numeric priority 0 covers every lower plane")
end

local function synthetic_window_masks_isolate_engine_planes(scope)
  local root = sceneArtRoot(1)
  local mainBg1 = root .. "layers/main-bg1.png"
  local mainBg2 = root .. "layers/main-bg2.png"
  local subBg1 = root .. "layers/sub-bg1.png"
  local subBg2 = root .. "layers/sub-bg2.png"
  local art = {
    [mainBg1] = solidPng(256, 192, 255, 0, 0),
    [mainBg2] = solidPng(256, 192, 0, 0, 255),
    [subBg1] = solidPng(256, 192, 0, 255, 0),
    [subBg2] = solidPng(256, 192, 255, 255, 0),
  }
  local scenes, cacheFs = compositePack(
    compositeScene(
      1,
      { compositeLayer(1, mainBg1, 256, 192), compositeLayer(2, mainBg2, 256, 192) },
      { compositeLayer(1, subBg1, 256, 192), compositeLayer(2, subBg2, 256, 192) },
      {},
      { seed = 0, emitters = {} },
      { { id = "reveal", events = { 1, 2, 3, 4, 5 }, ["until"] = { kind = "duration", ticks = 20 } } },
      {
        {
          op = "window",
          stepId = "reveal",
          atStepTick = 0,
          engine = "main",
          from = { x1 = 255, y1 = 0, x2 = 255, y2 = 192 },
          to = { x1 = 0, y1 = 0, x2 = 255, y2 = 192 },
          ticks = 10,
          insideMask = 22,
          outsideMask = 20,
        },
        {
          op = "window",
          stepId = "reveal",
          atStepTick = 0,
          engine = "sub",
          from = { x1 = 0, y1 = 0, x2 = 0, y2 = 192 },
          to = { x1 = 0, y1 = 0, x2 = 255, y2 = 192 },
          ticks = 10,
          insideMask = 22,
          outsideMask = 20,
        },
        { op = "enableSkip", stepId = "reveal", atStepTick = 10 },
        { op = "waitTicks", stepId = "reveal", atStepTick = 0, ticks = 20 },
        { op = "finish", stepId = "reveal", atStepTick = 20 },
      }
    ),
    art,
    solidPng(16, 16, 128, 128, 128)
  )
  -- The dual stage carries both engines at once: the upper pane is the
  -- main target, the lower pane the sub target, each cover-cropped so the
  -- sampled columns land on opposite sides of the fifth-tick split.
  local movie = openCompositeMovie(scope, scenes, cacheFs, 512, 384, "dual")
  advance(movie, 5)
  local r1, g1, b1 = samplePixel(scope, movie, 512, 384, 128, 96)
  Assert.isTrue(b1 > 0.9 and r1 < 0.1, "main BG1 stays masked outside its window")
  local r2, g2, b2 = samplePixel(scope, movie, 512, 384, 384, 96)
  Assert.isTrue(r2 > 0.9 and b2 < 0.1, "main BG1 reveals inside its window")
  local r3, g3, b3 = samplePixel(scope, movie, 512, 384, 128, 288)
  Assert.isTrue(g3 > 0.9 and r3 < 0.1, "sub BG1 reveals inside its window")
  local r4, g4, b4 = samplePixel(scope, movie, 512, 384, 384, 288)
  Assert.isTrue(r4 > 0.9 and g4 > 0.9 and b4 < 0.1, "sub BG1 stays masked outside its window")
end

local function soulsilver_town_stays_on_main_and_stops_at_the_rival_beat(scope, context)
  local versionId = selectedVersionId(context)
  local movie = openMovie(scope, versionId, 512, 384, "dual")
  local ticks = 0
  while movie:sceneNumber() < 3 and ticks < 20000 do
    movie:updateFixed()
    ticks = ticks + 1
  end
  Assert.equal(movie:sceneNumber(), 3, "playback reaches the town scene")
  local entry = ticks
  advance(movie, 20)
  ticks = ticks + 20
  Assert.equal(movie.current.mainPhysical, "upper", "the town beat maps main to physical upper")
  local function paneLitCells(bytes, y0)
    local lit = 0
    for y = y0, y0 + 191, 4 do
      for x = 0, 511, 4 do
        local r, g, b = pixelOf(bytes, 512, x, y)
        if r + g + b > 0.05 then
          lit = lit + 1
        end
      end
    end
    return lit
  end
  local function lowerLitCells(bytes)
    local lit = 0
    for y = 192, 383, 4 do
      for x = 0, 511, 4 do
        local r, g, b = pixelOf(bytes, 512, x, y)
        if r + g + b > 0.05 then
          lit = lit + 1
        end
      end
    end
    return lit
  end
  local beatBytes = drawBytes(movie, scope, 512, 384)
  Assert.isTrue(paneLitCells(beatBytes, 0) > 3000, "the town beat lights the main-mapped upper pane")
  Assert.isTrue(lowerLitCells(beatBytes) > 500, "the town beat keeps the sub-mapped lower panels lit")
  Assert.equal(movie.current.activeTown, "new-bark-town", "the town beat selects its stage")
  advance(movie, 5)
  local laterBytes = drawBytes(movie, scope, 512, 384)
  Assert.isTrue(beatBytes ~= laterBytes, "town pixels animate across non-wipe hold ticks")
  -- The authored stop lands at the 187th scene tick; playing past it must
  -- neither raise nor hang the step graph. A wipe covers the transition,
  -- so the test waits for the panels to return instead of asserting a
  -- fixed post-stop tick.
  advance(movie, 187 + 8 - 25)
  local waited, panelsBack = 0, false
  local stopBytes = beatBytes
  while waited < 200 do
    movie:updateFixed()
    waited = waited + 1
    if waited % 5 == 0 then
      stopBytes = drawBytes(movie, scope, 512, 384)
      if lowerLitCells(stopBytes) > 500 then
        panelsBack = true
        break
      end
    end
  end
  Assert.isTrue(panelsBack, "the sub panels return after the stop transition")
  Assert.isTrue(paneLitCells(stopBytes, 0) < 50, "the authored stop clears the main-mapped upper pane")
  local townPool = movie.current.pool
  Assert.isTrue(townPool.triangles > 0, "the live town stage keeps its geometry")
  movie:dispose()
  Assert.equal(townPool.triangles, 0, "slot disposal releases the town geometry")
end

-- The authored scene-4 physical flips place the main engine on the lower,
-- upper, then lower host pane across the three starter beats. Each beat is
-- read from both fixed source targets and from the composed host frame, so
-- a flipped engine assignment fails on pixels, not on event names.
local function real_starter_flips_map_each_source_engine_onto_its_authored_host_pane(scope, context)
  local versionId = selectedVersionId(context)
  local movie = openMovie(scope, versionId, 512, 384, "dual")
  -- Asserts the two host panes show the mapped source engines on the current
  -- beat. Object beats paint only part of their 256x192 target, so the
  -- probes compare the authored engine point through the centered blit:
  -- every layout centers its source canvas, so the mapped host point
  -- samples the exact authored texel under nearest filtering.
  local function assertStackedPlacement(target, width, height, firstPt, secondPt, label)
    target:draw()
    local hostBytes = drawBytes(target, scope, width, height)
    local mainBytes = sourceBytes(scope, target.mainCanvas)
    local subBytes = sourceBytes(scope, target.subCanvas)
    local upperR, upperG, upperB = pixelOf(hostBytes, width, firstPt[1], firstPt[2])
    local lowerR, lowerG, lowerB = pixelOf(hostBytes, width, secondPt[1], secondPt[2])
    local mainR, mainG, mainB = pixelOf(mainBytes, 256, 128, 96)
    local subR, subG, subB = pixelOf(subBytes, 256, 128, 96)
    if target.current.mainPhysical == "upper" then
      assertPaneShowsEngine(
        upperR,
        upperG,
        upperB,
        mainR,
        mainG,
        mainB,
        subR,
        subG,
        subB,
        label .. ": upper pane shows main"
      )
      assertPaneShowsEngine(
        lowerR,
        lowerG,
        lowerB,
        subR,
        subG,
        subB,
        mainR,
        mainG,
        mainB,
        label .. ": lower pane shows sub"
      )
    else
      assertPaneShowsEngine(
        upperR,
        upperG,
        upperB,
        subR,
        subG,
        subB,
        mainR,
        mainG,
        mainB,
        label .. ": upper pane shows sub"
      )
      assertPaneShowsEngine(
        lowerR,
        lowerG,
        lowerB,
        mainR,
        mainG,
        mainB,
        subR,
        subG,
        subB,
        label .. ": lower pane shows main"
      )
    end
  end
  local starters = {
    { step = "starter-chikorita", mainPhysical = "lower" },
    { step = "starter-cyndaquil", mainPhysical = "upper" },
    { step = "starter-totodile", mainPhysical = "lower" },
  }
  for _, beat in ipairs(starters) do
    advanceToSceneStep(movie, 4, beat.step, 20000)
    advance(movie, 4)
    Assert.equal(currentStepId(movie), beat.step, beat.step .. " holds across its emitter beat")
    Assert.equal(movie.current.mainPhysical, beat.mainPhysical, beat.step .. " maps main to " .. beat.mainPhysical)
    movie:draw()
    local mainBytes = sourceBytes(scope, movie.mainCanvas)
    local subBytes = sourceBytes(scope, movie.subCanvas)
    Assert.isTrue(mainBytes ~= subBytes, beat.step .. " keeps the two source engines distinct")
    assertStackedPlacement(movie, 512, 384, { 256, 96 }, { 256, 288 }, beat.step .. " dual")
  end
  movie:dispose()
  -- The same cyndaquil beat keeps its role mapping on every host geometry.
  -- Resizing never rewinds the source clock, so one single-surface movie
  -- covers the tall, wide, and native-like stages.
  local single = openMovie(scope, versionId, 600, 1000, "single")
  advanceToSceneStep(single, 4, "starter-cyndaquil", 20000)
  advance(single, 4)
  Assert.equal(currentStepId(single), "starter-cyndaquil", "the single-surface movie holds its emitter beat")
  Assert.equal(single.current.mainPhysical, "upper", "the cyndaquil beat maps main to upper")
  for _, layout in ipairs({
    { width = 600, height = 1000, first = { 300, 250 }, second = { 300, 750 }, name = "tall" },
    { width = 1200, height = 600, first = { 300, 300 }, second = { 900, 300 }, name = "wide" },
    { width = 512, height = 384, first = { 256, 96 }, second = { 256, 288 }, name = "nativeLike" },
  }) do
    single:resize(layout.width, layout.height)
    Assert.equal(single:sceneNumber(), 4, layout.name .. " keeps the movie on its scene")
    Assert.equal(currentStepId(single), "starter-cyndaquil", layout.name .. " keeps the movie on its beat")
    assertStackedPlacement(
      single,
      layout.width,
      layout.height,
      layout.first,
      layout.second,
      "cyndaquil " .. layout.name
    )
  end
  single:dispose()
end

-- Starter particles animate only the main source target. Each starter step
-- waits on its own emitter effect, so live particles are guaranteed while
-- the step holds; the sub target must stay pixel-identical across the same
-- ticks on both sides of a physical flip, proving output follows main.
local function starter_particles_move_only_the_main_source_target(scope, context)
  local versionId = selectedVersionId(context)
  local scenes = loadScenes(versionId)
  local function stepEffect(stepId)
    for _, step in ipairs(scenes[4].timeline.steps) do
      if step.id == stepId then
        local finish = assert(step["until"], stepId .. " carries its completion")
        return finish.effect
      end
    end
    Assert.notNil(nil, "scene 4 keeps its " .. stepId .. " step")
  end
  Assert.equal(stepEffect("starter-chikorita"), "emitters-grass", "the first starter waits on its grass emitters")
  Assert.equal(stepEffect("starter-cyndaquil"), "emitters-fire", "the second starter waits on its fire emitters")
  local movie = openMovie(scope, versionId, 512, 384, "dual")
  local function liveParticles()
    local count = 0
    for _, runtime in ipairs(assert(movie.current.emitters, "the movie tracks its live emitters")) do
      count = count + #(runtime.particles or {})
    end
    return count
  end
  local mappings = {}
  for _, beat in ipairs({ "starter-chikorita", "starter-cyndaquil" }) do
    advanceToSceneStep(movie, 4, beat, 20000)
    advance(movie, 3)
    Assert.equal(currentStepId(movie), beat, beat .. " holds across its emitter beat")
    mappings[#mappings + 1] = movie.current.mainPhysical
    movie:draw()
    local mainBefore = sourceBytes(scope, movie.mainCanvas)
    local subBefore = sourceBytes(scope, movie.subCanvas)
    Assert.isTrue(liveParticles() > 0, beat .. " samples while starter particles are live")
    advance(movie, 3)
    Assert.equal(currentStepId(movie), beat, beat .. " still holds after three more ticks")
    movie:draw()
    local mainAfter = sourceBytes(scope, movie.mainCanvas)
    local subAfter = sourceBytes(scope, movie.subCanvas)
    Assert.isTrue(mainAfter ~= mainBefore, beat .. " animates the main source target")
    Assert.equal(subAfter, subBefore, beat .. " leaves the sub source target untouched")
  end
  Assert.equal(mappings[1], "lower", "the first starter plays with main on the lower pane")
  Assert.equal(mappings[2], "upper", "the second starter plays after the flip with main on the upper pane")
  movie:dispose()
end

-- The scene-4 slide-in runs one ten-tick window per engine in opposite
-- directions: main reveals left to right, sub right to left. Between the
-- midway and completed frames the still-scrolling background shifts both
-- halves alike, so the half that changes more is the half the window
-- finishes revealing.
local function slide_in_windows_reveal_opposite_halves_on_each_engine(scope, context)
  local versionId = selectedVersionId(context)
  local movie = openMovie(scope, versionId, 512, 384, "dual")
  advanceToSceneStep(movie, 4, "slide-in", 20000)
  movie:draw()
  local mainEarly = sourceBytes(scope, movie.mainCanvas)
  local subEarly = sourceBytes(scope, movie.subCanvas)
  advance(movie, 5)
  Assert.equal(currentStepId(movie), "slide-in", "the slide still runs at its fifth tick")
  movie:draw()
  local mainMid = sourceBytes(scope, movie.mainCanvas)
  local subMid = sourceBytes(scope, movie.subCanvas)
  local guard = 0
  while currentStepId(movie) == "slide-in" and guard < 20 do
    movie:updateFixed()
    guard = guard + 1
  end
  movie:draw()
  local mainDone = sourceBytes(scope, movie.mainCanvas)
  local subDone = sourceBytes(scope, movie.subCanvas)
  advance(movie, 10)
  Assert.equal(currentStepId(movie), "hold", "the hold follows the completed slide")
  movie:draw()
  local mainHold = sourceBytes(scope, movie.mainCanvas)
  local subHold = sourceBytes(scope, movie.subCanvas)
  local mainFirst = changeFraction(mainEarly, mainMid, 256, 192)
  local subFirst = changeFraction(subEarly, subMid, 256, 192)
  Assert.isTrue(mainFirst > 0.05, ("the main reveal starts (%.3f)"):format(mainFirst))
  Assert.isTrue(subFirst > 0.05, ("the sub reveal starts (%.3f)"):format(subFirst))
  local mainSecond = changeFraction(mainMid, mainDone, 256, 192)
  local subSecond = changeFraction(subMid, subDone, 256, 192)
  Assert.isTrue(mainSecond > 0.05, ("the main reveal runs to completion (%.3f)"):format(mainSecond))
  Assert.isTrue(subSecond > 0.05, ("the sub reveal runs to completion (%.3f)"):format(subSecond))
  local mainSettled = changeFraction(mainDone, mainHold, 256, 192)
  local subSettled = changeFraction(subDone, subHold, 256, 192)
  Assert.isTrue(mainSettled < 0.02, ("the completed main reveal holds still (%.3f)"):format(mainSettled))
  Assert.isTrue(subSettled < 0.02, ("the completed sub reveal holds still (%.3f)"):format(subSettled))
  -- The sourced slide opens the main window from the right edge toward
  -- full width and mirrors the sub window from the left edge, so the late
  -- (mid-to-done) change concentrates on the left for main and on the
  -- right for sub: the two engines reveal opposite halves.
  local mainLeft = halfChangeFraction(mainMid, mainDone, 256, 192, true)
  local mainRight = halfChangeFraction(mainMid, mainDone, 256, 192, false)
  Assert.isTrue(
    mainLeft > mainRight,
    ("the main reveal finishes on the left (left %.3f vs right %.3f)"):format(mainLeft, mainRight)
  )
  local subLeft = halfChangeFraction(subMid, subDone, 256, 192, true)
  local subRight = halfChangeFraction(subMid, subDone, 256, 192, false)
  Assert.isTrue(
    subRight > subLeft,
    ("the sub reveal finishes on the right (right %.3f vs left %.3f)"):format(subRight, subLeft)
  )
  movie:dispose()
end

-- One grouped journey across all five scenes: each authored beat lights
-- both fixed source targets with distinct engine content. Repeated host
-- draws between the samples prove draws never advance the source clock.
local function every_scene_paints_its_authored_beat_on_both_engines(scope, context)
  local versionId = selectedVersionId(context)
  local movie = openMovie(scope, versionId, 512, 384, "dual")
  local function sampleBeat(label)
    movie:draw()
    local main = sourceBytes(scope, movie.mainCanvas)
    local sub = sourceBytes(scope, movie.subCanvas)
    Assert.isTrue(regionLit(main, 256, 0, 255, 0, 191) > 0.2, label .. " lights the main source target")
    Assert.isTrue(regionLit(sub, 256, 0, 255, 0, 191) > 0.2, label .. " lights the sub source target")
    Assert.isTrue(main ~= sub, label .. " keeps the two source engines distinct")
    return main
  end
  advanceToSceneStep(movie, 1, "sunrise", 20000)
  sampleBeat("scene 1 sunrise")
  movie:draw()
  local firstDraw = sourceBytes(scope, movie.mainCanvas)
  movie:draw()
  Assert.equal(sourceBytes(scope, movie.mainCanvas), firstDraw, "a repeated draw paints the identical source frame")
  -- The flyin black-out fade has no clearing event, so the later pan beats
  -- stay covered; the flyin beat itself carries visible grass, flowers, and
  -- heroes on both engines. Pan-beat pixels wait on the fade-lifecycle
  -- follow-up instead of being asserted here.
  advanceToSceneStep(movie, 2, "flyin", 20000)
  advance(movie, 30)
  Assert.equal(currentStepId(movie), "flyin", "scene 2 samples its visible flyin beat")
  sampleBeat("scene 2 flowers")
  local waited = 0
  while waited < 20000 and (movie:sceneNumber() ~= 3 or movie.current.activeTown == nil) do
    movie:updateFixed()
    waited = waited + 1
  end
  Assert.notNil(movie.current.activeTown, "scene 3 selects its town stage")
  advance(movie, 15)
  sampleBeat("scene 3 town (" .. tostring(movie.current.activeTown) .. ")")
  advanceToSceneStep(movie, 4, "starter-cyndaquil", 20000)
  advance(movie, 3)
  sampleBeat("scene 4 starter")
  advanceToSceneStep(movie, 5, "scroll", 20000)
  advance(movie, 5)
  movie:draw()
  local scrollBefore = sourceBytes(scope, movie.mainCanvas)
  advance(movie, 5)
  movie:draw()
  Assert.isTrue(sourceBytes(scope, movie.mainCanvas) ~= scrollBefore, "scene 5 panorama scrolls main source pixels")
  sampleBeat("scene 5 panorama")
  movie:dispose()
end

-- Single-role beats fill a single-screen stage with the authored active
-- engine: the town beat shows main, the rival-only beat after the town
-- stop shows sub. Dual stages keep both roles mapped instead.
local function single_screen_stages_show_the_authored_active_engine(scope, context)
  local versionId = selectedVersionId(context)
  local single = openMovie(scope, versionId, 512, 384, "single")
  local waited = 0
  while waited < 20000 and (single:sceneNumber() ~= 3 or single.current.activeTown == nil) do
    single:updateFixed()
    waited = waited + 1
  end
  Assert.notNil(single.current.activeTown, "scene 3 selects its town stage")
  advance(single, 5)
  Assert.equal(single.current.mainPhysical, "upper", "the town beat maps main to physical upper")
  for _, layout in ipairs({
    { width = 1200, height = 600, center = { 600, 300 }, name = "wide" },
    { width = 512, height = 384, center = { 256, 192 }, name = "nativeLike" },
  }) do
    single:resize(layout.width, layout.height)
    local hostBytes = drawBytes(single, scope, layout.width, layout.height)
    local mainR, mainG, mainB = pixelOf(sourceBytes(scope, single.mainCanvas), 256, 128, 96)
    local subR, subG, subB = pixelOf(sourceBytes(scope, single.subCanvas), 256, 128, 96)
    local hostR, hostG, hostB = pixelOf(hostBytes, layout.width, layout.center[1], layout.center[2])
    assertPaneShowsEngine(hostR, hostG, hostB, mainR, mainG, mainB, subR, subG, subB, layout.name .. " town stage shows main")
  end
  advanceToSceneStep(single, 3, "panels", 20000)
  advance(single, 5)
  for _, layout in ipairs({
    { width = 512, height = 384, center = { 256, 192 }, name = "nativeLike" },
    { width = 1200, height = 600, center = { 600, 300 }, name = "wide" },
  }) do
    single:resize(layout.width, layout.height)
    local hostBytes = drawBytes(single, scope, layout.width, layout.height)
    local subBytes = sourceBytes(scope, single.subCanvas)
    -- Rival panels avoid the exact canvas center, so the probes sample
    -- the lit panel point (96, 96) the column survey identified.
    local mainR, mainG, mainB = pixelOf(sourceBytes(scope, single.mainCanvas), 256, 96, 96)
    local subR, subG, subB = pixelOf(subBytes, 256, 96, 96)
    local hostPt = { layout.name == "wide" and 500 or 192, layout.name == "wide" and 300 or 192 }
    local hostR, hostG, hostB = pixelOf(hostBytes, layout.width, hostPt[1], hostPt[2])
    assertPaneShowsEngine(hostR, hostG, hostB, subR, subG, subB, mainR, mainG, mainB, layout.name .. " rival stage shows sub")
  end
  single:dispose()
  local dual = openMovie(scope, versionId, 512, 384, "dual")
  local function assertBothPanesMapped(width, height, upperPt, lowerPt, enginePt, sceneLabel)
    dual:draw()
    local hostBytes = drawBytes(dual, scope, width, height)
    local mainBytes = sourceBytes(scope, dual.mainCanvas)
    local subBytes = sourceBytes(scope, dual.subCanvas)
    local upperR, upperG, upperB = pixelOf(hostBytes, width, upperPt[1], upperPt[2])
    local lowerR, lowerG, lowerB = pixelOf(hostBytes, width, lowerPt[1], lowerPt[2])
    local mainR, mainG, mainB = pixelOf(mainBytes, 256, enginePt[1], enginePt[2])
    local subR, subG, subB = pixelOf(subBytes, 256, enginePt[1], enginePt[2])
    local firstR, firstG, firstB, firstMappedR, firstMappedG, firstMappedB, firstOtherR, firstOtherG, firstOtherB
    local secondR, secondG, secondB, secondMappedR, secondMappedG, secondMappedB, secondOtherR, secondOtherG, secondOtherB
    if dual.current.mainPhysical == "upper" then
      firstR, firstG, firstB = upperR, upperG, upperB
      firstMappedR, firstMappedG, firstMappedB = mainR, mainG, mainB
      firstOtherR, firstOtherG, firstOtherB = subR, subG, subB
      secondR, secondG, secondB = lowerR, lowerG, lowerB
      secondMappedR, secondMappedG, secondMappedB = subR, subG, subB
      secondOtherR, secondOtherG, secondOtherB = mainR, mainG, mainB
    else
      firstR, firstG, firstB = upperR, upperG, upperB
      firstMappedR, firstMappedG, firstMappedB = subR, subG, subB
      firstOtherR, firstOtherG, firstOtherB = mainR, mainG, mainB
      secondR, secondG, secondB = lowerR, lowerG, lowerB
      secondMappedR, secondMappedG, secondMappedB = mainR, mainG, mainB
      secondOtherR, secondOtherG, secondOtherB = subR, subG, subB
    end
    assertPaneShowsEngine(firstR, firstG, firstB, firstMappedR, firstMappedG, firstMappedB, firstOtherR, firstOtherG, firstOtherB, sceneLabel .. ": first pane shows its mapped engine")
    assertPaneShowsEngine(secondR, secondG, secondB, secondMappedR, secondMappedG, secondMappedB, secondOtherR, secondOtherG, secondOtherB, sceneLabel .. ": second pane shows its mapped engine")
  end
  waited = 0
  while waited < 20000 and (dual:sceneNumber() ~= 3 or dual.current.activeTown == nil) do
    dual:updateFixed()
    waited = waited + 1
  end
  advance(dual, 5)
  assertBothPanesMapped(512, 384, { 256, 96 }, { 256, 288 }, { 128, 96 }, "town dual")
  advanceToSceneStep(dual, 3, "panels", 20000)
  advance(dual, 5)
  assertBothPanesMapped(512, 384, { 192, 96 }, { 192, 288 }, { 96, 96 }, "panels dual")
  dual:dispose()
end

-- Reads the current background offsets of the running slot by engine.
---@param movie table running opening movie
---@return table<string, integer> vertical offsets by engine and slot name
local function currentScrollOffsets(movie)
  local slot = assert(movie.current, "the running movie owns its current slot")
  return {
    main0 = slot.backgrounds.main[0].scrollY,
    main1 = slot.backgrounds.main[1].scrollY,
    main2 = slot.backgrounds.main[2].scrollY,
    sub0 = slot.backgrounds.sub[0].scrollY,
  }
end

---@param scope table
---@param versionId string selected edition identity
local function sourced_scroll_offsets_follow_absolute_source_ticks(scope, versionId)
  local scenes, cacheFs = loadRomPackWithFillers(versionId, { 3, 4, 5 })
  local movie = openMovieWithCache(scope, scenes, cacheFs, versionId, 512, 384, "single")
  advanceToSceneStep(movie, 2, "flyin", 20000)
  -- The sourced flyin opens with two immediate placements plus two
  -- open-ended drifts: main BG0 sits 192 down, main BG1 320 down, and
  -- both drifts add 64 every fixed tick.
  local entry = currentScrollOffsets(movie)
  Assert.equal(entry.main0, 192, "the immediate main BG0 placement lands on the first frame")
  Assert.equal(entry.main1, 320, "the immediate main BG1 placement lands on the first frame")
  Assert.equal(entry.main2, 0, "the open-ended drift starts at its origin")
  movie:draw()
  local drawn = currentScrollOffsets(movie)
  Assert.equal(drawn.main0, 192, "a host draw never resamples the immediate placement")
  for _ = 1, 10 do
    movie:updateFixed()
    movie:draw()
  end
  local tenth = currentScrollOffsets(movie)
  Assert.equal(tenth.main0, 192, "the timed replacement has not fired yet")
  Assert.equal(tenth.main2, 640, "the main open-ended drift adds its step every fixed tick")
  Assert.equal(tenth.sub0, 640, "the sub open-ended drift advances on its own engine clock")
  -- At the fifty-sixth flyin tick both voiced panels start a five-tick
  -- -192 replacement: the middle sample truncates toward zero and the
  -- final tick lands exactly on the combined displacement.
  for _ = 1, 45 do
    movie:updateFixed()
  end
  movie:updateFixed()
  local first = currentScrollOffsets(movie)
  Assert.equal(first.main0, 154, "the first replacement tick holds 192 plus trunc(-192/5)")
  for _ = 1, 4 do
    movie:updateFixed()
  end
  local settled = currentScrollOffsets(movie)
  Assert.equal(settled.main0, 0, "the replacement lands exactly on its combined displacement")
  Assert.equal(settled.main1, 128, "the main BG1 replacement lands exactly on 320 minus 192")
  movie:dispose()
end

local function sourced_scroll_offsets_for_edition(scope, context)
  local versionId = selectedVersionId(context)
  sourced_scroll_offsets_follow_absolute_source_ticks(scope, versionId)
end

local function heartgold_scroll_offsets_are_blocked_without_a_dump(scope, context)
  if not RomImporter.isReady("heartgold") then
    context:skip(
      "BLOCKED: HeartGold scroll offsets need a user-owned HeartGold dump; "
        .. "only SoulSilver is ready here, so the sourced immediate, continuous, "
        .. "and timed offset legs cannot run for HeartGold and are never faked"
    )
  end
  sourced_scroll_offsets_follow_absolute_source_ticks(scope, "heartgold")
end

---@param scope table
---@param pngBytes string staged png bytes from the version cache
---@param name string staged path carried for diagnostics
---@return love.ImageData decoded art pixels owned by the scope
local function decodedArt(scope, pngBytes, name)
  local fileData = love.filesystem.newFileData(pngBytes, name)
  return scope:own(love.image.newImageData(fileData))
end

---@param scope table
---@param versionId string selected edition identity
local function sourced_panorama_pixels_match_wrapped_source_art(scope, versionId)
  local scenes, cacheFs = loadRomPackWithFillers(versionId, { 3, 4 })
  local movie = openMovieWithCache(scope, scenes, cacheFs, versionId, 512, 384, "single")
  advanceToSceneStep(movie, 5, "scroll", 20000)
  -- The wipe-step cover retires a few ticks into the scroll beat, so the
  -- lit baseline is sampled once the engine targets show the panorama.
  for _ = 1, 10 do
    movie:updateFixed()
    movie:draw()
  end
  movie:draw()
  local startMain = sourceBytes(scope, movie.mainCanvas)
  Assert.isTrue(
    regionLit(startMain, 256, 0, 255, 0, 191) > 0.2,
    "the scroll beat lights the main source target"
  )
  -- The sourced panorama pans every voiced panel across 73 fixed ticks.
  for _ = 1, 60 do
    movie:updateFixed()
    movie:draw()
  end
  movie:draw()
  local endMain = sourceBytes(scope, movie.mainCanvas)
  Assert.isTrue(endMain ~= startMain, "the panorama moves main source pixels across its duration")
  local slot = assert(movie.current, "the running movie owns its current slot")
  -- Every voiced main-engine panel is decoded from its own staged bytes
  -- and the engine canvas is checked against the wrapped source formula,
  -- composited back-to-front exactly like the plane pass: numeric
  -- priority paints first, the lower slot breaks ties. Only decisive
  -- (opaque or fully clear) art pixels count, so soft art edges can never
  -- decide the comparison either way.
  local panels = {}
  for _, bgSlot in ipairs({ 1, 2 }) do
    local background = assert(slot.backgrounds.main[bgSlot], "the voiced panel is staged")
    Assert.isTrue(background.visible, "the voiced panel stays visible through the pan")
    local bytes = assert(cacheFs:read(background.image), "the staged panel art reads back")
    local data = decodedArt(scope, bytes, background.image)
    panels[#panels + 1] = {
      data = data,
      width = data:getWidth(),
      height = data:getHeight(),
      offsetX = math.floor(background.scrollX),
      offsetY = math.floor(background.scrollY),
      priority = background.priority,
      bgSlot = bgSlot,
    }
  end
  table.sort(panels, function(a, b)
    if a.priority ~= b.priority then
      return a.priority > b.priority
    end
    return a.bgSlot < b.bgSlot
  end)
  local matched, decisive = 0, 0
  for y = 0, 191, 16 do
    for x = 0, 255, 16 do
      local er, eg, eb = 0, 0, 0
      local settled = true
      for _, panel in ipairs(panels) do
        local sx = (x + panel.offsetX) % panel.width
        local sy = (y + panel.offsetY) % panel.height
        local r, g, b, a = panel.data:getPixel(sx, sy)
        if a > 0.98 then
          er, eg, eb = r, g, b
          break
        elseif a > 0.02 then
          settled = false
          break
        end
      end
      if settled then
        decisive = decisive + 1
        local ar, ag, ab = pixelOf(endMain, 256, x, y)
        if math.abs(ar - er) + math.abs(ag - eg) + math.abs(ab - eb) < 0.06 then
          matched = matched + 1
        end
      end
    end
  end
  Assert.isTrue(decisive > 96, "most sampled viewport pixels rest on decisive art")
  Assert.isTrue(matched / decisive > 0.9, "viewport pixels match the wrapped source art")
  movie:draw()
  Assert.equal(
    sourceBytes(scope, movie.mainCanvas),
    endMain,
    "a repeated draw paints the identical source frame"
  )
  movie:dispose()
end

local function sourced_panorama_for_edition(scope, context)
  local versionId = selectedVersionId(context)
  sourced_panorama_pixels_match_wrapped_source_art(scope, versionId)
end

local function heartgold_panorama_wrap_is_blocked_without_a_dump(scope, context)
  if not RomImporter.isReady("heartgold") then
    context:skip(
      "BLOCKED: HeartGold panorama edges need a user-owned HeartGold dump; "
        .. "only SoulSilver is ready here, so the sourced wrap and strip legs "
        .. "cannot run for HeartGold and are never faked"
    )
  end
  sourced_panorama_pixels_match_wrapped_source_art(scope, "heartgold")
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
  ["native viewports wrap across source extents"] = native_viewports_wrap_across_source_extents,
  ["swapped viewports follow the active image extents"] = swapped_viewports_follow_the_active_image_extents,
  ["sourced scroll offsets follow absolute source ticks"] = sourced_scroll_offsets_for_edition,
  ["heartgold scroll offsets are blocked without a dump"] = heartgold_scroll_offsets_are_blocked_without_a_dump,
  ["sourced panorama pixels match wrapped source art"] = sourced_panorama_for_edition,
  ["heartgold panorama wrap is blocked without a dump"] = heartgold_panorama_wrap_is_blocked_without_a_dump,
  ["synthetic color overlap proves bg ordering"] = synthetic_color_overlap_proves_bg_ordering,
  ["synthetic window masks isolate engine planes"] = synthetic_window_masks_isolate_engine_planes,
  ["soulsilver town stays on main and stops at the rival beat"] = soulsilver_town_stays_on_main_and_stops_at_the_rival_beat,
  ["authored sprites stay on their engine with frame offsets"] = authored_sprites_stay_on_their_engine_with_frame_offsets,
  ["step relative fades composite on the gpu"] = step_relative_fades_composite_on_the_gpu,
  ["a single active source screen fills the whole single-screen stage"] = a_single_active_source_screen_fills_the_whole_single_screen_stage,
  ["paired beats and flips keep both source screens across every layout"] = paired_beats_and_flips_keep_both_source_screens_across_every_layout,
  ["movie targets stay bounded across resizes to very large stages"] = movie_targets_stay_bounded_across_resizes_to_very_large_stages,
  ["construction fails before the first frame unless all five scenes acquire"] = construction_fails_before_the_first_frame_unless_all_five_scenes_acquire,
  ["composited town pixels stay visible and animate across hold ticks"] = composited_town_pixels_stay_visible_and_animate_across_hold_ticks,
  ["real starter flips map each source engine onto its authored host pane"] = real_starter_flips_map_each_source_engine_onto_its_authored_host_pane,
  ["starter particles move only the main source target"] = starter_particles_move_only_the_main_source_target,
  ["slide-in windows reveal opposite halves on each engine"] = slide_in_windows_reveal_opposite_halves_on_each_engine,
  ["every scene paints its authored beat on both engines"] = every_scene_paints_its_authored_beat_on_both_engines,
  ["single-screen stages show the authored active engine"] = single_screen_stages_show_the_authored_active_engine,
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
