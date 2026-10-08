-- Resolved item catalogs: vanilla entries keep their native identities and
-- pocket order while a namespaced custom held entry resolves without a
-- native identity and sorts after native entries in its pocket.

local Assert = require("tests.support.Assert")
local ItemFixture = require("libs.items.tests.item_fixture")

local T = {}

---@param module string
---@param behavior string
---@return table
local function requireContract(module, behavior)
  local ok, loaded = pcall(require, module)
  Assert.isTrue(ok, "missing resolved catalog contract " .. module .. ": " .. behavior)
  assert(loaded ~= nil, "the resolved catalog contract loads its module")
  return loaded --[[@as table]]
end

---@return table<string, unknown>
local function customHeldEntry(pocket)
  return {
    name = "Ember Charm",
    nameIndefinite = "an Ember Charm",
    namePlural = "Ember Charms",
    description = "A charm holding leftover warmth.",
    pocket = pocket or "items",
    preventToss = false,
    selectable = false,
    isBall = false,
    friendshipBoost = false,
    icon = "ember:EMBER_CHARM",
    isHm = false,
    canHold = true,
    heldFormEffect = "none",
    partyUse = { kind = "none" },
  }
end

function T.custom_held_entry_resolves_without_a_native_identity()
  local ItemCatalog = require("libs.items.src.ItemCatalog")
  Assert.isTrue(
    type(ItemCatalog.fromResolved) == "function",
    "missing item catalog contract ItemCatalog.fromResolved: composed definitions have no catalog owner"
  )
  local ResolvedItemSchema = requireContract(
    "libs.items.src.ResolvedItemSchema",
    "composed item definitions have no runtime schema"
  )

  local root = ItemFixture.buildAssetRoot()
  root.items["ember:EMBER_CHARM"] = customHeldEntry()
  Assert.isTrue(ResolvedItemSchema.assertCatalog(root) ~= false, "the resolved item schema accepts the catalog")

  local catalog = ItemCatalog.fromResolved(root)

  -- Vanilla identity and order are unchanged.
  Assert.equal(catalog:item("POKE_BALL").nativeId, 4)
  Assert.equal(catalog:itemKeyByNativeId(4), "POKE_BALL")
  Assert.equal(catalog:item("POTION").nativeId, 17)
  Assert.equal(catalog:itemByNativeId(158).nativeId, 158)

  -- The custom held entry resolves semantically with no native identity invented.
  local charm = catalog:item("ember:EMBER_CHARM")
  Assert.equal(charm.name, "Ember Charm")
  Assert.isTrue(charm.canHold)
  Assert.isNil(charm.nativeId)

  -- Optional-native indexing carries only declared identities.
  Assert.throws(function()
    catalog:itemKeyByNativeId(9999)
  end)

  -- Native entries keep their relative order and custom entries sort after
  -- every native entry in the same pocket.
  Assert.isTrue(type(catalog.orderingKey) == "function", "missing item catalog contract orderingKey")
  Assert.isTrue(catalog:orderingKey("NONE") < catalog:orderingKey("SOOTHE_BELL"))
  Assert.isTrue(catalog:orderingKey("SOOTHE_BELL") < catalog:orderingKey("ember:EMBER_CHARM"))

  -- The frozen catalog detaches from the caller's root.
  root.items["ember:EMBER_CHARM"] = nil
  Assert.equal(catalog:item("ember:EMBER_CHARM").name, "Ember Charm")
end

function T.duplicate_declared_native_identities_fail()
  local ItemCatalog = require("libs.items.src.ItemCatalog")
  local ResolvedItemSchema = require("libs.items.src.ResolvedItemSchema")

  local root = ItemFixture.buildAssetRoot()
  root.items["ember:EMBER_CHARM"] = customHeldEntry()
  root.items["ember:EMBER_CHARM"].nativeId = 4
  -- Borrowing an occupied numeric identity collides with the vanilla entry.
  Assert.throws(function()
    ResolvedItemSchema.assertCatalog(root)
  end)
  Assert.throws(function()
    ItemCatalog.fromResolved(root)
  end)
end

function T.unknown_keys_and_ordering_keys_fail_explicitly()
  local ItemCatalog = require("libs.items.src.ItemCatalog")

  local catalog = ItemCatalog.fromResolved(ItemFixture.buildAssetRoot())
  Assert.throws(function()
    catalog:item("MISSING")
  end)
  Assert.throws(function()
    catalog:itemByNativeId(9999)
  end)
  Assert.throws(function()
    catalog:orderingKey("MISSING")
  end)
end

function T.native_ordering_follows_source_identities_while_customs_sort_after()
  local ItemCatalog = require("libs.items.src.ItemCatalog")

  local root = ItemFixture.buildAssetRoot()
  root.items["ember:EMBER_CHARM"] = customHeldEntry()
  root.items["ember:ZEPHYR_CHIME"] = customHeldEntry()
  root.items["ember:ZEPHYR_CHIME"].name = "Zephyr Chime"
  local catalog = ItemCatalog.fromResolved(root)

  -- Native entries keep numeric source order within their pocket.
  Assert.isTrue(catalog:orderingKey("GREAT_BALL") < catalog:orderingKey("POKE_BALL"))
  Assert.isTrue(catalog:orderingKey("POKE_BALL") < catalog:orderingKey("LUXURY_BALL"))
  -- Custom entries sort after every native entry and semantically by key.
  Assert.isTrue(catalog:orderingKey("LUXURY_BALL") < catalog:orderingKey("ember:EMBER_CHARM"))
  Assert.isTrue(catalog:orderingKey("ember:EMBER_CHARM") < catalog:orderingKey("ember:ZEPHYR_CHIME"))
  Assert.equal(catalog:orderingKey("ember:EMBER_CHARM"), catalog:orderingKey("ember:EMBER_CHARM"))
end

function T.item_keys_enumerate_mixed_catalog_in_semantic_order()
  local ItemCatalog = require("libs.items.src.ItemCatalog")

  local root = ItemFixture.buildAssetRoot()
  root.items["ember:EMBER_CHARM"] = customHeldEntry("items")
  root.items["ember:MOON_BALL"] = customHeldEntry("balls")
  local catalog = ItemCatalog.fromResolved(root)

  local first = catalog:itemKeys()
  local second = catalog:itemKeys()
  Assert.deepEqual(first, second, "mixed catalog enumeration is deterministic")
  local seen = {}
  for index, key in ipairs(first) do
    Assert.isFalse(seen[key] == true, "item key appears once: " .. key)
    seen[key] = true
    if index > 1 then
      Assert.isTrue(
        catalog:orderingKey(first[index - 1]) < catalog:orderingKey(key),
        "item keys follow the semantic ordering contract"
      )
    end
  end
  Assert.isTrue(seen["ember:EMBER_CHARM"], "custom items are enumerated")
  Assert.isTrue(seen["ember:MOON_BALL"], "custom balls are enumerated")
  Assert.isTrue(catalog:orderingKey("LUXURY_BALL") < catalog:orderingKey("ember:MOON_BALL"))
end

return { tests = T }
