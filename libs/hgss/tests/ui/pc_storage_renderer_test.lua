-- PC Storage editor previews use the compiled wallpaper and marking visuals.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local FakeGraphics = require("tests.support.FakeGraphics")
local PngWriter = require("libs.assets.src.PngWriter")
local PcPresentationFixture = require("tests.support.PcPresentationFixture")
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
  }
  admit(renderer, chooserView)
  renderer:drawPane(chooserView, {}, "lower", placement())
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
  local markingView = {
    mode = 0,
    activeBox = 0,
    tray = "closed",
    wallpaperId = 0,
    wallpaperUnlocks = { false, false, false, false, false, false, false, false },
    boxSlots = {},
    party = {},
    editor = { kind = "markings", mask = 5, selected = 2 },
  }
  admit(renderer, markingView)
  renderer:drawPane(markingView, {}, "lower", placement(), true)
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
  local messageView = {
    mode = 2,
    activeBox = 0,
    tray = "closed",
    wallpaperId = 0,
    wallpaperUnlocks = {},
    boxSlots = {},
    party = {},
    message = { id = 11, window = "W37", yesNo = true },
  }
  admit(renderer, messageView)
  renderer:drawPane(messageView, resources, "lower", placement())
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
  Assert.equal(
    inner:stats().outstandingLeases,
    2 * opened,
    "each open holds its own borrow of the shared visuals"
  )
  second:release()
  Assert.equal(
    inner:stats().outstandingLeases,
    opened,
    "closing the second box returns only its own borrows"
  )
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
  Assert.isTrue(
    type(renderer.prepare) == "function",
    "the renderer prepares its visuals outside drawing"
  )
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
  Assert.isTrue(
    type(renderer.prepare) == "function",
    "the renderer prepares its visuals outside drawing"
  )
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
  Assert.isTrue(
    type(renderer.prepare) == "function",
    "the renderer prepares its visuals outside drawing"
  )
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
  Assert.isTrue(
    type(renderer.prepare) == "function",
    "the renderer prepares its visuals outside drawing"
  )
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
    Assert.isTrue(
      tostring(ready):find(missing, 1, true) ~= nil,
      "the failure names its missing visual"
    )
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
  Assert.isTrue(
    type(renderer.prepare) == "function",
    "the renderer prepares its visuals outside drawing"
  )
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
  Assert.isTrue(
    drawsImageSince(drawsBefore, oldImage),
    "preparation alone leaves the previous group drawable"
  )
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

return { tests = T }
