-- Integrated render matrix for the shared presentation boundary: exact
-- integer magnification, bounded cropping, DPI equivalence, translated
-- origins, native responsive visibility, and terminal failure propagation
-- through one logical-surface contract; every migrated interface resolving its
-- real plans across representative hosts with matched geometry; real
-- party readability through the borrowed text renderer; and single
-- magnification for the hosted naming child. Per-application suites own
-- source-content depth (portraits, models, card art); this matrix proves
-- the common boundary uniformly. Only solid fills and measured fixture
-- ink are compared, with every painted edge on whole host pixels.

local Assert = require("tests.support.Assert")
local ApplicationLayout = require("libs.ui.src.ApplicationLayout")
local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local BagInterface = require("game.hgss.src.field.BagInterface")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
local LogicalSurface = require("libs.ui.src.LogicalSurface")
local MainMenuInterface = require("app.src.mainmenu.MainMenuInterface")
local SaveEditorInterface = require("app.src.saveeditor.SaveEditorInterface")
local MonCache = require("libs.assets.src.MonCache")
local MonIconAssetProvider = require("libs.hgss.src.presentation.MonIconAssetProvider")
local NamingInterface = require("game.hgss.src.newgame.NamingInterface")
local PartyPresentationFixture = require("tests.support.PartyPresentationFixture")
local PartyScreenInterface = require("game.hgss.src.field.PartyScreenInterface")
local PartyScreenRenderer = require("libs.hgss.src.ui.PartyScreenRenderer")
local PixelScale = require("libs.ui.src.PixelScale")
local PngWriter = require("libs.assets.src.PngWriter")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local ScreenTopology = require("libs.ui.src.ScreenTopology")
local StartMenuInterface = require("game.hgss.src.field.StartMenuInterface")
local StarterChoiceInterface = require("game.hgss.src.starters.StarterChoiceInterface")
local TrainerCardInterface = require("game.hgss.src.field.TrainerCardInterface")

local T = {}

local function measurement(width, height, topology, pixelRatio)
  return {
    width = width,
    height = height,
    topology = topology,
    pixelRatio = pixelRatio or 1,
    signature = "matrix:" .. width .. "x" .. height .. "@" .. (pixelRatio or 1),
  }
end

local function singleDisplay(width, height, pixelRatio, originX, originY)
  return measurement(
    width,
    height,
    ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = originX or 0, y = originY or 0, width = width, height = height },
      role = "world",
      touch = true,
    }),
    pixelRatio
  )
end

local function translatedPair()
  return measurement(
    800,
    600,
    ScreenTopology.dualDisplay({
      id = "world",
      rect = { x = 400, y = 100, width = 256, height = 192 },
      role = "world",
      touch = false,
    }, {
      id = "aux",
      rect = { x = 100, y = 300, width = 256, height = 192 },
      role = "auxiliary",
      touch = true,
    }),
    1
  )
end

local function contextFor(measured, configuration, interfaceTable)
  local selection = ApplicationLayout.selectSurfaces(measured)
  return {
    measurement = measured,
    configuration = configuration,
    primary = selection.primary,
    secondary = selection.secondary,
    nativeLikeInterface = interfaceTable.nativeLike,
  }
end

local function renderToCanvas(scope, width, height, paint)
  local lg = love.graphics
  local canvas = scope:own(lg.newCanvas(width, height))
  lg.setCanvas(canvas)
  lg.clear(0, 0, 0, 0)
  paint()
  lg.setCanvas()
  return canvas
end

local function assertPixelNear(data, x, y, r, g, b, a, label)
  local ar, ag, ab, aa = data:getPixel(x, y)
  Assert.near(ar, r, 1e-2, label .. " red")
  Assert.near(ag, g, 1e-2, label .. " green")
  Assert.near(ab, b, 1e-2, label .. " blue")
  Assert.near(aa, a, 1e-2, label .. " alpha")
end

local function captureState(lg)
  local r, g, b, a = lg.getColor()
  local sx, sy, sw, sh = lg.getScissor()
  return { color = { r, g, b, a }, scissor = { sx, sy, sw, sh }, canvas = lg.getCanvas() }
end

local function assertStateRestored(before, lg, label)
  local after = captureState(lg)
  Assert.deepEqual(after.color, before.color, label .. " color")
  Assert.deepEqual(after.scissor, before.scissor, label .. " scissor")
  Assert.isTrue(after.canvas == before.canvas, label .. " render target")
end

local function paintSolid(color, width, height)
  return function()
    local lg = love.graphics
    lg.setColor(color[1], color[2], color[3], color[4])
    lg.rectangle("fill", 0, 0, width, height)
  end
end

local function interactivePane(plan)
  for _, pane in ipairs(assert(plan.panes, "the plan must carry its panes")) do
    if pane.interactive then
      return assert(pane.placement, "the interactive pane carries its placement")
    end
  end
  error("the plan carries no interactive pane", 0)
end

-- Integer placements magnify logical blocks uniformly: every logical pixel
-- covers exactly scale x scale physical pixels with hard edges.
function T.integer_fits_magnify_blocks_uniformly(scope)
  local lg = love.graphics
  local placement = assert(
    PixelScale.placeFixed({ x = 0, y = 0, width = 640, height = 480 }, 256, 192),
    "640x480 must place its surface"
  )
  Assert.equal(placement.pixelScale, 2, "640x480 must fit at 2x")
  local canvas = renderToCanvas(scope, 640, 480, function()
    LogicalSurface.draw(lg, placement, paintSolid({ 1, 1, 1, 1 }, 256, 192))
  end)
  local data = scope:own(canvas:newImageData())
  -- Full frame at 2x from (64,48): the first logical pixel covers (64,48)
  -- through (65,49), and the edge to the next pixel is exact.
  assertPixelNear(data, 64, 48, 1, 1, 1, 1, "block origin paints")
  assertPixelNear(data, 65, 49, 1, 1, 1, 1, "block interior paints")
  assertPixelNear(data, 66, 48, 1, 1, 1, 1, "adjacent logical pixel starts exactly")
  assertPixelNear(data, 63, 48, 0, 0, 0, 0, "outside the frame stays clear")
  assertPixelNear(data, 64 + 512, 100, 0, 0, 0, 0, "past the frame edge stays clear")
end

-- The bounded 3x bump hides only its budgeted margins: the visible image
-- keeps integral pixels while the cropped edges stay clear.
function T.cropped_3x_hides_only_budgeted_margins(scope)
  local lg = love.graphics
  local placement = assert(
    PixelScale.placeFixed({ x = 0, y = 0, width = 750, height = 560 }, 256, 192),
    "750x560 must place its surface"
  )
  Assert.equal(placement.pixelScale, 3, "750x560 must bump to 3x")
  Assert.deepEqual(
    placement.crop,
    { left = 3, right = 3, top = 3, bottom = 3 },
    "the bump must spend exactly the default budget"
  )
  local canvas = renderToCanvas(scope, 750, 560, function()
    LogicalSurface.draw(lg, placement, paintSolid({ 0.5, 0.5, 0.5, 1 }, 256, 192))
  end)
  local data = scope:own(canvas:newImageData())
  for _, x in ipairs({ 0, 100, 375, 749 }) do
    assertPixelNear(data, x, 0, 0, 0, 0, 0, "cropped top margin stays clear at x=" .. x)
    assertPixelNear(data, x, 559, 0, 0, 0, 0, "cropped bottom margin stays clear at x=" .. x)
  end
  assertPixelNear(data, 375, 300, 0.5, 0.5, 0.5, 1, "visible content renders inside the clip")
  -- Cropped input inverts the full origin: the clip origin maps to the
  -- first visible logical pixel, never to zero.
  local lx, ly = LayoutGeometry.hostToLogical(placement, placement.clipRect.x, placement.clipRect.y)
  Assert.equal(lx, placement.visibleLogicalRect.x, "clip maps to its visible logical origin")
  Assert.equal(ly, placement.visibleLogicalRect.y, "clip maps to its visible logical origin")
