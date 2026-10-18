-- The pure Start Menu controller: final interactive action display,
-- selection, confirm/cancel/menu-key close, and pointer interaction over the
-- generated normal-position contract. The controller receives the
-- runtime-composed final action list (each entry already intersected with
-- the registered destination capabilities, carrying only id /
-- targetApplication / displayPosition) and the generated manifest
-- interactive record (cancel/header hit rectangle plus the source anchor,
-- label window, touch hit rectangle, and ordered directional candidate
-- lists per normal position 0..6); it carries no labels, no product-mode
-- projections, and no capability or progression knowledge. The final list is
-- never empty -- the menu factory returns nil when no action is
-- interactive -- so the controller's invariants are that at least one
-- action exists and every display position fits the normal seven-position
-- selector, and the selection always resolves. The controller is silent: it
-- never names a ROM sequence and never touches love. No application
-- launches happen here: the controller records the takeResult contract and
-- the host launches.

local Assert = require("tests.support.Assert")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local StartMenuController = require("libs.hgss.src.ui.StartMenuController")

local T = {}

local POSITIONS = FieldUiFixture.startMenuInteractive()

-- The full-progression interactive list (every destination registered):
-- display positions 0..6.
local function fullEntries()
  return {
    { id = "vanilla.pokedex", targetApplication = "pokedex", actionKind = "application", displayPosition = 0 },
    { id = "vanilla.pokemon", targetApplication = "pokemon", actionKind = "application", displayPosition = 1 },
    { id = "vanilla.bag", targetApplication = "bag", actionKind = "application", displayPosition = 2 },
    { id = "vanilla.pokegear", targetApplication = "pokegear", actionKind = "application", displayPosition = 3 },
    {
      id = "vanilla.trainer_card",
      targetApplication = "trainer_card",
      actionKind = "application",
      displayPosition = 4,
    },
    { id = "vanilla.save", targetApplication = "save", actionKind = "application", displayPosition = 5 },
    { id = "vanilla.options", targetApplication = "options", actionKind = "application", displayPosition = 6 },
  }
end

---@param opts table?
---@return StartMenuController
local function newController(opts)
  opts = opts or {}
  return StartMenuController.new({
    entries = opts.entries ~= nil and opts.entries or fullEntries(),
    interactive = opts.interactive or POSITIONS,
    rememberedActionId = opts.rememberedActionId,
    effect = opts.effect,
    runningShoes = opts.runningShoes,
  })
end

local function rectCenter(rect)
  return rect.x + rect.width / 2, rect.y + rect.height / 2
end

-- The Running Shoes toggle: a fresh touch inside its generated hit rectangle
-- toggles the lock once, only while the shoes are visible; the controller
-- owns no lock state and reports the live one through its status.
local SHOES_RECT = FieldUiFixture.startMenuRunningShoes().hitRect

local function shoesPort(visible)
  local port = { toggles = 0, visible = visible, locked = false }
  port.hitRect = SHOES_RECT
  port.state = function()
    return { visible = port.visible, locked = port.locked }
  end
  port.toggle = function()
    port.toggles = port.toggles + 1
    port.locked = not port.locked
  end
  return port
end

function T.running_shoes_touch_toggles_once_per_press_and_reports_the_lock()
  local port = shoesPort(true)
  local controller = newController({ runningShoes = port })
  Assert.deepEqual(controller:status().runningShoes, { locked = false, focused = false })
  local x, y = rectCenter(SHOES_RECT)
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = x, y = y } })
  Assert.equal(port.toggles, 1, "the fresh touch toggles immediately")
  Assert.deepEqual(controller:status().runningShoes, { locked = true, focused = true })
  controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = x, y = y } })
  Assert.equal(port.toggles, 1, "release never toggles again")
  Assert.isNil(controller:takeResult(), "the toggle never closes or launches")
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch:2", x = x, y = y } })
  Assert.equal(port.toggles, 2)
  Assert.deepEqual(controller:status().runningShoes, { locked = false, focused = true })
end

