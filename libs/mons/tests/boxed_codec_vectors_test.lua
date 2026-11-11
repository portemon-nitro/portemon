-- Exact boxed representation: fixed reference byte vectors prove clear
-- block layout, checksum, permutation, and cipher compatibility beyond
-- round trips, while decoding rejects corruption and never invents
-- party-only state.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local Mon = require("libs.mons.src.Mon")
local MonsErrors = require("libs.mons.src.errors")

local T = {}

local FIRST_HEX =
  "e30f5cd800004dbca66accddf60d900956dead6c81c674df776d21b01cee8f99334650839c135a111bfebf6d815c9953b37c4854c54ebba7eca8a568a0910791f5f458024e6114d15ca6b2e5267a4b1c20632690b5c4e87d41203411fdc6d979cdf677ab7fcce5c3c90dff93a26b57787371cf456ecde5dc0e53a89c5287acb9f275584eddc7c585"
local SECOND_HEX =
  "1227c05b0000466a2a18e475d4c7717fe6c5790dfc75bf1ecee41310bd42712ca1b161685c3a7123b5bdae607041b2f1a9351bcb5596cf3dc66de37973ee928235d287c32041404025b8500392dd9f68b87aa563ae2e799a9b35d4e58a071da6d2a735be02ae621b65c6c8eeb576f582e8f38f5eb97817de2ecfd15305f4048ea8f1d5c29b071c2a"
local THIRD_HEX =
  "904a749000004bed2adb8a78da1d5f76e5e6cbf106c56db7642a01401b9062d56fa1361b65a15f9f3a04e315a1ba8c2062684a9adc6849c55e86920b1b7b82d6360f2ac6b878a58cd539794f2aa38299a4742d57063d3459637d98da3f699d06630e88db1351bea92be3f26242dfb613652346ef76478b5cda882070d46b10238d7460d533badd56"
local FOURTH_HEX =
  "bf61d8130000a847612906bd6ac754b462a9c307350fa758852e04b8a78144a1028db0fc261a3cc0c0ff362eda2e92057e2c6c97e5f84046431b06e78b4d4ceb70bf1a3a6244163b90bd396ed5121f19bf4c961a943ce27a5f59274beff0d638b2f5771bbe29d4eae80d80de7f448f9148bb89cf0357d228ea44ad079240c995f70ff3147340e947"

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected a structured error")
  Assert.equal(err.code, code)
end

local function origin()
  return {
    trainerId = 2271560481,
    trainerName = "RED",
    trainerGender = 0,
    game = "heartgold",
    ball = "POKE_BALL",
    language = "english",
  }
end

local function met(location, level, terrain)
  return {
    location = location,
    date = { year = 2009, month = 9, day = 13 },
    level = level,
    terrain = terrain,
  }
end

