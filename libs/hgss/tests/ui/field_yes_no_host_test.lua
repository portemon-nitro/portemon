local Assert = require("tests.support.Assert")
local FieldDialogueFixture = require("tests.support.FieldDialogueFixture")
local FieldDialogueTheme = require("libs.hgss.src.ui.FieldDialogueTheme")
local FieldYesNoHost = require("libs.hgss.src.ui.FieldYesNoHost")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")

local T = {}

local function fakeInput()
  return {
    began = {},
    cleared = 0,
    beginUi = function(self, tick)
      self.began[#self.began + 1] = tick
    end,
    clearUi = function(self)
      self.cleared = self.cleared + 1
    end,
  }
end

local function singleTopology()
  return ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 640, height = 480 },
    role = "world",
    touch = false,
  })
end

local function dualTopology()
  return ScreenTopology.dualDisplay({
    id = "upper",
    rect = { x = 0, y = 0, width = 256, height = 192 },
    role = "world",
    touch = false,
  }, {
    id = "lower",
    rect = { x = 256, y = 0, width = 256, height = 192 },
    role = "auxiliary",
    touch = false,
  })
end

---@param overrides { topology: table<string, unknown> }?
---@return fun(): FieldYesNoHost.PresentationContext
local function fixedContext(overrides)
  local resolved = {
    topology = singleTopology(),
    bounds = { x = 0, y = 0, width = 640, height = 480 },
    dialogueBox = { x = 100, y = 100, width = 200, height = 80 },
    preferredScale = 1,
  }
  for key, value in pairs(overrides or {}) do
    resolved[key] = value
  end
  return function()
    return resolved
  end
end

local function productionMeasure()
  return FieldDialogueTheme.measureText(FieldDialogueFixture.fontDef())
end

---@param opts { measureText: (fun(text: string): number)?, presentation: (fun(): FieldYesNoHost.PresentationContext)?, yesText: string?, noText: string? }?
local function openHost(opts)
  opts = opts or {}
  local input = fakeInput()
  local host = FieldYesNoHost.new({
    width = 640,
    height = 480,
    input = input --[[@as FieldInput]],
    screenTopology = singleTopology(),
    measureText = opts.measureText or productionMeasure(),
    presentation = opts.presentation or fixedContext(),
  })
  host:openChoice({
    yesText = opts.yesText or "YES",
    noText = opts.noText or "NO",
    frameIndex = 1,
  }, 41)
  return host, input
end

local function rowCenter(host, row)
  local presentation = assert(host:presentation(), "choice must be open to resolve its rows")
  local content = assert(presentation.layout.content, "choice layout must publish its content box")
  local placement = assert(presentation.layout.placement, "choice layout must publish its placement")
  local origin = assert(placement.origin, "choice placement must publish its content origin")
  return origin.x + (content.x + content.width / 2) * placement.scale,
    origin.y + (content.y + row * 16 + 8) * placement.scale
end

function T.opening_starts_one_modal_lifetime_and_closing_clears_it()
  local host, input = openHost()
  Assert.isTrue(host:isModal())
  Assert.deepEqual(input.began, { 41 })
  local presentation = assert(host:presentation(), "open choice publishes its presentation")
  Assert.equal(presentation.status.selectedIndex, 0)
  Assert.equal(presentation.status.yesText, "YES")
  Assert.equal(presentation.status.noText, "NO")
  Assert.equal(presentation.status.frameIndex, 1)
  host:syncSelection(1)
  Assert.equal(assert(host:presentation()).status.selectedIndex, 1)
  host:close()
  Assert.isFalse(host:isModal())
  Assert.isNil(host:presentation())
  Assert.equal(input.cleared, 1)
  host:close()
  Assert.equal(input.cleared, 1, "closing an idle host stays silent")
end

