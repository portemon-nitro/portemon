-- Bag preparation: detached inventory candidates with a one-shot install
-- operation. Preparation never touches the live inventory or revision.

local Assert = require("tests.support.Assert")
local ItemFixture = require("libs.items.tests.item_fixture")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")

local function service()
  return HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
end

-- Occupies every medicine slot while keeping one chosen item out, so a
-- later staged addition of that item can only fit if an earlier delta
-- frees its slot first.
local function fillMedicineExcept(bag, excluded)
  local catalog = bag:catalog()
  for nativeId = 0, 536 do
    if #bag:pocketItems("medicine") >= catalog:pocket("medicine").capacity then
      break
    end
    local key = catalog:itemKeyByNativeId(nativeId)
    if key ~= excluded and catalog:item(key).pocket == "medicine" and bag:quantity(key) == 0 then
      Assert.isTrue(bag:add(key, 1), "setup must occupy the medicine pocket")
    end
  end
  Assert.equal(
    #bag:pocketItems("medicine"),
    catalog:pocket("medicine").capacity,
    "setup fills every medicine slot"
  )
end

local function firstMedicineKeyExcept(bag, excluded)
  local catalog = bag:catalog()
  for nativeId = 0, 536 do
    local key = catalog:itemKeyByNativeId(nativeId)
    if key ~= excluded and catalog:item(key).pocket == "medicine" then
      return key
    end
  end
  error("the catalog carries no spare medicine item", 0)
end

local T = {}

function T.prepare_rejects_a_stale_revision_without_touching_state()
  local bag = service()
  Assert.isTrue(bag:add("POTION", 3))
  local revision = bag:revision()
  local preparation, reason =
    bag:prepareInventoryChanges(revision + 1, { { op = "take", item = "POTION", quantity = 1 } })
  Assert.isNil(preparation)
  Assert.equal(reason, "stale")
  Assert.equal(bag:quantity("POTION"), 3)
  Assert.equal(bag:revision(), revision)
end

function T.prepare_applies_deltas_to_a_candidate_and_publishes_once()
  local bag = service()
  Assert.isTrue(bag:add("POTION", 3))
  Assert.isTrue(bag:add("POKE_BALL", 2))
  local revision = bag:revision()
  local preparation, reason = bag:prepareInventoryChanges(revision, {
    { op = "take", item = "POTION", quantity = 1 },
    { op = "add", item = "POKE_BALL", quantity = 1 },
  })
  assert(preparation ~= nil, "a current revision prepares: " .. tostring(reason))
  Assert.isTrue(preparation.isCurrent())
  Assert.equal(bag:quantity("POTION"), 3, "preparation leaves the live inventory alone")
  preparation.publish()
  Assert.equal(bag:quantity("POTION"), 2)
  Assert.equal(bag:quantity("POKE_BALL"), 3)
  Assert.equal(bag:revision(), revision + 1, "publication bumps exactly once for the batch")
  Assert.throws(function()
    preparation.publish()
  end, "a repeated publish is a programming error")
  Assert.equal(bag:revision(), revision + 1, "a duplicate publish never increments twice")
end

function T.prepare_preserves_pocket_ordering_through_exchange_deltas()
  local bag = service()
  Assert.isTrue(bag:add("POKE_BALL", 1))
  Assert.isTrue(bag:add("GREAT_BALL", 1))
  local revision = bag:revision()
  local preparation = assert(bag:prepareInventoryChanges(revision, {
    { op = "take", item = "POKE_BALL", quantity = 1 },
    { op = "add", item = "LUXURY_BALL", quantity = 1 },
  }))
  preparation.publish()
  Assert.equal(bag:quantity("POKE_BALL"), 0)
  Assert.equal(bag:quantity("LUXURY_BALL"), 1)
  Assert.equal(bag:quantity("GREAT_BALL"), 1, "untouched stacks survive the swap")
  Assert.equal(bag:revision(), revision + 1)
end

