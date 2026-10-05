-- Host placement and inspection for the native Summary screen over
-- synthetic families: all four layout classes publish native main/sub
-- panes with the Summary input role and identical native content, the
-- gutter affordance opens a host-only inspection overlay with pointer
-- isolation, the menu edge toggles it, and layout changes discard it
-- without touching native state.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local FakeGraphics = require("tests.support.FakeGraphics")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local ScreenTopology = require("libs.ui.src.ScreenTopology")
local SummaryPresentationFixture = require("tests.support.SummaryPresentationFixture")
local SummaryScreenInterface = require("game.hgss.src.field.SummaryScreenInterface")
local SummaryScreenState = require("game.hgss.src.field.SummaryScreenState")

local T = {}

local function openService(seed)
  local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
  local catalog = CatalogFixture.makeCatalog()
  local service = HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(seed):capture(), catalog:fingerprint()),
    profile = CatalogFixture.profile(),
    game = "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
  })
  Assert.isTrue(
    service:giveMon({
      species = "CHIKORITA",
      level = 12,
      heldItem = "NONE",
      form = 0,
      location = 7,
      date = CatalogFixture.metDate(),
    }),
    "setup gift must enter the party"
  )
  return service
end

---@param class string dualDisplay, nativeLike, wide, or tall
local function measurementFor(class)
  if class == "dualDisplay" then
    return {
      width = 512,
      height = 384,
      topology = ScreenTopology.dualDisplay({
        id = "world",
        rect = { x = 0, y = 0, width = 256, height = 192 },
        role = "world",
        touch = false,
      }, {
        id = "aux",
        rect = { x = 256, y = 0, width = 256, height = 192 },
        role = "auxiliary",
        touch = true,
      }),
      pixelRatio = 1,
      signature = "summary-interface-test:dual",
    }
  end
  if class == "wide" then
    return {
      width = 640,
      height = 384,
      topology = ScreenTopology.oneDisplay({
        id = "main",
        rect = { x = 0, y = 0, width = 640, height = 384 },
        touch = false,
        role = "world",
      }),
      pixelRatio = 1,
      signature = "summary-interface-test:wide",
    }
  end
  if class == "tall" then
    return {
      width = 256,
      height = 384,
      topology = ScreenTopology.oneDisplay({
        id = "main",
        rect = { x = 0, y = 0, width = 256, height = 384 },
        touch = false,
        role = "world",
      }),
      pixelRatio = 1,
      signature = "summary-interface-test:tall",
    }
  end
  return {
    width = 256,
    height = 192,
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 256, height = 192 },
      touch = true,
      role = "world",
    }),
    pixelRatio = 1,
    signature = "summary-interface-test:nativeLike",
  }
end

---@param service table<string, unknown> live mon service
---@param class string host layout class under test
---@return table<string, unknown> open wrapper
local function openSummary(service, class)
  local family = SummaryPresentationFixture.manifest()
  local lease = {}
  function lease:prepare(demand)
    return { kind = "ready", key = demand.key, assets = { manifest = family } }
  end
  function lease:release()
  end
  local measured = measurementFor(class)
  local state = SummaryScreenState.new({
    mons = service,
    manifest = family,
    initialSlot = 0,
    measureDisplay = function()
      return measured
    end,
    mode = "summary",
    context = function()
      return SummaryPresentationFixture.context(service:partyCount())
    end,
    readNavigation = function()
      return nil
    end,
    acquirePreparation = function()
      return lease
    end,
  })
  for _ = 1, 12 do
    state:updateFixed({})
  end
  return state
end

function T.layouts_publish_native_panes_with_summary_roles()
  local service = openService(0x1F000001)
  local contents = {}
  for _, class in ipairs({ "dualDisplay", "wide", "tall", "nativeLike" }) do
    local state = openSummary(service, class)
    local status = state:status()
    Assert.equal(status.wrapperPhase, "active", class .. " reaches the interactive phase")
    local plan = assert(status.presentation, class .. " publishes its pane plan")
    Assert.equal(plan.inputKey, "summary", class .. " carries the Summary input role")
    local byId = {}
    for _, pane in ipairs(assert(plan.panes, class .. " carries its panes")) do
      byId[pane.id] = pane
    end
    local main = assert(byId.main, class .. " exposes the native main pane")
    local sub = assert(byId.sub, class .. " exposes the native sub pane")
    Assert.isTrue(main.placement ~= nil and sub.placement ~= nil, class .. " places both panes")
    Assert.isFalse(main.interactive, class .. " never makes the main pane touch-interactive by moving it")
    Assert.isTrue(sub.interactive, class .. " keeps the touch pane interactive")
    if class == "wide" then
      Assert.isTrue(main.placement.x < sub.placement.x, "wide keeps main left of sub")
    elseif class == "tall" then
      Assert.isTrue(main.placement.y < sub.placement.y, "tall keeps main above sub")
    elseif class == "dualDisplay" then
      Assert.isTrue(
        main.placement.x ~= sub.placement.x or main.placement.y ~= sub.placement.y,
        "dual keeps main and sub on their own surfaces"
      )
    end
    contents[class] = plan.content
    state:dispose()
  end
  Assert.deepEqual(contents.wide, contents.tall, "native content ignores the host aspect ratio")
  Assert.deepEqual(contents.tall, contents.nativeLike, "native content ignores the host topology")
