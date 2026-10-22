-- Ho-Oh scene assets are built once per field session: scene phases reuse the
-- built models, preparation proceeds in steps without drawing, a draw before
-- preparation finishes the missing parts itself, and every pool is released
-- exactly once.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldEffectAssetCache = require("libs.assets.src.field.FieldEffectAssetCache")
local GpuAssetPool = require("libs.hgss.src.presentation.GpuAssetPool")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local HoOhAppearanceRenderer = require("libs.hgss.src.presentation.HoOhAppearanceRenderer")
local ImageAssetPool = require("libs.hgss.src.presentation.ImageAssetPool")
local RomImporter = require("romdump.src.source.RomImporter")

local VERSION = "heartgold"

-- Counts the loads, mesh builds, pool constructions and pool releases the
-- renderer performs; the wrappers are removed by the returned restore.
local function counting()
  local counts = { core = 0, cinematic = {}, meshes = 0, images = 0, pools = 0, releases = 0 }
  local originals = {
    core = FieldEffectAssetCache.loadHoOhCore,
    cinematic = FieldEffectAssetCache.loadHoOhCinematic,
    meshFor = GpuAssetPool.meshFor,
    sharedImage = GpuAssetPool.sharedImage,
    new = GpuAssetPool.new,
    release = GpuAssetPool.release,
  }
  FieldEffectAssetCache.loadHoOhCore = function(...)
    counts.core = counts.core + 1
    return originals.core(...)
  end
  FieldEffectAssetCache.loadHoOhCinematic = function(cacheFs, shot, variant)
    local key = shot .. variant
    counts.cinematic[key] = (counts.cinematic[key] or 0) + 1
    return originals.cinematic(cacheFs, shot, variant)
  end
  GpuAssetPool.meshFor = function(self, path)
    counts.meshes = counts.meshes + 1
    return originals.meshFor(self, path)
  end
  GpuAssetPool.sharedImage = function(self, ...)
    counts.images = counts.images + 1
    return originals.sharedImage(self, ...)
  end
  GpuAssetPool.new = function(...)
    counts.pools = counts.pools + 1
    return originals.new(...)
  end
  GpuAssetPool.release = function(self)
    counts.releases = counts.releases + 1
    return originals.release(self)
  end
  local function restore()
    FieldEffectAssetCache.loadHoOhCore = originals.core
    FieldEffectAssetCache.loadHoOhCinematic = originals.cinematic
    GpuAssetPool.meshFor = originals.meshFor
    GpuAssetPool.sharedImage = originals.sharedImage
    GpuAssetPool.new = originals.new
    GpuAssetPool.release = originals.release
  end
  return counts, restore
end