function T.running_shoes_are_dpad_focusable_and_confirm_without_leaving_the_menu()
  local port = shoesPort(true)
  local effects = {}
  local controller = newController({
    runningShoes = port,
    effect = function(sequence)
      effects[#effects + 1] = sequence
    end,
  })
  for _, direction in ipairs({ "right", "down", "down" }) do
    controller:updateFixed({ { type = "navigate", direction = direction } })
  end
  Assert.equal(controller:status().selectedPosition, 6)
  controller:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.deepEqual(controller:status().runningShoes, { locked = false, focused = true })
  Assert.equal(controller:status().selectedPosition, 6, "normal selection remains remembered")
  for _ = 1, 2 do
    controller:updateFixed({ { type = "confirm" } })
  end
  Assert.deepEqual(controller:status().runningShoes, { locked = false, focused = true })
  Assert.equal(port.toggles, 2, "each confirm toggles exactly once")
  -- Four focus moves (right, down, down, right onto the shoes), then two toggles.
  Assert.equal(#effects, 6)
  Assert.equal(effects[6], "SEQ_SE_DP_SELECT")
  Assert.isNil(controller:takeResult(), "shoes confirmation does not launch or close")
  controller:updateFixed({ { type = "navigate", direction = "left" } })
  Assert.equal(controller:status().selectedPosition, 6, "left returns to the ingress action")
  Assert.isFalse(controller:status().runningShoes.focused)
  controller:updateFixed({ { type = "confirm" } })
  Assert.equal(controller:takeResult().applicationId, "options", "normal confirmation still launches")
end

function T.running_shoes_focus_enters_from_sparse_reachable_actions_only()
  for _, position in ipairs({ 0, 1, 2, 4, 5, 6 }) do
    local controller = newController({
      entries = {
        { id = "vanilla.sparse", targetApplication = "sparse", actionKind = "application", displayPosition = position },
      },
      runningShoes = shoesPort(true),
    })
    Assert.equal(controller:status().selectedPosition, position)
    controller:updateFixed({ { type = "navigate", direction = "right" } })
    Assert.deepEqual(
      controller:status().runningShoes,
      { locked = false, focused = true },
      "a one-action sparse menu enters shoes from position " .. position
    )
    Assert.equal(controller:status().selectedPosition, position, "no synthetic normal position is selected")
    controller:updateFixed({ { type = "navigate", direction = "left" } })
    Assert.equal(controller:status().selectedPosition, position, "left returns to the sparse ingress")
  end
end

function T.hidden_shoes_clear_focus_before_the_next_confirm()
  local port = shoesPort(true)
  local controller = newController({ runningShoes = port })
  for _, direction in ipairs({ "right", "down", "down", "right" }) do
    controller:updateFixed({ { type = "navigate", direction = direction } })
  end
  Assert.isTrue(controller:status().runningShoes.focused)
  port.visible = false
  controller:updateFixed({ { type = "confirm" } })
  Assert.equal(port.toggles, 0, "confirm cannot activate a newly hidden shoe target")
  Assert.isNil(controller:status().runningShoes)
  Assert.deepEqual(controller:takeResult(), {
    kind = "launch",
    applicationId = "options",
    actionId = "vanilla.options",
  }, "confirm falls back to the remembered normal action")
end

function T.pointer_move_never_changes_focus()
  local port = shoesPort(true)
  local controller = newController({ runningShoes = port })
  local shoesX, shoesY = rectCenter(SHOES_RECT)
  controller:updateFixed({ { type = "pointer_move", pointerId = "mouse:1", x = shoesX, y = shoesY } })
  Assert.isFalse(controller:status().runningShoes.focused)
  Assert.equal(port.toggles, 0)
  local x, y = rectCenter(POSITIONS.positions[4].hitRect)
  controller:updateFixed({ { type = "pointer_move", pointerId = "mouse:1", x = x, y = y } })
  Assert.equal(controller:status().selectedPosition, 0, "hovering an action does not select it")
  Assert.isNil(controller:status().focusShake)
end

function T.running_shoes_touch_is_inert_outside_the_rect_or_while_hidden()
  local port = shoesPort(true)
  local controller = newController({ runningShoes = port })
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = SHOES_RECT.x - 1, y = SHOES_RECT.y } })
  controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = SHOES_RECT.x - 1, y = SHOES_RECT.y } })
  Assert.equal(port.toggles, 0)
  local hidden = shoesPort(false)
  local hiddenController = newController({ runningShoes = hidden })
  Assert.isNil(hiddenController:status().runningShoes, "an unowned or hidden toggle is not presented")
  local x, y = rectCenter(SHOES_RECT)
  hiddenController:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = x, y = y } })
  Assert.equal(hidden.toggles, 0, "a hidden toggle has no touch region")
end

function T.construction_succeeds_with_only_the_documented_options()
  local controller = newController()
  Assert.equal(controller:status().open, true)
end

function T.visible_actions_follow_positions_with_the_selected_position()
  local controller = newController()
  local status = controller:status()
  Assert.equal(status.open, true)
  Assert.deepEqual(status.actions, {
    { id = "vanilla.pokedex", targetApplication = "pokedex", position = 0, enabled = true },
    { id = "vanilla.pokemon", targetApplication = "pokemon", position = 1, enabled = true },
    { id = "vanilla.bag", targetApplication = "bag", position = 2, enabled = true },
    { id = "vanilla.pokegear", targetApplication = "pokegear", position = 3, enabled = true },
    { id = "vanilla.trainer_card", targetApplication = "trainer_card", position = 4, enabled = true },
    { id = "vanilla.save", targetApplication = "save", position = 5, enabled = true },
    { id = "vanilla.options", targetApplication = "options", position = 6, enabled = true },
  })
  Assert.equal(status.selectedPosition, 0, "the default selection is the first visible action")
end

