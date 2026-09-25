-- Manifest-backed native party geometry: the six staggered source
-- panels resolve inside the 256x192 frame with deterministic dpad
-- neighbors, touch hit targets, and count-indexed menu rows.

local Assert = require("tests.support.Assert")
local PartyScreenLayout = require("libs.hgss.src.ui.PartyScreenLayout")

local T = {}

local function sourceManifest()
  local panels = {}
  local origins = { { 0, 0 }, { 128, 8 }, { 0, 48 }, { 128, 56 }, { 0, 96 }, { 128, 104 } }
  for slot, origin in ipairs(origins) do
    panels[slot] = {
      origin = { x = origin[1], y = origin[2] },
      size = { width = 128, height = 48 },
      chrome = {},
      text = {},
      hp = {},
      compat = {},
    }
  end
  local function dpadBox(left, top, up, down, leftNeighbor, rightNeighbor)
    return {
      left = left,
      top = top,
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
    windows = {
      message = { x = 16, y = 168, width = 160, height = 16 },
      context = { x = 152, y = 120, width = 96, height = 64 },
    },
    navigation = {
      dpad = {
        default = {
          dpadBox(64, 25, 7, 2, 7, 1),
          dpadBox(192, 33, 7, 3, 0, 2),
          dpadBox(64, 73, 0, 4, 1, 3),
          dpadBox(192, 81, 1, 5, 2, 4),
          dpadBox(64, 121, 2, 7, 3, 5),
          dpadBox(192, 129, 3, 7, 4, 7),
          dpadBox(0, 0, 0, 0, 0, 0),
          dpadBox(224, 168, 5, 1, 5, 0),
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
    iconAnimations = { periods = { 1, 8, 12, 24, 40, 36 } },
  }
end

function T.manifest_panels_resolve_the_staggered_native_grid()
  local layout = PartyScreenLayout.resolve({ manifest = sourceManifest(), cancellable = true })
  Assert.deepEqual(layout.frame, { x = 0, y = 0, width = 256, height = 192 })
  local expected = { { 0, 0 }, { 128, 8 }, { 0, 48 }, { 128, 56 }, { 0, 96 }, { 128, 104 } }
  for slot0 = 0, 5 do
    local rect = layout.slotRects[slot0 + 1]
    Assert.equal(rect.x, expected[slot0 + 1][1], "slot " .. slot0 .. " x")
    Assert.equal(rect.y, expected[slot0 + 1][2], "slot " .. slot0 .. " y")
    Assert.equal(rect.width, 128)
    Assert.equal(rect.height, 48)
  end
end

function T.manifest_dpad_compiles_neighbors_with_the_cancel_mapping()
  local layout = PartyScreenLayout.resolve({ manifest = sourceManifest(), cancellable = true })
  Assert.equal(layout.neighbors[0].right, 1)
  Assert.equal(layout.neighbors[0].down, 2)
  Assert.equal(layout.neighbors[4].down, "cancel", "the bottom row drops to cancel")
  Assert.equal(layout.neighbors[5].down, "cancel")
  Assert.equal(layout.neighbors.cancel.up, 5)
  Assert.equal(layout.neighbors[0].left, "cancel", "source left links resolve, never wrap")
end

function T.manifest_touch_rects_drive_hit_testing()
  local layout = PartyScreenLayout.resolve({ manifest = sourceManifest(), cancellable = true })
  Assert.deepEqual(layout.cancelRect, { x = 200, y = 152, width = 56, height = 40 })
  local hit = assert(layout.hitTest(210, 160), "cancel region hits")
  Assert.equal(hit.kind, "cancel")
  local slot = assert(layout.hitTest(30, 120), "occupied panel hits")
  Assert.equal(slot.kind, "slot")
  Assert.equal(slot.slot, 4)
end

function T.menu_rows_index_count_entries_inside_the_context_window()
  local layout = PartyScreenLayout.resolve({ manifest = sourceManifest(), cancellable = true })
  for count = 2, 8 do
    local rows = layout.menuRows(count)
    Assert.equal(#rows, count, "count " .. count .. " resolves one row per entry")
    for index, row in ipairs(rows) do
      Assert.equal(row.x, 152)
      Assert.equal(row.width, 96)
      Assert.equal(row.height, 8)
      Assert.equal(row.y, 120 + (index - 1) * 8, "row " .. index .. " stacks from the window top")
      Assert.isTrue(row.y + row.height <= 184, "rows stay inside the 64-pixel window")
    end
  end
  Assert.throws(function()
    layout.menuRows(9)
  end, "nine rows exceed the source count range")
  Assert.throws(function()
    layout.menuRows(1)
  end, "one row is below the source count range")
end

function T.sealed_layout_carries_no_cancel_targets()
  local layout = PartyScreenLayout.resolve({ manifest = sourceManifest(), cancellable = false })
  Assert.isNil(layout.cancelRect, "no close affordance resolves when forbidden")
  Assert.isNil(layout.hitTest(210, 160), "the forbidden cancel region stays noninteractive")
  Assert.isNil(layout.neighbors[5].down, "no cancel node resolves when forbidden")
  Assert.isNil(layout.neighbors.cancel, "no cancel node resolves when forbidden")
end

function T.missing_manifest_fails_without_partial_geometry()
  local opts = { cancellable = true } ---@type any -- the missing manifest is the invalid input under test
  Assert.throws(function()
    PartyScreenLayout.resolve(opts)
  end, "native geometry requires its manifest")
end

return { tests = T }
