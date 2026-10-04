-- Pure four-topology placement and inverse-input contracts for the mart
-- child's two fixed source-sized panes.

local Assert = require("tests.support.Assert")
local ApplicationLayout = require("libs.ui.src.ApplicationLayout")
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
  return measurement(width, height, ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    role = "world",
    touch = false,
  }))
end

local function dual()
  return measurement(800, 600, ScreenTopology.dualDisplay({
    id = "world",
    rect = { x = 400, y = 100, width = 256, height = 192 },
    role = "world",
    touch = false,
  }, {
    id = "aux",
    rect = { x = 100, y = 300, width = 256, height = 192 },
    role = "auxiliary",
    touch = true,
  }))
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

function T.wide_and_tall_pair_source_panes_without_gap_or_reflow()
  local set = interfaces()
  local wide = resolve(set, "wide", single(1280, 720))
  local wideUpper, wideLower = pane(wide, "upper"), pane(wide, "lower")
  Assert.isFalse(wideUpper.interactive)
  Assert.isTrue(wideLower.interactive)
  Assert.equal(wideUpper.placement.pixelScale, wideLower.placement.pixelScale)
  Assert.equal(
    wideLower.placement.frame.x,
    wideUpper.placement.frame.x + 256 * wideUpper.placement.pixelScale
  )
  uncropped(wideUpper.placement, "wide upper pane")
  uncropped(wideLower.placement, "wide lower pane")
  Assert.equal(#wide.frames, 1, "the pair reserves one independent application frame")

  local tall = resolve(set, "tall", single(600, 1000))
  local tallUpper, tallLower = pane(tall, "upper"), pane(tall, "lower")
  Assert.equal(tallUpper.placement.pixelScale, tallLower.placement.pixelScale)
  Assert.equal(
    tallLower.placement.frame.y,
    tallUpper.placement.frame.y + 192 * tallUpper.placement.pixelScale
  )
  uncropped(tallLower.placement, "tall lower pane")
  Assert.equal(#tall.frames, 1, "the tall pair reserves one independent application frame")
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

function T.input_is_already_lower_local_and_outside_press_becomes_dismiss()
  local set = interfaces()
  local plan = resolve(set, "nativeLike", single(640, 480))
  local view = { state = "quantity", quantity = 3 }
  local event = { type = "pointer_down", pointerId = "touch:0", x = 136, y = 100 }
  Assert.deepEqual(plan.mapInput(event, view, plan), event, "pane-local pointer coordinates reach the controller unchanged")
  Assert.deepEqual(
    plan.mapInput({ type = "pointer_down", pointerId = "touch:0", outside = true }, view, plan),
    { type = "dismiss" },
    "an outside press is a dismissal intent"
  )
end

return { tests = T }
