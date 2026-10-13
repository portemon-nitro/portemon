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
  local all = {
    storage.backgrounds.default,
    storage.ui.boxPane,
    storage.ui.infoPane,
    storage.ui.partyTray,
    storage.ui.markingPanel,
    storage.ui.wallpaperBar,
    storage.ui.arrows.left,
    storage.ui.arrows.right,
    storage.ui.cursors.browse,
    storage.ui.cursors.menu,
    storage.ui.cursors.carry,
  }
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
  -- Every message id reads "b<bank>:<id>" so tests can name what was drawn.
  manifest.text = { banks = { [24] = {}, [25] = {} } }
  for bankId, bank in pairs(manifest.text.banks) do
    for messageId = 0, 100 do
      bank[messageId] = { { kind = "glyph", text = "b" .. bankId .. ":" .. messageId } }
    end
  end
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local image = PngWriter.encode(1, 1, string.char(255, 255, 255, 255))
  for _, visual in ipairs(visuals(manifest)) do
    cache:write(visual.image, image)
  end
  local graphics = FakeGraphics.new()
  local text = {
    drawText = function() end,
    textWidth = function()
      return 0
    end,
  }
  return PcStorageRenderer.new({ graphics = graphics, cacheFs = cache, manifest = manifest, text = text }),
    graphics,
    manifest
end

local function placement()
  return assert(PixelScale.placeFixed({ x = 0, y = 0, width = 256, height = 192 }, 256, 192))
end