end

function T.affordance_lives_in_its_gutter_outside_native_controls()
  local box = SummaryScreenInterface.AFFORDANCE
  Assert.equal(box.x, 144, "the affordance starts past the native tab column")
  Assert.equal(box.y, 168, "the affordance sits in the bottom gutter")
  Assert.isTrue(box.x + box.width <= 186, "the affordance ends inside its gutter")
  Assert.isTrue(box.y + box.height <= 189, "the affordance stays inside its gutter")
  Assert.isTrue(type(SummaryScreenInterface.AFFORDANCE_LABEL) == "string", "the affordance carries a label")
end

function T.inspection_is_host_only_with_pointer_isolation()
  local service = openService(0x1F000002)
  local state = openSummary(service, "nativeLike")
  local before = state:status()
  Assert.equal(before.group, "info", "the summary opens on its first native group")
  local epoch = before.pictureEpoch
  state:updateFixed({ { type = "pointer_down", x = 160, y = 178 } })
  local inspecting = state:status()
  Assert.isTrue(inspecting.mainInspection, "the gutter affordance opens host inspection")
  Assert.equal(inspecting.group, "info", "opening inspection changes no native group")
  Assert.equal(inspecting.pictureEpoch, epoch, "opening inspection restarts no picture")
  state:updateFixed({ { type = "pointer_down", x = 20, y = 30 } })
  local held = state:status()
  Assert.equal(held.group, "info", "a press held across targets never fires")
  Assert.equal(held.pictureEpoch, epoch, "a held press advances no native clock")
  Assert.isTrue(held.mainInspection, "a held press never toggles the overlay")
  state:updateFixed({ { type = "pointer_up", x = 20, y = 30 } })
  Assert.isTrue(state:status().mainInspection, "releasing the held press changes nothing")
  state:updateFixed({ { type = "pointer_down", x = 20, y = 30 } })
  state:updateFixed({ { type = "pointer_up", x = 20, y = 30 } })
  local tapped = state:status()
  Assert.isFalse(tapped.mainInspection, "a fresh hidden tap closes the overlay")
  Assert.equal(tapped.group, "info", "closing taps fire no native target")
  Assert.isNil(state:takeResult(), "closing the overlay reports no terminal result")
  state:updateFixed({ { type = "menu" } })
  Assert.isTrue(state:status().mainInspection, "the menu edge toggles inspection open")
  state:updateFixed({ { type = "cancel" } })
  local closed = state:status()
  Assert.isFalse(closed.mainInspection, "cancel closes the overlay first")
  Assert.isTrue(closed.open, "closing the overlay keeps the summary open")
  Assert.isNil(state:takeResult(), "closing the overlay reports no terminal result")
  state:updateFixed({ { type = "menu" } })
  Assert.isTrue(state:status().mainInspection, "the menu edge toggles inspection open again")
  state:updateFixed({ { type = "menu" } })
  Assert.isFalse(state:status().mainInspection, "the menu edge toggles inspection closed")
  state:dispose()
end

function T.layout_changes_discard_the_overlay_without_native_side_effects()
  local service = openService(0x1F000003)
  local family = SummaryPresentationFixture.manifest()
  local lease = {}
  function lease:prepare(demand)
    return { kind = "ready", key = demand.key, assets = { manifest = family } }
  end
  function lease:release()
  end
  local measured = measurementFor("nativeLike")
  local state = SummaryScreenState.new({
    mons = service,
    manifest = family,
    initialSlot = 0,
    measureDisplay = function()
      return measured
    end,
    mode = "summary",
    context = function()
      return SummaryPresentationFixture.context(service:partyCount())
    end,
    readNavigation = function()
      return nil
    end,
    acquirePreparation = function()
      return lease
    end,
  })
  for _ = 1, 12 do
    state:updateFixed({})
  end
  state:updateFixed({ { type = "menu" } })
  Assert.isTrue(state:status().mainInspection, "inspection opens on the single display")
  measured = measurementFor("wide")
  state:updateFixed({})
  local moved = state:status()
  Assert.isFalse(moved.mainInspection, "a layout change discards the overlay")
  Assert.equal(moved.group, "info", "the layout change keeps the native group")
  Assert.isNil(state:takeResult(), "the layout change reports no terminal result")
  state:dispose()
end

function T.host_chrome_rides_the_interface_render_outside_native_raster()
  local service = openService(0x1F000004)
  local state = openSummary(service, "nativeLike")
  local status = state:status()
  local plan = assert(status.presentation, "the wrapper publishes its pane plan")
  local graphics = FakeGraphics.new({})
  local SummaryRenderer = require("libs.hgss.src.ui.SummaryRenderer")
  local renderer = SummaryRenderer.new({ graphics = graphics, text = {
    drawLineWithPalette = function(_, _, _, _, _)
    end,
    textWidth = function(_, _)
      return 0
    end,
  } })
  plan.render({ graphics = graphics, summaryRenderer = renderer }, status, plan)
  local affordances = 0
  for _, rectangle in ipairs(graphics.rectangles) do
    if rectangle.x == 144 and rectangle.y == 168 and rectangle.w == 42 and rectangle.h == 21 then
      affordances = affordances + 1
    end
  end
  Assert.equal(affordances, 1, "the interface draws its gutter affordance once")
  state:dispose()
end

return { tests = T }