function T.boxed_bytes_match_reference_vectors_and_decode_exactly()
  local catalog = CatalogFixture.makeCatalog()
  local context = CatalogFixture.domainContext(catalog)
  local Mon = require("libs.mons.src.Mon")
  local BoxCodec = require("libs.mons.src.gen4.BoxCodec")

  local firstMaker = CatalogFixture.makeFactory(0x10000024, catalog)
  local first = firstMaker:createNormal(CatalogFixture.normalRequest({ level = 5 }))
  Assert.equal(CatalogFixture.toHex(BoxCodec.encode(first, context)), FIRST_HEX)
  local firstProjection = {
    schema = Mon.SCHEMA,
    species = "CHIKORITA",
    form = 0,
    personality = 3629912035,
    experience = 135,
    friendship = 70,
    ability = "OVERGROW",
    heldItem = "NONE",
    markings = 0,
    evs = { hp = 0, attack = 0, defense = 0, speed = 0, specialAttack = 0, specialDefense = 0 },
    contest = { cool = 0, beauty = 0, cute = 0, smart = 0, tough = 0, sheen = 0 },
    moves = {
      { move = "TACKLE", pp = 35, ppUps = 0 },
      { move = "GROWL", pp = 40, ppUps = 0 },
    },
    ivs = { hp = 31, attack = 0, defense = 13, speed = 26, specialAttack = 20, specialDefense = 14 },
    isEgg = false,
    ribbons = { ds1 = 0, gba = 0, ds2 = 0 },
    fatefulEncounter = false,
    shinyLeaves = 0,
    egg = { location = 0 },
    met = met(7, 5, 4),
    origin = origin(),
    pokerus = 0,
    mood = 0,
  }
  local firstDecoded = BoxCodec.decode(CatalogFixture.fromHex(FIRST_HEX), context)
  Assert.deepEqual(firstDecoded, firstProjection)
  Assert.deepEqual(BoxCodec.project(first, context), firstProjection)

  local secondMaker = CatalogFixture.makeFactory(0x1000000D, catalog)
  local secondRaw = secondMaker:createNormal(CatalogFixture.normalRequest())
  secondRaw.contest = { cool = 200, beauty = 150, cute = 100, smart = 50, tough = 25, sheen = 60 }
  secondRaw.markings = 85
  secondRaw.ribbons = { ds1 = 1, gba = 32, ds2 = 1 }
  secondRaw.fatefulEncounter = true
  local second = Mon.validate(secondRaw, context)
  Assert.equal(CatalogFixture.toHex(BoxCodec.encode(second, context)), SECOND_HEX)
  local secondProjection = {
    schema = Mon.SCHEMA,
    species = "CHIKORITA",
    form = 0,
    personality = 1539319570,
    experience = 419,
    friendship = 70,
    ability = "OVERGROW",
    heldItem = "NONE",
    markings = 85,
    evs = { hp = 0, attack = 0, defense = 0, speed = 0, specialAttack = 0, specialDefense = 0 },
    contest = { cool = 200, beauty = 150, cute = 100, smart = 50, tough = 25, sheen = 60 },
    moves = {
      { move = "TACKLE", pp = 35, ppUps = 0 },
      { move = "GROWL", pp = 40, ppUps = 0 },
      { move = "RAZOR_LEAF", pp = 25, ppUps = 0 },
      { move = "POISONPOWDER", pp = 35, ppUps = 0 },
    },
    ivs = { hp = 19, attack = 6, defense = 10, speed = 5, specialAttack = 0, specialDefense = 22 },
    isEgg = false,
    ribbons = { ds1 = 1, gba = 32, ds2 = 1 },
    fatefulEncounter = true,
    shinyLeaves = 0,
    egg = { location = 0 },
    met = met(7, 9, 4),
    origin = origin(),
    pokerus = 0,
    mood = 0,
  }
  Assert.deepEqual(BoxCodec.decode(CatalogFixture.fromHex(SECOND_HEX), context), secondProjection)
  Assert.deepEqual(BoxCodec.project(second, context), secondProjection)

  local thirdMaker = CatalogFixture.makeFactory(0x10000021, catalog)
  local thirdRaw = thirdMaker:createNormal(CatalogFixture.normalRequest({ species = "TOTODILE", level = 5 }))
  thirdRaw.nickname = "LEAF"
  thirdRaw.heldItem = "SITRUS_BERRY"
  thirdRaw.shinyLeaves = 42
  thirdRaw.pokerus = 19
  thirdRaw.mood = -5
  local third = Mon.validate(thirdRaw, context)
  Assert.equal(CatalogFixture.toHex(BoxCodec.encode(third, context)), THIRD_HEX)
  local thirdProjection = {
    schema = Mon.SCHEMA,
    species = "TOTODILE",
    form = 0,
    personality = 2423540368,
    experience = 135,
    friendship = 70,
    ability = "TORRENT",
    heldItem = "SITRUS_BERRY",
    markings = 0,
    evs = { hp = 0, attack = 0, defense = 0, speed = 0, specialAttack = 0, specialDefense = 0 },
    contest = { cool = 0, beauty = 0, cute = 0, smart = 0, tough = 0, sheen = 0 },
    moves = {
      { move = "SCRATCH", pp = 35, ppUps = 0 },
      { move = "LEER", pp = 30, ppUps = 0 },
    },
    ivs = { hp = 6, attack = 21, defense = 12, speed = 7, specialAttack = 4, specialDefense = 28 },
    isEgg = false,
    nickname = "LEAF",
    ribbons = { ds1 = 0, gba = 0, ds2 = 0 },
    fatefulEncounter = false,
    shinyLeaves = 42,
    egg = { location = 0 },
    met = met(7, 5, 4),
    origin = origin(),
    pokerus = 19,
    mood = -5,
  }
  Assert.deepEqual(BoxCodec.decode(CatalogFixture.fromHex(THIRD_HEX), context), thirdProjection)
  Assert.deepEqual(BoxCodec.project(third, context), thirdProjection)

  local fourthMaker = CatalogFixture.makeFactory(0x1000000A, catalog)
  local fourthRaw = fourthMaker:createNormal(CatalogFixture.normalRequest({ species = "EEVEE", level = 100 }))
  fourthRaw.friendship = 255
  fourthRaw.markings = 255
  fourthRaw.shinyLeaves = 63
  fourthRaw.pokerus = 255
  fourthRaw.mood = 127
  fourthRaw.contest = { cool = 255, beauty = 255, cute = 255, smart = 255, tough = 255, sheen = 255 }
  fourthRaw.evs = { hp = 252, attack = 252, defense = 6, speed = 0, specialAttack = 0, specialDefense = 0 }
  fourthRaw.met.location = 11
  fourthRaw.met.terrain = 9
  local fourth = Mon.validate(fourthRaw, context)
  Assert.equal(CatalogFixture.toHex(BoxCodec.encode(fourth, context)), FOURTH_HEX)
  local fourthProjection = {
    schema = Mon.SCHEMA,
    species = "EEVEE",
    form = 0,
    personality = 332947903,
    experience = 1000000,
    friendship = 255,
    ability = "ADAPTABILITY",
    heldItem = "NONE",
    markings = 255,
    evs = { hp = 252, attack = 252, defense = 6, speed = 0, specialAttack = 0, specialDefense = 0 },
    contest = { cool = 255, beauty = 255, cute = 255, smart = 255, tough = 255, sheen = 255 },
    moves = {
      { move = "TACKLE", pp = 35, ppUps = 0 },
      { move = "TAIL_WHIP", pp = 30, ppUps = 0 },
      { move = "SAND_ATTACK", pp = 15, ppUps = 0 },
      { move = "QUICK_ATTACK", pp = 30, ppUps = 0 },
    },
    ivs = { hp = 26, attack = 26, defense = 9, speed = 17, specialAttack = 15, specialDefense = 3 },
    isEgg = false,
    ribbons = { ds1 = 0, gba = 0, ds2 = 0 },
    fatefulEncounter = false,
    shinyLeaves = 63,
    egg = { location = 0 },
    met = met(11, 100, 9),
    origin = origin(),
    pokerus = 255,
    mood = 127,
  }
  Assert.deepEqual(BoxCodec.decode(CatalogFixture.fromHex(FOURTH_HEX), context), fourthProjection)
  Assert.deepEqual(BoxCodec.project(fourth, context), fourthProjection)

  -- Decoding never invents party-only state the boxed bytes cannot carry.
  for _, bytes in ipairs({ FIRST_HEX, SECOND_HEX, THIRD_HEX, FOURTH_HEX }) do
    local decoded = BoxCodec.decode(CatalogFixture.fromHex(bytes), context)
    Assert.isNil(decoded.condition)
    Assert.isNil(decoded.mail)
    Assert.isNil(decoded.capsule)
  end

  -- A single altered bit breaks the checksum before anything is published.
  local stored = CatalogFixture.fromHex(FIRST_HEX)
  local last = string.byte(stored, 136)
  local tampered = stored:sub(1, 135) .. string.char((last + 1) % 256)
  throwsCode("MON_CODEC_INVALID", function()
    BoxCodec.decode(tampered, context)
  end)
  throwsCode("MON_CODEC_INVALID", function()
    BoxCodec.decode(stored:sub(1, 135), context)
  end)