local function snapshot(counts)
  local keys = {}
  for key, value in pairs(counts.cinematic) do
    keys[#keys + 1] = key .. "=" .. value
  end
  table.sort(keys)
  return string.format(
    "core=%d meshes=%d pools=%d releases=%d cinematic=%s",
    counts.core,
    counts.meshes,
    counts.pools,
    counts.releases,
    table.concat(keys, ",")
  )
end

local function newRenderer(scope)
  local cache = CacheFs.forVersion(VERSION)
  local images = ImageAssetPool.new(cache)
  scope:own({
    release = function()
      images:dispose()
    end,
  })
  local renderer = HoOhAppearanceRenderer.new(cache, images)
  scope:own({
    release = function()
      renderer:dispose()
    end,
  })
  return renderer
end

local function status(sequence, fields)
  local out = { active = true, sequence = sequence, versionId = VERSION, origin = { x = 0, y = 0, z = 0 } }
  for key, value in pairs(fields) do
    out[key] = value
  end
  return out
end

local function bell(sequence)
  return status(sequence, { bellStage = "idle", bellFrame = 0, bellVisible = false })
end

local function shimmer(sequence)
  return status(sequence, {
    bellStage = "shimmer",
    bellFrame = 0,
    loopFrame = 0,
    bellVisible = false,
    shimmerFrame = 0,
    shimmerClearBellOnly = false,
    cornerOffsets = { { 12.5, -4.5625, 9 }, { -12.375, -4.5625, 9 }, { 12.5, -4.5625, -16.875 }, { -12.375, -4.5625, -16.875 } },
  })
end

local function bird(sequence)
  return status(sequence, { birdFrame = 1, birdRingFrame = 0 })
end

local function cinematic(sequence, shot, variant)
  return status(sequence, { cinematicShot = shot, cinematicVariant = variant, cinematicModelFrame = 0 })
end

local function drawAllPhases(renderer)
  renderer:drawItems(bell(1))
  renderer:drawItems(bird(2))
  renderer:drawItems(cinematic(3, "first", 1))
  renderer:drawItems(cinematic(3, "second", 1))
end

local function prepareFully(renderer, variant)
  local steps = 0
  repeat
    steps = steps + 1
    assert(steps < 200, "preparation never finished")
  until renderer:prepareStep(VERSION, variant)
  return steps
end

local function roles(items)
  local list = {}
  for _, item in ipairs(items) do
    list[#list + 1] = tostring(item.fieldEffectRole)
  end
  table.sort(list)
  return table.concat(list, ",")
end

local function withCounts(body)
  local counts, restore = counting()
  local ok, err = pcall(body, counts)
  restore()
  assert(ok, err)
end

local function testBuildsOnceAcrossSequences(scope)
  if not RomImporter.isReady(VERSION) then
    return
  end
  withCounts(function(counts)
    local renderer = newRenderer(scope)
    drawAllPhases(renderer)
    Assert.equal(counts.core, 1, "the core record loads once")
    Assert.deepEqual(counts.cinematic, { first1 = 1, second1 = 1 }, "only the live variant's shots load")
    Assert.equal(counts.pools, 2, "a core pool and one cinematic pool")
    local after = snapshot(counts)
    renderer:drawItems(bell(4))
    renderer:drawItems(bird(5))
    renderer:drawItems(cinematic(6, "second", 1))
    Assert.equal(snapshot(counts), after, "later scene runs reuse every built model")
  end)
end

local function testPreparationIsIncrementalAndComplete(scope)
  if not RomImporter.isReady(VERSION) then
    return
  end
  withCounts(function(counts)
    local renderer = newRenderer(scope)
    local steps = prepareFully(renderer, 1)
    Assert.isTrue(steps > 3, "preparation is spread over several steps")
    local prepared = snapshot(counts)
    Assert.isTrue(renderer:prepareStep(VERSION, 1), "a finished preparation stays finished")
    Assert.equal(snapshot(counts), prepared, "a finished preparation does no further work")
    drawAllPhases(renderer)
    Assert.equal(snapshot(counts), prepared, "drawing after preparation builds nothing")
  end)
end

local function testDrawBeforePreparationMatchesPreparedOutput(scope)
  if not RomImporter.isReady(VERSION) then
    return
  end
  local prepared = newRenderer(scope)
  prepareFully(prepared, 1)
  local direct = newRenderer(scope)
  for index, make in ipairs({ shimmer, bird, function(sequence)
    return cinematic(sequence, "first", 1)
  end }) do
    local expected = prepared:drawItems(make(index))
    local actual = direct:drawItems(make(index))
    Assert.equal(roles(actual), roles(expected), "phase " .. index .. " draws the same items")
    Assert.equal(#actual, #expected)
  end
end

local function testPreparationSlicesItsHeavyUnits(scope)
  if not RomImporter.isReady(VERSION) then
    return
  end
  withCounts(function(counts)
    local renderer = newRenderer(scope)
    local steps, maxMeshes, maxImages = 0, 0, 0
    repeat
      local meshes, images = counts.meshes, counts.images
      local done = renderer:prepareStep(VERSION, 1)
      steps = steps + 1
      maxMeshes = math.max(maxMeshes, counts.meshes - meshes)
      maxImages = math.max(maxImages, counts.images - images)
      assert(steps < 400, "preparation never finished")
    until done
    Assert.isTrue(maxMeshes <= HoOhAppearanceRenderer.MESHES_PER_STEP, "a step builds a bounded number of meshes")
    Assert.isTrue(maxImages <= HoOhAppearanceRenderer.LEAF_IMAGES_PER_STEP, "a step loads a bounded number of images")
    Assert.isTrue(counts.meshes > HoOhAppearanceRenderer.MESHES_PER_STEP, "the models really are larger than one slice")
    Assert.isTrue(steps > 20, "the heavy units are spread over many steps (" .. steps .. ")")
  end)
end

local function testDrawDrivenVariantChangeReleasesTheStaleVariant(scope)
  if not RomImporter.isReady(VERSION) then
    return
  end
  withCounts(function(counts)
    local renderer = newRenderer(scope)
    prepareFully(renderer, 1)
    local core = counts.core
    renderer:drawItems(cinematic(1, "second", 2))
    Assert.equal(counts.releases, 1, "the prepared variant is released once when the scene needs another")
    Assert.equal(counts.cinematic.second2, 1, "the scene's variant is built once")
    Assert.equal(counts.core, core, "the core is not rebuilt")
  end)
end

local function testCancelMidPreparationReleasesOnce(scope)
  if not RomImporter.isReady(VERSION) then
    return
  end
  withCounts(function(counts)
    local renderer = newRenderer(scope)
    for _ = 1, 3 do
      Assert.isFalse(renderer:prepareStep(VERSION, 1))
    end
    renderer:cancel()
    Assert.equal(counts.releases, counts.pools, "every pool built so far is released once")
    local cancelled = snapshot(counts)
    renderer:cancel()
    Assert.equal(snapshot(counts), cancelled, "cancelling an unprepared renderer does nothing")
    Assert.isTrue(#renderer:drawItems(shimmer(1)) > 0, "drawing after a cancel builds synchronously")
  end)
end

local function testVariantChangeReleasesTheStaleVariant(scope)
  if not RomImporter.isReady(VERSION) then
    return
  end
  withCounts(function(counts)
    local renderer = newRenderer(scope)
    prepareFully(renderer, 1)
    Assert.equal(counts.releases, 0)
    prepareFully(renderer, 2)
    Assert.equal(counts.releases, 1, "the stale variant's pool is released once")
    Assert.deepEqual(counts.cinematic, { first1 = 1, second1 = 1, first2 = 1, second2 = 1 })
    Assert.equal(counts.core, 1, "the core is not rebuilt for a new variant")
    local prepared = snapshot(counts)
    renderer:drawItems(cinematic(1, "second", 2))
    Assert.equal(snapshot(counts), prepared, "the new variant draws without building")
  end)
end

local function testSceneStartMidwayDoesNotDoubleBuild(scope)
  if not RomImporter.isReady(VERSION) then
    return
  end
  withCounts(function(counts)
    local renderer = newRenderer(scope)
    Assert.isFalse(renderer:prepareStep(VERSION, 1))
    Assert.isFalse(renderer:prepareStep(VERSION, 1))
    renderer:drawItems(cinematic(1, "first", 1))
    prepareFully(renderer, 1)
    Assert.equal(counts.core, 1, "the core loads once however the work is split")
    Assert.deepEqual(counts.cinematic, { first1 = 1, second1 = 1 })
    Assert.equal(counts.pools, 2)
  end)
end

local function testDisposeReleasesEveryPoolOnce(scope)
  if not RomImporter.isReady(VERSION) then
    return
  end
  withCounts(function(counts)
    local renderer = newRenderer(scope)
    prepareFully(renderer, 1)
    renderer:dispose()
    Assert.equal(counts.releases, counts.pools, "every pool is released")
    local disposed = snapshot(counts)
    renderer:dispose()
    Assert.equal(snapshot(counts), disposed, "disposal is exactly once")
  end)
end

local T = GraphicsSmoke.suite({
  ["Ho-Oh models are built once across scene sequences"] = testBuildsOnceAcrossSequences,
  ["Ho-Oh preparation is incremental and complete"] = testPreparationIsIncrementalAndComplete,
  ["a Ho-Oh draw before preparation matches the prepared output"] = testDrawBeforePreparationMatchesPreparedOutput,
  ["Ho-Oh preparation slices its heavy units"] = testPreparationSlicesItsHeavyUnits,
  ["a scene that needs another variant releases the prepared one"] = testDrawDrivenVariantChangeReleasesTheStaleVariant,
  ["cancelling a Ho-Oh preparation releases every pool once"] = testCancelMidPreparationReleasesOnce,
  ["a new time-of-day variant releases the stale one"] = testVariantChangeReleasesTheStaleVariant,
  ["starting the scene mid-preparation never builds twice"] = testSceneStartMidwayDoesNotDoubleBuild,
  ["disposing the Ho-Oh renderer releases every pool once"] = testDisposeReleasesEveryPoolOnce,
})
T.metadata.capabilities = { "graphics", "rom_dump" }
T.metadata.derivedAssets = { "field-effects:global", "field-camera:global" }
T.metadata.tags = { "field", "ho-oh", "lifecycle" }
return T
