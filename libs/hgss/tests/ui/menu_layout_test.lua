-- Pure menu-layout tests exercise deterministic list geometry across display
-- topologies without involving rendering or physical input.

local Assert = require("tests.support.Assert")
local ListSurface = require("libs.ui.src.ListSurface")
local MenuLayout = require("libs.hgss.src.ui.MenuLayout")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {}

local function rect(x, y, width, height)
  return { x = x, y = y, width = width, height = height }
end

local function topology(width, height, opts)
  opts = opts or {}
  return ScreenTopology.oneDisplay({
    id = "main",
    rect = rect(0, 0, width, height),
    safeRect = opts.safeRect,
    role = opts.role or "world",
    touch = opts.touch == true,
  })
end

local function menu(count, opts)
  opts = opts or {}
  local items = {}
  for index = 1, count do
    items[index] = { text = opts.text or "Choice" }
  end
  return {
    items = items,
    selectedIndex = opts.selectedIndex or 0,
    cancellable = opts.cancellable == true,
  }
end

local function resolve(spec)
  spec.measureText = spec.measureText or function(text)
    return #text * 8
  end
  return MenuLayout.resolve(spec)
end

-- Maps a logical rectangle through the resolved placement into host space.
local function physical(layout, logical)
  local placement = layout.placement
  return rect(
    placement.origin.x + logical.x * placement.scale,
    placement.origin.y + logical.y * placement.scale,
    logical.width * placement.scale,
    logical.height * placement.scale
  )
end

local function contains(outer, inner)
  return inner.x >= outer.x
    and inner.y >= outer.y
    and inner.x + inner.width <= outer.x + outer.width
    and inner.y + inner.height <= outer.y + outer.height
end

