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
---@param playMode string|nil normalized NANR playback mode carried by the strict scene contract
---@param loopStartFrameIdx integer|nil zero-based loop entry frame carried by the strict scene contract
---@return table compiled sprite clip record
local function spriteClip(id, frames, playMode, loopStartFrameIdx)
  return {
    id = id,
    frameCount = #frames,
    frames = frames,
    playMode = playMode or "forward_loop",
    loopStartFrameIdx = loopStartFrameIdx or 0,
  }
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
        objPriority = 1,
        clipId = root .. "sprites/ethan.g4sprite",
        animate = true,
      },
      { op = "waitTicks", stepId = "intro", atStepTick = 0, ticks = 10 },
      { op = "startEmitters", stepId = "starters", atStepTick = 0, group = "grass", emitters = { 6, 7, 8 } },
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
    {
      op = "setFade",
      stepId = "fade",
      atStepTick = 0,
      scope = "both",
      mode = "brightness",
      color = "white",
      direction = "out",
      ticks = 15,
      terminal = "neutral",
    },
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
      { id = "starters", events = { 3 }, ["until"] = { kind = "effect", effect = "emitters-grass" } },
      { id = "outro", events = { 4, 5 }, ["until"] = { kind = "duration", ticks = 10 } },
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

---@param id integer source emitter id
---@param group string starter group owning the emitter
---@param buildEmitters (fun(id: integer, group: string): table)|nil per-emitter record builder
---@return table strict synthetic opening-scene manifest
local function manifestFor(sceneNumber, buildEmitters)
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
    initialDisplay = { mainPhysical = "upper", brightness = { main = "neutral", sub = "neutral" } },
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
    local builder = buildEmitters or testEmitter
    for id = 0, 8 do
      local group = id < 3 and "water" or (id < 6 and "fire" or "grass")
      emitters[#emitters + 1] = builder(id, group)
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

-- Advances through the retail exit call into `sceneNumber` and past its
-- init call plus entry stalls, so the next fixed update runs the scene's
-- first case.
---@param movie table opening movie
---@param sceneNumber integer scene to enter
local function enterScene(movie, sceneNumber)
  while movie:sceneNumber() < sceneNumber do
    movie:updateFixed()
  end
  local current = movie.current
  while current ~= nil and current.handoff ~= nil do
    movie:updateFixed()
    current = movie.current
  end
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
  -- Each handoff spends the retail exit call, and each later scene its
  -- init call plus three entry stalls, around the scene's authored ticks.
  Assert.equal(entries[1], 0, "scene 1 starts on the first tick")
  Assert.equal(entries[2], 90 + 1, "scene 2 starts after scene 1's authored 90 ticks and exit call")
  Assert.equal(entries[3], 91 + 4 + 40 + 1, "scene 3 starts after scene 2's init stalls, authored 40 ticks, and exit")
  Assert.equal(entries[4], 136 + 4 + 50 + 1, "scene 4 starts after scene 3's init stalls, authored 50 ticks, and exit")
  Assert.isTrue(entries[5] > entries[4] + 20, "scene 5 waits out the starter effect, never a bare timer")
  movie:dispose()
end

function T.simultaneous_events_share_one_tick_without_extra_frames_or_spins()
  local scenes, cacheFs = validPack()
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  local entries, total = playthrough(movie, graphics, 5000)
  Assert.notNil(entries[5], "scene 5 is reached")
  -- Retail src/intro_movie.c spends, after the authored beat, the scene's
  -- exit call, then the overlay's done call where IntroMovie_Main returns
  -- TRUE, then the overlay's exit call: the last scene's own ticks are the
  -- authored 53 plus its three entry stalls, and the movie finishes two
  -- calls after its exit call.
  Assert.equal(
    total - entries[5],
    4 + 53 + 1 + 2,
    "scene 5's same-tick wipe and role events cost exactly the authored 53 ticks between its init stalls and the overlay calls"
  )
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
  -- The init call plus three entry stalls, the authored 50 town ticks, then the exit call.
  for _ = 1, 4 + 50 do
    movie:updateFixed()
    movie:draw()
  end
  Assert.equal(movie:sceneNumber(), 3, "scene 3 holds its authored 50 town ticks after its init stalls")
  movie:updateFixed()
  Assert.equal(movie:sceneNumber(), 4, "scene 3 hands over on its exit call")
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
    "the continued run starts in scene two (entered at absolute 91, before the run, never rewound)"
  )
  Assert.equal(
    entries[3],
    36,
    "scene three enters 36 ticks into the continued run (absolute 136 less 100 pre-run ticks)"
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
        assets[alternate.image or alternate] = true
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
    initialDisplay = { mainPhysical = "upper", brightness = { main = "neutral", sub = "neutral" } },
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

-- A scene-five filler that stages art and finishes on a bare duration:
-- wipe and shutter isolation tests replace another scene and need a
-- fifth scene that starts no effect of its own.
---@return table strict synthetic scene-five manifest with no effect program
local function neutralSceneFive()
  local root = sceneRoot(5)
  return compositeManifest(
    5,
    { layer(0, root .. "layers/quiet-upper.png", 256, 192) },
    { layer(0, root .. "layers/quiet-lower.png", 256, 192) },
    {},
    { { id = "fill", events = { 1, 2 }, ["until"] = { kind = "duration", ticks = 10 } } },
    {
      { op = "waitTicks", stepId = "fill", atStepTick = 0, ticks = 10 },
      { op = "finish", stepId = "fill", atStepTick = 0 },
    }
  )
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
        layer(1, middleImage, 256, 192, 1),
        layer(2, topImage, 256, 192, 2),
      },
      { layer(0, groundImage, 256, 192, 0) },
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
          effect = "pan-middle",
        },
        { op = "enableSkip", stepId = "pan", atStepTick = 10 },
        { op = "waitTicks", stepId = "pan", atStepTick = 0, ticks = 40 },
        { op = "finish", stepId = "pan", atStepTick = 40 },
      }
    ),
    1
  )
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  local slotImages = {
    bottom = assert(movie.current.imageByPath[bottomImage], "the bottom layer image is staged"),
    middle = assert(movie.current.imageByPath[middleImage], "the middle layer image is staged"),
    top = assert(movie.current.imageByPath[topImage], "the top layer image is staged"),
    ground = assert(movie.current.imageByPath[groundImage], "the lower-role layer image is staged"),
  }
  for _ = 1, 12 do
    movie:updateFixed()
  end
  -- Timed pans hold absolute source displacements: each layer lands
  -- exactly on its full signed displacement, never on a divided speed.
  local current = assert(movie.current, "the running movie owns its current slot")
  Assert.equal(current.backgrounds.main[2].scrollX, -1024, "the top layer lands exactly on its full displacement")
  Assert.equal(current.backgrounds.main[1].scrollX, -512, "the middle layer pans at its own authored displacement")
  Assert.equal(current.backgrounds.main[0].scrollX, 0, "the unscrolled bottom layer stays at its source origin")
  Assert.equal(current.backgrounds.sub[0].scrollX, 0, "the sub-engine layer ignores main-engine pans")
  local frameDrawsStart = #graphics.draws + 1
  movie:draw()
  local drawOf = {}
  local layerDraws = 0
  -- The composed host frame carries the fixed role targets as canvas
  -- blits alongside the source-space layer draws, and construction
  -- preflights every scene through the same frame path: only staged
  -- layer images drawn by this frame prove the per-engine compositor.
  -- Every viewport sample draws as plain translated image copies at exact
  -- source positions under the active scissor, never as a shifted whole
  -- texture and never through a per-draw viewport quad.
  local stagedImages = {}
  for _, image in ipairs(graphics.images) do
    stagedImages[image] = true
  end
  for index = frameDrawsStart, #graphics.draws do
    local draw = graphics.draws[index]
    if stagedImages[draw.image] == true then
      layerDraws = layerDraws + 1
      drawOf[draw.image] = draw
    end
  end
  Assert.equal(layerDraws, 4, "every simultaneously live layer is drawn, never just the first")
  Assert.notNil(drawOf[slotImages.bottom], "the bottom layer is drawn")
  Assert.notNil(drawOf[slotImages.middle], "the middle layer is drawn")
  Assert.notNil(drawOf[slotImages.top], "the top layer is drawn")
  Assert.notNil(drawOf[slotImages.ground], "the lower-role layer is drawn")
  for name, image in pairs(slotImages) do
    Assert.isTrue(drawOf[image].quad == nil, "the " .. name .. " layer samples without a per-draw viewport quad")
  end
  movie:dispose()
end

-- Timed pans land on exact signed endpoints: every fixed tick holds the
-- truncated absolute share of the full displacement, the final tick lands
-- exactly on it, and later ticks retain it. Host draws never advance the
-- sampled positions.
function T.timed_pans_land_on_exact_signed_endpoints_with_truncating_steps()
  local root = sceneRoot(2)
  local scenes, cacheFs = packWithSceneAt(
    compositeManifest(
      2,
      {
        layer(0, root .. "layers/wide-a.png", 512, 512),
        layer(1, root .. "layers/wide-b.png", 512, 512),
      },
      { layer(0, root .. "layers/wide-c.png", 512, 512) },
      {},
      { { id = "pan", events = { 1, 2, 3, 4 }, ["until"] = { kind = "duration", ticks = 100 } } },
      {
        {
          op = "setScroll",
          stepId = "pan",
          atStepTick = 0,
          engine = "main",
          bgSlot = 0,
          dx = 192,
          dy = 0,
          ticks = 10,
        },
        {
          op = "setScroll",
          stepId = "pan",
          atStepTick = 0,
          engine = "main",
          bgSlot = 1,
          dx = -192,
          dy = 0,
          ticks = 5,
        },
        {
          op = "setScroll",
          stepId = "pan",
          atStepTick = 0,
          engine = "sub",
          bgSlot = 0,
          dx = 32,
          dy = 0,
          ticks = 90,
        },
        { op = "waitTicks", stepId = "pan", atStepTick = 0, ticks = 100 },
      }
    ),
    2
  )
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  enterScene(movie, 2)
  local function offsets()
    local current = assert(movie.current, "the running movie owns its current slot")
    return {
      mainA = current.backgrounds.main[0].scrollX,
      mainB = current.backgrounds.main[1].scrollX,
      sub = current.backgrounds.sub[0].scrollX,
    }
  end
  local entry = offsets()
  Assert.equal(entry.mainA, 0, "a timed pan starts at its origin")
  Assert.equal(entry.mainB, 0, "a timed pan starts at its origin")
  Assert.equal(entry.sub, 0, "a timed pan starts at its origin")
  movie:updateFixed()
  local first = offsets()
  Assert.equal(first.mainA, 19, "the first tick holds the truncated share of +192 over 10")
  Assert.equal(first.mainB, -38, "negative shares truncate toward zero, never down")
  Assert.equal(first.sub, 0, "a sub-pixel share stays at the origin")
  movie:draw()
  movie:draw()
  local redrawn = offsets()
  Assert.equal(redrawn.mainA, first.mainA, "repeated host draws never advance sampled positions")
  for _ = 1, 4 do
    movie:updateFixed()
  end
  local mid = offsets()
  Assert.equal(mid.mainA, 96, "the middle tick holds the truncated absolute interpolation")
  Assert.equal(mid.mainB, -192, "the shorter pan lands exactly on its endpoint")
  Assert.equal(mid.sub, 1, "the long pan accumulates its fractional shares")
  for _ = 1, 5 do
    movie:updateFixed()
  end
  local settled = offsets()
  Assert.equal(settled.mainA, 192, "the final tick lands exactly on the full displacement")
  Assert.equal(settled.mainB, -192, "a finished pan retains its endpoint")
  for _ = 1, 80 do
    movie:updateFixed()
  end
  local tail = offsets()
  Assert.equal(tail.mainA, 192, "later ticks retain the full displacement")
  Assert.equal(tail.mainB, -192, "later ticks retain the full displacement")
  Assert.equal(tail.sub, 32, "the long pan lands exactly on +32 at its ninetieth tick")
  for _ = 1, 5 do
    movie:updateFixed()
  end
  local held = offsets()
  Assert.equal(held.sub, 32, "ticks past the duration retain the endpoint")
  movie:dispose()
end

-- Immediate offsets land on the first frame and continuous pans advance
-- one authored step per fixed tick on independent engine clocks. Host
-- draws and resizes never resample them.
function T.immediate_offsets_land_first_and_continuous_pans_advance_per_tick()
  local root = sceneRoot(2)
  local scenes, cacheFs = packWithSceneAt(
    compositeManifest(
      2,
      {
        layer(0, root .. "layers/snap-a.png", 512, 512),
        layer(1, root .. "layers/drift-a.png", 512, 512),
      },
      { layer(0, root .. "layers/drift-b.png", 512, 512) },
      {},
      { { id = "drift", events = { 1, 2, 3, 4 }, ["until"] = { kind = "duration", ticks = 100 } } },
      {
        {
          op = "setScroll",
          stepId = "drift",
          atStepTick = 0,
          engine = "main",
          bgSlot = 0,
          dx = 128,
          dy = 64,
          ticks = 0,
        },
        {
          op = "setScroll",
          stepId = "drift",
          atStepTick = 0,
          engine = "sub",
          bgSlot = 0,
          dx = 64,
          dy = 0,
          ticks = -1,
        },
        {
          op = "setScroll",
          stepId = "drift",
          atStepTick = 0,
          engine = "main",
          bgSlot = 1,
          dx = 0,
          dy = -32,
          ticks = -1,
        },
        { op = "waitTicks", stepId = "drift", atStepTick = 0, ticks = 100 },
      }
    ),
    2
  )
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  enterScene(movie, 2)
  -- The newly entered case first runs on the following update: its entry
  -- programs dispatch there, and continuous programs advance at once.
  movie:updateFixed()
  local function offsets()
    local current = assert(movie.current, "the running movie owns its current slot")
    return {
      snapX = current.backgrounds.main[0].scrollX,
      snapY = current.backgrounds.main[0].scrollY,
      subX = current.backgrounds.sub[0].scrollX,
      driftY = current.backgrounds.main[1].scrollY,
    }
  end
  local entry = offsets()
  Assert.equal(entry.snapX, 128, "an immediate pan is already displaced on the first frame")
  Assert.equal(entry.snapY, 64, "an immediate pan is already displaced on the first frame")
  Assert.equal(entry.subX, 64, "a continuous pan advances on its dispatch update")
  Assert.equal(entry.driftY, -32, "independent slots advance on the dispatch update")
  movie:draw()
  local drawn = offsets()
  Assert.equal(drawn.snapX, 128, "the first draw keeps the immediate displacement")
  for _ = 1, 9 do
    movie:updateFixed()
    movie:draw()
  end
  local tenth = offsets()
  Assert.equal(tenth.snapX, 128, "fixed ticks never move an immediate-only pan")
  Assert.equal(tenth.snapY, 64, "fixed ticks never move an immediate-only pan")
  Assert.equal(tenth.subX, 640, "a continuous pan advances its authored step every fixed tick")
  Assert.equal(tenth.driftY, -320, "independent slots keep independent continuous clocks")
  movie:resize(600, 1000)
  movie:draw()
  local resized = offsets()
  Assert.equal(resized.subX, 640, "resizes never resample the continuous clock")
  for _ = 1, 40 do
    movie:updateFixed()
  end
  local late = offsets()
  Assert.equal(late.subX, 3200, "a continuous pan keeps its step across many ticks")
  Assert.equal(late.driftY, -1600, "a continuous pan keeps its step across many ticks")
  Assert.equal(late.snapX, 128, "the immediate pan still holds after many ticks")
  movie:dispose()
end

-- Full native extents keep the bounded preflight while the source clock
-- advances without draws: a 512-wide base swaps to a 256-wide alternate
-- mid-pan, offsets progress on fixed ticks alone, and the retained graph
-- never grows past the current and next scenes.
function T.full_native_extents_swap_atomically_and_tick_without_draws()
  local root = sceneRoot(2)
  local baseImage = root .. "layers/native-base.png"
  local altImage = root .. "layers/native-alt.png"
  local groundImage = root .. "layers/native-ground.png"
  local scenes, cacheFs = packWithSceneAt(
    compositeManifest(
      2,
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
      { layer(0, groundImage, 512, 256) },
      {},
      { { id = "pan", events = { 1, 2, 3, 4, 5 }, ["until"] = { kind = "duration", ticks = 40 } } },
      {
        {
          op = "setScroll",
          stepId = "pan",
          atStepTick = 0,
          engine = "main",
          bgSlot = 0,
          dx = 256,
          dy = 128,
          ticks = 8,
        },
        {
          op = "setScroll",
          stepId = "pan",
          atStepTick = 0,
          engine = "sub",
          bgSlot = 0,
          dx = 0,
          dy = -96,
          ticks = -1,
        },
        {
          op = "setLayer",
          stepId = "pan",
          atStepTick = 4,
          engine = "main",
          bgSlot = 0,
          image = altImage,
          visible = true,
          priority = 0,
        },
        { op = "waitTicks", stepId = "pan", atStepTick = 0, ticks = 40 },
        { op = "finish", stepId = "pan", atStepTick = 40 },
      }
    ),
    2
  )
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  -- The custom scene stages its base, alternate, and sub art plus one
  -- scene-two filler clip image; the prefetched next scene stages its
  -- two panels and the town scene stages alongside them: nothing else
  -- may stay resident after the preflight.
  Assert.equal(liveHandles(graphics), 10, "full native art still retains a bounded prefetch window")
  Assert.equal(#graphics.canvases, 2, "preflight keeps exactly two bounded role targets")
  enterScene(movie, 2)
  local function state()
    local current = assert(movie.current, "the running movie owns its current slot")
    local main = current.backgrounds.main[0]
    return {
      scrollX = main.scrollX,
      scrollY = main.scrollY,
      width = main.width,
      height = main.height,
      image = main.image,
      subY = current.backgrounds.sub[0].scrollY,
    }
  end
  local entry = state()
  Assert.equal(entry.width, 512, "the base image stages with its native extent")
  Assert.equal(entry.height, 512, "the base image stages with its native extent")
  Assert.equal(entry.image, baseImage, "the base image samples before its swap tick")
  -- No draws between fixed ticks: the source clock alone resamples.
  for _ = 1, 3 do
    movie:updateFixed()
  end
  local third = state()
  Assert.equal(third.scrollX, 96, "zero-draw ticks hold the truncated absolute share")
  Assert.equal(third.scrollY, 48, "zero-draw ticks hold the truncated absolute share")
  Assert.equal(third.subY, -288, "the sub-engine drift advances without draws")
  Assert.equal(third.image, baseImage, "the swap stays off before its step tick")
  movie:updateFixed()
  local swapped = state()
  Assert.equal(swapped.image, altImage, "the swap lands on its authored tick")
  Assert.equal(swapped.width, 256, "the sampled extent follows the newly selected image")
  Assert.equal(swapped.height, 192, "the sampled extent follows the newly selected image")
  Assert.equal(swapped.scrollX, 128, "the pan keeps its absolute course across the swap")
  local drawsBefore = #graphics.draws
  movie:draw()
  movie:draw()
  movie:draw()
  Assert.equal(state().scrollX, 128, "repeated host draws never resample the clock")
  movie:resize(600, 1000)
  movie:draw()
  Assert.equal(state().scrollX, 128, "resizes never resample the clock")
  local altHandle = assert(movie.current.imageByPath[altImage], "the alternate image is staged")
  local sampled = false
  for index = drawsBefore + 1, #graphics.draws do
    local draw = graphics.draws[index]
    if draw.image == altHandle then
      sampled = true
      Assert.isTrue(draw.quad == nil, "the swapped viewport still samples without a per-draw quad")
    end
  end
  Assert.isTrue(sampled, "the swapped alternate image draws after its tick")
  movie:dispose()
  Assert.equal(liveHandles(graphics), 0, "disposing the native movie releases every handle")
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
      objPriority = 1,
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
  })
end

---@param graphics table fake graphics namespace
---@param clipImage table staged sprite clip image handle
---@param baseline integer only draws after this draw index
---@return table[] draws of the sprite clip image
local function spriteDraws(graphics, clipImage, baseline)
  local found = {}
  for index = (baseline or 0) + 1, #graphics.draws do
    -- Background viewports paint without per-draw quads, so sprite
    -- draws are told apart by their staged clip image, never by the
    -- presence of a quad.
    if graphics.draws[index].image == clipImage then
      found[#found + 1] = graphics.draws[index]
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
  local firstClip =
    assert(first.current.imageByPath[sceneRoot(1) .. "sprites/hero.g4sprite"], "the hero clip image is staged")
  local secondClip =
    assert(second.current.imageByPath[sceneRoot(1) .. "sprites/hero.g4sprite"], "the hero clip image is staged")
  for _ = 1, 4 do
    first:updateFixed()
    second:updateFixed()
  end
  -- Four source ticks at double speed reach the offset frame (entered
  -- at six units of the 6+6 pair and latched for the fourth draw);
  -- sampling later would wrap back to the reset cell and hide the
  -- authored offsets.
  -- Construction preflights every scene through the same frame path,
  -- so only draws issued after the opener count toward the per-frame
  -- proof.
  local firstBaseline, secondBaseline = #firstGraphics.draws, #secondGraphics.draws
  first:draw()
  second:draw()
  local firstSprites = spriteDraws(firstGraphics, firstClip, firstBaseline)
  local secondSprites = spriteDraws(secondGraphics, secondClip, secondBaseline)
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
  enterScene(movie, 2)
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
        }, "forward", 0),
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
          objPriority = 1,
          clipId = sparkleClip,
          animate = true,
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
  -- The one-shot sparkle sums to 6 + 6 + 8 units and the controller
  -- advances two units per source tick, so the finale step runs ten
  -- ticks and completes on the tenth; a looping clip would never
  -- complete this effect wait.
  local scenes, cacheFs = packWithSceneAt(sparkleScene(sparkleClip), 1)
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  for _ = 1, 10 do
    movie:updateFixed()
  end
  Assert.equal(movie:sceneNumber(), 1, "the setup step hands over to the clip finale")
  for _ = 1, 9 do
    movie:updateFixed()
  end
  Assert.equal(movie:sceneNumber(), 1, "the finale holds for the nine ticks before the summed duration")
  movie:updateFixed()
  Assert.equal(movie:sceneNumber(), 1, "the finale's completing tick leaves the exit call to the next tick")
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
  rawMovie:updateFixed()
  Assert.equal(rawMovie:sceneNumber(), 1, "the tenth tick selects the gated finale without firing it")
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

