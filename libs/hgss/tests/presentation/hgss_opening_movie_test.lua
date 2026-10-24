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
local MeshWriter = require("libs.assets.src.model.MeshWriter")
local NitroModelFixture = require("tests.support.NitroModelFixture")
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
---@param initialVisible boolean|nil source plane enable state, defaults to visible
---@return table compiled engine layer record
local function layer(bgSlot, image, width, height, priority, initialVisible)
  return {
    bgSlot = bgSlot,
    priority = priority == nil and bgSlot or priority,
    image = image,
    variants = {},
    width = width,
    height = height,
    sourceHash = string.rep("c", 40),
    initialVisible = initialVisible ~= false,
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
  -- Construction preflights every scene through the same frame path, so
  -- only draws issued after the opener count toward the cadence proof.
  local firstBaseline, secondBaseline = #firstGraphics.draws, #secondGraphics.draws
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
    #firstGraphics.draws - firstBaseline,
    (#secondGraphics.draws - secondBaseline) / 3,
    "only fixed ticks drive frames; host draws only repeat the current frame"
  )
  local thirdGraphics = movieGraphics()
  local third = openMovie(scenes, cacheFs, thirdGraphics)
  local thirdBaseline = #thirdGraphics.draws
  for _ = 1, 200 do
    third:updateFixed()
    third:draw()
  end
  Assert.equal(first:sceneNumber(), third:sceneNumber(), "identical fixed ticks reach identical scenes")
  Assert.equal(
    #firstGraphics.draws - firstBaseline,
    #thirdGraphics.draws - thirdBaseline,
    "identical fixed ticks issue identical frame counts"
  )
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
  local frameDrawsStart = #graphics.draws + 1
  for _ = 1, 12 do
    movie:updateFixed()
  end
  movie:draw()
  local byWidth = {}
  local layerDraws = 0
  -- The composed host frame carries the fixed role targets as canvas
  -- blits alongside the source-space layer draws, and construction
  -- preflights every scene through the same frame path: only staged
  -- layer images drawn by this frame prove the per-engine compositor.
  local stagedImages = {}
  for _, image in ipairs(graphics.images) do
    stagedImages[image] = true
  end
  for index = frameDrawsStart, #graphics.draws do
    local draw = graphics.draws[index]
    if stagedImages[draw.image] == true then
      local width = draw.image:getWidth()
      if width == 256 or width == 128 or width == 64 or width == 32 then
        layerDraws = layerDraws + 1
        byWidth[width] = draw
      end
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
          initialVisible = true,
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

-- Strict town acquisition: scene 3 must build all three real town stages with
-- bound animation or abort the scene with a typed failure. A town that
-- cannot build is never allowed to fall back to a drifting 2D backdrop.
-- Fixtures below reuse the strict synthetic scene shape validated through
-- the real startup cache reader; the graphics host stays the shared fake
-- so acquisitions, releases, and draws are counted without a GPU.

---@param models table[] town model records for a synthetic scene three
---@return table strict synthetic scene-three manifest with caller-supplied towns
local function townScene(models)
  local root = sceneRoot(3)
  local upperImage = root .. "upper-bg.png"
  local lowerImage = root .. "lower-bg.png"
  return {
    schema = Contract.startupOpeningScene.schema,
    versionId = VERSION_ID,
    generationId = "movie-test-generation",
    sceneNumber = 3,
    sourceTickRate = Contract.startupOpeningScene.tickRate,
    layers = {
      main = { layer(0, upperImage, 256, 192) },
      sub = { layer(0, lowerImage, 256, 192) },
    },
    spriteClips = {},
    models = models,
    particles = { seed = 0, emitters = {} },
    timeline = { steps = sceneSteps(3), events = sceneEvents(3) },
    assets = { [upperImage] = true, [lowerImage] = true },
  }
end

---@param models table[] town model records for a synthetic scene three
---@return table[] scenes, table cacheFs strict five-scene pack with a custom scene three
local function packWithTownScene(models)
  local raw = {}
  for sceneNumber = 1, 5 do
    if sceneNumber == 3 then
      raw[sceneNumber] = townScene(models)
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

---@param name string town model name
---@param index integer town model index
---@return table town record whose descriptor cannot build a definition
local function unbuildableTown(name, index)
  return {
    name = name,
    index = index,
    descriptor = { key = "synthetic:" .. name, materials = {}, meshes = {} },
    clips = { { frameCount = 2 }, { frameCount = 3 } },
  }
end

-- A town record with a renderable descriptor shape: one node, one segment
-- mesh, one textured material, and caller-supplied clips. The descriptor
-- mirrors the compiled town shape (the staged clip list may repeat the
-- descriptor's clip identities), so assembly proves the merge never
-- double-counts one animation set.
---@param name string town model name
---@param index integer town model index
---@param clips table[] staged animation channels for the town
---@param texture string staged texture path owned by the town material
---@param descriptorClips table[]|nil animation channels already on the descriptor
---@return table town record with a renderable descriptor shape
local function buildableTown(name, index, clips, texture, descriptorClips)
  local root = sceneRoot(3)
  return {
    name = name,
    index = index,
    descriptor = {
      key = "synthetic:" .. name,
      dynamic = {
        nodes = {
          {
            name = "root",
            translation = { x = 0, y = 0, z = 0 },
            rotation = { 1, 0, 0, 0, 1, 0, 0, 0, 1 },
            scale = { x = 1, y = 1, z = 1 },
          },
        },
        transformProgram = NitroModelFixture.doorProgram(),
        batches = {
          {
            id = "seg0",
            nodeIndex = 0,
            materialIndex = 0,
            geometry = root .. "geometry/" .. name .. ".g4mesh",
            drawIndex = 0,
            positionSource = "draw",
            transformMode = "static",
            cullMode = "back",
            polygonMode = "modulation",
            polygonId = 0,
            translucentDepthWrite = false,
            depthEqual = false,
            polygonAlpha = 31,
            lightMask = 15,
            fogEnabled = false,
          },
        },
      },
      materials = {
        {
          id = 0,
          name = "wall",
          texture = texture,
          wrap = { x = "clamp", y = "clamp" },
          baseColor = { r = 255, g = 255, b = 255, a = 255 },
          alphaMode = "opaque",
          polygonAlpha = 31,
          texMtxMode = 0,
          texWidth = 16,
          texHeight = 16,
        },
      },
      animations = descriptorClips or {},
    },
    clips = clips,
  }
end

-- Two compiled joint clips sharing one town clip identity, mirroring the
-- staged town shape where both animation members name the same set. The
-- compilation source stamps stay out: staged bundles carry no source-only
-- identities through the strict scene reader.
---@param id string shared town clip identity
---@return table[] two clips carrying the same identity
local function sameIdentityClips(id)
  local first = NitroModelFixture.doorOpenClip()
  local second = NitroModelFixture.doorCloseClip()
  first.id, second.id = id, id
  first.source, second.source = nil, nil
  return { first, second }
end

-- Two trailing towns the acquisition never reaches: the strict reader still
-- requires all three town records with two animation channels each, but the
-- injected failure aborts on the first town before these ever build.
---@return table[] two inert trailing town records
local function unreachedTowns()
  local towns = {}
  for town = 1, 2 do
    towns[#towns + 1] = {
      name = "town-" .. town,
      index = town,
      descriptor = { key = "synthetic:town-" .. town, materials = {}, meshes = {} },
      clips = { { frameCount = 2 }, { frameCount = 3 } },
    }
  end
  return towns
end

---@param name string town model name
---@param index integer town model index
---@return table town record whose geometry bytes cannot decode
local function meshFailingTown(name, index)
  local root = sceneRoot(3)
  return {
    name = name,
    index = index,
    descriptor = {
      key = "synthetic:" .. name,
      dynamic = {
        nodes = { { name = "root" } },
        transformProgram = {},
        batches = {
          {
            id = "seg0",
            nodeIndex = 0,
            materialIndex = 0,
            geometry = root .. "geometry/" .. name .. ".g4mesh",
          },
        },
      },
      materials = { { id = 0, name = "mat" } },
      animations = {},
    },
    clips = { { frameCount = 2 }, { frameCount = 3 } },
  }
end

---@param failure unknown caught error value
local function assertTypedSceneFailure(failure)
  Assert.equal(
    type(failure),
    "table",
    "a failed town acquisition raises a structured error, never a bare string or silent fallback"
  )
  Assert.equal(failure.code, "HGSS_OPENING_MOVIE_INVALID", "a failed town acquisition raises the typed scene failure")
end

---@param graphics table fake graphics namespace
---@param expected table set of live handles that must survive
---@param message string assertion context
local function assertLiveSetEquals(graphics, expected, message)
  local live = liveSet(graphics)
  local liveCount, expectedCount = 0, 0
  for handle in pairs(live) do
    liveCount = liveCount + 1
    Assert.isTrue(expected[handle] ~= nil, message)
  end
  for _ in pairs(expected) do
    expectedCount = expectedCount + 1
  end
  Assert.equal(liveCount, expectedCount, message)
end

---@param graphics table fake graphics namespace
local function assertReleasedExactlyOnce(graphics)
  Assert.equal(liveHandles(graphics), 0, "a failed acquisition leaves no unreleased handle behind")
  for _, group in ipairs({ graphics.images, graphics.canvases, graphics.meshes or {} }) do
    for _, handle in ipairs(group) do
      Assert.equal(handle.releaseCount, 1, "every acquired handle is released exactly once")
    end
  end
end

function T.a_town_model_that_cannot_build_aborts_the_scene_instead_of_substituting_a_drifting_backdrop()
  local models = {}
  for town = 0, 2 do
    models[#models + 1] = unbuildableTown("town-" .. town, town)
  end
  local scenes, cacheFs = packWithTownScene(models)
  local graphics = movieGraphics()
  -- The five-scene preflight acquires the town stage before the first
  -- frame, so an unbuildable town fails construction instead of failing
  -- mid-run: no partial movie ever becomes visible.
  local movie = nil
  local ok, failure = pcall(function()
    movie = openMovie(scenes, cacheFs, graphics)
  end)
  if ok then
    movie:dispose()
  end
  Assert.isFalse(ok, "the town stage failure surfaces before the first frame instead of playing a fallback scene")
  assertTypedSceneFailure(failure)
  assertReleasedExactlyOnce(graphics)
end

function T.a_town_mesh_that_cannot_decode_aborts_the_scene_and_releases_its_staged_slot()
  local models = {}
  for town = 0, 2 do
    models[#models + 1] = meshFailingTown("town-" .. town, town)
  end
  local scenes, cacheFs = packWithTownScene(models)
  local graphics = movieGraphics()
  -- The five-scene preflight decodes the town stage before the first
  -- frame, so an undecodable town mesh fails construction with every
  -- staged handle released exactly once.
  local movie = nil
  local ok, failure = pcall(function()
    movie = openMovie(scenes, cacheFs, graphics)
  end)
  if ok then
    movie:dispose()
  end
  Assert.isFalse(ok, "the town mesh failure surfaces before the first frame instead of playing a fallback scene")
  assertTypedSceneFailure(failure)
  assertReleasedExactlyOnce(graphics)
end

function T.a_failed_scene_image_acquisition_keeps_the_current_scene_and_releases_exactly_once()
  local scenes, cacheFs = validPack()
  local fakeOpts = {}
  local graphics = movieGraphics(fakeOpts)
  local movie = openMovie(scenes, cacheFs, graphics)
  for _ = 1, 90 do
    movie:updateFixed()
    movie:draw()
  end
  Assert.equal(movie:sceneNumber(), 2, "playback reaches the second scene")
  local heldLive = liveSet(graphics)
  fakeOpts.failOnImageCall = #graphics.images + 1
  local ok, err = pcall(function()
    movie:updateFixed()
  end)
  fakeOpts.failOnImageCall = nil
  Assert.isFalse(ok, "a failed next-scene image acquisition surfaces explicitly")
  assertTypedSceneFailure(err)
  Assert.equal(movie:sceneNumber(), 2, "the failed acquisition never drops the current scene")
  for handle in pairs(heldLive) do
    Assert.isFalse(handle.released, "the failed acquisition never tears down the current scene")
  end
  assertLiveSetEquals(graphics, heldLive, "the failed image acquisition releases its staged images")
  movie:draw()
  movie:dispose()
  assertReleasedExactlyOnce(graphics)
end

function T.a_town_texture_failure_during_the_town_stage_aborts_and_releases_exactly_once()
  local texture = sceneRoot(3) .. "textures/town-0.png"
  local clips = sameIdentityClips("synthetic:town-0:spin")
  local models = { buildableTown("town-0", 0, clips, texture, clips) }
  for _, trailing in ipairs(unreachedTowns()) do
    models[#models + 1] = trailing
  end
  local scenes, baseFs = packWithTownScene(models)
  local state = { textureReads = 0 }
  local cacheFs = {
    loadLua = function(_, path)
      return baseFs:loadLua(path)
    end,
    exists = function()
      return true
    end,
    read = function(_, path)
      if path == texture then
        state.textureReads = state.textureReads + 1
        error("injected town texture failure")
      end
      return baseFs:read(path)
    end,
  }
  local graphics = movieGraphics()
  -- The five-scene preflight reads the town textures before the first
  -- frame, so the injected texture failure aborts construction with every
  -- staged handle released exactly once.
  local movie = nil
  local ok, failure = pcall(function()
    movie = openMovie(scenes, cacheFs, graphics)
  end)
  if ok then
    movie:dispose()
  end
  Assert.isFalse(ok, "the town texture failure surfaces before the first frame instead of playing a fallback scene")
  Assert.isTrue(state.textureReads > 0, "the town texture is read eagerly during acquisition, never lazily")
  assertTypedSceneFailure(failure)
  assertReleasedExactlyOnce(graphics)
end

function T.a_town_without_a_bindable_clip_aborts_the_scene_and_releases_its_staged_slot()
  local texture = sceneRoot(3) .. "textures/town-0.png"
  local models = { buildableTown("town-0", 0, { { frameCount = 2 }, { frameCount = 3 } }, texture) }
  for _, trailing in ipairs(unreachedTowns()) do
    models[#models + 1] = trailing
  end
  local scenes, cacheFs = packWithTownScene(models)
  local graphics = movieGraphics()
  -- The five-scene preflight binds the town clips before the first frame,
  -- so a town with no bindable clip fails construction with every staged
  -- handle released exactly once.
  local movie = nil
  local ok, failure = pcall(function()
    movie = openMovie(scenes, cacheFs, graphics)
  end)
  if ok then
    movie:dispose()
  end
  Assert.isFalse(ok, "the town clip failure surfaces before the first frame instead of playing a mute town")
  assertTypedSceneFailure(failure)
  assertReleasedExactlyOnce(graphics)
end

-- Opens the movie at an explicit stage size through an injected graphics
-- namespace, so bounded-target and resize tests control both halves of the
-- construction seam the shared opener fixes.
---@param scenes table[] validated scene bundles in retail order
---@param cacheFs table staged art backing the scenes
---@param graphics table fake graphics namespace
---@param width integer host stage width
---@param height integer host stage height
---@return table player
local function openMovieSized(scenes, cacheFs, graphics, width, height)
  local Movie = requireMovie()
  local context = DisplayContext.new({
    graphics = graphics,
    topologyProvider = function(stageWidth, stageHeight)
      return {
        surfaces = {
          {
            id = "main",
            rect = { x = 0, y = 0, width = stageWidth, height = stageHeight },
            touch = false,
            role = "world",
          },
        },
      }
    end,
  })
  return Movie.new({
    versionId = VERSION_ID,
    scenes = scenes,
    cacheFs = cacheFs,
    width = width,
    height = height,
    graphics = graphics,
    displayContext = context,
  })
end

function T.construction_preflights_all_five_scenes_before_the_first_frame()
  local raw = {}
  for sceneNumber = 1, 5 do
    raw[sceneNumber] = manifestFor(sceneNumber)
  end
  local poisoned = sceneRoot(5) .. "lower-bg.png"
  local state = { poisonedReads = 0 }
  local baseFs = stubCache(raw)
  local cacheFs = {
    loadLua = function(_, path)
      return baseFs:loadLua(path)
    end,
    exists = function()
      return true
    end,
    read = function(_, path)
      if path == poisoned then
        state.poisonedReads = state.poisonedReads + 1
        error("injected scene five art failure")
      end
      return baseFs:read(path)
    end,
  }
  local scenes = {}
  for sceneNumber = 1, 5 do
    local loaded, err = StartupAssetCache.loadOpeningScene(baseFs, sceneNumber, VERSION_ID)
    Assert.notNil(loaded, "synthetic scene " .. sceneNumber .. " passes the strict scene reader: " .. tostring(err))
    scenes[sceneNumber] = loaded
  end
  local graphics = movieGraphics()
  local movie = nil
  local ok, failure = pcall(function()
    movie = openMovieSized(scenes, cacheFs, graphics, WIDTH, HEIGHT)
  end)
  if ok then
    movie:dispose()
  end
  Assert.isFalse(ok, "construction preflights all five scenes instead of publishing after the first")
  Assert.isTrue(state.poisonedReads > 0, "the fifth scene acquisition is attempted before the movie becomes visible")
  assertTypedSceneFailure(failure)
  Assert.equal(liveHandles(graphics), 0, "a failed preflight releases every staged handle")
end

function T.construction_keeps_two_bounded_role_targets_for_the_current_and_next_scenes()
  local scenes, cacheFs = validPack()
  local graphics = movieGraphics()
  local movie = openMovieSized(scenes, cacheFs, graphics, WIDTH, HEIGHT)
  Assert.equal(movie:sceneNumber(), 1, "a preflighted movie still starts at the first scene")
  Assert.isFalse(movie:skipAllowed(), "a preflighted movie still opens with the skip gate closed")
  Assert.equal(#graphics.canvases, 2, "construction keeps exactly two bounded role targets")
  for _, canvas in ipairs(graphics.canvases) do
    Assert.equal(canvas.width, 256, "every role target keeps the source engine width")
    Assert.equal(canvas.height, 192, "every role target keeps the source engine height")
  end
  -- The first scene owns its two staged images plus one clip image and the
  -- prefetched second scene owns its two staged images: nothing else may
  -- stay resident after the sequential preflight releases its transients.
  Assert.equal(liveHandles(graphics), 7, "construction retains only the current and next scene graphs")
  movie:draw()
  movie:dispose()
  Assert.equal(liveHandles(graphics), 0, "disposing the preflighted movie releases every handle")
end

function T.preflight_offscreen_renders_every_scene_once_without_consuming_source_time()
  local scenes, cacheFs = validPack()
  local graphics = movieGraphics()
  local Movie = requireMovie()
  local rendered = {}
  local realRender = Movie._renderRoles
  Movie._renderRoles = function(self, slot)
    rendered[#rendered + 1] = slot.sceneNumber
    return realRender(self, slot)
  end
  local movie = nil
  local ok, failure = pcall(function()
    movie = openMovie(scenes, cacheFs, graphics)
  end)
  Movie._renderRoles = realRender
  Assert.isTrue(ok, "preflight still readies a drawable movie: " .. tostring(failure))
  Assert.equal(#rendered, 5, "preflight proves every scene with a real offscreen render, never a manifest-only check")
  for sceneNumber = 1, 5 do
    Assert.equal(rendered[sceneNumber], sceneNumber, "preflight renders scenes in retail order")
  end
  Assert.equal(movie:sceneNumber(), 1, "preflight consumes no source time")
  Assert.isFalse(movie:skipAllowed(), "preflight leaves the skip gate closed")
  Assert.equal(liveHandles(graphics), 7, "preflight retains only the current and next scene graphs")
  movie:draw()
  movie:dispose()
  Assert.equal(liveHandles(graphics), 0, "disposing the preflighted movie releases every handle")
end

function T.every_canvas_allocation_uses_the_bounded_numeric_module_signature_across_resizes()
  local scenes, cacheFs = validPack()
  local graphics = movieGraphics()
  local calls = {}
  local realNewCanvas = graphics.newCanvas
  graphics.newCanvas = function(width, height, opts)
    calls[#calls + 1] = { width = width, height = height }
    return realNewCanvas(width, height, opts)
  end
  local movie = openMovieSized(scenes, cacheFs, graphics, 256, 192)
  movie:resize(3840, 2160)
  movie:resize(7680, 4320)
  movie:resize(600, 1000)
  movie:resize(512, 384)
  Assert.equal(movie:sceneNumber(), 1, "resizing across size classes never rewinds the movie clock")
  for index, call in ipairs(calls) do
    Assert.equal(
      type(call.width),
      "number",
      "canvas call " .. index .. " passes numeric dimensions, never the graphics namespace"
    )
    Assert.equal(
      type(call.height),
      "number",
      "canvas call " .. index .. " passes numeric dimensions, never the graphics namespace"
    )
    Assert.isTrue(
      call.width <= 256 and call.height <= 192,
      "canvas call " .. index .. " stays within the 256x192 source frame"
    )
  end
  Assert.isTrue(#graphics.canvases <= 2, "resizing allocates no host-sized targets")
  movie:draw()
  movie:dispose()
  Assert.equal(liveHandles(graphics), 0, "the resized movie releases every handle")
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

-- Engine-compositor acceptance fixtures: per-engine plane visibility and
-- priority, main-only town and particle stages, and independent
-- engine-local source windows with plane masks. Every fixture below passes
-- the strict generated reader, so each test fails on the compositor
-- behavior itself rather than on fixture loading.

---@param stepId string owning step identity
---@param atStepTick integer source tick the window program starts
---@param engine string source engine owning the window registers
---@param from table source start rectangle {x1,y1,x2,y2}
---@param to table source end rectangle {x1,y1,x2,y2}
---@param ticks integer authored pan length in source frames
---@param insideMask integer plane mask inside the window
---@param outsideMask integer plane mask outside the window
---@param effect string|nil waitable effect started for a positive duration
---@return table engine-local source window event
local function windowEvent(stepId, atStepTick, engine, from, to, ticks, insideMask, outsideMask, effect)
  local event = {
    op = "window",
    stepId = stepId,
    atStepTick = atStepTick,
    engine = engine,
    from = from,
    to = to,
    ticks = ticks,
    insideMask = insideMask,
    outsideMask = outsideMask,
  }
  if effect ~= nil then
    event.effect = effect
  end
  return event
end

---@param x1 integer
---@param y1 integer
---@param x2 integer
---@param y2 integer
---@return table source pixel rectangle
local function windowRect(x1, y1, x2, y2)
  return { x1 = x1, y1 = y1, x2 = x2, y2 = y2 }
end

---@param graphics table fake graphics namespace
---@param movie table player owning the fixed role canvases
---@param engine string "main" or "sub"
---@param image table staged image handle to count
---@param baseline integer only draws after this draw index
---@return table[] draws of the image into the engine target
local function engineDrawsOf(graphics, movie, engine, image, baseline)
  local target = (engine == "main") and movie.mainCanvas or movie.subCanvas
  local found = {}
  for index = (baseline or 0) + 1, #graphics.draws do
    local draw = graphics.draws[index]
    if graphics.drawCanvases[index].canvas == target and draw.image == image then
      found[#found + 1] = draw
    end
  end
  return found
end

---@param graphics table fake graphics namespace
---@param movie table player owning the fixed role canvases
---@param engine string "main" or "sub"
---@param baseline integer only scissor records after this index
---@return table[] requested scissor rects on the engine target
local function engineScissors(graphics, movie, engine, baseline)
  local target = (engine == "main") and movie.mainCanvas or movie.subCanvas
  local found = {}
  for index = (baseline or 0) + 1, #graphics.scissorIntersections do
    local entry = graphics.scissorIntersections[index]
    if graphics.scissorCanvases[index].canvas == target then
      found[#found + 1] = entry.requested
    end
  end
  return found
end

---@param rects table[] requested scissor rects
---@param x integer
---@param y integer
---@param w integer
---@param h integer
---@return boolean true when the exact region was clipped
local function hasScissor(rects, x, y, w, h)
  for _, rect in ipairs(rects) do
    if rect[1] == x and rect[2] == y and rect[3] == w and rect[4] == h then
      return true
    end
  end
  return false
end

---@param steps table[] source step records
---@param events table[] closed step-clocked timeline events
---@return table strict synthetic scene-four manifest with all nine starter emitters
local function particleScene(steps, events)
  local root = sceneRoot(4)
  local upperImage = root .. "upper-bg.png"
  local lowerImage = root .. "lower-bg.png"
  local ethanClip = root .. "sprites/ethan.g4sprite"
  local emitters, textures = {}, {}
  local assets = { [upperImage] = true, [lowerImage] = true, [ethanClip] = true }
  for id = 0, 8 do
    local group = id < 3 and "water" or (id < 6 and "fire" or "grass")
    emitters[#emitters + 1] = testEmitter(id, group)
    textures[#textures + 1] = {
      id = id,
      format = 1,
      width = 16,
      height = 16,
      image = root .. "particles/texture" .. id .. ".png",
      sourceHash = string.rep("d", 40),
    }
    assets[root .. "particles/texture" .. id .. ".png"] = true
  end
  return {
    schema = Contract.startupOpeningScene.schema,
    versionId = VERSION_ID,
    generationId = "movie-test-generation",
    sceneNumber = 4,
    sourceTickRate = Contract.startupOpeningScene.tickRate,
    layers = {
      main = { layer(0, upperImage, 256, 192) },
      sub = { layer(0, lowerImage, 256, 192) },
    },
    spriteClips = { spriteClip(ethanClip, { stillFrame() }) },
    models = {},
    particles = { seed = 0, emitters = emitters, textures = textures },
    timeline = { steps = steps, events = events },
    assets = assets,
  }
end

---@param models table[] town model records for a synthetic scene three
---@param steps table[] source step records
---@param events table[] closed step-clocked timeline events
---@param mainVisible boolean source enable state of the main panel
---@return table strict synthetic scene-three manifest with caller-supplied towns and program
local function townSceneCustom(models, steps, events, mainVisible)
  local root = sceneRoot(3)
  local upperImage = root .. "upper-bg.png"
  local lowerImage = root .. "lower-bg.png"
  return {
    schema = Contract.startupOpeningScene.schema,
    versionId = VERSION_ID,
    generationId = "movie-test-generation",
    sceneNumber = 3,
    sourceTickRate = Contract.startupOpeningScene.tickRate,
    layers = {
      main = { layer(0, upperImage, 256, 192, 0, mainVisible) },
      sub = { layer(0, lowerImage, 256, 192) },
    },
    spriteClips = {},
    models = models,
    particles = { seed = 0, emitters = {} },
    timeline = { steps = steps, events = events },
    assets = { [upperImage] = true, [lowerImage] = true },
  }
end

function T.bg_priority_zero_paints_last_and_hidden_planes_stay_dark()
  local root = sceneRoot(1)
  local backImage = root .. "layers/back.png"
  local frontImage = root .. "layers/front.png"
  local middleImage = root .. "layers/middle.png"
  local hiddenImage = root .. "layers/hidden.png"
  local scenes, cacheFs = packWithSceneAt(
    compositeManifest(
      1,
      {
        layer(2, backImage, 256, 192, 2),
        layer(0, frontImage, 64, 192, 0),
        layer(1, middleImage, 128, 192, 1),
        layer(3, hiddenImage, 48, 192, 3, false),
      },
      { layer(0, root .. "layers/lower.png", 256, 192) },
      { spriteClip(root .. "sprites/clip0.g4sprite", { stillFrame() }) },
      { { id = "show", events = { 1, 2, 3, 4 }, ["until"] = { kind = "duration", ticks = 40 } } },
      {
        {
          op = "setLayer",
          stepId = "show",
          atStepTick = 5,
          engine = "main",
          bgSlot = 3,
          image = hiddenImage,
          visible = true,
          priority = 3,
        },
        { op = "enableSkip", stepId = "show", atStepTick = 10 },
        { op = "waitTicks", stepId = "show", atStepTick = 0, ticks = 40 },
        { op = "finish", stepId = "show", atStepTick = 40 },
      }
    ),
    1
  )
  -- Acquisition order fixes the fake image sizes: the three visible main
  -- planes tag their priority by width, then the hidden plane, the sub
  -- plane, and the sprite clip.
  local graphics = movieGraphics({
    imageSizes = { { 256, 192 }, { 64, 192 }, { 128, 192 }, { 48, 192 }, { 256, 192 }, { 16, 16 } },
  })
  local movie = openMovie(scenes, cacheFs, graphics)
  local baseline = #graphics.draws
  for _ = 1, 2 do
    movie:updateFixed()
  end
  movie:draw()
  local order = {}
  local hiddenDrawn = false
  for index = baseline + 1, #graphics.draws do
    local draw = graphics.draws[index]
    if graphics.drawCanvases[index].canvas == movie.mainCanvas then
      local width = draw.image:getWidth()
      if width == 256 or width == 128 or width == 64 then
        order[#order + 1] = width
      elseif width == 48 then
        hiddenDrawn = true
      end
    end
  end
  Assert.equal(#order, 3, "every visible main plane paints exactly once")
  Assert.equal(order[1], 256, "numeric priority 2 paints first (backmost)")
  Assert.equal(order[2], 128, "numeric priority 1 paints next")
  Assert.equal(order[3], 64, "numeric priority 0 paints last (frontmost)")
  Assert.isFalse(hiddenDrawn, "the disabled slot contributes no pixels despite its staged image")
  for _ = 1, 4 do
    movie:updateFixed()
  end
  local revealBaseline = #graphics.draws
  movie:draw()
  local revealed = false
  for index = revealBaseline + 1, #graphics.draws do
    local draw = graphics.draws[index]
    if graphics.drawCanvases[index].canvas == movie.mainCanvas and draw.image:getWidth() == 48 then
      revealed = true
    end
  end
  Assert.isTrue(revealed, "setLayer reveals the hidden plane on its authored tick")
  movie:dispose()
end

function T.town_stage_draws_on_main_and_stops_without_releasing()
  local root = sceneRoot(3)
  local models = {}
  for town = 0, 2 do
    local texture = root .. "textures/town-" .. town .. ".png"
    local clips = sameIdentityClips("synthetic:town-" .. town .. ":spin")
    models[#models + 1] = buildableTown("town-" .. town, town, clips, texture, clips)
  end
  local customThird = townSceneCustom(models, {
      { id = "arrive", events = { 1, 2, 3 }, ["until"] = { kind = "duration", ticks = 20 } },
      { id = "hold", events = { 4, 5, 6, 7 }, ["until"] = { kind = "duration", ticks = 30 } },
    }, {
      { op = "setCamera", stepId = "arrive", atStepTick = 0, distance = 100 },
      { op = "setModelClip", stepId = "arrive", atStepTick = 0, model = "town-0", clip = "arrive-pose" },
      { op = "waitTicks", stepId = "arrive", atStepTick = 0, ticks = 20 },
      { op = "setLighting", stepId = "hold", atStepTick = 0, map = 1 },
      { op = "setModelVisible", stepId = "hold", atStepTick = 10, visible = false },
      { op = "waitTicks", stepId = "hold", atStepTick = 0, ticks = 30 },
      { op = "finish", stepId = "hold", atStepTick = 0 },
    }, false)
  -- Town geometry decodes from real encoded mesh bytes; every other staged
  -- path serves synthetic bytes the fake image host accepts.
  local meshBytes = MeshWriter.encode(NitroModelFixture.doorQuad())
  local rawThird = {}
  for sceneNumber = 1, 5 do
    rawThird[sceneNumber] = manifestFor(sceneNumber)
  end
  rawThird[3] = customThird
  local byPathThird = {}
  for sceneNumber, manifest in pairs(rawThird) do
    byPathThird[StartupAssetCache.openingScenePath(sceneNumber)] = manifest
  end
  local cacheFs = {
    loadLua = function(_, path)
      return byPathThird[path]
    end,
    exists = function()
      return true
    end,
    read = function(_, path)
      if path:find("/geometry/", 1, true) ~= nil then
        return meshBytes
      end
      return "bytes:" .. tostring(path)
    end,
  }
  local scenes = {}
  for sceneNumber = 1, 5 do
    local loaded, err = StartupAssetCache.loadOpeningScene(cacheFs, sceneNumber, VERSION_ID)
    Assert.notNil(loaded, "synthetic scene " .. sceneNumber .. " passes the strict scene reader: " .. tostring(err))
    scenes[sceneNumber] = loaded
  end
  local graphics = movieGraphics()
  -- The town stage composites through the real field renderer, which the
  -- fake image host cannot feed: construction already proves the preflight
  -- keeps town pixels off both targets until the authored clip selects the
  -- town, and the run below never draws while the town is live. Per-engine
  -- town pixels are proved on the real GPU suite instead.
  local movie = openMovie(scenes, cacheFs, graphics)
  local ticks = 0
  while movie:sceneNumber() < 3 and ticks < 5000 do
    movie:updateFixed()
    ticks = ticks + 1
  end
  Assert.equal(movie:sceneNumber(), 3, "playback reaches the town scene")
  Assert.isFalse(movie.current.townVisible, "the town stage contributes nothing before its clip")
  -- The town beat runs silently: drawing it would composite staged town
  -- meshes the fake host cannot texture. Scene 3 arrives at tick 130,
  -- holds 20 arrive ticks, and stops its town at the eleventh hold tick,
  -- so 31 silent ticks land just past the authored stop.
  for _ = 1, 10 do
    movie:updateFixed()
  end
  Assert.isTrue(movie.current.townVisible, "the town clip opens the main BG0 stage")
  for _ = 1, 21 do
    movie:updateFixed()
  end
  Assert.equal(movie:sceneNumber(), 3, "the town beat holds past its authored stop tick")
  Assert.isFalse(movie.current.townVisible, "the authored stop retires the town stage")
  Assert.equal(#movie.current.towns, 3, "the live town stage keeps all three towns staged")
  Assert.isTrue(movie.current.pool.triangles > 0, "the live town stage keeps its geometry")
  local townPool = movie.current.pool
  -- Past the stop the rival-only sub panel draws alone on the
  -- single-screen stage; the quiet main target contributes nothing.
  local stopBaseline = #graphics.draws
  movie:draw()
  local mainDraws, subDraws = 0, 0
  for index = stopBaseline + 1, #graphics.draws do
    local draw = graphics.draws[index]
    if draw.image == movie.mainCanvas then
      mainDraws = mainDraws + 1
    elseif draw.image == movie.subCanvas then
      subDraws = subDraws + 1
    end
  end
  Assert.equal(mainDraws, 0, "the quiet main target no longer fills the single-screen stage")
  Assert.isTrue(subDraws > 0, "the rival-only sub target fills the single-screen stage")
  movie:dispose()
  Assert.equal(townPool.triangles, 0, "slot disposal releases the town geometry")
  Assert.equal(liveHandles(graphics), 0, "disposing the town movie releases every handle")
end

function T.independent_engine_windows_mask_planes_through_flips()
  local root = sceneRoot(1)
  local mainBg1 = root .. "layers/main-bg1.png"
  local mainBg2 = root .. "layers/main-bg2.png"
  local subBg1 = root .. "layers/sub-bg1.png"
  local subBg2 = root .. "layers/sub-bg2.png"
  local heroMain = root .. "sprites/hero-main.g4sprite"
  local heroSub = root .. "sprites/hero-sub.g4sprite"
  local function opposingScene(mapping)
    return compositeManifest(
      1,
      { layer(1, mainBg1, 64, 192, 1), layer(2, mainBg2, 128, 192, 2) },
      { layer(1, subBg1, 96, 192, 1), layer(2, subBg2, 112, 192, 2) },
      {
        spriteClip(heroMain, { stillFrame() }),
        spriteClip(heroSub, { stillFrame() }),
      },
      { { id = "reveal", events = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 }, ["until"] = { kind = "duration", ticks = 20 } } },
      {
        windowEvent("reveal", 0, "main", windowRect(255, 0, 255, 192), windowRect(0, 0, 255, 192), 10, 30, 28),
        windowEvent("reveal", 0, "sub", windowRect(0, 0, 0, 192), windowRect(0, 0, 255, 192), 10, 30, 28),
        {
          op = "setSpriteClip",
          stepId = "reveal",
          atStepTick = 0,
          instanceId = "hero1",
          engine = "main",
          x = 200,
          y = 96,
          drawOrder = 1,
          clipId = heroMain,
        },
        {
          op = "spriteVisible",
          stepId = "reveal",
          atStepTick = 0,
          instanceId = "hero1",
          engine = "main",
          x = 200,
          y = 96,
          drawOrder = 1,
          visible = true,
        },
        {
          op = "setSpriteClip",
          stepId = "reveal",
          atStepTick = 0,
          instanceId = "hero2",
          engine = "sub",
          x = 32,
          y = 96,
          drawOrder = 1,
          clipId = heroSub,
        },
        {
          op = "spriteVisible",
          stepId = "reveal",
          atStepTick = 0,
          instanceId = "hero2",
          engine = "sub",
          x = 32,
          y = 96,
          drawOrder = 1,
          visible = true,
        },
        {
          op = "setWindowSecondary",
          stepId = "reveal",
          atStepTick = 12,
          engine = "main",
          rect = windowRect(0, 64, 255, 128),
          insideMask = 16,
        },
        { op = "setScreenMapping", stepId = "reveal", atStepTick = 5, mainPhysical = mapping },
        { op = "enableSkip", stepId = "reveal", atStepTick = 10 },
        { op = "waitTicks", stepId = "reveal", atStepTick = 0, ticks = 20 },
        { op = "finish", stepId = "reveal", atStepTick = 20 },
      }
    )
  end
  -- Acquisition order fixes the fake image sizes behind each engine slot.
  local sizes = { { 64, 192 }, { 128, 192 }, { 96, 192 }, { 112, 192 }, { 16, 16 }, { 16, 16 } }
  local flipScenes, flipCache = packWithSceneAt(opposingScene("lower"), 1)
  local flipGraphics = movieGraphics({ imageSizes = sizes })
  local flipped = openMovie(flipScenes, flipCache, flipGraphics)
  local plainScenes, plainCache = packWithSceneAt(opposingScene("upper"), 1)
  local plainGraphics = movieGraphics({ imageSizes = sizes })
  local plain = openMovie(plainScenes, plainCache, plainGraphics)
  for _ = 1, 5 do
    flipped:updateFixed()
    plain:updateFixed()
  end
  local flipBaseline = #flipGraphics.draws
  local flipScissorBaseline, plainScissorBaseline =
    #flipGraphics.scissorIntersections, #plainGraphics.scissorIntersections
  flipped:draw()
  plain:draw()
  -- At the fifth pan tick the main window spans [128,256) and the sub
  -- window spans [0,128). Draws pair with their preceding clip in order:
  -- BG2 paints first and full, BG1 paints only its inside band, and the
  -- sprite rides the OBJ bit across the whole target.
  local function engineFrame(graphics, movie, engine, drawBaseline, scissorBaseline)
    local target = (engine == "main") and movie.mainCanvas or movie.subCanvas
    local draws, scissors = {}, {}
    for index = drawBaseline + 1, #graphics.draws do
      local draw = graphics.draws[index]
      if graphics.drawCanvases[index].canvas == target then
        draws[#draws + 1] = draw
      end
    end
    for index = scissorBaseline + 1, #graphics.scissorIntersections do
      local entry = graphics.scissorIntersections[index]
      if graphics.scissorCanvases[index].canvas == target then
        scissors[#scissors + 1] = entry.requested
      end
    end
    return draws, scissors
  end
  local mainDraws, mainScissors = engineFrame(flipGraphics, flipped, "main", flipBaseline, flipScissorBaseline)
  Assert.equal(#mainDraws, 3, "main BG2, BG1, and its sprite each paint once")
  Assert.equal(mainDraws[1].image, flipGraphics.images[2], "main BG2 paints first (backmost)")
  Assert.equal(mainDraws[2].image, flipGraphics.images[1], "main BG1 paints next")
  Assert.notNil(mainDraws[3].quad, "the main sprite paints through its authored clip")
  Assert.equal(#mainScissors, 3, "every main plane draws under its own clip")
  Assert.isTrue(hasScissor({ mainScissors[1] }, 0, 0, 256, 192), "main BG2 paints the whole target")
  Assert.isTrue(
    hasScissor({ mainScissors[2] }, 128, 0, 128, 192),
    "main BG1 paints only its inside band from the authored right edge"
  )
  Assert.isTrue(hasScissor({ mainScissors[3] }, 0, 0, 256, 192), "main OBJ paints wherever the mask allows")
  local subDraws, subScissors = engineFrame(flipGraphics, flipped, "sub", flipBaseline, flipScissorBaseline)
  Assert.equal(#subDraws, 3, "sub BG2, BG1, and its sprite each paint once")
  Assert.equal(subDraws[1].image, flipGraphics.images[4], "sub BG2 paints first (backmost)")
  Assert.equal(subDraws[2].image, flipGraphics.images[3], "sub BG1 paints next")
  Assert.notNil(subDraws[3].quad, "the sub sprite paints through its authored clip")
  Assert.equal(#subScissors, 3, "every sub plane draws under its own clip")
  Assert.isTrue(hasScissor({ subScissors[1] }, 0, 0, 256, 192), "sub BG2 paints the whole target")
  Assert.isTrue(
    hasScissor({ subScissors[2] }, 0, 0, 128, 192),
    "sub BG1 paints only its inside band from the authored left edge"
  )
  Assert.isTrue(hasScissor({ subScissors[3] }, 0, 0, 256, 192), "sub OBJ paints wherever the mask allows")
  -- The physical flip moves placement, never engine window ownership.
  local flippedMain = engineScissors(flipGraphics, flipped, "main", flipScissorBaseline)
  local plainMain = engineScissors(plainGraphics, plain, "main", plainScissorBaseline)
  Assert.equal(#flippedMain, #plainMain, "the flip preserves the main window region count")
  for _, rect in ipairs(plainMain) do
    Assert.isTrue(
      hasScissor(flippedMain, rect[1], rect[2], rect[3], rect[4]),
      "the flip preserves every main window region"
    )
  end
  -- The manual second-register override splits the main target horizontally:
  -- only its band edges can cut the BG1 rows the completed full-width pan
  -- would otherwise paint whole.
  for _ = 1, 8 do
    flipped:updateFixed()
  end
  local overrideBaseline = #flipGraphics.scissorIntersections
  flipped:draw()
  local overrideScissors = engineScissors(flipGraphics, flipped, "main", overrideBaseline)
  Assert.isTrue(
    hasScissor(overrideScissors, 0, 64, 128, 64) or hasScissor(overrideScissors, 0, 64, 128, 65),
    "the manual second-register override cuts its authored horizontal band"
  )
  flipped:dispose()
  plain:dispose()
end

function T.starter_particles_draw_only_on_main_through_flips()
  local scenes, cacheFs = packWithSceneAt(
    particleScene(
      {
        { id = "intro", events = { 1 }, ["until"] = { kind = "duration", ticks = 10 } },
        { id = "starters", events = { 2, 3, 4 }, ["until"] = { kind = "effect", effect = "emitters-grass" } },
        { id = "outro", events = { 5, 6, 7 }, ["until"] = { kind = "duration", ticks = 10 } },
      },
      {
        { op = "waitTicks", stepId = "intro", atStepTick = 0, ticks = 10 },
        { op = "startEmitters", stepId = "starters", atStepTick = 0, group = "grass", emitters = { 6, 7, 8 } },
        { op = "setScreenMapping", stepId = "starters", atStepTick = 5, mainPhysical = "lower" },
        { op = "waitEffects", stepId = "starters", atStepTick = 0, effects = { "emitters-grass" } },
        { op = "setScreenMapping", stepId = "outro", atStepTick = 2, mainPhysical = "upper" },
        { op = "waitTicks", stepId = "outro", atStepTick = 0, ticks = 10 },
        { op = "finish", stepId = "outro", atStepTick = 0 },
      }
    ),
    4
  )
  -- Images 11..19 are the nine staged particle textures behind the 8-wide tag.
  local sizes = {}
  for index = 1, 21 do
    sizes[index] = { 16, 16 }
  end
  for index = 11, 19 do
    sizes[index] = { 8, 8 }
  end
  local graphics = movieGraphics({ imageSizes = sizes })
  local movie = openMovie(scenes, cacheFs, graphics)
  local ticks = 0
  while movie:sceneNumber() < 4 and ticks < 5000 do
    movie:updateFixed()
    ticks = ticks + 1
  end
  Assert.equal(movie:sceneNumber(), 4, "playback reaches the starter scene")
  for _ = 1, 30 do
    movie:updateFixed()
  end
  -- Playback re-acquires each scene on entry, so particle art is
  -- identified through the live slot's staged handles, never by creation
  -- order or tag size.
  local particleImages = {}
  for id = 0, 8 do
    local handle = movie.current.imageByPath[sceneRoot(4) .. "particles/texture" .. id .. ".png"]
    Assert.notNil(handle, "starter texture " .. id .. " stays staged while its scene plays")
    particleImages[handle] = true
  end
  local firstBaseline = #graphics.draws
  movie:draw()
  local mainParticles, subParticles = 0, 0
  for index = firstBaseline + 1, #graphics.draws do
    local draw = graphics.draws[index]
    if particleImages[draw.image] == true then
      if graphics.drawCanvases[index].canvas == movie.mainCanvas then
        mainParticles = mainParticles + 1
      elseif graphics.drawCanvases[index].canvas == movie.subCanvas then
        subParticles = subParticles + 1
      end
    end
  end
  Assert.isTrue(mainParticles > 0, "starter particles paint the main engine target")
  Assert.equal(subParticles, 0, "starter particles never paint the sub engine target")
  -- Past the second flip the ownership still holds while placement follows.
  local guard = 0
  while movie:sceneNumber() == 4 and guard < 5000 do
    movie:updateFixed()
    guard = guard + 1
  end
  Assert.equal(movie:sceneNumber(), 5, "the starter step ends on its emitter effect")
  local secondBaseline = #graphics.draws
  movie:draw()
  local lateSub = 0
  for index = secondBaseline + 1, #graphics.draws do
    local draw = graphics.draws[index]
    if particleImages[draw.image] == true and graphics.drawCanvases[index].canvas == movie.subCanvas then
      lateSub = lateSub + 1
    end
  end
  -- Scene 5 carries no emitters, so its frame draws no particle pixels;
  -- the assertion is that no sub-engine copy ever appears on the way out.
  Assert.equal(lateSub, 0, "no sub-engine particle copy appears through the flips")
  movie:dispose()
end

function T.window_sampling_truncates_toward_zero_and_applies_zero_ticks_immediately()
  local root = sceneRoot(1)
  local scenes, cacheFs = packWithSceneAt(
    compositeManifest(
      1,
      { layer(1, root .. "layers/plane.png", 256, 192, 1) },
      { layer(0, root .. "layers/lower.png", 256, 192) },
      { spriteClip(root .. "sprites/clip0.g4sprite", { stillFrame() }) },
      { { id = "sweep", events = { 1, 2, 3, 4, 5 }, ["until"] = { kind = "effect", effect = "win-sweep" } } },
      {
        windowEvent("sweep", 0, "main", windowRect(200, 0, 255, 100), windowRect(50, 0, 255, 100), 7, 31, 0, "win-sweep"),
        { op = "enableSkip", stepId = "sweep", atStepTick = 10 },
        { op = "waitTicks", stepId = "sweep", atStepTick = 0, ticks = 40 },
        { op = "finish", stepId = "sweep", atStepTick = 40 },
        windowEvent("sweep", 5, "main", windowRect(9, 9, 19, 19), windowRect(10, 10, 20, 20), 0, 31, 0),
      }
    ),
    1
  )
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  -- The negative edge moves (50-200)*3/7 = -64.28, truncated toward zero
  -- to -64: the window opens at x=136, never the floored 135.
  for _ = 1, 3 do
    movie:updateFixed()
  end
  local sweepBaseline = #graphics.scissorIntersections
  movie:draw()
  local sweepScissors = engineScissors(graphics, movie, "main", sweepBaseline)
  Assert.isTrue(hasScissor(sweepScissors, 136, 0, 120, 101), "negative window edges truncate toward zero")
  -- A zero-duration assignment lands on its target rectangle immediately.
  for _ = 1, 3 do
    movie:updateFixed()
  end
  local snapBaseline = #graphics.scissorIntersections
  movie:draw()
  local snapScissors = engineScissors(graphics, movie, "main", snapBaseline)
  Assert.isTrue(hasScissor(snapScissors, 10, 10, 11, 11), "a zero-tick window applies its target at once")
  movie:dispose()
end

function T.screen_flip_preserves_engine_window_state()
  local root = sceneRoot(1)
  local function flipScene(mapping, atTick)
    return compositeManifest(
      1,
      { layer(1, root .. "layers/plane.png", 256, 192, 1) },
      { layer(0, root .. "layers/lower.png", 256, 192) },
      { spriteClip(root .. "sprites/clip0.g4sprite", { stillFrame() }) },
      { { id = "pan", events = { 1, 2, 3, 4 }, ["until"] = { kind = "duration", ticks = 20 } } },
      {
        windowEvent("pan", 0, "main", windowRect(255, 0, 255, 192), windowRect(0, 0, 255, 192), 10, 31, 0),
        { op = "setScreenMapping", stepId = "pan", atStepTick = atTick, mainPhysical = mapping },
        { op = "enableSkip", stepId = "pan", atStepTick = 10 },
        { op = "finish", stepId = "pan", atStepTick = 20 },
      }
    )
  end
  local flipScenes, flipCache = packWithSceneAt(flipScene("lower", 5), 1)
  local flipGraphics = movieGraphics()
  local flipped = openMovie(flipScenes, flipCache, flipGraphics)
  local plainScenes, plainCache = packWithSceneAt(flipScene("upper", 5), 1)
  local plainGraphics = movieGraphics()
  local plain = openMovie(plainScenes, plainCache, plainGraphics)
  for _ = 1, 8 do
    flipped:updateFixed()
    plain:updateFixed()
  end
  local flipBaseline, plainBaseline = #flipGraphics.scissorIntersections, #plainGraphics.scissorIntersections
  flipped:draw()
  plain:draw()
  local flippedMain = engineScissors(flipGraphics, flipped, "main", flipBaseline)
  local plainMain = engineScissors(plainGraphics, plain, "main", plainBaseline)
  Assert.equal(#flippedMain, #plainMain, "the flip preserves the main window region count")
  for _, rect in ipairs(plainMain) do
    Assert.isTrue(
      hasScissor(flippedMain, rect[1], rect[2], rect[3], rect[4]),
      "the flip preserves every main window region"
    )
  end
  flipped:dispose()
  plain:dispose()
end

function T.failed_plane_draw_restores_scissor_state()
  local root = sceneRoot(1)
  local scenes, cacheFs = packWithSceneAt(
    compositeManifest(
      1,
      { layer(1, root .. "layers/plane.png", 256, 192, 1), layer(2, root .. "layers/other.png", 256, 192, 2) },
      { layer(0, root .. "layers/lower.png", 256, 192) },
      { spriteClip(root .. "sprites/clip0.g4sprite", { stillFrame() }) },
      { { id = "reveal", events = { 1, 2, 3, 4 }, ["until"] = { kind = "duration", ticks = 20 } } },
      {
        windowEvent("reveal", 0, "main", windowRect(255, 0, 255, 192), windowRect(0, 0, 255, 192), 10, 30, 28),
        { op = "enableSkip", stepId = "reveal", atStepTick = 10 },
        { op = "waitTicks", stepId = "reveal", atStepTick = 0, ticks = 20 },
        { op = "finish", stepId = "reveal", atStepTick = 20 },
      }
    ),
    1
  )
  local fakeOpts = {}
  local graphics = movieGraphics(fakeOpts)
  local movie = openMovie(scenes, cacheFs, graphics)
  for _ = 1, 5 do
    movie:updateFixed()
  end
  local scissor = { graphics.getScissor() }
  fakeOpts.failOnDrawCall = #graphics.draws + 2
  local ok = pcall(function()
    movie:draw()
  end)
  Assert.isFalse(ok, "a failed plane draw surfaces explicitly")
  Assert.equal(graphics.pushDepth(), 0, "a failed plane draw leaves no pushed scope behind")
  local after = { graphics.getScissor() }
  Assert.equal(#after, #scissor, "a failed plane draw restores the borrowed scissor")
  for index, value in ipairs(scissor) do
    Assert.equal(after[index], value, "a failed plane draw restores the borrowed scissor")
  end
  fakeOpts.failOnDrawCall = nil
  movie:draw()
  movie:dispose()
end

function T.hidden_planes_stay_hidden_without_leaking_across_scenes()
  local mainUpper = sceneRoot(3) .. "upper-bg.png"
  local hiddenScene = compositeManifest(3, { layer(0, mainUpper, 256, 192, 0, false) }, {
    layer(0, sceneRoot(3) .. "lower-bg.png", 256, 192),
  }, {}, {
    { id = "arrive", events = { 1 }, ["until"] = { kind = "duration", ticks = 20 } },
    { id = "hold", events = { 2, 3 }, ["until"] = { kind = "duration", ticks = 30 } },
  }, {
    { op = "waitTicks", stepId = "arrive", atStepTick = 0, ticks = 20 },
    { op = "waitTicks", stepId = "hold", atStepTick = 0, ticks = 30 },
    { op = "finish", stepId = "hold", atStepTick = 0 },
  })
  -- Scene 4 reuses the full starter-emitter program shape the strict reader
  -- requires; only its main panel visibility differs from scene 3.
  local shownScene = particleScene(
    { { id = "frame", events = { 1, 2 }, ["until"] = { kind = "duration", ticks = 20 } } },
    {
      { op = "waitTicks", stepId = "frame", atStepTick = 0, ticks = 20 },
      { op = "finish", stepId = "frame", atStepTick = 0 },
    }
  )
  local raw = {}
  for sceneNumber = 1, 5 do
    raw[sceneNumber] = manifestFor(sceneNumber)
  end
  raw[3], raw[4] = hiddenScene, shownScene
  local cacheFs = stubCache(raw)
  local scenes = {}
  for sceneNumber = 1, 5 do
    local loaded, err = StartupAssetCache.loadOpeningScene(cacheFs, sceneNumber, VERSION_ID)
    Assert.notNil(loaded, "synthetic scene " .. sceneNumber .. " passes the strict scene reader: " .. tostring(err))
    scenes[sceneNumber] = loaded
  end
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  local ticks = 0
  while movie:sceneNumber() < 3 and ticks < 5000 do
    movie:updateFixed()
    ticks = ticks + 1
  end
  Assert.equal(movie:sceneNumber(), 3, "playback reaches scene 3")
  -- Playback re-acquires each scene on entry, so the disabled panel is
  -- identified through the live slot's staged handle, never by creation
  -- order.
  local hiddenImage = movie.current.imageByPath[mainUpper]
  Assert.notNil(hiddenImage, "the disabled panel stays staged while its scene plays")
  local sceneBaseline = #graphics.draws
  for _ = 1, 10 do
    movie:updateFixed()
    movie:draw()
  end
  local leaked = engineDrawsOf(graphics, movie, "main", hiddenImage, sceneBaseline)
  Assert.equal(#leaked, 0, "the disabled scene-3 plane never paints its engine target")
  while movie:sceneNumber() < 4 and ticks < 5000 do
    movie:updateFixed()
    ticks = ticks + 1
  end
  Assert.equal(movie:sceneNumber(), 4, "playback reaches scene 4")
  local shownImage = movie.current.imageByPath[sceneRoot(4) .. "upper-bg.png"]
  Assert.notNil(shownImage, "the scene-4 panel stays staged while its scene plays")
  local nextBaseline = #graphics.draws
  movie:draw()
  local painted = engineDrawsOf(graphics, movie, "main", shownImage, nextBaseline)
  Assert.isTrue(#painted > 0, "scene 4 paints its own enabled plane")
  movie:dispose()
end

return { tests = T }