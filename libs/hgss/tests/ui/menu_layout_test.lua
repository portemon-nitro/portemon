-- Pure menu-layout tests exercise deterministic list geometry across display
-- topologies without involving rendering or physical input.

local Assert = require("tests.support.Assert")
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

function T.touch_menus_use_touch_sized_rows_and_a_cancel_target()
  local layout = resolve({
    topology = topology(256, 192, { touch = true }),
    menu = menu(2, { cancellable = true }),
  })
  Assert.isTrue(layout.itemRects[0].height * layout.placement.scale >= MenuLayout.minimumTouchTarget)
  Assert.notNil(layout.cancelRect)
  Assert.isTrue(layout.cancelRect.y >= layout.listSurface.surface.y + layout.listSurface.surface.height)
  Assert.isTrue(layout.cancelRect.height * layout.placement.scale >= MenuLayout.minimumTouchTarget)
  Assert.isNil(resolve({ topology = topology(256, 192), menu = menu(2, { cancellable = true }) }).cancelRect)
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