function T.prepare_applies_ordered_deltas_through_a_freed_slot()
  local bag = service()
  local freed = firstMedicineKeyExcept(bag, "POTION")
  Assert.isTrue(bag:add(freed, 1), "setup must stock the freed stack as a lone unit")
  fillMedicineExcept(bag, "POTION")
  Assert.equal(bag:quantity("POTION"), 0, "the added item starts absent from the bag")
  Assert.isFalse(bag:hasSpace("POTION", 1), "setup must leave the medicine pocket full")
  local revision = bag:revision()
  local preparation, reason = bag:prepareInventoryChanges(revision, {
    { op = "take", item = freed, quantity = 1 },
    { op = "add", item = "POTION", quantity = 1 },
  })
  assert(preparation ~= nil, "ordered deltas prepare through the freed slot: " .. tostring(reason))
  Assert.equal(bag:quantity(freed), 1, "preparation leaves the live inventory alone")
  Assert.equal(bag:quantity("POTION"), 0, "preparation stages nothing live before publish")
  Assert.equal(bag:revision(), revision, "preparation publishes no revision before publish")
  preparation.publish()
  Assert.equal(bag:quantity(freed), 0, "publishing removes the taken stack")
  Assert.equal(bag:quantity("POTION"), 1, "publishing installs the addition into the freed slot")
  Assert.equal(bag:revision(), revision + 1, "publication bumps exactly once for the batch")
end

function T.prepare_clones_owner_state_without_whole_bucket_validation()
  local BagSave = require("libs.hgss.src.save.BagSave")
  local bag = service()
  Assert.isTrue(bag:add("SITRUS_BERRY", 1), "setup stocks an unrelated berries stack")
  fillMedicineExcept(bag, "POTION")
  Assert.isFalse(bag:hasSpace("POTION", 1), "setup must leave the medicine pocket full")
  local revision = bag:revision()
  local before = bag:capture()

  local calls = 0
  local original = BagSave.validate
  BagSave.validate = function(...)
    calls = calls + 1
    return original(...)
  end
  local function finish()
    BagSave.validate = original
    return calls
  end

  local stale, staleReason =
    bag:prepareInventoryChanges(revision + 1, { { op = "take", item = "SITRUS_BERRY", quantity = 1 } })
  Assert.isNil(stale)
  Assert.equal(staleReason, "stale")

  local refused, refuseReason = bag:prepareInventoryChanges(revision, {
    { op = "take", item = "SITRUS_BERRY", quantity = 1 },
    { op = "add", item = "POTION", quantity = 1 },
  })
  Assert.isNil(refused, "a full-pocket add refuses instead of publishing")
  Assert.equal(refuseReason, "bag_full")
  Assert.deepEqual(bag:capture(), before, "a refused preparation mutates nothing live")

  local preparation = assert(
    bag:prepareInventoryChanges(revision, { { op = "take", item = "SITRUS_BERRY", quantity = 1 } })
  )
  Assert.isTrue(preparation.isCurrent())
  preparation.publish()
  Assert.equal(bag:quantity("SITRUS_BERRY"), 0)
  Assert.equal(bag:revision(), revision + 1, "publication bumps exactly once for the batch")

  Assert.equal(finish(), 0, "staged owner-state cloning must not revalidate the whole bag")
  Assert.notNil(
    BagSave.validate(bag:capture(), bag:catalog()),
    "explicit bag validation still accepts the published capture"
  )
end

function T.prepare_reports_an_unfreeable_add_as_a_recoverable_refusal()
  local bag = service()
  Assert.isTrue(bag:add("SITRUS_BERRY", 1), "setup stocks an unrelated berries stack")
  fillMedicineExcept(bag, "POTION")
  Assert.isFalse(bag:hasSpace("POTION", 1), "setup must leave the medicine pocket full")
  local revision = bag:revision()
  local before = bag:capture()
  local preparation, reason = bag:prepareInventoryChanges(revision, {
    { op = "take", item = "SITRUS_BERRY", quantity = 1 },
    { op = "add", item = "POTION", quantity = 1 },
  })
  Assert.isNil(preparation, "a full-pocket add refuses instead of publishing")
  Assert.equal(reason, "bag_full")
  Assert.deepEqual(bag:capture(), before, "a refused preparation mutates nothing live")
  Assert.equal(bag:revision(), revision, "a refused preparation publishes no revision")
end

return { tests = T }