function T.actions_carry_id_destination_position_and_enabled()
  local actions = newController():status().actions
  for _, action in ipairs(actions) do
    local keys = {}
    for key in pairs(action) do
      keys[#keys + 1] = key
    end
    table.sort(keys)
    Assert.deepEqual(
      keys,
      { "enabled", "id", "position", "targetApplication" },
      "status actions include the enabled flag"
    )
  end
end

function T.status_preserves_source_and_implementation_capabilities()
  local controller = newController({
    entries = {
      {
        id = "vanilla.trainer_card",
        targetApplication = "trainer_card",
        actionKind = "application",
        displayPosition = 0,
        sourcePresent = true,
        sourceEnabled = true,
        implemented = true,
        enabled = true,
      },
      {
        id = "vanilla.options",
        targetApplication = "options",
        actionKind = "application",
        displayPosition = 1,
        sourcePresent = true,
        sourceEnabled = true,
        implemented = false,
        enabled = false,
      },
    },
  })
  Assert.deepEqual(controller:status().actions, {
    {
      id = "vanilla.trainer_card",
      targetApplication = "trainer_card",
      position = 0,
      enabled = true,
      sourcePresent = true,
      sourceEnabled = true,
      implemented = true,
    },
    {
      id = "vanilla.options",
      targetApplication = "options",
      position = 1,
      enabled = false,
      sourcePresent = true,
      sourceEnabled = true,
      implemented = false,
    },
  })
end

function T.selection_and_close_emit_source_effects()
  local effects = {}
  local controller = newController({
    effect = function(sequence)
      effects[#effects + 1] = sequence
    end,
  })
  controller:updateFixed({ { type = "confirm" } })
  Assert.deepEqual(effects, { "SEQ_SE_DP_SELECT" })
  local closing = newController({
    effect = function(sequence)
      effects[#effects + 1] = sequence
    end,
  })
  closing:updateFixed({ { type = "cancel" } })
  Assert.equal(effects[#effects], "SEQ_SE_GS_GEARCANCEL")
end

function T.directional_focus_changes_play_the_cursor_effect()
  local effects = {}
  local controller = newController({
    effect = function(sequence)
      effects[#effects + 1] = sequence
    end,
  })
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.deepEqual(effects, { "SEQ_SE_DP_SELECT" })
  local x, y = rectCenter(POSITIONS.positions[4].hitRect)
  controller:updateFixed({ { type = "pointer_move", pointerId = "mouse:1", x = x, y = y } })
  Assert.equal(#effects, 1, "hover is silent")
end

function T.selection_restores_by_remembered_action_id()
  local controller = newController({ rememberedActionId = "vanilla.bag" })
  Assert.equal(controller:status().selectedPosition, 2, "the remembered action restores its display position")
end

function T.selection_falls_back_to_the_first_action_when_the_remembered_id_is_absent()
  local controller = newController({ rememberedActionId = "vanilla.running_shoes" })
  Assert.equal(controller:status().selectedPosition, 0, "an absent remembered id falls back to the first action")
end

function T.directional_navigation_walks_the_full_normal_menu()
  local controller = newController()
  Assert.equal(controller:status().selectedPosition, 0)
  controller:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.equal(controller:status().selectedPosition, 4, "right from 0 selects the first visible candidate")
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(controller:status().selectedPosition, 5, "down from 4 selects the first visible candidate")
  controller:updateFixed({ { type = "navigate", direction = "left" } })
  Assert.equal(controller:status().selectedPosition, 1, "left from 5 selects the first visible candidate")
  controller:updateFixed({ { type = "navigate", direction = "up" } })
  Assert.equal(controller:status().selectedPosition, 0, "up from 1 selects the first visible candidate")
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(controller:status().selectedPosition, 1, "down from 0 selects the first visible candidate")
end

-- Retail shakes the newly focused icon along the movement axis
-- (up/down restart animation 3, left/right animation 1),
-- only when focus actually changes; touch selection never shakes.
function T.directional_focus_change_shakes_the_new_icon_along_the_movement_axis()
  local controller = newController()
  Assert.isNil(controller:status().focusShake, "the freshly opened menu shakes no icon")
  controller:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.deepEqual(
    controller:status().focusShake,
    { position = 4, axis = "horizontal", age = 0 },
    "a right move shakes the new icon horizontally from its first tick"
  )
  controller:updateFixed({})
  controller:updateFixed({})
  Assert.deepEqual(
    controller:status().focusShake,
    { position = 4, axis = "horizontal", age = 2 },
    "the shake ages one tick per fixed update"
  )
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.deepEqual(
    controller:status().focusShake,
    { position = 5, axis = "vertical", age = 0 },
    "a down move restarts the shake vertically on the new icon"
  )
end

function T.navigation_without_a_focus_change_shakes_nothing()
  local single = newController({
    entries = {
      { id = "vanilla.solo", targetApplication = "solo", actionKind = "application", displayPosition = 0 },
    },
  })
  for _, direction in ipairs({ "up", "down", "left", "right" }) do
    single:updateFixed({ { type = "navigate", direction = direction } })
    Assert.equal(single:status().selectedPosition, 0, direction .. " on a solo menu moves nowhere")
    Assert.isNil(single:status().focusShake, "a move that changes nothing shakes nothing")
  end
  local controller = newController()
  controller:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.deepEqual(controller:status().focusShake, { position = 4, axis = "horizontal", age = 0 }, "a real move shakes")
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(controller:status().selectedPosition, 5, "down from 4 moves to 5")
  controller:updateFixed({ { type = "navigate", direction = "left" } })
  Assert.equal(controller:status().selectedPosition, 1, "left from 5 moves to 1")
  Assert.deepEqual(
    controller:status().focusShake,
    { position = 1, axis = "horizontal", age = 0 },
    "a left move shakes horizontally"
  )
  controller:updateFixed({ { type = "navigate", direction = "up" } })
  Assert.equal(controller:status().selectedPosition, 0, "up from 1 moves to 0")
  Assert.deepEqual(
    controller:status().focusShake,
    { position = 0, axis = "vertical", age = 0 },
    "an up move shakes vertically"
  )
end

function T.pointer_selection_never_shakes()
  local controller = newController()
  local zeroX, zeroY = rectCenter(POSITIONS.positions[0].hitRect)
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = zeroX, y = zeroY } })
  controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = zeroX, y = zeroY } })
  Assert.isNil(controller:status().focusShake, "touch selection never shakes")
end

-- Retail hops the activated icon upward on successful activation
-- (the loop restarts sequence 2 on the
-- selected icon): confirm-key and tap activation hop; disabled, cancel,
-- and shoes-toggle activation never hop.
function T.successful_activation_hops_the_activated_icon()
  local controller = newController()
  Assert.isNil(controller:status().confirmHop, "the freshly opened menu hops no icon")
  controller:updateFixed({ { type = "confirm" } })
  Assert.deepEqual(
    controller:status().confirmHop,
    { position = 0, age = 0 },
    "confirming the selected application hops it from its first tick"
  )
  controller:updateFixed({})
  controller:updateFixed({})
  Assert.deepEqual(controller:status().confirmHop, { position = 0, age = 2 }, "the hop ages one tick per fixed update")
  Assert.notNil(controller:takeResult(), "the host drains the launch before further input")
  controller:updateFixed({ { type = "navigate", direction = "right" } })
  controller:updateFixed({ { type = "confirm" } })
  Assert.deepEqual(
    controller:status().confirmHop,
    { position = 4, age = 0 },
    "a later activation restarts the hop on the newly activated icon"
  )
end

function T.tap_activation_hops_the_tapped_icon()
  local controller = newController()
  local x, y = rectCenter(POSITIONS.positions[4].hitRect)
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = x, y = y } })
  Assert.isNil(controller:status().confirmHop, "pressing an icon hops nothing yet")
  controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = x, y = y } })
  Assert.deepEqual(
    controller:status().confirmHop,
    { position = 4, age = 0 },
    "releasing on the pressed icon hops the activated icon"
  )
