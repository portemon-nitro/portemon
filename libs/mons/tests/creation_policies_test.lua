-- Named creation policies: the starter wrapper pins every source value
-- for its candidate, and the script-gift wrapper applies held item, form,
-- and ability overrides after ordinary creation, rejecting combinations
-- the final form cannot represent.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")

local T = {}

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected a structured error")
  Assert.equal(err.code, code)
end

function T.starter_creation_pins_policy_values()
  local catalog = CatalogFixture.makeCatalog()
  local context = CatalogFixture.domainContext(catalog)
  local MonFactory = require("libs.mons.src.gen4.MonFactory")
  local Experience = require("libs.mons.src.gen4.Experience")
  local Personality = require("libs.mons.src.gen4.Personality")
  local BoxCodec = require("libs.mons.src.gen4.BoxCodec")
  local args = CatalogFixture.factoryArgs(0x22222222, catalog)
  local factory = MonFactory.new(args)

  local mon = factory:createStarter({
    species = "CHIKORITA",
    profile = CatalogFixture.profile(),
    location = 7,
    date = CatalogFixture.metDate(),
  })

  Assert.equal(mon.species, "CHIKORITA")
  Assert.equal(mon.form, 0)
  Assert.equal(mon.personality, 3481990971)
  Assert.equal(Personality.nature(mon.personality), 21)
  Assert.equal(Personality.gender(31, mon.personality), "male")
  Assert.deepEqual(mon.ivs, {
    hp = 30,
    attack = 1,
    defense = 12,
    speed = 16,
    specialAttack = 13,
    specialDefense = 19,
  })
  Assert.equal(mon.experience, 135)
  Assert.equal(Experience.level(catalog:growthCurve("medium_slow"), mon.experience), 5)
  Assert.equal(mon.ability, "OVERGROW")
  Assert.equal(mon.heldItem, "NONE")
  Assert.equal(mon.origin.ball, "POKE_BALL")
  Assert.equal(mon.origin.trainerId, 2271560481)
  Assert.equal(mon.origin.trainerName, "RED")
  Assert.equal(mon.met.level, 5)
  Assert.equal(mon.met.location, 7)
  Assert.equal(mon.met.terrain, 12)
  Assert.deepEqual(mon.moves, {
    { move = "TACKLE", pp = 35, ppUps = 0 },
    { move = "GROWL", pp = 40, ppUps = 0 },
  })
  Assert.equal(mon.condition.currentHp, 21)
  Assert.equal(args.rng:capture().calls, 4)

  local encoded = BoxCodec.encode(mon, context)
  Assert.equal(#encoded, 136)
end

function T.script_gift_applies_item_form_and_ability_after_creation()
  local catalog = CatalogFixture.makeCatalog()
  local context = CatalogFixture.domainContext(catalog)
  local MonFactory = require("libs.mons.src.gen4.MonFactory")
  local BoxCodec = require("libs.mons.src.gen4.BoxCodec")
  local args = CatalogFixture.factoryArgs(0x33333333, catalog)
  local factory = MonFactory.new(args)

  local mon = factory:createScriptGift({
    species = "EEVEE",
    level = 5,
    form = 1,
    profile = CatalogFixture.profile(),
    location = 11,
    date = CatalogFixture.metDate(),
    heldItem = "SITRUS_BERRY",
    ability = "ADAPTABILITY",
  })

  Assert.equal(mon.personality, 3264344792)
  -- The drawn personality selects the first ability slot, so the final
  -- second-slot ability proves the override ran after ordinary creation.
  Assert.equal(mon.personality % 2, 0)
  Assert.equal(mon.ability, "ADAPTABILITY")
  Assert.equal(mon.form, 1)
  Assert.equal(mon.heldItem, "SITRUS_BERRY")
  Assert.equal(mon.origin.ball, "POKE_BALL")
  Assert.equal(mon.met.terrain, 24)
  Assert.equal(mon.met.location, 11)
  Assert.equal(mon.met.level, 5)
  Assert.deepEqual(mon.moves, {
    { move = "TACKLE", pp = 35, ppUps = 0 },
    { move = "TAIL_WHIP", pp = 30, ppUps = 0 },
  })
  Assert.equal(mon.condition.currentHp, 20)
  Assert.equal(args.rng:capture().calls, 4)

  local encoded = BoxCodec.encode(mon, context)
  Assert.equal(#encoded, 136)

  -- An ability outside the final form fails at semantic record admission.
  throwsCode("MON_RECORD_INVALID", function()
    factory:createScriptGift({
      species = "EEVEE",
      level = 5,
      form = 1,
      profile = CatalogFixture.profile(),
      location = 11,
      date = CatalogFixture.metDate(),
      heldItem = "SITRUS_BERRY",
      ability = "OVERGROW",
    })
  end)
  throwsCode("MON_RECORD_INVALID", function()
    factory:createScriptGift({
      species = "EEVEE",
      level = 5,
      form = 1,
      profile = CatalogFixture.profile(),
      location = 11,
      date = CatalogFixture.metDate(),
      heldItem = "BOGUS_ITEM",
    })
  end)
end

-- The event-locked Spiky-Ear Pichu distribution: a fixed level-30 form-1
-- Pichu with the source moveset at full power points, the Zap Plate, and
-- an arithmetically forced Naughty female personality (no generator
-- draws), exactly like the retail ROM.
function T.spiky_ear_pichu_pins_the_event_distribution()
  local catalog = CatalogFixture.makeCatalog()
  local Personality = require("libs.mons.src.gen4.Personality")
  local MonFactory = require("libs.mons.src.gen4.MonFactory")
  local args = CatalogFixture.factoryArgs(0x5151ED, catalog)
  local factory = MonFactory.new(args)

  local mon = factory:createSpikyEarPichu({
    profile = CatalogFixture.profile(),
    location = 7,
    date = CatalogFixture.metDate(),
  })

  Assert.equal(mon.species, "PICHU")
  Assert.equal(mon.form, 1, "the event form is applied")
  Assert.equal(mon.met.level, 30)
  Assert.equal(mon.ability, "STATIC")
  Assert.equal(mon.heldItem, "ZAP_PLATE")
  Assert.equal(Personality.nature(mon.personality), 4, "the forced nature is Naughty")
  Assert.equal(Personality.gender(127, mon.personality), "female", "the forced pid reads female")
  Assert.equal(mon.personality % 2, 0, "the forced pid keeps the ability parity")
  Assert.deepEqual(mon.moves, {
    { move = "HELPING_HAND", pp = 20, ppUps = 0 },
    { move = "VOLT_TACKLE", pp = 15, ppUps = 0 },
    { move = "SWAGGER", pp = 15, ppUps = 0 },
    { move = "PAIN_SPLIT", pp = 20, ppUps = 0 },
  })
  Assert.equal(mon.origin.ball, "POKE_BALL")
  Assert.equal(mon.met.terrain, 24)
  Assert.equal(mon.met.location, 7)
  Assert.equal(mon.origin.trainerId, CatalogFixture.profile().trainerId)
  Assert.isFalse(mon.isEgg, "the gift arrives as a mon")
  Assert.equal(mon.egg.location, 0)
  Assert.isFalse(mon.fatefulEncounter, "the gift itself is not fateful")
  -- The forced personality consumes no generator draws: only the two
  -- individual-value draws run, exactly like the source CreateMon with a
  -- fixed personality.
  Assert.equal(args.rng:capture().calls, 2)
end

return { tests = T }
