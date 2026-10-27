-- Source-backed opening movie graphics: the compiled scenes from the selected
-- user-owned edition play in order with real town and particle motion at fixed
-- source timing, the skip gate finishes only the movie, and GPU resources are
-- released. HeartGold coverage stays blocked: no HeartGold dump is available
-- here, so its dedicated scenario skips instead of running against faked art;
-- every other real-source scenario runs against whichever edition is ready.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local Contract = require("libs.assets.src.DerivedAssetContract")
local PngWriter = require("tests.support.PngEncoder")
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
    startOffset = 0,
    generation = { countFx = 8192, interval = 1 },
    initPosType = 2,
    circleAxis = 0,
    drawType = 0,
    radius = 0.5,
    length = 0,
    position = { x = 0, y = 0, z = 0 },
    axis = { x = 0, y = 1, z = 0 },
    baseColorRgb = { r = 31, g = 31, b = 31 },
    baseAlpha = 31,
    baseScaleFx = 4096,
    velocityFx = { pos = 819, axis = 0 },
    velRandom = 0,
    scaleRandom = 0,
    lifeRandom = 0,
    rotation = { min = 0, max = 0 },
    useRotationAnim = false,
    useInitRotationRandom = false,
    initRotation = 0,
    airResist = 128,
    aspect = 1.0,
    loopFrame = 1,
    dbbScale = 0,
    sclAnmDirect = 0,
    texRepeat = { s = 0, t = 0 },
    texture = id,
    textureImage = root .. "particles/texture" .. id .. ".png",
    animations = {},
    child = nil,
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

---@param custom table scene manifest under test
---@param customIndex integer retail position of the custom scene
---@param art table<string, string> staged png bytes by generated path
---@param defaultPng string fallback png bytes for art the test never samples
---@return table[] scenes, table cacheFs strict five-scene pack with the custom scene at its retail position
local function compositePackAt(custom, customIndex, art, defaultPng)
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
  -- Ten of twenty source ticks count raw fifteen: the old complementary
  -- single weight would leave the under plane one sixteenth, but the
  -- normative equation saturates each side independently, so the second
  -- side stays full: (31*15+0)/16=29 red-blue-side, (0+31*16)/16=31 green.
  -- The top blue keeps 29/31 while the under green keeps its full share.
  Assert.near(xr, 0, 0.05, "the blend keeps no bottom red under the settling top layer")
  Assert.near(xg, 1, 0.06, "the independently saturated second side keeps its full green share")
  Assert.near(xb, 29 / 31, 0.08, "the top keeps its fifteen-sixteenths blue share")
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
          animate = true,
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
    {
      op = "setFade",
      stepId = "run",
      atStepTick = 90,
      scope = "both",
      mode = "brightness",
      color = "white",
      direction = "out",
      ticks = 20,
      terminal = "neutral",
      effect = "fade-run",
    },
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
  Assert.equal(
    frameAt(sampleTick, true),
    frameAt(sampleTick, false),
    "rendering cadence cannot advance the source timeline"
  )
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

-- Emitter 1 carries a scale-animated child whose end is the source fx16
-- value 5360: the live child starts at unity and follows the retail life
-- interpolation, and the engine target keeps repainting while it grows.
---@param scope table test scope owning GPU readbacks
---@param context table runner context owning skip
local function soulsilver_starter_child_scale_follows_its_life_curve(scope, context)
  local versionId = selectedVersionId(context)
  local scenes = loadScenes(versionId)
  local emitterOne = nil
  for _, record in ipairs(scenes[4].particles.emitters) do
    if record.id == 1 then
      emitterOne = record
    end
  end
  Assert.notNil(emitterOne, "scene 4 keeps its source emitter 1")
  local compiled = assert(emitterOne.child, "emitter 1 keeps its child block")
  Assert.isTrue(compiled.useScaleAnm, "emitter 1 animates its child scale")
  Assert.equal(compiled.life, 7, "emitter 1 keeps its child lifespan")
  Assert.near(compiled.scaleEnd, 5360 / 4096, 1e-12, "the compiled child end keeps its source fx16 value")
  local movie = openMovie(scope, versionId, 512, 384, "single")
  local ticks = 0
  while movie:sceneNumber() < 4 and ticks < 20000 do
    movie:updateFixed()
    ticks = ticks + 1
  end
  Assert.equal(movie:sceneNumber(), 4, "playback reaches the starter scenes")
  local runtime = nil
  while ticks < 20000 do
    movie:updateFixed()
    ticks = ticks + 1
    if movie:sceneNumber() ~= 4 then
      break
    end
    local slot = movie.current
    Assert.notNil(slot, "the running movie owns its current slot")
    for _, candidate in ipairs(slot.emitters) do
      if candidate.id == 1 and #candidate.children > 0 then
        runtime = candidate
      end
    end
    if runtime ~= nil then
      break
    end
  end
  Assert.notNil(runtime, "emitter 1 spawns a live child")
  local live = runtime.children[1]
  live.age = 0
  local function cdivTrunc(numerator, denominator)
    local quotient = numerator / denominator
    if quotient >= 0 then
      return math.floor(quotient)
    end
    return math.ceil(quotient)
  end
  movie:draw()
  local early = drawBytes(movie, scope, 512, 384)
  for age = 0, 3 do
    movie:updateFixed()
    movie:draw()
    local rate = math.floor(age * 256 / 7)
    local expected = 5360 + cdivTrunc((5360 - 4096) * (rate - 255), 255)
    Assert.equal(live.animScale, expected, "the real child scale follows its life rate at age " .. age)
  end
  Assert.equal(live.animScale, 4637, "the real child scale reaches its mid-life value")
  local late = drawBytes(movie, scope, 512, 384)
  Assert.isTrue(early ~= late, "the growing child repaints real stage pixels")
  movie:dispose()
end

---@param scope table test scope owning GPU readbacks
---@param context table runner context owning skip
local function heartgold_starter_child_scale_is_blocked_without_a_dump(scope, context)
  if not RomImporter.isReady("heartgold") then
    context:skip(
      "BLOCKED: HeartGold starter child scale needs a user-owned HeartGold dump; "
        .. "only SoulSilver is ready here, so the sourced life-curve leg cannot run for HeartGold "
        .. "and is never faked"
    )
  end
  local scenes = loadScenes("heartgold")
  local emitterOne = nil
  for _, record in ipairs(scenes[4].particles.emitters) do
    if record.id == 1 then
      emitterOne = record
    end
  end
  Assert.notNil(emitterOne, "HeartGold scene 4 keeps its source emitter 1")
  Assert.notNil(emitterOne.child, "HeartGold emitter 1 keeps its child block")
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
        animate = true,
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
  -- A blend timeline owns the five fixed compositor targets alongside the
  -- two role targets and the town scratch: eight standing source canvases
  -- at most, every one exactly 256x192.
  Assert.equal(
    movieCalls,
    8,
    "a town-staging movie keeps two role targets plus five compositor targets plus one fixed town scratch"
  )
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
  -- The v5 town section retires through its authored seven-wipe order with
  -- effect-gated closes, so the stop is addressed by step identity: walking
  -- to the panels beat proves every close wait completed, the final main
  -- close holds black, and the sub reveal keeps the panels lit.
  for _, stepId in ipairs({
    "close-new-bark-town",
    "show-goldenrod-city",
    "close-goldenrod-city",
    "show-ecruteak-city",
    "close-ecruteak-city",
    "rival",
    "panels",
  }) do
    advanceToSceneStep(movie, 3, stepId, 20000)
  end
  movie:draw()
  local stopped = drawBytes(movie, scope, 512, 384)
  Assert.isTrue(lowerLitCells(stopped) > 500, "the sub panels persist past the town stop")
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

-- Separate 5-bit mix of the raw top and raw under channels with the two
-- independently saturated source weights, clamped to the channel ceiling.
-- The oracle is transcribed from the hardware blend law, never from the
-- runtime helper under test.
---@param top integer 5-bit top channel
---@param under integer 5-bit under channel
---@param firstWeight integer raw first-target coefficient
---@param secondWeight integer raw second-target coefficient
---@return integer blended 5-bit channel
local function dualBlendChannel(top, under, firstWeight, secondWeight)
  return math.min(31, math.floor((top * math.min(firstWeight, 16) + under * math.min(secondWeight, 16)) / 16))
end

---@param value number normalized channel in 0..1
---@return integer quantized 5-bit channel
local function fiveBitChannel(value)
  return math.max(0, math.min(31, math.floor(value * 31 + 0.5)))
end

local function synthetic_dual_coefficients_saturate_both_weights_per_pixel(scope)
  local root = sceneArtRoot(1)
  local frontImage = root .. "layers/dual-front.png"
  local midImage = root .. "layers/dual-mid.png"
  local backImage = root .. "layers/dual-back.png"
  local grayImage = root .. "layers/dual-gray.png"
  local probeClip = root .. "sprites/dual-probe.g4sprite"
  local art = {
    [frontImage] = solidPng(256, 192, 255, 0, 0),
    [midImage] = solidPng(256, 192, 0, 255, 0),
    [backImage] = solidPng(256, 192, 0, 0, 255),
    [grayImage] = solidPng(256, 192, 128, 128, 128),
    [probeClip] = solidPng(128, 96, 0, 255, 255),
  }
  local scenes, cacheFs = compositePack(
    compositeScene(
      1,
      {
        compositeLayer(2, backImage, 256, 192, true, 2),
        compositeLayer(1, midImage, 256, 192, true, 1),
        compositeLayer(0, frontImage, 256, 192, true, 0),
      },
      { compositeLayer(0, grayImage, 256, 192) },
      { compositeClip(probeClip, { compositeFrame(0, 0, 128, 96, 0, 0, 1) }) },
      { seed = 0, emitters = {} },
      { { id = "hold", events = { 1, 2, 3, 4, 5, 6, 7 }, ["until"] = { kind = "duration", ticks = 40 } } },
      {
        {
          op = "setBlend",
          stepId = "hold",
          atStepTick = 0,
          engine = "main",
          firstMask = 17,
          secondMask = 2,
          direction = 0,
          effect = "dual-cross",
          ticks = 31,
        },
        {
          op = "setSpriteClip",
          stepId = "hold",
          atStepTick = 0,
          instanceId = "probe",
          engine = "main",
          x = 128,
          y = 0,
          drawOrder = 0,
          clipId = probeClip,
          animate = true,
        },
        {
          op = "spriteVisible",
          stepId = "hold",
          atStepTick = 0,
          instanceId = "probe",
          engine = "main",
          x = 128,
          y = 0,
          drawOrder = 0,
          visible = true,
        },
        {
          op = "window",
          stepId = "hold",
          atStepTick = 0,
          engine = "main",
          from = { x1 = 128, y1 = 0, x2 = 255, y2 = 191 },
          to = { x1 = 128, y1 = 0, x2 = 255, y2 = 191 },
          ticks = 40,
          insideMask = 23,
          outsideMask = 22,
        },
        { op = "enableSkip", stepId = "hold", atStepTick = 10 },
        { op = "waitTicks", stepId = "hold", atStepTick = 0, ticks = 40 },
        { op = "finish", stepId = "hold", atStepTick = 40 },
      }
    ),
    art,
    solidPng(16, 16, 128, 128, 128)
  )
  local movie = openCompositeMovie(scope, scenes, cacheFs, 512, 384, "dual")
  -- The dual stage carries the main target on its upper pane: the source
  -- texel is half the host column and half the cropped host row, so the
  -- left guard reads source (32, 96), the sprite point source (160, 72),
  -- and the blend point source (160, 120).
  local function sampleAt(x, y)
    return samplePixel(scope, movie, 512, 384, x, y)
  end
  -- At the opening tick the first weight is zero, so every eligible pair
  -- shows its raw under pixel while the masked region stays raw middle.
  local lr, lg, lb = sampleAt(64, 96)
  Assert.near(lg, 1, 0.06, "the masked region shows the raw middle plane at the opening tick")
  Assert.near(lr, 0, 0.06, "no masked top red leaks at the opening tick")
  Assert.near(lb, 0, 0.06, "no lower blue leaks at the opening tick")
  -- The sprite pair is not eligible: its red under plane is outside the
  -- second mask, so the sprite paints unchanged at every tick while the
  -- masked region stays raw middle.
  local or_, og, ob = sampleAt(320, 48)
  Assert.near(or_, 0, 0.1, "the unselected under plane leaves the sprite raw at the opening tick")
  Assert.near(og, 1, 0.06, "the sprite keeps full green at the opening tick")
  Assert.near(ob, 1, 0.06, "the sprite keeps full blue at the opening tick")
  local br, bg, bb = sampleAt(320, 144)
  Assert.near(bg, 1, 0.06, "the blend pair shows its raw green under pixel at the opening tick")
  Assert.near(br, 0, 0.06, "no top red covers at the opening tick")
  Assert.near(bb, 0, 0.06, "no lower blue leaks into the blend at the opening tick")
  -- Fifteen of thirty-one steps: raw (15, 16), so both sides contribute
  -- near-fully and the mixed pixel outshines any single-weight overlap.
  advance(movie, 15)
  lr, lg, lb = sampleAt(64, 96)
  Assert.near(lg, 1, 0.06, "the masked region stays raw middle through the blend")
  Assert.near(lr, 0, 0.06, "the masked top never blends where its window hides it")
  or_, og, ob = sampleAt(320, 48)
  Assert.isTrue(or_ < 0.04, "the unselected under plane never tints the sprite")
  Assert.near(og, 1, 0.06, "the sprite keeps full green at fifteen steps")
  Assert.near(ob, 1, 0.06, "the sprite keeps full blue at fifteen steps")
  br, bg, bb = sampleAt(320, 144)
  Assert.near(br, 29 / 31, 0.08, "the top keeps its red share at fifteen steps")
  Assert.near(bg, 1, 0.06, "the under keeps its full green share at fifteen steps")
  Assert.near(bb, 0, 0.06, "no lower blue leaks into the blend at fifteen steps")
  -- Sixteen steps saturates the first side: raw (16, 15).
  advance(movie, 1)
  or_, og, ob = sampleAt(320, 48)
  Assert.isTrue(or_ < 0.04, "the sprite stays untinted at sixteen steps")
  Assert.near(og, 1, 0.06, "the sprite keeps full green at sixteen steps")
  Assert.near(ob, 1, 0.06, "the sprite keeps full blue at sixteen steps")
  br, bg, bb = sampleAt(320, 144)
  Assert.near(br, 1, 0.06, "the saturated first side keeps full red at sixteen steps")
  Assert.near(bg, 29 / 31, 0.08, "the under keeps its green share at sixteen steps")
  -- The final step retires to the raw top pixel on both pairs.
  advance(movie, 15)
  or_, og, ob = sampleAt(320, 48)
  Assert.isTrue(or_ < 0.04, "the sprite stays untinted at the final tick")
  Assert.near(og, 1, 0.06, "the sprite keeps full green at the final tick")
  Assert.near(ob, 1, 0.06, "the sprite keeps full blue at the final tick")
  br, bg, bb = sampleAt(320, 144)
  Assert.near(br, 1, 0.06, "the blend retires to the raw top red")
  Assert.near(bg, 0, 0.06, "no under green survives the final tick")
  lr, lg, lb = sampleAt(64, 96)
  Assert.near(lg, 1, 0.06, "the masked region stays raw middle at the final tick")
end

local function synthetic_masked_pairs_use_raw_under_pixels_without_cascading(scope)
  local root = sceneArtRoot(1)
  local frontImage = root .. "layers/pair-front.png"
  local midImage = root .. "layers/pair-mid.png"
  local backImage = root .. "layers/pair-back.png"
  local grayImage = root .. "layers/pair-gray.png"
  local art = {
    [frontImage] = solidPng(256, 192, 255, 0, 0),
    [midImage] = solidPng(256, 192, 0, 255, 0),
    [backImage] = solidPng(256, 192, 0, 0, 255),
    [grayImage] = solidPng(256, 192, 128, 128, 128),
  }
  local scenes, cacheFs = compositePack(
    compositeScene(
      1,
      {
        compositeLayer(2, backImage, 256, 192, true, 2),
        compositeLayer(1, midImage, 256, 192, true, 1),
        compositeLayer(0, frontImage, 256, 192, true, 0),
      },
      { compositeLayer(0, grayImage, 256, 192) },
      {},
      { seed = 0, emitters = {} },
      { { id = "hold", events = { 1, 2, 3, 4 }, ["until"] = { kind = "duration", ticks = 40 } } },
      {
        {
          op = "setBlend",
          stepId = "hold",
          atStepTick = 0,
          engine = "main",
          firstMask = 3,
          secondMask = 4,
          direction = 0,
          effect = "masked-pair",
          ticks = 31,
        },
        { op = "enableSkip", stepId = "hold", atStepTick = 10 },
        { op = "waitTicks", stepId = "hold", atStepTick = 0, ticks = 40 },
        { op = "finish", stepId = "hold", atStepTick = 40 },
      }
    ),
    art,
    solidPng(16, 16, 128, 128, 128)
  )
  local movie = openCompositeMovie(scope, scenes, cacheFs, 512, 384, "dual")
  -- The middle plane is eligible as a first target over the back plane,
  -- yet the top pixel must still pair with its raw middle under pixel,
  -- which the second mask does not select: the frame stays pure red.
  local function sampleCenter()
    return samplePixel(scope, movie, 512, 384, 256, 96)
  end
  local r, g, b = sampleCenter()
  Assert.near(r, 1, 0.06, "the unselected under plane blocks the pair at the opening tick")
  Assert.isTrue(g < 0.04, "no middle green shows at the opening tick")
  Assert.isTrue(b < 0.04, "no back blue shows at the opening tick")
  advance(movie, 15)
  r, g, b = sampleCenter()
  Assert.near(r, 1, 0.06, "the unselected under plane blocks the pair at fifteen steps")
  Assert.isTrue(g < 0.04, "no middle green tints the blocked top pixel")
  Assert.isTrue(b < 0.04, "no cascaded back blue leaks through the lower blend")
  advance(movie, 1)
  r, g, b = sampleCenter()
  Assert.near(r, 1, 0.06, "the blocked pair stays pure red at sixteen steps")
  Assert.isTrue(g < 0.04, "no middle green tints at sixteen steps")
  Assert.isTrue(b < 0.04, "no cascaded back blue leaks at sixteen steps")
  advance(movie, 15)
  r, g, b = sampleCenter()
  Assert.near(r, 1, 0.06, "the blocked pair retires to the raw top red")
  Assert.isTrue(g < 0.04, "no middle green survives the final tick")
  Assert.isTrue(b < 0.04, "no back blue survives the final tick")
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
  -- The v5 town section retires through its authored seven-wipe order with
  -- effect-gated closes, so the stop is addressed by step identity: walking
  -- to the panels beat proves every close wait completed, the final main
  -- close holds black, and the sub reveal keeps the panels lit.
  for _, stepId in ipairs({
    "close-new-bark-town",
    "show-goldenrod-city",
    "close-goldenrod-city",
    "show-ecruteak-city",
    "close-ecruteak-city",
    "rival",
    "panels",
  }) do
    advanceToSceneStep(movie, 3, stepId, 20000)
  end
  movie:draw()
  local stopBytes = drawBytes(movie, scope, 512, 384)
  Assert.isTrue(lowerLitCells(stopBytes) > 500, "the rival beat keeps the sub panels lit")
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
    { step = "run-chikorita", mainPhysical = "lower" },
    { step = "run-cyndaquil", mainPhysical = "upper" },
    { step = "run-totodile", mainPhysical = "lower" },
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
  advanceToSceneStep(single, 4, "run-cyndaquil", 20000)
  advance(single, 4)
  Assert.equal(currentStepId(single), "run-cyndaquil", "the single-surface movie holds its emitter beat")
  Assert.equal(single.current.mainPhysical, "upper", "the cyndaquil beat maps main to upper")
  for _, layout in ipairs({
    { width = 600, height = 1000, first = { 300, 250 }, second = { 300, 750 }, name = "tall" },
    { width = 1200, height = 600, first = { 300, 300 }, second = { 900, 300 }, name = "wide" },
    { width = 512, height = 384, first = { 256, 96 }, second = { 256, 288 }, name = "nativeLike" },
  }) do
    single:resize(layout.width, layout.height)
    Assert.equal(single:sceneNumber(), 4, layout.name .. " keeps the movie on its scene")
    Assert.equal(currentStepId(single), "run-cyndaquil", layout.name .. " keeps the movie on its beat")
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
  Assert.equal(stepEffect("run-chikorita"), "emitters-grass", "the first starter waits on its grass emitters")
  Assert.equal(stepEffect("run-cyndaquil"), "emitters-fire", "the second starter waits on its fire emitters")
  local movie = openMovie(scope, versionId, 512, 384, "dual")
  local function liveParticles()
    local count = 0
    for _, runtime in ipairs(assert(movie.current.emitters, "the movie tracks its live emitters")) do
      count = count + #(runtime.particles or {})
    end
    return count
  end
  local mappings = {}
  for _, beat in ipairs({ "run-chikorita", "run-cyndaquil" }) do
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

-- The scene-4 close retires every starter and holds both engines black
-- into the sparkle: the last close tick still shows a fully masked pair,
-- and only the dispatched sparkle clears physical TOP while the main
-- target on the bottom pane retains its black hold.
local function scene4_close_retires_starters_and_holds_black_until_top_neutral(scope, context)
  local versionId = selectedVersionId(context)
  local movie = openMovie(scope, versionId, 512, 384, "dual")
  advanceToSceneStep(movie, 4, "finish-totodile", 20000)
  local guard = 0
  while currentStepId(movie) == "finish-totodile" and guard < 200 do
    movie:updateFixed()
    guard = guard + 1
  end
  Assert.equal(currentStepId(movie), "sparkle", "the retired close hands off to sparkle")
  movie:draw()
  local retiredMain = sourceBytes(scope, movie.mainCanvas)
  local retiredSub = sourceBytes(scope, movie.subCanvas)
  Assert.isTrue(
    regionLit(retiredMain, 256, 0, 255, 0, 191) < 0.02,
    "the retired main target holds black into sparkle"
  )
  Assert.isTrue(
    regionLit(retiredSub, 256, 0, 255, 0, 191) < 0.02,
    "the retired sub target still holds black before the TOP reset"
  )
  movie:updateFixed()
  Assert.equal(currentStepId(movie), "sparkle", "the sparkle dispatches on the tick after retirement")
  movie:draw()
  local sparkleMain = sourceBytes(scope, movie.mainCanvas)
  local sparkleSub = sourceBytes(scope, movie.subCanvas)
  Assert.isTrue(
    regionLit(sparkleMain, 256, 0, 255, 0, 191) < 0.02,
    "the bottom pane retains black while the sparkle plays"
  )
  Assert.isTrue(sparkleSub ~= retiredSub, "resetting physical TOP releases only the top target")
  movie:dispose()
end

-- Each starter beat separates its appear frame from emission and its run
-- from the flip: the appear tick shows its sprite with no live emitter,
-- the run holds its mapping, and only the finish dispatch moves main.
local function scene4_starter_beats_hold_emission_and_flip_until_their_cases(scope, context)
  local versionId = selectedVersionId(context)
  local movie = openMovie(scope, versionId, 512, 384, "dual")
  advanceToSceneStep(movie, 4, "appear-chikorita", 20000)
  movie:updateFixed()
  Assert.equal(currentStepId(movie), "start-chikorita", "the appear lasts one source tick")
  local appearSprite = assert(movie.current.spriteInstances.chikorita, "the appear stages its starter")
  Assert.isTrue(appearSprite.visible, "the appear shows its starter")
  local appearLive = 0
  for _, runtime in ipairs(assert(movie.current.emitters, "the movie tracks its live emitters")) do
    appearLive = appearLive + #(runtime.particles or {})
    Assert.isFalse(runtime.group == "grass", "the appear frame runs no grass emitter")
  end
  Assert.equal(appearLive, 0, "the appear tick starts no emitter")
  Assert.equal(movie.current.mainPhysical, "lower", "the appear flips no screen")
  advanceToSceneStep(movie, 4, "run-chikorita", 20000)
  advance(movie, 3)
  Assert.equal(currentStepId(movie), "run-chikorita", "the run holds across its emitter beat")
  local runLive = 0
  for _, runtime in ipairs(assert(movie.current.emitters, "the movie tracks its run emitters")) do
    runLive = runLive + #(runtime.particles or {})
  end
  Assert.isTrue(runLive > 0, "the run samples live emitters")
  Assert.equal(movie.current.mainPhysical, "lower", "the run flips no screen before its finish")
  advanceToSceneStep(movie, 4, "finish-chikorita", 20000)
  Assert.equal(movie.current.mainPhysical, "lower", "the flip waits for its finish dispatch")
  movie:updateFixed()
  Assert.equal(movie.current.mainPhysical, "upper", "the finish dispatch moves main upper")
  movie:dispose()
end

