-- Five-scene opening movie playback: ordered source-timed scenes, a source
-- gated skip that finishes only the movie, and bounded scene resource
-- ownership with rollback. Fixtures are strict synthetic opening-scene
-- bundles validated through the real startup cache reader; the graphics
-- host is the shared fake so acquisitions, releases, and draws are counted
-- without a GPU.

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
---@param width integer claimed source extent
---@param height integer claimed source extent
---@param priority integer|nil source priority, defaults to the slot
---@return table compiled engine layer record
local function layer(bgSlot, image, width, height, priority)
  return {
    bgSlot = bgSlot,
    priority = priority == nil and bgSlot or priority,
    image = image,
    variants = {},
    width = width,
    height = height,
    sourceHash = string.rep("c", 40),
  }
end

---@param x integer
---@param y integer
---@param width integer
---@param height integer
---@param offsetX integer per-frame draw origin offset
---@param offsetY integer per-frame draw origin offset
---@param duration integer source ticks the frame shows
---@return table compiled sprite clip frame
local function clipFrame(x, y, width, height, offsetX, offsetY, duration)
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

---@param id string staged clip identity under its scene root
---@param frames table[] compiled clip frames
---@return table compiled sprite clip record
local function spriteClip(id, frames)
  return { id = id, frameCount = #frames, frames = frames }
end

---@return table single-frame still clip frame
local function stillFrame()
  return clipFrame(0, 0, 16, 16, 0, 0, 1)
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
        direction = "left",
      },
      { op = "waitTicks", stepId = "open", atStepTick = 0, ticks = 25 },
      { op = "circleWipe", stepId = "close", atStepTick = 0, mode = "out", ticks = 10 },
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
    { op = "circleWipe", stepId = "wipe", atStepTick = 0, mode = "in", ticks = 18 },
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
      direction = "left",
    },
    { op = "waitTicks", stepId = "scroll", atStepTick = 0, ticks = 20 },
    { op = "setFade", stepId = "fade", atStepTick = 0, kind = "white", ticks = 15 },
    { op = "finish", stepId = "fade", atStepTick = 0 },
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
---@return table strict synthetic opening-scene manifest
local function manifestFor(sceneNumber)
  local root = sceneRoot(sceneNumber)
  local upperImage = root .. "upper-bg.png"
  local lowerImage = root .. "lower-bg.png"
  local clips = {}
  if sceneNumber == 1 then
    clips = { spriteClip(root .. "sprites/clip0.g4sprite", { stillFrame() }) }
  elseif sceneNumber == 4 then
    clips = { spriteClip(root .. "sprites/ethan.g4sprite", { stillFrame() }) }
  end
  local manifest = {
    schema = Contract.startupOpeningScene.schema,
    versionId = VERSION_ID,
    generationId = "movie-test-generation",
    sceneNumber = sceneNumber,
    sourceTickRate = Contract.startupOpeningScene.tickRate,
    layers = {
      main = { layer(0, upperImage, 256, 192) },
      sub = { layer(0, lowerImage, 256, 192) },
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

-- Builds five strict synthetic scenes through the real startup cache
-- reader, so every happy-path player starts from a bundle the production
-- contract already accepts.
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

---@param fakeOpts table|nil mutable fake graphics options (kept for failure injection)
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
    if fakeOpts.failOnMeshCall ~= nil then
      fakeOpts.failOnMeshCall = fakeOpts.failOnMeshCall - 1
      if fakeOpts.failOnMeshCall < 0 then
        error("injected newMesh failure")
      end
    end
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

---@param graphics table
---@return table set of live handles keyed by identity
local function liveSet(graphics)
  local set = {}
  for _, group in ipairs({ graphics.images, graphics.canvases, graphics.meshes or {} }) do
    for _, handle in ipairs(group) do
      if not handle.released then
        set[handle] = true
      end
    end
  end
  return set
end

---@param movie table
---@param graphics table
---@param limit integer
---@return table entry tick per scene, integer total ticks
local function playthrough(movie, graphics, limit)
  local entries = { [1] = 0 }
  local ticks = 0
  while not movie:isFinished() and ticks < limit do
    movie:updateFixed()
    ticks = ticks + 1
    movie:draw()
    local scene = movie:sceneNumber()
    if entries[scene] == nil then
      entries[scene] = ticks
    end
  end
  Assert.isTrue(movie:isFinished(), "the movie finishes within its bounded run")
  return entries, ticks
end

function T.plays_all_five_scenes_in_order_with_their_authored_step_lengths()
  local scenes, cacheFs = validPack()
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  Assert.equal(movie:sceneNumber(), 1, "playback starts at the first scene, never the title")
  Assert.isFalse(movie:isFinished(), "a fresh movie is not finished")
  local entries = playthrough(movie, graphics, 5000)
  for sceneNumber = 1, 5 do
    Assert.notNil(entries[sceneNumber], "scene " .. sceneNumber .. " is visited")
  end
  Assert.equal(entries[1], 0, "scene 1 starts on the first tick")
  Assert.equal(entries[2], 90, "scene 2 starts after scene 1's authored 90 ticks")
  Assert.equal(entries[3], 130, "scene 3 starts after scene 2's authored 40 ticks")
  Assert.equal(entries[4], 180, "scene 4 starts after scene 3's authored 50 ticks")
  Assert.isTrue(entries[5] > entries[4] + 20, "scene 5 waits out the starter effect, never a bare timer")
  movie:dispose()
end

function T.simultaneous_events_share_one_tick_without_extra_frames_or_spins()
  local scenes, cacheFs = validPack()
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  local entries, total = playthrough(movie, graphics, 5000)
  Assert.notNil(entries[5], "scene 5 is reached")
  Assert.equal(total - entries[5], 53, "scene 5's same-tick wipe and role events cost exactly the authored 53 ticks")
  movie:dispose()
end

function T.extra_host_draws_never_advance_source_time_and_repeated_ticks_stay_deterministic()
  local scenes, cacheFs = validPack()
  local firstGraphics = movieGraphics()
  local first = openMovie(scenes, cacheFs, firstGraphics)
  local secondGraphics = movieGraphics()
  local second = openMovie(scenes, cacheFs, secondGraphics)
  for _ = 1, 200 do
    first:updateFixed()
    first:draw()
    second:updateFixed()
    second:draw()
    second:draw()
    second:draw()
  end
  Assert.equal(
    first:sceneNumber(),
    second:sceneNumber(),
    "triple host draws never advance the source clock past single-draw playback"
  )
  Assert.equal(first:isFinished(), second:isFinished(), "draw cadence never changes completion")
  Assert.equal(
    #firstGraphics.draws,
    #secondGraphics.draws / 3,
    "only fixed ticks drive frames; host draws only repeat the current frame"
  )
  local thirdGraphics = movieGraphics()
  local third = openMovie(scenes, cacheFs, thirdGraphics)
  for _ = 1, 200 do
    third:updateFixed()
    third:draw()
  end
  Assert.equal(first:sceneNumber(), third:sceneNumber(), "identical fixed ticks reach identical scenes")
  Assert.equal(#firstGraphics.draws, #thirdGraphics.draws, "identical fixed ticks issue identical frame counts")
  first:dispose()
  second:dispose()
  third:dispose()
end

function T.town_and_emitter_steps_stay_live_until_their_effects_complete()
  local scenes, cacheFs = validPack()
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  local ticks = 0
  while movie:sceneNumber() < 3 and ticks < 5000 do
    movie:updateFixed()
    ticks = ticks + 1
  end
  Assert.equal(movie:sceneNumber(), 3, "playback reaches the town scenes")
  local scene3draws = #graphics.draws
  for _ = 1, 50 do
    movie:updateFixed()
    movie:draw()
  end
  Assert.equal(movie:sceneNumber(), 4, "scene 3 holds exactly its authored 50 town ticks")
  Assert.isTrue(#graphics.draws > scene3draws, "every town tick issues its frame")
  local emitterEntryDraws = #graphics.draws
  local emitterTicks = 0
  while movie:sceneNumber() == 4 and emitterTicks < 2000 do
    movie:updateFixed()
    movie:draw()
    emitterTicks = emitterTicks + 1
  end
  Assert.equal(movie:sceneNumber(), 5, "the starter step ends on its emitter effect, never a skipped sim")
  Assert.isTrue(emitterTicks > 20, "the emitter effect runs instead of completing instantly")
  Assert.isTrue(#graphics.draws > emitterEntryDraws, "every emitter tick issues its frame")
  movie:dispose()
end

function T.skip_stays_closed_before_the_source_gate_and_finishes_only_the_movie_after_it()
  local scenes, cacheFs = validPack()
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  Assert.isFalse(movie:skipAllowed(), "the skip gate is closed on the first frame")
  Assert.isFalse(movie:requestSkip(), "an early skip is ignored")
  Assert.equal(movie:sceneNumber(), 1, "an early skip never leaves the first scene")
  Assert.isFalse(movie:isFinished(), "an early skip never finishes the movie")
  for _ = 1, 39 do
    movie:updateFixed()
  end
  Assert.isFalse(movie:skipAllowed(), "the gate stays closed before its authored scene-one tick")
  movie:updateFixed()
  Assert.isTrue(movie:skipAllowed(), "the gate opens on its authored scene-one tick")
  Assert.isTrue(movie:requestSkip(), "an eligible skip is consumed")
  Assert.isTrue(movie:isFinished(), "an eligible skip finishes the movie")
  Assert.isFalse(movie:requestSkip(), "a second skip never triggers another transition")
  movie:draw()
  Assert.isTrue(movie:isFinished(), "drawing after the skip stays finished without entering another stage")
  movie:dispose()
  movie:dispose()
end

function T.scene_graphs_release_within_two_transitions_and_dispose_releases_exactly_once()
  local scenes, cacheFs = validPack()
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  local movieWide = liveSet(graphics)
  local snapshots = {}
  local ticks = 0
  while not movie:isFinished() and ticks < 5000 do
    local scene = movie:sceneNumber()
    if snapshots[scene] == nil then
      local live = liveSet(graphics)
      local owned = {}
      for handle in pairs(live) do
        if movieWide[handle] == nil then
          owned[handle] = true
        end
      end
      snapshots[scene] = owned
    end
    movie:updateFixed()
    ticks = ticks + 1
    movie:draw()
  end
  Assert.isTrue(movie:isFinished(), "the run finishes")
  for sceneNumber = 1, 3 do
    for handle in pairs(snapshots[sceneNumber]) do
      Assert.isTrue(handle.released, "scene " .. sceneNumber .. " is torn down two transitions later")
    end
  end
  for _, group in ipairs({ graphics.images, graphics.canvases, graphics.meshes or {} }) do
    for _, handle in ipairs(group) do
      Assert.isTrue(handle.releaseCount <= 1, "no scene handle is released twice while ownership moves")
    end
  end
  movie:dispose()
  Assert.equal(liveHandles(graphics), 0, "dispose releases every remaining handle")
  for _, group in ipairs({ graphics.images, graphics.canvases, graphics.meshes or {} }) do
    for _, handle in ipairs(group) do
      Assert.equal(handle.releaseCount, 1, "every acquired handle is released exactly once")
    end
  end
  movie:dispose()
  Assert.equal(liveHandles(graphics), 0, "disposing twice stays safe")
end

function T.a_failed_next_scene_acquisition_keeps_the_current_scene_and_recovers()
  local scenes, cacheFs = validPack()
  local fakeOpts = {}
  local graphics = movieGraphics(fakeOpts)
  local movie = openMovie(scenes, cacheFs, graphics)
  movie:updateFixed()
  movie:draw()
  -- Trap the next acquisition wherever it happens: prefetch timing is an
  -- implementation detail, so the failing tick keeps whatever scene is
  -- current at that moment and the run recovers once the failure clears.
  fakeOpts.failOnImageCall = #graphics.images + 1
  local failure = nil
  local previousScene = movie:sceneNumber()
  local ticks = 0
  while ticks < 500 and not movie:isFinished() do
    local heldScene = movie:sceneNumber()
    Assert.isTrue(heldScene >= previousScene, "the movie never replays an earlier scene")
    previousScene = heldScene
    local heldLive = liveSet(graphics)
    local ok, err = pcall(function()
      movie:updateFixed()
    end)
    ticks = ticks + 1
    if not ok then
      failure = err
      Assert.equal(movie:sceneNumber(), heldScene, "the failed acquisition never drops the current scene")
      for handle in pairs(heldLive) do
        Assert.isFalse(handle.released, "the failed acquisition never tears down the current scene")
      end
      break
    end
    movie:draw()
  end
  fakeOpts.failOnImageCall = nil
  Assert.notNil(failure, "a failed next-scene acquisition surfaces explicitly")
  movie:draw()
  playthrough(movie, graphics, 5000)
  Assert.isTrue(movie:isFinished(), "playback resumes and completes after the failure clears")
  movie:dispose()
end

function T.construction_fails_cleanly_when_the_first_acquisition_fails()
  local scenes, cacheFs = validPack()
  local graphics = movieGraphics({ failOnImageCall = 1 })
  local Movie = requireMovie()
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
  Assert.throws(function()
    Movie.new({
      versionId = VERSION_ID,
      scenes = scenes,
      cacheFs = cacheFs,
      width = WIDTH,
      height = HEIGHT,
      graphics = graphics,
      displayContext = context,
    })
  end, "a failed first acquisition fails construction")
  Assert.equal(liveHandles(graphics), 0, "a failed construction leaves no unreleased handle behind")
end

function T.construction_rejects_anything_but_five_ordered_current_bundles()
  local scenes, cacheFs = validPack()
  local Movie = requireMovie()
  local function attempt(candidate, versionId)
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
      versionId = versionId or VERSION_ID,
      scenes = candidate,
      cacheFs = cacheFs,
      width = WIDTH,
      height = HEIGHT,
      graphics = host,
      displayContext = context,
    })
  end
  local short = { scenes[1], scenes[2], scenes[3], scenes[4] }
  Assert.isFalse(attempt(short), "four scenes never open a five-scene movie")
  local swapped = { scenes[1], scenes[3], scenes[2], scenes[4], scenes[5] }
  Assert.isFalse(attempt(swapped), "out-of-order scenes never play")
  local mixed = { scenes[1], scenes[2], scenes[3], scenes[4], manifestFor(5) }
  mixed[5].versionId = "heartgold"
  local mixedCache = stubCache({ [1] = scenes[1], [2] = scenes[2], [3] = scenes[3], [4] = scenes[4], [5] = mixed[5] })
  local mixedHost = movieGraphics()
  local mixedContext = DisplayContext.new({
    graphics = mixedHost,
    topologyProvider = function(width, height)
      return {
        surfaces = {
          { id = "main", rect = { x = 0, y = 0, width = width, height = height }, touch = false, role = "world" },
        },
      }
    end,
  })
  local mixedOk = pcall(Movie.new, {
    versionId = VERSION_ID,
    scenes = mixed,
    cacheFs = mixedCache,
    width = WIDTH,
    height = HEIGHT,
    graphics = mixedHost,
    displayContext = mixedContext,
  })
  Assert.isFalse(mixedOk, "a mixed-edition bundle never joins the run")
  local stale = { scenes[1], scenes[2], scenes[3], scenes[4], scenes[5] }
  local staleCopy = manifestFor(5)
  staleCopy.generationId = "another-generation"
  stale[5] = staleCopy
  Assert.isFalse(attempt(stale), "a stale-generation bundle never joins the run")
  local retired = { scenes[1], scenes[2], scenes[3], scenes[4], manifestFor(5) }
  retired[5].schema = "g4-startup-opening-scene-v1"
  Assert.isFalse(attempt(retired), "a retired schema never plays through the strict player")
  Assert.equal(liveHandles(movieGraphics()), 0, "rejected constructions acquire nothing observable")
end

function T.two_instances_keep_independent_cursors_and_particles()
  local scenes, cacheFs = validPack()
  local firstGraphics = movieGraphics()
  local first = openMovie(scenes, cacheFs, firstGraphics)
  local secondGraphics = movieGraphics()
  local second = openMovie(scenes, cacheFs, secondGraphics)
  for _ = 1, 150 do
    first:updateFixed()
    first:draw()
  end
  Assert.equal(second:sceneNumber(), 1, "ticking one movie never moves its sibling")
  Assert.isFalse(second:skipAllowed(), "ticking one movie never opens its sibling's skip gate")
  for _ = 1, 150 do
    second:updateFixed()
    second:draw()
  end
  Assert.equal(first:sceneNumber(), second:sceneNumber(), "identical ticks converge again")
  Assert.equal(#firstGraphics.draws, #secondGraphics.draws, "identical ticks issue identical frame counts")
  first:dispose()
  second:dispose()
end

function T.resize_reflows_without_rewinding_source_time()
  local scenes, cacheFs = validPack()
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  for _ = 1, 100 do
    movie:updateFixed()
    movie:draw()
  end
  local before = movie:sceneNumber()
  movie:resize(600, 1000)
  Assert.equal(movie:sceneNumber(), before, "resizing never rewinds the movie")
  movie:draw()
  movie:resize(WIDTH, HEIGHT)
  Assert.equal(movie:sceneNumber(), before, "a second resize still preserves the movie clock")
  local entries = playthrough(movie, graphics, 5000)
  Assert.equal(
    entries[2],
    1,
    "the continued run starts in scene two (entered at absolute 90, before the run, never rewound)"
  )
  Assert.equal(
    entries[3],
    30,
    "scene three enters 30 ticks into the continued run (authored absolute 130 less 100 pre-run ticks)"
  )
  movie:dispose()
end

function T.draws_restore_the_borrowed_graphics_state()
  local scenes, cacheFs = validPack()
  local graphics = movieGraphics({ canvas = nil, shader = nil })
  local movie = openMovie(scenes, cacheFs, graphics)
  for _ = 1, 100 do
    movie:updateFixed()
  end
  local canvas, shader = graphics.getCanvas(), graphics.getShader()
  local r, g, b, a = graphics.getColor()
  local blend, alpha = graphics.getBlendMode()
  movie:draw()
  Assert.equal(graphics.getCanvas(), canvas, "drawing restores the borrowed canvas")
  Assert.equal(graphics.getShader(), shader, "drawing restores the borrowed shader")
  local r2, g2, b2, a2 = graphics.getColor()
  Assert.equal(r2, r, "drawing restores the borrowed color")
  Assert.equal(g2, g, "drawing restores the borrowed color")
  Assert.equal(b2, b, "drawing restores the borrowed color")
  Assert.equal(a2, a, "drawing restores the borrowed color")
  local blend2, alpha2 = graphics.getBlendMode()
  Assert.equal(blend2, blend, "drawing restores the borrowed blend mode")
  Assert.equal(alpha2, alpha, "drawing restores the borrowed blend mode")
  movie:dispose()
end

-- Composite playback keeps every simultaneously live background slot, honors
-- authored sprite frame offsets, and times effects against the step clock.
-- Every fixture below passes the strict generated reader, so each test fails
-- on the playback behavior itself rather than on fixture loading.
local COMPOSITE_GENERATION = "movie-test-generation"

---@param sceneNumber integer
---@param upper table[] main-engine layer records in source order
---@param lower table[] sub-engine layer records in source order
---@param clips table[] sprite clip records
---@param steps table[] source step records
---@param events table[] closed step-clocked timeline events
---@return table strict synthetic opening-scene manifest
local function compositeManifest(sceneNumber, upper, lower, clips, steps, events)
  local assets = {}
  for _, list in ipairs({ upper, lower }) do
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
  return {
    schema = Contract.startupOpeningScene.schema,
    versionId = VERSION_ID,
    generationId = COMPOSITE_GENERATION,
    sceneNumber = sceneNumber,
    sourceTickRate = Contract.startupOpeningScene.tickRate,
    layers = { main = upper, sub = lower },
    spriteClips = clips,
    models = {},
    particles = { seed = 0, emitters = {} },
    timeline = { steps = steps, events = events },
    assets = assets,
  }
end

---@param custom table custom scene manifest
---@param customIndex integer position of the custom scene in retail order
---@return table[] scenes, table cacheFs strict five-scene pack with one custom scene
local function packWithSceneAt(custom, customIndex)
  local raw = {}
  for sceneNumber = 1, 5 do
    if sceneNumber == customIndex then
      raw[sceneNumber] = custom
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

function T.simultaneous_layers_keep_their_own_scroll_in_source_order()
  local root = sceneRoot(1)
  local bottomImage = root .. "layers/sky-bottom.png"
  local middleImage = root .. "layers/sky-middle.png"
  local topImage = root .. "layers/sky-top.png"
  local groundImage = root .. "layers/ground.png"
  local scenes, cacheFs = packWithSceneAt(
    compositeManifest(
      1,
      {
        layer(0, bottomImage, 256, 192, 0),
        layer(1, middleImage, 128, 96, 1),
        layer(2, topImage, 64, 48, 2),
      },
      { layer(0, groundImage, 32, 32, 0) },
      { spriteClip(root .. "sprites/clip0.g4sprite", { stillFrame() }) },
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
          effect = "pan-top",
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
          effect = "pan-middle",
        },
        { op = "enableSkip", stepId = "pan", atStepTick = 10 },
        { op = "waitTicks", stepId = "pan", atStepTick = 0, ticks = 40 },
        { op = "finish", stepId = "pan", atStepTick = 40 },
      }
    ),
    1
  )
  local graphics = movieGraphics({ imageSizes = { { 256, 192 }, { 128, 96 }, { 64, 48 }, { 32, 32 }, { 16, 16 } } })
  local movie = openMovie(scenes, cacheFs, graphics)
  for _ = 1, 12 do
    movie:updateFixed()
  end
  movie:draw()
  local byWidth = {}
  local layerDraws = 0
  for _, draw in ipairs(graphics.draws) do
    local width = draw.image:getWidth()
    if width == 256 or width == 128 or width == 64 or width == 32 then
      layerDraws = layerDraws + 1
      byWidth[width] = draw
    end
  end
  Assert.equal(layerDraws, 4, "every simultaneously live layer is drawn, never just the first")
  Assert.notNil(byWidth[256], "the bottom layer is drawn")
  Assert.notNil(byWidth[128], "the middle layer is drawn")
  Assert.notNil(byWidth[64], "the top layer is drawn")
  Assert.notNil(byWidth[32], "the lower-role layer is drawn")
  Assert.equal(byWidth[256].x, 0, "the unscrolled bottom layer stays at its source origin")
  Assert.equal(byWidth[256].y, 0, "the unscrolled bottom layer stays at its source origin")
  Assert.equal(byWidth[128].x, -24, "the middle layer pans at its own authored velocity")
  Assert.equal(byWidth[64].x, -48, "the top layer pans at its own authored velocity")
  Assert.equal(byWidth[32].x, 0, "the sub-engine layer ignores main-engine pans")
  movie:dispose()
end

---@param offsetX integer authored horizontal clip frame offset
---@param offsetY integer authored vertical clip frame offset
---@return table strict synthetic opening scene with one visible hero sprite
local function heroScene(offsetX, offsetY)
  local root = sceneRoot(1)
  local clipId = root .. "sprites/hero.g4sprite"
  return compositeManifest(1, { layer(0, root .. "layers/stage.png", 256, 192) }, {
    layer(0, root .. "layers/lower.png", 256, 192),
  }, {
    spriteClip(clipId, {
      clipFrame(0, 0, 16, 16, 0, 0, 6),
      clipFrame(0, 0, 16, 16, offsetX, offsetY, 6),
    }),
  }, { { id = "show", events = { 1, 2, 3, 4, 5 }, ["until"] = { kind = "duration", ticks = 40 } } }, {
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
  })
end

---@param graphics table fake graphics namespace
---@return table[] draws that sample a sprite clip quad
local function spriteDraws(graphics)
  local found = {}
  for _, draw in ipairs(graphics.draws) do
    if draw.quad ~= nil then
      found[#found + 1] = draw
    end
  end
  return found
end

function T.authored_sprite_frames_offset_the_draw_origin_and_draw_once()
  local firstScenes, firstCache = packWithSceneAt(heroScene(40, 30), 1)
  local firstGraphics = movieGraphics()
  local first = openMovie(firstScenes, firstCache, firstGraphics)
  local secondScenes, secondCache = packWithSceneAt(heroScene(52, 30), 1)
  local secondGraphics = movieGraphics()
  local second = openMovie(secondScenes, secondCache, secondGraphics)
  for _ = 1, 8 do
    first:updateFixed()
    second:updateFixed()
  end
  first:draw()
  second:draw()
  local firstSprites = spriteDraws(firstGraphics)
  local secondSprites = spriteDraws(secondGraphics)
  Assert.equal(#firstSprites, 1, "one authored instance draws exactly once per frame")
  Assert.equal(#secondSprites, 1, "one authored instance draws exactly once per frame")
  Assert.equal(secondSprites[1].x - firstSprites[1].x, 12, "the authored frame offset moves the draw origin")
  Assert.equal(secondSprites[1].y - firstSprites[1].y, 0, "matching vertical offsets hold the vertical origin")
  first:dispose()
  second:dispose()
end

---@return table strict synthetic opening scene with a step-relative white fade
local function fadeScene()
  local root = sceneRoot(1)
  return compositeManifest(
    1,
    { layer(0, root .. "layers/sunrise.png", 256, 192) },
    { layer(0, root .. "layers/lower.png", 256, 192) },
    { spriteClip(root .. "sprites/clip0.g4sprite", { stillFrame() }) },
    {
      { id = "setup", events = { 1, 2 }, ["until"] = { kind = "duration", ticks = 30 } },
      { id = "run", events = { 3, 4, 5 }, ["until"] = { kind = "duration", ticks = 120 } },
    },
    {
      { op = "waitTicks", stepId = "setup", atStepTick = 0, ticks = 30 },
      { op = "enableSkip", stepId = "setup", atStepTick = 10 },
      { op = "setFade", stepId = "run", atStepTick = 90, kind = "white", ticks = 20, effect = "fade-run" },
      { op = "waitTicks", stepId = "run", atStepTick = 0, ticks = 120 },
      { op = "finish", stepId = "run", atStepTick = 120 },
    }
  )
end

---@param graphics table fake graphics namespace
---@return table[] source-sized opaque-white fill rectangles
local function whiteRects(graphics)
  local found = {}
  for _, rect in ipairs(graphics.rectangles) do
    if
      rect.mode == "fill"
      and rect.x == 0
      and rect.y == 0
      and rect.w == 256
      and rect.h == 192
      and rect.color[1] == 1
      and rect.color[2] == 1
      and rect.color[3] == 1
    then
      found[#found + 1] = rect
    end
  end
  return found
end

function T.step_relative_fades_start_on_their_step_tick()
  local earlyScenes, earlyCache = packWithSceneAt(fadeScene(), 1)
  local earlyGraphics = movieGraphics()
  local early = openMovie(earlyScenes, earlyCache, earlyGraphics)
  for _ = 1, 35 do
    early:updateFixed()
  end
  early:draw()
  local earlyLit = 0
  for _, rect in ipairs(whiteRects(earlyGraphics)) do
    if rect.color[4] > 0 then
      earlyLit = earlyLit + 1
    end
  end
  Assert.equal(earlyLit, 0, "the run fade stays off before its ninetieth step tick")
  early:dispose()
  local lateScenes, lateCache = packWithSceneAt(fadeScene(), 1)
  local lateGraphics = movieGraphics()
  local late = openMovie(lateScenes, lateCache, lateGraphics)
  for _ = 1, 135 do
    late:updateFixed()
  end
  late:draw()
  local midFade = false
  for _, rect in ipairs(whiteRects(lateGraphics)) do
    if rect.color[4] > 0 and rect.color[4] < 1 then
      midFade = true
    end
  end
  Assert.isTrue(midFade, "the run fade is mid-transition fifteen ticks after its step onset")
  late:dispose()
end

function T.unstarted_effect_waits_fail_instead_of_completing()
  -- The reader would reject an unresolvable wait, so this program reaches
  -- the player directly: the strict player must raise the same way instead
  -- of counting the missing effect complete.
  local root = sceneRoot(2)
  local hold = compositeManifest(2, { layer(0, root .. "layers/hold-upper.png", 256, 192) }, {
    layer(0, root .. "layers/hold-lower.png", 256, 192),
  }, {}, { { id = "hold", events = { 1 }, ["until"] = { kind = "effect", effect = "bloom-sparkle" } } }, {
    { op = "waitTicks", stepId = "hold", atStepTick = 0, ticks = 10 },
  })
  hold.generationId = COMPOSITE_GENERATION
  local scenes, cacheFs = validPack()
  scenes[2] = hold
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  for _ = 1, 90 do
    movie:updateFixed()
  end
  Assert.equal(movie:sceneNumber(), 2, "playback reaches the effect-gated step")
  local failure = nil
  for _ = 1, 10 do
    local ok, err = pcall(function()
      movie:updateFixed()
    end)
    if not ok then
      failure = err
      break
    end
  end
  Assert.notNil(failure, "waiting on an effect that never started raises instead of completing")
  Assert.equal(movie:sceneNumber(), 2, "the failed wait never advances past its step")
  movie:dispose()
end

function T.clip_completion_binds_the_compiled_clip_duration()
  local root = sceneRoot(1)
  local sparkleClip = root .. "sprites/sparkle.g4sprite"
  local function sparkleScene(effect)
    return compositeManifest(
      1,
      { layer(0, root .. "layers/stage.png", 256, 192) },
      { layer(0, root .. "layers/lower.png", 256, 192) },
      {
        spriteClip(sparkleClip, {
          clipFrame(0, 0, 16, 16, 0, 0, 6),
          clipFrame(0, 0, 16, 16, 0, 0, 6),
          clipFrame(0, 0, 16, 16, 0, 0, 8),
        }),
      },
      {
        { id = "setup", events = { 1, 2 }, ["until"] = { kind = "duration", ticks = 10 } },
        { id = "finale", events = { 3, 4 }, ["until"] = { kind = "effect", effect = effect } },
      },
      {
        { op = "waitTicks", stepId = "setup", atStepTick = 0, ticks = 10 },
        { op = "enableSkip", stepId = "setup", atStepTick = 5 },
        {
          op = "setSpriteClip",
          stepId = "finale",
          atStepTick = 0,
          instanceId = "sparkles",
          engine = "main",
          x = 128,
          y = 96,
          drawOrder = 1,
          clipId = sparkleClip,
        },
        {
          op = "spriteVisible",
          stepId = "finale",
          atStepTick = 0,
          instanceId = "sparkles",
          engine = "main",
          x = 128,
          y = 96,
          drawOrder = 1,
          visible = true,
        },
      }
    )
  end
  -- The clip sums to 6 + 6 + 8 source ticks; the finale step completes
  -- exactly then, neither on an earlier frame nor a tick late.
  local scenes, cacheFs = packWithSceneAt(sparkleScene(sparkleClip), 1)
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  for _ = 1, 10 do
    movie:updateFixed()
  end
  Assert.equal(movie:sceneNumber(), 1, "the setup step hands over to the clip finale")
  for _ = 1, 19 do
    movie:updateFixed()
  end
  Assert.equal(movie:sceneNumber(), 1, "the finale holds for the nineteen ticks before the summed duration")
  movie:updateFixed()
  Assert.equal(movie:sceneNumber(), 2, "the finale completes exactly after the summed frame durations")
  movie:dispose()
  -- The same shape with an unstarted non-clip wait raises instead: a wait
  -- that names no started effect and no compiled clip is never complete.
  local raw, rawCache = validPack()
  local dangling = sparkleScene("bloom-sparkle")
  dangling.generationId = COMPOSITE_GENERATION
  raw[1] = dangling
  local rawGraphics = movieGraphics()
  local rawMovie = openMovie(raw, rawCache, rawGraphics)
  for _ = 1, 9 do
    rawMovie:updateFixed()
  end
  Assert.equal(rawMovie:sceneNumber(), 1, "playback reaches the setup step before the gated finale")
  local failure = nil
  local ok, err = pcall(function()
    rawMovie:updateFixed()
  end)
  if not ok then
    failure = err
  end
  Assert.notNil(failure, "waiting on an unstarted non-clip effect raises instead of completing")
  Assert.equal(rawMovie:sceneNumber(), 1, "the failed wait never advances past its step")
  rawMovie:dispose()
end

function T.step_events_apply_in_listed_order()
  local root = sceneRoot(1)
  local baseImage = root .. "layers/base.png"
  local firstImage = root .. "layers/first.png"
  local secondImage = root .. "layers/second.png"
  local scenes, cacheFs = packWithSceneAt(
    compositeManifest(
      1,
      {
        {
          bgSlot = 0,
          priority = 0,
          image = baseImage,
          variants = { firstImage, secondImage },
          width = 256,
          height = 192,
          sourceHash = string.rep("c", 40),
        },
      },
      { layer(0, root .. "layers/lower.png", 32, 32) },
      { spriteClip(root .. "sprites/clip0.g4sprite", { stillFrame() }) },
      { { id = "show", events = { 1, 2, 3, 4 }, ["until"] = { kind = "duration", ticks = 40 } } },
      {
        {
          op = "setLayer",
          stepId = "show",
          atStepTick = 3,
          engine = "main",
          bgSlot = 0,
          image = firstImage,
          visible = true,
          priority = 0,
        },
        {
          op = "setLayer",
          stepId = "show",
          atStepTick = 3,
          engine = "main",
          bgSlot = 0,
          image = secondImage,
          visible = true,
          priority = 0,
        },
        { op = "enableSkip", stepId = "show", atStepTick = 10 },
        { op = "finish", stepId = "show", atStepTick = 40 },
      }
    ),
    1
  )
  local graphics = movieGraphics({ imageSizes = { { 256, 192 }, { 128, 96 }, { 64, 48 }, { 32, 32 }, { 16, 16 } } })
  local movie = openMovie(scenes, cacheFs, graphics)
  for _ = 1, 2 do
    movie:updateFixed()
  end
  movie:draw()
  local earlyWidths = {}
  for _, draw in ipairs(graphics.draws) do
    earlyWidths[draw.image:getWidth()] = true
  end
  Assert.isTrue(earlyWidths[256], "the base image draws before either same-tick swap fires")
  Assert.isNil(earlyWidths[128], "the first swap stays off before its step tick")
  movie:updateFixed()
  movie:draw()
  local lateWidths = {}
  for _, draw in ipairs(graphics.draws) do
    lateWidths[draw.image:getWidth()] = true
  end
  Assert.isTrue(lateWidths[64], "same-tick swaps apply in listed order with the later event winning")
  movie:dispose()
end

function T.repeated_effect_starts_rebind_the_wait_to_the_latest_start()
  local root = sceneRoot(2)
  local scenes, cacheFs = packWithSceneAt(
    compositeManifest(
      2,
      { layer(0, root .. "layers/hold-upper.png", 256, 192) },
      { layer(0, root .. "layers/hold-lower.png", 256, 192) },
      {},
      {
        { id = "hold", events = { 1, 2 }, ["until"] = { kind = "effect", effect = "pulse" } },
        { id = "tail", events = { 3, 4 }, ["until"] = { kind = "duration", ticks = 5 } },
      },
      {
        { op = "setBlend", stepId = "hold", atStepTick = 0, effect = "pulse", ticks = 6 },
        { op = "setBlend", stepId = "hold", atStepTick = 4, effect = "pulse", ticks = 6 },
        { op = "waitTicks", stepId = "tail", atStepTick = 0, ticks = 5 },
        { op = "finish", stepId = "tail", atStepTick = 0 },
      }
    ),
    2
  )
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  for _ = 1, 90 do
    movie:updateFixed()
  end
  Assert.equal(movie:sceneNumber(), 2, "playback reaches the rebound effect step")
  for _ = 1, 6 do
    movie:updateFixed()
  end
  Assert.equal(movie:sceneNumber(), 2, "the first start alone never completes the rebound wait")
  for _ = 1, 5 do
    movie:updateFixed()
  end
  Assert.equal(movie:sceneNumber(), 2, "the rebound wait ends on the latest start with its tail step")
  for _ = 1, 5 do
    movie:updateFixed()
  end
  Assert.equal(movie:sceneNumber(), 3, "the tail step still costs its authored duration")
  movie:dispose()
end

function T.steps_hold_until_a_later_start_fires_and_completes()
  local root = sceneRoot(2)
  local scenes, cacheFs = packWithSceneAt(
    compositeManifest(
      2,
      { layer(0, root .. "layers/hold-upper.png", 256, 192) },
      { layer(0, root .. "layers/hold-lower.png", 256, 192) },
      {},
      {
        { id = "hold", events = { 1 }, ["until"] = { kind = "effect", effect = "late-fade" } },
        { id = "tail", events = { 2, 3 }, ["until"] = { kind = "duration", ticks = 5 } },
      },
      {
        { op = "setFade", stepId = "hold", atStepTick = 5, kind = "white", ticks = 4, effect = "late-fade" },
        { op = "waitTicks", stepId = "tail", atStepTick = 0, ticks = 5 },
        { op = "finish", stepId = "tail", atStepTick = 0 },
      }
    ),
    2
  )
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  for _ = 1, 90 do
    movie:updateFixed()
  end
  Assert.equal(movie:sceneNumber(), 2, "playback reaches the late-start step")
  for _ = 1, 4 do
    movie:updateFixed()
  end
  Assert.equal(movie:sceneNumber(), 2, "the step holds without completing before its effect starts")
  for _ = 1, 4 do
    movie:updateFixed()
  end
  Assert.equal(movie:sceneNumber(), 2, "the started effect runs its authored ticks")
  movie:updateFixed()
  Assert.equal(movie:sceneNumber(), 2, "the effect completion hands over to the tail step")
  for _ = 1, 5 do
    movie:updateFixed()
  end
  Assert.equal(movie:sceneNumber(), 3, "the tail step still costs its authored duration")
  movie:dispose()
end

return { tests = T }