function T.wallpaper_chooser_draws_one_page_of_four_swatches_with_locked_entries_black()
  local renderer, graphics, manifest = rendererFixture()
  local drawn = {}
  renderer._text = {
    textWidth = function()
      return 0
    end,
    drawText = function(_, value, x, y)
      drawn[#drawn + 1] = { value, x, y }
    end,
  }
  -- Logical 17 sits on the fifth page (16..19); only bonus 16 is unlocked.
  renderer:drawPane({
    mode = 0,
    activeBox = 0,
    tray = "closed",
    wallpaperId = 0,
    wallpaperUnlocks = { true, false, false, false, false, false, false, false },
    boxSlots = {},
    party = {},
    editor = { kind = "wallpaper", selected = 17, focus = "slots" },
  }, {}, "lower", placement())
  local menuHand = renderer._images[manifest.storage.ui.cursors.menu.image]
  renderer:release()

  local fills = {}
  for _, rectangle in ipairs(graphics.rectangles) do
    if rectangle.mode == "fill" then
      fills[#fills + 1] = rectangle
    end
  end
  Assert.equal(#fills, 4, "the page shows four swatches")
  for slot, fill in ipairs(fills) do
    Assert.equal(fill.x, 59 + 46 * (slot - 1) - 12 + 4, "swatches are centred on their source slots")
  end
  Assert.equal(fills[1].color[1], 160 / 255, "an unlocked bonus uses its palette color")
  Assert.equal(fills[2].color[1], 0, "a locked entry is black")
  local hand
  for _, draw in ipairs(graphics.draws) do
    if draw.image == menuHand then
      hand = draw
    end
  end
  Assert.notNil(hand, "the hand cursor points at the selected swatch")
  Assert.deepEqual({ hand.x, hand.y }, { 59 + 46, 31 }, "the cursor sits on the swatch's node")
  Assert.deepEqual(drawn[1], { "b24:59", 93 + 12, 8 }, "a locked selection reads the locked name")
end

function T.marking_editor_draws_six_compiled_clear_set_tiles_in_the_marking_panel()
  local renderer, graphics, manifest = rendererFixture()
  renderer:drawPane({
    mode = 0,
    activeBox = 0,
    tray = "closed",
    wallpaperId = 0,
    wallpaperUnlocks = { false, false, false, false, false, false, false, false },
    boxSlots = {},
    party = {},
    editor = { kind = "markings", mask = 5, selected = 2 },
  }, {}, "lower", placement(), true)
  local setZero = renderer._images[manifest.storage.ui.markings[0].set.image]
  local clearOne = renderer._images[manifest.storage.ui.markings[1].clear.image]
  local setTwo = renderer._images[manifest.storage.ui.markings[2].set.image]
  local browseHand = renderer._images[manifest.storage.ui.cursors.browse.image]
  renderer:release()

  local markingDraws = {}
  for _, draw in ipairs(graphics.draws) do
    if (draw.x == 188 or draw.x == 220) and (draw.y == 60 or draw.y == 84 or draw.y == 108) then
      markingDraws[#markingDraws + 1] = draw
    end
  end
  Assert.equal(#markingDraws, 6)
  Assert.equal(markingDraws[1].image, setZero, "the selected marking uses its compiled set tile")
  Assert.equal(markingDraws[2].image, clearOne, "the unselected marking uses its compiled clear tile")
  Assert.equal(markingDraws[3].image, setTwo, "the set tile uses its compiled source pair")
  local hand
  for _, draw in ipairs(graphics.draws) do
    if draw.image == browseHand then
      hand = draw
    end
  end
  Assert.notNil(hand, "the hand cursor marks the selected mark")
  Assert.deepEqual({ hand.x, hand.y }, { 204, 80 }, "the cursor sits on the selected mark's node")
  Assert.isTrue(manifest.storage.ui.markings[2].set ~= nil)
end

function T.storage_menu_draws_compiled_source_messages()
  local renderer = rendererFixture()
  local drawn = {}
  renderer._text = {
    textWidth = function()
      return 0
    end,
    drawText = function(_, value)
      if value == "b24:81" or value == "b24:64" then
        drawn[#drawn + 1] = value
      end
    end,
  }
  renderer:drawPane({
    mode = 3,
    activeBox = 0,
    tray = "closed",
    wallpaperId = 0,
    wallpaperUnlocks = { false, false, false, false, false, false, false, false },
    boxSlots = {},
    party = {},
    menu = { actions = { "giveItem", "swapItems" }, selected = 1 },
  }, {}, "lower", placement(), true)
  Assert.equal(#drawn, 2, "Storage draws both menu labels")
  Assert.equal(drawn[1], "b24:81", "Give Item uses source message 81")
  Assert.equal(drawn[2], "b24:64", "Sort Items uses source message 64")
  renderer:release()
end

function T.message_line_draws_in_the_player_frame_with_yes_no_and_the_bottom_buttons()
  local renderer = rendererFixture()
  local windows, drawn = {}, {}
  renderer._text = {
    textWidth = function()
      return 0
    end,
    windowBackgroundColor = function()
      return { 1, 1, 1, 1 }
    end,
    drawText = function(_, value, x, y)
      drawn[#drawn + 1] = { value, x, y }
    end,
  }
  local resources = {
    applicationFrameIndex = 3,
    windowRenderer = {
      drawWindow = function(_, box, frameIndex)
        windows[#windows + 1] = { "player", box, frameIndex }
      end,
      drawStandardWindow = function(_, box)
        windows[#windows + 1] = { "standard", box }
      end,
    },
  }
  renderer:drawPane({
    mode = 2,
    activeBox = 0,
    tray = "closed",
    wallpaperId = 0,
    wallpaperUnlocks = {},
    boxSlots = {},
    party = {},
    message = { id = 11, window = "W37", yesNo = true },
  }, resources, "lower", placement())
  Assert.deepEqual(
    windows[1],
    { "player", { x = 16, y = 168, width = 216, height = 16 }, 3 },
    "the line uses the player's frame"
  )
  Assert.equal(windows[2][1], "standard", "Yes is a standard window")
  Assert.equal(windows[3][1], "standard", "No is a standard window")
  local function drew(value, x, y)
    for _, record in ipairs(drawn) do
      if record[1] == value and record[2] == x and record[3] == y then
        return true
      end
    end
    return false
  end
  Assert.isTrue(drew("b25:11", 16, 168), "the prompt text sits in its window")
  Assert.isTrue(drew("YES", 212, 104) and drew("NO", 212, 136), "Yes and No are labelled")
  Assert.isTrue(drew("b24:62", 200, 172), "RETURN labels the right button")
  Assert.isTrue(drew("b24:60", 8, 172), "Move mode adds the PARTY button")
  renderer:release()
end

function T.top_screen_prints_the_selected_mon_info_at_the_source_windows()
  local renderer = rendererFixture()
  local drawn = {}
  renderer._text = {
    textWidth = function()
      return 0
    end,
    drawText = function(_, value, x, y)
      drawn[#drawn + 1] = { value, x, y }
    end,
  }
  local function infoView(info)
    return {
      mode = 0,
      activeBox = 0,
      tray = "closed",
      wallpaperId = 0,
      wallpaperUnlocks = {},
      boxSlots = {},
      party = {},
      info = info,
    }
  end
  renderer:drawPane(
    infoView({
      nickname = "CHIKO",
      speciesName = "CHIKORITA",
      level = 12,
      dexNumber = 152,
      gender = "female",
      natureName = "Calm",
      abilityName = "Overgrow",
      itemName = nil,
    }),
    {},
    "upper",
    placement()
  )
  Assert.deepEqual(drawn, {
    { "b25:50", 8, 8 },
    { "CHIKO", 8, 56 },
    { "CHIKORITA", 64, 40 },
    { "Lv.", 32, 72 },
    { "12", 48, 72 },
    { "No.", 8, 40 },
    { "152", 24, 40 },
    { "b24:83", 128, 40 },
    { "b24:87", 8, 88 },
    { "Calm", 8, 104 },
    { "b24:88", 8, 120 },
    { "Overgrow", 8, 136 },
    { "b24:89", 8, 152 },
    { "b24:92", 8, 168 },
  }, "the info panel prints each fact in its source window")

  drawn = {}
  renderer:drawPane(infoView({ nickname = "Egg", egg = true }), {}, "upper", placement())
  Assert.equal(drawn[3][1], "b24:87", "an egg skips species facts and keeps the labels")
  Assert.equal(drawn[4][1], "b24:93", "an egg's nature is hidden")
  renderer:release()
end

function T.box_renderer_skips_empty_sentinels_and_draws_the_final_slot()
  local renderer, graphics, manifest = rendererFixture()
  local iconDraws = {}
  local plainDraw = graphics.draw
  graphics.draw = function(image, quad, x, ...)
    if type(quad) == "table" and quad.icon then
      iconDraws[#iconDraws + 1] = { x = x, y = select(1, ...) }
      return
    end
    return plainDraw(image, quad, x, ...)
  end
  local icons = {
    dimensions = function()
      return { width = 32, height = 32 }
    end,
    image = function()
      return {}
    end,
    quadFor = function()
      return { icon = true }
    end,
  }
  local slots = {}
  for slot = 1, 29 do
    slots[slot] = false
  end
  slots[30] = { heldItem = "NONE", markings = 0, iconKey = "last-slot" }
  local rendered, failure = pcall(function()
    renderer:drawPane({
      mode = 0,
      activeBox = 0,
      tray = "closed",
      wallpaperId = 0,
      wallpaperUnlocks = { false, false, false, false, false, false, false, false },
      boxSlots = slots,
      party = {},
    }, { icons = icons }, "lower", placement(), true)
  end)
  Assert.isTrue(rendered, "Storage rendering skips explicit empty slots: " .. tostring(failure))
  -- Slot 29 is column 5, row 4: a 32px icon centred four pixels above its slot centre.
  Assert.deepEqual(iconDraws, { { x = 8 + 24 * 5, y = 32 + 24 * 4 } }, "slot 29 renders at its fixed box geometry")
  Assert.isTrue(manifest.storage.wallpapers[0] ~= nil, "the active box keeps its compiled wallpaper")
  renderer:release()
end

return { tests = T }
