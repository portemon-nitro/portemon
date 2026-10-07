-- Catalog ownership: immutable indexed definitions, native-identity
-- lookups, and presentation selection through the selected form.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")

local T = {}

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected a structured error")
  Assert.equal(err.code, code)
end

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[key] = copy(item)
  end
  return out
end

function T.catalog_indexes_definitions_and_selects_presentations()
  local catalog = CatalogFixture.makeCatalog()

  Assert.equal(catalog:species("CHIKORITA").nativeId, 152)
  Assert.equal(catalog:speciesByNativeId(158).name, "TOTODILE")
  Assert.equal(catalog:move("TACKLE").nativeId, 33)
  Assert.equal(catalog:moveByNativeId(45).name, "Growl")
  Assert.equal(catalog:ability("OVERGROW").nativeId, 65)
  Assert.equal(catalog:abilityByNativeId(67).name, "Torrent")
  Assert.equal(catalog:speciesKeyByNativeId(133), "EEVEE")
  Assert.equal(catalog:moveKeyByNativeId(33), "TACKLE")
  Assert.equal(catalog:abilityKeyByNativeId(65), "OVERGROW")
  Assert.equal(#catalog:growthCurve("medium_slow"), 100)

  local form = catalog:form("CHIKORITA", 0)
  Assert.equal(form.baseStats.hp, 45)
  Assert.throws(function()
    catalog:form("CHIKORITA", 3)
  end)

  local mon = { species = "CHIKORITA", form = 0 }
  Assert.equal(catalog:iconSelection(mon), "CHIKORITA/f0")
  Assert.equal(catalog:portraitSelection(mon), "CHIKORITA/f0/male/plain")
  Assert.notNil(catalog:followerSelection(mon))
  Assert.isNil(catalog:followerSelection({ species = "EEVEE", form = 0 }))

  throwsCode("MON_RECORD_INVALID", function()
    catalog:species("BOGUS")
  end)
  throwsCode("MON_RECORD_INVALID", function()
    catalog:move("BOGUS")
  end)
  throwsCode("MON_RECORD_INVALID", function()
    catalog:speciesKeyByNativeId(9999)
  end)

  -- Duplicate native identities fail at construction.
  local OtherCatalog = require("libs.mons.src.MonCatalog")
  local doubled = CatalogFixture.buildAssetRoot()
  doubled.species.FAKE = copy(doubled.species.CHIKORITA)
  doubled.species.FAKE.name = "FAKE"
  Assert.throws(function()
    OtherCatalog.new(doubled, CatalogFixture.makeItemCatalog())
  end)
end

function T.catalog_keeps_indexed_lookups_without_an_aggregate_digest()
  local MonCatalog = require("libs.mons.src.MonCatalog")
  Assert.isNil(MonCatalog.fingerprint, "the catalog exposes no aggregate compatibility digest")
  local root = CatalogFixture.buildAssetRoot()
  local catalog = MonCatalog.new(root, CatalogFixture.makeItemCatalog())
  Assert.isNil(catalog.fingerprint, "a constructed catalog carries no aggregate digest")
  Assert.isNil(rawget(catalog, "_fingerprint"), "a constructed catalog retains no digest state")
  Assert.equal(catalog:species("CHIKORITA").nativeId, 152)
  Assert.equal(catalog:speciesKeyByNativeId(158), "TOTODILE")
  Assert.equal(catalog:move("TACKLE").nativeId, 33)
end

-- The generated mon root is published immutable data borrowed for the
-- catalog's lifetime: construction indexes it without a recursive clone.
-- Identity and shared mutation visibility fail while the constructor
-- still deep-copies.
function T.mon_catalog_borrows_the_published_root_without_a_recursive_copy()
  local MonCatalog = require("libs.mons.src.MonCatalog")
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local root = CatalogFixture.buildAssetRoot()
  local catalog = MonCatalog.new(root, CatalogFixture.makeItemCatalog())
  Assert.isTrue(
    catalog:species("CHIKORITA") == root.species.CHIKORITA,
    "species lookups resolve the published record itself"
  )
  Assert.isTrue(
    catalog:move("TACKLE") == root.moves.TACKLE,
    "move lookups resolve the published record itself"
  )
  root.species.CHIKORITA.nativeId = 9999
  Assert.equal(
    catalog:species("CHIKORITA").nativeId,
    9999,
    "the catalog borrows the live published root"
  )
  Assert.equal(catalog:speciesKeyByNativeId(158), "TOTODILE")
  Assert.equal(catalog:move("TACKLE").nativeId, 33)
end

function T.catalog_delegates_item_identities_to_the_shared_catalog()
  local catalog = CatalogFixture.makeCatalog()

  Assert.equal(catalog:itemKeyByNativeId(0), "NONE")
  Assert.equal(catalog:itemKeyByNativeId(4), "POKE_BALL")
  local ball = catalog:item("POKE_BALL")
  Assert.equal(ball.nativeId, 4)
  Assert.isTrue(ball.isBall)
  Assert.isFalse(ball.friendshipBoost)
  local plain = catalog:itemByNativeId(158)
  Assert.equal(plain.nativeId, 158)
  Assert.isFalse(plain.isBall)
  local itemErr = Assert.throws(function()
    catalog:item("BOGUS_ITEM")
  end)
  Assert.isTrue(Errors.is(itemErr), "unknown items raise structured item-domain errors")
  Assert.equal(itemErr.code, "ITEM_RECORD_INVALID")
  local nativeErr = Assert.throws(function()
    catalog:itemKeyByNativeId(9999)
  end)
  Assert.equal(nativeErr.code, "ITEM_RECORD_INVALID")
end

return { tests = T }
