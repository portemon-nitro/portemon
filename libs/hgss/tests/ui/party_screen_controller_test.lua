-- The native party-screen controller: named browse/pick/item_target and
-- give_target contexts over an injected immutable view, injected swap port,
-- injected action policy, and revision reconciliation. Pointer input shares
-- the keyboard/gamepad confirm path with epoch-guarded captures; results
-- are one-shot semantic records with no source sentinels.

local Assert = require("tests.support.Assert")
local PartyScreenController = require("libs.hgss.src.ui.PartyScreenController")

local T = {}

local function slots(count, eligible)
  local out = {}
  for slot0 = 0, 5 do
    local occupied = slot0 < count
    out[slot0 + 1] = {
      slot = slot0,
      occupied = occupied,
      eligible = occupied and (eligible == nil or eligible[slot0 + 1] ~= false),
      displayName = occupied and ("MON" .. slot0) or nil,
      level = 5,
      gender = "male",
      status = "ok",
      currentHp = 20,
      maxHp = 20,
    }
  end
  return out
end

local NEIGHBORS = {
  [0] = { down = 1 },
  [1] = { up = 0, down = 2 },
  [2] = { up = 1, down = 3 },
  [3] = { up = 2, down = 4 },
  [4] = { up = 3, down = 5 },
  [5] = { up = 4, down = "cancel" },
  cancel = { up = 5 },
}

local function fakeLayout(hitTarget)
  return {
    neighbors = NEIGHBORS,
    hitTest = function(_, _)
      return hitTarget
    end,
    contextWindow = { x = 152, y = 120, width = 96, height = 64 },
    menuRows = function(count)
      local rows = {}
      for index = 1, count do
        rows[index] = { x = 152, y = 120 + (index - 1) * 8, width = 96, height = 8 }
      end
      return rows
    end,
  }
end

local function silentPolicy()
  return {
    menuFor = function(_, _)
      return {
        { kind = "summary", label = "SUMMARY" },
        { kind = "switch", label = "SWITCH" },
        { kind = "quit", label = "QUIT" },
      }
    end,
    submenuFor = function(_, _)
      return {
        { kind = "quit", label = "QUIT" },
      }
    end,
    evaluateTarget = function(_, _)
      return { compatible = true }
    end,
  }
end

