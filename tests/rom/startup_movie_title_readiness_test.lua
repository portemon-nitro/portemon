-- The cinematic journey reads back as one current, edition-matched package
-- set: all five opening scenes plus the legendary title compile from the
-- exact user-owned ROM, stage under one generation, and pass the strict
-- readers the startup state consumes before constructing its movie. Each
-- ready edition runs its own journey; an edition without a user-owned dump
-- records BLOCKED instead of running against faked art.

local Assert = require("tests.support.Assert")
local RomImporter = require("romdump.src.source.RomImporter")
local RomSourcePath = require("tests.rom.support.RomSourcePath")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local ArtifactState = require("romdump.src.build.ArtifactState")
local PreparedArtifact = require("romdump.src.build.PreparedArtifact")
local StartupAssetCache = require("libs.assets.src.StartupAssetCache")

local OPENING_SCHEMA = "g4-startup-opening-scene-v10"
local SOURCE_TICK_RATE = 30
local JOURNEY_GENERATION = "startup-journey"

local CLOSED_OPS = {
  setLayer = true,
  setPalette = true,
  setScroll = true,
  setScrollPosition = true,
  setBrightness = true,
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

local function compileScene(versionId, romFs, sceneNumber)
  local compiler = require("romdump.src.digest.startup.OpeningMovieCompiler")
  local bundle, err = compiler.compile(romFs, versionId, sceneNumber)
  Assert.notNil(bundle, "scene " .. sceneNumber .. " compiles from the exact ROM: " .. tostring(err))
  return bundle
end

local function checkScene(bundle, versionId, sceneNumber)
  local manifest = assert(bundle.manifest, "scene " .. sceneNumber .. " publishes its manifest")
  Assert.equal(manifest.schema, OPENING_SCHEMA, "scene " .. sceneNumber .. " carries the opening scene schema")
  Assert.equal(manifest.versionId, versionId, "scene " .. sceneNumber .. " carries its edition")
  Assert.equal(manifest.sceneNumber, sceneNumber, "scene " .. sceneNumber .. " carries its scene key")
  Assert.equal(manifest.sourceTickRate, SOURCE_TICK_RATE, "scene " .. sceneNumber .. " runs at the source frame rate")
  local timeline = assert(manifest.timeline, "scene " .. sceneNumber .. " carries its normalized timeline")
  local events = assert(timeline.events, "scene " .. sceneNumber .. " carries its normalized event stream")
  Assert.isTrue(#events > 0, "scene " .. sceneNumber .. " carries a nonempty event stream")
  for _, event in ipairs(events) do
    Assert.isTrue(
      type(event.op) == "string" and CLOSED_OPS[event.op] == true,
      "scene " .. sceneNumber .. " uses only the closed movie event grammar"
    )
    Assert.isTrue(
      type(event.atStepTick) == "number" and event.atStepTick % 1 == 0 and event.atStepTick >= 0,
      "scene " .. sceneNumber .. " fires every event on its source step clock"
    )
    Assert.isTrue(event.atTick == nil, "scene " .. sceneNumber .. " carries no parallel global clock")
  end
  Assert.isTrue(
    type(manifest.layers) == "table" and type(manifest.layers.main) == "table" and type(manifest.layers.sub) == "table",
    "scene " .. sceneNumber .. " keys its layers by source engine"
  )
  return manifest
end

local function stageScene(cacheFs, bundle, sceneNumber)
  local writer = require("romdump.src.digest.startup.OpeningMovieCacheWriter")
  local key = tostring(sceneNumber)
  local artifact = PreparedArtifact.new({
    cacheFs = cacheFs,
    generationId = JOURNEY_GENERATION,
    epoch = 1,
    kind = "opening-scene",
    key = key,
    jobKey = "opening-scene:" .. key,
    stageName = "opening-scene-" .. key,
  })
  local marker, err = writer.stageScene(artifact, bundle, JOURNEY_GENERATION, sceneNumber)
  Assert.notNil(marker, "scene " .. sceneNumber .. " stages its numbered package: " .. tostring(err))
  artifact:finishSuccess({ marker = marker })
  Assert.isTrue(
    artifact:publish({
      generationId = JOURNEY_GENERATION,
      epoch = 1,
      kind = "opening-scene",
      key = key,
      jobKey = "opening-scene:" .. key,
      stageName = "opening-scene-" .. key,
    }),
    "scene " .. sceneNumber .. " publishes its numbered package"
  )
end

local function stageTitle(cacheFs, bundle)
  local writer = require("romdump.src.digest.startup.StartupCacheWriter")
  local artifact = PreparedArtifact.new({
    cacheFs = cacheFs,
    generationId = JOURNEY_GENERATION,
    epoch = 1,
    kind = "startup-title",
    key = "global",
    jobKey = "startup-title:global",
    stageName = "startup-title",
  })
  local marker, err = writer.stageTitle(artifact, bundle, JOURNEY_GENERATION)
  Assert.notNil(marker, "the title stages its package: " .. tostring(err))
  artifact:finishSuccess({ marker = marker })
  Assert.isTrue(
    artifact:publish({
      generationId = JOURNEY_GENERATION,
      epoch = 1,
      kind = "startup-title",
      key = "global",
      jobKey = "startup-title:global",
      stageName = "startup-title",
    }),
    "the title publishes its package"
  )
end

local function journey(versionId)
  local romFs, sourceOrErr = RomSourcePath.openReader(versionId)
  Assert.notNil(romFs, "the " .. versionId .. " source ROM opens: " .. tostring(sourceOrErr))
  local ok, err = pcall(function()
    local scenes = {}
    for sceneNumber = 1, 5 do
      scenes[sceneNumber] = checkScene(compileScene(versionId, romFs, sceneNumber), versionId, sceneNumber)
    end
    local skipTicks = {}
    for sceneNumber = 1, 5 do
      for _, event in ipairs(scenes[sceneNumber].timeline.events) do
        if event.op == "enableSkip" then
          skipTicks[#skipTicks + 1] = event.atStepTick
        end
      end
    end
    Assert.isTrue(#skipTicks > 0, "the journey carries the source skip gate")
    for _, atStepTick in ipairs(skipTicks) do
      Assert.isTrue(atStepTick > 0, "the source skip gate never opens on the first step tick")
    end

    local compiler = require("romdump.src.digest.startup.TitleScreenCompiler")
    local titleBundle, titleErr = compiler.compile(romFs, versionId)
    Assert.notNil(titleBundle, "the title compiles from the exact ROM: " .. tostring(titleErr))
    local titleManifest = assert(titleBundle.manifest, "the title publishes its manifest")
    Assert.equal(titleManifest.versionId, versionId, "the title carries its edition")
    Assert.equal(titleManifest.sequence, "SEQ_GS_POKEMON_THEME", "the title carries its original title track symbol")
    Assert.equal(
      titleManifest.menuSelectSequence,
      "SEQ_SE_DP_SELECT",
      "the title carries its original menu select symbol"
    )
    Assert.equal(
      titleManifest.crySpeciesId,
      versionId == "heartgold" and 250 or 249,
      "the title carries its edition legendary cry species"
    )

    local backend = FakeCache.new()
    local cacheFs = CacheFs.forVersion(versionId, backend)
    for sceneNumber = 1, 5 do
      local bundle = compileScene(versionId, romFs, sceneNumber)
      stageScene(cacheFs, bundle, sceneNumber)
    end
    stageTitle(cacheFs, titleBundle)

    for sceneNumber = 1, 5 do
      local read, readErr = StartupAssetCache.loadOpeningScene(cacheFs, sceneNumber, versionId)
      Assert.notNil(read, "scene " .. sceneNumber .. " reads back as a ready bundle: " .. tostring(readErr))
      Assert.equal(read.versionId, versionId, "scene " .. sceneNumber .. " reads back its edition")
      Assert.equal(
        read.generationId,
        JOURNEY_GENERATION,
        "scene " .. sceneNumber .. " reads back the journey generation"
      )
    end
    local title, titleReadErr = StartupAssetCache.loadTitle(cacheFs, versionId)
    Assert.notNil(title, "the title reads back as a ready bundle: " .. tostring(titleReadErr))
    Assert.equal(title.versionId, versionId, "the title reads back its edition")
    Assert.equal(title.generationId, JOURNEY_GENERATION, "the title reads back the journey generation")
  end)
  romFs:close()
  if sourceOrErr ~= nil and type(sourceOrErr) == "table" and type(sourceOrErr.release) == "function" then
    sourceOrErr:release()
  end
  if not ok then
    error(err, 0)
  end
end

local function soulsilverJourneyRunsItsFiveScenesAndTitleTogether(context)
  if not RomImporter.isReady("soulsilver") then
    context:skip(
      "BLOCKED: SoulSilver journey needs a user-owned SoulSilver dump; "
        .. "the five-scene and title package set cannot run and is never faked"
    )
  end
  journey("soulsilver")
end

local function heartgoldJourneyRunsItsFiveScenesAndTitleTogether(context)
  if not RomImporter.isReady("heartgold") then
    context:skip(
      "BLOCKED: HeartGold journey needs a user-owned HeartGold dump; "
        .. "only SoulSilver is ready here, so the five-scene and title package set "
        .. "cannot run for HeartGold and is never faked"
    )
  end
  journey("heartgold")
end

local T = {
  metadata = { capabilities = { "rom_dump" }, tags = { "startup" } },
  tests = {
    ["soulsilver five scenes and title validate together for the journey"] = soulsilverJourneyRunsItsFiveScenesAndTitleTogether,
    ["heartgold five scenes and title validate together for the journey"] = heartgoldJourneyRunsItsFiveScenesAndTitleTogether,
  },
}
return T
