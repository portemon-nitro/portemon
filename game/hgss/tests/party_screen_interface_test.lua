-- Leaf adaptation for the field party screen: four display cases resolve
-- complete matched plans over one canonical 256x192 pane. DualDisplay
-- takes the auxiliary fullscreen and nativeLike the single-surface
-- fullscreen, both uncropped; wide and tall center the pane in a static
-- framed box with a native-like fallback below 1x. The content is
-- the canonical compact grid; render and input callbacks match.

local Assert = require("tests.support.Assert")
local ApplicationLayout = require("libs.ui.src.ApplicationLayout")
local PartyScreenInterface = require("game.hgss.src.field.PartyScreenInterface")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {}

local function measurement(width, height, topology, pixelRatio)
  return {
    width = width,
    height = height,
    topology = topology,
    pixelRatio = pixelRatio or 1,
    signature = "party-interface-test:" .. width .. "x" .. height .. "@" .. (pixelRatio or 1),
  }
end

local function singleDisplay(width, height, pixelRatio)
  return measurement(
    width,
    height,
    ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = width, height = height },
      role = "world",
      touch = false,
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

---@param measured table<string, unknown>
---@param configuration string
---@param interfaceTable table<string, unknown>
---@return ApplicationLayout.Context
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

local function view(cancellable)
  return { cancellable = cancellable ~= false, cursorNode = 0 }
end

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
    windows = {
      message = { x = 16, y = 168, width = 160, height = 16 },
      context = { x = 152, y = 120, width = 96, height = 64 },
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
    iconAnimations = { periods = { 1, 8, 12, 24, 40, 36 } },
  }
end

local function partyInterface()
  return PartyScreenInterface.defaults(sourceManifest())
end

local function partySession(overrides)
  local sessionModule = require("libs.ui.src.ApplicationPresentation")
  return sessionModule.new(PartyScreenInterface.defaults(sourceManifest()), overrides)
end