---@param opts table?
---@return table controller, table calls, table model
local function newController(opts)
  opts = opts or {}
  local calls = { swaps = {} }
  local revision = opts.revision or 3
  local current = opts.slots or slots(2)
  local controller = PartyScreenController.new({
    context = opts.context or "browse",
    initialFocus = opts.initialSlot,
    allowCancel = opts.allowCancel,
    model = {
      refresh = function()
        return { revision = revision, slots = current }
      end,
    },
    layout = function()
      return fakeLayout(opts.hitTarget)
    end,
    swap = {
      partyRevision = function()
        return revision
      end,
      swapPartyMons = function(a, b)
        calls.swaps[#calls.swaps + 1] = { a, b }
        revision = revision + 1
      end,
    },
    actionPolicy = silentPolicy(),
    promptShape = {
      width = 48,
      height = 32,
      yes = { normal = {}, selected = {} },
      no = { normal = {}, selected = {} },
    },
  })
  return controller,
    calls,
    {
      setSlots = function(nextSlots, nextRevision)
        current = nextSlots
        if nextRevision ~= nil then
          revision = nextRevision
        else
          revision = revision + 1
        end
      end,
    }
end

local function status(controller)
  return controller:status()
end

function T.browse_navigation_skips_empty_slots()
  local controller = newController({ slots = slots(2) })
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(status(controller).cursorNode, 1)
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(status(controller).cursorNode, "cancel", "navigation falls past empty slots to cancel")
  controller:updateFixed({ { type = "confirm" } })
  Assert.equal(controller:takeResult().kind, "closed")
end

function T.browse_revision_change_reconciles_the_cursor()
  local controller, _, model = newController({ slots = slots(2) })
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(status(controller).cursorNode, 1)
  model.setSlots(slots(1))
  controller:updateFixed({})
  Assert.equal(status(controller).cursorNode, 0, "a vanished cursor reconciles to the nearest valid slot")
end

function T.browse_pointer_shares_the_confirm_path()
  local controller = newController({ hitTarget = { kind = "slot", slot = 1 } })
  controller:updateFixed({ { type = "pointer_down", pointerId = "p", x = 1, y = 1 } })
  controller:updateFixed({ { type = "pointer_up", pointerId = "p", x = 1, y = 1 } })
  Assert.equal(status(controller).state, "context")
  Assert.equal(status(controller).cursorNode, 1)
end

function T.browse_pointer_cancel_closes()
  local controller = newController({ hitTarget = { kind = "cancel" } })
  controller:updateFixed({ { type = "pointer_down", pointerId = "p", x = 1, y = 1 } })
  controller:updateFixed({ { type = "pointer_up", pointerId = "p", x = 1, y = 1 } })
  Assert.equal(controller:takeResult().kind, "closed")
end

function T.browse_pointer_cancel_clears_the_capture_without_changing_selection()
  local controller = newController({ hitTarget = { kind = "slot", slot = 1 } })
  controller:updateFixed({ { type = "pointer_down", pointerId = "p", x = 1, y = 1 } })
  controller:updateFixed({
    { type = "pointer_cancel" },
    { type = "pointer_up", pointerId = "p", x = 1, y = 1 },
  })
  Assert.isNil(controller:takeResult(), "a cancelled press never activates")
  Assert.isTrue(status(controller).open)
  Assert.equal(status(controller).cursorNode, 0, "cancellation changes no selection")
  Assert.equal(status(controller).state, "browse", "cancellation changes no state")
end

function T.browse_dragged_pointer_commits_nothing()
  local controller = newController({ hitTarget = { kind = "cancel" } })
  controller:updateFixed({ { type = "pointer_down", pointerId = "p", x = 1, y = 1 } })
  controller:updateFixed({ { type = "pointer_up", pointerId = "p", x = 9, y = 9, dragged = true } })
  Assert.isNil(controller:takeResult(), "a drag never activates its release target")
  Assert.isTrue(status(controller).open)
end

function T.pick_confirm_returns_the_semantic_slot()
  local controller = newController({ context = "pick", slots = slots(3, { true, false, true }) })
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(status(controller).cursorNode, 2, "navigation skips the ineligible slot")
  controller:updateFixed({ { type = "confirm" } })
  local result = controller:takeResult()
  Assert.deepEqual(result, { kind = "selected", slot = 2 }, "selection carries no source sentinel")
end

function T.pick_rejects_ineligible_and_empty_slots()
  local controller = newController({ context = "pick", slots = slots(3, { true, false, true }) })
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(status(controller).cursorNode, 2, "directional input skips ineligible slots")
  controller:updateFixed({
    { type = "navigate", direction = "down" },
    { type = "navigate", direction = "down" },
    { type = "navigate", direction = "down" },
    { type = "navigate", direction = "down" },
  })
  Assert.equal(status(controller).cursorNode, "cancel", "empty slots never become selectable")
  controller:updateFixed({ { type = "navigate", direction = "up" } })
  controller:updateFixed({ { type = "confirm" } })
  Assert.deepEqual(controller:takeResult(), { kind = "selected", slot = 2 })
end

function T.pick_cancel_returns_cancelled_when_allowed()
  local controller = newController({ context = "pick", allowCancel = true })
  controller:updateFixed({ { type = "cancel" } })
  Assert.deepEqual(controller:takeResult(), { kind = "cancelled" })
end

function T.pick_cancel_is_inert_when_forbidden()
  local controller = newController({ context = "pick", allowCancel = false })
  controller:updateFixed({ { type = "cancel" } })
  Assert.isNil(controller:takeResult(), "a forbidden cancel completes nothing")
  Assert.isTrue(status(controller).open)
  controller:updateFixed({ { type = "confirm" } })
  Assert.deepEqual(controller:takeResult(), { kind = "selected", slot = 0 })
end

function T.completed_controller_ignores_further_input()
  local controller = newController({ context = "pick" })
  controller:updateFixed({ { type = "confirm" } })
  controller:updateFixed({ { type = "navigate", direction = "down" }, { type = "cancel" } })
  Assert.deepEqual(controller:takeResult(), { kind = "selected", slot = 0 })
end

function T.cancelled_pointer_capture_never_activates()
  local controller = newController({ hitTarget = { kind = "cancel" } })
  controller:updateFixed({ { type = "pointer_down", pointerId = "p", x = 1, y = 1 } })
  controller:cancelPointerCapture()
  controller:updateFixed({ { type = "pointer_up", pointerId = "p", x = 1, y = 1 } })
  Assert.isNil(controller:takeResult(), "a capture lost to a layout change activates nothing")
  Assert.isTrue(status(controller).open)
end

function T.browse_dismiss_from_menu_states_closes_immediately()
  local controller = newController()
  controller:updateFixed({ { type = "dismiss" } })
  local result = controller:takeResult()
  Assert.equal(result.kind, "closed", "dismiss closes the party without unwinding")
  Assert.isNil(result.slot, "an outside close carries no slot")
  Assert.isFalse(status(controller).open, "the party is closed")
end

function T.browse_dismiss_from_context_closes_without_activating()
  local controller, calls = newController()
  controller:updateFixed({ { type = "confirm" } })
  Assert.equal(status(controller).state, "context", "setup opens the context menu")
  controller:updateFixed({ { type = "dismiss" } })
  Assert.equal(controller:takeResult().kind, "closed", "dismiss closes instead of activating")
  Assert.isFalse(status(controller).open, "the party is closed")
  Assert.equal(#calls.swaps, 0, "dismiss never swaps")
end

function T.browse_dismiss_ends_the_batch_so_later_events_cannot_overwrite_the_close()
  local controller = newController()
  controller:updateFixed({ { type = "dismiss" }, { type = "confirm" } })
  Assert.equal(controller:takeResult().kind, "closed", "only the terminal close survives the batch")
  Assert.isNil(controller:takeResult(), "the close result is delivered exactly once")
end

function T.pick_dismiss_is_a_programming_error()
  local controller = newController({ context = "pick" })
  local err = Assert.throws(function()
    controller:updateFixed({ { type = "dismiss" } })
  end, "no current producer dismisses script selection")
  Assert.isTrue(
    tostring(err):find("pick", 1, true) ~= nil,
    "the failure must name pick context, not a generic unknown event: " .. tostring(err)
  )
end

-- Native source-shaped contract: named contexts, source-ordered context
-- menus, value-only intents with waiting_action/completeAction, the
-- 35-stage delayed swap commit, epoch-guarded pointer captures, and
-- deterministic animation clocks. These scenarios fail against the mock
-- controller, which knows only view/select modes, immediate swaps, and
-- two hardcoded actions.

local CONTEXT_WINDOW = { x = 152, y = 120, width = 96, height = 64 }

local function nativeSlotFacts(slot0, overrides)
  local facts = {
    slot = slot0,
    occupied = true,
    eligible = true,
    displayName = "MON" .. slot0,
    level = 5,
    gender = "male",
    status = "ok",
    currentHp = 20,
    maxHp = 20,
    isEgg = false,
    heldItem = "NONE",
    capsule = nil,
    moves = {},
    shinyLeaves = 0,
  }
  for key, value in pairs(overrides or {}) do
    facts[key] = value
  end
  return facts
end

local function nativeView(specs)
  local records = {}
  for slot0 = 0, 5 do
    local record = { slot = slot0, occupied = false, eligible = false }
    local spec = specs ~= nil and specs[slot0 + 1] or nil
    if spec ~= nil then
      record = nativeSlotFacts(slot0, spec)
    elseif slot0 < 2 then
      record = nativeSlotFacts(slot0)
    end
    records[slot0 + 1] = record
  end
  return records
end

local function nativeNeighbors()
  return {
    [0] = { down = 1, right = 1 },
    [1] = { up = 0, down = 2, left = 0 },
    [2] = { up = 1, down = 3 },
    [3] = { up = 2, down = 4 },
    [4] = { up = 3, down = 5 },
    [5] = { up = 4, down = "cancel" },
    cancel = { up = 5 },
  }
end

local function nativeLayout(hitTarget, menuCount)
  return {
    neighbors = nativeNeighbors(),
    hitTest = function(_, _)
      return hitTarget
    end,
    contextWindow = CONTEXT_WINDOW,
    menuRows = function(count)
      local rows = {}
      for index = 1, count do
        rows[index] =
          { x = CONTEXT_WINDOW.x, y = CONTEXT_WINDOW.y + (index - 1) * 8, width = CONTEXT_WINDOW.width, height = 8 }
      end
      return rows
    end,
    _menuCount = menuCount,
  }
end

-- A complete explicit action provider double: the full source menu order
-- (summary, switch, item-or-mail, quit, then field moves in move-slot
-- order; eggs get summary, switch, quit), take drives through the
-- yes/no confirm, incompatible targets explain instead of committing.
local function nativePolicy()
  local function menuFor(facts, _)
    if facts.isEgg then
      return {
        { kind = "summary", label = "SUMMARY" },
        { kind = "switch", label = "SWITCH" },
        { kind = "quit", label = "QUIT" },
      }
    end
    local entries = {
      { kind = "summary", label = "SUMMARY" },
      { kind = "switch", label = "SWITCH" },
    }
    if facts.mail == true then
      entries[#entries + 1] = { kind = "mail", label = "MAIL" }
    elseif not facts.isEgg then
      entries[#entries + 1] = { kind = "item", label = "ITEM" }
    end
    entries[#entries + 1] = { kind = "quit", label = "QUIT" }
    for moveSlot, move in ipairs(facts.moves or {}) do
      entries[#entries + 1] = { kind = "field_move", label = move.key, move = move.key, moveSlot = moveSlot - 1 }
    end
    return entries
  end
  local function submenuFor(facts, menuKind)
    if menuKind == "mail" then
      return {
        { kind = "read_mail", label = "READ" },
        { kind = "take_mail", label = "TAKE", confirm = true },
        { kind = "quit", label = "QUIT" },
      }
    end
    if facts.heldItem ~= nil and facts.heldItem ~= "NONE" then
      return {
        { kind = "take", label = "TAKE", confirm = true },
        { kind = "quit", label = "QUIT" },
      }
    end
    return {
      { kind = "give", label = "GIVE" },
      { kind = "quit", label = "QUIT" },
    }
  end
  local function evaluateTarget(facts, contextName)
    if contextName == "item_target" and facts.isEgg then
      return { compatible = false, note = "NO ENTRY" }
    end
    return { compatible = true }
  end
  return { menuFor = menuFor, submenuFor = submenuFor, evaluateTarget = evaluateTarget }
end

local function nativePromptShape()
  return {
    width = 48,
    height = 32,
    yes = { normal = {}, selected = {} },
    no = { normal = {}, selected = {} },
  }
end

---@param opts table?
---@return table controller, table calls, table control
local function nativeController(opts)
  opts = opts or {}
  local calls = { swaps = {} }
  local revision = opts.revision or 11
  local specs = opts.specs
  local controller = PartyScreenController.new({
    context = opts.context or "browse",
    model = {
      refresh = function()
        return { revision = revision, slots = nativeView(specs) }
      end,
    },
    layout = function()
      return nativeLayout(opts.hitTarget)
    end,
    swap = {
      partyRevision = function()
        return revision
      end,
      swapPartyMons = function(a, b)
        calls.swaps[#calls.swaps + 1] = { a, b }
        revision = revision + 1
      end,
    },
    actionPolicy = opts.actionPolicy or nativePolicy(),
    promptShape = nativePromptShape(),
    initialFocus = opts.initialFocus,
    allowCancel = opts.allowCancel,
    item = opts.item,
  })
  return controller, calls, {
    setRevision = function(nextRevision)
      revision = nextRevision
    end,
    setSpecs = function(nextSpecs)
      specs = nextSpecs
      revision = revision + 1
    end,
  }
end

local function nativeStatus(controller)
  return controller:status()
end

function T.browse_confirm_on_occupied_slot_opens_the_context_menu()
  local controller = nativeController()
  controller:updateFixed({ { type = "confirm" } })
  local state = nativeStatus(controller)
  Assert.equal(state.state, "context", "confirming a mon opens its context menu")
  Assert.isTrue(state.menu ~= nil and #state.menu >= 3, "the context menu carries source entries")
  Assert.isNil(controller:takeResult(), "opening the menu completes nothing")
  Assert.isNil(controller:takeIntent(), "opening the menu emits no intent")
end

function T.context_menu_lists_summary_switch_item_quit_then_field_moves()
  local controller = nativeController({
    specs = {
      [1] = { moves = { { key = "CUT" }, { key = "FLY" }, { key = "SURF" }, { key = "STRENGTH" } } },
    },
  })
  controller:updateFixed({ { type = "confirm" } })
  local menu = nativeStatus(controller).menu
  local kinds = {}
  for _, entry in ipairs(menu) do
    kinds[#kinds + 1] = entry.kind
  end
  Assert.deepEqual(
    kinds,
    { "summary", "switch", "item", "quit", "field_move", "field_move", "field_move", "field_move" },
    "the menu follows the source order with field moves in move-slot order"
  )
  Assert.equal(menu[5].move, "CUT")
  Assert.equal(menu[5].moveSlot, 0)
  Assert.equal(menu[8].move, "STRENGTH")
  Assert.equal(menu[8].moveSlot, 3)
end

function T.egg_menu_lists_summary_switch_quit_only()
  local controller = nativeController({ specs = { [1] = { isEgg = true } } })
  controller:updateFixed({ { type = "confirm" } })
  local menu = nativeStatus(controller).menu
  local kinds = {}
  for _, entry in ipairs(menu) do
    kinds[#kinds + 1] = entry.kind
  end
  Assert.deepEqual(kinds, { "summary", "switch", "quit" }, "eggs never offer item or field actions")
end

function T.context_cancel_returns_to_browse_without_result_or_intent()
  local controller = nativeController()
  controller:updateFixed({ { type = "confirm" } })
  Assert.equal(nativeStatus(controller).state, "context")
  controller:updateFixed({ { type = "cancel" } })
  Assert.equal(nativeStatus(controller).state, "browse")
  Assert.isNil(controller:takeResult())
  Assert.isNil(controller:takeIntent())
end

function T.quit_entry_closes_the_screen()
  local controller = nativeController()
  controller:updateFixed({ { type = "confirm" } })
  local menu = nativeStatus(controller).menu
  local quitIndex = #menu
  for _ = 1, quitIndex - 1 do
    controller:updateFixed({ { type = "navigate", direction = "down" } })
  end
  controller:updateFixed({ { type = "confirm" } })
  Assert.deepEqual(controller:takeResult(), { kind = "closed" })
end

function T.switch_entry_enters_swap_destination_pick()
  local controller = nativeController()
  controller:updateFixed({ { type = "confirm" } })
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  controller:updateFixed({ { type = "confirm" } })
  Assert.equal(nativeStatus(controller).state, "choose_swap", "confirming switch arms the destination pick")
  Assert.isNil(controller:takeResult())
  Assert.isNil(controller:takeIntent())
end

function T.swap_drives_35_stages_and_commits_once_at_the_end()
  local controller, calls, model = nativeController()
  controller:updateFixed({ { type = "confirm" } })
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  controller:updateFixed({ { type = "confirm" } })
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  controller:updateFixed({ { type = "confirm" } })
  Assert.equal(nativeStatus(controller).state, "swapping")
  for tick = 1, 34 do
    controller:updateFixed({})
    Assert.equal(#calls.swaps, 0, "no publication before the final stage (tick " .. tick .. ")")
    Assert.equal(nativeStatus(controller).state, "swapping", "the animation still owns the tick " .. tick)
  end
  controller:updateFixed({})
  Assert.equal(#calls.swaps, 1, "the final stage publishes exactly once")
  Assert.deepEqual(calls.swaps[1], { 0, 1 })
  Assert.equal(nativeStatus(controller).state, "browse", "completion returns to browse")
  Assert.equal(nativeStatus(controller).view.revision, 12, "exactly one revision increment is observed")
  model.setRevision(99)
  controller:updateFixed({})
  Assert.equal(#calls.swaps, 1, "post-commit ticks never republish")
end

function T.swap_midpoint_exchanges_temporary_draw_records_only()
  local controller, calls = nativeController()
  controller:updateFixed({ { type = "confirm" } })
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  controller:updateFixed({ { type = "confirm" } })
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  controller:updateFixed({ { type = "confirm" } })
  for _ = 1, 18 do
    controller:updateFixed({})
  end
  Assert.equal(#calls.swaps, 0, "the visual midpoint publishes nothing")
  local swap = nativeStatus(controller).swap
  Assert.isTrue(swap ~= nil and swap.exchanged == true, "temporary draw records exchange at the midpoint")
  Assert.equal(nativeStatus(controller).view.revision, 11, "authoritative order is unchanged at the midpoint")
end

function T.swap_revision_change_aborts_without_mutation()
  local controller, calls, model = nativeController()
  controller:updateFixed({ { type = "confirm" } })
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  controller:updateFixed({ { type = "confirm" } })
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  controller:updateFixed({ { type = "confirm" } })
  for _ = 1, 10 do
    controller:updateFixed({})
  end
  model.setRevision(12)
  for _ = 1, 30 do
    controller:updateFixed({})
  end
  Assert.equal(#calls.swaps, 0, "a stale swap never publishes")
  Assert.equal(nativeStatus(controller).state, "browse", "the abort returns to browse")
end

function T.summary_confirm_emits_a_value_only_intent_once()
  local controller = nativeController()
  controller:updateFixed({ { type = "confirm" } })
  controller:updateFixed({ { type = "confirm" } })
  Assert.equal(nativeStatus(controller).state, "waiting_action")
  local intent = controller:takeIntent()
  Assert.deepEqual(intent, { kind = "summary", slot = 0, partyRevision = 11 })
  Assert.isNil(controller:takeIntent(), "the intent yields exactly once")
  controller:updateFixed({ { type = "confirm" } })
  Assert.isNil(controller:takeIntent(), "waiting never re-emits on extra input")
  Assert.equal(nativeStatus(controller).state, "waiting_action")
end

function T.completeAction_with_noop_returns_to_origin_silently()
  local controller = nativeController()
  controller:updateFixed({ { type = "confirm" } })
  controller:updateFixed({ { type = "confirm" } })
  Assert.equal(nativeStatus(controller).state, "waiting_action")
  controller:takeIntent()
  controller:completeAction({ kind = "no_op" })
  local restored = nativeStatus(controller)
  Assert.equal(restored.state, "context", "the no-op returns to the originating menu state")
  Assert.isNil(restored.prompt, "the armed prompt is released before the intent is emitted")
  Assert.equal(restored.menuIndex, 1, "the no-op restores the menu position")
  Assert.equal(#restored.menu, 4, "the no-op rebuilds the originating menu")
  Assert.isNil(controller:takeResult())
  Assert.isNil(controller:takeIntent(), "the no-op emits no new intent")
end

function T.completeAction_with_text_shows_the_message()
  local controller = nativeController()
  controller:updateFixed({ { type = "confirm" } })
  controller:updateFixed({ { type = "confirm" } })
  Assert.equal(nativeStatus(controller).state, "waiting_action")
  controller:takeIntent()
  controller:completeAction({ kind = "ok", text = "Hello" })
  local shown = nativeStatus(controller)
  Assert.equal(shown.state, "message", "a text outcome shows the message")
  Assert.equal(shown.message, "Hello", "the message carries the outcome text")
  controller:updateFixed({ { type = "confirm" } })
  local resumed = nativeStatus(controller)
  Assert.equal(resumed.state, "context", "acknowledging returns to the originating menu state")
  Assert.isTrue(resumed.menu ~= nil and #resumed.menu == 4, "acknowledging keeps a usable originating menu")
end

function T.completed_action_with_vanished_origin_slot_returns_to_browse()
  local controller, _, control = nativeController()
  controller:updateFixed({ { type = "confirm" } })
  controller:updateFixed({ { type = "confirm" } })
  Assert.equal(nativeStatus(controller).state, "waiting_action")
  controller:takeIntent()
  control.setSpecs({ [1] = { occupied = false }, [2] = {} })
  controller:updateFixed({})
  controller:completeAction({ kind = "no_op" })
  local restored = nativeStatus(controller)
  Assert.equal(
    restored.state,
    "browse",
    "a vanished origin menu falls back to browse, never an empty menu state"
  )
  Assert.isNil(restored.menu, "no menu survives without its originating slot")
  controller:updateFixed({ { type = "confirm" } })
  Assert.equal(
    nativeStatus(controller).state,
    "context",
    "later input opens the surviving mon menu"
  )
end

function T.take_entry_routes_through_the_yesno_confirm()
  local controller = nativeController({ specs = { [1] = { heldItem = "SITRUS_BERRY" } } })
  controller:updateFixed({ { type = "confirm" } })
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  controller:updateFixed({ { type = "confirm" } })
  Assert.equal(nativeStatus(controller).state, "item_context", "item opens its submenu")
  controller:updateFixed({ { type = "confirm" } })
  Assert.equal(nativeStatus(controller).state, "confirm", "take arms the yes/no confirm")
  Assert.isNil(controller:takeIntent(), "arming the confirm emits nothing yet")
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  controller:updateFixed({ { type = "confirm" } })
  Assert.equal(nativeStatus(controller).state, "confirm", "latching starts the confirmation interval")
  Assert.isNil(controller:takeIntent(), "a latched choice publishes nothing yet")
  for _ = 1, 8 do
    controller:updateFixed({})
    Assert.equal(nativeStatus(controller).state, "confirm", "the interval owns its ticks")
  end
  controller:updateFixed({})
  Assert.equal(nativeStatus(controller).state, "waiting_action")
  Assert.deepEqual(controller:takeIntent(), { kind = "take", slot = 0, partyRevision = 11 })
end

function T.pick_context_confirms_a_slot_without_menus()
  local controller = nativeController({ context = "pick" })
  controller:updateFixed({ { type = "confirm" } })
  Assert.deepEqual(controller:takeResult(), { kind = "selected", slot = 0 })
end

function T.pick_context_cancel_returns_cancelled()
  local controller = nativeController({ context = "pick" })
  controller:updateFixed({ { type = "cancel" } })
  Assert.deepEqual(controller:takeResult(), { kind = "cancelled" })
end

function T.item_target_confirm_emits_use_item_with_bag_identity()
  local controller = nativeController({
    context = "item_target",
    item = { key = "POTION", bagRevision = 7 },
  })
  controller:updateFixed({ { type = "confirm" } })
  Assert.equal(nativeStatus(controller).state, "waiting_action")
  Assert.deepEqual(
    controller:takeIntent(),
    { kind = "use_item", slot = 0, partyRevision = 11, bagRevision = 7, item = "POTION" }
  )
end

function T.give_target_confirm_emits_give_with_bag_identity()
  local controller = nativeController({
    context = "give_target",
    item = { key = "SITRUS_BERRY", bagRevision = 7 },
  })
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  controller:updateFixed({ { type = "confirm" } })
  Assert.deepEqual(
    controller:takeIntent(),
    { kind = "give", slot = 1, partyRevision = 11, bagRevision = 7, item = "SITRUS_BERRY" }
  )
end

function T.incompatible_target_confirm_explains_instead_of_committing()
  local controller = nativeController({
    context = "item_target",
    item = { key = "POTION", bagRevision = 7 },
    specs = { [1] = { isEgg = true } },
  })
  controller:updateFixed({ { type = "confirm" } })
  Assert.equal(nativeStatus(controller).state, "message", "incompatibility explains instead of emitting")
  Assert.equal(nativeStatus(controller).message, "NO ENTRY")
  Assert.isNil(controller:takeIntent(), "an explained target emits nothing")
  controller:updateFixed({ { type = "confirm" } })
  Assert.isTrue(nativeStatus(controller).open, "acknowledging returns to picking, not out")
  Assert.isNil(controller:takeResult())
end

function T.held_pointer_across_a_state_change_never_activates()
  local controller = nativeController({ hitTarget = { kind = "slot", slot = 1 } })
  controller:updateFixed({ { type = "pointer_down", pointerId = "p", x = 1, y = 1 } })
  controller:updateFixed({ { type = "confirm" } })
  Assert.equal(nativeStatus(controller).state, "context", "keyboard input moves state while held")
  controller:updateFixed({ { type = "pointer_up", pointerId = "p", x = 1, y = 1 } })
  Assert.equal(nativeStatus(controller).state, "context", "the stale release activates nothing")
  Assert.isNil(controller:takeResult())
  Assert.isNil(controller:takeIntent())
end

function T.unknown_event_raises_inside_prompt_states()
  local controller = nativeController({ specs = { [1] = { heldItem = "SITRUS_BERRY" } } })
  controller:updateFixed({ { type = "confirm" } })
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  controller:updateFixed({ { type = "confirm" } })
  Assert.equal(nativeStatus(controller).state, "item_context")
  controller:updateFixed({ { type = "confirm" } })
  Assert.equal(nativeStatus(controller).state, "confirm")
  local err = Assert.throws(function()
    controller:updateFixed({ { type = "frobnicate" } })
  end, "unknown events raise inside the confirm state")
  Assert.isTrue(tostring(err):find("frobnicate", 1, true) ~= nil)
end

function T.top_panel_slide_advances_source_steps_on_show_and_reverses_on_hide()
  local controller = nativeController()
  controller:updateFixed({ { type = "confirm" } })
  Assert.equal(nativeStatus(controller).anim.panelSlide, 0, "the slide starts at zero on show")
  local seen = {}
  for _ = 1, 4 do
    controller:updateFixed({})
    seen[#seen + 1] = nativeStatus(controller).anim.panelSlide
  end
  Assert.deepEqual(seen, { 12, 24, 36, 40 }, "show advances 0,12,24,36,40")
  controller:updateFixed({ { type = "cancel" } })
  local hid = {}
  for _ = 1, 4 do
    controller:updateFixed({})
    hid[#hid + 1] = nativeStatus(controller).anim.panelSlide
  end
  Assert.deepEqual(hid, { 36, 24, 12, 0 }, "hide clamps in reverse")
end

function T.icon_sequence_tracks_hp_zone_with_phase_reset_on_change()
  local controller = nativeController({
    specs = { [1] = { currentHp = 20, maxHp = 20 }, [2] = { currentHp = 0, maxHp = 20 } },
  })
  controller:updateFixed({})
  local anim = nativeStatus(controller).anim
  Assert.equal(anim.sequences[1], 1, "full health selects sequence 1")
  Assert.equal(anim.sequences[2], 0, "fainted selects sequence 0")
  local first = anim.phases[1]
  controller:updateFixed({})
  controller:updateFixed({})
  Assert.isTrue(nativeStatus(controller).anim.phases[1] ~= first, "the phase advances while healthy")
end

function T.mail_menu_routes_read_directly_and_take_through_confirm()
  local controller = nativeController({ specs = { [1] = { mail = true, heldItem = "TEST_MAIL" } } })
  controller:updateFixed({ { type = "confirm" } })
  local kinds = {}
  for _, entry in ipairs(nativeStatus(controller).menu) do
    kinds[#kinds + 1] = entry.kind
  end
  Assert.deepEqual(kinds, { "summary", "switch", "mail", "quit" })
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  controller:updateFixed({ { type = "confirm" } })
  Assert.equal(nativeStatus(controller).state, "mail_context")
  local sub = {}
  for _, entry in ipairs(nativeStatus(controller).menu) do
    sub[#sub + 1] = entry.kind
  end
  Assert.deepEqual(sub, { "read_mail", "take_mail", "quit" })
  controller:updateFixed({ { type = "confirm" } })
  Assert.deepEqual(controller:takeIntent(), { kind = "read_mail", slot = 0, partyRevision = 11 })
end

function T.give_confirm_waits_for_layout_before_opening_its_prompt()
  local controller = nativeController({
    context = "give_confirm",
    initialFocus = 0,
    item = { key = "SITRUS_BERRY", bagRevision = 7 },
  })
  Assert.isTrue(nativeStatus(controller).state ~= "confirm", "construction opens no prompt yet")
  controller:updateFixed({ { type = "confirm" } })
  local state = nativeStatus(controller)
  Assert.equal(state.state, "confirm", "the first update opens the replacement question")
  Assert.equal(state.prompt and state.prompt.selected, "no", "the question keeps its safe default")
  Assert.isNil(controller:takeIntent(), "the opening batch emits nothing")
  Assert.isNil(controller:takeResult(), "the opening batch completes nothing")
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  controller:updateFixed({ { type = "confirm" } })
  for _ = 1, 8 do
    controller:updateFixed({})
    Assert.equal(nativeStatus(controller).state, "confirm", "the interval owns its ticks")
  end
  controller:updateFixed({})
  Assert.equal(nativeStatus(controller).state, "waiting_action")
  Assert.deepEqual(
    controller:takeIntent(),
    { kind = "give", slot = 0, partyRevision = 11, bagRevision = 7, item = "SITRUS_BERRY", confirmed = true },
    "the ignored opening batch never latches, so Yes still answers"
  )
end

function T.give_confirm_no_answer_cancels_without_an_intent()
  local controller = nativeController({
    context = "give_confirm",
    initialFocus = 1,
    item = { key = "SITRUS_BERRY", bagRevision = 7 },
  })
  controller:updateFixed({})
  Assert.equal(nativeStatus(controller).state, "confirm")
  controller:updateFixed({ { type = "confirm" } })
  local result = nil
  for _ = 1, 20 do
    controller:updateFixed({})
    result = controller:takeResult()
    if result ~= nil then
      break
    end
  end
  Assert.deepEqual(result, { kind = "cancelled" }, "answering No declines the replacement")
  Assert.isNil(controller:takeIntent(), "declining emits no intent")
  Assert.isNil(controller:takeResult(), "the decline reports exactly once")
end

function T.give_confirm_cancel_event_cancels_without_an_intent()
  local controller = nativeController({
    context = "give_confirm",
    initialFocus = 0,
    item = { key = "SITRUS_BERRY", bagRevision = 7 },
  })
  controller:updateFixed({})
  Assert.equal(nativeStatus(controller).state, "confirm")
  controller:updateFixed({ { type = "cancel" } })
  Assert.deepEqual(controller:takeResult(), { kind = "cancelled" }, "cancelling declines the replacement")
  Assert.isNil(controller:takeIntent(), "cancelling emits no intent")
end

function T.give_confirm_dismiss_event_cancels_without_an_intent()
  local controller = nativeController({
    context = "give_confirm",
    initialFocus = 0,
    item = { key = "SITRUS_BERRY", bagRevision = 7 },
  })
  controller:updateFixed({})
  Assert.equal(nativeStatus(controller).state, "confirm")
  controller:updateFixed({ { type = "dismiss" } })
  Assert.deepEqual(controller:takeResult(), { kind = "cancelled" }, "dismissing declines the replacement")
  Assert.isNil(controller:takeIntent(), "dismissing emits no intent")
end

function T.give_confirm_yes_answer_emits_one_confirmed_give_intent()
  local controller = nativeController({
    context = "give_confirm",
    initialFocus = 0,
    item = { key = "SITRUS_BERRY", bagRevision = 7 },
  })
  controller:updateFixed({})
  Assert.equal(nativeStatus(controller).state, "confirm")
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  controller:updateFixed({ { type = "confirm" } })
  for tick = 1, 8 do
    controller:updateFixed({})
    Assert.equal(nativeStatus(controller).state, "confirm", "the confirmation interval owns its ticks (" .. tick .. ")")
  end
  controller:updateFixed({})
  Assert.equal(nativeStatus(controller).state, "waiting_action")
  Assert.deepEqual(
    controller:takeIntent(),
    { kind = "give", slot = 0, partyRevision = 11, bagRevision = 7, item = "SITRUS_BERRY", confirmed = true },
    "only the affirmative answer authorizes the exchange"
  )
  Assert.isNil(controller:takeIntent(), "the intent yields exactly once")
  Assert.isNil(controller:takeResult(), "accepting completes nothing itself")
end

function T.give_confirm_requires_its_pending_item()
  Assert.throws(function()
    nativeController({ context = "give_confirm", initialFocus = 0 })
  end, "the replacement question names its pending item")
end

function T.give_confirm_requires_a_numeric_target_slot()
  Assert.throws(function()
    nativeController({
      context = "give_confirm",
      item = { key = "SITRUS_BERRY", bagRevision = 7 },
    })
  end, "the replacement question targets a party slot")
end

return { tests = T }
