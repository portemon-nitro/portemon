-- Evolution-member decoding contract for the mon catalog compiler.
-- Fixture slots mirror pret/pokeheartgold@0985e8718df4f25e64d6507d89c0c97c0d288981
-- include/pokemon_types_def.h `struct Evolution` (u16 method/param/target,
-- seven slots per member) with LoadMonEvolutionTable member selection. Zero
-- slots are omitted; trailing reserved bytes must be zero.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")

local T = {}

local function compiler()
  return require("romdump.src.digest.mons.MonCatalogCompiler")
end

local function u16le(value)
  return string.char(value % 256, math.floor(value / 256) % 256)
end

local function slot(method, param, target)
  return u16le(method) .. u16le(param) .. u16le(target)
end

local function member(slots)
  local parts = {}
  for _, entry in ipairs(slots) do
    parts[#parts + 1] = entry
  end
  while #parts < 7 do
    parts[#parts + 1] = string.rep("\0", 6)
  end
  return table.concat(parts) .. string.rep("\0", 2)
end

local function context()
  return { archive = "evolutions", memberId = 152 }
end

function T.decodes_slots_and_omits_zero_slots()
  local Compile = compiler()
  -- Chikorita evolves into Bayleef (153) at level 16 (method 4).
  local slots = assert(Compile.decodeEvolution(member({ slot(4, 16, 153) }), context()))
  Assert.equal(#slots, 1)
  Assert.deepEqual(slots[1], { method = 4, param = 16, target = 153 })
end

function T.preserves_slot_order_across_methods()
  local Compile = compiler()
  -- Eevee: moss-rock and ice-rock methods before the three stone methods.
  local slots = assert(Compile.decodeEvolution(
    member({
      slot(25, 0, 470),
      slot(26, 0, 471),
      slot(7, 83, 135),
      slot(7, 84, 134),
      slot(7, 82, 136),
    }),
    context()
  ))
  Assert.equal(#slots, 5)
  Assert.equal(slots[1].target, 470)
  Assert.equal(slots[3].method, 7)
  Assert.equal(slots[3].param, 83)
end

function T.rejects_wrong_size_unknown_methods_and_nonzero_padding()
  local Compile = compiler()
  local short, shortErr = Compile.decodeEvolution(string.rep("\0", 43), context())
  Assert.isNil(short)
  Assert.isTrue(Errors.is(shortErr))
  Assert.equal(assert(shortErr).code, "MON_EVO_BAD_SIZE")
  local unknown, unknownErr = Compile.decodeEvolution(member({ slot(27, 0, 1) }), context())
  Assert.isNil(unknown)
  Assert.isTrue(Errors.is(unknownErr))
  Assert.equal(assert(unknownErr).code, "MON_EVO_BAD_VALUE")
  local padded = member({ slot(4, 16, 153) }) .. "?"
  padded = padded:sub(1, 42) .. string.char(1, 0)
  local bad, badErr = Compile.decodeEvolution(padded, context())
  Assert.isNil(bad)
  Assert.isTrue(Errors.is(badErr))
  Assert.equal(assert(badErr).code, "MON_EVO_BAD_VALUE")
end

-- Fixed native vocabulary parity: the strict generated-asset schema and
-- the composed resolved schema share the same growth-curve, move-category,
-- and native evolution-method membership while keeping their different
-- admission policies. Known native values validate in both; unsupported
-- values fail in both.
function T.known_native_vocabularies_validate_in_both_schemas()
  local MonAssetSchema = require("libs.assets.src.MonAssetSchema")
  local ResolvedMonSchema = require("libs.mons.src.ResolvedMonSchema")

  local root = CatalogFixture.buildAssetRoot()
  -- The synthetic fixture carries no evolutions, so name one native
  -- method through both validators alongside the fixture's curves and
  -- categories.
  root.species.CHIKORITA.forms[0].evolutions = {
    { method = "level", level = 16, target = "TOTODILE", form = 0 },
  }
  Assert.isTrue(MonAssetSchema.assertCatalog(root) ~= false, "the strict schema accepts native vocabulary")
  Assert.isTrue(ResolvedMonSchema.assertCatalog(root) ~= false, "the resolved schema accepts native vocabulary")
end

function T.unknown_native_vocabularies_fail_in_both_schemas()
  local MonAssetSchema = require("libs.assets.src.MonAssetSchema")
  local ResolvedMonSchema = require("libs.mons.src.ResolvedMonSchema")

  local badGrowth = CatalogFixture.buildAssetRoot()
  badGrowth.species.CHIKORITA.growthCurve = "dawn"
  Assert.throws(function()
    MonAssetSchema.assertCatalog(badGrowth)
  end, "the strict schema rejects an unknown growth curve")
  Assert.throws(function()
    ResolvedMonSchema.assertCatalog(badGrowth)
  end, "the resolved schema rejects an unknown growth curve")

  local badCategory = CatalogFixture.buildAssetRoot()
  badCategory.moves.TACKLE.category = "cosmic"
  Assert.throws(function()
    MonAssetSchema.assertCatalog(badCategory)
  end, "the strict schema rejects an unknown move category")
  Assert.throws(function()
    ResolvedMonSchema.assertCatalog(badCategory)
  end, "the resolved schema rejects an unknown move category")

  local badMethod = CatalogFixture.buildAssetRoot()
  badMethod.species.CHIKORITA.forms[0].evolutions = {
    { method = "warp", target = "TOTODILE", form = 0 },
  }
  Assert.throws(function()
    MonAssetSchema.assertCatalog(badMethod)
  end, "the strict schema rejects an unknown evolution method")
  Assert.throws(function()
    ResolvedMonSchema.assertCatalog(badMethod)
  end, "the resolved schema rejects an unknown evolution method")
end

return { tests = T }