end

function T.disabled_cancel_and_shoes_activation_never_hop()
  local controller = newController({
    entries = {
      { id = "vanilla.save", targetApplication = "save", displayPosition = 5, enabled = false },
    },
  })
  controller:updateFixed({ { type = "confirm" } })
  Assert.isNil(controller:takeResult(), "a disabled entry never activates")
  Assert.isNil(controller:status().confirmHop, "a disabled no-op hops nothing")
  controller:updateFixed({ { type = "cancel" } })
  Assert.deepEqual(controller:takeResult(), { kind = "close" }, "cancel closes")
  Assert.isNil(controller:status().confirmHop, "cancel hops nothing")
end

function T.shoes_toggle_activation_never_hops()
  local port = shoesPort(true)
  local controller = newController({ runningShoes = port })
  local x, y = rectCenter(SHOES_RECT)
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = x, y = y } })
  Assert.equal(port.toggles, 1, "the fresh touch toggles")
  Assert.isNil(controller:status().confirmHop, "toggling the shoes hops nothing")
end

function T.leaving_shoes_focus_shakes_the_reentered_icon_horizontally()
  local controller = newController({ runningShoes = shoesPort(true) })
  for _, direction in ipairs({ "right", "down", "down" }) do
    controller:updateFixed({ { type = "navigate", direction = direction } })
  end
  controller:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.isTrue(controller:status().runningShoes.focused, "right enters shoes focus")
  Assert.deepEqual(
    controller:status().focusShake,
    { position = 6, axis = "vertical", age = 1 },
    "entering shoes focus lets the in-flight icon shake play out"
  )
  controller:updateFixed({ { type = "navigate", direction = "left" } })
  Assert.isFalse(controller:status().runningShoes.focused, "left leaves shoes focus")
  Assert.deepEqual(
    controller:status().focusShake,
    { position = 6, axis = "horizontal", age = 0 },
    "returning to the icon shakes it along the horizontal axis"
  )
end

function T.confirm_launches_the_selected_application()
  local controller = newController()
  controller:updateFixed({ { type = "confirm" } })
  Assert.deepEqual(controller:takeResult(), {
    kind = "launch",
    applicationId = "pokedex",
    actionId = "vanilla.pokedex",
  })
  Assert.equal(controller:status().open, true, "a taken launch result keeps the menu open for its retained background")
end

function T.confirming_a_field_action_emits_a_field_action_result()
  local controller = newController({
    entries = {
      { id = "vanilla.save", actionKind = "field_action", displayPosition = 0, enabled = true },
    },
  })
  controller:updateFixed({ { type = "confirm" } })
  Assert.deepEqual(controller:takeResult(), { kind = "field_action", actionId = "vanilla.save" })
end

function T.cancel_and_the_menu_event_close()
  local controller = newController()
  controller:updateFixed({ { type = "cancel" } })
  Assert.deepEqual(controller:takeResult(), { kind = "close" })

  local menuController = newController()
  menuController:updateFixed({ { type = "menu" } })
  Assert.deepEqual(menuController:takeResult(), { kind = "close" })
end

function T.a_terminal_event_ends_the_ticks_processing()
  local closeFirst = newController()
  closeFirst:updateFixed({ { type = "cancel" }, { type = "confirm" } })
  Assert.deepEqual(closeFirst:takeResult(), { kind = "close" }, "a close before a confirm in one tick must win")
  Assert.equal(closeFirst:status().open, false)

  local confirmFirst = newController()
  confirmFirst:updateFixed({ { type = "confirm" }, { type = "cancel" } })
  Assert.deepEqual(
    confirmFirst:takeResult(),
    { kind = "launch", applicationId = "pokedex", actionId = "vanilla.pokedex" },
    "a confirm before a cancel in one tick must win"
  )
end