function T.scene_handoff_spends_the_retail_exit_and_init_calls()
  -- Retail src/intro_movie.c dispatches one scene call per frame: after the
  -- run case completes, the scene's exit call returns TRUE, the next scene
  -- spends its init call plus three entry stalls, and only the following
  -- call runs its first case.
  local scenes, cacheFs = validPack()
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  for _ = 1, 90 do
    movie:updateFixed()
  end
  Assert.equal(movie:sceneNumber(), 1, "the completing case leaves the exit call to the next tick")
  movie:updateFixed()
  Assert.equal(movie:sceneNumber(), 2, "the exit call hands over to the next scene")
  local background = function()
    return movie.current.backgrounds.main[0]
  end
  for _ = 1, 4 do
    movie:updateFixed()
    Assert.equal(background().scrollX, 0, "the init stalls stage the scene without running its first case")
  end
  movie:updateFixed()
  Assert.equal(background().scrollX, -10, "the first case runs on the call after the init stalls")
  movie:dispose()
end

function T.palette_fade_waits_complete_after_the_fade_cleanup_call()
  -- A palette fade's last step lands on its final update; the next update
  -- runs the fade cleanup that clears the active flag, and the scene sees
  -- IsPaletteFadeFinished on the call after that.
  local root = sceneRoot(1)
  local FADE_TICKS = 5
  local fading = compositeManifest(
    1,
    { layer(0, root .. "layers/sunrise.png", 256, 192) },
    { layer(0, root .. "layers/lower.png", 256, 192) },
    {},
    { { id = "fade", events = { 1, 2 }, ["until"] = { kind = "effect", effect = "fade-white" }, onCompleteEvents = { 3 } } },
    {
      {
        op = "setFade",
        stepId = "fade",
        atStepTick = 0,
        scope = "both",
        mode = "brightness",
        color = "white",
        direction = "out",
        ticks = FADE_TICKS,
        terminal = "neutral",
        effect = "fade-white",
      },
      { op = "enableSkip", stepId = "fade", atStepTick = 1 },
      { op = "finish", stepId = "fade", atStepTick = 0 },
    }
  )
  local scenes, cacheFs = packWithSceneAt(fading, 1)
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  -- The authored fade steps, then the cleanup call that clears the active
  -- flag and the poll call that finally reports the fade finished.
  for _ = 1, FADE_TICKS + 2 do
    movie:updateFixed()
  end
  Assert.equal(movie:sceneNumber(), 1, "the wait sees the finished fade only after its cleanup call")
  movie:updateFixed()
  Assert.equal(movie:sceneNumber(), 2, "the exit call follows the detected fade")
  movie:dispose()
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
          variants = {
            { image = firstImage, width = 256, height = 192 },
            { image = secondImage, width = 256, height = 192 },
          },
          width = 256,
          height = 192,
          sourceHash = string.rep("c", 40),
          initialVisible = true,
        },
      },
      { layer(0, root .. "layers/lower.png", 256, 192) },
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
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  local baseHandle = assert(movie.current.imageByPath[baseImage], "the base image is staged")
  local firstHandle = assert(movie.current.imageByPath[firstImage], "the first swap image is staged")
  local secondHandle = assert(movie.current.imageByPath[secondImage], "the second swap image is staged")
  for _ = 1, 2 do
    movie:updateFixed()
  end
  movie:draw()
  local earlySeen = {}
  for _, draw in ipairs(graphics.draws) do
    earlySeen[draw.image] = true
  end
  Assert.isTrue(earlySeen[baseHandle], "the base image draws before either same-tick swap fires")
  Assert.isNil(earlySeen[firstHandle], "the first swap stays off before its step tick")
  movie:updateFixed()
  movie:draw()
  local lateSeen = {}
  for _, draw in ipairs(graphics.draws) do
    lateSeen[draw.image] = true
  end
  Assert.isTrue(lateSeen[secondHandle], "same-tick swaps apply in listed order with the later event winning")
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
        {
          op = "setBlend",
          stepId = "hold",
          atStepTick = 0,
          engine = "main",
          firstMask = 1,
          secondMask = 2,
          direction = 0,
          effect = "pulse",
          ticks = 6,
        },
        {
          op = "setBlend",
          stepId = "hold",
          atStepTick = 4,
          engine = "main",
          firstMask = 1,
          secondMask = 2,
          direction = 0,
          effect = "pulse",
          ticks = 6,
        },
        { op = "waitTicks", stepId = "tail", atStepTick = 0, ticks = 5 },
        { op = "finish", stepId = "tail", atStepTick = 0 },
      }
    ),
    2
  )
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  enterScene(movie, 2)
  Assert.equal(movie:sceneNumber(), 2, "playback reaches the rebound effect step")
  for _ = 1, 6 do
    movie:updateFixed()
  end
  Assert.equal(movie:sceneNumber(), 2, "the first start alone never completes the rebound wait")
  for _ = 1, 5 do
    movie:updateFixed()
  end
  Assert.equal(movie:sceneNumber(), 2, "the rebound wait ends on the latest start with its tail step")
  for _ = 1, 5 + 1 do
    movie:updateFixed()
  end
  Assert.equal(movie:sceneNumber(), 3, "the tail step still costs its authored duration before the exit call")
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
    initialDisplay = { mainPhysical = "upper", brightness = { main = "neutral", sub = "neutral" } },
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
  -- Scene one's authored 90 ticks, then its exit call.
  for _ = 1, 90 + 1 do
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
  -- The first scene owns its two staged images plus one clip image, the
  -- prefetched second scene owns its two staged images, and the town
  -- scene stages alongside them so the first handoff never blocks
  -- mid-movie: nothing else may stay resident after the sequential
  -- preflight releases its transients.
  Assert.equal(liveHandles(graphics), 9, "construction retains the current, next, and town scene graphs")
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
  -- The town scene stages last and stays resident so its 3D build never
  -- blocks the first handoff mid-movie; the lighter panoramas still
  -- preflight as transients in between.
  for index, sceneNumber in ipairs({ 1, 2, 4, 5, 3 }) do
    Assert.equal(rendered[index], sceneNumber, "preflight renders every scene without overlap")
  end
  Assert.equal(movie:sceneNumber(), 1, "preflight consumes no source time")
  Assert.isFalse(movie:skipAllowed(), "preflight leaves the skip gate closed")
  Assert.equal(liveHandles(graphics), 9, "preflight retains the current, next, and town scene graphs")
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
        {
          op = "setFade",
          stepId = "hold",
          atStepTick = 5,
          scope = "both",
          mode = "brightness",
          color = "white",
          direction = "out",
          ticks = 4,
          terminal = "neutral",
          effect = "late-fade",
        },
        { op = "waitTicks", stepId = "tail", atStepTick = 0, ticks = 5 },
        { op = "finish", stepId = "tail", atStepTick = 0 },
      }
    ),
    2
  )
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  enterScene(movie, 2)
  Assert.equal(movie:sceneNumber(), 2, "playback reaches the late-start step")
  for _ = 1, 4 do
    movie:updateFixed()
  end
  Assert.equal(movie:sceneNumber(), 2, "the step holds without completing before its effect starts")
  for _ = 1, 4 do
    movie:updateFixed()
  end
  Assert.equal(movie:sceneNumber(), 2, "the started effect runs its authored ticks")
  for _ = 1, 2 do
    movie:updateFixed()
  end
  Assert.equal(movie:sceneNumber(), 2, "the fade wait trails its last step by the cleanup and poll calls")
  movie:updateFixed()
  Assert.equal(movie:sceneNumber(), 2, "the effect completion hands over to the tail step")
  for _ = 1, 5 + 1 do
    movie:updateFixed()
  end
  Assert.equal(movie:sceneNumber(), 3, "the tail step still costs its authored duration before the exit call")
  movie:dispose()
end

-- Engine-compositor behavior fixtures: per-engine plane visibility and
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

