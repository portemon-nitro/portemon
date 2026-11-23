-- PC Storage editor previews use the compiled wallpaper and marking visuals.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local FakeGraphics = require("tests.support.FakeGraphics")
local PngWriter = require("tests.support.PngEncoder")
local PcPresentationFixture = require("tests.support.PcPresentationFixture")
local MonCache = require("libs.assets.src.MonCache")
local MoveIconCache = require("libs.assets.src.MoveIconCache")
local PcStorageGeometry = require("libs.hgss.src.ui.PcStorageGeometry")
local PcStorageRenderer = require("libs.hgss.src.ui.PcStorageRenderer")
local PixelScale = require("libs.ui.src.PixelScale")
local SharedImagePoolFake = require("tests.support.SharedImagePoolFake")

local T = {}

-- The injected shared image owner behind Storage visuals: the
-- synchronous fake with straight sampling leases, recording every image
-- it hands out so the suite can prove no draw references a freed image
-- and the idle trim reclaims exactly the stale visuals.
---@return table<string, unknown> pool double
---@return SharedImagePoolFake inner fake behind census assertions
---@return table<string, unknown>[] every image handed out so far
local function storagePool()
  local inner = SharedImagePoolFake.new()
  local seen = {}
  local pool = {}
  function pool:request(path, sampler, priority)
    return inner:request(path, sampler, priority)
  end
  function pool:poll(token)
    return inner:poll(token)
  end
  function pool:acquire(token)
    local lease = inner:acquire(token)
    lease.kind = "rgba8"
    local image = assert(lease.image, "shared leases carry their resolved image")
    seen[#seen + 1] = image
    return lease
  end
  function pool:release(lease)
    return inner:release(lease)
  end
  function pool:cancel(token)
    return inner:cancel(token)
  end
  function pool:prune()
    return inner:prune()
  end
  function pool:stats()
    return inner:stats()
  end
  return pool, inner, seen
end

local function visuals(manifest)
  local storage = manifest.storage
  local all = {
    storage.backgrounds.default,
    storage.ui.boxPane,
    storage.ui.infoPane,
    storage.ui.partyTray,
    storage.ui.partyTrayMove,
    storage.ui.markingPanel,
    storage.ui.wallpaperBar,
    storage.ui.movesPanel,
    storage.ui.itemPanel,
    storage.ui.boxTray,
    storage.ui.depositBoxTray,
    storage.ui.arrows.left,
    storage.ui.arrows.right,
    storage.ui.tray.prev,
    storage.ui.tray.next,
    storage.ui.tray.marker,
    storage.ui.tray.cursor,
    storage.ui.tray.wallpaperCursor,
    storage.ui.tray.label,
  }
  for _, pose in pairs(storage.ui.cursors) do
    for _, frame in ipairs(pose.frames) do
      all[#all + 1] = frame
    end
  end
  for _, visual in pairs(storage.wallpaperSwatchArt.variants) do
    all[#all + 1] = visual
  end
  all[#all + 1] = storage.wallpaperSwatchArt.locked
  for _, visual in pairs(storage.boxThumbnail.variants) do
    all[#all + 1] = visual
  end
  all[#all + 1] = storage.boxThumbnail.locked
  for _, visual in pairs(storage.wallpapers) do
    all[#all + 1] = visual
  end
  for _, set in ipairs({ storage.ui.markings, storage.ui.panelMarkings }) do
    for _, pair in pairs(set) do
      all[#all + 1] = pair.clear
      all[#all + 1] = pair.set
    end
  end
  for _, plate in pairs(storage.ui.plates) do
    all[#all + 1] = plate.left
    all[#all + 1] = plate.middle
    all[#all + 1] = plate.right
  end
  for _, style in pairs(storage.ui.windowFrames) do
    if type(style) == "table" and style.image == nil then
      for _, visual in pairs(style) do
        if type(visual) == "table" and type(visual.image) == "string" then
          all[#all + 1] = visual
        end
      end
    end
  end
  return all
end

local function rendererFixture(pool)
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
  cache:write(
    MonCache.portraitManifestPath(),
    "return { entries = { ['CHIKORITA/f0/male/plain'] = { pageId = 0, frames = { { x = 0, y = 0, width = 80, height = 80 } }, width = 80, height = 80 } }, pages = { [0] = { width = 80, height = 80 } } }"
  )
  cache:write(
    MoveIconCache.manifestPath(),
    "return { schema = 'g4-move-icons-v1', types = { grass = { image = 'assets/generated/move-icons/type-grass.png', width = 32, height = 16, offset = { x = -16, y = -8 } }, poison = { image = 'assets/generated/move-icons/type-poison.png', width = 32, height = 16, offset = { x = -16, y = -8 } } }, categories = {} }"
  )
  local graphics = FakeGraphics.new()
  local text = {
    drawText = function() end,
    textWidth = function()
      return 0
    end,
  }
  return PcStorageRenderer.new({
    graphics = graphics,
    cacheFs = cache,
    manifest = manifest,
    text = text,
    imagePool = pool or assert(storagePool()),
  }),
    graphics,
    manifest
end

local function placement()
  return assert(PixelScale.placeFixed({ x = 0, y = 0, width = 256, height = 192 }, 256, 192))
end

-- Admitting helper: production prepares Storage visuals in the update phase
-- and draws only admitted signatures, so every composition below resolves
-- its demand before its first present. Preparation stages the next group
-- beside the installed one; the explicit commit below publishes a staged
-- group once every other prerequisite for the same view is ready.
local function settleStagedView(renderer, view)
  if type(renderer.commitPrepared) == "function" then
    renderer:commitPrepared(view)
  end
end

local function admit(renderer, view)
  local ready, failure = false, nil
  for _ = 1, 200 do
    ready, failure = renderer:prepare(view)
    if ready then
      break
    end
    Assert.isNil(failure, "admission reports no failure while pending")
  end
  Assert.isTrue(ready, "the view admits before drawing")
  Assert.isNil(failure, "admission reports no failure")
  settleStagedView(renderer, view)
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
  local chooserView = {
    mode = 0,
    activeBox = 0,
    tray = "closed",
    wallpaperId = 0,
    wallpaperUnlocks = { true, false, false, false, false, false, false, false },
    boxSlots = {},
    party = {},
    editor = { kind = "wallpaper", selected = 17, focus = "slots" },
    cursor = { x = 105, y = 31, pose = "menu" },
  }
  admit(renderer, chooserView)
  renderer:drawPane(chooserView, {}, "lower", placement())
  local menuHand = renderer._images[manifest.storage.ui.cursors.menu.frames[1].image]
  local swatchArt = manifest.storage.wallpaperSwatchArt
  local unlockedImage = renderer._images[swatchArt.variants[16].image]
  local lockedImage = renderer._images[swatchArt.locked.image]
  local swatchDraws = {}
  for _, draw in ipairs(graphics.draws) do
    if draw.image == unlockedImage or draw.image == lockedImage then
      swatchDraws[#swatchDraws + 1] = draw
    end
  end
  renderer:release()
  Assert.equal(#swatchDraws, 4, "the page draws four compiled swatches")
  Assert.deepEqual({ swatchDraws[1].x, swatchDraws[1].y }, { 47, 23 }, "swatches sit on their source wells")
  Assert.equal(swatchDraws[1].image, unlockedImage, "the unlocked bonus uses its authored swatch")
  Assert.equal(swatchDraws[2].image, lockedImage, "the locked entry uses the locked swatch")
  Assert.equal(swatchDraws[3].image, lockedImage, "the next locked entry uses the locked swatch")
  Assert.equal(swatchDraws[4].image, lockedImage, "the last locked entry uses the locked swatch")
  local hand
  for _, draw in ipairs(graphics.draws) do
    if draw.image == menuHand then
      hand = draw
    end
  end
  Assert.notNil(hand, "the hand cursor points at the selected swatch")
  Assert.deepEqual({ hand.x, hand.y }, { 59 + 46, 31 }, "the cursor sits on the swatch's node")
  -- The name window is 96 px wide, centred on the selected swatch, with its
  -- top at the swatch row minus 8 (PCBox_UpdateWallpaperCursor).
  local nameDraw = assert(drawn[1], "the locked name is drawn")
  Assert.deepEqual(nameDraw, { "b24:59", 105, 27 }, "a locked selection reads the locked name")
end

function T.marking_editor_draws_six_compiled_clear_set_tiles_in_the_marking_panel()
  local renderer, graphics, manifest = rendererFixture()
  local markingView = {
    mode = 0,
    activeBox = 0,
    tray = "closed",
    wallpaperId = 0,
    wallpaperUnlocks = { false, false, false, false, false, false, false, false },
    boxSlots = {},
    party = {},
    editor = { kind = "markings", mask = 5, selected = 2 },
    cursor = { x = 204, y = 80, pose = "menu" },
  }
  admit(renderer, markingView)
  renderer:drawPane(markingView, {}, "lower", placement(), true)
  local setZero = renderer._images[manifest.storage.ui.panelMarkings[0].set.image]
  local clearOne = renderer._images[manifest.storage.ui.panelMarkings[1].clear.image]
  local setTwo = renderer._images[manifest.storage.ui.panelMarkings[2].set.image]
  local browseHand = renderer._images[manifest.storage.ui.cursors.menu.frames[1].image]
  renderer:release()

  local markingDraws = {}
  for _, draw in ipairs(graphics.draws) do
    -- The source writes one 8x8 member-14 tile per mark at panel tiles
    -- (3,2),(7,2)...: screen (192,64),(224,64),(192,88)...
    if (draw.x == 192 or draw.x == 224) and (draw.y == 64 or draw.y == 88 or draw.y == 112) then
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
  local menuView = {
    mode = 3,
    activeBox = 0,
    tray = "closed",
    wallpaperId = 0,
    wallpaperUnlocks = { false, false, false, false, false, false, false, false },
    boxSlots = {},
    party = {},
    menu = { actions = { "giveItem", "swapItems" }, selected = 1 },
  }
  admit(renderer, menuView)
  renderer:drawPane(menuView, {}, "lower", placement(), true)
  Assert.equal(#drawn, 2, "Storage draws both menu labels")
  Assert.equal(drawn[1], "b24:81", "Give Item uses source message 81")
  Assert.equal(drawn[2], "b24:64", "Sort Items uses source message 64")
  renderer:release()
end

function T.message_line_draws_in_the_player_frame_with_yes_no_and_the_bottom_buttons()
  local renderer, graphics, manifest = rendererFixture()
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
  local messageView = {
    mode = 2,
    activeBox = 0,
    tray = "closed",
    wallpaperId = 0,
    wallpaperUnlocks = {},
    boxSlots = {},
    party = {},
    message = { id = 11, window = "W37", yesNo = true, yesNoChoice = "yes" },
  }
  admit(renderer, messageView)
  renderer:drawPane(messageView, resources, "lower", placement())
  Assert.deepEqual(
    windows[1],
    { "player", { x = 16, y = 168, width = 216, height = 16 }, 3 },
    "the line uses the player's frame"
  )
  -- The confirmation draws baked source button art, not framed text labels.
  local yesSelected = renderer._images[manifest.storage.ui.yesNo.yesSelected.image]
  local noNormal = renderer._images[manifest.storage.ui.yesNo.noNormal.image]
  local yesDraw, noDraw
  for _, draw in ipairs(graphics.draws) do
    if draw.image == yesSelected then
      yesDraw = draw
    elseif draw.image == noNormal then
      noDraw = draw
    end
  end
  Assert.notNil(yesDraw, "the highlighted YES row draws its selected variant")
  Assert.notNil(noDraw, "the idle NO row draws its normal variant")
  Assert.deepEqual({ yesDraw.x, yesDraw.y }, { 200, 96 }, "YES draws at the source button rect")
  Assert.deepEqual({ noDraw.x, noDraw.y }, { 200, 128 }, "NO draws at the source button rect")
  local function drew(value, x, y)
    for _, record in ipairs(drawn) do
      if record[1] == value and record[2] == x and record[3] == y then
        return true
      end
    end
    return false
  end
  Assert.isTrue(drew("b25:11", 16, 168), "the prompt text sits in its window")
  Assert.isTrue(drew("b24:62", 224, 172), "RETURN labels the right button, centred on its plate")
  Assert.isTrue(drew("b24:60", 44, 172), "Move mode adds the PARTY button, centred on its plate")
  Assert.isTrue(drew("b24:61", 140, 172), "Move mode adds its MOVE tab, centred on its plate")
  renderer:release()
end

function T.top_screen_prints_the_selected_mon_info_at_the_source_windows()
  local renderer, graphics, manifest = rendererFixture()
  local drawn = {}
  renderer._text = {
    textWidth = function()
      return 0
    end,
    drawText = function(_, value, x, y)
      drawn[#drawn + 1] = { value, x, y }
    end,
    drawTextWithColorVariant = function(_, value, x, y, band)
      drawn[#drawn + 1] = { value, x, y, band }
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
  local firstInfo = infoView({
    nickname = "CHIKO",
    speciesName = "CHIKORITA",
    level = 12,
    dexNumber = 152,
    gender = "female",
    natureName = "Calm",
    abilityName = "Overgrow",
    itemName = nil,
  })
  admit(renderer, firstInfo)
  renderer:drawPane(firstInfo, {}, "upper", placement())
  Assert.deepEqual(drawn, {
    { "b25:50", 8, 8 },
    { "CHIKO", 8, 56 },
    { "CHIKORITA", 64, 40 },
    { "12", 48, 72 },
    { "152", 24, 40 },
    -- The female symbol prints through the box panel's own colour band.
    { "b24:83", 128, 40, 1 },
    { "b24:87", 8, 88 },
    { "Calm", 8, 104 },
    { "b24:88", 8, 120 },
    { "Overgrow", 8, 136 },
    { "b24:89", 8, 152 },
    { "b24:92", 8, 168 },
    { "-", 168, 104 },
    { "-", 168, 120 },
    { "-", 168, 136 },
    { "-", 168, 152 },
  }, "the info panel prints each fact in its source window")
  -- The 8px "Lv."/"No." source bitmaps are blitted at their window rows,
  -- five pixels below the number baselines.
  local lvImage = renderer._images[manifest.storage.ui.infoGlyphs.lv.image]
  local noImage = renderer._images[manifest.storage.ui.infoGlyphs.no.image]
  local function glyphAt(image)
    for _, draw in ipairs(graphics.draws) do
      if draw.image == image then
        return draw
      end
    end
    return nil
  end
  local lv, no = glyphAt(lvImage), glyphAt(noImage)
  Assert.notNil(lv, "the level label draws the source Lv. bitmap")
  Assert.notNil(no, "the dex line draws the source No. bitmap")
  Assert.deepEqual({ lv.x, lv.y }, { 32, 77 }, "Lv. sits at its source window row")
  Assert.deepEqual({ no.x, no.y }, { 8, 45 }, "No. sits at its source window row")

  drawn = {}
  local eggInfo = infoView({ nickname = "Egg", egg = true })
  admit(renderer, eggInfo)
  renderer:drawPane(eggInfo, {}, "upper", placement())
  Assert.equal(drawn[3][1], "b24:87", "an egg skips species facts and keeps the labels")
  Assert.equal(drawn[4][1], "b24:93", "an egg's nature is hidden")
  renderer:release()
end

function T.box_renderer_skips_empty_sentinels_and_draws_the_final_slot()
  local renderer, graphics, manifest = rendererFixture()
  local iconDraws = {}
  local iconImage = { setFilter = function() end }
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
      return iconImage
    end,
    handleFor = function()
      return { image = iconImage, kind = "rgba8" }
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
  local slotView = {
    mode = 0,
    activeBox = 0,
    tray = "closed",
    wallpaperId = 0,
    wallpaperUnlocks = { false, false, false, false, false, false, false, false },
    boxSlots = slots,
    party = {},
  }
  local rendered, failure = pcall(function()
    admit(renderer, slotView)
    renderer:drawPane(slotView, { icons = icons }, "lower", placement(), true)
  end)
  Assert.isTrue(rendered, "Storage rendering skips explicit empty slots: " .. tostring(failure))
  -- Slot 29 is column 5, row 4: a 32px icon centred four pixels above its slot centre.
  Assert.deepEqual(iconDraws, { { x = 8 + 24 * 5, y = 32 + 24 * 4 } }, "slot 29 renders at its fixed box geometry")
  Assert.isTrue(manifest.storage.wallpapers[0] ~= nil, "the active box keeps its compiled wallpaper")
  renderer:release()
end

-- Shared box visuals resolve to one physical image across open renderers
-- through the session image owner, and returning to the active box after
-- visiting many boxes returns the stale box leases to idle while the
-- active box stays drawable with no per-draw image enrollment. Two opens
-- of one box never borrow the same visual twice, the explicit idle trim
-- reclaims exactly the stale visuals, and no draw ever references a
-- released image.
local function storageFixture()
  local manifest = PcPresentationFixture.manifest()
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
  cache:write(
    MonCache.portraitManifestPath(),
    "return { entries = { ['CHIKORITA/f0/male/plain'] = { pageId = 0, frames = { { x = 0, y = 0, width = 80, height = 80 } }, width = 80, height = 80 } }, pages = { [0] = { width = 80, height = 80 } } }"
  )
  cache:write(
    MoveIconCache.manifestPath(),
    "return { schema = 'g4-move-icons-v1', types = { grass = { image = 'assets/generated/move-icons/type-grass.png', width = 32, height = 16, offset = { x = -16, y = -8 } }, poison = { image = 'assets/generated/move-icons/type-poison.png', width = 32, height = 16, offset = { x = -16, y = -8 } } }, categories = {} }"
  )
  local graphics = FakeGraphics.new()
  local text = {
    drawText = function() end,
    textWidth = function()
      return 0
    end,
  }
  local pool, inner, seen = storagePool()
  return graphics, cache, manifest, text, pool, inner, seen
end

local function openStorage(graphics, cache, manifest, text, pool)
  return PcStorageRenderer.new({
    graphics = graphics,
    cacheFs = cache,
    manifest = manifest,
    text = text,
    imagePool = pool,
  })
end

local function browseView(wallpaperId)
  return {
    mode = 0,
    activeBox = 0,
    tray = "closed",
    wallpaperId = wallpaperId,
    wallpaperUnlocks = {},
    boxSlots = {},
    party = {},
  }
end

local function liveImages(seen)
  local live = 0
  local known = {}
  for _, image in ipairs(seen) do
    if known[image] == nil then
      known[image] = true
      if image.releaseCount == 0 then
        live = live + 1
      end
    end
  end
  return live
end

local function assertNoDrawAfterFree(graphics)
  for _, draw in ipairs(graphics.draws) do
    if draw.image ~= nil and type(draw.image) == "table" and draw.image.releaseCount ~= nil then
      Assert.equal(draw.image.releaseCount, 0, "no draw references a released image")
    end
  end
end

function T.box_visuals_share_one_image_and_release_stale_boxes_on_change()
  local graphics, cache, manifest, text, pool, inner, seen = storageFixture()
  local first = openStorage(graphics, cache, manifest, text, pool)
  local function present(renderer, wallpaperId)
    local view = browseView(wallpaperId)
    admit(renderer, view)
    renderer:drawPane(view, {}, "lower", placement())
  end
  present(first, 0)
  local opened = inner.uploads
  Assert.isTrue(opened > 0, "the open box borrows its visuals")
  assertNoDrawAfterFree(graphics)
  local second = openStorage(graphics, cache, manifest, text, pool)
  present(second, 0)
  Assert.equal(inner.uploads, opened, "two opens of one box share one physical image per visual")
  Assert.equal(inner:stats().outstandingLeases, 2 * opened, "each open holds its own borrow of the shared visuals")
  second:release()
  Assert.equal(inner:stats().outstandingLeases, opened, "closing the second box returns only its own borrows")
  for wallpaperId = 1, 7 do
    present(first, wallpaperId)
    assertNoDrawAfterFree(graphics)
  end
  local afterVisits = inner.uploads
  Assert.isTrue(afterVisits > opened, "visiting boxes borrows their wallpapers")
  present(first, 0)
  assertNoDrawAfterFree(graphics)
  local drawsBefore = #graphics.draws
  present(first, 0)
  Assert.equal(inner.uploads, afterVisits, "redrawing the active box enrolls no image per draw")
  Assert.isTrue(#graphics.draws > drawsBefore, "the active box still renders")
  assertNoDrawAfterFree(graphics)
  -- Returning the stale state leases never frees synchronously: every
  -- visited visual stays resident while idle, so no draw references a
  -- released image while the turnover is still in flight.
  Assert.equal(liveImages(seen), afterVisits, "returned leases stay resident while idle")
  for _, image in ipairs(seen) do
    Assert.equal(image.releaseCount, 0, "no visual frees on lease return alone")
  end
  -- The explicit idle trim bounds physical retention: the seven stale
  -- wallpapers free exactly once while shared chrome and the active box
  -- keep their hard references.
  first:trimIdle()
  local stale = 0
  local counted = {}
  for _, image in ipairs(seen) do
    if counted[image] == nil then
      counted[image] = true
      if image.releaseCount == 0 then
        -- Still resident: shared chrome or the active box wallpaper.
      else
        Assert.equal(image.releaseCount, 1, "a stale box visual frees exactly once on trim")
        stale = stale + 1
      end
    end
  end
  Assert.equal(stale, 7, "trimming bounds the seven idle wallpapers")
  Assert.equal(liveImages(seen), afterVisits - 7, "only shared chrome and the active box stay resident")
  first:release()
  Assert.equal(inner:stats().outstandingLeases, 0, "closing the box returns every remaining borrow")
  pool:prune()
  local freed = {}
  for _, image in ipairs(seen) do
    if freed[image] == nil then
      freed[image] = true
      Assert.equal(image.releaseCount, 1, "closing the box frees every remaining image exactly once")
    end
  end
end

-- Image-owner observer: records every enrollment call the renderer makes
-- after admission, so the suite can prove drawing performs no worker work.
local function countingPool(pool, tally)
  local counting = {}
  function counting:request(path, sampler, priority)
    tally.request = tally.request + 1
    return pool:request(path, sampler, priority)
  end
  function counting:poll(token)
    tally.poll = tally.poll + 1
    return pool:poll(token)
  end
  function counting:acquire(token)
    tally.acquire = tally.acquire + 1
    return pool:acquire(token)
  end
  function counting:release(lease)
    tally.release = tally.release + 1
    return pool:release(lease)
  end
  function counting:cancel(token)
    return pool:cancel(token)
  end
  function counting:prune()
    return pool:prune()
  end
  function counting:stats()
    return pool:stats()
  end
  return counting
end

-- A delayed shared owner: chosen generated paths stay pending until their
-- entry clears, modelling a cold wallpaper worker job without blocking.
local function delayingPool(pool, pendingPaths)
  local tokenPaths = {}
  local delayed = {}
  function delayed:request(path, sampler, priority)
    local token = pool:request(path, sampler, priority)
    tokenPaths[token] = path
    return token
  end
  function delayed:poll(token)
    if pendingPaths[tokenPaths[token]] then
      return "pending"
    end
    return pool:poll(token)
  end
  function delayed:acquire(token)
    return pool:acquire(token)
  end
  function delayed:release(lease)
    return pool:release(lease)
  end
  function delayed:cancel(token)
    tokenPaths[token] = nil
    return pool:cancel(token)
  end
  function delayed:prune()
    return pool:prune()
  end
  function delayed:stats()
    return pool:stats()
  end
  return delayed
end

-- An admitted view draws both panes with no image-owner traffic: no
-- enrollment, polling, acquisition, or lease release on the render path.
-- Either pane order paints the same admitted group without invalidating
-- the other pane's art.
function T.admitted_storage_draw_performs_no_image_owner_calls()
  local pool, _, _ = storagePool()
  local tally = { request = 0, poll = 0, acquire = 0, release = 0 }
  local renderer, graphics, _ = rendererFixture(countingPool(pool, tally))
  Assert.isTrue(type(renderer.prepare) == "function", "the renderer prepares its visuals outside drawing")
  local view = browseView(0)
  admit(renderer, view)
  tally.request, tally.poll, tally.acquire, tally.release = 0, 0, 0, 0
  renderer:drawPane(view, {}, "upper", placement())
  renderer:drawPane(view, {}, "lower", placement())
  Assert.equal(tally.request, 0, "drawing an admitted view enrolls no image")
  Assert.equal(tally.poll, 0, "drawing an admitted view polls no image")
  Assert.equal(tally.acquire, 0, "drawing an admitted view acquires no image")
  Assert.equal(tally.release, 0, "drawing an admitted view releases no image")
  Assert.isTrue(#graphics.draws > 0, "the admitted view still paints")
  renderer:dispose()
end

-- A wallpaper change borrows only the newly needed visual: static chrome
-- stays on its existing leases without new enrollment, and exactly one
-- new physical image appears for the incoming wallpaper.
function T.wallpaper_change_borrows_only_the_new_wallpaper()
  local pool, inner, _ = storagePool()
  local renderer, _, manifest = rendererFixture(pool)
  Assert.isTrue(type(renderer.prepare) == "function", "the renderer prepares its visuals outside drawing")
  local requested = {}
  local baselineRequest = pool.request
  function pool:request(path, sampler, priority)
    requested[#requested + 1] = path
    return baselineRequest(self, path, sampler, priority)
  end
  admit(renderer, browseView(0))
  local opened = inner.uploads
  Assert.isTrue(opened > 0, "the open view borrows its visuals")
  requested = {}
  admit(renderer, browseView(1))
  Assert.equal(inner.uploads, opened + 1, "a wallpaper change uploads only the new wallpaper")
  Assert.deepEqual(
    requested,
    { manifest.storage.wallpapers[1].image },
    "static chrome is reused without new enrollment"
  )
  renderer:dispose()
end

-- A superseded pending turnover never publishes: the current view stays
-- admitted while its replacement waits on the worker, and a repeated
-- demand for the current paths answers immediately.
function T.superseded_pending_turnover_keeps_the_current_view_ready()
  local pool, _, _ = storagePool()
  local pendingPaths = {}
  local renderer, graphics, manifest = rendererFixture(delayingPool(pool, pendingPaths))
  Assert.isTrue(type(renderer.prepare) == "function", "the renderer prepares its visuals outside drawing")
  local current = browseView(0)
  admit(renderer, current)
  pendingPaths[manifest.storage.wallpapers[1].image] = true
  local ready, failure = renderer:prepare(browseView(1))
  Assert.isFalse(ready, "a pending wallpaper keeps preparation unready")
  Assert.isNil(failure, "a pending wallpaper reports no failure")
  local again, againFailure = renderer:prepare(current)
  Assert.isTrue(again, "the current view stays admitted while its replacement pends")
  Assert.isNil(againFailure, "the current view reports no failure")
  local drawsBefore = #graphics.draws
  renderer:drawPane(current, {}, "lower", placement())
  Assert.isTrue(#graphics.draws > drawsBefore, "the current view still draws while its replacement pends")
  pendingPaths[manifest.storage.wallpapers[1].image] = nil
  admit(renderer, browseView(1))
  renderer:dispose()
end

-- A failed wallpaper names its missing visual and leaves the previous
-- group drawable: no half-ready state publishes, and the replacement
-- admits cleanly once the worker recovers.
function T.failed_wallpaper_keeps_the_previous_group_drawable()
  local pool, inner, _ = storagePool()
  local renderer, graphics, manifest = rendererFixture(pool)
  Assert.isTrue(type(renderer.prepare) == "function", "the renderer prepares its visuals outside drawing")
  local first = browseView(0)
  admit(renderer, first)
  local opened = inner.uploads
  local missing = manifest.storage.wallpapers[1].image
  inner:failAfterUploads(opened, "injected wallpaper failure")
  local ok, ready, failure = pcall(function()
    return renderer:prepare(browseView(1))
  end)
  if ok then
    Assert.isFalse(ready, "a failed wallpaper never reports ready")
    Assert.isTrue(
      type(failure) == "string" and failure:find(missing, 1, true) ~= nil,
      "the failure names its missing visual"
    )
  else
    Assert.isTrue(tostring(ready):find(missing, 1, true) ~= nil, "the failure names its missing visual")
  end
  inner:clearFailure()
  local drawsBefore = #graphics.draws
  renderer:drawPane(first, {}, "lower", placement())
  Assert.isTrue(#graphics.draws > drawsBefore, "the previous group still draws after a failed turnover")
  admit(renderer, browseView(1))
  renderer:dispose()
end

-- Disposal returns every admitted and partial lease exactly once and stays
-- quiet when repeated: no outstanding borrow survives the close.
function T.repeated_dispose_returns_leases_once_and_stays_quiet()
  local pool, inner, _ = storagePool()
  local renderer, _, _ = rendererFixture(pool)
  Assert.isTrue(type(renderer.prepare) == "function", "the renderer prepares its visuals outside drawing")
  admit(renderer, browseView(0))
  Assert.isTrue(inner:stats().outstandingLeases > 0, "admission holds its leases")
  renderer:dispose()
  Assert.equal(inner:stats().outstandingLeases, 0, "disposal returns every lease")
  renderer:dispose()
  Assert.equal(inner:stats().outstandingLeases, 0, "repeated disposal returns nothing again")
end

-- A resolved replacement stages beside the installed group: preparation
-- alone reports ready without retiring the previous visuals, so the old
-- view keeps drawing until the explicit commit installs the new group
-- and returns only the leases the replacement no longer needs.
function T.staged_wallpaper_replacement_keeps_the_previous_group_drawable_until_commit()
  local pool, inner, _ = storagePool()
  local pendingPaths = {}
  local renderer, graphics, manifest = rendererFixture(delayingPool(pool, pendingPaths))
  local current = browseView(0)
  local replacement = browseView(1)
  admit(renderer, current)
  local installedBefore = inner:stats().outstandingLeases
  Assert.isTrue(installedBefore > 0, "admission holds its leases")
  local oldWallpaper = manifest.storage.wallpapers[0].image
  local newWallpaper = manifest.storage.wallpapers[1].image
  local oldImage = assert(renderer._images[oldWallpaper], "the admitted group carries its wallpaper")

  local function drawsImageSince(mark, image)
    for index = mark + 1, #graphics.draws do
      if graphics.draws[index].image == image then
        return true
      end
    end
    return false
  end

  pendingPaths[newWallpaper] = true
  local ready, failure = renderer:prepare(replacement)
  Assert.isFalse(ready, "a pending wallpaper keeps preparation unready")
  Assert.isNil(failure, "a pending wallpaper reports no failure")
  local drawsBefore = #graphics.draws
  renderer:drawPane(current, {}, "lower", placement())
  Assert.isTrue(drawsImageSince(drawsBefore, oldImage), "the current wallpaper still paints while pending")

  pendingPaths[newWallpaper] = nil
  ready, failure = renderer:prepare(replacement)
  Assert.isTrue(ready, "a resolved wallpaper stages ready")
  Assert.isNil(failure, "staging reports no failure")
  drawsBefore = #graphics.draws
  renderer:drawPane(current, {}, "lower", placement())
  Assert.isTrue(drawsImageSince(drawsBefore, oldImage), "preparation alone leaves the previous group drawable")
  Assert.equal(
    inner:stats().outstandingLeases,
    installedBefore + 1,
    "staging holds the new wallpaper beside the installed group"
  )

  settleStagedView(renderer, replacement)
  drawsBefore = #graphics.draws
  renderer:drawPane(replacement, {}, "lower", placement())
  local newImage = assert(renderer._images[newWallpaper], "the commit installs the new wallpaper")
  Assert.isTrue(drawsImageSince(drawsBefore, newImage), "the committed replacement paints its wallpaper")
  Assert.equal(
    inner:stats().outstandingLeases,
    installedBefore,
    "the commit returns only the leases the replacement no longer needs"
  )
  local retired, _ = pcall(function()
    renderer:drawPane(current, {}, "lower", placement())
  end)
  Assert.isFalse(retired, "the retired group no longer draws after the commit")
  renderer:dispose()
end

function T.editor_plates_and_labels_sit_at_the_source_window_positions()
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
  local resources = {
    applicationFrameIndex = 3,
    windowRenderer = {
      drawWindow = function() end,
      drawStandardWindow = function() end,
    },
  }
  local function drew(value, x, y)
    for _, record in ipairs(drawn) do
      if record[1] == value and record[2] == x and record[3] == y then
        return true
      end
    end
    return false
  end
  local marking = {
    mode = 0,
    activeBox = 0,
    tray = "closed",
    wallpaperId = 0,
    wallpaperUnlocks = {},
    boxSlots = {},
    party = {},
    editor = { kind = "markings", mask = 0, selected = 0 },
    cursor = { x = 204, y = 56, pose = "menu" },
  }
  admit(renderer, marking)
  renderer:drawPane(marking, resources, "lower", placement())
  Assert.isTrue(drew("b24:72", 212, 136), "CONFIRM prints at the top of its plate")
  Assert.isTrue(drew("b24:73", 212, 168), "CANCEL prints at the top of its plate below CONFIRM")

  local wallpaper = {
    mode = 0,
    activeBox = 0,
    tray = "closed",
    wallpaperId = 0,
    wallpaperUnlocks = { true },
    boxSlots = {},
    party = {},
    editor = { kind = "wallpaper", selected = 0, focus = "slots" },
    cursor = { x = 59, y = 31, pose = "menu" },
  }
  admit(renderer, wallpaper)
  renderer:drawPane(wallpaper, resources, "lower", placement())
  Assert.isTrue(drew("b24:78", 212, 120), "CHANGE WALLPAPER centres in the title plate")
  Assert.isTrue(drew("b24:76", 224, 172), "the wallpaper chooser's EXIT plate labels the corner button")
  renderer:release()
end

function T.top_screen_draws_the_portrait_types_and_move_rows()
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
  local view = {
    mode = 2,
    activeBox = 0,
    tray = "closed",
    wallpaperId = 0,
    wallpaperUnlocks = {},
    boxSlots = {},
    party = {},
    info = {
      nickname = "CHIKO",
      speciesName = "CHIKORITA",
      level = 12,
      dexNumber = 152,
      types = { "grass", "poison" },
      moves = { "TACKLE", "GROWL", "RAZOR LEAF", "SYNTHESIS" },
      portraitSelector = "CHIKORITA/f0/male/plain",
    },
  }
  admit(renderer, view)
  renderer:drawPane(view, {}, "upper", placement())
  local movesPanel = renderer._images[manifest.storage.ui.movesPanel.image]
  local portrait = renderer._images[MonCache.portraitPagePath(0)]
  local grass = renderer._images["assets/generated/move-icons/type-grass.png"]
  local poison = renderer._images["assets/generated/move-icons/type-poison.png"]
  local function find(image, x, y)
    for _, draw in ipairs(graphics.draws) do
      if draw.image == image and draw.x == x and draw.y == y then
        return draw
      end
    end
    return nil
  end
  Assert.notNil(find(movesPanel, 160, 96), "the Move info panel draws at its source cell")
  local picture = assert(find(portrait, 100, 60), "the mon picture draws at its source rect origin")
  Assert.equal(picture.sx, 1, "the portrait frame draws at its native 80x80 size")
  Assert.notNil(find(grass, 144, 40), "the first type icon sits at its source anchor")
  Assert.notNil(find(poison, 178, 40), "the second type icon sits at its source anchor")
  local function drew(value, x, y)
    for _, record in ipairs(drawn) do
      if record[1] == value and record[2] == x and record[3] == y then
        return true
      end
    end
    return false
  end
  Assert.isTrue(drew("CHIKO", 8, 56), "the nickname prints at its source window")
  Assert.isTrue(drew("CHIKORITA", 64, 40), "the species name prints at its source window")
  Assert.isTrue(drew("12", 48, 72), "the level prints at its source window")
  Assert.isTrue(drew("152", 24, 40), "the dex number prints at its source window")
  for row, move in ipairs({ "TACKLE", "GROWL", "RAZOR LEAF", "SYNTHESIS" }) do
    Assert.isTrue(drew(move, 168, 88 + row * 16), "move row " .. row .. " prints in the Move panel")
  end
  renderer:release()
end

function T.box_tray_draws_its_panel_thumbnails_plate_and_dots()
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
  local boxes = {}
  for column = 0, 5 do
    boxes[column + 1] = {
      box = column,
      name = "BOX " .. (column + 1),
      count = column == 1 and 2 or 0,
      wallpaperId = column,
      dots = column == 1 and { [1] = 0, [8] = 5 } or {},
    }
  end
  local view = {
    mode = 2,
    activeBox = 0,
    tray = "closed",
    wallpaperId = 0,
    wallpaperUnlocks = {},
    boxSlots = {},
    party = {},
    cursor = { x = 77, y = 23, pose = "menu", layout = "tray", node = 38 },
    boxTray = { mode = "box", trayBox = 1, page = 0, changeBox = true, boxes = boxes },
  }
  admit(renderer, view)
  renderer:drawPane(view, {}, "lower", placement())
  local storage = manifest.storage
  local panel = renderer._images[storage.ui.boxTray.image]
  local thumbnail = renderer._images[storage.boxThumbnail.variants[0].image]
  local marker = renderer._images[storage.ui.tray.marker.image]
  local plate = renderer._images[storage.ui.tray.cursor.image]
  local label = renderer._images[storage.ui.tray.label.image]
  local prev = renderer._images[storage.ui.tray.prev.image]
  renderer:release()
  local function find(image, x, y)
    for _, draw in ipairs(graphics.draws) do
      if draw.image == image and draw.x == x and draw.y == y then
        return draw
      end
    end
    return nil
  end
  Assert.notNil(find(panel, 0, 0), "the tray strip draws at the source cell")
  Assert.notNil(find(thumbnail, 27, 11), "thumbnail column 0 draws at its source rect")
  Assert.notNil(find(marker, 31, 15), "the current-box marker frames the active box")
  Assert.notNil(find(plate, 16, 0), "the name/count plate follows its source cursor x")
  Assert.notNil(find(label, 69, 23), "the label anchors on the selected thumbnail")
  Assert.notNil(find(prev, -3, 15), "the previous arrow uses its source anchor")
  local dots = 0
  for _, rectangle in ipairs(graphics.rectangles) do
    if rectangle.mode == "fill" and rectangle.w == 2 and rectangle.h == 2 then
      dots = dots + 1
    end
  end
  Assert.equal(dots, 2, "occupied slots draw one 2x2 BASE_COLOR dot each")
  local function drew(value, x, y)
    for _, record in ipairs(drawn) do
      if record[1] == value and record[2] == x and record[3] == y then
        return true
      end
    end
    return false
  end
  Assert.isTrue(drew("BOX 2", 72, 0), "the selected box name centres in its 96 px window")
  Assert.isTrue(drew("2/30", 148, 0), "the selected box count centres in its 40 px window")
  Assert.isTrue(drew("b24:63", 68, 172), "the Change Box plate labels the wide bottom button")
  Assert.isTrue(drew("b24:76", 224, 172), "the tray's EXIT plate labels the corner button")
end

-- The framed plates assemble the eight named frame cells around a flat
-- interior fill instead of stretching the tile atlas (PCBox_DrawButtonWindow).
function T.framed_plates_assemble_source_cells_and_fill_the_interior()
  local renderer, graphics, manifest = rendererFixture()
  local view = {
    mode = 2,
    activeBox = 0,
    tray = "closed",
    wallpaperId = 0,
    wallpaperUnlocks = {},
    boxSlots = {},
    party = {},
    menu = { actions = { "summary" }, selected = 1 },
    cursor = { x = 212, y = 136, pose = "browse", layout = "move", node = 36 },
  }
  admit(renderer, view)
  renderer:drawPane(view, {}, "lower", placement())
  local atlas = renderer._images[manifest.storage.ui.windowFrames.standard.paletteBank0.image]
  renderer:release()
  local fill = manifest.storage.ui.windowFrames.fill
  local expected = { fill.r / 255, fill.g / 255, fill.b / 255, 1 }
  local rect = PcStorageGeometry.actionButtonRect(1, 0)
  local inset
  for _, rectangle in ipairs(graphics.rectangles) do
    if
      rectangle.mode == "fill"
      and rectangle.x == rect.x + 8
      and rectangle.y == rect.y + 8
      and rectangle.w == rect.width - 16
      and rectangle.h == rect.height - 16
    then
      inset = rectangle
    end
  end
  Assert.notNil(inset, "the plate interior fills its one-tile inset box")
  Assert.deepEqual(inset.color, expected, "the interior uses the source window-palette fill")
  -- The frame cells come from the compiled 96x8 atlas and land at the border
  -- roles of the plate: corners, per-row edges and per-column top/bottom.
  local seen = {}
  for _, draw in ipairs(graphics.draws) do
    if draw.image == atlas then
      seen[draw.x .. "," .. draw.y] = true
    end
  end
  for _, position in ipairs({
    { rect.x, rect.y },
    { rect.x + 80, rect.y },
    { rect.x, rect.y + 16 },
    { rect.x + 80, rect.y + 16 },
    { rect.x, rect.y + 8 },
    { rect.x + 80, rect.y + 8 },
    { rect.x + 8, rect.y },
    { rect.x + 8, rect.y + 16 },
    { rect.x + 72, rect.y },
    { rect.x + 72, rect.y + 16 },
  }) do
    Assert.isTrue(
      seen[position[1] .. "," .. position[2]] == true,
      "a frame cell draws at " .. position[1] .. "," .. position[2]
    )
  end
end

-- The box arrows hide while the party panel, a tray, an editor or a prompt
-- covers the box (PCBox_SetBoxArrowsVisible call sites).
function T.box_arrows_hide_behind_trays_editors_and_prompts()
  local renderer, graphics, manifest = rendererFixture()
  local arrow = manifest.storage.ui.arrows.left
  local rawView = { mode = 2, activeBox = 0, tray = "closed", wallpaperId = 0, boxSlots = {}, party = {} }
  admit(renderer, rawView)
  renderer:drawPane(rawView, {}, "lower", placement())
  local arrowImage = renderer._images[arrow.image]
  local function arrowDrawn(view)
    local start = #graphics.draws
    admit(renderer, view)
    renderer:drawPane(view, {}, "lower", placement())
    for index = start + 1, #graphics.draws do
      if graphics.draws[index].image == arrowImage then
        return true
      end
    end
    return false
  end
  local base = { mode = 2, activeBox = 0, tray = "closed", wallpaperId = 0, boxSlots = {}, party = {} }
  Assert.isTrue(arrowDrawn(rawView), "a plain browse view shows the box arrows")
  local trayOpen = { mode = 2, activeBox = 0, tray = "left", wallpaperId = 0, boxSlots = { false }, party = {} }
  Assert.isFalse(arrowDrawn(trayOpen), "the open party panel hides the box arrows")
  local prompting = {
    mode = 2,
    activeBox = 0,
    tray = "closed",
    wallpaperId = 0,
    boxSlots = { false },
    party = {},
    message = { id = 11, window = "W37", yesNo = true },
  }
  -- A yes/no prompt owns the screen; the arrows hide behind it.
  renderer._text = {
    drawText = function() end,
    textWidth = function()
      return 0
    end,
    windowBackgroundColor = function()
      return { 1, 1, 1, 1 }
    end,
  }
  local promptResources = {
    applicationFrameIndex = 1,
    windowRenderer = { drawWindow = function() end, drawStandardWindow = function() end },
  }
  local function promptArrowDrawn()
    local start = #graphics.draws
    admit(renderer, prompting)
    renderer:drawPane(prompting, promptResources, "lower", placement())
    for index = start + 1, #graphics.draws do
      if graphics.draws[index].image == arrowImage then
        return true
      end
    end
    return false
  end
  Assert.isFalse(promptArrowDrawn(), "a prompt hides the box arrows")
  local editing = {
    mode = 2,
    activeBox = 0,
    tray = "closed",
    wallpaperId = 0,
    boxSlots = { false },
    party = {},
    editor = { kind = "markings", mask = 0, selected = 0 },
  }
  Assert.isFalse(arrowDrawn(editing), "an editor hides the box arrows")
  Assert.notNil(base)
  renderer:release()
end

-- The box-tray strip shows SUMMARY on an occupied box slot and CHANGE BOX on
-- another box's thumbnail (PCBox_DrawSummaryButton / _DrawChangeBoxButton).
function T.box_tray_plate_switches_between_summary_and_change_box()
  local function plateFor(node, occupied)
    local boxes = {}
    for column = 0, 5 do
      boxes[column + 1] = { box = column, name = "BOX " .. column, count = 0, wallpaperId = column, dots = {} }
    end
    local view = {
      mode = 2,
      activeBox = 0,
      tray = "left",
      wallpaperId = 0,
      boxSlots = {},
      party = {},
      cursor = { x = 24, y = 36, pose = "menu", layout = "tray", node = node },
      boxTray = { mode = "box", trayBox = 1, page = 0, changeBox = true, boxes = boxes },
    }
    if occupied then
      view.boxSlots[5] = { iconKey = "k", heldItem = "NONE" }
    end
    for _, button in ipairs(PcStorageGeometry.bottomButtons(view)) do
      if button.rect.x == 0 and button.rect.width == 136 then
        return button
      end
    end
    return nil
  end
  local summary = assert(plateFor(4, true), "an occupied box slot offers the wide plate")
  Assert.equal(summary.messageId, 65, "the wide plate is SUMMARY on a mon")
  Assert.deepEqual(summary.target, { type = "action", action = "summary" })
  local change = assert(plateFor(38, false), "another box's thumbnail offers the wide plate")
  Assert.equal(change.messageId, 63, "the wide plate is CHANGE BOX on a thumbnail")
  Assert.deepEqual(change.target, { type = "box_tray_change" })
end

function T.hand_cursor_alternates_its_two_source_frames()
  local renderer, graphics, manifest = rendererFixture()
  local browse = manifest.storage.ui.cursors.browse
  Assert.equal(#browse.frames, 2, "the browsing hand carries its two source frames")
  local cursorView = {
    mode = 0,
    activeBox = 0,
    tray = "closed",
    wallpaperId = 0,
    wallpaperUnlocks = {},
    boxSlots = {},
    party = {},
    cursor = { x = 120, y = 80, pose = "browse" },
  }
  admit(renderer, cursorView)
  local frameImages = { renderer._images[browse.frames[1].image], renderer._images[browse.frames[2].image] }
  Assert.isTrue(
    frameImages[1] ~= nil and frameImages[1] ~= frameImages[2],
    "the two frames name different source cells"
  )
  local function cursorImageAfter(advance)
    for _ = 1, advance do
      renderer:stepAnimation(cursorView)
    end
    local before = #graphics.draws
    renderer:drawPane(cursorView, {}, "lower", placement(), true)
    for index = before + 1, #graphics.draws do
      local draw = graphics.draws[index]
      if draw.image == frameImages[1] or draw.image == frameImages[2] then
        return draw.image
      end
    end
    return nil
  end
  local first = browse.frames[1].duration
  local second = browse.frames[2].duration
  Assert.equal(cursorImageAfter(0), frameImages[1], "the hand opens on its first source frame")
  Assert.equal(cursorImageAfter(first - 1), frameImages[1], "the first frame holds for its source duration")
  Assert.equal(cursorImageAfter(1), frameImages[2], "the hand pulses to its second frame")
  Assert.equal(cursorImageAfter(second), frameImages[1], "the two-frame pulse loops")
  renderer:release()
end

-- A box icon provider double that records the draws the renderer makes.
local function recordingIcons()
  local image = { setFilter = function() end }
  return {
    dimensions = function()
      return { width = 32, height = 32 }
    end,
    image = function()
      return image
    end,
    handleFor = function()
      return { image = image, kind = "rgba8" }
    end,
    quadFor = function()
      return { icon = true }
    end,
  },
    image
end

function T.selected_icon_outline_draws_eight_silhouette_copies_behind_the_icon()
  local renderer, graphics = rendererFixture()
  local icons, iconImage = recordingIcons()
  local slots = {}
  for slot = 1, 30 do
    slots[slot] = false
  end
  slots[1] = { heldItem = "NONE", markings = 0, iconKey = "selected" }
  local view = {
    mode = 2,
    activeBox = 0,
    tray = "closed",
    wallpaperId = 0,
    wallpaperUnlocks = {},
    boxSlots = slots,
    party = {},
    focus = { domain = "box", slot = 0 },
    menu = { actions = { "move" }, selected = 1, address = { kind = "box", slot = 0 } },
    cursor = { x = 120, y = 80, pose = "menu" },
  }
  admit(renderer, view)
  renderer:drawPane(view, { icons = icons }, "lower", placement(), true)
  local iconDraws = {}
  for _, draw in ipairs(graphics.draws) do
    if draw.image == iconImage then
      iconDraws[#iconDraws + 1] = draw
    end
  end
  renderer:release()
  Assert.equal(#iconDraws, 9, "the selected icon draws eight silhouette copies and the icon itself")
  local icon = iconDraws[#iconDraws]
  Assert.deepEqual({ icon.color[1], icon.color[2], icon.color[3] }, { 1, 1, 1 }, "the icon keeps its own colours")
  local expected = {
    { 1, 0 },
    { -1, 0 },
    { 0, 1 },
    { 0, -1 },
    { 1, 1 },
    { 1, -1 },
    { -1, 1 },
    { -1, -1 },
  }
  for index, offset in ipairs(expected) do
    local copy = assert(iconDraws[index], "outline copy " .. index)
    Assert.deepEqual(
      { copy.x, copy.y },
      { icon.x + offset[1], icon.y + offset[2] },
      "outline copy " .. index .. " sits in the one-pixel neighbourhood"
    )
    Assert.deepEqual({ copy.color[1], copy.color[2], copy.color[3] }, { 0, 0, 0 }, "outline copies are silhouettes")
  end
end

function T.held_item_outline_wraps_the_item_icon_in_item_mode()
  local renderer, graphics = rendererFixture()
  local itemImage = { setFilter = function() end }
  local itemIcons = {
    dimensions = function()
      return { width = 32, height = 32 }
    end,
    handle = function()
      return { image = itemImage, kind = "rgba8" }
    end,
    quadFor = function()
      return { item = true }
    end,
  }
  local slots = {}
  for slot = 1, 30 do
    slots[slot] = false
  end
  slots[1] = { heldItem = "POTION", itemIconKey = "item-potion", markings = 0, iconKey = "holder" }
  local view = {
    mode = 3,
    activeBox = 0,
    tray = "closed",
    wallpaperId = 0,
    wallpaperUnlocks = {},
    boxSlots = slots,
    party = {},
    focus = { domain = "box", slot = 0 },
    cursor = { x = 120, y = 80, pose = "browse" },
  }
  admit(renderer, view)
  renderer:drawPane(view, { itemIcons = itemIcons }, "lower", placement(), true)
  local itemDraws = {}
  for _, draw in ipairs(graphics.draws) do
    if draw.image == itemImage then
      itemDraws[#itemDraws + 1] = draw
    end
  end
  renderer:release()
  Assert.equal(#itemDraws, 9, "the held item draws eight silhouette copies and the item itself")
  local icon = itemDraws[#itemDraws]
  Assert.deepEqual({ icon.color[1], icon.color[2], icon.color[3] }, { 1, 1, 1 }, "the item keeps its own colours")
  for index = 1, 8 do
    local copy = assert(itemDraws[index], "item outline copy " .. index)
    Assert.deepEqual(
      { copy.color[1], copy.color[2], copy.color[3] },
      { 0, 0, 0 },
      "item outline copies are silhouettes"
    )
    Assert.isTrue(
      math.abs(copy.x - icon.x) <= 1 and math.abs(copy.y - icon.y) <= 1 and (copy.x ~= icon.x or copy.y ~= icon.y),
      "item outline copy " .. index .. " sits in the one-pixel neighbourhood"
    )
  end
end

return { tests = T }