end

-- The same physical bounds through different DPI ratios choose the same
-- pixel scale and crop: one explicit boundary conversion, never repeated
-- per widget.
function T.dpi2_matches_dpi1_physical_pixels(scope)
  local lg = love.graphics
  local one = assert(PixelScale.placeFixed({ x = 0, y = 0, width = 750, height = 560 }, 256, 192, { pixelRatio = 1 }))
  local two = assert(PixelScale.placeFixed({ x = 0, y = 0, width = 375, height = 280 }, 256, 192, { pixelRatio = 2 }))
  Assert.equal(two.pixelScale, one.pixelScale, "equal physical bounds must choose equal pixel scales")
  Assert.deepEqual(two.crop, one.crop, "equal physical bounds must crop equally")
  Assert.equal(two.scale, one.pixelScale / 2, "host-unit scale must divide out the pixel ratio")
  local first = renderToCanvas(scope, 750, 560, function()
    LogicalSurface.draw(lg, one, paintSolid({ 0.2, 0.6, 0.2, 1 }, 256, 192))
  end)
  local second = renderToCanvas(scope, 375, 280, function()
    LogicalSurface.draw(lg, two, paintSolid({ 0.2, 0.6, 0.2, 1 }, 256, 192))
  end)
  local firstData = scope:own(first:newImageData())
  local secondData = scope:own(second:newImageData())
  -- The same logical point lands on the same physical pixel in both.
  local p1x, p1y = LayoutGeometry.logicalToHost(one, 100, 100)
  local p2x, p2y = LayoutGeometry.logicalToHost(two, 100, 100)
  Assert.equal(p1x * 1, p2x * 2, "both ratios must address the same physical column")
  Assert.equal(p1y * 1, p2y * 2, "both ratios must address the same physical row")
  assertPixelNear(firstData, math.floor(p1x), math.floor(p1y), 0.2, 0.6, 0.2, 1, "ratio-1 paints")
  assertPixelNear(secondData, math.floor(p2x), math.floor(p2y), 0.2, 0.6, 0.2, 1, "ratio-2 paints")
end

-- Translated origins invert exactly: nonzero host origins never leak into
-- logical coordinates on either surface of a genuine pair.
function T.translated_origins_invert_exactly(scope)
  local lg = love.graphics
  local measured = translatedPair()
  local selection = ApplicationLayout.selectSurfaces(measured)
  local primary = assert(selection.primary, "the pair must select its primary surface")
  local secondary = assert(selection.secondary, "the pair must select its auxiliary surface")
  for _, surface in ipairs({ primary, secondary }) do
    local bounds = assert(surface.usableBounds, "each selected surface must expose usable bounds")
    local placement = assert(
      PixelScale.placeFixed({ x = bounds.x, y = bounds.y, width = bounds.width, height = bounds.height }, 256, 192),
      "each translated surface must place its pane"
    )
    -- The full frame origin inverts to the logical origin even though the
    -- host origin is nonzero; points outside the visible clip never hit.
    local ox, oy = LayoutGeometry.hostToLogical(placement, placement.frame.x, placement.frame.y)
    assert(ox ~= nil and oy ~= nil, "translated frame inverts to its logical origin")
    Assert.near(ox, 0, 1e-9, "translated frame inverts to its logical origin")
    Assert.near(oy, 0, 1e-9, "translated frame inverts to its logical origin")
    Assert.isNil(
      LayoutGeometry.hostToLogical(placement, bounds.x - 4, bounds.y - 4),
      "points outside the translated clip never hit"
    )
    local canvas = renderToCanvas(scope, 800, 600, function()
      LogicalSurface.draw(lg, placement, paintSolid({ 0.8, 0.1, 0.1, 1 }, 256, 192))
    end)
    local data = scope:own(canvas:newImageData())
    local fx, fy = math.floor(placement.frame.x), math.floor(placement.frame.y)
    if fx >= 0 and fy >= 0 and fx < 800 and fy < 600 then
      assertPixelNear(data, fx, fy, 0.8, 0.1, 0.1, 1, "translated frame paints")
    end
  end
end

-- A fixed source surface has no sub-1x fallback; responsive consumers cover
-- the visible host at native logical scale instead.
function T.fixed_no_fit_uses_a_native_responsive_viewport(scope)
  local lg = love.graphics
  local bounds = { x = 0, y = 0, width = 200, height = 150 }
  Assert.isNil(PixelScale.placeFixed(bounds, 256, 192), "a fixed canvas is unavailable below the integer fit")
  local surface = PixelScale.cover(bounds, 1)
  Assert.equal(surface.placement.pixelScale, 1, "responsive coverage keeps source pixels native")
  Assert.deepEqual(surface.logicalViewport, { x = 0, y = 0, width = 200, height = 150 })
  local canvas = renderToCanvas(scope, 200, 150, function()
    LogicalSurface.draw(lg, surface.placement, paintSolid({ 0.9, 0.9, 0.1, 1 }, 200, 150))
  end)
  local data = scope:own(canvas:newImageData())
  assertPixelNear(data, 2, 2, 0.9, 0.9, 0.1, 1, "the near native pixel stays visible")
  assertPixelNear(data, 197, 147, 0.9, 0.9, 0.1, 1, "the far native pixel stays visible")
end

-- A failing draw callback propagates the original error without generic
-- state restoration; the test rebalances its own leaked scope before the
-- next draw paints cleanly.
function T.callback_failure_propagates_without_generic_restore(scope)
  local lg = love.graphics
  local placement = assert(
    PixelScale.placeFixed({ x = 0, y = 0, width = 640, height = 480 }, 256, 192),
    "640x480 must place its surface"
  )
  local marker = {}
  local canvas = scope:own(lg.newCanvas(640, 480))
  lg.setCanvas(canvas)
  local ok, err = pcall(function()
    LogicalSurface.draw(lg, placement, function()
      lg.setColor(1, 0, 0, 1)
      error(marker, 0)
    end)
  end)
  Assert.isFalse(ok, "the callback failure must propagate")
  Assert.isTrue(err == marker, "the original error object must propagate unwrapped")
  local r, g, b, a = lg.getColor()
  Assert.deepEqual({ r, g, b, a }, { 1, 0, 0, 1 }, "no generic unwind restores state after the failure")
  lg.pop()
  lg.setCanvas()
  local repaint = renderToCanvas(scope, 640, 480, function()
    LogicalSurface.draw(lg, placement, paintSolid({ 0.3, 0.3, 0.9, 1 }, 256, 192))
  end)
  local data = scope:own(repaint:newImageData())
  assertPixelNear(data, 320, 240, 0.3, 0.3, 0.9, 1, "the next draw paints cleanly after failure")
end

