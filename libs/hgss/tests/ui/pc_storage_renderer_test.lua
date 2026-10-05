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
  manifest.text = { banks = { [24] = { [26] = { { kind = "text", value = "wallpaper" } } } } }
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

function T.storage_menu_and_wallpaper_heading_draw_compiled_source_messages()
  local renderer, _, manifest = rendererFixture()
  local bank = {}
  for _, messageId in ipairs({ 26, 80, 81, 64 }) do
    bank[messageId] = { { kind = "text", value = "message:" .. messageId } }
  end
  manifest.text.banks[24] = bank
  local drawn = {}
  renderer._text = {
    drawText = function(_, tokens)
      if type(tokens) == "table" then
        drawn[#drawn + 1] = tokens
      end
    end,
  }
  renderer:drawPane({
    mode = 3,
    activeBox = 0,
    wallpaperId = 0,
    wallpaperUnlocks = { false, false, false, false, false, false, false, false },
    boxSlots = {},
    party = {},
    menu = { actions = { "giveItem", "swapItems" }, selected = 1 },
    editor = { kind = "wallpaper", selected = 0 },
  }, {}, "lower", placement(), true)
  Assert.equal(#drawn, 3, "Storage draws the heading and both menu labels")
  Assert.equal(drawn[1], bank[26], "wallpaper heading uses source message 26")
  Assert.equal(drawn[2], bank[81], "Give Item uses source message 81")
  Assert.equal(drawn[3], bank[64], "Sort Items uses source message 64")
  renderer:release()
end

function T.box_renderer_skips_empty_sentinels_and_draws_the_final_slot()
  local renderer, _, manifest = rendererFixture()
  local drawn = {}
  renderer._text = {
    drawText = function(_, value, x, y)
      drawn[#drawn + 1] = { value = value, x = x, y = y }
    end,
  }
  local slots = {}
  for slot = 1, 29 do
    slots[slot] = false
  end
  slots[30] = { heldItem = "NONE", markings = 0, nickname = "last-slot" }
  local rendered, failure = pcall(function()
    renderer:drawPane({
      activeBox = 0,
      wallpaperId = 0,
      wallpaperUnlocks = { false, false, false, false, false, false, false, false },
      boxSlots = slots,
      party = {},
    }, {}, "lower", placement(), true)
  end)
  Assert.isTrue(rendered, "Storage rendering skips explicit empty slots: " .. tostring(failure))
  local label
  for _, record in ipairs(drawn) do
    if record.value == "last-slot" then
      label = record
    end
  end
  Assert.deepEqual(label, { value = "last-slot", x = 242, y = 140 }, "slot 29 renders at its fixed box geometry")
  Assert.isTrue(manifest.storage.wallpapers[0] ~= nil, "the active box keeps its compiled wallpaper")
  renderer:release()
end

return { tests = T }
