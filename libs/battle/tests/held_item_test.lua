-- Held-item possession and consequence history: transfers move the live
-- effect without copying the item, knocked-off items stay off the field
-- through every restoration policy, consumed berries keep their history
-- for later use under a restoring policy only, choice possession survives
-- replacement, and finalizing never duplicates or deletes outside history.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")
local EffectFixture = require("libs.battle.tests.effect_fixture")

local T = {}

---@param behavior string missing owner under test
---@return table the loaded held-item state owner
local function heldItems(behavior)
  return SessionFixture.requirePresent("libs.battle.src.gen4.HeldItems", behavior)
end

---@param owner integer combatant holding the item under test
---@param item string held item key under test
---@return table fresh history record with possession and empty consequences
local function historyFor(owner, item)
  return {
    original = item,
    current = item,
    originalOwner = owner,
    consumed = {},
    knockedOff = false,
    suppressed = false,
    transfers = {},
  }
end

---@param records table[] history records under test
---@return table<string, integer> live holdings per item key
local function liveHoldings(records, HeldItems)
  local holdings = {}
  for _, record in ipairs(records) do
    local held = HeldItems.effective(record)
    if held ~= nil then
      holdings[held] = (holdings[held] or 0) + 1
    end
  end
  return holdings
end

-- A swap moves possession and the live effect to the new holders: each
-- item exists exactly once across both records while both originals and
-- both transfer entries stay on record.
function T.trick_moves_possession_and_effect_without_copying_the_item()
  local HeldItems = heldItems("held-item state owns possession and consequence history")
  local first = historyFor(1, "CHOICE_BAND")
  local second = historyFor(2, "LEFTOVERS")

  HeldItems.transfer(first, second, EffectFixture.cause(1, 1))

  Assert.equal(HeldItems.effective(first), "LEFTOVERS", "the first holder now applies the swapped item")
  Assert.equal(HeldItems.effective(second), "CHOICE_BAND", "the second holder now applies the swapped item")
  Assert.deepEqual(
    liveHoldings({ first, second }, HeldItems),
    { LEFTOVERS = 1, CHOICE_BAND = 1 },
    "the swap copies neither item"
  )
  Assert.equal(first.original, "CHOICE_BAND", "the first original stays anchored")
  Assert.equal(second.original, "LEFTOVERS", "the second original stays anchored")
  Assert.equal(#first.transfers, 1, "the first record keeps its transfer entry")
  Assert.equal(#second.transfers, 1, "the second record keeps its transfer entry")
end

-- Knocked-off items stop applying, are not recorded as consumed, and no
-- restoration policy brings them back: the provenance stays readable while
-- the field stays empty.
function T.knock_off_suppresses_the_effect_and_survives_finalize()
  local HeldItems = heldItems("held-item state owns possession and consequence history")
  local record = historyFor(2, "ORAN_BERRY")

  HeldItems.knockOff(record, EffectFixture.cause(1, 1))

  Assert.isNil(HeldItems.effective(record), "a knocked-off item stops applying")
  Assert.isTrue(record.knockedOff, "the removal stays on record")
  Assert.deepEqual(record.consumed, {}, "a knocked-off item is not recorded as consumed")

  HeldItems.restore(record, "restoring")
  Assert.isNil(HeldItems.effective(record), "a restoring policy never revives knocked-off items")
  HeldItems.restore(record, "nonrestoring")
  Assert.isNil(HeldItems.effective(record), "a nonrestoring policy never revives knocked-off items")
  Assert.equal(record.original, "ORAN_BERRY", "the provenance survives every policy")
end

-- Berry consumption empties live possession while keeping the berry on
-- record; the restoring policy brings it back for later use and the
-- nonrestoring policy leaves the field empty with identical history.
function T.berry_consumption_leaves_recycle_history_and_restores_by_policy()
  local HeldItems = heldItems("held-item state owns possession and consequence history")

  local recycled = historyFor(1, "SITRUS_BERRY")
  HeldItems.consume(recycled, EffectFixture.cause(2, 1))
  Assert.isNil(HeldItems.effective(recycled), "a consumed berry stops applying")
  Assert.deepEqual(recycled.consumed, { "SITRUS_BERRY" }, "consumption stays on record")
  HeldItems.restore(recycled, "restoring")
  Assert.equal(HeldItems.effective(recycled), "SITRUS_BERRY", "a restoring policy returns the berry to the holder")
  Assert.deepEqual(recycled.consumed, { "SITRUS_BERRY" }, "later use keeps the earlier consumption on record")

  local spent = historyFor(1, "SITRUS_BERRY")
  HeldItems.consume(spent, EffectFixture.cause(2, 1))
  HeldItems.restore(spent, "nonrestoring")
  Assert.isNil(HeldItems.effective(spent), "a nonrestoring policy leaves the holder empty")
  Assert.deepEqual(spent.consumed, { "SITRUS_BERRY" }, "the nonrestoring history matches the restoring one")
end

-- Choice possession survives the activation turnover that replacement
-- publishes: the same history still applies after the real effect owner
-- clears the departing activation state.
function T.choice_possession_survives_replacement_without_duplication()
  local HeldItems = heldItems("held-item state owns possession and consequence history")
  local EffectBag =
    SessionFixture.requirePresent("libs.battle.src.EffectBag", "scoped effect instances own their lifetimes")
  local Status =
    SessionFixture.requirePresent("libs.battle.src.gen4.Status", "native major status law owns replacement resets")

  local record = historyFor(1, "CHOICE_BAND")
  local mon = SessionFixture.makeMon(11)
  local bag = EffectBag.new()
  Status.switchReset(mon, bag, 1, 2)

  Assert.equal(HeldItems.effective(record), "CHOICE_BAND", "replacement keeps applying the choice item")
  Assert.equal(record.original, "CHOICE_BAND", "replacement keeps the original anchored")
  Assert.deepEqual(record.consumed, {}, "replacement consumes nothing")
  Assert.deepEqual(record.transfers, {}, "replacement transfers nothing")
  Assert.deepEqual(bag:capture(), {}, "the departing activation keeps no battle state")
end

-- A full sequence of swap, consumption, and removal finalizes with exact
-- ownership: live items never duplicate, knocked-off items never return,
-- and every consequence stays readable per record.
function T.finalize_never_duplicates_or_deletes_outside_history()
  local HeldItems = heldItems("held-item state owns possession and consequence history")
  local first = historyFor(1, "LEFTOVERS")
  local second = historyFor(2, "SITRUS_BERRY")
  local third = historyFor(3, "CHOICE_BAND")

  HeldItems.transfer(first, second, EffectFixture.cause(1, 1))
  HeldItems.consume(first, EffectFixture.cause(2, 1))
  HeldItems.knockOff(third, EffectFixture.cause(1, 1))

  for _, record in ipairs({ first, second, third }) do
    HeldItems.restore(record, "restoring")
  end

  Assert.equal(HeldItems.effective(first), "SITRUS_BERRY", "the consumed berry returns to its holder")
  Assert.equal(HeldItems.effective(second), "LEFTOVERS", "the swapped item stays with its holder")
  Assert.isNil(HeldItems.effective(third), "the knocked-off item never returns")
  Assert.deepEqual(
    liveHoldings({ first, second, third }, HeldItems),
    { SITRUS_BERRY = 1, LEFTOVERS = 1 },
    "finalizing duplicates no live item"
  )
  Assert.deepEqual(first.consumed, { "SITRUS_BERRY" }, "the berry consumption stays on record")
  Assert.deepEqual(second.consumed, {}, "the untouched swap consumes nothing")
  Assert.isTrue(third.knockedOff, "the removal stays on record")
  Assert.equal(third.original, "CHOICE_BAND", "the removed provenance is never deleted")
end

-- Suppression silences the live effect without consuming, removing, or
-- rewriting provenance; spending an empty holder and restoring a holder
-- that never spent are no-ops; an unknown restoration policy fails.
function T.suppression_and_empty_holders_stay_stable()
  local HeldItems = heldItems("held-item state owns possession and consequence history")

  local gagged = historyFor(1, "LEFTOVERS")
  gagged.suppressed = true
  Assert.isNil(HeldItems.effective(gagged), "a suppressed item stops applying")
  Assert.equal(gagged.original, "LEFTOVERS", "suppression keeps the provenance anchored")
  Assert.deepEqual(gagged.consumed, {}, "suppression consumes nothing")
  gagged.suppressed = false
  Assert.equal(HeldItems.effective(gagged), "LEFTOVERS", "lifting suppression restores the effect")

  local empty = historyFor(2, "SITRUS_BERRY")
  empty.current = nil
  Assert.isFalse(HeldItems.consume(empty, EffectFixture.cause(1, 1)), "spending an empty holder reports no work")
  Assert.deepEqual(empty.consumed, {}, "spending an empty holder records nothing")
  Assert.isFalse(HeldItems.restore(empty, "restoring"), "restoring a never-spent holder refills nothing")
  Assert.isNil(HeldItems.effective(empty), "the never-spent holder stays empty")

  local policy = Assert.throws(function()
    HeldItems.restore(historyFor(3, "ORAN_BERRY"), "sometimes")
  end)
  Assert.isTrue(tostring(policy):find("policy", 1, true) ~= nil, "an unknown policy fails naming the policy")
end

return { tests = T }
