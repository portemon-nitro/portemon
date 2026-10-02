-- The native party-screen controller: named browse/pick/item_target and
-- give_target contexts over an injected immutable view, injected swap port,
-- injected action policy, and revision reconciliation. Pointer input shares
-- the keyboard/gamepad confirm path with epoch-guarded captures; results
-- are one-shot semantic records with no source sentinels.

local Assert = require("tests.support.Assert")
local PartyPresentationFixture = require("tests.support.PartyPresentationFixture")
local PartyScreenController = require("libs.hgss.src.ui.PartyScreenController")
local PartyScreenLayout = require("libs.hgss.src.ui.PartyScreenLayout")

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
  local generated = PartyScreenLayout.resolve({ manifest = PartyPresentationFixture.manifest(), cancellable = true })
  return {
    neighbors = NEIGHBORS,
    hitTest = function(_, _)
      return hitTarget
    end,
    menuLayout = generated.menuLayout,
    menuHit = generated.menuHit,
    promptAnchor = generated.promptAnchor,
  }
end

local function nativePartyLayout()
  local panels = {}
  for slot0 = 0, 5 do
    panels[slot0 + 1] = {
      origin = { x = (slot0 % 2) * 128, y = math.floor(slot0 / 2) * 48 },
      size = { width = 128, height = 48 },
    }
  end
  local function box(up, down, leftNeighbor, rightNeighbor)
    return {
      up = up,
      down = down,
      leftNeighbor = leftNeighbor,
      rightNeighbor = rightNeighbor,
      left = 0,
      top = 0,
      width = 0,
      height = 0,
    }
  end
  local function touch(top, bottom, left, right)
    return { top = top, bottom = bottom, left = left, right = right }
  end
  return PartyScreenLayout.resolve({
    manifest = {
      panels = panels,
      windows = {
        context = { x = 152, y = 120, width = 96, height = 64 },
        prompt = { x = 200, y = 80 },
      },
      navigation = {
        dpad = {
          default = {
            box(7, 2, 7, 1),
            box(7, 3, 0, 2),
            box(0, 4, 1, 3),
            box(1, 5, 2, 4),
            box(2, 7, 3, 5),
            box(3, 7, 4, 7),
            box(0, 0, 0, 0),
            box(5, 1, 5, 0),
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
    },
    cancellable = true,
  })
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
      return opts.layout or fakeLayout(opts.hitTarget)
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
    effect = opts.effect,
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

function T.browse_cancel_exits_in_every_direction_with_a_sparse_party()
  local cases = {
    { direction = "up", expected = 0 },
    { direction = "down", expected = 1 },
    { direction = "left", expected = 1 },
    { direction = "right", expected = 0 },
  }
  for _, case in ipairs(cases) do
    local controller = newController({ slots = slots(2), layout = nativePartyLayout() })
    controller:updateFixed({ { type = "navigate", direction = "down" } })
    Assert.equal(status(controller).cursorNode, "cancel", "the sparse party reaches Cancel")
    controller:updateFixed({ { type = "navigate", direction = case.direction } })
    Assert.equal(
      status(controller).cursorNode,
      case.expected,
      case.direction .. " from Cancel reaches an occupied slot"
    )
  end
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
  local generated = PartyScreenLayout.resolve({ manifest = PartyPresentationFixture.manifest(), cancellable = true })
  return {
    neighbors = nativeNeighbors(),
    hitTest = function(_, _)
      return hitTarget
    end,
    menuLayout = generated.menuLayout,
    menuHit = generated.menuHit,
    promptAnchor = generated.promptAnchor,
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
      return opts.layout or nativeLayout(opts.hitTarget)
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
    initialMessage = opts.initialMessage,
    allowCancel = opts.allowCancel,
    item = opts.item,
    effect = opts.effect,
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

function T.initial_message_enters_the_party_owned_acknowledgement_state()
  local controller = nativeController({
    initialMessage = { templateKey = "giveHeldItem", displayName = "LEAD", itemNames = { "GREAT BALL" } },
  })
  local shown = controller:status()
  Assert.equal(shown.state, "message", "the initial result enters the owned message state")
  Assert.equal(shown.message.templateKey, "giveHeldItem", "the source template remains a descriptor")
  controller:updateFixed({ { type = "confirm" } })
  local resumed = controller:status()
  Assert.equal(resumed.state, "browse", "acknowledgement returns to browse")
end

local function nativeStatus(controller)
  return controller:status()
end

-- Advances one armed menu press through its visual cadence to the single
-- semantic dispatch: two pressed ticks, two selected ticks, then dispatch.
local function pressThrough(controller)
  for _ = 1, 4 do
    controller:updateFixed({})
  end
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
  pressThrough(controller)
  Assert.deepEqual(controller:takeResult(), { kind = "closed" })
end

function T.switch_entry_enters_swap_destination_pick()
  local controller = nativeController()
  controller:updateFixed({ { type = "confirm" } })
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  controller:updateFixed({ { type = "confirm" } })
  pressThrough(controller)
  Assert.equal(nativeStatus(controller).state, "choose_swap", "confirming switch arms the destination pick")
  Assert.isNil(controller:takeResult())
  Assert.isNil(controller:takeIntent())
end

function T.swap_drives_35_stages_and_commits_once_at_the_end()
  local controller, calls, model = nativeController()
  controller:updateFixed({ { type = "confirm" } })
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  controller:updateFixed({ { type = "confirm" } })
  pressThrough(controller)
  Assert.equal(nativeStatus(controller).state, "choose_swap", "the gated switch entry arms the destination pick")
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
  pressThrough(controller)
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
  pressThrough(controller)
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
  pressThrough(controller)
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
  pressThrough(controller)
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
  pressThrough(controller)
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

function T.completed_action_after_party_revision_change_returns_to_browse()
  local controller, _, control = nativeController()
  controller:updateFixed({ { type = "confirm" } })
  controller:updateFixed({ { type = "confirm" } })
  pressThrough(controller)
  Assert.equal(nativeStatus(controller).state, "waiting_action")
  controller:takeIntent()
  control.setSpecs({ [1] = { heldItem = "POTION" }, [2] = {} })
  controller:updateFixed({})
  controller:completeAction({ kind = "no_op" })
  local restored = nativeStatus(controller)
  Assert.equal(restored.state, "browse", "a changed party revision discards the originating menu")
  Assert.isNil(restored.menu, "no menu survives a stale action return")
  Assert.isTrue(restored.view.slots[1].occupied, "the origin slot remains occupied")
  Assert.equal(restored.cursorNode, 0, "the cursor reconciles to a selectable slot")
end

function T.take_entry_routes_through_the_yesno_confirm()
  local controller = nativeController({ specs = { [1] = { heldItem = "SITRUS_BERRY" } } })
  controller:updateFixed({ { type = "confirm" } })
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  controller:updateFixed({ { type = "confirm" } })
  pressThrough(controller)
  Assert.equal(nativeStatus(controller).state, "item_context", "item opens its submenu")
  controller:updateFixed({ { type = "confirm" } })
  pressThrough(controller)
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
  pressThrough(controller)
  Assert.equal(nativeStatus(controller).state, "item_context")
  controller:updateFixed({ { type = "confirm" } })
  pressThrough(controller)
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
  local first = anim.sequenceTicks[1]
  controller:updateFixed({})
  controller:updateFixed({})
  Assert.isTrue(
    nativeStatus(controller).anim.sequenceTicks[1] ~= first,
    "the sequence-local tick advances while healthy"
  )
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
  pressThrough(controller)
  Assert.equal(nativeStatus(controller).state, "mail_context")
  local sub = {}
  for _, entry in ipairs(nativeStatus(controller).menu) do
    sub[#sub + 1] = entry.kind
  end
  Assert.deepEqual(sub, { "read_mail", "take_mail", "quit" })
  controller:updateFixed({ { type = "confirm" } })
  pressThrough(controller)
  Assert.deepEqual(controller:takeIntent(), { kind = "read_mail", slot = 0, partyRevision = 11 })
end

function T.give_resume_emits_once_after_first_eligible_update()
  local controller = nativeController({
    context = "give_resume",
    initialFocus = 0,
    item = { key = "SITRUS_BERRY", bagRevision = 7 },
  })
  Assert.equal(nativeStatus(controller).state, "give_resume", "construction only records the continuation")
  Assert.isNil(controller:takeIntent(), "construction does not emit the held-item operation")
  Assert.isNil(controller:takeIntent(), "status and intent reads do not arm it")
  controller:updateFixed({ { type = "confirm" } })
  Assert.deepEqual(
    controller:takeIntent(),
    { kind = "give", slot = 0, partyRevision = 11, bagRevision = 7, item = "SITRUS_BERRY" },
    "the first eligible update emits the captured operation without replaying input"
  )
  Assert.isNil(controller:takeIntent(), "the operation emits exactly once")
  Assert.equal(nativeStatus(controller).state, "waiting_action")
end

function T.give_resume_decline_returns_to_browse_in_the_same_controller()
  local controller = nativeController({
    context = "give_resume",
    initialFocus = 1,
    item = { key = "SITRUS_BERRY", bagRevision = 7 },
  })
  controller:updateFixed({})
  Assert.notNil(controller:takeIntent(), "the continuation starts its held-item operation")
  controller:completeAction({
    kind = "needs_confirmation",
    disposition = "party",
    message = { templateKey = "switchHeldPrompt", displayName = "LEAD", itemNames = { "CHERI BERRY" } },
  })
  Assert.equal(nativeStatus(controller).state, "message", "the replacement text appears before Yes/No")
  controller:updateFixed({ { type = "confirm" } })
  Assert.equal(nativeStatus(controller).state, "give_question", "message acknowledgement opens the prompt on a later tick")
  controller:updateFixed({})
  Assert.equal(nativeStatus(controller).state, "confirm")
  controller:updateFixed({ { type = "cancel" } })
  Assert.deepEqual(controller:takeResult(), { kind = "give_complete" }, "decline completes in the same Party child")
  Assert.equal(nativeStatus(controller).context, "browse", "the same controller becomes ordinary browse")
  Assert.equal(nativeStatus(controller).state, "browse")
end

function T.give_resume_yes_shows_ordered_result_then_browses_in_place()
  local controller = nativeController({
    context = "give_resume",
    initialFocus = 0,
    item = { key = "SITRUS_BERRY", bagRevision = 7 },
  })
  controller:updateFixed({})
  controller:takeIntent()
  controller:completeAction({
    kind = "needs_confirmation",
    disposition = "party",
    message = { templateKey = "switchHeldPrompt", displayName = "LEAD", itemNames = { "CHERI BERRY" } },
  })
  controller:updateFixed({ { type = "confirm" } })
  controller:updateFixed({})
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  controller:updateFixed({ { type = "confirm" } })
  for _ = 1, 8 do
    controller:updateFixed({})
  end
  controller:updateFixed({})
  Assert.deepEqual(
    controller:takeIntent(),
    { kind = "give", slot = 0, partyRevision = 11, bagRevision = 7, item = "SITRUS_BERRY", confirmed = true },
    "Yes emits one revision-qualified confirmed request"
  )
  controller:completeAction({
    kind = "changed",
    disposition = "party",
    message = {
      templateKey = "switchHeldResult",
      displayName = "LEAD",
      itemNames = { "CHERI BERRY", "SITRUS BERRY" },
    },
  })
  Assert.equal(nativeStatus(controller).state, "message", "the swap result stays in the active child")
  controller:updateFixed({ { type = "confirm" } })
  Assert.deepEqual(controller:takeResult(), { kind = "give_complete" })
  Assert.equal(nativeStatus(controller).context, "browse")
  Assert.equal(nativeStatus(controller).state, "browse")
end

function T.bag_give_question_decline_returns_from_the_same_controller()
  local controller = nativeController({
    context = "give_target",
    item = { key = "SITRUS_BERRY", bagRevision = 7 },
  })
  controller:updateFixed({ { type = "confirm" } })
  local intent = assert(controller:takeIntent(), "the target selection emits its give")
  controller:completeAction({
    kind = "needs_confirmation",
    disposition = "bag",
    message = { templateKey = "switchHeldPrompt", displayName = "LEAD", itemNames = { "CHERI BERRY" } },
  })
  controller:updateFixed({ { type = "confirm" } })
  controller:updateFixed({})
  controller:updateFixed({ { type = "cancel" } })
  Assert.deepEqual(controller:takeResult(), { kind = "cancelled" }, "Bag caller returns after the in-place decline")
  Assert.isFalse(nativeStatus(controller).open, "the original Bag-origin target child returns to its caller")
  Assert.notNil(intent)
end

function T.give_resume_requires_its_pending_item_and_slot()
  Assert.throws(function()
    nativeController({ context = "give_resume", initialFocus = 0 })
  end, "the give continuation names its pending item")
  Assert.throws(function()
    nativeController({ context = "give_resume", item = { key = "SITRUS_BERRY", bagRevision = 7 } })
  end, "the give continuation targets a party slot")
end

-- Source-faithful native behavior: exact icon sequence clocks, generated
-- menu topology and press cadence, native prompt placement, and cancel
-- safety across large menus. The status facts asserted below
-- (sequence-local ticks, the armed menu press) are the proposed
-- presentation contract the renderer will consume: the exact helper and
-- status field names are an internal detail, while the asserted
-- relationships (tick reset on sequence
-- change, still sequence while swapping, pressed/selected cadence with
-- exactly one dispatch, neighbor-exact navigation) are not.
local function v3Layout()
  return PartyScreenLayout.resolve({ manifest = PartyPresentationFixture.manifest(), cancellable = true })
end

local function generatedTopLevel(count)
  return PartyPresentationFixture.manifest().contextMenu.topLevel[count]
end

local function sequenceTicks(controller)
  local anim = nativeStatus(controller).anim ---@type any
  return assert(anim.sequenceTicks, "the status publishes sequence-local ticks")
end

function T.swapping_slots_present_the_still_sequence()
  local controller = nativeController({ layout = v3Layout() })
  controller:updateFixed({ { type = "confirm" } })
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  controller:updateFixed({ { type = "confirm" } })
  pressThrough(controller)
  Assert.equal(nativeStatus(controller).state, "choose_swap", "the gated switch entry arms the destination pick")
  controller:updateFixed({ { type = "navigate", direction = "right" } })
  controller:updateFixed({ { type = "confirm" } })
  Assert.equal(nativeStatus(controller).state, "swapping")
  local sequences = nativeStatus(controller).anim.sequences
  Assert.equal(sequences[1], 0, "the swap source presents the still sequence")
  Assert.equal(sequences[2], 0, "the swap destination presents the still sequence")
end

function T.sequence_local_ticks_advance_and_reset_with_the_sequence()
  local controller, _, control = nativeController({ layout = v3Layout() })
  controller:updateFixed({})
  Assert.equal(sequenceTicks(controller)[1], 0, "ticks start at the sequence base")
  controller:updateFixed({})
  controller:updateFixed({})
  controller:updateFixed({})
  Assert.equal(sequenceTicks(controller)[1], 3, "steady health advances its local tick")
  control.setSpecs({ [1] = { currentHp = 0, maxHp = 20 } })
  controller:updateFixed({})
  Assert.equal(nativeStatus(controller).anim.sequences[1], 0, "fainting selects the still sequence")
  Assert.equal(sequenceTicks(controller)[1], 0, "a sequence change resets its local tick exactly once")
  controller:updateFixed({})
  Assert.equal(sequenceTicks(controller)[1], 1, "the new sequence advances from its reset base")
end

function T.menu_navigation_follows_the_generated_top_level_neighbors()
  local expected = generatedTopLevel(4)
  local controller = nativeController({ layout = v3Layout() })
  controller:updateFixed({ { type = "confirm" } })
  Assert.equal(#nativeStatus(controller).menu, 4, "setup opens the four-entry menu")
  controller:updateFixed({ { type = "navigate", direction = "up" } })
  Assert.equal(
    nativeStatus(controller).menuIndex,
    expected[1].up,
    "up from the first entry wraps through the generated neighbor"
  )
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(nativeStatus(controller).menuIndex, 1, "down returns through the generated neighbor")
  controller:updateFixed({ { type = "navigate", direction = "left" } })
  Assert.equal(
    nativeStatus(controller).menuIndex,
    expected[1].left,
    "left follows the generated lateral relation"
  )
  controller:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.equal(
    nativeStatus(controller).menuIndex,
    expected[expected[1].left].right,
    "right follows the generated lateral relation"
  )
end

function T.subcontext_navigation_wraps_and_ignores_lateral_input()
  local controller = nativeController({ layout = v3Layout() })
  controller:updateFixed({ { type = "confirm" } })
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  controller:updateFixed({ { type = "confirm" } })
  pressThrough(controller)
  Assert.equal(nativeStatus(controller).state, "item_context", "setup opens the two-entry item submenu")
  controller:updateFixed({ { type = "navigate", direction = "up" } })
  Assert.equal(nativeStatus(controller).menuIndex, 2, "up from the first subcontext entry wraps")
  controller:updateFixed({ { type = "navigate", direction = "left" } })
  Assert.equal(nativeStatus(controller).menuIndex, 2, "left leaves subcontext focus alone")
  controller:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.equal(nativeStatus(controller).menuIndex, 2, "right leaves subcontext focus alone")
  Assert.isNil(controller:takeIntent(), "lateral input dispatches nothing")
end

function T.menu_activation_waits_for_the_press_cadence_before_dispatch()
  local controller = nativeController({ layout = v3Layout() })
  controller:updateFixed({ { type = "confirm" } })
  controller:updateFixed({ { type = "confirm" } })
  Assert.isNil(controller:takeIntent(), "activation arms the press instead of dispatching")
  local armed = nativeStatus(controller).menuPress ---@type any
  Assert.notNil(armed, "the status publishes the armed press")
  Assert.equal(armed.index, 1, "the press captures the focused entry")
  Assert.equal(armed.phase, "pressed", "the first half shows the pressed presentation")
  controller:updateFixed({})
  controller:updateFixed({})
  local held = nativeStatus(controller).menuPress ---@type any
  Assert.notNil(held, "the press stays armed through its first half")
  Assert.equal(held.phase, "selected", "the second half shows the selected presentation")
  Assert.isNil(controller:takeIntent(), "the cadence dispatches nothing early")
  controller:updateFixed({})
  controller:updateFixed({})
  Assert.isNil(nativeStatus(controller).menuPress, "completion clears the armed press")
  local intent = controller:takeIntent()
  Assert.deepEqual(intent, { kind = "summary", slot = 0, partyRevision = 11 })
  Assert.isNil(controller:takeIntent(), "the gated entry dispatches exactly once")
end

function T.extra_activation_while_armed_dispatches_nothing_more()
  local controller = nativeController({ layout = v3Layout() })
  controller:updateFixed({ { type = "confirm" } })
  controller:updateFixed({ { type = "confirm" } })
  controller:updateFixed({ { type = "confirm" } })
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  controller:updateFixed({ { type = "cancel" } })
  for _ = 1, 6 do
    controller:updateFixed({})
  end
  local first = controller:takeIntent()
  Assert.notNil(first, "the armed entry still dispatches once")
  Assert.isNil(controller:takeIntent(), "extra input while armed adds no second dispatch")
end

function T.pointer_activation_shares_the_press_gate()
  local controller = nativeController({ layout = v3Layout() })
  controller:updateFixed({ { type = "confirm" } })
  local touch = generatedTopLevel(4)[1].touch
  local right = touch.right == 0 and 256 or touch.right
  local tapX, tapY = touch.left + math.floor((right - touch.left) / 2), touch.top + 1
  controller:updateFixed({ { type = "pointer_down", pointerId = "p", x = tapX, y = tapY } })
  controller:updateFixed({ { type = "pointer_up", pointerId = "p", x = tapX, y = tapY } })
  Assert.isNil(controller:takeIntent(), "a pointer tap arms the press instead of dispatching")
  local armed = nativeStatus(controller).menuPress ---@type any
  Assert.notNil(armed, "the status publishes the pointer-armed press")
  Assert.equal(armed.index, 1, "the tap captures its row entry")
  for _ = 1, 4 do
    controller:updateFixed({})
  end
  Assert.deepEqual(controller:takeIntent(), { kind = "summary", slot = 0, partyRevision = 11 })
end

function T.confirmation_opens_at_the_native_prompt_anchor()
  local controller = nativeController({
    layout = v3Layout(),
    specs = { [1] = { heldItem = "SITRUS_BERRY" } },
  })
  controller:updateFixed({ { type = "confirm" } })
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  controller:updateFixed({ { type = "confirm" } })
  pressThrough(controller)
  Assert.equal(nativeStatus(controller).state, "item_context", "the gated item entry opens its submenu")
  controller:updateFixed({ { type = "confirm" } })
  pressThrough(controller)
  Assert.equal(nativeStatus(controller).state, "confirm")
  local prompt = assert(nativeStatus(controller).prompt, "the confirm state carries its prompt")
  Assert.deepEqual(
    { prompt.buttons.yes.x, prompt.buttons.yes.y },
    { 200, 80 },
    "the confirmation opens at the native yes/no anchor"
  )
end

function T.opening_a_menu_without_a_generated_layout_fails_before_arming()
  local entries = {}
  for index = 1, 9 do
    entries[index] = { kind = "field_move", label = "F" .. index, move = "F" .. index, moveSlot = index - 1 }
  end
  local policy = nativePolicy()
  policy.menuFor = function()
    return entries
  end
  local controller = nativeController({ layout = v3Layout(), actionPolicy = policy })
  local err = Assert.throws(function()
    controller:updateFixed({ { type = "confirm" } })
  end, "nine entries exceed the generated top-level range")
  Assert.isTrue(tostring(err):find("9", 1, true) ~= nil, "the failure names its count")
  Assert.isNil(controller:takeIntent(), "a failed menu opening dispatches nothing")
end

function T.cancel_from_an_eight_entry_menu_returns_to_browse_cleanly()
  local controller = nativeController({
    layout = v3Layout(),
    specs = {
      [1] = { moves = { { key = "CUT" }, { key = "FLY" }, { key = "SURF" }, { key = "STRENGTH" } } },
    },
  })
  controller:updateFixed({ { type = "confirm" } })
  Assert.equal(#nativeStatus(controller).menu, 8, "setup opens the eight-entry menu")
  for _ = 1, 7 do
    controller:updateFixed({ { type = "navigate", direction = "down" } })
  end
  Assert.equal(nativeStatus(controller).menuIndex, 8, "the cancel-position entry stays reachable")
  controller:updateFixed({ { type = "cancel" } })
  Assert.equal(nativeStatus(controller).state, "browse")
  Assert.isNil(controller:takeResult())
  Assert.isNil(controller:takeIntent())
  Assert.isNil(nativeStatus(controller).menu, "cancelling releases the menu")
end

function T.browse_cancel_focus_leaves_no_menu_state()
  local controller = nativeController({ layout = v3Layout() })
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(nativeStatus(controller).cursorNode, "cancel", "setup focuses Cancel")
  controller:updateFixed({ { type = "cancel" } })
  Assert.deepEqual(controller:takeResult(), { kind = "closed" })
  Assert.isNil(nativeStatus(controller).menu, "focusing Cancel never builds menu state")
end

function T.pointer_down_latches_its_row_across_keyboard_focus_changes()
  local controller = nativeController({ layout = v3Layout() })
  controller:updateFixed({ { type = "confirm" } })
  Assert.equal(#nativeStatus(controller).menu, 4, "setup opens the four-entry menu")
  local first = generatedTopLevel(4)[1].touch
  local tapX = first.left + 1
  local tapY = first.top + 1
  controller:updateFixed({ { type = "pointer_down", pointerId = "p", x = tapX, y = tapY } })
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(nativeStatus(controller).menuIndex, 3, "keyboard motion moves focus away from the held row")
  controller:updateFixed({ { type = "pointer_up", pointerId = "p", x = tapX, y = tapY } })
  local armed = nativeStatus(controller).menuPress ---@type any
  Assert.notNil(armed, "the matching release arms the press")
  Assert.equal(armed.index, 1, "the armed entry is the latched down-target, not the moved focus")
  pressThrough(controller)
  local intent = controller:takeIntent()
  Assert.notNil(intent, "the latched entry dispatches once")
end

-- Column-parity switch motion: each slot exits outward from its own
-- column at eight units per source tick, presentation records exchange
-- at full exit while the party order holds, and the list sound fires at
-- the start and the midpoint with the order committing once at the end.
-- Statuses publish the per-slot contract the renderer consumes: an
-- integral tile-step clock plus a signed-unit map keyed by slot.
local SWITCH_SOUND = "SEQ_SE_DP_POKELIST_001"
local SWITCH_STEP_PX = 8
local SWITCH_FULL_STEPS = 16

local function columnDirection(slot0)
  if slot0 % 2 == 0 then
    return -1
  end
  return 1
end

---@param swap table
---@param slot0 integer
---@return number signed slide in units
local function slotSlidePx(swap, slot0)
  local offsets = assert(swap.offsets, "the swap publishes its per-slot slide map")
  local slide = assert(offsets[slot0], "the swap slides every travelling slot")
  assert(type(slide) == "number", "the swap publishes numeric slide offsets")
  return slide
end

---@param swap table
---@return number integral tile-step clock
local function swapClock(swap)
  assert(swap.xOffset % 1 == 0 and swap.xOffset >= 0, "the swap clock stays a non-negative integer")
  return swap.xOffset
end

---@param opts table?
---@return table controller, table calls, table control, string[] sounds
local function soundingController(opts)
  opts = opts or {}
  local sounds = {}
  opts.effect = function(sequence)
    sounds[#sounds + 1] = sequence
  end
  local controller, calls, control = nativeController(opts)
  return controller, calls, control, sounds
end

function T.root_back_plays_one_source_cancel_effect_and_closes_once()
  local rootBack, _, _, rootSounds = soundingController()
  rootBack:updateFixed({ { type = "cancel" } })
  Assert.deepEqual(rootBack:takeResult(), { kind = "closed" }, "root B closes the Party")
  Assert.deepEqual(rootSounds, { "SEQ_SE_GS_GEARCANCEL" }, "root B requests one cancel sound")
  Assert.isNil(rootBack:takeResult(), "root B close is delivered once")
  rootBack:dispose()
  Assert.deepEqual(rootSounds, { "SEQ_SE_GS_GEARCANCEL" }, "draining and disposal do not replay the sound")
end

function T.main_cancel_plays_one_source_cancel_effect_and_closes()
  local mainCancel, _, _, cancelSounds = soundingController({ initialFocus = "cancel" })
  mainCancel:updateFixed({ { type = "confirm" } })
  Assert.deepEqual(mainCancel:takeResult(), { kind = "closed" }, "main CANCEL closes the Party")
  Assert.deepEqual(cancelSounds, { "SEQ_SE_GS_GEARCANCEL" }, "main CANCEL requests one cancel sound")
end

function T.top_level_quit_plays_one_source_cancel_effect_and_closes()
  local quit, _, _, quitSounds = soundingController()
  quit:updateFixed({ { type = "confirm" } })
  for _ = 1, #nativeStatus(quit).menu - 1 do
    quit:updateFixed({ { type = "navigate", direction = "down" } })
  end
  quit:updateFixed({ { type = "confirm" } })
  pressThrough(quit)
  Assert.deepEqual(quit:takeResult(), { kind = "closed" }, "top-level QUIT closes the Party")
  Assert.deepEqual(quitSounds, { "SEQ_SE_GS_GEARCANCEL" }, "top-level QUIT requests one cancel sound")
end

local function fourLeadSpecs()
  return { [1] = {}, [2] = {}, [3] = {}, [4] = {} }
end

-- Opens the context menu on the focused slot and arms the switch
-- destination pick through the gated press cadence.
---@param controller table
local function armSwitch(controller)
  controller:updateFixed({ { type = "confirm" } })
  Assert.equal(nativeStatus(controller).state, "context", "setup opens the context menu")
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  controller:updateFixed({ { type = "confirm" } })
  pressThrough(controller)
  Assert.equal(nativeStatus(controller).state, "choose_swap", "the switch entry arms the destination pick")
end

-- Starts the switch animation from the focused source toward the
-- destination reached through the given moves.
---@param controller table
---@param destination integer
---@param moves string[]
local function beginSwap(controller, destination, moves)
  armSwitch(controller)
  for _, direction in ipairs(moves) do
    controller:updateFixed({ { type = "navigate", direction = direction } })
  end
  Assert.equal(nativeStatus(controller).cursorNode, destination, "setup focuses the destination slot")
  controller:updateFixed({ { type = "confirm" } })
  Assert.equal(nativeStatus(controller).state, "swapping", "confirming the destination starts the animation")
end

-- Advances until the midpoint exchange, asserting each outward step
-- slides both slots exactly one tile-step outward from their columns
-- when motion checks are on. Returns the midpoint record.
---@param controller table
---@param source integer
---@param destination integer
---@param checkMotion boolean?
---@return table midpoint swap record
local function driveOutward(controller, source, destination, checkMotion)
  local stalledAtStart = false
  for _ = 1, 60 do
    local swap = assert(nativeStatus(controller).swap, "the outward leg publishes its swap record")
    if swap.exchanged == true then
      Assert.equal(swapClock(swap), SWITCH_FULL_STEPS, "the exchange happens at full exit")
      return swap
    end
    local before = swapClock(swap)
    controller:updateFixed({})
    local progressed = nativeStatus(controller).swap
    if progressed ~= nil and progressed.exchanged ~= true then
      local after = swapClock(progressed)
      if after == before then
        Assert.isTrue(
          before == 0 and not stalledAtStart,
          "only the start presentation tick holds the clock at zero"
        )
        stalledAtStart = true
      else
        Assert.equal(after, before + 1, "each outward tick advances exactly one tile-step")
        if checkMotion ~= false then
          for _, slot0 in ipairs({ source, destination }) do
            Assert.equal(
              slotSlidePx(progressed, slot0),
              columnDirection(slot0) * after * SWITCH_STEP_PX,
              "slot " .. slot0 .. " exits outward from its own column"
            )
          end
        end
      end
    end
  end
  error("the outward leg never reaches its exchange", 0)
end

-- Advances until the animation clears, asserting each inward step
-- returns both slots exactly one tile-step with the direction inverted
-- when motion checks are on. Returns every observed inward clock.
---@param controller table
---@param source integer
---@param destination integer
---@param checkMotion boolean?
---@return number[]
local function driveInward(controller, source, destination, checkMotion)
  local clocks = {}
  for _ = 1, 60 do
    local swap = nativeStatus(controller).swap
    if swap == nil then
      return clocks
    end
    local before = swapClock(swap)
    controller:updateFixed({})
    local progressed = nativeStatus(controller).swap
    if progressed ~= nil then
      local after = swapClock(progressed)
      Assert.equal(after, before - 1, "each inward tick returns exactly one tile-step")
      clocks[#clocks + 1] = after
      if checkMotion ~= false then
        for _, slot0 in ipairs({ source, destination }) do
          Assert.equal(
            slotSlidePx(progressed, slot0),
            columnDirection(slot0) * after * SWITCH_STEP_PX,
            "slot " .. slot0 .. " returns inward along its own column"
          )
        end
      end
    end
  end
  error("the inward leg never clears", 0)
end

function T.switch_mixed_columns_exit_opposite_sides()
  local controller = soundingController()
  beginSwap(controller, 1, { "down" })
  driveOutward(controller, 0, 1)
end

function T.switch_even_pair_exits_left_together()
  local controller = soundingController({ specs = fourLeadSpecs(), initialFocus = 0 })
  beginSwap(controller, 2, { "down", "down" })
  driveOutward(controller, 0, 2)
end

function T.switch_odd_pair_exits_right_together()
  local controller = soundingController({ specs = fourLeadSpecs(), initialFocus = 1 })
  beginSwap(controller, 3, { "down", "down" })
  driveOutward(controller, 1, 3)
end

function T.switch_tile_clock_covers_zero_to_sixteen_with_no_over_tick()
  local controller, calls, _, sounds = soundingController()
  local revision = nativeStatus(controller).view.revision
  beginSwap(controller, 1, { "down" })
  local clocks = {}
  local first = swapClock(assert(nativeStatus(controller).swap, "the animation publishes its clock"))
  Assert.equal(first, 0, "arming holds tile-step zero until the first swap tick")
  driveOutward(controller, 0, 1, false)
  for _ = 1, 60 do
    local swap = nativeStatus(controller).swap
    if swap == nil then
      break
    end
    local clock = swapClock(swap)
    clocks[#clocks + 1] = clock
    Assert.isTrue(clock % 1 == 0 and clock >= 0 and clock <= 16, "every swap clock stays within 0..16")
    controller:updateFixed({})
  end
  Assert.isNil(nativeStatus(controller).swap, "the animation clears its swap record")
  local seen16, seen0 = false, false
  for _, clock in ipairs(clocks) do
    seen16 = seen16 or clock == 16
    seen0 = seen0 or clock == 0
  end
  Assert.isTrue(seen16, "the animation reaches full exit")
  Assert.isTrue(seen0, "the animation returns to zero before committing")
  Assert.equal(#calls.swaps, 1, "the return commits exactly once")
  Assert.equal(nativeStatus(controller).view.revision, revision + 1, "exactly one revision publishes")
  Assert.deepEqual(sounds, { SWITCH_SOUND, SWITCH_SOUND }, "start and midpoint sound exactly once each")
end

function T.switch_start_sounds_once_the_first_step_moves()
  local controller, _, _, sounds = soundingController()
  beginSwap(controller, 1, { "down" })
  Assert.equal(#sounds, 0, "arming stays silent before motion")
  controller:updateFixed({})
  Assert.deepEqual(sounds, { SWITCH_SOUND }, "the first visible step carries the start sound")
end

function T.switch_midpoint_exchanges_presentation_not_domain_with_second_sound()
  local controller, calls, _, sounds = soundingController()
  local revision = nativeStatus(controller).view.revision
  beginSwap(controller, 1, { "down" })
  local midpoint = driveOutward(controller, 0, 1, false)
  Assert.isTrue(midpoint.exchanged == true, "temporary draw records exchange at the midpoint")
  Assert.equal(#calls.swaps, 0, "the visual midpoint publishes nothing")
  Assert.equal(nativeStatus(controller).view.revision, revision, "authoritative order holds at the midpoint")
  Assert.deepEqual(sounds, { SWITCH_SOUND, SWITCH_SOUND }, "the midpoint replays the list sound")
end

function T.switch_final_return_commits_once_and_restores_browse()
  local controller, calls, _, sounds = soundingController()
  beginSwap(controller, 1, { "down" })
  driveOutward(controller, 0, 1, false)
  driveInward(controller, 0, 1, false)
  Assert.equal(#calls.swaps, 1, "the final state publishes exactly once")
  Assert.deepEqual(calls.swaps[1], { 0, 1 }, "the commit carries its source and destination")
  Assert.deepEqual(sounds, { SWITCH_SOUND, SWITCH_SOUND }, "exactly two sounds fire across the animation")
  local status = nativeStatus(controller)
  Assert.equal(status.state, "browse", "completion returns to browse")
  Assert.equal(status.cursorNode, 1, "focus follows the destination")
  Assert.isNil(status.swap, "completion clears the swap record")
  Assert.isNil(controller:takeResult(), "completion reports no terminal result")
  for _ = 1, 5 do
    controller:updateFixed({})
  end
  Assert.equal(#calls.swaps, 1, "post-commit ticks never republish")
  Assert.deepEqual(sounds, { SWITCH_SOUND, SWITCH_SOUND }, "post-commit ticks sound nothing more")
end

function T.switch_arming_is_silent_with_zero_offset_then_sounds_on_first_tick()
  local controller, calls, _, sounds = soundingController()
  local revision = nativeStatus(controller).view.revision
  beginSwap(controller, 1, { "down" })
  local armed = assert(nativeStatus(controller).swap, "arming publishes its swap record")
  Assert.equal(swapClock(armed), 0, "arming holds tile-step zero")
  Assert.isFalse(armed.exchanged == true, "arming exchanges nothing yet")
  Assert.equal(#sounds, 0, "arming stays silent until the first swap tick")
  Assert.equal(#calls.swaps, 0, "arming publishes nothing")
  controller:updateFixed({})
  local started = assert(nativeStatus(controller).swap, "the first swap tick keeps its swap record")
  Assert.equal(swapClock(started), 0, "the first swap tick holds offset zero")
  Assert.isFalse(started.exchanged == true, "the first swap tick exchanges nothing")
  Assert.deepEqual(sounds, { SWITCH_SOUND }, "the first swap tick sounds once")
  Assert.equal(#calls.swaps, 0, "the first swap tick publishes nothing")
  for expected = 1, 16 do
    controller:updateFixed({})
    local leg = assert(nativeStatus(controller).swap, "the outward leg keeps its swap record at " .. expected)
    Assert.equal(swapClock(leg), expected, "each outward tick advances exactly one tile-step")
    Assert.isFalse(leg.exchanged == true, "the outward leg exchanges nothing")
    for _, slot0 in ipairs({ 0, 1 }) do
      Assert.equal(
        slotSlidePx(leg, slot0),
        columnDirection(slot0) * expected * SWITCH_STEP_PX,
        "slot " .. slot0 .. " exits outward from its own column"
      )
    end
    Assert.equal(#calls.swaps, 0, "the outward leg publishes nothing")
  end
  Assert.deepEqual(sounds, { SWITCH_SOUND }, "outward motion sounds nothing more")
  controller:updateFixed({})
  local midpoint = assert(nativeStatus(controller).swap, "the exchange keeps its swap record")
  Assert.equal(swapClock(midpoint), SWITCH_FULL_STEPS, "the exchange holds full exit")
  Assert.isTrue(midpoint.exchanged == true, "the exchange flips the temporary records")
  Assert.deepEqual(sounds, { SWITCH_SOUND, SWITCH_SOUND }, "the exchange replays the list sound")
  Assert.equal(#calls.swaps, 0, "the visual exchange publishes nothing")
  Assert.equal(nativeStatus(controller).view.revision, revision, "authoritative order holds at the exchange")
end

function T.switch_inward_returns_step_by_step_then_commits_on_its_own_tick()
  local controller, calls, _, sounds = soundingController()
  local revision = nativeStatus(controller).view.revision
  beginSwap(controller, 1, { "down" })
  controller:updateFixed({})
  for _ = 1, 16 do
    controller:updateFixed({})
  end
  controller:updateFixed({})
  local midpoint = assert(nativeStatus(controller).swap, "the inward leg starts from the exchange")
  Assert.equal(swapClock(midpoint), SWITCH_FULL_STEPS, "the inward leg starts at full exit")
  Assert.isTrue(midpoint.exchanged == true, "the inward leg keeps exchanged records")
  for expected = 15, 0, -1 do
    controller:updateFixed({})
    local leg = assert(
      nativeStatus(controller).swap,
      "the swap record survives the inward step to " .. expected
    )
    Assert.equal(swapClock(leg), expected, "each inward tick returns exactly one tile-step")
    Assert.isTrue(leg.exchanged == true, "the inward leg keeps exchanged records")
    for _, slot0 in ipairs({ 0, 1 }) do
      Assert.equal(
        slotSlidePx(leg, slot0),
        columnDirection(slot0) * expected * SWITCH_STEP_PX,
        "slot " .. slot0 .. " returns inward along its own column"
      )
    end
    Assert.equal(#calls.swaps, 0, "the inward leg publishes nothing")
  end
  local held = assert(nativeStatus(controller).swap, "the zero-offset hold keeps its swap record")
  Assert.equal(swapClock(held), 0, "the hold rests at tile-step zero")
  Assert.equal(#calls.swaps, 0, "the zero-offset hold publishes nothing")
  Assert.equal(nativeStatus(controller).state, "swapping", "the hold still owns the controller")
  controller:updateFixed({})
  Assert.equal(#calls.swaps, 1, "the final tick publishes exactly once")
  Assert.deepEqual(calls.swaps[1], { 0, 1 }, "the commit carries its source and destination")
  Assert.deepEqual(sounds, { SWITCH_SOUND, SWITCH_SOUND }, "exactly two sounds fire across the animation")
  local status = nativeStatus(controller)
  Assert.equal(status.state, "browse", "completion returns to browse")
  Assert.equal(status.cursorNode, 1, "focus follows the destination")
  Assert.isNil(status.swap, "completion clears the swap record")
  Assert.equal(status.view.revision, revision + 1, "exactly one revision publishes")
end

function T.switch_cancel_at_destination_pick_abandons_quietly()
  local controller, calls, _, sounds = soundingController()
  armSwitch(controller)
  controller:updateFixed({ { type = "cancel" } })
  Assert.equal(nativeStatus(controller).state, "browse", "cancelling the pick returns to browse")
  Assert.isNil(nativeStatus(controller).swap, "cancelling arms no swap")
  Assert.equal(#calls.swaps, 0, "cancelling publishes nothing")
  Assert.equal(#sounds, 0, "cancelling sounds nothing")
  Assert.isNil(controller:takeResult(), "cancelling completes nothing")
end

function T.switch_ignores_input_while_animating()
  local controller, calls = soundingController()
  beginSwap(controller, 1, { "down" })
  for _ = 1, 3 do
    controller:updateFixed({})
  end
  Assert.equal(nativeStatus(controller).state, "swapping", "setup is mid-animation")
  controller:updateFixed({
    { type = "navigate", direction = "down" },
    { type = "confirm" },
    { type = "cancel" },
  })
  Assert.equal(nativeStatus(controller).state, "swapping", "input never interrupts the animation")
  driveOutward(controller, 0, 1, false)
  driveInward(controller, 0, 1, false)
  Assert.equal(#calls.swaps, 1, "the locked animation still commits exactly once")
  Assert.equal(nativeStatus(controller).state, "browse", "the locked animation still returns to browse")
end

function T.menu_restore_after_complete_action_carries_no_armed_press()
  local layout = v3Layout()
  local controller = nativeController({ layout = layout })
  controller:updateFixed({ { type = "confirm" } })
  controller:updateFixed({ { type = "confirm" } })
  pressThrough(controller)
  Assert.equal(nativeStatus(controller).state, "waiting_action")
  controller:takeIntent()
  controller:completeAction({ kind = "no_op" })
  local restored = nativeStatus(controller)
  Assert.equal(restored.state, "context", "the no-op restores the originating menu")
  Assert.isNil(restored.menuPress, "restoring never retains an armed press")
  Assert.notNil(restored.menu, "the originating menu rebuilds")
  local entries = layout.menuLayout("topLevel", #restored.menu)
  Assert.equal(#entries, #restored.menu, "the restored menu resolves its generated layout")
  Assert.isTrue(
    restored.menuIndex >= 1 and restored.menuIndex <= #restored.menu,
    "the restored focus stays inside the generated count"
  )
end

return { tests = T }
