-- The five opening-movie scenes compile from the exact ROM into independent
-- versioned bundles with source-timed transitions, layered/model/particle
-- assets, and per-scene failure isolation.

local Assert = require("tests.support.Assert")
local RomSuite = require("tests.rom.support.RomSuite")

local OPENING_SCHEMA = "g4-startup-opening-scene-v1"
local SOURCE_TICK_RATE = 30

local CLOSED_OPS = {
  setLayer = true,
  setPalette = true,
  setScroll = true,
  setBlend = true,
  window = true,
  circleWipe = true,
  setSpriteClip = true,
  spriteVisible = true,
  setModelClip = true,
  setCamera = true,
  setLighting = true,
  startEmitters = true,
  setScreenRoles = true,
  setFade = true,
  waitTicks = true,
  waitEffects = true,
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
      type(event.atTick) == "number" and event.atTick % 1 == 0 and event.atTick >= 0,
      "scene " .. sceneNumber .. " keys every event by a source tick"
    )
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

local function opsInOrder(events)
  local ordered = {}
  for index, event in ipairs(events) do
    ordered[index] = event
  end
  table.sort(ordered, function(left, right)
    return left.atTick < right.atTick
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
    type(manifest.layers) == "table"
      and type(manifest.layers.upper) == "table"
      and type(manifest.layers.lower) == "table",
    "scene " .. sceneNumber .. " keeps its upper and lower screen roles"
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
  local firstEvents = opsInOrder(timelineEvents(first, 1))
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
  local skipAtTick = nil
  for _, event in ipairs(firstEvents) do
    if event.op == "enableSkip" then
      Assert.isTrue(event.atTick > 0, "the movie skip gate never opens on the first frame")
      if skipAtTick == nil or event.atTick < skipAtTick then
        skipAtTick = event.atTick
      end
    end
  end
  Assert.notNil(skipAtTick, "scene 1 carries the source movie skip gate")
  Assert.isTrue((skipAtTick or 0) >= 110, "the movie skip gate opens only after the copyright hold, fades, and setup")

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
  local fourthEvents = opsInOrder(timelineEvents(fourth, 4))
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
  local fifthEvents = opsInOrder(timelineEvents(fifth, 5))
  local wipeAt, scrollAt, waitAt, fadeAt = nil, nil, nil, nil
  for _, event in ipairs(fifthEvents) do
    if event.op == "circleWipe" and eventMentions(event, 18) and wipeAt == nil then
      wipeAt = event.atTick
    elseif event.op == "setScroll" and eventMentions(event, 73) and scrollAt == nil then
      scrollAt = event.atTick
    elseif event.op == "waitTicks" and eventMentions(event, 20) and waitAt == nil then
      waitAt = event.atTick
    elseif event.op == "setFade" and eventMentions(event, 50) and fadeAt == nil then
      fadeAt = event.atTick
    end
  end
  Assert.notNil(wipeAt, "scene 5 keeps its 18-tick wipe")
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

return RomSuite.fromFacts({
  ["source opening scenes compile to five independent versioned bundles"] = sourceOpeningScenesCompileToFiveIndependentVersionedBundles,
  ["source opening timeline keeps its five-scene transitions and skip gate"] = sourceOpeningTimelineKeepsItsFiveSceneTransitionsAndSkipGate,
  ["source opening assets keep layered models particles and failed stages preserve good output"] = sourceOpeningAssetsKeepLayeredModelsParticlesAndFailedStagesPreserveGoodOutput,
})
