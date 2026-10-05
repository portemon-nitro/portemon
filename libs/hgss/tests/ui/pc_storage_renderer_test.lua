-- PC Storage editor previews use the compiled wallpaper and marking visuals.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local FakeGraphics = require("tests.support.FakeGraphics")
local PngWriter = require("libs.assets.src.PngWriter")
local PcPresentationFixture = require("tests.support.PcPresentationFixture")
local PcStorageRenderer = require("libs.hgss.src.ui.PcStorageRenderer")
local PixelScale = require("libs.ui.src.PixelScale")

local T = {}

local function visuals(manifest)
  local storage = manifest.storage
  local all = { storage.backgrounds.default, storage.ui.boxPane, storage.ui.partyPane }
  for _, visual in pairs(storage.wallpapers) do
    all[#all + 1] = visual
  end
  for _, pair in pairs(storage.ui.markings) do
    all[#all + 1] = pair.clear
    all[#all + 1] = pair.set
  end
  for _, style in pairs(storage.ui.windowFrames) do
    for _, visual in pairs(style) do
      all[#all + 1] = visual
    end
  end
  return all
end

local function rendererFixture()
  local manifest = PcPresentationFixture.manifest()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local image = PngWriter.encode(1, 1, string.char(255, 255, 255, 255))
  for _, visual in ipairs(visuals(manifest)) do
    cache:write(visual.image, image)
  end
  local graphics = FakeGraphics.new()
  local text = { drawText = function() end }
  return PcStorageRenderer.new({ graphics = graphics, cacheFs = cache, manifest = manifest, text = text }),
    graphics,
    manifest
end

local function placement()
  return assert(PixelScale.placeFixed({ x = 0, y = 0, width = 256, height = 192 }, 256, 192))
end

function T.wallpaper_chooser_draws_four_columns_and_dim_locked_bonus_previews()
  local renderer, graphics, manifest = rendererFixture()
  local view = {
    mode = 0,
    activeBox = 0,
    wallpaperId = 0,
    wallpaperUnlocks = { false, false, false, false, false, false, false, false },
    boxSlots = {},
    party = {},
    editor = { kind = "wallpaper", selected = 1 },
  }
  renderer:drawPane(view, {}, "lower", placement(), true)
  renderer:release()

  local preview
  for _, draw in ipairs(graphics.draws) do
    if draw.x == 37 and draw.y == 116 then
      preview = draw
    end
  end
  Assert.isTrue(preview ~= nil, "logical wallpaper 16 occupies source column zero, row four")
  Assert.equal(preview.color[4], 0.35, "locked compiled previews are dimmed")
  Assert.equal(#graphics.rectangles, 1, "the selected source preview has one focus outline")
  Assert.deepEqual(
    { graphics.rectangles[1].x, graphics.rectangles[1].y, graphics.rectangles[1].w, graphics.rectangles[1].h },
    { 83, 20, 44, 20 }
  )
  Assert.isTrue(manifest.storage.wallpapers[32] ~= nil, "logical bonus 16 resolves to stored wallpaper 32")
end

function T.marking_editor_draws_six_compiled_clear_set_tiles_on_the_source_row()
  local renderer, graphics, manifest = rendererFixture()
  renderer:drawPane({
    mode = 0,
    activeBox = 0,
    wallpaperId = 0,
    wallpaperUnlocks = { false, false, false, false, false, false, false, false },
    boxSlots = {},
    party = {},
    editor = { kind = "markings", mask = 5, selected = 2 },
  }, {}, "lower", placement(), true)
  local setZero = renderer._images[manifest.storage.ui.markings[0].set.image]
  local clearOne = renderer._images[manifest.storage.ui.markings[1].clear.image]
  local setTwo = renderer._images[manifest.storage.ui.markings[2].set.image]
  renderer:release()

  local markingDraws = {}
  for _, draw in ipairs(graphics.draws) do
    if draw.y == 8 and draw.x >= 120 and draw.x <= 160 then
      markingDraws[#markingDraws + 1] = draw
    end
  end
  Assert.equal(#markingDraws, 6)
  Assert.equal(markingDraws[1].image, setZero, "the selected marking uses its compiled set tile")
  Assert.equal(markingDraws[2].image, clearOne, "the unselected marking uses its compiled clear tile")
  Assert.equal(markingDraws[3].image, setTwo, "the set tile uses its compiled source pair")
  Assert.deepEqual(
    { graphics.rectangles[1].x, graphics.rectangles[1].y, graphics.rectangles[1].w, graphics.rectangles[1].h },
    { 136, 8, 8, 8 }
  )
  Assert.isTrue(manifest.storage.ui.markings[2].set ~= nil)
end

return { tests = T }