function T.adapted_body_follows_measured_labels_while_source_stays_fixed()
  local host = openHost()
  local layout = assert(host:presentation()).layout
  Assert.equal(layout.presentation, "adapted")
  Assert.isTrue(layout.content.width < 48, "short labels shed unused source padding")
  Assert.equal(layout.content.width % 8, 0, "adapted width stays on the tile grid")
  Assert.equal(layout.content.height, 32, "adapted height keeps the two-row body")

  local wide = openHost({ yesText = "YES, PLEASE", noText = "NO, THANK YOU" })
  local wideLayout = assert(wide:presentation()).layout
  Assert.isTrue(
    wideLayout.content.width >= layout.content.width,
    "wider labels must not shrink the adapted body"
  )
  Assert.equal(wideLayout.content.width % 8, 0, "grown adapted width stays on the tile grid")
  Assert.isTrue(wideLayout.content.width <= 48, "adapted body never exceeds the source width for padding")

  local native, _ = openHost({ presentation = fixedContext({ topology = dualTopology() }) })
  local nativeLayout = assert(native:presentation()).layout
  Assert.equal(nativeLayout.presentation, "source")
  Assert.deepEqual(
    nativeLayout.content,
    { x = 200, y = 104, width = 48, height = 32 },
    "dual-display geometry stays source-exact"
  )
end

function T.same_row_press_and_release_focuses_and_confirms()
  local host = openHost()
  local x, y = rowCenter(host, 1)
  local translated = host:inputEvents({ { type = "pointer_down", pointerId = "touch", x = x, y = y } })
  Assert.deepEqual(translated, { { type = "focus", row = 1 } })
  translated = host:inputEvents({ { type = "pointer_up", pointerId = "touch", x = x, y = y } })
  Assert.deepEqual(translated, { { type = "focus", row = 1 }, { type = "confirm" } })
end

