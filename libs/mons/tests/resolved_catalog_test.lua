-- Resolved mon catalogs: vanilla entries keep their native identities and
-- lookup order while namespaced custom entries resolve semantically without
-- native identities and without invented placeholder identities.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")

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

---@param value unknown
---@return unknown
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

---@param root table<string, unknown>
local function addCustomEntries(root)
  local species = copy(root.species.CHIKORITA)
  species.name = "EMBERPUP"
  species.nativeId = nil
  root.species["ember:EMBERPUP"] = species
  local move = copy(root.moves.TACKLE)
  move.name = "Ember Bite"
  move.nativeId = nil
  root.moves["ember:EMBER_BITE"] = move
  local ability = copy(root.abilities.OVERGROW)
  ability.name = "Blaze Heart"
  ability.nativeId = nil
  root.abilities["ember:BLAZE_HEART"] = ability
end

function T.custom_entries_resolve_without_native_identities()
  local MonCatalog = require("libs.mons.src.MonCatalog")
  Assert.isTrue(
    type(MonCatalog.fromResolved) == "function",
    "missing mon catalog contract MonCatalog.fromResolved: composed definitions have no catalog owner"
  )
  local ResolvedMonSchema = requireContract(
    "libs.mons.src.ResolvedMonSchema",
    "composed mon definitions have no runtime schema"
  )

  local root = CatalogFixture.buildAssetRoot()
  addCustomEntries(root)
  Assert.isTrue(ResolvedMonSchema.assertCatalog(root) ~= false, "the resolved mon schema accepts the catalog")

  local catalog = MonCatalog.fromResolved(root, CatalogFixture.makeItemCatalog())

  -- Vanilla identity and order are unchanged.
  Assert.equal(catalog:species("CHIKORITA").nativeId, 152)
  Assert.equal(catalog:speciesKeyByNativeId(152), "CHIKORITA")
  Assert.equal(catalog:speciesByNativeId(158).name, "TOTODILE")
  Assert.equal(catalog:move("TACKLE").nativeId, 33)
  Assert.equal(catalog:moveKeyByNativeId(33), "TACKLE")
  Assert.equal(catalog:ability("OVERGROW").nativeId, 65)
  Assert.equal(catalog:abilityKeyByNativeId(65), "OVERGROW")

  -- Custom entries resolve semantically with no native identity invented.
  Assert.equal(catalog:species("ember:EMBERPUP").name, "EMBERPUP")
  Assert.isNil(catalog:species("ember:EMBERPUP").nativeId)
  Assert.equal(catalog:move("ember:EMBER_BITE").name, "Ember Bite")
  Assert.isNil(catalog:move("ember:EMBER_BITE").nativeId)
  Assert.equal(catalog:ability("ember:BLAZE_HEART").name, "Blaze Heart")
  Assert.isNil(catalog:ability("ember:BLAZE_HEART").nativeId)

  -- Optional-native indexing carries only declared identities.
  Assert.throws(function()
    catalog:speciesKeyByNativeId(9999)
  end)
  Assert.throws(function()
    catalog:moveKeyByNativeId(9999)
  end)
  Assert.throws(function()
    catalog:abilityKeyByNativeId(9999)
  end)

  -- The frozen catalog detaches from the caller's root.
  root.species["ember:EMBERPUP"] = nil
  Assert.equal(catalog:species("ember:EMBERPUP").name, "EMBERPUP")
end

function T.duplicate_declared_native_identities_fail()
  local MonCatalog = require("libs.mons.src.MonCatalog")
  local ResolvedMonSchema = require("libs.mons.src.ResolvedMonSchema")

  local root = CatalogFixture.buildAssetRoot()
  root.species["ember:EMBERPUP"] = copy(root.species.CHIKORITA)
  root.species["ember:EMBERPUP"].name = "EMBERPUP"
  -- Keeping the copied numeric identity collides with the vanilla entry.
  Assert.throws(function()
    ResolvedMonSchema.assertCatalog(root)
  end)
  Assert.throws(function()
    MonCatalog.fromResolved(root, CatalogFixture.makeItemCatalog())
  end)
end

function T.unknown_keys_fail_explicitly()
  local MonCatalog = require("libs.mons.src.MonCatalog")

  local catalog = MonCatalog.fromResolved(CatalogFixture.buildAssetRoot(), CatalogFixture.makeItemCatalog())
  Assert.throws(function()
    catalog:species("MISSING")
  end)
  Assert.throws(function()
    catalog:move("MISSING")
  end)
  Assert.throws(function()
    catalog:ability("MISSING")
  end)
  Assert.throws(function()
    catalog:abilityByNativeId(9999)
  end)
end

function T.custom_type_keys_pass_validation_without_a_native_whitelist()
  local MonCatalog = require("libs.mons.src.MonCatalog")
  local ResolvedMonSchema = require("libs.mons.src.ResolvedMonSchema")

  local root = CatalogFixture.buildAssetRoot()
  root.species["ember:EMBERPUP"] = copy(root.species.CHIKORITA)
  root.species["ember:EMBERPUP"].name = "EMBERPUP"
  root.species["ember:EMBERPUP"].nativeId = nil
  root.species["ember:EMBERPUP"].forms[0].types = { "sound:SOUND" }
  Assert.isTrue(ResolvedMonSchema.assertCatalog(root) ~= false, "custom type keys validate")
  local catalog = MonCatalog.fromResolved(root, CatalogFixture.makeItemCatalog())
  Assert.deepEqual(catalog:species("ember:EMBERPUP").forms[0].types, { "sound:SOUND" })
end

function T.strict_native_schema_still_requires_native_identities()
  local MonAssetSchema = require("libs.assets.src.MonAssetSchema")

  local root = CatalogFixture.buildAssetRoot()
  root.species["ember:EMBERPUP"] = copy(root.species.CHIKORITA)
  root.species["ember:EMBERPUP"].name = "EMBERPUP"
  root.species["ember:EMBERPUP"].nativeId = nil
  -- The generated-asset validator is untouched by the composed path: a
  -- missing numeric identity still fails there.
  Assert.throws(function()
    MonAssetSchema.assertCatalog(root)
  end)
end

return { tests = T }