-- Synthetic manifest mirror for matrix geometry: the pane/neighbor
-- contract resolves without generated assets, which the dedicated party
-- graphics smoke covers against the canonical cache.
local function matrixPartyManifest()
  local panels = {}
  local origins = { { 0, 0 }, { 128, 8 }, { 0, 48 }, { 128, 56 }, { 0, 96 }, { 128, 104 } }
  for slot, origin in ipairs(origins) do
    local ox, oy = origin[1], origin[2]
    panels[slot] = {
      origin = { x = ox, y = oy },
      iconAnchor = { x = ox + 30, y = oy + 16 },
      ballAnchor = { x = ox + 16, y = oy + 14 },
      heldAnchor = { x = ox + 38, y = oy + 24 },
      capsuleAnchor = { x = ox + 46, y = oy + 24 },
      statusRect = { x = ox + 24, y = oy + 40, width = 24, height = 8 },
      cursorSequence = 1,
      size = { width = 128, height = 48 },
      chrome = {
        normal = { image = "test/panel.png", width = 128, height = 48 },
        selected = { image = "test/panel-selected.png", width = 128, height = 48 },
        fainted = { image = "test/panel-fainted.png", width = 128, height = 48 },
        selectedFainted = { image = "test/panel-selected-fainted.png", width = 128, height = 48 },
        switchSelection = { image = "test/panel-switch-selection.png", width = 128, height = 48 },
      },
      text = {
        name = { x = ox + 48, y = oy + 8, width = 72, height = 16 },
        level = { x = ox + 0, y = oy + 32, width = 48, height = 16 },
      },
      hp = {
        bar = { x = ox + 64, y = oy + 24, width = 48, height = 8 },
        number = { x = ox + 56, y = oy + 32, width = 64, height = 16 },
      },
      compat = { x = ox + 48, y = oy + 32, width = 80, height = 16 },
    }
  end
  local function dpadBox(up, down, leftNeighbor, rightNeighbor)
    return {
      left = 0,
      top = 0,
      width = 0,
      height = 0,
      up = up,
      down = down,
      leftNeighbor = leftNeighbor,
      rightNeighbor = rightNeighbor,
    }
  end
  local function touch(top, bottom, left, right)
    return { top = top, bottom = bottom, left = left, right = right }
  end
  return {
    panels = panels,
    controls = {
      cancel = {
        anchor = { x = 232, y = 176 },
        label = PartyPresentationFixture.manifest().controls.cancel.label,
        textRect = { x = 200, y = 168, width = 48, height = 16 },
        align = "center",
      },
    },
    detail = {
      iconAnchor = { x = 30, y = 200 },
      statusAnchor = { x = 50, y = 220 },
      nicknameTextOrigin = { x = 56, y = 192 },
      heldItemTextOrigin = { x = 138, y = 212 },
    },
    text = PartyPresentationFixture.manifest().text,
    windows = {
      message = { x = 16, y = 168, width = 160, height = 16 },
      context = { x = 152, y = 120, width = 96, height = 64 },
      browse = { x = 16, y = 168, width = 160, height = 16 },
      action = { x = 8, y = 136, width = 176, height = 48 },
      prompt = { x = 200, y = 80 },
    },
    navigation = {
      dpad = {
        default = {
          dpadBox(7, 2, 7, 1),
          dpadBox(7, 3, 0, 2),
          dpadBox(0, 4, 1, 3),
          dpadBox(1, 5, 2, 4),
          dpadBox(2, 7, 3, 5),
          dpadBox(3, 7, 4, 7),
          dpadBox(0, 0, 0, 0),
          dpadBox(5, 1, 5, 0),
        },
      },
    },
    hitboxes = {
      touch = {
        default = {
          touch(0, 48, 0, 128),
          touch(8, 56, 128, 0),
          touch(48, 96, 0, 128),
          touch(56, 104, 128, 0),
          touch(96, 144, 0, 128),
          touch(104, 152, 128, 0),
          touch(152, 192, 200, 0),
        },
      },
    },
    iconAnimations = PartyPresentationFixture.manifest().iconAnimations,
    contextMenu = {
      topLevel = PartyPresentationFixture.manifest().contextMenu.topLevel,
      subcontext = PartyPresentationFixture.manifest().contextMenu.subcontext,
      textPalette = PartyPresentationFixture.manifest().contextMenu.textPalette,
      fillPalette = PartyPresentationFixture.manifest().contextMenu.fillPalette,
      frames = {
        standard = {
          raised = { image = "test/menu-standard-raised.png", width = 128, height = 32 },
          selected = { image = "test/menu-standard-selected.png", width = 128, height = 32 },
          pressed = { image = "test/menu-standard-pressed.png", width = 128, height = 32 },
        },
        cancel = {
          raised = { image = "test/menu-cancel-raised.png", width = 56, height = 40 },
          selected = { image = "test/menu-cancel-selected.png", width = 56, height = 40 },
          pressed = { image = "test/menu-cancel-pressed.png", width = 56, height = 40 },
        },
      },
    },
  }
end