function T.take_result_is_exactly_once_and_terminal()
  local controller = newController()
  controller:updateFixed({ { type = "cancel" } })
  Assert.deepEqual(controller:takeResult(), { kind = "close" })
  Assert.isNil(controller:takeResult(), "the result is consumed exactly once")
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(controller:status().open, false, "a terminal controller stays closed")
end

function T.pointer_down_up_on_the_same_position_activates()
  local controller = newController()
  local x, y = rectCenter(POSITIONS.positions[4].hitRect)
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = x, y = y } })
  Assert.equal(controller:status().selectedPosition, 4, "pointer down selects the pressed position")
  controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = x, y = y, dragged = false } })
  Assert.deepEqual(controller:takeResult(), {
    kind = "launch",
    applicationId = "trainer_card",
    actionId = "vanilla.trainer_card",
  })
end

function T.pointer_down_up_mismatch_and_drag_discard_the_activation()
  local mismatch = newController()
  local downX, downY = rectCenter(POSITIONS.positions[2].hitRect)
  local upX, upY = rectCenter(POSITIONS.positions[3].hitRect)
  mismatch:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = downX, y = downY } })
  mismatch:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = upX, y = upY, dragged = false } })
  Assert.isNil(mismatch:takeResult(), "a down/up mismatch must not activate")
  Assert.equal(mismatch:status().open, true)

  local dragged = newController()
  dragged:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = downX, y = downY } })
  dragged:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = downX, y = downY, dragged = true } })
  Assert.isNil(dragged:takeResult(), "a drag must not activate")
  Assert.equal(dragged:status().open, true)
end

function T.pointer_cancel_region_down_up_closes()
  local controller = newController()
  local x, y = rectCenter(POSITIONS.cancelHitRect)
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = x, y = y } })
  controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = x, y = y, dragged = false } })
  Assert.deepEqual(controller:takeResult(), { kind = "close" })
end

function T.pointer_cancel_mismatch_and_drag_do_not_close()
  local mismatch = newController()
  local x, y = rectCenter(POSITIONS.cancelHitRect)
  local otherX, otherY = rectCenter(POSITIONS.positions[0].hitRect)
  mismatch:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = x, y = y } })
  mismatch:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = otherX, y = otherY, dragged = false } })
  Assert.isNil(mismatch:takeResult(), "a cancel down released over an action must not close")
  Assert.equal(mismatch:status().open, true)

  local dragged = newController()
  dragged:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = x, y = y } })
  dragged:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = x, y = y, dragged = true } })
  Assert.isNil(dragged:takeResult(), "a dragged cancel press must not close")
  Assert.equal(dragged:status().open, true)
end

function T.pointer_capture_ignores_other_pointers()
  local controller = newController()
  local firstX, firstY = rectCenter(POSITIONS.positions[4].hitRect)
  local secondX, secondY = rectCenter(POSITIONS.positions[6].hitRect)
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = firstX, y = firstY } })
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch:2", x = secondX, y = secondY } })
  controller:updateFixed({ { type = "pointer_up", pointerId = "touch:2", x = secondX, y = secondY, dragged = false } })
  Assert.isNil(controller:takeResult(), "a second pointer cannot steal the capture")
  Assert.equal(controller:status().open, true)
  controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = firstX, y = firstY, dragged = false } })
  Assert.deepEqual(controller:takeResult(), {
    kind = "launch",
    applicationId = "trainer_card",
    actionId = "vanilla.trainer_card",
  })
end

-- A placement change cancels the active pointer capture, so a press held
-- across a layout change cannot activate a different post-change position.
function T.cancel_pointer_capture_discards_the_held_press()
  local controller = newController()
  local x, y = rectCenter(POSITIONS.positions[4].hitRect)
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = x, y = y } })
  controller:cancelPointerCapture()
  controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = x, y = y, dragged = false } })
  Assert.isNil(controller:takeResult(), "a cancelled capture cannot activate")
  Assert.equal(controller:status().open, true)
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = x, y = y } })
  controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = x, y = y, dragged = false } })
  Assert.notNil(controller:takeResult(), "a fresh press after the cancellation works normally")
end

function T.pointer_press_outside_any_hit_rect_does_not_move_selection()
  local controller = newController()
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = 255, y = 191 } })
  Assert.equal(controller:status().selectedPosition, 0, "a point outside the hit regions changes nothing")
end

function T.pointer_over_a_position_without_a_visible_action_changes_nothing()
  -- Display positions 0, 1, and 2 are visible in this list, so the hit
  -- rectangles of positions 5 and 6 have no action.
  local controller = newController({
    entries = {
      { id = "vanilla.trainer_card", targetApplication = "trainer_card", displayPosition = 0 },
      { id = "vanilla.save", targetApplication = "save", displayPosition = 1 },
      { id = "vanilla.options", targetApplication = "options", displayPosition = 2 },
    },
  })
  local x, y = rectCenter(POSITIONS.positions[5].hitRect)
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = x, y = y } })
  controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = x, y = y, dragged = false } })
  Assert.isNil(controller:takeResult(), "a press on an empty position must not activate anything")
  Assert.equal(controller:status().open, true)
end

function T.dispose_is_idempotent_and_discards_a_pending_result()
  local controller = newController()
  controller:updateFixed({ { type = "cancel" } })
  controller:dispose()
  controller:dispose()
  Assert.equal(controller:status().open, false)
  Assert.isNil(controller:takeResult(), "dispose discards the pending result")
end

