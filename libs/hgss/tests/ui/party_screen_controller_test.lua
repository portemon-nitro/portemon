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
