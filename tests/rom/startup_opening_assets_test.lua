-- The five opening-movie scenes compile from the exact ROM into independent
-- versioned bundles with source-timed transitions, layered/model/particle
-- assets, and per-scene failure isolation.

local Assert = require("tests.support.Assert")
local PngReader = require("tests.support.PngReader")
local RomSuite = require("tests.rom.support.RomSuite")

local OPENING_SCHEMA = "g4-startup-opening-scene-v6"
local SOURCE_TICK_RATE = 30

local CLOSED_OPS = {
  setLayer = true,
  setPalette = true,
  setScroll = true,
  setBlend = true,
  window = true,
  setWindowSecondary = true,
  setWindowVisible = true,
  circleWipe = true,
  shutterFade = true,
  setSpriteClip = true,
  spriteVisible = true,
  setModelClip = true,
  setModelVisible = true,
  setCamera = true,
  setLighting = true,
  startEmitters = true,
  setScreenMapping = true,
  setFade = true,
  waitTicks = true,
  enableSkip = true,
  finish = true,
}

local function requireProducer(name)
  local ok, module = pcall(require, "romdump.src.digest.startup." .. name)
  Assert.isTrue(ok and type(module) == "table", "the opening movie " .. name .. " produces one bundle per scene")
  return module
end

local function openingCompiler()
  local compiler = requireProducer("OpeningMovieCompiler")
  Assert.isTrue(type(compiler.compile) == "function", "the opening movie compiler exposes its scene compile entry")
  return compiler
end

local function sceneRoot(sceneNumber)
  return "assets/generated/startup/opening/" .. tostring(sceneNumber) .. "/"
end

local function containsForbiddenShape(value, seen)
  if type(value) == "function" then
    return true
  end
  if type(value) ~= "table" then
    return false
  end
  if seen[value] then
    return false
  end
  seen[value] = true
  for key, child in pairs(value) do
    if key == "fileId" or key == "narcId" or key == "memberId" then
      return true
    end
    if containsForbiddenShape(child, seen) then
      return true
    end
  end
  return false
end