-- The constructor guards the real controller invariants: the final list is
-- never empty (the menu factory returns nil instead) and every display
-- position fits the normal seven-position selector with a generated record.
function T.construction_guards_the_controller_invariants()
  Assert.throws(function()
    StartMenuController.new({ entries = {}, interactive = POSITIONS })
  end, "a blank menu is never constructed -- the factory returns nil")
  Assert.throws(function()
    StartMenuController.new({
      entries = { { id = "vanilla.save", targetApplication = "save", displayPosition = 9 } },
      interactive = POSITIONS,
    })
  end, "a position beyond the normal selector is rejected")
  Assert.throws(function()
    StartMenuController.new({ entries = fullEntries() })
  end, "the generated interactive record is required")
end

-- Disabled entries (enabled=false) are visible and selectable but do not
-- activate on confirm or pointer tap.
function T.disabled_entries_are_visible_and_selectable()
  local mixed = {
    { id = "vanilla.trainer_card", targetApplication = "trainer_card", displayPosition = 0, enabled = true },
    { id = "vanilla.save", targetApplication = "save", displayPosition = 2, enabled = false },
    { id = "vanilla.options", targetApplication = "options", displayPosition = 3, enabled = true },
  }
  local controller = newController({ entries = mixed })
  local status = controller:status()
  Assert.equal(#status.actions, 3, "disabled entries appear in the visible list")
  Assert.equal(status.actions[2].id, "vanilla.save", "disabled entry is at its display position")
end

-- Confirming on a disabled entry is a no-op: the menu stays open,
-- no result is taken, and the selection is unchanged.
function T.confirming_disabled_entry_is_noop()
  local mixed = {
    { id = "vanilla.trainer_card", targetApplication = "trainer_card", displayPosition = 0, enabled = true },
    { id = "vanilla.save", targetApplication = "save", displayPosition = 2, enabled = false },
  }
  local controller = newController({ entries = mixed })
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  local selectedBefore = controller:status().selectedPosition
  controller:updateFixed({ { type = "confirm" } })
  Assert.isNil(controller:takeResult(), "confirming disabled entry produces no result")
  Assert.equal(controller:status().open, true, "menu remains open")
  Assert.equal(controller:status().selectedPosition, selectedBefore, "selection unchanged")
end

-- Pointer tap on a disabled entry is a no-op.
function T.pointer_tap_on_disabled_entry_is_noop()
  local mixed = {
    { id = "vanilla.trainer_card", targetApplication = "trainer_card", displayPosition = 0, enabled = true },
    { id = "vanilla.save", targetApplication = "save", displayPosition = 1, enabled = false },
  }
  local controller = newController({ entries = mixed })
  local x, y = rectCenter(POSITIONS.positions[1].hitRect)
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = x, y = y } })
  controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = x, y = y, dragged = false } })
  Assert.isNil(controller:takeResult(), "tap on disabled entry produces no result")
  Assert.equal(controller:status().open, true, "menu remains open")
end

-- An enabled action whose kind has no implemented routing is a programming
-- fault: the runtime must never compose enabled=true for a non-application
-- action, so activating one is an error, never a silent close.
function T.confirming_an_enabled_non_application_action_errors()
  local controller = newController({
    entries = {
      { id = "vanilla.running_shoes", actionKind = "toggle", displayPosition = 0, enabled = true },
    },
  })
  Assert.throws(function()
    controller:updateFixed({ { type = "confirm" } })
  end, "an enabled action with unimplemented routing must error, not silently close")
end

-- Status output includes the enabled field for each action.
function T.status_includes_enabled_field()
  local mixed = {
    { id = "vanilla.trainer_card", targetApplication = "trainer_card", displayPosition = 0, enabled = true },
    { id = "vanilla.save", targetApplication = "save", displayPosition = 1, enabled = false },
  }
  local controller = newController({ entries = mixed })
  local actions = controller:status().actions
  Assert.equal(actions[1].enabled, true, "enabled action has enabled=true")
  Assert.equal(actions[2].enabled, false, "disabled action has enabled=false")
end

-- Unknown event types are programming faults, never silently dropped.
function T.unknown_event_types_are_rejected()
  local controller = newController()
  Assert.throws(function()
    controller:updateFixed({ { type = "pointer_scroll", pointerId = "mouse:1", x = 10, y = 10 } })
  end, "an unknown event type must error")
end

-- The interactive selector below consumes the generated source-position
-- contract: entries carry display positions 0..6 and the controller receives
-- the shared anchor/label/hit/navigation record. Selection is published as a
-- source position, pointer input resolves against the generated hit
-- rectangles (plus the cancel/header rectangle), and directional movement
-- scans the generated ordered candidate lists against visible positions.
-- Disabled visible entries stay selectable; only activation is a no-op.

local INTERACTIVE = FieldUiFixture.startMenuInteractive()

---@param opts table?
---@return StartMenuController
local function newInteractiveController(opts)
  opts = opts or {}
  return StartMenuController.new({
    entries = assert(opts.entries, "interactive selector tests compose their own entries"),
    interactive = opts.interactive or INTERACTIVE,
    rememberedActionId = opts.rememberedActionId,
  })
end

local function interactiveEntries()
  return {
    { id = "vanilla.pokedex", targetApplication = "pokedex", actionKind = "application", displayPosition = 0 },
    { id = "vanilla.bag", targetApplication = "bag", actionKind = "application", displayPosition = 2 },
    {
      id = "vanilla.save",
      targetApplication = "save",
      actionKind = "application",
      displayPosition = 5,
      enabled = false,
    },
  }