end

function T.boxed_origin_games_round_trip_every_representable_native_identity()
  local catalog = CatalogFixture.makeCatalog()
  local context = CatalogFixture.domainContext(catalog)
  local Mon = require("libs.mons.src.Mon")
  local BoxCodec = require("libs.mons.src.gen4.BoxCodec")
  local mon = CatalogFixture.makeFactory(0x10000024, catalog):createNormal(CatalogFixture.normalRequest({ level = 5 }))
  for game, nativeId in pairs(CatalogFixture.GAMES) do
    mon.origin.game = game
    local canonical = Mon.validate(mon, context)
    local decoded = BoxCodec.decode(BoxCodec.encode(canonical, context), context)
    Assert.equal(decoded.origin.game, game)
    Assert.equal(context.games[decoded.origin.game], nativeId)
  end
end

-- The independently derived gift-egg vector: the pinned script-egg
-- record encodes to a stable 136-byte form whose cleared meeting
-- triple restores to absence, and malformed cleared dates never
-- encode. The vector below pins the full ciphered layout while the
-- semantic assertions carry the independent evidence.
local EGG_HEX =
  "710bea8400009dcd4422ec7d9bce92a0fbc89fbc0b6d657164f9b9b48056c188f8dbe334394f69a222c0a1f3398de4160c1a8df8a673a4492fb5a8df123908b34ced7991e7d4d35ee08f12b837e29afffd3a38e7aec735860de96e584c40da5a23b943996cdf416d6907e722e18a5d51a1730093dee0bc994be6cee78669b327fba72c0db2e5db6c"

