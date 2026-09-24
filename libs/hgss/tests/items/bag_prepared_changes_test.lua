-- Bag preparation: detached inventory candidates with a one-shot install
-- operation. Preparation never touches the live inventory or revision.

local Assert = require("tests.support.Assert")
local ItemFixture = require("libs.items.tests.item_fixture")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")

local function service()
  return HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
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

return { tests = T }