end

local function hitCenter(rect)
  return rect.x + rect.width / 2, rect.y + rect.height / 2
end

function T.selection_identifies_the_source_position_and_restores_by_action_id()
  local controller = newInteractiveController({ entries = interactiveEntries() })
  local status = controller:status()
  Assert.equal(status.open, true)
  Assert.equal(status.selectedPosition, 0, "selection starts at the first visible normal position")

  local remembered = newInteractiveController({ entries = interactiveEntries(), rememberedActionId = "vanilla.bag" })
  Assert.equal(remembered:status().selectedPosition, 2, "the remembered action restores its source position")

  local absent = newInteractiveController({ entries = interactiveEntries(), rememberedActionId = "vanilla.options" })
  Assert.equal(
    absent:status().selectedPosition,
    0,
    "an absent remembered id falls back to the first visible normal action"
  )
end

function T.pointer_resolves_against_the_generated_touch_bounds()
  local controller = newInteractiveController({ entries = interactiveEntries() })
  for _, position in ipairs({ 0, 2, 5 }) do
    local x, y = hitCenter(INTERACTIVE.positions[position].hitRect)
    controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = x, y = y } })
    Assert.equal(controller:status().selectedPosition, position, "press selects generated position " .. position)
    controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = 0, y = 0, dragged = true } })
  end

  local press = newInteractiveController({ entries = interactiveEntries() })
  local x, y = hitCenter(INTERACTIVE.positions[2].hitRect)
  press:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = x, y = y } })
  Assert.equal(press:status().selectedPosition, 2, "pointer down selects the pressed position")
  press:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = x, y = y, dragged = false } })
  Assert.deepEqual(press:takeResult(), {
    kind = "launch",
    applicationId = "bag",
    actionId = "vanilla.bag",
  })
end

function T.disabled_visible_entries_select_but_never_activate()
  local controller = newInteractiveController({ entries = interactiveEntries() })
  local x, y = hitCenter(INTERACTIVE.positions[5].hitRect)
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = x, y = y } })
  controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = 0, y = 0, dragged = true } })
  Assert.equal(controller:status().selectedPosition, 5, "a disabled visible entry is selectable")
  controller:updateFixed({ { type = "confirm" } })
  Assert.isNil(controller:takeResult(), "confirming a disabled entry is a no-op")
  Assert.equal(controller:status().open, true)

  local tap = newInteractiveController({ entries = interactiveEntries() })
  tap:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = x, y = y } })
  tap:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = x, y = y, dragged = false } })
  Assert.isNil(tap:takeResult(), "tapping a disabled entry is a no-op")
  Assert.equal(tap:status().open, true)
end

function T.mismatched_and_dragged_releases_do_not_activate()
  local mismatch = newInteractiveController({ entries = interactiveEntries() })
  local downX, downY = hitCenter(INTERACTIVE.positions[0].hitRect)
  local upX, upY = hitCenter(INTERACTIVE.positions[2].hitRect)
  mismatch:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = downX, y = downY } })
  mismatch:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = upX, y = upY, dragged = false } })
  Assert.isNil(mismatch:takeResult(), "a down/up mismatch across positions must not activate")
  Assert.equal(mismatch:status().open, true)

  local dragged = newInteractiveController({ entries = interactiveEntries() })
  dragged:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = downX, y = downY } })
  dragged:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = downX, y = downY, dragged = true } })
  Assert.isNil(dragged:takeResult(), "a drag must not activate")
  Assert.equal(dragged:status().open, true)
end

function T.cancel_region_closes_through_the_same_close_path()
  local controller = newInteractiveController({ entries = interactiveEntries() })
  local x, y = hitCenter(INTERACTIVE.cancelHitRect)
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = x, y = y } })
  controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = x, y = y, dragged = false } })
  Assert.deepEqual(controller:takeResult(), { kind = "close" })

  local mismatch = newInteractiveController({ entries = interactiveEntries() })
  local otherX, otherY = hitCenter(INTERACTIVE.positions[0].hitRect)
  mismatch:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = x, y = y } })
  mismatch:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = otherX, y = otherY, dragged = false } })
  Assert.isNil(mismatch:takeResult(), "a cancel down released over an action must not close")
  Assert.equal(mismatch:status().open, true)
end

