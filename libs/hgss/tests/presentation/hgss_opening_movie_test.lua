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
  local graphics = movieGraphics()
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
  local badOp = manifestFor(2)
  badOp.timeline.events[1].op = "launchFireworks"
  local badPack = { scenes[1], badOp, scenes[3], scenes[4], scenes[5] }
  Assert.isFalse(attempt(badPack), "an event outside the closed grammar never plays")
  local earlySkip = manifestFor(2)
  earlySkip.timeline.events[1] = { op = "enableSkip", stepId = "open", atTick = 5 }
  earlySkip.timeline.steps[1].events = { 1, 2 }
  local earlyPack = { scenes[1], earlySkip, scenes[3], scenes[4], scenes[5] }
  Assert.isFalse(attempt(earlyPack), "a skip gate outside scene 1 never opens the movie")
  Assert.equal(liveHandles(graphics), 0, "rejected constructions acquire nothing observable")
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

return { tests = T }
