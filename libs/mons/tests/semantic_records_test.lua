-- Semantic records and native legality: derivable values never persist
-- as independent fields, pure derivation helpers follow the reference
-- formulas, and unrepresentable records fail with stable structured
-- errors instead of being clamped into legal-looking output.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")

local T = {}

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected a structured error")
  Assert.equal(err.code, code)
end

local function throwsEither(codes, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected a structured error")
  local matched = false
  for _, code in ipairs(codes) do
    if err.code == code then
      matched = true
    end
  end
  Assert.isTrue(matched, "unexpected error code " .. tostring(err.code))
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

function T.derivations_come_from_formulas_and_derived_keys_are_rejected()
  local catalog = CatalogFixture.makeCatalog()
  local context = CatalogFixture.domainContext(catalog)
  local Mon = require("libs.mons.src.Mon")
  local Personality = require("libs.mons.src.gen4.Personality")
  local Experience = require("libs.mons.src.gen4.Experience")
  local Stats = require("libs.mons.src.gen4.Stats")

  local factory = CatalogFixture.makeFactory(0x12345678, catalog)
  local mon = factory:createNormal(CatalogFixture.normalRequest())

  -- Persisted derivations would let stored values contradict the
  -- personality, identity, and experience they derive from, so every
  -- derived key is an unknown field.
  for _, field in ipairs({ "level", "nature", "gender", "shiny", "maxHp", "stats", "characteristic" }) do
    local altered = copy(mon)
    altered[field] = 1
    throwsCode("MON_RECORD_INVALID", function()
      Mon.validate(altered, context)
    end)
  end

  Assert.equal(Personality.nature(0), 0)
  Assert.equal(Personality.nature(1), 1)
  Assert.equal(Personality.nature(24), 24)
  Assert.equal(Personality.nature(25), 0)
  Assert.equal(Personality.nature(0xFFFFFFFF), 20)

  Assert.equal(Personality.gender(31, 30), "female")
  Assert.equal(Personality.gender(31, 31), "male")
  Assert.equal(Personality.gender(127, 126), "female")
  Assert.equal(Personality.gender(127, 127), "male")
  Assert.equal(Personality.gender(0, 12345), "male")
  Assert.equal(Personality.gender(254, 12345), "female")
  Assert.equal(Personality.gender(255, 12345), "genderless")

  Assert.equal(Personality.shiny(0, 7), true)
  Assert.equal(Personality.shiny(0, 8), false)
  Assert.equal(Personality.shiny(2271560481, 2229930865), false)

  Assert.equal(Personality.abilitySlot(1, 99), 1)
  Assert.equal(Personality.abilitySlot(2, 3264344792), 1)
  Assert.equal(Personality.abilitySlot(2, 3629912035), 2)

  local mediumSlow = catalog:growthCurve("medium_slow")
  Assert.equal(Experience.expFor(mediumSlow, 1), 0)
  Assert.equal(Experience.expFor(mediumSlow, 5), 135)
  Assert.equal(Experience.level(mediumSlow, 0), 1)
  Assert.equal(Experience.level(mediumSlow, 134), 4)
  Assert.equal(Experience.level(mediumSlow, 135), 5)
  Assert.equal(Experience.level(mediumSlow, 1059860), 100)
  Assert.equal(Experience.level(mediumSlow, 2000000), 100)

  local base = { hp = 100, attack = 100, defense = 100, speed = 100, specialAttack = 100, specialDefense = 100 }
  local fullIv = { hp = 31, attack = 31, defense = 31, speed = 31, specialAttack = 31, specialDefense = 31 }
  local noEv = { hp = 0, attack = 0, defense = 0, speed = 0, specialAttack = 0, specialDefense = 0 }
  local plain = { hp = 175, attack = 120, defense = 120, speed = 120, specialAttack = 120, specialDefense = 120 }
  Assert.deepEqual(Stats.calculate(base, fullIv, noEv, 50, 0), plain)
  local lonely = copy(plain)
  lonely.attack = 132
  lonely.defense = 108
  Assert.deepEqual(Stats.calculate(base, fullIv, noEv, 50, 1), lonely)
  local bold = copy(plain)
  bold.attack = 108
  bold.defense = 132
  Assert.deepEqual(Stats.calculate(base, fullIv, noEv, 50, 5), bold)
  local timid = copy(plain)
  timid.attack = 108
  timid.speed = 132
  Assert.deepEqual(Stats.calculate(base, fullIv, noEv, 50, 10), timid)
  local modest = copy(plain)
  modest.attack = 108
  modest.specialAttack = 132
  Assert.deepEqual(Stats.calculate(base, fullIv, noEv, 50, 15), modest)
  local calm = copy(plain)
  calm.attack = 108
  calm.specialDefense = 132
  Assert.deepEqual(Stats.calculate(base, fullIv, noEv, 50, 20), calm)

  -- The single-health species keeps one current health point instead of
  -- applying the health formula.
  local shedinjaMaker = CatalogFixture.makeFactory(0x44444444, catalog)
  local shedinja = shedinjaMaker:createNormal(CatalogFixture.normalRequest({ species = "SHEDINJA", level = 5 }))
  Assert.equal(shedinja.experience, 237)
  Assert.equal(shedinja.condition.currentHp, 1)
  Assert.equal(Personality.gender(255, shedinja.personality), "genderless")

  Assert.equal(Mon.displayName(mon, catalog), "CHIKORITA")
  local nicknamed = copy(mon)
  nicknamed.nickname = "LEAF"
  Assert.equal(Mon.displayName(Mon.validate(nicknamed, context), catalog), "LEAF")
end

function T.unrepresentable_records_fail_with_structured_errors()
  local catalog = CatalogFixture.makeCatalog()
  local context = CatalogFixture.domainContext(catalog)
  local Mon = require("libs.mons.src.Mon")
  local NativeLegality = require("libs.mons.src.gen4.NativeLegality")
  local BoxCodec = require("libs.mons.src.gen4.BoxCodec")

  local factory = CatalogFixture.makeFactory(0x12345678, catalog)
  local valid = factory:createNormal(CatalogFixture.normalRequest())
  Assert.notNil(NativeLegality.project(valid, context))

  local leveled = factory:createNormal(CatalogFixture.normalRequest({ level = 5 }))
  leveled.experience = catalog:growthCurve(catalog:species(leveled.species).growthCurve)[20]
  Assert.equal(leveled.met.level, 5)
  leveled = Mon.validate(leveled, context)
  Assert.notNil(NativeLegality.project(leveled, context))
  local BoxCodec = require("libs.mons.src.gen4.BoxCodec")
  Assert.equal(BoxCodec.decode(BoxCodec.encode(leveled, context), context).met.level, 5)

  local function invalid(mutator)
    local altered = copy(valid)
    mutator(altered)
    return altered
  end

  throwsCode("MON_RECORD_INVALID", function()
    Mon.validate(
      invalid(function(mon)
        mon.species = "BOGUS"
      end),
      context
    )
  end)
  throwsCode("MON_RECORD_INVALID", function()
    Mon.validate(
      invalid(function(mon)
        mon.form = 5
      end),
      context
    )
  end)
  throwsCode("MON_RECORD_INVALID", function()
    Mon.validate(
      invalid(function(mon)
        mon.ability = "TORRENT"
      end),
      context
    )
  end)
  throwsCode("MON_RECORD_INVALID", function()
    Mon.validate(
      invalid(function(mon)
        mon.moves[2] = { move = "TACKLE", pp = 35, ppUps = 0 }
      end),
      context
    )
  end)
  throwsCode("MON_RECORD_INVALID", function()
    Mon.validate(
      invalid(function(mon)
        mon.evs = { hp = 200, attack = 200, defense = 200, speed = 0, specialAttack = 0, specialDefense = 0 }
      end),
      context
    )
  end)
  throwsCode("MON_RECORD_INVALID", function()
    Mon.validate(
      invalid(function(mon)
        mon.ivs.hp = 32
      end),
      context
    )
  end)
  throwsCode("MON_RECORD_INVALID", function()
    Mon.validate(
      invalid(function(mon)
        mon.experience = 2000000
      end),
      context
    )
  end)
  throwsCode("MON_RECORD_INVALID", function()
    Mon.validate(
      invalid(function(mon)
        mon.met.level = 0
      end),
      context
    )
  end)
  throwsCode("MON_RECORD_INVALID", function()
    Mon.validate(
      invalid(function(mon)
        mon.nickname = "ABCDEFGHIJK"
      end),
      context
    )
  end)
  throwsCode("ITEM_RECORD_INVALID", function()
    Mon.validate(
      invalid(function(mon)
        mon.heldItem = "BOGUS"
      end),
      context
    )
  end)
  throwsCode("ITEM_RECORD_INVALID", function()
    Mon.validate(
      invalid(function(mon)
        mon.origin.ball = "BOGUS_BALL"
      end),
      context
    )
  end)
  throwsCode("MON_RECORD_INVALID", function()
    Mon.validate(
      invalid(function(mon)
        mon.origin.trainerName = "RE~D"
      end),
      context
    )
  end)

  -- Power-point bounds live at the native projection: the schema accepts
  -- the shape, but no encoder may clamp the values into range.
  local overPp = invalid(function(mon)
    mon.moves[1].pp = 99
  end)
  throwsEither({ "MON_RECORD_INVALID", "MON_LEGALITY_INVALID" }, function()
    BoxCodec.encode(overPp, context)
  end)
  Assert.equal(overPp.moves[1].pp, 99)
  throwsEither({ "MON_RECORD_INVALID", "MON_LEGALITY_INVALID" }, function()
    BoxCodec.encode(
      invalid(function(mon)
        mon.moves[1].ppUps = 4
      end),
      context
    )
  end)

  -- Met level is historical source data, independent of current experience.
  local historical = invalid(function(mon)
    mon.met.level = 6
  end)
  Assert.equal(BoxCodec.decode(BoxCodec.encode(historical, context), context).met.level, 6)
end

function T.numeric_boundaries_and_domain_relationships_hold_at_the_validation_boundary()
  local catalog = CatalogFixture.makeCatalog()
  local context = CatalogFixture.domainContext(catalog)
  local Mon = require("libs.mons.src.Mon")

  local factory = CatalogFixture.makeFactory(0x12345678, catalog)
  local valid = factory:createNormal(CatalogFixture.normalRequest())
  local maxHp = valid.condition.currentHp

  local function altered(mutator)
    local next = copy(valid)
    mutator(next)
    return next
  end

  local function accepted(mutator)
    local input = altered(mutator)
    local validated = Mon.validate(input, context)
    Assert.deepEqual(validated, input)
  end

  local function rejected(mutator)
    throwsCode("MON_RECORD_INVALID", function()
      Mon.validate(altered(mutator), context)
    end)
  end

  -- The factory record itself is canonical under the same validator.
  Assert.deepEqual(Mon.validate(valid, context), valid)

  -- Individual values span the full 0..31 range at each edge.
  accepted(function(mon)
    mon.ivs = { hp = 0, attack = 0, defense = 0, speed = 0, specialAttack = 0, specialDefense = 0 }
    mon.condition.currentHp = 0
  end)
  accepted(function(mon)
    mon.ivs = { hp = 31, attack = 31, defense = 31, speed = 31, specialAttack = 31, specialDefense = 31 }
  end)
  rejected(function(mon)
    mon.ivs.hp = 32
  end)
  rejected(function(mon)
    mon.ivs.attack = -1
  end)

  -- Power-point ups stay inside 0..3 while the point cap follows the
  -- move definition rather than the ups on the entry.
  accepted(function(mon)
    mon.moves[1].ppUps = 3
  end)
  rejected(function(mon)
    mon.moves[1].ppUps = 4
  end)
  accepted(function(mon)
    mon.moves[1].pp = 56
  end)
  rejected(function(mon)
    mon.moves[1].pp = 57
  end)

  -- Duplicate moves are rejected; distinct entries validate.
  rejected(function(mon)
    mon.moves[2] = { move = "TACKLE", pp = 35, ppUps = 0 }
  end)
  accepted(function(mon)
    mon.moves[2] = { move = "LEER", pp = 30, ppUps = 0 }
  end)

  -- Ability membership follows the selected form.
  rejected(function(mon)
    mon.ability = "TORRENT"
  end)

  -- Effort totals accept exactly 510 and reject 511.
  accepted(function(mon)
    mon.evs = { hp = 255, attack = 255, defense = 0, speed = 0, specialAttack = 0, specialDefense = 0 }
  end)
  rejected(function(mon)
    mon.evs = { hp = 255, attack = 255, defense = 1, speed = 0, specialAttack = 0, specialDefense = 0 }
  end)

  -- Current health spans 0..derived maximum and no further.
  accepted(function(mon)
    mon.condition.currentHp = 0
  end)
  accepted(function(mon)
    mon.condition.currentHp = maxHp
  end)
  rejected(function(mon)
    mon.condition.currentHp = maxHp + 1
  end)

  -- Met level keeps its 1..100 range at this layer.
  accepted(function(mon)
    mon.met.level = 1
  end)
  accepted(function(mon)
    mon.met.level = 100
  end)
  rejected(function(mon)
    mon.met.level = 0
  end)
  rejected(function(mon)
    mon.met.level = 101
  end)

  -- Trainer gender is exactly 0 or 1.
  accepted(function(mon)
    mon.origin.trainerGender = 1
  end)
  rejected(function(mon)
    mon.origin.trainerGender = 2
  end)

  -- Mood spans the signed byte range.
  accepted(function(mon)
    mon.mood = -128
  end)
  accepted(function(mon)
    mon.mood = 127
  end)
  rejected(function(mon)
    mon.mood = -129
  end)
  rejected(function(mon)
    mon.mood = 128
  end)

  -- The second ribbon generation keeps its exactly representable range.
  accepted(function(mon)
    mon.ribbons.ds2 = 9007199254740991
  end)
  rejected(function(mon)
    mon.ribbons.ds2 = 9007199254740992
  end)
  rejected(function(mon)
    mon.ribbons.ds2 = -1
  end)

  -- Date fields keep their accepted calendar shape without gaining a
  -- Gregorian check: February 30 remains accepted.
  accepted(function(mon)
    mon.met.date = { year = 2000, month = 1, day = 1 }
  end)
  accepted(function(mon)
    mon.met.date = { year = 2255, month = 12, day = 31 }
  end)
  accepted(function(mon)
    mon.met.date = { year = 2009, month = 2, day = 30 }
  end)
  rejected(function(mon)
    mon.met.date = { year = 1999, month = 9, day = 13 }
  end)
  rejected(function(mon)
    mon.met.date = { year = 2256, month = 9, day = 13 }
  end)
  rejected(function(mon)
    mon.met.date = { year = 2009, month = 0, day = 13 }
  end)
  rejected(function(mon)
    mon.met.date = { year = 2009, month = 13, day = 13 }
  end)
  rejected(function(mon)
    mon.met.date = { year = 2009, month = 9, day = 0 }
  end)
  rejected(function(mon)
    mon.met.date = { year = 2009, month = 9, day = 32 }
  end)

  -- The egg date stays optional and the empty mail record stays valid.
  accepted(function(mon)
    mon.egg = { location = 0 }
  end)
  accepted(function(mon)
    mon.egg = { location = 0, date = { year = 2009, month = 9, day = 13 } }
  end)
  rejected(function(mon)
    mon.egg = { location = 0, date = { year = 1999, month = 9, day = 13 } }
  end)
  accepted(function(mon)
    mon.mail = {}
  end)
  rejected(function(mon)
    mon.mail = { letter = 1 }
  end)

  -- Optional nicknames keep their glyph capacity: ten glyphs fit.
  accepted(function(mon)
    mon.nickname = "ABCDEFGHIJ"
  end)
  rejected(function(mon)
    mon.nickname = "ABCDEFGHIJK"
  end)

  -- Shiny leaves keep their six-bit range.
  accepted(function(mon)
    mon.shinyLeaves = 63
  end)
  rejected(function(mon)
    mon.shinyLeaves = 64
  end)

  -- Single-byte scalars keep their 0..255 range.
  accepted(function(mon)
    mon.markings = 255
  end)
  rejected(function(mon)
    mon.markings = 256
  end)
  accepted(function(mon)
    mon.contest.cool = 255
  end)
  rejected(function(mon)
    mon.contest.cool = 256
  end)

  -- Held items accept any known item while the origin ball must be a ball.
  accepted(function(mon)
    mon.heldItem = "SITRUS_BERRY"
  end)
  accepted(function(mon)
    mon.origin.ball = "GREAT_BALL"
  end)
  throwsCode("ITEM_RECORD_INVALID", function()
    Mon.validate(
      altered(function(mon)
        mon.heldItem = "BOGUS"
      end),
      context
    )
  end)
  throwsCode("MON_RECORD_INVALID", function()
    Mon.validate(
      altered(function(mon)
        mon.origin.ball = "SITRUS_BERRY"
      end),
      context
    )
  end)

  -- Capsule identity keeps its byte range and seals stay bounded.
  accepted(function(mon)
    mon.capsule = { id = 255, seals = {} }
  end)
  rejected(function(mon)
    mon.capsule = { id = 256, seals = {} }
  end)
  accepted(function(mon)
    mon.capsule = { id = 0, seals = { { x = 1, y = 2, graphic = 3 } } }
  end)
  rejected(function(mon)
    mon.capsule = { id = 0, seals = { { x = 256, y = 0, graphic = 0 } } }
  end)
end

return { tests = T }
