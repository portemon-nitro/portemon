-- Pure fixed-tick contract for the transient top-left area-name banner: one
-- eligible request at a time, one latest pending request, source-equivalent
-- elapsed timing, and no re-entry without a fresh event. The controller never
-- touches presentation or the message cache: style eligibility and the native
-- section title arrive through the injected selector and resolver.

local Assert = require("tests.support.Assert")

local T = {}

-- The controller is the module under test, so its absence must fail as the
-- missing behavior, not as a suite load error.
local function banner(behavior)
  local ok, moduleOrError = pcall(require, "libs.hgss.src.ui.FieldMapNameBanner")
  Assert.isTrue(ok, behavior .. " is missing: the map-name banner controller is unavailable")
  local module = moduleOrError
  Assert.isTrue(type(module.new) == "function", behavior .. " is missing: the banner exposes no constructor")
  return module
end

-- Two eligible towns sharing one native section id, plus a route on another
-- section and an interior that carries no compiled banner style.
local STYLE_BY_MAP_ID = { [60] = 0, [61] = 0, [67] = 5 }

local TITLES = {
  [5] = "NEW BARK TOWN",
  [6] = "ROUTE 29",
}

local function controller(behavior)
  local module = banner(behavior)
  return module.new({
    styleByMapId = STYLE_BY_MAP_ID,
    resolveTitle = function(sectionId)
      return assert(TITLES[sectionId], "fixture has no title for section " .. tostring(sectionId))
    end,
  })
end

local function statusOf(instance)
  return instance:status()
end

-- Advances fixed ticks until `predicate` holds or `limit` ticks elapse;
-- returns the number of ticks consumed.
local function tickUntil(instance, predicate, limit)
  for tick = 0, limit do
    if predicate() then
      return tick
    end
    instance:updateFixed()
  end
  return limit
end

function T.an_eligible_map_shows_its_native_section_title_and_style()
  local instance = controller("eligible area-name requests")
  Assert.isNil(statusOf(instance), "an untouched banner is hidden")
  Assert.isTrue(instance:request(60, 5), "an eligible map requests a banner")

  local status = assert(statusOf(instance), "an eligible request must publish a visible banner")
  Assert.equal(status.title, "NEW BARK TOWN", "the banner shows the native section title")
  Assert.equal(status.styleKey, 0, "the banner carries the compiled style for its destination")
  Assert.equal(status.scrollOffset, 38, "an entering banner starts at the source BG scroll displacement")
end

function T.an_ineligible_building_never_shows_and_never_blanks_a_visible_banner()
  local instance = controller("ineligible destinations")
  Assert.isFalse(instance:request(63, 5), "an interior without a compiled style is ineligible")
  Assert.isNil(statusOf(instance), "an ineligible request leaves the banner hidden")

  Assert.isTrue(instance:request(60, 5), "a later eligible request still shows")
  local shown = assert(statusOf(instance), "the eligible banner is visible")
  Assert.isFalse(instance:request(63, 5), "an ineligible request while visible is rejected")
  local stillShown = assert(statusOf(instance), "an ineligible request must not blank a visible banner")
  Assert.equal(stillShown.title, shown.title, "the visible title is untouched")
end

function T.a_committed_warp_ignores_section_equality()
  local instance = controller("same-section arrivals")
  -- Two distinct eligible maps share the same native section id; a warp
  -- between them must still announce the destination.
  Assert.isTrue(instance:request(60, 5), "the first same-section map requests")
  Assert.isTrue(instance:request(61, 5), "a same-section destination still requests")
end

function T.entry_hold_and_exit_follow_the_source_display_frame_cadence()
  local instance = controller("area-name timing")
  Assert.isTrue(instance:request(60, 5), "the banner starts")
  Assert.equal(assert(statusOf(instance)).scrollOffset, 38, "the entry starts at the source displacement")

  local entryTicks = tickUntil(instance, function()
    local status = statusOf(instance)
    return status == nil or status.scrollOffset == 0
  end, 12)
  local entered = assert(statusOf(instance), "the banner must remain visible after entering")
  Assert.equal(entered.scrollOffset, 0, "the entered banner rests at displacement zero")
  Assert.isTrue(entryTicks <= 6, "the ~1/6s entry elapses in at most six 30 Hz ticks")

  Assert.notNil(statusOf(instance), "the banner is still visible after the entry ticks")
  -- The 60 retail-display-frame hold is one second: at two display frames per
  -- tick it spans thirty fixed ticks, not sixty.
  local holdTicks = tickUntil(instance, function()
    return statusOf(instance) == nil
  end, 30)
  Assert.notNil(statusOf(instance), "the banner still holds after thirty fixed ticks")

  local total = entryTicks + holdTicks + tickUntil(instance, function()
    return statusOf(instance) == nil
  end, 25)
  Assert.isNil(statusOf(instance), "the banner clears after its hold and exit")
  Assert.isTrue(total >= 33, "the banner outlives a bare entry/exit (" .. tostring(total) .. " ticks)")
  Assert.isTrue(total <= 54, "the 60-frame hold is not copied as sixty 30 Hz ticks (" .. tostring(total) .. " ticks)")
end

function T.a_repeated_request_replaces_the_pending_art_with_the_latest_only()
  local instance = controller("interrupted banners")
  Assert.isTrue(instance:request(60, 5), "the first banner starts")

  -- Interrupt while entering: the active art keeps showing while it departs,
  -- and the newest request replaces any earlier pending one.
  instance:updateFixed()
  local interrupting = assert(statusOf(instance), "the first banner is still entering")
  Assert.equal(interrupting.title, "NEW BARK TOWN", "the departing banner keeps its own title")
  Assert.isTrue(instance:request(67, 6), "an interrupting request is accepted")

  local outgoing = assert(statusOf(instance), "the departing banner stays visible")
  Assert.equal(outgoing.title, "NEW BARK TOWN", "the pending title does not replace the active art early")
  Assert.isTrue(
    outgoing.scrollOffset > interrupting.scrollOffset,
    "the active art slides out from its current position"
  )

  local appeared = tickUntil(instance, function()
    local status = statusOf(instance)
    return status ~= nil and status.title == "ROUTE 29"
  end, 40)
  Assert.isTrue(appeared <= 20, "the latest pending banner replaces the old art without stalling")
  local replaced = assert(statusOf(instance), "the latest banner is visible")
  Assert.equal(replaced.styleKey, 5, "the replacement carries its own compiled style")
  Assert.equal(replaced.scrollOffset, 38, "the replacement restarts the entry from the source displacement")

  -- The older banner must never re-appear after its replacement began.
  tickUntil(instance, function()
    return statusOf(instance) == nil
  end, 40)
  Assert.isNil(statusOf(instance), "the replacement banner eventually clears")
end

function T.no_new_event_keeps_the_banner_hidden()
  local instance = controller("idle banners")
  Assert.isTrue(instance:request(60, 5), "the banner shows once")
  tickUntil(instance, function()
    return statusOf(instance) == nil
  end, 60)
  Assert.isNil(statusOf(instance), "the banner cleared")
  for _ = 1, 10 do
    instance:updateFixed()
  end
  Assert.isNil(statusOf(instance), "ticking without a new event must not re-enter the banner")
end

return { tests = T }