function T.gift_egg_bytes_carry_the_cleared_meeting_record()
  local catalog = CatalogFixture.makeCatalog()
  local context = CatalogFixture.domainContext(catalog)
  local BoxCodec = require("libs.mons.src.gen4.BoxCodec")
  local factory = CatalogFixture.makeFactory(0x12345678, catalog)
  local egg = factory:createScriptEgg({
    species = "PICHU",
    profile = CatalogFixture.profile(),
    location = 2014,
    date = CatalogFixture.metDate(),
  })
  Assert.equal(CatalogFixture.toHex(BoxCodec.encode(egg, context)), EGG_HEX)
  local decoded = BoxCodec.decode(CatalogFixture.fromHex(EGG_HEX), context)
  Assert.isTrue(decoded.isEgg, "the vector stays an egg")
  Assert.isNil(decoded.nickname, "the vector keeps no custom nickname")
  Assert.equal(decoded.species, "PICHU")
  Assert.deepEqual(decoded.egg, { location = 2014, date = { year = 2009, month = 9, day = 13 } })
  Assert.equal(decoded.met.location, 0)
  Assert.isNil(decoded.met.date, "the all-zero triple restores to absence")
  Assert.equal(decoded.met.level, 0)
  Assert.equal(decoded.met.terrain, 0)
  Assert.equal(decoded.friendship, 20)
  decoded.condition = { currentHp = 0, effects = {} }
  decoded.capsule = { id = 0, seals = {} }
  decoded.mail = {}
  Assert.equal(CatalogFixture.toHex(BoxCodec.encode(decoded, context)), EGG_HEX)

  -- A single altered bit breaks the checksum before anything publishes,
  -- exactly like the ordinary vectors.
  local stored = CatalogFixture.fromHex(EGG_HEX)
  local last = string.byte(stored, 136)
  local tampered = stored:sub(1, 135) .. string.char((last + 1) % 256)
  throwsCode("MON_CODEC_INVALID", function()
    BoxCodec.decode(tampered, context)
  end)

  -- Malformed cleared dates never encode: a partial zero triple, a
  -- zero level on an ordinary mon, and an absent date outside the
  -- cleared egg shape all fail at admission.
  throwsCode("MON_RECORD_INVALID", function()
    local partial = Mon.validate(egg, context)
    partial.met.date = { year = 2009, month = 0, day = 0 }
    BoxCodec.encode(partial, context)
  end)
  throwsCode("MON_RECORD_INVALID", function()
    local ordinary = factory:createNormal(CatalogFixture.normalRequest())
    ordinary.met.level = 0
    BoxCodec.encode(ordinary, context)
  end)
  throwsCode("MON_RECORD_INVALID", function()
    local dateless = factory:createNormal(CatalogFixture.normalRequest())
    dateless.met.date = nil
    BoxCodec.encode(dateless, context)
  end)
end

function T.decoded_records_are_semantically_admitted_inside_the_codec_boundary()
  local catalog = CatalogFixture.makeCatalog()
  local context = CatalogFixture.domainContext(catalog)
  local BoxCodec = require("libs.mons.src.gen4.BoxCodec")
  local originalValidate = Mon.validate
  local validations = 0
  Mon.validate = function(...)
    validations = validations + 1
    return originalValidate(...)
  end
  local ok, decoded = pcall(BoxCodec.decode, CatalogFixture.fromHex(FIRST_HEX), context)
  Mon.validate = originalValidate

  Assert.isTrue(ok, "a valid boxed mon decodes")
  local decodedRecord = assert(decoded) --[[@as table<string, unknown>]]
  Assert.equal(validations, 1, "decoded semantic fields cross admission exactly once")
  Assert.isNil(decodedRecord.condition, "decode preserves the boxed projection shape")

  Mon.validate = function()
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "semantic admission rejected decoded data", {})
  end
  local malformed, err = pcall(BoxCodec.decode, CatalogFixture.fromHex(FIRST_HEX), context)
  Mon.validate = originalValidate
  Assert.isFalse(malformed, "semantic rejection prevents decoded data from escaping")
  Assert.isTrue(Errors.is(err), "semantic rejection remains structured at the byte boundary")
  Assert.equal(assert(err).code, "MON_CODEC_INVALID", "decode reports malformed semantic content as a codec failure")
end

return { tests = T }
