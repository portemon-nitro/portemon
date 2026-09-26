-- Pure inventory-local action menu projection: toss follows the source
-- toss metadata, move follows manual ordering plus occupancy, registration
-- follows the two-slot state machine, the menu never leaves the
-- inventory-local set, and an empty selection offers only the way out.
-- Literal semantic facts only; no service, no catalog, no love.

local Assert = require("tests.support.Assert")
local BagActionPolicy = require("libs.hgss.src.ui.BagActionPolicy")

local T = {}

local function facts(overrides)
  local record = {
    itemKey = "POTION",
    preventToss = false,
    registerable = false,
    registered = false,
    pocketOrdering = "manual",
    pocketCount = 2,
    registeredCount = 0,
  }
  for key, value in pairs(overrides or {}) do
    record[key] = value
  end
  return record
end

local function ids(actions)
  local out = {}
  for index, action in ipairs(actions) do
    assert(type(action.id) == "string" and action.id ~= "", "menu actions carry a semantic id")
    Assert.isTrue(action.enabled == true, "offered actions stay enabled")
    out[index] = action.id
  end
  return out
end

local function slots(actions)
  local out = {}
  for index, action in ipairs(actions) do
    Assert.equal(type(action.slot), "number", "dynamic actions carry a physical slot")
    out[index] = action.slot
  end
  return out
end

local function has(actions, id)
  for _, action in ipairs(actions) do
    if action.id == id then
      return true
    end
  end
  return false
end

function T.toss_follows_the_source_toss_metadata()
  Assert.isTrue(has(BagActionPolicy.actionsFor(facts()), "toss"), "a tossable item offers to toss")
  Assert.isFalse(
    has(BagActionPolicy.actionsFor(facts({ preventToss = true })), "toss"),
    "a protected item never offers to toss"
  )
end

function T.move_needs_a_manual_pocket_with_room_to_reorder()
  Assert.isTrue(has(BagActionPolicy.actionsFor(facts()), "move"), "a manual pocket with two items offers to move")
  Assert.isFalse(
    has(BagActionPolicy.actionsFor(facts({ pocketOrdering = "native_id" })), "move"),
    "a canonical-order pocket never offers to move"
  )
  Assert.isFalse(has(BagActionPolicy.actionsFor(facts({ pocketCount = 1 })), "move"), "a lone item has nowhere to move")
end

function T.registration_offers_exactly_one_direction()
  Assert.isTrue(
    has(BagActionPolicy.actionsFor(facts({ registerable = true })), "register"),
    "an unregistered registerable item offers to register"
  )
  Assert.isFalse(
    has(BagActionPolicy.actionsFor(facts({ registerable = true })), "unregister"),
    "an unregistered item never offers to unregister"
  )
  local registered = facts({ registerable = true, registered = true, registeredCount = 1 })
  Assert.isTrue(has(BagActionPolicy.actionsFor(registered), "unregister"), "a registered item offers to unregister")
  Assert.isFalse(has(BagActionPolicy.actionsFor(registered), "register"), "a registered item never registers again")
  Assert.isFalse(
    has(BagActionPolicy.actionsFor(facts({ registerable = false })), "register"),
    "an ordinary item never offers to register"
  )
  Assert.isFalse(
    has(BagActionPolicy.actionsFor(facts({ registerable = false })), "unregister"),
    "an ordinary item never offers to unregister"
  )
end

function T.full_registration_omits_register_without_a_replacement()
  local full = facts({ registerable = true, registeredCount = 2 })
  Assert.isFalse(has(BagActionPolicy.actionsFor(full), "register"), "a full registration leaves no register path")
  Assert.isFalse(
    has(BagActionPolicy.actionsFor(full), "unregister"),
    "an unregistered item still offers no unregister when full"
  )
end

function T.dynamic_actions_use_retail_slots_and_never_include_cancel()
  local ordinary = BagActionPolicy.actionsFor(facts())
  Assert.deepEqual(slots(ordinary), { 1, 3 }, "toss and move occupy their source slots")
  Assert.isFalse(has(ordinary, "cancel"), "fixed cancel is not a dynamic policy action")
  local registered = BagActionPolicy.actionsFor(
    facts({ registerable = true, registered = true, registeredCount = 1, pocketOrdering = "native_id" })
  )
  Assert.deepEqual(slots(registered), { 1 }, "deselect owns the registration slot")
  Assert.equal(registered[1].id, "unregister")
  local registerable = BagActionPolicy.actionsFor(facts({ registerable = true, pocketOrdering = "native_id" }))
  Assert.deepEqual(slots(registerable), { 1 }, "register owns the registration slot")
  Assert.equal(registerable[1].id, "register")
  local empty = facts()
  empty.itemKey = nil
  Assert.deepEqual(ids(BagActionPolicy.actionsFor(empty)), {}, "no selection has no dynamic inventory action")
end

