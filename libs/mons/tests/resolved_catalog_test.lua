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

---@param overrides table<string, unknown>?
---@return table<string, unknown>
local function overdriveMove(overrides)
  local move = copy(CatalogFixture.buildAssetRoot().moves.TACKLE)
  move.name = "Overdrive Blast"
  move.nativeId = nil
  move.power = 300
  move.basePp = 80
  move.accuracy = 150
  move.priority = 200
  for key, value in pairs(overrides or {}) do
    move[key] = value
  end
  return move
end

function T.custom_move_numbers_beyond_native_limits_stay_readable_while_native_bounds_hold()
  local MonCatalog = require("libs.mons.src.MonCatalog")
  local ResolvedMonSchema = requireContract(
    "libs.mons.src.ResolvedMonSchema",
    "composed mon definitions have no runtime schema"
  )
  local Errors = require("libs.errors.src.Errors")
  local MonsErrors = require("libs.mons.src.errors")
  local Mon = require("libs.mons.src.Mon")
  local NativeLegality = require("libs.mons.src.gen4.NativeLegality")

  local root = CatalogFixture.buildAssetRoot()
  root.moves["ember:OVERDRIVE"] = overdriveMove()
  Assert.isTrue(ResolvedMonSchema.assertCatalog(root) ~= false, "the composed catalog accepts the custom move")
  local catalog = MonCatalog.fromResolved(root, CatalogFixture.makeItemCatalog())

  -- The custom move stays readable with its composed numbers unchanged:
  -- no native clamp is applied at composition.
  local seen = catalog:move("ember:OVERDRIVE")
  Assert.equal(seen.power, 300)
  Assert.equal(seen.basePp, 80)
  Assert.equal(seen.accuracy, 150)
  Assert.equal(seen.priority, 200)
  Assert.isNil(seen.nativeId)

  -- Native entries keep their exact values, priority, and behavior.
  local tackle = catalog:move("TACKLE")
  Assert.equal(tackle.power, 35)
  Assert.equal(tackle.basePp, 35)
  Assert.equal(tackle.accuracy, 95)
  Assert.equal(tackle.priority, 0)
  Assert.equal(tackle.nativeId, 33)

  -- Non-finite, fractional, and negative numbers stay invalid where the
  -- composed record requires an integer count.
  local invalid = {
    overdriveMove({ power = 0 / 0 }),
    overdriveMove({ accuracy = math.huge }),
    overdriveMove({ basePp = 80.5 }),
    overdriveMove({ power = -1 }),
    overdriveMove({ basePp = -1 }),
  }
  for _, move in ipairs(invalid) do
    local badRoot = CatalogFixture.buildAssetRoot()
    badRoot.moves["ember:BAD"] = move
    Assert.throws(function()
      ResolvedMonSchema.assertCatalog(badRoot)
    end, "invalid custom move numbers must fail composed validation")
  end

  -- The strict generated-asset validator is untouched: the overwide custom
  -- move still fails there.
  local MonAssetSchema = require("libs.assets.src.MonAssetSchema")
  Assert.throws(function()
    MonAssetSchema.assertCatalog(root)
  end, "the native schema keeps its retail move bounds")

  -- A mon carrying the custom move validates against its own power-point
  -- ceiling, while power points past that ceiling fail typed validation
  -- instead of truncating.
  local context = CatalogFixture.domainContext(catalog)
  local factory = CatalogFixture.makeFactory(0x12345678, catalog)
  local mon = factory:createNormal(CatalogFixture.normalRequest())
  mon.moves = { { move = "ember:OVERDRIVE", pp = 80, ppUps = 0 } }
  local validated = Mon.validate(mon, context)
  Assert.equal(validated.moves[1].pp, 80)
  local overwide = copy(mon)
  overwide.moves = { { move = "ember:OVERDRIVE", pp = 129, ppUps = 0 } }
  local ppErr = Assert.throws(function()
    Mon.validate(overwide, context)
  end, "power points past the definition ceiling must fail")
  Assert.isTrue(Errors.is(ppErr), "the power-point failure is structured")
  Assert.equal(ppErr.code, MonsErrors.RECORD_INVALID)

  -- The native save boundary still rejects the unrepresentable move with a
  -- typed failure before anything is written.
  local legalityErr = Assert.throws(function()
    NativeLegality.project(validated, context)
  end, "a custom move without a native identity must fail projection")
  Assert.isTrue(Errors.is(legalityErr), "the save-boundary failure is structured")
  Assert.equal(legalityErr.code, MonsErrors.LEGALITY_INVALID)
end

return { tests = T }
