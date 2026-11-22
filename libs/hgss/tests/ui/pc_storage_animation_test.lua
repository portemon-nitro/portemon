-- Presentation-only PC Storage animations: source cursor slide, linear mon
-- moves, release shrink and the 23-step box scroll.

local Assert = require("tests.support.Assert")
local PcStorageAnimation = require("libs.hgss.src.ui.PcStorageAnimation")

local T = { tests = {} }

local function mon(personality)
  return { personality = personality, iconKey = "icon-" .. tostring(personality) }
end

local function view(options)
  options = options or {}
  return {
    mode = 2,
    activeBox = options.activeBox or 0,
    boxCount = 18,
    tray = options.tray or "closed",
    wallpaperId = options.wallpaperId or 0,
    boxSlots = options.boxSlots or {},
    party = options.party or {},
    carry = options.carry,
    release = options.release,
    cursor = options.cursor or { x = 24, y = 36 },
  }
end

function T.tests.cursor_slide_steps_quarters_then_snaps_to_the_anchor()
  local animator = PcStorageAnimation.new()
  animator:step(view({ cursor = { x = 24, y = 36 } }))
  local target = view({ cursor = { x = 48, y = 36 } })
  local seen = {}
  for _ = 1, 5 do
    seen[#seen + 1] = animator:step(target).cursor.x
  end
  Assert.deepEqual(seen, { 30, 36, 42, 48, 48 }, "the source slides four steps and snaps on the fifth")
  Assert.deepEqual(animator:step(target).cursor, { x = 48, y = 36 }, "a settled cursor stays on its anchor")
end

function T.tests.a_mon_move_runs_eight_linear_steps()
  local animator = PcStorageAnimation.new()
  local occupied = mon(7)
  animator:step(view({ boxSlots = { occupied } }))
  local moved = view({ boxSlots = { false, occupied } })
  local xs = {}
  for _ = 1, 8 do
    local frame = animator:step(moved)
    xs[#xs + 1] = frame.icons and frame.icons.box[1] and frame.icons.box[1].x or nil
  end
  Assert.deepEqual(xs, { 27, 30, 33, 36, 39, 42, 45, 48 }, "moves use one eighth of the delta per step")
  Assert.isNil(animator:step(moved).icons, "the destination icon is parked after the flight")
end

function T.tests.party_shift_moves_every_later_slot()
  local animator = PcStorageAnimation.new()
  local a, b = mon(1), mon(2)
  animator:step(view({ party = { a, b } }))
  local frame = animator:step(view({ party = { b } }))
  Assert.notNil(frame.icons.party[0], "the surviving mon flies to the vacated slot")
  Assert.equal(frame.icons.party[0].mon, b, "the moving icon carries the surviving mon")
end

function T.tests.release_projects_the_screen_state_shrink_and_grow()
  local animator = PcStorageAnimation.new()
  local gone = mon(9)
  -- The mon is still in custody while the state publishes the shrink; the
  -- animation must never infer the removal from the slot data itself.
  local function releasing(tick, phase)
    return view({
      party = { gone },
      release = { phase = phase, tick = tick, address = { kind = "party", slot = 0 }, mon = gone },
    })
  end
  animator:step(releasing(0, "shrink"))
  local first = animator:step(releasing(0, "shrink"))
  Assert.isTrue(math.abs(first.release[1].scale - 0.975) < 1e-9, "the first shrink tick removes one source step")
  Assert.deepEqual(
    { first.release[1].domain, first.release[1].slot },
    { "party", 0 },
    "the shrink renders on the releasing cell"
  )
  local last = animator:step(releasing(39, "shrink"))
  Assert.isTrue(math.abs(last.release[1].scale - 0.0) < 1e-9, "the fortieth shrink tick reaches zero")
  Assert.isNil(animator:step(releasing(40, "hidden")).release, "the state hides the icon after the shrink")

  local grow = animator:step(releasing(0, "grow"))
  Assert.isTrue(math.abs(grow.release[1].scale - 0.05) < 1e-9, "a protected move grows back one step per tick")
  local grown = animator:step(releasing(19, "grow"))
  Assert.isTrue(math.abs(grown.release[1].scale - 1.0) < 1e-9, "the twentieth grow tick returns the icon")
end

function T.tests.box_scroll_slides_both_wallpapers_and_wraps_icons()
  local animator = PcStorageAnimation.new()
  local outgoing = { mon(1), mon(2) }
  local incoming = { mon(3), mon(4) }
  animator:step(view({ activeBox = 0, wallpaperId = 0, boxSlots = outgoing }))
  local nextBox = view({ activeBox = 1, wallpaperId = 1, boxSlots = incoming })
  local first = animator:step(nextBox)
  Assert.deepEqual(first.wallpaper, { { id = 0, x = -8 }, { id = 1, x = 176 } }, "a higher box scrolls the walls left")
  Assert.equal(first.icons.box[0].mon, outgoing[1], "the outgoing icons lead the scroll")
  local wrapped, last
  for step = 2, 23 do
    local frame = animator:step(nextBox)
    if step == 4 then
      wrapped = frame
    end
    last = frame
  end
  Assert.equal(last.wallpaper[1].x, -184, "twenty-three steps move the outgoing wallpaper one span")
  Assert.equal(last.wallpaper[2].x, 0, "the incoming wallpaper lands at its home")
  Assert.equal(last.icons.box[0].x, 24, "the icon grid returns to its home column")
  Assert.equal(wrapped.icons.box[0].x, 176, "an icon wraps to the far side mid-scroll")
  Assert.equal(wrapped.icons.box[0].mon, incoming[1], "the wrapped icon shows the incoming box's mon")
end

function T.tests.held_item_flight_follows_the_item_to_its_new_mon()
  local animator = PcStorageAnimation.new()
  local giver = { personality = 4, heldItem = "POTION", itemIconKey = "potion", iconKey = "icon-4" }
  local taker = { personality = 5, heldItem = "NONE", iconKey = "icon-5" }
  animator:step(view({ boxSlots = { giver, taker } }))
  local after = view({
    boxSlots = {
      { personality = 4, heldItem = "NONE", iconKey = "icon-4" },
      { personality = 5, heldItem = "POTION", itemIconKey = "potion", iconKey = "icon-5" },
    },
  })
  local frame = animator:step(after)
  Assert.notNil(frame.item, "an item moving between mons flies")
  Assert.equal(frame.item.iconKey, "potion", "the flight carries the moved item icon")
  Assert.equal(math.floor(frame.item.x), 35, "the flight starts one eighth of the way from the +8 carried offset")
end

function T.tests.pick_up_bobs_the_cursor_once()
  local animator = PcStorageAnimation.new()
  animator:step(view({ cursor = { x = 24, y = 36 } }))
  local carried = view({ cursor = { x = 24, y = 36 }, carry = { kind = "mon" } })
  local first = animator:step(carried)
  Assert.equal(first.cursor.y, 38, "the source dips two pixels on the first held frame")
  local last
  for _ = 1, 8 do
    last = animator:step(carried)
  end
  Assert.equal(last.cursor.y, 36, "the cursor returns to its anchor after the dip")
end

return T
