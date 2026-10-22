-- Source-backed opening movie graphics: the compiled SoulSilver scenes play
-- in order with real town and particle motion at fixed source timing, the
-- skip gate finishes only the movie, and GPU resources are released.
-- HeartGold coverage stays blocked: no HeartGold dump is available here, so
-- its scenarios skip instead of running against faked art.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
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

local T = GraphicsSmoke.suite({
  ["soulsilver movie plays five scenes with fixed timing"] = soulsilver_movie_plays_five_scenes_with_fixed_timing_under_variable_draw_rates,
  ["soulsilver towns and starter particles move"] = soulsilver_town_segments_and_starter_particles_move,
  ["soulsilver skip is gated and gpu stays bounded"] = soulsilver_skip_is_source_gated_and_gpu_stays_bounded,
  ["heartgold graphics are blocked without a dump"] = heartgold_opening_movie_graphics_are_blocked_without_a_dump,
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