function T.menus_float_at_the_top_right_of_the_native_four_by_three_region()
  local layout = resolve({ topology = topology(256, 192), menu = menu(3) })

  Assert.equal(layout.placement.scale, 1)
  Assert.equal(layout.placement.origin.x, 0)
  Assert.equal(layout.placement.origin.y, 0)
  local surface = layout.listSurface.surface
  Assert.isTrue(surface.x + surface.width < 256, "the frame keeps room for its exterior border")
  Assert.isTrue(256 - (surface.x + surface.width) <= 16, "the surface hugs the right edge")
  Assert.isTrue(surface.y <= 16, "the surface hugs the top edge")
  Assert.equal(surface.width % 8, 0, "framed content stays on the dialogue tile grid")
  Assert.equal(surface.height % 8, 0, "framed content stays on the dialogue tile grid")
  Assert.equal(#layout.rows, 3)
  Assert.equal(layout.itemTexts[2], "Choice")
  Assert.isTrue(contains(layout.scrollViewport, layout.itemRects[2]))
end

function T.wide_hosts_anchor_inside_the_supplied_four_by_three_bounds()
  local bounds = rect(240, 0, 1440, 1080)
  local layout = resolve({
    topology = topology(1920, 1080),
    menu = menu(3),
    bounds = bounds,
    preferredScale = 4,
  })

  Assert.equal(layout.placement.scale, 4, "the integer field scale is honored when the region fits")
  Assert.equal(layout.placement.origin.x, bounds.x + bounds.width - 256 * 4)
  Assert.equal(layout.placement.origin.y, bounds.y)
  local box = physical(layout, layout.listSurface.surface)
  local region = rect(layout.placement.origin.x, layout.placement.origin.y, 256 * 4, 192 * 4)
  Assert.isTrue(contains(region, box))
  Assert.isTrue(region.x + region.width - (box.x + box.width) <= 16 * 4, "right-aligned in the 4:3 region")
  Assert.isTrue(box.y - region.y <= 16 * 4, "top-aligned in the 4:3 region")
end

function T.region_smaller_than_one_native_pixel_per_pixel_scales_fractionally()
  local layout = resolve({ topology = topology(128, 96), menu = menu(2), bounds = rect(0, 0, 128, 96) })
  Assert.equal(layout.placement.scale, 0.5)
end

function T.text_measurement_determines_surface_width_up_to_the_region()
  local short = resolve({ topology = topology(256, 192), menu = menu(2, { text = "Hi" }) })
  local long = resolve({ topology = topology(256, 192), menu = menu(2, { text = "A much longer label" }) })
  local huge = resolve({ topology = topology(256, 192), menu = menu(2, { text = string.rep("W", 80) }) })

  Assert.isTrue(long.listSurface.surface.width > short.listSurface.surface.width)
  Assert.isTrue(huge.listSurface.surface.x >= 8, "an over-long label never leaves the region")
end

function T.large_menus_scroll_without_overflow_and_keep_the_selected_item_visible()
  for _, selected in ipairs({ 0, 7, 19 }) do
    local layout = resolve({ topology = topology(256, 192), menu = menu(20, { selectedIndex = selected }) })
    Assert.isTrue(contains(layout.scrollViewport, layout.itemRects[selected]))
    Assert.isTrue(layout.maxScrollOffset > 0)
    Assert.isTrue(layout.listSurface.surface.y + layout.listSurface.surface.height <= 192)
    for _, row in ipairs(layout.rows) do
      Assert.isTrue(contains(layout.scrollViewport, row.marker) or selected ~= row.itemIndex)
    end
  end
end

-- The shared list presentation sizes rows from the field line height: three
-- tile rows per entry, which leaves the focus ring clear of the glyph cell
-- instead of slicing through it.
function T.list_rows_keep_the_focus_ring_off_the_label_ink()
  local layout = resolve({ topology = topology(256, 192), menu = menu(3) })

  Assert.equal(#layout.rows, 3, "every option materializes its row")
  Assert.equal(layout.itemRects[0].height, 24, "list entries keep the three-tile source row extent")
  Assert.equal(layout.maxScrollOffset, 0, "three short options need no scrolling")
  for _, row in ipairs(layout.rows) do
    Assert.isTrue(row.marker.y > row.rect.y, "the focus ring insets its row")
    Assert.isTrue(row.marker.y < row.labelRect.y, "the ring clears the label cell above")
    Assert.isTrue(
      row.marker.y + row.marker.height > row.labelRect.y + row.labelRect.height,
      "the ring clears the label cell below"
    )
    Assert.isTrue(row.marker.x < row.labelRect.x, "the ring clears the label cell on the left")
    Assert.isTrue(
      row.marker.x + row.marker.width > row.labelRect.x + row.labelRect.width,
      "the ring clears the label cell on the right"
    )
  end
end

-- The resolved surface is a padded ListSurface, so the row width the list
-- measures must reserve that padding; otherwise the widest label overflows
-- its row and the focus ring closes over the text.
function T.a_menu_reserves_its_surface_padding_so_each_label_fits_its_row()
  local widths = { BUY = 24, SELL = 32, ["SEE YA!"] = 56 }
  local layout = resolve({
    topology = topology(256, 192),
    menu = {
      items = { { text = "BUY" }, { text = "SELL" }, { text = "SEE YA!" } },
    },
    measureText = function(text)
      return widths[text] or #text * 8
    end,
  })

  for _, row in ipairs(layout.rows) do
    local label = assert(layout.itemTexts[row.itemIndex], "the resolved row carries its label")
    Assert.isTrue(row.labelRect.width >= widths[label], "row " .. row.itemIndex .. " fits its label")
  end
end

function T.touch_menus_place_the_cancel_target_inside_the_same_frame()
  local layout = resolve({
    topology = topology(256, 192, { touch = true }),
    menu = menu(3, { cancellable = true }),
  })
  local frame = layout.frameBox
  Assert.notNil(layout.cancelRect)
  Assert.equal(layout.cancelRect.height, layout.itemRects[0].height, "the cancel target shares the list row extent")
  Assert.isTrue(
    layout.cancelRect.y >= layout.scrollViewport.y + layout.scrollViewport.height,
    "the cancel target sits below the item viewport"
  )
  Assert.isTrue(
    layout.cancelRect.y + layout.cancelRect.height <= frame.y + frame.height - ListSurface.PADDING,
    "the cancel target stays inside the frame"
  )
  Assert.isTrue(frame.height > layout.listSurface.surface.height, "the frame carries the cancel row")
  Assert.equal(layout.maxScrollOffset, 0, "three options and their cancel row fit without scrolling")
  Assert.equal(frame.x, layout.listSurface.surface.x)
  Assert.equal(frame.width, layout.listSurface.surface.width)
  Assert.isNil(
    resolve({ topology = topology(256, 192), menu = menu(3, { cancellable = true }) }).cancelRect,
    "non-touch menus cancel through the input binding, not a row"
  )
end

function T.dual_screen_menus_prefer_the_auxiliary_surface()
  local dual = ScreenTopology.dualDisplay({
    id = "main",
    rect = rect(0, 0, 400, 240),
    role = "world",
    touch = false,
  }, {
    id = "secondary",
    rect = rect(412, 0, 400, 240),
    role = "auxiliary",
    touch = true,
  })
  local layout = resolve({ topology = dual, menu = menu(3) })
  Assert.equal(layout.surface.id, "secondary")
  Assert.isTrue(contains(layout.surface.safeRect, physical(layout, layout.listSurface.surface)))
end

-- One source window row pair per item: `choice` labels are measured in pixels
-- like the retail title, and a shorter label yields a narrower window.
local function multichoice(opts)
  opts = opts or {}
  local items = {}
  for index = 1, opts.count or 3 do
    items[index] = { text = opts.text or "Choice A" }
  end
  return {
    kind = "multichoice",
    tileX = opts.tileX or 12,
    tileY = opts.tileY or 8,
    anchorRight = opts.anchorRight == true,
    items = items,
    selectedIndex = 0,
    cancellable = false,
  }
end

-- A source multichoice window occupies the native tile position it was created
-- with: ScriptMenu_ShowMultichoice adds its main-display window at the stored
-- x/y with the measured width and `count * 2` tiles of height. The width is the
-- widest measured label plus the source 12-pixel inset, rounded UP to tiles.
function T.source_multichoice_windows_sit_at_their_native_foreground_position()
  local layout = resolve({ topology = topology(256, 192), menu = multichoice({ tileX = 12, tileY = 8 }) })
  Assert.equal(layout.surface.id, "main")
  Assert.isFalse(layout.surface.touch)
  local surface = layout.listSurface.surface
  Assert.isTrue(
    surface.x >= 12 * 8 and surface.x <= 13 * 8,
    "the window starts at its source tile column: " .. surface.x
  )
  Assert.isTrue(surface.y >= 8 * 8 and surface.y <= 9 * 8, "the window starts at its source tile row: " .. surface.y)
  -- "Choice A" measures 8 glyphs = 64 pixels, so the source asks for 76 and
  -- draws whole tiles.
  Assert.equal(surface.width, 10 * 8, "the measured label plus the source inset rounds up to whole tiles")
  Assert.isTrue(surface.height >= 3 * 2 * 8 - 16 and surface.height <= 3 * 2 * 8, "height is two tiles per item")
  Assert.equal(surface.width % 8, 0, "a source window stays on the tile grid")
  Assert.equal(surface.height % 8, 0, "a source window stays on the tile grid")

  local moved = resolve({ topology = topology(256, 192), menu = multichoice({ tileX = 20, tileY = 14 }) })
  local movedSurface = moved.listSurface.surface
  Assert.equal(movedSurface.x - surface.x, 8 * 8, "the window follows its source tile column")
  Assert.equal(movedSurface.y - surface.y, 6 * 8, "the window follows its source tile row")
end

-- ScriptMenu_ShowMultichoice indents the label by one glyph cell and keeps the
-- rest of its measured width, so the widest label never loses its last tile to
-- the window clip.
function T.multichoice_label_rows_fit_the_widest_measured_label()
  for _, text in ipairs({ "Short", "Choice A", "A label that is 18", string.rep("W", 12) }) do
    local layout = resolve({ topology = topology(256, 192), menu = multichoice({ tileX = 4, text = text }) })
    local surface = layout.listSurface.surface
    for _, row in ipairs(layout.rows) do
      Assert.isTrue(
        row.labelRect.width >= #text * 8,
        string.format("the label row holds the %d-pixel label: %d", #text * 8, row.labelRect.width)
      )
      Assert.isTrue(
        row.labelRect.x + row.labelRect.width <= surface.x + surface.width,
        "the label row never extends past the source window"
      )
    end
  end
end

-- The source window is never clamped to the display: a measured width that runs
-- off the reference display fails the layout instead of being clipped.
function T.overwide_multichoice_windows_fail_instead_of_clipping()
  Assert.throws(function()
    resolve({ topology = topology(256, 192), menu = multichoice({ tileX = 24, text = string.rep("W", 40) }) })
  end)
end

-- ScriptMenu_SetAnchorRight makes the window's *left* edge move: the stored x
-- loses exactly the measured window width, so the right edge stays on x.
function T.right_anchored_multichoice_windows_subtract_their_measured_tile_width()
  -- Column 20 keeps the ten-tile source window of an eight-glyph "Choice A"
  -- label inside the 256-pixel reference display (20 * 8 + 10 * 8 = 240).
  local plain = resolve({ topology = topology(256, 192), menu = multichoice({ tileX = 20 }) })
  local anchored = resolve({ topology = topology(256, 192), menu = multichoice({ tileX = 16, anchorRight = true }) })
  Assert.isTrue(
    plain.listSurface.surface.x >= 20 * 8 and plain.listSurface.surface.x <= 21 * 8,
    "an unanchored window starts at its source tile column: " .. plain.listSurface.surface.x
  )
  -- The window keeps its right edge on the source column, so its left edge is
  -- that column minus the measured window width.
  Assert.equal(
    anchored.listSurface.surface.x,
    16 * 8 - plain.listSurface.surface.width,
    "the anchor subtracts the measured window width from the source x"
  )

  local wide = resolve({ topology = topology(256, 192), menu = multichoice({ tileX = 16, anchorRight = true }) })
  local narrow = resolve({
    topology = topology(256, 192),
    menu = multichoice({ tileX = 16, anchorRight = true, text = "Short" }),
  })
  Assert.equal(
    narrow.listSurface.surface.x - wide.listSurface.surface.x,
    (8 - 5) * 8,
    "narrower labels are rounded to fewer tiles and subtract less"
  )
end

-- The source multichoice window belongs to the gameplay display; the existing
-- touchscreen list menu keeps the auxiliary presentation it already has.
function T.multichoice_windows_use_the_gameplay_display_while_list_menus_stay_auxiliary()
  local dual = ScreenTopology.dualDisplay({
    id = "main",
    rect = rect(0, 0, 400, 240),
    role = "world",
    touch = false,
  }, {
    id = "secondary",
    rect = rect(412, 0, 400, 240),
    role = "auxiliary",
    touch = true,
  })
  local foreground = resolve({ topology = dual, menu = multichoice({ tileX = 12, tileY = 8 }) })
  Assert.equal(foreground.surface.id, "main")
  Assert.isTrue(contains(foreground.surface.safeRect, physical(foreground, foreground.listSurface.surface)))
  Assert.equal(resolve({ topology = dual, menu = menu(3) }).surface.id, "secondary")
end

function T.directional_adjacency_follows_item_geometry_and_has_no_wraparound()
  local layout = {
    itemCount = 4,
    itemRects = {
      [0] = rect(0, 0, 8, 8),
      [1] = rect(12, 0, 8, 8),
      [2] = rect(0, 12, 8, 8),
      [3] = rect(12, 12, 8, 8),
    },
  }

  Assert.equal(MenuLayout.adjacentItem(layout, 0, "right"), 1)
  Assert.equal(MenuLayout.adjacentItem(layout, 0, "down"), 2)
  Assert.equal(MenuLayout.adjacentItem(layout, 3, "left"), 2)
  Assert.equal(MenuLayout.adjacentItem(layout, 3, "up"), 1)
  Assert.equal(MenuLayout.adjacentItem(layout, 0, "left"), nil)
  Assert.equal(MenuLayout.adjacentItem(layout, 0, "up"), nil)
  Assert.equal(MenuLayout.adjacentItem(layout, 3, "right"), nil)
  Assert.equal(MenuLayout.adjacentItem(layout, 3, "down"), nil)
end

function T.directional_adjacency_prefers_the_same_logical_row_or_column()
  local primaryAxisLayout = {
    itemCount = 3,
    itemRects = {
      [0] = rect(0, 0, 8, 8),
      [1] = rect(12, 24, 8, 8),
      [2] = rect(20, 0, 8, 8),
    },
  }
  Assert.equal(MenuLayout.adjacentItem(primaryAxisLayout, 0, "right"), 2)

  local crossAxisLayout = {
    itemCount = 3,
    itemRects = {
      [0] = rect(0, 0, 8, 8),
      [1] = rect(12, 24, 8, 8),
      [2] = rect(12, 12, 8, 8),
    },
  }
  Assert.equal(MenuLayout.adjacentItem(crossAxisLayout, 0, "right"), 2)
end

function T.rejects_malformed_menu_input()
  Assert.throws(function()
    resolve({ topology = topology(256, 192), menu = menu(0) })
  end)
  Assert.throws(function()
    resolve({ topology = topology(256, 192), menu = menu(1, { selectedIndex = 1 }) })
  end)
  Assert.throws(function()
    resolve({ topology = topology(256, 192), menu = menu(1), bounds = rect(0, 0, 0, 10) })
  end)
end

return { tests = T }