-- The authored scene-4 shutters keep the source row geometry on both
-- engines: the 09 open reveals center-out over 10 source steps and the
-- 08 close masks outer-in over 26, with revealed rows matching the
-- settled art and masked rows holding black.
local function scene4_authored_shutters_match_source_rows_on_both_engines(scope, context)
  local versionId = selectedVersionId(context)
  local movie = openMovie(scope, versionId, 512, 384, "dual")
  local function rowEdgeOf(frameBytes, y)
    local parts = {}
    for _, x in ipairs({ 32, 224 }) do
      local r, g, b = pixelOf(frameBytes, 256, x, y)
      parts[#parts + 1] = string.format("%.2f,%.2f,%.2f", r, g, b)
    end
    return table.concat(parts, "|")
  end
  local function assertRowBlack(canvas, y, label)
    for _, x in ipairs({ 32, 128, 224 }) do
      local r, g, b = pixelOf(sourceBytes(scope, canvas), 256, x, y)
      assertSameColor(r, g, b, 0, 0, 0, 0.08, label .. " masks row " .. y)
    end
  end
  advanceToSceneStep(movie, 4, "fade-in", 20000)
  movie:updateFixed()
  Assert.equal(currentStepId(movie), "fade-in", "the open beat dispatches its first frame")
  movie:draw()
  local openFirstMain, openFirstSub = sourceBytes(scope, movie.mainCanvas), sourceBytes(scope, movie.subCanvas)
  assertRowBlack(movie.mainCanvas, 8, "the open first frame on main")
  assertRowBlack(movie.mainCanvas, 180, "the open first frame on main")
  assertRowBlack(movie.subCanvas, 8, "the open first frame on sub")
  assertRowBlack(movie.subCanvas, 180, "the open first frame on sub")
  advance(movie, 4)
  Assert.equal(currentStepId(movie), "fade-in", "the open holds its fifth frame")
  movie:draw()
  local openMidMain = sourceBytes(scope, movie.mainCanvas)
  assertRowBlack(movie.mainCanvas, 8, "the open middle frame on main")
  assertRowBlack(movie.mainCanvas, 180, "the open middle frame on main")
  assertRowBlack(movie.subCanvas, 8, "the open middle frame on sub")
  assertRowBlack(movie.subCanvas, 180, "the open middle frame on sub")
  Assert.equal(
    rowEdgeOf(openMidMain, 96),
    rowEdgeOf(openFirstMain, 96),
    "the revealed center holds still while the mask runs"
  )
  advance(movie, 5)
  Assert.equal(currentStepId(movie), "slide-in", "the open completes into its slide on step ten")
  movie:draw()
  local openDoneMain, openDoneSub = sourceBytes(scope, movie.mainCanvas), sourceBytes(scope, movie.subCanvas)
  Assert.equal(
    rowEdgeOf(openMidMain, 60),
    rowEdgeOf(openDoneMain, 60),
    "the revealed mid rows match the settled art on main"
  )
  Assert.equal(
    rowEdgeOf(openDoneMain, 96),
    rowEdgeOf(openFirstMain, 96),
    "the revealed center matches the settled art on main"
  )
  Assert.equal(
    rowEdgeOf(openDoneSub, 96),
    rowEdgeOf(openFirstSub, 96),
    "the revealed center matches the settled art on sub"
  )
  Assert.isTrue(openDoneMain ~= openFirstMain, "the open actually reveals main art")
  Assert.isTrue(openDoneSub ~= openFirstSub, "the open actually reveals sub art")
  advanceToSceneStep(movie, 4, "run-totodile", 20000)
  local guard = 0
  while currentStepId(movie) == "run-totodile" and guard < 5000 do
    movie:updateFixed()
    guard = guard + 1
  end
  Assert.equal(currentStepId(movie), "finish-totodile", "the retired close starts its finish")
  movie:draw()
  local closeEntryMain = sourceBytes(scope, movie.mainCanvas)
  movie:updateFixed()
  Assert.equal(currentStepId(movie), "finish-totodile", "the close holds its first frame")
  movie:draw()
  assertRowBlack(movie.mainCanvas, 1, "the close first frame on main")
  assertRowBlack(movie.mainCanvas, 190, "the close first frame on main")
  assertRowBlack(movie.subCanvas, 1, "the close first frame on sub")
  assertRowBlack(movie.subCanvas, 190, "the close first frame on sub")
  Assert.equal(
    rowEdgeOf(sourceBytes(scope, movie.mainCanvas), 96),
    rowEdgeOf(closeEntryMain, 96),
    "the close first frame keeps its revealed center"
  )
  advance(movie, 12)
  Assert.equal(currentStepId(movie), "finish-totodile", "the close holds its middle frame")
  movie:draw()
  assertRowBlack(movie.mainCanvas, 8, "the close middle frame on main")
  assertRowBlack(movie.mainCanvas, 180, "the close middle frame on main")
  assertRowBlack(movie.subCanvas, 8, "the close middle frame on sub")
  assertRowBlack(movie.subCanvas, 180, "the close middle frame on sub")
  guard = 0
  while currentStepId(movie) == "finish-totodile" and guard < 200 do
    movie:updateFixed()
    guard = guard + 1
  end
  Assert.equal(currentStepId(movie), "sparkle", "the close completes into sparkle on step twenty-six")
  movie:draw()
  assertRowBlack(movie.mainCanvas, 8, "the close final frame on main")
  assertRowBlack(movie.mainCanvas, 96, "the close final frame on main")
  assertRowBlack(movie.mainCanvas, 180, "the close final frame on main")
  assertRowBlack(movie.subCanvas, 8, "the close final frame on sub")
  assertRowBlack(movie.subCanvas, 96, "the close final frame on sub")
  assertRowBlack(movie.subCanvas, 180, "the close final frame on sub")
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
  -- The reached case first runs on the following update: dispatch the
  -- sunrise entry before sampling its lit beat.
  movie:updateFixed()
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
  advanceToSceneStep(movie, 4, "run-cyndaquil", 20000)
  advance(movie, 3)
  sampleBeat("scene 4 starter")
  advanceToSceneStep(movie, 5, "wait-bg-scroll", 20000)
  -- The scrolled panorama starts once the ordered shutter and its cleanup
  -- complete, so sample the running scroll programs on the scroll-wait beat.
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
  -- The reached case first runs on the following update: displace the
  -- entry programs there, then sample the dispatched frame.
  movie:updateFixed()
  -- The sourced flyin opens with two immediate placements plus one
  -- open-ended drift tick: main BG0 sits 192 down, main BG1 320 down,
  -- and both drifts add 64 every fixed tick.
  local entry = currentScrollOffsets(movie)
  Assert.equal(entry.main0, 192, "the immediate main BG0 placement lands on the first frame")
  Assert.equal(entry.main1, 320, "the immediate main BG1 placement lands on the first frame")
  Assert.equal(entry.main2, 64, "the open-ended drift advances on its dispatch update")
  movie:draw()
  local drawn = currentScrollOffsets(movie)
  Assert.equal(drawn.main0, 192, "a host draw never resamples the immediate placement")
  for _ = 1, 9 do
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

-- Front-to-back visible stack with staged art for one source engine.
---@param scope table test scope owning the decoded art
---@param cacheFs table staged art backing the scenes
---@param slot table running scene slot
---@param engine string source engine owning the planes
---@return table[] visible planes with wrapped art, front first
local function sunriseStack(scope, cacheFs, slot, engine)
  local ordered = {}
  for _, background in pairs(slot.backgrounds[engine]) do
    if background.visible then
      ordered[#ordered + 1] = background
    end
  end
  table.sort(ordered, function(a, b)
    if a.priority ~= b.priority then
      return a.priority > b.priority
    end
    return a.bgSlot < b.bgSlot
  end)
  local stack = {}
  for _, background in ipairs(ordered) do
    local bytes = assert(cacheFs:read(background.image), "the staged panel art reads back")
    local data = decodedArt(scope, bytes, background.image)
    stack[#stack + 1] = {
      background = background,
      data = data,
      width = data:getWidth(),
      height = data:getHeight(),
    }
  end
  return stack
end

---@param value integer target pixel coordinate
---@param extent integer art extent along that axis
---@param scroll number live signed source scroll
---@return integer wrapped art texel
local function sunriseTexel(value, extent, scroll)
  return (value + math.floor(scroll)) % extent
end

-- First target pixel whose raw top and raw under texels are both opaque,
-- differ decisively, and separate the dual mix from a single top weight,
-- skipping sprite-covered and translucent pixels.
---@param scope table test scope owning the decoded art
---@param cacheFs table staged art backing the scenes
---@param slot table running scene slot
---@param engine string source engine owning the planes
---@param spriteRects table[] sprite coverage in target pixels
---@param firstWeight integer raw first-target coefficient
---@param secondWeight integer raw second-target coefficient
---@param minSeparation integer required oracle/top 5-bit separation
---@param firstMask integer required first-target plane mask
---@param secondMask integer required second-target plane mask
---@return table? decisive sample with quantized top/under channels and plane slots
local function sunriseDecisivePixel(scope, cacheFs, slot, engine, spriteRects, firstWeight, secondWeight,
  minSeparation, firstMask, secondMask)
  local stack = sunriseStack(scope, cacheFs, slot, engine)
  for y = 0, 191, 4 do
    for x = 0, 255, 4 do
      local covered = false
      for _, rect in ipairs(spriteRects) do
        if x >= rect.x and x < rect.x + rect.w and y >= rect.y and y < rect.y + rect.h then
          covered = true
          break
        end
      end
      if not covered then
        -- The plane pass paints lower numeric priorities later, so the
        -- front of the stack is its lowest priority entry.
        local top, under, topSlot, underSlot = nil, nil, nil, nil
        local settled = true
        for index = #stack, 1, -1 do
          local entry = stack[index]
          local sx = sunriseTexel(x, entry.width, entry.background.scrollX)
          local sy = sunriseTexel(y, entry.height, entry.background.scrollY)
          local r, g, b, a = entry.data:getPixel(sx, sy)
          if a > 0.98 then
            local quantized = { fiveBitChannel(r), fiveBitChannel(g), fiveBitChannel(b) }
            if top == nil then
              top = quantized
              topSlot = entry.background.bgSlot
            else
              under = quantized
              underSlot = entry.background.bgSlot
              break
            end
          elseif a > 0.02 then
            settled = false
            break
          end
        end
        if settled and top ~= nil and under ~= nil then
          local distance = 0
          local separation = 0
          for channel = 1, 3 do
            distance = math.max(distance, math.abs(top[channel] - under[channel]))
            separation = math.max(
              separation,
              math.abs(dualBlendChannel(top[channel], under[channel], firstWeight, secondWeight) - top[channel])
            )
          end
          -- The hardware blends only when the top plane is first-selected
          -- and the raw under plane is second-selected; an unselected
          -- under plane blocks the pair and the top shows raw, so the
          -- oracle must hold an eligible pair to predict a mix.
          local topSelected = math.floor(firstMask / (2 ^ topSlot)) % 2 == 1
          local underSelected = math.floor(secondMask / (2 ^ underSlot)) % 2 == 1
          if distance >= 6 and separation >= minSeparation and topSelected and underSelected then
            return { x = x, y = y, top = top, under = under, topSlot = topSlot, underSlot = underSlot }
          end
        end
      end
    end
  end
  return nil
end

-- First front-opaque top texel in target pixels, skipping translucent stacks.
---@param scope table test scope owning the decoded art
---@param cacheFs table staged art backing the scenes
---@param slot table running scene slot
---@param engine string source engine owning the planes
---@return table? sample with target coords and quantized top channels
local function sunriseTopTexel(scope, cacheFs, slot, engine)
  local stack = sunriseStack(scope, cacheFs, slot, engine)
  for y = 0, 191, 4 do
    for x = 0, 255, 4 do
      local settled = true
      local top = nil
      for index = #stack, 1, -1 do
        local entry = stack[index]
        local sx = sunriseTexel(x, entry.width, entry.background.scrollX)
        local sy = sunriseTexel(y, entry.height, entry.background.scrollY)
        local r, g, b, a = entry.data:getPixel(sx, sy)
        if a > 0.98 then
          top = { fiveBitChannel(r), fiveBitChannel(g), fiveBitChannel(b) }
          break
        elseif a > 0.02 then
          settled = false
          break
        end
      end
      if settled and top ~= nil then
        return { x = x, y = y, top = top }
      end
    end
  end
  return nil
end

-- Source sprite coverage in target pixels for one engine.
---@param slot table running scene slot
---@param engine string source engine owning the sprites
---@return table[] sprite rectangles in target pixels
local function sunriseSpriteRects(slot, engine)
  local rects = {}
  for _, instanceId in ipairs(slot.spriteOrder) do
    local instance = slot.spriteInstances[instanceId]
    if instance ~= nil and instance.engine == engine and instance.visible and instance.clipId ~= nil then
      local clip = nil
      for _, candidate in ipairs(slot.manifest.spriteClips) do
        if candidate.id == instance.clipId then
          clip = candidate
          break
        end
      end
      local frame = clip ~= nil and clip.frames ~= nil and clip.frames[1] or nil
      if frame ~= nil and frame.width ~= nil and frame.height ~= nil and frame.width > 0 and frame.height > 0 then
        rects[#rects + 1] = {
          x = math.floor(instance.x + (frame.offsetX or 0)),
          y = math.floor(instance.y + (frame.offsetY or 0)),
          w = frame.width,
          h = frame.height,
        }
      end
    end
  end
  return rects
end

---@param scope table test scope owning the readback
---@param canvas love.Canvas fixed source engine target
---@param sample table decisive sample with quantized top/under channels
---@param firstWeight integer raw first-target coefficient
---@param secondWeight integer raw second-target coefficient
---@param label string engine label for diagnostics
local function assertSunrisePixel(scope, canvas, sample, firstWeight, secondWeight, label)
  local bytes = sourceBytes(scope, canvas)
  local ar, ag, ab = pixelOf(bytes, 256, sample.x, sample.y)
  local actual = { fiveBitChannel(ar), fiveBitChannel(ag), fiveBitChannel(ab) }
  local expected = {}
  for channel = 1, 3 do
    expected[channel] = dualBlendChannel(sample.top[channel], sample.under[channel], firstWeight, secondWeight)
  end
  for channel = 1, 3 do
    Assert.near(
      actual[channel] / 31,
      expected[channel] / 31,
      0.12,
      label .. " channel " .. channel .. " matches the dual-coefficient mix"
    )
  end
end

local function sunrise_blend_uses_both_source_masks(scope, versionId)
  local scenes, cacheFs = loadRomPackWithFillers(versionId, { 3, 4, 5 })
  local movie = openMovieWithCache(scope, scenes, cacheFs, versionId, 512, 384, "single")
  advanceToSceneStep(movie, 1, "scroll", 20000)
  -- The reached case first runs on the following update: dispatch the
  -- scroll entry so the blend programs own their engines before sampling.
  movie:updateFixed()
  local slot = assert(movie.current, "the running movie owns its current slot")
  local mainProgram = assert(slot.blendPrograms.main, "the sunrise step blends the main engine")
  local subProgram = assert(slot.blendPrograms.sub, "the sunrise step blends the sub engine")
  Assert.equal(mainProgram.firstMask, 1, "the sunrise blends the main top plane")
  Assert.equal(mainProgram.secondMask, 30, "the sunrise blends main planes under the top")
  Assert.equal(subProgram.firstMask, 2, "the sunrise blends the sub second plane independently")
  Assert.equal(subProgram.secondMask, 30, "the sunrise blends sub planes under the top")
  Assert.equal(mainProgram.direction, 1, "the sunrise counts its main coefficients down")
  Assert.equal(subProgram.direction, 1, "the sunrise counts its sub coefficients down")
  Assert.equal(mainProgram.ticks, 80, "the sunrise holds its authored main duration")
  Assert.equal(subProgram.ticks, 80, "the sunrise holds its authored sub duration")
  -- At step entry both coefficients sit at their ends: the first side is
  -- full, so the main stack shows its raw top texel while the sub stack
  -- falls through its transparent selected plane to its raw back plane.
  movie:draw()
  local mainEntry = sunriseDecisivePixel(
    scope,
    cacheFs,
    slot,
    "main",
    sunriseSpriteRects(slot, "main"),
    16,
    0,
    0,
    mainProgram.firstMask,
    mainProgram.secondMask
  )
  Assert.notNil(mainEntry, "the main stack holds a decisive blend pixel")
  mainEntry = assert(mainEntry, "the main stack holds a decisive blend pixel")
  local mainBytes = sourceBytes(scope, movie.mainCanvas)
  local mar, mag, mab = pixelOf(mainBytes, 256, mainEntry.x, mainEntry.y)
  Assert.near(mar, mainEntry.top[1] / 31, 0.1, "the main blend opens on its raw top red")
  Assert.near(mag, mainEntry.top[2] / 31, 0.1, "the main blend opens on its raw top green")
  Assert.near(mab, mainEntry.top[3] / 31, 0.1, "the main blend opens on its raw top blue")
  local subEntry = sunriseTopTexel(scope, cacheFs, slot, "sub")
  Assert.notNil(subEntry, "the sub stack shows its back plane through the transparent top")
  subEntry = assert(subEntry, "the sub stack shows its back plane through the transparent top")
  local subBytes = sourceBytes(scope, movie.subCanvas)
  local sar, sag, sab = pixelOf(subBytes, 256, subEntry.x, subEntry.y)
  Assert.near(sar, subEntry.top[1] / 31, 0.1, "the sub blend opens on its raw back red")
  Assert.near(sag, subEntry.top[2] / 31, 0.1, "the sub blend opens on its raw back green")
  Assert.near(sab, subEntry.top[3] / 31, 0.1, "the sub blend opens on its raw back blue")
  -- Forty steps in, raw (31-ev, ev) saturates the first side while the
  -- second side stays near-full: both main planes contribute, which a
  -- single weight cannot reproduce, while sub still shows its raw stack.
  advance(movie, 40)
  slot = assert(movie.current, "the running movie owns its current slot")
  Assert.equal(currentStepId(movie), "scroll", "the sunrise blend still runs at forty steps")
  local mainProgram = assert(slot.blendPrograms.main, "the sunrise blends the main engine")
  local mainEv = math.min(31, math.floor(mainProgram.elapsed * 31 / mainProgram.ticks))
  Assert.equal(mainEv, 15, "the main blend sits mid-transition at forty steps")
  local mainSample =
    sunriseDecisivePixel(
      scope,
      cacheFs,
      slot,
      "main",
      sunriseSpriteRects(slot, "main"),
      16,
      15,
      5,
      mainProgram.firstMask,
      mainProgram.secondMask
    )
  Assert.notNil(mainSample, "the main stack holds a decisive mid-blend pixel")
  mainSample = assert(mainSample, "the main stack holds a decisive mid-blend pixel")
  movie:draw()
  assertSunrisePixel(scope, movie.mainCanvas, mainSample, 31 - mainEv, mainEv, "main")
  local subSample = sunriseTopTexel(scope, cacheFs, slot, "sub")
  Assert.notNil(subSample, "the sub stack still shows its back plane mid-blend")
  subSample = assert(subSample, "the sub stack still shows its back plane mid-blend")
  local midSubBytes = sourceBytes(scope, movie.subCanvas)
  local mbr, mbg, mbb = pixelOf(midSubBytes, 256, subSample.x, subSample.y)
  Assert.near(mbr, subSample.top[1] / 31, 0.1, "the sub stack stays raw while main blends red")
  Assert.near(mbg, subSample.top[2] / 31, 0.1, "the sub stack stays raw while main blends green")
  Assert.near(mbb, subSample.top[3] / 31, 0.1, "the sub stack stays raw while main blends blue")
  movie:dispose()
end

local function soulsilver_sunrise_blend_uses_both_source_masks(scope, context)
  local versionId = selectedVersionId(context)
  sunrise_blend_uses_both_source_masks(scope, versionId)
end

local function heartgold_sunrise_blend_is_blocked_without_a_dump(scope, context)
  if not RomImporter.isReady("heartgold") then
    context:skip(
      "BLOCKED: HeartGold sunrise blend needs a user-owned HeartGold dump; "
        .. "only SoulSilver is ready here, so the per-engine coefficient and mask legs "
        .. "cannot run for HeartGold and are never faked"
    )
  end
  sunrise_blend_uses_both_source_masks(scope, "heartgold")
end


---@param scope table
---@param versionId string selected edition identity
local function sourced_panorama_pixels_match_wrapped_source_art(scope, versionId)
  local scenes, cacheFs = loadRomPackWithFillers(versionId, { 3, 4 })
  local movie = openMovieWithCache(scope, scenes, cacheFs, versionId, 512, 384, "single")
  advanceToSceneStep(movie, 5, "wait-bg-scroll", 20000)
  -- The wipe-step programs retire with the ordered shutter, so the lit
  -- baseline is sampled once the engine targets show the panorama and
  -- before the concurrent white fade begins: five sampling ticks stay
  -- inside the twenty-tick scroll wait.
  for _ = 1, 5 do
    movie:updateFixed()
    movie:draw()
  end
  movie:draw()
  local startMain = sourceBytes(scope, movie.mainCanvas)
  Assert.isTrue(
    regionLit(startMain, 256, 0, 255, 0, 191) > 0.2,
    "the scroll beat lights the main source target"
  )
  -- The sourced panorama pans every voiced panel across its run; sample
  -- the moved frame while the scroll programs still own the targets.
  for _ = 1, 10 do
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

local function soulsilver_source_wipe_slopes_with_the_scanline_without_spilling(scope, context)
  if not RomImporter.isReady("soulsilver") then
    context:skip("SoulSilver source wipe needs a user-owned SoulSilver ROM")
  end
  local versionId = "soulsilver"
  local romScenes = loadScenes(versionId)
  local wipeTicks, wipeStepId = nil, nil
  for _, event in ipairs(romScenes[2].timeline.events) do
    if event.op == "circleWipe" and event.engine == "main" then
      wipeTicks, wipeStepId = event.ticks, event.stepId
      break
    end
  end
  Assert.notNil(wipeTicks, "the sourced second scene carries its main wipe")
  local romMovie = openMovie(scope, versionId, 512, 384, "dual")
  advanceToSceneStep(romMovie, 2, wipeStepId, 20000)
  romMovie:draw()
  local romSubBefore = sourceBytes(scope, romMovie.subCanvas)
  advance(romMovie, math.max(1, math.floor(wipeTicks / 4)))
  romMovie:draw()
  local function romDifferingX(y)
    local r0, g0, b0 = pixelOf(sourceBytes(scope, romMovie.mainCanvas), 256, 0, y)
    for x = 4, 255, 4 do
      local r, g, b = pixelOf(sourceBytes(scope, romMovie.mainCanvas), 256, x, y)
      if math.abs(r - r0) > 0.08 or math.abs(g - g0) > 0.08 or math.abs(b - b0) > 0.08 then
        return x
      end
    end
    return 255
  end
  local romLow = romDifferingX(48)
  local romHigh = romDifferingX(96)
  Assert.isFalse(romLow == romHigh, "the sourced wipe slopes with the scanline")
  local romSubMid = sourceBytes(scope, romMovie.subCanvas)
  -- The sourced black-out holds the sub engine black through the wipe
  -- beat, so the wipe owns main alone: the sub target carries retained
  -- black before the wipe and the wipe leaves it byte-identical.
  Assert.isTrue(
    regionLit(romSubBefore, 256, 0, 255, 0, 191) < 0.05,
    "the sub engine keeps its retained black into the sourced wipe"
  )
  Assert.equal(romSubMid, romSubBefore, "the sourced wipe leaves the held sub engine untouched")
  romMovie:dispose()
end

-- Source-frame pixel conformance: every expected texel below is recomputed
-- in the test from the staged native art and the retail scroll/offset
-- arithmetic, never through the player sampler. Transparent staged texels
-- are legitimate masked content (the plane pass sees through them, so the
-- test falls through to the next plane exactly like the compositor);
-- opaque staged texels must match the rendered engine target, and an
-- opaque-bright texel rendering black fails as missing-coverage black.

---@param value number retail pixel displacement
---@return integer truncated toward zero, matching the C integer division
local function truncRetail(value)
  if value >= 0 then
    return math.floor(value)
  end
  return math.ceil(value)
end

---@param scope table
---@param movie table running opening movie
---@param cacheFs table staged art backing the scenes
---@param engine string source engine
---@return table[] visible staged panels front-to-back with decoded art
local function stagedPanels(scope, movie, cacheFs, engine)
  local slot = assert(movie.current, "the running movie owns its current slot")
  local panels = {}
  for _, background in pairs(slot.backgrounds[engine]) do
    if background.visible then
      local bytes = assert(cacheFs:read(background.image), "the staged panel art reads back")
      local data = decodedArt(scope, bytes, background.image)
      panels[#panels + 1] = {
        data = data,
        width = data:getWidth(),
        height = data:getHeight(),
        offsetX = math.floor(background.scrollX),
        offsetY = math.floor(background.scrollY),
        priority = background.priority,
        bgSlot = background.bgSlot,
      }
    end
  end
  -- Lowest numeric priority paints last, so it is frontmost; the higher
  -- slot breaks ties, mirroring the back-to-front plane pass.
  table.sort(panels, function(a, b)
    if a.priority ~= b.priority then
      return a.priority < b.priority
    end
    return a.bgSlot > b.bgSlot
  end)
  return panels
end

---@param panels table[] visible staged panels front-to-back
---@param x integer viewport column
---@param y integer viewport row
---@return number r, number g, number b expected source color
---@return boolean decisive true when an opaque authored texel owns the point
local function expectedWrapPixel(panels, x, y)
  for _, panel in ipairs(panels) do
    local sx = (x + panel.offsetX) % panel.width
    local sy = (y + panel.offsetY) % panel.height
    local r, g, b, a = panel.data:getPixel(sx, sy)
    if a > 0.98 then
      return r, g, b, true
    elseif a > 0.02 then
      return 0, 0, 0, false
    end
  end
  return 0, 0, 0, false
end

---@param box integer[] exclusion rectangle {x0, x1, y0, y1}
---@param x integer viewport column
---@param y integer viewport row
---@return boolean true when the point falls inside the box
local function insideBox(box, x, y)
  return x >= box[1] and x <= box[2] and y >= box[3] and y <= box[4]
end

-- Sprite exclusion boxes from the running slot state and the manifest
-- clip frames: points under a visible authored sprite stay out of the
-- background comparison. Reading positions from the player is fail-safe:
-- a misplaced sprite paints checked points and fails the match instead
-- of hiding inside an exclusion.
---@param movie table running opening movie
---@param manifest table compiled scene manifest carrying the clip frames
---@param margin integer exclusion margin in viewport pixels
---@return table[] exclusion boxes {x0, x1, y0, y1}
local function spriteExclusions(movie, manifest, margin)
  local slot = assert(movie.current, "the running movie owns its current slot")
  local clips = {}
  for _, candidate in ipairs(manifest.spriteClips or {}) do
    clips[candidate.id] = candidate
  end
  local boxes = {}
  for _, instance in pairs(slot.spriteInstances or {}) do
    if instance.visible and instance.clipId ~= nil then
      local clip = clips[instance.clipId]
      local frame = nil
      if clip ~= nil and type(clip.frames) == "table" and #clip.frames > 0 then
        local total = 0
        for _, entry in ipairs(clip.frames) do
          total = total + (entry.duration or 1)
        end
        local elapsed = (instance.tick or 0) % math.max(total, 1)
        for _, entry in ipairs(clip.frames) do
          local duration = entry.duration or 1
          if elapsed < duration then
            frame = entry
            break
          end
          elapsed = elapsed - duration
        end
        frame = frame or clip.frames[#clip.frames]
      end
      local width, height, offsetX, offsetY = 16, 16, 0, 0
      if frame ~= nil then
        width, height = frame.width or width, frame.height or height
        offsetX, offsetY = frame.offsetX or 0, frame.offsetY or 0
      end
      local x0, y0 = (instance.x or 0) + offsetX, (instance.y or 0) + offsetY
      boxes[#boxes + 1] = { x0 - margin, x0 + width + margin, y0 - margin, y0 + height + margin }
    end
  end
  return boxes
end

-- Compares one engine target against the wrapped native art at the
-- test-authored offsets. Every visible panel must carry an authored
-- expectation, so an unexpected plane fails instead of passing silently.
---@param scope table
---@param movie table running opening movie
---@param cacheFs table staged art backing the scenes
---@param engine string source engine
---@param expected table<integer, integer[]> authored offsets by bg slot
---@param label string assertion context
---@param opts table? {exclude, minDecisive}
local function assertEngineMatchesWrappedArt(scope, movie, cacheFs, manifest, engine, label, expected, opts)
  local options = opts or {}
  local margin = options.margin or 12
  local boxes = spriteExclusions(movie, manifest, margin)
  for _, box in ipairs(options.exclude or {}) do
    boxes[#boxes + 1] = box
  end
  local panels = stagedPanels(scope, movie, cacheFs, engine)
  Assert.isTrue(#panels > 0, label .. " stages at least one visible panel")
  for _, panel in ipairs(panels) do
    local want = expected[panel.bgSlot]
    Assert.notNil(want, label .. " authors the expected offset of " .. engine .. " slot " .. panel.bgSlot)
    Assert.equal(panel.offsetX, want[1], label .. " " .. engine .. " slot " .. panel.bgSlot .. " holds its authored x")
    Assert.equal(panel.offsetY, want[2], label .. " " .. engine .. " slot " .. panel.bgSlot .. " holds its authored y")
  end
  local count, sampled, decisive, matched, missingBlack = 0, 0, 0, 0, 0
  local authored = 0
  for _ in pairs(expected) do
    authored = authored + 1
  end
  for _ in ipairs(panels) do
    count = count + 1
  end
  Assert.equal(count, authored, label .. " stages exactly its authored panels")
  local canvas = (engine == "main") and movie.mainCanvas or movie.subCanvas
  local actual = sourceBytes(scope, canvas)
  for y = 0, 191, 16 do
    for x = 0, 255, 16 do
      local excluded = false
      for _, box in ipairs(boxes) do
        if insideBox(box, x, y) then
          excluded = true
          break
        end
      end
      if not excluded then
        sampled = sampled + 1
        local er, eg, eb, decisivePoint = expectedWrapPixel(panels, x, y)
        if decisivePoint and (er + eg + eb) > 0.3 then
          decisive = decisive + 1
          local ar, ag, ab = pixelOf(actual, 256, x, y)
          if ar + ag + ab < 0.05 then
            missingBlack = missingBlack + 1
          end
          if math.abs(ar - er) + math.abs(ag - eg) + math.abs(ab - eb) < 0.08 then
            matched = matched + 1
          end
        end
      end
    end
  end
  local minimum = options.minDecisive or math.max(24, math.floor(sampled * 0.15))
  Assert.isTrue(
    decisive >= minimum,
    (label .. " samples opaque authored art at %d of %d points (need %d)"):format(decisive, sampled, minimum)
  )
  Assert.equal(missingBlack, 0, label .. " shows no missing-coverage black over opaque authored texels")
  Assert.isTrue(
    matched / decisive > 0.9,
    (label .. " matches wrapped native art at %d of %d decisive points"):format(matched, decisive)
  )
end

-- Scene 2 pans its aerial maps with three first/mid/end edge samples, scene
-- 4 holds opposing ±192 slide offsets before settling at the origin, and
-- scene 5 covers its late panorama frame: every sample recomputes texels
-- from the staged native bytes under modular arithmetic. Visible authored
-- sprites are excluded by their live slot boxes, never by output.
local function soulsilver_source_pan_edges_match_wrapped_native_art(scope, context)
  if not RomImporter.isReady("soulsilver") then
    context:skip("SoulSilver panorama edges need a user-owned SoulSilver dump")
  end
  local versionId = "soulsilver"
  local scenes, cacheFs = loadRomPackWithFillers(versionId, { 3 })
  local movie = openMovieWithCache(scope, scenes, cacheFs, versionId, 512, 384, "single")
  advanceToSceneStep(movie, 2, "flyin", 20000)
  -- First: instant placements plus five open-ended drift ticks.
  advance(movie, 5)
  local slot = assert(movie.current, "the running movie owns its current slot")
  Assert.equal(slot.backgrounds.main[0].scrollY, 192, "the flyin holds its main BG0 placement")
  Assert.equal(slot.backgrounds.main[1].scrollY, 320, "the flyin holds its main BG1 placement")
  Assert.equal(slot.backgrounds.main[2].scrollY, 320, "the main drift adds 64 per fixed tick")
  Assert.equal(slot.backgrounds.sub[0].scrollY, 320, "the sub drift advances on its own engine clock")
  movie:draw()
  assertEngineMatchesWrappedArt(scope, movie, cacheFs, scenes[2], "main", "scene 2 first", {
    [0] = { 0, 192 },
    [1] = { 0, 320 },
    [2] = { 0, 320 },
  }, {})
  assertEngineMatchesWrappedArt(scope, movie, cacheFs, scenes[2], "sub", "scene 2 first", {
    [0] = { 0, 320 },
  }, {})
  -- Mid: thirty drift ticks, still before the timed replacement.
  advance(movie, 25)
  Assert.equal(slot.backgrounds.main[2].scrollY, 1920, "the main drift keeps adding 64 per fixed tick")
  movie:draw()
  assertEngineMatchesWrappedArt(scope, movie, cacheFs, scenes[2], "main", "scene 2 mid", {
    [0] = { 0, 192 },
    [1] = { 0, 320 },
    [2] = { 0, 1920 },
  }, {})
  assertEngineMatchesWrappedArt(scope, movie, cacheFs, scenes[2], "sub", "scene 2 mid", {
    [0] = { 0, 1920 },
  }, {})
  -- End: the slow ethan pan samples horizontal wrap at x 16 with the
  -- settled vertical origins. Visible authored sprites are excluded by
  -- their live slot boxes, never by hardcoded stations.
  local journey = 0
  while currentStepId(movie) ~= "slow-pan-ethan" and journey < 20000 do
    movie:updateFixed()
    journey = journey + 1
  end
  Assert.equal(currentStepId(movie), "slow-pan-ethan", "playback reaches the slow ethan pan")
  local elapsed = 30 + journey + 45
  advance(movie, 45)
  Assert.equal(slot.backgrounds.main[0].scrollX, 16, "the end pan holds its horizontal offset on main BG0")
  Assert.equal(slot.backgrounds.main[1].scrollX, 16, "the end pan holds its horizontal offset on main BG1")
  Assert.equal(slot.backgrounds.main[0].scrollY, 0, "the replaced BG0 settles at its origin")
  Assert.equal(slot.backgrounds.main[1].scrollY, 128, "the replaced BG1 settles at 320 minus 192")
  Assert.equal(slot.backgrounds.main[2].scrollY, 64 * elapsed, "the main drift accumulates every fixed tick")
  Assert.equal(slot.backgrounds.sub[0].scrollY, 64 * elapsed, "the sub drift accumulates every fixed tick")
  movie:draw()
  assertEngineMatchesWrappedArt(scope, movie, cacheFs, scenes[2], "main", "scene 2 end", {
    [0] = { 16, 0 },
    [1] = { 16, 128 },
    [2] = { 0, 64 * elapsed },
  }, {})
  -- The end pan runs under the retained sub black-out, so the sub target
  -- carries held black instead of wrapped art.
  Assert.isTrue(
    regionLit(sourceBytes(scope, movie.subCanvas), 256, 0, 255, 0, 191) < 0.05,
    "scene 2 end holds its sub black through the pan"
  )
  -- Scene 4: the slide carries opposing offsets before settling. Live
  -- hand sprites are excluded by their slot boxes.
  advanceToSceneStep(movie, 4, "slide-in", 20000)
  advance(movie, 5)
  slot = assert(movie.current, "scene 4 owns its current slot")
  Assert.equal(slot.backgrounds.main[1].scrollX, 96, "the main slide holds half its negative run")
  Assert.equal(slot.backgrounds.sub[1].scrollX, -96, "the sub slide holds half its positive run")
  Assert.equal(movie.current.mainPhysical, "lower", "scene 4 opens with main on the lower screen")
  advanceToSceneStep(movie, 4, "hold", 20000)
  advance(movie, 5)
  movie:draw()
  assertEngineMatchesWrappedArt(scope, movie, cacheFs, scenes[4], "main", "scene 4 hold", {
    [1] = { 0, 0 },
    [3] = { 0, 0 },
  }, {})
  assertEngineMatchesWrappedArt(scope, movie, cacheFs, scenes[4], "sub", "scene 4 hold", {
    [1] = { 0, 0 },
    [2] = { 0, 0 },
    [3] = { 0, 0 },
  }, {})
  movie:dispose()
  -- Scene 5: the panorama frame samples both tall maps mid-run, before
  -- the concurrent white fade begins at the twentieth scroll tick.
  -- The scene carries no sprites.
  local lateScenes, lateCache = loadRomPackWithFillers(versionId, { 3, 4 })
  local late = openMovieWithCache(scope, lateScenes, lateCache, versionId, 512, 384, "single")
  advanceToSceneStep(late, 5, "wait-bg-scroll", 20000)
  -- The scroll programs start once the ordered shutter and its cleanup
  -- complete; eighteen ticks into the scroll wait the run holds nineteen
  -- scroll ticks and is still unfaded.
  advance(late, 18)
  local lateSlot = assert(late.current, "the late movie owns its current slot")
  Assert.equal(lateSlot.backgrounds.main[1].scrollY, -16, "the late main BG1 holds its upward run")
  Assert.equal(lateSlot.backgrounds.main[2].scrollY, 176, "the late main BG2 holds 160 plus its downward run")
  Assert.equal(lateSlot.backgrounds.sub[1].scrollY, 16, "the late sub BG1 holds its downward run")
  Assert.equal(lateSlot.backgrounds.sub[2].scrollY, 176, "the late sub BG2 holds 160 plus its downward run")
  late:draw()
  assertEngineMatchesWrappedArt(scope, late, lateCache, lateScenes[5], "main", "scene 5 late", {
    [1] = { 0, -16 },
    [2] = { 0, 176 },
  }, {})
  assertEngineMatchesWrappedArt(scope, late, lateCache, lateScenes[5], "sub", "scene 5 late", {
    [1] = { 0, 16 },
    [2] = { 0, 16 + 160 },
  }, {})
  late:dispose()
end

local function heartgold_pan_edges_are_blocked_without_a_dump(scope, context)
  if not RomImporter.isReady("heartgold") then
    context:skip(
      "BLOCKED: HeartGold pan edges need a user-owned HeartGold dump; "
        .. "only SoulSilver is ready here, so the sourced first/mid/end wrap "
        .. "and opposing-offset legs cannot run for HeartGold and are never faked"
    )
  end
  local scenes, cacheFs = loadRomPackWithFillers("heartgold", { 3 })
  local movie = openMovieWithCache(scope, scenes, cacheFs, "heartgold", 512, 384, "single")
  advanceToSceneStep(movie, 2, "flyin", 20000)
  advance(movie, 5)
  movie:draw()
  movie:dispose()
end

-- The copyright blend runs its capped retail coefficient on both engines
-- while the closing white fade covers both engine targets: coefficients
-- come from the independent GBATEK floor(n*31/N) rule capped at sixteen,
-- never from the player weight helper.
---@param data love.ImageData decoded staged art
---@return integer? x, integer? y bright opaque texel coordinates
local function findBrightTexel(data)
  local width, height = data:getWidth(), data:getHeight()
  for y = 0, math.min(height - 1, 191), 4 do
    for x = 0, width - 1, 4 do
      local r, g, b, a = data:getPixel(x, y)
      if a > 0.98 and r > 0.7 and g > 0.7 and b > 0.7 then
        return x, y
      end
    end
  end
  return nil
end

---@param elapsed integer elapsed source ticks
---@param ticks integer authored duration
---@param direction integer retail blend direction
---@return number effective first-target weight
local function retailBlendWeight(elapsed, ticks, direction)
  local ev = math.min(31, math.floor(elapsed * 31 / ticks))
  local raw = (direction == 0) and ev or (31 - ev)
  return math.min(raw, 16) / 16
end

---@param bytes string raw RGBA frame bytes
---@param width integer frame width
---@param height integer frame height
---@return number mean distance from white in 0..1
local function meanWhiteDistance(bytes, width, height)
  local total, count = 0, 0
  for y = 0, height - 1, 8 do
    for x = 0, width - 1, 8 do
      local r, g, b = pixelOf(bytes, width, x, y)
      total = total + (1 - (r + g + b) / 3)
      count = count + 1
    end
  end
  return total / count
end

local function soulsilver_source_copyright_blend_and_white_fade_match_retail_operands(scope, context)
  local versionId = selectedVersionId(context)
  local movie = openMovie(scope, versionId, 512, 384, "single")
  -- The fades step blends BG0 over cleared black on both engines with
  -- masks 1/32, direction 1, and 60 ticks: the only eligible first
  -- target is BG0 itself.
  advanceToSceneStep(movie, 1, "fades", 20000)
  local slot = assert(movie.current, "the running movie owns its current slot")
  Assert.equal(slot.backgrounds.main[0].scrollX, 0, "the copyright returns its main BG0 to the origin")
  local checked = 0
  for _, engine in ipairs({ "main", "sub" }) do
    local background = slot.backgrounds[engine][0]
    Assert.notNil(background, "the copyright stages " .. engine .. " BG0")
    local data = decodedArt(scope, assert(movie.cacheFs:read(background.image)), background.image)
    local texelX, texelY = findBrightTexel(data)
    if texelX ~= nil then
      checked = checked + 1
      local er, eg, eb = data:getPixel(texelX, texelY)
      movie:draw()
      local canvas = (engine == "main") and movie.mainCanvas or movie.subCanvas
      local preR, preG, preB = pixelOf(sourceBytes(scope, canvas), 256, texelX, texelY)
      Assert.near(preR, er, 0.06, engine .. " BG0 starts opaque before its blend")
      Assert.near(preG, eg, 0.06, engine .. " BG0 starts opaque before its blend")
      Assert.near(preB, eb, 0.06, engine .. " BG0 starts opaque before its blend")
      advance(movie, 45)
      Assert.near(retailBlendWeight(45, 60, 1), 0.5, 1e-9, "the retail coefficient halves at 45 of 60 ticks")
      movie:draw()
      local midR, midG, midB = pixelOf(sourceBytes(scope, canvas), 256, texelX, texelY)
      Assert.near(midR, er * 0.5, 0.12, engine .. " BG0 halves toward black under its retail weight")
      Assert.near(midG, eg * 0.5, 0.12, engine .. " BG0 halves toward black under its retail weight")
      Assert.near(midB, eb * 0.5, 0.12, engine .. " BG0 halves toward black under its retail weight")
      -- Rewind to the blend entry for the next engine: the two engines
      -- share one source clock, so the second engine samples the same
      -- program from a fresh journey instead of a rewound one.
      if engine == "main" then
        movie:dispose()
        movie = openMovie(scope, versionId, 512, 384, "single")
        advanceToSceneStep(movie, 1, "fades", 20000)
        slot = assert(movie.current, "the renewed movie owns its current slot")
      end
    end
  end
  Assert.equal(checked, 2, "both engine copyright BG0s carry a bright opaque texel")
  -- The closing white fade fires at run tick 90 for 65 ticks: both
  -- engine targets move strictly toward white while dark authored art
  -- stays legitimate pre-fade content.
  advanceToSceneStep(movie, 1, "run", 20000)
  advance(movie, 80)
  movie:draw()
  local preMain = meanWhiteDistance(sourceBytes(scope, movie.mainCanvas), 256, 192)
  local preSub = meanWhiteDistance(sourceBytes(scope, movie.subCanvas), 256, 192)
  local waited = 0
  while currentStepId(movie) ~= "fade" and waited < 20000 do
    movie:updateFixed()
    waited = waited + 1
  end
  Assert.equal(currentStepId(movie), "fade", "playback reaches the closing fade")
  advance(movie, 32)
  movie:draw()
  local midMain = meanWhiteDistance(sourceBytes(scope, movie.mainCanvas), 256, 192)
  local midSub = meanWhiteDistance(sourceBytes(scope, movie.subCanvas), 256, 192)
  Assert.isTrue(midMain < preMain, "the white fade moves the main target toward white")
  Assert.isTrue(midSub < preSub, "the white fade moves the sub target toward white")
  Assert.isTrue(midMain < preMain * 0.75, "the mid-fade main target covers most of its white run")
  Assert.isTrue(midSub < preSub * 0.75, "the mid-fade sub target covers most of its white run")
  movie:dispose()
end

local function heartgold_copyright_blend_and_fade_are_blocked_without_a_dump(scope, context)
  if not RomImporter.isReady("heartgold") then
    context:skip(
      "BLOCKED: HeartGold copyright blend and fade need a user-owned HeartGold dump; "
        .. "only SoulSilver is ready here, so the sourced coefficient and white-fade "
        .. "legs cannot run for HeartGold and are never faked"
    )
  end
  local movie = openMovie(scope, "heartgold", 512, 384, "single")
  advanceToSceneStep(movie, 1, "fades", 20000)
  movie:dispose()
end

-- Shared retail scanline boundary law for the source circle wipes: callers
-- pass the wipe's own elapsed and total ticks. The reveal cuts a scanline
-- triangle out of the dark panels: the rightmost lit texel of each
-- spotlight row must ride this boundary law, and the edge must travel with
-- the source tick instead of sitting on static art. Rows under the silver
-- silhouette stay out via the live slot box.
local function wipeBoundaryRetail(elapsed, ticks, vcount)
  local theta = math.pi * elapsed / ticks
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
  local quotient = vcount * x / y
  local trunc = (quotient >= 0) and math.floor(quotient) or math.ceil(quotient)
  return math.max(0, math.min(255, 127 + trunc))
end

local function soulsilver_source_town_wipe_slopes_with_the_scanline(scope, context)
  local versionId = selectedVersionId(context)
  local movie = openMovie(scope, versionId, 512, 384, "single")
  local ticks = 0
  while movie:sceneNumber() < 3 and ticks < 20000 do
    movie:updateFixed()
    ticks = ticks + 1
  end
  Assert.equal(movie:sceneNumber(), 3, "playback reaches the town scenes")
  advanceToSceneStep(movie, 3, "show-new-bark-town", 20000)
  advance(movie, 3)
  movie:draw()
  -- The v5 town opens run on the main engine: kind0 hides the left behind
  -- white while the right shows the town, so the edge is read from the
  -- known white cover side. Per-engine isolation means the sub target
  -- never tracks the main wipe law, so no sub pixel is matched to it.
  local function coverIsWhite(bytes, x, y)
    local r, g, b = pixelOf(bytes, 256, x, y)
    return r > 0.85 and g > 0.85 and b > 0.85
  end
  local early = sourceBytes(scope, movie.mainCanvas)
  local earlySub = sourceBytes(scope, movie.subCanvas)
  for _, y in ipairs({ 32, 48, 96, 144 }) do
    local edge = wipeBoundaryRetail(3, 8, y)
    local r, g, b = pixelOf(early, 256, edge - 12, y)
    assertSameColor(r, g, b, 1, 1, 1, 0.12, ("town wipe row %d covers its left behind white"):format(y))
  end
  -- Column 156 sits right of row 48's edge but left of row 96's, so it is
  -- town on one scanline and cover on the other: the edge differs by row.
  Assert.isFalse(coverIsWhite(early, 156, 48), "row 48 already shows town right of its scanline edge")
  do
    local r, g, b = pixelOf(early, 256, 156, 96)
    assertSameColor(r, g, b, 1, 1, 1, 0.12, "row 96 still covers the same column in white")
  end
  advance(movie, 3)
  movie:draw()
  local late = sourceBytes(scope, movie.mainCanvas)
  local lateSub = sourceBytes(scope, movie.subCanvas)
  for _, y in ipairs({ 32, 48, 96 }) do
    local edge = wipeBoundaryRetail(6, 8, y)
    local r, g, b = pixelOf(late, 256, edge - 12, y)
    assertSameColor(r, g, b, 1, 1, 1, 0.12, ("town wipe row %d travels with the source tick"):format(y))
  end
  -- The late edge has passed column 156 on row 96, flipping that fixed
  -- pixel from cover to town while the sub target sits byte-identical.
  Assert.isFalse(coverIsWhite(late, 156, 96), "the cover edge travels with the source tick instead of freezing mid-wipe")
  Assert.equal(earlySub, lateSub, "the town wipe never spills onto the other engine")
  movie:dispose()
end

local function heartgold_town_wipe_is_blocked_without_a_dump(scope, context)
  if not RomImporter.isReady("heartgold") then
    context:skip(
      "BLOCKED: HeartGold town wipe needs a user-owned HeartGold dump; "
        .. "only SoulSilver is ready here, so the sourced scanline-slope leg "
        .. "cannot run for HeartGold and is never faked"
    )
  end
  local movie = openMovie(scope, "heartgold", 512, 384, "single")
  movie:dispose()
end

-- The first starter paints its authored clip frame at its authored station:
-- the expected frame comes from the manifest durations and the counted
-- source ticks, and its staged pixels must match the main target while
-- the sub target at the same box stays different.
---@param manifest table compiled opening-scene manifest
---@param clipId string staged sprite clip identity
---@param tick integer counted source ticks since the clip showed
---@return integer expected 1-based frame index
local function expectedClipFrame(manifest, clipId, tick)
  local clip = nil
  for _, candidate in ipairs(manifest.spriteClips) do
    if candidate.id == clipId then
      clip = candidate
      break
    end
  end
  Assert.notNil(clip, "the starter clip resolves: " .. tostring(clipId))
  local total = 0
  for _, frame in ipairs(clip.frames) do
    total = total + (frame.duration or 1)
  end
  total = math.max(total, 1)
  local elapsed = tick % total
  for index, frame in ipairs(clip.frames) do
    local duration = frame.duration or 1
    if elapsed < duration then
      return index
    end
    elapsed = elapsed - duration
  end
  return #clip.frames
end

local function soulsilver_source_starter_paints_its_authored_frame(scope, context)
  local versionId = selectedVersionId(context)
  local scenes = loadScenes(versionId)
  local movie = openMovie(scope, versionId, 512, 384, "single")
  advanceToSceneStep(movie, 4, "run-chikorita", 20000)
  advance(movie, 3)
  Assert.equal(currentStepId(movie), "run-chikorita", "the first starter holds its emitter beat")
  -- The clip shows at the appear dispatch two source ticks before the run
  -- entry, so three more ticks land on the fifth animation tick.
  local manifest = scenes[4]
  local placement = nil
  for _, event in ipairs(manifest.timeline.events) do
    if event.op == "setSpriteClip" and event.stepId == "appear-chikorita" and event.instanceId == "chikorita" then
      placement = event
      break
    end
  end
  Assert.notNil(placement, "the manifest places the chikorita sprite")
  Assert.equal(placement.engine, "main", "the starter paints its owning engine")
  Assert.equal(placement.x, 128, "the starter holds its retail x")
  Assert.equal(placement.y, 96, "the starter holds its retail y")
  local live = 0
  for _, runtime in ipairs(assert(movie.current.emitters, "the movie tracks its live emitters")) do
    live = live + #(runtime.particles or {})
  end
  Assert.isTrue(live > 0, "the starter samples while its particles are live")
  movie:draw()
  local clipBytes = assert(movie.cacheFs:read(placement.clipId), "the staged starter clip reads back")
  local clipData = decodedArt(scope, clipBytes, placement.clipId)
  local main = sourceBytes(scope, movie.mainCanvas)
  local sub = sourceBytes(scope, movie.subCanvas)
  local want = expectedClipFrame(manifest, placement.clipId, 5)
  local best, bestRate, wantRate = 1, -1, nil
  local clip = nil
  for _, candidate in ipairs(manifest.spriteClips) do
    if candidate.id == placement.clipId then
      clip = candidate
      break
    end
  end
  Assert.notNil(clip, "the starter clip carries its frames")
  -- Frames may hang off the viewport edge while the starter walks in:
  -- only the visible intersection is decidable, exactly like the canvas.
  local function frameMatch(frame, bytes, width)
    local bx, by = placement.x + (frame.offsetX or 0), placement.y + (frame.offsetY or 0)
    local ix0, iy0 = math.max(bx, 0), math.max(by, 0)
    local ix1, iy1 = math.min(bx + frame.width, 256), math.min(by + frame.height, 192)
    if ix1 - ix0 < 8 or iy1 - iy0 < 8 then
      return nil
    end
    local matched, decisive = 0, 0
    for vy = iy0, iy1 - 1, 2 do
      for vx = ix0, ix1 - 1, 2 do
        local cr, cg, cb, ca = clipData:getPixel(frame.x + (vx - bx), frame.y + (vy - by))
        if ca > 0.98 then
          decisive = decisive + 1
          local ar, ag, ab = pixelOf(bytes, width, vx, vy)
          if math.abs(ar - cr) + math.abs(ag - cg) + math.abs(ab - cb) < 0.08 then
            matched = matched + 1
          end
        end
      end
    end
    if decisive < 20 then
      return nil
    end
    return matched / decisive
  end
  for index, frame in ipairs(clip.frames) do
    local rate = frameMatch(frame, main, 256)
    if rate ~= nil then
      if rate > bestRate then
        best, bestRate = index, rate
      end
      if index == want then
        wantRate = rate
      end
    end
  end
  Assert.notNil(wantRate, "the expected starter frame carries decidable pixels")
  Assert.equal(best, want, "the painted starter frame is the source-clocked one")
  Assert.isTrue((wantRate or 0) > 0.9, "the starter paints its authored frame texels")
  -- The same frame on the sub target must not carry the sprite.
  local subRate = frameMatch(clip.frames[want], sub, 256)
  Assert.notNil(subRate, "the sub comparison samples the expected frame")
  Assert.isTrue(subRate < 0.5, "the starter never leaks onto the sub engine")
  movie:dispose()
end

local function heartgold_starter_frame_is_blocked_without_a_dump(scope, context)
  if not RomImporter.isReady("heartgold") then
    context:skip(
      "BLOCKED: HeartGold starter frame needs a user-owned HeartGold dump; "
        .. "only SoulSilver is ready here, so the sourced sprite-frame leg "
        .. "cannot run for HeartGold and is never faked"
    )
  end
  local movie = openMovie(scope, "heartgold", 512, 384, "single")
  movie:dispose()
end

local function heartgold_wipe_kinds_are_blocked_without_a_dump(scope, context)
  if not RomImporter.isReady("heartgold") then
    context:skip(
      "BLOCKED: HeartGold wipe kinds need a user-owned HeartGold dump; "
        .. "only SoulSilver is ready here, so the kind-specific brightness and "
        .. "scanline legs cannot run for HeartGold and are never faked"
    )
  end
  local romScenes = loadScenes("heartgold")
  local found = false
  for _, event in ipairs(romScenes[2].timeline.events) do
    if event.op == "circleWipe" then
      found = true
    end
  end
  Assert.isTrue(found, "the HeartGold second scene carries its wipe")
end

-- Every circle kind covers exactly one scanline span with its own source
-- backdrop on the GPU: kinds 0 and 2 hide the left of the scanline edge
-- behind white and black while the right shows game art; kinds 1 and 3
-- show game art on the left and hide the right behind white and black.
-- No kind paints a second mirrored stripe, and the idle engine is
-- byte-identical before and after every kind.
local function synthetic_wipe_kinds_paint_the_source_inside_outside_masks_and_backdrops(scope)
  local root = sceneArtRoot(1)
  local mainImage = root .. "layers/mask-main.png"
  local subImage = root .. "layers/mask-sub.png"
  local art = {
    [mainImage] = solidPng(256, 192, 255, 0, 0),
    [subImage] = solidPng(256, 192, 0, 255, 0),
  }
  local steps, events = {}, {}
  for kind = 0, 3 do
    local indexes = { #events + 1 }
    events[#events + 1] = {
      op = "circleWipe",
      stepId = "wipe-" .. kind,
      atStepTick = 0,
      engine = "main",
      kind = kind,
      ticks = 12,
      effect = "wipe-" .. kind,
    }
    if kind == 0 then
      indexes[#indexes + 1] = #events + 1
      events[#events + 1] = { op = "enableSkip", stepId = "wipe-0", atStepTick = 10 }
    end
    steps[#steps + 1] = { id = "wipe-" .. kind, events = indexes, ["until"] = { kind = "effect", effect = "wipe-" .. kind } }
  end
  steps[#steps + 1] = { id = "tail", events = { #events + 1, #events + 2 }, ["until"] = { kind = "duration", ticks = 10 } }
  events[#events + 1] = { op = "waitTicks", stepId = "tail", atStepTick = 0, ticks = 10 }
  events[#events + 1] = { op = "finish", stepId = "tail", atStepTick = 0 }
  local custom = compositeScene(
    1,
    { compositeLayer(0, mainImage, 256, 192) },
    { compositeLayer(0, subImage, 256, 192) },
    {},
    { seed = 0, emitters = {} },
    steps,
    events
  )
  local scenes, cacheFs = compositePack(custom, art, solidPng(16, 16, 128, 128, 128))
  local movie = openCompositeMovie(scope, scenes, cacheFs, 512, 384, "dual")
  movie:draw()
  local subBefore = sourceBytes(scope, movie.subCanvas)
  local wants = {
    { left = { 1, 1, 1 }, right = { 1, 0, 0 } },
    { left = { 1, 0, 0 }, right = { 1, 1, 1 } },
    { left = { 0, 0, 0 }, right = { 1, 0, 0 } },
    { left = { 1, 0, 0 }, right = { 0, 0, 0 } },
  }
  for kind = 0, 3 do
    advance(movie, 3)
    movie:draw()
    local main = sourceBytes(scope, movie.mainCanvas)
    for _, y in ipairs({ 32, 64, 96 }) do
      local boundary = wipeBoundaryRetail(3, 12, y)
      local lr, lg, lb = pixelOf(main, 256, boundary - 16, y)
      local rr, rg, rb = pixelOf(main, 256, boundary + 16, y)
      local wantLeft, wantRight = wants[kind + 1].left, wants[kind + 1].right
      assertSameColor(lr, lg, lb, wantLeft[1], wantLeft[2], wantLeft[3], 0.08, "kind " .. kind .. " shows its source left at row " .. y)
      assertSameColor(rr, rg, rb, wantRight[1], wantRight[2], wantRight[3], 0.08, "kind " .. kind .. " shows its source right at row " .. y)
    end
    Assert.equal(
      sourceBytes(scope, movie.subCanvas),
      subBefore,
      "kind " .. kind .. " never spills onto the idle engine"
    )
    advance(movie, 9)
  end
  movie:dispose()
end

-- Only the retail completion colors survive on the GPU: kinds 1 and 3
-- keep a full white and black hold on their own engine past completion
-- and across the next step boundary, while kinds 0 and 2 retire neutral
-- with staged art showing. A later open on the same engine resets a
-- hold instead of stacking washes.
local function synthetic_terminal_wipe_brightness_holds_only_for_the_retail_kinds(scope)
  local root = sceneArtRoot(1)
  local mainImage = root .. "layers/hold-main.png"
  local subImage = root .. "layers/hold-sub.png"
  local art = {
    [mainImage] = solidPng(256, 192, 255, 0, 0),
    [subImage] = solidPng(256, 192, 0, 255, 0),
  }
  local beats = { 1, 0, 3, 2 }
  local wants = { [1] = { 1, 1, 1 }, [0] = { 1, 0, 0 }, [3] = { 0, 0, 0 }, [2] = { 1, 0, 0 } }
  local steps, events = {}, {}
  for position, kind in ipairs(beats) do
    local indexes = { #events + 1 }
    events[#events + 1] = {
      op = "circleWipe",
      stepId = "wipe-" .. kind,
      atStepTick = 0,
      engine = "main",
      kind = kind,
      ticks = 8,
      effect = "wipe-" .. kind,
    }
    if position == 1 then
      indexes[#indexes + 1] = #events + 1
      events[#events + 1] = { op = "enableSkip", stepId = "wipe-1", atStepTick = 5 }
    end
    steps[#steps + 1] = { id = "wipe-" .. kind, events = indexes, ["until"] = { kind = "effect", effect = "wipe-" .. kind } }
    steps[#steps + 1] = { id = "check-" .. kind, events = { #events + 1 }, ["until"] = { kind = "duration", ticks = 4 } }
    events[#events + 1] = { op = "waitTicks", stepId = "check-" .. kind, atStepTick = 0, ticks = 4 }
  end
  steps[#steps + 1] = { id = "tail", events = { #events + 1, #events + 2 }, ["until"] = { kind = "duration", ticks = 5 } }
  events[#events + 1] = { op = "waitTicks", stepId = "tail", atStepTick = 0, ticks = 5 }
  events[#events + 1] = { op = "finish", stepId = "tail", atStepTick = 0 }
  local custom = compositeScene(
    1,
    { compositeLayer(0, mainImage, 256, 192) },
    { compositeLayer(0, subImage, 256, 192) },
    {},
    { seed = 0, emitters = {} },
    steps,
    events
  )
  local scenes, cacheFs = compositePack(custom, art, solidPng(16, 16, 128, 128, 128))
  local movie = openCompositeMovie(scope, scenes, cacheFs, 512, 384, "dual")
  movie:draw()
  local subBefore = sourceBytes(scope, movie.subCanvas)
  for _, kind in ipairs(beats) do
    advance(movie, 8)
    movie:draw()
    local want = wants[kind]
    local fr, fg, fb = pixelOf(sourceBytes(scope, movie.mainCanvas), 256, 128, 96)
    assertSameColor(fr, fg, fb, want[1], want[2], want[3], 0.08, "kind " .. kind .. " finishes with its own source brightness")
    advance(movie, 2)
    movie:draw()
    local hr, hg, hb = pixelOf(sourceBytes(scope, movie.mainCanvas), 256, 128, 96)
    assertSameColor(hr, hg, hb, want[1], want[2], want[3], 0.08, "kind " .. kind .. " keeps its finish across the step boundary")
    Assert.equal(
      sourceBytes(scope, movie.subCanvas),
      subBefore,
      "kind " .. kind .. " never spills onto the idle engine"
    )
    advance(movie, 2)
  end
  movie:dispose()
end

-- One shutter event arms both engine row masks masked black with main
-- active: main opens center-out toward the edges while sub stays black,
-- and sub rises bottom-up only after main finishes. The named wait stays
-- pending until both engine cleanups terminate, and host draws and
-- resizes advance nothing on any stage size.
local function synthetic_scene_five_shutter_opens_main_center_out_before_sub_bottom_up(scope)
  local root = sceneArtRoot(5)
  local mainImage = root .. "layers/shutter-main.png"
  local subImage = root .. "layers/shutter-sub.png"
  local art = {
    [mainImage] = solidPng(256, 192, 255, 0, 0),
    [subImage] = solidPng(256, 192, 0, 255, 0),
  }
  local steps = {
    { id = "wipe", events = { 1, 2 }, ["until"] = { kind = "duration", ticks = 18 } },
    { id = "scroll", events = {}, ["until"] = { kind = "effect", effect = "scene5-shutter" } },
    { id = "tail", events = { 3, 4 }, ["until"] = { kind = "duration", ticks = 5 } },
  }
  local events = {
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
    { op = "waitTicks", stepId = "tail", atStepTick = 0, ticks = 5 },
    { op = "finish", stepId = "tail", atStepTick = 0 },
  }
  local custom = compositeScene(
    5,
    { compositeLayer(0, mainImage, 256, 192) },
    { compositeLayer(0, subImage, 256, 192) },
    {},
    { seed = 0, emitters = {} },
    steps,
    events
  )
  local function gridHasNonBlack(bytes, width, xs, ys)
    for _, y in ipairs(ys) do
      for _, x in ipairs(xs) do
        local r, g, b = pixelOf(bytes, width, x, y)
        if r + g + b > 0.08 then
          return true
        end
      end
    end
    return false
  end
  local function gridAllBlack(bytes, width, xs, ys)
    for _, y in ipairs(ys) do
      for _, x in ipairs(xs) do
        local r, g, b = pixelOf(bytes, width, x, y)
        if r + g + b > 0.08 then
          return false
        end
      end
    end
    return true
  end
  local columns = { 64, 128, 192 }
  local scenes, cacheFs = compositePackAt(custom, 5, art, solidPng(16, 16, 128, 128, 128))
  local movie = openCompositeMovie(scope, scenes, cacheFs, 512, 384, "dual")
  while movie:sceneNumber() < 5 do
    movie:updateFixed()
  end
  -- The newly entered case first runs on the following update: the wipe
  -- entry arms the shutter there and opens its first center step at once.
  movie:updateFixed()
  movie:draw()
  local mainShut = sourceBytes(scope, movie.mainCanvas)
  local subShut = sourceBytes(scope, movie.subCanvas)
  Assert.isTrue(
    gridAllBlack(mainShut, 256, columns, { 8, 48, 144, 180 }),
    "the dispatched shutter still masks the outer rows"
  )
  Assert.isTrue(
    gridHasNonBlack(mainShut, 256, columns, { 96 }),
    "the first dispatched step opens the center band"
  )
  Assert.isTrue(
    gridAllBlack(subShut, 256, columns, { 8, 48, 96, 144, 180 }),
    "the shutter starts with sub fully masked black"
  )
  advance(movie, 8)
  movie:draw()
  local mainMid = sourceBytes(scope, movie.mainCanvas)
  local subMid = sourceBytes(scope, movie.subCanvas)
  Assert.isTrue(gridAllBlack(mainMid, 256, columns, { 8 }), "main still masks its top edge mid-shutter")
  Assert.isFalse(gridHasNonBlack(mainMid, 256, columns, { 8 }), "no main art leaks through the masked top edge")
  Assert.isTrue(gridHasNonBlack(mainMid, 256, columns, { 96 }), "main opens its center band first")
  Assert.isTrue(gridAllBlack(mainMid, 256, columns, { 180 }), "main still masks its bottom edge mid-shutter")
  Assert.isTrue(
    gridAllBlack(subMid, 256, columns, { 8, 48, 96, 144, 180 }),
    "sub stays fully masked while main runs"
  )
  local upperR, upperG, upperB = samplePixel(scope, movie, 512, 384, 256, 96)
  assertSameColor(upperR, upperG, upperB, 1, 0, 0, 0.2, "the upper pane maps the already composed main engine")
  local lowerR, lowerG, lowerB = samplePixel(scope, movie, 512, 384, 256, 288)
  assertSameColor(lowerR, lowerG, lowerB, 0, 0, 0, 0.2, "the lower pane maps the still masked sub engine")
  Assert.equal(subMid, subShut, "draws advance no sub row while main runs")
  advance(movie, 9)
  movie:draw()
  local mainOpen = sourceBytes(scope, movie.mainCanvas)
  local subWaiting = sourceBytes(scope, movie.subCanvas)
  Assert.isTrue(gridHasNonBlack(mainOpen, 256, columns, { 8, 48, 96, 144, 180 }), "main is fully revealed at its finish")
  Assert.equal(subWaiting, subShut, "sub still waits fully masked at the main finish")
  local slot = assert(movie.current, "the running movie owns its current slot")
  Assert.isFalse(slot.effects["scene5-shutter"].done, "the shutter wait stays pending at the main finish")
  Assert.equal(currentStepId(movie), "scroll", "the wipe step hands the gated scroll step its wait")
  local beforeMain, beforeSub = mainOpen, subWaiting
  movie:resize(600, 1000)
  movie:draw()
  movie:resize(512, 384)
  movie:draw()
  Assert.equal(sourceBytes(scope, movie.mainCanvas), beforeMain, "a resize and draw reveal no new main row")
  Assert.equal(sourceBytes(scope, movie.subCanvas), beforeSub, "a resize and draw advance no sub row")
  local handedOff = false
  for _ = 1, 36 do
    movie:updateFixed()
    local live = assert(movie.current, "the running movie owns its current slot")
    if live.shutter ~= nil and (live.shutter.sub.elapsed > 0 or live.shutter.active == "sub") then
      handedOff = true
      break
    end
  end
  Assert.isTrue(handedOff, "the sub shutter starts after main completes")
  local subActive = assert(movie.current, "the running movie owns its current slot")
  for _ = 1, 200 do
    if subActive.shutter ~= nil and subActive.shutter.sub.elapsed >= 9 then
      break
    end
    movie:updateFixed()
  end
  Assert.isTrue(
    subActive.shutter ~= nil and subActive.shutter.sub.elapsed >= 9,
    "the sub shutter advances bottom-up once active"
  )
  Assert.isFalse(
    assert(movie.current, "the running movie owns its current slot").effects["scene5-shutter"].done,
    "the shutter wait stays pending mid-sub"
  )
  movie:draw()
  local subMidUp = sourceBytes(scope, movie.subCanvas)
  Assert.isTrue(gridHasNonBlack(subMidUp, 256, columns, { 180 }), "sub opens its bottom band first")
  Assert.isTrue(gridAllBlack(subMidUp, 256, columns, { 8 }), "sub still masks its top edge mid-shutter")
  local finished = false
  for _ = 1, 120 do
    movie:updateFixed()
    if assert(movie.current, "the running movie owns its current slot").effects["scene5-shutter"].done then
      finished = true
      break
    end
  end
  Assert.isTrue(finished, "both engine cleanups terminate the shutter wait")
  local tailed = false
  for _ = 1, 60 do
    if currentStepId(movie) == "tail" then
      tailed = true
      break
    end
    movie:updateFixed()
  end
  Assert.isTrue(tailed, "the gated scroll step advances only after both cleanups")
  movie:draw()
  local endMain = sourceBytes(scope, movie.mainCanvas)
  local endSub = sourceBytes(scope, movie.subCanvas)
  Assert.isTrue(gridHasNonBlack(endMain, 256, columns, { 8, 96, 180 }), "main stays revealed after completion")
  Assert.isTrue(gridHasNonBlack(endSub, 256, columns, { 8, 96, 180 }), "sub stays revealed after completion")
  for _, layout in ipairs({
    { kind = "dual", width = 512, height = 384 },
    { kind = "single", width = 512, height = 384 },
    { kind = "single", width = 600, height = 1000 },
  }) do
    local scenesForLayout, cacheForLayout = compositePackAt(custom, 5, art, solidPng(16, 16, 128, 128, 128))
    local probe = openCompositeMovie(scope, scenesForLayout, cacheForLayout, layout.width, layout.height, layout.kind)
    while probe:sceneNumber() < 5 do
      probe:updateFixed()
    end
    advance(probe, 9)
    probe:draw()
    Assert.equal(
      sourceBytes(scope, probe.mainCanvas),
      mainMid,
      ("the main shutter owns its engine on the %s stage"):format(layout.kind)
    )
    Assert.equal(
      sourceBytes(scope, probe.subCanvas),
      subMid,
      ("the sub shutter owns its engine on the %s stage"):format(layout.kind)
    )
    probe:dispose()
  end
  movie:dispose()
end

---@param bytes string raw RGBA frame bytes
---@param width integer frame width
---@return integer near-black grid samples
local function blackGridCount(bytes, width)
  local found = 0
  for y = 0, 191, 2 do
    for x = 0, 255, 4 do
      local r, g, b = pixelOf(bytes, width, x, y)
      if r < 0.01 and g < 0.01 and b < 0.01 then
        found = found + 1
      end
    end
  end
  return found
end

-- The sourced second scene fades only its sub engine to black while the
-- main heroes keep panning: the main target stays lit through the
-- eight-tick fade, the sub target reaches black and holds it across the
-- following ninety-tick pan, and the next pan waits for the fade rather
-- than the shorter scrolls.
local function soulsilver_scene_two_sub_blackout_holds_while_main_pans(scope, context)
  if not RomImporter.isReady("soulsilver") then
    context:skip("SoulSilver sub blackout needs a user-owned SoulSilver ROM")
  end
  local movie = openMovie(scope, "soulsilver", 512, 384, "dual")
  advanceToSceneStep(movie, 2, "flyin", 20000)
  movie:updateFixed()
  movie:draw()
  Assert.isTrue(
    regionLit(sourceBytes(scope, movie.mainCanvas), 256, 0, 255, 0, 191) > 0.2,
    "the flyin lights main before the black-out"
  )
  Assert.isTrue(
    regionLit(sourceBytes(scope, movie.subCanvas), 256, 0, 255, 0, 191) > 0.2,
    "the flyin lights sub before the black-out"
  )
  -- The fifty-sixth flyin update starts the settle tasks; three updates
  -- later the sub fade is mid-course while main keeps its heroes.
  advance(movie, 55)
  Assert.equal(currentStepId(movie), "settle-flyin", "the settle opens on the fifty-sixth flyin tick")
  advance(movie, 3)
  movie:draw()
  Assert.isTrue(
    regionLit(sourceBytes(scope, movie.mainCanvas), 256, 0, 255, 0, 191) > 0.2,
    "main stays lit mid-way through the sub-only black-out"
  )
  -- The five-tick scrolls finish while the eight-tick fade still runs:
  -- the settle must not release its next pan yet.
  advance(movie, 1)
  Assert.equal(
    currentStepId(movie),
    "settle-flyin",
    "the settle still waits while the sub fade runs past its scrolls"
  )
  -- Once the fade completes the next pan begins with main art showing
  -- and sub at full black.
  advance(movie, 3)
  Assert.equal(
    currentStepId(movie),
    "slow-pan-ethan",
    "the next pan begins once the sub fade completes"
  )
  movie:draw()
  local doneMain = sourceBytes(scope, movie.mainCanvas)
  local doneSub = sourceBytes(scope, movie.subCanvas)
  Assert.isTrue(regionLit(doneMain, 256, 0, 255, 0, 191) > 0.2, "main shows its hero art past the sub fade")
  Assert.isTrue(regionLit(doneSub, 256, 0, 255, 0, 191) < 0.05, "sub reaches black when its fade completes")
  -- Halfway through the ninety-tick pan the heroes keep moving on main
  -- while sub holds its black without drifting.
  advance(movie, 45)
  movie:draw()
  local holdMain = sourceBytes(scope, movie.mainCanvas)
  local holdSub = sourceBytes(scope, movie.subCanvas)
  Assert.isTrue(regionLit(holdMain, 256, 0, 255, 0, 191) > 0.2, "main keeps its hero art across its pans")
  Assert.isTrue(regionLit(holdSub, 256, 0, 255, 0, 191) < 0.05, "sub holds black across the main hero pans")
  Assert.isTrue(
    changeFraction(doneMain, holdMain, 256, 192) > 0.02,
    "main pans continue while sub holds black"
  )
  Assert.isTrue(
    changeFraction(doneSub, holdSub, 256, 192) < 0.01,
    "sub stays still while it holds black"
  )
  movie:dispose()
end

-- The sourced first scene shows its sun paused on the setup beat and
-- only animates it once the scroll case starts: the sunrise entry carries
-- a visible unanimated sun at its station, a repeated draw keeps the
-- identical frame, and the following case advances both the clip and the
-- background scroll programs.
local function soulsilver_scene_one_sunrise_shows_static_sun_before_scroll(scope, context)
  if not RomImporter.isReady("soulsilver") then
    context:skip("SoulSilver sunrise needs a user-owned SoulSilver ROM")
  end
  local movie = openMovie(scope, "soulsilver", 512, 384, "dual")
  advanceToSceneStep(movie, 1, "sunrise", 20000)
  movie:updateFixed()
  movie:draw()
  local slot = assert(movie.current, "the running movie owns its current slot")
  Assert.notNil(slot.spriteInstances["sun"], "the sunrise beat shows its sun")
  local sun = assert(slot.spriteInstances["sun"], "the sunrise beat shows its sun")
  Assert.isTrue(sun.visible == true, "the staged sun is visible on its setup beat")
  Assert.equal(sun.animate, false, "the sunrise beat holds the sun paused")
  Assert.equal(sun.tick, 0, "the paused sun keeps its first authored frame")
  local first = sourceBytes(scope, movie.mainCanvas)
  Assert.isTrue(
    regionLit(first, 256, 112, 144, 80, 112) > 0.3,
    "the sunrise beat paints sun pixels at its station"
  )
  movie:draw()
  Assert.equal(sourceBytes(scope, movie.mainCanvas), first, "a repeated draw keeps the identical static sun")
  movie:updateFixed()
  Assert.equal(currentStepId(movie), "scroll", "the animated scroll case follows the setup beat")
  Assert.equal(sun.animate, true, "the scroll case restarts the sun clip")
  advance(movie, 30)
  movie:draw()
  Assert.isTrue((sun.tick or 0) > 0, "the scroll case advances the sun clip")
  local offsets = currentScrollOffsets(movie)
  Assert.isTrue(
    offsets.main1 ~= 0 or offsets.main2 ~= 0,
    "the scroll case moves its sunrise backgrounds"
  )
  Assert.isTrue(
    changeFraction(first, sourceBytes(scope, movie.mainCanvas), 256, 192) > 0.05,
    "the scroll case animates the sunrise beat"
  )
  movie:dispose()
end

-- The sourced second scene carries exactly one main wipe with its retail
-- kind and eight ticks: early, middle, and finished frames show game art
-- on the left and the white backdrop on the right, the finished white
-- holds past completion, and the sub engine keeps its retained flyin
-- black untouched by the wipe on every stage layout.
local function soulsilver_scene_two_final_wipe_keeps_its_source_kind_and_white_hold(scope, context)
  if not RomImporter.isReady("soulsilver") then
    context:skip("SoulSilver final wipe needs a user-owned SoulSilver ROM")
  end
  local scenes = loadScenes("soulsilver")
  local wipes = {}
  for _, event in ipairs(scenes[2].timeline.events) do
    if event.op == "circleWipe" then
      wipes[#wipes + 1] = event
    end
  end
  Assert.equal(#wipes, 1, "the second scene carries its single final wipe")
  Assert.equal(wipes[1].engine, "main", "the final wipe owns the main engine")
  Assert.equal(wipes[1].kind, 1, "the final wipe keeps its source kind")
  Assert.equal(wipes[1].ticks, 8, "the final wipe keeps its eight source ticks, never ten")
  local midMain, midSub = nil, nil
  for _, layout in ipairs({
    { kind = "dual", width = 512, height = 384 },
    { kind = "single", width = 512, height = 384 },
    { kind = "single", width = 600, height = 1000 },
  }) do
    local movie = openMovie(scope, "soulsilver", layout.width, layout.height, layout.kind)
    advanceToSceneStep(movie, 2, "wipe", 20000)
    movie:draw()
    local subBefore = sourceBytes(scope, movie.subCanvas)
    Assert.isTrue(
      regionLit(subBefore, 256, 0, 255, 0, 191) < 0.05,
      "the sub engine keeps its retained black into the wipe beat"
    )
    advance(movie, 2)
    movie:draw()
    local main = sourceBytes(scope, movie.mainCanvas)
    local sub = sourceBytes(scope, movie.subCanvas)
    local edgeLow = wipeBoundaryRetail(2, 8, 48)
    local edgeHigh = wipeBoundaryRetail(2, 8, 96)
    for _, row in ipairs({ { y = 48, edge = edgeLow }, { y = 96, edge = edgeHigh } }) do
      local r, g, b = pixelOf(main, 256, row.edge + 12, row.y)
      assertSameColor(r, g, b, 1, 1, 1, 0.12, "the sourced wipe hides the right behind white")
    end
    Assert.equal(sub, subBefore, "the main wipe leaves the held sub engine untouched")
    if midMain == nil then
      midMain, midSub = main, sub
    else
      Assert.equal(main, midMain, ("the main wipe owns its engine on the %s stage"):format(layout.kind))
      Assert.equal(sub, midSub, ("the idle engine matches on the %s stage"):format(layout.kind))
    end
    advance(movie, 6)
    movie:draw()
    local fr, fg, fb = pixelOf(sourceBytes(scope, movie.mainCanvas), 256, 128, 96)
    assertSameColor(fr, fg, fb, 1, 1, 1, 0.08, "the finished wipe holds full white")
    advance(movie, 3)
    movie:draw()
    local hr, hg, hb = pixelOf(sourceBytes(scope, movie.mainCanvas), 256, 128, 96)
    assertSameColor(hr, hg, hb, 1, 1, 1, 0.08, "the white hold persists past completion")
    movie:dispose()
  end
end

-- The sourced third scene runs its seven town open and close wipes in
-- order on their own engines with eight ticks each, retires town drawing
-- after the final main close, and reveals the rival on the sub engine:
-- the finished final close holds full black on main while the rival beat
-- shows art inside its edge and black outside, identically on every
-- stage layout.
local function soulsilver_scene_three_closes_retire_town_drawing_before_the_rival_reveal(scope, context)
  if not RomImporter.isReady("soulsilver") then
    context:skip("SoulSilver town beats need a user-owned SoulSilver ROM")
  end
  local scenes = loadScenes("soulsilver")
  local signatures = {}
  for _, event in ipairs(scenes[3].timeline.events) do
    if event.op == "circleWipe" then
      signatures[#signatures + 1] = event.engine .. ":" .. event.kind .. ":" .. event.ticks
    end
  end
  local expected = { "main:0:8", "main:3:8", "main:2:8", "main:3:8", "main:2:8", "main:3:8", "sub:2:8" }
  Assert.deepEqual(signatures, expected, "scene 3 keeps its seven source circle wipes in order")
  local firstMain, firstSub = nil, nil
  for _, layout in ipairs({
    { kind = "dual", width = 512, height = 384 },
    { kind = "single", width = 512, height = 384 },
  }) do
    local movie = openMovie(scope, "soulsilver", layout.width, layout.height, layout.kind)
    advanceToSceneStep(movie, 3, "rival", 20000)
    advance(movie, 2)
    movie:draw()
    local main = sourceBytes(scope, movie.mainCanvas)
    local sub = sourceBytes(scope, movie.subCanvas)
    if layout.kind == "dual" then
      firstMain, firstSub = main, sub
    else
      Assert.equal(main, firstMain, "the main close owns its engine on the single stage")
      Assert.equal(sub, firstSub, "the rival reveal owns its engine on the single stage")
    end
    local mr, mg, mb = pixelOf(main, 256, 128, 96)
    assertSameColor(mr, mg, mb, 0, 0, 0, 0.08, "the finished final close holds full black on main")
    local edgeLow = wipeBoundaryRetail(2, 8, 48)
    local edgeHigh = wipeBoundaryRetail(2, 8, 96)
    for _, row in ipairs({ { y = 48, edge = edgeLow }, { y = 96, edge = edgeHigh } }) do
      local r, g, b = pixelOf(sub, 256, row.edge + 12, row.y)
      assertSameColor(r, g, b, 0, 0, 0, 0.12, "the rival reveal hides the right behind black")
    end
    local early = sourceBytes(scope, movie.subCanvas)
    local late
    do
      advance(movie, 3)
      movie:draw()
      late = sourceBytes(scope, movie.subCanvas)
    end
    Assert.isFalse(early == late, "the rival wipe travels with the source tick")
    local slot = assert(movie.current, "the running movie owns its current slot")
    Assert.isFalse(slot.townVisible, "town drawing retires before the rival-only visuals")
    movie:dispose()
  end
end

-- The sourced fifth scene opens its main shutter center-out before its
-- sub shutter rises bottom-up: both engines start fully masked, the main
-- center band opens while sub stays black, the main finish still waits on
-- the named shutter, and only both cleanups together release the scroll
-- step, identically on every stage layout.
local function soulsilver_scene_five_shutter_runs_main_then_sub_across_layouts(scope, context)
  if not RomImporter.isReady("soulsilver") then
    context:skip("SoulSilver line shutter needs a user-owned SoulSilver ROM")
  end
  local scenes = loadScenes("soulsilver")
  local shutters, circles = 0, 0
  for _, event in ipairs(scenes[5].timeline.events) do
    if event.op == "shutterFade" then
      shutters = shutters + 1
      Assert.equal(event.order, "main-then-sub", "the shutter keeps its source engine order")
      Assert.equal(event.mainPattern, "center-out", "the shutter keeps its source main shape")
      Assert.equal(event.subPattern, "bottom-up", "the shutter keeps its source sub shape")
      Assert.equal(event.color, "black", "the shutter keeps its source color")
      Assert.equal(event.steps, 18, "the shutter keeps its eighteen source steps")
      Assert.equal(event.framesPerStep, 1, "the shutter keeps its source frame cadence")
      Assert.equal(event.effect, "scene5-shutter", "the shutter keeps its source wait identity")
    elseif event.op == "circleWipe" then
      circles = circles + 1
    end
  end
  Assert.equal(shutters, 1, "scene 5 carries its single sequential line shutter")
  Assert.equal(circles, 0, "scene 5 carries no circle wipe")
  local columns = { 32, 96, 160, 224 }
  local t0Main, t0Sub, midMain, midSub = nil, nil, nil, nil
  for _, layout in ipairs({
    { kind = "dual", width = 512, height = 384 },
    { kind = "single", width = 512, height = 384 },
    { kind = "single", width = 600, height = 1000 },
  }) do
    local movie = openMovie(scope, "soulsilver", layout.width, layout.height, layout.kind)
    advanceToSceneStep(movie, 5, "wipe", 20000)
    -- The newly entered case first runs on the following update: the wipe
    -- entry arms the shutter there and opens its first center step.
    movie:updateFixed()
    movie:draw()
    local shutMain = sourceBytes(scope, movie.mainCanvas)
    local shutSub = sourceBytes(scope, movie.subCanvas)
    -- The dispatched shutter still masks the outer rows on both engines;
    -- the first center step is already open, so the middle row is not
    -- pinned masked here (the midway sample below covers the opening).
    for _, y in ipairs({ 8, 48, 144, 180 }) do
      for _, x in ipairs(columns) do
        local r, g, b = pixelOf(shutMain, 256, x, y)
        assertSameColor(r, g, b, 0, 0, 0, 0.08, "the sourced shutter starts with main masked")
        local sr, sg, sb = pixelOf(shutSub, 256, x, y)
        assertSameColor(sr, sg, sb, 0, 0, 0, 0.08, "the sourced shutter starts with sub masked")
      end
    end
    advance(movie, 8)
    movie:draw()
    local main = sourceBytes(scope, movie.mainCanvas)
    local sub = sourceBytes(scope, movie.subCanvas)
    Assert.isTrue(changeFraction(shutMain, main, 256, 192) > 0.05, "the main shutter opens its center band")
    Assert.equal(changeFraction(shutSub, sub, 256, 192), 0, "the sub shutter waits fully masked while main runs")
    for _, x in ipairs(columns) do
      local tr, tg, tb = pixelOf(main, 256, x, 8)
      assertSameColor(tr, tg, tb, 0, 0, 0, 0.12, "the sourced main shutter still masks its top edge")
    end
    Assert.isTrue(changeFraction(main, shutMain, 256, 192) > 0.05, "the opened center differs from the masked start")
    if t0Main == nil then
      t0Main, t0Sub, midMain, midSub = shutMain, shutSub, main, sub
    else
      Assert.equal(main, midMain, ("the main shutter owns its engine on the %s stage"):format(layout.kind))
      Assert.equal(sub, midSub, ("the sub shutter owns its engine on the %s stage"):format(layout.kind))
    end
    advance(movie, 9)
    movie:draw()
    local slot = assert(movie.current, "the running movie owns its current slot")
    Assert.isFalse(slot.effects["scene5-shutter"].done, "the sourced shutter waits past the main finish")
    Assert.equal(changeFraction(shutSub, sourceBytes(scope, movie.subCanvas), 256, 192), 0, "sub still waits at the main finish")
    local handedOff = false
    for _ = 1, 36 do
      movie:updateFixed()
      -- Engine targets refresh only on draw, so each tick is composed
      -- before sampling the sub target for the main-to-sub handoff.
      movie:draw()
      if changeFraction(shutSub, sourceBytes(scope, movie.subCanvas), 256, 192) > 0 then
        handedOff = true
        break
      end
    end
    Assert.isTrue(handedOff, "the sourced sub shutter starts after main completes")
    -- The handoff frame is freshly drawn above; the mid-sub opening is
    -- watched tick by tick against it. Every sampled frame is composed
    -- first: without a draw per tick the canvas keeps the handoff frame,
    -- no further movement is ever observed, and the bound below fails.
    movie:draw()
    local handoffSub = sourceBytes(scope, movie.subCanvas)
    local firstSubMoveAt = nil
    for tick = 1, 200 do
      movie:updateFixed()
      -- Engine targets refresh only on draw, so each tick is composed
      -- before sampling the sub target for the bottom-up opening.
      movie:draw()
      if changeFraction(handoffSub, sourceBytes(scope, movie.subCanvas), 256, 192) > 0.02 then
        firstSubMoveAt = tick
        break
      end
    end
    Assert.notNil(firstSubMoveAt, "the sourced sub shutter visibly opens on a freshly drawn frame")
    local subMid = sourceBytes(scope, movie.subCanvas)
    local litBottom = false
    for _, x in ipairs(columns) do
      local r, g, b = pixelOf(subMid, 256, x, 180)
      if r + g + b > 0.08 then
        litBottom = true
      end
      local tr, tg, tb = pixelOf(subMid, 256, x, 8)
      assertSameColor(tr, tg, tb, 0, 0, 0, 0.12, "the sourced sub shutter still masks its top edge")
    end
    Assert.isTrue(litBottom, "the sourced sub shutter opens its bottom band first")
    local finished = false
    for _ = 1, 200 do
      movie:updateFixed()
      if assert(movie.current, "the running movie owns its current slot").effects["scene5-shutter"].done then
        finished = true
        break
      end
    end
    Assert.isTrue(finished, "both sourced engine cleanups terminate the shutter wait")
    local waited = false
    for _ = 1, 200 do
      movie:updateFixed()
      if currentStepId(movie) == "wait-bg-scroll" then
        waited = true
        break
      end
    end
    Assert.isTrue(waited, "the scroll wait releases only after both cleanups")
    movie:dispose()
  end
end

local function heartgold_scene_two_wipe_is_blocked_without_a_dump(scope, context)
  if not RomImporter.isReady("heartgold") then
    context:skip(
      "BLOCKED: HeartGold final wipe needs a user-owned HeartGold dump; "
        .. "only SoulSilver is ready here, so the sourced kind and white-hold legs "
        .. "cannot run for HeartGold and are never faked"
    )
  end
  local scenes = loadScenes("heartgold")
  local wipes = {}
  for _, event in ipairs(scenes[2].timeline.events) do
    if event.op == "circleWipe" then
      wipes[#wipes + 1] = event
    end
  end
  Assert.equal(#wipes, 1, "the HeartGold second scene carries its single final wipe")
  Assert.equal(wipes[1].kind, 1, "the HeartGold final wipe keeps its source kind")
  Assert.equal(wipes[1].ticks, 8, "the HeartGold final wipe keeps its eight source ticks")
end

local function heartgold_scene_three_beats_are_blocked_without_a_dump(scope, context)
  if not RomImporter.isReady("heartgold") then
    context:skip(
      "BLOCKED: HeartGold town beats need a user-owned HeartGold dump; "
        .. "only SoulSilver is ready here, so the sourced seven-wipe and rival legs "
        .. "cannot run for HeartGold and are never faked"
    )
  end
  local scenes = loadScenes("heartgold")
  local signatures = {}
  for _, event in ipairs(scenes[3].timeline.events) do
    if event.op == "circleWipe" then
      signatures[#signatures + 1] = event.engine .. ":" .. event.kind .. ":" .. event.ticks
    end
  end
  Assert.deepEqual(
    signatures,
    { "main:0:8", "main:3:8", "main:2:8", "main:3:8", "main:2:8", "main:3:8", "sub:2:8" },
    "HeartGold scene 3 keeps its seven source circle wipes in order"
  )
end

local function heartgold_scene_five_shutter_is_blocked_without_a_dump(scope, context)
  if not RomImporter.isReady("heartgold") then
    context:skip(
      "BLOCKED: HeartGold line shutter needs a user-owned HeartGold dump; "
        .. "only SoulSilver is ready here, so the sourced shutter legs "
        .. "cannot run for HeartGold and are never faked"
    )
  end
  local scenes = loadScenes("heartgold")
  local shutters, circles = 0, 0
  for _, event in ipairs(scenes[5].timeline.events) do
    if event.op == "shutterFade" then
      shutters = shutters + 1
    elseif event.op == "circleWipe" then
      circles = circles + 1
    end
  end
  Assert.equal(shutters, 1, "HeartGold scene 5 carries its single sequential line shutter")
  Assert.equal(circles, 0, "HeartGold scene 5 carries no circle wipe")
end

-- Reads the four panorama background displacements out of the running
-- scene-5 slot, so scroll starts show up as source state rather than
-- inferred pixels.
---@param movie table running opening movie
---@return number[] scrollX/scrollY per panorama slot
local function panoramaOffsets(movie)
  local slot = assert(movie.current, "the running movie owns its current slot")
  local found = {}
  for _, engine in ipairs({ "main", "sub" }) do
    for _, bgSlot in ipairs({ 1, 2 }) do
      local background = assert(slot.backgrounds[engine][bgSlot], engine .. " panorama " .. bgSlot .. " stays staged")
      found[#found + 1] = background.scrollX
      found[#found + 1] = background.scrollY
    end
  end
  return found
end

---@param offsets number[] panorama displacements
---@return number summed displacement magnitude
local function totalPanoramaDisplacement(offsets)
  local total = 0
  for _, value in ipairs(offsets) do
    total = total + math.abs(value)
  end
  return total
end

-- The fifth scene holds its four panorama scrolls until the ordered
-- shutter and both engine cleanups finish: the wipe hands off after one
-- dispatch tick, the wait holds with no scroll program through the main
-- finish and the sub phase, and the first scroll increment lands only
-- after the named shutter completes and the begin-scroll case dispatches.
local function soulsilver_scene_five_scroll_starts_only_after_both_shutter_cleanups(scope, context)
  if not RomImporter.isReady("soulsilver") then
    context:skip("SoulSilver panorama scroll needs a user-owned SoulSilver ROM")
  end
  local movie = openMovie(scope, "soulsilver", 512, 384, "dual")
  advanceToSceneStep(movie, 5, "wipe", 20000)
  -- The wipe entry dispatches the ordered shutter on the following update
  -- and hands off at once: the successor is selected, never dispatched,
  -- in the same source tick.
  movie:updateFixed()
  Assert.equal(currentStepId(movie), "wait-wipe", "the wipe hands off after its single dispatch tick")
  movie:draw()
  local slot = assert(movie.current, "the running movie owns its current slot")
  Assert.notNil(slot.effects["scene5-shutter"], "the wipe dispatch starts the ordered shutter")
  Assert.isFalse(slot.effects["scene5-shutter"].done, "the ordered shutter runs past its dispatch")
  Assert.isNil(slot.effects["scroll-panorama"], "no panorama scroll starts with the shutter")
  local parked = panoramaOffsets(movie)
  Assert.isNil(
    assert(movie.current, "the running movie owns its current slot").effects["scroll-panorama"],
    "the shutter wait starts no scroll on entry"
  )
  -- The main finish still waits: the first engine cleanup runs while the
  -- sub engine stays masked, and no scroll may start between the phases.
  local mainDone = false
  for _ = 1, 120 do
    movie:updateFixed()
    local live = assert(movie.current, "the running movie owns its current slot")
    if live.shutter ~= nil and (live.shutter.sub.elapsed > 0 or live.shutter.active == "sub") then
      mainDone = true
      break
    end
  end
  Assert.isTrue(mainDone, "the main shutter hands off to the sub phase")
  local live = assert(movie.current, "the running movie owns its current slot")
  Assert.isFalse(live.effects["scene5-shutter"].done, "the shutter wait stays pending between the phases")
  Assert.isNil(live.effects["scroll-panorama"], "no panorama scroll starts between the shutter phases")
  Assert.deepEqual(panoramaOffsets(movie), parked, "the panorama stays parked between the shutter phases")
  Assert.equal(currentStepId(movie), "wait-wipe", "the shutter wait holds through the engine handoff")
  -- The sub phase and its cleanup still gate every scroll program.
  local subMid = false
  for _ = 1, 200 do
    movie:updateFixed()
    local running = assert(movie.current, "the running movie owns its current slot")
    if running.shutter ~= nil and running.shutter.sub.elapsed >= 9 then
      subMid = true
      break
    end
  end
  Assert.isTrue(subMid, "the sub shutter advances bottom-up once active")
  local mid = assert(movie.current, "the running movie owns its current slot")
  Assert.isFalse(mid.effects["scene5-shutter"].done, "the shutter wait stays pending mid-sub")
  Assert.isNil(mid.effects["scroll-panorama"], "no panorama scroll starts mid-sub")
  Assert.equal(currentStepId(movie), "wait-wipe", "the shutter wait holds through the sub phase")
  -- Both cleanups release the shutter wait; the scroll programs fire only
  -- when the begin-scroll case dispatches on a later source tick.
  local finished = false
  for _ = 1, 200 do
    movie:updateFixed()
    if assert(movie.current, "the running movie owns its current slot").effects["scene5-shutter"].done then
      finished = true
      break
    end
  end
  Assert.isTrue(finished, "both engine cleanups terminate the shutter wait")
  Assert.equal(
    currentStepId(movie),
    "begin-scroll",
    "the completed wait selects the scroll case without dispatching it"
  )
  Assert.isNil(
    assert(movie.current, "the running movie owns its current slot").effects["scroll-panorama"],
    "the scroll case fires its programs on the following source tick, never the completion tick"
  )
  -- The parked frame is composed before the dispatch tick: no scroll
  -- pixel may move until the begin-scroll case actually dispatches.
  movie:draw()
  local parkedFrame = sourceBytes(scope, movie.mainCanvas)
  movie:updateFixed()
  Assert.equal(currentStepId(movie), "wait-bg-scroll", "the scroll case dispatches on one source tick")
  local scrolled = assert(movie.current, "the running movie owns its current slot")
  Assert.notNil(scrolled.effects["scroll-panorama"], "the begin-scroll case starts the panorama programs")
  Assert.isFalse(scrolled.effects["scroll-panorama"].done, "the panorama programs run past their dispatch")
  -- One source tick advances each panorama by a seventy-third of its
  -- program, which truncates to zero displacement: drive until the first
  -- visible increment lands, bounded well inside the scroll programs.
  -- Every sampled frame is composed first, so the first scrolled frame
  -- differs from the parked frame only once the scroll truly starts.
  -- Subpixel program steps leave the drawn bytes identical, so the loop
  -- watches painted pixels rather than raw float displacement.
  local pixelMoved = false
  for _ = 1, 10 do
    movie:updateFixed()
    -- Engine targets refresh only on draw, so each tick is composed
    -- before comparing against the parked frame.
    movie:draw()
    local frame = sourceBytes(scope, movie.mainCanvas)
    if changeFraction(parkedFrame, frame, 256, 192) > 0 then
      pixelMoved = true
      break
    end
    Assert.equal(frame, parkedFrame, "no scroll pixel moves before the first visible increment")
  end
  Assert.isTrue(pixelMoved, "the first scroll increment paints pixels past the parked shutter frame")
  Assert.isTrue(
    totalPanoramaDisplacement(panoramaOffsets(movie)) ~= totalPanoramaDisplacement(parked),
    "the first painted increment carries real panorama displacement"
  )
  movie:dispose()
end

-- The fifth scene starts its 50-step white fade at the twentieth scroll
-- tick while the 73-tick panorama keeps running: no fade exists for the
-- first nineteen scroll ticks, white appears on both engines at the
-- boundary while offsets keep changing, and the scene exits when the fade
-- finishes even though the scroll programs have not.
local function soulsilver_scene_five_white_fade_starts_at_scroll_tick_twenty(scope, context)
  if not RomImporter.isReady("soulsilver") then
    context:skip("SoulSilver panorama fade needs a user-owned SoulSilver ROM")
  end
  local movie = openMovie(scope, "soulsilver", 512, 384, "dual")
  advanceToSceneStep(movie, 5, "begin-scroll", 20000)
  -- The begin-scroll entry fires all four panorama programs on the
  -- following update.
  movie:updateFixed()
  movie:draw()
  Assert.equal(currentStepId(movie), "wait-bg-scroll", "the scroll programs hand off to their twenty-tick wait")
  local slot = assert(movie.current, "the running movie owns its current slot")
  Assert.notNil(slot.effects["scroll-panorama"], "the panorama programs run through the scroll wait")
  Assert.isNil(slot.effects["fade-white"], "no white fade exists on the first scroll tick")
  local before = panoramaOffsets(movie)
  local waited = 0
  for _ = 1, 60 do
    if currentStepId(movie) ~= "wait-bg-scroll" then
      break
    end
    movie:updateFixed()
    waited = waited + 1
    local live = assert(movie.current, "the running movie owns its current slot")
    if waited < 20 then
      Assert.isNil(live.effects["fade-white"], "no white fade exists before the twentieth scroll tick")
    end
  end
  Assert.equal(waited, 20, "the scroll wait counts its twenty source ticks")
  Assert.equal(currentStepId(movie), "wait-fade-out", "the twentieth scroll tick hands off to the fade wait")
  local boundary = assert(movie.current, "the running movie owns its current slot")
  Assert.notNil(boundary.effects["fade-white"], "the white fade starts at the scroll boundary")
  Assert.isFalse(boundary.effects["fade-white"].done, "the white fade runs past its start")
  Assert.isFalse(boundary.effects["scroll-panorama"].done, "the panorama keeps running under the white fade")
  local atFadeStart = panoramaOffsets(movie)
  Assert.isTrue(
    totalPanoramaDisplacement(atFadeStart) ~= totalPanoramaDisplacement(before),
    "the panorama advances across the scroll wait"
  )
  movie:draw()
  local fadingMain = sourceBytes(scope, movie.mainCanvas)
  local fadingSub = sourceBytes(scope, movie.subCanvas)
  -- Every sampled frame is composed first: without a draw per tick the
  -- canvases keep the boundary frame and the fade never visibly moves.
  local firstFadeMoveAt = nil
  for tick = 1, 25 do
    movie:updateFixed()
    -- Engine targets refresh only on draw, so each tick is composed
    -- before sampling the fade progression on both engines.
    movie:draw()
    if firstFadeMoveAt == nil
      and changeFraction(fadingMain, sourceBytes(scope, movie.mainCanvas), 256, 192) > 0.05
      and changeFraction(fadingSub, sourceBytes(scope, movie.subCanvas), 256, 192) > 0.05
    then
      firstFadeMoveAt = tick
    end
  end
  Assert.notNil(
    firstFadeMoveAt,
    "the white fade visibly progresses on both engines while scrolling"
  )
  local fading = assert(movie.current, "the running movie owns its current slot")
  Assert.isFalse(fading.effects["scroll-panorama"].done, "the panorama still runs late in the white fade")
  local finished = false
  for _ = 1, 120 do
    movie:updateFixed()
    if assert(movie.current, "the running movie owns its current slot").effects["fade-white"].done then
      finished = true
      break
    end
  end
  Assert.isTrue(finished, "the fifty-step white fade completes")
  local closing = assert(movie.current, "the running movie owns its current slot")
  Assert.isFalse(closing.effects["scroll-panorama"].done, "the panorama has not finished when the fade does")
  for _ = 1, 10 do
    movie:updateFixed()
    if movie:isFinished() then
      break
    end
  end
  Assert.isTrue(movie:isFinished(), "scene completion waits on the fade, not the scroll")
  movie:dispose()
end

-- Counts real love.graphics.newQuad calls so background allocation shows up
-- on actual GPU draws; the wrapper is restored through the scope so later
-- suites keep the real constructor.
---@param scope table test scope owning the restoration
---@return table counter with a mutable calls field
local function countingQuads(scope)
  local realNewQuad = love.graphics.newQuad
  local counter = { calls = 0 }
  love.graphics.newQuad = function(...)
    counter.calls = counter.calls + 1
    return realNewQuad(...)
  end
  scope:own({
    release = function()
      love.graphics.newQuad = realNewQuad
    end,
  })
  return counter
end

-- Records real love.graphics.intersectScissor calls with the bound target
-- so window slicing shows up as several scissor regions on one engine
-- canvas; restored through the scope.
---@param scope table test scope owning the restoration
---@return table log with a mutable regions field
local function countingScissors(scope)
  local realIntersect = love.graphics.intersectScissor
  local log = { regions = {} }
  love.graphics.intersectScissor = function(x, y, w, h)
    log.regions[#log.regions + 1] = { canvas = love.graphics.getCanvas(), x = x, y = y, w = w, h = h }
    return realIntersect(x, y, w, h)
  end
  scope:own({
    release = function()
      love.graphics.intersectScissor = realIntersect
    end,
  })
  return log
end

-- Four-quadrant chart with a fully transparent bottom-left quadrant so the
-- backing plane shows through; every other quadrant stays opaque.
---@param size integer chart edge in pixels
---@param topLeft integer[] RGB corner colors
---@param topRight integer[] RGB corner colors
---@param bottomRight integer[] RGB corner colors
---@return string png bytes of the chart with one transparent quadrant
local function transparentQuadrantsPng(size, topLeft, topRight, bottomRight)
  local half = math.floor(size / 2)
  local rows = {}
  for y = 0, size - 1 do
    local cells = {}
    for x = 0, size - 1 do
      local corner = nil
      if y < half then
        corner = (x < half) and topLeft or topRight
      elseif x >= half then
        corner = bottomRight
      end
      if corner == nil then
        cells[#cells + 1] = string.char(0, 0, 0, 0)
      else
        cells[#cells + 1] = string.char(corner[1], corner[2], corner[3], 255)
      end
    end
    rows[#rows + 1] = table.concat(cells)
  end
  return PngWriter.encode(size, size, table.concat(rows))
end

-- Vertical bands alternating opaque color and fully transparent columns so
-- a backing plane shows through every other stripe.
---@param width integer chart width in pixels
---@param height integer chart height in pixels
---@param color integer[] RGB opaque band color
---@return string png bytes of the striped chart
local function transparentBandsPng(width, height, color)
  local cells = {}
  for _ = 1, height do
    for x = 0, width - 1 do
      if math.floor(x / 32) % 2 == 0 then
        cells[#cells + 1] = string.char(color[1], color[2], color[3], 255)
      else
        cells[#cells + 1] = string.char(0, 0, 0, 0)
      end
    end
  end
  return PngWriter.encode(width, height, table.concat(cells))
end

-- Wrapped backgrounds sample the independent modulo oracle across native
-- extents with transparency, and repeated draws at one source tick
-- allocate no GPU quads on the sprite-free scene.
local function wrapped_backgrounds_match_the_modulo_oracle_without_per_draw_quads(scope)
  local root = sceneArtRoot(1)
  local chartImage = root .. "layers/wrap-chart.png"
  local magentaImage = root .. "layers/wrap-magenta.png"
  local bandsImage = root .. "layers/wrap-bands.png"
  local deepImage = root .. "layers/wrap-deep.png"
  local gray16 = solidPng(16, 16, 128, 128, 128)
  local art = {
    [chartImage] = transparentQuadrantsPng(512, { 255, 0, 0 }, { 0, 255, 0 }, { 255, 255, 0 }),
    [magentaImage] = solidPng(256, 192, 255, 0, 255),
    [bandsImage] = transparentBandsPng(256, 512, { 0, 255, 255 }),
    [deepImage] = solidPng(512, 192, 255, 255, 0),
  }
  local scenes, cacheFs = compositePack(
    compositeScene(
      1,
      {
        compositeLayer(0, chartImage, 512, 512, true, 0),
        compositeLayer(1, magentaImage, 256, 192, true, 1),
      },
      {
        compositeLayer(0, bandsImage, 256, 512, true, 0),
        compositeLayer(1, deepImage, 512, 192, true, 1),
      },
      {},
      { seed = 0, emitters = {} },
      { { id = "show", events = { 1, 2, 3, 4, 5, 6, 7 }, ["until"] = { kind = "duration", ticks = 40 } } },
      {
        { op = "setScroll", stepId = "show", atStepTick = 0, engine = "main", bgSlot = 0, dx = -1, dy = -1, ticks = 0 },
        { op = "setScroll", stepId = "show", atStepTick = 0, engine = "main", bgSlot = 1, dx = 255, dy = 191, ticks = 0 },
        { op = "setScroll", stepId = "show", atStepTick = 0, engine = "sub", bgSlot = 0, dx = 0, dy = 0, ticks = 0 },
        { op = "setScroll", stepId = "show", atStepTick = 0, engine = "sub", bgSlot = 1, dx = 100000, dy = -100001, ticks = 0 },
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
  -- The oracle recomputes every texel from the staged native bytes under
  -- modular arithmetic: negative one wraps to the last texel, width or
  -- height minus one samples the far edge, and the huge offsets land on
  -- their modular residues, with transparency falling through to backing.
  assertEngineMatchesWrappedArt(scope, movie, cacheFs, scenes[1], "main", "chart wrap", {
    [0] = { -1, -1 },
    [1] = { 255, 191 },
  }, {})
  assertEngineMatchesWrappedArt(scope, movie, cacheFs, scenes[1], "sub", "band wrap", {
    [0] = { 0, 0 },
    [1] = { 100000, -100001 },
  }, {})
  local slot = assert(movie.current, "the running movie owns its current slot")
  local scrollX, scrollY = slot.backgrounds.main[0].scrollX, slot.backgrounds.main[0].scrollY
  local counter = countingQuads(scope)
  movie:draw()
  local startMain = sourceBytes(scope, movie.mainCanvas)
  local startSub = sourceBytes(scope, movie.subCanvas)
  local baseline = counter.calls
  for _ = 1, 5 do
    movie:draw()
  end
  Assert.equal(counter.calls, baseline, "repeated draws at one source tick create no background quads")
  Assert.equal(slot.backgrounds.main[0].scrollX, scrollX, "repeated host draws never resample the clock")
  Assert.equal(slot.backgrounds.main[0].scrollY, scrollY, "repeated host draws never resample the clock")
  Assert.equal(sourceBytes(scope, movie.mainCanvas), startMain, "repeated draws paint identical main pixels")
  Assert.equal(sourceBytes(scope, movie.subCanvas), startSub, "repeated draws paint identical sub pixels")
end

-- An alternate-size swap keeps sampling the newly selected extents while a
-- window-sliced pan advances, and neither allocates GPU quads per draw.
local function swapped_alternates_and_window_sliced_pans_keep_wrap_pixels_without_per_draw_quads(scope)
  local root = sceneArtRoot(1)
  local chartImage = root .. "layers/slice-chart.png"
  local bandsImage = root .. "layers/slice-bands.png"
  local altImage = root .. "layers/slice-alt.png"
  local groundImage = root .. "layers/slice-ground.png"
  local gray16 = solidPng(16, 16, 128, 128, 128)
  local art = {
    [chartImage] = quadrantPng(512, { 255, 0, 0 }, { 0, 255, 0 }, { 0, 0, 255 }, { 255, 255, 0 }),
    [bandsImage] = halvesPng(256, 512, { 0, 255, 255 }, { 255, 255, 0 }),
    [altImage] = halvesPng(256, 192, { 255, 0, 255 }, { 0, 255, 255 }),
    [groundImage] = solidPng(256, 192, 40, 40, 40),
  }
  local scenes, cacheFs = compositePack(
    compositeScene(
      1,
      { compositeLayer(0, chartImage, 512, 512, true, 0) },
      {
        {
          bgSlot = 0,
          priority = 0,
          image = bandsImage,
          variants = { { image = altImage, width = 256, height = 192 } },
          width = 256,
          height = 512,
          sourceHash = string.rep("c", 40),
          initialVisible = true,
        },
      },
      {},
      { seed = 0, emitters = {} },
      { { id = "show", events = { 1, 2, 3, 4, 5, 6, 7 }, ["until"] = { kind = "duration", ticks = 40 } } },
      {
        { op = "setScroll", stepId = "show", atStepTick = 0, engine = "main", bgSlot = 0, dx = -512, dy = 0, ticks = 8 },
        {
          op = "window",
          stepId = "show",
          atStepTick = 0,
          engine = "main",
          from = { x1 = 0, y1 = 0, x2 = 127, y2 = 191 },
          to = { x1 = 128, y1 = 0, x2 = 255, y2 = 191 },
          ticks = 40,
          insideMask = 19,
          outsideMask = 19,
        },
        { op = "setScroll", stepId = "show", atStepTick = 0, engine = "sub", bgSlot = 0, dx = 0, dy = 0, ticks = 0 },
        { op = "setLayer", stepId = "show", atStepTick = 20, engine = "sub", bgSlot = 0, image = altImage, visible = true, priority = 0 },
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
  assertEngineMatchesWrappedArt(scope, movie, cacheFs, scenes[1], "sub", "pre-swap bands", {
    [0] = { 0, 0 },
  }, {})
  local counter = countingQuads(scope)
  local scissors = countingScissors(scope)
  movie:draw()
  local scissorBaseline = #scissors.regions
  movie:draw()
  local mainRegions = {}
  for index = scissorBaseline + 1, #scissors.regions do
    local region = scissors.regions[index]
    if region.canvas == movie.mainCanvas then
      mainRegions[#mainRegions + 1] = region
    end
  end
  Assert.isTrue(#mainRegions >= 2, "the active window slices the panning plane into several scissor regions")
  local quadBaseline = counter.calls
  for _ = 1, 20 do
    movie:updateFixed()
    movie:draw()
  end
  Assert.equal(counter.calls, quadBaseline, "the window-sliced pan and the alternate swap create no quads")
  local slot = assert(movie.current, "the running movie owns its current slot")
  Assert.equal(slot.backgrounds.sub[0].image, altImage, "the swap lands on its authored tick")
  movie:draw()
  assertEngineMatchesWrappedArt(scope, movie, cacheFs, scenes[1], "sub", "post-swap alternate", {
    [0] = { 0, 0 },
  }, {})
  local startMain = sourceBytes(scope, movie.mainCanvas)
  movie:draw()
  movie:draw()
  Assert.equal(sourceBytes(scope, movie.mainCanvas), startMain, "repeated windowed draws paint identical pixels")
end

-- Reads the live signed offsets of every visible panel on one engine so
-- the wrap comparison needs no hardcoded edition numbers.
---@param movie table running opening movie
---@return table<integer, integer[]> authored offsets by bg slot
local function liveEngineOffsets(movie, engine)
  local slot = assert(movie.current, "the running movie owns its current slot")
  local expected = {}
  for bgSlot, background in pairs(slot.backgrounds[engine]) do
    if background.visible then
      expected[bgSlot] = { math.floor(background.scrollX), math.floor(background.scrollY) }
    end
  end
  return expected
end

-- Real-edition scene 2 and scene 5 wrap stays pixel-exact under the
-- modular oracle while repeated renders at one source tick allocate no
-- GPU quads; the pan still moves source pixels between the samples.
local function sourced_wrap_stays_bounded_without_per_draw_quads(scope, versionId)
  local scenes, cacheFs = loadRomPackWithFillers(versionId, { 3, 4 })
  local movie = openMovieWithCache(scope, scenes, cacheFs, versionId, 512, 384, "single")
  advanceToSceneStep(movie, 2, "flyin", 20000)
  advance(movie, 5)
  movie:draw()
  assertEngineMatchesWrappedArt(scope, movie, cacheFs, scenes[2], "main", "scene 2 flyin wrap", liveEngineOffsets(movie, "main"), {})
  assertEngineMatchesWrappedArt(scope, movie, cacheFs, scenes[2], "sub", "scene 2 flyin wrap", liveEngineOffsets(movie, "sub"), {})
  local counter = countingQuads(scope)
  movie:draw()
  local startMain = sourceBytes(scope, movie.mainCanvas)
  local quadBaseline = counter.calls
  for _ = 1, 5 do
    movie:draw()
  end
  Assert.equal(quadBaseline, counter.calls, "repeated scene 2 draws at one source tick create no new quads")
  Assert.equal(sourceBytes(scope, movie.mainCanvas), startMain, "repeated scene 2 draws paint identical pixels")
  for _ = 1, 30 do
    movie:updateFixed()
    movie:draw()
  end
  Assert.isTrue(sourceBytes(scope, movie.mainCanvas) ~= startMain, "the scene 2 pan still moves source pixels")
  movie:draw()
  assertEngineMatchesWrappedArt(scope, movie, cacheFs, scenes[2], "main", "scene 2 mid-pan wrap", liveEngineOffsets(movie, "main"), {})
  movie:dispose()
  local lateScenes, lateCache = loadRomPackWithFillers(versionId, { 3, 4 })
  local late = openMovieWithCache(scope, lateScenes, lateCache, versionId, 512, 384, "single")
  advanceToSceneStep(late, 5, "wait-bg-scroll", 20000)
  -- The scroll programs start once the ordered shutter and its cleanup
  -- complete; sample the running panorama before the concurrent white
  -- fade at the twentieth scroll tick washes the comparison.
  advance(late, 18)
  late:draw()
  assertEngineMatchesWrappedArt(scope, late, lateCache, lateScenes[5], "main", "scene 5 late wrap", liveEngineOffsets(late, "main"), {})
  assertEngineMatchesWrappedArt(scope, late, lateCache, lateScenes[5], "sub", "scene 5 late wrap", liveEngineOffsets(late, "sub"), {})
  local lateCounter = countingQuads(scope)
  late:draw()
  local lateStart = sourceBytes(scope, late.mainCanvas)
  local lateBaseline = lateCounter.calls
  for _ = 1, 5 do
    late:draw()
  end
  Assert.equal(lateBaseline, lateCounter.calls, "repeated scene 5 draws at one source tick create no new quads")
  Assert.equal(sourceBytes(scope, late.mainCanvas), lateStart, "repeated scene 5 draws paint identical pixels")
  late:dispose()
end

local function soulsilver_scene_two_and_five_wrap_stays_bounded_without_per_draw_quads(scope, context)
  sourced_wrap_stays_bounded_without_per_draw_quads(scope, selectedVersionId(context))
end

local function heartgold_scene_two_and_five_wrap_is_blocked_without_a_dump(scope, context)
  if not RomImporter.isReady("heartgold") then
    context:skip(
      "BLOCKED: HeartGold scene 2 and 5 wrap needs a user-owned HeartGold dump; "
        .. "only SoulSilver is ready here, so the sourced wrap and quad legs "
        .. "cannot run for HeartGold and are never faked"
    )
  end
  sourced_wrap_stays_bounded_without_per_draw_quads(scope, "heartgold")
end

-- The retail title object translation both 3D title objects inherit
-- (title_screen.c TitleScreen_Load3DObjects): source (30, 95, 0) carried in
-- the same /16 world units the existing title camera adopts. The expected
-- values below spell the retail operand literally so the assertions anchor
-- on the decompilation, never on the player's current framing.
local TITLE_SOURCE_X, TITLE_SOURCE_Y, TITLE_SOURCE_Z = 30 / 16, 95 / 16, 0
local TITLE_HALF_ANGLE_INDEX = 0xB60
local TITLE_NATIVE_WIDTH, TITLE_NATIVE_HEIGHT = 256, 192

local function titleTopology(width, height)
  return {
    surfaces = {
      { id = "main", rect = { x = 0, y = 0, width = width, height = height }, touch = true, role = "world" },
    },
  }
end

local function openTitleScene(scope, versionId)
  local HgssTitleScene = require("libs.hgss.src.presentation.HgssTitleScene")
  local context = DisplayContext.new({
    graphics = love.graphics,
    topologyProvider = function(width, height)
      return titleTopology(width, height)
    end,
  })
  local scene = HgssTitleScene.new({
    versionId = versionId,
    cacheFs = CacheFs.forVersion(versionId),
    width = TITLE_NATIVE_WIDTH,
    height = TITLE_NATIVE_HEIGHT,
    displayContext = context,
  })
  scope:own({
    release = function()
      scene:dispose()
    end,
  })
  return scene
end

-- Projects a world-space point through column-major view and projection
-- matrices onto the native title target, returning device pixels.
local function titlePixel(view, projection, x, y, z)
  local Matrix4 = require("libs.math.src.Matrix4")
  local vx, vy, vz, vw = Matrix4.transformPoint(view, x, y, z)
  local cx = projection[1] * vx + projection[5] * vy + projection[9] * vz + projection[13]
  local cy = projection[2] * vx + projection[6] * vy + projection[10] * vz + projection[14]
  local cw = projection[4] * vx + projection[8] * vy + projection[12] * vz + projection[16]
  Assert.isTrue(cw ~= 0, "the placed title origin stays in front of the sourced lens")
  return (cx / cw * 0.5 + 0.5) * TITLE_NATIVE_WIDTH, (1 - (cy / cw * 0.5 + 0.5)) * TITLE_NATIVE_HEIGHT
end

local function expectedTitleCamera(scene, Matrix4)
  local timeline = assert(scene.bundle.timeline, "title bundle carries its camera timeline")
  local rawTarget = assert(timeline.camera.target, "title bundle carries its camera target")
  local unit = 1 / 16
  local eye = { scene.cameraPos[1] * unit, scene.cameraPos[2] * unit, scene.cameraPos[3] * unit }
  local target = { rawTarget[1] * unit, rawTarget[2] * unit, rawTarget[3] * unit }
  local halfAngle = (TITLE_HALF_ANGLE_INDEX / 65536) * (2 * math.pi)
  return Matrix4.lookAt(eye, target, { 0, 1, 0 }),
    Matrix4.perspective(2 * halfAngle, TITLE_NATIVE_WIDTH / TITLE_NATIVE_HEIGHT, 1, 5000)
end

local function title_legend_carries_its_retail_placement(scope, versionId)
  local Matrix4 = require("libs.math.src.Matrix4")
  local scene = openTitleScene(scope, versionId)
  local want = Matrix4.translate(TITLE_SOURCE_X, TITLE_SOURCE_Y, TITLE_SOURCE_Z)
  Assert.deepEqual(
    scene.legend.transform,
    want,
    "the " .. versionId .. " legendary inherits the retail object translation"
  )
  local camera = scene:_camera()
  local wantView, wantProjection = expectedTitleCamera(scene, Matrix4)
  Assert.deepEqual(camera.view(), wantView, "placing the legendary never moves the sourced camera")
  Assert.deepEqual(camera.projection(), wantProjection, "placing the legendary never retunes the sourced lens")
  local actualX, actualY, actualZ = Matrix4.transformPoint(scene.legend.transform, 0, 0, 0)
  Assert.near(actualX, TITLE_SOURCE_X, 1e-9, "the legendary origin lands on the retail x")
  Assert.near(actualY, TITLE_SOURCE_Y, 1e-9, "the legendary origin lands on the retail y")
  Assert.near(actualZ, TITLE_SOURCE_Z, 1e-9, "the legendary origin lands on the retail z")
  local pixelX, pixelY = titlePixel(camera.view(), camera.projection(), actualX, actualY, actualZ)
  local expectedX, expectedY =
    titlePixel(camera.view(), camera.projection(), TITLE_SOURCE_X, TITLE_SOURCE_Y, TITLE_SOURCE_Z)
  Assert.near(pixelX, expectedX, 1e-6, "the legendary projects onto its retail screen point")
  Assert.near(pixelY, expectedY, 1e-6, "the legendary projects onto its retail screen line")
  local guard = 0
  while scene.cameraPointIndex == 1 and guard < 5000 do
    scene:updateFixed()
    guard = guard + 1
  end
  Assert.equal(scene.cameraPointIndex, 2, "the title camera reaches its later waypoint")
  Assert.deepEqual(
    scene.legend.transform,
    want,
    "the traveling legendary keeps its retail placement at the later waypoint"
  )
  local laterView, _ = expectedTitleCamera(scene, Matrix4)
  Assert.deepEqual(scene:_camera().view(), laterView, "the later waypoint still composes eye and target in world units")
  local laterX, laterY = titlePixel(
    scene:_camera().view(),
    scene:_camera().projection(),
    Matrix4.transformPoint(scene.legend.transform, 0, 0, 0)
  )
  local laterExpectedX, laterExpectedY = titlePixel(
    scene:_camera().view(),
    scene:_camera().projection(),
    TITLE_SOURCE_X,
    TITLE_SOURCE_Y,
    TITLE_SOURCE_Z
  )
  Assert.near(laterX, laterExpectedX, 1e-6, "the traveling legendary still projects onto its retail point")
  Assert.near(laterY, laterExpectedY, 1e-6, "the traveling legendary still projects onto its retail line")
  scene:_drawModel()
  local bytes = sourceBytes(scope, assert(scene.canvas, "the title keeps its native target"))
  local painted = 0
  for i = 4, #bytes, 4 do
    if string.byte(bytes, i) > 0 then
      painted = painted + 1
    end
  end
  Assert.isTrue(painted > 0, "the placed legendary paints its native target instead of being culled")
  scene:dispose()
end

local function title_sparkle_shares_the_retail_placement(scope, versionId)
  local Matrix4 = require("libs.math.src.Matrix4")
  local scene = openTitleScene(scope, versionId)
  local want = Matrix4.translate(TITLE_SOURCE_X, TITLE_SOURCE_Y, TITLE_SOURCE_Z)
  Assert.deepEqual(
    scene.sparkle.transform,
    want,
    "the " .. versionId .. " sparkle inherits the same retail object translation"
  )
  Assert.deepEqual(
    scene.sparkle.transform,
    scene.legend.transform,
    "legend and sparkle share one source placement"
  )
  Assert.isTrue(scene.legend ~= scene.sparkle, "legend and sparkle stay independent instances")
  Assert.isTrue(
    scene.legend.animationState ~= scene.sparkle.animationState,
    "legend and sparkle keep independent animation state"
  )
  local view, projection = scene:_camera().view(), scene:_camera().projection()
  for _ = 1, 10 do
    scene:updateFixed()
  end
  Assert.deepEqual(
    scene.sparkle.transform,
    want,
    "advancing the title clock never moves the sparkle placement"
  )
  Assert.deepEqual(scene:_camera().view(), view, "the sparkle placement never moves the sourced camera")
  Assert.deepEqual(scene:_camera().projection(), projection, "the sparkle placement never retunes the sourced lens")
  scene:dispose()
end

local function soulsilver_title_legend_carries_its_retail_placement(scope, context)
  if not RomImporter.isReady("soulsilver") then
    context:skip("SoulSilver title placement needs a user-owned SoulSilver dump")
  end
  title_legend_carries_its_retail_placement(scope, "soulsilver")
end

local function soulsilver_title_sparkle_shares_the_retail_placement(scope, context)
  if not RomImporter.isReady("soulsilver") then
    context:skip("SoulSilver title placement needs a user-owned SoulSilver dump")
  end
  title_sparkle_shares_the_retail_placement(scope, "soulsilver")
end

local function heartgold_title_placement_is_blocked_without_a_dump(scope, context)
  if not RomImporter.isReady("heartgold") then
    context:skip(
      "BLOCKED: HeartGold title placement needs a user-owned HeartGold dump; "
        .. "only SoulSilver is ready here, so the legendary and sparkle retail translation legs "
        .. "cannot run for HeartGold and are never faked"
    )
  end
  title_legend_carries_its_retail_placement(scope, "heartgold")
  title_sparkle_shares_the_retail_placement(scope, "heartgold")
end
-- One retail case per 30 Hz fixed update: four one-dispatch cases (appear,
-- parallel scroll starts, an effect wait, and a screen flip carrying the
-- movie finish) must each occupy their own update, and the next scene entry
-- must not dispatch on the finishing update.
local function source_cases_dispatch_one_per_fixed_update(scope)
  local gray16 = solidPng(16, 16, 128, 128, 128)
  local root1 = sceneArtRoot(1)
  local base1 = root1 .. "layers/case-base.png"
  local sub1 = root1 .. "layers/case-sub.png"
  local root2 = sceneArtRoot(2)
  local base2 = root2 .. "layers/case-base.png"
  local sub2 = root2 .. "layers/case-sub.png"
  local first = compositeScene(
    1,
    { compositeLayer(0, base1, 256, 192) },
    { compositeLayer(0, sub1, 256, 192) },
    {},
    { seed = 0, emitters = {} },
    {
      { id = "appear", events = { 1, 2 }, ["until"] = { kind = "duration", ticks = 1 } },
      { id = "start", events = { 3, 4 }, ["until"] = { kind = "duration", ticks = 1 } },
      { id = "wait", events = { 5 }, ["until"] = { kind = "effect", effect = "scroll-main" } },
      { id = "flip", events = { 6, 7, 8, 9 }, ["until"] = { kind = "duration", ticks = 1 } },
    },
    {
      {
        op = "setLayer",
        stepId = "appear",
        atStepTick = 0,
        engine = "main",
        bgSlot = 0,
        image = base1,
        visible = true,
        priority = 0,
      },
      { op = "waitTicks", stepId = "appear", atStepTick = 0, ticks = 1 },
      {
        op = "setScroll",
        stepId = "start",
        atStepTick = 0,
        engine = "main",
        bgSlot = 0,
        dx = 8,
        dy = 0,
        ticks = 2,
        effect = "scroll-main",
      },
      {
        op = "setScroll",
        stepId = "start",
        atStepTick = 0,
        engine = "sub",
        bgSlot = 0,
        dx = 8,
        dy = 0,
        ticks = 2,
        effect = "scroll-sub",
      },
      { op = "waitTicks", stepId = "wait", atStepTick = 0, ticks = 5 },
      { op = "setScreenMapping", stepId = "flip", atStepTick = 0, mainPhysical = "lower" },
      { op = "waitTicks", stepId = "flip", atStepTick = 0, ticks = 1 },
      { op = "finish", stepId = "flip", atStepTick = 0 },
      { op = "enableSkip", stepId = "flip", atStepTick = 1 },
    }
  )
  local second = compositeScene(
    2,
    { compositeLayer(0, base2, 256, 192) },
    { compositeLayer(0, sub2, 256, 192) },
    {},
    { seed = 0, emitters = {} },
    {
      { id = "entry", events = { 1, 2 }, ["until"] = { kind = "duration", ticks = 3 } },
    },
    {
      { op = "setScreenMapping", stepId = "entry", atStepTick = 0, mainPhysical = "lower" },
      { op = "waitTicks", stepId = "entry", atStepTick = 0, ticks = 3 },
    }
  )
  local raw = { first, second, fillerScene(3), fillerScene(4), fillerScene(5) }
  local byPath = {}
  for sceneNumber, manifest in ipairs(raw) do
    byPath[StartupAssetCache.openingScenePath(sceneNumber)] = manifest
  end
  local art = {
    [base1] = gray16,
    [sub1] = gray16,
    [base2] = gray16,
    [sub2] = gray16,
  }
  local cacheFs = {
    loadLua = function(_, path)
      return byPath[path]
    end,
    exists = function()
      return true
    end,
    read = function(_, path)
      return art[path] or gray16
    end,
  }
  local scenes = {}
  for sceneNumber = 1, 5 do
    local loaded, err = StartupAssetCache.loadOpeningScene(cacheFs, sceneNumber, "soulsilver")
    Assert.notNil(loaded, "case scene " .. sceneNumber .. " passes the strict scene reader: " .. tostring(err))
    scenes[sceneNumber] = loaded
  end
  local movie = openCompositeMovie(scope, scenes, cacheFs, 512, 384, "single")
  local seen = {}
  local function observe()
    local slot = assert(movie.current, "the running movie owns its current slot")
    seen[#seen + 1] = {
      scene = movie:sceneNumber(),
      step = currentStepId(movie),
      mainScroll = slot.effects["scroll-main"] ~= nil,
      subScroll = slot.effects["scroll-sub"] ~= nil,
      mapping = slot.mainPhysical,
    }
  end
  observe()
  for _ = 1, 30 do
    movie:updateFixed()
    observe()
    local last = seen[#seen]
    if last.scene == 2 and last.mapping == "lower" then
      break
    end
  end
  Assert.equal(seen[1].scene, 1, "the movie opens on its first scene")
  Assert.equal(seen[1].step, "appear", "the first case is current before the first update")
  Assert.isFalse(seen[1].mainScroll, "no scroll starts before the first update")
  local firstStart, firstWait, firstFlip, firstEntry = nil, nil, nil, nil
  for _, observation in ipairs(seen) do
    if observation.scene == 1 and observation.step == "start" and firstStart == nil then
      firstStart = observation
    elseif observation.scene == 1 and observation.step == "wait" and firstWait == nil then
      firstWait = observation
    elseif observation.scene == 1 and observation.step == "flip" and firstFlip == nil then
      firstFlip = observation
    elseif observation.scene == 2 and firstEntry == nil then
      firstEntry = observation
    end
  end
  Assert.notNil(firstStart, "the start case is current for its own update")
  Assert.notNil(firstWait, "the wait case is current for its own update")
  Assert.notNil(firstFlip, "the flip case is current for its own update")
  Assert.notNil(firstEntry, "the next scene entry is current for its own update")
  Assert.isFalse(
    firstStart.mainScroll,
    "the successor case starts undispatched on its selection update"
  )
  Assert.isTrue(firstWait.mainScroll, "the dispatched start case runs its scroll")
  Assert.isTrue(firstWait.subScroll, "parallel starts within one case begin on the same update")
  Assert.equal(firstFlip.mapping, "upper", "the flip case applies its mapping only on its own dispatch")
  Assert.equal(firstEntry.step, "entry", "the finishing update hands off to the next scene entry")
  Assert.equal(
    firstEntry.mapping,
    "upper",
    "the next scene entry stays undispatched on the finishing update"
  )
  movie:dispose()
end

-- A conjunctive guard holds its mutation until every named effect finishes:
-- two independent scrolls of 3 and 5 ticks gate one retile, the retile
-- fires inside the guarded case, and the following case waits its own tick.
local function conjunctive_effect_guard_holds_mutation_until_both_effects_finish(scope)
  local gray16 = solidPng(16, 16, 128, 128, 128)
  local root = sceneArtRoot(1)
  local base = root .. "layers/guard-base.png"
  local rocket = root .. "layers/guard-rocket.png"
  local sub = root .. "layers/guard-sub.png"
  local mainLayer = compositeLayer(0, base, 256, 192)
  mainLayer.variants = { { image = rocket, width = 256, height = 192 } }
  local custom = compositeScene(
    1,
    { mainLayer },
    { compositeLayer(0, sub, 256, 192) },
    {},
    { seed = 0, emitters = {} },
    {
      { id = "start-scrolls", events = { 1, 2 }, ["until"] = { kind = "duration", ticks = 1 } },
      {
        id = "guarded-retile",
        events = {},
        onCompleteEvents = { 3 },
        ["until"] = { kind = "effects", effects = { "scroll-a", "scroll-b" } },
      },
      { id = "follow", events = { 4, 5 }, ["until"] = { kind = "duration", ticks = 2 } },
    },
    {
      {
        op = "setScroll",
        stepId = "start-scrolls",
        atStepTick = 0,
        engine = "main",
        bgSlot = 0,
        dx = 8,
        dy = 0,
        ticks = 3,
        effect = "scroll-a",
      },
      {
        op = "setScroll",
        stepId = "start-scrolls",
        atStepTick = 0,
        engine = "sub",
        bgSlot = 0,
        dx = 8,
        dy = 0,
        ticks = 5,
        effect = "scroll-b",
      },
      {
        op = "setLayer",
        stepId = "guarded-retile",
        atStepTick = 0,
        engine = "main",
        bgSlot = 0,
        image = rocket,
        visible = true,
        priority = 0,
      },
      { op = "waitTicks", stepId = "follow", atStepTick = 0, ticks = 2 },
      { op = "enableSkip", stepId = "follow", atStepTick = 1 },
    }
  )
  local art = { [base] = gray16, [rocket] = solidPng(16, 16, 200, 40, 40), [sub] = gray16 }
  local scenes, cacheFs = compositePackAt(custom, 1, art, gray16)
  local movie = openCompositeMovie(scope, scenes, cacheFs, 512, 384, "single")
  -- The guarded mutation and the successor selection share one update by
  -- design, so each observation records the case running at the update
  -- start alongside the post-update state.
  local seen = {}
  for _ = 1, 20 do
    local before = currentStepId(movie)
    movie:updateFixed()
    local slot = assert(movie.current, "the running movie owns its current slot")
    local background = assert(slot.backgrounds.main[0], "the guarded main plane stays staged")
    seen[#seen + 1] = {
      before = before,
      step = currentStepId(movie),
      elapsed = slot.stepElapsed,
      skip = movie:skipAllowed(),
      aDone = slot.effects["scroll-a"] ~= nil and slot.effects["scroll-a"].done == true,
      bDone = slot.effects["scroll-b"] ~= nil and slot.effects["scroll-b"].done == true,
      image = background.image,
    }
    if currentStepId(movie) == "follow" and slot.stepElapsed >= 1 then
      break
    end
  end
  local retileAt = nil
  for index, observation in ipairs(seen) do
    if observation.image == rocket then
      retileAt = index
      break
    end
  end
  Assert.notNil(retileAt, "the guarded retile fires once both scrolls finish")
  local retile = seen[retileAt]
  Assert.isTrue(retile.aDone, "the first scroll finishes before the guarded mutation")
  Assert.isTrue(retile.bDone, "the second scroll finishes before the guarded mutation")
  Assert.equal(retile.before, "guarded-retile", "the guarded mutation fires inside its own case")
  for index = 1, retileAt - 1 do
    local observation = seen[index]
    if observation.aDone and not observation.bDone then
      Assert.equal(
        observation.image,
        base,
        "the retile stays absent while only the first scroll has finished"
      )
    end
  end
  Assert.equal(retile.step, "follow", "the guarded update selects the following case")
  Assert.equal(retile.elapsed, 0, "the following case starts undispatched on its selection update")
  Assert.isFalse(retile.skip, "the following case applies its entry only on its own update")
  Assert.equal(seen[retileAt + 1].image, rocket, "the guarded retile survives into the following case")
  movie:dispose()
end

-- Scoped engine-local brightness fades with terminal holds: a sub-engine
-- brightness-out with a hold leaves the main target untouched throughout,
-- turns sub black by its final tick, and keeps sub black across the step
-- boundary until an authored reset.
local function scoped_sub_brightness_out_holds_black_while_main_stays_clear(scope)
  local root = sceneArtRoot(1)
  local mainImage = root .. "layers/fade-main.png"
  local subImage = root .. "layers/fade-sub.png"
  local gray16 = solidPng(16, 16, 128, 128, 128)
  local steps = {
    { id = "setup", events = { 1, 2 }, ["until"] = { kind = "duration", ticks = 2 } },
    { id = "fade", events = { 3 }, ["until"] = { kind = "effect", effect = "fade-sub" } },
    { id = "tail", events = { 4, 5 }, ["until"] = { kind = "duration", ticks = 6 } },
  }
  local events = {
    { op = "waitTicks", stepId = "setup", atStepTick = 0, ticks = 2 },
    { op = "enableSkip", stepId = "setup", atStepTick = 1 },
    {
      op = "setFade",
      stepId = "fade",
      atStepTick = 0,
      scope = "sub",
      mode = "brightness",
      color = "black",
      direction = "out",
      ticks = 8,
      terminal = "hold",
      effect = "fade-sub",
    },
    { op = "waitTicks", stepId = "tail", atStepTick = 0, ticks = 6 },
    { op = "finish", stepId = "tail", atStepTick = 0 },
  }
  local scenes, cacheFs = compositePack(
    compositeScene(
      1,
      { compositeLayer(0, mainImage, 256, 192) },
      { compositeLayer(0, subImage, 256, 192) },
      {},
      { seed = 0, emitters = {} },
      steps,
      events
    ),
    {
      [mainImage] = solidPng(256, 192, 255, 0, 0),
      [subImage] = solidPng(256, 192, 0, 255, 0),
    },
    gray16
  )
  local movie = openCompositeMovie(scope, scenes, cacheFs, 512, 384, "dual")
  advance(movie, 2)
  movie:draw()
  local mr, mg, mb = pixelOf(sourceBytes(scope, movie.mainCanvas), 256, 128, 96)
  assertSameColor(mr, mg, mb, 1, 0, 0, 0.08, "main stays clear before the sub fade")
  local sr, sg, sb = pixelOf(sourceBytes(scope, movie.subCanvas), 256, 128, 96)
  assertSameColor(sr, sg, sb, 0, 1, 0, 0.08, "sub starts on its authored art")
  advance(movie, 4)
  movie:draw()
  local hr, hg, hb = pixelOf(sourceBytes(scope, movie.mainCanvas), 256, 128, 96)
  assertSameColor(hr, hg, hb, 1, 0, 0, 0.08, "main stays clear mid-way through the sub fade")
  local qr, qg, qb = pixelOf(sourceBytes(scope, movie.subCanvas), 256, 128, 96)
  Assert.near(qg, 0.5, 0.14, "sub is mid-transition half-way through its fade")
  advance(movie, 4)
  movie:draw()
  local fr, fg, fb = pixelOf(sourceBytes(scope, movie.mainCanvas), 256, 128, 96)
  assertSameColor(fr, fg, fb, 1, 0, 0, 0.08, "main stays clear when the sub fade completes")
  local br, bg, bb = pixelOf(sourceBytes(scope, movie.subCanvas), 256, 128, 96)
  assertSameColor(br, bg, bb, 0, 0, 0, 0.08, "sub reaches black at its final fade tick")
  Assert.equal(currentStepId(movie), "tail", "the named fade effect completes its step")
  advance(movie, 5)
  movie:draw()
  local tr, tg, tb = pixelOf(sourceBytes(scope, movie.subCanvas), 256, 128, 96)
  assertSameColor(tr, tg, tb, 0, 0, 0, 0.08, "sub holds black across the step boundary")
  local ur, ug, ub = pixelOf(sourceBytes(scope, movie.mainCanvas), 256, 128, 96)
  assertSameColor(ur, ug, ub, 1, 0, 0, 0.08, "main stays clear while sub holds black")
  movie:dispose()
end

-- Two-range spatial line shutters on both engines: the center-out open
-- reveals the middle band first while the outer rows stay black, and the
-- outer-in close covers the edge rows first while the middle band stays
-- lit. Identical masks on the left, center, and right columns prove row
-- masks rather than a uniform alpha rectangle.
local function both_engine_line_shutters_sample_source_rows_not_uniform_alpha(scope)
  local root = sceneArtRoot(1)
  local mainImage = root .. "layers/shutter-main.png"
  local subImage = root .. "layers/shutter-sub.png"
  local gray16 = solidPng(16, 16, 128, 128, 128)
  local steps = {
    { id = "setup", events = { 1, 2 }, ["until"] = { kind = "duration", ticks = 1 } },
    { id = "open", events = { 3 }, ["until"] = { kind = "effect", effect = "fade-open" } },
    { id = "close", events = { 4 }, ["until"] = { kind = "effect", effect = "fade-close" } },
    { id = "tail", events = { 5, 6 }, ["until"] = { kind = "duration", ticks = 2 } },
  }
  local events = {
    { op = "waitTicks", stepId = "setup", atStepTick = 0, ticks = 1 },
    { op = "enableSkip", stepId = "setup", atStepTick = 1 },
    {
      op = "setFade",
      stepId = "open",
      atStepTick = 0,
      scope = "both",
      mode = "line-shutter",
      color = "black",
      direction = "in",
      ticks = 10,
      terminal = "neutral",
      shape = "center-out",
      effect = "fade-open",
    },
    {
      op = "setFade",
      stepId = "close",
      atStepTick = 0,
      scope = "both",
      mode = "line-shutter",
      color = "black",
      direction = "out",
      ticks = 26,
      terminal = "hold",
      shape = "outer-in",
      effect = "fade-close",
    },
    { op = "waitTicks", stepId = "tail", atStepTick = 0, ticks = 2 },
    { op = "finish", stepId = "tail", atStepTick = 0 },
  }
  local scenes, cacheFs = compositePack(
    compositeScene(
      1,
      { compositeLayer(0, mainImage, 256, 192) },
      { compositeLayer(0, subImage, 256, 192) },
      {},
      { seed = 0, emitters = {} },
      steps,
      events
    ),
    {
      [mainImage] = solidPng(256, 192, 255, 0, 0),
      [subImage] = solidPng(256, 192, 0, 255, 0),
    },
    gray16
  )
  local movie = openCompositeMovie(scope, scenes, cacheFs, 512, 384, "dual")
  local function assertEngineRow(canvas, artR, artG, artB, y, covered, label)
    for _, x in ipairs({ 32, 128, 224 }) do
      local r, g, b = pixelOf(sourceBytes(scope, canvas), 256, x, y)
      if covered then
        assertSameColor(r, g, b, 0, 0, 0, 0.08, label .. " masks row " .. y)
      else
        assertSameColor(r, g, b, artR, artG, artB, 0.08, label .. " shows row " .. y)
      end
    end
  end
  advance(movie, 1)
  advance(movie, 1)
  movie:draw()
  assertEngineRow(movie.mainCanvas, 1, 0, 0, 8, true, "the open first frame on main")
  assertEngineRow(movie.mainCanvas, 1, 0, 0, 96, false, "the open first frame on main")
  assertEngineRow(movie.mainCanvas, 1, 0, 0, 180, true, "the open first frame on main")
  assertEngineRow(movie.subCanvas, 0, 1, 0, 8, true, "the open first frame on sub")
  assertEngineRow(movie.subCanvas, 0, 1, 0, 96, false, "the open first frame on sub")
  assertEngineRow(movie.subCanvas, 0, 1, 0, 180, true, "the open first frame on sub")
  advance(movie, 4)
  movie:draw()
  assertEngineRow(movie.mainCanvas, 1, 0, 0, 8, true, "the open middle frame on main")
  assertEngineRow(movie.mainCanvas, 1, 0, 0, 96, false, "the open middle frame on main")
  assertEngineRow(movie.mainCanvas, 1, 0, 0, 180, true, "the open middle frame on main")
  assertEngineRow(movie.subCanvas, 0, 1, 0, 8, true, "the open middle frame on sub")
  assertEngineRow(movie.subCanvas, 0, 1, 0, 96, false, "the open middle frame on sub")
  assertEngineRow(movie.subCanvas, 0, 1, 0, 180, true, "the open middle frame on sub")
  advance(movie, 5)
  movie:draw()
  Assert.equal(currentStepId(movie), "close", "the open shutter completes into its close")
  assertEngineRow(movie.mainCanvas, 1, 0, 0, 8, false, "the open final frame on main")
  assertEngineRow(movie.mainCanvas, 1, 0, 0, 96, false, "the open final frame on main")
  assertEngineRow(movie.mainCanvas, 1, 0, 0, 180, false, "the open final frame on main")
  advance(movie, 1)
  movie:draw()
  assertEngineRow(movie.mainCanvas, 1, 0, 0, 2, true, "the close first frame on main")
  assertEngineRow(movie.mainCanvas, 1, 0, 0, 96, false, "the close first frame on main")
  assertEngineRow(movie.subCanvas, 0, 1, 0, 2, true, "the close first frame on sub")
  assertEngineRow(movie.subCanvas, 0, 1, 0, 96, false, "the close first frame on sub")
  advance(movie, 12)
  movie:draw()
  assertEngineRow(movie.mainCanvas, 1, 0, 0, 8, true, "the close middle frame on main")
  assertEngineRow(movie.mainCanvas, 1, 0, 0, 96, false, "the close middle frame on main")
  assertEngineRow(movie.mainCanvas, 1, 0, 0, 180, true, "the close middle frame on main")
  assertEngineRow(movie.subCanvas, 0, 1, 0, 8, true, "the close middle frame on sub")
  assertEngineRow(movie.subCanvas, 0, 1, 0, 96, false, "the close middle frame on sub")
  assertEngineRow(movie.subCanvas, 0, 1, 0, 180, true, "the close middle frame on sub")
  advance(movie, 13)
  movie:draw()
  Assert.equal(currentStepId(movie), "tail", "the close shutter completes into its tail")
  assertEngineRow(movie.mainCanvas, 1, 0, 0, 8, true, "the close final frame on main")
  assertEngineRow(movie.mainCanvas, 1, 0, 0, 96, true, "the close final frame on main")
  assertEngineRow(movie.mainCanvas, 1, 0, 0, 180, true, "the close final frame on main")
  assertEngineRow(movie.subCanvas, 0, 1, 0, 8, true, "the close final frame on sub")
  assertEngineRow(movie.subCanvas, 0, 1, 0, 96, true, "the close final frame on sub")
  assertEngineRow(movie.subCanvas, 0, 1, 0, 180, true, "the close final frame on sub")
  movie:dispose()
end

-- Absolute background origins replace the register and cancel the
-- same-slot scroll: after a running drift pans the wide map, the reset
-- lands back on the origin and later ticks hold it there.
local function absolute_scroll_position_overwrites_and_cancels_the_running_scroll(scope)
  local root = sceneArtRoot(1)
  local mainImage = root .. "layers/scroll-wide.png"
  local subImage = root .. "layers/scroll-sub.png"
  local gray16 = solidPng(16, 16, 128, 128, 128)
  local steps = {
    { id = "setup", events = { 1, 2 }, ["until"] = { kind = "duration", ticks = 1 } },
    { id = "drift", events = { 3 }, ["until"] = { kind = "duration", ticks = 4 } },
    { id = "reset", events = { 4 }, ["until"] = { kind = "duration", ticks = 4 } },
    { id = "tail", events = { 5, 6 }, ["until"] = { kind = "duration", ticks = 2 } },
  }
  local events = {
    { op = "waitTicks", stepId = "setup", atStepTick = 0, ticks = 1 },
    { op = "enableSkip", stepId = "setup", atStepTick = 1 },
    { op = "setScroll", stepId = "drift", atStepTick = 0, engine = "main", bgSlot = 1, dx = 64, dy = 0, ticks = -1 },
    { op = "setScrollPosition", stepId = "reset", atStepTick = 0, engine = "main", bgSlot = 1, x = 0, y = 0 },
    { op = "waitTicks", stepId = "tail", atStepTick = 0, ticks = 2 },
    { op = "finish", stepId = "tail", atStepTick = 0 },
  }
  local left = string.rep(string.char(255, 0, 0, 255), 256)
  local right = string.rep(string.char(0, 0, 255, 255), 256)
  local rows = {}
  for _ = 1, 192 do
    rows[#rows + 1] = left .. right
  end
  local scenes, cacheFs = compositePack(
    compositeScene(
      1,
      { compositeLayer(1, mainImage, 512, 192) },
      { compositeLayer(0, subImage, 256, 192) },
      {},
      { seed = 0, emitters = {} },
      steps,
      events
    ),
    {
      [mainImage] = PngWriter.encode(512, 192, table.concat(rows)),
      [subImage] = solidPng(256, 192, 0, 255, 0),
    },
    gray16
  )
  local movie = openCompositeMovie(scope, scenes, cacheFs, 512, 384, "dual")
  advance(movie, 1)
  advance(movie, 4)
  Assert.equal(currentStepId(movie), "reset", "the drift hands the reset step its scroll")
  local drifted = liveEngineOffsets(movie, "main")
  Assert.equal(drifted[1][1], 256, "the running drift pans the wide map")
  movie:draw()
  local dr, dg, db = pixelOf(sourceBytes(scope, movie.mainCanvas), 256, 0, 96)
  assertSameColor(dr, dg, db, 0, 0, 1, 0.08, "the drifted viewport shows the second half")
  advance(movie, 1)
  movie:draw()
  local reset = liveEngineOffsets(movie, "main")
  Assert.equal(reset[1][1], 0, "the absolute reset overwrites the scrolled origin")
  Assert.equal(reset[1][2], 0, "the absolute reset overwrites the scrolled row")
  local rr, rg, rb = pixelOf(sourceBytes(scope, movie.mainCanvas), 256, 0, 96)
  assertSameColor(rr, rg, rb, 1, 0, 0, 0.08, "the reset viewport shows the first half")
  advance(movie, 3)
  local held = liveEngineOffsets(movie, "main")
  Assert.equal(held[1][1], 0, "the cancelled drift never resumes after the reset")
  movie:draw()
  local hr, hg, hb = pixelOf(sourceBytes(scope, movie.mainCanvas), 256, 0, 96)
  assertSameColor(hr, hg, hb, 1, 0, 0, 0.08, "the held viewport keeps the first half")
  movie:dispose()
end

-- Paused sprite clips hold their first frame through every draw and tick
-- until a later authored start runs the same clip normally.
local function paused_sprite_clip_holds_its_first_frame_until_started(scope)
  local root = sceneArtRoot(1)
  local stageImage = root .. "layers/stage.png"
  local pitImage = root .. "layers/pit.png"
  local clipId = root .. "sprites/hero.g4sprite"
  local gray16 = solidPng(16, 16, 128, 128, 128)
  local steps = {
    { id = "setup", events = { 1, 2 }, ["until"] = { kind = "duration", ticks = 1 } },
    { id = "paused", events = { 3, 4, 5 }, ["until"] = { kind = "duration", ticks = 10 } },
    { id = "run", events = { 6, 7, 8 }, ["until"] = { kind = "duration", ticks = 6 } },
  }
  local events = {
    { op = "waitTicks", stepId = "setup", atStepTick = 0, ticks = 1 },
    { op = "enableSkip", stepId = "setup", atStepTick = 1 },
    {
      op = "setSpriteClip",
      stepId = "paused",
      atStepTick = 0,
      instanceId = "hero",
      engine = "main",
      x = 32,
      y = 64,
      drawOrder = 1,
      clipId = clipId,
      animate = false,
    },
    {
      op = "spriteVisible",
      stepId = "paused",
      atStepTick = 0,
      instanceId = "hero",
      engine = "main",
      x = 32,
      y = 64,
      drawOrder = 1,
      visible = true,
    },
    { op = "waitTicks", stepId = "paused", atStepTick = 0, ticks = 10 },
    {
      op = "setSpriteClip",
      stepId = "run",
      atStepTick = 0,
      instanceId = "hero",
      engine = "main",
      x = 32,
      y = 64,
      drawOrder = 1,
      clipId = clipId,
      animate = true,
    },
    {
      op = "spriteVisible",
      stepId = "run",
      atStepTick = 0,
      instanceId = "hero",
      engine = "main",
      x = 32,
      y = 64,
      drawOrder = 1,
      visible = true,
    },
    { op = "waitTicks", stepId = "run", atStepTick = 0, ticks = 6 },
  }
  local clipRows = {}
  local firstHalf = string.rep(string.char(255, 255, 0, 255), 16)
  local secondHalf = string.rep(string.char(0, 255, 255, 255), 16)
  for _ = 1, 16 do
    clipRows[#clipRows + 1] = firstHalf .. secondHalf
  end
  local scenes, cacheFs = compositePack(
    compositeScene(
      1,
      { compositeLayer(0, stageImage, 256, 192) },
      { compositeLayer(0, pitImage, 256, 192) },
      {
        compositeClip(clipId, {
          compositeFrame(0, 0, 16, 16, 0, 0, 2),
          compositeFrame(16, 0, 16, 16, 0, 0, 2),
        }),
      },
      { seed = 0, emitters = {} },
      steps,
      events
    ),
    {
      [stageImage] = solidPng(256, 192, 255, 0, 255),
      [pitImage] = solidPng(256, 192, 0, 255, 0),
      [clipId] = PngWriter.encode(32, 16, table.concat(clipRows)),
    },
    gray16
  )
  local movie = openCompositeMovie(scope, scenes, cacheFs, 512, 384, "dual")
  advance(movie, 1)
  advance(movie, 8)
  movie:draw()
  local pr, pg, pb = pixelOf(sourceBytes(scope, movie.mainCanvas), 256, 40, 72)
  assertSameColor(pr, pg, pb, 1, 1, 0, 0.08, "the paused clip holds its first frame")
  advance(movie, 2)
  Assert.equal(currentStepId(movie), "run", "the pause hands the authored start its clip")
  movie:draw()
  local hr, hg, hb = pixelOf(sourceBytes(scope, movie.mainCanvas), 256, 40, 72)
  assertSameColor(hr, hg, hb, 1, 1, 0, 0.08, "the clip still holds first-frame pixels before its start")
  advance(movie, 2)
  movie:draw()
  local rr, rg, rb = pixelOf(sourceBytes(scope, movie.mainCanvas), 256, 40, 72)
  assertSameColor(rr, rg, rb, 0, 1, 1, 0.08, "the started clip advances to its second frame")
  movie:dispose()
end

-- Physical-screen brightness resets resolve the live engine mapping: with
-- the main engine flipped to the lower screen, resetting the upper screen
-- clears only the sub hold while the main hold survives.
local function physical_top_neutral_resets_only_the_mapped_engine(scope)
  local root = sceneArtRoot(1)
  local mainImage = root .. "layers/top-main.png"
  local subImage = root .. "layers/top-sub.png"
  local gray16 = solidPng(16, 16, 128, 128, 128)
  local steps = {
    { id = "setup", events = { 1, 2, 3 }, ["until"] = { kind = "duration", ticks = 2 } },
    { id = "hold", events = { 4 }, ["until"] = { kind = "effect", effect = "fade-both" } },
    { id = "flip", events = { 5 }, ["until"] = { kind = "duration", ticks = 1 } },
    { id = "reset", events = { 6 }, ["until"] = { kind = "duration", ticks = 2 } },
    { id = "tail", events = { 7, 8 }, ["until"] = { kind = "duration", ticks = 2 } },
  }
  local events = {
    { op = "setScreenMapping", stepId = "setup", atStepTick = 0, mainPhysical = "upper" },
    { op = "enableSkip", stepId = "setup", atStepTick = 1 },
    { op = "waitTicks", stepId = "setup", atStepTick = 0, ticks = 2 },
    {
      op = "setFade",
      stepId = "hold",
      atStepTick = 0,
      scope = "both",
      mode = "brightness",
      color = "black",
      direction = "out",
      ticks = 4,
      terminal = "hold",
      effect = "fade-both",
    },
    { op = "setScreenMapping", stepId = "flip", atStepTick = 0, mainPhysical = "lower" },
    { op = "setBrightness", stepId = "reset", atStepTick = 0, physical = "upper", value = "neutral" },
    { op = "waitTicks", stepId = "tail", atStepTick = 0, ticks = 2 },
    { op = "finish", stepId = "tail", atStepTick = 0 },
  }
  local scenes, cacheFs = compositePack(
    compositeScene(
      1,
      { compositeLayer(0, mainImage, 256, 192) },
      { compositeLayer(0, subImage, 256, 192) },
      {},
      { seed = 0, emitters = {} },
      steps,
      events
    ),
    {
      [mainImage] = solidPng(256, 192, 255, 0, 0),
      [subImage] = solidPng(256, 192, 0, 255, 0),
    },
    gray16
  )
  local movie = openCompositeMovie(scope, scenes, cacheFs, 512, 384, "dual")
  advance(movie, 2)
  advance(movie, 4)
  Assert.equal(currentStepId(movie), "flip", "the both-engine fade completes into its flip")
  movie:draw()
  local fr, fg, fb = pixelOf(sourceBytes(scope, movie.mainCanvas), 256, 128, 96)
  assertSameColor(fr, fg, fb, 0, 0, 0, 0.08, "the main hold covers its engine")
  local gr, gg, gb = pixelOf(sourceBytes(scope, movie.subCanvas), 256, 128, 96)
  assertSameColor(gr, gg, gb, 0, 0, 0, 0.08, "the sub hold covers its engine")
  advance(movie, 1)
  advance(movie, 1)
  movie:draw()
  local hr, hg, hb = pixelOf(sourceBytes(scope, movie.mainCanvas), 256, 128, 96)
  assertSameColor(hr, hg, hb, 0, 0, 0, 0.08, "the main hold survives the upper-screen reset")
  local qr, qg, qb = pixelOf(sourceBytes(scope, movie.subCanvas), 256, 128, 96)
  assertSameColor(qr, qg, qb, 0, 1, 0, 0.08, "the upper-screen reset clears only the mapped sub engine")
  movie:dispose()
end

-- Scene 3 holds each beast panel through its exit slide and swaps all
-- three rocket tilemaps at the absolute origin: entei stays staged while
-- its slide runs, the retile waits for both slides, the guarded
-- completion lands new art with zeroed origins before re-enabling its
-- planes, and the suicune/viewport tail keeps its own guards.
local function snapshotBeastPanels(movie)
  local slot = assert(movie.current, "the running movie owns its current slot")
  local panels = {}
  for _, bgSlot in ipairs({ 1, 2, 3 }) do
    local background = assert(slot.backgrounds.sub[bgSlot], "scene 3 stages sub plane " .. bgSlot)
    panels[bgSlot] = {
      image = background.image,
      scrollX = background.scrollX,
      scrollY = background.scrollY,
      visible = background.visible,
    }
  end
  return panels
end

local function beastExitEffectDone(movie, name)
  local slot = assert(movie.current, "the running movie owns its current slot")
  local state = slot.effects[name]
  return state ~= nil and state.done == true
end

local function beast_exits_guard_the_rocket_retile_at_the_absolute_origin(scope, versionId)
  local scenes, cacheFs = loadRomPackWithFillers(versionId, {})
  local movie = openMovieWithCache(scope, scenes, cacheFs, versionId, 512, 384, "single")
  advanceToSceneStep(movie, 3, "entei-exit", 20000)
  local entryPanels = snapshotBeastPanels(movie)
  local seen = {}
  local phases = {}
  local guard = 0
  while guard < 800 and not movie:isFinished() do
    local before = currentStepId(movie)
    phases[before] = true
    movie:updateFixed()
    guard = guard + 1
    local slot = assert(movie.current, "the running movie owns its current slot")
    seen[#seen + 1] = {
      before = before,
      step = currentStepId(movie),
      elapsed = slot.stepElapsed,
      panels = snapshotBeastPanels(movie),
      firstDone = beastExitEffectDone(movie, "scroll-sub1"),
      secondDone = beastExitEffectDone(movie, "scroll-sub2"),
      suicuneDone = beastExitEffectDone(movie, "scroll-sub0"),
      bg0Visible = slot.backgrounds.sub[0].visible,
      pan12 = slot.scrolls["sub:1"] ~= nil and slot.scrolls["sub:2"] ~= nil,
      pan3 = slot.scrolls["sub:3"] ~= nil,
    }
    if before == "viewport-tail" then
      break
    end
  end
  for _, phase in ipairs({ "entei-exit", "rockets", "suicune", "viewport", "viewport-tail" }) do
    Assert.isTrue(phases[phase] == true, "playback walks the scene 3 " .. phase .. " beat")
  end
  for _, observation in ipairs(seen) do
    -- The guard-satisfied update already carries the hide while naming
    -- the old case as its source, so only pending updates prove staging.
    if observation.before == "entei-exit" and observation.step == "entei-exit" then
      Assert.isTrue(
        observation.panels[1].visible,
        "entei stays staged while its exit slide runs"
      )
      Assert.equal(
        observation.panels[1].image,
        entryPanels[1].image,
        "entei keeps its panel until the exit wait passes"
      )
    end
  end
  local enteiHideAt = nil
  for index, observation in ipairs(seen) do
    if observation.before == "entei-exit" and observation.step == "raikou" then
      enteiHideAt = index
      break
    end
  end
  Assert.notNil(enteiHideAt, "the entei exit hands the raikou beat its hide")
  Assert.isFalse(seen[enteiHideAt].panels[1].visible, "the entei hide lands on the guard-satisfied update")
  local rocketEntry = nil
  for _, observation in ipairs(seen) do
    if observation.before == "rockets" then
      rocketEntry = observation.panels
      break
    end
  end
  Assert.notNil(rocketEntry, "the rocket beat starts its guard")
  local retileAt = nil
  for index, observation in ipairs(seen) do
    if observation.panels[1].image ~= rocketEntry[1].image then
      retileAt = index
      break
    end
  end
  Assert.notNil(retileAt, "the rocket tilemaps land once both slides finish")
  local retile = seen[retileAt]
  Assert.equal(retile.before, "rockets", "the rocket retile fires inside its own case")
  Assert.equal(retile.step, "suicune", "the rocket update selects the following beat")
  Assert.equal(retile.elapsed, 0, "the following beat stays undispatched on the retile update")
  Assert.isTrue(retile.firstDone, "the first slide finishes before the guarded retile")
  Assert.isTrue(retile.secondDone, "the second slide finishes before the guarded retile")
  local heldPartial = false
  for index = 1, retileAt - 1 do
    local observation = seen[index]
    if observation.before == "rockets" and observation.firstDone and not observation.secondDone then
      heldPartial = true
      Assert.equal(
        observation.panels[1].image,
        rocketEntry[1].image,
        "the retile stays absent while only the first slide has finished"
      )
      Assert.equal(
        observation.panels[2].image,
        rocketEntry[2].image,
        "the second panel stays staged while its slide still runs"
      )
    end
  end
  Assert.isTrue(heldPartial, "the rocket guard observes a partial slide completion")
  for _, bgSlot in ipairs({ 1, 2, 3 }) do
    Assert.isTrue(
      retile.panels[bgSlot].image ~= rocketEntry[bgSlot].image,
      "the rocket completion swaps sub plane " .. bgSlot
    )
    Assert.equal(retile.panels[bgSlot].scrollX, 0, "the rocket completion zeroes sub plane " .. bgSlot .. " x")
    Assert.equal(retile.panels[bgSlot].scrollY, 0, "the rocket completion zeroes sub plane " .. bgSlot .. " y")
  end
  Assert.isTrue(retile.panels[1].visible, "the rocket completion re-enables the first plane")
  Assert.isTrue(retile.panels[2].visible, "the rocket completion re-enables the second plane")
  local viewportPending = false
  local viewportAt = nil
  for index, observation in ipairs(seen) do
    if observation.before == "viewport" then
      if not observation.suicuneDone then
        viewportPending = true
      end
      if observation.step == "viewport-tail" and viewportAt == nil then
        viewportAt = index
      end
    end
  end
  Assert.isTrue(viewportPending, "the viewport beat waits out the suicune slide")
  Assert.notNil(viewportAt, "the viewport beat hands the tail its pans")
  Assert.isTrue(seen[viewportAt].suicuneDone, "the viewport completion fires on the suicune slide")
  Assert.isFalse(seen[viewportAt].bg0Visible, "the viewport completion retires the rival plane")
  Assert.isTrue(seen[viewportAt].pan12, "the viewport completion starts the first two pans")
  Assert.equal(seen[viewportAt].elapsed, 0, "the viewport tail stays undispatched on the handoff update")
  local tailEntryAt = nil
  for index, observation in ipairs(seen) do
    if observation.before == "viewport-tail" then
      tailEntryAt = index
      break
    end
  end
  Assert.notNil(tailEntryAt, "the viewport tail dispatches on its own update")
  Assert.isTrue(seen[tailEntryAt].pan3, "the viewport tail starts the third pan on its own beat")
  movie:dispose()
end

local function sourced_beast_exits_guard_the_rocket_retile_for_edition(scope, context)
  local versionId = selectedVersionId(context)
  beast_exits_guard_the_rocket_retile_at_the_absolute_origin(scope, versionId)
end

-- Each starter group replays its sourced emission schedule through the
-- real scene bundle: the live-particle curve per group peaks at its
-- sourced height and retires exactly when its emitters exhaust their
-- bounded lifespans, identically on every replay. Peaks and completion
-- ticks below come from the decoded nine emitter records and their
-- generation, lifespan, and pool rules, not from the previous player.
local function groupLiveCurve(movie, scope, group, starter)
  advanceToSceneStep(movie, 4, "run-" .. starter, 20000)
  local curve = {}
  for _ = 1, 500 do
    movie:draw()
    local slot = assert(movie.current, "the running movie owns its current slot")
    local live = 0
    for _, runtime in ipairs(slot.emitters) do
      if runtime.group == group then
        live = live + #runtime.particles + #(runtime.children or {})
      end
    end
    curve[#curve + 1] = live
    if live == 0 then
      return curve
    end
    movie:updateFixed()
  end
  error("the " .. group .. " run never retires its particles", 0)
end

local function starter_groups_replay_bounded_deterministic_curves(scope, context)
  local versionId = selectedVersionId(context)
  local expectations = {
    { starter = "chikorita", group = "grass", peak = 45, done = 52 },
    { starter = "cyndaquil", group = "fire", peak = 150, done = 43 },
    { starter = "totodile", group = "water", peak = 200, done = 48 },
  }
  local first = openMovie(scope, versionId, 512, 384, "single")
  local curves = {}
  for _, want in ipairs(expectations) do
    local curve = groupLiveCurve(first, scope, want.group, want.starter)
    local peak = 0
    for _, live in ipairs(curve) do
      peak = math.max(peak, live)
    end
    Assert.equal(peak, want.peak, "the " .. want.group .. " run peaks at its sourced height")
    Assert.equal(#curve, want.done, "the " .. want.group .. " run retires on its sourced tick")
    curves[#curves + 1] = curve
  end
  local second = openMovie(scope, versionId, 512, 384, "single")
  for index, want in ipairs(expectations) do
    local replayed = groupLiveCurve(second, scope, want.group, want.starter)
    Assert.deepEqual(replayed, curves[index], "the " .. want.group .. " curve replays deterministically")
  end
end

local T = GraphicsSmoke.suite({
  ["starter groups replay bounded deterministic curves"] = starter_groups_replay_bounded_deterministic_curves,  ["soulsilver movie plays five scenes with fixed timing"] = soulsilver_movie_plays_five_scenes_with_fixed_timing_under_variable_draw_rates,
  ["soulsilver towns and starter particles move"] = soulsilver_town_segments_and_starter_particles_move,
  ["soulsilver skip is gated and gpu stays bounded"] = soulsilver_skip_is_source_gated_and_gpu_stays_bounded,
  ["heartgold graphics are blocked without a dump"] = heartgold_opening_movie_graphics_are_blocked_without_a_dump,
  ["soulsilver town texture failure aborts with a typed error"] = soulsilver_town_texture_failure_aborts_with_a_typed_error,
  ["soulsilver town clip failure aborts with a typed error"] = soulsilver_town_clip_failure_aborts_with_a_typed_error,
  ["soulsilver town model failure aborts with a typed error"] = soulsilver_town_model_failure_aborts_with_a_typed_error,
  ["soulsilver town camera uses the sourced angle and lens"] = soulsilver_town_camera_uses_the_sourced_angle_and_lens,
  ["composite layers pan independently with true blending"] = composite_layers_pan_independently_with_true_blending,
  ["native viewports wrap across source extents"] = native_viewports_wrap_across_source_extents,
  ["wrapped backgrounds match the modulo oracle without per-draw quads"] = wrapped_backgrounds_match_the_modulo_oracle_without_per_draw_quads,
  ["swapped alternates and window-sliced pans keep wrap pixels without per-draw quads"] = swapped_alternates_and_window_sliced_pans_keep_wrap_pixels_without_per_draw_quads,
  ["soulsilver scene two and five wrap stays bounded without per-draw quads"] = soulsilver_scene_two_and_five_wrap_stays_bounded_without_per_draw_quads,
  ["heartgold scene two and five wrap is blocked without a dump"] = heartgold_scene_two_and_five_wrap_is_blocked_without_a_dump,
  ["swapped viewports follow the active image extents"] = swapped_viewports_follow_the_active_image_extents,
  ["sourced scroll offsets follow absolute source ticks"] = sourced_scroll_offsets_for_edition,
  ["sourced beast exits guard the rocket retile at the absolute origin"] = sourced_beast_exits_guard_the_rocket_retile_for_edition,
  ["heartgold scroll offsets are blocked without a dump"] = heartgold_scroll_offsets_are_blocked_without_a_dump,
  ["soulsilver source pan edges match wrapped native art"] = soulsilver_source_pan_edges_match_wrapped_native_art,
  ["heartgold pan edges are blocked without a dump"] = heartgold_pan_edges_are_blocked_without_a_dump,
  ["soulsilver source copyright blend and white fade match retail operands"] = soulsilver_source_copyright_blend_and_white_fade_match_retail_operands,
  ["heartgold copyright blend and fade are blocked without a dump"] = heartgold_copyright_blend_and_fade_are_blocked_without_a_dump,
  ["soulsilver source town wipe slopes with the scanline"] = soulsilver_source_town_wipe_slopes_with_the_scanline,
  ["heartgold town wipe is blocked without a dump"] = heartgold_town_wipe_is_blocked_without_a_dump,
  ["soulsilver source starter paints its authored frame"] = soulsilver_source_starter_paints_its_authored_frame,
  ["soulsilver starter child scale follows its life curve"] = soulsilver_starter_child_scale_follows_its_life_curve,
  ["heartgold starter child scale is blocked without a dump"] = heartgold_starter_child_scale_is_blocked_without_a_dump,
  ["heartgold starter frame is blocked without a dump"] = heartgold_starter_frame_is_blocked_without_a_dump,
  ["sourced panorama pixels match wrapped source art"] = sourced_panorama_for_edition,
  ["heartgold panorama wrap is blocked without a dump"] = heartgold_panorama_wrap_is_blocked_without_a_dump,
  ["synthetic color overlap proves bg ordering"] = synthetic_color_overlap_proves_bg_ordering,
  ["synthetic window masks isolate engine planes"] = synthetic_window_masks_isolate_engine_planes,
  ["synthetic dual coefficients saturate both weights per pixel"] = synthetic_dual_coefficients_saturate_both_weights_per_pixel,
  ["synthetic masked pairs use raw under pixels without cascading"] = synthetic_masked_pairs_use_raw_under_pixels_without_cascading,
  ["soulsilver sunrise blend uses both source masks per engine"] = soulsilver_sunrise_blend_uses_both_source_masks,
  ["heartgold sunrise blend is blocked without a dump"] = heartgold_sunrise_blend_is_blocked_without_a_dump,
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
  ["scene 4 close retires starters and holds black until top neutral"] = scene4_close_retires_starters_and_holds_black_until_top_neutral,
  ["scene 4 starter beats hold emission and flip until their cases"] = scene4_starter_beats_hold_emission_and_flip_until_their_cases,
  ["scene 4 authored shutters match source rows on both engines"] = scene4_authored_shutters_match_source_rows_on_both_engines,
  ["slide-in windows reveal opposite halves on each engine"] = slide_in_windows_reveal_opposite_halves_on_each_engine,
  ["every scene paints its authored beat on both engines"] = every_scene_paints_its_authored_beat_on_both_engines,
  ["single-screen stages show the authored active engine"] = single_screen_stages_show_the_authored_active_engine,
  ["soulsilver source wipe slopes with the scanline without spilling"] = soulsilver_source_wipe_slopes_with_the_scanline_without_spilling,
  ["synthetic wipe kinds paint the source inside outside masks and backdrops"] = synthetic_wipe_kinds_paint_the_source_inside_outside_masks_and_backdrops,
  ["synthetic terminal wipe brightness holds only for the retail kinds"] = synthetic_terminal_wipe_brightness_holds_only_for_the_retail_kinds,
  ["source cases dispatch one per fixed update"] = source_cases_dispatch_one_per_fixed_update,
  ["conjunctive effect guard holds mutation until both effects finish"] = conjunctive_effect_guard_holds_mutation_until_both_effects_finish,
  ["scoped sub brightness out holds black while main stays clear"] = scoped_sub_brightness_out_holds_black_while_main_stays_clear,
  ["both engine line shutters sample source rows not uniform alpha"] = both_engine_line_shutters_sample_source_rows_not_uniform_alpha,
  ["absolute scroll position overwrites and cancels the running scroll"] = absolute_scroll_position_overwrites_and_cancels_the_running_scroll,
  ["paused sprite clip holds its first frame until started"] = paused_sprite_clip_holds_its_first_frame_until_started,
  ["physical top neutral resets only the mapped engine"] = physical_top_neutral_resets_only_the_mapped_engine,
  ["synthetic scene five shutter opens main center out before sub bottom up"] = synthetic_scene_five_shutter_opens_main_center_out_before_sub_bottom_up,
  ["soulsilver scene two final wipe keeps its source kind and white hold"] = soulsilver_scene_two_final_wipe_keeps_its_source_kind_and_white_hold,
  ["soulsilver scene two sub blackout holds while main pans"] = soulsilver_scene_two_sub_blackout_holds_while_main_pans,
  ["soulsilver scene one sunrise shows its static sun before scrolling"] = soulsilver_scene_one_sunrise_shows_static_sun_before_scroll,
  ["soulsilver scene three closes retire town drawing before the rival reveal"] = soulsilver_scene_three_closes_retire_town_drawing_before_the_rival_reveal,
  ["soulsilver scene five shutter runs main then sub across layouts"] = soulsilver_scene_five_shutter_runs_main_then_sub_across_layouts,
  ["soulsilver scene five scroll starts only after both shutter cleanups"] = soulsilver_scene_five_scroll_starts_only_after_both_shutter_cleanups,
  ["soulsilver scene five white fade starts at scroll tick twenty"] = soulsilver_scene_five_white_fade_starts_at_scroll_tick_twenty,
  ["heartgold scene two wipe is blocked without a dump"] = heartgold_scene_two_wipe_is_blocked_without_a_dump,
  ["heartgold scene three beats are blocked without a dump"] = heartgold_scene_three_beats_are_blocked_without_a_dump,
  ["heartgold scene five shutter is blocked without a dump"] = heartgold_scene_five_shutter_is_blocked_without_a_dump,
  ["heartgold wipe kinds are blocked without a dump"] = heartgold_wipe_kinds_are_blocked_without_a_dump,
  ["soulsilver title legend carries its retail placement"] = soulsilver_title_legend_carries_its_retail_placement,
  ["soulsilver title sparkle shares the retail placement"] = soulsilver_title_sparkle_shares_the_retail_placement,
  ["heartgold title placement is blocked without a dump"] = heartgold_title_placement_is_blocked_without_a_dump,
})
T.metadata.capabilities = { "graphics", "rom_dump" }
T.metadata.derivedAssets = {
  "opening-scene:1",
  "opening-scene:2",
  "opening-scene:3",
  "opening-scene:4",
  "opening-scene:5",
  "startup-title:global",
}
T.metadata.tags = { "startup", "opening" }
return T
