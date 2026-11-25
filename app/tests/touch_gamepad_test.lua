-- App-private virtual controller geometry, gesture ownership, and lifetime.

local Assert = require("tests.support.Assert")
local FakeGraphics = require("tests.support.FakeGraphics")
local Game = require("game.src.Game")

local T = {}
local TouchGamepad

local function controllerModule()
  local ok, moduleOrError = pcall(require, "app.src.input.TouchGamepad")
  Assert.isTrue(ok, "the app-private touch controller must be available: " .. tostring(moduleOrError))
  TouchGamepad = moduleOrError
  return TouchGamepad
end

local function recordingRenderer()
  local calls = {}
  return {
    calls = calls,
    drawButton = function(_, rect, label, iconKey, visualState)
      local originX, originY = love.graphics.transformPoint(0, 0)
      local unitX = love.graphics.transformPoint(1, 0)
      local _, unitY = love.graphics.transformPoint(0, 1)
      calls[#calls + 1] = {
        rect = rect,
        label = label,
        iconKey = iconKey,
        visualState = visualState or {},
        originX = originX,
        originY = originY,
        unitX = unitX,
        unitY = unitY,
      }
    end,
  }
end

local function recordingChild(events, hooks)
  hooks = hooks or {}
  local child = { disposals = 0 }
  function child:gamepadpressed(joystick, button)
    events[#events + 1] = { "gamepadpressed", joystick:getID(), button }
    if hooks.pressed then
      hooks.pressed(button)
    end
  end
  function child:gamepadreleased(joystick, button)
    events[#events + 1] = { "gamepadreleased", joystick:getID(), button }
    if hooks.released then
      hooks.released(button)
    end
  end
  function child:gamepadaxis(joystick, axis, value)
    events[#events + 1] = { "gamepadaxis", joystick:getID(), axis, value }
  end
  function child:keypressed(key)
    events[#events + 1] = { "keypressed", key }
  end
  function child:keyreleased(key)
    events[#events + 1] = { "keyreleased", key }
  end
  function child:dispose()
    self.disposals = self.disposals + 1
  end
  return child
end

local function recordingGame(events, hooks)
  local game = Game.new({ onExit = function() end })
  game:setState(recordingChild(events, hooks))
  return game
end

local function portraitPad(renderer, game)
  local pad = controllerModule().new(renderer)
  pad:setGeometry(360, 800, { x = 0, y = 0, width = 360, height = 800 }, 1)
  pad:setTarget(game)
  return pad
end

local function clear(events)
  for index = #events, 1, -1 do
    events[index] = nil
  end
end

local function withGraphics(graphics, fn)
  local original = love.graphics
  rawset(love, "graphics", graphics)
  local ok, err = pcall(fn)
  rawset(love, "graphics", original)
  if not ok then
    error(err, 0)
  end
end

local function overlaps(a, b)
  return a.x < b.x + b.width and b.x < a.x + a.width and a.y < b.y + b.height and b.y < a.y + a.height
end

local function containsClosed(rect, x, y)
  return x >= rect.x and y >= rect.y and x <= rect.x + rect.width and y <= rect.y + rect.height
end

function T.every_virtual_button_maps_once_to_the_normal_gamepad_path()
  local events = {}
  local pad = portraitPad(recordingRenderer(), recordingGame(events))
  local controls = {
    { "dpup", 56, 648 },
    { "dpdown", 56, 744 },
    { "dpleft", 8, 696 },
    { "dpright", 128, 696 },
    { "a", 328, 720 },
    { "b", 280, 768 },
    { "x", 280, 672 },
    { "y", 232, 696 },
    { "leftshoulder", 48, 616 },
    { "rightshoulder", 312, 616 },
    { "start", 224, 616 },
    { "back", 136, 616 },
  }
  local expected = {}
  for index, control in ipairs(controls) do
    Assert.isTrue(pad:touchpressed(index, control[2], control[3]), control[1] .. " is captured")
    Assert.isTrue(pad:touchreleased(index, control[2], control[3]), control[1] .. " release is captured")
    expected[#expected + 1] = { "gamepadpressed", -1, control[1] }
    expected[#expected + 1] = { "gamepadreleased", -1, control[1] }
  end
  Assert.deepEqual(events, expected, "the finite virtual source emits exactly one paired edge per visible button")
end

function T.multitouch_refcounts_keep_one_first_press_and_one_last_release()
  local events = {}
  local pad = portraitPad(recordingRenderer(), recordingGame(events))
  Assert.isTrue(pad:touchpressed(1, 56, 672))
  Assert.isTrue(pad:touchpressed(2, 280, 768))
  Assert.isTrue(pad:touchpressed(3, 56, 672), "a second owner of the same direction is accepted")
  Assert.deepEqual(events, {
    { "gamepadpressed", -1, "dpup" },
    { "gamepadpressed", -1, "b" },
  }, "simultaneous movement/action and duplicate ownership produce no repeat edge")
  Assert.isTrue(pad:touchreleased(2, 280, 768))
  Assert.isTrue(pad:touchreleased(1, 56, 672))
  Assert.deepEqual(events, {
    { "gamepadpressed", -1, "dpup" },
    { "gamepadpressed", -1, "b" },
    { "gamepadreleased", -1, "b" },
  }, "releasing one of two direction owners keeps the token held")
  Assert.isTrue(pad:touchreleased(3, 56, 672))
  Assert.deepEqual(events, {
    { "gamepadpressed", -1, "dpup" },
    { "gamepadpressed", -1, "b" },
    { "gamepadreleased", -1, "b" },
    { "gamepadreleased", -1, "dpup" },
  }, "the last owner releases exactly once")
end

function T.dpad_drag_releases_before_pressing_and_never_emits_diagonals()
  local events = {}
  local pad = portraitPad(recordingRenderer(), recordingGame(events))
  Assert.isTrue(pad:touchpressed(1, 56, 672))
  Assert.isTrue(pad:touchmoved(1, 128, 696))
  Assert.isTrue(pad:touchmoved(1, 80, 720), "the neutral center remains captured")
  Assert.isTrue(pad:touchmoved(1, 104, 744), "an exact diagonal tie without a prior direction chooses vertical")
  Assert.isTrue(pad:touchmoved(1, 56, 744), "an exact diagonal tie retains the prior vertical direction")
  Assert.isTrue(pad:touchmoved(1, 180, 500), "leaving the group neutralizes but retains capture")
  Assert.isTrue(pad:touchreleased(1, 180, 500))
  Assert.deepEqual(events, {
    { "gamepadpressed", -1, "dpup" },
    { "gamepadreleased", -1, "dpup" },
    { "gamepadpressed", -1, "dpright" },
    { "gamepadreleased", -1, "dpright" },
    { "gamepadpressed", -1, "dpdown" },
    { "gamepadreleased", -1, "dpdown" },
  }, "drag transitions are ordered cardinal edges with neutral center/outside behavior")
end

function T.dpad_opposite_diagonal_ties_do_not_retain_an_inapplicable_cardinal()
  local events = {}
  local pad = portraitPad(recordingRenderer(), recordingGame(events))
  Assert.isTrue(pad:touchpressed(1, 56, 672))
  Assert.isTrue(pad:touchmoved(1, 104, 744), "down-right replaces a previous up with the tied vertical direction")
  Assert.isTrue(pad:touchmoved(1, 48, 688), "up-left replaces a previous down with the tied vertical direction")
  Assert.isTrue(pad:touchreleased(1, 48, 688))
  Assert.deepEqual(events, {
    { "gamepadpressed", -1, "dpup" },
    { "gamepadreleased", -1, "dpup" },
    { "gamepadpressed", -1, "dpdown" },
    { "gamepadreleased", -1, "dpdown" },
    { "gamepadpressed", -1, "dpup" },
    { "gamepadreleased", -1, "dpup" },
  }, "opposite diagonal ties choose vertical unless the previous cardinal is tied")
end

function T.face_shoulder_and_start_gestures_keep_their_original_button()
  local events = {}
  local pad = portraitPad(recordingRenderer(), recordingGame(events))
  local cases = {
    { "a", 328, 720, 280, 744 },
    { "leftshoulder", 48, 616, 136, 616 },
    { "start", 224, 616, 312, 616 },
  }
  local expected = {}
  for index, case in ipairs(cases) do
    Assert.isTrue(pad:touchpressed(index, case[2], case[3]))
    Assert.isTrue(pad:touchmoved(index, case[4], case[5]))
    Assert.isTrue(pad:touchmoved(index, 180, 500))
    Assert.isTrue(pad:touchmoved(index, case[2], case[3]))
    Assert.isTrue(pad:touchreleased(index, case[2], case[3]))
    expected[#expected + 1] = { "gamepadpressed", -1, case[1] }
    expected[#expected + 1] = { "gamepadreleased", -1, case[1] }
    expected[#expected + 1] = { "gamepadpressed", -1, case[1] }
    expected[#expected + 1] = { "gamepadreleased", -1, case[1] }
  end
  Assert.deepEqual(events, expected, "crossing another hit rectangle never transfers gesture ownership")
end

function T.blank_reservations_are_inert_and_outside_gestures_never_become_controls()
  local events = {}
  local pad = portraitPad(recordingRenderer(), recordingGame(events))
  Assert.isFalse(pad:touchpressed(1, 180, 500))
  Assert.isFalse(pad:touchmoved(1, 280, 720))
  Assert.isFalse(pad:touchreleased(1, 280, 720))
  Assert.isTrue(pad:touchpressed(2, 180, 700), "blank dock space is consumed")
  Assert.isTrue(pad:touchmoved(2, 180, 500), "a captured blank gesture remains consumed outside")
  Assert.isTrue(pad:touchreleased(2, 180, 500))
  Assert.deepEqual(events, {}, "reservation blanks and retail-origin gestures emit no gamepad edges")
end

function T.opposing_dpad_fingers_remain_distinct_token_holds()
  local events = {}
  local pad = portraitPad(recordingRenderer(), recordingGame(events))
  Assert.isTrue(pad:touchpressed(1, 56, 672))
  Assert.isTrue(pad:touchpressed(2, 56, 744))
  Assert.isTrue(pad:touchreleased(1, 56, 672))
  Assert.isTrue(pad:touchreleased(2, 56, 744))
  Assert.deepEqual(events, {
    { "gamepadpressed", -1, "dpup" },
    { "gamepadpressed", -1, "dpdown" },
    { "gamepadreleased", -1, "dpup" },
    { "gamepadreleased", -1, "dpdown" },
  }, "the adapter does not collapse opposing fingers into one direction")
end

function T.geometry_is_value_stable_and_safe_area_only_changes_cancel_once()
  local events = {}
  local game = recordingGame(events)
  local pad = portraitPad(recordingRenderer(), game)
  Assert.isFalse(pad:setGeometry(360, 800, { x = 0, y = 0, width = 360, height = 800 }, 1))
  local first = pad:topology()
  local second = pad:topology()
  Assert.deepEqual(first, second)
  Assert.isFalse(first == second, "topology calls return detached copies")
  first.surfaces[1].occupiedRegions[1].width = 1
  Assert.equal(pad:topology().surfaces[1].occupiedRegions[1].width, 360, "callers cannot mutate the retained plan")
  Assert.isTrue(pad:touchpressed(1, 56, 672))
  clear(events)
  Assert.isFalse(pad:setGeometry(360, 800, { x = 0, y = 0, width = 360, height = 800 }, 1))
  Assert.deepEqual(events, {}, "equal facts do not cancel a hold")
  Assert.isTrue(pad:setGeometry(360, 800, { x = 12, y = 20, width = 336, height = 780 }, 1))
  Assert.deepEqual(events, { { "gamepadreleased", -1, "dpup" } }, "an inset-only change cancels exactly once")
  Assert.isTrue(pad:touchmoved(1, 68, 672))
  Assert.isTrue(pad:touchreleased(1, 68, 672))
  Assert.equal(#events, 1, "the canceled tail stays suppressed after republication")
  Assert.isTrue(pad:touchpressed(1, 68, 672), "a new down may reuse the host ID after its stale up")
  Assert.deepEqual(events, {
    { "gamepadreleased", -1, "dpup" },
    { "gamepadpressed", -1, "dpup" },
  })
  Assert.isTrue(pad:touchreleased(1, 68, 672))
  Assert.isFalse(game.terminal, "geometry changes never dispose the borrowed Game")
end

function T.portrait_and_landscape_publish_safe_separate_reservations_and_compact_controls_fit()
  local renderer = recordingRenderer()
  local pad = controllerModule().new(renderer)
  pad:setGeometry(360, 800, { x = 0, y = 0, width = 360, height = 800 }, 1)
  local portrait = pad:topology().surfaces[1]
  Assert.deepEqual(portrait.rect, { x = 0, y = 0, width = 360, height = 800 })
  Assert.deepEqual(portrait.safeRect, portrait.rect)
  Assert.deepEqual(portrait.occupiedRegions, { { x = 0, y = 584, width = 360, height = 216 } })
  Assert.isTrue(portrait.touch)
  Assert.equal(portrait.role, "world")

  pad:setGeometry(800, 360, { x = 0, y = 0, width = 800, height = 360 }, 1)
  local landscape = pad:topology().surfaces[1]
  Assert.deepEqual(landscape.occupiedRegions, {
    { x = 0, y = 0, width = 160, height = 360 },
    { x = 640, y = 0, width = 160, height = 360 },
  })
  Assert.isFalse(overlaps(landscape.occupiedRegions[1], landscape.occupiedRegions[2]))

  pad:setGeometry(293, 257, { x = 13, y = 17, width = 280, height = 240 }, 2.25)
  local compact = pad:topology().surfaces[1]
  Assert.deepEqual(compact.safeRect, { x = 13, y = 17, width = 280, height = 240 })
  Assert.deepEqual(compact.occupiedRegions, {
    { x = 13, y = 17, width = 70, height = 240 },
    { x = 223, y = 17, width = 70, height = 240 },
  })
  Assert.isTrue(compact.occupiedRegions[1].width + compact.occupiedRegions[2].width <= compact.safeRect.width / 2)
  local ApplicationLayout = require("libs.ui.src.ApplicationLayout")
  local DisplayContext = require("libs.ui.src.DisplayContext")
  local measurement = DisplayContext.new({
    graphics = {
      getDimensions = function()
        return 293, 257
      end,
      getDPIScale = function()
        return 2.25
      end,
    },
    topologyProvider = function()
      return pad:topology()
    end,
  }):measure(293, 257)
  local usable = assert(ApplicationLayout.selectSurfaces(measurement).primary.usableBounds)
  Assert.deepEqual(
    usable,
    { x = 83, y = 17, width = 140, height = 240 },
    "compact rails leave positive central content"
  )

  local game = recordingGame({})
  pad:setTarget(game)
  clear(renderer.calls)
  local graphics = FakeGraphics.new()
  withGraphics(graphics, function()
    pad:draw()
  end)
  Assert.equal(graphics.pushDepth(), 0, "controller drawing restores the caller graphics stack")
  local painted = {}
  for _, call in ipairs(renderer.calls) do
    local originX, originY = call.originX, call.originY
    local unitX, unitY = call.unitX, call.unitY
    Assert.near(originX * 2.25, math.floor(originX * 2.25 + 0.5), 1e-9, "paint origins snap to physical pixels")
    Assert.near(originY * 2.25, math.floor(originY * 2.25 + 0.5), 1e-9, "paint origins snap to physical pixels")
    Assert.near((unitX - originX) * 2.25, 1, 1e-9, "compact glyph pitch rounds to one physical pixel")
    Assert.near((unitY - originY) * 2.25, 1, 1e-9, "compact vertical pitch matches")
    Assert.equal(call.rect.x, math.floor(call.rect.x))
    Assert.equal(call.rect.y, math.floor(call.rect.y))
    Assert.equal(call.rect.width, math.floor(call.rect.width))
    Assert.equal(call.rect.height, math.floor(call.rect.height))
    local hostRect = {
      x = originX + call.rect.x * (unitX - originX),
      y = originY + call.rect.y * (unitY - originY),
      width = call.rect.width * (unitX - originX),
      height = call.rect.height * (unitY - originY),
    }
    Assert.isTrue(containsClosed(compact.safeRect, hostRect.x, hostRect.y))
    Assert.isTrue(containsClosed(compact.safeRect, hostRect.x + hostRect.width, hostRect.y + hostRect.height))
    for _, other in ipairs(painted) do
      Assert.isFalse(overlaps(hostRect, other), "painted controls never overlap")
    end
    painted[#painted + 1] = hostRect
  end
  local labels = {}
  for _, call in ipairs(renderer.calls) do
    labels[call.label] = true
  end
  Assert.isTrue(labels.ST and labels.SEL, "compact Start/Select use their short labels")
  for _, label in ipairs({ "A", "B", "X", "Y", "L", "R" }) do
    Assert.isTrue(labels[label], label .. " keeps its compact label")
  end
end

function T.fractional_dpi_uses_integer_glyph_pitch_without_scaling_touch_coordinates()
  local renderer = recordingRenderer()
  local events = {}
  local pad = controllerModule().new(renderer)
  pad:setGeometry(360, 800, { x = 0, y = 0, width = 360, height = 800 }, 2.25)
  pad:setTarget(recordingGame(events))
  local graphics = FakeGraphics.new()
  withGraphics(graphics, function()
    pad:draw()
  end)
  Assert.isTrue(#renderer.calls > 0)
  for _, call in ipairs(renderer.calls) do
    Assert.near((call.unitX - call.originX) * 2.25, 2, 1e-9, "nominal glyphs use two physical pixels per source pixel")
    Assert.near((call.unitY - call.originY) * 2.25, 2, 1e-9, "vertical glyph pitch matches the physical grid")
  end
  Assert.isTrue(pad:touchpressed(1, 328, 720))
  clear(renderer.calls)
  withGraphics(graphics, function()
    pad:draw()
  end)
  local pressedA = false
  for _, call in ipairs(renderer.calls) do
    if call.label == "A" then
      pressedA = call.visualState.pressed == true
    end
  end
  Assert.isTrue(pressedA, "the borrowed button painter receives visible depressed feedback")
  Assert.isTrue(pad:touchreleased(1, 328, 720))
  Assert.deepEqual(events, {
    { "gamepadpressed", -1, "a" },
    { "gamepadreleased", -1, "a" },
  }, "host-unit touch coordinates are not multiplied by DPI")
end

function T.draw_is_inert_without_target_or_geometry_and_borrows_the_renderer()
  local renderer = recordingRenderer()
  local pad = controllerModule().new(renderer)
  local graphics = FakeGraphics.new()
  withGraphics(graphics, function()
    pad:draw()
  end)
  Assert.equal(#renderer.calls, 0)
  Assert.equal(#graphics.transforms, 0)
  pad:setGeometry(360, 800, { x = 0, y = 0, width = 360, height = 800 }, 1)
  withGraphics(graphics, function()
    pad:draw()
  end)
  Assert.equal(#renderer.calls, 0, "detached controllers publish topology but draw no chrome")
  local game = recordingGame({})
  pad:setTarget(game)
  pad:setTarget(nil)
  Assert.isFalse(game.terminal, "detaching does not dispose the borrowed Game")
  Assert.throws(function()
    controllerModule().new({})
  end, "the borrowed renderer contract is required")
end

function T.invalid_geometry_preserves_the_last_valid_plan()
  local pad = portraitPad(recordingRenderer(), recordingGame({}))
  local before = pad:topology()
  Assert.throws(function()
    pad:setGeometry(0, 800, { x = 0, y = 0, width = 360, height = 800 }, 1)
  end)
  Assert.throws(function()
    pad:setGeometry(360, 800, { x = 20, y = 0, width = 360, height = 800 }, 1)
  end)
  Assert.throws(function()
    pad:setGeometry(360, 800, { x = 0, y = 0, width = 360, height = 0 }, 1)
  end)
  Assert.deepEqual(pad:topology(), before, "invalid publication never falls back or damages the current plan")
end

function T.reentrant_child_replacement_suppresses_the_rest_of_the_gesture()
  local events = {}
  local game
  local replacement = recordingChild(events)
  local first = recordingChild(events, {
    pressed = function(button)
      if button == "dpup" then
        game:setState(replacement)
      end
    end,
  })
  game = Game.new({ onExit = function() end })
  game:setState(first)
  local pad = portraitPad(recordingRenderer(), game)
  Assert.isTrue(pad:touchpressed(1, 56, 672))
  Assert.equal(first.disposals, 1, "Game disposes the replaced child exactly once")
  Assert.isTrue(pad:touchmoved(1, 104, 696))
  Assert.isTrue(pad:touchreleased(1, 104, 696))
  Assert.deepEqual(
    events,
    { { "gamepadpressed", -1, "dpup" } },
    "no drag edge or stale release reaches the replacement"
  )
  Assert.isTrue(pad:touchpressed(2, 128, 696))
  Assert.isTrue(pad:touchreleased(2, 128, 696))
  Assert.deepEqual(events, {
    { "gamepadpressed", -1, "dpup" },
    { "gamepadpressed", -1, "dpright" },
    { "gamepadreleased", -1, "dpright" },
  }, "a fresh gesture works on the current child")
end

function T.reentrant_replacement_during_drag_release_blocks_the_next_press()
  local events = {}
  local game
  local replacement = recordingChild(events)
  local first = recordingChild(events, {
    released = function(button)
      if button == "dpup" then
        game:setState(replacement)
      end
    end,
  })
  game = Game.new({ onExit = function() end })
  game:setState(first)
  local pad = portraitPad(recordingRenderer(), game)
  Assert.isTrue(pad:touchpressed(1, 56, 672))
  Assert.isTrue(pad:touchmoved(1, 128, 696))
  Assert.isTrue(pad:touchreleased(1, 128, 696))
  Assert.deepEqual(events, {
    { "gamepadpressed", -1, "dpup" },
    { "gamepadreleased", -1, "dpup" },
  }, "the identity guard between release and press suppresses the replacement edge")
end

function T.reentrant_exit_during_press_stops_dispatch_and_preserves_suppression()
  local events = {}
  local game
  local child = recordingChild(events, {
    pressed = function(button)
      if button == "a" then
        game:exit({ kind = "quit" })
      end
    end,
  })
  game = Game.new({ onExit = function() end })
  game:setState(child)
  local pad = portraitPad(recordingRenderer(), game)
  Assert.isTrue(pad:touchpressed(1, 328, 720))
  pad:sync()
  Assert.isTrue(pad:touchmoved(1, 280, 744))
  Assert.isTrue(pad:touchreleased(1, 280, 744))
  Assert.deepEqual(
    events,
    { { "gamepadpressed", -1, "a" } },
    "exit invalidates the target without a release into disposed state"
  )
  local nextEvents = {}
  pad:setTarget(recordingGame(nextEvents))
  Assert.isFalse(pad:touchmoved(1, 280, 744), "suppression survives target replacement")
  Assert.isFalse(pad:touchreleased(1, 280, 744))
  Assert.isTrue(pad:touchpressed(1, 280, 744))
  Assert.isTrue(pad:touchreleased(1, 280, 744))
  Assert.deepEqual(nextEvents, {
    { "gamepadpressed", -1, "b" },
    { "gamepadreleased", -1, "b" },
  }, "the reused ID starts a fresh lifetime on the new target")
end

function T.cancel_is_idempotent_under_reentrancy_and_detach_keeps_tails_consumed()
  local events = {}
  local pad
  local game = recordingGame(events, {
    released = function()
      pad:cancel()
    end,
  })
  pad = portraitPad(recordingRenderer(), game)
  Assert.isTrue(pad:touchpressed(1, 56, 672))
  Assert.isTrue(pad:touchpressed(2, 280, 768))
  clear(events)
  pad:cancel()
  pad:cancel()
  Assert.equal(#events, 2, "reentrant cancellation releases each held token once")
  local released = {}
  for _, event in ipairs(events) do
    Assert.equal(event[1], "gamepadreleased")
    Assert.equal(event[2], -1)
    Assert.isNil(released[event[3]], "a token is not released twice")
    released[event[3]] = true
  end
  Assert.isTrue(released.b and released.dpup, "cancellation clears both movement and action")
  Assert.isTrue(pad:touchmoved(1, 56, 672))
  Assert.isTrue(pad:touchreleased(1, 56, 672))
  Assert.isTrue(pad:touchreleased(2, 280, 768))
  clear(events)
  Assert.isTrue(pad:touchpressed(3, 280, 768))
  pad:setTarget(nil)
  Assert.deepEqual(events, {
    { "gamepadpressed", -1, "b" },
    { "gamepadreleased", -1, "b" },
  }, "target detachment live-cancels the old owner before dropping the borrow")
  Assert.isTrue(pad:touchmoved(3, 280, 768))
  Assert.isTrue(pad:touchreleased(3, 280, 768))
  Assert.equal(#events, 2, "stale tails remain consumed after detachment")
  Assert.isFalse(pad:touchpressed(3, 280, 768), "a detached controller establishes no new gesture")
  Assert.isFalse(game.terminal)
end

function T.sync_clears_a_disposed_owner_without_crossing_into_a_new_child()
  local events = {}
  local game = recordingGame(events)
  local pad = portraitPad(recordingRenderer(), game)
  Assert.isTrue(pad:touchpressed(1, 56, 672))
  game:dispose()
  clear(events)
  pad:sync()
  Assert.isTrue(pad:touchmoved(1, 56, 672))
  Assert.isTrue(pad:touchreleased(1, 56, 672))
  Assert.deepEqual(events, {}, "terminal reconciliation never invokes a disposed child")
end

return { tests = T }
