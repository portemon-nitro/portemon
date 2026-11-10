-- Pure four-topology placement and inverse-input contracts for the mart
-- child's two fixed source-sized panes.

local Assert = require("tests.support.Assert")
local ApplicationLayout = require("libs.ui.src.ApplicationLayout")
local FieldDialogueTheme = require("libs.hgss.src.ui.FieldDialogueTheme")
local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
local MartInterface = require("game.hgss.src.mart.MartInterface")
local MartFixture = require("tests.support.MartFixture")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {}

local function measurement(width, height, topology)
  return {
    width = width,
    height = height,
    topology = topology,
    pixelRatio = 1,
    signature = "mart-interface-test:" .. width .. "x" .. height,
  }
end

local function single(width, height)
  return measurement(
    width,
    height,
    ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = width, height = height },
      role = "world",
      touch = false,
    })
  )
end

local function dual()
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
    })
  )
end

local function interfaces()
  return MartInterface.defaults(MartFixture.manifest())
end

local function resolve(set, key, measured)
  local selection = ApplicationLayout.selectSurfaces(measured)
  local context = {
    measurement = measured,
    configuration = key,
    primary = selection.primary,
    secondary = selection.secondary,
    nativeLikeInterface = set.nativeLike,
  }
  return set[key](context, { state = "browse" })
end

local function pane(plan, id)
  for _, entry in ipairs(plan.panes) do
    if entry.id == id then
      return entry
    end
  end
  error("missing " .. id .. " pane", 0)
end

local function uncropped(value, description)
  local crop = value.crop or { left = 0, right = 0, top = 0, bottom = 0 }
  Assert.equal(crop.left, 0, description .. " keeps its left edge")
  Assert.equal(crop.right, 0, description .. " keeps its right edge")
  Assert.equal(crop.top, 0, description .. " keeps its top edge")
  Assert.equal(crop.bottom, 0, description .. " keeps its bottom edge")
end

function T.native_like_shows_only_the_interactive_lower_pane()
  local source = MartFixture.manifest()
  local set = MartInterface.defaults(source)
  local plan = resolve(set, "nativeLike", single(640, 480))
  Assert.equal(#plan.panes, 1)
  Assert.equal(plan.panes[1].id, "lower")
  Assert.isTrue(plan.panes[1].interactive)
  Assert.equal(plan.content.upper, source.upper, "the source upper geometry stays part of plan content")
  Assert.equal(plan.content.lower, source.lower, "the source lower geometry stays part of plan content")
  uncropped(plan.panes[1].placement, "native lower pane")
end

function T.wide_and_tall_clip_stack_and_pad_the_pair_without_gap_or_reflow()
  local set = interfaces()
  local cases = {
    { key = "wide", width = 1280, height = 720 },
    { key = "tall", width = 600, height = 1000 },
  }
  for _, case in ipairs(cases) do
    local plan = resolve(set, case.key, single(case.width, case.height))
    local upper, lower = pane(plan, "upper"), pane(plan, "lower")
    Assert.isFalse(upper.interactive, case.key .. " keeps the upper strip non-interactive")
    Assert.isTrue(lower.interactive, case.key .. " keeps the lower pane interactive")
    Assert.equal(upper.placement.pixelScale, lower.placement.pixelScale, case.key .. " shares one integer scale")
    -- The opaque 51-row strip sits top-aligned in its 8px-padded 56-row
    -- slot; the renderer paints the 5 padding rows below it with the strip
    -- background blue, so the frame content stays 8px-compatible with no
    -- transparent air.
    Assert.equal(
      upper.placement.frame.height,
      56 * upper.placement.pixelScale,
      case.key .. " padded upper slot spans strip plus blue"
    )
    Assert.equal(
      lower.placement.frame.y,
      upper.placement.frame.y + 56 * upper.placement.pixelScale,
      case.key .. " stacks the lower pane below the padded slot"
    )
    uncropped(upper.placement, case.key .. " upper pane")
    uncropped(lower.placement, case.key .. " lower pane")
    Assert.equal(#plan.frames, 1, case.key .. " reserves one independent application frame")
    local contentBox = assert(plan.frames[1].contentBox, case.key .. " frame carries its content box")
    Assert.equal(contentBox.width % 8, 0, case.key .. " frame content stays 8px-compatible wide")
    Assert.equal(contentBox.height % 8, 0, case.key .. " frame content stays 8px-compatible tall")
    local tiles = FieldDialogueTheme.applicationFrameTilePlacements(contentBox)
    Assert.isTrue(
      #tiles.top > 0 and #tiles.sides > 0 and #tiles.bottom > 0,
      case.key .. " frame content tiles without raising the 8px contract"
    )
  end
  -- The wide slot keeps full logical rows for the renderer while its top
  -- maps to the first opaque source row.
  local wideUpper = pane(resolve(set, "wide", single(1280, 720)), "upper")
  Assert.equal(wideUpper.placement.logicalHeight, 192, "the padded upper keeps full logical rows for the renderer")
  Assert.equal(wideUpper.placement.logicalWidth, 256, "the padded upper keeps full logical columns")
  local logicalX, logicalY =
    LayoutGeometry.hostToLogical(wideUpper.placement, wideUpper.placement.frame.x, wideUpper.placement.frame.y)
  Assert.equal(logicalX, 0, "the padded upper slot starts at the visible rect origin")
  Assert.equal(logicalY, 141, "the slot top maps to the first opaque row")
end

function T.dual_display_uses_world_for_upper_and_auxiliary_for_interaction()
  local set = interfaces()
  local plan = resolve(set, "dualDisplay", dual())
  local upper, lower = pane(plan, "upper"), pane(plan, "lower")
  Assert.equal(#plan.panes, 2)
  Assert.isFalse(upper.interactive)
  Assert.isTrue(lower.interactive)
  Assert.equal(upper.placement.frame.x, 400)
  Assert.equal(lower.placement.frame.x, 100)
  Assert.equal(lower.placement.frame.y, 300)
  uncropped(lower.placement, "dual lower pane")
end

function T.input_is_already_lower_local_and_outside_presses_are_dropped()
  local set = interfaces()
  local plan = resolve(set, "nativeLike", single(640, 480))
  local view = { state = "quantity", quantity = 3 }
  local event = { type = "pointer_down", pointerId = "touch:0", x = 136, y = 100 }
  Assert.deepEqual(
    plan.mapInput(event, view, plan),
    event,
    "pane-local pointer coordinates reach the controller unchanged"
  )
  Assert.isNil(
    plan.mapInput({ type = "pointer_down", pointerId = "touch:0", outside = true }, view, plan),
    "an outside press never closes the modal shop"
  )
end

return { tests = T }