-- Every migrated interface resolves its real plans across the matrix:
-- canonical single panes fullscreen or auxiliary, static frames on
-- wide/tall, matched input keys, and no window on fullscreen cases.
function T.all_interfaces_resolve_matched_geometry_across_matrix(scope)
  local _ = scope
  local startMenu = StartMenuInterface.defaults()
  local party = PartyScreenInterface.defaults(matrixPartyManifest())
  local card = TrainerCardInterface.defaults()
  local partyView = { cancellable = true, cursorNode = 0 }
  local singleMeasured = singleDisplay(640, 480)
  local menuPlan = startMenu.nativeLike(contextFor(singleMeasured, "nativeLike", startMenu), {})
  Assert.equal(#menuPlan.panes, 1, "native-like start menu shows its single body")
  local untypedMenu = menuPlan --[[@as table<string, unknown>]]
  Assert.isNil(untypedMenu.fadeCoverage, "fullscreen names no transition region")

  local partyPlan = party.nativeLike(contextFor(singleMeasured, "nativeLike", party), partyView)
  Assert.equal(#partyPlan.panes, 1, "native-like party shows its single compact pane")
  Assert.equal(partyPlan.inputKey, "party", "the party plan names its input geometry")

  local cardPlan = card.nativeLike(contextFor(singleMeasured, "nativeLike", card), {})
  Assert.equal(#cardPlan.panes, 1, "native-like card shows its single surface")

  local wideMeasured = singleDisplay(1280, 720)
  local wideMenu = startMenu.wide(contextFor(wideMeasured, "wide", startMenu), {})
  Assert.equal(#wideMenu.frames, 1, "wide frames the start menu in a static box")
  local untypedWide = wideMenu --[[@as table<string, unknown>]]
  Assert.isNil(untypedWide.fadeCoverage, "a static frame owns no transition region")
  local wideParty = party.wide(contextFor(wideMeasured, "wide", party), partyView)
  Assert.equal(#wideParty.frames, 1, "wide frames the party in a static box")
  local wideCard = card.wide(contextFor(wideMeasured, "wide", card), {})
  Assert.equal(#wideCard.frames, 1, "wide frames the card in a static box")

  local tallMeasured = singleDisplay(390, 844)
  Assert.equal(
    #startMenu.tall(contextFor(tallMeasured, "tall", startMenu), {}).frames,
    1,
    "tall frames the start menu in a static box"
  )

  local dualMeasured = translatedPair()
  local dualMenu = startMenu.dualDisplay(contextFor(dualMeasured, "dualDisplay", startMenu), {})
  Assert.isTrue(#dualMenu.panes >= 1, "dual display resolves the start menu")
  local dualParty = party.dualDisplay(contextFor(dualMeasured, "dualDisplay", party), partyView)
  Assert.equal(#dualParty.panes, 2, "dual display pairs detail with interaction")
  Assert.equal(dualParty.panes[1].id, "detail", "the upper pane carries detail")
  Assert.equal(dualParty.panes[2].id, "content", "the lower pane carries interaction")
  local dualFrame = dualParty.panes[2].placement.frame
  Assert.isTrue(
    dualFrame.x >= 100 and dualFrame.x + dualFrame.width <= 356,
    "the dual party must stay inside the auxiliary surface"
  )
end

-- The Bag pairs hero and interaction at one shared integer scale with no
-- synthetic gap and one frame around the common envelope; native-like
-- collapses to interaction with its description fallback content.
function T.bag_pairs_share_scale_with_no_gap(scope)
  local _ = scope
  local tabs = {}
  for index = 0, 7 do
    tabs[index + 1] = { x = index * 32, y = 0, width = 32, height = 32 }
  end
  local slots = {}
  for index = 1, 6 do
    slots[index] = { rect = { x = 0, y = 32 + (index - 1) * 24, width = 128, height = 22 } }
  end
  local manifest = {
    interactive = {
      pocketTabs = { rects = tabs },
      itemSlots = { slots = slots },
      cancel = { rect = { x = 192, y = 168, width = 64, height = 24 } },
      overlays = {
        descriptionFallback = {
          frame = { x = 0, y = 144, width = 256, height = 48 },
          textRect = { x = 20, y = 144, width = 236, height = 48 },
        },
      },
    },
  }
  local bag = BagInterface.defaults(manifest)
  local wide = bag.wide(contextFor(singleDisplay(1280, 720), "wide", bag), {})
  Assert.equal(#wide.panes, 2, "wide pairs hero with interaction")
  Assert.equal(
    wide.panes[1].placement.pixelScale,
    wide.panes[2].placement.pixelScale,
    "paired bag panes must share one integer scale"
  )
  Assert.near(
    wide.panes[1].placement.frame.x + wide.panes[1].placement.frame.width,
    wide.panes[2].placement.frame.x,
    1e-6,
    "paired bag panes touch with no gap"
  )
  Assert.equal(#wide.frames, 1, "the pair carries one frame around its envelope")
  local tall = bag.tall(contextFor(singleDisplay(390, 844), "tall", bag), {})
  Assert.equal(#tall.panes, 2, "tall stacks hero above interaction")
  Assert.equal(
    tall.panes[1].placement.pixelScale,
    tall.panes[2].placement.pixelScale,
    "stacked bag panes must share one integer scale"
  )
  Assert.near(
    tall.panes[1].placement.frame.y + tall.panes[1].placement.frame.height,
    tall.panes[2].placement.frame.y,
    1e-6,
    "stacked bag panes touch with no gap"
  )
  Assert.equal(#tall.frames, 1, "the stacked pair carries one frame around its envelope")
  local native = bag.nativeLike(contextFor(singleDisplay(640, 480), "nativeLike", bag), {})
  Assert.equal(#native.panes, 1, "native-like bag shows only interaction")
  Assert.notNil(native.content.descriptionFallback, "lower-only bag must carry its description fallback")
end

local function iconCache()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:writeLua(MonCache.iconManifestPath(), {
    schema = MonCache.ICON_MANIFEST_SCHEMA,
    version = { id = "heartgold", language = "english" },
    pages = {
      [0] = { pageId = 0, image = MonCache.iconPagePath(0), width = 256, height = 128 },
    },
    pageIds = { 0 },
    entries = {
      ["MON0/f0"] = {
        x = 0,
        y = 0,
        width = 32,
        height = 32,
        frames = { { x = 0, y = 0, width = 32, height = 32, duration = 1 } },
        pageId = 0,
      },
    },
    representative = { "MON0/f0" },
  })
  local pixels = {}
  for _ = 1, 64 * 64 do
    pixels[#pixels + 1] = string.char(200, 40, 40, 255)
  end
  cache:write(MonCache.iconPagePath(0), PngWriter.encode(64, 64, table.concat(pixels)))
  return cache
end

local function decodingQueue(cache)
  local nextToken = 0
  local live = {}
  local queue = {}
  function queue:request(kind, path, priority)
    assert(kind == "image", "icon pages decode as images")
    assert(priority == "demand", "visible party pages decode as demand")
    nextToken = nextToken + 1
    live[nextToken] = path
    return nextToken
  end
  function queue:poll(token)
    assert(live[token], "poll observes a live token")
    return "ready"
  end
  function queue:take(token)
    local path = assert(live[token], "take transfers a live token once")
    live[token] = nil
    local bytes = assert(cache:read(path), "the compiled icon page is present")
    local fileData = assert(love.filesystem.newFileData(bytes, "icon-page.png"), "page bytes form a file")
    return { imageData = assert(love.image.newImageData(fileData), "page bytes decode") }
  end
  function queue:cancel(token)
    live[token] = nil
  end
  return queue
end

local function readyDerivedAssets()
  return {
    requestIconPage = function(pageId, _)
      assert(type(pageId) == "number", "icon demand carries its page")
      return true
    end,
  }
end

local function preparedProvider(cache, keys)
  local provider = MonIconAssetProvider.new(cache, {
    preparationQueue = decodingQueue(cache),
    derivedAssets = readyDerivedAssets(),
  })
  local ready, failure
  for _ = 1, 8 do
    ready, failure = provider:prepareKeys(keys)
    if ready or failure ~= nil then
      break
    end
  end
  Assert.isTrue(ready, "demanded icon pages prepare: " .. tostring(failure))
  return provider
end

-- Synthetic party asset cache: the matrix manifest paths resolve to
-- stub art so geometry (not generated pixels) is under test; generated
-- pixels are covered against the canonical cache in the dedicated party
-- graphics smoke.
local function partyAssetCache()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  FieldUiFixture.writeFont(cache, 4)
  local function stub(path, width, height, r, g, b, a)
    local pixels = {}
    for _ = 1, width * height do
      pixels[#pixels + 1] = string.char(r, g, b, a or 255)
    end
    cache:write(path, PngWriter.encode(width, height, table.concat(pixels)))
  end
  stub("test/panel.png", 128, 48, 40, 40, 56)
  stub("test/panel-selected.png", 128, 48, 56, 40, 40)
  stub("test/panel-fainted.png", 128, 48, 32, 32, 48)
  stub("test/panel-selected-fainted.png", 128, 48, 48, 32, 32)
  stub("test/panel-switch-selection.png", 128, 48, 32, 48, 64)
  stub("test/aux.png", 128, 48, 32, 48, 48)
  stub("test/backdrop-main.png", 256, 256, 24, 64, 72)
  stub("test/backdrop-sub.png", 256, 256, 64, 72, 24)
  stub("test/detail-sub.png", 256, 256, 72, 24, 64)
  stub("test/ball.png", 32, 32, 60, 60, 80)
  stub("test/held.png", 8, 8, 200, 200, 80)
  stub("test/cursor.png", 128, 48, 0, 0, 0, 0)
  stub("test/button.png", 56, 32, 120, 120, 120)
  stub("test/button-selected.png", 56, 32, 180, 180, 180)
  stub("test/status.png", 24, 8, 240, 64, 64)
  stub("test/hp-green.png", 48, 4, 32, 200, 48)
  stub("test/hp-yellow.png", 48, 4, 220, 200, 40)
  stub("test/hp-red.png", 48, 4, 220, 48, 40)
  for digit = 0, 9 do
    stub("test/digit-" .. digit .. ".png", 8, 8, 230, 230, 230)
  end
  stub("test/level.png", 16, 8, 230, 230, 230)
  stub("test/slash.png", 8, 8, 230, 230, 230)
  stub("test/menu-standard-raised.png", 128, 32, 120, 110, 100)
  stub("test/menu-standard-selected.png", 128, 32, 90, 80, 70)
  stub("test/menu-standard-pressed.png", 128, 32, 60, 60, 60)
  stub("test/menu-cancel-raised.png", 56, 40, 120, 110, 100)
  stub("test/menu-cancel-selected.png", 56, 40, 90, 80, 70)
  stub("test/menu-cancel-pressed.png", 56, 40, 60, 60, 60)
  return cache
end

local function matrixPartyVisuals()
  local function imageRef(path, width, height)
    return { image = path, width = width or 32, height = height or 32 }
  end
  local function frameRef(path, width, height)
    return { image = path, width = width or 32, height = height or 32, offset = { x = 0, y = 0 }, durationTicks = 1 }
  end
  local digits = {}
  for digit = 0, 9 do
    digits[digit + 1] = imageRef("test/digit-" .. digit .. ".png", 8, 8)
  end
  local function sequence(path, width, height)
    return {
      frames = { frameRef(path, width, height) },
      loopFrom = 1,
      playback = "static",
    }
  end
  local visuals = {
    balls = {
      sequences = {
        sequence("test/ball.png"),
        sequence("test/ball.png"),
      },
    },
    held = {
      sequences = {
        sequence("test/held.png", 8, 8),
        sequence("test/held.png", 8, 8),
        sequence("test/held.png", 8, 8),
      },
    },
    cursor = { sequences = { sequence("test/cursor.png", 128, 48) } },
    buttons = {
      sequences = {
        sequence("test/button.png", 56, 32),
        sequence("test/button-selected.png", 56, 32),
        sequence("test/button.png", 56, 32),
        sequence("test/button.png", 56, 32),
      },
    },
    status = {
      paralysis = imageRef("test/status.png", 24, 8),
      freeze = imageRef("test/status.png", 24, 8),
      sleep = imageRef("test/status.png", 24, 8),
      poison = imageRef("test/status.png", 24, 8),
      burn = imageRef("test/status.png", 24, 8),
      faint = imageRef("test/status.png", 24, 8),
    },
    hpBars = {
      green = imageRef("test/hp-green.png", 48, 4),
      yellow = imageRef("test/hp-yellow.png", 48, 4),
      red = imageRef("test/hp-red.png", 48, 4),
    },
    backdropMain = imageRef("test/backdrop-main.png", 256, 256),
    backdropSub = imageRef("test/backdrop-sub.png", 256, 256),
    detailSub = imageRef("test/detail-sub.png", 256, 256),
    auxPanel = imageRef("test/aux.png", 128, 48),
  }
  return visuals, digits
end

-- Party readability through the real renderer and borrowed fixture text:
-- occupied cards carry name ink and the HP bar at 1x, and the doubled
-- density paints the same cards at exactly twice the frame.
function T.party_cards_stay_readable_across_densities(scope)
  local lg = love.graphics
  local text = scope:own(FieldTextRenderer.new({ cacheFs = FieldUiFixture.cacheWithFontAndFrames() }))
  local provider = preparedProvider(iconCache(), { "MON0/f0" })
  local cacheFs = partyAssetCache()
  local manifest = matrixPartyManifest()
  local visuals, digits = matrixPartyVisuals()
  manifest.visuals = visuals
  manifest.numberGlyphs = {
    advance = 8,
    height = 8,
    digits = digits,
    level = { image = "test/level.png", width = 16, height = 8 },
    slash = { image = "test/slash.png", width = 8, height = 8 },
    placement = PartyPresentationFixture.manifest().numberGlyphs.placement,
  }
  local renderer = PartyScreenRenderer.new({ graphics = lg, cacheFs = cacheFs, manifest = manifest, text = text })
  local function slots()
    local list = {}
    for slot0 = 0, 1 do
      list[#list + 1] = {
        slot = slot0,
        occupied = true,
        eligible = true,
        iconKey = "MON0/f0",
        displayName = "MON" .. slot0,
        level = 5,
        gender = "male",
        status = "ok",
        currentHp = 20,
        maxHp = 20,
        hpFraction = 1,
      }
    end
    for slot0 = 2, 5 do
      list[#list + 1] = { slot = slot0, occupied = false, eligible = false }
    end
    return list
  end
  local function presentation()
    local status = {
      open = true,
      mode = "view",
      action = "browsing",
      state = "browse",
      cursorNode = 0,
      switchSource = nil,
      actionSelection = nil,
      anim = { tick = 0, sequences = {}, sequenceTicks = {}, panelSlide = 0 },
      view = { revision = 1, slots = slots() },
      cancellable = true,
    }
    for index = 1, 6 do
      status.anim.sequences[index] = 1
      status.anim.sequenceTicks[index] = 0
    end
    return status
  end
  local party = PartyScreenInterface.defaults(matrixPartyManifest())
  local view = { cancellable = true, cursorNode = 0 }
  for _, host in ipairs({ { width = 320, height = 240 }, { width = 640, height = 480 } }) do
    local label = host.width .. "x" .. host.height
    local plan = party.nativeLike(contextFor(singleDisplay(host.width, host.height), "nativeLike", party), view)
    local placement = interactivePane(plan)
    local canvas = renderToCanvas(scope, host.width, host.height, function()
      LogicalSurface.draw(lg, placement, function()
        renderer:draw(presentation(), plan, provider)
      end)
    end)
    local data = scope:own(canvas:newImageData())
    local function inkCount(x0, y0, x1, y1)
      local count = 0
      for y = y0, y1 do
        for x = x0, x1 do
          local r, g, b, a = data:getPixel(x, y)
          if a > 0.5 and math.max(r, g, b) < 0.9 then
            count = count + 1
          end
        end
      end
      return count
    end
    -- First panel origin (0,0) logical: name ink sits right of the
    -- icon region and the HP bar paints at the panel foot, at either
    -- density.
    local fx, fy = placement.frame.x, placement.frame.y
    local scale = placement.pixelScale
    Assert.isTrue(
      inkCount(
        math.floor(fx + 48 * scale),
        math.floor(fy + 8 * scale),
        math.floor(fx + 120 * scale),
        math.floor(fy + 24 * scale)
      ) > 0,
      label .. ": the occupied card must carry name ink"
    )
    Assert.isTrue(
      inkCount(
        math.floor(fx + 64 * scale),
        math.floor(fy + 24 * scale),
        math.floor(fx + 112 * scale),
        math.floor(fy + 32 * scale)
      ) > 0,
      label .. ": the occupied card must paint its HP bar"
    )
  end
  provider:release()
end

-- The machine-derived starter pane lands on whole host pixels through
-- the resolved placement: the machine surface and the selected portrait
-- each paint inside their source rectangles and nowhere else.
function T.starter_machine_regions_match_locked_geometry(scope)
  local lg = love.graphics
  local starter = StarterChoiceInterface.defaults()
  local view = { selection = 0, selectionState = "inspect", transition = "idle", done = false }
  local plan = starter.nativeLike(contextFor(singleDisplay(640, 480), "nativeLike", starter), view)
  Assert.equal(#plan.panes, 1, "machine choice shows its single pane")
  Assert.equal(plan.inputKey, "starter", "the machine plan names its input geometry")
  local placement = assert(plan.panes[1], "the machine plan carries its pane").placement
  local canvas = renderToCanvas(scope, 640, 480, function()
    LogicalSurface.draw(lg, placement, function()
      lg.setColor(0.9, 0.2, 0.2, 1)
      lg.rectangle("fill", 0, 0, 256, 192)
      lg.setColor(0.2, 0.9, 0.2, 1)
      lg.rectangle("fill", 88, 56, 80, 80)
    end)
  end)
  local data = scope:own(canvas:newImageData())
  local function hostOf(lx, ly)
    return LayoutGeometry.logicalToHost(placement, lx, ly)
  end
  local mx, my = hostOf(16, 150)
  assertPixelNear(
    data,
    math.floor(mx),
    math.floor(my),
    0.9,
    0.2,
    0.2,
    1,
    "the machine surface paints through the machine placement"
  )
  local px, py = hostOf(88 + 40, 56 + 40)
  assertPixelNear(
    data,
    math.floor(px),
    math.floor(py),
    0.2,
    0.9,
    0.2,
    1,
    "the portrait region paints through the machine placement"
  )
  -- Between the regions the canvas keeps the machine surface.
  local gx, gy = hostOf(120, 150)
  assertPixelNear(data, math.floor(gx), math.floor(gy), 0.9, 0.2, 0.2, 1, "between regions keeps the surface")
end

-- Hosted naming magnifies exactly once: the same canonical child through
-- 1x and 2x placements doubles its pixels with identical logical
-- content, and no parent scale multiplies the output.
function T.hosted_naming_magnifies_once_across_densities(scope)
  local lg = love.graphics
  local naming = NamingInterface.defaults()
  local one = naming.nativeLike(contextFor(singleDisplay(320, 240), "nativeLike", naming), {})
  local two = naming.nativeLike(contextFor(singleDisplay(640, 480), "nativeLike", naming), {})
  local onePlacement = assert(one.panes[1], "the 1x naming plan carries its pane").placement
  local twoPlacement = assert(two.panes[1], "the 2x naming plan carries its pane").placement
  Assert.equal(onePlacement.logicalWidth, 256, "the child stays canonical at 1x")
  Assert.equal(twoPlacement.logicalWidth, 256, "the child stays canonical at 2x")
  Assert.equal(twoPlacement.pixelScale, 2, "the denser host must use the doubled scale")
  Assert.deepEqual(one.frames, {}, "native-like naming publishes no outer frame")
  Assert.deepEqual(two.frames, {}, "denser native-like naming publishes no outer frame")
  local wideNaming = naming.wide(contextFor(singleDisplay(1280, 720), "wide", naming), {})
  Assert.equal(#wideNaming.panes, 1, "wide naming keeps one canonical pane")
  Assert.equal(wideNaming.panes[1].placement.logicalWidth, 256, "the wide naming child stays canonical")
  Assert.deepEqual(wideNaming.frames, {}, "wide naming publishes no outer frame")
  Assert.deepEqual(
    one.content.layout.surface,
    two.content.layout.surface,
    "both densities must share the identical canonical child"
  )
  local function drawAt(placement, width, height)
    return renderToCanvas(scope, width, height, function()
      LogicalSurface.draw(lg, placement, function()
        lg.setColor(0.7, 0.7, 0.1, 1)
        lg.rectangle("fill", 0, 0, 256, 192)
      end)
    end)
  end
  local firstData = scope:own(drawAt(onePlacement, 320, 240):newImageData())
  local secondData = scope:own(drawAt(twoPlacement, 640, 480):newImageData())
  local x1, y1 = LayoutGeometry.logicalToHost(onePlacement, 100, 100)
  local x2, y2 = LayoutGeometry.logicalToHost(twoPlacement, 100, 100)
  assertPixelNear(firstData, math.floor(x1), math.floor(y1), 0.7, 0.7, 0.1, 1, "1x child paints")
  assertPixelNear(secondData, math.floor(x2), math.floor(y2), 0.7, 0.7, 0.1, 1, "2x child paints")
  Assert.equal(math.floor(x2), math.floor(x1) * 2, "one output scale doubles the columns")
end

-- The Trainer Card near fit never mixes crop with chrome: 750x560 misses
-- fullscreen, so the card refits as an uncropped decorated box whose
-- complete surface keeps the guarded text rect fully visible.
function T.trainer_crop_protects_text_bounds(scope)
  local _ = scope
  local card = TrainerCardInterface.defaults()
  local plan = card.nativeLike(contextFor(singleDisplay(750, 560), "nativeLike", card), {})
  local placement = assert(plan.panes[1], "the card plan carries its pane").placement
  Assert.equal(placement.pixelScale, 2, "750x560 must use the decorated 2x")
  Assert.deepEqual(
    placement.crop or { left = 0, right = 0, top = 0, bottom = 0 },
    { left = 0, right = 0, top = 0, bottom = 0 },
    "a visible frame never coexists with body crop"
  )
  local visible = assert(placement.visibleLogicalRect, "the decorated placement names its visible area")
  Assert.deepEqual(
    visible,
    { x = 0, y = 0, width = 256, height = 192 },
    "the decorated body keeps every source pixel visible"
  )
  Assert.isTrue(visible.x <= 8 and visible.y <= 8, "the visible area must start at or before the protected rect")
  Assert.isTrue(
    visible.x + visible.width >= 248 and visible.y + visible.height >= 184,
    "the visible area must cover the protected rect"
  )
  Assert.equal(#plan.frames, 1, "the underfilled card carries its complete frame")
end

-- The responsive startup menu grows its logical viewport with density
-- instead of multiplying inner metrics: placements at 640x480 and
-- 1280x720 share one root transform each.
function T.main_menu_viewport_grows_with_density(scope)
  local _ = scope
  local menu = MainMenuInterface.defaults()
  local view = {
    globalActions = { { id = "new-game", kind = "new_game" } },
    saves = { cards = {} },
    focus = { region = "global", actionId = "new-game" },
  }
  local small = menu.nativeLike(contextFor(singleDisplay(640, 480), "nativeLike", menu), view)
  local large = menu.nativeLike(contextFor(singleDisplay(1280, 720), "nativeLike", menu), view)
  local smallPlacement = assert(small.panes[1], "the small menu carries its pane").placement
  local largePlacement = assert(large.panes[1], "the large menu carries its pane").placement
  Assert.equal(smallPlacement.pixelScale, 2, "640x480 must use the doubled density")
  Assert.equal(largePlacement.pixelScale, 3, "1280x720 must respect the triple cap")
  Assert.isTrue(
    largePlacement.logicalWidth >= smallPlacement.logicalWidth,
    "a larger host must not shrink the logical viewport"
  )
  Assert.isNil(small.content.layout.uiScale, "the small layout must carry no presentation scale")
  Assert.isNil(large.content.layout.uiScale, "the large layout must carry no presentation scale")
end

function T.launcher_and_editor_keep_native_pixels_on_a_small_host(scope)
  local _ = scope
  local menu = MainMenuInterface.defaults()
  local menuView = {
    globalActions = { { id = "new-game", kind = "new_game" } },
    saves = { cards = {} },
    focus = { region = "global", actionId = "new-game" },
  }
  local editor = SaveEditorInterface.defaults()
  local editorView = {
    status = "opening",
    message = "Preparing save editor",
    section = "Player",
    scope = { id = "section:Player", epoch = 0 },
    textMetrics = {
      lineHeight = 12,
      measure = function(text)
        return #text * 6
      end,
    },
  }
  for _, host in ipairs({
    { width = 200, height = 150, pixelRatio = 1 },
    { width = 200, height = 150, pixelRatio = 2 },
    { width = 128, height = 96, pixelRatio = 1 },
    { width = 128, height = 96, pixelRatio = 2 },
  }) do
    local measured = singleDisplay(host.width, host.height, host.pixelRatio)
    local label = string.format("%dx%d@%dx", host.width, host.height, host.pixelRatio)
    local menuPlan = menu.nativeLike(contextFor(measured, "nativeLike", menu), menuView)
    local menuPane = assert(menuPlan.panes[1], label .. " startup menu remains available")
    local newGame = assert(menuPlan.content.layout.global.actions["new-game"], label .. " New Game is visible")
    local menuHit = menuPlan.mapInput({
      type = "pointer_down",
      x = newGame.x + newGame.width / 2,
      y = newGame.y + newGame.height / 2,
    }, menuView, menuPlan)
    Assert.equal(menuHit.actionId, "new-game", label .. " New Game remains pointer reachable")
    Assert.equal(menuPane.placement.pixelScale, 1, label .. " startup menu keeps native pixels")
    Assert.equal(menuPane.placement.scale, 1 / host.pixelRatio, label .. " host scale reflects the pixel ratio once")
    Assert.equal(
      menuPlan.content.width,
      host.width * host.pixelRatio,
      label .. " menu reflows to physical visible width"
    )
    Assert.equal(
      menuPlan.content.height,
      host.height * host.pixelRatio,
      label .. " menu reflows to physical visible height"
    )
    Assert.isNil(
      menuPlan.mapInput({ type = "pointer_down", x = menuPlan.content.width + 1, y = newGame.y }, menuView, menuPlan),
      label .. " menu has no offscreen hit target"
    )

    local editorPlan = editor.nativeLike(contextFor(measured, "nativeLike", editor), editorView)
    local editorPane = assert(editorPlan.panes[1], label .. " save editor remains available")
    local section = assert(editorPlan.content.layout.targets["section:Player"], label .. " Player remains visible")
    local sectionRect = assert(section.rect)
    local sectionHit = editorPlan.mapInput({
      type = "pointer_down",
      x = sectionRect.x + sectionRect.width / 2,
      y = sectionRect.y + sectionRect.height / 2,
    }, editorView, editorPlan)
    Assert.equal(sectionHit.targetId, "section:Player", label .. " Player remains pointer reachable")
    Assert.equal(editorPane.placement.pixelScale, 1, label .. " save editor keeps native pixels")
    Assert.equal(editorPane.placement.scale, 1 / host.pixelRatio, label .. " editor host scale reflects DPI once")
    Assert.equal(
      editorPlan.content.width,
      host.width * host.pixelRatio,
      label .. " editor reflows to physical visible width"
    )
    Assert.equal(
      editorPlan.content.height,
      host.height * host.pixelRatio,
      label .. " editor reflows to physical visible height"
    )
    Assert.isNil(
      editorPlan.mapInput(
        { type = "pointer_down", x = editorPlan.content.width + 1, y = sectionRect.y },
        editorView,
        editorPlan
      ).targetId,
      label .. " editor has no offscreen hit target"
    )
  end
end

-- Plan drawing through the shared dispatcher restores borrowed graphics
-- state and paints content through each migrated case.
function T.plan_draw_restores_state_for_every_case(scope)
  local lg = love.graphics
  local startMenu = StartMenuInterface.defaults()
  local cases = {
    { name = "nativeLike", measured = singleDisplay(640, 480) },
    { name = "wide", measured = singleDisplay(1280, 720) },
  }
  for _, host in ipairs(cases) do
    local plan = startMenu[host.name](contextFor(host.measured, host.name, startMenu), {})
    local body = interactivePane(plan)
    plan.render = function()
      LogicalSurface.draw(lg, body, paintSolid({ 0.4, 0.4, 0.9, 1 }, 256, 192))
    end
    local before = captureState(lg)
    local canvas = renderToCanvas(scope, host.measured.width, host.measured.height, function()
      -- The dispatcher borrows resource records; an empty record proves
      -- no acquisition path hides inside the callback boundary.
      ApplicationPresentation.draw(lg, {}, {}, plan)
    end)
    assertStateRestored(before, lg, host.name .. " draw")
    local data = scope:own(canvas:newImageData())
    local hx, hy = LayoutGeometry.logicalToHost(body, 200, 100)
    assertPixelNear(
      data,
      math.floor(hx),
      math.floor(hy),
      0.4,
      0.4,
      0.9,
      1,
      host.name .. " content paints through its plan"
    )
  end
end

-- The rectangular body never bleeds through exterior side transparency:
-- side-band pixels where the selected frame is transparent reveal the
-- already-rendered field, never body ink, while the body stays fully
-- painted from its own origin. Probe columns derive from the published
-- exterior insets, so they track the side bands whatever room the
-- geometry reserves. The test-local strip clears the sampled left-band
-- window (tile 6 cols 2-7 plus tile 7 cols 0-1) in both rows; the shared
-- solid-tile fixture stays untouched so dialogue goldens keep their
-- opaque side columns.
local function stripWithTransparentSideTile()
  local rows = {}
  for frame = 0, FieldUiFixture.FRAME_COUNT - 1 do
    local bytes = { FieldUiFixture.framePixels(frame):byte(1, -1) }
    for ty = 0, 7 do
      for tx = 2, 9 do
        local offset = (ty * 144 + 6 * 8 + tx) * 4
        bytes[offset + 1], bytes[offset + 2], bytes[offset + 3], bytes[offset + 4] = 0, 0, 0, 0
      end
    end
    local cells = {}
    for index = 1, #bytes do
      cells[index] = string.char(bytes[index])
    end
    rows[#rows + 1] = table.concat(cells)
  end
  return PngWriter.encode(144, FieldUiFixture.FRAME_COUNT * 8, table.concat(rows))
end

function T.application_body_never_bleeds_through_exterior_transparency(scope)
  local FieldDialogueTheme = require("libs.hgss.src.ui.FieldDialogueTheme")
  local FieldWindowRenderer = require("libs.hgss.src.ui.FieldWindowRenderer")
  local insets = FieldDialogueTheme.applicationFrameInsets()
  local FIELD = { 0.2, 0.5, 0.9, 1 }
  local BODY = { 0.9, 0.7, 0.1, 1 }
  for _, density in ipairs({ 1, 2 }) do
    for _, frameIndex in ipairs({ 0, 1 }) do
      local tag = density .. "x style " .. frameIndex
      local box = { x = 16, y = 32, width = 64, height = 64 }
      local cache = FieldUiFixture.cacheWithFontAndFrames()
      cache:write(FieldUiFixture.STRIP_PATH, stripWithTransparentSideTile())
      local window = scope:own(FieldWindowRenderer.new({
        cacheFs = cache,
        manifest = FieldUiFixture.manifest(),
      }))
      local canvasWidth, canvasHeight = 128 * density, 160 * density
      local function render(fieldFill, bodyFill)
        return renderToCanvas(scope, canvasWidth, canvasHeight, function()
          local lg = love.graphics
          lg.push("all")
          lg.scale(density, density)
          if fieldFill then
            lg.setColor(FIELD[1], FIELD[2], FIELD[3], FIELD[4])
            lg.rectangle("fill", 0, 0, 128, 160)
          end
          if bodyFill then
            lg.setColor(BODY[1], BODY[2], BODY[3], BODY[4])
            lg.rectangle("fill", box.x, box.y, box.width, box.height)
          end
          window:drawApplicationFrame(box, frameIndex)
          lg.pop()
        end)
      end
      -- Transparent side-band cells, located by scanning the frame-alone
      -- render across both side bands derived from the published insets.
      local bare = scope:own(render(false, false):newImageData())
      local probes = {}
      local bandX = {}
      for i = 0, insets.left - 1 do
        bandX[#bandX + 1] = box.x - insets.left + i
      end
      for i = 0, insets.right - 1 do
        bandX[#bandX + 1] = box.x + box.width + i
      end
      for _, lx in ipairs(bandX) do
        for ly = box.y, box.y + box.height - 1 do
          local _, _, _, a = bare:getPixel(lx * density, ly * density)
          if a < 0.5 then
            probes[#probes + 1] = { x = lx, y = ly }
          end
        end
      end
      Assert.isTrue(#probes > 0, tag .. ": the side bands carry transparent frame cells")
      local data = scope:own(render(true, true):newImageData())
      for _, probe in ipairs(probes) do
        local r, g, b, a = data:getPixel(probe.x * density, probe.y * density)
        Assert.near(r, FIELD[1], 1e-2, tag .. " exterior red at " .. probe.x .. "," .. probe.y)
        Assert.near(g, FIELD[2], 1e-2, tag .. " exterior green at " .. probe.x .. "," .. probe.y)
        Assert.near(b, FIELD[3], 1e-2, tag .. " exterior blue at " .. probe.x .. "," .. probe.y)
        Assert.near(a, FIELD[4], 1e-2, tag .. " exterior alpha at " .. probe.x .. "," .. probe.y)
      end
      local function assertBody(lx, ly, label)
        local r, g, b, a = data:getPixel(lx * density, ly * density)
        Assert.near(r, BODY[1], 1e-2, tag .. " " .. label .. " red")
        Assert.near(g, BODY[2], 1e-2, tag .. " " .. label .. " green")
        Assert.near(b, BODY[3], 1e-2, tag .. " " .. label .. " blue")
        Assert.near(a, BODY[4], 1e-2, tag .. " " .. label .. " alpha")
      end
      assertBody(box.x + 32, box.y + 32, "the body center stays fully painted")
      assertBody(box.x + 1, box.y + 1, "body ink starts at the body origin")
    end
  end
end

-- Framed applications render only their selected borders: production
-- frame composition for one closable field application and for the
-- blocking starter choice matches a direct selected-border draw for the
-- same frame body and index, with no extra title or control ink, at a
-- wide host and at more than one integer scale.
function T.framed_applications_render_only_their_selected_borders(scope)
  local lg = love.graphics
  local FieldPresentationResources = require("game.hgss.src.field.FieldPresentationResources")
  local FieldWindowRenderer = require("libs.hgss.src.ui.FieldWindowRenderer")
  local StarterChoicePresentation = require("game.hgss.src.starters.StarterChoicePresentation")
  local startMenu = StartMenuInterface.defaults()
  local starter = StarterChoiceInterface.defaults()
  local starterView = { selection = 0, selectionState = "null", transition = "idle", done = false }
  local wideMeasured = singleDisplay(1280, 720)
  local menuPlan = startMenu.wide(contextFor(wideMeasured, "wide", startMenu), {})
  local starterPlan = starter.wide(contextFor(wideMeasured, "wide", starter), starterView)
  Assert.isTrue(#menuPlan.frames >= 1, "the wide menu must publish its outer frame")
  Assert.isTrue(#starterPlan.frames >= 1, "the wide starter choice must publish its outer frame")
  menuPlan.render = function()
    lg.setColor(1, 0, 1, 1)
    lg.rectangle("fill", 0, 0, wideMeasured.width, wideMeasured.height)
  end
  local cacheFs = FieldUiFixture.cacheWithFontAndFrames()
  local window = scope:own(FieldWindowRenderer.new({ cacheFs = cacheFs, manifest = FieldUiFixture.manifest() }))
  local text = FieldTextRenderer.new({ cacheFs = cacheFs })
  local resources = setmetatable({
    windowRenderer = window,
    textRenderer = text,
    applicationFrameIndex = 0,
    startMenuRenderer = {},
  }, FieldPresentationResources)
  local starterPresentation = setmetatable({ _frameIndex = 0 }, StarterChoicePresentation)

  local function frameBounds(frames)
    local minX, minY = math.huge, math.huge
    local maxX, maxY = -math.huge, -math.huge
    for _, frame in ipairs(frames) do
      local outer = assert(frame.placement, "the frame carries its placement").frame
      minX = math.min(minX, outer.x)
      minY = math.min(minY, outer.y)
      maxX = math.max(maxX, outer.x + outer.width)
      maxY = math.max(maxY, outer.y + outer.height)
    end
    local x0 = math.max(0, math.floor(minX) - 2)
    local y0 = math.max(0, math.floor(minY) - 2)
    -- Even host origins keep every sampled canvas pixel integral at 1x/2x.
    return {
      x0 = x0 - (x0 % 2),
      y0 = y0 - (y0 % 2),
      x1 = math.min(wideMeasured.width, math.ceil(maxX) + 2),
      y1 = math.min(wideMeasured.height, math.ceil(maxY) + 2),
    }
  end

  local function pixelDiffers(data, hx, hy, backdrop)
    local r, g, b, a = data:getPixel(hx, hy)
    return math.abs(r - backdrop[1]) + math.abs(g - backdrop[2]) + math.abs(b - backdrop[3]) + math.abs(a - backdrop[4])
      > 0.05
  end

  local function compareRenders(directData, productionData, bounds, density, backdrop)
    local changed, ink = 0, 0
    local y = bounds.y0
    while y < bounds.y1 do
      local x = bounds.x0
      while x < bounds.x1 do
        local hx, hy = math.floor(x * density), math.floor(y * density)
        local r0, g0, b0, a0 = directData:getPixel(hx, hy)
        local r1, g1, b1, a1 = productionData:getPixel(hx, hy)
        if math.abs(r1 - r0) + math.abs(g1 - g0) + math.abs(b1 - b0) + math.abs(a1 - a0) > 0.05 then
          changed = changed + 1
        end
        if pixelDiffers(productionData, hx, hy, backdrop) then
          ink = ink + 1
        end
        x = x + 2
      end
      y = y + 2
    end
    return changed, ink
  end

  local menuBounds = frameBounds(menuPlan.frames)
  local starterBounds = frameBounds(starterPlan.frames)
  for _, density in ipairs({ 1, 2 }) do
    local tag = density .. "x"
    local canvasWidth, canvasHeight = wideMeasured.width * density, wideMeasured.height * density
    local productionField = renderToCanvas(scope, canvasWidth, canvasHeight, function()
      lg.push("all")
      lg.scale(density, density)
      resources:drawStartMenu({ presentation = menuPlan }, lg)
      lg.pop()
    end)
    local directField = renderToCanvas(scope, canvasWidth, canvasHeight, function()
      lg.push("all")
      lg.scale(density, density)
      ApplicationPresentation.draw(lg, {}, {}, menuPlan)
      for _, frame in ipairs(menuPlan.frames) do
        LogicalSurface.draw(lg, frame.placement, function()
          window:drawApplicationFrame(frame.contentBox, 0)
        end)
      end
      lg.pop()
    end)
    local productionStarter = renderToCanvas(scope, canvasWidth, canvasHeight, function()
      lg.push("all")
      lg.scale(density, density)
      starterPresentation:_drawOuterFrames(lg, starterPlan, window)
      lg.pop()
    end)
    local directStarter = renderToCanvas(scope, canvasWidth, canvasHeight, function()
      lg.push("all")
      lg.scale(density, density)
      for _, frame in ipairs(starterPlan.frames) do
        LogicalSurface.draw(lg, frame.placement, function()
          window:drawApplicationFrame(frame.contentBox, 0)
        end)
      end
      lg.pop()
    end)
    local productionFieldData = scope:own(productionField:newImageData())
    local directFieldData = scope:own(directField:newImageData())
    local productionStarterData = scope:own(productionStarter:newImageData())
    local directStarterData = scope:own(directStarter:newImageData())
    local fieldChanged, fieldInk =
      compareRenders(directFieldData, productionFieldData, menuBounds, density, { 1, 0, 1, 1 })
    Assert.isTrue(fieldInk > 50, tag .. ": production menu framing draws border ink over the fill")
    Assert.equal(fieldChanged, 0, tag .. ": production menu framing adds no title or control ink")
    local starterChanged, starterInk =
      compareRenders(directStarterData, productionStarterData, starterBounds, density, { 0, 0, 0, 0 })
    Assert.isTrue(starterInk > 50, tag .. ": production starter framing draws border ink")
    Assert.equal(starterChanged, 0, tag .. ": production starter framing adds no title ink")
  end
end

-- Undecorated surfaces publish no outer frame: Oak naming and the
-- startup main menu resolve frame-free plans at any density.
function T.undecorated_surfaces_publish_no_outer_frame(scope)
  local _ = scope
  local naming = NamingInterface.defaults()
  local menu = MainMenuInterface.defaults()
  local menuView = {
    globalActions = { { id = "new-game", kind = "new_game" } },
    saves = { cards = {} },
    focus = { region = "global", actionId = "new-game" },
  }
  for _, host in ipairs({ singleDisplay(320, 240), singleDisplay(1280, 720) }) do
    local label = host.width .. "x" .. host.height
    local namingPlan = naming.nativeLike(contextFor(host, "nativeLike", naming), {})
    Assert.deepEqual(namingPlan.frames, {}, label .. ": naming publishes no outer frame")
    local wideNaming = naming.wide(contextFor(host, "wide", naming), {})
    Assert.deepEqual(wideNaming.frames, {}, label .. ": wide naming publishes no outer frame")
    local menuPlan = menu.nativeLike(contextFor(host, "nativeLike", menu), menuView)
    Assert.deepEqual(menuPlan.frames, {}, label .. ": the startup menu publishes no outer frame")
  end
end

return GraphicsSmoke.suite(T)
