-- Source-backed town stage graphics: the compiled scene-3 edge table
-- reaches the shared field renderer packed, and every town hold keeps its
-- source materials on the active frame. HeartGold legs stay blocked: no
-- HeartGold dump is available here, so those scenarios skip instead of
-- running against faked art.

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
    if kind ~= "dual" then
      return {
        surfaces = {
          { id = "main", rect = { x = 0, y = 0, width = width, height = height }, touch = true, role = "world" },
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
---@return table player
local function openMovie(scope, versionId, width, height)
  local Movie = requireMovie()
  local context = DisplayContext.new({ graphics = love.graphics, topologyProvider = topology("single") })
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

-- Reads the fixed 256x192 main engine target after a draw. The caller
-- draws first so the canvas carries the current source tick; reading
-- never advances the movie clock.
---@param scope table test scope owning the readback
---@param canvas love.Canvas fixed source engine target
---@return string raw RGBA bytes of the engine target
local function sourceBytes(scope, canvas)
  local imageData = scope:own(canvas:newImageData())
  return imageData:getString()
end

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

-- The town stage forwards the compiled edge-marking table to the shared
-- field renderer: slot zero stays black while every other slot carries
-- the dark gray mark color, packed to RGB555 at the zero-based index.
---@param scope table test scope owning the movie
---@param versionId string selected edition identity
local function town_edge_profile_follows_the_compiled_source_table_for_edition(scope, versionId)
  local movie = openMovie(scope, versionId, 512, 384)
  local scenes = assert(movie.scenes, "the running movie keeps its scene bundles")
  local compiled = assert(scenes[3].lighting, "scene 3 carries its compiled lighting")
  local source = assert(compiled.edgeColors, "scene 3 carries its compiled edge table")
  Assert.equal(#source, 8, "the compiled edge table keeps all eight slots")
  for index, triple in ipairs(source) do
    local level = index == 1 and 0 or 4 / 31
    local r = triple.r ~= nil and triple.r or triple[1]
    local g = triple.g ~= nil and triple.g or triple[2]
    local b = triple.b ~= nil and triple.b or triple[3]
    Assert.near(r, level, 1e-6, "compiled edge slot " .. index .. " keeps its retail red")
    Assert.near(g, level, 1e-6, "compiled edge slot " .. index .. " keeps its retail green")
    Assert.near(b, level, 1e-6, "compiled edge slot " .. index .. " keeps its retail blue")
  end
  advanceToSceneStep(movie, 3, "show-goldenrod-city", 20000)
  for _ = 1, 5 do
    movie:updateFixed()
  end
  movie:draw()
  local slot = assert(movie.current, "the running movie owns its current slot")
  local environment = assert(slot.townEnv, "the town stage forwards its render environment")
  local profile = assert(environment.edgeColors, "the town environment carries its edge profile")
  local marked = 4 + 4 * 32 + 4 * 1024
  for index = 0, 7 do
    local want = index == 0 and 0 or marked
    Assert.equal(profile[index], want, "edge slot " .. index .. " reaches the renderer packed")
  end
  movie:dispose()
end

local function soulsilver_town_edge_profile_follows_the_compiled_source_table(scope, context)
  town_edge_profile_follows_the_compiled_source_table_for_edition(scope, selectedVersionId(context))
end

local function heartgold_town_edge_profile_is_blocked_without_a_dump(scope, context)
  if not RomImporter.isReady("heartgold") then
    context:skip(
      "BLOCKED: HeartGold town edges need a user-owned HeartGold dump; "
        .. "only SoulSilver is ready here, so the edge profile leg "
        .. "cannot run for HeartGold and is never faked"
    )
  end
  town_edge_profile_follows_the_compiled_source_table_for_edition(scope, "heartgold")
end

-- The town holds keep their source materials on the active frame: the
-- central mass stays lit, blended shadow edges stay between black and
-- full brightness, and the sibling towns keep only scattered dark pixels.
---@param scope table test scope owning the movie
---@param versionId string selected edition identity
local function town_hold_frames_keep_their_source_materials_for_edition(scope, versionId)
  local movie = openMovie(scope, versionId, 512, 384)
  Assert.notNil(movie.townHi, "the town stage owns its bounded high-resolution target")
  Assert.equal(movie.townHi:getWidth(), 768, "the town target keeps its 3x native width")
  Assert.equal(movie.townHi:getHeight(), 576, "the town target keeps its 3x native height")
  ---@param stepId string authored hold identity
  ---@param ticks integer fixed ticks to settle inside the hold
  ---@return string raw RGBA bytes of the high-resolution town target
  local function frameAt(stepId, ticks)
    advanceToSceneStep(movie, 3, stepId, 20000)
    for _ = 1, ticks do
      movie:updateFixed()
    end
    Assert.equal(currentStepId(movie), stepId, "the hold stays inside " .. stepId)
    movie:draw()
    return sourceBytes(scope, movie.townHi)
  end
  ---@param bytes string raw RGBA bytes of the town target
  ---@param x integer town pixel column 0..767
  ---@param y integer town pixel row 0..575
  ---@return integer summed channel brightness in 0..765
  local function channelSum(bytes, x, y)
    local base = (y * 768 + x) * 4 + 1
    local r, g, b = string.byte(bytes, base, base + 2)
    return r + g + b
  end
  ---@param bytes string raw RGBA bytes of the town target
  ---@return integer pure-black pixel count over the whole target
  local function blackCount(bytes)
    local black = 0
    for y = 0, 575, 3 do
      for x = 0, 767, 3 do
        if channelSum(bytes, x, y) == 0 then
          black = black + 1
        end
      end
    end
    return black
  end
  local newBark = frameAt("show-new-bark-town", 25)
  Assert.isTrue(blackCount(newBark) < 400, "the first town keeps only scattered dark pixels at high resolution")
  local goldenrod = frameAt("show-goldenrod-city", 25)
  Assert.isTrue(channelSum(goldenrod, 384, 240) > 100, "the town mass stays lit on its active high-resolution frame")
  local edge = channelSum(goldenrod, 108, 444)
  Assert.isTrue(edge > 20 and edge < 500, "the blended shadow edge stays between black and full brightness")
  local ecruteak = frameAt("show-ecruteak-city", 25)
  Assert.isTrue(blackCount(ecruteak) < 400, "the third town keeps only scattered dark pixels at high resolution")
  movie:dispose()
end

local function soulsilver_town_hold_frames_keep_their_source_materials(scope, context)
  town_hold_frames_keep_their_source_materials_for_edition(scope, selectedVersionId(context))
end

local function heartgold_town_hold_frames_are_blocked_without_a_dump(scope, context)
  if not RomImporter.isReady("heartgold") then
    context:skip(
      "BLOCKED: HeartGold town frames need a user-owned HeartGold dump; "
        .. "only SoulSilver is ready here, so the material frame leg "
        .. "cannot run for HeartGold and is never faked"
    )
  end
  town_hold_frames_keep_their_source_materials_for_edition(scope, "heartgold")
end

local T = GraphicsSmoke.suite({
  ["soulsilver town edge profile follows the compiled source table"] = soulsilver_town_edge_profile_follows_the_compiled_source_table,
  ["heartgold town edge profile is blocked without a dump"] = heartgold_town_edge_profile_is_blocked_without_a_dump,
  ["soulsilver town hold frames keep their source materials"] = soulsilver_town_hold_frames_keep_their_source_materials,
  ["heartgold town hold frames are blocked without a dump"] = heartgold_town_hold_frames_are_blocked_without_a_dump,
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
