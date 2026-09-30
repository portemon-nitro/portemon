-- Native status words become persistent condition records. Every supported
-- sleep count, major status, and toxic counter survives the legacy upgrade
-- and encodes to the same boxed bytes, while unsupported combinations and
-- battle-only state fail explicitly instead of being guessed.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")

local T = {}

-- Structured failures at the owning boundary: malformed native words fail
-- while decoding or upgrading, and unrepresentable effects fail while
-- projecting back to the native word.
local NATIVE_CODES = { "MON_RECORD_INVALID", "MON_CODEC_INVALID", "MON_LEGALITY_INVALID" }

-- Boxed bytes for the hand-built record below. Status never enters the
-- boxed form, so every recognized status word below encodes to these exact
-- bytes; the literal was frozen from the current encoder and is never
-- computed by the code under test at assertion time.
local FROZEN_HEX =
  "7856341200003fc007ea51c3cb7df323838001486ea1cef406760e0e46568373b80c61febaba03ab7ad0e09a3d50d727c70a1ecef1b435d86125d2818fe8176f1cb95f6231dee1ecbc704ad23f6559f5a1ec2a73dbaa98e01a774f19701a35e8605908baf8d4d66a55b839deb01af6b3cbcd8f585b3fab82f1eb1c7a8ecf890434bd50ea69715b13"

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

---@param name string
---@param behavior string
---@return table
local function requireOwner(name, behavior)
  local ok, loaded = pcall(require, name)
  Assert.isTrue(ok, "missing " .. behavior .. ": " .. name .. " is not implemented")
  assert(loaded ~= nil, "the status owner loads its module")
  return loaded --[[@as table]]
end

---@param statusWord integer
---@return table<string, unknown>
local function legacyRecord(statusWord)
  return {
    schema = "g4-mon-v1",
    species = "CHIKORITA",
    form = 0,
    personality = 0x12345678,
    experience = 419,
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
    ivs = { hp = 10, attack = 12, defense = 14, speed = 8, specialAttack = 11, specialDefense = 13 },
    isEgg = false,
    nickname = nil,
    ribbons = { ds1 = 0, gba = 0, ds2 = 0 },
    fatefulEncounter = false,
    shinyLeaves = 0,
    egg = { location = 0 },
    met = {
      location = 7,
      date = { year = 2009, month = 9, day = 13 },
      level = 9,
      terrain = 4,
    },
    origin = {
      trainerId = 2271560481,
      trainerName = "RED",
      trainerGender = 0,
      game = "heartgold",
      ball = "POKE_BALL",
      language = "english",
    },
    pokerus = 0,
    mood = 0,
    -- Level nine with the individual values above derives maximum health
    -- 28, so the record below is full health in every status word tried.
    condition = { status = statusWord, currentHp = 28 },
    capsule = { id = 0, seals = {} },
    mail = {},
  }
end