local function singlePane(plan, what)
  Assert.equal(#plan.panes, 1, "the party plan carries its single content pane " .. what)
  local pane = plan.panes[1]
  Assert.isTrue(pane.interactive, "the party pane takes pointer input " .. what)
  Assert.equal(plan.inputKey, "party", "the party plan names its stable input geometry " .. what)
  Assert.isTrue(type(plan.render) == "function", "the party plan carries its render callback " .. what)
  Assert.isTrue(type(plan.mapInput) == "function", "the party plan carries its input callback " .. what)
  local placement = assert(pane.placement, "the party pane carries its placement " .. what)
  -- Windowed body placements carry no crop-budget record; absence means the same uncropped fit.
  local crop = placement.crop or { left = 0, right = 0, top = 0, bottom = 0 }
  Assert.equal(crop.left, 0, "the party pane never crops " .. what)
  Assert.equal(crop.right, 0, "the party pane never crops " .. what)
  Assert.equal(crop.top, 0, "the party pane never crops " .. what)
  Assert.equal(crop.bottom, 0, "the party pane never crops " .. what)
  return pane
end

local function checkContent(plan, cancellable, what)
  local content = assert(plan.content, "the party plan carries its canonical content " .. what)
  Assert.equal(#content.slotRects, 6, "the party content carries six panels " .. what)
  Assert.equal(content.slotRects[1].x, 0, "the first panel sits at the pane origin " .. what)
  Assert.equal(content.slotRects[2].x, 128, "the second panel staggers into the right column " .. what)
  Assert.equal(content.slotRects[2].y, 8, "the right column staggers down eight pixels " .. what)
  Assert.equal(content.slotRects[1].width, 128, "panels keep their source width " .. what)
  Assert.equal(content.slotRects[1].height, 48, "panels keep their source height " .. what)
  if cancellable then
    Assert.isTrue(content.cancelRect ~= nil, "the cancellable content carries cancel " .. what)
  else
    Assert.isNil(content.cancelRect, "the sealed content carries no cancel " .. what)
  end
end

function T.native_like_resolves_uncropped_fullscreen()
  local interfaces = partyInterface()
  local plan = interfaces.nativeLike(contextFor(singleDisplay(640, 480), "nativeLike", interfaces), view(true))
  singlePane(plan, "nativeLike")
  checkContent(plan, true, "nativeLike")
  local sealed = interfaces.nativeLike(contextFor(singleDisplay(640, 480), "nativeLike", interfaces), view(false))
  checkContent(sealed, false, "sealed nativeLike")
end

function T.dual_display_pairs_detail_world_with_interaction_auxiliary()
  local interfaces = partyInterface()
  local plan = interfaces.dualDisplay(contextFor(translatedPair(), "dualDisplay", interfaces), view(true))
  Assert.equal(#plan.panes, 2, "dual display pairs detail with interaction")
  local detail = plan.panes[1]
  Assert.equal(detail.id, "detail", "the upper pane carries detail")
  Assert.isFalse(detail.interactive, "detail takes no pointer input")
  local pane = plan.panes[2]
  Assert.equal(pane.id, "content", "the lower pane carries interaction")
  Assert.isTrue(pane.interactive, "the party pane takes pointer input")
  Assert.equal(plan.inputKey, "party", "the pair keeps its stable input geometry")
  checkContent(plan, true, "dualDisplay")
  local frame = pane.placement.frame
  Assert.isTrue(
    frame.x >= 100 and frame.x + frame.width <= 356,
    "the dual interaction pane stays inside the translated auxiliary surface"
  )
end

function T.wide_and_tall_pair_detail_with_a_static_framed_box()
  local interfaces = partyInterface()
  local wide = interfaces.wide(contextFor(singleDisplay(1280, 720), "wide", interfaces), view(true))
  Assert.equal(#wide.panes, 2, "wide keeps both native panes")
  Assert.equal(wide.panes[1].id, "detail", "wide detail sits left")
  Assert.equal(wide.panes[2].id, "content", "wide interaction sits right")
  Assert.equal(wide.inputKey, "party", "the pair keeps its stable input geometry")
  checkContent(wide, true, "wide")
  local wideFrame = assert(wide.frames, "a wide host frames the party")[1]
  Assert.notNil(wideFrame, "one outer frame decorates the wide pair")
  local tall = interfaces.tall(contextFor(singleDisplay(600, 1000), "tall", interfaces), view(true))
  Assert.equal(#tall.panes, 2, "tall keeps both native panes")
  Assert.equal(tall.panes[1].id, "detail", "tall detail sits above")
  Assert.equal(tall.panes[2].id, "content", "tall interaction sits below")
  Assert.equal(#tall.frames, 1, "a tall host frames the party in a static box")
end

function T.small_framed_hosts_fall_back_to_native_like()
  local interfaces = partyInterface()
  local plan = interfaces.wide(contextFor(singleDisplay(256, 192), "wide", interfaces), view(true))
  singlePane(plan, "small wide")
  Assert.deepEqual(plan.frames, {}, "a frame that cannot fit falls back to fullscreen")
end

function T.tiny_fixed_party_host_stays_inactive_without_a_native_fit()
  local interfaces = partyInterface()
  local plan = interfaces.wide(contextFor(singleDisplay(200, 150), "wide", interfaces), view(true))
  Assert.deepEqual(plan.panes, {}, "a fixed party pane below its 1x crop budget is unavailable")
  Assert.deepEqual(plan.frames, {}, "an unavailable party pane publishes no frame")
end

function T.equivalent_measurements_resolve_the_same_geometry()
  local interfaces = partyInterface()
  local first = interfaces.nativeLike(contextFor(singleDisplay(640, 480), "nativeLike", interfaces), view(true))
  local fresh = measurement(
    640,
    480,
    ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 640, height = 480 },
      role = "world",
      touch = false,
    }),
    1
  )
  local second = interfaces.nativeLike(contextFor(fresh, "nativeLike", interfaces), view(true))
  Assert.equal(first.inputKey, second.inputKey, "a fresh measurement keeps the input geometry")
  Assert.equal(
    first.panes[1].placement.pixelScale,
    second.panes[1].placement.pixelScale,
    "a fresh measurement keeps the pixel scale"
  )
end

function T.dpi_two_matches_the_physical_fit()
  local interfaces = partyInterface()
  local ratioOne = interfaces.nativeLike(contextFor(singleDisplay(750, 560, 1), "nativeLike", interfaces), view(true))
  local ratioTwo = interfaces.nativeLike(contextFor(singleDisplay(375, 280, 2), "nativeLike", interfaces), view(true))
  Assert.equal(
    ratioOne.panes[1].placement.pixelScale,
    ratioTwo.panes[1].placement.pixelScale,
    "equal physical bounds keep the physical magnification"
  )
end

function T.render_invokes_the_borrowed_renderer_with_plan_and_icons()
  local FakeGraphics = require("tests.support.FakeGraphics")
  local interfaces = partyInterface()
  local plan = interfaces.nativeLike(contextFor(singleDisplay(640, 480), "nativeLike", interfaces), view(true))
  local calls = {}
  local graphics = FakeGraphics.new({})
  local resources = {
    graphics = graphics,
    partyScreenRenderer = {
      drawPane = function(_, presentation, pane, content, collaborators)
        calls[#calls + 1] =
          { presentation = presentation, pane = pane, content = content, collaborators = collaborators }
      end,
    },
    icons = { sentinel = "icons" },
  }
  plan.render(resources, view(true), plan)
  Assert.equal(#calls, 1, "the render callback draws its single pane once")
  Assert.isTrue(calls[1].pane == plan.panes[1], "the render callback draws the published pane")
  Assert.isTrue(calls[1].content == plan.content, "the render callback draws the canonical content")
  Assert.isTrue(calls[1].collaborators == resources.icons, "the render callback borrows the icon provider")
  Assert.equal(graphics:pushDepth(), 0, "the render scope restores the graphics stack")
end

function T.map_input_turns_outside_points_into_dismiss_and_forwards_the_rest()
  local interfaces = partyInterface()
  local plan = interfaces.nativeLike(contextFor(singleDisplay(640, 480), "nativeLike", interfaces), view(true))
  Assert.deepEqual(
    plan.mapInput({ type = "pointer_down", pointerId = "p", outside = true }, view(true), plan),
    { type = "dismiss" },
    "an outside press dismisses instead of unwinding nested party state"
  )
  local event = { type = "pointer_down", pointerId = "p", x = 10, y = 10 }
  Assert.isTrue(
    plan.mapInput(event, view(true), plan) == event,
    "visible logical points reach the controller unchanged"
  )
end

function T.case_override_replaces_one_complete_interface()
  local replacement = {
    panes = {},
    content = {},
    inputKey = "party-custom",
    render = function(_, _, _) end,
    mapInput = function()
      return nil
    end,
    frames = {},
  }
  local function customWide(_, _)
    return replacement
  end
  local session = partySession({ wide = customWide })
  local plan = session:resolve(singleDisplay(1280, 720), view(true))
  Assert.isTrue(plan == replacement, "the override supplies the whole interface")
  local native = session:resolve(singleDisplay(640, 480), view(true))
  Assert.equal(native.inputKey, "party", "other cases keep their default interface")
end

function T.unknown_override_cases_and_non_functions_fail()
  Assert.throws(function()
    partySession({
      overlay = function(_, _)
        return nil
      end,
    })
  end, "unknown override cases fail at composition")
  Assert.throws(function()
    partySession({ wide = "framed" })
  end, "non-function overrides fail at composition")
end

function T.host_detail_overlay_appends_the_framed_overlay()
  local interfaces = partyInterface()
  local plain = interfaces.nativeLike(
    contextFor(singleDisplay(640, 480), "nativeLike", interfaces),
    { cancellable = true, cursorNode = 0 }
  )
  Assert.equal(#plain.panes, 1, "no host overlay flag means no overlay")
  local plan = interfaces.nativeLike(
    contextFor(singleDisplay(640, 480), "nativeLike", interfaces),
    { cancellable = true, cursorNode = 0, detailOverlay = true }
  )
  Assert.equal(#plan.panes, 2, "the host flag appends the detail overlay")
  Assert.equal(plan.panes[1].id, "content", "the interaction pane keeps its identity")
  Assert.isTrue(plan.panes[1].interactive, "the interaction pane keeps pointer input")
  Assert.equal(plan.panes[2].id, "overlay", "the overlay carries detail")
  Assert.isFalse(plan.panes[2].interactive, "the overlay takes no pointer input")
  Assert.deepEqual(
    plan.panes[2].placement.frame,
    plain.panes[1].placement.frame,
    "the overlay shares the content placement"
  )
  Assert.equal(
    plan.panes[2].placement.pixelScale,
    plain.panes[1].placement.pixelScale,
    "the overlay keeps the content magnification"
  )
  Assert.deepEqual(
    plan.content.slotRects,
    plain.content.slotRects,
    "the overlay changes no native panel geometry"
  )
  Assert.deepEqual(
    plan.content.cancelRect,
    plain.content.cancelRect,
    "the overlay changes no native cancel target"
  )
  local off = interfaces.nativeLike(
    contextFor(singleDisplay(640, 480), "nativeLike", interfaces),
    { cancellable = true, cursorNode = 0, detailOverlay = false }
  )
  Assert.equal(#off.panes, 1, "an explicit off flag keeps the single content pane")
end

function T.overlay_plans_map_pointer_input_through_content_unchanged()
  local plainView = { cancellable = true, cursorNode = 0 }
  local plainSession = partySession()
  plainSession:resolve(singleDisplay(640, 480), plainView)
  local plainPlan = plainSession:plan()
  local frame = assert(
    plainPlan.panes[1].placement.frame,
    "the content pane carries its host frame"
  )
  local events = {
    { type = "pointer_down", pointerId = "touch:overlay-compare", x = frame.x + 64, y = frame.y + 24 },
    { type = "pointer_up", pointerId = "touch:overlay-compare", x = frame.x + 64, y = frame.y + 24 },
  }
  local plainMapped = plainSession:mapInput(events, plainView)
  local overlayView = { cancellable = true, cursorNode = 0, detailOverlay = true }
  local overlaySession = partySession()
  overlaySession:resolve(singleDisplay(640, 480), overlayView)
  Assert.equal(#overlaySession:plan().panes, 2, "the overlay plan under test is actually shown")
  local overlayMapped = overlaySession:mapInput(events, overlayView)
  Assert.deepEqual(
    overlayMapped,
    plainMapped,
    "the visible overlay changes no pointer mapping"
  )
end

function T.closed_snapshots_resolve_a_disposable_plan()
  local interfaces = partyInterface()
  local plan = interfaces.nativeLike(contextFor(singleDisplay(640, 480), "nativeLike", interfaces), { open = false })
  singlePane(plan, "closed")
  checkContent(plan, true, "closed")
end

function T.missing_measurement_fails_without_a_partial_plan()
  local interfaces = partyInterface()
  Assert.throws(function()
    local incomplete = {
      configuration = "nativeLike",
      nativeLikeInterface = interfaces.nativeLike,
    }
    interfaces.nativeLike(incomplete --[[@as ApplicationLayout.Context]], view(true))
  end, "a resolver without its display measurement fails")
end

-- While the reveal runs, every covered pane carries one opaque black cover
-- above its content that retreats downward as its leg advances: full cover
-- at step zero, a bottom-anchored remainder mid-leg, and no cover once the
-- leg is done. The first leg completes for one pane before the remaining
-- pane starts, and the interactive screen carries no cover at all.
function T.opening_covers_retreat_downward_in_pane_order()
  local FakeGraphics = require("tests.support.FakeGraphics")
  local interfaces = partyInterface()
  local plan = interfaces.wide(contextFor(singleDisplay(1280, 720), "wide", interfaces), view(true))
  Assert.equal(#plan.panes, 2, "the paired plan under test carries both panes")

  ---@param opening { subStep: integer, mainStep: integer }? the reveal progress, or nil once interactive
  ---@return integer[] the sorted cover heights across both panes
  local function coverHeights(opening)
    local graphics = FakeGraphics.new({})
    local draws = 0
    local resources = {
      graphics = graphics,
      partyScreenRenderer = {
        drawPane = function()
          draws = draws + 1
        end,
      },
      icons = {},
    }
    local revealView = view(true)
    revealView.opening = opening
    plan.render(resources, revealView, plan)
    Assert.equal(draws, 2, "the reveal keeps drawing both panes underneath")
    Assert.equal(graphics:pushDepth(), 0, "the reveal restores the graphics stack")
    local heights = {}
    for _, rectangle in ipairs(graphics.rectangles) do
      if rectangle.mode == "fill" then
        local color = rectangle.color
        Assert.deepEqual(
          { color[1], color[2], color[3], color[4] },
          { 0, 0, 0, 1 },
          "reveal covers are opaque black"
        )
        Assert.equal(rectangle.w, 256, "reveal covers span the pane width")
        Assert.equal(rectangle.x, 0, "reveal covers start at the pane edge")
        Assert.equal(rectangle.y + rectangle.h, 192, "reveal covers stay bottom-anchored")
        heights[#heights + 1] = rectangle.h
      end
    end
    table.sort(heights)
    return heights
  end

  for subStep = 0, 6 do
    local expected = { 192 }
    if subStep < 6 then
      expected = { 192 - 32 * subStep, 192 }
    end
    table.sort(expected)
    Assert.deepEqual(
      coverHeights({ subStep = subStep, mainStep = 0 }),
      expected,
      "the first leg clears one pane while the other stays covered"
    )
  end
  for mainStep = 1, 6 do
    local expected = {}
    if mainStep < 6 then
      expected = { 192 - 32 * mainStep }
    end
    Assert.deepEqual(
      coverHeights({ subStep = 6, mainStep = mainStep }),
      expected,
      "the second leg clears the remaining pane after the first completes"
    )
  end
  Assert.deepEqual(coverHeights(nil), {}, "the interactive screen carries no cover")
end

-- A lone content pane stays covered through the first leg and clears with
-- the second, so single-pane topologies keep the twelve-step wipe with no
-- re-cover and no clear-but-gated window.
function T.opening_lone_content_pane_clears_with_the_second_leg()
  local FakeGraphics = require("tests.support.FakeGraphics")
  local interfaces = partyInterface()
  local plan = interfaces.nativeLike(contextFor(singleDisplay(640, 480), "nativeLike", interfaces), view(true))
  Assert.equal(#plan.panes, 1, "the single-pane plan under test carries its content pane")
  Assert.equal(plan.panes[1].id, "content", "the lone pane is the interaction content")

  ---@param opening { subStep: integer, mainStep: integer }? the reveal progress, or nil once interactive
  ---@return integer? the lone cover height, or nil when clear
  local function coverHeight(opening)
    local graphics = FakeGraphics.new({})
    local resources = {
      graphics = graphics,
      partyScreenRenderer = {
        drawPane = function() end,
      },
      icons = {},
    }
    local revealView = view(true)
    revealView.opening = opening
    plan.render(resources, revealView, plan)
    Assert.equal(graphics:pushDepth(), 0, "the reveal restores the graphics stack")
    local height = nil
    for _, rectangle in ipairs(graphics.rectangles) do
      if rectangle.mode == "fill" then
        local color = rectangle.color
        Assert.deepEqual(
          { color[1], color[2], color[3], color[4] },
          { 0, 0, 0, 1 },
          "reveal covers are opaque black"
        )
        Assert.isNil(height, "the lone pane carries at most one cover")
        height = rectangle.h
      end
    end
    return height
  end

  for subStep = 0, 5 do
    Assert.equal(
      coverHeight({ subStep = subStep, mainStep = 0 }),
      192,
      "the lone pane stays covered while the first leg runs"
    )
  end
  for mainStep = 0, 6 do
    Assert.equal(
      coverHeight({ subStep = 6, mainStep = mainStep }),
      mainStep < 6 and (192 - 32 * mainStep) or nil,
      "the lone pane clears from the top with the second leg"
    )
  end
  Assert.isNil(coverHeight(nil), "the interactive screen carries no cover")
end

return { tests = T }