function T.directional_movement_scans_the_ordered_candidate_lists()
  local function atPosition(position, extra)
    local entries = {
      { id = "vanilla.a", targetApplication = "a", actionKind = "application", displayPosition = position },
    }
    for _, entry in ipairs(extra or {}) do
      entries[#entries + 1] = entry
    end
    local controller = newInteractiveController({ entries = entries })
    Assert.equal(controller:status().selectedPosition, position)
    return controller
  end
  local function entry(id, position, enabled)
    return {
      id = id,
      targetApplication = id,
      actionKind = "application",
      displayPosition = position,
      enabled = enabled,
    }
  end

  -- Position 0 right lists {4,0,0}: the first candidate wins when visible.
  local first = atPosition(0, { entry("vanilla.b", 4) })
  first:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.equal(first:status().selectedPosition, 4, "right from 0 selects the first visible candidate")

  -- Position 1 up lists {0,3,2}: with 0 absent the second candidate wins.
  local second = atPosition(1, { entry("vanilla.b", 3) })
  second:updateFixed({ { type = "navigate", direction = "up" } })
  Assert.equal(second:status().selectedPosition, 3, "up from 1 falls through to the second candidate")

  -- Position 2 down lists {3,0,1}: with 3 and 0 absent the third wins.
  local third = atPosition(2, { entry("vanilla.b", 1) })
  third:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(third:status().selectedPosition, 1, "down from 2 falls through to the third candidate")

  -- Disabled visible candidates stay eligible: presence, not enabled, decides.
  local disabled = atPosition(0, { entry("vanilla.b", 1, false) })
  disabled:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(disabled:status().selectedPosition, 1, "a disabled visible candidate is eligible for movement")

  -- No candidate but the current position resolves: selection stays put.
  local stay = atPosition(5, {})
  stay:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(stay:status().selectedPosition, 5, "down with no other visible candidate keeps the selection")
  stay:updateFixed({ { type = "navigate", direction = "up" } })
  Assert.equal(stay:status().selectedPosition, 5, "up with no other visible candidate keeps the selection")
  stay:updateFixed({ { type = "navigate", direction = "left" } })
  Assert.equal(stay:status().selectedPosition, 5, "left with no other visible candidate keeps the selection")
end

function T.hidden_positions_are_skipped_in_declared_candidate_order()
  local function sparseAt(position)
    -- Position 5 is unreachable by navigation through this sparse set, so
    -- restore it through the remembered selection instead.
    local remembered = position == 5 and "vanilla.save" or nil
    local controller = newInteractiveController({ entries = interactiveEntries(), rememberedActionId = remembered })
    if position == 2 then
      controller:updateFixed({ { type = "navigate", direction = "down" } })
    end
    Assert.equal(controller:status().selectedPosition, position, "sparse menu setup must reach position " .. position)
    return controller
  end
  local function move(controller, direction)
    controller:updateFixed({ { type = "navigate", direction = direction } })
    return controller:status().selectedPosition
  end

  -- Visible set is {0, 2, 5}; positions 1, 3, 4, 6 are hidden holes.
  Assert.equal(move(sparseAt(0), "down"), 2, "down from 0 must skip hidden 1 and select 2")
  Assert.equal(move(sparseAt(0), "up"), 2, "up from 0 must skip hidden 3 and select 2")
  Assert.equal(move(sparseAt(0), "right"), 0, "right from 0 must skip hidden 4 and stay")
  Assert.equal(move(sparseAt(0), "left"), 0, "left from 0 must skip hidden 4 and stay")

  Assert.equal(move(sparseAt(2), "up"), 0, "up from 2 must skip hidden 1 and select 0")
  Assert.equal(move(sparseAt(2), "down"), 0, "down from 2 must skip hidden 3 and select 0")
  Assert.equal(move(sparseAt(2), "left"), 2, "left from 2 must skip hidden 6 and stay")
  Assert.equal(move(sparseAt(2), "right"), 2, "right from 2 must skip hidden 6 and stay")

  Assert.equal(move(sparseAt(5), "up"), 5, "up from 5 must skip hidden 4 and 6 and stay")
  Assert.equal(move(sparseAt(5), "down"), 5, "down from 5 must skip hidden 6 and 4 and stay")
  Assert.equal(move(sparseAt(5), "left"), 5, "left from 5 must skip hidden 1 and stay")
  Assert.equal(move(sparseAt(5), "right"), 5, "right from 5 must skip hidden 1 and stay")
end

function T.dismiss_closes_immediately_without_activation()
  local control = newController()
  Assert.isTrue(control:status().open, "the menu starts open")
  control:updateFixed({ { type = "dismiss" } })
  Assert.deepEqual(control:takeResult(), { kind = "close" }, "dismiss records the terminal close result")
  Assert.isFalse(control:status().open, "dismiss closes the menu")
end

function T.dismiss_ends_the_batch_so_later_events_cannot_overwrite_the_close()
  local control = newController()
  control:updateFixed({ { type = "dismiss" }, { type = "confirm" }, { type = "navigate", direction = "down" } })
  Assert.deepEqual(control:takeResult(), { kind = "close" }, "only the terminal close survives the batch")
  Assert.isNil(control:takeResult(), "the close result is delivered exactly once")
end

function T.entries_outside_the_normal_seven_positions_are_rejected()
  Assert.throws(function()
    StartMenuController.new({
      entries = {
        { id = "vanilla.special", targetApplication = "pokegear", actionKind = "application", displayPosition = 7 },
      },
      interactive = INTERACTIVE,
    })
  end, "position 7 is outside the normal seven-position selector")
end

-- A taken launch keeps its menu presentable: the launched snapshot stays
-- open as the drawable background under its child, while close and field
-- actions still end the menu lifetime.
function T.a_taken_launch_result_keeps_the_menu_open_for_its_retained_background()
  local controller = newController()
  controller:updateFixed({ { type = "confirm" } })
  Assert.deepEqual(controller:takeResult(), {
    kind = "launch",
    applicationId = "pokedex",
    actionId = "vanilla.pokedex",
  })
  Assert.equal(controller:status().open, true, "a launched menu stays presentable under its child")
  local saver = newController({
    entries = {
      { id = "vanilla.save", actionKind = "field_action", displayPosition = 0, enabled = true },
    },
  })
  saver:updateFixed({ { type = "confirm" } })
  Assert.deepEqual(saver:takeResult(), { kind = "field_action", actionId = "vanilla.save" })
  Assert.equal(saver:status().open, false, "field actions still end the menu lifetime")
end

return { tests = T }