function T.dragged_and_outside_gestures_answer_nothing()
  local host = openHost()
  local x, y = rowCenter(host, 0)
  host:inputEvents({ { type = "pointer_down", pointerId = "touch", x = x, y = y } })
  local dragged = host:inputEvents({
    { type = "pointer_move", pointerId = "touch", x = x + 160, y = y + 160 },
    { type = "pointer_up", pointerId = "touch", x = x + 160, y = y + 160, dragged = true },
  })
  Assert.deepEqual(dragged, {}, "a dragged release confirms nothing")

  local outside = host:inputEvents({
    { type = "pointer_down", pointerId = "other", x = 4, y = 4 },
    { type = "pointer_up", pointerId = "other", x = 8, y = 8 },
  })
  Assert.deepEqual(outside, {}, "an outside gesture confirms nothing")

  local releaseElsewhere = host:inputEvents({
    { type = "pointer_down", pointerId = "third", x = x, y = y },
  })
  Assert.equal(#releaseElsewhere, 1, "pressing a row still focuses it")
  local elsewhereX, elsewhereY = rowCenter(host, 1)
  Assert.deepEqual(
    host:inputEvents({ { type = "pointer_up", pointerId = "third", x = elsewhereX, y = elsewhereY } }),
    {},
    "releasing on another row confirms nothing"
  )
end

function T.only_the_captured_pointer_completes_its_gesture()
  local host = openHost()
  local x, y = rowCenter(host, 0)
  host:inputEvents({ { type = "pointer_down", pointerId = "first", x = x, y = y } })
  Assert.deepEqual(
    host:inputEvents({ { type = "pointer_down", pointerId = "second", x = x, y = y } }),
    {},
    "a second press while captured is ignored"
  )
  Assert.deepEqual(
    host:inputEvents({ { type = "pointer_up", pointerId = "second", x = x, y = y } }),
    {},
    "a foreign release cannot complete the captured gesture"
  )
  Assert.deepEqual(
    host:inputEvents({ { type = "pointer_up", pointerId = "first", x = x, y = y } }),
    { { type = "focus", row = 0 }, { type = "confirm" } },
    "the captured pointer still completes after foreign events"
  )
end

function T.resize_cancels_a_held_gesture()
  local host = openHost()
  local x, y = rowCenter(host, 0)
  host:inputEvents({ { type = "pointer_down", pointerId = "touch", x = x, y = y } })
  host:resize(640, 480)
  Assert.deepEqual(
    host:inputEvents({ { type = "pointer_up", pointerId = "touch", x = x, y = y } }),
    {},
    "a resize invalidates the held gesture"
  )
  Assert.isTrue(host:isModal(), "the choice itself survives the resize")
end

function T.keyboard_events_pass_through_and_layout_stays_pure_for_foreign_choices()
  local host = openHost()
  Assert.deepEqual(
    host:inputEvents({
      { type = "navigate", direction = "down" },
      { type = "confirm" },
      { type = "cancel" },
    }),
    {
      { type = "navigate", direction = "down" },
      { type = "confirm" },
      { type = "cancel" },
    }
  )
  local idle = FieldYesNoHost.new({
    width = 640,
    height = 480,
    input = fakeInput() --[[@as FieldInput]],
    screenTopology = singleTopology(),
    measureText = productionMeasure(),
    presentation = fixedContext(),
  })
  local layout = idle:layoutFor({ active = true, selectedIndex = 1, yesText = "YES", noText = "NO" })
  Assert.equal(layout.presentation, "adapted")
  Assert.isFalse(idle:isModal(), "pure layout never starts a modal lifetime")
end

function T.unknown_events_and_double_open_fail_loudly()
  local host = openHost()
  local ok, _ = pcall(host.inputEvents, host, { { type = "hover" } })
  Assert.isFalse(ok, "unknown UI events must not reach the task silently")
  local openOk, _ = pcall(host.openChoice, host, { yesText = "YES", noText = "NO" }, 42)
  Assert.isFalse(openOk, "opening an active choice is a composition error")
end

local function borrowedStatus()
  return { active = true, selectedIndex = 0, yesText = "YES", noText = "NO" }
end

local function borrowedRowCenter(host, row)
  local layout = host:layoutFor(borrowedStatus())
  local content = assert(layout.content, "borrowed layout must publish its content box")
  local placement = assert(layout.placement, "borrowed layout must publish its placement")
  local origin = assert(placement.origin, "borrowed placement must publish its content origin")
  return origin.x + (content.x + content.width / 2) * placement.scale,
    origin.y + (content.y + row * 16 + 8) * placement.scale
end

function T.borrowed_choice_translates_pointer_without_a_live_lifetime()
  local idle = FieldYesNoHost.new({
    width = 640,
    height = 480,
    input = fakeInput() --[[@as FieldInput]],
    screenTopology = singleTopology(),
    measureText = productionMeasure(),
    presentation = fixedContext(),
  })
  local x, y = borrowedRowCenter(idle, 0)
  Assert.deepEqual(
    idle:inputEventsFor(borrowedStatus(), { { type = "pointer_down", pointerId = "touch", x = x, y = y } }),
    { { type = "focus", row = 0 } }
  )
  Assert.deepEqual(
    idle:inputEventsFor(borrowedStatus(), { { type = "pointer_up", pointerId = "touch", x = x, y = y } }),
    { { type = "focus", row = 0 }, { type = "confirm" } },
    "a same-row borrowed release focuses then confirms"
  )
  Assert.isFalse(idle:isModal(), "borrowed translation never starts a live modal lifetime")
end

function T.borrowed_gestures_share_live_rejection_rules()
  local idle = FieldYesNoHost.new({
    width = 640,
    height = 480,
    input = fakeInput() --[[@as FieldInput]],
    screenTopology = singleTopology(),
    measureText = productionMeasure(),
    presentation = fixedContext(),
  })
  local x, y = borrowedRowCenter(idle, 0)
  idle:inputEventsFor(borrowedStatus(), { { type = "pointer_down", pointerId = "touch", x = x, y = y } })
  local otherX, otherY = borrowedRowCenter(idle, 1)
  Assert.deepEqual(
    idle:inputEventsFor(borrowedStatus(), { { type = "pointer_up", pointerId = "touch", x = otherX, y = otherY } }),
    {},
    "a cross-row borrowed release confirms nothing"
  )
  idle:inputEventsFor(borrowedStatus(), { { type = "pointer_down", pointerId = "drag", x = x, y = y } })
  Assert.deepEqual(
    idle:inputEventsFor(
      borrowedStatus(),
      { { type = "pointer_up", pointerId = "drag", x = x + 160, y = y + 160, dragged = true } }
    ),
    {},
    "a dragged borrowed release confirms nothing"
  )
  Assert.deepEqual(
    idle:inputEventsFor(borrowedStatus(), {
      { type = "pointer_down", pointerId = "outside", x = 4, y = 4 },
      { type = "pointer_up", pointerId = "outside", x = 8, y = 8 },
    }),
    {},
    "an outside borrowed gesture confirms nothing"
  )
end

function T.borrowed_capture_is_independent_of_live_capture()
  local host = openHost()
  local liveX, liveY = rowCenter(host, 0)
  host:inputEvents({ { type = "pointer_down", pointerId = "live", x = liveX, y = liveY } })
  local x, y = borrowedRowCenter(host, 1)
  Assert.deepEqual(
    host:inputEventsFor(borrowedStatus(), { { type = "pointer_down", pointerId = "live", x = x, y = y } }),
    { { type = "focus", row = 1 } },
    "a borrowed press completes even while the live gesture is held"
  )
  Assert.deepEqual(
    host:inputEventsFor(borrowedStatus(), { { type = "pointer_up", pointerId = "live", x = x, y = y } }),
    { { type = "focus", row = 1 }, { type = "confirm" } }
  )
  Assert.deepEqual(
    host:inputEvents({ { type = "pointer_up", pointerId = "live", x = liveX, y = liveY } }),
    { { type = "focus", row = 0 }, { type = "confirm" } },
    "the held live gesture still completes on its own row"
  )
end

function T.borrowed_capture_resets_on_demand_resize_and_topology()
  local idle = FieldYesNoHost.new({
    width = 640,
    height = 480,
    input = fakeInput() --[[@as FieldInput]],
    screenTopology = singleTopology(),
    measureText = productionMeasure(),
    presentation = fixedContext(),
  })
  local x, y = borrowedRowCenter(idle, 0)
  idle:inputEventsFor(borrowedStatus(), { { type = "pointer_down", pointerId = "touch", x = x, y = y } })
  idle:clearBorrowedChoice()
  Assert.deepEqual(
    idle:inputEventsFor(borrowedStatus(), { { type = "pointer_up", pointerId = "touch", x = x, y = y } }),
    {},
    "clearing borrowed capture drops the stale release"
  )
  idle:inputEventsFor(borrowedStatus(), { { type = "pointer_down", pointerId = "held", x = x, y = y } })
  idle:resize(640, 480)
  Assert.deepEqual(
    idle:inputEventsFor(borrowedStatus(), { { type = "pointer_up", pointerId = "held", x = x, y = y } }),
    {},
    "a resize invalidates the held borrowed gesture"
  )
  idle:inputEventsFor(borrowedStatus(), { { type = "pointer_down", pointerId = "topo", x = x, y = y } })
  idle:setScreenTopology(singleTopology())
  Assert.deepEqual(
    idle:inputEventsFor(borrowedStatus(), { { type = "pointer_up", pointerId = "topo", x = x, y = y } }),
    {},
    "a topology change invalidates the held borrowed gesture"
  )
end

function T.borrowed_status_shape_fails_loudly()
  local idle = FieldYesNoHost.new({
    width = 640,
    height = 480,
    input = fakeInput() --[[@as FieldInput]],
    screenTopology = singleTopology(),
    measureText = productionMeasure(),
    presentation = fixedContext(),
  })
  local ok, _ = pcall(idle.inputEventsFor, idle, { active = false, selectedIndex = 0, yesText = "YES", noText = "NO" }, {})
  Assert.isFalse(ok, "an inactive borrowed status is a composition error")
  local badOk, _ =
    pcall(idle.inputEventsFor, idle, { active = true, selectedIndex = 2, yesText = "YES", noText = "NO" }, {})
  Assert.isFalse(badOk, "a borrowed selection outside the two rows is invalid")
end

return { tests = T }
