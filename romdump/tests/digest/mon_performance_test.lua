-- Source layout follows PokeathlonBasePerformance in
-- pret/pokeheartgold@9d8b7591f09b65804da2fb2dfd56f320633e0d36/include/pokemon_types_def.h
-- and the performance index/category mappings in src/pokemon.c and
-- include/constants/pokemon.h.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local MonSources = require("romdump.src.config.MonSources")

local T = {}

local function compiler()
  return require("romdump.src.digest.mons.MonCatalogCompiler")
end

local function performanceMember()
  return string.char(
    3, 4, 5, 6, 7,
    0, 0, 0, 0,
    2, 4, 3, 5, 1, 5, 4, 6, 6, 7,
    0
  )
end

function T.decodes_performance_source_order_to_named_stats()
  local decoded = assert(compiler().decodePerformance(performanceMember(), { archive = "performance", memberId = 1 }))
  Assert.deepEqual(decoded, {
    power = { base = 3, min = 2, max = 4 },
    stamina = { base = 4, min = 3, max = 5 },
    jump = { base = 5, min = 1, max = 5 },
    skill = { base = 6, min = 4, max = 6 },
    speed = { base = 7, min = 6, max = 7 },
  })
end

function T.rejects_performance_size_and_range_errors()
  local _, sizeErr = compiler().decodePerformance(string.rep("\0", 19), { archive = "performance", memberId = 0 })
  Assert.isTrue(Errors.is(sizeErr))
  Assert.equal(assert(sizeErr).code, "MON_PERFORMANCE_BAD_SIZE")

  local member = performanceMember():sub(1, 9) .. string.char(6, 4) .. performanceMember():sub(12)
  local _, rangeErr = compiler().decodePerformance(member, { archive = "performance", memberId = 0 })
  Assert.isTrue(Errors.is(rangeErr))
  Assert.equal(assert(rangeErr).code, "MON_PERFORMANCE_BAD_VALUE")
end

function T.resolves_source_performance_members_with_form_offsets()
  Assert.equal(MonSources.performanceMember(1, 0), 0)
  Assert.equal(MonSources.performanceMember(201, 27), 228)
  Assert.equal(MonSources.performanceMember(202, 0), 229)
  Assert.equal(MonSources.performanceMember(493, 17), 553)
  Assert.isNil(MonSources.performanceMember(494, 0))
end

return { tests = T }