-- Blend-active engines rasterize each plane into the transparent compositor
-- scratch (movie.planeCanvas) under their window clip instead of painting
-- the role target directly; the dual-coefficient shaders then resolve the
-- per-pixel pair. Structural blend assertions therefore follow the planes
-- into the scratch with native colors plus the eva/evb/firstMask/secondMask
-- uniforms, while pixel correctness stays with the graphics readback tests.
---@param graphics table fake graphics namespace
---@param movie table player owning the compositor scratch
---@param image table staged plane image
---@param baseline integer only draws after this index
---@return table[] scratch draws of the staged plane image
local function compositorDrawsOf(graphics, movie, image, baseline)
  local target = assert(movie.planeCanvas, "the blend movie owns its raster scratch")
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
---@param movie table player owning the compositor scratch
---@param baseline integer only scissor records after this index
---@return table[] requested scissor rects on the compositor scratch
local function compositorScissors(graphics, movie, baseline)
  local target = assert(movie.planeCanvas, "the blend movie owns its raster scratch")
  local found = {}
  for index = (baseline or 0) + 1, #graphics.scissorIntersections do
    local entry = graphics.scissorIntersections[index]
    if graphics.scissorCanvases[index].canvas == target then
      found[#found + 1] = entry.requested
    end
  end
  return found
end

---@param graphics table fake graphics namespace
---@param name string shader uniform name
---@return unknown[] every value sent under that name, in send order
local function uniformSends(graphics, name)
  local found = {}
  for _, shader in ipairs(graphics.shaders) do
    for _, send in ipairs(shader.sends) do
      if send.name == name then
        found[#found + 1] = send.value
      end
    end
  end
  return found
end

---@param graphics table fake graphics namespace
---@param name string shader uniform name
---@param skip integer only sends after this many recorded values
---@return unknown[] values sent under that name after the skip point
local function uniformSendsSince(graphics, name, skip)
  local all = uniformSends(graphics, name)
  local found = {}
  for index = (skip or 0) + 1, #all do
    found[#found + 1] = all[index]
  end
  return found
end

---@param draws table[] scratch draws to check
---@param label string plane label for diagnostics
local function assertNativeScratchDraws(draws, label)
  Assert.isTrue(#draws > 0, "the " .. label .. " plane paints into the compositor scratch")
  for _, draw in ipairs(draws) do
    Assert.equal(draw.color[1], 1, "the " .. label .. " plane keeps its native red")
    Assert.equal(draw.color[2], 1, "the " .. label .. " plane keeps its native green")
    Assert.equal(draw.color[3], 1, "the " .. label .. " plane keeps its native blue")
    Assert.equal(draw.color[4], 1, "the " .. label .. " plane carries no global alpha")
  end
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
    initialDisplay = { mainPhysical = "upper", brightness = { main = "neutral", sub = "neutral" } },
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
    initialDisplay = { mainPhysical = "upper", brightness = { main = "neutral", sub = "neutral" } },
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
        layer(0, frontImage, 256, 192, 0),
        layer(1, middleImage, 256, 192, 1),
        layer(3, hiddenImage, 256, 192, 3, false),
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
  -- Planes are told apart by their staged image handles: every fixture
  -- image claims the same valid source extent, so widths cannot tag them.
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  local handles = {
    back = assert(movie.current.imageByPath[backImage], "the back plane image is staged"),
    front = assert(movie.current.imageByPath[frontImage], "the front plane image is staged"),
    middle = assert(movie.current.imageByPath[middleImage], "the middle plane image is staged"),
    hidden = assert(movie.current.imageByPath[hiddenImage], "the hidden plane image is staged"),
  }
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
      if draw.image == handles.back or draw.image == handles.middle or draw.image == handles.front then
        order[#order + 1] = draw.image
      elseif draw.image == handles.hidden then
        hiddenDrawn = true
      end
    end
  end
  Assert.equal(#order, 3, "every visible main plane paints exactly once")
  Assert.equal(order[1], handles.back, "numeric priority 2 paints first (backmost)")
  Assert.equal(order[2], handles.middle, "numeric priority 1 paints next")
  Assert.equal(order[3], handles.front, "numeric priority 0 paints last (frontmost)")
  Assert.isFalse(hiddenDrawn, "the disabled slot contributes no pixels despite its staged image")
  for _ = 1, 4 do
    movie:updateFixed()
  end
  local revealBaseline = #graphics.draws
  movie:draw()
  local revealed = false
  for index = revealBaseline + 1, #graphics.draws do
    local draw = graphics.draws[index]
    if graphics.drawCanvases[index].canvas == movie.mainCanvas and draw.image == handles.hidden then
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
    -- The clip fires mid-step: handoff stages every tick-zero program
    -- before the first frame, and the fake host cannot feed the real
    -- town renderer, so the town stays off until its authored tick
    -- exactly like the stop below stays off after its.
    { op = "setModelClip", stepId = "arrive", atStepTick = 10, model = "town-0", clip = "arrive-pose" },
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
  for _ = 1, 4 do
    movie:updateFixed()
    Assert.isFalse(movie.current.townVisible, "the init stalls stage the town scene without running its clip")
  end
  -- The town beat runs silently: drawing it would composite staged town
  -- meshes the fake host cannot texture. Scene 3 holds 20 arrive ticks
  -- after its init call and stops its town at the eleventh hold tick, so
  -- 31 silent ticks land just past the authored stop.
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

-- The first scene opens on the copyright pair: each engine stages only
-- its BG0 notice, and the single-screen stage shows the upper (sub)
-- notice, never the lower (main) one, until the GameFreak setup retires it.
function T.copyright_beat_shows_the_upper_notice_on_a_single_screen()
  local scenes, cacheFs = validPack()
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  Assert.equal(movie:sceneNumber(), 1, "playback starts on the copyright beat")
  local current = assert(movie.current, "the running movie owns its current slot")
  Assert.isTrue(current.backgrounds.main[0].visible, "the copyright stages the lower notice")
  Assert.isTrue(current.backgrounds.sub[0].visible, "the copyright stages the upper notice")
  local baseline = #graphics.draws
  movie:draw()
  local mainDraws, subDraws = 0, 0
  for index = baseline + 1, #graphics.draws do
    local draw = graphics.draws[index]
    if draw.image == movie.mainCanvas then
      mainDraws = mainDraws + 1
    elseif draw.image == movie.subCanvas then
      subDraws = subDraws + 1
    end
  end
  Assert.equal(mainDraws, 0, "the copyright beat never fills the single-screen stage from the lower target")
  Assert.isTrue(subDraws > 0, "the copyright beat fills the single-screen stage from the upper target")
  movie:dispose()
end

-- A staged physical hold covers only the fitted source image on a
-- letterboxed stage: the scene-2 entry whites the central 4:3 picture
-- while the side bars stay black.
function T.physical_holds_cover_only_the_fitted_image_on_a_wide_stage()
  local raw = {}
  for sceneNumber = 1, 5 do
    raw[sceneNumber] = manifestFor(sceneNumber)
  end
  raw[1].initialDisplay = { mainPhysical = "upper", brightness = { main = "white", sub = "white" } }
  local cacheFs = stubCache(raw)
  local scenes = {}
  for sceneNumber = 1, 5 do
    local loaded, err = StartupAssetCache.loadOpeningScene(cacheFs, sceneNumber, VERSION_ID)
    Assert.notNil(loaded, "synthetic scene " .. sceneNumber .. " passes the strict scene reader: " .. tostring(err))
    scenes[sceneNumber] = loaded
  end
  local stageWidth, stageHeight = 1200, 600
  local graphics = movieGraphics()
  local movie = openMovieSized(scenes, cacheFs, graphics, stageWidth, stageHeight)
  movie:draw()
  local whiteFills = {}
  for _, rectangle in ipairs(graphics.rectangles) do
    local color = rectangle.color
    if color[1] == 1 and color[2] == 1 and color[3] == 1 and color[4] == 1 then
      whiteFills[#whiteFills + 1] = rectangle
    end
  end
  Assert.equal(#whiteFills, 1, "the staged white hold paints exactly one pane fill")
  local fill = whiteFills[1]
  -- A 4:3 source on a 2:1 stage letterboxes horizontally: the hold keeps
  -- the source shape, spans the full height, and stays centered instead of
  -- flashing the whole stage.
  Assert.near(fill.w / fill.h, 256 / 192, 1e-9, "the white hold keeps the source image shape")
  Assert.near(fill.h, stageHeight, 1e-9, "the white hold spans the fitted image height")
  Assert.isTrue(fill.w < stageWidth, "the white hold stops at the fitted image edge, never the stage edge")
  Assert.near(fill.x, (stageWidth - fill.w) / 2, 1e-9, "the white hold centers on the fitted image column")
  Assert.near(fill.y, (stageHeight - fill.h) / 2, 1e-9, "the white hold centers on the fitted image row")
  movie:dispose()
end

---@param graphics table fake graphics namespace carrying the recorded draws
---@param movie table running opening movie owning the role targets
---@return table[] role-target blits in draw order
local function roleBlits(graphics, movie)
  local blits = {}
  for _, draw in ipairs(graphics.draws) do
    if draw.image == movie.mainCanvas or draw.image == movie.subCanvas then
      blits[#blits + 1] = draw
    end
  end
  return blits
end

-- The two paired single-screen beats compose differently: the scene-4
-- hero bands stack vertically with their black surroundings overlapped, so
-- they sit closer than two full frames, while a single stage shows only the
-- scene-5 panorama's bottom-screen image. Both are checked on one
-- playthrough so the pack and the seek are amortized.
function T.paired_beats_stack_the_hero_bands_and_show_only_the_panorama_bottom_screen_on_a_wide_stage()
  local scenes, cacheFs = validPack()
  local stageWidth, stageHeight = 1200, 600
  local graphics = movieGraphics()
  local movie = openMovieSized(scenes, cacheFs, graphics, stageWidth, stageHeight)

  enterScene(movie, 4)
  movie:draw()
  local heroBlits = roleBlits(graphics, movie)
  Assert.equal(#heroBlits, 2, "the hero scene blits both role targets")
  local upper, lower = heroBlits[1], heroBlits[2]
  Assert.near(upper.x, lower.x, 1e-6, "the hero stack centers both bands on the same column")
  Assert.near(upper.sx, lower.sx, 1e-9, "the hero stack scales both bands together")
  -- The overlap equals the black surroundings each portrait carries, so the
  -- shared band shows one black margin instead of two stacked margins.
  local overlap = (upper.y + 192 * upper.sy) - lower.y
  Assert.near(overlap, 52 * upper.sy, 1e-6, "the hero stack overlaps by one band height")
  Assert.isTrue(overlap > 0, "the hero bands sit closer than two full frames")

  enterScene(movie, 5)
  local before = #graphics.draws
  movie:draw()
  local panoramaBlits = {}
  for index = before + 1, #graphics.draws do
    local draw = graphics.draws[index]
    if draw.image == movie.mainCanvas or draw.image == movie.subCanvas then
      panoramaBlits[#panoramaBlits + 1] = draw
    end
  end
  Assert.equal(#panoramaBlits, 1, "the wide panorama shows its bottom-screen image alone")
  local bottom = panoramaBlits[1]
  Assert.equal(bottom.image, movie.subCanvas, "the panorama's bottom screen owns the stage")
  -- The single remaining image keeps the source 4:3 shape fitted to the
  -- stage height and centered on the wide stage.
  Assert.near(bottom.y, 0, 1e-6, "the panorama image fills the stage height")
  Assert.near(bottom.sx, stageHeight / 192, 1e-9, "the panorama image scales to the stage height")
  Assert.near(bottom.x, (stageWidth - 256 * bottom.sx) / 2, 1e-6, "the panorama image centers on the stage")
  movie:dispose()
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
      { layer(1, mainBg1, 256, 192, 1), layer(2, mainBg2, 256, 192, 2) },
      { layer(1, subBg1, 256, 192, 1), layer(2, subBg2, 256, 192, 2) },
      {
        spriteClip(heroMain, { stillFrame() }),
        spriteClip(heroSub, { stillFrame() }),
      },
      {
        {
          id = "reveal",
          events = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 },
          ["until"] = { kind = "duration", ticks = 20 },
        },
      },
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
          objPriority = 1,
          clipId = heroMain,
          animate = true,
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
          objPriority = 1,
          clipId = heroSub,
          animate = true,
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
  -- Staged image handles tell the engine slots apart; every fixture
  -- image claims the same valid source extent, so widths cannot tag them.
  local flipScenes, flipCache = packWithSceneAt(opposingScene("lower"), 1)
  local flipGraphics = movieGraphics()
  local flipped = openMovie(flipScenes, flipCache, flipGraphics)
  local plainScenes, plainCache = packWithSceneAt(opposingScene("upper"), 1)
  local plainGraphics = movieGraphics()
  local plain = openMovie(plainScenes, plainCache, plainGraphics)
  local flipHandles = {
    mainBg1 = assert(flipped.current.imageByPath[mainBg1], "the main BG1 image is staged"),
    mainBg2 = assert(flipped.current.imageByPath[mainBg2], "the main BG2 image is staged"),
    subBg1 = assert(flipped.current.imageByPath[subBg1], "the sub BG1 image is staged"),
    subBg2 = assert(flipped.current.imageByPath[subBg2], "the sub BG2 image is staged"),
  }
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
  Assert.equal(mainDraws[1].image, flipHandles.mainBg2, "main BG2 paints first (backmost)")
  Assert.equal(mainDraws[2].image, flipHandles.mainBg1, "main BG1 paints next")
  Assert.notNil(mainDraws[3].quad, "the main sprite paints through its authored clip")
  Assert.equal(#mainScissors, 3, "every main plane draws under its own clip")
  Assert.isTrue(hasScissor({ mainScissors[1] }, 0, 0, 256, 192), "main BG2 paints the whole target")
  Assert.isTrue(
    hasScissor({ mainScissors[2] }, 128, 0, 127, 192),
    "main BG1 paints only its inside band from the authored right edge"
  )
  Assert.isTrue(hasScissor({ mainScissors[3] }, 0, 0, 256, 192), "main OBJ paints wherever the mask allows")
  local subDraws, subScissors = engineFrame(flipGraphics, flipped, "sub", flipBaseline, flipScissorBaseline)
  Assert.equal(#subDraws, 3, "sub BG2, BG1, and its sprite each paint once")
  Assert.equal(subDraws[1].image, flipHandles.subBg2, "sub BG2 paints first (backmost)")
  Assert.equal(subDraws[2].image, flipHandles.subBg1, "sub BG1 paints next")
  Assert.notNil(subDraws[3].quad, "the sub sprite paints through its authored clip")
  Assert.equal(#subScissors, 3, "every sub plane draws under its own clip")
  Assert.isTrue(hasScissor({ subScissors[1] }, 0, 0, 256, 192), "sub BG2 paints the whole target")
  Assert.isTrue(
    hasScissor({ subScissors[2] }, 0, 0, 127, 192),
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
  -- The manual second-register override carries only the OBJ bit, so BG1
  -- keeps the wrapped first window's full-height band and only the edge
  -- column stays cut.
  for _ = 1, 8 do
    flipped:updateFixed()
  end
  local overrideBaseline = #flipGraphics.scissorIntersections
  flipped:draw()
  local overrideScissors = engineScissors(flipGraphics, flipped, "main", overrideBaseline)
  Assert.isTrue(
    hasScissor(overrideScissors, 1, 64, 255, 64),
    "the manual second-register override keeps the wrapped first-window band row"
  )
  flipped:dispose()
  plain:dispose()
end

function T.starter_particles_draw_only_on_main_through_flips()
  local scenes, cacheFs = packWithSceneAt(
    particleScene({
      { id = "intro", events = { 1 }, ["until"] = { kind = "duration", ticks = 10 } },
      { id = "starters", events = { 2, 3 }, ["until"] = { kind = "effect", effect = "emitters-grass" } },
      { id = "outro", events = { 4, 5, 6 }, ["until"] = { kind = "duration", ticks = 10 } },
    }, {
      { op = "waitTicks", stepId = "intro", atStepTick = 0, ticks = 10 },
      { op = "startEmitters", stepId = "starters", atStepTick = 0, group = "grass", emitters = { 6, 7, 8 } },
      { op = "setScreenMapping", stepId = "starters", atStepTick = 5, mainPhysical = "lower" },
      { op = "setScreenMapping", stepId = "outro", atStepTick = 2, mainPhysical = "upper" },
      { op = "waitTicks", stepId = "outro", atStepTick = 0, ticks = 10 },
      { op = "finish", stepId = "outro", atStepTick = 0 },
    }),
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
        windowEvent(
          "sweep",
          0,
          "main",
          windowRect(200, 0, 255, 100),
          windowRect(50, 0, 255, 100),
          7,
          31,
          0,
          "win-sweep"
        ),
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
  Assert.isTrue(hasScissor(sweepScissors, 136, 0, 119, 100), "negative window edges truncate toward zero")
  -- A zero-duration assignment lands on its target rectangle immediately.
  for _ = 1, 3 do
    movie:updateFixed()
  end
  local snapBaseline = #graphics.scissorIntersections
  movie:draw()
  local snapScissors = engineScissors(graphics, movie, "main", snapBaseline)
  Assert.isTrue(hasScissor(snapScissors, 10, 10, 10, 10), "a zero-tick window applies its target at once")
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

-- A full-width source assignment addresses two hardware registers: the
-- second window keeps only its single edge column while the first window
-- wraps around it, so each plane clips to its own register instead of an
-- even half-screen split.
function T.full_width_window_registers_isolate_a_single_column_second_window()
  local root = sceneRoot(1)
  local frontImage = root .. "layers/full-front.png"
  local backImage = root .. "layers/full-back.png"
  local scenes, cacheFs = packWithSceneAt(
    compositeManifest(
      1,
      { layer(0, frontImage, 256, 192, 0), layer(1, backImage, 256, 192, 1) },
      { layer(0, root .. "layers/full-lower.png", 256, 192) },
      { spriteClip(root .. "sprites/clip0.g4sprite", { stillFrame() }) },
      { { id = "reveal", events = { 1, 2, 3, 4, 5 }, ["until"] = { kind = "duration", ticks = 20 } } },
      {
        windowEvent("reveal", 0, "main", windowRect(0, 0, 255, 192), windowRect(0, 0, 255, 192), 0, 1, 2),
        {
          op = "setWindowSecondary",
          stepId = "reveal",
          atStepTick = 0,
          engine = "main",
          rect = windowRect(0, 0, 64, 192),
          insideMask = 2,
        },
        { op = "enableSkip", stepId = "reveal", atStepTick = 10 },
        { op = "waitTicks", stepId = "reveal", atStepTick = 0, ticks = 20 },
        { op = "finish", stepId = "reveal", atStepTick = 20 },
      }
    ),
    1
  )
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  for _ = 1, 2 do
    movie:updateFixed()
  end
  local baseline = #graphics.scissorIntersections
  movie:draw()
  local scissors = engineScissors(graphics, movie, "main", baseline)
  -- The first window owns every column except the edge one, so the front
  -- plane paints [1,256) while the second-window plane keeps only x=0:
  -- the overlapped columns follow the first window, never the override.
  Assert.isTrue(
    hasScissor(scissors, 1, 0, 255, 192),
    "the wrapped first window paints every column past the edge pixel"
  )
  Assert.isTrue(
    hasScissor(scissors, 0, 0, 1, 192),
    "the second window keeps only its single edge column"
  )
  movie:dispose()
end

-- A rectangle whose start edge lies past its end edge wraps across the
-- right screen edge instead of vanishing: both disjoint spans clip.
function T.wrapped_window_rectangles_split_across_the_screen_edge()
  local root = sceneRoot(1)
  local planeImage = root .. "layers/wrap-plane.png"
  local scenes, cacheFs = packWithSceneAt(
    compositeManifest(
      1,
      { layer(1, planeImage, 256, 192, 1) },
      { layer(0, root .. "layers/wrap-lower.png", 256, 192) },
      { spriteClip(root .. "sprites/clip0.g4sprite", { stillFrame() }) },
      { { id = "hold", events = { 1, 2, 3, 4 }, ["until"] = { kind = "duration", ticks = 20 } } },
      {
        windowEvent("hold", 0, "main", windowRect(200, 0, 50, 192), windowRect(200, 0, 50, 192), 0, 3, 0),
        { op = "enableSkip", stepId = "hold", atStepTick = 10 },
        { op = "waitTicks", stepId = "hold", atStepTick = 0, ticks = 20 },
        { op = "finish", stepId = "hold", atStepTick = 20 },
      }
    ),
    1
  )
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  for _ = 1, 2 do
    movie:updateFixed()
  end
  local baseline = #graphics.scissorIntersections
  movie:draw()
  local scissors = engineScissors(graphics, movie, "main", baseline)
  Assert.isTrue(
    hasScissor(scissors, 200, 0, 56, 192),
    "the wrapped window paints its tail past the right edge"
  )
  Assert.isTrue(
    hasScissor(scissors, 0, 0, 50, 192),
    "the wrapped window paints its head from the left edge"
  )
  movie:dispose()
end

-- A first-window-only visibility mask retires the stale second register:
-- planes the hidden window would admit follow the outside mask instead,
-- matching the retail second-window disable after the scene-3 narrow pan.
function T.first_window_only_visibility_ignores_the_stale_second_register()
  local root = sceneRoot(1)
  local frontImage = root .. "layers/mask-front.png"
  local backImage = root .. "layers/mask-back.png"
  local scenes, cacheFs = packWithSceneAt(
    compositeManifest(
      1,
      { layer(0, frontImage, 256, 192, 0), layer(1, backImage, 256, 192, 1) },
      { layer(0, root .. "layers/mask-lower.png", 256, 192) },
      { spriteClip(root .. "sprites/clip0.g4sprite", { stillFrame() }) },
      { { id = "reveal", events = { 1, 2, 3, 4, 5, 6 }, ["until"] = { kind = "duration", ticks = 20 } } },
      {
        windowEvent("reveal", 0, "main", windowRect(70, 0, 185, 192), windowRect(70, 0, 185, 192), 0, 3, 0),
        {
          op = "setWindowSecondary",
          stepId = "reveal",
          atStepTick = 0,
          engine = "main",
          rect = windowRect(0, 0, 64, 192),
          insideMask = 2,
        },
        {
          op = "setWindowVisible",
          stepId = "reveal",
          atStepTick = 0,
          engine = "main",
          mask = 1,
        },
        { op = "enableSkip", stepId = "reveal", atStepTick = 10 },
        { op = "waitTicks", stepId = "reveal", atStepTick = 0, ticks = 20 },
        { op = "finish", stepId = "reveal", atStepTick = 20 },
      }
    ),
    1
  )
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  for _ = 1, 2 do
    movie:updateFixed()
  end
  local baseline = #graphics.scissorIntersections
  movie:draw()
  local scissors = engineScissors(graphics, movie, "main", baseline)
  Assert.isTrue(
    hasScissor(scissors, 70, 0, 115, 192),
    "both planes paint the visible first window"
  )
  Assert.isFalse(
    hasScissor(scissors, 0, 0, 64, 192),
    "the hidden second register clips no plane"
  )
  movie:dispose()
end

-- A zero-width rectangle covers no pixel: with clipping enabled and an
-- outside mask that forbids the plane, nothing paints instead of falling
-- back to one unrestricted full-target draw.
function T.empty_window_rectangles_paint_nothing_under_clipping()
  local root = sceneRoot(1)
  local planeImage = root .. "layers/empty-plane.png"
  local scenes, cacheFs = packWithSceneAt(
    compositeManifest(
      1,
      { layer(1, planeImage, 256, 192, 1) },
      { layer(0, root .. "layers/empty-lower.png", 256, 192) },
      { spriteClip(root .. "sprites/clip0.g4sprite", { stillFrame() }) },
      { { id = "hold", events = { 1, 2, 3, 4 }, ["until"] = { kind = "duration", ticks = 20 } } },
      {
        windowEvent("hold", 0, "main", windowRect(10, 0, 10, 192), windowRect(10, 0, 10, 192), 0, 31, 0),
        { op = "enableSkip", stepId = "hold", atStepTick = 10 },
        { op = "waitTicks", stepId = "hold", atStepTick = 0, ticks = 20 },
        { op = "finish", stepId = "hold", atStepTick = 20 },
      }
    ),
    1
  )
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  for _ = 1, 2 do
    movie:updateFixed()
  end
  local baseline = #graphics.scissorIntersections
  movie:draw()
  local scissors = engineScissors(graphics, movie, "main", baseline)
  Assert.equal(#scissors, 0, "a zero-width window clips its plane away entirely")
  movie:dispose()
end

-- A later pan rewrites both inside masks while leaving an explicitly
-- programmed second rectangle where the source left it.
function T.later_window_pans_rewrite_masks_without_resetting_the_second_rectangle()
  local root = sceneRoot(1)
  local frontImage = root .. "layers/rewrite-front.png"
  local backImage = root .. "layers/rewrite-back.png"
  local scenes, cacheFs = packWithSceneAt(
    compositeManifest(
      1,
      { layer(0, frontImage, 256, 192, 0), layer(1, backImage, 256, 192, 1) },
      { layer(0, root .. "layers/rewrite-lower.png", 256, 192) },
      { spriteClip(root .. "sprites/clip0.g4sprite", { stillFrame() }) },
      { { id = "reveal", events = { 1, 2, 3, 4, 5, 6 }, ["until"] = { kind = "duration", ticks = 20 } } },
      {
        windowEvent("reveal", 0, "main", windowRect(10, 0, 60, 100), windowRect(10, 0, 60, 100), 0, 1, 2),
        {
          op = "setWindowSecondary",
          stepId = "reveal",
          atStepTick = 0,
          engine = "main",
          rect = windowRect(0, 64, 255, 128),
          insideMask = 2,
        },
        windowEvent("reveal", 5, "main", windowRect(100, 0, 200, 192), windowRect(100, 0, 200, 192), 0, 1, 2),
        { op = "enableSkip", stepId = "reveal", atStepTick = 10 },
        { op = "waitTicks", stepId = "reveal", atStepTick = 0, ticks = 20 },
        { op = "finish", stepId = "reveal", atStepTick = 20 },
      }
    ),
    1
  )
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  for _ = 1, 6 do
    movie:updateFixed()
  end
  local baseline = #graphics.scissorIntersections
  movie:draw()
  local scissors = engineScissors(graphics, movie, "main", baseline)
  -- The rewritten second-window mask now admits the front plane across
  -- its whole authored band, while the back plane keeps its outside row.
  -- The band ends at the exclusive edge, so its last column falls outside.
  Assert.isTrue(
    hasScissor(scissors, 0, 64, 255, 64),
    "the later pan admits the front plane across the kept second rectangle"
  )
  Assert.isTrue(
    hasScissor(scissors, 0, 0, 100, 64),
    "the back plane keeps its outside row beside the later pan"
  )
  movie:dispose()
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

function T.opposing_engine_blends_keep_separate_weights_across_a_flip()
  local root = sceneRoot(1)
  local function rawCoefficient(n, ticks)
    return math.min(31, math.floor(n * 31 / ticks))
  end
  local function cappedWeight(raw)
    return math.min(raw, 16) / 16
  end
  Assert.equal(rawCoefficient(1, 20), 1, "the first tick holds the opening raw step")
  Assert.equal(rawCoefficient(10, 20), 15, "the middle tick holds the middle raw step")
  Assert.equal(rawCoefficient(20, 20), 31, "the final tick holds the full raw step")
  Assert.near(cappedWeight(1), 0.0625, 0.0001, "the opening weight follows the capped channel")
  Assert.near(cappedWeight(30), 1, 0.0001, "weights above the hardware cap saturate")
  local mainBack = root .. "layers/blend-main-back.png"
  local mainMid = root .. "layers/blend-main-mid.png"
  local mainFront = root .. "layers/blend-main-front.png"
  local subBack = root .. "layers/blend-sub-back.png"
  local subMid = root .. "layers/blend-sub-mid.png"
  local subFront = root .. "layers/blend-sub-front.png"
  local scenes, cacheFs = packWithSceneAt(
    compositeManifest(
      1,
      {
        layer(2, mainBack, 256, 192, 2),
        layer(1, mainMid, 256, 192, 1),
        layer(0, mainFront, 256, 192, 0),
      },
      {
        layer(2, subBack, 256, 192, 2),
        layer(1, subMid, 256, 192, 1),
        layer(0, subFront, 256, 192, 0),
      },
      { spriteClip(root .. "sprites/clip0.g4sprite", { stillFrame() }) },
      { { id = "hold", events = { 1, 2, 3, 4, 5, 6 }, ["until"] = { kind = "duration", ticks = 40 } } },
      {
        {
          op = "setBlend",
          stepId = "hold",
          atStepTick = 0,
          engine = "main",
          firstMask = 4,
          secondMask = 32,
          direction = 0,
          effect = "main-cross",
          ticks = 20,
        },
        {
          op = "setBlend",
          stepId = "hold",
          atStepTick = 0,
          engine = "sub",
          firstMask = 4,
          secondMask = 32,
          direction = 1,
          effect = "sub-cross",
          ticks = 20,
        },
        { op = "setScreenMapping", stepId = "hold", atStepTick = 15, mainPhysical = "lower" },
        { op = "enableSkip", stepId = "hold", atStepTick = 10 },
        { op = "waitTicks", stepId = "hold", atStepTick = 0, ticks = 40 },
        { op = "finish", stepId = "hold", atStepTick = 40 },
      }
    ),
    1
  )
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  local current = assert(movie.current, "the running movie owns its current slot")
  local mainFrontHandle = assert(current.imageByPath[mainFront], "the main front plane is staged")
  local mainBackHandle = assert(current.imageByPath[mainBack], "the main selected plane is staged")
  local subFrontHandle = assert(current.imageByPath[subFront], "the sub front plane is staged")
  local subBackHandle = assert(current.imageByPath[subBack], "the sub selected plane is staged")
  -- Both engines rasterize natively into the compositor scratch; the old
  -- per-draw tint was the single complementary weight, which the
  -- normative equation replaces with two independently saturated
  -- coefficients. The per-engine weights below are the raw step law:
  -- ev=floor(elapsed*31/ticks), direction 0 opens (ev,31-ev) and
  -- direction 1 opens (31-ev,ev), each side capped at sixteen.
  local function frameWeightSet(name, drawBaseline, evaBaseline)
    local weights = {}
    for _, weight in ipairs(uniformSendsSince(graphics, name, evaBaseline)) do
      weights[weight] = true
    end
    Assert.isTrue(
      #uniformSendsSince(graphics, name, evaBaseline) > 0,
      "the frame drives the compositor " .. name .. " uniforms"
    )
    return weights
  end
  movie:updateFixed()
  local firstBaseline = #graphics.draws
  local firstEva = #uniformSends(graphics, "eva")
  local firstEvb = #uniformSends(graphics, "evb")
  movie:draw()
  local mainFrontFirst = compositorDrawsOf(graphics, movie, mainFrontHandle, firstBaseline)
  Assert.equal(#mainFrontFirst, 1, "the excluded main front plane paints once")
  assertNativeScratchDraws(mainFrontFirst, "excluded main front")
  local mainBackFirst = compositorDrawsOf(graphics, movie, mainBackHandle, firstBaseline)
  Assert.equal(#mainBackFirst, 1, "the selected main plane paints once")
  assertNativeScratchDraws(mainBackFirst, "selected main")
  local subBackFirst = compositorDrawsOf(graphics, movie, subBackHandle, firstBaseline)
  Assert.equal(#subBackFirst, 1, "the selected sub plane paints once")
  assertNativeScratchDraws(subBackFirst, "selected sub")
  -- Opening tick: ev=floor(31/20)=1, so main (direction 0) sends (1,16)
  -- while sub (direction 1) sends (16,1).
  local firstEvaSet = frameWeightSet("eva", firstBaseline, firstEva)
  local firstEvbSet = frameWeightSet("evb", firstBaseline, firstEvb)
  Assert.isTrue(firstEvaSet[1], "the main engine opens its first side at one sixteenth")
  Assert.isTrue(firstEvaSet[16], "the reversed sub engine opens its first side saturated")
  Assert.isTrue(firstEvbSet[16], "the main engine opens its second side saturated")
  Assert.isTrue(firstEvbSet[1], "the reversed sub engine opens its second side at one sixteenth")
  for _ = 1, 9 do
    movie:updateFixed()
  end
  local midBaseline = #graphics.draws
  local midEva = #uniformSends(graphics, "eva")
  local midEvb = #uniformSends(graphics, "evb")
  movie:draw()
  local mainBackMid = compositorDrawsOf(graphics, movie, mainBackHandle, midBaseline)
  Assert.equal(#mainBackMid, 1, "the selected main plane still paints mid-transition")
  assertNativeScratchDraws(mainBackMid, "selected main mid-transition")
  -- Tenth tick: ev=floor(10*31/20)=15, so main sends (15,16) and sub (16,15).
  local midEvaSet = frameWeightSet("eva", midBaseline, midEva)
  local midEvbSet = frameWeightSet("evb", midBaseline, midEvb)
  Assert.isTrue(midEvaSet[15], "the main engine still counts its first side up mid-transition")
  Assert.isTrue(midEvaSet[16], "the reversed sub engine keeps its first side saturated")
  Assert.isTrue(midEvbSet[16], "the main engine keeps its second side saturated")
  Assert.isTrue(midEvbSet[15], "the reversed sub engine still counts its second side up")
  local midEffects = assert(movie.current, "the running movie owns its current slot").effects
  Assert.isFalse(midEffects["main-cross"].done, "the main blend still runs at its tenth tick")
  Assert.isFalse(midEffects["sub-cross"].done, "the sub blend still runs at its tenth tick")
  for _ = 1, 6 do
    movie:updateFixed()
  end
  Assert.equal(movie.current.mainPhysical, "lower", "the authored flip moves the main engine")
  local flipBaseline = #graphics.draws
  local flipEva = #uniformSends(graphics, "eva")
  local flipEvb = #uniformSends(graphics, "evb")
  movie:draw()
  -- Sixteenth tick: ev=floor(16*31/20)=24, so main sends (16,7) and sub
  -- (7,16); the flip carries each running pair instead of merging them.
  local flipEvaSet = frameWeightSet("eva", flipBaseline, flipEva)
  local flipEvbSet = frameWeightSet("evb", flipBaseline, flipEvb)
  Assert.isTrue(flipEvaSet[16], "the flipped main engine keeps its saturated first side")
  Assert.isTrue(flipEvaSet[7], "the flipped sub engine keeps its running first side")
  Assert.isTrue(flipEvbSet[7], "the flipped main engine keeps its running second side")
  Assert.isTrue(flipEvbSet[16], "the flipped sub engine keeps its saturated second side")
  for _ = 1, 4 do
    movie:updateFixed()
  end
  local doneEffects = assert(movie.current, "the running movie owns its current slot").effects
  Assert.isTrue(doneEffects["main-cross"].done, "the main blend retires on its own twentieth tick")
  Assert.isTrue(doneEffects["sub-cross"].done, "the sub blend retires on its own twentieth tick")
  movie:dispose()
  Assert.equal(liveHandles(graphics), 0, "the blend movie releases every handle")
end

function T.selected_planes_blend_with_capped_coefficients_under_window_masks()
  local root = sceneRoot(1)
  local function rawCoefficient(n, ticks)
    return math.min(31, math.floor(n * 31 / ticks))
  end
  local function cappedWeight(raw)
    return math.min(raw, 16) / 16
  end
  Assert.equal(rawCoefficient(15, 31), 15, "the middle tick holds its raw step")
  Assert.equal(rawCoefficient(31, 31), 31, "the final tick holds the full raw step")
  Assert.near(cappedWeight(15), 0.9375, 0.0001, "the middle weight follows the capped channel")
  Assert.equal(cappedWeight(16), cappedWeight(31), "weights above the hardware cap plateau")
  local backImage = root .. "layers/mask-back.png"
  local midImage = root .. "layers/mask-mid.png"
  local frontImage = root .. "layers/mask-front.png"
  local scenes, cacheFs = packWithSceneAt(
    compositeManifest(
      1,
      {
        layer(0, backImage, 256, 192, 2),
        layer(1, midImage, 256, 192, 1),
        layer(2, frontImage, 256, 192, 0),
      },
      { layer(0, root .. "layers/mask-lower.png", 256, 192) },
      { spriteClip(root .. "sprites/clip0.g4sprite", { stillFrame() }) },
      { { id = "hold", events = { 1, 2, 3, 4, 5 }, ["until"] = { kind = "duration", ticks = 40 } } },
      {
        {
          op = "setBlend",
          stepId = "hold",
          atStepTick = 0,
          engine = "main",
          firstMask = 2,
          secondMask = 32,
          direction = 0,
          effect = "mid-cross",
          ticks = 31,
        },
        windowEvent("hold", 0, "main", windowRect(0, 0, 127, 191), windowRect(0, 0, 127, 191), 0, 3, 31),
        { op = "enableSkip", stepId = "hold", atStepTick = 10 },
        { op = "waitTicks", stepId = "hold", atStepTick = 0, ticks = 40 },
        { op = "finish", stepId = "hold", atStepTick = 40 },
      }
    ),
    1
  )
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  local current = assert(movie.current, "the running movie owns its current slot")
  local midHandle = assert(current.imageByPath[midImage], "the selected middle plane is staged")
  local frontHandle = assert(current.imageByPath[frontImage], "the excluded front plane is staged")
  -- Both planes rasterize natively into the compositor scratch; the old
  -- per-draw tint was the single global weight, which the normative
  -- equation replaces with the per-pixel pair test. The masks below
  -- select the middle plane first and only the backdrop second, so the
  -- middle pair never qualifies and both planes keep native colors while
  -- the dual uniforms still travel: elapsed 15 of 31 counts raw fifteen,
  -- direction 0 sends (15,16).
  for _ = 1, 15 do
    movie:updateFixed()
  end
  local midBaseline = #graphics.draws
  movie:draw()
  local midDraws = compositorDrawsOf(graphics, movie, midHandle, midBaseline)
  assertNativeScratchDraws(midDraws, "selected middle")
  local evaSends = uniformSends(graphics, "eva")
  local evbSends = uniformSends(graphics, "evb")
  Assert.equal(evaSends[#evaSends], 15, "the middle tick sends fifteen first sixteenths")
  Assert.equal(evbSends[#evbSends], 16, "the second side saturates independently of the first")
  local firstSends = uniformSends(graphics, "firstMask")
  local secondSends = uniformSends(graphics, "secondMask")
  Assert.equal(firstSends[#firstSends], 2, "the first mask selects only the middle plane")
  Assert.equal(secondSends[#secondSends], 32, "the second mask selects only the backdrop")
  local frontDraws = compositorDrawsOf(graphics, movie, frontHandle, midBaseline)
  assertNativeScratchDraws(frontDraws, "excluded front")
  for _ = 1, 1 do
    movie:updateFixed()
  end
  -- Elapsed 16 counts raw sixteen and elapsed 31 counts raw thirty-one:
  -- the first side plateaus at sixteen on both frames while the second
  -- side falls from fifteen to zero independently.
  movie:draw()
  local evaAtSixteen = uniformSends(graphics, "eva")
  local evbAtSixteen = uniformSends(graphics, "evb")
  Assert.equal(evaAtSixteen[#evaAtSixteen], 16, "the saturation tick caps the first side at sixteen")
  Assert.equal(evbAtSixteen[#evbAtSixteen], 15, "the second side stays near-full at sixteen steps")
  for _ = 1, 15 do
    movie:updateFixed()
  end
  movie:draw()
  local evaAtFull = uniformSends(graphics, "eva")
  local evbAtFull = uniformSends(graphics, "evb")
  Assert.equal(
    evaAtFull[#evaAtFull],
    evaAtSixteen[#evaAtSixteen],
    "the capped first side plateaus instead of tracking the tick count"
  )
  Assert.equal(evaAtFull[#evaAtFull], 16, "the final raw step stays saturated")
  Assert.equal(evbAtFull[#evbAtFull], 0, "the independent second side retires while the first side plateaus")
  movie:dispose()
  Assert.equal(liveHandles(graphics), 0, "the mask movie releases every handle")
end

function T.row_wipe_boundaries_follow_the_scanline_cosine_law()
  local root = sceneRoot(2)
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
  Assert.equal(wipeBoundary(0, 20, 0), 255, "the opening edge starts fully closed")
  Assert.equal(wipeBoundary(0, 20, 191), 255, "the opening edge starts fully closed on every row")
  Assert.equal(wipeBoundary(20, 20, 0), 0, "the final edge ends fully open")
  Assert.equal(wipeBoundary(20, 20, 191), 0, "the final edge ends fully open on every row")
  Assert.equal(wipeBoundary(10, 20, 96), 127, "the halfway edge centers on every row")
  Assert.isFalse(wipeBoundary(5, 20, 48) == wipeBoundary(5, 20, 96), "quarter-transition edges slope with the scanline")
  local upperImage = root .. "layers/wipe-upper.png"
  local lowerImage = root .. "layers/wipe-lower.png"
  local scenes, cacheFs = packWithSceneAt(
    compositeManifest(
      2,
      { layer(0, upperImage, 256, 192) },
      { layer(0, lowerImage, 256, 192) },
      {},
      { { id = "hold", events = { 1, 2, 3 }, ["until"] = { kind = "duration", ticks = 40 } } },
      {
        {
          op = "circleWipe",
          stepId = "hold",
          atStepTick = 0,
          engine = "main",
          kind = 1,
          ticks = 20,
          effect = "wipe-cover",
        },
        { op = "waitTicks", stepId = "hold", atStepTick = 0, ticks = 40 },
        { op = "finish", stepId = "hold", atStepTick = 40 },
      }
    ),
    2
  )
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  enterScene(movie, 2)
  for _ = 1, 5 do
    movie:updateFixed()
  end
  local scissorBaseline = #graphics.scissorIntersections
  local canvasCount = #graphics.canvases
  movie:draw()
  local function edgesForRow(y)
    local edges = {}
    for index = scissorBaseline + 1, #graphics.scissorIntersections do
      local entry = graphics.scissorIntersections[index]
      if graphics.scissorCanvases[index].canvas == movie.mainCanvas then
        local requested = entry.requested
        if y >= requested[2] and y < requested[2] + requested[4] then
          edges[#edges + 1] = requested[1]
        end
      end
    end
    return edges
  end
  local lowEdges = edgesForRow(48)
  local highEdges = edgesForRow(96)
  local usesMaskCanvas = #graphics.canvases > canvasCount
  if #lowEdges == 0 and #highEdges == 0 then
    Assert.isTrue(usesMaskCanvas, "the scanline wipe clips per row instead of one centered rectangle")
  else
    Assert.isTrue(#lowEdges > 0, "the wipe clips the upper probe row")
    Assert.isTrue(#highEdges > 0, "the wipe clips the lower probe row")
    local lowSorted, highSorted = {}, {}
    for _, edge in ipairs(lowEdges) do
      lowSorted[#lowSorted + 1] = edge
    end
    for _, edge in ipairs(highEdges) do
      highSorted[#highSorted + 1] = edge
    end
    table.sort(lowSorted)
    table.sort(highSorted)
    Assert.isFalse(
      #lowSorted == #highSorted and lowSorted[1] == highSorted[1],
      "the wipe edge slopes with the scanline instead of a centered rectangle"
    )
    local expectedLow = wipeBoundary(5, 20, 48)
    local expectedHigh = wipeBoundary(5, 20, 96)
    local foundLow, foundHigh = false, false
    for _, edge in ipairs(lowSorted) do
      if math.abs(edge - expectedLow) <= 1 then
        foundLow = true
      end
    end
    for _, edge in ipairs(highSorted) do
      if math.abs(edge - expectedHigh) <= 1 then
        foundHigh = true
      end
    end
    Assert.isTrue(foundLow, "the upper row matches the scanline law")
    Assert.isTrue(foundHigh, "the lower row matches the scanline law")
  end
  movie:dispose()
  Assert.equal(liveHandles(graphics), 0, "the wipe movie releases every handle")
end

-- Source step-clock coefficients land on exact sixteenths: the opening
-- tick carries raw 0, the first tick raw 1, and saturation holds opaque
-- past raw 16 instead of dividing by the tick count. The fixture selects
-- the back plane on BG0 so the assertions observe the selected plane.
function T.blend_coefficients_follow_exact_sixteenth_steps()
  local root = sceneRoot(1)
  local backImage = root .. "layers/coeff-back.png"
  local midImage = root .. "layers/coeff-mid.png"
  local frontImage = root .. "layers/coeff-front.png"
  local scenes, cacheFs = packWithSceneAt(
    compositeManifest(
      1,
      {
        layer(0, backImage, 256, 192, 2),
        layer(1, midImage, 256, 192, 1),
        layer(2, frontImage, 256, 192, 0),
      },
      { layer(0, root .. "layers/coeff-lower.png", 256, 192) },
      { spriteClip(root .. "sprites/clip0.g4sprite", { stillFrame() }) },
      { { id = "hold", events = { 1, 2, 3, 4 }, ["until"] = { kind = "duration", ticks = 40 } } },
      {
        {
          op = "setBlend",
          stepId = "hold",
          atStepTick = 0,
          engine = "main",
          firstMask = 1,
          secondMask = 32,
          direction = 0,
          effect = "coeff-cross",
          ticks = 31,
        },
        { op = "enableSkip", stepId = "hold", atStepTick = 10 },
        { op = "waitTicks", stepId = "hold", atStepTick = 0, ticks = 40 },
        { op = "finish", stepId = "hold", atStepTick = 40 },
      }
    ),
    1
  )
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  local current = assert(movie.current, "the running movie owns its current slot")
  local backHandle = assert(current.imageByPath[backImage], "the selected back plane is staged")
  local frontHandle = assert(current.imageByPath[frontImage], "the excluded front plane is staged")
  -- The old per-draw alpha was the single complementary weight; the
  -- normative equation sends two independently saturated coefficients
  -- while every plane rasterizes natively. Raw ev counts
  -- floor(elapsed*31/31) and direction 0 opens (ev,31-ev) with each side
  -- capped at sixteen, so the frames below send (0,16), (1,16),
  -- (15,16), (16,15), and (16,0).
  local function framePair(baseline, evaBaseline, evbBaseline)
    local evaSends = uniformSendsSince(graphics, "eva", evaBaseline)
    local evbSends = uniformSendsSince(graphics, "evb", evbBaseline)
    Assert.isTrue(#evaSends > 0, "the frame drives the first-weight uniforms")
    Assert.isTrue(#evbSends > 0, "the frame drives the second-weight uniforms")
    local draws = compositorDrawsOf(graphics, movie, backHandle, baseline)
    Assert.equal(#draws, 1, "the frame paints the selected plane once")
    assertNativeScratchDraws(draws, "selected back")
    return evaSends[#evaSends], evbSends[#evbSends]
  end
  local preflightEva, preflightEvb = framePair(0, 0, 0)
  Assert.equal(preflightEva, 0, "the opening tick sends raw step zero first")
  Assert.equal(preflightEvb, 16, "the opening tick saturates the second side")
  movie:updateFixed()
  local firstBaseline = #graphics.draws
  local firstEvaCount = #uniformSends(graphics, "eva")
  local firstEvbCount = #uniformSends(graphics, "evb")
  movie:draw()
  local firstEva, firstEvb = framePair(firstBaseline, firstEvaCount, firstEvbCount)
  Assert.equal(firstEva, 1, "the first tick sends one capped sixteenth first")
  Assert.equal(firstEvb, 16, "the first tick keeps the second side saturated")
  for _ = 1, 14 do
    movie:updateFixed()
  end
  local midBaseline = #graphics.draws
  local midEvaCount = #uniformSends(graphics, "eva")
  local midEvbCount = #uniformSends(graphics, "evb")
  movie:draw()
  local midEva, midEvb = framePair(midBaseline, midEvaCount, midEvbCount)
  Assert.equal(midEva, 15, "the middle tick sends fifteen capped sixteenths first")
  Assert.equal(midEvb, 16, "the middle tick keeps the second side saturated")
  movie:updateFixed()
  local capBaseline = #graphics.draws
  local capEvaCount = #uniformSends(graphics, "eva")
  local capEvbCount = #uniformSends(graphics, "evb")
  movie:draw()
  local cappedEva, cappedEvb = framePair(capBaseline, capEvaCount, capEvbCount)
  Assert.equal(cappedEva, 16, "raw steps past sixteen saturate the first side")
  Assert.equal(cappedEvb, 15, "the second side counts down independently")
  for _ = 1, 15 do
    movie:updateFixed()
  end
  local fullBaseline = #graphics.draws
  local fullEvaCount = #uniformSends(graphics, "eva")
  local fullEvbCount = #uniformSends(graphics, "evb")
  movie:draw()
  local fullEva, fullEvb = framePair(fullBaseline, fullEvaCount, fullEvbCount)
  Assert.equal(fullEva, 16, "the final raw step stays saturated")
  Assert.equal(fullEva, cappedEva, "saturation plateaus instead of tracking the tick count")
  Assert.equal(fullEvb, 0, "the independent second side retires at the final tick")
  assertNativeScratchDraws(compositorDrawsOf(graphics, movie, frontHandle, 0), "excluded front")
  movie:dispose()
  Assert.equal(liveHandles(graphics), 0, "the coefficient movie releases every handle")
end

-- An instant blend restores the constant source register weights at once:
-- after a timed fade retires the first-target plane, the zero-duration
-- reset paints that plane opaque again with no timed program and no
-- effect wait, exactly like the source register write behind it.
function T.instant_blend_reset_restores_constant_source_weights()
  local root = sceneRoot(1)
  local logoImage = root .. "layers/logo-main.png"
  local scenes, cacheFs = packWithSceneAt(
    compositeManifest(
      1,
      { layer(0, logoImage, 256, 192) },
      { layer(0, root .. "layers/logo-sub.png", 256, 192) },
      {},
      {
        { id = "fades", events = { 1 }, ["until"] = { kind = "effect", effect = "logo-fade" } },
        { id = "logo", events = { 2, 3, 4 }, ["until"] = { kind = "duration", ticks = 4 } },
      },
      {
        {
          op = "setBlend",
          stepId = "fades",
          atStepTick = 0,
          engine = "main",
          firstMask = 1,
          secondMask = 32,
          direction = 1,
          effect = "logo-fade",
          ticks = 4,
        },
        {
          op = "setBlend",
          stepId = "logo",
          atStepTick = 2,
          engine = "main",
          firstMask = 1,
          secondMask = 32,
          ticks = 0,
          eva = 31,
          evb = 0,
        },

        { op = "waitTicks", stepId = "logo", atStepTick = 0, ticks = 4 },
        { op = "enableSkip", stepId = "logo", atStepTick = 1 },
      }
    ),
    1
  )
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  for _ = 1, 4 do
    movie:updateFixed()
  end
  local slot = assert(movie.current, "the running movie owns its current slot")
  Assert.equal(slot.stepIndex, 2, "playback reaches the logo beat after the fade")
  movie:updateFixed()
  movie:updateFixed()
  slot = assert(movie.current, "the running movie owns its current slot")
  local program = assert(slot.blendPrograms.main, "the instant reset replaces the main program")
  Assert.equal(program.ticks, 0, "the reset carries no timed program")
  Assert.equal(program.firstMask, 1, "the reset keeps the first-target mask")
  Assert.equal(program.secondMask, 32, "the reset keeps the second-target mask")
  Assert.equal(program.eva, 31, "the reset carries the source full first weight")
  Assert.equal(program.evb, 0, "the reset carries the source zero second weight")
  movie:draw()
  local evas = uniformSendsSince(graphics, "eva", 0)
  local evbs = uniformSendsSince(graphics, "evb", 0)
  Assert.isTrue(#evas > 0, "the reset frame drives the first-weight uniform")
  Assert.isTrue(#evbs > 0, "the reset frame drives the second-weight uniform")
  Assert.equal(evas[#evas], 16, "the constant restore saturates the first side")
  Assert.equal(evbs[#evbs], 0, "the constant restore retires the second side")
  movie:dispose()
  Assert.equal(liveHandles(graphics), 0, "the reset movie releases every handle")
end

-- Independent engine clocks retire their own named waits: the shorter main
-- program completes while the longer sub program still runs, so a wait on
-- the sub program holds past the main completion.
function T.blend_effect_waits_complete_on_their_own_engine_clock()
  local root = sceneRoot(1)
  local scenes, cacheFs = packWithSceneAt(
    compositeManifest(
      1,
      { layer(0, root .. "layers/wait-main.png", 256, 192) },
      { layer(0, root .. "layers/wait-sub.png", 256, 192) },
      { spriteClip(root .. "sprites/clip0.g4sprite", { stillFrame() }) },
      {
        { id = "hold", events = { 1, 2, 3 }, ["until"] = { kind = "effect", effect = "sub-twenty" } },
        { id = "tail", events = { 4, 5 }, ["until"] = { kind = "duration", ticks = 5 } },
      },
      {
        {
          op = "setBlend",
          stepId = "hold",
          atStepTick = 0,
          engine = "main",
          firstMask = 1,
          secondMask = 32,
          direction = 0,
          effect = "main-ten",
          ticks = 10,
        },
        {
          op = "setBlend",
          stepId = "hold",
          atStepTick = 0,
          engine = "sub",
          firstMask = 1,
          secondMask = 32,
          direction = 1,
          effect = "sub-twenty",
          ticks = 20,
        },
        { op = "enableSkip", stepId = "hold", atStepTick = 5 },
        { op = "waitTicks", stepId = "tail", atStepTick = 0, ticks = 5 },
        { op = "finish", stepId = "tail", atStepTick = 5 },
      }
    ),
    1
  )
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  for _ = 1, 10 do
    movie:updateFixed()
  end
  local effects = assert(movie.current, "the running movie owns its current slot").effects
  Assert.isTrue(effects["main-ten"].done, "the shorter main program retires on its own tenth tick")
  Assert.isFalse(effects["sub-twenty"].done, "the longer sub program still runs past the main completion")
  Assert.equal(movie:sceneNumber(), 1, "the sub wait holds the step past the main completion")
  for _ = 1, 10 do
    movie:updateFixed()
  end
  local done = assert(movie.current, "the running movie owns its current slot").effects
  Assert.isTrue(done["sub-twenty"].done, "the sub program retires on its own twentieth tick")
  for _ = 1, 5 + 1 do
    movie:updateFixed()
  end
  Assert.equal(movie:sceneNumber(), 2, "the tail step runs after both engine programs retire, then the exit call")
  movie:dispose()
  Assert.equal(liveHandles(graphics), 0, "the wait movie releases every handle")
end

-- Wipe endpoints stay arithmetic-safe and retire exactly: the opening
-- frame covers every row without division faults, and the program stops
-- clipping rows once its authored ticks elapse so later art shows. The
-- preflight draw already runs the opening frame, so the zero-tick
-- endpoint is observed before the first source tick advances.
function T.wipe_endpoints_retire_cleanly_without_arithmetic_faults()
  local root = sceneRoot(1)
  local scenes, cacheFs = packWithSceneAt(
    compositeManifest(
      1,
      { layer(0, root .. "layers/edge-upper.png", 256, 192) },
      { layer(0, root .. "layers/edge-lower.png", 256, 192) },
      { spriteClip(root .. "sprites/clip0.g4sprite", { stillFrame() }) },
      { { id = "open", events = { 1, 2, 3 }, ["until"] = { kind = "duration", ticks = 10 } } },
      {
        {
          op = "circleWipe",
          stepId = "open",
          atStepTick = 0,
          engine = "main",
          kind = 1,
          ticks = 6,
          effect = "edge-wipe",
        },
        { op = "enableSkip", stepId = "open", atStepTick = 5 },
        { op = "waitTicks", stepId = "open", atStepTick = 0, ticks = 10 },
      }
    ),
    1
  )
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  local covered = 0
  local widest = 0
  for index = 1, #graphics.scissorIntersections do
    local requested = graphics.scissorIntersections[index].requested
    Assert.isTrue(requested[1] == requested[1], "the opening edge stays finite")
    Assert.isTrue(requested[3] == requested[3], "the opening span stays finite")
    if graphics.scissorCanvases[index].canvas == movie.mainCanvas then
      covered = covered + 1
      if requested[3] == 256 then
        widest = widest + 1
      end
    end
  end
  Assert.equal(covered, 192, "the opening frame clips every row once on its owning engine")
  Assert.equal(widest, 0, "no row carries a full-width mirror span")
  local function mainScissors()
    local count = 0
    for index = 1, #graphics.scissorIntersections do
      if graphics.scissorCanvases[index].canvas == movie.mainCanvas then
        count = count + 1
      end
    end
    return count
  end
  for _ = 1, 6 do
    movie:updateFixed()
  end
  local doneBaseline = mainScissors()
  movie:draw()
  Assert.equal(mainScissors(), doneBaseline, "the completed wipe draws no further row spans")
  for _ = 1, 4 + 1 do
    movie:updateFixed()
  end
  Assert.equal(movie:sceneNumber(), 2, "the step still holds its authored duration past the wipe, then the exit call")
  local tailBaseline = mainScissors()
  movie:draw()
  Assert.equal(mainScissors(), tailBaseline, "the retired wipe stops clipping rows once its ticks elapse")
  movie:dispose()
  Assert.equal(liveHandles(graphics), 0, "the endpoint movie releases every handle")
end

-- Engine-local effects survive a physical screen flip without spilling:
-- the main blend keeps its own weights on the main canvas while the idle
-- sub engine paints every plane opaque.
function T.engine_effects_stay_local_across_a_physical_flip()
  local root = sceneRoot(1)
  local mainBack = root .. "layers/flip-main-back.png"
  local mainFront = root .. "layers/flip-main-front.png"
  local subBack = root .. "layers/flip-sub-back.png"
  local scenes, cacheFs = packWithSceneAt(
    compositeManifest(
      1,
      {
        layer(0, mainBack, 256, 192, 2),
        layer(2, mainFront, 256, 192, 0),
      },
      { layer(0, subBack, 256, 192) },
      { spriteClip(root .. "sprites/clip0.g4sprite", { stillFrame() }) },
      { { id = "hold", events = { 1, 2, 3, 4, 5 }, ["until"] = { kind = "duration", ticks = 40 } } },
      {
        {
          op = "setBlend",
          stepId = "hold",
          atStepTick = 0,
          engine = "main",
          firstMask = 1,
          secondMask = 32,
          direction = 0,
          effect = "flip-cross",
          ticks = 20,
        },
        { op = "setScreenMapping", stepId = "hold", atStepTick = 5, mainPhysical = "lower" },
        { op = "enableSkip", stepId = "hold", atStepTick = 10 },
        { op = "waitTicks", stepId = "hold", atStepTick = 0, ticks = 40 },
        { op = "finish", stepId = "hold", atStepTick = 40 },
      }
    ),
    1
  )
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  local current = assert(movie.current, "the running movie owns its current slot")
  local mainBackHandle = assert(current.imageByPath[mainBack], "the selected main plane is staged")
  local mainFrontHandle = assert(current.imageByPath[mainFront], "the excluded main plane is staged")
  local subBackHandle = assert(current.imageByPath[subBack], "the idle sub plane is staged")
  -- The blended main engine rasterizes natively into the compositor
  -- scratch while the idle sub engine keeps painting its role target
  -- directly; the old per-draw alpha was the single complementary weight,
  -- which the normative equation replaces with two independently
  -- saturated coefficients. Ticks are out of twenty: the opening frame
  -- sends main (1,16) uniformly and the flip frame sends main (7,16)
  -- uniformly, with no sub-engine coefficient anywhere.
  local function frameWeights(evaBaseline, evbBaseline)
    local evaSends = uniformSendsSince(graphics, "eva", evaBaseline)
    local evbSends = uniformSendsSince(graphics, "evb", evbBaseline)
    Assert.isTrue(#evaSends > 0, "the frame drives the first-weight uniforms")
    Assert.isTrue(#evbSends > 0, "the frame drives the second-weight uniforms")
    return evaSends, evbSends
  end
  local function assertUniform(weights, expected, message)
    for _, weight in ipairs(weights) do
      Assert.equal(weight, expected, message)
    end
  end
  movie:updateFixed()
  local firstBaseline = #graphics.draws
  local firstEva = #uniformSends(graphics, "eva")
  local firstEvb = #uniformSends(graphics, "evb")
  movie:draw()
  assertNativeScratchDraws(compositorDrawsOf(graphics, movie, mainBackHandle, firstBaseline), "selected main")
  local firstEvaSends, firstEvbSends = frameWeights(firstEva, firstEvb)
  assertUniform(firstEvaSends, 1, "the opening weight selects the masked back plane first")
  assertUniform(firstEvbSends, 16, "the main engine opens saturated second")
  assertNativeScratchDraws(compositorDrawsOf(graphics, movie, mainFrontHandle, firstBaseline), "unmasked main")
  -- The idle engine never enters the compositor: it paints its own role
  -- target natively with no coefficient sends of its own.
  local subFirst = engineDrawsOf(graphics, movie, "sub", subBackHandle, firstBaseline)
  Assert.isTrue(#subFirst > 0, "the idle sub engine still paints its own target")
  for _, draw in ipairs(subFirst) do
    Assert.equal(draw.color[4], 1, "the blend never spills onto the idle engine")
  end
  for _ = 1, 4 do
    movie:updateFixed()
  end
  Assert.equal(movie.current.mainPhysical, "lower", "the authored flip moves the main engine")
  local flipBaseline = #graphics.draws
  local flipEva = #uniformSends(graphics, "eva")
  local flipEvb = #uniformSends(graphics, "evb")
  movie:draw()
  assertNativeScratchDraws(compositorDrawsOf(graphics, movie, mainBackHandle, flipBaseline), "flipped selected main")
  local flipEvaSends, flipEvbSends = frameWeights(flipEva, flipEvb)
  assertUniform(flipEvaSends, 7, "the flip carries the running main first weight instead of restarting it")
  assertUniform(flipEvbSends, 16, "the flip carries the running main second weight instead of restarting it")
  local subFlip = engineDrawsOf(graphics, movie, "sub", subBackHandle, flipBaseline)
  Assert.isTrue(#subFlip > 0, "the idle engine still paints its own target across the flip")
  for _, draw in ipairs(subFlip) do
    Assert.equal(draw.color[4], 1, "the idle engine stays opaque across the flip")
  end
  movie:dispose()
  Assert.equal(liveHandles(graphics), 0, "the flip movie releases every handle")
end

-- Every circle kind covers exactly one scanline span with its own source
-- backdrop: kinds 0 and 2 hide the left of the scanline edge behind
-- white and black while the right shows game art; kinds 1 and 3 show
-- game art on the left and hide the right behind white and black. No
-- kind paints a second mirrored stripe, and the idle engine stays clean.
function T.circle_wipe_kinds_cover_the_source_inside_outside_spans_with_the_source_backdrops()
  local kinds = {
    { kind = 0, left = true, color = { 1, 1, 1, 1 } },
    { kind = 1, left = false, color = { 1, 1, 1, 1 } },
    { kind = 2, left = true, color = { 0, 0, 0, 1 } },
    { kind = 3, left = false, color = { 0, 0, 0, 1 } },
  }
  local rows = { 32, 64, 96 }
  local ticks = 12
  local elapsed = 3
  local function truncTowardZero(value)
    if value >= 0 then
      return math.floor(value)
    end
    return math.ceil(value)
  end
  local function wipeBoundary(n, total, vcount)
    local theta = math.pi * n / total
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
  for _, probe in ipairs(kinds) do
    local root = sceneRoot(1)
    local scenes, cacheFs = packWithOverrides({
      [1] = compositeManifest(
        1,
        { layer(0, root .. "layers/mask-upper.png", 256, 192) },
        { layer(0, root .. "layers/mask-lower.png", 256, 192) },
        {},
        { { id = "hold", events = { 1, 2, 3 }, ["until"] = { kind = "duration", ticks = 40 } } },
        {
          {
            op = "circleWipe",
            stepId = "hold",
            atStepTick = 0,
            engine = "main",
            kind = probe.kind,
            ticks = ticks,
            effect = "mask-kind",
          },
          { op = "enableSkip", stepId = "hold", atStepTick = 10 },
          { op = "waitTicks", stepId = "hold", atStepTick = 0, ticks = 40 },
        }
      ),
    })
    local graphics = movieGraphics()
    local movie = openMovie(scenes, cacheFs, graphics)
    for _ = 1, elapsed do
      movie:updateFixed()
    end
    local scissorBaseline = #graphics.scissorIntersections
    local rectBaseline = #graphics.rectangles
    movie:draw()
    local spans = {}
    local addedRects = {}
    for index = rectBaseline + 1, #graphics.rectangles do
      addedRects[#addedRects + 1] = graphics.rectangles[index]
    end
    local rectCursor = 0
    for index = scissorBaseline + 1, #graphics.scissorIntersections do
      local entry = graphics.scissorIntersections[index]
      local canvas = graphics.scissorCanvases[index].canvas
      if canvas == movie.mainCanvas then
        local requested = entry.requested
        if requested[4] == 1 and requested[3] < 256 then
          rectCursor = rectCursor + 1
          local fill = assert(addedRects[rectCursor], "every wipe scissor carries its cover fill")
          Assert.equal(fill.x, requested[1], "the cover fill matches its clipped span")
          Assert.equal(fill.y, requested[2], "the cover fill matches its clipped row")
          Assert.equal(fill.w, requested[3], "the cover fill matches its clipped width")
          spans[#spans + 1] = { x = requested[1], y = requested[2], w = requested[3], color = fill.color }
        end
      else
        Assert.isFalse(canvas == movie.subCanvas, "kind " .. probe.kind .. " clips nothing on the idle engine")
      end
    end
    Assert.equal(rectCursor, #addedRects, "every cover fill is accounted for by a wipe scissor")
    for _, row in ipairs(rows) do
      local boundary = wipeBoundary(elapsed, ticks, row)
      local wantX, wantW
      if probe.left then
        wantX, wantW = 0, boundary
      else
        wantX, wantW = boundary, 256 - boundary
      end
      local rowSpans = {}
      for _, span in ipairs(spans) do
        if span.y == row then
          rowSpans[#rowSpans + 1] = span
        end
      end
      Assert.equal(#rowSpans, 1, "kind " .. probe.kind .. " covers row " .. row .. " with one span, never a mirror")
      Assert.equal(rowSpans[1].x, wantX, "kind " .. probe.kind .. " anchors row " .. row .. " on the source side")
      Assert.equal(rowSpans[1].w, wantW, "kind " .. probe.kind .. " spans row " .. row .. " to the scanline edge")
      Assert.deepEqual(
        rowSpans[1].color,
        probe.color,
        "kind " .. probe.kind .. " hides row " .. row .. " behind its own source backdrop"
      )
    end
    movie:dispose()
    Assert.equal(liveHandles(graphics), 0, "the kind " .. probe.kind .. " mask movie releases every handle")
  end
end

-- The retail town open/close sequence runs its seven wipes in order on
-- their own engines: three main opens interleaved with three main closes
-- and one sub reveal, each holding its gate for exactly eight ticks with
-- its own completion identity. The runtime executes the authored order
-- without merging, reordering, or spilling beats across engines.
function T.seven_source_wipes_play_in_order_with_their_own_engines_and_gates()
  local beats = {
    { engine = "main", kind = 0 },
    { engine = "main", kind = 3 },
    { engine = "main", kind = 2 },
    { engine = "main", kind = 3 },
    { engine = "main", kind = 2 },
    { engine = "main", kind = 3 },
    { engine = "sub", kind = 2 },
  }
  local steps, events = {}, {}
  for index, beat in ipairs(beats) do
    steps[#steps + 1] =
      { id = "beat-" .. index, events = { index }, ["until"] = { kind = "effect", effect = "wipe-beat-" .. index } }
    events[#events + 1] = {
      op = "circleWipe",
      stepId = "beat-" .. index,
      atStepTick = 0,
      engine = beat.engine,
      kind = beat.kind,
      ticks = 8,
      effect = "wipe-beat-" .. index,
    }
  end
  steps[#steps + 1] =
    { id = "done", events = { #events + 1, #events + 2 }, ["until"] = { kind = "duration", ticks = 5 } }
  events[#events + 1] = { op = "waitTicks", stepId = "done", atStepTick = 0, ticks = 5 }
  events[#events + 1] = { op = "finish", stepId = "done", atStepTick = 0 }
  local root = sceneRoot(3)
  local scenes, cacheFs = packWithOverrides({
    [3] = compositeManifest(
      3,
      { layer(0, root .. "layers/beat-upper.png", 256, 192) },
      { layer(0, root .. "layers/beat-lower.png", 256, 192) },
      {},
      steps,
      events
    ),
  })
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  local ticks = 0
  while movie:sceneNumber() < 3 and ticks < 5000 do
    movie:updateFixed()
    movie:draw()
    ticks = ticks + 1
  end
  Assert.equal(movie:sceneNumber(), 3, "playback reaches the wipe sequence")
  local observed, beatStartTicks, lastBeat, thirdSlot = {}, {}, nil, nil
  -- Sample after dispatching: a newly selected case first runs on the
  -- following update, so the start lands when its entry fires and every
  -- gate keeps its authored eight ticks.
  local guard = 0
  while movie:sceneNumber() == 3 and guard < 5000 do
    guard = guard + 1
    local slot = assert(movie.current, "the running movie owns its current slot")
    if slot.sceneNumber == 3 then
      thirdSlot = slot
      local step = assert(slot.manifest.timeline.steps[slot.stepIndex], "the movie stays on a known step")
      local id = assert(step.id, "the step carries its source identity")
      if id ~= "done" and id ~= lastBeat and slot.wipe ~= nil and slot.stepElapsed >= 1 then
        lastBeat = id
        observed[#observed + 1] = { engine = slot.wipe.engine, kind = slot.wipe.kind, ticks = slot.wipe.ticks }
        beatStartTicks[#beatStartTicks + 1] = ticks
      end
    end
    movie:updateFixed()
    movie:draw()
    ticks = ticks + 1
  end
  Assert.equal(#observed, 7, "all seven wipe beats play exactly once")
  for index, beat in ipairs(beats) do
    Assert.equal(observed[index].engine, beat.engine, "beat " .. index .. " owns the " .. beat.engine .. " engine")
    Assert.equal(observed[index].kind, beat.kind, "beat " .. index .. " runs kind " .. beat.kind)
    Assert.equal(observed[index].ticks, 8, "beat " .. index .. " holds its eight authored ticks")
    if index > 1 then
      Assert.equal(
        beatStartTicks[index] - beatStartTicks[index - 1],
        8,
        "beat " .. index .. " starts exactly when beat " .. (index - 1) .. " completes"
      )
    end
  end
  local slot = assert(thirdSlot, "the wipe sequence ran its beats before retiring")
  for index = 1, 7 do
    local effect = assert(slot.effects["wipe-beat-" .. index], "beat " .. index .. " started its own completion")
    Assert.isTrue(effect.done, "beat " .. index .. " completed on its own eighth tick")
  end
  movie:dispose()
  Assert.equal(liveHandles(graphics), 0, "the seven-beat movie releases every handle")
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
local function mixedChannel(top, under, firstWeight, secondWeight)
  return math.min(31, math.floor((top * math.min(firstWeight, 16) + under * math.min(secondWeight, 16)) / 16))
end

-- Source step-clock first/second coefficient pair: the raw step counts
-- floor(elapsed*31/ticks) capped at 31, the direction selects which end
-- starts full, and each side saturates independently at sixteen.
---@param elapsed integer elapsed source ticks
---@param ticks integer authored duration
---@param direction integer retail blend direction
---@return integer first coefficient, integer second coefficient
local function sourceCoefficients(elapsed, ticks, direction)
  local ev = math.min(31, math.floor(elapsed * 31 / ticks))
  if direction == 0 then
    return math.min(ev, 16), math.min(31 - ev, 16)
  end
  return math.min(31 - ev, 16), math.min(ev, 16)
end

---@param graphics table fake graphics namespace
---@param name string shader uniform name
---@return unknown[] every value sent under that name, in send order
local function shaderSends(graphics, name)
  local found = {}
  for _, shader in ipairs(graphics.shaders) do
    for _, send in ipairs(shader.sends) do
      if send.name == name then
        found[#found + 1] = send.value
      end
    end
  end
  return found
end

function T.independent_weights_mix_raw_pairs_without_a_global_alpha()
  Assert.equal(mixedChannel(31, 31, 16, 16), 31, "two saturated weights clamp instead of doubling")
  Assert.equal(mixedChannel(31, 0, 15, 16), 29, "the lower weight still contributes beside a saturated upper weight")
  Assert.equal(mixedChannel(31, 31, 15, 16), 31, "near-saturated pairs exceed any complementary single-weight mix")
  Assert.equal(mixedChannel(31, 0, 0, 16), 0, "a zero first weight shows the raw under pixel")
  local first, second = sourceCoefficients(15, 31, 0)
  Assert.equal(first, 15, "the opening direction counts the first side up from zero")
  Assert.equal(second, 16, "the second side saturates independently of the first")
  local root = sceneRoot(1)
  local backImage = root .. "layers/dual-back.png"
  local midImage = root .. "layers/dual-mid.png"
  local frontImage = root .. "layers/dual-front.png"
  local scenes, cacheFs = packWithSceneAt(
    compositeManifest(
      1,
      {
        layer(2, backImage, 256, 192, 2),
        layer(1, midImage, 256, 192, 1),
        layer(0, frontImage, 256, 192, 0),
      },
      { layer(0, root .. "layers/dual-lower.png", 256, 192) },
      { spriteClip(root .. "sprites/clip0.g4sprite", { stillFrame() }) },
      { { id = "hold", events = { 1, 2, 3, 4 }, ["until"] = { kind = "duration", ticks = 40 } } },
      {
        {
          op = "setBlend",
          stepId = "hold",
          atStepTick = 0,
          engine = "main",
          firstMask = 1,
          secondMask = 2,
          direction = 0,
          effect = "dual-cross",
          ticks = 31,
        },
        { op = "enableSkip", stepId = "hold", atStepTick = 10 },
        { op = "waitTicks", stepId = "hold", atStepTick = 0, ticks = 40 },
        { op = "finish", stepId = "hold", atStepTick = 40 },
      }
    ),
    1
  )
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  for _ = 1, 15 do
    movie:updateFixed()
  end
  movie:draw()
  Assert.equal(#graphics.shaders, 2, "the compositor owns exactly two private shaders")
  local firstWeights = shaderSends(graphics, "eva")
  local secondWeights = shaderSends(graphics, "evb")
  Assert.isTrue(
    #firstWeights > 0 and #secondWeights > 0,
    "both source weights reach the compositor as separate uniforms"
  )
  local eva, evb = firstWeights[#firstWeights], secondWeights[#secondWeights]
  Assert.near(evb / eva, 16 / 15, 0.001, "the pair stays independently saturated instead of complementary")
  local firstMasks = shaderSends(graphics, "firstMask")
  local secondMasks = shaderSends(graphics, "secondMask")
  Assert.isTrue(#firstMasks > 0, "the first plane mask reaches the compositor")
  Assert.equal(firstMasks[#firstMasks], 1, "the first plane mask selects the top plane")
  Assert.isTrue(#secondMasks > 0, "the second plane mask reaches the compositor")
  Assert.equal(secondMasks[#secondMasks], 2, "the second plane mask selects the raw under plane")
  -- Planes rasterize with their native colors; only the compositor mixes.
  for _, staged in ipairs({
    { image = frontImage, label = "top" },
    { image = midImage, label = "middle" },
    { image = backImage, label = "back" },
  }) do
    local handle = assert(movie.current.imageByPath[staged.image], "the " .. staged.label .. " plane is staged")
    local draws = compositorDrawsOf(graphics, movie, handle, 0)
    Assert.isTrue(#draws > 0, "the " .. staged.label .. " plane paints into the compositor")
    for _, draw in ipairs(draws) do
      Assert.equal(draw.color[1], 1, "the " .. staged.label .. " plane keeps its native red")
      Assert.equal(draw.color[2], 1, "the " .. staged.label .. " plane keeps its native green")
      Assert.equal(draw.color[3], 1, "the " .. staged.label .. " plane keeps its native blue")
      Assert.equal(draw.color[4], 1, "the " .. staged.label .. " plane carries no global alpha")
    end
  end
  local roleTargets = { [movie.mainCanvas] = true, [movie.subCanvas] = true }
  local compositorDraws = 0
  for index = 1, #graphics.draws do
    local target = graphics.drawCanvases[index].canvas
    if target ~= nil and not roleTargets[target] then
      compositorDraws = compositorDraws + 1
    end
  end
  Assert.isTrue(compositorDraws > 0, "plane passes route through fixed compositor targets")
  movie:dispose()
  Assert.equal(liveHandles(graphics), 0, "the dual-weight movie releases every handle")
end

function T.masked_pairs_keep_raw_under_planes_with_sprites_and_windows()
  local root = sceneRoot(1)
  local backImage = root .. "layers/masked-back.png"
  local midImage = root .. "layers/masked-mid.png"
  local frontImage = root .. "layers/masked-front.png"
  local probeClip = root .. "sprites/probe.g4sprite"
  local scenes, cacheFs = packWithSceneAt(
    compositeManifest(
      1,
      {
        layer(2, backImage, 256, 192, 2),
        layer(1, midImage, 256, 192, 1),
        layer(0, frontImage, 256, 192, 0),
      },
      { layer(0, root .. "layers/masked-lower.png", 256, 192) },
      { spriteClip(probeClip, { stillFrame() }) },
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
          effect = "masked-cross",
          ticks = 31,
        },
        {
          op = "setSpriteClip",
          stepId = "hold",
          atStepTick = 0,
          instanceId = "probe",
          engine = "main",
          x = 120,
          y = 80,
          drawOrder = 0,
          objPriority = 1,
          clipId = probeClip,
          animate = true,
        },
        {
          op = "spriteVisible",
          stepId = "hold",
          atStepTick = 0,
          instanceId = "probe",
          engine = "main",
          x = 120,
          y = 80,
          drawOrder = 0,
          visible = true,
        },
        windowEvent("hold", 0, "main", windowRect(128, 0, 255, 191), windowRect(128, 0, 255, 191), 40, 23, 22),
        { op = "enableSkip", stepId = "hold", atStepTick = 10 },
        { op = "waitTicks", stepId = "hold", atStepTick = 0, ticks = 40 },
        { op = "finish", stepId = "hold", atStepTick = 40 },
      }
    ),
    1
  )
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  for _ = 1, 15 do
    movie:updateFixed()
  end
  movie:draw()
  Assert.equal(#graphics.shaders, 2, "the masked pair routes through the two compositor shaders")
  local planeIds = shaderSends(graphics, "planeId")
  local seen = {}
  for _, planeId in ipairs(planeIds) do
    seen[planeId] = true
  end
  Assert.isTrue(seen[0], "the compositor rasterizes the top background plane")
  Assert.isTrue(seen[4], "the compositor rasterizes the sprite plane separately")
  local firstMasks = shaderSends(graphics, "firstMask")
  Assert.isTrue(#firstMasks > 0, "the combined first mask reaches the compositor")
  Assert.equal(firstMasks[#firstMasks], 17, "top background and sprite stay selected together")
  local secondMasks = shaderSends(graphics, "secondMask")
  Assert.isTrue(#secondMasks > 0, "the second mask reaches the compositor")
  Assert.equal(secondMasks[#secondMasks], 2, "only the middle plane stays eligible underneath")
  local firstWeights = shaderSends(graphics, "eva")
  local secondWeights = shaderSends(graphics, "evb")
  Assert.isTrue(#firstWeights > 0 and #secondWeights > 0, "the masked pair keeps both independent weights")
  Assert.near(
    secondWeights[#secondWeights] / firstWeights[#firstWeights],
    16 / 15,
    0.001,
    "windowed pairs still saturate independently instead of complementing"
  )
  local spriteHandle = assert(movie.current.imageByPath[probeClip], "the probe sprite is staged")
  local spriteDraws = compositorDrawsOf(graphics, movie, spriteHandle, 0)
  Assert.isTrue(#spriteDraws > 0, "the sprite paints where its window allows")
  for _, draw in ipairs(spriteDraws) do
    Assert.equal(draw.color[4], 1, "the sprite carries no global alpha into the compositor")
  end
  local frontHandle = assert(movie.current.imageByPath[frontImage], "the top plane is staged")
  for _, draw in ipairs(compositorDrawsOf(graphics, movie, frontHandle, 0)) do
    Assert.equal(draw.color[4], 1, "the windowed top plane carries no global alpha")
  end
  Assert.isTrue(
    #compositorScissors(graphics, movie, 0) > 0,
    "the source window still clips planes around the compositor"
  )
  movie:dispose()
  Assert.equal(liveHandles(graphics), 0, "the masked movie releases every handle")
end

---@param graphics table fake graphics namespace
---@param movie table player owning the current slot
---@param spriteImages table<string, boolean> staged sprite clip images to exclude
---@param baseline integer only draws after this draw index
---@return table[] draws carrying a viewport quad on a non-sprite image
local function backgroundQuadDraws(graphics, movie, spriteImages, baseline)
  local found = {}
  for index = (baseline or 0) + 1, #graphics.draws do
    local draw = graphics.draws[index]
    if draw.quad ~= nil and not spriteImages[draw.image] then
      found[#found + 1] = draw
    end
  end
  return found
end

-- Wrapped backgrounds paint as plain translated image copies under the
-- active window scissor: repeated draws at one source tick and pans across
-- signed offsets (width-minus-one, negative one, huge, continuous drift,
-- and an alternate-size swap) allocate no background quads, while the
-- sprite atlas keeps its cached first-frame quads and the source clock
-- keeps its authored length.
function T.background_wrap_draws_issue_no_new_quads_across_repeats_and_pans()
  local root = sceneRoot(2)
  local baseImage = root .. "layers/quad-base.png"
  local altImage = root .. "layers/quad-alt.png"
  local tallImage = root .. "layers/quad-tall.png"
  local groundImage = root .. "layers/quad-ground.png"
  local heroClip = root .. "sprites/quad-hero.g4sprite"
  local scenes, cacheFs = packWithSceneAt(
    compositeManifest(
      2,
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
        layer(1, tallImage, 256, 192),
        layer(2, groundImage, 256, 512),
      },
      { layer(0, groundImage, 256, 192) },
      { spriteClip(heroClip, { stillFrame() }) },
      { { id = "pan", events = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }, ["until"] = { kind = "duration", ticks = 60 } } },
      {
        {
          op = "setScroll",
          stepId = "pan",
          atStepTick = 0,
          engine = "main",
          bgSlot = 0,
          dx = -511,
          dy = -1,
          ticks = 0,
        },
        {
          op = "setScroll",
          stepId = "pan",
          atStepTick = 0,
          engine = "main",
          bgSlot = 1,
          dx = 255,
          dy = 191,
          ticks = 0,
        },
        {
          op = "setScroll",
          stepId = "pan",
          atStepTick = 0,
          engine = "main",
          bgSlot = 2,
          dx = 100000,
          dy = -100001,
          ticks = 0,
        },
        { op = "setScroll", stepId = "pan", atStepTick = 0, engine = "sub", bgSlot = 0, dx = 0, dy = -32, ticks = -1 },
        windowEvent("pan", 0, "main", windowRect(0, 0, 127, 191), windowRect(128, 0, 255, 191), 60, 19, 19),
        {
          op = "setSpriteClip",
          stepId = "pan",
          atStepTick = 0,
          instanceId = "hero",
          engine = "main",
          x = 32,
          y = 64,
          drawOrder = 1,
          objPriority = 1,
          clipId = heroClip,
          animate = true,
        },
        {
          op = "spriteVisible",
          stepId = "pan",
          atStepTick = 0,
          instanceId = "hero",
          engine = "main",
          x = 32,
          y = 64,
          drawOrder = 1,
          visible = true,
        },
        {
          op = "setLayer",
          stepId = "pan",
          atStepTick = 30,
          engine = "main",
          bgSlot = 0,
          image = altImage,
          visible = true,
          priority = 0,
        },
        { op = "waitTicks", stepId = "pan", atStepTick = 0, ticks = 60 },
        { op = "finish", stepId = "pan", atStepTick = 0 },
      }
    ),
    2
  )
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  enterScene(movie, 2)
  -- The newly entered case first runs on the following update: its entry
  -- programs dispatch there, and the continuous drift advances at once.
  movie:updateFixed()
  local slot = assert(movie.current, "the running movie owns its current slot")
  Assert.equal(slot.backgrounds.main[0].scrollX, -511, "the base layer lands on its width-minus-one offset")
  Assert.equal(slot.backgrounds.main[0].scrollY, -1, "the base layer lands on its negative-one offset")
  Assert.equal(slot.backgrounds.main[1].scrollX, 255, "the tall layer lands on its width-minus-one offset")
  Assert.equal(slot.backgrounds.main[1].scrollY, 191, "the tall layer lands on its height-minus-one offset")
  Assert.equal(slot.backgrounds.main[2].scrollX, 100000, "the ground layer lands on its huge offset")
  Assert.equal(slot.backgrounds.main[2].scrollY, -100001, "the ground layer lands on its huge negative offset")
  Assert.equal(slot.backgrounds.sub[0].scrollX, 0, "the sub drift holds its horizontal origin")
  Assert.equal(slot.backgrounds.sub[0].scrollY, -32, "the sub drift advances on its dispatch update")
  local spriteImages = {}
  for _, clip in ipairs(scenes[2].spriteClips) do
    spriteImages[slot.imageByPath[clip.id]] = true
  end
  -- The warm draw caches the sprite atlas frame; sprite quads stay
  -- legitimate, background quads never are.
  movie:draw()
  local spriteQuads = 0
  for _, draw in ipairs(graphics.draws) do
    if draw.quad ~= nil and spriteImages[draw.image] then
      spriteQuads = spriteQuads + 1
    end
  end
  Assert.isTrue(spriteQuads > 0, "the first frame still caches its sprite atlas quad")
  local baseline = #graphics.draws
  for _ = 1, 5 do
    movie:draw()
  end
  Assert.equal(
    #backgroundQuadDraws(graphics, movie, spriteImages, baseline),
    0,
    "repeated draws at one source tick create no background quads"
  )
  Assert.equal(slot.backgrounds.main[0].scrollX, -511, "repeated host draws never resample the clock")
  Assert.equal(slot.backgrounds.sub[0].scrollX, 0, "repeated host draws never advance the drift")
  -- Background layers still paint on every repeated draw, only without quads.
  local painted = 0
  for index = baseline + 1, #graphics.draws do
    local draw = graphics.draws[index]
    if slot.imageByPath[baseImage] == draw.image or slot.imageByPath[tallImage] == draw.image then
      painted = painted + 1
      Assert.isTrue(draw.quad == nil, "each repeated background draw carries no viewport quad")
    end
  end
  Assert.isTrue(painted > 0, "repeated draws still paint the wrapped backgrounds")
  -- Pans, the alternate-size swap, and the window slices cross many
  -- scissor regions without allocating.
  for _ = 1, 35 do
    movie:updateFixed()
    movie:draw()
  end
  Assert.equal(
    #backgroundQuadDraws(graphics, movie, spriteImages, baseline),
    0,
    "pans, the alternate swap, and window slices create no background quads"
  )
  local swapped = assert(movie.current, "the running movie owns its current slot")
  Assert.equal(swapped.backgrounds.main[0].width, 256, "the sampled extent follows the newly selected image")
  Assert.equal(swapped.backgrounds.main[0].height, 192, "the sampled extent follows the newly selected image")
  Assert.equal(movie:sceneNumber(), 2, "the pan step still holds its authored duration")
  Assert.isFalse(movie:isFinished(), "the pan step never finishes the movie early")
  playthrough(movie, graphics, 5000)
  movie:dispose()
  Assert.equal(liveHandles(graphics), 0, "the wrapped movie releases every handle")
end

-- Starter particle replay follows the retail software particle library:
-- a source-seeded congruential stream drives placement, velocity, scale,
-- rotation, and lifespan draws; per-tick life rates index the staged
-- scale/color/alpha blocks; emitters retire only after their particles
-- and children expire. Fixtures below mirror the normalized compiled
-- shape with small synthetic values, never extracted bytes.

---@param id integer source emitter id
---@param group string starter group owning the emitter
---@param overrides table<string, unknown>|nil top-level record overrides
---@return table synthetic normalized starter emitter record
local function splEmitter(id, group, overrides)
  local root = sceneRoot(4)
  local record = {
    id = id,
    group = group,
    emitterLife = 30,
    particleLife = 30,
    startOffset = 0,
    generation = { countFx = 4096, interval = 1 },
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
    velocityFx = { pos = 0, axis = 0 },
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
  for key, value in pairs(overrides or {}) do
    record[key] = value
  end
  return record
end

-- A quiet emitter that never spawns: zero generation keeps the starter
-- group complete while the test observes its siblings. Short lifespans
-- retire it promptly so the group run measures the observed emitter.
local function quietEmitter(id, group, life)
  return splEmitter(id, group, {
    generation = { countFx = 0, interval = 1 },
    emitterLife = life or 30,
    particleLife = life or 30,
  })
end

---@param build fun(id: integer, group: string): table scene-4 emitter builder
---@return table[] scenes, table cacheFs
local function splPack(build)
  local raw = {}
  for sceneNumber = 1, 5 do
    raw[sceneNumber] = manifestFor(sceneNumber, build)
  end
  local cacheFs = stubCache(raw)
  local scenes = {}
  for sceneNumber = 1, 5 do
    local loaded, err = StartupAssetCache.loadOpeningScene(cacheFs, sceneNumber, VERSION_ID)
    Assert.notNil(loaded, "synthetic scene " .. sceneNumber .. " passes the strict reader: " .. tostring(err))
    scenes[sceneNumber] = loaded
  end
  return scenes, cacheFs
end

-- Advances the movie to the starter-emitter case of scene 4 and runs its
-- first generation tick, so the grass runtime exists with newborn state.
---@param movie table running movie
---@param graphics table fake graphics host
local function reachStarterCase(movie, graphics)
  local ticks = 0
  while movie:sceneNumber() < 4 and ticks < 20000 do
    movie:updateFixed()
    movie:draw()
    ticks = ticks + 1
  end
  Assert.equal(movie:sceneNumber(), 4, "playback reaches the starter scene")
  ticks = 0
  while #assert(movie.current, "the running movie owns its current slot").emitters == 0 and ticks < 20000 do
    movie:updateFixed()
    movie:draw()
    ticks = ticks + 1
  end
  Assert.isTrue(
    #assert(movie.current, "the running movie owns its current slot").emitters > 0,
    "the starter case dispatches its emitters"
  )
end

---@param movie table running movie
---@return table live emitter runtime for source id 6
local function grassRuntime(movie)
  local slot = assert(movie.current, "the running movie owns its current slot")
  for _, runtime in ipairs(slot.emitters) do
    if runtime.id == 6 then
      return runtime
    end
  end
  error("the grass emitter never started", 0)
end

function T.starter_rng_stream_matches_the_source_congruential_generator()
  local function build(id, group)
    if id ~= 6 then
      return quietEmitter(id, group)
    end
    return splEmitter(id, group, {
      initPosType = 0,
      particleLife = 40,
      lifeRandom = 255,
    })
  end
  local scenes, cacheFs = splPack(build)
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  reachStarterCase(movie, graphics)
  local runtime = grassRuntime(movie)
  Assert.equal(#runtime.particles, 1, "the point emitter spawns one particle")
  -- Seed zero opens the retail stream at the additive constant, and the
  -- seventh draw (after placement, velocity, and scale draws) randomizes
  -- the forty-tick lifespan down to six ticks.
  Assert.equal(runtime.particles[1].life, 6, "the lifespan follows the seeded stream")
  local replayScenes, replayCacheFs = splPack(build)
  local replayGraphics = movieGraphics()
  local replay = openMovie(replayScenes, replayCacheFs, replayGraphics)
  reachStarterCase(replay, replayGraphics)
  replay:updateFixed()
  local replayRuntime = grassRuntime(replay)
  Assert.equal(
    replayRuntime.particles[1].life,
    runtime.particles[1].life,
    "a replayed seed randomizes the same lifespan"
  )
  movie:dispose()
  replay:dispose()
end

function T.starter_life_rate_curves_follow_staged_animation_blocks()
  local animations = {
    scale = { startFx = 2048, normalFx = 4096, finishFx = 8192, inTick = 64, outTick = 192 },
    color = {
      startRgb = { r = 31, g = 0, b = 0 },
      endRgb = { r = 0, g = 0, b = 31 },
      inTick = 10,
      peakTick = 100,
      outTick = 200,
      interpolate = true,
    },
    -- The flicker factor scales every level by 255/256 even at zero magnitude.
    alpha = { start = 5, normal = 20, finish = 10, flick = 0, inTick = 30, outTick = 220 },
  }
  local function build(id, group)
    if id ~= 6 then
      return quietEmitter(id, group)
    end
    return splEmitter(id, group, {
      emitterLife = 1,
      particleLife = 5,
      animations = animations,
    })
  end
  local scenes, cacheFs = splPack(build)
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  reachStarterCase(movie, graphics)
  movie:updateFixed()
  movie:draw()
  local first = grassRuntime(movie).particles[1]
  Assert.notNil(first, "the single particle survives its second tick")
  Assert.equal(first.age, 2, "the particle ages once per source tick")
  -- Life rate 51 indexes the entry slope of every staged block.
  Assert.equal(first.animScale, 3680, "the scale follows its entry slope")
  Assert.deepEqual(first.colorRgb, { r = 31, g = 14, b = 14 }, "the color follows its entry slope")
  Assert.equal(first.animAlpha, 19, "the alpha holds its flicker-scaled normal level")
  Assert.equal(first.baseScale, 4080, "the base scale keeps its source randomization factor")
  movie:updateFixed()
  movie:updateFixed()
  local fourth = grassRuntime(movie).particles[1]
  Assert.notNil(fourth, "the single particle survives its fourth tick")
  -- Life rate 153 holds the normal scale and descends the exit color slope.
  Assert.equal(fourth.animScale, 4096, "the scale holds its normal stage")
  Assert.deepEqual(fourth.colorRgb, { r = 15, g = 15, b = 31 }, "the color follows its exit slope")
  Assert.equal(fourth.animAlpha, 19, "the alpha still holds its flicker-scaled normal level")
  movie:dispose()
end

function T.starter_emission_accumulates_fractional_generation_counts()
  local function build(id, group)
    if id ~= 6 then
      return quietEmitter(id, group)
    end
    return splEmitter(id, group, {
      emitterLife = 7,
      particleLife = 30,
      generation = { countFx = 20480, interval = 3 },
    })
  end
  local scenes, cacheFs = splPack(build)
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  reachStarterCase(movie, graphics)
  -- Generation fires on ages 0, 3, and 6 only: three bursts of five.
  for _ = 1, 10 do
    movie:updateFixed()
    movie:draw()
  end
  Assert.equal(#grassRuntime(movie).particles, 15, "fractional counts accumulate without drift")
  movie:dispose()
end

function T.starter_run_waits_for_child_particles_to_retire()
  local child = {
    useScaleAnm = false,
    useAlphaAnm = false,
    followEmitter = false,
    useChildColor = true,
    childColor = { r = 31, g = 0, b = 0 },
    drawType = 0,
    initVelRandom = 0,
    scaleEnd = 1.0,
    life = 5,
    velRatio = 0,
    sclRatio = 0,
    genNum = 1,
    genStart = 0,
    genInterval = 1,
    texNo = 6,
    textureImage = sceneRoot(4) .. "particles/texture6.png",
    texRepeat = { s = 0, t = 0 },
  }
  local function build(id, group)
    if id ~= 6 then
      return quietEmitter(id, group, 2)
    end
    return splEmitter(id, group, { emitterLife = 2, particleLife = 2, child = child })
  end
  local scenes, cacheFs = splPack(build)
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  reachStarterCase(movie, graphics)
  for _ = 1, 6 do
    movie:updateFixed()
    movie:draw()
  end
  local runtime = grassRuntime(movie)
  Assert.isTrue(#runtime.children > 0, "parents spawn children every tick")
  Assert.deepEqual(runtime.children[1].colorRgb, { r = 31, g = 0, b = 0 }, "children carry their own color record")
  Assert.equal(movie:sceneNumber(), 4, "the run outlives its retired parents while children live")
  for _ = 1, 20 do
    movie:updateFixed()
    movie:draw()
  end
  Assert.equal(movie:sceneNumber(), 5, "the run completes once every child retires")
  movie:dispose()
end

-- Signed 32-bit arithmetic shift: the retail damping step wraps the raw
-- product to 32 bits, then shifts right keeping the sign, which floors
-- negative quotients instead of truncating them toward zero.
---@param value integer raw pre-shift product
---@param shift integer right-shift amount
---@return integer shifted raw value
local function arithShift32(value, shift)
  local wrapped = value % 4294967296
  if wrapped >= 2147483648 then
    wrapped = wrapped - 4294967296
  end
  return math.floor(wrapped / (2 ^ shift))
end

-- Source damping oracle: the signed raw velocity times the staged
-- coefficient, shifted back to 1/4096 units with sign preserved.
---@param rawVel integer raw velocity in 1/4096 units
---@param airResist integer staged air resistance 0..255
---@return integer damped raw velocity
local function dampOracle(rawVel, airResist)
  return arithShift32(rawVel * (airResist + 384), 9)
end

-- C integer division truncates toward zero, matching the retail scale
-- slopes when the numerator goes negative.
---@param numerator integer
---@param denominator integer
---@return integer truncated quotient
local function cdivOracle(numerator, denominator)
  assert(denominator ~= 0, "the test oracle never divides by zero")
  local quotient = numerator / denominator
  if quotient >= 0 then
    return math.floor(quotient)
  end
  return math.ceil(quotient)
end

-- The retail congruential stream step, mirroring the production slot
-- stream so the test can predict the exact draws a step consumes.
local RNG_LO, RNG_HI, RNG_INC = 0xF715, 0x5EED, 0x1B0CB173
---@param seed integer stream state before the draw
---@return integer stream state after one draw
local function rngStep(seed)
  local lo = seed % 65536
  local hi = math.floor((seed - lo) / 65536)
  local low = lo * RNG_LO
  local mid = lo * RNG_HI + hi * RNG_LO
  return (low + (mid % 65536) * 65536 + RNG_INC) % 4294967296
end

function T.starter_subunit_velocities_keep_fractional_damping_precision()
  local cases = {
    { raw = 1066 },
    { raw = -1066 },
    { raw = 381 },
  }
  local function build(id, group)
    if id ~= 6 then
      return quietEmitter(id, group)
    end
    return splEmitter(id, group, { emitterLife = 30, particleLife = 30, airResist = 128 })
  end
  local scenes, cacheFs = splPack(build)
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  reachStarterCase(movie, graphics)
  movie:updateFixed()
  local runtime = grassRuntime(movie)
  for _, case in ipairs(cases) do
    local particle = assert(runtime.particles[1], "the point emitter holds its particle")
    particle.x, particle.y, particle.z = 0, 0, 0
    particle.vx, particle.vy, particle.vz = case.raw / 4096, 0, 0
    particle.age, particle.life = 0, 30
    movie:updateFixed()
    local expected = dampOracle(case.raw, 128)
    Assert.equal(
      particle.vx * 4096,
      expected,
      "raw velocity " .. case.raw .. " survives signed damping instead of collapsing to whole units"
    )
    Assert.equal(
      particle.x * 4096,
      expected,
      "raw velocity " .. case.raw .. " integrates its fractional step into position"
    )
  end
  movie:dispose()
end

function T.starter_fields_apply_after_damping_with_raw_child_spread()
  local orderCases = {
    { velRaw = 4096, accRaw = 2048, airResist = 63 },
    { velRaw = -2048, accRaw = 1024, airResist = 63 },
  }
  local function build(id, group)
    if id ~= 6 then
      return quietEmitter(id, group)
    end
    return splEmitter(id, group, {
      emitterLife = 30,
      particleLife = 30,
      airResist = 63,
      fields = { { kind = "gravity", magnitude = { x = 0.5, y = 0, z = 0 } } },
    })
  end
  local scenes, cacheFs = splPack(build)
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  reachStarterCase(movie, graphics)
  movie:updateFixed()
  local runtime = grassRuntime(movie)
  local record = runtime.record --[[@as table<string, unknown>]]
  for _, case in ipairs(orderCases) do
    local particle = assert(runtime.particles[1], "the point emitter holds its particle")
    particle.x, particle.y, particle.z = 0, 0, 0
    particle.vx, particle.vy, particle.vz = case.velRaw / 4096, 0, 0
    particle.age, particle.life = 0, 30
    record.airResist = case.airResist
    local fields = record.fields --[[@as table<string, unknown>[] ]]
    local gravity = fields[1] --[[@as table<string, unknown>]]
    gravity.magnitude = { x = case.accRaw / 4096, y = 0, z = 0 }
    movie:updateFixed()
    local expected = dampOracle(case.velRaw, case.airResist) + case.accRaw
    Assert.equal(
      particle.vx * 4096,
      expected,
      "field acceleration lands after damping for raw velocity " .. case.velRaw
    )
    Assert.equal(
      particle.x * 4096,
      expected,
      "the damped-then-pushed velocity integrates for raw velocity " .. case.velRaw
    )
  end
  movie:dispose()
end

function T.starter_child_spread_keeps_raw_precision_with_three_stream_draws()
  local spreadRaw = 381
  local child = {
    useScaleAnm = false,
    useAlphaAnm = false,
    followEmitter = false,
    useChildColor = true,
    childColor = { r = 31, g = 0, b = 0 },
    drawType = 0,
    initVelRandom = spreadRaw / 4096,
    scaleEnd = 1.0,
    life = 30,
    velRatio = 0,
    sclRatio = 30,
    genNum = 1,
    genStart = 0,
    genInterval = 1,
    texNo = 3,
    textureImage = sceneRoot(4) .. "particles/texture3.png",
    texRepeat = { s = 0, t = 0 },
  }
  local function build(id, group)
    if id ~= 6 then
      return quietEmitter(id, group)
    end
    return splEmitter(id, group, { emitterLife = 1, particleLife = 30, child = child })
  end
  local scenes, cacheFs = splPack(build)
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  reachStarterCase(movie, graphics)
  movie:updateFixed()
  local runtime = grassRuntime(movie)
  Assert.isTrue(#runtime.children > 0, "the parent spawns children every tick")
  runtime.children = {}
  local slot = assert(movie.current, "the running movie owns its current slot")
  local streamBefore = slot.rng --[[@as integer]]
  movie:updateFixed()
  Assert.equal(#runtime.children, 1, "the parent spawns exactly one more child")
  local streamAfter = slot.rng --[[@as integer]]
  Assert.equal(streamAfter, rngStep(rngStep(rngStep(streamBefore))), "one child consumes exactly three stream draws")
  local first = rngStep(streamBefore)
  local second = rngStep(first)
  local third = rngStep(second)
  local draws = {
    math.floor(first / 8388608),
    math.floor(second / 8388608),
    math.floor(third / 8388608),
  }
  local spawned = runtime.children[1]
  local velocities = { spawned.vx, spawned.vy, spawned.vz }
  for axis = 1, 3 do
    local expected = math.floor((spreadRaw * draws[axis] - spreadRaw * 256) / 256)
    Assert.equal(
      velocities[axis] --[[@as number]] * 4096,
      expected,
      "child axis " .. axis .. " keeps its fractional raw spread"
    )
  end
  movie:dispose()
end

function T.starter_child_scale_interpolates_raw_unity_curve_and_paints_once_normalized()
  local endRaw = 5360
  local function childBlock(scaleEnd, useScaleAnm, texNo, life)
    return {
      useScaleAnm = useScaleAnm,
      useAlphaAnm = false,
      followEmitter = false,
      useChildColor = true,
      childColor = { r = 31, g = 31, b = 31 },
      drawType = 0,
      initVelRandom = 0,
      scaleEnd = scaleEnd,
      life = life,
      velRatio = 0,
      sclRatio = 63,
      genNum = 1,
      genStart = 0,
      genInterval = 1,
      texNo = texNo,
      textureImage = sceneRoot(4) .. "particles/texture" .. texNo .. ".png",
      texRepeat = { s = 0, t = 0 },
    }
  end
  local function build(id, group)
    if id == 6 then
      return splEmitter(id, group, {
        emitterLife = 1,
        particleLife = 30,
        child = childBlock(endRaw / 4096, true, 3, 7),
      })
    elseif id == 7 then
      return splEmitter(id, group, {
        emitterLife = 1,
        particleLife = 30,
        child = childBlock(2.0, false, 4, 30),
      })
    elseif id == 8 then
      return splEmitter(id, group, {
        emitterLife = 1,
        particleLife = 30,
        child = childBlock(0.5, true, 5, 30),
      })
    end
    return quietEmitter(id, group)
  end
  local scenes, cacheFs = splPack(build)
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  reachStarterCase(movie, graphics)
  movie:updateFixed()
  local slot = assert(movie.current, "the running movie owns its current slot")
  local runtimes = {}
  for _, runtime in ipairs(slot.emitters) do
    if runtime.id == 6 or runtime.id == 7 or runtime.id == 8 then
      runtimes[
        runtime.id --[[@as integer]]
      ] = runtime
    end
  end
  local animated = assert(runtimes[6], "the animated-scale emitter runs")
  local flat = assert(runtimes[7], "the fixed-scale emitter runs")
  local shrinking = assert(runtimes[8], "the shrinking-scale emitter runs")
  Assert.isTrue(#animated.children > 0, "the animated parent spawns its child")
  animated.children[1].age = 0
  flat.children[1].age = 0
  shrinking.children[1].age = 0
  local function lifeRate(age, life)
    return math.floor(age * 256 / life)
  end
  local function scaleOracle(age)
    local rate = lifeRate(age, 7)
    return endRaw + cdivOracle((endRaw - 4096) * (rate - 255), 255)
  end
  local childImage = slot.imageByPath[sceneRoot(4) .. "particles/texture3.png"]
  Assert.notNil(childImage, "the animated child texture is staged")
  local drawnSx = {}
  for age = 0, 3 do
    movie:updateFixed()
    movie:draw()
    local childParticle = animated.children[1]
    Assert.equal(childParticle.age, age + 1, "the animated child ages once per source tick")
    Assert.equal(
      childParticle.animScale,
      scaleOracle(age),
      "the animated child scale follows its life rate at age " .. age
    )
    Assert.equal(flat.children[1].animScale, 4096, "the fixed child holds unity at age " .. age)
    local shrinkingScale = shrinking.children[1].animScale --[[@as number]]
    local shrinkingRate = lifeRate(age, 30)
    Assert.equal(
      shrinkingScale,
      2048 + cdivOracle((2048 - 4096) * (shrinkingRate - 255), 255),
      "the shrinking child descends toward its end at age " .. age
    )
    if age == 0 then
      Assert.equal(childParticle.animScale, 4096, "the animated child starts at unity")
    end
    if age == 3 then
      Assert.isTrue(shrinkingScale < 4096, "the shrinking child stays below unity")
    end
    local expectX = 128
      + (
        childParticle.x --[[@as number]]
        + childParticle.ex --[[@as number]]
      ) * 24
    local expectY = 96
      - (
        childParticle.y --[[@as number]]
        + childParticle.ey --[[@as number]]
      ) * 24
    local found = nil
    for _, entry in ipairs(graphics.draws) do
      if
        entry.kind == "draw"
        and entry.image == childImage
        and entry.quad ~= nil
        and math.abs(entry.x - expectX) < 1e-6
        and math.abs(entry.y - expectY) < 1e-6
      then
        found = entry
      end
    end
    Assert.notNil(found, "the animated child paints through its own texture at age " .. age)
    drawnSx[age] = assert(found, "the animated child paints at age " .. age).sx
  end
  Assert.near(
    drawnSx[3] / drawnSx[0],
    scaleOracle(3) / scaleOracle(0),
    1e-9,
    "the painted child width follows the raw scale without a second normalization"
  )
  movie:dispose()
end

function T.starter_start_offset_gates_generation()
  local function build(id, group)
    if id ~= 6 then
      return quietEmitter(id, group)
    end
    return splEmitter(id, group, { startOffset = 3, emitterLife = 10 })
  end
  local scenes, cacheFs = splPack(build)
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  reachStarterCase(movie, graphics)
  for _ = 1, 2 do
    movie:updateFixed()
    movie:draw()
  end
  Assert.equal(#grassRuntime(movie).particles, 0, "no particle spawns before the start offset")
  movie:updateFixed()
  movie:draw()
  Assert.equal(#grassRuntime(movie).particles, 1, "generation opens on the offset tick")
  movie:dispose()
end

function T.starter_third_axis_survives_to_projection()
  local function build(id, group)
    if id ~= 6 then
      return quietEmitter(id, group)
    end
    return splEmitter(id, group, {
      initPosType = 7,
      circleAxis = 2,
      radius = 0.5,
      length = 2.0,
      emitterLife = 5,
    })
  end
  local scenes, cacheFs = splPack(build)
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  reachStarterCase(movie, graphics)
  movie:updateFixed()
  movie:draw()
  local runtime = grassRuntime(movie)
  local placed = nil
  for _, particle in ipairs(runtime.particles) do
    if placed == nil or math.abs(particle.z) > math.abs(placed.z) then
      placed = particle
    end
  end
  Assert.notNil(placed, "the volume emitter spawns its particle")
  Assert.isTrue(math.abs(placed.z) > 1e-9, "the particle keeps its depth axis")
  local px, py = 128 + placed.x * 24, 96 - placed.y * 24
  local drawn = nil
  for _, entry in ipairs(graphics.draws) do
    if
      entry.kind == "draw"
      and entry.quad ~= nil
      and math.abs(entry.x - px) < 1e-6
      and math.abs(entry.y - py) < 1e-6
    then
      drawn = entry
    end
  end
  Assert.notNil(drawn, "the particle paints through a texture quad at its projected position")
  movie:dispose()
end

function T.starter_directional_billboards_orient_along_velocity()
  local function build(id, group)
    if id ~= 6 then
      return quietEmitter(id, group)
    end
    return splEmitter(id, group, {
      initPosType = 0,
      drawType = 1,
      emitterLife = 5,
      velocityFx = { pos = 8192, axis = 0 },
    })
  end
  local scenes, cacheFs = splPack(build)
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  reachStarterCase(movie, graphics)
  movie:updateFixed()
  movie:draw()
  local runtime = grassRuntime(movie)
  local placed = assert(runtime.particles[1], "the emitter spawns its particle")
  -- The quad x-axis follows velocity cross camera-z in view space, so the
  -- drawn rotation matches the velocity perpendicular on screen.
  local expected = math.atan2(placed.vx --[[@as number]], placed.vy --[[@as number]])
  local px, py = 128 + placed.x * 24, 96 - placed.y * 24
  local drawn = nil
  for _, entry in ipairs(graphics.draws) do
    if
      entry.kind == "draw"
      and entry.quad ~= nil
      and math.abs(entry.x - px) < 1e-6
      and math.abs(entry.y - py) < 1e-6
    then
      drawn = entry
    end
  end
  Assert.notNil(drawn, "the directional particle paints through a texture quad")
  Assert.near(drawn.rotation, expected, 1e-9, "the quad orients along its velocity")
  Assert.near(drawn.sx, drawn.sy, 1e-9, "the unbiased directional quad keeps equal axes")
  movie:dispose()
end

function T.starter_pool_bounds_concurrent_particles()
  local function build(id, group)
    if id ~= 6 then
      return quietEmitter(id, group)
    end
    return splEmitter(id, group, {
      emitterLife = 30,
      particleLife = 60,
      generation = { countFx = 40960, interval = 1 },
    })
  end
  local scenes, cacheFs = splPack(build)
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  reachStarterCase(movie, graphics)
  for _ = 1, 35 do
    movie:updateFixed()
    movie:draw()
  end
  Assert.equal(#grassRuntime(movie).particles, 200, "exhaustion drops extras instead of growing")
  movie:dispose()
end

function T.starter_emitter_count_stays_within_its_scene_bound()
  -- Four sequential starter groups keep every quiet emitter alive, so the
  -- fourth start would exceed nine concurrent runtimes.
  local starts = {
    { group = "grass", emitters = { 6, 7, 8 } },
    { group = "fire", emitters = { 3, 4, 5 } },
    { group = "water", emitters = { 0, 1, 2 } },
    { group = "grass", emitters = { 6, 7, 8 } },
  }
  local raw = {}
  for sceneNumber = 1, 5 do
    raw[sceneNumber] = manifestFor(sceneNumber, quietEmitter)
  end
  local events, steps = {}, {}
  for index, start in ipairs(starts) do
    events[#events + 1] = {
      op = "startEmitters",
      stepId = "start" .. index,
      atStepTick = 0,
      group = start.group,
      emitters = start.emitters,
    }
    steps[#steps + 1] = { id = "start" .. index, events = { #events }, ["until"] = { kind = "duration", ticks = 1 } }
  end
  events[#events + 1] = { op = "waitTicks", stepId = "hold", atStepTick = 0, ticks = 5 }
  steps[#steps + 1] = { id = "hold", events = { #events }, ["until"] = { kind = "duration", ticks = 5 } }
  raw[4].timeline = { steps = steps, events = events }
  local cacheFs = stubCache(raw)
  local scenes = {}
  for sceneNumber = 1, 5 do
    local loaded, err = StartupAssetCache.loadOpeningScene(cacheFs, sceneNumber, VERSION_ID)
    Assert.notNil(loaded, "synthetic scene " .. sceneNumber .. " passes the strict reader: " .. tostring(err))
    scenes[sceneNumber] = loaded
  end
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  local ticks = 0
  while movie:sceneNumber() < 4 and ticks < 20000 do
    movie:updateFixed()
    movie:draw()
    ticks = ticks + 1
  end
  Assert.equal(movie:sceneNumber(), 4, "playback reaches the starter scene")
  -- The init call plus three entry stalls, then the three starter ticks.
  for _ = 1, 4 + 3 do
    movie:updateFixed()
    movie:draw()
  end
  local slot = assert(movie.current, "the running movie owns its current slot")
  Assert.equal(#slot.emitters, 9, "three starter groups stay live together")
  local ok, failure = pcall(function()
    for _ = 1, 3 do
      movie:updateFixed()
      movie:draw()
    end
  end)
  Assert.isFalse(ok, "a tenth concurrent emitter fails instead of growing")
  Assert.notNil(failure, "the bound reports its cause")
  movie:dispose()
end

-- Source entry mapping and engine holds are staged on acquisition:
-- every freshly acquired slot already routes main to its authored
-- screen with the authored per-engine holds, before any source tick
-- runs on it. Handoffs carry the same guarantee: the incoming slot is
-- correct while its clock still reads zero. Brightness registers are
-- engine-bound on the hardware, so the holds follow engines across
-- physical screen flips instead of sticking to one LCD.
local ENTRY_HOLDS = {
  [1] = { mainPhysical = "lower", main = "neutral", sub = "neutral" },
  [2] = { mainPhysical = "upper", main = "white", sub = "white" },
  [3] = { mainPhysical = "upper", main = "white", sub = "black" },
  [4] = { mainPhysical = "lower", main = "black", sub = "black" },
  [5] = { mainPhysical = "lower", main = "black", sub = "black" },
}

---@param sceneNumber integer retail scene position
---@return table strict synthetic opening-scene manifest with staged entry holds
local function manifestWithEntry(sceneNumber)
  local manifest = manifestFor(sceneNumber)
  local entry = assert(ENTRY_HOLDS[sceneNumber], "every scene stages its source entry holds")
  manifest.initialDisplay = {
    mainPhysical = entry.mainPhysical,
    brightness = { main = entry.main, sub = entry.sub },
  }
  return manifest
end

---@param slot table acquired scene slot
---@param sceneNumber integer retail scene position
local function checkEntryHolds(slot, sceneNumber)
  local entry = assert(ENTRY_HOLDS[sceneNumber], "every scene stages its source entry holds")
  Assert.equal(
    slot.mainPhysical,
    entry.mainPhysical,
    "scene " .. sceneNumber .. " maps main to physical " .. entry.mainPhysical .. " before its first tick"
  )
  Assert.isTrue(
    type(slot.brightness) == "table",
    "scene " .. sceneNumber .. " stages its engine holds before its first tick"
  )
  Assert.equal(
    slot.brightness.main,
    entry.main,
    "scene " .. sceneNumber .. " holds the main engine " .. entry.main
  )
  Assert.equal(
    slot.brightness.sub,
    entry.sub,
    "scene " .. sceneNumber .. " holds the sub engine " .. entry.sub
  )
end

---@return table[] scenes, table cacheFs strict five-scene pack with staged entry holds
local function entryPack()
  local raw = {}
  for sceneNumber = 1, 5 do
    raw[sceneNumber] = manifestWithEntry(sceneNumber)
  end
  local cacheFs = stubCache(raw)
  local scenes = {}
  for sceneNumber = 1, 5 do
    local loaded, err = StartupAssetCache.loadOpeningScene(cacheFs, sceneNumber, VERSION_ID)
    Assert.notNil(loaded, "synthetic scene " .. sceneNumber .. " passes the strict reader: " .. tostring(err))
    scenes[sceneNumber] = loaded
  end
  return scenes, cacheFs
end

function T.scene_slots_stage_their_source_entry_mapping_and_holds_before_the_first_tick()
  local scenes, cacheFs = entryPack()
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  checkEntryHolds(assert(movie.current, "the running movie owns its current slot"), 1)
  local prefetched = assert(movie.nextSlot, "the prefetched slot is staged before its scene starts")
  Assert.equal(prefetched.sceneNumber, 2, "the prefetched slot stages the incoming scene")
  Assert.equal(prefetched.stepElapsed, 0, "the prefetched slot has run no source tick")
  checkEntryHolds(prefetched, 2)
  for target = 2, 5 do
    local ticks = 0
    while movie:sceneNumber() < target and ticks < 20000 do
      movie:updateFixed()
      ticks = ticks + 1
    end
    Assert.equal(movie:sceneNumber(), target, "playback reaches scene " .. target)
    local slot = assert(movie.current, "the running movie owns its current slot")
    Assert.equal(slot.stepElapsed, 0, "scene " .. target .. " has not run its first tick")
    checkEntryHolds(slot, target)
  end
  movie:dispose()
end

function T.staged_sprites_stay_visible_while_the_physical_bottom_holds_black_until_its_wipe()
  local third = manifestWithEntry(3)
  local root = sceneRoot(3)
  local clipId = root .. "sprites/silver.g4sprite"
  third.spriteClips = { spriteClip(clipId, { stillFrame() }) }
  third.assets[clipId] = true
  third.timeline = {
    steps = {
      { id = "enter", events = { 1, 2, 3 }, ["until"] = { kind = "duration", ticks = 20 } },
      { id = "reveal", events = { 4, 5 }, ["until"] = { kind = "duration", ticks = 8 } },
      { id = "tail", events = { 6, 7 }, ["until"] = { kind = "duration", ticks = 2 } },
    },
    events = {
      {
        op = "setSpriteClip",
        stepId = "enter",
        atStepTick = 0,
        instanceId = "silver-silhouette",
        engine = "sub",
        x = 120,
        y = 80,
        drawOrder = 1,
        objPriority = 1,
        clipId = clipId,
        animate = true,
      },
      {
        op = "spriteVisible",
        stepId = "enter",
        atStepTick = 0,
        instanceId = "silver-silhouette",
        engine = "sub",
        x = 120,
        y = 80,
        drawOrder = 1,
        visible = true,
      },
      { op = "waitTicks", stepId = "enter", atStepTick = 0, ticks = 20 },
      { op = "circleWipe", stepId = "reveal", atStepTick = 0, engine = "sub", kind = 2, ticks = 8 },
      { op = "waitTicks", stepId = "reveal", atStepTick = 0, ticks = 8 },
      { op = "waitTicks", stepId = "tail", atStepTick = 0, ticks = 2 },
      { op = "finish", stepId = "tail", atStepTick = 2 },
    },
  }
  local raw = { manifestWithEntry(1), manifestWithEntry(2), third, manifestWithEntry(4), manifestWithEntry(5) }
  local cacheFs = stubCache(raw)
  local scenes = {}
  for sceneNumber = 1, 5 do
    local loaded, err = StartupAssetCache.loadOpeningScene(cacheFs, sceneNumber, VERSION_ID)
    Assert.notNil(loaded, "synthetic scene " .. sceneNumber .. " passes the strict reader: " .. tostring(err))
    scenes[sceneNumber] = loaded
  end
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  local ticks = 0
  while movie:sceneNumber() < 3 and ticks < 20000 do
    movie:updateFixed()
    ticks = ticks + 1
  end
  Assert.equal(movie:sceneNumber(), 3, "playback reaches the third scene")
  local entered = assert(movie.current, "the running movie owns its current slot")
  Assert.equal(entered.stepElapsed, 0, "the incoming scene has not run its first tick")
  checkEntryHolds(entered, 3)
  -- The init call plus three entry stalls hold the staged entry; the first
  -- case then stages the rival while the black bottom hold still covers it.
  for _ = 1, 4 do
    movie:updateFixed()
    Assert.equal(movie.current.stepElapsed, 0, "the init stalls run no case")
    checkEntryHolds(movie.current, 3)
  end
  movie:updateFixed()
  local staged = assert(movie.current, "the running movie owns its current slot")
  local silver = assert(staged.spriteInstances["silver-silhouette"], "the entry tick stages the rival instance")
  Assert.isTrue(silver.visible, "the rival stays staged while hidden")
  Assert.isTrue(type(staged.brightness) == "table", "the entry keeps its staged engine holds")
  Assert.equal(staged.brightness.sub, "black", "the staged rival does not lift the sub hold")
  -- The authored bottom wipe releases the hold while keeping the rival.
  local waited = 0
  while movie.current.stepIndex < 2 and waited < 200 do
    movie:updateFixed()
    waited = waited + 1
  end
  Assert.equal(movie.current.stepIndex, 2, "playback reaches the bottom reveal")
  movie:updateFixed()
  local revealed = assert(movie.current, "the running movie owns its current slot")
  Assert.isTrue(type(revealed.brightness) == "table", "the reveal keeps its staged engine holds")
  Assert.equal(revealed.brightness.sub, "neutral", "the sub wipe releases the sub hold")
  Assert.isTrue(revealed.spriteInstances["silver-silhouette"].visible, "the reveal keeps the rival staged")
  movie:dispose()
end

function T.engine_holds_follow_their_engine_across_mapping_flips_and_neutral_resets()
  local first = manifestWithEntry(1)
  first.initialDisplay = {
    mainPhysical = "upper",
    brightness = { main = "white", sub = "black" },
  }
  first.timeline = {
    steps = {
      { id = "setup", events = { 1, 2 }, ["until"] = { kind = "duration", ticks = 4 } },
      { id = "flip", events = { 3, 4 }, ["until"] = { kind = "duration", ticks = 4 } },
      { id = "reset", events = { 5, 6 }, ["until"] = { kind = "duration", ticks = 4 } },
      { id = "tail", events = { 7, 8 }, ["until"] = { kind = "duration", ticks = 2 } },
    },
    events = {
      { op = "waitTicks", stepId = "setup", atStepTick = 0, ticks = 4 },
      { op = "enableSkip", stepId = "setup", atStepTick = 1 },
      { op = "setScreenMapping", stepId = "flip", atStepTick = 0, mainPhysical = "lower" },
      { op = "waitTicks", stepId = "flip", atStepTick = 0, ticks = 4 },
      { op = "setBrightness", stepId = "reset", atStepTick = 0, engine = "main", value = "neutral" },
      { op = "waitTicks", stepId = "reset", atStepTick = 0, ticks = 4 },
      { op = "waitTicks", stepId = "tail", atStepTick = 0, ticks = 2 },
      { op = "finish", stepId = "tail", atStepTick = 0 },
    },
  }
  local raw = { first, manifestWithEntry(2), manifestWithEntry(3), manifestWithEntry(4), manifestWithEntry(5) }
  local cacheFs = stubCache(raw)
  local scenes = {}
  for sceneNumber = 1, 5 do
    local loaded, err = StartupAssetCache.loadOpeningScene(cacheFs, sceneNumber, VERSION_ID)
    Assert.notNil(loaded, "synthetic scene " .. sceneNumber .. " passes the strict reader: " .. tostring(err))
    scenes[sceneNumber] = loaded
  end
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  local setup = assert(movie.current, "the running movie owns its current slot")
  Assert.equal(setup.mainPhysical, "upper", "the scene maps main to physical upper before its first tick")
  Assert.isTrue(type(setup.brightness) == "table", "the scene stages its engine holds before its first tick")
  Assert.equal(setup.brightness.main, "white", "the scene holds the main engine white")
  Assert.equal(setup.brightness.sub, "black", "the scene holds the sub engine black")
  local waited = 0
  while movie.current.stepIndex < 2 and waited < 200 do
    movie:updateFixed()
    waited = waited + 1
  end
  Assert.equal(movie.current.stepIndex, 2, "playback reaches the authored flip")
  movie:updateFixed()
  local flipped = assert(movie.current, "the running movie owns its current slot")
  Assert.equal(flipped.mainPhysical, "lower", "the authored flip moves the main engine")
  Assert.isTrue(type(flipped.brightness) == "table", "the flip keeps the staged engine holds")
  Assert.equal(flipped.brightness.main, "white", "the flip keeps the white hold on the main engine")
  Assert.equal(flipped.brightness.sub, "black", "the flip keeps the black hold on the sub engine")
  waited = 0
  while movie.current.stepIndex < 3 and waited < 200 do
    movie:updateFixed()
    waited = waited + 1
  end
  Assert.equal(movie.current.stepIndex, 3, "playback reaches the authored reset")
  movie:updateFixed()
  local reset = assert(movie.current, "the running movie owns its current slot")
  Assert.isTrue(type(reset.brightness) == "table", "the reset keeps the staged engine holds")
  Assert.equal(reset.brightness.main, "neutral", "the authored reset clears only the main hold")
  Assert.equal(reset.brightness.sub, "black", "the authored reset keeps the sub hold")
  movie:dispose()
end

-- Brightness resets name their engine directly: with the main engine
-- flipped below, resetting the sub engine clears only the sub hold
-- while the main hold survives, so the sparkle beat can free the main
-- output without lifting the black upper screen.
function T.engine_brightness_reset_clears_only_its_named_engine()
  local first = manifestWithEntry(1)
  first.initialDisplay = {
    mainPhysical = "lower",
    brightness = { main = "black", sub = "black" },
  }
  first.timeline = {
    steps = {
      { id = "fade", events = { 1 }, ["until"] = { kind = "effect", effect = "close-both" } },
      { id = "sparkle", events = { 2, 3, 4 }, ["until"] = { kind = "duration", ticks = 2 } },
    },
    events = {
      {
        op = "setFade",
        stepId = "fade",
        atStepTick = 0,
        scope = "both",
        mode = "brightness",
        color = "black",
        direction = "out",
        ticks = 2,
        terminal = "hold",
        effect = "close-both",
      },
      { op = "setBrightness", stepId = "sparkle", atStepTick = 0, engine = "main", value = "neutral" },
      { op = "enableSkip", stepId = "sparkle", atStepTick = 1 },
      { op = "waitTicks", stepId = "sparkle", atStepTick = 0, ticks = 2 },
    },
  }
  local raw = { first, manifestWithEntry(2), manifestWithEntry(3), manifestWithEntry(4), manifestWithEntry(5) }
  local cacheFs = stubCache(raw)
  local scenes = {}
  for sceneNumber = 1, 5 do
    local loaded, err = StartupAssetCache.loadOpeningScene(cacheFs, sceneNumber, VERSION_ID)
    Assert.notNil(loaded, "synthetic scene " .. sceneNumber .. " passes the strict scene reader: " .. tostring(err))
    scenes[sceneNumber] = loaded
  end
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  local waited = 0
  while movie.current.stepIndex < 2 and waited < 200 do
    movie:updateFixed()
    waited = waited + 1
  end
  Assert.equal(movie.current.stepIndex, 2, "playback reaches the sparkle reset")
  local faded = assert(movie.current, "the running movie owns its current slot")
  Assert.equal(faded.fadeByEngine.main.hold, "black", "the close holds the main engine")
  Assert.equal(faded.fadeByEngine.sub.hold, "black", "the close holds the sub engine")
  movie:updateFixed()
  local reset = assert(movie.current, "the running movie owns its current slot")
  Assert.equal(reset.mainPhysical, "lower", "the main engine stays mapped below")
  Assert.isTrue(reset.fadeByEngine.main.task == nil, "the reset retires the main fade task")
  Assert.isTrue(reset.fadeByEngine.main.hold == nil, "the reset frees the main engine")
  Assert.equal(reset.fadeByEngine.sub.hold, "black", "the reset keeps the sub hold behind black")
  movie:dispose()
end

-- Nitro playback and hardware priority: these synthetic scenes carry the
-- normalized animation and priority fields through raw manifests, so the
-- player proves its own progression and plane order instead of failing on
-- strict-reader rejection. The strict reader's share of the contract is
-- proved by the validator tests at the end of this file.
---@param custom table custom scene manifest
---@param customIndex integer position of the custom scene in retail order
---@return table[] scenes, table cacheFs five-scene pack bypassing the strict reader
local function packRawWithSceneAt(custom, customIndex)
  local raw = {}
  for sceneNumber = 1, 5 do
    if sceneNumber == customIndex then
      raw[sceneNumber] = custom
    else
      raw[sceneNumber] = manifestFor(sceneNumber)
    end
  end
  return raw, stubCache(raw)
end

---@return table strict synthetic scene sampling four playback modes plus one paused instance
local function nitroModeScene()
  local root = sceneRoot(2)
  local clips = {
    spriteClip(root .. "sprites/nitro-fwd.g4sprite", {
      clipFrame(0, 0, 16, 16, 0, 0, 2),
      clipFrame(16, 0, 16, 16, 40, 0, 2),
      clipFrame(32, 0, 16, 16, 80, 0, 2),
    }, "forward", 0),
    spriteClip(root .. "sprites/nitro-loop.g4sprite", {
      clipFrame(0, 0, 16, 16, 0, 0, 2),
      clipFrame(16, 0, 16, 16, 40, 0, 0),
      clipFrame(32, 0, 16, 16, 80, 0, 2),
      clipFrame(48, 0, 16, 16, 120, 0, 2),
    }, "forward_loop", 0),
    spriteClip(root .. "sprites/nitro-rev.g4sprite", {
      clipFrame(0, 0, 16, 16, 0, 0, 2),
      clipFrame(16, 0, 16, 16, 40, 0, 2),
      clipFrame(32, 0, 16, 16, 80, 0, 2),
    }, "reverse", 0),
    spriteClip(root .. "sprites/nitro-revloop.g4sprite", {
      clipFrame(0, 0, 16, 16, 0, 0, 2),
      clipFrame(16, 0, 16, 16, 40, 0, 2),
      clipFrame(32, 0, 16, 16, 80, 0, 2),
    }, "reverse_loop", 0),
    spriteClip(root .. "sprites/nitro-still.g4sprite", {
      clipFrame(0, 0, 16, 16, 200, 0, 6),
    }, "forward", 0),
    spriteClip(root .. "sprites/nitro-revloop-nz.g4sprite", {
      clipFrame(0, 0, 16, 16, 0, 0, 2),
      clipFrame(16, 0, 16, 16, 40, 0, 2),
      clipFrame(32, 0, 16, 16, 80, 0, 2),
    }, "reverse_loop", 1),
  }
  local instances = {
    { id = "fwd", clip = 1, animate = true },
    { id = "loop", clip = 2, animate = true },
    { id = "rev", clip = 3, animate = true },
    { id = "revloop", clip = 4, animate = true },
    { id = "still", clip = 5, animate = false },
    { id = "revnz", clip = 6, animate = true },
  }
  local events = {}
  for order, instance in ipairs(instances) do
    events[#events + 1] = {
      op = "setSpriteClip",
      stepId = "nitro",
      atStepTick = 0,
      instanceId = instance.id,
      engine = "main",
      x = 0,
      y = 0,
      drawOrder = order,
      objPriority = 1,
      clipId = clips[instance.clip].id,
      animate = instance.animate,
    }
    events[#events + 1] = {
      op = "spriteVisible",
      stepId = "nitro",
      atStepTick = 0,
      instanceId = instance.id,
      engine = "main",
      x = 0,
      y = 0,
      drawOrder = order,
      visible = true,
    }
  end
  events[#events + 1] = { op = "waitTicks", stepId = "nitro", atStepTick = 0, ticks = 16 }
  events[#events + 1] = { op = "finish", stepId = "nitro", atStepTick = 16 }
  local owned = {}
  for index = 1, #events do
    owned[#owned + 1] = index
  end
  return compositeManifest(
    2,
    { layer(0, root .. "layers/nitro-upper.png", 256, 192) },
    { layer(0, root .. "layers/nitro-lower.png", 256, 192) },
    clips,
    { { id = "nitro", events = owned, ["until"] = { kind = "duration", ticks = 16 } } },
    events
  )
end

---@param movie table running opening movie positioned at its custom scene
---@param graphics table fake graphics namespace
---@param clipIds string[] staged clip identities to sample, one per instance
---@param ticks integer source ticks to sample
---@return table<string, integer[]> horizontal draw origin per clip identity per tick
local function sampleClipOrigins(movie, graphics, clipIds, ticks)
  local images = {}
  for _, clipId in ipairs(clipIds) do
    images[clipId] = assert(movie.current.imageByPath[clipId], "clip " .. clipId .. " is staged")
  end
  local origins = {}
  for _, clipId in ipairs(clipIds) do
    origins[clipId] = {}
  end
  for _ = 1, ticks do
    movie:updateFixed()
    local baseline = #graphics.draws
    movie:draw()
    for _, clipId in ipairs(clipIds) do
      local found = {}
      for index = baseline + 1, #graphics.draws do
        local draw = graphics.draws[index]
        if draw.image == images[clipId] then
          found[#found + 1] = draw.x
        end
      end
      Assert.equal(#found, 1, "instance " .. clipId .. " draws exactly once per frame")
      origins[clipId][#origins[clipId] + 1] = found[1]
    end
  end
  return origins
end

function T.nitro_play_modes_follow_source_edge_handling_at_double_speed()
  local scene = nitroModeScene()
  local scenes, cacheFs = packRawWithSceneAt(scene, 2)
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  enterScene(movie, 2)
  local clips = scene.spriteClips
  local clipIds = {}
  for _, clip in ipairs(clips) do
    clipIds[#clipIds + 1] = clip.id
  end
  local origins = sampleClipOrigins(movie, graphics, clipIds, 14)
  local fwd, loop, rev, revloop, still, revnz =
    origins[clipIds[1]], origins[clipIds[2]], origins[clipIds[3]], origins[clipIds[4]], origins[clipIds[5]], origins[clipIds[6]]
  -- The forward one-shot latches its reset cell on the entry tick, advances
  -- two animation units per source tick, then clamps on its terminal cell.
  Assert.equal(fwd[1], 0, "the drawn frame latches the reset cell before the first advance")
  Assert.equal(fwd[2], 40, "double speed reaches the second cell on the second tick")
  Assert.equal(fwd[3], 80, "double speed reaches the terminal cell on the third tick")
  for tick = 4, 14 do
    Assert.equal(fwd[tick], 80, "a finished one-shot holds its terminal cell without restarting")
  end
  -- The looping clip restarts from its loop start and never displays the
  -- zero-duration cell.
  local expectedLoop = { 0, 80, 120, 0, 80, 120, 0, 80, 120, 0, 80, 120, 0, 80 }
  for tick = 1, 14 do
    Assert.equal(loop[tick], expectedLoop[tick], "the looping clip replays from its loop start on tick " .. tick)
  end
  -- The paused instance holds its authored cell while the source clock runs.
  for tick = 1, 14 do
    Assert.equal(still[tick], 200, "an animation-paused instance never leaves its first cell")
  end
  -- The back-and-forth clip traverses to its far edge, dwells there for
  -- the endpoint's authored timing, then traverses back and stops on its
  -- start cell instead of wrapping.
  local expectedRev = { 0, 40, 80, 80, 40, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
  for tick = 1, 14 do
    Assert.equal(rev[tick], expectedRev[tick], "the back-and-forth one-shot plays its traverse on tick " .. tick)
  end
  -- The looping back-and-forth clip keeps traversing without settling,
  -- dwelling on the far endpoint each pass.
  local expectedRevLoop = { 0, 40, 80, 80, 40, 0, 40, 80, 80, 40, 0, 40, 80, 80 }
  for tick = 1, 14 do
    Assert.equal(
      revloop[tick],
      expectedRevLoop[tick],
      "the looping back-and-forth clip keeps traversing on tick " .. tick
    )
  end
  -- The nonzero loop-start back-and-forth clip restarts its loop from
  -- the loop head, dwelling on the far endpoint each pass without
  -- emitting an extra fabricated frame at the loop edge.
  local expectedRevNz = { 40, 80, 80, 40, 80, 80, 40, 80, 80, 40, 80, 80, 40, 80 }
  for tick = 1, 14 do
    Assert.equal(
      revnz[tick],
      expectedRevNz[tick],
      "the nonzero loop-start back-and-forth clip replays its loop head on tick " .. tick
    )
  end
  -- Repeated host draws never advance the latched cells: two more frames
  -- without a source tick keep showing the terminal cell.
  local terminalImage = assert(movie.current.imageByPath[clipIds[1]], "the one-shot clip stays staged")
  for _ = 1, 2 do
    local baseline = #graphics.draws
    movie:draw()
    local found = {}
    for index = baseline + 1, #graphics.draws do
      local draw = graphics.draws[index]
      if draw.image == terminalImage then
        found[#found + 1] = draw.x
      end
    end
    Assert.equal(#found, 1, "the finished instance still draws exactly once per frame")
    Assert.equal(found[1], 80, "redraws without a source tick keep the terminal cell")
  end
  movie:dispose()
end

function T.bg_priority_zero_occludes_lower_priority_sprites_in_draw_order()
  local root = sceneRoot(2)
  local backImage = root .. "layers/occlude-back.png"
  local frontImage = root .. "layers/occlude-front.png"
  local midClip = spriteClip(root .. "sprites/occlude-mid.g4sprite", { stillFrame() }, "forward", 0)
  local tieClip = spriteClip(root .. "sprites/occlude-tie.g4sprite", { stillFrame() }, "forward", 0)
  local scene = compositeManifest(
    2,
    {
      layer(1, backImage, 256, 192, 2),
      layer(0, frontImage, 256, 192, 0),
    },
    { layer(0, root .. "layers/occlude-lower.png", 256, 192) },
    { midClip, tieClip },
    { { id = "hold", events = { 1, 2, 3, 4, 5, 6 }, ["until"] = { kind = "duration", ticks = 10 } } },
    {
      {
        op = "setSpriteClip",
        stepId = "hold",
        atStepTick = 0,
        instanceId = "mid",
        engine = "main",
        x = 0,
        y = 0,
        drawOrder = 1,
        objPriority = 1,
        clipId = midClip.id,
        animate = true,
      },
      {
        op = "spriteVisible",
        stepId = "hold",
        atStepTick = 0,
        instanceId = "mid",
        engine = "main",
        x = 0,
        y = 0,
        drawOrder = 1,
        visible = true,
      },
      {
        op = "setSpriteClip",
        stepId = "hold",
        atStepTick = 0,
        instanceId = "tie",
        engine = "main",
        x = 0,
        y = 0,
        drawOrder = 2,
        objPriority = 0,
        clipId = tieClip.id,
        animate = true,
      },
      {
        op = "spriteVisible",
        stepId = "hold",
        atStepTick = 0,
        instanceId = "tie",
        engine = "main",
        x = 0,
        y = 0,
        drawOrder = 2,
        visible = true,
      },
      { op = "waitTicks", stepId = "hold", atStepTick = 0, ticks = 10 },
      { op = "finish", stepId = "hold", atStepTick = 10 },
    }
  )
  local scenes, cacheFs = packRawWithSceneAt(scene, 2)
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  enterScene(movie, 2)
  movie:updateFixed()
  local baseline = #graphics.draws
  movie:draw()
  local images = {
    back = assert(movie.current.imageByPath[backImage], "the back background is staged"),
    mid = assert(movie.current.imageByPath[midClip.id], "the covered sprite is staged"),
    front = assert(movie.current.imageByPath[frontImage], "the foreground background is staged"),
    tie = assert(movie.current.imageByPath[tieClip.id], "the tied sprite is staged"),
  }
  local firstIndex = {}
  for index = baseline + 1, #graphics.draws do
    local draw = graphics.draws[index]
    for name, image in pairs(images) do
      if draw.image == image and firstIndex[name] == nil then
        firstIndex[name] = index
      end
    end
  end
  for name in pairs(images) do
    Assert.notNil(firstIndex[name], "the " .. name .. " plane paints in the sampled frame")
  end
  Assert.isTrue(
    firstIndex.back < firstIndex.mid,
    "the back background paints before the lower-priority sprite it sits behind"
  )
  Assert.isTrue(
    firstIndex.mid < firstIndex.front,
    "the occluding foreground background paints after the sprite it covers"
  )
  Assert.isTrue(firstIndex.front < firstIndex.tie, "the tied sprite paints after its same-priority background")
  movie:dispose()
end

function T.two_instances_sharing_one_clip_keep_independent_phases()
  local root = sceneRoot(2)
  local shared = spriteClip(root .. "sprites/shared-phase.g4sprite", {
    clipFrame(0, 0, 16, 16, 0, 0, 6),
    clipFrame(16, 0, 16, 16, 40, 0, 6),
    clipFrame(32, 0, 16, 16, 80, 0, 6),
  }, "forward", 0)
  -- The two instances share one clip image but stage at different origins,
  -- so each drawn frame stays attributable to its own playback phase.
  local scene = compositeManifest(
    2,
    { layer(0, root .. "layers/phase-upper.png", 256, 192) },
    { layer(0, root .. "layers/phase-lower.png", 256, 192) },
    { shared },
    { { id = "phase", events = { 1, 2, 3, 4, 5 }, ["until"] = { kind = "duration", ticks = 20 } } },
    {
      {
        op = "setSpriteClip",
        stepId = "phase",
        atStepTick = 0,
        instanceId = "early",
        engine = "main",
        x = 0,
        y = 0,
        drawOrder = 1,
        objPriority = 1,
        clipId = shared.id,
        animate = true,
      },
      {
        op = "spriteVisible",
        stepId = "phase",
        atStepTick = 0,
        instanceId = "early",
        engine = "main",
        x = 0,
        y = 0,
        drawOrder = 1,
        visible = true,
      },
      {
        op = "setSpriteClip",
        stepId = "phase",
        atStepTick = 6,
        instanceId = "late",
        engine = "main",
        x = 100,
        y = 0,
        drawOrder = 2,
        objPriority = 1,
        clipId = shared.id,
        animate = true,
      },
      {
        op = "spriteVisible",
        stepId = "phase",
        atStepTick = 6,
        instanceId = "late",
        engine = "main",
        x = 100,
        y = 0,
        drawOrder = 2,
        visible = true,
      },
      { op = "waitTicks", stepId = "phase", atStepTick = 0, ticks = 20 },
    }
  )
  local scenes, cacheFs = packRawWithSceneAt(scene, 2)
  local graphics = movieGraphics()
  local movie = openMovie(scenes, cacheFs, graphics)
  enterScene(movie, 2)
  local image = assert(movie.current.imageByPath[shared.id], "the shared clip image is staged")
  for _ = 1, 6 do
    movie:updateFixed()
    movie:draw()
  end
  local early, late = {}, {}
  for _ = 1, 12 do
    movie:updateFixed()
    local baseline = #graphics.draws
    movie:draw()
    local xs = {}
    for index = baseline + 1, #graphics.draws do
      local draw = graphics.draws[index]
      if draw.image == image then
        xs[#xs + 1] = draw.x
      end
    end
    Assert.equal(#xs, 2, "both instances sharing the clip draw every frame")
    table.sort(xs)
    early[#early + 1] = xs[1]
    late[#late + 1] = xs[2] - 100
  end
  Assert.equal(early[2], 80, "the first instance has already reached its terminal cell")
  Assert.equal(late[2], 0, "the later instance still shows its reset cell on the same tick")
  Assert.equal(early[12], 80, "the first instance holds its terminal cell")
  Assert.equal(late[12], 80, "the later instance reaches the same terminal cell without restarting")
  movie:dispose()
end

function T.strict_opening_clips_reject_unknown_play_modes()
  local raw = manifestFor(4)
  raw.spriteClips[1].playMode = "sideways"
  local loaded, err = StartupAssetCache.loadOpeningScene(stubCache({ [4] = raw }), 4, VERSION_ID)
  Assert.isNil(loaded, "a clip with an unknown playback mode never enters the runtime: " .. tostring(err))
end

function T.strict_opening_clips_reject_out_of_range_loop_starts()
  local raw = manifestFor(4)
  raw.spriteClips[1].loopStartFrameIdx = 99
  local loaded, err = StartupAssetCache.loadOpeningScene(stubCache({ [4] = raw }), 4, VERSION_ID)
  Assert.isNil(loaded, "a clip with a loop start outside its frames never enters the runtime: " .. tostring(err))
end

function T.strict_sprite_events_reject_out_of_range_obj_priority()
  local raw = manifestFor(4)
  for _, event in ipairs(raw.timeline.events) do
    if event.op == "setSpriteClip" then
      event.objPriority = 7
    end
  end
  local loaded, err = StartupAssetCache.loadOpeningScene(stubCache({ [4] = raw }), 4, VERSION_ID)
  Assert.isNil(loaded, "a sprite event with a priority outside 0..3 never enters the runtime: " .. tostring(err))
end

function T.strict_opening_scenes_reject_bundles_missing_playback_fields()
  local raw = manifestFor(4)
  for _, clip in ipairs(raw.spriteClips) do
    clip.playMode = nil
    clip.loopStartFrameIdx = nil
  end
  for _, event in ipairs(raw.timeline.events) do
    if event.op == "setSpriteClip" then
      event.objPriority = nil
    end
  end
  local loaded, err = StartupAssetCache.loadOpeningScene(stubCache({ [4] = raw }), 4, VERSION_ID)
  Assert.isNil(loaded, "a bundle without playback and priority fields never enters the runtime: " .. tostring(err))
end

return { tests = T }