local function generatedAssetPaths(manifest, sceneNumber)
  local paths = {}
  local function visit(value)
    if type(value) == "string" and value:sub(1, 7) == "assets/" then
      paths[#paths + 1] = value
    elseif type(value) == "table" then
      for _, child in pairs(value) do
        visit(child)
      end
    end
  end
  visit(manifest)
  local prefix = sceneRoot(sceneNumber)
  for _, path in ipairs(paths) do
    Assert.isTrue(
      path:sub(1, #prefix) == prefix,
      "scene " .. sceneNumber .. " keeps its runtime asset under its own root: " .. path
    )
  end
  return paths
end

local function timelineEvents(manifest, sceneNumber)
  local timeline = assert(manifest.timeline, "scene " .. sceneNumber .. " carries its normalized timeline")
  local events = assert(timeline.events, "scene " .. sceneNumber .. " carries its normalized event stream")
  Assert.isTrue(#events > 0, "scene " .. sceneNumber .. " carries a nonempty event stream")
  for _, event in ipairs(events) do
    Assert.isTrue(
      type(event.op) == "string" and CLOSED_OPS[event.op] == true,
      "scene " .. sceneNumber .. " uses only the closed movie event grammar: " .. tostring(event.op)
    )
    Assert.isTrue(
      type(event.atStepTick) == "number" and event.atStepTick % 1 == 0 and event.atStepTick >= 0,
      "scene " .. sceneNumber .. " fires every event on its source step clock"
    )
    Assert.isTrue(event.atTick == nil, "scene " .. sceneNumber .. " carries no parallel global clock")
  end
  return events
end

local function eventMentions(event, number)
  local seen = {}
  local function visit(value)
    if value == number then
      return true
    end
    if type(value) ~= "table" or seen[value] then
      return false
    end
    seen[value] = true
    for _, child in pairs(value) do
      if visit(child) then
        return true
      end
    end
    return false
  end
  return visit(event)
end

local function stepPosition(manifest, stepId)
  for position, step in ipairs(manifest.timeline.steps) do
    if step.id == stepId then
      return position
    end
  end
  return nil
end

local function opsInOrder(manifest, events)
  local ordered = {}
  for index, event in ipairs(events) do
    ordered[index] = event
  end
  table.sort(ordered, function(left, right)
    local leftStep, rightStep = stepPosition(manifest, left.stepId), stepPosition(manifest, right.stepId)
    if leftStep ~= rightStep then
      return (leftStep or 0) < (rightStep or 0)
    end
    return left.atStepTick < right.atStepTick
  end)
  return ordered
end

local function compileScene(romFs, versionId, sceneNumber)
  local compiler = openingCompiler()
  local bundle, err = compiler.compile(romFs, versionId, sceneNumber)
  Assert.notNil(bundle, "scene " .. sceneNumber .. " compiles from the exact ROM: " .. tostring(err))
  return bundle
end

local function checkSceneBundle(bundle, versionId, sceneNumber)
  local manifest = assert(bundle.manifest, "scene " .. sceneNumber .. " publishes its manifest")
  Assert.equal(manifest.schema, OPENING_SCHEMA, "scene " .. sceneNumber .. " carries the opening scene schema")
  Assert.equal(manifest.versionId, versionId, "scene " .. sceneNumber .. " carries its edition")
  Assert.equal(manifest.sceneNumber, sceneNumber, "scene " .. sceneNumber .. " carries its scene key")
  Assert.equal(manifest.sourceTickRate, SOURCE_TICK_RATE, "scene " .. sceneNumber .. " runs at the source frame rate")
  Assert.isFalse(
    containsForbiddenShape(manifest, {}),
    "scene " .. sceneNumber .. " carries no source member identity or executable payload"
  )
  local paths = generatedAssetPaths(manifest, sceneNumber)
  Assert.isTrue(#paths > 0, "scene " .. sceneNumber .. " references staged scene assets")
  for _, path in ipairs(paths) do
    Assert.notNil(bundle.files[path], "scene " .. sceneNumber .. " stages its referenced asset: " .. path)
  end
  Assert.isTrue(
    type(manifest.layers) == "table" and type(manifest.layers.main) == "table" and type(manifest.layers.sub) == "table",
    "scene " .. sceneNumber .. " keys its layers by source engine"
  )
  return manifest
end

local function stageScene(cacheFs, generationId, bundle, sceneNumber)
  local writer = requireProducer("OpeningMovieCacheWriter")
  Assert.isTrue(type(writer.stageScene) == "function", "the opening scene writer stages one numbered scene")
  local CacheFsModule = require("libs.storage.src.CacheFs")
  local PreparedArtifact = require("romdump.src.build.PreparedArtifact")
  local artifact = PreparedArtifact.new({
    cacheFs = cacheFs,
    generationId = generationId,
    epoch = 1,
    kind = "opening-scene",
    key = tostring(sceneNumber),
    jobKey = "opening-scene:" .. tostring(sceneNumber),
    stageName = "opening-scene-" .. tostring(sceneNumber),
  })
  local _ = CacheFsModule
  local marker, err = writer.stageScene(artifact, bundle, generationId, sceneNumber)
  Assert.notNil(marker, "scene " .. sceneNumber .. " stages its numbered package: " .. tostring(err))
  artifact:finishSuccess({ marker = marker })
  local published = artifact:publish({
    generationId = generationId,
    epoch = 1,
    kind = "opening-scene",
    key = tostring(sceneNumber),
    jobKey = "opening-scene:" .. tostring(sceneNumber),
    stageName = "opening-scene-" .. tostring(sceneNumber),
  })
  Assert.isTrue(published, "scene " .. sceneNumber .. " publishes its numbered package")
  return marker
end

local function loadScene(cacheFs, sceneNumber, versionId)
  local StartupAssetCache = require("libs.assets.src.StartupAssetCache")
  Assert.isTrue(
    type(StartupAssetCache.loadOpeningScene) == "function",
    "the startup cache reads one strict opening scene bundle"
  )
  local bundle, err = StartupAssetCache.loadOpeningScene(cacheFs, sceneNumber, versionId)
  Assert.notNil(bundle, "scene " .. sceneNumber .. " reads back as a ready bundle: " .. tostring(err))
  return bundle
end

local function sourceOpeningScenesCompileToFiveIndependentVersionedBundles(romFs, versionId)
  local ArtifactState = require("romdump.src.build.ArtifactState")
  Assert.isTrue(
    ArtifactState.KINDS["opening-scene"] == true,
    "the opening scenes form their own independently requestable artifact family"
  )
  local FakeCache = require("tests.support.FakeCache")
  local CacheFs = require("libs.storage.src.CacheFs")
  local backend = FakeCache.new()
  local cacheFs = CacheFs.forVersion(versionId, backend)
  local generationId = "opening-scene-independence"
  for sceneNumber = 1, 5 do
    local receiptPath = ArtifactState.path("opening-scene", tostring(sceneNumber))
    Assert.notNil(receiptPath, "scene " .. sceneNumber .. " addresses its own readiness receipt")
    local bundle = compileScene(romFs, versionId, sceneNumber)
    checkSceneBundle(bundle, versionId, sceneNumber)
    stageScene(cacheFs, generationId, bundle, sceneNumber)
    local loaded = loadScene(cacheFs, sceneNumber, versionId)
    Assert.equal(loaded.sceneNumber, sceneNumber, "scene " .. sceneNumber .. " reads back under its own key")
    Assert.equal(loaded.versionId, versionId, "scene " .. sceneNumber .. " reads back under its own edition")
    Assert.equal(loaded.schema, OPENING_SCHEMA, "scene " .. sceneNumber .. " reads back under its own schema")
  end
  for sceneNumber = 1, 5 do
    for other = 1, 5 do
      if other ~= sceneNumber then
        Assert.isTrue(
          ArtifactState.path("opening-scene", tostring(sceneNumber))
            ~= ArtifactState.path("opening-scene", tostring(other)),
          "scenes " .. sceneNumber .. " and " .. other .. " publish through distinct receipts"
        )
      end
    end
  end
end

local function sourceOpeningTimelineKeepsItsFiveSceneTransitionsAndSkipGate(romFs, versionId)
  local first = checkSceneBundle(compileScene(romFs, versionId, 1), versionId, 1)
  local firstEvents = opsInOrder(first, timelineEvents(first, 1))
  for _, landmark in ipairs({ 30, 60, 20, 110, 240, 128, 90, 65 }) do
    local seen = false
    for _, event in ipairs(firstEvents) do
      if eventMentions(event, landmark) then
        seen = true
        break
      end
    end
    Assert.isTrue(seen, "scene 1 keeps its " .. landmark .. "-tick source beat")
  end
  local skipStep = nil
  for _, event in ipairs(firstEvents) do
    if event.op == "enableSkip" then
      Assert.isTrue(event.atStepTick > 0, "the movie skip gate never opens on the first step tick")
      if skipStep == nil then
        skipStep = event.stepId
      end
    end
  end
  Assert.notNil(skipStep, "scene 1 carries the source movie skip gate")
  -- The skip opens in the setup step, after the copyright hold and fades
  -- steps have completed in step order.
  Assert.equal(skipStep, "setup", "the movie skip gate opens from the setup step")
  local setupPos = stepPosition(first, "setup")
  Assert.isTrue(
    (setupPos or 0) > (stepPosition(first, "copyright") or 0) and (setupPos or 0) > (stepPosition(first, "fades") or 0),
    "the movie skip gate opens only after the copyright hold, fades, and setup"
  )

  local second = checkSceneBundle(compileScene(romFs, versionId, 2), versionId, 2)
  local secondEvents = timelineEvents(second, 2)
  local sawScroll, sawWipe, sawSprite = false, false, false
  for _, event in ipairs(secondEvents) do
    if event.op == "setScroll" then
      sawScroll = true
    elseif event.op == "circleWipe" then
      sawWipe = true
    elseif event.op == "setSpriteClip" or event.op == "spriteVisible" then
      sawSprite = true
    end
  end
  Assert.isTrue(sawScroll, "scene 2 keeps its aerial and walking pans")
  Assert.isTrue(sawWipe, "scene 2 keeps its circle wipe")
  Assert.isTrue(sawSprite, "scene 2 keeps its grass and character sprites")
  Assert.isTrue(#second.spriteClips >= 2, "scene 2 keeps both of its sprite banks")

  local third = checkSceneBundle(compileScene(romFs, versionId, 3), versionId, 3)
  local thirdEvents = timelineEvents(third, 3)
  Assert.isTrue(type(third.models) == "table" and #third.models == 3, "scene 3 keeps its three town models")
  for _, landmark in ipairs({ 56, 73, 92, 145 }) do
    local seen = false
    for _, event in ipairs(thirdEvents) do
      if eventMentions(event, landmark) then
        seen = true
        break
      end
    end
    Assert.isTrue(seen, "scene 3 keeps its " .. landmark .. "-tick source appearance beat")
  end
  local longHold = false
  for _, event in ipairs(thirdEvents) do
    if eventMentions(event, 98) or eventMentions(event, 254) then
      longHold = true
      break
    end
  end
  Assert.isTrue(longHold, "scene 3 keeps its long town holds and closing wait")
  local sawCamera, sawLight = false, false
  for _, event in ipairs(thirdEvents) do
    if event.op == "setCamera" then
      sawCamera = true
    elseif event.op == "setLighting" then
      sawLight = true
    end
  end
  Assert.isTrue(sawCamera, "scene 3 keeps its source camera program")
  Assert.isTrue(sawLight, "scene 3 keeps its source lighting program")

  local fourth = checkSceneBundle(compileScene(romFs, versionId, 4), versionId, 4)
  local fourthEvents = opsInOrder(fourth, timelineEvents(fourth, 4))
  for _, starter in ipairs({ 152, 155, 158 }) do
    Assert.isTrue(
      eventMentions(fourth, starter) or eventMentions(fourthEvents, starter),
      "scene 4 keeps its starter " .. starter
    )
  end
  local seenStarterClips = 0
  for _, clip in ipairs(assert(fourth.spriteClips, "scene 4 carries its sprite clips")) do
    if clip ~= nil then
      seenStarterClips = seenStarterClips + 1
    end
  end
  Assert.isTrue(seenStarterClips >= 3, "scene 4 keeps its three starter animation sets")
  local emitters = assert(fourth.particles and fourth.particles.emitters, "scene 4 carries its emitter records")
  local byId = {}
  for _, emitter in ipairs(emitters) do
    Assert.isTrue(
      type(emitter.id) == "number" and emitter.id % 1 == 0 and emitter.id >= 0 and emitter.id <= 8,
      "scene 4 emitter ids stay within the nine source emitters"
    )
    byId[emitter.id] = emitter
  end
  for id = 0, 8 do
    Assert.notNil(byId[id], "scene 4 keeps source emitter " .. id)
  end
  local groups = { grass = { 6, 7, 8 }, fire = { 3, 4, 5 }, water = { 0, 1, 2 } }
  for group, ids in pairs(groups) do
    for _, id in ipairs(ids) do
      Assert.equal(byId[id].group, group, "source emitter " .. id .. " stays in its " .. group .. " group")
    end
  end

  local fifth = checkSceneBundle(compileScene(romFs, versionId, 5), versionId, 5)
  local fifthEvents = opsInOrder(fifth, timelineEvents(fifth, 5))
  local wipeAt, scrollAt, waitAt, fadeAt = nil, nil, nil, nil
  local circleWipes = 0
  for _, event in ipairs(fifthEvents) do
    if event.op == "shutterFade" and event.steps == 18 and wipeAt == nil then
      wipeAt = stepPosition(fifth, event.stepId)
    elseif event.op == "circleWipe" then
      circleWipes = circleWipes + 1
    elseif event.op == "setScroll" and eventMentions(event, 73) and scrollAt == nil then
      scrollAt = stepPosition(fifth, event.stepId)
    elseif event.op == "waitTicks" and eventMentions(event, 20) and waitAt == nil then
      waitAt = stepPosition(fifth, event.stepId)
    elseif event.op == "setFade" and eventMentions(event, 50) and fadeAt == nil then
      fadeAt = stepPosition(fifth, event.stepId)
    end
  end
  Assert.notNil(wipeAt, "scene 5 keeps its 18-step sequential line shutter")
  Assert.equal(circleWipes, 0, "scene 5 carries no circle wipe")
  Assert.notNil(scrollAt, "scene 5 keeps its 73-tick parallel scroll")
  Assert.notNil(waitAt, "scene 5 keeps its 20-tick wait")
  Assert.notNil(fadeAt, "scene 5 keeps its closing 50-tick white fade")
  Assert.isTrue(
    (wipeAt or 0) <= (scrollAt or 0) and (scrollAt or 0) <= (waitAt or 0) and (waitAt or 0) <= (fadeAt or 0),
    "scene 5 keeps its wipe, scroll, wait, and fade order"
  )
end

local function sourceOpeningAssetsKeepLayeredModelsParticlesAndFailedStagesPreserveGoodOutput(romFs, versionId)
  local third = checkSceneBundle(compileScene(romFs, versionId, 3), versionId, 3)
  for _, model in ipairs(third.models) do
    Assert.isTrue(type(model.clips) == "table" and #model.clips >= 2, "each town keeps its two animation channels")
    Assert.notNil(model.descriptor, "each town keeps its compiled model descriptor")
  end
  Assert.notNil(third.camera, "scene 3 keeps its source camera set")
  Assert.notNil(third.lighting, "scene 3 keeps its source lighting set")

  local fourth = checkSceneBundle(compileScene(romFs, versionId, 4), versionId, 4)
  local particles = assert(fourth.particles, "scene 4 carries its normalized particle set")
  Assert.equal(particles.seed, 0, "scene 4 keeps the deterministic source particle seed")
  Assert.isTrue(#particles.emitters == 9, "scene 4 keeps all nine starter emitters")
  for _, clip in ipairs(fourth.spriteClips) do
    Assert.isTrue(
      type(clip.frameCount) == "number" and clip.frameCount > 0,
      "scene 4 starter clips keep their source animation length"
    )
  end

  local FakeCache = require("tests.support.FakeCache")
  local CacheFs = require("libs.storage.src.CacheFs")
  local ArtifactState = require("romdump.src.build.ArtifactState")
  local StartupAssetCache = require("libs.assets.src.StartupAssetCache")
  local backend = FakeCache.new()
  local cacheFs = CacheFs.forVersion(versionId, backend)
  local goodGeneration = "opening-scene-good"
  local goodBundle = compileScene(romFs, versionId, 4)
  checkSceneBundle(goodBundle, versionId, 4)
  stageScene(cacheFs, goodGeneration, goodBundle, 4)
  local siblingBundle = compileScene(romFs, versionId, 2)
  stageScene(cacheFs, goodGeneration, siblingBundle, 2)
  local liveManifestPath = StartupAssetCache.openingScenePath(4)
  local liveReceiptPath = ArtifactState.path("opening-scene", "4")
  local liveManifest = cacheFs:loadLua(liveManifestPath)
  local liveReceipt = cacheFs:loadLua(liveReceiptPath)
  Assert.notNil(liveManifest, "the staged scene 4 manifest is live before the failed restage")
  Assert.notNil(liveReceipt, "the staged scene 4 receipt is live before the failed restage")

  local originalWrite = backend.write
  local stagedWrites = 0
  backend.write = function(self, path, bytes)
    stagedWrites = stagedWrites + 1
    if stagedWrites == 2 then
      error("injected opening scene staged write failure", 0)
    end
    return originalWrite(self, path, bytes)
  end
  local writer = requireProducer("OpeningMovieCacheWriter")
  local PreparedArtifact = require("romdump.src.build.PreparedArtifact")
  local artifact = PreparedArtifact.new({
    cacheFs = cacheFs,
    generationId = "opening-scene-broken",
    epoch = 1,
    kind = "opening-scene",
    key = "4",
    jobKey = "opening-scene:4",
    stageName = "opening-scene-4-failure",
  })
  local ok, failure = pcall(writer.stageScene, artifact, goodBundle, "opening-scene-broken", 4)
  backend.write = originalWrite
  Assert.isFalse(ok, "the injected staged failure fails the scene 4 restage: " .. tostring(failure))
  Assert.deepEqual(
    cacheFs:loadLua(liveManifestPath),
    liveManifest,
    "a failed scene 4 stage preserves its previous good manifest"
  )
  Assert.deepEqual(
    cacheFs:loadLua(liveReceiptPath),
    liveReceipt,
    "a failed scene 4 stage preserves its previous good receipt"
  )
  local sibling = loadScene(cacheFs, 2, versionId)
  Assert.equal(sibling.sceneNumber, 2, "a failed scene 4 stage leaves its sibling scene untouched")
end

-- The strict scene contract below is the source-independent program the
-- runtime consumes: layers keyed by source engine with numeric slots,
-- sprite instances carrying their owning engine and authored placement,
-- one source step clock, waits bound to started effects or compiled
-- clips, and explicit physical display mapping. Every new scenario
-- below reads the exact compiled bundles and fails until the producer
-- emits that contract and the central reader enforces it.

local STRICT_SCHEMA = "g4-startup-opening-scene-v6"

local function strictManifest(bundle, versionId, sceneNumber)
  local manifest = assert(bundle.manifest, "scene " .. sceneNumber .. " publishes its manifest")
  Assert.equal(manifest.schema, STRICT_SCHEMA, "scene " .. sceneNumber .. " carries the strict scene schema")
  Assert.equal(manifest.versionId, versionId, "scene " .. sceneNumber .. " carries its edition")
  Assert.equal(manifest.sceneNumber, sceneNumber, "scene " .. sceneNumber .. " carries its scene key")
  Assert.equal(manifest.sourceTickRate, SOURCE_TICK_RATE, "scene " .. sceneNumber .. " runs at the source frame rate")
  return manifest
end

local function engineLayers(manifest, sceneNumber)
  local layers = assert(manifest.layers, "scene " .. sceneNumber .. " carries its engine layers")
  Assert.isTrue(type(layers.main) == "table", "scene " .. sceneNumber .. " keys its main engine layers")
  Assert.isTrue(type(layers.sub) == "table", "scene " .. sceneNumber .. " keys its sub engine layers")
  Assert.isTrue(
    layers.upper == nil and layers.lower == nil,
    "scene " .. sceneNumber .. " keys layers by source engine instead of physical role"
  )
  return layers
end

local function checkLayerSlot(layer, sceneNumber, engine)
  Assert.isTrue(
    type(layer.bgSlot) == "number" and layer.bgSlot % 1 == 0 and layer.bgSlot >= 0 and layer.bgSlot <= 3,
    "scene " .. sceneNumber .. " " .. engine .. " keeps its numeric background slot"
  )
  Assert.isTrue(
    type(layer.priority) == "number" and layer.priority % 1 == 0 and layer.priority >= 0,
    "scene " .. sceneNumber .. " " .. engine .. " keeps its source priority"
  )
  Assert.isTrue(
    type(layer.image) == "string",
    "scene " .. sceneNumber .. " " .. engine .. " points at a compiled image"
  )
end

local function checkLayerImageResolves(manifest, bundle, layer, sceneNumber)
  Assert.notNil(
    bundle.files[layer.image],
    "scene " .. sceneNumber .. " stages its slot image: " .. tostring(layer.image)
  )
  Assert.isTrue(
    manifest.assets[layer.image] == true,
    "scene " .. sceneNumber .. " indexes its slot image: " .. tostring(layer.image)
  )
end

local function strictTimeline(manifest, sceneNumber)
  local timeline = assert(manifest.timeline, "scene " .. sceneNumber .. " carries its normalized timeline")
  local events = assert(timeline.events, "scene " .. sceneNumber .. " carries its normalized event stream")
  Assert.isTrue(#events > 0, "scene " .. sceneNumber .. " carries a nonempty event stream")
  return timeline, events
end

local function checkStepClock(events, sceneNumber)
  for _, event in ipairs(events) do
    Assert.isTrue(
      type(event.atStepTick) == "number" and event.atStepTick % 1 == 0 and event.atStepTick >= 0,
      "scene " .. sceneNumber .. " fires every event on its source step clock"
    )
    Assert.isTrue(event.atTick == nil, "scene " .. sceneNumber .. " carries no parallel global clock")
  end
end

local STARTING_OPS = { setBlend = true, setScroll = true, setFade = true, circleWipe = true, shutterFade = true, window = true }

local function startedEffectIds(events)
  local started = {}
  for _, event in ipairs(events) do
    if type(event.effect) == "string" and STARTING_OPS[event.op] == true then
      started[event.effect] = true
    end
    if event.op == "startEmitters" and type(event.group) == "string" then
      started["emitters-" .. event.group] = true
    end
  end
  return started
end

local function awaitableClipIds(manifest, events)
  local clips = {}
  for _, clip in ipairs(manifest.spriteClips or {}) do
    if type(clip.id) == "string" then
      clips[clip.id] = true
    end
  end
  for _, event in ipairs(events) do
    if event.op == "setSpriteClip" then
      if type(event.clipId) == "string" then
        clips[event.clipId] = true
      end
      if type(event.clip) == "string" then
        clips[event.clip] = true
      end
    end
  end
  return clips
end

local function waitedEffectIds(timeline)
  local waited = {}
  for _, step in ipairs(timeline.steps) do
    local finish = step["until"]
    if type(finish) == "table" and finish.kind == "effect" then
      waited[#waited + 1] = finish.effect
    end
  end
  return waited
end

local function checkEffectGraph(manifest, sceneNumber)
  local timeline, events = strictTimeline(manifest, sceneNumber)
  local started = startedEffectIds(events)
  local clips = awaitableClipIds(manifest, events)
  for _, name in ipairs(waitedEffectIds(timeline)) do
    Assert.isTrue(
      started[name] == true or clips[name] == true,
      "scene " .. sceneNumber .. " binds every waited effect to a started effect or a compiled clip: " .. tostring(name)
    )
  end
end

local function stepById(manifest, sceneNumber, id)
  for _, step in ipairs(manifest.timeline.steps) do
    if step.id == id then
      return step
    end
  end
  Assert.notNil(nil, "scene " .. sceneNumber .. " keeps its " .. id .. " step")
end

local function fadeTickInStep(manifest, sceneNumber, stepId)
  for _, event in ipairs(manifest.timeline.events) do
    if event.op == "setFade" and event.stepId == stepId then
      return event.atStepTick
    end
  end
  Assert.notNil(nil, "scene " .. sceneNumber .. " keeps its fade in step " .. stepId)
end

local function deepCopyManifest(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, child in pairs(value) do
    out[deepCopyManifest(key)] = deepCopyManifest(child)
  end
  return out
end

local function firstLayerImage(manifest)
  for _, key in ipairs({ "main", "sub", "upper", "lower" }) do
    local group = manifest.layers[key]
    if type(group) == "table" and type(group[1]) == "table" and type(group[1].image) == "string" then
      return group[1].image
    end
  end
  return nil
end

local function strictLoad(versionId, sceneNumber, manifest, files, dropPath)
  local FakeCache = require("tests.support.FakeCache")
  local CacheFs = require("libs.storage.src.CacheFs")
  local StartupAssetCache = require("libs.assets.src.StartupAssetCache")
  local backend = FakeCache.new()
  local cacheFs = CacheFs.forVersion(versionId, backend)
  for path, bytes in pairs(files) do
    if path ~= dropPath then
      cacheFs:write(path, bytes)
    end
  end
  manifest.generationId = "strict-contract-check"
  cacheFs:writeLua(StartupAssetCache.openingScenePath(sceneNumber), manifest)
  return StartupAssetCache.loadOpeningScene(cacheFs, sceneNumber, versionId)
end

local function concurrentSunriseSlotsKeepDistinctIndexedSlots(romFs, versionId)
  local bundle = compileScene(romFs, versionId, 1)
  local manifest = strictManifest(bundle, versionId, 1)
  local layers = engineLayers(manifest, 1)
  Assert.isTrue(#layers.main >= 3, "scene 1 keeps at least its three simultaneous main sunrise slots")
  local seen = {}
  for _, layer in ipairs(layers.main) do
    checkLayerSlot(layer, 1, "main")
    Assert.isTrue(seen[layer.bgSlot] == nil, "scene 1 keeps each main slot exactly once")
    seen[layer.bgSlot] = true
    checkLayerImageResolves(manifest, bundle, layer, 1)
  end
  local _, events = strictTimeline(manifest, 1)
  local sets, scrollSources = 0, {}
  for _, event in ipairs(events) do
    if event.op == "setLayer" then
      sets = sets + 1
      Assert.isTrue(event.engine == "main" or event.engine == "sub", "scene 1 sets layers by source engine")
      Assert.isTrue(
        type(event.bgSlot) == "number" and event.bgSlot % 1 == 0 and event.bgSlot >= 0 and event.bgSlot <= 3,
        "scene 1 sets layers by numeric slot"
      )
      Assert.isTrue(type(event.image) == "string", "scene 1 sets layers to a compiled image")
      Assert.notNil(
        bundle.files[event.image],
        "scene 1 sunrise art resolves to an emitted image: " .. tostring(event.image)
      )
    elseif event.op == "setScroll" then
      if event.engine == "main" then
        scrollSources[tostring(event.engine) .. ":" .. tostring(event.bgSlot)] = true
      elseif type(event.layer) == "string" and event.layer:find("main", 1, true) ~= nil then
        scrollSources[event.layer] = true
      end
    end
  end
  Assert.isTrue(sets >= 4, "scene 1 sets each of its sunrise slots")
  local distinct = 0
  for _ in pairs(scrollSources) do
    distinct = distinct + 1
  end
  Assert.isTrue(distinct >= 2, "scene 1 keeps distinct scroll sources across its sunrise slots")
end

local function alternatePanelsResolveToStagedImages(romFs, versionId)
  local bundle = compileScene(romFs, versionId, 3)
  local manifest = strictManifest(bundle, versionId, 3)
  local _, events = strictTimeline(manifest, 3)
  local swaps = 0
  for _, event in ipairs(events) do
    if event.op == "setLayer" then
      swaps = swaps + 1
      Assert.isTrue(event.engine == "main" or event.engine == "sub", "scene 3 swaps panels by source engine")
      Assert.isTrue(
        type(event.bgSlot) == "number" and event.bgSlot % 1 == 0 and event.bgSlot >= 0 and event.bgSlot <= 3,
        "scene 3 swaps panels by numeric slot"
      )
      Assert.isTrue(type(event.image) == "string", "scene 3 swaps panels to a compiled image")
      Assert.notNil(
        bundle.files[event.image],
        "scene 3 panel art resolves to an emitted image: " .. tostring(event.image)
      )
      Assert.isTrue(manifest.assets[event.image] == true, "scene 3 panel art is indexed: " .. tostring(event.image))
    end
  end
  Assert.isTrue(swaps >= 6, "scene 3 walks its rival, beast, and rocket panel swaps")
end

-- Exact retail sprite stations transcribed from the pinned decomp
-- CreateSprites functions. Scene 1 sun and bird share (128, 96) on the
-- main engine with no per-frame motion in Main (only anim and
-- visibility). Scene 2 holds ten both-engines flowers at (128, 192)
-- appearing at steps 1, 8, 16, 24, 28, 32, 34, 38, 42, 48, plus three
-- main-engine ethan at (64, -96) and three at (320, -96); the retail
-- SysTask pan effects move only the six heroes with the truncating
-- speed*duration arithmetic below. Scene 3 holds silver at (128, 608),
-- eusine at (32, 608), and unowns at (128, 544/672/608) on the sub
-- engine with no position updates in Main. Scene 4 holds hand1 at
-- (128, 352) on the sub engine with hand2, sparkles, and all three
-- starters at (128, 96) on the main engine; its slide-ins move
-- background layers, never sprites. Scene 5 creates no sprites.
-- The compiled program normalizes every sprite station into its owning
-- engine's 256x192 surface by subtracting the source renderer origin once:
-- sub origins are scene1 0, scene2 192, scene3 512, scene4 256, scene5 256
-- while every main origin is 0. The tables below carry those normalized
-- engine-local stations, not the raw shared-renderer coordinates.
local function exactSceneInstances()
  local scenes = {
    [1] = {
      { id = "sun", engine = "main", x = 128, y = 96 },
      { id = "bird", engine = "main", x = 128, y = 96 },
    },
    [3] = {
      { id = "eusine", engine = "sub", x = 32, y = 96 },
      { id = "unown0", engine = "sub", x = 128, y = 32 },
      { id = "unown1", engine = "sub", x = 128, y = 160 },
      { id = "unown2", engine = "sub", x = 128, y = 96 },
      { id = "silver-silhouette", engine = "sub", x = 128, y = 96 },
    },
    [4] = {
      { id = "hand1", engine = "sub", x = 128, y = 96 },
      { id = "hand2", engine = "main", x = 128, y = 96 },
      { id = "chikorita", engine = "main", x = 128, y = 96 },
      { id = "cyndaquil", engine = "main", x = 128, y = 96 },
      { id = "totodile", engine = "main", x = 128, y = 96 },
      { id = "sparkles", engine = "main", x = 128, y = 96 },
    },
  }
  local second = {}
  for flower = 1, 10 do
    second[#second + 1] = { id = "flower" .. flower .. "-main", engine = "main", x = 128, y = 192 }
    second[#second + 1] = { id = "flower" .. flower .. "-sub", engine = "sub", x = 128, y = 0 }
  end
  for hero = 0, 2 do
    second[#second + 1] = { id = "ethan" .. hero, engine = "main", x = 64, y = -96 }
    second[#second + 1] = { id = "lyra" .. hero, engine = "main", x = 320, y = -96 }
  end
  scenes[2] = second
  return scenes
end

-- Retail per-frame pan arithmetic sampled at the source step clock:
-- position(tick) = start + trunc(speed * tick / duration), matching the
-- C integer division in the scene 2 sprite pan task.
local function truncStep(speed, tick, duration)
  local quotient = speed * tick / duration
  if quotient >= 0 then
    return math.floor(quotient)
  end
  return math.ceil(quotient)
end

local SCENE2_PANS = {
  { step = "settle-flyin", xSpeed = 0, ySpeed = 192, duration = 5, ethan = { 64, -96 }, lyra = { 320, -96 } },
  { step = "slow-pan-ethan", xSpeed = -32, ySpeed = 0, duration = 90, ethan = { 64, 96 }, lyra = { 320, 96 } },
  { step = "fast-pan-lyra", xSpeed = -64, ySpeed = 0, duration = 7, ethan = { 32, 96 }, lyra = { 288, 96 } },
  { step = "slow-pan-lyra", xSpeed = -32, ySpeed = 0, duration = 66, ethan = { -32, 96 }, lyra = { 224, 96 } },
  { step = "lyra-exit", xSpeed = 0, ySpeed = 128, duration = 10, ethan = { -64, 96 }, lyra = { 192, 96 } },
}

local function spriteEventsByStepInstance(events)
  local byKey = {}
  for _, event in ipairs(events) do
    if event.op == "setSpriteClip" or event.op == "spriteVisible" then
      local key = event.stepId .. "\0" .. event.instanceId
      local list = byKey[key]
      if list == nil then
        list = {}
        byKey[key] = list
      end
      list[#list + 1] = event
    end
  end
  for _, list in pairs(byKey) do
    table.sort(list, function(left, right)
      return left.atStepTick < right.atStepTick
    end)
  end
  return byKey
end

local function checkExactStations(manifest, sceneNumber, wanted)
  local _, events = strictTimeline(manifest, sceneNumber)
  local defined, seenIds = {}, {}
  for _, event in ipairs(events) do
    if event.op == "setSpriteClip" or event.op == "spriteVisible" then
      Assert.isTrue(
        type(event.instanceId) == "string" and event.instanceId ~= "",
        "scene " .. sceneNumber .. " names its sprite instance"
      )
      Assert.isTrue(
        event.engine == "main" or event.engine == "sub",
        "scene " .. sceneNumber .. " owns its sprite instance from one engine"
      )
      Assert.isTrue(
        type(event.x) == "number" and type(event.y) == "number",
        "scene " .. sceneNumber .. " places its sprite instance at authored coordinates"
      )
      Assert.isTrue(
        type(event.drawOrder) == "number" and event.drawOrder % 1 == 0,
        "scene " .. sceneNumber .. " orders its sprite instance"
      )
      seenIds[event.instanceId] = true
      if event.op == "setSpriteClip" then
        Assert.isTrue(
          type(event.clipId) == "string",
          "scene " .. sceneNumber .. " points its instance at a compiled clip"
        )
        local found = false
        for _, clip in ipairs(manifest.spriteClips) do
          if clip.id == event.clipId then
            found = true
            break
          end
        end
        Assert.isTrue(found, "scene " .. sceneNumber .. " instance clip resolves: " .. tostring(event.clipId))
        defined[event.instanceId] = true
      end
    end
    if event.op == "setScroll" then
      Assert.isTrue(
        event.target == nil,
        "scene " .. sceneNumber .. " moves no invented sprite group; motion is per-instance"
      )
    end
  end
  for _, station in ipairs(wanted) do
    Assert.isTrue(seenIds[station.id] == true, "scene " .. sceneNumber .. " keeps its retail instance " .. station.id)
    Assert.isTrue(
      defined[station.id] == true,
      "scene " .. sceneNumber .. " assigns its retail instance " .. station.id .. " a compiled clip"
    )
  end
  local expectedCount = #wanted
  local actualCount = 0
  for _ in pairs(seenIds) do
    actualCount = actualCount + 1
  end
  Assert.equal(actualCount, expectedCount, "scene " .. sceneNumber .. " carries exactly its retail sprite instances")
  return events
end

local function checkStaticStations(manifest, sceneNumber, wanted)
  local events = checkExactStations(manifest, sceneNumber, wanted)
  local stations = {}
  for _, station in ipairs(wanted) do
    stations[station.id] = station
  end
  for _, event in ipairs(events) do
    if event.op == "setSpriteClip" or event.op == "spriteVisible" then
      local station = assert(stations[event.instanceId], "scene " .. sceneNumber .. " moves no extra instance")
      Assert.equal(event.engine, station.engine, station.id .. " stays on its retail engine")
      Assert.equal(event.x, station.x, station.id .. " stays at its retail x")
      Assert.equal(event.y, station.y, station.id .. " stays at its retail y")
    end
  end
end

local function checkScene2Motion(manifest)
  local events = checkExactStations(manifest, 2, exactSceneInstances()[2])
  local stations = {}
  for _, station in ipairs(exactSceneInstances()[2]) do
    stations[station.id] = station
  end
  local byKey = spriteEventsByStepInstance(events)
  for flower = 1, 10 do
    for _, engine in ipairs({ "main", "sub" }) do
      local id = "flower" .. flower .. "-" .. engine
      local homeY = engine == "sub" and 0 or 192
      for _, event in ipairs(byKey["flyin\0" .. id] or {}) do
        Assert.equal(event.x, 128, id .. " stays at its engine-local x")
        Assert.equal(event.y, homeY, id .. " stays at its engine-local y")
        Assert.equal(event.engine, engine, id .. " stays on its retail engine")
      end
    end
  end
  for hero = 0, 2 do
    for _, group in ipairs({ "ethan", "lyra" }) do
      local id = group .. hero
      local station = stations[id]
      local initial = byKey["flyin\0" .. id]
      Assert.notNil(initial, id .. " is visible from its creation station")
      Assert.equal(initial[1].x, station.x, id .. " starts at its retail x")
      Assert.equal(initial[1].y, station.y, id .. " starts at its retail y")
      local seen = 0
      for _, pan in ipairs(SCENE2_PANS) do
        local trail = byKey[pan.step .. "\0" .. id] or {}
        local start = pan[group]
        Assert.equal(#trail, pan.duration, id .. " samples every retail pan tick in " .. pan.step)
        for tick = 1, pan.duration do
          local event = trail[tick]
          Assert.equal(event.atStepTick, tick, id .. " fires its pan update on the step clock")
          Assert.equal(
            event.x,
            start[1] + truncStep(pan.xSpeed, tick, pan.duration),
            id .. " follows the retail x arithmetic at tick " .. tick .. " of " .. pan.step
          )
          Assert.equal(
            event.y,
            start[2] + truncStep(pan.ySpeed, tick, pan.duration),
            id .. " follows the retail y arithmetic at tick " .. tick .. " of " .. pan.step
          )
        end
        seen = seen + #trail
      end
      Assert.equal(seen, 5 + 90 + 7 + 66 + 10, id .. " carries every retail pan update")
    end
  end
end

local function spriteInstancesCarryRetailPlacement(romFs, versionId)
  local exact = exactSceneInstances()
  for _, sceneNumber in ipairs({ 1, 3, 4 }) do
    local bundle = compileScene(romFs, versionId, sceneNumber)
    local manifest = strictManifest(bundle, versionId, sceneNumber)
    checkStaticStations(manifest, sceneNumber, exact[sceneNumber])
  end
  local second = compileScene(romFs, versionId, 2)
  checkScene2Motion(strictManifest(second, versionId, 2))
  for _, sceneNumber in ipairs({ 1, 2, 3, 4 }) do
    local bundle = compileScene(romFs, versionId, sceneNumber)
    local manifest = strictManifest(bundle, versionId, sceneNumber)
    for _, clip in ipairs(manifest.spriteClips) do
      Assert.isTrue(
        type(clip.frames) == "table" and #clip.frames > 0,
        "scene " .. sceneNumber .. " keeps its clip frames"
      )
      for _, frame in ipairs(clip.frames) do
        Assert.isTrue(
          type(frame.offsetX) == "number" and type(frame.offsetY) == "number",
          "scene " .. sceneNumber .. " keeps its frame offsets"
        )
        Assert.isTrue(
          type(frame.duration) == "number" and frame.duration > 0,
          "scene " .. sceneNumber .. " keeps its frame durations"
        )
      end
    end
  end
end

local function effectWaitsResolveToStartedEffects(romFs, versionId)
  local manifests = {}
  for sceneNumber = 1, 5 do
    local bundle = compileScene(romFs, versionId, sceneNumber)
    manifests[sceneNumber] = strictManifest(bundle, versionId, sceneNumber)
  end
  for sceneNumber = 1, 5 do
    local _, events = strictTimeline(manifests[sceneNumber], sceneNumber)
    checkStepClock(events, sceneNumber)
    checkEffectGraph(manifests[sceneNumber], sceneNumber)
  end
  stepById(manifests[1], 1, "run")
  Assert.equal(fadeTickInStep(manifests[1], 1, "run"), 90, "scene 1 fades at its run step threshold")
  stepById(manifests[5], 5, "wait")
  Assert.equal(fadeTickInStep(manifests[5], 5, "wait"), 20, "scene 5 fades at its wait step threshold")
  local fourth = manifests[4]
  local finale = fourth.timeline.steps[#fourth.timeline.steps]
  Assert.isTrue(type(finale) == "table" and type(finale["until"]) == "table", "scene 4 keeps its closing wait")
  local target = finale["until"].effect or finale["until"].clip or finale["until"].clipId
  Assert.isTrue(type(target) == "string", "scene 4 names its closing completion")
  local started = startedEffectIds(fourth.timeline.events)
  local clips = awaitableClipIds(fourth, fourth.timeline.events)
  Assert.isTrue(
    started[target] == true or clips[target] == true,
    "scene 4 binds its closing sparkle to a started effect or a compiled clip"
  )
end

local ENTRY_MAPPING = { [1] = "lower", [2] = "upper", [3] = "upper", [4] = "lower", [5] = "lower" }

local function physicalSwapsAreExplicitMappingEvents(romFs, versionId)
  for sceneNumber = 1, 5 do
    local bundle = compileScene(romFs, versionId, sceneNumber)
    local manifest = strictManifest(bundle, versionId, sceneNumber)
    local _, events = strictTimeline(manifest, sceneNumber)
    local mappings = {}
    for _, event in ipairs(events) do
      if event.op == "setScreenMapping" then
        mappings[#mappings + 1] = event
      end
    end
    Assert.isTrue(#mappings >= 1, "scene " .. sceneNumber .. " records its physical display mapping")
    for _, mapping in ipairs(mappings) do
      Assert.isTrue(
        mapping.mainPhysical == "upper" or mapping.mainPhysical == "lower",
        "scene " .. sceneNumber .. " maps its main engine to one physical screen"
      )
      Assert.isTrue(
        type(mapping.atStepTick) == "number" and mapping.atStepTick >= 0,
        "scene " .. sceneNumber .. " times its mapping on the source step clock"
      )
    end
    local entry = mappings[1]
    for _, mapping in ipairs(mappings) do
      if mapping.atStepTick < entry.atStepTick then
        entry = mapping
      end
    end
    Assert.equal(
      entry.mainPhysical,
      ENTRY_MAPPING[sceneNumber],
      "scene " .. sceneNumber .. " starts on its source physical screen"
    )
    if sceneNumber == 4 then
      local phases = {}
      for _, mapping in ipairs(mappings) do
        phases[mapping.mainPhysical] = true
      end
      local count = 0
      for _ in pairs(phases) do
        count = count + 1
      end
      Assert.isTrue(count >= 2, "scene 4 flips its physical mapping mid-scene")
    end
  end
end

local function wireMaliciousEvent(manifest, event)
  local copy = deepCopyManifest(manifest)
  local firstStep = copy.timeline.steps[1]
  local index = #copy.timeline.events + 1
  event.stepId = firstStep.id
  copy.timeline.events[index] = event
  firstStep.events[#firstStep.events + 1] = index
  return copy
end

local function strictValidationAcceptsOnlyCompleteContracts(romFs, versionId)
  local compiled = {}
  for sceneNumber = 1, 5 do
    compiled[sceneNumber] = compileScene(romFs, versionId, sceneNumber)
  end
  local staleManifest = deepCopyManifest(compiled[2].manifest)
  staleManifest.schema = "g4-startup-opening-scene-v2"
  local staleLoaded, staleErr = strictLoad(versionId, 2, staleManifest, compiled[2].files, nil)
  Assert.isNil(staleLoaded, "a stale schema never validates")
  Assert.notNil(staleErr, "a stale schema reports its cause")
  local maliciousManifest =
    wireMaliciousEvent(compiled[1].manifest, { op = "waitEffects", atStepTick = 0, effects = { "no-such-effect" } })
  local badWait, badWaitErr = strictLoad(versionId, 1, maliciousManifest, compiled[1].files, nil)
  Assert.isNil(badWait, "an unstarted effect wait never validates")
  Assert.notNil(badWaitErr, "an unstarted effect wait reports its cause")
  local missingImage = firstLayerImage(compiled[3].manifest)
  Assert.notNil(missingImage, "scene 3 carries art to drop for its missing-image check")
  local missingManifest = deepCopyManifest(compiled[3].manifest)
  local missing, missingErr = strictLoad(versionId, 3, missingManifest, compiled[3].files, missingImage)
  Assert.isNil(missing, "a scene with missing art never validates")
  Assert.notNil(missingErr, "missing art reports its cause")
  local badRoleManifest =
    wireMaliciousEvent(compiled[4].manifest, { op = "setScreenMapping", atStepTick = 0, mainPhysical = "sideways" })
  local badRole, badRoleErr = strictLoad(versionId, 4, badRoleManifest, compiled[4].files, nil)
  Assert.isNil(badRole, "a scene with a bad physical role never validates")
  Assert.notNil(badRoleErr, "a bad physical role reports its cause")
  for sceneNumber = 1, 5 do
    local manifest = strictManifest(compiled[sceneNumber], versionId, sceneNumber)
    local loaded, err = strictLoad(versionId, sceneNumber, manifest, compiled[sceneNumber].files, nil)
    Assert.notNil(loaded, "scene " .. sceneNumber .. " validates under the strict contract: " .. tostring(err))
    Assert.equal(loaded.sceneNumber, sceneNumber, "scene " .. sceneNumber .. " reads back under its own key")
    Assert.equal(loaded.versionId, versionId, "scene " .. sceneNumber .. " reads back its edition")
  end
end

local function setLayerAt(events, stepId)
  local found = {}
  for _, event in ipairs(events) do
    if event.op == "setLayer" and event.stepId == stepId then
      found[#found + 1] = event
    end
  end
  return found
end

local function planeStateAt(manifest, events, stepId)
  local state = {}
  for _, role in ipairs({ "main", "sub" }) do
    for _, layer in ipairs(manifest.layers[role]) do
      state[role .. ":" .. layer.bgSlot] = layer.initialVisible
    end
  end
  -- Replay in step order up to and including the named step: later steps
  -- must not leak into the snapshot.
  local ordered = opsInOrder(manifest, events)
  local targetPos = stepPosition(manifest, stepId)
  for _, event in ipairs(ordered) do
    local eventPos = stepPosition(manifest, event.stepId)
    if (eventPos or 0) > (targetPos or 0) then
      break
    end
    if event.op == "setLayer" then
      state[event.engine .. ":" .. event.bgSlot] = event.visible
    end
  end
  return state
end

local function starterMappingAndPlaneMasksFollowTheRetailFlipOrder(romFs, versionId)
  local bundle = compileScene(romFs, versionId, 4)
  local manifest = strictManifest(bundle, versionId, 4)
  local _, events = strictTimeline(manifest, 4)
  local ordered = opsInOrder(manifest, events)
  local mappings = {}
  for _, event in ipairs(ordered) do
    if event.op == "setScreenMapping" then
      mappings[#mappings + 1] = event
    end
  end
  Assert.equal(#mappings, 3, "scene 4 records its entry mapping and its two starter flips")
  Assert.equal(mappings[1].mainPhysical, "lower", "scene 4 opens with its main engine on the lower screen")
  Assert.equal(
    mappings[2].mainPhysical,
    "upper",
    "the first flip moves the main engine upper for the second starter"
  )
  Assert.equal(
    mappings[3].mainPhysical,
    "lower",
    "the second flip returns the main engine lower for the third starter"
  )
  Assert.equal(mappings[2].stepId, "flip-chikorita", "the first flip follows the first starter")
  Assert.equal(mappings[3].stepId, "flip-cyndaquil", "the second flip follows the second starter")
  local function visibleAt(stepId, engine, bgSlot)
    local state = planeStateAt(manifest, events, stepId)
    return state[engine .. ":" .. bgSlot]
  end
  Assert.isTrue(visibleAt("flip-chikorita", "main", 2), "the first flip enables main plane 2")
  Assert.isFalse(visibleAt("flip-chikorita", "main", 3), "the first flip disables main plane 3")
  Assert.isFalse(visibleAt("flip-chikorita", "sub", 2), "the first flip disables sub plane 2")
  Assert.isTrue(visibleAt("flip-chikorita", "sub", 3), "the first flip enables sub plane 3")
  Assert.isFalse(visibleAt("flip-cyndaquil", "main", 2), "the second flip disables main plane 2")
  Assert.isTrue(visibleAt("flip-cyndaquil", "main", 3), "the second flip enables main plane 3")
  Assert.isTrue(visibleAt("flip-cyndaquil", "sub", 2), "the second flip enables sub plane 2")
  Assert.isFalse(visibleAt("flip-cyndaquil", "sub", 3), "the second flip disables sub plane 3")
end

local EXPECTED_INITIAL_PLANES = {
  [1] = {
    ["main:0"] = false,
    ["main:1"] = false,
    ["main:2"] = false,
    ["main:3"] = false,
    ["sub:0"] = false,
    ["sub:1"] = false,
    ["sub:3"] = false,
  },
  [2] = { ["main:2"] = true, ["main:1"] = true, ["main:0"] = true, ["sub:0"] = true },
  [3] = { ["sub:0"] = true, ["sub:3"] = true, ["sub:1"] = false, ["sub:2"] = false },
  [4] = {
    ["main:1"] = false,
    ["main:2"] = false,
    ["main:3"] = true,
    ["sub:1"] = false,
    ["sub:2"] = true,
    ["sub:3"] = true,
  },
  [5] = { ["sub:1"] = true, ["sub:2"] = true, ["main:1"] = true, ["main:2"] = true },
}

local function planeEnableStateIsExplicitInEveryCompiledScene(romFs, versionId)
  for sceneNumber = 1, 5 do
    local bundle = compileScene(romFs, versionId, sceneNumber)
    local manifest = strictManifest(bundle, versionId, sceneNumber)
    local wanted = assert(EXPECTED_INITIAL_PLANES[sceneNumber], "scene carries expected plane state")
    local seen = 0
    for _, role in ipairs({ "main", "sub" }) do
      for _, layer in ipairs(manifest.layers[role]) do
        local key = role .. ":" .. layer.bgSlot
        Assert.notNil(wanted[key], "scene " .. sceneNumber .. " compiles only its known slot " .. key)
        Assert.equal(
          layer.initialVisible,
          wanted[key],
          "scene " .. sceneNumber .. " slot " .. key .. " declares its post-init plane state"
        )
        seen = seen + 1
      end
    end
    local count = 0
    for _ in pairs(wanted) do
      count = count + 1
    end
    Assert.equal(seen, count, "scene " .. sceneNumber .. " declares every compiled slot exactly once")
    local _, events = strictTimeline(manifest, sceneNumber)
    for _, event in ipairs(events) do
      if event.op == "setLayer" then
        Assert.isTrue(
          event.visible == true or event.visible == false,
          "scene " .. sceneNumber .. " toggles planes with an explicit boolean"
        )
      end
    end
  end
  local first = strictManifest(compileScene(romFs, versionId, 1), versionId, 1)
  local _, firstEvents = strictTimeline(first, 1)
  local copyright = planeStateAt(first, firstEvents, "copyright")
  Assert.isTrue(copyright["main:0"], "the copyright enables the main plane")
  Assert.isTrue(copyright["sub:0"], "the copyright enables the sub plane")
  Assert.isFalse(copyright["sub:1"], "the copyright leaves the second sub plane dark")
  local setup = planeStateAt(first, firstEvents, "setup")
  Assert.isFalse(setup["sub:0"], "the logo beat turns the first sub plane off")
  Assert.isTrue(setup["sub:1"], "the logo beat turns the second sub plane on")
  local sunrise = planeStateAt(first, firstEvents, "sunrise")
  Assert.isTrue(sunrise["main:1"] and sunrise["main:2"] and sunrise["main:3"], "sunrise lights the main planes")
  Assert.isTrue(sunrise["sub:3"], "sunrise lights the third sub plane")
  local fourth = strictManifest(compileScene(romFs, versionId, 4), versionId, 4)
  local _, fourthEvents = strictTimeline(fourth, 4)
  local slideIn = planeStateAt(fourth, fourthEvents, "slide-in")
  Assert.isTrue(slideIn["main:1"] and slideIn["sub:1"], "the slide-in enables both first planes")
  local hidden = planeStateAt(fourth, fourthEvents, "hide-hands")
  Assert.isFalse(hidden["main:1"] or hidden["sub:1"], "the slide-out disables both first planes")
  local finale = planeStateAt(fourth, fourthEvents, "finish-totodile")
  Assert.isFalse(
    finale["main:1"] or finale["main:2"] or finale["main:3"],
    "the finale disables the main planes"
  )
  local third = strictManifest(compileScene(romFs, versionId, 3), versionId, 3)
  local _, thirdEvents = strictTimeline(third, 3)
  local borders = planeStateAt(third, thirdEvents, "borders")
  Assert.isFalse(borders["sub:0"], "the border beat turns the rival panel off")
  local aspect = planeStateAt(third, thirdEvents, "aspect")
  Assert.isTrue(aspect["sub:0"], "the widening beat turns the rival panel back on")
  local expansion = planeStateAt(third, thirdEvents, "viewport")
  Assert.isFalse(expansion["sub:0"], "the rocket expansion turns the rival panel off")
end

local function townDrawingStopsBeforeRivalOnlyVisuals(romFs, versionId)
  local bundle = compileScene(romFs, versionId, 3)
  local manifest = strictManifest(bundle, versionId, 3)
  local _, events = strictTimeline(manifest, 3)
  local stops = {}
  for _, event in ipairs(events) do
    if event.op == "setModelVisible" then
      stops[#stops + 1] = event
    end
  end
  Assert.equal(#stops, 1, "scene 3 carries exactly one town drawing stop")
  Assert.isFalse(stops[1].visible, "the town stop disables town drawing")
  local stopStep = stepPosition(manifest, stops[1].stepId)
  local lastTown = stepPosition(manifest, "show-ecruteak-city")
  local rivalOnly = stepPosition(manifest, "panels")
  Assert.isTrue((stopStep or 0) > (lastTown or 0), "the town stop fires after the last town beat")
  Assert.isTrue((stopStep or 0) < (rivalOnly or 0), "the town stop fires before the rival-only beats")
  Assert.equal(#manifest.models, 3, "the town models stay staged after the drawing stop")
  for _, event in ipairs(events) do
    Assert.isFalse(event.op == "finish" and (stepPosition(manifest, event.stepId) or 0) < (stopStep or 0)
      , "no early finish ends the scene before the town stop")
  end
end

local function engineWindowRecordsReplaceTheSyntheticKindShapes(romFs, versionId)
  local fourthBundle = compileScene(romFs, versionId, 4)
  local fourth = strictManifest(fourthBundle, versionId, 4)
  local _, fourthEvents = strictTimeline(fourth, 4)
  local windows = {}
  for _, event in ipairs(fourthEvents) do
    if event.op == "window" then
      windows[#windows + 1] = event
    end
  end
  Assert.equal(#windows, 4, "scene 4 carries its two slide-in and two slide-out windows")
  for _, window in ipairs(windows) do
    Assert.isTrue(window.target == nil and window.kind == nil, "windows carry no synthetic shape")
    Assert.isTrue(window.engine == "main" or window.engine == "sub", "windows name their source engine")
    Assert.equal(window.ticks, 10, "scene 4 slides run ten source frames")
    Assert.equal(window.insideMask, 30, "scene 4 slides keep their inside mask")
    Assert.equal(window.outsideMask, 28, "scene 4 slides keep their outside mask")
  end
  local slideIn = {}
  for _, window in ipairs(windows) do
    if window.stepId == "slide-in" then
      slideIn[#slideIn + 1] = window
    end
  end
  Assert.equal(#slideIn, 2, "the slide-in carries one window per engine")
  for _, window in ipairs(slideIn) do
    if window.engine == "sub" then
      Assert.deepEqual(
        { window.from, window.to },
        { { x1 = 255, y1 = 0, x2 = 255, y2 = 192 }, { x1 = 0, y1 = 0, x2 = 255, y2 = 192 } },
        "the sub slide opens right to left"
      )
    else
      Assert.deepEqual(
        { window.from, window.to },
        { { x1 = 0, y1 = 0, x2 = 0, y2 = 192 }, { x1 = 0, y1 = 0, x2 = 255, y2 = 192 } },
        "the main slide opens left to right"
      )
    end
  end
  local thirdBundle = compileScene(romFs, versionId, 3)
  local third = strictManifest(thirdBundle, versionId, 3)
  local _, thirdEvents = strictTimeline(third, 3)
  local narrow, widen = nil, nil
  local secondaries = 0
  local subVisibilities = 0
  local mainDisables = 0
  for _, event in ipairs(thirdEvents) do
    if event.op == "window" then
      Assert.equal(event.engine, "sub", "every scene 3 pan addresses the sub engine")
      Assert.isTrue(event.target == nil and event.kind == nil, "scene 3 windows carry no synthetic shape")
      if event.ticks == 5 then
        narrow = event
      end
      if event.atStepTick == 44 then
        widen = event
      end
    elseif event.op == "setWindowSecondary" then
      secondaries = secondaries + 1
      Assert.equal(event.engine, "sub", "manual overrides address the sub engine")
    elseif event.op == "setWindowVisible" then
      if event.engine == "sub" then
        subVisibilities = subVisibilities + 1
      else
        Assert.equal(event.engine, "main", "visibility toggles name a source engine")
        Assert.isFalse(event.visible, "the main engine window is only ever disabled")
        mainDisables = mainDisables + 1
      end
    end
  end
  Assert.notNil(narrow, "scene 3 keeps its five-frame narrow pan")
  Assert.notNil(widen, "scene 3 keeps its widening pan at tick 44")
  Assert.equal(widen.ticks, 7, "the widening pan runs seven source frames")
  Assert.isTrue(secondaries >= 3, "scene 3 keeps its manual window overrides")
  Assert.isTrue(subVisibilities >= 3, "scene 3 keeps its window visibility toggles")
  Assert.equal(mainDisables, 1, "scene 3 disables the never-shown main window once")
end

-- Compiled backgrounds keep every authored source tile: each layer records
-- its complete native extent, alternates resolve to staged images with
-- their own extents, and at least one layer exceeds the retail display
-- where the source map is larger than one screen.
local function pngDimensions(bundle, path, sceneNumber)
  local bytes = assert(bundle.files[path], "scene " .. sceneNumber .. " stages its art: " .. tostring(path))
  local width, height = PngReader.rgba(bytes)
  return width, height
end

local function backgroundLayersKeepTheirFullSourceMapExtents(romFs, versionId)
  local sawNativeExtent, sawAlternateRecord = false, false
  for sceneNumber = 1, 5 do
    local bundle = compileScene(romFs, versionId, sceneNumber)
    local manifest = assert(bundle.manifest, "scene " .. sceneNumber .. " publishes its manifest")
    local layers = assert(manifest.layers, "scene " .. sceneNumber .. " carries its engine layers")
    for _, engine in ipairs({ "main", "sub" }) do
      for _, layer in
        ipairs(assert(layers[engine], "scene " .. sceneNumber .. " keys its " .. engine .. " layers"))
      do
        local slot = "scene " .. sceneNumber .. " " .. engine .. " slot " .. tostring(layer.bgSlot)
        Assert.isTrue(
          type(layer.width) == "number" and layer.width % 1 == 0 and layer.width >= 256,
          slot .. " covers at least the retail display width"
        )
        Assert.isTrue(
          type(layer.height) == "number" and layer.height % 1 == 0 and layer.height >= 192,
          slot .. " covers at least the retail display height"
        )
        local decodedWidth, decodedHeight = pngDimensions(bundle, layer.image, sceneNumber)
        Assert.equal(decodedWidth, layer.width, slot .. " base art decodes to its recorded extent")
        Assert.equal(decodedHeight, layer.height, slot .. " base art decodes to its recorded extent")
        if layer.width > 256 or layer.height > 192 then
          sawNativeExtent = true
        end
        Assert.isTrue(type(layer.variants) == "table", slot .. " keeps its alternates as a record list")
        for _, variant in ipairs(layer.variants) do
          Assert.isTrue(
            type(variant) == "table",
            slot .. " keeps each alternate as an image record with its own extent, not a bare path"
          )
          Assert.isTrue(
            type(variant.image) == "string" and variant.image ~= "",
            slot .. " points its alternate at a compiled image"
          )
          Assert.isTrue(
            type(variant.width) == "number" and variant.width % 1 == 0 and variant.width >= 256,
            slot .. " records its alternate width"
          )
          Assert.isTrue(
            type(variant.height) == "number" and variant.height % 1 == 0 and variant.height >= 192,
            slot .. " records its alternate height"
          )
          local alternateWidth, alternateHeight = pngDimensions(bundle, variant.image, sceneNumber)
          Assert.equal(alternateWidth, variant.width, slot .. " alternate art decodes to its recorded extent")
          Assert.equal(alternateHeight, variant.height, slot .. " alternate art decodes to its recorded extent")
          sawAlternateRecord = true
        end
      end
    end
  end
  Assert.isTrue(
    sawNativeExtent,
    "at least one compiled layer keeps a native extent beyond the retail display"
  )
  Assert.isTrue(sawAlternateRecord, "at least one compiled layer carries an alternate image record")
end

local function initScrolls(manifest, engine, bgSlot)
  local found = {}
  for _, event in ipairs(manifest.timeline.events) do
    if
      event.op == "setScroll"
      and event.engine == engine
      and event.bgSlot == bgSlot
      and type(event.ticks) == "number"
      and event.ticks <= 0
    then
      found[#found + 1] = event
    end
  end
  return found
end

local function requireInitScroll(manifest, sceneNumber, engine, bgSlot, ticks, dx, dy)
  local slot = "scene " .. sceneNumber .. " " .. engine .. " slot " .. bgSlot
  local match = nil
  for _, event in ipairs(initScrolls(manifest, engine, bgSlot)) do
    if event.ticks == ticks and event.dx == dx and event.dy == dy then
      match = event
    end
  end
  Assert.notNil(match, slot .. " starts from its source origin")
  Assert.equal(match.atStepTick, 0, slot .. " applies its starting offset on the first source tick")
  Assert.equal(
    stepPosition(manifest, match.stepId),
    1,
    slot .. " applies its starting offset before the first painted frame"
  )
  Assert.isNil(match.effect, slot .. " starting offsets schedule no effect wait")
end

-- The source starting offsets reach the timeline as instant and continuous
-- scrolls: every displacement is whole source pixels, instant and
-- continuous modes schedule no effect wait, and timed panoramas survive
-- beside them.
local function openingProgramsStartFromTheirSourceOrigins(romFs, versionId)
  local compiled = {}
  for sceneNumber = 1, 5 do
    local bundle = compileScene(romFs, versionId, sceneNumber)
    local manifest = assert(bundle.manifest, "scene " .. sceneNumber .. " publishes its manifest")
    compiled[sceneNumber] = manifest
    for _, event in ipairs(manifest.timeline.events) do
      if event.op == "setScroll" then
        local where = "scene " .. sceneNumber .. " scroll"
        Assert.isTrue(
          type(event.dx) == "number" and event.dx % 1 == 0,
          where .. " displaces by whole source pixels"
        )
        Assert.isTrue(
          type(event.dy) == "number" and event.dy % 1 == 0,
          where .. " displaces by whole source pixels"
        )
        Assert.isTrue(
          type(event.ticks) == "number" and event.ticks % 1 == 0 and event.ticks >= -1,
          where .. " uses an instant, continuous, or timed mode"
        )
        if event.ticks <= 0 then
          Assert.isNil(event.effect, where .. " immediate and continuous scrolls schedule no effect wait")
        end
      end
    end
  end
  requireInitScroll(compiled[2], 2, "main", 1, 0, 0, 320)
  requireInitScroll(compiled[2], 2, "main", 0, 0, 0, 192)
  requireInitScroll(compiled[2], 2, "main", 2, -1, 0, 64)
  requireInitScroll(compiled[2], 2, "sub", 0, -1, 0, 64)
  requireInitScroll(compiled[4], 4, "sub", 1, 0, -192, 0)
  requireInitScroll(compiled[4], 4, "main", 1, 0, 192, 0)
  local copyright = initScrolls(compiled[1], "main", 0)
  Assert.isTrue(#copyright >= 2, "scene 1 resets its copyright offset after showing it")
  Assert.equal(copyright[1].dx, 0, "scene 1 shows its copyright from its source offset")
  Assert.equal(copyright[1].dy, 128, "scene 1 shows its copyright from its source offset")
  local total = 0
  for _, event in ipairs(copyright) do
    Assert.equal(event.ticks, 0, "scene 1 copyright offsets apply immediately")
    total = total + event.dy
  end
  Assert.equal(total, 0, "scene 1 returns to its origin after the copyright")
  requireInitScroll(compiled[5], 5, "main", 2, 0, 0, 160)
  requireInitScroll(compiled[5], 5, "sub", 2, 0, 0, 160)
  local sawPanorama = false
  for _, event in ipairs(compiled[5].timeline.events) do
    if event.op == "setScroll" and event.ticks == 73 and math.abs(event.dy) == 64 then
      sawPanorama = true
    end
  end
  Assert.isTrue(sawPanorama, "scene 5 keeps its timed panorama beside its starting offsets")
end

-- Blends and wipes travel with per-engine source operands: six-bit plane
-- masks, a source direction, and positive durations for blends; an engine,
-- a source kind, and a positive duration for wipes. Independent engine
-- tasks complete under independent identities.
local function engineBlendsAndWipesCarrySourceOperands(romFs, versionId)
  local compiled = {}
  for sceneNumber = 1, 5 do
    local bundle = compileScene(romFs, versionId, sceneNumber)
    compiled[sceneNumber] = assert(bundle.manifest, "scene " .. sceneNumber .. " publishes its manifest")
  end
  local sawBlend, sawWipe = false, false
  local wipesByScene = {}
  for sceneNumber = 1, 5 do
    local blendOwners = {}
    for _, event in ipairs(compiled[sceneNumber].timeline.events) do
      if event.op == "setBlend" then
        sawBlend = true
        local where = "scene " .. sceneNumber .. " blend"
        Assert.isTrue(
          event.engine == "main" or event.engine == "sub",
          where .. " targets one stage engine"
        )
        for _, mask in ipairs({ event.firstMask, event.secondMask }) do
          Assert.isTrue(
            type(mask) == "number" and mask % 1 == 0 and mask >= 0 and mask <= 63,
            where .. " selects source planes with a six-bit mask"
          )
        end
        Assert.isTrue(
          event.direction == 0 or event.direction == 1,
          where .. " animates in one source direction"
        )
        Assert.isTrue(
          type(event.ticks) == "number" and event.ticks % 1 == 0 and event.ticks > 0,
          where .. " runs a positive source duration"
        )
        if type(event.effect) == "string" then
          local owner = blendOwners[event.stepId .. "\0" .. event.effect]
          if owner == nil then
            blendOwners[event.stepId .. "\0" .. event.effect] = event.engine
          else
            Assert.equal(owner, event.engine, where .. " keeps one engine per blend completion identity")
          end
        end
      elseif event.op == "circleWipe" then
        sawWipe = true
        wipesByScene[sceneNumber] = true
        local where = "scene " .. sceneNumber .. " wipe"
        Assert.isTrue(
          event.engine == "main" or event.engine == "sub",
          where .. " targets one stage engine"
        )
        Assert.isTrue(
          type(event.kind) == "number" and event.kind % 1 == 0 and event.kind >= 0 and event.kind <= 3,
          where .. " carries a source wipe kind"
        )
        Assert.isTrue(
          type(event.ticks) == "number" and event.ticks % 1 == 0 and event.ticks > 0,
          where .. " runs a positive source duration"
        )
      end
    end
  end
  Assert.isTrue(sawBlend, "at least one compiled scene carries an engine blend")
  Assert.isTrue(sawWipe, "at least one compiled scene carries an engine wipe")
  for _, sceneNumber in ipairs({ 2, 3 }) do
    Assert.isTrue(wipesByScene[sceneNumber] == true, "scene " .. sceneNumber .. " keeps its source wipe")
  end
  Assert.isNil(wipesByScene[5], "scene 5 carries its sequential line shutter instead of a circle wipe")
  local fades = {}
  for _, event in ipairs(compiled[1].timeline.events) do
    if event.op == "setBlend" and event.stepId == "fades" then
      fades[#fades + 1] = event
    end
  end
  Assert.equal(#fades, 2, "scene 1 fades its two stage engines")
  local engines = {}
  for _, blend in ipairs(fades) do
    engines[blend.engine] = true
    Assert.equal(blend.ticks, 60, "scene 1 copyright blends run their source duration")
    Assert.equal(blend.direction, 1, "scene 1 copyright blends animate in their source direction")
    Assert.isTrue(
      type(blend.effect) == "string" and blend.effect ~= "",
      "scene 1 copyright blends complete under a named identity"
    )
  end
  Assert.isTrue(engines.main and engines.sub, "scene 1 copyright blends cover both stage engines")
  local mainBlend = nil
  for _, blend in ipairs(fades) do
    if blend.engine == "main" then
      mainBlend = blend
    end
  end
  Assert.notNil(mainBlend, "scene 1 fades its main engine")
  Assert.equal(mainBlend.firstMask, 1, "scene 1 main copyright blend selects its source planes")
  Assert.equal(mainBlend.secondMask, 32, "scene 1 main copyright blend selects its backdrop plane")
  Assert.isTrue(fades[1].effect ~= fades[2].effect, "scene 1 copyright blends complete independently per engine")
  local sawShutter18 = false
  local sawWipe18 = false
  for _, event in ipairs(compiled[5].timeline.events) do
    if event.op == "shutterFade" and event.steps == 18 then
      sawShutter18 = true
    end
    if event.op == "circleWipe" then
      sawWipe18 = true
    end
  end
  Assert.isTrue(sawShutter18, "scene 5 keeps its 18-step sequential line shutter")
  Assert.isFalse(sawWipe18, "scene 5 carries no circle wipe")
end

-- Pinned SS native extents transcribed from the compiled bundles produced
-- by the exact-ROM probe (f8dc38ea soulsilver cache): scene 2 main BG1 is
-- the 512x512 aerial map, scene 5 BG2s are the 256x512 panorama maps, and
-- every other opening layer decodes to the extent below. HeartGold uses
-- different source members, so other editions assert the structural
-- contract (manifest extent equals decoded PNG extent, opaque wrap edges)
-- without edition-specific pinned sizes.
local PINNED_SS_EXTENTS = {
  [1] = {
    main = { [0] = { 256, 256 }, [1] = { 256, 256 }, [2] = { 256, 256 }, [3] = { 256, 256 } },
    sub = { [0] = { 256, 256 }, [1] = { 256, 192 }, [3] = { 256, 256 } },
  },
  [2] = {
    main = { [0] = { 256, 256 }, [1] = { 512, 512 }, [2] = { 256, 256 } },
    sub = { [0] = { 256, 256 } },
  },
  [3] = {
    sub = { [0] = { 256, 256 }, [1] = { 256, 256 }, [2] = { 256, 256 }, [3] = { 256, 256 } },
  },
  [4] = {
    main = { [1] = { 256, 256 }, [2] = { 256, 256 }, [3] = { 256, 256 } },
    sub = { [1] = { 256, 256 }, [2] = { 256, 256 }, [3] = { 256, 256 } },
  },
  [5] = {
    main = { [1] = { 256, 256 }, [2] = { 256, 512 } },
    sub = { [1] = { 256, 256 }, [2] = { 256, 512 } },
  },
}

-- Pinned SS wrap-edge alpha topology transcribed from the exact-ROM
-- probe (f8dc38ea soulsilver cache): one letter per top/bottom/left/right
-- edge midpoint, O for opaque and T for transparent. Transparent edges are
-- legitimate masked content: the plane pass sees through them, and the
-- graphics conformance suite samples only opaque texels as decisive while
-- still requiring full-viewport coverage. Opaque edges prove the tile
-- coverage reaches the wrap seam. Pixel VALUES against native art are
-- proved on the graphics side (viewport versus wrapped staged bytes);
-- this side proves the full map decoded at its native extent.
local PINNED_SS_EDGE_TOPOLOGY = {
  [1] = {
    main = { [0] = "TOTT", [1] = "OTOO", [2] = "TTTT", [3] = "TTOO" },
    sub = { [0] = "TTTT", [1] = "TTTT", [3] = "OOOO" },
  },
  [2] = {
    main = { [0] = "TTTT", [1] = "OTOO", [2] = "OOOO" },
    sub = { [0] = "OOOO" },
  },
  [3] = {
    sub = {
      [0] = { "OTOO", "OTTO", "OTTT", "OTTT", "TTTT" },
      [1] = { "OTTT", "TTTT" },
      [2] = { "TTOO", "TTTO" },
      [3] = { "OTOO", "OOOO" },
    },
  },
  [4] = {
    main = { [1] = "TTTT", [2] = "OTOO", [3] = "OTOO" },
    sub = { [1] = "TTTT", [2] = "OTOO", [3] = "OTOO" },
  },
  [5] = {
    main = { [1] = "TTTT", [2] = "TTOO" },
    sub = { [1] = "TTTT", [2] = "TTOO" },
  },
}

---@param data love.ImageData decoded staged art
---@return string edge alpha signature, O for opaque and T for transparent
local function edgeTopology(data)
  local width, height = data:getWidth(), data:getHeight()
  local letters = {}
  for _, edge in ipairs({
    { math.floor(width / 2), 0 },
    { math.floor(width / 2), height - 1 },
    { 0, math.floor(height / 2) },
    { width - 1, math.floor(height / 2) },
  }) do
    local _, _, _, alpha = data:getPixel(edge[1], edge[2])
    letters[#letters + 1] = (alpha > 0.5) and "O" or "T"
  end
  return table.concat(letters)
end

-- Full base/variant extents reproduce the decoded NSCR renders, and every
-- wrap edge midpoint stays opaque: retail tilemap art carries no
-- transparency, so a transparent edge would mean missing tiles rather
-- than legitimate source-black content (opaque black edges pass).
---@param bundle table compiled scene bundle
---@param path string staged image path
---@param sceneNumber integer retail scene position
---@return love.ImageData decoded art pixels
local function decodedBundleImage(bundle, path, sceneNumber)
  local bytes = assert(bundle.files[path], "scene " .. sceneNumber .. " stages its art: " .. tostring(path))
  local fileData = love.filesystem.newFileData(bytes, path)
  return love.image.newImageData(fileData)
end

-- Full base/variant extents reproduce the decoded NSCR renders, and every
-- wrap edge midpoint keeps its pinned alpha topology: retail tilemap art
-- mixes opaque coverage with legitimately masked overlays, so transparent
-- midpoints are recorded explicitly instead of failing as missing tiles.
local function pinnedNativeExtentsAndWrapEdgeTopology(romFs, versionId)
  local pinned = PINNED_SS_EXTENTS
  for sceneNumber = 1, 5 do
    local bundle = compileScene(romFs, versionId, sceneNumber)
    local manifest = assert(bundle.manifest, "scene " .. sceneNumber .. " publishes its manifest")
    local scenePinned = (versionId == "soulsilver") and pinned[sceneNumber] or nil
    for _, engine in ipairs({ "main", "sub" }) do
      for _, layer in ipairs(assert(manifest.layers[engine], "scene " .. sceneNumber .. " keys its " .. engine .. " layers")) do
        local where = "scene " .. sceneNumber .. " " .. engine .. " slot " .. tostring(layer.bgSlot)
        local data = decodedBundleImage(bundle, layer.image, sceneNumber)
        Assert.equal(data:getWidth(), layer.width, where .. " base art decodes to its recorded width")
        Assert.equal(data:getHeight(), layer.height, where .. " base art decodes to its recorded height")
        if scenePinned ~= nil and scenePinned[engine] ~= nil and scenePinned[engine][layer.bgSlot] ~= nil then
          local want = scenePinned[engine][layer.bgSlot]
          Assert.equal(layer.width, want[1], where .. " keeps its pinned SS native width")
          Assert.equal(layer.height, want[2], where .. " keeps its pinned SS native height")
        end
        Assert.isTrue(layer.width >= 256 and layer.height >= 192, where .. " covers at least the retail display")
        if scenePinned ~= nil then
          local topologyPinned = PINNED_SS_EDGE_TOPOLOGY[sceneNumber]
            and PINNED_SS_EDGE_TOPOLOGY[sceneNumber][engine]
            and PINNED_SS_EDGE_TOPOLOGY[sceneNumber][engine][layer.bgSlot]
          if type(topologyPinned) == "table" then
            topologyPinned = topologyPinned[1]
          end
          if topologyPinned ~= nil then
            Assert.equal(
              edgeTopology(data),
              topologyPinned,
              where .. " keeps its pinned SS wrap-edge topology"
            )
          end
        end
        local variantTopologies = nil
        if scenePinned ~= nil then
          local topologyPinned = PINNED_SS_EDGE_TOPOLOGY[sceneNumber]
            and PINNED_SS_EDGE_TOPOLOGY[sceneNumber][engine]
            and PINNED_SS_EDGE_TOPOLOGY[sceneNumber][engine][layer.bgSlot]
          if type(topologyPinned) == "table" then
            variantTopologies = topologyPinned
          end
        end
        for variantIndex, variant in ipairs(layer.variants or {}) do
          local vwhere = where .. " alternate " .. tostring(variant.image)
          local vdata = decodedBundleImage(bundle, variant.image, sceneNumber)
          Assert.equal(vdata:getWidth(), variant.width, vwhere .. " decodes to its recorded width")
          Assert.equal(vdata:getHeight(), variant.height, vwhere .. " decodes to its recorded height")
          if variantTopologies ~= nil and variantTopologies[variantIndex + 1] ~= nil then
            Assert.equal(
              edgeTopology(vdata),
              variantTopologies[variantIndex + 1],
              vwhere .. " keeps its pinned SS wrap-edge topology"
            )
          end
        end
      end
    end
  end
  local second = compileScene(romFs, versionId, 2).manifest
  local aerial = nil
  for _, layer in ipairs(second.layers.main) do
    if layer.bgSlot == 1 then
      aerial = layer
    end
  end
  Assert.notNil(aerial, "scene 2 keeps its aerial map slot")
  Assert.isTrue(aerial.width > 256 and aerial.height > 192, "scene 2 keeps a native map beyond the retail display")
  local panorama = compileScene(romFs, versionId, 5).manifest
  for _, engine in ipairs({ "main", "sub" }) do
    local tall = nil
    for _, layer in ipairs(panorama.layers[engine]) do
      if layer.bgSlot == 2 then
        tall = layer
      end
    end
    Assert.notNil(tall, "scene 5 " .. engine .. " keeps its panorama slot")
    Assert.isTrue(tall.height > 192, "scene 5 " .. engine .. " keeps a native panorama beyond one screen")
  end
end

---@param manifest table compiled opening-scene manifest
---@param op string event operation
---@param stepId string|nil owning step identity, nil matches any step
---@return table[] matching events
local function collectEvents(manifest, op, stepId)
  local found = {}
  for _, event in ipairs(manifest.timeline.events) do
    if event.op == op and (stepId == nil or event.stepId == stepId) then
      found[#found + 1] = event
    end
  end
  return found
end

---@param event table compiled timeline event
---@param keys string[] field names carried for the comparison
---@return string canonical serialization
local function serializeEvent(event, keys)
  local parts = {}
  for _, key in ipairs(keys) do
    parts[#parts + 1] = key .. "=" .. tostring(event[key])
  end
  return table.concat(parts, " ")
end

---@param manifest table compiled opening-scene manifest
---@param sceneNumber integer retail scene position
---@param op string event operation
---@param stepId string owning step identity
---@param keys string[] compared field names
---@param expected string[] canonical expected serializations
local function assertExactEvents(manifest, sceneNumber, op, stepId, keys, expected)
  local actual = {}
  for _, event in ipairs(collectEvents(manifest, op, stepId)) do
    actual[#actual + 1] = serializeEvent(event, keys)
  end
  table.sort(actual)
  local wanted = {}
  for _, line in ipairs(expected) do
    wanted[#wanted + 1] = line
  end
  table.sort(wanted)
  Assert.deepEqual(
    actual,
    wanted,
    "scene " .. sceneNumber .. " " .. op .. " in step " .. stepId .. " matches its retail calls"
  )
end

local SCROLL_KEYS = { "atStepTick", "engine", "bgSlot", "dx", "dy", "ticks", "effect" }
local BLEND_KEYS = { "atStepTick", "engine", "firstMask", "secondMask", "direction", "ticks", "effect" }
local WIPE_KEYS = { "atStepTick", "engine", "kind", "ticks", "effect" }
local SHUTTER_KEYS =
  { "atStepTick", "order", "mainPattern", "subPattern", "color", "steps", "framesPerStep", "effect" }
local FADE_KEYS = { "atStepTick", "kind", "ticks", "effect" }

-- Independently transcribed source call table: scene 1 main (first 1,
-- second 0x1E) and sub (first 2, second 0x1E); scene 2 final main kind 1
-- ticks 8; scene 3 seven main/main/main/main/main/main/sub wipes at
-- 8 ticks each; scene 5 sequential line shutter. Never derived from
-- compiler output.
local EXPECTED_SCENE3_WIPES = {
  "engine=main kind=0 ticks=8",
  "engine=main kind=3 ticks=8",
  "engine=main kind=2 ticks=8",
  "engine=main kind=3 ticks=8",
  "engine=main kind=2 ticks=8",
  "engine=main kind=3 ticks=8",
  "engine=sub kind=2 ticks=8",
}

local function orderedWipeSignature(manifest)
  local ordered = opsInOrder(manifest, manifest.timeline.events)
  local signatures = {}
  for _, event in ipairs(ordered) do
    if event.op == "circleWipe" then
      signatures[#signatures + 1] = serializeEvent(event, { "engine", "kind", "ticks" })
    end
  end
  return signatures, ordered
end

local function checkScene3SevenWipesWithGates(manifest)
  local signatures, ordered = orderedWipeSignature(manifest)
  Assert.deepEqual(signatures, EXPECTED_SCENE3_WIPES, "scene 3 keeps its seven source circle wipes in order")
  local effects = {}
  for _, event in ipairs(ordered) do
    if event.op == "circleWipe" then
      Assert.isTrue(type(event.effect) == "string" and event.effect ~= "", "scene 3 names each wipe effect")
      Assert.isNil(effects[event.effect], "scene 3 gives each wipe its own completion identity")
      effects[event.effect] = event
    end
  end
  local guardByStep = {}
  for _, step in ipairs(manifest.timeline.steps) do
    guardByStep[step.id] = step["until"]
  end
  for _, event in ipairs(ordered) do
    if event.op == "circleWipe" then
      local guard = guardByStep[event.stepId]
      Assert.notNil(guard, "scene 3 gates step " .. event.stepId .. " on its wipe")
      if (event.engine == "main" and event.kind == 3) or event.engine == "sub" then
        -- Each close holds on its own wipe effect, and the rival reveal
        -- holds on its own wipe, so step order gates the next town beat
        -- on the finished close and the reveal on the retired town.
        Assert.equal(
          guard.effect,
          event.effect,
          "scene 3 gates each close and the rival reveal on its own wipe"
        )
      else
        -- Opens carry no wipe guard of their own: the town hold outlasts
        -- the 8-tick open, and step order gates the close on the open.
        Assert.equal(
          guard.kind,
          "duration",
          "scene 3 holds each town open on its duration instead of its wipe"
        )
      end
    end
  end
  local lastMainCloseAt, retireAt, rivalAt = nil, nil, nil
  for _, event in ipairs(ordered) do
    if event.op == "circleWipe" and event.engine == "main" and event.kind == 3 then
      lastMainCloseAt = stepPosition(manifest, event.stepId)
    elseif event.op == "setModelVisible" and event.visible == false then
      retireAt = stepPosition(manifest, event.stepId)
    elseif event.op == "circleWipe" and event.engine == "sub" then
      rivalAt = stepPosition(manifest, event.stepId)
    end
  end
  Assert.notNil(lastMainCloseAt, "scene 3 keeps its final main close")
  Assert.notNil(retireAt, "scene 3 retires its town drawing")
  Assert.notNil(rivalAt, "scene 3 keeps its rival reveal wipe")
  Assert.isTrue(
    (lastMainCloseAt or 0) <= (retireAt or 0) and (retireAt or 0) <= (rivalAt or 0),
    "scene 3 retires town drawing after the final close and before the rival reveal"
  )
end

-- Every scene 1/2/4/5 scroll offset, continuous job, and timed delta, plus
-- each engine alpha mask/direction/duration and wipe kind/engine/duration
-- with its fade brightness operand, pinned to the retail call at its
-- authoritative step and tick. Scene 5 paired-slot direction is "right"
-- (+64) on SoulSilver and "left" (-64) on HeartGold.
local function pinnedScrollBlendWipeAndFadeOperandsMatchRetailCalls(romFs, versionId)
  local manifests = {}
  for sceneNumber = 1, 5 do
    manifests[sceneNumber] = strictManifest(compileScene(romFs, versionId, sceneNumber), versionId, sceneNumber)
  end
  local first, second, fourth, fifth = manifests[1], manifests[2], manifests[4], manifests[5]
  assertExactEvents(first, 1, "setScroll", "copyright", SCROLL_KEYS, {
    "atStepTick=0 engine=main bgSlot=0 dx=0 dy=128 ticks=0 effect=nil",
    "atStepTick=0 engine=main bgSlot=0 dx=0 dy=-128 ticks=0 effect=nil",
  })
  assertExactEvents(first, 1, "setScroll", "scroll", SCROLL_KEYS, {
    "atStepTick=0 engine=main bgSlot=1 dx=0 dy=-32 ticks=240 effect=scroll-sunrise",
    "atStepTick=0 engine=main bgSlot=2 dx=0 dy=-16 ticks=240 effect=scroll-sunrise",
  })
  assertExactEvents(first, 1, "setBlend", "fades", BLEND_KEYS, {
    "atStepTick=0 engine=main firstMask=1 secondMask=32 direction=1 ticks=60 effect=blend-copyright-main",
    "atStepTick=0 engine=sub firstMask=1 secondMask=32 direction=1 ticks=60 effect=blend-copyright-sub",
  })
  assertExactEvents(first, 1, "setBlend", "scroll", BLEND_KEYS, {
    "atStepTick=0 engine=main firstMask=1 secondMask=30 direction=1 ticks=80 effect=scroll-sunrise-main",
    "atStepTick=0 engine=sub firstMask=2 secondMask=30 direction=1 ticks=80 effect=scroll-sunrise-sub",
  })
  assertExactEvents(first, 1, "setFade", "run", FADE_KEYS, {
    "atStepTick=90 kind=white ticks=65 effect=fade-white",
  })
  assertExactEvents(second, 2, "setScroll", "flyin", SCROLL_KEYS, {
    "atStepTick=0 engine=main bgSlot=0 dx=0 dy=192 ticks=0 effect=nil",
    "atStepTick=0 engine=main bgSlot=1 dx=0 dy=320 ticks=0 effect=nil",
    "atStepTick=0 engine=main bgSlot=2 dx=0 dy=64 ticks=-1 effect=nil",
    "atStepTick=0 engine=sub bgSlot=0 dx=0 dy=64 ticks=-1 effect=nil",
    "atStepTick=56 engine=main bgSlot=0 dx=0 dy=-192 ticks=5 effect=nil",
    "atStepTick=56 engine=main bgSlot=1 dx=0 dy=-192 ticks=5 effect=nil",
  })
  assertExactEvents(second, 2, "setScroll", "slow-pan-ethan", SCROLL_KEYS, {
    "atStepTick=0 engine=main bgSlot=0 dx=32 dy=0 ticks=90 effect=scroll-slow-pan-ethan",
    "atStepTick=0 engine=main bgSlot=1 dx=32 dy=0 ticks=90 effect=scroll-slow-pan-ethan",
  })
  assertExactEvents(second, 2, "setScroll", "fast-pan-lyra", SCROLL_KEYS, {
    "atStepTick=0 engine=main bgSlot=0 dx=64 dy=0 ticks=7 effect=scroll-fast-pan-lyra",
    "atStepTick=0 engine=main bgSlot=1 dx=64 dy=0 ticks=7 effect=scroll-fast-pan-lyra",
  })
  assertExactEvents(second, 2, "setScroll", "slow-pan-lyra", SCROLL_KEYS, {
    "atStepTick=0 engine=main bgSlot=0 dx=32 dy=0 ticks=66 effect=scroll-slow-pan-lyra",
    "atStepTick=0 engine=main bgSlot=1 dx=32 dy=0 ticks=66 effect=scroll-slow-pan-lyra",
  })
  assertExactEvents(second, 2, "setScroll", "lyra-exit", SCROLL_KEYS, {
    "atStepTick=0 engine=main bgSlot=0 dx=0 dy=-64 ticks=5 effect=scroll-lyra-exit",
    "atStepTick=0 engine=main bgSlot=1 dx=0 dy=-128 ticks=10 effect=scroll-lyra-exit",
  })
  assertExactEvents(second, 2, "setFade", "flyin", FADE_KEYS, {
    "atStepTick=0 kind=white-in ticks=3 effect=nil",
    "atStepTick=56 kind=black-out ticks=8 effect=nil",
  })
  assertExactEvents(second, 2, "circleWipe", "wipe", WIPE_KEYS, {
    "atStepTick=0 engine=main kind=1 ticks=8 effect=wipe-circle",
  })
  assertExactEvents(fourth, 4, "setScroll", "fade-in", SCROLL_KEYS, {
    "atStepTick=0 engine=main bgSlot=1 dx=192 dy=0 ticks=0 effect=nil",
    "atStepTick=0 engine=sub bgSlot=1 dx=-192 dy=0 ticks=0 effect=nil",
  })
  assertExactEvents(fourth, 4, "setScroll", "slide-in", SCROLL_KEYS, {
    "atStepTick=0 engine=main bgSlot=1 dx=-192 dy=0 ticks=10 effect=scroll-slide-in",
    "atStepTick=0 engine=sub bgSlot=1 dx=192 dy=0 ticks=10 effect=scroll-slide-in",
  })
  assertExactEvents(fourth, 4, "setScroll", "slide-out", SCROLL_KEYS, {
    "atStepTick=0 engine=main bgSlot=1 dx=-192 dy=0 ticks=10 effect=scroll-slide-out",
    "atStepTick=0 engine=sub bgSlot=1 dx=192 dy=0 ticks=10 effect=scroll-slide-out",
  })
  assertExactEvents(fourth, 4, "setFade", "fade-in", FADE_KEYS, {
    "atStepTick=0 kind=black-shutter-open ticks=10 effect=fade-in",
  })
  assertExactEvents(fourth, 4, "setFade", "finish-totodile", FADE_KEYS, {
    "atStepTick=0 kind=black-shutter-close ticks=26 effect=fade-close",
  })
  local pairedDy = (versionId == "heartgold") and -64 or 64
  assertExactEvents(fifth, 5, "setScroll", "wipe", SCROLL_KEYS, {
    "atStepTick=0 engine=main bgSlot=2 dx=0 dy=160 ticks=0 effect=nil",
    "atStepTick=0 engine=sub bgSlot=2 dx=0 dy=160 ticks=0 effect=nil",
  })
  assertExactEvents(fifth, 5, "setScroll", "scroll", SCROLL_KEYS, {
    "atStepTick=0 engine=main bgSlot=1 dx=0 dy=-64 ticks=73 effect=scroll-panorama",
    "atStepTick=0 engine=main bgSlot=2 dx=0 dy=" .. pairedDy .. " ticks=73 effect=scroll-panorama",
    "atStepTick=0 engine=sub bgSlot=1 dx=0 dy=" .. pairedDy .. " ticks=73 effect=scroll-panorama",
    "atStepTick=0 engine=sub bgSlot=2 dx=0 dy=" .. pairedDy .. " ticks=73 effect=scroll-panorama",
  })
  assertExactEvents(fifth, 5, "shutterFade", "wipe", SHUTTER_KEYS, {
    "atStepTick=0 order=main-then-sub mainPattern=center-out subPattern=bottom-up color=black steps=18 framesPerStep=1 effect=scene5-shutter",
  })
  Assert.equal(#collectEvents(fifth, "circleWipe", nil), 0, "scene 5 carries no circle wipe")
  assertExactEvents(fifth, 5, "setFade", "wait", FADE_KEYS, {
    "atStepTick=20 kind=white ticks=50 effect=fade-white",
  })
  local third = manifests[3]
  checkScene3SevenWipesWithGates(third)
end

-- The retail overlay steps at one source tick per two VBlanks: every
-- opening bundle keeps the 30 Hz source tick rate and an 8-tick wipe
-- still costs exactly 8 source updates. No 60 Hz clock change.
local function movieTickRateRemainsRetail30Hz(romFs, versionId)
  for sceneNumber = 1, 5 do
    local bundle = compileScene(romFs, versionId, sceneNumber)
    local manifest = strictManifest(bundle, versionId, sceneNumber)
    Assert.equal(manifest.schema, "g4-startup-opening-scene-v6", "scene " .. sceneNumber .. " carries the v6 schema")
    Assert.equal(manifest.sourceTickRate, 30, "scene " .. sceneNumber .. " runs at the retail 30 Hz tick rate")
  end
  local second = strictManifest(compileScene(romFs, versionId, 2), versionId, 2)
  local wipes = collectEvents(second, "circleWipe", "wipe")
  Assert.equal(#wipes, 1, "scene 2 keeps its single final wipe")
  Assert.equal(wipes[1].ticks, 8, "the 8-tick wipe costs 8 source updates")
end

-- Case-guard validation: unknown, zero-duration, duplicate, and future-start
-- waits fail the strict reader, an eventless conjunctive wait passes, and
-- the old pseudo-wait marker no longer validates.
local function strictCaseGuardsRejectInvalidWaitsAndAcceptEventlessConjunctions(romFs, versionId)
  local bundle = compileScene(romFs, versionId, 1)
  local unknownManifest = deepCopyManifest(bundle.manifest)
  unknownManifest.timeline.steps[#unknownManifest.timeline.steps + 1] =
    { id = "bad-unknown", events = {}, ["until"] = { kind = "effect", effect = "no-such-effect" } }
  local unknownLoaded, unknownErr = strictLoad(versionId, 1, unknownManifest, bundle.files, nil)
  Assert.isNil(unknownLoaded, "an unknown effect wait never validates")
  Assert.notNil(unknownErr, "an unknown effect wait reports its cause")
  local zeroManifest = deepCopyManifest(bundle.manifest)
  local zeroed = false
  for _, step in ipairs(zeroManifest.timeline.steps) do
    if step["until"].kind == "duration" and not zeroed then
      step["until"].ticks = 0
      zeroed = true
    end
  end
  Assert.isTrue(zeroed, "scene 1 carries a duration step to empty")
  local zeroLoaded, zeroErr = strictLoad(versionId, 1, zeroManifest, bundle.files, nil)
  Assert.isNil(zeroLoaded, "a zero-duration wait never validates")
  Assert.notNil(zeroErr, "a zero-duration wait reports its cause")
  local duplicateManifest = deepCopyManifest(bundle.manifest)
  local lastStep = duplicateManifest.timeline.steps[#duplicateManifest.timeline.steps]
  lastStep.onCompleteEvents = { duplicateManifest.timeline.steps[1].events[1] }
  local duplicateLoaded, duplicateErr = strictLoad(versionId, 1, duplicateManifest, bundle.files, nil)
  Assert.isNil(duplicateLoaded, "an event owned twice never validates")
  Assert.notNil(duplicateErr, "a duplicate event ownership reports its cause")
  local futureManifest = deepCopyManifest(bundle.manifest)
  futureManifest.timeline.steps[1]["until"] = { kind = "effect", effect = "fade-white" }
  local futureLoaded, futureErr = strictLoad(versionId, 1, futureManifest, bundle.files, nil)
  Assert.isNil(futureLoaded, "a wait on a later step effect never validates")
  Assert.notNil(futureErr, "a future-start wait reports its cause")
  local validManifest = deepCopyManifest(bundle.manifest)
  validManifest.timeline.steps[#validManifest.timeline.steps + 1] = {
    id = "tail-guard",
    events = {},
    ["until"] = { kind = "effects", effects = { "blend-copyright-main", "fade-white" } },
  }
  local validLoaded, validErr = strictLoad(versionId, 1, validManifest, bundle.files, nil)
  Assert.notNil(validLoaded, "an eventless conjunctive wait validates: " .. tostring(validErr))
  local pseudoManifest = deepCopyManifest(bundle.manifest)
  local pseudoStep = pseudoManifest.timeline.steps[1]
  local pseudoIndex = #pseudoManifest.timeline.events + 1
  pseudoManifest.timeline.events[pseudoIndex] =
    { op = "waitEffects", stepId = pseudoStep.id, atStepTick = 0, effects = { "blend-copyright-main" } }
  pseudoStep.events[#pseudoStep.events + 1] = pseudoIndex
  local pseudoLoaded, pseudoErr = strictLoad(versionId, 1, pseudoManifest, bundle.files, nil)
  Assert.isNil(pseudoLoaded, "the pseudo-wait marker never validates")
  Assert.notNil(pseudoErr, "the pseudo-wait marker reports its cause")
end

-- Producer structure: all five scenes emit no pseudo-wait marker, every
-- step carries a duration, single-effect, or conjunctive guard, and every
-- event is owned exactly once by its own step.
local function compiledScenesEmitStrictCaseGuardsWithoutPseudoWaits(romFs, versionId)
  for sceneNumber = 1, 5 do
    local manifest = strictManifest(compileScene(romFs, versionId, sceneNumber), versionId, sceneNumber)
    for _, event in ipairs(manifest.timeline.events) do
      Assert.isTrue(
        event.op ~= "waitEffects",
        "scene " .. sceneNumber .. " emits no pseudo-wait marker"
      )
    end
    local owned = {}
    for _, step in ipairs(manifest.timeline.steps) do
      local finish = assert(step["until"], "scene " .. sceneNumber .. " step " .. step.id .. " carries its guard")
      Assert.isTrue(
        finish.kind == "duration" or finish.kind == "effect" or finish.kind == "effects",
        "scene " .. sceneNumber .. " step " .. step.id .. " guards on duration, effect, or effects"
      )
      if finish.kind == "duration" then
        Assert.isTrue(
          type(finish.ticks) == "number" and finish.ticks % 1 == 0 and finish.ticks > 0,
          "scene " .. sceneNumber .. " step " .. step.id .. " waits a positive duration"
        )
      elseif finish.kind == "effect" then
        Assert.isTrue(
          type(finish.effect) == "string" and finish.effect ~= "",
          "scene " .. sceneNumber .. " step " .. step.id .. " names its waited effect"
        )
      else
        Assert.isTrue(
          type(finish.effects) == "table" and #finish.effects > 0,
          "scene " .. sceneNumber .. " step " .. step.id .. " names its waited effects"
        )
      end
      local completion = step.onCompleteEvents or {}
      Assert.isTrue(type(completion) == "table", "scene " .. sceneNumber .. " step " .. step.id .. " owns its completion list")
      for _, index in ipairs(step.events) do
        Assert.isNil(owned[index], "scene " .. sceneNumber .. " owns event " .. index .. " once")
        owned[index] = step.id
        Assert.equal(
          manifest.timeline.events[index].stepId,
          step.id,
          "scene " .. sceneNumber .. " event " .. index .. " belongs to its step"
        )
      end
      for _, index in ipairs(completion) do
        Assert.isNil(owned[index], "scene " .. sceneNumber .. " owns completion event " .. index .. " once")
        owned[index] = step.id
        Assert.equal(
          manifest.timeline.events[index].stepId,
          step.id,
          "scene " .. sceneNumber .. " completion event " .. index .. " belongs to its step"
        )
      end
    end
    for index = 1, #manifest.timeline.events do
      Assert.notNil(owned[index], "scene " .. sceneNumber .. " event " .. index .. " is owned by its step")
    end
  end
end

return RomSuite.fromFacts({
  ["source opening scenes compile to five independent versioned bundles"] = sourceOpeningScenesCompileToFiveIndependentVersionedBundles,
  ["source opening timeline keeps its five-scene transitions and skip gate"] = sourceOpeningTimelineKeepsItsFiveSceneTransitionsAndSkipGate,
  ["starter mapping and plane masks follow the retail flip order"] = starterMappingAndPlaneMasksFollowTheRetailFlipOrder,
  ["plane enable state is explicit in every compiled scene"] = planeEnableStateIsExplicitInEveryCompiledScene,
  ["town drawing stops before rival-only visuals"] = townDrawingStopsBeforeRivalOnlyVisuals,
  ["engine window records replace the synthetic kind shapes"] = engineWindowRecordsReplaceTheSyntheticKindShapes,
  ["source opening assets keep layered models particles and failed stages preserve good output"] = sourceOpeningAssetsKeepLayeredModelsParticlesAndFailedStagesPreserveGoodOutput,
  ["concurrent sunrise background slots keep distinct indexed slots with scroll sources"] = concurrentSunriseSlotsKeepDistinctIndexedSlots,
  ["alternate scene panels resolve to staged images"] = alternatePanelsResolveToStagedImages,
  ["sprite instances carry retail placement with engine and frame offsets"] = spriteInstancesCarryRetailPlacement,
  ["effect waits resolve to started effects with exact step thresholds"] = effectWaitsResolveToStartedEffects,
  ["physical engine swaps are explicit screen mapping events"] = physicalSwapsAreExplicitMappingEvents,
  ["strict versioned validation accepts only complete scene contracts"] = strictValidationAcceptsOnlyCompleteContracts,
  ["background layers keep their full source map extents with typed variant extents"] = backgroundLayersKeepTheirFullSourceMapExtents,
  ["opening programs start from their source origins with immediate and continuous scrolls"] = openingProgramsStartFromTheirSourceOrigins,
  ["engine blends and wipes carry their source operands per stage engine"] = engineBlendsAndWipesCarrySourceOperands,
  ["pinned native extents reproduce decoded art with pinned wrap edges"] = pinnedNativeExtentsAndWrapEdgeTopology,
  ["pinned scroll blend wipe and fade operands match retail calls"] = pinnedScrollBlendWipeAndFadeOperandsMatchRetailCalls,
  ["movie tick rate remains the retail 30 Hz source cadence"] = movieTickRateRemainsRetail30Hz,
  ["strict case guards reject invalid waits and accept eventless conjunctions"] = strictCaseGuardsRejectInvalidWaitsAndAcceptEventlessConjunctions,
  ["compiled scenes emit strict case guards without pseudo waits"] = compiledScenesEmitStrictCaseGuardsWithoutPseudoWaits,
})
