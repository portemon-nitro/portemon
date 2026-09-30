-- Manifest-backed native party geometry: the six staggered source
-- panels resolve inside the 256x192 frame with deterministic dpad
-- neighbors, touch hit targets, and count-indexed menu rows.

local Assert = require("tests.support.Assert")
local PartyPresentationFixture = require("tests.support.PartyPresentationFixture")
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
      prompt = { x = 200, y = 80 },
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
  Assert.deepEqual(layout.neighbors.cancel, { up = 5, down = 1, left = 5, right = 0 })
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


function T.sealed_layout_carries_no_cancel_targets()
  local layout = PartyScreenLayout.resolve({ manifest = sourceManifest(), cancellable = false })
  Assert.isNil(layout.cancelRect, "no close affordance resolves when forbidden")
  Assert.isNil(layout.hitTest(210, 160), "the forbidden cancel region stays noninteractive")
  Assert.isNil(layout.neighbors[5].down, "no cancel node resolves when forbidden")
  Assert.isNil(layout.neighbors.cancel, "no cancel node resolves when forbidden")
end

-- Generated context-menu geometry: the layout selects one source-shaped
-- record per menu class and entry count, exposes its frame/text/touch
-- rectangles and neighbor links, and rejects counts outside the audited
-- top-level 2..8 / subcontext 2..5 ranges at lookup time. The lookup and
-- hit helper names below are an internal detail: the tests pin their
-- meaning (per-count records, wrap/lateral topology, count failures)
-- rather than any particular spelling the implementation must keep.
local function v3Manifest()
  return PartyPresentationFixture.manifest()
end

function T.generated_top_level_layouts_carry_one_record_per_entry()
  local manifest = v3Manifest()
  local layout = PartyScreenLayout.resolve({ manifest = manifest, cancellable = true }) ---@type any
  for count = 2, 8 do
    local entries = layout.menuLayout("topLevel", count)
    Assert.equal(#entries, count, "count " .. count .. " resolves one record per entry")
    for index, entry in ipairs(entries) do
      Assert.notNil(entry.textRect, "entry " .. index .. " carries its text rectangle")
      Assert.notNil(entry.frameRect, "entry " .. index .. " carries its frame rectangle")
      Assert.notNil(entry.touch, "entry " .. index .. " carries its touch target")
    end
  end
  local eight = layout.menuLayout("topLevel", 8)
  local xs = {}
  for _, entry in ipairs(eight) do
    xs[entry.frameRect.x] = true
  end
  local columns = 0
  for _ in pairs(xs) do
    columns = columns + 1
  end
  Assert.isTrue(columns > 1, "eight entries use lateral placement, never one vertical stack")
end

function T.generated_subcontext_layouts_wrap_without_lateral_links()
  local layout = PartyScreenLayout.resolve({ manifest = v3Manifest(), cancellable = true }) ---@type any
  for count = 2, 5 do
    local entries = layout.menuLayout("subcontext", count)
    Assert.equal(#entries, count, "count " .. count .. " resolves one record per entry")
    for index, entry in ipairs(entries) do
      Assert.isNil(entry.left, "subcontext entry " .. index .. " keeps no lateral link")
      Assert.isNil(entry.right, "subcontext entry " .. index .. " keeps no lateral link")
      Assert.notNil(entry.up, "subcontext entry " .. index .. " keeps its wrap link")
      Assert.notNil(entry.down, "subcontext entry " .. index .. " keeps its wrap link")
    end
  end
end

function T.unsupported_menu_counts_fail_at_lookup()
  local layout = PartyScreenLayout.resolve({ manifest = v3Manifest(), cancellable = true }) ---@type any
  for _, count in ipairs({ 1, 9 }) do
    local err = Assert.throws(function()
      layout.menuLayout("topLevel", count)
    end, "count " .. count .. " fails at lookup")
    Assert.isTrue(
      tostring(err):find(tostring(count), 1, true) ~= nil,
      "the lookup failure names its count, got " .. tostring(err)
    )
  end
  local err = Assert.throws(function()
    layout.menuLayout("subcontext", 6)
  end, "the six-entry subcontext fails at lookup")
  Assert.isTrue(tostring(err):find("6", 1, true) ~= nil, "the lookup failure names its count")
end

function T.menu_hit_testing_uses_the_generated_touch_targets()
  local manifest = v3Manifest()
  local layout = PartyScreenLayout.resolve({ manifest = manifest, cancellable = true }) ---@type any
  local entries = layout.menuLayout("topLevel", 4)
  for index, entry in ipairs(entries) do
    local touch = entry.touch
    local right = touch.right == 0 and 256 or touch.right
    local hit = layout.menuHit("topLevel", 4, touch.left + 1, touch.top + 1)
    Assert.notNil(hit, "entry " .. index .. " stays hittable inside its touch target")
    Assert.equal(hit.index, index, "the touch target resolves its own entry")
    Assert.isTrue(right > touch.left, "entry " .. index .. " keeps a positive touch width")
  end
  Assert.isNil(layout.menuHit("topLevel", 4, 0, 191), "empty pane space hits no menu entry")
end

function T.former_info_coordinates_are_not_party_targets()
  local layout = PartyScreenLayout.resolve({ manifest = v3Manifest(), cancellable = true })
  Assert.isNil(layout.hitTest(188, 180), "the retired info affordance is not a party target")
  Assert.isNil(layout.hitTest(184, 172), "the retired info corner is not a party target")
  Assert.deepEqual(layout.hitTest(210, 160), { kind = "cancel" }, "the cancel region still resolves")
end

function T.missing_manifest_fails_without_partial_geometry()
  local opts = { cancellable = true } ---@type any -- the missing manifest is the invalid input under test
  Assert.throws(function()
    PartyScreenLayout.resolve(opts)
  end, "native geometry requires its manifest")
end

return { tests = T }