function T.menus_stay_inside_the_inventory_local_set()
  local allowed = { toss = true, move = true, register = true, unregister = true }
  local cases = {
    facts(),
    facts({ preventToss = true }),
    facts({ pocketOrdering = "native_id" }),
    facts({ pocketCount = 1 }),
    facts({ registerable = true }),
    facts({ registerable = true, registered = true, registeredCount = 1 }),
    facts({ registerable = true, registeredCount = 2 }),
  }
  local empty = facts()
  empty.itemKey = nil
  cases[#cases + 1] = empty
  for _, case in ipairs(cases) do
    for _, id in ipairs(ids(BagActionPolicy.actionsFor(case))) do
      Assert.isTrue(allowed[id] == true, "the menu stays inventory-local: " .. tostring(id))
    end
  end
end

-- Field-context facts ride semantic catalog metadata, never runtime
-- service discovery: the item key plus its party-use kind, holdability,
-- HM identity, and any deferred feature reason.
local function fieldFacts(overrides)
  local record = {
    itemKey = "POTION",
    useKind = "medicine",
    canHold = true,
    isHm = false,
    pocket = "medicine",
    featureReason = nil,
    preventToss = false,
    registerable = false,
    registered = false,
    pocketOrdering = "manual",
    pocketCount = 2,
    registeredCount = 0,
  }
  for key, value in pairs(overrides or {}) do
    record[key] = value
  end
  return record
end

function T.field_use_and_give_ride_the_source_slots()
  local actions = BagActionPolicy.actionsForField(fieldFacts())
  local at = {}
  for _, action in ipairs(actions) do
    at[action.id] = action.slot
  end
  Assert.equal(at.use, 0, "Use rides the source slot zero")
  Assert.equal(at.give, 2, "Give rides the source slot two")
end

function T.field_inventory_slots_survive_beside_use_and_give()
  local actions = BagActionPolicy.actionsForField(fieldFacts())
  Assert.isTrue(has(actions, "toss"), "the toss slot survives in field context")
  Assert.isTrue(has(actions, "move"), "the move slot survives in field context")
  Assert.isFalse(has(actions, "cancel"), "fixed cancel is not a dynamic policy action")
end

function T.field_use_requires_party_effect_metadata()
  Assert.isFalse(
    has(BagActionPolicy.actionsForField(fieldFacts({ useKind = "none" })), "use"),
    "an effect-free item offers no Use"
  )
  Assert.isTrue(
    has(BagActionPolicy.actionsForField(fieldFacts({ useKind = "deferred" })), "use"),
    "a deferred item still offers Use and reports later"
  )
  Assert.isTrue(
    has(BagActionPolicy.actionsForField(fieldFacts({ useKind = "machine" })), "use"),
    "a machine offers Use into compatibility"
  )
end

function T.field_empty_party_hides_target_requiring_entries_only()
  local actions = BagActionPolicy.actionsForField(fieldFacts({ partyEmpty = true }))
  Assert.isFalse(has(actions, "use"), "an empty party offers no Use without targets")
  Assert.isFalse(has(actions, "give"), "an empty party offers no Give without targets")
  Assert.isTrue(has(actions, "toss"), "inventory actions survive an empty party")
  Assert.isTrue(has(actions, "move"), "inventory actions survive an empty party")
  local offered = BagActionPolicy.actionsForField(fieldFacts({ partyEmpty = false }))
  Assert.isTrue(has(offered, "use"), "an owned party keeps Use")
  Assert.isTrue(has(offered, "give"), "an owned party keeps Give")
  local defaulted = BagActionPolicy.actionsForField(fieldFacts())
  Assert.isTrue(has(defaulted, "use"), "an absent party flag keeps the historical entries")
  Assert.isTrue(has(defaulted, "give"), "an absent party flag keeps the historical entries")
end

function T.field_give_needs_holdable_non_hm_non_mail()
  Assert.isFalse(
    has(BagActionPolicy.actionsForField(fieldFacts({ canHold = false })), "give"),
    "an unholdable item offers no Give"
  )
  Assert.isFalse(
    has(BagActionPolicy.actionsForField(fieldFacts({ isHm = true })), "give"),
    "a hidden machine offers no Give"
  )
  Assert.isFalse(has(BagActionPolicy.actionsForField(fieldFacts({ pocket = "mail" })), "give"), "mail offers no Give")
  Assert.isTrue(
    has(BagActionPolicy.actionsForField(fieldFacts({ useKind = "machine", isHm = false })), "give"),
    "an ordinary teachable disk stays giveable"
  )
end

function T.pick_held_marks_eligibility_without_nested_actions()
  Assert.isTrue(BagActionPolicy.isPickable(fieldFacts()), "an ordinary holdable item is pickable")
  Assert.isFalse(BagActionPolicy.isPickable(fieldFacts({ isHm = true })), "a hidden machine is not pickable")
  Assert.isFalse(BagActionPolicy.isPickable(fieldFacts({ canHold = false })), "key items are not pickable")
  Assert.isFalse(BagActionPolicy.isPickable(fieldFacts({ pocket = "mail" })), "mail is not pickable")
  Assert.isTrue(
    BagActionPolicy.isPickable(fieldFacts({ useKind = "machine", isHm = false })),
    "an ordinary teachable disk stays pickable"
  )
end

return { tests = T }