---@param bytes string
---@return string
local function toHex(bytes)
  local parts = {}
  for index = 1, #bytes do
    parts[#parts + 1] = string.format("%02x", string.byte(bytes, index))
  end
  return table.concat(parts)
end

---@param codes string[]
---@param fn fun(): any
---@return any
local function throwsStructured(codes, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected a structured domain failure, got " .. tostring(err))
  for _, code in ipairs(codes) do
    if err.code == code then
      return err
    end
  end
  error("unexpected failure code " .. tostring(err.code) .. ": " .. Errors.format(err), 0)
end

function T.native_status_words_upgrade_losslessly_and_bad_combinations_fail()
  local StatusCodec = requireOwner("libs.mons.src.gen4.StatusCodec", "native status word conversion")
  Assert.isTrue(type(StatusCodec.decode) == "function", "status conversion must expose decode")
  Assert.isTrue(type(StatusCodec.project) == "function", "status conversion must expose project")
  local Migration = requireOwner("libs.mons.src.MonStateMigration", "legacy mon upgrade")
  Assert.isTrue(type(Migration.upgradeMon) == "function", "legacy upgrade must expose upgradeMon")
  local Mon = require("libs.mons.src.Mon")
  Assert.equal(Mon.SCHEMA, "g4-mon-v2", "the canonical record must carry semantic condition effects")

  local catalog = CatalogFixture.makeCatalog()
  local context = CatalogFixture.domainContext(catalog)
  local BoxCodec = require("libs.mons.src.gen4.BoxCodec")

  -- Health is the empty persistent record.
  Assert.deepEqual(StatusCodec.decode(0), {})

  -- Poisoned and badly poisoned stay distinct instead of flattening into
  -- one boolean: each decodes to a single record that projects back to its
  -- own word.
  local poisoned = StatusCodec.decode(0x8)
  local badlyPoisoned = StatusCodec.decode(0x80)
  Assert.equal(#poisoned, 1, "poison decodes to one persistent record")
  Assert.equal(#badlyPoisoned, 1, "toxic decodes to one persistent record")
  Assert.equal(StatusCodec.project(copy(poisoned)), 0x8, "poison round-trips to its own word")
  Assert.equal(StatusCodec.project(copy(badlyPoisoned)), 0x80, "toxic round-trips to its own word")

  local validWords = { 0, 1, 2, 3, 4, 5, 6, 7, 0x8, 0x10, 0x20, 0x40, 0x80, 0x180, 0x580, 0xF80 }
  for _, word in ipairs(validWords) do
    local effects = StatusCodec.decode(word)
    Assert.equal(
      StatusCodec.project(copy(effects)),
      word,
      string.format("recognized word 0x%x must round-trip exactly", word)
    )
    Assert.deepEqual(
      StatusCodec.decode(word),
      effects,
      string.format("recognized word 0x%x must decode deterministically", word)
    )

    local source = legacyRecord(word)
    local pristine = copy(source)
    local upgraded = Migration.upgradeMon(source, context)
    Assert.deepEqual(source, pristine, "upgrade never mutates its input")
    Assert.equal(upgraded.schema, "g4-mon-v2", "upgrade moves the record to the current schema")
    Assert.equal(upgraded.condition.currentHp, 28, "upgrade keeps current health")
    Assert.deepEqual(upgraded.condition.effects, effects, "upgrade keeps the decoded conditions")
    for key, value in pairs(pristine) do
      if key ~= "schema" and key ~= "condition" then
        Assert.deepEqual(
          upgraded[key],
          value,
          string.format("upgrade preserves %s for word 0x%x", tostring(key), word)
        )
      end
    end
    Assert.deepEqual(
      Mon.validate(upgraded, context),
      upgraded,
      string.format("upgraded word 0x%x must validate as current", word)
    )
    Assert.deepEqual(
      Migration.upgradeMon(legacyRecord(word), context),
      upgraded,
      string.format("upgrade of word 0x%x must be deterministic", word)
    )
    Assert.equal(
      toHex(BoxCodec.encode(upgraded, context)),
      FROZEN_HEX,
      string.format("upgraded word 0x%x must keep the exact boxed bytes", word)
    )
  end

  -- The frozen bytes decode back to the same boxed identity.
  local decoded = BoxCodec.decode(CatalogFixture.fromHex(FROZEN_HEX), context)
  Assert.equal(decoded.species, "CHIKORITA")
  Assert.equal(decoded.personality, 0x12345678)
  Assert.equal(decoded.experience, 419)
  Assert.deepEqual(decoded.ivs, legacyRecord(0).ivs)
  Assert.deepEqual(decoded.moves, legacyRecord(0).moves)

  -- Unsupported combinations fail explicitly at decode and at upgrade:
  -- clashing majors, counters without toxic, and unknown high bits.
  local malformedWords = { 0x8 + 0x10, 0x3 + 0x8, 0x500, 0x8 + 0x300, 0x3 + 0x80, 0x5 + 0x200, 0x1000 }
  for _, word in ipairs(malformedWords) do
    throwsStructured(NATIVE_CODES, function()
      StatusCodec.decode(word)
    end)
    throwsStructured(NATIVE_CODES, function()
      Migration.upgradeMon(legacyRecord(word), context)
    end)
  end

  -- The current shape validates, but the opaque legacy word and
  -- battle-only state can never enter a persistent record.
  local current = legacyRecord(0)
  current.schema = "g4-mon-v2"
  current.condition = { currentHp = 28, effects = {} }
  Assert.deepEqual(Mon.validate(current, context), current)
  local opaque = copy(current)
  opaque.condition = { status = 0, currentHp = 28 }
  throwsStructured({ "MON_RECORD_INVALID" }, function()
    Mon.validate(opaque, context)
  end)
  for _, key in ipairs({ "substitute", "confusion" }) do
    local transient = copy(current)
    transient.condition = { currentHp = 28, effects = { { key = key, version = 1, state = {} } } }
    throwsStructured({ "MON_RECORD_INVALID" }, function()
      Mon.validate(transient, context)
    end)
  end
end

return { tests = T }
